// Webcam track capture. The AVCaptureSession setup, the host-clock conversion of camera
// timestamps and the interruption, effect and suspension observers come from
// Probes/LayeredCaptureProbe (CameraRecorder). US-002 verified the recovery policy: a camera
// problem never stops the screen track, finished camera media is kept, and the camera picks
// up in a new segment when frames come back. Presenter Overlay sends no interruption; the
// camera frames show a system placeholder for the range the screen track marks as flattened.

import AVFoundation
import CoreMedia
import Foundation

enum CameraTrackEvent: Sendable {
    /// A camera frame. `hostPTS` is on the host clock, the same timeline as the screen track.
    case frame(SampleBox, hostPTS: Double, width: Int, height: Int)
    /// The camera stopped delivering frames.
    case lost(RecordingManifest.CameraGap.Reason, hostTime: Double)
    /// A camera effect such as Portrait was turned on or off.
    case effect(RecordingManifest.CameraEffectRange.Kind, active: Bool, hostTime: Double)
}

enum CameraTrackIssue: Equatable, Sendable {
    /// The camera stopped sending frames. The screen keeps recording.
    case lost(RecordingManifest.CameraGap.Reason)
    /// Camera frames are arriving again, in a new segment.
    case resumed
    /// The camera track can't write any more. The screen keeps recording.
    case stopped(String)
}

