import Darwin
import Foundation
import GRDB
import XCTest
@testable import EngramCollectorCore

final class CollectorSpoolGCExecutorTests: XCTestCase {
    func testQuarantineAndExpiredProofRestoreExactBytes_repro() throws {
        let f = try GCExecutionFixture(); defer { f.remove() }
        try f.prepare()
        let approval = try f.approval()
        let result = try f.session!.apply(approval: approval, settingsURL: f.settings, now: GCExecutionFixture.clock)
        XCTAssertEqual(result.objects, 1)
        XCTAssertEqual(result.uniqueRawBytes, Int64(GCExecutionFixture.oldText.utf8.count))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.seed.object(GCExecutionFixture.oldText).path))
        XCTAssertEqual(try f.session!.restore(runID: approval.runID, now: GCExecutionFixture.clock + 60 * 86400), 1)
        XCTAssertEqual(try Data(contentsOf: f.seed.object(GCExecutionFixture.oldText)), Data(GCExecutionFixture.oldText.utf8))
    }

    func testHoldAndFreshEvidenceGateFinalUnlink_repro() throws {
        let f = try GCExecutionFixture(); defer { f.remove() }
        try f.prepare()
        let approval = try f.approval()
        try f.session!.apply(approval: approval, settingsURL: f.settings, now: GCExecutionFixture.clock)
        let early = try f.approval(action: "finalize", runID: approval.runID)
        XCTAssertThrowsError(try f.session!.finalize(approval: early, settingsURL: f.settings, now: GCExecutionFixture.clock)) {
            XCTAssertEqual($0 as? CollectorSpoolGCError, .holdNotElapsed)
        }
        let later = GCExecutionFixture.clock + 14 * 86400 + 1
        let ready = try f.approval(action: "finalize", runID: approval.runID, now: later)
        XCTAssertEqual(try f.session!.finalize(approval: ready, settingsURL: f.settings, now: later).objects, 1)
        XCTAssertThrowsError(try f.session!.prepareRead(f.oldDigest)) {
            XCTAssertEqual($0 as? CollectorSpoolGCError, .spoolRestoreRequired)
        }
    }

    func testUnlinkRejectsParentReplacementDuringAuthorization_repro() throws {
        let f = try GCExecutionFixture(); defer { f.remove() }
        try f.seed.add("head", bytes: "head", latest: true)
        try f.open()
        let files = f.session!.files, digest = ArchiveV2Hash.sha256(Data("head".utf8))
        let resident = try CollectorSpoolGCFiles.resident(digest)
        let quarantine = try CollectorSpoolGCFiles.quarantine(digest, runID: UUID().uuidString)
        let identity = try XCTUnwrap(files.verify(resident, digest: digest, bytes: 4))
        try files.move(resident, to: quarantine, digest: digest, expected: identity)
        let parent = f.seed.root.appendingPathComponent(quarantine).deletingLastPathComponent()
        let moved = parent.appendingPathExtension("replaced")
        XCTAssertThrowsError(try files.finalizeUnlink(quarantine, digest: digest, expected: identity) {
            try FileManager.default.moveItem(at: parent, to: moved)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        })
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent(digest)), Data("head".utf8))
    }

    func testCrashAtEachDurableQuarantineBoundaryIsRecoverable_repro() throws {
        for boundary in ["reserved", "beforeRename", "afterRename", "quarantined"] {
            let f = try GCExecutionFixture(); defer { f.remove() }
            try f.prepare(); let approval = try f.approval()
            f.session!.transitionHook = { event, _ in
                if event == boundary { throw CollectorSpoolGCSession.SimulatedCrash() }
            }
            XCTAssertThrowsError(try f.session!.apply(approval: approval, settingsURL: f.settings, now: GCExecutionFixture.clock))
            try f.reopen()
            _ = try f.session!.recover(now: GCExecutionFixture.clock + 1)
            if boundary == "quarantined" { XCTAssertEqual(try f.session!.restore(runID: approval.runID, now: GCExecutionFixture.clock + 2), 1) }
            XCTAssertEqual(try Data(contentsOf: f.seed.object(GCExecutionFixture.oldText)), Data(GCExecutionFixture.oldText.utf8))
            XCTAssertThrowsError(try f.session!.apply(approval: approval, settingsURL: f.settings, now: GCExecutionFixture.clock + 3))
            let reserved = try f.owner!.withSpoolGC { try $0.read { try Int64.fetchOne($0, sql: "SELECT reserved_bytes FROM collector_gc_runs") } }
            XCTAssertEqual(reserved, Int64(GCExecutionFixture.oldText.utf8.count))
        }
    }

    func testUnlinkCrashRecoveryUsesRecordedProofAndNeverRetriesUnlink_repro() throws {
        for boundary in ["unlinkPrepared", "afterUnlink", "evicted"] {
            let f = try GCExecutionFixture(); defer { f.remove() }
            try f.prepare(); let approval = try f.approval()
            try f.session!.apply(approval: approval, settingsURL: f.settings, now: GCExecutionFixture.clock)
            let later = GCExecutionFixture.clock + 14 * 86400 + 1
            let ready = try f.approval(action: "finalize", runID: approval.runID, now: later)
            f.session!.transitionHook = { event, _ in
                if event == boundary { throw CollectorSpoolGCSession.SimulatedCrash() }
            }
            XCTAssertThrowsError(try f.session!.finalize(approval: ready, settingsURL: f.settings, now: later))
            try f.reopen()
            _ = try f.session!.recover(now: later + 60 * 86400)
            let state = try f.owner!.withSpoolGC { try $0.read { try CollectorSpoolGCJournal.residency($0, f.oldDigest)?["state"] as String? } }
            XCTAssertEqual(state, boundary == "unlinkPrepared" ? "resident" : "evicted")
            _ = try f.session!.recover(now: later + 61 * 86400)
        }
    }

    func testRecreatedDigestCancelsOldUnlinkAuthority_repro() throws {
        let f = try GCExecutionFixture(); defer { f.remove() }
        try f.prepare(); let approval = try f.approval()
        try f.session!.apply(approval: approval, settingsURL: f.settings, now: GCExecutionFixture.clock)
        let cas = try ImmutableArchiveCAS(root: f.seed.root.appendingPathComponent("capture")).withCollectorObjectAccess(f.session!)
        _ = try cas.publishObject(raw: Data(GCExecutionFixture.oldText.utf8), expectedSHA256: f.oldDigest)
        let later = GCExecutionFixture.clock + 14 * 86400 + 1
        let ready = try f.approval(action: "finalize", runID: approval.runID, now: later)
        XCTAssertEqual(try f.session!.finalize(approval: ready, settingsURL: f.settings, now: later).objects, 0)
        XCTAssertEqual(try cas.readObject(sha256: f.oldDigest), Data(GCExecutionFixture.oldText.utf8))
        let extra = try CollectorSpoolGCFiles.quarantine(f.oldDigest, runID: approval.runID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.seed.root.appendingPathComponent(extra).path))
    }

    func testByteAndCountCapsNeverCreateOverBudgetIntent_repro() throws {
        for (bytes, objects) in [(Int64(0), 128), (Int64(1), 128), (Int64(1_048_576), 0)] {
            let f = try GCExecutionFixture(); defer { f.remove() }
            try f.prepare(); let approval = try f.approval(maxBytes: bytes, maxObjects: objects)
            XCTAssertEqual(try f.session!.apply(approval: approval, settingsURL: f.settings, now: GCExecutionFixture.clock).objects, 0)
            XCTAssertEqual(try f.session!.residencyCount(), 0)
        }
    }

    func testStaleProofOrPolicyAndNativeDriftNeverMovesObject_repro() throws {
        for mode in ["expired", "policy", "native", "proof", "escrow"] {
            let f = try GCExecutionFixture(); defer { f.remove() }
            try f.prepare(); var approval = try f.approval()
            switch mode {
            case "expired": approval.freshAt -= 301
            case "policy": approval.policySHA256 = String(repeating: "0", count: 64)
            case "native": try Data("changed".utf8).write(to: URL(fileURLWithPath: f.seed.nativeRoot).appendingPathComponent("stream"))
            case "proof": approval.replicas = []
            case "escrow":
                approval.escrow = .init(locationIdentity: "fixture", protectedSetSHA256: approval.escrow.protectedSetSHA256,
                    verifiedAt: approval.createdAt, expiresAt: approval.expiresAt, pKeyEvidenceID: "test", replicaRestoreDrillIDs: ["hq": "a", "m1": "b"], objects: [], manifests: [])
            default: XCTFail()
            }
            XCTAssertThrowsError(try f.session!.apply(approval: approval, settingsURL: f.settings, now: GCExecutionFixture.clock), mode)
            XCTAssertEqual(try f.session!.residencyCount(), 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.seed.object(GCExecutionFixture.oldText).path))
        }
    }

    func testNativeDriftAfterRenameRestoresBatch_repro() throws {
        let f = try GCExecutionFixture(); defer { f.remove() }
        try f.prepare(); let approval = try f.approval()
        f.session!.transitionHook = { event, _ in
            if event == "afterRename" { try Data("changed".utf8).write(to: URL(fileURLWithPath: f.seed.nativeRoot).appendingPathComponent("stream")) }
        }
        XCTAssertThrowsError(try f.session!.apply(approval: approval, settingsURL: f.settings, now: GCExecutionFixture.clock))
        XCTAssertEqual(try Data(contentsOf: f.seed.object(GCExecutionFixture.oldText)), Data(GCExecutionFixture.oldText.utf8))
    }

    func testNewProtectionRestoresBeforePublicationClaim_repro() throws {
        let f = try GCExecutionFixture(); defer { f.remove() }
        try f.prepare(); let approval = try f.approval()
        try f.session!.apply(approval: approval, settingsURL: f.settings, now: GCExecutionFixture.clock)
        // External state change reproduces a requeued historic publication.
        try f.owner!.withSpoolGC { try $0.write { try $0.execute(sql: "UPDATE collector_publication_replicas SET state='pending',ack_bytes=NULL WHERE publication_digest IN (SELECT publication_digest FROM collector_publications WHERE sequence<100000)") } }
        _ = try f.owner!.claimPublications(replicaID: "hq", limit: 1, now: GCExecutionFixture.clock + 1)
        XCTAssertEqual(try Data(contentsOf: f.seed.object(GCExecutionFixture.oldText)), Data(GCExecutionFixture.oldText.utf8))
    }

    func testK9FakeReadbackReassemblesAndRejectsWrongBytes() async throws {
        let f = try GCExecutionFixture(); defer { f.remove() }
        try f.prepare()
        let state = try f.owner!.withSpoolGC { try f.session!.snapshot($0) }
        let publications = state.inventory.publications.values.map(\.envelope)
        let manifests = Dictionary(uniqueKeysWithValues: state.catalog.captures.values.map { ($0.digest, $0.manifest) })
        var ackMap: [String: [String: CollectorPublicationACK]] = [:], responses: [String: [String: Data]] = [:]
        for server in ["hq", "m1"] {
            for pub in state.inventory.publications.values {
                let row = try XCTUnwrap(state.inventory.replicas[pub.digest]?.first { ($0["replica_id"] as String) == server })
                let ack = try ArchiveCanonicalJSON.decode(CollectorPublicationACK.self, from: row["ack_bytes"])
                ackMap[server, default: [:]][pub.digest] = ack
                responses[server, default: [:]]["/v2/archive/publications/" + pub.digest] = try ArchiveCanonicalJSON.encode(CollectorPublicationAcceptanceRecord(publication: pub.envelope, ack: ack))
                responses[server, default: [:]]["/v2/archive/manifests/" + pub.envelope.manifestSHA256] = try ArchiveCanonicalJSON.encode(manifests[pub.envelope.manifestSHA256]!)
            }
            for text in [GCExecutionFixture.oldText, GCExecutionFixture.headText] {
                responses[server, default: [:]]["/v2/archive/objects/" + ArchiveV2Hash.sha256(Data(text.utf8))] = Data(text.utf8)
            }
        }
        let targets = ["hq", "m1"].map { CollectorSpoolGCVerifier.Target(serverID: $0, endpoint: "https://\($0).invalid", physicalHostID: $0, storeIdentity: $0) }
        let good = responses
        let proofs = try await CollectorSpoolGCVerifier.readBack(publications: publications, manifests: manifests, expectedACKs: ackMap,
            targets: targets, now: GCExecutionFixture.clock) { target, path, _ in try XCTUnwrap(good[target.serverID]?[path]) }
        XCTAssertEqual(proofs.count, 2)
        responses["m1"]?["/v2/archive/objects/" + f.oldDigest] = Data("broken".utf8)
        let broken = responses
        do {
            _ = try await CollectorSpoolGCVerifier.readBack(publications: publications, manifests: manifests, expectedACKs: ackMap,
                targets: targets, now: GCExecutionFixture.clock) { target, path, _ in try XCTUnwrap(broken[target.serverID]?[path]) }
            XCTFail("Corrupt replica must fail")
        } catch { XCTAssertEqual(error as? CollectorSpoolGCError, .proofMissing) }
    }

    func testStreamAuthorityDriftInvalidatesApproval_repro() throws {
        let f = try GCExecutionFixture(); defer { f.remove() }
        try f.prepare(); let approval = try f.approval()
        try f.owner!.withSpoolGC { try $0.write { try $0.execute(sql: "UPDATE collector_streams SET last_sequence=last_sequence+1") } }
        XCTAssertThrowsError(try f.session!.apply(approval: approval, settingsURL: f.settings, now: GCExecutionFixture.clock))
        XCTAssertEqual(try f.session!.residencyCount(), 0)
    }

    func testSharedDigestChargesOnceAndOrphansAreOnlyReported() throws {
        let f = try GCExecutionFixture(); defer { f.remove() }
        try f.prepare(duplicateOld: true)
        let cas = try ImmutableArchiveCAS(root: f.seed.root.appendingPathComponent("capture"))
        let orphan = Data("orphan".utf8), orphanDigest = ArchiveV2Hash.sha256(orphan)
        _ = try cas.publishObject(raw: orphan, expectedSHA256: orphanDigest)
        let approval = try f.approval(maxBytes: Int64(GCExecutionFixture.oldText.utf8.count), maxObjects: 1)
        let report = try f.session!.apply(approval: approval, settingsURL: f.settings, now: GCExecutionFixture.clock)
        XCTAssertEqual(report.objects, 1)
        XCTAssertEqual(report.unknownOrphanBytes, 6)
        XCTAssertEqual(report.uniquePresentCandidateBytes, Int64(GCExecutionFixture.oldText.utf8.count))
        XCTAssertEqual(report.referencedLogicalBytes, Int64(GCExecutionFixture.oldText.utf8.count * 2 + GCExecutionFixture.headText.utf8.count))
        XCTAssertEqual(try cas.readObject(sha256: orphanDigest), orphan)
    }

    func testFinalizedBytesRemainChargedAcrossRestart() throws {
        let f = try GCExecutionFixture(); defer { f.remove() }
        try f.prepare(); let approval = try f.approval()
        try f.session!.apply(approval: approval, settingsURL: f.settings, now: GCExecutionFixture.clock)
        let later = GCExecutionFixture.clock + 14 * 86400 + 1
        let ready = try f.approval(action: "finalize", runID: approval.runID, now: later)
        try f.session!.finalize(approval: ready, settingsURL: f.settings, now: later)
        _ = try f.session!.recover(now: later + 1)
        var reset = ready; reset.maxBytes = 0
        XCTAssertThrowsError(try f.session!.finalize(approval: reset, settingsURL: f.settings, now: later + 1)) {
            XCTAssertEqual($0 as? CollectorSpoolGCError, .budgetExceeded)
        }
    }

    func testK9ReassemblesFileSetAndSQLitePairWithPerFileHashes() async throws {
        for paths in [["a.json", "b.json"], ["session.sqlite", "session.sqlite-wal"]] {
            for badPartHash in [false, true] {
                let a = Data("main".utf8), b = Data("wal".utf8), whole = a + b
                func generation(_ n: Int) throws -> ArchiveSourceGeneration {
                    try .init(device: 1, inode: 2, size: Int64(n), mtimeNs: 1, ctimeNs: 1, mode: 0o100600)
                }
                let files = try [ArchiveFileSetEntry(relativePath: paths[0], byteOffset: 0, rawByteCount: 4, wholeSourceSHA256: ArchiveV2Hash.sha256(a), generation: generation(4)),
                    ArchiveFileSetEntry(relativePath: paths[1], byteOffset: 4, rawByteCount: 3, wholeSourceSHA256: badPartHash ? String(repeating: "0", count: 64) : ArchiveV2Hash.sha256(b), generation: generation(3))]
                let layout = try ArchiveReplayLayout(strategy: .fileSet, relativePaths: paths, entrypointRelativePath: paths[0], files: files, absentRelativePaths: [])
                let digest = ArchiveV2Hash.sha256(whole)
                let manifest = try ArchiveSourceManifest(schemaVersion: 2, captureID: String(repeating: "a", count: 64), machineID: GCPreviewFixture.machine,
                    source: "cursor", locator: "/synthetic/session", sessionID: nil, capturedAt: "2026-11-11T00:00:00.000Z", generation: generation(4),
                    wholeSourceSHA256: digest, rawByteCount: 7, chunks: [ArchiveChunkReference(ordinal: 0, rawSHA256: digest, rawByteCount: 7)], replayLayout: layout)
                let bytes = try ArchiveCanonicalJSON.encode(manifest), manifestDigest = ArchiveV2Hash.sha256(bytes)
                let publication = try CollectorPublicationEnvelope(machineID: GCPreviewFixture.machine, sourceInstanceID: GCPreviewFixture.instance,
                    collectorEpoch: GCPreviewFixture.epoch, sequence: 1, manifestSHA256: manifestDigest)
                let publicationDigest = try publication.sha256()
                var ackMap: [String: [String: CollectorPublicationACK]] = [:], responses: [String: Data] = [:]
                for server in ["hq", "m1"] {
                    let ack = try CollectorPublicationACK(serverID: server, journalID: GCPreviewFixture.epoch, arrivalOrdinal: 1,
                        publicationSHA256: publicationDigest, manifestSHA256: manifestDigest, storedAt: "2026-11-11T00:00:00.000Z")
                    ackMap[server] = [publicationDigest: ack]
                    responses[server] = try ArchiveCanonicalJSON.encode(CollectorPublicationAcceptanceRecord(publication: publication, ack: ack))
                }
                let records = responses
                do {
                    let proofs = try await CollectorSpoolGCVerifier.readBack(publications: [publication], manifests: [manifestDigest: manifest], expectedACKs: ackMap,
                        targets: ["hq", "m1"].map { .init(serverID: $0, endpoint: "https://\($0).invalid", physicalHostID: $0, storeIdentity: $0) }, now: GCExecutionFixture.clock) { target, path, _ in
                        if path.contains("/publications/") { return records[target.serverID]! }
                        if path.contains("/manifests/") { return bytes }
                        return whole
                    }
                    XCTAssertFalse(badPartHash); XCTAssertEqual(proofs.count, 2)
                } catch {
                    XCTAssertTrue(badPartHash); XCTAssertEqual(error as? CollectorSpoolGCError, .proofMissing)
                }
            }
        }
    }

    func testPrivacyUsesCurrentCollectorLargeLineLimits_repro() throws {
        let f = try GCExecutionFixture(); defer { f.remove() }
        let large = GCExecutionFixture.oldText + "{\"type\":\"event_msg\",\"payload\":{\"type\":\"agent_message\",\"message\":\"" + String(repeating: "a", count: 2 * 1024 * 1024) + "\"}}\n"
        try f.seed.add("large-old", bytes: large)
        try f.prepare()
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: f.settings)) as? [String: Any])
        var collector = document["collector"] as! [String: Any], budgets = (document["collector"] as! [String: Any])["budgets"] as! [String: Any]
        budgets["maxCaptureBytes"] = 8 * 1024 * 1024; collector["budgets"] = budgets; document["collector"] = collector
        try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(to: f.settings)
        let approval = try f.approval(maxBytes: 8 * 1024 * 1024)
        XCTAssertEqual(try f.session!.apply(approval: approval, settingsURL: f.settings, now: GCExecutionFixture.clock).objects, 2)
    }

    func testMissingTrackedKeptBytesBlockBeforeClaimWithoutRelabeling() throws {
        let f = try GCExecutionFixture(); defer { f.remove() }
        try f.prepare(); let approval = try f.approval()
        try f.session!.apply(approval: approval, settingsURL: f.settings, now: GCExecutionFixture.clock)
        let path = try CollectorSpoolGCFiles.quarantine(f.oldDigest, runID: approval.runID)
        try FileManager.default.removeItem(at: f.seed.root.appendingPathComponent(path))
        try f.owner!.withSpoolGC { try $0.write { try $0.execute(sql: "UPDATE collector_publication_replicas SET state='pending',ack_bytes=NULL WHERE publication_digest IN (SELECT publication_digest FROM collector_publications WHERE sequence<100000)") } }
        XCTAssertThrowsError(try f.owner!.claimPublications(replicaID: "hq", limit: 1, now: GCExecutionFixture.clock)) {
            XCTAssertEqual($0 as? CollectorSpoolGCError, .spoolIntegrityBlocked)
        }
        XCTAssertThrowsError(try f.session!.recover(now: GCExecutionFixture.clock)) {
            XCTAssertEqual($0 as? CollectorSpoolGCError, .spoolIntegrityBlocked)
        }
        let relabeled = try f.owner!.withSpoolGC { try $0.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM collector_publication_replicas WHERE state='inflight' OR last_error='localContentUnavailable'") } }
        XCTAssertEqual(relabeled, 0)
    }

    func testPrivacyPropagatesRecordedEvictionAsRestoreRequired() throws {
        let f = try GCExecutionFixture(); defer { f.remove() }
        try f.prepare(); let approval = try f.approval()
        try f.session!.apply(approval: approval, settingsURL: f.settings, now: GCExecutionFixture.clock)
        let later = GCExecutionFixture.clock + 14 * 86400 + 1
        try f.session!.finalize(approval: f.approval(action: "finalize", runID: approval.runID, now: later), settingsURL: f.settings, now: later)
        let capture = try XCTUnwrap(f.catalog!.capture(captureID: ArchiveV2Hash.sha256(Data("old".utf8))))
        let manifest = try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: capture.unboundManifestBytes)
        let cas = try ImmutableArchiveCAS(root: f.seed.root.appendingPathComponent("capture")).withCollectorObjectAccess(f.session!)
        XCTAssertThrowsError(try CollectorPrivacyProof.assess(capture: .init(capture: capture, manifest: manifest), cas: cas, format: .codex,
            policy: f.session!.configuration(f.settings).freshPolicy(at: f.settings))) {
            XCTAssertEqual($0 as? CollectorSpoolGCError, .spoolRestoreRequired)
        }
    }

    func testUnsafeCandidateAndConflictingRestoreNeverOverwriteBytes() throws {
        for mode in ["hardlink", "symlink", "restoreConflict"] {
            let f = try GCExecutionFixture(); defer { f.remove() }
            try f.prepare(); let approval = try f.approval()
            let object = f.seed.object(GCExecutionFixture.oldText), other = f.base.appendingPathComponent("retained")
            if mode == "hardlink" {
                XCTAssertEqual(link(object.path, other.path), 0)
            } else if mode == "symlink" {
                try FileManager.default.moveItem(at: object, to: other)
                XCTAssertEqual(symlink(other.path, object.path), 0)
            } else {
                try f.session!.apply(approval: approval, settingsURL: f.settings, now: GCExecutionFixture.clock)
                try Data("conflict".utf8).write(to: object); XCTAssertEqual(chmod(object.path, 0o600), 0)
                XCTAssertThrowsError(try f.session!.restore(runID: approval.runID, now: GCExecutionFixture.clock))
                XCTAssertEqual(try Data(contentsOf: object), Data("conflict".utf8))
                let path = try CollectorSpoolGCFiles.quarantine(f.oldDigest, runID: approval.runID)
                XCTAssertEqual(try Data(contentsOf: f.seed.root.appendingPathComponent(path)), Data(GCExecutionFixture.oldText.utf8))
                continue
            }
            XCTAssertThrowsError(try f.session!.apply(approval: approval, settingsURL: f.settings, now: GCExecutionFixture.clock))
            XCTAssertEqual(try f.session!.residencyCount(), 0)
            XCTAssertEqual(try Data(contentsOf: other), Data(GCExecutionFixture.oldText.utf8))
        }
    }

    func testStaleNativeEpochBlocksEvenFreshApproval_repro() throws {
        let f = try GCExecutionFixture(); defer { f.remove() }
        try f.prepare()
        try f.owner!.withSpoolGC { try $0.write { try $0.execute(sql: "UPDATE collector_roots SET event_epoch=?,event_cursor='1'", arguments: ["fsevents-device-v1:" + UUID().uuidString]) } }
        XCTAssertThrowsError(try f.session!.apply(approval: f.approval(), settingsURL: f.settings, now: GCExecutionFixture.clock))
        XCTAssertEqual(try f.session!.residencyCount(), 0)
    }

    func testFinalizeRestoresWhenNativeOrPrivacyEligibilityChanges_repro() throws {
        for mode in ["native", "privacy"] {
            let f = try GCExecutionFixture(); defer { f.remove() }
            try f.prepare(); let approval = try f.approval()
            try f.session!.apply(approval: approval, settingsURL: f.settings, now: GCExecutionFixture.clock)
            let later = GCExecutionFixture.clock + 14 * 86400 + 1
            var ready = try f.approval(action: "finalize", runID: approval.runID, now: later)
            if mode == "native" {
                try Data("changed".utf8).write(to: URL(fileURLWithPath: f.seed.nativeRoot).appendingPathComponent("stream"))
            } else {
                var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: f.settings)) as? [String: Any])
                var collector = document["collector"] as! [String: Any]
                collector["privacy"] = ["revision": 2, "excludedProjectRoots": ["/allowed"]]; document["collector"] = collector
                try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(to: f.settings)
                ready = try f.approval(action: "finalize", runID: approval.runID, now: later)
            }
            XCTAssertThrowsError(try f.session!.finalize(approval: ready, settingsURL: f.settings, now: later))
            XCTAssertEqual(try Data(contentsOf: f.seed.object(GCExecutionFixture.oldText)), Data(GCExecutionFixture.oldText.utf8), mode)
        }
    }

    func testFinalizeRestoresWhenNativeHeadDisappearsOrRootIsUnreadable_repro() throws {
        for mode in ["removed", "renamed", "unreadable-root"] {
            let f = try GCExecutionFixture(); defer { f.remove() }
            try f.prepare(); let approval = try f.approval()
            try f.session!.apply(approval: approval, settingsURL: f.settings, now: GCExecutionFixture.clock)
            let later = GCExecutionFixture.clock + 14 * 86400 + 1
            let ready = try f.approval(action: "finalize", runID: approval.runID, now: later)
            let root = URL(fileURLWithPath: f.seed.nativeRoot)
            let head = root.appendingPathComponent("stream")
            defer { _ = chmod(root.path, 0o700) }
            switch mode {
            case "removed": try FileManager.default.removeItem(at: head)
            case "renamed": try FileManager.default.moveItem(at: head, to: root.appendingPathComponent("moved"))
            default: XCTAssertEqual(chmod(root.path, 0), 0)
            }
            XCTAssertThrowsError(try f.session!.finalize(approval: ready, settingsURL: f.settings, now: later), mode)
            XCTAssertEqual(try Data(contentsOf: f.seed.object(GCExecutionFixture.oldText)), Data(GCExecutionFixture.oldText.utf8), mode)
            let quarantine = try CollectorSpoolGCFiles.quarantine(f.oldDigest, runID: approval.runID)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.seed.root.appendingPathComponent(quarantine).path), mode)
        }
    }

    func testMissingProofNeverCreatesRunOrMovesObjects_repro() throws {
        let f = try GCExecutionFixture(); defer { f.remove() }
        try f.seed.add("head", bytes: "head", latest: true)
        try f.seed.add("old", bytes: "old")
        try f.open()
        XCTAssertThrowsError(try f.session!.apply(approval: nil, settingsURL: f.base.appendingPathComponent("missing-settings"), now: 1_800_000_000)) { error in
            XCTAssertEqual(error as? CollectorSpoolGCError, .proofMissing)
        }
        XCTAssertEqual(try f.session!.residencyCount(), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.seed.object("old").path))
    }

    func testUnknownJournalSchemaRollsBackMigration_repro() throws {
        let f = try GCExecutionFixture(); defer { f.remove() }
        try f.open()
        try f.owner!.withSpoolGC { queue in
            try queue.write { try $0.execute(sql: "UPDATE collector_metadata SET value='future' WHERE key='gc_schema_version'") }
            XCTAssertThrowsError(try queue.write { try CollectorSpoolGCJournal.migrate($0) }) { error in
                XCTAssertEqual(error as? CollectorSpoolGCError, .unsupportedSchema)
            }
        }
    }

    func testApplyAcceptsFullRawChunkSizeObject_repro() throws {
        let f = try GCExecutionFixture(); defer { f.remove() }
        let line = "{\"type\":\"turn_context\",\"payload\":{\"cwd\":\"/allowed\",\"pad\":\"" + String(repeating: "a", count: 8000) + "\"}}\n"
        let bigOld = GCExecutionFixture.oldText + String(repeating: line, count: 600) // ~4.8 MiB <= 8 MiB maxObjectRawBytes
        XCTAssertGreaterThan(bigOld.utf8.count, ArchiveV2ProtocolLimits.maxManifestBytes * 4)
        XCTAssertLessThanOrEqual(bigOld.utf8.count, ArchiveV2ProtocolLimits.maxObjectRawBytes)
        let root = CollectorRootConfiguration(rootID: "root", source: .codex, rootPath: f.seed.nativeRoot, revision: 1)
        try Data(GCExecutionFixture.headText.utf8).write(to: URL(fileURLWithPath: f.seed.nativeRoot).appendingPathComponent("stream"))
        let generation = try CollectorPublicationWorker.sourceGeneration(root: root, relativePath: "stream")
        try f.seed.add("big-old", bytes: bigOld)
        try f.seed.add("head", bytes: GCExecutionFixture.headText, latest: true, nativeGeneration: generation)
        try f.open()
        let opened = try CollectorPOSIXDirectoryAccess.openAbsolute(components: CollectorPOSIXDirectoryAccess.components(f.seed.nativeRoot))
        defer { close(opened.descriptor) }
        let id = try CollectorPOSIXDirectoryAccess.identity(opened.info)
        let epoch = try CollectorNativeEventStream.currentEpoch(binding: .init(configuration: root, expectedIdentity: id))
        try f.owner!.withSpoolGC { queue in
            try queue.write { db in
                try db.execute(sql: "UPDATE collector_roots SET event_epoch=?,event_cursor='1'", arguments: [epoch])
                try db.execute(sql: "INSERT INTO collector_streams(root_id,root_revision,effective_source,source_instance_id,collector_epoch,last_sequence) VALUES ('root',1,'codex',?,?,100000)", arguments: [GCPreviewFixture.instance, GCPreviewFixture.epoch])
                try db.execute(sql: "INSERT INTO collector_root_bindings(root_id,root_revision,device,inode,generation,birth_seconds,birth_nanoseconds) VALUES ('root',1,?,?,?,?,?)",
                    arguments: [id.device, id.inode, Int64(id.generation), id.birthSeconds, id.birthNanoseconds])
                try db.execute(sql: "UPDATE collector_locators SET observed_generation=?", arguments: ["stat-v1:" + String(decoding: try ArchiveCanonicalJSON.encode(generation), as: UTF8.self)])
            }
        }
        let document: [String: Any] = ["runtimeRole": "collector", "collector": [
            "enabled": true, "shadowRoot": f.seed.root.path, "identityCatalog": f.identity.path,
            "roots": [["rootID": "root", "source": "codex", "rootPath": f.seed.nativeRoot, "revision": 1]],
            "replicas": ["hq", "m1"].map { ["serverID": $0, "baseURL": "https://\($0).invalid", "credentialID": "\($0)-test"] },
            "privacy": ["revision": 1, "excludedProjectRoots": []],
            "budgets": ["maxEntriesVisited":2,"maxCandidateFiles":2,"maxDirectoryOpens":1,"maxMetadataBytes":8192,
                "maxCaptureFiles":2,"maxCaptureBytes":16_777_216,"maxUploadClaimsPerReplica":2,"maxRecoveryCandidates":8,
                "maxResponseBytes":4096,"minimumFreeDiskBytes":0,"maxIncomingPaths":64,"maxPathUTF8Bytes":4096,
                "maxTotalPathUTF8Bytes":32768,"maxCheckpointUTF8Bytes":512,"maxQueuedBatches":16,
                "maxQueuedUTF8Bytes":65536,"pollIntervalMilliseconds":50]]]
        try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(to: f.settings)
        XCTAssertEqual(chmod(f.settings.path, 0o600), 0)
        let approval = try f.approval(maxBytes: 16_777_216)
        let report = try f.session!.apply(approval: approval, settingsURL: f.settings, now: GCExecutionFixture.clock)
        XCTAssertEqual(report.objects, 1)
    }

    func testBatchRecheckAvoidsPerObjectSnapshotDecoding_repro() throws {
        let f = try GCExecutionFixture(); defer { f.remove() }
        for index in 0..<7 {
            let line = GCExecutionFixture.oldText + "{\"type\":\"turn_context\",\"payload\":{\"cwd\":\"/allowed\",\"seq\":\(index)}}\n"
            try f.seed.add("old-\(index)", bytes: line)
        }
        try f.prepare()
        let approval = try f.approval(maxBytes: 1_048_576, maxObjects: 128)
        f.session!.snapshotDecodeCount = 0
        let applied = try f.session!.apply(approval: approval, settingsURL: f.settings, now: GCExecutionFixture.clock)
        XCTAssertEqual(applied.objects, 8)
        XCTAssertEqual(f.session!.snapshotDecodeCount, 2, "apply must decode full canonical snapshot only at entry and exit, not 3x per object")

        let later = GCExecutionFixture.clock + 14 * 86400 + 1
        let ready = try f.approval(action: "finalize", runID: approval.runID, now: later)
        f.session!.snapshotDecodeCount = 0
        let finalized = try f.session!.finalize(approval: ready, settingsURL: f.settings, now: later)
        XCTAssertEqual(finalized.objects, 8)
        XCTAssertEqual(f.session!.snapshotDecodeCount, 1, "finalize must decode full canonical snapshot once when DB scope is unchanged")
    }

    func testMidBatchDatabaseAndCatalogDriftRestoresAndBlocksUnlink_repro() throws {
        for (phase, target) in [("apply", "inventory"), ("apply", "catalog"), ("finalize", "inventory"), ("finalize", "catalog")] {
            let f = try GCExecutionFixture(); defer { f.remove() }
            try f.prepare()
            let approval = try f.approval()
            let invPath = f.seed.root.appendingPathComponent("inventory/inventory.sqlite").path
            let catPath = f.seed.root.appendingPathComponent("capture/archive.sqlite").path
            let injectDrift: () throws -> Void = {
                if target == "inventory" {
                    let ext = try DatabaseQueue(path: invPath)
                    try ext.write { try $0.execute(sql: "UPDATE collector_streams SET last_sequence=last_sequence+1") }
                    try ext.close()
                } else {
                    let ext = try DatabaseQueue(path: catPath)
                    try ext.write { try $0.execute(sql: "UPDATE archive_captures SET diagnostic='drift'") }
                    try ext.close()
                }
            }
            if phase == "apply" {
                f.session!.transitionHook = { event, _ in
                    if event == "afterRename" { try injectDrift() }
                }
                XCTAssertThrowsError(try f.session!.apply(approval: approval, settingsURL: f.settings, now: GCExecutionFixture.clock), "\(phase)-\(target)") {
                    XCTAssertEqual($0 as? CollectorSpoolGCError, .scopeChanged)
                }
                XCTAssertEqual(try Data(contentsOf: f.seed.object(GCExecutionFixture.oldText)), Data(GCExecutionFixture.oldText.utf8), "\(phase)-\(target)")
            } else {
                try f.session!.apply(approval: approval, settingsURL: f.settings, now: GCExecutionFixture.clock)
                let later = GCExecutionFixture.clock + 14 * 86400 + 1
                let ready = try f.approval(action: "finalize", runID: approval.runID, now: later)
                f.session!.transitionHook = { event, _ in
                    if event == "unlinkPrepared" { try injectDrift() }
                }
                XCTAssertThrowsError(try f.session!.finalize(approval: ready, settingsURL: f.settings, now: later), "\(phase)-\(target)") {
                    XCTAssertEqual($0 as? CollectorSpoolGCError, .scopeChanged)
                }
                XCTAssertEqual(try Data(contentsOf: f.seed.object(GCExecutionFixture.oldText)), Data(GCExecutionFixture.oldText.utf8), "\(phase)-\(target)")
            }
        }
    }
}

