// Screen track capture. Frame gating, host-clock timestamps and segment rotation after a
// writer failure come from Probes/LayeredCaptureProbe (ScreenRecorder). US-002 showed the
// writer fails a few seconds after Presenter Overlay starts and that a fresh fragmented
// segment keeps recording, so the track rotates on every failure and at every effect boundary.

import AppKit
import CoreImage
import CoreMedia
import Foundation
import ScreenCaptureKit

/// A segment writer that takes host-clock video frames.
protocol FrameWriting: SegmentFinishing {
    func append(_ buffer: CMSampleBuffer, hostPTS: Double)
    /// Non-nil once the writer has failed and can take no more frames.
    var failure: String? { get }
}

extension TrackWriter: FrameWriting {}

/// Carries a sample buffer from the capture queue to the track actor. The buffer is not
/// touched again by the sender after it is sent.
struct SampleBox: @unchecked Sendable {
    let buffer: CMSampleBuffer
}

enum ScreenTrackEvent: Sendable {
    /// A complete frame. `hostPTS` is on the host clock, the shared capture timeline.
    case frame(SampleBox, hostPTS: Double, width: Int, height: Int)
    case effectStarted(hostTime: Double)
    case effectStopped(hostTime: Double)
}

enum ScreenTrackIssue: Equatable, Sendable {
    /// Presenter Overlay or another system effect is being drawn into the screen frames.
    case videoEffectStarted
    /// The track cannot write any more. The recording must stop with this reason.
    case failed(String)
}

/// Writes screen frames into rotating segments of the recording's screen track. Each segment
/// starts at its first frame's offset from the capture origin on the host clock.
actor ScreenTrack {
    typealias MakeWriter = @Sendable (URL, Int, Int) throws -> any FrameWriting

    let session: RecordingSession
    /// Host time the recording started. Every offset in the package is measured from here.
    let origin: Double
    /// Shared pause timeline. Frames inside a pause are not written, and offsets leave paused time out.
    let clock: RecordingClock
    private let makeWriter: MakeWriter
    private let onIssue: @Sendable (ScreenTrackIssue) -> Void
    private var writer: (any FrameWriting)?
    private var segmentURL: URL?
    private var width = 0
    private var height = 0
    private var framesInSegment = 0
    private var segmentEpoch = 0
    private var lastPTS: Double?
    private var rotatePending = false
    private var warned = false
    private(set) var failure: String?
    private(set) var framesWritten = 0
    private(set) var framesDropped = 0
    private(set) var framesPaused = 0

    init(session: RecordingSession, origin: Double, clock: RecordingClock? = nil,
         makeWriter: @escaping MakeWriter = { try TrackWriter(url: $0, width: $1, height: $2) },
         onIssue: @escaping @Sendable (ScreenTrackIssue) -> Void) {
        self.session = session
        self.origin = origin
        self.clock = clock ?? RecordingClock(origin: origin)
        self.makeWriter = makeWriter
        self.onIssue = onIssue
    }

    func handle(_ event: ScreenTrackEvent) async {
        switch event {
        case let .frame(box, pts, width, height):
            await write(box.buffer, pts: pts, width: width, height: height)
        case .effectStarted(let time):
            guard failure == nil else { return }
            do {
                try await session.beginVideoEffect(.presenterOverlay, atOffset: clock.offset(time))
            } catch {
                NSLog("HQ recorder: could not mark video effect start: \(error)")
            }
            rotatePending = writer != nil
            if !warned {
                warned = true
                onIssue(.videoEffectStarted)
            }
        case .effectStopped(let time):
            guard failure == nil else { return }
            do {
                try await session.endVideoEffect(atOffset: clock.offset(time))
            } catch {
                NSLog("HQ recorder: could not mark video effect end: \(error)")
            }
            rotatePending = writer != nil
        }
    }

    private func write(_ buffer: CMSampleBuffer, pts: Double, width: Int, height: Int) async {
        guard failure == nil else { return }
        // Frames from before the start, repeated or out of order cannot go on the timeline.
        guard pts.isFinite, pts >= origin, lastPTS.map({ pts > $0 }) ?? true else {
            framesDropped += 1
            return
        }
        // Paused time is left out of the output. The first frame after a resume opens a new
        // segment, so no segment file spans a pause.
        if clock.isPaused(at: pts) {
            framesPaused += 1
            lastPTS = pts
            return
        }
        if writer == nil || rotatePending || width != self.width || height != self.height
            || clock.epoch(at: pts) != segmentEpoch {
            guard await rotate(at: pts, width: width, height: height) else { return }
        }
        lastPTS = pts
        guard let current = writer else { return }
        current.append(buffer, hostPTS: pts)
        if current.failure == nil {
            framesInSegment += 1
            framesWritten += 1
            return
        }
        NSLog("HQ recorder: screen segment failed: \(current.failure ?? "unknown")")
        // Any writer failure, even on a segment's first frame, rolls to a fresh fragmented
        // segment and retries the frame once. A retry that fails too stops the track, so a
        // writer that can never write does not loop.
        guard await rotate(at: pts, width: width, height: height), let retry = writer else { return }
        retry.append(buffer, hostPTS: pts)
        if let error = retry.failure {
            NSLog("HQ recorder: screen segment failed again: \(error)")
            return fail("screen-writer-failed")
        }
        framesInSegment += 1
        framesWritten += 1
    }

    /// Closes the current segment and opens the next one at `pts`.
    private func rotate(at pts: Double, width: Int, height: Int) async -> Bool {
        do {
            if let segmentURL {
                writer = nil
                self.segmentURL = nil
                try await session.closeSegment(segmentURL)
            }
            let url = try await session.beginSegment(.screen, startOffsetSeconds: clock.offset(pts))
            let next = try makeWriter(url, width, height)
            try await session.attach(next, to: url)
            writer = next
            segmentURL = url
            self.width = width
            self.height = height
            framesInSegment = 0
            segmentEpoch = clock.epoch(at: pts)
            rotatePending = false
            return true
        } catch {
            NSLog("HQ recorder: could not start a screen segment: \(error)")
            fail("screen-segment-failed")
            return false
        }
    }

    private func fail(_ reason: String) {
        guard failure == nil else { return }
        failure = reason
        writer = nil
        onIssue(.failed(reason))
    }
}

