import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

// SOP review and export (US-016).
//
// The review document is the editable copy of the newest segment-first SOP draft. Every change
// is autosaved as a new unapproved draft revision inside the package. Approval is a separate,
// explicit action that is bound to the exact content it approved; any later edit clears it.
// Export only runs from an approved revision and writes a new versioned folder inside the
// package. The skill draft it writes is a file to read, never installed or run.

enum SOPReviewError: Error, Equatable {
    case noDraft
    case unknownStep
    case unknownPrerequisite
    case invalidCrop
    case emptyInstruction(step: Int)
    case noSteps
    case notApproved
    case approvalOutdated
    case unreadableImage
    case exportExists
}

// MARK: - Document

struct SOPReviewDocument: Codable, Equatable, Sendable {
    /// What the reviewer picked to illustrate one step.
    struct Screenshot: Codable, Equatable, Sendable {
        enum Source: Codable, Equatable, Sendable {
            /// A frame of the screen track. `timelineSeconds` is where it sits on the recording clock.
            case frame(image: String, timelineSeconds: Double)
            /// An image the reviewer chose instead, copied into the package.
            case imported(image: String)
            case none(reason: String)
        }
        var source: Source
        /// The draft's own frame, kept so a replacement can be undone.
        var drafted: Source
        var omitted = false
        var crop: Crop?

        var image: String? {
            switch source {
            case .frame(let image, _), .imported(let image): image
            case .none: nil
            }
        }
    }

    /// Crop rectangle in unit coordinates, origin at the top left of the image.
    struct Crop: Codable, Equatable, Sendable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double

