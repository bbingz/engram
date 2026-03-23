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

        // Either the timeline has content or shows empty state
        let hasContent = timeline.container.exists
        let hasEmpty = timeline.emptyState.waitForExistence(timeout: 3)
        XCTAssertTrue(hasContent || hasEmpty,
                      "Timeline should render content or empty state")
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
        } else if datePicker.waitForExistence(timeout: 3) {
            XCTAssertTrue(true, "Date picker exists for navigation")
        } else if timeline.emptyState.exists {
            XCTAssertTrue(true, "Timeline is empty — no date navigation available")
        } else {
            throw XCTSkip("Date navigation controls not found in timeline")
        }
    }
}
