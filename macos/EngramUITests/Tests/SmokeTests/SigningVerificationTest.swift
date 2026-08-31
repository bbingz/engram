import XCTest

final class SigningVerificationTest: XCTestCase {
    func testAppLaunches() throws {
        let app = XCUIApplication()
        TestLaunchConfig.mainWindow.configure(app)
        app.launch()
        XCTAssertTrue(app.exists)
    }
}
