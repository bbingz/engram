import XCTest

struct SkillsScreen {
    let app: XCUIApplication

    // MARK: - Elements

    var list: XCUIElement { app.otherElements["skills_list"] }
    var searchField: XCUIElement { app.otherElements["skills_search"] }
    var emptyState: XCUIElement { app.otherElements["skills_emptyState"] }

    // MARK: - Actions

    func search(query: String) {
        let field = searchField
        XCTAssertTrue(field.waitForExistence(timeout: 3),
                      "Skills search field not found")
        field.click()
        let textField = field.textFields.firstMatch
        if textField.exists {
            textField.click()
            textField.typeText(query)
        }
    }

    // MARK: - Waits

    func waitForLoad(timeout: TimeInterval = 5) {
        _ = list.waitForExistence(timeout: timeout)
    }
}
