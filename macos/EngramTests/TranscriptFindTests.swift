import XCTest
@testable import Engram

/// Locks the transcript find-bar contract: the index math behind auto-select +
/// restart-from-top, and the view-graph wirings (carrier + Return-advances +
/// Text-mode highlight) that can't be exercised headlessly in this target
/// (search-1, session-detail-transcript-1/-2/-3/-4/-6).
final class TranscriptFindTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func normalized(_ relativePath: String) throws -> String {
        try source(relativePath).filter { !$0.isWhitespace }
    }

    // MARK: - Pure index math

    func testAutoSelectsFirstMatchFromUnsetIndex() {
        // Restart-from-top: an unset (-1) index clamps to the first match.
        XCTAssertEqual(SessionDetailView.displayedFindMatchIndex(current: -1, count: 3), 0)
        // Return / Next wraps 0 -> 1 -> 2 -> 0.
        XCTAssertEqual(SessionDetailView.nextFindMatchIndex(current: 0, direction: 1, count: 3), 1)
        XCTAssertEqual(SessionDetailView.nextFindMatchIndex(current: 1, direction: 1, count: 3), 2)
        XCTAssertEqual(SessionDetailView.nextFindMatchIndex(current: 2, direction: 1, count: 3), 0)
    }

    func testResetIndexClampsToTop() {
        for n in 1...5 {
            XCTAssertEqual(SessionDetailView.displayedFindMatchIndex(current: -1, count: n), 0)
        }
        XCTAssertNil(SessionDetailView.displayedFindMatchIndex(current: -1, count: 0))
    }

    // MARK: - Source-contract assertions

    func testSessionBoxCarriesSearchTerm() throws {
        let notifications = try normalized("macos/Engram/AppNotifications.swift")
        XCTAssertTrue(notifications.contains("letsearchTerm:String?"))
        XCTAssertTrue(notifications.contains("init(_session:Session,searchTerm:String?=nil)"))
    }

    func testMainWindowPassesAndClearsSearchTerm() throws {
        let mainWindow = try source("macos/Engram/Views/MainWindowView.swift")
        XCTAssertTrue(mainWindow.contains("pendingSearchTerm"))
        XCTAssertTrue(mainWindow.contains("box.searchTerm"))
        XCTAssertTrue(mainWindow.contains("searchTerm: pendingSearchTerm"))
        let norm = try normalized("macos/Engram/Views/MainWindowView.swift")
        XCTAssertTrue(norm.contains("pendingSearchTerm=nil"))
    }

    func testSearchPageEmitsSearchTerm() throws {
        let searchPage = try source("macos/Engram/Views/Pages/SearchPageView.swift")
        XCTAssertTrue(
            searchPage.contains("SessionBox(session, searchTerm: query)"),
            "Search result taps must carry the active query into the transcript find bar"
        )
    }

    func testSessionDetailPrimesAndResetsFind() throws {
        let detail = try normalized("macos/Engram/Views/SessionDetailView.swift")
        // Prime the find bar from the search-driven open.
        XCTAssertTrue(detail.contains("searchText=searchTerm??\"\""))
        // Query edits restart navigation from the top.
        XCTAssertTrue(detail.contains(".onChange(of:searchText)"))
        XCTAssertTrue(detail.contains("currentMatchIndex=-1"))
        // Auto-select first match guarded so an in-progress Prev/Next isn't yanked.
        XCTAssertTrue(detail.contains("currentMatchIndex<0"))
        XCTAssertTrue(detail.contains("currentMatchIndex=0"))
    }

    func testTextModeRowsAnchorAndHighlight() throws {
        let detail = try normalized("macos/Engram/Views/SessionDetailView.swift")
        XCTAssertTrue(detail.contains(".id(msg.id)"))
        XCTAssertTrue(detail.contains("RawMessageRow(message:msg,searchText:searchText)"))
    }

    func testFindBarReturnAdvances() throws {
        let bar = try source("macos/Engram/Views/Transcript/TranscriptFindBar.swift")
        XCTAssertTrue(bar.contains("onSubmit"))
        XCTAssertTrue(bar.contains("onNext"))
    }

    // MARK: - Row 10: honest hidden-type match count

    /// Default visibility shows only user + assistant (all keys present, rest false).
    private static var defaultVisibility: [MessageType: Bool] {
        Dictionary(uniqueKeysWithValues: MessageType.allCases.map { type in
            (type, type == .user || type == .assistant)
        })
    }

    private func indexed(
        content: String,
        category: SystemCategory = .none,
        type: MessageType
    ) -> IndexedMessage {
        IndexedMessage(
            message: ChatMessage(role: "assistant", content: content, systemCategory: category),
            messageType: type,
            typeIndex: 1
        )
    }

    // row 10: a Tools-only match under default visibility must surface a hidden
    // bucket (not a flat "No matches"). Fails before hiddenTypeMatchSummary.
    func testFindReportsMatchesInHiddenTypes_repro() {
        let messages = [
            indexed(content: "hello user", type: .user),
            indexed(content: "secret-tool-token in tools", type: .tool)
        ]
        let buckets = SessionDetailView.hiddenTypeMatchSummary(
            messages,
            query: "secret-tool-token",
            typeVisibility: Self.defaultVisibility,
            showSystemPrompts: false,
            showAgentComm: false
        )
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets[0].revealKind, .typeVisibility(.tool))
        XCTAssertEqual(buckets[0].count, 1)
        XCTAssertEqual(buckets[0].label, MessageType.tool.label)
    }

    // B3: agentComm classifies as MessageType.system/toolCall but must bucket
    // under revealKind .agentComm, never .typeVisibility(.system).
    func testHiddenSystemMatchBucketsBySystemCategory_repro() {
        let messages = [
            indexed(content: "agent-comm-marker", category: .agentComm, type: .system)
        ]
        let buckets = SessionDetailView.hiddenTypeMatchSummary(
            messages,
            query: "agent-comm-marker",
            typeVisibility: Self.defaultVisibility,
            showSystemPrompts: false,
            showAgentComm: false
        )
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets[0].revealKind, .agentComm)
        XCTAssertNotEqual(buckets[0].revealKind, .typeVisibility(.system))
        XCTAssertEqual(buckets[0].label, "Agent Comm")
    }

    func testHiddenMatchRevealFlipsCorrectGate() {
        let toolMsg = indexed(content: "hidden-tool", type: .tool)
        let agentMsg = indexed(content: "hidden-agent", category: .agentComm, type: .system)
        var visibility = Self.defaultVisibility
        var showSystemPrompts = false
        var showAgentComm = false

        XCTAssertFalse(SessionDetailView.isMessageVisible(
            toolMsg, typeVisibility: visibility,
            showSystemPrompts: showSystemPrompts, showAgentComm: showAgentComm
        ))
        XCTAssertFalse(SessionDetailView.isMessageVisible(
            agentMsg, typeVisibility: visibility,
            showSystemPrompts: showSystemPrompts, showAgentComm: showAgentComm
        ))

        SessionDetailView.applyReveal(
            [.typeVisibility(.tool), .agentComm],
            typeVisibility: &visibility,
            showSystemPrompts: &showSystemPrompts,
            showAgentComm: &showAgentComm
        )

        XCTAssertTrue(visibility[.tool] == true)
        XCTAssertTrue(showAgentComm)
        XCTAssertFalse(showSystemPrompts, "agentComm reveal must not flip system prompts")
        XCTAssertTrue(SessionDetailView.isMessageVisible(
            toolMsg, typeVisibility: visibility,
            showSystemPrompts: showSystemPrompts, showAgentComm: showAgentComm
        ))
        XCTAssertTrue(SessionDetailView.isMessageVisible(
            agentMsg, typeVisibility: visibility,
            showSystemPrompts: showSystemPrompts, showAgentComm: showAgentComm
        ))
    }

    func testHiddenMatchBucketsEmptyWhenAllVisible() {
        let messages = [
            indexed(content: "hello visible", type: .user),
            indexed(content: "also visible", type: .assistant)
        ]
        let buckets = SessionDetailView.hiddenTypeMatchSummary(
            messages,
            query: "visible",
            typeVisibility: Self.defaultVisibility,
            showSystemPrompts: false,
            showAgentComm: false
        )
        XCTAssertTrue(buckets.isEmpty)
    }
}
