import XCTest

struct PopoverScreen {
    let app: XCUIApplication

    // MARK: - Elements

    var container: XCUIElement { app.element(id: "popover_container") }
    var recentActivity: XCUIElement { app.element(id: "popover_recentActivity") }

    // MARK: - Waits

    func waitForLoad(timeout: TimeInterval = 5) {
        _ = container.waitForExistence(timeout: timeout)
    }
}
