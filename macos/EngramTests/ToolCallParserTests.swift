import XCTest
@testable import Engram

/// Locks parser behavior that the hot-path perf change (hoisting the three
/// result-name regexes to a precompiled static) must not alter (#1).
final class ToolCallParserTests: XCTestCase {

    func testParseToolCallExtractsName() {
        let parsed = ToolCallParser.parseToolCall("`Read`:\n{\"file\":\"a.txt\"}")
        XCTAssertEqual(parsed?.toolName, "Read")
        XCTAssertEqual(parsed?.parameters.first?.key, "file")
        XCTAssertEqual(parsed?.parameters.first?.value, "a.txt")
    }

    func testParseToolCallReturnsNilWithoutHeader() {
        XCTAssertNil(ToolCallParser.parseToolCall("no header here"))
    }

    func testParseToolResultRequiresSignal() {
        XCTAssertNil(ToolCallParser.parseToolResult("plain text, not a result"))
        XCTAssertNotNil(ToolCallParser.parseToolResult("tool_result\nok"))
    }

    func testResultToolNameFromResultFromPattern() {
        let parsed = ToolCallParser.parseToolResult("tool_result\nResult from `Bash`: done")
        XCTAssertEqual(parsed?.toolName, "Bash")
    }

    func testResultToolNameFromBacktickResultPattern() {
        let parsed = ToolCallParser.parseToolResult("tool_result\n`Grep` result: 3 matches")
        XCTAssertEqual(parsed?.toolName, "Grep")
    }

    func testResultToolNameFromOutputOfPattern() {
        let parsed = ToolCallParser.parseToolResult("tool_result\nOutput of Edit: patched")
        XCTAssertEqual(parsed?.toolName, "Edit")
    }

    func testResultToolNameIsCaseInsensitive() {
        // The precompiled patterns keep the `.caseInsensitive` option.
        let parsed = ToolCallParser.parseToolResult("tool_result\nresult from `Write`: saved")
        XCTAssertEqual(parsed?.toolName, "Write")
    }

    func testResultErrorDetection() {
        let parsed = ToolCallParser.parseToolResult("tool_result\nError: ENOENT")
        XCTAssertEqual(parsed?.isError, true)
    }

    /// Precompiling the regexes must not change results across repeated calls.
    func testRepeatedCallsAreStable() {
        for _ in 0..<50 {
            XCTAssertEqual(
                ToolCallParser.parseToolResult("tool_result\nResult from `Read`: x")?.toolName,
                "Read"
            )
        }
    }
}
