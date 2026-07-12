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

    private func openSettings() {
        let sidebar = SidebarScreen(app: app)
        sidebar.waitForLoad()
        sidebar.navigateToSettings()
    }

    func testSectionNavigationItems() {
        openSettings()

        let settings = SettingsScreen(app: app)
        settings.waitForLoad()

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

    func testNetworkSettingsIsRemoved() {
        openSettings()

        let settings = SettingsScreen(app: app)
        settings.waitForLoad()

        XCTAssertFalse(settings.navItem(named: "network").exists,
                       "Network settings nav item should be removed with the dead peer-sync surface")
        XCTAssertFalse(settings.section(named: "network").exists,
                       "Network settings section should be removed with the dead peer-sync surface")
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

    func testArchiveSectionSimplifiedChinese() {
        app.terminate()
        app = XCUIApplication()
        TestLaunchConfig.mainWindow.configure(app)
        app.launchArguments += [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
        ]
        app.launch()

        openSettings()

        let settings = SettingsScreen(app: app)
        settings.waitForLoad()
        settings.navigateToSection(named: "archive")

        XCTAssertTrue(settings.archiveSection.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["归档同步状态"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.element(id: "archiveSync_status").exists)
        XCTAssertTrue(app.button(id: "archiveSync_refresh").exists)

        ScreenshotCapture.capture(
            name: "settings_archive_zh-Hans",
            app: app,
            screen: "settings",
            test: #function
        )
    }
}
