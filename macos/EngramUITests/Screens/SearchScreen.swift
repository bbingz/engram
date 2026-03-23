import XCTest

struct SearchScreen {
    let app: XCUIApplication

    // MARK: - Elements

    var container: XCUIElement { app.element(id: "search_container") }
    var searchInput: XCUIElement { app.element(id: "search_input") }
    var results: XCUIElement { app.element(id: "search_results") }
    var emptyState: XCUIElement { app.element(id: "search_emptyState") }
    var resultCount: XCUIElement { app.staticTexts["search_resultCount"] }

    // MARK: - Actions

    func search(query: String) {
        let container = searchInput
        XCTAssertTrue(container.waitForExistence(timeout: 3),
                      "Search input not found")
        // The identifier is on the wrapper — find the actual TextField inside
        let textField = container.textFields.firstMatch
        if textField.exists {
            textField.click()
            textField.typeText(query)
        } else {
            container.click()
            container.typeText(query)
        }
    }

    func clearSearch() {
        let container = searchInput
        if container.exists {
            let textField = container.textFields.firstMatch
            let target = textField.exists ? textField : container
            target.click()
            target.typeKey("a", modifierFlags: .command)
            target.typeKey(.delete, modifierFlags: [])
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