        var isValid: Bool {
            [x, y, width, height].allSatisfy(\.isFinite) && x >= 0 && y >= 0
                && width > 0.01 && height > 0.01 && x + width <= 1.000_001 && y + height <= 1.000_001
        }
    }

    struct Step: Codable, Equatable, Sendable, Identifiable {
        /// Stable across edits and reorders: `step-<candidate>` from the draft.
        var id: String
        var candidate: Int
        var instruction: String
        /// The instruction as drafted, nil when the draft had none (failed or pending step).
        var draftedInstruction: String?
        var evidence: SOPStep.Evidence
        var uncertainty: SOPStep.Uncertainty
        var flags: [String]
        var screenshot: Screenshot
    }

    struct Prerequisite: Codable, Equatable, Sendable, Identifiable {
        var id: String
        var text: String
        /// True when the drafter inferred it from narration; false when the reviewer added it.
        var inferred: Bool
        var start: Double?
        var end: Double?
    }

    struct Approval: Codable, Equatable, Sendable {
        enum State: String, Codable, Sendable { case unapproved, approved }
        var state: State = .unapproved
        var approvedAt: String?
        var reviewer: String?
        /// SHA-256 of the reviewed content at approval time.
        var contentHash: String?
    }

    struct HistoryEntry: Codable, Equatable, Sendable {
        var revision: String
        var savedAt: String
        var approval: Approval.State
        var steps: Int
    }

    var version = 1
    var title: String
    /// The SOP draft revision this review started from.
    var basedOn: String
    var steps: [Step]
    /// Steps the reviewer removed, kept so the removal is visible and can be undone.
    var removed: [Step] = []
    var prerequisites: [Prerequisite]
    var approval = Approval()
    var history: [HistoryEntry] = []

    var isApproved: Bool { approval.state == .approved && approval.contentHash == contentHash() }

    /// Builds the first review copy of a draft. Only the draft's own content is carried over.
    init(draft: SOPDraftDocument, draftPath: String, title: String) {
        self.title = title
        basedOn = draftPath
        steps = draft.steps.map { step in
            let source: Screenshot.Source = switch step.screenshot {
            case .frame(let image, let time): .frame(image: image, timelineSeconds: time)
            case .missing(let reason): .none(reason: reason)
            }
            return Step(id: "step-\(step.candidate)", candidate: step.candidate,
                        instruction: step.instruction ?? "", draftedInstruction: step.instruction,
                        evidence: step.evidence, uncertainty: step.uncertainty, flags: step.flags,
                        screenshot: Screenshot(source: source, drafted: source))
        }
        prerequisites = draft.prerequisites.enumerated().map { i, p in
            Prerequisite(id: "pre-\(i + 1)", text: p.text, inferred: true, start: p.start, end: p.end)
        }
    }

    /// Hash of everything the export is made from. Approval and history are left out.
    func contentHash() -> String {
        struct Content: Encodable {
            var title: String
            var basedOn: String
            var steps: [Step]
            var prerequisites: [Prerequisite]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(Content(title: title, basedOn: basedOn, steps: steps,
                                                prerequisites: prerequisites))) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Edits. Each one clears approval.

    private mutating func edited() { approval = Approval() }

    private func index(of id: String) throws -> Int {
        guard let i = steps.firstIndex(where: { $0.id == id }) else { throw SOPReviewError.unknownStep }
        return i
    }

    mutating func setTitle(_ text: String) {
        guard text != title else { return }
        title = text
        edited()
    }

    mutating func setInstruction(_ text: String, step id: String) throws {
        let i = try index(of: id)
        guard steps[i].instruction != text else { return }
        steps[i].instruction = text
        edited()
    }

    mutating func removeStep(_ id: String) throws {
        removed.append(steps.remove(at: try index(of: id)))
        edited()
    }

    /// Puts a removed step back in its original draft order.
    mutating func restoreStep(_ id: String) throws {
        guard let r = removed.firstIndex(where: { $0.id == id }) else { throw SOPReviewError.unknownStep }
        let step = removed.remove(at: r)
        steps.insert(step, at: steps.firstIndex { $0.candidate > step.candidate } ?? steps.endIndex)
        edited()
    }

    /// Moves a step to a new position, clamped to the list.
    mutating func moveStep(_ id: String, to position: Int) throws {
        let step = steps.remove(at: try index(of: id))
        steps.insert(step, at: min(max(position, 0), steps.count))
        edited()
    }

    mutating func moveStep(_ id: String, by offset: Int) throws {
        try moveStep(id, to: try index(of: id) + offset)
    }

    mutating func setPrerequisite(_ text: String, id: String) throws {
        guard let i = prerequisites.firstIndex(where: { $0.id == id }) else { throw SOPReviewError.unknownPrerequisite }
        guard prerequisites[i].text != text else { return }
        prerequisites[i].text = text
        edited()
    }

    mutating func removePrerequisite(_ id: String) throws {
        guard let i = prerequisites.firstIndex(where: { $0.id == id }) else { throw SOPReviewError.unknownPrerequisite }
        prerequisites.remove(at: i)
        edited()
    }

    /// Adds a prerequisite typed by the reviewer. It is not labeled inferred.
    mutating func addPrerequisite(_ text: String) {
        let next = (prerequisites.compactMap { Int($0.id.dropFirst(4)) }.max() ?? 0) + 1
        prerequisites.append(Prerequisite(id: "pre-\(next)", text: text, inferred: false))
        edited()
    }

    mutating func replaceScreenshot(step id: String, with source: Screenshot.Source) throws {
        let i = try index(of: id)
        steps[i].screenshot.source = source
        steps[i].screenshot.omitted = false
        steps[i].screenshot.crop = nil
        edited()
    }

    /// Goes back to the frame the draft picked.
    mutating func resetScreenshot(step id: String) throws {
        let i = try index(of: id)
        try replaceScreenshot(step: id, with: steps[i].screenshot.drafted)
    }

    mutating func setScreenshotOmitted(_ omitted: Bool, step id: String) throws {
        steps[try index(of: id)].screenshot.omitted = omitted
        edited()
    }

    mutating func cropScreenshot(step id: String, to crop: Crop?) throws {
        if let crop, !crop.isValid { throw SOPReviewError.invalidCrop }
        steps[try index(of: id)].screenshot.crop = crop
        edited()
    }

    /// The explicit review action. Refuses when there is nothing to approve or a kept step has no
    /// instruction. The approval only holds for the content as it is now.
    mutating func approve(reviewer: String, at time: String = SessionStatus.now()) throws {
        guard !steps.isEmpty else { throw SOPReviewError.noSteps }
        if let blank = steps.firstIndex(where: { $0.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            throw SOPReviewError.emptyInstruction(step: blank + 1)
        }
        approval = Approval(state: .approved, approvedAt: time, reviewer: reviewer, contentHash: contentHash())
    }

    mutating func revokeApproval() { edited() }
}

// MARK: - Seeking

/// Where a moment on the recording clock is inside the screen track's segment files.
struct SOPSeekTarget: Equatable, Sendable {
    var segment: String
    var seconds: Double
}

enum SOPReviewSeek {
    static func target(timelineSeconds: Double, manifest: RecordingManifest) -> SOPSeekTarget? {
        guard timelineSeconds.isFinite,
              let segments = manifest.tracks.first(where: { $0.kind == .screen })?.segments
                  .filter({ $0.status != .missing }).sorted(by: { $0.startOffsetSeconds < $1.startOffsetSeconds }),
              let first = segments.first else { return nil }
        let segment = segments.last { $0.startOffsetSeconds <= timelineSeconds } ?? first
        var seconds = max(0, timelineSeconds - segment.startOffsetSeconds)
        if let duration = segment.durationSeconds { seconds = min(seconds, duration) }
        return SOPSeekTarget(segment: segment.relativePath, seconds: seconds)
    }
}

// MARK: - Storage

struct SOPReviewLoaded: Equatable, Sendable {
    var document: SOPReviewDocument
    /// The saved revision the document was read from, nil for a fresh copy of the draft.
    var revisionPath: String?
    /// Screen evidence frames the reviewer can pick from.
    var frames: [ScreenEvidence.Frame]
}

enum SOPReviewWorkflow {
    /// Prefix of the draft revision `source` for review revisions.
    static let sourcePrefix = "sop-review"
    static let importedPrefix = "screenshots/review/"

    /// Opens the newest review revision for the newest SOP draft. When the draft is newer than
    /// every review revision, a fresh review copy of it is returned (not saved until edited).
    static func load(package: URL, store: RecordingPackageStore) throws -> SOPReviewLoaded {
        let manifest = try store.readManifest(in: package)
        var draft: (SOPDraftDocument, String)?
        var review: (SOPReviewDocument, String)?
        for entry in manifest.drafts.reversed() {
            let revision = try readRevision(entry.relativePath, package: package, store: store)
            if review == nil, revision.source.hasPrefix(sourcePrefix) {
                review = (try JSONDecoder().decode(SOPReviewDocument.self, from: Data(revision.body.utf8)), entry.relativePath)
            } else if revision.source.hasPrefix(SOPDraftWorkflow.sourcePrefix) {
                draft = (try JSONDecoder().decode(SOPDraftDocument.self, from: Data(revision.body.utf8)), entry.relativePath)
                break
            }
        }
        let frames = (try? evidence(manifest: manifest, package: package, store: store)?.frames) ?? []
        if let review, review.0.basedOn == draft?.1 || draft == nil {
            return SOPReviewLoaded(document: review.0, revisionPath: review.1, frames: frames)
        }
        guard let draft else { throw SOPReviewError.noDraft }
        return SOPReviewLoaded(document: SOPReviewDocument(draft: draft.0, draftPath: draft.1, title: manifest.title),
                               revisionPath: nil, frames: frames)
    }

    /// Saves the document as a new draft revision when it differs from the newest saved review.
    /// Selected screen frames are copied into `screenshots/review/` first, so a later evidence
    /// extraction cannot remove them. The revision is approved only when the document carries
    /// a current approval; every other save is unapproved. Returns the new revision path, or nil
    /// when nothing changed.
    @discardableResult
    static func autosave(_ document: inout SOPReviewDocument, package: URL, store: RecordingPackageStore,
                         syncChecker: any SyncChecking = HQSyncCLIChecker()) async throws -> String? {
        // Check sync before reading the manifest that gets written back, so a save or export that
        // finishes while this one waits is not overwritten with a stale copy.
        let observation = await syncChecker.observe(vaultKey: try store.readManifest(in: package).vaultKey)
        var manifest = try store.readManifest(in: package)
        let wasApproved = document.isApproved
        try keepSelectedScreenshots(&document, manifest: &manifest, package: package, store: store)
        if wasApproved, !document.isApproved {
            // Only the image paths moved to the kept copies; the reviewer approved these images.
            document.approval.contentHash = document.contentHash()
        }
        if let last = try latestReview(manifest: manifest, package: package, store: store),
           last.0.withoutHistory == document.withoutHistory {
            document.history = last.0.history
            return nil
        }
        let approval: DraftRevision.Approval = document.isApproved ? .approved : .unapproved
        let path = String(format: "drafts/draft-%03d.json", manifest.drafts.count + 1)
        document.history.append(.init(revision: path, savedAt: SessionStatus.now(),
                                      approval: document.approval.state, steps: document.steps.count))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let body = String(decoding: try encoder.encode(document), as: UTF8.self)
        manifest.sync = .init(observation, at: SessionStatus.now())
        try store.appendDraft(body: body, source: "\(sourcePrefix):\(approval.rawValue)", approval: approval,
                              to: &manifest, in: package)
        return path
    }

    /// Copies an image the reviewer picked into the package as PNG and returns its package path.
    static func importScreenshot(from url: URL, package: URL, store: RecordingPackageStore) throws -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw SOPReviewError.unreadableImage }
        var manifest = try store.readManifest(in: package)
        let path = importedPrefix + "imported-\(UUID().uuidString.lowercased()).png"
        try store.ensureDirectory("screenshots/review", in: package)
        try store.writeData(try ScreenEvidenceExtractor.png(image), to: path, in: package)
        manifest.screenshots.append(path)
        try store.writeManifest(manifest, in: package)
        return path
    }

    static func latestReview(manifest: RecordingManifest, package: URL,
                             store: RecordingPackageStore) throws -> (SOPReviewDocument, String, DraftRevision.Approval)? {
        for entry in manifest.drafts.reversed() {
            let revision = try readRevision(entry.relativePath, package: package, store: store)
            guard revision.source.hasPrefix(sourcePrefix) else { continue }
            return (try JSONDecoder().decode(SOPReviewDocument.self, from: Data(revision.body.utf8)),
                    entry.relativePath, revision.approval)
        }
        return nil
    }

    static func evidence(manifest: RecordingManifest, package: URL, store: RecordingPackageStore) throws -> ScreenEvidence? {
        guard let path = manifest.screenEvidence else { return nil }
        return try JSONDecoder().decode(ScreenEvidence.self, from: Data(contentsOf: store.url(for: path, in: package)))
    }

    private static func readRevision(_ path: String, package: URL, store: RecordingPackageStore) throws -> DraftRevision {
        try JSONDecoder().decode(DraftRevision.self, from: Data(contentsOf: store.url(for: path, in: package)))
    }

    private static func keepSelectedScreenshots(_ document: inout SOPReviewDocument, manifest: inout RecordingManifest,
                                                package: URL, store: RecordingPackageStore) throws {
        var added: [String] = []
        for i in document.steps.indices {
            guard case .frame(let image, let time) = document.steps[i].screenshot.source,
                  !image.hasPrefix(importedPrefix) else { continue }
            let kept = importedPrefix + "frame-\(Int((time * 1000).rounded())).png"
            let target = try store.url(for: kept, in: package)
            if !FileManager.default.fileExists(atPath: target.path) {
                try store.ensureDirectory("screenshots/review", in: package)
                try store.writeData(try Data(contentsOf: store.url(for: image, in: package)), to: kept, in: package)
            }
            if !manifest.screenshots.contains(kept) { added.append(kept) }
            document.steps[i].screenshot.source = .frame(image: kept, timelineSeconds: time)
            if document.steps[i].screenshot.drafted == .frame(image: image, timelineSeconds: time) {
                document.steps[i].screenshot.drafted = .frame(image: kept, timelineSeconds: time)
            }
        }
        guard !added.isEmpty else { return }
        manifest.screenshots += Array(Set(added)).sorted()
        try store.writeManifest(manifest, in: package)
    }
}

