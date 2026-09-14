import Darwin
import Foundation
import GRDB
import XCTest
import EngramCoreRead
import EngramCoreWrite
@testable import EngramServiceCore

final class WebInsightWriteTests: XCTestCase {
    private let requestID = "AAAAAAAA-0000-4000-8000-000000000212"

    func testHandlerGateSaveIsSearchableAndReadable() async throws {
        let env = try prepared()
        defer { env.tearDown() }
        try env.fixture.seedBoundSession(id: "one", start: "2026-09-01 12:00:00", nativeID: "native-one")
        let previous = getenv("ENGRAM_SETTINGS_PATH").map { String(cString: $0) }
        setenv("ENGRAM_SETTINGS_PATH", env.settingsURL.path, 1)
        defer {
            if let previous { setenv("ENGRAM_SETTINGS_PATH", previous, 1) }
            else { unsetenv("ENGRAM_SETTINGS_PATH") }
        }
        let runtime = env.fixture.directory.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let gate = try ServiceWriterGate(databasePath: env.fixture.path, runtimeDirectory: runtime)
        let producer = try env.fixture.producer()
        defer { try? producer.stop() }
        let reader = try SQLiteEngramServiceReadProvider(databasePath: env.fixture.path)
        let handler = EngramServiceCommandHandler(
            writerGate: gate, webMetadataProducer: producer, readProvider: reader)
        let request = try EngramServiceWebSaveInsightRequest(
            content: "library note from web save",
            wing: "Engineering",
            room: "Engram",
            importance: 4,
            sourceSessionId: "one"
        )
        let response = await handler.handle(EngramServiceRequestEnvelope(
            requestId: requestID,
            command: "webSaveInsight",
            payload: try JSONEncoder().encode(request)
        ))
        guard case .success(_, let payload, _) = response else {
            return XCTFail("webSaveInsight must succeed through the writer gate")
        }
        let saved = try JSONDecoder().decode(EngramServiceWebSaveInsightResponse.self, from: payload)
        let stored = try env.writer.read { db in
            try Row.fetchOne(db, sql: """
                SELECT content, wing, room, importance, source_session_id
                FROM insights WHERE id = ?
                """, arguments: [saved.id])
        }
        XCTAssertEqual(stored?["content"] as String?, "library note from web save")
        XCTAssertEqual(stored?["wing"] as String?, "Engineering")
        XCTAssertEqual(stored?["room"] as String?, "Engram")
        XCTAssertEqual(stored?["importance"] as Int?, 4)
        XCTAssertEqual(stored?["source_session_id"] as String?, "one")
        let fts = try env.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM insights_fts WHERE insight_id = ?",
                             arguments: [saved.id])
        }
        XCTAssertEqual(fts, 1)
        let ranked = try await reader.search(
            EngramServiceSearchRequest(query: "library note", mode: "keyword", limit: 10)
        )
        let page = try await producer.admitSearch(
            try EngramServiceWebSearchRequest(query: "library note"),
            ranked: ranked, requestId: requestID, deadline: env.fixture.deadline())
        XCTAssertEqual(page.insightResults.map(\.id), [saved.id])
        let detail = try await producer.insightDetail(
            try EngramServiceWebInsightDetailRequest(id: saved.id),
            requestId: requestID, deadline: env.fixture.deadline())
        XCTAssertEqual(detail.sourceSessionId, "one")
        XCTAssertEqual(detail.content, "library note from web save")
        XCTAssertNotNil(saved.warning)
    }

    func testUnknownPayloadKeysAndInvalidImportanceAreRejected() async throws {
        let env = try prepared()
        defer { env.tearDown() }
        let runtime = env.fixture.directory.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let gate = try ServiceWriterGate(databasePath: env.fixture.path, runtimeDirectory: runtime)
        let handler = EngramServiceCommandHandler(writerGate: gate)
        let unknown = await handler.handle(EngramServiceRequestEnvelope(
            requestId: requestID,
            command: "webSaveInsight",
            payload: try JSONSerialization.data(withJSONObject: [
                "content": "library note from web save", "type": "semantic",
            ])
        ))
        guard case .failure(_, let unknownError) = unknown else {
            return XCTFail("Unknown keys must not reach saveInsight")
        }
        XCTAssertEqual(unknownError.name, "InvalidRequest")
        XCTAssertThrowsError(try EngramServiceWebSaveInsightRequest(
            content: "library note from web save", importance: .infinity))
        XCTAssertThrowsError(try EngramServiceWebSaveInsightRequest(
            content: "library note from web save", importance: 5.1))
        XCTAssertThrowsError(try EngramServiceWebSaveInsightRequest(content: "short"))
    }

    func testHiddenDisabledUnboundAndEmptySourceAreRejected() throws {
        let env = try prepared()
        defer { env.tearDown() }
        try env.fixture.seedBoundSession(id: "one", start: "2026-09-01 12:00:00", nativeID: "native-one")
        try env.fixture.seedBoundSession(id: "hidden", start: "2026-09-01 12:00:00",
                                         nativeID: "native-hidden", hidden: true)
        try env.fixture.seedBoundSession(id: "skip", start: "2026-09-01 12:00:00",
                                         nativeID: "native-skip", tier: "skip")
        try env.fixture.seedBoundSession(id: "codex-only", start: "2026-09-01 12:00:00",
                                         nativeID: "native-codex", source: .codex)
        try env.fixture.seedLocalSession(id: "unbound")
        for source in ["hidden", "skip", "codex-only", "unbound", ""] {
            XCTAssertThrowsError(try EngramServiceCommandHandler.webSaveInsight(
                EngramServiceWebSaveInsightRequest(
                    content: "hidden source must not receive a new note",
                    sourceSessionId: source
                ),
                writer: env.writer,
                settingsURL: env.settingsURL
            )) { error in
                guard case .commandFailed(let name, _, _, _)? = error as? EngramServiceError else {
                    return XCTFail("Expected NotFound for \(source)")
                }
                XCTAssertEqual(name, "NotFound")
            }
        }
        let count = try env.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM insights")
        }
        XCTAssertEqual(count, 0)
    }

    func testWebDedupDoesNotSupersedeHiddenSourceInsight() throws {
        let env = try prepared()
        defer { env.tearDown() }
        try env.fixture.seedBoundSession(id: "one", start: "2026-09-01 12:00:00", nativeID: "native-one")
        try env.fixture.seedBoundSession(id: "hidden", start: "2026-09-01 12:00:00",
                                         nativeID: "native-hidden", hidden: true)
        try insertInsight(env, id: "hidden-note", content: "duplicate constellation note for dedup",
                          session: "hidden")
        let saved = try EngramServiceCommandHandler.webSaveInsight(
            EngramServiceWebSaveInsightRequest(content: "duplicate constellation note for dedup"),
            writer: env.writer,
            settingsURL: env.settingsURL
        )
        let hidden = try env.writer.read { db in
            try String.fetchOne(db, sql: "SELECT superseded_by FROM insights WHERE id = 'hidden-note'")
        }
        XCTAssertNil(hidden)
        XCTAssertNotEqual(saved.id, "hidden-note")
    }

    func testNativeSaveStillSupersedesHiddenSourceInsight() throws {
        let env = try prepared()
        defer { env.tearDown() }
        try env.fixture.seedBoundSession(id: "hidden", start: "2026-09-01 12:00:00",
                                         nativeID: "native-hidden", hidden: true)
        try insertInsight(env, id: "hidden-note", content: "duplicate constellation note for dedup",
                          session: "hidden")
        let json = try EngramServiceCommandHandler.saveInsight(
            EngramServiceSaveInsightRequest(content: "duplicate constellation note for dedup"),
            writer: env.writer
        )
        guard case .object(let object) = json, case .string(let id)? = object["id"] else {
            return XCTFail("Native saveInsight must return an id")
        }
        let hidden = try env.writer.read { db in
            try String.fetchOne(db, sql: "SELECT superseded_by FROM insights WHERE id = 'hidden-note'")
        }
        XCTAssertEqual(hidden, id)
    }

    private struct Env {
        let fixture: MetadataSQLFixture
        let writer: EngramDatabaseWriter
        let settingsURL: URL
        func tearDown() { fixture.remove() }

        func writeSettings(disabled: [String]) throws {
            let document: [String: Any] = [
                "runtimeRole": "index",
                "disabledSources": disabled,
                ArchivedDefaultOffSources.settingsMigrationKey: true,
                "captureIngest": [
                    "enabled": true, "serverID": "hq", "baseURL": "http://127.0.0.1",
                    "credentialID": "hq", "requestTimeout": 0.2, "retryCount": 0,
                ],
            ]
            try JSONSerialization.data(withJSONObject: document).write(to: settingsURL)
            XCTAssertEqual(chmod(settingsURL.path, 0o600), 0)
        }
    }

    private func prepared() throws -> Env {
        let fixture = try MetadataSQLFixture()
        try fixture.migrate()
        try fixture.seedRegistry()
        let env = Env(
            fixture: fixture,
            writer: try EngramDatabaseWriter(path: fixture.path),
            settingsURL: fixture.directory.appendingPathComponent("settings.json")
        )
        try env.writeSettings(
            disabled: EngramServiceWebSourceSettingsValidation.knownKeys.filter { $0 != "claude-code" }.sorted()
        )
        return env
    }

    private func insertInsight(_ env: Env, id: String, content: String, session: String?) throws {
        try env.writer.write { db in
            try db.execute(sql: """
                INSERT INTO insights(id, content, source_session_id, importance)
                VALUES (?, ?, ?, 5)
                """, arguments: [id, content, session])
            try db.execute(sql: "INSERT INTO insights_fts(insight_id, content) VALUES (?, ?)",
                           arguments: [id, content])
        }
    }
}
