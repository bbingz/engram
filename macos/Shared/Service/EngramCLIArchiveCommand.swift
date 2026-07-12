import Darwin
import Foundation

enum EngramCLIArchiveError: Error, CustomStringConvertible, Equatable {
    case usage
    case invalidTokenInput
    case ttyInputForbidden
    case tokenEnvironmentForbidden

    var description: String {
        switch self {
        case .usage:
            return "Usage: EngramCLI archive status [--json] | reclaim status|preview|enable|disable|run [--hot-window-days 30|60|90|180] [--json] | recovery-drill --replica hq|m1 [--json] | retry --replica hq|m1|all [--json] | token set --replica hq|m1 --stdin [--json] | probe-remote --session-id <id> [--json]"
        case .invalidTokenInput:
            return "archive token input must be one canonical base64 line decoding to 32 bytes"
        case .ttyInputForbidden:
            return "archive token input must be piped on stdin"
        case .tokenEnvironmentForbidden:
            return "archive tokens must not be supplied through environment variables"
        }
    }
}

enum EngramCLIArchiveCommand: Equatable {
    case status(json: Bool)
    case retry(replicaID: String?, json: Bool)
    case storeToken(replicaID: String, json: Bool)
    case probeRemote(sessionID: String, json: Bool)
    case reclamationStatus(json: Bool)
    case reclamationPreview(json: Bool)
    case reclamationUpdate(enabled: Bool, hotWindowDays: Int, json: Bool)
    case reclamationRun(json: Bool)
    case recoveryDrill(replicaID: String, json: Bool)

    static func parse(arguments: [String]) throws -> Self? {
        guard arguments.first == "archive" else { return nil }
        guard arguments.count >= 2 else { throw EngramCLIArchiveError.usage }
        let tail = Array(arguments.dropFirst(2))
        switch arguments[1] {
        case "status":
            guard tail.allSatisfy({ $0 == "--json" }), tail.filter({ $0 == "--json" }).count <= 1 else {
                throw EngramCLIArchiveError.usage
            }
            return .status(json: tail.contains("--json"))
        case "retry":
            let parsed = try parseReplicaOptions(tail, allowAll: true, requireStdin: false)
            return .retry(replicaID: parsed.replicaID == "all" ? nil : parsed.replicaID, json: parsed.json)
        case "token":
            guard tail.first == "set" else { throw EngramCLIArchiveError.usage }
            let parsed = try parseReplicaOptions(Array(tail.dropFirst()), allowAll: false, requireStdin: true)
            return .storeToken(replicaID: parsed.replicaID, json: parsed.json)
        case "probe-remote":
            var sessionID: String?
            var json = false
            var index = 0
            while index < tail.count {
                switch tail[index] {
                case "--session-id" where sessionID == nil && index + 1 < tail.count:
                    sessionID = tail[index + 1]
                    index += 2
                case "--json" where !json:
                    json = true
                    index += 1
                default:
                    throw EngramCLIArchiveError.usage
                }
            }
            guard let sessionID else { throw EngramCLIArchiveError.usage }
            _ = try EngramServiceArchiveV2RemoteRecoveryProbeRequest(sessionId: sessionID)
            return .probeRemote(sessionID: sessionID, json: json)
        case "reclaim":
            return try parseReclamation(tail)
        case "recovery-drill":
            let parsed = try parseReplicaOptions(tail, allowAll: false, requireStdin: false)
            return .recoveryDrill(replicaID: parsed.replicaID, json: parsed.json)
        default:
            throw EngramCLIArchiveError.usage
        }
    }

    private static func parseReclamation(_ arguments: [String]) throws -> Self {
        guard let action = arguments.first else { throw EngramCLIArchiveError.usage }
        let tail = Array(arguments.dropFirst())
        if action == "status" || action == "preview" || action == "disable" || action == "run" {
            guard tail.allSatisfy({ $0 == "--json" }), tail.filter({ $0 == "--json" }).count <= 1 else {
                throw EngramCLIArchiveError.usage
            }
            let json = tail.contains("--json")
            switch action {
            case "status": return .reclamationStatus(json: json)
            case "preview": return .reclamationPreview(json: json)
            case "disable": return .reclamationUpdate(enabled: false, hotWindowDays: 30, json: json)
            default: return .reclamationRun(json: json)
            }
        }
        guard action == "enable" else { throw EngramCLIArchiveError.usage }
        var days: Int?
        var json = false
        var index = 0
        while index < tail.count {
            switch tail[index] {
            case "--hot-window-days" where days == nil && index + 1 < tail.count:
                days = Int(tail[index + 1])
                index += 2
            case "--json" where !json:
                json = true
                index += 1
            default:
                throw EngramCLIArchiveError.usage
            }
        }
        guard let days, [30, 60, 90, 180].contains(days) else { throw EngramCLIArchiveError.usage }
        return .reclamationUpdate(enabled: true, hotWindowDays: days, json: json)
    }

