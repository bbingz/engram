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

    func testSessionBoxCarriesSearchTerm_repro() throws {
        let notifications = try normalized("macos/Engram/AppNotifications.swift")
        XCTAssertTrue(notifications.contains("letsearchTerm:String?"))
        XCTAssertTrue(
            notifications.contains(
                "init(_session:Session,searchTerm:String?=nil,navigationId:UUID?=nil)"
            )
        )
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
            searchPage.contains("openNotification(for: session, searchTerm: query)"),
            "Search result opens must carry the active query into the transcript find bar"
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

    func testSameSessionSearchTermChangeReprimesFindWithoutChangingViewIdentity_repro() throws {
        let detail = try normalized("macos/Engram/Views/SessionDetailView.swift")
        let mainWindow = try normalized("macos/Engram/Views/MainWindowView.swift")

        XCTAssertTrue(detail.contains(".onChange(of:searchTerm)"))
        XCTAssertTrue(detail.contains("searchText=newSearchTerm??\"\""))
        XCTAssertTrue(detail.contains("showFind=(newSearchTerm?.isEmpty==false)"))
        XCTAssertFalse(detail.contains(".task(id:searchTerm)"))
        XCTAssertTrue(mainWindow.contains(".id(session.id)"))
        XCTAssertFalse(mainWindow.contains(".id(searchTerm)"))
    }

    func testTextModeRowsAnchorAndHighlight() throws {
        let detail = try normalized("macos/Engram/Views/SessionDetailView.swift")
        XCTAssertTrue(detail.contains(".id(msg.id)"))
        XCTAssertTrue(detail.contains("RawMessageRow(message:msg,searchText:findNeedle)"))
    }

    func testTextModeFindUsesTheSameAllMessageCollection_repro() throws {
        let detail = try normalized("macos/Engram/Views/SessionDetailView.swift")
        XCTAssertTrue(detail.contains("privatevarfindIndexedMessages:[IndexedMessage]"))
        XCTAssertTrue(detail.contains("viewMode==.text?indexedMessages:displayIndexed"))
        XCTAssertTrue(detail.contains("letsnapshot=findIndexedMessages"))
        XCTAssertTrue(detail.contains("letdisplayed=findIndexedMessages"))
        XCTAssertFalse(
            detail.contains("letsnapshot=displayIndexed"),
            "Text mode renders every message, so its match count cannot use session-filtered rows"
        )
    }

    func testParentTranscriptOffersChildSessionLoadMore_repro() throws {
        let detail = try source("macos/Engram/Views/SessionDetailView.swift")
        XCTAssertTrue(detail.contains("loadMoreChildSessions"))
        XCTAssertTrue(detail.contains("Button(\"Load more agent sessions\")"))
        XCTAssertTrue(detail.contains("let offset = childrenSessions.count"))
        XCTAssertTrue(detail.contains("offset: offset"))
    }

    func testChildLoadMoreDoesNotCancelParentRefresh_repro() throws {
        let detail = try source("macos/Engram/Views/SessionDetailView.swift")
        XCTAssertTrue(detail.contains("@State private var childLoadMoreTask"))
        XCTAssertTrue(detail.contains("@State private var childLoadMoreToken"))
        XCTAssertTrue(detail.contains("@State private var isLoadingParentInfo"))

        let start = try XCTUnwrap(detail.range(of: "private func loadMoreChildSessions()"))
        let end = try XCTUnwrap(
            detail.range(of: "private func removeRelated(", range: start.upperBound..<detail.endIndex)
        )
        let body = detail[start.lowerBound..<end.lowerBound]
        XCTAssertTrue(body.contains("!isLoadingParentInfo"))
        XCTAssertTrue(body.contains("childLoadMoreTask = Task.detached"))
        XCTAssertTrue(body.contains("currentLoadToken: childLoadMoreToken"))
        XCTAssertFalse(body.contains("parentInfoTask?.cancel()"))
        XCTAssertFalse(body.contains("parentInfoLoadSessionId = loadToken"))
    }

    func testFindBarReturnAdvances() throws {
        let bar = try source("macos/Engram/Views/Transcript/TranscriptFindBar.swift")
        XCTAssertTrue(bar.contains("onSubmit"))
        XCTAssertTrue(bar.contains("onNext"))
    }

    // MARK: - Round 4 AA30: structured/collapsed transcript find

    func testTranscriptFindShowsRawToolPreambleAndExpandsCollapsedRegions_repro() throws {
        let call = try source("macos/Engram/Views/Transcript/ToolCallView.swift")
        let result = try source("macos/Engram/Views/Transcript/ToolResultView.swift")

        XCTAssertTrue(call.contains("preambleSlice"),
                      "A raw-only tool match must expose a highlighted preamble slice")
        XCTAssertTrue(call.contains("value.range(of: needle"),
                      "An active match in a truncated tool parameter must expand it")
        XCTAssertTrue(result.contains("parsed.output.range(of: needle"),
                      "An active match in collapsed tool output must expand it")
    }

    func testTranscriptFindScansTheRenderedToolResultContent_repro() throws {
        let detail = try source("macos/Engram/Views/SessionDetailView.swift")
        XCTAssertTrue(detail.contains("findableContent(for: msg, query: q)"))
        XCTAssertTrue(detail.contains("ToolCallParser.parseToolResult(message.content)"))
        XCTAssertFalse(
            detail.contains("msg.message.content.lowercased().contains(query)"),
            "The match scan must not count wrapper text that structured rendering removes"
        )
    }

    func testVisibleFindUsesHighlightCaseInsensitiveRangeForUnicode_repro() throws {
        XCTAssertNotNil("Straße".range(of: "STRASSE", options: .caseInsensitive))
        XCTAssertNil("İstanbul".range(of: "istanbul", options: .caseInsensitive))

        let detail = try normalized("macos/Engram/Views/SessionDetailView.swift")
        let start = try XCTUnwrap(detail.range(of: "privatefuncupdateMatchIndicesDebounced()async{"))
        let end = try XCTUnwrap(detail.range(of: "//MARK:-Body", range: start.upperBound..<detail.endIndex))
        let scan = String(detail[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(scan.contains("range(of:rawQuery,options:.caseInsensitive)!=nil"))
        XCTAssertFalse(
            scan.contains("lowercased().contains(query)"),
            "visible find must use the exact same Unicode matching semantics as hidden matches and highlights"
        )
    }

    func testReplacementFindScanKeepsOldResultsUntilCurrentIdentityCommits_repro() throws {
        let detail = try normalized("macos/Engram/Views/SessionDetailView.swift")
        let start = try XCTUnwrap(detail.range(of: "privatefuncupdateMatchIndicesDebounced()async{"))
        let end = try XCTUnwrap(detail.range(of: "//MARK:-Body", range: start.upperBound..<detail.endIndex))
        let scan = String(detail[start.lowerBound..<end.lowerBound])
        let priorMatch = try XCTUnwrap(scan.range(of: "letpreviousMatchedMessageID"))
        let sleep = try XCTUnwrap(scan.range(of: "Task.sleep", range: priorMatch.upperBound..<scan.endIndex))
        let debounce = String(scan[priorMatch.lowerBound..<sleep.lowerBound])

        XCTAssertFalse(debounce.contains("matchIndices=[]"))
        XCTAssertFalse(debounce.contains("hiddenMatchBuckets=[]"))
        XCTAssertFalse(debounce.contains("currentMatchIndex=-1"))
        XCTAssertTrue(scan.contains("letscanToken=matchScanToken"))
        XCTAssertTrue(scan.contains("guard!Task.isCancelled,scanToken==matchScanTokenelse{return}"))
        XCTAssertTrue(scan.contains("letqueryChanged=rawQuery!=committedFindQuery"))
        XCTAssertTrue(scan.contains("committedFindQuery=rawQuery"))
        XCTAssertTrue(detail.contains(#"\(session.id)\u{1}\(displayVersion)"#))

        let changeStart = try XCTUnwrap(detail.range(of: ".onChange(of:searchText)"))
        let changeEnd = try XCTUnwrap(
            detail.range(of: ".task(id:matchScanToken)", range: changeStart.upperBound..<detail.endIndex)
        )
        let change = String(detail[changeStart.lowerBound..<changeEnd.lowerBound])
        XCTAssertFalse(change.contains("currentMatchIndex=-1"))
        XCTAssertFalse(change.contains("committedFindMatchMessageID=nil"))
    }

    func testTranscriptFindRebindsCurrentMatchByMessageIdentity_repro() throws {
        let detail = try source("macos/Engram/Views/SessionDetailView.swift")
        XCTAssertTrue(detail.contains("currentFindMatchMessageID"))
        XCTAssertTrue(detail.contains("reboundFindMatchIndex"))
        XCTAssertTrue(detail.contains("snapshot[messageIndex].id == previousMatchedMessageID"))
    }

    func testTranscriptFindRebindsFromLastCommittedMessageIdentity_repro() {
        let earlier = indexed(content: "earlier needle", type: .user)
        let retained = indexed(content: "retained needle", type: .assistant)
        let later = indexed(content: "later needle", type: .assistant)
        let rebuilt = [earlier, retained, later]

        XCTAssertEqual(
            SessionDetailView.reboundFindMatchIndex(
                previousMessageID: retained.id,
                indices: [0, 1, 2],
                snapshot: rebuilt
            ),
            1
        )
        XCTAssertNotEqual(rebuilt[0].id, retained.id)
    }

    func testTextModeFindScansRawContentWhileSessionModeScansRenderedToolResult_repro() {
        let toolResult = indexed(
            content: "tool_result\nvisible output",
            type: .toolResult
        )

        XCTAssertEqual(
            SessionDetailView.findContent(for: toolResult, viewMode: .text),
            "tool_result\nvisible output"
        )
        XCTAssertEqual(
            SessionDetailView.findContent(for: toolResult, viewMode: .session),
            "visible output"
        )
    }

    func testToolParametersStartAfterMatchedHeader_repro() {
        let parsed = ToolCallParser.parseToolCall("prose mentions `Read` before the header\n`Read`:\npath: needle.txt")

        XCTAssertEqual(parsed?.toolName, "Read")
        XCTAssertEqual(parsed?.parameters.map(\.key), ["path"])
        XCTAssertEqual(parsed?.parameters.first?.value, "needle.txt")
    }

    func testToolFindExposesSameLineHeaderRemainderAndUnparsedBody_repro() throws {
        let parsed = try XCTUnwrap(ToolCallParser.parseToolCall(
            "`Read`: /a/needle.swift\n\n`Read`: /b/other.swift"
        ))
        XCTAssertTrue(parsed.parameters.contains { $0.value == "/a/needle.swift" })

        let unparsed = try XCTUnwrap(ToolCallParser.parseToolCall(
            "`Read`:\nunstructured needle phrase\npath: /b/other.swift"
        ))
        XCTAssertTrue(unparsed.parameters.contains { $0.key == "path" && $0.value == "/b/other.swift" })
        XCTAssertEqual(
            ToolCallView.renderedRemainder(parsed: unparsed, searchText: "needle phrase"),
            "unstructured needle phrase"
        )
    }

    func testToolCallParserSupportsLegacyBareParenHeaderAfterProse_repro() {
        let legacy = ToolCallParser.parseToolCall(
            "prose only mentions `Read` here\n`Read(\npath: legacy-needle.txt\n)"
        )
        let bareLegacy = ToolCallParser.parseToolCall(
            "prose only mentions `Read` here\nRead(\npath: bare-legacy-needle.txt\n)"
        )
        let colon = ToolCallParser.parseToolCall(
            "prose only mentions `Read` here\n`Read`:\npath: colon-needle.txt"
        )

        XCTAssertEqual(legacy?.toolName, "Read")
        XCTAssertEqual(legacy?.parameters.map(\.key), ["path"])
        XCTAssertEqual(legacy?.parameters.first?.value, "legacy-needle.txt")
        XCTAssertEqual(bareLegacy?.toolName, "Read")
        XCTAssertEqual(bareLegacy?.parameters.first?.value, "bare-legacy-needle.txt")
        XCTAssertEqual(colon?.toolName, "Read")
        XCTAssertEqual(colon?.parameters.map(\.key), ["path"])
        XCTAssertNil(ToolCallParser.parseToolCall("prose only mentions `Read` here"))
    }

    func testToolCallParserCarriesExactRawOnlyPreambleForAcceptedHeaders_repro() throws {
        let cases = [
            ("alpha raw-only needle\n`Read`:\n", "alpha raw-only needle"),
            ("beta raw-only needle\n`Read(\n", "beta raw-only needle"),
            ("gamma raw-only needle\nRead(\n", "gamma raw-only needle"),
        ]

        for (content, expectedPreamble) in cases {
            let parsed = try XCTUnwrap(ToolCallParser.parseToolCall(content))
            XCTAssertEqual(parsed.preamble, expectedPreamble)
            XCTAssertEqual(
                ToolCallView.renderedPreamble(parsed: parsed, searchText: "raw-only needle"),
                expectedPreamble
            )
        }
    }

    func testMultilineSystemFindPresentationExpandsAndHighlightsNeedleAfterFirstLine_repro() {
        let content = "System reminder\nKeep the needle visible\nFinal line"
        let presentation = CollapsibleSystemBubble.findPresentation(
            content: content,
            searchText: "needle",
            isManuallyExpanded: false
        )

        XCTAssertTrue(presentation.isExpanded)
        XCTAssertEqual(presentation.highlightInput, content)
        XCTAssertNotNil(presentation.highlightInput?.range(of: "needle", options: .caseInsensitive))
    }

    func testWhitespacePaddedFindUsesOneTrimmedNeedleAcrossStructuredRows_repro() throws {
        XCTAssertEqual(ColorBarMessageView.normalizedFindNeedle("  needle \n"), "needle")

        let highlighted = ColorBarMessageView.highlightRendered(
            AttributedString("a needle value"),
            query: "needle "
        )
        XCTAssertNotEqual(highlighted, AttributedString("a needle value"))

        let system = CollapsibleSystemBubble.findPresentation(
            content: "needle in system",
            searchText: " needle ",
            isManuallyExpanded: false
        )
        XCTAssertTrue(system.isExpanded)

        let parsed = try XCTUnwrap(ToolCallParser.parseToolCall("needle preamble\n`Read`:\npath: /tmp/a"))
        XCTAssertEqual(
            ToolCallView.renderedPreamble(parsed: parsed, searchText: "needle "),
            "needle preamble"
        )
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

    func testFindCountsStructuredToolCallAndSystemRowsWithHighlights_repro() {
        let messages = [
            indexed(content: "`Read`:\n{\"file\":\"needle.txt\"}", type: .toolCall),
            indexed(content: "needle system payload", type: .system)
        ]
        let buckets = SessionDetailView.hiddenTypeMatchSummary(
            messages,
            query: "needle",
            typeVisibility: Self.defaultVisibility,
            showSystemPrompts: false,
            showAgentComm: false
        )
        XCTAssertEqual(buckets.map(\.label).sorted(), [MessageType.system.label, MessageType.toolCall.label].sorted())
        XCTAssertEqual(buckets.reduce(0) { $0 + $1.count }, 2)
    }

    func testHiddenToolResultMatchesRenderedOutputNotWrapperToken_repro() {
        let messages = [
            indexed(content: "tool_result\nactual needle", type: .toolResult)
        ]

        let wrapperBuckets = SessionDetailView.hiddenTypeMatchSummary(
            messages,
            query: "tool_result",
            typeVisibility: Self.defaultVisibility,
            showSystemPrompts: false,
            showAgentComm: false
        )
        let outputBuckets = SessionDetailView.hiddenTypeMatchSummary(
            messages,
            query: "actual needle",
            typeVisibility: Self.defaultVisibility,
            showSystemPrompts: false,
            showAgentComm: false
        )

        XCTAssertTrue(wrapperBuckets.isEmpty)
        XCTAssertEqual(outputBuckets.first?.revealKind, .typeVisibility(.toolResult))
        XCTAssertEqual(outputBuckets.first?.count, 1)
    }

    func testFailedToolResultUsesCleanedRenderedOutputForFind_repro() {
        let failed = indexed(
            content: "tool_result\nExit code: 1",
            type: .error
        )

        XCTAssertFalse(
            SessionDetailView.findContent(
                for: failed,
                viewMode: .session,
                query: "tool_result"
            ).localizedCaseInsensitiveContains("tool_result")
        )
        XCTAssertTrue(
            SessionDetailView.findContent(
                for: failed,
                viewMode: .session,
                query: "Exit code"
            ).localizedCaseInsensitiveContains("Exit code")
        )
        XCTAssertTrue(ColorBarMessageView.rendersParsedToolResult(failed))
    }

    func testGenericToolRoleUsesCleanedToolResultForFind_repro() {
        let result = indexed(content: "tool_result\nactual output", type: .tool)
        XCTAssertEqual(
            SessionDetailView.findContent(for: result, viewMode: .session, query: "actual"),
            "actual output"
        )
        XCTAssertTrue(ColorBarMessageView.rendersParsedToolResult(result))
    }

    func testGenericToolCallRoleUsesStructuredToolView_repro() throws {
        let source = try normalized("macos/Engram/Views/Transcript/ColorBarMessageView.swift")
        let bodyStart = try XCTUnwrap(source.range(of: "varbody:someView"))
        XCTAssertTrue(source[bodyStart.lowerBound...].contains("case.toolCall,.tool:"))
    }

    func testToolCallFindOnlyExposesTheRawSliceContainingTheNeedle_repro() {
        let parsed = ParsedToolCall(
            toolName: "Read",
            parameters: [(key: "path", value: "/tmp/x")],
            rawContent: "needle preamble\n`Read`:\npath: /tmp/x\nunrelated remainder",
            preamble: "needle preamble",
            remainder: "unrelated remainder"
        )

        XCTAssertEqual(
            ToolCallView.renderedPreamble(parsed: parsed, searchText: "needle"),
            "needle preamble"
        )
        XCTAssertNil(ToolCallView.renderedRemainder(parsed: parsed, searchText: "needle"))
    }

    func testToolCallFindDoesNotRepaintParsedParametersAsRemainder_repro() throws {
        let parsed = try XCTUnwrap(ToolCallParser.parseToolCall(
            "`Read`:\npath: /tmp/needle\nunstructured tail"
        ))
        XCTAssertNil(ToolCallView.renderedRemainder(parsed: parsed, searchText: "needle"))
        XCTAssertEqual(
            ToolCallView.renderedRemainder(parsed: parsed, searchText: "unstructured"),
            "unstructured tail"
        )
    }

    func testHeaderOnlyToolCallFindableContentDoesNotDuplicateHeader_repro() throws {
        let parsed = try XCTUnwrap(ToolCallParser.parseToolCall("`Read`:"))
        XCTAssertEqual(
            ToolCallView.findableContent(parsed: parsed, searchText: "Read"),
            "Read"
        )
    }

    func testWhitespacePaddingDoesNotResetFindNavigation_repro() throws {
        let detail = try normalized("macos/Engram/Views/SessionDetailView.swift")
        XCTAssertTrue(
            detail.contains(
                "ColorBarMessageView.normalizedFindNeedle(oldValue)" +
                    "!=ColorBarMessageView.normalizedFindNeedle(newValue)"
            )
        )
    }

    func testFavoriteReadUsesLiveGenerationToken_repro() throws {
        let detail = try source("macos/Engram/Views/SessionDetailView.swift")
        XCTAssertTrue(detail.contains("favoriteLoadGeneration"))
        XCTAssertTrue(detail.contains("generation == favoriteLoadGeneration"))
    }

    func testHiddenAgentCommunicationSystemRowsAreCounted_repro() {
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
        XCTAssertEqual(buckets, [
            SessionDetailView.HiddenMatchBucket(
                label: "Agent Comm",
                revealKind: .agentComm,
                count: 1
            )
        ])
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

    func testHiddenMatchSummaryRunsOutsideMainActor_repro() async {
        let count = await Task.detached {
            let hiddenMessage = IndexedMessage(
                message: ChatMessage(
                    role: "assistant",
                    content: "needle",
                    systemCategory: .none
                ),
                messageType: .tool,
                typeIndex: 1
            )
            return SessionDetailView.hiddenTypeMatchSummary(
                [hiddenMessage],
                query: "needle",
                typeVisibility: [.tool: false],
                showSystemPrompts: false,
                showAgentComm: false
            ).count
        }.value

        XCTAssertEqual(count, 1)
    }
}
