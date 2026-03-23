import XCTest

struct SessionDetailScreen {
    let app: XCUIApplication

    // MARK: - Elements

    var container: XCUIElement { app.element(id: "detail_container") }
    var transcript: XCUIElement { app.element(id: "detail_transcript") }
    var toolbar: XCUIElement { app.element(id: "detail_toolbar") }
    var findBar: XCUIElement { app.element(id: "detail_findBar") }

    // MARK: - Waits

    func waitForLoad(timeout: TimeInterval = 5) {
        _ = container.waitForExistence(timeout: timeout)
    }

    func waitForTranscript(timeout: TimeInterval = 10) {
        _ = transcript.waitForExistence(timeout: timeout)
    }
}
