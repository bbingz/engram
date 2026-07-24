import Foundation
import Darwin

/// SessionStart context bridge: invoke sibling EngramMCP `get_context` over stdio
/// without duplicating MCP SQL, then emit Claude Code SessionStart hook JSON.
/// Fail-open for missing helpers, timeouts, and malformed MCP responses.
enum EngramCLIContextError: Error, CustomStringConvertible, Equatable {
    case usage
    case missingOptionValue(String)
    case unknownOption(String)
    case invalidOptionValue(String)

    var description: String {
        switch self {
        case .usage:
            return "Usage: EngramCLI context [--cwd <path>] [--task <text>] [--timeout-ms <n>] [--max-bytes <n>] [--mcp-helper <path>] [--json-rpc-only]"
        case .missingOptionValue(let option):
            return "Missing value for \(option)"
        case .unknownOption(let option):
            return "Unknown context option: \(option)"
        case .invalidOptionValue(let option):
            return "Invalid value for \(option)"
        }
    }
}

struct EngramCLIContextOptions: Equatable {
    /// Hard upper bound for SessionStart additionalContext payload (UTF-8 bytes).
    static let defaultMaxBytes = 8_192
    /// Default wall-clock budget for the MCP subprocess (milliseconds).
    static let defaultTimeoutMs = 2_500
    /// Token budget passed to get_context (~4 chars/token); kept under the byte cap.
    static let defaultMaxTokens = 1_800

    var cwd: String
    var task: String?
    var timeoutMs: Int
    var maxBytes: Int
    var maxTokens: Int
    var mcpHelperPath: String?
    /// When true, print raw MCP tool text instead of SessionStart hook JSON (debug).
    var jsonRpcOnly: Bool

    static func parse(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaultCwd: String = FileManager.default.currentDirectoryPath
    ) throws -> EngramCLIContextOptions? {
        guard let first = arguments.first else { return nil }
        guard first == "context" || first == "--context" else { return nil }

        var rest = Array(arguments.dropFirst())
        var cwd = environment["CLAUDE_PROJECT_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if cwd == nil || cwd?.isEmpty == true {
            cwd = defaultCwd
        }
        var task: String?
        var timeoutMs = defaultTimeoutMs
        var maxBytes = defaultMaxBytes
        var maxTokens = defaultMaxTokens
        var mcpHelperPath = environment["ENGRAM_CLI_MCP_HELPER"]
        var jsonRpcOnly = false

        while !rest.isEmpty {
            let value = rest.removeFirst()
            switch value {
            case "--cwd":
                guard let next = rest.first else { throw EngramCLIContextError.missingOptionValue(value) }
                cwd = next
                rest.removeFirst()
            case "--task":
                guard let next = rest.first else { throw EngramCLIContextError.missingOptionValue(value) }
                task = next
                rest.removeFirst()
            case "--timeout-ms":
                guard let next = rest.first else { throw EngramCLIContextError.missingOptionValue(value) }
                guard let parsed = Int(next), parsed > 0 else {
                    throw EngramCLIContextError.invalidOptionValue(value)
                }
                timeoutMs = parsed
                rest.removeFirst()
            case "--max-bytes":
                guard let next = rest.first else { throw EngramCLIContextError.missingOptionValue(value) }
                guard let parsed = Int(next), parsed > 0 else {
                    throw EngramCLIContextError.invalidOptionValue(value)
                }
                maxBytes = min(parsed, defaultMaxBytes)
                rest.removeFirst()
            case "--max-tokens":
                guard let next = rest.first else { throw EngramCLIContextError.missingOptionValue(value) }
                guard let parsed = Int(next), parsed > 0 else {
                    throw EngramCLIContextError.invalidOptionValue(value)
                }
                maxTokens = min(parsed, 32_000)
                rest.removeFirst()
            case "--mcp-helper":
                guard let next = rest.first else { throw EngramCLIContextError.missingOptionValue(value) }
                mcpHelperPath = next
                rest.removeFirst()
            case "--json-rpc-only":
                jsonRpcOnly = true
            default:
                if value.hasPrefix("-") {
                    throw EngramCLIContextError.unknownOption(value)
                }
                throw EngramCLIContextError.unknownOption(value)
            }
        }

        let resolvedCwd = (cwd ?? defaultCwd).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedCwd.isEmpty else { throw EngramCLIContextError.usage }
        return EngramCLIContextOptions(
            cwd: resolvedCwd,
            task: task,
            timeoutMs: timeoutMs,
            maxBytes: maxBytes,
            maxTokens: maxTokens,
            mcpHelperPath: mcpHelperPath?.isEmpty == true ? nil : mcpHelperPath,
            jsonRpcOnly: jsonRpcOnly
        )
    }
}

