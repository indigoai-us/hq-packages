import Foundation

/// Something that writes one media segment and can be closed when the recording stops.
protocol SegmentFinishing: AnyObject, Sendable {
    /// Closes the file. Returns the written duration in seconds, or nil when nothing was written.
    func finishSegment() async -> Double?
}

/// What a sync check observed for one package. Only a confirmed push counts as synced.
enum SyncObservation: Equatable, Sendable {
    case notAttempted
    case queued
    case pushed
    case offline
    case failed(String)
}

/// Checks sync for one package, addressed by its bucket-relative vault key.
protocol SyncChecking: Sendable {
    func observe(vaultKey: String) async -> SyncObservation
}

/// Default checker for the shipped app. The package already sits in the vault tree, so
/// the existing `hq sync` push and ACL rules carry it. The app cannot confirm a push on
/// its own, so it reports `queued` when the HQ CLI is installed and `failed` when it is not.
struct HQSyncCLIChecker: SyncChecking {
    var candidates = ["/opt/homebrew/bin/hq", "/usr/local/bin/hq"]
    func observe(vaultKey: String) async -> SyncObservation {
        candidates.contains { FileManager.default.isExecutableFile(atPath: $0) }
            ? .queued : .failed("hq-cli-unavailable")
    }
}

extension RecordingManifest.Sync {
    init(_ observation: SyncObservation, at time: String) {
        switch observation {
        case .notAttempted: self.init(state: .localOnly, checkedAt: time, detail: nil)
        case .queued: self.init(state: .pending, checkedAt: time, detail: "waiting-for-hq-sync")
        case .pushed: self.init(state: .synced, checkedAt: time, detail: nil)
        case .offline: self.init(state: .failedRetry, checkedAt: time, detail: "offline")
        case .failed(let reason): self.init(state: .failedRetry, checkedAt: time, detail: reason)
        }
    }
}

