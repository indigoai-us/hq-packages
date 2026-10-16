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

/// The ordered ranges of the recording an edit keeps. An edit without middle cuts keeps one range
/// (its trim); each middle cut splits a kept range in two. Playback, frames, export and
/// transcription all play the kept ranges back to back, on every track alike.
enum KeptRanges {
    typealias Range = RecordingProject.TrimRange

    enum CutError: Error, Equatable {
        /// A cut is not a finite time range with its start before its end.
        case invalidCut
        /// Two cuts share some time.
        case overlapping
        /// A cut is not entirely inside one kept range: it starts or ends outside the recording,
        /// past the in or out point, or inside time an earlier cut already removed.
        case outsideKept
        /// The cuts remove everything the edit kept.
        case nothingLeft
        /// A cut leaves a piece shorter than `TrimEditor.minimumLength`.
        case pieceTooShort
    }

    /// The ranges an edit keeps, checked against a recording of `duration` seconds. Nil `kept`
    /// means the single `trim` range, which is how edits saved before middle cuts load.
    static func resolve(trim: Range?, kept: [Range]?, duration: Double) throws -> [Range] {
        guard let kept else { return [try TrimEditor.check(trim, duration: duration)] }
        guard duration.isFinite, duration >= TrimEditor.minimumLength else { throw TrimEditor.TrimError.emptyRecording }
        guard !kept.isEmpty else { throw TrimEditor.TrimError.tooShort }
        var result: [Range] = []
        for (index, range) in kept.enumerated() {
            guard range.start.isFinite, range.end.isFinite, range.start >= 0,
                  index == 0 || range.start > kept[index - 1].end else { throw TrimEditor.TrimError.invalidRange }
            guard range.end <= duration + TrimEditor.tolerance else { throw TrimEditor.TrimError.outsideRecording }
            let clamped = Range(start: range.start, end: min(range.end, duration))
            guard clamped.end - clamped.start >= TrimEditor.minimumLength else { throw TrimEditor.TrimError.tooShort }
            result.append(clamped)
        }
        return result
    }

    /// The kept ranges with new in and out points. Moving a point outward lengthens the first or
    /// last range; moving it inward drops whatever falls outside. The middle cuts stay where they are.
    static func bounded(_ ranges: [Range], start: Double, end: Double) throws -> [Range] {
        guard !ranges.isEmpty else { throw TrimEditor.TrimError.tooShort }
        var result = ranges
        result[0].start = min(result[0].start, start)
        result[result.count - 1].end = max(result[result.count - 1].end, end)
        result = result.compactMap { range in
            let clipped = Range(start: max(range.start, start), end: min(range.end, end))
            return clipped.end > clipped.start ? clipped : nil
        }
        guard !result.isEmpty else { throw TrimEditor.TrimError.tooShort }
        guard result.allSatisfy({ $0.end - $0.start >= TrimEditor.minimumLength }) else { throw CutError.pieceTooShort }
        return result
    }

    /// The kept ranges with each cut removed. Every cut must lie inside one kept range and no two
    /// cuts may share time. A cut that covers a whole kept range removes it.
    static func cutting(_ cuts: [Range], from ranges: [Range]) throws -> [Range] {
        let sorted = cuts.sorted { $0.start < $1.start }
        for (index, cut) in sorted.enumerated() {
            guard cut.start.isFinite, cut.end.isFinite, cut.start < cut.end else { throw CutError.invalidCut }
            if index > 0, cut.start < sorted[index - 1].end { throw CutError.overlapping }
        }
        for cut in sorted where !ranges.contains(where: { cut.start >= $0.start && cut.end <= $0.end }) {
            throw CutError.outsideKept
        }
        var result: [Range] = []
        for range in ranges {
            var start = range.start
            for cut in sorted where cut.start >= range.start && cut.end <= range.end {
                if cut.start > start { result.append(Range(start: start, end: cut.start)) }
                start = cut.end
            }
            if range.end > start { result.append(Range(start: start, end: range.end)) }
        }
        guard !result.isEmpty else { throw CutError.nothingLeft }
        guard result.allSatisfy({ $0.end - $0.start >= TrimEditor.minimumLength }) else { throw CutError.pieceTooShort }
        return result
    }

    /// How kept ranges are saved: one range is a trim, nil when it is the whole recording, and
    /// several are the outer bounds as the trim plus the ranges themselves.
    static func normalize(_ ranges: [Range], duration: Double)
        -> (trim: Range?, kept: [Range]?) {
        guard let first = ranges.first, let last = ranges.last else { return (nil, nil) }
        if ranges.count == 1 { return (first.start <= 0 && first.end >= duration ? nil : first, nil) }
        return (Range(start: first.start, end: last.end), ranges)
    }

    /// Seconds of recording the ranges keep.
    static func total(_ ranges: [Range]) -> Double {
        ranges.reduce(0) { $0 + ($1.end - $1.start) }
    }

    /// Where a moment of the recording lands in the edited video, or nil when it is cut out.
    static func editedTime(recording seconds: Double, in ranges: [Range]) -> Double? {
        var offset = 0.0
        for range in ranges {
            if seconds >= range.start && seconds <= range.end { return offset + seconds - range.start }
            offset += range.end - range.start
        }
        return nil
    }

    /// The moment of the recording shown at `seconds` into the edited video, or nil past its end.
    /// A moment exactly on a join maps to the start of the later range, which is what plays there;
    /// pass `ending: true` for the end of a span, which then maps to the end of the earlier range.
    static func recordingTime(edited seconds: Double, in ranges: [Range], ending: Bool = false) -> Double? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        var offset = 0.0
        for (index, range) in ranges.enumerated() {
            let length = range.end - range.start
            let last = index == ranges.count - 1
            if seconds < offset + length || ((ending || last) && seconds <= offset + length) {
                return range.start + seconds - offset
            }
            offset += length
        }
        return nil
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
        let timeline = try store.readTimeline(of: manifest, in: package)
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
        try store.appendEdit(trim: manifest.trim, kept: manifest.kept, webcam: webcam, to: &manifest, in: package)
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

    /// Saves the edited range as a new revision, keeping the current webcam placement and any
    /// middle cuts inside the new range. Nothing changes in memory when the save fails.
    private mutating func change(_ edit: (inout TrimEditor) throws -> Void) throws {
        var next = editor
        try edit(&next)
        if next.range != editor.range {
            var trim = next.range
            var kept: [RecordingProject.TrimRange]?
            if let current = manifest.kept {
                let ranges = try KeptRanges.bounded(current, start: next.start, end: next.end)
                (trim, kept) = KeptRanges.normalize(ranges, duration: next.duration)
            }
            try store.appendEdit(trim: trim, kept: kept, webcam: manifest.webcam, to: &manifest, in: package)
        }
        editor = next
    }
}
