import Foundation
import GRDB
import XCTest
import EngramCoreRead
@testable import EngramCoreWrite
@testable import EngramServiceCore

final class WebRelationshipWriteTests: XCTestCase {
    func testLinkUnlinkConfirmAndDismissWriteVisibleBoundSessions() throws {
        let env = try prepared()
        defer { env.tearDown() }
        try env.seed("rel-parent", "rel-child", "rel-confirm", "rel-dismiss")
        try env.setSuggestion("rel-confirm", parent: "rel-parent")
        try env.setSuggestion("rel-dismiss", parent: "rel-parent")

        let linked = try EngramServiceCommandHandler.webLinkSession(
            EngramServiceWebLinkRequest(sessionId: "rel-child", parentId: "rel-parent"),
            writer: env.writer, settingsURL: env.settingsURL
        )
        XCTAssertEqual(linked.action, "link")
        XCTAssertEqual(linked.sessionId, "rel-child")
        XCTAssertTrue(linked.ok)
        XCTAssertEqual(try env.parent(of: "rel-child"), "rel-parent")

        let unlinked = try EngramServiceCommandHandler.webUnlinkSession(
            EngramServiceWebUnlinkRequest(sessionId: "rel-child"),
            writer: env.writer, settingsURL: env.settingsURL
        )
        XCTAssertEqual(unlinked.action, "unlink")
        XCTAssertNil(try env.parent(of: "rel-child"))

        let confirmed = try EngramServiceCommandHandler.webConfirmSuggestion(
            EngramServiceWebConfirmSuggestionRequest(
                sessionId: "rel-confirm", suggestedParentId: "rel-parent"
            ),
            writer: env.writer, settingsURL: env.settingsURL
        )
        XCTAssertEqual(confirmed.action, "confirmSuggestion")
        XCTAssertEqual(try env.parent(of: "rel-confirm"), "rel-parent")
        XCTAssertNil(try env.suggestion(of: "rel-confirm"))

        let dismissed = try EngramServiceCommandHandler.webDismissSuggestion(
            EngramServiceWebDismissSuggestionRequest(
                sessionId: "rel-dismiss", suggestedParentId: "rel-parent"
            ),
            writer: env.writer, settingsURL: env.settingsURL
        )
        XCTAssertEqual(dismissed.action, "dismissSuggestion")
        XCTAssertNil(try env.suggestion(of: "rel-dismiss"))
        XCTAssertNil(try env.parent(of: "rel-dismiss"))
    }

    func testInvalidRegistryBindingDoesNotWrite() throws {
        let env = try prepared()
        defer { env.tearDown() }
        try env.seed("rel-parent", "rel-child")
        try env.writer.write { db in
            try db.execute(sql: "UPDATE capture_ingest_source_registry SET parse_format = 'codex'")
        }
        try env.writer.read { db in
            let row = try XCTUnwrap(Row.fetchOne(
                db,
                sql: """
                    SELECT machine_id, source_instance_id FROM capture_ingest_identity_bindings
                    WHERE stored_session_id = 'rel-child'
                    """
            ))
            XCTAssertThrowsError(try CaptureIngestSourceRegistry.binding(
                db, machineID: row["machine_id"], sourceInstanceID: row["source_instance_id"]
            )) {
                XCTAssertEqual($0 as? CaptureIngestSourceRegistryError, .invalidStoredBinding)
            }
        }
        assertUnavailable {
            try EngramServiceCommandHandler.webLinkSession(
                EngramServiceWebLinkRequest(sessionId: "rel-child", parentId: "rel-parent"),
                writer: env.writer, settingsURL: env.settingsURL
            )
        }
        XCTAssertNil(try env.parent(of: "rel-child"))
    }

