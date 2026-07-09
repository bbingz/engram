import XCTest
@testable import Engram

/// Regression for Orca comparative study bug 5: SessionDetailView collapsed
/// structured `EngramServiceError` values to `localizedDescription`, dropping
/// name/code and `retryPolicy` from user-facing summary/handoff failures.
///
/// Wave-6 task 2 / PR to be linked on merge.
final class ServiceErrorPresenterTests: XCTestCase {
    func testCommandFailedIncludesNameMessageAndRetryPolicy_repro() {
        let error = EngramServiceError.commandFailed(
            name: "SummaryUnavailable",
            message: "model timed out",
            retryPolicy: "wait",
            details: nil
        )
        let text = ServiceErrorPresenter.displayMessage(for: error)
        XCTAssertTrue(text.contains("SummaryUnavailable"), text)
        XCTAssertTrue(text.contains("model timed out"), text)
        XCTAssertTrue(text.contains("wait"), text)
        // Must not collapse to message-only (the pre-fix UI path).
        XCTAssertNotEqual(text, error.localizedDescription)
    }

    func testPlainErrorFallsBackToLocalizedDescription_repro() {
        struct PlainError: LocalizedError {
            var errorDescription: String? { "plain failure" }
        }
        XCTAssertEqual(
            ServiceErrorPresenter.displayMessage(for: PlainError()),
            "plain failure"
        )
    }

    func testServiceUnavailableIncludesCodeAndMessage() {
        let error = EngramServiceError.serviceUnavailable(message: "socket down")
        let text = ServiceErrorPresenter.displayMessage(for: error)
        XCTAssertEqual(text, "ServiceUnavailable: socket down")
    }
}
