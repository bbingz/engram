import XCTest
@testable import EngramServiceCore
import EngramCoreWrite

final class ServiceWriterGateTests: XCTestCase {
    /// Wave 7C M01: pure reads through the gate must not advance databaseGeneration.
    func testPerformReadCommandDoesNotBumpGeneration_repro() async throws {
        let paths = try makeGatePaths()
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)

        let write = try await gate.performWriteCommand(name: "seed") { writer in
            try writer.write { db in
                try db.execute(sql: "CREATE TABLE IF NOT EXISTS t(id INTEGER PRIMARY KEY)")
            }
            return 1
        }
        XCTAssertEqual(write.databaseGeneration, 1)

        let read1 = try await gate.performReadCommand(name: "periodicIndexStatus") { writer in
            try writer.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM t") ?? -1
            }
        }
        XCTAssertEqual(read1.value, 0)
        XCTAssertEqual(read1.databaseGeneration, 1, "read must leave generation unchanged")

        let read2 = try await gate.performReadCommand(name: "remoteSyncStatus") { _ in "ok" }
        XCTAssertEqual(read2.databaseGeneration, 1)
    }

    /// Wave 7C H02: index/FTS/embed phase names are long-running for queue timeout.
    func testIndexAndFtsNamesAreLongRunning_repro() {
        XCTAssertTrue(ServiceWriterGate.isLongRunningWriteCommand("indexRecent"))
        XCTAssertTrue(ServiceWriterGate.isLongRunningWriteCommand("indexArchiveBacklog"))
        XCTAssertTrue(ServiceWriterGate.isLongRunningWriteCommand("initialScanIndex"))
        XCTAssertTrue(ServiceWriterGate.isLongRunningWriteCommand("periodicFtsDrain"))
        XCTAssertTrue(ServiceWriterGate.isLongRunningWriteCommand("embeddingBackfill"))
        XCTAssertTrue(ServiceWriterGate.isLongRunningWriteCommand("projectMove"))
        XCTAssertFalse(ServiceWriterGate.isLongRunningWriteCommand("saveInsight"))
    }

    // CONC-001: every startup phase that can hold the writer for healthy
    // multi-second work must use the long-running queue policy.
    func testStartupMaintenanceNamesAreLongRunning_repro() {
        for name in [
            "initialInstructionBackfill",
            "initialImplementationBeatBackfill",
            "initialFtsDrain",
        ] {
            XCTAssertTrue(
                ServiceWriterGate.isLongRunningWriteCommand(name),
                "\(name) must not false-timeout queued followers"
            )
        }
    }

    // CONC-001: exercise the actual queue behavior, not only name classification.
    func testFollowerBehindInitialFtsDrainDoesNotTimeout_repro() async throws {
        let paths = try makeGatePaths()
        let gate = try ServiceWriterGate(
            databasePath: paths.database.path,
            runtimeDirectory: paths.runtime,
            queueTimeoutNanoseconds: 20_000_000
        )
        let probe = CancellationProbe()

        let drain = Task {
            try await gate.performWriteCommand(name: "initialFtsDrain") { _ in
                await probe.markFirstStarted()
                await probe.waitUntilRelease()
                return "drained"
            }
        }
        await probe.waitUntilFirstStarted()

        let follower = Task {
            try await gate.performWriteCommand(name: "saveInsight") { _ in "saved" }
        }
        while await gate.queuedWriteWaiterCountForTesting() < 1 {
            await Task.yield()
        }
        try await Task.sleep(nanoseconds: 80_000_000)
        await probe.releaseFirst()

        let drainResult = try await drain.value
        let followerResult = try await follower.value
        XCTAssertEqual(drainResult.value, "drained")
        XCTAssertEqual(followerResult.value, "saved")
    }

    /// M1 hang fix: a long-running command blocked by a short holder must still
    /// arm the queue timeout (WriterBusy), not hang on timeout=nil forever.
    func testLongRunningCommandBlockedByShortHolderStillTimesOut_repro() async throws {
        let paths = try makeGatePaths()
        let gate = try ServiceWriterGate(
            databasePath: paths.database.path,
            runtimeDirectory: paths.runtime,
            queueTimeoutNanoseconds: 80_000_000
        )
        let hold = CancellationProbe()
        let holderEntered = expectation(description: "short holder entered")
        let holdTask = Task {
            _ = try await gate.performWriteCommand(name: "saveInsight") { _ in
                holderEntered.fulfill()
                await hold.waitUntilRelease()
                return "held"
            }
        }
        await fulfillment(of: [holderEntered], timeout: 5)

        do {
            _ = try await gate.performWriteCommand(name: "projectMove") { _ in
                "should-not-run"
            }
            XCTFail("projectMove must WriterBusy when blocked by short holder")
        } catch let error as EngramServiceError {
            guard case .writerBusy = error else {
                return XCTFail("expected writerBusy, got \(error)")
            }
        } catch {
            return XCTFail("expected EngramServiceError.writerBusy, got \(error)")
        }

        await hold.releaseFirst()
        _ = try await holdTask.value
    }

    func testFirstGateAcquiresLockAndConstructsOneWriter() async throws {
        let paths = try makeGatePaths()
        let factory = CountingWriterFactory()

        let gate = try ServiceWriterGate(
            databasePath: paths.database.path,
            runtimeDirectory: paths.runtime,
            writerFactory: { path in try factory.makeWriter(path: path) }
        )
        let result = try await gate.performWriteCommand(name: "create_table") { writer in
            try writer.write { db in
                try db.execute(sql: "CREATE TABLE IF NOT EXISTS gate_test(id INTEGER PRIMARY KEY)")
            }
            return "created"
        }

        XCTAssertEqual(result.value, "created")
        XCTAssertEqual(result.databaseGeneration, 1)
        XCTAssertEqual(factory.count, 1)
    }

    func testSecondGateFailsWithWriterBusy() throws {
        let paths = try makeGatePaths()
        let first = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        _ = first

        XCTAssertThrowsError(try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)) { error in
            guard case EngramServiceError.writerBusy = error else {
                return XCTFail("Expected writerBusy, got \(error)")
            }
        }
    }

    func testGlobalDatabaseLockRejectsSecondRuntimeDirectory() throws {
        let first = try makeGatePaths()
        let second = try makeGatePaths()
        let firstGate = try ServiceWriterGate(databasePath: first.database.path, runtimeDirectory: first.runtime)
        _ = firstGate

        XCTAssertThrowsError(try ServiceWriterGate(databasePath: first.database.path, runtimeDirectory: second.runtime)) { error in
            guard case EngramServiceError.writerBusy = error else {
                return XCTFail("Expected writerBusy, got \(error)")
            }
        }
    }

    func testCheckpointTruncateShrinksWalAfterPendingWrites() async throws {
        let paths = try makeGatePaths()
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let walPath = paths.database.path + "-wal"
        let fileManager = FileManager.default

        // Create a table and insert enough rows to grow the WAL.
        _ = try await gate.performWriteCommand(name: "seed_table") { writer in
            try writer.write { db in
                try db.execute(sql: "CREATE TABLE IF NOT EXISTS payload(id INTEGER PRIMARY KEY, data BLOB)")
            }
        }
        for batch in 0..<8 {
            _ = try await gate.performWriteCommand(name: "seed_rows_\(batch)") { writer in
                try writer.write { db in
                    for i in 0..<200 {
                        try db.execute(
                            sql: "INSERT INTO payload(data) VALUES (?)",
                            arguments: [Data(repeating: UInt8(i & 0xff), count: 4096)]
                        )
                    }
                }
            }
        }

        // PASSIVE alone should leave the WAL file size > 0.
        try await gate.checkpointWal()
        let walSizeAfterPassive = try Self.fileSize(walPath, fileManager: fileManager)
        XCTAssertGreaterThan(walSizeAfterPassive, 0, "PASSIVE checkpoint must not shrink WAL file")

        // TRUNCATE should bring it down to 0.
        let result = try await gate.checkpointTruncate()
        XCTAssertEqual(result.busy, 0, "no concurrent reader, truncate must succeed")
        let walSizeAfterTruncate = try Self.fileSize(walPath, fileManager: fileManager)
        XCTAssertEqual(walSizeAfterTruncate, 0, "TRUNCATE must shrink WAL file to 0 bytes")
    }

    func testIndexStatusUsesCacheWithinSameGenerationAndExpiresAfterTTL() async throws {
        let paths = try makeGatePaths()
        let clock = ManualDateProvider(Date(timeIntervalSince1970: 1_700_000_000))
        let gate = try ServiceWriterGate(
            databasePath: paths.database.path,
            runtimeDirectory: paths.runtime,
            indexStatusCacheTTL: 30,
            now: clock.now
        )
        let startTime = ISO8601DateFormatter().string(from: clock.now())

        _ = try await gate.performWriteCommand(name: "seed_sessions") { writer in
            try writer.write { db in
                try db.execute(sql: """
                    CREATE TABLE sessions(
                        id TEXT PRIMARY KEY,
                        hidden_at TEXT,
                        parent_session_id TEXT,
                        suggested_parent_id TEXT,
                        tier TEXT,
                        start_time TEXT NOT NULL
                    )
                    """)
                try db.execute(
                    sql: "INSERT INTO sessions(id, start_time) VALUES ('s1', ?)",
                    arguments: [startTime]
                )
            }
        }

        let first = try await gate.indexStatus()
        XCTAssertEqual(first.total, 1)

        let bypassWriter = try EngramDatabaseWriter(path: paths.database.path)
        try bypassWriter.write { db in
            try db.execute(
                sql: "INSERT INTO sessions(id, start_time) VALUES ('s2', ?)",
                arguments: [startTime]
            )
        }

        let cached = try await gate.indexStatus()
        XCTAssertEqual(cached.total, 1)

        clock.advance(by: 29)
        let stillCached = try await gate.indexStatus()
        XCTAssertEqual(stillCached.total, 1, "cache must still serve within the TTL window")

        // Reaching exactly the TTL boundary must expire the cache (strict `<`):
        // a `<=` off-by-one regression would keep serving the stale count here.
        clock.advance(by: 1)
        let refreshed = try await gate.indexStatus()
        XCTAssertEqual(refreshed.total, 2)
    }

    func testIndexStatusCacheInvalidatesAfterGateWrite() async throws {
        let paths = try makeGatePaths()
        let clock = ManualDateProvider(Date(timeIntervalSince1970: 1_700_000_000))
        let gate = try ServiceWriterGate(
            databasePath: paths.database.path,
            runtimeDirectory: paths.runtime,
            indexStatusCacheTTL: 30,
            now: clock.now
        )
        let startTime = ISO8601DateFormatter().string(from: clock.now())

        _ = try await gate.performWriteCommand(name: "seed_sessions") { writer in
            try writer.write { db in
                try db.execute(sql: """
                    CREATE TABLE sessions(
                        id TEXT PRIMARY KEY,
                        hidden_at TEXT,
                        parent_session_id TEXT,
                        suggested_parent_id TEXT,
                        tier TEXT,
                        start_time TEXT NOT NULL
                    )
                    """)
                try db.execute(
                    sql: "INSERT INTO sessions(id, start_time) VALUES ('s1', ?)",
                    arguments: [startTime]
                )
            }
        }
        let cachedBeforeWrite = try await gate.indexStatus()
        XCTAssertEqual(cachedBeforeWrite.total, 1)

        _ = try await gate.performWriteCommand(name: "insert_session") { writer in
            try writer.write { db in
                try db.execute(
                    sql: "INSERT INTO sessions(id, start_time) VALUES ('s2', ?)",
                    arguments: [startTime]
                )
            }
        }

        let refreshedAfterWrite = try await gate.indexStatus()
        XCTAssertEqual(refreshedAfterWrite.total, 2)
    }

    func testIndexStatusBypassesCacheDuringInFlightWrite() async throws {
        let paths = try makeGatePaths()
        let clock = ManualDateProvider(Date(timeIntervalSince1970: 1_700_000_000))
        let gate = try ServiceWriterGate(
            databasePath: paths.database.path,
            runtimeDirectory: paths.runtime,
            indexStatusCacheTTL: 30,
            now: clock.now
        )
        let startTime = ISO8601DateFormatter().string(from: clock.now())
        let probe = CancellationProbe()

        _ = try await gate.performWriteCommand(name: "seed_sessions") { writer in
            try writer.write { db in
                try db.execute(sql: """
                    CREATE TABLE sessions(
                        id TEXT PRIMARY KEY,
                        hidden_at TEXT,
                        parent_session_id TEXT,
                        suggested_parent_id TEXT,
                        tier TEXT,
                        start_time TEXT NOT NULL
                    )
                    """)
                try db.execute(
                    sql: "INSERT INTO sessions(id, start_time) VALUES ('s1', ?)",
                    arguments: [startTime]
                )
            }
        }
        let cachedBeforeWrite = try await gate.indexStatus()
        XCTAssertEqual(cachedBeforeWrite.total, 1)

        let inFlightWrite = Task {
            try await gate.performWriteCommand(name: "inflight_insert") { writer in
                try writer.write { db in
                    try db.execute(
                        sql: "INSERT INTO sessions(id, start_time) VALUES ('s2', ?)",
                        arguments: [startTime]
                    )
                }
                await probe.markFirstStarted()
                await probe.waitUntilRelease()
                return "inserted"
            }
        }
        await probe.waitUntilFirstStarted()

        let duringWrite = try await gate.indexStatus()
        XCTAssertEqual(duringWrite.total, 2)

        await probe.releaseFirst()
        _ = try await inFlightWrite.value
    }

    func testIndexStatusCacheInvalidatesWhenWriteMutatesThenThrows() async throws {
        let paths = try makeGatePaths()
        let clock = ManualDateProvider(Date(timeIntervalSince1970: 1_700_000_000))
        let gate = try ServiceWriterGate(
            databasePath: paths.database.path,
            runtimeDirectory: paths.runtime,
            indexStatusCacheTTL: 30,
            now: clock.now
        )
        let startTime = ISO8601DateFormatter().string(from: clock.now())

        _ = try await gate.performWriteCommand(name: "seed_sessions") { writer in
            try writer.write { db in
                try db.execute(sql: """
                    CREATE TABLE sessions(
                        id TEXT PRIMARY KEY,
                        hidden_at TEXT,
                        parent_session_id TEXT,
                        suggested_parent_id TEXT,
                        tier TEXT,
                        start_time TEXT NOT NULL
                    )
                    """)
                try db.execute(
                    sql: "INSERT INTO sessions(id, start_time) VALUES ('s1', ?)",
                    arguments: [startTime]
                )
            }
        }
        let cachedBeforeWrite = try await gate.indexStatus()
        XCTAssertEqual(cachedBeforeWrite.total, 1)

        do {
            _ = try await gate.performWriteCommand(name: "mutate_then_throw") { writer in
                try writer.write { db in
                    try db.execute(
                        sql: "INSERT INTO sessions(id, start_time) VALUES ('s2', ?)",
                        arguments: [startTime]
                    )
                }
                throw EngramServiceError.serviceUnavailable(message: "simulated failure after mutation")
            }
            XCTFail("mutate_then_throw should fail")
        } catch let error as EngramServiceError {
            guard case .serviceUnavailable = error else {
                return XCTFail("expected serviceUnavailable, got \(error)")
            }
        }

        let refreshedAfterFailure = try await gate.indexStatus()
        XCTAssertEqual(refreshedAfterFailure.total, 2)
    }

    private static func fileSize(_ path: String, fileManager: FileManager) throws -> UInt64 {
        let attrs = try fileManager.attributesOfItem(atPath: path)
        return (attrs[.size] as? UInt64) ?? 0
    }

    func testConcurrentWriteCommandsExecuteSerially() async throws {
        let paths = try makeGatePaths()
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let probe = SerializationProbe()

        async let first = gate.performWriteCommand(name: "first") { _ in
            await probe.enter()
            try await Task.sleep(nanoseconds: 20_000_000)
            await probe.leave()
            return "first"
        }
        async let second = gate.performWriteCommand(name: "second") { _ in
            await probe.enter()
            await probe.leave()
            return "second"
        }

        _ = try await [first.value, second.value]
        let maximumActive = await probe.maximumActive
        XCTAssertEqual(maximumActive, 1)
    }

    func testCancelledQueuedWriteCommandDoesNotExecuteLater() async throws {
        let paths = try makeGatePaths()
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let probe = CancellationProbe()

        let first = Task {
            try await gate.performWriteCommand(name: "first") { _ in
                await probe.markFirstStarted()
                await probe.waitUntilRelease()
                return "first"
            }
        }
        await probe.waitUntilFirstStarted()

        let queued = Task {
            try await gate.performWriteCommand(name: "queued") { _ in
                await probe.markQueuedOperationRan()
                return "queued"
            }
        }
        while await gate.queuedWriteWaiterCountForTesting() == 0 {
            await Task.yield()
        }
        queued.cancel()
        await probe.releaseFirst()

        let firstResult = try await first.value
        XCTAssertEqual(firstResult.databaseGeneration, 1)

        do {
            _ = try await queued.value
            XCTFail("cancelled queued write should not complete successfully")
        } catch is CancellationError {
            // Expected.
        }

        let queuedOperationRan = await probe.queuedOperationRan
        XCTAssertFalse(queuedOperationRan)

        let third = try await gate.performWriteCommand(name: "third") { _ in
            "third"
        }
        XCTAssertEqual(third.databaseGeneration, 2)
    }
    func testQueuedWriteTimesOutWhenHolderIsWedged() async throws {
        // R5-20: a stuck holder must not wedge queued writes forever. With a
        // short queue timeout, a second write that can't acquire the gate
        // throws writerBusy instead of blocking indefinitely.
        let paths = try makeGatePaths()
        let gate = try ServiceWriterGate(
            databasePath: paths.database.path,
            runtimeDirectory: paths.runtime,
            queueTimeoutNanoseconds: 50_000_000
        )
        let probe = CancellationProbe()

        // Holder enters and never returns until released — simulates a wedged
        // SQLite/NFS write.
        let holder = Task {
            try await gate.performWriteCommand(name: "holder") { _ in
                await probe.markFirstStarted()
                await probe.waitUntilRelease()
                return "holder"
            }
        }
        await probe.waitUntilFirstStarted()

        // Queued write should time out rather than hang forever.
        do {
            _ = try await gate.performWriteCommand(name: "queued") { _ in "queued" }
            XCTFail("queued write should have timed out while holder was wedged")
        } catch let error as EngramServiceError {
            guard case .writerBusy = error else {
                return XCTFail("expected writerBusy, got \(error)")
            }
        }

        // Releasing the holder lets the gate recover for subsequent writes.
        await probe.releaseFirst()
        _ = try await holder.value
        let after = try await gate.performWriteCommand(name: "after") { _ in "after" }
        XCTAssertEqual(after.value, "after")
    }

    func testQueuedWriteSucceedsWhenHolderFinishesBeforeTimeout() async throws {
        // Guard against false-positive timeouts: a normal queued write that
        // waits less than the timeout still completes.
        let paths = try makeGatePaths()
        let gate = try ServiceWriterGate(
            databasePath: paths.database.path,
            runtimeDirectory: paths.runtime,
            queueTimeoutNanoseconds: 2_000_000_000
        )

        async let first = gate.performWriteCommand(name: "first") { _ in
            try await Task.sleep(nanoseconds: 30_000_000)
            return "first"
        }
        async let second = gate.performWriteCommand(name: "second") { _ in "second" }

        let results = try await [first.value, second.value]
        XCTAssertEqual(Set(results), ["first", "second"])
    }

    func testQueuedWriteWaitsBehindUserDataBackupWithoutTimeout() async throws {
        let paths = try makeGatePaths()
        let gate = try ServiceWriterGate(
            databasePath: paths.database.path,
            runtimeDirectory: paths.runtime,
            queueTimeoutNanoseconds: 20_000_000
        )
        let probe = CancellationProbe()

        let backup = Task {
            try await gate.performWriteCommand(name: "userDataBackup") { _ in
                await probe.markFirstStarted()
                await probe.waitUntilRelease()
                return "backup"
            }
        }
        await probe.waitUntilFirstStarted()

        let queued = Task {
            try await gate.performWriteCommand(name: "queued") { _ in
                await probe.markQueuedOperationRan()
                return "queued"
            }
        }

        try await Task.sleep(nanoseconds: 80_000_000)
        let ranBeforeRelease = await probe.queuedOperationRan
        XCTAssertFalse(ranBeforeRelease)
        await probe.releaseFirst()

        let backupResult = try await backup.value
        let queuedResult = try await queued.value
        XCTAssertEqual(backupResult.value, "backup")
        XCTAssertEqual(queuedResult.value, "queued")
        let ranAfterRelease = await probe.queuedOperationRan
        XCTAssertTrue(ranAfterRelease)
    }

    /// M1: a follower enqueued behind a *queued* (not yet holding) long write must
    /// not arm the 60s timeout — otherwise it false-writerBusy while the migration
    /// is still legitimately waiting, then holding, for minutes.
    func testFollowerBehindQueuedLongWriteDoesNotTimeout_repro() async throws {
        let paths = try makeGatePaths()
        let gate = try ServiceWriterGate(
            databasePath: paths.database.path,
            runtimeDirectory: paths.runtime,
            queueTimeoutNanoseconds: 30_000_000 // 30ms
        )
        let probe = CancellationProbe()

        // Long-running holder occupies the gate (projectMove in progress).
        // Short followers must not arm the 30ms queue timeout behind it (M1).
        let holder = Task {
            try await gate.performWriteCommand(name: "projectMove") { _ in
                await probe.markFirstStarted()
                // Hold past the short queue timeout so a wrongly-armed follower
                // would surface writerBusy.
                try await Task.sleep(nanoseconds: 80_000_000)
                await probe.waitUntilRelease()
                return "move"
            }
        }
        await probe.waitUntilFirstStarted()

        let follower = Task {
            try await gate.performWriteCommand(name: "saveInsight") { _ in "ok" }
        }
        while await gate.queuedWriteWaiterCountForTesting() < 1 {
            await Task.yield()
        }

        // Exceed the short timeout while follower remains queued behind long hold.
        try await Task.sleep(nanoseconds: 50_000_000)
        await probe.releaseFirst()

        let holderResult = try await holder.value
        let followerResult = try await follower.value
        XCTAssertEqual(holderResult.value, "move")
        XCTAssertEqual(
            followerResult.value,
            "ok",
            "M1: follower behind active long write must wait unbounded, not false writerBusy"
        )
    }

    // MARK: - permit-leak race (audit round 2: grdb_txn-1)

    /// When signal() hands a permit to a waiter whose owning task has just been
    /// cancelled, wait() must still RELEASE that permit before surfacing
    /// cancellation. The original code threw at the post-resume
    /// `Task.checkCancellation()` without releasing, permanently leaking the
    /// single writer's permit and wedging every later write with WriterBusy.
    /// Drives the race repeatedly and fails the first round a leak is observed.
    func testSemaphoreReleasesPermitWhenWaiterCancelledAfterSignal() async throws {
        for round in 0..<200 {
            let sem = ServiceAsyncSemaphore(value: 0)
            let waiter = Task { try await sem.wait() }
            // Deterministically wait until the waiter is queued on the continuation.
            while await sem.waiterCount == 0 { await Task.yield() }
            // Arm cancellation, then hand the permit over. If signal() dequeues
            // the now-cancelled waiter, wait() resumes normally and then observes
            // cancellation — the exact window that leaked the permit.
            waiter.cancel()
            await sem.signal()
            _ = try? await waiter.value
            // Leak detector: the permit must be back. A fresh acquire with a
            // timeout must succeed; a leaked permit makes it time out.
            do {
                try await sem.wait(timeoutNanoseconds: 1_000_000_000)
            } catch {
                XCTFail("permit leaked at round \(round): fresh acquire failed with \(error)")
                return
            }
        }
    }
}

