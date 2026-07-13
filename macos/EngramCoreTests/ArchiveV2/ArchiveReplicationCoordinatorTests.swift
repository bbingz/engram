import Darwin
import Foundation
@testable import EngramCoreRead
@testable import EngramCoreWrite
import XCTest

final class ArchiveReplicationCoordinatorTests: XCTestCase {
    private let machineID = "11111111-2222-3333-4444-555555555555"
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "engram-archive-replication-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    func testCoordinatorRequiresExactlyHQAndM1Backends() throws {
        let store = try makeStore(name: "invalid-replicas")
        let hq = FakeArchiveReplicaBackend(replicaID: "hq")
        let duplicateHQ = FakeArchiveReplicaBackend(replicaID: "hq")
        let obsolete = FakeArchiveReplicaBackend(replicaID: "obsolete")

        XCTAssertThrowsError(
            try ArchiveReplicationCoordinator(
                catalog: store.catalog,
                cas: store.cas,
                backends: [hq]
            )
        ) { error in
            XCTAssertEqual(
                error as? ArchiveReplicaConfigurationError,
                .invalidReplicaSet
            )
        }
        XCTAssertThrowsError(
            try ArchiveReplicationCoordinator(
                catalog: store.catalog,
                cas: store.cas,
                backends: [hq, duplicateHQ]
            )
        )
        XCTAssertThrowsError(
            try ArchiveReplicationCoordinator(
                catalog: store.catalog,
                cas: store.cas,
                backends: [hq, obsolete]
            )
        )
    }

    func testNonPositiveLimitFailsClosedWithoutCatalogOrNetworkWork() async throws {
        let store = try makeStore(name: "invalid-limit")
        _ = try addBinding(to: store, seed: "invalid-limit", eligibility: .eligible)
        let hq = FakeArchiveReplicaBackend(replicaID: "hq")
        let m1 = FakeArchiveReplicaBackend(replicaID: "m1")
        let coordinator = try makeCoordinator(store: store, hq: hq, m1: m1)

        let zero = await coordinator.runOnce(limit: 0)
        let negative = await coordinator.runOnce(limit: -1)

        XCTAssertEqual(zero.cycleError, "invalid_limit")
        XCTAssertEqual(negative.cycleError, "invalid_limit")
        XCTAssertEqual(zero.claimed, 0)
        XCTAssertEqual(negative.claimed, 0)
        XCTAssertTrue(hq.events().isEmpty)
        XCTAssertTrue(m1.events().isEmpty)
        XCTAssertNil(try store.catalog.replicaWork(
            manifestSHA256: try XCTUnwrap(
                store.catalog.latestBinding(sessionID: "session-invalid-limit")
            ).manifestSHA256,
            replicaID: "hq"
        ))
    }

    func testUnknownAndExcludedBindingsNeverSeedOrCallEitherBackend() async throws {
        let store = try makeStore(name: "policy")
        _ = try addBinding(to: store, seed: "unknown", eligibility: .unknown)
        _ = try addBinding(to: store, seed: "excluded", eligibility: .excluded)
        let hq = FakeArchiveReplicaBackend(replicaID: "hq")
        let m1 = FakeArchiveReplicaBackend(replicaID: "m1")
        let coordinator = try makeCoordinator(store: store, hq: hq, m1: m1)

        let result = await coordinator.runOnce(limit: 10)

        XCTAssertNil(result.cycleError)
        XCTAssertEqual(result.reconciled, 0)
        XCTAssertEqual(result.claimed, 0)
        XCTAssertTrue(hq.events().isEmpty)
        XCTAssertTrue(m1.events().isEmpty)
    }

    func testSuccessfulCycleUsesStrictOrderAndRequiresDistinctDualReceipts() async throws {
        let store = try makeStore(name: "dual")
        let fixture = try addBinding(to: store, seed: "dual", eligibility: .eligible)
        let hq = FakeArchiveReplicaBackend(replicaID: "hq")
        let m1 = FakeArchiveReplicaBackend(replicaID: "m1")
        let coordinator = try makeCoordinator(store: store, hq: hq, m1: m1)

        let result = await coordinator.runOnce(limit: 2)

        XCTAssertNil(result.cycleError)
        XCTAssertEqual(result.claimed, 2)
        XCTAssertEqual(result.verified, 2)
        XCTAssertEqual(result.retryScheduled, 0)
        XCTAssertEqual(result.quarantined, 0)
        XCTAssertEqual(hq.events(), Self.completeCallOrder)
        XCTAssertEqual(m1.events(), Self.completeCallOrder)
        let receipts = try store.catalog.currentVerifiedReceipts(
            manifestSHA256: fixture.binding.manifestSHA256
        )
        XCTAssertEqual(Set(receipts.keys), Set(["hq", "m1"]))
        let hqReceipt = try ArchiveCanonicalJSON.decode(
            ArchiveServerReceipt.self,
            from: try XCTUnwrap(receipts["hq"]?.canonicalBytes)
        )
        let m1Receipt = try ArchiveCanonicalJSON.decode(
            ArchiveServerReceipt.self,
            from: try XCTUnwrap(receipts["m1"]?.canonicalBytes)
        )
        XCTAssertEqual(hqReceipt.serverID, "hq")
        XCTAssertEqual(m1Receipt.serverID, "m1")
        XCTAssertNotEqual(receipts["hq"]?.sha256, receipts["m1"]?.sha256)
        XCTAssertTrue(
            try store.catalog.hasCurrentDualDurability(
                manifestSHA256: fixture.binding.manifestSHA256
            )
        )
    }

    func testBacklogPassRunsHQAndM1ConcurrentlyButSeriallyWithinEachReplica() async throws {
        let store = try makeStore(name: "backlog-concurrency")
        _ = try addBinding(to: store, seed: "concurrency-1", eligibility: .eligible)
        _ = try addBinding(to: store, seed: "concurrency-2", eligibility: .eligible)
        let hq = FakeArchiveReplicaBackend(replicaID: "hq")
        let m1 = FakeArchiveReplicaBackend(replicaID: "m1")
        let hqGate = AsyncTestGate()
        let m1Gate = AsyncTestGate()
        hq.setHeadObjectGate(hqGate)
        m1.setHeadObjectGate(m1Gate)
        let coordinator = try makeCoordinator(store: store, hq: hq, m1: m1)
        let task = Task { await coordinator.runBacklogPass(perReplicaLimit: 2) }
        let hqEntered = expectation(description: "HQ entered its first request")
        let m1Entered = expectation(description: "M1 entered its first request")
        Task {
            await hqGate.waitUntilEntered()
            hqEntered.fulfill()
        }
        Task {
            await m1Gate.waitUntilEntered()
            m1Entered.fulfill()
        }

        await fulfillment(of: [hqEntered, m1Entered], timeout: 2)
        XCTAssertEqual(hq.events(), ["headObject"])
        XCTAssertEqual(m1.events(), ["headObject"])
        await hqGate.release()
        await m1Gate.release()
        let result = await task.value

        XCTAssertEqual(result.claimed, 4)
        XCTAssertEqual(result.verified, 4)
        XCTAssertEqual(hq.events().filter { $0 == "getReceipt" }.count, 2)
        XCTAssertEqual(m1.events().filter { $0 == "getReceipt" }.count, 2)
    }

    func testBacklogPassStopsOnlyFailedReplicaBatchAndReportsAttentionPause() async throws {
        let networkStore = try makeStore(name: "backlog-network-short-circuit")
        let networkFixtures = try [
            addBinding(to: networkStore, seed: "network-1", eligibility: .eligible),
            addBinding(to: networkStore, seed: "network-2", eligibility: .eligible),
        ]
        let failingHQ = FakeArchiveReplicaBackend(replicaID: "hq")
        failingHQ.setFailure(operation: "headObject", error: .transport(.network))
        let healthyM1 = FakeArchiveReplicaBackend(replicaID: "m1")
        let networkCoordinator = try makeCoordinator(
            store: networkStore,
            hq: failingHQ,
            m1: healthyM1
        )

        let networkResult = await networkCoordinator.runBacklogPass(perReplicaLimit: 2)

        XCTAssertEqual(networkResult.retryScheduled, 1)
        XCTAssertEqual(networkResult.verified, 2)
        XCTAssertEqual(failingHQ.events(), ["headObject"])
        XCTAssertEqual(healthyM1.events().filter { $0 == "getReceipt" }.count, 2)
        XCTAssertTrue(networkResult.pausedReplicaIDs.isEmpty)
        let networkHQStates = try networkFixtures.compactMap {
            try networkStore.catalog.replicaWork(
                manifestSHA256: $0.binding.manifestSHA256,
                replicaID: "hq"
            )?.state
        }
        XCTAssertEqual(networkHQStates.filter { $0 == .retryWait }.count, 1)
        XCTAssertEqual(networkHQStates.filter { $0 == .pending }.count, 1)

        let authStore = try makeStore(name: "backlog-auth-short-circuit")
        let authFixtures = try [
            addBinding(to: authStore, seed: "auth-1", eligibility: .eligible),
            addBinding(to: authStore, seed: "auth-2", eligibility: .eligible),
        ]
        let unauthorizedHQ = FakeArchiveReplicaBackend(replicaID: "hq")
        unauthorizedHQ.setFailure(operation: "headObject", error: .unexpectedStatus(401))
        let authM1 = FakeArchiveReplicaBackend(replicaID: "m1")
        let authCoordinator = try makeCoordinator(
            store: authStore,
            hq: unauthorizedHQ,
            m1: authM1
        )

        let authResult = await authCoordinator.runBacklogPass(perReplicaLimit: 2)

        XCTAssertEqual(authResult.pausedReplicaIDs, ["hq"])
        XCTAssertEqual(unauthorizedHQ.events(), ["headObject"])
        XCTAssertEqual(authM1.events().filter { $0 == "getReceipt" }.count, 2)
        let authHQStates = try authFixtures.compactMap {
            try authStore.catalog.replicaWork(
                manifestSHA256: $0.binding.manifestSHA256,
                replicaID: "hq"
            )?.state
        }
        XCTAssertEqual(authHQStates.filter { $0 == .quarantined }.count, 1)
        XCTAssertEqual(authHQStates.filter { $0 == .pending }.count, 1)
    }

    func testBacklogPassBoundsLongTransientPauseAndResumesPendingWorkAtExpiry() async throws {
        let store = try makeStore(name: "backlog-long-transient-deadline")
        let deferred = try addBinding(
            to: store,
            seed: "long-deadline",
            eligibility: .eligible
        )
        try seedRetryAttempts(
            count: 8,
            fixture: deferred,
            replicaID: "hq",
            catalog: store.catalog
        )
        let ordinary = try addBinding(
            to: store,
            seed: "ordinary-after-long-deadline",
            eligibility: .eligible
        )
        let hq = FakeArchiveReplicaBackend(replicaID: "hq")
        hq.setFailure(operation: "headObject", error: .transport(.network))
        let m1 = FakeArchiveReplicaBackend(replicaID: "m1")
        let now = try date("2026-07-11T00:00:00.000Z")
        let clock = LockedTestClock(now)
        let coordinator = try makeCoordinator(
            store: store,
            hq: hq,
            m1: m1,
            clock: clock,
            jitter: ArchiveRetryJitter(sampleUnit: { 1 })
        )

        let first = await coordinator.runBacklogPass(perReplicaLimit: 2)
        let deferredAfterFailure = try XCTUnwrap(try store.catalog.replicaWork(
            manifestSHA256: deferred.binding.manifestSHA256,
            replicaID: "hq"
        ))
        let durableRetryAt = try date(try XCTUnwrap(deferredAfterFailure.nextRetryAt))

        XCTAssertEqual(deferredAfterFailure.attempts, 9)
        XCTAssertEqual(durableRetryAt, now.addingTimeInterval(15_360))
        XCTAssertGreaterThan(durableRetryAt, now.addingTimeInterval(60))
        XCTAssertEqual(
            first.retryPausedUntilByReplica["hq"],
            now.addingTimeInterval(60)
        )
        XCTAssertEqual(first.verifiedByReplica["m1"], 2)

        let hqEventsBeforeDeadline = hq.events()
        let independent = try addBinding(
            to: store,
            seed: "m1-independent-during-hq-pause",
            eligibility: .eligible
        )
        clock.set(try date("2026-07-11T00:00:30.000Z"))
        let beforeDeadline = await coordinator.runBacklogPass(perReplicaLimit: 2)

        XCTAssertEqual(first.retryPausedReplicaIDs, ["hq"])
        XCTAssertEqual(beforeDeadline.retryPausedReplicaIDs, ["hq"])
        XCTAssertEqual(
            beforeDeadline.retryPausedUntilByReplica["hq"],
            try date("2026-07-11T00:01:00.000Z")
        )
        XCTAssertEqual(hq.events(), hqEventsBeforeDeadline)
        XCTAssertEqual(beforeDeadline.verifiedByReplica["m1"], 1)
        XCTAssertEqual(
            try store.catalog.replicaWork(
                manifestSHA256: independent.binding.manifestSHA256,
                replicaID: "m1"
            )?.state,
            .verified
        )
        XCTAssertEqual(
            try store.catalog.replicaWork(
                manifestSHA256: ordinary.binding.manifestSHA256,
                replicaID: "hq"
            )?.state,
            .pending
        )

        hq.clearFailure()
        clock.set(try date("2026-07-11T00:01:00.000Z"))
        let atDeadline = await coordinator.runBacklogPass(perReplicaLimit: 2)

        XCTAssertTrue(atDeadline.retryPausedReplicaIDs.isEmpty)
        XCTAssertEqual(atDeadline.verifiedByReplica["hq"], 2)
        XCTAssertEqual(
            try store.catalog.replicaWork(
                manifestSHA256: ordinary.binding.manifestSHA256,
                replicaID: "hq"
            )?.state,
            .verified
        )
        XCTAssertEqual(
            try store.catalog.replicaWork(
                manifestSHA256: independent.binding.manifestSHA256,
                replicaID: "hq"
            )?.state,
            .verified
        )
        let deferredAfterExpiry = try XCTUnwrap(try store.catalog.replicaWork(
            manifestSHA256: deferred.binding.manifestSHA256,
            replicaID: "hq"
        ))
        XCTAssertEqual(deferredAfterExpiry.state, .retryWait)
        XCTAssertEqual(deferredAfterExpiry.nextRetryAt, deferredAfterFailure.nextRetryAt)
    }

    func testBacklogPassKeepsShortRowRetryButPausesReplicaForSixtySeconds() async throws {
        let store = try makeStore(name: "backlog-short-transient-deadline")
        let fixture = try addBinding(
            to: store,
            seed: "short-deadline",
            eligibility: .eligible
        )
        let hq = FakeArchiveReplicaBackend(replicaID: "hq")
        hq.setFailure(operation: "headObject", error: .transport(.network))
        let m1 = FakeArchiveReplicaBackend(replicaID: "m1")
        let now = try date("2026-07-11T00:00:00.000Z")
        let clock = LockedTestClock(now)
        let coordinator = try makeCoordinator(
            store: store,
            hq: hq,
            m1: m1,
            clock: clock,
            jitter: ArchiveRetryJitter(sampleUnit: { 0.5 })
        )

        let first = await coordinator.runBacklogPass(perReplicaLimit: 1)

        let row = try XCTUnwrap(try store.catalog.replicaWork(
            manifestSHA256: fixture.binding.manifestSHA256,
            replicaID: "hq"
        ))
        XCTAssertEqual(try date(try XCTUnwrap(row.nextRetryAt)), now.addingTimeInterval(30))
        XCTAssertEqual(
            first.retryPausedUntilByReplica["hq"],
            now.addingTimeInterval(60)
        )

        let hqEvents = hq.events()
        clock.set(now.addingTimeInterval(30))
        let beforePauseDeadline = await coordinator.runBacklogPass(perReplicaLimit: 1)

        XCTAssertEqual(beforePauseDeadline.retryPausedReplicaIDs, ["hq"])
        XCTAssertEqual(hq.events(), hqEvents)

        hq.clearFailure()
        clock.set(now.addingTimeInterval(60))
        let atPauseDeadline = await coordinator.runBacklogPass(perReplicaLimit: 1)

        XCTAssertTrue(atPauseDeadline.retryPausedReplicaIDs.isEmpty)
        XCTAssertEqual(atPauseDeadline.verifiedByReplica["hq"], 1)
    }

    func testBacklogPassZeroJitterDoesNotRetryReplicaBeforeSixtySeconds() async throws {
        let store = try makeStore(name: "backlog-zero-jitter-deadline")
        _ = try addBinding(
            to: store,
            seed: "zero-jitter-deadline",
            eligibility: .eligible
        )
        let hq = FakeArchiveReplicaBackend(replicaID: "hq")
        hq.setFailure(operation: "headObject", error: .transport(.network))
        let m1 = FakeArchiveReplicaBackend(replicaID: "m1")
        let now = try date("2026-07-11T00:00:00.000Z")
        let clock = LockedTestClock(now)
        let coordinator = try makeCoordinator(
            store: store,
            hq: hq,
            m1: m1,
            clock: clock,
            jitter: ArchiveRetryJitter(sampleUnit: { 0 })
        )

        let first = await coordinator.runBacklogPass(perReplicaLimit: 1)

        XCTAssertEqual(
            first.retryPausedUntilByReplica["hq"],
            now.addingTimeInterval(60)
        )
        let hqEvents = hq.events()

        clock.set(now.addingTimeInterval(59))
        let beforePauseDeadline = await coordinator.runBacklogPass(perReplicaLimit: 1)

        XCTAssertEqual(beforePauseDeadline.retryPausedReplicaIDs, ["hq"])
        XCTAssertEqual(hq.events(), hqEvents)
    }

    func testBacklogPassCancellationRetainsExistingReplicaPauseSnapshot() async throws {
        let store = try makeStore(name: "backlog-cancel-retains-pause")
        _ = try addBinding(
            to: store,
            seed: "cancel-retains-pause",
            eligibility: .eligible
        )
        let hq = FakeArchiveReplicaBackend(replicaID: "hq")
        hq.setFailure(operation: "headObject", error: .transport(.network))
        let m1 = FakeArchiveReplicaBackend(replicaID: "m1")
        m1.setFailure(operation: "headObject", error: .unexpectedStatus(401))
        let now = try date("2026-07-11T00:00:00.000Z")
        let coordinator = try makeCoordinator(
            store: store,
            hq: hq,
            m1: m1,
            clock: LockedTestClock(now)
        )
        let first = await coordinator.runBacklogPass(perReplicaLimit: 1)
        XCTAssertEqual(first.retryPausedReplicaIDs, ["hq"])
        XCTAssertEqual(first.pausedReplicaIDs, ["m1"])
        let gate = AsyncTestGate()
        let task = Task {
            await gate.enterAndWait()
            return await coordinator.runBacklogPass(perReplicaLimit: 1)
        }
        await gate.waitUntilEntered()

        task.cancel()
        await gate.release()
        let cancelled = await task.value

        XCTAssertTrue(cancelled.cancelled)
        XCTAssertEqual(cancelled.pausedReplicaIDs, first.pausedReplicaIDs)
        XCTAssertEqual(
            cancelled.retryPausedUntilByReplica,
            first.retryPausedUntilByReplica
        )
    }

    func testBacklogPassResourceGateStopsBeforeStartingAnotherReplicaRow() async throws {
        let store = try makeStore(name: "backlog-resource-gate")
        _ = try addBinding(to: store, seed: "resource-1", eligibility: .eligible)
        _ = try addBinding(to: store, seed: "resource-2", eligibility: .eligible)
        let hq = FakeArchiveReplicaBackend(replicaID: "hq")
        let m1 = FakeArchiveReplicaBackend(replicaID: "m1")
        let hqGate = AsyncTestGate()
        let m1Gate = AsyncTestGate()
        hq.setHeadObjectGate(hqGate)
        m1.setHeadObjectGate(m1Gate)
        let workGate = WorkGateBox(true)
        let coordinator = try makeCoordinator(store: store, hq: hq, m1: m1)
        let task = Task {
            await coordinator.runBacklogPass(
                perReplicaLimit: 2,
                shouldStartUnit: { workGate.value() }
            )
        }
        async let hqEntered: Void = hqGate.waitUntilEntered()
        async let m1Entered: Void = m1Gate.waitUntilEntered()
        _ = await (hqEntered, m1Entered)

        workGate.set(false)
        await hqGate.release()
        await m1Gate.release()
        let result = await task.value

        XCTAssertEqual(result.verified, 2)
        XCTAssertEqual(hq.events().filter { $0 == "getReceipt" }.count, 1)
        XCTAssertEqual(m1.events().filter { $0 == "getReceipt" }.count, 1)
    }

    func testLimitCountsReplicaRowsRatherThanManifests() async throws {
        let store = try makeStore(name: "row-limit")
        let fixture = try addBinding(to: store, seed: "row-limit", eligibility: .eligible)
        let hq = FakeArchiveReplicaBackend(replicaID: "hq")
        let m1 = FakeArchiveReplicaBackend(replicaID: "m1")
        let coordinator = try makeCoordinator(store: store, hq: hq, m1: m1)

        let result = await coordinator.runOnce(limit: 1)

        XCTAssertEqual(result.claimed, 1)
        XCTAssertEqual(result.verified, 1)
        XCTAssertEqual(hq.events(), Self.completeCallOrder)
        XCTAssertTrue(m1.events().isEmpty)
        XCTAssertEqual(
            try store.catalog.replicaWork(
                manifestSHA256: fixture.binding.manifestSHA256,
                replicaID: "hq"
            )?.state,
            .verified
        )
        XCTAssertEqual(
            try store.catalog.replicaWork(
                manifestSHA256: fixture.binding.manifestSHA256,
                replicaID: "m1"
            )?.state,
            .pending
        )
    }

    func testHQSuccessAndM1FailureRetriesOnlyM1WithoutReuploadingHQ() async throws {
        let store = try makeStore(name: "independent")
        let fixture = try addBinding(to: store, seed: "independent", eligibility: .eligible)
        let hq = FakeArchiveReplicaBackend(replicaID: "hq")
        let m1 = FakeArchiveReplicaBackend(replicaID: "m1")
        m1.setFailure(
            operation: "headObject",
            error: .transport(.network)
        )
        let clock = LockedTestClock(try date("2026-07-11T00:00:00.000Z"))
        let coordinator = try makeCoordinator(
            store: store,
            hq: hq,
            m1: m1,
            clock: clock,
            jitter: ArchiveRetryJitter(sampleUnit: { 1 })
        )

        let first = await coordinator.runOnce(limit: 2)

        XCTAssertEqual(first.verified, 1)
        XCTAssertEqual(first.retryScheduled, 1)
        XCTAssertEqual(first.quarantined, 0)
        XCTAssertEqual(
            try store.catalog.replicaWork(
                manifestSHA256: fixture.binding.manifestSHA256,
                replicaID: "m1"
            )?.lastError,
            "transport_network"
        )
        XCTAssertEqual(
            try store.catalog.replicaWork(
                manifestSHA256: fixture.binding.manifestSHA256,
                replicaID: "m1"
            )?.nextRetryAt,
            "2026-07-11T00:01:00.000Z"
        )

        let hqEvents = hq.events()
        m1.clearFailure()
        clock.set(try date("2026-07-11T00:01:00.000Z"))
        let second = await coordinator.runOnce(limit: 2)

        XCTAssertEqual(second.claimed, 1)
        XCTAssertEqual(second.verified, 1)
        XCTAssertEqual(hq.events(), hqEvents)
        XCTAssertEqual(m1.events().filter { $0 == "getReceipt" }.count, 1)
        XCTAssertTrue(
            try store.catalog.hasCurrentDualDurability(
                manifestSHA256: fixture.binding.manifestSHA256
            )
        )
    }

    func testReceiptPUTResponseBodyIsDiscardedAndIndependentGETIsTheOnlyProof() async throws {
        let store = try makeStore(name: "receipt-proof")
        let fixture = try addBinding(to: store, seed: "receipt-proof", eligibility: .eligible)
        let hq = FakeArchiveReplicaBackend(replicaID: "hq")
        hq.setCreateReceiptResponse(Data("not-a-receipt".utf8))
        let m1 = FakeArchiveReplicaBackend(replicaID: "m1")
        let coordinator = try makeCoordinator(store: store, hq: hq, m1: m1)

        let result = await coordinator.runOnce(limit: 1)

        XCTAssertEqual(result.verified, 1)
        XCTAssertEqual(hq.events().suffix(2), ["createReceipt", "getReceipt"])
        XCTAssertEqual(
            try store.catalog.replicaWork(
                manifestSHA256: fixture.binding.manifestSHA256,
                replicaID: "hq"
            )?.state,
            .verified
        )
    }

    func testMissingReceiptAfterSuccessfulPUTQuarantinesAsContradiction() async throws {
        let store = try makeStore(name: "receipt-missing")
        let fixture = try addBinding(to: store, seed: "receipt-missing", eligibility: .eligible)
        let hq = FakeArchiveReplicaBackend(replicaID: "hq")
        hq.setFailure(operation: "getReceipt", error: .unexpectedStatus(404))
        let m1 = FakeArchiveReplicaBackend(replicaID: "m1")
        let coordinator = try makeCoordinator(store: store, hq: hq, m1: m1)

        let result = await coordinator.runOnce(limit: 1)

        XCTAssertEqual(result.verified, 0)
        XCTAssertEqual(result.quarantined, 1)
        let row = try store.catalog.replicaWork(
            manifestSHA256: fixture.binding.manifestSHA256,
            replicaID: "hq"
        )
        XCTAssertEqual(row?.state, .quarantined)
        XCTAssertEqual(row?.lastError, "remote_receipt_missing")
    }

    func testWrongReceiptIdentityFieldsQuarantineOnlyThatReplica() async throws {
        let mutations: [FakeReceiptMutation] = [
            .wrongServer,
            .wrongMachine,
            .wrongSession,
            .wrongCapture,
            .wrongManifest,
            .wrongWholeSource,
            .wrongObjectCount,
            .wrongRawByteCount,
        ]

        for mutation in mutations {
            let name = "wrong-receipt-\(mutation.rawValue)"
            let store = try makeStore(name: name)
            let fixture = try addBinding(to: store, seed: name, eligibility: .eligible)
            let hq = FakeArchiveReplicaBackend(replicaID: "hq")
            hq.setReceiptMutation(mutation)
            let m1 = FakeArchiveReplicaBackend(replicaID: "m1")
            let coordinator = try makeCoordinator(store: store, hq: hq, m1: m1)

            let result = await coordinator.runOnce(limit: 2)

            XCTAssertEqual(result.verified, 1, mutation.rawValue)
            XCTAssertEqual(result.quarantined, 1, mutation.rawValue)
            let hqRow = try store.catalog.replicaWork(
                manifestSHA256: fixture.binding.manifestSHA256,
                replicaID: "hq"
            )
            let m1Row = try store.catalog.replicaWork(
                manifestSHA256: fixture.binding.manifestSHA256,
                replicaID: "m1"
            )
            XCTAssertEqual(hqRow?.state, .quarantined, mutation.rawValue)
            XCTAssertEqual(hqRow?.lastError, "remote_receipt_mismatch", mutation.rawValue)
            XCTAssertEqual(m1Row?.state, .verified, mutation.rawValue)
        }
    }

    func testNoncanonicalReceiptQuarantines() async throws {
        let store = try makeStore(name: "receipt-noncanonical")
        let fixture = try addBinding(
            to: store,
            seed: "receipt-noncanonical",
            eligibility: .eligible
        )
        let hq = FakeArchiveReplicaBackend(replicaID: "hq")
        hq.setReceiptMutation(.noncanonical)
        let m1 = FakeArchiveReplicaBackend(replicaID: "m1")
        let coordinator = try makeCoordinator(store: store, hq: hq, m1: m1)

        let result = await coordinator.runOnce(limit: 1)

        XCTAssertEqual(result.quarantined, 1)
        XCTAssertEqual(
            try store.catalog.replicaWork(
                manifestSHA256: fixture.binding.manifestSHA256,
                replicaID: "hq"
            )?.lastError,
            "remote_receipt_noncanonical"
        )
    }

    func testCancellationLeavesInflightClaimWithoutIncrementingAttempts() async throws {
        let store = try makeStore(name: "cancelled")
        let fixture = try addBinding(to: store, seed: "cancelled", eligibility: .eligible)
        let hq = FakeArchiveReplicaBackend(replicaID: "hq")
        hq.setFailure(operation: "headObject", error: .transport(.cancelled))
        let m1 = FakeArchiveReplicaBackend(replicaID: "m1")
        let coordinator = try makeCoordinator(store: store, hq: hq, m1: m1)

        let result = await coordinator.runOnce(limit: 1)

        XCTAssertTrue(result.cancelled)
        XCTAssertEqual(result.retryScheduled, 0)
        XCTAssertEqual(result.quarantined, 0)
        let row = try store.catalog.replicaWork(
            manifestSHA256: fixture.binding.manifestSHA256,
            replicaID: "hq"
        )
        XCTAssertEqual(row?.state, .uploadingObjects)
        XCTAssertEqual(row?.attempts, 0)
        XCTAssertNil(row?.lastError)
    }

    func testRealTaskCancellationAfterEveryBackendAwaitStopsBeforeFurtherWork() async throws {
        struct Boundary {
            let operation: String
            let expectedState: ArchiveReplicaState
            let expectedEvents: [String]
        }
        let boundaries: [Boundary] = [
            .init(
                operation: "headObject",
                expectedState: .uploadingObjects,
                expectedEvents: ["headObject"]
            ),
            .init(
                operation: "putObject",
                expectedState: .uploadingObjects,
                expectedEvents: ["headObject", "putObject"]
            ),
            .init(
                operation: "headManifest",
                expectedState: .uploadingManifest,
                expectedEvents: ["headObject", "putObject", "headManifest"]
            ),
            .init(
                operation: "putManifest",
                expectedState: .uploadingManifest,
                expectedEvents: [
                    "headObject", "putObject", "headManifest", "putManifest",
                ]
            ),
            .init(
                operation: "createReceipt",
                expectedState: .requestingReceipt,
                expectedEvents: [
                    "headObject", "putObject", "headManifest", "putManifest",
                    "createReceipt",
                ]
            ),
            .init(
                operation: "getReceipt",
                expectedState: .verifyingReceipt,
                expectedEvents: [
                    "headObject", "putObject", "headManifest", "putManifest",
                    "createReceipt", "getReceipt",
                ]
            ),
        ]

        for boundary in boundaries {
            let name = "real-cancel-\(boundary.operation)"
            let store = try makeStore(name: name)
            let fixture = try addBinding(to: store, seed: name, eligibility: .eligible)
            let hq = FakeArchiveReplicaBackend(replicaID: "hq")
            let gate = AsyncTestGate()
            hq.setOperationGate(boundary.operation, gate: gate)
            let m1 = FakeArchiveReplicaBackend(replicaID: "m1")
            let coordinator = try makeCoordinator(store: store, hq: hq, m1: m1)
            let task = Task { await coordinator.runOnce(limit: 1) }
            await gate.waitUntilEntered()

            task.cancel()
            await gate.release()
            let result = await task.value

            XCTAssertTrue(result.cancelled, boundary.operation)
            XCTAssertNil(result.cycleError, boundary.operation)
            XCTAssertEqual(result.retryScheduled, 0, boundary.operation)
            XCTAssertEqual(result.quarantined, 0, boundary.operation)
            XCTAssertEqual(hq.events(), boundary.expectedEvents, boundary.operation)
            let row = try store.catalog.replicaWork(
                manifestSHA256: fixture.binding.manifestSHA256,
                replicaID: "hq"
            )
            XCTAssertEqual(row?.state, boundary.expectedState, boundary.operation)
            XCTAssertEqual(row?.attempts, 0, boundary.operation)
            XCTAssertNil(row?.lastError, boundary.operation)
        }
    }

    func testRealTaskCancellationWinsWhenBackendReturnsNetworkFailure() async throws {
        let store = try makeStore(name: "cancel-vs-failure")
        let fixture = try addBinding(
            to: store,
            seed: "cancel-vs-failure",
            eligibility: .eligible
        )
        let hq = FakeArchiveReplicaBackend(replicaID: "hq")
        let gate = AsyncTestGate()
        hq.setDeferredFailure(
            operation: "headObject",
            error: .transport(.network),
            gate: gate
        )
        let m1 = FakeArchiveReplicaBackend(replicaID: "m1")
        let coordinator = try makeCoordinator(store: store, hq: hq, m1: m1)
        let task = Task { await coordinator.runOnce(limit: 1) }
        await gate.waitUntilEntered()

        task.cancel()
        await gate.release()
        let result = await task.value

        XCTAssertTrue(result.cancelled)
        XCTAssertEqual(result.retryScheduled, 0)
        XCTAssertEqual(result.quarantined, 0)
        XCTAssertEqual(hq.events(), ["headObject"])
        let row = try store.catalog.replicaWork(
            manifestSHA256: fixture.binding.manifestSHA256,
            replicaID: "hq"
        )
        XCTAssertEqual(row?.state, .uploadingObjects)
        XCTAssertEqual(row?.attempts, 0)
        XCTAssertNil(row?.lastError)
    }

    func testActorSingleFlightRejectsReentrantCycleWithoutAdditionalClaim() async throws {
        let store = try makeStore(name: "single-flight")
        let fixture = try addBinding(to: store, seed: "single-flight", eligibility: .eligible)
        let hq = FakeArchiveReplicaBackend(replicaID: "hq")
        let gate = AsyncTestGate()
        hq.setHeadObjectGate(gate)
        let m1 = FakeArchiveReplicaBackend(replicaID: "m1")
        let coordinator = try makeCoordinator(store: store, hq: hq, m1: m1)
        let firstTask = Task { await coordinator.runOnce(limit: 1) }
        await gate.waitUntilEntered()

        let second = await coordinator.runOnce(limit: 1)

        XCTAssertEqual(second.cycleError, "already_running")
        XCTAssertEqual(second.claimed, 0)
        XCTAssertEqual(second.reconciled, 0)
        XCTAssertEqual(
            try store.catalog.replicaWork(
                manifestSHA256: fixture.binding.manifestSHA256,
                replicaID: "hq"
            )?.claimGeneration,
            1
        )
        await gate.release()
        let first = await firstTask.value
        XCTAssertEqual(first.verified, 1)
    }

    func testRetryJitterUses60SecondBaseAnd86400SecondCap() {
        let jitter = ArchiveRetryJitter(sampleUnit: { 1 })

        XCTAssertEqual(ArchiveRetryJitter.maximumDelay(failureNumber: 1), 60)
        XCTAssertEqual(ArchiveRetryJitter.maximumDelay(failureNumber: 2), 120)
        XCTAssertEqual(ArchiveRetryJitter.maximumDelay(failureNumber: 12), 86_400)
        XCTAssertEqual(ArchiveRetryJitter.maximumDelay(failureNumber: 10_000), 86_400)
        XCTAssertEqual(ArchiveRetryJitter.maximumDelay(failureNumber: Int.min), 60)
        XCTAssertEqual(jitter.delay(failureNumber: 1), 60)
        XCTAssertEqual(jitter.delay(failureNumber: 12), 86_400)
    }

    func testFailureNumberSaturatesWithoutOverflowAtIntegerBounds() {
        XCTAssertEqual(ArchiveRetryJitter.failureNumber(afterAttempts: Int.min), 1)
        XCTAssertEqual(ArchiveRetryJitter.failureNumber(afterAttempts: -1), 1)
        XCTAssertEqual(ArchiveRetryJitter.failureNumber(afterAttempts: 0), 1)
        XCTAssertEqual(ArchiveRetryJitter.failureNumber(afterAttempts: 1), 2)
        XCTAssertEqual(
            ArchiveRetryJitter.failureNumber(afterAttempts: Int.max),
            Int.max
        )
        XCTAssertEqual(ArchiveRetryJitter.maximumDelay(failureNumber: Int.max), 86_400)
    }

    func testRetryTimestampAndDelayShareOneActualFailureClockSample() async throws {
        let store = try makeStore(name: "single-failure-time")
        let fixture = try addBinding(
            to: store,
            seed: "single-failure-time",
            eligibility: .eligible
        )
        let hq = FakeArchiveReplicaBackend(replicaID: "hq")
        hq.setFailure(operation: "headObject", error: .transport(.network))
        let m1 = FakeArchiveReplicaBackend(replicaID: "m1")
        let advancingClock = AdvancingTestClock(
            start: try date("2026-07-11T00:00:00.000Z"),
            step: 1
        )
        let coordinator = try ArchiveReplicationCoordinator(
            catalog: store.catalog,
            cas: store.cas,
            backends: [hq, m1],
            clock: { advancingClock.now() },
            jitter: ArchiveRetryJitter(sampleUnit: { 1 })
        )

        let result = await coordinator.runOnce(limit: 1)

        XCTAssertEqual(result.retryScheduled, 1)
        let row = try XCTUnwrap(try store.catalog.replicaWork(
            manifestSHA256: fixture.binding.manifestSHA256,
            replicaID: "hq"
        ))
        let failedAt = try date(row.updatedAt)
        let nextRetryAt = try date(try XCTUnwrap(row.nextRetryAt))
        XCTAssertEqual(nextRetryAt.timeIntervalSince(failedAt), 60, accuracy: 0.001)
    }

    func testStaleClaimCannotRegressNewerVerifiedGeneration() async throws {
        let store = try makeStore(name: "stale-generation")
        let fixture = try addBinding(
            to: store,
            seed: "stale-generation",
            eligibility: .eligible
        )
        let hq = FakeArchiveReplicaBackend(replicaID: "hq")
        let m1 = FakeArchiveReplicaBackend(replicaID: "m1")
        hq.setHeadObjectHook {
            _ = try store.catalog.recoverStaleInflight(
                now: "2026-07-11T00:20:01.000Z",
                olderThanSeconds: 600
            )
            let newer = try store.catalog.claimReplicaWork(
                limit: 2,
                now: "2026-07-11T00:20:01.000Z"
            ).first { $0.replicaID == "hq" }
            guard let newer else {
                throw TestFailure.unexpectedLostClaim
            }
            try self.advanceToVerifying(store.catalog, claim: newer)
            let receiptBytes = try self.receiptBytes(
                serverID: "hq",
                manifestBytes: fixture.manifestBytes
            )
            XCTAssertTrue(
                try store.catalog.recordVerifiedReceipt(
                    newer,
                    receipt: ArchiveVerifiedReceipt(
                        canonicalBytes: receiptBytes,
                        sha256: ArchiveV2Hash.sha256(receiptBytes),
                        verifiedAt: "2026-07-11T00:20:05.000Z"
                    ),
                    updatedAt: "2026-07-11T00:20:05.000Z"
                )
            )
        }
        let clock = LockedTestClock(try date("2026-07-11T00:00:00.000Z"))
        let coordinator = try makeCoordinator(
            store: store,
            hq: hq,
            m1: m1,
            clock: clock
        )

        let result = await coordinator.runOnce(limit: 1)

        XCTAssertEqual(result.lostClaims, 1)
        XCTAssertEqual(result.verified, 0)
        let row = try store.catalog.replicaWork(
            manifestSHA256: fixture.binding.manifestSHA256,
            replicaID: "hq"
        )
        XCTAssertEqual(row?.state, .verified)
        XCTAssertGreaterThanOrEqual(row?.claimGeneration ?? 0, 3)
        XCTAssertEqual(row?.attempts, 0)
    }

    func testCycleRecoversTenMinuteStaleClaimAndAdvancesItsGeneration() async throws {
        let store = try makeStore(name: "stale-recovery")
        let fixture = try addBinding(
            to: store,
            seed: "stale-recovery",
            eligibility: .eligible
        )
        XCTAssertEqual(
            try store.catalog.reconcileEligibleReplicaRows(
                updatedAt: "2026-07-11T00:00:00.000Z"
            ),
            2
        )
        let initialClaims = try store.catalog.claimReplicaWork(
            limit: 2,
            now: "2026-07-11T00:00:00.000Z"
        )
        let initialHQ = try XCTUnwrap(initialClaims.first { $0.replicaID == "hq" })
        let initialM1 = try XCTUnwrap(initialClaims.first { $0.replicaID == "m1" })
        try advanceToVerifying(store.catalog, claim: initialM1)
        let m1ReceiptBytes = try receiptBytes(
            serverID: "m1",
            manifestBytes: fixture.manifestBytes
        )
        XCTAssertTrue(
            try store.catalog.recordVerifiedReceipt(
                initialM1,
                receipt: ArchiveVerifiedReceipt(
                    canonicalBytes: m1ReceiptBytes,
                    sha256: ArchiveV2Hash.sha256(m1ReceiptBytes),
                    verifiedAt: "2026-07-11T00:20:05.000Z"
                ),
                updatedAt: "2026-07-11T00:20:05.000Z"
            )
        )
        let hq = FakeArchiveReplicaBackend(replicaID: "hq")
        let m1 = FakeArchiveReplicaBackend(replicaID: "m1")
        let clock = LockedTestClock(try date("2026-07-11T00:10:01.000Z"))
        let coordinator = try makeCoordinator(
            store: store,
            hq: hq,
            m1: m1,
            clock: clock
        )

        let result = await coordinator.runOnce(limit: 1)

        XCTAssertEqual(result.staleRecovered, 1)
        XCTAssertEqual(result.claimed, 1)
        XCTAssertEqual(result.verified, 1)
        XCTAssertEqual(
            try store.catalog.replicaWork(
                manifestSHA256: fixture.binding.manifestSHA256,
                replicaID: "hq"
            )?.claimGeneration,
            initialHQ.claimGeneration + 2
        )
        XCTAssertTrue(
            try store.catalog.hasCurrentDualDurability(
                manifestSHA256: fixture.binding.manifestSHA256
            )
        )
    }

    func testMissingAndCorruptLocalManifestQuarantineWithoutNetwork() async throws {
        for corruption in ["missing", "corrupt"] {
            let name = "manifest-\(corruption)"
            let store = try makeStore(name: name)
            let fixture = try addBinding(to: store, seed: name, eligibility: .eligible)
            let manifestURL = manifestURL(
                store: store,
                digest: fixture.binding.manifestSHA256
            )
            if corruption == "missing" {
                try FileManager.default.removeItem(at: manifestURL)
            } else {
                try Data("corrupt".utf8).write(to: manifestURL)
            }
            let hq = FakeArchiveReplicaBackend(replicaID: "hq")
            let m1 = FakeArchiveReplicaBackend(replicaID: "m1")
            let coordinator = try makeCoordinator(store: store, hq: hq, m1: m1)

            let result = await coordinator.runOnce(limit: 1)

            XCTAssertEqual(result.quarantined, 1, corruption)
            XCTAssertTrue(hq.events().isEmpty, corruption)
            XCTAssertEqual(
                try store.catalog.replicaWork(
                    manifestSHA256: fixture.binding.manifestSHA256,
                    replicaID: "hq"
                )?.lastError,
                corruption == "missing" ? "local_manifest_missing" : "local_manifest_corrupt"
            )
        }
    }

    func testMissingAndCorruptLocalObjectQuarantineBeforeManifestOrReceipt() async throws {
        for corruption in ["missing", "corrupt"] {
            let name = "object-\(corruption)"
            let store = try makeStore(name: name)
            let fixture = try addBinding(to: store, seed: name, eligibility: .eligible)
            let objectURL = objectURL(store: store, digest: fixture.objectDigest)
            if corruption == "missing" {
                try FileManager.default.removeItem(at: objectURL)
            } else {
                try Data("corrupt".utf8).write(to: objectURL)
            }
            let hq = FakeArchiveReplicaBackend(replicaID: "hq")
            let m1 = FakeArchiveReplicaBackend(replicaID: "m1")
            let coordinator = try makeCoordinator(store: store, hq: hq, m1: m1)

            let result = await coordinator.runOnce(limit: 1)

            XCTAssertEqual(result.quarantined, 1, corruption)
            XCTAssertTrue(hq.events().isEmpty, corruption)
            XCTAssertEqual(
                try store.catalog.replicaWork(
                    manifestSHA256: fixture.binding.manifestSHA256,
                    replicaID: "hq"
                )?.lastError,
                corruption == "missing" ? "local_object_missing" : "local_object_corrupt"
            )
        }
    }

    func testWholeSourceHashMismatchQuarantinesBeforeManifestAndReceiptPublication() async throws {
        let store = try makeStore(name: "whole-mismatch")
        let fixture = try addBinding(
            to: store,
            seed: "whole-mismatch",
            eligibility: .eligible,
            wholeSourceOverride: String(repeating: "0", count: 64)
        )
        let hq = FakeArchiveReplicaBackend(replicaID: "hq")
        let m1 = FakeArchiveReplicaBackend(replicaID: "m1")
        let coordinator = try makeCoordinator(store: store, hq: hq, m1: m1)

        let result = await coordinator.runOnce(limit: 1)

        XCTAssertEqual(result.quarantined, 1)
        XCTAssertEqual(hq.events(), ["headObject", "putObject"])
        XCTAssertEqual(
            try store.catalog.replicaWork(
                manifestSHA256: fixture.binding.manifestSHA256,
                replicaID: "hq"
            )?.lastError,
            "local_whole_hash_mismatch"
        )
    }

    func testFrozenBackendErrorClassification() async throws {
        struct FailureCase {
            let name: String
            let error: ArchiveReplicaBackendError
            let expectedState: ArchiveReplicaState
            let expectedSymbol: String
        }
        let cases: [FailureCase] = [
            .init(name: "network", error: .transport(.network), expectedState: .retryWait, expectedSymbol: "transport_network"),
            .init(name: "timeout", error: .transport(.timedOut), expectedState: .retryWait, expectedSymbol: "transport_timeout"),
            .init(name: "408", error: .unexpectedStatus(408), expectedState: .retryWait, expectedSymbol: "transport_timeout"),
            .init(name: "429", error: .unexpectedStatus(429), expectedState: .retryWait, expectedSymbol: "remote_rate_limited"),
            .init(name: "500", error: .unexpectedStatus(500), expectedState: .retryWait, expectedSymbol: "remote_server_unavailable"),
            .init(name: "tls", error: .transport(.tls), expectedState: .quarantined, expectedSymbol: "transport_tls"),
            .init(name: "401", error: .unexpectedStatus(401), expectedState: .quarantined, expectedSymbol: "remote_auth_rejected"),
            .init(name: "403", error: .unexpectedStatus(403), expectedState: .quarantined, expectedSymbol: "remote_auth_rejected"),
            .init(name: "redirect", error: .redirectRejected, expectedState: .quarantined, expectedSymbol: "remote_origin_violation"),
            .init(name: "final-url", error: .finalURLMismatch, expectedState: .quarantined, expectedSymbol: "remote_origin_violation"),
            .init(name: "409", error: .unexpectedStatus(409), expectedState: .quarantined, expectedSymbol: "remote_content_conflict"),
            .init(name: "422", error: .unexpectedStatus(422), expectedState: .quarantined, expectedSymbol: "remote_invalid_content"),
            .init(name: "400", error: .unexpectedStatus(400), expectedState: .quarantined, expectedSymbol: "remote_protocol_contradiction"),
            .init(name: "non-http", error: .notHTTPResponse, expectedState: .quarantined, expectedSymbol: "remote_protocol_contradiction"),
            .init(name: "telemetry-unsupported", error: .telemetryUnsupported, expectedState: .quarantined, expectedSymbol: "remote_protocol_contradiction"),
            .init(name: "size", error: .responseTooLarge(.object), expectedState: .quarantined, expectedSymbol: "remote_response_too_large"),
        ]

        for failureCase in cases {
            let store = try makeStore(name: "classification-\(failureCase.name)")
            let fixture = try addBinding(
                to: store,
                seed: "classification-\(failureCase.name)",
                eligibility: .eligible
            )
            let hq = FakeArchiveReplicaBackend(replicaID: "hq")
            hq.setFailure(operation: "headObject", error: failureCase.error)
            let m1 = FakeArchiveReplicaBackend(replicaID: "m1")
            let coordinator = try makeCoordinator(
                store: store,
                hq: hq,
                m1: m1,
                jitter: ArchiveRetryJitter(sampleUnit: { 1 })
            )

            _ = await coordinator.runOnce(limit: 1)

            let row = try store.catalog.replicaWork(
                manifestSHA256: fixture.binding.manifestSHA256,
                replicaID: "hq"
            )
            XCTAssertEqual(row?.state, failureCase.expectedState, failureCase.name)
            XCTAssertEqual(row?.lastError, failureCase.expectedSymbol, failureCase.name)
            XCTAssertEqual(row?.attempts, 1, failureCase.name)
        }
    }

    func testManualRetryClearsBothPauseKindsForSelectedReplicaOnly() async throws {
        let store = try makeStore(name: "manual-retry")
        let fixtures = try [
            addBinding(to: store, seed: "manual-retry-1", eligibility: .eligible),
            addBinding(to: store, seed: "manual-retry-2", eligibility: .eligible),
        ]
        let hq = FakeArchiveReplicaBackend(replicaID: "hq")
        let m1 = FakeArchiveReplicaBackend(replicaID: "m1")
        hq.setFailure(operation: "headObject", error: .transport(.network))
        m1.setFailure(operation: "headObject", error: .unexpectedStatus(401))
        let coordinator = try makeCoordinator(store: store, hq: hq, m1: m1)

        let first = await coordinator.runBacklogPass(perReplicaLimit: 2)

        XCTAssertEqual(first.retryPausedReplicaIDs, ["hq"])
        XCTAssertEqual(first.pausedReplicaIDs, ["m1"])
        let hqEventsWhilePaused = hq.events()

        try await coordinator.retryQuarantined(replicaID: "m1")
        m1.clearFailure()
        let afterAttentionRetry = await coordinator.runBacklogPass(perReplicaLimit: 2)

        XCTAssertEqual(afterAttentionRetry.retryPausedReplicaIDs, ["hq"])
        XCTAssertTrue(afterAttentionRetry.pausedReplicaIDs.isEmpty)
        XCTAssertEqual(afterAttentionRetry.verifiedByReplica["m1"], 2)
        XCTAssertEqual(hq.events(), hqEventsWhilePaused)

        hq.clearFailure()
        try await coordinator.retryQuarantined(replicaID: "hq")
        let afterTransientRetry = await coordinator.runBacklogPass(perReplicaLimit: 2)

        XCTAssertTrue(afterTransientRetry.retryPausedReplicaIDs.isEmpty)
        XCTAssertTrue(afterTransientRetry.pausedReplicaIDs.isEmpty)
        XCTAssertEqual(afterTransientRetry.verifiedByReplica["hq"], 1)
        let hqStates = try fixtures.compactMap {
            try store.catalog.replicaWork(
                manifestSHA256: $0.binding.manifestSHA256,
                replicaID: "hq"
            )?.state
        }
        XCTAssertEqual(hqStates.filter { $0 == .retryWait }.count, 1)
        XCTAssertEqual(hqStates.filter { $0 == .verified }.count, 1)
    }

    func testResumeClearsBothPauseKindsForSelectedReplicaOnly() async throws {
        let store = try makeStore(name: "manual-resume")
        _ = try addBinding(to: store, seed: "manual-resume-1", eligibility: .eligible)
        _ = try addBinding(to: store, seed: "manual-resume-2", eligibility: .eligible)
        let hq = FakeArchiveReplicaBackend(replicaID: "hq")
        let m1 = FakeArchiveReplicaBackend(replicaID: "m1")
        hq.setFailure(operation: "headObject", error: .transport(.network))
        m1.setFailure(operation: "headObject", error: .unexpectedStatus(401))
        let coordinator = try makeCoordinator(store: store, hq: hq, m1: m1)

        let first = await coordinator.runBacklogPass(perReplicaLimit: 2)

        XCTAssertEqual(first.retryPausedReplicaIDs, ["hq"])
        XCTAssertEqual(first.pausedReplicaIDs, ["m1"])
        let m1EventsWhilePaused = m1.events()

        hq.clearFailure()
        await coordinator.resumeAfterAttention(replicaID: "hq")
        let afterTransientResume = await coordinator.runBacklogPass(perReplicaLimit: 2)

        XCTAssertTrue(afterTransientResume.retryPausedReplicaIDs.isEmpty)
        XCTAssertEqual(afterTransientResume.pausedReplicaIDs, ["m1"])
        XCTAssertEqual(afterTransientResume.verifiedByReplica["hq"], 1)
        XCTAssertEqual(m1.events(), m1EventsWhilePaused)

        m1.clearFailure()
        await coordinator.resumeAfterAttention(replicaID: "m1")
        let afterAttentionResume = await coordinator.runBacklogPass(perReplicaLimit: 2)

        XCTAssertTrue(afterAttentionResume.retryPausedReplicaIDs.isEmpty)
        XCTAssertTrue(afterAttentionResume.pausedReplicaIDs.isEmpty)
        XCTAssertEqual(afterAttentionResume.verifiedByReplica["m1"], 1)
    }

    func testCoordinatorSourceHasNoLegacyOffloadOrDestructiveSurface() throws {
        let testURL = URL(fileURLWithPath: #filePath)
        let sourceURL = testURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("EngramCoreWrite/ArchiveV2/ArchiveReplicationCoordinator.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        for forbidden in [
            "RemoteSync",
            "EngramRemoteBackend",
            "Offload",
            "offload",
            "purge",
            "rehydrate",
            "delete",
            "vacuum",
        ] {
            XCTAssertFalse(source.contains(forbidden), forbidden)
        }
    }

    private static let completeCallOrder = [
        "headObject",
        "putObject",
        "headManifest",
        "putManifest",
        "createReceipt",
        "getReceipt",
    ]

    private struct Store {
        let root: URL
        let cas: ImmutableArchiveCAS
        let catalog: ArchiveCatalog
    }

    private struct Fixture {
        let binding: ArchiveBinding
        let manifestBytes: Data
        let objectDigest: String
    }

    private func makeStore(name: String) throws -> Store {
        let storeRoot = root.appendingPathComponent(name, isDirectory: true)
        let cas = try ImmutableArchiveCAS(root: storeRoot)
        let catalog = try ArchiveCatalog(root: storeRoot, machineID: machineID)
        try catalog.migrate()
        return Store(root: storeRoot, cas: cas, catalog: catalog)
    }

    private func addBinding(
        to store: Store,
        seed: String,
        eligibility: ArchiveRemoteEligibility,
        wholeSourceOverride: String? = nil
    ) throws -> Fixture {
        let raw = Data("exact-source-\(seed)".utf8)
        let objectDigest = ArchiveV2Hash.sha256(raw)
        _ = try store.cas.publishObject(raw: raw, expectedSHA256: objectDigest)
        let captureID = ArchiveV2Hash.sha256(Data("capture-\(seed)".utf8))
        let locator = "/tmp/\(seed)/session.jsonl"
        let wholeSourceSHA256 = wholeSourceOverride ?? objectDigest
        let chunks = [
            try ArchiveChunkReference(
                ordinal: 0,
                rawSHA256: objectDigest,
                rawByteCount: Int64(raw.count)
            ),
        ]
        let generation = try ArchiveSourceGeneration(
            device: 1,
            inode: Int64(abs(seed.hashValue % 1_000_000) + 1),
            size: Int64(raw.count),
            mtimeNs: 3,
            ctimeNs: 4,
            mode: Int64(S_IFREG | 0o600)
        )
        let replay = try ArchiveReplayLayout(
            strategy: .singleFile,
            relativePaths: ["sessions/\(seed).jsonl"]
        )
        let unbound = try ArchiveSourceManifest(
            captureID: captureID,
            machineID: machineID,
            source: "codex",
            locator: locator,
            sessionID: nil,
            capturedAt: "2026-07-11T00:00:00.000Z",
            generation: generation,
            wholeSourceSHA256: wholeSourceSHA256,
            rawByteCount: Int64(raw.count),
            chunks: chunks,
            replayLayout: replay
        )
        let unboundBytes = try ArchiveCanonicalJSON.encode(unbound)
        _ = try store.cas.publishManifest(
            unboundBytes,
            expectedSHA256: ArchiveV2Hash.sha256(unboundBytes)
        )
        _ = try store.catalog.recordCapture(canonicalManifestBytes: unboundBytes)
        let bound = try ArchiveSourceManifest(
            captureID: captureID,
            machineID: machineID,
            source: "codex",
            locator: locator,
            sessionID: "session-\(seed)",
            capturedAt: "2026-07-11T00:00:00.000Z",
            generation: generation,
            wholeSourceSHA256: wholeSourceSHA256,
            rawByteCount: Int64(raw.count),
            chunks: chunks,
            replayLayout: replay
        )
        let manifestBytes = try ArchiveCanonicalJSON.encode(bound)
        let manifestSHA256 = ArchiveV2Hash.sha256(manifestBytes)
        _ = try store.cas.publishManifest(
            manifestBytes,
            expectedSHA256: manifestSHA256
        )
        let binding = try store.catalog.bind(
            canonicalManifestBytes: manifestBytes,
            sourceSnapshotFingerprint: ArchiveV2Hash.sha256(Data("snapshot-\(seed)".utf8)),
            boundAt: "2026-07-11T00:00:00.000Z"
        )
        switch eligibility {
        case .unknown:
            break
        case .eligible:
            XCTAssertTrue(
                try store.catalog.setRemotePolicySnapshot(
                    manifestSHA256: binding.manifestSHA256,
                    projectRootSnapshot: "/tmp/project/\(seed)",
                    eligibility: .eligible
                )
            )
        case .excluded:
            XCTAssertTrue(
                try store.catalog.setRemotePolicySnapshot(
                    manifestSHA256: binding.manifestSHA256,
                    projectRootSnapshot: nil,
                    eligibility: .excluded
                )
            )
        }
        return Fixture(
            binding: binding,
            manifestBytes: manifestBytes,
            objectDigest: objectDigest
        )
    }

    private func makeCoordinator(
        store: Store,
        hq: FakeArchiveReplicaBackend,
        m1: FakeArchiveReplicaBackend,
        clock: LockedTestClock? = nil,
        jitter: ArchiveRetryJitter = ArchiveRetryJitter(sampleUnit: { 0.5 })
    ) throws -> ArchiveReplicationCoordinator {
        let resolvedClock: LockedTestClock
        if let clock {
            resolvedClock = clock
        } else {
            resolvedClock = LockedTestClock(
                try date("2026-07-11T00:00:00.000Z")
            )
        }
        return try ArchiveReplicationCoordinator(
            catalog: store.catalog,
            cas: store.cas,
            backends: [hq, m1],
            clock: { resolvedClock.now() },
            jitter: jitter
        )
    }

    private func seedRetryAttempts(
        count: Int,
        fixture: Fixture,
        replicaID: String,
        catalog: ArchiveCatalog
    ) throws {
        let retryAt = "2026-07-10T23:59:00.000Z"
        _ = try catalog.reconcileEligibleReplicaRows(updatedAt: retryAt)
        for _ in 0 ..< count {
            let claim = try XCTUnwrap(try catalog.claimReplicaWork(
                replicaID: replicaID,
                limit: 1,
                retryQuota: 1,
                now: retryAt
            ).first { $0.manifestSHA256 == fixture.binding.manifestSHA256 })
            XCTAssertTrue(try catalog.markReplicaRetry(
                claim,
                from: .uploadingObjects,
                nextRetryAt: retryAt,
                lastError: "transport_network",
                updatedAt: retryAt
            ))
        }
    }

    private func objectURL(store: Store, digest: String) -> URL {
        store.root
            .appendingPathComponent("objects/sha256", isDirectory: true)
            .appendingPathComponent(String(digest.prefix(2)), isDirectory: true)
            .appendingPathComponent(digest)
    }

    private func manifestURL(store: Store, digest: String) -> URL {
        store.root
            .appendingPathComponent("manifests/sha256", isDirectory: true)
            .appendingPathComponent(String(digest.prefix(2)), isDirectory: true)
            .appendingPathComponent("\(digest).json")
    }

    private func receiptBytes(
        serverID: String,
        manifestBytes: Data
    ) throws -> Data {
        let manifest = try ArchiveCanonicalJSON.decode(
            ArchiveSourceManifest.self,
            from: manifestBytes
        )
        return try ArchiveCanonicalJSON.encode(
            ArchiveServerReceipt(
                serverID: serverID,
                machineID: manifest.machineID,
                sessionID: try XCTUnwrap(manifest.sessionID),
                captureID: manifest.captureID,
                manifestSHA256: ArchiveV2Hash.sha256(manifestBytes),
                wholeSourceSHA256: manifest.wholeSourceSHA256,
                objectCount: manifest.chunks.count,
                rawByteCount: manifest.rawByteCount,
                storedAt: "2026-07-11T00:20:04.000Z"
            )
        )
    }

    private func advanceToVerifying(
        _ catalog: ArchiveCatalog,
        claim: ArchiveReplicaClaim
    ) throws {
        guard try catalog.transitionReplicaClaim(
            claim,
            from: .uploadingObjects,
            to: .uploadingManifest,
            updatedAt: "2026-07-11T00:20:02.000Z"
        ), try catalog.transitionReplicaClaim(
            claim,
            from: .uploadingManifest,
            to: .requestingReceipt,
            updatedAt: "2026-07-11T00:20:03.000Z"
        ), try catalog.transitionReplicaClaim(
            claim,
            from: .requestingReceipt,
            to: .verifyingReceipt,
            updatedAt: "2026-07-11T00:20:04.000Z"
        ) else {
            throw TestFailure.unexpectedLostClaim
        }
    }

    private func date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return try XCTUnwrap(formatter.date(from: value))
    }
}

