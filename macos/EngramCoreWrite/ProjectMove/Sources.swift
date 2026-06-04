// macos/EngramCoreWrite/ProjectMove/Sources.swift
// Mirrors src/core/project-move/sources.ts (Node parity baseline).
//
// Enumerates the AI session root directories a project move must scan +
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
    case qoder
    case opencode
    case antigravity
    case antigravityLegacy = "antigravity-legacy"
    case commandcode
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
    /// The session roots a project move must consider. Ordering matches
    /// Node parity: known-active first (claude-code → codex → gemini-cli →
    /// iflow → qoder), then flat-layout tail (opencode → antigravity →
    /// antigravity-legacy → commandcode → copilot).
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
                encodeProjectDir: { cwd in encodeGemini(cwd) }
            ),
            SourceRoot(
                id: .iflow,
                path: (home as NSString).appendingPathComponent(".iflow/projects"),
                encodeProjectDir: { cwd in encodeIflow(cwd) }
            ),
            SourceRoot(
                id: .qoder,
                path: (home as NSString).appendingPathComponent(".qoder/projects"),
                encodeProjectDir: { cwd in ClaudeCodeProjectDir.encode(cwd) }
            ),
            SourceRoot(
                id: .opencode,
                path: (home as NSString).appendingPathComponent(".local/share/opencode"),
                encodeProjectDir: nil
            ),
            SourceRoot(
                id: .antigravity,
                path: (home as NSString).appendingPathComponent(".gemini/antigravity-cli/brain"),
                encodeProjectDir: nil
            ),
            SourceRoot(
                id: .antigravityLegacy,
                path: (home as NSString).appendingPathComponent(".gemini/antigravity"),
                encodeProjectDir: nil
            ),
            SourceRoot(
                id: .commandcode,
                path: (home as NSString).appendingPathComponent(".commandcode/projects"),
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

    public static func collectOtherIflowCwdsSharingEncodedDir(
        root: String,
        targetEncodedDir: String,
        srcCwd: String
    ) -> [String] {
        var conflicts = Set<String>()
        walkSessionFiles(root: root) { filePath in
            guard filePath.contains("/\(targetEncodedDir)/"),
                  let content = try? String(contentsOfFile: filePath, encoding: .utf8)
            else { return }
            for line in content.split(whereSeparator: \.isNewline) {
                guard let cwd = extractJSONLineCwd(String(line)),
                      cwd != srcCwd,
                      encodeIflow(cwd) == targetEncodedDir
                else { continue }
                conflicts.insert(cwd)
            }
        }
        return conflicts.sorted()
    }

    /// Encode a project cwd into the Gemini CLI project slug used both as the
    /// `~/.gemini/tmp/<slug>/` directory name and as the `projects.json` value.
    /// Gemini slugifies the cwd basename: lowercase, `_` → `-`, then strip the
    /// wrapping dashes. e.g. `/Users/bing/-Code-` → `code`,
    /// `/Users/bing/-Code-/WebSite_Gemini` → `website-gemini`. Lossy by design.
    public static func encodeGemini(_ absolutePath: String) -> String {
        var s = (absolutePath as NSString).lastPathComponent
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")[...]
        while s.first == "-" { s = s.dropFirst() }
        while s.last == "-" { s = s.dropLast() }
        return String(s)
    }

    /// Recursively walk `root` invoking `onFile` for each session file
    /// (extension in `extensions`, size ≤ `maxFileBytes`, not a symlink).
    /// Issues (read errors, skips) reported via `onIssue` so the caller
    /// can surface them in `migration_log.audit_note`. Lazy/iterative —
    /// no array materialisation.
    public static func walkSessionFiles(
        root: String,
        extensions: Set<String> = [".jsonl", ".json"],
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

    /// Find JSONL/JSON files under `root` containing `needle` or its canonical
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
