import Foundation

/// Launch context handed to the helper by the HQ pack launcher (`hq-record-process.sh start`).
/// The helper never picks a company itself: the HQ session resolves and binds it.
struct HQLaunchContext: Equatable, Sendable {
    var controlDirectory: URL
    var company: String
    var destination: URL

    /// Returns nil when the app was opened without `--hq-control` (not launched from HQ).
    static func parse(_ arguments: [String]) throws -> HQLaunchContext? {
        var values: [String: String] = [:]
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let key = arguments[index]
            if ["--hq-control", "--company", "--destination"].contains(key) {
                let next = arguments.index(after: index)
                guard next < arguments.endIndex, !arguments[next].hasPrefix("--")
                else { throw HQLaunchError.missingValue(key) }
                values[key] = arguments[next]
                index = arguments.index(after: next)
            } else {
                index = arguments.index(after: index)
            }
        }
        guard let control = values["--hq-control"] else { return nil }
        guard let company = values["--company"] else { throw HQLaunchError.missingValue("--company") }
        guard let destination = values["--destination"] else { throw HQLaunchError.missingValue("--destination") }
        guard company.range(of: "^[a-z0-9][a-z0-9-]*$", options: .regularExpression) != nil
        else { throw HQLaunchError.invalidCompany }
        guard control.hasPrefix("/"), destination.hasPrefix("/") else { throw HQLaunchError.relativePath }
        return HQLaunchContext(controlDirectory: URL(fileURLWithPath: control, isDirectory: true),
                               company: company,
                               destination: URL(fileURLWithPath: destination, isDirectory: true))
    }
}

enum HQLaunchError: Error, Equatable {
    case missingValue(String)
    case invalidCompany
    case relativePath
}

enum SessionState: String, Codable, Sendable {
    /// Helper is open and showing the company destination; nothing is being captured.
    case awaitingStart = "awaiting-start"
    case recording
    case finalizing
    case saved
    case failed
    case closed
    /// The app quit before recording after the user asked for Screen Recording access, which is
    /// macOS "Quit & Reopen". The reopened app keeps the binding and writes its own status, so HQ
    /// keeps waiting instead of treating this as the user closing the app.
    case relaunching
}

struct SessionStatus: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    var schema = schemaVersion
    var state: SessionState
    var company: String
    var destination: String
    var pid: Int32
    var updatedAt: String
    var reason: String?
    /// Vault-relative path of the recording package, once one exists.
    var recording: String?
    /// Sync state of that package: local-only, pending, synced or failed-retry.
    var sync: String?
    /// True while a recording is paused. Absent when not recording.
    var paused: Bool?
    /// Recorded seconds so far, with paused time left out. Absent before a recording starts.
    var durationSeconds: Double?
    /// After a save, a prompt to paste into any HQ session to pick the recording up again.
    /// Kept on later updates such as closed, so an interrupted session can still read it.
    var resumePrompt: String? = nil
    /// After a save, a plain note when a track file is not as long as the recording says.
    var issue: String? = nil
}

/// File-based control channel shared with the HQ session.
/// `status.json` is written atomically by the helper; `stop.request` is created by the launcher.
struct ControlChannel: Sendable {
    let directory: URL
    var statusURL: URL { directory.appendingPathComponent("status.json") }
    var stopRequestURL: URL { directory.appendingPathComponent("stop.request") }

    func write(_ status: SessionStatus) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(status).write(to: statusURL, options: .atomic)
    }

    func read() throws -> SessionStatus {
        try JSONDecoder().decode(SessionStatus.self, from: Data(contentsOf: statusURL))
    }

    var stopRequested: Bool { FileManager.default.fileExists(atPath: stopRequestURL.path) }

    func clearStopRequest() throws {
        guard stopRequested else { return }
        try FileManager.default.removeItem(at: stopRequestURL)
    }
}

enum DestinationCheck {
    /// Returns nil when the destination is an existing directory the helper can write to,
    /// otherwise a short reason suitable for status and display.
    static func problem(with destination: URL) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return "destination-missing" }
        let probe = destination.appendingPathComponent(".hq-recorder-probe-\(UUID().uuidString)")
        do {
            try Data().write(to: probe)
            try FileManager.default.removeItem(at: probe)
            return nil
        } catch {
            return "destination-unwritable"
        }
    }
}

extension SessionStatus {
    static func now() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

/// Remembers the last HQ launch binding so a plain relaunch shortly after (macOS "Quit & Reopen"
/// after granting Screen Recording, or opening the app from the Dock) stays bound to the same
/// company and destination. The restored arguments still go through `HQLaunchContext.parse` and
/// the destination check, so a stale or moved folder is refused the same way as a fresh launch.
struct LaunchBindingStore: @unchecked Sendable {
    let defaults: UserDefaults
    /// How long after the last HQ launch a plain relaunch reuses its binding.
    static let window: TimeInterval = 600
    static let key = "hqLaunchBinding.v1"

    /// The arguments to launch with. An HQ launch is remembered and returned unchanged. A launch
    /// with no `--` options (system-added `-NS...` flags are ignored) reuses a binding saved within
    /// `window`. Any other launch, such as a command-line tool or `--review-package`, is unchanged.
    func resolve(_ arguments: [String], now: Date = Date()) -> [String] {
        if arguments.contains("--hq-control") {
            if let context = try? HQLaunchContext.parse(arguments) { save(context, at: now) }
            return arguments
        }
        guard !arguments.dropFirst().contains(where: { $0.hasPrefix("--") }),
              let saved = defaults.dictionary(forKey: Self.key),
              let control = saved["control"] as? String, let company = saved["company"] as? String,
              let destination = saved["destination"] as? String, let savedAt = saved["savedAt"] as? Double
        else { return arguments }
        let age = now.timeIntervalSince1970 - savedAt
        guard age >= 0, age <= Self.window else { return arguments }
        return [arguments.first ?? "LocalScreenRecorder", "--hq-control", control, "--company", company,
                "--destination", destination]
    }

    func save(_ context: HQLaunchContext, at date: Date) {
        defaults.set(["control": context.controlDirectory.path, "company": context.company,
                      "destination": context.destination.path, "savedAt": date.timeIntervalSince1970],
                     forKey: Self.key)
    }
}
