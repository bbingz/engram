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

        XCTAssertTrue(agents.emptyState.waitForExistence(timeout: 5),
                      "The fixture's unlinked subagent should produce the dedicated no-agent-sessions state")
        XCTAssertTrue(app.staticTexts["No agent sessions"].exists,
                      "The agent miss case should assert its dedicated empty-state title")
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
