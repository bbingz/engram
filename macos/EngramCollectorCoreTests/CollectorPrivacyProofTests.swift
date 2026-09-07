import Darwin
import Foundation
import XCTest
@testable import EngramCollectorCore

final class CollectorPrivacyProofTests: XCTestCase {
    private let machineID = "11111111-2222-3333-4444-555555555555"
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("engram-collector-privacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        root = root.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }

    func testCompleteClaudeAndCodexCapturedGenerationsProduceBoundProofs() throws {
        for format in [SourceMetadataProjection.Format.claudeCode(forceClaudeCodeSource: false), .codex] {
            let source: SourceName = format == .codex ? .codex : .claudeCode
            let bytes = try transcript(format: format, cwd: "/allowed")
            let fixture = try capture(bytes, source: source)
            let policy = try policy()
            let proof = try eligible(assess(fixture, format: format, policy: policy))
            XCTAssertEqual(proof.manifestSHA256, fixture.result.capture.unboundManifestSHA256)
            XCTAssertEqual(proof.wholeSourceSHA256, ArchiveV2Hash.sha256(bytes))
            XCTAssertEqual(proof.generation, fixture.result.manifest.generation)
            XCTAssertEqual(proof.nativeSessionID, "native")
            XCTAssertEqual(proof.projectRoot, "/allowed")
            XCTAssertEqual(proof.source, source)
            XCTAssertEqual(proof.policyRevision, policy.revision)
            XCTAssertEqual(proof.policySHA256, try policy.sha256())
            XCTAssertTrue(proof.isCurrent(for: fixture.result, policy: policy, format: format))
            XCTAssertNil(fixture.result.manifest.sessionID)
        }
    }

    func testProofReadsCapturedCASGenerationAndDoesNotReopenChangedOrMissingSource() throws {
        let fixture = try capture(transcript(format: .codex, cwd: "/allowed"), source: .codex)
        try transcript(format: .codex, cwd: "/excluded").write(to: fixture.sourceURL)
        let policy = try policy(excluded: ["/excluded"])
        let proof = try eligible(assess(fixture, format: .codex, policy: policy))
        XCTAssertEqual(proof.projectRoot, "/allowed")
        try FileManager.default.removeItem(at: fixture.sourceURL)
        XCTAssertEqual(try eligible(assess(fixture, format: .codex, policy: policy)), proof)
    }

    func testDefaultClaudeAllowsMultipleSafeRecognizedCwdRoots() throws {
        let format = SourceMetadataProjection.Format.claudeCode(forceClaudeCodeSource: false)
        let first = try transcript(format: format, cwd: "/allowed")
        let bytes = first + (try transcript(format: format, cwd: "/other"))
        let fixture = try capture(bytes, source: .claudeCode)
        let policy = try policy()
        let proof = try eligible(assess(fixture, format: format, policy: policy))
        XCTAssertEqual(proof.projectRoot, "/allowed")
        XCTAssertEqual(proof.nativeSessionID, "native")
        XCTAssertEqual(proof.wholeSourceSHA256, ArchiveV2Hash.sha256(bytes))
        XCTAssertTrue(proof.isCurrent(for: fixture.result, policy: policy, format: format))
    }

    func testDefaultClaudeWithholdsExcludedLaterRootInsteadOfConflict() throws {
        let format = SourceMetadataProjection.Format.claudeCode(forceClaudeCodeSource: false)
        let bytes = try transcript(format: format, cwd: "/allowed")
            + transcript(format: format, cwd: "/excluded/child")
        let fixture = try capture(bytes, source: .claudeCode)
        let policy = try policy(excluded: ["/excluded"])
        XCTAssertEqual(try assess(fixture, format: format, policy: policy), .withheld(.excludedProject))
    }

    func testCodexLaterCwdAndAllNativeIdentityConflictsAreWithheld() throws {
        for format in [SourceMetadataProjection.Format.claudeCode(forceClaudeCodeSource: false), .codex] {
            let source: SourceName = format == .codex ? .codex : .claudeCode
            let first = try transcript(format: format, cwd: "/allowed")
            let changedRoot = try capture(first + transcript(format: format, cwd: "/excluded"), source: source)
            if format == .codex {
                XCTAssertEqual(try assess(changedRoot, format: format), .withheld(.conflictingProjectRoots))
            } else {
                XCTAssertEqual(try eligible(assess(changedRoot, format: format)).projectRoot, "/allowed")
            }
            let changedID = try capture(first + transcript(format: format, cwd: "/allowed", id: "other"), source: source)
            XCTAssertEqual(try assess(changedID, format: format), .withheld(.conflictingSourceIdentity))
        }
    }

    func testLaterClaudeModelSourceConflictAndMixedSourceFormatAreWithheld() throws {
        let first = try transcript(format: .claudeCode(forceClaudeCodeSource: false), cwd: "/allowed")
        let changed = try capture(first + transcript(format: .claudeCode(forceClaudeCodeSource: false), cwd: "/allowed", model: "MiniMax-M2.1"), source: .claudeCode)
        XCTAssertEqual(try assess(changed), .withheld(.conflictingSourceIdentity))
        let mixed = try capture(first + transcript(format: .codex, cwd: "/allowed"), source: .claudeCode)
        XCTAssertEqual(try assess(mixed), .withheld(.conflictingSourceIdentity))
    }

    func testCanonicallyEquivalentButByteDistinctNativeIdentitiesAreConflicts() throws {
        let composed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        XCTAssertEqual(composed, decomposed)
        XCTAssertNotEqual(Array(composed.utf8), Array(decomposed.utf8))
        for format in [SourceMetadataProjection.Format.claudeCode(forceClaudeCodeSource: false), .codex] {
            let source: SourceName = format == .codex ? .codex : .claudeCode
            let bytes = try transcript(format: format, cwd: "/allowed", id: composed)
                + transcript(format: format, cwd: "/allowed", id: decomposed)
            XCTAssertEqual(try assess(capture(bytes, source: source), format: format), .withheld(.conflictingSourceIdentity))
        }
    }

    func testDerivedSourceRequiresOptInAndNonDefaultClaudeProfileRetainsForcedSource() throws {
        let bytes = try transcript(format: .claudeCode(forceClaudeCodeSource: false), cwd: "/allowed", model: "MiniMax-M2.1")
        let derived = try capture(bytes, source: .minimax)
        XCTAssertEqual(try assess(derived), .withheld(.unsupportedSource))
        let enabled = try policy(sources: [.claudeCode, .codex, .minimax])
        XCTAssertEqual(try eligible(assess(derived, policy: enabled)).source, .minimax)
        let forced = try capture(bytes, source: .claudeCode)
        XCTAssertEqual(try eligible(assess(forced, format: .claudeCode(forceClaudeCodeSource: true))).source, .claudeCode)
        XCTAssertEqual(try assess(forced), .withheld(.conflictingSourceIdentity))
    }

    func testProfileResolutionFormatMustStillMatchBeforeUpload() throws {
        let forced = SourceMetadataProjection.Format.claudeCode(forceClaudeCodeSource: true)
        let defaultProfile = SourceMetadataProjection.Format.claudeCode(forceClaudeCodeSource: false)
        let bytes = try transcript(format: forced, cwd: "/allowed", model: "MiniMax-M2.1")
        let fixture = try capture(bytes, source: .claudeCode)
        let policy = try policy()
        let proof = try eligible(assess(fixture, format: forced, policy: policy))
        XCTAssertTrue(proof.isCurrent(for: fixture.result, policy: policy, format: forced))
        XCTAssertFalse(proof.isCurrent(for: fixture.result, policy: policy, format: defaultProfile))
        XCTAssertFalse(proof.isCurrent(for: fixture.result, policy: policy, format: .codex))
        XCTAssertEqual(try assess(fixture, format: defaultProfile, policy: policy), .withheld(.conflictingSourceIdentity))
    }

    func testMissingInvalidTruncatedAndMalformedEvidenceCannotAuthorizeUpload() throws {
        let valid = try transcript(format: .codex, cwd: "/allowed")
        let cases: [(Data, CollectorPrivacyWithheldReason)] = [
            (try transcript(format: .codex, cwd: nil), .invalidProjectRoot),
            (try transcript(format: .codex, cwd: "/allowed", id: nil), .missingNativeIdentity),
            (try transcript(format: .codex, cwd: "relative"), .invalidProjectRoot),
            (valid + Data("{\"type\":".utf8), .incompleteMetadata),
            (valid + Data("not-json\n".utf8), .malformedMetadata),
            (valid + Data([0xFF, 0x0A]), .malformedMetadata),
            (Data(valid.dropLast()), .incompleteMetadata),
        ]
        for (bytes, expected) in cases {
            XCTAssertEqual(try assess(capture(bytes, source: .codex), format: .codex), .withheld(expected))
        }
    }

    func testExcludedRootUsesComponentBoundaryAndRejectsSymlinkOrTraversalRoots() throws {
        let policy = try policy(excluded: ["/private/project"])
        for path in ["/private/project", "/private/project/child"] {
            XCTAssertEqual(try assess(capture(transcript(format: .codex, cwd: path), source: .codex), format: .codex, policy: policy), .withheld(.excludedProject))
        }
        XCTAssertEqual(try eligible(assess(capture(transcript(format: .codex, cwd: "/private/project-other"), source: .codex), format: .codex, policy: policy)).projectRoot, "/private/project-other")
        let destination = root.appendingPathComponent("excluded-project")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let linked = root.appendingPathComponent("linked-project")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: destination)
        XCTAssertThrowsError(try self.policy(excluded: [linked.path]))
        for unsafe in [linked.path, destination.path + "/../allowed", "/"] {
            XCTAssertEqual(try assess(capture(transcript(format: .codex, cwd: unsafe), source: .codex), format: .codex), .withheld(.invalidProjectRoot))
        }
    }

