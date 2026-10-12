import AppKit
import AVFoundation
import AVKit
import Foundation
import SwiftUI

/// The trim controls for the recording that was just saved. The player shows the whole recording,
/// screen with the camera drawn at its saved placement and the narration underneath, so the in and
/// out points are picked against synchronized playback. The camera can be moved, resized, hidden
/// and shown over the player. Every change is saved as an edit revision. The finished cut can be
/// exported as an MP4 into the recording's own exports folder and shown in Finder.
@MainActor @Observable
final class TrimModel {
    private(set) var document: TrimDocument
    let player: AVPlayer
    /// Where the playhead is, in seconds from the recording start.
    private(set) var position = 0.0
    /// Why the last change was refused, in plain words.
    private(set) var note: String?
    /// The screen layer's size, which sets the player's shape.
    let screenSize: CGSize
    /// Whether the recording has camera footage to place.
    let hasCamera: Bool
    private let playback: PlaybackLayers.Playback
    /// True while an export runs. Edits wait until it finishes or is cancelled.
    private(set) var exporting = false
    /// The last finished export, for Show in Finder.
    private(set) var lastExport: URL?
    private var exportTask: Task<Void, Never>?

    var duration: Double { document.editor.duration }
    var start: Double { document.editor.start }
    var end: Double { document.editor.end }
    var canUndo: Bool { document.editor.canUndo }
    var isTrimmed: Bool { document.editor.range != nil }
    var webcam: RecordingProject.WebcamPlacement { document.manifest.webcam }

    init(document: TrimDocument, playback: PlaybackLayers.Playback) {
        self.document = document
        self.playback = playback
        let item = AVPlayerItem(asset: playback.composition)
        item.videoComposition = PlaybackLayers.videoComposition(playback, webcam: document.manifest.webcam)
        self.player = AVPlayer(playerItem: item)
        screenSize = playback.tracks[.screen]?.naturalSize ?? CGSize(width: 16, height: 9)
        hasCamera = playback.tracks[.camera] != nil
        if document.editor.duration < TrimEditor.minimumLength {
            note = Self.message(.emptyRecording)
        }
        player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, time.seconds.isFinite else { return }
                self.position = time.seconds
            }
        }
    }

    /// Opens a saved recording for trimming. Nil, with the reason logged, when it can't be read.
    static func load(package: URL, store: RecordingPackageStore) async -> TrimModel? {
        do {
            let document = try await TrimDocument.open(package, store: store)
            let playback = try await PlaybackLayers.preview(package: package, timeline: document.timeline,
                                                            webcam: document.manifest.webcam)
            return TrimModel(document: document, playback: playback)
        } catch {
            NSLog("HQ recorder: could not open the recording for trimming: \(error)")
            return nil
        }
    }

    func setStart() { edit { try $0.setStart(self.position) } }
    func setEnd() { edit { try $0.setEnd(self.position) } }
    func clear() { edit { try $0.clear() } }
    func undo() { edit { try $0.undo() } }

    /// Saves a new camera placement and redraws the player with it, at the same moment.
    func place(_ webcam: RecordingProject.WebcamPlacement) {
        edit { try $0.setWebcam(webcam) }
        guard let item = player.currentItem,
              let video = PlaybackLayers.videoComposition(playback, webcam: self.webcam) else { return }
        item.videoComposition = video
        // A paused player keeps the old picture until it is asked for a frame again.
        player.seek(to: player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func toggleCamera() {
        var next = webcam
        next.visible.toggle()
        place(next)
    }

    /// Moves the playhead to a fraction of the recording.
    func seek(fraction: Double) {
        guard duration > 0, fraction.isFinite else { return }
        let seconds = min(max(0, fraction), 1) * duration
        position = seconds
        player.currentItem?.forwardPlaybackEndTime = .invalid
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Plays only the kept range.
    func playTrimmed() {
        player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: end, preferredTimescale: 600)
        position = start
        player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }

    /// "Keeps 0:01.2 to 0:04.5 (3.3 s) of 0:10.0", or the whole length when nothing is trimmed.
    var rangeText: String {
        let kept = String(format: "%.1f", end - start)
        guard isTrimmed else { return "Keeps the whole recording (\(kept) s)" }
        return "Keeps \(Self.clock(start)) to \(Self.clock(end)) (\(kept) s) of \(Self.clock(duration))"
    }

    static func clock(_ seconds: Double) -> String {
        let tenths = Int((max(0, seconds) * 10).rounded())
        return String(format: "%d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
    }

    /// Exports the current trim and camera placement as an MP4 inside the recording package.
    func export() {
        guard !exporting else { return }
        exporting = true
        note = nil
        lastExport = nil
        let document = self.document
        exportTask = Task { [weak self] in
            do {
                let result = try await document.exportVideo()
                self?.document.recordExport(result.manifest)
                self?.lastExport = result.url
            } catch {
                NSLog("HQ recorder: export did not finish: \(error)")
                self?.note = Self.exportMessage(error)
            }
            self?.exporting = false
            self?.exportTask = nil
        }
    }

    /// Stops a running export. Nothing it started writing is kept.
    func cancelExport() { exportTask?.cancel() }

    /// Selects the last export in Finder, where it can be shared with any app.
    func showExportInFinder() {
        guard let lastExport else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastExport])
    }

    static func exportMessage(_ error: any Error) -> String {
        let unchanged = "The recording and earlier exports are unchanged."
        switch error {
        case is CancellationError: return "Export cancelled. \(unchanged)"
        case PackageError.lowDiskSpace:
            return "There isn't enough free space to export this video. Free up some space and try again. \(unchanged)"
        case let error as TrimEditor.TrimError: return "\(message(error)) \(unchanged)"
        default: return "The video couldn't be exported. Try again. \(unchanged)"
        }
    }

    static func message(_ error: TrimEditor.TrimError) -> String {
        switch error {
        case .emptyRecording: "This recording has no playable video to trim."
        case .tooShort: "Keep at least a tenth of a second. The start has to come before the end."
        case .invalidRange, .outsideRecording: "That point is outside the recording."
        case .exportMismatch: "The trimmed video didn't come out the right length, so it wasn't kept."
        }
    }

    private func edit(_ change: (inout TrimDocument) throws -> Void) {
        // The export saves the manifest when it finishes, so edits wait for it.
        guard !exporting else { return }
        do {
            try change(&document)
            note = nil
        } catch let error as TrimEditor.TrimError {
            NSLog("HQ recorder: trim refused: \(error)")
            note = Self.message(error)
        } catch {
            NSLog("HQ recorder: edit could not be saved: \(error)")
            note = "The change couldn't be saved. The recording is unchanged."
        }
    }
}

