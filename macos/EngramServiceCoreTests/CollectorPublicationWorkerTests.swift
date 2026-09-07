import CryptoKit
import Darwin
import Foundation
import GRDB
import XCTest
@testable import EngramCollectorCore
@testable import EngramRemoteServerCore

private typealias PublicationIntent = EngramCollectorCore.CollectorPublicationIntent
private typealias PublicationClaim = EngramCollectorCore.CollectorPublicationClaim
private typealias PublicationEnvelope = EngramCollectorCore.CollectorPublicationEnvelope
private typealias PublicationACK = EngramCollectorCore.CollectorPublicationACK
private typealias CaptureResult = EngramCollectorCore.ArchiveCaptureResult
private typealias Canonical = EngramCollectorCore.ArchiveCanonicalJSON
private typealias PublicationWorker = EngramCollectorCore.CollectorPublicationWorker
private typealias WorkerError = EngramCollectorCore.CollectorPublicationWorkerError

final class CollectorPublicationWorkerTests: XCTestCase {
    func testDiskAdmissionRecordsIndependentVolumePressureAndResetsEachCycle() async throws {
        for recovering in [false, true] {
            for inventoryPressure in [false, true] {
                let override = PublicationLocked<Int64?>(nil)
                let samples = PublicationLocked<[Int64]>([])
                let f = try PublicationFixture(casTestHooks: .init(afterVolumeStat: { _, measured in
                    let value = override.value ?? measured
                    samples.change { $0.append(value) }
                    return value
                }))
                let replicas = try await replicas(for: f)
                if recovering {
                    let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(beforeCapture: { _ in
                        throw PublicationFixture.Failure.injected
                    })
                    do {
                        _ = try await f.worker(replicas.endpoints, hooks: hooks).runOnce(now: 99)
                        XCTFail("the uncaptured reservation must be established by the real worker")
                    } catch { XCTAssertEqual(error as? PublicationFixture.Failure, .injected) }
                    XCTAssertEqual(try f.owner.captureReservations(limit: 8).count, 1)
                    XCTAssertTrue(try f.catalog.unboundCaptures(limit: 8).isEmpty)
                }
                samples.change { $0.removeAll() }
                override.change { $0 = 0 }
                var budget = EngramCollectorCore.CollectorPublicationBudget()
                budget.minimumFreeDiskBytes = inventoryPressure ? Int64.max : 1
                let worker = try f.worker(replicas.endpoints, budget: budget)
                let blocked = try await worker.runOnce(now: 100)
                assertDiskObservation(blocked.diskAdmission, threshold: budget.minimumFreeDiskBytes,
                    captureMinimum: inventoryPressure ? nil : 0, inventoryBelowThreshold: inventoryPressure)
                XCTAssertEqual(samples.value, inventoryPressure ? [] : [0], "preserve inventory-before-CAS short circuit")
                XCTAssertEqual(blocked.captured, 0)
                XCTAssertGreaterThan(blocked.deferred, 0)
                XCTAssertEqual(blocked.acknowledgedHQ + blocked.acknowledgedM1, 0)
                XCTAssertTrue(try f.catalog.unboundCaptures(limit: 8).isEmpty)
                XCTAssertTrue(try f.owner.publicationIntents(limit: 8).isEmpty)
                XCTAssertEqual(try f.integer("SELECT acknowledged_revision FROM collector_locators WHERE relative_path = 'one.jsonl'"), 0)
                if !inventoryPressure {
                    override.change { $0 = 4096 }
                    let resumed = try await worker.runOnce(now: 101)
                    assertDiskObservation(resumed.diskAdmission, threshold: 1, captureMinimum: 4096)
                    XCTAssertEqual(resumed.captured, 1)
                    XCTAssertEqual(resumed.acknowledgedHQ, 1)
                    XCTAssertEqual(resumed.acknowledgedM1, 1)
                    let idle = try await worker.runOnce(now: 102)
                    XCTAssertEqual(idle.diskAdmission, .notEvaluated,
                        "an idle pass must not advertise the previous pass's observation")
                }
                await replicas.stop()
            }
        }

        // One low admission followed by a successful admission in the same
        // cycle must preserve the actual minimum, not the last observation.
        let samples = PublicationLocked<[Int64]>([])
        let f = try PublicationFixture(casTestHooks: .init(afterVolumeStat: { _, _ in
            var value: Int64 = 4096
            samples.change { recorded in
                if recorded.isEmpty { value = 0 }
                recorded.append(value)
            }
            return value
        }))
        let replicas = try await replicas(for: f)
        let second = f.sourceRoot.appendingPathComponent("two.jsonl")
        try f.transcript(text: "another bounded candidate").write(to: second)
        XCTAssertEqual(chmod(second.path, 0o600), 0)
        try f.markDirty(relativePath: "two.jsonl")
        var budget = EngramCollectorCore.CollectorPublicationBudget()
        budget.minimumFreeDiskBytes = 1
        budget.maxCaptureFiles = 2
        let worker = try f.worker(replicas.endpoints, budget: budget)
        let mixed = try await worker.runOnce(now: 100)
        XCTAssertEqual(samples.value, [0, 4096], "status must not add an extra volume probe")
        assertDiskObservation(mixed.diskAdmission, threshold: 1, captureMinimum: 0)
        XCTAssertEqual(mixed.captured, 1)
        XCTAssertEqual(mixed.acknowledgedHQ, 1)
        XCTAssertEqual(mixed.acknowledgedM1, 1)
        let resumed = try await worker.runOnce(now: 101)
        assertDiskObservation(resumed.diskAdmission, threshold: 1, captureMinimum: 4096)
        XCTAssertEqual(resumed.captured, 1)
        XCTAssertEqual(resumed.acknowledgedHQ, 1)
        XCTAssertEqual(resumed.acknowledgedM1, 1)
        await replicas.stop()
    }

    func testCaptureFileAndByteBudgetShortCircuitsDoNotInventDiskObservations() async throws {
        for fileBudget in [false, true] {
            let probes = PublicationLocked(0)
            let f = try PublicationFixture(casTestHooks: .init(afterVolumeStat: { _, _ in
                probes.change { $0 += 1 }
                return 0
            }))
            let replicas = try await replicas(for: f)
            var budget = EngramCollectorCore.CollectorPublicationBudget()
            budget.minimumFreeDiskBytes = 1
            if fileBudget { budget.maxCaptureFiles = 0 }
            else { budget.maxCaptureBytes = 1 }
            let cycle = try await f.worker(replicas.endpoints, budget: budget).runOnce(now: 100)
            XCTAssertEqual(cycle.diskAdmission, .notEvaluated)
            XCTAssertEqual(probes.value, 0)
            XCTAssertEqual(cycle.captured, 0)
            XCTAssertEqual(cycle.deferred, fileBudget ? 0 : 1,
                "neither a zero nor a nonzero deferred count identifies disk pressure")
            XCTAssertEqual(cycle.acknowledgedHQ + cycle.acknowledgedM1, 0)
            XCTAssertTrue(try f.catalog.unboundCaptures(limit: 8).isEmpty)
            XCTAssertTrue(try f.owner.publicationIntents(limit: 8).isEmpty)
            XCTAssertEqual(try f.integer("SELECT acknowledged_revision FROM collector_locators WHERE relative_path = 'one.jsonl'"), 0)
            await replicas.stop()
        }
    }

    func testPrivacyAndTransportDeferralsRemainIndependentOfDiskAdmission() async throws {
        for privacyWithheld in [false, true] {
            let probes = PublicationLocked(0)
            let f = try PublicationFixture(casTestHooks: .init(afterVolumeStat: { _, _ in
                probes.change { $0 += 1 }
                return 4096
            }))
            let replicas = try await replicas(for: f)
            var endpoints = replicas.endpoints
            if privacyWithheld {
                f.policy.change { $0 = try! .init(revision: 2, excludedProjectRoots: [f.project.path]) }
            } else {
                endpoints[0] = .init(replicaID: "hq", baseURL: endpoints[0].baseURL,
                    bearerToken: "synthetic-wrong-hq-token")
            }
            let requests = PublicationLocked(0)
            let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(beforeRequest: { _, _ in
                requests.change { $0 += 1 }
            })
            var budget = EngramCollectorCore.CollectorPublicationBudget()
            budget.minimumFreeDiskBytes = 1
            let worker = try f.worker(endpoints, budget: budget, hooks: hooks)
            let captured = try await worker.runOnce(now: 100)
            assertDiskObservation(captured.diskAdmission, threshold: 1, captureMinimum: 4096)
            XCTAssertEqual(captured.captured, 1)
            XCTAssertGreaterThan(captured.deferred, 0)
            XCTAssertEqual(captured.acknowledgedHQ, 0)
            XCTAssertEqual(captured.acknowledgedM1, privacyWithheld ? 0 : 1)
            if privacyWithheld { XCTAssertEqual(requests.value, 0) }
            else { XCTAssertGreaterThan(requests.value, 0) }
            XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_publication_replicas WHERE replica_id = 'hq' AND last_error = '\(privacyWithheld ? "privacyWithheld" : "unavailable")'"), 1)
            let backlogOnly = try await worker.runOnce(now: 200_000)
            XCTAssertEqual(backlogOnly.diskAdmission, .notEvaluated,
                "upload-only deferrals must not reuse an old successful disk sample")
            XCTAssertEqual(backlogOnly.captured, 0)
            XCTAssertGreaterThan(backlogOnly.deferred, 0)
            XCTAssertEqual(probes.value, 1, "upload retries must not introduce capture-admission probes")
            if privacyWithheld { XCTAssertEqual(requests.value, 0) }
            await replicas.stop()
        }
    }

