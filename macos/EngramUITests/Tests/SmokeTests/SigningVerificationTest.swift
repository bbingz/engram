import XCTest

final class SigningVerificationTest: XCTestCase {
    func testAppLaunches() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--test-mode"]
        app.launch()
        XCTAssertTrue(app.exists)
    }
}
