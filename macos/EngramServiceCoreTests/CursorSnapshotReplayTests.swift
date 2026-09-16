import Darwin
import Foundation
import SQLite3
import XCTest
@testable import EngramCollectorCore
@testable import EngramCoreRead
@testable import EngramCoreWrite

/// Native replay of modern Cursor file sets and scoped legacy row bodies.
/// Includes schema/CAS reopen for modern captures and cross-module legacy replay.
/// Legacy transport and real-host acceptance remain pending.
final class CursorSnapshotReplayTests: XCTestCase {
    func testLegacyCollectorCanonicalBodyReplaysAcrossModulesAfterSourceRemoval() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("cursor-legacy-bridge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        let physical = try XCTUnwrap(realpath(temporary.path, nil))
        defer { free(physical) }
        let base = URL(fileURLWithPath: String(cString: physical))
        defer { try? FileManager.default.removeItem(at: base) }
        let user = base.appendingPathComponent("User")
        let global = user.appendingPathComponent("globalStorage")
        let workspace = user.appendingPathComponent("workspaceStorage/ws")
        let staging = base.appendingPathComponent("staging")
        for directory in [global, workspace, staging] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        let source = global.appendingPathComponent("state.vscdb")
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.path, &writer), SQLITE_OK)
        defer { if let writer { sqlite3_close(writer) } }
        let handle = try XCTUnwrap(writer)
        func sql(_ text: String) throws {
            guard sqlite3_exec(handle, text, nil, nil, nil) == SQLITE_OK else { throw POSIXError(.EIO) }
        }
        try Data(#"{"folder":"file:///tmp/cursor-legacy-bridge-project"}"#.utf8)
            .write(to: workspace.appendingPathComponent("workspace.json"))
        try sql("""
            PRAGMA journal_mode=WAL;
            PRAGMA wal_autocheckpoint=0;
            CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT);
            INSERT INTO ItemTable VALUES ('composer.composerHeaders',
              '{"allComposers":[{"composerId":"owned","workspaceIdentifier":{"id":"ws"}}]}');
            INSERT INTO cursorDiskKV VALUES ('composerData:owned',
              '{"composerId":"owned","createdAt":1700000000000,"name":"Frozen legacy"}');
            INSERT INTO cursorDiskKV VALUES ('bubbleId:owned:1','{"type":1,"text":"original user"}');
            INSERT INTO cursorDiskKV VALUES ('bubbleId:owned:2',
              CAST('{"type":2,"text":"blob answer","tokenCount":{"inputTokens":3,"outputTokens":5}}' AS BLOB));
            INSERT INTO cursorDiskKV VALUES ('bubbleId:owned:3',X'70726500706F7374');
            INSERT INTO cursorDiskKV VALUES ('bubbleId:owned:4',NULL);
            INSERT INTO cursorDiskKV VALUES ('composerData:sibling',
              '{"composerId":"sibling","conversation":[{"type":1,"text":"SIBLING-SECRET"}]}');
            """)
        XCTAssertEqual(sqlite3_db_cacheflush(handle), SQLITE_OK)
        let logical = source.path + "?composer=owned"
        guard case .success(let before) = try await CursorAdapter(dbPath: source.path).scanForIndexing(locator: logical) else {
            return XCTFail("native fixture must parse before capture")
        }
        XCTAssertEqual(before.info.cwd, "/tmp/cursor-legacy-bridge-project")
        let capture = try CollectorCursorLegacyOwnership.capture(
            globalStorageRoot: global, composerID: "owned", stagingParent: staging)
        let body = try capture.archiveSession()
        XCTAssertEqual(body.bubbles.map(\.storage), [.text, .blob, .blob, .null])
        XCTAssertEqual(body.bubbles.count, 4)
        let saved = base.appendingPathComponent("legacy-body.json")
        try body.encodeCanonical().write(to: saved, options: .atomic)
        XCTAssertEqual(sqlite3_close(handle), SQLITE_OK)
        writer = nil
        try FileManager.default.removeItem(at: user)
        let restored = try EngramCoreRead.ArchiveCursorLegacySession.decodeCanonical(Data(contentsOf: saved))
        guard case .success(let after) = try await CursorAdapter.scanCapturedLegacySession(restored, logicalLocator: logical) else {
            return XCTFail("Collector bytes must replay in CoreRead without live sources")
        }
        XCTAssertEqual(after.scan.info, before.info)
        XCTAssertEqual(after.scan.messages, before.messages)
        XCTAssertEqual(after.rawSourceSessionID, "owned")
        XCTAssertEqual(after.scan.messages.map(\.content), ["original user", "blob answer"])
        XCTAssertNotEqual(restored.rawPayloadByteCount, before.info.sizeBytes)

        let machine = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
        let instance = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
        let epoch = "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"
        let casRoot = base.appendingPathComponent("legacy-cas")
        let collectorCAS = try EngramCollectorCore.ImmutableArchiveCAS(root: casRoot)
        let catalog = try EngramCollectorCore.ArchiveCatalog(root: casRoot, machineID: machine)
        try catalog.migrate()
        defer { try? catalog.close() }
        let persistedBody = try EngramCollectorCore.ArchiveCursorLegacySession.decodeCanonical(Data(contentsOf: saved))
        let durable = try EngramCollectorCore.ExactSourceCapturer.captureCursorLegacySession(
            persistedBody, machineID: machine, cas: collectorCAS, catalog: catalog)
        let publication = try EngramCoreRead.CollectorPublicationEnvelope(machineID: machine, sourceInstanceID: instance,
            collectorEpoch: epoch, sequence: 1, manifestSHA256: durable.capture.unboundManifestSHA256)
        let binding = CaptureIngestSourceBinding(machineID: machine, sourceInstanceID: instance,
            source: .cursor, parseFormat: .cursor, configuredRoot: global.path,
            approvedEpoch: epoch, authorityGeneration: 1)
        let hq = try await CaptureIngestReplay.replay(publication: publication, bindingSnapshot: binding,
            cas: EngramCoreWrite.ImmutableArchiveCAS(root: casRoot), stagingParent: staging)
        XCTAssertEqual(hq.verifiedManifest.schemaVersion, 6)
        XCTAssertEqual(hq.scan.info, before.info)
        XCTAssertEqual(hq.scan.messages, before.messages)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: user.path))
    }

    func testRawArchiveRetainsHistoricalRootsHiddenByCurrentSQLiteMetadata() async throws {
        for hex in [false, true] {
            let world = try ReplayWorld(); defer { world.remove() }
            let id = "root-history"
            let oldMain = "/synthetic/excluded-main"
            let oldWAL = "/synthetic/excluded-wal-history"
            let selected = "/synthetic/allowed-current"
            let store = try world.writeStore(workspace: "ws", id: id, journal: .walCheckpointed,
                blobs: [("user", #"{"role":"user","content":"Visible current conversation"}"#),
                        ("assistant", #"{"role":"assistant","content":"Visible current response"}"#)],
                metadata: ["cwd": oldMain])
            try world.updateStoredCWD(oldWAL, hex: hex)
            try world.updateStoredCWD(selected, hex: hex)
            try world.freezePayloadMtimes(store: store, extras: [URL(fileURLWithPath: store.path + "-wal")])
            let before = try await world.scanNative(root: world.cursorRoot)
            XCTAssertEqual(before.info.cwd, selected)
            let replayed = try await world.captureAndReplay(sessionID: id, before: before)
            let main = try XCTUnwrap(replayed.capture.files.first { $0.relativePath.hasSuffix("/store.db") })
            let wal = try XCTUnwrap(replayed.capture.files.first { $0.relativePath.hasSuffix("/store.db-wal") })
            func needle(_ root: String, encoded: Bool) -> Data {
                let bytes = Data(root.utf8)
                return encoded ? Data(bytes.map { String(format: "%02x", $0) }.joined().utf8) : bytes
            }
            let originalMetadata = try JSONSerialization.data(withJSONObject: ["cwd": oldMain], options: [.sortedKeys])
            let originalHex = Data(originalMetadata.map { String(format: "%02x", $0) }.joined().utf8)
            XCTAssertNotNil(main.bytes.range(of: originalHex))
            XCTAssertNotNil(wal.bytes.range(of: needle(oldWAL, encoded: hex)))
            XCTAssertNotNil(wal.bytes.range(of: needle(selected, encoded: hex)))
            // Full raw custody is deliberate. Current native cwd cannot alone
            // authorize publishing historical root evidence under exclusions.
        }
    }

    func testPairedTranscriptWinsAndLiveEmptySummaryOverlaysStoredMetadata() async throws {
        let world = try ReplayWorld()
        defer { world.remove() }
        let id = "paired-live"
        let store = try world.writeStore(
            workspace: "ws",
            id: id,
            journal: .walCheckpointed,
            blobs: [
                ("user", #"{"role":"user","content":"STORE user that must lose"}"#),
                ("assistant", #"{"role":"assistant","content":"STORE assistant that must lose"}"#),
            ],
            metadata: [
                "createdAt": 1_700_000_000_000,
                "cwd": "/store/secret-cwd",
                "name": "Store title that must lose",
                "latestConversationSummary": ["summary": ["summary": "STORE digest that must lose"]],
            ]
        )
        let meta = store.deletingLastPathComponent().appendingPathComponent("meta.json")
        try world.writeFile(
            meta,
            JSONSerialization.data(
                withJSONObject: [
                    "cwd": "/replay/paired-project",
                    "name": "Live overlay title",
                    "latestConversationSummary": ["summary": ["summary": ""]],
                ],
                options: [.sortedKeys]
            )
        )
        let transcript = try world.writeTranscript(
            project: "proj",
            id: id,
            rows: [
                #"{"role":"user","message":{"content":[{"type":"text","text":"LIVE user that must win"}]}}"#,
                #"{"role":"assistant","message":{"content":[{"type":"text","text":"LIVE assistant that must win"}]}}"#,
            ]
        )
        try world.plantUnrelatedNotes(nextToStore: store, nextToTranscript: transcript)
        try world.freezePayloadMtimes(store: store, extras: [
            URL(fileURLWithPath: store.path + "-wal"),
            meta,
            transcript,
        ])

        let before = try await world.scanNative(root: world.cursorRoot)
        XCTAssertEqual(before.messages.map(\.content), ["LIVE user that must win", "LIVE assistant that must win"])
        XCTAssertNotEqual(before.messages.map(\.content), ["STORE user that must lose", "STORE assistant that must lose"])
        XCTAssertEqual(before.info.cwd, "/replay/paired-project")
        XCTAssertEqual(before.info.project, "paired-project")
        XCTAssertEqual(before.info.displayTitle, "Live overlay title")
        XCTAssertNil(before.info.summary)
        XCTAssertEqual(before.info.userMessageCount, 1)
        XCTAssertEqual(before.info.assistantMessageCount, 1)

        let replayed = try await world.captureAndReplay(sessionID: id, before: before)
        let captured = Set(replayed.capture.files.map(\.relativePath))
        XCTAssertTrue(captured.contains(world.storeRelative(workspace: "ws", id: id)))
        XCTAssertTrue(captured.contains(world.transcriptRelative(project: "proj", id: id)))
        XCTAssertTrue(captured.contains(world.metaRelative(workspace: "ws", id: id)))
    }

    func testStoreOnlyWALRowsReplayThroughExactMainAndWALBytes() async throws {
        let world = try ReplayWorld()
        defer { world.remove() }
        let id = "wal-only"
        let store = try world.writeStore(
            workspace: "ws",
            id: id,
            journal: .walUncheckpointed,
            blobs: [
                ("user", #"{"role":"user","content":"WAL user row"}"#),
                ("assistant", #"{"role":"assistant","content":"WAL assistant row"}"#),
            ],
            metadata: [
                "createdAt": 1_700_000_100_000,
                "cwd": "/replay/wal-only",
                "name": "WAL store title",
            ]
        )
        let wal = URL(fileURLWithPath: store.path + "-wal")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wal.path))
        XCTAssertNil(try Data(contentsOf: store).range(of: Data("WAL user row".utf8)))
        XCTAssertNotNil(try Data(contentsOf: wal).range(of: Data("WAL user row".utf8)))
        try world.plantUnrelatedNotes(nextToStore: store, nextToTranscript: nil)
        try world.freezePayloadMtimes(store: store, extras: [wal])

        let before = try await world.scanNative(root: world.cursorRoot)
        XCTAssertEqual(before.messages.map(\.content), ["WAL user row", "WAL assistant row"])
        XCTAssertEqual(before.info.cwd, "/replay/wal-only")
        XCTAssertEqual(before.info.displayTitle, "WAL store title")
        XCTAssertEqual(before.info.summary, "WAL user row")

        let replayed = try await world.captureAndReplay(sessionID: id, before: before)
        XCTAssertNil(replayed.session.transcriptRelativePath)
        XCTAssertEqual(
            Set(replayed.capture.files.map(\.relativePath)),
            Set([
                world.storeRelative(workspace: "ws", id: id),
                world.storeRelative(workspace: "ws", id: id) + "-wal",
            ])
        )
    }

    func testTranscriptOnlyReplaysWithoutInventedCwdOrMetadata() async throws {
        let world = try ReplayWorld()
        defer { world.remove() }
        let id = "transcript-only"
        let transcript = try world.writeTranscript(
            project: "proj",
            id: id,
            rows: [
                #"{"role":"user","message":{"content":[{"type":"text","text":"Transcript only user"}]}}"#,
                #"{"role":"assistant","message":{"content":[{"type":"text","text":"Transcript only assistant"}]}}"#,
            ]
        )
        try world.plantUnrelatedNotes(nextToStore: nil, nextToTranscript: transcript)
        try world.setMtime(path: transcript.path, nanoseconds: 1_788_825_800_000_000_111, preserveAtime: true)

        let before = try await world.scanNative(root: world.cursorRoot)
        XCTAssertEqual(before.messages.map(\.content), ["Transcript only user", "Transcript only assistant"])
        XCTAssertEqual(before.info.cwd, "")
        XCTAssertNil(before.info.project)
        XCTAssertNil(before.info.displayTitle)
        XCTAssertEqual(before.info.summary, "Transcript only user")
        XCTAssertEqual(before.info.messageCount, 2)

        let replayed = try await world.captureAndReplay(sessionID: id, before: before)
        XCTAssertNil(replayed.session.storeRelativePath)
        XCTAssertEqual(replayed.capture.files.map(\.relativePath), [world.transcriptRelative(project: "proj", id: id)])
        XCTAssertFalse(replayed.session.present.contains { $0.relativePath.contains("meta.json") })
        XCTAssertFalse(replayed.session.absentRelativePaths.contains { $0.contains("store.db") || $0.contains("meta.json") })
    }

    func testDeleteJournalStoreOmitsSidecarsAndReplaysExactMain() async throws {
        let world = try ReplayWorld()
        defer { world.remove() }
        let id = "delete-only"
        let store = try world.writeStore(
            workspace: "ws",
            id: id,
            journal: .delete,
            blobs: [
                ("user", #"{"role":"user","content":"DELETE user row"}"#),
                ("assistant", #"{"role":"assistant","content":"DELETE assistant row"}"#),
            ],
            metadata: [
                "createdAt": 1_700_000_200_000,
                "cwd": "/replay/delete-only",
                "name": "DELETE store title",
            ]
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path + "-journal"))
        let meta = store.deletingLastPathComponent().appendingPathComponent("meta.json")
        try world.writeFile(
            meta,
            JSONSerialization.data(
                withJSONObject: ["cwd": "/replay/delete-only", "name": "DELETE live title"],
                options: [.sortedKeys]
            )
        )
        try world.plantUnrelatedNotes(nextToStore: store, nextToTranscript: nil)
        try world.freezePayloadMtimes(store: store, extras: [meta])

        let before = try await world.scanNative(root: world.cursorRoot)
        XCTAssertEqual(before.messages.map(\.content), ["DELETE user row", "DELETE assistant row"])
        XCTAssertEqual(before.info.cwd, "/replay/delete-only")
        XCTAssertEqual(before.info.displayTitle, "DELETE live title")

        let replayed = try await world.captureAndReplay(sessionID: id, before: before)
        XCTAssertEqual(
            Set(replayed.capture.files.map(\.relativePath)),
            Set([world.storeRelative(workspace: "ws", id: id), world.metaRelative(workspace: "ws", id: id)])
        )
        XCTAssertFalse(replayed.capture.files.contains { $0.relativePath.hasSuffix("-wal") })
    }

    func testMetaAbsentStoreReplaysFullVisibleMessagesFromExactMain() async throws {
        let world = try ReplayWorld()
        defer { world.remove() }
        let id = "meta-absent"
        let store = try world.writeStore(
            workspace: "ws",
            id: id,
            journal: .delete,
            blobs: [
                ("user", #"{"role":"user","content":"Meta-absent user"}"#),
                ("assistant", #"{"role":"assistant","content":"Meta-absent assistant"}"#),
            ],
            metadata: [
                "createdAt": 1_700_000_300_000,
                "cwd": "/replay/meta-absent",
                "name": "Meta-absent title",
            ]
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path + "-journal"))
        try world.plantUnrelatedNotes(nextToStore: store, nextToTranscript: nil)
        try world.freezePayloadMtimes(store: store, extras: [])

        let before = try await world.scanNative(root: world.cursorRoot)
        XCTAssertEqual(before.messages.map(\.content), ["Meta-absent user", "Meta-absent assistant"])
        XCTAssertEqual(before.info.cwd, "/replay/meta-absent")
        XCTAssertEqual(before.info.displayTitle, "Meta-absent title")
        XCTAssertEqual(before.info.summary, "Meta-absent user")
        XCTAssertEqual(before.info.userMessageCount + before.info.assistantMessageCount, 2)

        let replayed = try await world.captureAndReplay(sessionID: id, before: before)
        XCTAssertEqual(replayed.capture.files.map(\.relativePath), [world.storeRelative(workspace: "ws", id: id)])
        XCTAssertTrue(replayed.session.absentRelativePaths.contains(world.metaRelative(workspace: "ws", id: id)))
        XCTAssertFalse(replayed.capture.files.contains { $0.relativePath.hasSuffix("meta.json") })
    }

    func testCursorPrivacyBoundsBothStoredAndLiveMetadataRecords() async throws {
        let world = try ReplayWorld(); defer { world.remove() }
        let archived = try await world.archivePrivacySession(id: "privacy-record-cap",
            storedCWD: "/synthetic/allowed", live: ["cwd": "/synthetic/allowed"])
        XCTAssertEqual(try world.assessCursor(archived, limits: .init(maxRecords: 1)), .withheld(.limitsExceeded))
        _ = try world.eligible(world.assessCursor(archived, limits: .init(maxRecords: 2)))
        let single = try ReplayWorld(); defer { single.remove() }
        let storedOnly = try await single.archivePrivacySession(id: "privacy-one-record",
            storedCWD: "/synthetic/allowed", live: nil)
        _ = try single.eligible(single.assessCursor(storedOnly, limits: .init(maxRecords: 1)))
    }

    func testCursorPrivacyReadsWALOnlyMetadataFromReopenedCAS() async throws {
        let world = try ReplayWorld(); defer { world.remove() }
        let id = "privacy-wal-only"
        let root = "/synthetic/wal-only"
        let metadata: [String: Any] = ["cwd": root]
        let store = try world.writeStore(workspace: "ws", id: id, journal: .walUncheckpointed,
            blobs: [("user", #"{"role":"user","content":"WAL user"}"#),
                    ("assistant", #"{"role":"assistant","content":"WAL assistant"}"#)], metadata: metadata)
        let encoded = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        let needle = Data(encoded.map { String(format: "%02x", $0) }.joined().utf8)
        XCTAssertNil(try Data(contentsOf: store).range(of: needle))
        XCTAssertNotNil(try Data(contentsOf: URL(fileURLWithPath: store.path + "-wal")).range(of: needle))
        try world.freezePayloadMtimes(store: store, extras: [URL(fileURLWithPath: store.path + "-wal")])
        let archived = try await world.archivePrivacy(sessionID: id, before: try await world.scanNative(root: world.cursorRoot))
        XCTAssertFalse(world.fm.fileExists(atPath: world.cursorRoot.path))
        // A canonical physical input must survive CAS URL handling unchanged.
        XCTAssertEqual(archived.cas.snapshotStagingParent.path, world.base.appendingPathComponent("archive/tmp").path)
        let proof = try world.eligible(world.assessCursor(archived))
        XCTAssertEqual(proof.nativeSessionID, id)
        XCTAssertEqual(proof.projectRoot, root)
        XCTAssertEqual(try world.assessCursor(archived, policy: world.cursorPolicy(excluded: [root])),
            .withheld(.excludedProject))
        XCTAssertEqual(try world.fm.contentsOfDirectory(atPath: archived.cas.snapshotStagingParent.path), [])
    }

    func testCursorPrivacyRejectsMemberHashForgeryWithValidCASAndAggregate() async throws {
        let world = try ReplayWorld(); defer { world.remove() }
        let archived = try await world.archivePrivacySession(id: "privacy-member-forgery",
            storedCWD: "/synthetic/allowed", live: ["cwd": "/synthetic/allowed"])
        _ = try world.eligible(world.assessCursor(archived))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: archived.result.capture.unboundManifestBytes) as? [String: Any])
        var layout = try XCTUnwrap(object["replayLayout"] as? [String: Any])
        var files = try XCTUnwrap(layout["files"] as? [[String: Any]])
        let member = try XCTUnwrap(files.firstIndex { ($0["relativePath"] as? String)?.hasSuffix("/store.db") == true })
        files[member]["wholeSourceSHA256"] = String(repeating: "a", count: 64)
        layout["files"] = files
        object["replayLayout"] = layout
        let manifest = try JSONDecoder().decode(
            EngramCollectorCore.ArchiveSourceManifest.self, from: JSONSerialization.data(withJSONObject: object))
        let bytes = try EngramCollectorCore.ArchiveCanonicalJSON.encode(manifest)
        let digest = EngramCollectorCore.ArchiveV2Hash.sha256(bytes)
        _ = try archived.cas.publishManifest(bytes, expectedSHA256: digest)
        let original = archived.result.capture
        let capture = EngramCollectorCore.ArchiveCapture(captureID: original.captureID, machineID: original.machineID,
            source: original.source, locator: original.locator, generation: original.generation,
            wholeSourceSHA256: original.wholeSourceSHA256, rawByteCount: original.rawByteCount,
            chunkSize: original.chunkSize, unboundManifestSHA256: digest, unboundManifestBytes: bytes,
            status: original.status, diagnostic: original.diagnostic, capturedAt: original.capturedAt)
        XCTAssertTrue(EngramCollectorCore.ArchiveSourceDescriptor.isCursorModernFileSet(manifest))
        XCTAssertEqual(manifest.chunks, archived.result.manifest.chunks)
        XCTAssertEqual(manifest.wholeSourceSHA256, archived.result.manifest.wholeSourceSHA256)
        XCTAssertEqual(try world.assessCursor((EngramCollectorCore.ArchiveCaptureResult(capture: capture, manifest: manifest), archived.cas)),
            .withheld(.invalidCapture))
    }

    func testCursorFactoryRejectsUnconfiguredReplayWithoutLayout() async throws {
        let world = try ReplayWorld(); defer { world.remove() }
        let result = try await SessionAdapterFactory.scanCapturedSource(
            physicalLocator: world.replayStage.appendingPathComponent("missing.db").path,
            stagingRoot: world.replayStage.path, logicalLocator: "cursor-modern:unconfigured", format: .cursor)
        guard case .failure(let failure) = result else { return XCTFail("Cursor replay requires a captured layout") }
        XCTAssertEqual(failure, .unsupportedVirtualLocator)
    }

    func testCursorPrivacyEligibleWhenStoredAndLiveShareOneCanonicalRoot() async throws {
        let world = try ReplayWorld(); defer { world.remove() }
        let id = "privacy-same"
        let root = "/synthetic/allowed"
        try world.writePrivacySession(id: id, storedCWD: root, live: ["cwd": root],
            blob: #"{"role":"user","content":"Visible","cwd":"/synthetic/excluded-from-blob"}"#)
        let before = try await world.scanNative(root: world.cursorRoot)
        XCTAssertEqual(before.info.id, id)
        XCTAssertEqual(before.info.cwd, root)
        let archived = try await world.archivePrivacy(sessionID: id, before: before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.cursorRoot.path))
        try world.writePrivacySession(id: id, storedCWD: "/synthetic/excluded-from-blob", live: nil)
        let policy = try world.cursorPolicy(excluded: ["/synthetic/excluded-from-blob"])
        let proof = try world.eligible(world.assessCursor(archived, policy: policy))
        XCTAssertEqual(proof.nativeSessionID, id)
        XCTAssertEqual(proof.projectRoot, root)
        XCTAssertEqual(proof.source, .cursor)
        XCTAssertEqual(proof.format, .cursor)
        XCTAssertEqual(proof.generation, archived.result.manifest.generation)
        XCTAssertTrue(proof.isCurrent(for: archived.result, policy: policy, format: .cursor))
    }

    func testCursorPrivacyWithholdsExcludedStoredRootEvenWhenLiveIsAllowed() async throws {
        let world = try ReplayWorld(); defer { world.remove() }
        let archived = try await world.archivePrivacySession(
            id: "privacy-excluded-store", storedCWD: "/synthetic/excluded", live: ["cwd": "/synthetic/allowed"])
        XCTAssertEqual(
            try world.assessCursor(archived, policy: world.cursorPolicy(excluded: ["/synthetic/excluded"])),
            .withheld(.excludedProject)
        )
    }

    func testCursorPrivacyWithholdsTwoDistinctAllowedRootsWithoutClaudeException() async throws {
        let world = try ReplayWorld(); defer { world.remove() }
        let archived = try await world.archivePrivacySession(
            id: "privacy-conflict", storedCWD: "/synthetic/allowed", live: ["cwd": "/synthetic/other"])
        XCTAssertEqual(try world.assessCursor(archived), .withheld(.conflictingProjectRoots))
    }

    func testCursorPrivacyWithholdsEmptyNullTypedOverlayAndTranscriptOnly() async throws {
        for live in [["cwd": ""], ["cwd": NSNull()], ["cwd": 1]] as [[String: Any]] {
            let world = try ReplayWorld(); defer { world.remove() }
            let archived = try await world.archivePrivacySession(
                id: "privacy-invalid-live", storedCWD: "/synthetic/allowed", live: live)
            XCTAssertEqual(try world.assessCursor(archived), .withheld(.invalidProjectRoot), String(describing: live))
        }
        let transcriptOnly = try ReplayWorld(); defer { transcriptOnly.remove() }
        let id = "privacy-transcript"
        try transcriptOnly.writeTranscript(project: "proj", id: id, rows: [
            #"{"role":"user","message":{"content":[{"type":"text","text":"Transcript only user"}]}}"#,
            #"{"role":"assistant","message":{"content":[{"type":"text","text":"Transcript only assistant"}]}}"#,
        ])
        let before = try await transcriptOnly.scanNative(root: transcriptOnly.cursorRoot)
        XCTAssertEqual(before.info.cwd, "")
        let archived = try await transcriptOnly.archivePrivacy(sessionID: id, before: before)
        let proof = try transcriptOnly.eligible(transcriptOnly.assessCursor(archived))
        XCTAssertNil(proof.projectRoot)
        XCTAssertTrue(proof.isCurrent(for: archived.result, policy: try transcriptOnly.cursorPolicy(), format: .cursor))
        XCTAssertFalse(proof.isCurrent(for: archived.result,
            policy: try transcriptOnly.cursorPolicy(excluded: ["/private/project"]), format: .cursor))
        XCTAssertEqual(try transcriptOnly.assessCursor(archived,
            policy: try transcriptOnly.cursorPolicy(excluded: ["/private/project"])),
                       .withheld(.invalidProjectRoot))
    }

    func testCursorPrivacyWithholdsPresentMalformedOrInvalidUTF8LiveMetadata() async throws {
        for body in [Data("{".utf8), Data([0xFF, 0x00, 0x0A])] {
            let world = try ReplayWorld(); defer { world.remove() }
            let id = "privacy-malformed"
            let store = try world.writePrivacySession(id: id, storedCWD: "/synthetic/allowed", live: nil)
            try world.writeFile(store.deletingLastPathComponent().appendingPathComponent("meta.json"), body)
            try world.freezePayloadMtimes(store: store, extras: [store.deletingLastPathComponent().appendingPathComponent("meta.json")])
            let archived = try await world.archivePrivacy(sessionID: id, before: try await world.scanNative(root: world.cursorRoot))
            XCTAssertTrue(archived.result.manifest.replayLayout.files?.contains { $0.relativePath.hasSuffix("meta.json") } == true)
            XCTAssertEqual(try world.assessCursor(archived), .withheld(.malformedMetadata))
        }
    }

    func testCursorPrivacyDefaultPolicyAndRemovedSourceStillBindProof() async throws {
        let world = try ReplayWorld(); defer { world.remove() }
        let archived = try await world.archivePrivacySession(
            id: "privacy-policy", storedCWD: "/synthetic/allowed", live: ["cwd": "/synthetic/allowed"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.cursorRoot.path))
        XCTAssertEqual(
            try EngramCollectorCore.CollectorPrivacyProof.assess(
                capture: archived.result, cas: archived.cas, format: .cursor,
                policy: EngramCollectorCore.CollectorPrivacyPolicy(revision: 1, excludedProjectRoots: [])),
            .withheld(.unsupportedSource)
        )
        let policy = try world.cursorPolicy()
        let proof = try world.eligible(world.assessCursor(archived, policy: policy))
        XCTAssertTrue(proof.isCurrent(for: archived.result, policy: policy, format: .cursor))
        XCTAssertFalse(proof.isCurrent(for: archived.result, policy: try world.cursorPolicy(revision: 2), format: .cursor))
        let excluded = try world.cursorPolicy(excluded: ["/synthetic/allowed"])
        XCTAssertFalse(proof.isCurrent(for: archived.result, policy: excluded, format: .cursor))
        XCTAssertEqual(try world.assessCursor(archived, policy: excluded), .withheld(.excludedProject))
    }

    func testCursorPrivacyLimitsAndCASTamperWithholdBeforeMemberSQL() async throws {
        let world = try ReplayWorld(); defer { world.remove() }
        let archived = try await world.archivePrivacySession(
            id: "privacy-limits", storedCWD: "/synthetic/allowed", live: ["cwd": "/synthetic/allowed"])
        let raw = archived.result.manifest.rawByteCount
        for limits in [
            EngramCollectorCore.CollectorPrivacyLimits(maxSourceBytes: raw - 1),
            EngramCollectorCore.CollectorPrivacyLimits(maxLineBytes: 4),
            EngramCollectorCore.CollectorPrivacyLimits(maxRecords: 0),
            EngramCollectorCore.CollectorPrivacyLimits(maxProjectRoots: 0),
            EngramCollectorCore.CollectorPrivacyLimits(maxTotalProjectRootBytes: 3),
        ] {
            XCTAssertEqual(try world.assessCursor(archived, limits: limits), .withheld(.limitsExceeded))
        }
        let twoRoots = try ReplayWorld(); defer { twoRoots.remove() }
        let conflict = try await twoRoots.archivePrivacySession(
            id: "privacy-root-cap", storedCWD: "/synthetic/allowed", live: ["cwd": "/synthetic/other"])
        XCTAssertEqual(
            try twoRoots.assessCursor(conflict, limits: EngramCollectorCore.CollectorPrivacyLimits(maxProjectRoots: 1)),
            .withheld(.limitsExceeded)
        )
        let digest = try XCTUnwrap(archived.result.manifest.chunks.first).rawSHA256
        let object = world.base.appendingPathComponent("archive/objects/sha256/\(digest.prefix(2))/\(digest)")
        try Data("corrupt".utf8).write(to: object)
        XCTAssertEqual(try world.assessCursor(archived), .withheld(.invalidCapture))
    }
}

private final class ReplayWorld {
    let fm = FileManager.default
    let base: URL
    let cursorRoot: URL
    let captureStaging: URL
    let replayStage: URL
    let missingLegacyDB: URL
    private var liveStores: [OpaquePointer] = []

    init() throws {
        let temporary = fm.temporaryDirectory.appendingPathComponent("engram-cursor-replay-" + UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: false)
        let physical = try XCTUnwrap(realpath(temporary.path, nil))
        defer { free(physical) }
        base = URL(fileURLWithPath: String(cString: physical))
        cursorRoot = base.appendingPathComponent(".cursor")
        captureStaging = base.appendingPathComponent("capture-staging")
        replayStage = base.appendingPathComponent("replay-stage")
        missingLegacyDB = base.appendingPathComponent("missing.vscdb")
        for directory in [cursorRoot, captureStaging, replayStage] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        XCTAssertFalse(fm.fileExists(atPath: missingLegacyDB.path))
    }

    func remove() {
        closeLiveStores()
        try? fm.removeItem(at: base)
    }

    func closeLiveStores() {
        for handle in liveStores {
            if sqlite3_close(handle) != SQLITE_OK {
                sqlite3_close_v2(handle)
            }
        }
        liveStores.removeAll()
    }

    func cursorPolicy(
        revision: Int64 = 1,
        excluded: [String] = [],
        sources: Set<EngramCollectorCore.SourceName> = [.cursor]
    ) throws -> EngramCollectorCore.CollectorPrivacyPolicy {
        try EngramCollectorCore.CollectorPrivacyPolicy(
            revision: revision, excludedProjectRoots: excluded, allowedSources: sources)
    }

    func assessCursor(
        _ archived: (result: EngramCollectorCore.ArchiveCaptureResult, cas: EngramCollectorCore.ImmutableArchiveCAS),
        policy: EngramCollectorCore.CollectorPrivacyPolicy? = nil,
        limits: EngramCollectorCore.CollectorPrivacyLimits = .init()
    ) throws -> EngramCollectorCore.CollectorPrivacyAssessment {
        try EngramCollectorCore.CollectorPrivacyProof.assess(
            capture: archived.result, cas: archived.cas, format: .cursor,
            policy: try policy ?? cursorPolicy(), limits: limits)
    }

    func eligible(
        _ assessment: EngramCollectorCore.CollectorPrivacyAssessment
    ) throws -> EngramCollectorCore.CollectorPrivacyProof {
        guard case .eligible(let proof) = assessment else {
            throw NSError(domain: "CursorSnapshotReplayTests", code: 1,
                userInfo: [NSLocalizedDescriptionKey: String(describing: assessment)])
        }
        return proof
    }

    func reopenPersistedCapture() throws -> (
        result: EngramCollectorCore.ArchiveCaptureResult,
        cas: EngramCollectorCore.ImmutableArchiveCAS
    ) {
        let archiveRoot = base.appendingPathComponent("archive")
        let cas = try EngramCollectorCore.ImmutableArchiveCAS(root: archiveRoot)
        let catalog = try EngramCollectorCore.ArchiveCatalog(
            root: archiveRoot, machineID: "11111111-2222-3333-4444-555555555555")
        try catalog.migrate()
        defer { try? catalog.close() }
        let capture = try XCTUnwrap(try catalog.unboundCaptures(limit: 2).first)
        let manifest = try EngramCollectorCore.ArchiveCanonicalJSON.decode(
            EngramCollectorCore.ArchiveSourceManifest.self, from: capture.unboundManifestBytes)
        return (EngramCollectorCore.ArchiveCaptureResult(capture: capture, manifest: manifest), cas)
    }

    func archivePrivacy(
        sessionID: String,
        before: IndexingScan
    ) async throws -> (result: EngramCollectorCore.ArchiveCaptureResult, cas: EngramCollectorCore.ImmutableArchiveCAS) {
        _ = try await captureAndReplay(sessionID: sessionID, before: before)
        return try reopenPersistedCapture()
    }

    func archivePrivacySession(
        id: String,
        storedCWD: String,
        live: [String: Any]?
    ) async throws -> (result: EngramCollectorCore.ArchiveCaptureResult, cas: EngramCollectorCore.ImmutableArchiveCAS) {
        let store = try writePrivacySession(id: id, storedCWD: storedCWD, live: live)
        var extras: [URL] = []
        if live != nil { extras.append(store.deletingLastPathComponent().appendingPathComponent("meta.json")) }
        try freezePayloadMtimes(store: store, extras: extras)
        return try await archivePrivacy(sessionID: id, before: try await scanNative(root: cursorRoot))
    }

    @discardableResult
    func writePrivacySession(
        id: String,
        storedCWD: String,
        live: [String: Any]?,
        blob: String = #"{"role":"user","content":"Visible current conversation"}"#
    ) throws -> URL {
        let store = try writeStore(
            workspace: "ws",
            id: id,
            journal: .delete,
            blobs: [
                ("user", blob),
                ("assistant", #"{"role":"assistant","content":"Visible current response"}"#),
            ],
            metadata: ["cwd": storedCWD, "createdAt": 1_700_000_400_000]
        )
        if let live {
            try writeFile(
                store.deletingLastPathComponent().appendingPathComponent("meta.json"),
                JSONSerialization.data(withJSONObject: live, options: [.sortedKeys])
            )
        }
        return store
    }

    func storeRelative(workspace: String, id: String) -> String {
        "chats/\(workspace)/\(id)/store.db"
    }

    func transcriptRelative(project: String, id: String) -> String {
        "projects/\(project)/agent-transcripts/\(id)/\(id).jsonl"
    }

    func metaRelative(workspace: String, id: String) -> String {
        "chats/\(workspace)/\(id)/meta.json"
    }

    func adapter(root: URL) -> CursorAdapter {
        CursorAdapter(dbPath: missingLegacyDB.path, cursorDataRoot: root)
    }

    func scanNative(root: URL) async throws -> IndexingScan {
        XCTAssertFalse(fm.fileExists(atPath: missingLegacyDB.path), "legacy dbPath must stay nonexistent")
        let native = adapter(root: root)
        let locators = try await native.listSessionLocators()
        XCTAssertEqual(locators.count, 1)
        let locator = try XCTUnwrap(locators.first)
        XCTAssertTrue(locator.hasPrefix("cursor-modern:"))
        guard case .success(let scan) = try await native.scanForIndexing(locator: locator) else {
            XCTFail("native CursorAdapter must parse the synthetic fixture")
            throw POSIXError(.EIO)
        }
        XCTAssertNil(scan.parseFailure)
        XCTAssertEqual(scan.info.source, .cursor)
        XCTAssertEqual(scan.messages.count, 2)
        XCTAssertEqual(scan.messages.map(\.role), [.user, .assistant])
        XCTAssertTrue(scan.messages.allSatisfy { $0.timestamp == nil && $0.usage == nil })
        return scan
    }

    func captureAndReplay(
        sessionID: String,
        before: IndexingScan
    ) async throws -> (
        session: CollectorCursorSource.ModernSession,
        capture: CollectorCursorSource.ModernCapture
    ) {
        let discovered = try CollectorCursorSource.discoverModern(rootPath: cursorRoot.path)
        let session = try XCTUnwrap(discovered.first { $0.nativeSessionID.utf8.elementsEqual(sessionID.utf8) })
        XCTAssertEqual(discovered.count, 1)

        let expectedPaths = session.present.map(\.relativePath).filter { path in
            !path.hasSuffix("-shm") && !path.hasSuffix("-journal")
        }
        var originals: [String: Data] = [:]
        for relative in expectedPaths {
            originals[relative] = try Data(contentsOf: cursorRoot.appendingPathComponent(relative))
        }
        let mainSize = Int64(originals[session.storeRelativePath ?? ""]?.count ?? 0)
        let transcriptSize = Int64(originals[session.transcriptRelativePath ?? ""]?.count ?? 0)
        XCTAssertEqual(before.info.sizeBytes, mainSize + transcriptSize)

        let capture = try CollectorCursorSource.captureModern(
            rootPath: cursorRoot.path,
            session: session,
            stagingParent: captureStaging
        )
        XCTAssertEqual(capture.session, session)
        XCTAssertEqual(Set(capture.files.map(\.relativePath)), Set(expectedPaths))
        XCTAssertFalse(capture.files.contains { $0.relativePath.hasSuffix("-shm") || $0.relativePath.hasSuffix("-journal") })
        XCTAssertFalse(capture.files.contains { $0.relativePath.hasSuffix("notes.txt") })
        XCTAssertFalse(session.present.contains { $0.relativePath.hasSuffix("-journal") })
        if let store = session.storeRelativePath {
            XCTAssertFalse(fm.fileExists(atPath: cursorRoot.appendingPathComponent(store + "-journal").path))
            let shm = cursorRoot.appendingPathComponent(store + "-shm")
            if fm.fileExists(atPath: shm.path) {
                XCTAssertTrue(session.present.contains { $0.relativePath.utf8.elementsEqual((store + "-shm").utf8) })
                XCTAssertFalse(capture.files.contains { $0.relativePath.hasSuffix("-shm") })
            }
        }
        for file in capture.files {
            XCTAssertEqual(file.bytes, originals[file.relativePath])
            XCTAssertEqual(file.generation, session.present.first { $0.relativePath.utf8.elementsEqual(file.relativePath.utf8) }?.generation)
            XCTAssertEqual(try Data(contentsOf: cursorRoot.appendingPathComponent(file.relativePath)), file.bytes)
            XCTAssertNil(file.bytes.range(of: Data("SECRET".utf8)))
        }

        closeLiveStores()
        try fm.removeItem(at: cursorRoot)
        XCTAssertFalse(fm.fileExists(atPath: cursorRoot.path))

        XCTAssertEqual(capture.rootPath, cursorRoot.path)
        let machineID = "11111111-2222-3333-4444-555555555555"
        let archiveRoot = base.appendingPathComponent("archive")
        let cas = try EngramCollectorCore.ImmutableArchiveCAS(root: archiveRoot)
        let catalog = try EngramCollectorCore.ArchiveCatalog(root: archiveRoot, machineID: machineID)
        try catalog.migrate()
        defer { try? catalog.close() }
        // Persistence happens after deleting every original input.
        let archived = try CollectorCursorSource.persistModern(capture, machineID: machineID, cas: cas, catalog: catalog)
        XCTAssertEqual(archived.manifest.schemaVersion, 2)
        XCTAssertTrue(EngramCollectorCore.ArchiveSourceDescriptor.isCursorModernFileSet(archived.manifest))
        let primaryPath = try XCTUnwrap(session.transcriptRelativePath ?? session.storeRelativePath)
        XCTAssertEqual(archived.manifest.locator, cursorRoot.appendingPathComponent(primaryPath).path)
        XCTAssertEqual(archived.manifest.generation, session.present.first { $0.relativePath == primaryPath }?.generation)
        try catalog.close()
        let reopenedCAS = try EngramCollectorCore.ImmutableArchiveCAS(root: archiveRoot)
        let reopened = try EngramCollectorCore.ArchiveCatalog(root: archiveRoot, machineID: machineID)
        try reopened.migrate()
        defer { try? reopened.close() }
        let saved = try XCTUnwrap(try reopened.capture(captureID: archived.manifest.captureID))
        let manifestBytes = try reopenedCAS.readManifest(sha256: saved.unboundManifestSHA256)
        XCTAssertEqual(manifestBytes, saved.unboundManifestBytes)
        let manifest = try EngramCollectorCore.ArchiveCanonicalJSON.decode(
            EngramCollectorCore.ArchiveSourceManifest.self, from: manifestBytes)
        let payload = try manifest.chunks.reduce(into: Data()) { bytes, chunk in
            bytes.append(try reopenedCAS.readObject(sha256: chunk.rawSHA256))
        }
        XCTAssertEqual(manifest.rawByteCount, Int64(payload.count))
        XCTAssertEqual(EngramCollectorCore.ArchiveV2Hash.sha256(payload), manifest.wholeSourceSHA256)
        let files = try XCTUnwrap(manifest.replayLayout.files)
        XCTAssertEqual(Set(files.map(\.relativePath)), Set(expectedPaths))
        for file in files {
            let bytes = payload.subdata(in: Int(file.byteOffset)..<Int(file.byteOffset + file.rawByteCount))
            XCTAssertEqual(bytes, originals[file.relativePath])
            XCTAssertEqual(EngramCollectorCore.ArchiveV2Hash.sha256(bytes), file.wholeSourceSHA256)
            XCTAssertEqual(file.generation, session.present.first { $0.relativePath == file.relativePath }?.generation)
            let dest = replayStage.appendingPathComponent(file.relativePath)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: dest)
            try setMtime(path: dest.path, nanoseconds: file.generation.mtimeNs, preserveAtime: false)
            XCTAssertEqual(try Data(contentsOf: dest), bytes)
        }

        var after = try await scanNative(root: replayStage)
        after.info.filePath = before.info.filePath
        XCTAssertEqual(after.info, before.info)
        XCTAssertEqual(after.messages, before.messages)
        XCTAssertNil(after.parseFailure)
        // HQ reconstructs bytes with fresh filesystem timestamps. Captured
        // metadata must retain native time semantics without original inputs.
        let physicalPrimary = replayStage.appendingPathComponent(primaryPath)
        try setMtime(path: physicalPrimary.path, nanoseconds: 1_900_000_000_000_000_000, preserveAtime: true)
        let replayManifest = try EngramCoreRead.ArchiveCanonicalJSON.decode(
            EngramCoreRead.ArchiveSourceManifest.self, from: manifestBytes)
        let factoryResult = try await SessionAdapterFactory.scanCapturedSource(
            physicalLocator: physicalPrimary.path, stagingRoot: replayStage.path,
            logicalLocator: manifest.locator, format: .cursor,
            capturedModificationNanoseconds: manifest.generation.mtimeNs,
            capturedReplayLayout: replayManifest.replayLayout)
        guard case .success(let capturedScan) = factoryResult else {
            XCTFail("HQ factory must replay only the captured modern Cursor layout: \(factoryResult)")
            throw POSIXError(.EIO)
        }
        XCTAssertEqual(capturedScan.rawSourceSessionID, sessionID)
        XCTAssertEqual(capturedScan.scan.info.filePath, manifest.locator)
        var capturedInfo = capturedScan.scan.info
        capturedInfo.filePath = before.info.filePath
        XCTAssertEqual(capturedInfo, before.info)
        XCTAssertEqual(capturedScan.scan.messages, before.messages)
        XCTAssertNil(capturedScan.scan.parseFailure)
        let hqWriter = try EngramCoreWrite.EngramDatabaseWriter(path: base.appendingPathComponent("hq-index.sqlite").path)
        try hqWriter.migrate()
        let instance = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
        let epoch = "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"
        let binding = try hqWriter.write { db in
            try EngramCoreWrite.CaptureIngestSourceRegistry.provision(db, machineID: machineID,
                sourceInstanceID: instance, source: .cursor, parseFormat: .cursor,
                configuredRoot: cursorRoot.path, initialEpoch: epoch)
        }
        let publication = try EngramCoreRead.CollectorPublicationEnvelope(machineID: machineID,
            sourceInstanceID: instance, collectorEpoch: epoch, sequence: 1,
            manifestSHA256: saved.unboundManifestSHA256)
        XCTAssertEqual(try hqWriter.read { db in
            try EngramCoreWrite.CaptureIngestSourceRegistry.eligibility(db,
                publication: publication, verifiedManifest: replayManifest)
        }, .eligible(binding))
        let hqCAS = try EngramCoreWrite.ImmutableArchiveCAS(root: archiveRoot)
        let hqStage = base.appendingPathComponent("hq-stage")
        try fm.createDirectory(at: hqStage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let hqReplay = try await EngramCoreWrite.CaptureIngestReplay.replay(publication: publication,
            bindingSnapshot: binding, cas: hqCAS, stagingParent: hqStage)
        var hqInfo = hqReplay.scan.info
        XCTAssertEqual(hqInfo.filePath, manifest.locator)
        hqInfo.filePath = before.info.filePath
        XCTAssertEqual(hqInfo, before.info)
        XCTAssertEqual(hqReplay.scan.messages, before.messages)
        XCTAssertEqual(hqReplay.rawSourceSessionID, sessionID)
        XCTAssertEqual(hqReplay.nativeIdentity.nativeID, sessionID)
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: hqStage.path).isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: cursorRoot.path))
        if let absentMeta = replayManifest.replayLayout.absentRelativePaths?.first(where: { $0.hasSuffix("/meta.json") }) {
            let unboundMeta = replayStage.appendingPathComponent(absentMeta)
            try Data(#"{"cwd":"/unbound/metadata","title":"must not enter HQ"}"#.utf8).write(to: unboundMeta)
            let unbound = try await SessionAdapterFactory.scanCapturedSource(
                physicalLocator: physicalPrimary.path, stagingRoot: replayStage.path,
                logicalLocator: manifest.locator, format: .cursor,
                capturedModificationNanoseconds: manifest.generation.mtimeNs,
                capturedReplayLayout: replayManifest.replayLayout)
            guard case .failure(.malformedJSON) = unbound else {
                XCTFail("An unbound stage metadata file must not alter the captured session")
                throw POSIXError(.EIO)
            }
            try fm.removeItem(at: unboundMeta)
        }
        XCTAssertFalse(fm.fileExists(atPath: missingLegacyDB.path))
        return (session, capture)
    }

    enum Journal {
        case walCheckpointed
        case walUncheckpointed
        case delete
    }

    @discardableResult
    func writeStore(
        workspace: String,
        id: String,
        journal: Journal,
        blobs: [(String, String)],
        metadata: [String: Any]?
    ) throws -> URL {
        let url = cursorRoot.appendingPathComponent(storeRelative(workspace: workspace, id: id))
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let handle = database else {
            sqlite3_close(database)
            throw POSIXError(.EIO)
        }
        var adopted = false
        defer {
            if !adopted {
                sqlite3_close(handle)
            }
        }
        func sql(_ text: String) throws {
            guard sqlite3_exec(handle, text, nil, nil, nil) == SQLITE_OK else { throw POSIXError(.EIO) }
        }
        switch journal {
        case .walCheckpointed, .walUncheckpointed:
            try sql("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;")
        case .delete:
            try sql("PRAGMA journal_mode=DELETE;")
        }
        try sql("CREATE TABLE blobs (id TEXT PRIMARY KEY, data BLOB); CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);")
        if journal != .delete {
            try sql("PRAGMA wal_checkpoint(TRUNCATE);")
        }
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
        if journal == .walCheckpointed {
            try sql("PRAGMA wal_checkpoint(TRUNCATE);")
        }
        liveStores.append(handle)
        adopted = true
        return url
    }

    func updateStoredCWD(_ cwd: String, hex: Bool) throws {
        let handle = try XCTUnwrap(liveStores.last)
        let bytes = try JSONSerialization.data(withJSONObject: ["cwd": cwd], options: [.sortedKeys, .withoutEscapingSlashes])
        let value = hex ? bytes.map { String(format: "%02x", $0) }.joined() : String(decoding: bytes, as: UTF8.self)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "UPDATE meta SET value = ? WHERE key = '0'", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw NSError(domain: "CursorReplayFixture", code: 1) }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, value, -1, transient) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else { throw NSError(domain: "CursorReplayFixture", code: 2) }
    }

    @discardableResult
    func writeTranscript(project: String, id: String, rows: [String]) throws -> URL {
        let url = cursorRoot.appendingPathComponent(transcriptRelative(project: project, id: id))
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data()
        for row in rows {
            data.append(Data(row.utf8))
            data.append(10)
        }
        try data.write(to: url)
        return url
    }

    func writeFile(_ url: URL, _ body: Data) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: url)
    }

    func plantUnrelatedNotes(nextToStore store: URL?, nextToTranscript transcript: URL?) throws {
        if let store {
            try writeFile(store.deletingLastPathComponent().appendingPathComponent("notes.txt"), Data("UNRELATED-SECRET".utf8))
        }
        if let transcript {
            try writeFile(transcript.deletingLastPathComponent().appendingPathComponent("notes.txt"), Data("UNRELATED-SECRET".utf8))
        }
    }

    func freezePayloadMtimes(store: URL, extras: [URL]) throws {
        var stamp = Int64(1_788_825_600_000_000_101)
        try setMtime(path: store.path, nanoseconds: stamp, preserveAtime: true)
        for extra in extras where fm.fileExists(atPath: extra.path) {
            stamp += 1_000
            try setMtime(path: extra.path, nanoseconds: stamp, preserveAtime: true)
        }
    }

    func setMtime(path: String, nanoseconds: Int64, preserveAtime: Bool) throws {
        let mtime = timespec(
            tv_sec: numericCast(nanoseconds / 1_000_000_000),
            tv_nsec: numericCast(nanoseconds % 1_000_000_000)
        )
        var atime = mtime
        if preserveAtime {
            var info = stat()
            guard lstat(path, &info) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            atime = info.st_atimespec
        }
        var times = [atime, mtime]
        guard Darwin.utimensat(AT_FDCWD, path, &times, 0) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
