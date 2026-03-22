import XCTest

final class ObservabilityTests: XCTestCase {
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

    private func navigateToObservability() {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("observability")

        let obs = ObservabilityScreen(app: app)
        obs.waitForLoad()
    }

    func testLogStream() {
        navigateToObservability()

        let obs = ObservabilityScreen(app: app)
        obs.selectTab("Logs")

        XCTAssertTrue(obs.logStream.waitForExistence(timeout: 5),
                      "Log stream view should be visible")
        ScreenshotCapture.capture(name: "observability_logStream", app: app, screen: "observability", test: #function)
    }

    func testTraceExplorer() {
        navigateToObservability()

        let obs = ObservabilityScreen(app: app)
        obs.selectTab("Traces")

        XCTAssertTrue(obs.traceExplorer.waitForExistence(timeout: 5),
                      "Trace explorer view should be visible")
        ScreenshotCapture.capture(name: "observability_traceExplorer", app: app, screen: "observability", test: #function)
    }

    func testErrorDashboard() {
        navigateToObservability()

        let obs = ObservabilityScreen(app: app)
        obs.selectTab("Errors")

        XCTAssertTrue(obs.errorDashboard.waitForExistence(timeout: 5),
                      "Error dashboard view should be visible")
        ScreenshotCapture.capture(name: "observability_errorDashboard", app: app, screen: "observability", test: #function)
    }

    func testPerformanceCharts() {
        navigateToObservability()

        let obs = ObservabilityScreen(app: app)
        obs.selectTab("Performance")

        XCTAssertTrue(obs.performance.waitForExistence(timeout: 5),
                      "Performance charts should be visible")
        ScreenshotCapture.capture(name: "observability_performance", app: app, screen: "observability", test: #function)
    }

    func testSystemHealth() {
        navigateToObservability()

        let obs = ObservabilityScreen(app: app)
        obs.selectTab("Health")

        XCTAssertTrue(obs.health.waitForExistence(timeout: 5),
                      "System health view should be visible")
        ScreenshotCapture.capture(name: "observability_health", app: app, screen: "observability", test: #function)
    }
}
