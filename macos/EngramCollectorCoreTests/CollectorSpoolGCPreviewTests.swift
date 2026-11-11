import Darwin
import Foundation
import GRDB
import XCTest
@testable import EngramCollectorCore

final class CollectorSpoolGCPreviewTests: XCTestCase {
    func test1109EmptyLegacyKeepSetCannotAuthorizeDeletion_repro() throws {
        let f = try GCPreviewFixture(); defer { f.remove() }
        try f.add("old", bytes: "old", latest: false)
        try f.add("head", bytes: "head", latest: true)
        try f.finish()
        let r = try f.preview()
        XCTAssertEqual(r.captureCount, 2)
        XCTAssertEqual(r.presentBytes, 7)
        XCTAssertEqual(r.bytes("latest"), 4)
        XCTAssertEqual(r.bytes("proof_missing"), 3)
        XCTAssertEqual(r.potentialBytesBeforeProofAndEscrow, 3)
        XCTAssertEqual(r.actionableBytes, 0)
    }

    func testEmptyGraphAndEmptyKeepSetFailClosed_repro() throws {
        let f = try GCPreviewFixture(); defer { f.remove() }
        try f.finish()
        XCTAssertThrowsError(try f.preview())
        XCTAssertThrowsError(try CollectorSpoolGCPreview.validateKeepSet(graph: ["a"], keep: [], floor: []))
        XCTAssertThrowsError(try CollectorSpoolGCPreview.validateKeepSet(graph: ["a", "b"], keep: ["a"], floor: ["b"]))
    }

    func testMalformedManifestAbortsWholePlan_repro() throws {
        let f = try GCPreviewFixture(); defer { f.remove() }
        try f.add("head", bytes: "head", latest: true)
        try f.finish()
        try f.catalogSQL("UPDATE archive_captures SET unbound_manifest_bytes = X'7B7D'")
        XCTAssertThrowsError(try f.preview())
    }

    func testUnpublishedAndOldRevisionRemainInGraph_repro() throws {
        let f = try GCPreviewFixture(); defer { f.remove() }
        try f.add("head", bytes: "head", latest: true)
        try f.add("unpublished", bytes: "unpublished", published: false)
        try f.add("old-revision", bytes: "old-revision", revision: 2)
        try f.finish()
        let r = try f.preview()
        XCTAssertEqual(r.captureCount, 3)
        XCTAssertEqual(r.bytes("not_dual_acked"), 11)
        XCTAssertEqual(r.bytes("dirty_k6"), 12)
    }

    func testSharedChunkWithKeptCaptureIsPinned_repro() throws {
        let f = try GCPreviewFixture(); defer { f.remove() }
        try f.add("old", bytes: "shared")
        try f.add("head", bytes: "shared", latest: true)
        try f.finish()
        let r = try f.preview()
        XCTAssertEqual(r.presentBytes, 6)
        XCTAssertEqual(r.bytes("shared_pinned"), 6)
        XCTAssertEqual(r.potentialBytesBeforeProofAndEscrow, 0)
    }

    func testWithheldPendingInflightAndUnavailablePin_repro() throws {
        for (state, error, reason) in [("pending", "privacyWithheld", "withheld"),
                                      ("pending", "", "pending"), ("inflight", "", "inflight"),
                                      ("pending", "localContentUnavailable", "local_content_unavailable")] {
            let f = try GCPreviewFixture(); defer { f.remove() }
            try f.add("head", bytes: "head", latest: true)
            try f.add("old", bytes: "old", state: state, error: error)
            try f.finish()
            XCTAssertEqual(try f.preview().bytes(reason), 3, reason)
        }
    }

    func testDirtyK6AndLatestStayProtected_repro() throws {
        let f = try GCPreviewFixture(); defer { f.remove() }
        try f.add("head", bytes: "head", latest: true)
        try f.add("old", bytes: "old", dirty: true)
        try f.finish()
        let r = try f.preview()
        XCTAssertEqual(r.bytes("latest"), 4)
        XCTAssertEqual(r.bytes("dirty_k6"), 3)
    }

    func testACKWithoutCentralEvidenceBlocks_repro() throws {
        let f = try GCPreviewFixture(); defer { f.remove() }
        try f.add("head", bytes: "head", latest: true)
        try f.add("old", bytes: "old")
        try f.finish()
        let r = try f.preview(central: false)
        XCTAssertEqual(r.bytes("central_evidence_missing"), 3)
        XCTAssertEqual(r.potentialBytesBeforeProofAndEscrow, 0)
        XCTAssertTrue(r.blocked.contains("proof_missing"))
    }

