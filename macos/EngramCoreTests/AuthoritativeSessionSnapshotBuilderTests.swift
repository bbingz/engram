import CryptoKit
import Foundation
import XCTest
@testable import EngramCoreRead
@testable import EngramCoreWrite

final class AuthoritativeSessionSnapshotBuilderTests: XCTestCase {
    private let resolvedID = "remote:capture-v1.machine.instance:resolved-session"
    private let logicalLocator = "/logical/vendor/projects/session.jsonl"
    private let storedLocator = "capture-v1:immutable-manifest/session"
    private let node = "capture-v1.machine.instance"
    private let timestamp = "2026-09-06T01:02:03Z"

    func testExplicitIdentityAuthorityVersionTimeAndStoredLocatorAreNotDefaulted() {
        let scan = makeScan()
        let first = build(scan, version: 901)
        XCTAssertEqual(first.id, resolvedID)
        XCTAssertEqual(first.authoritativeNode, node)
        XCTAssertEqual(first.origin, node)
        XCTAssertEqual(first.syncVersion, 901)
        XCTAssertEqual(first.indexedAt, timestamp)
        XCTAssertEqual(first.sourceLocator, storedLocator)
        XCTAssertEqual(first, build(scan, version: 901), "construction must not read a clock")

        // These are caller-allocated versions, not a stream's resetting sequence.
        let next = build(scan, version: 902, time: "2026-09-07T01:02:03Z")
        XCTAssertEqual(next.syncVersion, 902)
        XCTAssertEqual(next.indexedAt, "2026-09-07T01:02:03Z")
        XCTAssertEqual(next.snapshotHash, first.snapshotHash)
        XCTAssertEqual(build(scan, version: Int.max).syncVersion, Int.max)
        XCTAssertEqual(scan.info.id, "native-session", "do not mutate parser provenance")
        XCTAssertEqual(scan.info.origin, "parser-origin")
    }

    func testResolvedIdentityFlowsIntoBeatsWithoutRemappingResolvedParent() {
        var scan = makeScan()
        scan.info.parentSessionId = "remote:capture-v1.machine.instance:resolved-parent"
        let snapshot = build(scan)
        XCTAssertEqual(snapshot.id, resolvedID)
        XCTAssertEqual(snapshot.parentSessionId, scan.info.parentSessionId)
        XCTAssertFalse(snapshot.implementationBeats.isEmpty)
        XCTAssertTrue(snapshot.implementationBeats.allSatisfy { $0.sessionId == resolvedID })
        XCTAssertEqual(snapshot.implementationBeats.map(\.beatIndex), Array(snapshot.implementationBeats.indices))
        let secondID = "remote:capture-v1.other.instance:resolved-session"
        let second = build(scan, id: secondID)
        XCTAssertTrue(second.implementationBeats.allSatisfy { $0.sessionId == secondID })
        XCTAssertEqual(snapshot.contentFingerprint, second.contentFingerprint)
        XCTAssertEqual(snapshot.snapshotHash, second.snapshotHash)
    }

    func testLogicalProbeLocatorControlsTierButStoredAndStagingLocatorsDoNot() {
        var scan = makeScan()
        let probe = "/logical/.engram/probes/codex/session.jsonl"
        let skipped = build(scan, logical: probe)
        XCTAssertEqual(skipped.tier, .skip)
        XCTAssertTrue(skipped.implementationBeats.isEmpty)
        XCTAssertEqual(skipped.sourceLocator, storedLocator)

        scan.info.filePath = "/staging/.engram/probes/unrelated/session.jsonl"
        let normal = build(scan, stored: probe)
        XCTAssertEqual(normal.tier, .normal)
        XCTAssertFalse(normal.implementationBeats.isEmpty)
        XCTAssertEqual(normal.sourceLocator, probe)
        scan.info.filePath = "/another/nonexistent/staging/session.jsonl"
        XCTAssertEqual(normal, build(scan, stored: probe))
    }

    func testFullScanProjectFallbackPreservesExplicitAndEmptyProjects() {
        var scan = makeScan()
        scan.info.project = nil
        scan.info.cwd = "/nonexistent/logical/project-name"
        XCTAssertEqual(build(scan).project, "project-name")
        scan.info.project = "explicit-project"
        XCTAssertEqual(build(scan).project, "explicit-project")
        scan.info.project = ""
        XCTAssertEqual(build(scan).project, "", "empty and absent remain distinct")
        scan.info.project = nil
        scan.info.cwd = ""
        XCTAssertNil(build(scan).project)
        XCTAssertEqual(build(scan).cwd, "")
    }