/// Inline trim controls shown under the saved recording.
struct TrimTimeline: View {
    let model: TrimModel
    /// The placement while the camera is being dragged, before it is saved.
    @State private var dragging: RecordingProject.WebcamPlacement?

    private var playerSize: CGSize {
        let screen = model.screenSize
        guard screen.width > 0, screen.height > 0 else { return CGSize(width: 320, height: 180) }
        return CGSize(width: 320, height: (320 * screen.height / screen.width).rounded())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TRIM").font(.system(size: 12)).foregroundStyle(.secondary)
            VideoPlayer(player: model.player)
                .frame(width: playerSize.width, height: playerSize.height)
                .overlay(alignment: .topLeading) { camera }
            bar.frame(width: 320, height: 16)
                .accessibilityIdentifier("trimTimeline")
            Text(model.rangeText)
                .font(.system(size: 12).monospacedDigit())
                .accessibilityIdentifier("trimRange")
            HStack(spacing: 8) {
                Button("Set start") { model.setStart() }.accessibilityIdentifier("trimStart")
                Button("Set end") { model.setEnd() }.accessibilityIdentifier("trimEnd")
                Button("Undo") { model.undo() }.disabled(!model.canUndo).accessibilityIdentifier("trimUndo")
                Button("Clear trim") { model.clear() }.disabled(!model.isTrimmed).accessibilityIdentifier("trimClear")
                Button("Play trimmed") { model.playTrimmed() }.accessibilityIdentifier("trimPlay")
            }
            .disabled(model.exporting)
            if model.hasCamera {
                HStack(spacing: 8) {
                    Button(model.webcam.visible ? "Hide camera" : "Show camera") { model.toggleCamera() }
                        .disabled(model.exporting)
                        .accessibilityIdentifier("trimCameraToggle")
                    if model.webcam.visible {
                        Text("Drag the camera to move it. Drag its corner to resize.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 8) {
                if model.exporting {
                    ProgressView().controlSize(.small)
                    Text("Exporting…").font(.system(size: 12))
                    Button("Cancel") { model.cancelExport() }.accessibilityIdentifier("trimExportCancel")
                } else {
                    Button("Export video") { model.export() }
                        .disabled(model.duration < TrimEditor.minimumLength)
                        .accessibilityIdentifier("trimExport")
                    if model.lastExport != nil {
                        Button("Show in Finder") { model.showExportInFinder() }
                            .accessibilityIdentifier("trimShowInFinder")
                        Text("Saved as an MP4 in this recording.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .accessibilityIdentifier("trimExportDone")
                    }
                }
            }
            if let note = model.note {
                Text(note).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("trimNote")
            }
            Text("Trimming only changes what plays and exports. The recorded files stay as they are. Exports stay on this Mac until you share them.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// An outline over the camera in the player. Dragging it moves the camera; dragging the square
    /// in its lower-right corner resizes it. The placement is saved when the drag ends.
    @ViewBuilder private var camera: some View {
        if model.hasCamera, model.webcam.visible {
            let size = playerSize
            let saved = model.webcam
            let bubble = WebcamBubble.frame(dragging ?? saved, in: size)
            ZStack(alignment: .bottomTrailing) {
                Rectangle().stroke(Color.white, lineWidth: 1)
                    .contentShape(Rectangle())
                    .gesture(DragGesture()
                        .onChanged { dragging = WebcamBubble.moved(saved, by: $0.translation, in: size) }
                        .onEnded {
                            model.place(WebcamBubble.moved(saved, by: $0.translation, in: size))
                            dragging = nil
                        })
                    .accessibilityIdentifier("trimCameraBubble")
                Rectangle().fill(Color.white)
                    .frame(width: 8, height: 8)
                    .gesture(DragGesture()
                        .onChanged { dragging = WebcamBubble.resized(saved, by: $0.translation, in: size) }
                        .onEnded {
                            model.place(WebcamBubble.resized(saved, by: $0.translation, in: size))
                            dragging = nil
                        })
                    .accessibilityIdentifier("trimCameraResize")
            }
            .frame(width: bubble.width, height: bubble.height)
            .offset(x: bubble.minX, y: bubble.minY)
            .allowsHitTesting(!model.exporting)
        }
    }

    /// The whole recording as a gray track, the kept range drawn over it and the playhead on top.
    /// Clicking or dragging moves the playhead.
    private var bar: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let scale = model.duration > 0 ? width / model.duration : 0
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.secondary.opacity(0.25))
                Rectangle().fill(Color.primary.opacity(0.55))
                    .frame(width: max(0, (model.end - model.start) * scale))
                    .offset(x: model.start * scale)
                Rectangle().fill(Color.primary)
                    .frame(width: 2)
                    .offset(x: min(width - 2, model.position * scale))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard width > 0 else { return }
                model.seek(fraction: value.location.x / width)
            })
        }
    }
}
