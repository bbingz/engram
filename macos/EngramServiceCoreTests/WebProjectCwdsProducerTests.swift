import Foundation
import XCTest
@testable import EngramServiceCore

final class WebProjectCwdsProducerTests: XCTestCase {
    private let requestID = "AAAAAAAA-0000-4000-8000-000000000215"
    private let visible = "/Users/alice/Code/engram"
    private let other = "/tmp/visible-cwd"
    private let hiddenPath = "/Users/alice/secret"

    func testAdmittedCwdsPageWithSafeLabelsAndExcludeSkipHiddenDisabled() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        let codexInstance = "DDDDDDDD-0000-4000-8000-000000000004"
        try fixture.seedRegistry(instance: codexInstance, source: .codex)
        try fixture.seedBoundSession(id: "keep", start: "2026-09-01 12:00:00", project: "project_1")
        try fixture.seedBoundSession(id: "lite", start: "2026-09-01 12:01:00", nativeID: "native-lite",
                                     project: "project_1", title: "lite", tier: "lite")
        try fixture.seedBoundSession(id: "skip", start: "2026-09-01 12:02:00", nativeID: "native-skip",
                                     project: "project_1", title: "skip", tier: "skip")
        try fixture.seedBoundSession(id: "hidden", start: "2026-09-01 12:03:00", nativeID: "native-hidden",
                                     project: "project_1", title: "hidden", hidden: true)
        try fixture.seedBoundSession(id: "child", start: "2026-09-01 12:04:00", nativeID: "native-child",
                                     project: "project_1", title: "child", parent: "keep")
        try fixture.seedBoundSession(id: "codex", start: "2026-09-01 12:05:00", nativeID: "native-codex",
                                     instance: codexInstance, source: .codex, project: "project_1")
        try fixture.seedLocalSession(id: "unbound")
        try fixture.write { db in
            try db.execute(sql: "UPDATE sessions SET cwd = ? WHERE id IN ('keep', 'lite')", arguments: [visible])
            try db.execute(sql: "UPDATE sessions SET cwd = ? WHERE id = 'skip'", arguments: [hiddenPath])
            try db.execute(sql: "UPDATE sessions SET cwd = ? WHERE id = 'hidden'", arguments: [hiddenPath])
            try db.execute(sql: "UPDATE sessions SET cwd = ? WHERE id = 'child'", arguments: [other])
            try db.execute(sql: "UPDATE sessions SET cwd = ? WHERE id = 'codex'", arguments: [other])
            try db.execute(sql: "UPDATE sessions SET cwd = ? WHERE id = 'unbound'", arguments: [other])
        }
        let producer = try fixture.producer(policy: {
            .init(parserRevision: "parser-v1", enabledSources: [.claudeCode])
        })
        defer { try? producer.stop() }

        let first = try await producer.projectCwds(
            .init(projectKey: "project_1", limit: 1),
            requestId: requestID,
            deadline: fixture.deadline()
        )
        XCTAssertEqual(first.scope, "captured")
        XCTAssertEqual(first.projectKey, "project_1")
        XCTAssertEqual(first.totalCount, 1)
        XCTAssertEqual(first.items.count, 1)
        XCTAssertNil(first.nextCursor)
        let encoded = String(decoding: try JSONEncoder().encode(first), as: UTF8.self)
        XCTAssertFalse(encoded.contains("/Users/alice"))
        XCTAssertFalse(encoded.contains(visible))
        XCTAssertFalse(encoded.contains(hiddenPath))
        XCTAssertFalse(encoded.contains(other))
        let item = try XCTUnwrap(first.items.first)
        XCTAssertTrue(item.key.hasPrefix("p."))
        XCTAssertFalse(item.label.contains("/"))
        XCTAssertFalse(item.label.contains("~"))
        XCTAssertEqual(item.key, try XCTUnwrap(EngramServiceWebWriteValidation.publishedProjectKey(visible)))
    }

    func testHiddenRevocationDropsCapturedLocation() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "keep", start: "2026-09-01 12:00:00", project: "project_1")
        try fixture.write { db in
            try db.execute(sql: "UPDATE sessions SET cwd = ? WHERE id = 'keep'", arguments: [visible])
        }
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let before = try await producer.projectCwds(
            .init(projectKey: "project_1"),
            requestId: requestID,
            deadline: fixture.deadline()
        )
        XCTAssertEqual(before.totalCount, 1)
        try fixture.write { db in
            try db.execute(sql: "UPDATE sessions SET hidden_at = '2026-09-02 00:00:00' WHERE id = 'keep'")
        }
        let after = try await producer.projectCwds(
            .init(projectKey: "project_1"),
            requestId: requestID,
            deadline: fixture.deadline()
        )
        XCTAssertEqual(after.totalCount, 0)
        XCTAssertEqual(after.items, [])
        XCTAssertEqual(after.scope, "captured")
    }
}
