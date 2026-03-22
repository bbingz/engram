import XCTest

struct SessionsScreen {
    let app: XCUIApplication

    // MARK: - Elements

    var container: XCUIElement { app.otherElements["sessions_container"] }
    var sessionList: XCUIElement { app.otherElements["sessions_list"] }
    var filterPills: XCUIElement { app.otherElements["sessions_filterPills"] }
    var sourcePicker: XCUIElement { app.otherElements["sessions_sourcePicker"] }
    var emptyState: XCUIElement { app.otherElements["sessions_emptyState"] }

    // MARK: - KPI Cards

    var kpiTotal: XCUIElement { app.otherElements["sessions_kpiCard_total"] }
    var kpiMessages: XCUIElement { app.otherElements["sessions_kpiCard_messages"] }
    var kpiAvgDuration: XCUIElement { app.otherElements["sessions_kpiCard_avgDuration"] }

    // MARK: - Session Rows

    func row(at index: Int) -> XCUIElement {
        app.otherElements["sessions_row_\(index)"]
    }

    func selectSession(at index: Int) {
        let r = row(at: index)
        XCTAssertTrue(r.waitForExistence(timeout: 3),
                      "Session row \(index) not found")
        r.click()
    }

    // MARK: - Waits

    func waitForLoad(timeout: TimeInterval = 5) {
        _ = container.waitForExistence(timeout: timeout)
    }
}