    func testMetadataCountsAndDisplayFieldsArePreservedSeparatelyFromStreamStats() {
        let scan = makeScan()
        let snapshot = build(scan)
        XCTAssertEqual(snapshot.source, scan.info.source)
        XCTAssertEqual(snapshot.sizeBytes, scan.info.sizeBytes)
        XCTAssertEqual(snapshot.startTime, scan.info.startTime)
        XCTAssertEqual(snapshot.endTime, scan.info.endTime)
        XCTAssertEqual(snapshot.cwd, scan.info.cwd)
        XCTAssertEqual(snapshot.project, scan.info.project)
        XCTAssertEqual(snapshot.model, scan.info.model)
        XCTAssertEqual(snapshot.messageCount, 8)
        XCTAssertEqual(snapshot.userMessageCount, 3)
        XCTAssertEqual(snapshot.assistantMessageCount, 3)
        XCTAssertEqual(snapshot.toolMessageCount, 1)
        XCTAssertEqual(snapshot.systemMessageCount, 1)
        XCTAssertEqual(snapshot.summary, "Session summary")
        XCTAssertEqual(snapshot.displayTitle, "Resolved display title")
        XCTAssertEqual(snapshot.summaryMessageCount, 2, "derive searchable count, not metadata count")
    }

    func testBlankAssistantToolCallsAndToolRolePreserveTierCountingGates() {
        let user = NormalizedMessage(role: .user, content: "Implement the requested change.")
        let cases: [([NormalizedMessage], SessionTier, Int)] = [
            ([user, .init(role: .assistant, content: " \n")], .lite, 1),
            ([user, .init(role: .assistant, content: "", toolCalls: [.init(name: "Read")])], .normal, 1),
            ([user, .init(role: .tool, content: "tool result")], .normal, 1),
            ([user, .init(role: .tool, content: " \n")], .lite, 1),
            ([user, .init(role: .system, content: "system context")], .lite, 1),
            ([user, .init(role: .assistant, content: "Implemented the change.")], .normal, 2),
        ]
        for (messages, expectedTier, expectedCount) in cases {
            let snapshot = build(makeScan(messages: messages))
            XCTAssertEqual(snapshot.tier, expectedTier)
            XCTAssertEqual(snapshot.summaryMessageCount, expectedCount)
            XCTAssertEqual(snapshot.humanTurnCount, 1)
        }
    }

    func testUsageAndNamedToolCallsAccumulateBeforeContentAndInjectionFiltering() {
        let messages: [NormalizedMessage] = [
            .init(role: .user, content: "# AGENTS.md instructions for /repo", toolCalls: [.init(name: "Read")],
                  usage: .init(inputTokens: 1, outputTokens: 2, cacheReadTokens: 3, cacheCreationTokens: 4)),
            .init(role: .assistant, content: "", toolCalls: [.init(name: "Read"), .init(name: "")],
                  usage: .init(inputTokens: 10, outputTokens: 20)),
            .init(role: .tool, content: "", toolCalls: [.init(name: "Write")],
                  usage: .init(inputTokens: 100, outputTokens: 200, cacheReadTokens: 30)),
            .init(role: .system, content: "", toolCalls: [.init(name: "Write")],
                  usage: .init(inputTokens: 1_000, outputTokens: 2_000, cacheCreationTokens: 40)),
            .init(role: .user, content: "Implement the requested feature.")
        ]
        let snapshot = build(makeScan(messages: messages))
        XCTAssertEqual(snapshot.tokenUsage, .init(inputTokens: 1_111, outputTokens: 2_222, cacheReadTokens: 33, cacheCreationTokens: 44))
        XCTAssertEqual(snapshot.toolCallCounts, ["Read": 2, "Write": 2])
        XCTAssertEqual(snapshot.humanTurnCount, 1)
        XCTAssertEqual(snapshot.summaryMessageCount, 1)
        XCTAssertEqual(snapshot.tier, .normal)
        let unused = build(makeScan(messages: [.init(role: .user, content: "A substantive request.")]))
        XCTAssertNil(unused.tokenUsage, "absence of token events must not invent zero usage")
    }

