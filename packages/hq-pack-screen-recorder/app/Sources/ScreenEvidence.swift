// Screen evidence for SOP drafts (US-014). Samples still frames from the clean screen track only
// (media/screen/segment-NNN.mov, recorded with the app's own windows excluded), never from the
// camera track or an editor render. Each sampled frame is read with on-device Vision text
// recognition, and the frames and recognized text are saved into the recording package as
// screenshots/evidence-NNN/screen-<ms>.png and screenshots/evidence-NNN/evidence.json, one folder
// per extraction. Nothing leaves the Mac.
//
// The evidence records only what was visible on screen at a source timestamp. Clicks, keystrokes
// and other input events are not captured by the recorder, and none are ever inferred here.
//
// When no frame has reliable text, the result is marked narration-only with a limitation, so the
// draft workflow continues from narration alone.

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Vision

/// One recognized line of screen text.
struct ScreenTextLine: Codable, Equatable, Sendable {
    var text: String
    /// Vision's confidence for the top candidate, 0 to 1.
    var confidence: Double
    /// Normalized to the frame (0 to 1), origin at the top-left corner.
    var boundingBox: Box

    struct Box: Codable, Equatable, Sendable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
    }
}

/// The saved evidence file, `screenshots/evidence-NNN/evidence.json`.
struct ScreenEvidence: Codable, Equatable, Sendable {
    static let provenance = "screen-track-sample"
    /// The recorder does not capture input events, and evidence never infers them.
    static let inputEventsNotRecorded = "not-recorded"

    var version = 1
    var extractedAt: String
    /// Always `screen`: frames come from the screen track's original segments only.
    var sourceTrack = RecordingProject.Track.Kind.screen
    var provenance = ScreenEvidence.provenance
    var inputEvents = ScreenEvidence.inputEventsNotRecorded
    var sampling: Sampling
    var frames: [Frame]
    /// Planned samples whose frame could not be decoded.
    var skipped: [Skipped]
    /// True when at least one frame has text at or above the confidence threshold.
    var ocrReliable: Bool
    /// Why the draft must rely on narration alone. Nil when the OCR evidence is reliable.
    var limitation: Limitation?

    enum Limitation: String, Codable, Sendable {
        /// The recording has no readable screen segment.
        case noScreenTrack = "no-screen-track"
        /// Screen segments exist but no frame could be decoded.
        case noScreenFrames = "no-screen-frames"
        /// Frames were sampled but none had text above the confidence threshold.
        case noReliableText = "no-reliable-screen-text"
    }

    struct Sampling: Codable, Equatable, Sendable {
        var intervalSeconds: Double
        var maxFrames: Int
        var minConfidence: Double
        var recognitionLevel = "accurate"
        var usesLanguageCorrection = true
        /// Samples the interval produced before the frame cap was applied.
        var plannedSamples: Int
        /// Samples dropped because a system effect drew the camera into the screen frames there.
        var excludedForCameraOverlay: Int
        /// True when the frame cap thinned the samples.
        var truncated: Bool
    }

    struct Frame: Codable, Equatable, Sendable {
        /// Package-relative screen segment the frame was decoded from.
        var sourceSegment: String
        /// Time of the decoded frame inside the segment file, in seconds.
        var sourceSeconds: Double
        /// The same moment on the recording timeline (segment start offset plus source time).
        var timelineSeconds: Double
        /// Package-relative PNG of the frame.
        var image: String
        var width: Int
        var height: Int
        var provenance = ScreenEvidence.provenance
        /// Lines at or above the confidence threshold.
        var lines: [ScreenTextLine]
        /// Lines Vision found but dropped as too uncertain or too short.
        var droppedLines: Int
        /// Set when text recognition failed for this frame; the screenshot is still kept.
        var ocrError: String?
    }

    struct Skipped: Codable, Equatable, Sendable {
        var sourceSegment: String
        var sourceSeconds: Double
        var reason: String
    }
}

/// What the draft workflow receives after extraction.
struct ScreenEvidenceResult: Equatable, Sendable {
    var evidence: ScreenEvidence
    /// Package-relative path of the evidence file.
    var evidencePath: String
    var manifest: RecordingManifest

    var ocrReliable: Bool { evidence.ocrReliable }
    var limitation: ScreenEvidence.Limitation? { evidence.limitation }
    /// The `source` a draft records: screen text plus narration, or narration alone and why.
    var draftSource: String {
        if let limitation { "narration-only:\(limitation.rawValue)" } else { "narration+screen-text" }
    }
}

