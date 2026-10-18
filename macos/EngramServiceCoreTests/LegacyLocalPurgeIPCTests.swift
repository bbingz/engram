import CryptoKit
import EngramCoreRead
import EngramCoreWrite
import Foundation
import GRDB
import XCTest
@testable import EngramServiceCore

/// D7 (docs/TODO.md) operator surface; docs/invariants.md "Legacy Local-Origin
/// Purge Is An Explicit Operator Action".
final class LegacyLocalPurgeIPCTests: XCTestCase {
    private static let captureID = "remote:capture-v1.M.I:Z3Jvaw"

    func testLegacyLocalPurgeCommandsAreCapabilityProtectedAndApplyIsLongRunning() {
        XCTAssertTrue(ServiceCapabilityToken.requiresToken("legacyLocalPurgePreview"))
        XCTAssertTrue(ServiceCapabilityToken.requiresToken("legacyLocalPurgeApply"))
        XCTAssertTrue(ServiceWriterGate.isLongRunningWriteCommand("legacyLocalPurgeApply"))
        XCTAssertFalse(ServiceWriterGate.isLongRunningWriteCommand("legacyLocalPurgePreview"))
    }

    func testLegacyLocalPurgeRefusesOutsideIndexRole() async throws {
        let runtime = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: runtime) }
        let gate = try makeSeededGate(runtime)
        let token = String(repeating: "a", count: 64)
        let handlers = [
            EngramServiceCommandHandler(writerGate: gate),
            EngramServiceCommandHandler(writerGate: gate, runtimeRole: .local),
            EngramServiceCommandHandler(writerGate: gate, runtimeRole: .collector),
            EngramServiceCommandHandler(writerGate: gate, runtimeRole: .replica),
            EngramServiceCommandHandler(writerGate: gate, runtimeRole: .invalidSettings),
        ]
        for handler in handlers {
            let preview = await handler.handle(EngramServiceRequestEnvelope(command: "legacyLocalPurgePreview"))
            assertInvalidRequest(preview, contains: "requires runtimeRole index")
            let apply = await handler.handle(try applyEnvelope(sessions: 2, token: token))
            assertInvalidRequest(apply, contains: "requires runtimeRole index")
        }
        let ids = try await sessionIDs(gate)
        XCTAssertEqual(ids, ["grok-a", "pi-a", Self.captureID].sorted())
    }

    /// D7 repro: the purge reaches the index database only through the
    /// service writer gate, bound to the previewed plan.
    func testLegacyLocalPurgePreviewThenApplyThroughWriterGate_repro() async throws {
        let runtime = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: runtime) }
        let gate = try makeSeededGate(runtime)
        let handler = EngramServiceCommandHandler(writerGate: gate, runtimeRole: .index)

        let generationBefore = try await gate.performReadCommand(name: "probe") { _ in 0 }.databaseGeneration
        let previewEnvelope = await handler.handle(EngramServiceRequestEnvelope(command: "legacyLocalPurgePreview"))
        guard case .success(_, let previewData, let previewGeneration) = previewEnvelope else {
            return XCTFail("expected preview success: \(previewEnvelope)")
        }
        XCTAssertEqual(previewGeneration, generationBefore)
        let preview = try JSONDecoder().decode(EngramServiceLegacyLocalPurgePreviewResponse.self, from: previewData)
        XCTAssertEqual(preview.sessionCount, 2)
        XCTAssertEqual(preview.planToken, Self.token(["grok-a", "pi-a"]))
        XCTAssertEqual(preview.derived["sessionsFts"], 2)
        XCTAssertTrue(preview.purgeAllowed)

        let applyResponse = await handler.handle(
            try applyEnvelope(sessions: preview.sessionCount, token: preview.planToken)
        )
        guard case .success(_, let applyData, let applyGeneration) = applyResponse else {
            return XCTFail("expected apply success: \(applyResponse)")
        }
        XCTAssertEqual(applyGeneration, generationBefore + 1)
        let applied = try JSONDecoder().decode(EngramServiceLegacyLocalPurgeApplyResponse.self, from: applyData)
        XCTAssertEqual(applied.sessionsDeleted, 2)
        XCTAssertEqual(applied.deleted["sessionsFts"], 2)
        XCTAssertEqual(applied.planToken, preview.planToken)
        XCTAssertTrue(applied.auditKey.hasPrefix("legacy_local_purge.v1."))
        let ids = try await sessionIDs(gate)
        XCTAssertEqual(ids, [Self.captureID])
        let remaining = try await gate.performReadCommand(name: "probe") { writer in
            try writer.read { db in
                (
                    try String.fetchAll(db, sql: "SELECT session_id FROM sessions_fts ORDER BY session_id"),
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM metadata WHERE key = ?", arguments: [applied.auditKey]) ?? 0
                )
            }
        }.value
        XCTAssertEqual(remaining.0, [Self.captureID])
        XCTAssertEqual(remaining.1, 1)

        let replay = await handler.handle(try applyEnvelope(sessions: preview.sessionCount, token: preview.planToken))
        assertInvalidRequest(replay, contains: "plan changed")
    }

    func testLegacyLocalPurgeApplyRejectsMalformedPayload() async throws {
        let runtime = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: runtime) }
        let gate = try makeSeededGate(runtime)
        let handler = EngramServiceCommandHandler(writerGate: gate, runtimeRole: .index)
        let token = Self.token(["grok-a", "pi-a"])
        let payloads: [[String: Any]] = [
            ["expectedSessionCount": 2, "expectedPlanToken": token, "force": true],
            ["expectedSessionCount": 2],
            ["expectedPlanToken": token],
            ["expectedSessionCount": 2, "expectedPlanToken": token.uppercased()],
            ["expectedSessionCount": 2, "expectedPlanToken": String(token.prefix(63))],
            ["expectedSessionCount": 0, "expectedPlanToken": token],
            ["expectedSessionCount": "2", "expectedPlanToken": token],
        ]
        for object in payloads {
            let response = await handler.handle(
                EngramServiceRequestEnvelope(
                    command: "legacyLocalPurgeApply",
                    payload: try JSONSerialization.data(withJSONObject: object)
                )
            )
            assertInvalidRequest(response, contains: "Invalid payload for legacyLocalPurgeApply")
        }
        let missing = await handler.handle(EngramServiceRequestEnvelope(command: "legacyLocalPurgeApply"))
        assertInvalidRequest(missing, contains: "Invalid payload for legacyLocalPurgeApply")
        let previewWithPayload = await handler.handle(
            EngramServiceRequestEnvelope(command: "legacyLocalPurgePreview", payload: Data("{}".utf8))
        )
        assertInvalidRequest(previewWithPayload, contains: "does not accept a payload")
        let ids = try await sessionIDs(gate)
        XCTAssertEqual(ids, ["grok-a", "pi-a", Self.captureID].sorted())
    }

    func testLegacyLocalPurgeReportFlagIsReadOnly() throws {
        let runtime = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: runtime) }
        let path = runtime.appendingPathComponent("copy.sqlite").path
        do {
            let writer = try EngramDatabaseWriter(path: path)
            try writer.migrate()
            try writer.write { try Self.seed($0) }
        }
        // Runbook step: the backup copy is switched to DELETE journal mode first.
        let queue = try DatabaseQueue(path: path)
        _ = try queue.writeWithoutTransaction { try String.fetchOne($0, sql: "PRAGMA journal_mode = DELETE") }
        try queue.close()
        let digestBefore = try Self.fileDigest(path)

        XCTAssertEqual(
            try EngramServiceRunner.legacyLocalPurgeReportDatabasePath(
                arguments: ["--legacy-local-purge-report", "--database-path", path]
            ),
            path
        )
        XCTAssertNil(try EngramServiceRunner.legacyLocalPurgeReportDatabasePath(arguments: ["--database-path", path]))
        for arguments in [
            ["--legacy-local-purge-report"],
            ["--legacy-local-purge-report", "--database-path", "relative.sqlite"],
            ["--legacy-local-purge-report", "--database-path", path, "--service-socket", "/tmp/x.sock"],
            ["--database-path", path, "--legacy-local-purge-report"],
        ] {
            XCTAssertThrowsError(try EngramServiceRunner.legacyLocalPurgeReportDatabasePath(arguments: arguments))
        }

        let json = try EngramServiceRunner.legacyLocalPurgeReportJSON(databasePath: path)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        for key in ["planToken", "sessionCount", "blocking", "derived", "retained", "purgeAllowed"] {
            XCTAssertNotNil(object[key], key)
        }
        XCTAssertEqual(object["sessionCount"] as? Int, 2)
        XCTAssertEqual(object["planToken"] as? String, Self.token(["grok-a", "pi-a"]))
        XCTAssertLessThan(
            try XCTUnwrap(json.range(of: "\"blocking\"")).lowerBound,
            try XCTUnwrap(json.range(of: "\"planToken\"")).lowerBound,
            "keys are sorted"
        )
        XCTAssertEqual(try Self.fileDigest(path), digestBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + "-wal"))

        let missing = runtime.appendingPathComponent("missing.sqlite").path
        XCTAssertThrowsError(try EngramServiceRunner.legacyLocalPurgeReportJSON(databasePath: missing))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing))
    }

    func testParsesLegacyLocalPurgeCLICommands() throws {
        let token = Self.token(["grok-a"])
        XCTAssertNil(try EngramCLIMaintenanceCommand.parse(arguments: []))
        XCTAssertNil(try EngramCLIMaintenanceCommand.parse(arguments: ["archive", "status"]))
        XCTAssertEqual(
            try EngramCLIMaintenanceCommand.parse(arguments: ["maintenance", "legacy-local-purge", "preview"]),
            .legacyLocalPurgePreview(json: false)
        )
        XCTAssertEqual(
            try EngramCLIMaintenanceCommand.parse(arguments: ["maintenance", "legacy-local-purge", "preview", "--json"]),
            .legacyLocalPurgePreview(json: true)
        )
        XCTAssertEqual(
            try EngramCLIMaintenanceCommand.parse(arguments: [
                "maintenance", "legacy-local-purge", "apply", "--expect-sessions", "6191", "--expect-token", token,
            ]),
            .legacyLocalPurgeApply(expectedSessionCount: 6191, expectedPlanToken: token, json: false)
        )
        XCTAssertEqual(
            try EngramCLIMaintenanceCommand.parse(arguments: [
                "maintenance", "legacy-local-purge", "apply", "--json", "--expect-token", token, "--expect-sessions", "3",
            ]),
            .legacyLocalPurgeApply(expectedSessionCount: 3, expectedPlanToken: token, json: true)
        )
        let invalid: [[String]] = [
            ["maintenance"],
            ["maintenance", "legacy-local-purge"],
            ["maintenance", "other", "preview"],
            ["maintenance", "legacy-local-purge", "run"],
            ["maintenance", "legacy-local-purge", "preview", "--json", "--json"],
            ["maintenance", "legacy-local-purge", "preview", "--all"],
            ["maintenance", "legacy-local-purge", "apply", "--expect-sessions", "3"],
            ["maintenance", "legacy-local-purge", "apply", "--expect-token", token],
            ["maintenance", "legacy-local-purge", "apply", "--expect-sessions", "three", "--expect-token", token],
            ["maintenance", "legacy-local-purge", "apply", "--expect-sessions", "0", "--expect-token", token],
            ["maintenance", "legacy-local-purge", "apply", "--expect-sessions", "3", "--expect-token", token.uppercased()],
            ["maintenance", "legacy-local-purge", "apply", "--expect-sessions", "3", "--expect-sessions", "3", "--expect-token", token],
            ["maintenance", "legacy-local-purge", "apply", "--expect-sessions", "3", "--expect-token", token, "--json", "--json"],
            ["maintenance", "legacy-local-purge", "apply", "--expect-sessions", "3", "--expect-token", token, "--socket", "/tmp/s"],
        ]
        for arguments in invalid {
            XCTAssertThrowsError(try EngramCLIMaintenanceCommand.parse(arguments: arguments), "\(arguments)") { error in
                XCTAssertEqual(error as? EngramCLIMaintenanceError, .usage)
            }
        }
    }

    // MARK: - Helpers

    private static func token(_ ids: [String]) -> String {
        let bytes = Data(("engram-legacy-local-purge-v1\n" + ids.map { $0 + "\n" }.joined()).utf8)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func fileDigest(_ path: String) throws -> String {
        SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: path))).map { String(format: "%02x", $0) }.joined()
    }

    private static func seed(_ db: Database) throws {
        for (id, source, origin) in [
            ("grok-a", "grok", "local"),
            ("pi-a", "pi", "local"),
            (captureID, "grok", "capture-v1.M.I"),
        ] {
            try db.execute(
                sql: """
                    INSERT INTO sessions(id, source, start_time, file_path, origin, authoritative_node)
                    VALUES (?, ?, '2026-09-01T00:00:00Z', ?, ?, ?)
                    """,
                arguments: [id, source, "/fixture/\(id)", origin, origin]
            )
            try db.execute(
                sql: "INSERT INTO sessions_fts(session_id, content) VALUES (?, 'content')",
                arguments: [id]
            )
        }
        try db.execute(
            sql: """
                INSERT INTO capture_ingest_identity_bindings(machine_id, source_instance_id, source, native_id, stored_session_id)
                VALUES ('M', 'I', 'grok', 'native', ?)
                """,
            arguments: [captureID]
        )
    }

    private func makeSeededGate(_ runtime: URL) throws -> ServiceWriterGate {
        let path = runtime.appendingPathComponent("index.sqlite").path
        do {
            let writer = try EngramDatabaseWriter(path: path)
            try writer.migrate()
            try writer.write { try Self.seed($0) }
        }
        return try ServiceWriterGate(databasePath: path, runtimeDirectory: runtime)
    }

    private func sessionIDs(_ gate: ServiceWriterGate) async throws -> [String] {
        try await gate.performReadCommand(name: "probe") { writer in
            try writer.read { try String.fetchAll($0, sql: "SELECT id FROM sessions ORDER BY id") }
        }.value
    }

    private func applyEnvelope(sessions: Int, token: String) throws -> EngramServiceRequestEnvelope {
        EngramServiceRequestEnvelope(
            command: "legacyLocalPurgeApply",
            payload: try JSONSerialization.data(
                withJSONObject: ["expectedSessionCount": sessions, "expectedPlanToken": token]
            )
        )
    }

    private func assertInvalidRequest(
        _ response: EngramServiceResponseEnvelope,
        contains text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .failure(_, let error) = response else {
            return XCTFail("expected failure, got \(response)", file: file, line: line)
        }
        XCTAssertEqual(error.name, "InvalidRequest", file: file, line: line)
        XCTAssertTrue(error.message.contains(text), "\(error.message)", file: file, line: line)
    }

    private func makeRuntime() throws -> URL {
        let runtime = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("engram-d7purge-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: runtime,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return runtime
    }
}
