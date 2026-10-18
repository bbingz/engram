import Foundation

enum EngramCLICollectorEpochError: Error, CustomStringConvertible, Equatable {
    case usage

    var description: String {
        "Usage: EngramCLI collector-epoch dry-run --machine-id <UUID> --source-instance-id <UUID> --candidate-epoch <UUID> | approve --machine-id <UUID> --source-instance-id <UUID> --candidate-epoch <UUID> --expected-epoch <UUID> --expected-authority-generation <N> (canonical uppercase UUIDs; output is one JSON object)"
    }
}

/// HQ operator command for collector epoch authority. Invariant "Collector
/// Epoch Approval Is A Local Operator Action": approve needs the exact current
/// binding that a dry run reports.
enum EngramCLICollectorEpochCommand: Equatable {
    case dryRun(machineID: String, sourceInstanceID: String, candidateEpoch: String)
    case approve(
        machineID: String, sourceInstanceID: String, candidateEpoch: String,
        expectedEpoch: String, expectedAuthorityGeneration: Int64
    )

    private static let identityFlags = ["--machine-id", "--source-instance-id", "--candidate-epoch"]
    private static let approveFlags = identityFlags + ["--expected-epoch", "--expected-authority-generation"]

    static func parse(arguments: [String]) throws -> Self? {
        guard arguments.first == "collector-epoch" else { return nil }
        guard arguments.count >= 2 else { throw EngramCLICollectorEpochError.usage }
        let tail = Array(arguments.dropFirst(2))
        switch arguments[1] {
        case "dry-run":
            let values = try parseFlags(tail, allowed: identityFlags)
            return .dryRun(
                machineID: try uuid(values["--machine-id"]),
                sourceInstanceID: try uuid(values["--source-instance-id"]),
                candidateEpoch: try uuid(values["--candidate-epoch"])
            )
        case "approve":
            let values = try parseFlags(tail, allowed: approveFlags)
            let candidate = try uuid(values["--candidate-epoch"])
            let expected = try uuid(values["--expected-epoch"])
            guard candidate != expected,
                  let rawGeneration = values["--expected-authority-generation"],
                  let generation = Int64(rawGeneration), generation > 0,
                  String(generation) == rawGeneration else {
                throw EngramCLICollectorEpochError.usage
            }
            return .approve(
                machineID: try uuid(values["--machine-id"]),
                sourceInstanceID: try uuid(values["--source-instance-id"]),
                candidateEpoch: candidate, expectedEpoch: expected,
                expectedAuthorityGeneration: generation
            )
        default:
            throw EngramCLICollectorEpochError.usage
        }
    }

    /// Every allowed flag exactly once with a value; nothing else.
    private static func parseFlags(_ arguments: [String], allowed: [String]) throws -> [String: String] {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            guard allowed.contains(flag), values[flag] == nil, index + 1 < arguments.count else {
                throw EngramCLICollectorEpochError.usage
            }
            values[flag] = arguments[index + 1]
            index += 2
        }
        guard values.count == allowed.count else { throw EngramCLICollectorEpochError.usage }
        return values
    }

    /// Canonical uppercase UUID only; never normalizes the operator's input.
    private static func uuid(_ value: String?) throws -> String {
        guard let value, let canonical = UUID(uuidString: value)?.uuidString,
              canonical.utf8.elementsEqual(value.utf8) else {
            throw EngramCLICollectorEpochError.usage
        }
        return value
    }
}

enum EngramCLICollectorEpochRunner {
    static func run(
        _ command: EngramCLICollectorEpochCommand,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> String {
        let client = EngramServiceClient(
            transport: UnixSocketEngramServiceTransport(
                socketPath: try UnixSocketEngramServiceTransport.resolvedSocketPath(environment: environment)
            )
        )
        defer { client.close() }
        switch command {
        case .dryRun(let machineID, let sourceInstanceID, let candidateEpoch):
            return try render(try await client.collectorEpochDryRun(.init(
                machineID: machineID, sourceInstanceID: sourceInstanceID, candidateEpoch: candidateEpoch
            )))
        case .approve(let machineID, let sourceInstanceID, let candidateEpoch, let expectedEpoch, let generation):
            return try render(try await client.collectorApproveEpoch(.init(
                machineID: machineID, sourceInstanceID: sourceInstanceID, candidateEpoch: candidateEpoch,
                expectedEpoch: expectedEpoch, expectedAuthorityGeneration: generation
            )))
        }
    }

    /// One sorted-keys JSON object, always (no --json flag).
    static func render(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
