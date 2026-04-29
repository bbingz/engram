import XCTest

struct ObservabilityScreen {
    let app: XCUIApplication

    // MARK: - Container

    var container: XCUIElement { app.element(id: "observability_container") }
    var tabPicker: XCUIElement { app.element(id: "observability_tabPicker") }

    // MARK: - Tab Views

    var logStream: XCUIElement { app.element(id: "observability_logStream") }
    var errorDashboard: XCUIElement { app.element(id: "observability_errorDashboard") }
    var performance: XCUIElement { app.element(id: "observability_performance") }
    var traceExplorer: XCUIElement { app.element(id: "observability_traceExplorer") }
    var health: XCUIElement { app.element(id: "observability_health") }

    // MARK: - Log Stream Details

    var logLevelPicker: XCUIElement { app.element(id: "observability_logLevelPicker") }
    var logModulePicker: XCUIElement { app.element(id: "observability_logModulePicker") }
    var logList: XCUIElement { app.element(id: "observability_logList") }

    // MARK: - Tab Names (match ObservabilityView.Tab.rawValue)

    static let tabs = ["Logs", "Errors", "Performance", "Traces", "Health"]

    // MARK: - Actions

    func selectTab(_ tabName: String) {
        // Use type-agnostic lookup since macOS Picker segments can be buttons, radioButtons, etc.
        let tabId = "observability_tab_\(tabName.lowercased())"
        let tab = app.element(id: tabId)
        XCTAssertTrue(tab.waitForExistence(timeout: 5),
                      "Observability tab '\(tabName)' not found")
        tab.tap()
    }

    // MARK: - Waits

    func waitForLoad(timeout: TimeInterval = 5) {
        _ = container.waitForExistence(timeout: timeout)
    }
}