private extension SOPReviewDocument {
    var withoutHistory: SOPReviewDocument {
        var copy = self
        copy.history = []
        return copy
    }
}

// MARK: - Export

struct SOPExportResult: Equatable, Sendable {
    var folder: String
    var sop: String
    var skill: String?
    var images: [String: String]
    var manifest: RecordingManifest
}

/// Written next to the export so a reopened export keeps each step's image.
struct SOPExportRecord: Codable, Equatable, Sendable {
    struct Step: Codable, Equatable, Sendable {
        var number: Int
        var id: String
        var instruction: String
        var image: String?
        var sourceImage: String?
        var crop: SOPReviewDocument.Crop?
        var omitted: Bool
    }
    var version = 1
    var exportedAt: String
    var reviewRevision: String
    var approvedAt: String?
    var reviewer: String?
    var sop: String
    var skill: String?
    var steps: [Step]
}

enum SOPExporter {
    static let folderPrefix = "exports/"

    /// Exports the newest review revision. Refuses unless that saved revision is approved and its
    /// approval still matches its content. Writes `exports/vNNN/` and never replaces an export.
    static func export(package: URL, store: RecordingPackageStore, includeSkill: Bool = true,
                       syncChecker: any SyncChecking = HQSyncCLIChecker()) async throws -> SOPExportResult {
        // As in autosave: no suspension between reading the manifest and writing it back.
        let observation = await syncChecker.observe(vaultKey: try store.readManifest(in: package).vaultKey)
        var manifest = try store.readManifest(in: package)
        guard let latest = try SOPReviewWorkflow.latestReview(manifest: manifest, package: package, store: store)
        else { throw SOPReviewError.notApproved }
        let (document, revisionPath, savedApproval) = latest
        guard savedApproval == .approved, document.approval.state == .approved else { throw SOPReviewError.notApproved }
        guard document.isApproved else { throw SOPReviewError.approvalOutdated }

        // Folders already on disk count too, so an export that failed part way does not block the next.
        let onDisk = (try? FileManager.default.contentsOfDirectory(atPath: try store.url(for: "exports", in: package).path)) ?? []
        let number = ((manifest.exports ?? []).compactMap { path -> Substring? in
            let parts = path.split(separator: "/")
            return parts.count > 1 ? parts[1] : nil
        } + onDisk.map { Substring($0) }).compactMap { name -> Int? in
            name.hasPrefix("v") ? Int(name.dropFirst()) : nil
        }.max().map { $0 + 1 } ?? 1
        let folder = folderPrefix + String(format: "v%03d", number)
        guard !FileManager.default.fileExists(atPath: try store.url(for: folder, in: package).path)
        else { throw SOPReviewError.exportExists }
        try store.ensureDirectory(folder + "/images", in: package)

        var written: [String] = []
        var images: [String: String] = [:]
        var records: [SOPExportRecord.Step] = []
        for (i, step) in document.steps.enumerated() {
            var link: String?
            if !step.screenshot.omitted, let source = step.screenshot.image {
                let name = String(format: "images/step-%02d.png", i + 1)
                let data = try image(at: source, crop: step.screenshot.crop, package: package, store: store)
                try store.writeData(data, to: "\(folder)/\(name)", in: package)
                written.append("\(folder)/\(name)")
                images[step.id] = name
                link = name
            }
            records.append(.init(number: i + 1, id: step.id, instruction: step.instruction, image: link,
                                 sourceImage: step.screenshot.image, crop: step.screenshot.crop,
                                 omitted: step.screenshot.omitted))
        }

        let exportedAt = SessionStatus.now()
        let sop = "\(folder)/SOP.md"
        try store.writeData(Data(markdown(document, manifest: manifest, revision: revisionPath, version: number,
                                          exportedAt: exportedAt, images: images).utf8), to: sop, in: package)
        written.append(sop)
        var skill: String?
        if includeSkill {
            try store.ensureDirectory(folder + "/skill-draft", in: package)
            let path = "\(folder)/skill-draft/SKILL.md"
            try store.writeData(Data(skillDraft(document, manifest: manifest, revision: revisionPath,
                                                version: number).utf8), to: path, in: package)
            written.append(path)
            skill = path
        }
        let record = SOPExportRecord(exportedAt: exportedAt, reviewRevision: revisionPath,
                                     approvedAt: document.approval.approvedAt, reviewer: document.approval.reviewer,
                                     sop: "SOP.md", skill: includeSkill ? "skill-draft/SKILL.md" : nil, steps: records)
        try store.writeJSON(record, to: "\(folder)/export.json", in: package)
        written.append("\(folder)/export.json")

        manifest.exports = (manifest.exports ?? []) + written
        manifest.sync = .init(observation, at: SessionStatus.now())
        try store.writeManifest(manifest, in: package)
        return SOPExportResult(folder: folder, sop: sop, skill: skill, images: images, manifest: manifest)
    }

