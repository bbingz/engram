import XCTest

struct ActivityScreen {
    let app: XCUIApplication

    // MARK: - Elements

    var container: XCUIElement { app.otherElements["activity_container"] }
    var dailyChart: XCUIElement { app.otherElements["activity_dailyChart"] }
    var heatmap: XCUIElement { app.otherElements["activity_heatmap"] }

    // MARK: - Waits

    func waitForLoad(timeout: TimeInterval = 5) {
        _ = container.waitForExistence(timeout: timeout)
    }
}
