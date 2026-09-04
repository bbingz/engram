import XCTest
@testable import Engram

/// Locks the SearchPageView result-state classifier so a backend double-fault
/// stays distinguishable from a genuine no-match (search-2/3, xc-states-4,
/// command-palette-5).
final class SearchOutcomeTests: XCTestCase {
    // The selected origin is forwarded to both service and offline SQL search
    // before their result limits. This helper characterizes the corresponding
    // stored-origin semantics: HQ is exact, nil/non-HQ is local, and all passes.
    func testSearchOriginFilterMatchesStoredOrigin() {
        XCTAssertTrue(SearchOriginFilter.all.matches("hq"))
        XCTAssertTrue(SearchOriginFilter.all.matches(nil))
        XCTAssertTrue(SearchOriginFilter.hq.matches("hq"))
        XCTAssertFalse(SearchOriginFilter.hq.matches(nil))
        XCTAssertFalse(SearchOriginFilter.hq.matches("m1"))
        XCTAssertTrue(SearchOriginFilter.local.matches(nil))
        XCTAssertTrue(SearchOriginFilter.local.matches("m1"))
        XCTAssertFalse(SearchOriginFilter.local.matches("hq"))
    }

    private func result(_ id: String) -> SearchResult {
        SearchResult(id: id, session: nil, snippet: "", matchType: "keyword", score: 0)
    }

