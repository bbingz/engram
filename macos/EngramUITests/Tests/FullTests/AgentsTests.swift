import XCTest

final class AgentsTests: XCTestCase {
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

    func testAgentList() {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("agents")

        let agents = AgentsScreen(app: app)
        agents.waitForLoad()

        let hasList = agents.list.waitForExistence(timeout: 5)
        let hasEmpty = agents.emptyState.waitForExistence(timeout: 3)
        XCTAssertTrue(hasList || hasEmpty,
                      "Agents should show a list or empty state")
        ScreenshotCapture.capture(name: "agents_list", app: app, screen: "agents", test: #function)
    }

    func testEmptyState() {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("agents")

        let agents = AgentsScreen(app: app)
        agents.waitForLoad()

        // Verify the container loaded regardless of content
        XCTAssertTrue(agents.container.exists,
                      "Agents container should be visible")
    }
}