/// Sampling limits. Values outside the hard bounds are clamped.
struct ScreenEvidenceOptions: Equatable, Sendable {
    static let minimumInterval = 0.5
    static let hardMaxFrames = 120

    var intervalSeconds = 5.0
    var maxFrames = 40
    var minConfidence = 0.5
    /// Longest side of a saved screenshot, in pixels.
    var maxImageDimension = 1_920

    var bounded: ScreenEvidenceOptions {
        var copy = self
        copy.intervalSeconds = intervalSeconds.isFinite ? max(Self.minimumInterval, intervalSeconds) : 5
        copy.maxFrames = min(max(1, maxFrames), Self.hardMaxFrames)
        copy.minConfidence = minConfidence.isFinite ? min(max(0, minConfidence), 1) : 0.5
        copy.maxImageDimension = min(max(320, maxImageDimension), 4_096)
        return copy
    }
}

/// A decoded frame and the time it actually sits at in the file.
struct SampledFrame {
    var image: CGImage
    var actualSeconds: Double
}

/// Decodes frames from one media file. AVFoundation in the app, a fake in tests.
protocol ScreenFrameSampling: Sendable {
    func duration(of url: URL) async throws -> Double
    func frame(of url: URL, at seconds: Double, maxDimension: Int) async throws -> SampledFrame
}

/// Reads text in one image. Vision in the app, a fake in tests.
protocol ScreenTextRecognizing: Sendable {
    func recognize(_ image: CGImage) throws -> [ScreenTextLine]
}

struct AVFrameSampler: ScreenFrameSampling {
    func duration(of url: URL) async throws -> Double {
        try await AVURLAsset(url: url).load(.duration).seconds
    }

    func frame(of url: URL, at seconds: Double, maxDimension: Int) async throws -> SampledFrame {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        // Exact frames, so the recorded source time is the time of the pixels saved.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, actual) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        return SampledFrame(image: image, actualSeconds: actual.seconds.isFinite ? actual.seconds : seconds)
    }
}

/// On-device text recognition with Vision's accurate level and language correction.
struct VisionTextRecognizer: ScreenTextRecognizing {
    func recognize(_ image: CGImage) throws -> [ScreenTextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return ScreenTextLine(text: candidate.string, confidence: Double(candidate.confidence),
                                  boundingBox: .init(x: box.minX, y: 1 - box.maxY,
                                                     width: box.width, height: box.height))
        }
    }
}

enum ScreenEvidenceError: Error, Equatable {
    case imageEncoding
}

enum ScreenEvidenceExtractor {
    /// The single evidence file older versions wrote. Still read when a manifest points at it.
    static let evidencePath = "screenshots/evidence.json"
    /// Frames older versions wrote straight into `screenshots/`.
    static let imagePrefix = "screenshots/screen-"
    /// Each extraction writes its evidence and frames into its own `screenshots/evidence-NNN/`.
    static let revisionPrefix = "screenshots/evidence-"

    static func revisionFolder(_ number: Int) -> String { revisionPrefix + String(format: "%03d", number) }

    struct PlannedSample: Equatable, Sendable {
        var segment: String
        var segmentStart: Double
        var sourceSeconds: Double
        var timelineSeconds: Double { segmentStart + sourceSeconds }
    }

    struct Plan: Equatable, Sendable {
        var samples: [PlannedSample]
        var planned: Int
        var excludedForCameraOverlay: Int
        var truncated: Bool
    }

