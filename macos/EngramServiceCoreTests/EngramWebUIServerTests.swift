import XCTest
import GRDB
import EngramCoreRead
@testable import EngramServiceCore

final class EngramWebUIServerTests: XCTestCase {
    func testWebUIServerOpensDatabaseReadOnly() throws {
        // R5-23: the Web UI must open the DB read-only like MCPDatabase, never
        // read-write (only the ServiceWriterGate owns writes).
        let dbPath = try makeMinimalDatabase()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        let server = try EngramWebUIServer(databasePath: dbPath, authToken: "test-token")

        XCTAssertTrue(try server.writeIsRejectedForTesting(), "Web UI DB handle must be read-only")
    }

    func testWebUIServerCloseReleasesPoolDeterministically() throws {
        // R5-60: close() releases the GRDB pool eagerly and is idempotent;
        // reads after close fail loudly rather than relying on ARC timing.
        let dbPath = try makeMinimalDatabase()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        let server = try EngramWebUIServer(databasePath: dbPath, authToken: "test-token")

        XCTAssertFalse(server.isClosedForTesting)
        server.close()
        XCTAssertTrue(server.isClosedForTesting)
        server.close() // idempotent
        XCTAssertTrue(server.isClosedForTesting)
        XCTAssertThrowsError(try server.writeIsRejectedForTesting())
    }

    func testHtmlResponsesDeclareContentSecurityPolicy() throws {
        let source = try serviceCoreSource("EngramWebUIServer.swift")

        XCTAssertTrue(
            source.contains("headers[.contentSecurityPolicy]"),
            "Swift Web UI HTML responses should send an enforcing Content-Security-Policy header"
        )
        XCTAssertTrue(
            source.contains("default-src 'none'"),
            "CSP should fail closed by default because the Swift Web UI is local and static"
        )
        XCTAssertTrue(
            source.contains("frame-ancestors 'none'"),
            "CSP should prevent the local Web UI from being framed"
        )
    }