    func testSourceRecordAndLineBudgetsWithholdInsteadOfAcceptingPrefixProof() throws {
        let bytes = try transcript(format: .codex, cwd: "/allowed")
        let fixture = try capture(bytes, source: .codex)
        let cases = [
            CollectorPrivacyLimits(maxSourceBytes: Int64(bytes.count - 1)),
            CollectorPrivacyLimits(maxLineBytes: 12),
            CollectorPrivacyLimits(maxRecords: 1),
        ]
        for limits in cases {
            XCTAssertEqual(try assess(fixture, format: .codex, limits: limits), .withheld(.limitsExceeded))
        }
        XCTAssertNotNil(try eligible(assess(fixture, format: .codex, limits: CollectorPrivacyLimits(maxSourceBytes: Int64(bytes.count), maxRecords: 2))))
    }

    func testPolicyRevisionDigestAndCaptureBindingsMustStillMatchBeforeUpload() throws {
        let fixture = try capture(transcript(format: .codex, cwd: "/allowed"), source: .codex)
        let originalPolicy = try policy()
        let proof = try eligible(assess(fixture, format: .codex, policy: originalPolicy))
        XCTAssertFalse(proof.isCurrent(for: fixture.result, policy: try policy(revision: 2), format: .codex))
        XCTAssertFalse(proof.isCurrent(for: fixture.result, policy: try policy(excluded: ["/allowed"]), format: .codex))
        let another = try capture(transcript(format: .codex, cwd: "/other"), source: .codex)
        XCTAssertFalse(proof.isCurrent(for: another.result, policy: originalPolicy, format: .codex))
        let mismatched = ArchiveCaptureResult(capture: fixture.result.capture, manifest: another.result.manifest)
        XCTAssertEqual(try CollectorPrivacyProof.assess(capture: mismatched, cas: fixture.cas, format: .codex, policy: originalPolicy), .withheld(.invalidCapture))
        XCTAssertEqual(try policy(excluded: ["/b", "/a"]).sha256(), try policy(excluded: ["/a", "/b"]).sha256())
        XCTAssertThrowsError(try policy(revision: 0))
        XCTAssertThrowsError(try policy(excluded: ["relative"]))

        let project = root.appendingPathComponent("allowed-project")
        let excludedProject = root.appendingPathComponent("excluded-project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: excludedProject, withIntermediateDirectories: false)
        let aliasPolicy = try policy(excluded: [excludedProject.path])
        let aliasFixture = try capture(transcript(format: .codex, cwd: project.path), source: .codex)
        let aliasProof = try eligible(assess(aliasFixture, format: .codex, policy: aliasPolicy))
        XCTAssertTrue(aliasProof.isCurrent(for: aliasFixture.result, policy: aliasPolicy, format: .codex))
        try FileManager.default.removeItem(at: project)
        try FileManager.default.createSymbolicLink(at: project, withDestinationURL: excludedProject)
        let refreshedPolicy = try policy(excluded: [excludedProject.path])
        XCTAssertFalse(aliasProof.isCurrent(for: aliasFixture.result, policy: refreshedPolicy, format: .codex))
    }

    func testMissingOrCorruptCASObjectCannotProduceProof() throws {
        let fixture = try capture(transcript(format: .codex, cwd: "/allowed"), source: .codex)
        let digest = try XCTUnwrap(fixture.result.manifest.chunks.first).rawSHA256
        let objectURL = fixture.storeRoot.appendingPathComponent("objects/sha256/\(digest.prefix(2))/\(digest)")
        XCTAssertEqual(chmod(objectURL.path, 0o600), 0)
        try Data("corrupt".utf8).write(to: objectURL)
        XCTAssertEqual(try assess(fixture, format: .codex), .withheld(.invalidCapture))
        try FileManager.default.removeItem(at: objectURL)
        XCTAssertEqual(try assess(fixture, format: .codex), .withheld(.invalidCapture))
    }

    func testCancellationCannotReturnEligibleProof() async throws {
        let fixture = try capture(transcript(format: .codex, cwd: "/allowed"), source: .codex)
        let policy = try policy()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try CollectorPrivacyProof.assess(capture: fixture.result, cas: fixture.cas, format: .codex, policy: policy)
        }
        do { _ = try await task.value; XCTFail("cancelled proof assessment succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testCompleteAssessmentCrossesCASChunkBoundaryAndStillFindsLaterConflict() throws {
        let opening = try transcript(format: .codex, cwd: "/allowed")
        let padding = try JSONSerialization.data(withJSONObject: ["type": "ignored", "padding": String(repeating: "x", count: Int(ArchiveSourceManifest.rawChunkSize))]) + Data([0x0A])
        let fixture = try capture(opening + padding, source: .codex)
        XCTAssertEqual(fixture.result.manifest.chunks.count, 2)
        let limits = CollectorPrivacyLimits(maxLineBytes: 9 * 1024 * 1024)
        XCTAssertEqual(try eligible(assess(fixture, format: .codex, limits: limits)).projectRoot, "/allowed")
        let conflict = try capture(opening + padding + transcript(format: .codex, cwd: "/excluded"), source: .codex)
        XCTAssertEqual(try assess(conflict, format: .codex, limits: limits), .withheld(.conflictingProjectRoots))
    }

    func testDefaultClaudeMultiRootInvalidatesWhenLaterRootBecomesExcludedSymlink() throws {
        let format = SourceMetadataProjection.Format.claudeCode(forceClaudeCodeSource: false)
        let first = root.appendingPathComponent("allowed-root")
        let second = root.appendingPathComponent("other-root")
        let excluded = root.appendingPathComponent("excluded-root")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: false)
        let bytes = try transcript(format: format, cwd: first.path) + transcript(format: format, cwd: second.path)
        let fixture = try capture(bytes, source: .claudeCode)
        let policy = try policy(excluded: [excluded.path])
        let proof = try eligible(assess(fixture, format: format, policy: policy))
        XCTAssertTrue(proof.isCurrent(for: fixture.result, policy: policy, format: format))
        try FileManager.default.removeItem(at: second)
        try FileManager.default.createSymbolicLink(at: second, withDestinationURL: excluded)
        XCTAssertFalse(proof.isCurrent(for: fixture.result, policy: policy, format: format))
        XCTAssertEqual(try assess(fixture, format: format, policy: policy), .withheld(.invalidProjectRoot))
    }

    func testDefaultClaudeMultiRootProofInvalidatesOnPolicyRevisionAndExcludedLaterRoot() throws {
        let format = SourceMetadataProjection.Format.claudeCode(forceClaudeCodeSource: false)
        let bytes = try transcript(format: format, cwd: "/allowed") + transcript(format: format, cwd: "/other")
        let fixture = try capture(bytes, source: .claudeCode)
        let original = try policy()
        let proof = try eligible(assess(fixture, format: format, policy: original))
        XCTAssertFalse(proof.isCurrent(for: fixture.result, policy: try policy(revision: 2), format: format))
        let digested = try policy(excluded: ["/other"])
        XCTAssertFalse(proof.isCurrent(for: fixture.result, policy: digested, format: format))
        XCTAssertEqual(try assess(fixture, format: format, policy: digested), .withheld(.excludedProject))
    }

    func testDefaultClaudeMultiRootObservationLimitsAndByteDistinctUnicodeRoots() throws {
        let format = SourceMetadataProjection.Format.claudeCode(forceClaudeCodeSource: false)
        let a = try transcript(format: format, cwd: "/allowed/a")
        let b = try transcript(format: format, cwd: "/allowed/b")
        let fixture = try capture(a + b, source: .claudeCode)
        XCTAssertNotNil(try eligible(assess(fixture, format: format, limits: CollectorPrivacyLimits(maxProjectRoots: 2))))
        XCTAssertEqual(try assess(fixture, format: format, limits: CollectorPrivacyLimits(maxProjectRoots: 1)), .withheld(.limitsExceeded))
        let repeated = try capture(a + b + a, source: .claudeCode)
        XCTAssertNotNil(try eligible(assess(repeated, format: format, limits: CollectorPrivacyLimits(maxProjectRoots: 2))))
        let total = "/allowed/a".utf8.count + "/allowed/b".utf8.count
        XCTAssertNotNil(try eligible(assess(fixture, format: format, limits: CollectorPrivacyLimits(maxTotalProjectRootBytes: total))))
        XCTAssertEqual(try assess(fixture, format: format, limits: CollectorPrivacyLimits(maxTotalProjectRootBytes: total - 1)), .withheld(.limitsExceeded))
        let composed = "/allowed/\u{00E9}"
        let decomposed = "/allowed/e\u{0301}"
        XCTAssertEqual(composed, decomposed)
        XCTAssertNotEqual(Array(composed.utf8), Array(decomposed.utf8))
        let unicode = try capture(transcript(format: format, cwd: composed) + transcript(format: format, cwd: decomposed), source: .claudeCode)
        XCTAssertEqual(try assess(unicode, format: format, limits: CollectorPrivacyLimits(maxProjectRoots: 1)), .withheld(.limitsExceeded))
    }

    func testDefaultClaudeLaterMalformedRowsWithholdAndIgnoresUnrecognizedCwd() throws {
        let format = SourceMetadataProjection.Format.claudeCode(forceClaudeCodeSource: false)
        let first = try transcript(format: format, cwd: "/allowed")
        func row(_ object: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) + Data([0x0A])
        }
        let nonstring = try capture(first + row(["type": "user", "cwd": 1, "sessionId": "native", "message": ["content": "x"]]), source: .claudeCode)
        XCTAssertEqual(try assess(nonstring, format: format), .withheld(.invalidProjectRoot))
        let traversal = try capture(first + row(["type": "assistant", "cwd": "/allowed/../evil", "sessionId": "native", "message": ["model": "claude-sonnet-4", "content": "x"]]), source: .claudeCode)
        XCTAssertEqual(try assess(traversal, format: format), .withheld(.invalidProjectRoot))
        let partial = try capture(first + Data("{\"type\":".utf8), source: .claudeCode)
        XCTAssertEqual(try assess(partial, format: format), .withheld(.incompleteMetadata))
        let ignored = try capture(first + row(["type": "file-history", "cwd": "/excluded", "sessionId": "native"]), source: .claudeCode)
        XCTAssertEqual(try eligible(assess(ignored, format: format, policy: try policy(excluded: ["/excluded"]))).projectRoot, "/allowed")
    }

