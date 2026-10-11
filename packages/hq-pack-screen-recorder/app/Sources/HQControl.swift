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
