import XCTest

struct ReposScreen {
    let app: XCUIApplication

    // MARK: - Elements

    var repoList: XCUIElement { app.element(id: "repos_list") }
    var detail: XCUIElement { app.element(id: "repos_detail") }
    var emptyState: XCUIElement { app.element(id: "repos_emptyState") }

    // MARK: - Waits

    func waitForLoad(timeout: TimeInterval = 5) {
        _ = repoList.waitForExistence(timeout: timeout)
    }
}
