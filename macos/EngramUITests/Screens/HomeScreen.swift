import XCTest

struct HomeScreen {
    let app: XCUIApplication

    // MARK: - Elements

    var container: XCUIElement { app.element(id: "home_container") }
    var kpiCards: XCUIElement { app.element(id: "home_kpiCards") }
    var recentSessions: XCUIElement { app.element(id: "home_recentSessions") }
    var dailyChart: XCUIElement { app.element(id: "home_dailyChart") }
    var heatmap: XCUIElement { app.element(id: "home_heatmap") }
    var sourceDistribution: XCUIElement { app.element(id: "home_sourceDistribution") }
    var tierDistribution: XCUIElement { app.element(id: "home_tierDistribution") }

    // MARK: - KPI Cards

    var kpiSessions: XCUIElement { app.element(id: "home_kpiCard_sessions") }
    var kpiSources: XCUIElement { app.element(id: "home_kpiCard_sources") }
    var kpiMessages: XCUIElement { app.element(id: "home_kpiCard_messages") }
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
