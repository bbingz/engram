import Foundation

enum EngramCLIMaintenanceError: Error, CustomStringConvertible, Equatable {
    case usage

    var description: String {
        switch self {
        case .usage:
            return "Usage: EngramCLI maintenance legacy-local-purge preview [--json] | apply --expect-sessions N --expect-token HEX [--json]"
        }
    }
}

/// D7 operator surface. Both commands go to the service over IPC; EngramCLI
/// never opens the database (docs/invariants.md "Legacy Local-Origin Purge Is
/// An Explicit Operator Action").
enum EngramCLIMaintenanceCommand: Equatable {
    case legacyLocalPurgePreview(json: Bool)
    case legacyLocalPurgeApply(expectedSessionCount: Int, expectedPlanToken: String, json: Bool)

    static func parse(arguments: [String]) throws -> Self? {
        guard arguments.first == "maintenance" else { return nil }
        guard arguments.count >= 3, arguments[1] == "legacy-local-purge" else {
            throw EngramCLIMaintenanceError.usage
        }
        let tail = Array(arguments.dropFirst(3))
        switch arguments[2] {
        case "preview":
            guard tail.allSatisfy({ $0 == "--json" }), tail.count <= 1 else {
                throw EngramCLIMaintenanceError.usage
            }
            return .legacyLocalPurgePreview(json: !tail.isEmpty)
        case "apply":
            var sessions: Int?
            var token: String?
            var json = false
            var index = 0
            while index < tail.count {
                switch tail[index] {
                case "--expect-sessions" where sessions == nil && index + 1 < tail.count:
                    guard let value = Int(tail[index + 1]) else { throw EngramCLIMaintenanceError.usage }
                    sessions = value
                    index += 2
                case "--expect-token" where token == nil && index + 1 < tail.count:
                    token = tail[index + 1]
                    index += 2
                case "--json" where !json:
                    json = true
                    index += 1
                default:
                    throw EngramCLIMaintenanceError.usage
                }
            }
            guard let sessions, let token,
                  (try? EngramServiceLegacyLocalPurgeApplyRequest(
                      expectedSessionCount: sessions,
                      expectedPlanToken: token
                  )) != nil else {
                throw EngramCLIMaintenanceError.usage
            }
            return .legacyLocalPurgeApply(expectedSessionCount: sessions, expectedPlanToken: token, json: json)
        default:
            throw EngramCLIMaintenanceError.usage
        }
    }
}

enum EngramCLIMaintenanceRunner {
    static func run(
        _ command: EngramCLIMaintenanceCommand,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> String {
        let client = EngramServiceClient(
            transport: UnixSocketEngramServiceTransport(
                socketPath: try UnixSocketEngramServiceTransport.resolvedSocketPath(environment: environment)
            )
        )
        defer { client.close() }
        let value: any Encodable
        switch command {
        case .legacyLocalPurgePreview:
            value = try await client.legacyLocalPurgePreview()
        case .legacyLocalPurgeApply(let sessions, let token, _):
            value = try await client.legacyLocalPurgeApply(
                try EngramServiceLegacyLocalPurgeApplyRequest(
                    expectedSessionCount: sessions,
                    expectedPlanToken: token
                )
            )
        }
        let json: Bool
        switch command {
        case .legacyLocalPurgePreview(let wantsJSON), .legacyLocalPurgeApply(_, _, let wantsJSON):
            json = wantsJSON
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = json ? [.sortedKeys] : [.sortedKeys, .prettyPrinted]
        return String(decoding: try encoder.encode(MaintenanceAnyEncodable(value)), as: UTF8.self)
    }
}

private struct MaintenanceAnyEncodable: Encodable {
    let value: any Encodable
    init(_ value: any Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