enum EngramCLIContextCommand {
    /// Exit codes: 0 success or fail-open; 64 usage errors.
    static let exitSuccess: Int32 = 0
    static let exitUsage: Int32 = 64

    static func mcpHelperCandidates(
        explicit: String?,
        executablePath: String,
        environment: [String: String]
    ) -> [String] {
        // Explicit / env overrides are exclusive so a mis-set path fails open
        // instead of silently falling through to a different helper.
        if let explicit, !explicit.isEmpty {
            return [explicit]
        }
        if let override = environment["ENGRAM_CLI_MCP_HELPER"], !override.isEmpty {
            return [override]
        }
        if let override = environment["ENGRAM_MCP_PATH"], !override.isEmpty {
            return [override]
        }

        var candidates: [String] = []
        let executableURL = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath()
        let executableDirectory = executableURL.deletingLastPathComponent()
        candidates.append(executableDirectory.appendingPathComponent("EngramMCP").path)
        candidates.append(
            executableDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("Helpers", isDirectory: true)
                .appendingPathComponent("EngramMCP")
                .path
        )
        candidates.append("/Applications/Engram.app/Contents/Helpers/EngramMCP")

        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    static func isExecutableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }

    /// Truncate UTF-8 text to at most `maxBytes` without splitting a scalar mid-code-unit.
    static func truncateUTF8(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        let data = Data(text.utf8)
        if data.count <= maxBytes { return text }
        var end = min(maxBytes, data.count)
        while end > 0 {
            if let sliced = String(data: data.prefix(end), encoding: .utf8) {
                return sliced
            }
            end -= 1
        }
        return ""
    }

