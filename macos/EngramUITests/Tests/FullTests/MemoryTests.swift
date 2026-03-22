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

        let hasContent = memory.container.exists
        let hasEmpty = memory.emptyState.waitForExistence(timeout: 3)
        XCTAssertTrue(hasContent || hasEmpty,
                      "Memory should show entries or empty state")
        ScreenshotCapture.capture(name: "memory_entries", app: app, screen: "memory", test: #function)
    }

    func testSearch() {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("memory")

        let memory = MemoryScreen(app: app)
        memory.waitForLoad()

        if memory.searchField.waitForExistence(timeout: 5) {
            memory.search(query: "test")
            // After searching, the page should still be visible
            XCTAssertTrue(memory.container.exists,
                          "Memory container should remain visible after searching")
        } else {
            // No search field — verify page loaded
            XCTAssertTrue(memory.container.exists || memory.emptyState.exists,
                          "Memory page should show content or empty state")
        }
    }
}
