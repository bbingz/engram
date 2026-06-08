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

    func testTerminalLauncherShellCommandEscapesMetacharacters() {
        let rendered = TerminalLauncher.shellCommandLine(
            command: "codex; touch /tmp/pwned",
            args: ["--resume", "$(touch /tmp/pwned)", "quote'and space"],
            cwd: "/tmp/a; touch /tmp/pwned"
        )

        XCTAssertEqual(
            rendered,
            "cd '/tmp/a; touch /tmp/pwned' && 'codex; touch /tmp/pwned' --resume '$(touch /tmp/pwned)' 'quote'\\''and space'"
        )
    }

    func testTerminalLauncherAppleScriptCommandEscapesAfterShellQuoting() {
        let rendered = TerminalLauncher.appleScriptCommandLine(
            command: "co\"dex",
            args: ["back\\slash", "$HOME"],
            cwd: "/tmp/path with spaces"
        )

        XCTAssertEqual(
            rendered,
            "cd '/tmp/path with spaces' && 'co\\\"dex' 'back\\\\slash' '$HOME'"
        )
    }

    func testTerminalLauncherAvailableTerminalTypesFiltersUnavailableThirdPartyApps() {
        let terminals = TerminalLauncher.availableTerminalTypes(
            bundleIdentifierIsInstalled: { $0 == "com.apple.Terminal" },
            applicationPathExists: { _ in false }
        )

        XCTAssertEqual(terminals, [.terminal])
    }

    func testTerminalLauncherAvailableTerminalTypesIncludesInstalledThirdPartyApps() {
        let terminals = TerminalLauncher.availableTerminalTypes(
            bundleIdentifierIsInstalled: { $0 == "com.apple.Terminal" || $0 == "com.mitchellh.ghostty" },
            applicationPathExists: { _ in false }
        )

        XCTAssertEqual(terminals, [.terminal, .ghostty])
    }

    func testTerminalLauncherAvailableTerminalTypesIncludesWarpWhenInstalled() {
        let terminals = TerminalLauncher.availableTerminalTypes(
            bundleIdentifierIsInstalled: { $0 == "dev.warp.Warp-Stable" },
            applicationPathExists: { _ in false }
        )

        XCTAssertEqual(terminals, [.warp])
    }

    func testTerminalLauncherWarpTabConfigUsesTerminalPane() {
        let toml = TerminalLauncher.warpTabConfigTOML(
            configName: "engram-resume-test",
            command: "'/usr/local/bin/codex' resume 'abc123'",
            directory: "/Users/test/project"
        )

        XCTAssertTrue(toml.contains(#"name = "engram-resume-test""#))
        XCTAssertTrue(toml.contains(#"type = "terminal""#))
        XCTAssertTrue(toml.contains(#"directory = "/Users/test/project""#))
        XCTAssertTrue(toml.contains(#"commands = ["'/usr/local/bin/codex' resume 'abc123'"]"#))
    }

    func testTerminalLauncherWarpTabConfigEscapesTomlStrings() {
        let toml = TerminalLauncher.warpTabConfigTOML(
            configName: "engram-resume-escape",
            command: "echo \"hi\" && printf 'a\\b\nc\td\r'",
            directory: #"/tmp/dir "quote"\slash"#
        )

        XCTAssertTrue(toml.contains(#"directory = "/tmp/dir \"quote\"\\slash""#))
        XCTAssertTrue(toml.contains(#"commands = ["echo \"hi\" && printf 'a\\b\nc\td\r'"]"#))
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

    func testRenderOptionsJSONReturnsErrorPayloadWithContextPrimer() async throws {
        let client = MockEngramServiceClient(resumeCommand: EngramServiceResumeCommandResponse(
            contextPrimer: """
            Resume context from Engram archive:
            - recover from archived transcript
            """,
            error: "Resume command unavailable",
            hint: "Install codex"
        ))
        let options = EngramCLIResumeOptions(sessionId: "session-1", socketPath: "/tmp/engram.sock", json: true)

        let rendered = try await EngramCLIResumeCommand.render(options: options, client: client)
        let decoded = try JSONDecoder().decode(
            EngramServiceResumeCommandResponse.self,
            from: Data(rendered.utf8)
        )

        XCTAssertEqual(decoded.error, "Resume command unavailable")
        XCTAssertEqual(decoded.hint, "Install codex")
        XCTAssertEqual(decoded.contextPrimer, """
        Resume context from Engram archive:
        - recover from archived transcript
        """)
    }

    func testRenderShellCommandAppendsContextPrimerAsComments() throws {
        let response = EngramServiceResumeCommandResponse(
            tool: "codex",
            command: "codex",
            args: ["--resume", "session-1"],
            cwd: "/repo",
            contextPrimer: """
            Resume context from Engram archive:
            - keep database migrations reversible
            - avoid shell metacharacter expansion: $(touch /tmp/pwned)
            """
        )

        let rendered = try EngramCLIResumeCommand.render(response: response, json: false)

        XCTAssertEqual(rendered, """
        cd /repo && codex --resume session-1

        # Engram context primer:
        # Resume context from Engram archive:
        # - keep database migrations reversible
        # - avoid shell metacharacter expansion: $(touch /tmp/pwned)
        """)
    }

    func testRenderOptionsNonJSONReturnsContextPrimerWhenResumeCommandErrors() async throws {
        let client = MockEngramServiceClient(resumeCommand: EngramServiceResumeCommandResponse(
            contextPrimer: """
            Resume context from Engram archive:
            - recover decisions from the persisted transcript
            """,
            error: "Resume command unavailable",
            hint: "Install codex"
        ))
        let options = EngramCLIResumeOptions(sessionId: "session-1", socketPath: "/tmp/engram.sock", json: false)

        let rendered = try await EngramCLIResumeCommand.render(options: options, client: client)

        XCTAssertEqual(rendered, """
        # Engram resume command unavailable: Resume command unavailable
        # Install codex
        #
        # Engram context primer:
        # Resume context from Engram archive:
        # - recover decisions from the persisted transcript
        """)
    }
}
