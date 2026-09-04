import XCTest
@testable import Engram

/// Rows 7/17/24/28 pure helpers for mcp-activation-onboarding.
final class MCPActivationOnboardingTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: - Row 17 URL builder

    func testGitHubIssueURLIncludesVersionAndBuild_repro() {
        let url = GitHubIssueURL.reportIssue(version: "1.0.5", build: "42")
        XCTAssertEqual(url.host, "github.com")
        XCTAssertTrue(url.path.hasSuffix("/issues/new"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let body = items.first(where: { $0.name == "body" })?.value ?? ""
        XCTAssertTrue(body.contains("1.0.5"), body)
        XCTAssertTrue(body.contains("42"), body)
    }

    // MARK: - Row 24 detector + gate

    func testEngramConfiguredDetection_repro() {
        let global = #"{"mcpServers":{"engram":{"command":"/x"}}}"#.data(using: .utf8)!
        XCTAssertTrue(MCPClientDetection.isEngramConfigured(claudeJSON: global))

        let project = #"{"projects":{"/tmp/p":{"mcpServers":{"engram":{}}}}}"#.data(using: .utf8)!
        XCTAssertTrue(MCPClientDetection.isEngramConfigured(claudeJSON: project))

        let other = #"{"mcpServers":{"other":{}}}"#.data(using: .utf8)!
        XCTAssertFalse(MCPClientDetection.isEngramConfigured(claudeJSON: other))

        XCTAssertFalse(MCPClientDetection.isEngramConfigured(claudeJSON: Data("not-json".utf8)))
        XCTAssertFalse(MCPClientDetection.isEngramConfigured(claudeJSON: Data()))
    }

    func testMCPActivationGateTruthTable_repro() {
        XCTAssertTrue(MCPActivationGate.shouldShow(indexedSessions: 1, mcpConfigured: false, dismissed: false))
        XCTAssertFalse(MCPActivationGate.shouldShow(indexedSessions: 0, mcpConfigured: false, dismissed: false))
        XCTAssertFalse(MCPActivationGate.shouldShow(indexedSessions: 1, mcpConfigured: true, dismissed: false))
        XCTAssertFalse(MCPActivationGate.shouldShow(indexedSessions: 1, mcpConfigured: false, dismissed: true))
    }

    // MARK: - Row 28 ladder

    private func invocation(
        helperMissing: Bool = false,
        processFailed: Bool = false,
        timedOut: Bool = false,
        malformed: Bool = false
    ) -> EngramCLIContextCommand.MCPInvocationResult {
        EngramCLIContextCommand.MCPInvocationResult(
            text: malformed ? nil : "ok",
            timedOut: timedOut,
            helperMissing: helperMissing,
            malformed: malformed,
            processFailed: processFailed
        )
    }

    func testVerifyLadderRungs_repro() {
        // resolve: no candidate exists on disk
        let missing = MCPVerificationLadder.verify(
            candidates: ["/no/such/helper"],
            isExecutable: { _ in true },
            invoke: { _ in self.invocation() },
            serviceRunning: true,
            fileExists: { _ in false }
        )
        XCTAssertEqual(missing.failingRung, .resolve)
        XCTAssertNotNil(missing.remedy)

        // execBit
        let noExec = MCPVerificationLadder.verify(
            candidates: ["/tmp/helper"],
            isExecutable: { _ in false },
            invoke: { _ in self.invocation() },
            serviceRunning: true,
            fileExists: { _ in true }
        )
        XCTAssertEqual(noExec.failingRung, .execBit)

        // handshake variants
        for (label, inv) in [
            ("missing", invocation(helperMissing: true)),
            ("crash", invocation(processFailed: true)),
            ("timeout", invocation(timedOut: true)),
            ("malformed", invocation(malformed: true)),
        ] {
            let r = MCPVerificationLadder.verify(
                candidates: ["/tmp/helper"],
                isExecutable: { _ in true },
                invoke: { _ in inv },
                serviceRunning: true,
                fileExists: { _ in true }
            )
            XCTAssertEqual(r.failingRung, .handshake, label)
            XCTAssertNotNil(r.remedy, label)
        }

        // socket
        let socket = MCPVerificationLadder.verify(
            candidates: ["/tmp/helper"],
            isExecutable: { _ in true },
            invoke: { _ in self.invocation() },
            serviceRunning: false,
            fileExists: { _ in true }
        )
        XCTAssertEqual(socket.failingRung, .socket)

        // pass
        let pass = MCPVerificationLadder.verify(
            candidates: ["/tmp/helper"],
            isExecutable: { _ in true },
            invoke: { _ in self.invocation() },
            serviceRunning: true,
            fileExists: { _ in true }
        )
        XCTAssertTrue(pass.passed)
        XCTAssertNil(pass.failingRung)
        XCTAssertNil(pass.remedy)
    }

    // MARK: - Source contracts

    func testOnboardingWindsurfPathAndMCPStep() throws {
        let onboarding = try source("macos/Engram/Onboarding/OnboardingView.swift")
        XCTAssertTrue(onboarding.contains(".engram/cache/windsurf"))
        XCTAssertFalse(onboarding.contains(".codeium/windsurf"))
        XCTAssertTrue(onboarding.contains("ForEach(0..<5)"))
        XCTAssertTrue(onboarding.contains("mcpStep"))
        XCTAssertTrue(onboarding.contains("MCP") || onboarding.contains("get_context"))
        XCTAssertTrue(onboarding.contains("!ArchivedDefaultOffSources.contains"))
        XCTAssertFalse(onboarding.contains("(\"lobsterai\""))
    }

    func testHelpMenuAndContextOrder() throws {
        let menu = try source("macos/Engram/MenuBarController.swift")
        XCTAssertTrue(menu.contains("NSApp.helpMenu"))
        XCTAssertTrue(menu.contains("Report an Issue"))
        XCTAssertTrue(menu.contains("Show Onboarding"))
        // Help items before separator; Restart (row 5) lands after separator later.
        let reportIdx = menu.range(of: "Report an Issue")!.lowerBound
        let sepIdx = menu.range(of: "menu.addItem(.separator())")!.lowerBound
        XCTAssertLessThan(reportIdx, sepIdx)
    }

    func testMCPHelperDerivationAndNoNodeSentence() throws {
        let sources = try source("macos/Engram/Views/Settings/SourcesSettingsSection.swift")
        XCTAssertTrue(sources.contains("mcpHelperCandidates("))
        XCTAssertTrue(sources.contains("Bundle.main"))
        XCTAssertFalse(sources.contains("Node MCP"))
        XCTAssertTrue(sources.contains("Test now"))
        XCTAssertTrue(sources.contains("MCPVerificationLadder"))
    }

    /// ui-search-settings-5: Gemini must retain confirmation for mutating MCP tools.
    func testGeminiSnippetDoesNotTrustMCPServer_repro() throws {
        let sources = try source("macos/Engram/Views/Settings/SourcesSettingsSection.swift")
        let geminiStart = try XCTUnwrap(sources.range(of: #"name: "Gemini CLI""#))
        let codexStart = try XCTUnwrap(
            sources.range(of: #"name: "Codex CLI""#, range: geminiStart.upperBound..<sources.endIndex)
        )
        let gemini = sources[geminiStart.lowerBound..<codexStart.lowerBound]
        XCTAssertTrue(gemini.contains(#""trust": false"#))
        XCTAssertFalse(gemini.contains(#""trust": true"#))
    }

    func testHomeActivationCardWiring() throws {
        let home = try source("macos/Engram/Views/Pages/HomeView.swift")
        XCTAssertTrue(home.contains("home_mcpActivationCard"))
        XCTAssertTrue(home.contains("MCPActivationGate"))
        XCTAssertTrue(home.contains("get_context"))
        XCTAssertTrue(home.contains("MCPClientDetection.isEngramConfiguredOnDisk"))
    }

    func testOnboardingClosePathPresent() throws {
        let app = try source("macos/Engram/App.swift")
        XCTAssertTrue(app.contains("windowWillClose"))
        XCTAssertTrue(app.contains("onboardingWindow?.delegate = nil"))
        XCTAssertTrue(app.contains("NSWindowDelegate"))
    }

    func testOnboardingWindowIsReusedAndKeepsRegularActivationWhileVisible_repro() throws {
        let app = try source("macos/Engram/App.swift")
        let menu = try source("macos/Engram/MenuBarController.swift")

        XCTAssertTrue(app.contains("if let onboardingWindow"))
        XCTAssertTrue(app.contains("hasOnboardingWindow:"))
        XCTAssertTrue(menu.contains("hasOnboardingWindow"))
        XCTAssertTrue(menu.contains("!self.hasOnboardingWindow()"))
    }

    func testUITestLaunchConsumesMockAndCanForceOnboarding_repro() throws {
        let environment = try source("macos/Engram/Core/AppEnvironment.swift")
        let app = try source("macos/Engram/App.swift")
        let launch = try source("macos/EngramUITests/Helpers/TestLaunchConfig.swift")
        let onboarding = try source("macos/Engram/Onboarding/OnboardingView.swift")
        let searchTests = try source("macos/EngramUITests/Tests/FullTests/SearchTests.swift")

        XCTAssertTrue(environment.contains("let showOnboarding: Bool"))
        XCTAssertTrue(environment.contains("args.contains(\"--show-onboarding\")"))
        XCTAssertTrue(app.contains("environment.mockDaemon"))
        XCTAssertTrue(app.contains("MockEngramServiceClient"))
        XCTAssertTrue(app.contains("environment.showOnboarding"))
        XCTAssertTrue(launch.contains("--show-onboarding"))
        for identifier in [
            "onboarding_container",
            "onboarding_getStarted",
            "onboarding_sourcesContinue",
            "onboarding_fdaContinue",
            "onboarding_mcpContinue",
            "onboarding_finish",
        ] {
            XCTAssertTrue(onboarding.contains(identifier), "missing \(identifier)")
        }
        XCTAssertFalse(searchTests.contains("XCTAssertTrue(true"))
        XCTAssertFalse(searchTests.contains("if search.results.exists"))
    }

    /// Invariant 6: every UI-test process owns an isolated HOME and test-mode
    /// startup never migrates or scrubs production settings/keychain state.
    func testUITestLaunchesUseHermeticHomeAndSkipSettingsMutation_repro() throws {
        let launch = try source("macos/EngramUITests/Helpers/TestLaunchConfig.swift")
        let signing = try source("macos/EngramUITests/Tests/SmokeTests/SigningVerificationTest.swift")
        let darkMode = try source("macos/EngramUITests/Tests/FullTests/DarkModeTests.swift")
        let app = try source("macos/Engram/App.swift")

        XCTAssertTrue(launch.contains("app.launchEnvironment = ["))
        XCTAssertTrue(launch.contains(#""HOME": home.path"#))
        XCTAssertTrue(launch.contains(#""CFFIXED_USER_HOME": home.path"#))
        XCTAssertTrue(launch.contains(#""TMPDIR": home.path"#))
        XCTAssertTrue(launch.contains("UUID().uuidString"))
        XCTAssertTrue(launch.contains("ENGRAM_SETTINGS_PATH"))
        XCTAssertTrue(launch.contains("ENGRAM_RUNTIME_AI_SECRETS_PATH"))
        XCTAssertTrue(launch.contains("ENGRAM_EMBEDDING_API_KEY"))
        XCTAssertTrue(launch.contains("ENGRAM_EMBEDDING_BASE_URL"))
        XCTAssertTrue(launch.contains("ENGRAM_EMBEDDING_MODEL"))
        XCTAssertTrue(launch.contains("ENGRAM_EMBEDDING_DIM"))
        XCTAssertTrue(launch.contains("ENGRAM_DIR"))
        XCTAssertTrue(launch.contains("TemporaryUITestHomeObserver"))
        XCTAssertTrue(launch.contains("removeItem(at: root)"))
        XCTAssertTrue(signing.contains("TestLaunchConfig.mainWindow.configure(app)"))
        XCTAssertTrue(darkMode.contains("TestLaunchConfig.popover.configure(popoverApp)"))
        XCTAssertTrue(app.contains("if !environment.isTestMode"))
    }

    func testUITestConfigureFailsClosedBeforeReportingSetupFailure_repro() throws {
        let launch = try source("macos/EngramUITests/Helpers/TestLaunchConfig.swift")
        let onboardingTests = try source("macos/EngramUITests/Tests/FullTests/OnboardingTests.swift")
        let signingTest = try source("macos/EngramUITests/Tests/SmokeTests/SigningVerificationTest.swift")
        let environment = try XCTUnwrap(launch.range(of: "app.launchEnvironment = ["))
        let firstFailure = try XCTUnwrap(launch.range(of: "XCTFail("))
        let testMode = try XCTUnwrap(
            launch.range(of: "app.launchArguments += [\n            \"--test-mode\"")
        )

        XCTAssertLessThan(environment.lowerBound, firstFailure.lowerBound)
        XCTAssertLessThan(testMode.lowerBound, firstFailure.lowerBound)
        for caller in [onboardingTests, signingTest] {
            let failFast = try XCTUnwrap(caller.range(of: "continueAfterFailure = false"))
            let configure = try XCTUnwrap(caller.range(of: ".configure(app)"))
            let launch = try XCTUnwrap(caller.range(of: "app.launch()"))
            XCTAssertLessThan(failFast.lowerBound, configure.lowerBound)
            XCTAssertLessThan(configure.lowerBound, launch.lowerBound)
        }
    }
}
