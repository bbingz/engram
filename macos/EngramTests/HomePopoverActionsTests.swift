import XCTest
@testable import Engram

/// Source-inspection guards (mirroring ViewMainThreadReadTests) for WP09: the
/// Home/Today dashboard and menu-bar popover wire-ups. SwiftUI bodies aren't
/// unit-instantiable here, so these lock the view wiring at the source level —
/// KPI/See-all/warning navigation, deleted Web UI affordances, the removed dead
/// embedding bindings, the indexing vs empty states, and the popover Live
/// section that must reuse the badge's exact active-session predicate.
final class HomePopoverActionsTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func homeView() throws -> String {
        try source("macos/Engram/Views/Pages/HomeView.swift")
    }

    private func popoverView() throws -> String {
        try source("macos/Engram/Views/PopoverView.swift")
    }

    private func menuBarController() throws -> String {
        try source("macos/Engram/MenuBarController.swift")
    }

    private func liveCard() throws -> String {
        try source("macos/Engram/Components/LiveSessionCard.swift")
    }

    // MARK: - HomeView KPI / See-all / Changed-Repos navigation

    func testHomeKpiCardsNavigate() throws {
        let s = try homeView()
        XCTAssertTrue(s.contains(".navigateToScreen"), "Home KPI/See-all must post .navigateToScreen")
        XCTAssertTrue(s.contains("navigate(to: .sessions)"), "Sessions KPI must navigate to .sessions")
        XCTAssertTrue(s.contains("navigate(to: .projects)"), "Projects KPI must navigate to .projects")
        XCTAssertTrue(s.contains("navigate(to: .settings)"), "Service KPI must navigate to .settings")
    }

    func testHomeSeeAllLinksGatedOnCount() throws {
        let s = try homeView()
        XCTAssertTrue(s.contains("trailingAction"), "overflow panels must pass a See-all trailingAction")
        XCTAssertTrue(
            s.contains("recentSessions.count > todayPanelRowLimit"),
            "Continue See-all must be gated on count > limit"
        )
        XCTAssertTrue(
            s.contains("projectGroups.count > 5"),
            "Changed Repos See-all must be gated on count > 5"
        )
    }

    func testHomeChangedRepoWarningNavigatesToProjects() throws {
        let s = try homeView()
        XCTAssertTrue(
            s.contains("onOpenWarning: { navigate(to: .projects) }"),
            "Changed Repos warning badge must navigate to the Projects page"
        )
    }

    func testHomeServiceStateDropsDeletedWebUiRow() throws {
        let s = try homeView()
        XCTAssertFalse(s.contains("openWebUI"), "Home must not expose the deleted Web UI action")
        XCTAssertFalse(s.contains("webEndpointLabel"), "Home must not format a deleted Web UI endpoint")
        XCTAssertFalse(s.contains("endpointPort"), "Home must not read deleted Web UI endpoint state")
        XCTAssertFalse(s.contains("\"Web UI\""), "Home service state must not render a deleted Web UI row")
    }

    // MARK: - HomeView dead-embedding removal + indexing state

    func testHomeRemovesDeadEmbeddingRow() throws {
        let s = try homeView()
        XCTAssertFalse(s.contains("embeddingStatus"), "HomeView must not bind the dead embeddingStatus field")
        XCTAssertFalse(s.contains("Check Advanced diagnostics"), "HomeView must drop the misleading embedding fallback")
        XCTAssertFalse(s.contains("\"Embeddings\""), "HomeView must remove the Embeddings ServiceStateRow")
    }

    func testHomeDistinguishesIndexingFromEmpty() throws {
        let s = try homeView()
        XCTAssertTrue(s.contains(".starting"), "Home must branch the empty states on the .starting status")
        XCTAssertTrue(s.contains("Indexing your sessions…"), "Home must show a distinct indexing placeholder")
    }

    // MARK: - PopoverView Live section + badge-consistent count

    func testPopoverLiveSectionUsesBadgePredicate() throws {
        let s = try popoverView()
        XCTAssertTrue(s.contains("serviceClient.liveSessions()"), "Popover must fetch live sessions")
        XCTAssertTrue(s.contains("LiveSessionCard"), "Popover Live section must render LiveSessionCard rows")
        XCTAssertTrue(
            s.contains("$0.activityLevel == \"active\""),
            "Popover live count must use the exact MenuBarController badge predicate"
        )
    }

    func testPopoverLiveSectionCapsAndFiltersCards() throws {
        let s = try popoverView()
        XCTAssertFalse(
            s.contains("ForEach(liveSessions)"),
            "Popover Live section must not render every live session unbounded"
        )
        XCTAssertTrue(
            s.contains("prefix(Self.liveSectionLimit)"),
            "Popover Live section must cap the rendered cards"
        )
        XCTAssertTrue(
            s.contains("$0.activityLevel == \"idle\""),
            "Popover Live section must keep only active/idle sessions (drop 24h 'recent' churn)"
        )
        XCTAssertTrue(
            s.contains("popover_liveOverflow"),
            "Popover Live section must surface overflow as a single affordance"
        )
    }

    func testPopoverLiveCardOpensSessionOffMainThread() throws {
        let s = try popoverView()
        XCTAssertTrue(s.contains("Task.detached"), "Popover live-card open must resolve getSession off the main thread")
        XCTAssertTrue(s.contains("db.getSession(id: id)"), "Popover live-card open must resolve via getSession")
        XCTAssertTrue(s.contains(".openWindow"), "Popover live-card open must post .openWindow")
    }

    // MARK: - PopoverView dead-embedding removal + states + usage empty

    func testPopoverRemovesDeadEmbeddingDot() throws {
        let s = try popoverView()
        XCTAssertFalse(s.contains("embeddingStatus"), "Popover must not bind the dead embeddingStatus field")
        XCTAssertFalse(s.contains("embeddingStatusView"), "Popover must remove the embedding status dot view")
    }

    func testPopoverTimelineHasDiscoverabilityAndEmptyStates() throws {
        let s = try popoverView()
        XCTAssertTrue(s.contains(".help(\"Open session\")"), "Popover timeline rows must expose an Open session tooltip")
        XCTAssertTrue(s.contains("Indexing your sessions…"), "Popover timeline must show an indexing placeholder")
        XCTAssertTrue(s.contains("No sessions yet"), "Popover timeline must show a distinct zero-data placeholder")
    }

    func testPopoverPinsStableMinHeight() throws {
        let s = try popoverView()
        XCTAssertTrue(
            s.contains("minHeight: 420"),
            "Popover must pin a stable min height so sections swap in place instead of resizing the window"
        )
        XCTAssertTrue(
            s.contains("Spacer(minLength: 0)"),
            "Popover must anchor the footer to the bottom of the pinned min-box with a Spacer"
        )
    }

    func testPopoverUsageEmptyRowOpensSettings() throws {
        let s = try popoverView()
        XCTAssertTrue(
            s.contains("serviceStatusStore.usageData.isEmpty"),
            "Popover usage-empty row must be gated on usageData.isEmpty"
        )
        XCTAssertTrue(
            s.contains("No usage data — set token limits in Settings"),
            "Popover must show the unconfigured-usage row"
        )
        XCTAssertTrue(s.contains(".openSettings"), "Popover usage-empty row must post .openSettings")
    }

    func testPopoverPollsWithSingleTimer() throws {
        let s = try popoverView()
        XCTAssertTrue(s.contains("Timer.scheduledTimer"), "Popover must refresh via a single timer")
        XCTAssertTrue(s.contains("refreshTimer?.invalidate()"), "Popover timer must be invalidated on disappear")
    }

    func testMenuBarSingleClickRoutesToPopoverImmediately() {
        XCTAssertEqual(MenuBarController.clickAction(for: .leftMouseUp, clickCount: 1), .togglePopover)
        XCTAssertEqual(MenuBarController.clickAction(for: .leftMouseUp, clickCount: 2), .openWindow)
        XCTAssertEqual(MenuBarController.clickAction(for: .rightMouseUp, clickCount: 1), .showContextMenu)
    }

    func testMenuBarClickHandlerDoesNotWaitForDoubleClickInterval() throws {
        let s = try menuBarController()
        XCTAssertFalse(
            s.contains("NSEvent.doubleClickInterval"),
            "Single-click must not wait out doubleClickInterval before opening the popover"
        )
        XCTAssertFalse(
            s.contains("Timer.scheduledTimer(withTimeInterval: NSEvent.doubleClickInterval"),
            "Click handling must not use a timer to delay single-click popover opening"
        )
    }

    func testMenuBarDropsDeletedWebUiAction() throws {
        let s = try menuBarController()
        XCTAssertFalse(s.contains("openWebUI"), "Menu bar menu must not expose a deleted Web UI action")
    }

    func testPopoverHoverStateIsTimelineRowLocal() throws {
        let s = try popoverView()
        XCTAssertFalse(
            s.contains("@State private var hoveredSessionId"),
            "Timeline hover state must not live on the root PopoverView"
        )
        XCTAssertTrue(
            s.contains("struct PopoverTimelineRow: View"),
            "Timeline rows must be extracted so hover invalidates only the row"
        )
        XCTAssertTrue(
            s.contains("@State private var isHovered = false"),
            "Timeline row hover must be local row state"
        )
    }

    func testPopoverUsesSingleDataSnapshotState() throws {
        let s = try popoverView()
        XCTAssertTrue(s.contains("struct PopoverDataSnapshot"), "Popover DB-backed state must be grouped")
        XCTAssertTrue(
            s.contains("@State private var data = PopoverDataSnapshot.empty"),
            "Popover must update DB-backed fields with one snapshot assignment"
        )
        XCTAssertFalse(s.contains("@State private var sourceCount"), "sourceCount must move into the snapshot")
        XCTAssertFalse(s.contains("@State private var projectCount"), "projectCount must move into the snapshot")
        XCTAssertFalse(s.contains("@State private var dbSize"), "dbSize must move into the snapshot")
        XCTAssertFalse(s.contains("@State private var recentSessions"), "recentSessions must move into the snapshot")
    }

    func testPopoverDropsTechnicalChromeKeepsSessionContent() throws {
        let s = try popoverView()
        // The simplified popover drops the low-signal technical blocks…
        XCTAssertFalse(s.contains("popover_statsGrid"), "Popover must drop the Today/Sources/Projects/DB Size stats grid")
        XCTAssertFalse(s.contains("popover_status_web"), "Popover must drop the Web/Service status dots")
        XCTAssertFalse(s.contains("sources active"), "Popover must drop the source-health summary line")
        XCTAssertFalse(s.contains("DB Size"), "Popover must drop the DB size stat")
        // …and keeps the useful session content.
        XCTAssertTrue(s.contains("LiveSessionCard"), "Popover must keep the Live section")
        XCTAssertTrue(s.contains("struct PopoverTimelineRow"), "Popover must keep the recent-session timeline")
    }

    func testMenuBarActivityIsGatedOnSetting() throws {
        let s = try menuBarController()
        XCTAssertTrue(
            s.contains("register(defaults: [\"showMenuBarActivity\": true])"),
            "Menu-bar activity must default to on so existing behavior is preserved"
        )
        XCTAssertTrue(
            s.contains("guard showMenuBarActivity else"),
            "updateBadge must clear the badge when activity display is disabled"
        )
        XCTAssertTrue(
            s.contains("if showMenuBarActivity, let usage = serviceStatusStore.usagePressureSummary"),
            "The usage gauge must be suppressed when activity display is disabled"
        )
    }

    func testPopoverAssignsStatsBeforeAwaitingLiveSessions() throws {
        let s = try popoverView()
        // Live poll stamps LiveSessionsHold via Result; DB snapshot still paints first.
        guard let statsAssignment = s.range(of: "data = result"),
              let liveAssignment = s.range(of: "switch await livePoll") else {
            return XCTFail("Popover loadData must assign DB stats before awaiting live sessions")
        }
        XCTAssertLessThan(statsAssignment.lowerBound, liveAssignment.lowerBound)
        XCTAssertTrue(
            s.contains("async let livePoll"),
            "liveSessions() must start in a child task concurrently with the detached DB block"
        )
        XCTAssertFalse(
            s.contains("(try? await serviceClient.liveSessions().sessions) ?? []"),
            "Popover must not collapse live-poll failure into an empty list (row 9 hold)"
        )
        XCTAssertTrue(
            s.contains("LiveSessionsHold"),
            "Popover must hold last-good live sessions across a failed poll"
        )
    }

    func testPopoverRefreshCadenceAlignsWithLiveSessionTTL() {
        XCTAssertGreaterThanOrEqual(
            PopoverRefreshPolicy.refreshInterval,
            PopoverRefreshPolicy.liveSessionCacheTTL,
            "Popover refresh must not poll live sessions faster than the service cache TTL"
        )
    }

    // MARK: - LiveSessionCard open closure

    func testLiveSessionCardExposesGuardedOpenClosure() throws {
        let s = try liveCard()
        XCTAssertTrue(s.contains("var onOpen: (() -> Void)?"), "LiveSessionCard must expose an onOpen closure")
        XCTAssertTrue(
            s.contains("session.sessionId != nil"),
            "LiveSessionCard interactivity must be guarded on a non-nil sessionId"
        )
    }

    // MARK: - Reachable service restart (mirror row 5)

    /// App.swift registered a .restartService observer for months under a comment
    /// naming two posters that did not exist, so the recovery was unreachable.
    /// Assert the posters are present *and gated*: an ungated Restart Service
    /// control would offer a restart during .starting, fighting the launch in
    /// flight, and every file-level `contains` would still pass.
    func testHomeServiceStatePostsRestartOnlyWhileFailed() throws {
        let s = try homeView()
        let sectionStart = try XCTUnwrap(s.range(of: "private var serviceStateSection: some View {"))
        let sectionEnd = try XCTUnwrap(
            s.range(of: ".accessibilityIdentifier(\"home_serviceState\")", range: sectionStart.upperBound..<s.endIndex)
        )
        let section = String(s[sectionStart.upperBound..<sectionEnd.lowerBound])

        let gateStart = try XCTUnwrap(section.range(of: "if serviceStatusStore.isFailed {"))
        let gated = String(section[gateStart.upperBound...])
        XCTAssertTrue(
            gated.contains("post(name: .restartService"),
            "the Restart Service poster must sit inside the isFailed branch"
        )
        XCTAssertEqual(
            section.components(separatedBy: "post(name: .restartService").count - 1,
            1,
            "exactly one restart poster in the Service State section, and it is the gated one"
        )
    }

    func testMenuBarRestartItemIsGatedAndOrderedBeforeQuit() throws {
        let s = try menuBarController()
        let menuStart = try XCTUnwrap(s.range(of: "private func showContextMenu() {"))
        let menuEnd = try XCTUnwrap(
            s.range(of: "statusItem.button?.performClick(nil)", range: menuStart.upperBound..<s.endIndex)
        )
        let menu = String(s[menuStart.upperBound..<menuEnd.lowerBound])

        let separator = try XCTUnwrap(menu.range(of: "menu.addItem(.separator())"))
        let restart = try XCTUnwrap(menu.range(of: "if serviceStatusStore.isFailed {"))
        let quit = try XCTUnwrap(menu.range(of: "Quit Engram"))
        XCTAssertTrue(separator.upperBound < restart.lowerBound, "Restart Service belongs after the separator")
        XCTAssertTrue(restart.upperBound < quit.lowerBound, "Restart Service belongs before Quit")

        // #252 put the Help items in this same rebuilt menu; neither may drop the other.
        XCTAssertTrue(menu.contains("Report an Issue…"))
        XCTAssertTrue(menu.contains("Show Onboarding"))

        XCTAssertTrue(
            s.contains("@objc func restartService() {"),
            "the menu item needs an @objc target on the controller"
        )
    }

    func testPopoverDoesNotPostRestartService() throws {
        XCTAssertFalse(
            try popoverView().contains("restartService"),
            "the popover is session content only; restart controls belong to HomeView and the menu bar"
        )
    }

    func testAppNoLongerClaimsPostersThatDoNotExist() throws {
        let s = try source("macos/Engram/App.swift")
        // Comment prose wraps; compare on the joined text so a rewrap cannot
        // silently disarm either half of this guard.
        let prose = s
            .replacingOccurrences(of: "//", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        XCTAssertFalse(
            prose.contains("WP09's menu-bar item / Service-State banner post"),
            "the comment named posters that did not exist for months"
        )
        XCTAssertTrue(
            prose.contains("Gated on autoStartService so headless test runs never spawn the helper"),
            "the accurate half of that comment describes real gating and must stay"
        )
    }
}
