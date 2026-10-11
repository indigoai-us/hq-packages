import Foundation

struct RecordingProject: Codable, Equatable, Sendable {
    static let currentVersion = 1
    var version = currentVersion
    var id: UUID
    var title: String
    var tracks: [Track]
    var trim: TrimRange?
    var webcam = WebcamPlacement()

    struct Track: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case screen, camera, microphone }
        var kind: Kind
        var relativePath: String
        var startOffsetSeconds: Double
    }
    struct TrimRange: Codable, Equatable, Sendable {
        var start: Double
        var end: Double
    }
    struct WebcamPlacement: Codable, Equatable, Sendable {
        var x = 0.8
        var y = 0.8
        var width = 0.18
        var visible = true
    }

    func validate() throws {
        guard version == Self.currentVersion else { throw ProjectError.unsupportedVersion }
        if let trim {
            guard trim.start.isFinite, trim.end.isFinite, trim.start >= 0, trim.end > trim.start
            else { throw ProjectError.invalidTrim }
        }
        guard webcam.x.isFinite, webcam.y.isFinite, webcam.width.isFinite,
              (0...1).contains(webcam.x), (0...1).contains(webcam.y),
              webcam.width > 0, webcam.width <= 1 else { throw ProjectError.invalidPlacement }
        guard Set(tracks.map(\.kind)).count == tracks.count else { throw ProjectError.duplicateTrack }
        for track in tracks {
            let parts = track.relativePath.split(separator: "/", omittingEmptySubsequences: false)
            guard !track.relativePath.isEmpty, !track.relativePath.hasPrefix("/"),
                  !parts.contains(".."), !parts.contains("."), !parts.contains(""),
                  track.startOffsetSeconds.isFinite, track.startOffsetSeconds >= 0
            else { throw ProjectError.invalidTrack }
        }
    }
}

enum ProjectError: Error { case unsupportedVersion, invalidTrim, invalidPlacement, invalidTrack, duplicateTrack }

struct ProjectStore {
    func save(_ project: RecordingProject, to package: URL) throws {
        try project.validate()
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(project).write(to: package.appendingPathComponent("project.json"), options: .atomic)
    }
    func load(from package: URL) throws -> RecordingProject {
        let project = try JSONDecoder().decode(RecordingProject.self,
            from: Data(contentsOf: package.appendingPathComponent("project.json")))
        try project.validate()
        return project
    }
}
