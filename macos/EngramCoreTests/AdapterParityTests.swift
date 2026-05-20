import Foundation
import XCTest
@testable import EngramCoreRead

final class AdapterParityTests: XCTestCase {
    func testSwiftAdaptersMatchNodeParityGoldensForAllProviders() async throws {
        let fixtureRoot = repoRoot()
            .appendingPathComponent("tests/fixtures/adapter-parity")
        let registry = AdapterRegistry(adapters: [
            AntigravityAdapter(
                cacheDir: fixtureRoot.appendingPathComponent("antigravity/input/cache").path,
                enableLiveSync: false
            ),
            ClaudeCodeAdapter(projectsRoot: fixtureRoot.appendingPathComponent("claude-code/input").path),
            ClineAdapter(tasksRoot: fixtureRoot.appendingPathComponent("cline/input/tasks").path),
            CodexAdapter(sessionsRoot: fixtureRoot.appendingPathComponent("codex/input").path),
            CommandCodeAdapter(projectsRoot: fixtureRoot.appendingPathComponent("commandcode/input").path),
            CopilotAdapter(sessionRoot: fixtureRoot.appendingPathComponent("copilot/input").path),
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
            QoderAdapter(projectsRoot: fixtureRoot.appendingPathComponent("qoder/input").path),
            QwenAdapter(projectsRoot: fixtureRoot.appendingPathComponent("qwen/input").path),
            VsCodeAdapter(workspaceStorageDir: fixtureRoot.appendingPathComponent("vscode/input").path),
            WindsurfAdapter(
                cacheDir: fixtureRoot.appendingPathComponent("windsurf/input/cache").path,
                enableLiveSync: false
            )
        ])
        let enabledSources: Set<SourceName> = [
            .antigravity,
            .claudeCode,
            .cline,
            .codex,
            .commandcode,
            .copilot,
            .cursor,
            .geminiCli,
            .iflow,
            .kimi,
            .opencode,
            .qoder,
            .qwen,
            .vscode,
            .windsurf
        ]
        let harness = AdapterParityHarness(
            fixtureRoot: fixtureRoot,
            registry: registry,
            enabledSources: enabledSources
        )
        let goldens = try harness.loadGoldens()
        XCTAssertEqual(Set(goldens.map(\.source)), enabledSources)

        let results = try await harness.run()
        XCTAssertEqual(results.count, goldens.count)

        let goldensBySource = Dictionary(uniqueKeysWithValues: goldens.map { ($0.source, $0) })
        for result in results {
            guard let golden = goldensBySource[result.source] else {
                XCTFail("Unexpected adapter result for \(result.source.rawValue)")
                continue
            }
            XCTAssertTrue(
                result.listedLocators.contains(harness.resolveLocator(golden.locator)),
                "\(result.source.rawValue) did not list its fixture locator"
            )
            XCTAssertNil(result.failure, result.source.rawValue)
            XCTAssertEqual(result.sessionInfo, harness.expectedSessionInfo(for: golden), result.source.rawValue)
            XCTAssertEqual(result.messages, golden.messages ?? [], result.source.rawValue)
            XCTAssertEqual(result.toolCalls, golden.toolCalls ?? [], result.source.rawValue)
            XCTAssertEqual(
                result.usageTotals,
                golden.usageTotals ?? TokenUsage(inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0),
                result.source.rawValue
            )
        }
    }
}

private func repoRoot(filePath: String = #filePath) -> URL {
    URL(fileURLWithPath: filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