    func testCentralParsedOtherAndDuplicateRemainProtected() throws {
        for (status, failure, reason) in [("parsed", "", "central_parsed_skip"),
                                          ("failed_retryable", "", "central_other"),
                                          ("quarantined", "quarantine.cross_machine_duplicate", "duplicate_unprovable")] {
            let f = try GCPreviewFixture(); defer { f.remove() }
            try f.add("head", bytes: "head", latest: true)
            try f.add("old", bytes: "old", centralStatus: status, centralFailure: failure)
            try f.finish()
            XCTAssertEqual(try f.preview().bytes(reason), 3)
        }
    }

    func testSharedDigestBudgetAccountingIsReportOnly_repro() throws {
        let f = try GCPreviewFixture(); defer { f.remove() }
        try f.add("head", bytes: "head", latest: true)
        try f.add("old-a", bytes: "shared")
        try f.add("old-b", bytes: "shared")
        try f.finish()
        let before = try f.snapshot()
        let r = try f.preview(maxBytes: 6, maxObjects: 1)
        XCTAssertEqual(r.potentialBytesBeforeProofAndEscrow, 6)
        XCTAssertEqual(r.budgetedPotentialBytes, 6)
        XCTAssertEqual(r.budgetedPotentialObjects, 1)
        XCTAssertEqual(try f.preview(maxBytes: 5).budgetedPotentialBytes, 0)
        XCTAssertEqual(try f.preview(maxObjects: 0).budgetedPotentialBytes, 0)
        XCTAssertEqual(try f.snapshot(), before)
    }

    func testPreviewNeverAcquiresOwnerLockOrWritesFiles_repro() throws {
        let f = try GCPreviewFixture(); defer { f.remove() }
        try f.add("head", bytes: "head", latest: true)
        try f.finish()
        let lock = open(f.root.appendingPathComponent("collector-owner.lock").path, O_CREAT | O_RDWR, 0o600)
        XCTAssertGreaterThanOrEqual(lock, 0)
        defer { close(lock) }
        XCTAssertEqual(flock(lock, LOCK_EX | LOCK_NB), 0)
        let before = try f.snapshot()
        XCTAssertEqual(try f.preview().captureCount, 1)
        XCTAssertEqual(try f.snapshot(), before)
    }

    func testWALWithoutSidecarsRefusesWithoutCreatingThem_repro() throws {
        let f = try GCPreviewFixture(); defer { f.remove() }
        try f.add("head", bytes: "head", latest: true)
        try f.finish()
        let path = f.root.appendingPathComponent("inventory/inventory.sqlite")
        var bytes = try Data(contentsOf: path)
        bytes[18] = 2; bytes[19] = 2
        try bytes.write(to: path)
        let before = try f.snapshot()
        XCTAssertThrowsError(try f.preview())
        XCTAssertEqual(try f.snapshot(), before)
    }

