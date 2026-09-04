// macos/EngramCoreWrite/ProjectMove/Sources.swift
// Mirrors src/core/project-move/sources.ts (Node parity baseline).
//
// Enumerates the AI session root directories a project move must scan +
// patch, plus the per-source `cwd → directory-name` encoding rules. Also
// supplies the recursive walk + literal-substring grep used by the
// orchestrator and the post-move review.
import Darwin
import CryptoKit
import EngramCoreRead
import Foundation
import GRDB

enum ProjectPathVariants {
    static func variants(_ path: String) -> [String] {
        var variants: [String] = []
        for value in [
            path,
            path.precomposedStringWithCanonicalMapping,
            path.decomposedStringWithCanonicalMapping,
        ] where !variants.contains(where: { $0.utf8.elementsEqual(value.utf8) }) {
            variants.append(value)
        }
        return variants
    }

    static func filesystemAliases(_ path: String) -> [String] {
        var aliases: [String] = []
        let canonical = canonicalEncodingPath(path)
        for value in variants(path) + variants(canonical) {
            if !aliases.contains(where: { $0.utf8.elementsEqual(value.utf8) }) {
                aliases.append(value)
            }
        }
        return aliases
    }

    static func equivalentIgnoringFilesystemCase(_ lhs: String, _ rhs: String) -> Bool {
        filesystemAliases(lhs).contains { left in
            filesystemAliases(rhs).contains { right in
                left.caseInsensitiveCompare(right) == .orderedSame
            }
        }
    }

    static func canonicalEncodingPath(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        var existingPrefix = standardized
        var missingSuffix: [String] = []

        while true {
            if let resolved = Darwin.realpath(existingPrefix, nil) {
                defer { free(resolved) }
                return missingSuffix.reduce(String(cString: resolved)) { result, component in
                    (result as NSString).appendingPathComponent(component)
                }
            }
            let prefix = existingPrefix as NSString
            let parent = prefix.deletingLastPathComponent
            guard parent != existingPrefix else { return standardized }
            missingSuffix.insert(prefix.lastPathComponent, at: 0)
            existingPrefix = parent
        }
    }
}

func projectMovePatchSourcePaths(_ path: String) -> [String] {
    ProjectPathVariants.filesystemAliases(path)
}

func projectDirEncodingNames(
    for path: String,
    encode: (String) -> String
) -> [String] {
    var names: [String] = []
    for value in projectMovePatchSourcePaths(path) {
        let name = encode(value)
        if !names.contains(name) { names.append(name) }
    }
    return names
}

public enum SourceId: String, CaseIterable, Sendable, Equatable {
    case claudeCode = "claude-code"
    case codex
    case codexArchived = "codex-archived"
    case codexRolloutSummaries = "codex-rollout-summaries"
    case geminiCli = "gemini-cli"
    case kimi
    case iflow
    case qwen
    case qoder
    case opencode
    case antigravity
    case antigravityLegacy = "antigravity-legacy"
    case commandcode
    case copilot
}

public struct OpenCodeSQLitePatchResult: Equatable, Sendable {
    public let databasePath: String
    public let sessionIds: [String]

    public init(databasePath: String, sessionIds: [String]) {
        self.databasePath = databasePath
        self.sessionIds = sessionIds
    }

    public var occurrences: Int { sessionIds.count }
}

public enum OpenCodeSQLiteProjectMove {
    public static func databasePath(root: String) -> String {
        (root as NSString).appendingPathComponent("opencode.db")
    }

