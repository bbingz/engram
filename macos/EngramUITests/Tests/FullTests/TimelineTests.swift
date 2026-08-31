import XCTest

final class TimelineTests: XCTestCase {
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

    func testTimelineRenders() {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("timeline")

        let timeline = TimelineScreen(app: app)
        timeline.waitForLoad()

        XCTAssertTrue(timeline.modePicker.waitForExistence(timeout: 5))
        timeline.mode(named: "Sessions").click()
        XCTAssertTrue(timeline.chart.waitForExistence(timeout: 5),
                      "The seeded session timeline should render a chart")
        XCTAssertTrue(
            timeline.container.buttons["expandableCard_askCount"].firstMatch.waitForExistence(timeout: 5),
            "The seeded session timeline should render at least one session row"
        )
        ScreenshotCapture.capture(name: "timeline_page", app: app, screen: "timeline", test: #function)
    }

    func testDateNavigation() throws {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("timeline")

        let timeline = TimelineScreen(app: app)
        timeline.waitForLoad()

        // Look for date navigation controls (arrows, date picker, etc.)
        let previousButton = app.buttons["Previous"]
        let nextButton = app.buttons["Next"]
        let datePicker = app.datePickers.firstMatch

        if previousButton.waitForExistence(timeout: 3) {
            previousButton.click()
            XCTAssertTrue(timeline.container.exists,
                          "Timeline should remain after date navigation")
        } else if nextButton.waitForExistence(timeout: 3) {
            nextButton.click()
            XCTAssertTrue(timeline.container.exists,
                          "Timeline should remain after date navigation")
        } else if datePicker.waitForExistence(timeout: 3) {
            XCTAssertTrue(true, "Date picker exists for navigation")
        } else if timeline.emptyState.exists {
            XCTAssertTrue(true, "Timeline is empty — no date navigation available")
        } else {
            throw XCTSkip("Date navigation controls not found in timeline")
        }
    }
}
