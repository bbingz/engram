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

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