/// Delivers capture events to the track in order, off the capture queue.
final class ScreenFeed: Sendable {
    private let continuation: AsyncStream<ScreenTrackEvent>.Continuation
    private let consumer: Task<Void, Never>

    init(track: ScreenTrack) {
        let (stream, continuation) = AsyncStream.makeStream(of: ScreenTrackEvent.self)
        self.continuation = continuation
        consumer = Task {
            for await event in stream { await track.handle(event) }
        }
    }

    func send(_ event: ScreenTrackEvent) { continuation.yield(event) }

    /// Stops taking events. Events already queued are still written.
    func close() { continuation.finish() }

    /// Stops taking events and waits until every queued event has been written.
    func drain() async {
        continuation.finish()
        await consumer.value
    }
}

/// Receives ScreenCaptureKit callbacks and turns them into track events.
final class ScreenStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.indigo.local-screen-recorder.screen")
    private let feed: ScreenFeed
    private let onStopped: @Sendable (String) -> Void
    private let preview: ScreenPreviewTap?

    init(feed: ScreenFeed, preview: ScreenPreviewTap? = nil, onStopped: @escaping @Sendable (String) -> Void) {
        self.feed = feed
        self.preview = preview
        self.onStopped = onStopped
    }

    /// Only complete frames carry new screen content; idle, blank and suspended frames are skipped.
    static func isCompleteFrame(_ info: [SCStreamFrameInfo: Any]?) -> Bool {
        guard let raw = info?[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        let info = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]])?.first
        guard Self.isCompleteFrame(info), let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // ScreenCaptureKit timestamps are already on the host clock.
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        feed.send(.frame(SampleBox(buffer: sampleBuffer), hostPTS: pts,
                         width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image)))
        preview?.offer(image, at: pts)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("HQ recorder: screen capture stopped by the system: \(error)")
        onStopped("capture-terminated")
    }

    func outputVideoEffectDidStart(for stream: SCStream) {
        feed.send(.effectStarted(hostTime: ScreenCapture.hostNow()))
    }

    func outputVideoEffectDidStop(for stream: SCStream) {
        feed.send(.effectStopped(hostTime: ScreenCapture.hostNow()))
    }
}

/// A window ScreenCaptureKit can see, reduced to what the filter plan needs.
struct CapturableWindow: Equatable, Sendable {
    var id: UInt32
    var processID: Int32
}

