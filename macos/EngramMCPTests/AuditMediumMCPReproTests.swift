import XCTest

/// Source/contract repros for full-audit mediums M9/M18/M19/M20/M24 that land
/// on MCP read paths. Executable RPC coverage for CJK is separate (H2).
final class AuditMediumMCPReproTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    /// M9: list_sessions / file_activity must clamp limit to >= 1.
    func testListAndFileActivityLimitsClamped_repro() throws {
        let registry = try source("macos/EngramMCP/Core/MCPToolRegistry.swift")
        XCTAssertTrue(
            registry.contains("min(max(arguments[\"limit\"]?.intValue ?? 20, 1), 100)"),
            "M9: list_sessions limit must clamp with min(max(...))"
        )
        XCTAssertTrue(
            registry.contains("min(max(arguments[\"limit\"]?.intValue ?? 50, 1), 200)"),
            "M9: file_activity limit must clamp with min(max(...))"
        )
    }

    /// M18: default list_sessions must force top-level + non-skip filters.
    func testListSessionsTopLevelAndSkipFilters_repro() throws {
        let db = try source("macos/EngramMCP/Core/MCPDatabase.swift")
        let start = try XCTUnwrap(db.range(of: "func listSessions("))
        let end = try XCTUnwrap(db.range(of: "func getCosts(", range: start.lowerBound..<db.endIndex))
        let body = String(db[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("parent_session_id IS NULL"), "M18: top-level parent filter")
        XCTAssertTrue(body.contains("suggested_parent_id IS NULL"), "M18: top-level suggested filter")
        XCTAssertTrue(
            body.contains("tier IS NULL OR tier != 'skip'"),
            "M18: exclude skip tier when include_all=false"
        )
    }

    /// M19: cost queries must filter hidden_at IS NULL.
    func testCostQueriesExcludeHiddenSessions_repro() throws {
        let db = try source("macos/EngramMCP/Core/MCPDatabase.swift")
        XCTAssertTrue(
            db.contains("WHERE s.hidden_at IS NULL AND s.start_time >="),
            "M19: totalCostSince must exclude hidden"
        )
        // getCosts day path
        let costs = try XCTUnwrap(db.range(of: "func getCosts("))
        let costsEnd = try XCTUnwrap(db.range(of: "func getToolAnalytics(", range: costs.lowerBound..<db.endIndex))
        let body = String(db[costs.lowerBound..<costsEnd.lowerBound])
        XCTAssertTrue(body.contains("WHERE s.hidden_at IS NULL"), "M19: getCosts excludes hidden")
    }

    /// M24: get_costs day buckets use localtime.
    func testGetCostsDayBucketsUseLocaltime_repro() throws {
        let db = try source("macos/EngramMCP/Core/MCPDatabase.swift")
        let costs = try XCTUnwrap(db.range(of: "func getCosts("))
        let costsEnd = try XCTUnwrap(db.range(of: "func getToolAnalytics(", range: costs.lowerBound..<db.endIndex))
        let body = String(db[costs.lowerBound..<costsEnd.lowerBound])
        XCTAssertTrue(
            body.contains("date(s.start_time, 'localtime')"),
            "M24: day groupExpr must use localtime"
        )
        XCTAssertFalse(
            body.contains("groupExpr = \"date(s.start_time)\""),
            "M24: must not use bare UTC date()"
        )
    }
}
