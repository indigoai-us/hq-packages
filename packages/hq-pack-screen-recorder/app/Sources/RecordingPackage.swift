import Foundation

/// The bound company's recordings folder, `<vault>/companies/<slug>/recordings`.
/// Every file the recorder writes must resolve inside this folder.
struct RecordingsRoot: Equatable, Sendable {
    let company: String
    /// Absolute folder with symlinks resolved.
    let url: URL
    /// Vault-relative path of the folder, always `companies/<slug>/recordings`.
    var vaultPath: String { "companies/\(company)/recordings" }

    static func resolve(company: String, destination: URL) throws -> RecordingsRoot {
        guard company.range(of: "^[a-z0-9][a-z0-9-]*$", options: .regularExpression) != nil
        else { throw PackageError.invalidCompany }
        let resolved = try canonical(destination)
        let parts = resolved.pathComponents
        guard parts.count >= 4, Array(parts.suffix(3)) == ["companies", company, "recordings"]
        else { throw PackageError.outsideCompanyRecordings }
        return RecordingsRoot(company: company, url: resolved)
    }

    /// Returns `url` when it resolves inside this folder, otherwise throws.
    func contain(_ url: URL) throws -> URL {
        let resolved = try Self.canonical(url)
        let root = self.url.pathComponents
        guard resolved.pathComponents.count > root.count,
              Array(resolved.pathComponents.prefix(root.count)) == root
        else { throw PackageError.outsideCompanyRecordings }
        return resolved
    }

    /// Resolves symlinks in the deepest existing ancestor with realpath(3), then appends
    /// the parts that do not exist yet. `URL.resolvingSymlinksInPath()` leaves symlinked
    /// parent folders unresolved when the leaf is missing, which would let a link inside
    /// a package point a new file outside the recordings folder. A dangling symlink on
    /// the way is refused because its target cannot be checked.
    static func canonical(_ url: URL) throws -> URL {
        var existing = url.standardizedFileURL.path
        var tail: [String] = []
        while true {
            if let real = realpath(existing, nil) {
                defer { free(real) }
                var result = URL(fileURLWithPath: String(cString: real))
                for part in tail.reversed() { result.appendPathComponent(part) }
                return result
            }
            var info = stat()
            if lstat(existing, &info) == 0 { throw PackageError.outsideCompanyRecordings }
            let parent = (existing as NSString).deletingLastPathComponent
            guard parent != existing, !parent.isEmpty else { throw PackageError.outsideCompanyRecordings }
            tail.append((existing as NSString).lastPathComponent)
            existing = parent
        }
    }
}

enum PackageError: Error, Equatable {
    case invalidCompany
    case outsideCompanyRecordings
    case destinationMissing
    case destinationUnwritable
    case lowDiskSpace
    case unsupportedVersion
    case invalidPath
    case duplicateTrack
    case companyMismatch
    case bindingLocked
    case notRecording
    case revisionExists
    case notAPackage
    /// The recording has not finished saving, so its media can't be read yet.
    case stillRecording
}

