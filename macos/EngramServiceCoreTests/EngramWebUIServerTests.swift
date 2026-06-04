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

    func testTranscriptParserFailureMapsToNonOkStatus() {
        XCTAssertEqual(EngramWebUIServer.transcriptErrorStatus(ParserFailure.fileMissing), .notFound)
        XCTAssertEqual(EngramWebUIServer.transcriptErrorStatus(ParserFailure.fileModifiedDuringParse), .notFound)
        XCTAssertEqual(EngramWebUIServer.transcriptErrorStatus(ParserFailure.fileTooLarge), .init(code: 413, reasonPhrase: "Payload Too Large"))
        XCTAssertEqual(EngramWebUIServer.transcriptErrorStatus(ParserFailure.messageLimitExceeded), .init(code: 413, reasonPhrase: "Payload Too Large"))
        XCTAssertEqual(EngramWebUIServer.transcriptErrorStatus(ParserFailure.malformedJSON), .internalServerError)
    }

    func testTranscriptDisplayFiltersToolMessagesLikeSwiftApp() {
        XCTAssertTrue(EngramWebUIServer.shouldDisplayTranscriptMessage(NormalizedMessage(role: .user, content: "hello"), source: "codex"))
        XCTAssertTrue(EngramWebUIServer.shouldDisplayTranscriptMessage(NormalizedMessage(role: .assistant, content: "done"), source: "codex"))
        XCTAssertFalse(EngramWebUIServer.shouldDisplayTranscriptMessage(NormalizedMessage(role: .tool, content: "tool output"), source: "codex"))
        XCTAssertFalse(EngramWebUIServer.shouldDisplayTranscriptMessage(NormalizedMessage(role: .system, content: "system"), source: "codex"))
        XCTAssertFalse(EngramWebUIServer.shouldDisplayTranscriptMessage(NormalizedMessage(role: .assistant, content: "   "), source: "codex"))
        XCTAssertFalse(EngramWebUIServer.shouldDisplayTranscriptMessage(NormalizedMessage(role: .user, content: "# AGENTS.md instructions for /tmp"), source: "codex"))
        XCTAssertFalse(EngramWebUIServer.shouldDisplayTranscriptMessage(NormalizedMessage(role: .user, content: "<command-name>hidden</command-name>"), source: "codex"))
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

    func testRedactionCoversCommonTokenFamilies() {
        let input = """
        github_pat_1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZ
        AKIA1234567890ABCDEF
        npm_1234567890abcdef
        xoxe-1234567890-abcdef
        -----BEGIN PRIVATE KEY-----
        secret
        -----END PRIVATE KEY-----
        """
        let redacted = EngramWebUIServer.redactSensitiveContent(input)

        XCTAssertFalse(redacted.contains("github_pat_1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZ"))
        XCTAssertFalse(redacted.contains("AKIA1234567890ABCDEF"))
        XCTAssertFalse(redacted.contains("npm_1234567890abcdef"))
        XCTAssertFalse(redacted.contains("xoxe-1234567890-abcdef"))
        XCTAssertFalse(redacted.contains("BEGIN PRIVATE KEY"))
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

        // expectedPort is now enforced: a loopback Host/Origin on a DIFFERENT
        // local port is rejected (the parameter was previously ignored).
        XCTAssertFalse(EngramWebUIServer.isLoopbackHost("127.0.0.1:9999", expectedPort: 3457))
        XCTAssertFalse(EngramWebUIServer.isLoopbackHost("127.0.0.1:3457.attacker.com", expectedPort: 3457))
        XCTAssertFalse(EngramWebUIServer.isLoopbackHost("127.0.0.1:3457:extra", expectedPort: 3457))
        XCTAssertFalse(EngramWebUIServer.isLoopbackOrigin("http://127.0.0.1:9999", expectedPort: 3457))
        // A bare loopback host with no port is still allowed.
        XCTAssertTrue(EngramWebUIServer.isLoopbackHost("127.0.0.1", expectedPort: 3457))
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

    func testRunnerLogsWebUIEnabledAndDisabledBranches() throws {
        let source = try serviceCoreSource("EngramServiceRunner.swift")

        XCTAssertTrue(source.contains("web ui disabled (webUIEnabled=false); not starting"))
        XCTAssertTrue(
            source.contains("web ui enabled (webUIEnabled=true); starting local server"),
            "the enabled-by-settings branch should leave a startup breadcrumb before the health probe"
        )
    }

    // MARK: - Transcript pager (raw-index consistency + capped window)

    /// A mixed stream: index 0 user (shown), 1 tool (filtered), 2 assistant
    /// (shown), 3 empty user (filtered), 4 user (shown), 5 user (shown).
    private func mixedStream() -> [NormalizedMessage] {
        [
            NormalizedMessage(role: .user, content: "m0"),       // 0 shown
            NormalizedMessage(role: .tool, content: "tool out"), // 1 filtered (tool)
            NormalizedMessage(role: .assistant, content: "m2"),  // 2 shown
            NormalizedMessage(role: .user, content: "   "),      // 3 filtered (blank)
            NormalizedMessage(role: .user, content: "m4"),       // 4 shown
            NormalizedMessage(role: .user, content: "m5")        // 5 shown
        ]
    }

    /// Mirror the formula the view uses so the rendered pager values are
    /// asserted as the page handler actually computes them.
    private func renderedPrevious(offset: Int, limit: Int) -> Int { max(0, offset - limit) }
    private func renderedShowing(offset: Int, nextOffset: Int) -> String {
        "Showing messages \(offset + 1)-\(nextOffset)"
    }

    func testPagerFirstPageCapsRawWindowAndReportsHasMore() {
        // Page stride is `limit` RAW messages. limit = 3 → raw window covers
        // indices 0,1,2 (the +1 probe at index 3 only signals hasMore).
        let full = mixedStream()
        let offset = 0, limit = 3
        // readMessages hands windowDisplayable at most limit+1 raw messages.
        let raw = Array(full[offset...].prefix(limit + 1))
        let page = EngramWebUIServer.windowDisplayable(raw, source: "codex", offset: offset, limit: limit)

        // Of raw indices 0..2: 0 (user) + 2 (assistant) are shown; 1 (tool) filtered.
        XCTAssertEqual(page.messages.map(\.content), ["m0", "m2"])
        XCTAssertTrue(page.hasMore, "a 4th raw message exists past the window")
        // nextOffset is a RAW index = offset + window size (3), not displayed count.
        XCTAssertEqual(page.nextOffset, 3)
        XCTAssertEqual(renderedPrevious(offset: offset, limit: limit), 0)
        XCTAssertEqual(renderedShowing(offset: offset, nextOffset: page.nextOffset),
                       "Showing messages 1-3")
    }

    func testPagerSecondPageIsExactRawInverseOfFirst() {
        // Next from page 1 lands at raw offset 3. From there limit = 3 covers
        // raw indices 3,4,5; there is no 7th raw message so hasMore is false.
        let full = mixedStream()
        let offset = 3, limit = 3
        let raw = Array(full[offset...].prefix(limit + 1)) // 3,4,5 (only 3 left)
        let page = EngramWebUIServer.windowDisplayable(raw, source: "codex", offset: offset, limit: limit)

        // raw 3 (blank user) filtered; 4 + 5 shown.
        XCTAssertEqual(page.messages.map(\.content), ["m4", "m5"])
        XCTAssertFalse(page.hasMore, "stream ends at raw index 5")
        XCTAssertEqual(page.nextOffset, 6) // offset(3) + window(3)
        // Previous from page 2 is offset - limit = 0 — the EXACT start of page 1.
        XCTAssertEqual(renderedPrevious(offset: offset, limit: limit), 0)
        XCTAssertEqual(renderedShowing(offset: offset, nextOffset: page.nextOffset),
                       "Showing messages 4-6")
    }

    func testPagerWindowFullOfFilteredMessagesStillAdvances() {
        // A page whose raw window is entirely filtered renders nothing but must
        // still report hasMore + a forward nextOffset so navigation continues.
        let raw = [
            NormalizedMessage(role: .tool, content: "a"),
            NormalizedMessage(role: .tool, content: "b"),
            NormalizedMessage(role: .system, content: "c"),
            NormalizedMessage(role: .user, content: "probe") // +1 probe
        ]
        let page = EngramWebUIServer.windowDisplayable(raw, source: "codex", offset: 10, limit: 3)

        XCTAssertTrue(page.messages.isEmpty)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.nextOffset, 13) // offset(10) + window(3)
    }

    func testPagerExactlyLimitRawMessagesHasNoMore() {
        // raw.count == limit (no probe element) → no further page.
        let raw = [
            NormalizedMessage(role: .user, content: "x"),
            NormalizedMessage(role: .assistant, content: "y"),
            NormalizedMessage(role: .user, content: "z")
        ]
        let page = EngramWebUIServer.windowDisplayable(raw, source: "codex", offset: 0, limit: 3)

        XCTAssertEqual(page.messages.map(\.content), ["x", "y", "z"])
        XCTAssertFalse(page.hasMore)
        XCTAssertEqual(page.nextOffset, 3)
    }

    func testPagerRedactsSurvivingMessages() {
        let raw = [NormalizedMessage(role: .user, content: "api_key: ABCDEF0123456789")]
        let page = EngramWebUIServer.windowDisplayable(raw, source: "codex", offset: 0, limit: 3)

        XCTAssertEqual(page.messages.count, 1)
        XCTAssertFalse(page.messages[0].content.contains("ABCDEF0123456789"))
        XCTAssertTrue(page.messages[0].content.contains("[REDACTED]"))
    }

    func testMissingSessionSignalsNotFoundStatus() throws {
        // sessionPage is private + needs a Request, so assert the wiring at the
        // source level: a missing session must return .notFound, mirroring the
        // percent-decode-failure branch — not the default .ok.
        let source = try serviceCoreSource("EngramWebUIServer.swift")
        XCTAssertTrue(
            source.contains("return (layout(title: \"Not Found\", body: \"<p>Session not found.</p>\"), .notFound)"),
            "Missing session must signal HTTP 404, not a 200 that renders not-found HTML"
        )
        XCTAssertFalse(
            source.contains("options: StreamMessagesOptions(offset: offset, limit: nil)"),
            "readMessages must cap the raw window, not materialize the whole post-offset suffix"
        )
    }
}
