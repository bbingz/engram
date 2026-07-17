import XCTest
@testable import EngramCoreRead

/// M23: Gemini sidecar parentSessionId must not write empty/self links.
final class GeminiSidecarParentValidationTests: XCTestCase {
    func testEmptySidecarParentRejected_repro() {
        XCTAssertNil(
            GeminiCliAdapter.validatedSidecarParentSessionId(sessionId: "child", raw: "")
        )
        XCTAssertNil(
            GeminiCliAdapter.validatedSidecarParentSessionId(sessionId: "child", raw: "   ")
        )
        XCTAssertNil(
            GeminiCliAdapter.validatedSidecarParentSessionId(sessionId: "child", raw: nil)
        )
    }

    func testSelfSidecarParentRejected_repro() {
        XCTAssertNil(
            GeminiCliAdapter.validatedSidecarParentSessionId(sessionId: "same", raw: "same")
        )
    }

    func testValidSidecarParentAccepted_repro() {
        XCTAssertEqual(
            GeminiCliAdapter.validatedSidecarParentSessionId(sessionId: "child", raw: "parent-1"),
            "parent-1"
        )
    }
}
