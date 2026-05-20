import XCTest
import EngramCoreRead
@testable import EngramServiceCore

final class EngramWebUIServerTests: XCTestCase {
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
}
