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

    // 4. Logical derived-source detection is preserved; the active source gate is not widened.
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
        for edit: ([String: Any]) -> [String: Any] in [
            { var value = $0; value["sessionID"] = "normalized-export"; return value },
            { var value = $0; value["source"] = "minimax"; return value },
        ] {
            let candidate = try alteredManifest(valid) { $0 = edit($0) }
            await assertReplayError(candidate, .quarantined(.unsupportedCaptureShape))
        }
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
            let size = SessionAdapterFactory.maximumCapturedSourceBytes + 1
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
        publishObjects: Bool = true
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
        let manifest = try ArchiveSourceManifest(
            captureID: ArchiveV2Hash.sha256(Data(UUID().uuidString.utf8)), machineID: manifestMachine ?? machine,
            source: source.rawValue, locator: locator ?? root + "/" + relative, sessionID: nil,
            capturedAt: "2026-09-06T00:00:00Z",
            generation: ArchiveSourceGeneration(device: 1, inode: 2, size: Int64(raw.count), mtimeNs: 3, ctimeNs: 4, mode: 0o100600),
            wholeSourceSHA256: hash, rawByteCount: Int64(raw.count), chunks: chunks,
            replayLayout: ArchiveReplayLayout(strategy: .singleFile, relativePaths: [relative])
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
