import XCTest

final class PopoverSmokeTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        TestLaunchConfig.popover.configure(app)
        app.launch()
    }

    override func tearDown() {
        app.terminate()
    }

    func testPopoverRecentActivity() {
        let popover = PopoverScreen(app: app)
        popover.waitForLoad()
        XCTAssertTrue(popover.recentActivity.waitForExistence(timeout: 5),
                      "Popover recent-activity timeline should be visible")
    }
}
