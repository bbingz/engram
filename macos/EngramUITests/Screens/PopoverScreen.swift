import XCTest

struct PopoverScreen {
    let app: XCUIApplication

    // MARK: - Elements

    var container: XCUIElement { app.element(id: "popover_container") }
    var statsGrid: XCUIElement { app.element(id: "popover_statsGrid") }
    var recentActivity: XCUIElement { app.element(id: "popover_recentActivity") }

    // MARK: - Status Indicators

    var statusWeb: XCUIElement { app.element(id: "popover_status_web") }
    var statusMcp: XCUIElement { app.element(id: "popover_status_mcp") }
    var statusEmbedding: XCUIElement { app.element(id: "popover_status_embedding") }

    // MARK: - Waits

    func waitForLoad(timeout: TimeInterval = 5) {
        _ = container.waitForExistence(timeout: timeout)
    }
}
