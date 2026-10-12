// Nondestructive trimming. The in and out points are an edit decision saved as a new edit
// revision; the recorded media files are only read.

import AVFoundation
import Foundation

/// The in and out points of one saved recording, with undo. A nil range keeps the whole recording.
struct TrimEditor: Equatable, Sendable {
    /// Shortest range that may be kept, so a near-empty selection never passes as a video.
    static let minimumLength = 0.1
    /// Slack for an end point that rounds a little past the recording, in seconds.
    static let tolerance = 0.05

    enum TrimError: Error, Equatable {
        /// The recording has no playable media to keep.
        case emptyRecording
        /// A point is not a finite time, or the start is before zero.
        case invalidRange
        /// The end is past the end of the recording.
        case outsideRecording
        /// The kept range is shorter than `minimumLength`, including zero-length and reversed ranges.
        case tooShort
        /// The exported file is missing, unreadable or does not match the kept range.
        case exportMismatch
    }

    let duration: Double
    private(set) var range: RecordingProject.TrimRange?
    private var history: [RecordingProject.TrimRange?] = []

    init(duration: Double, range: RecordingProject.TrimRange?) {
        self.duration = duration
        self.range = range
    }

    var start: Double { range?.start ?? 0 }
    var end: Double { range?.end ?? duration }
    var canUndo: Bool { !history.isEmpty }

    /// The range to keep, or an error when it is invalid, too short or outside a recording of
    /// `duration` seconds. The end is clamped to the recording when it is within `tolerance`.
    static func check(_ range: RecordingProject.TrimRange?, duration: Double) throws -> RecordingProject.TrimRange {
        guard duration.isFinite, duration >= minimumLength else { throw TrimError.emptyRecording }
        let kept = range ?? .init(start: 0, end: duration)
        guard kept.start.isFinite, kept.end.isFinite, kept.start >= 0 else { throw TrimError.invalidRange }
        guard kept.end <= duration + tolerance else { throw TrimError.outsideRecording }
        let clamped = RecordingProject.TrimRange(start: kept.start, end: min(kept.end, duration))
        guard clamped.end - clamped.start >= minimumLength else { throw TrimError.tooShort }
        return clamped
    }

    mutating func setStart(_ seconds: Double) throws {
        try apply(.init(start: try clamp(seconds), end: end))
    }

    mutating func setEnd(_ seconds: Double) throws {
        try apply(.init(start: start, end: try clamp(seconds)))
    }

    /// Keeps the whole recording again.
    mutating func clear() {
        guard range != nil else { return }
        history.append(range)
        range = nil
    }

    /// Goes back to the range before the last change. Returns false when there is nothing to undo.
    @discardableResult mutating func undo() -> Bool {
        guard let previous = history.popLast() else { return false }
        range = previous
        return true
    }

    private func clamp(_ seconds: Double) throws -> Double {
        guard seconds.isFinite else { throw TrimError.invalidRange }
        return min(max(0, seconds), duration)
    }

    private mutating func apply(_ next: RecordingProject.TrimRange) throws {
        let kept = try Self.check(next, duration: duration)
        let normalized: RecordingProject.TrimRange? = kept.start <= 0 && kept.end >= duration ? nil : kept
        guard normalized != range else { return }
        history.append(range)
        range = normalized
    }
}

/// One saved recording open for trimming. Every change appends an edit revision through the
/// package store, so undo and reopening show the same range and the media files stay as recorded.
struct TrimDocument: Sendable {
    let store: RecordingPackageStore
    let package: URL
    let timeline: RecordingTimeline
    private(set) var manifest: RecordingManifest
    private(set) var editor: TrimEditor

    /// Opens the package and measures the recording from its media under the saved webcam
    /// placement, the same layers playback and export use. The saved trim is restored as is.
    static func open(_ package: URL, store: RecordingPackageStore) async throws -> TrimDocument {
        let manifest = try store.open(package)
        let timeline = try JSONDecoder().decode(RecordingTimeline.self, from: Data(
            contentsOf: store.url(for: manifest.timeline, in: package)))
        let duration = try await PlaybackLayers.composition(package: package, timeline: timeline,
                                                            webcam: manifest.webcam).duration.seconds
        return TrimDocument(store: store, package: package, timeline: timeline, manifest: manifest,
                            editor: TrimEditor(duration: duration, range: manifest.trim))
    }

    mutating func setStart(_ seconds: Double) throws { try change { try $0.setStart(seconds) } }
    mutating func setEnd(_ seconds: Double) throws { try change { try $0.setEnd(seconds) } }
    mutating func clear() throws { try change { $0.clear() } }
    mutating func undo() throws { try change { _ = $0.undo() } }

    /// Saves a moved, resized, hidden or shown camera as a new revision, keeping the current trim.
    /// A placement that isn't valid is refused and nothing is saved.
    mutating func setWebcam(_ webcam: RecordingProject.WebcamPlacement) throws {
        guard webcam != manifest.webcam else { return }
        try store.appendEdit(trim: editor.range, webcam: webcam, to: &manifest, in: package)
    }

    /// Writes a shareable MP4 of the current trim and camera placement into the package's exports
    /// folder. The returned manifest lists it; pass it to `recordExport` to keep this document current.
    func exportVideo() async throws -> (url: URL, manifest: RecordingManifest) {
        try await store.exportVideo(manifest: manifest, timeline: timeline, in: package)
    }

    /// Takes the manifest an export saved. Refused when it belongs to another recording or changes
    /// anything besides the export list.
    mutating func recordExport(_ saved: RecordingManifest) {
        var expected = saved
        expected.exportEntries = manifest.exportEntries
        guard expected == manifest else {
            NSLog("HQ recorder: export manifest does not match the open recording, so it was not taken")
            return
        }
        manifest = saved
    }

    /// Saves the edited range as a new revision, keeping the current webcam placement. Nothing
    /// changes in memory when the save fails.
    private mutating func change(_ edit: (inout TrimEditor) throws -> Void) throws {
        var next = editor
        try edit(&next)
        if next.range != editor.range {
            try store.appendEdit(trim: next.range, webcam: manifest.webcam, to: &manifest, in: package)
        }
        editor = next
    }
}