    func testLinkAndConfirmAuthorizeReplacedParentsBeforeMutation() throws {
        let env = try prepared()
        defer { env.tearDown() }
        try env.seed("rel-old", "rel-new", "rel-child", "rel-confirm")
        XCTAssertEqual(
            try EngramServiceCommandHandler.webLinkSession(
                EngramServiceWebLinkRequest(sessionId: "rel-child", parentId: "rel-old"),
                writer: env.writer, settingsURL: env.settingsURL
            ).action,
            "link"
        )
        try env.fixture.hide("rel-old")
        assertUnavailable {
            try EngramServiceCommandHandler.webLinkSession(
                EngramServiceWebLinkRequest(sessionId: "rel-child", parentId: "rel-new"),
                writer: env.writer, settingsURL: env.settingsURL
            )
        }
        XCTAssertEqual(try env.parent(of: "rel-child"), "rel-old")

        try env.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE sessions
                    SET parent_session_id = 'rel-old', suggested_parent_id = 'rel-new'
                    WHERE id = 'rel-confirm'
                    """
            )
        }
        assertUnavailable {
            try EngramServiceCommandHandler.webConfirmSuggestion(
                EngramServiceWebConfirmSuggestionRequest(
                    sessionId: "rel-confirm", suggestedParentId: "rel-new"
                ),
                writer: env.writer, settingsURL: env.settingsURL
            )
        }
        XCTAssertEqual(try env.parent(of: "rel-confirm"), "rel-old")
        XCTAssertEqual(try env.suggestion(of: "rel-confirm"), "rel-new")
    }

    func testStaleUnlinkConfirmAndDismissDoNotWrite() throws {
        let env = try prepared()
        defer { env.tearDown() }
        try env.seed("rel-parent", "rel-child", "rel-suggest")
        try env.setSuggestion("rel-suggest", parent: "rel-parent")

        assertStale {
            try EngramServiceCommandHandler.webUnlinkSession(
                EngramServiceWebUnlinkRequest(sessionId: "rel-child"),
                writer: env.writer, settingsURL: env.settingsURL
            )
        }
        assertStale {
            try EngramServiceCommandHandler.webUnlinkSession(
                EngramServiceWebUnlinkRequest(sessionId: "rel-suggest"),
                writer: env.writer, settingsURL: env.settingsURL
            )
        }
        XCTAssertEqual(try env.suggestion(of: "rel-suggest"), "rel-parent")

        assertStale {
            try EngramServiceCommandHandler.webConfirmSuggestion(
                EngramServiceWebConfirmSuggestionRequest(
                    sessionId: "rel-suggest", suggestedParentId: "rel-child"
                ),
                writer: env.writer, settingsURL: env.settingsURL
            )
        }
        XCTAssertNil(try env.parent(of: "rel-suggest"))

        assertStale {
            try EngramServiceCommandHandler.webDismissSuggestion(
                EngramServiceWebDismissSuggestionRequest(
                    sessionId: "rel-suggest", suggestedParentId: "rel-child"
                ),
                writer: env.writer, settingsURL: env.settingsURL
            )
        }
        XCTAssertEqual(try env.suggestion(of: "rel-suggest"), "rel-parent")
    }

    func testHiddenSkipUnboundAndEmptyPolicyAreUnavailable() throws {
        let env = try prepared()
        defer { env.tearDown() }
        try env.seed("rel-parent", "rel-child")
        try env.fixture.seedBoundSession(
            id: "rel-hidden", start: "2026-09-01 12:02:00", nativeID: "native-rel-hidden", hidden: true
        )
        try env.fixture.seedBoundSession(
            id: "rel-skip", start: "2026-09-01 12:03:00", nativeID: "native-rel-skip", tier: "skip"
        )
        try env.fixture.seedLocalSession(id: "rel-unbound")
        for child in ["rel-hidden", "rel-skip", "rel-unbound"] {
            assertUnavailable {
                try EngramServiceCommandHandler.webLinkSession(
                    EngramServiceWebLinkRequest(sessionId: child, parentId: "rel-parent"),
                    writer: env.writer, settingsURL: env.settingsURL
                )
            }
        }
        try env.writeSettings(disabled: SourceName.allCases.map(\.rawValue))
        assertUnavailable {
            try EngramServiceCommandHandler.webLinkSession(
                EngramServiceWebLinkRequest(sessionId: "rel-child", parentId: "rel-parent"),
                writer: env.writer, settingsURL: env.settingsURL
            )
        }
        XCTAssertNil(try env.parent(of: "rel-child"))
    }

    func testHiddenOrSkipParentIsUnavailable() throws {
        let env = try prepared()
        defer { env.tearDown() }
        try env.seed("rel-child")
        try env.fixture.seedBoundSession(
            id: "rel-hidden-parent", start: "2026-09-01 12:02:00",
            nativeID: "native-rel-hidden-parent", hidden: true
        )
        try env.fixture.seedBoundSession(
            id: "rel-skip-parent", start: "2026-09-01 12:03:00",
            nativeID: "native-rel-skip-parent", tier: "skip"
        )
        for parent in ["rel-hidden-parent", "rel-skip-parent"] {
            assertUnavailable {
                try EngramServiceCommandHandler.webLinkSession(
                    EngramServiceWebLinkRequest(sessionId: "rel-child", parentId: parent),
                    writer: env.writer, settingsURL: env.settingsURL
                )
            }
        }
        XCTAssertNil(try env.parent(of: "rel-child"))
    }

    func testDepthExceededLinkIsInvalidWithoutWrite() throws {
        let env = try prepared()
        defer { env.tearDown() }
        try env.seed("rel-grand", "rel-child")
        try env.fixture.seedBoundSession(
            id: "rel-mid", start: "2026-09-01 12:02:00", nativeID: "native-rel-mid", parent: "rel-grand"
        )
        assertInvalid {
            try EngramServiceCommandHandler.webLinkSession(
                EngramServiceWebLinkRequest(sessionId: "rel-child", parentId: "rel-mid"),
                writer: env.writer, settingsURL: env.settingsURL
            )
        }
        XCTAssertNil(try env.parent(of: "rel-child"))
    }

    func testUnlinkPreservesDispatchedSkipTier() throws {
        let env = try prepared()
        defer { env.tearDown() }
        try env.seed("rel-parent", "rel-child")
        XCTAssertEqual(
            try EngramServiceCommandHandler.webLinkSession(
                EngramServiceWebLinkRequest(sessionId: "rel-child", parentId: "rel-parent"),
                writer: env.writer, settingsURL: env.settingsURL
            ).action,
            "link"
        )
        try env.writer.write { db in
            try db.execute(sql: "UPDATE sessions SET agent_role = 'dispatched' WHERE id = 'rel-child'")
        }
        XCTAssertEqual(
            try EngramServiceCommandHandler.webUnlinkSession(
                EngramServiceWebUnlinkRequest(sessionId: "rel-child"),
                writer: env.writer, settingsURL: env.settingsURL
            ).action,
            "unlink"
        )
        XCTAssertNil(try env.parent(of: "rel-child"))
        XCTAssertEqual(try env.tier(of: "rel-child"), "skip")
    }

    func testReplacedParentInvalidBindingDoesNotWrite() throws {
        let env = try prepared()
        defer { env.tearDown() }
        let oldMachine = "AAAAAAAA-0000-4000-8000-000000000011"
        let oldInstance = "BBBBBBBB-0000-4000-8000-000000000012"
        try env.fixture.seedRegistry(machine: oldMachine, instance: oldInstance)
        try env.fixture.seedBoundSession(
            id: "rel-old", start: "2026-09-01 12:00:00", nativeID: "native-rel-old",
            machine: oldMachine, instance: oldInstance
        )
        try env.seed("rel-new", "rel-child")
        XCTAssertEqual(
            try EngramServiceCommandHandler.webLinkSession(
                EngramServiceWebLinkRequest(sessionId: "rel-child", parentId: "rel-old"),
                writer: env.writer, settingsURL: env.settingsURL
            ).action,
            "link"
        )
        try env.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE capture_ingest_source_registry
                    SET parse_format = 'codex'
                    WHERE source_instance_id = ?
                    """,
                arguments: [oldInstance]
            )
        }
        assertUnavailable {
            try EngramServiceCommandHandler.webLinkSession(
                EngramServiceWebLinkRequest(sessionId: "rel-child", parentId: "rel-new"),
                writer: env.writer, settingsURL: env.settingsURL
            )
        }
        XCTAssertEqual(try env.parent(of: "rel-child"), "rel-old")
    }

    func testLiteSessionsAdmitLink() throws {
        let env = try prepared()
        defer { env.tearDown() }
        try env.fixture.seedBoundSession(
            id: "rel-parent", start: "2026-09-01 12:00:00", nativeID: "native-rel-parent", tier: "lite"
        )
        try env.fixture.seedBoundSession(
            id: "rel-child", start: "2026-09-01 12:01:00", nativeID: "native-rel-child", tier: "lite"
        )
        let linked = try EngramServiceCommandHandler.webLinkSession(
            EngramServiceWebLinkRequest(sessionId: "rel-child", parentId: "rel-parent"),
            writer: env.writer, settingsURL: env.settingsURL
        )
        XCTAssertEqual(linked.action, "link")
        XCTAssertEqual(try env.parent(of: "rel-child"), "rel-parent")
        XCTAssertEqual(try env.tier(of: "rel-child"), "lite")
    }

    private struct Env {
        let fixture: MetadataSQLFixture
        let writer: EngramDatabaseWriter
        let settingsURL: URL
        func tearDown() { fixture.remove() }

        func seed(_ ids: String...) throws {
            for (index, id) in ids.enumerated() {
                try fixture.seedBoundSession(
                    id: id,
                    start: "2026-09-01 12:0\(index):00",
                    nativeID: "native-\(id)"
                )
            }
        }

        func setSuggestion(_ id: String, parent: String) throws {
            try writer.write { db in
                try db.execute(
                    sql: "UPDATE sessions SET suggested_parent_id = ? WHERE id = ?",
                    arguments: [parent, id]
                )
            }
        }

        func parent(of id: String) throws -> String? { try text("parent_session_id", id) }
        func suggestion(of id: String) throws -> String? { try text("suggested_parent_id", id) }
        func tier(of id: String) throws -> String? { try text("tier", id) }

        func writeSettings(disabled: [String]) throws {
            let document: [String: Any] = [
                "runtimeRole": "index",
                "disabledSources": disabled,
                ArchivedDefaultOffSources.settingsMigrationKey: true,
                "captureIngest": [
                    "enabled": true, "serverID": "hq", "baseURL": "http://127.0.0.1",
                    "credentialID": "hq", "requestTimeout": 0.2, "retryCount": 0,
                ],
            ]
            try JSONSerialization.data(withJSONObject: document).write(to: settingsURL)
            XCTAssertEqual(chmod(settingsURL.path, 0o600), 0)
        }

        private func text(_ column: String, _ id: String) throws -> String? {
            try writer.read { db in
                let value = try String.fetchOne(
                    db, sql: "SELECT \(column) FROM sessions WHERE id = ?", arguments: [id]
                )
                return value?.isEmpty == true ? nil : value
            }
        }
    }

    private func prepared() throws -> Env {
        let fixture = try MetadataSQLFixture()
        try fixture.migrate()
        try fixture.seedRegistry()
        let settingsURL = fixture.directory.appendingPathComponent("settings.json")
        let env = Env(
            fixture: fixture,
            writer: try EngramDatabaseWriter(path: fixture.path),
            settingsURL: settingsURL
        )
        try env.writeSettings(
            disabled: EngramServiceWebSourceSettingsValidation.knownKeys.filter { $0 != "claude-code" }.sorted()
        )
        return env
    }

    private func assertUnavailable(_ body: () throws -> Void) {
        XCTAssertThrowsError(try body()) {
            XCTAssertEqual(
                $0 as? EngramServiceError,
                .serviceUnavailable(message: "Web relationship service is unavailable.")
            )
        }
    }

    private func assertInvalid(_ body: () throws -> Void) {
        XCTAssertThrowsError(try body()) {
            XCTAssertEqual(
                $0 as? EngramServiceError,
                .invalidRequest(message: "Web relationship request is invalid.")
            )
        }
    }

    private func assertStale(_ body: () throws -> Void) {
        XCTAssertThrowsError(try body()) {
            XCTAssertEqual(
                $0 as? EngramServiceError,
                .commandFailed(
                    name: "StaleCursor",
                    message: "Web relationship authorization is stale.",
                    retryPolicy: "never",
                    details: nil
                )
            )
        }
    }
}
