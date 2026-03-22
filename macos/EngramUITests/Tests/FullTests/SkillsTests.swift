import XCTest

final class SkillsTests: XCTestCase {
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

    func testSkillsList() {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("skills")

        let skills = SkillsScreen(app: app)
        skills.waitForLoad()

        let hasList = skills.list.exists
        let hasEmpty = skills.emptyState.waitForExistence(timeout: 3)
        XCTAssertTrue(hasList || hasEmpty,
                      "Skills should show a list or empty state")
        ScreenshotCapture.capture(name: "skills_list", app: app, screen: "skills", test: #function)
    }

    func testSkillsSearch() {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("skills")

        let skills = SkillsScreen(app: app)
        skills.waitForLoad()

        if skills.searchField.waitForExistence(timeout: 5) {
            skills.search(query: "test")
            // Page should remain visible after searching
            XCTAssertTrue(skills.list.exists || skills.emptyState.exists,
                          "Skills list or empty state should be visible after searching")
        } else {
            // No search field — verify page loaded
            XCTAssertTrue(skills.list.exists || skills.emptyState.exists,
                          "Skills page should show content or empty state")
        }
    }
}
