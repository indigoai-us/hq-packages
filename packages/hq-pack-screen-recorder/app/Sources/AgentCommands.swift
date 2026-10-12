// Headless commands the HQ session agent uses to work with a saved recording after the app has
// captured it: describe, transcribe, edit, export and render one frame. They run in the app's own
// binary, check the package is inside `companies/<slug>/recordings` like every other mode, and
// never change the recorded media. Edits are new revision files; exports and transcripts are new
// files. `--json` prints one JSON object on stdout; without it the result is a few plain lines.
//
// Exit codes: 0 done, 1 refused (nothing written), 2 bad arguments or a failure, 130 cancelled.

import AVFoundation
import Foundation
import ImageIO

/// One parsed agent command.
struct AgentInvocation: Equatable, Sendable {
    var command: AgentCommand
    var package: URL
    var json: Bool
}

enum AgentCommand: Equatable, Sendable {
    case describe
    case transcribe(locale: String?)
    case edit(AgentEditRequest)
    case exportVideo
    case frame(at: Double, out: URL)
}

/// The changes `--edit` asks for. Nil fields keep the current value.
struct AgentEditRequest: Equatable, Sendable {
    struct Camera: Equatable, Sendable {
        var x: Double
        var y: Double
        var width: Double
    }

    var start: Double?
    var end: Double?
    /// `--cut a-b` values. The edit model keeps one range, so any cut is refused.
    var cuts: [String] = []
    var camera: Camera?
    var cameraHidden: Bool?
}

enum AgentCommandError: Error, Equatable, CustomStringConvertible {
    /// The arguments are wrong. Exit 2.
    case usage(String)
    /// The request is understood but not allowed; nothing was written. Exit 1.
    case refused(String)

    var description: String {
        switch self {
        case .usage(let message), .refused(let message): message
        }
    }
}

enum AgentCommandsCLI {
    static let modes = ["--describe", "--transcribe", "--edit", "--export-video", "--frame"]
    static let jsonFlag = "--json"

    static let usage = """
        usage:
          --describe <package> [--json]
          --transcribe <package> [--locale <id>] [--json]
          --edit <package> [--in <seconds>] [--out <seconds>] [--camera <x,y,width>] [--camera-hidden true|false] [--json]
          --export-video <package> [--json]
          --frame <package> --at <seconds> --out <file.png> [--json]
        """

    /// Options each mode takes, besides `--json`. Each one takes a value.
    private static let options: [String: Set<String>] = [
        "--describe": [],
        "--transcribe": ["--locale"],
        "--edit": ["--in", "--out", "--cut", "--camera", "--camera-hidden"],
        "--export-video": [],
        "--frame": ["--at", "--out"],
    ]

    // MARK: Parsing

    /// The agent command in `arguments`, nil when none of the agent modes is present. The first
    /// argument is the executable and is skipped. Arguments with a single dash, such as the
    /// `-NSDocumentRevisionsDebugMode` pair Xcode adds, are left alone.
    static func parse(_ arguments: [String]) throws -> AgentInvocation? {
        let rest = Array(arguments.dropFirst())
        let present = modes.filter(rest.contains)
        guard let mode = present.first else { return nil }
        guard present.count == 1 else {
            throw AgentCommandError.usage("Use one agent command at a time, not \(present.joined(separator: " and ")).")
        }
        let allowed = options[mode] ?? []
        var package: URL?
        var values: [String: [String]] = [:]
        var json = false
        var index = 0
        while index < rest.count {
            let argument = rest[index]
            if argument == mode {
                guard rest.indices.contains(index + 1), !rest[index + 1].hasPrefix("--") else {
                    throw AgentCommandError.usage("\(mode) needs the path to a .hqrec package.")
                }
                package = URL(fileURLWithPath: rest[index + 1], isDirectory: true)
                index += 2
            } else if argument == jsonFlag {
                json = true
                index += 1
            } else if allowed.contains(argument) {
                guard rest.indices.contains(index + 1) else {
                    throw AgentCommandError.usage("\(argument) needs a value.")
                }
                values[argument, default: []].append(rest[index + 1])
                index += 2
            } else if argument.hasPrefix("--") {
                throw AgentCommandError.usage("\(mode) does not take \(argument).")
            } else {
                index += 1
            }
        }
        guard let package else { throw AgentCommandError.usage("\(mode) needs the path to a .hqrec package.") }
        for (name, list) in values where list.count > 1 && name != "--cut" {
            throw AgentCommandError.usage("Give \(name) once.")
        }
        let command: AgentCommand
        switch mode {
        case "--describe": command = .describe
        case "--transcribe": command = .transcribe(locale: values["--locale"]?.first)
        case "--export-video": command = .exportVideo
        case "--edit":
            var request = AgentEditRequest()
            request.start = try values["--in"]?.first.map { try seconds($0, option: "--in") }
            request.end = try values["--out"]?.first.map { try seconds($0, option: "--out") }
            request.cuts = values["--cut"] ?? []
            request.camera = try values["--camera"]?.first.map(camera)
            request.cameraHidden = try values["--camera-hidden"]?.first.map(flag)
            command = .edit(request)
        default:
            guard let at = values["--at"]?.first else { throw AgentCommandError.usage("--frame needs --at <seconds>.") }
            guard let out = values["--out"]?.first, !out.isEmpty else {
                throw AgentCommandError.usage("--frame needs --out <file.png>.")
            }
            command = .frame(at: try seconds(at, option: "--at"), out: URL(fileURLWithPath: out))
        }
        return AgentInvocation(command: command, package: package, json: json)
    }

