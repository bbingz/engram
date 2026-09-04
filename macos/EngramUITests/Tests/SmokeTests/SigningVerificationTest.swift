import XCTest

final class SigningVerificationTest: XCTestCase {
    func testAppLaunches() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        TestLaunchConfig.mainWindow.configure(app)
        app.launch()
        XCTAssertTrue(app.exists)
    }
}