enum ScreenCaptureError: Error, Equatable {
    case sourceUnavailable
    /// The recorder's own window cannot be the recorded source.
    case ownWindow
    /// The capture was stopped before or while it was starting.
    case stopped
}

/// Which ScreenCaptureKit filter to build for a picked source.
enum ScreenCapturePlan: Equatable, Sendable {
    /// A whole display with the recorder app's own windows left out.
    case display(UInt32)
    /// One window on its own, so nothing on top of it is recorded.
    case window(UInt32)

    static func make(for source: ScreenSource, displayIDs: [UInt32], windows: [CapturableWindow],
                     ownProcessID: Int32) throws -> ScreenCapturePlan {
        switch source.kind {
        case .display:
            guard displayIDs.contains(source.id) else { throw ScreenCaptureError.sourceUnavailable }
            return .display(source.id)
        case .window:
            guard let window = windows.first(where: { $0.id == source.id }) else {
                throw ScreenCaptureError.sourceUnavailable
            }
            guard window.processID != ownProcessID else { throw ScreenCaptureError.ownWindow }
            return .window(source.id)
        }
    }
}

enum ScreenCapture {
    /// Now on the host clock, the same clock ScreenCaptureKit stamps frames with.
    static func hostNow() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    /// Pixel size for a capture: points times scale, rounded down to even for H.264.
    static func pixelSize(points: CGSize, scale: Double) -> (width: Int, height: Int) {
        func even(_ value: Double) -> Int { max(2, Int(value) & ~1) }
        return (even(points.width * scale), even(points.height * scale))
    }
}

/// The start and stop calls of a capture stream, so tests can stand in for ScreenCaptureKit.
protocol CaptureStreamControl: AnyObject, Sendable {
    func startCapture() async throws
    func stopCapture() async throws
}

/// ScreenCaptureKit's stream behind `CaptureStreamControl`.
final class ScreenKitStream: CaptureStreamControl, @unchecked Sendable {
    let stream: SCStream
    init(_ stream: SCStream) { self.stream = stream }
    func startCapture() async throws { try await stream.startCapture() }
    func stopCapture() async throws { try await stream.stopCapture() }
}

/// Orders start and stop for one capture stream. A stop that arrives while start is under way
/// waits until start returns and then stops the stream. A start after a stop is refused.
actor CaptureStartStop {
    private enum Phase {
        case idle
        case starting
        case running(any CaptureStreamControl)
        case stopped
    }

    private var phase = Phase.idle
    private var stopRequested = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    /// Claims the start. Throws `stopped` when a stop came first or a start already ran.
    func begin() throws {
        guard case .idle = phase else { throw ScreenCaptureError.stopped }
        phase = .starting
    }

    /// Starts `stream`, unless a stop came in first. A stop that arrives while the stream is
    /// starting stops it as soon as it has started, and this throws `stopped`.
    func run(_ stream: any CaptureStreamControl) async throws {
        guard !stopRequested else {
            finishStop()
            throw ScreenCaptureError.stopped
        }
        do {
            try await stream.startCapture()
        } catch {
            finishStop()
            throw stopRequested ? ScreenCaptureError.stopped : error
        }
        guard !stopRequested else {
            do {
                try await stream.stopCapture()
            } catch {
                NSLog("HQ recorder: stopping a capture that was stopped while starting failed: \(error)")
            }
            finishStop()
            throw ScreenCaptureError.stopped
        }
        phase = .running(stream)
    }

    /// Ends a start that failed before it had a stream.
    func abandon() { finishStop() }

    /// Stops the stream. When a start is under way, waits until that start has stopped it.
    func stop() async {
        switch phase {
        case .idle:
            phase = .stopped
        case .starting:
            stopRequested = true
            await withCheckedContinuation { stopWaiters.append($0) }
        case .running(let stream):
            phase = .stopped
            do {
                try await stream.stopCapture()
            } catch {
                NSLog("HQ recorder: stopping screen capture failed: \(error)")
            }
        case .stopped:
            break
        }
    }

    private func finishStop() {
        phase = .stopped
        let waiters = stopWaiters
        stopWaiters = []
        waiters.forEach { $0.resume() }
    }
}

/// One running ScreenCaptureKit stream. All stream calls happen inside this object.
final class ScreenCaptureRun: @unchecked Sendable {
    private let output: ScreenStreamOutput
    let feed: ScreenFeed
    private let gate = CaptureStartStop()

