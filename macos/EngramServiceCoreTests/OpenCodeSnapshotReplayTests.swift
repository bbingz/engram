import Darwin
import Foundation
import SQLite3
import XCTest
@testable import EngramCollectorCore
@testable import EngramCoreRead
@testable import EngramCoreWrite

final class OpenCodeSnapshotReplayTests: XCTestCase {
    func testScopedImageReplaysThroughNativeAdapterAfterOriginalDatabaseRemoval() async throws {
        try await verifyReplay(throughArchive: false)
    }

    func testScopedImageCASRoundTripPreservesNativeReplayAfterOriginalDatabaseRemoval() async throws {
        try await verifyReplay(throughArchive: true)
    }

    func testCollectorSnapshotCASReplaysThroughHQPipelineWithoutOriginalDatabase() async throws {
        try await verifyReplay(throughArchive: true, throughHQ: true)
    }

    private func verifyReplay(throughArchive: Bool, throughHQ: Bool = false) async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("opencode-native-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        let physical = try XCTUnwrap(realpath(temporary.path, nil))
        defer { free(physical) }
        let base = URL(fileURLWithPath: String(cString: physical))
        defer { try? FileManager.default.removeItem(at: base) }
        let sourceRoot = base.appendingPathComponent("source")
        let staging = base.appendingPathComponent("staging")
        for directory in [sourceRoot, staging] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        }
        let source = sourceRoot.appendingPathComponent("opencode.db")
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.path, &writer), SQLITE_OK)
        defer { if let writer { sqlite3_close(writer) } }
        let handle = try XCTUnwrap(writer)
        func sql(_ text: String) throws {
            guard sqlite3_exec(handle, text, nil, nil, nil) == SQLITE_OK else { throw POSIXError(.EIO) }
        }
        try sql("""
            PRAGMA journal_mode=WAL;
            PRAGMA wal_autocheckpoint=0;
            CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT, slug TEXT, agent TEXT,
                directory TEXT, title TEXT, time_created INTEGER, time_updated INTEGER, time_archived INTEGER);
            CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT);
            CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, time_created INTEGER, data TEXT);
            PRAGMA wal_checkpoint(TRUNCATE);
            BEGIN;
            INSERT INTO session VALUES ('ses-native', 'parent-native', 'task-reader', 'explore', '/offline/native-project',
                'Native question (@explore subagent)', 1788825600000, 1788825602000, NULL);
            INSERT INTO session (id,directory,title) VALUES ('ses-private','/private/project','SIBLING-SECRET');
            INSERT INTO message VALUES ('m-user','ses-native',1788825601000,'{"role":"user"}');
            INSERT INTO message VALUES ('m-answer','ses-native',1788825602000,
                '{"role":"assistant","tokens":{"input":96,"output":10,"reasoning":2,"cache":{"read":4,"write":3}}}');
            INSERT INTO part VALUES ('p-user','m-user',1788825601000,'{"type":"text","text":"原生问题"}');
            INSERT INTO part VALUES ('p-answer','m-answer',1788825602000,'{"type":"text","text":"Native answer"}');
            INSERT INTO part VALUES ('p-tool','m-answer',1788825602001,'{"type":"tool","state":{"input":"keep raw tool"}}');
            COMMIT;
            """)
        let logical = source.path + "::ses-native"
        let native = OpenCodeAdapter(dbPath: source.path)
        guard case .success(let before) = try await native.scanForIndexing(locator: logical) else {
            return XCTFail("the real native fixture must parse before export")
        }
        let snapshot = try CollectorOpenCodeSource.snapshot(root: sourceRoot, sessionID: "ses-native", stagingParent: staging)
        XCTAssertNil(snapshot.image.range(of: Data("SIBLING-SECRET".utf8)))
        XCTAssertEqual(snapshot.nativePayloadByteCount, before.info.sizeBytes)
        sqlite3_close(handle)
        writer = nil
        try FileManager.default.removeItem(at: sourceRoot)
        let image = staging.appendingPathComponent("session.sqlite")
        if throughArchive {
            let archive = base.appendingPathComponent("archive")
            let machineID = "11111111-2222-3333-4444-555555555555"
            let cas = try EngramCollectorCore.ImmutableArchiveCAS(root: archive)
            let catalog = try EngramCollectorCore.ArchiveCatalog(root: archive, machineID: machineID)
            try catalog.migrate()
            defer { try? catalog.close() }
            let context = try EngramCollectorCore.ArchiveSQLiteSessionContext(
                databaseLocator: source.path, nativeSessionID: snapshot.sessionID,
                nativePayloadByteCount: snapshot.nativePayloadByteCount, walGeneration: snapshot.walGeneration)
            let capture = try EngramCollectorCore.ExactSourceCapturer.captureSQLiteSessionImage(
                snapshot.image, context: context, generation: snapshot.databaseGeneration,
                machineID: machineID, cas: cas, catalog: catalog)
            XCTAssertEqual(capture.manifest.schemaVersion, 4)
            XCTAssertEqual(capture.manifest.locator, logical)
            XCTAssertEqual(capture.manifest.replayLayout.sqliteSession, context)
            let restored = try capture.manifest.chunks.reduce(into: Data()) { bytes, chunk in
                bytes.append(try cas.readObject(sha256: chunk.rawSHA256))
            }
            XCTAssertEqual(restored, snapshot.image)
            if throughHQ {
                let format = try XCTUnwrap(EngramCoreWrite.CaptureIngestParseFormat(rawValue: "opencode"))
                let hqWriter = try EngramCoreWrite.EngramDatabaseWriter(path: base.appendingPathComponent("hq-index.sqlite").path)
                try hqWriter.migrate()
                let instance = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
                let epoch = "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"
                let binding = try hqWriter.write { db in
                    try EngramCoreWrite.CaptureIngestSourceRegistry.provision(db, machineID: machineID,
                        sourceInstanceID: instance, source: .opencode, parseFormat: format,
                        configuredRoot: sourceRoot.path, initialEpoch: epoch)
                }
                let publication = try EngramCoreRead.CollectorPublicationEnvelope(machineID: machineID,
                    sourceInstanceID: instance, collectorEpoch: epoch, sequence: 1,
                    manifestSHA256: capture.capture.unboundManifestSHA256)
                let hqCAS = try EngramCoreWrite.ImmutableArchiveCAS(root: archive)
                let replay = try await EngramCoreWrite.CaptureIngestReplay.replay(publication: publication,
                    bindingSnapshot: binding, cas: hqCAS, stagingParent: staging)
                XCTAssertEqual(replay.scan.info, before.info)
                XCTAssertEqual(replay.scan.messages, before.messages)
                XCTAssertEqual(replay.rawSourceSessionID, "ses-native")
                XCTAssertEqual(replay.verifiedManifest.replayLayout.sqliteSession?.nativePayloadByteCount, snapshot.nativePayloadByteCount)
                XCTAssertEqual(replay.parentIdentity, try replay.nativeIdentity.mapping(nativeID: "parent-native"))
                XCTAssertFalse(FileManager.default.fileExists(atPath: sourceRoot.path))
            }
            try restored.write(to: image)
        } else {
            try snapshot.image.write(to: image)
        }
        let adapter = OpenCodeAdapter(dbPath: image.path)
        let locators = try await adapter.listSessionLocators()
        XCTAssertEqual(locators, [image.path + "::ses-native"])
        guard case .success(var after) = try await adapter.scanForIndexing(locator: image.path + "::ses-native") else {
            return XCTFail("the scoped image must be sufficient without original files")
        }
        after.info.filePath = logical
        XCTAssertEqual(after.info, before.info)
        XCTAssertEqual(after.messages, before.messages)
        XCTAssertEqual(after.info.source, .opencode)
        XCTAssertEqual(after.info.parentSessionId, "parent-native")
        XCTAssertEqual(after.info.agentRole, "dispatched")
        XCTAssertEqual(after.messages.map(\.content), ["原生问题", "Native answer"])
        XCTAssertEqual(after.messages.last?.usage?.inputTokens, 96)
        XCTAssertEqual(after.messages.last?.usage?.outputTokens, 12)
        XCTAssertEqual(after.messages.last?.usage?.cacheReadTokens, 4)
        XCTAssertEqual(after.messages.last?.usage?.cacheCreationTokens, 3)
        XCTAssertNil(after.parseFailure)
    }
}
