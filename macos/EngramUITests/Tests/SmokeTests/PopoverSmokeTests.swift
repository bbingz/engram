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

    func testPopoverStatsGrid() {
        let popover = PopoverScreen(app: app)
        popover.waitForLoad()
        XCTAssertTrue(popover.statsGrid.waitForExistence(timeout: 5),
                      "Popover stats grid should be visible")
        ScreenshotCapture.capture(name: "popover_stats", app: app, screen: "popover", test: #function)
    }
}
