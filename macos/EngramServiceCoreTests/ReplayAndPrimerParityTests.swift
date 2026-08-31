import XCTest
import GRDB
import Foundation
@testable import EngramCoreRead
@testable import EngramServiceCore

/// Parity coverage for the read/render-path perf changes:
///  - #30 windowed resume-context primer (TranscriptExportService.readPrimerMessages)
///  - #6  deferred FTS fallback in SQLiteEngramServiceReadProvider.replayTimeline
final class ReplayAndPrimerParityTests: XCTestCase {

    // MARK: - #30 windowed primer parity

    func testPrimerWindowMatchesFullReadForLongTranscript() async throws {
        // 10 visible JSONL messages → primer keeps first + last 5.
        let path = try writeClaudeCodeFixture(userAssistantPairs: 5) // 10 messages
        defer { try? FileManager.default.removeItem(atPath: path) }

        let full = try await ServiceTranscriptReader.readMessages(filePath: path, source: "iflow")
        XCTAssertEqual(full.count, 10)
        let expected = ServiceTranscriptReader.primerWindow(full, limit: 6)
        XCTAssertEqual(expected.count, 6)

        let windowed = try await ServiceTranscriptReader.readPrimerMessages(
            filePath: path,
            source: "iflow",
            limit: 6
        )

        XCTAssertEqual(windowed.map(\.role), expected.map(\.role))
        XCTAssertEqual(windowed.map(\.content), expected.map(\.content))
        // first message + last five.
        XCTAssertEqual(windowed.first?.content, full.first?.content)
        XCTAssertEqual(windowed.suffix(5).map(\.content), full.suffix(5).map(\.content))
    }

    func testPrimerWindowMatchesFullReadForShortTranscript() async throws {
        // 4 visible messages (< limit) → primer is the whole transcript.
        let path = try writeClaudeCodeFixture(userAssistantPairs: 2) // 4 messages
        defer { try? FileManager.default.removeItem(atPath: path) }

        let full = try await ServiceTranscriptReader.readMessages(filePath: path, source: "iflow")
        XCTAssertEqual(full.count, 4)

        let windowed = try await ServiceTranscriptReader.readPrimerMessages(
            filePath: path,
            source: "iflow",
            limit: 6
        )
        XCTAssertEqual(windowed.map(\.content), full.map(\.content))
    }

    // MARK: - #6 replayTimeline deferred-FTS parity

    func testReplayTimelineUsesOnDiskStreamAndSkipsFtsSentinel() async throws {
        let fixture = try writeClaudeCodeFixture(userAssistantPairs: 2) // U0,A0,U1,A1
        defer { try? FileManager.default.removeItem(atPath: fixture) }

        let dbPath = try seedReplayFixture { db in
            try insertSession(db, id: "disk1", source: "claude-code", filePath: fixture)
            // Divergent FTS content that must NOT surface on the on-disk path.
            try db.execute(
                sql: "INSERT INTO sessions_fts(session_id, content) VALUES ('disk1', ?)",
                arguments: ["FTS_SENTINEL_SHOULD_NOT_APPEAR"]
            )
        }
        defer { removeSQLiteFixture(at: dbPath) }

        let fixtureRoot = URL(fileURLWithPath: fixture).deletingLastPathComponent().path
        let provider = try SQLiteEngramServiceReadProvider(
            databasePath: dbPath,
            sessionAdapterProvider: {
                [ClaudeCodeAdapter(projectsRoot: fixtureRoot)]
            }
        )
        let replay = try await provider.replayTimeline(
            EngramServiceReplayTimelineRequest(sessionId: "disk1", limit: 500)
        )

        XCTAssertEqual(replay.source, "claude-code")
        XCTAssertEqual(replay.entries.map(\.role), ["user", "assistant", "user", "assistant"])
        XCTAssertEqual(replay.entries.map(\.preview), ["U0", "A0", "U1", "A1"])
        XCTAssertFalse(
            replay.entries.contains { $0.preview.contains("FTS_SENTINEL") },
            "on-disk stream must not fall through to the FTS content rows"
        )
    }

