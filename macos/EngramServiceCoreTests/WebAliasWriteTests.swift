import Foundation
import GRDB
import XCTest
@testable import EngramCoreWrite
@testable import EngramServiceCore

final class WebAliasWriteTests: XCTestCase {
    private let rawProject = "/Users/fixture/engram"
    private let rawAlias = "/old/engram"
    private let siblingAlias = "/keep/path"
    private let siblingCanonical = "/Users/fixture/other"

    func testAliasActorsReachAuditThroughCapabilitySocketAndDispatcher_repro() async throws {
        let env = try prepared(project: rawProject)
        defer { env.tearDown() }
        let runtime = URL(fileURLWithPath: "/tmp/eg-alias-audit-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: runtime) }
        let gate = try ServiceWriterGate(databasePath: env.fixture.path, runtimeDirectory: runtime)
        let handler = EngramServiceCommandHandler(writerGate: gate, webMetadataProducer: env.producer)
        let socket = runtime.appendingPathComponent("service.sock").path
        let server = UnixSocketServiceServer(socketPath: socket) { await handler.handle($0) }
        try server.start()
        defer { server.stop() }
        let client = try EngramServiceWebWriteClient(socketPath: socket)
        let canonical = try XCTUnwrap(EngramServiceWebWriteValidation.publishedProjectKey(rawProject))
        let alias = try XCTUnwrap(EngramServiceWebWriteValidation.publishedProjectKey(rawAlias))
        let added = try await client.addAlias(decode([
            "alias": rawAlias, "canonical": canonical, "actor": "editor@example.com",
        ]))
        XCTAssertEqual(added.changed, 1)
        let removed = try await client.removeAlias(decode([
            "alias": alias, "canonical": canonical, "actor": "remover@example.com",
        ]))
        XCTAssertEqual(removed.changed, 1)
        _ = try await client.addAlias(EngramServiceWebAddAliasRequest(canonical: canonical, alias: rawAlias))
        XCTAssertEqual(try auditRows(env.writer).map { $0["actor"] as String },
                       ["editor@example.com", "remover@example.com", "web-editor"])
        try env.writer.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_alias_audit BEFORE INSERT ON web_alias_audit_log
                BEGIN SELECT RAISE(ABORT, 'private database detail'); END;
                """)
        }
        do {
            _ = try await client.removeAlias(EngramServiceWebRemoveAliasRequest(alias: alias, canonical: canonical))
            XCTFail("Audit failure must not become successful removal")
        } catch {
            XCTAssertEqual(error as? EngramServiceWebWriteClientError, .unavailable)
        }
        XCTAssertEqual(try pairKeys(env.writer), [rawAlias + "\u{1E}" + rawProject])
        XCTAssertEqual(try auditRows(env.writer).count, 3)
    }

    func testAliasAuditRecordsOnlyTransitionsAndPublishedIdentities_repro() throws {
        let env = try prepared(project: rawProject)
        defer { env.tearDown() }
        try insertSibling(env.writer)
        let canonical = try XCTUnwrap(EngramServiceWebWriteValidation.publishedProjectKey(rawProject))
        let alias = try XCTUnwrap(EngramServiceWebWriteValidation.publishedProjectKey(rawAlias))
        let add: EngramServiceWebAddAliasRequest = try decode([
            "alias": rawAlias, "canonical": canonical, "actor": "editor@example.com",
        ])
        XCTAssertEqual(try env.producer.addProjectAlias(add, writer: env.writer).changed, 1)
        XCTAssertEqual(try env.producer.addProjectAlias(add, writer: env.writer).changed, 0)
        let remove: EngramServiceWebRemoveAliasRequest = try decode([
            "alias": alias, "canonical": canonical, "actor": "remover@example.com",
        ])
        XCTAssertEqual(try env.producer.removeProjectAlias(remove, writer: env.writer).changed, 1)
        XCTAssertEqual(try env.producer.removeProjectAlias(remove, writer: env.writer).changed, 0)
        _ = try env.producer.addProjectAlias(
            EngramServiceWebAddAliasRequest(canonical: canonical, alias: rawAlias), writer: env.writer
        )
        let rows = try auditRows(env.writer)
        XCTAssertEqual(rows.map { $0["actor"] as String }, ["editor@example.com", "remover@example.com", "web-editor"])
        XCTAssertEqual(rows.map { $0["action"] as String }, ["add", "remove", "add"])
        XCTAssertEqual(rows.map { $0["alias"] as String }, [alias, alias, alias])
        XCTAssertEqual(rows.map { $0["canonical"] as String }, [canonical, canonical, canonical])
        for row in rows {
            XCTAssertFalse((row["created_at"] as String).isEmpty)
        }
        XCTAssertEqual(try pairKeys(env.writer), [
            siblingAlias + "\u{1E}" + siblingCanonical, rawAlias + "\u{1E}" + rawProject,
        ])
        let rejected: EngramServiceWebAddAliasRequest = try decode(["alias": rawAlias, "canonical": "missing"])
        XCTAssertThrowsError(try env.producer.addProjectAlias(rejected, writer: env.writer))
        XCTAssertEqual(try auditRows(env.writer).count, 3)
    }

    func testAliasAuditRejectsInvalidActorDuringDecoding_repro() throws {
        for actor in ["", " editor", "editor\n", "a b", "\"", "\\", "中", String(repeating: "a", count: 255)] {
            let data = try JSONSerialization.data(withJSONObject: [
                "alias": "old", "canonical": "new", "actor": actor,
            ])
            XCTAssertThrowsError(try JSONDecoder().decode(EngramServiceWebAddAliasRequest.self, from: data), actor)
            XCTAssertThrowsError(try JSONDecoder().decode(EngramServiceWebRemoveAliasRequest.self, from: data), actor)
        }
    }

    func testAliasAuditInsertFailureRollsBackAddAndRemove_repro() throws {
        let env = try prepared(project: rawProject)
        defer { env.tearDown() }
        let canonical = try XCTUnwrap(EngramServiceWebWriteValidation.publishedProjectKey(rawProject))
        let alias = try XCTUnwrap(EngramServiceWebWriteValidation.publishedProjectKey(rawAlias))
        let add = try EngramServiceWebAddAliasRequest(canonical: canonical, alias: rawAlias)
        try env.writer.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_alias_audit BEFORE INSERT ON web_alias_audit_log
                BEGIN SELECT RAISE(ABORT, 'injected audit failure'); END;
                """)
        }
        XCTAssertThrowsError(try env.producer.addProjectAlias(add, writer: env.writer))
        XCTAssertEqual(try pairKeys(env.writer), [])
        XCTAssertEqual(try auditRows(env.writer).count, 0)
        try env.writer.write { try $0.execute(sql: "DROP TRIGGER fail_alias_audit") }
        _ = try env.producer.addProjectAlias(add, writer: env.writer)
        try env.writer.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_alias_audit BEFORE INSERT ON web_alias_audit_log
                BEGIN SELECT RAISE(ABORT, 'injected audit failure'); END;
                """)
        }
        XCTAssertThrowsError(try env.producer.removeProjectAlias(
            EngramServiceWebRemoveAliasRequest(alias: alias, canonical: canonical), writer: env.writer
        ))
        XCTAssertEqual(try pairKeys(env.writer), [rawAlias + "\u{1E}" + rawProject])
        XCTAssertEqual(try auditRows(env.writer).count, 1)
    }

    func testAliasAuditRetentionAndPruningFailureAreTransactional_repro() throws {
        let env = try prepared(project: rawProject)
        defer { env.tearDown() }
        let canonical = try XCTUnwrap(EngramServiceWebWriteValidation.publishedProjectKey(rawProject))
        let add = try EngramServiceWebAddAliasRequest(canonical: canonical, alias: rawAlias)
        try env.writer.write { db in
            try db.execute(sql: """
                WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x + 1 FROM n WHERE x < 10000)
                INSERT INTO web_alias_audit_log (action, actor, alias, canonical, created_at)
                SELECT 'add', 'seed', 'old', 'new',
                    CASE WHEN x = 1 THEN '2099-01-01T00:00:00Z' ELSE '2000-01-01T00:00:00Z' END FROM n;
                CREATE TRIGGER fail_alias_prune BEFORE DELETE ON web_alias_audit_log
                BEGIN SELECT RAISE(ABORT, 'injected prune failure'); END;
                """)
        }
        XCTAssertThrowsError(try env.producer.addProjectAlias(add, writer: env.writer))
        XCTAssertEqual(try pairKeys(env.writer), [])
        XCTAssertEqual(try auditRows(env.writer).count, 10_000)
        try env.writer.write { try $0.execute(sql: "DROP TRIGGER fail_alias_prune") }
        _ = try env.producer.addProjectAlias(add, writer: env.writer)
        let rows = try auditRows(env.writer)
        XCTAssertEqual(rows.count, 10_000)
        XCTAssertEqual(rows.first?["id"] as Int?, 2, "Retention uses insertion order despite clock rollback")
        XCTAssertEqual(rows.last?["actor"] as String?, "web-editor")
        XCTAssertEqual(try env.producer.addProjectAlias(add, writer: env.writer).changed, 0)
        XCTAssertEqual(try auditRows(env.writer).map { $0["id"] as Int }, rows.map { $0["id"] as Int })
    }

    private func decode<T: Decodable>(_ object: [String: String]) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func auditRows(_ writer: EngramDatabaseWriter) throws -> [Row] {
        try writer.read { try Row.fetchAll($0, sql: "SELECT * FROM web_alias_audit_log ORDER BY id") }
    }

    func testAddStoresPathShapedAliasAgainstAuthorizedRawCanonical() throws {
        let env = try prepared(project: rawProject)
        defer { env.tearDown() }
        try insertSibling(env.writer)
        let published = try XCTUnwrap(EngramServiceWebWriteValidation.publishedProjectKey(rawProject))
        let result = try env.producer.addProjectAlias(
            EngramServiceWebAddAliasRequest(canonical: published, alias: rawAlias),
            writer: env.writer
        )
        XCTAssertEqual(result.action, "add")
        XCTAssertEqual(result.changed, 1)
        XCTAssertEqual(result.canonical, published)
        XCTAssertEqual(result.alias, EngramServiceWebWriteValidation.publishedProjectKey(rawAlias))
        XCTAssertEqual(try pairKeys(env.writer), [
            siblingAlias + "\u{1E}" + siblingCanonical,
            rawAlias + "\u{1E}" + rawProject,
        ])
    }

    func testAddIsIdempotentAndDoesNotRewriteSiblingPathRows() throws {
        let env = try prepared(project: rawProject)
        defer { env.tearDown() }
        try insertSibling(env.writer)
        let published = try XCTUnwrap(EngramServiceWebWriteValidation.publishedProjectKey(rawProject))
        let request = try EngramServiceWebAddAliasRequest(canonical: published, alias: rawAlias)
        XCTAssertEqual(try env.producer.addProjectAlias(request, writer: env.writer).changed, 1)
        XCTAssertEqual(try env.producer.addProjectAlias(request, writer: env.writer).changed, 0)
        XCTAssertEqual(try pairKeys(env.writer), [
            siblingAlias + "\u{1E}" + siblingCanonical,
            rawAlias + "\u{1E}" + rawProject,
        ])
    }

    func testLiteProjectAdmitsAdd() throws {
        let env = try prepared(project: rawProject, tier: "lite")
        defer { env.tearDown() }
        let published = try XCTUnwrap(EngramServiceWebWriteValidation.publishedProjectKey(rawProject))
        let result = try env.producer.addProjectAlias(
            EngramServiceWebAddAliasRequest(canonical: published, alias: rawAlias),
            writer: env.writer
        )
        XCTAssertEqual(result.changed, 1)
        XCTAssertEqual(try pairKeys(env.writer), [rawAlias + "\u{1E}" + rawProject])
    }

    func testHiddenSkipAndUnknownCanonicalAreRejected() throws {
        for env in [
            try prepared(project: rawProject, hidden: true),
            try prepared(project: rawProject, tier: "skip"),
            try prepared(project: rawProject),
        ] {
            defer { env.tearDown() }
            let canonical: String
            if env.hidden || env.tier == "skip" {
                canonical = try XCTUnwrap(EngramServiceWebWriteValidation.publishedProjectKey(rawProject))
            } else {
                canonical = "missing_project"
            }
            XCTAssertThrowsError(
                try env.producer.addProjectAlias(
                    EngramServiceWebAddAliasRequest(canonical: canonical, alias: rawAlias),
                    writer: env.writer
                )
            ) { error in
                XCTAssertEqual(error as? ServiceWebMetadataError, .invalidRequest)
            }
            XCTAssertEqual(try pairKeys(env.writer), [])
        }
    }

    func testRemoveDeletesExactRawPairAndLeavesSiblingIntact() throws {
        let env = try prepared(project: rawProject)
        defer { env.tearDown() }
        try insertSibling(env.writer)
        let publishedProject = try XCTUnwrap(EngramServiceWebWriteValidation.publishedProjectKey(rawProject))
        XCTAssertEqual(
            try env.producer.addProjectAlias(
                EngramServiceWebAddAliasRequest(canonical: publishedProject, alias: rawAlias),
                writer: env.writer
            ).changed,
            1
        )
        let publishedAlias = try XCTUnwrap(EngramServiceWebWriteValidation.publishedProjectKey(rawAlias))
        let removed = try env.producer.removeProjectAlias(
            EngramServiceWebRemoveAliasRequest(alias: publishedAlias, canonical: publishedProject),
            writer: env.writer
        )
        XCTAssertEqual(removed.action, "remove")
        XCTAssertEqual(removed.changed, 1)
        XCTAssertEqual(removed.alias, publishedAlias)
        XCTAssertEqual(removed.canonical, publishedProject)
        XCTAssertEqual(try pairKeys(env.writer), [siblingAlias + "\u{1E}" + siblingCanonical])
    }

    func testRemoveMissingPublishedPairIsChangedZeroWithoutRewritingRows() throws {
        let env = try prepared(project: rawProject)
        defer { env.tearDown() }
        try insertSibling(env.writer)
        let publishedProject = try XCTUnwrap(EngramServiceWebWriteValidation.publishedProjectKey(rawProject))
        let missing = try XCTUnwrap(EngramServiceWebWriteValidation.publishedProjectKey("/missing/alias"))
        let removed = try env.producer.removeProjectAlias(
            EngramServiceWebRemoveAliasRequest(alias: missing, canonical: publishedProject),
            writer: env.writer
        )
        XCTAssertEqual(removed.changed, 0)
        XCTAssertEqual(try pairKeys(env.writer), [siblingAlias + "\u{1E}" + siblingCanonical])
    }

    func testAliasWriteIgnoresCancelledMetadataReadRelay_repro() throws {
        let env = try prepared(project: rawProject)
        defer { env.tearDown() }
        let published = try XCTUnwrap(EngramServiceWebWriteValidation.publishedProjectKey(rawProject))
        let result = try env.producer.withPinnedCancelledReadRelay {
            try env.producer.addProjectAlias(
                EngramServiceWebAddAliasRequest(canonical: published, alias: rawAlias),
                writer: env.writer
            )
        }
        XCTAssertEqual(result.changed, 1)
        XCTAssertEqual(try pairKeys(env.writer), [rawAlias + "\u{1E}" + rawProject])
    }

    private struct Env {
        let fixture: MetadataSQLFixture
        let producer: ServiceWebMetadataProducer
        let writer: EngramDatabaseWriter
        let tier: String
        let hidden: Bool
        func tearDown() {
            try? producer.stop()
            fixture.remove()
        }
    }

    private func prepared(project: String, tier: String = "normal", hidden: Bool = false) throws -> Env {
        let fixture = try MetadataSQLFixture()
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(
            id: "bound", start: "2026-09-01 12:00:00", project: project, tier: tier, hidden: hidden
        )
        return Env(
            fixture: fixture,
            producer: try fixture.producer(),
            writer: try EngramDatabaseWriter(path: fixture.path),
            tier: tier,
            hidden: hidden
        )
    }

    private func insertSibling(_ writer: EngramDatabaseWriter) throws {
        try writer.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS project_aliases (
                  alias TEXT NOT NULL,
                  canonical TEXT NOT NULL,
                  created_at TEXT NOT NULL DEFAULT (datetime('now')),
                  PRIMARY KEY (alias, canonical)
                );
                """)
            try db.execute(
                sql: "INSERT INTO project_aliases (alias, canonical) VALUES (?, ?)",
                arguments: [siblingAlias, siblingCanonical]
            )
        }
    }

    private func pairKeys(_ writer: EngramDatabaseWriter) throws -> [String] {
        try writer.read { db in
            guard try db.tableExists("project_aliases") else { return [] }
            return try Row.fetchAll(db, sql: "SELECT alias, canonical FROM project_aliases ORDER BY alias").map {
                ($0["alias"] as String? ?? "") + "\u{1E}" + ($0["canonical"] as String? ?? "")
            }
        }
    }
}