private enum TestFailure: Error {
    case missingManifest
    case unexpectedLostClaim
}

private enum FakeReceiptMutation: String, Sendable {
    case none
    case wrongServer
    case wrongMachine
    case wrongSession
    case wrongCapture
    case wrongManifest
    case wrongWholeSource
    case wrongObjectCount
    case wrongRawByteCount
    case noncanonical
}

private final class LockedTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Date) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}

private final class WorkGateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed: Bool

    init(_ allowed: Bool) {
        self.allowed = allowed
    }

    func value() -> Bool {
        lock.withLock { allowed }
    }

    func set(_ value: Bool) {
        lock.withLock { allowed = value }
    }
}

private final class AdvancingTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    private let step: TimeInterval

    init(start: Date, step: TimeInterval) {
        value = start
        self.step = step
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        let current = value
        value = value.addingTimeInterval(step)
        return current
    }
}

private actor AsyncTestGate {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func enterAndWait() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private final class FakeArchiveReplicaBackend: ArchiveReplicaBackend, @unchecked Sendable {
    let replicaID: String

    private let lock = NSLock()
    private var recordedEvents: [String] = []
    private var objects: [String: Data] = [:]
    private var manifests: [String: Data] = [:]
    private var receipts: [String: Data] = [:]
    private var failureOperation: String?
    private var failure: ArchiveReplicaBackendError?
    private var receiptMutation: FakeReceiptMutation = .none
    private var createReceiptResponse: Data?
    private var headObjectHook: (@Sendable () throws -> Void)?
    private var operationGates: [String: AsyncTestGate] = [:]
    private var deferredFailureOperation: String?
    private var deferredFailure: ArchiveReplicaBackendError?

    init(replicaID: String) {
        self.replicaID = replicaID
    }

    func setFailure(operation: String, error: ArchiveReplicaBackendError) {
        lock.lock()
        failureOperation = operation
        failure = error
        lock.unlock()
    }

    func clearFailure() {
        lock.lock()
        failureOperation = nil
        failure = nil
        deferredFailureOperation = nil
        deferredFailure = nil
        lock.unlock()
    }

    func setReceiptMutation(_ mutation: FakeReceiptMutation) {
        lock.lock()
        receiptMutation = mutation
        lock.unlock()
    }

    func setCreateReceiptResponse(_ data: Data) {
        lock.lock()
        createReceiptResponse = data
        lock.unlock()
    }

    func setHeadObjectHook(_ hook: @escaping @Sendable () throws -> Void) {
        lock.lock()
        headObjectHook = hook
        lock.unlock()
    }

    func setHeadObjectGate(_ gate: AsyncTestGate) {
        setOperationGate("headObject", gate: gate)
    }

    func setOperationGate(_ operation: String, gate: AsyncTestGate) {
        lock.lock()
        operationGates[operation] = gate
        lock.unlock()
    }

    func setDeferredFailure(
        operation: String,
        error: ArchiveReplicaBackendError,
        gate: AsyncTestGate
    ) {
        lock.lock()
        operationGates[operation] = gate
        deferredFailureOperation = operation
        deferredFailure = error
        lock.unlock()
    }

    func events() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }

    func headObject(digest: String) async throws -> Bool {
        try record("headObject")
        let hook = takeHeadObjectHook()
        try hook?()
        await waitIfGated("headObject")
        try throwDeferredFailureIfNeeded("headObject")
        return hasObject(digest)
    }

    func putObject(digest: String, data: Data) async throws {
        try record("putObject")
        await waitIfGated("putObject")
        try throwDeferredFailureIfNeeded("putObject")
        storeObject(data, digest: digest)
    }

    func getObject(digest: String) async throws -> Data {
        try record("getObject")
        await waitIfGated("getObject")
        try throwDeferredFailureIfNeeded("getObject")
        guard let data = object(digest) else {
            throw ArchiveReplicaBackendError.unexpectedStatus(404)
        }
        return data
    }

    func headManifest(digest: String) async throws -> Bool {
        try record("headManifest")
        await waitIfGated("headManifest")
        try throwDeferredFailureIfNeeded("headManifest")
        return hasManifest(digest)
    }

    func putManifest(digest: String, data: Data) async throws {
        try record("putManifest")
        await waitIfGated("putManifest")
        try throwDeferredFailureIfNeeded("putManifest")
        storeManifest(data, digest: digest)
    }

    func getManifest(digest: String) async throws -> Data {
        try record("getManifest")
        await waitIfGated("getManifest")
        try throwDeferredFailureIfNeeded("getManifest")
        guard let data = manifest(digest) else {
            throw ArchiveReplicaBackendError.unexpectedStatus(404)
        }
        return data
    }

    func createReceipt(manifestDigest: String) async throws -> Data {
        try record("createReceipt")
        await waitIfGated("createReceipt")
        try throwDeferredFailureIfNeeded("createReceipt")
        let inputs = try receiptInputs(manifestDigest: manifestDigest)

        let receiptBytes = try makeReceipt(
            manifestBytes: inputs.manifestBytes,
            manifestDigest: manifestDigest,
            mutation: inputs.mutation
        )
        storeReceipt(receiptBytes, manifestDigest: manifestDigest)
        return inputs.responseOverride ?? receiptBytes
    }

    func getReceipt(manifestDigest: String) async throws -> Data {
        try record("getReceipt")
        await waitIfGated("getReceipt")
        try throwDeferredFailureIfNeeded("getReceipt")
        guard let data = receipt(manifestDigest) else {
            throw ArchiveReplicaBackendError.unexpectedStatus(404)
        }
        return data
    }

    func listMachines(cursor: String?, limit: Int) async throws -> ArchiveMachinePage {
        try record("listMachines")
        return try ArchiveMachinePage(machineIDs: [], nextCursor: nil)
    }

    func listReceipts(
        machineID: String,
        cursor: String?,
        limit: Int
    ) async throws -> ArchiveReceiptPage {
        try record("listReceipts")
        return try ArchiveReceiptPage(receipts: [], nextCursor: nil)
    }

    private func record(_ operation: String) throws {
        lock.lock()
        recordedEvents.append(operation)
        let injected = failureOperation == operation ? failure : nil
        lock.unlock()
        if let injected { throw injected }
    }

    private func hasObject(_ digest: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return objects[digest] != nil
    }

    private func object(_ digest: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return objects[digest]
    }

    private func storeObject(_ data: Data, digest: String) {
        lock.lock()
        objects[digest] = data
        lock.unlock()
    }

    private func hasManifest(_ digest: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return manifests[digest] != nil
    }

    private func manifest(_ digest: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return manifests[digest]
    }

    private func storeManifest(_ data: Data, digest: String) {
        lock.lock()
        manifests[digest] = data
        lock.unlock()
    }

    private func receiptInputs(manifestDigest: String) throws -> (
        manifestBytes: Data,
        mutation: FakeReceiptMutation,
        responseOverride: Data?
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard let manifestBytes = manifests[manifestDigest] else {
            throw TestFailure.missingManifest
        }
        return (manifestBytes, receiptMutation, createReceiptResponse)
    }

    private func storeReceipt(_ data: Data, manifestDigest: String) {
        lock.lock()
        receipts[manifestDigest] = data
        lock.unlock()
    }

    private func receipt(_ manifestDigest: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return receipts[manifestDigest]
    }

    private func takeHeadObjectHook() -> (@Sendable () throws -> Void)? {
        lock.lock()
        let hook = headObjectHook
        headObjectHook = nil
        lock.unlock()
        return hook
    }

    private func waitIfGated(_ operation: String) async {
        if let gate = takeOperationGate(operation) {
            await gate.enterAndWait()
        }
    }

    private func takeOperationGate(_ operation: String) -> AsyncTestGate? {
        lock.lock()
        defer { lock.unlock() }
        return operationGates.removeValue(forKey: operation)
    }

    private func throwDeferredFailureIfNeeded(_ operation: String) throws {
        lock.lock()
        let injected = deferredFailureOperation == operation ? deferredFailure : nil
        if injected != nil {
            deferredFailureOperation = nil
            deferredFailure = nil
        }
        lock.unlock()
        if let injected { throw injected }
    }

    private func makeReceipt(
        manifestBytes: Data,
        manifestDigest: String,
        mutation: FakeReceiptMutation
    ) throws -> Data {
        let manifest = try ArchiveCanonicalJSON.decode(
            ArchiveSourceManifest.self,
            from: manifestBytes
        )
        let receipt = try ArchiveServerReceipt(
            serverID: mutation == .wrongServer ? "wrong-server" : replicaID,
            machineID: mutation == .wrongMachine
                ? "99999999-8888-7777-6666-555555555555"
                : manifest.machineID,
            sessionID: mutation == .wrongSession
                ? "wrong-session"
                : try XCTUnwrap(manifest.sessionID),
            captureID: mutation == .wrongCapture
                ? String(repeating: "0", count: 64)
                : manifest.captureID,
            manifestSHA256: mutation == .wrongManifest
                ? String(repeating: "0", count: 64)
                : manifestDigest,
            wholeSourceSHA256: mutation == .wrongWholeSource
                ? String(repeating: "0", count: 64)
                : manifest.wholeSourceSHA256,
            objectCount: mutation == .wrongObjectCount
                ? manifest.chunks.count + 1
                : manifest.chunks.count,
            rawByteCount: mutation == .wrongRawByteCount
                ? manifest.rawByteCount + 1
                : manifest.rawByteCount,
            storedAt: "2026-07-11T00:00:10.000Z"
        )
        let canonical = try ArchiveCanonicalJSON.encode(receipt)
        if mutation == .noncanonical {
            var value = Data([0x20])
            value.append(canonical)
            return value
        }
        return canonical
    }
}