    func testForcedClaudeAndEnabledMinimaxMultiRootRemainConflicts() throws {
        let forced = SourceMetadataProjection.Format.claudeCode(forceClaudeCodeSource: true)
        let bytes = try transcript(format: forced, cwd: "/allowed", model: "MiniMax-M2.1")
            + transcript(format: forced, cwd: "/other", model: "MiniMax-M2.1")
        XCTAssertEqual(try assess(capture(bytes, source: .claudeCode), format: forced), .withheld(.conflictingProjectRoots))
        let derived = try capture(bytes, source: .minimax)
        let enabled = try policy(sources: [.claudeCode, .codex, .minimax])
        XCTAssertEqual(try assess(derived, policy: enabled), .withheld(.conflictingProjectRoots))
    }

    func testDefaultClaudeRootBudgetsDoNotRestrictEnabledDerivedSource() throws {
        let bytes = try transcript(format: .claudeCode(forceClaudeCodeSource: false),
                                   cwd: "/allowed", model: "MiniMax-M2.1")
        let fixture = try capture(bytes, source: .minimax)
        let enabled = try policy(sources: [.minimax])
        let limits = CollectorPrivacyLimits(maxTotalProjectRootBytes: 1)
        XCTAssertEqual(try eligible(assess(fixture, policy: enabled, limits: limits)).source, .minimax)
    }