    func testReplayTimelineFallsBackToFtsWhenFileMissing() async throws {
        let dbPath = try seedReplayFixture { db in
            try insertSession(db, id: "missing1", source: "claude-code", filePath: "/tmp/engram-does-not-exist.jsonl")
            try db.execute(
                sql: "INSERT INTO sessions_fts(session_id, content) VALUES ('missing1', ?)",
                arguments: ["User: fallback one"]
            )
            try db.execute(
                sql: "INSERT INTO sessions_fts(session_id, content) VALUES ('missing1', ?)",
                arguments: ["Assistant: fallback two"]
            )
        }
        defer { removeSQLiteFixture(at: dbPath) }

        let provider = try SQLiteEngramServiceReadProvider(databasePath: dbPath)
        let replay = try await provider.replayTimeline(
            EngramServiceReplayTimelineRequest(sessionId: "missing1", limit: 500)
        )

        XCTAssertEqual(replay.source, "claude-code")
        XCTAssertEqual(replay.totalEntries, 2)
        XCTAssertEqual(replay.entries.map(\.role), ["user", "assistant"])
        XCTAssertEqual(replay.entries.map(\.preview), ["fallback one", "fallback two"])
    }

    func testReplayTimelineReportsStreamSentinelBeyondReturnedPrefix_repro() async throws {
        let fixture = try writeReplayFixture(messageCount: 2_002)
        defer { try? FileManager.default.removeItem(atPath: fixture) }

        let dbPath = try seedReplayFixture { db in
            try insertSession(db, id: "long-disk", source: "claude-code", filePath: fixture)
        }
        defer { removeSQLiteFixture(at: dbPath) }

        let fixtureRoot = URL(fileURLWithPath: fixture).deletingLastPathComponent().path
        let provider = try SQLiteEngramServiceReadProvider(
            databasePath: dbPath,
            sessionAdapterProvider: {
                [ClaudeCodeAdapter(projectsRoot: fixtureRoot)]
            }
        )
        let replay = try await provider.replayTimeline(
            EngramServiceReplayTimelineRequest(sessionId: "long-disk", limit: 2_000)
        )

        XCTAssertEqual(replay.entries.count, 2_000)
        XCTAssertEqual(replay.totalEntries, 2_001, "the sentinel is a lower bound beyond the returned prefix")
        XCTAssertEqual(replay.hasMore, true)
        XCTAssertGreaterThan(replay.totalEntries, replay.entries.count)
    }

    func testReplayTimelineKeepsAdapterPrefixOnParseFailure_repro() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-replay-prefix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("rollout-prefix.jsonl")
        let valid = #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"disk prefix"}]}}"#
        try (valid + "\n" + String(repeating: "x", count: 300) + "\n")
            .write(to: transcript, atomically: true, encoding: .utf8)
        let dbPath = try seedReplayFixture { db in
            try insertSession(db, id: "prefix-disk", source: "codex", filePath: transcript.path)
            try db.execute(
                sql: "INSERT INTO sessions_fts(session_id, content) VALUES ('prefix-disk', 'FTS SHOULD NOT REPLACE PREFIX')"
            )
        }
        defer { removeSQLiteFixture(at: dbPath) }
        let provider = try SQLiteEngramServiceReadProvider(
            databasePath: dbPath,
            sessionAdapterProvider: {
                [CodexAdapter(sessionsRoot: root.path, limits: ParserLimits(maxLineBytes: 256))]
            }
        )

        let replay = try await provider.replayTimeline(
            EngramServiceReplayTimelineRequest(sessionId: "prefix-disk", limit: 500)
        )

