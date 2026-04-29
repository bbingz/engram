import XCTest

final class SearchSmokeTests: XCTestCase {
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

    func testSearchInput() {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("search")

        let search = SearchScreen(app: app)
        search.waitForLoad()
        XCTAssertTrue(search.searchInput.waitForExistence(timeout: 5),
                      "Search input field should be visible")
    }

    func testSearchResults() {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("search")

        let search = SearchScreen(app: app)
        search.waitForLoad()

        search.search(query: "test")

        // Either results appear or we get an empty state
        let resultsAppeared = search.results.waitForExistence(timeout: 10)
        let emptyStateAppeared = search.emptyState.waitForExistence(timeout: 2)
        XCTAssertTrue(resultsAppeared || emptyStateAppeared,
                      "Either search results or empty state should appear after searching")
        ScreenshotCapture.capture(name: "search_results", app: app, screen: "search", test: #function)
    }
}
