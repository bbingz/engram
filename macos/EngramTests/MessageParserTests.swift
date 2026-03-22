// macos/EngramTests/MessageParserTests.swift
import XCTest
@testable import Engram

final class MessageParserTests: XCTestCase {

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

    // MARK: - claude-code format (type/message)

    /// 1. Parse claude-code JSONL with string and array content
    func testParseClaudeCodeFormat() throws {
        let path = try fixturePath("claude-code.jsonl")
        let messages = MessageParser.parse(filePath: path, source: "claude-code")

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
    func testParseCodexFormat() throws {
        let path = try fixturePath("codex.jsonl")
        let messages = MessageParser.parse(filePath: path, source: "codex")

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, "user")
        XCTAssertEqual(messages[0].content, "Hello from Codex")
        XCTAssertEqual(messages[1].role, "assistant")
        XCTAssertEqual(messages[1].content, "Codex response here")
    }

    /// 3. Parse gemini-cli format (whole-file JSON with messages array)
    func testParseGeminiFormat() throws {
        let path = try fixturePath("gemini.json")
        let messages = MessageParser.parse(filePath: path, source: "gemini-cli")

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
        let messages = MessageParser.parse(filePath: path, source: "claude-code")

        // malformed.jsonl: 1 unparseable, 1 missing message field, 1 empty message content
        XCTAssertEqual(messages.count, 0, "All malformed entries should be skipped")
    }

    /// 5. Empty file returns empty array
    func testEmptyFileReturnsEmpty() throws {
        let path = try fixturePath("empty.jsonl")
        let messages = MessageParser.parse(filePath: path, source: "claude-code")
        XCTAssertTrue(messages.isEmpty)
    }

    /// 6. Mixed valid/invalid lines — empty content skipped, whitespace-only content kept
    func testMixedValidInvalid() throws {
        let path = try fixturePath("empty-content.jsonl")
        let messages = MessageParser.parse(filePath: path, source: "claude-code")

        // empty-content.jsonl: "" is skipped (isEmpty), "valid" kept, "   " kept (not empty, just whitespace)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].content, "valid")
        XCTAssertEqual(messages[1].content, "   ")
    }

    /// 7. CJK content preserved in claude-code format
    func testCJKContentPreserved() throws {
        let path = try fixturePath("cjk-claude.jsonl")
        let messages = MessageParser.parse(filePath: path, source: "claude-code")

        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0].content, "请帮我写一个函数")
        XCTAssertEqual(messages[1].content, "好的，这是函数实现")
        XCTAssertEqual(messages[2].content, "ありがとう")
    }

    /// 8. Kimi format (role/content, no skip)
    func testParseKimiFormat() throws {
        let path = try fixturePath("kimi.jsonl")
        let messages = MessageParser.parse(filePath: path, source: "kimi")

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, "user")
        XCTAssertEqual(messages[0].content, "Hello Kimi")
        XCTAssertEqual(messages[1].role, "assistant")
    }

    /// 9. Antigravity format (role/content, skips first line)
    func testParseAntigravityFormat() throws {
        let path = try fixturePath("antigravity.jsonl")
        let messages = MessageParser.parse(filePath: path, source: "antigravity")

        // First line is metadata, should be skipped
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].content, "Hello Antigravity")
        XCTAssertEqual(messages[1].content, "Hi from Antigravity")
    }

    /// 10. Copilot format (type-based with data.content)
    func testParseCopilotFormat() throws {
        let path = try fixturePath("copilot.jsonl")
        let messages = MessageParser.parse(filePath: path, source: "copilot")

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, "user")
        XCTAssertEqual(messages[0].content, "Hello Copilot")
        XCTAssertEqual(messages[1].role, "assistant")
        XCTAssertEqual(messages[1].content, "Hi from Copilot")
    }

    /// 11. Cline format (whole-file JSON array with say/text)
    func testParseClineFormat() throws {
        let path = try fixturePath("cline.json")
        let messages = MessageParser.parse(filePath: path, source: "cline")

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
    func testSystemPromptDetection() throws {
        let path = try fixturePath("system-prompts.jsonl")
        let messages = MessageParser.parse(filePath: path, source: "claude-code")

        XCTAssertEqual(messages.count, 4)
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

    /// 13. Unknown source returns empty array
    func testUnknownSourceReturnsEmpty() throws {
        let path = try fixturePath("valid.jsonl")
        let messages = MessageParser.parse(filePath: path, source: "vscode")
        XCTAssertTrue(messages.isEmpty)
    }

    /// 14. Nonexistent file returns empty array
    func testNonexistentFileReturnsEmpty() throws {
        let messages = MessageParser.parse(filePath: "/nonexistent/path.jsonl", source: "claude-code")
        XCTAssertTrue(messages.isEmpty)
    }

    /// 15. classifySystem unit tests — direct call
    func testClassifySystemCategories() throws {
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

        // Agent communication
        XCTAssertEqual(
            MessageParser.classifySystem(content: "<local-command-caveat>warning</local-command-caveat>", source: "claude-code"),
            .agentComm
        )
        XCTAssertEqual(
            MessageParser.classifySystem(content: "text with <command-name>test</command-name>", source: "claude-code"),
            .agentComm
        )

        // Normal content
        XCTAssertEqual(
            MessageParser.classifySystem(content: "Hello, how are you?", source: "claude-code"),
            .none
        )
    }
}
