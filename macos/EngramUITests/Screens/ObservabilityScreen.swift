import XCTest

struct ObservabilityScreen {
    let app: XCUIApplication

    // MARK: - Container

    var container: XCUIElement { app.otherElements["observability_container"] }
    var tabPicker: XCUIElement { app.otherElements["observability_tabPicker"] }

    // MARK: - Tab Views

    var logStream: XCUIElement { app.otherElements["observability_logStream"] }
    var errorDashboard: XCUIElement { app.otherElements["observability_errorDashboard"] }
    var performance: XCUIElement { app.otherElements["observability_performance"] }
    var traceExplorer: XCUIElement { app.otherElements["observability_traceExplorer"] }
    var health: XCUIElement { app.otherElements["observability_health"] }

    // MARK: - Log Stream Details

    var logLevelPicker: XCUIElement { app.otherElements["observability_logLevelPicker"] }
    var logModulePicker: XCUIElement { app.otherElements["observability_logModulePicker"] }
    var logList: XCUIElement { app.otherElements["observability_logList"] }

    // MARK: - Tab Names (match ObservabilityView.Tab.rawValue)

    static let tabs = ["Logs", "Errors", "Performance", "Traces", "Health"]

    // MARK: - Actions

    func selectTab(_ tabName: String) {
        // Segmented picker tabs appear as buttons in the accessibility tree
        let tab = app.buttons[tabName]
        XCTAssertTrue(tab.waitForExistence(timeout: 3),
                      "Observability tab '\(tabName)' not found")
        tab.click()
    }

    // MARK: - Waits

    func waitForLoad(timeout: TimeInterval = 5) {
        _ = container.waitForExistence(timeout: timeout)
    }
}
