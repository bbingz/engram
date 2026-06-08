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
            TokenUsage(inputTokens: 123, outputTokens: 45, cacheReadTokens: 67, cacheCreationTokens: 8)
        )
    }

    // MARK: - Qwen

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

    // MARK: - Codex

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
        try exec("INSERT INTO session VALUES ('ses_2', '/Users/test/proj', 'Second', 1700000000000, 1700000010000, NULL)")
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
