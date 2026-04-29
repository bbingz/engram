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
}
