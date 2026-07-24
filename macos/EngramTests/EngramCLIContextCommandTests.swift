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
