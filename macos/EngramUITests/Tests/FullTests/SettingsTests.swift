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
        let settingsButton = sidebar.settingsItem
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 3),
                      "Settings sidebar item should exist")
        settingsButton.click()
    }

    func testFiveSectionTabs() {
        openSettings()

        let settings = SettingsScreen(app: app)
        settings.waitForLoad()

        // Verify all 5 section tabs exist
        for name in SettingsScreen.sectionNames {
            let section = settings.section(named: name)
            XCTAssertTrue(section.waitForExistence(timeout: 3),
                          "Settings section '\(name)' should exist")
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

        // Verify network settings section is present in the view hierarchy.
        // SwiftUI ScrollView inside NavigationSplitView doesn't respond to XCUITest
        // scroll events on macOS, so we verify existence without requiring hittability.
        let networkSection = settings.networkSection
        XCTAssertTrue(networkSection.waitForExistence(timeout: 3),
                      "Network settings section should exist")

        ScreenshotCapture.capture(name: "settings_network", app: app, screen: "settings", test: #function)
    }

    func testAboutSection() {
        openSettings()

        let settings = SettingsScreen(app: app)
        settings.waitForLoad()

        // The about section is at the bottom of a long settings ScrollView.
        // SwiftUI ScrollView inside NavigationSplitView doesn't respond to XCUITest
        // scroll events on macOS, so we verify the element exists in the tree
        // without requiring it to be hittable/clickable.
        let aboutSection = settings.aboutSection
        XCTAssertTrue(aboutSection.waitForExistence(timeout: 3),
                      "About section should exist in settings")

        ScreenshotCapture.capture(name: "settings_about", app: app, screen: "settings", test: #function)
    }
}
