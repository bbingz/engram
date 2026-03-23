import XCTest

struct TimelineScreen {
    let app: XCUIApplication

    // MARK: - Elements

    var container: XCUIElement { app.element(id: "timeline_container") }
    var emptyState: XCUIElement { app.element(id: "timeline_emptyState") }

    // MARK: - Waits

    func waitForLoad(timeout: TimeInterval = 5) {
        _ = container.waitForExistence(timeout: timeout)
    }
}