    public static func countReferences(
        root: String,
        oldPaths: [String]
    ) throws -> OpenCodeSQLitePatchResult {
        let dbPath = databasePath(root: root)
        guard FileManager.default.fileExists(atPath: dbPath) else {
            return OpenCodeSQLitePatchResult(databasePath: dbPath, sessionIds: [])
        }
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: dbPath, configuration: configuration)
        let ids = try queue.read { db -> [String] in
            guard try hasSessionDirectory(db) else { return [] }
            return try matchingSessions(db, oldPaths: oldPaths).map(\.id)
        }
        return OpenCodeSQLitePatchResult(databasePath: dbPath, sessionIds: ids)
    }

    public static func patch(
        root: String,
        oldPaths: [String],
        newPath: String
    ) throws -> OpenCodeSQLitePatchResult {
        let dbPath = databasePath(root: root)
        guard FileManager.default.fileExists(atPath: dbPath) else {
            return OpenCodeSQLitePatchResult(databasePath: dbPath, sessionIds: [])
        }
        let queue = try DatabaseQueue(path: dbPath)
        let ids = try queue.write { db -> [String] in
            guard try hasSessionDirectory(db) else { return [] }
            let rows = try matchingSessions(db, oldPaths: oldPaths)
            for row in rows {
                let suffix = String(row.directory.dropFirst(row.matchedPath.count))
                try db.execute(
                    sql: "UPDATE session SET directory = ? WHERE id = ? AND directory = ?",
                    arguments: [newPath + suffix, row.id, row.directory]
                )
            }
            return rows.map(\.id)
        }
        return OpenCodeSQLitePatchResult(databasePath: dbPath, sessionIds: ids)
    }

    public static func reverse(
        databasePath: String,
        sessionIds: [String],
        oldPaths: [String],
        newPath: String
    ) throws {
        guard !sessionIds.isEmpty,
              FileManager.default.fileExists(atPath: databasePath)
        else { return }
        let queue = try DatabaseQueue(path: databasePath)
        try queue.write { db in
            guard try hasSessionDirectory(db) else { return }
            let variants = pathVariants(oldPaths)
            for id in sessionIds {
                guard
                    let directory = try String.fetchOne(
                        db,
                        sql: "SELECT directory FROM session WHERE id = ?",
                        arguments: [id]
                    ),
                    let matched = matchingPrefix(directory: directory, variants: variants)
                else { continue }
                let suffix = String(directory.dropFirst(matched.count))
                try db.execute(
                    sql: "UPDATE session SET directory = ? WHERE id = ? AND directory = ?",
                    arguments: [newPath + suffix, id, directory]
                )
            }
        }
    }

    public static func residualReferenceLocators(root: String, oldPaths: [String]) -> [String] {
        guard let result = try? countReferences(root: root, oldPaths: oldPaths) else {
            return []
        }
        return result.sessionIds.map { "\(result.databasePath)::session:\($0):directory" }
    }

    private static func hasSessionDirectory(_ db: GRDB.Database) throws -> Bool {
        let tableExists = try Bool.fetchOne(
            db,
            sql: """
            SELECT EXISTS(
                SELECT 1 FROM sqlite_master
                WHERE type = 'table' AND name = 'session'
            )
            """
        ) ?? false
        guard tableExists else { return false }
        let names = Set(try String.fetchAll(
            db,
            sql: "SELECT name FROM pragma_table_info('session')"
        ))
        return names.contains("id") && names.contains("directory")
    }

    private struct MatchingSession {
        let id: String
        let directory: String
        let matchedPath: String
    }

    private static func matchingSessions(
        _ db: GRDB.Database,
        oldPaths: [String]
    ) throws -> [MatchingSession] {
        let variants = pathVariants(oldPaths)
        guard !variants.isEmpty else { return [] }
        let predicates = Array(
            repeating: "(directory = ? OR substr(directory, 1, length(?)) = ?)",
            count: variants.count
        ).joined(separator: " OR ")
        var arguments = StatementArguments()
        for variant in variants {
            arguments += [variant, variant + "/", variant + "/"]
        }
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT id, directory FROM session
            WHERE \(predicates)
            ORDER BY id
            """,
            arguments: arguments
        )
        return rows.compactMap { row in
            let directory: String = row["directory"]
            guard let matched = matchingPrefix(directory: directory, variants: variants) else {
                return nil
            }
            return MatchingSession(id: row["id"], directory: directory, matchedPath: matched)
        }
    }

    private static func pathVariants(_ paths: [String]) -> [String] {
        var result: [String] = []
        for value in paths.flatMap(ProjectPathVariants.variants) {
            if !result.contains(where: { $0.utf8.elementsEqual(value.utf8) }) {
                result.append(value)
            }
        }
        return result
    }

    private static func matchingPrefix(directory: String, variants: [String]) -> String? {
        for variant in variants {
            if directory.utf8.elementsEqual(variant.utf8)
                || directory.utf8.starts(with: (variant + "/").utf8)
            {
                return variant
            }
        }
        return nil
    }
}

public struct SourceRoot: Sendable {
    public let id: SourceId
    public let path: String
    /// Returns the per-project directory name under `path`. `nil` for
    /// flat-layout sources (sessions stored side-by-side without
    /// per-project grouping; only file-content patching is needed).
    public let encodeProjectDir: (@Sendable (_ cwd: String) -> String)?

    public init(
        id: SourceId,
        path: String,
        encodeProjectDir: (@Sendable (String) -> String)?
    ) {
        self.id = id
        self.path = path
        self.encodeProjectDir = encodeProjectDir
    }
}

public struct GroupedDirReconcileResult: Equatable, Sendable {
    public var scannedDirs: Int
    public var plannedRenames: Int
    public var appliedRenames: Int
    public var collisions: Int
    public var ambiguous: Int
    public var issues: Int

    public init(
        scannedDirs: Int = 0,
        plannedRenames: Int = 0,
        appliedRenames: Int = 0,
        collisions: Int = 0,
        ambiguous: Int = 0,
        issues: Int = 0
    ) {
        self.scannedDirs = scannedDirs
        self.plannedRenames = plannedRenames
        self.appliedRenames = appliedRenames
        self.collisions = collisions
        self.ambiguous = ambiguous
        self.issues = issues
    }
}

public enum GroupedDirReconcile {
    private static let structuredCwdReadCapBytes: Int64 = 50 * 1024 * 1024

    private struct RepairPlan {
        let sourceDir: String
        let targetDir: String
    }

    public static func run(
        roots: [SourceRoot],
        dryRun: Bool = false
    ) -> GroupedDirReconcileResult {
        var result = GroupedDirReconcileResult()
        let fm = FileManager.default

        for root in roots {
            guard shouldReconcile(root), let encode = root.encodeProjectDir else { continue }
            guard let entries = try? fm.contentsOfDirectory(atPath: root.path) else { continue }

            for name in entries {
                let sourceDir = (root.path as NSString).appendingPathComponent(name)
                guard isDirectoryNoFollow(sourceDir) else { continue }
                result.scannedDirs += 1

                var walkIssues = 0
                let targetNames = structuredCwds(in: sourceDir, issues: &walkIssues)
                    .map(encode)
                result.issues += walkIssues
                let uniqueTargets = Set(targetNames)
                if uniqueTargets.isEmpty { continue }
                guard uniqueTargets.count == 1, let targetName = uniqueTargets.first else {
                    result.ambiguous += 1
                    continue
                }
                if targetName == name { continue }

                let targetDir = (root.path as NSString).appendingPathComponent(targetName)
                result.plannedRenames += 1
                guard !dryRun else { continue }

                let plan = RepairPlan(sourceDir: sourceDir, targetDir: targetDir)
                switch apply(plan: plan) {
                case .applied:
                    result.appliedRenames += 1
                case .collision:
                    result.collisions += 1
                case .issue:
                    result.issues += 1
                }
            }
        }

        return result
    }

    private static func shouldReconcile(_ root: SourceRoot) -> Bool {
        root.id == .claudeCode || root.id == .qoder || root.id == .commandcode
    }

    private enum ApplyResult {
        case applied
        case collision
        case issue
    }

    private static func apply(plan: RepairPlan) -> ApplyResult {
        let fm = FileManager.default
        if fm.fileExists(atPath: plan.targetDir) {
            return .collision
        }
        do {
            try fm.copyItem(atPath: plan.sourceDir, toPath: plan.targetDir)
        } catch {
            if fm.fileExists(atPath: plan.targetDir) {
                return .collision
            }
            return .issue
        }
        do {
            try fm.removeItem(atPath: plan.sourceDir)
            return .applied
        } catch {
            return .issue
        }
    }

    private static func isDirectoryNoFollow(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR
    }

    private static func structuredCwds(in dir: String, issues: inout Int) -> [String] {
        var cwds = Set<String>()
        var localIssues = 0
        SessionSources.walkSessionFiles(
            root: dir,
            maxFileBytes: structuredCwdReadCapBytes,
            onIssue: { _ in localIssues += 1 },
            onFile: { file in
                autoreleasepool {
                    guard let text = try? String(contentsOfFile: file, encoding: .utf8) else {
                        localIssues += 1
                        return
                    }
                    for line in text.split(whereSeparator: \.isNewline) {
                        // Session transcripts contain many large JSON message
                        // rows but only a handful of structured cwd fields.
                        // Avoid constructing Foundation JSON object graphs for
                        // lines that cannot contribute reconciliation evidence.
                        guard line.contains(#""cwd""#) else { continue }
                        if let cwd = extractStructuredCwd(String(line)) {
                            cwds.insert(cwd)
                        }
                    }
                }
            }
        )
        issues += localIssues
        return cwds.sorted()
    }

    private static func extractStructuredCwd(_ line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let cwd = object["cwd"] as? String, !cwd.isEmpty {
            return cwd
        }
        if let payload = object["payload"] as? [String: Any],
           let cwd = payload["cwd"] as? String,
           !cwd.isEmpty {
            return cwd
        }
        return nil
    }
}

public enum WalkIssueReason: String, Equatable, Sendable {
    case readdirFailed = "readdir_failed"
    case statFailed = "stat_failed"
    case tooLarge = "too_large"
    case skippedSymlink = "skipped_symlink"
    case skippedWrongExt = "skipped_wrong_ext"
    case skippedNonRegular = "skipped_non_regular"
}

public struct WalkIssue: Equatable, Sendable {
    public let path: String
    public let reason: WalkIssueReason
    public let detail: String?

    public init(path: String, reason: WalkIssueReason, detail: String? = nil) {
        self.path = path
        self.reason = reason
        self.detail = detail
    }
}

public enum SessionSources {
    public static let defaultSessionExtensions: Set<String> = [".jsonl", ".json"]
    public static let defaultSessionFilenames: Set<String> = [".project_root", "workspace.yaml"]

    /// The session roots a project move must consider. Ordering matches
    /// Node parity: known-active first (claude-code → Codex stores →
    /// gemini-cli → iflow → qwen → qoder), then flat-layout tail (opencode →
    /// antigravity → antigravity-legacy → commandcode → copilot).
    public static func roots(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [SourceRoot] {
        let paths = Dictionary(
            uniqueKeysWithValues: SessionStorageRootCatalog.paths(homeDirectory: homeDirectory)
                .map { ($0.id, $0.path) }
        )
        func path(_ id: SourceId) -> String {
            guard let value = paths[id.rawValue] else {
                preconditionFailure("Missing canonical session root for \(id.rawValue)")
            }
            return value
        }
        let claudePaths = ProjectReviewPathSupport.sourceRoots(homeDirectory: homeDirectory)
            .filter { $0.id == SourceId.claudeCode.rawValue }
            .map(\.path)
        let claudeRoots = claudePaths.map { projectsRoot in
            SourceRoot(
                id: .claudeCode,
                path: projectsRoot,
                encodeProjectDir: { cwd in ClaudeCodeProjectDir.encode(cwd) }
            )
        }
        return claudeRoots + [
            SourceRoot(
                id: .codex,
                path: path(.codex),
                encodeProjectDir: nil
            ),
            SourceRoot(
                id: .codexArchived,
                path: path(.codexArchived),
                encodeProjectDir: nil
            ),
            SourceRoot(
                id: .codexRolloutSummaries,
                path: path(.codexRolloutSummaries),
                encodeProjectDir: nil
            ),
            SourceRoot(
                id: .geminiCli,
                path: path(.geminiCli),
                encodeProjectDir: { cwd in encodeGemini(cwd) }
            ),
            SourceRoot(
                id: .kimi,
                path: path(.kimi),
                encodeProjectDir: { cwd in encodeKimi(cwd) }
            ),
            SourceRoot(
                id: .iflow,
                path: path(.iflow),
                encodeProjectDir: { cwd in encodeIflow(cwd) }
            ),
            SourceRoot(
                id: .qwen,
                path: path(.qwen),
                encodeProjectDir: { cwd in encodeQwen(cwd) }
            ),
            SourceRoot(
                id: .qoder,
                path: path(.qoder),
                encodeProjectDir: { cwd in ClaudeCodeProjectDir.encode(cwd) }
            ),
            SourceRoot(
                id: .opencode,
                path: path(.opencode),
                encodeProjectDir: nil
            ),
            SourceRoot(
                id: .antigravity,
                path: path(.antigravity),
                encodeProjectDir: nil
            ),
            SourceRoot(
                id: .antigravityLegacy,
                path: path(.antigravityLegacy),
                encodeProjectDir: nil
            ),
            SourceRoot(
                id: .commandcode,
                path: path(.commandcode),
                encodeProjectDir: { cwd in encodeCommandCode(cwd) }
            ),
            SourceRoot(
                id: .copilot,
                path: path(.copilot),
                encodeProjectDir: nil
            ),
        ]
    }

    /// Encode a project cwd into the iFlow project-directory name. Joins
    /// path segments with `-` after stripping per-segment leading/trailing
    /// dashes. Lossy by design — `/a/-foo-/p` and `/a/foo/p` both encode
    /// to `-a-foo-p`; the orchestrator's iFlow pre-flight cwd probe catches
    /// the collision rather than overwriting.
    public static func encodeIflow(_ absolutePath: String) -> String {
        absolutePath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { segment -> String in
                var s = segment[...]
                while s.first == "-" { s = s.dropFirst() }
                while s.last == "-" { s = s.dropLast() }
                return String(s)
            }
            .joined(separator: "-")
    }

    /// Encode a project cwd into Qwen Code's project-directory name.
    /// Same non-alnum → `-` sanitize as Claude Code (UTF-16 units, no
    /// collapsing), but Qwen never truncates at 200 or appends a hash.
    public static func encodeQwen(_ absolutePath: String) -> String {
        let units = absolutePath.utf16.map { u -> UInt16 in
            let isAlnum = (u >= 48 && u <= 57) // 0-9
                || (u >= 65 && u <= 90) // A-Z
                || (u >= 97 && u <= 122) // a-z
            return isAlnum ? u : 45 // '-'
        }
        return String(utf16CodeUnits: units, count: units.count)
    }

    /// CommandCode's live writer lowercases cwd, drops the leading separator,
    /// and collapses each run of non-alphanumeric characters to one dash.
    /// The adapter's fallback decoder is intentionally lossy and is not the
    /// inverse of this slug.
    public static func encodeCommandCode(_ absolutePath: String) -> String {
        var slug = ""
        var pendingDash = false
        for byte in absolutePath.utf8 {
            switch byte {
            case UInt8(ascii: "0") ... UInt8(ascii: "9"):
                if pendingDash, !slug.isEmpty { slug.append("-") }
                slug.append(Character(UnicodeScalar(byte)))
                pendingDash = false
            case UInt8(ascii: "A") ... UInt8(ascii: "Z"):
                if pendingDash, !slug.isEmpty { slug.append("-") }
                slug.append(Character(UnicodeScalar(byte + 32)))
                pendingDash = false
            case UInt8(ascii: "a") ... UInt8(ascii: "z"):
                if pendingDash, !slug.isEmpty { slug.append("-") }
                slug.append(Character(UnicodeScalar(byte)))
                pendingDash = false
            default:
                pendingDash = !slug.isEmpty
            }
        }
        return slug
    }

    public static func collectOtherIflowCwdsSharingEncodedDir(
        root: String,
        targetEncodedDir: String,
        srcCwd: String
    ) -> [String] {
        var conflicts = Set<String>()
        let canonicalSource = ProjectPathVariants.canonicalEncodingPath(srcCwd)
        walkSessionFiles(root: root) { filePath in
            guard filePath.contains("/\(targetEncodedDir)/"),
                  let content = try? String(contentsOfFile: filePath, encoding: .utf8)
            else { return }
            for line in content.split(whereSeparator: \.isNewline) {
                guard let cwd = extractJSONLineCwd(String(line)) else { continue }
                let lexicalCwd = URL(fileURLWithPath: cwd).standardizedFileURL.path
                let canonicalCwd = ProjectPathVariants.canonicalEncodingPath(cwd)
                guard canonicalCwd != canonicalSource,
                      [cwd, lexicalCwd, canonicalCwd].contains(where: {
                          encodeIflow($0) == targetEncodedDir
                      })
                else { continue }
                conflicts.insert(cwd)
            }
        }
        return conflicts.sorted()
    }

    /// Encode a project cwd into Gemini CLI's project directory name.
    /// Current Gemini CLI uses SHA-256 of the project root path string.
    public static func encodeGemini(_ absolutePath: String) -> String {
        SHA256.hash(data: Data(absolutePath.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Kimi stores each workspace under MD5(cwd), optionally prefixed by the
    /// non-local `kaos` name recorded in ~/.kimi/kimi.json.
    public static func encodeKimi(_ absolutePath: String, kaos: String? = nil) -> String {
        let digest = Insecure.MD5.hash(data: Data(absolutePath.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        guard let kaos, !kaos.isEmpty, kaos != "local" else { return digest }
        return "\(kaos)_\(digest)"
    }

    /// Recursively walk `root` invoking `onFile` for each session file
    /// (extension in `extensions`, size ≤ `maxFileBytes`, not a symlink).
    /// Issues (read errors, skips) reported via `onIssue` so the caller
    /// can surface them in `migration_log.audit_note`. Lazy/iterative —
    /// no array materialisation.
    public static func walkSessionFiles(
        root: String,
        extensions: Set<String> = defaultSessionExtensions,
        filenames: Set<String> = defaultSessionFilenames,
        maxFileBytes: Int64 = Int64.max,
        onIssue: ((WalkIssue) -> Void)? = nil,
        onFile: (String) -> Void
    ) {
        guard FileManager.default.fileExists(atPath: root) else {
            return // missing root → silent empty walk (Node parity)
        }

        var stack: [String] = [root]
        let fm = FileManager.default
        while let dir = stack.popLast() {
            let entries: [String]
            do {
                entries = try fm.contentsOfDirectory(atPath: dir)
            } catch {
                onIssue?(WalkIssue(
                    path: dir,
                    reason: .readdirFailed,
                    detail: error.localizedDescription
                ))
                continue
            }
            for name in entries {
                let full = (dir as NSString).appendingPathComponent(name)
                var info = stat()
                if lstat(full, &info) != 0 {
                    onIssue?(WalkIssue(
                        path: full,
                        reason: .statFailed,
                        detail: String(cString: strerror(errno))
                    ))
                    continue
                }
                let mode = info.st_mode & S_IFMT
                if mode == S_IFLNK {
                    onIssue?(WalkIssue(path: full, reason: .skippedSymlink))
                    continue
                }
                if mode == S_IFDIR {
                    stack.append(full)
                    continue
                }
                if mode != S_IFREG {
                    onIssue?(WalkIssue(
                        path: full,
                        reason: .skippedNonRegular,
                        detail: "mode=\(String(info.st_mode, radix: 8))"
                    ))
                    continue
                }
                let ext = name.lastIndex(of: ".").map { String(name[$0...]) } ?? ""
                if !filenames.contains(name), !extensions.contains(ext) { continue }
                if Int64(info.st_size) > maxFileBytes {
                    onIssue?(WalkIssue(
                        path: full,
                        reason: .tooLarge,
                        detail: "size=\(info.st_size), limit=\(maxFileBytes)"
                    ))
                    continue
                }
                onFile(full)
            }
        }
    }

    /// Find patchable session files under `root` containing `needle` or its canonical
    /// Unicode path variants as literal byte substrings. Tries `grep -rlF`
    /// first (~100× faster); falls back to the in-process walk on grep failure.
    public static func findReferencingFiles(
        root: String,
        needle: String
    ) -> [String] {
        if needle.isEmpty { return [] }
        guard FileManager.default.fileExists(atPath: root) else { return [] }
        let needles = uniqueByteNeedles([
            needle,
            needle.precomposedStringWithCanonicalMapping,
            needle.decomposedStringWithCanonicalMapping,
        ])
        // Keep the grep fast path for ASCII trees, but verify Unicode no-hit
        // cases in-process so canonical path forms are matched by raw bytes.
        if let viaGrep = tryGrepFastPath(root: root, needles: needles),
           !viaGrep.isEmpty || needles.allSatisfy(isASCII) {
            return viaGrep.sorted()
        }
        return walkAndGrepFallback(root: root, needles: needles).sorted()
    }

    // MARK: - internals

    private static func uniqueByteNeedles(_ candidates: [String]) -> [String] {
        var seen = Set<[UInt8]>()
        var needles: [String] = []
        for candidate in candidates {
            let key = Array(candidate.utf8)
            if seen.insert(key).inserted {
                needles.append(candidate)
            }
        }
        return needles
    }

    private static func isASCII(_ value: String) -> Bool {
        value.utf8.allSatisfy { $0 < 0x80 }
    }

    private static func tryGrepFastPath(root: String, needles: [String]) -> [String]? {
        var hits = Set<String>()
        for needle in needles {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [
                "grep", "-rlF",
                "--include=*.jsonl",
                "--include=*.json",
                "--include=.project_root",
                "--include=workspace.yaml",
                "--",
                needle, root,
            ]
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            do {
                try process.run()
            } catch {
                return nil
            }
            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                hits.formUnion(parseGrepOutput(stdoutData))
                continue
            }
            // grep exits 1 on no-matches with empty stderr; keep trying the
            // remaining normalized needles.
            if process.terminationStatus == 1 && stderrData.isEmpty {
                continue
            }
            return nil
        }
        return Array(hits)
    }

    private static func parseGrepOutput(_ data: Data) -> [String] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func walkAndGrepFallback(root: String, needles: [String]) -> [String] {
        let needleData = needles.map { Data($0.utf8) }
        var hits: [String] = []
        walkSessionFiles(root: root, onIssue: nil) { filePath in
            if let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
               needleData.contains(where: { data.range(of: $0) != nil }) {
                hits.append(filePath)
            }
        }
        return Array(Set(hits))
    }

    private static func extractJSONLineCwd(_ line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cwd = object["cwd"] as? String,
              !cwd.isEmpty
        else { return nil }
        return cwd
    }
}