/// Versioned description of one recording package (`<name>.hqrec/manifest.json`).
/// File references are relative to the package. `vaultPath` is the package's location in
/// the HQ tree (`companies/<slug>/recordings/<name>.hqrec`); `vaultKey` is the same location
/// as a key in the company-scoped vault bucket, which has no `companies/<slug>/` prefix.
struct RecordingManifest: Codable, Equatable, Sendable {
    static let currentVersion = 2
    var version = currentVersion
    var id: UUID
    var title: String
    var company: String
    var vaultPath: String
    var createdAt: String
    var state: State
    var stopReason: String?
    var tracks: [Track] = []
    var timeline = "timeline.json"
    var edits: [String] = []
    var transcripts: [String] = []
    var screenshots: [String] = []
    var drafts: [Draft] = []
    var sync = Sync()
    var trim: RecordingProject.TrimRange?
    /// The ranges the current edit keeps when it has middle cuts. Nil for one range, and in older manifests.
    var kept: [RecordingProject.TrimRange]?
    var webcam = RecordingProject.WebcamPlacement()
    /// Set when this manifest was migrated from a v1 `project.json`, which is kept unchanged.
    var migratedFrom: String?
    /// Ranges where the system drew a video effect into the screen track. Absent in older manifests.
    var videoEffects: [VideoEffectRange]?
    /// Ranges where the camera track has no frames. Absent in older manifests and screen-only recordings.
    var cameraGaps: [CameraGap]?
    /// Ranges where a camera effect was baked into the camera frames. Absent in older manifests.
    var cameraEffects: [CameraEffectRange]?
    /// What the camera track does after an interruption or disconnect. Set once a camera segment exists.
    var cameraRecovery: CameraRecoveryPolicy?
    /// Ranges with no microphone audio, with the same reasons as camera gaps. Absent in older manifests.
    var microphoneGaps: [CameraGap]?
    /// Ranges where the microphone delivered audio but it stayed below the silence threshold.
    var microphoneSilence: [SilenceRange]?
    /// Loudest microphone level heard during the recording, in dBFS. Nil when no audio arrived.
    var microphonePeakDBFS: Double?
    /// True when a microphone was recorded but no sound ever rose above the silence threshold,
    /// so the narration is unusable. Absent when no microphone was chosen or in older manifests.
    var microphoneSilent: Bool?
    /// Where the user paused. Paused time is left out of every segment and offset, so each pause
    /// sits at one point of the output. Absent when the recording was never paused.
    var pausedRanges: [PausedRange]?
    /// Package-relative path of the teleprompter script shown while recording, if one was used.
    var teleprompter: String?
    /// Screen-text evidence sampled from the screen track (`screenshots/evidence.json`). Absent
    /// until evidence is extracted, and in older manifests.
    var screenEvidence: String?
    /// The `exports` list in `manifest.json`. SOP exports add their files as path strings and video
    /// exports add an object each, so packages written before both kinds existed still decode.
    /// Use `exports` and `videoExports` rather than this list.
    var exportEntries: [ExportEntry]?
    /// Track files whose real length differs from their place on the timeline by more than 5%,
    /// found when the recording was saved. Absent when every file matched, and in older manifests.
    var mediaIssues: [MediaIssue]?

    /// Files written by SOP exports (`exports/vNNN/...`). Absent until the first export, and in
    /// older manifests.
    var exports: [String]? {
        get {
            let files = (exportEntries ?? []).compactMap { if case .file(let path) = $0 { path } else { nil } }
            return files.isEmpty ? nil : files
        }
        set { setExportEntries(files: newValue ?? [], videos: videoExports ?? []) }
    }

    /// Finished video exports saved inside this package, oldest first. Absent until the first export.
    var videoExports: [Export]? {
        get {
            let videos = (exportEntries ?? []).compactMap { if case .video(let export) = $0 { export } else { nil } }
            return videos.isEmpty ? nil : videos
        }
        set { setExportEntries(files: exports ?? [], videos: newValue ?? []) }
    }

    private mutating func setExportEntries(files: [String], videos: [Export]) {
        let entries = videos.map(ExportEntry.video) + files.map(ExportEntry.file)
        exportEntries = entries.isEmpty ? nil : entries
    }

    enum CodingKeys: String, CodingKey {
        case version, id, title, company, vaultPath, createdAt, state, stopReason, tracks, timeline, edits,
             transcripts, screenshots, drafts, sync, trim, kept, webcam, migratedFrom, videoEffects, cameraGaps,
             cameraEffects, cameraRecovery, microphoneGaps, microphoneSilence, microphonePeakDBFS,
             microphoneSilent, pausedRanges, teleprompter, screenEvidence, mediaIssues
        case exportEntries = "exports"
    }

