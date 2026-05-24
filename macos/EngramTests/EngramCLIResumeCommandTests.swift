import XCTest
@testable import Engram

final class EngramCLIResumeCommandTests: XCTestCase {
    func testParseResumeSubcommandUsesServiceSocketEnvironment() throws {
        let options = try XCTUnwrap(EngramCLIResumeOptions.parse(
            arguments: ["resume", "session-1", "--json"],
            environment: ["ENGRAM_SERVICE_SOCKET": "/tmp/custom.sock"]
        ))

        XCTAssertEqual(options.sessionId, "session-1")
        XCTAssertEqual(options.socketPath, "/tmp/custom.sock")
        XCTAssertTrue(options.json)
    }

    func testParseLegacyResumeFlag() throws {
        let options = try XCTUnwrap(EngramCLIResumeOptions.parse(
            arguments: ["--resume", "session-2"],
            environment: [:]
        ))

        XCTAssertEqual(options.sessionId, "session-2")
        XCTAssertFalse(options.json)
    }

    func testRenderShellCommandEscapesCwdAndArgs() throws {
        let response = EngramServiceResumeCommandResponse(
            tool: "codex",
            command: "codex",
            args: ["--resume", "session with space"],
            cwd: "/Users/test/Project's Name"
        )

        let rendered = try EngramCLIResumeCommand.render(response: response, json: false)

        XCTAssertEqual(
            rendered,
            "cd '/Users/test/Project'\\''s Name' && codex --resume 'session with space'"
        )
    }

    func testRenderJSONReturnsServicePayload() throws {
        let response = EngramServiceResumeCommandResponse(
            tool: "codex",
            command: "codex",
            args: ["--resume", "session-1"],
            cwd: "/repo"
        )

        let rendered = try EngramCLIResumeCommand.render(response: response, json: true)

        let decoded = try JSONDecoder().decode(
            EngramServiceResumeCommandResponse.self,
            from: Data(rendered.utf8)
        )
        XCTAssertEqual(decoded.command, "codex")
        XCTAssertEqual(decoded.cwd, "/repo")
    }
}