    private static func seconds(_ text: String, option: String) throws -> Double {
        guard let value = Double(text), value.isFinite else {
            throw AgentCommandError.usage("\(option) needs a number of seconds, not \(text).")
        }
        return value
    }

    private static func camera(_ text: String) throws -> AgentEditRequest.Camera {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false).map {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        guard parts.count == 3, let x = parts[0], let y = parts[1], let width = parts[2],
              x.isFinite, y.isFinite, width.isFinite else {
            throw AgentCommandError.usage("--camera needs three numbers x,y,width, such as 0.8,0.8,0.18.")
        }
        return .init(x: x, y: y, width: width)
    }

    private static func flag(_ text: String) throws -> Bool {
        switch text {
        case "true": return true
        case "false": return false
        default: throw AgentCommandError.usage("--camera-hidden needs true or false, not \(text).")
        }
    }

    // MARK: Running

    static func runIfRequested(_ arguments: [String]) -> Int32? {
        let invocation: AgentInvocation
        do {
            guard let parsed = try parse(arguments) else { return nil }
            invocation = parsed
        } catch {
            NSLog("HQ recorder: agent command arguments refused: \(error)")
            FileHandle.standardError.write(Data("\(error)\n\(usage)\n".utf8))
            return 2
        }
        let result = StatusBox()
        let done = DispatchSemaphore(value: 0)
        let task = Task.detached {
            result.set(await run(invocation))
            done.signal()
        }
        // Ctrl-C during an export cancels it; the export removes its unfinished file.
        var interrupt: DispatchSourceSignal?
        if invocation.command == .exportVideo {
            signal(SIGINT, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
            source.setEventHandler { task.cancel() }
            source.resume()
            interrupt = source
        }
        done.wait()
        interrupt?.cancel()
        return result.value
    }

    /// Runs one command, prints its result and returns the exit code.
    static func run(_ invocation: AgentInvocation,
                    engine: any NarrationTranscribing = OnDeviceNarrationTranscriber()) async -> Int32 {
        do {
            let store = try store(for: invocation.package)
            let report = try await execute(invocation, store: store, engine: engine, progress: { line in
                FileHandle.standardError.write(Data("progress: \(line)\n".utf8))
            })
            if invocation.json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                FileHandle.standardOutput.write(try encoder.encode(report) + Data("\n".utf8))
            } else {
                FileHandle.standardOutput.write(Data((report.lines.joined(separator: "\n") + "\n").utf8))
            }
            return 0
        } catch let error as AgentCommandError {
            NSLog("HQ recorder: agent command stopped: \(error)")
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            if case .usage = error { return 2 }
            return 1
        } catch is CancellationError {
            NSLog("HQ recorder: agent command cancelled")
            FileHandle.standardError.write(Data("Cancelled. No file was written.\n".utf8))
            return 130
        } catch {
            NSLog("HQ recorder: agent command failed: \(error)")
            FileHandle.standardError.write(Data("\(message(for: error))\n".utf8))
            return 2
        }
    }

