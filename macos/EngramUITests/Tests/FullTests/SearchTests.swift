import XCTest

final class SearchTests: XCTestCase {
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

    func testNoResultsState() {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("search")

        let search = SearchScreen(app: app)
        search.waitForLoad()

        // Search for something that should not match any fixture data
        search.search(query: "zzz_nonexistent_query_xyz_12345")

        // A guaranteed miss must render the empty state, never silently pass
        // because the fixture happened to contain no clickable result.
        let emptyAppeared = search.noResultsState.waitForExistence(timeout: 10)
        let resultsAppeared = search.results.waitForExistence(timeout: 2)

        XCTAssertTrue(
            emptyAppeared,
            "Empty state should appear for a nonexistent term; failed=\(search.failedState.exists), "
                + "results=\(search.results.exists)"
        )
        XCTAssertTrue(app.text("No results").exists, "A miss must show the No results title")
        XCTAssertFalse(resultsAppeared, "Nonexistent term must not render result rows")
        ScreenshotCapture.capture(name: "search_empty", app: app, screen: "search", test: #function)
    }
}
