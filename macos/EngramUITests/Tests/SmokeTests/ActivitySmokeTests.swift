import XCTest

final class ActivitySmokeTests: XCTestCase {
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

    func testActivityLoads() {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("activity")

        let activity = ActivityScreen(app: app)
        activity.waitForLoad()
        XCTAssertTrue(activity.container.exists,
                      "Activity container should be visible")
    }

    func testTimelineLoads() {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("timeline")

        let timeline = TimelineScreen(app: app)
        timeline.waitForLoad()
        XCTAssertTrue(timeline.container.exists,
                      "Timeline container should be visible")
    }
}
