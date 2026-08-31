import Darwin
import XCTest
@testable import Engram

final class EngramCLIContextCommandTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: - Parsing

    func testParseContextDefaultsAndOverrides() throws {
        let options = try XCTUnwrap(EngramCLIContextOptions.parse(
            arguments: [
                "context",
                "--cwd", "/tmp/项目 with spaces",
                "--task", "ship plugin",
                "--timeout-ms", "1200",
                "--max-bytes", "4096",
                "--mcp-helper", "/tmp/EngramMCP",
            ],
            environment: [:],
            defaultCwd: "/fallback"
        ))

        XCTAssertEqual(options.cwd, "/tmp/项目 with spaces")
        XCTAssertEqual(options.task, "ship plugin")
        XCTAssertEqual(options.timeoutMs, 1200)
        XCTAssertEqual(options.maxBytes, 4096)
        XCTAssertEqual(options.mcpHelperPath, "/tmp/EngramMCP")
        XCTAssertFalse(options.jsonRpcOnly)
    }

    func testParseUsesClaudeProjectDirWhenCwdOmitted() throws {
        let options = try XCTUnwrap(EngramCLIContextOptions.parse(
            arguments: ["context"],
            environment: ["CLAUDE_PROJECT_DIR": "/proj/unicode-路径"],
            defaultCwd: "/should-not-use"
        ))
        XCTAssertEqual(options.cwd, "/proj/unicode-路径")
        XCTAssertEqual(options.maxBytes, EngramCLIContextOptions.defaultMaxBytes)
        XCTAssertEqual(options.timeoutMs, EngramCLIContextOptions.defaultTimeoutMs)
    }

    func testContextPathsExpandTildeAgainstDeclaredHome_repro() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-cli-context-home-\(UUID().uuidString)", isDirectory: true)
        let bin = home.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let helper = bin.appendingPathComponent("EngramMCP")
        try "#!/bin/sh\nexit 0\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)

        let options = try XCTUnwrap(EngramCLIContextOptions.parse(
            arguments: ["context", "--cwd", "~/project", "--mcp-helper", "~/bin/EngramMCP"],
            environment: [:],
            defaultCwd: "/fallback",
            homeDirectory: home
        ))
        XCTAssertEqual(options.cwd, home.appendingPathComponent("project").path)
        XCTAssertEqual(
            EngramCLIContextCommand.mcpHelperCandidates(
                explicit: options.mcpHelperPath,
                executablePath: "/Applications/Engram.app/Contents/MacOS/EngramCLI",
                environment: [:],
                homeDirectory: home
            ),
            [helper.path]
        )
    }

    func testContextRejectsRelativeCwdOverride_repro() {
        XCTAssertThrowsError(try EngramCLIContextOptions.parse(
            arguments: ["context", "--cwd", "relative/project"],
            environment: [:],
            defaultCwd: "/fallback"
        ))
    }

    func testParseCapsMaxBytesAt8KB() throws {
        let options = try XCTUnwrap(EngramCLIContextOptions.parse(
            arguments: ["context", "--max-bytes", "999999"],
            environment: [:],
            defaultCwd: "/tmp"
        ))
        XCTAssertEqual(options.maxBytes, 8_192)
    }

    func testParseRejectsUnknownAndInvalidOptions() {
        XCTAssertThrowsError(try EngramCLIContextOptions.parse(
            arguments: ["context", "--nope"],
            environment: [:],
            defaultCwd: "/tmp"
        ))
        XCTAssertThrowsError(try EngramCLIContextOptions.parse(
            arguments: ["context", "--timeout-ms", "0"],
            environment: [:],
            defaultCwd: "/tmp"
        ))
        XCTAssertNil(try EngramCLIContextOptions.parse(
            arguments: ["resume", "x"],
            environment: [:],
            defaultCwd: "/tmp"
        ))
    }

    // MARK: - Output shaping

    func testExtractToolTextFromValidMCPResponse() {
        let json = """
        {"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"hello context"}]}}
        """
        XCTAssertEqual(
            EngramCLIContextCommand.extractToolText(fromMCPResponseJSON: json),
            "hello context"
        )
    }

    func testExtractToolTextRejectsErrorAndMalformed() {
        XCTAssertNil(EngramCLIContextCommand.extractToolText(
            fromMCPResponseJSON: #"{"jsonrpc":"2.0","id":1,"error":{"code":-32603,"message":"boom"}}"#
        ))
        XCTAssertNil(EngramCLIContextCommand.extractToolText(
            fromMCPResponseJSON: #"{"jsonrpc":"2.0","id":1,"result":{"isError":true,"content":[{"type":"text","text":"nope"}]}}"#
        ))
        XCTAssertNil(EngramCLIContextCommand.extractToolText(fromMCPResponseJSON: "not-json"))
        XCTAssertNil(EngramCLIContextCommand.extractToolText(fromMCPResponseJSON: #"{"result":{}}"#))
    }

    func testSessionStartHookJSONShape() throws {
        let json = try EngramCLIContextCommand.sessionStartHookJSON(additionalContext: "alpha")
        let data = try XCTUnwrap(json.data(using: .utf8))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hook = try XCTUnwrap(root["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(hook["hookEventName"] as? String, "SessionStart")
        XCTAssertEqual(hook["additionalContext"] as? String, "alpha")
    }

    func testTruncateUTF8RespectsByteBudgetAndDoesNotSplitMultibyte() {
        let text = String(repeating: "你", count: 100) // 3 bytes each
        let truncated = EngramCLIContextCommand.truncateUTF8(text, maxBytes: 10)
        XCTAssertLessThanOrEqual(truncated.utf8.count, 10)
        XCTAssertFalse(truncated.utf8.contains { ($0 & 0xC0) == 0x80 && truncated.utf8.first == $0 })
        // Whole characters only
        XCTAssertEqual(truncated.utf8.count % 3, 0)
    }

    func testBoundedAdditionalContextEnforces8KB() {
        let huge = String(repeating: "a", count: 50_000)
        let bounded = EngramCLIContextCommand.boundedAdditionalContext(huge, maxBytes: 8_192)
        XCTAssertLessThanOrEqual(bounded.utf8.count, 8_192)
        XCTAssertTrue(bounded.contains("Engram project context"))
    }

    // MARK: - Fail-open / timeout / helper resolution

    func testMissingHelperFailOpen() {
        let options = EngramCLIContextOptions(
            cwd: "/tmp",
            task: nil,
            timeoutMs: 500,
            maxBytes: 8192,
            maxTokens: 100,
            mcpHelperPath: "/definitely/missing/EngramMCP-\(UUID().uuidString)",
            jsonRpcOnly: false
        )
        let result = EngramCLIContextCommand.run(
            options: options,
            executablePath: "/tmp/EngramCLI",
            environment: [:]
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "")
    }

    func testTimeoutAndMalformedInvokerFailOpen() {
        let options = EngramCLIContextOptions(
            cwd: "/tmp/path with spaces/项目",
            task: "task",
            timeoutMs: 100,
            maxBytes: 8192,
            maxTokens: 100,
            mcpHelperPath: "/usr/bin/true",
            jsonRpcOnly: false
        )

        let timedOut = EngramCLIContextCommand.run(
            options: options,
            executablePath: "/tmp/EngramCLI",
            environment: [:],
            invoker: { _, _, _, _, _ in
                .init(text: nil, timedOut: true, helperMissing: false, malformed: false, processFailed: false)
            }
        )
        XCTAssertEqual(timedOut.exitCode, 0)
        XCTAssertEqual(timedOut.stdout, "")

        let malformed = EngramCLIContextCommand.run(
            options: options,
            executablePath: "/tmp/EngramCLI",
            environment: [:],
            invoker: { _, _, _, _, _ in
                .init(text: nil, timedOut: false, helperMissing: false, malformed: true, processFailed: false)
            }
        )
        XCTAssertEqual(malformed.exitCode, 0)
        XCTAssertEqual(malformed.stdout, "")
    }

    func testSuccessfulInvokerEmitsSessionStartJSONUnderCap() throws {
        let body = String(repeating: "\"ctx\\\n项目 ", count: 5_000)
        let options = EngramCLIContextOptions(
            cwd: "/tmp/unicode 路径",
            task: nil,
            timeoutMs: 500,
            maxBytes: 8_192,
            maxTokens: 1_800,
            mcpHelperPath: "/usr/bin/true",
            jsonRpcOnly: false
        )
        let result = EngramCLIContextCommand.run(
            options: options,
            executablePath: "/tmp/EngramCLI",
            environment: [:],
            invoker: { helper, cwd, task, maxTokens, timeout in
                XCTAssertEqual(helper, "/usr/bin/true")
                XCTAssertEqual(cwd, "/tmp/unicode 路径")
                XCTAssertNil(task)
                XCTAssertEqual(maxTokens, 1_800)
                XCTAssertEqual(timeout, 500)
                return .init(
                    text: body,
                    timedOut: false,
                    helperMissing: false,
                    malformed: false,
                    processFailed: false
                )
            }
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.stdout.isEmpty)
        let data = try XCTUnwrap(result.stdout.data(using: .utf8))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hook = try XCTUnwrap(root["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(hook["hookEventName"] as? String, "SessionStart")
        let context = try XCTUnwrap(hook["additionalContext"] as? String)
        XCTAssertLessThanOrEqual(context.utf8.count, 8_192)
        XCTAssertLessThanOrEqual(result.stdout.utf8.count, 8_192)
        XCTAssertTrue(context.contains("Engram project context"))
    }

    func testInvokeMCPPerformsInitializeHandshakeBeforeToolCall() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Engram CLI context \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let helper = temporaryDirectory.appendingPathComponent("mock EngramMCP")
        let trace = temporaryDirectory.appendingPathComponent("trace.jsonl")
        let script = """
        #!/bin/bash
        set -eu
        IFS= read -r initialize
        printf '%s\\n' "${initialize}" >> "${ENGRAM_HANDSHAKE_TRACE}"
        printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25","capabilities":{},"serverInfo":{"name":"mock","version":"1"}}}'
        IFS= read -r initialized
        printf '%s\\n' "${initialized}" >> "${ENGRAM_HANDSHAKE_TRACE}"
        IFS= read -r tool_call
        printf '%s\\n' "${tool_call}" >> "${ENGRAM_HANDSHAKE_TRACE}"
        printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"handshake context"}]}}'
        """
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: helper.path
        )

        let result = EngramCLIContextCommand.invokeMCPGetContext(
            helperPath: helper.path,
            cwd: "/tmp/项目 with spaces",
            task: "verify handshake",
            maxTokens: 500,
            timeoutMs: 2_000,
            environment: [
                "ENGRAM_HANDSHAKE_TRACE": trace.path,
                "PATH": "/usr/bin:/bin",
            ]
        )

        XCTAssertEqual(result.text, "handshake context")
        XCTAssertFalse(result.timedOut)
        XCTAssertFalse(result.malformed)
        let lines = try String(contentsOf: trace, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(jsonMethod(lines[0]), "initialize")
        XCTAssertEqual(jsonMethod(lines[1]), "notifications/initialized")
        XCTAssertEqual(jsonMethod(lines[2]), "tools/call")
        XCTAssertEqual(jsonID(lines[0]), 1)
        XCTAssertNil(jsonID(lines[1]))
        XCTAssertEqual(jsonID(lines[2]), 2)
    }

    func testInvokeMCPTimeoutForceKillsAndReapsHelper() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Engram CLI timeout \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let helper = temporaryDirectory.appendingPathComponent("stubborn EngramMCP")
        let pidFile = temporaryDirectory.appendingPathComponent("pid")
        let script = """
        #!/bin/bash
        set -u
        printf '%s\\n' "$$" > "${ENGRAM_TIMEOUT_PID_FILE}"
        trap '' TERM INT
        while :; do :; done
        """
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: helper.path
        )

        let start = Date()
        let result = EngramCLIContextCommand.invokeMCPGetContext(
            helperPath: helper.path,
            cwd: "/tmp",
            task: nil,
            maxTokens: 100,
            timeoutMs: 500,
            environment: [
                "ENGRAM_TIMEOUT_PID_FILE": pidFile.path,
                "PATH": "/usr/bin:/bin",
            ]
        )

        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(Int32(pidText))
        XCTAssertEqual(Darwin.kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testHelperCandidateOrderPrefersExplicitThenEnvThenSiblingThenAppBundle() {
        XCTAssertEqual(
            EngramCLIContextCommand.mcpHelperCandidates(
                explicit: "/explicit/EngramMCP",
                executablePath: "/Apps/Engram.app/Contents/MacOS/EngramCLI",
                environment: [
                    "ENGRAM_CLI_MCP_HELPER": "/env/cli-helper",
                    "ENGRAM_MCP_PATH": "/env/mcp-path",
                ]
            ),
            ["/explicit/EngramMCP"]
        )
        XCTAssertEqual(
            EngramCLIContextCommand.mcpHelperCandidates(
                explicit: nil,
                executablePath: "/Apps/Engram.app/Contents/MacOS/EngramCLI",
                environment: ["ENGRAM_CLI_MCP_HELPER": "/env/cli-helper"]
            ),
            ["/env/cli-helper"]
        )
        XCTAssertEqual(
            EngramCLIContextCommand.mcpHelperCandidates(
                explicit: nil,
                executablePath: "/Apps/Engram.app/Contents/MacOS/EngramCLI",
                environment: ["ENGRAM_MCP_PATH": "/env/mcp-path"]
            ),
            ["/env/mcp-path"]
        )

        let fallback = EngramCLIContextCommand.mcpHelperCandidates(
            explicit: nil,
            executablePath: "/Apps/Engram.app/Contents/MacOS/EngramCLI",
            environment: [:]
        )
        XCTAssertEqual(fallback.first, "/Apps/Engram.app/Contents/MacOS/EngramMCP")
        XCTAssertTrue(fallback.contains("/Apps/Engram.app/Contents/Helpers/EngramMCP"))
        XCTAssertTrue(fallback.contains("/Applications/Engram.app/Contents/Helpers/EngramMCP"))
        // No user-home absolute paths in resolution list.
        XCTAssertFalse(fallback.contains { $0.hasPrefix("/Users/") })
    }

    func testHelperCandidatesIgnoreRelativeArgvZeroAndResolveTheRealCLIPath_repro() throws {
        let cwd = FileManager.default.currentDirectoryPath
        let candidates = EngramCLIContextCommand.mcpHelperCandidates(
            explicit: nil,
            executablePath: "EngramCLI",
            environment: [:]
        )

        XCTAssertFalse(candidates.contains("\(cwd)/EngramMCP"))
        XCTAssertEqual(candidates, ["/Applications/Engram.app/Contents/Helpers/EngramMCP"])
        XCTAssertEqual(
            EngramCLIContextCommand.resolvedExecutablePath(
                argv0: "EngramCLI",
                processExecutablePath: "/Apps/Engram.app/Contents/MacOS/EngramCLI"
            ),
            "/Apps/Engram.app/Contents/MacOS/EngramCLI"
        )
    }

    func testHelperOverridesResolveToAbsoluteExecutablePaths_repro() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-cli-helper-path-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("EngramMCP")
        try "#!/bin/sh\nexit 0\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)

        XCTAssertEqual(
            EngramCLIContextCommand.mcpHelperCandidates(
                explicit: "EngramMCP",
                executablePath: "/Applications/Engram.app/Contents/MacOS/EngramCLI",
                environment: ["PATH": root.path]
            ),
            [helper.path]
        )
    }

    func testHelperOverridesTrimValuesAndIgnoreRelativePATHEntries_repro() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-cli-helper-trim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("EngramMCP")
        try "#!/bin/sh\nexit 0\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)

        XCTAssertEqual(
            EngramCLIContextCommand.mcpHelperCandidates(
                explicit: "  \(helper.path)  ",
                executablePath: "/Applications/Engram.app/Contents/MacOS/EngramCLI",
                environment: [:]
            ),
            [helper.path]
        )
        XCTAssertEqual(
            EngramCLIContextCommand.mcpHelperCandidates(
                explicit: "EngramMCP",
                executablePath: "/Applications/Engram.app/Contents/MacOS/EngramCLI",
                environment: ["PATH": ".:\(root.path)"]
            ),
            [helper.path]
        )

        let parsed = try XCTUnwrap(
            EngramCLIContextOptions.parse(
                arguments: ["context", "--mcp-helper", "  \(helper.path)  "],
                environment: [:],
                defaultCwd: root.path
            )
        )
        XCTAssertEqual(parsed.mcpHelperPath, helper.path)
    }

    func testSlashFreeHelperOverrideUsesOnlyPATHAndSkipsDirectories_repro() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-cli-helper-search-\(UUID().uuidString)", isDirectory: true)
        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(
            at: first.appendingPathComponent("EngramMCP", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = second.appendingPathComponent("EngramMCP")
        try "#!/bin/sh\nexit 0\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)

        XCTAssertEqual(
            EngramCLIContextCommand.mcpHelperCandidates(
                explicit: "EngramMCP",
                executablePath: "/Applications/Engram.app/Contents/MacOS/EngramCLI",
                environment: ["PATH": "\(first.path):\(second.path)"]
            ),
            [helper.path]
        )
        XCTAssertEqual(
            EngramCLIContextCommand.mcpHelperCandidates(
                explicit: "EngramMCP",
                executablePath: "/Applications/Engram.app/Contents/MacOS/EngramCLI",
                environment: ["PATH": ""]
            ),
            []
        )
        XCTAssertEqual(
            EngramCLIContextCommand.mcpHelperCandidates(
                explicit: "relative/EngramMCP",
                executablePath: "/Applications/Engram.app/Contents/MacOS/EngramCLI",
                environment: ["PATH": second.path]
            ),
            []
        )
    }

    func testContextRunResolvesBundleExecutableInsteadOfDefaultingToArgvZero_repro() throws {
        let source = try source("macos/Shared/Service/EngramCLIContextCommand.swift")
        let runStart = try XCTUnwrap(source.range(of: "static func run(\n        options:"))
        let runBody = source[runStart.lowerBound...]
        XCTAssertFalse(runBody.hasPrefix("static func run(\n        options: EngramCLIContextOptions,\n        executablePath: String = CommandLine.arguments.first"))
        XCTAssertTrue(runBody.contains("resolvedExecutablePath(argv0: CommandLine.arguments.first ?? \"\")"))
    }

    func testDefaultMCPModeTreatsBadHelperOverrideAsExclusive_repro() throws {
        let executable = Bundle(for: Self.self)
            .bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("EngramCLI")
        let missing = "/tmp/missing-engram-mcp-\(UUID().uuidString)"
        let process = Process()
        process.executableURL = executable
        let sandbox = try makeHermeticRPCEnvironment(overrides: [
            "ENGRAM_CLI_MCP_HELPER": missing,
        ])
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        process.environment = sandbox.environment
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        try process.run()
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let stderr = String(
            data: error.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        XCTAssertEqual(process.terminationStatus, 1, stderr)
        XCTAssertTrue(stderr.contains(missing), stderr)
    }

    func testDefaultMCPModePinsDatabaseToFileManagerHomeBeforeExec_repro() throws {
        let executable = Bundle(for: Self.self)
            .bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("EngramCLI")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-cli-db-home-\(UUID().uuidString)", isDirectory: true)
        let environmentHome = root.appendingPathComponent("environment-home", isDirectory: true)
        let fileManagerHome = root.appendingPathComponent("file-manager-home", isDirectory: true)
        let helper = root.appendingPathComponent("EngramMCP")
        try FileManager.default.createDirectory(at: environmentHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fileManagerHome, withIntermediateDirectories: true)
        try "#!/bin/sh\nprintf '%s\\n' \"$ENGRAM_MCP_DB_PATH\"\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let process = Process()
        process.executableURL = executable
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": environmentHome.path,
            "CFFIXED_USER_HOME": fileManagerHome.path,
            "ENGRAM_CLI_MCP_HELPER": helper.path,
            "ENGRAM_MCP_SERVICE_SOCKET": root.appendingPathComponent("missing.sock").path,
            "ENGRAM_MCP_DB_PATH": "  \n ",
        ]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        try input.fileHandleForWriting.close()
        process.waitUntilExit()

        let dbPath = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(
            dbPath,
            fileManagerHome.appendingPathComponent(".engram/index.sqlite").path,
            "CLI must pin the same FileManager home database used by the GUI before execv"
        )
        XCTAssertFalse(dbPath?.hasPrefix(environmentHome.path) == true)
    }

    // MARK: - CLI wiring / no auto-write contracts

    func testCLIMainWiresContextBeforeMCPExec() throws {
        let cliMain = try source("macos/EngramCLI/main.swift")
        XCTAssertTrue(cliMain.contains("runContextCommandIfRequested"))
        XCTAssertTrue(cliMain.contains("EngramCLIContextCommand.run"))
        let contextIdx = try XCTUnwrap(cliMain.range(of: "runContextCommandIfRequested")?.lowerBound)
        let execIdx = try XCTUnwrap(cliMain.range(of: "execSwiftMCPHelper")?.lowerBound)
        XCTAssertLessThan(contextIdx, execIdx)
    }

    func testContextCommandDoesNotCallSaveInsightOrWritePaths() throws {
        let source = try source("macos/Shared/Service/EngramCLIContextCommand.swift")
        for forbidden in [
            "save_insight",
            "saveInsight",
            "deleteInsight",
            "project_move",
            "INSERT INTO",
            "SessionEnd",
            "Stop",
        ] {
            XCTAssertFalse(source.contains(forbidden), "context command must stay read-only; found \(forbidden)")
        }
        XCTAssertTrue(source.contains("get_context"))
        XCTAssertTrue(source.contains("tools/call"))
        XCTAssertTrue(source.contains("SessionStart"))
        XCTAssertTrue(source.contains("additionalContext"))
        XCTAssertTrue(source.contains("8_192") || source.contains("8192"))
    }

    func testPluginHasNoAutoWriteHooks() throws {
        let hooks = try source("integrations/claude-code/engram/hooks/hooks.json")
        XCTAssertTrue(hooks.contains("SessionStart"))
        XCTAssertTrue(hooks.contains("\"type\": \"command\""))
        XCTAssertFalse(hooks.contains("mcp_tool"))
        XCTAssertFalse(hooks.contains("SessionEnd"))
        XCTAssertFalse(hooks.contains("\"Stop\""))
        XCTAssertFalse(hooks.contains("save_insight"))
        XCTAssertTrue(hooks.contains("startup") || hooks.contains("startup|"))
        XCTAssertTrue(hooks.contains("resume"))
        XCTAssertTrue(hooks.contains("clear"))
        XCTAssertTrue(hooks.contains("compact"))
    }

    private func jsonMethod(_ line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object["method"] as? String
    }

    private func jsonID(_ line: String) -> Int? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object["id"] as? Int
    }
}
