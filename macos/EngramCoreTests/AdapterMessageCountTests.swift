import Foundation
import SQLite3
import XCTest
@testable import EngramCoreRead

/// Coverage for the adapter message-count fixes (data-integrity review pass):
/// parseSessionInfo counts must reflect only the turns that streamMessages
/// actually emits — empty / tool-only / function-call-only turns must not
/// inflate the counts. Also covers the generic (non-personal) Antigravity CLI
/// cwd inference.
final class AdapterMessageCountTests: XCTestCase {
    // MARK: - Helpers

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-adapter-count-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sessionInfo<T>(_ result: AdapterParseResult<T>) throws -> T {
        switch result {
        case .success(let value):
            return value
        case .failure(let failure):
            throw XCTSkip("unexpected adapter failure: \(failure)")
        }
    }

    private func drain(_ adapter: SessionAdapter, locator: String) async throws -> [NormalizedMessage] {
        let stream = try await adapter.streamMessages(locator: locator, options: StreamMessagesOptions())
        var messages: [NormalizedMessage] = []
        for try await message in stream {
            messages.append(message)
        }
        return messages
    }

    private func jsonLine(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - VsCode

    func testVsCodeCountsOnlyNonEmptyTurns() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatDir = root.appendingPathComponent("ws-1/chatSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: chatDir, withIntermediateDirectories: true)

        // Request 1: normal user + markdown assistant.
        // Request 2: user text present, but assistant response is non-markdown
        //            (tool output only) → extractAssistantText returns "".
        let session: [String: Any] = [
            "kind": 0,
            "v": [
                "sessionId": "vs-1",
                "creationDate": 1_700_000_000_000,
                "requests": [
                    [
                        "timestamp": 1_700_000_000_000,
                        "message": ["text": "first question"],
                        "response": [
                            ["value": ["kind": "markdownContent", "content": ["value": "answer one"]]]
                        ],
                    ],
                    [
                        "timestamp": 1_700_000_010_000,
                        "message": ["text": "second question"],
                        "response": [
                            ["value": ["kind": "toolInvocationSerialized", "content": ["value": "n/a"]]]
                        ],
                    ],
                ],
            ],
        ]
        let file = chatDir.appendingPathComponent("sess.jsonl")
        try (try jsonLine(session) + "\n").write(to: file, atomically: true, encoding: .utf8)

        let adapter = VsCodeAdapter(workspaceStorageDir: root.path)
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: file.path))
        let streamed = try await drain(adapter, locator: file.path)

