import XCTest

final class HomeTests: XCTestCase {
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

    func testDailyChart() {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("home")

        let home = HomeScreen(app: app)
        home.waitForLoad()
        XCTAssertTrue(home.dailyChart.waitForExistence(timeout: 5),
                      "Daily chart should be visible on the home page")
        ScreenshotCapture.capture(name: "home_dailyChart", app: app, screen: "home", test: #function)
    }

    func testHeatmap() {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("home")

        let home = HomeScreen(app: app)
        home.waitForLoad()
        XCTAssertTrue(home.heatmap.waitForExistence(timeout: 5),
                      "Heatmap should be visible on the home page")
        ScreenshotCapture.capture(name: "home_heatmap", app: app, screen: "home", test: #function)
    }

    func testSourceDistribution() {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("home")

        let home = HomeScreen(app: app)
        home.waitForLoad()
        XCTAssertTrue(home.sourceDistribution.waitForExistence(timeout: 5),
                      "Source distribution chart should be visible on the home page")
        ScreenshotCapture.capture(name: "home_sourceDistribution", app: app, screen: "home", test: #function)
    }
}
