// Microphone narration track. Audio is captured with its own AVCaptureSession, converted to the
// host clock like the camera (CameraClock), and written as AAC segments under media/microphone.
// The level check comes from Probes/LocalDraftProbe (MicRecorder.peakDB): in US-003 a closed
// MacBook lid gave an all-silent file at -91 dB, so silence is measured live, warned about
// within a few seconds, and recorded in the manifest so a silent recording never reads as clean.

import AVFoundation
import CoreMedia
import os
import Foundation

enum MicrophoneTrackEvent: Sendable {
    /// Microphone audio. `hostPTS` is on the host clock, the same timeline as the screen track.
    case audio(SampleBox, hostPTS: Double, durationSeconds: Double, levelDBFS: Double)
    /// A periodic clock tick, so silence is noticed even when no audio arrives at all.
    case tick(hostTime: Double)
    /// The microphone stopped delivering audio.
    case lost(RecordingManifest.CameraGap.Reason, hostTime: Double)
}

enum MicrophoneTrackIssue: Equatable, Sendable {
    /// The microphone has sent only silence for a few seconds.
    case silent
    /// Sound is coming through again after a silent stretch.
    case soundBack
    /// The microphone stopped sending audio. The screen keeps recording.
    case lost(RecordingManifest.CameraGap.Reason)
    /// Audio is arriving again, in a new segment.
    case resumed
    /// The microphone track can't write any more. The screen keeps recording.
    case stopped(String)
}

/// Peak level of PCM audio, in dBFS.
enum AudioLevel {
    /// The level reported for digital silence. JSON can't hold -infinity.
    static let floorDBFS = -160.0

    static func dbfs(peak: Double) -> Double {
        guard peak.isFinite, peak > 0 else { return floorDBFS }
        return max(floorDBFS, 20 * log10(peak))
    }

    /// Loudest sample in a linear PCM buffer. Non-PCM or unreadable buffers report the floor.
    static func peakDBFS(_ buffer: CMSampleBuffer) -> Double {
        guard let format = CMSampleBufferGetFormatDescription(buffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 else { return floorDBFS }
        var needed = 0
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer, bufferListSizeNeededOut: &needed, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard status == noErr, needed > 0 else { return floorDBFS }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: 16)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: needed,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block)
        guard status == noErr else {
            NSLog("HQ recorder: could not read microphone samples: \(status)")
            return floorDBFS
        }
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        var peak = 0.0
        for audio in UnsafeMutableAudioBufferListPointer(list) {
            guard let data = audio.mData else { continue }
            let bytes = Int(audio.mDataByteSize)
            switch (isFloat, asbd.mBitsPerChannel) {
            case (true, 32):
                for v in UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: bytes / 4) {
                    peak = max(peak, Double(abs(v)))
                }
            case (true, 64):
                for v in UnsafeBufferPointer(start: data.assumingMemoryBound(to: Double.self), count: bytes / 8) {
                    peak = max(peak, abs(v))
                }
            case (false, 16):
                for v in UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int16.self), count: bytes / 2) {
                    peak = max(peak, abs(Double(v)) / 32768)
                }
            case (false, 32):
                for v in UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int32.self), count: bytes / 4) {
                    peak = max(peak, abs(Double(v)) / 2147483648)
                }
            default:
                return floorDBFS
            }
        }
        return dbfs(peak: peak)
    }
}

/// Decides when microphone audio counts as silent. Pure, so the timing is testable.
struct SilenceMonitor: Sendable {
    /// Peaks below this are silence. A quiet room's noise floor peaks well above it; the
    /// closed-lid built-in mic measured in US-003 sat at -91 dBFS.
    static let thresholdDBFS = -60.0
    /// How long the input must stay silent before the user is warned.
    static let windowSeconds = 3.0

    enum Change: Equatable, Sendable {
        /// Silent since the given time on the output timeline.
        case silent(since: Double)
        /// Sound came back at the given time on the output timeline.
        case sound(at: Double)
    }

