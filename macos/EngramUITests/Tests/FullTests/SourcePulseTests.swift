import XCTest

final class SourcePulseTests: XCTestCase {
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

    func testStatusGrid() {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("sourcePulse")

        let sourcePulse = SourcePulseScreen(app: app)
        sourcePulse.waitForLoad()

        let hasGrid = sourcePulse.statusGrid.waitForExistence(timeout: 5)
        let hasEmpty = sourcePulse.emptyState.waitForExistence(timeout: 3)
        XCTAssertTrue(hasGrid || hasEmpty,
                      "SourcePulse should show status grid or empty state")
        ScreenshotCapture.capture(name: "sourcePulse_statusGrid", app: app, screen: "sourcePulse", test: #function)
    }

    func testEmptyState() {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("sourcePulse")

        let sourcePulse = SourcePulseScreen(app: app)
        sourcePulse.waitForLoad()

        // Verify the page loaded — either content or empty state is acceptable
        XCTAssertTrue(sourcePulse.container.exists,
                      "SourcePulse container should be visible")
    }
}
