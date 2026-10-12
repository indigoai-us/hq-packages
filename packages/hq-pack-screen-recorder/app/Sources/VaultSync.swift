// Company-vault sync, access checks, retrieval and skill registration for recording packages.
// Everything here goes through the HQ CLI (`hq sync`, `hq files`, `hq access`, `hq skill`), so the
// company vault's ACLs and sync rules apply. There is no separate upload or sharing service, and
// sync only stores files: nothing here sends recordings to a model.
import CryptoKit
import Foundation

// MARK: - HQ CLI

struct HQCommandResult: Equatable, Sendable {
    var exit: Int32
    var stdout: String
    var stderr: String
}

/// Runs one `hq` command. Returns nil when the HQ CLI is not installed.
protocol HQCommandRunning: Sendable {
    func run(_ arguments: [String]) async -> HQCommandResult?
}

/// Runs the installed `hq` binary directly, without a shell.
struct HQCLIRunner: HQCommandRunning {
    var candidates = ["/opt/homebrew/bin/hq", "/usr/local/bin/hq"]

    func run(_ arguments: [String]) async -> HQCommandResult? {
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return nil }
        return await Task.detached { Self.launch(binary, arguments) }.value
    }

    private static func launch(_ binary: String, _ arguments: [String]) -> HQCommandResult {
        // Output goes to temp files so a large JSON Lines stream cannot fill a pipe and stall the child.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hq-run-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let out = folder.appendingPathComponent("stdout"), err = folder.appendingPathComponent("stderr")
            FileManager.default.createFile(atPath: out.path, contents: nil)
            FileManager.default.createFile(atPath: err.path, contents: nil)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = try FileHandle(forWritingTo: out)
            process.standardError = try FileHandle(forWritingTo: err)
            try process.run()
            process.waitUntilExit()
            return HQCommandResult(exit: process.terminationStatus,
                                   stdout: (try? String(contentsOf: out, encoding: .utf8)) ?? "",
                                   stderr: (try? String(contentsOf: err, encoding: .utf8)) ?? "")
        } catch {
            return HQCommandResult(exit: 127, stdout: "", stderr: "hq-launch-failed: \(error)")
        }
    }
}

// MARK: - Failures

/// Why a vault operation stopped. Local files are never removed, so every case can be retried.
enum VaultSyncFailure: Error, Equatable, Sendable {
    case cliUnavailable
    case authExpired
    case networkLost
    case accessDenied(String)
    case partial(String)
    case destinationMismatch(String)
    case stillRecording
    case localCopyExists

    /// Short reason stored in `manifest.sync.detail`.
    var detail: String {
        switch self {
        case .cliUnavailable: "hq-cli-unavailable"
        case .authExpired: "auth-expired"
        case .networkLost: "offline"
        case .accessDenied(let why): "access-denied: \(why)"
        case .partial(let why): "partial: \(why)"
        case .destinationMismatch(let why): "destination-mismatch: \(why)"
        case .stillRecording: "still-recording"
        case .localCopyExists: "local-copy-exists"
        }
    }

    /// What the person can do next. The local originals stay on this Mac in every case.
    var retryAdvice: String {
        switch self {
        case .cliUnavailable: "Install the HQ CLI, then retry."
        case .authExpired: "Run hq login, then retry."
        case .networkLost: "Reconnect to the network, then retry."
        case .accessDenied: "Ask a company admin for vault access, then retry."
        case .partial: "Retry to upload the rest."
        case .destinationMismatch: "Check the company and recordings folder, then retry."
        case .stillRecording: "Stop the recording, then retry."
        case .localCopyExists: "The package is already on this Mac. Open it there, or move it out of the recordings folder, then retry."
        }
    }

    /// Reads a failed `hq` command's output. Order matters: an expired session often surfaces as
    /// a 403 from the bucket, so login problems are checked before access problems.
    static func classify(_ result: HQCommandResult) -> VaultSyncFailure {
        let text = (result.stdout + "\n" + result.stderr).lowercased()
        let auth = ["not logged in", "hq login", "session expired", "token expired", "expiredtoken",
                    "refresh token", "401", "unauthorized", "unauthenticated"]
        let network = ["enotfound", "econnrefused", "etimedout", "econnreset", "eai_again", "fetch failed",
                       "network", "offline", "socket hang up"]
        let denied = ["403", "accessdenied", "access denied", "forbidden", "no-access", "not a member"]
        if auth.contains(where: text.contains) { return .authExpired }
        if network.contains(where: text.contains) { return .networkLost }
        if denied.contains(where: text.contains) { return .accessDenied("vault refused the request") }
        if text.contains("company slug"), text.contains("not found") { return .accessDenied("company not in this account") }
        return .partial("hq exited \(result.exit)")
    }
}

