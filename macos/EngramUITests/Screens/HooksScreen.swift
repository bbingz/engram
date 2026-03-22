import XCTest

struct HooksScreen {
    let app: XCUIApplication

    // MARK: - Elements

    var list: XCUIElement { app.element(id: "hooks_list") }
    var emptyState: XCUIElement { app.element(id: "hooks_emptyState") }

    // MARK: - Waits

    func waitForLoad(timeout: TimeInterval = 5) {
        _ = list.waitForExistence(timeout: timeout)
    }
}
