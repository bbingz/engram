import XCTest
@testable import Engram

final class TranscriptLabelAndCopyTests: XCTestCase {
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
}