// MARK: - Sync

/// One file of a package, grouped by the layer it belongs to.
struct VaultSyncFile: Codable, Equatable, Sendable {
    enum Layer: String, Codable, Sendable, CaseIterable {
        case package
        case recordingLayers = "recording-layers"
        case screenshots
        case edits
        case transcripts
        case drafts
        case documents
        case videoExports = "video-exports"
    }
    var path: String
    var layer: Layer
    var bytes: Int64
    var sha256: String

    static func layer(of path: String) -> Layer {
        let parts = path.split(separator: "/").map(String.init)
        switch parts.first {
        case "media": return .recordingLayers
        case "screenshots": return .screenshots
        case "edits": return .edits
        case "transcripts": return .transcripts
        case "drafts": return .drafts
        case "exports":
            let ext = (path as NSString).pathExtension.lowercased()
            return ["mov", "mp4", "m4v"].contains(ext) ? .videoExports : .documents
        default: return .package
        }
    }
}

struct VaultSyncReport: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable { case synced, failedRetry = "failed-retry" }
    var version = 1
    var checkedAt: String
    var company: String
    /// Vault path the package was pushed to, `companies/<slug>/recordings/<name>.hqrec`.
    var destination: String
    var outcome: Outcome
    var failure: String?
    var retry: String?
    var files: [VaultSyncFile]
    var filesVerified: Int
    var bytesVerified: Int64
    /// The local originals are kept whatever happens.
    var localOriginalsKept = true
    /// Sync stores and shares files. It does not run any model on them.
    var processing = "storage-only"

    var layerCounts: [String: Int] {
        Dictionary(grouping: files, by: { $0.layer.rawValue }).mapValues(\.count)
    }

    var statusLine: String {
        switch outcome {
        case .synced:
            "Synced to the company vault at \(destination). \(filesVerified) files, \(bytesVerified) bytes checked against this Mac. Storage only."
        case .failedRetry:
            "Not fully synced (\(failure ?? "unknown")). The originals are still on this Mac. \(retry ?? "")"
        }
    }
}

enum VaultSyncWorkflow {
    /// Pushes a saved package through `hq sync push`, then downloads every file back with
    /// `hq files cat` and compares it with the bytes hashed before the push. Records the result in
    /// `manifest.sync`. Never deletes or changes a local media, draft or export file.
    static func sync(package: URL, store: RecordingPackageStore,
                     runner: any HQCommandRunning = HQCLIRunner()) async throws -> VaultSyncReport {
        let package = try store.root.contain(package)
        let manifest = try store.readManifest(in: package)
        guard manifest.state != .recording, manifest.state != .finalizing else { throw VaultSyncFailure.stillRecording }
        let destination = try destination(of: package, manifest: manifest, store: store)
        let files = try snapshot(package: package)
        let hqRoot = hqRoot(of: store)

        var report = VaultSyncReport(checkedAt: SessionStatus.now(), company: store.root.company,
                                     destination: destination, outcome: .synced, files: files,
                                     filesVerified: 0, bytesVerified: 0)
        do {
            try await push(destination: destination, company: store.root.company, hqRoot: hqRoot, runner: runner)
            try await confirmDestination(destination, company: store.root.company, hqRoot: hqRoot, runner: runner)
            for file in files {
                try await verify(file, destination: destination, company: store.root.company, hqRoot: hqRoot,
                                 runner: runner)
                report.filesVerified += 1
                report.bytesVerified += file.bytes
            }
        } catch let failure as VaultSyncFailure {
            report.outcome = .failedRetry
            report.failure = failure.detail
            report.retry = failure.retryAdvice
        }
        report.checkedAt = SessionStatus.now()

        // Re-read so a review autosave that landed during the push is kept.
        var latest = try store.readManifest(in: package)
        latest.sync = report.outcome == .synced
            ? .init(state: .synced, checkedAt: report.checkedAt,
                    detail: "verified \(report.filesVerified) files, \(report.bytesVerified) bytes")
            : .init(state: .failedRetry, checkedAt: report.checkedAt, detail: report.failure)
        try store.writeManifest(latest, in: package)
        return report
    }

