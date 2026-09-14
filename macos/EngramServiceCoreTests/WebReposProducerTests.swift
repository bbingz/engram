import Foundation
import GRDB
import XCTest
@testable import EngramServiceCore

final class WebReposProducerTests: XCTestCase {
    private let requestID = "AAAAAAAA-0000-4000-8000-000000000190"
    private let secretPath = "/Users/alice/secret-repo"
    private let alphaPath = "/tmp/a"
    private let muPath = "/tmp/m"
    private let parentPath = "/tmp/parent"
    private let nestedPath = "/tmp/parent/nested"
    private let orphanPath = "/tmp/orphan"
    private let aliasCwd = "/work/link"
    private let token = "sk-abcdefghijklmnopqrstuvwxyz"

    func testPagingRetainsFullCountAndStoredObservationOrder() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let first = try await producer.repos(.init(limit: 1), requestId: requestID, deadline: fixture.deadline())
        XCTAssertEqual(first.scope, "serverFilesystem")
        XCTAssertEqual(first.totalRepos, 6)
        XCTAssertEqual(first.items.count, 1)
        XCTAssertEqual(first.items.first?.name, "secret-repo")
        XCTAssertEqual(first.items.first?.branch, "feat/foo")
        XCTAssertEqual(first.items.first?.dirtyCount, 1)
        XCTAssertEqual(first.items.first?.untrackedCount, 2)
        XCTAssertEqual(first.items.first?.unpushedCount, 3)
        XCTAssertEqual(first.items.first?.lastCommitHash, "abcdef1234567")
        XCTAssertEqual(first.items.first?.sessionCount, 1)
        XCTAssertNotNil(first.items.first?.lastCommitAt)
        XCTAssertNotNil(first.items.first?.probedAt)
        XCTAssertNotNil(first.nextCursor)
        let second = try await producer.repos(
            .init(limit: 1, snapshotId: first.snapshotId, cursor: try XCTUnwrap(first.nextCursor)),
            requestId: requestID, deadline: fixture.deadline())
        XCTAssertEqual(second.totalRepos, 6)
        XCTAssertEqual(second.items.first?.name, "alpha")
        XCTAssertEqual(second.items.first?.sessionCount, 3)
        XCTAssertEqual(second.items.first?.lastCommitAt, first.items.first?.lastCommitAt.map { $0 - 86_400 })
        let third = try await producer.repos(
            .init(limit: 1, snapshotId: second.snapshotId, cursor: try XCTUnwrap(second.nextCursor)),
            requestId: requestID, deadline: fixture.deadline())
        XCTAssertEqual(third.totalRepos, 6)
        XCTAssertEqual(third.items.first?.name, "m-repo")
        XCTAssertEqual(third.items.first?.sessionCount, 0)
        XCTAssertEqual(third.items.first?.lastCommitAt, second.items.first?.lastCommitAt)
        XCTAssertNil(third.items.first?.lastCommitHash)
        XCTAssertNotNil(third.nextCursor)
        var previous = third
        for expected in [("parent", Int64(1), false), ("nested", 1, false), ("orphan", 0, true)] {
            let page = try await producer.repos(
                .init(limit: 1, snapshotId: previous.snapshotId, cursor: try XCTUnwrap(previous.nextCursor)),
                requestId: requestID, deadline: fixture.deadline())
            XCTAssertEqual(page.snapshotId, first.snapshotId)
            XCTAssertEqual(page.totalRepos, 6)
            XCTAssertEqual(page.items.first?.name, expected.0)
            XCTAssertEqual(page.items.first?.sessionCount, expected.1)
            if expected.2 { XCTAssertNil(page.items.first?.lastCommitAt) }
            previous = page
        }
        XCTAssertNil(previous.nextCursor)
    }

    func testSameNameDistinctKeysOmitLocatorsAndIgnoreStoredSessionCount() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let page = try await producer.repos(.init(), requestId: requestID, deadline: fixture.deadline())
        XCTAssertEqual(page.totalRepos, 6)
        XCTAssertEqual(page.items.map(\.name).filter { $0 == "alpha" || $0 == "secret-repo" }.count, 2)
        XCTAssertEqual(Set(page.items.map(\.key)).count, 6)
        XCTAssertTrue(page.items.allSatisfy { $0.key.hasPrefix("p.") && $0.key.utf8.count == 66 })
        let secret = try XCTUnwrap(page.items.first { $0.name == "secret-repo" })
        XCTAssertEqual(secret.sessionCount, 1, "Stored git_repos.session_count=99 must not leak hidden or historical counts")
        XCTAssertEqual(secret.branch, "feat/foo")
        XCTAssertEqual(secret.lastCommitMessage, "token: [REDACTED]")
        XCTAssertFalse((secret.lastCommitMessage ?? "").contains(token))
        for item in page.items {
            XCTAssertFalse(item.key.contains("/"))
            XCTAssertFalse(item.name.contains("/"))
            XCTAssertFalse((item.branch ?? "").contains(secretPath))
            XCTAssertFalse((item.lastCommitMessage ?? "").contains(token))
        }
        let encoded = String(decoding: try JSONEncoder().encode(page), as: UTF8.self)
        for locator in [secretPath, alphaPath, muPath, parentPath, nestedPath, orphanPath, aliasCwd,
                        "/Users/alice", "/Users/fixture", "/tmp/", "/work/", token] {
            XCTAssertFalse(encoded.contains(locator), locator)
        }
    }

    func testNestedLongestPathAndStoredAliasAssociateOnlyVisibleSessions() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let page = try await producer.repos(.init(), requestId: requestID, deadline: fixture.deadline())
        let counts = Dictionary(uniqueKeysWithValues: page.items.map { ($0.name, $0.sessionCount) })
        XCTAssertEqual(counts["secret-repo"], 1)
        XCTAssertEqual(counts["alpha"], 3)
        XCTAssertEqual(counts["m-repo"], 0)
        XCTAssertEqual(counts["parent"], 1)
        XCTAssertEqual(counts["nested"], 1)
        XCTAssertEqual(counts["orphan"], 0)
    }

    func testContinuedPageRejectsRevokedVisibility() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let first = try await producer.repos(.init(limit: 1), requestId: requestID, deadline: fixture.deadline())
        try fixture.write { db in try db.execute(sql: "UPDATE sessions SET hidden_at = '2026-09-13' WHERE id = 'one'") }
        do {
            _ = try await producer.repos(
                .init(limit: 1, snapshotId: first.snapshotId, cursor: try XCTUnwrap(first.nextCursor)),
                requestId: requestID, deadline: fixture.deadline())
            XCTFail("A stale authorized aggregate must not be released")
        } catch { XCTAssertEqual(error as? ServiceWebMetadataError, .stale) }
    }

    func testMissingGitReposTableIsUnavailableNotZero() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        try fixture.write { db in
            try db.execute(sql: "DROP TABLE git_repo_cwd_aliases")
            try db.execute(sql: "DROP TABLE git_repos")
        }
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        do {
            _ = try await producer.repos(.init(), requestId: requestID, deadline: fixture.deadline())
            XCTFail("Omitted repository telemetry must not look like a measured empty set")
        } catch { XCTAssertEqual(error as? ServiceWebMetadataError, .unavailable) }
    }

    func testEmptyGitReposTableIsEmptyObservationsNotUnavailable() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate(); try fixture.seedRegistry()
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let page = try await producer.repos(.init(), requestId: requestID, deadline: fixture.deadline())
        XCTAssertEqual(page.scope, "serverFilesystem")
        XCTAssertEqual(page.totalRepos, 0)
        XCTAssertEqual(page.items, [])
        XCTAssertNil(page.nextCursor)
    }

    func testUnknownCountStorageIsUnavailable() async throws {
        let mutations: [(String, String, [any DatabaseValueConvertible])] = [
            ("blob dirty_count", "UPDATE git_repos SET dirty_count = ? WHERE path = ?", [Data([0]), secretPath]),
            ("null dirty_count", "UPDATE git_repos SET dirty_count = NULL WHERE path = ?", [secretPath]),
            ("null untracked_count", "UPDATE git_repos SET untracked_count = NULL WHERE path = ?", [secretPath]),
            ("null unpushed_count", "UPDATE git_repos SET unpushed_count = NULL WHERE path = ?", [secretPath]),
        ]
        for (label, sql, arguments) in mutations {
            let fixture = try fixture()
            defer { fixture.remove() }
            try fixture.write { db in try db.execute(sql: sql, arguments: StatementArguments(arguments)) }
            let producer = try fixture.producer()
            defer { try? producer.stop() }
            do {
                _ = try await producer.repos(.init(), requestId: requestID, deadline: fixture.deadline())
                XCTFail("\(label) must not publish a clean working tree")
            } catch { XCTAssertEqual(error as? ServiceWebMetadataError, .unavailable, label) }
        }
    }

    private func fixture() throws -> MetadataSQLFixture {
        let fixture = try MetadataSQLFixture()
        try fixture.migrate(); try fixture.seedRegistry()
        for (id, tier, hidden, parent) in [
            ("one", "normal", false, nil),
            ("two", "normal", false, nil),
            ("three", "normal", false, nil),
            ("alias", "normal", false, nil),
            ("parent-s", "normal", false, nil),
            ("nested-s", "normal", false, nil),
            ("hidden", "normal", true, nil),
            ("skip", "skip", false, nil),
            ("agent", "normal", false, "one"),
        ] as [(String, String, Bool, String?)] {
            try fixture.seedBoundSession(id: id, start: "2026-09-01 12:00:00", nativeID: "native-\(id)",
                                         tier: tier, hidden: hidden, parent: parent)
        }
        try fixture.seedLocalSession(id: "unbound")
        try fixture.write { db in
            try db.execute(sql: "UPDATE sessions SET cwd = ? WHERE id IN ('one', 'hidden', 'skip', 'agent', 'unbound')",
                           arguments: [secretPath])
            try db.execute(sql: "UPDATE sessions SET cwd = ? WHERE id = 'two'", arguments: [alphaPath])
            try db.execute(sql: "UPDATE sessions SET cwd = ? WHERE id = 'three'", arguments: [alphaPath + "/src"])
            try db.execute(sql: "UPDATE sessions SET cwd = ? WHERE id = 'alias'", arguments: [aliasCwd])
            try db.execute(sql: "UPDATE sessions SET cwd = ? WHERE id = 'parent-s'", arguments: [parentPath])
            try db.execute(sql: "UPDATE sessions SET cwd = ? WHERE id = 'nested-s'", arguments: [nestedPath + "/src"])
            try insertRepo(db, path: secretPath, name: secretPath, branch: "feat/foo", dirty: 1, untracked: 2, unpushed: 3,
                           hash: "abcdef1234567", message: "token: \(token)",
                           commitAt: "2026-09-03T12:00:00Z", sessions: 99, probedAt: "2026-09-03T13:00:00Z")
            try insertRepo(db, path: alphaPath, name: "alpha", commitAt: "2026-09-02T12:00:00Z")
            try insertRepo(db, path: muPath, name: "m-repo", hash: "not-a-hash", commitAt: "2026-09-02T12:00:00Z")
            try insertRepo(db, path: parentPath, name: "parent", commitAt: "2026-09-01T12:00:00Z")
            try insertRepo(db, path: nestedPath, name: "nested", commitAt: "2026-09-01T11:00:00Z")
            try insertRepo(db, path: orphanPath, name: "orphan")
            try db.execute(sql: """
                INSERT INTO git_repo_cwd_aliases(cwd, real_cwd, repo_path) VALUES (?, ?, ?)
                """, arguments: [aliasCwd, aliasCwd, alphaPath])
        }
        return fixture
    }

    private func insertRepo(
        _ db: Database, path: String, name: String, branch: String? = nil,
        dirty: Int = 0, untracked: Int = 0, unpushed: Int = 0,
        hash: String? = nil, message: String? = nil, commitAt: String? = nil,
        sessions: Int = 0, probedAt: String? = nil
    ) throws {
        try db.execute(sql: """
            INSERT INTO git_repos(
                path, name, branch, dirty_count, untracked_count, unpushed_count,
                last_commit_hash, last_commit_msg, last_commit_at, session_count, probed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [path, name, branch, dirty, untracked, unpushed, hash, message, commitAt, sessions, probedAt])
    }
}
