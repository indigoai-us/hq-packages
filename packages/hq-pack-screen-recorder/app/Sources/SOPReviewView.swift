import AVKit
import AppKit
import SwiftUI

/// Review state for one saved recording package. Every edit is autosaved as an unapproved
/// draft revision in the package; approval and export are separate, explicit actions.
@MainActor
@Observable
final class SOPReviewModel {
    let package: URL
    let store: RecordingPackageStore
    let syncChecker: any SyncChecking
    let reviewer: String
    private(set) var document: SOPReviewDocument?
    private(set) var frames: [ScreenEvidence.Frame] = []
    private(set) var manifest: RecordingManifest?
    /// Plain-language result of the last action, or why it failed.
    private(set) var note: String?
    private(set) var isDrafting = false
    private(set) var isSaving = false
    private(set) var lastExport: SOPExportResult?
    let player = AVPlayer()
    private(set) var playerSegment: String?
    private var saveTask: Task<Void, Never>?
    private var pendingSave: Task<Void, Never>?

    init(package: URL, store: RecordingPackageStore, syncChecker: any SyncChecking = HQSyncCLIChecker(),
         reviewer: String = NSFullUserName().isEmpty ? NSUserName() : NSFullUserName()) {
        self.package = package
        self.store = store
        self.syncChecker = syncChecker
        self.reviewer = reviewer
        reload()
    }

    /// `--review-package <path>` opens the review for a saved package inside the launch destination.
    static func launch(_ arguments: [String], context: HQLaunchContext?) -> SOPReviewModel? {
        guard let index = arguments.firstIndex(of: "--review-package"), arguments.indices.contains(index + 1),
              let context else { return nil }
        let package = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        do {
            let store = RecordingPackageStore(root: try RecordingsRoot.resolve(company: context.company,
                                                                               destination: context.destination))
            _ = try store.root.contain(package)
            return SOPReviewModel(package: package, store: store)
        } catch {
            NSLog("HQ recorder: review package refused: \(error)")
            return nil
        }
    }

    func reload() {
        do {
            manifest = try store.readManifest(in: package)
            let loaded = try SOPReviewWorkflow.load(package: package, store: store)
            document = loaded.document
            frames = loaded.frames
        } catch SOPReviewError.noDraft {
            document = nil
        } catch {
            NSLog("HQ recorder: review could not load: \(error)")
            document = nil
            note = "The draft couldn't be opened."
        }
    }

    /// Drafts steps on this Mac from the saved narration and screen.
    func draftSteps() async {
        guard !isDrafting else { return }
        isDrafting = true
        note = "Drafting steps on this Mac…"
        defer { isDrafting = false }
        do {
            let screen = try? await ScreenEvidenceExtractor.extract(package: package, store: store,
                                                                    sampler: AVFrameSampler(),
                                                                    recognizer: VisionTextRecognizer(),
                                                                    syncChecker: syncChecker)
            let result = try await SOPDraftWorkflow.draft(package: package, store: store,
                                                          rewriter: OnDeviceSegmentRewriter(), screen: screen)
            reload()
            note = switch result.document.status {
            case .drafted: "Steps drafted. Review them below."
            case .partial: "Some steps couldn't be drafted. Fill in or remove the empty ones."
            case .noSupportedSteps, .refused: result.document.evidenceGap ?? "No steps could be drafted from this recording."
            }
        } catch {
            NSLog("HQ recorder: drafting failed: \(error)")
            note = "Steps couldn't be drafted."
        }
    }

    /// Applies one edit and autosaves shortly after, so typing does not write a revision per key.
    func edit(_ change: (inout SOPReviewDocument) throws -> Void) {
        guard var document else { return }
        do {
            try change(&document)
        } catch {
            note = Self.text(error)
            return
        }
        self.document = document
        lastExport = nil
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    /// Writes the current document as a new revision.
    func save() {
        serially { await $0.performSave() }
    }

    /// Saves, imports and exports all write the package manifest, so they run one at a time.
    @discardableResult
    private func serially(_ work: @escaping @MainActor (SOPReviewModel) async -> Void) -> Task<Void, Never> {
        let previous = saveTask
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await work(self)
        }
        saveTask = task
        return task
    }

