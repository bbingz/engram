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
        let server = try EngramWebUIServer(databasePath: dbPath)

        XCTAssertTrue(try server.writeIsRejectedForTesting(), "Web UI DB handle must be read-only")
    }

    func testWebUIServerCloseReleasesPoolDeterministically() throws {
        // R5-60: close() releases the GRDB pool eagerly and is idempotent;
        // reads after close fail loudly rather than relying on ARC timing.
        let dbPath = try makeMinimalDatabase()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        let server = try EngramWebUIServer(databasePath: dbPath)

        XCTAssertFalse(server.isClosedForTesting)
        server.close()
        XCTAssertTrue(server.isClosedForTesting)
        server.close() // idempotent
        XCTAssertTrue(server.isClosedForTesting)
        XCTAssertThrowsError(try server.writeIsRejectedForTesting())
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
}