    init(track: ScreenTrack, preview: ScreenPreviewTap? = nil, onStopped: @escaping @Sendable (String) -> Void) {
        feed = ScreenFeed(track: track)
        output = ScreenStreamOutput(feed: feed, preview: preview, onStopped: onStopped)
    }

    /// Builds the filter for `source` and starts capture at 30 frames per second.
    func start(source: ScreenSource) async throws {
        try await start { [output] in try await Self.makeStream(source: source, output: output) }
    }

    /// Starts the stream `make` returns. Throws `ScreenCaptureError.stopped` when `stop()` was
    /// called first or while the stream was starting; the stream is stopped in that case.
    func start(making make: @Sendable () async throws -> any CaptureStreamControl) async throws {
        try await gate.begin()
        let stream: any CaptureStreamControl
        do {
            stream = try await make()
        } catch {
            await gate.abandon()
            throw error
        }
        try await gate.run(stream)
    }

    private static func makeStream(source: ScreenSource, output: ScreenStreamOutput) async throws
        -> any CaptureStreamControl {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let plan = try ScreenCapturePlan.make(
            for: source, displayIDs: content.displays.map(\.displayID),
            windows: content.windows.map { CapturableWindow(id: $0.windowID,
                                                            processID: $0.owningApplication?.processID ?? -1) },
            ownProcessID: ownPID)
        let filter: SCContentFilter
        switch plan {
        case .display(let id):
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                throw ScreenCaptureError.sourceUnavailable
            }
            let ownBundle = Bundle.main.bundleIdentifier
            let own = content.applications.filter { $0.processID == ownPID || $0.bundleIdentifier == ownBundle }
            filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                throw ScreenCaptureError.sourceUnavailable
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
        }
        let config = SCStreamConfiguration()
        let size = ScreenCapture.pixelSize(points: filter.contentRect.size, scale: Double(filter.pointPixelScale))
        config.width = size.width
        config.height = size.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.showsCursor = true
        config.queueDepth = 6
        let stream = SCStream(filter: filter, configuration: config, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        return ScreenKitStream(stream)
    }

    /// Stops capture, including one that is still starting, then waits until every frame
    /// delivered before the stop is written. Frames that arrive after the stop are dropped.
    func stop() async {
        feed.close()
        await gate.stop()
        await feed.drain()
    }
}

/// A low-rate copy of the screen frames being recorded, for the live preview. The recording
/// itself is untouched: the preview takes a still from a frame already delivered to the writer.
final class ScreenPreviewTap: @unchecked Sendable {
    /// Seconds between preview stills.
    let interval: Double
    private let lock = NSLock()
    private var lastSample: Double?
    private var image: CGImage?
    private let context = CIContext(options: [.cacheIntermediates: false])

    init(interval: Double = 0.2) { self.interval = interval }

    /// The most recent still, if any frame has arrived.
    var latest: CGImage? { lock.withLock { image } }

    /// True when a frame at `pts` should become the next still. Claims the slot when it does.
    func claim(_ pts: Double) -> Bool {
        lock.withLock {
            guard pts.isFinite else { return false }
            if let lastSample, pts >= lastSample, pts - lastSample < interval { return false }
            lastSample = pts
            return true
        }
    }

    func offer(_ buffer: CVPixelBuffer, at pts: Double) {
        guard claim(pts) else { return }
        guard let still = context.createCGImage(CIImage(cvPixelBuffer: buffer),
                                                from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(buffer),
                                                             height: CVPixelBufferGetHeight(buffer))) else {
            NSLog("HQ recorder: could not make a preview still from a screen frame")
            return
        }
        lock.withLock { image = still }
    }

    func clear() { lock.withLock { image = nil; lastSample = nil } }
}

/// Keeps the recorder's own windows (camera preview and controls) out of every capture.
@MainActor
enum CaptureHiding {
    static func hide(_ windows: [NSWindow]) {
        for window in windows { window.sharingType = .none }
    }

    /// Windows that must never be captured, such as the Recording badge and teleprompter,
    /// stay hidden after a recording ends.
    static func restore(_ windows: [NSWindow]) {
        for window in windows where !(window is NeverCapturedPanel) { window.sharingType = .readOnly }
    }
}
