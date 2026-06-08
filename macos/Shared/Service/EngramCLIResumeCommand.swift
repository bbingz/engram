import Foundation

enum EngramCLIResumeError: Error, CustomStringConvertible, Equatable {
    case missingSessionId
    case unknownOption(String)
    case missingOptionValue(String)
    case unavailable(String)

    var description: String {
        switch self {
        case .missingSessionId:
            "Usage: EngramCLI resume <session-id> [--json] [--socket <path>]"
        case .unknownOption(let option):
            "Unknown resume option: \(option)"
        case .missingOptionValue(let option):
            "Missing value for \(option)"
        case .unavailable(let message):
            message
        }
    }
}

struct EngramCLIResumeOptions: Equatable {
    let sessionId: String
    let socketPath: String
    let json: Bool

    static func parse(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> EngramCLIResumeOptions? {
        guard let first = arguments.first else { return nil }
        guard first == "resume" || first == "--resume" || first == "-r" else {
            return nil
        }

        var rest = Array(arguments.dropFirst())
        var socketPath = environment["ENGRAM_SERVICE_SOCKET"]
            ?? UnixSocketEngramServiceTransport.defaultSocketPath()
        var json = false
        var sessionId: String?

        while !rest.isEmpty {
            let value = rest.removeFirst()
            switch value {
            case "--json":
                json = true
            case "--socket":
                guard let next = rest.first else {
                    throw EngramCLIResumeError.missingOptionValue(value)
                }
                socketPath = next
                rest.removeFirst()
            default:
                if value.hasPrefix("-") {
                    throw EngramCLIResumeError.unknownOption(value)
                }
                if sessionId == nil {
                    sessionId = value
                } else {
                    throw EngramCLIResumeError.unknownOption(value)
                }
            }
        }

        guard let sessionId, !sessionId.isEmpty else {
            throw EngramCLIResumeError.missingSessionId
        }
        return EngramCLIResumeOptions(sessionId: sessionId, socketPath: socketPath, json: json)
    }
}

enum EngramCLIResumeCommand {
    static func render(
        options: EngramCLIResumeOptions,
        client: any EngramServiceClientProtocol
    ) async throws -> String {
        let response = try await client.resumeCommand(sessionId: options.sessionId)
        if options.json {
            return try render(response: response, json: true)
        }
        if let error = response.error, !error.isEmpty {
            if let primer = response.contextPrimer?.trimmingCharacters(in: .whitespacesAndNewlines),
               !primer.isEmpty {
                return renderUnavailableContextPrimer(error: error, hint: response.hint, primer: primer)
            }
            let suffix = response.hint?.isEmpty == false ? " \(response.hint!)" : ""
            throw EngramCLIResumeError.unavailable(error + suffix)
        }
        return try render(response: response, json: options.json)
    }

    static func render(response: EngramServiceResumeCommandResponse, json: Bool) throws -> String {
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(response)
            return String(decoding: data, as: UTF8.self)
        }
        guard let command = response.command, !command.isEmpty else {
            if let primer = response.contextPrimer?.trimmingCharacters(in: .whitespacesAndNewlines),
               !primer.isEmpty {
                return renderUnavailableContextPrimer(
                    error: "Session has no resumable command",
                    hint: response.hint,
                    primer: primer
                )
            }
            throw EngramCLIResumeError.unavailable("Session has no resumable command")
        }
        let commandLine = ([command] + response.args)
            .map(shellEscaped)
            .joined(separator: " ")
        let rendered: String
        if let cwd = response.cwd, !cwd.isEmpty {
            rendered = "cd \(shellEscaped(cwd)) && \(commandLine)"
        } else {
            rendered = commandLine
        }
        guard let primer = response.contextPrimer?.trimmingCharacters(in: .whitespacesAndNewlines),
              !primer.isEmpty else {
            return rendered
        }
        return rendered + "\n\n# Engram context primer:\n" + shellCommentBlock(primer)
    }

    static func shellEscaped(_ value: String) -> String {
        if value.range(of: #"^[A-Za-z0-9_@%+=:,./-]+$"#, options: .regularExpression) != nil {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func shellCommentBlock(_ value: String) -> String {
        value
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                line.isEmpty ? "#" : "# \(line)"
            }
            .joined(separator: "\n")
    }

    private static func renderUnavailableContextPrimer(
        error: String,
        hint: String?,
        primer: String
    ) -> String {
        var lines = ["# Engram resume command unavailable: \(error)"]
        if let hint = hint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
            lines.append("# \(hint)")
        }
        lines.append("#")
        lines.append("# Engram context primer:")
        lines.append(shellCommentBlock(primer))
        return lines.joined(separator: "\n")
    }
}
