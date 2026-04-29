import XCTest

final class NavigationTests: XCTestCase {
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

    func testAllPagesReachable() {
        let sidebar = SidebarScreen(app: app)
        sidebar.waitForLoad()

        // Navigate to every page and verify its container loads
        for page in SidebarScreen.pages {
            sidebar.navigateTo(page)

            let container = app.element(id: "\(page)_container")
            XCTAssertTrue(container.waitForExistence(timeout: 5),
                          "Page '\(page)' container should load after navigation")
        }
    }

    func testSettingsReachable() {
        let sidebar = SidebarScreen(app: app)
        sidebar.waitForLoad()

        let settingsButton = sidebar.settingsItem
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 3),
                      "Settings button should exist in sidebar")
        settingsButton.click()

        let settings = SettingsScreen(app: app)
        XCTAssertTrue(settings.container.waitForExistence(timeout: 5),
                      "Settings container should load after clicking settings")
        ScreenshotCapture.capture(name: "settings_page", app: app, screen: "settings", test: #function)
    }
}
