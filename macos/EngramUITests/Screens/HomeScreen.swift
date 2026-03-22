import XCTest

struct HomeScreen {
    let app: XCUIApplication

    // MARK: - Elements

    var container: XCUIElement { app.otherElements["home_container"] }
    var kpiCards: XCUIElement { app.otherElements["home_kpiCards"] }
    var recentSessions: XCUIElement { app.otherElements["home_recentSessions"] }
    var dailyChart: XCUIElement { app.otherElements["home_dailyChart"] }
    var heatmap: XCUIElement { app.otherElements["home_heatmap"] }
    var sourceDistribution: XCUIElement { app.otherElements["home_sourceDistribution"] }
    var tierDistribution: XCUIElement { app.otherElements["home_tierDistribution"] }

    // MARK: - KPI Cards

    var kpiSessions: XCUIElement { app.otherElements["home_kpiCard_sessions"] }
    var kpiSources: XCUIElement { app.otherElements["home_kpiCard_sources"] }
    var kpiMessages: XCUIElement { app.otherElements["home_kpiCard_messages"] }
    var kpiProjects: XCUIElement { app.otherElements["home_kpiCard_projects"] }

    // MARK: - Recent Sessions

    func recentSession(at index: Int) -> XCUIElement {
        app.otherElements["home_recentSession_\(index)"]
    }

    // MARK: - Waits

    func waitForLoad(timeout: TimeInterval = 5) {
        _ = container.waitForExistence(timeout: timeout)
    }
}
