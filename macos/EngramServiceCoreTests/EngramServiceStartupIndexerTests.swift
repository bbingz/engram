import Foundation
import GRDB
import XCTest
import EngramCoreRead
import EngramCoreWrite
@testable import EngramServiceCore

final class EngramServiceStartupIndexerTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-service-startup-indexer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        dbURL = tempDir.appendingPathComponent("index.sqlite")
        let writer = try EngramDatabaseWriter(path: dbURL.path)
        try writer.migrate()
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        dbURL = nil
    }

    func testIndexOnceWritesAdapterSessionsThroughServiceGate() async throws {
        let gate = try ServiceWriterGate(databasePath: dbURL.path, runtimeDirectory: tempDir)

        let indexed = try await EngramServiceStartupIndexer.indexOnce(
            gate: gate,
            adapters: [SingleSessionAdapter()]
        )

        XCTAssertEqual(indexed, 1)
        let writer = try EngramDatabaseWriter(path: dbURL.path)
        let row = try writer.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT id, source, cwd, message_count FROM sessions WHERE id = ?",
                arguments: ["service-startup-session"]
            )
        }
        XCTAssertEqual(row?["id"] as String?, "service-startup-session")
        XCTAssertEqual(row?["source"] as String?, "codex")
        XCTAssertEqual(row?["cwd"] as String?, "/tmp/service-startup")
        XCTAssertEqual(row?["message_count"] as Int?, 2)
    }
}

private final class SingleSessionAdapter: SessionAdapter {
    let source: SourceName = .codex

    func detect() async -> Bool { true }

    func listSessionLocators() async throws -> [String] {
        ["/tmp/service-startup-rollout.jsonl"]
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        .success(
            NormalizedSessionInfo(
                id: "service-startup-session",
                source: .codex,
                startTime: "2026-04-29T00:00:00Z",
                endTime: "2026-04-29T00:01:00Z",
                cwd: "/tmp/service-startup",
                project: "service-startup",
                model: "openai",
                messageCount: 2,
                userMessageCount: 1,
                assistantMessageCount: 1,
                toolMessageCount: 0,
                systemMessageCount: 0,
                summary: "hello",
                filePath: locator,
                sizeBytes: 128
            )
        )
    }

    func streamMessages(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> AsyncThrowingStream<NormalizedMessage, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(NormalizedMessage(role: .user, content: "hello"))
            continuation.yield(NormalizedMessage(role: .assistant, content: "hi"))
            continuation.finish()
        }
    }

    func isAccessible(locator: String) async -> Bool {
        true
    }
}