    /// The package store for a package at `<recordings>/<name>.hqrec`, refused when the folder is
    /// not `companies/<slug>/recordings`.
    static func store(for package: URL) throws -> RecordingPackageStore {
        let recordings = package.standardizedFileURL.deletingLastPathComponent()
        let company = recordings.deletingLastPathComponent().lastPathComponent
        return RecordingPackageStore(root: try RecordingsRoot.resolve(company: company, destination: recordings))
    }

    static func execute(_ invocation: AgentInvocation, store: RecordingPackageStore,
                        engine: any NarrationTranscribing,
                        progress: @escaping @Sendable (String) -> Void) async throws -> AgentReport {
        let package = invocation.package
        switch invocation.command {
        case .describe:
            return .describe(try await describe(package: package, store: store))
        case .transcribe(let locale):
            return .transcribe(try await transcribe(package: package, store: store, locale: locale,
                                                    engine: engine, progress: progress))
        case .edit(let request):
            return .edit(try await edit(request, package: package, store: store))
        case .exportVideo:
            return .export(try await exportVideo(package: package, store: store))
        case .frame(let at, let out):
            return .frame(try await frame(at: at, out: out, package: package, store: store))
        }
    }

    /// Plain words for an error from the package store or the media layers.
    static func message(for error: any Error) -> String {
        switch error {
        case let error as AgentCommandError: return error.description
        case let error as TranscriptionError: return error.description
        case let error as TrimEditor.TrimError: return trimMessage(error)
        case PackageError.outsideCompanyRecordings, PackageError.invalidCompany:
            return "The package must be inside companies/<company>/recordings."
        case PackageError.notAPackage: return "That folder is not a recording package."
        case PackageError.stillRecording: return "The recording has not finished saving yet."
        case PackageError.companyMismatch: return "The package belongs to another company."
        case PackageError.lowDiskSpace: return "There isn't enough free space. Free up some space and try again."
        default: return "The command failed: \(error)"
        }
    }

    static func trimMessage(_ error: TrimEditor.TrimError) -> String {
        switch error {
        case .emptyRecording: "This recording has no playable video."
        case .tooShort: "Keep at least a tenth of a second between the start and the end."
        case .invalidRange: "The start has to be zero or later."
        case .outsideRecording: "The end is past the end of the recording."
        case .exportMismatch: "The exported video didn't come out the right length, so it wasn't kept."
        }
    }

    // MARK: --edit

    static func edit(_ request: AgentEditRequest, package: URL,
                     store: RecordingPackageStore) async throws -> AgentEditResult {
        let unchanged = "No revision was written."
        guard request.cuts.isEmpty else {
            throw AgentCommandError.refused("Cutting out a middle range (--cut) is not supported. An edit keeps one "
                                            + "range, set with --in and --out. \(unchanged)")
        }
        guard request.start != nil || request.end != nil || request.camera != nil || request.cameraHidden != nil else {
            throw AgentCommandError.usage("--edit needs --in, --out, --camera or --camera-hidden.")
        }
        let document = try await TrimDocument.open(package, store: store)
        let duration = document.editor.duration
        let start = request.start ?? document.editor.start
        let end = request.end ?? document.editor.end
        if end == start {
            throw AgentCommandError.refused("The start and end are both \(format(start))s, so nothing would be kept. "
                                            + unchanged)
        }
        if end < start {
            throw AgentCommandError.refused("The end (\(format(end))s) comes before the start (\(format(start))s). "
                                            + unchanged)
        }
        let kept: RecordingProject.TrimRange
        do {
            kept = try TrimEditor.check(.init(start: start, end: end), duration: duration)
        } catch let error as TrimEditor.TrimError {
            NSLog("HQ recorder: agent edit refused: \(error)")
            throw AgentCommandError.refused("\(trimMessage(error)) The recording is \(format(duration))s long. \(unchanged)")
        }
        let trim: RecordingProject.TrimRange? = kept.start <= 0 && kept.end >= duration ? nil : kept
        var manifest = document.manifest
        var webcam = manifest.webcam
        if let camera = request.camera {
            guard (0...1).contains(camera.x), (0...1).contains(camera.y), camera.width > 0, camera.width <= 1 else {
                throw AgentCommandError.refused("The camera position x and y must be from 0 to 1, and the width more "
                                                + "than 0 and at most 1. \(unchanged)")
            }
            webcam.x = camera.x
            webcam.y = camera.y
            webcam.width = camera.width
        }
        if let hidden = request.cameraHidden { webcam.visible = !hidden }
        guard trim != manifest.trim || webcam != manifest.webcam else {
            throw AgentCommandError.refused("That is already the current edit. \(unchanged)")
        }
        try store.appendEdit(trim: trim, webcam: webcam, to: &manifest, in: package)
        let kept2 = trim ?? .init(start: 0, end: duration)
        return AgentEditResult(revision: manifest.edits.count, path: manifest.edits.last ?? "", trim: trim,
                               keptStart: kept2.start, keptEnd: kept2.end, keptSeconds: kept2.end - kept2.start,
                               durationSeconds: duration, webcam: webcam)
    }

