import XCTest

struct ProjectsScreen {
    let app: XCUIApplication

    // MARK: - Elements

    var container: XCUIElement { app.element(id: "projects_container") }
    var projectList: XCUIElement { app.element(id: "projects_list") }
    var emptyState: XCUIElement { app.element(id: "projects_emptyState") }
    var advancedMigrationToolsToggle: XCUIElement { app.element(id: "projects_advancedMigrationTools") }
    var undoButton: XCUIElement { app.element(id: "projects_undoButton") }
    var selectToggle: XCUIElement { app.element(id: "projects_selectToggle") }
    var historyButton: XCUIElement { app.element(id: "projects_historyButton") }
    var batchMoveButton: XCUIElement { app.element(id: "projects_batchMoveButton") }

    // MARK: - Project Groups

    func group(at index: Int) -> XCUIElement {
        app.element(id: "projects_group_\(index)")
    }

    func checkbox(at index: Int) -> XCUIElement {
        app.element(id: "projects_checkbox_\(index)")
    }

    // MARK: - Waits

    func waitForLoad(timeout: TimeInterval = 5) {
        _ = container.waitForExistence(timeout: timeout)
    }

    func expandAdvancedMigrationTools(timeout: TimeInterval = 2) {
        if undoButton.exists { return }
        XCTAssertTrue(
            advancedMigrationToolsToggle.waitForExistence(timeout: timeout),
            "Projects page should expose the Advanced migration tools disclosure"
        )
        advancedMigrationToolsToggle.click()
    }
}
