import XCTest

struct AgentsScreen {
    let app: XCUIApplication

    // MARK: - Elements

    var container: XCUIElement { app.element(id: "agents_container") }
    var list: XCUIElement { app.element(id: "agents_list") }
    var emptyState: XCUIElement { app.element(id: "agents_emptyState") }

    // MARK: - Waits

    func waitForLoad(timeout: TimeInterval = 5) {
        _ = container.waitForExistence(timeout: timeout)
    }
}
