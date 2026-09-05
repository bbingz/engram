import XCTest

final class SessionsSmokeTests: XCTestCase {
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

    func testSessionsListLoads() {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("sessions")

        let sessions = SessionsScreen(app: app)
        sessions.waitForLoad()
        XCTAssertTrue(sessions.sessionList.waitForExistence(timeout: 5),
                      "Session list should be visible")
    }

    func testSessionsFilterToday() {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("sessions")

        let sessions = SessionsScreen(app: app)
        sessions.waitForLoad()
        XCTAssertTrue(sessions.showAllToggle.waitForExistence(timeout: 5))
        sessions.showAllToggle.click()
        let todayButton = sessions.filterPill(named: "Today")
        XCTAssertTrue(todayButton.waitForExistence(timeout: 5), sessions.filterPills.debugDescription)
        todayButton.click()
        XCTAssertTrue(
            sessions.result(containingText: "Fixed authentication flow bug").waitForExistence(timeout: 10),
            "The fixture session dated on --fixed-date must remain visible under Today"
        )
    }

    func testSessionsSourceFilter() {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("sessions")

        let sessions = SessionsScreen(app: app)
        sessions.waitForLoad()

        let sourcePicker = sessions.sourcePicker
        XCTAssertTrue(sourcePicker.waitForExistence(timeout: 5),
                      "The multi-source fixture should expose the source picker")
        sourcePicker.click()
        app.menuItems["Claude"].click()
        XCTAssertTrue(
            sessions.result(containingText: "Fixed authentication flow bug").waitForExistence(timeout: 10),
            "Filtering to Claude should retain the seeded Claude session"
        )
    }
}
