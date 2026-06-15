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

            // Verify a container loaded for this page — use the generic page container pattern.
            // 15s (not 5s): the Observability page renders heavy diagnostics
            // (LogStreamView reads OSLog on first load) and intermittently took
            // >5s to register its container on CI, flaking this smoke run while
            // the full run passed. Light pages still resolve in well under 1s, so
            // the larger ceiling only adds wall-time when a container is genuinely slow.
            let container = app.element(id: "\(page)_container")
            let loaded = container.waitForExistence(timeout: 15)
            XCTAssertTrue(loaded,
                          "Container for '\(page)' should appear after sidebar click")
        }
    }

    func testCommandPalette() throws {
        let paletteButton = app.button(id: "command_palette_button")
        XCTAssertTrue(paletteButton.waitForExistence(timeout: 10),
                      "Command palette toolbar button should be present before testing Cmd+K")

        app.activate()
        let mainWindow = app.windows.firstMatch
        if mainWindow.waitForExistence(timeout: 3) {
            mainWindow.click()
        }
        app.typeKey("k", modifierFlags: .command)

        let searchField = app.textFields["commandPalette_search"].firstMatch
        if !searchField.waitForExistence(timeout: 3) {
            paletteButton.click()
        }
        XCTAssertTrue(searchField.waitForExistence(timeout: 3),
                      "Command Palette should open the search field")
    }
}
