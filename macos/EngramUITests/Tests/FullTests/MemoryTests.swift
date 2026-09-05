import XCTest

final class MemoryTests: XCTestCase {
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

    func testEntryList() {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("memory")

        let memory = MemoryScreen(app: app)
        memory.waitForLoad()

        XCTAssertTrue(memory.failedState.waitForExistence(timeout: 5),
                      "The unavailable mock service should render the memory failure state")
        XCTAssertFalse(memory.emptyState.exists,
                       "A failed memory read must not masquerade as an empty file list")
        XCTAssertFalse(memory.insightsEmptyState.exists,
                       "A failed insights read must not masquerade as an empty insights list")
        ScreenshotCapture.capture(name: "memory_entries", app: app, screen: "memory", test: #function)
    }

    func testSearch() {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("memory")

        let memory = MemoryScreen(app: app)
        memory.waitForLoad()

        XCTAssertTrue(memory.searchField.waitForExistence(timeout: 5),
                      "Memory search should remain available while the service is unavailable")
        memory.search(query: "test")
        XCTAssertTrue(memory.failedState.exists,
                      "Searching must not replace the service failure with an empty state")
    }
}
