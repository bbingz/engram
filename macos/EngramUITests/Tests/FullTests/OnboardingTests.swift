import XCTest

final class OnboardingTests: XCTestCase {
    func testForcedOnboardingLaunchesWithMockService() {
        continueAfterFailure = false
        let app = XCUIApplication()
        TestLaunchConfig.onboarding.configure(app)
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["onboarding_container"].waitForExistence(timeout: 10),
            "Explicit UI-test launch should present onboarding"
        )
        XCTAssertTrue(
            app.buttons["onboarding_getStarted"].waitForExistence(timeout: 3),
            "Welcome step should expose a stable Get Started control"
        )
    }
}
