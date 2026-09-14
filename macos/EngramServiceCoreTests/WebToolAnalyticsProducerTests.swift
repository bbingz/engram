import Foundation
import GRDB
import XCTest
@testable import EngramServiceCore

final class WebToolAnalyticsProducerTests: XCTestCase {
    private let requestID = "AAAAAAAA-0000-4000-8000-000000000188"

    func testToolPagingRetainsFullTotalsAndExcludesUnavailableSessions() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let first = try await producer.toolAnalytics(.init(limit: 1), requestId: requestID, deadline: fixture.deadline())
        XCTAssertEqual(first.totalCalls, 10)
        XCTAssertEqual(first.groupCount, 2)
        XCTAssertEqual(first.items.map(\.label), ["Read"])
        XCTAssertEqual(first.items.first?.callCount, 8)
        XCTAssertEqual(first.items.first?.sessionCount, 3)
        let second = try await producer.toolAnalytics(.init(limit: 1, snapshotId: first.snapshotId, cursor: try XCTUnwrap(first.nextCursor)),
            requestId: requestID, deadline: fixture.deadline())
        XCTAssertEqual(second.totalCalls, 10)
        XCTAssertEqual(second.groupCount, 2)
        XCTAssertEqual(second.items.map(\.label), ["Edit"])
        XCTAssertNil(second.nextCursor)
    }

    func testSessionAndProjectGroupsCountDistinctSessionsAndTools() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let sessions = try await producer.toolAnalytics(.init(groupBy: .session), requestId: requestID, deadline: fixture.deadline())
        XCTAssertEqual(sessions.items.map(\.sessionId), ["one", "two", "three"])
        XCTAssertEqual(sessions.items.first?.callCount, 5)
        XCTAssertEqual(sessions.items.first?.toolCount, 2)
        let projects = try await producer.toolAnalytics(.init(groupBy: .project), requestId: requestID, deadline: fixture.deadline())
        XCTAssertEqual(projects.totalCalls, 10)
        XCTAssertEqual(projects.items.first?.label, "alpha")
        XCTAssertEqual(projects.items.first?.callCount, 9)
        XCTAssertEqual(projects.items.first?.sessionCount, 2)
        XCTAssertEqual(projects.items.first?.toolCount, 2)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(projects), as: UTF8.self).contains("/private/alpha"))
    }

    func testProjectSubstringAndLatestActivityDateFiltersMatchLegacyBehavior() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let page = try await producer.toolAnalytics(.init(project: "alp", since: "2026-09-03", until: "2026-09-03"),
            requestId: requestID, deadline: fixture.deadline())
        XCTAssertEqual(page.totalCalls, 5, "The first session ended on September 3 despite starting earlier")
        let literal = try await producer.toolAnalytics(.init(project: "%"), requestId: requestID, deadline: fixture.deadline())
        XCTAssertEqual(literal.totalCalls, 0, "Project wildcards are literal user input")
    }

    func testContinuedPageRejectsRevokedVisibility() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let first = try await producer.toolAnalytics(.init(limit: 1), requestId: requestID, deadline: fixture.deadline())
        try fixture.write { db in try db.execute(sql: "UPDATE sessions SET hidden_at = '2026-09-13' WHERE id = 'one'") }
        do {
            _ = try await producer.toolAnalytics(.init(limit: 1, snapshotId: first.snapshotId, cursor: try XCTUnwrap(first.nextCursor)),
                requestId: requestID, deadline: fixture.deadline())
            XCTFail("A stale authorized aggregate must not be released")
        } catch { XCTAssertEqual(error as? ServiceWebMetadataError, .stale) }
    }

    /// HQ session ids look like `remote:capture-v1.<machine>.<instance>:<native>`
    /// (about 196 bytes) and every session of one stream shares well over 80
    /// leading bytes. `Data.hash(into:)` only hashes the first 80 bytes, so the
    /// `Data`-keyed group dictionary and per-group session sets collapsed into
    /// one probe chain and `groupBy=session` blew the 2s deadline on HQ's 38k
    /// sessions. 4k such sessions took several seconds per aggregation before
    /// the fix; both aggregations now finish in well under a second.
    func testLongSharedPrefixSessionIDsAggregateQuickly_repro() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let machine = "DDDDDDDD-0000-4000-8000-000000000004"
        let instance = "EEEEEEEE-0000-4000-8000-000000000005"
        try fixture.seedRegistry(machine: machine, instance: instance)
        let count = 4000
        let prefix = "remote:capture-v1.\(machine).\(instance):" + String(repeating: "W", count: 64)
        try fixture.write { db in
            for index in 0..<count {
                let id = prefix + String(format: "%08d", index)
                try db.execute(sql: """
                    INSERT INTO sessions(
                        id, source, start_time, cwd, project, file_path, generated_title, tier,
                        authoritative_node, sync_version)
                    VALUES (?, 'claude-code', '2026-09-01 12:00:00', ?, '/private/alpha', ?, ?, 'normal', ?, 1)
                    """, arguments: [
                        id, fixture.configuredRoot(instance),
                        "\(fixture.configuredRoot(instance))/long-\(index).jsonl", "long \(index)",
                        "capture-v1.\(machine).\(instance)",
                    ])
                try db.execute(sql: """
                    INSERT INTO capture_ingest_identity_bindings(
                        machine_id, source_instance_id, source, native_id, stored_session_id, last_sync_version)
                    VALUES (?, ?, 'claude-code', ?, ?, 1)
                    """, arguments: [machine, instance, "native-long-\(index)", id])
                for tool in ["Read", "Edit", "Bash"] {
                    try db.execute(sql: "INSERT INTO session_tools(session_id, tool_name, call_count) VALUES (?, ?, 2)",
                                   arguments: [id, tool])
                }
            }
        }
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let clock = ContinuousClock()
        let started = clock.now
        let sessions = try await producer.toolAnalytics(.init(groupBy: .session, limit: 100),
                                                        requestId: requestID, deadline: fixture.deadline())
        let tools = try await producer.toolAnalytics(.init(groupBy: .tool), requestId: requestID, deadline: fixture.deadline())
        let elapsed = clock.now - started
        XCTAssertEqual(sessions.groupCount, count + 3)
        XCTAssertEqual(sessions.totalCalls, Int64(10 + count * 6))
        XCTAssertEqual(sessions.items.count, 100)
        XCTAssertEqual(sessions.items.first?.callCount, 6)
        XCTAssertEqual(sessions.items.first?.toolCount, 3)
        XCTAssertEqual(sessions.items.first?.sessionId?.hasPrefix(prefix), true)
        XCTAssertEqual(tools.items.first(where: { $0.label == "Read" })?.sessionCount, Int64(count + 3))
        XCTAssertEqual(tools.items.first(where: { $0.label == "Bash" })?.sessionCount, Int64(count))
        XCTAssertLessThan(elapsed, .seconds(3), "long shared-prefix ids must not degrade the aggregation to linear probing")
    }

    /// HQ regression: with `agents=all` the only index constraint on `sessions`
    /// is `hidden_at IS NULL`, and on a database without statistics the planner
    /// took `idx_sessions_visible`, reading all 44k visible session rows (32k of
    /// them skip-tier and discarded): 2.4s, a 503 at the 2s deadline for Tools
    /// and Files, 1.7s for the list. The `.all` / `.only` statements pin
    /// `sessions` to the skip-excluding partial `idx_sessions_activity_time`;
    /// `.hide` keeps the planner's own covering `idx_sessions_web_list_keys`,
    /// and results are the same either way.
    func testAgentsAllPinsSessionsToSkipExcludingIndex_repro() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let statements = TracedStatements()
        let producer = try fixture.producer(hooks: .init(prepareDatabase: { db in
            db.trace(options: .statement) { event in
                if case .statement(let statement) = event { statements.record(statement.sql) }
            }
        }))
        defer { try? producer.stop() }
        let hide = try await producer.toolAnalytics(.init(), requestId: requestID, deadline: fixture.deadline())
        let all = try await producer.toolAnalytics(.init(agents: .all), requestId: requestID, deadline: fixture.deadline())
        let only = try await producer.toolAnalytics(.init(agents: .only), requestId: requestID, deadline: fixture.deadline())
        XCTAssertEqual(all.totalCalls, hide.totalCalls, "the fixture has no agent sessions")
        XCTAssertEqual(all.items.map(\.key), hide.items.map(\.key))
        XCTAssertEqual(only.totalCalls, 0)

        let toolStatements = statements.values.filter { $0.contains("FROM session_tools t") }
        let pinned = toolStatements.filter { $0.contains("INDEXED BY \(ServiceWebMetadataProducer.visibleSessionsIndex)") }
        XCTAssertGreaterThanOrEqual(toolStatements.count, 3)
        XCTAssertGreaterThanOrEqual(pinned.count, 2, "all and only pin the index")
        XCTAssertGreaterThanOrEqual(toolStatements.count - pinned.count, 1, "hide does not")
        guard let statement = pinned.first else { return }
        var plan: [String] = []
        try fixture.write { db in
            XCTAssertFalse(try db.tableExists("sqlite_stat1"), "fixture must stay statistics-free like HQ")
            let placeholders = statement.filter { $0 == "?" }.count
            plan = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + statement,
                                    arguments: StatementArguments(Array(repeating: "x", count: placeholders)))
                .map { $0["detail"] as String }
        }
        let joined = plan.joined(separator: "\n")
        XCTAssertTrue(joined.contains("SEARCH s USING INDEX \(ServiceWebMetadataProducer.visibleSessionsIndex)"), joined)
        XCTAssertFalse(joined.contains("idx_sessions_visible"), joined)
    }

    private final class TracedStatements: @unchecked Sendable {
        private let lock = NSLock()
        private var statements: [String] = []
        func record(_ sql: String) { lock.withLock { statements.append(sql) } }
        var values: [String] { lock.withLock { statements } }
    }

    private func fixture() throws -> MetadataSQLFixture {
        let fixture = try MetadataSQLFixture()
        try fixture.migrate(); try fixture.seedRegistry()
        for (id, project, tier, hidden) in [("one", "/private/alpha", "normal", false),
                                           ("two", "/private/alpha", "normal", false),
                                           ("three", "/private/beta", "normal", false),
                                           ("hidden", "/private/alpha", "normal", true),
                                           ("skip", "/private/alpha", "skip", false)] {
            try fixture.seedBoundSession(id: id, start: "2026-09-01 12:00:00", nativeID: "native-\(id)", project: project, tier: tier, hidden: hidden)
        }
        try fixture.seedLocalSession(id: "unbound")
        try fixture.write { db in
            try db.execute(sql: "UPDATE sessions SET end_time = '2026-09-03 12:00:00' WHERE id = 'one'")
            for (id, tool, count) in [("one", "Read", 3), ("one", "Edit", 2), ("two", "Read", 4), ("three", "Read", 1),
                                      ("hidden", "Read", 99), ("skip", "Read", 99), ("unbound", "Read", 99)] {
                try db.execute(sql: "INSERT INTO session_tools(session_id, tool_name, call_count) VALUES (?, ?, ?)", arguments: [id, tool, count])
            }
        }
        return fixture
    }
}
