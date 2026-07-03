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

    func testWebUISessionListFiltersNoiseRowsLikeAppTopLevelLists() throws {
        let source = try serviceCoreSource("EngramWebUIServer.swift")
        let start = try XCTUnwrap(source.range(of: "private func readSessions(limit: Int"))
        let end = try XCTUnwrap(source.range(of: "private func readSession(id: String)", options: [], range: start.lowerBound..<source.endIndex))
        let query = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(query.contains("COALESCE(s.tier, 'normal') NOT IN ('skip', 'lite')"))
        XCTAssertTrue(query.contains("s.parent_session_id IS NULL"))
        XCTAssertTrue(query.contains("s.suggested_parent_id IS NULL"))
        XCTAssertTrue(query.contains("s.orphan_status IS NULL"))
        // Default browse list also applies the human-driven predicate (?all=1 opts out).
        XCTAssertTrue(query.contains("HumanDrivenFilter.sqlPredicate"))
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

    // Hoisting the 8 patterns into a static precompiled array (perf finding #28)
    // must not change redaction output. Lock the exact byte output on a
    // representative multi-secret sample and confirm repeated calls are stable.
    func testRedactionStaticPatternsProduceByteIdenticalOutput() {
        let samples = [
            "api_key: ABCDEF0123456789 tail",
            "Authorization: Bearer ABCDEF0123456789",
            "token=sk-abcdefghij0123456789 done",
            "github_pat_1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZ here",
            "AKIA1234567890ABCDEF and npm_1234567890abcdef and xoxe-1234567890-abcdef",
            "-----BEGIN PRIVATE KEY-----\nsecret\n-----END PRIVATE KEY-----",
            "no secrets here, just prose about tokens and passwords in general",
        ]
        let expected = [
            "[REDACTED] tail",
            "[REDACTED]",
            "[REDACTED] done",
            "[REDACTED] here",
            "[REDACTED] and [REDACTED] and [REDACTED]",
            "[REDACTED]",
            "no secrets here, just prose about tokens and passwords in general",
        ]
        for (input, want) in zip(samples, expected) {
            let first = TranscriptExportService.redactSensitiveContent(input)
            XCTAssertEqual(first, want, "redaction output changed for: \(input)")
            // Idempotent across repeated calls (precompiled regexes are reused).
            XCTAssertEqual(TranscriptExportService.redactSensitiveContent(input), first)
        }
    }

    // Finding #32: the session-page ETag is a weak validator derived from ACTUAL
    // values (id + file mtime/size + offset/limit), never Swift hashValue.
    func testSessionETagDerivesFromActualFileValues() throws {
        let dir = NSTemporaryDirectory() + "engram-etag-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/transcript.jsonl"
        try "line one\n".write(toFile: path, atomically: true, encoding: .utf8)

        let base = EngramWebUIServer.sessionETag(id: "s1", locator: path, offset: 0, limit: 50)
        XCTAssertNotNil(base)
        XCTAssertTrue(base!.hasPrefix("W/\""), "ETag must be weak")
        // Stable for identical inputs.
        XCTAssertEqual(base, EngramWebUIServer.sessionETag(id: "s1", locator: path, offset: 0, limit: 50))
        // Sensitive to id / offset / limit.
        XCTAssertNotEqual(base, EngramWebUIServer.sessionETag(id: "s2", locator: path, offset: 0, limit: 50))
        XCTAssertNotEqual(base, EngramWebUIServer.sessionETag(id: "s1", locator: path, offset: 50, limit: 50))
        XCTAssertNotEqual(base, EngramWebUIServer.sessionETag(id: "s1", locator: path, offset: 0, limit: 100))
        // Sensitive to file size/mtime.
        try "line one\nline two\n".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(base, EngramWebUIServer.sessionETag(id: "s1", locator: path, offset: 0, limit: 50))
        // Virtual/missing locators skip conditional-GET entirely.
        XCTAssertNil(EngramWebUIServer.sessionETag(id: "s1", locator: nil, offset: 0, limit: 50))
        XCTAssertNil(EngramWebUIServer.sessionETag(id: "s1", locator: "", offset: 0, limit: 50))
        XCTAssertNil(EngramWebUIServer.sessionETag(id: "s1", locator: dir + "/missing.db::abc", offset: 0, limit: 50))
    }

    func testIfNoneMatchWeakComparison() {
        let etag = "W/\"deadbeef\""
        XCTAssertTrue(EngramWebUIServer.ifNoneMatch(header: etag, matches: etag))
        // Weak comparison ignores the W/ prefix on either side.
        XCTAssertTrue(EngramWebUIServer.ifNoneMatch(header: "\"deadbeef\"", matches: etag))
        // Comma-separated list and wildcard.
        XCTAssertTrue(EngramWebUIServer.ifNoneMatch(header: "W/\"other\", W/\"deadbeef\"", matches: etag))
        XCTAssertTrue(EngramWebUIServer.ifNoneMatch(header: "*", matches: etag))
        // Non-matches.
        XCTAssertFalse(EngramWebUIServer.ifNoneMatch(header: nil, matches: etag))
        XCTAssertFalse(EngramWebUIServer.ifNoneMatch(header: "W/\"other\"", matches: etag))
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
            source.contains("html: layout(title: \"Not Found\", body: \"<p>Session not found.</p>\")")
                && source.contains("status: .notFound"),
            "Missing session must signal HTTP 404, not a 200 that renders not-found HTML"
        )
        XCTAssertFalse(
            source.contains("options: StreamMessagesOptions(offset: offset, limit: nil)"),
            "readMessages must cap the raw window, not materialize the whole post-offset suffix"
        )
    }
}
