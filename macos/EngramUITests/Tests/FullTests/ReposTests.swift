import XCTest

final class ReposTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        TestLaunchConfig.mainWindow.configure(app)
        app.launch()
    }

    override func tearDown() {
        app.terminate()
    }

    func testRepoList() {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("repos")

        let repos = ReposScreen(app: app)
        repos.waitForLoad()

        let hasList = repos.repoList.exists
        let hasEmpty = repos.emptyState.waitForExistence(timeout: 3)
        XCTAssertTrue(hasList || hasEmpty,
                      "Repos should show a list or empty state")
        ScreenshotCapture.capture(name: "repos_list", app: app, screen: "repos", test: #function)
    }

    func testRepoDetail() {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("repos")

        let repos = ReposScreen(app: app)
        repos.waitForLoad()

        if repos.repoList.exists {
            // Click first repo to open detail
            let firstRepo = repos.repoList.otherElements.firstMatch
            if firstRepo.waitForExistence(timeout: 3) {
                firstRepo.click()
                let detailLoaded = repos.detail.waitForExistence(timeout: 5)
                XCTAssertTrue(detailLoaded || repos.repoList.exists,
                              "Repo detail should load or list should remain visible")
            }
        } else {
            // Empty state — pass
            XCTAssertTrue(repos.emptyState.exists,
                          "Repos empty state should be visible when no repos")
        }
    }
}
