import XCTest

final class SettingsTests: XCTestCase {
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

    /// Navigate to settings via the sidebar settings item
    private func openSettings() {
        let sidebar = SidebarScreen(app: app)
        sidebar.waitForLoad()
        sidebar.navigateToSettings()
    }

    func testFiveSectionNavigationItems() {
        openSettings()

        let settings = SettingsScreen(app: app)
        settings.waitForLoad()

        // Verify all 5 section navigation items exist
        for name in SettingsScreen.sectionNames {
            let item = settings.navItem(named: name)
            XCTAssertTrue(item.waitForExistence(timeout: 3),
                          "Settings navigation item '\(name)' should exist")
        }
    }

    func testGeneralSection() {
        openSettings()

        let settings = SettingsScreen(app: app)
        settings.waitForLoad()

        XCTAssertTrue(settings.generalSection.waitForExistence(timeout: 5),
                      "General settings section should be visible")
        ScreenshotCapture.capture(name: "settings_general", app: app, screen: "settings", test: #function)
    }

    func testNetworkSettings() {
        openSettings()

        let settings = SettingsScreen(app: app)
        settings.waitForLoad()

        settings.navigateToSection(named: "network")

        // Verify network settings section is present in the view hierarchy.
        let networkSection = settings.networkSection
        XCTAssertTrue(networkSection.waitForExistence(timeout: 3),
                       "Network settings section should exist")

        ScreenshotCapture.capture(name: "settings_network", app: app, screen: "settings", test: #function)
    }

    func testAboutSection() {
        openSettings()

        let settings = SettingsScreen(app: app)
        settings.waitForLoad()

        settings.navigateToSection(named: "about")

        let aboutSection = settings.aboutSection
        XCTAssertTrue(aboutSection.waitForExistence(timeout: 3),
                       "About section should exist in settings")

        ScreenshotCapture.capture(name: "settings_about", app: app, screen: "settings", test: #function)
    }
}