    /// `companies/<slug>/recordings/<name>.hqrec`, after checking the manifest names the same place.
    static func destination(of package: URL, manifest: RecordingManifest, store: RecordingPackageStore) throws -> String {
        let expected = "\(store.root.vaultPath)/\(package.lastPathComponent)"
        guard manifest.company == store.root.company else {
            throw VaultSyncFailure.destinationMismatch("manifest company \(manifest.company)")
        }
        guard manifest.vaultPath == expected, package.pathExtension == RecordingPackageStore.packageExtension else {
            throw VaultSyncFailure.destinationMismatch("manifest vault path \(manifest.vaultPath)")
        }
        return expected
    }

    /// Every regular file in the package with its size and SHA-256. Links are refused so a push
    /// can never carry a file from outside the package. Hidden files (atomic-write temps, Finder
    /// metadata) are left out.
    static func snapshot(package: URL) throws -> [VaultSyncFile] {
        let base = package.resolvingSymlinksInPath().standardizedFileURL
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles]) else {
            throw PackageError.notAPackage
        }
        var files: [VaultSyncFile] = []
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true { throw PackageError.invalidPath }
            guard values.isRegularFile == true else { continue }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(base.path + "/") else { throw PackageError.invalidPath }
            let relative = String(full.dropFirst(base.path.count + 1))
            guard RecordingManifest.isSafeRelative(relative) else { throw PackageError.invalidPath }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            files.append(.init(path: relative, layer: VaultSyncFile.layer(of: relative), bytes: Int64(data.count),
                               sha256: sha256(data)))
        }
        return files.sorted { $0.path < $1.path }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func hqRoot(of store: RecordingPackageStore) -> URL {
        store.root.url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func push(destination: String, company: String, hqRoot: URL,
                             runner: any HQCommandRunning) async throws {
        // `keep` never replaces a teammate's newer copy; a conflict is reported for retry instead.
        guard let result = await runner.run(["sync", "push", "--company", company, "--hq-root", hqRoot.path,
                                             "--on-conflict", "keep", "--json",
                                             "--message", "recording package \(destination)", destination])
        else { throw VaultSyncFailure.cliUnavailable }
        guard let complete = completeEvent(result) else { throw VaultSyncFailure.classify(result) }
        if complete["aborted"] as? Bool == true { throw VaultSyncFailure.partial("push aborted") }
        if let excluded = complete["filesExcludedByScope"] as? Int, excluded > 0 {
            throw VaultSyncFailure.accessDenied("\(excluded) files outside your vault scope")
        }
        if let conflicts = complete["conflictPaths"] as? [Any], !conflicts.isEmpty {
            throw VaultSyncFailure.partial("\(conflicts.count) conflicts; run hq sync pull first")
        }
        if let stale = complete["filesRefusedStale"] as? Int, stale > 0 {
            throw VaultSyncFailure.partial("\(stale) files refused as stale")
        }
        if let limit = complete["planLimitRefused"], !(limit is NSNull), (limit as? Bool) != false {
            throw VaultSyncFailure.partial("plan storage limit")
        }
        guard result.exit == 0 else { throw VaultSyncFailure.classify(result) }
    }

    /// The last `{"type":"complete"}` JSON line `hq sync push --json` writes to stderr.
    static func completeEvent(_ result: HQCommandResult) -> [String: Any]? {
        for line in (result.stderr + "\n" + result.stdout).split(separator: "\n").reversed() {
            guard let data = line.trimmingCharacters(in: .whitespaces).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "complete" else { continue }
            return object
        }
        return nil
    }

    /// Asks the vault where the pushed manifest lives and checks it is this company's path.
    private static func confirmDestination(_ destination: String, company: String, hqRoot: URL,
                                           runner: any HQCommandRunning) async throws {
        let manifestPath = "\(destination)/\(RecordingPackageStore.manifestName)"
        guard let result = await runner.run(["access", manifestPath, "--company", company, "--hq-root", hqRoot.path,
                                             "--json", "--no-fix"])
        else { throw VaultSyncFailure.cliUnavailable }
        let answer = AccessAnswer(result)
        switch result.exit {
        case 0: break
        case 2: throw VaultSyncFailure.partial("manifest not found in the vault after push")
        case 3: throw VaultSyncFailure.accessDenied("no read access to \(manifestPath)")
        default: throw VaultSyncFailure.classify(result)
        }
        guard answer?.company == company, answer?.path == manifestPath else {
            throw VaultSyncFailure.destinationMismatch("vault resolved \(answer?.company ?? "?")/\(answer?.path ?? "?")")
        }
    }

    /// Downloads one pushed file outside the HQ tree and compares its bytes, then deletes the copy.
    private static func verify(_ file: VaultSyncFile, destination: String, company: String, hqRoot: URL,
                               runner: any HQCommandRunning) async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("hq-verify-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let out = scratch.appendingPathComponent("object")
        guard let result = await runner.run(["files", "cat", "\(destination)/\(file.path)", "--company", company,
                                             "--hq-root", hqRoot.path, "--out", out.path])
        else { throw VaultSyncFailure.cliUnavailable }
        guard result.exit == 0 else {
            let failure = VaultSyncFailure.classify(result)
            if case .partial = failure { throw VaultSyncFailure.partial("\(file.path) missing in the vault") }
            throw failure
        }
        guard let data = try? Data(contentsOf: out), Int64(data.count) == file.bytes, sha256(data) == file.sha256
        else { throw VaultSyncFailure.partial("\(file.path) differs from the local original") }
    }
}

