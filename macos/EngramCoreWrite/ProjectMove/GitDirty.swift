// macos/EngramCoreWrite/ProjectMove/GitDirty.swift
// Mirrors src/core/project-move/git-dirty.ts (Node parity baseline).
//
// Mechanism-only: returns structured info, never throws. Orchestrator owns
// the policy (warn / require --force / future stash path).
import Foundation

public struct GitDirtyStatus: Equatable, Sendable {
    /// `src` is a git repository (contains `.git` as either a directory or
    /// a gitdir file for worktrees).
    public let isGitRepo: Bool
    /// `git status --porcelain` produced any output.
    public let dirty: Bool
    /// Every dirty line starts with `??` (only untracked files).
    public let untrackedOnly: Bool
    /// Raw porcelain output, trimmed.
    public let porcelain: String

    public static let nonRepo = GitDirtyStatus(
        isGitRepo: false,
        dirty: false,
        untrackedOnly: false,
        porcelain: ""
    )

    public init(isGitRepo: Bool, dirty: Bool, untrackedOnly: Bool, porcelain: String) {
        self.isGitRepo = isGitRepo
        self.dirty = dirty
        self.untrackedOnly = untrackedOnly
        self.porcelain = porcelain
    }
}

public enum GitDirty {
    /// Inspect `src` for uncommitted git state. Returns `.nonRepo` if `.git`
    /// is missing or git itself is unavailable; never throws so callers
    /// don't have to model "tool missing" as an error.
    public static func check(_ src: String) async -> GitDirtyStatus {
        let gitMarker = (src as NSString).appendingPathComponent(".git")
        guard FileManager.default.fileExists(atPath: gitMarker) else {
            return .nonRepo
        }
        // .git can be either a directory (normal repo) or a regular file
        // (worktree gitdir pointer). Either qualifies; just confirm it's
        // not something exotic like a broken symlink.
        let isGitRepo = true

        return await Task.detached { () -> GitDirtyStatus in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git", "-C", src, "status", "--porcelain"]
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                return GitDirtyStatus(
                    isGitRepo: isGitRepo,
                    dirty: false,
                    untrackedOnly: false,
                    porcelain: ""
                )
            }
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            _ = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                return GitDirtyStatus(
                    isGitRepo: isGitRepo,
                    dirty: false,
                    untrackedOnly: false,
                    porcelain: ""
                )
            }

            let porcelain = (String(data: data, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let dirty = !porcelain.isEmpty
            let untrackedOnly = dirty && porcelain
                .split(separator: "\n", omittingEmptySubsequences: false)
                .allSatisfy { line in
                    let lstripped = line.drop { $0 == " " || $0 == "\t" }
                    return lstripped.hasPrefix("??")
                }
            return GitDirtyStatus(
                isGitRepo: isGitRepo,
                dirty: dirty,
                untrackedOnly: untrackedOnly,
                porcelain: porcelain
            )
        }.value
    }
}
