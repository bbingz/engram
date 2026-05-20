import XCTest
@testable import EngramServiceCore
import EngramCoreWrite

final class ServiceWriterGateTests: XCTestCase {
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
        try await Task.sleep(nanoseconds: 20_000_000)
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
}

private final class CountingWriterFactory {
    private(set) var count = 0

    func makeWriter(path: String) throws -> EngramDatabaseWriter {
        count += 1
        return try EngramDatabaseWriter(path: path)
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
