import XCTest
@testable import Engram

final class HygieneViewTests: XCTestCase {
    // The real score + check generation lives in the service handler and is
    // covered by EngramServiceCoreTests. These tests cover the view-side model:
    // how HygieneView renders a real EngramServiceHygieneResponse and the
    // remediation/confirmation copy.

    private func issue(
        kind: String,
        severity: String,
        message: String
    ) -> EngramServiceHygieneIssue {
        EngramServiceHygieneIssue(
            kind: kind,
            severity: severity,
            message: message,
            detail: nil,
            repo: nil,
            action: nil
        )
    }

    // MARK: - Score / issue rendering

    func testCleanResponseHasFullScoreAndNoIssues() {
        let response = EngramServiceHygieneResponse(issues: [], score: 100, checkedAt: "2026-06-14T00:00:00Z")
        XCTAssertEqual(response.score, 100)
        XCTAssertTrue(response.issues.isEmpty)
    }

    func testIssuesSplitBySeverity() {
        let issues = [
            issue(kind: "empty-sessions", severity: "warning", message: "3 empty session(s) clutter the index"),
            issue(kind: "pending-suggestions", severity: "info", message: "2 suggested parent link(s) awaiting review"),
            issue(kind: "orphans", severity: "warning", message: "1 orphaned session(s)"),
        ]
        let response = EngramServiceHygieneResponse(issues: issues, score: 89, checkedAt: "2026-06-14T00:00:00Z")

        XCTAssertEqual(response.issues.filter { $0.severity == "warning" }.count, 2)
        XCTAssertEqual(response.issues.filter { $0.severity == "info" }.count, 1)
        XCTAssertEqual(response.issues.filter { $0.severity == "error" }.count, 0)
    }

    func testErrorIssueDecodesIntoErrorSeverity() throws {
        // Graceful-degradation path: the handler emits a single severity:"error"
        // issue on read failure; the view routes it through its red-card section.
        let json = #"{"issues":[{"kind":"error","severity":"error","message":"Could not read database","detail":null,"repo":null,"action":null}],"score":0,"checkedAt":"2026-06-14T00:00:00Z"}"#
        let response = try JSONDecoder().decode(EngramServiceHygieneResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.issues.filter { $0.severity == "error" }.count, 1)
        XCTAssertEqual(response.score, 0)
    }

    // MARK: - Remediation confirmation model

    func testEmptySessionCountParsedFromIssueMessage() {
        let twelve = issue(kind: "empty-sessions", severity: "warning", message: "12 empty session(s) clutter the index")
        XCTAssertEqual(HygieneView.emptySessionCount(in: twelve), 12)

        let one = issue(kind: "empty-sessions", severity: "warning", message: "1 empty session(s) clutter the index")
        XCTAssertEqual(HygieneView.emptySessionCount(in: one), 1)
    }

    func testEmptySessionCountIsZeroWhenMessageHasNoLeadingNumber() {
        let weird = issue(kind: "empty-sessions", severity: "warning", message: "no leading number here")
        XCTAssertEqual(HygieneView.emptySessionCount(in: weird), 0)
    }

    func testHideResultToastPointsAtShowHiddenSessions() {
        let toast = HygieneView.hideResultToast(hiddenCount: 5)
        XCTAssertEqual(toast, "Hid 5 session(s) — view them under Sessions → Show hidden sessions")
    }

    func testHideResultToastHandlesZeroHidden() {
        // Race: another client hid them first; the count is informational.
        let toast = HygieneView.hideResultToast(hiddenCount: 0)
        XCTAssertTrue(toast.contains("0 session"))
        XCTAssertTrue(toast.contains("Show hidden sessions"))
    }
}
