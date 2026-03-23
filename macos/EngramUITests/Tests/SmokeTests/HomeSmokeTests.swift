import XCTest

final class HomeSmokeTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        TestLaunchConfig.mainWindow.configure(app)
        app.launch()
    }

    override func tearDown() {
        app.terminate()
    }

    func testHomePageLoads() {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("home")

        let home = HomeScreen(app: app)
        home.waitForLoad()
        XCTAssertTrue(home.kpiCards.exists, "KPI cards should be visible")
        ScreenshotCapture.capture(name: "home_kpi_cards", app: app, screen: "home", test: #function)
    }

    func testHomeRecentSessions() {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("home")

        let home = HomeScreen(app: app)
        home.waitForLoad()
        XCTAssertTrue(home.recentSessions.waitForExistence(timeout: 5),
                      "Recent sessions section should be visible")
    }
}