    /// ui-search-settings-3: a one-character query is an explicit idle state,
    /// and both views must clear stale result metadata instead of saying no results.
    func testOneCharacterQueriesShowMinimumLengthGuidance_repro() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let searchPage = try String(
            contentsOf: root.appendingPathComponent("macos/Engram/Views/Pages/SearchPageView.swift"),
            encoding: .utf8
        )
        let palette = try String(
            contentsOf: root.appendingPathComponent("macos/Engram/Views/CommandPaletteView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(searchPage.contains("SearchQueryReadiness.classify(query: query)"))
        XCTAssertTrue(palette.contains("SearchQueryReadiness.classify(query: query)"))
        XCTAssertTrue(searchPage.contains("Type at least 2 characters"))
        XCTAssertTrue(palette.contains("Type at least 2 characters"))
        XCTAssertTrue(searchPage.contains("searchModes = []"))
    }

    func testSearchQueryReadinessClassifiesMinimumLength_repro() {
        XCTAssertEqual(SearchQueryReadiness.classify(query: ""), .idle)
        XCTAssertEqual(SearchQueryReadiness.classify(query: " \n"), .idle)
        XCTAssertEqual(SearchQueryReadiness.classify(query: "a"), .tooShort)
        XCTAssertEqual(SearchQueryReadiness.classify(query: "AI"), .ready)
    }

    func testEmptyQueryIsEmpty() {
        XCTAssertEqual(SearchOutcome.classify(query: "", results: [], didFail: false), .empty)
    }

    func testWhitespaceQueryIsEmpty() {
        XCTAssertEqual(SearchOutcome.classify(query: "   \n", results: [], didFail: false), .empty)
    }

    func testNonEmptyQueryWithResultsIsResults() {
        XCTAssertEqual(
            SearchOutcome.classify(query: "swift", results: [result("a")], didFail: false),
            .results
        )
    }

    func testNonEmptyQueryNoResultsNoFailureIsEmpty() {
        XCTAssertEqual(
            SearchOutcome.classify(query: "swift", results: [], didFail: false),
            .empty
        )
    }

    func testDoubleFaultIsFailed() {
        XCTAssertEqual(
            SearchOutcome.classify(query: "swift", results: [], didFail: true),
            .failed
        )
    }

    func testFailureWinsOverStaleResults() {
        XCTAssertEqual(
            SearchOutcome.classify(query: "swift", results: [result("a")], didFail: true),
            .failed
        )
    }

    // MARK: - Bool overload (CommandPaletteView session search)

    func testBoolOverloadEmptyQueryIsEmpty() {
        XCTAssertEqual(
            SearchOutcome.classify(query: "", isEmptyResults: true, didFail: false),
            .empty
        )
    }

    func testBoolOverloadWhitespaceQueryIsEmpty() {
        XCTAssertEqual(
            SearchOutcome.classify(query: "   \n", isEmptyResults: true, didFail: false),
            .empty
        )
    }

    func testBoolOverloadWithResultsIsResults() {
        XCTAssertEqual(
            SearchOutcome.classify(query: "swift", isEmptyResults: false, didFail: false),
            .results
        )
    }

    func testBoolOverloadNoResultsNoFailureIsEmpty() {
        XCTAssertEqual(
            SearchOutcome.classify(query: "swift", isEmptyResults: true, didFail: false),
            .empty
        )
    }

    /// Wave 7E H11 (repro): Command palette path — service down + successful empty
    /// local FTS is emptiness (didFail=false), not infrastructure unavailable.
    func testPaletteServiceDownEmptyLocalIsEmptyNotFailed_repro() {
        // Mirrors CommandPaletteView after local FTS returns [] without throwing.
        XCTAssertEqual(
            SearchOutcome.classify(query: "swift", isEmptyResults: true, didFail: false),
            .empty
        )
    }

    /// Wave 7E H11 (repro): only when local FTS also throws is the palette unavailable.
    func testPaletteDoubleFaultIsFailed_repro() {
        XCTAssertEqual(
            SearchOutcome.classify(query: "swift", isEmptyResults: true, didFail: true),
            .failed
        )
    }

    func testBoolOverloadDoubleFaultIsFailed() {
        XCTAssertEqual(
            SearchOutcome.classify(query: "swift", isEmptyResults: true, didFail: true),
            .failed
        )
    }

    func testBoolOverloadFailureWinsOverStaleResults() {
        XCTAssertEqual(
            SearchOutcome.classify(query: "swift", isEmptyResults: false, didFail: true),
            .failed
        )
    }

    func testUITestMockExercisesFixtureFallbackAndDistinctSearchStates_repro() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let app = try source("macos/Engram/App.swift")
        let page = try source("macos/Engram/Views/Pages/SearchPageView.swift")
        let smoke = try source("macos/EngramUITests/Tests/SmokeTests/SearchSmokeTests.swift")
        let full = try source("macos/EngramUITests/Tests/FullTests/SearchTests.swift")

        XCTAssertTrue(app.contains("searchResult: .failure"))
        for identifier in ["search_idle", "search_tooShort", "search_failed", "search_noResults"] {
            XCTAssertTrue(page.contains(identifier), "missing distinct search state \(identifier)")
        }
        XCTAssertTrue(smoke.contains("authentication"))
        XCTAssertFalse(smoke.contains("resultsAppeared || emptyStateAppeared"))
        XCTAssertTrue(full.contains("No results"))
    }

    func testUITestSearchAndHomeAssertionsAreDataScoped_repro() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }

        let searchScreen = try source("macos/EngramUITests/Screens/SearchScreen.swift")
        let smoke = try source("macos/EngramUITests/Tests/SmokeTests/SearchSmokeTests.swift")
        let sessions = try source("macos/EngramUITests/Tests/SmokeTests/SessionsSmokeTests.swift")
        let projects = try source("macos/EngramUITests/Tests/FullTests/ProjectsTests.swift")
        let homeSmoke = try source("macos/EngramUITests/Tests/SmokeTests/HomeSmokeTests.swift")

        XCTAssertFalse(searchScreen.contains("for character in query"))
        XCTAssertTrue(smoke.contains("search.result(containingText:"))
        XCTAssertTrue(sessions.contains("sessions.result(containingText:"))
        XCTAssertTrue(projects.contains("projects.result(containingText:"))
        XCTAssertTrue(homeSmoke.contains("home.recentSession(containingText:"))
    }
}
