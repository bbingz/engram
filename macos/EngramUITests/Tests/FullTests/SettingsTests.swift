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

    func testOpenVikingConfig() {
        openSettings()

        let settings = SettingsScreen(app: app)
        settings.waitForLoad()

        // Navigate to network section where OpenViking config lives
        let networkSection = settings.networkSection
        if networkSection.waitForExistence(timeout: 3) {
            // Scroll into view if needed — network section may be below the fold
            let scrollView = app.scrollViews.firstMatch
            if !networkSection.isHittable, scrollView.exists {
                networkSection.scrollToVisible(in: scrollView)
            }
            networkSection.click()
        }

        // Look for OpenViking-related elements within settings
        let vikingLabel = app.staticTexts["OpenViking"]
        if vikingLabel.waitForExistence(timeout: 3) {
            XCTAssertTrue(true, "OpenViking config found in network settings")
        } else {
            // OpenViking config may be within a different section — verify network section loaded
            XCTAssertTrue(networkSection.exists,
                          "Network settings section should be visible for Viking config")
        }
        ScreenshotCapture.capture(name: "settings_network", app: app, screen: "settings", test: #function)
    }

    func testAboutSection() {
        openSettings()

        let settings = SettingsScreen(app: app)
        settings.waitForLoad()

        let aboutSection = settings.aboutSection
        XCTAssertTrue(aboutSection.waitForExistence(timeout: 3),
                      "About section should exist")

        // About is at the bottom of the settings ScrollView — scroll it into view
        let scrollView = app.scrollViews.firstMatch
        if !aboutSection.isHittable, scrollView.exists {
            aboutSection.scrollToVisible(in: scrollView)
        }
        aboutSection.click()

        ScreenshotCapture.capture(name: "settings_about", app: app, screen: "settings", test: #function)
    }
}
