import Darwin
import Foundation
import GRDB
import XCTest
@testable import EngramCollectorCore

final class CollectorCaptureCoreTests: XCTestCase {
    private let machineID = "11111111-2222-3333-4444-555555555555"
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-collector-capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    func testExplicitMachineIdentityAndUnboundExactBytesRoundTripWithoutProductIndex() throws {
        for source in [SourceName.claudeCode, .codex] {
            let storeRoot = root.appendingPathComponent("shadow-\(source.rawValue)")
            let sourceURL = root.appendingPathComponent("\(source.rawValue).jsonl")
            let bytes = Data([0xEF, 0xBB, 0xBF]) + Data("{\"fixture\":true}\r\n".utf8)
                + Data([0x00, 0xFF, 0xFE]) + Data("{\"partial\":".utf8)
            try bytes.write(to: sourceURL)
            let descriptor = try descriptor(sourceURL)
            let cas = try ImmutableArchiveCAS(root: storeRoot)
            var catalog: ArchiveCatalog? = try ArchiveCatalog(root: storeRoot, machineID: machineID)
            try catalog!.migrate()
            let result = try ExactSourceCapturer(cas: cas, catalog: catalog!, descriptor: descriptor)
                .capture(source: source, locator: sourceURL.path, machineID: machineID)

            XCTAssertNil(result.manifest.sessionID)
            XCTAssertEqual(result.manifest.machineID, machineID)
            XCTAssertEqual(result.manifest.source, source.rawValue)
            XCTAssertEqual(result.manifest.rawByteCount, Int64(bytes.count))
            XCTAssertEqual(result.manifest.wholeSourceSHA256, ArchiveV2Hash.sha256(bytes))
            XCTAssertEqual(try catalog!.unboundCaptures(limit: 10), [result.capture])
            let manifestBytes = try cas.readManifest(sha256: result.capture.unboundManifestSHA256)
            XCTAssertEqual(manifestBytes, result.capture.unboundManifestBytes)
            XCTAssertEqual(try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: manifestBytes), result.manifest)
            let restored = try result.manifest.chunks.reduce(into: Data()) { data, chunk in
                data.append(try cas.readObject(sha256: chunk.rawSHA256))
            }
            XCTAssertEqual(restored, bytes)
            XCTAssertEqual(try Data(contentsOf: sourceURL), bytes)

            catalog = nil
            let reopened = try ArchiveCatalog(root: storeRoot, machineID: machineID)
            try reopened.migrate()
            XCTAssertEqual(try reopened.machineID(), machineID)
            XCTAssertEqual(try reopened.capture(captureID: result.capture.captureID), result.capture)
            XCTAssertEqual(
                try ExactSourceCapturer(cas: cas, catalog: reopened, descriptor: descriptor)
                    .capture(source: source, locator: sourceURL.path, machineID: machineID), result
            )
            var configuration = Configuration()
            configuration.readonly = true
            let database = try DatabaseQueue(
                path: storeRoot.appendingPathComponent("archive.sqlite").path,
                configuration: configuration
            )
            let tables = try database.read { db in
                try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
            }
            XCTAssertFalse(tables.isEmpty)
            XCTAssertTrue(tables.allSatisfy { $0.hasPrefix("archive_") }, tables.description)
            XCTAssertFalse(FileManager.default.fileExists(atPath: storeRoot.appendingPathComponent("index.sqlite").path))
        }
    }

    func testCatalogRetainsExplicitIdentityAndCaptureRejectsMismatchedIdentity() throws {
        let sourceURL = root.appendingPathComponent("identity.jsonl")
        try Data("fixture".utf8).write(to: sourceURL)
        let (cas, catalog) = try makeStore()
        let capturer = ExactSourceCapturer(cas: cas, catalog: catalog, descriptor: try descriptor(sourceURL))
        let otherMachineID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        XCTAssertThrowsError(try capturer.capture(source: .codex, locator: sourceURL.path, machineID: otherMachineID)) { error in
            XCTAssertEqual(error as? ExactSourceCapturerError, .machineIDMismatch(expected: self.machineID, actual: otherMachineID))
        }
        XCTAssertEqual(try catalog.machineID(), machineID)
        XCTAssertTrue(try catalog.unboundCaptures(limit: 10).isEmpty)
    }

    func testPhysicalDescriptorClassificationRejectsUnsafeAndCompositeSources() throws {
        let sourceURL = root.appendingPathComponent("source.jsonl")
        try Data("fixture".utf8).write(to: sourceURL)
        let symlink = root.appendingPathComponent("linked.jsonl")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: sourceURL)
        let fifo = root.appendingPathComponent("pipe.jsonl")
        XCTAssertEqual(mkfifo(fifo.path, S_IRUSR | S_IWUSR), 0)
        let directory = root.appendingPathComponent("directory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let missing = root.appendingPathComponent("missing.jsonl")
        XCTAssertEqual(classify(try descriptor(sourceURL)), .declaredSingleFile(sourceURL.standardizedFileURL))
        XCTAssertEqual(classify(try descriptor(missing)), .missing)
        XCTAssertEqual(classify(try descriptor(directory)), .unsupportedComposite)
        for unsafe in [symlink, fifo] {
            guard case .unsafe = classify(try descriptor(unsafe)) else {
                return XCTFail("unsafe source was accepted: \(unsafe.lastPathComponent)")
            }
        }
        let mismatch = try ArchiveSourceDescriptor(
            locator: sourceURL.path,
            files: [ArchiveSourceFileDescriptor(sourceURL: missing, replayRelativePath: "missing.jsonl")]
        )
        guard case .unsafe = classify(mismatch) else { return XCTFail("mismatched descriptor was accepted") }
        let composite = try ArchiveSourceDescriptor(
            locator: sourceURL.path,
            files: [
                ArchiveSourceFileDescriptor(sourceURL: sourceURL, replayRelativePath: "source.jsonl"),
                ArchiveSourceFileDescriptor(sourceURL: missing, replayRelativePath: "missing.jsonl"),
            ]
        )
        XCTAssertEqual(classify(composite), .unsupportedComposite)
    }

    func testMutableSourceStillPublishesNoCaptureAndDiscardsStaging() throws {
        let sourceURL = root.appendingPathComponent("mutable.jsonl")
        try Data("before".utf8).write(to: sourceURL)
        let (cas, catalog) = try makeStore()
        let capturer = ExactSourceCapturer(
            cas: cas, catalog: catalog, descriptor: try descriptor(sourceURL),
            testHooks: ExactSourceCapturerTestHooks(afterStreamingBeforeFinalStat: { url in
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(" changed".utf8))
            })
        )
        XCTAssertThrowsError(try capturer.capture(source: .codex, locator: sourceURL.path, machineID: machineID)) { error in
            XCTAssertEqual(error as? ExactSourceCapturerError, .generationChanged)
        }
        XCTAssertTrue(try catalog.unboundCaptures(limit: 10).isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: storeRoot.appendingPathComponent("tmp").path).isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: storeRoot.appendingPathComponent("manifests/sha256").path).isEmpty)
    }

    func testCancellationStillStopsBeforeCapture() async throws {
        let sourceURL = root.appendingPathComponent("cancelled.jsonl")
        try Data("fixture".utf8).write(to: sourceURL)
        let (cas, catalog) = try makeStore()
        let capturer = ExactSourceCapturer(cas: cas, catalog: catalog, descriptor: try descriptor(sourceURL))
        let fixtureMachineID = machineID
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try capturer.capture(source: .codex, locator: sourceURL.path, machineID: fixtureMachineID)
        }
        do {
            _ = try await task.value
            XCTFail("cancelled capture succeeded")
        } catch {
            XCTAssertTrue(error is CancellationError, String(describing: error))
        }
        XCTAssertTrue(try catalog.unboundCaptures(limit: 10).isEmpty)
    }

    func testExtractedSQLiteDefaultsRetainExistingValues() {
        XCTAssertEqual(SQLiteBusyDefaults.busyTimeoutMilliseconds, 30_000)
        XCTAssertEqual(SQLiteBusyDefaults.walAutocheckpointPages, 1_000)
    }

    private var storeRoot: URL { root.appendingPathComponent("shadow") }

    private func makeStore() throws -> (ImmutableArchiveCAS, ArchiveCatalog) {
        let cas = try ImmutableArchiveCAS(root: storeRoot)
        let catalog = try ArchiveCatalog(root: storeRoot, machineID: machineID)
        try catalog.migrate()
        return (cas, catalog)
    }

    private func descriptor(_ sourceURL: URL) throws -> ArchiveSourceDescriptor {
        try .singleFile(locator: sourceURL.path, sourceURL: sourceURL, replayRelativePath: sourceURL.lastPathComponent)
    }

    private func classify(_ descriptor: ArchiveSourceDescriptor) -> ArchiveLocatorClassification {
        ArchiveLocatorClassifier.classify(descriptor: descriptor, enumeratedLocator: descriptor.locator)
    }
}