// MARK: - Access and retrieval

/// The JSON object `hq access --json` prints. For your own access it is pretty-printed over
/// several lines with an `outcome`; with `--as` it is one line with a `permission` instead.
struct AccessAnswer: Decodable, Equatable, Sendable {
    var outcome: String?
    var permission: String?
    var path: String
    var company: String?
    var exists: Bool?

    init?(_ result: HQCommandResult) {
        for text in [result.stdout, result.stderr] {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let answer = try? JSONDecoder().decode(AccessAnswer.self, from: Data(trimmed.utf8)) {
                self = answer
                return
            }
            // Fall back to the last single-line object when other output surrounds it.
            for line in trimmed.split(separator: "\n").reversed() {
                if let answer = try? JSONDecoder().decode(AccessAnswer.self, from: Data(line.utf8)) {
                    self = answer
                    return
                }
            }
        }
        return nil
    }
}

enum VaultAccessDecision: Equatable, Sendable {
    case allowed(String)
    case denied
    case missing
    case ambiguous
    case failed(VaultSyncFailure)
}

struct RetrievalReport: Codable, Equatable, Sendable {
    var package: String
    var resolved: [String]
    var missing: [String]
    var complete: Bool { missing.isEmpty }
}

enum VaultAccess {
    /// Checks whether `person` (email, prs_ or agt_ uid) may read the package, using the vault ACL.
    static func check(package: String, company: String, person: String, hqRoot: URL,
                      runner: any HQCommandRunning = HQCLIRunner()) async -> VaultAccessDecision {
        guard isPackagePath(package, company: company) else {
            return .failed(.destinationMismatch("not a \(company) recording package: \(package)"))
        }
        let path = "\(package)/\(RecordingPackageStore.manifestName)"
        guard let result = await runner.run(["access", path, "--company", company, "--as", person,
                                             "--hq-root", hqRoot.path, "--json", "--no-fix"])
        else { return .failed(.cliUnavailable) }
        switch result.exit {
        case 0:
            let answer = AccessAnswer(result)
            return .allowed(answer?.permission ?? answer?.outcome ?? "readable")
        case 2: return .missing
        case 3: return .denied
        case 4: return .ambiguous
        default: return .failed(VaultSyncFailure.classify(result))
        }
    }

    /// `companies/<company>/recordings/<name>.hqrec`, nothing more.
    static func isPackagePath(_ path: String, company: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return parts.count == 4 && Array(parts.prefix(3)) == ["companies", company, "recordings"]
            && parts[3].hasSuffix(".\(RecordingPackageStore.packageExtension)")
            && RecordingManifest.isSafeRelative(path)
    }

    /// Fetches a package through normal vault sync (`hq files get`, which writes in place under
    /// `companies/<company>/` and pins it), then checks that every file the manifest, the SOP
    /// exports and the review revisions point at is present.
    static func retrieve(package: String, store: RecordingPackageStore,
                         runner: any HQCommandRunning = HQCLIRunner()) async throws -> RetrievalReport {
        guard isPackagePath(package, company: store.root.company) else {
            throw VaultSyncFailure.destinationMismatch("not a \(store.root.company) recording package: \(package)")
        }
        // `hq files get` writes over files in place, so a local copy (the recording Mac's originals,
        // or edits made since an earlier retrieval) would be replaced by the vault's bytes.
        let local = store.root.url.appendingPathComponent((package as NSString).lastPathComponent, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: local.path) else { throw VaultSyncFailure.localCopyExists }
        guard let result = await runner.run(["files", "get", package, "--company", store.root.company,
                                             "--hq-root", VaultSyncWorkflow.hqRoot(of: store).path])
        else { throw VaultSyncFailure.cliUnavailable }
        guard result.exit == 0 else { throw VaultSyncFailure.classify(result) }
        return try resolveReferences(package: local, store: store)
    }