    func testPrivateTmpPrefixReachesReadOnlyOpenInsteadOfInvalidInput() throws {
        // Read-only path validation only: never create a spool outside the
        // worktree. Both standard spellings name the existing system temp dir.
        for path in ["/private/tmp", "/tmp"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path + "/inventory/inventory.sqlite"))
            XCTAssertThrowsError(try CollectorSpoolGCPreview.run(spoolRoot: URL(fileURLWithPath: path))) { error in
                XCTAssertNil(error as? CollectorSpoolGCPreview.Failure)
                XCTAssertNotNil(error as? CollectorMachineIdentityError)
            }
        }
    }

    func testMissingDualACKedProtectedObjectsAreReportedWithoutSavings() throws {
        let f = try GCPreviewFixture(); defer { f.remove() }
        try f.add("head", bytes: "head", latest: true)
        try f.add("old", bytes: "old", centralStatus: "parsed")
        try f.finish()
        try FileManager.default.removeItem(at: f.object("head"))
        try FileManager.default.removeItem(at: f.object("old"))
        let before = try f.snapshot()
        let report = try f.preview()
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        let missing = try XCTUnwrap(document["missingProtectedByACK"] as? [[String: Any]])
        let acked = try XCTUnwrap(missing.first { $0["reason"] as? String == "dual_acked" })
        XCTAssertEqual(acked["bytes"] as? Int, 7)
        XCTAssertEqual(acked["objects"] as? Int, 2)
        XCTAssertEqual(report.missingReferencedBytes, 7)
        XCTAssertEqual(report.presentBytes, 0)
        XCTAssertEqual(report.potentialBytesBeforeProofAndEscrow, 0)
        XCTAssertEqual(report.actionableBytes, 0)
        XCTAssertEqual(try f.snapshot(), before)
    }

    func testMissingSharedObjectWithNonDualACKedReferenceStillFailsClosed() throws {
        let f = try GCPreviewFixture(); defer { f.remove() }
        try f.add("head", bytes: "shared", latest: true)
        try f.add("old", bytes: "shared", state: "pending")
        try f.finish()
        try FileManager.default.removeItem(at: f.object("shared"))
        let before = try f.snapshot()
        XCTAssertThrowsError(try f.preview()) { error in
            XCTAssertEqual(error as? CollectorSpoolGCPreview.Failure, .missingProtectedObject)
        }
        XCTAssertEqual(try f.snapshot(), before)
    }

    func testMalformedDuplicateStaleAndWrongScopeCentralEvidenceFailClosed() throws {
        let f = try GCPreviewFixture(); defer { f.remove() }
        try f.add("head", bytes: "head", latest: true)
        try f.add("old", bytes: "old")
        try f.finish()
        let original = try Data(contentsOf: f.evidence)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        for mode in ["malformed", "duplicate", "stale", "future", "parser", "scope"] {
            var modified = document
            var rows = try XCTUnwrap(document["publications"] as? [[String: Any]])
            switch mode {
            case "duplicate": rows.append(rows[0]); modified["publications"] = rows
            case "stale": modified["generatedAt"] = "2000-01-01T00:00:00Z"
            case "future": modified["generatedAt"] = "2100-01-01T00:00:00Z"
            case "parser": modified["parserRevision"] = "unknown"
            case "scope":
                for index in rows.indices { rows[index]["machineID"] = "wrong-machine" }
                modified["publications"] = rows
            default: break
            }
            let bytes = mode == "malformed" ? Data("{".utf8) : try JSONSerialization.data(withJSONObject: modified)
            try bytes.write(to: f.evidence)
            let before = try f.snapshot()
            if mode == "scope" { XCTAssertEqual(try f.preview().bytes("central_other"), 3) }
            else { XCTAssertThrowsError(try f.preview(), mode) }
            XCTAssertEqual(try f.snapshot(), before)
        }
    }

    func testNativeCLIReadsActiveWALWithHeldOwnerLockAndReadOnlyFiles() throws {
        guard let binary = ProcessInfo.processInfo.environment["ENGRAM_COLLECTOR_BINARY"] else {
            throw XCTSkip("Explicit ENGRAM_COLLECTOR_BINARY required")
        }
        let f = try GCPreviewFixture(); defer { f.remove() }
        try f.add("head", bytes: "head", latest: true)
        try f.add("old", bytes: "old")
        try f.finish()
        let path = f.root.appendingPathComponent("inventory/inventory.sqlite")
        let writer = try DatabaseQueue(path: path.path)
        defer { try? writer.close() }
        try writer.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
            try db.execute(sql: "UPDATE collector_publication_replicas SET state='pending',ack_bytes=NULL WHERE publication_digest=(SELECT publication_digest FROM collector_publications WHERE sequence<100000 LIMIT 1)")
        }
        for suffix in ["", "-wal", "-shm"] { XCTAssertEqual(chmod(path.path + suffix, 0o400), 0) }
        let lock = open(f.root.appendingPathComponent("collector-owner.lock").path, O_CREAT | O_RDWR, 0o600)
        XCTAssertGreaterThanOrEqual(lock, 0); defer { close(lock) }
        XCTAssertEqual(flock(lock, LOCK_EX | LOCK_NB), 0)
        let settings = f.root.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: ["runtimeRole": "collector", "collector": ["enabled": true, "shadowRoot": f.root.path]]).write(to: settings)
        // SecureRegularFile requires settings/evidence mode 0600; database
        // and sidecars above remain 0400 throughout the preview.
        XCTAssertEqual(chmod(settings.path, 0o600), 0)
        let before = try f.snapshot()
        let result = try f.cli(binary, ["--spool-gc", "--settings", settings.path, "--central-evidence", f.evidence.path])
        guard result.0 == 0 else { XCTFail("CLI failed: \(result.0): \(result.2)"); return }
        let report = try JSONDecoder().decode(CollectorSpoolGCPreview.Report.self, from: Data(result.1.utf8))
        XCTAssertEqual(report.bytes("pending"), 3)
        for arguments in [["--credentials-file", f.root.appendingPathComponent("missing-token").path], ["--once"], ["--initialize"], ["--reconcile-native-epoch"]] {
            XCTAssertEqual(try f.cli(binary, ["--spool-gc", "--settings", settings.path] + arguments).0, 64)
        }
        XCTAssertEqual(try f.snapshot(), before)
    }

    func testNativeCLIIsTokenFreeReadOnlyAndRejectsApply() throws {
        guard let binary = ProcessInfo.processInfo.environment["ENGRAM_COLLECTOR_BINARY"] else {
            throw XCTSkip("Explicit ENGRAM_COLLECTOR_BINARY required")
        }
        let f = try GCPreviewFixture(); defer { f.remove() }
        try f.add("head", bytes: "head", latest: true)
        try f.add("old", bytes: "old")
        try f.finish()
        let before = try f.snapshot()
        let result = try f.cli(binary, ["--spool-gc", "--spool-root", f.root.path, "--central-evidence", f.evidence.path])
        XCTAssertEqual(result.0, 0, result.1)
        let report = try JSONDecoder().decode(CollectorSpoolGCPreview.Report.self, from: Data(result.1.utf8))
        XCTAssertEqual(report.potentialBytesBeforeProofAndEscrow, 3)
        XCTAssertEqual(try f.cli(binary, ["--spool-gc", "--spool-root", f.root.path, "--apply"]).0, 64)
        XCTAssertEqual(try f.snapshot(), before)
    }
}

