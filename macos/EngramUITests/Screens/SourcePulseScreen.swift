import XCTest

struct SourcePulseScreen {
    let app: XCUIApplication

    // MARK: - Elements

    var container: XCUIElement { app.otherElements["sourcePulse_container"] }
    var statusGrid: XCUIElement { app.otherElements["sourcePulse_statusGrid"] }
    var emptyState: XCUIElement { app.otherElements["sourcePulse_emptyState"] }

    // MARK: - Waits

    func waitForLoad(timeout: TimeInterval = 5) {
        _ = container.waitForExistence(timeout: timeout)
    }
}
