// Measures audio/video sync in a saved recording, for the US-008 reference check.
// Reference procedure: record about 10 minutes with the screen, camera and microphone on. Near the
// start and again near the end, make a sharp sound (a clap) at the same moment as a full-screen
// white flash on a dark screen, in view of the camera. Then run
//   LocalScreenRecorder --measure-sync <path to the .hqrec package>
// It finds each flash in the screen and camera tracks and each sound onset in the narration, places
// both on the shared timeline, and saves the offsets at the start and end to sync-measurements.json
// in the package. The pass rule is an offset of 100 ms or less at both ends.

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

struct SyncMeasurementReport: Codable, Equatable, Sendable {
    var version = 1
    var measuredAt: String
    var toleranceSeconds: Double
    /// Each segment's duration in the manifest (host clock) next to the duration of its media file.
    var segments: [SegmentDrift]
    /// Narration sound onsets on the shared timeline, in seconds from the recording start.
    var audioMarkers: [Double]
    /// Offsets between the narration and each video track, one entry per video track.
    var tracks: [TrackOffset]
    /// True when every video track has start and end offsets within tolerance. Nil when markers
    /// were missing, so nothing could be judged.
    var passed: Bool?

    struct SegmentDrift: Codable, Equatable, Sendable {
        var kind: RecordingProject.Track.Kind
        var relativePath: String
        var manifestDurationSeconds: Double?
        var mediaDurationSeconds: Double?
        /// Media duration minus manifest duration.
        var driftSeconds: Double?
    }

    struct TrackOffset: Codable, Equatable, Sendable {
        var kind: RecordingProject.Track.Kind
        /// Flash onsets on the shared timeline, in seconds from the recording start.
        var videoMarkers: [Double]
        /// Video marker time minus audio marker time for the first matched pair. Positive means
        /// the picture is later than the sound.
        var startOffsetSeconds: Double?
        /// The same for the last matched pair.
        var endOffsetSeconds: Double?
        var matchedPairs: Int
        var passed: Bool?
    }
}

/// Finds the moment a signal turns on after a quiet stretch. Used for sound onsets (sample
/// amplitude) and for flashes (frame brightness).
struct OnsetDetector: Sendable {
    /// A value at or above this is the marker.
    let on: Double
    /// Values below this count as quiet.
    let quiet: Double
    /// How long the signal must have been quiet before a new onset counts.
    let minQuietSeconds: Double
    private var lastActive: Double?
    private var active = false
    /// Set when the signal leaves a long enough quiet stretch; cleared when a marker fires.
    private var armed = false

    init(on: Double, quiet: Double, minQuietSeconds: Double = 0.3) {
        self.on = on
        self.quiet = quiet
        self.minQuietSeconds = minQuietSeconds
    }

    /// Returns `time` when this value starts a new marker. The quiet stretch is judged where the
    /// signal first rises above `quiet`, so a sound that ramps up through the middle band (a sine
    /// starting at zero, encoder pre-echo) still counts.
    mutating func feed(_ value: Double, at time: Double) -> Double? {
        guard value >= quiet else {
            active = false
            return nil
        }
        if !active, lastActive.map({ time - $0 >= minQuietSeconds }) ?? true { armed = true }
        active = true
        lastActive = time
        guard value >= on, armed else { return nil }
        armed = false
        return time
    }
}

enum SyncMeasurement {
    static let toleranceSeconds = 0.1
    static let fileName = "sync-measurements.json"
    /// Sound onsets: a sample at -20 dBFS or louder after at least 0.3 s below -40 dBFS.
    static func audioDetector() -> OnsetDetector { OnsetDetector(on: 0.1, quiet: 0.01) }
    /// Flashes: mean brightness at or above half after at least 0.3 s below a third.
    static func videoDetector() -> OnsetDetector { OnsetDetector(on: 0.5, quiet: 0.33) }

