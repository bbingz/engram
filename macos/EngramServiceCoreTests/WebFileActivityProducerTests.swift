import Foundation
import GRDB
import XCTest
@testable import EngramServiceCore

final class WebFileActivityProducerTests: XCTestCase {
    private let requestID = "AAAAAAAA-0000-4000-8000-000000000189"
    private let alphaPath = "/private/alpha/macos/Core/App.swift"
    private let betaPath = "/private/beta/macos/Core/App.swift"
    private let helperPath = "/tmp/other/Helper.swift"

    func testPagingRetainsFullTotalsAndExcludesUnavailableSessions() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let first = try await producer.fileActivity(.init(limit: 1), requestId: requestID, deadline: fixture.deadline())
        XCTAssertEqual(first.totalFiles, 3)
        XCTAssertEqual(first.totalOperations, 12)
        XCTAssertEqual(first.items.map(\.label), ["alpha › macos › Core › App.swift"])
        XCTAssertEqual(first.items.first?.readCount, 5)
        XCTAssertEqual(first.items.first?.editCount, 3)
        XCTAssertEqual(first.items.first?.writeCount, 1)
        XCTAssertEqual(first.items.first?.sessionCount, 2)
        let second = try await producer.fileActivity(
            .init(limit: 1, snapshotId: first.snapshotId, cursor: try XCTUnwrap(first.nextCursor)),
            requestId: requestID, deadline: fixture.deadline())
        XCTAssertEqual(second.totalFiles, 3)
        XCTAssertEqual(second.totalOperations, 12)
        XCTAssertEqual(second.items.map(\.label), ["beta › macos › Core › App.swift"])
        XCTAssertEqual(second.items.first?.readCount, 2)
        XCTAssertNotNil(second.nextCursor)
    }

    func testSameBasenameDistinctPathsStaySeparateAndOmitHostLocators() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let page = try await producer.fileActivity(.init(), requestId: requestID, deadline: fixture.deadline())
        XCTAssertEqual(page.totalFiles, 3)
        XCTAssertEqual(Set(page.items.map(\.label)), [
            "alpha › macos › Core › App.swift",
            "beta › macos › Core › App.swift",
            "other › Helper.swift",
        ])
        XCTAssertEqual(Set(page.items.map(\.key)).count, 3)
        let encoded = String(decoding: try JSONEncoder().encode(page), as: UTF8.self)
        for locator in [alphaPath, betaPath, helperPath, "/private/", "/tmp/", "\\", "~"] {
            XCTAssertFalse(encoded.contains(locator), locator)
        }
        XCTAssertFalse(encoded.contains("/"), "safeText rejects slashes; breadcrumbs must not reintroduce them")
    }

    func testProjectSubstringAndLatestActivityDateFiltersMatchLegacyBehavior() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let page = try await producer.fileActivity(.init(project: "alp", since: "2026-09-03", until: "2026-09-03"),
            requestId: requestID, deadline: fixture.deadline())
        XCTAssertEqual(page.totalOperations, 9, "The first session ended on September 3 despite starting earlier")
        XCTAssertEqual(page.totalFiles, 2)
        let literal = try await producer.fileActivity(.init(project: "%"), requestId: requestID, deadline: fixture.deadline())
        XCTAssertEqual(literal.totalFiles, 0, "Project wildcards are literal user input")
        XCTAssertEqual(literal.totalOperations, 0)
    }

    func testContinuedPageRejectsRevokedVisibility() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let first = try await producer.fileActivity(.init(limit: 1), requestId: requestID, deadline: fixture.deadline())
        try fixture.write { db in try db.execute(sql: "UPDATE sessions SET hidden_at = '2026-09-13' WHERE id = 'one'") }
        do {
            _ = try await producer.fileActivity(
                .init(limit: 1, snapshotId: first.snapshotId, cursor: try XCTUnwrap(first.nextCursor)),
                requestId: requestID, deadline: fixture.deadline())
            XCTFail("A stale authorized aggregate must not be released")
        } catch { XCTAssertEqual(error as? ServiceWebMetadataError, .stale) }
    }

    /// HQ regression: after `session_files` was backfilled (190k rows), the
    /// Files view returned 503 at the 2s deadline. The statement's
    /// `ORDER BY s.id, file_path, action` sorted the joined rows in a temp
    /// B-tree (0.46s of a 0.50s statement) twice per request, and every
    /// distinct path paid the redaction-based label and the SHA-256 key twice.
    /// The statement now has no ORDER BY, group authority is a digest over the
    /// sorted per-row digests, and paging still holds when the same rows come
    /// back in another physical order.
    func testFileActivityStatementIsUnsortedAndAuthorityIgnoresRowOrder_repro() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let statements = TracedStatements()
        let producer = try fixture.producer(hooks: .init(prepareDatabase: { db in
            db.trace(options: .statement) { event in
                if case .statement(let statement) = event { statements.record(statement.sql) }
            }
        }))
        defer { try? producer.stop() }
        let first = try await producer.fileActivity(.init(limit: 1), requestId: requestID, deadline: fixture.deadline())
        XCTAssertEqual(first.items.map(\.label), ["alpha › macos › Core › App.swift"])
        let fileStatements = statements.values.filter { $0.contains("FROM session_files f") }
        XCTAssertFalse(fileStatements.isEmpty)
        for statement in fileStatements {
            XCTAssertFalse(statement.uppercased().contains("ORDER BY"), statement)
        }

        // Same rows, reversed insertion order and fresh rowids.
        try fixture.write { db in
            let rows = try Row.fetchAll(db, sql: "SELECT session_id, file_path, action, count FROM session_files ORDER BY rowid")
            try db.execute(sql: "DELETE FROM session_files")
            for row in rows.reversed() {
                try db.execute(sql: "INSERT INTO session_files(session_id, file_path, action, count) VALUES (?, ?, ?, ?)",
                               arguments: [row["session_id"] as String, row["file_path"] as String,
                                           row["action"] as String, row["count"] as Int])
            }
        }
        let second = try await producer.fileActivity(
            .init(limit: 1, snapshotId: first.snapshotId, cursor: try XCTUnwrap(first.nextCursor)),
            requestId: requestID, deadline: fixture.deadline())
        XCTAssertEqual(second.items.map(\.label), ["beta › macos › Core › App.swift"])
        XCTAssertEqual(second.totalFiles, 3)
        XCTAssertEqual(second.totalOperations, 12)
    }

    private final class TracedStatements: @unchecked Sendable {
        private let lock = NSLock()
        private var statements: [String] = []
        func record(_ sql: String) { lock.withLock { statements.append(sql) } }
        var values: [String] { lock.withLock { statements } }
    }

    func testMissingSessionFilesTableIsUnavailableNotZero() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        try fixture.write { db in try db.execute(sql: "DROP TABLE session_files") }
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        do {
            _ = try await producer.fileActivity(.init(), requestId: requestID, deadline: fixture.deadline())
            XCTFail("Omitted file telemetry must not look like a measured empty set")
        } catch { XCTAssertEqual(error as? ServiceWebMetadataError, .unavailable) }
    }

    private func fixture() throws -> MetadataSQLFixture {
        let fixture = try MetadataSQLFixture()
        try fixture.migrate(); try fixture.seedRegistry()
        for (id, project, tier, hidden, parent) in [
            ("one", "/private/alpha", "normal", false, nil),
            ("two", "/private/alpha", "normal", false, nil),
            ("three", "/private/beta", "normal", false, nil),
            ("hidden", "/private/alpha", "normal", true, nil),
            ("skip", "/private/alpha", "skip", false, nil),
            ("agent", "/private/alpha", "normal", false, "one"),
        ] as [(String, String, String, Bool, String?)] {
            try fixture.seedBoundSession(id: id, start: "2026-09-01 12:00:00", nativeID: "native-\(id)",
                                         project: project, tier: tier, hidden: hidden, parent: parent)
        }
        try fixture.seedLocalSession(id: "unbound")
        try fixture.write { db in
            try db.execute(sql: "UPDATE sessions SET end_time = '2026-09-03 12:00:00' WHERE id = 'one'")
            for (id, path, action, count) in [
                ("one", alphaPath, "read", 5), ("one", alphaPath, "edit", 3), ("one", helperPath, "write", 1),
                ("two", alphaPath, "write", 1), ("three", betaPath, "read", 2),
                ("hidden", alphaPath, "read", 99), ("skip", alphaPath, "read", 99),
                ("unbound", alphaPath, "read", 99), ("agent", alphaPath, "read", 99),
            ] as [(String, String, String, Int)] {
                try db.execute(sql: "INSERT INTO session_files(session_id, file_path, action, count) VALUES (?, ?, ?, ?)",
                               arguments: [id, path, action, count])
            }
        }
        return fixture
    }
}
