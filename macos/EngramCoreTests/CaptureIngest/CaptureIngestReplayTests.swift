import Darwin
@testable import EngramCoreRead
@testable import EngramCoreWrite
import XCTest

final class CaptureIngestReplayTests: XCTestCase {
    private let machine = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    private let instance = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
    private let epoch = "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"
    private let logicalRoot = "/offline-client/.claude/projects"
    private var directory: URL!

    override func setUpWithError() throws {
        guard let canonicalTemp = Darwin.realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { free(canonicalTemp) }
        directory = URL(fileURLWithPath: String(cString: canonicalTemp), isDirectory: true)
            .appendingPathComponent("capture-replay-\(UUID().uuidString)", isDirectory: true)
        try privateDirectory(directory)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testWindsurfHookReplayRejectsCacheLayoutsWrongAuthorityAndMalformedRecords() async throws {
        let format = try XCTUnwrap(CaptureIngestParseFormat(rawValue: "windsurfHookTranscript"))
        let raw = Data((#"{"type":"user_input","status":"done","user_input":{"user_response":"inspect /repo/project/a"}}"# + "\n").utf8)
        let relative = "native.jsonl"
        let fixture = try makeFixture(raw: raw, source: .windsurf, format: format, configuredRoot: "/offline/transcripts", relative: relative)
        guard let replay = await replaySuccess(fixture) else { return }
        XCTAssertEqual(replay.rawSourceSessionID, "native")
        XCTAssertEqual(replay.scan.info.cwd, "")
        XCTAssertEqual(replay.nativeIdentity.source, .windsurf)
        for path in [".hidden.jsonl", "native/cache/transcript.jsonl", "extra/" + relative, "native.pb"] {
            let wrong = try makeFixture(raw: raw, source: .windsurf, format: format, configuredRoot: "/offline/transcripts", relative: path)
            await assertReplayError(wrong, .quarantined(.unsupportedCaptureShape))
        }
        let wrongRoot = fixture.withBinding(binding(root: "/offline", source: .windsurf, format: format))
        await assertReplayError(wrongRoot, .quarantined(.invalidReplayLayout))
        await assertReplayError(fixture.withBinding(binding(root: "/offline/transcripts", source: .windsurf, format: .codex)), .quarantined(.bindingMismatch))
        let malformed = try makeFixture(raw: raw + Data("[]\n".utf8), source: .windsurf, format: format,
                                        configuredRoot: "/offline/transcripts", relative: relative)
        await assertReplayError(malformed, .parseFailed(.malformedJSON))
        let corrupt = try alteredManifest(fixture) { $0["wholeSourceSHA256"] = String(repeating: "2", count: 64) }
        await assertReplayError(corrupt, .quarantined(.sourceIntegrityMismatch))
        try assertEmpty(fixture.stagingParent)
    }

    func testAntigravityCLIReplayRejectsCacheLayoutsWrongAuthorityAndMalformedRecords() async throws {
        let format = try XCTUnwrap(CaptureIngestParseFormat(rawValue: "antigravityCLITranscript"))
        let raw = Data((#"{"type":"USER_INPUT","created_at":"2026-09-10T00:00:00Z","content":"inspect /repo/project/a"}"# + "\n").utf8)
        let relative = "native/.system_generated/logs/transcript.jsonl"
        let fixture = try makeFixture(raw: raw, source: .antigravity, format: format, configuredRoot: "/offline/brain", relative: relative)
        guard let replay = await replaySuccess(fixture) else { return }
        XCTAssertEqual(replay.rawSourceSessionID, "native")
        XCTAssertEqual(replay.scan.info.cwd, "/repo/project")
        XCTAssertEqual(replay.nativeIdentity.source, .antigravity)
        for path in ["transcript.jsonl", "native/cache/transcript.jsonl", "extra/" + relative, "native/.system_generated/logs/other.jsonl"] {
            let wrong = try makeFixture(raw: raw, source: .antigravity, format: format, configuredRoot: "/offline/brain", relative: path)
            await assertReplayError(wrong, .quarantined(.unsupportedCaptureShape))
        }
        let wrongRoot = fixture.withBinding(binding(root: "/offline", source: .antigravity, format: format))
        await assertReplayError(wrongRoot, .quarantined(.invalidReplayLayout))
        await assertReplayError(fixture.withBinding(binding(root: "/offline/brain", source: .antigravity, format: .codex)), .quarantined(.bindingMismatch))
        let malformed = try makeFixture(raw: raw + Data("[]\n".utf8), source: .antigravity, format: format,
                                        configuredRoot: "/offline/brain", relative: relative)
        await assertReplayError(malformed, .parseFailed(.malformedJSON))
        let corrupt = try alteredManifest(fixture) { $0["wholeSourceSHA256"] = String(repeating: "2", count: 64) }
        await assertReplayError(corrupt, .quarantined(.sourceIntegrityMismatch))
        try assertEmpty(fixture.stagingParent)
    }

    func testVSCodeCASReplayUsesFrozenExternalWorkspaceAndNativeJournal() async throws {
        let fixture = try vscodeFixture()
        guard let replay = await replaySuccess(fixture) else { return }
        XCTAssertEqual(replay.scan.info.id, "journal-id")
        XCTAssertEqual(replay.rawSourceSessionID, "journal-id")
        XCTAssertEqual(replay.scan.info.cwd, "/offline/repository")
        XCTAssertEqual(replay.scan.info.filePath, fixture.manifest.locator)
        XCTAssertEqual(replay.scan.messages.map(\.content), ["aurora question", "aurora answer"])
        XCTAssertNil(replay.scan.info.model)
        XCTAssertTrue(replay.scan.messages.allSatisfy { $0.usage == nil })
        XCTAssertEqual(replay.scan.info.sizeBytes, fixture.manifest.generation.size)
        XCTAssertEqual(replay.nativeIdentity.source, .vscode)
        try assertEmpty(fixture.stagingParent)
    }

    func testVSCodeHQRejectsContextStrippedSchemaTwoDowngrade() async throws {
        let fixture = try vscodeFixture()
        let downgraded = try alteredManifest(fixture) { object in
            object["schemaVersion"] = 2
            var layout = object["replayLayout"] as! [String: Any]
            layout.removeValue(forKey: "vscodeWorkspaceContext")
            object["replayLayout"] = layout
        }
        await assertReplayError(downgraded, .quarantined(.unsupportedCaptureShape))
        try assertEmpty(fixture.stagingParent)
    }

    func testVSCodeReplayRejectsFrozenConfigurationReferenceSwapAndWrongRoot() async throws {
        let fixture = try vscodeFixture()
        let rebound = try alteredManifest(fixture) { object in
            var layout = object["replayLayout"] as! [String: Any]
            var context = layout["vscodeWorkspaceContext"] as! [String: Any]
            context["configurationLocator"] = "/offline/other.code-workspace"
            layout["vscodeWorkspaceContext"] = context
            object["replayLayout"] = layout
        }
        await assertReplayError(rebound, .parseFailed(.malformedJSON))
        await assertReplayError(fixture.withBinding(binding(root: "/offline/other", source: .vscode,
            format: try XCTUnwrap(CaptureIngestParseFormat(rawValue: "vscode")))) , .quarantined(.invalidReplayLayout))
        try assertEmpty(fixture.stagingParent)
    }

    func testVSCodeReplayKeepsFrozenConfigurationAbsenceAndRejectsWorkspaceSymlink() async throws {
        let fixture = try vscodeFixture(configurationPresent: false)
        guard let replay = await replaySuccess(fixture) else { return }
        XCTAssertEqual(replay.scan.info.cwd, "")
        let outside = directory.appendingPathComponent("outside-workspace.json")
        try Data(#"{"folder":"file:///must-not-read"}"#.utf8).write(to: outside)
        await assertReplayError(fixture, .quarantined(.unsafeStaging), hooks: .init(beforeParse: { primary in
            let workspace = primary.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("workspace.json")
            try FileManager.default.removeItem(at: workspace)
            try FileManager.default.createSymbolicLink(at: workspace, withDestinationURL: outside)
        }))
        try assertEmpty(fixture.stagingParent)
    }

    private func vscodeFixture(configurationPresent: Bool = true) throws -> Fixture {
        let format = try XCTUnwrap(CaptureIngestParseFormat(rawValue: "vscode"))
        let primary = "ws/chatSessions/native-name.jsonl"
        let workspace = "ws/workspace.json"
        let lines = [
            #"{"kind":0,"v":{"creationDate":1700000000000,"requests":[]}}"#,
            #"{"kind":1,"k":["sessionId"],"v":"journal-id"}"#,
            #"{"kind":2,"k":["requests"],"v":[{"timestamp":1700000005000,"message":{"text":"aurora question"},"response":[{"value":{"kind":"markdownContent","content":{"value":"aurora answer"}}}]}]}"#,
        ]
        let raw = Data((lines.joined(separator: "\n") + "\n").utf8)
        let config = Data(#"{"folders":[{"path":"../repository"}]}"#.utf8)
        let context = try ArchiveVSCodeWorkspaceContext(configurationLocator: "/offline/work/project.code-workspace",
            configurationGeneration: configurationPresent ? ArchiveSourceGeneration(device: 1, inode: 5,
                size: Int64(config.count), mtimeNs: 6, ctimeNs: 7, mode: 0o100600) : nil,
            configurationData: configurationPresent ? config : nil,
            configurationSHA256: configurationPresent ? ArchiveV2Hash.sha256(config) : nil)
        return try makeFileSetFixture(payloads: [primary: raw,
            workspace: Data(#"{"configuration":"file:///offline/work/project.code-workspace"}"#.utf8)],
            primary: primary, format: format, source: .vscode, configuredRoot: "/offline/Code/workspaceStorage",
            canonicalSlots: [primary, workspace], vscodeContext: context)
    }

    func testCursorLegacyBodyMetadataMustMatchManifestContextAndFullGeneration() async throws {
        let fixture = try legacyFixture()
        guard let valid = await replaySuccess(fixture) else { return }
        XCTAssertEqual(valid.scan.messages.map(\.content), ["aurora legacy"])
        for field in ["cwd", "nativePayloadByteCount", "rawPayloadByteCount", "walGeneration"] {
            let rebound = try alteredManifest(fixture) { object in
                var layout = object["replayLayout"] as! [String: Any]
                var context = layout["cursorLegacySession"] as! [String: Any]
                switch field {
                case "cwd": context[field] = "/rebound/project"
                case "walGeneration": context[field] = object["generation"]
                default: context[field] = (context[field] as! Int) + 1
                }
                layout["cursorLegacySession"] = context
                object["replayLayout"] = layout
            }
            await assertReplayError(rebound, .parseFailed(.malformedJSON))
        }
        for field in ["device", "inode", "size", "mtimeNs", "ctimeNs", "mode"] {
            let rebound = try alteredManifest(fixture) { object in
                var generation = object["generation"] as! [String: Any]
                generation[field] = (generation[field] as! Int) + 1
                object["generation"] = generation
            }
            await assertReplayError(rebound, .parseFailed(.malformedJSON))
        }
        try assertEmpty(fixture.stagingParent)
    }

    func testCursorLegacyHQRequiresExactConfiguredGlobalDatabaseRootAndSealedStaging() async throws {
        let fixture = try legacyFixture()
        guard await replaySuccess(fixture) != nil else { return }
        await assertReplayError(fixture.withBinding(binding(root: "/offline/other", source: .cursor, format: .cursor)),
            .quarantined(.invalidReplayLayout))
        await assertReplayError(fixture, .quarantined(.unsafeStaging), hooks: .init(afterParse: { primary in
            try FileManager.default.removeItem(at: primary)
        }))
        try assertEmpty(fixture.stagingParent)
    }

    func testCursorLegacyEncodedEnvelopeUsesOwnLimitBeforeCheckingMissingChunks() async throws {
        let fixture = try legacyFixture()
        let expanded = try alteredManifest(fixture) { object in
            let rawCount = SessionAdapterFactory.maximumCapturedSourceBytes + 1
            object["rawByteCount"] = rawCount
            var remaining = rawCount
            var chunks: [[String: Any]] = []
            while remaining > 0 {
                let size = min(remaining, ArchiveSourceManifest.rawChunkSize)
                chunks.append(["ordinal": chunks.count, "rawSHA256": String(repeating: "f", count: 64), "rawByteCount": size])
                remaining -= size
            }
            object["chunks"] = chunks
        }
        // No large allocation is needed: after accepting encoded overhead,
        // the first absent CAS chunk must fail rather than the native file cap.
        await assertReplayError(expanded, .retryable(.casUnavailable))
        try assertEmpty(fixture.stagingParent)
    }

    private func legacyFixture() throws -> Fixture {
        let fixtureRoot = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try privateDirectory(fixtureRoot)
        let casRoot = fixtureRoot.appendingPathComponent("cas", isDirectory: true)
        let cas = try ImmutableArchiveCAS(root: casRoot)
        let staging = fixtureRoot.appendingPathComponent("stage", isDirectory: true)
        try privateDirectory(staging)
        let configuredRoot = "/offline/Cursor/User/globalStorage"
        let body = try ArchiveCursorLegacySession(logicalDatabaseLocator: configuredRoot + "/state.vscdb",
            composerID: "legacy", cwd: "/offline/project",
            databaseGeneration: ArchiveSourceGeneration(device: 1, inode: 2, size: 4096,
                mtimeNs: 3, ctimeNs: 4, mode: 0o100600), walGeneration: nil,
            composer: .init(rowID: 1, key: "composerData:legacy",
                value: Data(#"{"composerId":"legacy","conversation":[{"type":1,"text":"aurora legacy"}]}"#.utf8)), bubbles: [])
        let raw = try body.encodeCanonical()
        let hash = ArchiveV2Hash.sha256(raw)
        _ = try cas.publishObject(raw: raw, expectedSHA256: hash)
        let manifest = try ArchiveSourceManifest(schemaVersion: 6,
            captureID: ArchiveV2Hash.sha256(Data(UUID().uuidString.utf8)), machineID: machine,
            source: "cursor", locator: body.logicalLocator, sessionID: nil, capturedAt: "2026-09-09T00:00:00Z",
            generation: body.databaseGeneration, wholeSourceSHA256: hash, rawByteCount: Int64(raw.count),
            chunks: [ArchiveChunkReference(ordinal: 0, rawSHA256: hash, rawByteCount: Int64(raw.count))],
            replayLayout: ArchiveReplayLayout(strategy: .singleFile, relativePaths: ["session.cursor-legacy.json"],
                cursorLegacySession: ArchiveCursorLegacyContext(session: body)))
        let bytes = try ArchiveCanonicalJSON.encode(manifest)
        let digest = ArchiveV2Hash.sha256(bytes)
        _ = try cas.publishManifest(bytes, expectedSHA256: digest)
        let publication = try CollectorPublicationEnvelope(machineID: machine, sourceInstanceID: instance,
            collectorEpoch: epoch, sequence: 1, manifestSHA256: digest)
        return Fixture(cas: cas, casRoot: casRoot, stagingParent: staging, manifest: manifest,
            publication: publication, binding: binding(root: configuredRoot, source: .cursor, format: .cursor))
    }

    // 1. Exact bytes feed the existing Claude parser, including usage/drop policy.
    func testClaudeCASReplayMatchesLegacyScanAndUsesLogicalMetadata() async throws {
        let raw = try claudeBytes()
        let fixture = try makeFixture(raw: raw)
        let baseline = try await legacyScan(raw: raw, relative: "project/session.jsonl", codex: false)
        guard let replay = await replaySuccess(fixture) else { return }
        assertParity(replay.scan, baseline: baseline, logicalLocator: fixture.manifest.locator)
        XCTAssertEqual(replay.rawSourceSessionID, "native-session")
        XCTAssertEqual(replay.nativeIdentity.nativeID, baseline.info.id)
        XCTAssertEqual(replay.verifiedManifest, fixture.manifest)
        XCTAssertEqual(replay.publicationSHA256, try fixture.publication.sha256())
        XCTAssertEqual(replay.bindingSnapshot, fixture.binding)
        XCTAssertEqual(replay.scan.messages.compactMap(\.usage).first?.inputTokens, 7)
        XCTAssertTrue(replay.scan.unknownRecordKinds.contains("future-lifecycle"))
        XCTAssertFalse(replay.scan.messages.contains { $0.role == .system })
        XCTAssertNil(replay.parentIdentity)
        XCTAssertNil(replay.suggestedParentIdentity)
        try assertEmpty(fixture.stagingParent)
    }

    // 2. Codex selection, messages, usage, originator, and tier inputs remain native.
    func testCodexCASReplayAboveLegacyFileCapRetainsCompletePayload() async throws {
        var raw = try codexBytes()
        let output = String(repeating: "x", count: 26 * 1024 * 1024)
        let record = try jsonl([["type": "response_item", "payload": [
            "type": "function_call_output", "output": output, "call_id": "large-tool"
        ]]])
        for _ in 0..<4 { raw.append(record) }
        XCTAssertGreaterThan(raw.count, 100 * 1024 * 1024)
        let fixture = try makeFixture(raw: raw, source: .codex, format: .codex,
            relative: "2026/09/06/rollout-large.jsonl")
        guard let result = await replaySuccess(fixture) else { return }
        XCTAssertEqual(result.scan.messages.first?.content, "Implement a useful feature")
        XCTAssertEqual(result.scan.messages.suffix(4).map(\.content), Array(repeating: output, count: 4))
        try assertEmpty(fixture.stagingParent)
    }

    func testCodexCASReplayMatchesLegacyFirstMetadataAndDispatchSemantics() async throws {
        let raw = try codexBytes(originator: "Claude_Code")
        let fixture = try makeFixture(
            raw: raw, source: .codex, format: .codex,
            configuredRoot: "/offline-client/.codex/sessions", relative: "2026/09/rollout.jsonl"
        )
        let baseline = try await legacyScan(raw: raw, relative: "2026/09/rollout.jsonl", codex: true)
        guard let replay = await replaySuccess(fixture) else { return }
        assertParity(replay.scan, baseline: baseline, logicalLocator: fixture.manifest.locator)
        XCTAssertEqual(replay.scan.info.id, "codex-native")
        XCTAssertEqual(replay.rawSourceSessionID, "codex-native")
        XCTAssertEqual(replay.scan.info.agentRole, "dispatched")
        XCTAssertEqual(tier(replay.scan.info), .skip)
        XCTAssertNil(replay.scan.info.tier, "Replay must not grant an indexing tier")
        try assertEmpty(fixture.stagingParent)
    }

    func testQwenCASReplayPreservesNativeParserMessagesUsageAndLogicalIdentity() async throws {
        let format = try XCTUnwrap(CaptureIngestParseFormat(rawValue: "qwen"))
        let raw = try qwenBytes()
        let local = try writeFixture(raw, relative: "qwen-baseline/project/chats/session.jsonl")
        let adapter = QwenAdapter(projectsRoot: local.deletingLastPathComponent().deletingLastPathComponent().path)
        let baseline: IndexingScan
        switch try await adapter.scanForIndexing(locator: local.path) {
        case .success(let value): baseline = value
        case .failure(let failure): throw failure
        }
        for parent in ["stage", "lobsterai-stage/subagents"] {
            let fixture = try makeFixture(raw: raw, source: .qwen, format: format,
                configuredRoot: "/offline-client/.qwen/projects", relative: "project/chats/session.jsonl",
                parentName: parent)
            guard let replay = await replaySuccess(fixture) else { continue }
            var expected = baseline.info
            expected.filePath = fixture.manifest.locator
            XCTAssertEqual(replay.scan.info, expected)
            XCTAssertEqual(replay.scan.messages, baseline.messages)
            XCTAssertNil(replay.scan.parseFailure)
            XCTAssertEqual(replay.scan.info.source, .qwen)
            XCTAssertEqual(replay.scan.info.model, "qwen3-coder")
            XCTAssertEqual(replay.rawSourceSessionID, "native-qwen")
            XCTAssertEqual(replay.nativeIdentity.nativeID, "native-qwen")
            XCTAssertEqual(replay.scan.messages.compactMap(\.usage).first?.inputTokens, 12)
            XCTAssertEqual(replay.scan.messages.compactMap(\.usage).first?.outputTokens, 7)
            XCTAssertEqual(replay.scan.messages.last?.role, .tool)
            XCTAssertEqual(replay.scan.messages.last?.content, "tool result")
            try assertEmpty(fixture.stagingParent)
        }
    }

    func testPiCASReplayAfterOriginalRemovalPreservesNativeParserMessagesUsageAndLogicalIdentity_repro() async throws {
        let format = try XCTUnwrap(CaptureIngestParseFormat(rawValue: "pi"))
        let raw = try piBytes()
        let relative = "--Users-test--project--/2026-04-29T01-00-00-000Z_019dd6e3-91d1-7326-8299-314858773a0e.jsonl"
        let local = try writeFixture(raw, relative: "pi-baseline/\(relative)")
        let adapter = PiAdapter(sessionsRoot: local.deletingLastPathComponent().deletingLastPathComponent().path)
        let baseline: IndexingScan
        switch try await adapter.scanForIndexing(locator: local.path) {
        case .success(let value): baseline = value
        case .failure(let failure): throw failure
        }
        XCTAssertEqual(baseline.info.source, .pi)
        XCTAssertEqual(baseline.info.id, "019dd6e3-91d1-7326-8299-314858773a0e")
        XCTAssertEqual(baseline.info.cwd, "/Users/test/project")
        XCTAssertEqual(baseline.info.model, "mimo-v2.5-pro")
        XCTAssertEqual(baseline.messages.map(\.role), [.user, .assistant, .tool])
        XCTAssertEqual(baseline.messages.first?.content, "Fix the Pi parser")
        XCTAssertEqual(baseline.messages[1].content, "I will inspect it.")
        XCTAssertEqual(baseline.messages[1].toolCalls?.first?.name, "read")
        XCTAssertEqual(baseline.messages.compactMap(\.usage).first?.inputTokens, 10)
        XCTAssertEqual(baseline.messages.compactMap(\.usage).first?.outputTokens, 5)
        XCTAssertEqual(baseline.messages.compactMap(\.usage).first?.cacheReadTokens, 2)
        XCTAssertEqual(baseline.messages.compactMap(\.usage).first?.cacheCreationTokens, 1)
        XCTAssertEqual(baseline.messages.last?.role, .tool)

        let decoy = try jsonl([["type": "session", "id": "live-decoy", "cwd": "/tmp/decoy",
            "timestamp": "2026-04-29T01:00:00.000Z"]])
        try decoy.write(to: local)
        let fixture = try makeFixture(raw: raw, source: .pi, format: format,
            configuredRoot: "/offline-client/.pi/agent/sessions", relative: relative)
        try FileManager.default.removeItem(at: local)
        XCTAssertFalse(FileManager.default.fileExists(atPath: local.path))
        guard let replay = await replaySuccess(fixture) else { return }
        var expected = baseline.info
        expected.filePath = fixture.manifest.locator
        XCTAssertEqual(replay.scan.info, expected)
        XCTAssertEqual(replay.scan.messages, baseline.messages)
        XCTAssertNil(replay.scan.parseFailure)
        XCTAssertEqual(replay.scan.info.source, .pi)
        XCTAssertEqual(replay.rawSourceSessionID, "019dd6e3-91d1-7326-8299-314858773a0e")
        XCTAssertEqual(replay.nativeIdentity.nativeID, "019dd6e3-91d1-7326-8299-314858773a0e")
        try assertEmpty(fixture.stagingParent)

        let capturedCopy = try writeFixture(raw, relative: "pi-captured-physical/\(relative)")
        switch try PiAdapter.scanCapturedSource(physicalLocator: capturedCopy.path, logicalLocator: local.path) {
        case .success(let captured):
            XCTAssertEqual(captured.scan.messages, baseline.messages)
            XCTAssertEqual(captured.rawSourceSessionID, "019dd6e3-91d1-7326-8299-314858773a0e")
            XCTAssertEqual(captured.scan.info.filePath, local.path)
        case .failure(let failure):
            XCTFail("Captured Pi scan must not fall back to the removed live locator: \(failure)")
        }
    }

    func testPiCapturedReplayExceedsLegacyEightMiBLine_repro() async throws {
        let oversized = String(repeating: "x", count: ParserLimits.default.maxLineBytes + 1)
        XCTAssertEqual(oversized.utf8.count, ParserLimits.default.maxLineBytes + 1)
        let raw = try jsonl([
            ["type": "session", "id": "019dd6e3-91d1-7326-8299-314858773a0e",
             "timestamp": "2026-04-29T01:00:00.000Z", "cwd": "/Users/test/project"],
            ["type": "message", "id": "msg-user",
             "message": ["role": "user", "content": [["type": "text", "text": oversized]]]],
        ])
        let relative = "2026-04-29T01-00-00-000Z_019dd6e3-91d1-7326-8299-314858773a0e.jsonl"
        let local = try writeFixture(raw, relative: "pi-oversize-live/\(relative)")
        switch try await PiAdapter(sessionsRoot: local.deletingLastPathComponent().path).scanForIndexing(locator: local.path) {
        case .success:
            XCTFail("live Pi adapter must keep the 8MiB default line cap")
        case .failure(let failure):
            XCTAssertEqual(failure, .lineTooLarge)
        }
        let captured = try writeFixture(raw, relative: "pi-oversize-captured/\(relative)")
        switch try PiAdapter.scanCapturedSource(physicalLocator: captured.path, logicalLocator: local.path) {
        case .success(let scan):
            XCTAssertEqual(scan.rawSourceSessionID, "019dd6e3-91d1-7326-8299-314858773a0e")
            XCTAssertEqual(scan.scan.messages.first?.content.utf8.count, oversized.utf8.count)
            XCTAssertNil(scan.scan.parseFailure)
        case .failure(let failure):
            XCTFail("captured Pi replay must read an 8MiB+ line: \(failure)")
        }
    }

    func testQwenReplayRejectsMalformedRecordsAndWrongFormatBinding() async throws {
        let format = try XCTUnwrap(CaptureIngestParseFormat(rawValue: "qwen"))
        let raw = try qwenBytes()
        let valid = try makeFixture(raw: raw, source: .qwen, format: format,
            configuredRoot: "/offline-client/.qwen/projects", relative: "p/chats/session.jsonl")
        await assertReplayError(valid.withBinding(binding(root: "/offline-client/.qwen/projects",
            source: .qwen, format: .claudeDefault)), .quarantined(.bindingMismatch))
        let malformed = try makeFixture(raw: raw + Data("not-json\n".utf8), source: .qwen, format: format,
            configuredRoot: "/offline-client/.qwen/projects", relative: "p/chats/session.jsonl")
        do {
            _ = try await replay(malformed)
            XCTFail("Captured Qwen replay must not silently skip malformed records")
        } catch let error as CaptureIngestReplayError {
            guard case .parseFailed = error else { XCTFail("Expected parse failure, got \(error)"); return }
        }
        try assertEmpty(malformed.stagingParent)
    }

    func testQwenReplayUsesCapturedModificationTimeWhenRecordsHaveNoTimestamp() async throws {
        let format = try XCTUnwrap(CaptureIngestParseFormat(rawValue: "qwen"))
        let raw = try jsonl([
            ["type": "user", "sessionId": "native-qwen", "cwd": "/repo/qwen-project",
             "message": ["parts": [["text": "request without timestamp"]]]],
            ["type": "assistant", "sessionId": "native-qwen", "cwd": "/repo/qwen-project",
             "model": "qwen3-coder", "message": ["parts": [["text": "reply without timestamp"]]]],
        ])
        let local = try writeFixture(raw, relative: "qwen-time-baseline/p/chats/session.jsonl")
        let modified = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: local.path)
        let baseline: NormalizedSessionInfo
        switch try await QwenAdapter().parseSessionInfo(locator: local.path) {
        case .success(let value): baseline = value
        case .failure(let failure): throw failure
        }
        let fixture = try makeFixture(raw: raw, source: .qwen, format: format,
            configuredRoot: "/offline-client/.qwen/projects", relative: "p/chats/session.jsonl")
        let capturedTime = try alteredManifest(fixture) { object in
            var generation = object["generation"] as! [String: Any]
            generation["mtimeNs"] = Int64(1_600_000_000_000_000_000)
            object["generation"] = generation
        }
        guard let replay = await replaySuccess(capturedTime) else { return }
        XCTAssertEqual(replay.scan.info.startTime, baseline.startTime,
            "a replay must use original capture time evidence, not the staging file creation time")
    }

    func testClineCapturedArrayPreservesNativeTaskIdentityMessagesAndUsage() async throws {
        let format = try XCTUnwrap(CaptureIngestParseFormat(rawValue: SourceName.cline.rawValue))
        let request = String(decoding: try JSONSerialization.data(withJSONObject: [
            "request": "Current Working Directory (/offline/project(with)paren) Files", "tokensIn": 100, "tokensOut": 7
        ], options: [.sortedKeys]), as: UTF8.self)
        let raw = try JSONSerialization.data(withJSONObject: [
            ["ts": 1_780_000_000_000, "say": "task", "text": "cline request"],
            ["ts": 1_780_000_000_001, "say": "api_req_started", "text": request,
             "modelInfo": ["modelId": "cline-model"]],
            ["ts": 1_780_000_000_002, "say": "text", "text": "cline answer"],
        ], options: [.sortedKeys, .prettyPrinted])
        for name in ["ui_messages.json", "claude_messages.json"] {
            let relative = "task-opaque/" + name
            let baseline = try await nativeScan(raw: raw, source: .cline, relative: relative)
            let absent = name == "claude_messages.json" ? ["task-opaque/ui_messages.json"] : []
            let fixture = try makeFixture(raw: raw, source: .cline, format: format,
                configuredRoot: "/offline-client/.cline/data/tasks", relative: relative,
                parentName: "arbitrary-stage", fileSetAbsent: absent)
            guard let replay = await replaySuccess(fixture) else { continue }
            var expected = baseline.scan.info; expected.filePath = fixture.manifest.locator
            XCTAssertEqual(replay.scan.info, expected)
            XCTAssertEqual(replay.scan.messages, baseline.scan.messages)
            XCTAssertEqual(replay.rawSourceSessionID, "task-opaque")
            XCTAssertEqual(replay.nativeIdentity.nativeID, "task-opaque")
            XCTAssertEqual(replay.scan.info.cwd, "/offline/project(with)paren")
            XCTAssertEqual(replay.scan.messages.last?.usage?.inputTokens, 100)
            XCTAssertEqual(replay.scan.messages.last?.usage?.outputTokens, 7)
            try assertEmpty(fixture.stagingParent)
        }
    }

    func testClineReplayRejectsMissingPreferenceProofWrongFormatAndMalformedArray() async throws {
        let root = "/offline-client/.cline/data/tasks"
        let raw = Data(#"[{"say":"task","text":"question","ts":1780000000000}]"#.utf8)
        let valid = try makeFixture(raw: raw, source: .cline, format: .cline,
            configuredRoot: root, relative: "task-one/ui_messages.json", fileSetAbsent: [])
        await assertReplayError(valid.withBinding(binding(root: root, source: .cline, format: .claudeDefault)),
            .quarantined(.bindingMismatch))
        let missingProof = try makeFixture(raw: raw, source: .cline, format: .cline,
            configuredRoot: root, relative: "task-one/claude_messages.json", fileSetAbsent: [])
        await assertReplayError(missingProof, .quarantined(.unsupportedCaptureShape))
        let wrongProof = try makeFixture(raw: raw, source: .cline, format: .cline,
            configuredRoot: root, relative: "task-one/claude_messages.json", fileSetAbsent: ["other-task/ui_messages.json"])
        await assertReplayError(wrongProof, .quarantined(.unsupportedCaptureShape))
        for bytes in [raw + Data("junk".utf8), Data("[{},]".utf8), Data("[42]".utf8)] {
            let malformed = try makeFixture(raw: bytes, source: .cline, format: .cline,
                configuredRoot: root, relative: "task-one/ui_messages.json", fileSetAbsent: [])
            do {
                _ = try await replay(malformed)
                XCTFail("Captured Cline must reject malformed arrays")
            } catch let error as CaptureIngestReplayError {
                guard case .parseFailed = error else { XCTFail("Expected parse failure, got \(error)"); continue }
            }
            try assertEmpty(malformed.stagingParent)
        }
    }

    func testIflowCASReplayPreservesNativeMessagesAndLogicalIdentity() async throws {
        let format = try XCTUnwrap(CaptureIngestParseFormat(rawValue: SourceName.iflow.rawValue))
        let raw = try iflowBytes()
        let baseline = try await nativeScan(raw: raw, source: .iflow, relative: "project/session-one.jsonl")
        for parent in ["stage", "lobsterai-stage/subagents"] {
            let fixture = try makeFixture(raw: raw, source: .iflow, format: format,
                configuredRoot: "/offline-client/.iflow/projects", relative: "project/session-one.jsonl", parentName: parent)
            guard let replay = await replaySuccess(fixture) else { continue }
            var expected = baseline.scan.info
            expected.filePath = fixture.manifest.locator
            XCTAssertEqual(replay.scan.info, expected)
            XCTAssertEqual(replay.scan.messages, baseline.scan.messages)
            XCTAssertNil(replay.scan.parseFailure)
            XCTAssertEqual(replay.scan.info.source, .iflow)
            XCTAssertEqual(replay.rawSourceSessionID, "native-iflow")
            XCTAssertEqual(replay.nativeIdentity.nativeID, "native-iflow")
            XCTAssertEqual(replay.scan.messages.map(\.role), [.user, .assistant])
            try assertEmpty(fixture.stagingParent)
        }
    }

    private func iflowBytes() throws -> Data {
        let records: [[String: Any]] = [
            ["type": "user", "sessionId": "native-iflow", "cwd": "/offline-project",
             "timestamp": "2026-09-09T00:00:00Z", "message": ["content": "iflow archive request"]],
            ["type": "assistant", "sessionId": "native-iflow", "cwd": "/offline-project",
             "timestamp": "2026-09-09T00:00:01Z", "message": ["model": "MiniMax-M2.1", "content": "iflow archive reply"]],
        ]
        return try records.reduce(into: Data()) { result, record in
            result.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
            result.append(10)
        }
    }

    func testIflowReplayRejectsMalformedRecordsAndWrongFormatBinding() async throws {
        let format = try XCTUnwrap(CaptureIngestParseFormat(rawValue: SourceName.iflow.rawValue))
        let raw = try iflowBytes()
        let valid = try makeFixture(raw: raw, source: .iflow, format: format,
            configuredRoot: "/offline-client/.iflow/projects", relative: "project/session-one.jsonl")
        await assertReplayError(valid.withBinding(binding(root: "/offline-client/.iflow/projects",
            source: .iflow, format: .claudeDefault)), .quarantined(.bindingMismatch))
        let malformed = try makeFixture(raw: raw + Data("not-json\n".utf8), source: .iflow, format: format,
            configuredRoot: "/offline-client/.iflow/projects", relative: "project/session-one.jsonl")
        do {
            _ = try await replay(malformed)
            XCTFail("Captured iFlow replay must not silently skip malformed records")
        } catch let error as CaptureIngestReplayError {
            guard case .parseFailed = error else { XCTFail("Expected parse failure, got \(error)"); return }
        }
        try assertEmpty(malformed.stagingParent)
    }

    func testQoderCASReplayPreservesNativeParserMessagesUsageAndLogicalIdentity() async throws {
        let format = try XCTUnwrap(CaptureIngestParseFormat(rawValue: SourceName.qoder.rawValue))
        let raw = try qoderBytes()
        let baseline = try await nativeScan(raw: raw, source: .qoder, relative: "project/session.jsonl")
        for parent in ["stage", "lobsterai-stage/subagents"] {
            let fixture = try makeFixture(raw: raw, source: .qoder, format: format,
                configuredRoot: "/offline-client/.qoder/projects", relative: "project/session.jsonl",
                parentName: parent)
            guard let replay = await replaySuccess(fixture) else { continue }
            var expected = baseline.scan.info
            expected.filePath = fixture.manifest.locator
            XCTAssertEqual(replay.scan.info, expected)
            XCTAssertEqual(replay.scan.messages, baseline.scan.messages)
            XCTAssertNil(replay.scan.parseFailure)
            XCTAssertEqual(replay.scan.info.source, .qoder)
            XCTAssertEqual(replay.scan.info.model, "qoder-agent")
            XCTAssertEqual(replay.scan.info.id, "native-qoder")
            XCTAssertEqual(replay.rawSourceSessionID, "native-qoder")
            XCTAssertEqual(replay.nativeIdentity.nativeID, "native-qoder")
            XCTAssertEqual(replay.scan.messages.compactMap(\.usage).first?.inputTokens, 12)
            XCTAssertEqual(replay.scan.messages.compactMap(\.usage).first?.outputTokens, 8)
            XCTAssertEqual(replay.scan.messages.map(\.role), [.user, .assistant, .assistant, .tool])
            XCTAssertEqual(replay.scan.messages.last?.content, "file contents omitted")
            try assertEmpty(fixture.stagingParent)
        }
    }

    func testQoderReplayPreservesProjectLevelAndNestedSubagentIdentityWithoutClaudeRelabel() async throws {
        let format = try XCTUnwrap(CaptureIngestParseFormat(rawValue: SourceName.qoder.rawValue))
        let layouts = [
            "project/subagents/agent-worker.jsonl",
            "project/qoder-parent-session/subagents/agent-child.jsonl",
        ]
        let raw = try qoderBytes(sessionId: "native-qoder")
        for relative in layouts {
            let baseline = try await nativeScan(raw: raw, source: .qoder, relative: relative)
            let layout = try XCTUnwrap(SubagentTranscriptPath.layout(
                locator: baseline.locator, projectsRoot: baseline.projectsRoot,
                projectLevelParentSessionId: "native-qoder"))
            XCTAssertEqual(baseline.scan.info.id, "sub:native-qoder:\(layout.relativePath)")
            XCTAssertEqual(baseline.scan.info.parentSessionId, layout.parentSessionId)
            let fixture = try makeFixture(raw: raw, source: .qoder, format: format,
                configuredRoot: "/offline-client/.qoder/projects", relative: relative,
                parentName: "lobsterai-stage/subagents")
            guard let replay = await replaySuccess(fixture) else { continue }
            var expected = baseline.scan.info
            expected.filePath = fixture.manifest.locator
            XCTAssertEqual(replay.scan.info, expected)
            XCTAssertEqual(replay.scan.info.source, .qoder)
            XCTAssertEqual(replay.scan.info.agentRole, "subagent")
            XCTAssertEqual(tier(replay.scan.info), .skip)
            XCTAssertNotEqual(replay.scan.info.id, "native-qoder")
            XCTAssertEqual(replay.rawSourceSessionID, "native-qoder")
            XCTAssertEqual(replay.scan.info.id, "sub:native-qoder:\(layout.relativePath)")
            XCTAssertEqual(replay.scan.info.parentSessionId, layout.parentSessionId)
            try assertEmpty(fixture.stagingParent)
        }
    }

    func testQoderReplayRejectsMalformedRecordsAndWrongFormatBinding() async throws {
        let format = try XCTUnwrap(CaptureIngestParseFormat(rawValue: SourceName.qoder.rawValue))
        let raw = try qoderBytes()
        let valid = try makeFixture(raw: raw, source: .qoder, format: format,
            configuredRoot: "/offline-client/.qoder/projects", relative: "project/session.jsonl")
        await assertReplayError(valid.withBinding(binding(root: "/offline-client/.qoder/projects",
            source: .qoder, format: .claudeDefault)), .quarantined(.bindingMismatch))
        let malformed = try makeFixture(raw: raw + Data("not-json\n".utf8), source: .qoder, format: format,
            configuredRoot: "/offline-client/.qoder/projects", relative: "project/session.jsonl")
        do {
            _ = try await replay(malformed)
            XCTFail("Captured Qoder replay must not silently skip malformed records")
        } catch let error as CaptureIngestReplayError {
            guard case .parseFailed = error else { XCTFail("Expected parse failure, got \(error)"); return }
        }
        try assertEmpty(malformed.stagingParent)
    }

    func testCommandCodeCASReplayPreservesNativeParserRolesModelSlugCwdAndNoSessionParent() async throws {
        let format = try XCTUnwrap(CaptureIngestParseFormat(rawValue: SourceName.commandcode.rawValue))
        let raw = try commandCodeBytes()
        let relative = "-Users-test-my--project/session.jsonl"
        let baseline = try await nativeScan(raw: raw, source: .commandcode, relative: relative)
        XCTAssertEqual(baseline.scan.info.cwd, "/Users/test/my-project")
        for parent in ["stage", "lobsterai-stage/subagents"] {
            let fixture = try makeFixture(raw: raw, source: .commandcode, format: format,
                configuredRoot: "/offline-client/.commandcode/projects", relative: relative,
                parentName: parent)
            guard let replay = await replaySuccess(fixture) else { continue }
            var expected = baseline.scan.info
            expected.filePath = fixture.manifest.locator
            XCTAssertEqual(replay.scan.info, expected)
            XCTAssertEqual(replay.scan.messages, baseline.scan.messages)
            XCTAssertNil(replay.scan.parseFailure)
            XCTAssertEqual(replay.scan.info.source, .commandcode)
            XCTAssertEqual(replay.scan.info.model, "command-code-agent")
            XCTAssertEqual(replay.scan.info.cwd, "/Users/test/my-project")
            XCTAssertEqual(replay.scan.info.id, "native-commandcode")
            XCTAssertEqual(replay.rawSourceSessionID, "native-commandcode")
            XCTAssertNil(replay.scan.info.parentSessionId)
            XCTAssertNil(replay.parentIdentity)
            XCTAssertEqual(replay.scan.messages.map(\.role), [.user, .assistant, .tool])
            XCTAssertTrue(replay.scan.messages.allSatisfy { $0.usage == nil })
            try assertEmpty(fixture.stagingParent)
        }
    }

    func testCommandCodeReplayPreservesUnknownProjectFromLossySlug() async throws {
        let format = try XCTUnwrap(CaptureIngestParseFormat(rawValue: SourceName.commandcode.rawValue))
        let fixture = try makeFixture(raw: commandCodeBytes(), source: .commandcode, format: format,
            configuredRoot: "/offline-client/.commandcode/projects", relative: "users-bing-code-project/session.jsonl")
        guard let result = await replaySuccess(fixture) else { return }
        XCTAssertEqual(result.scan.info.cwd, "")
        XCTAssertEqual(result.rawSourceSessionID, "native-commandcode")
        XCTAssertEqual(result.scan.messages.map(\.role), [.user, .assistant, .tool])
        try assertEmpty(fixture.stagingParent)
    }

    func testCommandCodeReplayUsesCapturedModificationTimeWhenRecordsHaveNoTimestamp() async throws {
        let format = try XCTUnwrap(CaptureIngestParseFormat(rawValue: SourceName.commandcode.rawValue))
        let raw = try jsonl([
            ["role": "user", "sessionId": "native-commandcode",
             "content": [["type": "text", "text": "request without timestamp"]]],
            ["role": "assistant", "sessionId": "native-commandcode", "model": "command-code-agent",
             "content": [["type": "text", "text": "reply without timestamp"]]],
        ])
        let local = try writeFixture(raw, relative: "commandcode-time-baseline/-Users-test-my--project/session.jsonl")
        let modified = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: local.path)
        let baseline: NormalizedSessionInfo
        switch try await CommandCodeAdapter().parseSessionInfo(locator: local.path) {
        case .success(let value):
            baseline = value
            XCTAssertEqual(value.cwd, "/Users/test/my-project")
        case .failure(let failure): throw failure
        }
        let fixture = try makeFixture(raw: raw, source: .commandcode, format: format,
            configuredRoot: "/offline-client/.commandcode/projects",
            relative: "-Users-test-my--project/session.jsonl")
        let capturedTime = try alteredManifest(fixture) { object in
            var generation = object["generation"] as! [String: Any]
            generation["mtimeNs"] = Int64(1_600_000_000_000_000_000)
            object["generation"] = generation
        }
        guard let replay = await replaySuccess(capturedTime) else { return }
        XCTAssertEqual(replay.scan.info.startTime, baseline.startTime,
            "a replay must use original capture time evidence, not the staging file creation time")
    }

    func testCommandCodeReplayRejectsMalformedRecordsAndWrongFormatBinding() async throws {
        let format = try XCTUnwrap(CaptureIngestParseFormat(rawValue: SourceName.commandcode.rawValue))
        let raw = try commandCodeBytes()
        let relative = "-Users-test-my--project/session.jsonl"
        let valid = try makeFixture(raw: raw, source: .commandcode, format: format,
            configuredRoot: "/offline-client/.commandcode/projects", relative: relative)
        await assertReplayError(valid.withBinding(binding(root: "/offline-client/.commandcode/projects",
            source: .commandcode, format: .claudeDefault)), .quarantined(.bindingMismatch))
        let malformed = try makeFixture(raw: raw + Data("not-json\n".utf8), source: .commandcode, format: format,
            configuredRoot: "/offline-client/.commandcode/projects", relative: relative)
        do {
            _ = try await replay(malformed)
            XCTFail("Captured CommandCode replay must not silently skip malformed records")
        } catch let error as CaptureIngestReplayError {
            guard case .parseFailed = error else { XCTFail("Expected parse failure, got \(error)"); return }
        }
        try assertEmpty(malformed.stagingParent)
    }

    private func piBytes() throws -> Data {
        try jsonl([
            ["type": "session", "version": 1, "id": "019dd6e3-91d1-7326-8299-314858773a0e",
             "timestamp": "2026-04-29T01:00:00.000Z", "cwd": "/Users/test/project"],
            ["type": "model_change", "id": "model-1",
             "parentId": "019dd6e3-91d1-7326-8299-314858773a0e",
             "timestamp": "2026-04-29T01:00:01.000Z", "modelId": "mimo-v2.5-pro"],
            ["type": "message", "id": "msg-user",
             "parentId": "019dd6e3-91d1-7326-8299-314858773a0e",
             "timestamp": "2026-04-29T01:00:02.000Z",
             "message": ["role": "user",
                "content": [["type": "text", "text": "Fix the Pi parser"]],
                "timestamp": "2026-04-29T01:00:02.000Z"]],
            ["type": "message", "id": "msg-assistant", "parentId": "msg-user",
             "timestamp": "2026-04-29T01:00:03.000Z",
             "message": ["role": "assistant",
                "content": [
                    ["type": "text", "text": "I will inspect it."],
                    ["type": "toolCall", "name": "read",
                     "arguments": ["path": "/Users/test/project/package.json"]],
                ],
                "model": "mimo-v2.5-pro",
                "usage": ["input": 10, "output": 5, "cacheRead": 2, "cacheWrite": 1],
                "timestamp": "2026-04-29T01:00:03.000Z"]],
            ["type": "message", "id": "msg-tool", "parentId": "msg-assistant",
             "timestamp": "2026-04-29T01:00:04.000Z",
             "message": ["role": "toolResult",
                "content": [["type": "text", "text": #"{"name":"fixture"}"#]],
                "timestamp": "2026-04-29T01:00:04.000Z"]],
        ])
    }

    private func qwenBytes() throws -> Data {
        let common: [String: Any] = ["sessionId": "native-qwen", "cwd": "/repo/qwen-project",
            "timestamp": "2026-09-08T00:00:00Z"]
        return try jsonl([
            common.merging(["type": "user", "message": ["parts": [["text": "Qwen request"]]]]) { _, new in new },
            common.merging(["type": "assistant", "model": "qwen3-coder",
                "message": ["parts": [["text": "Qwen response"]]],
                "usageMetadata": ["promptTokenCount": 12, "candidatesTokenCount": 7]]) { _, new in new },
            common.merging(["type": "tool_result", "toolCallResult": ["resultDisplay": "tool result"]]) { _, new in new },
        ])
    }

    private func qoderBytes(sessionId: String = "native-qoder") throws -> Data {
        let common: [String: Any] = ["sessionId": sessionId, "cwd": "/repo/qoder-project",
            "timestamp": "2026-09-08T00:00:00Z"]
        return try jsonl([
            ["type": "summary", "sessionId": "ignored-summary-id", "cwd": "/ignored"],
            common.merging(["type": "user", "message": ["role": "user", "content": "Review the parser"]]) { _, new in new },
            common.merging(["type": "assistant", "message": ["role": "assistant", "model": "qoder-agent",
                "content": [["type": "text", "text": "I will review the parser."]],
                "usage": ["input_tokens": 12, "output_tokens": 8, "cache_read_input_tokens": 3,
                    "cache_creation_input_tokens": 2]]]) { _, new in new },
            common.merging(["type": "assistant", "message": ["role": "assistant",
                "content": [["type": "tool_use", "id": "tool-001", "name": "Read",
                    "input": ["file_path": "/repo/qoder-project/src/parser.ts"]]]]]) { _, new in new },
            common.merging(["type": "user", "message": ["role": "user",
                "content": [["type": "tool_result", "tool_use_id": "tool-001",
                    "content": "file contents omitted"]]]]) { _, new in new },
        ])
    }

    private func commandCodeBytes() throws -> Data {
        return try jsonl([
            ["id": "msg-001", "sessionId": "native-commandcode", "parentId": NSNull(),
             "role": "user",
             "content": [["type": "text", "text": "Review the parser"]],
             "timestamp": "2026-09-08T00:00:00Z"],
            ["id": "msg-002", "sessionId": "native-commandcode", "parentId": "msg-001",
             "role": "assistant", "model": "command-code-agent",
             "content": [["type": "text", "text": "I will review the parser."],
                ["type": "tool-call", "toolCallId": "tool-001", "toolName": "read_file",
                 "input": ["path": "/Users/test/my-project/src/parser.ts"]]],
             "timestamp": "2026-09-08T00:00:01Z"],
            ["id": "msg-003", "sessionId": "native-commandcode", "parentId": "msg-002",
             "role": "tool",
             "content": [["type": "tool-result", "toolCallId": "tool-001", "toolName": "read_file",
                "output": "file contents omitted"]],
             "timestamp": "2026-09-08T00:00:02Z"],
        ])
    }

    private struct NativeScan {
        let scan: IndexingScan
        let locator: String
        let projectsRoot: String
    }

    private func nativeScan(raw: Data, source: SourceName, relative: String) async throws -> NativeScan {
        let local = try writeFixture(raw, relative: "native-\(source.rawValue)-\(UUID().uuidString)/\(relative)")
        var projectsRoot = local
        for _ in relative.split(separator: "/") {
            projectsRoot = projectsRoot.deletingLastPathComponent()
        }
        let result: AdapterParseResult<IndexingScan>
        switch source {
        case .cline:
            result = try await ClineAdapter(tasksRoot: projectsRoot.path).scanForIndexing(locator: local.path)
        case .iflow:
            result = try await IflowAdapter(projectsRoot: projectsRoot.path).scanForIndexing(locator: local.path)
        case .qoder:
            result = try await QoderAdapter(projectsRoot: projectsRoot.path).scanForIndexing(locator: local.path)
        case .commandcode:
            result = try await CommandCodeAdapter(projectsRoot: projectsRoot.path).scanForIndexing(locator: local.path)
        default:
            throw NSError(domain: "CaptureIngestReplayTests", code: 1)
        }
        switch result {
        case .success(let value):
            return NativeScan(scan: value, locator: local.path, projectsRoot: projectsRoot.path)
        case .failure(let failure): throw failure
        }
    }

    // 3. Only the proved relative vendor layout supplies parent/native identity.
    func testClaudeOrdinaryDirectAndWorkflowLayoutsSurviveDifferentStagingRoots() async throws {
        let layouts = [
            "project/session.jsonl", "subagents/session.jsonl",
            "project/parent/subagents/agent-one.jsonl",
            "project/parent/subagents/workflows/wf/agent-two.jsonl",
        ]
        for relative in layouts {
            let raw = try claudeBytes(nativeID: "parent")
            let baseline = try await legacyScan(raw: raw, relative: relative, codex: false)
            var identities: [CaptureIngestIdentity] = []
            for parentName in ["ordinary-stage", "lobsterai-stage/subagents"] {
                let fixture = try makeFixture(raw: raw, relative: relative, parentName: parentName)
                guard let replay = await replaySuccess(fixture) else { continue }
                assertParity(replay.scan, baseline: baseline, logicalLocator: fixture.manifest.locator)
                XCTAssertEqual(replay.nativeIdentity.nativeID, baseline.info.id)
                XCTAssertEqual(replay.rawSourceSessionID, "parent")
                XCTAssertEqual(replay.scan.info.source, .claudeCode)
                identities.append(replay.nativeIdentity)
                if relative.contains("/parent/subagents/") {
                    XCTAssertNotEqual(replay.nativeIdentity.nativeID, replay.rawSourceSessionID)
                    XCTAssertEqual(replay.parentIdentity?.nativeID, "parent")
                    XCTAssertEqual(replay.parentIdentity?.sourceInstanceID, instance)
                    XCTAssertEqual(tier(replay.scan.info), .skip)
                } else {
                    XCTAssertNil(replay.scan.info.agentRole)
                    XCTAssertNil(replay.parentIdentity)
                }
                try assertEmpty(fixture.stagingParent)
            }
            if identities.count == 2 { XCTAssertEqual(identities[0], identities[1]) }
        }
    }

    func testTruthfullyLabeledDerivedClaudeReplayPreservesNativeIdentityAndMessages() async throws {
        for (source, relative, model) in [(SourceName.minimax, "project/s.jsonl", "MiniMax-M2"),
                                        (.lobsterai, "lobsterai-project/s.jsonl", "claude-test")] {
            let raw = try claudeBytes(model: model)
            var prior: CaptureIngestReplayResult?
            for stage in ["ordinary-stage", "unrelated-lobsterai-stage"] {
                let fixture = try makeFixture(raw: raw, source: source, format: .claudeDefault,
                    configuredRoot: "/offline-client/.claude/projects", relative: relative, parentName: stage)
                guard let replay = await replaySuccess(fixture) else { continue }
                XCTAssertEqual(replay.scan.info.source, source)
                XCTAssertEqual(replay.nativeIdentity.source, source)
                XCTAssertEqual(replay.rawSourceSessionID, "native-session")
                XCTAssertEqual(replay.scan.info.cwd, "/repo/project")
                XCTAssertEqual(replay.scan.info.model, model)
                XCTAssertFalse(replay.scan.messages.isEmpty)
                XCTAssertGreaterThan(replay.scan.messages.compactMap(\.usage).reduce(0) { $0 + $1.inputTokens }, 0)
                if let prior {
                    XCTAssertEqual(replay.scan.info, prior.scan.info)
                    XCTAssertEqual(replay.scan.messages, prior.scan.messages)
                    XCTAssertEqual(replay.nativeIdentity, prior.nativeIdentity)
                }
                prior = replay
                try assertEmpty(fixture.stagingParent)
            }
        }
    }

    func testDerivedClaudeBindingsRejectContentFromAnotherSource() async throws {
        for (source, relative, model) in [(SourceName.minimax, "project/s.jsonl", "claude-test"),
                                        (.minimax, "lobsterai-project/s.jsonl", "MiniMax-M2"),
                                        (.lobsterai, "project/s.jsonl", "MiniMax-M2")] {
            let fixture = try makeFixture(raw: claudeBytes(model: model), source: source,
                format: .claudeDefault, configuredRoot: "/offline-client/.claude/projects", relative: relative)
            await assertReplayError(fixture, .quarantined(.sourceMismatch))
            try assertEmpty(fixture.stagingParent)
        }
    }

    // 4. Logical derived-source detection is preserved; mismatched labels remain rejected.
    func testDerivedSourceBridgeAndExplicitCustomProfileDoNotInferFromStagingPath() async throws {
        for (logical, model, expected) in [
            ("/offline-client/.claude/projects/p/s.jsonl", "MiniMax-M2", SourceName.minimax),
            ("/offline-client/lobsterai/projects/p/s.jsonl", "claude-test", SourceName.lobsterai),
        ] {
            let raw = try claudeBytes(model: model)
            let physical = try writeFixture(raw, relative: "bridge-\(UUID().uuidString)/p/s.jsonl")
            let stage = physical.deletingLastPathComponent().deletingLastPathComponent()
            let captured = try await SessionAdapterFactory.scanCapturedSource(
                physicalLocator: physical.path, stagingRoot: stage.path, logicalLocator: logical,
                format: .claudeCode(forceClaudeCodeSource: false)
            )
            if case .success(let value) = captured {
                XCTAssertEqual(value.scan.info.source, expected)
                XCTAssertEqual(value.scan.info.filePath, logical)
            } else { XCTFail("Captured bridge must preserve logical derived-source classification") }
            let root = String(logical.dropLast("/p/s.jsonl".count))
            let rejected = try makeFixture(raw: raw, configuredRoot: root, relative: "p/s.jsonl")
            await assertReplayError(rejected, .quarantined(.sourceMismatch))
            let custom = try makeFixture(
                raw: raw, format: .claudeCustomProfile, configuredRoot: root, relative: "p/s.jsonl"
            )
            guard let replay = await replaySuccess(custom) else { continue }
            XCTAssertEqual(replay.scan.info.source, .claudeCode)
            XCTAssertEqual(replay.scan.info.originator, "claude-code")
            try assertEmpty(custom.stagingParent)
        }
    }

    // 5. Native identifiers are byte-preserved and namespaced, not filename guesses.
    func testNativeIdentityPreservesBytesAndSeparatesInstancesAndMachines() async throws {
        let native = "session:e\u{301}/百分号%2F"
        let first = try makeFixture(raw: claudeBytes(nativeID: native), relative: "p/decoy-name.jsonl")
        let second = try makeFixture(
            raw: claudeBytes(nativeID: native), sourceInstance: "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD"
        )
        guard let one = await replaySuccess(first), let two = await replaySuccess(second) else { return }
        XCTAssertTrue(one.nativeIdentity.nativeID.utf8.elementsEqual(native.utf8))
        XCTAssertEqual(one.rawSourceSessionID, native)
        XCTAssertNotEqual(try one.nativeIdentity.proposedSessionID(), try two.nativeIdentity.proposedSessionID())
        XCTAssertEqual(one.bindingSnapshot.authorityGeneration, 7)
        let invalid = try makeFixture(raw: claudeBytes(nativeID: "bad\u{0000}id"))
        await assertReplayError(invalid, .quarantined(.invalidNativeIdentity))
    }

    // 6. Original canonical manifest bytes are hashed; legacy UUID spelling is not rewritten.
    func testCanonicalManifestValidationAndLegacyMachineUUID() async throws {
        let legacy = try makeFixture(raw: claudeBytes(), manifestMachine: machine.lowercased())
        guard let replay = await replaySuccess(legacy) else { return }
        XCTAssertEqual(replay.verifiedManifest.machineID, machine.lowercased())
        XCTAssertEqual(replay.nativeIdentity.machineID, machine)
        XCTAssertEqual(ArchiveV2Hash.sha256(try ArchiveCanonicalJSON.encode(replay.verifiedManifest)), legacy.publication.manifestSHA256)
        let valid = try makeFixture(raw: claudeBytes())
        for bytes in [Data("not-json".utf8), try ArchiveCanonicalJSON.encode(valid.manifest) + Data("\n".utf8)] {
            await assertReplayError(try replacingManifestBytes(valid, bytes), .quarantined(.invalidManifest))
        }
        let wrongSchema = try alteredManifest(valid) { $0["schemaVersion"] = 2 }
        await assertReplayError(wrongSchema, .quarantined(.invalidManifest))
        let missing = try replacingPublication(valid, manifestSHA: String(repeating: "1", count: 64))
        await assertReplayError(missing, .retryable(.casUnavailable))
        let mismatch = try makeFixture(raw: claudeBytes(), manifestMachine: "EEEEEEEE-EEEE-4EEE-8EEE-EEEEEEEEEEEE")
        await assertReplayError(mismatch, .quarantined(.manifestMismatch))
    }

    // 7. Every chunk's actual length/hash and the concatenated digest are verified.
    func testMissingTamperedWrongLengthAndWholeHashChunksNeverProduceScan() async throws {
        let raw = try claudeBytes()
        let missing = try makeFixture(raw: raw, publishObjects: false)
        await assertReplayError(missing, .retryable(.casUnavailable))
        let tampered = try makeFixture(raw: raw)
        try Data("tampered".utf8).write(to: objectURL(tampered, tampered.manifest.chunks[0].rawSHA256))
        await assertReplayError(tampered, .quarantined(.sourceIntegrityMismatch))
        for delta: Int64 in [-1, 1] {
            let fixture = try makeFixture(raw: raw)
            let wrongLength = try alteredManifest(fixture) { object in
                let count = Int64(raw.count) + delta
                object["rawByteCount"] = count
                var generation = object["generation"] as! [String: Any]
                generation["size"] = count
                object["generation"] = generation
                var chunks = object["chunks"] as! [[String: Any]]
                chunks[0]["rawByteCount"] = count
                object["chunks"] = chunks
            }
            await assertReplayError(wrongLength, .quarantined(.sourceIntegrityMismatch))
        }
        let whole = try alteredManifest(makeFixture(raw: raw)) { $0["wholeSourceSHA256"] = String(repeating: "2", count: 64) }
        await assertReplayError(whole, .quarantined(.sourceIntegrityMismatch))
    }

    // 8. Replay validates the supplied binding snapshot but grants no current DB authority.
    func testCaptureShapeAndBindingMismatchFailClosed() async throws {
        let valid = try makeFixture(raw: claudeBytes())
        let normalized = try alteredManifest(valid) { $0["sessionID"] = "normalized-export" }
        await assertReplayError(normalized, .quarantined(.unsupportedCaptureShape))
        let mislabeled = try alteredManifest(valid) { $0["source"] = "minimax" }
        await assertReplayError(mislabeled, .quarantined(.bindingMismatch))
        let variants = [
            binding(root: logicalRoot, sourceInstance: "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD"),
            binding(root: logicalRoot, approvedEpoch: "EEEEEEEE-EEEE-4EEE-8EEE-EEEEEEEEEEEE"),
            binding(root: logicalRoot, source: .codex, format: .codex),
            binding(root: logicalRoot, source: .claudeCode, format: .codex),
            binding(root: logicalRoot, generation: 0),
        ]
        for supplied in variants {
            await assertReplayError(valid.withBinding(supplied), .quarantined(.bindingMismatch))
        }
        let wrongExtension = try makeFixture(raw: claudeBytes(), relative: "p/source.sqlite")
        await assertReplayError(wrongExtension, .quarantined(.unsupportedCaptureShape))
    }

    // 9. Root/layout comparisons use exact lexical bytes, with only the documented Codex prefix.
    func testReplayLayoutRejectsAliasesAndAcceptsOnlyDocumentedCodexPrefix() async throws {
        let raw = try claudeBytes()
        for (root, locator, layout) in [
            (logicalRoot, logicalRoot + "-sibling/p/s.jsonl", "p/s.jsonl"),
            (logicalRoot, logicalRoot + "/p/../s.jsonl", "s.jsonl"),
            (logicalRoot, logicalRoot + "//p/s.jsonl", "p/s.jsonl"),
            (logicalRoot, logicalRoot + "/p/%2F.jsonl", "p//.jsonl"),
            ("/offline-client/caf\u{00e9}", "/offline-client/cafe\u{301}/p/s.jsonl", "p/s.jsonl"),
            (logicalRoot, logicalRoot + "/p/s.jsonl", "other/s.jsonl"),
        ] {
            let validLayout = layout.contains("//") ? "p/decoded.jsonl" : layout
            let fixture = try makeFixture(raw: raw, configuredRoot: root, locator: locator, relative: validLayout)
            await assertReplayError(fixture, .quarantined(.invalidReplayLayout))
        }
        let literal = try makeFixture(raw: raw, relative: "p/%2F.jsonl")
        _ = await replaySuccess(literal)
        for leaf in ["sessions", "archived_sessions"] {
            let root = "/offline-client/.codex/" + leaf
            for relative in ["2026/09/s.jsonl", leaf + "/2026/09/s.jsonl"] {
                let fixture = try makeFixture(
                    raw: codexBytes(), source: .codex, format: .codex, configuredRoot: root,
                    locator: root + "/2026/09/s.jsonl", relative: relative
                )
                _ = await replaySuccess(fixture)
            }
            let wrong = try makeFixture(
                raw: codexBytes(), source: .codex, format: .codex, configuredRoot: root,
                locator: root + "/2026/09/s.jsonl", relative: "unrelated/2026/09/s.jsonl"
            )
            await assertReplayError(wrong, .quarantined(.invalidReplayLayout))
        }
    }

    // 10. An explicit existing owner-only staging parent is required; no aliases are repaired.
    func testStagingUsesPrivateOwnedPathsAndRejectsUnsafeParent() async throws {
        let fixture = try makeFixture(raw: claudeBytes(), relative: "p/nested/s.jsonl")
        let stageParent = fixture.stagingParent
        let hooks = CaptureIngestReplayTestHooks(beforeParse: { physical in
            var current = physical
            var metadata = stat()
            XCTAssertEqual(lstat(current.path, &metadata), 0)
            XCTAssertEqual(metadata.st_mode & 0o777, 0o600)
            XCTAssertEqual(metadata.st_nlink, 1)
            XCTAssertEqual(metadata.st_uid, geteuid())
            while current.deletingLastPathComponent().path != stageParent.path {
                current.deleteLastPathComponent()
                XCTAssertEqual(lstat(current.path, &metadata), 0)
                XCTAssertEqual(metadata.st_mode & 0o777, 0o700)
                XCTAssertEqual(metadata.st_mode & S_IFMT, S_IFDIR)
            }
        })
        _ = await replaySuccess(fixture, hooks: hooks)
        try assertEmpty(stageParent)
        XCTAssertEqual(chmod(stageParent.path, 0o755), 0)
        await assertReplayError(fixture, .quarantined(.unsafeStaging))
        XCTAssertEqual(try permissions(stageParent), 0o755, "Do not silently repair caller-owned parents")
        XCTAssertEqual(chmod(stageParent.path, 0o700), 0)
        let alias = directory.appendingPathComponent("stage-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: stageParent)
        await assertReplayError(fixture.withStagingParent(alias), .quarantined(.unsafeStaging))
        let missing = directory.appendingPathComponent("missing-stage")
        await assertReplayError(fixture.withStagingParent(missing), .retryable(.stagingUnavailable))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    // 11. Same-user test races cannot substitute symlinks, hardlinks, modes, or an inode.
    func testStagedFileTamperingBeforeOrAfterParsingIsRejectedAndConfined() async throws {
        for mutation in ["symlink", "hardlink", "mode", "inode", "bytes", "nested-symlink"] {
            for afterParse in [false, true] {
                let fixture = try makeFixture(raw: claudeBytes(), relative: "p/nested/s.jsonl")
                let outside = try writeFixture(Data("outside sentinel".utf8), relative: "outside-\(UUID().uuidString)/s.jsonl")
                let original = try Data(contentsOf: outside)
                let invoked = XCTestExpectation(description: "Staged mutation hook executes once")
                invoked.expectedFulfillmentCount = 1
                invoked.assertForOverFulfill = true
                let change: @Sendable (URL) throws -> Void = { physical in
                    invoked.fulfill()
                    switch mutation {
                    case "mode": XCTAssertEqual(chmod(physical.path, 0o644), 0)
                    case "bytes": try Data("changed".utf8).write(to: physical)
                    case "nested-symlink":
                        let parent = physical.deletingLastPathComponent()
                        try FileManager.default.removeItem(at: parent)
                        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside.deletingLastPathComponent())
                    default:
                        let originalBytes = try Data(contentsOf: physical)
                        try FileManager.default.removeItem(at: physical)
                        if mutation == "symlink" {
                            try FileManager.default.createSymbolicLink(at: physical, withDestinationURL: outside)
                        } else if mutation == "hardlink" {
                            XCTAssertEqual(link(outside.path, physical.path), 0)
                        } else {
                            XCTAssertTrue(FileManager.default.createFile(atPath: physical.path, contents: originalBytes, attributes: [.posixPermissions: 0o600]))
                        }
                    }
                }
                let hooks = CaptureIngestReplayTestHooks(
                    beforeParse: afterParse ? nil : change, afterParse: afterParse ? change : nil
                )
                await assertReplayError(fixture, .quarantined(.unsafeStaging), hooks: hooks)
                await fulfillment(of: [invoked], timeout: 0.1)
                XCTAssertEqual(try Data(contentsOf: outside), original)
                try assertEmpty(fixture.stagingParent)
            }
        }
    }

    // 12. Owned staging is cleaned on success, parser rejection, and cancellation.
    func testCleanupAndCancellationNeverReturnPartialSuccess() async throws {
        let fixture = try makeFixture(raw: claudeBytes())
        _ = await replaySuccess(fixture)
        try assertEmpty(fixture.stagingParent)
        let invalid = try makeFixture(raw: Data("{broken\n".utf8))
        await assertReplayError(invalid, .parseFailed(.malformedJSON))
        try assertEmpty(invalid.stagingParent)
        let cancel: @Sendable (URL) throws -> Void = { _ in throw CancellationError() }
        for after in [false, true] {
            let hooks = CaptureIngestReplayTestHooks(
                beforeParse: after ? nil : cancel,
                afterParse: after ? cancel : nil
            )
            do {
                _ = try await replay(fixture, hooks: hooks)
                XCTFail("Cancellation must propagate")
            } catch is CancellationError {} catch { XCTFail("Expected CancellationError, got \(error)") }
            try assertEmpty(fixture.stagingParent)
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await CaptureIngestReplay.replay(
                publication: fixture.publication, bindingSnapshot: fixture.binding,
                cas: fixture.cas, stagingParent: fixture.stagingParent
            )
        }
        do { _ = try await task.value; XCTFail("Already-cancelled replay must fail") }
        catch is CancellationError {} catch { XCTFail("Expected CancellationError, got \(error)") }
        try assertEmpty(fixture.stagingParent)
    }

    // 13. A missing client file and a different live decoy are equivalent to the CAS replay.
    func testLogicalClientFileIsNeitherReadNorModified() async throws {
        let liveRoot = directory.appendingPathComponent("live-client/projects")
        try privateDirectory(liveRoot)
        let live = liveRoot.appendingPathComponent("p/s.jsonl")
        let fixture = try makeFixture(
            raw: claudeBytes(nativeID: "cas-identity"), configuredRoot: liveRoot.path, relative: "p/s.jsonl"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: live.path))
        guard let absent = await replaySuccess(fixture) else { return }
        try privateDirectory(live.deletingLastPathComponent())
        let decoy = try claudeBytes(nativeID: "must-not-read-live-file")
        XCTAssertTrue(FileManager.default.createFile(atPath: live.path, contents: decoy, attributes: [.posixPermissions: 0o600]))
        let identity = try fileIdentity(live)
        guard let present = await replaySuccess(fixture) else { return }
        XCTAssertEqual(absent.scan.info, present.scan.info)
        XCTAssertEqual(absent.scan.messages, present.scan.messages)
        XCTAssertEqual(present.nativeIdentity.nativeID, "cas-identity")
        XCTAssertEqual(try Data(contentsOf: live), decoy)
        XCTAssertEqual(try fileIdentity(live), identity)
    }

    // 14. Strict records opt in on the existing reader, including reportFailures=false.
    func testStrictRecordsRejectMalformedNonObjectsAndTruncationWithoutChangingLegacy() async throws {
        let valid = try claudeBytes()
        let badLines = ["{truncated", "[]", "null", "17", "\"string\""]
        for bad in badLines {
            for raw in [valid + Data(bad.utf8), Data((bad + "\n").utf8) + valid] {
                let physical = try writeFixture(raw, relative: "strict-\(UUID().uuidString)/s.jsonl")
                for reportFailures in [false, true] {
                    let legacy = try JSONLAdapterSupport.readObjects(locator: physical.path, limits: .default, reportFailures: reportFailures)
                    XCTAssertNil(legacy.1, "Existing default remains permissive")
                    let strict = try JSONLAdapterSupport.readObjects(
                        locator: physical.path, limits: .default, reportFailures: reportFailures, strictRecords: true
                    )
                    XCTAssertEqual(strict.1, .malformedJSON)
                }
                await assertReplayError(try makeFixture(raw: raw), .parseFailed(.malformedJSON))
            }
        }
        let blanks = Data(" \t\r\n\n".utf8) + valid + Data("\n\t \r\n".utf8)
        _ = await replaySuccess(try makeFixture(raw: blanks))
        let invalidUTF8 = valid + Data([0xff, 0x0a])
        await assertReplayError(try makeFixture(raw: invalidUTF8), .parseFailed(.invalidUtf8))
        let physical = try writeFixture(invalidUTF8, relative: "strict-utf8/s.jsonl")
        let strict = try JSONLAdapterSupport.readObjects(
            locator: physical.path, limits: .default, reportFailures: false, strictRecords: true
        )
        XCTAssertEqual(strict.1, .invalidUtf8, "Strict mode also reports existing reader failures")
    }

    // 15. An adapter success containing a failure is still an incomplete replay.
    func testEveryIncompleteAdapterOutcomeIsRejectedWithoutPublishingTier() async throws {
        let baseline = try await legacyScan(raw: claudeBytes(), relative: "p/s.jsonl", codex: false)
        for failure in ParserFailure.allCases {
            var partial = baseline
            partial.parseFailure = failure
            let value = CapturedSourceScan(scan: partial, rawSourceSessionID: partial.info.id)
            XCTAssertThrowsError(try CaptureIngestReplay.requireCompleteScan(.success(value))) { error in
                XCTAssertEqual(error as? CaptureIngestReplayError, .parseFailed(failure))
            }
            XCTAssertThrowsError(try CaptureIngestReplay.requireCompleteScan(.failure(failure))) { error in
                XCTAssertEqual(error as? CaptureIngestReplayError, .parseFailed(failure))
            }
        }
        let complete = try CaptureIngestReplay.requireCompleteScan(.success(CapturedSourceScan(scan: baseline, rawSourceSessionID: baseline.info.id)))
        XCTAssertNil(complete.scan.info.tier)
        XCTAssertEqual(complete.scan.messages, baseline.messages)
    }

    // 16. Both declared source limits and actual CAS allocation bounds precede parsing.
    func testDeclaredSourceAndActualManifestBoundsFailBeforeMissingChunkReads() async throws {
        XCTAssertEqual(SessionAdapterFactory.maximumCapturedSourceBytes, 100 * 1024 * 1024)
        let valid = try makeFixture(raw: claudeBytes())
        let oversized = try alteredManifest(valid) { object in
            let size = SessionAdapterFactory.maximumCapturedJSONLSourceBytes + 1
            object["rawByteCount"] = size
            var generation = object["generation"] as! [String: Any]
            generation["size"] = size
            object["generation"] = generation
            var remaining = size
            var chunks: [[String: Any]] = []
            while remaining > 0 {
                let count = min(remaining, ArchiveSourceManifest.rawChunkSize)
                chunks.append(["ordinal": chunks.count, "rawSHA256": String(repeating: "3", count: 64), "rawByteCount": count])
                remaining -= count
            }
            object["chunks"] = chunks
        }
        await assertReplayError(oversized, .parseFailed(.fileTooLarge))
        try assertEmpty(valid.stagingParent)
        let bytes = Data(repeating: 0x20, count: ArchiveV2ProtocolLimits.maxManifestBytes + 1)
        let actualOversizedManifest = try replacingManifestBytes(valid, bytes)
        await assertReplayError(actualOversizedManifest, .quarantined(.invalidManifest))
        try assertEmpty(valid.stagingParent)
    }

    func testCleanupFailurePreservesPrimaryCancellationAndTerminalRejection() throws {
        let cleanup: () throws -> Void = { throw CocoaError(.fileWriteNoPermission) }
        XCTAssertThrowsError(try CaptureIngestReplay.finishStaging(primaryError: CancellationError(), cleanup: cleanup)) { error in
            XCTAssertTrue(error is CancellationError)
        }
        for primary in [
            CaptureIngestReplayError.parseFailed(.malformedJSON),
            .quarantined(.sourceIntegrityMismatch),
        ] {
            XCTAssertThrowsError(try CaptureIngestReplay.finishStaging(primaryError: primary, cleanup: cleanup)) { error in
                XCTAssertEqual(error as? CaptureIngestReplayError, primary)
            }
        }
        XCTAssertThrowsError(try CaptureIngestReplay.finishStaging(primaryError: nil, cleanup: cleanup)) { error in
            XCTAssertEqual(error as? CaptureIngestReplayError, .retryable(.stagingUnavailable))
        }
        XCTAssertNoThrow(try CaptureIngestReplay.finishStaging(primaryError: nil, cleanup: {}))
    }

    func testGrokFileSetReplayAfterOriginalRemovalPreservesLabeledArchivesWithoutSpeakerRoles_repro() async throws {
        let format = try XCTUnwrap(CaptureIngestParseFormat(rawValue: "grok"))
        let session = "%2FUsers%2Ftest%2Fproject/019dd6e3-91d1-7326-8299-314858773a0e"
        let chat = session + "/chat_history.jsonl"
        let prompt = session + "/prompt_context.json"
        let summary = session + "/summary.json"
        let updates = session + "/updates.jsonl"
        let index = session + "/compaction/INDEX.md"
        let segment = session + "/compaction/segment_000.md"
        let firstBody = "# Turn 1\nolder history GROKREPLAY_unique\n"
        let payloads: [String: Data] = [
            chat: try jsonl([
                ["type": "user", "timestamp": "2026-04-29T01:00:02.000Z",
                 "content": "<user_query>Inspect the Grok parser</user_query>"],
                ["type": "assistant", "timestamp": "2026-04-29T01:00:03.000Z",
                 "content": "I will inspect it.", "model": "grok-4",
                 "usage": ["input_tokens": 10, "output_tokens": 5],
                 "tool_calls": [["name": "read", "arguments": ["path": "/Users/test/project/package.json"]]]],
                ["type": "tool_result", "timestamp": "2026-04-29T01:00:04.000Z",
                 "content": #"{"name":"fixture"}"#],
            ]),
            prompt: try JSONSerialization.data(withJSONObject: ["working_directory": "/Users/test/project"], options: [.sortedKeys]),
            summary: try JSONSerialization.data(withJSONObject: [
                "created_at": "2026-04-29T01:00:00.000Z",
                "updated_at": "2026-04-29T01:00:04.000Z",
                "current_model_id": "grok-4",
                "info": ["id": "019dd6e3-91d1-7326-8299-314858773a0e", "cwd": "/Users/test/project"],
            ], options: [.sortedKeys]),
            index: Data("# Segment\n".utf8),
            segment: Data(firstBody.utf8),
        ]
        let name = "grok-replay-" + UUID().uuidString
        for (path, bytes) in payloads { _ = try writeFixture(bytes, relative: name + "/" + path) }
        let original = directory.appendingPathComponent(name)
        let adapter = GrokAdapter(sessionsRoot: original.path)
        let live = original.appendingPathComponent(chat)
        let native = try await adapter.scanForIndexing(locator: live.path)
        let baseline: IndexingScan
        switch native { case .success(let scan): baseline = scan; case .failure(let error): throw error }
        XCTAssertEqual(baseline.messages.map(\.role), [.user, .assistant, .tool])
        let fixture = try makeFileSetFixture(
            payloads: payloads, primary: chat, format: format, source: .grok,
            configuredRoot: "/offline-client/.grok/sessions",
            canonicalSlots: [chat, updates, summary, prompt, index]
        )
        XCTAssertTrue(ArchiveSourceDescriptor.isGrokFileSet(fixture.manifest))
        try FileManager.default.removeItem(at: original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: live.path))
        guard let value = await replaySuccess(fixture) else { return }
        var expected = baseline.info
        expected.filePath = fixture.manifest.locator
        expected.systemMessageCount = baseline.info.systemMessageCount + 1
        XCTAssertEqual(value.scan.info.source, .grok)
        XCTAssertEqual(value.scan.info.id, "019dd6e3-91d1-7326-8299-314858773a0e")
        XCTAssertEqual(value.scan.info.cwd, "/Users/test/project")
        XCTAssertEqual(value.scan.info.messageCount, baseline.info.messageCount)
        XCTAssertEqual(value.scan.info.systemMessageCount, expected.systemMessageCount)
        XCTAssertEqual(value.scan.messages.map(\.role), [.system, .user, .assistant, .tool])
        XCTAssertEqual(value.scan.messages[0].content, "Grok compaction archive\nsegment_000.md\n\n" + firstBody)
        XCTAssertFalse(value.scan.messages.contains { $0.content.hasPrefix("Turn 1:") || $0.role == .assistant && $0.content.contains("older history") })
        XCTAssertEqual(Array(value.scan.messages.dropFirst()), baseline.messages)
        XCTAssertEqual(value.rawSourceSessionID, "019dd6e3-91d1-7326-8299-314858773a0e")
        try assertEmpty(fixture.stagingParent)

        let single = try makeFixture(raw: payloads[chat]!, source: .grok, format: format,
            configuredRoot: "/offline-client/.grok/sessions", relative: chat)
        await assertReplayError(single, .quarantined(.unsupportedCaptureShape))
    }

    func testGrokCapturedReplayUsesJSONLLimitBeforeCheckingMissingChunks_repro() async throws {
        XCTAssertEqual(SessionAdapterFactory.maximumCapturedSourceBytes, 100 * 1024 * 1024)
        XCTAssertEqual(SessionAdapterFactory.maximumCapturedJSONLSourceBytes, 1024 * 1024 * 1024)
        let format = try XCTUnwrap(CaptureIngestParseFormat(rawValue: "grok"))
        let session = "%2FUsers%2Ftest%2Fproject/019dd6e3-91d1-7326-8299-314858773a0e"
        let chat = session + "/chat_history.jsonl"
        let prompt = session + "/prompt_context.json"
        let summary = session + "/summary.json"
        let updates = session + "/updates.jsonl"
        let index = session + "/compaction/INDEX.md"
        let payloads: [String: Data] = [
            chat: try jsonl([
                ["type": "user", "timestamp": "2026-04-29T01:00:02.000Z",
                 "content": "<user_query>Inspect the Grok parser</user_query>"],
                ["type": "assistant", "timestamp": "2026-04-29T01:00:03.000Z",
                 "content": "I will inspect it.", "model": "grok-4"],
            ]),
            updates: try jsonl([["type": "update", "id": "u1"]]),
            prompt: try JSONSerialization.data(
                withJSONObject: ["working_directory": "/Users/test/project"],
                options: [.sortedKeys]
            ),
            summary: try JSONSerialization.data(withJSONObject: [
                "created_at": "2026-04-29T01:00:00.000Z",
                "updated_at": "2026-04-29T01:00:04.000Z",
                "current_model_id": "grok-4",
                "info": ["id": "019dd6e3-91d1-7326-8299-314858773a0e", "cwd": "/Users/test/project"],
            ], options: [.sortedKeys]),
        ]
        let fixture = try makeFileSetFixture(
            payloads: payloads, primary: chat, format: format, source: .grok,
            configuredRoot: "/offline-client/.grok/sessions",
            canonicalSlots: [chat, updates, summary, prompt, index]
        )
        XCTAssertLessThan(fixture.manifest.rawByteCount, SessionAdapterFactory.maximumCapturedSourceBytes)
        XCTAssertEqual(fixture.manifest.replayLayout.files?.last?.relativePath, updates)
        func inflateLastMember(_ object: inout [String: Any], rawCount: Int64) {
            let previous = (object["rawByteCount"] as? NSNumber)?.int64Value ?? 0
            let extra = rawCount - previous
            object["rawByteCount"] = rawCount
            var layout = object["replayLayout"] as! [String: Any]
            var files = layout["files"] as! [[String: Any]]
            var last = files[files.count - 1]
            XCTAssertEqual(last["relativePath"] as? String, updates)
            let lastSize = (last["rawByteCount"] as? NSNumber)?.int64Value ?? 0
            last["rawByteCount"] = lastSize + extra
            var memberGeneration = last["generation"] as! [String: Any]
            memberGeneration["size"] = lastSize + extra
            last["generation"] = memberGeneration
            files[files.count - 1] = last
            layout["files"] = files
            object["replayLayout"] = layout
            var remaining = rawCount
            var chunks: [[String: Any]] = []
            while remaining > 0 {
                let size = min(remaining, ArchiveSourceManifest.rawChunkSize)
                chunks.append([
                    "ordinal": chunks.count,
                    "rawSHA256": String(repeating: "f", count: 64),
                    "rawByteCount": size,
                ])
                remaining -= size
            }
            object["chunks"] = chunks
        }
        let expanded = try alteredManifest(fixture) { object in
            inflateLastMember(&object, rawCount: SessionAdapterFactory.maximumCapturedSourceBytes + 1)
        }
        // Live Grok 284341056 B is the fileset total (updates.jsonl last).
        // Member ranges still cover rawByteCount; chat/primary generation stays small.
        // After accepting capturedJSONL, the first absent CAS chunk must fail
        // rather than the 100MiB native file cap. No 284MB fixture.
        await assertReplayError(expanded, .retryable(.casUnavailable))
        try assertEmpty(fixture.stagingParent)

        let stillGuarded = try alteredManifest(fixture) { object in
            inflateLastMember(&object, rawCount: SessionAdapterFactory.maximumCapturedJSONLSourceBytes + 1)
        }
        await assertReplayError(stillGuarded, .parseFailed(.fileTooLarge))
        try assertEmpty(stillGuarded.stagingParent)
    }

    func testGeminiFileSetReplayPreservesNativeProjectRootSidecarAndUsage() async throws {
        try await assertGeminiReplay(registryOnly: false, jsonl: false)
    }

    func testGeminiJSONLReplayPreservesMetadataUpdatesAndNativeSidecarIdentity() async throws {
        try await assertGeminiReplay(registryOnly: false, jsonl: true)
    }

    func testGeminiRegistryProjectionReplaysAfterNativeRegistryDisappearsWithoutFakeFiles() async throws {
        try await assertGeminiReplay(registryOnly: true, jsonl: false)
    }

    func testGeminiJSONLFinalSessionIDAfterEightKiBSelectsNativeSidecar() async throws {
        try await assertGeminiReplay(registryOnly: false, jsonl: true, lateIdentity: true)
    }

    func testGeminiReplayRejectsSidecarWitnessForFilenameInsteadOfFinalSessionID() async throws {
        for registryOnly in [false, true] {
            try await assertGeminiReplay(registryOnly: registryOnly, jsonl: false, wrongSidecar: true)
        }
    }

    private func assertGeminiReplay(registryOnly: Bool, jsonl: Bool, wrongSidecar: Bool = false, lateIdentity: Bool = false) async throws {
        let format = try XCTUnwrap(CaptureIngestParseFormat(rawValue: "gemini-cli"))
        let relative = "project/chats/stem." + (jsonl ? "jsonl" : "json")
        let messages: [[String: Any]] = [
            ["id": "m1", "type": "user", "timestamp": "2026-09-08T00:00:01Z", "content": lateIdentity ? String(repeating: "x", count: 9_000) : "gemini question"],
            ["id": "m2", "type": "gemini", "timestamp": "2026-09-08T00:00:02Z", "content": "gemini answer",
             "tokens": ["input": 100, "cached": 4, "output": 7, "thoughts": 2, "tool": 1]],
        ]
        let header: [String: Any] = ["sessionId": lateIdentity ? "old-gemini-id" : "native-gemini", "startTime": "2026-09-08T00:00:00Z",
            "lastUpdated": "2026-09-08T00:00:02Z"]
        let transcript = try jsonl ? self.jsonl([header] + messages + [["$set": ["sessionId": "native-gemini", "lastUpdated": "2026-09-08T00:00:03Z"]]])
            : JSONSerialization.data(withJSONObject: header.merging(["messages": messages]) { _, new in new }, options: [.prettyPrinted, .sortedKeys])
        var payloads = [relative: transcript]
        if !registryOnly {
            payloads["project/.project_root"] = Data("/repo/gemini\n".utf8)
            payloads["project/chats/native-gemini.engram.json"] = Data("{\"originator\":\"claude-code\",\"parentSessionId\":\"native-parent\"}".utf8)
        }
        let name = "native-gemini-" + UUID().uuidString
        for (path, bytes) in payloads { _ = try writeFixture(bytes, relative: name + "/tmp/" + path) }
        let original = directory.appendingPathComponent(name)
        let nativeRoot = original.appendingPathComponent("tmp")
        let registryBytes = try JSONSerialization.data(withJSONObject: ["projects": ["/repo/gemini": "project", "/unrelated-private": "other"]], options: [.sortedKeys])
        let registry = try writeFixture(registryBytes, relative: name + "/projects.json")
        _ = try writeFixture(Data("{\"originator\":\"decoy\",\"parentSessionId\":\"wrong\"}".utf8), relative: name + "/tmp/project/chats/stem.engram.json")
        let native = try await GeminiCliAdapter(tmpRoot: nativeRoot.path, projectsFile: registry.path)
            .scanForIndexing(locator: nativeRoot.appendingPathComponent(relative).path)
        let baseline: IndexingScan
        switch native { case .success(let scan): baseline = scan; case .failure(let error): throw error }
        let context = try registryOnly ? ArchiveGeminiProjectContext(projectName: "project", cwd: "/repo/gemini",
            registryLocator: registry.path, registryGeneration: ArchiveSourceGeneration(device: 1, inode: 9,
                size: Int64(registryBytes.count), mtimeNs: 3, ctimeNs: 4, mode: 0o100600),
            registrySHA256: ArchiveV2Hash.sha256(registryBytes)) : nil
        if wrongSidecar, let sidecar = payloads.removeValue(forKey: "project/chats/native-gemini.engram.json") {
            payloads["project/chats/stem.engram.json"] = sidecar
        }
        let declaredSidecar = wrongSidecar ? "project/chats/stem.engram.json" : "project/chats/native-gemini.engram.json"
        let fixture = try makeFileSetFixture(payloads: payloads, primary: relative, format: format,
            source: .geminiCli, configuredRoot: "/offline-client/.gemini/tmp",
            canonicalSlots: [relative, "project/.project_root", declaredSidecar], context: context)
        try FileManager.default.removeItem(at: original)
        if wrongSidecar {
            await assertReplayError(fixture, .parseFailed(.malformedJSON))
            return
        }
        let value = try await replay(fixture, hooks: .init(beforeParse: { physical in
            if registryOnly {
                XCTAssertFalse(FileManager.default.fileExists(atPath: physical.deletingLastPathComponent()
                    .deletingLastPathComponent().appendingPathComponent(".project_root").path))
            }
        }))
        var expected = baseline.info
        expected.filePath = fixture.manifest.locator
        XCTAssertEqual(value.scan.info, expected)
        XCTAssertEqual(value.scan.messages, baseline.messages)
        XCTAssertEqual(value.rawSourceSessionID, "native-gemini")
        XCTAssertEqual(value.scan.info.cwd, "/repo/gemini")
        XCTAssertEqual(value.scan.info.parentSessionId, registryOnly ? nil : "native-parent")
        XCTAssertEqual(value.scan.info.agentRole, registryOnly ? nil : "dispatched")
        XCTAssertEqual(value.scan.messages.last?.usage?.inputTokens, 96)
        XCTAssertEqual(value.scan.messages.last?.usage?.outputTokens, 10)
        XCTAssertNil(value.scan.parseFailure)
        try assertEmpty(fixture.stagingParent)
    }

    func testCopilotFileSetReplayMatchesNativeEventsWorkspaceAndUsage() async throws {
        try await assertCopilotReplay(checkpoint: false)
    }

    func testCopilotFileSetReplayMatchesNativeCheckpointBodiesWithBareEvents() async throws {
        try await assertCopilotReplay(checkpoint: true)
    }

    func testCopilotReplayRejectsAuxiliaryTamperingBeforeAndAfterParse() async throws {
        let format = try XCTUnwrap(CaptureIngestParseFormat(rawValue: "copilot"))
        for after in [false, true] {
            let fixture = try makeCopilotFixture(payloads: copilotPayloads(checkpoint: false),
                primary: "s1/events.jsonl", format: format)
            let mutate: @Sendable (URL) throws -> Void = { primary in
                try Data("id: forged\ncwd: /elsewhere\n".utf8)
                    .write(to: primary.deletingLastPathComponent().appendingPathComponent("workspace.yaml"))
            }
            await assertReplayError(fixture, .quarantined(.unsafeStaging), hooks: .init(
                beforeParse: after ? nil : mutate, afterParse: after ? mutate : nil))
            try assertEmpty(fixture.stagingParent)
        }
    }

    func testCopilotReplayRejectsWrongMemberHashDespiteCorrectAggregateHash() async throws {
        let format = try XCTUnwrap(CaptureIngestParseFormat(rawValue: "copilot"))
        let fixture = try makeCopilotFixture(payloads: copilotPayloads(checkpoint: false),
            primary: "s1/events.jsonl", format: format)
        let wrong = try alteredManifest(fixture) { object in
            var layout = object["replayLayout"] as! [String: Any]
            var files = layout["files"] as! [[String: Any]]
            files[1]["wholeSourceSHA256"] = String(repeating: "b", count: 64)
            layout["files"] = files
            object["replayLayout"] = layout
        }
        await assertReplayError(wrong, .quarantined(.sourceIntegrityMismatch))
        try assertEmpty(fixture.stagingParent)
    }

    func testCopilotReplayFencesUnexpectedFilesAndPreservesCrossChunkCheckpointBody() async throws {
        let format = try XCTUnwrap(CaptureIngestParseFormat(rawValue: "copilot"))
        var payloads = try copilotPayloads(checkpoint: true)
        payloads["s1/checkpoints/001-body.md"] = Data(repeating: 0x41, count: Int(ArchiveSourceManifest.rawChunkSize) + 7)
        let fixture = try makeCopilotFixture(payloads: payloads, primary: "s1/checkpoints/index.md", format: format)
        XCTAssertEqual(fixture.manifest.chunks.count, 2)
        let result = try await replay(fixture)
        XCTAssertFalse(result.scan.messages.isEmpty)
        XCTAssertEqual(result.scan.info.sizeBytes, fixture.manifest.rawByteCount)
        await assertReplayError(fixture, .quarantined(.unsafeStaging), hooks: .init(beforeParse: { primary in
            try Data("unexpected body".utf8).write(to: primary.deletingLastPathComponent().appendingPathComponent("999-extra.md"))
        }))
        try assertEmpty(fixture.stagingParent)
    }

    func testCopilotCapturedLongLineExceedsNativeDefault_repro() async throws {
        let format = try XCTUnwrap(CaptureIngestParseFormat(rawValue: "copilot"))
        var payloads = try copilotPayloads(checkpoint: false)
        let text = String(repeating: "x", count: 8 * 1024 * 1024 + 1)
        var event = try JSONSerialization.data(withJSONObject: [
            "type": "assistant.message", "timestamp": "2026-09-08T00:00:03Z",
            "data": ["content": text],
        ], options: [.sortedKeys])
        event.append(10)
        payloads["s1/events.jsonl", default: Data()].append(event)
        let fixture = try makeCopilotFixture(payloads: payloads, primary: "s1/events.jsonl", format: format)
        let value = try await replay(fixture)
        XCTAssertEqual(value.rawSourceSessionID, "native-copilot")
        XCTAssertEqual(value.scan.messages.last?.content, text)
        XCTAssertNil(value.scan.parseFailure)
        try assertEmpty(fixture.stagingParent)
    }

    private func assertCopilotReplay(checkpoint: Bool) async throws {
        let format = try XCTUnwrap(CaptureIngestParseFormat(rawValue: "copilot"))
        let payloads = try copilotPayloads(checkpoint: checkpoint)
        let primary = checkpoint ? "s1/checkpoints/index.md" : "s1/events.jsonl"
        let nativeRoot = "native-copilot-" + UUID().uuidString
        for (path, bytes) in payloads { _ = try writeFixture(bytes, relative: nativeRoot + "/" + path) }
        let localRoot = directory.appendingPathComponent(nativeRoot)
        let native = try await CopilotAdapter(sessionRoot: localRoot.path)
            .scanForIndexing(locator: localRoot.appendingPathComponent(primary).path)
        let baseline: IndexingScan
        switch native {
        case .success(let scan): baseline = scan
        case .failure(let error): throw error
        }
        let fixture = try makeCopilotFixture(payloads: payloads, primary: primary, format: format)
        // Replay must stand alone after the original native tree disappears.
        try FileManager.default.removeItem(at: localRoot)
        let value = try await replay(fixture)
        var expected = baseline.info
        expected.filePath = fixture.manifest.locator
        XCTAssertEqual(value.scan.info, expected)
        XCTAssertEqual(value.scan.messages, baseline.messages)
        XCTAssertEqual(value.scan.info.id, "native-copilot")
        XCTAssertEqual(value.scan.info.cwd, "/repo/copilot")
        XCTAssertEqual(value.scan.info.source, .copilot)
        XCTAssertEqual(value.rawSourceSessionID, "native-copilot")
        if !checkpoint {
            let usage = try XCTUnwrap(value.scan.messages.last?.usage)
            XCTAssertEqual(usage.inputTokens, 111)
            XCTAssertEqual(usage.outputTokens, 23)
            XCTAssertEqual(usage.cacheReadTokens, 7)
            XCTAssertEqual(usage.cacheCreationTokens, 3)
        }
        XCTAssertFalse(value.scan.messages.isEmpty)
        XCTAssertNil(value.scan.parseFailure)
        try assertEmpty(fixture.stagingParent)
    }

    private func copilotPayloads(checkpoint: Bool) throws -> [String: Data] {
        var records: [[String: Any]] = [["type": "session.start", "timestamp": "2026-09-08T00:00:00Z",
            "data": ["context": ["cwd": "/repo/copilot"]]]]
        if !checkpoint {
            records += [["type": "user.message", "timestamp": "2026-09-08T00:00:01Z", "data": ["content": "question"]],
                ["type": "assistant.message", "timestamp": "2026-09-08T00:00:02Z", "data": ["content": "answer"]],
                ["type": "session.shutdown", "data": ["modelMetrics": ["native-model": ["usage":
                    ["inputTokens": 111, "outputTokens": 23, "cacheReadTokens": 7, "cacheWriteTokens": 3]]]]]]
        }
        var payloads = ["s1/events.jsonl": try jsonl(records),
            "s1/workspace.yaml": Data("id: native-copilot\ncwd: /repo/copilot\ncreated_at: 2026-09-08T00:00:00Z\nsummary: native summary\n".utf8)]
        if checkpoint {
            payloads["s1/checkpoints/index.md"] = Data("| 1 | Checkpoint title | 001-body.md |\n".utf8)
            payloads["s1/checkpoints/001-body.md"] = Data("# Captured checkpoint\n\nExact checkpoint body.\n".utf8)
        }
        return payloads
    }

    private func makeCopilotFixture(payloads: [String: Data], primary: String,
                                    format: CaptureIngestParseFormat) throws -> Fixture {
        try makeFileSetFixture(payloads: payloads, primary: primary, format: format, source: .copilot,
            configuredRoot: "/offline-client/.copilot/session-state",
            canonicalSlots: ["s1/events.jsonl", "s1/workspace.yaml", "s1/checkpoints/index.md"])
    }

    private func makeFileSetFixture(payloads: [String: Data], primary: String, format: CaptureIngestParseFormat,
                                    source: SourceName, configuredRoot: String, canonicalSlots: [String],
                                    context: ArchiveGeminiProjectContext? = nil,
                                    vscodeContext: ArchiveVSCodeWorkspaceContext? = nil) throws -> Fixture {
        let paths = payloads.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        var combined = Data()
        var entries: [ArchiveFileSetEntry] = []
        for path in paths {
            let bytes = payloads[path]!
            let generation = try ArchiveSourceGeneration(device: 1, inode: Int64(entries.count + 2),
                size: Int64(bytes.count), mtimeNs: 3, ctimeNs: 4, mode: 0o100600)
            entries.append(try ArchiveFileSetEntry(relativePath: path, byteOffset: Int64(combined.count),
                rawByteCount: Int64(bytes.count), wholeSourceSHA256: ArchiveV2Hash.sha256(bytes), generation: generation))
            combined.append(bytes)
        }
        let fixture = try makeFixture(raw: combined, source: source, format: format,
            configuredRoot: configuredRoot, relative: primary)
        let absent = canonicalSlots.filter { payloads[$0] == nil }.sorted()
        let layout = try ArchiveReplayLayout(strategy: .fileSet, relativePaths: paths,
            entrypointRelativePath: primary, files: entries, absentRelativePaths: absent, vscodeWorkspaceContext: vscodeContext, geminiProjectContext: context)
        let old = fixture.manifest
        let manifest = try ArchiveSourceManifest(schemaVersion: vscodeContext != nil ? 7 : (context == nil ? 2 : 3), captureID: old.captureID, machineID: old.machineID,
            source: old.source, locator: old.locator, sessionID: nil, capturedAt: old.capturedAt,
            generation: XCTUnwrap(entries.first { $0.relativePath == primary }).generation,
            wholeSourceSHA256: old.wholeSourceSHA256, rawByteCount: old.rawByteCount, chunks: old.chunks, replayLayout: layout)
        let replaced = try replacingManifestBytes(fixture, ArchiveCanonicalJSON.encode(manifest))
        return Fixture(cas: fixture.cas, casRoot: fixture.casRoot, stagingParent: fixture.stagingParent,
            manifest: manifest, publication: replaced.publication, binding: fixture.binding)
    }

    private struct Fixture: Sendable {
        let cas: ImmutableArchiveCAS
        let casRoot: URL
        let stagingParent: URL
        let manifest: ArchiveSourceManifest
        let publication: CollectorPublicationEnvelope
        let binding: CaptureIngestSourceBinding

        func withBinding(_ value: CaptureIngestSourceBinding) -> Self {
            Self(cas: cas, casRoot: casRoot, stagingParent: stagingParent, manifest: manifest, publication: publication, binding: value)
        }

        func withStagingParent(_ value: URL) -> Self {
            Self(cas: cas, casRoot: casRoot, stagingParent: value, manifest: manifest, publication: publication, binding: binding)
        }
    }

    private func makeFixture(
        raw: Data, source: SourceName = .claudeCode, format: CaptureIngestParseFormat = .claudeDefault,
        configuredRoot: String? = nil, locator: String? = nil, relative: String = "project/session.jsonl",
        parentName: String = "stage", sourceInstance: String? = nil, manifestMachine: String? = nil,
        publishObjects: Bool = true, fileSetAbsent: [String]? = nil
    ) throws -> Fixture {
        let fixtureRoot = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try privateDirectory(fixtureRoot)
        let casRoot = fixtureRoot.appendingPathComponent("cas", isDirectory: true)
        let cas = try ImmutableArchiveCAS(root: casRoot)
        let staging = fixtureRoot.appendingPathComponent(parentName, isDirectory: true)
        try privateDirectory(staging)
        let root = configuredRoot ?? logicalRoot
        let hash = ArchiveV2Hash.sha256(raw)
        var chunks: [ArchiveChunkReference] = []
        var offset = 0
        while offset < raw.count {
            let end = min(raw.count, offset + Int(ArchiveSourceManifest.rawChunkSize))
            let bytes = Data(raw[offset..<end])
            let digest = ArchiveV2Hash.sha256(bytes)
            chunks.append(try ArchiveChunkReference(ordinal: chunks.count, rawSHA256: digest, rawByteCount: Int64(bytes.count)))
            if publishObjects { _ = try cas.publishObject(raw: bytes, expectedSHA256: digest) }
            offset = end
        }
        let generation = try ArchiveSourceGeneration(device: 1, inode: 2, size: Int64(raw.count), mtimeNs: 3, ctimeNs: 4, mode: 0o100600)
        let layout: ArchiveReplayLayout
        if let fileSetAbsent {
            layout = try ArchiveReplayLayout(strategy: .fileSet, relativePaths: [relative],
                entrypointRelativePath: relative,
                files: [ArchiveFileSetEntry(relativePath: relative, byteOffset: 0, rawByteCount: Int64(raw.count),
                    wholeSourceSHA256: hash, generation: generation)], absentRelativePaths: fileSetAbsent)
        } else { layout = try ArchiveReplayLayout(strategy: .singleFile, relativePaths: [relative]) }
        let manifest = try ArchiveSourceManifest(schemaVersion: fileSetAbsent == nil ? 1 : 2,
            captureID: ArchiveV2Hash.sha256(Data(UUID().uuidString.utf8)), machineID: manifestMachine ?? machine,
            source: source.rawValue, locator: locator ?? root + "/" + relative, sessionID: nil,
            capturedAt: "2026-09-06T00:00:00Z",
            generation: generation,
            wholeSourceSHA256: hash, rawByteCount: Int64(raw.count), chunks: chunks,
            replayLayout: layout
        )
        let manifestBytes = try ArchiveCanonicalJSON.encode(manifest)
        let manifestSHA = ArchiveV2Hash.sha256(manifestBytes)
        _ = try cas.publishManifest(manifestBytes, expectedSHA256: manifestSHA)
        let publication = try CollectorPublicationEnvelope(
            machineID: machine, sourceInstanceID: sourceInstance ?? instance, collectorEpoch: epoch,
            sequence: 1, manifestSHA256: manifestSHA
        )
        return Fixture(
            cas: cas, casRoot: casRoot, stagingParent: staging, manifest: manifest, publication: publication,
            binding: binding(root: root, source: source, format: format, sourceInstance: sourceInstance)
        )
    }

    private func binding(
        root: String, source: SourceName = .claudeCode, format: CaptureIngestParseFormat = .claudeDefault,
        sourceInstance: String? = nil, approvedEpoch: String? = nil, generation: Int64 = 7
    ) -> CaptureIngestSourceBinding {
        CaptureIngestSourceBinding(
            machineID: machine, sourceInstanceID: sourceInstance ?? instance, source: source, parseFormat: format,
            configuredRoot: root, approvedEpoch: approvedEpoch ?? epoch, authorityGeneration: generation
        )
    }

    private func replacingPublication(_ fixture: Fixture, manifestSHA: String) throws -> Fixture {
        let original = fixture.publication
        let publication = try CollectorPublicationEnvelope(
            machineID: original.machineID, sourceInstanceID: original.sourceInstanceID,
            collectorEpoch: original.collectorEpoch, sequence: original.sequence, manifestSHA256: manifestSHA
        )
        return Fixture(cas: fixture.cas, casRoot: fixture.casRoot, stagingParent: fixture.stagingParent,
                       manifest: fixture.manifest, publication: publication, binding: fixture.binding)
    }

    private func replacingManifestBytes(_ fixture: Fixture, _ bytes: Data) throws -> Fixture {
        let hash = ArchiveV2Hash.sha256(bytes)
        _ = try fixture.cas.publishManifest(bytes, expectedSHA256: hash)
        return try replacingPublication(fixture, manifestSHA: hash)
    }

    private func alteredManifest(_ fixture: Fixture, edit: (inout [String: Any]) -> Void) throws -> Fixture {
        var object = try JSONSerialization.jsonObject(with: ArchiveCanonicalJSON.encode(fixture.manifest)) as! [String: Any]
        edit(&object)
        let raw = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        let bytes: Data
        if let manifest = try? JSONDecoder().decode(ArchiveSourceManifest.self, from: raw) {
            bytes = try ArchiveCanonicalJSON.encode(manifest)
        } else {
            bytes = raw
        }
        return try replacingManifestBytes(fixture, bytes)
    }

    private func replay(_ fixture: Fixture, hooks: CaptureIngestReplayTestHooks = .init()) async throws -> CaptureIngestReplayResult {
        try await CaptureIngestReplay.replay(
            publication: fixture.publication, bindingSnapshot: fixture.binding, cas: fixture.cas,
            stagingParent: fixture.stagingParent, testHooks: hooks
        )
    }

    private func replaySuccess(
        _ fixture: Fixture, hooks: CaptureIngestReplayTestHooks = .init(), file: StaticString = #filePath, line: UInt = #line
    ) async -> CaptureIngestReplayResult? {
        do { return try await replay(fixture, hooks: hooks) }
        catch { XCTFail("Expected complete CAS-only replay, got \(error)", file: file, line: line); return nil }
    }

    private func assertReplayError(
        _ fixture: Fixture, _ expected: CaptureIngestReplayError, hooks: CaptureIngestReplayTestHooks = .init(),
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do { _ = try await replay(fixture, hooks: hooks); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? CaptureIngestReplayError, expected, file: file, line: line) }
    }

    private func privateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    private func writeFixture(_ raw: Data, relative: String) throws -> URL {
        let url = directory.appendingPathComponent(relative)
        try privateDirectory(url.deletingLastPathComponent())
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: raw, attributes: [.posixPermissions: 0o600]))
        return url
    }

    private func legacyScan(raw: Data, relative: String, codex: Bool) async throws -> IndexingScan {
        let root = directory.appendingPathComponent("legacy-\(UUID().uuidString)")
        try privateDirectory(root)
        let file = root.appendingPathComponent(relative)
        try privateDirectory(file.deletingLastPathComponent())
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: raw, attributes: [.posixPermissions: 0o600]))
        let result = codex
            ? try await CodexAdapter(sessionsRoot: root.path).scanForIndexing(locator: file.path)
            : try await ClaudeCodeAdapter(projectsRoot: root.path).scanForIndexing(locator: file.path)
        switch result {
        case .success(let value): return value
        case .failure(let failure): throw failure
        }
    }

    private func assertParity(_ scan: IndexingScan, baseline: IndexingScan, logicalLocator: String, file: StaticString = #filePath, line: UInt = #line) {
        var expected = baseline.info
        expected.filePath = logicalLocator
        XCTAssertEqual(scan.info, expected, file: file, line: line)
        XCTAssertEqual(scan.messages, baseline.messages, file: file, line: line)
        XCTAssertEqual(scan.unknownRecordKinds, baseline.unknownRecordKinds, file: file, line: line)
        XCTAssertNil(scan.parseFailure, file: file, line: line)
        XCTAssertEqual(scan.checkpointParsedOffset, baseline.checkpointParsedOffset, file: file, line: line)
        XCTAssertEqual(scan.checkpointBoundaryHash, baseline.checkpointBoundaryHash, file: file, line: line)
        XCTAssertEqual(tier(scan.info), tier(expected), file: file, line: line)
    }

    private func tier(_ info: NormalizedSessionInfo) -> SessionTier {
        SessionTier.compute(TierInput(
            messageCount: info.messageCount, agentRole: info.agentRole, filePath: info.filePath,
            project: info.project, summary: info.summary, startTime: info.startTime, endTime: info.endTime,
            source: info.source.rawValue, assistantCount: info.assistantMessageCount, toolCount: info.toolMessageCount
        ))
    }

    private func assertEmpty(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.path), [], file: file, line: line)
    }

    private func permissions(_ url: URL) throws -> mode_t {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw CocoaError(.fileReadUnknown) }
        return value.st_mode & 0o777
    }

    private func fileIdentity(_ url: URL) throws -> [UInt64] {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw CocoaError(.fileReadUnknown) }
        return [UInt64(value.st_dev), UInt64(value.st_ino), UInt64(value.st_size), UInt64(value.st_mtimespec.tv_sec), UInt64(value.st_mtimespec.tv_nsec)]
    }

    private func objectURL(_ fixture: Fixture, _ digest: String) -> URL {
        fixture.casRoot.appendingPathComponent("objects/sha256/\(digest.prefix(2))/\(digest)")
    }

    private func jsonl(_ objects: [[String: Any]]) throws -> Data {
        var result = Data()
        for object in objects {
            result.append(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            result.append(0x0a)
        }
        return result
    }

    private func claudeBytes(nativeID: String = "native-session", model: String = "claude-test") throws -> Data {
        let common: [String: Any] = ["sessionId": nativeID, "cwd": "/repo/project", "timestamp": "2026-09-06T00:00:00Z"]
        func record(_ type: String, _ message: [String: Any]) -> [String: Any] {
            common.merging(["type": type, "message": message]) { _, new in new }
        }
        return try jsonl([
            record("user", ["content": "Implement a useful feature"]),
            record("assistant", ["id": "usage-once", "model": model, "content": [["type": "text", "text": "Working"]],
                                 "usage": ["input_tokens": 7, "output_tokens": 3, "cache_read_input_tokens": 2]]),
            record("assistant", ["id": "usage-once", "model": model, "content": [["type": "tool_use", "id": "t1", "name": "read", "input": ["path": "a"]]],
                                 "usage": ["input_tokens": 7, "output_tokens": 3]]),
            record("user", ["content": [["type": "tool_result", "tool_use_id": "t1", "content": "tool output"]]]),
            record("user", ["content": "<system-reminder>context</system-reminder>"]),
            ["type": "future-lifecycle", "sessionId": nativeID],
        ])
    }

    private func codexBytes(originator: String = "codex-cli") throws -> Data {
        let timestamp = "2026-09-06T00:00:00Z"
        return try jsonl([
            ["type": "session_meta", "timestamp": timestamp,
             "payload": ["id": "codex-native", "cwd": "/repo/project", "timestamp": timestamp, "originator": originator]],
            ["type": "session_meta", "payload": ["id": "later-ignored", "cwd": "/repo/later", "timestamp": timestamp]],
            ["type": "turn_context", "payload": ["model": "gpt-test"]],
            ["type": "response_item", "timestamp": timestamp,
             "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Implement a useful feature"]]]],
            ["type": "response_item", "timestamp": timestamp,
             "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Working"]]]],
            ["type": "response_item", "timestamp": timestamp,
             "payload": ["type": "function_call", "name": "read", "arguments": "{\"path\":\"a\"}", "call_id": "t1"]],
            ["type": "response_item", "timestamp": timestamp,
             "payload": ["type": "function_call_output", "output": "tool output", "call_id": "t1"]],
        ])
    }
}
