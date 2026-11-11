import Foundation
@testable import EngramCoreRead
import XCTest

final class GrokAdapterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-adapter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testNativeSubagentKindsStaySkipWithoutParentMetadata_repro() async throws {
        for kind in ["subagent", "subagent_resume", "subagent_fork"] {
            let root = directory.appendingPathComponent(kind)
            let locator = try writeNativeSession(root: root, kind: kind)
            let adapter = GrokAdapter(sessionsRoot: root.path)
            let info = try await nativeInfo(adapter, locator: locator)
            XCTAssertEqual(info.agentRole, "subagent", kind)
            XCTAssertEqual(nativeTier(info), .skip, kind)
            XCTAssertNil(info.parentSessionId)
            switch try await adapter.parseSessionInfo(locator: locator) {
            case .success(let parsed): XCTAssertEqual(parsed, info)
            case .failure(let failure): throw failure
            }
        }
    }

    func testHeadlessPrimaryAndIncompleteOrConflictingIdentityStayUnknown_repro() async throws {
        let cases: [(String?, String?, String?)] = [
            ("headless", "user", "child"),
            ("headless", "subagent", "child"),
            (nil, "subagent", "child"),
            ("subagent", nil, "child"),
            ("subagent", "user", "child"),
            ("subagent", "subagent", nil),
            ("subagent", "subagent", "different-id"),
            ("future_kind", "subagent", "child"),
        ]
        for (index, identity) in cases.enumerated() {
            let root = directory.appendingPathComponent("unknown-\(index)")
            let locator = try writeNativeSession(
                root: root, kind: identity.0, audience: identity.1, summaryID: identity.2
            )
            let info = try await nativeInfo(GrokAdapter(sessionsRoot: root.path), locator: locator)
            XCTAssertNil(info.agentRole, "case \(index)")
            XCTAssertNil(info.parentSessionId)
            XCTAssertEqual(nativeTier(info), .normal)
        }
    }

    func testNativeIdentityRequiresLayoutConfinedToEnumerationRoot_repro() async throws {
        let root = directory.appendingPathComponent("sessions")
        let outside = directory.appendingPathComponent("sessions-other")
        let outsideLocator = try writeNativeSession(root: outside)
        let adapter = GrokAdapter(sessionsRoot: root.path)
        let outsideInfo = try await nativeInfo(adapter, locator: outsideLocator)
        XCTAssertNil(outsideInfo.agentRole)

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("project"),
            withDestinationURL: outside.appendingPathComponent("project")
        )
        let escapedLocator = root.appendingPathComponent("project/child/chat_history.jsonl").path
        let escapedInfo = try await nativeInfo(adapter, locator: escapedLocator)
        XCTAssertNil(escapedInfo.agentRole)
        let nestedLocator = try writeNativeSession(root: root.appendingPathComponent("nested"))
        let nestedInfo = try await nativeInfo(adapter, locator: nestedLocator)
        XCTAssertNil(nestedInfo.agentRole)
    }

    func testNativeParentRequiresUniqueVerifiedConfinedMeta_repro() async throws {
        let root = directory.appendingPathComponent("sessions")
        let locator = try writeNativeSession(root: root)
        let adapter = GrokAdapter(sessionsRoot: root.path)
        let meta = try writeNativeParent(root: root, parent: "parent")
        let linked = try await nativeInfo(adapter, locator: locator)
        XCTAssertEqual(linked.agentRole, "subagent")
        XCTAssertEqual(linked.parentSessionId, "parent")
        XCTAssertEqual(nativeTier(linked), .skip)

        for key in ["parent_session_id", "subagent_id", "child_session_id"] {
            var object = ["parent_session_id": "parent", "subagent_id": "child", "child_session_id": "child"]
            object[key] = "wrong"
            try jsonObject(object).write(to: meta)
            let info = try await nativeInfo(adapter, locator: locator)
            XCTAssertNil(info.parentSessionId, key)
            XCTAssertEqual(nativeTier(info), .skip)
        }
        _ = try writeNativeParent(root: root, parent: "parent")
        let otherMeta = try writeNativeParent(root: root, parent: "other-parent")
        let ambiguousInfo = try await nativeInfo(adapter, locator: locator)
        XCTAssertNil(ambiguousInfo.parentSessionId)
        try FileManager.default.removeItem(at: otherMeta)

        let outside = directory.appendingPathComponent("outside")
        let outsideMeta = try writeNativeParent(root: outside, parent: "parent")
        try FileManager.default.removeItem(at: meta)
        try FileManager.default.createSymbolicLink(at: meta, withDestinationURL: outsideMeta)
        let escapedParentInfo = try await nativeInfo(adapter, locator: locator)
        XCTAssertNil(escapedParentInfo.parentSessionId)
    }

    func testParentMetadataCannotClassifyHeadlessOrUnknownChild_repro() async throws {
        for kind in ["headless", "unknown"] {
            let root = directory.appendingPathComponent(kind)
            let locator = try writeNativeSession(root: root, kind: kind, audience: "user")
            _ = try writeNativeParent(root: root, parent: "parent")
            let info = try await nativeInfo(GrokAdapter(sessionsRoot: root.path), locator: locator)
            XCTAssertNil(info.agentRole)
            XCTAssertNil(info.parentSessionId)
            XCTAssertEqual(nativeTier(info), .normal)
        }
    }

    func testNativeIdentityRejectsMissingMalformedAndEscapedSidecars_repro() async throws {
        for name in ["summary.json", "prompt_context.json"] {
            let root = directory.appendingPathComponent(name)
            let locator = try writeNativeSession(root: root)
            let sidecar = URL(fileURLWithPath: locator).deletingLastPathComponent().appendingPathComponent(name)
            let outside = directory.appendingPathComponent("outside-\(name)")
            try FileManager.default.copyItem(at: sidecar, to: outside)
            let adapter = GrokAdapter(sessionsRoot: root.path)
            try FileManager.default.removeItem(at: sidecar)
            let missing = try await nativeInfo(adapter, locator: locator)
            XCTAssertNil(missing.agentRole)
            try Data("malformed".utf8).write(to: sidecar)
            let malformed = try await nativeInfo(adapter, locator: locator)
            XCTAssertNil(malformed.agentRole)
            try FileManager.default.removeItem(at: sidecar)
            try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: outside)
            let escaped = try await nativeInfo(adapter, locator: locator)
            XCTAssertNil(escaped.agentRole)
        }
    }

    func testParentMetadataFromAnotherProjectOrRootDoesNotLink_repro() async throws {
        let root = directory.appendingPathComponent("sessions")
        let locator = try writeNativeSession(root: root)
        _ = try writeNativeParent(root: directory.appendingPathComponent("sessions-other"), parent: "parent")
        _ = try writeNativeParent(root: root.appendingPathComponent("another-project"), parent: "parent")
        let info = try await nativeInfo(GrokAdapter(sessionsRoot: root.path), locator: locator)
        XCTAssertEqual(info.agentRole, "subagent")
        XCTAssertNil(info.parentSessionId)
    }

    func testCapturedNativeKindsAndIdentityMismatches_repro() throws {
        let chat = "project/child/chat_history.jsonl"
        let present = [chat, "project/child/prompt_context.json", "project/child/summary.json"]
        let cases = [("subagent", "child"), ("subagent_resume", "child"),
                     ("subagent_fork", "child"), ("subagent", "wrong-id")]
        for (index, identity) in cases.enumerated() {
            let root = directory.appendingPathComponent("capture-\(index)")
            let payloads = try nativePayloads(kind: identity.0, summaryID: identity.1)
            try writeTree(root: root, payloads: payloads)
            for logical in ["/missing/project/child/chat_history.jsonl", "/missing/project/wrong/chat_history.jsonl"] {
                switch try GrokAdapter.scanCapturedSource(
                    physicalLocator: root.appendingPathComponent(chat).path, logicalLocator: logical,
                    replayLayout: try fileSetLayout(present: present, payloads: payloads)
                ) {
                case .success(let captured):
                    XCTAssertEqual(captured.scan.info.agentRole,
                                   identity.1 == "child" && logical.contains("/child/") ? "subagent" : nil)
                    XCTAssertNil(captured.scan.info.parentSessionId)
                case .failure(let failure): throw failure
                }
            }
        }
    }

    func testIndexingIdentityChangesWhenOnlyNativeSidecarChanges_repro() throws {
        let root = directory.appendingPathComponent("sessions")
        let locator = try writeNativeSession(root: root)
        let adapter: any SessionAdapter = GrokAdapter(sessionsRoot: root.path)
        let sessionDir = URL(fileURLWithPath: locator).deletingLastPathComponent()
        for name in ["chat_history.jsonl", "summary.json", "prompt_context.json"] {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 100)],
                ofItemAtPath: sessionDir.appendingPathComponent(name).path
            )
        }
        let before = try XCTUnwrap(adapter.indexingInputIdentity(locator: locator))
        for name in ["summary.json", "prompt_context.json"] {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 300)],
                ofItemAtPath: sessionDir.appendingPathComponent(name).path
            )
            let after = try XCTUnwrap(adapter.indexingInputIdentity(locator: locator))
            XCTAssertNotEqual(before, after, name)
            XCTAssertEqual(before.locatorInode, after.locatorInode)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 100)],
                ofItemAtPath: sessionDir.appendingPathComponent(name).path
            )
        }
    }

    func testCapturedNativeIdentityUsesOnlyChildDeclaredFiles_repro() async throws {
        let root = directory.appendingPathComponent("live")
        let locator = try writeNativeSession(root: root)
        _ = try writeNativeParent(root: root, parent: "parent")
        let local = try await nativeInfo(GrokAdapter(sessionsRoot: root.path), locator: locator)
        XCTAssertEqual(local.parentSessionId, "parent")
        let capturedRoot = directory.appendingPathComponent("unrelated-staging")
        let payloads = try nativePayloads()
        try writeTree(root: capturedRoot, payloads: payloads)
        let chat = "project/child/chat_history.jsonl"
        let summary = "project/child/summary.json"
        let prompt = "project/child/prompt_context.json"
        // The live parent remains readable. Replay must never consult it.
        for present in [[chat, summary, prompt], [chat, summary], [chat, prompt], [chat]] {
            let layout = try fileSetLayout(present: present, payloads: payloads)
            switch try GrokAdapter.scanCapturedSource(
                physicalLocator: capturedRoot.appendingPathComponent(chat).path,
                logicalLocator: locator, replayLayout: layout
            ) {
            case .success(let captured):
                XCTAssertEqual(captured.scan.info.agentRole, present.count == 3 ? "subagent" : nil)
                XCTAssertNil(captured.scan.info.parentSessionId)
                XCTAssertEqual(nativeTier(captured.scan.info), present.count == 3 ? .skip : .normal)
            case .failure(let failure): throw failure
            }
        }
        // A declared sibling's basename must not authorize the child's decoy metadata.
        var siblingPayloads = payloads
        siblingPayloads["project/other/summary.json"] = payloads[summary]
        switch try GrokAdapter.scanCapturedSource(
            physicalLocator: capturedRoot.appendingPathComponent(chat).path,
            logicalLocator: locator,
            replayLayout: try fileSetLayout(
                present: [chat, "project/other/summary.json", prompt], payloads: siblingPayloads
            )
        ) {
        case .success(let captured): XCTAssertNil(captured.scan.info.agentRole)
        case .failure(let failure): throw failure
        }
        try FileManager.default.removeItem(at: root)
        switch try GrokAdapter.scanCapturedSource(
            physicalLocator: capturedRoot.appendingPathComponent(chat).path,
            logicalLocator: locator,
            replayLayout: try fileSetLayout(present: [chat, summary, prompt], payloads: payloads)
        ) {
        case .success(let captured):
            XCTAssertEqual(captured.scan.info.agentRole, "subagent")
            XCTAssertEqual(nativeTier(captured.scan.info), .skip)
        case .failure(let failure): throw failure
        }
    }

    func testModifiedSinceIncludesNativeIdentitySidecars_repro() async throws {
        for name in ["summary.json", "prompt_context.json"] {
            let root = directory.appendingPathComponent(name)
            let locator = try writeNativeSession(root: root)
            let old = Date(timeIntervalSince1970: 100)
            let recent = Date(timeIntervalSince1970: 300)
            for member in ["chat_history.jsonl", "summary.json", "prompt_context.json"] {
                try FileManager.default.setAttributes(
                    [.modificationDate: member == name ? recent : old],
                    ofItemAtPath: URL(fileURLWithPath: locator).deletingLastPathComponent()
                        .appendingPathComponent(member).path
                )
            }
            let locators = try await GrokAdapter(sessionsRoot: root.path).listSessionLocators(
                modifiedSince: Date(timeIntervalSince1970: 200), fileManager: .default
            )
            XCTAssertEqual(locators.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                           [URL(fileURLWithPath: locator).resolvingSymlinksInPath().path], name)
            let unchanged = try await GrokAdapter(sessionsRoot: root.path).listSessionLocators(
                modifiedSince: Date(timeIntervalSince1970: 400), fileManager: .default
            )
            XCTAssertEqual(unchanged, [])
        }
    }

    private func nativeInfo(_ adapter: GrokAdapter, locator: String) async throws -> NormalizedSessionInfo {
        switch try await adapter.scanForIndexing(locator: locator) {
        case .success(let scan): return scan.info
        case .failure(let failure): throw failure
        }
    }

    private func nativeTier(_ info: NormalizedSessionInfo) -> SessionTier {
        SessionTier.compute(TierInput(messageCount: info.messageCount, agentRole: info.agentRole, source: "grok"))
    }

    private func nativePayloads(
        kind: String? = "subagent", audience: String? = "subagent", summaryID: String? = "child"
    ) throws -> [String: Data] {
        var summary: [String: Any] = ["info": summaryID.map { ["id": $0] } ?? [:]]
        summary["session_kind"] = kind
        var context: [String: Any] = ["is_non_interactive": kind == "headless"]
        context["audience"] = audience
        return [
            "project/child/chat_history.jsonl": try jsonl([
                ["type": "user", "content": "Inspect native identity"],
                ["type": "assistant", "content": "Inspecting"],
                ["type": "assistant", "content": "Complete"],
            ]),
            "project/child/summary.json": try jsonObject(summary),
            "project/child/prompt_context.json": try jsonObject(context),
        ]
    }

    private func writeNativeSession(
        root: URL, kind: String? = "subagent", audience: String? = "subagent", summaryID: String? = "child"
    ) throws -> String {
        try writeTree(root: root, payloads: nativePayloads(kind: kind, audience: audience, summaryID: summaryID))
        return root.appendingPathComponent("project/child/chat_history.jsonl").path
    }

    private func writeNativeParent(root: URL, parent: String) throws -> URL {
        let relative = "project/\(parent)/subagents/child/meta.json"
        try writeTree(root: root, payloads: [
            "project/\(parent)/summary.json": try jsonObject(["info": ["id": parent]]),
            relative: try jsonObject([
                "parent_session_id": parent, "subagent_id": "child", "child_session_id": "child",
            ]),
        ])
        return root.appendingPathComponent(relative)
    }

    func testCapturedFileSetReplayMatchesLocalParseAfterOriginalRemoved_repro() async throws {
        let relative = [
            "%2FUsers%2Ftest%2Fproject/019dd6e3-91d1-7326-8299-314858773a0e/chat_history.jsonl",
            "%2FUsers%2Ftest%2Fproject/019dd6e3-91d1-7326-8299-314858773a0e/prompt_context.json",
            "%2FUsers%2Ftest%2Fproject/019dd6e3-91d1-7326-8299-314858773a0e/summary.json",
        ]
        let payloads = try grokPayloads()
        let liveRoot = directory.appendingPathComponent("live-sessions", isDirectory: true)
        try writeTree(root: liveRoot, payloads: payloads)
        let liveTranscript = liveRoot.appendingPathComponent(relative[0])
        let adapter = GrokAdapter(sessionsRoot: liveRoot.path)
        let locators = try await adapter.listSessionLocators()
        XCTAssertEqual(
            locators.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
            [liveTranscript.resolvingSymlinksInPath().path]
        )
        let baseline: IndexingScan
        switch try await adapter.scanForIndexing(locator: liveTranscript.path) {
        case .success(let scan): baseline = scan
        case .failure(let failure): throw failure
        }
        XCTAssertEqual(baseline.info.source, .grok)
        XCTAssertEqual(baseline.info.id, "019dd6e3-91d1-7326-8299-314858773a0e")
        XCTAssertEqual(baseline.info.cwd, "/Users/test/project")
        XCTAssertEqual(baseline.info.model, "grok-4")
        XCTAssertEqual(baseline.messages.map(\.role), [.user, .assistant, .tool])
        XCTAssertEqual(baseline.messages[0].content, "Inspect the Grok parser")
        XCTAssertEqual(baseline.messages[1].toolCalls?.first?.name, "read")
        XCTAssertEqual(baseline.messages[1].usage?.inputTokens, 10)
        XCTAssertEqual(baseline.messages[1].usage?.outputTokens, 5)
        XCTAssertEqual(baseline.messages[2].content, #"{"name":"fixture"}"#)

        let capturedRoot = directory.appendingPathComponent("captured-sessions", isDirectory: true)
        try writeTree(root: capturedRoot, payloads: payloads)
        let layout = try fileSetLayout(present: relative, payloads: payloads)
        let decoy = try jsonObject([
            "created_at": "2026-04-29T01:00:00.000Z",
            "updated_at": "2026-04-29T01:00:04.000Z",
            "current_model_id": "live-decoy",
            "info": ["id": "live-decoy", "cwd": "/tmp/decoy"],
        ])
        try decoy.write(to: liveRoot.appendingPathComponent(relative[2]))
        try FileManager.default.removeItem(at: liveRoot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: liveTranscript.path))

        switch try GrokAdapter.scanCapturedSource(
            physicalLocator: capturedRoot.appendingPathComponent(relative[0]).path,
            logicalLocator: liveTranscript.path,
            replayLayout: layout
        ) {
        case .success(let captured):
            var expected = baseline.info
            expected.filePath = liveTranscript.path
            XCTAssertEqual(captured.scan.info, expected)
            XCTAssertEqual(captured.scan.messages, baseline.messages)
            XCTAssertEqual(captured.rawSourceSessionID, "019dd6e3-91d1-7326-8299-314858773a0e")
            XCTAssertEqual(captured.scan.info.cwd, "/Users/test/project")
            XCTAssertNotEqual(captured.scan.info.id, "live-decoy")
        case .failure(let failure):
            XCTFail("Captured Grok scan must not open the removed live root: \(failure)")
        }
    }

    func testCapturedMissingMetadataUsesLogicalFallbacksAndIgnoresStagingDecoys_repro() async throws {
        let session = "%2FUsers%2Ftest%2Fproject/019dd6e3-91d1-7326-8299-314858773a0e"
        let transcriptRelative = session + "/chat_history.jsonl"
        let summaryRelative = session + "/summary.json"
        let payloads = [
            transcriptRelative: try jsonl([
                [
                    "type": "user",
                    "content": "<user_query>Inspect the Grok parser</user_query>",
                ],
                [
                    "type": "assistant",
                    "content": "I will inspect it.",
                    "model": "grok-4",
                    "usage": ["input_tokens": 10, "output_tokens": 5],
                    "tool_calls": [[
                        "name": "read",
                        "arguments": ["path": "/Users/test/project/package.json"],
                    ]],
                ],
                [
                    "type": "tool_result",
                    "content": #"{"name":"fixture"}"#,
                ],
            ]),
        ]
        let liveRoot = directory.appendingPathComponent("live-sessions", isDirectory: true)
        try writeTree(root: liveRoot, payloads: payloads)
        let liveTranscript = liveRoot.appendingPathComponent(transcriptRelative)
        let knownMtime = Date(timeIntervalSince1970: 1_777_434_002)
        try FileManager.default.setAttributes([.modificationDate: knownMtime], ofItemAtPath: liveTranscript.path)
        let capturedModificationNanoseconds: Int64 = 1_777_434_002_000_000_000
        let adapter = GrokAdapter(sessionsRoot: liveRoot.path)
        let baseline: IndexingScan
        switch try await adapter.scanForIndexing(locator: liveTranscript.path) {
        case .success(let scan): baseline = scan
        case .failure(let failure): throw failure
        }
        XCTAssertEqual(baseline.info.id, "019dd6e3-91d1-7326-8299-314858773a0e")
        XCTAssertEqual(baseline.info.cwd, "/Users/test/project")
        XCTAssertEqual(baseline.info.startTime, Phase4AdapterSupport.isoFromSeconds(knownMtime.timeIntervalSince1970))
        XCTAssertEqual(baseline.info.model, "grok-4")

        let capturedRoot = directory.appendingPathComponent("unrelated-staging/aaaa/bbbb", isDirectory: true)
        let capturedTranscript = capturedRoot.appendingPathComponent("chat_history.jsonl")
        try FileManager.default.createDirectory(at: capturedRoot, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: capturedTranscript.path, contents: payloads[transcriptRelative]))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)],
            ofItemAtPath: capturedTranscript.path
        )
        let decoySummary = try jsonObject([
            "created_at": "2026-01-01T00:00:00.000Z",
            "updated_at": "2026-01-01T00:00:04.000Z",
            "current_model_id": "staging-decoy",
            "info": ["id": "staging-decoy", "cwd": "/tmp/staging-decoy"],
        ])
        let decoyPrompt = try jsonObject(["working_directory": "/tmp/undeclared-decoy"])
        try decoySummary.write(to: capturedRoot.appendingPathComponent("summary.json"))
        try decoyPrompt.write(to: capturedRoot.appendingPathComponent("prompt_context.json"))
        let layout = try fileSetLayout(
            present: [transcriptRelative],
            payloads: payloads,
            absent: [summaryRelative]
        )
        try FileManager.default.removeItem(at: liveRoot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: liveTranscript.path))

        switch try GrokAdapter.scanCapturedSource(
            physicalLocator: capturedTranscript.path,
            logicalLocator: liveTranscript.path,
            replayLayout: layout,
            capturedModificationNanoseconds: capturedModificationNanoseconds
        ) {
        case .success(let captured):
            var expected = baseline.info
            expected.filePath = liveTranscript.path
            XCTAssertEqual(captured.scan.info, expected)
            XCTAssertEqual(captured.scan.messages, baseline.messages)
            XCTAssertEqual(captured.scan.info.id, "019dd6e3-91d1-7326-8299-314858773a0e")
            XCTAssertEqual(captured.scan.info.cwd, "/Users/test/project")
            XCTAssertEqual(
                captured.scan.info.startTime,
                Phase4AdapterSupport.isoFromSeconds(Double(capturedModificationNanoseconds) / 1_000_000_000)
            )
            XCTAssertNotEqual(captured.scan.info.id, "bbbb")
            XCTAssertNotEqual(captured.scan.info.id, "staging-decoy")
            XCTAssertNotEqual(captured.scan.info.cwd, "/tmp/staging-decoy")
            XCTAssertNotEqual(captured.scan.info.cwd, "/tmp/undeclared-decoy")
            XCTAssertNotEqual(captured.scan.info.model, "staging-decoy")
            XCTAssertNotEqual(
                captured.scan.info.startTime,
                Phase4AdapterSupport.isoFromSeconds(1_000_000_000)
            )
        case .failure(let failure):
            XCTFail("Captured missing-metadata scan must use logical fallbacks: \(failure)")
        }
    }

    func testCapturedDeclaredCompactionSegmentsPrecedeChatAsLabeledArchive_repro() async throws {
        let session = "%2FUsers%2Ftest%2Fproject/019dd6e3-91d1-7326-8299-314858773a0e"
        let chat = session + "/chat_history.jsonl"
        let prompt = session + "/prompt_context.json"
        let summary = session + "/summary.json"
        let index = session + "/compaction/INDEX.md"
        let first = session + "/compaction/segment_000.md"
        let second = session + "/compaction/segment_001.md"
        let undeclared = session + "/compaction/segment_999.md"
        let firstBody = "# Turn 1\nolder history\n"
        let secondBody = "# Turn 2\nlater archive\n"
        var payloads = try grokPayloads()
        payloads[index] = Data("# Segment\n".utf8)
        payloads[first] = Data(firstBody.utf8)
        payloads[second] = Data(secondBody.utf8)
        payloads[undeclared] = Data("# must not be read\n".utf8)

        let liveRoot = directory.appendingPathComponent("live-sessions", isDirectory: true)
        try writeTree(root: liveRoot, payloads: payloads)
        let liveTranscript = liveRoot.appendingPathComponent(chat)
        let adapter = GrokAdapter(sessionsRoot: liveRoot.path)
        let baseline: IndexingScan
        switch try await adapter.scanForIndexing(locator: liveTranscript.path) {
        case .success(let scan): baseline = scan
        case .failure(let failure): throw failure
        }
        XCTAssertEqual(baseline.messages.map(\.role), [.user, .assistant, .tool])
        XCTAssertEqual(baseline.info.systemMessageCount, 0)
        XCTAssertEqual(baseline.info.messageCount, 3)
        XCTAssertEqual(baseline.info.userMessageCount, 1)
        XCTAssertEqual(baseline.info.assistantMessageCount, 1)
        XCTAssertEqual(baseline.info.toolMessageCount, 1)

        let capturedRoot = directory.appendingPathComponent("captured-sessions", isDirectory: true)
        try writeTree(root: capturedRoot, payloads: payloads)
        let layout = try fileSetLayout(
            present: [chat, index, first, second, prompt, summary],
            payloads: payloads
        )
        try FileManager.default.removeItem(at: liveRoot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: liveTranscript.path))

        switch try GrokAdapter.scanCapturedSource(
            physicalLocator: capturedRoot.appendingPathComponent(chat).path,
            logicalLocator: liveTranscript.path,
            replayLayout: layout
        ) {
        case .success(let captured):
            XCTAssertEqual(captured.scan.messages.map(\.role), [.system, .system, .user, .assistant, .tool])
            XCTAssertEqual(
                captured.scan.messages[0].content,
                "Grok compaction archive\nsegment_000.md\n\n" + firstBody
            )
            XCTAssertEqual(
                captured.scan.messages[1].content,
                "Grok compaction archive\nsegment_001.md\n\n" + secondBody
            )
            XCTAssertEqual(Array(captured.scan.messages.dropFirst(2)), baseline.messages)
            XCTAssertFalse(captured.scan.messages.contains { $0.content.contains("must not be read") })
            XCTAssertEqual(captured.scan.info.systemMessageCount, baseline.info.systemMessageCount + 2)
            XCTAssertEqual(captured.scan.info.messageCount, baseline.info.messageCount)
            XCTAssertEqual(captured.scan.info.userMessageCount, baseline.info.userMessageCount)
            XCTAssertEqual(captured.scan.info.assistantMessageCount, baseline.info.assistantMessageCount)
            XCTAssertEqual(captured.scan.info.toolMessageCount, baseline.info.toolMessageCount)
            XCTAssertEqual(captured.scan.info.summary, baseline.info.summary)
            XCTAssertEqual(captured.scan.info.id, baseline.info.id)
            XCTAssertEqual(captured.scan.info.cwd, baseline.info.cwd)
        case .failure(let failure):
            XCTFail("Captured compaction scan failed: \(failure)")
        }
    }

    func testCapturedAbsentCompactionDoesNotReadOnDiskSegments_repro() async throws {
        let session = "%2FUsers%2Ftest%2Fproject/019dd6e3-91d1-7326-8299-314858773a0e"
        let chat = session + "/chat_history.jsonl"
        let prompt = session + "/prompt_context.json"
        let summary = session + "/summary.json"
        let index = session + "/compaction/INDEX.md"
        let hidden = session + "/compaction/segment_000.md"
        var payloads = try grokPayloads()
        payloads[index] = Data("# Segment\n".utf8)
        payloads[hidden] = Data("# hidden undeclared archive\n".utf8)

        let liveRoot = directory.appendingPathComponent("live-sessions", isDirectory: true)
        try writeTree(root: liveRoot, payloads: payloads)
        let liveTranscript = liveRoot.appendingPathComponent(chat)
        let adapter = GrokAdapter(sessionsRoot: liveRoot.path)
        let baseline: IndexingScan
        switch try await adapter.scanForIndexing(locator: liveTranscript.path) {
        case .success(let scan): baseline = scan
        case .failure(let failure): throw failure
        }

        let capturedRoot = directory.appendingPathComponent("captured-sessions", isDirectory: true)
        try writeTree(root: capturedRoot, payloads: payloads)
        let layout = try fileSetLayout(
            present: [chat, prompt, summary],
            payloads: payloads,
            absent: [index]
        )
        try FileManager.default.removeItem(at: liveRoot)

        switch try GrokAdapter.scanCapturedSource(
            physicalLocator: capturedRoot.appendingPathComponent(chat).path,
            logicalLocator: liveTranscript.path,
            replayLayout: layout
        ) {
        case .success(let captured):
            XCTAssertEqual(captured.scan.messages, baseline.messages)
            XCTAssertEqual(captured.scan.info.systemMessageCount, baseline.info.systemMessageCount)
            XCTAssertEqual(captured.scan.info.messageCount, baseline.info.messageCount)
            XCTAssertFalse(captured.scan.messages.contains { $0.content.contains("hidden undeclared archive") })
        case .failure(let failure):
            XCTFail("Absent compaction must not authorize on-disk segments: \(failure)")
        }
    }

    func testCapturedDeclaredSegmentMissingFailsParse_repro() throws {
        let session = "%2FUsers%2Ftest%2Fproject/019dd6e3-91d1-7326-8299-314858773a0e"
        let chat = session + "/chat_history.jsonl"
        let first = session + "/compaction/segment_000.md"
        var payloads = try grokPayloads()
        payloads[first] = Data("# declared but absent on disk\n".utf8)
        let capturedRoot = directory.appendingPathComponent("captured-sessions", isDirectory: true)
        var onDisk = payloads
        onDisk.removeValue(forKey: first)
        try writeTree(root: capturedRoot, payloads: onDisk)
        let layout = try fileSetLayout(present: [chat, first], payloads: payloads)
        switch try GrokAdapter.scanCapturedSource(
            physicalLocator: capturedRoot.appendingPathComponent(chat).path,
            logicalLocator: capturedRoot.appendingPathComponent(chat).path,
            replayLayout: layout
        ) {
        case .success:
            XCTFail("Missing declared segment must fail parse")
        case .failure(let failure):
            XCTAssertEqual(failure, .malformedJSON)
        }
    }

    func testCapturedGrokExceedsLegacyLineCap_repro() async throws {
        XCTAssertEqual(ParserLimits.default.maxLineBytes, 8 * 1024 * 1024)
        XCTAssertEqual(ParserLimits.capturedJSONL.maxLineBytes, 32 * 1024 * 1024)

        let session = "%2FUsers%2Ftest%2Fproject/019dd6e3-91d1-7326-8299-314858773a0e"
        let chat = session + "/chat_history.jsonl"
        let oversizedLine = String(repeating: "x", count: ParserLimits.default.maxLineBytes + 1)
        XCTAssertEqual(oversizedLine.utf8.count, ParserLimits.default.maxLineBytes + 1)
        var payloads = try grokPayloads()
        payloads[chat] = try jsonl([
            [
                "type": "user",
                "timestamp": "2026-04-29T01:00:02.000Z",
                "content": "<user_query>\(oversizedLine)</user_query>",
            ],
            [
                "type": "assistant",
                "timestamp": "2026-04-29T01:00:03.000Z",
                "content": "I will inspect it.",
                "model": "grok-4",
            ],
        ])
        let liveRoot = directory.appendingPathComponent("legacy-line-live", isDirectory: true)
        try writeTree(root: liveRoot, payloads: payloads)
        let liveChat = liveRoot.appendingPathComponent(chat)
        switch try await GrokAdapter(sessionsRoot: liveRoot.path).scanForIndexing(locator: liveChat.path) {
        case .success:
            XCTFail("live Grok adapter must keep the 8MiB default line cap")
        case .failure(let failure):
            XCTAssertEqual(failure, .lineTooLarge)
        }
        let capturedRoot = directory.appendingPathComponent("legacy-line-captured", isDirectory: true)
        try writeTree(root: capturedRoot, payloads: payloads)
        switch try GrokAdapter.scanCapturedSource(
            physicalLocator: capturedRoot.appendingPathComponent(chat).path,
            logicalLocator: liveChat.path,
            replayLayout: try fileSetLayout(present: [chat], payloads: payloads)
        ) {
        case .success(let captured):
            XCTAssertEqual(captured.rawSourceSessionID, "019dd6e3-91d1-7326-8299-314858773a0e")
            XCTAssertEqual(captured.scan.messages.first?.content, oversizedLine)
            XCTAssertNil(captured.scan.parseFailure)
        case .failure(let failure):
            XCTFail("captured Grok replay must read an 8MiB+ line: \(failure)")
        }
    }

    func testSummaryOnlySessionParsesFromMetadataWithoutMalformedJSON_repro() async throws {
        let session = "%2FUsers%2Ftest%2Fproject/019dd6e3-91d1-7326-8299-314858773a0e"
        let summaryRelative = session + "/summary.json"
        let payloads = [
            summaryRelative: try jsonObject([
                "created_at": "2026-04-29T01:00:00.000Z",
                "updated_at": "2026-04-29T01:00:04.000Z",
                "current_model_id": "grok-4",
                "session_summary": "Summary-only session",
                "info": [
                    "id": "019dd6e3-91d1-7326-8299-314858773a0e",
                    "cwd": "/Users/test/project",
                ],
            ]),
        ]
        let liveRoot = directory.appendingPathComponent("summary-only", isDirectory: true)
        try writeTree(root: liveRoot, payloads: payloads)
        let adapter = GrokAdapter(sessionsRoot: liveRoot.path)
        let locators = try await adapter.listSessionLocators()
        XCTAssertEqual(locators.count, 1)
        XCTAssertEqual(URL(fileURLWithPath: locators[0]).lastPathComponent, "summary.json")

        switch try await adapter.scanForIndexing(locator: locators[0]) {
        case .success(let scan):
            XCTAssertEqual(scan.info.id, "019dd6e3-91d1-7326-8299-314858773a0e")
            XCTAssertEqual(scan.info.source, .grok)
            XCTAssertEqual(scan.info.cwd, "/Users/test/project")
            XCTAssertEqual(scan.info.model, "grok-4")
            XCTAssertEqual(scan.info.startTime, "2026-04-29T01:00:00.000Z")
            XCTAssertEqual(scan.info.summary, "Summary-only session")
            XCTAssertEqual(scan.messages, [])
            XCTAssertNil(scan.parseFailure)
        case .failure(let failure):
            XCTFail("summary-only Grok session must parse metadata, not \(failure)")
        }
    }

    func testCapturedDeclaredSegmentInvalidUTF8FailsParse_repro() throws {
        let session = "%2FUsers%2Ftest%2Fproject/019dd6e3-91d1-7326-8299-314858773a0e"
        let chat = session + "/chat_history.jsonl"
        let first = session + "/compaction/segment_000.md"
        var payloads = try grokPayloads()
        payloads[first] = Data([0x80, 0x81, 0x82])
        let capturedRoot = directory.appendingPathComponent("captured-sessions", isDirectory: true)
        try writeTree(root: capturedRoot, payloads: payloads)
        let layout = try fileSetLayout(present: [chat, first], payloads: payloads)
        switch try GrokAdapter.scanCapturedSource(
            physicalLocator: capturedRoot.appendingPathComponent(chat).path,
            logicalLocator: capturedRoot.appendingPathComponent(chat).path,
            replayLayout: layout
        ) {
        case .success:
            XCTFail("Invalid UTF-8 declared segment must fail parse")
        case .failure(let failure):
            XCTAssertEqual(failure, .malformedJSON)
        }
    }

    private func grokPayloads() throws -> [String: Data] {
        let session = "%2FUsers%2Ftest%2Fproject/019dd6e3-91d1-7326-8299-314858773a0e"
        return [
            session + "/chat_history.jsonl": try jsonl([
                [
                    "type": "user",
                    "timestamp": "2026-04-29T01:00:02.000Z",
                    "content": "<user_query>Inspect the Grok parser</user_query>",
                ],
                [
                    "type": "assistant",
                    "timestamp": "2026-04-29T01:00:03.000Z",
                    "content": "I will inspect it.",
                    "model": "grok-4",
                    "usage": ["input_tokens": 10, "output_tokens": 5],
                    "tool_calls": [[
                        "name": "read",
                        "arguments": ["path": "/Users/test/project/package.json"],
                    ]],
                ],
                [
                    "type": "tool_result",
                    "timestamp": "2026-04-29T01:00:04.000Z",
                    "content": #"{"name":"fixture"}"#,
                ],
            ]),
            session + "/prompt_context.json": try jsonObject([
                "working_directory": "/Users/test/project",
            ]),
            session + "/summary.json": try jsonObject([
                "created_at": "2026-04-29T01:00:00.000Z",
                "updated_at": "2026-04-29T01:00:04.000Z",
                "current_model_id": "grok-4",
                "session_summary": "unused when a user message exists",
                "info": [
                    "id": "019dd6e3-91d1-7326-8299-314858773a0e",
                    "cwd": "/Users/test/project",
                ],
            ]),
        ]
    }

    private func writeTree(root: URL, payloads: [String: Data]) throws {
        for (relative, bytes) in payloads {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: bytes))
        }
    }

    private func fileSetLayout(
        present: [String],
        payloads: [String: Data],
        absent: [String] = []
    ) throws -> ArchiveReplayLayout {
        var offset: Int64 = 0
        var files: [ArchiveFileSetEntry] = []
        let sortedPresent = present.sorted()
        for path in sortedPresent {
            let bytes = try XCTUnwrap(payloads[path])
            files.append(try ArchiveFileSetEntry(
                relativePath: path,
                byteOffset: offset,
                rawByteCount: Int64(bytes.count),
                wholeSourceSHA256: ArchiveV2Hash.sha256(bytes),
                generation: try ArchiveSourceGeneration(
                    device: 1, inode: 2, size: Int64(bytes.count), mtimeNs: 3, ctimeNs: 4, mode: 0o100600
                )
            ))
            offset += Int64(bytes.count)
        }
        return try ArchiveReplayLayout(
            strategy: .fileSet,
            relativePaths: sortedPresent,
            entrypointRelativePath: present[0],
            files: files,
            absentRelativePaths: absent
        )
    }

    private func jsonl(_ objects: [[String: Any]]) throws -> Data {
        var result = Data()
        for object in objects {
            result.append(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            result.append(0x0a)
        }
        return result
    }

    private func jsonObject(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