    /// Time sound was last heard, or the start when none has been heard yet.
    private(set) var lastSound: Double
    private(set) var warned = false
    /// Loudest level seen, or nil before any audio.
    private(set) var peakDBFS: Double?

    init(start: Double) { lastSound = start }

    /// True once any audio rose above the threshold.
    var heardSound: Bool { (peakDBFS ?? AudioLevel.floorDBFS) >= Self.thresholdDBFS }

    mutating func level(_ dbfs: Double, at time: Double) -> Change? {
        peakDBFS = max(peakDBFS ?? AudioLevel.floorDBFS, dbfs)
        guard dbfs >= Self.thresholdDBFS else { return check(at: time) }
        lastSound = max(lastSound, time)
        guard warned else { return nil }
        warned = false
        return .sound(at: time)
    }

    /// Called with audio and on clock ticks, so a microphone that sends nothing is caught too.
    mutating func check(at time: Double) -> Change? {
        guard !warned, time - lastSound >= Self.windowSeconds else { return nil }
        warned = true
        return .silent(since: lastSound)
    }
}

/// Writes microphone audio into segments of the recording's microphone track. Each segment
/// starts at its first buffer's offset from the origin the screen and camera tracks use.
actor MicrophoneTrack {
    typealias MakeWriter = @Sendable (URL) throws -> any FrameWriting

    let session: RecordingSession
    /// Host time the recording started, shared with the screen and camera tracks.
    let origin: Double
    /// Shared pause timeline. Audio inside a pause is not written, and offsets leave paused time out.
    let clock: RecordingClock
    private let makeWriter: MakeWriter
    private let onIssue: @Sendable (MicrophoneTrackIssue) -> Void
    private var writer: (any FrameWriting)?
    private var segmentURL: URL?
    private var buffersInSegment = 0
    private var segmentEpoch = 0
    private var lastPTS: Double?
    private var gapOpen = false
    private var monitor: SilenceMonitor
    /// Why the microphone track stopped writing, if it did. The recording itself goes on.
    private(set) var stopped: String?
    private(set) var buffersWritten = 0
    private(set) var buffersDropped = 0
    private(set) var buffersPaused = 0
    private var finished = false

    init(session: RecordingSession, origin: Double, clock: RecordingClock? = nil,
         makeWriter: @escaping MakeWriter = { try AudioTrackWriter(url: $0) },
         onIssue: @escaping @Sendable (MicrophoneTrackIssue) -> Void) {
        self.session = session
        self.origin = origin
        self.clock = clock ?? RecordingClock(origin: origin)
        self.makeWriter = makeWriter
        self.onIssue = onIssue
        // Silence is timed on the output timeline, so a pause never counts as silence.
        monitor = SilenceMonitor(start: 0)
    }

    var heardSound: Bool { monitor.heardSound }

    func handle(_ event: MicrophoneTrackEvent) async {
        guard !finished else { return }
        switch event {
        case let .audio(box, pts, duration, level):
            if pts.isFinite, clock.isPaused(at: pts) {
                buffersPaused += 1
                if lastPTS.map({ pts > $0 }) ?? true { lastPTS = pts }
                return
            }
            if let change = monitor.level(level, at: clock.offset(pts)) { await report(change) }
            guard stopped == nil else { return }
            await write(box.buffer, pts: pts, duration: duration)
        case let .tick(time):
            guard !clock.isPaused(at: time) else { return }
            if let change = monitor.check(at: clock.offset(time)) { await report(change) }
        case let .lost(reason, time):
            guard stopped == nil else { return }
            await lose(reason, at: time)
        }
    }

    /// Records the narration result in the manifest. Call after capture has stopped and the
    /// feed has drained, before the recording is finalized.
    func finish() async {
        guard !finished else { return }
        finished = true
        do {
            try await session.recordMicrophoneLevel(silent: !monitor.heardSound, peakDBFS: monitor.peakDBFS)
        } catch {
            NSLog("HQ recorder: could not record the microphone level: \(error)")
        }
    }

    private func report(_ change: SilenceMonitor.Change) async {
        do {
            switch change {
            case .silent(let since):
                try await session.beginMicrophoneSilence(atOffset: since)
                onIssue(.silent)
            case .sound(let time):
                try await session.endMicrophoneSilence(atOffset: time)
                onIssue(.soundBack)
            }
        } catch {
            NSLog("HQ recorder: could not mark microphone silence: \(error)")
        }
    }

    private func write(_ buffer: CMSampleBuffer, pts: Double, duration: Double) async {
        // Audio from before the start, repeated or out of order cannot go on the timeline.
        guard pts.isFinite, pts >= origin, lastPTS.map({ pts > $0 }) ?? true else {
            buffersDropped += 1
            return
        }
        // The first buffer after a resume opens a new segment, so no segment spans a pause.
        if writer == nil || clock.epoch(at: pts) != segmentEpoch {
            guard await openSegment(at: pts) else { return }
        }
        lastPTS = pts
        if gapOpen {
            gapOpen = false
            do {
                try await session.endMicrophoneGap(atOffset: clock.offset(pts))
            } catch {
                NSLog("HQ recorder: could not mark microphone gap end: \(error)")
            }
            onIssue(.resumed)
        }
        guard let current = writer else { return }
        current.append(buffer, hostPTS: pts)
        if current.failure == nil {
            buffersInSegment += 1
            buffersWritten += 1
            return
        }
        NSLog("HQ recorder: microphone segment failed: \(current.failure ?? "unknown")")
        // A writer that fails on its first buffer will fail again in a new segment.
        guard buffersInSegment > 0 else { return await giveUp("microphone-writer-failed", at: pts) }
        guard await openSegment(at: pts), let retry = writer else { return }
        retry.append(buffer, hostPTS: pts)
        if let error = retry.failure {
            NSLog("HQ recorder: microphone segment failed again: \(error)")
            return await giveUp("microphone-writer-failed", at: pts)
        }
        buffersInSegment += 1
        buffersWritten += 1
    }

    /// Closes the open segment, keeping its audio, and records a gap until audio comes back.
    private func lose(_ reason: RecordingManifest.CameraGap.Reason, at time: Double) async {
        guard !gapOpen else { return }
        gapOpen = true
        do {
            try await session.beginMicrophoneGap(reason, atOffset: clock.offset(time))
        } catch {
            NSLog("HQ recorder: could not mark microphone gap start: \(error)")
        }
        await closeSegment()
        onIssue(.lost(reason))
    }

    private func openSegment(at pts: Double) async -> Bool {
        await closeSegment()
        do {
            let url = try await session.beginSegment(.microphone, startOffsetSeconds: clock.offset(pts),
                                                     fileExtension: "m4a")
            let next = try makeWriter(url)
            try await session.attach(next, to: url)
            writer = next
            segmentURL = url
            buffersInSegment = 0
            segmentEpoch = clock.epoch(at: pts)
            return true
        } catch {
            NSLog("HQ recorder: could not start a microphone segment: \(error)")
            await giveUp("microphone-segment-failed", at: pts)
            return false
        }
    }

    private func closeSegment() async {
        guard let segmentURL else { return }
        writer = nil
        self.segmentURL = nil
        do {
            try await session.closeSegment(segmentURL)
        } catch {
            NSLog("HQ recorder: could not close a microphone segment: \(error)")
        }
    }

    /// Stops the microphone track for the rest of the recording. Written audio is kept and the
    /// rest of the recording is marked as a microphone gap.
    private func giveUp(_ reason: String, at pts: Double) async {
        guard stopped == nil else { return }
        stopped = reason
        await closeSegment()
        if !gapOpen {
            gapOpen = true
            do {
                try await session.beginMicrophoneGap(.writerFailed, atOffset: clock.offset(pts))
            } catch {
                NSLog("HQ recorder: could not mark microphone gap start: \(error)")
            }
        }
        onIssue(.stopped(reason))
    }
}

