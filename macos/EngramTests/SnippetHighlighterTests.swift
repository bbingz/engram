import XCTest
@testable import Engram

final class SnippetHighlighterTests: XCTestCase {
    /// `<mark>…</mark>` runs become strongly-emphasized; tags are removed.
    func testHighlightsMarkedRunsAndStripsTags() {
        let attr = SnippetHighlighter.attributed("foo <mark>bar</mark> baz")
        XCTAssertEqual(String(attr.characters), "foo bar baz")

        var emphasizedText = ""
        for run in attr.runs where run.inlinePresentationIntent == .stronglyEmphasized {
            emphasizedText += String(attr[run.range].characters)
        }
        XCTAssertEqual(emphasizedText, "bar")
    }

    /// Multiple matches in one snippet are each highlighted.
    func testHighlightsMultipleMarks() {
        let attr = SnippetHighlighter.attributed("…<mark>the</mark> x <mark>the</mark>…")
        XCTAssertEqual(String(attr.characters), "…the x the…")
        let marked = attr.runs
            .filter { $0.inlinePresentationIntent == .stronglyEmphasized }
            .map { String(attr[$0.range].characters) }
        XCTAssertEqual(marked, ["the", "the"])
    }

    /// Plain text with no markers is passed through verbatim, including real
    /// angle brackets (the old regex `<[^>]+>` would have eaten `<Int>`).
    func testPreservesNonMarkAngleBrackets() {
        let attr = SnippetHighlighter.attributed("uses Array<Int> here")
        XCTAssertEqual(String(attr.characters), "uses Array<Int> here")
        XCTAssertFalse(attr.runs.contains { $0.inlinePresentationIntent == .stronglyEmphasized })
    }

    /// A dangling `<mark>` without a close tag does not crash and keeps the text.
    func testUnterminatedMarkIsSafe() {
        let attr = SnippetHighlighter.attributed("start <mark>oops")
        XCTAssertEqual(String(attr.characters), "start oops")
    }

    func testEmptyString() {
        XCTAssertEqual(String(SnippetHighlighter.attributed("").characters), "")
    }
}