/// Writes camera frames into segments of the recording's camera track. Each segment starts
/// at its first frame's offset from the same origin the screen track uses. A lost camera
/// closes its segment and opens a gap; the next frame closes the gap and starts a new segment.
actor CameraTrack {
    let session: RecordingSession
    /// Host time the recording started, shared with the screen track.
    let origin: Double
    /// Shared pause timeline. Frames inside a pause are not written, and offsets leave paused time out.
    let clock: RecordingClock
    private let makeWriter: ScreenTrack.MakeWriter
    private let onIssue: @Sendable (CameraTrackIssue) -> Void
    private var writer: (any FrameWriting)?
    private var segmentURL: URL?
    private var width = 0
    private var height = 0
    private var framesInSegment = 0
    private var segmentEpoch = 0
    private var lastPTS: Double?
    private var gapOpen = false
    /// Why the camera track stopped writing, if it did. The recording itself goes on.
    private(set) var stopped: String?
    private(set) var framesWritten = 0
    private(set) var framesDropped = 0
    private(set) var framesPaused = 0

    init(session: RecordingSession, origin: Double, clock: RecordingClock? = nil,
         makeWriter: @escaping ScreenTrack.MakeWriter = { try TrackWriter(url: $0, width: $1, height: $2) },
         onIssue: @escaping @Sendable (CameraTrackIssue) -> Void) {
        self.session = session
        self.origin = origin
        self.clock = clock ?? RecordingClock(origin: origin)
        self.makeWriter = makeWriter
        self.onIssue = onIssue
    }

    func handle(_ event: CameraTrackEvent) async {
        guard stopped == nil else { return }
        switch event {
        case let .frame(box, pts, width, height):
            await write(box.buffer, pts: pts, width: width, height: height)
        case let .lost(reason, time):
            await lose(reason, at: time)
        case let .effect(kind, active, time):
            do {
                if active {
                    try await session.beginCameraEffect(kind, atOffset: clock.offset(time))
                } else {
                    try await session.endCameraEffect(kind, atOffset: clock.offset(time))
                }
            } catch {
                NSLog("HQ recorder: could not mark camera effect \(kind.rawValue): \(error)")
            }
        }
    }

    private func write(_ buffer: CMSampleBuffer, pts: Double, width: Int, height: Int) async {
        // Frames from before the start, repeated or out of order cannot go on the timeline.
        guard pts.isFinite, pts >= origin, lastPTS.map({ pts > $0 }) ?? true else {
            framesDropped += 1
            return
        }
        // Paused time is left out; the first frame after a resume opens a new segment.
        if clock.isPaused(at: pts) {
            framesPaused += 1
            lastPTS = pts
            return
        }
        if writer == nil || width != self.width || height != self.height
            || clock.epoch(at: pts) != segmentEpoch {
            guard await openSegment(at: pts, width: width, height: height) else { return }
        }
        lastPTS = pts
        if gapOpen {
            gapOpen = false
            do {
                try await session.endCameraGap(atOffset: clock.offset(pts))
            } catch {
                NSLog("HQ recorder: could not mark camera gap end: \(error)")
            }
            onIssue(.resumed)
        }
        guard let current = writer else { return }
        current.append(buffer, hostPTS: pts)
        if current.failure == nil {
            framesInSegment += 1
            framesWritten += 1
            return
        }
        NSLog("HQ recorder: camera segment failed: \(current.failure ?? "unknown")")
        // A writer that fails on its first frame will fail again in a new segment.
        guard framesInSegment > 0 else { return await giveUp("camera-writer-failed", at: pts) }
        guard await openSegment(at: pts, width: width, height: height), let retry = writer else { return }
        retry.append(buffer, hostPTS: pts)
        if let error = retry.failure {
            NSLog("HQ recorder: camera segment failed again: \(error)")
            return await giveUp("camera-writer-failed", at: pts)
        }
        framesInSegment += 1
        framesWritten += 1
    }

    /// Closes the open segment, keeping its media, and records a gap until frames come back.
    private func lose(_ reason: RecordingManifest.CameraGap.Reason, at time: Double) async {
        guard !gapOpen else { return }
        gapOpen = true
        do {
            try await session.beginCameraGap(reason, atOffset: clock.offset(time))
        } catch {
            NSLog("HQ recorder: could not mark camera gap start: \(error)")
        }
        await closeSegment()
        onIssue(.lost(reason))
    }

    /// Closes the current segment and opens the next one at `pts`.
    private func openSegment(at pts: Double, width: Int, height: Int) async -> Bool {
        await closeSegment()
        do {
            let url = try await session.beginSegment(.camera, startOffsetSeconds: clock.offset(pts))
            let next = try makeWriter(url, width, height)
            try await session.attach(next, to: url)
            writer = next
            segmentURL = url
            self.width = width
            self.height = height
            framesInSegment = 0
            segmentEpoch = clock.epoch(at: pts)
            return true
        } catch {
            NSLog("HQ recorder: could not start a camera segment: \(error)")
            await giveUp("camera-segment-failed", at: pts)
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
            NSLog("HQ recorder: could not close a camera segment: \(error)")
        }
    }

    /// Stops the camera track for the rest of the recording. Written camera media is kept and
    /// the rest of the recording is marked as a camera gap.
    private func giveUp(_ reason: String, at pts: Double) async {
        guard stopped == nil else { return }
        stopped = reason
        await closeSegment()
        if !gapOpen {
            gapOpen = true
            do {
                try await session.beginCameraGap(.writerFailed, atOffset: clock.offset(pts))
            } catch {
                NSLog("HQ recorder: could not mark camera gap start: \(error)")
            }
        }
        onIssue(.stopped(reason))
    }
}

/// Delivers camera events to the track in order, off the capture queue.
final class CameraFeed: Sendable {
    private let continuation: AsyncStream<CameraTrackEvent>.Continuation
    private let consumer: Task<Void, Never>

    init(track: CameraTrack) {
        let (stream, continuation) = AsyncStream.makeStream(of: CameraTrackEvent.self)
        self.continuation = continuation
        consumer = Task {
            for await event in stream { await track.handle(event) }
        }
    }

    func send(_ event: CameraTrackEvent) { continuation.yield(event) }

    /// Stops taking events and waits until every queued event has been written.
    func drain() async {
        continuation.finish()
        await consumer.value
    }
}

enum CameraClock {
    /// Converts a camera presentation time from the capture session's clock to host-clock
    /// seconds, the timeline ScreenCaptureKit stamps screen frames with.
    static func hostSeconds(_ pts: CMTime, sessionClock: CMClock?) -> Double {
        guard let sessionClock else { return pts.seconds }
        return CMSyncConvertTime(pts, from: sessionClock, to: CMClockGetHostTimeClock()).seconds
    }
}

enum CameraCaptureError: Error, Equatable {
    case deviceUnavailable
    case cannotAddInput
    case cannotAddOutput
    /// The capture was stopped before it started.
    case stopped
}

