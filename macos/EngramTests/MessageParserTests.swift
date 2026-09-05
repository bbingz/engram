// macos/EngramTests/MessageParserTests.swift
import XCTest
@testable import Engram

final class MessageParserTests: XCTestCase {
    private struct MetadataThrowingPrefixAdapter: SessionAdapter {
        let source: SourceName = .iflow

        func detect() async -> Bool { true }
        func listSessionLocators() async throws -> [String] { [] }
        func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
            .failure(.malformedJSON)
        }
        func isAccessible(locator: String) async -> Bool { true }

        func streamMessages(
            locator: String,
            options: StreamMessagesOptions
        ) async throws -> AsyncThrowingStream<NormalizedMessage, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield(NormalizedMessage(role: .user, content: "retained-prefix"))
                continuation.finish(throwing: ParserFailure.malformedJSON)
            }
        }

        func streamMessagesWithMetadata(
            locator: String,
            options: StreamMessagesOptions
        ) async throws -> StreamMessagesResult {
            throw ParserFailure.fileModifiedDuringParse
        }
    }

    private struct MetadataThrowingCappedQwenAdapter: SessionAdapter {
        let source: SourceName = .qwen
        let inner: QwenAdapter

        func detect() async -> Bool { true }
        func listSessionLocators() async throws -> [String] { [] }
        func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
            try await inner.parseSessionInfo(locator: locator)
        }
        func isAccessible(locator: String) async -> Bool { true }

        func streamMessages(
            locator: String,
            options: StreamMessagesOptions
        ) async throws -> AsyncThrowingStream<NormalizedMessage, Error> {
            try await inner.streamMessages(locator: locator, options: options)
        }

        func streamMessagesWithMetadata(
            locator: String,
            options: StreamMessagesOptions
        ) async throws -> StreamMessagesResult {
            throw ParserFailure.fileModifiedDuringParse
        }
    }

    private struct ClassificationFixtureCase: Decodable {
        let name: String
        let source: String
        let content: String
        let category: String
    }


    override func setUpWithError() throws {
        try super.setUpWithError()
    }

    override func tearDownWithError() throws {
        try super.tearDownWithError()
    }

    // MARK: - Helper

    private func fixturePath(_ name: String) throws -> String {
        guard let path = Bundle(for: type(of: self)).path(forResource: "test-fixtures/sessions/\(name)", ofType: nil) else {
            XCTFail("Fixture '\(name)' not found in test bundle. Ensure test-fixtures is configured as a resource in project.yml.")
            return ""  // unreachable after XCTFail, but satisfies compiler
        }
        return path
    }

    private func repoFixturePath(_ relativePath: String, filePath: String = #filePath) -> String {
        URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("tests/fixtures/\(relativePath)")
            .path
    }

    // MARK: - claude-code format (type/message)

    /// 1. Parse claude-code JSONL with string and array content
    func testParseClaudeCodeFormat() throws {
        let path = try fixturePath("claude-code.jsonl")
        let messages = MessageParser.parseLegacy(filePath: path, source: "claude-code")

        XCTAssertEqual(messages.count, 4)
        XCTAssertEqual(messages[0].role, "user")
        XCTAssertEqual(messages[0].content, "Hello from Claude Code")
        XCTAssertEqual(messages[1].role, "assistant")
        XCTAssertEqual(messages[1].content, "Hi! How can I help?")
        // 4th message uses array content format [{type:"text",text:"..."}]
        XCTAssertEqual(messages[3].role, "assistant")
        XCTAssertEqual(messages[3].content, "Here is the function")
    }

    /// 2. Parse codex format (response_item/payload)
    func testParseCodexFormat() async throws {
        let path = try fixturePath("codex.jsonl")
        let messages = try await MessageParser.parse(filePath: path, source: "codex")

        guard messages.count == 2 else {
            return XCTFail("Expected 2 codex display messages, got \(messages.count)")
        }
        XCTAssertEqual(messages[0].role, "user")
        XCTAssertEqual(messages[0].content, "Hello from Codex")
        XCTAssertEqual(messages[1].role, "assistant")
        XCTAssertEqual(messages[1].content, "Codex response here")
    }

    /// 3. Parse gemini-cli format (whole-file JSON with messages array)
    func testParseGeminiFormat() async throws {
        let path = try fixturePath("gemini.json")
        let messages = try await MessageParser.parse(filePath: path, source: "gemini-cli")

        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0].role, "user")
        XCTAssertEqual(messages[0].content, "Hello Gemini")
        XCTAssertEqual(messages[1].role, "assistant")  // "gemini" type maps to "assistant"
        XCTAssertEqual(messages[1].content, "Hi from Gemini")
        XCTAssertEqual(messages[2].role, "assistant")  // "model" type maps to "assistant"
        XCTAssertEqual(messages[2].content, "Multi-part model response")
    }

    /// 4. Malformed JSON lines are silently skipped
    func testMalformedJSONSkipped() throws {
        let path = try fixturePath("malformed.jsonl")
        let messages = MessageParser.parseLegacy(filePath: path, source: "claude-code")

        // malformed.jsonl: 1 unparseable, 1 missing message field, 1 empty message content
        XCTAssertEqual(messages.count, 0, "All malformed entries should be skipped")
    }

    /// 5. Empty file returns empty array
    func testEmptyFileReturnsEmpty() throws {
        let path = try fixturePath("empty.jsonl")
        let messages = MessageParser.parseLegacy(filePath: path, source: "claude-code")
        XCTAssertTrue(messages.isEmpty)
    }

    /// 6. Mixed valid/invalid lines — empty content skipped, whitespace-only content kept
    func testMixedValidInvalid() throws {
        let path = try fixturePath("empty-content.jsonl")
        let messages = MessageParser.parseLegacy(filePath: path, source: "claude-code")

        // empty-content.jsonl: "" is skipped (isEmpty), "valid" kept, "   " kept (not empty, just whitespace)
        guard messages.count == 2 else {
            return XCTFail("Expected 2 claude-code display messages, got \(messages.count)")
        }
        XCTAssertEqual(messages[0].content, "valid")
        XCTAssertEqual(messages[1].content, "   ")
    }

    /// 7. CJK content preserved in claude-code format
    func testCJKContentPreserved() throws {
        let path = try fixturePath("cjk-claude.jsonl")
        let messages = MessageParser.parseLegacy(filePath: path, source: "claude-code")

        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0].content, "请帮我写一个函数")
        XCTAssertEqual(messages[1].content, "好的，这是函数实现")
        XCTAssertEqual(messages[2].content, "ありがとう")
    }

    /// 8. Kimi format (role/content, no skip)
    func testParseKimiFormat() async throws {
        let path = try fixturePath("kimi.jsonl")
        let messages = try await MessageParser.parse(filePath: path, source: "kimi")

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, "user")
        XCTAssertEqual(messages[0].content, "Hello Kimi")
        XCTAssertEqual(messages[1].role, "assistant")
    }

    /// 9. Antigravity format (role/content, skips first line)
    func testParseAntigravityFormat() async throws {
        let path = try fixturePath("antigravity.jsonl")
        let messages = try await MessageParser.parse(filePath: path, source: "antigravity")

        // First line is metadata, should be skipped
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].content, "Hello Antigravity")
        XCTAssertEqual(messages[1].content, "Hi from Antigravity")
    }

    /// 10. Copilot format (type-based with data.content)
    func testParseCopilotFormat() async throws {
        let path = try fixturePath("copilot.jsonl")
        let messages = try await MessageParser.parse(filePath: path, source: "copilot")

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, "user")
        XCTAssertEqual(messages[0].content, "Hello Copilot")
        XCTAssertEqual(messages[1].role, "assistant")
        XCTAssertEqual(messages[1].content, "Hi from Copilot")
    }

    func testParseQoderThroughAdapterRegistry() async throws {
        let messages = try await MessageParser.parse(
            filePath: repoFixturePath("qoder/sample.jsonl"),
            source: "qoder"
        )

        guard messages.count == 3 else {
            return XCTFail("Expected 3 qoder display messages, got \(messages.count)")
        }
        XCTAssertEqual(messages[0].role, "user")
        XCTAssertEqual(messages[0].content, "Review the parser")
        XCTAssertEqual(messages[1].role, "assistant")
        XCTAssertEqual(messages[1].content, "I will review the parser.")
        XCTAssertEqual(messages[2].role, "assistant")
        XCTAssertEqual(messages[2].content, "`Read`")
    }

    func testParseCommandCodeThroughAdapterRegistry() async throws {
        let messages = try await MessageParser.parse(
            filePath: repoFixturePath("commandcode/sample.jsonl"),
            source: "commandcode"
        )

        guard messages.count == 2 else {
            return XCTFail("Expected 2 commandcode display messages, got \(messages.count)")
        }
        XCTAssertEqual(messages[0].role, "user")
        XCTAssertEqual(messages[0].content, "检查解析器")
        XCTAssertEqual(messages[1].role, "assistant")
        XCTAssertEqual(messages[1].content, "我会检查解析器。\n\n`read_file`")
    }

    func testParseAntigravityCliThroughAdapterRegistry() async throws {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("engram-ag-cli-\(UUID().uuidString)", isDirectory: true)
        let transcript = tmpRoot
            .appendingPathComponent(".gemini/antigravity-cli/brain/cli-session-001/.system_generated/logs/transcript.jsonl")
        try FileManager.default.createDirectory(
            at: transcript.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tmpRoot) }
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: repoFixturePath("antigravity-cli/transcript.jsonl")),
            to: transcript
        )

        let messages = try await MessageParser.parse(filePath: transcript.path, source: "antigravity")

        guard messages.count == 3 else {
            return XCTFail("Expected 3 antigravity CLI display messages, got \(messages.count)")
        }
        XCTAssertEqual(messages[0].role, "user")
        XCTAssertEqual(messages[0].content, "Review the Antigravity CLI parser")
        XCTAssertEqual(messages[1].role, "assistant")
        XCTAssertEqual(messages[1].content, "Inspecting the transcript shape")
        XCTAssertEqual(messages[2].role, "assistant")
        XCTAssertEqual(messages[2].content, "The parser should include CLI brain transcripts.")
    }

    /// 11. Cline format (whole-file JSON array with say/text)
    func testParseClineFormat() throws {
        let path = try fixturePath("cline.json")
        let messages = MessageParser.parseLegacy(filePath: path, source: "cline")

        // task → user, text(partial=false) → assistant, user_feedback → user, text(partial=true) → skipped
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0].role, "user")
        XCTAssertEqual(messages[0].content, "Build a widget")
        XCTAssertEqual(messages[1].role, "assistant")
        XCTAssertEqual(messages[1].content, "Here is the widget")
        XCTAssertEqual(messages[2].role, "user")
        XCTAssertEqual(messages[2].content, "Looks good")
    }

    /// 12. System prompt detection — systemPrompt category
    func testSystemPromptDetection_repro() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-system-prompts-\(UUID().uuidString)", isDirectory: true)
        let homeDirectory = root.appendingPathComponent("home", isDirectory: true)
        let projectDirectory = homeDirectory
            .appendingPathComponent(".claude/projects/-fixture", isDirectory: true)
        let transcript = projectDirectory.appendingPathComponent("system-prompts.jsonl")
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            atPath: try fixturePath("system-prompts.jsonl"),
            toPath: transcript.path
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = ClaudeCodeProfileResolver(
            homeDirectory: homeDirectory,
            settingsURL: homeDirectory.appendingPathComponent(".engram/settings.json")
        )

        let messages = try await MessageParser.parse(
            filePath: transcript.path,
            source: "claude-code",
            claudeCodeProfileResolver: resolver
        )

        XCTAssertEqual(messages.count, 4)
        guard messages.count == 4 else { return }
        // <system-reminder> → systemPrompt
        XCTAssertEqual(messages[0].systemCategory, .systemPrompt)
        XCTAssertTrue(messages[0].isSystem)
        // Normal message → none
        XCTAssertEqual(messages[1].systemCategory, .none)
        XCTAssertFalse(messages[1].isSystem)
        // <environment_context> → systemPrompt
        XCTAssertEqual(messages[2].systemCategory, .systemPrompt)
        // <local-command-stdout> → agentComm
        XCTAssertEqual(messages[3].systemCategory, .agentComm)
    }

    func testParseWithOffsetAndLimit() async throws {
        let path = try fixturePath("codex.jsonl")
        let messages = try await MessageParser.parse(filePath: path, source: "codex", offset: 1, limit: 1)

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, "assistant")
        XCTAssertEqual(messages[0].content, "Codex response here")
    }

    /// Transcript paging (SessionDetailView) loads a first page then APPENDS the
    /// remainder from `offset = loadedCount`. That must reconstruct the full
    /// transcript exactly — no gap, dup, or silent truncation at the page seam.
    func testPagedParseConcatenationEqualsFullTranscript() async throws {
        let path = try fixturePath("codex.jsonl")
        let full = try await MessageParser.parse(filePath: path, source: "codex")
        XCTAssertGreaterThan(full.count, 1, "fixture must have enough messages to page")

        let firstPage = try await MessageParser.parse(filePath: path, source: "codex", offset: 0, limit: 1)
        XCTAssertEqual(firstPage.count, 1)
        // "Load all" continues from the loaded count to the end (limit nil).
        let remainder = try await MessageParser.parse(filePath: path, source: "codex", offset: firstPage.count, limit: nil)
        XCTAssertEqual(remainder.count, full.count - firstPage.count)

        let paged = (firstPage + remainder).map { ($0.role, $0.content) }
        let whole = full.map { ($0.role, $0.content) }
        XCTAssertEqual(paged.map(\.0), whole.map(\.0))
        XCTAssertEqual(paged.map(\.1), whole.map(\.1))
    }

    /// Iflow streamMessages throws on the message cap, so MessageParser used to
    /// return nil from the adapter path and parseLegacy loaded the whole file.
    /// invariant: MESSAGEPARSER-METADATA-001
    func testIflowOversizedParseUsesAdapterPrefixNotLegacyFullFile_repro() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-iflow-parser-cap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("session-oversized-parse.jsonl")

        let cap = ParserLimits.default.maxMessages
        var lines: [String] = []
        lines.reserveCapacity(cap + 1)
        for index in 0..<(cap + 1) {
            let role = index % 2 == 0 ? "user" : "assistant"
            lines.append(
                #"{"type":"\#(role)","timestamp":"2026-08-14T00:00:00.000Z","message":{"role":"\#(role)","content":"iflow parse turn \#(index)"}}"#
            )
        }
        try lines.joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)

        let messages = try await MessageParser.parse(filePath: file.path, source: "iflow")
        XCTAssertEqual(messages.count, cap)
        XCTAssertEqual(messages.first?.content, "iflow parse turn 0")
        XCTAssertEqual(messages.last?.content, "iflow parse turn \(cap - 1)")
    }

    func testRegisteredAdapterFailureNeverFallsBackToLegacyParser_repro() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-adapter-failure-no-legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("iflow-line-too-large.jsonl")
        let valid = #"{"type":"user","timestamp":"2026-08-21T00:00:00Z","message":{"role":"user","content":"legacy-visible"}}"#
        let oversized = String(repeating: "x", count: ParserLimits.default.maxLineBytes + 1)
        try (valid + "\n" + oversized + "\n").write(to: file, atomically: true, encoding: .utf8)

        let parsed = try await MessageParser.parse(filePath: file.path, source: "iflow")
        let windowed = try await MessageParser.parseWindowed(
            filePath: file.path,
            source: "iflow",
            offset: 0,
            limit: 10
        )

        XCTAssertEqual(parsed.map(\.content), ["legacy-visible"])
        XCTAssertEqual(windowed.messages.map(\.content), ["legacy-visible"])
        XCTAssertEqual(windowed.producedCount, 1)
        XCTAssertFalse(windowed.truncated, "a parser failure is distinct from the produced-message cap")
        XCTAssertTrue(windowed.parseFailed, "the retained prefix must still report the parser failure")
    }

    func testMetadataConstructionFailureKeepsFallbackStreamPrefix_repro() async throws {
        let result = try await MessageParser.adapterMessages(
            adapter: MetadataThrowingPrefixAdapter(),
            locator: "/tmp/unused",
            source: "iflow",
            options: StreamMessagesOptions()
        )

        XCTAssertEqual(result.messages.map(\.content), ["retained-prefix"])
        XCTAssertEqual(result.producedCount, 1)
        XCTAssertFalse(result.truncated)
        XCTAssertTrue(result.parseFailed)
    }

    func testMetadataAndCappedFallbackKeepProducedPrefix_repro() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-dual-constructor-prefix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("qwen.jsonl")
        let lines = (0..<4).map { index in
            let type = index.isMultiple(of: 2) ? "user" : "assistant"
            return #"{"type":"\#(type)","sessionId":"dual-prefix","message":{"role":"\#(type)","parts":[{"text":"m\#(index)"}]}}"#
        }
        try lines.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = MetadataThrowingCappedQwenAdapter(
            inner: QwenAdapter(projectsRoot: dir.path, limits: ParserLimits(maxMessages: 3))
        )
        let result = try await MessageParser.adapterMessages(
            adapter: adapter,
            locator: file.path,
            source: "qwen",
            options: StreamMessagesOptions()
        )

        XCTAssertEqual(result.messages.map(\.content), ["m0", "m1", "m2"])
        XCTAssertEqual(result.producedCount, 3)
        XCTAssertTrue(result.parseFailed)
    }

    func testParseWindowedReportsAdapterTruncation_repro() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-window-truncation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("iflow-over-cap.jsonl")
        let cap = ParserLimits.default.maxMessages
        let lines = (0...cap).map { index -> String in
            let role = index % 2 == 0 ? "user" : "assistant"
            return #"{"type":"\#(role)","message":{"role":"\#(role)","content":"m\#(index)"}}"#
        }
        try lines.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let result = try await MessageParser.parseWindowed(
            filePath: file.path,
            source: "iflow",
            offset: 0,
            limit: nil
        )

        XCTAssertEqual(result.producedCount, cap)
        XCTAssertTrue(result.truncated)
    }

    func testParseWindowedPagesStopAtParserMaxMessages_repro() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-window-max-pages-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("iflow-over-page-cap.jsonl")
        let cap = ParserLimits.default.maxMessages
        let lines = (0...cap).map { index -> String in
            #"{"type":"user","message":{"role":"user","content":"page\#(index)"}}"#
        }
        try lines.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        var offset = 0
        var collected = 0
        var sawTruncation = false
        while true {
            let page = try await MessageParser.parseWindowed(
                filePath: file.path,
                source: "iflow",
                offset: offset,
                limit: 500
            )
            collected += page.producedCount
            offset += page.producedCount
            sawTruncation = page.truncated
            if page.truncated || page.producedCount < 500 { break }
        }
        XCTAssertEqual(collected, cap)
        XCTAssertTrue(sawTruncation)
    }

    /// Adapter path must thread `NormalizedMessage.timestamp` into `ChatMessage`
    /// (row 30 production path). Uses Codex JSONL so the adapter stream is hit
    /// without a Claude profile root. Fails if MessageParser drops the field.
    func testAdapterPathThreadsTimestamp() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-ts-thread-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("rollout-ts-stamp.jsonl")
        let lines = [
            #"{"timestamp":"2026-07-25T10:00:00.000Z","type":"session_meta","payload":{"id":"ts-stamp","timestamp":"2026-07-25T10:00:00.000Z","cwd":"/repo"}}"#,
            #"{"timestamp":"2026-07-25T10:00:00.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hello stamped"}]}}"#,
            #"{"timestamp":"2026-07-25T10:00:05.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"hi stamped"}]}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: path, atomically: true, encoding: .utf8)

        let stamped = try await MessageParser.parse(filePath: path.path, source: "codex")
        XCTAssertEqual(stamped.count, 2, stamped.map(\.content).description)
        XCTAssertEqual(stamped[0].timestamp, "2026-07-25T10:00:00.000Z")
        XCTAssertEqual(stamped[1].timestamp, "2026-07-25T10:00:05.000Z")

        // Legacy parser path leaves timestamp nil (defaulted field).
        let legacyPath = try fixturePath("claude-code.jsonl")
        // Force legacy by using a source that hits parseLegacy without adapter
        // timestamps on every row — parse with claude-code fixture via legacy
        // happens only when adapter fails; instead assert ChatMessage default
        // and that adapterMessages threading is the production site under test.
        let legacy = MessageParser.parseLegacy(filePath: legacyPath, source: "claude-code")
        // Fixture rows that lack timestamps must not invent them. If the adapter
        // path is used and the fixture has timestamps, non-nil is fine; we only
        // require no crash and that explicit missing stays nil via bare construct.
        XCTAssertFalse(legacy.isEmpty)
        let bare = ChatMessage(role: "user", content: "x", systemCategory: .none)
        XCTAssertNil(bare.timestamp)
    }

    func testClaudeCustomProfileReplayAndWindowingUseResolverBackedRegistry() async throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-message-parser-claude-profile-\(UUID().uuidString)", isDirectory: true)
        let homeDirectory = fixtureRoot.appendingPathComponent("home", isDirectory: true)
        let projectsRoot = fixtureRoot.appendingPathComponent("custom/projects", isDirectory: true)
        let projectDirectory = projectsRoot.appendingPathComponent("-Users-custom", isDirectory: true)
        let settingsURL = homeDirectory.appendingPathComponent(".engram/settings.json")
        let locator = projectDirectory.appendingPathComponent("custom.jsonl")
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let settings = try JSONSerialization.data(
            withJSONObject: [
                "claudeCodeProfiles": [
                    "autoDiscover": false,
                    "customProjectsRoots": [projectsRoot.path],
                ],
            ]
        )
        try settings.write(to: settingsURL)
        let lines = [
            ##"{"type":"user","sessionId":"custom","timestamp":"2026-07-13T00:00:00Z","message":{"role":"user","content":"# AGENTS.md instructions for custom"}}"##,
            #"{"type":"user","sessionId":"custom","timestamp":"2026-07-13T00:00:01Z","message":{"role":"user","content":"visible request"}}"#,
            #"{"type":"assistant","sessionId":"custom","timestamp":"2026-07-13T00:00:02Z","message":{"role":"assistant","model":"claude-sonnet-4","content":"visible response"}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: locator, atomically: true, encoding: .utf8)
        let resolver = ClaudeCodeProfileResolver(homeDirectory: homeDirectory, settingsURL: settingsURL)

        let full = try await MessageParser.parse(
            filePath: locator.path,
            source: "claude-code",
            claudeCodeProfileResolver: resolver
        )
        XCTAssertEqual(
            full.map(\.content),
            ["# AGENTS.md instructions for custom", "visible request", "visible response"]
        )
        XCTAssertEqual(full.first?.systemCategory, .systemPrompt)

        let firstPage = try await MessageParser.parseWindowed(
            filePath: locator.path,
            source: "claude-code",
            offset: 0,
            limit: 1,
            claudeCodeProfileResolver: resolver
        )
        XCTAssertEqual(firstPage.producedCount, 1)
        XCTAssertEqual(firstPage.messages.map(\.content), ["# AGENTS.md instructions for custom"])
        XCTAssertEqual(firstPage.messages.first?.systemCategory, .systemPrompt)

        let secondPage = try await MessageParser.parseWindowed(
            filePath: locator.path,
            source: "claude-code",
            offset: firstPage.producedCount,
            limit: 1,
            claudeCodeProfileResolver: resolver
        )
        XCTAssertEqual(secondPage.producedCount, 1)
        XCTAssertEqual(secondPage.messages.map(\.content), ["visible request"])

        let thirdPage = try await MessageParser.parseWindowed(
            filePath: locator.path,
            source: "claude-code",
            offset: firstPage.producedCount + secondPage.producedCount,
            limit: 1,
            claudeCodeProfileResolver: resolver
        )
        XCTAssertEqual(thirdPage.producedCount, 1)
        XCTAssertEqual(thirdPage.messages.map(\.content), ["visible response"])
    }

    func testMessageParserUsesInjectedHomeForAdapterRegistry_repro() async throws {
        // docs/invariants.md #6: the UI parser must not construct adapters from
        // the production home while running against a temporary transcript.
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-message-parser-home-\(UUID().uuidString)", isDirectory: true)
        let homeDirectory = fixtureRoot.appendingPathComponent("home", isDirectory: true)
        let projectDirectory = homeDirectory
            .appendingPathComponent(".claude/projects/-Users-injected", isDirectory: true)
        let locator = projectDirectory.appendingPathComponent("injected.jsonl")
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        try (#"{"type":"user","sessionId":"injected","timestamp":"2026-08-23T00:00:00Z","message":{"role":"user","content":"injected request"}}"# + "\n")
            .write(to: locator, atomically: true, encoding: .utf8)

        let messages = try await MessageParser.parse(
            filePath: locator.path,
            source: "claude-code",
            homeDirectory: homeDirectory
        )

        XCTAssertEqual(messages.map(\.content), ["injected request"])
    }

    /// `parseWindowed` reports a PRODUCED count that includes filtered (tool)
    /// messages, so the detail-view pager advances its offset in produced-message
    /// space. Paging by the displayable count instead (the pre-fix behaviour)
    /// drifts at the seam and can falsely conclude "no more" when tool messages
    /// thin the page. with-tools.jsonl: [user, assistant(tool_use), tool_result,
    /// assistant(text), user] — the tool_result is produced but filtered out.
    func testParseWindowedReportsProducedCountIncludingFilteredToolMessages() async throws {
        // Codex emits .tool messages for function_call / function_call_output; the
        // UI parser filters them out, so PRODUCED > displayable. The pager must
        // advance its offset in produced space (this test's contract) — using the
        // displayable count would drift at the seam and could falsely truncate.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pagewindow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("rollout-pagewindow.jsonl").path
        let lines = [
            #"{"timestamp":"2026-05-20T00:00:00.000Z","type":"session_meta","payload":{"id":"pagewindow","timestamp":"2026-05-20T00:00:00.000Z","cwd":"/repo"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"u0"}]}}"#,
            #"{"type":"response_item","payload":{"type":"function_call","name":"bash","arguments":"ls"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call_output","output":"file1"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"a0"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"u1"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"a1"}]}}"#
        ]
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let full = try await MessageParser.parse(filePath: path, source: "codex")
        XCTAssertEqual(full.map(\.content), ["u0", "a0", "u1", "a1"])

        // First 3 PRODUCED messages: user, function_call, function_call_output —
        // only the user survives filtering, so produced (3) > displayable (1).
        let page1 = try await MessageParser.parseWindowed(filePath: path, source: "codex", offset: 0, limit: 3)
        XCTAssertEqual(page1.producedCount, 3)
        XCTAssertLessThan(page1.messages.count, page1.producedCount)
        XCTAssertEqual(page1.messages.map(\.content), ["u0"])

        // Page through in produced-space windows of 2, advancing by producedCount.
        // The union must reconstruct the full transcript with no seam gap/dup —
        // the property that breaks if the pager advances by the displayable count.
        var collected: [ChatMessage] = []
        var producedOffset = 0
        while true {
            let page = try await MessageParser.parseWindowed(filePath: path, source: "codex", offset: producedOffset, limit: 2)
            collected += page.messages
            producedOffset += page.producedCount
            if page.producedCount < 2 { break }
        }
        XCTAssertEqual(collected.map(\.content), full.map(\.content))
    }

    /// 13. Unknown source returns empty array
    func testUnknownSourceReturnsEmpty() async throws {
        let path = try fixturePath("valid.jsonl")
        let messages = try await MessageParser.parse(filePath: path, source: "unknown-source")
        XCTAssertTrue(messages.isEmpty)
    }

    /// 14. Nonexistent file returns empty array
    func testNonexistentFileReturnsEmpty() async throws {
        let messages = try await MessageParser.parse(filePath: "/nonexistent/path.jsonl", source: "claude-code")
        XCTAssertTrue(messages.isEmpty)
    }

    /// 15. classifySystem unit tests — direct call
    func testClassifySystemCategories() async throws {
        // System prompts
        XCTAssertEqual(
            MessageParser.classifySystem(content: "<system-reminder>test</system-reminder>", source: "claude-code"),
            .systemPrompt
        )
        XCTAssertEqual(
            MessageParser.classifySystem(content: "<environment_context>macOS</environment_context>", source: "claude-code"),
            .systemPrompt
        )
        XCTAssertEqual(
            MessageParser.classifySystem(content: "# AGENTS.md instructions for project", source: "claude-code"),
            .systemPrompt
        )
        XCTAssertEqual(
            MessageParser.classifySystem(content: "You are Qwen Code...", source: "qwen"),
            .systemPrompt
        )
        XCTAssertEqual(
            MessageParser.classifySystem(content: "\n<SYSTEM_MESSAGE>not sent by user", source: "antigravity"),
            .systemPrompt
        )
        XCTAssertEqual(
            MessageParser.classifySystem(content: "\n<SYSTEM_MESSAGE>user pasted wrapper", source: "codex"),
            .none
        )

        // Agent communication
        XCTAssertEqual(
            MessageParser.classifySystem(content: "<local-command-caveat>warning</local-command-caveat>", source: "claude-code"),
            .agentComm
        )
        XCTAssertEqual(
            MessageParser.classifySystem(content: "text with <command-name>test</command-name>", source: "claude-code"),
            .agentComm
        )
        XCTAssertEqual(
            MessageParser.classifySystem(
                content: "\n<subagent_notification>\n{\"agent_path\":\"agent-1\"}\n</subagent_notification>",
                source: "codex"
            ),
            .agentComm
        )

        // Normal content
        XCTAssertEqual(
            MessageParser.classifySystem(content: "Hello, how are you?", source: "claude-code"),
            .none
        )
    }

    func testClassifySystemMatchesSharedTranscriptDisplayFixtures() async throws {
        guard let path = Bundle(for: type(of: self)).path(
            forResource: "system-classification-cases",
            ofType: "json",
            inDirectory: "test-fixtures/transcript-display"
        ) else {
            return XCTFail("missing shared transcript display classification fixture")
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let cases = try JSONDecoder().decode([ClassificationFixtureCase].self, from: data)

        for fixtureCase in cases {
            let expected: SystemCategory
            switch fixtureCase.category {
            case "systemPrompt":
                expected = .systemPrompt
            case "agentComm":
                expected = .agentComm
            case "none":
                expected = .none
            default:
                return XCTFail("unknown category \(fixtureCase.category) in \(fixtureCase.name)")
            }

            XCTAssertEqual(
                MessageParser.classifySystem(content: fixtureCase.content, source: fixtureCase.source),
                expected,
                fixtureCase.name
            )
        }
    }

    func testRemoteLocatorRendersSnapshotNotFilesystem_repro() async throws {
        let parsed = try await MessageParser.parseWindowed(
            filePath: "remote://hq/native-id",
            source: "codex",
            offset: 0,
            limit: 10
        )
        XCTAssertEqual(parsed.messages.first?.content, "HQ 索引快照，不是源文件")
        XCTAssertFalse(parsed.parseFailed)
        XCTAssertGreaterThanOrEqual(parsed.producedCount, 1)
    }
}
