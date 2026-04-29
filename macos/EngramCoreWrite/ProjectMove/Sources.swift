// macos/EngramCoreWrite/ProjectMove/Sources.swift
// Mirrors src/core/project-move/sources.ts (Node parity baseline).
//
// Enumerates the 7 AI session root directories a project move must scan +
// patch, plus the per-source `cwd → directory-name` encoding rules. Also
// supplies the recursive walk + literal-substring grep used by the
// orchestrator and the post-move review.
import Darwin
import Foundation

public enum SourceId: String, CaseIterable, Sendable, Equatable {
    case claudeCode = "claude-code"
    case codex
    case geminiCli = "gemini-cli"
    case iflow
    case opencode
    case antigravity
    case copilot
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

public enum WalkIssueReason: String, Equatable, Sendable {
    case readdirFailed = "readdir_failed"
    case statFailed = "stat_failed"
    case tooLarge = "too_large"
    case skippedSymlink = "skipped_symlink"
    case skippedWrongExt = "skipped_wrong_ext"
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
    /// The 7 session roots a project move must consider. Ordering matches
    /// Node parity: known-active first (claude-code → codex → gemini-cli →
    /// iflow), then mvp.py compat tail (opencode → antigravity → copilot).
    public static func roots(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [SourceRoot] {
        let home = homeDirectory.path
        return [
            SourceRoot(
                id: .claudeCode,
                path: (home as NSString).appendingPathComponent(".claude/projects"),
                encodeProjectDir: { cwd in ClaudeCodeProjectDir.encode(cwd) }
            ),
            SourceRoot(
                id: .codex,
                path: (home as NSString).appendingPathComponent(".codex/sessions"),
                encodeProjectDir: nil
            ),
            SourceRoot(
                id: .geminiCli,
                path: (home as NSString).appendingPathComponent(".gemini/tmp"),
                encodeProjectDir: { cwd in (cwd as NSString).lastPathComponent }
            ),
            SourceRoot(
                id: .iflow,
                path: (home as NSString).appendingPathComponent(".iflow/projects"),
                encodeProjectDir: { cwd in encodeIflow(cwd) }
            ),
            SourceRoot(
                id: .opencode,
                path: (home as NSString).appendingPathComponent(".local/share/opencode"),
                encodeProjectDir: nil
            ),
            SourceRoot(
                id: .antigravity,
                path: (home as NSString).appendingPathComponent(".antigravity"),
                encodeProjectDir: nil
            ),
            SourceRoot(
                id: .copilot,
                path: (home as NSString).appendingPathComponent(".copilot"),
                encodeProjectDir: nil
            ),
        ]
    }

    /// Encode a project cwd into the iFlow project-directory name. Joins
    /// path segments with `-` after stripping per-segment leading/trailing
    /// dashes. Lossy by design — `/a/-foo-/p` and `/a/foo/p` both encode
    /// to `-a-foo-p`; the orchestrator's pre-flight stat catches the
    /// collision rather than overwriting.
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

    /// Recursively walk `root` invoking `onFile` for each session file
    /// (extension in `extensions`, size ≤ `maxFileBytes`, not a symlink).
    /// Issues (read errors, skips) reported via `onIssue` so the caller
    /// can surface them in `migration_log.audit_note`. Lazy/iterative —
    /// no array materialisation.
    public static func walkSessionFiles(
        root: String,
        extensions: Set<String> = [".jsonl", ".json"],
        maxFileBytes: Int64 = 128 * 1024 * 1024,
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
                if mode != S_IFREG { continue }
                guard let dot = name.lastIndex(of: ".") else { continue }
                let ext = String(name[dot...])
                if !extensions.contains(ext) { continue }
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

    /// Find JSONL/JSON files under `root` containing `needle` as a literal
    /// byte substring. Tries `grep -rlF` first (~100× faster); falls back
    /// to the in-process walk on grep failure.
    public static func findReferencingFiles(
        root: String,
        needle: String
    ) -> [String] {
        if needle.isEmpty { return [] }
        guard FileManager.default.fileExists(atPath: root) else { return [] }
        if let viaGrep = tryGrepFastPath(root: root, needle: needle) {
            return viaGrep.sorted()
        }
        return walkAndGrepFallback(root: root, needle: needle).sorted()
    }

    // MARK: - internals

    private static func tryGrepFastPath(root: String, needle: String) -> [String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "grep", "-rlF",
            "--include=*.jsonl",
            "--include=*.json",
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
            return parseGrepOutput(stdoutData)
        }
        // grep exits 1 on no-matches with empty stderr; treat that as success.
        if process.terminationStatus == 1 && stderrData.isEmpty {
            return []
        }
        return nil
    }

    private static func parseGrepOutput(_ data: Data) -> [String] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func walkAndGrepFallback(root: String, needle: String) -> [String] {
        let needleData = Data(needle.utf8)
        var hits: [String] = []
        walkSessionFiles(root: root, onIssue: nil) { filePath in
            if let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
               data.range(of: needleData) != nil {
                hits.append(filePath)
            }
        }
        return hits
    }
}
