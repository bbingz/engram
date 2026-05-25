import XCTest

final class ReposTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        FixtureAssertions.requireRowCount("git_repos")
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

        XCTAssertTrue(
            repos.repoList.waitForExistence(timeout: 3),
            "Repos fixture should render a non-empty repo list"
        )
        ScreenshotCapture.capture(name: "repos_list", app: app, screen: "repos", test: #function)
    }

    func testRepoDetail() {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("repos")

        let repos = ReposScreen(app: app)
        repos.waitForLoad()

        XCTAssertTrue(
            repos.repoList.waitForExistence(timeout: 3),
            "Repos fixture should render a non-empty repo list"
        )
        let firstRepo = repos.repoRows.firstMatch
        XCTAssertTrue(
            firstRepo.waitForExistence(timeout: 3),
            "Repos fixture should expose at least one selectable repo row"
        )
        firstRepo.click()
        XCTAssertTrue(
            repos.detailBackButton.waitForExistence(timeout: 5),
            "Repo detail should expose its back button after selecting a repo"
        )
    }
}
