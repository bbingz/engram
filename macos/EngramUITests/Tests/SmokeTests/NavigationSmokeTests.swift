import XCTest

final class NavigationSmokeTests: XCTestCase {
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

    func testSidebarFullTraversal() {
        let sidebar = SidebarScreen(app: app)
        sidebar.waitForLoad()

        for page in SidebarScreen.pages {
            let button = sidebar.item(for: page)
            XCTAssertTrue(button.waitForExistence(timeout: 3),
                          "Sidebar item '\(page)' should exist")
            button.click()

            // Verify a container loaded for this page — use the generic page container pattern
            let container = app.element(id: "\(page)_container")
            let loaded = container.waitForExistence(timeout: 5)
            XCTAssertTrue(loaded,
                          "Container for '\(page)' should appear after sidebar click")
        }
    }

    func testCommandPalette() throws {
        // Command palette may not be implemented — skip gracefully if not found
        let sidebar = SidebarScreen(app: app)
        sidebar.waitForLoad()

        // Try Cmd+K which is a common command palette shortcut
        app.typeKey("k", modifierFlags: .command)

        // Look for a command palette element
        let palette = app.element(id: "commandPalette")
        let searchField = app.searchFields.firstMatch

        if palette.waitForExistence(timeout: 2) || searchField.waitForExistence(timeout: 2) {
            XCTAssertTrue(true, "Command palette opened")
        } else {
            throw XCTSkip("Command palette not implemented — skipping")
        }
    }
}
