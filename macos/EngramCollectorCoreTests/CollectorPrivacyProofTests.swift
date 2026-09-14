import Darwin
import Foundation
import SQLite3
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

    func testWindsurfHookPrivacyRequiresEvidenceAndReplaysAfterSourceDeletion() throws {
        let noPaths = try captureWindsurf(Data(#"{"type":"user_input","status":"done","user_input":{"user_response":"hello"}}"#.utf8))
        let policy = try policy(sources: [.windsurf])
        XCTAssertEqual(try assess(noPaths, format: .windsurfHookTranscript, policy: policy), .withheld(.invalidProjectRoot))
        let fixture = try captureWindsurf(Data(#"{"type":"code_action","status":"done","code_action":{"path":"/allowed/project/a","new_content":"body"}}"#.utf8))
        try FileManager.default.removeItem(at: fixture.sourceURL.deletingLastPathComponent())
        let proof = try eligible(assess(fixture, format: .windsurfHookTranscript, policy: policy))
        XCTAssertEqual(proof.nativeSessionID, "session")
        XCTAssertEqual(proof.source, .windsurf)
        XCTAssertTrue(proof.isCurrent(for: fixture.result, policy: policy, format: .windsurfHookTranscript))
        let excluded = try self.policy(excluded: ["/allowed"], sources: [.windsurf])
        XCTAssertFalse(proof.isCurrent(for: fixture.result, policy: excluded, format: .windsurfHookTranscript))
    }

    func testWindsurfHookPrivacyRejectsEscapedNestedPathsBeyondPrefix() throws {
        let prefix = Data((#"{"type":"user_input","status":"done","user_input":{"user_response":"/allowed/project/a"}}"# + "\n" + String(repeating: " ", count: 50_000) + "\n").utf8)
        let policy = try policy(excluded: ["/private"], sources: [.windsurf])
        for token in [#"{"rules_applied":{"path":"\/private\/project\/secret"}}"#,
                      #"{"future_step":{"path":"\u002fprivate\u002fproject\u002fsecret"}}"#,
                      #"{"code_action":{"path":"/private"}}"#] {
            let fixture = try captureWindsurf(prefix + Data(token.utf8))
            try FileManager.default.removeItem(at: fixture.sourceURL)
            XCTAssertEqual(try assess(fixture, format: .windsurfHookTranscript, policy: policy), .withheld(.excludedProject))
        }
    }

    func testWindsurfHookPrivacyRejectsMalformedEscapesAndBudgets() throws {
        let policy = try policy(sources: [.windsurf])
        let invalid = try captureWindsurf(Data(#"{"path":"/allowed/project/a","other":"\uD800"}"#.utf8))
        XCTAssertEqual(try assess(invalid, format: .windsurfHookTranscript, policy: policy), .withheld(.malformedMetadata))
        let fixture = try captureWindsurf(Data(#"{"path":"/allowed/project/a"}"#.utf8))
        for limits in [CollectorPrivacyLimits(maxSourceBytes: 1), .init(maxLineBytes: 1), .init(maxTotalProjectRootBytes: 1)] {
            XCTAssertEqual(try assess(fixture, format: .windsurfHookTranscript, policy: policy, limits: limits), .withheld(.limitsExceeded))
        }
        let chunk = try XCTUnwrap(fixture.result.manifest.chunks.first)
        _ = try fixture.cas.removeObject(sha256: chunk.rawSHA256)
        XCTAssertEqual(try assess(fixture, format: .windsurfHookTranscript, policy: policy), .withheld(.invalidCapture))
    }

    func testWindsurfHookPrivacyHandlesWholePathsAndSingleEvidenceBudget() throws {
        let policy = try policy(sources: [.windsurf])
        let single = try captureWindsurf(Data(#"{"path":"\/allowed\/project\/a"}"#.utf8))
        let proof = try eligible(assess(single, format: .windsurfHookTranscript, policy: policy, limits: .init(maxProjectRoots: 1)))
        XCTAssertTrue(proof.isCurrent(for: single.result, policy: policy, format: .windsurfHookTranscript))
        for path in ["/private/project", "/private/project with spaces", "/private/项目"] {
            let raw = try JSONSerialization.data(withJSONObject: ["path": path])
            let fixture = try captureWindsurf(raw)
            let excluded = try self.policy(excluded: [path], sources: [.windsurf])
            XCTAssertEqual(try assess(fixture, format: .windsurfHookTranscript, policy: excluded), .withheld(.excludedProject))
        }
        let alias = root.appendingPathComponent("alias")
        let real = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        let fixture = try captureWindsurf(try JSONSerialization.data(withJSONObject: ["path": alias.path + "/a"]))
        XCTAssertEqual(try assess(fixture, format: .windsurfHookTranscript, policy: policy), .withheld(.invalidProjectRoot))
    }

    func testWindsurfHookPrivacyDecodesEscapeAcrossCASChunks() throws {
        var bytes = Data(#"{"path":"/allowed/project/a"}"#.utf8)
        bytes.append(10)
        let token = Data(#"{"future":{"path":"\u002fprivate\u002fsecret"}}"#.utf8)
        let boundary = Int(ArchiveSourceManifest.rawChunkSize)
        let count = boundary - 21 - bytes.count
        var padding = Data(repeating: 32, count: count)
        for index in stride(from: 0, to: count, by: 1024) { padding[index] = 10 }
        bytes.append(padding)
        bytes.append(token)
        let fixture = try captureWindsurf(bytes)
        XCTAssertEqual(fixture.result.manifest.chunks.count, 2)
        try FileManager.default.removeItem(at: fixture.sourceURL)
        let policy = try policy(excluded: ["/private"], sources: [.windsurf])
        XCTAssertEqual(try assess(fixture, format: .windsurfHookTranscript, policy: policy), .withheld(.excludedProject))
    }

    func testWindsurfHookPrivacyRejectsExcludedPathsInsideText() throws {
        let policy = try policy(excluded: ["/private", "/secret/project with spaces"], sources: [.windsurf])
        for text in ["Inspect /private", "/allowed/project/a /private", "Read /secret/project with spaces/file now", "/allowed/project/a\n/private"] {
            let fixture = try captureWindsurf(try JSONSerialization.data(withJSONObject: ["user_input": ["user_response": text]]))
            XCTAssertEqual(try assess(fixture, format: .windsurfHookTranscript, policy: policy), .withheld(.excludedProject))
        }
    }

    func testWindsurfHookPrivacyRejectsPunctuationDelimitedExcludedPaths_repro() throws {
        let policy = try policy(excluded: ["/private"], sources: [.windsurf])
        for text in ["path:/private", "files,/private", "(/private)", "inspect /private,"] {
            let bytes = try JSONSerialization.data(withJSONObject: ["allowed": "/allowed/project/a", "content": text])
            let fixture = try captureWindsurf(bytes)
            XCTAssertEqual(try assess(fixture, format: .windsurfHookTranscript, policy: policy), .withheld(.excludedProject))
        }
    }

    func testWindsurfHookPrivacyRejectsSentencePeriodAndExcessiveDepth_repro() throws {
        let policy = try policy(excluded: ["/private"], sources: [.windsurf])
        let sentence = try captureWindsurf(try JSONSerialization.data(withJSONObject: ["path": "/allowed/project/a", "content": "Inspect /private."]))
        XCTAssertEqual(try assess(sentence, format: .windsurfHookTranscript, policy: policy), .withheld(.excludedProject))
        let deepPath = "/allowed/" + Array(repeating: "a", count: 300).joined(separator: "/")
        let deep = try captureWindsurf(try JSONSerialization.data(withJSONObject: ["path": deepPath]))
        XCTAssertEqual(try assess(deep, format: .windsurfHookTranscript, policy: policy), .withheld(.limitsExceeded))
    }

    func testWindsurfHookPrivacyRejectsExcludedFileURIWithAllowedEvidence_repro() throws {
        let policy = try policy(excluded: ["/private"], sources: [.windsurf])
        for text in ["file:///private/project/a", "open file:///%70rivate/project/a"] {
            let fixture = try captureWindsurf(try JSONSerialization.data(withJSONObject: ["path": "/allowed/project/a", "content": text]))
            XCTAssertEqual(try assess(fixture, format: .windsurfHookTranscript, policy: policy), .withheld(.excludedProject))
        }
        let webpage = try captureWindsurf(try JSONSerialization.data(withJSONObject: ["path": "/allowed/project/a", "content": "https://example.test/private/project/a"]))
        _ = try eligible(assess(webpage, format: .windsurfHookTranscript, policy: policy))
    }

    private func captureWindsurf(_ bytes: Data) throws -> Fixture {
        let sourceURL = root.appendingPathComponent(UUID().uuidString).appendingPathComponent("transcripts/session.jsonl")
        try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: sourceURL)
        let storeRoot = root.appendingPathComponent("windsurf-" + UUID().uuidString)
        let cas = try ImmutableArchiveCAS(root: storeRoot)
        let catalog = try ArchiveCatalog(root: storeRoot, machineID: machineID)
        try catalog.migrate()
        defer { try? catalog.close() }
        let descriptor = try ArchiveSourceDescriptor.singleFile(locator: sourceURL.path, sourceURL: sourceURL, replayRelativePath: "session.jsonl")
        let result = try ExactSourceCapturer(cas: cas, catalog: catalog, descriptor: descriptor)
            .capture(source: .windsurf, locator: sourceURL.path, machineID: machineID)
        return Fixture(sourceURL: sourceURL, storeRoot: storeRoot, cas: cas, result: result)
    }

    func testAntigravityCLIPrivacyReplaysFrozenBytesAndChecksEveryRoot_repro() throws {
        let fixture = try captureAntigravity(Data("/allowed/project/a /allowed/project/b /private/project/c".utf8))
        try FileManager.default.removeItem(at: fixture.sourceURL)
        let policy = try policy(sources: [.antigravity])
        let proof = try eligible(assess(fixture, format: .antigravityCLITranscript, policy: policy))
        XCTAssertEqual(proof.nativeSessionID, "session")
        XCTAssertEqual(proof.projectRoot, "/allowed/project")
        XCTAssertTrue(proof.isCurrent(for: fixture.result, policy: policy, format: .antigravityCLITranscript))
        let excluded = try self.policy(excluded: ["/private"], sources: [.antigravity])
        XCTAssertEqual(try assess(fixture, format: .antigravityCLITranscript, policy: excluded), .withheld(.excludedProject))
        for limits in [CollectorPrivacyLimits(maxSourceBytes: 1), .init(maxProjectRoots: 1), .init(maxTotalProjectRootBytes: 1)] {
            XCTAssertEqual(try assess(fixture, format: .antigravityCLITranscript, policy: policy, limits: limits), .withheld(.limitsExceeded))
        }
        let chunk = try XCTUnwrap(fixture.result.manifest.chunks.first)
        _ = try fixture.cas.removeObject(sha256: chunk.rawSHA256)
        XCTAssertEqual(try assess(fixture, format: .antigravityCLITranscript, policy: policy), .withheld(.invalidCapture))
    }

    func testAntigravityCLIPrivacyRejectsInvalidPrefixAndUnrelatedLayout() throws {
        let policy = try policy(sources: [.antigravity])
        for bytes in [Data("no directory".utf8), Data("/allowed/project/a".utf8) + Data([0xff])] {
            let fixture = try captureAntigravity(bytes)
            XCTAssertEqual(try assess(fixture, format: .antigravityCLITranscript, policy: policy),
                           .withheld(bytes.last == 0xff ? .malformedMetadata : .invalidProjectRoot))
        }
        for relative in ["transcript.jsonl", "other/session/.system_generated/logs/transcript.jsonl", "session/cache/transcript.jsonl"] {
            let fixture = try captureAntigravity(Data("/allowed/project/a".utf8), relative: relative)
            XCTAssertEqual(try assess(fixture, format: .antigravityCLITranscript, policy: policy), .withheld(.invalidCapture))
        }
    }

    func testAntigravityCLIPrivacyRejectsSecondarySymlinkAndTruncatedUTF8AtEOF() throws {
        let policy = try policy(sources: [.antigravity])
        let target = root.appendingPathComponent("real")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let fixture = try captureAntigravity(Data(("/allowed/project/a /allowed/project/b " + alias.path + "/c").utf8))
        XCTAssertEqual(try assess(fixture, format: .antigravityCLITranscript, policy: policy), .withheld(.invalidProjectRoot))
        let lead = Data("/allowed/project/a ".utf8)
        let prefix = lead + Data(repeating: 32, count: SourceMetadataProjection.antigravityCLIPrefixByteLimit - lead.count - 2) + Data([0xE4, 0xB8])
        let truncated = try captureAntigravity(prefix)
        XCTAssertEqual(try assess(truncated, format: .antigravityCLITranscript, policy: policy), .withheld(.malformedMetadata))
        let complete = try captureAntigravity(prefix + Data([0xAD]))
        let proof = try eligible(assess(complete, format: .antigravityCLITranscript, policy: policy))
        XCTAssertEqual(proof.projectRoot, "/allowed/project")
    }

    func testAntigravityCLIPrivacyChecksPathsAndMalformedBytesBeyondCWDWindow_repro() throws {
        let prefix = Data(("/allowed/project/a\n" + String(repeating: " ", count: 50_000) + "\n").utf8)
        let excludedPolicy = try policy(excluded: ["/private"], sources: [.antigravity])
        let excluded = try captureAntigravity(prefix + Data("/private/project/secret\n".utf8))
        XCTAssertEqual(try assess(excluded, format: .antigravityCLITranscript, policy: excludedPolicy), .withheld(.excludedProject))
        let malformed = try captureAntigravity(prefix + Data([0xFF]))
        XCTAssertEqual(try assess(malformed, format: .antigravityCLITranscript, policy: excludedPolicy), .withheld(.malformedMetadata))
        let limited = try captureAntigravity(prefix + Data("/another/project/a\n".utf8))
        XCTAssertEqual(try assess(limited, format: .antigravityCLITranscript, policy: excludedPolicy,
                                 limits: .init(maxProjectRoots: 1)), .withheld(.limitsExceeded))
    }

    func testAntigravityCLIPrivacyCarriesPathAndUTF8AcrossCASChunks() throws {
        var bytes = Data("/allowed/project/a\n".utf8)
        let boundary = Int(ArchiveSourceManifest.rawChunkSize)
        let paddingCount = boundary - 10 - bytes.count
        var padding = Data(repeating: 32, count: paddingCount)
        for index in stride(from: 0, to: paddingCount, by: 1024) { padding[index] = 10 }
        bytes.append(padding)
        bytes.append(Data("/private/中/a".utf8))
        let fixture = try captureAntigravity(bytes)
        XCTAssertEqual(fixture.result.manifest.chunks.count, 2)
        let allowed = try policy(sources: [.antigravity])
        XCTAssertEqual(try eligible(assess(fixture, format: .antigravityCLITranscript, policy: allowed)).projectRoot, "/allowed/project")
        let excluded = try policy(excluded: ["/private"], sources: [.antigravity])
        XCTAssertEqual(try assess(fixture, format: .antigravityCLITranscript, policy: excluded), .withheld(.excludedProject))
        XCTAssertEqual(try assess(fixture, format: .antigravityCLITranscript, policy: allowed,
                                 limits: .init(maxLineBytes: 16)), .withheld(.limitsExceeded))
    }

    func testAntigravityCLIPrivacyChecksJSONEscapedPathsBeyondNativePrefix_repro() throws {
        let prefix = Data(("/allowed/project/a /allowed/project/b\n" + String(repeating: " ", count: 50_000) + "\n").utf8)
        let policy = try policy(excluded: ["/private"], sources: [.antigravity])
        let records = [
            #"{"content":"\/private\/project\/secret"}"#,
            #"{"content":"\u002fprivate\u002fproject\u002fsecret"}"#,
            #"{"content":"/\u0070rivate/project/secret"}"#,
            #"{"content":"safe\n/private/project/secret"}"#,
        ]
        for record in records {
            let fixture = try captureAntigravity(prefix + Data(record.utf8))
            XCTAssertEqual(try assess(fixture, format: .antigravityCLITranscript, policy: policy), .withheld(.excludedProject))
        }
        let safe = try captureAntigravity(prefix + Data(#"{"content":"\/allowed\/project\/file \u4e2d\ud83d\ude00"}"#.utf8))
        XCTAssertEqual(try eligible(assess(safe, format: .antigravityCLITranscript, policy: policy,
                                          limits: .init(maxProjectRoots: 1))).projectRoot, "/allowed/project")
    }

    func testAntigravityCLIPrivacyRejectsBrokenEscapesAndDecodedUnsafeRoots() throws {
        let prefix = Data("/allowed/project/a\n".utf8)
        let policy = try policy(sources: [.antigravity])
        for record in [#"{"content":"\q"}"#, #"{"content":"\u12"}"#,
                       #"{"content":"\uD800"}"#, #"{"content":"\uDC00"}"#,
                       #"{"content":"\uD800\u0041"}"#, #"{"content":"unterminated"#] {
            let fixture = try captureAntigravity(prefix + Data(record.utf8))
            XCTAssertEqual(try assess(fixture, format: .antigravityCLITranscript, policy: policy), .withheld(.malformedMetadata))
        }
        let unsafe = try captureAntigravity(prefix + Data(#"{"content":"/private\u0000/project/file"}"#.utf8))
        XCTAssertEqual(try assess(unsafe, format: .antigravityCLITranscript, policy: policy), .withheld(.invalidProjectRoot))
        let second = try captureAntigravity(prefix + Data(#"{"content":"\u002fanother\u002fproject\u002ffile"}"#.utf8))
        XCTAssertEqual(try assess(second, format: .antigravityCLITranscript, policy: policy,
                                 limits: .init(maxProjectRoots: 1)), .withheld(.limitsExceeded))
    }

    func testAntigravityCLIPrivacyDecodesEscapeSplitAcrossCASChunks() throws {
        var bytes = Data("/allowed/project/a\n".utf8)
        let token = Data(#"{"content":"\u002fprivate\u002fproject\u002ffile"}"#.utf8)
        let boundary = Int(ArchiveSourceManifest.rawChunkSize)
        // The first Unicode escape straddles the archive chunk boundary.
        let split = 16
        let count = boundary - split - bytes.count
        var padding = Data(repeating: 32, count: count)
        for index in stride(from: 0, to: count, by: 1024) { padding[index] = 10 }
        bytes.append(padding)
        bytes.append(token)
        let fixture = try captureAntigravity(bytes)
        XCTAssertEqual(fixture.result.manifest.chunks.count, 2)
        let policy = try policy(excluded: ["/private"], sources: [.antigravity])
        XCTAssertEqual(try assess(fixture, format: .antigravityCLITranscript, policy: policy), .withheld(.excludedProject))
    }

    private func captureAntigravity(_ bytes: Data, relative: String = "session/.system_generated/logs/transcript.jsonl") throws -> Fixture {
        let sourceURL = root.appendingPathComponent(UUID().uuidString).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: sourceURL)
        let storeRoot = root.appendingPathComponent("antigravity-" + UUID().uuidString)
        let cas = try ImmutableArchiveCAS(root: storeRoot)
        let catalog = try ArchiveCatalog(root: storeRoot, machineID: machineID)
        try catalog.migrate()
        defer { try? catalog.close() }
        let descriptor = try ArchiveSourceDescriptor.singleFile(locator: sourceURL.path, sourceURL: sourceURL, replayRelativePath: relative)
        let result = try ExactSourceCapturer(cas: cas, catalog: catalog, descriptor: descriptor)
            .capture(source: .antigravity, locator: sourceURL.path, machineID: machineID)
        return Fixture(sourceURL: sourceURL, storeRoot: storeRoot, cas: cas, result: result)
    }

    func testCursorLegacyCapturedPrivacyAdmissionAndPolicyBinding_repro() throws {
        let fixture = try captureLegacy(cwd: "/allowed/project")
        let policy = try CollectorPrivacyPolicy(revision: 1, excludedProjectRoots: [], allowedSources: [.cursor])
        // No source database exists: admission must use the captured body alone.
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
        let proof = try eligible(assess(fixture, format: .cursor, policy: policy))
        XCTAssertEqual(proof.nativeSessionID, "owned")
        XCTAssertEqual(proof.projectRoot, "/allowed/project")
        XCTAssertTrue(proof.isCurrent(for: fixture.result, policy: policy, format: .cursor))
        let excluded = try CollectorPrivacyPolicy(revision: 2, excludedProjectRoots: ["/allowed"], allowedSources: [.cursor])
        XCTAssertFalse(proof.isCurrent(for: fixture.result, policy: excluded, format: .cursor))
        XCTAssertEqual(try assess(fixture, format: .cursor, policy: excluded), .withheld(.excludedProject))
        XCTAssertEqual(try assess(fixture, format: .cursor, policy: self.policy()), .withheld(.unsupportedSource))
    }

    func testCursorLegacyPrivacyRequiresFrozenRootAndRespectsLimits_repro() throws {
        let policy = try CollectorPrivacyPolicy(revision: 1, excludedProjectRoots: [], allowedSources: [.cursor])
        let missing = try captureLegacy(cwd: "")
        let missingProof = try eligible(assess(missing, format: .cursor, policy: policy))
        XCTAssertNil(missingProof.projectRoot)
        let fixture = try captureLegacy(cwd: "/allowed/project")
        for limits in [CollectorPrivacyLimits(maxSourceBytes: 1), .init(maxLineBytes: 1),
                       .init(maxRecords: 0), .init(maxProjectRoots: 0), .init(maxTotalProjectRootBytes: 1)] {
            XCTAssertEqual(try CollectorPrivacyProof.assess(capture: fixture.result, cas: fixture.cas,
                format: .cursor, policy: policy, limits: limits), .withheld(.limitsExceeded))
        }
    }

    func testCursorLegacyPrivacyRejectsMissingCASAndSymlinkRoot() throws {
        let policy = try CollectorPrivacyPolicy(revision: 1, excludedProjectRoots: [], allowedSources: [.cursor])
        let fixture = try captureLegacy(cwd: "/allowed/project")
        let chunk = try XCTUnwrap(fixture.result.manifest.chunks.first)
        _ = try fixture.cas.removeObject(sha256: chunk.rawSHA256)
        XCTAssertEqual(try assess(fixture, format: .cursor, policy: policy), .withheld(.invalidCapture))
        let target = root.appendingPathComponent("real-project")
        let alias = root.appendingPathComponent("project-alias")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let aliased = try captureLegacy(cwd: alias.path)
        XCTAssertEqual(try assess(aliased, format: .cursor, policy: policy), .withheld(.invalidProjectRoot))
    }

    func testCursorLegacyPrivacyRecordBudgetCountsComposerAndOpaqueRows() throws {
        let fixture = try captureLegacy(cwd: "/allowed", bubbles: [
            .init(rowID: 2, key: "bubbleId:owned:one", value: Data([0xFF]), storage: .blob)])
        let policy = try CollectorPrivacyPolicy(revision: 1, excludedProjectRoots: [], allowedSources: [.cursor])
        XCTAssertEqual(try CollectorPrivacyProof.assess(capture: fixture.result, cas: fixture.cas,
            format: .cursor, policy: policy, limits: .init(maxRecords: 1)), .withheld(.limitsExceeded))
        _ = try eligible(CollectorPrivacyProof.assess(capture: fixture.result, cas: fixture.cas,
            format: .cursor, policy: policy, limits: .init(maxRecords: 2)))
    }

    func testCursorRootlessArchivesOnlyWhenPolicyHasNoExclusions_repro() throws {
        let absent = SourceMetadataProjection.cursorModernMetadata(storedText: "{}", liveText: "{}")
        XCTAssertEqual(absent.cwd, "")
        XCTAssertFalse(absent.hasInvalidRootEvidence)
        XCTAssertFalse(absent.hasMalformedMetadata)
        XCTAssertTrue(absent.observedRawCWDs.allSatisfy(\.isEmpty))
        let empty = SourceMetadataProjection.cursorModernMetadata(
            storedText: #"{"cwd":""}"#, liveText: #"{"cwd":""}"#)
        XCTAssertEqual(empty.cwd, "")
        XCTAssertFalse(empty.hasInvalidRootEvidence)
        let typed = SourceMetadataProjection.cursorModernMetadata(storedText: "{}", liveText: #"{"cwd":1}"#)
        XCTAssertTrue(typed.hasInvalidRootEvidence)
        XCTAssertEqual(typed.cwd, "")

        let unrestricted = try CollectorPrivacyPolicy(revision: 1, excludedProjectRoots: [], allowedSources: [.cursor])
        let excluded = try CollectorPrivacyPolicy(
            revision: 2, excludedProjectRoots: ["/private/project"], allowedSources: [.cursor])
        let modern = try captureModern(stored: [:], live: [:])
        let modernProof = try eligible(assess(modern, format: .cursor, policy: unrestricted))
        XCTAssertNil(modernProof.projectRoot)
        XCTAssertEqual(modernProof.nativeSessionID, "native")
        XCTAssertTrue(modernProof.isCurrent(for: modern.result, policy: unrestricted, format: .cursor))
        XCTAssertFalse(modernProof.isCurrent(for: modern.result, policy: excluded, format: .cursor))
        XCTAssertEqual(try assess(modern, format: .cursor, policy: excluded), .withheld(.invalidProjectRoot))

        let emptyModern = try captureModern(stored: ["cwd": ""], live: ["cwd": ""])
        let emptyProof = try eligible(assess(emptyModern, format: .cursor, policy: unrestricted))
        XCTAssertNil(emptyProof.projectRoot)
        XCTAssertTrue(emptyProof.isCurrent(for: emptyModern.result, policy: unrestricted, format: .cursor))
        XCTAssertFalse(emptyProof.isCurrent(for: emptyModern.result, policy: excluded, format: .cursor))

        let legacy = try captureLegacy(cwd: "")
        let legacyProof = try eligible(assess(legacy, format: .cursor, policy: unrestricted))
        XCTAssertNil(legacyProof.projectRoot)
        XCTAssertEqual(legacyProof.nativeSessionID, "owned")
        XCTAssertTrue(legacyProof.isCurrent(for: legacy.result, policy: unrestricted, format: .cursor))
        XCTAssertFalse(legacyProof.isCurrent(for: legacy.result, policy: excluded, format: .cursor))
        XCTAssertEqual(try assess(legacy, format: .cursor, policy: excluded), .withheld(.invalidProjectRoot))

        XCTAssertEqual(try assess(captureModern(stored: [:], live: ["cwd": 1]), format: .cursor, policy: unrestricted),
                       .withheld(.invalidProjectRoot))
        XCTAssertEqual(try assess(captureModern(stored: [:], live: ["cwd": "relative"]), format: .cursor, policy: unrestricted),
                       .withheld(.invalidProjectRoot))
        XCTAssertEqual(try assess(captureModern(stored: ["cwd": "/allowed/project"], live: ["cwd": ""]),
                                  format: .cursor, policy: unrestricted),
                       .withheld(.invalidProjectRoot))
        XCTAssertEqual(try assess(captureModern(stored: ["cwd": "/allowed/project"], live: ["cwd": "/other/project"]),
                                  format: .cursor, policy: unrestricted),
                       .withheld(.conflictingProjectRoots))
    }

    private func captureLegacy(cwd: String, bubbles: [ArchiveCursorLegacySession.Row] = []) throws -> Fixture {
        let source = root.appendingPathComponent("absent/state.vscdb")
        let session = try ArchiveCursorLegacySession(logicalDatabaseLocator: source.path,
            composerID: "owned", cwd: cwd,
            databaseGeneration: ArchiveSourceGeneration(device: 1, inode: 2, size: 8192,
                mtimeNs: 5, ctimeNs: 6, mode: 0o100600), walGeneration: nil,
            composer: .init(rowID: 1, key: "composerData:owned", value: Data(#"{"composerId":"owned"}"#.utf8)),
            bubbles: bubbles)
        let storeRoot = root.appendingPathComponent("legacy-" + UUID().uuidString)
        let cas = try ImmutableArchiveCAS(root: storeRoot)
        let catalog = try ArchiveCatalog(root: storeRoot, machineID: machineID)
        try catalog.migrate()
        defer { try? catalog.close() }
        let result = try ExactSourceCapturer.captureCursorLegacySession(session,
            machineID: machineID, cas: cas, catalog: catalog)
        return Fixture(sourceURL: source, storeRoot: storeRoot, cas: cas, result: result)
    }

    private func captureModern(stored: [String: Any], live: [String: Any]?) throws -> Fixture {
        let physical = try XCTUnwrap(realpath(root.path, nil))
        defer { free(physical) }
        let basePath = String(cString: physical)
        let sourceRoot = URL(fileURLWithPath: basePath + "/cursor-" + UUID().uuidString)
        let store = sourceRoot.appendingPathComponent("chats/ws/native/store.db")
        try FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
        var database: OpaquePointer?
        guard sqlite3_open(store.path, &database) == SQLITE_OK, let handle = database else {
            sqlite3_close(database)
            throw POSIXError(.EIO)
        }
        defer { sqlite3_close(handle) }
        func sql(_ text: String) throws {
            guard sqlite3_exec(handle, text, nil, nil, nil) == SQLITE_OK else { throw POSIXError(.EIO) }
        }
        try sql("PRAGMA journal_mode=DELETE;")
        try sql("CREATE TABLE blobs (id TEXT PRIMARY KEY, data BLOB); CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);")
        let payload = try JSONSerialization.data(withJSONObject: stored, options: [.sortedKeys])
        let hex = payload.map { String(format: "%02x", $0) }.joined()
        try sql("BEGIN;")
        try sql("INSERT INTO meta (key, value) VALUES ('0', '\(hex)');")
        try sql("COMMIT;")
        guard chmod(store.path, 0o600) == 0 else { throw POSIXError(.EPERM) }
        for sidecar in [store.path + "-wal", store.path + "-shm", store.path + "-journal"] {
            if FileManager.default.fileExists(atPath: sidecar) {
                try FileManager.default.removeItem(at: URL(fileURLWithPath: sidecar))
            }
        }
        var files = [store]
        var absent = [URL(fileURLWithPath: store.path + "-wal")]
        if let live {
            let meta = store.deletingLastPathComponent().appendingPathComponent("meta.json")
            try JSONSerialization.data(withJSONObject: live, options: [.sortedKeys]).write(to: meta)
            files.append(meta)
        } else {
            absent.append(store.deletingLastPathComponent().appendingPathComponent("meta.json"))
        }
        let storeRoot = URL(fileURLWithPath: basePath + "/cursor-cas-" + UUID().uuidString)
        let cas = try ImmutableArchiveCAS(root: storeRoot)
        let catalog = try ArchiveCatalog(root: storeRoot, machineID: machineID)
        try catalog.migrate()
        defer { try? catalog.close() }
        let descriptor = try ArchiveSourceDescriptor.fileSet(
            locator: store.path, root: sourceRoot, files: files, absentFiles: absent)
        let result = try ExactSourceCapturer(cas: cas, catalog: catalog, descriptor: descriptor)
            .capture(source: .cursor, locator: store.path, machineID: machineID)
        XCTAssertTrue(ArchiveSourceDescriptor.isCursorModernFileSet(result.manifest))
        return Fixture(sourceURL: store, storeRoot: storeRoot, cas: cas, result: result)
    }

    func testGeminiJSONLSnapshotConversationWitness_repro() throws {
        let message: [String: Any] = ["type": "user", "content": "retained snapshot conversation"]
        let snapshots: [[String: Any]] = [["$set": ["messages": [message]]], ["messages": [message]]]
        for object in snapshots {
            let bytes = try JSONSerialization.data(withJSONObject: object) + Data([10])
            XCTAssertTrue(CollectorGeminiSource.recognizedConversation(bytes, jsonl: true,
                maxLineBytes: 1024 * 1024, maxRecords: 100))
        }
        let ignored: [[String: Any]] = [
            ["$set": ["sessionId": "metadata-only"], "type": "user", "content": "ignored by native replay"],
            ["$rewindTo": "unknown", "messages": [message]],
            ["type": "system", "messages": [message]],
            ["$set": ["messages": [["type": "system", "content": "initialization"]]]],
        ]
        for object in ignored {
            let bytes = try JSONSerialization.data(withJSONObject: object) + Data([10])
            XCTAssertFalse(CollectorGeminiSource.recognizedConversation(bytes, jsonl: true,
                maxLineBytes: 1024 * 1024, maxRecords: 100))
        }
    }

    func testGeminiMetadataProjectionHonorsSessionIDUpdateInNativeSizeLine() throws {
        let records: [[String: Any]] = [
            ["sessionId": "before"],
            ["$set": ["sessionId": "after", "padding": String(repeating: "x", count: 1_100_000)]],
        ]
        let bytes = try records.reduce(into: Data()) { data, record in
            data.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
            data.append(10)
        }
        XCTAssertEqual(CollectorGeminiSource.sessionId(from: bytes, jsonl: true), "after")
    }

    func testGeminiNonObjectSetFollowsNativeHeaderMetadataPrecedence() throws {
        let rows: [[String: Any]] = [["sessionId": "before"], ["$set": "non-object", "sessionId": "after"]]
        let bytes = try rows.reduce(into: Data()) { data, row in
            data.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
            data.append(10)
        }
        XCTAssertEqual(CollectorGeminiSource.sessionId(from: bytes, jsonl: true), "after")
    }

    func testGeminiMetadataProjectionDoesNotRestoreIDAfterExplicitInvalidUpdate() throws {
        for invalid: Any in ["", NSNull(), 42] {
            let records: [[String: Any]] = [["sessionId": "before"], ["$set": ["sessionId": invalid]]]
            let bytes = try records.reduce(into: Data()) { data, record in
                data.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
                data.append(10)
            }
            XCTAssertNil(CollectorGeminiSource.sessionId(from: bytes, jsonl: true))
        }
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

    func testLiteralFilesystemRootCwdArchivesOnlyWhenPolicyHasNoExclusions_repro() throws {
        XCTAssertThrowsError(try policy(excluded: ["/"]))
        for format in [SourceMetadataProjection.Format.claudeCode(forceClaudeCodeSource: false), .codex] {
            let source: SourceName = format == .codex ? .codex : .claudeCode
            let fixture = try capture(transcript(format: format, cwd: "/"), source: source)
            let unrestricted = try policy()
            let proof = try eligible(assess(fixture, format: format, policy: unrestricted))
            XCTAssertEqual(proof.projectRoot, "/")
            XCTAssertEqual(proof.nativeSessionID, "native")
            XCTAssertEqual(proof.source, source)
            XCTAssertTrue(proof.isCurrent(for: fixture.result, policy: unrestricted, format: format))
            let excluded = try policy(excluded: ["/private/project"])
            XCTAssertFalse(proof.isCurrent(for: fixture.result, policy: excluded, format: format))
            XCTAssertEqual(try assess(fixture, format: format, policy: excluded), .withheld(.excludedProject))
        }
    }

    func testPhysicalTemporaryRootArchivesWithoutProjectExclusions_repro() throws {
        for source in [SourceName.pi, .qwen] {
            let format: SourceMetadataProjection.Format = source == .pi ? .pi : .qwen
            func bytes(_ cwd: String) throws -> Data {
                let record: [String: Any] = source == .pi
                    ? ["type": "session", "id": "native", "cwd": cwd]
                    : ["type": "assistant", "sessionId": "native", "cwd": cwd,
                       "message": ["parts": [["text": "answer"]]]]
                return try JSONSerialization.data(withJSONObject: record) + Data([10])
            }
            let fixture = try capture(bytes("/private/tmp"), source: source)
            let unrestricted = try policy(sources: [source])
            let result = try assess(fixture, format: format, policy: unrestricted)
            if case .eligible(let proof) = result {
                XCTAssertEqual(proof.projectRoot, "/private/tmp")
                XCTAssertTrue(proof.isCurrent(for: fixture.result, policy: unrestricted, format: format))
                let excluded = try policy(excluded: ["/unrelated"], sources: [source])
                XCTAssertFalse(proof.isCurrent(for: fixture.result, policy: excluded, format: format))
                XCTAssertEqual(try assess(fixture, format: format, policy: excluded), .withheld(.excludedProject))
            } else { XCTFail("Physical temporary root should authorize: \(source): \(result)") }
            for invalid in ["/private/tmp/../tmp", "/private//tmp", "/private/tmp/", "relative", "/"] {
                let invalidFixture = try capture(bytes(invalid), source: source)
                XCTAssertEqual(try assess(invalidFixture, format: format, policy: unrestricted), .withheld(.invalidProjectRoot))
            }
        }
    }

    func testGeminiFilesystemRootArchivesWithoutProjectExclusions_repro() throws {
        let fixture = try captureGemini(nativeRoot: "/", derivedRoot: nil)
        let unrestricted = try policy(sources: [.geminiCli])
        let proof = try eligible(assess(fixture, format: .geminiCli, policy: unrestricted))
        XCTAssertEqual(proof.projectRoot, "/")
        XCTAssertTrue(proof.isCurrent(for: fixture.result, policy: unrestricted, format: .geminiCli))
        let excluded = try policy(excluded: ["/unrelated"], sources: [.geminiCli])
        XCTAssertFalse(proof.isCurrent(for: fixture.result, policy: excluded, format: .geminiCli))
        XCTAssertEqual(try assess(fixture, format: .geminiCli, policy: excluded), .withheld(.excludedProject))
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

    func testCodexExplicitForkedFromIdAncestryIsEligibleAndNegativesStayWithheld_repro() throws {
        func meta(id: Any, cwd: String, fork: Any? = nil) throws -> Data {
            var payload: [String: Any] = ["id": id, "cwd": cwd, "timestamp": "2026-09-05T00:00:00Z"]
            if let fork { payload["forked_from_id"] = fork }
            return try JSONSerialization.data(
                withJSONObject: ["type": "session_meta", "payload": payload], options: [.sortedKeys]
            ) + Data([10])
        }
        let reply = try JSONSerialization.data(
            withJSONObject: ["type": "response_item",
                             "payload": ["type": "message", "role": "assistant",
                                         "content": [["type": "output_text", "text": "answer"]]]],
            options: [.sortedKeys]
        ) + Data([10])
        let linked = try meta(id: "child", cwd: "/allowed", fork: "parent")
            + meta(id: "parent", cwd: "/allowed")
            + meta(id: "parent", cwd: "/allowed")
            + reply
        let proof = try eligible(assess(capture(linked, source: .codex), format: .codex))
        XCTAssertEqual(proof.nativeSessionID, "child")
        XCTAssertEqual(proof.projectRoot, "/allowed")
        XCTAssertEqual(proof.source, .codex)

        let chain = try meta(id: "child", cwd: "/allowed", fork: "parent")
            + meta(id: "parent", cwd: "/allowed", fork: "grand")
            + meta(id: "grand", cwd: "/allowed")
            + reply
        XCTAssertEqual(try eligible(assess(capture(chain, source: .codex), format: .codex)).nativeSessionID, "child")

        let unlinked = try meta(id: "child", cwd: "/allowed", fork: "parent")
            + meta(id: "other", cwd: "/allowed")
            + reply
        XCTAssertEqual(try assess(capture(unlinked, source: .codex), format: .codex), .withheld(.conflictingSourceIdentity))

        let composed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        let byteMismatch = try meta(id: "child", cwd: "/allowed", fork: composed)
            + meta(id: decomposed, cwd: "/allowed")
            + reply
        XCTAssertEqual(try assess(capture(byteMismatch, source: .codex), format: .codex),
                       .withheld(.conflictingSourceIdentity))

        let differingRoot = try meta(id: "child", cwd: "/allowed", fork: "parent")
            + meta(id: "parent", cwd: "/other")
            + reply
        XCTAssertEqual(try assess(capture(differingRoot, source: .codex), format: .codex),
                       .withheld(.conflictingProjectRoots))

        let mixed = try meta(id: "child", cwd: "/allowed", fork: "parent")
            + meta(id: "parent", cwd: "/allowed")
            + Data("{\"type\":\"user\",\"sessionId\":\"child\"}\n".utf8)
        XCTAssertEqual(try assess(capture(mixed, source: .codex), format: .codex),
                       .withheld(.conflictingSourceIdentity))

        let malformed = try meta(id: "child", cwd: "/allowed", fork: 1) + reply
        XCTAssertEqual(try assess(capture(malformed, source: .codex), format: .codex),
                       .withheld(.missingNativeIdentity))
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

    func testExactSyntheticAfterMinimaxStaysEligibleAndRealClaudeStillConflicts_repro() throws {
        let format = SourceMetadataProjection.Format.claudeCode(forceClaudeCodeSource: false)
        let enabled = try policy(sources: [.claudeCode, .codex, .minimax])
        let minimax = try transcript(format: format, cwd: "/allowed", model: "MiniMax-M2.1")
        let synthetic = try transcript(format: format, cwd: "/allowed", model: "<synthetic>")
        let claude = try transcript(format: format, cwd: "/allowed", model: "claude-sonnet-4")

        let placeholder = try capture(minimax + synthetic, source: .minimax)
        let proof = try eligible(assess(placeholder, format: format, policy: enabled))
        XCTAssertEqual(proof.source, .minimax)
        XCTAssertEqual(proof.projectRoot, "/allowed")
        XCTAssertEqual(proof.nativeSessionID, "native")
        XCTAssertTrue(proof.isCurrent(for: placeholder.result, policy: enabled, format: format))

        let afterClaude = try capture(minimax + synthetic + claude, source: .minimax)
        XCTAssertEqual(try assess(afterClaude, format: format, policy: enabled), .withheld(.conflictingSourceIdentity))
        let genuine = try capture(minimax + claude, source: .minimax)
        XCTAssertEqual(try assess(genuine, format: format, policy: enabled), .withheld(.conflictingSourceIdentity))
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
        for unsafe in [linked.path, destination.path + "/../allowed"] {
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

    func testQwenProofBindsNativeFormatAndWithholdsInvalidOrConflictingEvidence() throws {
        func record(_ changes: [String: Any] = [:]) throws -> Data {
            let base: [String: Any] = ["type": "assistant", "sessionId": "native-qwen", "cwd": "/allowed",
                "model": "MiniMax-M2.1", "message": ["parts": [["text": "qwen content"]]]]
            return try JSONSerialization.data(withJSONObject: base.merging(changes) { _, new in new },
                options: [.sortedKeys]) + Data([10])
        }
        let bytes = try record()
        let fixture = try capture(bytes, source: .qwen)
        let qwenPolicy = try policy(sources: [.qwen])
        let proof = try eligible(assess(fixture, format: .qwen, policy: qwenPolicy))
        XCTAssertEqual(proof.source, .qwen)
        XCTAssertEqual(proof.nativeSessionID, "native-qwen")
        XCTAssertEqual(proof.wholeSourceSHA256, ArchiveV2Hash.sha256(bytes))
        XCTAssertTrue(proof.isCurrent(for: fixture.result, policy: qwenPolicy, format: .qwen))
        XCTAssertFalse(proof.isCurrent(for: fixture.result, policy: qwenPolicy,
            format: .claudeCode(forceClaudeCodeSource: true)))
        XCTAssertEqual(try assess(fixture, format: .qwen, policy: policy(sources: [.codex])), .withheld(.unsupportedSource))
        XCTAssertEqual(try assess(fixture, format: .qwen, policy: policy(excluded: ["/allowed"], sources: [.qwen])),
            .withheld(.excludedProject))
        for (raw, expected) in [
            (try bytes + record(["cwd": "/other"]), CollectorPrivacyWithheldReason.conflictingProjectRoots),
            (try bytes + record(["sessionId": "different"]), .conflictingSourceIdentity),
            (try record(["cwd": "relative"]), .invalidProjectRoot),
            (try record(["sessionId": 42]), .missingNativeIdentity),
            (bytes + Data("not-json\n".utf8), .malformedMetadata),
            (Data(bytes.dropLast()), .incompleteMetadata),
        ] {
            let rejected = try capture(raw, source: .qwen)
            XCTAssertEqual(try assess(rejected, format: .qwen, policy: qwenPolicy), .withheld(expected))
        }
    }

    func testPiProofBindsSessionCwdAndWithholdsExcludedOrConflictingEvidence_repro() throws {
        func record(_ changes: [String: Any] = [:]) throws -> Data {
            let session: [String: Any] = ["type": "session", "id": "019dd6e3-91d1-7326-8299-314858773a0e",
                "cwd": "/allowed", "timestamp": "2026-04-29T01:00:00.000Z"]
            let message: [String: Any] = ["type": "message", "id": "msg-user",
                "message": ["role": "user", "content": [["type": "text", "text": "Fix the Pi parser"]]]]
            let sessionLine = try JSONSerialization.data(
                withJSONObject: session.merging(changes) { _, new in new }, options: [.sortedKeys]
            ) + Data([10])
            let messageLine = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]) + Data([10])
            return sessionLine + messageLine
        }
        let bytes = try record()
        let fixture = try capture(bytes, source: .pi)
        let piPolicy = try policy(sources: [.pi])
        let proof = try eligible(assess(fixture, format: .pi, policy: piPolicy))
        XCTAssertEqual(proof.source, .pi)
        XCTAssertEqual(proof.nativeSessionID, "019dd6e3-91d1-7326-8299-314858773a0e")
        XCTAssertEqual(proof.projectRoot, "/allowed")
        XCTAssertEqual(proof.wholeSourceSHA256, ArchiveV2Hash.sha256(bytes))
        XCTAssertTrue(proof.isCurrent(for: fixture.result, policy: piPolicy, format: .pi))
        XCTAssertFalse(proof.isCurrent(for: fixture.result, policy: piPolicy, format: .qwen))
        XCTAssertEqual(try assess(fixture, format: .pi, policy: policy(sources: [.qwen])), .withheld(.unsupportedSource))
        XCTAssertEqual(try assess(fixture, format: .pi, policy: policy(excluded: ["/allowed"], sources: [.pi])),
            .withheld(.excludedProject))
        for (raw, expected) in [
            (try bytes + record(["cwd": "/other"]), CollectorPrivacyWithheldReason.conflictingProjectRoots),
            (try bytes + record(["id": "different"]), .conflictingSourceIdentity),
            (try record(["cwd": "relative"]), .invalidProjectRoot),
            (try record(["id": 42]), .missingNativeIdentity),
            (bytes + Data("not-json\n".utf8), .malformedMetadata),
            (Data(bytes.dropLast()), .incompleteMetadata),
        ] {
            let rejected = try capture(raw, source: .pi)
            XCTAssertEqual(try assess(rejected, format: .pi, policy: piPolicy), .withheld(expected))
        }
    }

    func testQoderIflowAndCommandCodeProofsWithholdConflictsAndBindNativeSource() throws {
        for (source, format) in [(SourceName.qoder, SourceMetadataProjection.Format.qoder), (.iflow, .iflow), (.commandcode, .commandcode)] {
            func record(_ changes: [String: Any] = [:]) throws -> Data {
                var base: [String: Any] = ["sessionId": "native", "cwd": "/allowed"]
                if source == .qoder || source == .iflow {
                    base["type"] = "assistant"
                    base["message"] = ["model": "MiniMax-M2.1", "content": "qoder reply"]
                } else {
                    base["role"] = "assistant"
                    base["metadata"] = ["model": "command-code-agent"]
                    base["content"] = [["type": "text", "text": "command reply"]]
                }
                return try JSONSerialization.data(withJSONObject: base.merging(changes) { _, new in new },
                    options: [.sortedKeys]) + Data([10])
            }
            let bytes = try record()
            let fixture = try capture(bytes, source: source)
            let enabled = try policy(sources: [source])
            let proof = try eligible(assess(fixture, format: format, policy: enabled))
            XCTAssertEqual(proof.source, source)
            XCTAssertEqual(proof.nativeSessionID, "native")
            XCTAssertEqual(proof.wholeSourceSHA256, ArchiveV2Hash.sha256(bytes))
            XCTAssertTrue(proof.isCurrent(for: fixture.result, policy: enabled, format: format))
            XCTAssertFalse(proof.isCurrent(for: fixture.result, policy: enabled, format: .claudeCode(forceClaudeCodeSource: true)))
            XCTAssertEqual(try assess(fixture, format: format, policy: policy()), .withheld(.unsupportedSource))
            XCTAssertEqual(try assess(fixture, format: format, policy: policy(excluded: ["/allowed"], sources: [source])), .withheld(.excludedProject))
            for (raw, expected) in [
                (try bytes + record(["cwd": "/other"]), CollectorPrivacyWithheldReason.conflictingProjectRoots),
                (try bytes + record(["sessionId": "different"]), .conflictingSourceIdentity),
                (try record(["cwd": "relative"]), .invalidProjectRoot),
                (try record(["sessionId": 42]), .missingNativeIdentity),
                (bytes + Data("not-json\n".utf8), .malformedMetadata),
                (Data(bytes.dropLast()), .incompleteMetadata),
            ] {
                XCTAssertEqual(try assess(capture(raw, source: source), format: format, policy: enabled), .withheld(expected), source.rawValue)
            }
        }
    }

    func testCommandCodeLossySlugCanPublishOnlyWithoutProjectExclusions_repro() throws {
        let bytes = Data("{\"role\":\"user\",\"sessionId\":\"native\",\"content\":\"request\"}\n".utf8)
        let fixture = try capture(bytes, source: .commandcode, directory: "users-bing-code-project")
        let unrestricted = try policy(sources: [.commandcode])
        let proof = try eligible(assess(fixture, format: .commandcode, policy: unrestricted))
        XCTAssertNil(proof.projectRoot)
        XCTAssertTrue(proof.isCurrent(for: fixture.result, policy: unrestricted, format: .commandcode))
        let excluded = try policy(excluded: ["/private/project"], sources: [.commandcode])
        XCTAssertFalse(proof.isCurrent(for: fixture.result, policy: excluded, format: .commandcode))
        XCTAssertEqual(try assess(fixture, format: .commandcode, policy: excluded), .withheld(.invalidProjectRoot))

        for cwd in ["relative/project", "/", "/private/project"] {
            let object: [String: Any] = ["role": "user", "sessionId": "native", "content": "request", "cwd": cwd]
            var invalid = try JSONSerialization.data(withJSONObject: object)
            invalid.append(10)
            let captured = try capture(invalid, source: .commandcode, directory: "users-bing-code-project")
            XCTAssertEqual(try assess(captured, format: .commandcode, policy: excluded),
                           .withheld(cwd == "/private/project" ? .excludedProject : .invalidProjectRoot))
        }
    }

    func testCommandCodeSlugPrivacyFallbackYieldsToLaterExplicitCwd() throws {
        let first = Data("{\"role\":\"user\",\"sessionId\":\"native\",\"content\":\"request\"}\n".utf8)
        let later = Data("{\"role\":\"assistant\",\"sessionId\":\"native\",\"cwd\":\"/explicit-project\",\"content\":\"reply\"}\n".utf8)
        let policy = try policy(excluded: ["/Users/test/my-project"], sources: [.commandcode])
        let slug = try capture(first, source: .commandcode, directory: "-Users-test-my--project")
        XCTAssertEqual(try assess(slug, format: .commandcode, policy: policy), .withheld(.excludedProject))
        let explicit = try capture(first + later, source: .commandcode, directory: "-Users-test-my--project")
        XCTAssertEqual(try eligible(assess(explicit, format: .commandcode, policy: policy)).projectRoot, "/explicit-project")
    }

    func testCopilotProofUsesNativeDirectoryIdentityWithoutWorkspaceID() throws {
        for workspace in [nil, "cwd: /allowed\nsummary: native fallback\n"] as [String?] {
            let fixture = try captureCopilot(workspace: workspace)
            let enabled = try policy(sources: [.copilot])
            let proof = try eligible(assess(fixture, format: .copilot, policy: enabled))
            XCTAssertEqual(proof.nativeSessionID, "session-native")
            XCTAssertEqual(proof.projectRoot, "/allowed")
            XCTAssertEqual(proof.source, .copilot)
        }
    }

    func testCopilotCheckpointOnlyProofUsesDirectoryIdentityWithoutWorkspaceID() throws {
        let fixture = try captureCopilot(workspace: "cwd: /allowed\n", checkpoint: true)
        let proof = try eligible(assess(fixture, format: .copilot, policy: policy(sources: [.copilot])))
        XCTAssertEqual(proof.nativeSessionID, "session-native")
        XCTAssertEqual(proof.projectRoot, "/allowed")
    }

    func testCopilotExplicitEmptyWorkspaceIdentityDoesNotBecomeDirectoryFallback() throws {
        let fixture = try captureCopilot(workspace: "id: ''\ncwd: /allowed\n")
        XCTAssertEqual(try assess(fixture, format: .copilot, policy: policy(sources: [.copilot])),
            .withheld(.missingNativeIdentity))
    }

    func testCopilotProofUsesCapturedWorkspaceAndChecksEveryObservedRoot() throws {
        let fixture = try captureCopilot(workspace: "id: yaml-native\ncwd: /allowed\n")
        let enabled = try policy(excluded: ["/excluded"], sources: [.copilot])
        let proof = try eligible(assess(fixture, format: .copilot, policy: enabled))
        XCTAssertEqual(proof.nativeSessionID, "yaml-native")
        let workspace = fixture.sourceURL.deletingLastPathComponent().appendingPathComponent("workspace.yaml")
        try Data("id: forged-live\ncwd: /excluded\n".utf8).write(to: workspace)
        XCTAssertEqual(try eligible(assess(fixture, format: .copilot, policy: enabled)), proof)
        try FileManager.default.removeItem(at: fixture.sourceURL.deletingLastPathComponent())
        XCTAssertEqual(try eligible(assess(fixture, format: .copilot, policy: enabled)), proof)
        for (yaml, roots) in [("id: native\ncwd: /excluded\n", ["/allowed"]),
                              ("id: native\ncwd: /allowed\n", ["/allowed", "/excluded/child"])] {
            let denied = try captureCopilot(workspace: yaml, eventRoots: roots)
            XCTAssertEqual(try assess(denied, format: .copilot, policy: enabled), .withheld(.excludedProject))
        }
    }

    func testGrokProofUsesCASIdentityAndPathDecodeAfterOriginalsDisappear_repro() throws {
        let fixture = try captureGrok(
            project: "%2Fallowed",
            summaryCWD: "/allowed",
            promptCWD: nil
        )
        try FileManager.default.removeItem(at: fixture.sourceURL.deletingLastPathComponent().deletingLastPathComponent())
        let enabled = try policy(sources: [.grok])
        let proof = try eligible(assess(fixture, format: .grok, policy: enabled))
        XCTAssertEqual(proof.source, .grok)
        XCTAssertEqual(proof.nativeSessionID, "019dd6e3-91d1-7326-8299-314858773a0e")
        XCTAssertEqual(proof.projectRoot, "/allowed")
        XCTAssertTrue(proof.isCurrent(for: fixture.result, policy: enabled, format: .grok))
        XCTAssertEqual(try assess(fixture, format: .grok, policy: policy(sources: [.pi])), .withheld(.unsupportedSource))
        XCTAssertEqual(try assess(fixture, format: .grok, policy: policy(excluded: ["/allowed"], sources: [.grok])),
            .withheld(.excludedProject))
    }

    func testGrokPrivacyDoesNotBufferLargeAuxiliaryHistory() throws {
        let fixture = try captureGrok(project: "project", summaryCWD: "/allowed", promptCWD: nil,
                                      auxiliaryBytes: 128 * 1024 * 1024)
        var before = rusage()
        XCTAssertEqual(getrusage(RUSAGE_SELF, &before), 0)
        _ = try eligible(assess(fixture, format: .grok, policy: policy(sources: [.grok])))
        var after = rusage()
        XCTAssertEqual(getrusage(RUSAGE_SELF, &after), 0)
        let growth = after.ru_maxrss - before.ru_maxrss
        print("GROK_PRIVACY_PEAK_GROWTH_BYTES=\(growth)")
        XCTAssertLessThan(growth, 64 * 1024 * 1024,
            "privacy metadata assessment must not retain the entire 128 MiB auxiliary history")
    }

    func testGrokMissingMetadataPathDecodeHonorsExcludedProject_repro() throws {
        let fixture = try captureGrok(project: "%2Fexcluded%2Fsecret", summaryCWD: nil, promptCWD: nil, includeSummary: false, includePrompt: false)
        XCTAssertEqual(try assess(fixture, format: .grok, policy: policy(excluded: ["/excluded"], sources: [.grok])),
            .withheld(.excludedProject))
        let allowed = try eligible(assess(fixture, format: .grok, policy: policy(sources: [.grok])))
        XCTAssertEqual(allowed.projectRoot, "/excluded/secret")
        XCTAssertEqual(allowed.nativeSessionID, "019dd6e3-91d1-7326-8299-314858773a0e")
    }

    func testGrokSummaryCwdWinsOverEncodedProjectDirectory_repro() throws {
        let fixture = try captureGrok(project: "%2Fexcluded%2Fsecret", summaryCWD: "/allowed", promptCWD: "/also-ignored")
        let proof = try eligible(assess(fixture, format: .grok,
            policy: policy(excluded: ["/excluded"], sources: [.grok])))
        XCTAssertEqual(proof.projectRoot, "/allowed")
    }

    func testGeminiProofUsesCapturedNativeRootAfterOriginalFilesDisappear() throws {
        let fixture = try captureGemini(nativeRoot: "/allowed", derivedRoot: nil)
        try FileManager.default.removeItem(at: fixture.sourceURL.deletingLastPathComponent().deletingLastPathComponent())
        let proof = try eligible(assess(fixture, format: .geminiCli, policy: policy(sources: [.geminiCli])))
        XCTAssertEqual(proof.nativeSessionID, "native-id")
        XCTAssertEqual(proof.projectRoot, "/allowed")
    }

    func testGeminiDerivedContextCannotBypassExcludedNativeProjectRoot() throws {
        let fixture = try captureGemini(nativeRoot: "/excluded", derivedRoot: "/allowed")
        XCTAssertEqual(try assess(fixture, format: .geminiCli,
            policy: policy(excluded: ["/excluded"], sources: [.geminiCli])), .withheld(.excludedProject))
    }

    func testGeminiPrivacyRejectsSidecarWitnessForWrongNativeIdentity() throws {
        let fixture = try captureGemini(nativeRoot: "/allowed", derivedRoot: nil, wrongSidecar: true)
        XCTAssertEqual(try assess(fixture, format: .geminiCli, policy: policy(sources: [.geminiCli])),
            .withheld(.invalidCapture))
    }

    private func captureGrok(
        project: String,
        summaryCWD: String?,
        promptCWD: String?,
        includeSummary: Bool = true,
        includePrompt: Bool = true,
        auxiliaryBytes: Int = 0
    ) throws -> Fixture {
        let physical = try XCTUnwrap(realpath(root.path, nil))
        defer { free(physical) }
        let sourceRoot = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent("grok-" + UUID().uuidString)
        let session = "019dd6e3-91d1-7326-8299-314858773a0e"
        let sessionDir = sourceRoot.appendingPathComponent(project).appendingPathComponent(session)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let chat = sessionDir.appendingPathComponent("chat_history.jsonl")
        try Data("{\"type\":\"user\",\"content\":\"<user_query>Inspect</user_query>\"}\n".utf8).write(to: chat)
        var files = [chat]
        var absent = [sessionDir.appendingPathComponent("compaction/INDEX.md")]
        let updates = sessionDir.appendingPathComponent("updates.jsonl")
        if auxiliaryBytes > 0 {
            XCTAssertTrue(FileManager.default.createFile(atPath: updates.path, contents: nil))
            let handle = try FileHandle(forWritingTo: updates)
            defer { try? handle.close() }
            let block = Data(repeating: 0x20, count: 1024 * 1024)
            for _ in 0..<(auxiliaryBytes / block.count) { try handle.write(contentsOf: block) }
            try handle.synchronize()
            files.append(updates)
        } else {
            absent.append(updates)
        }
        if includeSummary {
            var info: [String: Any] = ["id": session]
            if let summaryCWD { info["cwd"] = summaryCWD }
            let bytes = try JSONSerialization.data(withJSONObject: ["info": info], options: [.sortedKeys])
            let url = sessionDir.appendingPathComponent("summary.json")
            try bytes.write(to: url)
            files.append(url)
        } else {
            absent.append(sessionDir.appendingPathComponent("summary.json"))
        }
        if includePrompt {
            var object: [String: Any] = [:]
            if let promptCWD { object["working_directory"] = promptCWD }
            let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let url = sessionDir.appendingPathComponent("prompt_context.json")
            try bytes.write(to: url)
            files.append(url)
        } else {
            absent.append(sessionDir.appendingPathComponent("prompt_context.json"))
        }
        let storeRoot = root.appendingPathComponent("shadow-" + UUID().uuidString)
        let cas = try ImmutableArchiveCAS(root: storeRoot)
        let catalog = try ArchiveCatalog(root: storeRoot, machineID: machineID)
        try catalog.migrate()
        defer { try? catalog.close() }
        let descriptor = try ArchiveSourceDescriptor.fileSet(locator: chat.path, root: sourceRoot,
            files: files, absentFiles: absent)
        let result = try ExactSourceCapturer(cas: cas, catalog: catalog, descriptor: descriptor)
            .capture(source: .grok, locator: chat.path, machineID: machineID)
        XCTAssertTrue(ArchiveSourceDescriptor.isGrokFileSet(result.manifest))
        return Fixture(sourceURL: chat, storeRoot: storeRoot, cas: cas, result: result)
    }

    private func captureGemini(nativeRoot: String, derivedRoot: String?, wrongSidecar: Bool = false) throws -> Fixture {
        let physical = try XCTUnwrap(realpath(root.path, nil))
        defer { free(physical) }
        let sourceRoot = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent("gemini-" + UUID().uuidString)
        let chats = sourceRoot.appendingPathComponent("project/chats")
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let source = chats.appendingPathComponent("stem.json")
        let bytes = try JSONSerialization.data(withJSONObject: ["sessionId": "native-id",
            "startTime": "2026-09-08T00:00:00Z", "messages": [["type": "user", "content": "question"]]])
        try bytes.write(to: source)
        let projectRoot = sourceRoot.appendingPathComponent("project/.project_root")
        try Data(nativeRoot.utf8).write(to: projectRoot)
        let context = try derivedRoot.map { cwd in
            try ArchiveGeminiProjectContext(projectName: "project", cwd: cwd,
                registryLocator: "/fictional/projects.json", registryGeneration: ArchiveSourceGeneration(
                    device: 1, inode: 2, size: 0, mtimeNs: 3, ctimeNs: 4, mode: 0o100600),
                registrySHA256: ArchiveV2Hash.sha256(Data()))
        }
        let storeRoot = root.appendingPathComponent("shadow-" + UUID().uuidString)
        let cas = try ImmutableArchiveCAS(root: storeRoot)
        let catalog = try ArchiveCatalog(root: storeRoot, machineID: machineID)
        try catalog.migrate()
        let descriptor = try ArchiveSourceDescriptor.fileSet(locator: source.path, root: sourceRoot,
            files: [projectRoot, source],
            absentFiles: [chats.appendingPathComponent(wrongSidecar ? "stem.engram.json" : "native-id.engram.json")],
            geminiProjectContext: context)
        let result = try ExactSourceCapturer(cas: cas, catalog: catalog, descriptor: descriptor)
            .capture(source: .geminiCli, locator: source.path, machineID: machineID)
        return Fixture(sourceURL: source, storeRoot: storeRoot, cas: cas, result: result)
    }

    private func captureCopilot(workspace: String?, eventRoots: [String] = ["/allowed"], checkpoint: Bool = false) throws -> Fixture {
        let physical = try XCTUnwrap(realpath(root.path, nil))
        defer { free(physical) }
        let sourceRoot = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent("native-\(UUID().uuidString)")
        let session = sourceRoot.appendingPathComponent("session-native")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let sourceURL = session.appendingPathComponent("events.jsonl")
        var bytes = Data()
        for cwd in eventRoots {
            bytes.append(try JSONSerialization.data(withJSONObject: ["type": "session.start", "data": ["context": ["cwd": cwd]]]))
            bytes.append(10)
        }
        if !checkpoint {
            bytes.append(Data("{\"type\":\"user.message\",\"data\":{\"content\":\"native question\"}}\n".utf8))
        }
        try bytes.write(to: sourceURL)
        let workspaceURL = session.appendingPathComponent("workspace.yaml")
        var files = [sourceURL]
        var absent = [session.appendingPathComponent("checkpoints/index.md")]
        if let workspace {
            try Data(workspace.utf8).write(to: workspaceURL)
            files.append(workspaceURL)
        } else { absent.append(workspaceURL) }
        let storeRoot = root.appendingPathComponent("shadow-\(UUID().uuidString)")
        let cas = try ImmutableArchiveCAS(root: storeRoot)
        let catalog = try ArchiveCatalog(root: storeRoot, machineID: machineID)
        try catalog.migrate()
        var primary = sourceURL
        if checkpoint {
            let directory = session.appendingPathComponent("checkpoints")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            primary = directory.appendingPathComponent("index.md")
            let body = directory.appendingPathComponent("001.md")
            try Data("| 1 | Native saved conversation | 001.md |\n".utf8).write(to: primary)
            try Data("Checkpoint content.\n".utf8).write(to: body)
            files += [primary, body]
            absent.removeAll { $0.lastPathComponent == "index.md" }
        }
        let descriptor = try ArchiveSourceDescriptor.fileSet(locator: primary.path, root: sourceRoot, files: files, absentFiles: absent)
        let result = try ExactSourceCapturer(cas: cas, catalog: catalog, descriptor: descriptor)
            .capture(source: .copilot, locator: primary.path, machineID: machineID)
        return Fixture(sourceURL: sourceURL, storeRoot: storeRoot, cas: cas, result: result)
    }

    func testVSCodePrivacyUsesFrozenWorkspaceAndChecksEveryFolder() throws {
        let fixture = try captureVSCode(roots: ["/allowed/main", "/allowed/second"])
        try FileManager.default.removeItem(at: fixture.sourceURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
        let allowed = try policy(sources: [.vscode])
        let proof = try eligible(assess(fixture, format: .vscode, policy: allowed))
        XCTAssertEqual(proof.nativeSessionID, "last")
        XCTAssertEqual(proof.projectRoot, "/allowed/main")
        XCTAssertTrue(proof.isCurrent(for: fixture.result, policy: allowed, format: .vscode))
        let excluded = try policy(excluded: ["/allowed/second"], sources: [.vscode])
        XCTAssertEqual(try assess(fixture, format: .vscode, policy: excluded), .withheld(.excludedProject))
        XCTAssertFalse(proof.isCurrent(for: fixture.result, policy: excluded, format: .vscode))
        XCTAssertEqual(try assess(fixture, format: .vscode), .withheld(.unsupportedSource))
    }

    func testVSCodePrivacyAcceptsFrozenFolderUriWithoutExternalConfiguration() throws {
        let fixture = try captureVSCode(roots: [], folderURI: "file://localhost/allowed%20project")
        XCTAssertNil(fixture.result.manifest.replayLayout.vscodeWorkspaceContext?.configurationLocator)
        let proof = try eligible(assess(fixture, format: .vscode, policy: policy(sources: [.vscode])))
        XCTAssertEqual(proof.projectRoot, "/allowed project")
        XCTAssertEqual(proof.nativeSessionID, "last")
    }

    func testVSCodePrivacyWithholdsAbsentUnknownAndRemoteRoots() throws {
        let allowed = try policy(sources: [.vscode])
        for fixture in [try captureVSCode(roots: [], configurationPresent: false),
                        try captureVSCode(roots: []),
                        try captureVSCode(roots: [], folderURI: "vscode-remote://host/project")] {
            XCTAssertEqual(try assess(fixture, format: .vscode, policy: allowed), .withheld(.invalidProjectRoot))
        }
    }

    func testVSCodePrivacyBudgetsIncludeExternalConfigurationAndAllRoots() throws {
        let fixture = try captureVSCode(roots: ["/allowed/main", "/allowed/second"])
        let allowed = try policy(sources: [.vscode])
        for limits in [CollectorPrivacyLimits(maxSourceBytes: fixture.result.manifest.rawByteCount),
                       .init(maxLineBytes: 1), .init(maxRecords: 1), .init(maxProjectRoots: 1),
                       .init(maxTotalProjectRootBytes: 1)] {
            XCTAssertEqual(try assess(fixture, format: .vscode, policy: allowed, limits: limits), .withheld(.limitsExceeded))
        }
    }

    func testVSCodePrivacyRejectsIncompleteMalformedAndInvalidMutationRecords() throws {
        let allowed = try policy(sources: [.vscode])
        let initial = #"{"kind":0,"v":{"sessionId":"native","requests":[]}}"#
        for (raw, expected) in [(initial, CollectorPrivacyWithheldReason.incompleteMetadata),
                                (initial + "\n{bad}\n", .malformedMetadata),
                                (initial + "\n" + #"{"kind":1,"k":["requests",1000001],"v":{}}"# + "\n", .malformedMetadata)] {
            let fixture = try captureVSCode(roots: ["/allowed"], raw: Data(raw.utf8))
            XCTAssertEqual(try assess(fixture, format: .vscode, policy: allowed), .withheld(expected))
        }
        let fixture = try captureVSCode(roots: ["/allowed"])
        _ = try fixture.cas.removeObject(sha256: XCTUnwrap(fixture.result.manifest.chunks.first).rawSHA256)
        XCTAssertEqual(try assess(fixture, format: .vscode, policy: allowed), .withheld(.invalidCapture))
    }

    private func captureVSCode(roots: [String], raw: Data? = nil, configurationPresent: Bool = true,
                               folderURI: String? = nil) throws -> Fixture {
        let physical = try XCTUnwrap(realpath(root.path, nil))
        defer { free(physical) }
        let sourceRoot = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent("vscode-" + UUID().uuidString)
        let source = sourceRoot.appendingPathComponent("ws/chatSessions/native.jsonl")
        let workspace = sourceRoot.appendingPathComponent("ws/workspace.json")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = [#"{"kind":0,"v":{"sessionId":"first","creationDate":1700000000000,"requests":[{"message":{"text":"question"}}]}}"#,
                     #"{"kind":1,"k":["sessionId"],"v":"last"}"#]
        try (raw ?? Data((lines.joined(separator: "\n") + "\n").utf8)).write(to: source)
        let context: ArchiveVSCodeWorkspaceContext
        if let folderURI {
            context = try ArchiveVSCodeWorkspaceContext()
            try JSONSerialization.data(withJSONObject: ["folder": folderURI]).write(to: workspace)
        } else {
            let bytes = try JSONSerialization.data(withJSONObject: ["folders": roots.map { ["path": $0] }])
            context = try ArchiveVSCodeWorkspaceContext(configurationLocator: "/frozen/project.code-workspace",
                configurationGeneration: configurationPresent ? ArchiveSourceGeneration(device: 1, inode: 2,
                    size: Int64(bytes.count), mtimeNs: 3, ctimeNs: 4, mode: 0o100600) : nil,
                configurationData: configurationPresent ? bytes : nil,
                configurationSHA256: configurationPresent ? ArchiveV2Hash.sha256(bytes) : nil)
            try Data(#"{"configuration":"file:///frozen/project.code-workspace"}"#.utf8).write(to: workspace)
        }
        let storeRoot = root.appendingPathComponent("shadow-" + UUID().uuidString)
        let cas = try ImmutableArchiveCAS(root: storeRoot)
        let catalog = try ArchiveCatalog(root: storeRoot, machineID: machineID)
        try catalog.migrate()
        defer { try? catalog.close() }
        let descriptor = try ArchiveSourceDescriptor.fileSet(locator: source.path, root: sourceRoot,
            files: [source, workspace], vscodeWorkspaceContext: context)
        let result = try ExactSourceCapturer(cas: cas, catalog: catalog, descriptor: descriptor)
            .capture(source: .vscode, locator: source.path, machineID: machineID)
        return Fixture(sourceURL: source, storeRoot: storeRoot, cas: cas, result: result)
    }

    func testClineFrozenArrayPrivacyPreservesTaskIdentityAfterSourceRemoval() throws {
        for legacy in [false, true] {
            let fixture = try captureCline(try clineBytes(roots: ["/allowed/project(with)paren"]), legacy: legacy)
            try FileManager.default.removeItem(at: fixture.sourceURL.deletingLastPathComponent())
            let allowed = try policy(sources: [.cline])
            let proof = try eligible(assess(fixture, format: .cline, policy: allowed))
            XCTAssertEqual(proof.nativeSessionID, "task-native")
            XCTAssertEqual(proof.projectRoot, "/allowed/project(with)paren")
            XCTAssertTrue(proof.isCurrent(for: fixture.result, policy: allowed, format: .cline))
            XCTAssertEqual(try assess(fixture, format: .cline,
                policy: policy(excluded: ["/allowed"], sources: [.cline])), .withheld(.excludedProject))
            XCTAssertEqual(try assess(fixture, format: .cline), .withheld(.unsupportedSource))
        }
    }

    func testClineArrayPrivacyRejectsConflictingAndInvalidRoots() throws {
        let allowed = try policy(sources: [.cline])
        let conflict = try captureCline(try clineBytes(roots: ["/allowed", "/excluded"]))
        XCTAssertEqual(try assess(conflict, format: .cline, policy: allowed), .withheld(.conflictingProjectRoots))
        let invalid = try captureCline(try clineBytes(roots: ["Primary: /allowed"]))
        XCTAssertEqual(try assess(invalid, format: .cline, policy: allowed), .withheld(.invalidProjectRoot))
    }

    func testClineArrayPrivacyRejectsMalformedAndBoundedInputs() throws {
        let allowed = try policy(sources: [.cline])
        for raw in ["", "{}", "[{}", "[{},]", "[42]", "[{}]trailing"] {
            let fixture = try captureCline(Data(raw.utf8))
            XCTAssertEqual(try assess(fixture, format: .cline, policy: allowed), .withheld(.malformedMetadata), raw)
        }
        let fixture = try captureCline(try clineBytes(roots: ["/allowed"]))
        for limits in [CollectorPrivacyLimits(maxSourceBytes: 1), .init(maxLineBytes: 1),
                       .init(maxRecords: 1), .init(maxProjectRoots: 0), .init(maxTotalProjectRootBytes: 1)] {
            XCTAssertEqual(try assess(fixture, format: .cline, policy: allowed, limits: limits), .withheld(.limitsExceeded))
        }
        let chunk = try XCTUnwrap(fixture.result.manifest.chunks.first)
        _ = try fixture.cas.removeObject(sha256: chunk.rawSHA256)
        XCTAssertEqual(try assess(fixture, format: .cline, policy: allowed), .withheld(.invalidCapture))
    }

    private func clineBytes(roots: [String]) throws -> Data {
        var records: [[String: Any]] = [["say": "task", "text": "question", "ts": 1780000000000.0]]
        for cwd in roots {
            let request = try JSONSerialization.data(withJSONObject: ["request": "Current Working Directory (\(cwd)) Files"])
            records.append(["say": "api_req_started", "text": String(decoding: request, as: UTF8.self)])
        }
        records.append(["say": "text", "text": "answer", "ts": 1780000000001.0])
        return try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
    }

    private func captureCline(_ bytes: Data, legacy: Bool = false) throws -> Fixture {
        let physical = try XCTUnwrap(realpath(root.path, nil))
        defer { free(physical) }
        let sourceRoot = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent("cline-" + UUID().uuidString)
        let task = sourceRoot.appendingPathComponent("task-native")
        try FileManager.default.createDirectory(at: task, withIntermediateDirectories: true)
        let source = task.appendingPathComponent(legacy ? "claude_messages.json" : "ui_messages.json")
        try bytes.write(to: source)
        let storeRoot = root.appendingPathComponent("shadow-" + UUID().uuidString)
        let cas = try ImmutableArchiveCAS(root: storeRoot)
        let catalog = try ArchiveCatalog(root: storeRoot, machineID: machineID)
        try catalog.migrate()
        defer { try? catalog.close() }
        let descriptor = try ArchiveSourceDescriptor.fileSet(locator: source.path, root: sourceRoot,
            files: [source], absentFiles: legacy ? [task.appendingPathComponent("ui_messages.json")] : [])
        let result = try ExactSourceCapturer(cas: cas, catalog: catalog, descriptor: descriptor)
            .capture(source: .cline, locator: source.path, machineID: machineID)
        return Fixture(sourceURL: source, storeRoot: storeRoot, cas: cas, result: result)
    }

    private struct Fixture: Sendable {
        let sourceURL: URL
        let storeRoot: URL
        let cas: ImmutableArchiveCAS
        let result: ArchiveCaptureResult
    }

    private func capture(_ bytes: Data, source: SourceName, directory: String? = nil) throws -> Fixture {
        let parent = directory.map { root.appendingPathComponent($0) } ?? root!
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let sourceURL = parent.appendingPathComponent("\(UUID().uuidString).jsonl")
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
