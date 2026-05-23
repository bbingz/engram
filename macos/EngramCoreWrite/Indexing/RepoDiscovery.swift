// macos/EngramCoreWrite/Indexing/RepoDiscovery.swift
// Populates `git_repos` from the distinct `cwd`s referenced by sessions.
//
// Replaces the removed Node `src/core/git-probe.ts`. The old probe parsed
// `git log --format=%H|%s|%aI`, which corrupts on commit messages containing
// `|`; this implementation uses a NUL (`%x00`) field separator and never `|`.
import Foundation
import GRDB

/// Structured git metadata for a single repository root.
public struct GitRepoProbe: Equatable, Sendable {
    public let path: String
    public let name: String
    public let branch: String?
    public let dirtyCount: Int
    public let untrackedCount: Int
    public let unpushedCount: Int
    public let lastCommitHash: String?
    public let lastCommitMsg: String?
    public let lastCommitAt: String?

    public init(
        path: String,
        name: String,
        branch: String?,
        dirtyCount: Int,
        untrackedCount: Int,
        unpushedCount: Int,
        lastCommitHash: String?,
        lastCommitMsg: String?,
        lastCommitAt: String?
    ) {
        self.path = path
        self.name = name
        self.branch = branch
        self.dirtyCount = dirtyCount
        self.untrackedCount = untrackedCount
        self.unpushedCount = unpushedCount
        self.lastCommitHash = lastCommitHash
        self.lastCommitMsg = lastCommitMsg
        self.lastCommitAt = lastCommitAt
    }
}

public enum RepoDiscovery {
    /// Probe every distinct repo root referenced by a session `cwd` and upsert
    /// it into `git_repos`. `session_count` aggregates sessions whose `cwd`
    /// resolves to the same repo top-level. Returns the number of repos written.
    ///
    /// `probe` is injected for testing; the default shells out to `git`.
    @discardableResult
    public static func discover(
        _ db: Database,
        probe: (String) -> GitRepoProbe? = RepoDiscovery.probeGit,
        now: () -> String = { ISO8601DateFormatter().string(from: Date()) }
    ) throws -> Int {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT cwd, COUNT(*) AS n
            FROM sessions
            WHERE cwd IS NOT NULL AND TRIM(cwd) != ''
            GROUP BY cwd
            """
        )

        // Aggregate by resolved repo top-level: many cwds (sub-dirs) can map to
        // one repo. Cache probes per cwd to avoid re-shelling identical paths.
        var byRepo: [String: (probe: GitRepoProbe, sessions: Int)] = [:]
        for row in rows {
            guard let cwd = row["cwd"] as String? else { continue }
            let sessions = (row["n"] as Int?) ?? 0
            guard let info = probe(cwd) else { continue }
            if let existing = byRepo[info.path] {
                byRepo[info.path] = (existing.probe, existing.sessions + sessions)
            } else {
                byRepo[info.path] = (info, sessions)
            }
        }

        let probedAt = now()
        for (_, entry) in byRepo {
            let p = entry.probe
            try db.execute(
                sql: """
                INSERT INTO git_repos(
                  path, name, branch, dirty_count, untracked_count, unpushed_count,
                  last_commit_hash, last_commit_msg, last_commit_at, session_count, probed_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(path) DO UPDATE SET
                  name = excluded.name,
                  branch = excluded.branch,
                  dirty_count = excluded.dirty_count,
                  untracked_count = excluded.untracked_count,
                  unpushed_count = excluded.unpushed_count,
                  last_commit_hash = excluded.last_commit_hash,
                  last_commit_msg = excluded.last_commit_msg,
                  last_commit_at = excluded.last_commit_at,
                  session_count = excluded.session_count,
                  probed_at = excluded.probed_at
                """,
                arguments: [
                    p.path, p.name, p.branch, p.dirtyCount, p.untrackedCount, p.unpushedCount,
                    p.lastCommitHash, p.lastCommitMsg, p.lastCommitAt, entry.sessions, probedAt
                ]
            )
        }
        return byRepo.count
    }

    /// Real git probe. Returns `nil` when `cwd` is not inside a git repo or git
    /// is unavailable — never throws, so a missing tool just yields no repos.
    public static func probeGit(_ cwd: String) -> GitRepoProbe? {
        guard let top = runGit(["rev-parse", "--show-toplevel"], cwd: cwd)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !top.isEmpty
        else { return nil }

        let branchRaw = runGit(["rev-parse", "--abbrev-ref", "HEAD"], cwd: top)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = (branchRaw?.isEmpty == false) ? branchRaw : nil

        var dirty = 0
        var untracked = 0
        if let porcelain = runGit(["status", "--porcelain"], cwd: top) {
            for line in porcelain.split(separator: "\n", omittingEmptySubsequences: true) {
                if line.hasPrefix("??") { untracked += 1 } else { dirty += 1 }
            }
        }

        // Unpushed commits vs upstream; 0 when no upstream is configured.
        let unpushed = runGit(["rev-list", "--count", "@{u}..HEAD"], cwd: top)
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0

        var hash: String?
        var msg: String?
        var at: String?
        // NUL-separated fields so commit messages containing any printable
        // character (including `|`) round-trip safely.
        if let log = runGit(["log", "-1", "--pretty=format:%H%x00%s%x00%aI"], cwd: top) {
            let parts = log.components(separatedBy: "\u{0}")
            if parts.count == 3 {
                hash = parts[0].isEmpty ? nil : parts[0]
                msg = parts[1].isEmpty ? nil : parts[1]
                at = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
                if at?.isEmpty == true { at = nil }
            }
        }

        return GitRepoProbe(
            path: top,
            name: (top as NSString).lastPathComponent,
            branch: branch,
            dirtyCount: dirty,
            untrackedCount: untracked,
            unpushedCount: unpushed,
            lastCommitHash: hash,
            lastCommitMsg: msg,
            lastCommitAt: at
        )
    }

    /// Run `git <args>` in `cwd`. Returns stdout on exit 0, else `nil`.
    private static func runGit(_ args: [String], cwd: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", cwd] + args
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        _ = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
