import XCTest
import GRDB
@testable import Engram

final class DiagnosticBundleComposerTests: XCTestCase {
    func testComposeIncludesTopLevelKeys() throws {
        let data = try DiagnosticBundleComposer.compose(input: makeInput())
        let object = try rootObject(from: data)

        for key in ["app", "service", "database", "recentLogs", "settings"] {
            XCTAssertNotNil(object[key], "Expected top-level key \(key)")
        }
    }

    func testComposeRedactsPlantedSensitiveSettings() throws {
        let aiSecret = "sk-test-diagnostic-secret"
        let titleSecret = "title-test-diagnostic-secret"
        let remoteToken = "remote-offload-token-secret"
        let nestedSecret = "nested-title-secret"
        let embeddingSecret = "sk-embedding-diagnostic-secret"
        let data = try DiagnosticBundleComposer.compose(input: makeInput(settings: [
            "aiApiKey": aiSecret,
            "titleApiKey": titleSecret,
            "embeddingApiKey": embeddingSecret,
            "remoteOffloadToken": remoteToken,
            "usageTokenLimits": [
                "codex": ["fiveHourTokens": 10_000],
            ],
            "nested": [
                "titleApiKey": nestedSecret,
                "embeddingApiKey": "nested-embedding-secret",
            ],
        ]))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(json.contains(aiSecret))
        XCTAssertFalse(json.contains(titleSecret))
        XCTAssertFalse(json.contains(remoteToken))
        XCTAssertFalse(json.contains(nestedSecret))
        XCTAssertFalse(json.contains(embeddingSecret))
        XCTAssertFalse(json.contains("nested-embedding-secret"))
        XCTAssertTrue(json.contains(#""<redacted>""#))
        XCTAssertTrue(json.contains("usageTokenLimits"))
        XCTAssertTrue(json.contains("fiveHourTokens"))
    }

    /// M14: embeddingApiKey and normalized aliases must redact; non-secret keys stay visible.
    func testComposeRedactsEmbeddingApiKeyAliasesWithoutExactKeyBypass() throws {
        let camel = "sk-embedding-camel-secret"
        let snake = "sk-embedding-snake-secret"
        let spaced = "sk-embedding-spaced-secret"
        let data = try DiagnosticBundleComposer.compose(input: makeInput(settings: [
            "embeddingApiKey": camel,
            "embedding_api_key": snake,
            "Embedding-Api-Key": spaced,
            "noiseFilter": "hide-skip",
        ]))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(json.contains(camel), "camelCase embeddingApiKey must redact")
        XCTAssertFalse(json.contains(snake), "snake_case alias must redact")
        XCTAssertFalse(json.contains(spaced), "hyphenated alias must redact")
        XCTAssertTrue(json.contains("hide-skip"), "non-secret keys must not be redacted by alias normalization")
        XCTAssertTrue(json.contains(#""<redacted>""#))
    }

    func testServiceUnreachableStillProducesValidJSON() throws {
        let data = try DiagnosticBundleComposer.compose(input: makeInput(
            service: .unreachable(message: "service socket unavailable")
        ))
        let object = try rootObject(from: data)
        let service = try XCTUnwrap(object["service"] as? [String: Any])

        XCTAssertEqual(service["state"] as? String, "unreachable")
        XCTAssertEqual(service["message"] as? String, "service socket unavailable")
    }

    @MainActor
    func testDiagnosticStatsUsesAggregateVisibleCounts() throws {
        let (db, path) = try createTempDatabase()
        defer { cleanupTempDatabase(at: path) }

        try insertTestSession(at: path, id: "visible-claude", source: "claude-code", tier: "normal")
        try insertTestSession(at: path, id: "visible-codex", source: "codex", tier: "lite")
        try insertTestSession(
            at: path,
            id: "hidden-codex",
            source: "codex",
            tier: "skip",
            hiddenAt: "2026-07-08T00:00:00Z"
        )
        let queue = try DatabaseQueue(path: path)
        try queue.write { database in
            try database.execute(sql: """
                CREATE TABLE IF NOT EXISTS session_index_jobs (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id TEXT NOT NULL,
                    status TEXT NOT NULL
                )
            """)
            try database.execute(
                sql: "INSERT INTO session_index_jobs (session_id, status) VALUES (?, ?), (?, ?), (?, ?)",
                arguments: ["visible-claude", "pending", "visible-codex", "pending", "hidden-codex", "done"]
            )
        }

        let stats = try db.diagnosticStats()

        XCTAssertEqual(stats.sessionsBySource, ["claude-code": 1, "codex": 1])
        XCTAssertEqual(stats.sessionsByTier, ["lite": 1, "normal": 1])
        XCTAssertEqual(stats.indexJobsByStatus, ["done": 1, "pending": 2])
        XCTAssertGreaterThan(stats.dbFileSizeBytes, 0)
    }

    private func makeInput(
        service: DiagnosticServiceStatus = .status(.running(total: 7, todayParents: 2)),
        settings: [String: Any] = ["noiseFilter": "hide-skip"]
    ) -> DiagnosticBundleInput {
        DiagnosticBundleInput(
            app: DiagnosticAppInfo(version: "1.2.3", build: "456", macOSVersion: "macOS 15.0"),
            service: service,
            database: DiagnosticDatabaseStats(
                sessionsBySource: ["claude-code": 3, "codex": 4],
                sessionsByTier: ["normal": 6, "lite": 1],
                indexJobsByStatus: ["pending": 1],
                dbFileSizeBytes: 4096
            ),
            recentLogs: [
                DiagnosticLogLine(
                    timestamp: "2026-07-08T00:00:00Z",
                    level: "info",
                    category: "index",
                    message: "scan complete"
                ),
            ],
            settings: settings
        )
    }

    private func rootObject(from data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
