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

    // rows 8+26 (transcript-find-rendering): user/assistant/code always take the
    // segmented path — including under active search — so find never flattens
    // rich rendering. Fails before usesSegmentedView exists / admits .user.
    func testUserMessagesUseSegmentedView_repro() {
        XCTAssertTrue(ColorBarMessageView.usesSegmentedView(for: .user))
        XCTAssertTrue(ColorBarMessageView.usesSegmentedView(for: .assistant))
        XCTAssertTrue(ColorBarMessageView.usesSegmentedView(for: .code))
        XCTAssertFalse(ColorBarMessageView.usesSegmentedView(for: .thinking))
        XCTAssertFalse(ColorBarMessageView.usesSegmentedView(for: .toolCall))
    }

    // row 26: highlight on rendered markdown (markers consumed), not raw source.
    // Template: SnippetHighlighterTests. Fails before highlightRendered exists.
    func testHighlightPaintsOnRenderedMarkdownNotRawSource_repro() {
        let rendered = try! AttributedString(
            markdown: "**bold**",
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        let result = ColorBarMessageView.highlightRendered(rendered, query: "bold")
        XCTAssertFalse(
            String(result.characters).contains("*"),
            "rendered characters must not reintroduce markdown markers"
        )
        var painted = ""
        for run in result.runs where run.backgroundColor == .yellow {
            painted += String(result[run.range].characters)
        }
        XCTAssertEqual(painted, "bold", "yellow background should cover the rendered 'bold' run")
    }

    /// Parse caches stay keyed on source text alone — re-keying on query would
    /// re-parse markdown every keystroke (row 26 acceptance).
    func testSegmentAndAttrCachesNotKeyedOnQuery() throws {
        let content = try source("macos/Engram/Views/ContentSegmentViews.swift")
        let normalized = content.filter { !$0.isWhitespace }
        // attrCache setObject uses text key; must not include searchText/query.
        XCTAssertTrue(normalized.contains("attrCache.setObject(CachedAttributedString(value:result),forKey:key,cost:text.utf16.count*2)"))
        XCTAssertTrue(normalized.contains("segmentCache.setObject(entry,forKey:NSString(string:content),cost:content.utf16.count*2)"))
        // Leaves accept searchText; highlight is layered after cache fetch.
        XCTAssertTrue(content.contains("var searchText: String = \"\""))
        XCTAssertTrue(content.contains("ColorBarMessageView.highlightRendered"))
        // No searchText.isEmpty fork left on ColorBarMessageView for segmented path.
        let colorBar = try source("macos/Engram/Views/Transcript/ColorBarMessageView.swift")
        XCTAssertFalse(
            colorBar.filter { !$0.isWhitespace }.contains("ifsearchText.isEmpty{SegmentedMessageView"),
            "search must not destroy segmented rendering via an isEmpty fork"
        )
        XCTAssertTrue(colorBar.contains("usesSegmentedView(for:"))
        XCTAssertTrue(colorBar.contains("SegmentedMessageView(content: indexed.message.content, searchText: searchText)"))
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
