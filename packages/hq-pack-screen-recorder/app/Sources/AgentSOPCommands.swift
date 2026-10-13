// Headless SOP review for the HQ session agent: `--review-sop` edits the newest review through the
// same operations the review window uses and saves a new draft revision, `--approve-sop` approves
// the newest revision for its exact content, and `--list-frames` lists the screen frames a step's
// screenshot can be picked from. Every save is a new `drafts/draft-NNN.json`; the recorded media,
// the drafted SOP and earlier revisions are never changed. Any edit clears an earlier approval.

import Foundation

/// One change `--review-sop` makes, applied in the order given. A step is named by its position
/// in the current list (1 is the first) or by its id, such as `step-2`.
enum SOPReviewEdit: Equatable, Sendable {
    /// `position` is 1-based.
    case move(step: String, position: Int)
    case reword(step: String, text: String)
    case drop(step: String)
    /// `step` is the id of a removed step.
    case restore(step: String)
    /// `frame` is a frame image path from `--list-frames`, or its time on the recording timeline.
    case screenshot(step: String, frame: String)
    case omitScreenshot(step: String)
    case crop(step: String, crop: SOPReviewDocument.Crop)
    case title(String)
    case prerequisiteAdd(String)
    /// `prerequisite` is its text or its id, such as `pre-1`.
    case prerequisiteRemove(String)
}

extension AgentCommandsCLI {
    // MARK: Parsing --review-sop

