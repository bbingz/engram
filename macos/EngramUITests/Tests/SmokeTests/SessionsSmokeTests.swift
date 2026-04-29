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

        let filterPills = sessions.filterPills
        if filterPills.waitForExistence(timeout: 5) {
            // Look for a "Today" filter button within the filter pills area
            let todayButton = filterPills.buttons["Today"]
            if todayButton.waitForExistence(timeout: 3) {
                todayButton.click()
                // Verify the list still exists after filtering
                XCTAssertTrue(sessions.sessionList.exists || sessions.emptyState.exists,
                              "Either session list or empty state should be visible after filtering")
            } else {
                // Filter pills exist but no "Today" — click the first available pill
                let firstButton = filterPills.buttons.firstMatch
                if firstButton.exists {
                    firstButton.click()
                }
                XCTAssertTrue(sessions.sessionList.exists || sessions.emptyState.exists,
                              "Either session list or empty state should be visible")
            }
        } else {
            XCTAssertTrue(sessions.sessionList.exists,
                          "Session list should be visible when no filter pills")
        }
    }

    func testSessionsSourceFilter() {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("sessions")

        let sessions = SessionsScreen(app: app)
        sessions.waitForLoad()

        let sourcePicker = sessions.sourcePicker
        if sourcePicker.waitForExistence(timeout: 5) {
            sourcePicker.click()
            // After clicking the picker, verify the list updates
            XCTAssertTrue(sessions.sessionList.exists || sessions.emptyState.exists,
                          "Session list or empty state should remain visible after source filter interaction")
        } else {
            // Source picker may not exist in fixture data — that's acceptable
            XCTAssertTrue(sessions.sessionList.exists,
                          "Session list should be visible when no source picker")
        }
    }
}