    // MARK: --export-video

    static func exportVideo(package: URL, store: RecordingPackageStore) async throws -> AgentExportResult {
        let document = try await TrimDocument.open(package, store: store)
        let (url, manifest) = try await document.exportVideo()
        let export = manifest.videoExports?.last
        return AgentExportResult(path: url.path, relativePath: export?.relativePath ?? url.lastPathComponent,
                                 durationSeconds: export?.durationSeconds ?? 0, trim: export?.trim,
                                 webcam: export?.webcam ?? manifest.webcam)
    }

    // MARK: --frame

    static func frame(at seconds: Double, out: URL, package: URL,
                      store: RecordingPackageStore) async throws -> AgentFrameResult {
        let target = out.standardizedFileURL
        guard target.pathExtension.lowercased() == "png" else {
            throw AgentCommandError.refused("--out must be a .png file.")
        }
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw AgentCommandError.refused("\(target.path) already exists. Pick a new file name; nothing was overwritten.")
        }
        var isFolder: ObjCBool = false
        let folder = target.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else {
            throw AgentCommandError.refused("The folder \(folder.path) does not exist.")
        }
        let packagePath = try RecordingsRoot.canonical(package).path
        let targetPath = try RecordingsRoot.canonical(target).path
        guard targetPath != packagePath, !targetPath.hasPrefix(packagePath + "/") else {
            throw AgentCommandError.refused("Write the frame outside the recording package, so the package stays as recorded.")
        }
        let document = try await TrimDocument.open(package, store: store)
        let duration = document.editor.duration
        guard seconds >= 0, seconds < duration else {
            throw AgentCommandError.refused("--at must be from 0 to under \(format(duration))s, the length of the recording.")
        }
        let image = try await renderFrame(package: package, timeline: document.timeline,
                                          webcam: document.manifest.webcam, at: seconds)
        let temp = folder.appendingPathComponent(".\(target.lastPathComponent).tmp-\(UUID().uuidString)")
        do {
            guard let destination = CGImageDestinationCreateWithURL(temp as CFURL, "public.png" as CFString, 1, nil)
            else { throw AgentCommandError.refused("The frame could not be written to \(folder.path).") }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw AgentCommandError.refused("The frame could not be written to \(folder.path).")
            }
            // Fails when the target appeared meanwhile, so nothing is overwritten.
            try FileManager.default.moveItem(at: temp, to: target)
        } catch {
            NSLog("HQ recorder: frame not written: \(error)")
            if FileManager.default.fileExists(atPath: temp.path) {
                do { try FileManager.default.removeItem(at: temp) } catch {
                    NSLog("HQ recorder: could not remove unfinished frame: \(error)")
                }
            }
            throw error
        }
        return AgentFrameResult(path: target.path, atSeconds: seconds, width: image.width, height: image.height)
    }

    /// One still of the screen with the camera drawn at its saved placement, at a time on the
    /// recording timeline (the same times `--describe` and transcripts use).
    private static func renderFrame(package: URL, timeline: RecordingTimeline,
                                    webcam: RecordingProject.WebcamPlacement, at seconds: Double) async throws -> CGImage {
        let playback = try await PlaybackLayers.layers(package: package, timeline: timeline, webcam: webcam)
        guard let video = PlaybackLayers.videoComposition(playback, webcam: webcam) else {
            throw AgentCommandError.refused("This recording has no screen video to show.")
        }
        let generator = AVAssetImageGenerator(asset: playback.composition)
        generator.videoComposition = video
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    // MARK: --transcribe

    static func transcribe(package: URL, store: RecordingPackageStore, locale: String?,
                           engine: any NarrationTranscribing,
                           progress: @escaping @Sendable (String) -> Void) async throws -> AgentTranscribeResult {
        let language = locale.map { Locale(identifier: $0) } ?? Locale.current
        let (path, transcript) = try await NarrationTranscription.run(package: package, store: store, locale: language,
                                                                      engine: engine, progress: progress)
        return AgentTranscribeResult(path: try store.url(for: path, in: package).path, relativePath: path,
                                     locale: transcript.locale, editRevision: transcript.editRevision,
                                     range: transcript.range, segments: transcript.segments.count,
                                     words: transcript.words.count)
    }

    // MARK: --describe

    static func describe(package: URL, store: RecordingPackageStore) async throws -> AgentDescription {
        let manifest = try store.open(package)
        var duration: Double?
        do {
            duration = try await TrimDocument.open(package, store: store).editor.duration
        } catch {
            NSLog("HQ recorder: could not measure the recording for --describe: \(error)")
        }
        var kept: RecordingProject.TrimRange?
        if let duration {
            do {
                kept = try TrimEditor.check(manifest.trim, duration: duration)
            } catch {
                NSLog("HQ recorder: saved trim does not fit the recording: \(error)")
            }
        }
        let edit = AgentDescription.Edit(revisions: manifest.edits.count, path: manifest.edits.last, trim: manifest.trim,
                                         kept: kept, keptSeconds: kept.map { $0.end - $0.start }, webcam: manifest.webcam)
        return AgentDescription(
            package: try RecordingsRoot.canonical(package).path, company: manifest.company, title: manifest.title,
            state: manifest.state.rawValue, stopReason: manifest.stopReason, createdAt: manifest.createdAt,
            durationSeconds: duration, tracks: manifest.tracks, pauses: manifest.pausedRanges ?? [],
            cameraGaps: manifest.cameraGaps ?? [], microphoneGaps: manifest.microphoneGaps ?? [],
            microphoneSilence: manifest.microphoneSilence ?? [], cameraEffects: manifest.cameraEffects ?? [],
            videoEffects: manifest.videoEffects ?? [], edit: edit, videoExports: manifest.videoExports ?? [],
            sopExports: manifest.exports ?? [], drafts: manifest.drafts,
            transcript: transcriptStatus(manifest: manifest, package: package, store: store))
    }

    private struct TranscriptMirror: Decodable {
        struct Segment: Decodable {
            var start: Double
            var end: Double
            var text: String
            var words: [TranscriptWord]?
        }

        var segments: [Segment]
        var words: [TranscriptWord]?
        var locale: String?
        var editRevision: Int?
    }

    static func transcriptStatus(manifest: RecordingManifest, package: URL,
                                 store: RecordingPackageStore) -> AgentDescription.Transcript {
        guard let path = manifest.transcripts.last(where: { $0.hasSuffix(".json") }) else {
            return .init(status: "none")
        }
        do {
            let mirror = try JSONDecoder().decode(TranscriptMirror.self,
                                                  from: Data(contentsOf: store.url(for: path, in: package)))
            let segments = mirror.segments.map {
                TranscriptSegment(start: $0.start, end: $0.end, text: $0.text, words: $0.words ?? [])
            }
            let status = mirror.editRevision.map { $0 == manifest.edits.count ? "current" : "stale" } ?? "unknown"
            return .init(status: status, path: path, locale: mirror.locale, editRevision: mirror.editRevision,
                         segments: segments, words: mirror.words ?? segments.flatMap(\.words))
        } catch {
            NSLog("HQ recorder: could not read transcript \(path): \(error)")
            return .init(status: "unreadable", path: path)
        }
    }

    static func format(_ seconds: Double) -> String { String(format: "%.2f", seconds) }

    private final class StatusBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Int32 = 2
        var value: Int32 { lock.withLock { stored } }
        func set(_ value: Int32) { lock.withLock { stored = value } }
    }
}