    /// `--review-sop <package>` and its edits, kept in the order given.
    static func parseReview(_ rest: [String]) throws -> AgentInvocation {
        let mode = "--review-sop"
        let arity = ["--move": 2, "--reword": 2, "--screenshot": 2, "--crop": 2, "--prerequisite": 2,
                     "--drop": 1, "--restore": 1, "--omit-screenshot": 1, "--title": 1]
        var package: URL?
        var json = false
        var edits: [SOPReviewEdit] = []
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
            } else if let count = arity[argument] {
                guard index + count < rest.count else {
                    throw AgentCommandError.usage(count == 1 ? "\(argument) needs a value."
                                                             : "\(argument) needs two values.")
                }
                let values = Array(rest[(index + 1)...(index + count)])
                edits.append(try reviewEdit(argument, values))
                index += count + 1
            } else if argument.hasPrefix("--") {
                throw AgentCommandError.usage("\(mode) does not take \(argument).")
            } else {
                index += 1
            }
        }
        guard let package else { throw AgentCommandError.usage("\(mode) needs the path to a .hqrec package.") }
        return AgentInvocation(command: .reviewSOP(edits), package: package, json: json)
    }

    private static func reviewEdit(_ option: String, _ values: [String]) throws -> SOPReviewEdit {
        let first = values[0]
        switch option {
        case "--move":
            guard let position = Int(values[1]), position >= 1 else {
                throw AgentCommandError.usage("--move needs a step and a position from 1, such as --move 3 1, "
                                              + "not \(values[1]).")
            }
            return .move(step: first, position: position)
        case "--reword": return .reword(step: first, text: values[1])
        case "--screenshot": return .screenshot(step: first, frame: values[1])
        case "--crop": return .crop(step: first, crop: try crop(values[1]))
        case "--prerequisite":
            switch first {
            case "add": return .prerequisiteAdd(values[1])
            case "remove": return .prerequisiteRemove(values[1])
            default: throw AgentCommandError.usage("--prerequisite needs add or remove, not \(first).")
            }
        case "--drop": return .drop(step: first)
        case "--restore": return .restore(step: first)
        case "--omit-screenshot": return .omitScreenshot(step: first)
        default: return .title(first)
        }
    }

    /// A `--crop x,y,w,h` value in 0 to 1 of the screenshot's width and height.
    private static func crop(_ text: String) throws -> SOPReviewDocument.Crop {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false).map {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        guard parts.count == 4, let x = parts[0], let y = parts[1], let width = parts[2], let height = parts[3] else {
            throw AgentCommandError.usage("--crop needs four numbers x,y,w,h from 0 to 1, such as 0.1,0.1,0.5,0.5, "
                                          + "not \(text).")
        }
        return .init(x: x, y: y, width: width, height: height)
    }

    // MARK: --review-sop

    static func reviewSOP(_ edits: [SOPReviewEdit], package: URL, store: RecordingPackageStore,
                          syncChecker: any SyncChecking) async throws -> AgentReviewResult {
        let unchanged = "No revision was written."
        let loaded = try loadReview(package: package, store: store)
        guard !edits.isEmpty else { return AgentReviewResult(loaded.document, revision: loaded.revisionPath, saved: false) }
        var document = loaded.document
        do {
            for edit in edits { try apply(edit, to: &document, frames: loaded.frames) }
        } catch let error as SOPReviewError {
            throw AgentCommandError.refused("\(reviewMessage(error)) \(unchanged)")
        } catch let error as AgentCommandError {
            throw AgentCommandError.refused("\(error) \(unchanged)")
        }
        guard document != loaded.document else { throw AgentCommandError.refused("Those edits change nothing. \(unchanged)") }
        let saved: String?
        do {
            saved = try await SOPReviewWorkflow.autosave(&document, package: package, store: store,
                                                         syncChecker: syncChecker,
                                                         expecting: SOPReviewWorkflow.head(of: loaded))
        } catch SOPReviewError.reviewChanged {
            throw AgentCommandError.refused("The guide changed since it was loaded. Review the latest version, "
                                            + "then make the edits again. \(unchanged)")
        }
        guard let path = saved else { throw AgentCommandError.refused("Those edits change nothing. \(unchanged)") }
        return AgentReviewResult(document, revision: path, saved: true)
    }

    private static func apply(_ edit: SOPReviewEdit, to document: inout SOPReviewDocument,
                              frames: [ScreenEvidence.Frame]) throws {
        switch edit {
        case .move(let step, let position):
            let id = try stepID(step, in: document)
            let target = min(position, document.steps.count) - 1
            if document.steps.firstIndex(where: { $0.id == id }) != target { try document.moveStep(id, to: target) }
        case .reword(let step, let text):
            let id = try stepID(step, in: document)
            let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty else {
                throw AgentCommandError.refused("A step needs an instruction. Use --drop \(step) to remove the step.")
            }
            try document.setInstruction(words, step: id)
        case .drop(let step):
            try document.removeStep(try stepID(step, in: document))
        case .restore(let step):
            let id = step.hasPrefix("step-") ? step : "step-\(step)"
            guard document.removed.contains(where: { $0.id == id }) else {
                let removed = document.removed.map(\.id)
                throw AgentCommandError.refused("No removed step is called \(step). "
                    + (removed.isEmpty ? "No steps have been removed." : "Removed steps: \(removed.joined(separator: ", ")).")) }
            try document.restoreStep(id)
        case .screenshot(let step, let frame):
            let id = try stepID(step, in: document)
            let seconds = Double(frame)
            guard let match = frames.first(where: { $0.image == frame })
                    ?? seconds.flatMap({ s in frames.first { abs($0.timelineSeconds - s) < 0.01 } }) else {
                throw AgentCommandError.refused("No screen frame matches \(frame). --list-frames shows the frames "
                                                + "a step can use.")
            }
            let current = document.steps.first { $0.id == id }?.screenshot
            if case .frame(_, let time) = current?.source, abs(time - match.timelineSeconds) < 0.0005,
               current?.omitted == false, current?.crop == nil { return }
            try document.replaceScreenshot(step: id, with: .frame(image: match.image,
                                                                 timelineSeconds: match.timelineSeconds))
        case .omitScreenshot(let step):
            let id = try stepID(step, in: document)
            if document.steps.first(where: { $0.id == id })?.screenshot.omitted != true {
                try document.setScreenshotOmitted(true, step: id)
            }
        case .crop(let step, let crop):
            let id = try stepID(step, in: document)
            if document.steps.first(where: { $0.id == id })?.screenshot.crop != crop {
                try document.cropScreenshot(step: id, to: crop)
            }
        case .title(let text):
            let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw AgentCommandError.refused("The title can't be empty.") }
            document.setTitle(title)
        case .prerequisiteAdd(let text):
            let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty else { throw AgentCommandError.refused("A prerequisite needs some words.") }
            document.addPrerequisite(words)
        case .prerequisiteRemove(let text):
            let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let found = document.prerequisites.first(where: {
                $0.id == words || $0.text.caseInsensitiveCompare(words) == .orderedSame
            }) else {
                throw AgentCommandError.refused("No prerequisite matches \"\(words)\". Give its text or its id, "
                                                + "such as pre-1.")
            }
            try document.removePrerequisite(found.id)
        }
    }

    /// The id of the step `reference` names: a position from 1, or an id such as `step-2`.
    private static func stepID(_ reference: String, in document: SOPReviewDocument) throws -> String {
        if let position = Int(reference) {
            guard document.steps.indices.contains(position - 1) else {
                throw AgentCommandError.refused("There is no step \(position). The review has "
                                                + "\(document.steps.count) step(s), numbered from 1.")
            }
            return document.steps[position - 1].id
        }
        guard document.steps.contains(where: { $0.id == reference }) else {
            throw AgentCommandError.refused("There is no step called \(reference). Name a step by its number, "
                                            + "such as 2, or its id, such as step-2.")
        }
        return reference
    }

    // MARK: --approve-sop

    static func approveSOP(reviewer: String, revision: String?, package: URL, store: RecordingPackageStore,
                           syncChecker: any SyncChecking) async throws -> AgentReviewResult {
        let loaded = try loadReview(package: package, store: store)
        if let revision, revision != loaded.revisionPath {
            let newest = loaded.revisionPath.map { "The newest review revision is \($0)." }
                ?? "The newest SOP draft has not been reviewed yet."
            throw AgentCommandError.refused("\(revision) is not the newest review revision, so it can't be approved. "
                                            + "\(newest) Check that one and approve it. Nothing was written.")
        }
        var document = loaded.document
        if document.isApproved {
            throw AgentCommandError.refused("This revision is already approved by \(document.approval.reviewer ?? "a reviewer"). "
                                            + "Nothing was written.")
        }
        do {
            try document.approve(reviewer: reviewer)
        } catch let error as SOPReviewError {
            throw AgentCommandError.refused("\(reviewMessage(error)) Nothing was written.")
        }
        let saved: String?
        do {
            saved = try await SOPReviewWorkflow.autosave(&document, package: package, store: store,
                                                         syncChecker: syncChecker,
                                                         expecting: SOPReviewWorkflow.head(of: loaded))
        } catch SOPReviewError.reviewChanged {
            throw AgentCommandError.refused("The guide changed since it was reviewed. Review the latest version, "
                                            + "then approve it. Nothing was written.")
        }
        guard let path = saved else {
            throw AgentCommandError.refused("This revision is already approved. Nothing was written.")
        }
        return AgentReviewResult(document, revision: path, saved: true)
    }

    // MARK: --list-frames

    static func listFrames(step: String?, package: URL, store: RecordingPackageStore) throws -> AgentFramesResult {
        guard let step else {
            let manifest = try store.readManifest(in: package)
            let frames = try SOPReviewWorkflow.evidence(manifest: manifest, package: package, store: store)?.frames ?? []
            return AgentFramesResult(step: nil, frames: frames.map(AgentFramesResult.Frame.init))
        }
        let loaded = try loadReview(package: package, store: store)
        let id = try stepID(step, in: loaded.document)
        guard let found = loaded.document.steps.first(where: { $0.id == id }) else {
            throw AgentCommandError.refused("There is no step called \(step).")
        }
        return AgentFramesResult(step: id, frames: SOPReviewWorkflow.frames(for: found, in: loaded.frames)
            .map(AgentFramesResult.Frame.init))
    }

    // MARK: Shared

    private static func loadReview(package: URL, store: RecordingPackageStore) throws -> SOPReviewLoaded {
        do {
            return try SOPReviewWorkflow.load(package: package, store: store)
        } catch SOPReviewError.noDraft {
            throw AgentCommandError.refused("This recording has no SOP draft yet, so there is nothing to review. "
                                            + "Run --draft-sop first.")
        }
    }

    static func reviewMessage(_ error: SOPReviewError) -> String {
        switch error {
        case .noDraft: "This recording has no SOP draft yet."
        case .unknownStep: "That step is not in the review."
        case .unknownPrerequisite: "That prerequisite is not in the review."
        case .invalidCrop: "A crop needs x and y of 0 or more, a width and height above 0.01, and must stay "
            + "inside the screenshot (x + w and y + h at most 1)."
        case .emptyInstruction(let step): "Step \(step) has no instruction. Give it one with --review-sop --reword "
            + "\(step) <text>, or drop it, before approving."
        case .noSteps: "The review has no steps, so there is nothing to approve."
        case .notApproved, .approvalOutdated: "The newest review revision is not approved."
        case .unreadableImage: "That image could not be read."
        case .exportExists: "That export already exists."
        case .reviewChanged: "The guide changed since it was loaded. Review the latest version and try again."
        }
    }
}

