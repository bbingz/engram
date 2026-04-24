import XCTest

final class AppSearchServiceCutoverScanTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testStage3DaemonCutoverScanClassifiesRemainingProductionHits() throws {
        let scriptURL = repoRoot.appendingPathComponent("scripts/check-stage3-daemon-cutover.sh")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, output)
        XCTAssertTrue(output.contains("Stage 3 daemon cutover scan ok"), output)
        XCTAssertTrue(output.contains("Allowed legacy compatibility hits"), output)
        XCTAssertTrue(output.contains("Allowed Stage 4 project-op hits"), output)
        XCTAssertFalse(output.contains("Ollama"), "External provider localhost/API references must not be daemon-cutover hits:\n\(output)")
        XCTAssertFalse(output.contains("Cascade"), "External provider localhost/API references must not be daemon-cutover hits:\n\(output)")
    }

    func testStage3DirectWriteScanClassifiesRemainingProductionHits() throws {
        let scriptURL = repoRoot.appendingPathComponent("scripts/check-app-mcp-cli-direct-writes.sh")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, output)
        XCTAssertTrue(output.contains("direct write scan ok"), output)
        XCTAssertTrue(output.contains("Allowed legacy app DB writer hits"), output)
        XCTAssertTrue(output.contains("Allowed Stage 4 MCP DB/project-op hits"), output)
        XCTAssertFalse(output.contains("AgentFilterBar"), "Set.insert UI state should not be classified as a direct DB write:\n\(output)")
        XCTAssertFalse(output.contains("SharedPickers"), "Set.insert UI state should not be classified as a direct DB write:\n\(output)")
    }

    func testAppSearchSurfacesDoNotCallDaemonSearchHttpDirectly() throws {
        let files = [
            "macos/Engram/Views/SearchView.swift",
            "macos/Engram/Views/Pages/SearchPageView.swift",
            "macos/Engram/Views/GlobalSearchOverlay.swift",
            "macos/Engram/Views/CommandPaletteView.swift"
        ]

        for relativePath in files {
            let url = repoRoot.appendingPathComponent(relativePath)
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(text.contains("/api/search"), "\(relativePath) must use EngramServiceClient.search")
            XCTAssertFalse(text.contains("127.0.0.1"), "\(relativePath) must not construct daemon localhost URLs")
            XCTAssertFalse(text.contains("IndexerProcess"), "\(relativePath) must not depend on daemon/indexer search ports")
        }
    }

    func testReadOnlyAppPagesDoNotCallDaemonHttpDirectly() throws {
        let expectations: [(path: String, forbidden: [String])] = [
            (
                "macos/Engram/Views/Pages/SourcePulseView.swift",
                ["DaemonClient", "/api/live", "/api/sources"]
            ),
            (
                "macos/Engram/Views/Pages/MemoryView.swift",
                ["DaemonClient", "/api/memory"]
            ),
            (
                "macos/Engram/Views/Pages/SkillsView.swift",
                ["DaemonClient", "/api/skills"]
            ),
            (
                "macos/Engram/Views/Pages/HooksView.swift",
                ["DaemonClient", "/api/hooks"]
            ),
            (
                "macos/Engram/Views/Replay/SessionReplayView.swift",
                ["DaemonClient", "/api/sessions/", "/timeline?limit="]
            )
        ]

        for expectation in expectations {
            let url = repoRoot.appendingPathComponent(expectation.path)
            let text = try String(contentsOf: url, encoding: .utf8)
            for forbidden in expectation.forbidden {
                XCTAssertFalse(text.contains(forbidden), "\(expectation.path) must use EngramServiceClient, found \(forbidden)")
            }
        }
    }

    func testSettingsPrimaryMcpSetupDoesNotRecommendNodeRuntime() throws {
        let files = [
            "macos/Engram/Views/Settings/SourcesSettingsSection.swift"
        ]

        let forbiddenPrimarySetupText = [
            "node dist/index.js",
            "~/.engram/dist/index.js"
        ]

        for relativePath in files {
            let url = repoRoot.appendingPathComponent(relativePath)
            let text = try String(contentsOf: url, encoding: .utf8)
            for forbidden in forbiddenPrimarySetupText {
                XCTAssertFalse(
                    text.contains(forbidden),
                    "\(relativePath) must present Swift stdio MCP as primary setup, found \(forbidden)"
                )
            }
        }
    }

    func testStage3ServiceBackedViewsDoNotCallDaemonHttpDirectly() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let expectations: [(path: String, forbidden: [String])] = [
            (
                "macos/Engram/Views/SessionDetailView.swift",
                ["DaemonClient", "IndexerProcess", "/api/handoff", "/api/summary", "127.0.0.1"]
            ),
            (
                "macos/Engram/Views/Pages/HygieneView.swift",
                ["DaemonClient", "/api/hygiene"]
            ),
            (
                "macos/Engram/Views/Pages/HomeView.swift",
                ["DaemonClient"]
            ),
            (
                "macos/Engram/Views/Pages/SessionsPageView.swift",
                ["DaemonClient"]
            ),
            (
                "macos/Engram/Views/Pages/TimelinePageView.swift",
                ["DaemonClient"]
            )
        ]

        for expectation in expectations {
            let url = repoRoot.appendingPathComponent(expectation.path)
            let text = try String(contentsOf: url, encoding: .utf8)
            for forbidden in expectation.forbidden {
                XCTAssertFalse(text.contains(forbidden), "\(expectation.path) must use EngramServiceClient, found \(forbidden)")
            }
        }
    }
}
