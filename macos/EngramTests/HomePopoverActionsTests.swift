import XCTest
@testable import Engram

/// Source-inspection guards (mirroring ViewMainThreadReadTests) for WP09: the
/// Home/Today dashboard and menu-bar popover wire-ups. SwiftUI bodies aren't
/// unit-instantiable here, so these lock the view wiring at the source level —
/// KPI/See-all/warning navigation, the Web UI open action, the removed dead
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

    func testHomeWebUiRowOpensBrowser() throws {
        let s = try homeView()
        XCTAssertTrue(s.contains("NSWorkspace.shared.open"), "Web UI row must open the browser")
        XCTAssertTrue(
            s.contains("onTap: serviceStatusStore.endpointPort == nil ? nil : openWebUI"),
            "Web UI row tap must be gated on an available endpoint port"
        )
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

    func testPopoverSourceCountIsDerivedFromSourceStats() throws {
        let s = try popoverView()
        XCTAssertFalse(
            s.contains("COUNT(DISTINCT source)"),
            "sourceCount must be derived from sourceStats instead of issuing a redundant source-count query"
        )
        XCTAssertTrue(
            s.contains("sourceCount: stats.count"),
            "sourceCount and totalSourceCount must share the sourceStats result"
        )
    }

    func testPopoverAssignsStatsBeforeAwaitingLiveSessions() throws {
        let s = try popoverView()
        guard let statsAssignment = s.range(of: "data = result"),
              let liveAssignment = s.range(of: "liveSessions = await liveSessionsResult") else {
            return XCTFail("Popover loadData must assign DB stats before awaiting live sessions")
        }
        XCTAssertLessThan(statsAssignment.lowerBound, liveAssignment.lowerBound)
        XCTAssertTrue(
            s.contains("async let liveSessionsResult"),
            "liveSessions() must start in a child task concurrently with the detached DB block"
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
}
