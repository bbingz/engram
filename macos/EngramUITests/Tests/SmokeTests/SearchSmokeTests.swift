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

    func testSearchResults_repro() throws {
        let fixturePath = try XCTUnwrap(TestLaunchConfig.bundledFixtureDBPath)
        XCTAssertEqual(
            try sqliteScalar(path: fixturePath, sql: "SELECT COUNT(*) FROM sessions_fts;"),
            18,
            "The generated FTS rows must be present in the bundled UI-test database"
        )

        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("search")

        let search = SearchScreen(app: app)
        search.waitForLoad()

        search.search(query: "authentication")

        XCTAssertTrue(search.results.waitForExistence(timeout: 10))
        XCTAssertTrue(
            search.result(containingText: "Fixed authentication flow bug").exists,
            "The seeded authentication session should be returned from the fixture database; "
                + "failed=\(search.failedState.exists), empty=\(search.noResultsState.exists)"
        )
        XCTAssertFalse(search.failedState.exists)
        ScreenshotCapture.capture(name: "search_results", app: app, screen: "search", test: #function)
    }

    private func sqliteScalar(path: String, sql: String) throws -> Int {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        let immutableURI = URL(fileURLWithPath: path).absoluteString + "?immutable=1"
        process.arguments = [immutableURI, sql]
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let errorText = String(
            data: stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, errorText)
        let output = String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        return try XCTUnwrap(output.flatMap(Int.init))
    }
}
