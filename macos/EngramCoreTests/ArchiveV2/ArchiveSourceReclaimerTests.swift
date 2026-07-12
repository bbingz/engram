import Darwin
import EngramCoreRead
import Foundation
@testable import EngramCoreWrite
import XCTest

final class ArchiveSourceReclaimerTests: XCTestCase {
    private enum Marker: Error { case crash, fsync }
    private let machineID = "11111111-2222-4333-8444-555555555555"
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-source-reclaimer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testPlanIsDurableBeforeRenameAndSuccessfulUnlinkRecordsReleasedBytes() throws {
        let fixture = try makeFixture(name: "success", bytes: Data("old transcript".utf8))
        let reclaimer = ArchiveSourceReclaimer(
            catalog: fixture.catalog,
            testHooks: ArchiveSourceReclaimerTestHooks(afterPlan: { quarantineURL in
                XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: quarantineURL.path))
                let persisted = try XCTUnwrap(
                    fixture.catalog.reclamationIntent(manifestSHA256: fixture.intent.manifestSHA256)
                )
                XCTAssertEqual(persisted.phase, .quarantinePlanned)
                XCTAssertEqual(persisted.quarantinePath, quarantineURL.path)
            })
        )

        let result = try reclaimer.planAndReclaim(intent: fixture.intent, capture: fixture.capture)

        XCTAssertEqual(result.releasedBytes, Int64(fixture.bytes.count))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
        let deleted = try XCTUnwrap(
            fixture.catalog.reclamationIntent(manifestSHA256: fixture.intent.manifestSHA256)
        )
        XCTAssertEqual(deleted.phase, .sourceDeleted)
        XCTAssertEqual(deleted.releasedSourceBytes, Int64(fixture.bytes.count))
        XCTAssertNotNil(deleted.quarantinePath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(deleted.quarantinePath)))
    }

    func testRecoveryHandlesCrashBeforeAndAfterRename() throws {
        let before = try makeFixture(name: "crash-before", bytes: Data("before rename".utf8))
        let beforeReclaimer = ArchiveSourceReclaimer(
            catalog: before.catalog,
            testHooks: ArchiveSourceReclaimerTestHooks(afterPlan: { _ in throw Marker.crash })
        )
        XCTAssertThrowsError(
            try beforeReclaimer.planAndReclaim(intent: before.intent, capture: before.capture)
        )
        let beforePlanned = try XCTUnwrap(
            before.catalog.reclamationIntent(manifestSHA256: before.intent.manifestSHA256)
        )
        XCTAssertEqual(beforePlanned.phase, .quarantinePlanned)
        XCTAssertTrue(FileManager.default.fileExists(atPath: before.sourceURL.path))
        _ = try ArchiveSourceReclaimer(catalog: before.catalog).recover(
            intent: beforePlanned,
            capture: before.capture
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: before.sourceURL.path))

        let after = try makeFixture(name: "crash-after", bytes: Data("after rename".utf8))
        let afterReclaimer = ArchiveSourceReclaimer(
            catalog: after.catalog,
            testHooks: ArchiveSourceReclaimerTestHooks(afterRename: { _ in throw Marker.crash })
        )
        XCTAssertThrowsError(
            try afterReclaimer.planAndReclaim(intent: after.intent, capture: after.capture)
        )
        let afterPlanned = try XCTUnwrap(
            after.catalog.reclamationIntent(manifestSHA256: after.intent.manifestSHA256)
        )
        XCTAssertEqual(afterPlanned.phase, .quarantinePlanned)
        XCTAssertFalse(FileManager.default.fileExists(atPath: after.sourceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(afterPlanned.quarantinePath)))
        _ = try ArchiveSourceReclaimer(catalog: after.catalog).recover(
            intent: afterPlanned,
            capture: after.capture
        )
        XCTAssertEqual(
            try after.catalog.reclamationIntent(manifestSHA256: after.intent.manifestSHA256)?.phase,
            .sourceDeleted
        )
    }

    func testPostRenameMismatchRestoresOnlyWhenOriginalPathIsFree() throws {
        let restored = try makeFixture(name: "restore", bytes: Data("expected bytes".utf8))
        let restoreReclaimer = ArchiveSourceReclaimer(
            catalog: restored.catalog,
            testHooks: ArchiveSourceReclaimerTestHooks(afterRename: { quarantineURL in
                try Data("changed bytes!".utf8).write(to: quarantineURL)
            })
        )
        XCTAssertThrowsError(
            try restoreReclaimer.planAndReclaim(intent: restored.intent, capture: restored.capture)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: restored.sourceURL.path))
        let restoredIntent = try XCTUnwrap(
            restored.catalog.reclamationIntent(manifestSHA256: restored.intent.manifestSHA256)
        )
        XCTAssertEqual(restoredIntent.phase, .paused)
        XCTAssertEqual(restoredIntent.lastError, "generation_changed")

        let collision = try makeFixture(name: "collision", bytes: Data("expected collision".utf8))
        let replacement = Data("new user file".utf8)
        let collisionReclaimer = ArchiveSourceReclaimer(
            catalog: collision.catalog,
            testHooks: ArchiveSourceReclaimerTestHooks(afterRename: { quarantineURL in
                try Data("corrupt collision".utf8).write(to: quarantineURL)
                try replacement.write(to: collision.sourceURL)
            })
        )
        XCTAssertThrowsError(
            try collisionReclaimer.planAndReclaim(intent: collision.intent, capture: collision.capture)
        )
        XCTAssertEqual(try Data(contentsOf: collision.sourceURL), replacement)
        let collisionIntent = try XCTUnwrap(
            collision.catalog.reclamationIntent(manifestSHA256: collision.intent.manifestSHA256)
        )
        XCTAssertEqual(collisionIntent.phase, .paused)
        XCTAssertEqual(collisionIntent.lastError, "quarantine_collision")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(collisionIntent.quarantinePath)))
    }

    func testSymlinkOversizeCancellationAndDirectorySyncFailureNeverDeleteSource() throws {
        let symlink = try makeFixture(name: "symlink", bytes: Data("symlink target".utf8))
        let target = symlink.sourceURL.deletingLastPathComponent().appendingPathComponent("target.jsonl")
        try FileManager.default.moveItem(at: symlink.sourceURL, to: target)
        try FileManager.default.createSymbolicLink(at: symlink.sourceURL, withDestinationURL: target)
        XCTAssertThrowsError(
            try ArchiveSourceReclaimer(catalog: symlink.catalog).planAndReclaim(
                intent: symlink.intent,
                capture: symlink.capture
            )
        )
        var info = stat()
        XCTAssertEqual(Darwin.lstat(symlink.sourceURL.path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFLNK)

        let oversized = try makeFixture(name: "oversized", bytes: Data("small".utf8))
        let oversizedCapture = ArchiveCapture(
            captureID: oversized.capture.captureID,
            machineID: oversized.capture.machineID,
            source: oversized.capture.source,
            locator: oversized.capture.locator,
            generation: oversized.capture.generation,
            wholeSourceSHA256: oversized.capture.wholeSourceSHA256,
            rawByteCount: ArchiveSourceReclaimer.maximumSourceBytes + 1,
            chunkSize: oversized.capture.chunkSize,
            unboundManifestSHA256: oversized.capture.unboundManifestSHA256,
            unboundManifestBytes: oversized.capture.unboundManifestBytes,
            status: oversized.capture.status,
            diagnostic: oversized.capture.diagnostic,
            capturedAt: oversized.capture.capturedAt
        )
        XCTAssertThrowsError(
            try ArchiveSourceReclaimer(catalog: oversized.catalog).planAndReclaim(
                intent: oversized.intent,
                capture: oversizedCapture
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: oversized.sourceURL.path))
        XCTAssertEqual(
            try oversized.catalog.reclamationIntent(manifestSHA256: oversized.intent.manifestSHA256)?.lastError,
            "source_too_large"
        )

        let cancelled = try makeFixture(name: "cancelled", bytes: Data("cancel me".utf8))
        XCTAssertThrowsError(
            try ArchiveSourceReclaimer(
                catalog: cancelled.catalog,
                testHooks: ArchiveSourceReclaimerTestHooks(afterPlan: { _ in throw CancellationError() })
            ).planAndReclaim(intent: cancelled.intent, capture: cancelled.capture)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: cancelled.sourceURL.path))
        XCTAssertEqual(
            try cancelled.catalog.reclamationIntent(manifestSHA256: cancelled.intent.manifestSHA256)?.phase,
            .quarantinePlanned
        )

        let syncFailure = try makeFixture(name: "sync-failure", bytes: Data("sync me".utf8))
        XCTAssertThrowsError(
            try ArchiveSourceReclaimer(
                catalog: syncFailure.catalog,
                testHooks: ArchiveSourceReclaimerTestHooks(fsyncDirectory: { _ in throw Marker.fsync })
            ).planAndReclaim(intent: syncFailure.intent, capture: syncFailure.capture)
        )
        let planned = try XCTUnwrap(
            syncFailure.catalog.reclamationIntent(manifestSHA256: syncFailure.intent.manifestSHA256)
        )
        XCTAssertEqual(planned.phase, .quarantinePlanned)
        XCTAssertFalse(FileManager.default.fileExists(atPath: syncFailure.sourceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(planned.quarantinePath)))
    }

    private struct Fixture: @unchecked Sendable {
        let catalog: ArchiveCatalog
        let sourceURL: URL
        let bytes: Data
        let capture: ArchiveCapture
        let intent: ArchiveReclamationIntent
    }

    private func makeFixture(name: String, bytes: Data) throws -> Fixture {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("session.jsonl")
        try bytes.write(to: sourceURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sourceURL.path)
        var info = stat()
        XCTAssertEqual(Darwin.lstat(sourceURL.path, &info), 0)
        let generation = try ArchiveSourceGeneration(
            device: Int64(info.st_dev),
            inode: Int64(info.st_ino),
            size: Int64(info.st_size),
            mtimeNs: nanoseconds(info.st_mtimespec),
            ctimeNs: nanoseconds(info.st_ctimespec),
            mode: Int64(info.st_mode)
        )
        let captureID = ArchiveV2Hash.sha256(Data("capture-\(name)".utf8))
        let objectSHA = ArchiveV2Hash.sha256(bytes)
        let unbound = try ArchiveSourceManifest(
            captureID: captureID,
            machineID: machineID,
            source: "claude-code",
            locator: sourceURL.path,
            sessionID: nil,
            capturedAt: "2026-07-12T00:00:00.000Z",
            generation: generation,
            wholeSourceSHA256: objectSHA,
            rawByteCount: Int64(bytes.count),
            chunks: [try ArchiveChunkReference(ordinal: 0, rawSHA256: objectSHA, rawByteCount: Int64(bytes.count))],
            replayLayout: try ArchiveReplayLayout(strategy: .singleFile, relativePaths: ["session.jsonl"])
        )
        let archiveRoot = directory.appendingPathComponent("archive", isDirectory: true)
        let catalog = try ArchiveCatalog(root: archiveRoot, machineID: machineID)
        try catalog.migrate()
        let recorded = try catalog.recordCapture(
            canonicalManifestBytes: ArchiveCanonicalJSON.encode(unbound)
        )
        let bound = try ArchiveSourceManifest(
            captureID: captureID,
            machineID: machineID,
            source: "claude-code",
            locator: sourceURL.path,
            sessionID: "session-\(name)",
            capturedAt: unbound.capturedAt,
            generation: generation,
            wholeSourceSHA256: objectSHA,
            rawByteCount: Int64(bytes.count),
            chunks: unbound.chunks,
            replayLayout: unbound.replayLayout
        )
        let binding = try catalog.bind(
            canonicalManifestBytes: ArchiveCanonicalJSON.encode(bound),
            sourceSnapshotFingerprint: ArchiveV2Hash.sha256(Data("snapshot-\(name)".utf8)),
            boundAt: "2026-07-12T00:01:00.000Z"
        )
        let intent = try catalog.upsertReclamationIntent(
            manifestSHA256: binding.manifestSHA256,
            captureID: binding.captureID,
            sessionID: binding.sessionID,
            locator: sourceURL.path,
            updatedAt: "2026-07-12T00:02:00.000Z"
        )
        return Fixture(
            catalog: catalog,
            sourceURL: sourceURL,
            bytes: bytes,
            capture: recorded,
            intent: intent
        )
    }

    private func nanoseconds(_ value: timespec) -> Int64 {
        Int64(value.tv_sec) * 1_000_000_000 + Int64(value.tv_nsec)
    }
}