// MARK: Results

enum AgentReport: Encodable, Sendable {
    case describe(AgentDescription)
    case transcribe(AgentTranscribeResult)
    case edit(AgentEditResult)
    case export(AgentExportResult)
    case frame(AgentFrameResult)

    func encode(to encoder: Encoder) throws {
        switch self {
        case .describe(let value): try value.encode(to: encoder)
        case .transcribe(let value): try value.encode(to: encoder)
        case .edit(let value): try value.encode(to: encoder)
        case .export(let value): try value.encode(to: encoder)
        case .frame(let value): try value.encode(to: encoder)
        }
    }

    /// The result as short plain lines, for output without `--json`.
    var lines: [String] {
        let f = AgentCommandsCLI.format
        switch self {
        case .describe(let d):
            var lines = ["\(d.title) (\(d.company)), \(d.state)"]
            lines.append("length: " + (d.durationSeconds.map { "\(f($0))s" } ?? "unknown"))
            lines.append("tracks: " + d.tracks.map { "\($0.kind.rawValue) (\($0.segments.count) segments)" }
                .joined(separator: ", "))
            if let kept = d.edit.kept {
                lines.append("edit \(d.edit.revisions): keeps \(f(kept.start))s to \(f(kept.end))s")
            }
            let camera = d.edit.webcam
            lines.append(camera.visible ? "camera: x \(camera.x), y \(camera.y), width \(camera.width)" : "camera: hidden")
            lines.append("pauses: \(d.pauses.count), camera gaps: \(d.cameraGaps.count), "
                         + "microphone gaps: \(d.microphoneGaps.count)")
            lines.append("video exports: \(d.videoExports.count)")
            lines.append("transcript: \(d.transcript.status)" + (d.transcript.path.map { " (\($0))" } ?? ""))
            return lines
        case .transcribe(let t):
            return ["saved \(t.path)", "\(t.segments) phrases, \(t.words) words, \(t.locale)"]
        case .edit(let e):
            return ["saved \(e.path)", "keeps \(f(e.keptStart))s to \(f(e.keptEnd))s of \(f(e.durationSeconds))s",
                    e.webcam.visible ? "camera: x \(e.webcam.x), y \(e.webcam.y), width \(e.webcam.width)" : "camera: hidden"]
        case .export(let e):
            return [e.path]
        case .frame(let fr):
            return [fr.path]
        }
    }
}