        XCTAssertEqual(replay.entries.map(\.preview), ["disk prefix"])
        XCTAssertEqual(replay.hasMore, true)
    }

    func testReplayTimelineUsesHqSnapshotWithoutOpeningRemoteLocator_repro() async throws {
        let adapterProbe = RemoteReplayAdapterProbe()
        let dbPath = try seedReplayFixture { db in
            try insertSession(
                db,
                id: "remote-replay",
                source: "codex",
                filePath: "remote://hq/remote-replay",
                summary: "Stored HQ summary"
            )
            try db.execute(
                sql: "INSERT INTO sessions_fts(session_id, content) VALUES ('remote-replay', 'Assistant: indexed HQ detail')"
            )
        }
        defer { removeSQLiteFixture(at: dbPath) }
        let provider = try SQLiteEngramServiceReadProvider(
            databasePath: dbPath,
            sessionAdapterProvider: {
                [RemoteReplayTrapAdapter(probe: adapterProbe)]
            }
        )

        let replay = try await provider.replayTimeline(
            EngramServiceReplayTimelineRequest(sessionId: "remote-replay", limit: 500)
        )

        XCTAssertEqual(adapterProbe.callCount, 0, "remote:// must never enter a local source adapter")
        XCTAssertEqual(
            replay.entries.map(\.preview),
            ["HQ 索引快照，不是源文件", "Stored HQ summary", "indexed HQ detail"]
        )
        XCTAssertEqual(replay.totalEntries, 3)
        XCTAssertEqual(replay.hasMore, false)
    }

    // MARK: - Helpers

    private func writeClaudeCodeFixture(userAssistantPairs pairs: Int) throws -> String {
        var lines: [String] = []
        for i in 0..<pairs {
            lines.append(
                #"{"type":"user","sessionId":"fix","timestamp":"2026-06-14T10:0\#(i):00Z","message":{"role":"user","content":"U\#(i)"}}"#
            )
            lines.append(
                #"{"type":"assistant","sessionId":"fix","timestamp":"2026-06-14T10:0\#(i):30Z","message":{"role":"assistant","content":"A\#(i)"}}"#
            )
        }
        let path = NSTemporaryDirectory() + "engram-cc-\(UUID().uuidString.prefix(8)).jsonl"
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func writeReplayFixture(messageCount: Int) throws -> String {
        let lines = (0..<messageCount).map { index in
            let type = index.isMultiple(of: 2) ? "user" : "assistant"
            return #"{"type":"\#(type)","sessionId":"long-fix","timestamp":"2026-06-14T10:00:00Z","message":{"role":"\#(type)","content":"M\#(index)"}}"#
        }
        let path = NSTemporaryDirectory() + "engram-replay-long-\(UUID().uuidString.prefix(8)).jsonl"
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func insertSession(
        _ db: GRDB.Database,
        id: String,
        source: String,
        filePath: String,
        summary: String? = nil
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO sessions (
                  id, source, start_time, file_path, source_locator, message_count, summary, indexed_at
                )
                VALUES (?, ?, '2026-06-14T10:00:00Z', ?, NULL, 0, ?, '2026-06-14T10:00:00Z')
            """,
            arguments: [id, source, filePath, summary]
        )
    }

    private func seedReplayFixture(_ seed: (GRDB.Database) throws -> Void) throws -> String {
        let path = NSTemporaryDirectory() + "engram-replay-\(UUID().uuidString.prefix(8)).sqlite"
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        let queue = try DatabaseQueue(path: path, configuration: configuration)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE sessions (
                  id TEXT PRIMARY KEY,
                  source TEXT NOT NULL,
                  start_time TEXT NOT NULL DEFAULT '',
                  file_path TEXT,
                  source_locator TEXT,
                  message_count INTEGER NOT NULL DEFAULT 0,
                  summary TEXT,
                  indexed_at TEXT
                );
                CREATE TABLE session_local_state (
                  session_id TEXT PRIMARY KEY,
                  local_readable_path TEXT
                );
                CREATE VIRTUAL TABLE sessions_fts USING fts5(
                  session_id UNINDEXED,
                  content,
                  tokenize='trigram case_sensitive 0'
                );
            """)
            try seed(db)
        }
        return path
    }

    private func removeSQLiteFixture(at path: String) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }
}

private final class RemoteReplayAdapterProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func recordCall() {
        lock.lock()
        calls += 1
        lock.unlock()
    }
}

private final class RemoteReplayTrapAdapter: SessionAdapter, @unchecked Sendable {
    let source: SourceName = .codex
    private let probe: RemoteReplayAdapterProbe

    init(probe: RemoteReplayAdapterProbe) {
        self.probe = probe
    }

    func detect() async -> Bool { true }
    func listSessionLocators() async throws -> [String] { [] }
    func isAccessible(locator _: String) async -> Bool { false }

    func parseSessionInfo(locator _: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        throw ParserFailure.unsupportedVirtualLocator
    }

    func streamMessages(
        locator _: String,
        options _: StreamMessagesOptions
    ) async throws -> AsyncThrowingStream<NormalizedMessage, Error> {
        probe.recordCall()
        throw ParserFailure.unsupportedVirtualLocator
    }
}
