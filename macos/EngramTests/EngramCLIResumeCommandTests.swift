import Darwin
import XCTest
@testable import Engram

final class EngramCLIResumeCommandTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testParseResumeSubcommandUsesServiceSocketEnvironment() throws {
        let options = try XCTUnwrap(EngramCLIResumeOptions.parse(
            arguments: ["resume", "session-1", "--json"],
            environment: ["ENGRAM_SERVICE_SOCKET": "/tmp/custom.sock"]
        ))

        XCTAssertEqual(options.sessionId, "session-1")
        XCTAssertEqual(options.socketPath, "/tmp/custom.sock")
        XCTAssertTrue(options.json)
    }

    func testParseResumeSubcommandPrefersMCPServiceSocketEnvironment_repro() throws {
        let options = try XCTUnwrap(EngramCLIResumeOptions.parse(
            arguments: ["resume", "session-1"],
            environment: [
                "ENGRAM_MCP_SERVICE_SOCKET": "/tmp/mcp.sock",
                "ENGRAM_SERVICE_SOCKET": "/tmp/service.sock",
            ]
        ))
        XCTAssertEqual(options.socketPath, "/tmp/mcp.sock")
    }

    func testResumeRejectsRelativeOrBlankSocketFlag_repro() {
        for value in ["relative.sock", "relative/service.sock", "   "] {
            XCTAssertThrowsError(
                try EngramCLIResumeOptions.parse(
                    arguments: ["resume", "session-1", "--socket", value],
                    environment: [:]
                )
            )
        }
    }

    func testParseLegacyResumeFlag() throws {
        let options = try XCTUnwrap(EngramCLIResumeOptions.parse(
            arguments: ["--resume", "session-2"],
            environment: [:]
        ))

        XCTAssertEqual(options.sessionId, "session-2")
        XCTAssertFalse(options.json)
    }

    func testDefaultCLIStdioModeDelegatesToSwiftMCPHelper() throws {
        let cliMain = try source("macos/EngramCLI/main.swift")

        XCTAssertFalse(cliMain.contains(#"/tmp/engram.sock"#))
        XCTAssertFalse(cliMain.contains("POST /mcp HTTP/1.1"))
        XCTAssertTrue(cliMain.contains("EngramMCP"))
        XCTAssertTrue(cliMain.contains("execv"))
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

    func testRepoDetailClaudeActionUsesShellEscapedAppleScriptHelper() throws {
        let source = try source("macos/Engram/Views/Workspace/RepoDetailView.swift")

        XCTAssertTrue(source.contains("TerminalLauncher.appleScriptCommandLine(command: \"claude\", args: [], cwd: repo.path)"))
        XCTAssertFalse(source.contains("let safePath = TerminalLauncher.escapeForAppleScript(repo.path)"))
        XCTAssertFalse(source.contains("&& claude"), "RepoDetailView must not hand-build a shell cd command inside AppleScript")
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

    /// L-e / SEC-006: Warp tab configs carry resume cwd + session ids and must
    /// be owner-only even when the process umask would leave 0644.
    func testTerminalLauncherWarpTabConfigFileIsOwnerOnly0600_repro() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-warp-tab-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("engram-resume-test.toml")
        try Data("stale".utf8).write(to: file)
        XCTAssertEqual(chmod(file.path, 0o644), 0)

        let toml = TerminalLauncher.warpTabConfigTOML(
            configName: "engram-resume-test",
            command: "'/usr/local/bin/codex' resume 'abc123'",
            directory: "/Users/test/project"
        )
        try TerminalLauncher.writeWarpTabConfigFile(toml, to: file)

        var info = stat()
        XCTAssertEqual(lstat(file.path, &info), 0)
        XCTAssertEqual(
            info.st_mode & 0o777,
            0o600,
            "L-e: Warp tab config must be forced to 0600, got \(String(info.st_mode & 0o777, radix: 8))"
        )
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), toml)
    }

    func testTerminalLauncherLaunchInWarpUsesSecureTabConfigWriter() throws {
        let launcher = try source("macos/Engram/Views/Resume/TerminalLauncher.swift")
        XCTAssertTrue(
            launcher.contains("writeWarpTabConfigFile(toml, to: configFile)"),
            "L-e: launchInWarp must write through the 0600 helper"
        )
        XCTAssertFalse(
            launcher.contains("toml.write(to: configFile"),
            "L-e: launchInWarp must not write the tab config with default umask permissions"
        )
    }

    func testWarpConfigCleanupSurvivesCallerCancellationAfterOpen_repro() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("warp-config-lifetime-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("resume.toml")
        try "tab config".write(to: file, atomically: true, encoding: .utf8)
        let opened = expectation(description: "Warp accepted the tab configuration URL")

        let task = Task {
            try await TerminalLauncher.keepWarpTabConfigAlive(file, graceNanoseconds: 200_000_000) {
                XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
                opened.fulfill()
            }
        }
        await fulfillment(of: [opened], timeout: 1)
        try await task.value
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: file.path),
            "launch must return while Warp still has time to materialize the tab config"
        )
        task.cancel()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testWarpConfigKeepsGraceWhenSecondOpenFailsAfterLaunch_repro() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("warp-config-second-open-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("resume.toml")
        try "tab config".write(to: file, atomically: true, encoding: .utf8)

        do {
            try await TerminalLauncher.keepWarpTabConfigAlive(file, graceNanoseconds: 200_000_000) {
                // Models a successful openApplication followed by a failing or
                // cancelled warp://tab_config open.
                throw CancellationError()
            }
            XCTFail("expected second-step cancellation")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: file.path),
            "Warp may still be reading the file after the first launch step"
        )
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testWarpConfigIsRemovedAfterSuccessfulOpen_repro() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("warp-config-success-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("resume.toml")
        try "tab config".write(to: file, atomically: true, encoding: .utf8)

        try await TerminalLauncher.keepWarpTabConfigAlive(file, graceNanoseconds: 0) {}
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testWarpConfigIsNotWrittenUntilWarpCanBeResolved_repro() throws {
        let launcher = try source("macos/Engram/Views/Resume/TerminalLauncher.swift")
        let write = try XCTUnwrap(launcher.range(of: "try writeWarpTabConfigFile(toml, to: configFile)"))
        let resolveWarp = try XCTUnwrap(
            launcher.range(of: "let runningWarp")
        )
        let resolveApp = try XCTUnwrap(launcher.range(of: "guard let appURL"))

        XCTAssertLessThan(resolveWarp.lowerBound, write.lowerBound)
        XCTAssertLessThan(resolveApp.lowerBound, write.lowerBound)
        XCTAssertTrue(launcher.contains("graceNanoseconds: UInt64 = 30_000_000_000"))
        XCTAssertTrue(launcher.contains("Task.detached"))
        XCTAssertFalse(launcher.contains("defer { try? FileManager.default.removeItem(at: configFile) }"))
    }

    func testWarpSecureWriterCreatesOwnerOnlyFileBeforePublication_repro() throws {
        let launcher = try source("macos/Engram/Views/Resume/TerminalLauncher.swift")
        let writerStart = try XCTUnwrap(launcher.range(of: "static func writeWarpTabConfigFile"))
        let writerEnd = try XCTUnwrap(
            launcher.range(of: "static func keepWarpTabConfigAlive", range: writerStart.upperBound..<launcher.endIndex)
        )
        let writer = String(launcher[writerStart.lowerBound..<writerEnd.lowerBound])

        XCTAssertTrue(writer.contains("SecureRegularFile.writeAtomically"))
        XCTAssertFalse(writer.contains("toml.write(to: file, atomically:"))
        XCTAssertFalse(writer.contains("setAttributes"))
    }

    func testWarpTabConfigDirectoryIsOwnerOnlyBeforeConfigPublication_repro() throws {
        let launcher = try source("macos/Engram/Views/Resume/TerminalLauncher.swift")
        let launchStart = try XCTUnwrap(launcher.range(of: "private static func launchInWarp"))
        let configWrite = try XCTUnwrap(
            launcher.range(of: "try writeWarpTabConfigFile", range: launchStart.upperBound..<launcher.endIndex)
        )
        let setup = String(launcher[launchStart.lowerBound..<configWrite.lowerBound])

        XCTAssertTrue(setup.contains("attributes: [.posixPermissions: 0o700]"))
        XCTAssertTrue(setup.contains("setAttributes([.posixPermissions: 0o700]"))
    }

    func testWarpColdLaunchTargetsWarp_repro() throws {
        let launcher = try source("macos/Engram/Views/Resume/TerminalLauncher.swift")
        XCTAssertTrue(launcher.contains("private static func launchInWarp(shellCommand: String, cwd: String) async throws"))
        XCTAssertTrue(launcher.contains("try await NSWorkspace.shared.openApplication"))
        XCTAssertTrue(launcher.contains("try await launchInWarp(shellCommand: shellCmd, cwd: cwd)"))
        XCTAssertTrue(launcher.contains("keepWarpTabConfigAlive(configFile)"))
        XCTAssertTrue(launcher.contains("withApplicationAt: appURL"))
        XCTAssertTrue(launcher.contains("?new_window=true"))
        XCTAssertTrue(launcher.contains("Task.detached"))
        XCTAssertFalse(launcher.contains("NSWorkspace.shared.open(url)"))
    }

    func testTerminalLauncherGhosttyExecsShellForCompositeCommand() {
        let args = TerminalLauncher.ghosttyArguments(for: "cd '/repo' && codex resume 'session-1'")

        XCTAssertEqual(args, ["-e", "/bin/zsh", "-lc", "cd '/repo' && codex resume 'session-1'"])
    }

    func testTerminalLauncherReturnsLaunchFailuresInsteadOfSwallowingThem() throws {
        let launcher = try source("macos/Engram/Views/Resume/TerminalLauncher.swift")

        XCTAssertTrue(launcher.contains("enum LaunchError: LocalizedError"))
        XCTAssertTrue(launcher.contains("static func launch(command: String, args: [String], cwd: String, terminal: TerminalType) async throws -> Result<Void, LaunchError>"))
        XCTAssertFalse(launcher.contains("try? process.run()"))
        XCTAssertTrue(launcher.contains("return .failure(.appleScriptError("))
        XCTAssertTrue(launcher.contains("return .failure(.processRunFailed("))
        XCTAssertTrue(launcher.contains("return .failure(.warpLaunchFailed("))
    }

    func testTerminalLauncherRethrowsCancellationAndDialogCancelsLaunchTask_repro() throws {
        let launcher = try source("macos/Engram/Views/Resume/TerminalLauncher.swift")
        let dialog = try source("macos/Engram/Views/Resume/ResumeDialog.swift")

        XCTAssertTrue(launcher.contains("catch is CancellationError"))
        XCTAssertTrue(launcher.contains("throw CancellationError()"))
        XCTAssertTrue(dialog.contains("@State private var launchTask: Task<Void, Never>?"))
        XCTAssertTrue(dialog.contains("launchTask?.cancel()"))
        XCTAssertTrue(dialog.contains(".onDisappear"))
    }

    func testResumeInfoCancellationReturnsBeforePublishingViewState_repro() throws {
        let dialog = try source("macos/Engram/Views/Resume/ResumeDialog.swift")
        let fetchStart = try XCTUnwrap(dialog.range(of: "func fetchResumeInfo() async"))
        let fetchEnd = try XCTUnwrap(
            dialog.range(of: "private func copyContextPrimer", range: fetchStart.upperBound..<dialog.endIndex)
        )
        let fetch = String(dialog[fetchStart.lowerBound..<fetchEnd.lowerBound])
        let response = try XCTUnwrap(fetch.range(of: "let response = try await serviceClient.resumeCommand"))
        let cancellationCheck = try XCTUnwrap(fetch.range(of: "try Task.checkCancellation()"))
        let firstStateWrite = try XCTUnwrap(fetch.range(of: "fallbackContextPrimer = response.contextPrimer"))
        let cancellationCatch = try XCTUnwrap(fetch.range(of: "catch is CancellationError"))
        let genericCatch = try XCTUnwrap(fetch.range(of: "catch {", range: cancellationCatch.upperBound..<fetch.endIndex))
        let loadingWrite = try XCTUnwrap(fetch.range(of: "isLoading = false"))

        XCTAssertLessThan(response.lowerBound, cancellationCheck.lowerBound)
        XCTAssertLessThan(cancellationCheck.lowerBound, firstStateWrite.lowerBound)
        XCTAssertLessThan(cancellationCatch.lowerBound, genericCatch.lowerBound)
        XCTAssertLessThan(cancellationCatch.lowerBound, loadingWrite.lowerBound)
        let cancellationBranch = String(fetch[cancellationCatch.lowerBound..<genericCatch.lowerBound])
        XCTAssertTrue(cancellationBranch.contains("return"))
        XCTAssertFalse(cancellationBranch.contains("errorMessage ="))
        XCTAssertFalse(cancellationBranch.contains("resumeResult ="))
        XCTAssertFalse(cancellationBranch.contains("isLoading ="))
    }

    func testTerminalLauncherChecksCancellationBeforeExternalSideEffects_repro() throws {
        let launcher = try source("macos/Engram/Views/Resume/TerminalLauncher.swift")
        let launchStart = try XCTUnwrap(launcher.range(of: "static func launch(command:"))
        let launch = String(launcher[launchStart.lowerBound..<launcher.endIndex])

        let terminalSwitch = try XCTUnwrap(launch.range(of: "switch terminal"))
        let entryCheck = try XCTUnwrap(launch.range(of: "try Task.checkCancellation()"))
        XCTAssertLessThan(entryCheck.lowerBound, terminalSwitch.lowerBound)

        let ghostty = try XCTUnwrap(launch.range(of: "case .ghostty:"))
        let processRun = try XCTUnwrap(launch.range(of: "try process.run()"))
        let processCheck = try XCTUnwrap(
            launch.range(of: "try Task.checkCancellation()", range: ghostty.upperBound..<processRun.lowerBound)
        )
        let processDo = try XCTUnwrap(
            launch.range(of: "do {", range: processCheck.upperBound..<processRun.lowerBound)
        )
        XCTAssertLessThan(processCheck.lowerBound, processDo.lowerBound)

        let appleScriptRun = try XCTUnwrap(launch.range(of: "appleScript.executeAndReturnError(&error)"))
        let appleScriptCheck = try XCTUnwrap(
            launch.range(
                of: "try Task.checkCancellation()",
                options: .backwards,
                range: processRun.upperBound..<appleScriptRun.lowerBound
            )
        )
        XCTAssertTrue(
            launch[appleScriptCheck.upperBound..<appleScriptRun.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        )
    }

    /// SEC-M1: resume must not dump shell/AppleScript command lines to a
    /// world-readable `/tmp` path (cross-user session/cwd disclosure).
    func testTerminalLauncherDoesNotWriteWorldReadableTmpDebugLog_repro() throws {
        let launcher = try source("macos/Engram/Views/Resume/TerminalLauncher.swift")
        XCTAssertFalse(
            launcher.contains("/tmp/engram-terminal.log"),
            "SEC-M1: TerminalLauncher must not write resume commands to /tmp/engram-terminal.log"
        )
        XCTAssertFalse(
            launcher.contains("write(toFile: \"/tmp/"),
            "SEC-M1: TerminalLauncher must not write debug logs under /tmp"
        )
    }

    func testResumeDialogKeepsDialogOpenWhenTerminalLaunchFails() throws {
        let dialog = try source("macos/Engram/Views/Resume/ResumeDialog.swift")

        XCTAssertTrue(dialog.contains("switch try await TerminalLauncher.launch("))
        XCTAssertTrue(dialog.contains("case .success:"))
        XCTAssertTrue(dialog.contains("dismiss()"))
        XCTAssertTrue(dialog.contains("case .failure(let error):"))
        XCTAssertTrue(dialog.contains("errorMessage = error.localizedDescription"))
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
