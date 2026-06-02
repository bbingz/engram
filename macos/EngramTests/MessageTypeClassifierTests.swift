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

    func testAgentCommClassifiedAsSystem() {
        // agentComm is plumbing (command-name / skill invocation / local-command-*),
        // not a model-issued tool call — must NOT inflate tool chip counts.
        let m = msg(role: "assistant", content: "Running subagent task", systemCategory: .agentComm)
        XCTAssertEqual(MessageTypeClassifier.classify(m), .system)
    }

    func testAgentCommWithToolResultPatternStillSystem() {
        // Even when the body looks like a tool result, agentComm stays .system.
        let m = msg(role: "assistant", content: "tool_result: success", systemCategory: .agentComm)
        XCTAssertEqual(MessageTypeClassifier.classify(m), .system)
    }

    func testAgentCommNotInChipTypes() {
        // Regression guard for the inflated-tool-chip-count bug: .system is not a chip.
        XCTAssertFalse(MessageType.chipTypes.contains(.system))
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

    func testLineAnchoredErrorMarkerDetected() {
        // Error marker at the start of a (non-first) line still counts.
        let m = msg(role: "assistant", content: "Building the project...\nERROR cannot resolve symbol")
        XCTAssertEqual(MessageTypeClassifier.classify(m), .error)
    }

    func testProseErrorNotMisclassified() {
        // "error:" buried mid-sentence is prose, not an error message.
        let m = msg(role: "assistant", content: "I checked the logs and there was no error: everything looks fine here.")
        XCTAssertEqual(MessageTypeClassifier.classify(m), .assistant)
    }

    func testProseFailedNotMisclassified() {
        let m = msg(role: "assistant", content: "The previous attempt FAILED only because of a typo, which I have now fixed.")
        XCTAssertEqual(MessageTypeClassifier.classify(m), .assistant)
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

    func testUnbalancedFenceNotClassifiedAsCode() {
        // A single (unterminated) fence has an odd marker count — the dangling
        // region must NOT be counted as a code block.
        let m = msg(role: "assistant", content: "Quick note ```\nlong dangling text that follows the single fence and never closes")
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