    /// Reads a package image, crops it when asked, and returns PNG data.
    static func image(at path: String, crop: SOPReviewDocument.Crop?, package: URL,
                      store: RecordingPackageStore) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(try store.url(for: path, in: package) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw SOPReviewError.unreadableImage }
        guard let crop else { return try ScreenEvidenceExtractor.png(image) }
        guard crop.isValid else { throw SOPReviewError.invalidCrop }
        let w = Double(image.width), h = Double(image.height)
        let rect = CGRect(x: (crop.x * w).rounded(), y: (crop.y * h).rounded(),
                          width: max(1, (crop.width * w).rounded()), height: max(1, (crop.height * h).rounded()))
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard let cropped = image.cropping(to: rect) else { throw SOPReviewError.invalidCrop }
        return try ScreenEvidenceExtractor.png(cropped)
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// One line of plain text: no line breaks, no leading Markdown block markers.
    static func line(_ text: String) -> String {
        var s = text.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        while let first = s.first, "#>-*+|".contains(first) { s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces) }
        return s
    }

    /// A YAML double-quoted scalar. JSON string syntax is valid YAML.
    static func yaml(_ text: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(line(text))) ?? Data("\"\"".utf8), as: UTF8.self)
    }

    static func slug(_ text: String) -> String {
        let s = text.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        return s.isEmpty ? "recorded-procedure" : String(s.prefix(64))
    }

    static func markdown(_ document: SOPReviewDocument, manifest: RecordingManifest, revision: String,
                         version: Int, exportedAt: String, images: [String: String]) -> String {
        var out = """
        ---
        title: \(yaml(document.title))
        company: \(yaml(manifest.company))
        recording: \(yaml(manifest.vaultPath))
        recording_id: \(yaml(manifest.id.uuidString.lowercased()))
        export_version: \(version)
        review_revision: \(yaml(revision))
        draft_revision: \(yaml(document.basedOn))
        approval: approved
        approved_at: \(yaml(document.approval.approvedAt ?? ""))
        approved_by: \(yaml(document.approval.reviewer ?? ""))
        exported_at: \(yaml(exportedAt))
        drafted_by: "on-device model, reviewed by a person"
        ---

        # \(line(document.title))

        """
        if !document.prerequisites.isEmpty {
            out += "\n## Prerequisites\n\n"
            for p in document.prerequisites {
                let label = p.inferred
                    ? " _(inferred from narration\(p.start.map { " at \(clock($0))" } ?? ""); confirm before use)_" : ""
                out += "- \(line(p.text))\(label)\n"
            }
        }
        out += "\n## Steps\n\n"
        for (i, step) in document.steps.enumerated() {
            out += "\(i + 1). \(line(step.instruction))\n"
            if let image = images[step.id] { out += "\n   ![Step \(i + 1)](\(image))\n\n" }
            out += "   Source: recording \(clock(step.evidence.start))–\(clock(step.evidence.end))\n\n"
        }
        out += "## Version history\n\n"
        for entry in document.history {
            out += "- \(entry.revision), \(entry.savedAt): \(entry.approval.rawValue), \(entry.steps) steps\n"
        }
        out += "- \(revision): approved by \(line(document.approval.reviewer ?? "")) at \(document.approval.approvedAt ?? "")\n"
        out += "- Export v\(String(format: "%03d", version)), \(exportedAt)\n"
        return out
    }

    static func skillDraft(_ document: SOPReviewDocument, manifest: RecordingManifest, revision: String,
                           version: Int) -> String {
        var out = """
        ---
        name: \(slug(document.title))
        description: \(yaml("Draft procedure from the recording \"\(document.title)\". Not reviewed as a skill."))
        status: draft
        approved_as_skill: false
        disable-model-invocation: true
        source_sop: "../SOP.md"
        source_review_revision: \(yaml(revision))
        recording: \(yaml(manifest.vaultPath))
        export_version: \(version)
        ---

        # \(line(document.title)) (draft)

        This is a draft written from a reviewed SOP. It has not been reviewed or approved as a skill. \
        It is not installed and nothing runs it. Review it before copying it into a skills folder.

        """
        if !document.prerequisites.isEmpty {
            out += "\n## Before you start\n\n"
            for p in document.prerequisites {
                out += "- \(line(p.text))\(p.inferred ? " (inferred from narration)" : "")\n"
            }
        }
        out += "\n## Steps\n\n"
        for (i, step) in document.steps.enumerated() { out += "\(i + 1). \(line(step.instruction))\n" }
        return out
    }
}