struct AgentEditResult: Codable, Equatable, Sendable {
    var revision: Int
    var path: String
    var trim: RecordingProject.TrimRange?
    var keptStart: Double
    var keptEnd: Double
    var keptSeconds: Double
    var durationSeconds: Double
    var webcam: RecordingProject.WebcamPlacement
}

struct AgentExportResult: Codable, Equatable, Sendable {
    var path: String
    var relativePath: String
    var durationSeconds: Double
    var trim: RecordingProject.TrimRange?
    var webcam: RecordingProject.WebcamPlacement
}

struct AgentFrameResult: Codable, Equatable, Sendable {
    var path: String
    var atSeconds: Double
    var width: Int
    var height: Int
}

struct AgentTranscribeResult: Codable, Equatable, Sendable {
    var path: String
    var relativePath: String
    var locale: String
    var editRevision: Int
    var range: RecordingProject.TrimRange
    var segments: Int
    var words: Int
}

struct AgentDescription: Codable, Equatable, Sendable {
    struct Edit: Codable, Equatable, Sendable {
        var revisions: Int
        var path: String?
        var trim: RecordingProject.TrimRange?
        /// The range the current edit keeps; nil when the recording could not be measured.
        var kept: RecordingProject.TrimRange?
        var keptSeconds: Double?
        var webcam: RecordingProject.WebcamPlacement
    }

    struct Transcript: Codable, Equatable, Sendable {
        /// none, current (made for the current edit), stale (made for an earlier edit), unknown or unreadable.
        var status: String
        var path: String?
        var locale: String?
        var editRevision: Int?
        var segments: [TranscriptSegment]?
        var words: [TranscriptWord]?
    }

    var package: String
    var company: String
    var title: String
    var state: String
    var stopReason: String?
    var createdAt: String
    var durationSeconds: Double?
    var tracks: [RecordingManifest.Track]
    var pauses: [RecordingManifest.PausedRange]
    var cameraGaps: [RecordingManifest.CameraGap]
    var microphoneGaps: [RecordingManifest.CameraGap]
    var microphoneSilence: [RecordingManifest.SilenceRange]
    var cameraEffects: [RecordingManifest.CameraEffectRange]
    var videoEffects: [RecordingManifest.VideoEffectRange]
    var edit: Edit
    var videoExports: [RecordingManifest.Export]
    var sopExports: [String]
    var drafts: [RecordingManifest.Draft]
    var transcript: Transcript
}
