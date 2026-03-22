import XCTest

struct PopoverScreen {
    let app: XCUIApplication

    // MARK: - Elements

    var container: XCUIElement { app.otherElements["popover_container"] }
    var statsGrid: XCUIElement { app.otherElements["popover_statsGrid"] }
    var recentActivity: XCUIElement { app.otherElements["popover_recentActivity"] }

    // MARK: - Status Indicators

    var statusWeb: XCUIElement { app.otherElements["popover_status_web"] }
    var statusMcp: XCUIElement { app.otherElements["popover_status_mcp"] }
    var statusEmbedding: XCUIElement { app.otherElements["popover_status_embedding"] }

    // MARK: - Waits

    func waitForLoad(timeout: TimeInterval = 5) {
        _ = container.waitForExistence(timeout: timeout)
    }
}