    /// Pairs each audio marker with the nearest video marker within `window` seconds and
    /// returns (audio, video) pairs in time order.
    static func pair(audio: [Double], video: [Double], window: Double = 1) -> [(audio: Double, video: Double)] {
        var pairs: [(audio: Double, video: Double)] = []
        var used = Set<Int>()
        for a in audio.sorted() {
            let best = video.indices
                .filter { !used.contains($0) && abs(video[$0] - a) <= window }
                .min { abs(video[$0] - a) < abs(video[$1] - a) }
            guard let best else { continue }
            used.insert(best)
            pairs.append((a, video[best]))
        }
        return pairs
    }

    /// Start and end offsets for one video track against the narration markers.
    static func offset(kind: RecordingProject.Track.Kind, audio: [Double], video: [Double],
                       tolerance: Double = toleranceSeconds) -> SyncMeasurementReport.TrackOffset {
        let pairs = pair(audio: audio, video: video)
        let start = pairs.first.map { $0.video - $0.audio }
        let end = pairs.last.map { $0.video - $0.audio }
        let passed: Bool? = if let start, let end, pairs.count >= 2 {
            abs(start) <= tolerance && abs(end) <= tolerance
        } else {
            nil
        }
        return .init(kind: kind, videoMarkers: video, startOffsetSeconds: start, endOffsetSeconds: end,
                     matchedPairs: pairs.count, passed: passed)
    }

    /// Reads every segment of the package and measures drift and marker offsets. Media is only read.
    static func measure(package: URL, manifest: RecordingManifest,
                        tolerance: Double = toleranceSeconds) async throws -> SyncMeasurementReport {
        var drifts: [SyncMeasurementReport.SegmentDrift] = []
        var markers: [RecordingProject.Track.Kind: [Double]] = [:]
        for track in manifest.tracks {
            for segment in track.segments where segment.status != .missing {
                let url = try RecordingPackageStore.contained(segment.relativePath, in: package)
                let asset = AVURLAsset(url: url)
                let media = try await asset.load(.duration).seconds
                let mediaDuration = media.isFinite ? media : nil
                drifts.append(.init(kind: track.kind, relativePath: segment.relativePath,
                                    manifestDurationSeconds: segment.durationSeconds,
                                    mediaDurationSeconds: mediaDuration,
                                    driftSeconds: mediaDuration.flatMap { m in segment.durationSeconds.map { m - $0 } }))
                let found = track.kind == .microphone
                    ? try await audioMarkers(asset)
                    : try await videoMarkers(asset)
                markers[track.kind, default: []] += found.map { segment.startOffsetSeconds + $0 }
            }
        }
        let audio = (markers[.microphone] ?? []).sorted()
        let tracks = [RecordingProject.Track.Kind.screen, .camera].compactMap { kind in
            markers[kind].map { offset(kind: kind, audio: audio, video: $0.sorted(), tolerance: tolerance) }
        }
        let passed: Bool? = tracks.isEmpty || tracks.contains { $0.passed == nil }
            ? nil : tracks.allSatisfy { $0.passed == true }
        return .init(measuredAt: SessionStatus.now(), toleranceSeconds: tolerance, segments: drifts,
                     audioMarkers: audio, tracks: tracks, passed: passed)
    }

    /// Measures and saves the report into the package next to the manifest.
    @discardableResult
    static func measureAndSave(package: URL, store: RecordingPackageStore) async throws -> SyncMeasurementReport {
        let manifest = try store.readManifest(in: package)
        let report = try await measure(package: package, manifest: manifest)
        try store.writeJSON(report, to: fileName, in: package)
        return report
    }

