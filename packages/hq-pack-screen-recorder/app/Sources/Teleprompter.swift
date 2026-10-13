import Foundation

/// The optional script shown in the teleprompter window. It saves with the recording package
/// as `teleprompter.json`, so the editor and SOP workflow can read what was read aloud.
struct TeleprompterScript: Codable, Equatable, Sendable {
    static let relativePath = "teleprompter.json"
    static let currentVersion = 1
    /// Text size in points.
    static let fontSizes: ClosedRange<Double> = 14...96
    /// Scroll speed in points per second. Zero holds the text still.
    static let scrollSpeeds: ClosedRange<Double> = 0...240

    var version = currentVersion
    var text: String
    var fontSize = 32.0
    var scrollSpeed = 40.0

    /// Text size and speed moved into range. Non-finite values fall back to the defaults.
    func clamped() -> TeleprompterScript {
        var script = self
        script.fontSize = Self.clamp(fontSize, to: Self.fontSizes, fallback: 32)
        script.scrollSpeed = Self.clamp(scrollSpeed, to: Self.scrollSpeeds, fallback: 40)
        return script
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
    }

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// Scroll position of the teleprompter text. Playing moves the text up at the script's speed;
/// it stops at the end and never scrolls past it.
struct TeleprompterScroll: Equatable, Sendable {
    /// Points scrolled from the top.
    private(set) var position = 0.0
    private(set) var isPlaying = false

    mutating func play() { isPlaying = true }
    mutating func pause() { isPlaying = false }
    mutating func togglePlay() { isPlaying.toggle() }
    mutating func rewind() { position = 0 }

    /// Advances by `elapsed` seconds. `limit` is how far the text can scroll before its end
    /// reaches the top of the window. Reaching the end stops play.
    mutating func advance(by elapsed: Double, speed: Double, limit: Double) {
        let end = max(0, limit.isFinite ? limit : 0)
        position = min(position, end)
        guard isPlaying, elapsed.isFinite, elapsed > 0, speed.isFinite, speed > 0 else { return }
        position = min(end, position + elapsed * speed)
        if position >= end { isPlaying = false }
    }
}
