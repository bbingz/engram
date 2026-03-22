import XCTest

struct AgentsScreen {
    let app: XCUIApplication

    // MARK: - Elements

    var container: XCUIElement { app.otherElements["agents_container"] }
    var list: XCUIElement { app.otherElements["agents_list"] }
    var emptyState: XCUIElement { app.otherElements["agents_emptyState"] }

    // MARK: - Waits

    func waitForLoad(timeout: TimeInterval = 5) {
        _ = container.waitForExistence(timeout: timeout)
    }
}
