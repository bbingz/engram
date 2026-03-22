import XCTest

final class DarkModeTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        TestLaunchConfig.darkMode.configure(app)
        app.launch()
    }

    override func tearDown() {
        app.terminate()
    }

    func testHomeDark() {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("home")

        let home = HomeScreen(app: app)
        home.waitForLoad()
        XCTAssertTrue(home.kpiCards.waitForExistence(timeout: 5),
                      "KPI cards should be visible in dark mode")
        ScreenshotCapture.capture(name: "home_kpi_cards_dark", app: app, screen: "home", test: #function)
    }

    func testSessionsDark() {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("sessions")

        let sessions = SessionsScreen(app: app)
        sessions.waitForLoad()
        XCTAssertTrue(sessions.sessionList.waitForExistence(timeout: 5),
                      "Session list should be visible in dark mode")
        ScreenshotCapture.capture(name: "sessions_list_dark", app: app, screen: "sessions", test: #function)
    }

    func testSessionDetailDark() {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("sessions")

        let sessions = SessionsScreen(app: app)
        sessions.waitForLoad()
        sessions.selectSession(at: 0)

        let detail = SessionDetailScreen(app: app)
        detail.waitForLoad()
        detail.waitForTranscript()
        ScreenshotCapture.capture(name: "detail_transcript_dark", app: app, screen: "detail", test: #function)
    }

    func testSettingsDark() {
        let sidebar = SidebarScreen(app: app)
        sidebar.waitForLoad()
        sidebar.settingsItem.click()

        let settings = SettingsScreen(app: app)
        settings.waitForLoad()
        XCTAssertTrue(settings.container.exists,
                      "Settings should be visible in dark mode")
        ScreenshotCapture.capture(name: "settings_dark", app: app, screen: "settings", test: #function)
    }

    func testPopoverDark() {
        // Terminate the main window app, launch in popover dark mode
        app.terminate()

        let popoverApp = XCUIApplication()
        popoverApp.launchArguments = [
            "--test-mode", "--fixture-db", TestLaunchConfig.fixtureDBPath,
            "--mock-daemon", "--fixed-date", "2026-01-15T10:00:00Z",
            "--popover-standalone", "--appearance", "dark"
        ]
        popoverApp.launch()

        let popover = PopoverScreen(app: popoverApp)
        popover.waitForLoad()
        ScreenshotCapture.capture(name: "popover_stats_dark", app: popoverApp, screen: "popover", test: #function)

        popoverApp.terminate()
    }
}
