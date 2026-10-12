// On-device transcription of a saved recording's narration, for `--transcribe`. The kept range of
// the microphone track is written to a temporary audio file and read by the system's on-device
// speech model. The result is saved as a new `transcripts/transcript-NNN.json` with word times on
// the recording timeline. The recorded media files are only read.

import AVFoundation
import Foundation
import Speech

/// One word or phrase with its times in seconds.
struct TranscriptWord: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
    var text: String
}

/// One transcribed phrase and the words in it.
struct TranscriptSegment: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
    var text: String
    var words: [TranscriptWord]
}

/// The transcript file. `segments` keeps the shape `NarrationTranscriptReader` reads; `words` adds
/// word-level times. Every time is in seconds on the recording timeline, not the trimmed file.
struct NarrationTranscript: Codable, Equatable, Sendable {
    var version = 1
    var createdAt: String
    var locale: String
    var onDeviceOnly: Bool
    /// The edit revision whose range was transcribed. 0 means no edit had been saved yet.
    var editRevision: Int
    /// The outer bounds of what was transcribed, on the recording timeline.
    var range: RecordingProject.TrimRange
    /// The kept ranges when the edit had middle cuts; the cut-out time was not transcribed.
    var kept: [RecordingProject.TrimRange]?
    var segments: [TranscriptSegment]
    var words: [TranscriptWord]
}

enum TranscriptionError: Error, Equatable, CustomStringConvertible {
    case noNarration
    case unsupportedLocale(String)
    case speechUnavailable

    var description: String {
        switch self {
        case .noNarration: "This recording has no microphone narration to transcribe."
        case .unsupportedLocale(let locale): "On-device transcription does not support the language \(locale)."
        case .speechUnavailable: "On-device transcription is not available on this Mac."
        }
    }
}

/// Turns an audio file into timed phrases. Times are seconds from the start of the file.
protocol NarrationTranscribing: Sendable {
    func transcribe(audio: URL, locale: Locale,
                    progress: @escaping @Sendable (String) -> Void) async throws -> (locale: String, segments: [TranscriptSegment])
}

/// The system's on-device speech model (SpeechAnalyzer with SpeechTranscriber). Audio never
/// leaves the Mac. The language model is downloaded once by the system when it is missing.
struct OnDeviceNarrationTranscriber: NarrationTranscribing {
    func transcribe(audio: URL, locale: Locale,
                    progress: @escaping @Sendable (String) -> Void) async throws -> (locale: String, segments: [TranscriptSegment]) {
        guard SpeechTranscriber.isAvailable else { throw TranscriptionError.speechUnavailable }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriptionError.unsupportedLocale(locale.identifier(.bcp47))
        }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            progress("installing the on-device speech model for \(supported.identifier(.bcp47))")
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () -> [TranscriptSegment] in
            var segments: [TranscriptSegment] = []
            for try await result in transcriber.results {
                var words: [TranscriptWord] = []
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let text = String(result.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    words.append(.init(start: range.start.seconds, end: range.end.seconds, text: text))
                }
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let start = words.first?.start ?? result.range.start.seconds
                let end = words.last?.end ?? result.range.end.seconds
                segments.append(.init(start: start, end: end, text: text, words: words))
            }
            return segments
        }
        progress("transcribing on device")
        let file = try AVAudioFile(forReading: audio)
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return (supported.identifier(.bcp47), try await collector.value)
    }
}

enum NarrationTranscription {
    static let folder = "transcripts"

