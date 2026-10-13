import Foundation

/// The shared recording timeline. Every track maps host-clock times through one clock, so
/// pausing stops all tracks together and paused time is left out of every offset.
///
/// Offsets are seconds of recorded output: host time minus the origin minus every pause that
/// ended before that time. A time inside a pause maps to the offset where the pause began.
/// Each resume starts a new epoch; tracks open a new segment when the epoch changes, so no
/// segment file spans a pause.
final class RecordingClock: @unchecked Sendable {
    struct Pause: Equatable, Sendable {
        var start: Double
        var end: Double?
    }

    /// Host time the recording started.
    let origin: Double
    private let lock = NSLock()
    private var pauses: [Pause] = []

    init(origin: Double) { self.origin = origin }

    /// Host-clock pauses so far. The last one has no end while paused.
    var hostPauses: [Pause] { lock.withLock { pauses } }

    var isPaused: Bool { lock.withLock { pauses.last.map { $0.end == nil } ?? false } }

    /// Starts a pause at `host`. Returns false when already paused, so repeats do nothing.
    @discardableResult
    func pause(at host: Double) -> Bool {
        lock.withLock {
            guard pauses.last.map({ $0.end != nil }) ?? true else { return false }
            let start = max(host, origin, pauses.last?.end ?? origin)
            pauses.append(Pause(start: start, end: nil))
            return true
        }
    }

    /// Ends the open pause at `host`. Returns false when not paused, so repeats do nothing.
    @discardableResult
    func resume(at host: Double) -> Bool {
        lock.withLock {
            guard let last = pauses.indices.last, pauses[last].end == nil else { return false }
            pauses[last].end = max(host, pauses[last].start)
            return true
        }
    }

    /// True when `host` falls inside a pause. Media stamped then is not recorded.
    func isPaused(at host: Double) -> Bool {
        lock.withLock {
            pauses.contains { host >= $0.start && $0.end.map { host < $0 } ?? true }
        }
    }

    /// Seconds of output at `host`, with paused time left out.
    func offset(_ host: Double) -> Double {
        lock.withLock {
            var paused = 0.0
            for pause in pauses where host > pause.start {
                let end = pause.end.map { min($0, host) } ?? host
                paused += end - pause.start
            }
            return max(0, host - origin - paused)
        }
    }

    /// Number of pauses that ended at or before `host`. Changes exactly when media resumes.
    func epoch(at host: Double) -> Int {
        lock.withLock { pauses.filter { $0.end.map { $0 <= host } ?? false }.count }
    }

    /// Paused time so far at `host`, for the duration shown while recording.
    func pausedSeconds(at host: Double) -> Double {
        max(0, host - origin) - offset(host)
    }

    /// Pauses as offsets on the output timeline, for the manifest. A pause sits at one point of
    /// the output, so each range records where it falls and how long it lasted on the host clock.
    func pausedRanges() -> [RecordingManifest.PausedRange] {
        hostPauses.map { pause in
            RecordingManifest.PausedRange(atOffsetSeconds: offset(pause.start),
                                          startHostOffsetSeconds: max(0, pause.start - origin),
                                          durationSeconds: pause.end.map { max(0, $0 - pause.start) })
        }
    }
}
