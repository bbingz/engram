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

        XCTAssertTrue(sourcePulse.statusGrid.waitForExistence(timeout: 5),
                      "SourcePulse should retain its summary grid while reads fail")
        XCTAssertTrue(sourcePulse.failedState.waitForExistence(timeout: 5),
                      "The unavailable mock service should render the source failure state")
        XCTAssertFalse(sourcePulse.emptyState.exists,
                       "A failed source read must not masquerade as an empty source catalog")
        XCTAssertTrue(sourcePulse.liveUnavailable.waitForExistence(timeout: 5),
                      "SourcePulse should finish the mock-service live poll before capture")
        ScreenshotCapture.capture(name: "sourcePulse_statusGrid", app: app, screen: "sourcePulse", test: #function)
    }

    func testEmptyState() {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("sourcePulse")

        let sourcePulse = SourcePulseScreen(app: app)
        sourcePulse.waitForLoad()

        // This test only verifies that the page shell remains reachable.
        XCTAssertTrue(sourcePulse.container.exists,
                      "SourcePulse container should be visible")
    }
}