    /// One entry of the manifest's `exports` list: a file path from an SOP export, or a video export.
    enum ExportEntry: Codable, Equatable, Sendable {
        case file(String)
        case video(Export)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let path = try? container.decode(String.self) {
                self = .file(path)
            } else {
                self = .video(try container.decode(Export.self))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .file(let path): try container.encode(path)
            case .video(let export): try container.encode(export)
            }
        }
    }

    enum State: String, Codable, Sendable {
        case recording, finalizing, saved
        /// The recorder stopped without finalizing (crash or power loss); closed segments are kept.
        case interrupted
    }

    struct Track: Codable, Equatable, Sendable {
        var kind: RecordingProject.Track.Kind
        var segments: [Segment]
    }

    struct Segment: Codable, Equatable, Sendable {
        enum Status: String, Codable, Sendable { case recording, closed, missing }
        var relativePath: String
        var startOffsetSeconds: Double
        var durationSeconds: Double?
        var status: Status
    }

    /// A saved track file that is not as long as the timeline says. The file is kept as recorded;
    /// the issue tells the user and the HQ session that it may not line up.
    struct MediaIssue: Codable, Equatable, Sendable {
        /// Largest difference, as a share of the timeline length, that still counts as matching.
        static let tolerance = 0.05
        /// Differences up to this many seconds always match, so one frame on a short segment never counts.
        static let slackSeconds = 0.1

        var kind: RecordingProject.Track.Kind
        var relativePath: String
        var timelineSeconds: Double
        var fileSeconds: Double
        var message: String

        init(kind: RecordingProject.Track.Kind, relativePath: String, timelineSeconds: Double, fileSeconds: Double) {
            self.kind = kind
            self.relativePath = relativePath
            self.timelineSeconds = timelineSeconds
            self.fileSeconds = fileSeconds
            message = Self.message(kind, timelineSeconds: timelineSeconds, fileSeconds: fileSeconds)
        }

        /// An issue when the file length is more than 5% away from the timeline length, else nil.
        static func check(_ kind: RecordingProject.Track.Kind, path: String, timelineSeconds: Double,
                          fileSeconds: Double) -> MediaIssue? {
            guard timelineSeconds.isFinite, fileSeconds.isFinite, timelineSeconds > 0 else { return nil }
            let difference = abs(fileSeconds - timelineSeconds)
            guard difference > timelineSeconds * tolerance, difference > slackSeconds else { return nil }
            return MediaIssue(kind: kind, relativePath: path, timelineSeconds: timelineSeconds, fileSeconds: fileSeconds)
        }

        static func message(_ kind: RecordingProject.Track.Kind, timelineSeconds: Double, fileSeconds: Double) -> String {
            let name = switch kind {
            case .screen: "screen"
            case .camera: "camera"
            case .microphone: "narration"
            }
            let seconds = { (value: Double) in String(format: "%.1f", value) }
            return "The \(name) file is \(seconds(fileSeconds)) seconds long but the recording has "
                + "\(seconds(timelineSeconds)) seconds of it, so it may not line up. The original files are kept."
        }
    }

    /// A range where a system video effect such as Presenter Overlay drew the camera into the
    /// screen frames. `flattened` means the layers can't be separated there. A nil end means
    /// the effect was still on when the recording stopped.
    struct VideoEffectRange: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case presenterOverlay = "presenter-overlay" }
        var kind: Kind
        var startOffsetSeconds: Double
        var endOffsetSeconds: Double?
        var flattened: Bool
    }

    /// A range with no camera frames. Segments before the gap are closed and kept; a nil end
    /// means the camera did not come back before the recording stopped.
    struct CameraGap: Codable, Equatable, Sendable {
        enum Reason: String, Codable, Sendable {
            /// AVCaptureSession reported an interruption, for example another app took the camera.
            case interrupted
            /// The camera device was unplugged or went out of range.
            case disconnected
            /// The system suspended the camera (device `isSuspended`, such as a closed lid).
            case suspended
            /// AVCaptureSession reported a runtime error.
            case runtimeError = "runtime-error"
            /// The camera segment could not be written.
            case writerFailed = "writer-failed"
        }
        var reason: Reason
        var startOffsetSeconds: Double
        var endOffsetSeconds: Double?
    }

    /// A camera effect the user turned on. It is drawn into the camera frames only, so it is
    /// kept as the user's chosen look. Reactions are not reported by the system and never appear here.
    struct CameraEffectRange: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable {
            case portrait
            case studioLight = "studio-light"
            case backgroundReplacement = "background-replacement"
            case centerStage = "center-stage"
        }
        var kind: Kind
        var startOffsetSeconds: Double
        var endOffsetSeconds: Double?
    }

    /// The camera recovery policy verified in US-002: a camera problem never stops the screen
    /// track. The open camera segment is closed and kept, a gap is recorded, and the next
    /// camera frame starts a new segment at its own offset.
    enum CameraRecoveryPolicy: String, Codable, Sendable {
        case keepScreenResumeInNewSegment = "keep-screen-resume-in-new-segment"
    }

    /// A range where the microphone sent only silence, such as a closed laptop lid or a muted
    /// input. A nil end means it was still silent when the recording stopped.
    struct SilenceRange: Codable, Equatable, Sendable {
        var startOffsetSeconds: Double
        var endOffsetSeconds: Double?
    }

    /// One pause. `atOffsetSeconds` is where it falls on the output timeline;
    /// `startHostOffsetSeconds` and `durationSeconds` are measured on the recording clock.
    /// A nil duration means the recording stopped while paused.
    struct PausedRange: Codable, Equatable, Sendable {
        var atOffsetSeconds: Double
        var startHostOffsetSeconds: Double
        var durationSeconds: Double?
    }

    struct Draft: Codable, Equatable, Sendable {
        var relativePath: String
        var approval: DraftRevision.Approval
    }

    /// One shareable video written from the recording, with the trim and camera placement it used.
    struct Export: Codable, Equatable, Sendable {
        var relativePath: String
        var createdAt: String
        var durationSeconds: Double
        var trim: RecordingProject.TrimRange?
        /// The kept ranges when the edit had middle cuts. Absent for one range and in older exports.
        var kept: [RecordingProject.TrimRange]?
        var webcam: RecordingProject.WebcamPlacement
    }

    struct Sync: Codable, Equatable, Sendable {
        enum State: String, Codable, Sendable {
            /// Saved in the local vault tree; no sync attempt observed yet.
            case localOnly = "local-only"
            /// Waiting for `hq sync` to push the package.
            case pending
            /// A checker confirmed the package was pushed.
            case synced
            /// The last sync attempt failed; the local package is kept and the push will be retried.
            case failedRetry = "failed-retry"
        }
        var state: State = .localOnly
        var checkedAt: String?
        var detail: String?
    }

    /// Bucket-relative vault key (`recordings/<name>.hqrec`). The vault bucket is already
    /// scoped to the company, so the HQ-tree `companies/<slug>/` prefix is dropped.
    var vaultKey: String {
        vaultPath.split(separator: "/").dropFirst(2).joined(separator: "/")
    }

    var allReferences: [String] {
        [timeline] + tracks.flatMap { $0.segments.map(\.relativePath) } + edits + transcripts
            + screenshots + drafts.map(\.relativePath) + (teleprompter.map { [$0] } ?? [])
            + (screenEvidence.map { [$0] } ?? []) + (exports ?? []) + (videoExports ?? []).map(\.relativePath)
    }

    func validate() throws {
        guard version == Self.currentVersion else { throw PackageError.unsupportedVersion }
        guard company.range(of: "^[a-z0-9][a-z0-9-]*$", options: .regularExpression) != nil
        else { throw PackageError.invalidCompany }
        let vaultParts = vaultPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard vaultParts.count == 4, Array(vaultParts.prefix(3)) == ["companies", company, "recordings"],
              Self.isSafeRelative(vaultPath) else { throw PackageError.outsideCompanyRecordings }
        guard Set(tracks.map(\.kind)).count == tracks.count else { throw PackageError.duplicateTrack }
        for path in allReferences where !Self.isSafeRelative(path) { throw PackageError.invalidPath }
        for segment in tracks.flatMap(\.segments) {
            guard segment.startOffsetSeconds.isFinite, segment.startOffsetSeconds >= 0
            else { throw PackageError.invalidPath }
        }
        let ranges = (videoEffects ?? []).map { ($0.startOffsetSeconds, $0.endOffsetSeconds) }
            + (cameraGaps ?? []).map { ($0.startOffsetSeconds, $0.endOffsetSeconds) }
            + (cameraEffects ?? []).map { ($0.startOffsetSeconds, $0.endOffsetSeconds) }
            + (microphoneGaps ?? []).map { ($0.startOffsetSeconds, $0.endOffsetSeconds) }
            + (microphoneSilence ?? []).map { ($0.startOffsetSeconds, $0.endOffsetSeconds) }
        for (start, end) in ranges {
            guard start.isFinite, start >= 0, end.map({ $0.isFinite && $0 >= start }) ?? true
            else { throw PackageError.invalidPath }
        }
        if let microphonePeakDBFS, !microphonePeakDBFS.isFinite { throw PackageError.invalidPath }
        for export in videoExports ?? [] {
            guard export.relativePath.hasPrefix("\(RecordingPackageStore.exportsFolder)/"),
                  export.durationSeconds.isFinite, export.durationSeconds > 0
            else { throw PackageError.invalidPath }
        }
        for pause in pausedRanges ?? [] {
            guard pause.atOffsetSeconds.isFinite, pause.atOffsetSeconds >= 0,
                  pause.startHostOffsetSeconds.isFinite, pause.startHostOffsetSeconds >= 0,
                  pause.durationSeconds.map({ $0.isFinite && $0 >= 0 }) ?? true
            else { throw PackageError.invalidPath }
        }
    }

    static func isSafeRelative(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty && !path.hasPrefix("/") && !parts.contains("..")
            && !parts.contains(".") && !parts.contains("")
    }
}

