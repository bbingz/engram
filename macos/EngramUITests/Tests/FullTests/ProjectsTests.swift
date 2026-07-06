import XCTest

final class ProjectsTests: XCTestCase {
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

    func testProjectList() {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("projects")

        let projects = ProjectsScreen(app: app)
        projects.waitForLoad()

        let hasList = projects.projectList.waitForExistence(timeout: 5)
        let hasEmpty = projects.emptyState.waitForExistence(timeout: 3)
        XCTAssertTrue(hasList || hasEmpty,
                      "Projects should show a list or empty state")
        ScreenshotCapture.capture(name: "projects_list", app: app, screen: "projects", test: #function)
    }

    func testEmptyProject() {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("projects")

        let projects = ProjectsScreen(app: app)
        projects.waitForLoad()

        // Verify the container loaded — the page itself should always render
        XCTAssertTrue(projects.container.exists,
                      "Projects container should be visible")
    }

    func testProjectMigrationControlsAreReachable() {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("projects")

        let projects = ProjectsScreen(app: app)
        projects.waitForLoad()

        XCTAssertFalse(projects.selectToggle.exists,
                       "Projects page should keep Select collapsed by default")
        XCTAssertFalse(projects.historyButton.exists,
                       "Projects page should keep History collapsed by default")
        XCTAssertFalse(projects.undoButton.exists,
                       "Projects page should keep Undo Recent Move collapsed by default")
        XCTAssertFalse(projects.batchMoveButton.exists,
                       "Projects page should keep Move Selected collapsed by default")

        projects.expandAdvancedMigrationTools()

        XCTAssertTrue(projects.selectToggle.waitForExistence(timeout: 2),
                      "Projects page should expose the Select migration control after opening Advanced")
        XCTAssertTrue(projects.historyButton.waitForExistence(timeout: 2),
                      "Projects page should expose the History migration control after opening Advanced")
        XCTAssertTrue(projects.undoButton.waitForExistence(timeout: 2),
                      "Projects page should expose the Undo Recent Move migration control after opening Advanced")
        let firstProject = projects.group(at: 0)
        if firstProject.waitForExistence(timeout: 2) {
            projects.selectToggle.click()
            let firstCheckbox = projects.checkbox(at: 0)
            XCTAssertTrue(firstCheckbox.waitForExistence(timeout: 2),
                          "Project rows should expose selection checkboxes after clicking Select")
            firstCheckbox.click()
            XCTAssertTrue(projects.batchMoveButton.waitForExistence(timeout: 2),
                          "Projects page should expose Move Selected after selecting a project")

            firstProject.rightClick()
            XCTAssertTrue(app.menuItems["Rename\u{2026}"].waitForExistence(timeout: 2),
                          "Project rows should expose migration commands via context menu")
            app.typeKey(.escape, modifierFlags: [])
        }
    }

    func testProjectMigrationAdvancedScreenshot() {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("projects")

        let projects = ProjectsScreen(app: app)
        projects.waitForLoad()
        projects.expandAdvancedMigrationTools()

        let firstProject = projects.group(at: 0)
        XCTAssertTrue(firstProject.waitForExistence(timeout: 5),
                      "Project fixture should include at least one project for the advanced migration screenshot")

        projects.selectToggle.click()
        let firstCheckbox = projects.checkbox(at: 0)
        XCTAssertTrue(firstCheckbox.waitForExistence(timeout: 2),
                      "Project rows should expose selection checkboxes after clicking Select")
        firstCheckbox.click()
        XCTAssertTrue(projects.batchMoveButton.waitForExistence(timeout: 2),
                      "Projects page should expose Move Selected after selecting a project")

        ScreenshotCapture.capture(name: "projects_migration_advanced", app: app, screen: "projects", test: #function)
    }
}
