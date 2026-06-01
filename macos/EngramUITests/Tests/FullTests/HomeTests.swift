import XCTest

final class HomeTests: XCTestCase {
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

    func testTodayHeader() {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("home")

        let home = HomeScreen(app: app)
        home.waitForLoad()
        XCTAssertTrue(home.todayHeader.waitForExistence(timeout: 5),
                      "Today header should be visible on the home page")
        ScreenshotCapture.capture(name: "home_todayHeader", app: app, screen: "home", test: #function)
    }

    func testFollowUps() {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("home")

        let home = HomeScreen(app: app)
        home.waitForLoad()
        XCTAssertTrue(home.followUps.waitForExistence(timeout: 5),
                      "Follow-ups section should be visible on the home page")
        ScreenshotCapture.capture(name: "home_followUps", app: app, screen: "home", test: #function)
    }

    func testChangedReposAndServiceState() {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("home")

        let home = HomeScreen(app: app)
        home.waitForLoad()
        XCTAssertTrue(home.changedRepos.waitForExistence(timeout: 5),
                      "Changed repos section should be visible on the home page")
        XCTAssertTrue(home.serviceState.waitForExistence(timeout: 5),
                      "Service state section should be visible on the home page")
        ScreenshotCapture.capture(name: "home_workbench", app: app, screen: "home", test: #function)
    }
}
