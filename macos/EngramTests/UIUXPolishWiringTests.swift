import XCTest
@testable import Engram

/// Source-contract greps for uiux-polish Parts B/C/D call-site wiring.
final class UIUXPolishWiringTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testLoadFailureBannersCarryRetryAction() throws {
        for path in [
            "macos/Engram/Views/Pages/SessionsPageView.swift",
            "macos/Engram/Views/Workspace/ReposView.swift",
            "macos/Engram/Views/Pages/SourcePulseView.swift",
            "macos/Engram/Views/Pages/TimelinePageView.swift",
        ] {
            let text = try source(path)
            XCTAssertTrue(
                text.contains("action: (\"Retry\""),
                "\(path) load-failure banner must pass Retry action"
            )
            XCTAssertTrue(
                text.contains("ServiceErrorPresenter.displayMessage(for: error)"),
                "\(path) catches must route through ServiceErrorPresenter"
            )
        }
    }

    func testSidebarNoLongerPinsMaxWidth160() throws {
        let sidebar = try source("macos/Engram/Views/SidebarView.swift")
        XCTAssertFalse(
            sidebar.contains("maxWidth: 160"),
            "sidebar must not hard-pin maxWidth: 160 once Dynamic Type scales width"
        )
        XCTAssertTrue(sidebar.contains("@ScaledMetric"))
        XCTAssertTrue(sidebar.contains("navigationSplitViewColumnWidth"))
        XCTAssertTrue(sidebar.contains("scaledFont"))
    }

    func testTranscriptBodyComposesScaledFontSize() throws {
        for path in [
            "macos/Engram/Views/Transcript/ColorBarMessageView.swift",
            "macos/Engram/Views/ContentSegmentViews.swift",
            "macos/Engram/Views/Transcript/ToolCallView.swift",
            "macos/Engram/Views/Transcript/ToolResultView.swift",
        ] {
            let text = try source(path)
            XCTAssertTrue(
                text.contains("Theme.scaledFontSize(base: fontSize"),
                "\(path) must compose Dynamic Type with contentFontSize"
            )
        }
    }

    /// The check above only proves each file mentions the scaled size somewhere.
    /// Assistant and code messages render through SegmentedMessageView, so the
    /// scaled value has to survive two more hops: the routing decision, and the
    /// argument each segment view is actually handed. Passing the raw `fontSize`
    /// to one segment would stop that segment scaling while every file-level
    /// assertion kept passing.
    func testSegmentedTranscriptPathCarriesScaledFontSizeToEverySegment() throws {
        let colorBar = try source("macos/Engram/Views/Transcript/ColorBarMessageView.swift")
        let routeStart = try XCTUnwrap(colorBar.range(of: "static func usesSegmentedView"))
        let routeEnd = try XCTUnwrap(
            colorBar.range(of: "}", range: routeStart.upperBound..<colorBar.endIndex)
        )
        let route = String(colorBar[routeStart.upperBound..<routeEnd.upperBound])
        for role in ["assistant", "code"] {
            XCTAssertTrue(
                route.contains(".\(role)"),
                "\(role) messages must route to SegmentedMessageView, which owns the scaling"
            )
        }

        let segments = try source("macos/Engram/Views/ContentSegmentViews.swift")
        let bodyStart = try XCTUnwrap(segments.range(of: "ForEach(Array(displaySegments.enumerated())"))
        let bodyEnd = try XCTUnwrap(
            segments.range(of: ".task(id: content)", range: bodyStart.upperBound..<segments.endIndex)
        )
        let body = String(segments[bodyStart.upperBound..<bodyEnd.lowerBound])
        XCTAssertFalse(
            body.contains("fontSize: fontSize"),
            "every segment view must be handed effectiveFontSize, not the unscaled fontSize"
        )
        XCTAssertEqual(
            body.components(separatedBy: "fontSize: effectiveFontSize").count - 1,
            body.components(separatedBy: "fontSize:").count - 1,
            "a segment view is being handed some other font size"
        )
    }

    // MARK: - Wave 6 wiring assertions

    /// Wave 6C-1: Sessions "HQ only" must filter in SQL (paginated page forbids
    /// client-side post-filter), and the toggle must be reloaded-triggering and
    /// clearable from the empty-state reset.
    func testSessionsHQOnlyFilterWiredThroughSQLAndClearFilters() throws {
        let db = try source("macos/Engram/Core/Database.swift")
        XCTAssertTrue(
            db.contains("if let origin {"),
            "appendSessionFilters must take the HQ origin filter (6C-1)"
        )
        XCTAssertTrue(db.contains("parts.append(\"AND origin = ?\")"))

        let view = try source("macos/Engram/Views/Pages/SessionsPageView.swift")
        XCTAssertTrue(view.contains("sessions_hqOnlyToggle"))
        XCTAssertTrue(view.contains("AnyHashable(hqOnly)"), "toggle must retrigger the load task")
        XCTAssertTrue(view.contains("hqOnly = false"), "Clear filters must reset HQ only")
        XCTAssertTrue(view.contains("origin: origin"), "listSessions call must pass origin")
    }

    /// Wave 6C-3 + merge-gate fix 1: action capability must follow real service
    /// capability. replayTimeline falls back to the indexed FTS timeline for
    /// remote:// rows (EngramServiceReadProvider step 3), so Replay stays
    /// enabled; TranscriptExportService reads the real transcript file, so
    /// Export must be disabled with honest help for remote snapshots.
    /// Behavior-first: real Session objects through the capability table.
    func testRemoteSnapshotActionCapabilityMatchesService_repro() throws {
        let remote = try makeSession(id: "remote:hq:abc")
        let local = try makeSession(id: "local-1")
        XCTAssertTrue(
            ExpandableSessionCard.canReplay(remote),
            "FTS fallback keeps Replay available for remote snapshots"
        )
        XCTAssertFalse(
            ExpandableSessionCard.canExport(remote),
            "exportSession reads the real transcript file; remote:// rows have none"
        )
        XCTAssertFalse(ExpandableSessionCard.canResumeLocally(remote))
        XCTAssertTrue(ExpandableSessionCard.canReplay(local))
        XCTAssertTrue(ExpandableSessionCard.canExport(local))
        XCTAssertTrue(ExpandableSessionCard.canResumeLocally(local))

        // Wiring supplement: both menus route resume-family actions and Export
        // through the table; no action keys off the raw property anymore.
        let card = try source("macos/Engram/Components/ExpandableSessionCard.swift")
        XCTAssertEqual(
            card.components(separatedBy: ".disabled(!ExpandableSessionCard.canResumeLocally(session))").count - 1,
            6,
            "Resume/Copy/Handoff in parent + child menus"
        )
        XCTAssertEqual(
            card.components(separatedBy: "exportAllowed: ExpandableSessionCard.canExport(session)").count - 1,
            2,
            "parent + child menus pass the export capability"
        )
        XCTAssertFalse(
            card.contains(".disabled(session.isRemoteSnapshot)"),
            "actions must not key off the raw property — the capability table is the contract"
        )
        XCTAssertTrue(card.contains("Only available on the HQ machine"))
    }

    /// Wave 6A-2: MemoryView must surface load failures through an AlertBanner
    /// with a Retry action, not an unactionable label.
    func testMemoryViewErrorBannerHasRetry() throws {
        let view = try source("macos/Engram/Views/Pages/MemoryView.swift")
        XCTAssertTrue(view.contains("AlertBanner(message: error, action: (\"Retry\""))
        XCTAssertTrue(view.contains("ServiceErrorPresenter.displayMessage(for: error)"))
    }

    /// Wave 6A-6: expanding/collapsing an agent-children card must announce the
    /// transition to VoiceOver.
    func testExpandableCardPostsAnnouncement() throws {
        let card = try source("macos/Engram/Components/ExpandableSessionCard.swift")
        XCTAssertTrue(
            card.contains("AccessibilityNotification.Announcement("),
            "expansion must post a VoiceOver announcement (6A-6)"
        )
        XCTAssertTrue(card.contains("agent sessions"))
    }

    /// Wave 6B-1: list-row vertical padding is one Theme token, not scattered
    /// magic numbers. Sessions rows render through ExpandableSessionCard, so the
    /// token has to live there; Memory rows own their padding directly.
    func testListRowPaddingUsesThemeToken() throws {
        let theme = try source("macos/Engram/Components/Theme.swift")
        XCTAssertTrue(theme.contains("static let listRowVerticalPadding"))
        for path in [
            "macos/Engram/Components/ExpandableSessionCard.swift",
            "macos/Engram/Components/LiveSessionCard.swift",
            "macos/Engram/Views/Pages/MemoryView.swift",
        ] {
            let text = try source(path)
            XCTAssertTrue(
                text.contains("Theme.listRowVerticalPadding"),
                "\(path) rows must use the shared padding token (6B-1)"
            )
        }
    }

    /// Wave 6A-5: search result rows must expose an accent focus ring so keyboard
    /// navigation is visible.
    func testSearchResultsCarryAccentFocusRing() throws {
        let view = try source("macos/Engram/Views/Pages/SearchPageView.swift")
        XCTAssertTrue(view.contains("focusedResultId"))
        XCTAssertTrue(view.contains(".focusable()"))
        XCTAssertTrue(view.contains(".focused($focusedResultId"))
    }

    /// Merge-gate residual 3b: search rows shipped focus+ring (6A-5) without
    /// activation — Enter/Space on a focused row did nothing. Keyboard must
    /// share the tap's open path (7-1 pattern: Enter and click open identically).
    func testSearchResultRowsActivateWithEnterOrSpace_repro() throws {
        let view = try source("macos/Engram/Views/Pages/SearchPageView.swift")
        XCTAssertTrue(
            view.contains(".onKeyPress(keys: [.return, .space])"),
            "focused search rows must activate with Enter/Space (7-1 pattern)"
        )
        XCTAssertTrue(
            view.contains("guard focusedResultId == result.id, let session = result.session"),
            "key handler must only fire for the focused row with a backing session"
        )
        XCTAssertEqual(
            view.components(separatedBy: "openNotification(for: session, searchTerm: query)").count - 1,
            2,
            "tap closure AND key handler must share one open path"
        )
    }

    /// Behavior half of residual 3b: the shared search open path must post
    /// .openSession carrying the row's session AND the live query, so tap and
    /// keyboard prime the transcript find bar identically.
    func testSearchOpenNotificationCarriesSessionBoxWithQuery_repro() throws {
        let session = try makeSession(id: "search-kb-open")
        let notification = SearchPageView.openNotification(for: session, searchTerm: "engram")
        XCTAssertEqual(notification.name, .openSession)
        let box = try XCTUnwrap(notification.object as? SessionBox)
        XCTAssertEqual(box.session.id, "search-kb-open")
        XCTAssertEqual(box.searchTerm, "engram")
    }

    // MARK: - Wave 7 wiring assertions

    /// Wave 6E-4: failed sheet writes must keep the attempt so the banner's
    /// Retry re-runs it without retyping.
    func testSheetsKeepFailedAttemptForRetry() throws {
        let alias = try source("macos/Engram/Views/Projects/AliasSheet.swift")
        XCTAssertTrue(alias.contains("failedAttempt = (action, input)"))
        XCTAssertTrue(alias.contains("failedAttempt = nil"), "success must clear the retry state")
        XCTAssertTrue(alias.contains("alias_errorBanner"))

        let batch = try source("macos/Engram/Views/Projects/BatchMoveSheet.swift")
        XCTAssertTrue(batch.contains("failedDryRun = effectiveDryRun"))
        XCTAssertTrue(batch.contains("failedDryRun = nil"), "run start/success must clear the retry state")
        XCTAssertTrue(batch.contains("batchMove_errorBanner"))
    }

    /// Wave 6E-10: the sessions action-status banner swaps text in place, which
    /// VoiceOver does not announce — the view must post the announcement itself.
    func testSessionsActionStatusAnnouncesOnChange() throws {
        let view = try source("macos/Engram/Views/Pages/SessionsPageView.swift")
        XCTAssertTrue(view.contains("AccessibilityNotification.Announcement(actionStatus).post()"))
        XCTAssertTrue(view.contains(".onChange(of: actionStatus)"))
    }

    /// Wave 6E-round2: the shared SectionHeader refresh button is icon-only and
    /// must name what it refreshes.
    func testSectionHeaderRefreshButtonIsLabeled() throws {
        let header = try source("macos/Engram/Components/SectionHeader.swift")
        XCTAssertTrue(header.contains(".accessibilityLabel(\"Refresh \\(title)\")"))
        XCTAssertTrue(header.contains(".help(\"Refresh \\(title)\")"))
    }

    /// Merge-gate residual 3c: the popover header gear is icon-only — without a
    /// label VoiceOver announces the SF Symbol name instead of the action.
    func testPopoverGearButtonIsLabeled_repro() throws {
        let view = try source("macos/Engram/Views/PopoverView.swift")
        XCTAssertTrue(
            view.contains(".accessibilityLabel(\"Open Settings\")"),
            "icon-only gear must name its action for VoiceOver"
        )
        XCTAssertTrue(
            view.contains(".help(\"Open Settings\")"),
            "icon-only gear must expose a tooltip naming the action"
        )
    }

    /// Wave 7-3/4/5: VoiceOver announcements for disclosure, onboarding steps,
    /// and completed searches.
    func testWave7AnnouncementsArePosted() throws {
        let hygiene = try source("macos/Engram/Views/Pages/HygieneView.swift")
        XCTAssertTrue(
            hygiene.contains("AccessibilityNotification.Announcement("),
            "IssueSection disclosure must announce expand/collapse (7-3)"
        )
        let onboarding = try source("macos/Engram/Onboarding/OnboardingView.swift")
        XCTAssertTrue(
            onboarding.contains("stepAnnouncementTitles"),
            "advance(to:) must announce the new step (7-4)"
        )
        let search = try source("macos/Engram/Views/Pages/SearchPageView.swift")
        XCTAssertTrue(
            search.contains("announceResults(count:"),
            "completed searches must announce the result count (7-5)"
        )
        XCTAssertEqual(
            search.components(separatedBy: "announceResults(count: results.count").count - 1,
            2,
            "service path AND offline fallback path must both announce"
        )
    }

    /// ui-residual-onboarding-cta-1: the primary CTA lived inside the step
    /// ScrollView, so at large Dynamic Type it scrolled away with the content.
    /// The CTA must be a fixed footer rendered after the ScrollView; actions,
    /// identifiers, sizes, and step announcements stay unchanged.
    func testOnboardingPrimaryCTAIsFixedFooter_repro() throws {
        let view = try source("macos/Engram/Onboarding/OnboardingView.swift")
        let ctaIDs = [
            "onboarding_getStarted",
            "onboarding_sourcesContinue",
            "onboarding_fdaContinue",
            "onboarding_mcpContinue",
            "onboarding_finish",
        ]
        for id in ctaIDs {
            XCTAssertTrue(view.contains(id), "\(id) must be preserved")
        }
        // Step content sections (rendered inside the ScrollView) must no longer
        // host the CTA — there it scrolls away at large Dynamic Type.
        for section in view.components(separatedBy: "// MARK: - Step ").dropFirst() {
            for id in ctaIDs {
                XCTAssertFalse(section.contains(id), "\(id) must leave step content for the fixed footer")
            }
        }
        // One fixed footer holds all five CTAs, rendered after the ScrollView.
        let bodyStart = try XCTUnwrap(view.range(of: "var body: some View"))
        let footerDef = try XCTUnwrap(
            view.range(of: "private var primaryCTA"),
            "a fixed primaryCTA footer must exist"
        )
        let body = view[bodyStart.lowerBound..<footerDef.lowerBound]
        let scrollIdx = try XCTUnwrap(body.range(of: "ScrollView {"), "step ScrollView must remain")
        let ctaRef = try XCTUnwrap(body.range(of: "primaryCTA"), "body must render the fixed footer")
        XCTAssertLessThan(scrollIdx.lowerBound, ctaRef.lowerBound, "footer must render after the step ScrollView")
        let stepOneMark = try XCTUnwrap(view.range(of: "// MARK: - Step 1"))
        let footer = view[footerDef.lowerBound..<stepOneMark.lowerBound]
        for id in ctaIDs {
            XCTAssertTrue(footer.contains(id), "fixed footer must host \(id)")
        }
    }

    /// Wave 7-1/10: list rows on the Sessions and Memory pages must be keyboard
    /// reachable — focus, visible ring, and Enter/Space activation (6A-5 pattern).
    func testListRowsAreKeyboardNavigable() throws {
        let sessions = try source("macos/Engram/Views/Pages/SessionsPageView.swift")
        XCTAssertTrue(sessions.contains("@FocusState private var focusedSessionId"))
        XCTAssertTrue(sessions.contains(".onKeyPress(keys: [.return, .space])"))
        XCTAssertTrue(sessions.contains("open(session)"), "Enter and tap must share one open path")

        let memory = try source("macos/Engram/Views/Pages/MemoryView.swift")
        XCTAssertTrue(memory.contains("@FocusState private var focusedRowId"))
        XCTAssertEqual(
            memory.components(separatedBy: ".onKeyPress(keys: [.return, .space])").count - 1,
            2,
            "insight rows AND file rows must both be keyboard-activatable"
        )
    }

    /// Wave 7-8: single-edit sheets must open with keyboard focus already in the
    /// editable control.
    func testSheetsAutoFocusEditableControl() throws {
        let sessions = try source("macos/Engram/Views/Pages/SessionsPageView.swift")
        XCTAssertTrue(sessions.contains(".focused($nameFocused)"), "RenameSessionSheet must autofocus (7-8)")
        let memory = try source("macos/Engram/Views/Pages/MemoryView.swift")
        XCTAssertTrue(memory.contains(".focused($editorFocused)"), "NewInsightSheet must autofocus (7-8)")
    }

    // MARK: - Wave 8 wiring assertions (UI-modifier supplements)

    /// W8-1: Timeline session rows need the same keyboard path as Sessions rows
    /// (7-1): focus, ring, Enter/Space, and one shared open path.
    func testTimelineRowsAreKeyboardNavigable() throws {
        let view = try source("macos/Engram/Views/Pages/TimelinePageView.swift")
        XCTAssertTrue(view.contains("@FocusState private var focusedSessionId"))
        XCTAssertTrue(view.contains(".onKeyPress(keys: [.return, .space])"))
        XCTAssertTrue(view.contains("open(session)"), "Enter and tap must share one open path")
    }

    /// W8-2: Agents session rows get the same treatment.
    func testAgentsRowsAreKeyboardNavigable() throws {
        let view = try source("macos/Engram/Views/Pages/AgentsView.swift")
        XCTAssertTrue(view.contains("@FocusState private var focusedSessionId"))
        XCTAssertTrue(view.contains(".onKeyPress(keys: [.return, .space])"))
        XCTAssertTrue(view.contains("open(session)"), "Enter and tap must share one open path")
    }

    /// W8-3: BarChart bars are individual text runs today; VoiceOver must get one
    /// summary element like HeatmapGrid already has.
    func testBarChartHasVoiceOverSummary() throws {
        let chart = try source("macos/Engram/Components/BarChart.swift")
        XCTAssertTrue(chart.contains(".accessibilityElement(children: .ignore)"))
        XCTAssertTrue(chart.contains(".accessibilityLabel("))
        XCTAssertTrue(chart.contains("accessibilitySummary(for:"))
    }

    /// W8-4: child rows were tap-gesture-only, so keyboard users could not open
    /// an expanded child at all. Focus is gated on `onTap` so rows rendered
    /// without a tap action stay out of the tab order.
    func testCompactChildRowIsKeyboardActivatable() throws {
        let card = try source("macos/Engram/Components/ExpandableSessionCard.swift")
        XCTAssertTrue(card.contains(".focusable(onTap != nil)"))
        XCTAssertTrue(card.contains(".focused($isFocused)"))
    }

    /// W8-5: replay transport buttons are icon-only; they must name themselves
    /// and the speed picker must be labeled.
    func testReplayTransportControlsAreLabeled() throws {
        let view = try source("macos/Engram/Views/Replay/SessionReplayView.swift")
        XCTAssertTrue(view.contains(".accessibilityLabel(\"Step back\")"))
        XCTAssertTrue(view.contains(".accessibilityLabel(\"Step forward\")"))
        XCTAssertTrue(view.contains("playPauseLabel(isPlaying:"))
        XCTAssertTrue(view.contains(".accessibilityLabel(\"Playback speed\")"))
    }

    /// W8-6: ProjectWorkTimeline rows are .plain buttons with no visible focus
    /// indicator; they need the ring + Enter/Space pattern.
    func testProjectWorkTimelineRowsHaveFocusRing() throws {
        let view = try source("macos/Engram/Components/ProjectWorkTimeline.swift")
        XCTAssertTrue(view.contains("@FocusState private var focusedItemId"))
        XCTAssertTrue(view.contains(".onKeyPress(keys: [.return, .space])"))
    }

    /// W8-7: LiveSessionCard is a .plain button (SourcePulse) with no ring.
    func testLiveSessionCardHasFocusRing() throws {
        let card = try source("macos/Engram/Components/LiveSessionCard.swift")
        XCTAssertTrue(card.contains("@FocusState private var isFocused"))
        XCTAssertTrue(card.contains(".focused($isFocused)"))
    }

    // MARK: - Wave 8 behavior tests (real state/interaction verification)

    /// Minimal Session via JSON decode (mirrors SessionModelTests usage).
    private func makeSession(id: String) throws -> Session {
        let data = """
        {
          "id": "\(id)",
          "source": "codex",
          "start_time": "2026-03-20T10:00:00Z",
          "cwd": "",
          "message_count": 1,
          "user_message_count": 1,
          "assistant_message_count": 0,
          "system_message_count": 0,
          "file_path": "/tmp/\(id).jsonl",
          "size_bytes": 1,
          "indexed_at": "2026-03-20T10:00:00Z",
          "tool_message_count": 0
        }
        """.data(using: .utf8)!
        return try JSONDecoder().decode(Session.self, from: data)
    }

    /// W8-1/W8-2: the open notification shared by tap and keyboard must carry
    /// the tapped session in a SessionBox on .openSession. Tested via the static
    /// builder so no service client (and no production socket) is involved.
    func testOpenNotificationCarriesSessionBox() throws {
        let session = try makeSession(id: "w8-open")
        for notification in [
            TimelinePageView.openNotification(for: session),
            AgentsView.openNotification(for: session),
        ] {
            XCTAssertEqual(notification.name, .openSession)
            let box = try XCTUnwrap(notification.object as? SessionBox)
            XCTAssertEqual(box.session.id, "w8-open")
        }
    }

    /// W8-3: the VoiceOver value must read every bar, and stay sensible empty.
    func testBarChartAccessibilitySummary() {
        let items = [
            BarChartItem(label: "Claude", value: 12, color: .blue),
            BarChartItem(label: "Codex", value: 3, color: .green),
        ]
        XCTAssertEqual(
            BarChart.accessibilitySummary(for: items),
            "Claude: 12, Codex: 3"
        )
        XCTAssertEqual(BarChart.accessibilitySummary(for: []), "No data")
    }

    // MARK: - Merge-gate fix 2 (sheet mutation double-click)

    /// The buttons' `disabled(isExecuting)` alone cannot stop a fast
    /// double-click: the flag used to be set inside the launched Task, so a
    /// second click created a second Task before the first one published it.
    /// The launch decision now happens synchronously at the button entry —
    /// the first click flips the flag, the second closure reads it and is
    /// dropped.
    func testSheetBeginMutationDropsDoubleEntry_repro() {
        var isExecuting = false
        XCTAssertTrue(
            AliasSheet.beginMutation(isExecuting: &isExecuting),
            "first click starts the mutation"
        )
        XCTAssertTrue(isExecuting, "the flag is set synchronously, before any Task exists")
        XCTAssertFalse(
            AliasSheet.beginMutation(isExecuting: &isExecuting),
            "double-click second entry must be dropped"
        )
        XCTAssertTrue(isExecuting, "a dropped entry must not disturb the running state")

        var batchExecuting = false
        XCTAssertTrue(BatchMoveSheet.beginMutation(isExecuting: &batchExecuting))
        XCTAssertFalse(
            BatchMoveSheet.beginMutation(isExecuting: &batchExecuting),
            "BatchMoveSheet double-click second entry must be dropped"
        )
    }

    /// The banner's Retry re-enters the same launch path, so the MainActor
    /// defer must release the flag after success AND failure — otherwise one
    /// failure would wedge the sheet behind a stuck flag.
    func testSheetBeginMutationAcceptsRetryAfterRelease_repro() {
        var isExecuting = false
        XCTAssertTrue(AliasSheet.beginMutation(isExecuting: &isExecuting), "first attempt runs")
        isExecuting = false  // defer releases on the failure path
        XCTAssertTrue(
            AliasSheet.beginMutation(isExecuting: &isExecuting),
            "retry after a failed attempt must run"
        )

        var batchExecuting = false
        XCTAssertTrue(BatchMoveSheet.beginMutation(isExecuting: &batchExecuting))
        batchExecuting = false
        XCTAssertTrue(
            BatchMoveSheet.beginMutation(isExecuting: &batchExecuting),
            "BatchMoveSheet retry after failure must run"
        )
    }

    /// Wiring supplement: every mutation launch site (main buttons AND the
    /// error banner's Retry) must pass through the synchronous guard.
    func testEveryMutationLaunchSiteIsGuarded() throws {
        let alias = try source("macos/Engram/Views/Projects/AliasSheet.swift")
        XCTAssertEqual(
            alias.components(separatedBy: "Self.beginMutation(isExecuting: &isExecuting)").count - 1,
            3,
            "Add + Remove + banner Retry must all guard"
        )
        let batch = try source("macos/Engram/Views/Projects/BatchMoveSheet.swift")
        XCTAssertEqual(
            batch.components(separatedBy: "Self.beginMutation(isExecuting: &isExecuting)").count - 1,
            4,
            "Preview + Move + Resume + banner Retry must all guard"
        )
    }

    /// Merge-gate fix 3: the banner's Retry must render disabled while a
    /// mutation runs — the beginMutation guard alone would silently drop the
    /// click with no visible feedback. Applied as a modifier OUTSIDE
    /// AlertBanner's public API (no component change).
    func testSheetRetryBannerVisiblyDisabledWhileExecuting() throws {
        let alias = try source("macos/Engram/Views/Projects/AliasSheet.swift")
        XCTAssertTrue(
            alias.contains(".accessibilityIdentifier(\"alias_errorBanner\")\n                    .disabled(isExecuting)"),
            "AliasSheet Retry banner must render disabled while isExecuting"
        )
        let batch = try source("macos/Engram/Views/Projects/BatchMoveSheet.swift")
        XCTAssertTrue(
            batch.contains(".accessibilityIdentifier(\"batchMove_errorBanner\")\n                    .disabled(isExecuting)"),
            "BatchMoveSheet Retry banner must render disabled while isExecuting"
        )
    }
}
