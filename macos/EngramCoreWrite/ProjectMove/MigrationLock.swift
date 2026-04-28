// macos/EngramCoreWrite/ProjectMove/MigrationLock.swift
// Mirrors src/core/project-move/lock.ts (Node parity baseline).
//
// Advisory cross-process lock for project-move. The DB-level
// `migration_log` pending guard + per-file CAS are the real safety nets;
// this lock only prevents two concurrent project-move runs from clobbering
// each other's filesystem work.
//
// Protocol:
//   - Lock file: ~/.engram/.project-move.lock
//   - Contents:  JSON { pid, startedAt, migrationId }
//   - Stale detection: if owning pid is gone (kill -0 → ESRCH), break.
//
// Atomicity: open(O_CREAT | O_EXCL) ensures only one process can claim
// the path. Round 4 (Codex blocker #2a) closed a TOCTOU race where two
// processes could both classify the lock "stale" and both overwrite.
import Darwin
import Foundation

public struct LockHolder: Codable, Equatable, Sendable {
    public let pid: Int32
    public let startedAt: String
    public let migrationId: String

    public init(pid: Int32, startedAt: String, migrationId: String) {
        self.pid = pid
        self.startedAt = startedAt
        self.migrationId = migrationId
    }
}

public struct LockBusyError: ProjectMoveError {
    public let holder: LockHolder

    public init(holder: LockHolder) {
        self.holder = holder
    }

    public var errorName: String { "LockBusyError" }
    public var errorMessage: String {
        "project-move is already in progress (pid=\(holder.pid), migration=\(holder.migrationId), started \(holder.startedAt))"
    }
}

public enum MigrationLockError: Error, Equatable {
    case writeFailed(errno: Int32, message: String)
    case openFailed(errno: Int32, message: String)
    case exhaustedAttempts
}

public enum MigrationLock {
    /// Default lock path: `~/.engram/.project-move.lock`.
    public static func defaultLockPath(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        homeDirectory
            .appendingPathComponent(".engram", isDirectory: true)
            .appendingPathComponent(".project-move.lock")
            .path
    }

    /// Try to acquire the lock. Throws `LockBusyError` if a live process
    /// holds it; breaks stale locks (dead PID) and retries once. Other
    /// errors propagate as `MigrationLockError`.
    public static func acquire(
        migrationId: String,
        lockPath: String = defaultLockPath(),
        now: Date = Date()
    ) throws {
        let directory = (lockPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )

        let holder = LockHolder(
            pid: getpid(),
            startedAt: iso8601(now),
            migrationId: migrationId
        )
        let payload = try JSONEncoder().encode(holder)

        // Up to 2 attempts: first try to create, then on EEXIST probe the
        // holder; if alive throw LockBusyError, if stale unlink and retry.
        for _ in 0..<2 {
            switch tryCreate(lockPath: lockPath, payload: payload) {
            case .acquired:
                return
            case .alreadyExists:
                let existing = readHolder(lockPath: lockPath)
                if let existing, isProcessAlive(pid: existing.pid) {
                    throw LockBusyError(holder: existing)
                }
                // Stale (or corrupt) lock — unlink and retry. Ignore ENOENT
                // since another process may have already broken it.
                if unlink(lockPath) != 0 && errno != ENOENT {
                    let code = errno
                    throw MigrationLockError.openFailed(
                        errno: code,
                        message: String(cString: strerror(code))
                    )
                }
            case .failed(let code):
                throw MigrationLockError.openFailed(
                    errno: code,
                    message: String(cString: strerror(code))
                )
            }
        }
        throw MigrationLockError.exhaustedAttempts
    }

    /// Release the lock — only if it's still owned by the current process.
    /// Defensive against races where we already broke a stale lock and the
    /// original PID was reused by an unrelated process.
    public static func release(lockPath: String = defaultLockPath()) {
        guard let holder = readHolder(lockPath: lockPath) else { return }
        if holder.pid != getpid() { return }
        _ = unlink(lockPath)
    }

    /// Read the current lock holder, or `nil` if no lock file exists or
    /// the contents are unreadable.
    public static func read(lockPath: String = defaultLockPath()) -> LockHolder? {
        readHolder(lockPath: lockPath)
    }

    // MARK: - internals

    enum CreateOutcome {
        case acquired
        case alreadyExists
        case failed(errno: Int32)
    }

    private static func tryCreate(lockPath: String, payload: Data) -> CreateOutcome {
        let fd = open(lockPath, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        if fd >= 0 {
            defer { close(fd) }
            let ok = payload.withUnsafeBytes { buf -> Bool in
                guard let base = buf.baseAddress else { return false }
                var written = 0
                while written < buf.count {
                    let n = write(fd, base.advanced(by: written), buf.count - written)
                    if n <= 0 {
                        return false
                    }
                    written += n
                }
                return true
            }
            if !ok {
                _ = unlink(lockPath)
                return .failed(errno: errno)
            }
            return .acquired
        }
        let code = errno
        if code == EEXIST {
            return .alreadyExists
        }
        return .failed(errno: code)
    }

    private static func readHolder(lockPath: String) -> LockHolder? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: lockPath)) else {
            return nil
        }
        return try? JSONDecoder().decode(LockHolder.self, from: data)
    }

    /// `kill(pid, 0)` is a probe; returns 0 if the process exists and we
    /// can signal it, ESRCH if it's gone, EPERM if it exists but we lack
    /// permission. EPERM still implies the process is alive.
    private static func isProcessAlive(pid: Int32) -> Bool {
        if pid == getpid() { return true }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