    static func extractToolText(fromMCPResponseJSON json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        if root["error"] != nil {
            return nil
        }
        guard let result = root["result"] as? [String: Any] else {
            return nil
        }
        if let isError = result["isError"] as? Bool, isError {
            return nil
        }
        guard let content = result["content"] as? [[String: Any]] else {
            return nil
        }
        let texts = content.compactMap { item -> String? in
            guard (item["type"] as? String) == "text" || item["type"] == nil else { return nil }
            return item["text"] as? String
        }
        let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    static func sessionStartHookJSON(additionalContext: String) throws -> String {
        let payload: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "SessionStart",
                "additionalContext": additionalContext,
            ] as [String: Any],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// Bound a context string independently of its JSON envelope.
    static func boundedAdditionalContext(_ text: String, maxBytes: Int) -> String {
        let prefix = "## Engram project context\n\n"
        let bodyBudget = max(0, maxBytes - prefix.utf8.count)
        let body = truncateUTF8(text, maxBytes: bodyBudget)
        let combined = prefix + body
        return truncateUTF8(combined, maxBytes: maxBytes)
    }

    /// Return the largest valid SessionStart payload whose complete UTF-8 JSON is within the cap.
    static func boundedSessionStartHookJSON(_ text: String, maxBytes: Int) -> String? {
        guard maxBytes > 0 else { return nil }
        let prefix = "## Engram project context\n\n"
        guard let smallest = try? sessionStartHookJSON(additionalContext: prefix),
              smallest.utf8.count <= maxBytes
        else {
            return nil
        }

        var lowerBound = 0
        var upperBound = min(text.utf8.count, maxBytes)
        var best = smallest

        while lowerBound <= upperBound {
            let candidateBudget = lowerBound + (upperBound - lowerBound) / 2
            let body = truncateUTF8(text, maxBytes: candidateBudget)
            guard let candidate = try? sessionStartHookJSON(additionalContext: prefix + body) else {
                return nil
            }
            if candidate.utf8.count <= maxBytes {
                best = candidate
                lowerBound = candidateBudget + 1
            } else {
                upperBound = candidateBudget - 1
            }
        }
        return best
    }

    struct MCPInvocationResult: Equatable {
        var text: String?
        var timedOut: Bool
        var helperMissing: Bool
        var malformed: Bool
        var processFailed: Bool
    }

    typealias MCPInvoker = (
        _ helperPath: String,
        _ cwd: String,
        _ task: String?,
        _ maxTokens: Int,
        _ timeoutMs: Int
    ) -> MCPInvocationResult

    static func run(
        options: EngramCLIContextOptions,
        executablePath: String = CommandLine.arguments.first ?? "",
        environment: [String: String] = ProcessInfo.processInfo.environment,
        invoker: MCPInvoker? = nil
    ) -> (stdout: String, exitCode: Int32) {
        let candidates = mcpHelperCandidates(
            explicit: options.mcpHelperPath,
            executablePath: executablePath,
            environment: environment
        )
        guard let helper = candidates.first(where: isExecutableFile) else {
            // Fail-open: missing app/helper must not block Claude.
            return ("", exitSuccess)
        }

        let invoke = invoker ?? defaultMCPInvoker
        let result = invoke(helper, options.cwd, options.task, options.maxTokens, options.timeoutMs)

        if result.helperMissing || result.timedOut || result.processFailed || result.malformed {
            return ("", exitSuccess)
        }
        guard let text = result.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else {
            return ("", exitSuccess)
        }

        if options.jsonRpcOnly {
            let capped = truncateUTF8(text, maxBytes: options.maxBytes)
            return (capped, exitSuccess)
        }

        guard let json = boundedSessionStartHookJSON(text, maxBytes: options.maxBytes) else {
            return ("", exitSuccess)
        }
        return (json, exitSuccess)
    }

    private static func defaultMCPInvoker(
        helperPath: String,
        cwd: String,
        task: String?,
        maxTokens: Int,
        timeoutMs: Int
    ) -> MCPInvocationResult {
        invokeMCPGetContext(
            helperPath: helperPath,
            cwd: cwd,
            task: task,
            maxTokens: maxTokens,
            timeoutMs: timeoutMs
        )
    }

    static func invokeMCPGetContext(
        helperPath: String,
        cwd: String,
        task: String?,
        maxTokens: Int,
        timeoutMs: Int,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> MCPInvocationResult {
        guard isExecutableFile(helperPath) else {
            return MCPInvocationResult(
                text: nil,
                timedOut: false,
                helperMissing: true,
                malformed: false,
                processFailed: false
            )
        }

        var argumentsObject: [String: Any] = [
            "cwd": cwd,
            "max_tokens": maxTokens,
            "detail": "overview",
            "include_environment": false,
            "sort_by": "recency",
        ]
        if let task, !task.isEmpty {
            argumentsObject["task"] = task
        }

        let initialize: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2025-11-25",
                "capabilities": [:] as [String: Any],
                "clientInfo": [
                    "name": "engram-cli-context",
                    "version": "0.1.0",
                ],
            ] as [String: Any],
        ]
        let initialized: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
        ]
        let toolCall: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": [
                "name": "get_context",
                "arguments": argumentsObject,
            ] as [String: Any],
        ]

        guard let initializeLine = jsonLine(initialize),
              let initializedLine = jsonLine(initialized),
              let toolCallLine = jsonLine(toolCall)
        else {
            return MCPInvocationResult(
                text: nil,
                timedOut: false,
                helperMissing: false,
                malformed: true,
                processFailed: false
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: helperPath)
        process.arguments = []
        process.environment = environment
        // EngramMCP default mode is stdio MCP (resume is an explicit subcommand).

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let responseBuffer = MCPJSONLineBuffer()
        let stdoutThread = Thread {
            let handle = stdoutPipe.fileHandleForReading
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                responseBuffer.append(data)
            }
            responseBuffer.finish()
        }
        stdoutThread.qualityOfService = .userInitiated

        let stderrThread = Thread {
            let handle = stderrPipe.fileHandleForReading
            while true {
                if handle.availableData.isEmpty { break }
            }
        }
        stderrThread.qualityOfService = .userInitiated

        do {
            try process.run()
        } catch {
            return MCPInvocationResult(
                text: nil,
                timedOut: false,
                helperMissing: false,
                malformed: false,
                processFailed: true
            )
        }
        stdoutThread.start()
        stderrThread.start()

        let timeoutSeconds = max(0.05, Double(timeoutMs) / 1_000.0)
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        let input = stdinPipe.fileHandleForWriting
        guard writeLine(initializeLine, to: input) else {
            try? input.close()
            terminateAndReap(process)
            return MCPInvocationResult(
                text: nil,
                timedOut: false,
                helperMissing: false,
                malformed: false,
                processFailed: true
            )
        }

        guard let initializeResponse = responseBuffer.waitForResponse(id: 1, until: deadline) else {
            try? input.close()
            terminateAndReap(process)
            return MCPInvocationResult(
                text: nil,
                timedOut: Date() >= deadline,
                helperMissing: false,
                malformed: Date() < deadline,
                processFailed: false
            )
        }

        guard isSuccessfulInitializeResponse(initializeResponse) else {
            try? input.close()
            terminateAndReap(process)
            return MCPInvocationResult(
                text: nil,
                timedOut: false,
                helperMissing: false,
                malformed: true,
                processFailed: false
            )
        }

        guard writeLine(initializedLine, to: input),
              writeLine(toolCallLine, to: input)
        else {
            try? input.close()
            terminateAndReap(process)
            return MCPInvocationResult(
                text: nil,
                timedOut: false,
                helperMissing: false,
                malformed: false,
                processFailed: true
            )
        }
        try? input.close()

        guard let responseLine = responseBuffer.waitForResponse(id: 2, until: deadline) else {
            terminateAndReap(process)
            return MCPInvocationResult(
                text: nil,
                timedOut: Date() >= deadline,
                helperMissing: false,
                malformed: Date() < deadline,
                processFailed: false
            )
        }

        if process.isRunning {
            let exitDeadline = min(deadline, Date().addingTimeInterval(0.1))
            while process.isRunning && Date() < exitDeadline {
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        if process.isRunning {
            terminateAndReap(process)
        } else {
            process.waitUntilExit()
        }

        guard let text = extractToolText(fromMCPResponseJSON: responseLine) else {
            return MCPInvocationResult(
                text: nil,
                timedOut: false,
                helperMissing: false,
                malformed: true,
                processFailed: false
            )
        }

        return MCPInvocationResult(
            text: text,
            timedOut: false,
            helperMissing: false,
            malformed: false,
            processFailed: false
        )
    }

    private static func jsonLine(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func writeLine(_ line: String, to handle: FileHandle) -> Bool {
        do {
            try handle.write(contentsOf: Data((line + "\n").utf8))
            return true
        } catch {
            return false
        }
    }

    private static func isSuccessfulInitializeResponse(_ json: String) -> Bool {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["error"] == nil,
              let result = root["result"] as? [String: Any],
              result["protocolVersion"] as? String != nil
        else {
            return false
        }
        return true
    }

    private static func terminateAndReap(_ process: Process) {
        guard process.isRunning else {
            process.waitUntilExit()
            return
        }
        process.terminate()
        let graceDeadline = Date().addingTimeInterval(0.1)
        while process.isRunning && Date() < graceDeadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }
}

private final class MCPJSONLineBuffer: @unchecked Sendable {
    private let condition = NSCondition()
    private var pending = Data()
    private var lines: [String] = []
    private var finished = false

    func append(_ data: Data) {
        condition.lock()
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let lineData = pending.prefix(upTo: newline)
            pending.removeSubrange(...newline)
            let line = String(decoding: lineData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty {
                lines.append(line)
            }
        }
        condition.broadcast()
        condition.unlock()
    }

    func finish() {
        condition.lock()
        if !pending.isEmpty {
            let line = String(decoding: pending, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty {
                lines.append(line)
            }
            pending.removeAll()
        }
        finished = true
        condition.broadcast()
        condition.unlock()
    }

    func waitForResponse(id: Int, until deadline: Date) -> String? {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if let match = lines.first(where: { Self.hasResponseID($0, id: id) }) {
                return match
            }
            if finished || Date() >= deadline {
                return nil
            }
            _ = condition.wait(until: deadline)
        }
    }

    private static func hasResponseID(_ line: String, id: Int) -> Bool {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return false
        }
        if let numericID = object["id"] as? Int {
            return numericID == id
        }
        if let stringID = object["id"] as? String {
            return stringID == String(id)
        }
        return false
    }
}
