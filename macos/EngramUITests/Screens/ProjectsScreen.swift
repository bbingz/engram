import XCTest

struct ProjectsScreen {
    let app: XCUIApplication

    // MARK: - Elements

    var container: XCUIElement { app.element(id: "projects_container") }
    var projectList: XCUIElement { app.element(id: "projects_list") }
    var emptyState: XCUIElement { app.element(id: "projects_emptyState") }

    // MARK: - Project Groups

    func group(at index: Int) -> XCUIElement {
        app.element(id: "projects_group_\(index)")
    }

    // MARK: - Waits

    func waitForLoad(timeout: TimeInterval = 5) {
        _ = container.waitForExistence(timeout: timeout)
    }
}