    /// Lists every reference in a local package and which ones are missing on disk.
    static func resolveReferences(package: URL, store: RecordingPackageStore) throws -> RetrievalReport {
        let package = try store.root.contain(package)
        let manifest = try store.readManifest(in: package)
        var references = Set(manifest.allReferences)
        for folder in Set((manifest.exports ?? []).compactMap(exportFolder)) {
            let recordPath = "\(folder)/export.json"
            references.insert(recordPath)
            guard let data = try? Data(contentsOf: store.url(for: recordPath, in: package)),
                  let record = try? JSONDecoder().decode(SOPExportRecord.self, from: data) else { continue }
            references.insert("\(folder)/\(record.sop)")
            if let skill = record.skill { references.insert("\(folder)/\(skill)") }
            for step in record.steps {
                if let image = step.image { references.insert("\(folder)/\(image)") }
                if let source = step.sourceImage { references.insert(source) }
            }
            if let sop = try? String(contentsOf: store.url(for: "\(folder)/\(record.sop)", in: package), encoding: .utf8) {
                for link in imageLinks(in: sop) { references.insert("\(folder)/\(link)") }
            }
        }
        var resolved: [String] = [], missing: [String] = []
        for path in references.sorted() {
            let exists = RecordingManifest.isSafeRelative(path)
                && (try? store.url(for: path, in: package)).map { FileManager.default.fileExists(atPath: $0.path) } == true
            if exists { resolved.append(path) } else { missing.append(path) }
        }
        return RetrievalReport(package: manifest.vaultPath, resolved: resolved, missing: missing)
    }

    /// `exports/v001` from `exports/v001/SOP.md`.
    static func exportFolder(_ path: String) -> String? {
        let parts = path.split(separator: "/")
        guard parts.count > 2, parts[0] == "exports" else { return nil }
        return "exports/\(parts[1])"
    }

    /// Relative targets of Markdown image links, `![...](target)`.
    static func imageLinks(in markdown: String) -> [String] {
        guard let pattern = try? NSRegularExpression(pattern: #"!\[[^\]]*\]\(([^)\s]+)\)"#) else { return [] }
        let range = NSRange(markdown.startIndex..., in: markdown)
        return pattern.matches(in: markdown, range: range).compactMap { match in
            Range(match.range(at: 1), in: markdown).map { String(markdown[$0]) }
        }.filter { !$0.contains("://") }
    }
}

// MARK: - Skill registration

enum SkillRegistrationError: Error, Equatable, Sendable {
    case invalidSlug
    case noSkillDraft
    case exportNotCurrent
    case reviewerRequired
    case reviewMismatch
    case skillExists
    case stampInvalid(String)
    case failed(VaultSyncFailure)
}

struct SkillRegistrationRecord: Codable, Equatable, Sendable {
    var version = 1
    var registeredAt: String
    var skill: String
    var skillUID: String
    var canonicalPath: String
    var reviewer: String
    var reviewedSourceSHA256: String
    var stampedSHA256: String
    var export: String
    var reviewRevision: String
}

/// Turns an approved SOP export into a company skill through `hq skill register` and
/// `hq skill promote`, after a person has read the exact source and confirmed its hash.
/// Saving or exporting never gets here on its own: this runs only when asked, with a reviewer.
enum SkillRegistrar {
    static let folderName = "skill-register"

    static func isValidSlug(_ slug: String) -> Bool {
        slug.range(of: "^[a-z0-9][a-z0-9-]{0,63}$", options: .regularExpression) != nil
    }

    /// Writes `<export>/skill-register/SKILL.md`, the source the reviewer reads, and returns its
    /// SHA-256. Write-once: a different existing source is refused. Model invocation stays off.
    static func prepare(package: URL, export folder: String, skill: String,
                        store: RecordingPackageStore) throws -> (path: String, sha256: String) {
        guard isValidSlug(skill) else { throw SkillRegistrationError.invalidSlug }
        let (record, _) = try currentExport(package: package, folder: folder, store: store)
        guard let draftName = record.skill else { throw SkillRegistrationError.noSkillDraft }
        let draft = try String(contentsOf: store.url(for: "\(folder)/\(draftName)", in: package), encoding: .utf8)
        let source = Data(registrationSource(draft: draft, skill: skill, record: record, folder: folder).utf8)
        let path = "\(folder)/\(folderName)/SKILL.md"
        let target = try store.url(for: path, in: package)
        if let existing = try? Data(contentsOf: target) {
            guard existing == source else { throw PackageError.revisionExists }
        } else {
            try store.ensureDirectory("\(folder)/\(folderName)", in: package)
            try store.writeData(source, to: path, in: package)
        }
        return (path, VaultSyncWorkflow.sha256(source))
    }