/// Common timeline: where each segment sits on the recording clock (seconds from start).
struct RecordingTimeline: Codable, Equatable, Sendable {
    var version = 1
    /// Host clock time at recording start, so tracks captured separately line up.
    var originHostTime: Double?
    var entries: [Entry] = []
    struct Entry: Codable, Equatable, Sendable {
        var kind: RecordingProject.Track.Kind
        var relativePath: String
        var startOffsetSeconds: Double
        var durationSeconds: Double?
    }
}

/// One edit-decision revision. Revisions are append-only; source media is never modified.
struct EditRevision: Codable, Equatable, Sendable {
    var revision: Int
    var createdAt: String
    var trim: RecordingProject.TrimRange?
    /// The kept ranges when the edit has middle cuts. Absent for one range, and in revisions
    /// written before cuts existed, which load as the single `trim` range.
    var kept: [RecordingProject.TrimRange]?
    var webcam: RecordingProject.WebcamPlacement
}

/// One SOP draft revision. Drafting and autosave write unapproved revisions; only the explicit
/// review action writes an approved one.
struct DraftRevision: Codable, Equatable, Sendable {
    enum Approval: String, Codable, Sendable { case unapproved, approved }
    var revision: Int
    var createdAt: String
    var approval: Approval = .unapproved
    var source: String
    var body: String
}

