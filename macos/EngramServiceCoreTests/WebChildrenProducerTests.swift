import Foundation
import GRDB
import XCTest
@testable import EngramServiceCore

final class WebChildrenProducerTests: XCTestCase {
    private let requestId = "AAAAAAAA-0000-4000-8000-000000000199"

    func testConfirmedAndSuggestedPageTogetherAndDedupConfirmedWins() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "parent", start: "2026-09-03 12:00:00")
        try fixture.seedBoundSession(id: "confirmed-a", start: "2026-09-03 11:00:00",
                                     nativeID: "native-confirmed-a", parent: "parent")
        try fixture.seedBoundSession(id: "confirmed-b", start: "2026-09-03 10:00:00",
                                     nativeID: "native-confirmed-b", parent: "parent")
        try fixture.seedBoundSession(id: "suggested-a", start: "2026-09-03 09:00:00",
                                     nativeID: "native-suggested-a")
        try fixture.seedBoundSession(id: "dual", start: "2026-09-03 08:00:00",
                                     nativeID: "native-dual", parent: "parent")
        try fixture.write { db in
            try db.execute(sql: """
                UPDATE sessions SET parent_session_id = NULL, suggested_parent_id = 'parent'
                WHERE id = 'suggested-a'
                """)
            try db.execute(sql: "UPDATE sessions SET suggested_parent_id = 'parent' WHERE id = 'dual'")
        }
        let producer = try fixture.producer()
        defer { try? producer.stop() }

        let first = try await producer.children(
            try EngramServiceWebChildrenRequest(sessionId: "parent", limit: 2),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(first.items.map(\.session.sessionId), ["confirmed-a", "confirmed-b"])
        XCTAssertEqual(first.items.map(\.relationship), [.confirmed, .confirmed])
        let cursor = try XCTUnwrap(first.nextCursor)
        let second = try await producer.children(
            try EngramServiceWebChildrenRequest(sessionId: "parent", limit: 2,
                                                snapshotId: first.snapshotId, cursor: cursor),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(second.snapshotId, first.snapshotId)
        XCTAssertEqual(second.items.map(\.session.sessionId), ["suggested-a", "dual"])
        XCTAssertEqual(second.items.map(\.relationship), [.suggested, .confirmed])
        XCTAssertNil(second.nextCursor)
    }

    func testHiddenSkipUnboundExcludedWhileLiteAndAgentAreAdmitted() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "parent", start: "2026-09-03 12:00:00")
        try fixture.seedBoundSession(id: "lite-child", start: "2026-09-03 11:00:00",
                                     nativeID: "native-lite", tier: "lite", parent: "parent")
        try fixture.seedBoundSession(id: "agent-child", start: "2026-09-03 10:00:00",
                                     nativeID: "native-agent", parent: "parent")
        try fixture.seedBoundSession(id: "skip-child", start: "2026-09-03 09:00:00",
                                     nativeID: "native-skip", tier: "skip", parent: "parent")
        try fixture.seedBoundSession(id: "hidden-child", start: "2026-09-03 08:00:00",
                                     nativeID: "native-hidden", hidden: true, parent: "parent")
        try fixture.write { db in
            try db.execute(sql: "UPDATE sessions SET agent_role = 'dispatched' WHERE id = 'agent-child'")
            try db.execute(sql: """
                INSERT INTO sessions(
                    id, source, start_time, cwd, project, file_path, generated_title, custom_name,
                    tier, hidden_at, parent_session_id, suggested_parent_id, authoritative_node,
                    sync_version, snapshot_hash)
                VALUES (
                    'unbound-child', 'claude-code', '2026-09-03 07:00:00', '/tmp', 'project_1',
                    '/tmp/unbound.jsonl', 'unbound', NULL, 'normal', NULL, 'parent', NULL,
                    'capture-v1.missing.missing', 1, 'snapshot-unbound')
                """)
        }
        let producer = try fixture.producer()
        defer { try? producer.stop() }

        let page = try await producer.children(
            try EngramServiceWebChildrenRequest(sessionId: "parent", limit: 20),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(Set(page.items.map(\.session.sessionId)), ["lite-child", "agent-child"])
        XCTAssertEqual(page.items.first { $0.session.sessionId == "agent-child" }?.session.isAgent, true)
        XCTAssertFalse(page.items.contains { ["skip-child", "hidden-child", "unbound-child"].contains($0.session.sessionId) })
    }

    /// HQ regression, three planner traps in the children statement:
    /// an explicit `COLLATE BINARY` on the two parent terms disabled SQLite's
    /// multi-index OR optimisation (every request walked all 38k identity
    /// bindings, 1.96s); once eligible, a database with no `sqlite_stat1`
    /// still preferred the partial `idx_sessions_visible (hidden_at=?)`, a scan
    /// of every visible session (1.53s, a 503 at the 2s deadline in the Child
    /// sessions tab); and with that term de-indexed a policy with few enabled
    /// sources made it take `idx_sessions_source` through the transitive
    /// `s.source = i.source AND i.source IN (…)` instead. HQ has never been
    /// analysed and neither has this fixture (one enabled source), so the plan
    /// for the statement the producer actually sent is the plan HQ takes: it
    /// must probe both parent indexes and nothing else on `sessions`.
    func testChildrenStatementUsesBothParentIndexes_repro() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "parent", start: "2026-09-03 12:00:00")
        try fixture.seedBoundSession(id: "child", start: "2026-09-03 11:00:00",
                                     nativeID: "native-child", parent: "parent")
        let statements = TracedStatements()
        let producer = try fixture.producer(hooks: .init(prepareDatabase: { db in
            db.trace(options: .statement) { event in
                if case .statement(let statement) = event { statements.record(statement.sql) }
            }
        }))
        defer { try? producer.stop() }

        let page = try await producer.children(
            try EngramServiceWebChildrenRequest(sessionId: "parent", limit: 20),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(page.items.map(\.session.sessionId), ["child"])

        let predicate = ServiceWebMetadataProducer.childParentPredicateSQL
        XCTAssertFalse(predicate.contains("COLLATE"), predicate)
        for term in ["+s.hidden_at IS NULL", "+s.source = i.source", "+s.authoritative_node = ("] {
            XCTAssertTrue(ServiceWebMetadataProducer.childVisibilitySQL.contains(term), term)
        }
        let children = statements.values.filter {
            $0.contains(predicate) && $0.contains(ServiceWebMetadataProducer.childVisibilitySQL)
                && !$0.contains("s.id COLLATE BINARY IN")
        }
        XCTAssertEqual(children.count, 1, "expected one first-page children statement:\n\(statements.values.joined(separator: "\n---\n"))")
        guard let statement = children.first else { return }
        var plan: [String] = []
        try fixture.write { db in
            XCTAssertFalse(try db.tableExists("sqlite_stat1"), "fixture must stay statistics-free like HQ")
            let placeholders = statement.filter { $0 == "?" }.count
            plan = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + statement,
                                    arguments: StatementArguments(Array(repeating: "parent", count: placeholders)))
                .map { $0["detail"] as String }
        }
        let joined = plan.joined(separator: "\n")
        XCTAssertTrue(joined.contains("MULTI-INDEX OR"), joined)
        XCTAssertTrue(joined.contains("SEARCH s USING INDEX idx_sessions_parent"), joined)
        XCTAssertTrue(joined.contains("SEARCH s USING INDEX idx_sessions_suggested_parent"), joined)
        XCTAssertFalse(joined.contains("idx_sessions_visible"), joined)
        XCTAssertFalse(joined.contains("idx_sessions_source"), joined)
        XCTAssertFalse(joined.contains("SCAN s"), joined)
        XCTAssertFalse(joined.contains("SCAN i"), joined)
    }

    private final class TracedStatements: @unchecked Sendable {
        private let lock = NSLock()
        private var statements: [String] = []
        func record(_ sql: String) { lock.withLock { statements.append(sql) } }
        var values: [String] { lock.withLock { statements } }
    }

    func testMissingHiddenSkipParentDoesNotRevealChildren() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "visible-parent", start: "2026-09-03 12:00:00")
        try fixture.seedBoundSession(id: "hidden-parent", start: "2026-09-03 11:00:00",
                                     nativeID: "native-hidden-parent", hidden: true)
        try fixture.seedBoundSession(id: "skip-parent", start: "2026-09-03 10:00:00",
                                     nativeID: "native-skip-parent", tier: "skip")
        try fixture.seedBoundSession(id: "hidden-child", start: "2026-09-03 09:00:00",
                                     nativeID: "native-hidden-child", parent: "hidden-parent")
        try fixture.seedBoundSession(id: "skip-parent-child", start: "2026-09-03 08:00:00",
                                     nativeID: "native-skip-parent-child", parent: "skip-parent")
        let producer = try fixture.producer()
        defer { try? producer.stop() }

        for parent in ["missing-parent", "hidden-parent", "skip-parent"] {
            do {
                let page = try await producer.children(
                    try EngramServiceWebChildrenRequest(sessionId: parent, limit: 20),
                    requestId: requestId, deadline: fixture.deadline())
                XCTFail("parent \(parent) must not publish children: \(page.items.map(\.session.sessionId))")
            } catch {
                XCTAssertEqual(error as? ServiceWebMetadataError, .unavailable, parent)
            }
        }
        let visible = try await producer.children(
            try EngramServiceWebChildrenRequest(sessionId: "visible-parent", limit: 20),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(visible.items.map(\.session.sessionId), [])
    }
}