    /// Sound onsets in seconds from the first audio sample of the file.
    static func audioMarkers(_ asset: AVURLAsset) async throws -> [Double] {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? SyncMeasurementError.unreadable }
        var detector = audioDetector()
        var onsets: [Double] = []
        var first: Double?
        while let sample = output.copyNextSampleBuffer() {
            guard let format = CMSampleBufferGetFormatDescription(sample),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                  asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0,
                  let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let base = first ?? pts
            first = base
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                              totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
                  let pointer else { throw SyncMeasurementError.unreadable }
            let channels = Int(asbd.mChannelsPerFrame)
            let frames = length / (4 * channels)
            pointer.withMemoryRebound(to: Float.self, capacity: frames * channels) { samples in
                for frame in 0..<frames {
                    var peak: Float = 0
                    for c in 0..<channels { peak = max(peak, abs(samples[frame * channels + c])) }
                    let time = pts - base + Double(frame) / asbd.mSampleRate
                    if let onset = detector.feed(Double(peak), at: time) { onsets.append(onset) }
                }
            }
        }
        guard reader.status == .completed else { throw reader.error ?? SyncMeasurementError.unreadable }
        return onsets
    }

    /// Flash onsets in seconds from the first frame of the file.
    static func videoMarkers(_ asset: AVURLAsset) async throws -> [Double] {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? SyncMeasurementError.unreadable }
        var detector = videoDetector()
        var onsets: [Double] = []
        var first: Double?
        while let sample = output.copyNextSampleBuffer() {
            guard let image = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let base = first ?? pts
            first = base
            if let onset = detector.feed(brightness(image), at: pts - base) { onsets.append(onset) }
        }
        guard reader.status == .completed else { throw reader.error ?? SyncMeasurementError.unreadable }
        return onsets
    }

    /// Mean brightness of a BGRA frame from 0 to 1, sampled on a grid.
    static func brightness(_ image: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(image) else { return 0 }
        let width = CVPixelBufferGetWidth(image)
        let height = CVPixelBufferGetHeight(image)
        let row = CVPixelBufferGetBytesPerRow(image)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var total = 0.0
        var count = 0
        for y in stride(from: 0, to: height, by: 8) {
            for x in stride(from: 0, to: width, by: 8) {
                let p = bytes + y * row + x * 4
                total += 0.114 * Double(p[0]) + 0.587 * Double(p[1]) + 0.299 * Double(p[2])
                count += 1
            }
        }
        return count == 0 ? 0 : total / Double(count) / 255
    }
}

enum SyncMeasurementError: Error, Equatable {
    case unreadable
    case notAPackage
}

/// `--measure-sync <package>`: measures a saved package, saves the report into it and prints it.
enum SyncMeasurementCLI {
    static let flag = "--measure-sync"

    /// Exit status when the flag is present: 0 passed, 1 failed or not measurable, 2 error.
    /// Nil when the app should launch normally.
    static func runIfRequested(_ arguments: [String]) -> Int32? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        guard arguments.indices.contains(index + 1) else {
            FileHandle.standardError.write(Data("usage: \(flag) <path to .hqrec package>\n".utf8))
            return 2
        }
        let package = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        let result = ResultBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            result.set(await run(package: package))
            done.signal()
        }
        done.wait()
        return result.value
    }

    static func run(package: URL) async -> Int32 {
        do {
            // The package's parent must be companies/<slug>/recordings, like every recording.
            let recordings = package.standardizedFileURL.deletingLastPathComponent()
            let company = recordings.deletingLastPathComponent().lastPathComponent
            let store = RecordingPackageStore(root: try RecordingsRoot.resolve(company: company, destination: recordings))
            let report = try await SyncMeasurement.measureAndSave(package: package, store: store)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            FileHandle.standardOutput.write(try encoder.encode(report) + Data("\n".utf8))
            return report.passed == true ? 0 : 1
        } catch {
            NSLog("HQ recorder: sync measurement failed: \(error)")
            FileHandle.standardError.write(Data("sync measurement failed: \(error)\n".utf8))
            return 2
        }
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Int32 = 2
        var value: Int32 { lock.withLock { stored } }
        func set(_ value: Int32) { lock.withLock { stored = value } }
    }
}
