import XCTest

struct ReposScreen {
    let app: XCUIApplication

    // MARK: - Elements

    var container: XCUIElement { app.element(id: "repos_container") }
    var repoList: XCUIElement { app.element(id: "repos_list") }
    var repoRows: XCUIElementQuery { app.buttons.matching(identifier: "repos_row") }
    var detail: XCUIElement { app.element(id: "repos_detail") }
    var detailBackButton: XCUIElement { app.buttons["repos_detail_back"] }
    var emptyState: XCUIElement { app.element(id: "repos_emptyState") }

    // MARK: - Waits

    func waitForLoad(timeout: TimeInterval = 5) {
        _ = container.waitForExistence(timeout: timeout)
    }
}
