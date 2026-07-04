import XCTest
@testable import Engram

final class TranscriptLabelAndCopyTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // #4: tool rows surface the concrete tool name instead of "TOOL CALL #N".
    func testToolCallLabelShowsToolName() {
        let label = ColorBarMessageView.displayLabel(
            for: .toolCall, typeIndex: 2, content: "`Read`:\n{\"file\":\"a.txt\"}"
        )
        XCTAssertEqual(label, "TOOL: Read #2")
    }

    func testNonToolLabelFallsBackToTypeLabel() {
        XCTAssertEqual(
            ColorBarMessageView.displayLabel(for: .assistant, typeIndex: 1, content: "hi"),
            "ASSISTANT #1"
        )
    }

    func testUnparseableToolFallsBackToGenericLabel() {
        // No recognizable tool header -> keep the generic type label.
        XCTAssertEqual(
            ColorBarMessageView.displayLabel(for: .toolCall, typeIndex: 3, content: "no header here"),
            "TOOL CALL #3"
        )
    }

    // #0: header label from a pre-parsed tool name matches the parse-from-content
    // path, so the single-parse-per-row refactor keeps identical labels.
    func testHeaderLabelFromToolNameMatchesDisplayLabel() {
        XCTAssertEqual(
            ColorBarMessageView.headerLabel(for: .toolCall, typeIndex: 2, toolName: "Read"),
            ColorBarMessageView.displayLabel(for: .toolCall, typeIndex: 2, content: "`Read`:\n{}")
        )
        XCTAssertEqual(
            ColorBarMessageView.headerLabel(for: .toolCall, typeIndex: 2, toolName: "Read"),
            "TOOL: Read #2"
        )
        // Empty/nil tool name falls back to the generic type label.
        XCTAssertEqual(
            ColorBarMessageView.headerLabel(for: .assistant, typeIndex: 1, toolName: nil),
            "ASSISTANT #1"
        )
        XCTAssertEqual(
            ColorBarMessageView.headerLabel(for: .toolCall, typeIndex: 3, toolName: ""),
            "TOOL CALL #3"
        )
    }

    // #27: the memoized highlight computation still highlights every match.
    func testComputeHighlightMarksMatches() {
        let attr = ColorBarMessageView.computeHighlight("foo BAR foo", searchText: "foo")
        var matched = 0
        for run in attr.runs where run.backgroundColor == .yellow {
            matched += String(attr[run.range].characters).count > 0 ? 1 : 0
        }
        XCTAssertEqual(matched, 2, "case-insensitive scan should highlight both 'foo' matches")
    }

    func testComputeHighlightEmptyQueryReturnsPlain() {
        let attr = ColorBarMessageView.computeHighlight("foo", searchText: "")
        for run in attr.runs {
            XCTAssertNil(run.backgroundColor)
        }
    }

    // #5: "Copy Entire Conversation" has one testable source of truth.
    func testConversationTextJoinsRowsWithRolePrefixes() {
        let msgs = [
            IndexedMessage(message: ChatMessage(role: "user", content: "hello", systemCategory: .none),
                           messageType: .user, typeIndex: 1),
            IndexedMessage(message: ChatMessage(role: "assistant", content: "world", systemCategory: .none),
                           messageType: .assistant, typeIndex: 1)
        ]
        XCTAssertEqual(TranscriptText.conversationText(msgs), "> hello\n\nworld")
    }

    func testCopyEntireConversationUsesAllLoadedRowsNotFilteredDisplayRows() throws {
        let sessionDetail = try source("macos/Engram/Views/SessionDetailView.swift")
        XCTAssertTrue(
            sessionDetail.contains("TranscriptText.conversationText(indexedMessages)"),
            "Copy Entire Conversation must use all loaded transcript rows, not the current filtered display subset"
        )
        XCTAssertFalse(
            sessionDetail.contains("TranscriptText.conversationText(displayIndexed)"),
            "Copy Entire Conversation must not copy only the currently visible filtered rows"
        )
    }
}