private final class GCPreviewFixture {
    static let machine = "11111111-2222-3333-4444-555555555555"
    static let instance = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    static let epoch = "11111111-AAAA-BBBB-CCCC-555555555555"
    let root: URL
    var evidence: URL { root.appendingPathComponent("central.json") }
    private var catalog: ArchiveCatalog?
    private var inventory: DatabaseQueue?
    private var central: [[String: Any]] = []
    private var sequence: Int64 = 0

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("k5-preview-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let capture = root.appendingPathComponent("capture")
        catalog = try ArchiveCatalog(root: capture, machineID: Self.machine)
        try catalog!.migrate()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("inventory"), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var config = Configuration(); config.foreignKeysEnabled = false
        inventory = try DatabaseQueue(path: root.appendingPathComponent("inventory/inventory.sqlite").path, configuration: config)
        let store = try CollectorInventoryStore(database: inventory!, machineID: Self.machine, ownerRunID: "fixture")
        try store.registerRoot(.init(rootID: "root", source: .codex, rootPath: "/synthetic", revision: 1))
        try inventory!.write { try $0.execute(sql: "UPDATE collector_roots SET completed_revision=requested_revision") }
    }

    func add(_ name: String, bytes text: String, latest: Bool = false, published: Bool = true,
             revision: Int = 1, state: String = "acknowledged", error: String = "", dirty: Bool = false,
             centralStatus: String = "index_ready", centralFailure: String = "") throws {
        sequence += 1
        let bytes = Data(text.utf8), digest = ArchiveV2Hash.sha256(bytes)
        let id = ArchiveV2Hash.sha256(Data(name.utf8))
        let generation = try ArchiveSourceGeneration(device: 1, inode: sequence, size: Int64(bytes.count), mtimeNs: sequence, ctimeNs: sequence, mode: 0o100600)
        let manifest = try ArchiveSourceManifest(captureID: id, machineID: Self.machine, source: "codex", locator: "/synthetic/stream", sessionID: nil,
            capturedAt: "2026-11-11T00:00:00.000Z", generation: generation, wholeSourceSHA256: digest, rawByteCount: Int64(bytes.count),
            chunks: [ArchiveChunkReference(ordinal: 0, rawSHA256: digest, rawByteCount: Int64(bytes.count))],
            replayLayout: ArchiveReplayLayout(strategy: .singleFile, relativePaths: ["source.jsonl"]))
        let manifestBytes = try ArchiveCanonicalJSON.encode(manifest)
        let capture = try catalog!.recordCapture(canonicalManifestBytes: manifestBytes)
        let cas = try ImmutableArchiveCAS(root: root.appendingPathComponent("capture"))
        _ = try cas.publishObject(raw: bytes, expectedSHA256: digest)
        _ = try cas.publishManifest(manifestBytes, expectedSHA256: capture.unboundManifestSHA256)
        guard published else { return }
        let publicationSequence = latest ? 100_000 : sequence
        let pub = try CollectorPublicationEnvelope(machineID: Self.machine, sourceInstanceID: Self.instance, collectorEpoch: Self.epoch, sequence: publicationSequence, manifestSHA256: capture.unboundManifestSHA256)
        let pubBytes = try ArchiveCanonicalJSON.encode(pub), pubDigest = try pub.sha256()
        try inventory!.write { db in
            try db.execute(sql: "INSERT INTO collector_publications VALUES (?, ?, 'root', ?, ?, ?, ?, ?, ?, ?)",
                arguments: [pubDigest, id, revision, "stream", Self.instance, Self.epoch, publicationSequence, capture.unboundManifestSHA256, pubBytes])
            try db.execute(sql: """
                INSERT INTO collector_locators(root_id,root_revision,relative_path,dirty_revision,acknowledged_revision,last_capture_id,claim_generation,last_error)
                VALUES ('root',?,'stream',2,?,?,0,?) ON CONFLICT(root_id,root_revision,relative_path) DO UPDATE SET
                last_capture_id=COALESCE(excluded.last_capture_id,collector_locators.last_capture_id),
                acknowledged_revision=MIN(excluded.acknowledged_revision,collector_locators.acknowledged_revision),
                last_error=COALESCE(excluded.last_error,collector_locators.last_error)
                """, arguments: [revision, dirty ? 1 : 2, latest ? id : nil, dirty ? "recaptureCooldown" : nil])
            for replica in ["hq", "m1"] {
                let ack = try CollectorPublicationACK(serverID: replica, journalID: Self.epoch, arrivalOrdinal: sequence,
                    publicationSHA256: pubDigest, manifestSHA256: capture.unboundManifestSHA256, storedAt: "2026-11-11T00:00:00.000Z")
                try db.execute(sql: "INSERT INTO collector_publication_replicas(publication_digest,replica_id,state,claim_generation,attempts,ack_bytes,last_error,claim_owner_run_id,claimed_at) VALUES (?,?,?,0,0,?,?,?,?)",
                    arguments: [pubDigest, replica, state, state == "acknowledged" ? try ArchiveCanonicalJSON.encode(ack) : nil,
                                error.isEmpty ? nil : error, state == "inflight" ? "fixture" : nil, state == "inflight" ? 1 : nil])
            }
        }
        central.append(["publicationSHA256": pubDigest, "manifestSHA256": capture.unboundManifestSHA256, "machineID": Self.machine,
                        "sourceInstanceID": Self.instance, "collectorEpoch": Self.epoch, "sequence": publicationSequence,
                        "status": centralStatus, "failureCode": centralFailure, "hasRetainedGeneration": true])
    }

