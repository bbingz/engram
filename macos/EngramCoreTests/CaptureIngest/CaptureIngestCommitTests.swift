import Darwin
import Foundation
@testable import EngramCoreRead
@testable import EngramCoreWrite
import GRDB
import SQLite3
import XCTest

final class CaptureIngestCommitTests: XCTestCase {
    private let machine = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    private let instance = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
    private let epoch = "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"
    private let nextEpoch = "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD"
    private let otherMachine = "EEEEEEEE-EEEE-4EEE-8EEE-EEEEEEEEEEEE"
    private let otherInstance = "FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF"
    private let journal = "11111111-1111-4111-8111-111111111111"
    private let revision = "swift-parser-z"
    private let timestamp = "2026-09-06T01:02:03.000Z"
    private let logicalRoot = "/offline-client/.claude/projects"
    private var directory: URL!
    private var writer: EngramDatabaseWriter!
    private var nextOrdinal: Int64 = 1

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("capture-commit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        writer = try EngramDatabaseWriter(path: databasePath)
        try writer.migrate()
    }

    override func tearDownWithError() throws {
        writer = nil
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testWindsurfHookArchiveCommitsAndIndexesAfterSourceDeletion_repro() async throws {
        let physical = try XCTUnwrap(realpath(directory.path, nil))
        defer { free(physical) }
        let base = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
        let original = base.appendingPathComponent("windsurf-original")
        let storage = original.appendingPathComponent("transcripts")
        let primary = storage.appendingPathComponent("native-windsurf.jsonl")
        try FileManager.default.createDirectory(at: primary.deletingLastPathComponent(), withIntermediateDirectories: true)
        let records: [[String: Any]] = [
            ["type": "user_input", "status": "done", "user_input": ["user_response": "windsurfconstellation /offline/windsurf-project/a", "rules_applied": ["always_on": ["rule.md"]]]],
            ["type": "planner_response", "status": "done", "planner_response": ["response": "Archived answer"]],
        ]
        let bytes = try records.reduce(into: Data()) { bytes, record in
            bytes.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes]))
            bytes.append(10)
        }
        try bytes.write(to: primary)
        let casRoot = base.appendingPathComponent("windsurf-cas")
        let cas = try ImmutableArchiveCAS(root: casRoot)
        let catalog = try ArchiveCatalog(root: casRoot, machineID: machine)
        try catalog.migrate()
        defer { try? catalog.close() }
        let descriptor = try ArchiveSourceDescriptor.singleFile(locator: primary.path, sourceURL: primary,
            replayRelativePath: "native-windsurf.jsonl")
        let capture = try ExactSourceCapturer(cas: cas, catalog: catalog, descriptor: descriptor)
            .capture(source: .windsurf, locator: primary.path, machineID: machine)
        let format = try XCTUnwrap(CaptureIngestParseFormat(rawValue: "windsurfHookTranscript"))
        XCTAssertEqual(capture.manifest.locator, primary.path)
        let configuredRoot = storage.path
        let binding = try writer.write { db in
            try CaptureIngestSourceRegistry.provision(db, machineID: machine, sourceInstanceID: instance,
                source: .windsurf, parseFormat: format, configuredRoot: configuredRoot, initialEpoch: epoch)
        }
        try FileManager.default.removeItem(at: original)
        let archivedBytes = try capture.manifest.chunks.sorted { $0.ordinal < $1.ordinal }.reduce(into: Data()) {
            $0.append(try cas.readObject(sha256: $1.rawSHA256))
        }
        XCTAssertEqual(archivedBytes, bytes)
        XCTAssertTrue(String(decoding: archivedBytes, as: UTF8.self).contains("rules_applied"))
        let publication = try CollectorPublicationEnvelope(machineID: machine, sourceInstanceID: instance,
            collectorEpoch: epoch, sequence: 1, manifestSHA256: capture.capture.unboundManifestSHA256)
        _ = try accept(publication, parser: revision)
        let claim = try writer.write { db in
            try XCTUnwrap(CaptureIngestLedger.claim(db, publicationSHA256: publication.sha256(),
                parserRevision: revision, now: 100, leaseDuration: 10))
        }
        let staging = base.appendingPathComponent("windsurf-stage")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let replay = try await CaptureIngestReplay.replay(publication: publication, bindingSnapshot: binding,
            cas: cas, stagingParent: staging)
        XCTAssertEqual(replay.scan.info.cwd, "")
        XCTAssertEqual(replay.rawSourceSessionID, "native-windsurf")
        XCTAssertEqual(replay.scan.messages.map(\.content), ["windsurfconstellation /offline/windsurf-project/a", "Archived answer"])
        var forgedScan = replay.scan
        forgedScan.info.id = "forged"
        let forgedIdentity = try CaptureIngestIdentity(machineID: machine, sourceInstanceID: instance,
            source: .windsurf, nativeID: "forged")
        let forged = replacing(replay, scan: forgedScan, rawNativeID: "forged", identity: forgedIdentity)
        XCTAssertThrowsError(try writer.write { db in
            try db.inSavepoint {
                _ = try CaptureIngestCommitter.commitParsed(db, claim: claim, replay: forged,
                    expectedParserRevision: revision, now: 101, indexedAt: timestamp)
                return .rollback
            }
        }) { XCTAssertEqual($0 as? CaptureIngestCommitError, .invalidReplay) }
        let receipt = try writer.write { db in
            try CaptureIngestCommitter.commitParsed(db, claim: claim, replay: replay,
                expectedParserRevision: revision, now: 101, indexedAt: timestamp)
        }
        let policy = CaptureFTSReadinessPolicy(parserRevision: revision, enabledSources: [.windsurf])
        let runner = IndexJobRunner(writer: writer, adapters: [], capturePolicy: { policy })
        let indexed = try await runner.runRecoverableJobsOnce()
        XCTAssertEqual(indexed.result.completed, 1)
        XCTAssertEqual(try writer.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT session_id FROM sessions_fts WHERE sessions_fts MATCH ?",
                arguments: ["windsurfconstellation"])
        }, [receipt.sessionID])
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    func testAntigravityCLIArchiveCommitsAndIndexesAfterSourceDeletion_repro() async throws {
        let physical = try XCTUnwrap(realpath(directory.path, nil))
        defer { free(physical) }
        let base = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
        let original = base.appendingPathComponent("antigravity-original")
        let storage = original.appendingPathComponent("storage")
        let primary = storage.appendingPathComponent("native-antigravity/.system_generated/logs/transcript.jsonl")
        try FileManager.default.createDirectory(at: primary.deletingLastPathComponent(), withIntermediateDirectories: true)
        let records: [[String: Any]] = [
            ["type": "USER_INPUT", "created_at": "2026-09-10T00:00:00Z", "content": "antigravityconstellation /offline/antigravity-project/a"],
            ["type": "PLANNER_RESPONSE", "created_at": "2026-09-10T00:00:01Z", "content": "Archived answer"],
        ]
        let bytes = try records.reduce(into: Data()) { bytes, record in
            bytes.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes]))
            bytes.append(10)
        }
        try bytes.write(to: primary)
        let casRoot = base.appendingPathComponent("antigravity-cas")
        let cas = try ImmutableArchiveCAS(root: casRoot)
        let catalog = try ArchiveCatalog(root: casRoot, machineID: machine)
        try catalog.migrate()
        defer { try? catalog.close() }
        let descriptor = try ArchiveSourceDescriptor.singleFile(locator: primary.path, sourceURL: primary,
            replayRelativePath: "native-antigravity/.system_generated/logs/transcript.jsonl")
        let capture = try ExactSourceCapturer(cas: cas, catalog: catalog, descriptor: descriptor)
            .capture(source: .antigravity, locator: primary.path, machineID: machine)
        let format = try XCTUnwrap(CaptureIngestParseFormat(rawValue: "antigravityCLITranscript"))
        XCTAssertEqual(capture.manifest.locator, primary.path)
        let configuredRoot = storage.path
        let binding = try writer.write { db in
            try CaptureIngestSourceRegistry.provision(db, machineID: machine, sourceInstanceID: instance,
                source: .antigravity, parseFormat: format, configuredRoot: configuredRoot, initialEpoch: epoch)
        }
        try FileManager.default.removeItem(at: original)
        let publication = try CollectorPublicationEnvelope(machineID: machine, sourceInstanceID: instance,
            collectorEpoch: epoch, sequence: 1, manifestSHA256: capture.capture.unboundManifestSHA256)
        _ = try accept(publication, parser: revision)
        let claim = try writer.write { db in
            try XCTUnwrap(CaptureIngestLedger.claim(db, publicationSHA256: publication.sha256(),
                parserRevision: revision, now: 100, leaseDuration: 10))
        }
        let staging = base.appendingPathComponent("antigravity-stage")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let replay = try await CaptureIngestReplay.replay(publication: publication, bindingSnapshot: binding,
            cas: cas, stagingParent: staging)
        XCTAssertEqual(replay.scan.info.cwd, "/offline/antigravity-project")
        XCTAssertEqual(replay.rawSourceSessionID, "native-antigravity")
        XCTAssertEqual(replay.scan.messages.map(\.content), ["antigravityconstellation /offline/antigravity-project/a", "Archived answer"])
        var forgedScan = replay.scan
        forgedScan.info.id = "forged"
        let forgedIdentity = try CaptureIngestIdentity(machineID: machine, sourceInstanceID: instance,
            source: .antigravity, nativeID: "forged")
        let forged = replacing(replay, scan: forgedScan, rawNativeID: "forged", identity: forgedIdentity)
        XCTAssertThrowsError(try writer.write { db in
            try db.inSavepoint {
                _ = try CaptureIngestCommitter.commitParsed(db, claim: claim, replay: forged,
                    expectedParserRevision: revision, now: 101, indexedAt: timestamp)
                return .rollback
            }
        }) { XCTAssertEqual($0 as? CaptureIngestCommitError, .invalidReplay) }
        let receipt = try writer.write { db in
            try CaptureIngestCommitter.commitParsed(db, claim: claim, replay: replay,
                expectedParserRevision: revision, now: 101, indexedAt: timestamp)
        }
        let policy = CaptureFTSReadinessPolicy(parserRevision: revision, enabledSources: [.antigravity])
        let runner = IndexJobRunner(writer: writer, adapters: [], capturePolicy: { policy })
        let indexed = try await runner.runRecoverableJobsOnce()
        XCTAssertEqual(indexed.result.completed, 1)
        XCTAssertEqual(try writer.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT session_id FROM sessions_fts WHERE sessions_fts MATCH ?",
                arguments: ["antigravityconstellation"])
        }, [receipt.sessionID])
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    func testVSCodeExactArchiveCommitsAndIndexesAfterOriginalWorkspaceDeletion() async throws {
        let physical = try XCTUnwrap(realpath(directory.path, nil))
        defer { free(physical) }
        let base = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
        let original = base.appendingPathComponent("vscode-original")
        let storage = original.appendingPathComponent("storage")
        let primary = storage.appendingPathComponent("ws/chatSessions/native.jsonl")
        let workspace = storage.appendingPathComponent("ws/workspace.json")
        let config = original.appendingPathComponent("project.code-workspace")
        try FileManager.default.createDirectory(at: primary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((#"{"kind":0,"v":{"sessionId":"native-vscode","creationDate":1700000000000,"requests":[{"message":{"text":"vscodeconstellation"},"response":[{"value":{"kind":"markdownContent","content":{"value":"Archived answer"}}}]}]}}"# + "\n").utf8).write(to: primary)
        try JSONSerialization.data(withJSONObject: ["configuration": config.absoluteString]).write(to: workspace)
        let configBytes = Data(#"{"folders":[{"path":"/offline/vscode-project"}]}"#.utf8)
        try configBytes.write(to: config)
        let context = try ArchiveVSCodeWorkspaceContext(configurationLocator: config.path,
            configurationGeneration: cursorGeneration(config), configurationData: configBytes,
            configurationSHA256: ArchiveV2Hash.sha256(configBytes))
        let casRoot = base.appendingPathComponent("vscode-cas")
        let cas = try ImmutableArchiveCAS(root: casRoot)
        let catalog = try ArchiveCatalog(root: casRoot, machineID: machine)
        try catalog.migrate()
        defer { try? catalog.close() }
        let descriptor = try ArchiveSourceDescriptor.fileSet(locator: primary.path, root: storage,
            files: [primary, workspace], vscodeWorkspaceContext: context)
        let capture = try ExactSourceCapturer(cas: cas, catalog: catalog, descriptor: descriptor)
            .capture(source: .vscode, locator: primary.path, machineID: machine)
        let binding = try writer.write { db in
            try CaptureIngestSourceRegistry.provision(db, machineID: machine, sourceInstanceID: instance,
                source: .vscode, parseFormat: .vscode, configuredRoot: storage.path, initialEpoch: epoch)
        }
        try FileManager.default.removeItem(at: original)
        let publication = try CollectorPublicationEnvelope(machineID: machine, sourceInstanceID: instance,
            collectorEpoch: epoch, sequence: 1, manifestSHA256: capture.capture.unboundManifestSHA256)
        _ = try accept(publication, parser: revision)
        let claim = try writer.write { db in
            try XCTUnwrap(CaptureIngestLedger.claim(db, publicationSHA256: publication.sha256(),
                parserRevision: revision, now: 100, leaseDuration: 10))
        }
        let staging = base.appendingPathComponent("vscode-stage")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let replay = try await CaptureIngestReplay.replay(publication: publication, bindingSnapshot: binding,
            cas: cas, stagingParent: staging)
        XCTAssertEqual(replay.scan.info.cwd, "/offline/vscode-project")
        XCTAssertEqual(replay.rawSourceSessionID, "native-vscode")
        XCTAssertEqual(replay.scan.messages.map(\.content), ["vscodeconstellation", "Archived answer"])
        let receipt = try writer.write { db in
            try CaptureIngestCommitter.commitParsed(db, claim: claim, replay: replay,
                expectedParserRevision: revision, now: 101, indexedAt: timestamp)
        }
        let policy = CaptureFTSReadinessPolicy(parserRevision: revision, enabledSources: [.vscode])
        let runner = IndexJobRunner(writer: writer, adapters: [], capturePolicy: { policy })
        let indexed = try await runner.runRecoverableJobsOnce()
        XCTAssertEqual(indexed.result.completed, 1)
        XCTAssertEqual(try writer.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT session_id FROM sessions_fts WHERE sessions_fts MATCH ?",
                arguments: ["vscodeconstellation"])
        }, [receipt.sessionID])
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    func testDerivedClaudeArchivesCommitDistinctIdentitiesAndFTSAfterSourceDeletion() async throws {
        let physical = try XCTUnwrap(realpath(directory.path, nil))
        defer { free(physical) }
        let base = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
        let root = base.appendingPathComponent("projects")
        let casRoot = base.appendingPathComponent("derived-cas")
        let cas = try ImmutableArchiveCAS(root: casRoot)
        let catalog = try ArchiveCatalog(root: casRoot, machineID: machine)
        try catalog.migrate()
        defer { try? catalog.close() }
        let staging = base.appendingPathComponent("derived-stage")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        var storedIDs = Set<String>()
        for (source, sourceInstance, relative, model, word) in [
            (SourceName.minimax, instance, "project/s.jsonl", "MiniMax-M2", "minimaxconstellation"),
            (.lobsterai, otherInstance, "lobsterai-project/s.jsonl", "claude-test", "lobsterconstellation"),
        ] {
            let file = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let records: [[String: Any]] = [
                ["type": "user", "sessionId": "shared-native", "cwd": "/offline/project",
                 "timestamp": timestamp, "message": ["role": "user", "content": word]],
                ["type": "assistant", "sessionId": "shared-native", "cwd": "/offline/project",
                 "timestamp": timestamp, "message": ["role": "assistant", "model": model,
                    "content": [["type": "text", "text": "Archived reply"]],
                    "usage": ["input_tokens": 7, "output_tokens": 3]]],
            ]
            var bytes = Data()
            for record in records {
                bytes.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
                bytes.append(0x0A)
            }
            try bytes.write(to: file)
            let descriptor = try ArchiveSourceDescriptor.singleFile(locator: file.path,
                sourceURL: file, replayRelativePath: relative)
            let capture = try ExactSourceCapturer(cas: cas, catalog: catalog, descriptor: descriptor)
                .capture(source: source, locator: file.path, machineID: machine)
            let binding = try writer.write { db in
                try CaptureIngestSourceRegistry.provision(db, machineID: machine, sourceInstanceID: sourceInstance,
                    source: source, parseFormat: .claudeDefault, configuredRoot: root.standardizedFileURL.path, initialEpoch: epoch)
            }
            try FileManager.default.removeItem(at: file)
            let publication = try CollectorPublicationEnvelope(machineID: machine, sourceInstanceID: sourceInstance,
                collectorEpoch: epoch, sequence: 1, manifestSHA256: capture.capture.unboundManifestSHA256)
            _ = try accept(publication, parser: revision)
            let claim = try writer.write { db in
                try XCTUnwrap(CaptureIngestLedger.claim(db, publicationSHA256: publication.sha256(),
                    parserRevision: revision, now: 100, leaseDuration: 10))
            }
            let replay = try await CaptureIngestReplay.replay(publication: publication, bindingSnapshot: binding,
                cas: cas, stagingParent: staging)
            XCTAssertEqual(replay.scan.info.source, source)
            XCTAssertEqual(replay.rawSourceSessionID, "shared-native")
            XCTAssertEqual(replay.scan.messages.count, 2)
            XCTAssertEqual(replay.scan.messages.last?.usage?.inputTokens, 7)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
            let receipt = try writer.write { db in
                try CaptureIngestCommitter.commitParsed(db, claim: claim, replay: replay,
                    expectedParserRevision: revision, now: 101, indexedAt: timestamp)
            }
            XCTAssertTrue(storedIDs.insert(receipt.sessionID).inserted)
            let policy = CaptureFTSReadinessPolicy(parserRevision: revision, enabledSources: [.minimax, .lobsterai])
            let runner = IndexJobRunner(writer: writer, adapters: [], capturePolicy: { policy })
            let indexed = try await runner.runRecoverableJobsOnce()
            XCTAssertEqual(indexed.result.completed, 1)
            XCTAssertEqual(try writer.read { db in
                try String.fetchAll(db, sql: "SELECT DISTINCT session_id FROM sessions_fts WHERE sessions_fts MATCH ?",
                    arguments: [word])
            }, [receipt.sessionID])
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
        XCTAssertEqual(try count("sessions"), 2)
    }

    func testCursorLegacyCaptureReplaysCommitsAndIndexesWithoutSource() async throws {
        try await assertCursorLegacyCommit()
    }

    func testCursorLegacyCommitRejectsEncodedBytesAsNativeSize() async throws {
        try await assertCursorLegacyCommit(forgery: "size")
    }

    func testCursorLegacyCommitRejectsRawBytesAsNativeSize() async throws {
        try await assertCursorLegacyCommit(forgery: "raw-size")
    }

    func testCursorLegacyCommitRejectsFrozenCwdRebinding() async throws {
        try await assertCursorLegacyCommit(forgery: "cwd")
    }

    func testCursorLegacyCommitRejectsConsistentNativeIDRebinding() async throws {
        try await assertCursorLegacyCommit(forgery: "identity")
    }

    func testCursorLegacyCwdAndPayloadVersionsUpdateOneIndexedSession() async throws {
        try await assertCursorLegacyCommit(versions: 2)
    }

    func testCursorLegacyVirtualComposerIDIsNotTreatedAsFilesystemPath() async throws {
        try await assertCursorLegacyCommit(composerID: "literal/../id%_")
    }

    func testCursorLegacyNativeUTF8ExpansionMayExceedEncodedBodySize() async throws {
        try await assertCursorLegacyCommit(invalidBytes: 10000)
    }

    private func assertCursorLegacyCommit(forgery: String? = nil, versions: Int = 1,
                                          composerID: String = "legacy-native", invalidBytes: Int = 1) async throws {
        let physical = try XCTUnwrap(realpath(directory.path, nil))
        defer { free(physical) }
        let base = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
        let root = "/offline-client/Cursor/User/globalStorage"
        let locator = root + "/state.vscdb"
        let cas = try ImmutableArchiveCAS(root: base.appendingPathComponent("legacy-cas"))
        let catalog = try ArchiveCatalog(root: base.appendingPathComponent("legacy-cas"), machineID: machine)
        try catalog.migrate()
        defer { try? catalog.close() }
        let binding = try writer.write { db in
            try CaptureIngestSourceRegistry.provision(db, machineID: machine, sourceInstanceID: instance,
                source: .cursor, parseFormat: .cursor, configuredRoot: root, initialEpoch: epoch)
        }
        let staging = base.appendingPathComponent("legacy-stage")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        var storedID: String?
        for version in 0..<versions {
            let composer = try JSONSerialization.data(withJSONObject: ["composerId": composerID,
                "name": "Frozen legacy", "createdAt": 1700000000000] as [String: Any], options: [.sortedKeys])
            let body = try ArchiveCursorLegacySession(logicalDatabaseLocator: locator, composerID: composerID,
                cwd: "/offline/cursor-legacy-project-\(version)",
                databaseGeneration: ArchiveSourceGeneration(device: 1, inode: 2, size: 819200,
                    mtimeNs: Int64(version + 3), ctimeNs: 4, mode: 0o100600), walGeneration: nil,
                composer: .init(rowID: 1, key: "composerData:" + composerID, value: composer),
                bubbles: [
                    .init(rowID: 2, key: "bubbleId:" + composerID + ":1",
                        value: Data("{\"type\":1,\"text\":\"aurora legacy version \(version)\"}".utf8)),
                    .init(rowID: 3, key: "bubbleId:" + composerID + ":2",
                        value: Data(#"{"type":2,"text":"legacy reply","tokenCount":{"inputTokens":3,"outputTokens":5}}"#.utf8), storage: .blob),
                    .init(rowID: 4, key: "bubbleId:" + composerID + ":3", value: Data([0x70,0,0x6F,0x73,0x74]), storage: .blob),
                    .init(rowID: 5, key: "bubbleId:" + composerID + ":4", value: Data(repeating: 0xFF, count: invalidBytes), storage: .blob),
                ])
            guard case .success(let baseline) = try await CursorAdapter.scanCapturedLegacySession(body,
                logicalLocator: body.logicalLocator) else { return XCTFail("native baseline must parse") }
            let capture = try ExactSourceCapturer.captureCursorLegacySession(body, machineID: machine, cas: cas, catalog: catalog)
            if invalidBytes > 1 { XCTAssertGreaterThan(baseline.scan.info.sizeBytes, capture.manifest.rawByteCount) }
            let publication = try CollectorPublicationEnvelope(machineID: machine, sourceInstanceID: instance,
                collectorEpoch: epoch, sequence: Int64(version + 1), manifestSHA256: capture.capture.unboundManifestSHA256)
            XCTAssertEqual(try writer.read { try CaptureIngestSourceRegistry.eligibility($0,
                publication: publication, verifiedManifest: capture.manifest) }, .eligible(binding))
            _ = try accept(publication, parser: revision)
            let claim = try writer.write { db in
                try XCTUnwrap(CaptureIngestLedger.claim(db, publicationSHA256: publication.sha256(),
                    parserRevision: revision, now: 100, leaseDuration: 10))
            }
            let replay = try await CaptureIngestReplay.replay(publication: publication, bindingSnapshot: binding,
                cas: cas, stagingParent: staging)
            XCTAssertEqual(replay.scan.info, baseline.scan.info)
            XCTAssertEqual(replay.scan.messages, baseline.scan.messages)
            XCTAssertEqual(replay.scan.messages.last?.usage?.outputTokens, 5)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
            if let forgery {
                var scan = replay.scan
                var wrong = replay
                switch forgery {
                case "size": scan.info.sizeBytes = capture.manifest.rawByteCount
                case "raw-size": scan.info.sizeBytes = body.rawPayloadByteCount
                case "cwd": scan.info.cwd = "/forged/project"
                default:
                    scan.info.id = "forged-native"
                    wrong = replacing(replay, rawNativeID: scan.info.id,
                        identity: try replay.nativeIdentity.mapping(nativeID: scan.info.id))
                }
                wrong = replacing(wrong, scan: scan)
                XCTAssertThrowsError(try writer.write { db in
                    try CaptureIngestCommitter.commitParsed(db, claim: claim, replay: wrong,
                        expectedParserRevision: revision, now: 101, indexedAt: timestamp)
                }) { XCTAssertEqual($0 as? CaptureIngestCommitError, .invalidReplay) }
                XCTAssertEqual(try count("sessions"), 0)
                return
            }
            let receipt = try writer.write { db in
                try CaptureIngestCommitter.commitParsed(db, claim: claim, replay: replay,
                    expectedParserRevision: revision, now: 101, indexedAt: timestamp)
            }
            if let storedID { XCTAssertEqual(receipt.sessionID, storedID) } else { storedID = receipt.sessionID }
            XCTAssertEqual(try session(receipt.sessionID)["size_bytes"] as Int64, baseline.scan.info.sizeBytes)
            XCTAssertEqual(try session(receipt.sessionID)["cwd"] as String, body.cwd)
            XCTAssertEqual(try count("sessions"), 1)
            XCTAssertEqual(try count("capture_ingest_generations"), version + 1)
            let policy = CaptureFTSReadinessPolicy(parserRevision: revision, enabledSources: [.cursor])
            let runner = IndexJobRunner(writer: writer, adapters: [], capturePolicy: { policy })
            let indexed = try await runner.runRecoverableJobsOnce()
            XCTAssertEqual(indexed.result.completed, 1)
            XCTAssertEqual(try writer.read { db in
                try String.fetchAll(db, sql: "SELECT DISTINCT session_id FROM sessions_fts WHERE sessions_fts MATCH ?",
                    arguments: ["aurora"])
            }, [receipt.sessionID])
            XCTAssertEqual(try writer.read { db in
                try String.fetchOne(db, sql: "SELECT status FROM capture_ingest_ledger WHERE publication_sha256 = ? AND parser_revision = ?",
                    arguments: [try publication.sha256(), revision])
            }, "index_ready")
        }
    }

    func testKimiCommitPreservesNativeContextSizeAndUsageWithoutOriginalInputs() async throws {
        try await assertKimiCommit()
    }

    func testKimiCommitRejectsWireBytesAsNativeContextSize() async throws {
        try await assertKimiCommit(forgery: "size")
    }

    func testKimiCommitRejectsConsistentNativeIdentityRebinding() async throws {
        try await assertKimiCommit(forgery: "identity")
    }

    func testKimiCommitRejectsCwdOutsideFrozenProjectContext() async throws {
        try await assertKimiCommit(forgery: "cwd")
    }

    func testKimiRegistryOnlyVersionUpdatesOneStoredSession() async throws {
        try await assertKimiCommit(versions: 2)
    }

    private func assertKimiCommit(forgery: String? = nil, versions: Int = 1) async throws {
        let format = try XCTUnwrap(CaptureIngestParseFormat(rawValue: "kimi"))
        let fm = FileManager.default
        let physical = try XCTUnwrap(realpath(directory.path, nil)); defer { free(physical) }
        let base = URL(fileURLWithPath: String(cString: physical))
        let original = base.appendingPathComponent("kimi-source")
        let root = original.appendingPathComponent("sessions")
        let relative = "workspace/native-kimi/context.jsonl"
        let primary = root.appendingPathComponent(relative)
        let shard = primary.deletingLastPathComponent().appendingPathComponent("context_sub_2.jsonl")
        let wire = primary.deletingLastPathComponent().appendingPathComponent("wire.jsonl")
        let registry = original.appendingPathComponent("kimi.json")
        try fm.createDirectory(at: primary.deletingLastPathComponent(), withIntermediateDirectories: true)
        func writeRows(_ url: URL, _ rows: [[String: Any]]) throws {
            var bytes = Data()
            for row in rows { bytes.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])); bytes.append(10) }
            try bytes.write(to: url)
        }
        try writeRows(primary, [["role": "user", "content": "aurora native question"]])
        try writeRows(shard, [["role": "assistant", "content": "native reply"]])
        try writeRows(wire, [
            ["timestamp": 1_788_825_601, "message": ["type": "TurnBegin"]],
            ["timestamp": 1_788_825_602, "message": ["type": "StatusUpdate", "payload": ["token_usage":
                ["input_other": 96, "output": 12, "input_cache_read": 4, "input_cache_creation": 3]]]],
            ["timestamp": 1_788_825_603, "message": ["type": "TurnEnd"]]
        ])
        let cas = try ImmutableArchiveCAS(root: base.appendingPathComponent("kimi-cas"))
        let catalog = try ArchiveCatalog(root: base.appendingPathComponent("kimi-cas"), machineID: machine)
        try catalog.migrate(); defer { try? catalog.close() }
        var captures: [ArchiveCaptureResult] = []
        var nativeScans: [IndexingScan] = []
        for version in 0..<versions {
            let cwd = "/offline/kimi-project-" + String(version)
            let registryBytes = try JSONSerialization.data(withJSONObject: ["work_dirs": [["path": cwd, "last_session_id": "native-kimi"]]])
            try registryBytes.write(to: registry, options: .atomic)
            guard case .success(let native) = try await KimiAdapter(sessionsRoot: root.path, kimiJsonPath: registry.path)
                .scanForIndexing(locator: primary.path) else { return XCTFail("native fixture must parse") }
            nativeScans.append(native)
            var info = stat(); XCTAssertEqual(lstat(registry.path, &info), 0)
            let generation = try ArchiveSourceGeneration(device: Int64(info.st_dev), inode: Int64(info.st_ino),
                size: Int64(info.st_size), mtimeNs: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
                ctimeNs: Int64(info.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(info.st_ctimespec.tv_nsec), mode: Int64(info.st_mode))
            let context = try ArchiveKimiProjectContext(workspaceName: "workspace", nativeSessionID: "native-kimi", cwd: cwd,
                registryLocator: registry.path, registryGeneration: generation, registrySHA256: ArchiveV2Hash.sha256(registryBytes))
            let descriptor = try ArchiveSourceDescriptor.fileSet(locator: primary.path, root: root,
                files: [primary, shard, wire], kimiProjectContext: context)
            captures.append(try ExactSourceCapturer(cas: cas, catalog: catalog, descriptor: descriptor)
                .capture(source: .kimi, locator: primary.path, machineID: machine))
        }
        try fm.removeItem(at: original)
        let binding = try writer.write { db in
            try CaptureIngestSourceRegistry.provision(db, machineID: machine, sourceInstanceID: instance,
                source: .kimi, parseFormat: format, configuredRoot: root.path, initialEpoch: epoch)
        }
        let staging = base.appendingPathComponent("kimi-stage")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var storedID: String?
        for (index, captured) in captures.enumerated() {
            let publication = try CollectorPublicationEnvelope(machineID: machine, sourceInstanceID: instance,
                collectorEpoch: epoch, sequence: Int64(index + 1), manifestSHA256: captured.capture.unboundManifestSHA256)
            XCTAssertEqual(try writer.read { try CaptureIngestSourceRegistry.eligibility($0,
                publication: publication, verifiedManifest: captured.manifest) }, .eligible(binding))
            _ = try accept(publication, parser: revision)
            let claim = try writer.write { db in
                try XCTUnwrap(CaptureIngestLedger.claim(db, publicationSHA256: publication.sha256(),
                    parserRevision: revision, now: 100, leaseDuration: 10))
            }
            let replay = try await CaptureIngestReplay.replay(publication: publication, bindingSnapshot: binding,
                cas: cas, stagingParent: staging)
            XCTAssertEqual(replay.scan.info, nativeScans[index].info)
            XCTAssertEqual(replay.scan.messages, nativeScans[index].messages)
            XCTAssertEqual(replay.scan.messages.last?.usage?.inputTokens, 96)
            XCTAssertGreaterThan(captured.manifest.rawByteCount, replay.scan.info.sizeBytes)
            XCTAssertTrue(try fm.contentsOfDirectory(atPath: staging.path).isEmpty)
            if let forgery {
                var scan = replay.scan
                var wrong = replay
                switch forgery {
                case "size": scan.info.sizeBytes = captured.manifest.rawByteCount
                case "cwd": scan.info.cwd = "/forged/project"
                default:
                    scan.info.id = "forged-native"
                    wrong = replacing(replay, rawNativeID: scan.info.id,
                        identity: try replay.nativeIdentity.mapping(nativeID: scan.info.id))
                }
                wrong = replacing(wrong, scan: scan)
                XCTAssertThrowsError(try writer.write { db in
                    try CaptureIngestCommitter.commitParsed(db, claim: claim, replay: wrong,
                        expectedParserRevision: revision, now: 101, indexedAt: timestamp)
                }) { XCTAssertEqual($0 as? CaptureIngestCommitError, .invalidReplay) }
                XCTAssertEqual(try count("sessions"), 0)
            } else {
                let receipt = try writer.write { db in
                    try CaptureIngestCommitter.commitParsed(db, claim: claim, replay: replay,
                        expectedParserRevision: revision, now: 101, indexedAt: timestamp)
                }
                if let storedID { XCTAssertEqual(receipt.sessionID, storedID) } else { storedID = receipt.sessionID }
                XCTAssertEqual(try session(receipt.sessionID)["size_bytes"] as Int64, nativeScans[index].info.sizeBytes)
                XCTAssertEqual(try session(receipt.sessionID)["cwd"] as String, nativeScans[index].info.cwd)
                XCTAssertEqual(try count("sessions"), 1)
                XCTAssertEqual(try count("capture_ingest_generations"), index + 1)
                let policy = CaptureFTSReadinessPolicy(parserRevision: revision, enabledSources: [.kimi])
                let indexer = IndexJobRunner(writer: writer, adapters: [], capturePolicy: { policy })
                let indexed = try await indexer.runRecoverableJobsOnce()
                XCTAssertEqual(indexed.result.completed, 1)
                XCTAssertTrue(indexed.drained)
                XCTAssertEqual(try writer.read { db in
                    try String.fetchAll(db, sql: "SELECT DISTINCT session_id FROM sessions_fts WHERE sessions_fts MATCH ?",
                        arguments: ["aurora"])
                }, [receipt.sessionID])
                XCTAssertEqual(try writer.read { db in
                    try String.fetchOne(db, sql: "SELECT status FROM capture_ingest_ledger WHERE publication_sha256 = ? AND parser_revision = ?",
                        arguments: [try publication.sha256(), revision])
                }, "index_ready")
                if index > 0 {
                    XCTAssertEqual(captures[0].manifest.chunks, captured.manifest.chunks)
                    XCTAssertNotEqual(captures[0].manifest.captureID, captured.manifest.captureID)
                }
            }
        }
    }

    func testOpenCodeCapturedImageReplaysAndCommitsNativePayloadSizeWithoutOriginalDatabase() async throws {
        try await assertOpenCodeCommit(dispatched: false, useImageSize: false)
    }

    func testOpenCodeCapturedDispatchedChildPreservesSkipAndParentIdentity() async throws {
        try await assertOpenCodeCommit(dispatched: true, useImageSize: false)
    }

    func testOpenCodeCommitRejectsSQLiteImageSizeAsNativePayloadSize() async throws {
        try await assertOpenCodeCommit(dispatched: false, useImageSize: true)
    }

    func testOpenCodeReplayRejectsWrongNativeSessionContext() async throws {
        try await assertOpenCodeCommit(dispatched: false, useImageSize: false, invalidImage: "nativeID")
    }

    func testOpenCodeReplayRejectsWrongNativePayloadContext() async throws {
        try await assertOpenCodeCommit(dispatched: false, useImageSize: false, invalidImage: "payload")
    }

    func testOpenCodeReplayRejectsSiblingSessionRows() async throws {
        try await assertOpenCodeCommit(dispatched: false, useImageSize: false, invalidImage: "sibling")
    }

    func testOpenCodeReplayRejectsForeignMessageOwnership() async throws {
        try await assertOpenCodeCommit(dispatched: false, useImageSize: false, invalidImage: "messageOwner")
    }

    func testOpenCodeReplayRejectsForeignPartOwnership() async throws {
        try await assertOpenCodeCommit(dispatched: false, useImageSize: false, invalidImage: "partOwner")
    }

    func testOpenCodeCommitRejectsConsistentIdentityRebindingAwayFromCapturedNativeID() async throws {
        try await assertOpenCodeCommit(dispatched: false, useImageSize: false, rebindIdentity: true)
    }

    private func assertOpenCodeCommit(dispatched: Bool, useImageSize: Bool, invalidImage: String? = nil,
                                      rebindIdentity: Bool = false) async throws {
        let format = try XCTUnwrap(CaptureIngestParseFormat(rawValue: "opencode"))
        let physical = try XCTUnwrap(realpath(directory.path, nil))
        defer { free(physical) }
        let base = URL(fileURLWithPath: String(cString: physical))
        let sourceRoot = base.appendingPathComponent("opencode-source")
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: false)
        let source = sourceRoot.appendingPathComponent("opencode.db")
        let queue = try DatabaseQueue(path: source.path)
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TABLE session(id TEXT PRIMARY KEY, parent_id TEXT, slug TEXT, agent TEXT,
                    directory TEXT, title TEXT, time_created INTEGER, time_updated INTEGER, time_archived INTEGER);
                CREATE TABLE message(id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT);
                CREATE TABLE part(id TEXT PRIMARY KEY, message_id TEXT, time_created INTEGER, data TEXT);
                """)
            try db.execute(sql: "INSERT INTO session VALUES ('ses-native', ?, ?, ?, '/offline/project', 'Captured native task', 1788825600000, 1788825602000, NULL)",
                arguments: [dispatched ? "parent-native" : nil, dispatched ? "task-reader" : "native", dispatched ? "explore" : "build"])
            try db.execute(sql: """
                INSERT INTO message VALUES ('m-user','ses-native',1788825601000,'{"role":"user"}');
                INSERT INTO message VALUES ('m-answer','ses-native',1788825602000,
                    '{"role":"assistant","tokens":{"input":96,"output":10,"reasoning":2,"cache":{"read":4,"write":3}}}');
                INSERT INTO part VALUES ('p-user','m-user',1788825601000,'{"type":"text","text":"原生问题"}');
                INSERT INTO part VALUES ('p-answer','m-answer',1788825602000,'{"type":"text","text":"Native answer"}');
                INSERT INTO part VALUES ('p-tool','m-answer',1788825602001,'{"type":"tool","state":{"input":"raw tool"}}');
                """)
        }
        try queue.close()
        let logical = source.path + "::ses-native"
        guard case .success(let before) = try await OpenCodeAdapter(dbPath: source.path).scanForIndexing(locator: logical) else {
            return XCTFail("native SQLite fixture must parse before capture")
        }
        if invalidImage == "sibling" || invalidImage == "messageOwner" || invalidImage == "partOwner" {
            let altered = try DatabaseQueue(path: source.path)
            try await altered.write { db in
                if invalidImage == "sibling" {
                    try db.execute(sql: "INSERT INTO session(id, directory) VALUES ('sibling', '/private/project')")
                } else if invalidImage == "partOwner" {
                    try db.execute(sql: "INSERT INTO part VALUES ('foreign-part','missing-message',1788825602000,'{}')")
                } else {
                    try db.execute(sql: "INSERT INTO message VALUES ('foreign-message','foreign-session',1788825602000,'{}')")
                }
            }
            try altered.close()
        }
        let image = try Data(contentsOf: source)
        var info = stat()
        XCTAssertEqual(lstat(source.path, &info), 0)
        let generation = try ArchiveSourceGeneration(device: Int64(info.st_dev), inode: Int64(info.st_ino),
            size: info.st_size, mtimeNs: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
            ctimeNs: Int64(info.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(info.st_ctimespec.tv_nsec), mode: Int64(info.st_mode))
        let context = try ArchiveSQLiteSessionContext(databaseLocator: source.path,
            nativeSessionID: invalidImage == "nativeID" ? "wrong-native" : "ses-native",
            nativePayloadByteCount: before.info.sizeBytes + (invalidImage == "payload" ? 1 : 0), walGeneration: nil)
        let archive = base.appendingPathComponent("opencode-cas")
        let cas = try ImmutableArchiveCAS(root: archive)
        let catalog = try ArchiveCatalog(root: archive, machineID: machine)
        try catalog.migrate()
        defer { try? catalog.close() }
        let captured = try ExactSourceCapturer.captureSQLiteSessionImage(image, context: context,
            generation: generation, machineID: machine, cas: cas, catalog: catalog)
        try FileManager.default.removeItem(at: sourceRoot)
        let binding = try writer.write { db in
            try CaptureIngestSourceRegistry.provision(db, machineID: machine, sourceInstanceID: instance,
                source: .opencode, parseFormat: format, configuredRoot: sourceRoot.path, initialEpoch: epoch)
        }
        let publication = try CollectorPublicationEnvelope(machineID: machine, sourceInstanceID: instance,
            collectorEpoch: epoch, sequence: 1, manifestSHA256: captured.capture.unboundManifestSHA256)
        XCTAssertEqual(try writer.read { try CaptureIngestSourceRegistry.eligibility($0,
            publication: publication, verifiedManifest: captured.manifest) }, .eligible(binding))
        _ = try accept(publication, parser: revision)
        let claim = try writer.write { db in
            try XCTUnwrap(CaptureIngestLedger.claim(db, publicationSHA256: publication.sha256(),
                parserRevision: revision, now: 100, leaseDuration: 10))
        }
        let staging = base.appendingPathComponent("opencode-stage")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        if invalidImage != nil {
            do {
                _ = try await CaptureIngestReplay.replay(publication: publication, bindingSnapshot: binding,
                    cas: cas, stagingParent: staging)
                XCTFail("scoped image/context mismatch must not produce an ingest artifact")
            } catch let error as CaptureIngestReplayError {
                switch error {
                case .parseFailed, .quarantined(.invalidNativeIdentity), .quarantined(.sourceIntegrityMismatch): break
                default: XCTFail("expected admitted image validation failure, got \(error)")
                }
            }
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
            XCTAssertEqual(try count("sessions"), 0)
            return
        }
        let replay = try await CaptureIngestReplay.replay(publication: publication, bindingSnapshot: binding,
            cas: cas, stagingParent: staging)
        XCTAssertEqual(replay.scan.info, before.info)
        XCTAssertEqual(replay.scan.messages, before.messages)
        XCTAssertEqual(replay.rawSourceSessionID, "ses-native")
        XCTAssertEqual(replay.scan.messages.last?.usage?.inputTokens, 96)
        XCTAssertEqual(replay.scan.messages.last?.usage?.outputTokens, 12)
        XCTAssertEqual(replay.scan.messages.last?.usage?.cacheReadTokens, 4)
        XCTAssertEqual(replay.scan.messages.last?.usage?.cacheCreationTokens, 3)
        XCTAssertGreaterThan(replay.verifiedManifest.rawByteCount, replay.scan.info.sizeBytes)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
        if rebindIdentity {
            var scan = replay.scan
            scan.info.id = "different-native"
            let identity = try replay.nativeIdentity.mapping(nativeID: scan.info.id)
            let wrong = CaptureIngestReplayResult(publicationSHA256: replay.publicationSHA256,
                verifiedManifest: replay.verifiedManifest, bindingSnapshot: replay.bindingSnapshot,
                scan: scan, rawSourceSessionID: scan.info.id, nativeIdentity: identity,
                parentIdentity: nil, suggestedParentIdentity: nil)
            XCTAssertThrowsError(try writer.write { db in
                try CaptureIngestCommitter.commitParsed(db, claim: claim, replay: wrong,
                    expectedParserRevision: revision, now: 101, indexedAt: timestamp)
            }) { XCTAssertEqual($0 as? CaptureIngestCommitError, .invalidReplay) }
            XCTAssertEqual(try count("sessions"), 0)
        } else if useImageSize {
            var scan = replay.scan
            scan.info.sizeBytes = replay.verifiedManifest.rawByteCount
            let wrong = replacing(replay, scan: scan)
            XCTAssertThrowsError(try writer.write { db in
                try CaptureIngestCommitter.commitParsed(db, claim: claim, replay: wrong,
                    expectedParserRevision: revision, now: 101, indexedAt: timestamp)
            }) { XCTAssertEqual($0 as? CaptureIngestCommitError, .invalidReplay) }
            XCTAssertEqual(try count("sessions"), 0)
        } else {
            let receipt = try writer.write { db in
                try CaptureIngestCommitter.commitParsed(db, claim: claim, replay: replay,
                    expectedParserRevision: revision, now: 101, indexedAt: timestamp)
            }
            XCTAssertEqual(try session(receipt.sessionID)["size_bytes"] as Int64, before.info.sizeBytes)
            XCTAssertEqual(try count("capture_ingest_generations"), 1)
            if dispatched {
                XCTAssertEqual(replay.parentIdentity, try replay.nativeIdentity.mapping(nativeID: "parent-native"))
                XCTAssertEqual(try session(receipt.sessionID)["tier"] as String, "skip")
                XCTAssertEqual(try session(receipt.sessionID)["agent_role"] as String, "dispatched")
                XCTAssertEqual(try count("session_index_jobs"), 0)
            } else {
                XCTAssertGreaterThan(try count("session_index_jobs"), 0)
            }
        }
    }

    func testCursorModernCommitPreservesNativeStoreTranscriptSizeWithoutOriginalInputs() async throws {
        try await assertCursorModernCommit()
    }

    func testCursorModernCommitRejectsWALAndMetaBytesAsNativeSize() async throws {
        try await assertCursorModernCommit(forgery: "size")
    }

    func testCursorModernCommitRejectsConsistentNativeIdentityRebinding() async throws {
        try await assertCursorModernCommit(forgery: "identity")
    }

    func testCursorModernStoreOnlyWALReplayCommitsNativeMainSizeWithoutOriginalInputs() async throws {
        try await assertCursorModernCommit(shape: .storeOnlyWAL)
    }

    func testCursorModernTranscriptOnlyCommitUsesCaptureMtimeFallbackWithoutOriginalInputs() async throws {
        try await assertCursorModernCommit(shape: .transcriptOnly)
    }

    func testCursorModernStoreOnlyCheckpointedWALHeaderCommitsWithoutCapturedWAL() async throws {
        try await assertCursorModernCommit(shape: .storeOnlyCheckpointedAbsentWAL)
    }

    private enum CursorModernShape {
        case paired
        case storeOnlyWAL
        case transcriptOnly
        case storeOnlyCheckpointedAbsentWAL
    }

    private func assertCursorModernCommit(shape: CursorModernShape = .paired, forgery: String? = nil) async throws {
        // rawValue keeps this file compiling before CaptureIngestParseFormat.cursor exists.
        let format = try XCTUnwrap(CaptureIngestParseFormat(rawValue: "cursor"))
        let fm = FileManager.default
        let physical = try XCTUnwrap(realpath(directory.path, nil))
        defer { free(physical) }
        let base = URL(fileURLWithPath: String(cString: physical))
        let original = base.appendingPathComponent("cursor-source")
        let cursorRoot = original.appendingPathComponent(".cursor")
        let missingLegacyDB = base.appendingPathComponent("missing.vscdb")
        XCTAssertFalse(fm.fileExists(atPath: missingLegacyDB.path))
        let sessionID: String
        let ftsToken = "cursorhq"
        let captureMtimeNs: Int64 = 1_788_825_600_123_000_000
        switch shape {
        case .paired: sessionID = "native-one"
        case .storeOnlyWAL: sessionID = "wal-only"
        case .transcriptOnly: sessionID = "transcript-only"
        case .storeOnlyCheckpointedAbsentWAL: sessionID = "checkpointed"
        }
        let storeRelative = "chats/ws/\(sessionID)/store.db"
        let walRelative = storeRelative + "-wal"
        let metaRelative = "chats/ws/\(sessionID)/meta.json"
        let transcriptRelative = "projects/proj/agent-transcripts/\(sessionID)/\(sessionID).jsonl"
        let storeURL = cursorRoot.appendingPathComponent(storeRelative)
        let transcriptURL = cursorRoot.appendingPathComponent(transcriptRelative)
        var liveHandle: OpaquePointer?
        defer {
            if let liveHandle {
                if sqlite3_close(liveHandle) != SQLITE_OK { sqlite3_close_v2(liveHandle) }
            }
        }
        var declaredMembers: [(relative: String, url: URL)] = []
        var absent: [String] = []
        var checkpointedMain: Data?
        let primaryRelative: String
        switch shape {
        case .paired:
            primaryRelative = transcriptRelative
            liveHandle = try openCursorWALStore(
                at: storeURL,
                blobs: [
                    ("user", #"{"role":"user","content":"STORE user that must lose"}"#),
                    ("assistant", #"{"role":"assistant","content":"STORE assistant that must lose"}"#),
                ],
                metadata: ["cwd": "/store/secret-cwd", "name": "Store title that must lose"]
            )
            let metaURL = storeURL.deletingLastPathComponent().appendingPathComponent("meta.json")
            let walURL = URL(fileURLWithPath: storeURL.path + "-wal")
            try writeCursorFile(
                metaURL,
                JSONSerialization.data(
                    withJSONObject: [
                        "cwd": "/offline/cursor-paired",
                        "name": "Live overlay title",
                        "latestConversationSummary": ["summary": ["summary": ""]],
                    ],
                    options: [.sortedKeys]
                )
            )
            try writeCursorFile(
                transcriptURL,
                cursorJSONL([
                    #"{"role":"user","message":{"content":[{"type":"text","text":"cursorhq paired aurora question"}]}}"#,
                    #"{"role":"assistant","message":{"content":[{"type":"text","text":"LIVE assistant that must win"}]}}"#,
                ])
            )
            try writeCursorFile(
                storeURL.deletingLastPathComponent().appendingPathComponent("notes.txt"),
                Data("UNRELATED-SECRET".utf8)
            )
            try writeCursorFile(
                transcriptURL.deletingLastPathComponent().appendingPathComponent("notes.txt"),
                Data("UNRELATED-SECRET".utf8)
            )
            declaredMembers = [
                (storeRelative, storeURL),
                (walRelative, walURL),
                (metaRelative, metaURL),
                (transcriptRelative, transcriptURL),
            ]
        case .storeOnlyWAL:
            primaryRelative = storeRelative
            liveHandle = try openCursorWALStore(
                at: storeURL,
                blobs: [
                    ("user", #"{"role":"user","content":"cursorhq WAL user row"}"#),
                    ("assistant", #"{"role":"assistant","content":"WAL assistant row"}"#),
                ],
                metadata: ["cwd": "/offline/cursor-wal", "name": "WAL store title"]
            )
            let walURL = URL(fileURLWithPath: storeURL.path + "-wal")
            try writeCursorFile(
                storeURL.deletingLastPathComponent().appendingPathComponent("notes.txt"),
                Data("UNRELATED-SECRET".utf8)
            )
            declaredMembers = [(storeRelative, storeURL), (walRelative, walURL)]
            absent = [metaRelative]
            XCTAssertNil(try Data(contentsOf: storeURL).range(of: Data("cursorhq".utf8)))
            XCTAssertNotNil(try Data(contentsOf: walURL).range(of: Data("cursorhq".utf8)))
        case .transcriptOnly:
            primaryRelative = transcriptRelative
            try writeCursorFile(
                transcriptURL,
                cursorJSONL([
                    #"{"role":"user","message":{"content":[{"type":"text","text":"cursorhq transcript only user"}]}}"#,
                    #"{"role":"assistant","message":{"content":[{"type":"text","text":"Transcript only assistant"}]}}"#,
                ])
            )
            try writeCursorFile(
                transcriptURL.deletingLastPathComponent().appendingPathComponent("notes.txt"),
                Data("UNRELATED-SECRET".utf8)
            )
            declaredMembers = [(transcriptRelative, transcriptURL)]
        case .storeOnlyCheckpointedAbsentWAL:
            primaryRelative = storeRelative
            liveHandle = try openCursorWALStore(
                at: storeURL,
                blobs: [
                    ("user", #"{"role":"user","content":"cursorhq checkpointed user row"}"#),
                    ("assistant", #"{"role":"assistant","content":"Checkpointed assistant row"}"#),
                ],
                metadata: ["cwd": "/offline/cursor-checkpointed", "name": "Checkpointed store title"]
            )
            try writeCursorFile(
                storeURL.deletingLastPathComponent().appendingPathComponent("notes.txt"),
                Data("UNRELATED-SECRET".utf8)
            )
            try checkpointCursorWAL(try XCTUnwrap(liveHandle))
            declaredMembers = [(storeRelative, storeURL)]
            absent = [walRelative, metaRelative]
            let main = try Data(contentsOf: storeURL)
            XCTAssertGreaterThanOrEqual(main.count, 20)
            XCTAssertEqual(main[18], 2)
            XCTAssertEqual(main[19], 2)
            XCTAssertNotNil(main.range(of: Data("cursorhq".utf8)))
            checkpointedMain = main
        }
        let primaryURL = cursorRoot.appendingPathComponent(primaryRelative)
        try setCursorMtime(path: primaryURL.path, nanoseconds: captureMtimeNs)
        XCTAssertFalse(fm.fileExists(atPath: missingLegacyDB.path))
        let adapter = CursorAdapter(dbPath: missingLegacyDB.path, cursorDataRoot: cursorRoot)
        let locators = try await adapter.listSessionLocators()
        XCTAssertEqual(locators.count, 1)
        let nativeLocator = try XCTUnwrap(locators.first)
        XCTAssertTrue(nativeLocator.hasPrefix("cursor-modern:"))
        guard case .success(let native) = try await adapter.scanForIndexing(locator: nativeLocator) else {
            return XCTFail("native CursorAdapter must parse the sealed fixture")
        }
        XCTAssertNil(native.parseFailure)
        XCTAssertEqual(native.info.id, sessionID)
        XCTAssertEqual(native.info.source, .cursor)
        XCTAssertTrue(native.messages.allSatisfy { $0.timestamp == nil && $0.usage == nil })
        let storeBytes: Data
        let transcriptBytes: Data
        switch shape {
        case .transcriptOnly:
            storeBytes = Data()
            transcriptBytes = try Data(contentsOf: transcriptURL)
        case .storeOnlyWAL, .storeOnlyCheckpointedAbsentWAL:
            storeBytes = try Data(contentsOf: storeURL)
            transcriptBytes = Data()
        case .paired:
            storeBytes = try Data(contentsOf: storeURL)
            transcriptBytes = try Data(contentsOf: transcriptURL)
        }
        let nativeSize = Int64(storeBytes.count + transcriptBytes.count)
        XCTAssertEqual(native.info.sizeBytes, nativeSize)
        switch shape {
        case .paired:
            XCTAssertEqual(native.messages.map(\.content), ["cursorhq paired aurora question", "LIVE assistant that must win"])
            XCTAssertEqual(native.info.cwd, "/offline/cursor-paired")
            XCTAssertEqual(native.info.displayTitle, "Live overlay title")
            XCTAssertNil(native.info.summary)
        case .storeOnlyWAL:
            XCTAssertEqual(native.messages.map(\.content), ["cursorhq WAL user row", "WAL assistant row"])
            XCTAssertEqual(native.info.cwd, "/offline/cursor-wal")
            XCTAssertEqual(native.info.displayTitle, "WAL store title")
            XCTAssertEqual(native.info.summary, "cursorhq WAL user row")
        case .transcriptOnly:
            XCTAssertEqual(native.messages.map(\.content), ["cursorhq transcript only user", "Transcript only assistant"])
            XCTAssertEqual(native.info.cwd, "")
            XCTAssertNil(native.info.project)
            XCTAssertNil(native.info.displayTitle)
            XCTAssertEqual(native.info.summary, "cursorhq transcript only user")
        case .storeOnlyCheckpointedAbsentWAL:
            XCTAssertEqual(native.messages.map(\.content),
                ["cursorhq checkpointed user row", "Checkpointed assistant row"])
            XCTAssertEqual(native.info.cwd, "/offline/cursor-checkpointed")
            XCTAssertEqual(native.info.displayTitle, "Checkpointed store title")
            XCTAssertEqual(native.info.summary, "cursorhq checkpointed user row")
            XCTAssertEqual(storeBytes, try XCTUnwrap(checkpointedMain))
            XCTAssertEqual(storeBytes[18], 2)
        }
        let expectedISO = Phase4AdapterSupport.isoFromMilliseconds(Double(captureMtimeNs) / 1_000_000.0)
        XCTAssertEqual(native.info.startTime, expectedISO)
        XCTAssertNil(native.info.endTime)
        if shape == .storeOnlyCheckpointedAbsentWAL {
            try checkpointAndCloseCursorWAL(&liveHandle)
            try requireCursorWALSidecarsAbsent(store: storeURL)
            XCTAssertEqual(try Data(contentsOf: storeURL), try XCTUnwrap(checkpointedMain))
            try setCursorMtime(path: storeURL.path, nanoseconds: captureMtimeNs)
        }
        let members = try declaredMembers.map { member in
            ArchiveCapturedFile(
                relativePath: member.relative,
                generation: try cursorGeneration(member.url),
                bytes: try Data(contentsOf: member.url)
            )
        }
        XCTAssertFalse(members.contains { $0.relativePath.hasSuffix("notes.txt") })
        XCTAssertFalse(members.contains { $0.relativePath.hasSuffix("-shm") || $0.relativePath.hasSuffix("-journal") })
        if shape == .storeOnlyCheckpointedAbsentWAL {
            XCTAssertEqual(members.map(\.relativePath), [storeRelative])
            XCTAssertEqual(members[0].bytes[18], 2)
            XCTAssertFalse(members.contains { $0.relativePath.hasSuffix("-wal") })
            XCTAssertEqual(Set(absent), [walRelative, metaRelative])
        }
        XCTAssertEqual(try cursorGeneration(primaryURL).mtimeNs, captureMtimeNs)
        let cas = try ImmutableArchiveCAS(root: base.appendingPathComponent("cursor-cas"))
        let catalog = try ArchiveCatalog(root: base.appendingPathComponent("cursor-cas"), machineID: machine)
        try catalog.migrate()
        defer { try? catalog.close() }
        let locator = cursorRoot.appendingPathComponent(primaryRelative).path
        let captured = try ExactSourceCapturer.captureCursorModernFileSet(
            members, locator: locator, absentRelativePaths: absent, machineID: machine, cas: cas, catalog: catalog)
        XCTAssertTrue(ArchiveSourceDescriptor.isCursorModernFileSet(captured.manifest))
        XCTAssertEqual(captured.manifest.generation.mtimeNs, captureMtimeNs)
        XCTAssertEqual(captured.manifest.locator, locator)
        XCTAssertEqual(Set(captured.manifest.replayLayout.files?.map(\.relativePath) ?? []), Set(members.map(\.relativePath)))
        if shape == .paired || shape == .storeOnlyWAL {
            XCTAssertGreaterThan(captured.manifest.rawByteCount, nativeSize)
        } else {
            XCTAssertEqual(captured.manifest.rawByteCount, nativeSize)
        }
        if shape == .storeOnlyCheckpointedAbsentWAL {
            try requireCursorWALSidecarsAbsent(store: storeURL)
        }
        if let handle = liveHandle {
            if sqlite3_close(handle) != SQLITE_OK { sqlite3_close_v2(handle) }
            liveHandle = nil
        }
        try fm.removeItem(at: original)
        XCTAssertFalse(fm.fileExists(atPath: cursorRoot.path))
        XCTAssertFalse(fm.fileExists(atPath: missingLegacyDB.path))
        let binding = try writer.write { db in
            try CaptureIngestSourceRegistry.provision(db, machineID: machine, sourceInstanceID: instance,
                source: .cursor, parseFormat: format, configuredRoot: cursorRoot.path, initialEpoch: epoch)
        }
        let publication = try CollectorPublicationEnvelope(machineID: machine, sourceInstanceID: instance,
            collectorEpoch: epoch, sequence: 1, manifestSHA256: captured.capture.unboundManifestSHA256)
        XCTAssertEqual(try writer.read { try CaptureIngestSourceRegistry.eligibility($0,
            publication: publication, verifiedManifest: captured.manifest) }, .eligible(binding))
        _ = try accept(publication, parser: revision)
        let claim = try writer.write { db in
            try XCTUnwrap(CaptureIngestLedger.claim(db, publicationSHA256: publication.sha256(),
                parserRevision: revision, now: 100, leaseDuration: 10))
        }
        let staging = base.appendingPathComponent("cursor-stage")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        // Pristine HQ replay only. beforeParse sibling injection is a sealed
        // verifyLinks rejection, not discovery; do not plant or list the tree.
        let replay = try await CaptureIngestReplay.replay(publication: publication, bindingSnapshot: binding,
            cas: cas, stagingParent: staging)
        var remapped = replay.scan.info
        remapped.filePath = native.info.filePath
        XCTAssertEqual(remapped, native.info)
        XCTAssertEqual(replay.scan.messages, native.messages)
        XCTAssertEqual(replay.scan.info.id, sessionID)
        XCTAssertEqual(replay.rawSourceSessionID, sessionID)
        XCTAssertEqual(replay.scan.info.filePath, captured.manifest.locator)
        XCTAssertEqual(replay.scan.info.sizeBytes, nativeSize)
        XCTAssertEqual(replay.scan.info.startTime, expectedISO)
        XCTAssertNil(replay.scan.info.endTime)
        XCTAssertEqual(captured.manifest.generation.mtimeNs, captureMtimeNs)
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: staging.path).isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: missingLegacyDB.path))
        if let forgery {
            var scan = replay.scan
            var wrong = replay
            if forgery == "size" {
                scan.info.sizeBytes = captured.manifest.rawByteCount
            } else {
                scan.info.id = "forged-native"
                wrong = replacing(replay, rawNativeID: scan.info.id,
                    identity: try replay.nativeIdentity.mapping(nativeID: scan.info.id))
            }
            wrong = replacing(wrong, scan: scan)
            XCTAssertThrowsError(try writer.write { db in
                try CaptureIngestCommitter.commitParsed(db, claim: claim, replay: wrong,
                    expectedParserRevision: revision, now: 101, indexedAt: timestamp)
            }) { XCTAssertEqual($0 as? CaptureIngestCommitError, .invalidReplay) }
            XCTAssertEqual(try count("sessions"), 0)
            return
        }
        let receipt = try writer.write { db in
            try CaptureIngestCommitter.commitParsed(db, claim: claim, replay: replay,
                expectedParserRevision: revision, now: 101, indexedAt: timestamp)
        }
        XCTAssertEqual(try session(receipt.sessionID)["size_bytes"] as Int64, nativeSize)
        XCTAssertEqual(try session(receipt.sessionID)["cwd"] as String, native.info.cwd)
        let policy = CaptureFTSReadinessPolicy(parserRevision: revision, enabledSources: [.cursor])
        let indexer = IndexJobRunner(writer: writer, adapters: [], capturePolicy: { policy })
        let indexed = try await indexer.runRecoverableJobsOnce()
        XCTAssertEqual(indexed.result.completed, 1)
        XCTAssertTrue(indexed.drained)
        XCTAssertEqual(try writer.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT session_id FROM sessions_fts WHERE sessions_fts MATCH ?",
                arguments: [ftsToken])
        }, [receipt.sessionID])
        XCTAssertEqual(try writer.read { db in
            try String.fetchOne(db, sql: "SELECT status FROM capture_ingest_ledger WHERE publication_sha256 = ? AND parser_revision = ?",
                arguments: [try publication.sha256(), revision])
        }, "index_ready")
    }

    private func openCursorWALStore(
        at url: URL, blobs: [(String, String)], metadata: [String: Any]?
    ) throws -> OpaquePointer {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let handle = database else {
            sqlite3_close(database)
            throw POSIXError(.EIO)
        }
        func sql(_ text: String) throws {
            guard sqlite3_exec(handle, text, nil, nil, nil) == SQLITE_OK else { throw POSIXError(.EIO) }
        }
        try sql("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;")
        try sql("CREATE TABLE blobs (id TEXT PRIMARY KEY, data BLOB); CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);")
        try sql("PRAGMA wal_checkpoint(TRUNCATE);")
        try sql("BEGIN;")
        if let metadata {
            let encoded = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
            let hex = encoded.map { String(format: "%02x", $0) }.joined()
            try sql("INSERT INTO meta (key, value) VALUES ('0', '\(hex)');")
        }
        for (blobID, json) in blobs {
            try sql("INSERT INTO blobs (id, data) VALUES ('\(blobID)', '\(json)');")
        }
        try sql("COMMIT;")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + "-wal"))
        return handle
    }

    private struct CursorModernFixtureError: Error, CustomStringConvertible {
        let description: String
    }

    private func checkpointCursorWAL(_ handle: OpaquePointer) throws {
        var log: Int32 = 0
        var checkpointed: Int32 = 0
        let status = sqlite3_wal_checkpoint_v2(handle, nil, SQLITE_CHECKPOINT_TRUNCATE, &log, &checkpointed)
        guard status == SQLITE_OK else {
            throw CursorModernFixtureError(description:
                "wal_checkpoint_v2 TRUNCATE status=\(status) log=\(log) checkpointed=\(checkpointed)")
        }
    }

    private func checkpointAndCloseCursorWAL(_ handle: inout OpaquePointer?) throws {
        guard let database = handle else {
            throw CursorModernFixtureError(description: "checkpoint-and-close missing WAL writer")
        }
        try checkpointCursorWAL(database)
        // Ask SQLite to remove its checkpointed sidecars on this writer's
        // final close; never unlink them or alter database bytes ourselves.
        var persistentWAL: Int32 = 0
        guard sqlite3_file_control(database, "main", SQLITE_FCNTL_PERSIST_WAL, &persistentWAL) == SQLITE_OK else {
            throw CursorModernFixtureError(description: "cannot disable persistent WAL for fixture close")
        }
        let status = sqlite3_close(database)
        guard status == SQLITE_OK else {
            throw CursorModernFixtureError(description: "sqlite3_close status=\(status)")
        }
        handle = nil
    }

    private func requireCursorWALSidecarsAbsent(store: URL) throws {
        let wal = store.path + "-wal"
        let shm = store.path + "-shm"
        let present = (
            wal: FileManager.default.fileExists(atPath: wal),
            shm: FileManager.default.fileExists(atPath: shm)
        )
        if present.wal || present.shm {
            throw CursorModernFixtureError(description:
                "source WAL/SHM remain after checked close wal=\(present.wal) shm=\(present.shm)")
        }
    }

    private func writeCursorFile(_ url: URL, _ body: Data) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: url)
    }

    private func cursorJSONL(_ rows: [String]) -> Data {
        var data = Data()
        for row in rows {
            data.append(Data(row.utf8))
            data.append(10)
        }
        return data
    }

    private func cursorGeneration(_ url: URL) throws -> ArchiveSourceGeneration {
        var info = stat()
        XCTAssertEqual(lstat(url.path, &info), 0)
        return try ArchiveSourceGeneration(
            device: Int64(info.st_dev), inode: Int64(info.st_ino), size: Int64(info.st_size),
            mtimeNs: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
            ctimeNs: Int64(info.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(info.st_ctimespec.tv_nsec),
            mode: Int64(info.st_mode)
        )
    }

    private func setCursorMtime(path: String, nanoseconds: Int64) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let mtime = timespec(
            tv_sec: numericCast(nanoseconds / 1_000_000_000),
            tv_nsec: numericCast(nanoseconds % 1_000_000_000)
        )
        var times = [info.st_atimespec, mtime]
        guard Darwin.utimensat(AT_FDCWD, path, &times, 0) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func testGeminiNativeFileSetCommitPreservesTranscriptSize() async throws {
        try await assertGeminiNativeSizeCommit(useAggregateSize: false)
    }

    func testGeminiFileSetCommitRejectsAggregateSizeAsNativeTranscriptSize() async throws {
        try await assertGeminiNativeSizeCommit(useAggregateSize: true)
    }

    private func assertGeminiNativeSizeCommit(useAggregateSize: Bool) async throws {
        let physical = try XCTUnwrap(realpath(directory.path, nil))
        defer { free(physical) }
        let physicalDirectory = URL(fileURLWithPath: String(cString: physical))
        let sourceRoot = physicalDirectory.appendingPathComponent("gemini-tmp")
        let chats = sourceRoot.appendingPathComponent("project/chats")
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let source = chats.appendingPathComponent("stem.json")
        let rootFile = sourceRoot.appendingPathComponent("project/.project_root")
        let sidecar = chats.appendingPathComponent("native-gemini.engram.json")
        let bytes = try JSONSerialization.data(withJSONObject: ["sessionId": "native-gemini",
            "startTime": "2026-09-08T00:00:00Z", "lastUpdated": "2026-09-08T00:00:02Z",
            "messages": [["type": "user", "content": "A complete native Gemini question", "timestamp": "2026-09-08T00:00:01Z"],
                ["type": "gemini", "content": "A complete native Gemini answer", "timestamp": "2026-09-08T00:00:02Z"]]], options: [.sortedKeys])
        try bytes.write(to: source)
        try Data("/offline-client/project\n".utf8).write(to: rootFile)
        try Data("{\"originator\":\"gemini-cli\"}".utf8).write(to: sidecar)
        let archive = physicalDirectory.appendingPathComponent("gemini-archive")
        let cas = try ImmutableArchiveCAS(root: archive)
        let catalog = try ArchiveCatalog(root: archive, machineID: machine)
        try catalog.migrate()
        defer { try? catalog.close() }
        let descriptor = try ArchiveSourceDescriptor.fileSet(locator: source.path, root: sourceRoot,
            files: [rootFile, sidecar, source])
        let captured = try ExactSourceCapturer(cas: cas, catalog: catalog, descriptor: descriptor)
            .capture(source: .geminiCli, locator: source.path, machineID: machine)
        let binding = try writer.write { db in
            try CaptureIngestSourceRegistry.provision(db, machineID: machine, sourceInstanceID: instance,
                source: .geminiCli, parseFormat: .geminiCli, configuredRoot: sourceRoot.path, initialEpoch: epoch)
        }
        let publication = try CollectorPublicationEnvelope(machineID: machine, sourceInstanceID: instance,
            collectorEpoch: epoch, sequence: 1, manifestSHA256: captured.capture.unboundManifestSHA256)
        _ = try accept(publication, parser: revision)
        let claim = try writer.write { db in
            try XCTUnwrap(CaptureIngestLedger.claim(db, publicationSHA256: publication.sha256(),
                parserRevision: revision, now: 100, leaseDuration: 10))
        }
        let staging = physicalDirectory.appendingPathComponent("gemini-stage")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let replay = try await CaptureIngestReplay.replay(publication: publication, bindingSnapshot: binding,
            cas: cas, stagingParent: staging)
        XCTAssertEqual(replay.scan.info.sizeBytes, Int64(bytes.count))
        XCTAssertGreaterThan(replay.verifiedManifest.rawByteCount, Int64(bytes.count))
        if useAggregateSize {
            var scan = replay.scan
            scan.info.sizeBytes = replay.verifiedManifest.rawByteCount
            let wrong = replacing(replay, scan: scan)
            XCTAssertThrowsError(try writer.write { db in
                try CaptureIngestCommitter.commitParsed(db, claim: claim, replay: wrong,
                    expectedParserRevision: revision, now: 101, indexedAt: timestamp)
            }) { XCTAssertEqual($0 as? CaptureIngestCommitError, .invalidReplay) }
            XCTAssertEqual(try count("sessions"), 0)
        } else {
            let receipt = try writer.write { db in
                try CaptureIngestCommitter.commitParsed(db, claim: claim, replay: replay,
                    expectedParserRevision: revision, now: 101, indexedAt: timestamp)
            }
            XCTAssertEqual(try writer.read { try Int64.fetchOne($0, sql: "SELECT size_bytes FROM sessions WHERE id = ?",
                arguments: [receipt.sessionID]) }, Int64(bytes.count))
        }
    }

    func testFreshAndRepeatedMigrationCreatesOnlyEmptyCommitStores() throws {
        let before = try state()
        try writer.migrate()
        try writer.migrate()
        guard try requireSchema() else { return }
        XCTAssertEqual(try state(), before)
        XCTAssertEqual(try count("capture_ingest_identity_bindings"), 0)
        XCTAssertEqual(try count("capture_ingest_generations"), 0)
        XCTAssertEqual(try count("sessions"), 0)
        XCTAssertEqual(try count("session_index_jobs"), 0)
    }

    func testMigrationAddsReadyMetadataIndexWithoutChangingExistingGeneration() throws {
        let fixture = try makeFixture()
        guard let receipt = requireCommit(fixture) else { return }
        let before = try generation(receipt)
        try writer.write { try $0.execute(sql: "DROP INDEX capture_ingest_generations_ready_metadata") }
        try writer.migrate()
        try writer.migrate()
        XCTAssertEqual(try generation(receipt), before)
        let exists = try writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'capture_ingest_generations_ready_metadata'")
        }
        XCTAssertEqual(exists, 1)
    }

    func testMigrationPreservesLegacyRowsWithoutInventingIdentityAliases() throws {
        try seedSession(id: "native-session", owner: "local")
        let fixture = try makeFixture()
        try writer.write { db in
            try db.execute(sql: "DROP TABLE IF EXISTS capture_ingest_generations")
            try db.execute(sql: "DROP TABLE IF EXISTS capture_ingest_identity_bindings")
        }
        let before = try state()
        try writer.migrate()
        guard try requireSchema() else { return }
        XCTAssertEqual(try state().filter { before[$0.key] != nil }, before)
        XCTAssertEqual(try count("capture_ingest_identity_bindings"), 0)
        XCTAssertEqual(try count("capture_ingest_generations"), 0)
        XCTAssertEqual(try ledger(fixture)["status"] as String, "processing")
    }

    func testNormalizedStorageBudgetAndSchemaAreFixedNotAnIPCFrameLimit() {
        XCTAssertEqual(CaptureIngestCommitter.normalizedSchemaVersion, 1)
        XCTAssertEqual(CaptureIngestCommitter.maximumNormalizedPayloadBytes, 100 * 1024 * 1024)
        XCTAssertEqual(CaptureIngestCommitter.maximumNormalizedMessages, 10_000)
        XCTAssertGreaterThan(CaptureIngestCommitter.maximumNormalizedPayloadBytes, 256 * 1024)
    }

    func testFirstCommitAtomicallyPersistsCompleteProvenanceSnapshotJobAndParsedOnly() throws {
        let fixture = try makeFixture()
        let intakeBefore = try intakeState()
        guard let receipt = requireCommit(fixture) else { return }
        XCTAssertEqual(receipt.sessionID, try fixture.replay.nativeIdentity.proposedSessionID())
        XCTAssertEqual(receipt.syncVersion, 1, "publication sequence is not a snapshot version")
        XCTAssertEqual(receipt.generationID.count, 64)
        XCTAssertEqual(receipt.generationID, receipt.generationID.lowercased())
        let generation = try generation(receipt)
        XCTAssertEqual(generation["publication_sha256"] as String, fixture.claim.publicationSHA256)
        XCTAssertEqual(generation["parser_revision"] as String, revision)
        XCTAssertEqual(generation["machine_id"] as String, machine)
        XCTAssertEqual(generation["source_instance_id"] as String, instance)
        XCTAssertEqual(generation["source"] as String, "claude-code")
        XCTAssertEqual(generation["parse_format"] as String, "claudeDefault")
        XCTAssertEqual(generation["configured_root"] as String, logicalRoot)
        XCTAssertEqual(generation["collector_epoch"] as String, epoch)
        XCTAssertEqual(generation["authority_generation"] as Int64, 1)
        XCTAssertEqual(generation["sequence"] as Int64, fixture.claim.publication.sequence)
        XCTAssertEqual(generation["native_id"] as String, "native-session")
        XCTAssertEqual(generation["raw_source_session_id"] as String, fixture.replay.rawSourceSessionID)
        XCTAssertEqual(generation["stored_session_id"] as String, receipt.sessionID)
        XCTAssertEqual(generation["manifest_json"] as Data, try ArchiveCanonicalJSON.encode(fixture.replay.verifiedManifest))
        XCTAssertEqual(generation["normalized_schema_version"] as Int, 1)
        XCTAssertEqual(generation["normalized_message_count"] as Int, fixture.replay.scan.messages.count)
        XCTAssertEqual(generation["sync_version"] as Int, receipt.syncVersion)
        XCTAssertEqual(generation["snapshot_hash"] as String, receipt.snapshotHash)
        XCTAssertEqual(generation["created_at"] as String, timestamp)
        try assertPayload(receipt, equals: fixture.replay.scan.messages)
        let binding = try identity(fixture)
        XCTAssertEqual(binding["stored_session_id"] as String, receipt.sessionID)
        XCTAssertEqual(binding["last_parsed_generation_id"] as String, receipt.generationID)
        XCTAssertEqual(binding["last_sync_version"] as Int, 1)
        XCTAssertNil(binding["last_ready_generation_id"] as String?)
        let session = try session(receipt.sessionID)
        XCTAssertEqual(session["authoritative_node"] as String, fixture.replay.nativeIdentity.peer)
        XCTAssertEqual(session["sync_version"] as Int, receipt.syncVersion)
        XCTAssertEqual(session["snapshot_hash"] as String, receipt.snapshotHash)
        XCTAssertEqual(session["source_locator"] as String, "capture://\(receipt.generationID)")
        XCTAssertFalse((session["file_path"] as String).contains("/offline-client/"))
        try assertExactPendingFTS(receipt)
        try assertParsedOnly(fixture, receipt: receipt)
        XCTAssertEqual(try intakeState(), intakeBefore, "parsed commit does not advance intake")
    }

    func testLargeUnicodeToolFieldsAndEveryNormalizedFieldRoundTripWithoutFragmentsLost() throws {
        let toolText = String(repeating: "漢字😀\\\"\n", count: 30_000)
        let messages: [NormalizedMessage] = [
            .init(role: .user, content: "Implement the complete transcript reader.", timestamp: timestamp),
            .init(role: .assistant, content: "Implemented it.", timestamp: timestamp,
                  toolCalls: [.init(name: "Write", input: toolText, output: toolText + "tail-output"),
                              .init(name: "Read", input: nil, output: "")],
                  usage: .init(inputTokens: 7, outputTokens: 11, cacheReadTokens: 13, cacheCreationTokens: 17)),
            .init(role: .tool, content: "complete tool message", timestamp: nil, toolCalls: []),
            .init(role: .system, content: "preserved supported role", timestamp: timestamp),
        ]
        let fixture = try makeFixture(messages: messages)
        guard let receipt = requireCommit(fixture) else { return }
        let payload: Data = try generation(receipt)["normalized_messages_json"]
        XCTAssertGreaterThan(payload.count, 256 * 1024)
        try assertPayload(receipt, equals: messages)
        XCTAssertEqual(try count("sessions_fts"), 0, "storage has no read/FTS consumer in T2")
        try assertParsedOnly(fixture, receipt: receipt)
    }

    func testTenThousandCompleteMessagesAreAcceptedWithoutPrefixTruncation() throws {
        let messages = (0..<10_000).map { index in
            NormalizedMessage(role: index.isMultiple(of: 2) ? .user : .assistant,
                              content: "message-\(index)", timestamp: timestamp)
        }
        let fixture = try makeFixture(messages: messages)
        guard let receipt = requireCommit(fixture) else { return }
        try assertPayload(receipt, equals: messages)
        XCTAssertEqual(try generation(receipt)["normalized_message_count"] as Int, 10_000)
    }

    func testOverMessageBudgetFailsWholeGenerationInsteadOfSavingAPrefix() throws {
        let fixture = try makeFixture()
        var scan = fixture.replay.scan
        scan.messages = Array(repeating: .init(role: .user, content: "not a successful prefix"), count: 100_001)
        let before = try state()
        assertCommitError(.tooManyMessages) { try self.commit(fixture, replay: self.replacing(fixture.replay, scan: scan)) }
        XCTAssertEqual(try state(), before)
    }

    func testOverEncodedPayloadBudgetFailsWholeGenerationWithoutPersistingLargeLogs() throws {
        let fixture = try makeFixture()
        let before = try state()
        // The fixture manifest stays small. The budget must reject this forged
        // in-memory artifact before any database payload or diagnostic is saved.
        var scan = fixture.replay.scan
        scan.messages[1].toolCalls = [.init(name: "Write", input: String(repeating: "x", count: 128 * 1024 * 1024 + 1))]
        assertCommitError(.normalizedPayloadTooLarge) {
            try self.commit(fixture, replay: self.replacing(fixture.replay, scan: scan))
        }
        XCTAssertEqual(try state(), before)
    }

    func testHistoriesAboveTenThousandCommitAndLoadCompleteFirstAndLastWithoutPrefixTruncation() throws {
        let messages = (0..<10_001).map { index in
            NormalizedMessage(role: index.isMultiple(of: 2) ? .user : .assistant,
                              content: "message-\(index)", timestamp: timestamp)
        }
        let fixture = try makeFixture(messages: messages)
        guard let receipt = requireCommit(fixture) else { return }
        let snapshot = try loadSnapshot(receipt)
        XCTAssertEqual(snapshot.messages.count, 10_001)
        XCTAssertEqual(snapshot.messages.first, messages.first)
        XCTAssertEqual(snapshot.messages.last, messages.last)
        XCTAssertTrue(snapshot.messages == messages, "No normalized role, middle element or suffix may be dropped")
        let parent: Data = try generation(receipt)["normalized_messages_json"]
        let encoded = try ArchiveCanonicalJSON.encode(messages)
        XCTAssertNotEqual(parent, encoded, "v2 parent BLOB is the bounded manifest, not the encoded history")
        XCTAssertEqual(try generation(receipt)["normalized_messages_sha256"] as String, ArchiveV2Hash.sha256(parent))
        XCTAssertNotEqual(snapshot.normalizedMessagesSHA256, ArchiveV2Hash.sha256(encoded))
        try assertV2StorageSentinel(receipt, expectedTotal: 10_001)
        XCTAssertEqual(try perMessageRowCount(receipt.generationID), 10_001)
    }

    func testEncodedPayloadAboveLegacyHundredMebibytesCommitsAndLoadsAsBoundedManifest() throws {
        let fixture = try makeFixture()
        var scan = fixture.replay.scan
        scan.messages[1].toolCalls = [.init(name: "Write", input: String(repeating: "x", count: 100 * 1024 * 1024 + 1))]
        let encoded = try ArchiveCanonicalJSON.encode(scan.messages)
        XCTAssertGreaterThan(encoded.count, 100 * 1024 * 1024)
        XCTAssertLessThan(encoded.count, 128 * 1024 * 1024)
        let receipt: CaptureIngestCommittedGeneration
        do { receipt = try commit(fixture, replay: replacing(fixture.replay, scan: scan)) }
        catch {
            XCTFail("eligible complete generation must commit: \(type(of: error))")
            return
        }
        let snapshot = try loadSnapshot(receipt)
        XCTAssertEqual(snapshot.messages.count, scan.messages.count)
        XCTAssertTrue(snapshot.messages == scan.messages, "Do not print large normalized payloads")
        let parent: Data = try generation(receipt)["normalized_messages_json"]
        XCTAssertNotEqual(parent, encoded, "v2 parent BLOB is the bounded manifest, not the encoded history")
        XCTAssertLessThan(parent.count, 64 * 1024)
        XCTAssertEqual(try generation(receipt)["normalized_messages_sha256"] as String, ArchiveV2Hash.sha256(parent))
        try assertV2StorageSentinel(receipt, expectedTotal: scan.messages.count)
        XCTAssertEqual(try perMessageRowCount(receipt.generationID), scan.messages.count)
    }

    func testFreshSchemaKeepsLegacyGenerationChecksAndAddsStorageColumns() throws {
        try assertLegacyGenerationChecks()
        try assertAdditiveNormalizedStoragePresent()
    }

    func testMigratingPopulatedLegacySchemaAddsPerMessageRowsAndPreservesForeignKeysAndV1Hash() throws {
        let fixture = try makeFixture()
        guard let receipt = requireCommit(fixture) else { return }
        let beforeGeneration = try generation(receipt)
        let beforePayload: Data = beforeGeneration["normalized_messages_json"]
        let beforeSHA = beforeGeneration["normalized_messages_sha256"] as String
        let beforeCount = beforeGeneration["normalized_message_count"] as Int
        let beforeBinding = try identity(fixture)
        let beforeGenerationsFK = try foreignKeys("capture_ingest_generations")
        let beforeBindingsFK = try foreignKeys("capture_ingest_identity_bindings")
        let beforeSnapshot = try loadSnapshot(receipt)
        XCTAssertEqual(beforePayload, try ArchiveCanonicalJSON.encode(fixture.replay.scan.messages))
        XCTAssertEqual(beforeSHA, ArchiveV2Hash.sha256(beforePayload))
        XCTAssertEqual(beforeSnapshot.normalizedMessagesSHA256, beforeSHA)
        XCTAssertEqual(beforeSnapshot.messages, fixture.replay.scan.messages)
        XCTAssertEqual(beforeCount, fixture.replay.scan.messages.count)
        XCTAssertEqual(beforeGeneration["normalized_schema_version"] as Int, 1)
        try stripAdditiveNormalizedStorageIfPresent()
        try assertAdditiveNormalizedStorageAbsent()
        try assertLegacyGenerationChecks()
        XCTAssertEqual(try foreignKeys("capture_ingest_generations"), beforeGenerationsFK)
        XCTAssertEqual(try foreignKeys("capture_ingest_identity_bindings"), beforeBindingsFK)
        try writer.migrate()
        try assertAdditiveNormalizedStoragePresent()
        try assertLegacyGenerationChecks()
        let afterGeneration = try generation(receipt)
        XCTAssertEqual(afterGeneration["generation_id"] as String, receipt.generationID)
        XCTAssertEqual(afterGeneration["normalized_messages_json"] as Data, beforePayload)
        XCTAssertEqual(afterGeneration["normalized_messages_sha256"] as String, beforeSHA)
        XCTAssertEqual(afterGeneration["normalized_message_count"] as Int, beforeCount)
        XCTAssertEqual(afterGeneration["normalized_schema_version"] as Int, 1)
        XCTAssertEqual(afterGeneration["normalized_storage_version"] as Int?, 1)
        XCTAssertNil(afterGeneration["normalized_total_message_count"] as Int?)
        XCTAssertEqual(try identity(fixture)["last_parsed_generation_id"] as String,
                       beforeBinding["last_parsed_generation_id"] as String)
        XCTAssertEqual(try foreignKeys("capture_ingest_generations"), beforeGenerationsFK)
        XCTAssertEqual(try foreignKeys("capture_ingest_identity_bindings"), beforeBindingsFK)
        XCTAssertEqual(try count("capture_ingest_generations"), 1)
        XCTAssertEqual(try count("capture_ingest_identity_bindings"), 1)
        let afterSnapshot = try loadSnapshot(receipt)
        XCTAssertEqual(afterSnapshot.messages, beforeSnapshot.messages)
        XCTAssertEqual(afterSnapshot.normalizedMessagesSHA256, beforeSHA)
        XCTAssertEqual(try perMessageRowCount(receipt.generationID), 0)
    }

    func testSelectedPerMessageRowDeletionFailsCompleteLoad() throws {
        let messages = (0..<10_001).map { index in
            NormalizedMessage(role: index.isMultiple(of: 2) ? .user : .assistant,
                              content: "message-\(index)", timestamp: timestamp)
        }
        let fixture = try makeFixture(messages: messages)
        guard let receipt = requireCommit(fixture) else { return }
        XCTAssertEqual(try loadSnapshot(receipt).messages.last, messages.last)
        try writer.write { db in
            try db.execute(sql: """
                DELETE FROM capture_ingest_generation_messages
                WHERE rowid = (
                    SELECT MIN(rowid) FROM capture_ingest_generation_messages WHERE generation_id = ?
                )
                """, arguments: [receipt.generationID])
            XCTAssertEqual(db.changesCount, 1)
        }
        XCTAssertEqual(try perMessageRowCount(receipt.generationID), 10_000)
        assertLoadError(.invalidStoredRecord) { try self.loadSnapshot(receipt) }
    }

    func testNormalizedManifestCorruptionFailsCompleteLoadAboveLegacyCaps() throws {
        let messages = (0..<10_001).map { index in
            NormalizedMessage(role: index.isMultiple(of: 2) ? .user : .assistant,
                              content: "message-\(index)", timestamp: timestamp)
        }
        let fixture = try makeFixture(messages: messages)
        guard let receipt = requireCommit(fixture) else { return }
        let intact = try loadSnapshot(receipt)
        XCTAssertEqual(intact.messages.count, 10_001)
        try writer.write { db in
            try db.execute(sql: """
                UPDATE capture_ingest_generations SET normalized_messages_json = x'FF'
                WHERE generation_id = ?
                """, arguments: [receipt.generationID])
        }
        assertLoadError(.invalidStoredRecord) { try self.loadSnapshot(receipt) }
    }

    func testLoadRangeSlicesValidatedV1HistoryAfterFullPayloadCheck() throws {
        let messages = (0..<8).map { index in
            NormalizedMessage(role: .user, content: "message-\(index)", timestamp: timestamp)
        }
        let fixture = try makeFixture(messages: messages)
        guard let receipt = requireCommit(fixture) else { return }
        try assertPayload(receipt, equals: messages)
        let full = try loadSnapshot(receipt)
        XCTAssertEqual(full.messageStartOrdinal, 0)
        XCTAssertEqual(full.totalMessageCount, 8)
        let slice = try loadSnapshot(receipt, messageRange: 2..<5)
        XCTAssertEqual(slice.messageStartOrdinal, 2)
        XCTAssertEqual(slice.totalMessageCount, 8)
        XCTAssertEqual(slice.messages, Array(messages[2..<5]))
        XCTAssertEqual(slice.normalizedMessagesSHA256, full.normalizedMessagesSHA256)
    }

    func testLoadRangeReadsOnlySelectedV2RowsAfterManifestVerification() throws {
        let messages = (0..<10_001).map { index in
            NormalizedMessage(role: index.isMultiple(of: 2) ? .user : .assistant,
                              content: "message-\(index)", timestamp: timestamp)
        }
        let fixture = try makeFixture(messages: messages)
        guard let receipt = requireCommit(fixture) else { return }
        let first = try loadSnapshot(receipt, messageRange: 0..<1)
        XCTAssertEqual(first.messageStartOrdinal, 0)
        XCTAssertEqual(first.totalMessageCount, 10_001)
        XCTAssertEqual(first.messages, [messages[0]])
        let last = try loadSnapshot(receipt, messageRange: 10_000..<10_001)
        XCTAssertEqual(last.messageStartOrdinal, 10_000)
        XCTAssertEqual(last.totalMessageCount, 10_001)
        XCTAssertEqual(last.messages, [messages[10_000]])
        XCTAssertEqual(first.normalizedMessagesSHA256, last.normalizedMessagesSHA256)
    }

    func testSelectedPerMessageRowCorruptionFailsOnlyRangesThatIncludeIt() throws {
        let messages = (0..<10_001).map { index in
            NormalizedMessage(role: index.isMultiple(of: 2) ? .user : .assistant,
                              content: "message-\(index)", timestamp: timestamp)
        }
        let fixture = try makeFixture(messages: messages)
        guard let receipt = requireCommit(fixture) else { return }
        try writer.write { db in
            try db.execute(sql: """
                UPDATE capture_ingest_generation_messages SET message_json = x'FF'
                WHERE generation_id = ? AND ordinal = 5000
                """, arguments: [receipt.generationID])
            XCTAssertEqual(db.changesCount, 1)
        }
        assertLoadError(.invalidStoredRecord) { try self.loadSnapshot(receipt) }
        assertLoadError(.invalidStoredRecord) { try self.loadSnapshot(receipt, messageRange: 5000..<5001) }
        let other = try loadSnapshot(receipt, messageRange: 0..<1)
        XCTAssertEqual(other.messages, [messages[0]])
        XCTAssertEqual(other.totalMessageCount, 10_001)
    }

    func testLoadPageSelectsSparseMatchingRolesWithoutContiguousWindow() throws {
        let v2Messages = (0..<10_001).map { index in
            NormalizedMessage(role: index.isMultiple(of: 2) ? .user : .assistant,
                              content: "message-\(index)", timestamp: timestamp)
        }
        let v2 = try makeFixture(nativeID: "v2-page", messages: v2Messages)
        guard let v2Receipt = requireCommit(v2) else { return }
        let page = try loadPage(v2Receipt, fromOrdinal: 0, maximumMessages: 2, roles: [.user])
        XCTAssertEqual(page.ordinals, [0, 2])
        XCTAssertEqual(page.snapshot.messages, [v2Messages[0], v2Messages[2]])
        XCTAssertEqual(page.snapshot.messageStartOrdinal, 0)
        XCTAssertEqual(page.snapshot.totalMessageCount, 10_001)
        XCTAssertTrue(page.hasMore)
        let later = try loadPage(v2Receipt, fromOrdinal: 1, maximumMessages: 1, roles: [.user])
        XCTAssertEqual(later.ordinals, [2])
        XCTAssertEqual(later.snapshot.messageStartOrdinal, 2)
        XCTAssertEqual(later.snapshot.messages, [v2Messages[2]])
        XCTAssertTrue(later.hasMore)
        let empty = try loadPage(v2Receipt, fromOrdinal: 10_001, maximumMessages: 1, roles: [.user])
        XCTAssertEqual(empty.ordinals, [])
        XCTAssertEqual(empty.snapshot.messages, [])
        XCTAssertEqual(empty.snapshot.messageStartOrdinal, 10_001)
        XCTAssertEqual(empty.snapshot.totalMessageCount, 10_001)
        XCTAssertFalse(empty.hasMore)
        let first = try ArchiveCanonicalJSON.encode(v2Messages[0]).count
        let budgeted = try loadPage(v2Receipt, fromOrdinal: 0, maximumMessages: 101, roles: [.user],
                                    maximumPayloadBytes: first + 1)
        XCTAssertEqual(budgeted.ordinals, [0, 2, 4], "floor two matches, then one lookahead after the byte budget")
        XCTAssertEqual(budgeted.snapshot.messages, [v2Messages[0], v2Messages[2], v2Messages[4]])
        XCTAssertTrue(budgeted.hasMore)

        let v1Messages: [NormalizedMessage] = [
            .init(role: .user, content: "u0", timestamp: timestamp),
            .init(role: .tool, content: "t1", timestamp: timestamp),
            .init(role: .assistant, content: "a2", timestamp: timestamp),
            .init(role: .user, content: "u3", timestamp: timestamp),
        ]
        let v1 = try makeFixture(nativeID: "v1-page", messages: v1Messages)
        guard let v1Receipt = requireCommit(v1) else { return }
        try assertPayload(v1Receipt, equals: v1Messages)
        let v1Page = try loadPage(v1Receipt, fromOrdinal: 0, maximumMessages: 2, roles: [.user])
        XCTAssertEqual(v1Page.ordinals, [0, 3])
        XCTAssertEqual(v1Page.snapshot.messages, [v1Messages[0], v1Messages[3]])
        XCTAssertEqual(v1Page.snapshot.messageStartOrdinal, 0)
        XCTAssertEqual(v1Page.snapshot.totalMessageCount, 4)
        XCTAssertFalse(v1Page.hasMore)
    }

    func testLoadPageHasMoreWhenExactlyOneMatchingOrdinalRemainsAfterAFullPage_repro() throws {
        let messages: [NormalizedMessage] = [
            .init(role: .user, content: "u0", timestamp: timestamp),
            .init(role: .user, content: "u1", timestamp: timestamp),
            .init(role: .user, content: "u2", timestamp: timestamp),
        ]
        let fixture = try makeFixture(messages: messages)
        guard let receipt = requireCommit(fixture) else { return }
        try assertPayload(receipt, equals: messages)
        let first = try loadPage(receipt, fromOrdinal: 0, maximumMessages: 2, roles: [.user])
        XCTAssertEqual(first.ordinals, [0, 1])
        XCTAssertEqual(first.snapshot.messages, [messages[0], messages[1]])
        XCTAssertTrue(first.hasMore, "the remaining matching ordinal must not be skipped by the page cursor")
        let rest = try loadPage(receipt, fromOrdinal: first.ordinals.last! + 1, maximumMessages: 2, roles: [.user])
        XCTAssertEqual(rest.ordinals, [2])
        XCTAssertEqual(rest.snapshot.messages, [messages[2]])
        XCTAssertEqual(rest.snapshot.messageStartOrdinal, 2)
        XCTAssertFalse(rest.hasMore)
    }

    func testManifestRoleMismatchFailsCompleteLoadAndSelectedPage() throws {
        let messages = (0..<10_001).map { index in
            NormalizedMessage(role: index.isMultiple(of: 2) ? .user : .assistant,
                              content: "message-\(index)", timestamp: timestamp)
        }
        let fixture = try makeFixture(messages: messages)
        guard let receipt = requireCommit(fixture) else { return }
        let replacement = NormalizedMessage(role: .assistant, content: "role-mismatch", timestamp: timestamp)
        let bytes = try ArchiveCanonicalJSON.encode(replacement)
        try writer.write { db in
            try db.execute(sql: """
                UPDATE capture_ingest_generation_messages
                SET message_json = ?, message_sha256 = ?, message_byte_size = ?
                WHERE generation_id = ? AND ordinal = 0
                """, arguments: [bytes, ArchiveV2Hash.sha256(bytes), bytes.count, receipt.generationID])
            XCTAssertEqual(db.changesCount, 1)
        }
        assertLoadError(.invalidStoredRecord) { try self.loadSnapshot(receipt) }
        assertLoadError(.invalidStoredRecord) { try self.loadSnapshot(receipt, messageRange: 0..<1) }
        assertLoadError(.invalidStoredRecord) {
            try self.loadPage(receipt, fromOrdinal: 0, maximumMessages: 1, roles: [.user])
        }
        let assistants = try loadPage(receipt, fromOrdinal: 1, maximumMessages: 1, roles: [.assistant])
        XCTAssertEqual(assistants.ordinals, [1])
        XCTAssertEqual(assistants.snapshot.messages, [messages[1]])
        XCTAssertTrue(assistants.hasMore)
    }

    func testNewGenerationWithSameHashGetsNewSyncVersionAndExactFTSJob() throws {
        let first = try makeFixture(sequence: 100)
        guard let one = requireCommit(first) else { return }
        let immutable = try generation(one)
        let second = try makeFixture(sequence: 101)
        guard let two = requireCommit(second) else { return }
        XCTAssertEqual(two.snapshotHash, one.snapshotHash)
        XCTAssertEqual(two.syncVersion, 2)
        XCTAssertNotEqual(two.generationID, one.generationID)
        XCTAssertNotEqual(two.requiredFTSJobID, one.requiredFTSJobID)
        XCTAssertEqual(try generation(one), immutable)
        XCTAssertEqual(try count("capture_ingest_generations"), 2)
        try assertExactPendingFTS(two)
        XCTAssertEqual(try identity(second)["last_parsed_generation_id"] as String, two.generationID)
        XCTAssertNil(try identity(second)["last_ready_generation_id"] as String?)
    }

    func testAnotherIdentityHigherStreamSequenceDoesNotRejectLegalLowerSequence() throws {
        let high = try makeFixture(nativeID: "other-session", sequence: 9_000)
        guard requireCommit(high) != nil else { return }
        let low = try makeFixture(nativeID: "native-session", sequence: 2)
        guard let committed = requireCommit(low) else { return }
        XCTAssertEqual(committed.syncVersion, 1)
        XCTAssertEqual(try count("capture_ingest_identity_bindings"), 2)
        XCTAssertEqual(try count("sessions"), 2)
        try assertExactPendingFTS(committed)
    }

    func testOlderIdentitySequenceIsRejectedBeforeNoopSidecarsOrOrphanRecovery() throws {
        let latest = try makeFixture(sequence: 50)
        guard let current = requireCommit(latest) else { return }
        try writer.write { try $0.execute(sql: "UPDATE sessions SET orphan_status = 'orphaned', orphan_reason = 'keep' WHERE id = ?",
                                         arguments: [current.sessionID]) }
        let older = try makeFixture(sequence: 49, messages: [
            .init(role: .user, content: "Replace sidecars incorrectly."),
            .init(role: .assistant, content: "Incorrect old result.",
                  toolCalls: [.init(name: "WrongOldTool", input: "old")],
                  usage: .init(inputTokens: 999, outputTokens: 999)),
        ])
        let before = try state()
        assertCommitError(.obsoleteGeneration) { try self.commit(older) }
        XCTAssertEqual(try state(), before)
    }

    func testEqualStreamSequenceDifferentPublicationNeverCreatesSecondGeneration() throws {
        let first = try makeFixture(sequence: 7)
        guard let committed = requireCommit(first) else { return }
        let productBefore = try productState()
        let competing = try CollectorPublicationEnvelope(machineID: machine, sourceInstanceID: instance,
            collectorEpoch: epoch, sequence: 7, manifestSHA256: String(repeating: "0", count: 64))
        _ = try accept(competing, parser: revision)
        let conflict = try writer.read { try XCTUnwrap(Row.fetchOne($0,
            sql: "SELECT status, failure_code FROM capture_ingest_ledger WHERE publication_sha256 = ? AND parser_revision = ?",
            arguments: [competing.sha256(), revision])) }
        XCTAssertEqual(conflict["status"] as String, "quarantined")
        XCTAssertEqual(conflict["failure_code"] as String, "sequence_conflict")
        XCTAssertNil(try writer.write { try CaptureIngestLedger.claim($0, publicationSHA256: competing.sha256(),
                                                                     parserRevision: revision, now: 101, leaseDuration: 10) })
        assertLedgerError(.claimLost) { try self.commit(first) }
        XCTAssertEqual(try productState(), productBefore)
        XCTAssertEqual(try identity(first)["last_parsed_generation_id"] as String, committed.generationID)
    }

    func testSamePublicationCanReparseOnlyAsNewTrustedRevisionWithoutLexicalOrdering() throws {
        let first = try makeFixture()
        guard let one = requireCommit(first) else { return }
        let next = try withRevision(first, parser: "swift-parser-a")
        guard let two = requireCommit(next, expectedRevision: "swift-parser-a") else { return }
        XCTAssertEqual(next.claim.publicationSHA256, first.claim.publicationSHA256)
        XCTAssertNotEqual(two.generationID, one.generationID)
        XCTAssertEqual(two.syncVersion, 2)
        XCTAssertEqual(two.snapshotHash, one.snapshotHash)
        XCTAssertEqual(try count("capture_ingest_generations"), 2)
        try assertExactPendingFTS(two)
    }

    func testOldClaimRevisionFailsAgainstTrustedCurrentRevisionAndCannotSortItsWayIn() throws {
        let fixture = try makeFixture()
        let before = try state()
        assertCommitError(.parserRevisionChanged) { try self.commit(fixture, expectedRevision: "swift-parser-a") }
        XCTAssertEqual(try state(), before)
        let composed = try withRevision(fixture, parser: "parser-é")
        let unicodeBefore = try state()
        assertCommitError(.parserRevisionChanged) { try self.commit(composed, expectedRevision: "parser-e\u{301}") }
        XCTAssertEqual(try state(), unicodeBefore, "revision equality is byte exact, not Unicode equivalence")
    }

    func testExpectedParserRevisionMustSatisfyTheExistingBoundedRevisionContract() throws {
        let fixture = try makeFixture()
        let before = try state()
        for invalid in ["", " leading", "trailing ", "bad\0revision", String(repeating: "x", count: 129)] {
            assertCommitError(.invalidParserRevision) { try self.commit(fixture, expectedRevision: invalid) }
            XCTAssertEqual(try state(), before)
        }
    }

    func testSamePublicationRevisionReplayNeverResetsAnyExistingJobState() throws {
        let fixture = try makeFixture()
        guard let receipt = requireCommit(fixture), let jobID = receipt.requiredFTSJobID else { return }
        for status in ["pending", "processing", "failed_retryable", "failed_permanent", "completed", "not_applicable"] {
            try writer.write { try $0.execute(sql: """
                UPDATE session_index_jobs SET status = ?, retry_count = 8, last_error = 'preserved',
                    created_at = '2001-01-01', updated_at = '2002-02-02', not_before = '2003-03-03'
                WHERE id = ?
                """, arguments: [status, jobID]) }
            let before = try state()
            XCTAssertNil(try claim(fixture))
            assertLedgerError(.claimLost) { try self.commit(fixture) }
            XCTAssertEqual(try state(), before, status)
        }
    }

    func testRestartDoesNotDuplicateCommittedGenerationOrAdvanceItsHead() throws {
        let fixture = try makeFixture()
        guard let receipt = requireCommit(fixture) else { return }
        let before = try state()
        writer = nil
        writer = try EngramDatabaseWriter(path: databasePath)
        try writer.migrate()
        XCTAssertNil(try claim(fixture))
        assertLedgerError(.claimLost) { try self.commit(fixture) }
        XCTAssertEqual(try state(), before)
        XCTAssertEqual(try identity(fixture)["last_parsed_generation_id"] as String, receipt.generationID)
    }

    func testIndependentWritersCannotCommitTheSameClaimTwice() async throws {
        let fixture = try makeFixture()
        let firstWriter = try XCTUnwrap(writer)
        let secondWriter = try EngramDatabaseWriter(path: databasePath)
        let parser = revision
        let indexedAt = timestamp
        let attempts = await withTaskGroup(of: CommitAttempt.self) { group in
            for current in [firstWriter, secondWriter] {
                group.addTask {
                    do {
                        let receipt = try current.write { try CaptureIngestCommitter.commitParsed($0,
                            claim: fixture.claim, replay: fixture.replay, expectedParserRevision: parser,
                            now: 101, indexedAt: indexedAt) }
                        return .committed(receipt)
                    } catch CaptureIngestLedgerError.claimLost {
                        return .claimLost
                    } catch {
                        return .unexpected(String(describing: type(of: error)))
                    }
                }
            }
            var result: [CommitAttempt] = []
            for await attempt in group { result.append(attempt) }
            return result
        }
        var receipts: [CaptureIngestCommittedGeneration] = []
        var rejected = 0
        for attempt in attempts {
            switch attempt {
            case .committed(let receipt): receipts.append(receipt)
            case .claimLost: rejected += 1
            case .unexpected(let type): XCTFail("competing commit must not throw an unrelated error: \(type)")
            }
        }
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(rejected, 1)
        guard let receipt = receipts.first else { return }
        XCTAssertEqual(try count("capture_ingest_generations"), 1)
        XCTAssertEqual(try count("sessions"), 1)
        try assertExactPendingFTS(receipt)
        try assertParsedOnly(fixture, receipt: receipt)
    }

    func testApprovedNewAuthoritySequenceOneSupersedesOldThousandWithoutMovingReadyHead() throws {
        let old = try makeFixture(sequence: 1_000)
        guard let one = requireCommit(old) else { return }
        try markReadyForFixture(old, receipt: one)
        let immutable = try generation(one)
        _ = try approveNextEpoch()
        let next = try makeFixture(sequence: 1)
        guard let two = requireCommit(next) else { return }
        XCTAssertEqual(two.syncVersion, 2)
        XCTAssertEqual(try generation(two)["authority_generation"] as Int64, 2)
        XCTAssertEqual(try generation(two)["sequence"] as Int64, 1)
        XCTAssertEqual(try identity(next)["last_ready_generation_id"] as String, one.generationID)
        XCTAssertEqual(try generation(one), immutable)
        XCTAssertEqual(try ledger(old)["status"] as String, "index_ready")
        XCTAssertEqual(try ledger(next)["status"] as String, "parsed")
    }

    func testUnknownEpochAndRegistryChangeAfterReplayCannotGrantCommitAuthority() throws {
        let unknown = try makeFixture(publicationEpoch: nextEpoch)
        let before = try state()
        assertCommitError(.bindingChanged) { try self.commit(unknown) }
        XCTAssertEqual(try state(), before)
        let old = try makeFixture(sequence: 2)
        _ = try approveNextEpoch()
        let afterApproval = try state()
        assertCommitError(.bindingChanged) { try self.commit(old) }
        XCTAssertEqual(try state(), afterApproval)
    }

    func testEveryBindingSnapshotFieldIsRecheckedWithByteExactStrings() throws {
        let fixture = try makeFixture()
        let original = fixture.replay.bindingSnapshot
        let variants = [
            binding(original, machineID: otherMachine), binding(original, instanceID: otherInstance),
            binding(original, source: .codex), binding(original, format: .claudeCustomProfile),
            binding(original, root: logicalRoot + "/different"), binding(original, approvedEpoch: nextEpoch),
            binding(original, authority: 2),
        ]
        let before = try state()
        for changed in variants {
            assertCommitError(.bindingChanged) { try self.commit(fixture, replay: self.replacing(fixture.replay, binding: changed)) }
            XCTAssertEqual(try state(), before)
        }
    }

    func testRegistryFieldsChangedAfterReplayRejectWithoutAnyCommitSideEffects() throws {
        let fixture = try makeFixture()
        let fields: [(String, DatabaseValue, DatabaseValue)] = [
            ("machine_id", otherMachine.databaseValue, machine.databaseValue),
            ("source_instance_id", otherInstance.databaseValue, instance.databaseValue),
            ("source", "codex".databaseValue, "claude-code".databaseValue),
            ("parse_format", "claudeCustomProfile".databaseValue, "claudeDefault".databaseValue),
            ("configured_root", (logicalRoot + "/changed").databaseValue, logicalRoot.databaseValue),
            ("approved_epoch", nextEpoch.databaseValue, epoch.databaseValue),
            ("authority_generation", Int64(2).databaseValue, Int64(1).databaseValue),
        ]
        for (column, changed, original) in fields {
            try mutateRegistryField(column, value: changed)
            let afterDrift = try state()
            XCTAssertThrowsError(try commit(fixture)) { error in
                // Single-field corruption may invalidate the registry's own
                // history check before the complete binding can be compared.
                XCTAssertTrue(error as? CaptureIngestCommitError == .bindingChanged
                    || error as? CaptureIngestSourceRegistryError == .invalidStoredBinding, column)
            }
            XCTAssertEqual(try state(), afterDrift, column)
            try mutateRegistryField(column, value: original)
        }
    }

    func testExpiredLeaseBoundaryAndNegativeTimeRejectBeforeAnyCommitWrites() throws {
        let fixture = try makeFixture()
        let before = try state()
        assertLedgerError(.invalidTime) { try self.commit(fixture, now: -1) }
        assertLedgerError(.invalidTime) { try self.commit(fixture, now: 99) }
        assertLedgerError(.claimLost) { try self.commit(fixture, now: 110) }
        XCTAssertEqual(try state(), before)
    }

    func testReclaimedTokenRevokesOldCommitButNewClaimCanCommit() throws {
        let fixture = try makeFixture()
        let renewed = try XCTUnwrap(claim(fixture, now: 110))
        XCTAssertNotEqual(renewed.token, fixture.claim.token)
        let before = try state()
        assertLedgerError(.claimLost) { try self.commit(fixture, now: 111) }
        XCTAssertEqual(try state(), before)
        guard let receipt = requireCommit(fixture.withClaim(renewed), now: 111) else { return }
        XCTAssertEqual(receipt.syncVersion, 1)
    }

    func testNonProcessingLedgerStateAlwaysRevokesFormerToken() throws {
        for (index, status) in ["pending", "parsed", "index_ready", "quarantined", "failed_retryable"].enumerated() {
            let fixture = try makeFixture(nativeID: "state-\(index)", sequence: Int64(index + 1))
            try writer.write { try $0.execute(sql: "UPDATE capture_ingest_ledger SET status = ? WHERE publication_sha256 = ?",
                                             arguments: [status, fixture.claim.publicationSHA256]) }
            let before = try state()
            assertLedgerError(.claimLost) { try self.commit(fixture) }
            XCTAssertEqual(try state(), before)
        }
    }

    func testPostClaimCanonicalPublicationCorruptionCannotReachTheSnapshotWriter() throws {
        let fixture = try makeFixture()
        try writer.write { try $0.execute(sql: "UPDATE capture_ingest_publications SET canonical_bytes = ? WHERE publication_sha256 = ?",
                                         arguments: [Data("corrupt".utf8), fixture.claim.publicationSHA256]) }
        let before = try state()
        assertLedgerError(.invalidStoredRecord) { try self.commit(fixture) }
        XCTAssertEqual(try state(), before)
    }

    func testForgedReplayPublicationManifestIdentityAndScanRelationshipsAreRejected() throws {
        let fixture = try makeFixture()
        let replay = fixture.replay
        var wrongID = replay.scan
        wrongID.info.id = "forged-native"
        var wrongSource = replay.scan
        wrongSource.info.source = .codex
        var wrongLocator = replay.scan
        wrongLocator.info.filePath = "/private/staging/forged.jsonl"
        let anotherIdentity = try replay.nativeIdentity.mapping(nativeID: "different-native")
        let crossNamespaceParent = try CaptureIngestIdentity(machineID: otherMachine, sourceInstanceID: instance,
                                                           source: .claudeCode, nativeID: "parent")
        let anotherManifest = try manifest(binding: replay.bindingSnapshot, nativeID: "native-session", sequence: 999,
                                          messages: replay.scan.messages, captureSalt: "wrong-manifest")
        let variants = [
            replacing(replay, digest: String(repeating: "0", count: 64)),
            replacing(replay, manifest: anotherManifest), replacing(replay, identity: anotherIdentity),
            replacing(replay, scan: wrongID), replacing(replay, scan: wrongSource), replacing(replay, scan: wrongLocator),
            replacing(replay, rawNativeID: ""), replacing(replay, rawNativeID: "bad\0native"),
            replacing(replay, parent: crossNamespaceParent), replacing(replay, suggested: crossNamespaceParent),
        ]
        let before = try state()
        for variant in variants {
            assertCommitError(.invalidReplay) { try self.commit(fixture, replay: variant) }
            XCTAssertEqual(try state(), before)
        }
    }

    func testEveryPartialParseFailureRejectsCompleteLookingMessagePrefixes() throws {
        let fixture = try makeFixture()
        let before = try state()
        for failure in ParserFailure.allCases {
            var scan = fixture.replay.scan
            scan.parseFailure = failure
            assertCommitError(.invalidReplay) { try self.commit(fixture, replay: self.replacing(fixture.replay, scan: scan)) }
            XCTAssertEqual(try state(), before, failure.rawValue)
        }
    }

    func testJSONEscapeExpansionCountsAgainstTheEncodedPayloadBudget() throws {
        let fixture = try makeFixture()
        var scan = fixture.replay.scan
        scan.messages[1].toolCalls = [.init(name: "Write", output: String(repeating: "\u{0001}", count: 22 * 1024 * 1024))]
        let before = try state()
        assertCommitError(.normalizedPayloadTooLarge) {
            try self.commit(fixture, replay: self.replacing(fixture.replay, scan: scan))
        }
        XCTAssertTrue(try state() == before, "the encoded JSON bytes, not Swift character count, set the budget")
    }

    func testSeventeenSharedSixtyFourMebibyteStringsRejectTheAggregateStorageCapWithoutBuildingTheEncodedArray() throws {
        let fixture = try makeFixture()
        let shared = String(repeating: "x", count: 64 * 1024 * 1024)
        var scan = fixture.replay.scan
        scan.messages = (0..<17).map { _ in NormalizedMessage(role: .user, content: shared) }
        let before = try state()
        assertCommitError(.normalizedPayloadTooLarge) {
            try self.commit(fixture, replay: self.replacing(fixture.replay, scan: scan))
        }
        XCTAssertTrue(try state() == before, "Do not print large normalized payloads")
    }

    func testMachineInstanceSourceAndExactNativeBytesKeepDistinctIdentities() throws {
        let fixtures = [
            try makeFixture(nativeID: "native-é", sequence: 1),
            try makeFixture(nativeID: "native-e\u{301}", sequence: 2),
            try makeFixture(nativeID: "native-é", sequence: 1, machineID: otherMachine),
            try makeFixture(nativeID: "native-é", sequence: 1, instanceID: otherInstance,
                            root: "/offline-client/second-profile/projects"),
            try makeFixture(nativeID: "native-é", sequence: 1, source: .codex,
                            instanceID: nextEpoch, root: "/offline-client/.codex/sessions"),
        ]
        var storedIDs: [String] = []
        for fixture in fixtures {
            guard let receipt = requireCommit(fixture) else { return }
            storedIDs.append(receipt.sessionID)
            XCTAssertTrue((try identity(fixture)["native_id"] as String).utf8.elementsEqual(fixture.replay.nativeIdentity.nativeID.utf8))
        }
        XCTAssertEqual(Set(storedIDs).count, fixtures.count)
        XCTAssertEqual(try count("sessions"), fixtures.count)
        XCTAssertEqual(try count("capture_ingest_identity_bindings"), fixtures.count)
    }

    func testExistingProposedIDWithoutProvenBindingIsRejectedEvenForMatchingOwner() throws {
        for (index, owner) in ["local", "capture-v1.\(machine).\(instance)", "legacy-hq"].enumerated() {
            let fixture = try makeFixture(nativeID: "collision-\(index)", sequence: Int64(index + 1))
            let proposed = try fixture.replay.nativeIdentity.proposedSessionID()
            try seedSession(id: proposed, owner: owner)
            let before = try state()
            assertCommitError(.identityConflict) { try self.commit(fixture) }
            XCTAssertEqual(try state(), before, "matching string namespace is not alias proof")
        }
    }

    func testUnprovedSameNativeLocalRowCanCoexistWithoutAliasOrUserDataChanges() throws {
        let fixture = try makeFixture()
        let localID = fixture.replay.nativeIdentity.nativeID
        try seedSession(id: localID, owner: "local")
        try writer.write { db in
            try db.execute(sql: "INSERT INTO session_local_state(session_id, hidden_at, custom_name, local_readable_path) VALUES (?, '2001-01-01', 'keep-local-name', '/legacy/keep.jsonl')",
                           arguments: [localID])
            try db.execute(sql: "INSERT INTO insights(id, content, source_session_id) VALUES ('local-insight', 'keep local insight', ?)",
                           arguments: [localID])
        }
        let localBefore = try session(localID)
        let dependenciesBefore = try writer.read { try state($0, tables: ["session_local_state", "insights"]) }
        guard let receipt = requireCommit(fixture) else { return }
        XCTAssertNotEqual(receipt.sessionID, localID)
        XCTAssertEqual(try session(localID), localBefore)
        XCTAssertEqual(try writer.read { try state($0, tables: ["session_local_state", "insights"]) }, dependenciesBefore)
        XCTAssertEqual(try count("sessions"), 2)
        XCTAssertEqual(try count("capture_ingest_identity_bindings"), 1)
        XCTAssertEqual(try identity(fixture)["stored_session_id"] as String, receipt.sessionID)
        // No same-machine proof is inferred from native ID or path coincidence.
        // Legacy alias/cutover proof is deliberately outside this shadow-DB slice.
    }

    func testPersistedIdentityCannotTransferToAnUnprovedStoredIDOrForeignOwner() throws {
        let first = try makeFixture()
        guard let one = requireCommit(first) else { return }
        let next = try makeFixture(sequence: 2)
        try seedSession(id: "foreign", owner: "local")
        try writer.write { try $0.execute(sql: "UPDATE capture_ingest_identity_bindings SET stored_session_id = 'foreign'") }
        let redirected = try state()
        assertCommitError(.identityConflict) { try self.commit(next) }
        XCTAssertEqual(try state(), redirected)
        try writer.write { db in
            try db.execute(sql: "UPDATE capture_ingest_identity_bindings SET stored_session_id = ?", arguments: [one.sessionID])
            try db.execute(sql: "UPDATE sessions SET authoritative_node = 'foreign-owner' WHERE id = ?", arguments: [one.sessionID])
        }
        let wrongOwner = try state()
        assertCommitError(.identityConflict) { try self.commit(next) }
        XCTAssertEqual(try state(), wrongOwner)
    }

    func testNextSyncVersionChecksMaximumOfRowBindingAndImmutableGenerationHistory() throws {
        for (index, counter) in ["session", "binding", "generation"].enumerated() {
            let first = try makeFixture(nativeID: "version-\(index)", sequence: Int64(index * 2 + 1))
            guard let one = requireCommit(first) else { return }
            try setVersion(counter, receipt: one, value: .int64(50))
            let next = try makeFixture(nativeID: "version-\(index)", sequence: Int64(index * 2 + 2))
            guard let two = requireCommit(next) else { return }
            XCTAssertEqual(two.syncVersion, 51, counter)
            try assertExactPendingFTS(two)
        }
    }

    func testCommitMaterializesBoundedHistoryRowsForManyGenerations() throws {
        let first = try makeFixture(sequence: 1)
        guard let one = requireCommit(first) else { return }
        try seedHistory(from: one, versions: 2...64)
        XCTAssertEqual(try count("capture_ingest_generations"), 64)
        let next = try makeFixture(sequence: 2)

        // SQLITE_TRACE_ROW measures result rows crossing into Swift, not rows
        // scanned by SQLite. The bound does not claim constant SQL scan work.
        var historyRows = 0
        let two = try withUnsafeMutablePointer(to: &historyRows) { counter in
            try writer.write { db in
                XCTAssertEqual(sqlite3_trace_v2(db.sqliteConnection, UInt32(SQLITE_TRACE_ROW), { _, context, statement, _ in
                    guard let context, let statement,
                          let rawSQL = sqlite3_sql(OpaquePointer(statement)) else { return 0 }
                    let sql = String(cString: rawSQL).lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                    if sql.hasPrefix("select ") && sql.contains("from capture_ingest_generations") {
                        context.assumingMemoryBound(to: Int.self).pointee += 1
                    }
                    return 0
                }, counter), SQLITE_OK)
                defer { sqlite3_trace_v2(db.sqliteConnection, 0, nil, nil) }
                return try CaptureIngestCommitter.commitParsed(db, claim: next.claim, replay: next.replay,
                    expectedParserRevision: revision, now: 101, indexedAt: timestamp)
            }
        }
        XCTAssertGreaterThan(historyRows, 0, "the production history reads must actually be measured")
        XCTAssertLessThanOrEqual(historyRows, 4, "history result materialization must stay bounded as generations grow")
        XCTAssertEqual(two.syncVersion, 65, "non-head history still participates in the maximum")
        try assertExactPendingFTS(two)
    }

    func testNonHeadCorruptHistoryRejectsDespiteValidHeadAndLargerValidCounters() throws {
        let first = try makeFixture(nativeID: "native-é", sequence: 1)
        guard let one = requireCommit(first) else { return }
        let historicalID = try XCTUnwrap(seedHistory(from: one, versions: 2...2).first)
        try setVersion("session", receipt: one, value: .int64(50))
        try setVersion("binding", receipt: one, value: .int64(50))
        let next = try makeFixture(nativeID: "native-é", sequence: 2)
        let originalIdentity: [String: DatabaseValue] = [
            "machine_id": machine.databaseValue, "source_instance_id": instance.databaseValue,
            "source": "claude-code".databaseValue, "native_id": "native-é".databaseValue,
        ]
        let variants: [(String, DatabaseValue)] = [
            ("machine_id", otherMachine.databaseValue), ("source_instance_id", otherInstance.databaseValue),
            ("source", "codex".databaseValue), ("native_id", "native-e\u{301}".databaseValue),
            ("machine_id", Data(machine.utf8).databaseValue),
            ("source_instance_id", Data(instance.utf8).databaseValue),
            ("source", Data("claude-code".utf8).databaseValue), ("native_id", Data("native-é".utf8).databaseValue),
            ("sync_version", "not-an-integer".databaseValue), ("sync_version", 1.5.databaseValue),
            ("sync_version", Data([2]).databaseValue), ("sync_version", Int64(0).databaseValue),
            ("sync_version", Int64(-1).databaseValue),
        ]
        for (index, variant) in variants.enumerated() {
            let (column, value) = variant
            if column != "sync_version" {
                let foreignID = "corrupt-history-identity-\(index)"
                try seedSession(id: foreignID, owner: "local")
                var foreign = originalIdentity
                foreign[column] = value
                // Keep the composite FK valid while making provenance disagree
                // with the generation's stored session. No FK bypass is needed.
                try writer.write { try $0.execute(sql: """
                    INSERT INTO capture_ingest_identity_bindings(machine_id, source_instance_id, source, native_id, stored_session_id)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: [foreign["machine_id"]!, foreign["source_instance_id"]!, foreign["source"]!,
                                       foreign["native_id"]!, foreignID.databaseValue]) }
            }
            try writer.write { db in
                // Deliberately seed zero/negative historical corruption in this
                // isolated fixture, then restore CHECK enforcement immediately.
                try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
                defer { XCTAssertNoThrow(try db.execute(sql: "PRAGMA ignore_check_constraints = OFF")) }
                try db.execute(sql: "UPDATE capture_ingest_generations SET \(column) = ? WHERE generation_id = ?",
                               arguments: [value, historicalID])
            }
            XCTAssertEqual(try identity(next)["last_parsed_generation_id"] as String, one.generationID)
            let before = try state()
            assertCommitError(.invalidStoredRecord) { try self.commit(next) }
            XCTAssertEqual(try state(), before, "non-head corruption variant \(index): \(column)")
            try writer.write { try $0.execute(sql: "UPDATE capture_ingest_generations SET \(column) = ? WHERE generation_id = ?",
                arguments: [originalIdentity[column] ?? Int64(2).databaseValue, historicalID]) }
        }
        guard let two = requireCommit(next) else { return }
        XCTAssertEqual(two.syncVersion, 51, "failed attempts preserve the claim and valid maximum counters")
    }

    func testOverflowInAnyRelatedSyncVersionRejectsAtomically() throws {
        for (index, counter) in ["session", "binding", "generation"].enumerated() {
            let first = try makeFixture(nativeID: "overflow-\(index)", sequence: Int64(index * 2 + 1))
            guard let one = requireCommit(first) else { return }
            try setVersion(counter, receipt: one, value: .int64(Int64.max))
            let next = try makeFixture(nativeID: "overflow-\(index)", sequence: Int64(index * 2 + 2))
            let before = try state()
            assertCommitError(.syncVersionOverflow) { try self.commit(next) }
            XCTAssertEqual(try state(), before, counter)
        }
    }

    func testMalformedPersistedVersionCannotCoerceToAValidOrderingCounter() throws {
        for (index, malformed) in [DatabaseValue.Storage.int64(-1), .string("not-an-integer"), .double(1.5)].enumerated() {
            let first = try makeFixture(nativeID: "malformed-version-\(index)", sequence: Int64(index * 2 + 1))
            guard let one = requireCommit(first) else { return }
            try setVersion("session", receipt: one, value: malformed)
            let next = try makeFixture(nativeID: "malformed-version-\(index)", sequence: Int64(index * 2 + 2))
            let before = try state()
            assertCommitError(.invalidStoredRecord) { try self.commit(next) }
            XCTAssertEqual(try state(), before)
        }
    }

    func testKnownParentMapsOnlyInsideItsNamespaceAndSuggestedParentDoesNotBecomeALink() throws {
        let parent = try makeFixture(nativeID: "parent", sequence: 1)
        guard let parentReceipt = requireCommit(parent) else { return }
        let child = try makeFixture(nativeID: "child", sequence: 2, parentNativeID: "parent", suggestedNativeID: "other-hint")
        guard let childReceipt = requireCommit(child) else { return }
        XCTAssertEqual(try session(childReceipt.sessionID)["parent_session_id"] as String, parentReceipt.sessionID)
        XCTAssertEqual(try generation(childReceipt)["parent_native_id"] as String, "parent")
        XCTAssertEqual(try generation(childReceipt)["suggested_parent_native_id"] as String, "other-hint")
        let hintOnly = try makeFixture(nativeID: "hint-only", sequence: 3, suggestedNativeID: "parent")
        guard let hintReceipt = requireCommit(hintOnly) else { return }
        XCTAssertNil(try session(hintReceipt.sessionID)["parent_session_id"] as String?)
        XCTAssertEqual(try generation(hintReceipt)["suggested_parent_native_id"] as String, "parent")
    }

    func testUnknownOrCrossNamespaceParentRemainsUnlinkedWithoutLosingNativeProvenance() throws {
        let foreignParent = try makeFixture(nativeID: "parent", machineID: otherMachine)
        guard requireCommit(foreignParent) != nil else { return }
        let child = try makeFixture(nativeID: "child", sequence: 2, parentNativeID: "parent")
        guard let receipt = requireCommit(child) else { return }
        XCTAssertNil(try session(receipt.sessionID)["parent_session_id"] as String?)
        XCTAssertEqual(try generation(receipt)["parent_native_id"] as String, "parent")
        XCTAssertEqual(try count("capture_ingest_identity_bindings"), 2, "do not create an unproved placeholder parent binding")
    }

    func testManualUnlinkStaysAuthoritativeAcrossCapturedGenerations() throws {
        let parent = try makeFixture(nativeID: "parent", sequence: 1)
        guard requireCommit(parent) != nil else { return }
        let child = try makeFixture(nativeID: "child", sequence: 2, parentNativeID: "parent")
        guard let one = requireCommit(child) else { return }
        try writer.write { try $0.execute(sql: "UPDATE sessions SET parent_session_id = NULL, link_source = 'manual' WHERE id = ?",
                                         arguments: [one.sessionID]) }
        let next = try makeFixture(nativeID: "child", sequence: 3, parentNativeID: "parent")
        guard let two = requireCommit(next) else { return }
        XCTAssertNil(try session(two.sessionID)["parent_session_id"] as String?)
        XCTAssertEqual(try session(two.sessionID)["link_source"] as String, "manual")
    }

    func testSkipPayloadIsPreservedWithoutFTSOrReadyPromotionAndPinnedDispatchStaysSkip() throws {
        let skipped = try makeFixture(nativeID: "dispatched", sequence: 1, agentRole: "dispatched")
        guard let receipt = requireCommit(skipped) else { return }
        XCTAssertEqual(try session(receipt.sessionID)["tier"] as String, "skip")
        XCTAssertNil(receipt.requiredFTSJobID)
        XCTAssertNil(try generation(receipt)["required_fts_job_id"] as String?)
        try assertPayload(receipt, equals: skipped.replay.scan.messages)
        try assertParsedOnly(skipped, receipt: receipt)
        let ordinary = try makeFixture(nativeID: "pinned-skip", sequence: 2)
        guard let normal = requireCommit(ordinary) else { return }
        try writer.write { try $0.execute(sql: "UPDATE sessions SET tier = 'skip', agent_role = 'dispatched' WHERE id = ?",
                                         arguments: [normal.sessionID]) }
        let next = try makeFixture(nativeID: "pinned-skip", sequence: 3)
        guard let preserved = requireCommit(next) else { return }
        XCTAssertEqual(try session(preserved.sessionID)["tier"] as String, "skip")
        XCTAssertNil(preserved.requiredFTSJobID)
        XCTAssertEqual(try writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM session_index_jobs WHERE session_id = ? AND target_sync_version = ?",
                                                        arguments: [preserved.sessionID, preserved.syncVersion]) }, 0)
    }

    func testCapturedFileToolsPersistPathActionCountsWithoutPromotingSkip() throws {
        let fixture = try makeFixture(nativeID: "file-activity", sequence: 1,
                                      messages: fileActivityMessages(), agentRole: "dispatched")
        guard let receipt = requireCommit(fixture) else { return }
        XCTAssertEqual(try session(receipt.sessionID)["tier"] as String, "skip")
        XCTAssertNil(receipt.requiredFTSJobID)
        XCTAssertEqual(try sessionFiles(receipt.sessionID), [
            FileRow(path: "/tmp/a.swift", action: "edit", count: 1),
            FileRow(path: "/tmp/a.swift", action: "read", count: 2),
            FileRow(path: "/tmp/b.swift", action: "write", count: 2),
            FileRow(path: "/tmp/c.swift", action: "edit", count: 1),
        ])
        let ordinary = try makeFixture(nativeID: "file-activity-default", sequence: 2)
        guard let empty = requireCommit(ordinary) else { return }
        XCTAssertEqual(try sessionFiles(empty.sessionID), [])
    }

    func testChangedGenerationReplacesStaleFileRows() throws {
        let first = try makeFixture(nativeID: "file-replace", sequence: 100,
                                    messages: fileActivityMessages(path: "/tmp/old.swift", tool: "Read"))
        guard let original = requireCommit(first) else { return }
        XCTAssertEqual(try sessionFiles(original.sessionID), [FileRow(path: "/tmp/old.swift", action: "read", count: 1)])
        let next = try makeFixture(nativeID: "file-replace", sequence: 101,
                                   messages: fileActivityMessages(path: "/tmp/new.swift", tool: "Write"))
        guard let replaced = requireCommit(next) else { return }
        XCTAssertEqual(replaced.sessionID, original.sessionID)
        XCTAssertEqual(replaced.syncVersion, 2)
        XCTAssertEqual(try sessionFiles(replaced.sessionID), [FileRow(path: "/tmp/new.swift", action: "write", count: 1)])
        let cleared = try makeFixture(nativeID: "file-replace", sequence: 102)
        guard let empty = requireCommit(cleared) else { return }
        XCTAssertEqual(empty.sessionID, original.sessionID)
        XCTAssertEqual(try sessionFiles(empty.sessionID), [])
    }

    func testFailedAndStaleCommitCannotLeavePartialFileRows() throws {
        let first = try makeFixture(nativeID: "file-rollback", sequence: 50,
                                    messages: fileActivityMessages(path: "/tmp/keep.swift", tool: "Read"))
        guard let receipt = requireCommit(first) else { return }
        XCTAssertEqual(try sessionFiles(receipt.sessionID), [FileRow(path: "/tmp/keep.swift", action: "read", count: 1)])

        let before = try state()
        assertLedgerError(.claimLost) { try self.commit(first) }
        XCTAssertEqual(try state(), before)
        XCTAssertEqual(try sessionFiles(receipt.sessionID), [FileRow(path: "/tmp/keep.swift", action: "read", count: 1)])

        let older = try makeFixture(nativeID: "file-rollback", sequence: 49,
                                    messages: fileActivityMessages(path: "/tmp/stale.swift", tool: "Write"))
        assertCommitError(.obsoleteGeneration) { try self.commit(older) }
        XCTAssertEqual(try sessionFiles(receipt.sessionID), [FileRow(path: "/tmp/keep.swift", action: "read", count: 1)])

        let replacement = try makeFixture(nativeID: "file-rollback", sequence: 51,
                                          messages: fileActivityMessages(path: "/tmp/partial.swift", tool: "Write"))
        try acceptRevision(replacement, parser: "failure-witness")
        try assertInjectedRollback(stage: ("files", "INSERT", "session_files"), fixture: replacement)
        XCTAssertEqual(try sessionFiles(receipt.sessionID), [FileRow(path: "/tmp/keep.swift", action: "read", count: 1)])
        XCTAssertEqual(try identity(first)["last_parsed_generation_id"] as String, receipt.generationID)
    }

    func testHistoricalFileActivityRepairRestoresCountsWithoutChangingVisibility() throws {
        let fixture = try makeFixture(nativeID: "file-repair-skip", sequence: 1,
                                      messages: fileActivityMessages(), agentRole: "dispatched")
        guard let receipt = requireCommit(fixture) else { return }
        try writer.write { db in
            try db.execute(sql: "UPDATE sessions SET hidden_at = ? WHERE id = ?",
                           arguments: [timestamp, receipt.sessionID])
        }
        XCTAssertEqual(try session(receipt.sessionID)["tier"] as String, "skip")
        try clearSessionFiles(receipt.sessionID)
        XCTAssertEqual(try sessionFiles(receipt.sessionID), [])
        let beforeSession = try session(receipt.sessionID)
        let first = try repairFileActivity()
        XCTAssertEqual(first.repaired, 1)
        XCTAssertTrue(try fileActivityRepaired(receipt.generationID))
        XCTAssertEqual(try sessionFiles(receipt.sessionID), [
            FileRow(path: "/tmp/a.swift", action: "edit", count: 1),
            FileRow(path: "/tmp/a.swift", action: "read", count: 2),
            FileRow(path: "/tmp/b.swift", action: "write", count: 2),
            FileRow(path: "/tmp/c.swift", action: "edit", count: 1),
        ])
        let afterSession = try session(receipt.sessionID)
        XCTAssertEqual(afterSession["tier"] as String, "skip")
        XCTAssertEqual(afterSession["hidden_at"] as String, timestamp)
        XCTAssertEqual(afterSession["agent_role"] as String, "dispatched")
        XCTAssertEqual(afterSession["sync_version"] as Int64, beforeSession["sync_version"] as Int64)
        XCTAssertEqual(afterSession["snapshot_hash"] as String, beforeSession["snapshot_hash"] as String)
        XCTAssertNil(receipt.requiredFTSJobID)
        XCTAssertEqual(try writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM session_index_jobs WHERE session_id = ?",
                                                        arguments: [receipt.sessionID]) }, 0)
        let second = try repairFileActivity()
        XCTAssertEqual(second.repaired, 0)
        XCTAssertEqual(try sessionFiles(receipt.sessionID), [
            FileRow(path: "/tmp/a.swift", action: "edit", count: 1),
            FileRow(path: "/tmp/a.swift", action: "read", count: 2),
            FileRow(path: "/tmp/b.swift", action: "write", count: 2),
            FileRow(path: "/tmp/c.swift", action: "edit", count: 1),
        ])
    }

    func testHistoricalFileActivityRepairResumesAcrossBoundedBatches() throws {
        let first = try makeFixture(nativeID: "file-repair-a", sequence: 1,
                                    messages: fileActivityMessages(path: "/tmp/one.swift", tool: "Read"))
        let second = try makeFixture(nativeID: "file-repair-b", sequence: 2,
                                     messages: fileActivityMessages(path: "/tmp/two.swift", tool: "Write"))
        guard let one = requireCommit(first), let two = requireCommit(second) else { return }
        try clearSessionFiles(one.sessionID)
        try clearSessionFiles(two.sessionID)
        let batch1 = try repairFileActivity(limit: 1)
        XCTAssertEqual(batch1.repaired, 1)
        let repairedOne = try fileActivityRepaired(one.generationID)
        let repairedTwo = try fileActivityRepaired(two.generationID)
        XCTAssertEqual([repairedOne, repairedTwo].filter(\.self).count, 1)
        XCTAssertEqual(try sessionFiles(one.sessionID).isEmpty, !repairedOne)
        XCTAssertEqual(try sessionFiles(two.sessionID).isEmpty, !repairedTwo)
        let batch2 = try repairFileActivity(limit: 1)
        XCTAssertEqual(batch2.repaired, 1)
        XCTAssertTrue(try fileActivityRepaired(one.generationID))
        XCTAssertTrue(try fileActivityRepaired(two.generationID))
        XCTAssertEqual(try sessionFiles(one.sessionID), [FileRow(path: "/tmp/one.swift", action: "read", count: 1)])
        XCTAssertEqual(try sessionFiles(two.sessionID), [FileRow(path: "/tmp/two.swift", action: "write", count: 1)])
        XCTAssertEqual(try repairFileActivity(limit: 1).repaired, 0)
    }

    func testHistoricalFileActivityRepairSkipsDisabledAndStaleHeadsAndMarksEmptyDerivation() throws {
        let empty = try makeFixture(nativeID: "file-repair-empty", sequence: 1)
        let stale = try makeFixture(nativeID: "file-repair-stale", sequence: 2,
                                    messages: fileActivityMessages(path: "/tmp/stale.swift", tool: "Read"))
        let current = try makeFixture(nativeID: "file-repair-disabled", sequence: 3,
                                      messages: fileActivityMessages(path: "/tmp/live.swift", tool: "Write"))
        guard let emptyReceipt = requireCommit(empty), let staleReceipt = requireCommit(stale),
              let currentReceipt = requireCommit(current) else { return }
        try clearSessionFiles(staleReceipt.sessionID)
        try clearSessionFiles(currentReceipt.sessionID)
        try writer.write { try $0.execute(sql: "UPDATE sessions SET sync_version = sync_version + 1 WHERE id = ?",
                                         arguments: [staleReceipt.sessionID]) }
        let disabled = try repairFileActivity(sources: [])
        XCTAssertEqual(disabled.repaired, 0)
        XCTAssertEqual(disabled.attempted, 0)
        XCTAssertTrue(disabled.exhausted)
        XCTAssertFalse(disabled.shouldContinueStartup)
        let otherSource = try repairFileActivity(sources: [.codex])
        XCTAssertEqual(otherSource.repaired, 0)
        XCTAssertEqual(otherSource.attempted, 0)
        XCTAssertTrue(otherSource.exhausted)
        XCTAssertFalse(otherSource.shouldContinueStartup)
        XCTAssertFalse(try fileActivityRepaired(emptyReceipt.generationID))
        XCTAssertFalse(try fileActivityRepaired(staleReceipt.generationID))
        XCTAssertFalse(try fileActivityRepaired(currentReceipt.generationID))
        XCTAssertEqual(try sessionFiles(staleReceipt.sessionID), [])
        XCTAssertEqual(try sessionFiles(currentReceipt.sessionID), [])
        let batch = try repairFileActivity()
        XCTAssertEqual(batch.repaired, 2)
        XCTAssertTrue(try fileActivityRepaired(emptyReceipt.generationID))
        XCTAssertTrue(try fileActivityRepaired(currentReceipt.generationID))
        XCTAssertFalse(try fileActivityRepaired(staleReceipt.generationID))
        XCTAssertEqual(try sessionFiles(emptyReceipt.sessionID), [])
        XCTAssertEqual(try sessionFiles(currentReceipt.sessionID), [FileRow(path: "/tmp/live.swift", action: "write", count: 1)])
        XCTAssertEqual(try sessionFiles(staleReceipt.sessionID), [])
        XCTAssertEqual(try session(staleReceipt.sessionID)["sync_version"] as Int64, Int64(staleReceipt.syncVersion + 1))
    }

    func testHistoricalFileActivityRepairRollbackLeavesNoPartialRowsOrMark() throws {
        let fixture = try makeFixture(nativeID: "file-repair-rollback", sequence: 1,
                                      messages: fileActivityMessages(path: "/tmp/keep.swift", tool: "Read"))
        guard let receipt = requireCommit(fixture) else { return }
        try clearSessionFiles(receipt.sessionID)
        try writer.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER fail_file_activity_repair AFTER INSERT ON session_files
                BEGIN
                    SELECT RAISE(FAIL, 'injected-file-repair');
                END
                """)
            let batch = try CaptureIngestFileActivity.repairCurrentGenerations(
                db, expectedParserRevision: revision, enabledSources: [.claudeCode], limit: 1)
            XCTAssertEqual(batch.repaired, 0)
            XCTAssertEqual(try Row.fetchAll(db, sql: "SELECT * FROM session_files WHERE session_id = ?",
                                            arguments: [receipt.sessionID]).count, 0)
            XCTAssertNil(try Row.fetchOne(db, sql: "SELECT 1 FROM metadata WHERE key = ?",
                                          arguments: [CaptureIngestFileActivity.repairedMetadataPrefix + receipt.generationID]))
            XCTAssertEqual(batch.attempted, 1)
            XCTAssertFalse(batch.exhausted)
            XCTAssertTrue(batch.shouldContinueStartup)
            try db.execute(sql: "DROP TRIGGER fail_file_activity_repair")
        }
        XCTAssertFalse(try fileActivityRepaired(receipt.generationID))
        XCTAssertEqual(try sessionFiles(receipt.sessionID), [])
        let wrapped = try repairFileActivity(limit: 1)
        XCTAssertEqual(wrapped.repaired, 0)
        XCTAssertEqual(wrapped.attempted, 0)
        XCTAssertTrue(wrapped.exhausted)
        XCTAssertFalse(wrapped.shouldContinueStartup)
        XCTAssertEqual(try repairFileActivity(limit: 1).repaired, 1)
        XCTAssertEqual(try sessionFiles(receipt.sessionID), [FileRow(path: "/tmp/keep.swift", action: "read", count: 1)])
        XCTAssertTrue(try fileActivityRepaired(receipt.generationID))
    }

    func testHistoricalFileActivityRepairAdvancesPastFailingEarliestHeadOnNextCall() throws {
        let first = try makeFixture(nativeID: "file-repair-corrupt", sequence: 1,
                                    messages: fileActivityMessages(path: "/tmp/early.swift", tool: "Read"))
        let second = try makeFixture(nativeID: "file-repair-later", sequence: 2,
                                     messages: fileActivityMessages(path: "/tmp/later.swift", tool: "Write"))
        guard let one = requireCommit(first), let two = requireCommit(second) else { return }
        let (early, late) = one.generationID < two.generationID ? (one, two) : (two, one)
        try writer.write { db in
            try db.execute(sql: "UPDATE capture_ingest_generations SET normalized_messages_json = ? WHERE generation_id = ?",
                           arguments: [Data("not-json".utf8), early.generationID])
        }
        try clearSessionFiles(early.sessionID)
        try clearSessionFiles(late.sessionID)
        let firstBatch = try repairFileActivity(limit: 1)
        XCTAssertEqual(firstBatch.repaired, 0)
        XCTAssertEqual(firstBatch.attempted, 1)
        XCTAssertFalse(firstBatch.exhausted)
        XCTAssertTrue(firstBatch.shouldContinueStartup)
        XCTAssertFalse(try fileActivityRepaired(early.generationID))
        XCTAssertFalse(try fileActivityRepaired(late.generationID))
        XCTAssertEqual(try sessionFiles(early.sessionID), [])
        XCTAssertEqual(try sessionFiles(late.sessionID), [])
        XCTAssertEqual(try fileActivityResume(), early.generationID)
        let secondBatch = try repairFileActivity(limit: 1)
        XCTAssertEqual(secondBatch.repaired, 1)
        XCTAssertEqual(secondBatch.attempted, 1)
        XCTAssertFalse(secondBatch.exhausted)
        XCTAssertTrue(secondBatch.shouldContinueStartup)
        XCTAssertFalse(try fileActivityRepaired(early.generationID))
        XCTAssertTrue(try fileActivityRepaired(late.generationID))
        XCTAssertEqual(try sessionFiles(early.sessionID), [])
        XCTAssertEqual(try sessionFiles(late.sessionID), late.sessionID == two.sessionID
                       ? [FileRow(path: "/tmp/later.swift", action: "write", count: 1)]
                       : [FileRow(path: "/tmp/early.swift", action: "read", count: 1)])
        XCTAssertEqual(try fileActivityResume(), late.generationID)
    }

    func testHistoricalFileActivityRepairStartupLoopReachesLaterHeadThenStops() throws {
        let first = try makeFixture(nativeID: "file-repair-loop-a", sequence: 1,
                                    messages: fileActivityMessages(path: "/tmp/loop-early.swift", tool: "Read"))
        let second = try makeFixture(nativeID: "file-repair-loop-b", sequence: 2,
                                     messages: fileActivityMessages(path: "/tmp/loop-later.swift", tool: "Write"))
        guard let one = requireCommit(first), let two = requireCommit(second) else { return }
        let (early, late) = one.generationID < two.generationID ? (one, two) : (two, one)
        try writer.write { db in
            try db.execute(sql: "UPDATE capture_ingest_generations SET normalized_messages_json = ? WHERE generation_id = ?",
                           arguments: [Data("not-json".utf8), early.generationID])
        }
        try clearSessionFiles(early.sessionID)
        try clearSessionFiles(late.sessionID)
        var ticks = 0
        var last = CaptureIngestFileActivityRepairBatch(repaired: 0, attempted: 0, exhausted: false)
        repeat {
            last = try repairFileActivity(limit: 1)
            ticks += 1
            XCTAssertLessThanOrEqual(ticks, 3, "one corrupt head plus one valid head must finish in a finite traversal")
        } while last.shouldContinueStartup
        XCTAssertEqual(ticks, 3)
        XCTAssertTrue(last.exhausted)
        XCTAssertFalse(last.shouldContinueStartup)
        XCTAssertEqual(last.repaired, 0)
        XCTAssertEqual(last.attempted, 0)
        XCTAssertFalse(try fileActivityRepaired(early.generationID))
        XCTAssertTrue(try fileActivityRepaired(late.generationID))
        XCTAssertEqual(try sessionFiles(early.sessionID), [])
        XCTAssertEqual(try sessionFiles(late.sessionID), late.sessionID == two.sessionID
                       ? [FileRow(path: "/tmp/loop-later.swift", action: "write", count: 1)]
                       : [FileRow(path: "/tmp/loop-early.swift", action: "read", count: 1)])
    }

    /// HQ regression (session_files stayed at 0 rows for 38,780 current heads):
    /// the candidate SELECT started from the ledger status index, joined every
    /// current head and sorted the lot in a temp B-tree before `LIMIT 4`, about
    /// 15s on HQ, so the 2s startup budget threw before the first head. The plan
    /// must walk `capture_ingest_generations` in `generation_id` order and probe
    /// the other tables per row, with no sort step.
    func testHistoricalFileActivityRepairCandidateQueryWalksGenerationsInOrder_repro() throws {
        let fixture = try makeFixture(nativeID: "file-repair-plan", sequence: 1,
                                      messages: fileActivityMessages(path: "/tmp/plan.swift", tool: "Read"))
        guard let receipt = requireCommit(fixture) else { return }
        try clearSessionFiles(receipt.sessionID)
        let traced = TracedRepairStatements()
        var plan: [String] = []
        try writer.write { db in
            db.trace(options: .statement) { event in
                if case .statement(let statement) = event { traced.record(statement.sql) }
            }
            defer { db.trace(options: .statement, nil) }
            let batch = try CaptureIngestFileActivity.repairCurrentGenerations(
                db, expectedParserRevision: revision, enabledSources: [.claudeCode], limit: 4)
            XCTAssertEqual(batch.repaired, 1)
            let candidateSQL = try XCTUnwrap(traced.values.first {
                $0.contains("capture_ingest_identity_bindings") && $0.contains("ORDER BY g.generation_id")
            }, "candidate statement was not traced")
            let placeholders = candidateSQL.filter { $0 == "?" }.count
            plan = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + candidateSQL,
                                    arguments: StatementArguments(Array(repeating: "x", count: placeholders)))
                .map { $0["detail"] as String }
        }
        let joined = plan.joined(separator: "\n")
        XCTAssertFalse(joined.contains("TEMP B-TREE"), joined)
        XCTAssertTrue(try XCTUnwrap(plan.first).hasPrefix("SCAN g"), joined)
        XCTAssertFalse(joined.contains("SCAN b"), joined)
        XCTAssertFalse(joined.contains("SCAN s"), joined)
        XCTAssertFalse(joined.contains("SCAN l"), joined)
    }

    /// HQ regression: a deadline hit on a later head rolled back the whole
    /// batch (including heads already repaired and the cursor) and ended the
    /// startup task, so the batch containing one slow head never progressed
    /// across restarts. Completed heads must stay committed and the slow head
    /// must be first in the next batch.
    func testHistoricalFileActivityRepairDeadlineMidBatchKeepsCompletedHeads_repro() throws {
        let first = try makeFixture(nativeID: "file-repair-deadline-a", sequence: 1,
                                    messages: fileActivityMessages(path: "/tmp/deadline-early.swift", tool: "Read"))
        let second = try makeFixture(nativeID: "file-repair-deadline-b", sequence: 2,
                                     messages: fileActivityMessages(path: "/tmp/deadline-later.swift", tool: "Write"))
        guard let one = requireCommit(first), let two = requireCommit(second) else { return }
        let (early, late) = one.generationID < two.generationID ? (one, two) : (two, one)
        try clearSessionFiles(early.sessionID)
        try clearSessionFiles(late.sessionID)
        let batch = try repairFileActivity(limit: 4, deadline: .milliseconds(400),
                                           stallingLoadOf: late.generationID, by: 1.0)
        XCTAssertEqual(batch.repaired, 1)
        XCTAssertGreaterThanOrEqual(batch.attempted, 1)
        XCTAssertFalse(batch.exhausted)
        XCTAssertTrue(batch.shouldContinueStartup)
        XCTAssertTrue(try fileActivityRepaired(early.generationID))
        XCTAssertFalse(try fileActivityRepaired(late.generationID))
        XCTAssertEqual(try sessionFiles(early.sessionID).count, 1)
        XCTAssertEqual(try sessionFiles(late.sessionID), [])
        XCTAssertEqual(try fileActivityResume(), early.generationID)
        let retry = try repairFileActivity(limit: 1)
        XCTAssertEqual(retry.repaired, 1)
        XCTAssertEqual(retry.attempted, 1)
        XCTAssertFalse(retry.exhausted)
        XCTAssertTrue(try fileActivityRepaired(late.generationID))
        XCTAssertEqual(try sessionFiles(late.sessionID).count, 1)
        XCTAssertEqual(try fileActivityResume(), late.generationID)
    }

    /// HQ regression: a head whose own load exhausts the batch budget must be
    /// skipped for this process start (cursor advanced, nothing marked) instead
    /// of ending the startup task, so one oversized generation cannot starve
    /// every later head. It is retried after the finite traversal wraps.
    func testHistoricalFileActivityRepairSkipsHeadThatAloneExceedsDeadline_repro() throws {
        let first = try makeFixture(nativeID: "file-repair-slow-a", sequence: 1,
                                    messages: fileActivityMessages(path: "/tmp/slow-early.swift", tool: "Read"))
        let second = try makeFixture(nativeID: "file-repair-slow-b", sequence: 2,
                                     messages: fileActivityMessages(path: "/tmp/slow-later.swift", tool: "Write"))
        guard let one = requireCommit(first), let two = requireCommit(second) else { return }
        let (early, late) = one.generationID < two.generationID ? (one, two) : (two, one)
        try clearSessionFiles(early.sessionID)
        try clearSessionFiles(late.sessionID)
        let batch = try repairFileActivity(limit: 4, deadline: .milliseconds(400),
                                           stallingLoadOf: early.generationID, by: 1.0)
        XCTAssertEqual(batch.repaired, 0)
        XCTAssertEqual(batch.attempted, 1)
        XCTAssertFalse(batch.exhausted)
        XCTAssertTrue(batch.shouldContinueStartup)
        XCTAssertFalse(try fileActivityRepaired(early.generationID))
        XCTAssertFalse(try fileActivityRepaired(late.generationID))
        XCTAssertEqual(try sessionFiles(early.sessionID), [])
        XCTAssertEqual(try sessionFiles(late.sessionID), [])
        XCTAssertEqual(try fileActivityResume(), early.generationID)
        let next = try repairFileActivity(limit: 1)
        XCTAssertEqual(next.repaired, 1)
        XCTAssertFalse(next.exhausted)
        XCTAssertTrue(try fileActivityRepaired(late.generationID))
        XCTAssertFalse(try fileActivityRepaired(early.generationID))
        XCTAssertEqual(try sessionFiles(late.sessionID).count, 1)
        XCTAssertEqual(try fileActivityResume(), late.generationID)
        let wrap = try repairFileActivity(limit: 1)
        XCTAssertEqual(wrap.attempted, 0)
        XCTAssertTrue(wrap.exhausted)
        XCTAssertNil(try fileActivityResume())
        let retried = try repairFileActivity(limit: 1)
        XCTAssertEqual(retried.repaired, 1)
        XCTAssertTrue(try fileActivityRepaired(early.generationID))
        XCTAssertEqual(try sessionFiles(early.sessionID).count, 1)
    }

    func testEnsureHelperRejectsNoncurrentOwnerVersionHashAndAbsentSessionWithoutWrites() throws {
        let fixture = try makeFixture()
        guard let receipt = requireCommit(fixture) else { return }
        let before = try state()
        let variants = [
            ("missing-session", fixture.replay.nativeIdentity.peer, receipt.syncVersion, receipt.snapshotHash),
            (receipt.sessionID, "wrong-owner", receipt.syncVersion, receipt.snapshotHash),
            (receipt.sessionID, fixture.replay.nativeIdentity.peer, receipt.syncVersion + 1, receipt.snapshotHash),
            (receipt.sessionID, fixture.replay.nativeIdentity.peer, receipt.syncVersion, String(repeating: "0", count: 64)),
        ]
        for (sessionID, owner, version, hash) in variants {
            assertCommitError(.currentSnapshotMismatch) {
                try self.writer.write { try SessionSnapshotWriter(db: $0).ensureCurrentCaptureFTSJob(
                    sessionID: sessionID, authoritativeNode: owner, syncVersion: version, snapshotHash: hash) }
            }
            XCTAssertEqual(try state(), before)
        }
    }

    func testEnsureHelperNeverResetsExactExistingJobStatusRetryOrDebounce() throws {
        let fixture = try makeFixture()
        guard let receipt = requireCommit(fixture), let jobID = receipt.requiredFTSJobID else { return }
        for status in ["pending", "processing", "failed_retryable", "failed_permanent", "completed", "not_applicable"] {
            try writer.write { try $0.execute(sql: """
                UPDATE session_index_jobs SET status = ?, retry_count = 9, last_error = 'keep-symbolic-code',
                    created_at = '2001-01-01', updated_at = '2002-02-02', not_before = '2003-03-03' WHERE id = ?
                """, arguments: [status, jobID]) }
            let before = try state()
            let ensured = try writer.write { try SessionSnapshotWriter(db: $0).ensureCurrentCaptureFTSJob(
                sessionID: receipt.sessionID, authoritativeNode: fixture.replay.nativeIdentity.peer,
                syncVersion: receipt.syncVersion, snapshotHash: receipt.snapshotHash) }
            XCTAssertEqual(ensured, jobID)
            XCTAssertEqual(try state(), before, status)
        }
    }

    func testInitialCommitFailureAtEveryWriteStageRollsBackWhenOuterTransactionContinues() throws {
        guard try requireSchema() else { return }
        let stages: [(String, String, String)] = [
            ("identity_insert", "INSERT", "capture_ingest_identity_bindings"),
            ("snapshot", "INSERT", "sessions"), ("costs", "INSERT", "session_costs"),
            ("tools", "INSERT", "session_tools"), ("beats", "INSERT", "session_work_beats"),
            ("job", "INSERT", "session_index_jobs"), ("generation", "INSERT", "capture_ingest_generations"),
            ("head", "UPDATE", "capture_ingest_identity_bindings"), ("ledger", "UPDATE", "capture_ingest_ledger"),
        ]
        for (index, stage) in stages.enumerated() {
            let fixture = try makeFixture(nativeID: "initial-failure-\(index)", sequence: Int64(index + 1))
            try acceptRevision(fixture, parser: "failure-witness")
            try assertInjectedRollback(stage: stage, fixture: fixture)
        }
    }

    func testReplacementFailureAtEveryWriteStageKeepsLastGoodAndReadyGeneration() throws {
        let first = try makeFixture(sequence: 1)
        guard let receipt = requireCommit(first) else { return }
        try markReadyForFixture(first, receipt: receipt)
        let stages: [(String, String, String)] = [
            ("snapshot", "UPDATE", "sessions"), ("costs", "UPDATE", "session_costs"),
            ("tools", "INSERT", "session_tools"), ("beats", "INSERT", "session_work_beats"),
            ("job", "INSERT", "session_index_jobs"), ("generation", "INSERT", "capture_ingest_generations"),
            ("head", "UPDATE", "capture_ingest_identity_bindings"), ("ledger", "UPDATE", "capture_ingest_ledger"),
        ]
        for (index, stage) in stages.enumerated() {
            let fixture = try makeFixture(sequence: Int64(index + 2), messages: defaultMessages(suffix: " replacement-\(index)"))
            try acceptRevision(fixture, parser: "failure-witness")
            try assertInjectedRollback(stage: stage, fixture: fixture)
            XCTAssertEqual(try identity(first)["last_parsed_generation_id"] as String, receipt.generationID)
            XCTAssertEqual(try identity(first)["last_ready_generation_id"] as String, receipt.generationID)
        }
    }

    func testOuterRollbackAfterSuccessfulCommitRevertsReceiptArtifactsAndLedgerTogether() throws {
        let fixture = try makeFixture()
        let before = try state()
        XCTAssertThrowsError(try writer.write { db in
            _ = try CaptureIngestCommitter.commitParsed(db, claim: fixture.claim, replay: fixture.replay,
                expectedParserRevision: revision, now: 101, indexedAt: timestamp)
            throw InjectedFailure.outerRollback
        }) { XCTAssertEqual($0 as? InjectedFailure, .outerRollback) }
        XCTAssertEqual(try state(), before)
    }

    private var databasePath: String { directory.appendingPathComponent("index.sqlite").path }

    private struct Fixture: Sendable {
        let claim: CaptureIngestClaim
        let replay: CaptureIngestReplayResult
        let page: CollectorPublicationPage
        let requestedCursor: String?

        func withClaim(_ value: CaptureIngestClaim) -> Self {
            Self(claim: value, replay: replay, page: page, requestedCursor: requestedCursor)
        }
    }

    private enum InjectedFailure: Error, Equatable { case outerRollback }

    private enum CommitAttempt: Sendable {
        case committed(CaptureIngestCommittedGeneration)
        case claimLost
        case unexpected(String)
    }

    private var productTables: [String] {
        ["sessions", "session_local_state", "session_relations", "session_costs", "session_tools",
         "session_files", "session_work_beats", "session_index_jobs", "sessions_fts", "fts_map", "insights",
         "sync_ledger", "capture_ingest_identity_bindings", "capture_ingest_generations"]
    }

    private var intakeTables: [String] {
        ["capture_ingest_publications", "capture_ingest_arrivals", "capture_ingest_checkpoints",
         "capture_ingest_source_registry", "capture_ingest_epoch_history"]
    }

    private func makeFixture(
        nativeID: String = "native-session", sequence: Int64? = nil, source: SourceName = .claudeCode,
        machineID: String? = nil, instanceID: String? = nil, root: String? = nil,
        publicationEpoch: String? = nil, messages: [NormalizedMessage]? = nil,
        parentNativeID: String? = nil, suggestedNativeID: String? = nil,
        agentRole: String? = nil, captureSalt: String = ""
    ) throws -> Fixture {
        let machineID = machineID ?? machine
        let instanceID = instanceID ?? instance
        let root = root ?? logicalRoot
        let current = try writer.write { db in
            if let existing = try CaptureIngestSourceRegistry.binding(db, machineID: machineID, sourceInstanceID: instanceID) {
                return existing
            }
            return try CaptureIngestSourceRegistry.provision(db, machineID: machineID, sourceInstanceID: instanceID,
                source: source, parseFormat: source == .codex ? .codex : .claudeDefault,
                configuredRoot: root, initialEpoch: epoch)
        }
        let sequence = sequence ?? nextOrdinal
        let messages = messages ?? defaultMessages()
        let manifest = try manifest(binding: current, nativeID: nativeID, sequence: sequence,
                                    messages: messages, captureSalt: captureSalt)
        let publication = try CollectorPublicationEnvelope(machineID: machineID, sourceInstanceID: instanceID,
            collectorEpoch: publicationEpoch ?? current.approvedEpoch, sequence: sequence,
            manifestSHA256: ArchiveV2Hash.sha256(ArchiveCanonicalJSON.encode(manifest)))
        let accepted = try accept(publication, parser: revision)
        let claim = try writer.write { db in
            try XCTUnwrap(CaptureIngestLedger.claim(db, publicationSHA256: publication.sha256(),
                parserRevision: revision, now: 100, leaseDuration: 10))
        }
        let identity = try CaptureIngestIdentity(machineID: machineID, sourceInstanceID: instanceID, source: source, nativeID: nativeID)
        let info = NormalizedSessionInfo(
            id: nativeID, source: source, startTime: "2026-09-06T01:00:00Z", endTime: "2026-09-06T01:02:00Z",
            cwd: "/offline-client/project", project: "project", model: "claude-sonnet-4-20250514",
            messageCount: messages.count,
            userMessageCount: messages.filter { $0.role == .user }.count,
            assistantMessageCount: messages.filter { $0.role == .assistant }.count,
            toolMessageCount: messages.filter { $0.role == .tool }.count,
            systemMessageCount: messages.filter { $0.role == .system }.count,
            summary: "Complete captured session", displayTitle: "Captured fixture",
            filePath: manifest.locator, sizeBytes: manifest.rawByteCount,
            agentRole: agentRole, originator: source == .codex ? "codex" : "claude-code",
            parentSessionId: parentNativeID, suggestedParentId: suggestedNativeID
        )
        let replay = CaptureIngestReplayResult(
            publicationSHA256: claim.publicationSHA256, verifiedManifest: manifest, bindingSnapshot: current,
            scan: IndexingScan(info: info, messages: messages), rawSourceSessionID: nativeID,
            nativeIdentity: identity,
            parentIdentity: try parentNativeID.map { try identity.mapping(nativeID: $0) },
            suggestedParentIdentity: try suggestedNativeID.map { try identity.mapping(nativeID: $0) }
        )
        return Fixture(claim: claim, replay: replay, page: accepted.page, requestedCursor: accepted.requestedCursor)
    }

    private func manifest(
        binding: CaptureIngestSourceBinding, nativeID: String, sequence: Int64,
        messages: [NormalizedMessage], captureSalt: String
    ) throws -> ArchiveSourceManifest {
        // T2 starts after replay: synthetic parse artifacts avoid any source or
        // CAS I/O while retaining a valid canonical manifest/envelope binding.
        let raw = try ArchiveCanonicalJSON.encode(messages)
        let hash = ArchiveV2Hash.sha256(raw)
        let relative = "project/\(ArchiveV2Hash.sha256(Data(nativeID.utf8))).jsonl"
        return try ArchiveSourceManifest(
            captureID: ArchiveV2Hash.sha256(Data("\(binding.sourceInstanceID):\(binding.approvedEpoch):\(sequence):\(nativeID):\(captureSalt)".utf8)),
            machineID: binding.machineID, source: binding.source.rawValue,
            locator: binding.configuredRoot + "/" + relative, sessionID: nil, capturedAt: timestamp,
            generation: ArchiveSourceGeneration(device: 1, inode: 2, size: Int64(raw.count), mtimeNs: 3, ctimeNs: 4, mode: 0o100600),
            wholeSourceSHA256: hash, rawByteCount: Int64(raw.count),
            chunks: [try ArchiveChunkReference(ordinal: 0, rawSHA256: hash, rawByteCount: Int64(raw.count))],
            replayLayout: ArchiveReplayLayout(strategy: .singleFile, relativePaths: [relative])
        )
    }

    private func fileActivityMessages() -> [NormalizedMessage] {
        [
            .init(role: .user, content: "Read and edit fixture files."),
            .init(role: .assistant, content: "Applied file tools.",
                  toolCalls: [
                    .init(name: "Read", input: #"{"file_path":"/tmp/a.swift"}"#),
                    .init(name: "read_file", input: #"{"file_path":"/tmp/a.swift","extra":1}"#),
                    .init(name: "Edit", input: #"{"file_path":"/tmp/a.swift"}"#),
                    .init(name: "Write", input: #"{"file_path":"/tmp/b.swift"}"#),
                    .init(name: "write_file", input: #"{"file_path":"/tmp/b.swift"}"#),
                    .init(name: "edit_file", input: #"{"file_path":"/tmp/c.swift"}"#),
                    .init(name: "Bash", input: #"{"file_path":"/tmp/skip.swift"}"#),
                    .init(name: "Read", input: "not-json"),
                    .init(name: "Read", input: #"{"file_path":"relative.swift"}"#),
                    .init(name: "Read", input: #"{"file_path":"/tmp/nul\u0000.swift"}"#),
                    .init(name: "Read", input: #"{"file_path":123}"#),
                    .init(name: "Read"),
                    .init(name: "edit_file", input: "fixture"),
                  ]),
        ]
    }

    private func fileActivityMessages(path: String, tool: String) -> [NormalizedMessage] {
        [
            .init(role: .user, content: "Touch \(path)."),
            .init(role: .assistant, content: "Touched.",
                  toolCalls: [.init(name: tool, input: #"{"file_path":"\#(path)"}"#)]),
        ]
    }

    private struct FileRow: Equatable {
        let path: String
        let action: String
        let count: Int
    }

    private func clearSessionFiles(_ sessionID: String) throws {
        try writer.write { try $0.execute(sql: "DELETE FROM session_files WHERE session_id = ?", arguments: [sessionID]) }
    }

    private func fileActivityResume() throws -> String? {
        try writer.read {
            try String.fetchOne($0, sql: "SELECT value FROM metadata WHERE key = ?",
                                arguments: [CaptureIngestFileActivity.resumeMetadataKey])
        }
    }

    private func fileActivityRepaired(_ generationID: String) throws -> Bool {
        try writer.read {
            try Row.fetchOne($0, sql: "SELECT 1 FROM metadata WHERE key = ?",
                             arguments: [CaptureIngestFileActivity.repairedMetadataPrefix + generationID]) != nil
        }
    }

    private func repairFileActivity(limit: Int = 4, sources: Set<SourceName> = [.claudeCode]) throws
        -> CaptureIngestFileActivityRepairBatch {
        try writer.write {
            try CaptureIngestFileActivity.repairCurrentGenerations($0, expectedParserRevision: revision,
                                                                  enabledSources: sources, limit: limit)
        }
    }

    /// Runs one repair batch under `deadline` while the normalized-store
    /// metadata read for `generationID` is stalled by `stall`, so that head's
    /// own load checkpoint observes an expired deadline deterministically.
    private func repairFileActivity(limit: Int, deadline: Duration, stallingLoadOf generationID: String,
                                    by stall: TimeInterval) throws -> CaptureIngestFileActivityRepairBatch {
        try writer.write { db in
            let stalled = TracedRepairStatements()
            db.trace(options: .statement) { event in
                guard case .statement(let statement) = event,
                      statement.sql.contains("FROM capture_ingest_generations WHERE generation_id = ?"),
                      statement.expandedSQL.contains(generationID),
                      stalled.values.isEmpty else { return }
                stalled.record(generationID)
                Thread.sleep(forTimeInterval: stall)
            }
            defer { db.trace(options: .statement, nil) }
            return try CaptureIngestFileActivity.repairCurrentGenerations(
                db, expectedParserRevision: revision, enabledSources: [.claudeCode],
                deadline: ContinuousClock.now.advanced(by: deadline), limit: limit)
        }
    }

    private final class TracedRepairStatements: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        var values: [String] { lock.withLock { storage } }
        func record(_ sql: String) { lock.withLock { storage.append(sql) } }
    }

    private func sessionFiles(_ sessionID: String) throws -> [FileRow] {
        try writer.read {
            try Row.fetchAll($0, sql: """
                SELECT file_path, action, count FROM session_files
                WHERE session_id = ? ORDER BY file_path, action
                """, arguments: [sessionID]).map {
                FileRow(path: $0["file_path"], action: $0["action"], count: $0["count"])
            }
        }
    }

    private func defaultMessages(suffix: String = "") -> [NormalizedMessage] {
        [
            .init(role: .user, content: "Implement the requested complete transcript reader." + suffix,
                  timestamp: "2026-09-06T01:00:00Z"),
            .init(role: .assistant, content: "Result\nImplemented the complete transcript reader.\n\nValidation\nchecks run: targeted tests" + suffix,
                  timestamp: "2026-09-06T01:02:00Z", toolCalls: [.init(name: "edit_file", input: "fixture", output: "complete")],
                  usage: .init(inputTokens: 100, outputTokens: 50, cacheReadTokens: 3, cacheCreationTokens: 4)),
        ]
    }

    private func accept(_ publication: CollectorPublicationEnvelope, parser: String) throws
        -> (page: CollectorPublicationPage, requestedCursor: String?) {
        let ack = try CollectorPublicationACK(serverID: "hq", journalID: journal, arrivalOrdinal: nextOrdinal,
            publicationSHA256: publication.sha256(), manifestSHA256: publication.manifestSHA256, storedAt: timestamp)
        nextOrdinal += 1
        let record = try CollectorPublicationAcceptanceRecord(publication: publication, ack: ack)
        let page = try CollectorPublicationPage(items: [record], afterCursor: CollectorPublicationCursor(
            journalID: journal, afterArrivalOrdinal: ack.arrivalOrdinal).encoded(), hasMore: false)
        let requested = try writer.write { db in
            let cursor = try CaptureIngestLedger.checkpoint(db, serverID: "hq")
            try CaptureIngestLedger.accept(db, page: page, requestedCursor: cursor, serverID: "hq", parserRevision: parser)
            return cursor
        }
        return (page, requested)
    }

    private func acceptRevision(_ fixture: Fixture, parser: String) throws {
        try writer.write { try CaptureIngestLedger.accept($0, page: fixture.page,
            requestedCursor: fixture.requestedCursor, serverID: "hq", parserRevision: parser) }
    }

    private func withRevision(_ fixture: Fixture, parser: String) throws -> Fixture {
        try acceptRevision(fixture, parser: parser)
        let revised = try XCTUnwrap(writer.write { try CaptureIngestLedger.claim($0,
            publicationSHA256: fixture.claim.publicationSHA256, parserRevision: parser, now: 100, leaseDuration: 10) })
        return fixture.withClaim(revised)
    }

    private func claim(_ fixture: Fixture, now: Int64 = 101) throws -> CaptureIngestClaim? {
        try writer.write { try CaptureIngestLedger.claim($0, publicationSHA256: fixture.claim.publicationSHA256,
            parserRevision: fixture.claim.parserRevision, now: now, leaseDuration: 10) }
    }

    private func approveNextEpoch() throws -> CaptureIngestSourceBinding {
        try writer.write { db in
            let current = try XCTUnwrap(CaptureIngestSourceRegistry.binding(db, machineID: machine, sourceInstanceID: instance))
            return try CaptureIngestSourceRegistry.approveEpoch(db, machineID: machine, sourceInstanceID: instance,
                candidateEpoch: nextEpoch, expectedEpoch: current.approvedEpoch, expectedAuthorityGeneration: current.authorityGeneration)
        }
    }

    private func mutateRegistryField(_ column: String, value: DatabaseValue) throws {
        try writer.write { db in
            if column == "machine_id" || column == "source_instance_id" {
                // Preserve the existing history FK while changing one binding
                // field. The replay/publication still carry the old identity.
                try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
                try db.execute(sql: "UPDATE capture_ingest_epoch_history SET \(column) = ?", arguments: [value])
            }
            try db.execute(sql: "UPDATE capture_ingest_source_registry SET \(column) = ?", arguments: [value])
        }
    }

    @discardableResult
    private func commit(_ fixture: Fixture, replay: CaptureIngestReplayResult? = nil,
                        expectedRevision: String? = nil, now: Int64 = 101) throws -> CaptureIngestCommittedGeneration {
        try writer.write { try CaptureIngestCommitter.commitParsed($0, claim: fixture.claim, replay: replay ?? fixture.replay,
            expectedParserRevision: expectedRevision ?? revision, now: now, indexedAt: timestamp) }
    }

    private func requireCommit(_ fixture: Fixture, expectedRevision: String? = nil, now: Int64 = 101,
                               file: StaticString = #filePath, line: UInt = #line) -> CaptureIngestCommittedGeneration? {
        do { return try commit(fixture, expectedRevision: expectedRevision, now: now) }
        catch {
            XCTFail("eligible complete generation must commit: \(type(of: error))", file: file, line: line)
            return nil
        }
    }

    private func loadSnapshot(_ receipt: CaptureIngestCommittedGeneration,
                              sources: Set<SourceName> = [.claudeCode],
                              deadline: ContinuousClock.Instant? = nil,
                              messageRange: Range<Int>? = nil) throws -> CaptureIngestNormalizedSnapshot {
        try writer.read {
            try CaptureIngestNormalizedStore.load($0, sessionID: receipt.sessionID, generationID: receipt.generationID,
                expectedParserRevision: revision, enabledSources: sources, deadline: deadline, messageRange: messageRange)
        }
    }

    private func loadPage(_ receipt: CaptureIngestCommittedGeneration,
                          fromOrdinal: Int, maximumMessages: Int, roles: Set<NormalizedMessageRole>,
                          sources: Set<SourceName> = [.claudeCode],
                          deadline: ContinuousClock.Instant? = nil,
                          maximumPayloadBytes: Int = 1024 * 1024) throws -> (snapshot: CaptureIngestNormalizedSnapshot, ordinals: [Int], hasMore: Bool) {
        try writer.read {
            try CaptureIngestNormalizedStore.loadPage($0, sessionID: receipt.sessionID, generationID: receipt.generationID,
                expectedParserRevision: revision, enabledSources: sources, fromOrdinal: fromOrdinal,
                maximumMessages: maximumMessages, roles: roles, deadline: deadline,
                maximumPayloadBytes: maximumPayloadBytes)
        }
    }

    private func perMessageRowCount(_ generationID: String, file: StaticString = #filePath, line: UInt = #line) throws -> Int {
        try writer.read { db in
            XCTAssertTrue(try db.tableExists("capture_ingest_generation_messages"),
                          "v2 histories persist one row per normalized message", file: file, line: line)
            return try XCTUnwrap(Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM capture_ingest_generation_messages WHERE generation_id = ?
                """, arguments: [generationID]), file: file, line: line)
        }
    }

    private func foreignKeys(_ table: String) throws -> [Row] {
        try writer.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_list(\(table))") }
    }

    private func generationColumnNames() throws -> Set<String> {
        try writer.read {
            Set(try Row.fetchAll($0, sql: "PRAGMA table_info(capture_ingest_generations)").map { $0["name"] as String })
        }
    }

    private func generationTableSQL() throws -> String {
        try writer.read {
            try XCTUnwrap(String.fetchOne($0, sql: """
                SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'capture_ingest_generations'
                """))
        }
    }

    private func assertLegacyGenerationChecks(file: StaticString = #filePath, line: UInt = #line) throws {
        let sql = try generationTableSQL()
        XCTAssertTrue(sql.contains("normalized_schema_version = \(CaptureIngestCommitter.normalizedSchemaVersion)"),
                      "fresh and upgraded schema must keep the envelope schema CHECK: \(sql)", file: file, line: line)
        XCTAssertTrue(sql.contains("length(normalized_messages_json) <= \(CaptureIngestCommitter.maximumNormalizedPayloadBytes)"),
                      "fresh and upgraded schema must keep the legacy payload CHECK: \(sql)", file: file, line: line)
        XCTAssertTrue(sql.contains("normalized_message_count BETWEEN 0 AND \(CaptureIngestCommitter.maximumNormalizedMessages)"),
                      "fresh and upgraded schema must keep the legacy count CHECK: \(sql)", file: file, line: line)
    }

    private func assertAdditiveNormalizedStoragePresent(file: StaticString = #filePath, line: UInt = #line) throws {
        let columns = try generationColumnNames()
        XCTAssertTrue(columns.contains("normalized_storage_version"), "missing normalized_storage_version", file: file, line: line)
        XCTAssertTrue(columns.contains("normalized_total_message_count"), "missing normalized_total_message_count", file: file, line: line)
        XCTAssertTrue(try writer.read { try $0.tableExists("capture_ingest_generation_messages") },
                      "additive per-message table must exist", file: file, line: line)
    }

    private func assertAdditiveNormalizedStorageAbsent(file: StaticString = #filePath, line: UInt = #line) throws {
        let columns = try generationColumnNames()
        XCTAssertFalse(columns.contains("normalized_storage_version"), file: file, line: line)
        XCTAssertFalse(columns.contains("normalized_total_message_count"), file: file, line: line)
        XCTAssertFalse(try writer.read { try $0.tableExists("capture_ingest_generation_messages") },
                       "legacy fixture must not retain the additive per-message table", file: file, line: line)
    }

    private func stripAdditiveNormalizedStorageIfPresent(file: StaticString = #filePath, line: UInt = #line) throws {
        try writer.write { db in
            if try db.tableExists("capture_ingest_generation_messages") {
                let leftover = try XCTUnwrap(Int.fetchOne(db, sql: "SELECT COUNT(*) FROM capture_ingest_generation_messages"),
                                             file: file, line: line)
                XCTAssertEqual(leftover, 0, "legacy fixture drops only an empty additive child table", file: file, line: line)
                try db.execute(sql: "DROP TABLE capture_ingest_generation_messages")
            }
            let columns = Set(try Row.fetchAll(db, sql: "PRAGMA table_info(capture_ingest_generations)").map { $0["name"] as String })
            for column in ["normalized_storage_version", "normalized_total_message_count"] where columns.contains(column) {
                try db.execute(sql: "ALTER TABLE capture_ingest_generations DROP COLUMN \(column)")
            }
        }
    }

    private func assertV2StorageSentinel(_ receipt: CaptureIngestCommittedGeneration, expectedTotal: Int,
                                         file: StaticString = #filePath, line: UInt = #line) throws {
        let row = try generation(receipt)
        XCTAssertEqual(row["normalized_schema_version"] as Int, 1, file: file, line: line)
        XCTAssertEqual(row["normalized_storage_version"] as Int?, 2, file: file, line: line)
        XCTAssertEqual(row["normalized_message_count"] as Int, 0,
                       "v2 writes sentinel 0 on the legacy count column; never clamp", file: file, line: line)
        XCTAssertNotEqual(row["normalized_message_count"] as Int, expectedTotal, file: file, line: line)
        XCTAssertEqual(row["normalized_total_message_count"] as Int?, expectedTotal, file: file, line: line)
    }

    private func replacing(
        _ replay: CaptureIngestReplayResult, digest: String? = nil, manifest: ArchiveSourceManifest? = nil,
        binding: CaptureIngestSourceBinding? = nil, scan: IndexingScan? = nil, rawNativeID: String? = nil,
        identity: CaptureIngestIdentity? = nil, parent: CaptureIngestIdentity? = nil, suggested: CaptureIngestIdentity? = nil
    ) -> CaptureIngestReplayResult {
        CaptureIngestReplayResult(publicationSHA256: digest ?? replay.publicationSHA256,
            verifiedManifest: manifest ?? replay.verifiedManifest, bindingSnapshot: binding ?? replay.bindingSnapshot,
            scan: scan ?? replay.scan, rawSourceSessionID: rawNativeID ?? replay.rawSourceSessionID,
            nativeIdentity: identity ?? replay.nativeIdentity, parentIdentity: parent ?? replay.parentIdentity,
            suggestedParentIdentity: suggested ?? replay.suggestedParentIdentity)
    }

    private func binding(
        _ original: CaptureIngestSourceBinding, machineID: String? = nil, instanceID: String? = nil,
        source: SourceName? = nil, format: CaptureIngestParseFormat? = nil, root: String? = nil,
        approvedEpoch: String? = nil, authority: Int64? = nil
    ) -> CaptureIngestSourceBinding {
        CaptureIngestSourceBinding(machineID: machineID ?? original.machineID,
            sourceInstanceID: instanceID ?? original.sourceInstanceID, source: source ?? original.source,
            parseFormat: format ?? original.parseFormat, configuredRoot: root ?? original.configuredRoot,
            approvedEpoch: approvedEpoch ?? original.approvedEpoch, authorityGeneration: authority ?? original.authorityGeneration)
    }

    private func seedSession(id: String, owner: String) throws {
        try writer.write { try $0.execute(sql: """
            INSERT INTO sessions(id, source, start_time, file_path, source_locator, authoritative_node,
                                 sync_version, snapshot_hash, tier, custom_name)
            VALUES (?, 'claude-code', '2026-01-01', '/legacy/do-not-open.jsonl', '/legacy/do-not-open.jsonl', ?, 17, ?, 'normal', 'keep-user-name')
            """, arguments: [id, owner, String(repeating: "a", count: 64)]) }
    }

    @discardableResult
    private func seedHistory(from receipt: CaptureIngestCommittedGeneration, versions: ClosedRange<Int>) throws -> [String] {
        try writer.write { db in
            try versions.map { version in
                let parser = "history-\(version)"
                let id = ArchiveV2Hash.sha256(Data("\(receipt.generationID):\(parser)".utf8))
                // Copy a complete valid row without invoking the commit API per
                // generation. Only the ID, parser revision, and version change.
                try db.execute(sql: """
                    INSERT INTO capture_ingest_generations(
                        generation_id, publication_sha256, parser_revision, machine_id, source_instance_id, source,
                        parse_format, configured_root, collector_epoch, authority_generation, sequence, native_id,
                        raw_source_session_id, stored_session_id, parent_native_id, suggested_parent_native_id,
                        manifest_json, normalized_schema_version, normalized_messages_json, normalized_messages_sha256,
                        normalized_message_count, sync_version, snapshot_hash, required_fts_job_id, created_at)
                    SELECT ?, publication_sha256, ?, machine_id, source_instance_id, source,
                        parse_format, configured_root, collector_epoch, authority_generation, sequence, native_id,
                        raw_source_session_id, stored_session_id, parent_native_id, suggested_parent_native_id,
                        manifest_json, normalized_schema_version, normalized_messages_json, normalized_messages_sha256,
                        normalized_message_count, ?, snapshot_hash, required_fts_job_id, created_at
                    FROM capture_ingest_generations WHERE generation_id = ?
                    """, arguments: [id, parser, version, receipt.generationID])
                XCTAssertEqual(db.changesCount, 1)
                return id
            }
        }
    }

    private func setVersion(_ counter: String, receipt: CaptureIngestCommittedGeneration, value: DatabaseValue.Storage) throws {
        let converted: DatabaseValue
        switch value {
        case .int64(let number): converted = number.databaseValue
        case .double(let number): converted = number.databaseValue
        case .string(let string): converted = string.databaseValue
        case .blob(let bytes): converted = bytes.databaseValue
        case .null: converted = .null
        }
        try writer.write { db in
            switch counter {
            case "session":
                try db.execute(sql: "UPDATE sessions SET sync_version = ? WHERE id = ?", arguments: [converted, receipt.sessionID])
            case "binding":
                try db.execute(sql: "UPDATE capture_ingest_identity_bindings SET last_sync_version = ? WHERE stored_session_id = ?",
                               arguments: [converted, receipt.sessionID])
            default:
                try db.execute(sql: "UPDATE capture_ingest_generations SET sync_version = ? WHERE generation_id = ?",
                               arguments: [converted, receipt.generationID])
            }
        }
    }

    private func markReadyForFixture(_ fixture: Fixture, receipt: CaptureIngestCommittedGeneration) throws {
        // Seed a previously completed generation; T2 itself must never do this.
        try writer.write { db in
            try db.execute(sql: "UPDATE capture_ingest_identity_bindings SET last_ready_generation_id = ? WHERE stored_session_id = ?",
                           arguments: [receipt.generationID, receipt.sessionID])
            try db.execute(sql: "UPDATE capture_ingest_ledger SET status = 'index_ready' WHERE publication_sha256 = ? AND parser_revision = ?",
                           arguments: [fixture.claim.publicationSHA256, fixture.claim.parserRevision])
            if let job = receipt.requiredFTSJobID {
                try db.execute(sql: "UPDATE session_index_jobs SET status = 'completed' WHERE id = ?", arguments: [job])
            }
        }
    }

    private func requireSchema(file: StaticString = #filePath, line: UInt = #line) throws -> Bool {
        let required: [String: Set<String>] = [
            "capture_ingest_identity_bindings": ["machine_id", "source_instance_id", "source", "native_id", "stored_session_id",
                "last_parsed_generation_id", "last_ready_generation_id", "last_sync_version"],
            "capture_ingest_generations": ["generation_id", "publication_sha256", "parser_revision", "machine_id", "source_instance_id",
                "source", "parse_format", "configured_root", "collector_epoch", "authority_generation", "sequence", "native_id",
                "raw_source_session_id", "stored_session_id", "parent_native_id", "suggested_parent_native_id", "manifest_json",
                "normalized_schema_version", "normalized_messages_json", "normalized_messages_sha256", "normalized_message_count",
                "sync_version", "snapshot_hash", "required_fts_job_id", "created_at"],
        ]
        return try writer.read { db in
            var complete = true
            for table in required.keys.sorted() {
                let columns = Set(try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))").map { $0["name"] as String })
                let missing = required[table]!.subtracting(columns)
                XCTAssertTrue(missing.isEmpty, "missing commit schema \(table): \(missing.sorted())", file: file, line: line)
                complete = complete && missing.isEmpty
            }
            return complete
        }
    }

    private func generation(_ receipt: CaptureIngestCommittedGeneration) throws -> Row {
        try writer.read { try XCTUnwrap(Row.fetchOne($0, sql: "SELECT * FROM capture_ingest_generations WHERE generation_id = ?",
                                                    arguments: [receipt.generationID])) }
    }

    private func identity(_ fixture: Fixture) throws -> Row {
        let native = fixture.replay.nativeIdentity
        return try writer.read { try XCTUnwrap(Row.fetchOne($0, sql: """
            SELECT * FROM capture_ingest_identity_bindings WHERE machine_id = ? AND source_instance_id = ? AND source = ? AND native_id = ?
            """, arguments: [native.machineID, native.sourceInstanceID, native.source.rawValue, native.nativeID])) }
    }

    private func session(_ id: String) throws -> Row {
        try writer.read { try XCTUnwrap(Row.fetchOne($0, sql: "SELECT * FROM sessions WHERE id = ?", arguments: [id])) }
    }

    private func ledger(_ fixture: Fixture) throws -> Row {
        try writer.read { try XCTUnwrap(Row.fetchOne($0,
            sql: "SELECT * FROM capture_ingest_ledger WHERE publication_sha256 = ? AND parser_revision = ?",
            arguments: [fixture.claim.publicationSHA256, fixture.claim.parserRevision])) }
    }

    private func count(_ table: String) throws -> Int {
        try writer.read { try XCTUnwrap(Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)")) }
    }

    private func state(_ db: Database, tables: [String]) throws -> [String: [Row]] {
        var result: [String: [Row]] = [:]
        for table in tables where try db.tableExists(table) {
            result[table] = try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY rowid")
        }
        return result
    }

    private func state() throws -> [String: [Row]] {
        try writer.read { try state($0, tables: productTables + intakeTables + ["capture_ingest_ledger"]) }
    }

    private func productState() throws -> [String: [Row]] {
        try writer.read { try state($0, tables: productTables) }
    }

    private func intakeState() throws -> [String: [Row]] {
        try writer.read { try state($0, tables: intakeTables) }
    }

    private func assertPayload(_ receipt: CaptureIngestCommittedGeneration, equals expected: [NormalizedMessage],
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let row = try generation(receipt)
        let payload: Data = row["normalized_messages_json"]
        let decoded = try ArchiveCanonicalJSON.decode([NormalizedMessage].self, from: payload)
        XCTAssertTrue(decoded == expected, "complete normalized fields must round-trip without truncation", file: file, line: line)
        XCTAssertTrue(payload == (try ArchiveCanonicalJSON.encode(expected)),
                      "stored bytes must equal the whole canonical payload; do not log large transcript values", file: file, line: line)
        XCTAssertEqual(row["normalized_messages_sha256"] as String, ArchiveV2Hash.sha256(payload), file: file, line: line)
    }

    private func assertExactPendingFTS(_ receipt: CaptureIngestCommittedGeneration,
                                       file: StaticString = #filePath, line: UInt = #line) throws {
        let expectedID = "\(receipt.sessionID):\(receipt.syncVersion):\(receipt.snapshotHash):fts"
        XCTAssertEqual(receipt.requiredFTSJobID, expectedID, file: file, line: line)
        let jobs = try writer.read { try Row.fetchAll($0, sql: "SELECT * FROM session_index_jobs WHERE session_id = ? AND job_kind = 'fts' AND target_sync_version = ?",
                                                     arguments: [receipt.sessionID, receipt.syncVersion]) }
        XCTAssertEqual(jobs.count, 1, file: file, line: line)
        guard let job = jobs.first else { return }
        XCTAssertEqual(job["id"] as String, expectedID, file: file, line: line)
        XCTAssertEqual(job["status"] as String, "pending", file: file, line: line)
        XCTAssertEqual(job["retry_count"] as Int, 0, file: file, line: line)
        XCTAssertEqual(try generation(receipt)["required_fts_job_id"] as String, expectedID, file: file, line: line)
    }

    private func assertParsedOnly(_ fixture: Fixture, receipt: CaptureIngestCommittedGeneration,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        let row = try ledger(fixture)
        XCTAssertEqual(row["status"] as String, "parsed", file: file, line: line)
        XCTAssertNil(row["failure_code"] as String?, file: file, line: line)
        XCTAssertNil(row["claim_token"] as String?, file: file, line: line)
        XCTAssertNil(row["claim_started_at"] as Int64?, file: file, line: line)
        XCTAssertNil(row["claim_expires_at"] as Int64?, file: file, line: line)
        XCTAssertNil(row["retry_after"] as Int64?, file: file, line: line)
        XCTAssertEqual(row["attempt_count"] as Int64, fixture.claim.attemptCount, file: file, line: line)
        XCTAssertEqual(try identity(fixture)["last_parsed_generation_id"] as String, receipt.generationID, file: file, line: line)
        XCTAssertNil(try identity(fixture)["last_ready_generation_id"] as String?, file: file, line: line)
        XCTAssertEqual(try count("sessions_fts"), 0, file: file, line: line)
    }

    private func assertCommitError<T>(_ expected: CaptureIngestCommitError, file: StaticString = #filePath, line: UInt = #line,
                                       _ operation: () throws -> T) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertEqual($0 as? CaptureIngestCommitError, expected, file: file, line: line)
        }
    }

    private func assertLoadError<T>(_ expected: CaptureIngestReadinessError, file: StaticString = #filePath, line: UInt = #line,
                                    _ operation: () throws -> T) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertEqual($0 as? CaptureIngestReadinessError, expected, file: file, line: line)
        }
    }

    private func assertLedgerError<T>(_ expected: CaptureIngestLedgerError, file: StaticString = #filePath, line: UInt = #line,
                                       _ operation: () throws -> T) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertEqual($0 as? CaptureIngestLedgerError, expected, file: file, line: line)
        }
    }

    private func assertInjectedRollback(stage: (String, String, String), fixture: Fixture,
                                        file: StaticString = #filePath, line: UInt = #line) throws {
        let (label, event, table) = stage
        let condition = table == "capture_ingest_ledger" ? "WHEN NEW.status = 'parsed'" : ""
        let before = try state()
        var continued = false
        try writer.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER fail_capture_commit_stage AFTER \(event) ON \(table) \(condition)
                BEGIN
                    UPDATE capture_ingest_ledger SET failure_code = 'injected_side_effect' WHERE parser_revision = 'failure-witness';
                    SELECT RAISE(FAIL, 'injected-\(label)');
                END
                """)
            XCTAssertThrowsError(try CaptureIngestCommitter.commitParsed(db, claim: fixture.claim, replay: fixture.replay,
                expectedParserRevision: revision, now: 101, indexedAt: timestamp), file: file, line: line) { error in
                XCTAssertTrue(error is DatabaseError, "stage must actually execute: \(label)", file: file, line: line)
                XCTAssertTrue((error as? DatabaseError)?.message?.contains("injected-\(label)") == true,
                              "the intended trigger, not an earlier validation failure, must fire", file: file, line: line)
            }
            XCTAssertEqual(try state(db, tables: productTables + intakeTables + ["capture_ingest_ledger"]), before,
                           "inner savepoint must restore all tables before outer continuation: \(label)", file: file, line: line)
            continued = true
            try db.execute(sql: "DROP TRIGGER fail_capture_commit_stage")
        }
        XCTAssertTrue(continued, file: file, line: line)
        XCTAssertEqual(try state(), before, label, file: file, line: line)
    }
}