    /// Registers the prepared source. `reviewedSHA256` must match the bytes on disk, so an edit
    /// after review needs a fresh review. Refuses when the canonical skill already exists, so an
    /// existing skill_uid or exact ACL is never replaced.
    static func register(package: URL, export folder: String, skill: String, reviewer: String,
                         reviewedSHA256: String, store: RecordingPackageStore,
                         runner: any HQCommandRunning = HQCLIRunner()) async throws -> SkillRegistrationRecord {
        guard isValidSlug(skill) else { throw SkillRegistrationError.invalidSlug }
        let reviewer = reviewer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reviewer.isEmpty else { throw SkillRegistrationError.reviewerRequired }
        let package = try store.root.contain(package)
        let (record, _) = try currentExport(package: package, folder: folder, store: store)
        let sourcePath = "\(folder)/\(folderName)/SKILL.md"
        let sourceURL = try store.url(for: sourcePath, in: package)
        guard let source = try? Data(contentsOf: sourceURL), VaultSyncWorkflow.sha256(source) == reviewedSHA256.lowercased()
        else { throw SkillRegistrationError.reviewMismatch }

        let company = store.root.company
        let hqRoot = VaultSyncWorkflow.hqRoot(of: store)
        let canonical = "companies/\(company)/skills/\(skill)/SKILL.md"
        guard !FileManager.default.fileExists(atPath: hqRoot.appendingPathComponent("companies/\(company)/skills/\(skill)").path)
        else { throw SkillRegistrationError.skillExists }

        let stampedPath = "\(folder)/\(folderName)/stamped/SKILL.md"
        let stampedURL = try store.url(for: stampedPath, in: package)
        if !FileManager.default.fileExists(atPath: stampedURL.path) {
            try store.ensureDirectory("\(folder)/\(folderName)/stamped", in: package)
            guard let result = await runner.run(["skill", "--company", company, "--hq-root", hqRoot.path, "register", skill,
                                                 "--source", sourceURL.path, "--stamped-output", stampedURL.path])
            else { throw SkillRegistrationError.failed(.cliUnavailable) }
            guard result.exit == 0 else { throw SkillRegistrationError.failed(VaultSyncFailure.classify(result)) }
        }
        guard let stamped = try? Data(contentsOf: stampedURL) else { throw SkillRegistrationError.stampInvalid("no stamped file") }
        let uid = try checkStamp(stamped, source: source)
        let stampedSHA = VaultSyncWorkflow.sha256(stamped)

        guard let promoted = await runner.run(["skill", "--company", company, "--hq-root", hqRoot.path, "promote", skill,
                                               "--from", stampedURL.path, "--expected-sha256", stampedSHA])
        else { throw SkillRegistrationError.failed(.cliUnavailable) }
        guard promoted.exit == 0 else { throw SkillRegistrationError.failed(VaultSyncFailure.classify(promoted)) }
        guard let written = try? Data(contentsOf: hqRoot.appendingPathComponent(canonical)), written == stamped
        else { throw SkillRegistrationError.stampInvalid("canonical file differs from stamped bytes") }

        let registration = SkillRegistrationRecord(registeredAt: SessionStatus.now(), skill: skill, skillUID: uid,
                                                   canonicalPath: canonical, reviewer: reviewer,
                                                   reviewedSourceSHA256: reviewedSHA256.lowercased(),
                                                   stampedSHA256: stampedSHA, export: folder,
                                                   reviewRevision: record.reviewRevision)
        let registrationPath = "\(folder)/\(folderName)/registration.json"
        try store.writeJSON(registration, to: registrationPath, in: package)
        var manifest = try store.readManifest(in: package)
        let added = [sourcePath, stampedPath, registrationPath].filter { !(manifest.exports ?? []).contains($0) }
        manifest.exports = (manifest.exports ?? []) + added
        try store.writeManifest(manifest, in: package)
        return registration
    }

    /// The export record, if it was made from the newest review revision and that revision is
    /// still approved with a matching content hash.
    static func currentExport(package: URL, folder: String,
                              store: RecordingPackageStore) throws -> (SOPExportRecord, SOPReviewDocument) {
        guard VaultAccess.exportFolder("\(folder)/export.json") == folder else { throw PackageError.invalidPath }
        let manifest = try store.readManifest(in: package)
        guard manifest.state == .saved || manifest.state == .interrupted else { throw PackageError.stillRecording }
        let record = try JSONDecoder().decode(SOPExportRecord.self,
                                              from: Data(contentsOf: store.url(for: "\(folder)/export.json", in: package)))
        guard let latest = try SOPReviewWorkflow.latestReview(manifest: manifest, package: package, store: store),
              latest.2 == .approved, latest.0.isApproved, latest.1 == record.reviewRevision
        else { throw SkillRegistrationError.exportNotCurrent }
        return (record, latest.0)
    }