    func testDefaultClaudeMultiRootKeepsComponentBoundaryAndCASBytes() throws {
        let format = SourceMetadataProjection.Format.claudeCode(forceClaudeCodeSource: false)
        let policy = try policy(excluded: ["/private/project"])
        let bytes = try transcript(format: format, cwd: "/private/project-other") + transcript(format: format, cwd: "/allowed")
        let fixture = try capture(bytes, source: .claudeCode)
        let proof = try eligible(assess(fixture, format: format, policy: policy))
        XCTAssertEqual(proof.projectRoot, "/private/project-other")
        var reconstructed = Data()
        for chunk in fixture.result.manifest.chunks {
            reconstructed.append(try fixture.cas.readObject(sha256: chunk.rawSHA256))
        }
        XCTAssertEqual(reconstructed, bytes)
        XCTAssertEqual(proof.wholeSourceSHA256, ArchiveV2Hash.sha256(bytes))
    }

    func testCanonicallyEquivalentUnicodeExclusionsApplyToLaterClaudeRoots() throws {
        let composed = "/allowed/caf\u{00E9}"
        let decomposed = "/allowed/cafe\u{0301}"
        for (excluded, observed) in [(composed, decomposed), (decomposed, composed)] {
            for suffix in ["", "/child"] {
                let bytes = try transcript(format: .claudeCode(forceClaudeCodeSource: false), cwd: "/first")
                    + transcript(format: .claudeCode(forceClaudeCodeSource: false), cwd: observed + suffix)
                let fixture = try capture(bytes, source: .claudeCode)
                XCTAssertEqual(try assess(fixture, policy: policy(excluded: [excluded])), .withheld(.excludedProject))
            }
        }
    }

