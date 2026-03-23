import XCTest

struct HooksScreen {
    let app: XCUIApplication

    // MARK: - Elements

    var container: XCUIElement { app.element(id: "hooks_container") }
    var list: XCUIElement { app.element(id: "hooks_list") }
    var emptyState: XCUIElement { app.element(id: "hooks_emptyState") }

    // MARK: - Waits

    func waitForLoad(timeout: TimeInterval = 5) {
        _ = container.waitForExistence(timeout: timeout)
    }
}
