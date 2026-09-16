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