    /// Server-stamped bytes must keep the reviewed body and every reviewed frontmatter line, and
    /// carry exactly one reserved `skill_uid: skl_...`. Returns that uid.
    static func checkStamp(_ stamped: Data, source: Data) throws -> String {
        guard let stampedText = String(data: stamped, encoding: .utf8),
              let sourceText = String(data: source, encoding: .utf8) else { throw SkillRegistrationError.stampInvalid("not UTF-8") }
        let (stampedFront, stampedBody) = split(stampedText), (sourceFront, sourceBody) = split(sourceText)
        guard stampedBody == sourceBody else { throw SkillRegistrationError.stampInvalid("body changed") }
        let uids = stampedFront.filter { $0.hasPrefix("skill_uid:") }
        guard uids.count == 1, let uid = uids.first.map({ $0.dropFirst("skill_uid:".count).trimmingCharacters(in: .whitespaces) }),
              uid.range(of: "^skl_[A-Za-z0-9_-]+$", options: .regularExpression) != nil
        else { throw SkillRegistrationError.stampInvalid("no reserved skill_uid") }
        guard sourceFront.allSatisfy({ stampedFront.contains($0) }),
              stampedFront.contains("disable-model-invocation: true")
        else { throw SkillRegistrationError.stampInvalid("frontmatter changed") }
        return uid
    }

    private static func split(_ text: String) -> ([String], String) {
        let lines = text.components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return ([], text) }
        return (Array(lines[1..<end]), lines[(end + 1)...].joined(separator: "\n"))
    }

    /// The exported draft with its draft-only frontmatter swapped for skill frontmatter. It never
    /// carries a skill_uid: the server reserves one at register time.
    static func registrationSource(draft: String, skill: String, record: SOPExportRecord, folder: String) -> String {
        let (front, body) = split(draft)
        let dropped = ["name:", "status:", "approved_as_skill:", "disable-model-invocation:", "skill_uid:", "source_sop:"]
        var lines = ["name: \(skill)"]
        lines += front.filter { line in !dropped.contains(where: line.hasPrefix) }
        lines += ["disable-model-invocation: true",
                  "source_sop: \(SOPExporter.yaml("\(folder)/\(record.sop)"))",
                  "sop_reviewer: \(SOPExporter.yaml(record.reviewer ?? ""))",
                  "sop_approved_at: \(SOPExporter.yaml(record.approvedAt ?? ""))"]
        let cleaned = body
            .replacingOccurrences(of: " (draft)\n", with: "\n")
            .replacingOccurrences(of: "This is a draft written from a reviewed SOP. It has not been reviewed or approved as a skill. It is not installed and nothing runs it. Review it before copying it into a skills folder.",
                                  with: "Written from a reviewed SOP. Registered only after a person reviewed this file. Model invocation is off; run it by name.")
        return "---\n" + lines.joined(separator: "\n") + "\n---" + "\n" + cleaned
    }
}

// MARK: - Command line

/// `--sync-package <package>` pushes and verifies one package. Exit 0 synced, 1 retry, 2 error.
/// `--check-access <companies/<co>/recordings/<name>.hqrec> --as <person> [--hq-root <path>]`. Exit 0 allowed, 3 denied, 2 other.
/// `--retrieve-package <companies/<co>/recordings/<name>.hqrec> [--hq-root <path>]`. Exit 0 complete, 1 missing references or retry, 2 error.
/// `--prepare-skill <package> --export exports/vNNN --skill <slug>` prints the source path and SHA-256.
/// `--register-skill <package> --export exports/vNNN --skill <slug> --reviewer <name> --reviewed-sha256 <hex>`.
enum VaultCLI {
    static let syncFlag = "--sync-package"
    static let accessFlag = "--check-access"
    static let retrieveFlag = "--retrieve-package"
    static let prepareFlag = "--prepare-skill"
    static let registerFlag = "--register-skill"