    private func performSave() async {
        guard var copy = document else { return }
        let before = copy
        isSaving = true
        defer { isSaving = false }
        do {
            try await SOPReviewWorkflow.autosave(&copy, package: package, store: store, syncChecker: syncChecker)
            if document == before {
                document = copy
            } else {
                document?.history = copy.history
            }
            manifest = try store.readManifest(in: package)
        } catch {
            NSLog("HQ recorder: review autosave failed: \(error)")
            note = "The last change couldn't be saved. It is still shown here; try again."
        }
    }

    func approve() async {
        pendingSave?.cancel()
        edit { try $0.approve(reviewer: reviewer) }
        pendingSave?.cancel()
        guard document?.isApproved == true else { return }
        save()
        await saveTask?.value
        note = "Approved. You can export the SOP now."
    }

    func export() async {
        pendingSave?.cancel()
        save()
        await serially { await $0.performExport() }.value
    }

    private func performExport() async {
        do {
            let result = try await SOPExporter.export(package: package, store: store, syncChecker: syncChecker)
            lastExport = result
            manifest = result.manifest
            note = "Exported to \(result.folder). The skill draft is a file to review; it is not installed or run."
        } catch {
            note = Self.text(error)
        }
    }

    func importScreenshot(_ url: URL, step id: String) {
        serially { model in
            do {
                let path = try SOPReviewWorkflow.importScreenshot(from: url, package: model.package, store: model.store)
                model.edit { try $0.replaceScreenshot(step: id, with: .imported(image: path)) }
            } catch {
                model.note = Self.text(error)
            }
        }
    }

