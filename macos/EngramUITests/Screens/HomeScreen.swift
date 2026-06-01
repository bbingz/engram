import XCTest

struct HomeScreen {
    let app: XCUIApplication

    // MARK: - Elements

    var container: XCUIElement { app.element(id: "home_container") }
    var kpiCards: XCUIElement { app.element(id: "home_kpiCards") }
    var recentSessions: XCUIElement { app.element(id: "home_recentSessions") }
    var todayHeader: XCUIElement { app.element(id: "home_todayHeader") }
    var followUps: XCUIElement { app.element(id: "home_followUps") }
    var changedRepos: XCUIElement { app.element(id: "home_changedRepos") }
    var serviceState: XCUIElement { app.element(id: "home_serviceState") }

    // MARK: - KPI Cards

    var kpiSessions: XCUIElement { app.element(id: "home_kpiCard_sessions") }
    var kpiToday: XCUIElement { app.element(id: "home_kpiCard_today") }
    var kpiService: XCUIElement { app.element(id: "home_kpiCard_service") }
    var kpiProjects: XCUIElement { app.element(id: "home_kpiCard_projects") }

    // MARK: - Recent Sessions

    func recentSession(at index: Int) -> XCUIElement {
        app.element(id: "home_recentSession_\(index)")
    }

    // MARK: - Waits

    func waitForLoad(timeout: TimeInterval = 5) {
        _ = container.waitForExistence(timeout: timeout)
    }
}
