import XCTest
@testable import Engram

final class EngramCLICollectorEpochCommandTests: XCTestCase {
    private let machine = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    private let instance = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
    private let current = "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"
    private let candidate = "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD"

    private var dryRunArguments: [String] {
        ["collector-epoch", "dry-run", "--machine-id", machine, "--source-instance-id", instance,
         "--candidate-epoch", candidate]
    }

    private var approveArguments: [String] {
        ["collector-epoch", "approve", "--machine-id", machine, "--source-instance-id", instance,
         "--candidate-epoch", candidate, "--expected-epoch", current, "--expected-authority-generation", "3"]
    }

    func testParsesDryRunAndApprove() throws {
        XCTAssertEqual(
            try EngramCLICollectorEpochCommand.parse(arguments: dryRunArguments),
            .dryRun(machineID: machine, sourceInstanceID: instance, candidateEpoch: candidate)
        )
        XCTAssertEqual(
            try EngramCLICollectorEpochCommand.parse(arguments: approveArguments),
            .approve(machineID: machine, sourceInstanceID: instance, candidateEpoch: candidate,
                     expectedEpoch: current, expectedAuthorityGeneration: 3)
        )
        // Flag order is free.
        XCTAssertEqual(
            try EngramCLICollectorEpochCommand.parse(arguments: [
                "collector-epoch", "dry-run", "--candidate-epoch", candidate,
                "--source-instance-id", instance, "--machine-id", machine,
            ]),
            .dryRun(machineID: machine, sourceInstanceID: instance, candidateEpoch: candidate)
        )
    }

    func testRejectsMalformedCollectorEpochArguments() throws {
        var malformed: [[String]] = [
            ["collector-epoch"],
            ["collector-epoch", "rotate"],
            dryRunArguments.dropLast(2).map { $0 },
            dryRunArguments + ["--machine-id", machine],
            dryRunArguments + ["--json"],
            dryRunArguments + ["--expected-epoch", current],
            dryRunArguments.dropLast(),
            approveArguments.dropLast(2).map { $0 },
            approveArguments + ["--force"],
        ]
        for (flag, value) in [
            ("--machine-id", machine.lowercased()), ("--source-instance-id", "not-a-uuid"),
            ("--candidate-epoch", candidate.lowercased()), ("--expected-epoch", ""),
            ("--expected-authority-generation", "0"), ("--expected-authority-generation", "-1"),
            ("--expected-authority-generation", "1.5"), ("--expected-authority-generation", "+1"),
            ("--expected-authority-generation", "01"), ("--expected-authority-generation", "9223372036854775808"),
            ("--candidate-epoch", current),
        ] {
            var arguments = approveArguments
            let index = try XCTUnwrap(arguments.firstIndex(of: flag))
            arguments[index + 1] = value
            malformed.append(arguments)
        }
        for arguments in malformed {
            XCTAssertThrowsError(try EngramCLICollectorEpochCommand.parse(arguments: arguments), "\(arguments)") {
                XCTAssertEqual($0 as? EngramCLICollectorEpochError, .usage)
            }
        }
        XCTAssertNil(try EngramCLICollectorEpochCommand.parse(arguments: ["archive", "status"]))
        XCTAssertNil(try EngramCLICollectorEpochCommand.parse(arguments: ["resume", "x"]))
        XCTAssertNil(try EngramCLICollectorEpochCommand.parse(arguments: []))
    }

    func testRenderEmitsSingleSortedJSONObject() throws {
        let binding = EngramServiceCollectorEpochBinding(
            machineID: machine, sourceInstanceID: instance, source: "codex", parseFormat: "codex",
            configuredRoot: "/synthetic/codex", approvedEpoch: current, authorityGeneration: 3
        )
        let response = EngramServiceCollectorEpochDryRunResponse(
            dryRun: true, current: binding, candidateEpoch: candidate, candidateWasPreviouslyApproved: false,
            currentBacklog: .init(publicationCount: 1, ledgerTaskCounts: ["pending": 1, "parsed": 0]),
            candidateBacklog: .init(publicationCount: 2, ledgerTaskCounts: ["pending": 2]),
            observedUnapprovedEpochs: [.init(collectorEpoch: candidate, publicationCount: 2)]
        )
        let text = try EngramCLICollectorEpochRunner.render(response)
        XCTAssertFalse(text.contains("\n"))
        XCTAssertTrue(text.hasPrefix("{\"candidateBacklog\":"))
        XCTAssertTrue(text.contains("\"configuredRoot\":\"/synthetic/codex\""))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(object["dryRun"] as? Bool, true)
        let currentObject = try XCTUnwrap(object["current"] as? [String: Any])
        XCTAssertEqual(currentObject["approvedEpoch"] as? String, current)
        XCTAssertEqual(currentObject["authorityGeneration"] as? Int, 3)
        XCTAssertEqual(
            try JSONDecoder().decode(EngramServiceCollectorEpochDryRunResponse.self, from: Data(text.utf8)),
            response
        )
    }
}
