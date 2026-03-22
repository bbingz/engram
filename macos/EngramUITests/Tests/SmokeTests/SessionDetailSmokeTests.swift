import XCTest

final class SessionDetailSmokeTests: XCTestCase {
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

    func testTranscriptRenders() {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("sessions")

        let sessions = SessionsScreen(app: app)
        sessions.waitForLoad()

        // Select the first session to open its detail view
        sessions.selectSession(at: 0)

        let detail = SessionDetailScreen(app: app)
        detail.waitForLoad()
        XCTAssertTrue(detail.transcript.waitForExistence(timeout: 10),
                      "Transcript should render after selecting a session")
        ScreenshotCapture.capture(name: "detail_transcript", app: app, screen: "detail", test: #function)
    }

    func testMetadataPanel() {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("sessions")

        let sessions = SessionsScreen(app: app)
        sessions.waitForLoad()

        sessions.selectSession(at: 0)

        let detail = SessionDetailScreen(app: app)
        detail.waitForLoad()

        // The toolbar contains metadata information
        XCTAssertTrue(detail.toolbar.waitForExistence(timeout: 5),
                      "Metadata toolbar should be visible in session detail view")
    }
}