/// Delivers microphone events to the track in order, off the capture queue. Sending never waits
/// for the writer, so a slow disk can't hold up capture or the UI.
final class MicrophoneFeed: Sendable {
    private let continuation: AsyncStream<MicrophoneTrackEvent>.Continuation
    private let consumer: Task<Void, Never>

    init(track: MicrophoneTrack) {
        let (stream, continuation) = AsyncStream.makeStream(of: MicrophoneTrackEvent.self)
        self.continuation = continuation
        consumer = Task {
            for await event in stream { await track.handle(event) }
        }
    }

    func send(_ event: MicrophoneTrackEvent) { continuation.yield(event) }

    /// Stops taking events and waits until every queued event has been written.
    func drain() async {
        continuation.finish()
        await consumer.value
    }
}

/// Writes one microphone segment as fragmented AAC. Fragments are flushed every second, so a
/// crash or a low-disk stop loses at most the last fragment.
///
/// The writer input reads every buffer in the format it was opened with, and a microphone can
/// change format after the first buffer (another app or the camera reconfiguring the device).
/// Audio read in the wrong format is written at the wrong length, so the writer is opened with
/// one fixed format, 48 kHz Float32 with the first buffer's channel count (one or two), and every
/// buffer in another format is converted to it first.
final class AudioTrackWriter: FrameWriting, @unchecked Sendable {
    static let sampleRate = 48_000.0
    let url: URL
    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    /// The format the writer input reads. Every appended buffer is in this format.
    private var target: AVAudioFormat?
    /// Converters to `target`, one per source format, so a resampler keeps its state across buffers.
    private var converters: [(source: CMAudioFormatDescription, converter: AVAudioConverter)] = []
    private var setupError: String?
    private var firstHostPTS: Double?
    private var endHostPTS: Double?
    private(set) var buffers = 0
    private(set) var dropped = 0
    private var closed = false
    private var finishTask: Task<Void, Never>?

