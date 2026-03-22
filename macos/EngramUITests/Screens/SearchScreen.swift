import XCTest

struct SearchScreen {
    let app: XCUIApplication

    // MARK: - Elements

    var container: XCUIElement { app.otherElements["search_container"] }
    var searchInput: XCUIElement { app.textFields["search_input"] }
    var results: XCUIElement { app.otherElements["search_results"] }
    var emptyState: XCUIElement { app.otherElements["search_emptyState"] }
    var resultCount: XCUIElement { app.staticTexts["search_resultCount"] }

    // MARK: - Actions

    func search(query: String) {
        let input = searchInput
        XCTAssertTrue(input.waitForExistence(timeout: 3),
                      "Search input not found")
        input.click()
        input.typeText(query)
    }

    func clearSearch() {
        let input = searchInput
        if input.exists {
            input.click()
            input.typeKey("a", modifierFlags: .command)
            input.typeKey(.delete, modifierFlags: [])
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
