// macos/EngramCoreTests/ProjectMove/MigrationLockTests.swift
// Mirrors the protocol covered in tests/core/project-move/lock-and-archive.test.ts
// (lock half) plus the round-4 TOCTOU contract: acquire is atomic, stale
// locks are broken, release is owner-bound.
import Darwin
import Foundation
import XCTest
@testable import EngramCoreWrite

final class MigrationLockTests: XCTestCase {
    private var tmpRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("engram-lock-\(UUID().uuidString.prefix(8))", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let tmpRoot {
            try? FileManager.default.removeItem(at: tmpRoot)
        }
        try super.tearDownWithError()
    }

    // MARK: - acquire / release / read

    func testAcquireOnFreshPathSucceeds() throws {
        let lockPath = tmpRoot.appendingPathComponent("a.lock").path
        try MigrationLock.acquire(migrationId: "m-1", lockPath: lockPath)
        defer { MigrationLock.release(lockPath: lockPath) }

        let holder = try XCTUnwrap(MigrationLock.read(lockPath: lockPath))
        XCTAssertEqual(holder.pid, getpid())
        XCTAssertEqual(holder.migrationId, "m-1")
        XCTAssertFalse(holder.startedAt.isEmpty)
    }

    func testReleaseRemovesLockFileWhenOwned() throws {
        let lockPath = tmpRoot.appendingPathComponent("b.lock").path
        try MigrationLock.acquire(migrationId: "m-1", lockPath: lockPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockPath))
        MigrationLock.release(lockPath: lockPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockPath))
    }

    func testReleaseDoesNothingIfPidMismatch() throws {
        let lockPath = tmpRoot.appendingPathComponent("c.lock").path
        try MigrationLock.acquire(migrationId: "m-1", lockPath: lockPath)

        // Rewrite the lock with a different (but still real) pid so release
        // is forced to no-op. PID 1 (launchd) is always alive on macOS.
        let foreign = LockHolder(pid: 1, startedAt: "2026-01-01T00:00:00Z", migrationId: "other")
        let data = try JSONEncoder().encode(foreign)
        try data.write(to: URL(fileURLWithPath: lockPath))

        MigrationLock.release(lockPath: lockPath)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: lockPath),
            "release must not unlink a lock owned by a different pid"
        )
    }

    func testReadReturnsNilWhenAbsent() {
        let lockPath = tmpRoot.appendingPathComponent("missing.lock").path
        XCTAssertNil(MigrationLock.read(lockPath: lockPath))
    }

    // MARK: - busy / stale

    func testAcquireThrowsLockBusyWhenLiveHolderExists() throws {
        let lockPath = tmpRoot.appendingPathComponent("d.lock").path

        // Plant a live holder (current pid) so the second acquire sees a
        // collision against an alive process.
        let live = LockHolder(
            pid: getpid(),
            startedAt: "2026-04-28T00:00:00Z",
            migrationId: "first"
        )
        try FileManager.default.createDirectory(
            atPath: (lockPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(live).write(to: URL(fileURLWithPath: lockPath))

        XCTAssertThrowsError(
            try MigrationLock.acquire(migrationId: "second", lockPath: lockPath)
        ) { error in
            guard let busy = error as? LockBusyError else {
                return XCTFail("expected LockBusyError, got \(error)")
            }
            XCTAssertEqual(busy.holder.migrationId, "first")
            XCTAssertEqual(busy.errorName, "LockBusyError")
            XCTAssertTrue(busy.errorMessage.contains("first"))
        }
    }

    func testAcquireBreaksStaleLockFromDeadPid() throws {
        let lockPath = tmpRoot.appendingPathComponent("e.lock").path

        // Pick a PID we're confident is gone: the pid of a sub-process we
        // just fully reaped. `Process` plus waitUntilExit guarantees the
        // kernel has released the entry by the time we read .processIdentifier.
        let staleProcess = Process()
        staleProcess.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try staleProcess.run()
        staleProcess.waitUntilExit()
        let stalePid = staleProcess.processIdentifier
        XCTAssertGreaterThan(stalePid, 0)

        let stale = LockHolder(
            pid: stalePid,
            startedAt: "2026-04-28T00:00:00Z",
            migrationId: "ghost"
        )
        try FileManager.default.createDirectory(
            atPath: (lockPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(stale).write(to: URL(fileURLWithPath: lockPath))

        try MigrationLock.acquire(migrationId: "fresh", lockPath: lockPath)
        defer { MigrationLock.release(lockPath: lockPath) }

        let holder = try XCTUnwrap(MigrationLock.read(lockPath: lockPath))
        XCTAssertEqual(holder.pid, getpid(), "stale lock must be replaced by us")
        XCTAssertEqual(holder.migrationId, "fresh")
    }

    func testAcquireDoesNotBreakLiveHolderOlderThanTTL() throws {
        let lockPath = tmpRoot.appendingPathComponent("ttl.lock").path
        let oldStart = "2026-04-28T00:00:00.000Z"
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-04-28T02:00:00Z"))
        let liveButOld = LockHolder(pid: 1, startedAt: oldStart, migrationId: "old")
        try FileManager.default.createDirectory(
            atPath: (lockPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(liveButOld).write(to: URL(fileURLWithPath: lockPath))

        XCTAssertThrowsError(
            try MigrationLock.acquire(migrationId: "fresh", lockPath: lockPath, now: now, staleTTL: 60)
        ) { error in
            guard let busy = error as? LockBusyError else {
                return XCTFail("expected LockBusyError, got \(error)")
            }
            XCTAssertEqual(busy.holder.migrationId, "old")
        }
        let holder = try XCTUnwrap(MigrationLock.read(lockPath: lockPath))
        XCTAssertEqual(holder.migrationId, "old", "live holder must keep the lock even after the stale TTL")
    }

    func testAcquireBreaksZombieHolder() throws {
        let lockPath = tmpRoot.appendingPathComponent("zombie.lock").path
        var childPid: pid_t = 0
        let executable = try XCTUnwrap(strdup("/usr/bin/true"))
        var argv: [UnsafeMutablePointer<CChar>?] = [executable, nil]
        defer { free(executable) }
        let spawnResult = posix_spawn(&childPid, executable, nil, nil, &argv, nil)
        if spawnResult != 0 {
            throw XCTSkip("posix_spawn() failed: \(spawnResult)")
        }
        defer {
            var status: Int32 = 0
            waitpid(childPid, &status, 0)
        }
        usleep(50_000)

        let zombie = LockHolder(
            pid: childPid,
            startedAt: "2026-04-28T00:00:00.000Z",
            migrationId: "zombie"
        )
        try FileManager.default.createDirectory(
            atPath: (lockPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(zombie).write(to: URL(fileURLWithPath: lockPath))

        try MigrationLock.acquire(migrationId: "fresh", lockPath: lockPath, staleTTL: 3_600)
        defer { MigrationLock.release(lockPath: lockPath) }

        let holder = try XCTUnwrap(MigrationLock.read(lockPath: lockPath))
        XCTAssertEqual(holder.pid, getpid(), "zombie holder must not keep the lock busy")
        XCTAssertEqual(holder.migrationId, "fresh")
    }

    func testAcquireBreaksCorruptLock() throws {
        let lockPath = tmpRoot.appendingPathComponent("f.lock").path
        try FileManager.default.createDirectory(
            atPath: (lockPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        // Corrupt JSON — must be treated as stale (Node parity).
        try Data("not json".utf8).write(to: URL(fileURLWithPath: lockPath))

        try MigrationLock.acquire(migrationId: "fresh", lockPath: lockPath)
        defer { MigrationLock.release(lockPath: lockPath) }

        let holder = try XCTUnwrap(MigrationLock.read(lockPath: lockPath))
        XCTAssertEqual(holder.pid, getpid())
    }

    // MARK: - LockBusyError contract

    func testLockBusyErrorConformsToProjectMoveError() {
        let busy = LockBusyError(
            holder: LockHolder(pid: 999, startedAt: "T0", migrationId: "x")
        )
        let env = buildErrorEnvelope(busy)
        XCTAssertEqual(env.error.name, "LockBusyError")
        XCTAssertEqual(env.error.retryPolicy, .wait)
    }
}