    init(url: URL) throws {
        self.url = url
    }

    func append(_ buffer: CMSampleBuffer, hostPTS: Double) {
        lock.lock(); defer { lock.unlock() }
        guard !closed, setupError == nil else { return }
        if writer == nil {
            do {
                try open(for: buffer)
            } catch {
                NSLog("HQ recorder: could not set up the microphone writer: \(error)")
                setupError = "\(error)"
                return
            }
        }
        guard let writer, let input else { return }
        if writer.status == .unknown {
            writer.startWriting()
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(buffer))
            firstHostPTS = hostPTS
        }
        guard writer.status == .writing else { return }
        guard let written = matching(buffer) else {
            dropped += 1
            return
        }
        if input.isReadyForMoreMediaData, input.append(written) {
            buffers += 1
            endHostPTS = hostPTS + Self.seconds(of: buffer)
        } else {
            dropped += 1
        }
    }

    /// The buffer in the writer's format: as is when it already matches, else converted. Nil when
    /// it can't be converted.
    private func matching(_ buffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard let target, let source = CMSampleBufferGetFormatDescription(buffer) else { return nil }
        if CMFormatDescriptionEqual(source, otherFormatDescription: target.formatDescription) { return buffer }
        guard let converter = converter(from: source, to: target) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(buffer))
        guard frames > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            buffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList) == noErr else { return nil }
        let capacity = AVAudioFrameCount(
            (Double(frames) * target.sampleRate / converter.inputFormat.sampleRate).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        // The converter calls the input block on this thread before `convert` returns. The buffer
        // is handed over once; a later call is told there is no more input yet, which keeps the
        // resampler's state for the next buffer.
        let pending = OSAllocatedUnfairLock<AVAudioPCMBuffer?>(uncheckedState: pcm)
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            let next = pending.withLockUnchecked { buffer in
                defer { buffer = nil }
                return buffer
            }
            inputStatus.pointee = next == nil ? .noDataNow : .haveData
            return next
        }
        guard status != .error, out.frameLength > 0 else {
            if let error { NSLog("HQ recorder: could not convert microphone audio: \(error)") }
            return nil
        }
        return Self.sampleBuffer(out, at: CMSampleBufferGetPresentationTimeStamp(buffer))
    }

    private func converter(from source: CMAudioFormatDescription, to target: AVAudioFormat) -> AVAudioConverter? {
        if let known = converters.first(where: { CMFormatDescriptionEqual($0.source, otherFormatDescription: source) }) {
            return known.converter
        }
        guard let converter = AVAudioConverter(from: AVAudioFormat(cmAudioFormatDescription: source), to: target)
        else { return nil }
        converter.downmix = true
        converters.append((source, converter))
        return converter
    }

    /// A sample buffer holding `pcm`, starting at `pts`.
    static func sampleBuffer(_ pcm: AVAudioPCMBuffer, at pts: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(pcm.format.sampleRate)),
                                        presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
                                   refcon: nil, formatDescription: pcm.format.formatDescription,
                                   sampleCount: CMItemCount(pcm.frameLength), sampleTimingEntryCount: 1,
                                   sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                   sampleBufferOut: &sample) == noErr,
              let sample,
              CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: nil,
                                                             blockBufferMemoryAllocator: nil, flags: 0,
                                                             bufferList: pcm.audioBufferList) == noErr
        else { return nil }
        return sample
    }

    /// Non-nil once the writer can't take more audio.
    var failure: String? {
        lock.withLock {
            if let setupError { return setupError }
            guard let writer, writer.status == .failed else { return nil }
            return writer.error.map { "\($0)" } ?? "unknown"
        }
    }

    private func open(for buffer: CMSampleBuffer) throws {
        guard let source = CMSampleBufferGetFormatDescription(buffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(source)?.pointee,
              asbd.mSampleRate > 0 else { throw AudioWriterError.unsupportedFormat }
        let channels = max(1, min(2, Int(asbd.mChannelsPerFrame)))
        guard let opened = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate,
                                         channels: AVAudioChannelCount(channels), interleaved: true)
        else { throw AudioWriterError.unsupportedFormat }
        let format = opened.formatDescription
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        let next = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: channels,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
        ]
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: format)
        audio.expectsMediaDataInRealTime = true
        next.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        guard next.canAdd(audio) else { throw AudioWriterError.cannotAddInput }
        next.add(audio)
        writer = next
        input = audio
        target = opened
    }

    static func seconds(of buffer: CMSampleBuffer) -> Double {
        let duration = CMSampleBufferGetDuration(buffer)
        if duration.isValid, duration.seconds.isFinite, duration.seconds > 0 { return duration.seconds }
        guard let format = CMSampleBufferGetFormatDescription(buffer),
              let rate = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mSampleRate,
              rate > 0 else { return 0 }
        return Double(CMSampleBufferGetNumSamples(buffer)) / rate
    }

    private func closingTask() -> Task<Void, Never> {
        lock.withLock {
            if let finishTask { return finishTask }
            closed = true
            let writer = self.writer
            let input = self.input
            let task = Task<Void, Never> {
                guard let writer, let input, writer.status == .writing else { return }
                input.markAsFinished()
                await writer.finishWriting()
                if writer.status != .completed {
                    NSLog("HQ recorder: microphone segment did not finish: \(writer.error.map { "\($0)" } ?? "unknown")")
                }
            }
            finishTask = task
            return task
        }
    }

    /// Returns the host-clock span of the written audio, or nil when nothing was written.
    func finishSegment() async -> Double? {
        await closingTask().value
        return lock.withLock {
            guard let firstHostPTS, let endHostPTS, buffers > 0 else { return nil }
            return endHostPTS - firstHostPTS
        }
    }
}