extension GCExecutionFixture {
    static let clock: Int64 = 1_800_000_000
    static let oldText = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"native\",\"cwd\":\"/allowed\"}}\n"
    static let headText = oldText + "{\"type\":\"turn_context\",\"payload\":{\"cwd\":\"/allowed\"}}\n"
    var settings: URL { base.appendingPathComponent("settings.json") }
    var oldDigest: String { ArchiveV2Hash.sha256(Data(Self.oldText.utf8)) }

    func prepare(duplicateOld: Bool = false) throws {
        let root = CollectorRootConfiguration(rootID: "root", source: .codex, rootPath: seed.nativeRoot, revision: 1)
        try Data(Self.headText.utf8).write(to: URL(fileURLWithPath: seed.nativeRoot).appendingPathComponent("stream"))
        let generation = try CollectorPublicationWorker.sourceGeneration(root: root, relativePath: "stream")
        try seed.add("old", bytes: Self.oldText)
        if duplicateOld { try seed.add("old-shared", bytes: Self.oldText) }
        try seed.add("head", bytes: Self.headText, latest: true, nativeGeneration: generation)
        try open()
        let opened = try CollectorPOSIXDirectoryAccess.openAbsolute(components: CollectorPOSIXDirectoryAccess.components(seed.nativeRoot))
        defer { close(opened.descriptor) }
        let id = try CollectorPOSIXDirectoryAccess.identity(opened.info)
        let epoch = try CollectorNativeEventStream.currentEpoch(binding: .init(configuration: root, expectedIdentity: id))
        try owner!.withSpoolGC { queue in
            try queue.write { db in
                try db.execute(sql: "UPDATE collector_roots SET event_epoch=?,event_cursor='1'", arguments: [epoch])
                try db.execute(sql: "INSERT INTO collector_streams(root_id,root_revision,effective_source,source_instance_id,collector_epoch,last_sequence) VALUES ('root',1,'codex',?,?,100000)", arguments: [GCPreviewFixture.instance, GCPreviewFixture.epoch])
                try db.execute(sql: "INSERT INTO collector_root_bindings(root_id,root_revision,device,inode,generation,birth_seconds,birth_nanoseconds) VALUES ('root',1,?,?,?,?,?)",
                    arguments: [id.device, id.inode, Int64(id.generation), id.birthSeconds, id.birthNanoseconds])
                try db.execute(sql: "UPDATE collector_locators SET observed_generation=?", arguments: ["stat-v1:" + String(decoding: try ArchiveCanonicalJSON.encode(generation), as: UTF8.self)])
            }
        }
        let document: [String: Any] = ["runtimeRole": "collector", "collector": [
            "enabled": true, "shadowRoot": seed.root.path, "identityCatalog": identity.path,
            "roots": [["rootID": "root", "source": "codex", "rootPath": seed.nativeRoot, "revision": 1]],
            "replicas": ["hq", "m1"].map { ["serverID": $0, "baseURL": "https://\($0).invalid", "credentialID": "\($0)-test"] },
            "privacy": ["revision": 1, "excludedProjectRoots": []],
            "budgets": ["maxEntriesVisited":2,"maxCandidateFiles":2,"maxDirectoryOpens":1,"maxMetadataBytes":8192,
                "maxCaptureFiles":2,"maxCaptureBytes":1048576,"maxUploadClaimsPerReplica":2,"maxRecoveryCandidates":8,
                "maxResponseBytes":4096,"minimumFreeDiskBytes":0,"maxIncomingPaths":64,"maxPathUTF8Bytes":4096,
                "maxTotalPathUTF8Bytes":32768,"maxCheckpointUTF8Bytes":512,"maxQueuedBatches":16,
                "maxQueuedUTF8Bytes":65536,"pollIntervalMilliseconds":50]]]
        try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(to: settings)
        XCTAssertEqual(chmod(settings.path, 0o600), 0)
    }