/// One recording bound to one company and destination from start to finish.
actor RecordingSession {
    let company: String
    let destination: URL
    let store: RecordingPackageStore
    let syncChecker: any SyncChecking
    private(set) var package: URL?
    private(set) var manifest: RecordingManifest?
    private var writers: [(path: String, writer: any SegmentFinishing)] = []

    init(company: String, destination: URL, store: RecordingPackageStore? = nil,
         syncChecker: any SyncChecking = HQSyncCLIChecker()) throws {
        let root = try RecordingsRoot.resolve(company: company, destination: destination)
        if let store, store.root != root { throw PackageError.companyMismatch }
        self.company = company
        self.destination = destination
        self.store = store ?? RecordingPackageStore(root: root)
        self.syncChecker = syncChecker
    }

    var isRecording: Bool { manifest?.state == .recording }

    /// Verifies the destination again and creates the package. Nothing is written on failure.
    func start(title: String) throws -> URL {
        guard manifest == nil else { throw PackageError.bindingLocked }
        let (package, manifest) = try store.create(title: title)
        self.package = package
        self.manifest = manifest
        return package
    }

    /// The company and destination cannot change once a recording exists.
    func rebind(company: String, destination: URL) throws {
        let requested = try RecordingsRoot.resolve(company: company, destination: destination)
        guard requested == store.root else {
            throw manifest == nil ? PackageError.companyMismatch : PackageError.bindingLocked
        }
    }

    /// Adds a segment for `kind` and returns where its writer must write.
    func beginSegment(_ kind: RecordingProject.Track.Kind, startOffsetSeconds: Double,
                      fileExtension: String = "mov") throws -> URL {
        guard var manifest, let package, manifest.state == .recording else { throw PackageError.notRecording }
        if !manifest.tracks.contains(where: { $0.kind == kind }) {
            manifest.tracks.append(.init(kind: kind, segments: []))
        }
        let index = manifest.tracks.firstIndex { $0.kind == kind }!
        let number = manifest.tracks[index].segments.count + 1
        let path = String(format: "media/%@/segment-%03d.%@", kind.rawValue, number, fileExtension)
        let url = try store.url(for: path, in: package)
        manifest.tracks[index].segments.append(.init(relativePath: path, startOffsetSeconds: startOffsetSeconds,
                                                     durationSeconds: nil, status: .recording))
        if kind == .camera { manifest.cameraRecovery = .keepScreenResumeInNewSegment }
        try store.writeManifest(manifest, in: package)
        self.manifest = manifest
        return url
    }

    /// Hands the writer for a segment to the session so stop can close it.
    func attach(_ writer: any SegmentFinishing, to url: URL) throws {
        guard let package, let manifest, manifest.state == .recording else { throw PackageError.notRecording }
        let resolved = try store.root.contain(url).path
        guard resolved.hasPrefix(package.path + "/") else { throw PackageError.outsideCompanyRecordings }
        let path = String(resolved.dropFirst(package.path.count + 1))
        guard manifest.tracks.contains(where: { $0.segments.contains { $0.relativePath == path } })
        else { throw PackageError.invalidPath }
        writers.append((path, writer))
    }

    /// Closes one segment while the recording goes on, so a new segment can take over.
    /// The writer stays registered until it has finished, so a concurrent stop still waits for it.
    func closeSegment(_ url: URL) async throws {
        guard let package else { throw PackageError.notRecording }
        let resolved = try store.root.contain(url).path
        guard resolved.hasPrefix(package.path + "/") else { throw PackageError.outsideCompanyRecordings }
        let path = String(resolved.dropFirst(package.path.count + 1))
        guard let entry = writers.first(where: { $0.path == path }) else { return }
        let seconds = await entry.writer.finishSegment()
        writers.removeAll { $0.writer === entry.writer }
        guard var manifest, manifest.state == .recording else { return }
        for t in manifest.tracks.indices {
            for s in manifest.tracks[t].segments.indices where manifest.tracks[t].segments[s].relativePath == path {
                let exists = FileManager.default.fileExists(atPath: package.appendingPathComponent(path).path)
                manifest.tracks[t].segments[s].status = exists ? .closed : .missing
                manifest.tracks[t].segments[s].durationSeconds = seconds
            }
        }
        try store.writeManifest(manifest, in: package)
        self.manifest = manifest
    }

    /// Marks the start of a range where a system video effect is drawn into the screen frames.
    /// Does nothing when a range is already open.
    func beginVideoEffect(_ kind: RecordingManifest.VideoEffectRange.Kind, atOffset offset: Double) throws {
        guard var manifest, let package, manifest.state == .recording else { throw PackageError.notRecording }
        var effects = manifest.videoEffects ?? []
        if effects.last.map({ $0.endOffsetSeconds == nil }) == true { return }
        effects.append(.init(kind: kind, startOffsetSeconds: max(0, offset), endOffsetSeconds: nil, flattened: true))
        manifest.videoEffects = effects
        try store.writeManifest(manifest, in: package)
        self.manifest = manifest
    }

    /// Closes the open video effect range, if any.
    func endVideoEffect(atOffset offset: Double) throws {
        guard var manifest, let package, manifest.state == .recording else { throw PackageError.notRecording }
        guard var effects = manifest.videoEffects, let last = effects.indices.last,
              effects[last].endOffsetSeconds == nil else { return }
        effects[last].endOffsetSeconds = max(effects[last].startOffsetSeconds, offset)
        manifest.videoEffects = effects
        try store.writeManifest(manifest, in: package)
        self.manifest = manifest
    }

    /// Marks the start of a range with no camera frames. Does nothing when a gap is already open.
    func beginCameraGap(_ reason: RecordingManifest.CameraGap.Reason, atOffset offset: Double) throws {
        try update { Self.beginGap(&$0.cameraGaps, reason, at: offset) }
    }

    /// Closes the open camera gap, if any, when camera frames arrive again.
    func endCameraGap(atOffset offset: Double) throws {
        try update { Self.endGap(&$0.cameraGaps, at: offset) }
    }

    /// Marks the start of a range with no microphone audio. Does nothing when a gap is already open.
    func beginMicrophoneGap(_ reason: RecordingManifest.CameraGap.Reason, atOffset offset: Double) throws {
        try update { Self.beginGap(&$0.microphoneGaps, reason, at: offset) }
    }

    /// Closes the open microphone gap, if any, when audio arrives again.
    func endMicrophoneGap(atOffset offset: Double) throws {
        try update { Self.endGap(&$0.microphoneGaps, at: offset) }
    }

    /// Marks the start of a silent microphone range. Does nothing when one is already open.
    func beginMicrophoneSilence(atOffset offset: Double) throws {
        try update { manifest in
            var ranges = manifest.microphoneSilence ?? []
            if ranges.last.map({ $0.endOffsetSeconds == nil }) == true { return }
            ranges.append(.init(startOffsetSeconds: max(0, offset), endOffsetSeconds: nil))
            manifest.microphoneSilence = ranges
        }
    }

    /// Closes the open silent range, if any, when sound comes back.
    func endMicrophoneSilence(atOffset offset: Double) throws {
        try update { manifest in
            guard var ranges = manifest.microphoneSilence, let last = ranges.indices.last,
                  ranges[last].endOffsetSeconds == nil else { return }
            ranges[last].endOffsetSeconds = max(ranges[last].startOffsetSeconds, offset)
            manifest.microphoneSilence = ranges
        }
    }

    /// Records whether the narration ever rose above silence, and its loudest level.
    func recordMicrophoneLevel(silent: Bool, peakDBFS: Double?) throws {
        try update { manifest in
            manifest.microphoneSilent = silent
            manifest.microphonePeakDBFS = peakDBFS
        }
    }

    /// Records the pauses so far. Empty lists leave the field absent.
    func recordPauses(_ ranges: [RecordingManifest.PausedRange]) throws {
        try update { $0.pausedRanges = ranges.isEmpty ? nil : ranges }
    }

    /// Saves the teleprompter script into the package and references it from the manifest.
    /// Called again, it replaces the script with the latest text.
    func saveTeleprompter(_ script: TeleprompterScript) throws {
        guard let package, manifest?.state == .recording else { throw PackageError.notRecording }
        try store.writeJSON(script.clamped(), to: TeleprompterScript.relativePath, in: package)
        try update { $0.teleprompter = TeleprompterScript.relativePath }
    }

    /// Records where the camera bubble sits in the live preview, so the editor opens with it there.
    func placeWebcam(_ placement: RecordingProject.WebcamPlacement) throws {
        guard let manifest, manifest.state == .recording else { throw PackageError.notRecording }
        try RecordingProject(id: manifest.id, title: manifest.title, tracks: [], trim: nil, webcam: placement).validate()
        try update { $0.webcam = placement }
    }

    private static func beginGap(_ gaps: inout [RecordingManifest.CameraGap]?,
                                 _ reason: RecordingManifest.CameraGap.Reason, at offset: Double) {
        var list = gaps ?? []
        if list.last.map({ $0.endOffsetSeconds == nil }) == true { return }
        list.append(.init(reason: reason, startOffsetSeconds: max(0, offset), endOffsetSeconds: nil))
        gaps = list
    }

    private static func endGap(_ gaps: inout [RecordingManifest.CameraGap]?, at offset: Double) {
        guard var list = gaps, let last = list.indices.last, list[last].endOffsetSeconds == nil else { return }
        list[last].endOffsetSeconds = max(list[last].startOffsetSeconds, offset)
        gaps = list
    }

    /// Opens a range for a camera effect. Does nothing when that effect already has an open range.
    func beginCameraEffect(_ kind: RecordingManifest.CameraEffectRange.Kind, atOffset offset: Double) throws {
        try update { manifest in
            var effects = manifest.cameraEffects ?? []
            if effects.contains(where: { $0.kind == kind && $0.endOffsetSeconds == nil }) { return }
            effects.append(.init(kind: kind, startOffsetSeconds: max(0, offset), endOffsetSeconds: nil))
            manifest.cameraEffects = effects
        }
    }

    /// Closes the open range for a camera effect, if any.
    func endCameraEffect(_ kind: RecordingManifest.CameraEffectRange.Kind, atOffset offset: Double) throws {
        try update { manifest in
            guard var effects = manifest.cameraEffects,
                  let index = effects.lastIndex(where: { $0.kind == kind && $0.endOffsetSeconds == nil })
            else { return }
            effects[index].endOffsetSeconds = max(effects[index].startOffsetSeconds, offset)
            manifest.cameraEffects = effects
        }
    }

    /// Applies a change to a recording manifest and writes it. Unchanged manifests are not rewritten.
    private func update(_ change: (inout RecordingManifest) -> Void) throws {
        guard var manifest, let package, manifest.state == .recording else { throw PackageError.notRecording }
        let before = manifest
        change(&manifest)
        guard manifest != before else { return }
        try store.writeManifest(manifest, in: package)
        self.manifest = manifest
    }

    /// Stops and finalizes when free space drops below the store's floor. Returns true when it stopped.
    func stopIfLowOnDisk() async throws -> Bool {
        guard isRecording, !store.hasRoomToRecord() else { return false }
        _ = try await stop(reason: "low-disk-space")
        return true
    }

    /// Closes every writer, records durations and missing files, writes the timeline,
    /// saves an unapproved draft placeholder and refreshes sync state.
    func stop(reason: String? = nil, originHostTime: Double? = nil) async throws -> RecordingManifest {
        guard var manifest, let package, manifest.state == .recording else { throw PackageError.notRecording }
        manifest.state = .finalizing
        manifest.stopReason = reason
        try store.writeManifest(manifest, in: package)
        self.manifest = manifest

        var durations: [String: Double] = [:]
        for (path, writer) in writers {
            if let seconds = await writer.finishSegment() { durations[path] = seconds }
        }
        writers.removeAll()
        for t in manifest.tracks.indices {
            for s in manifest.tracks[t].segments.indices {
                let path = manifest.tracks[t].segments[s].relativePath
                let exists = FileManager.default.fileExists(atPath: package.appendingPathComponent(path).path)
                manifest.tracks[t].segments[s].status = exists ? .closed : .missing
                if let seconds = durations[path] { manifest.tracks[t].segments[s].durationSeconds = seconds }
            }
        }
        try store.writeJSON(store.timeline(for: manifest, originHostTime: originHostTime),
                            to: manifest.timeline, in: package)
        if manifest.drafts.isEmpty {
            try store.appendDraft(body: "", source: "recording-stopped", to: &manifest, in: package)
        }
        manifest.state = .saved
        manifest.sync = .init(await syncChecker.observe(vaultKey: manifest.vaultKey), at: SessionStatus.now())
        try store.writeManifest(manifest, in: package)
        self.manifest = manifest
        return manifest
    }

    /// Re-reads sync state for a saved package, for retry after offline or failed sync.
    func refreshSync() async throws -> RecordingManifest.Sync {
        guard var manifest, let package, manifest.state == .saved else { throw PackageError.notRecording }
        manifest.sync = .init(await syncChecker.observe(vaultKey: manifest.vaultKey), at: SessionStatus.now())
        try store.writeManifest(manifest, in: package)
        self.manifest = manifest
        return manifest.sync
    }
}
