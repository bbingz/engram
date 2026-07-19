import Foundation
import SQLite3
import XCTest
@testable import EngramCoreRead
@testable import EngramCoreWrite

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

    private func parseFailure<T>(_ result: AdapterParseResult<T>) throws -> ParserFailure {
        switch result {
        case .success:
            throw XCTSkip("expected adapter failure")
        case .failure(let failure):
            return failure
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

    // Runtime-debt repro: VS Code persists valid empty draft sessions that are
    // not malformed transcripts and must not enter the retry loop.
    func testVsCodeEmptyDraftIsTerminalNoVisibleMessages_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatDir = root.appendingPathComponent("ws-empty/chatSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: chatDir, withIntermediateDirectories: true)

        let session: [String: Any] = [
            "kind": 0,
            "v": [
                "sessionId": "vs-empty-draft",
                "creationDate": 1_700_000_000_000,
                "requests": [],
            ],
        ]
        let file = chatDir.appendingPathComponent("empty.jsonl")
        try (try jsonLine(session) + "\n").write(to: file, atomically: true, encoding: .utf8)

        let adapter = VsCodeAdapter(workspaceStorageDir: root.path)
        let failure = try parseFailure(await adapter.parseSessionInfo(locator: file.path))

        XCTAssertEqual(failure, .noVisibleMessages)
    }

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

    func testVsCodeReplaysAppendMutationLog() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatDir = root.appendingPathComponent("ws-1/chatSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: chatDir, withIntermediateDirectories: true)

        let initial: [String: Any] = [
            "kind": 0,
            "v": [
                "sessionId": "vs-replay",
                "creationDate": 1_700_000_000_000,
                "requests": [],
            ],
        ]
        let request: [String: Any] = [
            "requestId": "r1",
            "timestamp": 1_700_000_005_000,
            "message": ["text": "request from mutation log"],
            "response": [
                ["value": ["kind": "markdownContent", "content": ["value": "answer from mutation log"]]]
            ],
        ]
        let push: [String: Any] = [
            "kind": 2,
            "k": ["requests"],
            "v": [request],
        ]
        let file = chatDir.appendingPathComponent("sess.jsonl")
        try ([try jsonLine(initial), try jsonLine(push)].joined(separator: "\n") + "\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = VsCodeAdapter(workspaceStorageDir: root.path)
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: file.path))
        let streamed = try await drain(adapter, locator: file.path)

        XCTAssertEqual(info.userMessageCount, 1)
        XCTAssertEqual(info.assistantMessageCount, 1)
        XCTAssertEqual(info.summary, "request from mutation log")
        XCTAssertEqual(streamed.map(\.content), ["request from mutation log", "answer from mutation log"])
    }

    func testVsCodeRejectsDeepMutationPaths() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatDir = root.appendingPathComponent("ws-1/chatSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: chatDir, withIntermediateDirectories: true)

        let initial: [String: Any] = [
            "kind": 0,
            "v": [
                "sessionId": "vs-deep-path",
                "creationDate": 1_700_000_000_000,
                "requests": [
                    [
                        "timestamp": 1_700_000_000_000,
                        "message": ["text": "kept valid"],
                        "response": [
                            ["value": ["kind": "markdownContent", "content": ["value": "valid answer"]]]
                        ],
                    ],
                ],
            ],
        ]
        let deepMutation: [String: Any] = [
            "kind": 1,
            "k": Array(repeating: "nested", count: 65),
            "v": "too deep",
        ]
        let file = chatDir.appendingPathComponent("sess.jsonl")
        try ([try jsonLine(initial), try jsonLine(deepMutation)].joined(separator: "\n") + "\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = VsCodeAdapter(workspaceStorageDir: root.path)
        switch try await adapter.parseSessionInfo(locator: file.path) {
        case .failure(.malformedJSON):
            break
        case .failure(let failure):
            XCTFail("expected malformedJSON for over-deep mutation path, got \(failure)")
        case .success:
            XCTFail("over-deep VS Code mutation paths must be rejected before recursive replay")
        }
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

    func testGeminiAttachesAssistantTokenUsage() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatsDir = root.appendingPathComponent("tmp/proj/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)

        let session: [String: Any] = [
            "sessionId": "g-usage-1",
            "startTime": "2026-01-01T00:00:00.000Z",
            "lastUpdated": "2026-01-01T00:10:00.000Z",
            "messages": [
                ["type": "user", "timestamp": "2026-01-01T00:00:01.000Z", "content": [["text": "track usage"]]],
                [
                    "type": "gemini",
                    "timestamp": "2026-01-01T00:00:02.000Z",
                    "content": "usage tracked",
                    "tokens": [
                        "input": 800,
                        "output": 40,
                        "cached": 300,
                        "thoughts": 9,
                        "tool": 1,
                        "total": 850,
                    ],
                ],
            ],
        ]
        let file = chatsDir.appendingPathComponent("session-g-usage.json")
        try (try jsonLine(session)).write(to: file, atomically: true, encoding: .utf8)

        let adapter = GeminiCliAdapter(
            tmpRoot: root.appendingPathComponent("tmp").path,
            projectsFile: root.appendingPathComponent("projects.json").path
        )
        let streamed = try await drain(adapter, locator: file.path)

        XCTAssertEqual(streamed.map(\.role), [.user, .assistant])
        XCTAssertNil(streamed.first?.usage)
        XCTAssertEqual(
            streamed.last?.usage,
            TokenUsage(inputTokens: 500, outputTokens: 50, cacheReadTokens: 300, cacheCreationTokens: 0)
        )
    }

    func testGeminiParsesCurrentJsonlEventLogAndProjectRoot() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDir = root.appendingPathComponent("tmp/hash-001", isDirectory: true)
        let chatsDir = projectDir.appendingPathComponent("chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)
        try "/Users/test/gemini-jsonl".write(
            to: projectDir.appendingPathComponent(".project_root"),
            atomically: true,
            encoding: .utf8
        )

        let lines: [[String: Any]] = [
            [
                "kind": "main",
                "sessionId": "gemini-jsonl-1",
                "projectHash": "hash-001",
                "startTime": "2026-06-21T01:33:00.000Z",
                "lastUpdated": "2026-06-21T01:33:00.000Z",
            ],
            [
                "id": "m1",
                "timestamp": "2026-06-21T01:33:05.000Z",
                "type": "user",
                "content": [["text": "jsonl prompt"]],
            ],
            [
                "id": "m2",
                "timestamp": "2026-06-21T01:33:09.000Z",
                "type": "gemini",
                "content": "jsonl answer",
            ],
            [
                "$set": [
                    "lastUpdated": "2026-06-21T01:33:09.000Z",
                    "summary": "derived jsonl title",
                ],
            ],
        ]
        let file = chatsDir.appendingPathComponent("jsonl-session-1.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)
        try jsonLine(["originator": "claude-code"])
            .write(
                to: chatsDir.appendingPathComponent("jsonl-session-1.engram.json"),
                atomically: true,
                encoding: .utf8
            )

        let adapter = GeminiCliAdapter(
            tmpRoot: root.appendingPathComponent("tmp").path,
            projectsFile: root.appendingPathComponent("projects.json").path
        )
        let locators = try await adapter.listSessionLocators()
        XCTAssertEqual(
            locators.map { URL(fileURLWithPath: $0).standardizedFileURL.path },
            [file.standardizedFileURL.path]
        )
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: file.path))
        let streamed = try await drain(adapter, locator: file.path)

        XCTAssertEqual(info.id, "gemini-jsonl-1")
        XCTAssertEqual(info.cwd, "/Users/test/gemini-jsonl")
        XCTAssertEqual(info.endTime, "2026-06-21T01:33:09.000Z")
        XCTAssertEqual(info.userMessageCount, 1)
        XCTAssertEqual(info.assistantMessageCount, 1)
        XCTAssertEqual(streamed.map(\.content), ["jsonl prompt", "jsonl answer"])
    }

    func testGeminiIgnoresOversizedSidecar() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatsDir = root.appendingPathComponent("tmp/proj/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)

        let session: [String: Any] = [
            "sessionId": "gemini-sidecar-cap",
            "startTime": "2026-01-01T00:00:00.000Z",
            "lastUpdated": "2026-01-01T00:00:01.000Z",
            "messages": [
                ["type": "user", "timestamp": "2026-01-01T00:00:00.000Z", "content": "hello"],
            ],
        ]
        let file = chatsDir.appendingPathComponent("gemini-sidecar-cap.json")
        try jsonLine(session).write(to: file, atomically: true, encoding: .utf8)
        try """
        {"originator":"claude-code","parentSessionId":"\(String(repeating: "x", count: 600))"}
        """.write(
            to: chatsDir.appendingPathComponent("gemini-sidecar-cap.engram.json"),
            atomically: true,
            encoding: .utf8
        )

        let adapter = GeminiCliAdapter(
            tmpRoot: root.appendingPathComponent("tmp").path,
            projectsFile: root.appendingPathComponent("projects.json").path,
            limits: ParserLimits(maxFileBytes: 512)
        )
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: file.path))

        XCTAssertNil(info.agentRole)
        XCTAssertNil(info.parentSessionId)
    }

    // MARK: - Iflow

    func testIflowAttachesAssistantUsageMetadata() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDir = root.appendingPathComponent("projects/-Users-test-iflow-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let lines: [[String: Any]] = [
            [
                "uuid": "iflow-1",
                "sessionId": "iflow-usage-1",
                "timestamp": "2026-06-01T10:00:00.000Z",
                "type": "user",
                "message": [
                    "role": "user",
                    "content": "Track Iflow usage",
                ],
                "cwd": "/tmp/iflow-project",
            ],
            [
                "uuid": "iflow-2",
                "sessionId": "iflow-usage-1",
                "timestamp": "2026-06-01T10:00:01.000Z",
                "type": "assistant",
                "message": [
                    "role": "assistant",
                    "content": [
                        ["type": "text", "text": "Iflow usage tracked."],
                    ],
                    "usage": [
                        "input_tokens": 321,
                        "output_tokens": 65,
                    ],
                ],
                "cwd": "/tmp/iflow-project",
            ],
        ]
        let file = projectDir.appendingPathComponent("session-usage.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = IflowAdapter(projectsRoot: root.appendingPathComponent("projects").path)
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: file.path))
        let streamed = try await drain(adapter, locator: file.path)

        XCTAssertEqual(info.messageCount, streamed.count)
        XCTAssertEqual(streamed.map(\.role), [.user, .assistant])
        XCTAssertNil(streamed.first?.usage)
        XCTAssertEqual(streamed.last?.usage, TokenUsage(inputTokens: 321, outputTokens: 65))
    }

    func testIflowCombinesMultipartTextContent() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDir = root.appendingPathComponent("projects/-Users-test-iflow-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let lines: [[String: Any]] = [
            [
                "uuid": "iflow-multipart-1",
                "sessionId": "iflow-multipart-1",
                "timestamp": "2026-06-01T10:00:00.000Z",
                "type": "assistant",
                "message": [
                    "role": "assistant",
                    "content": [
                        ["type": "text", "text": "first"],
                        ["type": "text", "text": "second"],
                    ],
                ],
                "cwd": "/tmp/iflow-project",
            ],
        ]
        let file = projectDir.appendingPathComponent("session-multipart.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = IflowAdapter(projectsRoot: root.appendingPathComponent("projects").path)
        let streamed = try await drain(adapter, locator: file.path)

        XCTAssertEqual(streamed.map(\.content), ["first\n\nsecond"])
    }

    // MARK: - Kimi

    func testKimiAttachesWireTokenUsageToAssistantTurn() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root.appendingPathComponent("workspace-1/kimi-session-1", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let contextLines: [[String: Any]] = [
            ["role": "user", "content": "Track Kimi usage"],
            ["role": "assistant", "content": "Kimi usage tracked."],
        ]
        let contextFile = sessionDir.appendingPathComponent("context.jsonl")
        try contextLines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: contextFile, atomically: true, encoding: .utf8)

        let wireLines: [[String: Any]] = [
            ["timestamp": 1_700_000_000.0, "message": ["type": "TurnBegin"]],
            [
                "timestamp": 1_700_000_001.0,
                "message": [
                    "type": "StatusUpdate",
                    "payload": [
                        "token_usage": [
                            "input_other": 123,
                            "output": 45,
                            "input_cache_read": 67,
                            "input_cache_creation": 8,
                        ],
                    ],
                ],
            ],
            [
                "timestamp": 1_700_000_001.5,
                "message": [
                    "type": "StatusUpdate",
                    "payload": [
                        "token_usage": [
                            "input_other": 10,
                            "output": 5,
                            "input_cache_read": 3,
                            "input_cache_creation": 2,
                        ],
                    ],
                ],
            ],
            ["timestamp": 1_700_000_002.0, "message": ["type": "TurnEnd"]],
        ]
        let wireFile = sessionDir.appendingPathComponent("wire.jsonl")
        try wireLines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: wireFile, atomically: true, encoding: .utf8)

        let adapter = KimiAdapter(
            sessionsRoot: root.path,
            kimiJsonPath: root.appendingPathComponent("kimi.json").path
        )
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: contextFile.path))
        let streamed = try await drain(adapter, locator: contextFile.path)

        XCTAssertEqual(info.messageCount, streamed.count)
        XCTAssertEqual(streamed.map(\.role), [.user, .assistant])
        XCTAssertNil(streamed.first?.usage)
        XCTAssertEqual(
            streamed.last?.usage,
            TokenUsage(inputTokens: 133, outputTokens: 50, cacheReadTokens: 70, cacheCreationTokens: 10)
        )
    }

    func testKimiReadsCurrentContextRotationAndArrayTextContent() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root.appendingPathComponent("workspace-1/kimi-session-rotation", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let contextFile = sessionDir.appendingPathComponent("context.jsonl")
        try (try jsonLine(["role": "user", "content": "main question"]) + "\n")
            .write(to: contextFile, atomically: true, encoding: .utf8)
        let shardLines: [[String: Any]] = [
            [
                "role": "assistant",
                "content": [
                    ["type": "think", "think": "private reasoning", "encrypted": NSNull()],
                    ["type": "text", "text": "visible answer"],
                ],
            ],
            [
                "role": "user",
                "content": [["type": "text", "text": "follow-up from shard"]],
            ],
        ]
        try shardLines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: sessionDir.appendingPathComponent("context_1.jsonl"), atomically: true, encoding: .utf8)

        let adapter = KimiAdapter(
            sessionsRoot: root.path,
            kimiJsonPath: root.appendingPathComponent("kimi.json").path
        )
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: contextFile.path))
        let streamed = try await drain(adapter, locator: contextFile.path)

        XCTAssertEqual(info.userMessageCount, 2)
        XCTAssertEqual(info.assistantMessageCount, 1)
        XCTAssertEqual(streamed.map(\.content), ["main question", "visible answer", "follow-up from shard"])
    }

    // Audit KIMI-001: agentic turns must preserve tools and bind one wire turn per user turn.
    func testKimiPreservesAgenticTurnToolsAndTimestamps_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root.appendingPathComponent("workspace-1/kimi-agentic", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let contextLines: [[String: Any]] = [
            ["role": "user", "content": "Read the file"],
            [
                "role": "assistant",
                "content": "",
                "tool_calls": [[
                    "id": "call-1",
                    "type": "function",
                    "function": [
                        "name": "read_file",
                        "arguments": #"{"path":"README.md"}"#,
                    ],
                ]],
            ],
            ["role": "tool", "tool_call_id": "call-1", "content": "README contents"],
            ["role": "assistant", "content": "The file is ready."],
            ["role": "user", "content": "Summarize it"],
            ["role": "assistant", "content": "Short summary."],
        ]
        let contextFile = sessionDir.appendingPathComponent("context.jsonl")
        try contextLines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: contextFile, atomically: true, encoding: .utf8)

        let firstUsage = TokenUsage(inputTokens: 10, outputTokens: 2, cacheReadTokens: 3, cacheCreationTokens: 4)
        let secondUsage = TokenUsage(inputTokens: 20, outputTokens: 5, cacheReadTokens: 6, cacheCreationTokens: 7)
        let wireLines: [[String: Any]] = [
            ["timestamp": 1_700_000_000.0, "message": ["type": "TurnBegin"]],
            [
                "timestamp": 1_700_000_001.0,
                "message": [
                    "type": "StatusUpdate",
                    "payload": [
                        "token_usage": [
                            "input_other": firstUsage.inputTokens,
                            "output": firstUsage.outputTokens,
                            "input_cache_read": firstUsage.cacheReadTokens ?? 0,
                            "input_cache_creation": firstUsage.cacheCreationTokens ?? 0,
                        ],
                    ],
                ],
            ],
            ["timestamp": 1_700_000_002.0, "message": ["type": "TurnEnd"]],
            ["timestamp": 1_700_000_010.0, "message": ["type": "TurnBegin"]],
            [
                "timestamp": 1_700_000_011.0,
                "message": [
                    "type": "StatusUpdate",
                    "payload": [
                        "token_usage": [
                            "input_other": secondUsage.inputTokens,
                            "output": secondUsage.outputTokens,
                            "input_cache_read": secondUsage.cacheReadTokens ?? 0,
                            "input_cache_creation": secondUsage.cacheCreationTokens ?? 0,
                        ],
                    ],
                ],
            ],
            ["timestamp": 1_700_000_012.0, "message": ["type": "TurnEnd"]],
        ]
        try wireLines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: sessionDir.appendingPathComponent("wire.jsonl"), atomically: true, encoding: .utf8)

        let adapter = KimiAdapter(
            sessionsRoot: root.path,
            kimiJsonPath: root.appendingPathComponent("kimi.json").path
        )
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: contextFile.path))
        let streamed = try await drain(adapter, locator: contextFile.path)

        XCTAssertEqual(info.messageCount, 6)
        XCTAssertEqual(info.userMessageCount, 2)
        XCTAssertEqual(info.assistantMessageCount, 3)
        XCTAssertEqual(info.toolMessageCount, 1)
        XCTAssertEqual(streamed.map(\.role), [.user, .assistant, .tool, .assistant, .user, .assistant])
        guard streamed.count == 6 else { return }
        XCTAssertEqual(
            streamed[1].toolCalls,
            [NormalizedToolCall(name: "read_file", input: #"{"path":"README.md"}"#)]
        )
        XCTAssertEqual(streamed[2].content, "README contents")
        XCTAssertEqual(
            streamed.map(\.timestamp),
            [
                Phase4AdapterSupport.isoFromSeconds(1_700_000_000),
                Phase4AdapterSupport.isoFromSeconds(1_700_000_002),
                Phase4AdapterSupport.isoFromSeconds(1_700_000_002),
                Phase4AdapterSupport.isoFromSeconds(1_700_000_002),
                Phase4AdapterSupport.isoFromSeconds(1_700_000_010),
                Phase4AdapterSupport.isoFromSeconds(1_700_000_012),
            ]
        )
        XCTAssertNil(streamed[1].usage)
        XCTAssertNil(streamed[2].usage)
        XCTAssertEqual(streamed[3].usage, firstUsage)
        XCTAssertEqual(streamed[5].usage, secondUsage)
    }

    // Audit KIMI-002: historical sessions must resolve cwd from the workspace directory hash.
    func testKimiResolvesHistoricalSessionCwdFromWorkspaceHash_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let cases = [
            (workspace: "6530f9eb448d96e7552a3c3a29b6cd2b", session: "old-local", cwd: "/repo"),
            (workspace: "ssh_3e8bdf0b7c3f317d367df8cc16095151", session: "old-remote", cwd: "/repo/remote"),
        ]
        for item in cases {
            let sessionDir = root.appendingPathComponent("\(item.workspace)/\(item.session)", isDirectory: true)
            try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
            try (try jsonLine(["role": "user", "content": "Historical session"]) + "\n")
                .write(to: sessionDir.appendingPathComponent("context.jsonl"), atomically: true, encoding: .utf8)
        }
        let kimiJSON: [String: Any] = [
            "work_dirs": [
                ["path": "/repo", "kaos": "local", "last_session_id": "new-local"],
                ["path": "/repo/remote", "kaos": "ssh", "last_session_id": "new-remote"],
            ],
        ]
        let kimiJsonURL = root.appendingPathComponent("kimi.json")
        try JSONSerialization.data(withJSONObject: kimiJSON)
            .write(to: kimiJsonURL)

        let adapter = KimiAdapter(sessionsRoot: root.path, kimiJsonPath: kimiJsonURL.path)
        let locators = try await adapter.listSessionLocators()

        XCTAssertEqual(locators.count, 2)
        for locator in locators {
            let workspace = URL(fileURLWithPath: locator)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .lastPathComponent
            let expected = try XCTUnwrap(cases.first { $0.workspace == workspace })
            let info = try sessionInfo(await adapter.parseSessionInfo(locator: locator))
            XCTAssertEqual(info.cwd, expected.cwd)
        }
    }

    // MARK: - Qwen

    // Runtime-debt repro: Qwen slash-command telemetry carries a session ID but
    // no visible conversation and must terminate cleanly instead of retrying.
    func testQwenSlashCommandOnlyIsTerminalNoVisibleMessages_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatsDir = root.appendingPathComponent("project-empty/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)

        let lines: [[String: Any]] = [
            [
                "type": "system",
                "subtype": "slash_command",
                "sessionId": "qwen-slash-only",
                "timestamp": "2026-07-17T00:00:00.000Z",
            ],
            [
                "type": "system",
                "subtype": "slash_command",
                "sessionId": "qwen-slash-only",
                "timestamp": "2026-07-17T00:00:01.000Z",
            ],
        ]
        let file = chatsDir.appendingPathComponent("slash-only.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = QwenAdapter(projectsRoot: root.path)
        let failure = try parseFailure(await adapter.parseSessionInfo(locator: file.path))

        XCTAssertEqual(failure, .noVisibleMessages)
    }

    func testQwenAttachesAssistantUsageMetadata() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatsDir = root.appendingPathComponent("project-1/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)

        let lines: [[String: Any]] = [
            [
                "type": "user",
                "sessionId": "qwen-usage-1",
                "cwd": "/tmp/qwen-project",
                "timestamp": "2026-06-01T10:00:00.000Z",
                "message": [
                    "role": "user",
                    "parts": [["text": "Summarize token accounting"]],
                ],
            ],
            [
                "type": "assistant",
                "sessionId": "qwen-usage-1",
                "cwd": "/tmp/qwen-project",
                "timestamp": "2026-06-01T10:00:01.000Z",
                "message": [
                    "role": "model",
                    "parts": [["text": "Token accounting summarized."]],
                ],
                "usageMetadata": [
                    "promptTokenCount": 17_761,
                    "candidatesTokenCount": 2_473,
                    "cachedContentTokenCount": 16_627,
                    "totalTokenCount": 20_234,
                    "thoughtsTokenCount": 22,
                ],
            ],
        ]
        let file = chatsDir.appendingPathComponent("qwen-usage.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = QwenAdapter(projectsRoot: root.path)
        let streamed = try await drain(adapter, locator: file.path)

        XCTAssertEqual(streamed.map(\.role), [.user, .assistant])
        XCTAssertNil(streamed.first?.usage)
        XCTAssertEqual(
            streamed.last?.usage,
            TokenUsage(inputTokens: 17_761, outputTokens: 2_473, cacheReadTokens: 16_627, cacheCreationTokens: 0)
        )
    }

    func testQwenUsesTelemetryUsageWhenAssistantUsageMetadataIsMissing() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatsDir = root.appendingPathComponent("project-1/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)

        let lines: [[String: Any]] = [
            [
                "type": "user",
                "sessionId": "qwen-telemetry-1",
                "cwd": "/tmp/qwen-project",
                "timestamp": "2026-06-01T10:00:00.000Z",
                "message": [
                    "role": "user",
                    "parts": [["text": "Use telemetry token accounting"]],
                ],
            ],
            [
                "type": "system",
                "subtype": "ui_telemetry",
                "sessionId": "qwen-telemetry-1",
                "cwd": "/tmp/qwen-project",
                "timestamp": "2026-06-01T10:00:01.000Z",
                "systemPayload": [
                    "uiEvent": [
                        "event.name": "qwen-code.api_response",
                        "input_token_count": 1_111,
                        "output_token_count": 222,
                        "cached_content_token_count": 333,
                        "total_token_count": 1_333,
                    ],
                ],
            ],
            [
                "type": "assistant",
                "sessionId": "qwen-telemetry-1",
                "cwd": "/tmp/qwen-project",
                "timestamp": "2026-06-01T10:00:02.000Z",
                "message": [
                    "role": "model",
                    "parts": [["text": "Telemetry token accounting used."]],
                ],
            ],
        ]
        let file = chatsDir.appendingPathComponent("qwen-telemetry.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = QwenAdapter(projectsRoot: root.path)
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: file.path))
        let streamed = try await drain(adapter, locator: file.path)

        XCTAssertEqual(info.messageCount, streamed.count)
        XCTAssertEqual(streamed.map(\.role), [.user, .assistant])
        XCTAssertNil(streamed.first?.usage)
        XCTAssertEqual(
            streamed.last?.usage,
            TokenUsage(inputTokens: 1_111, outputTokens: 222, cacheReadTokens: 333, cacheCreationTokens: 0)
        )
    }

    func testQwenCombinesMultipartTextContent() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatsDir = root.appendingPathComponent("project-1/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)

        let lines: [[String: Any]] = [
            [
                "type": "assistant",
                "sessionId": "qwen-multipart-1",
                "cwd": "/tmp/qwen-project",
                "timestamp": "2026-06-01T10:00:00.000Z",
                "message": [
                    "role": "model",
                    "parts": [
                        ["text": "first"],
                        ["text": "second"],
                    ],
                ],
            ],
        ]
        let file = chatsDir.appendingPathComponent("qwen-multipart.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = QwenAdapter(projectsRoot: root.path)
        let streamed = try await drain(adapter, locator: file.path)

        XCTAssertEqual(streamed.map(\.content), ["first\n\nsecond"])
    }

    func testQwenSkipsThoughtTextParts() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatsDir = root.appendingPathComponent("project-1/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)

        let lines: [[String: Any]] = [
            [
                "type": "assistant",
                "sessionId": "qwen-thought-1",
                "cwd": "/tmp/qwen-project",
                "timestamp": "2026-06-01T10:00:00.000Z",
                "message": [
                    "role": "model",
                    "parts": [
                        ["text": "private reasoning", "thought": true],
                        ["text": "final answer"],
                    ],
                ],
            ],
        ]
        let file = chatsDir.appendingPathComponent("qwen-thought.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = QwenAdapter(projectsRoot: root.path)
        let streamed = try await drain(adapter, locator: file.path)

        XCTAssertEqual(streamed.map(\.content), ["final answer"])
    }

    // Audit SRC-QWEN-001: functionCall/tool_result must surface as assistant toolCalls + tool messages.
    func testQwenPreservesFunctionCallsAndToolResults_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatsDir = root.appendingPathComponent("project-tools/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)

        let lines: [[String: Any]] = [
            [
                "type": "user",
                "sessionId": "qwen-tools-1",
                "cwd": "/tmp/qwen-tools",
                "timestamp": "2026-07-19T10:00:00.000Z",
                "message": [
                    "role": "user",
                    "parts": [["text": "List the directory"]],
                ],
            ],
            [
                "type": "assistant",
                "sessionId": "qwen-tools-1",
                "cwd": "/tmp/qwen-tools",
                "timestamp": "2026-07-19T10:00:01.000Z",
                "model": "qwen3.5-plus",
                "message": [
                    "role": "model",
                    "parts": [
                        ["text": "Checking the directory."],
                        [
                            "functionCall": [
                                "id": "call_list_1",
                                "name": "list_directory",
                                "args": ["path": "/tmp/qwen-tools"],
                            ],
                        ],
                    ],
                ],
            ],
            [
                "type": "tool_result",
                "sessionId": "qwen-tools-1",
                "cwd": "/tmp/qwen-tools",
                "timestamp": "2026-07-19T10:00:02.000Z",
                "toolCallResult": [
                    "callId": "call_list_1",
                    "status": "success",
                    "resultDisplay": "main.swift\nREADME.md",
                ],
                "message": [
                    "role": "user",
                    "parts": [[
                        "functionResponse": [
                            "id": "call_list_1",
                            "name": "list_directory",
                            "response": ["output": "main.swift\nREADME.md"],
                        ],
                    ]],
                ],
            ],
        ]
        let file = chatsDir.appendingPathComponent("qwen-tools.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = QwenAdapter(projectsRoot: root.path)
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: file.path))
        let streamed = try await drain(adapter, locator: file.path)

        XCTAssertEqual(info.userMessageCount, 1)
        XCTAssertEqual(info.assistantMessageCount, 1)
        XCTAssertEqual(info.toolMessageCount, 1)
        XCTAssertEqual(info.messageCount, 3)
        XCTAssertEqual(streamed.map(\.role), [.user, .assistant, .tool])
        XCTAssertEqual(streamed[0].content, "List the directory")
        XCTAssertEqual(streamed[1].content, "Checking the directory.")
        XCTAssertEqual(
            streamed[1].toolCalls,
            [NormalizedToolCall(name: "list_directory", input: "{\"path\":\"/tmp/qwen-tools\"}")]
        )
        XCTAssertEqual(streamed[2].content, "main.swift\nREADME.md")
        XCTAssertEqual(streamed[2].timestamp, "2026-07-19T10:00:02.000Z")
    }

    // MARK: - Cline

    func testClineListsLegacyClaudeMessagesWhenUiMessagesMissing() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let taskDir = root.appendingPathComponent("legacy-task", isDirectory: true)
        try FileManager.default.createDirectory(at: taskDir, withIntermediateDirectories: true)
        let legacyFile = taskDir.appendingPathComponent("claude_messages.json")
        let messages: [[String: Any]] = [
            [
                "ts": 1_771_392_000_000,
                "type": "say",
                "say": "task",
                "text": "legacy task",
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: messages, options: [.withoutEscapingSlashes])
        try data.write(to: legacyFile)

        let adapter = ClineAdapter(tasksRoot: root.path)
        let locators = try await adapter.listSessionLocators()
        XCTAssertEqual(
            locators.map { URL(fileURLWithPath: $0).standardizedFileURL.path },
            [legacyFile.standardizedFileURL.path]
        )
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: legacyFile.path))

        XCTAssertEqual(info.id, "legacy-task")
        XCTAssertEqual(info.summary, "legacy task")
    }

    func testClineRejectsPrimaryWorkspaceLabelAsCwd() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let taskDir = root.appendingPathComponent("primary-task", isDirectory: true)
        try FileManager.default.createDirectory(at: taskDir, withIntermediateDirectories: true)
        let file = taskDir.appendingPathComponent("ui_messages.json")
        let messages: [[String: Any]] = [
            [
                "ts": 1_771_392_000_000,
                "type": "say",
                "say": "api_req_started",
                "text": ##"{"request":"# Current Working Directory (Primary: workspace-a) Files\n- file.ts"}"##,
            ],
            [
                "ts": 1_771_392_001_000,
                "type": "say",
                "say": "task",
                "text": "hello",
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: messages, options: [.withoutEscapingSlashes])
        try data.write(to: file)

        let adapter = ClineAdapter(tasksRoot: root.path)
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: file.path))

        XCTAssertEqual(info.cwd, "")
    }


    // MARK: - Codex

    func testCodexMessageCountIncludesFunctionCallOutput_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-codex-fco.jsonl")
        let lines: [[String: Any]] = [
            ["timestamp": "2026-06-01T10:00:00.000Z", "type": "session_meta",
             "payload": ["id": "codex-fco-1", "timestamp": "2026-06-01T10:00:00.000Z", "cwd": "/tmp/x", "originator": "codex"]],
            ["timestamp": "2026-06-01T10:00:01.000Z", "type": "response_item",
             "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Read a.ts"]]]],
            ["timestamp": "2026-06-01T10:00:02.000Z", "type": "response_item",
             "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Reading."]]]],
            ["timestamp": "2026-06-01T10:00:03.000Z", "type": "response_item",
             "payload": ["type": "function_call", "name": "read_file", "arguments": "{\"path\":\"a.ts\"}"]],
            ["timestamp": "2026-06-01T10:00:04.000Z", "type": "response_item",
             "payload": ["type": "function_call_output", "output": "contents of a.ts"]],
        ]
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)
        let adapter = CodexAdapter(sessionsRoot: root.path)
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: file.path))
        let streamed = try await drain(adapter, locator: file.path)
        XCTAssertEqual(streamed.filter { $0.role == .tool }.count, 2)
        XCTAssertEqual(info.toolMessageCount, 2)
        XCTAssertEqual(info.messageCount, 4)
        XCTAssertEqual(info.messageCount, streamed.count)
    }

    // Audit ADAPTER-CODEX-001: custom tool records must stream and count as tool messages.
    func testCodexCustomToolCallAndOutputAreStreamedAndCounted_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-codex-custom-tool.jsonl")
        let lines: [[String: Any]] = [
            ["timestamp": "2026-06-01T10:00:00.000Z", "type": "session_meta",
             "payload": ["id": "codex-custom-tool-1", "timestamp": "2026-06-01T10:00:00.000Z", "cwd": "/tmp/x"]],
            ["timestamp": "2026-06-01T10:00:01.000Z", "type": "response_item",
             "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Apply the patch"]]]],
            ["timestamp": "2026-06-01T10:00:02.000Z", "type": "response_item",
             "payload": [
                 "type": "custom_tool_call",
                 "call_id": "call-1",
                 "name": "apply_patch",
                 "status": "completed",
                 "input": "*** Begin Patch\n*** End Patch",
             ]],
            ["timestamp": "2026-06-01T10:00:03.000Z", "type": "response_item",
             "payload": ["type": "custom_tool_call_output", "call_id": "call-1", "output": "Success."]],
        ]
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = CodexAdapter(sessionsRoot: root.path)
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: file.path))
        let streamed = try await drain(adapter, locator: file.path)

        XCTAssertEqual(streamed.map(\.role), [.user, .tool, .tool])
        XCTAssertEqual(info.userMessageCount, 1)
        XCTAssertEqual(info.assistantMessageCount, 0)
        XCTAssertEqual(info.toolMessageCount, 2)
        XCTAssertEqual(info.systemMessageCount, 0)
        XCTAssertEqual(info.messageCount, 3)
        XCTAssertEqual(info.messageCount, streamed.count)
        guard streamed.count == 3 else { return }
        XCTAssertTrue(streamed[1].content.contains("apply_patch"))
        XCTAssertTrue(streamed[1].content.contains("*** Begin Patch\n*** End Patch"))
        XCTAssertEqual(
            streamed[1].toolCalls,
            [NormalizedToolCall(name: "apply_patch", input: "*** Begin Patch\n*** End Patch")]
        )
        XCTAssertEqual(streamed[2].content, "Success.")
    }

    // Audit ADAPTER-CODEX-002: duplicate adjacent token snapshots must not inflate usage.
    func testCodexDuplicateTokenCountSnapshotIsNotDoubleCounted_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-codex-duplicate-usage.jsonl")
        let sessionMeta: [String: Any] = [
            "timestamp": "2026-06-01T10:00:00.000Z",
            "type": "session_meta",
            "payload": [
                "id": "codex-duplicate-usage-1",
                "timestamp": "2026-06-01T10:00:00.000Z",
                "cwd": "/tmp/codex-usage",
            ],
        ]
        let user: [String: Any] = [
            "timestamp": "2026-06-01T10:00:01.000Z",
            "type": "response_item",
            "payload": [
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": "Track Codex usage"]],
            ],
        ]
        let assistant: [String: Any] = [
            "timestamp": "2026-06-01T10:00:02.000Z",
            "type": "response_item",
            "payload": [
                "type": "message",
                "role": "assistant",
                "content": [["type": "output_text", "text": "Codex usage tracked."]],
            ],
        ]
        let usageA: [String: Int] = [
            "input_tokens": 1_000,
            "cached_input_tokens": 400,
            "output_tokens": 25,
            "reasoning_output_tokens": 5,
            "total_tokens": 1_025,
        ]
        let totalA: [String: Int] = usageA
        var totalAWithDifferentReasoning = totalA
        totalAWithDifferentReasoning["reasoning_output_tokens"] = 6

        func tokenCount(
            timestamp: String,
            last: [String: Int],
            total: [String: Int]?
        ) -> [String: Any] {
            var info: [String: Any] = ["last_token_usage": last]
            if let total {
                info["total_token_usage"] = total
            }
            return [
                "timestamp": timestamp,
                "type": "event_msg",
                "payload": ["type": "token_count", "info": info],
            ]
        }

        let snapshotA = tokenCount(
            timestamp: "2026-06-01T10:00:03.000Z",
            last: usageA,
            total: totalA
        )
        let duplicateSnapshotA = tokenCount(
            timestamp: "2026-06-01T10:00:04.000Z",
            last: usageA,
            total: totalA
        )
        let changedTotalSnapshotA = tokenCount(
            timestamp: "2026-06-01T10:00:05.000Z",
            last: usageA,
            total: totalAWithDifferentReasoning
        )
        let noTotalSnapshotA = tokenCount(
            timestamp: "2026-06-01T10:00:06.000Z",
            last: usageA,
            total: nil
        )
        let unsupportedResponseItem: [String: Any] = [
            "timestamp": "2026-06-01T10:00:07.000Z",
            "type": "response_item",
            "payload": ["type": "reasoning", "summary": []],
        ]
        let noTotalSnapshotAfterBoundary = tokenCount(
            timestamp: "2026-06-01T10:00:08.000Z",
            last: usageA,
            total: nil
        )
        let snapshotB = tokenCount(
            timestamp: "2026-06-01T10:00:09.000Z",
            last: [
                "input_tokens": 300,
                "cached_input_tokens": 100,
                "output_tokens": 7,
                "reasoning_output_tokens": 2,
                "total_tokens": 307,
            ],
            total: [
                "input_tokens": 1_300,
                "cached_input_tokens": 500,
                "output_tokens": 32,
                "reasoning_output_tokens": 7,
                "total_tokens": 1_332,
            ]
        )
        try [
            sessionMeta,
            user,
            assistant,
            snapshotA,
            duplicateSnapshotA,
            changedTotalSnapshotA,
            noTotalSnapshotA,
            unsupportedResponseItem,
            noTotalSnapshotAfterBoundary,
            snapshotB,
        ]
        .map { try jsonLine($0) }
        .joined(separator: "\n")
        .appending("\n")
        .write(to: file, atomically: true, encoding: .utf8)

        let adapter = CodexAdapter(sessionsRoot: root.path)
        let streamed = try await drain(adapter, locator: file.path)

        XCTAssertEqual(streamed.map(\.role), [.user, .assistant])
        XCTAssertNil(streamed.first?.usage)
        XCTAssertEqual(
            streamed.last?.usage,
            TokenUsage(inputTokens: 2_600, outputTokens: 107, cacheReadTokens: 1_700, cacheCreationTokens: 0)
        )
    }

    // Audit ADAPTER-CODEX-002: token snapshot deduplication must be scoped to one read.
    func testCodexTokenCountSnapshotDeduplicationIsInvocationLocal_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstFile = root.appendingPathComponent("rollout-codex-usage-first.jsonl")
        let secondFile = root.appendingPathComponent("rollout-codex-usage-second.jsonl")
        let snapshot: [String: Any] = [
            "timestamp": "2026-06-01T10:00:02.000Z",
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "info": [
                    "last_token_usage": [
                        "input_tokens": 1_000,
                        "cached_input_tokens": 400,
                        "output_tokens": 25,
                        "reasoning_output_tokens": 5,
                        "total_tokens": 1_025,
                    ],
                    "total_token_usage": [
                        "input_tokens": 1_000,
                        "cached_input_tokens": 400,
                        "output_tokens": 25,
                        "reasoning_output_tokens": 5,
                        "total_tokens": 1_025,
                    ],
                ],
            ],
        ]
        let assistant: [String: Any] = [
            "timestamp": "2026-06-01T10:00:01.000Z",
            "type": "response_item",
            "payload": [
                "type": "message",
                "role": "assistant",
                "content": [["type": "output_text", "text": "Codex usage tracked."]],
            ],
        ]
        let firstMeta: [String: Any] = [
            "timestamp": "2026-06-01T10:00:00.000Z",
            "type": "session_meta",
            "payload": ["id": "codex-usage-first", "cwd": "/tmp/codex-usage"],
        ]
        let secondMeta: [String: Any] = [
            "timestamp": "2026-06-01T10:00:00.000Z",
            "type": "session_meta",
            "payload": ["id": "codex-usage-second", "cwd": "/tmp/codex-usage"],
        ]
        try [firstMeta, assistant, snapshot]
            .map { try jsonLine($0) }
            .joined(separator: "\n")
            .appending("\n")
            .write(to: firstFile, atomically: true, encoding: .utf8)
        try [secondMeta, snapshot, assistant]
            .map { try jsonLine($0) }
            .joined(separator: "\n")
            .appending("\n")
            .write(to: secondFile, atomically: true, encoding: .utf8)

        let adapter = CodexAdapter(sessionsRoot: root.path)
        let expected = TokenUsage(
            inputTokens: 600,
            outputTokens: 25,
            cacheReadTokens: 400,
            cacheCreationTokens: 0
        )
        let firstStreamed = try await drain(adapter, locator: firstFile.path)
        let secondStreamed = try await drain(adapter, locator: secondFile.path)

        XCTAssertEqual(firstStreamed.map(\.usage), [expected])
        XCTAssertEqual(secondStreamed.map(\.usage), [expected])
    }

    func testCodexTailIndexingConformance_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-codex-tail.jsonl")
        let initial: [[String: Any]] = [
            ["timestamp": "2026-06-01T10:00:00.000Z", "type": "session_meta",
             "payload": ["id": "codex-tail-1", "timestamp": "2026-06-01T10:00:00.000Z", "cwd": "/tmp/t"]],
            ["timestamp": "2026-06-01T10:00:01.000Z", "type": "response_item",
             "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "hello"]]]],
            ["timestamp": "2026-06-01T10:00:02.000Z", "type": "response_item",
             "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "hi"]]]],
        ]
        try initial.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)
        let adapter = CodexAdapter(sessionsRoot: root.path)
        XCTAssertTrue(adapter is any TailIndexingSessionAdapter)
        let scan = try sessionInfo(await adapter.scanForIndexing(locator: file.path))
        XCTAssertEqual(scan.messages.count, 2)
        let offset = try XCTUnwrap(scan.checkpointParsedOffset)
        let boundary = try XCTUnwrap(scan.checkpointBoundaryHash)
        let tailLine: [String: Any] = [
            "timestamp": "2026-06-01T10:00:03.000Z", "type": "response_item",
            "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "follow-up"]]],
        ]
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((try jsonLine(tailLine) + "\n").utf8))
        switch try await adapter.scanTailForIndexing(locator: file.path, from: offset, expectedBoundaryHash: boundary) {
        case .success(let tail):
            XCTAssertEqual(tail.messages.count, 1)
            XCTAssertEqual(tail.messages.first?.content, "follow-up")
        case .fallback: XCTFail("expected success")
        case .failure(let f): XCTFail("\(f)")
        }
    }

    func testCodexAttachesTokenCountEventUsageToPreviousAssistantMessage() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-codex-usage.jsonl")

        let lines: [[String: Any]] = [
            [
                "timestamp": "2026-06-01T10:00:00.000Z",
                "type": "session_meta",
                "payload": [
                    "id": "codex-token-count-1",
                    "timestamp": "2026-06-01T10:00:00.000Z",
                    "cwd": "/tmp/codex-usage",
                    "originator": "codex",
                    "model_provider": "openai",
                ],
            ],
            [
                "timestamp": "2026-06-01T10:00:01.000Z",
                "type": "response_item",
                "payload": [
                    "type": "message",
                    "role": "user",
                    "content": [["type": "input_text", "text": "Track Codex usage"]],
                ],
            ],
            [
                "timestamp": "2026-06-01T10:00:02.000Z",
                "type": "response_item",
                "payload": [
                    "type": "message",
                    "role": "assistant",
                    "content": [["type": "output_text", "text": "Codex usage tracked."]],
                ],
            ],
            [
                "timestamp": "2026-06-01T10:00:03.000Z",
                "type": "event_msg",
                "payload": [
                    "type": "token_count",
                    "info": [
                        "last_token_usage": [
                            "input_tokens": 1_000,
                            "cached_input_tokens": 400,
                            "output_tokens": 25,
                            "reasoning_output_tokens": 5,
                            "total_tokens": 1_025,
                        ],
                    ],
                ],
            ],
        ]
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = CodexAdapter(sessionsRoot: root.path)
        let streamed = try await drain(adapter, locator: file.path)

        XCTAssertEqual(streamed.map(\.role), [.user, .assistant])
        XCTAssertNil(streamed.first?.usage)
        XCTAssertEqual(
            streamed.last?.usage,
            TokenUsage(inputTokens: 600, outputTokens: 25, cacheReadTokens: 400, cacheCreationTokens: 0)
        )
    }

    func testCodexCombinesMultipartTextContent() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-codex-multipart.jsonl")

        let lines: [[String: Any]] = [
            [
                "timestamp": "2026-06-01T10:00:00.000Z",
                "type": "session_meta",
                "payload": [
                    "id": "codex-multipart-1",
                    "timestamp": "2026-06-01T10:00:00.000Z",
                    "cwd": "/tmp/codex-multipart",
                ],
            ],
            [
                "timestamp": "2026-06-01T10:00:01.000Z",
                "type": "response_item",
                "payload": [
                    "type": "message",
                    "role": "assistant",
                    "content": [
                        ["type": "output_text", "text": "first"],
                        ["type": "output_text", "text": "second"],
                    ],
                ],
            ],
        ]
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = CodexAdapter(sessionsRoot: root.path)
        let streamed = try await drain(adapter, locator: file.path)

        XCTAssertEqual(streamed.map(\.content), ["first\n\nsecond"])
    }

    func testCodexUsesTurnContextModelWhenResponseItemModelMissing() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-codex-turn-context-model.jsonl")

        let lines: [[String: Any]] = [
            [
                "timestamp": "2026-07-01T10:00:00.000Z",
                "type": "session_meta",
                "payload": [
                    "id": "codex-turn-context-model",
                    "timestamp": "2026-07-01T10:00:00.000Z",
                    "cwd": "/tmp/codex-turn-context-model",
                    "model_provider": "openai",
                ],
            ],
            [
                "timestamp": "2026-07-01T10:00:00.100Z",
                "type": "turn_context",
                "payload": [
                    "model": "gpt-5.5",
                ],
            ],
            [
                "timestamp": "2026-07-01T10:00:01.000Z",
                "type": "response_item",
                "payload": [
                    "type": "message",
                    "role": "user",
                    "content": [["type": "input_text", "text": "Use turn_context model"]],
                ],
            ],
            [
                "timestamp": "2026-07-01T10:00:02.000Z",
                "type": "response_item",
                "payload": [
                    "type": "message",
                    "role": "assistant",
                    "content": [["type": "output_text", "text": "Using turn_context model."]],
                ],
            ],
        ]
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = CodexAdapter(sessionsRoot: root.path)
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: file.path))

        XCTAssertEqual(info.model, "gpt-5.5")
    }

    func testCodexDoesNotUseModelProviderAsFallbackModel() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-codex-model-provider-only.jsonl")

        let lines: [[String: Any]] = [
            [
                "timestamp": "2026-07-01T11:00:00.000Z",
                "type": "session_meta",
                "payload": [
                    "id": "codex-model-provider-only",
                    "timestamp": "2026-07-01T11:00:00.000Z",
                    "cwd": "/tmp/codex-model-provider-only",
                    "model_provider": "openai",
                ],
            ],
            [
                "timestamp": "2026-07-01T11:00:01.000Z",
                "type": "response_item",
                "payload": [
                    "type": "message",
                    "role": "user",
                    "content": [["type": "input_text", "text": "No model label here"]],
                ],
            ],
        ]
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = CodexAdapter(sessionsRoot: root.path)
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: file.path))

        XCTAssertNil(info.model)
    }

    // MARK: - Claude Code

    // Runtime-debt repro: Claude metadata-only JSONL is valid session state and
    // must use the existing terminal no-visible contract rather than malformed.
    func testClaudeCodeMetadataOnlyIsTerminalNoVisibleMessages_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDir = root.appendingPathComponent("-Users-test-metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let lines: [[String: Any]] = [
            ["type": "system", "sessionId": "cc-metadata-only", "timestamp": "2026-07-17T00:00:00Z"],
            ["type": "mode", "sessionId": "cc-metadata-only", "mode": "default"],
            ["type": "permission-mode", "sessionId": "cc-metadata-only", "mode": "acceptEdits"],
            ["type": "last-prompt", "sessionId": "cc-metadata-only", "prompt": ""],
        ]
        let file = projectDir.appendingPathComponent("metadata-only.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = ClaudeCodeAdapter(projectsRoot: root.path)
        let failure = try parseFailure(await adapter.parseSessionInfo(locator: file.path))

        XCTAssertEqual(failure, .noVisibleMessages)
    }

    // Claude can leave standalone file-history snapshots that are valid JSONL
    // but have neither a session ID nor any visible messages. They are not a
    // damaged transcript and should use the terminal no-visible contract.
    func testClaudeCodeFileHistorySnapshotsWithoutSessionIdAreTerminalNoVisibleMessages_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDir = root.appendingPathComponent("-Users-test-file-history", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let lines: [[String: Any]] = [
            ["type": "file-history-snapshot", "snapshot": ["trackedFileBackups": [:]]],
            ["type": "file-history-snapshot", "snapshot": ["trackedFileBackups": [:]]],
        ]
        let file = projectDir.appendingPathComponent("file-history-only.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = ClaudeCodeAdapter(projectsRoot: root.path)
        let failure = try parseFailure(await adapter.parseSessionInfo(locator: file.path))

        XCTAssertEqual(failure, .noVisibleMessages)
    }

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

        XCTAssertEqual(info.project, "proj")
        XCTAssertEqual(info.userMessageCount, 1)
        XCTAssertEqual(info.assistantMessageCount, 1)
        XCTAssertEqual(info.toolMessageCount, 1, "only the content-bearing tool_result is counted")
        XCTAssertEqual(info.messageCount, 3)
        XCTAssertEqual(info.messageCount, streamed.count, "count must match streamed message count")
        XCTAssertEqual(streamed.filter { $0.role == .tool }.count, 1)
        XCTAssertEqual(streamed.filter { $0.role == .user }.count, 1)
        XCTAssertEqual(streamed.filter { $0.role == .assistant }.count, 1)
    }

    func testClaudeCodeSystemOnlyTranscriptIsTerminalNoVisibleMessages() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDir = root.appendingPathComponent("-Users-test-empty", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let lines: [[String: Any]] = [
            ["type": "summary", "summary": "Prior session title", "leafUuid": "prev"],
            [
                "type": "user",
                "sessionId": "system-only-session",
                "cwd": "/Users/test/empty",
                "timestamp": "2026-04-29T10:00:00.000Z",
                "message": [
                    "role": "user",
                    "content": "<command-message>compact</command-message>\n<command-name>/compact</command-name>",
                ],
            ],
        ]
        let file = projectDir.appendingPathComponent("system-only.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = ClaudeCodeAdapter(projectsRoot: root.path)
        let failure = try parseFailure(await adapter.parseSessionInfo(locator: file.path))

        XCTAssertEqual(failure, .noVisibleMessages)
        XCTAssertEqual(ParserFailure.noVisibleMessages.rawValue, "noVisibleMessages")

        let now = Date(timeIntervalSince1970: 2_000)
        let stat = FileIndexStat(sizeBytes: 128, modifiedAtNanos: 1_000_000_000, inode: 42, device: 7)
        let state = FileIndexState.failure(
            source: .claudeCode,
            locator: file.path,
            stat: stat,
            failure: failure,
            previous: nil,
            now: now
        )
        XCTAssertEqual(state.parseStatus, .terminal)
        XCTAssertNil(state.retryAfterEpochSeconds)
        XCTAssertEqual(state.retryCount, 0)
        XCTAssertEqual(FileIndexDecision.decide(stat: stat, state: state, now: now), .skip)
    }

    func testClaudeCodeMalformedTranscriptStaysRetryable() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let badFile = root.appendingPathComponent("garbage.jsonl")
        try "this is not json at all\n{ broken\n".write(to: badFile, atomically: true, encoding: .utf8)

        let adapter = ClaudeCodeAdapter(projectsRoot: root.path)
        let failure = try parseFailure(await adapter.parseSessionInfo(locator: badFile.path))

        XCTAssertEqual(failure, .malformedJSON)
        let now = Date(timeIntervalSince1970: 2_000)
        let stat = FileIndexStat(sizeBytes: 128, modifiedAtNanos: 1_000_000_000, inode: 42, device: 7)
        let state = FileIndexState.failure(
            source: .claudeCode,
            locator: badFile.path,
            stat: stat,
            failure: failure,
            previous: nil,
            now: now
        )
        XCTAssertEqual(state.parseStatus, .retry)
        XCTAssertNotNil(state.retryAfterEpochSeconds)
        XCTAssertGreaterThan(state.retryCount, 0)
    }

    func testClaudeCodeSystemInjectionCountMatchesStream() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDir = root.appendingPathComponent("-Users-test-system-mixed", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let lines: [[String: Any]] = [
            [
                "type": "user",
                "sessionId": "cc-system-mixed",
                "cwd": "/Users/test/system-mixed",
                "timestamp": "2026-01-01T00:00:00Z",
                "message": [
                    "role": "user",
                    "content": "# AGENTS.md instructions for /Users/test/system-mixed\n<INSTRUCTIONS>...</INSTRUCTIONS>",
                ],
            ],
            [
                "type": "user",
                "sessionId": "cc-system-mixed",
                "timestamp": "2026-01-01T00:00:01Z",
                "message": ["role": "user", "content": "real task"],
            ],
            [
                "type": "assistant",
                "sessionId": "cc-system-mixed",
                "timestamp": "2026-01-01T00:00:02Z",
                "message": ["role": "assistant", "model": "claude-x", "content": "done"],
            ],
        ]
        let file = projectDir.appendingPathComponent("mixed.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = ClaudeCodeAdapter(projectsRoot: root.path)
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: file.path))
        let streamed = try await drain(adapter, locator: file.path)

        XCTAssertEqual(info.userMessageCount, 1)
        XCTAssertEqual(info.assistantMessageCount, 1)
        XCTAssertEqual(info.systemMessageCount, 1)
        XCTAssertEqual(info.messageCount, 2)
        XCTAssertEqual(info.messageCount, streamed.count, "count must match streamed message count")
        XCTAssertEqual(streamed.map(\.content), ["real task", "done"])
    }

    func testClaudeCodeMultiRootIndexingScanForcesNonDefaultSourceAndOriginator() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let projectsRoot = home
            .appendingPathComponent(".claude-minimax", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
        let projectDir = projectsRoot.appendingPathComponent("-Users-test-minimax", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let settingsURL = home.appendingPathComponent(".engram/settings.json")
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let settings = try JSONSerialization.data(
            withJSONObject: [
                "claudeCodeProfiles": [
                    "autoDiscover": true,
                    "customProjectsRoots": [],
                ],
            ],
            options: [.sortedKeys]
        )
        try settings.write(to: settingsURL)
        let file = projectDir.appendingPathComponent("minimax.jsonl")
        let lines: [[String: Any]] = [
            [
                "type": "user",
                "sessionId": "cc-minimax-profile",
                "cwd": "/Users/test/minimax",
                "timestamp": "2026-07-13T00:00:00Z",
                "message": ["role": "user", "content": "request"],
            ],
            [
                "type": "assistant",
                "sessionId": "cc-minimax-profile",
                "timestamp": "2026-07-13T00:00:01Z",
                "message": ["role": "assistant", "model": "MiniMax-M2.1", "content": "response"],
            ],
        ]
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)
        let resolver = ClaudeCodeProfileResolver(homeDirectory: home, settingsURL: settingsURL)
        let adapter = ClaudeCodeAdapter(profileResolver: resolver)

        let scan = try sessionInfo(await adapter.scanForIndexing(locator: file.path))

        XCTAssertEqual(scan.info.source, .claudeCode)
        XCTAssertEqual(scan.info.originator, "claude-code")
        XCTAssertEqual(scan.info.model, "MiniMax-M2.1")
        XCTAssertEqual(scan.messages.count, 2)
    }

    // MARK: - Copilot

    func testCopilotAttachesShutdownModelMetricsToLastAssistantMessage() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root.appendingPathComponent("session-with-usage", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try """
        id: session-with-usage
        cwd: /tmp/copilot-usage-project
        created_at: 2026-06-01T10:00:00.000Z
        updated_at: 2026-06-01T10:05:00.000Z
        """.write(to: sessionDir.appendingPathComponent("workspace.yaml"), atomically: true, encoding: .utf8)

        let events = sessionDir.appendingPathComponent("events.jsonl")
        try [
            jsonLine([
                "type": "session.start",
                "timestamp": "2026-06-01T10:00:00.000Z",
                "data": [
                    "startTime": "2026-06-01T10:00:00.000Z",
                    "context": ["cwd": "/tmp/copilot-usage-project"],
                ],
            ]),
            jsonLine([
                "type": "user.message",
                "timestamp": "2026-06-01T10:01:00.000Z",
                "data": ["content": "Check the usage monitor"],
            ]),
            jsonLine([
                "type": "assistant.message",
                "timestamp": "2026-06-01T10:02:00.000Z",
                "data": ["content": "Usage monitor reviewed."],
            ]),
            jsonLine([
                "type": "session.shutdown",
                "timestamp": "2026-06-01T10:05:00.000Z",
                "data": [
                    "modelMetrics": [
                        "gpt-5.4": [
                            "usage": [
                                "inputTokens": 1_200,
                                "outputTokens": 80,
                                "cacheReadTokens": 900,
                                "cacheWriteTokens": 40,
                            ],
                        ],
                    ],
                ],
            ]),
        ].joined(separator: "\n").appending("\n")
            .write(to: events, atomically: true, encoding: .utf8)

        let adapter = CopilotAdapter(sessionRoot: root.path)
        let streamed = try await drain(adapter, locator: events.path)

        XCTAssertEqual(streamed.map(\.role), [.user, .assistant])
        XCTAssertNil(streamed.first?.usage)
        XCTAssertEqual(
            streamed.last?.usage,
            TokenUsage(inputTokens: 1_200, outputTokens: 80, cacheReadTokens: 900, cacheCreationTokens: 40)
        )
    }

    func testCopilotFallsBackToCheckpointIndexWhenEventsAreMissing() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root.appendingPathComponent("session-no-events", isDirectory: true)
        let checkpointsDir = sessionDir.appendingPathComponent("checkpoints", isDirectory: true)
        try FileManager.default.createDirectory(at: checkpointsDir, withIntermediateDirectories: true)
        try """
        id: session-no-events
        cwd: /tmp/copilot-project
        summary_count: 2
        created_at: 2026-06-01T10:00:00.000Z
        updated_at: 2026-06-01T10:05:00.000Z
        """.write(to: sessionDir.appendingPathComponent("workspace.yaml"), atomically: true, encoding: .utf8)
        let checkpointIndex = checkpointsDir.appendingPathComponent("index.md")
        try """
        # Checkpoint History

        | # | Title | File |
        |---|-------|------|
        | 1 | Initial production deploy audit | 001-initial-production-deploy.md |
        | 2 | Follow-up verifier and rollback notes | 002-follow-up-verifier.md |
        """.write(to: checkpointIndex, atomically: true, encoding: .utf8)
        try """
        <overview>
        Production deploy reached the smoke-test phase and needs database checks.
        </overview>
        """.write(
            to: checkpointsDir.appendingPathComponent("001-initial-production-deploy.md"),
            atomically: true,
            encoding: .utf8
        )
        try """
        <work_done>
        Rollback notes were captured and the verifier command is ready.
        </work_done>
        """.write(
            to: checkpointsDir.appendingPathComponent("002-follow-up-verifier.md"),
            atomically: true,
            encoding: .utf8
        )

        let adapter = CopilotAdapter(sessionRoot: root.path)
        let locators = try await adapter.listSessionLocators()
        func standardize(_ path: String) -> String {
            URL(fileURLWithPath: path).standardizedFileURL.path
        }

        XCTAssertEqual(locators.map(standardize), [standardize(checkpointIndex.path)])

        let info = try sessionInfo(await adapter.parseSessionInfo(locator: checkpointIndex.path))
        let streamed = try await drain(adapter, locator: checkpointIndex.path)

        XCTAssertEqual(info.id, "session-no-events")
        XCTAssertEqual(info.cwd, "/tmp/copilot-project")
        XCTAssertEqual(info.startTime, "2026-06-01T10:00:00.000Z")
        XCTAssertEqual(info.endTime, "2026-06-01T10:05:00.000Z")
        XCTAssertEqual(info.summary, "Initial production deploy audit")
        XCTAssertEqual(info.systemMessageCount, 2)
        XCTAssertEqual(info.messageCount, 2)
        XCTAssertEqual(info.messageCount, streamed.count)
        XCTAssertEqual(streamed.map(\.role), [.system, .system])
        XCTAssertEqual(streamed.map(\.content), [
            """
            Checkpoint 1: Initial production deploy audit

            <overview>
            Production deploy reached the smoke-test phase and needs database checks.
            </overview>
            """,
            """
            Checkpoint 2: Follow-up verifier and rollback notes

            <work_done>
            Rollback notes were captured and the verifier command is ready.
            </work_done>
            """
        ])
    }

    func testCopilotIgnoresOversizedWorkspaceYaml() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root.appendingPathComponent("session-oversized-workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try """
        id: injected-id
        cwd: /tmp/\(String(repeating: "x", count: 1_000))
        created_at: 2026-01-01T00:00:00Z
        updated_at: 2026-01-01T00:05:00Z
        """.write(to: sessionDir.appendingPathComponent("workspace.yaml"), atomically: true, encoding: .utf8)
        let events = sessionDir.appendingPathComponent("events.jsonl")
        try [
            jsonLine(["type": "user.message", "timestamp": "2026-01-01T00:01:00Z", "data": ["content": "hi"]]),
            jsonLine(["type": "assistant.message", "timestamp": "2026-01-01T00:02:00Z", "data": ["content": "ok"]]),
        ].joined(separator: "\n").appending("\n")
            .write(to: events, atomically: true, encoding: .utf8)

        let adapter = CopilotAdapter(
            sessionRoot: root.path,
            limits: ParserLimits(maxFileBytes: 512)
        )
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: events.path))

        XCTAssertEqual(info.id, "session-oversized-workspace")
        XCTAssertEqual(info.cwd, "")
    }

    func testCopilotSkipsOversizedCheckpointBody() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root.appendingPathComponent("session-oversized-checkpoint", isDirectory: true)
        let checkpointsDir = sessionDir.appendingPathComponent("checkpoints", isDirectory: true)
        try FileManager.default.createDirectory(at: checkpointsDir, withIntermediateDirectories: true)
        try """
        id: session-oversized-checkpoint
        cwd: /tmp/copilot-project
        created_at: 2026-06-01T10:00:00.000Z
        updated_at: 2026-06-01T10:05:00.000Z
        """.write(to: sessionDir.appendingPathComponent("workspace.yaml"), atomically: true, encoding: .utf8)
        let checkpointIndex = checkpointsDir.appendingPathComponent("index.md")
        try """
        # Checkpoint History

        | # | Title | File |
        |---|-------|------|
        | 1 | Large checkpoint | 001-large.md |
        """.write(to: checkpointIndex, atomically: true, encoding: .utf8)
        try "<overview>\(String(repeating: "x", count: 200))</overview>"
            .write(
                to: checkpointsDir.appendingPathComponent("001-large.md"),
                atomically: true,
                encoding: .utf8
            )

        let adapter = CopilotAdapter(
            sessionRoot: root.path,
            limits: ParserLimits(maxFileBytes: 128)
        )
        let streamed = try await drain(adapter, locator: checkpointIndex.path)

        XCTAssertEqual(streamed.map(\.content), ["Checkpoint 1: Large checkpoint"])
    }

    func testCopilotStripsMatchedYamlQuotePairs() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root.appendingPathComponent("session-quoted", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try """
        id: "quoted-id"
        cwd: "/tmp/path with space"
        created_at: '2026-01-01T00:00:00Z'
        updated_at: 2026-01-01T00:05:00Z
        """.write(to: sessionDir.appendingPathComponent("workspace.yaml"), atomically: true, encoding: .utf8)
        let events = sessionDir.appendingPathComponent("events.jsonl")
        try [
            jsonLine(["type": "user.message", "timestamp": "2026-01-01T00:01:00Z", "data": ["content": "hi"]]),
            jsonLine(["type": "assistant.message", "timestamp": "2026-01-01T00:02:00Z", "data": ["content": "ok"]]),
        ].joined(separator: "\n").appending("\n")
            .write(to: events, atomically: true, encoding: .utf8)

        let adapter = CopilotAdapter(sessionRoot: root.path)
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: events.path))

        XCTAssertEqual(info.id, "quoted-id")
        XCTAssertEqual(info.cwd, "/tmp/path with space")
        XCTAssertEqual(info.startTime, "2026-01-01T00:00:00Z")
    }

    // MARK: - OpenCode

    func testOpenCodeRecentListingFiltersBySessionUpdateTime() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbPath = root.appendingPathComponent("opencode.db").path
        try Self.buildOpenCodeFixture(dbPath: dbPath)

        let adapter = RecentlyModifiedSessionAdapter(
            base: OpenCodeAdapter(dbPath: dbPath),
            modifiedSince: Date(timeIntervalSince1970: 1_695_000_000)
        )

        let locators = try await adapter.listSessionLocators()

        XCTAssertEqual(locators, ["\(dbPath)::ses_1"])
    }

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
        XCTAssertEqual(streamed.map(\.content), ["question", "answer\nfollow-up"])
    }

    func testOpenCodeAttachesAssistantMessageTokenUsage() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbPath = root.appendingPathComponent("opencode.db").path
        try Self.buildOpenCodeFixture(dbPath: dbPath)

        let adapter = OpenCodeAdapter(dbPath: dbPath)
        let streamed = try await drain(adapter, locator: "\(dbPath)::ses_1")

        XCTAssertEqual(streamed.map(\.role), [.user, .assistant])
        XCTAssertNil(streamed.first?.usage)
        XCTAssertEqual(
            streamed.last?.usage,
            TokenUsage(inputTokens: 123, outputTokens: 50, cacheReadTokens: 67, cacheCreationTokens: 8)
        )
    }

    func testOpenCodeNormalizesTextPartTypeCaseAndWhitespace() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbPath = root.appendingPathComponent("opencode.db").path
        try Self.buildOpenCodeFixture(dbPath: dbPath)
        try Self.updateOpenCodePart(dbPath: dbPath, id: "p1", data: #"{"type":" Text ","text":"question"}"#)

        let adapter = OpenCodeAdapter(dbPath: dbPath)
        let locator = "\(dbPath)::ses_1"
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: locator))
        let streamed = try await drain(adapter, locator: locator)

        XCTAssertEqual(info.userMessageCount, 1)
        XCTAssertEqual(info.messageCount, streamed.count)
        XCTAssertEqual(streamed.first?.content, "question")
    }

    func testOpenCodeAccessibilityReusesSharedDatabaseConnection() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbPath = root.appendingPathComponent("opencode.db").path
        try Self.buildOpenCodeFixture(dbPath: dbPath)

        let adapter = OpenCodeAdapter(dbPath: dbPath)
        let first = await adapter.isAccessible(locator: "\(dbPath)::ses_1")
        XCTAssertTrue(first)

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dbPath)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dbPath) }

        let second = await adapter.isAccessible(locator: "\(dbPath)::ses_2")
        XCTAssertTrue(
            second,
            "orphan scanning must not reopen the same OpenCode sqlite database for every session"
        )
    }

    func testOpenCodeListingThrowsWhenSQLiteSchemaIsUnreadable() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbPath = root.appendingPathComponent("opencode.db").path
        try Self.buildEmptySQLiteFile(dbPath: dbPath)

        let adapter = OpenCodeAdapter(dbPath: dbPath)

        do {
            _ = try await adapter.listSessionLocators()
            XCTFail("Malformed SQLite-backed sources must surface listing errors instead of appearing empty.")
        } catch let failure as ParserFailure {
            XCTAssertEqual(failure, .sqliteUnreadable)
        }
    }

    func testCursorAccessibilityReusesSharedDatabaseConnection() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbPath = root.appendingPathComponent("state.vscdb").path
        try Self.buildCursorFixture(dbPath: dbPath)

        let adapter = CursorAdapter(dbPath: dbPath)
        let first = await adapter.isAccessible(locator: "\(dbPath)?composer=cmp_1")
        XCTAssertTrue(first)

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dbPath)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dbPath) }

        let second = await adapter.isAccessible(locator: "\(dbPath)?composer=cmp_2")
        XCTAssertTrue(
            second,
            "orphan scanning must not reopen the same Cursor sqlite database for every composer"
        )
    }

    func testCursorListingThrowsWhenSQLiteSchemaIsUnreadable() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbPath = root.appendingPathComponent("state.vscdb").path
        try Self.buildEmptySQLiteFile(dbPath: dbPath)

        let adapter = CursorAdapter(dbPath: dbPath)

        do {
            _ = try await adapter.listSessionLocators()
            XCTFail("Malformed SQLite-backed sources must surface listing errors instead of appearing empty.")
        } catch let failure as ParserFailure {
            XCTAssertEqual(failure, .sqliteUnreadable)
        }
    }

    func testCursorAttachesAssistantTokenUsage() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbPath = root.appendingPathComponent("state.vscdb").path
        try Self.buildCursorUsageFixture(dbPath: dbPath)

        let adapter = CursorAdapter(dbPath: dbPath)
        let streamed = try await drain(adapter, locator: "\(dbPath)?composer=cmp_usage")

        XCTAssertEqual(streamed.map(\.role), [.user, .assistant])
        XCTAssertNil(streamed.first?.usage)
        XCTAssertEqual(
            streamed.last?.usage,
            TokenUsage(inputTokens: 123, outputTokens: 45, cacheReadTokens: 0, cacheCreationTokens: 0)
        )
    }

    func testCursorComposerMissingCreatedAtUsesFirstBubbleTimestamp() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbPath = root.appendingPathComponent("state.vscdb").path
        try Self.buildCursorMissingCreatedAtFixture(dbPath: dbPath)

        let adapter = CursorAdapter(dbPath: dbPath)
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: "\(dbPath)?composer=cmp_missing_created"))

        XCTAssertEqual(info.startTime, "2023-11-14T22:13:21.000Z")
        XCTAssertEqual(info.endTime, "2023-11-14T22:13:22.000Z")
    }

    /// Minimal OpenCode schema with: 1 user msg (text part), 1 assistant msg
    /// (multiple text parts), and 1 assistant msg whose only part is a non-text
    /// tool part (must be excluded from counts and the stream).
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
        try exec("INSERT INTO session VALUES ('ses_2', '/Users/test/proj', 'Second', 1690000000000, 1690000010000, NULL)")
        try exec("INSERT INTO message VALUES ('m1', 'ses_1', 1700000001000, '{\"role\":\"user\"}')")
        try exec("INSERT INTO message VALUES ('m2', 'ses_1', 1700000002000, '{\"role\":\"assistant\",\"tokens\":{\"input\":123,\"output\":45,\"reasoning\":5,\"cache\":{\"read\":67,\"write\":8}}}')")
        try exec("INSERT INTO message VALUES ('m3', 'ses_1', 1700000003000, '{\"role\":\"assistant\"}')")
        try exec("INSERT INTO message VALUES ('m4', 'ses_2', 1700000004000, '{\"role\":\"user\"}')")
        try exec("INSERT INTO part VALUES ('p1', 'm1', 1700000001000, '{\"type\":\"text\",\"text\":\"question\"}')")
        try exec("INSERT INTO part VALUES ('p2', 'm2', 1700000002000, '{\"type\":\"text\",\"text\":\"answer\"}')")
        try exec("INSERT INTO part VALUES ('p2b', 'm2', 1700000002001, '{\"type\":\"text\",\"text\":\"follow-up\"}')")
        // m3 has only a tool part (no text) → must be dropped.
        try exec("INSERT INTO part VALUES ('p3', 'm3', 1700000003000, '{\"type\":\"tool\",\"tool\":\"read\"}')")
        try exec("INSERT INTO part VALUES ('p4', 'm4', 1700000004000, '{\"type\":\"text\",\"text\":\"second\"}')")
    }

    private static func updateOpenCodePart(dbPath: String, id: String, data: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw NSError(domain: "test", code: 1)
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE part SET data = ? WHERE id = ?", -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "test", code: 2)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, data, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(statement, 2, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw NSError(domain: "test", code: 3)
        }
    }

    private static func buildEmptySQLiteFile(dbPath: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw NSError(domain: "test", code: 1)
        }
        sqlite3_close(db)
    }

    private static func buildCursorFixture(dbPath: String) throws {
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

        try exec("CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value TEXT)")
        try exec("INSERT INTO cursorDiskKV VALUES ('composerData:cmp_1', '{\"composerId\":\"cmp_1\"}')")
        try exec("INSERT INTO cursorDiskKV VALUES ('composerData:cmp_2', '{\"composerId\":\"cmp_2\"}')")
    }

    private static func buildCursorUsageFixture(dbPath: String) throws {
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

        try exec("CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value TEXT)")
        try exec("INSERT INTO cursorDiskKV VALUES ('composerData:cmp_usage', '{\"composerId\":\"cmp_usage\"}')")
        try exec("INSERT INTO cursorDiskKV VALUES ('bubbleId:cmp_usage:u1', '{\"type\":1,\"text\":\"Track Cursor usage\",\"timingInfo\":{\"clientStartTime\":1700000001000},\"tokenCount\":{\"inputTokens\":77,\"outputTokens\":0}}')")
        try exec("INSERT INTO cursorDiskKV VALUES ('bubbleId:cmp_usage:a1', '{\"type\":2,\"text\":\"Cursor usage tracked.\",\"timingInfo\":{\"clientStartTime\":1700000002000},\"tokenCount\":{\"inputTokens\":123,\"outputTokens\":45}}')")
    }

    private static func buildCursorMissingCreatedAtFixture(dbPath: String) throws {
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

        try exec("CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value TEXT)")
        try exec("INSERT INTO cursorDiskKV VALUES ('composerData:cmp_missing_created', '{\"composerId\":\"cmp_missing_created\",\"lastUpdatedAt\":1700000002000}')")
        try exec("INSERT INTO cursorDiskKV VALUES ('bubbleId:cmp_missing_created:u1', '{\"type\":1,\"text\":\"Track Cursor timestamps\",\"timingInfo\":{\"clientStartTime\":1700000001000}}')")
        try exec("INSERT INTO cursorDiskKV VALUES ('bubbleId:cmp_missing_created:a1', '{\"type\":2,\"text\":\"Cursor timestamps tracked.\",\"timingInfo\":{\"clientStartTime\":1700000002000}}')")
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
