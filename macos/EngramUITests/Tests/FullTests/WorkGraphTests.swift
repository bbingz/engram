import XCTest

final class WorkGraphTests: XCTestCase {
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

    func testGraphRenders() {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("workGraph")

        let graph = WorkGraphScreen(app: app)
        graph.waitForLoad()
        XCTAssertTrue(graph.container.exists,
                      "Work graph container should be visible")
        ScreenshotCapture.capture(name: "workGraph_render", app: app, screen: "workGraph", test: #function)
    }

    func testGraphInteraction() {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("workGraph")

        let graph = WorkGraphScreen(app: app)
        graph.waitForLoad()

        // Attempt to interact with the graph by clicking on it
        if graph.container.isHittable {
            graph.container.click()
        }

        // Graph should remain stable after interaction
        XCTAssertTrue(graph.container.exists,
                      "Work graph should remain visible after interaction")
    }
}