    private struct Fixture: Sendable {
        let sourceURL: URL
        let storeRoot: URL
        let cas: ImmutableArchiveCAS
        let result: ArchiveCaptureResult
    }

    private func capture(_ bytes: Data, source: SourceName) throws -> Fixture {
        let sourceURL = root.appendingPathComponent("\(UUID().uuidString).jsonl")
        try bytes.write(to: sourceURL)
        let storeRoot = root.appendingPathComponent("shadow-\(UUID().uuidString)")
        let cas = try ImmutableArchiveCAS(root: storeRoot)
        let catalog = try ArchiveCatalog(root: storeRoot, machineID: machineID)
        try catalog.migrate()
        let descriptor = try ArchiveSourceDescriptor.singleFile(locator: sourceURL.path, sourceURL: sourceURL, replayRelativePath: sourceURL.lastPathComponent)
        let result = try ExactSourceCapturer(cas: cas, catalog: catalog, descriptor: descriptor).capture(source: source, locator: sourceURL.path, machineID: machineID)
        return Fixture(sourceURL: sourceURL, storeRoot: storeRoot, cas: cas, result: result)
    }

    private func transcript(format: SourceMetadataProjection.Format, cwd: String?, id: String? = "native", model: String = "claude-sonnet-4") throws -> Data {
        var metadata: [String: Any] = [:]
        if let cwd { metadata["cwd"] = cwd }
        var objects: [[String: Any]]
        if format == .codex {
            if let id { metadata["id"] = id }
            metadata["timestamp"] = "2026-09-05T00:00:00Z"
            objects = [["type": "session_meta", "payload": metadata], ["type": "response_item", "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "answer"]]]]]
        } else {
            if let id { metadata["sessionId"] = id }
            metadata["type"] = "assistant"
            metadata["message"] = ["model": model, "content": "answer"]
            objects = [metadata]
        }
        var bytes = Data()
        for object in objects { bytes.append(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])); bytes.append(0x0A) }
        return bytes
    }

    private func policy(revision: Int64 = 1, excluded: [String] = [], sources: Set<SourceName> = [.claudeCode, .codex]) throws -> CollectorPrivacyPolicy {
        try CollectorPrivacyPolicy(revision: revision, excludedProjectRoots: excluded, allowedSources: sources)
    }

    private func assess(_ fixture: Fixture, format: SourceMetadataProjection.Format = .claudeCode(forceClaudeCodeSource: false), policy: CollectorPrivacyPolicy? = nil, limits: CollectorPrivacyLimits = .init()) throws -> CollectorPrivacyAssessment {
        try CollectorPrivacyProof.assess(capture: fixture.result, cas: fixture.cas, format: format, policy: try policy ?? self.policy(), limits: limits)
    }

    private func eligible(_ result: CollectorPrivacyAssessment) throws -> CollectorPrivacyProof {
        guard case .eligible(let proof) = result else { throw NSError(domain: "CollectorPrivacyProofTests", code: 1, userInfo: [NSLocalizedDescriptionKey: String(describing: result)]) }
        return proof
    }
}
