import EngramCoreRead
import XCTest

/// ARCH-001A: shared search filters characterize the common SQL contract
/// without moving any surface's database pool, DTOs, or alias resolver.
final class SearchFilterPredicatesTests: XCTestCase {
    func testActivitySinceUsesCoalescedSessionActivityTime_repro() throws {
        let clauses = SearchFilterPredicates.clauses(
            since: " 2026-08-12T01:02:03Z\n"
        )

        let clause = try XCTUnwrap(clauses.first)
        XCTAssertEqual(clauses.count, 1)
        XCTAssertEqual(clause.sql, "COALESCE(NULLIF(s.end_time, ''), s.start_time) >= ?")
        XCTAssertEqual(clause.bindings, ["2026-08-12T01:02:03Z"])
    }

    func testBlankSourceAndProjectValuesAreIgnored_repro() {
        let clauses = SearchFilterPredicates.clauses(
            sources: ["", "  ", "\n"],
            projects: ["", "\t"]
        )

        XCTAssertTrue(clauses.isEmpty)
    }

    func testProjectValuesUseExactMatchAfterCallerAliasExpansion_repro() throws {
        let clauses = SearchFilterPredicates.clauses(
            projects: [" app ", "app-alias"]
        )

        let clause = try XCTUnwrap(clauses.first)
        XCTAssertEqual(clause.sql, "s.project IN (?, ?)")
        XCTAssertEqual(clause.bindings, ["app", "app-alias"])
        XCTAssertFalse(clause.sql.localizedCaseInsensitiveContains("LIKE"))
    }

    func testSourceUsesExactMatchWithRequestedAlias_repro() throws {
        let clauses = SearchFilterPredicates.clauses(
            sources: [" codex "],
            alias: "session"
        )

        let clause = try XCTUnwrap(clauses.first)
        XCTAssertEqual(clause.sql, "session.source = ?")
        XCTAssertEqual(clause.bindings, ["codex"])
    }

    func testHQOriginUsesExactMatchWithRequestedAlias_repro() throws {
        let clauses = SearchFilterPredicates.clauses(
            origin: " hq ",
            alias: "session"
        )

        let clause = try XCTUnwrap(clauses.first)
        XCTAssertEqual(clauses.count, 1)
        XCTAssertEqual(clause.sql, "session.origin = ?")
        XCTAssertEqual(clause.bindings, ["hq"])
    }

    func testLocalOriginIncludesLegacyNullAndEveryNonHQOrigin_repro() throws {
        let clauses = SearchFilterPredicates.clauses(origin: "local")

        let clause = try XCTUnwrap(clauses.first)
        XCTAssertEqual(clauses.count, 1)
        XCTAssertEqual(clause.sql, "(s.origin IS NULL OR s.origin != ?)")
        XCTAssertEqual(clause.bindings, ["hq"])
    }

    func testNilOriginAddsNoSQLOrBindings_repro() {
        XCTAssertTrue(SearchFilterPredicates.clauses(origin: nil).isEmpty)
    }

    func testBlankOriginAddsNoSQLOrBindings_repro() {
        XCTAssertTrue(SearchFilterPredicates.clauses(origin: " \n\t ").isEmpty)
    }
}
