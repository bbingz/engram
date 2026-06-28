import XCTest
@testable import EngramCoreRead

/// Coverage for the deterministic human-instruction distillation that drives the
/// human-driven default filter and the instruction-first display. The CJK case is
/// the load-bearing one: short Chinese asks must NOT be dropped as noise.
final class InstructionExtractorTests: XCTestCase {
    /// Mirrors the SwiftIndexer.streamStats loop: shared `seen`, cap at max.
    private func extract(_ messages: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for m in messages {
            if out.count < InstructionExtractor.maxInstructions,
               let instruction = InstructionExtractor.distinctInstruction(from: m, seen: &seen) {
                out.append(instruction)
            }
        }
        return out
    }

    func testRejectsSlashAndCommandEnvelopes() {
        var seen = Set<String>()
        XCTAssertNil(InstructionExtractor.distinctInstruction(from: "/clear", seen: &seen))
        XCTAssertNil(InstructionExtractor.distinctInstruction(from: "<command-name>compact</command-name>", seen: &seen))
        XCTAssertNil(InstructionExtractor.distinctInstruction(from: "<local-command-stdout>done</local-command-stdout>", seen: &seen))
    }

    func testRejectsToolResultEnvelope() {
        var seen = Set<String>()
        XCTAssertNil(InstructionExtractor.distinctInstruction(from: "<tool_use_result>{...}</tool_use_result>", seen: &seen))
    }

    func testRejectsProbesAndMicroAcks() {
        var seen = Set<String>()
        let noise = ["ping", "PING", "ok", "Yes", "继续", "好的", "POLYCLI_HEALTH_OK",
                     "No tools. Review the diff and report only blocking issues"]
        for item in noise {
            XCTAssertNil(InstructionExtractor.distinctInstruction(from: item, seen: &seen), "should reject: \(item)")
        }
    }

    func testRejectsShortLatinTokens() {
        var seen = Set<String>()
        for token in ["y", "k", "no", "go", "fix"] {
            XCTAssertNil(InstructionExtractor.distinctInstruction(from: token, seen: &seen), "short latin token should reject: \(token)")
        }
    }

    /// The critical fix: a short non-Latin ask has no whitespace and few graphemes
    /// but must be KEPT (errs toward visible), not dropped by the short-token gate.
    func testKeepsShortCJKAsks() {
        var seen = Set<String>()
        XCTAssertEqual(InstructionExtractor.distinctInstruction(from: "改成深色模式", seen: &seen), "改成深色模式")
        XCTAssertEqual(InstructionExtractor.distinctInstruction(from: "修复登录bug", seen: &seen), "修复登录bug")
    }

    func testRejectsCompoundPoliteAcks() {
        var seen = Set<String>()
        for ack in ["好的，谢谢", "ok, thanks", "好的、收到", "yes, sure"] {
            XCTAssertNil(InstructionExtractor.distinctInstruction(from: ack, seen: &seen), "compound ack should reject: \(ack)")
        }
        // But a real ask with a leading ack segment is kept.
        XCTAssertNotNil(InstructionExtractor.distinctInstruction(from: "好的，帮我加一个深色模式", seen: &seen))
    }

    func testKeepsSubstantiveEnglishAsk() {
        var seen = Set<String>()
        XCTAssertEqual(InstructionExtractor.distinctInstruction(from: "Please refactor the parser", seen: &seen),
                       "Please refactor the parser")
    }

    func testDedupesRepeatedAsks() {
        let kept = extract(["continue", "continue", "继续", "Add a dark mode toggle", "Add a dark mode toggle"])
        XCTAssertEqual(kept, ["Add a dark mode toggle"])
    }

    func testCountsFiveDistinctAsks() {
        let asks = ["Add a login screen", "Fix the parser drift", "Write parity tests",
                    "Update the changelog", "Ship it to production"]
        XCTAssertEqual(extract(asks).count, 5)
    }

    func testCapsAtMaxInstructions() {
        let many = (0 ..< 40).map { "Distinct instruction number \($0) please do it" }
        XCTAssertEqual(extract(many).count, InstructionExtractor.maxInstructions)
    }

    func testTruncatesLongInstructionTo200Chars() {
        var seen = Set<String>()
        let long = String(repeating: "a", count: 500)
        XCTAssertEqual(InstructionExtractor.distinctInstruction(from: long, seen: &seen)?.count, 200)
    }

    func testRejectsEmptyAndWhitespace() {
        var seen = Set<String>()
        XCTAssertNil(InstructionExtractor.distinctInstruction(from: "", seen: &seen))
        XCTAssertNil(InstructionExtractor.distinctInstruction(from: "   \n  ", seen: &seen))
    }
}
