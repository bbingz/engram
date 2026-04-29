import XCTest
@testable import Engram

final class ParentDetectionParityTests: XCTestCase {
    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("tests/fixtures/parent-detection/detection-version.json")
    }

    func testDetectionVersionAndFixtureCasesMatchNodeReference() throws {
        let fixture = try JSONDecoder().decode(
            ParentDetectionFixture.self,
            from: Data(contentsOf: fixtureURL)
        )

        XCTAssertEqual(ParentDetection.detectionVersion, fixture.detectionVersion)
        for item in fixture.dispatchCases {
            XCTAssertEqual(ParentDetection.isDispatchPattern(item.input), item.isDispatch, item.input)
        }
        for item in fixture.scoreCases {
            let actual: Double
            switch item.name {
            case "same-project-active-parent":
                actual = ParentDetection.scoreCandidate(
                    agentStartTime: "2026-04-23T10:10:00.000Z",
                    parentStartTime: "2026-04-23T10:00:00.000Z",
                    parentEndTime: nil,
                    agentProject: "engram",
                    parentProject: "engram",
                    agentCwd: "/Users/example/-Code-/engram",
                    parentCwd: "/Users/example/-Code-/engram"
                )
            case "agent-before-parent":
                actual = ParentDetection.scoreCandidate(
                    agentStartTime: "2026-04-23T09:50:00.000Z",
                    parentStartTime: "2026-04-23T10:00:00.000Z",
                    parentEndTime: nil,
                    agentProject: "engram",
                    parentProject: "engram",
                    agentCwd: "/Users/example/-Code-/engram",
                    parentCwd: "/Users/example/-Code-/engram"
                )
            default:
                XCTFail("Unhandled fixture case \(item.name)")
                continue
            }
            XCTAssertEqual(actual, item.score, accuracy: 0.000000000001, item.name)
        }
        for item in fixture.pickBestCases {
            XCTAssertEqual(ParentDetection.pickBestCandidate(item.input), item.bestParentId)
        }
    }

    func testDispatchProbeAndNormalQuestionParity() {
        XCTAssertTrue(ParentDetection.isDispatchPattern("  <task>Implement the feature</task>"))
        XCTAssertTrue(ParentDetection.isDispatchPattern("Say exactly: streaming works"))
        XCTAssertTrue(ParentDetection.isDispatchPattern("Reply with just the number"))
        XCTAssertFalse(ParentDetection.isDispatchPattern("Say more about vector search tradeoffs"))
        XCTAssertFalse(ParentDetection.isDispatchPattern("What does this function do?"))
        XCTAssertFalse(ParentDetection.isDispatchPattern("Fix my lunch order"))
    }

    func testCandidateScoringCwdAndTimeRules() {
        XCTAssertEqual(
            ParentDetection.scoreCandidate(
                agentStartTime: "2026-04-13T09:55:00Z",
                parentStartTime: "2026-04-13T10:00:00Z",
                parentEndTime: "2026-04-13T11:00:00Z",
                agentProject: nil,
                parentProject: nil
            ),
            0
        )

        let exactCwd = ParentDetection.scoreCandidate(
            agentStartTime: "2026-04-13T11:17:10Z",
            parentStartTime: "2026-04-13T10:46:20Z",
            parentEndTime: "2026-04-13T14:07:07Z",
            agentProject: nil,
            parentProject: nil,
            agentCwd: "/Users/example/-Code-/gemini-plugin-cc",
            parentCwd: "/Users/example/-Code-/gemini-plugin-cc"
        )
        let unrelatedCloser = ParentDetection.scoreCandidate(
            agentStartTime: "2026-04-13T11:17:10Z",
            parentStartTime: "2026-04-13T11:10:02Z",
            parentEndTime: "2026-04-13T13:24:03Z",
            agentProject: nil,
            parentProject: nil,
            agentCwd: "/Users/example/-Code-/gemini-plugin-cc",
            parentCwd: "/Users/example/-Code-/sscms-audit"
        )
        XCTAssertGreaterThan(exactCwd, unrelatedCloser)

        XCTAssertGreaterThan(
            ParentDetection.scoreCandidate(
                agentStartTime: "2026-04-08T15:43:00Z",
                parentStartTime: "2026-04-08T11:42:44Z",
                parentEndTime: "2026-04-08T11:48:17Z",
                agentProject: "Zhiwei",
                parentProject: nil,
                agentCwd: "/Users/example/-Code-/Zhiwei",
                parentCwd: "/Users/example/-Code-/Zhiwei"
            ),
            0
        )

        XCTAssertEqual(
            ParentDetection.scoreCandidate(
                agentStartTime: "2026-04-08T16:00:00Z",
                parentStartTime: "2026-04-08T10:00:00Z",
                parentEndTime: "2026-04-08T11:00:00Z",
                agentProject: nil,
                parentProject: nil,
                agentCwd: "/Users/example/-Code-/Zhiwei",
                parentCwd: "/Users/example/-Code-/Zhiwei"
            ),
            0
        )
    }
}

private struct ParentDetectionFixture: Decodable {
    var detectionVersion: Int
    var dispatchCases: [DispatchCase]
    var scoreCases: [ScoreCase]
    var pickBestCases: [PickBestCase]
}

private struct DispatchCase: Decodable {
    var input: String
    var isDispatch: Bool
}

private struct ScoreCase: Decodable {
    var name: String
    var score: Double
}

private struct PickBestCase: Decodable {
    var input: [ScoredParent]
    var bestParentId: String?
}
