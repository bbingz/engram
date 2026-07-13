import XCTest
import SQLite3
@testable import Engram

final class AdapterParityTests: XCTestCase {
    private var fixtureRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("tests/fixtures/adapter-parity")
    }

    func testParserFailureCategoriesMatchStage2Contract() {
        XCTAssertEqual(
            ParserFailure.allCases.map(\.rawValue),
            [
                "fileMissing",
                "fileTooLarge",
                "invalidUtf8",
                "truncatedJSON",
                "truncatedJSONL",
                "malformedJSON",
                "malformedToolCall",
                "deeplyNestedRecord",
                "messageLimitExceeded",
                "lineTooLarge",
                "fileModifiedDuringParse",
                "sqliteUnreadable",
                "grpcUnavailable",
                "unsupportedVirtualLocator",
                "noVisibleMessages"
            ]
        )
    }

    func testSharedModelMirrorsNodeSourceAndMessageContracts() {
        let message = NormalizedMessage(
            role: .assistant,
            content: "implemented",
            timestamp: "2026-04-23T10:00:00.000Z",
            toolCalls: [
                NormalizedToolCall(
                    name: "Read",
                    input: "{\"file_path\":\"/tmp/a.swift\"}",
                    output: nil
                )
            ],
            usage: TokenUsage(
                inputTokens: 10,
                outputTokens: 5,
                cacheReadTokens: 2,
                cacheCreationTokens: 1
            )
        )

        XCTAssertEqual(SourceName.allCases.map(\.rawValue).sorted().first, "antigravity")
        XCTAssertEqual(message.role.rawValue, "assistant")
        XCTAssertEqual(message.toolCalls?.first?.name, "Read")
        XCTAssertEqual(message.usage?.cacheCreationTokens, 1)
    }

    func testAdapterFactoriesCoverEveryKnownSource() {
        XCTAssertEqual(
            Set(SessionAdapterFactory.defaultAdapters().map(\.source)),
            Set(SourceName.allCases)
        )
        XCTAssertEqual(
            Set(SessionAdapterFactory.recentActiveAdapters().map(\.source)),
            Set(SourceName.allCases)
        )
    }

    func testClaudeCodeOriginatorClassifierMatchesCodexAndGeminiSpellings() {
        XCTAssertTrue(OriginatorClassifier.isClaudeCode("Claude Code"))
        XCTAssertTrue(OriginatorClassifier.isClaudeCode("claude-code"))
        XCTAssertTrue(OriginatorClassifier.isClaudeCode("CLAUDE_CODE"))
        XCTAssertFalse(OriginatorClassifier.isClaudeCode("codex_cli_rs"))
        XCTAssertFalse(OriginatorClassifier.isClaudeCode(nil))
    }

    func testClaudeDerivedSourceAdaptersExposeMinimaxAndLobsterSessions() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-derived-\(UUID().uuidString)", isDirectory: true)
        let minimaxProject = root.appendingPathComponent("project", isDirectory: true)
        let lobsterProject = root.appendingPathComponent("lobsterai-project", isDirectory: true)
        let hiddenLobsterProject = root.appendingPathComponent(".lobsterai-project", isDirectory: true)
        let hiddenDecoyProject = root.appendingPathComponent(".lobsteraiproject", isDirectory: true)
        let decoyProject = root.appendingPathComponent("notlobsterai-project", isDirectory: true)
        try FileManager.default.createDirectory(at: minimaxProject, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: lobsterProject, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hiddenLobsterProject, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hiddenDecoyProject, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: decoyProject, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let minimaxLocator = minimaxProject.appendingPathComponent("minimax.jsonl")
        let lobsterLocator = lobsterProject.appendingPathComponent("claude.jsonl")
        let hiddenLobsterLocator = hiddenLobsterProject.appendingPathComponent("claude.jsonl")
        let hiddenDecoyLocator = hiddenDecoyProject.appendingPathComponent("claude.jsonl")
        let decoyLocator = decoyProject.appendingPathComponent("claude.jsonl")
        try claudeFixture(sessionId: "minimax-session", model: "minimax-m1").write(
            to: minimaxLocator,
            atomically: true,
            encoding: .utf8
        )
        try claudeFixture(sessionId: "lobster-session", model: "claude-sonnet").write(
            to: lobsterLocator,
            atomically: true,
            encoding: .utf8
        )
        try claudeFixture(sessionId: "hidden-lobster-session", model: "claude-sonnet").write(
            to: hiddenLobsterLocator,
            atomically: true,
            encoding: .utf8
        )
        try claudeFixture(sessionId: "hidden-claude-session", model: "claude-sonnet").write(
            to: hiddenDecoyLocator,
            atomically: true,
            encoding: .utf8
        )
        try claudeFixture(sessionId: "claude-session", model: "claude-sonnet").write(
            to: decoyLocator,
            atomically: true,
            encoding: .utf8
        )

        let minimax = ClaudeCodeDerivedSourceAdapter(source: .minimax, projectsRoot: root.path)
        let lobster = ClaudeCodeDerivedSourceAdapter(source: .lobsterai, projectsRoot: root.path)
        let claude = ClaudeCodeAdapter(projectsRoot: root.path)

        let minimaxLocators = try await minimax.listSessionLocators()
        let lobsterLocators = try await lobster.listSessionLocators()
        XCTAssertEqual(minimaxLocators.map(standardizedPath), [standardizedPath(minimaxLocator.path)])
        XCTAssertEqual(
            lobsterLocators.map(standardizedPath).sorted(),
            [standardizedPath(lobsterLocator.path), standardizedPath(hiddenLobsterLocator.path)].sorted()
        )
        guard case .success(let minimaxInfo) = try await minimax.parseSessionInfo(locator: minimaxLocator.path) else {
            return XCTFail("minimax fixture did not parse")
        }
        guard case .success(let lobsterInfo) = try await lobster.parseSessionInfo(locator: lobsterLocator.path) else {
            return XCTFail("lobster fixture did not parse")
        }
        XCTAssertEqual(minimaxInfo.source, .minimax)
        XCTAssertEqual(lobsterInfo.source, .lobsterai)
        guard case .success(let hiddenLobsterInfo) = try await lobster.parseSessionInfo(locator: hiddenLobsterLocator.path) else {
            return XCTFail("hidden Lobster fixture did not parse")
        }
        XCTAssertEqual(hiddenLobsterInfo.source, .lobsterai)
        guard case .success(let hiddenDecoyInfo) = try await claude.parseSessionInfo(locator: hiddenDecoyLocator.path) else {
            return XCTFail("hidden decoy Claude fixture did not parse")
        }
        XCTAssertEqual(hiddenDecoyInfo.source, .claudeCode)
        guard case .success(let decoyInfo) = try await claude.parseSessionInfo(locator: decoyLocator.path) else {
            return XCTFail("decoy Claude fixture did not parse")
        }
        XCTAssertEqual(decoyInfo.source, .claudeCode)
    }

    func testClaudeDerivedSourceLocatorFilteringDoesNotRequireFullParse() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-derived-lightweight-\(UUID().uuidString)", isDirectory: true)
        let minimaxProject = root.appendingPathComponent("project", isDirectory: true)
        let lobsterProject = root.appendingPathComponent("lobsterai-project", isDirectory: true)
        let decoyProject = root.appendingPathComponent("notlobsterai-project", isDirectory: true)
        try FileManager.default.createDirectory(at: minimaxProject, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: lobsterProject, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: decoyProject, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let minimaxLocator = minimaxProject.appendingPathComponent("minimax.jsonl")
        let lobsterLocator = lobsterProject.appendingPathComponent("claude.jsonl")
        let decoyLocator = decoyProject.appendingPathComponent("claude.jsonl")
        let extraClaudeLine = """
        {"type":"user","sessionId":"extra","cwd":"/repo","timestamp":"2026-04-24T01:02:00.000Z","message":{"content":"extra"}}

        """
        try (claudeFixture(sessionId: "minimax-session", model: "minimax-m1") + extraClaudeLine).write(
            to: minimaxLocator,
            atomically: true,
            encoding: .utf8
        )
        try claudeFixture(sessionId: "lobster-session", model: "claude-sonnet").write(
            to: lobsterLocator,
            atomically: true,
            encoding: .utf8
        )
        try claudeFixture(sessionId: "claude-session", model: "claude-sonnet").write(
            to: decoyLocator,
            atomically: true,
            encoding: .utf8
        )

        let minimax = ClaudeCodeDerivedSourceAdapter(
            source: .minimax,
            projectsRoot: root.path,
            limits: ParserLimits(maxFileBytes: 1024 * 1024, maxLineBytes: 1024, maxMessages: 1)
        )
        let lobster = ClaudeCodeDerivedSourceAdapter(
            source: .lobsterai,
            projectsRoot: root.path,
            limits: ParserLimits(maxFileBytes: 1, maxLineBytes: 1024, maxMessages: 1)
        )

        let minimaxLocators = try await minimax.listSessionLocators().map(standardizedPath)
        let lobsterLocators = try await lobster.listSessionLocators().map(standardizedPath)
        XCTAssertEqual(minimaxLocators, [standardizedPath(minimaxLocator.path)])
        XCTAssertEqual(lobsterLocators, [standardizedPath(lobsterLocator.path)])
    }

    func testClaudeDerivedAdaptersShareBaseAndSourceHintCache() throws {
        let factory = try source("macos/Shared/EngramCore/Adapters/SessionAdapterFactory.swift")
        let messageParser = try source("macos/Engram/Core/MessageParser.swift")
        let adapter = try source("macos/Shared/EngramCore/Adapters/Sources/ClaudeCodeAdapter.swift")

        XCTAssertTrue(
            factory.contains("let claudeCode = defaultClaudeCodeAdapter(sourceHintCacheDirectory: cacheDirectory)"),
            "Default adapter construction should share one Claude base between Claude and derived sources"
        )
        XCTAssertTrue(
            factory.contains("ClaudeCodeDerivedSourceAdapter(source: .minimax, base: claudeCode)"),
            "Minimax derived source should reuse the shared Claude base instead of re-enumerating its own base"
        )
        XCTAssertTrue(
            factory.contains("ClaudeCodeDerivedSourceAdapter(source: .lobsterai, base: claudeCode)"),
            "LobsterAI derived source should reuse the shared Claude base instead of re-enumerating its own base"
        )
        XCTAssertTrue(
            messageParser.contains("let claudeCode = ClaudeCodeAdapter(profileResolver: resolver)"),
            "The UI registry should construct Claude from the profile resolver"
        )
        XCTAssertTrue(
            messageParser.contains("ClaudeCodeDerivedSourceAdapter(source: .minimax, base: claudeCode)") &&
                messageParser.contains("ClaudeCodeDerivedSourceAdapter(source: .lobsterai, base: claudeCode)"),
            "The UI registry should share one resolver-backed Claude base with both derived sources"
        )
        XCTAssertTrue(
            adapter.contains("sourceHintCache"),
            "ClaudeCodeAdapter should cache locator source hints so derived sources do not re-read the same heads"
        )
        XCTAssertTrue(
            adapter.contains("init(source: SourceName, base: ClaudeCodeAdapter)"),
            "Derived adapters should support sharing a ClaudeCodeAdapter base"
        )
    }

    func testClaudeAdapterKeepsRoutedProviderModelsUnderClaudeCodeSource() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-routed-provider-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let locator = project.appendingPathComponent("kimi.jsonl")
        try claudeFixture(sessionId: "routed-provider-session", model: "kimi-k2").write(
            to: locator,
            atomically: true,
            encoding: .utf8
        )

        let adapter = ClaudeCodeAdapter(projectsRoot: root.path)
        guard case .success(let info) = try await adapter.parseSessionInfo(locator: locator.path) else {
            return XCTFail("routed provider fixture did not parse")
        }

        XCTAssertEqual(info.source, .claudeCode)
        XCTAssertEqual(info.model, "kimi-k2")
    }

    func testQoderAdapterParsesClaudeCompatibleProjectJsonl() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoder-adapter-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("-Users-test-my-project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let locator = project.appendingPathComponent("qoder-session.jsonl")
        try Data(contentsOf: fixtureRoot.deletingLastPathComponent().appendingPathComponent("qoder/sample.jsonl"))
            .write(to: locator)

        let adapter = QoderAdapter(projectsRoot: root.path)
        let locators = try await adapter.listSessionLocators().map(standardizedPath)
        XCTAssertEqual(locators, [standardizedPath(locator.path)])
        guard case .success(let info) = try await adapter.parseSessionInfo(locator: locator.path) else {
            return XCTFail("qoder fixture did not parse")
        }

        XCTAssertEqual(info.id, "qoder-session-001")
        XCTAssertEqual(info.source, .qoder)
        XCTAssertEqual(info.cwd, "/Users/test/my-project")
        XCTAssertEqual(info.userMessageCount, 1)
        XCTAssertEqual(info.assistantMessageCount, 2)
        XCTAssertEqual(info.toolMessageCount, 1)
        XCTAssertEqual(info.summary, "Review the parser")

        var messages: [NormalizedMessage] = []
        for try await message in try await adapter.streamMessages(locator: locator.path, options: StreamMessagesOptions()) {
            messages.append(message)
        }
        XCTAssertEqual(messages.map(\.role), [.user, .assistant, .assistant, .tool])
        XCTAssertEqual(messages.flatMap { $0.toolCalls ?? [] }.first?.name, "Read")
    }

    func testQoderAdapterListsSubagentSessions() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoder-subagents-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("-Users-test-my-project", isDirectory: true)
        let parent = project.appendingPathComponent("qoder-parent-session", isDirectory: true)
        let subagents = parent.appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let locator = subagents.appendingPathComponent("qoder-subagent.jsonl")
        try Data(contentsOf: fixtureRoot.deletingLastPathComponent().appendingPathComponent("qoder/sample.jsonl"))
            .write(to: locator)

        let adapter = QoderAdapter(projectsRoot: root.path)
        let locators = try await adapter.listSessionLocators().map(standardizedPath)
        XCTAssertEqual(locators, [standardizedPath(locator.path)])
        guard case .success(let info) = try await adapter.parseSessionInfo(locator: locator.path) else {
            return XCTFail("qoder subagent fixture did not parse")
        }

        XCTAssertEqual(info.agentRole, "subagent")
        XCTAssertEqual(info.parentSessionId, "qoder-parent-session")
    }

    func testQoderDirectProjectSubagentFolderDoesNotInventParentSession() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoder-direct-subagents-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("-Volumes-work-my-project", isDirectory: true)
        let subagents = project.appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let locator = subagents.appendingPathComponent("qoder-subagent.jsonl")
        try Data(contentsOf: fixtureRoot.deletingLastPathComponent().appendingPathComponent("qoder/sample.jsonl"))
            .write(to: locator)

        let adapter = QoderAdapter(projectsRoot: root.path)
        let locators = try await adapter.listSessionLocators().map(standardizedPath)
        XCTAssertEqual(locators, [standardizedPath(locator.path)])
        guard case .success(let info) = try await adapter.parseSessionInfo(locator: locator.path) else {
            return XCTFail("qoder direct subagent fixture did not parse")
        }

        XCTAssertEqual(info.agentRole, "subagent")
        XCTAssertNil(info.parentSessionId)
    }

    func testCommandCodeAdapterParsesRoleContentJsonl() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("commandcode-adapter-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("-Users-test-my-project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let locator = project.appendingPathComponent("commandcode-session.jsonl")
        try Data(contentsOf: fixtureRoot.deletingLastPathComponent().appendingPathComponent("commandcode/sample.jsonl"))
            .write(to: locator)
        try "{}\n".write(
            to: project.appendingPathComponent("commandcode-session.checkpoints.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let adapter = CommandCodeAdapter(projectsRoot: root.path)
        let locators = try await adapter.listSessionLocators().map(standardizedPath)
        XCTAssertEqual(locators, [standardizedPath(locator.path)])
        guard case .success(let info) = try await adapter.parseSessionInfo(locator: locator.path) else {
            return XCTFail("commandcode fixture did not parse")
        }

        XCTAssertEqual(info.id, "commandcode-session-001")
        XCTAssertEqual(info.source, .commandcode)
        XCTAssertEqual(info.cwd, "/Users/test/my-project")
        XCTAssertEqual(info.model, "command-code-agent")
        XCTAssertEqual(info.userMessageCount, 1)
        XCTAssertEqual(info.assistantMessageCount, 1)
        XCTAssertEqual(info.toolMessageCount, 1)
        XCTAssertEqual(info.summary, "检查解析器")

        var messages: [NormalizedMessage] = []
        for try await message in try await adapter.streamMessages(locator: locator.path, options: StreamMessagesOptions()) {
            messages.append(message)
        }
        XCTAssertEqual(messages.map(\.role), [.user, .assistant, .tool])
        XCTAssertEqual(messages.flatMap { $0.toolCalls ?? [] }.first?.name, "read_file")
        XCTAssertTrue(messages.flatMap { $0.toolCalls ?? [] }.first?.input?.contains(#""path":"/Users/test/my-project/src/parser.ts""#) ?? false)
    }

    func testCommandCodeAdapterAcceptsArgsForToolCallInput() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("commandcode-args-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("-Users-test-my-project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let locator = project.appendingPathComponent("commandcode-session.jsonl")
        try """
        {"id":"msg-001","sessionId":"commandcode-session-args","role":"assistant","content":[{"type":"tool-call","toolName":"read_file","args":{"path":"/tmp/file.txt"}}],"timestamp":"2026-05-20T02:00:01.000Z"}
        """.write(to: locator, atomically: true, encoding: .utf8)

        let adapter = CommandCodeAdapter(projectsRoot: root.path)
        var messages: [NormalizedMessage] = []
        for try await message in try await adapter.streamMessages(locator: locator.path, options: StreamMessagesOptions()) {
            messages.append(message)
        }

        XCTAssertEqual(messages.flatMap { $0.toolCalls ?? [] }.first?.input, #"{"path":"/tmp/file.txt"}"#)
    }

    func testAntigravityAdapterListsAndParsesCliBrainTranscripts() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-cli-\(UUID().uuidString)", isDirectory: true)
        let transcriptDir = root.appendingPathComponent("brain/ag-cli-session/.system_generated/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: transcriptDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let locator = transcriptDir.appendingPathComponent("transcript.jsonl")
        try Data(contentsOf: fixtureRoot.deletingLastPathComponent().appendingPathComponent("antigravity-cli/transcript.jsonl"))
            .write(to: locator)

        let adapter = AntigravityAdapter(
            cacheDir: root.appendingPathComponent("missing-cache").path,
            conversationsDir: root.appendingPathComponent("missing-conversations").path,
            cliBrainDir: root.appendingPathComponent("brain").path
        )

        let locators = try await adapter.listSessionLocators().map(standardizedPath)
        XCTAssertEqual(locators, [standardizedPath(locator.path)])
        guard case .success(let info) = try await adapter.parseSessionInfo(locator: locator.path) else {
            return XCTFail("antigravity cli fixture did not parse")
        }

        XCTAssertEqual(info.id, "ag-cli-session")
        XCTAssertEqual(info.source, .antigravity)
        XCTAssertEqual(info.userMessageCount, 1)
        XCTAssertEqual(info.assistantMessageCount, 2)
        XCTAssertEqual(info.toolMessageCount, 1)
        XCTAssertEqual(info.summary, "Review the Antigravity CLI parser")

        var messages: [NormalizedMessage] = []
        for try await message in try await adapter.streamMessages(locator: locator.path, options: StreamMessagesOptions()) {
            messages.append(message)
        }
        XCTAssertEqual(messages.map(\.role), [.user, .assistant, .tool, .assistant])
        XCTAssertEqual(messages.flatMap { $0.toolCalls ?? [] }.first?.name, "Read")
    }

    func testAntigravityCliIgnoresUnknownContentEvents() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-cli-unknown-\(UUID().uuidString)", isDirectory: true)
        let transcriptDir = root.appendingPathComponent("brain/ag-cli-session/.system_generated/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: transcriptDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let locator = transcriptDir.appendingPathComponent("transcript.jsonl")
        try """
        {"type":"USER_INPUT","created_at":"2026-05-20T03:00:00Z","content":"Review the parser"}
        {"type":"MEMORY_NOTE","created_at":"2026-05-20T03:00:01Z","content":"internal memory"}
        {"type":"PLANNER_RESPONSE","created_at":"2026-05-20T03:00:02Z","content":"Done."}
        """.write(to: locator, atomically: true, encoding: .utf8)

        let adapter = AntigravityAdapter(
            cacheDir: root.appendingPathComponent("missing-cache").path,
            conversationsDir: root.appendingPathComponent("missing-conversations").path,
            cliBrainDir: root.appendingPathComponent("brain").path
        )

        var messages: [NormalizedMessage] = []
        for try await message in try await adapter.streamMessages(locator: locator.path, options: StreamMessagesOptions()) {
            messages.append(message)
        }

        XCTAssertEqual(messages.map(\.role), [.user, .assistant])
        XCTAssertFalse(messages.contains { $0.content == "internal memory" })
    }

    func testAntigravityCliSessionIdUsesTranscriptContainerOutsideConfiguredRoot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-cli-external-\(UUID().uuidString)", isDirectory: true)
        let transcriptDir = root.appendingPathComponent(".gemini/antigravity-cli/brain/ag-external/.system_generated/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: transcriptDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let locator = transcriptDir.appendingPathComponent("transcript.jsonl")
        try """
        {"type":"USER_INPUT","created_at":"2026-05-20T03:00:00Z","content":"Review the parser"}
        {"type":"PLANNER_RESPONSE","created_at":"2026-05-20T03:00:01Z","content":"Done."}
        """.write(to: locator, atomically: true, encoding: .utf8)

        let adapter = AntigravityAdapter(
            cacheDir: root.appendingPathComponent("missing-cache").path,
            conversationsDir: root.appendingPathComponent("missing-conversations").path,
            cliBrainDir: root.appendingPathComponent("different-brain-root").path
        )
        guard case .success(let info) = try await adapter.parseSessionInfo(locator: locator.path) else {
            return XCTFail("external antigravity cli fixture did not parse")
        }

        XCTAssertEqual(info.id, "ag-external")
    }

    func testCodexAdapterListsArchivedSessionsNextToSessionsRoot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-archive-\(UUID().uuidString)", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let archived = root.appendingPathComponent("archived_sessions", isDirectory: true)
        let activeDir = sessions.appendingPathComponent("2026/04/29", isDirectory: true)
        try FileManager.default.createDirectory(at: activeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let activeLocator = activeDir.appendingPathComponent("rollout-active.jsonl")
        let archivedLocator = archived.appendingPathComponent("rollout-archived.jsonl")
        try codexFixture(sessionId: "active").write(to: activeLocator, atomically: true, encoding: .utf8)
        try codexFixture(sessionId: "archived").write(to: archivedLocator, atomically: true, encoding: .utf8)

        let adapter = CodexAdapter(sessionsRoot: sessions.path)
        let locators = try await adapter.listSessionLocators().map(standardizedPath)

        XCTAssertEqual(
            locators.sorted(),
            [activeLocator.path, archivedLocator.path].map(standardizedPath).sorted()
        )
    }

    func testParserLimitsUseStage2ProductionThresholdsAndIdentityChecks() throws {
        XCTAssertEqual(ParserLimits.default.maxFileBytes, 100 * 1024 * 1024)
        XCTAssertEqual(ParserLimits.default.maxLineBytes, 8 * 1024 * 1024)
        XCTAssertEqual(ParserLimits.default.maxMessages, 10_000)

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("adapter-identity-\(UUID().uuidString).jsonl")
        try "one\n".write(to: temp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: temp) }

        let before = try ParserLimits.default.fileIdentity(for: temp)
        let after = try ParserLimits.default.fileIdentity(for: temp)
        XCTAssertTrue(ParserLimits.default.isSameFileIdentity(before, after))

        try "two longer\n".write(to: temp, atomically: true, encoding: .utf8)
        let modified = try ParserLimits.default.fileIdentity(for: temp)
        XCTAssertFalse(ParserLimits.default.isSameFileIdentity(before, modified))
    }

    func testCodexStreamMessagesAppliesWindowBeforeMessageLimit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-window-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let locator = root.appendingPathComponent("rollout-window.jsonl")
        var lines = [
            """
            {"timestamp":"2026-05-20T00:00:00.000Z","type":"session_meta","payload":{"id":"window","timestamp":"2026-05-20T00:00:00.000Z","cwd":"/repo","originator":"Codex Desktop","model_provider":"openai"}}
            """
        ]
        for index in 0..<12 {
            lines.append(
                """
                {"timestamp":"2026-05-20T00:00:\(String(format: "%02d", index + 1)).000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"task-\(index)"}]}}
                """
            )
        }
        try lines.joined(separator: "\n").write(to: locator, atomically: true, encoding: .utf8)

        let adapter = CodexAdapter(sessionsRoot: root.path, limits: ParserLimits(maxMessages: 10))
        let stream = try await adapter.streamMessages(
            locator: locator.path,
            options: StreamMessagesOptions(offset: 9, limit: 2)
        )
        var messages: [NormalizedMessage] = []
        for try await message in stream {
            messages.append(message)
        }

        XCTAssertEqual(messages.map(\.content), ["task-9", "task-10"])
    }

    func testCodexStreamWindowToleratesActiveSessionAppend() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-active-window-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let locator = root.appendingPathComponent("rollout-active-window.jsonl")
        var lines = [
            """
            {"timestamp":"2026-05-20T00:00:00.000Z","type":"session_meta","payload":{"id":"active-window","timestamp":"2026-05-20T00:00:00.000Z","cwd":"/repo","originator":"Codex Desktop","model_provider":"openai"}}
            """
        ]
        for index in 0..<20_000 {
            lines.append(
                """
                {"timestamp":"2026-05-20T00:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"active-\(index)"}]}}
                """
            )
        }
        try lines.joined(separator: "\n").write(to: locator, atomically: true, encoding: .utf8)

        let appendTask = Task.detached {
            try await Task.sleep(nanoseconds: 1_000_000)
            let handle = try FileHandle(forWritingTo: locator)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("\n".utf8))
            try handle.close()
        }

        let adapter = CodexAdapter(sessionsRoot: root.path)
        let stream = try await adapter.streamMessages(
            locator: locator.path,
            options: StreamMessagesOptions(offset: 19_000, limit: 2)
        )
        var messages: [NormalizedMessage] = []
        for try await message in stream {
            messages.append(message)
        }
        try await appendTask.value

        XCTAssertEqual(messages.map(\.content), ["active-19000", "active-19001"])
    }

    func testStreamingLineReaderReportsLinesAndLineLimitFailures() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("adapter-lines-\(UUID().uuidString).jsonl")
        try "{\"ok\":true}\n\(String(repeating: "x", count: 12))\n".write(
            to: temp,
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: temp) }

        let reader = try StreamingLineReader(fileURL: temp, maxLineBytes: 11)
        XCTAssertEqual(try Array(reader.readLines()), ["{\"ok\":true}"])
        XCTAssertEqual(reader.failures, [.lineTooLarge])
    }

    // MARK: - Windowed lazy streaming (perf/jsonl-lazy-streaming)

    private func writeLines(_ lines: [String], named name: String) throws -> (root: URL, path: String) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("windowed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let locator = root.appendingPathComponent(name)
        try lines.joined(separator: "\n").write(to: locator, atomically: true, encoding: .utf8)
        return (root, locator.path)
    }

    /// offset/limit count PRODUCED messages (post-transform, nils skipped), exactly
    /// like `applyWindow` — not physical lines. A transform that drops odd lines
    /// must still window over the kept ones.
    func testWindowedMessagesCountsProducedMessagesNotPhysicalLines() throws {
        let lines = (0..<24).map { "{\"i\":\($0),\"keep\":\($0 % 2 == 0)}" }
        let (root, path) = try writeLines(lines, named: "produced.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }

        let transform: ([String: Any]) -> NormalizedMessage? = { object in
            guard (object["keep"] as? Bool) == true, let i = object["i"] as? Int else { return nil }
            return NormalizedMessage(role: .user, content: "m\(i)")
        }
        // Kept lines are i = 0,2,4,...; window [produced 3, produced 5) => i=6, i=8.
        let window = try JSONLAdapterSupport.windowedMessages(
            locator: path,
            options: StreamMessagesOptions(offset: 3, limit: 2),
            limits: .default,
            transform: transform
        )
        XCTAssertEqual(window.map(\.content), ["m6", "m8"])

        // Parity: the windowed slice equals applyWindow over a full read.
        let full = try JSONLAdapterSupport.windowedMessages(
            locator: path, options: StreamMessagesOptions(), limits: .default, transform: transform
        )
        XCTAssertEqual(full.map(\.content), (0..<24).filter { $0 % 2 == 0 }.map { "m\($0)" })
    }

    /// The windowed read must STOP at the window boundary, not scan the whole
    /// file: an oversized line past the window trips `.lineTooLarge` on a full
    /// read, but a windowed read that ends before it must succeed.
    func testWindowedMessagesStopsReadingAtWindowEnd() throws {
        var lines = (0..<6).map { "{\"i\":\($0)}" }
        lines.append("{\"i\":6,\"x\":\"\(String(repeating: "z", count: 200))\"}")
        let (root, path) = try writeLines(lines, named: "earlystop.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }

        let transform: ([String: Any]) -> NormalizedMessage? = { object in
            (object["i"] as? Int).map { NormalizedMessage(role: .user, content: "m\($0)") }
        }
        let limits = ParserLimits(maxLineBytes: 64)

        let window = try JSONLAdapterSupport.windowedMessages(
            locator: path,
            options: StreamMessagesOptions(offset: 0, limit: 3),
            limits: limits,
            transform: transform
        )
        XCTAssertEqual(window.map(\.content), ["m0", "m1", "m2"])

        XCTAssertThrowsError(
            try JSONLAdapterSupport.windowedMessages(
                locator: path, options: StreamMessagesOptions(), limits: limits, transform: transform
            )
        ) { error in
            XCTAssertEqual(error as? ParserFailure, .lineTooLarge)
        }
    }

    /// End-to-end through a real (non-Codex) adapter: a windowed page returns its
    /// slice even when a full read would trip the message cap — proving the
    /// shared early-termination path is wired into the line-based adapters.
    func testClaudeCodeStreamMessagesWindowsBeforeMessageCap() async throws {
        let lines = (0..<12).map { index -> String in
            let role = index % 2 == 0 ? "user" : "assistant"
            return "{\"type\":\"\(role)\",\"message\":{\"content\":\"m\(index)\"}}"
        }
        let (root, path) = try writeLines(lines, named: "session.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }

        let adapter = ClaudeCodeAdapter(
            projectsRoot: root.path,
            limits: ParserLimits(maxMessages: 10)
        )
        var windowed: [String] = []
        for try await message in try await adapter.streamMessages(
            locator: path, options: StreamMessagesOptions(offset: 9, limit: 2)
        ) {
            windowed.append(message.content)
        }
        XCTAssertEqual(windowed, ["m9", "m10"])

        // A full (unwindowed) read of the same file overflows the cap. Instead of
        // throwing — which would route MessageParser into its uncapped legacy
        // fallback and re-buffer the whole file — it truncates-and-succeeds,
        // returning the first `maxMessages` messages.
        var full: [String] = []
        for try await message in try await adapter.streamMessages(
            locator: path, options: StreamMessagesOptions()
        ) {
            full.append(message.content)
        }
        XCTAssertEqual(full, (0..<10).map { "m\($0)" })
    }

    func testAdapterParityHarnessComparesStage2Phase3Phase4AndPhase5Sources() async throws {
        let testFixtureRoot = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("adapter-parity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: fixtureRoot, to: testFixtureRoot)
        defer { try? FileManager.default.removeItem(at: testFixtureRoot) }
        try createOpenCodeFixtureDatabase(
            at: testFixtureRoot.appendingPathComponent("opencode/input/sample.db")
        )

        let enabledSources: Set<SourceName> = [
            .antigravity,
            .codex,
            .claudeCode,
            .cline,
            .commandcode,
            .cursor,
            .geminiCli,
            .iflow,
            .kimi,
            .opencode,
            .qoder,
            .qwen,
            .copilot,
            .vscode,
            .windsurf
        ]
        let harness = AdapterParityHarness(
            fixtureRoot: testFixtureRoot,
            registry: AdapterRegistry(adapters: [
                AntigravityAdapter(
                    cacheDir: testFixtureRoot.appendingPathComponent("antigravity/input/cache").path,
                    conversationsDir: testFixtureRoot.appendingPathComponent("antigravity/input/conversations").path
                ),
                CodexAdapter(sessionsRoot: testFixtureRoot.appendingPathComponent("codex/input").path),
                ClaudeCodeAdapter(projectsRoot: testFixtureRoot.appendingPathComponent("claude-code/input").path),
                ClineAdapter(tasksRoot: testFixtureRoot.appendingPathComponent("cline/input/tasks").path),
                CommandCodeAdapter(projectsRoot: testFixtureRoot.appendingPathComponent("commandcode/input").path),
                CursorAdapter(dbPath: testFixtureRoot.appendingPathComponent("cursor/input/state.vscdb").path),
                GeminiCliAdapter(
                    tmpRoot: testFixtureRoot.appendingPathComponent("gemini-cli/input/tmp").path,
                    projectsFile: testFixtureRoot.appendingPathComponent("gemini-cli/input/projects.json").path
                ),
                IflowAdapter(projectsRoot: testFixtureRoot.appendingPathComponent("iflow/input").path),
                KimiAdapter(
                    sessionsRoot: testFixtureRoot.appendingPathComponent("kimi/input/sessions").path,
                    kimiJsonPath: testFixtureRoot.appendingPathComponent("kimi/input/kimi.json").path
                ),
                OpenCodeAdapter(dbPath: testFixtureRoot.appendingPathComponent("opencode/input/sample.db").path),
                QoderAdapter(projectsRoot: testFixtureRoot.appendingPathComponent("qoder/input").path),
                QwenAdapter(projectsRoot: testFixtureRoot.appendingPathComponent("qwen/input").path),
                CopilotAdapter(sessionRoot: testFixtureRoot.appendingPathComponent("copilot/input").path),
                VsCodeAdapter(workspaceStorageDir: testFixtureRoot.appendingPathComponent("vscode/input").path),
                WindsurfAdapter(
                    cacheDir: testFixtureRoot.appendingPathComponent("windsurf/input/cache").path,
                    limits: .default
                )
            ]),
            enabledSources: enabledSources
        )

        let goldens = try harness.loadGoldens()
        XCTAssertEqual(goldens.count, 15)
        let enabledGoldens = goldens.filter { enabledSources.contains($0.source) }
        let results = try await harness.run()
        XCTAssertEqual(Set(results.map { $0.source }), enabledSources)

        for golden in enabledGoldens {
            let result = try XCTUnwrap(results.first { $0.source == golden.source })
            let expectedLocator = harness.resolveLocator(golden.locator)
            let listedLocators = result.listedLocators.map(standardizedPath)
            XCTAssertEqual(result.locator, expectedLocator, golden.source.rawValue)
            XCTAssertTrue(
                listedLocators.contains(standardizedPath(expectedLocator)),
                "\(golden.source.rawValue) did not list \(expectedLocator)"
            )
            XCTAssertEqual(result.failure, golden.failure, golden.source.rawValue)
            XCTAssertNil(result.failure, golden.source.rawValue)
            let expectedInfo = harness.expectedSessionInfo(for: golden)
            XCTAssertEqual(
                result.sessionInfo,
                expectedInfo,
                fieldDiff("sessionInfo", source: golden.source, expected: expectedInfo, actual: result.sessionInfo)
            )
            XCTAssertEqual(
                result.messages,
                golden.messages ?? [],
                fieldDiff("messages", source: golden.source, expected: golden.messages ?? [], actual: result.messages)
            )
            XCTAssertEqual(
                result.toolCalls,
                golden.toolCalls ?? [],
                fieldDiff("toolCalls", source: golden.source, expected: golden.toolCalls ?? [], actual: result.toolCalls)
            )
            XCTAssertEqual(
                result.usageTotals,
                golden.usageTotals ?? TokenUsage(
                    inputTokens: 0,
                    outputTokens: 0,
                    cacheReadTokens: 0,
                    cacheCreationTokens: 0
                ),
                golden.source.rawValue
            )
        }
    }

    private func fieldDiff<T: Encodable>(
        _ field: String,
        source: SourceName,
        expected: T,
        actual: T
    ) -> String {
        "\(source.rawValue) \(field) mismatch\nexpected: \(stableJSON(expected))\nactual: \(stableJSON(actual))"
    }

    private func stableJSON<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8)
        else {
            return String(describing: value)
        }
        return text
    }

    private func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func claudeFixture(sessionId: String, model: String) -> String {
        """
        {"type":"user","sessionId":"\(sessionId)","cwd":"/repo","timestamp":"2026-04-24T01:00:00.000Z","message":{"content":"hello"}}
        {"type":"assistant","sessionId":"\(sessionId)","cwd":"/repo","timestamp":"2026-04-24T01:01:00.000Z","message":{"model":"\(model)","content":[{"type":"text","text":"done"}]}}

        """
    }

    private func codexFixture(sessionId: String) -> String {
        """
        {"timestamp":"2026-04-29T00:00:00.000Z","type":"session_meta","payload":{"id":"\(sessionId)","timestamp":"2026-04-29T00:00:00.000Z","cwd":"/repo","originator":"Codex Desktop","model_provider":"openai"}}
        {"timestamp":"2026-04-29T00:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hello"}]}}

        """
    }

    private func createOpenCodeFixtureDatabase(at dbURL: URL) throws {
        try? FileManager.default.removeItem(at: dbURL)
        try FileManager.default.createDirectory(
            at: dbURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        let sql = """
        CREATE TABLE session (
          id TEXT PRIMARY KEY, project_id TEXT NOT NULL, parent_id TEXT,
          slug TEXT NOT NULL, directory TEXT NOT NULL, title TEXT NOT NULL,
          version TEXT NOT NULL, share_url TEXT, summary_additions INTEGER,
          summary_deletions INTEGER, summary_files INTEGER, summary_diffs TEXT,
          revert TEXT, permission TEXT,
          time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL,
          time_compacting INTEGER, time_archived INTEGER
        );
        CREATE TABLE message (
          id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
          time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL,
          data TEXT NOT NULL
        );
        CREATE TABLE part (
          id TEXT PRIMARY KEY, message_id TEXT NOT NULL,
          time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL,
          data TEXT NOT NULL
        );
        INSERT INTO session VALUES (
          'ses_test001', 'proj_001', NULL, 'test-session', '/Users/test/my-project',
          '实现用户登录功能', '0.0.1', NULL, 3, 10, 2, NULL, NULL, NULL,
          1770000000000, 1770000060000, NULL, NULL
        );
        INSERT INTO message VALUES (
          'msg_001', 'ses_test001', 1770000001000, 1770000001000,
          '{"role":"user","time":{"created":1770000001000}}'
        );
        INSERT INTO part VALUES (
          'part_001', 'msg_001', 1770000001000, 1770000001000,
          '{"type":"text","text":"帮我实现登录功能"}'
        );
        INSERT INTO message VALUES (
          'msg_002', 'ses_test001', 1770000010000, 1770000010000,
          '{"role":"assistant","time":{"created":1770000010000,"completed":1770000015000},"tokens":{"input":123,"output":45,"reasoning":5,"cache":{"read":67,"write":8}}}'
        );
        INSERT INTO part VALUES (
          'part_002', 'msg_002', 1770000010000, 1770000010000,
          '{"type":"text","text":"好的，我来实现登录功能。"}'
        );
        """
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown sqlite error"
            sqlite3_free(errorMessage)
            XCTFail("failed to create OpenCode fixture DB: \(message)")
        }
    }
}