    func finish() throws {
        try catalog?.close(); catalog = nil
        try inventory?.close(); inventory = nil
        try catalogSQL("PRAGMA journal_mode=DELETE")
        let doc: [String: Any] = ["schemaVersion": 1, "generatedAt": ISO8601DateFormatter().string(from: Date()),
                                "parserRevision": "swift-capture-v1", "publications": central]
        try JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys]).write(to: evidence)
        for url in FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])!.allObjects as! [URL] {
            var info = stat(); _ = lstat(url.path, &info)
            _ = chmod(url.path, info.st_mode & S_IFMT == S_IFDIR ? 0o700 : 0o600)
        }
    }
    func catalogSQL(_ sql: String) throws {
        let db = try DatabaseQueue(path: root.appendingPathComponent("capture/archive.sqlite").path)
        try db.writeWithoutTransaction { try $0.execute(sql: sql) }; try db.close()
    }
    func preview(central: Bool = true, maxBytes: Int64 = 256 * 1024 * 1024, maxObjects: Int = 128) throws -> CollectorSpoolGCPreview.Report {
        try CollectorSpoolGCPreview.run(spoolRoot: root, centralEvidence: central ? evidence : nil, maxBytes: maxBytes, maxObjects: maxObjects)
    }
    func object(_ text: String) -> URL {
        let digest = ArchiveV2Hash.sha256(Data(text.utf8))
        return root.appendingPathComponent("capture/objects/sha256/\(digest.prefix(2))/\(digest)")
    }
    func snapshot() throws -> [String: Data] {
        var values: [String: Data] = [:]
        for case let url as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])! {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                var info = stat(); XCTAssertEqual(lstat(url.path, &info), 0)
                values[url.path] = try Data(contentsOf: url)
                values[url.path + ":metadata"] = Data("\(info.st_ino):\(info.st_mode):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)".utf8)
            }
        }
        return values
    }
    func cli(_ binary: String, _ arguments: [String]) throws -> (Int32, String, String) {
        let p = Process(), out = Pipe(), err = Pipe()
        p.executableURL = URL(fileURLWithPath: binary); p.arguments = arguments
        p.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "CFFIXED_USER_HOME": root.path, "TMPDIR": root.path]
        p.standardOutput = out; p.standardError = err
        try p.run()
        let output = out.fileHandleForReading.readDataToEndOfFile()
        let errors = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: output, as: UTF8.self), String(decoding: errors, as: UTF8.self))
    }
    func remove() { try? catalog?.close(); try? inventory?.close(); try? FileManager.default.removeItem(at: root) }
}
