import Foundation
import GRDB
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

    private func writeJSON(_ object: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        try data.write(to: url)
    }

    private func writeJSONL(_ objects: [[String: Any]], to url: URL) throws {
        try objects.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: url, atomically: true, encoding: .utf8)
    }

    private func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func makeGrokFixture(root: URL) throws -> (sessionDir: URL, transcript: URL) {
        let encodedCwd = "%2FUsers%2Fbing%2F-Automations-%2FPrefict-Trading-Bot"
        let sessionDir = root
            .appendingPathComponent(encodedCwd, isDirectory: true)
            .appendingPathComponent("019f179d-0888-76b1-9325-5a91ace595df", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        try writeJSON(
            [
                "info": [
                    "id": "019f179d-0888-76b1-9325-5a91ace595df",
                    "cwd": "/Users/bing/-Automations-/Prefict-Trading-Bot"
                ],
                "session_summary": "Reconstruct Technical Route from X Post Clues and Validate Closed Loop",
                "generated_title": "Reconstruct Technical Route from X Post Clues and Validate Closed Loop",
                "created_at": "2026-06-30T08:19:55.275395Z",
                "updated_at": "2026-06-30T11:12:27.482957Z",
                "current_model_id": "grok-build",
                "agent_name": "grok-build-plan",
                "num_messages": 7,
                "num_chat_messages": 5,
                "chat_format_version": 1
            ],
            to: sessionDir.appendingPathComponent("summary.json")
        )
        try writeJSON(
            [
                "working_directory": "/Users/bing/-Automations-/Prefict-Trading-Bot",
                "system_prompt_label": "Grok"
            ],
            to: sessionDir.appendingPathComponent("prompt_context.json")
        )
        let transcript = sessionDir.appendingPathComponent("chat_history.jsonl")
        try writeJSONL(
            [
                ["type": "system", "content": "You are Grok released by xAI."],
                [
                    "type": "user",
                    "content": [[
                        "type": "text",
                        "text": "<user_info>\nWorkspace Path: /Users/bing/-Automations-/Prefict-Trading-Bot\n</user_info>"
                    ]]
                ],
                [
                    "type": "reasoning",
                    "content": "Inspecting public clues before writing the route."
                ],
                [
                    "type": "backend_tool_call",
                    "name": "list_dir",
                    "arguments": #"{"target_directory":"."}"#
                ],
                [
                    "type": "user",
                    "content": [[
                        "type": "text",
                        "text": "<user_query>\nhttps://x.com/ZhanweiC/status/2071750256715505947\n\n你按他说的线索，完整还原出他的技术路线？\n</user_query>"
                    ]]
                ],
                [
                    "type": "assistant",
                    "content": "我会先抓取线索并还原技术路线。",
                    "tool_calls": [[
                        "id": "call-1",
                        "name": "web_fetch",
                        "arguments": #"{"url":"https://github.com/PredictDotFun/sdk-python"}"#
                    ]],
                    "model_id": "grok-build",
                    "model_fingerprint": "fp_36bb860c5ab2a013"
                ],
                [
                    "type": "tool_result",
                    "tool_call_id": "call-1",
                    "content": "Predict.fun SDK README"
                ]
            ],
            to: transcript
        )
        return (sessionDir, transcript)
    }

    private func makeClaudeCodeFixture(
        projectsRoot: URL,
        projectName: String = "-Users-bing--Code--MimoProject",
        sessionId: String = "cc-mimo-1",
        model: String = "mimo-v2.5-pro"
    ) throws -> URL {
        let projectDir = projectsRoot.appendingPathComponent(projectName, isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let transcript = projectDir.appendingPathComponent("\(sessionId).jsonl")
        let assistantContent: [[String: Any]] = [
            ["type": "text", "text": "Indexed under the provider source."]
        ]
        try writeJSONL(
            [
                [
                    "type": "user",
                    "sessionId": sessionId,
                    "cwd": "/Users/bing/-Code-/MimoProject",
                    "timestamp": "2026-06-30T01:00:00.000Z",
                    "message": [
                        "role": "user",
                        "content": "Build the provider routed session index.",
                    ],
                ],
                [
                    "type": "assistant",
                    "sessionId": sessionId,
                    "cwd": "/Users/bing/-Code-/MimoProject",
                    "timestamp": "2026-06-30T01:00:01.000Z",
                    "message": [
                        "role": "assistant",
                        "model": model,
                        "content": assistantContent,
                    ],
                ],
            ],
            to: transcript
        )
        return transcript
    }

    private func makeClaudeCodeSubagentFixture(
        projectsRoot: URL,
        projectName: String = "-Users-bing--Code--MimoProject",
        parentSessionId: String = "cc-mimo-parent",
        agentId: String,
        nestedWorkflowId: String? = nil
    ) throws -> URL {
        var subagentsDir = projectsRoot
            .appendingPathComponent(projectName, isDirectory: true)
            .appendingPathComponent(parentSessionId, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        if let nestedWorkflowId {
            subagentsDir = subagentsDir
                .appendingPathComponent("workflows", isDirectory: true)
                .appendingPathComponent(nestedWorkflowId, isDirectory: true)
        }
        try FileManager.default.createDirectory(at: subagentsDir, withIntermediateDirectories: true)
        let transcript = subagentsDir.appendingPathComponent("agent-\(agentId).jsonl")
        try writeJSONL(
            [
                [
                    "type": "user",
                    "sessionId": parentSessionId,
                    "agentId": agentId,
                    "cwd": "/Users/bing/-Code-/MimoProject",
                    "timestamp": "2026-06-30T01:00:00.000Z",
                    "isSidechain": true,
                    "message": [
                        "role": "user",
                        "content": "Review the provider parser.",
                    ],
                ],
                [
                    "type": "assistant",
                    "sessionId": parentSessionId,
                    "agentId": agentId,
                    "cwd": "/Users/bing/-Code-/MimoProject",
                    "timestamp": "2026-06-30T01:00:01.000Z",
                    "isSidechain": true,
                    "message": [
                        "role": "assistant",
                        "model": "mimo-v2.5-pro",
                        "content": [["type": "text", "text": "Nested workflow subagent parsed."]],
                    ],
                ],
            ],
            to: transcript
        )
        return transcript
    }

    private func makeClaudeCodeLocalCommandOnlyFixture(projectsRoot: URL) throws -> URL {
        let projectDir = projectsRoot.appendingPathComponent("-Users-bing--Code--DrCom", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let transcript = projectDir.appendingPathComponent("local-command-only.jsonl")
        try writeJSONL(
            [
                [
                    "type": "mode",
                    "mode": "normal",
                    "sessionId": "local-command-only",
                ],
                [
                    "type": "permission-mode",
                    "permissionMode": "bypassPermissions",
                    "sessionId": "local-command-only",
                ],
                [
                    "type": "user",
                    "sessionId": "local-command-only",
                    "cwd": "/Users/bing/-Code-/DrCom",
                    "timestamp": "2026-06-29T13:20:16.846Z",
                    "isMeta": true,
                    "message": [
                        "role": "user",
                        "content": "<local-command-caveat>Caveat: ignore local commands.</local-command-caveat>",
                    ],
                ],
                [
                    "type": "user",
                    "sessionId": "local-command-only",
                    "cwd": "/Users/bing/-Code-/DrCom",
                    "timestamp": "2026-06-29T13:20:16.846Z",
                    "message": [
                        "role": "user",
                        "content": "<command-name>/effort</command-name>\n<command-message>effort</command-message>",
                    ],
                ],
                [
                    "type": "user",
                    "sessionId": "local-command-only",
                    "cwd": "/Users/bing/-Code-/DrCom",
                    "timestamp": "2026-06-29T13:20:16.846Z",
                    "message": [
                        "role": "user",
                        "content": "<local-command-stdout>Set effort level to ultracode</local-command-stdout>",
                    ],
                ],
            ],
            to: transcript
        )
        return transcript
    }

    private struct LiveClaudeCodeProviderRootSpec {
        let name: String
        let source: SourceName
    }

    // MARK: - Grok

    func testGrokAdapterDiscoversSessionDirectoriesAndParsesMetadata() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGrokFixture(root: root)

        let adapter = GrokAdapter(sessionsRoot: root.path)
        let locators = try await adapter.listSessionLocators()
        XCTAssertEqual(locators.count, 1)
        XCTAssertTrue(locators[0].hasSuffix(
            "%2FUsers%2Fbing%2F-Automations-%2FPrefict-Trading-Bot/019f179d-0888-76b1-9325-5a91ace595df/chat_history.jsonl"
        ))

        let info = try sessionInfo(await adapter.parseSessionInfo(locator: fixture.transcript.path))
        XCTAssertEqual(info.id, "019f179d-0888-76b1-9325-5a91ace595df")
        XCTAssertEqual(info.source, .grok)
        XCTAssertEqual(info.cwd, "/Users/bing/-Automations-/Prefict-Trading-Bot")
        XCTAssertEqual(info.model, "grok-build")
        XCTAssertEqual(info.startTime, "2026-06-30T08:19:55.275395Z")
        XCTAssertEqual(info.endTime, "2026-06-30T11:12:27.482957Z")
        XCTAssertEqual(info.userMessageCount, 1)
        XCTAssertEqual(info.assistantMessageCount, 1)
        XCTAssertEqual(info.toolMessageCount, 1)
        XCTAssertEqual(info.systemMessageCount, 2)
        XCTAssertEqual(info.messageCount, 3)
        XCTAssertEqual(info.summary, "https://x.com/ZhanweiC/status/2071750256715505947\n\n你按他说的线索，完整还原出他的技术路线？")
        XCTAssertEqual(info.filePath, fixture.transcript.path)
        XCTAssertGreaterThan(info.sizeBytes, 0)
    }

    func testGrokAdapterStreamsCleanMessagesAndToolCalls() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGrokFixture(root: root)

        let adapter = GrokAdapter(sessionsRoot: root.path)
        let streamed = try await drain(adapter, locator: fixture.transcript.path)

        XCTAssertEqual(streamed.map(\.role), [.user, .assistant, .tool])
        XCTAssertEqual(streamed[0].content, "https://x.com/ZhanweiC/status/2071750256715505947\n\n你按他说的线索，完整还原出他的技术路线？")
        XCTAssertEqual(streamed[1].content, "我会先抓取线索并还原技术路线。")
        XCTAssertEqual(streamed[1].toolCalls?.first?.name, "web_fetch")
        XCTAssertEqual(streamed[1].toolCalls?.first?.input, #"{"url":"https://github.com/PredictDotFun/sdk-python"}"#)
        XCTAssertEqual(streamed[2].content, "Predict.fun SDK README")
    }

    func testGrokAdapterIsRegisteredAndIndexable() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makeGrokFixture(root: root)

        XCTAssertTrue(SessionAdapterFactory.defaultAdapters().contains { $0.source == .grok })
        let adapter = GrokAdapter(sessionsRoot: root.path)
        let indexer = SwiftIndexer(sink: AdapterMessageCountNoopSink(), adapters: [adapter])
        let snapshots = try await indexer.collectSnapshots()

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.source, .grok)
        XCTAssertEqual(snapshots.first?.id, "019f179d-0888-76b1-9325-5a91ace595df")
        XCTAssertEqual(snapshots.first?.messageCount, 3)
        XCTAssertNotEqual(snapshots.first?.tier, .skip)
    }

    func testLiveGrokCorpusIndexesExpectedLocalSessions() async throws {
        guard ProcessInfo.processInfo.environment["ENGRAM_LIVE_GROK_CORPUS_SMOKE"] == "1" else {
            throw XCTSkip("set ENGRAM_LIVE_GROK_CORPUS_SMOKE=1 to scan the local Grok corpus")
        }

        let sessionsRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/sessions", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sessionsRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw XCTSkip("missing local Grok sessions root: \(sessionsRoot.path)")
        }

        let adapter = GrokAdapter(sessionsRoot: sessionsRoot.path)
        let locators = try await adapter.listSessionLocators()
        XCTAssertGreaterThan(locators.count, 0)

        var parsed = 0
        var userMessages = 0
        var assistantMessages = 0
        var toolMessages = 0
        var systemMessages = 0
        var models = Set<String>()
        for locator in locators {
            switch try await adapter.parseSessionInfo(locator: locator) {
            case .success(let info):
                XCTAssertEqual(info.source, .grok)
                XCTAssertFalse(info.id.isEmpty)
                XCTAssertFalse(info.cwd.isEmpty)
                XCTAssertTrue(info.filePath.hasSuffix("/chat_history.jsonl") || info.filePath.hasSuffix("/updates.jsonl"))
                parsed += 1
                userMessages += info.userMessageCount
                assistantMessages += info.assistantMessageCount
                toolMessages += info.toolMessageCount
                systemMessages += info.systemMessageCount
                if let model = info.model, !model.isEmpty {
                    models.insert(model)
                }
            case .failure:
                break
            }
        }
        XCTAssertEqual(parsed, locators.count)
        XCTAssertGreaterThan(userMessages, 0)
        XCTAssertGreaterThan(assistantMessages, 0)
        XCTAssertGreaterThan(toolMessages, 0)
        XCTAssertGreaterThan(systemMessages, 0)
        XCTAssertTrue(models.contains("grok-build"))

        let runRoot = tempDir()
        defer { try? FileManager.default.removeItem(at: runRoot) }
        let writer = try EngramDatabaseWriter(path: runRoot.appendingPathComponent("index.sqlite").path)
        try writer.migrate()
        _ = try await writer.indexAllSessions(adapters: [adapter])
        let rowCount = try writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions WHERE source = 'grok'") ?? 0
        }
        XCTAssertEqual(rowCount, parsed)
        print(
            "LIVE_GROK_CORPUS_SMOKE listed=\(locators.count) parsed=\(parsed) rows=\(rowCount) user=\(userMessages) assistant=\(assistantMessages) tool=\(toolMessages) system=\(systemMessages) models=\(models.sorted().joined(separator: ","))"
        )
    }

    // MARK: - Claude Code provider roots

    func testClaudeCodeProviderRootParsesAsProviderSourceWithOriginator() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectsRoot = root.appendingPathComponent(".claude-mimo/projects", isDirectory: true)
        let transcript = try makeClaudeCodeFixture(projectsRoot: projectsRoot)

        let adapter = ClaudeCodeAdapter(projectsRoot: projectsRoot.path)
        let locators = try await adapter.listSessionLocators()
        XCTAssertEqual(locators.map(standardizedPath), [standardizedPath(transcript.path)])

        let info = try sessionInfo(await adapter.parseSessionInfo(locator: transcript.path))
        XCTAssertEqual(info.source.rawValue, "mimo")
        XCTAssertEqual(info.originator, "Claude Code")
        XCTAssertEqual(info.model, "mimo-v2.5-pro")
        XCTAssertEqual(info.userMessageCount, 1)
        XCTAssertEqual(info.assistantMessageCount, 1)

        let streamed = try await drain(adapter, locator: transcript.path)
        XCTAssertEqual(streamed.map(\.role), [.user, .assistant])
        XCTAssertEqual(streamed.map(\.content), [
            "Build the provider routed session index.",
            "Indexed under the provider source.",
        ])
    }

    func testClaudeCodeProviderRootSkipsSystemInjectionInStreamCount() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectsRoot = root.appendingPathComponent(".claude-qwen/projects", isDirectory: true)
        let projectDir = projectsRoot.appendingPathComponent("-Users-test-provider", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let transcript = projectDir.appendingPathComponent("provider-session.jsonl")
        try writeJSONL(
            [
                [
                    "type": "user",
                    "sessionId": "provider-session",
                    "cwd": "/Users/test/provider",
                    "timestamp": "2026-04-29T10:00:00.000Z",
                    "message": [
                        "role": "user",
                        "content": "<command-message>goal</command-message>\n<command-name>/goal</command-name>",
                    ],
                ],
                [
                    "type": "user",
                    "sessionId": "provider-session",
                    "cwd": "/Users/test/provider",
                    "timestamp": "2026-04-29T10:00:01.000Z",
                    "message": [
                        "role": "user",
                        "content": "real question",
                    ],
                ],
                [
                    "type": "assistant",
                    "sessionId": "provider-session",
                    "timestamp": "2026-04-29T10:00:02.000Z",
                    "message": [
                        "role": "assistant",
                        "model": "qwen3.7-plus",
                        "content": [["type": "text", "text": "real answer"]],
                    ],
                ],
            ],
            to: transcript
        )

        let adapter = ClaudeCodeAdapter(projectsRoot: projectsRoot.path)
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: transcript.path))
        XCTAssertEqual(info.source, .qwen)
        XCTAssertEqual(info.systemMessageCount, 1)
        XCTAssertEqual(info.userMessageCount, 1)
        XCTAssertEqual(info.assistantMessageCount, 1)
        XCTAssertEqual(info.messageCount, 2)

        let streamed = try await drain(adapter, locator: transcript.path)
        XCTAssertEqual(info.messageCount, streamed.count, "count must match streamed message count")
        XCTAssertEqual(streamed.map(\.content), ["real question", "real answer"])

        let offsetStream = try await adapter.streamMessages(
            locator: transcript.path,
            options: StreamMessagesOptions(offset: 1)
        )
        var offsetMessages: [NormalizedMessage] = []
        for try await message in offsetStream {
            offsetMessages.append(message)
        }
        XCTAssertEqual(offsetMessages.map(\.content), ["real answer"])
    }

    func testClaudeCodeProviderRootDiscoversNestedWorkflowSubagents() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectsRoot = root.appendingPathComponent(".claude-mimo/projects", isDirectory: true)
        let parent = try makeClaudeCodeFixture(projectsRoot: projectsRoot, sessionId: "cc-mimo-parent")
        let directSubagent = try makeClaudeCodeSubagentFixture(
            projectsRoot: projectsRoot,
            agentId: "direct"
        )
        let workflowSubagent = try makeClaudeCodeSubagentFixture(
            projectsRoot: projectsRoot,
            agentId: "workflow",
            nestedWorkflowId: "wf_123"
        )
        let workflowJournal = workflowSubagent
            .deletingLastPathComponent()
            .appendingPathComponent("journal.jsonl")
        try jsonLine([
            "type": "workflow_event",
            "workflowId": "wf_123",
            "event": "started",
        ])
        .appending("\n")
        .write(to: workflowJournal, atomically: true, encoding: .utf8)

        let adapter = ClaudeCodeAdapter(projectsRoot: projectsRoot.path)
        let locators = try await adapter.listSessionLocators().map(standardizedPath)

        XCTAssertEqual(
            Set(locators),
            Set([parent.path, directSubagent.path, workflowSubagent.path].map(standardizedPath))
        )

        let info = try sessionInfo(await adapter.parseSessionInfo(locator: workflowSubagent.path))
        XCTAssertEqual(info.id, "workflow")
        XCTAssertEqual(info.source, .mimo)
        XCTAssertEqual(info.originator, "Claude Code")
        XCTAssertEqual(info.agentRole, "subagent")
        XCTAssertEqual(info.parentSessionId, "cc-mimo-parent")
        XCTAssertEqual(info.userMessageCount, 1)
        XCTAssertEqual(info.assistantMessageCount, 1)
    }

    func testLiveNativeClaudeCodeCorpusHasIdentityCoverageInDatabase() async throws {
        guard ProcessInfo.processInfo.environment["ENGRAM_LIVE_CLAUDE_CODE_CORPUS_SMOKE"] == "1" else {
            throw XCTSkip("set ENGRAM_LIVE_CLAUDE_CODE_CORPUS_SMOKE=1 to scan the local native Claude Code corpus")
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let projectsRoot = home.appendingPathComponent(".claude/projects", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: projectsRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw XCTSkip("missing native Claude Code projects root: \(projectsRoot.path)")
        }

        let adapter = ClaudeCodeAdapter(projectsRoot: projectsRoot.path)
        let locators = try await adapter.listSessionLocators()
        XCTAssertGreaterThan(locators.count, 0)

        var parsed = 0
        var claudeParsed = 0
        var minimaxParsed = 0
        var parseFailures = 0
        var seenCurrentIds = Set<String>()
        var duplicateCurrentIds = Set<String>()
        for locator in locators {
            switch try await adapter.parseSessionInfo(locator: locator) {
            case .success(let info):
                parsed += 1
                if info.source == .minimax {
                    minimaxParsed += 1
                    continue
                }
                guard info.source == .claudeCode else { continue }
                claudeParsed += 1
                if !seenCurrentIds.insert(info.id).inserted {
                    duplicateCurrentIds.insert(info.id)
                }
            case .failure:
                parseFailures += 1
            }
        }
        XCTAssertGreaterThan(claudeParsed, 0)

        let writer = try EngramDatabaseWriter(path: home.appendingPathComponent(".engram/index.sqlite").path)
        let row = try writer.read { db in
            try Row.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) AS rows,
                       SUM(CASE WHEN agent_role = 'subagent' THEN 1 ELSE 0 END) AS subagents,
                       SUM(CASE WHEN COALESCE(NULLIF(source_locator, ''), file_path) LIKE '%/subagents/workflows/%' THEN 1 ELSE 0 END) AS workflow_subagents
                FROM sessions
                WHERE source = 'claude-code'
                  AND COALESCE(NULLIF(source_locator, ''), file_path) LIKE '/Users/bing/.claude/projects/%'
                """
            )
        }
        let dbIds = try writer.read { db in
            try Set(String.fetchAll(
                db,
                sql: """
                SELECT id
                FROM sessions
                WHERE source = 'claude-code'
                  AND COALESCE(NULLIF(source_locator, ''), file_path) LIKE '/Users/bing/.claude/projects/%'
                """
            ))
        }

        XCTAssertEqual(seenCurrentIds.subtracting(dbIds), [])
        print(
            "LIVE_CLAUDE_CODE_CORPUS_SMOKE locators=\(locators.count) parsed=\(parsed) claude_parsed=\(claudeParsed) minimax_parsed=\(minimaxParsed) parse_failures=\(parseFailures) unique_ids=\(seenCurrentIds.count) duplicate_ids=\(duplicateCurrentIds.count) db_rows=\(row?["rows"] as Int? ?? 0) db_subagents=\(row?["subagents"] as Int? ?? 0) db_workflow_subagents=\(row?["workflow_subagents"] as Int? ?? 0)"
        )
    }

    func testClaudeCodeLegacyRootAgentFileParsesAsSubagent() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectsRoot = root.appendingPathComponent(".claude/projects", isDirectory: true)
        let projectDir = projectsRoot.appendingPathComponent("-Users-bing--Code--Legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let transcript = projectDir.appendingPathComponent("agent-legacy.jsonl")
        try writeJSONL(
            [
                [
                    "type": "user",
                    "isSidechain": true,
                    "sessionId": "legacy-parent-session",
                    "agentId": "legacy-agent",
                    "cwd": "/Users/bing/-Code-/Legacy",
                    "timestamp": "2026-06-30T01:00:00.000Z",
                    "message": [
                        "role": "user",
                        "content": "Warmup",
                    ],
                ],
                [
                    "type": "assistant",
                    "isSidechain": true,
                    "sessionId": "legacy-parent-session",
                    "agentId": "legacy-agent",
                    "cwd": "/Users/bing/-Code-/Legacy",
                    "timestamp": "2026-06-30T01:00:01.000Z",
                    "message": [
                        "role": "assistant",
                        "content": [["type": "text", "text": "Ready."]],
                    ],
                ],
            ],
            to: transcript
        )

        let adapter = ClaudeCodeAdapter(projectsRoot: projectsRoot.path)
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: transcript.path))

        XCTAssertEqual(info.id, "legacy-agent")
        XCTAssertEqual(info.agentRole, "subagent")
        XCTAssertEqual(info.parentSessionId, "legacy-parent-session")
    }

    func testClaudeCodeSkipsLocalCommandOnlySessions() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectsRoot = root.appendingPathComponent(".claude-glmc/projects", isDirectory: true)
        let transcript = try makeClaudeCodeLocalCommandOnlyFixture(projectsRoot: projectsRoot)

        let adapter = ClaudeCodeAdapter(source: .glm, projectsRoot: projectsRoot.path, originator: "Claude Code")
        switch try await adapter.parseSessionInfo(locator: transcript.path) {
        case .success(let info):
            XCTFail("expected local-command-only session to be skipped, got messageCount=\(info.messageCount)")
        case .failure:
            break
        }
    }

    func testDefaultAdaptersRegisterCcWrapperProviderSources() {
        let sources = SessionAdapterFactory.defaultAdapters().map(\.source.rawValue)

        XCTAssertTrue(Set(sources).isSuperset(of: [
            "kimi",
            "minimax",
            "mimo",
            "qwen",
            "doubao",
            "glm",
            "deepseek",
            "codex",
        ]))
        XCTAssertGreaterThanOrEqual(sources.filter { $0 == "kimi" }.count, 2)
        XCTAssertGreaterThanOrEqual(sources.filter { $0 == "qwen" }.count, 2)
        XCTAssertGreaterThanOrEqual(sources.filter { $0 == "codex" }.count, 2)
    }

    func testIndexingPersistsClaudeCodeProviderOriginator() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectsRoot = root.appendingPathComponent(".claude-mimo/projects", isDirectory: true)
        _ = try makeClaudeCodeFixture(projectsRoot: projectsRoot)
        let adapter = ClaudeCodeAdapter(projectsRoot: projectsRoot.path)

        let indexer = SwiftIndexer(sink: AdapterMessageCountNoopSink(), adapters: [adapter])
        let snapshots = try await indexer.collectSnapshots()
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.source.rawValue, "mimo")
        let snapshotOriginator = Mirror(reflecting: try XCTUnwrap(snapshots.first))
            .children
            .first { $0.label == "originator" }?
            .value as? String
        XCTAssertEqual(snapshotOriginator, "Claude Code")

        let writer = try EngramDatabaseWriter(path: root.appendingPathComponent("index.sqlite").path)
        try writer.migrate()
        _ = try await writer.indexAllSessions(adapters: [adapter])
        let row = try writer.read { db in
            try Row.fetchOne(db, sql: "SELECT source, originator FROM sessions WHERE id = 'cc-mimo-1'")
        }
        XCTAssertEqual(row?["source"] as String?, "mimo")
        XCTAssertEqual(row?["originator"] as String?, "Claude Code")
    }

    func testLiveClaudeCodeProviderRootsIndexExpectedLocalCorpus() async throws {
        guard ProcessInfo.processInfo.environment["ENGRAM_LIVE_CC_PROVIDER_ROOT_SMOKE"] == "1" else {
            throw XCTSkip("set ENGRAM_LIVE_CC_PROVIDER_ROOT_SMOKE=1 to run against local ~/.claude-* provider roots")
        }

        let specs = [
            LiveClaudeCodeProviderRootSpec(name: "kimi", source: .kimi),
            LiveClaudeCodeProviderRootSpec(name: "minimax", source: .minimax),
            LiveClaudeCodeProviderRootSpec(name: "mimo", source: .mimo),
            LiveClaudeCodeProviderRootSpec(name: "mimosg", source: .mimo),
            LiveClaudeCodeProviderRootSpec(name: "qwen", source: .qwen),
            LiveClaudeCodeProviderRootSpec(name: "doubao", source: .doubao),
            LiveClaudeCodeProviderRootSpec(name: "glm", source: .glm),
            LiveClaudeCodeProviderRootSpec(name: "glmc", source: .glm),
            LiveClaudeCodeProviderRootSpec(name: "ds", source: .deepseek),
            LiveClaudeCodeProviderRootSpec(name: "dsc", source: .deepseek),
            LiveClaudeCodeProviderRootSpec(name: "openai", source: .codex),
        ]
        let falsePositivePath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-glmc/projects/-Users-bing--Code--DrCom/2b9addbc-e168-48d7-af0c-3320bb7faf66.jsonl")
            .path
        let runRoot = tempDir()
        defer { try? FileManager.default.removeItem(at: runRoot) }

        var adapters: [any SessionAdapter] = []
        var expected: [(name: String, source: SourceName, parsed: Int, subagents: Int)] = []

        for spec in specs {
            let projectsRoot = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude-\(spec.name)/projects", isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: projectsRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw XCTSkip("missing local provider root: \(projectsRoot.path)")
            }

            let adapter = ClaudeCodeAdapter(
                source: spec.source,
                projectsRoot: projectsRoot.path,
                originator: "Claude Code"
            )
            let locators = try await adapter.listSessionLocators()
            var parsed = 0
            var subagents = 0
            for locator in locators {
                switch try await adapter.parseSessionInfo(locator: locator) {
                case .success(let info):
                    XCTAssertNotEqual(locator, falsePositivePath, "local-command-only side channel must not parse")
                    XCTAssertEqual(info.source, spec.source)
                    XCTAssertEqual(info.originator, "Claude Code")
                    let streamed = try await drain(adapter, locator: locator)
                    XCTAssertEqual(info.messageCount, streamed.count, "stream/count mismatch for \(locator)")
                    parsed += 1
                    if info.agentRole == "subagent" {
                        subagents += 1
                    }
                case .failure:
                    break
                }
            }

            XCTAssertGreaterThan(parsed, 0, "expected parseable conversations under \(projectsRoot.path)")
            adapters.append(adapter)
            expected.append((name: spec.name, source: spec.source, parsed: parsed, subagents: subagents))
        }

        let writer = try EngramDatabaseWriter(path: runRoot.appendingPathComponent("index.sqlite").path)
        try writer.migrate()
        _ = try await writer.indexAllSessions(adapters: adapters)

        var totalActual = 0
        var totalExpected = 0
        for item in expected {
            let rootPattern = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude-\(item.name)/projects")
                .path + "/%"
            let row = try writer.read { db in
                try Row.fetchOne(
                    db,
                    sql: """
                    SELECT COUNT(*) AS actual,
                           SUM(CASE WHEN agent_role = 'subagent' THEN 1 ELSE 0 END) AS subagents
                    FROM sessions
                    WHERE source = ?
                      AND COALESCE(NULLIF(source_locator, ''), file_path) LIKE ?
                    """,
                    arguments: [item.source.rawValue, rootPattern]
                )
            }
            let actual: Int = row?["actual"] ?? 0
            let actualSubagents: Int = row?["subagents"] ?? 0
            XCTAssertEqual(actual, item.parsed, "row count mismatch for .claude-\(item.name)")
            XCTAssertEqual(actualSubagents, item.subagents, "subagent count mismatch for .claude-\(item.name)")
            totalActual += actual
            totalExpected += item.parsed
            print(
                "LIVE_CC_PROVIDER_ROOT_SMOKE root=.claude-\(item.name) source=\(item.source.rawValue) expected=\(item.parsed) actual=\(actual) subagents=\(actualSubagents)"
            )
        }

        let falsePositiveCount = try writer.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sessions WHERE COALESCE(NULLIF(source_locator, ''), file_path) = ?",
                arguments: [falsePositivePath]
            ) ?? 0
        }
        XCTAssertEqual(falsePositiveCount, 0)
        XCTAssertEqual(totalActual, totalExpected)
        print("LIVE_CC_PROVIDER_ROOT_SMOKE total_expected=\(totalExpected) total_actual=\(totalActual)")
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

    func testVsCodeUsesSessionWorkingDirectoryWhenWorkspaceJsonMissing() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatDir = root.appendingPathComponent("ws-working-dir/chatSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: chatDir, withIntermediateDirectories: true)

        let session: [String: Any] = [
            "kind": 0,
            "v": [
                "sessionId": "vs-working-dir",
                "creationDate": 1_700_000_000_000,
                "workingDirectory": "file:///Users/test/from-session",
                "requests": [
                    [
                        "timestamp": 1_700_000_000_000,
                        "message": ["text": "cwd fallback"],
                        "response": [
                            ["value": ["kind": "markdownContent", "content": ["value": "ok"]]]
                        ],
                    ],
                ],
            ],
        ]
        let file = chatDir.appendingPathComponent("sess.jsonl")
        try (try jsonLine(session) + "\n").write(to: file, atomically: true, encoding: .utf8)

        let adapter = VsCodeAdapter(workspaceStorageDir: root.path)
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: file.path))

        XCTAssertEqual(info.cwd, "/Users/test/from-session")
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

    func testGeminiListsNativeNestedSubagentJsonlFilesWithParentLinks() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDir = root.appendingPathComponent("tmp/hash-001", isDirectory: true)
        let subagentDir = projectDir.appendingPathComponent(
            "chats/parent-session-001",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: subagentDir, withIntermediateDirectories: true)
        try "/Users/test/gemini".write(
            to: projectDir.appendingPathComponent(".project_root"),
            atomically: true,
            encoding: .utf8
        )

        let lines: [[String: Any]] = [
            [
                "kind": "subagent",
                "sessionId": "subagent-session-001",
                "projectHash": "hash-001",
                "startTime": "2026-06-22T01:00:00.000Z",
                "lastUpdated": "2026-06-22T01:00:00.000Z",
            ],
            [
                "id": "m1",
                "timestamp": "2026-06-22T01:00:01.000Z",
                "type": "user",
                "content": [["text": "subagent task"]],
            ],
            [
                "id": "m2",
                "timestamp": "2026-06-22T01:00:02.000Z",
                "type": "gemini",
                "content": "subagent answer",
            ],
        ]
        let file = subagentDir.appendingPathComponent("subagent-session-001.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

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

        XCTAssertEqual(info.id, "subagent-session-001")
        XCTAssertEqual(info.agentRole, "subagent")
        XCTAssertEqual(info.parentSessionId, "parent-session-001")
        XCTAssertEqual(info.project, "hash-001")
        XCTAssertEqual(info.cwd, "/Users/test/gemini")
        XCTAssertEqual(info.messageCount, 2)
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

        XCTAssertEqual(streamed.map(\.content), ["first\nsecond"])
    }

    func testIflowSkipsSystemInjectionInStreamCount() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDir = root.appendingPathComponent("projects/-Users-test-iflow-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let lines: [[String: Any]] = [
            [
                "uuid": "iflow-system-1",
                "sessionId": "iflow-system-1",
                "timestamp": "2026-06-01T10:00:00.000Z",
                "type": "user",
                "message": [
                    "role": "user",
                    "content": "# AGENTS.md instructions for /tmp/iflow-project\n\n<INSTRUCTIONS>system prompt</INSTRUCTIONS>",
                ],
                "cwd": "/tmp/iflow-project",
            ],
            [
                "uuid": "iflow-system-2",
                "sessionId": "iflow-system-1",
                "timestamp": "2026-06-01T10:00:01.000Z",
                "type": "user",
                "message": [
                    "role": "user",
                    "content": "real prompt",
                ],
                "cwd": "/tmp/iflow-project",
            ],
            [
                "uuid": "iflow-system-3",
                "sessionId": "iflow-system-1",
                "timestamp": "2026-06-01T10:00:02.000Z",
                "type": "assistant",
                "message": [
                    "role": "assistant",
                    "content": [
                        ["type": "text", "text": "answer"],
                    ],
                ],
                "cwd": "/tmp/iflow-project",
            ],
        ]
        let file = projectDir.appendingPathComponent("session-system.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = IflowAdapter(projectsRoot: root.appendingPathComponent("projects").path)
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: file.path))
        let streamed = try await drain(adapter, locator: file.path)

        XCTAssertEqual(info.systemMessageCount, 1)
        XCTAssertEqual(info.userMessageCount, 1)
        XCTAssertEqual(info.assistantMessageCount, 1)
        XCTAssertEqual(info.messageCount, streamed.count)
        XCTAssertEqual(streamed.map(\.content), ["real prompt", "answer"])
    }

    func testIflowSkipsToolOnlyTurnsInStreamCount() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDir = root.appendingPathComponent("projects/-Users-test-iflow-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let lines: [[String: Any]] = [
            [
                "uuid": "iflow-tool-1",
                "sessionId": "iflow-tool-only-1",
                "timestamp": "2026-06-01T10:00:00.000Z",
                "type": "user",
                "message": [
                    "role": "user",
                    "content": "real prompt",
                ],
                "cwd": "/tmp/iflow-project",
            ],
            [
                "uuid": "iflow-tool-2",
                "sessionId": "iflow-tool-only-1",
                "timestamp": "2026-06-01T10:00:01.000Z",
                "type": "assistant",
                "message": [
                    "role": "assistant",
                    "content": [
                        ["type": "tool_use", "name": "read_file"],
                    ],
                ],
                "cwd": "/tmp/iflow-project",
            ],
            [
                "uuid": "iflow-tool-3",
                "sessionId": "iflow-tool-only-1",
                "timestamp": "2026-06-01T10:00:02.000Z",
                "type": "user",
                "message": [
                    "role": "user",
                    "content": [
                        ["type": "tool_result", "content": "file output"],
                    ],
                ],
                "cwd": "/tmp/iflow-project",
            ],
            [
                "uuid": "iflow-tool-4",
                "sessionId": "iflow-tool-only-1",
                "timestamp": "2026-06-01T10:00:03.000Z",
                "type": "assistant",
                "message": [
                    "role": "assistant",
                    "content": [
                        ["type": "text", "text": "answer"],
                    ],
                ],
                "cwd": "/tmp/iflow-project",
            ],
        ]
        let file = projectDir.appendingPathComponent("session-tool-only.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = IflowAdapter(projectsRoot: root.appendingPathComponent("projects").path)
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: file.path))
        let streamed = try await drain(adapter, locator: file.path)

        XCTAssertEqual(info.userMessageCount, 1)
        XCTAssertEqual(info.assistantMessageCount, 1)
        XCTAssertEqual(info.messageCount, 2)
        XCTAssertEqual(streamed.map(\.content), ["real prompt", "answer"])
    }

    // MARK: - CommandCode

    func testCommandCodeSkipsSystemInjectionInStreamCount() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDir = root.appendingPathComponent("projects/users-test-commandcode-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let lines: [[String: Any]] = [
            [
                "id": "cc-system-1",
                "sessionId": "cc-system-1",
                "role": "user",
                "cwd": "/tmp/commandcode-project",
                "content": [
                    [
                        "type": "text",
                        "text": "<command-message>goal</command-message>\n<command-name>/goal</command-name>",
                    ],
                ],
                "timestamp": "2026-06-01T10:00:00.000Z",
            ],
            [
                "id": "cc-system-2",
                "sessionId": "cc-system-1",
                "role": "user",
                "cwd": "/tmp/commandcode-project",
                "content": [
                    ["type": "text", "text": "real prompt"],
                ],
                "timestamp": "2026-06-01T10:00:01.000Z",
            ],
            [
                "id": "cc-system-3",
                "sessionId": "cc-system-1",
                "role": "assistant",
                "cwd": "/tmp/commandcode-project",
                "content": [
                    ["type": "text", "text": "answer"],
                ],
                "timestamp": "2026-06-01T10:00:02.000Z",
            ],
            [
                "id": "cc-system-4",
                "sessionId": "cc-system-1",
                "role": "tool",
                "cwd": "/tmp/commandcode-project",
                "content": [
                    ["type": "tool-result", "output": "tool output"],
                ],
                "timestamp": "2026-06-01T10:00:03.000Z",
            ],
        ]
        let file = projectDir.appendingPathComponent("commandcode-session.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = CommandCodeAdapter(projectsRoot: root.appendingPathComponent("projects").path)
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: file.path))
        let streamed = try await drain(adapter, locator: file.path)

        XCTAssertEqual(info.systemMessageCount, 1)
        XCTAssertEqual(info.userMessageCount, 1)
        XCTAssertEqual(info.assistantMessageCount, 1)
        XCTAssertEqual(info.toolMessageCount, 1)
        XCTAssertEqual(info.messageCount, streamed.count)
        XCTAssertEqual(streamed.map(\.role), [.user, .assistant, .tool])
        XCTAssertEqual(streamed.map(\.content), ["real prompt", "answer", "tool output"])
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

    func testKimiDiscoversAndLinksSubagentContexts() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root.appendingPathComponent("workspace-1/kimi-parent-session", isDirectory: true)
        let subagentDir = sessionDir.appendingPathComponent("subagents/agent-abc123", isDirectory: true)
        try FileManager.default.createDirectory(at: subagentDir, withIntermediateDirectories: true)

        let parentContext = sessionDir.appendingPathComponent("context.jsonl")
        try writeJSONL(
            [["role": "user", "content": "parent task"]],
            to: parentContext
        )
        let subagentContext = subagentDir.appendingPathComponent("context.jsonl")
        try writeJSONL(
            [
                ["role": "user", "content": "subagent task"],
                ["role": "assistant", "content": "subagent result"],
            ],
            to: subagentContext
        )
        try writeJSON(
            [
                "work_dirs": [[
                    "path": "/tmp/kimi-project",
                    "kaos": "workspace-1",
                    "last_session_id": "kimi-parent-session",
                ]],
            ],
            to: root.appendingPathComponent("kimi.json")
        )

        let adapter = KimiAdapter(
            sessionsRoot: root.path,
            kimiJsonPath: root.appendingPathComponent("kimi.json").path
        )
        let locators = try await adapter.listSessionLocators()

        XCTAssertEqual(
            locators.map(standardizedPath).sorted(),
            [parentContext.path, subagentContext.path].map(standardizedPath).sorted()
        )

        let info = try sessionInfo(await adapter.parseSessionInfo(locator: subagentContext.path))
        XCTAssertEqual(info.id, "agent-abc123")
        XCTAssertEqual(info.agentRole, "subagent")
        XCTAssertEqual(info.parentSessionId, "kimi-parent-session")
        XCTAssertEqual(info.cwd, "/tmp/kimi-project")
    }

    func testLiveKimiCorpusIndexesCanonicalContextLocators() async throws {
        guard ProcessInfo.processInfo.environment["ENGRAM_LIVE_KIMI_CORPUS_SMOKE"] == "1" else {
            throw XCTSkip("set ENGRAM_LIVE_KIMI_CORPUS_SMOKE=1 to scan the local Kimi corpus")
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let sessionsRoot = home.appendingPathComponent(".kimi/sessions", isDirectory: true)
        let kimiJsonPath = home.appendingPathComponent(".kimi/kimi.json")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sessionsRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw XCTSkip("missing local Kimi sessions root: \(sessionsRoot.path)")
        }

        let adapter = KimiAdapter(sessionsRoot: sessionsRoot.path, kimiJsonPath: kimiJsonPath.path)
        let locators = try await adapter.listSessionLocators()
        XCTAssertGreaterThan(locators.count, 0)

        let snapshots = try await SwiftIndexer(
            sink: AdapterMessageCountNoopSink(),
            adapters: [adapter]
        ).collectSnapshots()
        XCTAssertEqual(snapshots.count, locators.count)
        XCTAssertTrue(snapshots.allSatisfy { $0.sourceLocator.hasSuffix("/context.jsonl") })

        let runRoot = tempDir()
        defer { try? FileManager.default.removeItem(at: runRoot) }
        let writer = try EngramDatabaseWriter(path: runRoot.appendingPathComponent("index.sqlite").path)
        try writer.migrate()

        if var staleProbe = snapshots.first(where: { snapshot in
            FileManager.default.fileExists(atPath: URL(fileURLWithPath: snapshot.sourceLocator)
                .deletingLastPathComponent()
                .appendingPathComponent("wire.jsonl")
                .path)
        }) {
            let canonicalLocator = staleProbe.sourceLocator
            staleProbe.sourceLocator = URL(fileURLWithPath: canonicalLocator)
                .deletingLastPathComponent()
                .appendingPathComponent("wire.jsonl")
                .path

            try writer.write { db in
                let snapshotWriter = SessionSnapshotWriter(db: db)
                _ = try snapshotWriter.writeAuthoritativeSnapshot(staleProbe)
                var canonicalProbe = staleProbe
                canonicalProbe.sourceLocator = canonicalLocator
                let result = try snapshotWriter.writeAuthoritativeSnapshot(canonicalProbe)
                XCTAssertEqual(result.action, .merge)
            }
        } else {
            XCTFail("expected at least one Kimi session with sibling wire.jsonl")
        }

        try writer.write { db in
            let snapshotWriter = SessionSnapshotWriter(db: db)
            for snapshot in snapshots {
                _ = try snapshotWriter.writeAuthoritativeSnapshot(snapshot)
            }
        }

        let row = try writer.read { db in
            try Row.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) AS rows,
                       SUM(CASE WHEN agent_role = 'subagent' THEN 1 ELSE 0 END) AS subagents,
                       SUM(CASE WHEN COALESCE(NULLIF(source_locator, ''), file_path) NOT LIKE '%/context.jsonl' THEN 1 ELSE 0 END) AS non_canonical
                FROM sessions
                WHERE source = 'kimi'
                """
            )
        }
        let rowCount: Int = row?["rows"] ?? 0
        let subagentCount: Int = row?["subagents"] ?? 0
        let nonCanonicalCount: Int = row?["non_canonical"] ?? 0
        XCTAssertEqual(rowCount, snapshots.count)
        XCTAssertEqual(
            subagentCount,
            snapshots.filter { $0.agentRole == "subagent" }.count
        )
        XCTAssertEqual(nonCanonicalCount, 0)

        let storedLocators = try writer.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT COALESCE(NULLIF(source_locator, ''), file_path)
                FROM sessions
                WHERE source = 'kimi'
                """
            )
        }
        XCTAssertEqual(Set(storedLocators.map(standardizedPath)), Set(locators.map(standardizedPath)))
        print(
            "LIVE_KIMI_CORPUS_SMOKE locators=\(locators.count) rows=\(storedLocators.count) subagents=\(snapshots.filter { $0.agentRole == "subagent" }.count)"
        )
    }

    func testLiveKimiDatabaseRescanRefreshesCanonicalSessionRows() async throws {
        let confirmation = "I_UNDERSTAND_THIS_MUTATES_LIVE_ENGRAM_DB"
        guard ProcessInfo.processInfo.environment["ENGRAM_LIVE_KIMI_DB_RESCAN"] == confirmation else {
            throw XCTSkip("set ENGRAM_LIVE_KIMI_DB_RESCAN=\(confirmation) to write current Kimi snapshots into ~/.engram/index.sqlite")
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let databasePath = home.appendingPathComponent(".engram/index.sqlite").path
        let sessionsRoot = home.appendingPathComponent(".kimi/sessions", isDirectory: true)
        let kimiJsonPath = home.appendingPathComponent(".kimi/kimi.json")

        let adapter = KimiAdapter(sessionsRoot: sessionsRoot.path, kimiJsonPath: kimiJsonPath.path)
        let locators = try await adapter.listSessionLocators()
        XCTAssertGreaterThan(locators.count, 0)

        let snapshots = try await SwiftIndexer(
            sink: AdapterMessageCountNoopSink(),
            adapters: [adapter]
        ).collectSnapshots()
        XCTAssertEqual(snapshots.count, locators.count)

        let writer = try EngramDatabaseWriter(path: databasePath)
        try writer.write { db in
            let snapshotWriter = SessionSnapshotWriter(db: db)
            for snapshot in snapshots {
                _ = try snapshotWriter.writeAuthoritativeSnapshot(snapshot)
            }
        }

        let canonicalLocators = Set(locators.map(standardizedPath))
        let storedLocators = try writer.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT COALESCE(NULLIF(source_locator, ''), file_path)
                FROM sessions
                WHERE source = 'kimi'
                  AND COALESCE(NULLIF(source_locator, ''), file_path) LIKE '/Users/bing/.kimi/%'
                """
            )
        }
        let storedSet = Set(storedLocators.map(standardizedPath))
        XCTAssertEqual(canonicalLocators.subtracting(storedSet), [])

        let remainingNonCanonical = storedLocators.filter { locator in
            !locator.hasSuffix("/context.jsonl")
        }.count
        print(
            "LIVE_KIMI_DB_RESCAN current_locators=\(canonicalLocators.count) live_rows=\(storedLocators.count) remaining_noncanonical=\(remainingNonCanonical)"
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

    func testQwenSkipsSystemInjectionInStreamCount() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatsDir = root.appendingPathComponent("project-1/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)

        let lines: [[String: Any]] = [
            [
                "type": "user",
                "sessionId": "qwen-system-1",
                "cwd": "/tmp/qwen-project",
                "timestamp": "2026-06-01T10:00:00.000Z",
                "message": [
                    "role": "user",
                    "parts": [
                        ["text": "\nYou are Qwen Code, an interactive CLI agent. Analyze the current directory."],
                    ],
                ],
            ],
            [
                "type": "user",
                "sessionId": "qwen-system-1",
                "cwd": "/tmp/qwen-project",
                "timestamp": "2026-06-01T10:00:01.000Z",
                "message": [
                    "role": "user",
                    "parts": [["text": "real prompt"]],
                ],
            ],
            [
                "type": "assistant",
                "sessionId": "qwen-system-1",
                "cwd": "/tmp/qwen-project",
                "timestamp": "2026-06-01T10:00:02.000Z",
                "message": [
                    "role": "model",
                    "parts": [["text": "answer"]],
                ],
            ],
        ]
        let file = chatsDir.appendingPathComponent("qwen-system.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = QwenAdapter(projectsRoot: root.path)
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: file.path))
        let streamed = try await drain(adapter, locator: file.path)

        XCTAssertEqual(info.systemMessageCount, 1)
        XCTAssertEqual(info.userMessageCount, 1)
        XCTAssertEqual(info.assistantMessageCount, 1)
        XCTAssertEqual(info.messageCount, streamed.count)
        XCTAssertEqual(streamed.map(\.content), ["real prompt", "answer"])
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

        XCTAssertEqual(streamed.map(\.content), ["first\nsecond"])
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

    // MARK: - Pi

    func testPiAdapterListsParsesAndStreamsSessions() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root.appendingPathComponent("--Users-test--project--", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let file = sessionDir.appendingPathComponent(
            "2026-04-29T01-00-00-000Z_019dd6e3-91d1-7326-8299-314858773a0e.jsonl"
        )
        try writeJSONL(
            [
                [
                    "type": "session",
                    "version": 1,
                    "id": "019dd6e3-91d1-7326-8299-314858773a0e",
                    "timestamp": "2026-04-29T01:00:00.000Z",
                    "cwd": "/Users/test/project",
                ],
                [
                    "type": "model_change",
                    "id": "model-1",
                    "parentId": "019dd6e3-91d1-7326-8299-314858773a0e",
                    "timestamp": "2026-04-29T01:00:01.000Z",
                    "modelId": "mimo-v2.5-pro",
                ],
                [
                    "type": "message",
                    "id": "msg-user",
                    "parentId": "019dd6e3-91d1-7326-8299-314858773a0e",
                    "timestamp": "2026-04-29T01:00:02.000Z",
                    "message": [
                        "role": "user",
                        "content": [["type": "text", "text": "Fix the Pi parser"]],
                        "timestamp": "2026-04-29T01:00:02.000Z",
                    ],
                ],
                [
                    "type": "message",
                    "id": "msg-assistant",
                    "parentId": "msg-user",
                    "timestamp": "2026-04-29T01:00:03.000Z",
                    "message": [
                        "role": "assistant",
                        "content": [
                            ["type": "text", "text": "I will inspect it."],
                            ["type": "toolCall", "name": "read", "arguments": ["path": "/Users/test/project/package.json"]],
                        ],
                        "model": "mimo-v2.5-pro",
                        "usage": ["input": 10, "output": 5, "cacheRead": 2, "cacheWrite": 1],
                        "timestamp": "2026-04-29T01:00:03.000Z",
                    ],
                ],
                [
                    "type": "message",
                    "id": "msg-tool",
                    "parentId": "msg-assistant",
                    "timestamp": "2026-04-29T01:00:04.000Z",
                    "message": [
                        "role": "toolResult",
                        "content": [["type": "text", "text": #"{"name":"fixture"}"#]],
                        "timestamp": "2026-04-29T01:00:04.000Z",
                    ],
                ],
            ],
            to: file
        )

        let adapter = PiAdapter(sessionsRoot: root.path)
        let locators = try await adapter.listSessionLocators()
        XCTAssertEqual(locators.map(standardizedPath), [standardizedPath(file.path)])

        let info = try sessionInfo(await adapter.parseSessionInfo(locator: file.path))
        let streamed = try await drain(adapter, locator: file.path)

        XCTAssertEqual(info.id, "019dd6e3-91d1-7326-8299-314858773a0e")
        XCTAssertEqual(info.source, .pi)
        XCTAssertEqual(info.cwd, "/Users/test/project")
        XCTAssertEqual(info.model, "mimo-v2.5-pro")
        XCTAssertEqual(info.userMessageCount, 1)
        XCTAssertEqual(info.assistantMessageCount, 1)
        XCTAssertEqual(info.toolMessageCount, 1)
        XCTAssertEqual(info.messageCount, 3)
        XCTAssertEqual(info.summary, "Fix the Pi parser")
        XCTAssertEqual(streamed.map(\.role), [.user, .assistant, .tool])
        XCTAssertEqual(
            streamed[1].usage,
            TokenUsage(inputTokens: 10, outputTokens: 5, cacheReadTokens: 2, cacheCreationTokens: 1)
        )
        XCTAssertEqual(streamed[1].toolCalls?.first?.name, "read")
        XCTAssertEqual(streamed[1].toolCalls?.first?.input, #"{"path":"/Users/test/project/package.json"}"#)
    }

    // MARK: - Codex

    func testCodexUsesTurnContextModelWhenResponseItemsDoNotCarryModel() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-codex-turn-context.jsonl")

        let lines: [[String: Any]] = [
            [
                "timestamp": "2026-07-01T08:00:00.000Z",
                "type": "session_meta",
                "payload": [
                    "id": "codex-turn-context-1",
                    "timestamp": "2026-07-01T08:00:00.000Z",
                    "cwd": "/tmp/codex-turn-context",
                    "model_provider": "openai",
                ],
            ],
            [
                "timestamp": "2026-07-01T08:00:01.000Z",
                "type": "turn_context",
                "payload": [
                    "model": "gpt-5-codex",
                    "model_provider": "openai",
                ],
            ],
            [
                "timestamp": "2026-07-01T08:00:02.000Z",
                "type": "response_item",
                "payload": [
                    "type": "message",
                    "role": "user",
                    "content": [["type": "input_text", "text": "remember model"]],
                ],
            ],
        ]
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = CodexAdapter(sessionsRoot: root.path)
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: file.path))

        XCTAssertEqual(info.model, "gpt-5-codex")
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

    func testCursorReadsNestedLatestConversationSummary() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbPath = root.appendingPathComponent("state.vscdb").path
        try Self.buildCursorUsageFixture(dbPath: dbPath)

        let adapter = CursorAdapter(dbPath: dbPath)
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: "\(dbPath)?composer=cmp_usage"))

        XCTAssertEqual(info.summary, "Nested Cursor summary")
    }

    func testCursorInfersCwdFromComposerContextFileSelection() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbPath = root.appendingPathComponent("state.vscdb").path
        try Self.buildCursorUsageFixture(dbPath: dbPath)

        let adapter = CursorAdapter(dbPath: dbPath)
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: "\(dbPath)?composer=cmp_usage"))

        XCTAssertEqual(info.cwd, "/Users/test/proj/src")
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

    func testCursorRejectsMetadataOnlyComposerWithoutVisibleMessages() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbPath = root.appendingPathComponent("state.vscdb").path
        try Self.buildCursorFixture(dbPath: dbPath)

        let adapter = CursorAdapter(dbPath: dbPath)
        let result = try await adapter.parseSessionInfo(locator: "\(dbPath)?composer=cmp_1")

        switch result {
        case .success(let info):
            XCTFail("metadata-only Cursor composer should not parse as session, got messageCount=\(info.messageCount)")
        case .failure(let failure):
            // A composer with zero visible messages is valid-but-empty, not
            // malformed → terminal .noVisibleMessages (no perpetual re-parse).
            XCTAssertEqual(failure, .noVisibleMessages)
        }
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
        try exec("INSERT INTO cursorDiskKV VALUES ('composerData:cmp_usage', '{\"composerId\":\"cmp_usage\",\"latestConversationSummary\":{\"summary\":{\"summary\":\"Nested Cursor summary\"}},\"context\":{\"fileSelections\":[{\"uri\":{\"fsPath\":\"/Users/test/proj/src/index.ts\"}}]}}')")
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

    func testAntigravityCWDInferenceIgnoresMarkupLikeSlashTokens() {
        let text = """
        {"content":"</bash_command_reminder>\\n<foo/bar>"}
        {"content":"/Users/bing/-Code-/engram\\"}
        """

        XCTAssertEqual(AntigravityAdapter.inferCWDFromAbsolutePaths(in: text), "")
    }

    func testAntigravityCWDInferenceIgnoresURLAndRouteLikeSlashTokens() {
        let text = """
        {"content":"https://github.com/bbingz/engram and http://localhost:5173/components/ui"}
        {"content":"Menu: /编辑/视图 /reports /CI/Bug修复 /components/ui"}
        """

        XCTAssertEqual(AntigravityAdapter.inferCWDFromAbsolutePaths(in: text), "")
    }

    func testAntigravityCWDInferenceReturnsEmptyWithoutPaths() {
        XCTAssertEqual(AntigravityAdapter.inferCWDFromAbsolutePaths(in: "no absolute paths in auth.ts here"), "")
    }
}

private struct AdapterMessageCountNoopSink: IndexingWriteSink {
    func upsertBatch(
        _ snapshots: [AuthoritativeSessionSnapshot],
        reason: IndexingWriteReason
    ) throws -> SessionBatchUpsertResult {
        SessionBatchUpsertResult(
            reason: reason,
            results: snapshots.map {
                SessionBatchItemResult(sessionId: $0.id, action: .merge, enqueuedJobs: [])
            }
        )
    }
}