    /// Picks sample times on the screen track: every `intervalSeconds` from half an interval in
    /// (or the middle of a shorter segment), skipping ranges where Presenter Overlay flattened the
    /// camera into the screen, then thinned evenly to at most `maxFrames`.
    static func plan(manifest: RecordingManifest, durations: [String: Double],
                     options: ScreenEvidenceOptions) -> Plan {
        let options = options.bounded
        let overlays = (manifest.videoEffects ?? []).filter(\.flattened)
        var all: [PlannedSample] = []
        var excluded = 0
        for track in manifest.tracks where track.kind == .screen {
            for segment in track.segments where segment.status == .closed {
                guard let duration = durations[segment.relativePath], duration.isFinite, duration > 0 else { continue }
                let first = min(options.intervalSeconds / 2, duration / 2)
                for t in stride(from: first, to: duration, by: options.intervalSeconds) {
                    let sample = PlannedSample(segment: segment.relativePath,
                                               segmentStart: segment.startOffsetSeconds, sourceSeconds: t)
                    let onTimeline = sample.timelineSeconds
                    if overlays.contains(where: { onTimeline >= $0.startOffsetSeconds
                                                    && onTimeline < ($0.endOffsetSeconds ?? .infinity) }) {
                        excluded += 1
                        continue
                    }
                    all.append(sample)
                }
            }
        }
        all.sort { $0.timelineSeconds < $1.timelineSeconds }
        let planned = all.count
        guard planned > options.maxFrames else {
            return Plan(samples: all, planned: planned, excludedForCameraOverlay: excluded, truncated: false)
        }
        let step = Double(planned) / Double(options.maxFrames)
        let picked = (0..<options.maxFrames).map { all[min(planned - 1, Int(Double($0) * step + step / 2))] }
        return Plan(samples: picked, planned: planned, excludedForCameraOverlay: excluded, truncated: true)
    }

    /// Keeps lines at or above the confidence threshold with at least two letters or digits.
    static func reliableLines(_ lines: [ScreenTextLine], minConfidence: Double) -> [ScreenTextLine] {
        lines.filter { line in
            line.confidence >= minConfidence
                && line.text.unicodeScalars.filter(CharacterSet.alphanumerics.contains).count >= 2
        }
    }

    static func imagePath(timelineSeconds: Double, in folder: String) -> String {
        String(format: "\(folder)/screen-%09d.png", Int((timelineSeconds * 1_000).rounded()))
    }