// MARK: Results

/// The review as it stands after `--review-sop` or `--approve-sop`.
struct AgentReviewResult: Codable, Equatable, Sendable {
    struct Step: Codable, Equatable, Sendable {
        var number: Int
        var id: String
        var instruction: String
        /// Package path of the screenshot, nil when there is none.
        var screenshot: String?
        var screenshotSeconds: Double?
        var screenshotOmitted: Bool
        var crop: SOPReviewDocument.Crop?
        var flags: [String]
    }

    struct Removed: Codable, Equatable, Sendable {
        var id: String
        var instruction: String
    }

    /// The saved review revision; nil when the newest draft has not been reviewed yet.
    var revision: String?
    /// True when this command wrote `revision`.
    var saved: Bool
    var approved: Bool
    var reviewer: String?
    var title: String
    var basedOn: String
    var steps: [Step]
    var removed: [Removed]
    var prerequisites: [SOPReviewDocument.Prerequisite]

    init(_ document: SOPReviewDocument, revision: String?, saved: Bool) {
        self.revision = revision
        self.saved = saved
        approved = document.isApproved
        reviewer = document.isApproved ? document.approval.reviewer : nil
        title = document.title
        basedOn = document.basedOn
        steps = document.steps.enumerated().map { index, step in
            var seconds: Double?
            if case .frame(_, let time) = step.screenshot.source { seconds = time }
            return Step(number: index + 1, id: step.id, instruction: step.instruction, screenshot: step.screenshot.image,
                        screenshotSeconds: seconds, screenshotOmitted: step.screenshot.omitted,
                        crop: step.screenshot.crop, flags: step.flags)
        }
        removed = document.removed.map { Removed(id: $0.id, instruction: $0.instruction) }
        prerequisites = document.prerequisites
    }