// MARK: - Command line

/// `--export-sop <package>` exports the newest approved review revision and exits.
/// `--no-skill` leaves out the skill draft. Exit codes: 0 exported, 1 not approved, 2 error.
enum ExportSOPCLI {
    static let flag = "--export-sop"
    static let noSkillFlag = "--no-skill"

    static func runIfRequested(_ arguments: [String]) -> Int32? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        guard arguments.indices.contains(index + 1), !arguments[index + 1].hasPrefix("--") else {
            FileHandle.standardError.write(Data("usage: \(flag) <path to .hqrec package> [\(noSkillFlag)]\n".utf8))
            return 2
        }
        let package = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        let includeSkill = !arguments.contains(noSkillFlag)
        let result = ExitBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            result.set(await run(package: package, includeSkill: includeSkill))
            done.signal()
        }
        done.wait()
        return result.value
    }

    static func run(package: URL, includeSkill: Bool = true,
                    syncChecker: any SyncChecking = HQSyncCLIChecker()) async -> Int32 {
        do {
            let recordings = package.standardizedFileURL.deletingLastPathComponent()
            let company = recordings.deletingLastPathComponent().lastPathComponent
            let store = RecordingPackageStore(root: try RecordingsRoot.resolve(company: company, destination: recordings))
            let result = try await SOPExporter.export(package: package, store: store, includeSkill: includeSkill,
                                                      syncChecker: syncChecker)
            FileHandle.standardOutput.write(Data("\(result.sop)\n".utf8))
            if let skill = result.skill { FileHandle.standardOutput.write(Data("\(skill)\n".utf8)) }
            return 0
        } catch SOPReviewError.notApproved, SOPReviewError.approvalOutdated {
            FileHandle.standardError.write(Data("SOP export refused: the newest review revision is not approved.\n".utf8))
            return 1
        } catch {
            NSLog("HQ recorder: SOP export failed: \(error)")
            FileHandle.standardError.write(Data("SOP export failed: \(error)\n".utf8))
            return 2
        }
    }

    private final class ExitBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Int32 = 2
        var value: Int32 { lock.withLock { stored } }
        func set(_ value: Int32) { lock.withLock { stored = value } }
    }
}