enum AudioWriterError: Error, Equatable {
    case unsupportedFormat
    case cannotAddInput
}

/// One running microphone capture for one device. Session, device and observer state is only
/// touched on `queue`. The live level is readable from any thread for the meter.
final class MicrophoneCaptureRun: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    let deviceID: String
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "com.indigo.local-screen-recorder.microphone")
    private let feed: MicrophoneFeed
    private let levelLock = NSLock()
    private var currentLevel: Double?
    private var ticker: DispatchSourceTimer?
    private var tokens: [NSObjectProtocol] = []
    /// Set by `stop()` on `queue`. A start that runs after it is refused.
    private var stopped = false

    init(track: MicrophoneTrack, deviceID: String) {
        feed = MicrophoneFeed(track: track)
        self.deviceID = deviceID
    }

    /// Peak level of the latest audio in dBFS, or nil before any audio.
    var level: Double? { levelLock.withLock { currentLevel } }

    /// Opens the microphone, starts audio, the silence clock and the interruption observers.
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard !stopped else {
                    continuation.resume(throwing: CameraCaptureError.stopped)
                    return
                }
                do {
                    session.beginConfiguration()
                    try attachDevice()
                    output.setSampleBufferDelegate(self, queue: queue)
                    guard session.canAddOutput(output) else { throw CameraCaptureError.cannotAddOutput }
                    session.addOutput(output)
                    session.commitConfiguration()
                    observeSession()
                    startTicker()
                    session.startRunning()
                    continuation.resume()
                } catch {
                    session.commitConfiguration()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Stops the microphone, then waits until every delivered buffer is written.
    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                stopped = true
                ticker?.cancel()
                ticker = nil
                tokens.forEach(NotificationCenter.default.removeObserver)
                tokens = []
                if session.isRunning { session.stopRunning() }
                continuation.resume()
            }
        }
        await feed.drain()
    }

    private func attachDevice() throws {
        guard let device = AVCaptureDevice(uniqueID: deviceID) else { throw CameraCaptureError.deviceUnavailable }
        let input = try AVCaptureDeviceInput(device: device)
        session.inputs.forEach(session.removeInput)
        guard session.canAddInput(input) else { throw CameraCaptureError.cannotAddInput }
        session.addInput(input)
    }

    private func startTicker() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let feed = self.feed
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { feed.send(.tick(hostTime: ScreenCapture.hostNow())) }
        timer.resume()
        ticker = timer
    }

    private func observeSession() {
        let center = NotificationCenter.default
        let feed = self.feed
        let deviceID = self.deviceID
        tokens = [
            center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session,
                               queue: nil) { _ in
                feed.send(.lost(.interrupted, hostTime: ScreenCapture.hostNow()))
            },
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session,
                               queue: nil) { [weak self] note in
                NSLog("HQ recorder: microphone runtime error: \(note.userInfo?[AVCaptureSessionErrorKey] ?? "unknown")")
                feed.send(.lost(.runtimeError, hostTime: ScreenCapture.hostNow()))
                self?.restart()
            },
            center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil,
                               queue: nil) { note in
                guard (note.object as? AVCaptureDevice)?.uniqueID == deviceID else { return }
                feed.send(.lost(.disconnected, hostTime: ScreenCapture.hostNow()))
            },
            center.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil,
                               queue: nil) { [weak self] note in
                guard (note.object as? AVCaptureDevice)?.uniqueID == deviceID else { return }
                self?.reconnect()
            },
        ]
    }

    /// The same microphone came back: attach it again. Its next audio closes the gap.
    private func reconnect() {
        queue.async { [self] in
            guard !tokens.isEmpty else { return }
            session.beginConfiguration()
            do {
                try attachDevice()
            } catch {
                NSLog("HQ recorder: could not reattach the microphone: \(error)")
            }
            session.commitConfiguration()
            if !session.isRunning { session.startRunning() }
        }
    }

    private func restart() {
        queue.async { [self] in
            guard !tokens.isEmpty, !session.isRunning else { return }
            session.startRunning()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard sampleBuffer.isValid else { return }
        let pts = CameraClock.hostSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                                          sessionClock: session.synchronizationClock)
        let level = AudioLevel.peakDBFS(sampleBuffer)
        levelLock.withLock { currentLevel = level }
        feed.send(.audio(SampleBox(buffer: sampleBuffer), hostPTS: pts,
                         durationSeconds: AudioTrackWriter.seconds(of: sampleBuffer), levelDBFS: level))
    }
}