    static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)
        else { throw ScreenEvidenceError.imageEncoding }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ScreenEvidenceError.imageEncoding }
        return data as Data
    }

    /// Samples the screen track of a saved package, reads its text on device, and saves the
    /// screenshots and evidence into a new `screenshots/evidence-NNN/` folder, and points the
    /// manifest at them under the package lock.
    /// Every write goes through the store, so it stays inside the company recordings folder.
    static func extract(package: URL, store: RecordingPackageStore,
                        options: ScreenEvidenceOptions = .init(),
                        sampler: any ScreenFrameSampling = AVFrameSampler(),
                        recognizer: any ScreenTextRecognizing = VisionTextRecognizer(),
                        syncChecker: any SyncChecking = HQSyncCLIChecker()) async throws -> ScreenEvidenceResult {
        let options = options.bounded
        let manifest = try store.readManifest(in: package)
        guard manifest.state == .saved || manifest.state == .interrupted else { throw PackageError.stillRecording }

        var durations: [String: Double] = [:]
        var skipped: [ScreenEvidence.Skipped] = []
        let screenSegments = manifest.tracks.filter { $0.kind == .screen }
            .flatMap(\.segments).filter { $0.status == .closed }
        for segment in screenSegments {
            let url = try store.url(for: segment.relativePath, in: package)
            if let known = segment.durationSeconds, known.isFinite, known > 0 {
                durations[segment.relativePath] = known
                continue
            }
            do {
                durations[segment.relativePath] = try await sampler.duration(of: url)
            } catch {
                NSLog("HQ recorder: screen evidence could not read \(segment.relativePath): \(error)")
                skipped.append(.init(sourceSegment: segment.relativePath, sourceSeconds: 0,
                                     reason: "unreadable: \(error)"))
            }
        }

        let plan = plan(manifest: manifest, durations: durations, options: options)
        // This extraction's own folder, reserved by creating it, so an extraction running at the
        // same time never writes over these frames or this evidence file.
        try store.ensureDirectory("screenshots", in: package)
        let taken = try FileManager.default.contentsOfDirectory(atPath: store.url(for: "screenshots", in: package).path)
            .compactMap { name in name.hasPrefix("evidence-") ? Int(name.dropFirst("evidence-".count)) : nil }
        let folder = try store.reserveFolder(revisionFolder, from: (taken.max() ?? 0) + 1, in: package).path
        do {
            return try await extract(into: folder, package: package, store: store, manifest: manifest, plan: plan,
                                     options: options, skipped: skipped, screenSegments: screenSegments,
                                     sampler: sampler, recognizer: recognizer, syncChecker: syncChecker)
        } catch {
            NSLog("HQ recorder: screen evidence stopped, removing \(folder): \(error)")
            remove([folder], package: package, store: store)
            throw error
        }
    }

    private static func extract(into folder: String, package: URL, store: RecordingPackageStore,
                                manifest: RecordingManifest, plan: Plan, options: ScreenEvidenceOptions,
                                skipped: [ScreenEvidence.Skipped], screenSegments: [RecordingManifest.Segment],
                                sampler: any ScreenFrameSampling, recognizer: any ScreenTextRecognizing,
                                syncChecker: any SyncChecking) async throws -> ScreenEvidenceResult {
        var skipped = skipped
        let evidencePath = folder + "/evidence.json"
        var frames: [ScreenEvidence.Frame] = []
        var images: [(path: String, data: Data)] = []
        for sample in plan.samples {
            let url = try store.url(for: sample.segment, in: package)
            let decoded: SampledFrame
            do {
                decoded = try await sampler.frame(of: url, at: sample.sourceSeconds,
                                                  maxDimension: options.maxImageDimension)
            } catch {
                NSLog("HQ recorder: screen evidence skipped \(sample.segment) at \(sample.sourceSeconds): \(error)")
                skipped.append(.init(sourceSegment: sample.segment, sourceSeconds: sample.sourceSeconds,
                                     reason: "frame-unavailable: \(error)"))
                continue
            }
            let path = imagePath(timelineSeconds: sample.timelineSeconds, in: folder)
            images.append((path, try png(decoded.image)))
            var found: [ScreenTextLine] = []
            var ocrError: String?
            do {
                found = try recognizer.recognize(decoded.image)
            } catch {
                NSLog("HQ recorder: text recognition failed for \(path): \(error)")
                ocrError = "\(error)"
            }
            let kept = reliableLines(found, minConfidence: options.minConfidence)
            frames.append(.init(sourceSegment: sample.segment, sourceSeconds: decoded.actualSeconds,
                                timelineSeconds: sample.segmentStart + decoded.actualSeconds, image: path,
                                width: decoded.image.width, height: decoded.image.height,
                                lines: kept, droppedLines: found.count - kept.count, ocrError: ocrError))
        }

        let reliable = frames.contains { !$0.lines.isEmpty }
        let limitation: ScreenEvidence.Limitation? =
            if reliable { nil }
            else if screenSegments.isEmpty { .noScreenTrack }
            else if frames.isEmpty { .noScreenFrames }
            else { .noReliableText }
        let evidence = ScreenEvidence(
            extractedAt: SessionStatus.now(),
            sampling: .init(intervalSeconds: options.intervalSeconds, maxFrames: options.maxFrames,
                            minConfidence: options.minConfidence, plannedSamples: plan.planned,
                            excludedForCameraOverlay: plan.excludedForCameraOverlay, truncated: plan.truncated),
            frames: frames, skipped: skipped, ocrReliable: reliable, limitation: limitation)

        for image in images { try store.writeData(image.data, to: image.path, in: package) }
        try store.writeJSON(evidence, to: evidencePath, in: package)

        let newImages = Set(images.map(\.path))
        // New files in the package: the last sync result no longer covers them. Checked before the
        // package lock is taken, so a slow check never holds up another command's save.
        let sync = RecordingManifest.Sync(await syncChecker.observe(vaultKey: manifest.vaultKey), at: SessionStatus.now())
        var stale: [String] = []
        var replaced: [String] = []
        let saved = try store.mutateManifest(in: package) { latest in
            // The manifest moves to this extraction's evidence, whose frames are all in its folder.
            // A frame or evidence file that a saved draft revision or an exported guide still uses
            // is kept, along with its manifest entry. Only files nothing points at are removed.
            let referenced = referencedScreenshots(latest, in: package, store: store)
            let old = latest.screenshots.filter {
                ($0.hasPrefix(imagePrefix) || $0.hasPrefix(revisionPrefix)) && !newImages.contains($0)
            }
            stale = referenced.map { keep in old.filter { !keep.contains($0) } } ?? []
            if let previous = latest.screenEvidence, previous != evidencePath,
               let keep = referenced, !keep.contains(previous) { replaced = [previous] }
            latest.screenshots = latest.screenshots.filter { !stale.contains($0) && !newImages.contains($0) }
                + images.map(\.path)
            latest.screenEvidence = evidencePath
            latest.sync = sync
        }
        remove(stale + replaced, package: package, store: store)
        return ScreenEvidenceResult(evidence: evidence, evidencePath: evidencePath, manifest: saved)
    }

    /// Removes package files, then any older extraction folder left empty. A failure is logged and
    /// the file left in place.
    private static func remove(_ paths: [String], package: URL, store: RecordingPackageStore) {
        var folders: Set<String> = []
        for path in paths {
            if path.hasPrefix(revisionPrefix) {
                folders.insert(path.split(separator: "/").prefix(2).joined(separator: "/"))
            }
            do {
                try FileManager.default.removeItem(at: store.url(for: path, in: package))
            } catch {
                NSLog("HQ recorder: could not remove old screen evidence \(path): \(error)")
            }
        }
        for folder in folders {
            do {
                let url = try store.url(for: folder, in: package)
                guard FileManager.default.fileExists(atPath: url.path),
                      try FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty else { continue }
                try FileManager.default.removeItem(at: url)
            } catch {
                NSLog("HQ recorder: could not remove old screen evidence folder \(folder): \(error)")
            }
        }
    }

    /// Every `screenshots/` path named in any saved draft revision or exported guide record, or nil when
    /// one of them cannot be read. On nil the caller keeps every old frame, since it cannot tell
    /// which ones are still in use.
    static func referencedScreenshots(_ manifest: RecordingManifest, in package: URL,
                                      store: RecordingPackageStore) -> Set<String>? {
        var found: Set<String> = []
        func collect(_ value: Any) {
            switch value {
            case let text as String where text.hasPrefix("screenshots/"): found.insert(text)
            case let list as [Any]: list.forEach(collect)
            case let object as [String: Any]: object.values.forEach(collect)
            default: break
            }
        }
        let records = (manifest.exports ?? []).filter { $0.hasSuffix("/export.json") }
        do {
            for path in manifest.drafts.map(\.relativePath) {
                let draft = try JSONDecoder().decode(DraftRevision.self,
                                                     from: Data(contentsOf: store.url(for: path, in: package)))
                // A recording-stopped placeholder has an empty body and names no screenshot.
                guard !draft.body.isEmpty else { continue }
                collect(try JSONSerialization.jsonObject(with: Data(draft.body.utf8), options: [.fragmentsAllowed]))
            }
            for path in records {
                collect(try JSONSerialization.jsonObject(with: Data(contentsOf: store.url(for: path, in: package))))
            }
        } catch {
            NSLog("HQ recorder: could not read the drafts and exports that use screenshots, keeping every old frame: \(error)")
            return nil
        }
        return found
    }
}