    func approval(action: String = "apply", runID: String = UUID().uuidString, now: Int64 = clock,
                  maxBytes: Int64 = 1_048_576, maxObjects: Int = 128) throws -> CollectorSpoolGCApproval {
        let session = session!, config = try session.configuration(settings)
        let loaded = try JSONDecoder().decode(CollectorSpoolGCPreview.Evidence.self, from: Data(contentsOf: seed.evidence))
        let central = CollectorSpoolGCPreview.Evidence(schemaVersion: 1,
            generatedAt: ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(now))),
            parserRevision: loaded.parserRevision, publications: loaded.publications)
        return try owner!.withSpoolGC { queue in
            let state = try session.snapshot(queue, evidence: central), graph = try XCTUnwrap(state.graph)
            let candidates = Set(graph.refs.keys).subtracting(graph.keep)
            let captures = Set(candidates.flatMap { graph.refs[$0]! })
            let replicas = try ["hq", "m1"].map { server -> CollectorSpoolGCApproval.Replica in
                var accepts: [String: String] = [:]
                for pub in state.inventory.publications.values {
                    let row = try XCTUnwrap(state.inventory.replicas[pub.digest]?.first { ($0["replica_id"] as String) == server })
                    let ack = try ArchiveCanonicalJSON.decode(CollectorPublicationACK.self, from: row["ack_bytes"])
                    let record = try CollectorPublicationAcceptanceRecord(publication: pub.envelope, ack: ack)
                    accepts[pub.digest] = ArchiveV2Hash.sha256(try ArchiveCanonicalJSON.encode(record))
                }
                return .init(serverID: server, endpoint: "https://\(server).invalid", physicalHostID: server, storeIdentity: server,
                    journalID: GCPreviewFixture.epoch, verifiedAt: now, acceptanceSHA256: accepts,
                    manifests: Dictionary(uniqueKeysWithValues: state.catalog.captures.values.map { ($0.digest, $0.manifest.wholeSourceSHA256) }), objects: graph.sizes)
            }
            let manifests = Set(graph.keep.flatMap { graph.refs[$0]! }).map { state.catalog.captures[$0]!.digest }.sorted()
            return .init(verifierBuildID: "isolated-k9-fixture-v1", centralInstanceIdentity: "synthetic-central-v1", action: action, runID: runID, nonce: UUID().uuidString, machineID: state.inventory.machine,
                spoolIdentity: session.files.scopeIdentity, scopeSHA256: state.hash,
                configurationSHA256: ArchiveV2Hash.sha256(config.authorityBytes), policySHA256: try config.freshPolicy(at: settings).sha256(),
                nativeSHA256: try session.nativeHash(queue, snapshot: state, config: config, captures: captures),
                createdAt: now, expiresAt: now + 86400, freshAt: now, maxBytes: maxBytes, maxObjects: maxObjects,
                holdSeconds: 14 * 86400, central: central, replicas: replicas,
                escrow: .init(locationIdentity: "synthetic-private-escrow", protectedSetSHA256: try CollectorSpoolGCSession.protectedSetHash(state),
                    verifiedAt: now, expiresAt: now + 86400, pKeyEvidenceID: "test-key-drill", replicaRestoreDrillIDs: ["hq": "test-hq", "m1": "test-m1"],
                    objects: graph.keep.sorted(), manifests: manifests))
        }
    }
}