    static func runIfRequested(_ arguments: [String], hqRoot: URL? = nil,
                               runner: any HQCommandRunning = HQCLIRunner()) -> Int32? {
        guard [syncFlag, accessFlag, retrieveFlag, prepareFlag, registerFlag].contains(where: arguments.contains)
        else { return nil }
        let result = ExitBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            result.set(await run(arguments, hqRoot: hqRoot, runner: runner))
            done.signal()
        }
        done.wait()
        return result.value
    }

    static func run(_ arguments: [String], hqRoot: URL? = nil, runner: any HQCommandRunning) async -> Int32 {
        func value(_ flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), arguments.indices.contains(i + 1),
                  !arguments[i + 1].hasPrefix("--") else { return nil }
            return arguments[i + 1]
        }
        func root(_ given: URL?) -> URL {
            given ?? value("--hq-root").map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/HQ", isDirectory: true)
        }
        func say(_ text: String) { FileHandle.standardOutput.write(Data("\(text)\n".utf8)) }
        func fail(_ text: String) { FileHandle.standardError.write(Data("\(text)\n".utf8)) }
        do {
            if let path = value(syncFlag) {
                let (package, store) = try open(path)
                let report = try await VaultSyncWorkflow.sync(package: package, store: store, runner: runner)
                say(report.statusLine)
                return report.outcome == .synced ? 0 : 1
            }
            if let path = value(accessFlag) {
                guard let person = value("--as"), let company = company(ofVaultPath: path) else {
                    fail("usage: \(accessFlag) companies/<co>/recordings/<name>.hqrec --as <person>")
                    return 2
                }
                let base = root(hqRoot)
                switch await VaultAccess.check(package: path, company: company, person: person, hqRoot: base, runner: runner) {
                case .allowed(let outcome): say("allowed (\(outcome))"); return 0
                case .denied: say("denied"); return 3
                case .missing: say("never-existed"); return 2
                case .ambiguous: say("ambiguous"); return 2
                case .failed(let failure): fail("\(failure.detail). \(failure.retryAdvice)"); return 1
                }
            }
            if let path = value(retrieveFlag) {
                guard let company = company(ofVaultPath: path) else {
                    fail("usage: \(retrieveFlag) companies/<co>/recordings/<name>.hqrec"); return 2
                }
                let base = root(hqRoot)
                let recordings = base.appendingPathComponent("companies/\(company)/recordings", isDirectory: true)
                try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
                let store = RecordingPackageStore(root: try RecordingsRoot.resolve(company: company, destination: recordings))
                let report = try await VaultAccess.retrieve(package: path, store: store, runner: runner)
                say("resolved \(report.resolved.count) references")
                for missing in report.missing { say("missing \(missing)") }
                return report.complete ? 0 : 1
            }
            if let path = value(prepareFlag) {
                guard let folder = value("--export"), let skill = value("--skill") else {
                    fail("usage: \(prepareFlag) <package> --export exports/vNNN --skill <slug>"); return 2
                }
                let (package, store) = try open(path)
                let prepared = try SkillRegistrar.prepare(package: package, export: folder, skill: skill, store: store)
                say(try store.url(for: prepared.path, in: package).path)
                say("sha256 \(prepared.sha256)")
                return 0
            }
            if let path = value(registerFlag) {
                guard let folder = value("--export"), let skill = value("--skill"), let reviewer = value("--reviewer"),
                      let sha = value("--reviewed-sha256") else {
                    fail("usage: \(registerFlag) <package> --export exports/vNNN --skill <slug> --reviewer <name> --reviewed-sha256 <hex>")
                    return 2
                }
                let (package, store) = try open(path)
                let record = try await SkillRegistrar.register(package: package, export: folder, skill: skill,
                                                               reviewer: reviewer, reviewedSHA256: sha, store: store,
                                                               runner: runner)
                say("registered \(record.canonicalPath) \(record.skillUID)")
                return 0
            }
            fail("missing value for a vault flag")
            return 2
        } catch let failure as VaultSyncFailure {
            fail("\(failure.detail). The originals are still on this Mac. \(failure.retryAdvice)")
            return 1
        } catch SkillRegistrationError.failed(let failure) {
            fail("skill registration stopped: \(failure.detail). \(failure.retryAdvice)")
            return 1
        } catch {
            fail("failed: \(error)")
            return 2
        }
    }

    private static func open(_ path: String) throws -> (URL, RecordingPackageStore) {
        let package = URL(fileURLWithPath: path, isDirectory: true)
        let recordings = package.standardizedFileURL.deletingLastPathComponent()
        let company = recordings.deletingLastPathComponent().lastPathComponent
        return (package, RecordingPackageStore(root: try RecordingsRoot.resolve(company: company, destination: recordings)))
    }

    private static func company(ofVaultPath path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 4, VaultAccess.isPackagePath(path, company: parts[1]) else { return nil }
        return parts[1]
    }

    private final class ExitBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Int32 = 2
        var value: Int32 { lock.withLock { stored } }
        func set(_ value: Int32) { lock.withLock { stored = value } }
    }
}