    private static func parseReplicaOptions(
        _ arguments: [String],
        allowAll: Bool,
        requireStdin: Bool
    ) throws -> (replicaID: String, json: Bool) {
        var replicaID: String?
        var json = false
        var stdin = false
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--replica":
                guard replicaID == nil, index + 1 < arguments.count else { throw EngramCLIArchiveError.usage }
                replicaID = arguments[index + 1]
                index += 2
            case "--json" where !json:
                json = true
                index += 1
            case "--stdin" where requireStdin && !stdin:
                stdin = true
                index += 1
            default:
                throw EngramCLIArchiveError.usage
            }
        }
        let allowed = allowAll ? ["hq", "m1", "all"] : ["hq", "m1"]
        guard let replicaID, allowed.contains(replicaID), stdin == requireStdin else {
            throw EngramCLIArchiveError.usage
        }
        return (replicaID, json)
    }
}

enum EngramCLIArchiveTokenInput {
    static let maximumInputBytes = 256

    static func validate(
        _ input: String,
        stdinIsTTY: Bool,
        environment: [String: String]
    ) throws -> String {
        guard !stdinIsTTY else { throw EngramCLIArchiveError.ttyInputForbidden }
        guard !environment.keys.contains(where: { $0.uppercased().contains("ARCHIVE") && $0.uppercased().contains("TOKEN") }) else {
            throw EngramCLIArchiveError.tokenEnvironmentForbidden
        }
        guard !input.contains("\0"), input.utf8.count <= maximumInputBytes else {
            throw EngramCLIArchiveError.invalidTokenInput
        }
        var value = input
        if value.hasSuffix("\n") { value.removeLast() }
        if value.hasSuffix("\r") { value.removeLast() }
        guard !value.isEmpty, !value.contains("\n"), !value.contains("\r"),
              let decoded = Data(base64Encoded: value), decoded.count == 32,
              decoded.base64EncodedString() == value else {
            throw EngramCLIArchiveError.invalidTokenInput
        }
        return value
    }

    static func readFromStandardInput(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        guard isatty(STDIN_FILENO) == 0 else { throw EngramCLIArchiveError.ttyInputForbidden }
        var bytes = [UInt8]()
        bytes.reserveCapacity(maximumInputBytes)
        defer { bytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        while bytes.count <= maximumInputBytes {
            var byte: UInt8 = 0
            let count = Darwin.read(STDIN_FILENO, &byte, 1)
            if count == 0 { break }
            guard count == 1 else { throw EngramCLIArchiveError.invalidTokenInput }
            bytes.append(byte)
        }
        guard bytes.count <= maximumInputBytes, let input = String(bytes: bytes, encoding: .utf8) else {
            throw EngramCLIArchiveError.invalidTokenInput
        }
        return try validate(input, stdinIsTTY: false, environment: environment)
    }
}

enum EngramCLIArchiveRunner {
    static func run(_ command: EngramCLIArchiveCommand) async throws -> String {
        let client = EngramServiceClient(transport: UnixSocketEngramServiceTransport())
        defer { client.close() }
        let value: any Encodable
        let json: Bool
        switch command {
        case .status(let wantsJSON):
            value = try await client.archiveV2Status()
            json = wantsJSON
        case .retry(let replicaID, let wantsJSON):
            value = try await client.archiveV2Retry(try EngramServiceArchiveV2RetryRequest(replicaID: replicaID))
            json = wantsJSON
        case .storeToken(let replicaID, let wantsJSON):
            let token = try EngramCLIArchiveTokenInput.readFromStandardInput()
            value = try await client.archiveV2StoreToken(.init(replicaID: replicaID, token: token))
            json = wantsJSON
        case .probeRemote(let sessionID, let wantsJSON):
            value = try await client.archiveV2RemoteRecoveryProbe(
                try .init(sessionId: sessionID)
            )
            json = wantsJSON
        case .reclamationStatus(let wantsJSON):
            value = try await client.archiveReclamationStatus()
            json = wantsJSON
        case .reclamationPreview(let wantsJSON):
            value = try await client.archiveReclamationPreview()
            json = wantsJSON
        case .reclamationUpdate(let enabled, let days, let wantsJSON):
            value = try await client.archiveReclamationUpdateSettings(.init(enabled: enabled, hotWindowDays: days))
            json = wantsJSON
        case .reclamationRun(let wantsJSON):
            value = try await client.archiveReclamationRun()
            json = wantsJSON
        case .recoveryDrill(let replicaID, let wantsJSON):
            value = try await client.archiveV2RecoveryDrill(.init(replicaID: replicaID))
            json = wantsJSON
        }
        let data = try JSONEncoder().encode(AnyEncodable(value))
        if json { return String(decoding: data, as: UTF8.self) }
        return String(decoding: data, as: UTF8.self)
    }
}

private struct AnyEncodable: Encodable {
    let value: any Encodable
    init(_ value: any Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