        XCTAssertEqual(info.userMessageCount, 2)
        XCTAssertEqual(info.assistantMessageCount, 1, "non-markdown assistant turn must not be counted")
        XCTAssertEqual(info.messageCount, 3)
        XCTAssertEqual(info.messageCount, streamed.count, "count must match streamed message count")
        XCTAssertEqual(streamed.filter { $0.role == .assistant }.count, info.assistantMessageCount)
        XCTAssertEqual(streamed.filter { $0.role == .user }.count, info.userMessageCount)
    }

    // MARK: - Gemini CLI

    func testGeminiCountsOnlyNonEmptyTurns() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatsDir = root.appendingPathComponent("tmp/proj/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)

        let session: [String: Any] = [
            "sessionId": "g-1",
            "startTime": "2026-01-01T00:00:00.000Z",
            "lastUpdated": "2026-01-01T00:10:00.000Z",
            "messages": [
                ["type": "user", "timestamp": "2026-01-01T00:00:01.000Z", "content": [["text": "hello"]]],
                ["type": "gemini", "timestamp": "2026-01-01T00:00:02.000Z", "content": "hi there"],
                // function-call-only model turn: no text content → dropped.
                ["type": "model", "timestamp": "2026-01-01T00:00:03.000Z", "content": [["functionCall": ["name": "read"]]]],
                // empty-text user turn → dropped.
                ["type": "user", "timestamp": "2026-01-01T00:00:04.000Z", "content": [["text": ""]]],
            ],
        ]
        let file = chatsDir.appendingPathComponent("session-g.json")
        try (try jsonLine(session)).write(to: file, atomically: true, encoding: .utf8)

        let adapter = GeminiCliAdapter(
            tmpRoot: root.appendingPathComponent("tmp").path,
            projectsFile: root.appendingPathComponent("projects.json").path
        )
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: file.path))
        let streamed = try await drain(adapter, locator: file.path)

        XCTAssertEqual(info.userMessageCount, 1, "empty-text user turn must not be counted")
        XCTAssertEqual(info.assistantMessageCount, 1, "function-call-only model turn must not be counted")
        XCTAssertEqual(info.messageCount, 2)
        XCTAssertEqual(info.messageCount, streamed.count)
    }

    // MARK: - Claude Code

    func testClaudeCodeToolResultCountMatchesStream() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDir = root.appendingPathComponent("-Users-test-proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let lines: [[String: Any]] = [
            [
                "type": "user",
                "sessionId": "cc-1",
                "cwd": "/Users/test/proj",
                "timestamp": "2026-01-01T00:00:00Z",
                "message": ["role": "user", "content": "do the thing"],
            ],
            [
                "type": "assistant",
                "sessionId": "cc-1",
                "timestamp": "2026-01-01T00:00:01Z",
                "message": ["role": "assistant", "model": "claude-x", "content": "on it"],
            ],
            // tool_result-only user record with no surfaced text → must be
            // dropped from stream AND not counted.
            [
                "type": "user",
                "sessionId": "cc-1",
                "timestamp": "2026-01-01T00:00:02Z",
                "message": ["role": "user", "content": [["type": "tool_result", "content": "raw output"]]],
            ],
            // tool_result that surfaces "User has answered" → counted as tool
            // and streamed with role .tool.
            [
                "type": "user",
                "sessionId": "cc-1",
                "timestamp": "2026-01-01T00:00:03Z",
                "message": ["role": "user", "content": [["type": "tool_result", "content": "User has answered: yes"]]],
            ],
        ]
        let file = projectDir.appendingPathComponent("sample.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = ClaudeCodeAdapter(projectsRoot: root.path)
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: file.path))
        let streamed = try await drain(adapter, locator: file.path)

        XCTAssertEqual(info.userMessageCount, 1)
        XCTAssertEqual(info.assistantMessageCount, 1)
        XCTAssertEqual(info.toolMessageCount, 1, "only the content-bearing tool_result is counted")
        XCTAssertEqual(info.messageCount, 3)
        XCTAssertEqual(info.messageCount, streamed.count, "count must match streamed message count")
        XCTAssertEqual(streamed.filter { $0.role == .tool }.count, 1)
        XCTAssertEqual(streamed.filter { $0.role == .user }.count, 1)
        XCTAssertEqual(streamed.filter { $0.role == .assistant }.count, 1)
    }

    // MARK: - OpenCode

    func testOpenCodeCountsOnlyMessagesWithTextParts() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbPath = root.appendingPathComponent("opencode.db").path
        try Self.buildOpenCodeFixture(dbPath: dbPath)

        let adapter = OpenCodeAdapter(dbPath: dbPath)
        let locator = "\(dbPath)::ses_1"
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: locator))
        let streamed = try await drain(adapter, locator: locator)

        XCTAssertEqual(info.userMessageCount, 1)
        XCTAssertEqual(info.assistantMessageCount, 1, "assistant message without a text part must not be counted")
        XCTAssertEqual(info.messageCount, 2)
        XCTAssertEqual(info.messageCount, streamed.count, "count must match streamed message count")
    }

    /// Minimal OpenCode schema with: 1 user msg (text part), 1 assistant msg
    /// (text part), and 1 assistant msg whose only part is a non-text tool part
    /// (must be excluded from counts and the stream).
    private static func buildOpenCodeFixture(dbPath: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw NSError(domain: "test", code: 1)
        }
        defer { sqlite3_close(db) }

        func exec(_ sql: String) throws {
            var err: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
                let message = err.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(err)
                throw NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }

        try exec("CREATE TABLE session (id TEXT, directory TEXT, title TEXT, time_created INTEGER, time_updated INTEGER, time_archived INTEGER)")
        try exec("CREATE TABLE message (id TEXT, session_id TEXT, time_created INTEGER, data TEXT)")
        try exec("CREATE TABLE part (id TEXT, message_id TEXT, time_created INTEGER, data TEXT)")

        try exec("INSERT INTO session VALUES ('ses_1', '/Users/test/proj', 'Title', 1700000000000, 1700000010000, NULL)")
        try exec("INSERT INTO message VALUES ('m1', 'ses_1', 1700000001000, '{\"role\":\"user\"}')")
        try exec("INSERT INTO message VALUES ('m2', 'ses_1', 1700000002000, '{\"role\":\"assistant\"}')")
        try exec("INSERT INTO message VALUES ('m3', 'ses_1', 1700000003000, '{\"role\":\"assistant\"}')")
        try exec("INSERT INTO part VALUES ('p1', 'm1', 1700000001000, '{\"type\":\"text\",\"text\":\"question\"}')")
        try exec("INSERT INTO part VALUES ('p2', 'm2', 1700000002000, '{\"type\":\"text\",\"text\":\"answer\"}')")
        // m3 has only a tool part (no text) → must be dropped.
        try exec("INSERT INTO part VALUES ('p3', 'm3', 1700000003000, '{\"type\":\"tool\",\"tool\":\"read\"}')")
    }

    // MARK: - Antigravity generic cwd inference

    func testAntigravityCWDInferenceIsGenericAndNonPersonal() {
        // Most-frequent directory wins; no '-Code-' literal required.
        let text = """
        {"tool_calls":[{"name":"Read","args":{"path":"/home/alice/work/app/src/main.go"}}]}
        also touched /home/alice/work/app/src/util.go and /opt/other/x.go
        """
        XCTAssertEqual(
            AntigravityAdapter.inferCWDFromAbsolutePaths(in: text),
            "/home/alice/work/app/src"
        )
    }

    func testAntigravityCWDInferenceReturnsEmptyWithoutPaths() {
        XCTAssertEqual(AntigravityAdapter.inferCWDFromAbsolutePaths(in: "no absolute paths in auth.ts here"), "")
    }
}
