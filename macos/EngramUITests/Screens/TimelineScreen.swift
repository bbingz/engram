import XCTest

struct TimelineScreen {
    let app: XCUIApplication

    // MARK: - Elements

    var container: XCUIElement { app.element(id: "timeline_container") }
    var emptyState: XCUIElement { app.element(id: "timeline_emptyState") }
    var modePicker: XCUIElement { app.element(id: "timeline_modePicker") }
    var chart: XCUIElement { app.element(id: "timeline_chart") }

    func mode(named name: String) -> XCUIElement {
        modePicker.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", name))
            .firstMatch
    }

    // MARK: - Waits

    func waitForLoad(timeout: TimeInterval = 5) {
        _ = container.waitForExistence(timeout: timeout)
    }
}