    private func assertDiskObservation(
        _ status: EngramCollectorCore.CollectorDiskAdmissionStatus,
        threshold: Int64, captureMinimum: Int64?, inventoryBelowThreshold: Bool = false,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .observed(let actualThreshold, let inventory, let capture) = status else {
            XCTFail("expected this cycle's actual disk-admission observation", file: file, line: line)
            return
        }
        XCTAssertEqual(actualThreshold, threshold, file: file, line: line)
        guard let inventory else {
            XCTFail("inventory must be sampled before CAS", file: file, line: line)
            return
        }
        XCTAssertGreaterThanOrEqual(inventory, 0, file: file, line: line)
        if inventoryBelowThreshold { XCTAssertLessThan(inventory, threshold, file: file, line: line) }
        else { XCTAssertGreaterThanOrEqual(inventory, threshold, file: file, line: line) }
        XCTAssertEqual(capture, captureMinimum, file: file, line: line)
    }

    func testReservationEpochSequenceAndCanonicalIntentSurviveOwnerRestart() throws {
        let f = try PublicationFixture()
        defer { f.remove() }
        let prepared = try f.prepare()
        let reserved = prepared.reservation
        XCTAssertEqual(reserved.sequence, 1)
        XCTAssertNotNil(UUID(uuidString: reserved.sourceInstanceID))
        XCTAssertNotNil(UUID(uuidString: reserved.collectorEpoch))
        try f.reopen()
        XCTAssertEqual(try f.owner.captureReservations(limit: 8), [reserved])
        let intent = try XCTUnwrap(f.owner.finishCapture(reserved, configuration: f.configuration, capture: prepared.capture.capture))
        XCTAssertEqual(intent.publication.sequence, reserved.sequence)
        XCTAssertEqual(intent.publication.collectorEpoch, reserved.collectorEpoch)
        XCTAssertEqual(intent.publication.sourceInstanceID, reserved.sourceInstanceID)
        XCTAssertEqual(intent.canonicalBytes, try Canonical.encode(intent.publication))
        XCTAssertEqual(intent.digest, try intent.publication.sha256())
        XCTAssertNil(prepared.capture.manifest.sessionID)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_publication_replicas"), 2)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_capture_reservations"), 0)
        try f.reopen()
        XCTAssertEqual(try f.owner.publicationIntents(limit: 8), [intent])
        XCTAssertTrue(try f.owner.claimDirty(configuration: f.configuration, limit: 8, now: 2).isEmpty)
    }

    func testFinishTransactionFailureLeavesReservationAndNoHalfQueueOrDirtyACK() throws {
        let probe = PublicationProbe()
        let f = try PublicationFixture(probe: probe)
        defer { f.remove() }
        let prepared = try f.prepare()
        let before = try f.inventoryDigest()
        probe.action = { throw PublicationFixture.Failure.injected }
        XCTAssertThrowsError(try f.finish(prepared)) { XCTAssertEqual($0 as? PublicationFixture.Failure, .injected) }
        probe.action = nil
        XCTAssertEqual(try f.inventoryDigest(), before)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_publications"), 0)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_publication_replicas"), 0)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_capture_reservations"), 1)
        XCTAssertEqual(try f.integer("SELECT acknowledged_revision FROM collector_locators WHERE relative_path = 'one.jsonl'"), 0)
        _ = try f.finish(prepared)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_publication_replicas"), 2)
    }

    func testDuplicateCapturedGenerationReusesPublicationAndNewGenerationAdvancesSameStream() throws {
        let f = try PublicationFixture()
        defer { f.remove() }
        let first = try f.finish(f.prepare())
        try f.markDirty()
        let duplicate = try f.finish(f.prepare(markDirty: false))
        XCTAssertEqual(duplicate, first)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_publications"), 1)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_publication_replicas"), 2)
        try f.writeTranscript(text: "second-generation-is-longer")
        try f.markDirty()
        let next = try f.finish(f.prepare(markDirty: false))
        XCTAssertGreaterThan(next.publication.sequence, first.publication.sequence)
        XCTAssertEqual(next.publication.collectorEpoch, first.publication.collectorEpoch)
        XCTAssertEqual(next.publication.sourceInstanceID, first.publication.sourceInstanceID)
        XCTAssertNotEqual(next.digest, first.digest)
    }

    func testWrongAndMalformedACKsNeverMutateReplicaState() throws {
        let f = try PublicationFixture()
        defer { f.remove() }
        let intent = try f.finish(f.prepare())
        let claim = try XCTUnwrap(f.owner.claimPublications(replicaID: "hq", limit: 1, now: 10).first)
        let before = try f.inventoryDigest()
        for bytes in [
            try f.ack(intent, server: "m1"),
            try f.ack(intent, publicationDigest: String(repeating: "a", count: 64)),
            try f.ack(intent, manifestDigest: String(repeating: "b", count: 64)),
            Data("{\"schemaVersion\":1}".utf8),
            Data(repeating: 65, count: 4_097),
        ] {
            XCTAssertThrowsError(try f.owner.recordPublicationACK(claim, canonicalBytes: bytes))
            XCTAssertEqual(try f.inventoryDigest(), before)
        }
        XCTAssertTrue(try f.owner.recordPublicationACK(claim, canonicalBytes: f.ack(intent)))
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_publication_replicas WHERE state = 'acknowledged'"), 1)
        XCTAssertFalse(try f.owner.recordPublicationACK(claim, canonicalBytes: f.ack(intent)))
        try f.assertNoLegacyAuthority()
    }

    func testNewOwnerReclaimsInflightAndRejectsOldLateACKAndDeferral() throws {
        let f = try PublicationFixture()
        defer { f.remove() }
        let intent = try f.finish(f.prepare())
        let old = try XCTUnwrap(f.owner.claimPublications(replicaID: "hq", limit: 1, now: 10).first)
        try f.reopen()
        let current = try XCTUnwrap(f.owner.claimPublications(replicaID: "hq", limit: 1, now: 11).first)
        XCTAssertNotEqual(current.ownerRunID, old.ownerRunID)
        XCTAssertGreaterThan(current.claimGeneration, old.claimGeneration)
        let before = try f.inventoryDigest()
        XCTAssertFalse(try f.owner.recordPublicationACK(old, canonicalBytes: f.ack(intent)))
        XCTAssertFalse(try f.owner.deferPublication(old, now: 11, reason: .unavailable))
        XCTAssertEqual(try f.inventoryDigest(), before)
        XCTAssertTrue(try f.owner.recordPublicationACK(current, canonicalBytes: f.ack(intent)))
    }

    func testRetryIsReplicaIndependentBoundedAndNotClaimedBeforeDeadline() throws {
        let f = try PublicationFixture()
        defer { f.remove() }
        _ = try f.finish(f.prepare())
        var now: Int64 = 10
        for _ in 0..<22 {
            let claim = try XCTUnwrap(f.owner.claimPublications(replicaID: "hq", limit: 1, now: now).first)
            XCTAssertTrue(try f.owner.deferPublication(claim, now: now, reason: .unavailable))
            let deadline = try f.integer("SELECT retry_not_before FROM collector_publication_replicas WHERE replica_id = 'hq'")
            XCTAssertGreaterThan(deadline, now)
            XCTAssertLessThanOrEqual(deadline - now, 86_400)
            XCTAssertTrue(try f.owner.claimPublications(replicaID: "hq", limit: 1, now: deadline - 1).isEmpty)
            now = deadline
        }
        let m1 = try XCTUnwrap(f.owner.claimPublications(replicaID: "m1", limit: 1, now: 10).first)
        XCTAssertEqual(m1.attempts, 0)
        XCTAssertEqual(try f.integer("SELECT attempts FROM collector_publication_replicas WHERE replica_id = 'hq'"), 22)
    }

    func testPublicationInputBoundsFailBeforeAnyMutation() throws {
        let f = try PublicationFixture()
        defer { f.remove() }
        _ = try f.finish(f.prepare())
        let before = try f.inventoryDigest()
        for count in [-1, 0, 65] {
            XCTAssertThrowsError(try f.owner.claimPublications(replicaID: "hq", limit: count, now: 1))
            XCTAssertThrowsError(try f.owner.publicationIntents(limit: count))
            XCTAssertThrowsError(try f.owner.captureReservations(limit: count))
        }
        XCTAssertThrowsError(try f.owner.claimPublications(replicaID: "other", limit: 1, now: 1))
        XCTAssertThrowsError(try f.owner.claimPublications(replicaID: "hq", limit: 1, now: -1))
        XCTAssertEqual(try f.inventoryDigest(), before)
    }

    func testSequenceOverflowFailsClosedWithoutChangingEpochOrAcknowledgingDirtyWork() throws {
        let f = try PublicationFixture()
        defer { f.remove() }
        _ = try f.finish(f.prepare())
        try f.writeTranscript(text: "next-generation-after-sequence-exhaustion")
        try f.markDirty()
        let captured = try f.capture()
        let claim = try XCTUnwrap(f.owner.claimDirty(configuration: f.configuration, limit: 1, now: 2).first)
        try f.mutate("UPDATE collector_streams SET last_sequence = 9223372036854775807")
        let before = try f.inventoryDigest()
        XCTAssertThrowsError(try f.owner.reserveCapture(claim, configuration: f.configuration, generation: captured.manifest.generation)) {
            XCTAssertEqual($0 as? WorkerError, .sequenceExhausted)
        }
        XCTAssertEqual(try f.inventoryDigest(), before)
    }

    func testCancellationInsideFinishCommitRollsBackInsteadOfAcknowledgingCapture() async throws {
        let probe = PublicationProbe()
        let f = try PublicationFixture(probe: probe)
        defer { f.remove() }
        let prepared = try f.prepare()
        let before = try f.inventoryDigest()
        let task = Task {
            try withUnsafeCurrentTask { borrowed in
                probe.action = { borrowed?.cancel() }
                defer { probe.action = nil }
                return try f.finish(prepared)
            }
        }
        do { _ = try await task.value; XCTFail("cancelled transaction committed") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try f.inventoryDigest(), before)
    }

    func testStorageReplacementInFinishCommitRollsBackOriginalInventory() throws {
        let probe = PublicationProbe()
        let f = try PublicationFixture(probe: probe)
        defer { f.remove() }
        let prepared = try f.prepare()
        let before = try f.inventoryDigest()
        let lock = f.shadow.appendingPathComponent("collector-owner.lock")
        let saved = f.base.appendingPathComponent("saved-owner-lock")
        var moved = false
        probe.action = {
            try FileManager.default.moveItem(at: lock, to: saved)
            moved = true
            try Data().write(to: lock)
            XCTAssertEqual(chmod(lock.path, 0o600), 0)
        }
        XCTAssertThrowsError(try f.finish(prepared)) {
            XCTAssertEqual($0 as? EngramCollectorCore.CollectorInventoryOwnerError, .unsafePath)
        }
        probe.action = nil
        XCTAssertTrue(moved, "the injected filesystem boundary must actually execute")
        if moved {
            try FileManager.default.removeItem(at: lock)
            try FileManager.default.moveItem(at: saved, to: lock)
        }
        XCTAssertEqual(try f.inventoryDigest(), before)
    }

    func testClosedOwnerRejectsAllPublicationOperations() throws {
        let f = try PublicationFixture()
        defer { f.remove() }
        let prepared = try f.prepare()
        try f.owner.close()
        for operation in [
            { _ = try f.owner.captureReservations(limit: 1) },
            { _ = try f.owner.publicationIntents(limit: 1) },
            { _ = try f.owner.claimPublications(replicaID: "hq", limit: 1, now: 1) },
            { _ = try f.finish(prepared) },
        ] {
            XCTAssertThrowsError(try operation()) { XCTAssertEqual($0 as? EngramCollectorCore.CollectorInventoryOwnerError, .closed) }
        }
    }

    func testRealTwoHTTPReplicasAcceptExactBytesAndIndependentDurableACKs() async throws {
        let f = try PublicationFixture()
        let replicas = try await replicas(for: f)
        let before = try Data(contentsOf: f.source)
        let worker = try f.worker(replicas.endpoints)
        let cycle = try await worker.runOnce(now: 100)
        XCTAssertEqual(cycle.captured, 1)
        XCTAssertEqual(cycle.acknowledgedHQ, 1)
        XCTAssertEqual(cycle.acknowledgedM1, 1)
        let intent = try XCTUnwrap(f.owner.publicationIntents(limit: 8).first)
        for replica in replicas.all {
            let records = try await replica.publications()
            XCTAssertEqual(records.count, 1)
            XCTAssertEqual(records.first?["publicationSHA256"] as? String, intent.digest)
            let manifest = try await replica.get("/v2/archive/manifests/\(intent.publication.manifestSHA256)")
            let capture = try XCTUnwrap(f.catalog.capture(captureID: intent.captureID))
            XCTAssertEqual(manifest.0, capture.unboundManifestBytes)
            let decoded = try Canonical.decode(EngramCollectorCore.ArchiveSourceManifest.self, from: manifest.0)
            var restored = Data()
            for chunk in decoded.chunks {
                let object = try await replica.get("/v2/archive/objects/\(chunk.rawSHA256)")
                XCTAssertEqual(object.1, 200)
                restored.append(object.0)
            }
            XCTAssertEqual(restored, before)
        }
        XCTAssertEqual(try Data(contentsOf: f.source), before)
        try f.assertNoLegacyAuthority()
        try f.reopen()
        let resumed = try f.worker(replicas.endpoints)
        let resumedCycle = try await resumed.runOnce(now: 101)
        XCTAssertEqual(resumedCycle, .init())
        await replicas.stop()
    }

    func testHQFailureDoesNotBlockM1AndRestartRetriesOnlyHQ() async throws {
        let f = try PublicationFixture()
        let replicas = try await replicas(for: f)
        var endpoints = replicas.endpoints
        endpoints[0] = .init(replicaID: "hq", baseURL: endpoints[0].baseURL, bearerToken: "synthetic-wrong-hq-token")
        let first = try await f.worker(endpoints).runOnce(now: 100)
        XCTAssertEqual(first.acknowledgedHQ, 0)
        XCTAssertEqual(first.acknowledgedM1, 1)
        let firstM1 = try await replicas.m1.publications()
        let firstHQ = try await replicas.hq.publications()
        XCTAssertEqual(firstM1.count, 1)
        XCTAssertEqual(firstHQ.count, 0)
        try f.reopen()
        let requests = PublicationLocked<[String]>([])
        let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(beforeRequest: { id, path in requests.change { $0.append(id + path) } })
        let second = try await f.worker(replicas.endpoints, hooks: hooks).runOnce(now: 200_000)
        XCTAssertEqual(second.acknowledgedHQ, 1)
        XCTAssertEqual(second.acknowledgedM1, 0)
        XCTAssertFalse(requests.value.contains { $0.hasPrefix("m1") })
        await replicas.stop()
    }

    func testLostPublicationResponseRetriesIdenticalCanonicalIntentWithoutNewJournalEntry() async throws {
        let f = try PublicationFixture()
        let replicas = try await replicas(for: f)
        let dropped = PublicationLocked(false)
        let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(afterResponse: { id, path, bytes in
            if id == "hq", path.hasPrefix("/v2/archive/publications/") {
                dropped.change { $0 = true }
                throw WorkerError.transport
            }
            return bytes
        })
        let first = try await f.worker(replicas.endpoints, hooks: hooks).runOnce(now: 100)
        XCTAssertTrue(dropped.value, "drop occurs after the real server committed")
        XCTAssertEqual(first.acknowledgedHQ, 0)
        XCTAssertEqual(first.acknowledgedM1, 1)
        let intent = try XCTUnwrap(f.owner.publicationIntents(limit: 8).first)
        let accepted = try await replicas.hq.publications()
        XCTAssertEqual(accepted.count, 1)
        let ordinal = accepted.first?["arrivalOrdinal"] as? Int
        try f.reopen()
        _ = try await f.worker(replicas.endpoints).runOnce(now: 200_000)
        XCTAssertEqual(try f.owner.publicationIntents(limit: 8), [intent])
        let retried = try await replicas.hq.publications()
        XCTAssertEqual(retried.count, 1)
        XCTAssertEqual(retried.first?["arrivalOrdinal"] as? Int, ordinal)
        XCTAssertEqual(retried.first?["publicationSHA256"] as? String, intent.digest)
        await replicas.stop()
    }

    func testTamperedActualHTTPACKNeverMarksHQSuccessful() async throws {
        for field in ["serverID", "publicationSHA256", "manifestSHA256", "malformed"] {
            let f = try PublicationFixture()
            let replicas = try await replicas(for: f)
            let tampered = PublicationLocked(false)
            let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(afterResponse: { id, path, bytes in
                guard id == "hq", path.hasPrefix("/v2/archive/publications/") else { return bytes }
                tampered.change { $0 = true }
                if field == "malformed" { return Data("not-json".utf8) }
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                object[field] = field == "serverID" ? "m1" : String(repeating: "f", count: 64)
                return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            })
            let cycle = try await f.worker(replicas.endpoints, hooks: hooks).runOnce(now: 100)
            XCTAssertTrue(tampered.value)
            XCTAssertEqual(cycle.acknowledgedHQ, 0)
            XCTAssertEqual(cycle.acknowledgedM1, 1)
            XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_publication_replicas WHERE replica_id = 'hq' AND state = 'acknowledged'"), 0)
            await replicas.stop()
        }
    }

    func testActualHTTPResponseBudgetIsEnforced() async throws {
        let f = try PublicationFixture()
        let replicas = try await replicas(for: f)
        var budget = EngramCollectorCore.CollectorPublicationBudget()
        budget.maxResponseBytes = 32
        let cycle = try await f.worker(replicas.endpoints, budget: budget).runOnce(now: 100)
        XCTAssertEqual(cycle.acknowledgedHQ + cycle.acknowledgedM1, 0)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_publication_replicas WHERE state = 'acknowledged'"), 0)
        await replicas.stop()
    }

    func testUnsupportedPublicationCapabilityRetainsHQBacklogWithoutLegacyFallback() async throws {
        let f = try PublicationFixture()
        let replicas = try await replicas(for: f, hqPublicationsEnabled: false)
        let paths = PublicationLocked<[String]>([])
        let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(beforeRequest: { id, path in if id == "hq" { paths.change { $0.append(path) } } })
        let cycle = try await f.worker(replicas.endpoints, hooks: hooks).runOnce(now: 100)
        XCTAssertEqual(cycle.acknowledgedHQ, 0)
        XCTAssertEqual(cycle.acknowledgedM1, 1)
        XCTAssertEqual(paths.value, ["/v2/archive/publication-capabilities"])
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_publication_replicas WHERE replica_id = 'hq' AND state != 'acknowledged'"), 1)
        try f.assertNoLegacyAuthority()
        await replicas.stop()
    }

    func testExcludedUnknownAndAmbiguousCapturesAreRetainedWithZeroOutboundRequests() async throws {
        for variant in 0..<3 {
            let f = try PublicationFixture()
            let replicas = try await replicas(for: f)
            if variant == 0 { f.policy.change { $0 = try! .init(revision: 2, excludedProjectRoots: [f.project.path]) } }
            if variant == 1 { try f.writeBytes(Data("{\"type\":\"unrecognized\"}\n".utf8)) }
            if variant == 2 { try f.writeBytes(try f.transcript() + f.transcript(cwd: f.base.appendingPathComponent("other-project").path)) }
            let requests = PublicationLocked(0)
            let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(beforeRequest: { _, _ in requests.change { $0 += 1 } })
            let raw = try Data(contentsOf: f.source)
            let cycle = try await f.worker(replicas.endpoints, hooks: hooks).runOnce(now: 100)
            XCTAssertEqual(cycle.captured, 1)
            XCTAssertEqual(cycle.acknowledgedHQ + cycle.acknowledgedM1, 0)
            XCTAssertEqual(requests.value, 0)
            XCTAssertEqual(try Data(contentsOf: f.source), raw)
            XCTAssertEqual(try f.owner.publicationIntents(limit: 8).count, 1)
            let hqRecords = try await replicas.hq.publications()
            let m1Records = try await replicas.m1.publications()
            XCTAssertEqual(hqRecords.count, 0)
            XCTAssertEqual(m1Records.count, 0)
            await replicas.stop()
        }
    }

    func testPolicyIsRefreshedImmediatelyBeforeEveryHTTPStage() async throws {
        for blockedPrefix in ["/v2/archive/publication-capabilities", "/v2/archive/objects/", "/v2/archive/manifests/", "/v2/archive/publications/"] {
            let f = try PublicationFixture()
            let replicas = try await replicas(for: f)
            let reached = PublicationLocked(false)
            let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(beforeRequest: { id, path in
                if id == "hq", path.hasPrefix(blockedPrefix) {
                    reached.change { $0 = true }
                    f.policy.change { $0 = try! .init(revision: 2, excludedProjectRoots: [f.project.path]) }
                }
            })
            let cycle = try await f.worker(replicas.endpoints, hooks: hooks).runOnce(now: 100)
            XCTAssertTrue(reached.value, blockedPrefix)
            XCTAssertEqual(cycle.acknowledgedHQ, 0)
            let hqRecords = try await replicas.hq.publications()
            XCTAssertEqual(hqRecords.count, 0)
            let intent = try XCTUnwrap(f.owner.publicationIntents(limit: 8).first)
            if blockedPrefix != "/v2/archive/publications/" {
                let manifest = try await replicas.hq.get("/v2/archive/manifests/\(intent.publication.manifestSHA256)")
                XCTAssertEqual(manifest.1, 404)
            }
            if blockedPrefix == "/v2/archive/publication-capabilities" || blockedPrefix == "/v2/archive/objects/" {
                let capture = try XCTUnwrap(f.catalog.capture(captureID: intent.captureID))
                let manifest = try Canonical.decode(EngramCollectorCore.ArchiveSourceManifest.self, from: capture.unboundManifestBytes)
                XCTAssertFalse(manifest.chunks.isEmpty, "the object-leak control needs actual captured bytes")
                for chunk in manifest.chunks {
                    let object = try await replicas.hq.get("/v2/archive/objects/\(chunk.rawSHA256)")
                    XCTAssertEqual(object.1, 404, "privacy withdrawal must prevent the raw object PUT, not only its publication")
                }
            }
            XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_publication_replicas WHERE replica_id = 'hq' AND last_error = 'privacyWithheld'"), 1)
            await replicas.stop()
        }
    }

    func testCrashAfterCaptureRecoversReservedGenerationNotChangedSourceBytes() async throws {
        let f = try PublicationFixture()
        let replicas = try await replicas(for: f)
        let original = try Data(contentsOf: f.source)
        let captured = PublicationLocked<CaptureResult?>(nil)
        let beforeCaptureReached = PublicationLocked(false)
        let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(beforeCapture: { reservation in
            beforeCaptureReached.change { $0 = true }
            XCTAssertEqual(try f.owner.captureReservations(limit: 8), [reservation])
            XCTAssertEqual(reservation.generation.size, Int64(original.count))
            XCTAssertTrue(try f.catalog.unboundCaptures(limit: 1).isEmpty,
                          "ordering intent must already be durable before the capture writer records any generation")
        }, afterCapture: { value in
            XCTAssertTrue(beforeCaptureReached.value)
            captured.change { $0 = value }
            XCTAssertEqual(try f.catalog.capture(captureID: value.capture.captureID), value.capture)
            XCTAssertEqual(try f.owner.captureReservations(limit: 8).count, 1)
            throw PublicationFixture.Failure.injected
        })
        do { _ = try await f.worker(replicas.endpoints, hooks: hooks).runOnce(now: 100); XCTFail("crash injection was ignored") }
        catch { XCTAssertEqual(error as? PublicationFixture.Failure, .injected) }
        let durable = try XCTUnwrap(captured.value)
        XCTAssertEqual(try f.owner.publicationIntents(limit: 8).count, 0)
        let reservation = try XCTUnwrap(f.owner.captureReservations(limit: 8).first)
        try f.writeTranscript(text: "new-live-generation-not-the-reserved-capture", cwd: f.base.appendingPathComponent("excluded").path)
        try f.markDirty()
        try f.reopen()
        var budget = EngramCollectorCore.CollectorPublicationBudget()
        budget.maxCaptureFiles = 0
        let cycle = try await f.worker(replicas.endpoints, budget: budget).runOnce(now: 200)
        XCTAssertEqual(cycle.recovered, 1)
        XCTAssertEqual(cycle.captured, 0)
        XCTAssertEqual(cycle.acknowledgedHQ, 1)
        XCTAssertEqual(cycle.acknowledgedM1, 1)
        let intent = try XCTUnwrap(f.owner.publicationIntents(limit: 8).first)
        XCTAssertEqual(intent.captureID, durable.capture.captureID)
        XCTAssertEqual(intent.publication.sequence, reservation.sequence)
        XCTAssertEqual(intent.publication.collectorEpoch, reservation.collectorEpoch)
        var restored = Data()
        for chunk in durable.manifest.chunks { restored.append(try await replicas.hq.get("/v2/archive/objects/\(chunk.rawSHA256)").0) }
        XCTAssertEqual(restored, original)
        XCTAssertNotEqual(try Data(contentsOf: f.source), original)
        XCTAssertFalse(try f.owner.claimDirty(configuration: f.configuration, limit: 8, now: 201).isEmpty,
                       "recovering old dirty revision must retain the newer event")
        await replicas.stop()
    }

    func testCancellationAfterActualACKLeavesReplayableBacklog() async throws {
        let f = try PublicationFixture()
        let replicas = try await replicas(for: f)
        let reached = PublicationLocked(false)
        let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(beforeACKCommit: { claim in
            if claim.replicaID == "hq" {
                reached.change { $0 = true }
                throw CancellationError()
            }
        })
        do { _ = try await f.worker(replicas.endpoints, hooks: hooks).runOnce(now: 100); XCTFail("cancellation became a success") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(reached.value)
        let cancelledRecords = try await replicas.hq.publications()
        XCTAssertEqual(cancelledRecords.count, 1)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_publication_replicas WHERE replica_id = 'hq' AND state = 'acknowledged'"), 0)
        let intent = try XCTUnwrap(f.owner.publicationIntents(limit: 8).first)
        try f.reopen()
        _ = try await f.worker(replicas.endpoints).runOnce(now: 200_000)
        XCTAssertEqual(try f.owner.publicationIntents(limit: 8), [intent])
        let replayedRecords = try await replicas.hq.publications()
        XCTAssertEqual(replayedRecords.count, 1)
        await replicas.stop()
    }

    func testMissingCASObjectRetainsBacklogAndMakesNoHTTPRequests() async throws {
        let f = try PublicationFixture()
        let replicas = try await replicas(for: f)
        let prepared = try f.prepare()
        _ = try f.finish(prepared)
        let digest = try XCTUnwrap(prepared.capture.manifest.chunks.first).rawSHA256
        let object = f.captureRoot.appendingPathComponent("objects/sha256/\(digest.prefix(2))/\(digest)")
        try FileManager.default.removeItem(at: object)
        let requests = PublicationLocked(0)
        let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(beforeRequest: { _, _ in requests.change { $0 += 1 } })
        let cycle = try await f.worker(replicas.endpoints, hooks: hooks).runOnce(now: 100)
        XCTAssertEqual(cycle.acknowledgedHQ + cycle.acknowledgedM1, 0)
        XCTAssertEqual(requests.value, 0)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_publication_replicas"), 2)
        await replicas.stop()
    }

    func testCaptureByteAndDiskBudgetsDoNotCreatePartialCaptureOrAcknowledgeDirty() async throws {
        for diskPressure in [false, true] {
            let f = try PublicationFixture()
            let replicas = try await replicas(for: f)
            var budget = EngramCollectorCore.CollectorPublicationBudget()
            if diskPressure { budget.minimumFreeDiskBytes = Int64.max }
            else { budget.maxCaptureBytes = 1 }
            let cycle = try await f.worker(replicas.endpoints, budget: budget).runOnce(now: 100)
            XCTAssertEqual(cycle.captured, 0)
            XCTAssertTrue(try f.owner.publicationIntents(limit: 8).isEmpty)
            XCTAssertEqual(try f.integer("SELECT acknowledged_revision FROM collector_locators WHERE relative_path = 'one.jsonl'"), 0)
            await replicas.stop()
        }
    }

    func testOldRevisionReservationsDoNotStarveCurrentRevisionRecovery() async throws {
        let f = try PublicationFixture()
        let replicas = try await replicas(for: f)
        let capture = try f.capture()
        var current: EngramCollectorCore.CollectorCaptureReservation?
        for revision in 1...65 {
            if revision > 1 {
                f.rootRevision = Int64(revision)
                _ = try f.owner.enrollAndActivateRoot(f.configuration)
                try f.markDirty()
            }
            let claim = try XCTUnwrap(f.owner.claimDirty(configuration: f.configuration, limit: 1, now: 1).first)
            current = try XCTUnwrap(f.owner.reserveCapture(claim, configuration: f.configuration,
                generation: capture.manifest.generation))
        }
        let reserved = try XCTUnwrap(current)
        XCTAssertEqual(reserved.rootRevision, 65)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_capture_reservations WHERE root_revision < 65"), 64)
        try f.reopen()
        var budget = EngramCollectorCore.CollectorPublicationBudget()
        budget.maxCaptureFiles = 0
        let cycle = try await f.worker(replicas.endpoints, budget: budget).runOnce(now: 100)
        XCTAssertEqual(cycle.recovered, 1, "old revisions must not consume the entire bounded recovery window")
        XCTAssertEqual(cycle.captured, 0)
        XCTAssertEqual(cycle.acknowledgedHQ, 1)
        XCTAssertEqual(cycle.acknowledgedM1, 1)
        let intents = try f.owner.publicationIntents(limit: 8)
        XCTAssertEqual(intents.count, 1)
        XCTAssertEqual(intents.first?.rootRevision, 65)
        XCTAssertEqual(intents.first?.captureID, capture.capture.captureID)
        XCTAssertEqual(intents.first?.publication.sequence, reserved.sequence)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_capture_reservations WHERE root_revision = 65"), 0)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_capture_reservations WHERE root_revision < 65"), 64,
                       "recovery must fence old reservations without deleting their durable evidence")
        await replicas.stop()
    }

    func testLiveAppendAfterStableCapturePublishesReservedGenerationAndRetainsDirty() async throws {
        let fixture = PublicationLocked<PublicationFixture?>(nil)
        let appended = PublicationLocked(false)
        let casHooks = EngramCollectorCore.ImmutableArchiveCASTestHooks(afterFinalLinkPublished: { url in
            guard url.pathExtension == "json", !appended.value, let f = fixture.value else { return }
            // Manifest publication is after the capturer's stable-FD read and
            // final generation check. Catalog commit follows before it returns.
            // This existing CAS hook needs no timing race or production changes.
            let handle = try FileHandle(forWritingTo: f.source)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"later append\"}}\n".utf8))
            try handle.synchronize()
            try f.markDirty()
            appended.change { $0 = true }
        })
        let f = try PublicationFixture(casTestHooks: casHooks)
        fixture.change { $0 = f }
        defer { fixture.change { $0 = nil } }
        let replicas = try await replicas(for: f)
        let original = try Data(contentsOf: f.source)
        let cycle = try await f.worker(replicas.endpoints).runOnce(now: 100)
        XCTAssertTrue(appended.value, "the stable-capture/live-append boundary must actually execute")
        let durable = try XCTUnwrap(f.catalog.unboundCaptures(limit: 8).first)
        XCTAssertEqual(durable.rawByteCount, Int64(original.count))
        XCTAssertEqual(durable.generation.size, Int64(original.count))
        XCTAssertNotEqual(try Data(contentsOf: f.source), original)
        XCTAssertEqual(cycle.captured, 1)
        XCTAssertEqual(cycle.acknowledgedHQ, 1)
        XCTAssertEqual(cycle.acknowledgedM1, 1)
        let pending = try f.owner.claimDirty(configuration: f.configuration, limit: 8, now: 101)
        XCTAssertEqual(pending.first?.dirtyRevision, 2, "publication of the old generation must not erase the appended event")
        let intents = try f.owner.publicationIntents(limit: 8)
        XCTAssertEqual(intents.count, 1, "an already durable generation must retain its publication entry")
        XCTAssertEqual(intents.first?.captureID, durable.captureID)
        XCTAssertEqual(intents.first?.publication.sequence, 1)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_capture_reservations"), 0)
        if let intent = intents.first {
            for replica in replicas.all {
                let manifest = try await replica.get("/v2/archive/manifests/\(intent.publication.manifestSHA256)")
                XCTAssertEqual(manifest.0, durable.unboundManifestBytes)
                let decoded = try Canonical.decode(EngramCollectorCore.ArchiveSourceManifest.self, from: manifest.0)
                var restored = Data()
                for chunk in decoded.chunks { restored.append(try await replica.get("/v2/archive/objects/\(chunk.rawSHA256)").0) }
                XCTAssertEqual(restored, original)
            }
        }
        await replicas.stop()
    }

    func testRecaptureAfterNegativeRecoveryRefreshesBoundaryBeforeCrash() async throws {
        let f = try PublicationFixture()
        let replicas = try await replicas(for: f)
        _ = try f.capture()
        try f.writeTranscript(text: "unrelated-older-generation-with-a-different-size")
        _ = try f.capture()
        let oldBoundary = try XCTUnwrap(f.catalog.unboundCaptureBoundary())
        XCTAssertEqual(try f.catalog.unboundCaptures(limit: 8).count, 2)
        try f.writeTranscript(text: "reserved-generation-to-be-captured-after-negative-recovery")
        try f.markDirty()
        let beforeCapture = EngramCollectorCore.CollectorPublicationWorkerTestHooks(beforeCapture: { _ in
            throw PublicationFixture.Failure.injected
        })
        do { _ = try await f.worker(replicas.endpoints, hooks: beforeCapture).runOnce(now: 100); XCTFail("reservation interruption ignored") }
        catch { XCTAssertEqual(error as? PublicationFixture.Failure, .injected) }
        let reserved = try XCTUnwrap(f.owner.captureReservations(limit: 8).first)
        var budget = EngramCollectorCore.CollectorPublicationBudget()
        budget.maxCaptureFiles = 0
        budget.maxRecoveryCandidates = 1
        let firstPage = try await f.worker(replicas.endpoints, budget: budget).runOnce(now: 101)
        XCTAssertEqual(firstPage.recovered, 0)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_capture_reservations WHERE recovery_state IS NOT NULL"), 1,
                       "the regression requires a real persisted multi-page checkpoint")
        let captured = PublicationLocked<CaptureResult?>(nil)
        let afterCapture = EngramCollectorCore.CollectorPublicationWorkerTestHooks(afterCapture: { value in
            captured.change { $0 = value }
            XCTAssertEqual(try f.catalog.capture(captureID: value.capture.captureID), value.capture)
            throw PublicationFixture.Failure.injected
        })
        budget.maxCaptureFiles = 1
        do { _ = try await f.worker(replicas.endpoints, budget: budget, hooks: afterCapture).runOnce(now: 102); XCTFail("durable recapture interruption ignored") }
        catch { XCTAssertEqual(error as? PublicationFixture.Failure, .injected) }
        let durable = try XCTUnwrap(captured.value)
        XCTAssertTrue(durable.capture.capturedAt > oldBoundary.capturedAt
            || (durable.capture.capturedAt == oldBoundary.capturedAt && durable.capture.captureID > oldBoundary.captureID),
            "the actual newly committed capture must be beyond the old frozen catalog boundary")
        XCTAssertEqual(try f.owner.captureReservations(limit: 8), [reserved])
        XCTAssertTrue(try f.owner.publicationIntents(limit: 8).isEmpty)
        try f.writeTranscript(text: "later-live-generation-that-must-not-replace-the-durable-recapture")
        try f.markDirty()
        try f.reopen()
        budget.maxRecoveryCandidates = 8
        let recovered = try await f.worker(replicas.endpoints, budget: budget).runOnce(now: 200)
        XCTAssertEqual(recovered.recovered, 1)
        XCTAssertEqual(recovered.captured, 0)
        XCTAssertEqual(recovered.acknowledgedHQ, 1)
        XCTAssertEqual(recovered.acknowledgedM1, 1)
        let intents = try f.owner.publicationIntents(limit: 8)
        XCTAssertEqual(intents.count, 1)
        XCTAssertEqual(intents.first?.captureID, durable.capture.captureID)
        XCTAssertEqual(intents.first?.publication.sequence, reserved.sequence)
        let pending = try f.owner.claimDirty(configuration: f.configuration, limit: 8, now: 201)
        XCTAssertEqual(pending.first?.dirtyRevision, reserved.dirtyRevision + 1)
        await replicas.stop()
    }

    func testMissingUncapturedSourceDoesNotStarveAnotherDirtyFileInRoot() async throws {
        let f = try PublicationFixture()
        let replicas = try await replicas(for: f)
        var budget = EngramCollectorCore.CollectorPublicationBudget()
        budget.maxCaptureFiles = 1
        let interrupted = EngramCollectorCore.CollectorPublicationWorkerTestHooks(beforeCapture: { _ in
            throw PublicationFixture.Failure.injected
        })
        do { _ = try await f.worker(replicas.endpoints, budget: budget, hooks: interrupted).runOnce(now: 100); XCTFail("reservation interruption ignored") }
        catch { XCTAssertEqual(error as? PublicationFixture.Failure, .injected) }
        XCTAssertEqual(try f.owner.captureReservations(limit: 8).count, 1)
        XCTAssertTrue(try f.catalog.unboundCaptures(limit: 8).isEmpty)
        try FileManager.default.removeItem(at: f.source)
        let other = f.sourceRoot.appendingPathComponent("two.jsonl")
        try f.transcript(text: "another-live-source-in-the-same-root").write(to: other)
        XCTAssertEqual(chmod(other.path, 0o600), 0)
        try f.markDirty(relativePath: "two.jsonl")
        var captured = 0
        var acknowledgedHQ = 0
        var acknowledgedM1 = 0
        let worker = try f.worker(replicas.endpoints, budget: budget)
        for now: Int64 in [101, 102, 103] {
            let cycle = try await worker.runOnce(now: now)
            captured += cycle.captured
            acknowledgedHQ += cycle.acknowledgedHQ
            acknowledgedM1 += cycle.acknowledgedM1
        }
        XCTAssertEqual(captured, 1, "an absent uncaptured file must not reserve its entire root forever")
        XCTAssertEqual(acknowledgedHQ, 1)
        XCTAssertEqual(acknowledgedM1, 1)
        let intents = try f.owner.publicationIntents(limit: 8)
        XCTAssertEqual(intents.count, 1)
        XCTAssertEqual(intents.first?.relativePath, "two.jsonl")
        XCTAssertEqual(try f.integer("SELECT acknowledged_revision FROM collector_locators WHERE relative_path = 'one.jsonl'"), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.source.path))
        await replicas.stop()
    }

    func testEndpointConfigurationRejectsCredentialAndOriginAliasing() throws {
        let f = try PublicationFixture()
        defer { f.remove() }
        let good: [EngramCollectorCore.CollectorReplicaEndpoint] = [
            .init(replicaID: "hq", baseURL: URL(string: "https://hq.example")!, bearerToken: "hq-test"),
            .init(replicaID: "m1", baseURL: URL(string: "https://m1.example")!, bearerToken: "m1-test"),
        ]
        for invalid in [
            [good[0]],
            [good[0], good[0]],
            [good[0], .init(replicaID: "m1", baseURL: good[0].baseURL, bearerToken: "m1-test")],
            [good[0], .init(replicaID: "m1", baseURL: good[1].baseURL, bearerToken: "hq-test")],
            [good[0], .init(replicaID: "m1", baseURL: URL(string: "http://public.example")!, bearerToken: "m1-test")],
            [good[0], .init(replicaID: "m1", baseURL: URL(string: "https://user:pass@m1.example")!, bearerToken: "m1-test")],
            [good[0], .init(replicaID: "m1", baseURL: good[1].baseURL, bearerToken: "bad\r\nHeader: value")],
        ] {
            XCTAssertThrowsError(try f.worker(invalid)) { XCTAssertEqual($0 as? WorkerError, .invalidConfiguration) }
        }
    }

    func testFDAdmissionRejectsChangedSecondGenerationBeforeAnyAdditionalCASWrite() async throws {
        for growsBeyondRemainingBudget in [false, true] {
            let publishedObjects = PublicationLocked(0)
            let casHooks = EngramCollectorCore.ImmutableArchiveCASTestHooks(afterFinalLinkPublished: { url in
                if url.pathExtension != "json" { publishedObjects.change { $0 += 1 } }
            })
            let f = try PublicationFixture(casTestHooks: casHooks)
            let replicas = try await replicas(for: f)
            let original = try Data(contentsOf: f.source)
            let second = f.sourceRoot.appendingPathComponent("two.jsonl")
            try original.write(to: second)
            XCTAssertEqual(chmod(second.path, 0o600), 0)
            try f.markDirty(relativePath: "two.jsonl")
            var budget = EngramCollectorCore.CollectorPublicationBudget()
            budget.maxCaptureFiles = 2
            budget.maxCaptureBytes = Int64(original.count * 2)
            let reached = PublicationLocked(false)
            let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(beforeCaptureFDAdmission: { reservation in
                guard reservation.relativePath == "two.jsonl" else { return }
                // The first file already consumed N of the 2N cycle budget.
                // Mutate the second only after its final path preflight, but
                // before the actual capturer opens and admits its descriptor.
                let text = growsBeyondRemainingBudget
                    ? String(repeating: "x", count: original.count / 2 + "synthetic capture".utf8.count)
                    : "different capture"
                let changed = try f.transcript(text: text)
                if growsBeyondRemainingBudget {
                    XCTAssertGreaterThan(changed.count, original.count)
                    XCTAssertLessThan(changed.count, original.count * 2)
                } else { XCTAssertEqual(changed.count, original.count) }
                try changed.write(to: second)
                XCTAssertEqual(chmod(second.path, 0o600), 0)
                try f.markDirty(relativePath: "two.jsonl")
                reached.change { $0 = true }
            })
            let cycle = try await f.worker(replicas.endpoints, budget: budget, hooks: hooks).runOnce(now: 100)
            XCTAssertTrue(reached.value, "the actual preflight-to-FD gap must be exercised")
            XCTAssertEqual(cycle.captured, 1)
            XCTAssertEqual(cycle.acknowledgedHQ, 1)
            XCTAssertEqual(cycle.acknowledgedM1, 1)
            let durable = try f.catalog.unboundCaptures(limit: 8)
            XCTAssertEqual(durable.count, 1, "FD admission must reject the changed generation before catalog commit")
            XCTAssertEqual(durable.first?.locator, f.source.path)
            XCTAssertEqual(publishedObjects.value, 1, "only the already admitted first source may publish CAS bytes")
            XCTAssertEqual(try f.owner.publicationIntents(limit: 8).count, 1)
            XCTAssertEqual(try f.integer("SELECT acknowledged_revision FROM collector_locators WHERE relative_path = 'two.jsonl'"), 0)
            await replicas.stop()
        }
    }

    func testCASVolumePressureBlocksCaptureEvenWhenOwnerVolumeHasSpace() async throws {
        let fixture = PublicationLocked<PublicationFixture?>(nil)
        let queried = PublicationLocked(0)
        let casHooks = EngramCollectorCore.ImmutableArchiveCASTestHooks(afterVolumeStat: { descriptor, measured in
            guard let f = fixture.value else { throw PublicationFixture.Failure.unsafeFixture }
            var opened = stat()
            var actualCAS = stat()
            var volume = statfs()
            XCTAssertEqual(fstat(descriptor, &opened), 0)
            XCTAssertEqual(lstat(f.captureRoot.path, &actualCAS), 0)
            XCTAssertEqual(fstatfs(descriptor, &volume), 0)
            XCTAssertEqual(opened.st_dev, actualCAS.st_dev)
            XCTAssertEqual(opened.st_ino, actualCAS.st_ino)
            XCTAssertGreaterThanOrEqual(measured, 0)
            queried.change { $0 += 1 }
            return 0
        })
        let f = try PublicationFixture(casTestHooks: casHooks)
        fixture.change { $0 = f }
        defer { fixture.change { $0 = nil } }
        let replicas = try await replicas(for: f)
        XCTAssertNotEqual(f.shadow.path, f.captureRoot.path)
        var budget = EngramCollectorCore.CollectorPublicationBudget()
        budget.minimumFreeDiskBytes = 1
        XCTAssertGreaterThan(try f.owner.availableSpoolBytes(), budget.minimumFreeDiskBytes,
            "the owner volume must independently pass admission in this fixture")
        let requests = PublicationLocked(0)
        let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(beforeRequest: { _, _ in
            requests.change { $0 += 1 }
        })
        let original = try Data(contentsOf: f.source)
        let cycle = try await f.worker(replicas.endpoints, budget: budget, hooks: hooks).runOnce(now: 100)
        XCTAssertGreaterThan(queried.value, 0, "budget admission must query the actual CAS root descriptor")
        XCTAssertEqual(cycle.captured, 0)
        XCTAssertEqual(cycle.acknowledgedHQ + cycle.acknowledgedM1, 0)
        XCTAssertEqual(requests.value, 0)
        XCTAssertTrue(try f.catalog.unboundCaptures(limit: 8).isEmpty)
        XCTAssertTrue(try f.owner.publicationIntents(limit: 8).isEmpty)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_capture_reservations"), 0)
        XCTAssertEqual(try f.integer("SELECT acknowledged_revision FROM collector_locators WHERE relative_path = 'one.jsonl'"), 0)
        XCTAssertEqual(try Data(contentsOf: f.source), original)
        await replicas.stop()
    }

    func testMissingIntermediateDirectoryDoesNotStarveAnotherDirtyFileInRoot() async throws {
        let f = try PublicationFixture()
        let replicas = try await replicas(for: f)
        let original = try Data(contentsOf: f.source)
        let nested = f.sourceRoot.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let nestedSource = nested.appendingPathComponent("one.jsonl")
        try original.write(to: nestedSource)
        XCTAssertEqual(chmod(nestedSource.path, 0o600), 0)
        try f.markDirty(relativePath: "nested/one.jsonl")
        try FileManager.default.removeItem(at: f.source)
        var budget = EngramCollectorCore.CollectorPublicationBudget()
        budget.maxCaptureFiles = 1
        let interrupted = EngramCollectorCore.CollectorPublicationWorkerTestHooks(beforeCapture: { reservation in
            XCTAssertEqual(reservation.relativePath, "nested/one.jsonl")
            throw PublicationFixture.Failure.injected
        })
        do { _ = try await f.worker(replicas.endpoints, budget: budget, hooks: interrupted).runOnce(now: 100); XCTFail("nested reservation interruption ignored") }
        catch { XCTAssertEqual(error as? PublicationFixture.Failure, .injected) }
        XCTAssertEqual(try f.owner.captureReservations(limit: 8).first?.relativePath, "nested/one.jsonl")
        XCTAssertTrue(try f.catalog.unboundCaptures(limit: 8).isEmpty)
        // Removing the intermediate directory exercises openComponent ENOENT,
        // not the separate final-leaf POSIX ENOENT regression above.
        try FileManager.default.removeItem(at: nested)
        let other = f.sourceRoot.appendingPathComponent("two.jsonl")
        try original.write(to: other)
        XCTAssertEqual(chmod(other.path, 0o600), 0)
        try f.markDirty(relativePath: "two.jsonl")
        let worker = try f.worker(replicas.endpoints, budget: budget)
        var captured = 0
        var acknowledgedHQ = 0
        var acknowledgedM1 = 0
        for now: Int64 in [101, 102, 103, 104, 105] {
            let cycle = try await worker.runOnce(now: now)
            captured += cycle.captured
            acknowledgedHQ += cycle.acknowledgedHQ
            acknowledgedM1 += cycle.acknowledgedM1
        }
        XCTAssertEqual(captured, 1, "a missing intermediate directory must not pin its root's reservation")
        XCTAssertEqual(acknowledgedHQ, 1)
        XCTAssertEqual(acknowledgedM1, 1)
        let intents = try f.owner.publicationIntents(limit: 8)
        XCTAssertEqual(intents.count, 1)
        XCTAssertEqual(intents.first?.relativePath, "two.jsonl")
        XCTAssertEqual(try f.integer("SELECT acknowledged_revision FROM collector_locators WHERE relative_path = 'nested/one.jsonl'"), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: nested.path))
        await replicas.stop()
    }

    private func replicas(for fixture: PublicationFixture, hqPublicationsEnabled: Bool = true) async throws -> PublicationReplicas {
        do {
            let replicas = try await PublicationReplicas.start(in: fixture.base, hqPublicationsEnabled: hqPublicationsEnabled)
            // Async teardown runs even when the notImplemented RED path throws.
            // Join both actual server tasks before removing their owned stores.
            addTeardownBlock {
                await replicas.stop()
                fixture.remove()
            }
            return replicas
        } catch {
            fixture.remove()
            throw error
        }
    }
}