/// Free space at a path, injectable for tests.
protocol FreeSpaceProviding: Sendable {
    func availableBytes(at url: URL) -> Int64?
}

struct VolumeFreeSpace: FreeSpaceProviding {
    func availableBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

/// Reads and writes recording packages inside one company's recordings folder.
struct RecordingPackageStore: Sendable {
    static let packageExtension = "hqrec"
    static let manifestName = "manifest.json"
    static let exportsFolder = "exports"
    static let subdirectories = ["media/screen", "media/camera", "media/microphone",
                                 "edits", "transcripts", "screenshots", "drafts", exportsFolder]

    let root: RecordingsRoot
    var freeSpace: any FreeSpaceProviding = VolumeFreeSpace()
    /// Capture refuses to start, and an active recording stops, below this many free bytes.
    var minimumFreeBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
    /// Test hook: runs after a temporary file is written and before it replaces the live file.
    var beforeCommit: (@Sendable (URL) throws -> Void)?

    init(root: RecordingsRoot) { self.root = root }

    /// Checks the recordings folder exists, is writable and has room to record.
    func verifyDestination() throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw PackageError.destinationMissing }
        guard DestinationCheck.problem(with: root.url) == nil else { throw PackageError.destinationUnwritable }
        guard hasRoomToRecord() else { throw PackageError.lowDiskSpace }
    }

    func hasRoomToRecord() -> Bool {
        guard let bytes = freeSpace.availableBytes(at: root.url) else { return true }
        return bytes >= minimumFreeBytes
    }

    /// Creates a new uniquely named package and writes its first manifest.
    func create(title: String, date: Date = Date(), id: UUID = UUID()) throws -> (URL, RecordingManifest) {
        try verifyDestination()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "\(formatter.string(from: date))-\(id.uuidString.prefix(8).lowercased()).\(Self.packageExtension)"
        let package = try root.contain(root.url.appendingPathComponent(name, isDirectory: true))
        // Fails when the name already exists, so an existing package is never reused.
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        for sub in Self.subdirectories {
            try FileManager.default.createDirectory(at: package.appendingPathComponent(sub),
                                                    withIntermediateDirectories: true)
        }
        let manifest = RecordingManifest(id: id, title: title, company: root.company,
                                         vaultPath: "\(root.vaultPath)/\(name)",
                                         createdAt: SessionStatus.now(), state: .recording)
        try writeJSON(RecordingTimeline(), to: "timeline.json", in: package)
        try writeManifest(manifest, in: package)
        return (package, manifest)
    }

    /// Validates, then replaces `manifest.json` with a temp-file write and rename.
    func writeManifest(_ manifest: RecordingManifest, in package: URL) throws {
        try manifest.validate()
        guard manifest.company == root.company else { throw PackageError.companyMismatch }
        try writeJSON(manifest, to: Self.manifestName, in: package)
    }

    func readManifest(in package: URL) throws -> RecordingManifest {
        let url = try root.contain(package.appendingPathComponent(Self.manifestName))
        let manifest = try JSONDecoder().decode(RecordingManifest.self, from: Data(contentsOf: url))
        try manifest.validate()
        guard manifest.company == root.company else { throw PackageError.companyMismatch }
        return manifest
    }

    /// Opens a package for editing or recovery. A v1 `project.json` package is migrated
    /// into a v2 manifest without changing `project.json`. Segment files that are gone
    /// are marked missing, and a recording that never finalized is marked interrupted.
    func open(_ package: URL) throws -> RecordingManifest {
        let package = try root.contain(package)
        let manifestURL = package.appendingPathComponent(Self.manifestName)
        var manifest: RecordingManifest
        var changed = false
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            manifest = try readManifest(in: package)
        } else if FileManager.default.fileExists(atPath: package.appendingPathComponent("project.json").path) {
            manifest = try migrate(ProjectStore().load(from: package), package: package)
            changed = true
        } else {
            throw PackageError.notAPackage
        }
        for t in manifest.tracks.indices {
            for s in manifest.tracks[t].segments.indices {
                let segment = manifest.tracks[t].segments[s]
                let exists = FileManager.default.fileExists(
                    atPath: package.appendingPathComponent(segment.relativePath).path)
                if !exists, segment.status != .missing {
                    manifest.tracks[t].segments[s].status = .missing
                    changed = true
                } else if exists, segment.status == .missing {
                    manifest.tracks[t].segments[s].status = .closed
                    changed = true
                }
            }
        }
        if manifest.state == .recording || manifest.state == .finalizing {
            manifest.state = .interrupted
            manifest.stopReason = manifest.stopReason ?? "not-finalized"
            for t in manifest.tracks.indices {
                for s in manifest.tracks[t].segments.indices
                where manifest.tracks[t].segments[s].status == .recording {
                    manifest.tracks[t].segments[s].status = .closed
                }
            }
            changed = true
        }
        if changed { try writeManifest(manifest, in: package) }
        return manifest
    }

    private func migrate(_ project: RecordingProject, package: URL) throws -> RecordingManifest {
        var manifest = RecordingManifest(id: project.id, title: project.title, company: root.company,
                                         vaultPath: "\(root.vaultPath)/\(package.lastPathComponent)",
                                         createdAt: SessionStatus.now(), state: .saved)
        manifest.tracks = project.tracks.map {
            .init(kind: $0.kind, segments: [.init(relativePath: $0.relativePath,
                                                  startOffsetSeconds: $0.startOffsetSeconds,
                                                  durationSeconds: nil, status: .closed)])
        }
        manifest.trim = project.trim
        manifest.kept = project.kept
        manifest.webcam = project.webcam
        manifest.migratedFrom = "project.json"
        if !FileManager.default.fileExists(atPath: package.appendingPathComponent(manifest.timeline).path) {
            try writeJSON(timeline(for: manifest), to: manifest.timeline, in: package)
        }
        return manifest
    }

    func timeline(for manifest: RecordingManifest, originHostTime: Double? = nil) -> RecordingTimeline {
        RecordingTimeline(originHostTime: originHostTime, entries: manifest.tracks.flatMap { track in
            track.segments.map { .init(kind: track.kind, relativePath: $0.relativePath,
                                       startOffsetSeconds: $0.startOffsetSeconds,
                                       durationSeconds: $0.durationSeconds) }
        })
    }

    /// Records an edit decision as a new revision file. Earlier revisions and media are untouched.
    /// `kept` lists the ranges an edit with middle cuts keeps; nil keeps the one `trim` range.
    func appendEdit(trim: RecordingProject.TrimRange?, kept: [RecordingProject.TrimRange]? = nil,
                    webcam: RecordingProject.WebcamPlacement,
                    to manifest: inout RecordingManifest, in package: URL) throws {
        var candidate = manifest
        candidate.trim = trim
        candidate.kept = kept
        candidate.webcam = webcam
        try RecordingProject(id: manifest.id, title: manifest.title, tracks: [], trim: trim, kept: kept,
                             webcam: webcam).validate()
        let revision = manifest.edits.count + 1
        let path = String(format: "edits/edit-%03d.json", revision)
        try writeNewJSON(EditRevision(revision: revision, createdAt: SessionStatus.now(), trim: trim, kept: kept,
                                      webcam: webcam),
                         to: path, in: package)
        candidate.edits.append(path)
        try writeManifest(candidate, in: package)
        manifest = candidate
    }

    /// Saves an SOP draft revision, unapproved unless the review action approved it.
    func appendDraft(body: String, source: String, approval: DraftRevision.Approval = .unapproved,
                     to manifest: inout RecordingManifest, in package: URL) throws {
        var candidate = manifest
        let revision = manifest.drafts.count + 1
        let path = String(format: "drafts/draft-%03d.json", revision)
        try writeNewJSON(DraftRevision(revision: revision, createdAt: SessionStatus.now(), approval: approval,
                                       source: source, body: body),
                         to: path, in: package)
        candidate.drafts.append(.init(relativePath: path, approval: approval))
        try writeManifest(candidate, in: package)
        manifest = candidate
    }

    /// Absolute URL for a package-relative path, refused when it would leave the recordings folder.
    func url(for relativePath: String, in package: URL) throws -> URL {
        guard RecordingManifest.isSafeRelative(relativePath) else { throw PackageError.invalidPath }
        let package = try root.contain(package)
        return try root.contain(package.appendingPathComponent(relativePath))
    }

    /// Creates a folder inside the package, refused when it would leave the recordings folder.
    func ensureDirectory(_ relativePath: String, in package: URL) throws {
        try FileManager.default.createDirectory(at: url(for: relativePath, in: package), withIntermediateDirectories: true)
    }

    func writeJSON<T: Encodable>(_ value: T, to relativePath: String, in package: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writeData(try encoder.encode(value), to: relativePath, in: package)
    }

    /// Replaces a package file with a temp-file write, flush and rename. The path must stay
    /// inside the package and the recordings folder.
    func writeData(_ data: Data, to relativePath: String, in package: URL) throws {
        let target = try url(for: relativePath, in: package)
        let temp = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: temp)
        do {
            let handle = try FileHandle(forWritingTo: temp)
            try handle.synchronize()
            try handle.close()
            try beforeCommit?(temp)
            guard rename(temp.path, target.path) == 0 else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: target.path])
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    /// Writes a file that must not exist yet, so a revision is never overwritten.
    private func writeNewJSON<T: Encodable>(_ value: T, to relativePath: String, in package: URL) throws {
        let target = try url(for: relativePath, in: package)
        guard !FileManager.default.fileExists(atPath: target.path) else { throw PackageError.revisionExists }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: target, options: .withoutOverwriting)
    }
}