    var lines: [String] {
        var lines = [saved ? "saved \(revision ?? "")" : "review: \(revision ?? "not saved yet")",
                     "\(title): " + (approved ? "approved by \(reviewer ?? "a reviewer")" : "not approved")]
        for step in steps {
            let picture = step.screenshotOmitted ? "no screenshot" : (step.screenshot ?? "no screenshot")
            lines.append("\(step.number). [\(step.id)] \(step.instruction.isEmpty ? "(no instruction)" : step.instruction)"
                         + " (\(picture)\(step.crop == nil ? "" : ", cropped"))")
        }
        if !removed.isEmpty { lines.append("removed: " + removed.map(\.id).joined(separator: ", ")) }
        for prerequisite in prerequisites { lines.append("needs [\(prerequisite.id)]: \(prerequisite.text)") }
        return lines
    }
}

/// Screen frames a step's screenshot can be picked from, for `--review-sop --screenshot`.
struct AgentFramesResult: Codable, Equatable, Sendable {
    struct Frame: Codable, Equatable, Sendable {
        var image: String
        var timelineSeconds: Double
        var width: Int
        var height: Int

        init(_ frame: ScreenEvidence.Frame) {
            image = frame.image
            timelineSeconds = frame.timelineSeconds
            width = frame.width
            height = frame.height
        }
    }

    /// The step the frames are for; nil when every frame is listed.
    var step: String?
    var frames: [Frame]

    var lines: [String] {
        guard !frames.isEmpty else { return ["no screen frames; run --extract-screen-evidence first"] }
        return frames.map { "\($0.image) at \(AgentCommandsCLI.format($0.timelineSeconds))s" }
    }
}
