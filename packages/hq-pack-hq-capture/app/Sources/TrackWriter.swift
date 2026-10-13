// TrackWriter — writes one video segment as a fragmented H.264 movie. Moved from
// Probes/LayeredCaptureProbe, where it kept closed segments playable when the
// writer failed mid-stream. Fragments are flushed every second, so a crash or a
// low-disk stop loses at most the last fragment.

import AVFoundation
import Foundation

final class TrackWriter: SegmentFinishing, @unchecked Sendable {
    let url: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let lock = NSLock()
    private(set) var firstPTS: Double?
    private(set) var lastPTS: Double?
    private(set) var frames = 0
    private(set) var dropped = 0
    private var closed = false
    private var finishTask: Task<Void, Never>?

    init(url: URL, width: Int, height: Int) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = true
        writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        writer.add(input)
    }

    /// `hostPTS` is the buffer's presentation time already converted to the host clock.
    func append(_ buffer: CMSampleBuffer, hostPTS: Double) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        if writer.status == .unknown {
            writer.startWriting()
            writer.startSession(atSourceTime: pts)
            firstPTS = hostPTS
        }
        guard writer.status == .writing else { return }
        if input.isReadyForMoreMediaData, input.append(buffer) {
            frames += 1
            lastPTS = hostPTS
        } else {
            dropped += 1
        }
    }

    var isClosed: Bool { lock.withLock { closed } }

    /// Non-nil once the asset writer has failed.
    var failure: String? {
        writer.status == .failed ? "\(writer.error.map { "\($0)" } ?? "unknown")" : nil
    }

    /// Closes the writer once; every caller awaits the same finishing task.
    private func closingTask() -> Task<Void, Never> {
        lock.withLock {
            if let finishTask { return finishTask }
            closed = true
            let task = Task<Void, Never> { [self] in
                if writer.status == .writing {
                    input.markAsFinished()
                    await writer.finishWriting()
                }
            }
            finishTask = task
            return task
        }
    }

    func finishSegment() async -> Double? {
        await closingTask().value
        return lock.withLock {
            guard let firstPTS, let lastPTS, frames > 0 else { return nil }
            return lastPTS - firstPTS
        }
    }
}

extension MicRecorder: SegmentFinishing {
    func finishSegment() async -> Double? {
        _ = await stop()
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else { return nil }
        return Double(file.length) / file.processingFormat.sampleRate
    }
}