    func testReliableInstructionsDeduplicateAndCapWithoutCappingHumanTurns() {
        let messages = [
            NormalizedMessage(role: .user, content: "# AGENTS.md instructions for /repo"),
            .init(role: .user, content: " \n"),
            .init(role: .user, content: "continue"),
            .init(role: .user, content: "/status"),
            .init(role: .user, content: "Implement task number 0."),
            .init(role: .user, content: "  IMPLEMENT   task number 0.  ")
        ] + (1...20).map { NormalizedMessage(role: .user, content: "Implement task number \($0).") }
        for source in [SourceName.claudeCode, .codex] {
            var scan = makeScan(messages: messages)
            scan.info.source = source
            let snapshot = build(scan)
            XCTAssertEqual(snapshot.humanTurnCount, 24)
            XCTAssertEqual(snapshot.instructionCount, 16)
            XCTAssertEqual(snapshot.instructionSummary, (0..<16).map { "Implement task number \($0)." }.joined(separator: "\n"))
        }
        for source in [SourceName.copilot, .cursor, .geminiCli] {
            var scan = makeScan(messages: messages)
            scan.info.source = source
            let snapshot = build(scan)
            XCTAssertNil(snapshot.humanTurnCount)
            XCTAssertNil(snapshot.instructionCount)
            XCTAssertNil(snapshot.instructionSummary)
            XCTAssertEqual(snapshot.messageCount, scan.info.messageCount)
        }
    }

    func testTierMatrixIgnoresParserTierHintAndPreservesSkipPriority() {
        var normal = makeScan()
        normal.info.tier = "skip"
        var premium = normal
        premium.info.messageCount = 20
        var projectPremium = normal
        projectPremium.info.messageCount = 10
        var noProject = projectPremium
        noProject.info.project = nil
        noProject.info.cwd = ""
        var longSession = normal
        longSession.info.endTime = "2026-09-05T10:31:00Z"
        var noise = normal
        noise.info.summary = "Reply exactly: ready"
        var single = normal
        single.info.messageCount = 1
        var child = premium
        child.info.agentRole = "subagent"
        var dispatched = premium
        dispatched.info.agentRole = "dispatched"
        for (scan, expected) in [(normal, SessionTier.normal), (premium, .premium), (projectPremium, .premium),
                                 (noProject, .normal), (longSession, .premium), (noise, .lite),
                                 (single, .skip), (child, .skip), (dispatched, .skip)] {
            XCTAssertEqual(build(scan).tier, expected)
        }
    }

    func testProvableSkipSuppressesOnlyDigestAccumulation() {
        let normal = build(makeScan())
        XCTAssertFalse(normal.implementationBeats.isEmpty)
        for role in ["subagent", "dispatched"] {
            var scan = makeScan()
            scan.info.agentRole = role
            let skipped = build(scan)
            XCTAssertEqual(skipped.tier, .skip)
            XCTAssertEqual(skipped.agentRole, role)
            XCTAssertTrue(skipped.implementationBeats.isEmpty)
            XCTAssertEqual(skipped.tokenUsage, normal.tokenUsage)
            XCTAssertEqual(skipped.toolCallCounts, normal.toolCallCounts)
            XCTAssertEqual(skipped.messageCount, normal.messageCount)
            XCTAssertEqual(skipped.summaryMessageCount, normal.summaryMessageCount)
            XCTAssertEqual(skipped.instructionSummary, normal.instructionSummary)
            XCTAssertEqual(skipped.instructionCount, normal.instructionCount)
            XCTAssertEqual(skipped.humanTurnCount, normal.humanTurnCount)
            XCTAssertEqual(skipped.contentFingerprint, normal.contentFingerprint)
        }
    }

