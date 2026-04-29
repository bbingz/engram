import XCTest
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
                "unsupportedVirtualLocator"
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
        try FileManager.default.createDirectory(at: minimaxProject, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: lobsterProject, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let minimaxLocator = minimaxProject.appendingPathComponent("minimax.jsonl")
        let lobsterLocator = lobsterProject.appendingPathComponent("claude.jsonl")
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

        let minimax = ClaudeCodeDerivedSourceAdapter(source: .minimax, projectsRoot: root.path)
        let lobster = ClaudeCodeDerivedSourceAdapter(source: .lobsterai, projectsRoot: root.path)

        let minimaxLocators = try await minimax.listSessionLocators()
        let lobsterLocators = try await lobster.listSessionLocators()
        XCTAssertEqual(minimaxLocators.map(standardizedPath), [standardizedPath(minimaxLocator.path)])
        XCTAssertEqual(lobsterLocators.map(standardizedPath), [standardizedPath(lobsterLocator.path)])
        guard case .success(let minimaxInfo) = try await minimax.parseSessionInfo(locator: minimaxLocator.path) else {
            return XCTFail("minimax fixture did not parse")
        }
        guard case .success(let lobsterInfo) = try await lobster.parseSessionInfo(locator: lobsterLocator.path) else {
            return XCTFail("lobster fixture did not parse")
        }
        XCTAssertEqual(minimaxInfo.source, .minimax)
        XCTAssertEqual(lobsterInfo.source, .lobsterai)
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

    func testAdapterParityHarnessComparesStage2Phase3Phase4AndPhase5Sources() async throws {
        let enabledSources: Set<SourceName> = [
            .antigravity,
            .codex,
            .claudeCode,
            .cline,
            .cursor,
            .geminiCli,
            .iflow,
            .kimi,
            .opencode,
            .qwen,
            .copilot,
            .vscode,
            .windsurf
        ]
        let harness = AdapterParityHarness(
            fixtureRoot: fixtureRoot,
            registry: AdapterRegistry(adapters: [
                AntigravityAdapter(
                    cacheDir: fixtureRoot.appendingPathComponent("antigravity/input/cache").path,
                    conversationsDir: fixtureRoot.appendingPathComponent("antigravity/input/conversations").path,
                    enableLiveSync: false
                ),
                CodexAdapter(sessionsRoot: fixtureRoot.appendingPathComponent("codex/input").path),
                ClaudeCodeAdapter(projectsRoot: fixtureRoot.appendingPathComponent("claude-code/input").path),
                ClineAdapter(tasksRoot: fixtureRoot.appendingPathComponent("cline/input/tasks").path),
                CursorAdapter(dbPath: fixtureRoot.appendingPathComponent("cursor/input/state.vscdb").path),
                GeminiCliAdapter(
                    tmpRoot: fixtureRoot.appendingPathComponent("gemini-cli/input/tmp").path,
                    projectsFile: fixtureRoot.appendingPathComponent("gemini-cli/input/projects.json").path
                ),
                IflowAdapter(projectsRoot: fixtureRoot.appendingPathComponent("iflow/input").path),
                KimiAdapter(
                    sessionsRoot: fixtureRoot.appendingPathComponent("kimi/input/sessions").path,
                    kimiJsonPath: fixtureRoot.appendingPathComponent("kimi/input/kimi.json").path
                ),
                OpenCodeAdapter(dbPath: fixtureRoot.appendingPathComponent("opencode/input/sample.db").path),
                QwenAdapter(projectsRoot: fixtureRoot.appendingPathComponent("qwen/input").path),
                CopilotAdapter(sessionRoot: fixtureRoot.appendingPathComponent("copilot/input").path),
                VsCodeAdapter(workspaceStorageDir: fixtureRoot.appendingPathComponent("vscode/input").path),
                WindsurfAdapter(
                    cacheDir: fixtureRoot.appendingPathComponent("windsurf/input/cache").path,
                    conversationsDir: fixtureRoot.appendingPathComponent("windsurf/input/cascade").path,
                    enableLiveSync: false
                )
            ]),
            enabledSources: enabledSources
        )

        let goldens = try harness.loadGoldens()
        XCTAssertEqual(goldens.count, 13)
        let enabledGoldens = goldens.filter { enabledSources.contains($0.source) }
        let results = try await harness.run()
        XCTAssertEqual(Set(results.map { $0.source }), enabledSources)

        for golden in enabledGoldens {
            let result = try XCTUnwrap(results.first { $0.source == golden.source })
            let expectedLocator = harness.resolveLocator(golden.locator)
            XCTAssertEqual(result.locator, expectedLocator, golden.source.rawValue)
            XCTAssertTrue(
                result.listedLocators.contains(expectedLocator),
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
}