private final class CountingWriterFactory {
    private(set) var count = 0

    func makeWriter(path: String) throws -> EngramDatabaseWriter {
        count += 1
        return try EngramDatabaseWriter(path: path)
    }
}

final class ManualDateProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(interval)
        lock.unlock()
    }
}

private actor SerializationProbe {
    private var active = 0
    private var maxActive = 0

    var maximumActive: Int { maxActive }

    func enter() {
        active += 1
        maxActive = max(maxActive, active)
    }

    func leave() {
        active -= 1
    }
}

private actor CancellationProbe {
    private var firstStarted = false
    private var firstStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var queuedRan = false

    var queuedOperationRan: Bool { queuedRan }

    func markFirstStarted() {
        firstStarted = true
        let waiters = firstStartWaiters
        firstStartWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitUntilFirstStarted() async {
        guard !firstStarted else { return }
        await withCheckedContinuation { continuation in
            firstStartWaiters.append(continuation)
        }
    }

    func waitUntilRelease() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func releaseFirst() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func markQueuedOperationRan() {
        queuedRan = true
    }
}

private func makeGatePaths() throws -> (runtime: URL, database: URL) {
    let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent("engram-gate-\(UUID().uuidString.prefix(8))", isDirectory: true)
    let runtime = root.appendingPathComponent("run", isDirectory: true)
    try FileManager.default.createDirectory(
        at: runtime,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    return (runtime, root.appendingPathComponent("gate.sqlite"))
}
