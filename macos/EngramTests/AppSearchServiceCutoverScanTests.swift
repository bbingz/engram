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

    func testPopoverStatusLabelsServiceInsteadOfMcpWhenUsingServiceStatus() throws {
        let popover = try source("macos/Engram/Views/PopoverView.swift")
        XCTAssertFalse(
            popover.contains("label: \"MCP\""),
            "Popover must not label serviceStatusStore.isRunning as MCP helper health"
        )
        XCTAssertTrue(
            popover.contains("label: \"Service\""),
            "Popover should label serviceStatusStore.isRunning as Service unless a real MCP helper health check exists"
        )
        XCTAssertFalse(
            popover.contains("popover_status_mcp"),
            "Popover accessibility id should not imply an MCP helper health check"
        )
    }

    func testMainMenuNavigationTitlesUseStringCatalog() throws {
        let menu = try source("macos/Engram/MenuBarController.swift")
        XCTAssertFalse(
            menu.contains("NSMenuItem(title: title, action: #selector(navigateToScreenAction(_:))"),
            "View menu navigation items must localize Screen titles before creating NSMenuItem titles"
        )
        XCTAssertTrue(
            menu.contains("NSMenuItem(title: screen.localizedTitle, action: #selector(navigateToScreenAction(_:))"),
            "View menu navigation items should use Screen.localizedTitle for String-backed NSMenuItem titles"
        )
        let screen = try source("macos/Engram/Models/Screen.swift")
        XCTAssertTrue(
            screen.contains("var localizedTitle: String"),
            "Screen should expose a String-backed localized title for AppKit menu surfaces"
        )
    }

    func testAISettingsOperationStatusesUseLocalizedStateModels() throws {
        let aiSettings = try source("macos/Engram/Views/Settings/AISettingsSection.swift")
        XCTAssertFalse(
            aiSettings.contains("@State private var titleTestStatus: String"),
            "Title connection status should be an enum-backed localized state, not a raw display String"
        )
        XCTAssertFalse(
            aiSettings.contains("@State private var titleRegenerateStatus: String"),
            "Title regeneration status should be an enum-backed localized state, not a raw display String"
        )
        XCTAssertFalse(
            aiSettings.contains("Text(titleTestStatus)"),
            "Dynamic operation status text should render localized state labels instead of raw String state"
        )
        XCTAssertFalse(
            aiSettings.contains("Text(titleRegenerateStatus)"),
            "Dynamic operation status text should render localized state labels instead of raw String state"
        )
        XCTAssertTrue(
            aiSettings.contains("enum TitleConnectionStatus"),
            "AI settings should define a localized state model for connection status"
        )
        XCTAssertTrue(
            aiSettings.contains("enum TitleRegenerationStatus"),
            "AI settings should define a localized state model for title regeneration status"
        )
    }

    func testUnsupportedSyncIsNotPresentedAsWorkingSettingsAction() throws {
        let networkSettings = try source("macos/Engram/Views/Settings/NetworkSettingsSection.swift")
        XCTAssertTrue(
            networkSettings.contains("Sync is not implemented in the Swift service"),
            "Network settings should state that peer sync is currently unsupported"
        )
        XCTAssertFalse(
            networkSettings.contains("triggerSync()"),
            "Settings must not expose a Sync Now action while the Swift service returns an unsupported stub"
        )
        XCTAssertFalse(
            networkSettings.contains("syncStatus = \"Synced!\""),
            "Settings must not present a success state for unsupported sync"
        )
    }

    func testReadmeDoesNotAdvertiseUnsupportedAppSurfacesOrFixedTestCounts() throws {
        let readme = try source("README.md")
        XCTAssertFalse(
            readme.contains("多机同步"),
            "README should not advertise peer sync while the Swift service returns an unsupported stub"
        )
        XCTAssertFalse(
            readme.contains("Settings 页面 → Project Aliases"),
            "README should not point users to a Project Aliases settings UI that does not exist"
        )
        XCTAssertFalse(
            readme.contains("922 tests"),
            "README should avoid fixed test counts that drift with the suite"
        )
    }

    func testSwiftMcpDocsDoNotDescribeRetiredNodeDaemonRuntimeAsProductPath() throws {
        let mcpSwift = try source("docs/mcp-swift.md")
        XCTAssertFalse(
            mcpSwift.contains("Node (default)"),
            "Swift MCP docs should not describe Node as the default product runtime"
        )
        XCTAssertFalse(
            mcpSwift.contains("daemon's HTTP API"),
            "Swift MCP docs should not describe writes as going through retired daemon HTTP"
        )
        XCTAssertFalse(
            mcpSwift.contains("default 9100"),
            "Swift MCP docs should not require the retired daemon HTTP port"
        )
        XCTAssertTrue(
            mcpSwift.contains("Unix socket"),
            "Swift MCP docs should describe the current EngramService Unix socket runtime"
        )
    }

    func testDaemonClientMapMarksSyncUnsupportedInSwiftService() throws {
        let daemonMap = try source("docs/swift-single-stack/daemon-client-map.md")
        XCTAssertTrue(
            daemonMap.contains("Sync remains an unsupported Swift service stub"),
            "Daemon map should not present sync as a completed service-backed app feature"
        )
        XCTAssertFalse(
            daemonMap.contains("Sync trigger is native service fail-soft status reporting"),
            "Daemon map should remove the old wording that made unsupported sync sound product-ready"
        )
    }

    func testAppLaunchDoesNotMarkWebEndpointReadyBeforeServiceEvent() throws {
        let app = try source("macos/Engram/App.swift")
        XCTAssertFalse(
            app.contains("serviceStatusStore.endpointHost = \"127.0.0.1\""),
            "App launch must not mark the Web endpoint ready before the service emits a verified web_ready event"
        )
        XCTAssertFalse(
            app.contains("serviceStatusStore.endpointPort = 3457"),
            "App launch must not enable Web UI before service readiness is verified"
        )
    }

    func testServiceRunnerDoesNotEmitWebReadyBeforeServerRun() throws {
        let runner = try source("macos/EngramService/Core/EngramServiceRunner.swift")
        let runRange = try XCTUnwrap(runner.range(of: "try await webServer.run()"))
        let readyRange = try XCTUnwrap(runner.range(of: #"{"event":"web_ready""#))

        XCTAssertLessThan(
            runRange.lowerBound,
            readyRange.lowerBound,
            "Service must not emit web_ready before starting the Web server run loop"
        )
    }

    func testResumeActionLivesInSessionToolbarNotGlobalWindowToolbar() throws {
        let mainWindow = try source("macos/Engram/Views/MainWindowView.swift")
        XCTAssertFalse(
            mainWindow.contains("Label(\"Resume\", systemImage: \"play.fill\")"),
            "Resume must not be rendered from the global main window toolbar"
        )
        XCTAssertFalse(
            mainWindow.contains("resumeSelectedSession()"),
            "MainWindowView should not own the session resume action"
        )
        let topBar = try source("macos/Engram/Views/TopBarView.swift")
        XCTAssertFalse(
            topBar.contains("Resume"),
            "TopBarView should not render a global Resume control"
        )

        let transcriptToolbar = try source("macos/Engram/Views/Transcript/TranscriptToolbar.swift")
        XCTAssertTrue(
            transcriptToolbar.contains("var onResume: (() -> Void)? = nil"),
            "TranscriptToolbar should expose a session-scoped resume action"
        )
        XCTAssertTrue(
            transcriptToolbar.contains("if let onResume"),
            "TranscriptToolbar should render Resume only when SessionDetailView provides the action"
        )

        let sessionDetail = try source("macos/Engram/Views/SessionDetailView.swift")
        XCTAssertTrue(
            sessionDetail.contains("@State private var showResume = false"),
            "SessionDetailView should own the Resume sheet state"
        )
        XCTAssertTrue(
            sessionDetail.contains("onResume: { showResume = true }"),
            "SessionDetailView should wire Resume into the transcript toolbar"
        )
        XCTAssertTrue(
            sessionDetail.contains("ResumeDialog(session: session)"),
            "SessionDetailView should present ResumeDialog for the current session"
        )
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

    func testEngramAppHostedTestsPinSameDevelopmentTeamAsHostApp() throws {
        let project = try source("macos/project.yml")
        guard
            let appRange = project.range(of: "\n  Engram:\n"),
            let cliRange = project.range(of: "\n  EngramCLI:\n"),
            let testsRange = project.range(of: "\n  EngramTests:\n"),
            let mcpTestsRange = project.range(of: "\n  EngramMCPTests:\n")
        else {
            return XCTFail("project.yml target ranges not found")
        }

        let appBlock = String(project[appRange.lowerBound..<cliRange.lowerBound])
        let testsBlock = String(project[testsRange.lowerBound..<mcpTestsRange.lowerBound])

        XCTAssertTrue(appBlock.contains("DEVELOPMENT_TEAM: J25GS8J4XM"))
        XCTAssertTrue(
            testsBlock.contains("DEVELOPMENT_TEAM: J25GS8J4XM"),
            "EngramTests must pin the same team as the hosted app so xcodebuild test does not require a command-line override"
        )
    }

    func testMcpToolDescriptionsDoNotPromiseUnavailableCapabilities() throws {
        let registry = try source("macos/EngramMCP/Core/MCPToolRegistry.swift")
        XCTAssertFalse(
            registry.contains("List currently active coding sessions detected by file activity."),
            "live_sessions is unavailable in MCP mode and must say so in its description"
        )
        XCTAssertTrue(
            registry.contains("Live session monitoring is not available in MCP mode"),
            "live_sessions should document the MCP-mode limitation"
        )
        XCTAssertFalse(
            registry.contains("Swift MCP does not compute optimization suggestions yet"),
            "get_insights must not deny computed spend-distribution suggestions"
        )
        XCTAssertTrue(
            registry.contains("Report cost totals, projection, and high-confidence spend-distribution suggestions"),
            "get_insights should describe the current spend-summary and conservative suggestion behavior"
        )
    }

    func testMcpInsightsOutputDescribesComputedSuggestionsConservatively() throws {
        let insights = try source("macos/EngramMCP/Core/MCPInsightsTool.swift")
        XCTAssertFalse(
            insights.contains("No cost optimization suggestions for this period. Spending looks healthy!"),
            "A hardcoded no-suggestions message hides that suggestions are not computed"
        )
        XCTAssertTrue(
            insights.contains("No high-confidence optimization suggestions from current spend distribution."),
            "Output should describe the conservative fallback when no threshold-based suggestion is available"
        )
        XCTAssertTrue(
            insights.contains("Model concentration:"),
            "Output should include computed spend-distribution suggestions when thresholds are met"
        )
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
