import XCTest

struct SearchScreen {
    let app: XCUIApplication

    // MARK: - Elements

    var container: XCUIElement { app.element(id: "search_container") }
    var searchInput: XCUIElement { app.textFields["search_input"].firstMatch }
    var results: XCUIElement { app.element(id: "search_results") }
    var idleState: XCUIElement { app.element(id: "search_idle") }
    var tooShortState: XCUIElement { app.element(id: "search_tooShort") }
    var failedState: XCUIElement { app.element(id: "search_failed") }
    var noResultsState: XCUIElement { app.element(id: "search_noResults") }
    var resultCount: XCUIElement { app.staticTexts["search_resultCount"] }

    // MARK: - Actions

    func search(query: String) {
        let textField = searchInput
        XCTAssertTrue(textField.waitForExistence(timeout: 3),
                      "Search input not found")
        textField.click()
        textField.typeKey("a", modifierFlags: .command)
        textField.typeKey(.delete, modifierFlags: [])
        textField.typeText(query)
        XCTAssertEqual(textField.value as? String, query, "Search field must contain the requested query")
    }

    func result(containingText text: String) -> XCUIElement {
        results.element(containingText: text)
    }

    func clearSearch() {
        let textField = searchInput
        if textField.exists {
            textField.click()
            textField.typeKey("a", modifierFlags: .command)
            textField.typeKey(.delete, modifierFlags: [])
        }
    }

    // MARK: - Waits

    func waitForLoad(timeout: TimeInterval = 5) {
        _ = container.waitForExistence(timeout: timeout)
    }

    func waitForResults(timeout: TimeInterval = 10) {
        _ = results.waitForExistence(timeout: timeout)
    }
}