extension RecordingPackageStore {
    /// Free bytes an export of `seconds` needs before it starts: a generous estimate of the
    /// encoded video plus headroom, so the disk is never filled by an export.
    static func exportBytesNeeded(seconds: Double) -> Int64 {
        let media = Int64(max(seconds, 0) * 2_500_000)
        return max(media, 64 * 1_024 * 1_024) + 256 * 1_024 * 1_024
    }

    func hasRoomToExport(seconds: Double) -> Bool {
        guard let bytes = freeSpace.availableBytes(at: root.url) else { return true }
        return bytes >= Self.exportBytesNeeded(seconds: seconds)
    }

    /// The next `exports/export-NNN.mp4` that is neither on disk nor in the manifest.
    func nextExportPath(for manifest: RecordingManifest, in package: URL) throws -> String {
        let used = Set((manifest.videoExports ?? []).map(\.relativePath))
        var number = (manifest.videoExports?.count ?? 0) + 1
        while true {
            let path = "\(Self.exportsFolder)/" + String(format: "export-%03d.mp4", number)
            let file = try url(for: path, in: package)
            if !used.contains(path), !FileManager.default.fileExists(atPath: file.path) { return path }
            number += 1
        }
    }

    /// Writes a shareable H.264/AAC MP4 of the recording, cut to the saved trim with the camera
    /// at its saved placement, into the package's `exports` folder, and records it in the manifest.
    /// The video is written to a hidden temporary file and only moved into place once it is
    /// complete and checked, so cancelling, a full disk or a failure leaves the recorded media,
    /// earlier exports and the manifest as they were. Nothing is uploaded or shared.
    func exportVideo(manifest: RecordingManifest, timeline: RecordingTimeline,
                     in package: URL) async throws -> (url: URL, manifest: RecordingManifest) {
        let package = try root.contain(package)
        guard manifest.company == root.company else { throw PackageError.companyMismatch }
        let folder = try url(for: Self.exportsFolder, in: package)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = try nextExportPath(for: manifest, in: package)
        let target = try url(for: path, in: package)
        let temp = folder.appendingPathComponent(".\(target.deletingPathExtension().lastPathComponent)"
                                                 + "-\(UUID().uuidString).tmp.mp4")
        let duration: Double
        do {
            duration = try await PlaybackLayers.exportVideo(
                package: package, timeline: timeline, webcam: manifest.webcam, trim: manifest.trim,
                kept: manifest.kept, to: temp, beforeWriting: { seconds in
                    guard hasRoomToExport(seconds: seconds) else { throw PackageError.lowDiskSpace }
                })
            try beforeCommit?(temp)
            try Task.checkCancellation()
            // Fails when the target exists, so an earlier export is never replaced.
            try FileManager.default.moveItem(at: temp, to: target)
        } catch {
            NSLog("HQ recorder: video export stopped: \(error)")
            removeIfPresent(temp)
            throw Task.isCancelled ? CancellationError() : error
        }
        var candidate = manifest
        candidate.videoExports = (manifest.videoExports ?? []) + [.init(
            relativePath: path, createdAt: SessionStatus.now(), durationSeconds: duration,
            trim: manifest.trim, kept: manifest.kept, webcam: manifest.webcam)]
        do {
            try writeManifest(candidate, in: package)
        } catch {
            NSLog("HQ recorder: could not record the export in the manifest: \(error)")
            removeIfPresent(target)
            throw error
        }
        return (target, candidate)
    }

    private func removeIfPresent(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do { try FileManager.default.removeItem(at: url) } catch {
            NSLog("HQ recorder: could not remove unfinished export: \(error)")
        }
    }
}