    func testHealthProviderAndFirstThreeUserProbeRulesRemainDistinctFromInjections() {
        let prompts = ["ping", "QUICK PING", "Reply with POLYCLI_HEALTH_OK only.",
                       "You are acting as reviewer_1 inside polycli.",
                       "No tools. Stage 1 verified facts and diff: no change.",
                       "Review these snippets. Report only blocking correctness findings."]
        for prompt in prompts {
            let messages: [NormalizedMessage] = [.init(role: .user, content: prompt), .init(role: .assistant, content: "Done.")]
            XCTAssertEqual(build(makeScan(messages: messages)).tier, .skip, prompt)
        }
        let firstThree: [NormalizedMessage] = [
            .init(role: .user, content: "No tools."),
            .init(role: .user, content: "Stage 1 facts"),
            .init(role: .user, content: "verified; diff:"),
            .init(role: .user, content: "Implement the real feature now."),
            .init(role: .assistant, content: "Implemented the feature.")
        ]
        XCTAssertEqual(build(makeScan(messages: firstThree)).tier, .skip)
        let realTask: [NormalizedMessage] = [
            .init(role: .user, content: "# AGENTS.md instructions for /repo"),
            .init(role: .user, content: "<environment_context>context</environment_context>"),
            .init(role: .user, content: "Implement the requested snapshot builder."),
            .init(role: .assistant, content: "Implemented the snapshot builder.")
        ]
        let snapshot = build(makeScan(messages: realTask))
        XCTAssertEqual(snapshot.tier, .normal)
        XCTAssertEqual(snapshot.humanTurnCount, 1)
        XCTAssertEqual(snapshot.summaryMessageCount, 2)
    }

    func testCursorSummaryVersionIsAbsentWhileOtherSourcesUseSearchableCount() {
        for source in [SourceName.claudeCode, .codex, .cursor, .copilot] {
            var scan = makeScan()
            scan.info.source = source
            scan.info.summaryMessageCount = 999
            let snapshot = build(scan)
            XCTAssertEqual(snapshot.summaryMessageCount, source == .cursor ? nil : 2)
            XCTAssertEqual(snapshot.summary, scan.info.summary)
        }
    }

    func testSameCountBodyAndSystemRewritesChangeHashesButToolTextDoesNot() {
        let messages: [NormalizedMessage] = [
            .init(role: .user, content: "Implement the original feature."),
            .init(role: .assistant, content: "Implemented the original feature."),
            .init(role: .system, content: "Original checkpoint body."),
            .init(role: .tool, content: "Original tool output.")
        ]
        let scan = makeScan(messages: messages)
        let before = build(scan)
        for index in 0...2 {
            var rewritten = scan
            rewritten.messages[index].content = "Different body with unchanged metadata counts."
            let after = build(rewritten)
            XCTAssertNotEqual(after.snapshotHash, before.snapshotHash)
            XCTAssertNotEqual(after.contentFingerprint, before.contentFingerprint)
            XCTAssertEqual(after.messageCount, before.messageCount)
        }
        var toolRewrite = scan
        toolRewrite.messages[3].content = "Different tool output."
        XCTAssertEqual(build(toolRewrite).snapshotHash, before.snapshotHash)
        var whitespace = scan
        whitespace.messages[0].content = " \n\t" + messages[0].content + "\n "
        XCTAssertEqual(build(whitespace).snapshotHash, before.snapshotHash)
    }

    func testTimestampHashExceptionsRemainLimitedToKimiAndCopilot() {
        for source in [SourceName.kimi, .copilot, .codex, .claudeCode] {
            var scan = makeScan()
            scan.info.source = source
            let before = build(scan)
            scan.info.startTime = "2026-09-04T10:00:00Z"
            scan.info.endTime = "2026-09-04T10:05:00Z"
            let after = build(scan)
            if source == .kimi || source == .copilot {
                XCTAssertNotEqual(after.snapshotHash, before.snapshotHash, source.rawValue)
            } else {
                XCTAssertEqual(after.snapshotHash, before.snapshotHash, source.rawValue)
            }
            XCTAssertEqual(after.startTime, scan.info.startTime)
        }
    }

    func testLegacyCanonicalHashVectorPreservesFieldOrderAndJSONEscaping() {
        var scan = makeScan(messages: [
            .init(role: .user, content: " \nhello /\"世界\"\n"),
            .init(role: .assistant, content: "reply\tline\nnext"),
            .init(role: .system, content: "system state")
        ])
        scan.info.cwd = "/repo/\"世界\"\n"
        scan.info.project = "p/\"世界\""
        scan.info.model = "m\t1"
        scan.info.summary = "line1\nline2"
        scan.info.displayTitle = "title\\tail"
        scan.info.parentSessionId = "parent\n\"x\""
        let snapshot = build(scan)
        // Frozen from the legacy ordered JSON fields and SHA-256 chain; these
        // constants do not derive expectations from the implementation under test.
        XCTAssertEqual(snapshot.contentFingerprint, "9d30d37cd4341aa0f7e2af8edb066947f880d9a9573ea5367c9dc2bbde114065")
        XCTAssertEqual(snapshot.snapshotHash, "b3db6c08b7b207ae8f69aa1156454307403394e995384022c7ee6748a45777e1")
    }

