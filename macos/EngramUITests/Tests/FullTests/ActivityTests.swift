import XCTest

final class ActivityTests: XCTestCase {
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
        sidebar.navigateTo("activity")

        let activity = ActivityScreen(app: app)
        activity.waitForLoad()
        XCTAssertTrue(activity.dailyChart.waitForExistence(timeout: 5),
                      "Activity daily chart should be visible")
        ScreenshotCapture.capture(name: "activity_dailyChart", app: app, screen: "activity", test: #function)
    }

    func testHeatmap() {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("activity")

        let activity = ActivityScreen(app: app)
        activity.waitForLoad()
        XCTAssertTrue(activity.heatmap.waitForExistence(timeout: 5),
                      "Activity heatmap should be visible")
        ScreenshotCapture.capture(name: "activity_heatmap", app: app, screen: "activity", test: #function)
    }
}