    /// Transcribes the narration in the current edit range and saves it as a new transcript.
    /// Returns the saved transcript and its package-relative path.
    static func run(package: URL, store: RecordingPackageStore, locale: Locale,
                    engine: any NarrationTranscribing,
                    progress: @escaping @Sendable (String) -> Void) async throws -> (path: String, transcript: NarrationTranscript) {
        let document = try await TrimDocument.open(package, store: store)
        guard document.timeline.entries.contains(where: { $0.kind == .microphone }) else {
            throw TranscriptionError.noNarration
        }
        let ranges = try KeptRanges.resolve(trim: document.manifest.trim, kept: document.manifest.kept,
                                            duration: document.editor.duration)
        let outer = RecordingProject.TrimRange(start: ranges[0].start, end: ranges[ranges.count - 1].end)
        progress("preparing narration audio from \(format(outer.start))s to \(format(outer.end))s"
                 + (ranges.count > 1 ? " with \(ranges.count - 1) cut(s)" : ""))
        let audio = FileManager.default.temporaryDirectory
            .appendingPathComponent("hq-capture-narration-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: audio) }
        try await writeNarration(package: package, timeline: document.timeline, webcam: document.manifest.webcam,
                                 trim: document.manifest.trim, kept: document.manifest.kept, to: audio)
        let result = try await engine.transcribe(audio: audio, locale: locale, progress: progress)
        // Times in the transcribed audio are edited time; map them back onto the recording.
        func onRecording(_ seconds: Double, ending: Bool) -> Double {
            KeptRanges.recordingTime(edited: seconds, in: ranges, ending: ending) ?? outer.end
        }
        let segments = result.segments.map { segment in
            TranscriptSegment(start: onRecording(segment.start, ending: false),
                              end: onRecording(segment.end, ending: true), text: segment.text,
                              words: segment.words.map { .init(start: onRecording($0.start, ending: false),
                                                               end: onRecording($0.end, ending: true), text: $0.text) })
        }
        var manifest = document.manifest
        let transcript = NarrationTranscript(createdAt: SessionStatus.now(), locale: result.locale, onDeviceOnly: true,
                                             editRevision: manifest.edits.count, range: outer,
                                             kept: ranges.count > 1 ? ranges : nil,
                                             segments: segments, words: segments.flatMap(\.words))
        try store.ensureDirectory(folder, in: package)
        let path = try nextPath(manifest: manifest, package: package, store: store)
        try store.writeJSON(transcript, to: path, in: package)
        manifest.transcripts.append(path)
        do {
            try store.writeManifest(manifest, in: package)
        } catch {
            NSLog("HQ recorder: could not list the transcript in the manifest: \(error)")
            try? FileManager.default.removeItem(at: store.url(for: path, in: package))
            throw error
        }
        return (path, transcript)
    }

    /// The next `transcripts/transcript-NNN.json` that is neither on disk nor in the manifest.
    static func nextPath(manifest: RecordingManifest, package: URL, store: RecordingPackageStore) throws -> String {
        let used = Set(manifest.transcripts)
        var number = manifest.transcripts.count + 1
        while true {
            let path = "\(folder)/" + String(format: "transcript-%03d.json", number)
            if !used.contains(path), !FileManager.default.fileExists(atPath: try store.url(for: path, in: package).path) {
                return path
            }
            number += 1
        }
    }

    /// Writes only the microphone track of the kept range to an audio file.
    private static func writeNarration(package: URL, timeline: RecordingTimeline,
                                       webcam: RecordingProject.WebcamPlacement,
                                       trim: RecordingProject.TrimRange?, kept: [RecordingProject.TrimRange]?,
                                       to destination: URL) async throws {
        let playback = try await PlaybackLayers.trimmed(package: package, timeline: timeline, webcam: webcam,
                                                        trim: trim, kept: kept)
        guard playback.tracks[.microphone] != nil else { throw TranscriptionError.noNarration }
        for kind in [RecordingProject.Track.Kind.screen, .camera] {
            if let track = playback.tracks[kind] { playback.composition.removeTrack(track) }
        }
        guard let session = AVAssetExportSession(asset: playback.composition, presetName: AVAssetExportPresetAppleM4A)
        else { throw TranscriptionError.noNarration }
        try await session.export(to: destination, as: .m4a)
    }

    private static func format(_ seconds: Double) -> String { String(format: "%.2f", seconds) }
}
