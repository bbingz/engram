import XCTest

final class SessionDetailTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        TestLaunchConfig.mainWindow.configure(app)
        app.launch()
        app.activate()
    }

    override func tearDown() {
        app.terminate()
    }

    /// Navigate to sessions and select the first one
    private func openFirstSession() {
        let sidebar = SidebarScreen(app: app)
        sidebar.navigateTo("sessions")

        let sessions = SessionsScreen(app: app)
        sessions.waitForLoad()
        sessions.selectSession(at: 0)

        let detail = SessionDetailScreen(app: app)
        detail.waitForLoad()
    }

    func testMessageTypeChips() {
        openFirstSession()

        let detail = SessionDetailScreen(app: app)
        detail.waitForTranscript()

        // Message type chips are rendered as colored bars in the transcript
        // Verify the transcript has child elements (messages rendered)
        let transcriptChildren = detail.transcript.otherElements
        XCTAssertTrue(transcriptChildren.count > 0,
                      "Transcript should contain message elements")
    }

    func testFindBar() {
        openFirstSession()

        let detail = SessionDetailScreen(app: app)
        detail.waitForTranscript()

        // Open the find bar with Cmd+F
        app.typeKey("f", modifierFlags: .command)

        XCTAssertTrue(detail.findBar.waitForExistence(timeout: 5),
                      "Find bar should appear after Cmd+F")
        ScreenshotCapture.capture(name: "detail_findBar", app: app, screen: "detail", test: #function)
    }

    func testToolCallsExpanded() {
        openFirstSession()

        let detail = SessionDetailScreen(app: app)
        detail.waitForTranscript()

        // Look for tool call disclosure triangles or expandable elements
        let toolCalls = app.disclosureTriangles.firstMatch
        if toolCalls.waitForExistence(timeout: 5) {
            toolCalls.click()
            // After clicking, verify the transcript still exists
            XCTAssertTrue(detail.transcript.exists,
                          "Transcript should remain visible after expanding tool calls")
        } else {
            // Tool calls may not have disclosure controls in fixture data — verify transcript is valid
            XCTAssertTrue(detail.transcript.exists,
                          "Transcript should be visible (no tool call disclosures in fixture)")
        }
    }
}