/// One running camera capture for one device. Session, device and observer state is only
/// touched on `queue`.
final class CameraCaptureRun: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    let deviceID: String
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "com.indigo.local-screen-recorder.camera")
    private let feed: CameraFeed
    private var observations: [NSKeyValueObservation] = []
    private var tokens: [NSObjectProtocol] = []
    /// Set by `stop()` on `queue`. A start that runs after it is refused.
    private var stopped = false

    init(track: CameraTrack, deviceID: String) {
        feed = CameraFeed(track: track)
        self.deviceID = deviceID
    }

    /// Opens the camera, starts frames and starts watching for interruptions and effects.
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard !stopped else {
                    continuation.resume(throwing: CameraCaptureError.stopped)
                    return
                }
                do {
                    session.beginConfiguration()
                    if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
                    let device = try attachDevice()
                    output.alwaysDiscardsLateVideoFrames = false
                    output.setSampleBufferDelegate(self, queue: queue)
                    guard session.canAddOutput(output) else { throw CameraCaptureError.cannotAddOutput }
                    session.addOutput(output)
                    session.commitConfiguration()
                    observe(device)
                    observeSession()
                    session.startRunning()
                    continuation.resume()
                } catch {
                    session.commitConfiguration()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Stops the camera, then waits until every delivered frame is written.
    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                stopped = true
                observations.forEach { $0.invalidate() }
                observations = []
                tokens.forEach(NotificationCenter.default.removeObserver)
                tokens = []
                if session.isRunning { session.stopRunning() }
                continuation.resume()
            }
        }
        await feed.drain()
    }

    /// Replaces any input with the device for `deviceID`. Call inside a configuration block.
    private func attachDevice() throws -> AVCaptureDevice {
        guard let device = AVCaptureDevice(uniqueID: deviceID) else { throw CameraCaptureError.deviceUnavailable }
        let input = try AVCaptureDeviceInput(device: device)
        session.inputs.forEach(session.removeInput)
        guard session.canAddInput(input) else { throw CameraCaptureError.cannotAddInput }
        session.addInput(input)
        return device
    }

    /// Effect and suspension state on the device. Effects are drawn into the camera frames,
    /// so they are logged as the user's chosen look.
    private func observe(_ device: AVCaptureDevice) {
        observations.forEach { $0.invalidate() }
        let feed = self.feed
        func effect(_ kind: RecordingManifest.CameraEffectRange.Kind)
            -> @Sendable (AVCaptureDevice, NSKeyValueObservedChange<Bool>) -> Void {
            { _, change in feed.send(.effect(kind, active: change.newValue ?? false, hostTime: ScreenCapture.hostNow())) }
        }
        observations = [
            device.observe(\.isPortraitEffectActive, options: [.initial, .new], changeHandler: effect(.portrait)),
            device.observe(\.isStudioLightActive, options: [.initial, .new], changeHandler: effect(.studioLight)),
            device.observe(\.isBackgroundReplacementActive, options: [.initial, .new],
                           changeHandler: effect(.backgroundReplacement)),
            device.observe(\.isCenterStageActive, options: [.initial, .new], changeHandler: effect(.centerStage)),
            device.observe(\.isSuspended, options: [.new]) { _, change in
                if change.newValue == true { feed.send(.lost(.suspended, hostTime: ScreenCapture.hostNow())) }
            },
        ]
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
                NSLog("HQ recorder: camera runtime error: \(note.userInfo?[AVCaptureSessionErrorKey] ?? "unknown")")
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

    /// The same camera came back: attach it again. Its next frame closes the gap.
    private func reconnect() {
        queue.async { [self] in
            guard !tokens.isEmpty else { return }
            session.beginConfiguration()
            do {
                let device = try attachDevice()
                session.commitConfiguration()
                observe(device)
            } catch {
                session.commitConfiguration()
                NSLog("HQ recorder: could not reattach the camera: \(error)")
            }
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
        guard sampleBuffer.isValid, let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CameraClock.hostSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                                          sessionClock: session.synchronizationClock)
        feed.send(.frame(SampleBox(buffer: sampleBuffer), hostPTS: pts,
                         width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image)))
    }
}
