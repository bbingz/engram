import XCTest

struct MemoryScreen {
    let app: XCUIApplication

    // MARK: - Elements

    var container: XCUIElement { app.element(id: "memory_container") }
    var searchField: XCUIElement { app.element(id: "memory_search") }
    var emptyState: XCUIElement { app.element(id: "memory_emptyState") }

    // MARK: - Actions

    func search(query: String) {
        let field = searchField
        XCTAssertTrue(field.waitForExistence(timeout: 3),
                      "Memory search field not found")
        field.click()
        // The text field is inside the search container
        let textField = field.textFields.firstMatch
        if textField.exists {
            textField.click()
            textField.typeText(query)
        }
    }

    // MARK: - Waits

    func waitForLoad(timeout: TimeInterval = 5) {
        _ = container.waitForExistence(timeout: timeout)
    }
}