    func testFullFingerprintMatchesLegacyPrefixChainExtendedByTailMessages() {
        let prefix: [NormalizedMessage] = [
            .init(role: .user, content: "Implement the initial feature."),
            .init(role: .assistant, content: "Implemented the initial feature."),
            .init(role: .system, content: "Initial checkpoint.")
        ]
        let tail: [NormalizedMessage] = [
            .init(role: .user, content: "<environment_context>ignored injection</environment_context>"),
            .init(role: .tool, content: "Ignored tool body."),
            .init(role: .user, content: "  Extend the initial feature.\n"),
            .init(role: .assistant, content: "Extended the initial feature."),
            .init(role: .system, content: "Updated checkpoint.")
        ]
        let priorSnapshot = build(makeScan(messages: prefix))
        XCTAssertNotNil(priorSnapshot.contentFingerprint)
        let prior = priorSnapshot.contentFingerprint ?? ""
        let full = build(makeScan(messages: prefix + tail))
        // Exact legacy chain encoding, extended only with eligible tail bodies.
        var expected = prior
        for message in tail.suffix(3) {
            let body = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            expected = SHA256.hash(data: Data((expected + "\n" + message.role.rawValue + "\n" + body + "\n").utf8))
                .map { String(format: "%02x", $0) }.joined()
        }
        XCTAssertEqual(full.contentFingerprint, expected)
        XCTAssertEqual(full.summaryMessageCount, 4)
        XCTAssertNotEqual(full.contentFingerprint, prior)
    }

    func testPartialScanMetadataDoesNotTurnConstructionIntoReplayAdmission() {
        var complete = makeScan()
        complete.info.source = .copilot
        let before = build(complete)
        var partial = complete
        partial.parseFailure = .messageLimitExceeded
        partial.checkpointParsedOffset = 123
        partial.checkpointBoundaryHash = "opaque-boundary"
        partial.unknownRecordKinds = ["future.record"]
        // Legacy Copilot can construct a prefix snapshot while file-state logic
        // records terminal status. Capture replay must gate completeness BEFORE
        // calling this builder; a returned value is not acceptance/readiness.
        XCTAssertEqual(build(partial), before)
        XCTAssertEqual(before.messageCount, 8)
        XCTAssertEqual(partial.parseFailure, .messageLimitExceeded)
        XCTAssertEqual(partial.checkpointParsedOffset, 123)
        XCTAssertEqual(partial.unknownRecordKinds, ["future.record"])
    }

    private func build(
        _ scan: IndexingScan,
        id: String? = nil,
        logical: String? = nil,
        stored: String? = nil,
        version: Int = 901,
        time: String? = nil
    ) -> AuthoritativeSessionSnapshot {
        AuthoritativeSessionSnapshotBuilder.build(
            from: scan,
            sessionID: id ?? resolvedID,
            logicalLocator: logical ?? logicalLocator,
            sourceLocator: stored ?? storedLocator,
            authoritativeNode: node,
            syncVersion: version,
            indexedAt: time ?? timestamp
        )
    }

    private func makeScan(messages: [NormalizedMessage]? = nil) -> IndexingScan {
        IndexingScan(
            info: NormalizedSessionInfo(
                id: "native-session", source: .codex,
                startTime: "2026-09-05T10:00:00Z", endTime: "2026-09-05T10:05:00Z",
                cwd: "/logical/project", project: "project", model: "fixture-model",
                messageCount: 8, userMessageCount: 3, assistantMessageCount: 3,
                toolMessageCount: 1, systemMessageCount: 1,
                summary: "Session summary", displayTitle: "Resolved display title",
                filePath: "/never-open/staging/native.jsonl", sizeBytes: 4_096,
                indexedAt: "1999-01-01T00:00:00Z", origin: "parser-origin"
            ),
            messages: messages ?? [
                .init(role: .user, content: "实现项目变更时间线第一版", timestamp: "2026-09-05T10:00:00Z"),
                .init(role: .assistant,
                      content: "结果\n已完成第一版项目变更时间线。\n\n验证结果\nchecks run: targeted tests",
                      timestamp: "2026-09-05T10:01:00Z", toolCalls: [.init(name: "edit_file")],
                      usage: .init(inputTokens: 100, outputTokens: 50, cacheReadTokens: 3, cacheCreationTokens: 4))
            ]
        )
    }
}
