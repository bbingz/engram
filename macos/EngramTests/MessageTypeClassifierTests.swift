// macos/EngramTests/MessageTypeClassifierTests.swift
import XCTest
@testable import Engram

final class MessageTypeClassifierTests: XCTestCase {

    // MARK: - Helpers

    private func msg(role: String, content: String, systemCategory: SystemCategory = .none) -> ChatMessage {
        ChatMessage(role: role, content: content, systemCategory: systemCategory)
    }

    // MARK: - Basic role classification

    func testUserMessageClassifiedAsUser() {
        let m = msg(role: "user", content: "Please fix the bug in main.swift")
        XCTAssertEqual(MessageTypeClassifier.classify(m), .user)
    }

    func testAssistantPlainTextClassifiedAsAssistant() {
        let m = msg(role: "assistant", content: "I have reviewed the code and here is my analysis of the problem.")
        XCTAssertEqual(MessageTypeClassifier.classify(m), .assistant)
    }

    // MARK: - System category

    func testSystemPromptClassifiedAsSystem() {
        let m = msg(role: "user", content: "CLAUDE.md contents...", systemCategory: .systemPrompt)
        XCTAssertEqual(MessageTypeClassifier.classify(m), .system)
    }

    func testAgentCommClassifiedAsToolCall() {
        // agentComm without tool result patterns defaults to toolCall
        let m = msg(role: "assistant", content: "Running subagent task", systemCategory: .agentComm)
        XCTAssertEqual(MessageTypeClassifier.classify(m), .toolCall)
    }

    func testAgentCommWithToolResultPattern() {
        let m = msg(role: "assistant", content: "tool_result: success", systemCategory: .agentComm)
        XCTAssertEqual(MessageTypeClassifier.classify(m), .toolResult)
    }

    // MARK: - Tool call detection

    func testToolCallPatternDetected() {
        let m = msg(role: "assistant", content: "`Read`: /Users/test/file.swift\nContents of the file...")
        XCTAssertEqual(MessageTypeClassifier.classify(m), .toolCall)
    }

    func testToolCallWithExplicitErrorClassifiedAsError() {
        let m = msg(role: "assistant", content: "`Bash`: npm test\nExit code: 1\nTests failed")
        XCTAssertEqual(MessageTypeClassifier.classify(m), .error)
    }

    // MARK: - Tool result detection

    func testToolResultPatternDetected() {
        let m = msg(role: "assistant", content: "<local-command-stdout>some output here</local-command-stdout>")
        XCTAssertEqual(MessageTypeClassifier.classify(m), .toolResult)
    }

    // MARK: - Thinking detection

    func testThinkingPatternDetected() {
        let m = msg(role: "assistant", content: "<thinking>Let me analyze the problem step by step...</thinking>")
        XCTAssertEqual(MessageTypeClassifier.classify(m), .thinking)
    }

    // MARK: - Error detection

    func testErrorPatternDetected() {
        let m = msg(role: "assistant", content: "Error: Cannot find module 'express' in the project dependencies")
        XCTAssertEqual(MessageTypeClassifier.classify(m), .error)
    }

    // MARK: - Code block detection

    func testSignificantCodeBlockClassifiedAsCode() {
        // Code block must be > 50% of total content
        let code = "```swift\nfunc hello() {\n    print(\"Hello, World!\")\n}\n```"
        let m = msg(role: "assistant", content: code)
        XCTAssertEqual(MessageTypeClassifier.classify(m), .code)
    }

    func testSmallCodeBlockNotClassifiedAsCode() {
        // Code block < 50% of content: should be .assistant
        let content = "Here is a long explanation of the problem that is much longer than the code block itself. " +
            "We need to consider many factors when solving this issue. ```x``` The fix is straightforward."
        let m = msg(role: "assistant", content: content)
        XCTAssertEqual(MessageTypeClassifier.classify(m), .assistant)
    }

    // MARK: - Edge cases

    func testEmptyContentAssistantClassifiedAsAssistant() {
        let m = msg(role: "assistant", content: "")
        XCTAssertEqual(MessageTypeClassifier.classify(m), .assistant)
    }

    func testGenericToolPatternFallback() {
        // "Tool:" is in toolPatterns but not in toolCallPatterns or toolResultPatterns
        let m = msg(role: "assistant", content: "Tool: some generic tool output")
        XCTAssertEqual(MessageTypeClassifier.classify(m), .tool)
    }
}