    private func makeMinimalDatabase() throws -> String {
        let path = NSTemporaryDirectory() + "engram-webui-\(UUID().uuidString).sqlite"
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE sessions (
                  id TEXT PRIMARY KEY,
                  source TEXT NOT NULL,
                  start_time TEXT NOT NULL,
                  end_time TEXT,
                  project TEXT,
                  summary TEXT,
                  generated_title TEXT,
                  custom_name TEXT,
                  message_count INTEGER NOT NULL DEFAULT 0,
                  file_path TEXT,
                  source_locator TEXT,
                  hidden_at TEXT
                );
                CREATE TABLE session_local_state (
                  session_id TEXT PRIMARY KEY,
                  local_readable_path TEXT,
                  hidden_at TEXT
                );
            """)
        }
        return path
    }

    private func serviceCoreSource(_ relativePath: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath)
        while directory.lastPathComponent != "macos" {
            directory.deleteLastPathComponent()
        }
        return try String(
            contentsOf: directory
                .appendingPathComponent("EngramService/Core")
                .appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    func testSubagentNotificationRendersAsAgentCommunication() {
        let message = NormalizedMessage(
            role: .user,
            content: "<subagent_notification>{\"status\":\"completed\"}</subagent_notification>"
        )

        let html = EngramWebUIServer.renderMessageHTML(message, source: "codex")

        XCTAssertTrue(html.contains("Agent Communication"))
        XCTAssertTrue(html.contains("subagent_notification"))
        XCTAssertFalse(html.contains(">You<"))
        XCTAssertTrue(html.contains("message system agent-comm"))
    }

    func testInjectedAgentInstructionsRenderAsSystemPrompt() {
        let message = NormalizedMessage(
            role: .user,
            content: """
            # AGENTS.md instructions for /Users/bing/-Code-/engram

            <INSTRUCTIONS>
            Keep engineering changes small.
            </INSTRUCTIONS>
            """
        )

        let html = EngramWebUIServer.renderMessageHTML(message, source: "codex")

        XCTAssertTrue(html.contains("System Prompt"))
        XCTAssertFalse(html.contains(">You<"))
        XCTAssertTrue(html.contains("message system system-prompt"))
    }

    func testAntigravitySystemMessageWrapperUsesSharedSystemPromptClassification() {
        let message = NormalizedMessage(
            role: .user,
            content: """
            The following is a <SYSTEM_MESSAGE> not actually sent by the user.

            <SYSTEM_MESSAGE>
            [Message] timestamp=2026-05-20T00:02:44Z priority=MESSAGE_PRIORITY_HIGH
            content=Task finished with result.
            </SYSTEM_MESSAGE>
            """
        )

        let html = EngramWebUIServer.renderMessageHTML(message, source: "antigravity")

        XCTAssertTrue(html.contains("System Prompt"))
        XCTAssertFalse(html.contains(">You<"))
        XCTAssertTrue(html.contains("message system system-prompt"))
    }

    func testSystemMessageWrapperDoesNotReclassifyNonAntigravitySources() {
        let message = NormalizedMessage(
            role: .user,
            content: "<SYSTEM_MESSAGE>user pasted wrapper</SYSTEM_MESSAGE>"
        )

        let html = EngramWebUIServer.renderMessageHTML(message, source: "codex")

        XCTAssertTrue(html.contains(">You<"))
        XCTAssertFalse(html.contains("System Prompt"))
        XCTAssertFalse(html.contains("message system system-prompt"))
    }

    func testTranscriptParserFailureRendersInlineNotice() {
        let html = EngramWebUIServer.transcriptErrorHTML(ParserFailure.messageLimitExceeded)

        XCTAssertTrue(html.contains("Transcript unavailable"))
        XCTAssertTrue(html.contains("message limit"))
        XCTAssertTrue(html.contains("message system transcript-error"))
    }

    func testTranscriptDisplayFiltersToolMessagesLikeSwiftApp() {
        XCTAssertTrue(EngramWebUIServer.shouldDisplayTranscriptMessage(NormalizedMessage(role: .user, content: "hello")))
        XCTAssertTrue(EngramWebUIServer.shouldDisplayTranscriptMessage(NormalizedMessage(role: .assistant, content: "done")))
        XCTAssertFalse(EngramWebUIServer.shouldDisplayTranscriptMessage(NormalizedMessage(role: .tool, content: "tool output")))
        XCTAssertFalse(EngramWebUIServer.shouldDisplayTranscriptMessage(NormalizedMessage(role: .system, content: "system")))
        XCTAssertFalse(EngramWebUIServer.shouldDisplayTranscriptMessage(NormalizedMessage(role: .assistant, content: "   ")))
    }

    // MARK: - SEC-C1

    func testWebUIServerFailsClosedWithoutAuthToken() {
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("webui-noauth-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        XCTAssertThrowsError(try EngramWebUIServer(databasePath: dbPath, authToken: nil)) { error in
            XCTAssertTrue(error is WebUIServerError)
        }
        XCTAssertThrowsError(try EngramWebUIServer(databasePath: dbPath, authToken: "")) { error in
            XCTAssertTrue(error is WebUIServerError)
        }
    }

    func testWebUIServerConstructsWithAuthToken() throws {
        // The init opens the DB read-only (R5-23), so the file must exist —
        // a read-only open of a missing file fails with SQLite error 14.
        let dbPath = try makeMinimalDatabase()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        XCTAssertNoThrow(try EngramWebUIServer(databasePath: dbPath, authToken: "secret-token"))
    }

    func testRedactionMatchesExportPatterns() {
        let input = "here is api_key: ABCDEF0123456789 and sk-abcdefghij0123456789"
        let redacted = EngramWebUIServer.redactSensitiveContent(input)
        XCTAssertFalse(redacted.contains("ABCDEF0123456789"))
        XCTAssertFalse(redacted.contains("sk-abcdefghij0123456789"))
        XCTAssertTrue(redacted.contains("[REDACTED]"))
    }

    func testWebUIRedactionUsesExportCanonicalRedaction() {
        let input = "Authorization: Bearer ABCDEF0123456789"
        XCTAssertEqual(
            EngramWebUIServer.redactSensitiveContent(input),
            TranscriptExportService.redactSensitiveContent(input)
        )
    }

    func testLoopbackHostAndOriginValidation() {
        XCTAssertTrue(EngramWebUIServer.isLoopbackHost("127.0.0.1:3457", expectedPort: 3457))
        XCTAssertTrue(EngramWebUIServer.isLoopbackHost("localhost:3457", expectedPort: 3457))
        XCTAssertFalse(EngramWebUIServer.isLoopbackHost("evil.example.com", expectedPort: 3457))
        XCTAssertTrue(EngramWebUIServer.isLoopbackOrigin("http://127.0.0.1:3457", expectedPort: 3457))
        XCTAssertFalse(EngramWebUIServer.isLoopbackOrigin("http://evil.example.com", expectedPort: 3457))
    }

    func testConstantTimeEquals() {
        XCTAssertTrue(EngramWebUIServer.constantTimeEquals("abc123", "abc123"))
        XCTAssertFalse(EngramWebUIServer.constantTimeEquals("abc123", "abc124"))
        XCTAssertFalse(EngramWebUIServer.constantTimeEquals("abc", "abc123"))
    }

    func testWebUIEnvOverride() {
        // Env override is authoritative and deterministic regardless of any
        // real ~/.engram/settings.json on the host.
        XCTAssertTrue(EngramServiceRunner.readWebUIEnabled(environment: ["ENGRAM_WEB_UI_ENABLED": "1"]))
        XCTAssertTrue(EngramServiceRunner.readWebUIEnabled(environment: ["ENGRAM_WEB_UI_ENABLED": "true"]))
        XCTAssertFalse(EngramServiceRunner.readWebUIEnabled(environment: ["ENGRAM_WEB_UI_ENABLED": "0"]))
        XCTAssertFalse(EngramServiceRunner.readWebUIEnabled(environment: ["ENGRAM_WEB_UI_ENABLED": "false"]))
    }
}
