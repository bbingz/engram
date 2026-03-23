import XCTest

struct SessionsScreen {
    let app: XCUIApplication

    // MARK: - Elements

    var container: XCUIElement { app.element(id: "sessions_container") }
    var sessionList: XCUIElement { app.element(id: "sessions_list") }
    var filterPills: XCUIElement { app.element(id: "sessions_filterPills") }
    var sourcePicker: XCUIElement { app.element(id: "sessions_sourcePicker") }
    var emptyState: XCUIElement { app.element(id: "sessions_emptyState") }

    // MARK: - KPI Cards

    var kpiTotal: XCUIElement { app.element(id: "sessions_kpiCard_total") }
    var kpiMessages: XCUIElement { app.element(id: "sessions_kpiCard_messages") }
    var kpiAvgDuration: XCUIElement { app.element(id: "sessions_kpiCard_avgDuration") }

    // MARK: - Session Rows

    func row(at index: Int) -> XCUIElement {
        app.element(id: "sessions_row_\(index)")
    }

    func selectSession(at index: Int) {
        // Wait for session list to be populated before selecting a row
        _ = sessionList.waitForExistence(timeout: 10)
        let r = row(at: index)
        XCTAssertTrue(r.waitForExistence(timeout: 10),
                      "Session row \(index) not found")
        r.click()
    }

    // MARK: - Waits

    func waitForLoad(timeout: TimeInterval = 5) {
        _ = container.waitForExistence(timeout: timeout)
    }
}