    /// Loads the screen segment that holds this moment and seeks to it.
    func seek(_ timelineSeconds: Double) {
        guard let manifest, let target = SOPReviewSeek.target(timelineSeconds: timelineSeconds, manifest: manifest),
              let url = try? store.url(for: target.segment, in: package) else { return }
        if playerSegment != target.segment {
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            playerSegment = target.segment
        }
        player.seek(to: CMTime(seconds: target.seconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func image(_ path: String) -> NSImage? {
        guard let url = try? store.url(for: path, in: package) else { return nil }
        return NSImage(contentsOf: url)
    }

    /// Frames that fall inside the step, or the nearest ones when none do.
    func frames(for step: SOPReviewDocument.Step) -> [ScreenEvidence.Frame] {
        SOPReviewWorkflow.frames(for: step, in: frames)
    }

    /// Approval, shown on its own line apart from where the files are stored.
    var approvalText: String {
        guard let document else { return "" }
        if document.isApproved {
            return "Approved by \(document.approval.reviewer ?? "you") at \(document.approval.approvedAt ?? ""). Editing a step clears the approval."
        }
        return "Not approved. Edits are kept as draft revisions until you approve."
    }

    var storageText: String {
        guard let manifest else { return "" }
        let saved = document?.history.last.map { "Draft revision \($0.revision) is saved in the recording package. " } ?? ""
        return saved + SessionController.saveStatus(manifest)
    }

    static func text(_ error: Error) -> String {
        switch error {
        case SOPReviewError.emptyInstruction(let step): "Step \(step) has no instruction. Write one or remove the step."
        case SOPReviewError.noSteps: "There are no steps to approve."
        case SOPReviewError.notApproved, SOPReviewError.approvalOutdated: "Approve the steps before exporting."
        case SOPReviewError.unreadableImage: "That file isn't an image the recorder can read."
        case SOPReviewError.invalidCrop: "That crop is too small."
        default: "That didn't work. The draft is unchanged."
        }
    }
}

/// Inline review: editable steps beside the recording, screenshots, approval and export.
struct SOPReviewSection: View {
    let model: SOPReviewModel
    @State private var newPrerequisite = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("REVIEW").font(.system(size: 12)).foregroundStyle(.secondary)
            if let document = model.document {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Title", text: binding(document.title) { doc, text in doc.setTitle(text) })
                            .font(.system(size: 17))
                            .accessibilityIdentifier("reviewTitle")
                        prerequisites(document)
                        ForEach(Array(document.steps.enumerated()), id: \.element.id) { offset, step in
                            stepRow(step, number: offset + 1, count: document.steps.count)
                        }
                        ForEach(document.removed) { step in
                            HStack {
                                Text("Removed: \(step.instruction.isEmpty ? "step without instruction" : step.instruction)")
                                    .foregroundStyle(.secondary).lineLimit(1)
                                Button("Restore") { model.edit { try $0.restoreStep(step.id) } }
                            }.font(.system(size: 12))
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VideoPlayer(player: model.player)
                        .frame(width: 280, height: 180)
                        .accessibilityIdentifier("reviewPlayer")
                }
                Text(model.approvalText)
                    .accessibilityIdentifier("approvalStatus")
                Text(model.storageText)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("reviewStorage")
                HStack {
                    Button("Approve steps") { Task { await model.approve() } }
                        .disabled(document.isApproved)
                        .accessibilityIdentifier("approveSteps")
                    Button("Export SOP and skill draft") { Task { await model.export() } }
                        .disabled(!document.isApproved)
                        .accessibilityIdentifier("exportSOP")
                }
            } else {
                Text("No draft steps yet. Draft them from the saved narration and screen.")
                    .foregroundStyle(.secondary)
                Button(model.isDrafting ? "Drafting…" : "Draft steps") { Task { await model.draftSteps() } }
                    .disabled(model.isDrafting)
                    .accessibilityIdentifier("draftSteps")
            }
            if let note = model.note {
                Text(note).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("reviewNote")
            }
        }
    }

    private func binding(_ value: String, _ set: @escaping (inout SOPReviewDocument, String) throws -> Void) -> Binding<String> {
        Binding(get: { value }, set: { text in model.edit { try set(&$0, text) } })
    }

    @ViewBuilder private func prerequisites(_ document: SOPReviewDocument) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Prerequisites").font(.system(size: 13, weight: .medium))
            ForEach(document.prerequisites) { p in
                HStack {
                    TextField("Prerequisite", text: binding(p.text) { doc, text in try doc.setPrerequisite(text, id: p.id) })
                    Text(p.inferred ? "Inferred from narration\(p.start.map { " at \(SOPExporter.clock($0))" } ?? "")" : "Added by you")
                        .font(.system(size: 11)).foregroundStyle(p.inferred ? .orange : .secondary)
                    if let start = p.start { Button("Play") { model.seek(start) }.font(.system(size: 11)) }
                    Button("Remove") { model.edit { try $0.removePrerequisite(p.id) } }.font(.system(size: 11))
                }
            }
            HStack {
                TextField("Add a prerequisite", text: $newPrerequisite)
                Button("Add") {
                    let text = newPrerequisite.trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty else { return }
                    model.edit { $0.addPrerequisite(text) }
                    newPrerequisite = ""
                }
            }
        }
    }

    @ViewBuilder private func stepRow(_ step: SOPReviewDocument.Step, number: Int, count: Int) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(number).").monospacedDigit()
                    TextField("Instruction", text: binding(step.instruction) { doc, text in
                        try doc.setInstruction(text, step: step.id)
                    }, axis: .vertical)
                    .accessibilityIdentifier("stepInstruction-\(number)")
                }
                HStack(spacing: 8) {
                    Button("Play \(SOPExporter.clock(step.evidence.start))–\(SOPExporter.clock(step.evidence.end))") {
                        model.seek(step.evidence.start)
                    }
                    Button("Up") { model.edit { try $0.moveStep(step.id, by: -1) } }.disabled(number == 1)
                    Button("Down") { model.edit { try $0.moveStep(step.id, by: 1) } }.disabled(number == count)
                    Button("Remove") { model.edit { try $0.removeStep(step.id) } }
                        .accessibilityIdentifier("removeStep-\(number)")
                    if step.uncertainty.level != .low {
                        Text("\(step.uncertainty.level.rawValue) uncertainty").foregroundStyle(.orange)
                    }
                }.font(.system(size: 11))
                Text("Said: \(step.evidence.transcriptText)")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }.frame(maxWidth: .infinity, alignment: .leading)
            screenshot(step)
        }
    }

    @ViewBuilder private func screenshot(_ step: SOPReviewDocument.Step) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if step.screenshot.omitted {
                Text("Screenshot left out").font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(width: 180, height: 100)
            } else if let path = step.screenshot.image, let image = model.image(path) {
                CropSurface(image: image, crop: step.screenshot.crop) { crop in
                    model.edit { try $0.cropScreenshot(step: step.id, to: crop) }
                }
                .frame(width: 180, height: 100)
            } else {
                Text("No screenshot. Drop an image here.").font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(width: 180, height: 100)
            }
            HStack(spacing: 6) {
                Menu("Replace") {
                    ForEach(model.frames(for: step), id: \.image) { frame in
                        Button("Frame at \(SOPExporter.clock(frame.timelineSeconds))") {
                            model.edit { try $0.replaceScreenshot(step: step.id,
                                                                  with: .frame(image: frame.image, timelineSeconds: frame.timelineSeconds)) }
                        }
                    }
                    Button("Drafted frame") { model.edit { try $0.resetScreenshot(step: step.id) } }
                }.fixedSize()
                Button(step.screenshot.omitted ? "Include" : "Omit") {
                    model.edit { try $0.setScreenshotOmitted(!step.screenshot.omitted, step: step.id) }
                }
                if step.screenshot.crop != nil {
                    Button("Uncrop") { model.edit { try $0.cropScreenshot(step: step.id, to: nil) } }
                }
            }.font(.system(size: 11))
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.importScreenshot(url, step: step.id)
            return true
        }
        .help("Drag across the screenshot to crop it. Drop an image file to replace it.")
    }
}

