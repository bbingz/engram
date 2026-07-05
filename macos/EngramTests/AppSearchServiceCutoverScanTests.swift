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

    func testObsoleteTabRootViewsAreRemoved() throws {
        for relativePath in [
            "macos/Engram/Views/ContentView.swift",
            "macos/Engram/Views/FavoritesView.swift",
            "macos/Engram/Views/GlobalSearchOverlay.swift",
            "macos/Engram/Views/SearchView.swift",
            "macos/Engram/Views/TimelineView.swift",
        ] {
            let url = repoRoot.appendingPathComponent(relativePath)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: url.path),
                "\(relativePath) is an obsolete pre-MainWindowView root/search surface and should not stay compiled"
            )
        }

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: repoRoot.appendingPathComponent("macos/Engram/Views/Pages/SearchPageView.swift").path
            ),
            "SearchPageView remains the canonical search surface"
        )
    }

    func testAppSearchSurfacesDoNotCallDaemonSearchHttpDirectly() throws {
        let files = [
            "macos/Engram/Views/Pages/SearchPageView.swift",
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

    func testAppSearchSurfacesRequestKeywordModeOnly() throws {
        let files = [
            "macos/Engram/Views/Pages/SearchPageView.swift",
            "macos/Engram/Views/CommandPaletteView.swift",
        ]

        for relativePath in files {
            let text = try source(relativePath)
            XCTAssertFalse(
                text.contains("mode: \"hybrid\""),
                "\(relativePath) must not request hybrid search while the Swift service search path is keyword-only"
            )
            XCTAssertFalse(
                text.contains("mode: \"semantic\""),
                "\(relativePath) must not request semantic search while the Swift service search path is keyword-only"
            )
        }
    }

    func testSearchPageDoesNotAdvertiseUnavailableSemanticModes() throws {
        let searchPage = try source("macos/Engram/Views/Pages/SearchPageView.swift")

        XCTAssertFalse(
            searchPage.contains("ForEach(SearchMode.allCases"),
            "SearchPageView must not offer semantic/hybrid modes unless embeddings are available"
        )
        XCTAssertFalse(
            searchPage.contains("Hybrid search combines keyword"),
            "SearchPageView empty state must not claim semantic search works before sqlite-vec is wired"
        )
    }

    func testMainWindowExposesCommandPaletteEntryPoints() throws {
        let mainWindow = try source("macos/Engram/Views/MainWindowView.swift")

        XCTAssertTrue(
            mainWindow.contains("private func openPalette()"),
            "MainWindowView should own a concrete opener for the Command Palette instead of leaving showPalette write-only"
        )
        XCTAssertTrue(
            mainWindow.contains("Button(action: openPalette)"),
            "MainWindowView should expose a visible toolbar button for the Command Palette"
        )
        XCTAssertTrue(
            mainWindow.contains("Label(\"Command Palette\", systemImage: \"command\")"),
            "The Command Palette toolbar entry should use an icon label with an accessible name"
        )
        XCTAssertTrue(
            mainWindow.contains(".keyboardShortcut(\"k\", modifiers: .command)"),
            "The Command Palette should open with Command-K"
        )
        XCTAssertTrue(
            mainWindow.contains(".accessibilityIdentifier(\"command_palette_button\")"),
            "The Command Palette opener needs a stable UI-test identifier"
        )
    }

    func testSessionSelectionRecordsAccessThroughService() throws {
        let serviceProtocol = try source("macos/Shared/Service/EngramServiceProtocol.swift")
        let serviceClient = try source("macos/Shared/Service/EngramServiceClient.swift")
        let serviceModels = try source("macos/Shared/Service/EngramServiceModels.swift")
        let serviceHandler = try source("macos/EngramService/Core/EngramServiceCommandHandler.swift")

        XCTAssertTrue(
            serviceProtocol.contains("func recordSessionAccess(sessionId: String) async throws"),
            "Session access bumps should go through the service client protocol"
        )
        XCTAssertTrue(
            serviceClient.contains("func recordSessionAccess(sessionId: String) async throws"),
            "EngramServiceClient should expose a typed session access command"
        )
        XCTAssertTrue(
            serviceModels.contains("struct EngramServiceSessionAccessRequest"),
            "The access command should have an explicit payload model"
        )
        XCTAssertTrue(
            serviceHandler.contains("case \"recordSessionAccess\""),
            "The service handler must route access bumps through the single writer gate"
        )
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

    func testSourcePulseMakesLocalArchiveStatusVisible() throws {
        let sourcePulse = try source("macos/Engram/Views/Pages/SourcePulseView.swift")

        XCTAssertTrue(
            sourcePulse.contains("Archived Sessions"),
            "Source Pulse should frame persisted session rows as a local archive, not only an index counter"
        )
        XCTAssertTrue(
            sourcePulse.contains("sourcePulse_archiveStore"),
            "Source Pulse should expose an accessible local archive store status row"
        )
        XCTAssertTrue(
            sourcePulse.contains("db.path"),
            "Source Pulse should render the actual DatabaseManager path instead of hardcoding ~/.engram/index.sqlite"
        )
    }

    func testSourcePulseCanRevealLocalArchiveStoreInFinder() throws {
        let sourcePulse = try source("macos/Engram/Views/Pages/SourcePulseView.swift")

        XCTAssertTrue(
            sourcePulse.contains("sourcePulse_revealArchiveStore"),
            "Archive store status should expose an accessible Finder reveal action"
        )
        XCTAssertTrue(
            sourcePulse.contains("revealArchiveStore()"),
            "Archive store reveal button should call a dedicated action instead of duplicating NSWorkspace code inline"
        )
        XCTAssertTrue(
            sourcePulse.contains("NSWorkspace.shared.selectFile(db.path"),
            "Archive store reveal should select the actual DatabaseManager path in Finder"
        )
        XCTAssertTrue(
            sourcePulse.contains(".help(\"Reveal archive store in Finder\")"),
            "Icon-only archive reveal button needs a visible hover description"
        )
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

    func testSessionFilterLivesUnderAdvancedSettings() throws {
        let generalSettings = try source("macos/Engram/Views/Settings/GeneralSettingsSection.swift")
        let settingsView = try source("macos/Engram/Views/SettingsView.swift")

        XCTAssertFalse(
            generalSettings.contains("GroupBox(\"Session Filter\")"),
            "General settings should stay quiet; the low-level session noise filter belongs in Advanced"
        )
        XCTAssertTrue(
            settingsView.contains("GroupBox(\"Session Filter\")"),
            "Advanced settings should expose the simplified session noise filter"
        )
        XCTAssertTrue(
            settingsView.contains("GroupBox(\"Noise Details\")"),
            "Advanced settings should keep the low-level noise detail toggles near the simplified filter"
        )
        XCTAssertTrue(
            settingsView.contains("settings[\"noiseFilter\"] = noiseFilter"),
            "Moving the control must preserve the existing noiseFilter settings contract"
        )
    }

    func testTranscriptDiagnosticTogglesLiveUnderAdvancedSettings() throws {
        let generalSettings = try source("macos/Engram/Views/Settings/GeneralSettingsSection.swift")
        let settingsView = try source("macos/Engram/Views/SettingsView.swift")

        XCTAssertFalse(
            generalSettings.contains("Show System Prompts"),
            "General settings should not expose raw transcript diagnostic toggles"
        )
        XCTAssertFalse(
            generalSettings.contains("Show Agent Communication"),
            "General settings should not expose raw transcript diagnostic toggles"
        )
        XCTAssertTrue(
            settingsView.contains("GroupBox(\"Transcript Diagnostics\")"),
            "Advanced settings should group raw transcript diagnostic visibility"
        )
        XCTAssertTrue(
            settingsView.contains("@AppStorage(\"showSystemPrompts\")"),
            "Moving diagnostics must preserve the existing showSystemPrompts setting"
        )
        XCTAssertTrue(
            settingsView.contains("@AppStorage(\"showAgentComm\")"),
            "Moving diagnostics must preserve the existing showAgentComm setting"
        )
    }

    func testUsageTokenLimitsLiveUnderAdvancedSettings() throws {
        let settingsView = try source("macos/Engram/Views/SettingsView.swift")

        XCTAssertTrue(
            settingsView.contains("GroupBox(\"Usage Limits\")"),
            "Advanced settings should expose token pressure limits that feed the service usage collector"
        )
        XCTAssertTrue(
            settingsView.contains("usageTokenLimits"),
            "Usage limit settings must write the same key that EngramServiceRunner reads"
        )
        for sourceLabel in [
            "Codex",
            "Claude Code",
            "OpenCode",
            "Copilot",
            "Gemini CLI",
            "Iflow",
            "Qwen",
            "Qoder",
            "Kimi",
            "Cline",
        ] {
            XCTAssertTrue(
                settingsView.contains(sourceLabel),
                "Usage Limits should expose high-demand source rows, missing \(sourceLabel)"
            )
        }
        XCTAssertFalse(
            settingsView.contains("codexFiveHourTokens"),
            "Usage Limits should not be a two-source hard-coded state model"
        )
    }

    func testUsageTokenLimitsSavePreservesUnknownSources() throws {
        let settingsView = try source("macos/Engram/Views/SettingsView.swift")

        XCTAssertTrue(
            settingsView.contains("UsageTokenLimitEditableRow.settingsObject(")
                && settingsView.contains("preservingUnknownFrom: settings[\"usageTokenLimits\"] as? [String: Any]"),
            "Saving visible Usage Limits should preserve valid custom source limits already present in settings.json"
        )
        XCTAssertTrue(
            settingsView.contains("excludingSourceIDs: removedUsageLimitSourceIDs"),
            "Saving Usage Limits should also be able to exclude custom sources the user explicitly removed"
        )
    }

    func testServiceUsageTokenLimitsReloadBeforeEachCollection() throws {
        let runner = try source("macos/EngramService/Core/EngramServiceRunner.swift")

        XCTAssertFalse(
            runner.contains("let usageTokenLimits = Self.readUsageTokenLimits(environment: environment)"),
            "The service must not freeze usage token limits at startup; Settings changes should affect the next usage collection"
        )
        XCTAssertTrue(
            runner.contains("tokenLimitsProvider: { Self.readUsageTokenLimits(environment: environment) }"),
            "Initial and periodic scans should receive a provider that re-reads settings.json for each usage collection"
        )
        XCTAssertTrue(
            runner.contains("try await collectUsage(gate: gate, tokenLimits: tokenLimitsProvider())"),
            "Best-effort usage collection should resolve token limits immediately before collecting"
        )
        XCTAssertFalse(
            runner.contains("collectUsageBestEffort(gate: gate, tokenLimits: tokenLimits)"),
            "Usage collection loops should not pass a stale startup tokenLimits snapshot"
        )
    }

    func testUsageCollectorAggregatesAllSourcesWithUsageData() throws {
        let collector = try source("macos/EngramCoreWrite/Indexing/StartupUsageCollector.swift")

        XCTAssertFalse(
            collector.contains("trackedSources"),
            "Usage collector should not require each supported source to be manually added to a tracking allowlist"
        )
        XCTAssertFalse(
            collector.contains("AND s.source IN"),
            "Usage collector should aggregate all sources with usage data instead of filtering to configured/default sources"
        )
        XCTAssertTrue(
            collector.contains("AND TRIM(s.source) <> ''"),
            "Usage collector should still reject empty source keys while aggregating all real sources"
        )
        XCTAssertTrue(
            collector.contains("COALESCE(NULLIF(s.end_time, ''), NULLIF(s.indexed_at, ''), s.start_time) >= ?"),
            "Usage pressure should include long-running sessions that overlap the window instead of filtering only by start_time"
        )
        XCTAssertTrue(
            collector.contains("MIN(CASE WHEN s.start_time < ? THEN ? ELSE s.start_time END) AS earliest_start_time"),
            "Reset labels should be based on the window-clamped start for overlapping long-running sessions"
        )
        XCTAssertFalse(
            collector.contains("WHERE s.start_time >= ?"),
            "Start-time-only attribution drops all-day sessions from 5h pressure after their start time ages out"
        )
    }

    func testPopoverDropsLegacyServiceStatusLabelsInsteadOfMcpHealth() throws {
        let popover = try source("macos/Engram/Views/PopoverView.swift")
        XCTAssertFalse(
            popover.contains("label: \"MCP\""),
            "Popover must not label serviceStatusStore.isRunning as MCP helper health"
        )
        XCTAssertFalse(
            popover.contains("label: \"Service\""),
            "Simplified popover no longer renders the legacy Service status chip"
        )
        XCTAssertFalse(
            popover.contains("popover_status_mcp"),
            "Popover accessibility id should not imply an MCP helper health check"
        )
        XCTAssertFalse(
            popover.contains("popover_status_service"),
            "Simplified popover no longer renders the legacy Service status chip"
        )
    }

    func testPopoverDataLoadLogsReadFailures() throws {
        let popover = try source("macos/Engram/Views/PopoverView.swift")
        XCTAssertTrue(
            popover.contains("EngramLogger.error(\"PopoverView"),
            "Popover data reads should log failures instead of silently rendering zero/empty fallback state"
        )
        XCTAssertFalse(
            popover.contains("(try? db."),
            "Popover DB reads should use explicit do/catch logging, not try? defaults"
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

    func testAppLaunchDoesNotSeedDeletedHttpWebEndpoint() throws {
        let app = try source("macos/Engram/App.swift")
        XCTAssertFalse(
            app.contains("serviceStatusStore.endpointHost = \"127.0.0.1\""),
            "App launch must not seed the deleted HTTP Web UI endpoint host"
        )
        XCTAssertFalse(
            app.contains("serviceStatusStore.endpointPort = 3457"),
            "App launch must not seed the deleted HTTP Web UI endpoint port"
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

    func testExpandableSessionCardsExposeResumeCopyHandoffAndReplayActions() throws {
        let card = try source("macos/Engram/Components/ExpandableSessionCard.swift")
        XCTAssertTrue(
            card.contains("var onResume: ((Session) -> Void)?"),
            "ExpandableSessionCard should expose a session-scoped resume callback"
        )
        XCTAssertTrue(
            card.contains("var onCopyResumeCommand: ((Session) -> Void)?"),
            "ExpandableSessionCard should expose a session-scoped copy-resume callback"
        )
        XCTAssertTrue(
            card.contains("var onHandoff: ((Session) -> Void)?"),
            "ExpandableSessionCard should expose a session-scoped handoff callback"
        )
        XCTAssertTrue(
            card.contains("var onReplay: ((Session) -> Void)?"),
            "ExpandableSessionCard should expose a session-scoped replay callback"
        )
        XCTAssertTrue(
            card.contains("Button(\"Resume...\")"),
            "Grouped parent and child rows should let users resume without switching to the flat table"
        )
        XCTAssertTrue(
            card.contains("Button(\"Copy Resume Command\")"),
            "Grouped parent and child rows should let users copy the rendered resume command"
        )
        XCTAssertTrue(
            card.contains("Button(\"Handoff\")"),
            "Grouped parent and child rows should let users copy a handoff brief without switching views"
        )
        XCTAssertTrue(
            card.contains("Button(\"Replay\")"),
            "Grouped parent and child rows should let users open replay without switching views"
        )
        XCTAssertTrue(
            card.contains("onResume: { onResume?(child) }"),
            "Confirmed/suggested child rows should forward resume for the child session"
        )
        XCTAssertTrue(
            card.contains("onCopyResumeCommand: { onCopyResumeCommand?(child) }"),
            "Confirmed/suggested child rows should forward copy-resume for the child session"
        )
        XCTAssertTrue(
            card.contains("onHandoff: { onHandoff?(child) }"),
            "Confirmed/suggested child rows should forward handoff for the child session"
        )
        XCTAssertTrue(
            card.contains("onReplay: { onReplay?(child) }"),
            "Confirmed/suggested child rows should forward replay for the child session"
        )
    }

    func testResumeDialogUsesInstalledTerminalChoices() throws {
        let resumeDialog = try source("macos/Engram/Views/Resume/ResumeDialog.swift")
        let terminalLauncher = try source("macos/Engram/Views/Resume/TerminalLauncher.swift")
        XCTAssertTrue(
            resumeDialog.contains("private let availableTerminals: [TerminalType]"),
            "ResumeDialog should own an installed-terminal choice list"
        )
        XCTAssertTrue(
            resumeDialog.contains("TerminalLauncher.availableTerminalTypes()"),
            "ResumeDialog should ask TerminalLauncher for installed terminal choices"
        )
        XCTAssertTrue(
            resumeDialog.contains("ForEach(availableTerminals)"),
            "ResumeDialog picker should show installed terminal choices, not every hard-coded terminal"
        )
        XCTAssertFalse(
            resumeDialog.contains("ForEach(TerminalType.allCases)"),
            "ResumeDialog should not show terminal apps that are not installed"
        )
        XCTAssertTrue(
            terminalLauncher.contains(#"case warp = "Warp""#),
            "Warp should be a first-class resume terminal target"
        )
        XCTAssertTrue(
            terminalLauncher.contains("warp://tab_config/"),
            "Warp resume should use Warp's terminal tab config URL path"
        )
    }

    func testResumeDialogSurfacesContextPrimerFromService() throws {
        let resumeDialog = try source("macos/Engram/Views/Resume/ResumeDialog.swift")

        XCTAssertTrue(
            resumeDialog.contains("let contextPrimer: String?"),
            "ResumeDialog should preserve the service-provided context primer"
        )
        XCTAssertTrue(
            resumeDialog.contains("contextPrimer: response.contextPrimer"),
            "ResumeDialog should pass the resume response context primer into UI state"
        )
        XCTAssertTrue(
            resumeDialog.contains("Label(\"Context Primer\""),
            "ResumeDialog should make available context primer visible before launch"
        )
        XCTAssertTrue(
            resumeDialog.contains("copyContextPrimer("),
            "ResumeDialog should provide a direct context-primer copy action"
        )
        XCTAssertTrue(
            resumeDialog.contains("NSPasteboard.general.setString(primer, forType: .string)"),
            "ResumeDialog should copy the raw primer text, not a lossy display string"
        )
    }

    func testResumeDialogKeepsContextPrimerAvailableWhenResumeCommandErrors() throws {
        let resumeDialog = try source("macos/Engram/Views/Resume/ResumeDialog.swift")

        XCTAssertTrue(
            resumeDialog.contains("@State private var fallbackContextPrimer: String?"),
            "ResumeDialog should keep service-provided context even when no launchable CLI command is available"
        )
        XCTAssertTrue(
            resumeDialog.contains("fallbackContextPrimer = response.contextPrimer"),
            "ResumeDialog should preserve the primer before rendering the resume-command error"
        )
        XCTAssertTrue(
            resumeDialog.contains("private var availableContextPrimer: String?"),
            "ResumeDialog should render primer availability independently from the successful resume command model"
        )
        XCTAssertTrue(
            resumeDialog.contains("if let primer = availableContextPrimer"),
            "ResumeDialog should show/copy an available primer in both success and error states"
        )
    }

    func testSettingsUsageRefreshAppliesReturnedPressureToStatusStore() throws {
        let settingsView = try source("macos/Engram/Views/SettingsView.swift")

        XCTAssertTrue(
            settingsView.contains("@Environment(EngramServiceStatusStore.self)"),
            "SettingsView should have access to the shared status store"
        )
        XCTAssertTrue(
            settingsView.contains("let response = try await serviceClient.refreshUsage()"),
            "SettingsView should keep the refreshUsage response instead of discarding it"
        )
        XCTAssertTrue(
            settingsView.contains("serviceStatusStore.apply(response)"),
            "SettingsView should immediately publish returned usage pressure to menu bar/popover state"
        )
    }

    func testMenuBarUsagePressureObserverTriggersNotifier() throws {
        let menuBar = try source("macos/Engram/MenuBarController.swift")

        XCTAssertTrue(
            menuBar.contains("private let usagePressureNotifier = UsagePressureNotifier()"),
            "MenuBarController should own the usage-pressure notification dedupe state"
        )
        XCTAssertTrue(
            menuBar.contains("usagePressureNotifier.observe(summary: serviceStatusStore.usagePressureSummary)"),
            "Usage pressure observation should notify on new attention/critical pressure, not only change the icon"
        )
    }

    func testSettingsExposeUsagePressureNotificationToggle() throws {
        let settingsView = try source("macos/Engram/Views/SettingsView.swift")

        XCTAssertTrue(
            settingsView.contains("@State private var notifyOnUsagePressure = true"),
            "Advanced settings should keep an explicit usage-pressure notification toggle"
        )
        XCTAssertTrue(
            settingsView.contains("Toggle(\"Notify on usage pressure\", isOn: $notifyOnUsagePressure)"),
            "Monitor settings should expose a quota/usage-pressure notification toggle"
        )
        XCTAssertTrue(
            settingsView.contains("monitor[\"notifyOnUsagePressure\"] as? Bool"),
            "Settings load should read notifyOnUsagePressure from settings.json"
        )
        XCTAssertTrue(
            settingsView.contains("\"notifyOnUsagePressure\": notifyOnUsagePressure"),
            "Settings save should persist notifyOnUsagePressure into the monitor settings object"
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

    func testGeneralSettingsDoesNotExposeLegacyNodeRollbackControls() throws {
        let generalSettings = try source("macos/Engram/Views/Settings/GeneralSettingsSection.swift")

        for forbidden in [
            "Legacy Node rollback settings",
            "Legacy HTTP Port",
            "Legacy Node.js Path",
            "@AppStorage(\"httpPort\")",
            "@AppStorage(\"nodejsPath\")",
        ] {
            XCTAssertFalse(
                generalSettings.contains(forbidden),
                "General settings must not expose dead legacy Node rollback controls: \(forbidden)"
            )
        }
        XCTAssertTrue(
            generalSettings.contains("showDeveloperTools"),
            "General settings should keep the developer tools toggle"
        )
        // The former `mcpEndpointText` showed `http://host:port/mcp`, but the
        // Swift service serves no HTTP /mcp route — MCP is the stdio EngramMCP
        // helper, and correct MCP setup lives in the primary MCP setup section.
        // The misleading URL was removed (UX flow-alignment, 2026-06-15); General
        // settings must NOT advertise a non-existent HTTP MCP endpoint.
        XCTAssertFalse(
            generalSettings.contains("/mcp\""),
            "General settings must not advertise a non-existent HTTP /mcp endpoint"
        )
    }

    func testCascadeAdapterDocsDoNotClaimDisabledLiveSyncMeansZeroIngest() throws {
        let claude = try source("CLAUDE.md")

        XCTAssertFalse(
            claude.contains("ingest zero sessions"),
            "Antigravity and Windsurf can still ingest existing caches, and Antigravity also reads CLI brain transcripts."
        )
        XCTAssertTrue(
            claude.contains("live gRPC sync is disabled"),
            "Docs should name that only the live sync path is disabled."
        )
        XCTAssertTrue(
            claude.contains("cache-only") && claude.contains("Antigravity CLI brain"),
            "Docs should describe the remaining cache/CLI ingestion behavior."
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

    func testMcpModeDoesNotKeepUnusedLiveSessionScannerCompiled() throws {
        let scannerURL = repoRoot.appendingPathComponent("macos/EngramMCP/Core/MCPLiveSessionScanner.swift")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: scannerURL.path),
            "live_sessions returns an explicit MCP-mode unavailable result, so the unused filesystem scanner should not stay compiled"
        )
    }

    func testStartupMigrationCleanupUsesProjectMoveStoreImplementation() throws {
        let startupBackfills = try source("macos/EngramCoreWrite/Indexing/StartupBackfills.swift")

        XCTAssertTrue(
            startupBackfills.contains("MigrationLogStore.cleanupStaleMigrations(db)"),
            "Startup migration cleanup should use the project-move store implementation instead of a drift-prone duplicate SQL statement."
        )
        XCTAssertFalse(
            startupBackfills.contains("stale_after_crash: non-terminal for over 24 hours"),
            "StartupBackfills must not keep its own hardcoded stale-migration cleanup message."
        )
        XCTAssertFalse(
            startupBackfills.contains("started_at <= datetime('now', '-86400 seconds')"),
            "StartupBackfills must not keep a second hardcoded stale threshold."
        )
    }

    func testUnusedSwiftWatcherPathIsRemovedFromProductAndTests() throws {
        for relativePath in [
            "macos/EngramCoreWrite/Indexing/SessionWatcher.swift",
            "macos/EngramCoreWrite/Indexing/NonWatchableSourceRescanner.swift",
            "macos/Shared/EngramCore/Indexing/WatchPathRules.swift",
            "macos/EngramCoreTests/WatcherSemanticsTests.swift",
        ] {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent(relativePath).path),
                "\(relativePath) is unused by the Swift product runtime and should not stay compiled or scan-tested"
            )
        }

        let migrationLogStore = try source("macos/EngramCoreWrite/ProjectMove/MigrationLogStore.swift")
        XCTAssertFalse(
            migrationLogStore.contains("hasPendingMigrationFor"),
            "Swift project-move code must not keep a watcher guard when no Swift watcher is wired into the product runtime"
        )

        let indexer = try source("macos/EngramCoreWrite/Indexing/EngramDatabaseIndexer.swift")
        XCTAssertFalse(
            indexer.contains("FSEvents watcher is not wired into the runtime"),
            "Indexer comments should describe the live periodic scan path instead of documenting a removed watcher"
        )
    }

    func testUnreachableLegacySessionListViewIsRemoved() throws {
        for relativePath in [
            "macos/Engram/Views/SessionListView.swift",
            "macos/Engram/Views/SessionList/SessionTableView.swift",
            "macos/Engram/Views/SessionList/ProjectSearchField.swift",
            "macos/Engram/Views/SessionList/ColumnVisibilityStore.swift",
            "macos/Engram/Views/SessionList/AgentFilterBar.swift",
            "macos/EngramTests/SessionListPersistenceTests.swift",
        ] {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent(relativePath).path),
                "\(relativePath) belongs to the unreachable pre-SessionsPageView session list surface and should not stay compiled"
            )
        }

        let mainWindow = try source("macos/Engram/Views/MainWindowView.swift")
        XCTAssertTrue(
            mainWindow.contains("SessionsPageView()"),
            "MainWindowView should keep routing the Sessions screen to the reachable SessionsPageView"
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

    func testParentLinkValidationRejectsDepthTwoChainsInServiceAndBackfill() throws {
        let service = try source("macos/EngramService/Core/EngramServiceCommandHandler.swift")
        let backfills = try source("macos/EngramCoreWrite/Indexing/StartupBackfills.swift")

        for (name, text) in [
            ("EngramServiceCommandHandler", service),
            ("StartupBackfills", backfills),
        ] {
            XCTAssertTrue(
                text.contains("SELECT COUNT(*) FROM sessions WHERE parent_session_id = ?"),
                "\(name) must check whether the session being linked already has children"
            )
            XCTAssertTrue(
                text.contains("arguments: [sessionId]"),
                "\(name) child-count query must be keyed by the child candidate, not the parent candidate"
            )
        }

        XCTAssertTrue(
            service.contains("if childCount > 0") && service.contains("return \"depth-exceeded\""),
            "Manual service links must reject depth-two chains with the existing depth-exceeded response"
        )
        XCTAssertTrue(
            backfills.contains("return childCount == 0"),
            "Startup parent backfills must skip links that would create depth-two chains"
        )
    }

    func testPolycliHostScoringSqlDoesNotDefeatCwdNormalization() throws {
        let backfills = try source("macos/EngramCoreWrite/Indexing/StartupBackfills.swift")
        let start = try XCTUnwrap(backfills.range(of: "private static func scoredPolycliHosts("))
        let end = try XCTUnwrap(backfills.range(of: "public static func backfillSuggestedParents", range: start.lowerBound..<backfills.endIndex))
        let scoredPolycliHosts = String(backfills[start.lowerBound..<end.lowerBound])

        XCTAssertFalse(
            scoredPolycliHosts.contains("AND cwd = ?"),
            "scoredPolycliHosts must not prefilter hosts with exact cwd equality before normalized scoring"
        )
        XCTAssertTrue(
            scoredPolycliHosts.contains("rtrim(cwd, '/') = rtrim(?, '/')"),
            "scoredPolycliHosts SQL should admit trailing-slash cwd variants for the existing normalized scorer"
        )
    }

    func testProjectMoveRollbackRestoresPatchedFilesFromBackups() throws {
        let orchestrator = try source("macos/EngramCoreWrite/ProjectMove/Orchestrator.swift")
        let compensateStart = try XCTUnwrap(orchestrator.range(of: "private func compensate("))
        let compensateEnd = try XCTUnwrap(orchestrator.range(of: "private struct PatchOutcome", range: compensateStart.lowerBound..<orchestrator.endIndex))
        let compensate = String(orchestrator[compensateStart.lowerBound..<compensateEnd.lowerBound])

        XCTAssertTrue(orchestrator.contains("public let backupPath: String?"))
        XCTAssertTrue(orchestrator.contains("let backupPath = try backupPatchInput(file: file, backupRoot: patchBackupRoot)"))
        XCTAssertTrue(orchestrator.contains("ManifestEntry(path: r.file, occurrences: r.count, backupPath: r.backupPath)"))
        XCTAssertTrue(
            compensate.contains("if let backupPath = entry.backupPath") &&
                compensate.contains("try restorePatchBackup(backupPath: backupPath, targetPath: entry.path)"),
            "rollback must restore the exact pre-patch bytes when a patch backup is available"
        )
        XCTAssertTrue(
            compensate.contains("_ = try JsonlPatch.patchFile("),
            "rollback should keep the old reverse-patch fallback only for legacy manifest entries without backups"
        )
    }

    func testProjectUndoPreflightRunsInsideProjectMoveLock() throws {
        let handler = try source("macos/EngramService/Core/EngramServiceCommandHandler+ProjectMigration.swift")
        let undoStart = try XCTUnwrap(handler.range(of: "static func projectUndo("))
        let batchStart = try XCTUnwrap(handler.range(of: "static func projectMoveBatch(", range: undoStart.lowerBound..<handler.endIndex))
        let projectUndo = String(handler[undoStart.lowerBound..<batchStart.lowerBound])
        let orchestrator = try source("macos/EngramCoreWrite/ProjectMove/Orchestrator.swift")

        XCTAssertTrue(
            projectUndo.contains("ProjectMoveOrchestrator.runUndo("),
            "projectUndo should delegate undo preflight and reverse move to the orchestrator so both run under one project-move lock"
        )
        XCTAssertFalse(
            projectUndo.contains("UndoMigration.prepareReverseRequest"),
            "projectUndo must not run undo preflight before the orchestrator acquires the migration lock"
        )
        XCTAssertTrue(
            orchestrator.contains("MigrationLock.acquire") &&
                orchestrator.contains("UndoMigration.prepareReverseRequest") &&
                orchestrator.range(of: "MigrationLock.acquire")!.lowerBound < orchestrator.range(of: "UndoMigration.prepareReverseRequest")!.lowerBound,
            "ProjectMoveOrchestrator.runUndo must acquire the migration lock before reading migration_log/session state"
        )
        XCTAssertTrue(
            orchestrator.contains("lockAlreadyHeld: true"),
            "The reverse move should reuse the already-held undo lock instead of reacquiring it after preflight"
        )
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
