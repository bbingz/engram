import XCTest

final class HooksTests: XCTestCase {
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

    func testHookList() {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("hooks")

        let hooks = HooksScreen(app: app)
        hooks.waitForLoad()

        let hasList = hooks.list.exists
        let hasEmpty = hooks.emptyState.waitForExistence(timeout: 3)
        XCTAssertTrue(hasList || hasEmpty,
                      "Hooks should show a list or empty state")
        ScreenshotCapture.capture(name: "hooks_list", app: app, screen: "hooks", test: #function)
    }

    func testEmptyState() {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("hooks")

        let hooks = HooksScreen(app: app)
        hooks.waitForLoad()

        // Either list or empty state — both are valid
        let hasList = hooks.list.exists
        let hasEmpty = hooks.emptyState.waitForExistence(timeout: 3)
        XCTAssertTrue(hasList || hasEmpty,
                      "Hooks page should display content or empty state")
    }
}
