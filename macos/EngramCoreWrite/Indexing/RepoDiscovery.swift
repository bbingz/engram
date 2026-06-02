// macos/EngramCoreWrite/Indexing/RepoDiscovery.swift
// Populates `git_repos` from the distinct `cwd`s referenced by sessions.
//
// Replaces the removed Node `src/core/git-probe.ts`. The old probe parsed
// `git log --format=%H|%s|%aI`, which corrupts on commit messages containing
// `|`; this implementation uses a NUL (`%x00`) field separator and never `|`.
import Darwin
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

public struct GitRepoCandidate: Equatable, Sendable {
    public let cwd: String
    public let sessionCount: Int

    public init(cwd: String, sessionCount: Int) {
        self.cwd = cwd
        self.sessionCount = sessionCount
    }
}

public struct GitRepoDiscoveryEntry: Equatable, Sendable {
    public let probe: GitRepoProbe
    public let sessionCount: Int

    public init(probe: GitRepoProbe, sessionCount: Int) {
        self.probe = probe
        self.sessionCount = sessionCount
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
        probe: (String) -> GitRepoProbe? = { RepoDiscovery.probeGit($0) },
        now: () -> String = { ISO8601DateFormatter().string(from: Date()) }
    ) throws -> Int {
        let candidates = try sessionCwdCounts(db)
        let entries = probeRepositories(candidates, probe: probe)
        return try upsert(db, entries: entries, probedAt: now())
    }

    /// Distinct session cwds to probe, capped to the `limit` busiest. Each
    /// candidate shells out to several `git` subprocesses, and this runs every
    /// indexing cycle, so an unbounded list of one-off cwds (temp dirs, etc.)
    /// would fan out unboundedly. The long tail beyond the busiest repos is not
    /// worth re-probing every cycle.
    public static func sessionCwdCounts(_ db: Database, limit: Int = 200) throws -> [GitRepoCandidate] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT cwd, COUNT(*) AS n
            FROM sessions
            WHERE cwd IS NOT NULL AND TRIM(cwd) != ''
            GROUP BY cwd
            ORDER BY n DESC
            LIMIT ?
            """,
            arguments: [limit]
        )

        return rows.compactMap { row in
            guard let cwd = row["cwd"] as String? else { return nil }
            return GitRepoCandidate(cwd: cwd, sessionCount: (row["n"] as Int?) ?? 0)
        }
    }

    public static func probeRepositories(
        _ candidates: [GitRepoCandidate],
        probe: (String) -> GitRepoProbe? = { RepoDiscovery.probeGit($0) }
    ) -> [GitRepoDiscoveryEntry] {
        // Aggregate by resolved repo top-level: many cwds (sub-dirs) can map to
        // one repo. Cache probes per cwd to avoid re-shelling identical paths.
        var byRepo: [String: (probe: GitRepoProbe, sessions: Int)] = [:]
        for candidate in candidates {
            guard let info = probe(candidate.cwd) else { continue }
            if let existing = byRepo[info.path] {
                byRepo[info.path] = (existing.probe, existing.sessions + candidate.sessionCount)
            } else {
                byRepo[info.path] = (info, candidate.sessionCount)
            }
        }

        return byRepo.values.map { entry in
            GitRepoDiscoveryEntry(probe: entry.probe, sessionCount: entry.sessions)
        }
    }

    @discardableResult
    public static func upsert(
        _ db: Database,
        entries: [GitRepoDiscoveryEntry],
        probedAt: String
    ) throws -> Int {
        for entry in entries {
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
                    p.lastCommitHash, p.lastCommitMsg, p.lastCommitAt, entry.sessionCount, probedAt
                ]
            )
        }
        return entries.count
    }

    /// Real git probe. Returns `nil` when `cwd` is not inside a git repo or git
    /// is unavailable — never throws, so a missing tool just yields no repos.
    public static func probeGit(_ cwd: String, timeoutSeconds: TimeInterval = 3) -> GitRepoProbe? {
        guard let top = runGit(["rev-parse", "--show-toplevel"], cwd: cwd, timeoutSeconds: timeoutSeconds)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !top.isEmpty
        else { return nil }

        let branchRaw = runGit(["rev-parse", "--abbrev-ref", "HEAD"], cwd: top, timeoutSeconds: timeoutSeconds)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = (branchRaw?.isEmpty == false) ? branchRaw : nil

        var dirty = 0
        var untracked = 0
        if let porcelain = runGit(["status", "--porcelain"], cwd: top, timeoutSeconds: timeoutSeconds) {
            for line in porcelain.split(separator: "\n", omittingEmptySubsequences: true) {
                if line.hasPrefix("??") { untracked += 1 } else { dirty += 1 }
            }
        }

        // Unpushed commits vs upstream; 0 when no upstream is configured.
        let unpushed = runGit(["rev-list", "--count", "@{u}..HEAD"], cwd: top, timeoutSeconds: timeoutSeconds)
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0

        var hash: String?
        var msg: String?
        var at: String?
        // NUL-separated fields so commit messages containing any printable
        // character (including `|`) round-trip safely.
        if let log = runGit(["log", "-1", "--pretty=format:%H%x00%s%x00%aI"], cwd: top, timeoutSeconds: timeoutSeconds) {
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
    static func runGit(
        _ args: [String],
        cwd: String,
        timeoutSeconds: TimeInterval = 3,
        environment: [String: String]? = nil
    ) -> String? {
        guard timeoutSeconds > 0 else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", cwd] + args
        process.environment = environment
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        // Drain both pipes CONCURRENTLY with the process. The OS pipe buffer is
        // ~64KB; reading only after the process exits deadlocks once git writes
        // more than that (git blocks on write(), the termination handler never
        // fires, the wait times out, and the repo is silently skipped).
        let ioGroup = DispatchGroup()
        let ioQueue = DispatchQueue(label: "com.engram.repo-discovery.git-io", attributes: .concurrent)
        var outData = Data()
        ioQueue.async(group: ioGroup) { outData = out.fileHandleForReading.readDataToEndOfFile() }
        ioQueue.async(group: ioGroup) { _ = err.fileHandleForReading.readDataToEndOfFile() }
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        guard finished.wait(timeout: .now() + timeoutSeconds) == .success else {
            process.terminate() // SIGTERM
            if finished.wait(timeout: .now() + 1) != .success {
                // git ignored SIGTERM (e.g. blocked on a credential prompt).
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
            // Killing the child does NOT guarantee the drain reaches EOF: a
            // grandchild (credential helper, pager, an orphaned `sleep`) can
            // keep the inherited pipe write end open. We never read the captured
            // output on the timeout path, so bound the drain and abandon it
            // rather than block the caller (the indexing loop) until that
            // grandchild exits.
            _ = ioGroup.wait(timeout: .now() + 1)
            return nil
        }
        // No post-success elapsed recheck: the process exited within the
        // termination-handler timeout, so a slow-but-successful run keeps its
        // output instead of being discarded by a race against the wall clock.
        ioGroup.wait() // process exited -> both reads have reached EOF
        guard process.terminationStatus == 0 else { return nil }
        return String(data: outData, encoding: .utf8)
    }
}
