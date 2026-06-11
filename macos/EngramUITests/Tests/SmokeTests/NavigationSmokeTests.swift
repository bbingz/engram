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
        let paletteButton = app.button(id: "command_palette_button")
        XCTAssertTrue(paletteButton.waitForExistence(timeout: 10),
                      "Command palette toolbar button should be present before testing Cmd+K")

        app.typeKey("k", modifierFlags: .command)

        let searchField = app.textFields["commandPalette_search"].firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 3),
                      "Cmd+K should open the command palette search field")
    }
}
