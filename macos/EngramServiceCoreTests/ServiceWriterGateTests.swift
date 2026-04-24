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
