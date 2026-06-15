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
}
