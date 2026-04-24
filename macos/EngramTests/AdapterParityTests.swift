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
            XCTAssertEqual(result.sessionInfo, harness.expectedSessionInfo(for: golden), golden.source.rawValue)
            XCTAssertEqual(result.messages, golden.messages ?? [], golden.source.rawValue)
            XCTAssertEqual(result.toolCalls, golden.toolCalls ?? [], golden.source.rawValue)
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
}