/// `--extract-screen-evidence <package>`: samples the screen track of a saved package, saves the
/// screenshots and evidence into it and prints the evidence. Exit 0 when the OCR text is reliable,
/// 1 when the draft must use narration alone, 2 on error.
enum ScreenEvidenceCLI {
    static let flag = "--extract-screen-evidence"

    static func runIfRequested(_ arguments: [String]) -> Int32? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        guard arguments.indices.contains(index + 1) else {
            FileHandle.standardError.write(Data("usage: \(flag) <path to .hqrec package>\n".utf8))
            return 2
        }
        let package = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        let result = StatusBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            result.set(await run(package: package))
            done.signal()
        }
        done.wait()
        return result.value
    }

    static func run(package: URL, sampler: any ScreenFrameSampling = AVFrameSampler(),
                    recognizer: any ScreenTextRecognizing = VisionTextRecognizer(),
                    syncChecker: any SyncChecking = HQSyncCLIChecker()) async -> Int32 {
        do {
            let recordings = package.standardizedFileURL.deletingLastPathComponent()
            let company = recordings.deletingLastPathComponent().lastPathComponent
            let store = RecordingPackageStore(root: try RecordingsRoot.resolve(company: company, destination: recordings))
            let result = try await ScreenEvidenceExtractor.extract(package: package, store: store, sampler: sampler,
                                                                   recognizer: recognizer, syncChecker: syncChecker)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            FileHandle.standardOutput.write(try encoder.encode(result.evidence) + Data("\n".utf8))
            return result.ocrReliable ? 0 : 1
        } catch {
            NSLog("HQ recorder: screen evidence failed: \(error)")
            FileHandle.standardError.write(Data("screen evidence failed: \(error)\n".utf8))
            return 2
        }
    }

    private final class StatusBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Int32 = 2
        var value: Int32 { lock.withLock { stored } }
        func set(_ value: Int32) { lock.withLock { stored = value } }
    }
}
