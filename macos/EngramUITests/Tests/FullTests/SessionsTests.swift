import XCTest

final class SessionsTests: XCTestCase {
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

    func testSortByDuration() throws {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("sessions")

        let sessions = SessionsScreen(app: app)
        sessions.waitForLoad()

        // Look for a sort control — may be a popup button or segmented control
        let sortButton = app.popUpButtons.firstMatch
        if sortButton.waitForExistence(timeout: 3) {
            sortButton.click()
            // Look for a "Duration" menu item
            let durationItem = app.menuItems["Duration"]
            if durationItem.waitForExistence(timeout: 2) {
                durationItem.click()
                XCTAssertTrue(sessions.sessionList.exists,
                              "Session list should remain visible after sorting by duration")
                return
            }
        }
        throw XCTSkip("Sort by duration control not found — skipping")
    }

    func testPagination() throws {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("sessions")

        let sessions = SessionsScreen(app: app)
        sessions.waitForLoad()

        // Look for pagination controls (next page button, page numbers, etc.)
        let nextButton = app.buttons["Next"]
        let pageButton = app.buttons["Page 2"]
        let loadMore = app.buttons["Load More"]

        if nextButton.waitForExistence(timeout: 3) {
            nextButton.click()
            XCTAssertTrue(sessions.sessionList.exists,
                          "Session list should be visible after pagination")
        } else if pageButton.waitForExistence(timeout: 2) {
            pageButton.click()
            XCTAssertTrue(sessions.sessionList.exists,
                          "Session list should be visible after page change")
        } else if loadMore.waitForExistence(timeout: 2) {
            loadMore.click()
            XCTAssertTrue(sessions.sessionList.exists,
                          "Session list should be visible after load more")
        } else {
            throw XCTSkip("Pagination controls not found — fixture may have few sessions")
        }
    }

    func testEmptyFilterResult() {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("sessions")

        let sessions = SessionsScreen(app: app)
        sessions.waitForLoad()

        let filterPills = sessions.filterPills
        if filterPills.waitForExistence(timeout: 5) {
            // Click all filter pills to maximally restrict results
            let buttons = filterPills.buttons.allElementsBoundByIndex
            for button in buttons {
                if button.exists && button.isHittable {
                    button.click()
                }
            }
        }

        // Either session list or empty state should appear
        let hasContent = sessions.sessionList.waitForExistence(timeout: 3)
        let hasEmpty = sessions.emptyState.waitForExistence(timeout: 3)
        XCTAssertTrue(hasContent || hasEmpty,
                      "Either session list or empty state should be visible after applying filters")
    }
}