private final class PublicationLocked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func change(_ body: (inout Value) -> Void) { lock.lock(); defer { lock.unlock() }; body(&stored) }
}

private final class PublicationProbe {
    var action: (() throws -> Void)?
}

private final class PublicationFixture: @unchecked Sendable {
    enum Failure: Error, Equatable { case injected, unsafeFixture }
    static let machine = "11111111-2222-3333-4444-555555555555"
    let base: URL
    let shadow: URL
    let captureRoot: URL
    let identity: URL
    let sourceRoot: URL
    let project: URL
    let source: URL
    let catalog: EngramCollectorCore.ArchiveCatalog
    let cas: EngramCollectorCore.ImmutableArchiveCAS
    let policy: PublicationLocked<EngramCollectorCore.CollectorPrivacyPolicy>
    let probe: PublicationProbe
    var owner: EngramCollectorCore.CollectorInventoryOwner!
    var rootRevision: Int64 = 1
    var configuration: EngramCollectorCore.CollectorRootConfiguration {
        .init(rootID: "synthetic-codex-root", source: .codex, rootPath: sourceRoot.path, revision: rootRevision)
    }
    var inventory: URL { shadow.appendingPathComponent("inventory/inventory.sqlite") }

    init(probe: PublicationProbe = .init(), casTestHooks: EngramCollectorCore.ImmutableArchiveCASTestHooks = .init()) throws {
        if let expectedHome = ProcessInfo.processInfo.environment["ENGRAM_DEMO_EXPECTED_HOME"] {
            guard FileManager.default.homeDirectoryForCurrentUser.path == expectedHome else {
                throw Failure.unsafeFixture
            }
        }
        self.probe = probe
        // Every opened root is an explicit test-owned checkout child. This does
        // not discover source paths under the real home, including on CI where
        // the optional local Foundation-home diagnostic is not configured.
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixtureBase = checkout.appendingPathComponent(".engram-publication-test-\(UUID().uuidString)")
        base = fixtureBase
        var completed = false
        // Captures only this invocation's exact local path, not a glob or an
        // incompletely initialized self. Previous failed fixtures are evidence.
        defer { if !completed { try? FileManager.default.removeItem(at: fixtureBase) } }
        shadow = base.appendingPathComponent("shadow")
        captureRoot = base.appendingPathComponent("capture")
        identity = base.appendingPathComponent("identity/archive.sqlite")
        sourceRoot = base.appendingPathComponent("sources")
        project = base.appendingPathComponent("project")
        source = sourceRoot.appendingPathComponent("one.jsonl")
        for url in [base, shadow, captureRoot, identity.deletingLastPathComponent(), sourceRoot, project] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        // Both identity readers see closed rollback-journal identity fixtures.
        // The active capture writer's WAL/SHM must never pass as this authority.
        for identityURL in [identity, shadow.appendingPathComponent("archive.sqlite")] {
            let identityQueue = try DatabaseQueue(path: identityURL.path)
            do {
                try identityQueue.write { db in
                    try db.execute(sql: "CREATE TABLE archive_metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
                    try db.execute(sql: "INSERT INTO archive_metadata VALUES ('machine_id', ?)", arguments: [Self.machine])
                }
                try identityQueue.close()
            } catch {
                try? identityQueue.close()
                throw error
            }
            guard chmod(identityURL.path, 0o600) == 0 else { throw Failure.unsafeFixture }
        }
        catalog = try EngramCollectorCore.ArchiveCatalog(root: captureRoot, machineID: Self.machine)
        try catalog.migrate()
        cas = try EngramCollectorCore.ImmutableArchiveCAS(root: captureRoot, testHooks: casTestHooks)
        policy = PublicationLocked(try .init(revision: 1, excludedProjectRoots: []))
        do {
            try writeTranscript()
            try reopen()
            try markDirty()
            completed = true
        } catch {
            try? owner?.close()
            throw error
        }
    }

    func reopen() throws {
        try owner?.close()
        owner = try XCTUnwrap(EngramCollectorCore.CollectorInventoryOwner.open(enabled: true,
            shadowRoot: shadow, identityCatalog: identity, ownerRunID: UUID().uuidString,
            testHooks: .init(beforeInventoryCommit: { [probe] in try probe.action?() })))
        _ = try owner.enrollAndActivateRoot(configuration)
    }

    func remove() {
        probe.action = nil
        do {
            try catalog.close()
            try owner?.close()
            try FileManager.default.removeItem(at: base)
        } catch {
            XCTFail("Publication fixture retained at \(base.path): \(error)")
        }
    }

    func transcript(text: String = "synthetic capture", cwd: String? = nil) throws -> Data {
        let rows: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": "native-one", "cwd": cwd ?? project.path]],
            ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]]],
        ]
        var data = Data()
        for row in rows { data.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])); data.append(10) }
        return data
    }

    func writeTranscript(text: String = "synthetic capture", cwd: String? = nil) throws {
        try writeBytes(transcript(text: text, cwd: cwd))
    }

    func writeBytes(_ bytes: Data) throws {
        try bytes.write(to: source)
        guard chmod(source.path, 0o600) == 0 else { throw Failure.unsafeFixture }
    }

    func markDirty(relativePath: String = "one.jsonl") throws {
        let checkpoint = try owner.rootState(rootID: configuration.rootID)?.eventCheckpoint
        _ = try owner.applyEvents(configuration: configuration, expectedCheckpoint: checkpoint,
            nextCheckpoint: .init(epoch: "fixture-events", cursor: UUID().uuidString),
            dirtyRelativePaths: [relativePath],
            budget: .init(maxIncomingPaths: 8, maxPathUTF8Bytes: 1_024, maxTotalPathUTF8Bytes: 4_096, maxCheckpointUTF8Bytes: 512))
    }

    func capture() throws -> CaptureResult {
        let descriptor = try EngramCollectorCore.ArchiveSourceDescriptor.singleFile(locator: source.path, sourceURL: source, replayRelativePath: "one.jsonl")
        return try EngramCollectorCore.ExactSourceCapturer(cas: cas, catalog: catalog, descriptor: descriptor)
            .capture(source: .codex, locator: source.path, machineID: Self.machine)
    }

    struct Prepared {
        let reservation: EngramCollectorCore.CollectorCaptureReservation
        let capture: CaptureResult
    }

    func prepare(markDirty: Bool = true) throws -> Prepared {
        // The allocator/Owner unit cases may use an already durable capture.
        // The real Worker crash test separately proves reservation-before-capture.
        let captured = try capture()
        let claim = try XCTUnwrap(owner.claimDirty(configuration: configuration, limit: 8, now: 1).first)
        let reservation = try XCTUnwrap(owner.reserveCapture(claim, configuration: configuration, generation: captured.manifest.generation))
        return .init(reservation: reservation, capture: captured)
    }

    func finish(_ prepared: Prepared) throws -> PublicationIntent {
        let intent = try owner.finishCapture(prepared.reservation, configuration: configuration, capture: prepared.capture.capture)
        return try XCTUnwrap(intent)
    }

    func worker(
        _ endpoints: [EngramCollectorCore.CollectorReplicaEndpoint],
        budget: EngramCollectorCore.CollectorPublicationBudget = .init(),
        hooks: EngramCollectorCore.CollectorPublicationWorkerTestHooks = .init()
    ) throws -> PublicationWorker {
        try PublicationWorker(owner: owner, catalog: catalog, cas: cas, roots: [configuration], replicas: endpoints,
            policy: { [policy] in policy.value }, budget: budget, testHooks: hooks)
    }

    func ack(_ intent: PublicationIntent, server: String = "hq", publicationDigest: String? = nil, manifestDigest: String? = nil) throws -> Data {
        try Canonical.encode(PublicationACK(serverID: server, journalID: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", arrivalOrdinal: 1,
            publicationSHA256: publicationDigest ?? intent.digest, manifestSHA256: manifestDigest ?? intent.publication.manifestSHA256,
            storedAt: "2026-09-06T12:00:00.000Z"))
    }

    func integer(_ sql: String) throws -> Int64 {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: inventory.path, configuration: configuration)
        defer { try? queue.close() }
        return try queue.read { try XCTUnwrap(Int64.fetchOne($0, sql: sql)) }
    }

    func mutate(_ sql: String) throws {
        let queue = try DatabaseQueue(path: inventory.path)
        defer { try? queue.close() }
        try queue.write { try $0.execute(sql: sql) }
    }

    func inventoryDigest() throws -> Data {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: inventory.path, configuration: configuration)
        defer { try? queue.close() }
        return try queue.read { db in
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
            var result = Data()
            for table in tables {
                guard table.utf8.allSatisfy({ (97...122).contains($0) || $0 == 95 }) else { throw Failure.unsafeFixture }
                let rows = try Row.fetchAll(db, sql: "SELECT * FROM \(table)")
                let rendered = rows.map { row in row.columnNames.map { String(describing: row[$0] as DatabaseValue) }.joined(separator: "|") }.sorted()
                result.append(Data((table + ":" + rendered.joined(separator: "\n")).utf8))
            }
            return result
        }
    }

    func assertNoLegacyAuthority(file: StaticString = #filePath, line: UInt = #line) throws {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: captureRoot.appendingPathComponent("archive.sqlite").path, configuration: configuration)
        defer { try? queue.close() }
        for table in ["archive_session_bindings", "archive_replica_receipts", "archive_recovery_leases", "archive_reclamation_intents"] {
            XCTAssertEqual(try queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM \(table)") }, 0, table, file: file, line: line)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("index.sqlite").path), file: file, line: line)
    }
}

/// Real existing RemoteServer app, real loopback HTTP and encrypted ArchiveStore.
/// No URLProtocol, mock server, alternate storage implementation or product writer.
private final class PublicationHTTPReplica: @unchecked Sendable {
    let id: String
    let token: String
    let config: EngramRemoteServerCore.EngramRemoteServerConfig
    let baseURL: URL
    private let server: Task<Void, Error>

    private init(id: String, token: String, config: EngramRemoteServerCore.EngramRemoteServerConfig, baseURL: URL, server: Task<Void, Error>) {
        self.id = id; self.token = token; self.config = config; self.baseURL = baseURL; self.server = server
    }

    static func start(id: String, parent: URL, publicationsEnabled: Bool = true) async throws -> PublicationHTTPReplica {
        let token = "synthetic-\(id)-archive-token"
        let root = parent.appendingPathComponent("replica-\(id)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let config = EngramRemoteServerCore.EngramRemoteServerConfig(host: "127.0.0.1", port: 0,
            storeRoot: root.appendingPathComponent("legacy"), bearerToken: "synthetic-\(id)-legacy-token",
            atRestKey: SymmetricKey(data: Data(repeating: 8, count: 32)),
            archiveV2: .init(serverID: id, root: root.appendingPathComponent("archive"), bearerToken: token,
                atRestKey: SymmetricKey(data: Data(repeating: id == "hq" ? 11 : 12, count: 32)), publicationsEnabled: publicationsEnabled))
        let app = try EngramRemoteServerCore.EngramRemoteServerApp(config: config)
        let bound = XCTestExpectation(description: "\(id) real archive HTTP listener")
        let port = PublicationLocked<Int?>(nil)
        let server = Task { try await app.run { value in port.change { $0 = value }; bound.fulfill() } }
        let result = await XCTWaiter.fulfillment(of: [bound], timeout: 10)
        guard result == .completed, let selected = port.value else {
            server.cancel()
            _ = try? await server.value
            throw PublicationFixture.Failure.unsafeFixture
        }
        let replica = PublicationHTTPReplica(id: id, token: token, config: config,
            baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:\(selected)")), server: server)
        do {
        if publicationsEnabled {
            // The actual app warms its durable publication journal off the accept
            // path. Wait with a deadline; listener-bound alone is not readiness.
            let deadline = Date().addingTimeInterval(5)
            while true {
                if try await replica.get("/v2/archive/publications").1 == 200 { break }
                guard Date() < deadline else { throw PublicationFixture.Failure.unsafeFixture }
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        return replica
        } catch {
            await replica.stop()
            throw error
        }
    }

    var endpoint: EngramCollectorCore.CollectorReplicaEndpoint { .init(replicaID: id, baseURL: baseURL, bearerToken: token) }
    func cancel() { server.cancel() }
    func stop() async { server.cancel(); _ = try? await server.value }

    func get(_ path: String) async throws -> (Data, Int) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: try XCTUnwrap(URL(string: path, relativeTo: baseURL)))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (bytes, response) = try await session.data(for: request)
        return (bytes, try XCTUnwrap(response as? HTTPURLResponse).statusCode)
    }

    func publications() async throws -> [[String: Any]] {
        let response = try await get("/v2/archive/publications")
        XCTAssertEqual(response.1, 200)
        let page = try XCTUnwrap(JSONSerialization.jsonObject(with: response.0) as? [String: Any])
        let items = try XCTUnwrap(page["items"] as? [[String: Any]])
        return try items.map { try XCTUnwrap($0["ack"] as? [String: Any]) }
    }
}

private struct PublicationReplicas {
    let hq: PublicationHTTPReplica
    let m1: PublicationHTTPReplica
    var all: [PublicationHTTPReplica] { [hq, m1] }
    var endpoints: [EngramCollectorCore.CollectorReplicaEndpoint] { all.map(\.endpoint) }
    static func start(in parent: URL, hqPublicationsEnabled: Bool = true) async throws -> Self {
        let hq = try await PublicationHTTPReplica.start(id: "hq", parent: parent, publicationsEnabled: hqPublicationsEnabled)
        do {
            let m1 = try await PublicationHTTPReplica.start(id: "m1", parent: parent)
            return .init(hq: hq, m1: m1)
        }
        catch { await hq.stop(); throw error }
    }
    func cancel() { hq.cancel(); m1.cancel() }
    func stop() async { await hq.stop(); await m1.stop() }
}
