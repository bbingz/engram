import XCTest

struct ReposScreen {
    let app: XCUIApplication

    // MARK: - Elements

    var repoList: XCUIElement { app.otherElements["repos_list"] }
    var detail: XCUIElement { app.otherElements["repos_detail"] }
    var emptyState: XCUIElement { app.otherElements["repos_emptyState"] }

    // MARK: - Waits

    func waitForLoad(timeout: TimeInterval = 5) {
        _ = repoList.waitForExistence(timeout: timeout)
    }
}