/// Shows a screenshot with its crop. Dragging across it sets a new crop.
struct CropSurface: View {
    let image: NSImage
    let crop: SOPReviewDocument.Crop?
    let onCrop: (SOPReviewDocument.Crop) -> Void
    @State private var drag: CGRect?

    var body: some View {
        GeometryReader { geo in
            let fitted = Self.fit(image.size, in: geo.size)
            ZStack(alignment: .topLeading) {
                Image(nsImage: image).resizable().frame(width: fitted.width, height: fitted.height)
                if let rect = drag ?? crop.map({ CGRect(x: $0.x * fitted.width, y: $0.y * fitted.height,
                                                        width: $0.width * fitted.width, height: $0.height * fitted.height) }) {
                    Rectangle().stroke(Color.accentColor, lineWidth: 2)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
            .frame(width: fitted.width, height: fitted.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 4).onChanged { value in
                drag = Self.rect(value.startLocation, value.location, in: fitted)
            }.onEnded { value in
                let rect = Self.rect(value.startLocation, value.location, in: fitted)
                drag = nil
                let next = SOPReviewDocument.Crop(x: rect.minX / fitted.width, y: rect.minY / fitted.height,
                                                  width: rect.width / fitted.width, height: rect.height / fitted.height)
                if next.isValid { onCrop(next) }
            })
        }
    }

    static func fit(_ size: CGSize, in box: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    static func rect(_ a: CGPoint, _ b: CGPoint, in size: CGSize) -> CGRect {
        let x0 = min(max(min(a.x, b.x), 0), size.width), x1 = min(max(max(a.x, b.x), 0), size.width)
        let y0 = min(max(min(a.y, b.y), 0), size.height), y1 = min(max(max(a.y, b.y), 0), size.height)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}
