import Darwin
import Foundation
import GRDB
import XCTest
@testable import EngramCollectorCore

final class CollectorEventCoordinatorTests: XCTestCase {
    func testDefaultOffPerformsNoOwnerOrStreamIO() throws {
        var ownerCalls = 0
        var streamCalls = 0
        let coordinator = CollectorEventCoordinator(
            configuration: .init(rootID: "off", source: .codex, rootPath: "/not-accessed", revision: 1),
            budget: eventBudget(),
            ownerFactory: { ownerCalls += 1; throw CoordinatorFixture.Failure.injected },
            streamFactory: { _ in streamCalls += 1; throw CoordinatorFixture.Failure.injected }
        )
        try coordinator.start(epoch: "epoch")
        let step = try coordinator.step(budget: scanBudget)
        try coordinator.stop()
        XCTAssertEqual(step.snapshot.phase, .stopped)
        XCTAssertNil(step.bootstrap)
        XCTAssertEqual(step.appliedBatches, 0)
        XCTAssertEqual(ownerCalls, 0)
        XCTAssertEqual(streamCalls, 0)
    }

    func testInvalidBudgetsRejectBeforeOwnerFactory() throws {
        for invalid in 0..<6 {
            var ownerCalls = 0
            var streamCalls = 0
            let coordinator = CollectorEventCoordinator(
                enabled: true,
                configuration: .init(rootID: "invalid", source: .codex, rootPath: "/not-accessed", revision: 1),
                budget: eventBudget(paths: invalid == 0 ? -1 : 8, perPath: invalid == 1 ? -1 : 64,
                                    totalPaths: invalid == 2 ? -1 : 512, checkpoints: invalid == 3 ? -1 : 64,
                                    batches: invalid == 4 ? -1 : 8, queueBytes: invalid == 5 ? -1 : 1024),
                ownerFactory: { ownerCalls += 1; throw CoordinatorFixture.Failure.injected },
                streamFactory: { _ in streamCalls += 1; throw CoordinatorFixture.Failure.injected }
            )
            XCTAssertThrowsError(try coordinator.start(epoch: "epoch")) {
                XCTAssertEqual($0 as? CollectorInventoryError, .invalidBudget)
            }
            XCTAssertEqual(ownerCalls, 0)
            XCTAssertEqual(streamCalls, 0)
        }
    }

    func testRestartRequestCommitsBeforeStreamFactoryAndStart() throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let owner = try fixture.open()
        defer { try? owner.close() }
        _ = try owner.enrollAndActivateRoot(fixture.configuration)
        for _ in 0..<3 { _ = try owner.requestEventReconciliation(configuration: fixture.configuration, reason: .overflow) }
        let before = try state(owner, fixture)
        var factoryRevision: Int64?
        var startRevision: Int64?
        let stream = CoordinatorFakeStream()
        stream.onStart = { startRevision = try self.state(owner, fixture).requestedRevision }
        let coordinator = make(owner, fixture, factory: { request in
            factoryRevision = try self.state(owner, fixture).requestedRevision
            XCTAssertEqual(request.binding.configuration, fixture.configuration)
            XCTAssertNil(request.resumeCheckpoint)
            XCTAssertNil(try self.state(owner, fixture).activeScan)
            return stream
        })
        try coordinator.start(epoch: "epoch")
        let snapshot = try coordinator.snapshot()
        XCTAssertEqual(factoryRevision, before.requestedRevision + 1)
        XCTAssertEqual(startRevision, factoryRevision)
        XCTAssertEqual(snapshot.recoveryRevision, factoryRevision)
        XCTAssertEqual(snapshot.phase, .recovering)
        XCTAssertFalse(snapshot.historyDone)
        XCTAssertNil(try state(owner, fixture).activeScan)
        XCTAssertEqual(stream.startCount, 1)
        try coordinator.stop()
        XCTAssertNotNil(try owner.rootState(rootID: fixture.configuration.rootID))
    }

    func testWatchStartsBeforeFreshReconciliationAndRecoveryNeverAppliesEvents() throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let owner = try fixture.open()
        defer { try? owner.close() }
        let stream = CoordinatorFakeStream()
        stream.onStart = { XCTAssertNil(try self.state(owner, fixture).activeScan) }
        let coordinator = make(owner, fixture, stream: stream)
        try coordinator.start(epoch: "epoch")
        XCTAssertEqual(stream.emit(batch("one", paths: ["rollout-pending.jsonl"])), .queued)
        for _ in 0..<3 {
            let step = try coordinator.step(budget: scanBudget)
            XCTAssertEqual(step.appliedBatches, 0)
            XCTAssertEqual(step.snapshot.phase, .recovering)
            XCTAssertNil(try state(owner, fixture).eventCheckpoint)
        }
        let completed = try state(owner, fixture)
        XCTAssertGreaterThanOrEqual(completed.completedRevision, try XCTUnwrap(coordinator.snapshot().recoveryRevision))
        XCTAssertEqual(stream.emit(.historyDone), .controlAccepted)
        let release = try coordinator.step(budget: scanBudget)
        XCTAssertEqual(release.snapshot.phase, .watching)
        XCTAssertEqual(release.appliedBatches, 0)
        XCTAssertNil(try state(owner, fixture).eventCheckpoint)
        let applied = try coordinator.step(budget: scanBudget)
        XCTAssertEqual(applied.appliedBatches, 1)
        assertCheckpoint(try state(owner, fixture).eventCheckpoint, .init(epoch: "epoch", cursor: "one"))
        try coordinator.stop()
        try owner.close()
        XCTAssertEqual(try fixture.integer("SELECT COUNT(*) FROM collector_locators"), 1)
    }

    func testOldStickyScanFinishedCannotSatisfyNewRestartFence() throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        try fixture.file("rollout-a.jsonl")
        try fixture.file("rollout-b.jsonl")
        let owner = try fixture.open()
        defer { try? owner.close() }
        _ = try owner.enrollAndActivateRoot(fixture.configuration)
        _ = try owner.stepRoot(fixture.configuration, budget: tinyScanBudget)
        let oldScan = try XCTUnwrap(state(owner, fixture).activeScan)
        let stream = CoordinatorFakeStream()
        let coordinator = make(owner, fixture, stream: stream)
        try coordinator.start(epoch: "epoch")
        let fence = try XCTUnwrap(coordinator.snapshot().recoveryRevision)
        XCTAssertGreaterThan(fence, oldScan.requestedRevision)
        XCTAssertEqual(try state(owner, fixture).activeScan, oldScan)
        XCTAssertEqual(stream.emit(.historyDone), .controlAccepted)
        var oldFinished = false
        for _ in 0..<16 {
            let step = try coordinator.step(budget: tinyScanBudget)
            XCTAssertEqual(step.appliedBatches, 0)
            if step.bootstrap?.outcome == .finished {
                oldFinished = true
                XCTAssertEqual(step.snapshot.phase, .recovering)
                XCTAssertLessThan(try state(owner, fixture).completedRevision, fence)
                break
            }
        }
        XCTAssertTrue(oldFinished)
        try finishRecovery(coordinator, owner, fixture)
        XCTAssertGreaterThanOrEqual(try state(owner, fixture).completedRevision, fence)
        try coordinator.stop()
    }

    func testNewGapDuringRecoveryClosesGenerationInsteadOfChasingFence() throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let owner = try fixture.open()
        defer { try? owner.close() }
        let stream = CoordinatorFakeStream()
        let coordinator = make(owner, fixture, stream: stream)
        try coordinator.start(epoch: "epoch")
        let fence = try XCTUnwrap(coordinator.snapshot().recoveryRevision)
        _ = try owner.requestEventReconciliation(configuration: fixture.configuration, reason: .overflow)
        XCTAssertEqual(stream.emit(.historyDone), .controlAccepted)
        _ = try coordinator.step(budget: scanBudget)
        XCTAssertEqual(try coordinator.snapshot().phase, .recoveryRequired)
        XCTAssertEqual(try coordinator.snapshot().recoveryRevision, fence)
        let sealed = try state(owner, fixture)
        for _ in 0..<12 { _ = try coordinator.step(budget: scanBudget) }
        XCTAssertEqual(try state(owner, fixture), sealed)
        XCTAssertEqual(stream.startCount, 1)
        XCTAssertEqual(stream.emit(batch("late")), .rejectedClosed)
        try coordinator.stop()
    }

    func testQueuedAndDeliveredCallbacksCannotAdvanceDurableCheckpoint() throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let owner = try fixture.open()
        defer { try? owner.close() }
        let stream = CoordinatorFakeStream()
        let coordinator = make(owner, fixture, stream: stream)
        try ready(coordinator, stream, owner, fixture)
        XCTAssertEqual(stream.emit(batch("first")), .queued)
        XCTAssertEqual(stream.emit(batch("second", paths: ["rollout-b.jsonl"])), .queued)
        XCTAssertNil(try state(owner, fixture).eventCheckpoint)
        XCTAssertNil(try coordinator.snapshot().lastAcknowledgedCheckpoint)
        XCTAssertEqual(try coordinator.snapshot().queuedBatchCount, 2)
        XCTAssertEqual(try coordinator.step(budget: scanBudget).appliedBatches, 1)
        assertCheckpoint(try state(owner, fixture).eventCheckpoint, .init(epoch: "epoch", cursor: "first"))
        assertCheckpoint(try coordinator.snapshot().lastAcknowledgedCheckpoint, .init(epoch: "epoch", cursor: "first"))
        XCTAssertEqual(try coordinator.snapshot().queuedBatchCount, 1)
        try coordinator.stop()
        let stopped = try state(owner, fixture)
        XCTAssertGreaterThan(stopped.requestedRevision, stopped.completedRevision)
        assertCheckpoint(stopped.eventCheckpoint, .init(epoch: "epoch", cursor: "first"))
    }

    func testEachBatchRereadsPersistedCheckpointAndUsesByteExactEpoch() throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let owner = try fixture.open()
        defer { try? owner.close() }
        let stream = CoordinatorFakeStream()
        let coordinator = make(owner, fixture, stream: stream)
        try ready(coordinator, stream, owner, fixture, epoch: "é")
        XCTAssertEqual(stream.emit(batch("one", epoch: "é")), .queued)
        _ = try coordinator.step(budget: scanBudget)
        let first = try XCTUnwrap(state(owner, fixture).eventCheckpoint)
        let external = CollectorEventCheckpoint(epoch: "é", cursor: "outside")
        _ = try owner.applyEvents(configuration: fixture.configuration, expectedCheckpoint: first,
                                  nextCheckpoint: external, dirtyRelativePaths: ["rollout-external.jsonl"], budget: eventBudget().ingress)
        XCTAssertEqual(stream.emit(batch("two", epoch: "é")), .queued)
        XCTAssertEqual(try coordinator.step(budget: scanBudget).appliedBatches, 1)
        assertCheckpoint(try state(owner, fixture).eventCheckpoint, .init(epoch: "é", cursor: "two"))
        XCTAssertEqual("é", "e\u{301}")
        XCTAssertNotEqual(Data("é".utf8), Data("e\u{301}".utf8))
        _ = stream.emit(batch("three", epoch: "e\u{301}"))
        _ = try coordinator.step(budget: scanBudget)
        XCTAssertEqual(try coordinator.snapshot().phase, .recoveryRequired)
        XCTAssertEqual(stream.emit(batch("four", epoch: "é")), .rejectedClosed)
        assertCheckpoint(try state(owner, fixture).eventCheckpoint, .init(epoch: "é", cursor: "two"))
        try coordinator.stop()
    }

    func testRawFourBudgetsAndQueueLimitsCountDuplicateUTF8Input() throws {
        let path = "rollout-一.jsonl"
        let cp = CollectorEventCheckpoint(epoch: "流", cursor: "甲")
        let pathBytes = path.utf8.count
        let cpBytes = cp.epoch.utf8.count + cp.cursor.utf8.count
        let cost = 2 * pathBytes + cpBytes
        for limit in 0..<6 {
            let fixture = try CoordinatorFixture()
            defer { fixture.remove() }
            let owner = try fixture.open()
            defer { try? owner.close() }
            let stream = CoordinatorFakeStream()
            let budget = eventBudget(paths: limit == 0 ? 1 : 2, perPath: limit == 1 ? pathBytes - 1 : pathBytes,
                                     totalPaths: limit == 2 ? 2 * pathBytes - 1 : 2 * pathBytes,
                                     checkpoints: limit == 3 ? cpBytes - 1 : 2 * cpBytes,
                                     batches: limit == 4 ? 1 : 2, queueBytes: limit == 5 ? cost - 1 : 2 * cost)
            let coordinator = make(owner, fixture, stream: stream, budget: budget)
            try coordinator.start(epoch: cp.epoch)
            let before = try state(owner, fixture)
            let signal = CollectorEventStreamSignal.batch(.init(nextCheckpoint: cp, dirtyRelativePaths: [path, path]))
            if limit == 4 { XCTAssertEqual(stream.emit(signal), .queued) }
            XCTAssertEqual(stream.emit(signal), .recoveryRequired(.budgetExceeded), "limit \(limit)")
            let pending = try coordinator.snapshot()
            XCTAssertEqual(pending.phase, .recoveryRequired)
            XCTAssertEqual(pending.pendingGap, .budgetExceeded)
            XCTAssertNil(pending.persistedGapRevision)
            XCTAssertLessThanOrEqual(pending.queuedBatchCount, budget.maxQueuedBatches)
            XCTAssertLessThanOrEqual(pending.queuedUTF8Bytes, budget.maxQueuedUTF8Bytes)
            XCTAssertEqual(try state(owner, fixture), before, "callback must not write Owner")
            XCTAssertEqual(stream.emit(signal), .rejectedClosed)
            _ = try coordinator.step(budget: scanBudget)
            XCTAssertEqual(try state(owner, fixture).requestedRevision, before.requestedRevision + 1)
            XCTAssertEqual(try coordinator.snapshot().persistedGapRevision, before.requestedRevision + 1)
            XCTAssertNil(try state(owner, fixture).eventCheckpoint)
            try coordinator.stop()
            try owner.close()
            XCTAssertEqual(try fixture.integer("SELECT COUNT(*) FROM collector_locators"), 0)
        }
    }

    func testExactUTF8BudgetPositiveControlAndDuplicateDirtyRevisions() throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let owner = try fixture.open()
        defer { try? owner.close() }
        let path = "rollout-一.jsonl"
        let cp = CollectorEventCheckpoint(epoch: "流", cursor: "甲")
        let cpBytes = cp.epoch.utf8.count + cp.cursor.utf8.count
        let cost = 2 * path.utf8.count + cpBytes
        let stream = CoordinatorFakeStream()
        let coordinator = make(owner, fixture, stream: stream,
                               budget: eventBudget(paths: 2, perPath: path.utf8.count, totalPaths: 2 * path.utf8.count,
                                                   checkpoints: cpBytes, batches: 1, queueBytes: cost))
        try ready(coordinator, stream, owner, fixture, epoch: cp.epoch)
        XCTAssertEqual(stream.emit(.batch(.init(nextCheckpoint: cp, dirtyRelativePaths: [path, path]))), .queued)
        XCTAssertEqual(try coordinator.snapshot().queuedUTF8Bytes, cost)
        XCTAssertEqual(try coordinator.step(budget: scanBudget).appliedBatches, 1)
        assertCheckpoint(try state(owner, fixture).eventCheckpoint, cp)
        try coordinator.stop()
        try owner.close()
        XCTAssertEqual(try fixture.integer("SELECT COUNT(*) FROM collector_locators"), 1)
        XCTAssertEqual(try fixture.integer("SELECT SUM(dirty_revision) FROM collector_locators"), 2)
    }

    func testOwnerReconciliationResultClosesGenerationWithoutDoubleGapOrAck() throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let owner = try fixture.open()
        defer { try? owner.close() }
        let stream = CoordinatorFakeStream()
        let coordinator = make(owner, fixture, stream: stream, budget: eventBudget(checkpoints: 8))
        try ready(coordinator, stream, owner, fixture, epoch: "e")
        let external = CollectorEventCheckpoint(epoch: "e", cursor: "1234567")
        _ = try owner.applyEvents(configuration: fixture.configuration, expectedCheckpoint: nil,
                                  nextCheckpoint: external, dirtyRelativePaths: ["rollout-seed.jsonl"], budget: eventBudget().ingress)
        let before = try state(owner, fixture)
        XCTAssertEqual(stream.emit(batch("n", epoch: "e")), .queued)
        let step = try coordinator.step(budget: scanBudget)
        XCTAssertEqual(step.appliedBatches, 0)
        XCTAssertEqual(step.snapshot.phase, .recoveryRequired)
        XCTAssertEqual(step.snapshot.persistedGapRevision, before.requestedRevision + 1)
        XCTAssertEqual(try state(owner, fixture).requestedRevision, before.requestedRevision + 1)
        assertCheckpoint(try state(owner, fixture).eventCheckpoint, external)
        XCTAssertNil(step.snapshot.lastAcknowledgedCheckpoint)
        XCTAssertEqual(stream.emit(batch("late", epoch: "e")), .rejectedClosed)
        try coordinator.stop()
        XCTAssertEqual(try state(owner, fixture).requestedRevision, before.requestedRevision + 1)
    }

    func testQueueByteBudgetIsAggregateAndNeverGrowsAfterLossLatch() throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let owner = try fixture.open()
        defer { try? owner.close() }
        let path = "rollout-一.jsonl"
        let cp = CollectorEventCheckpoint(epoch: "流", cursor: "甲")
        let cost = 2 * path.utf8.count + cp.epoch.utf8.count + cp.cursor.utf8.count
        let stream = CoordinatorFakeStream()
        let coordinator = make(owner, fixture, stream: stream, budget: eventBudget(batches: 8, queueBytes: 2 * cost))
        try coordinator.start(epoch: cp.epoch)
        let signal = CollectorEventStreamSignal.batch(.init(nextCheckpoint: cp, dirtyRelativePaths: [path, path]))
        XCTAssertEqual(stream.emit(signal), .queued)
        XCTAssertEqual(stream.emit(signal), .queued)
        XCTAssertEqual(try coordinator.snapshot().queuedUTF8Bytes, 2 * cost)
        XCTAssertEqual(try coordinator.snapshot().queuedBatchCount, 2)
        XCTAssertEqual(stream.emit(signal), .recoveryRequired(.budgetExceeded))
        let sealed = try coordinator.snapshot()
        for _ in 0..<256 { XCTAssertEqual(stream.emit(signal), .rejectedClosed) }
        XCTAssertEqual(try coordinator.snapshot().queuedUTF8Bytes, sealed.queuedUTF8Bytes)
        XCTAssertEqual(try coordinator.snapshot().queuedBatchCount, sealed.queuedBatchCount)
        XCTAssertNil(try state(owner, fixture).eventCheckpoint)
        try coordinator.stop()
        XCTAssertNotNil(try coordinator.snapshot().persistedGapRevision)
    }

    func testCompletedRecoveryScanWaitsForHistoryDoneWithoutRescanning() throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        var commits = 0
        let owner = try fixture.open(hooks: .init(beforeInventoryCommit: { commits += 1 }))
        defer { try? owner.close() }
        let stream = CoordinatorFakeStream()
        let coordinator = make(owner, fixture, stream: stream)
        try coordinator.start(epoch: "epoch")
        let first = try coordinator.step(budget: scanBudget)
        XCTAssertEqual(first.bootstrap?.outcome, .finished)
        XCTAssertEqual(first.snapshot.phase, .recovering)
        XCTAssertFalse(first.snapshot.historyDone)
        let afterScan = commits
        let completed = try state(owner, fixture)
        for _ in 0..<16 {
            let step = try coordinator.step(budget: scanBudget)
            XCTAssertNil(step.bootstrap)
            XCTAssertEqual(step.appliedBatches, 0)
            XCTAssertEqual(step.snapshot.phase, .recovering)
        }
        XCTAssertEqual(commits, afterScan)
        XCTAssertEqual(try state(owner, fixture), completed)
        XCTAssertEqual(stream.emit(.historyDone), .controlAccepted)
        let release = try coordinator.step(budget: scanBudget)
        XCTAssertEqual(release.snapshot.phase, .watching)
        XCTAssertNil(release.bootstrap)
        XCTAssertEqual(commits, afterScan)
        try coordinator.stop()
    }

    func testEveryLossSignalSealsImmediatelyAndPersistsOnlyOneGapPerGeneration() throws {
        let cases: [(CollectorEventStreamSignal, CollectorEventGapReason)] = [
            (.loss(.overflow), .overflow), (.loss(.continuityLoss), .continuityLoss),
            (.loss(.budgetExceeded), .budgetExceeded), (.loss(.restart), .restart),
            (.terminated, .continuityLoss),
        ]
        for (signal, reason) in cases {
            let fixture = try CoordinatorFixture()
            defer { fixture.remove() }
            let owner = try fixture.open()
            defer { try? owner.close() }
            let stream = CoordinatorFakeStream()
            let coordinator = make(owner, fixture, stream: stream)
            try ready(coordinator, stream, owner, fixture)
            XCTAssertEqual(stream.emit(batch("buffered")), .queued)
            let before = try state(owner, fixture)
            XCTAssertEqual(stream.emit(signal), .recoveryRequired(reason))
            XCTAssertEqual(try coordinator.snapshot().pendingGap, reason)
            XCTAssertNil(try coordinator.snapshot().persistedGapRevision)
            for _ in 0..<64 {
                XCTAssertEqual(stream.emit(batch("late")), .rejectedClosed)
                XCTAssertEqual(stream.emit(signal), .rejectedClosed)
            }
            XCTAssertEqual(try state(owner, fixture), before)
            let step = try coordinator.step(budget: scanBudget)
            XCTAssertEqual(step.appliedBatches, 0)
            XCTAssertNil(step.bootstrap)
            XCTAssertEqual(step.snapshot.phase, .recoveryRequired)
            XCTAssertEqual(step.snapshot.persistedGapRevision, before.requestedRevision + 1)
            let sealed = try state(owner, fixture)
            XCTAssertNil(sealed.eventCheckpoint)
            for _ in 0..<16 { _ = try coordinator.step(budget: scanBudget) }
            XCTAssertEqual(try state(owner, fixture), sealed)
            XCTAssertEqual(stream.startCount, 1)
            XCTAssertEqual(stream.stopCount, 1)
            try coordinator.stop()
            XCTAssertEqual(try state(owner, fixture), sealed)
        }
    }

    func testAlwaysOverbudgetRequiresExplicitNewGenerationAndNeverHotLoops() throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let owner = try fixture.open()
        defer { try? owner.close() }
        var streams: [CoordinatorFakeStream] = []
        let coordinator = make(owner, fixture, budget: eventBudget(paths: 0), factory: { _ in
            let stream = CoordinatorFakeStream()
            streams.append(stream)
            return stream
        })
        try coordinator.start(epoch: "epoch")
        let firstGeneration = try XCTUnwrap(coordinator.snapshot().generation)
        XCTAssertEqual(streams[0].emit(batch("oversized")), .recoveryRequired(.budgetExceeded))
        _ = try coordinator.step(budget: scanBudget)
        let firstSealed = try state(owner, fixture)
        for _ in 0..<32 { _ = try coordinator.step(budget: scanBudget) }
        XCTAssertEqual(streams.count, 1)
        XCTAssertEqual(try state(owner, fixture), firstSealed)
        try coordinator.start(epoch: "epoch")
        XCTAssertEqual(streams.count, 2)
        XCTAssertNotEqual(try coordinator.snapshot().generation, firstGeneration)
        XCTAssertEqual(try coordinator.snapshot().recoveryRevision, firstSealed.requestedRevision + 1)
        XCTAssertEqual(streams[0].emit(batch("stale")), .rejectedClosed)
        XCTAssertEqual(streams[1].emit(batch("oversized-again")), .recoveryRequired(.budgetExceeded))
        _ = try coordinator.step(budget: scanBudget)
        XCTAssertEqual(try coordinator.snapshot().phase, .recoveryRequired)
        XCTAssertNil(try state(owner, fixture).eventCheckpoint)
        try coordinator.stop()
    }

    func testRestartResumesOnlyDurableCheckpointAndEpochMismatchCannotRebase() throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let owner = try fixture.open()
        defer { try? owner.close() }
        var requests: [CollectorEventStreamRequest] = []
        var streams: [CoordinatorFakeStream] = []
        let coordinator = make(owner, fixture, factory: { request in
            requests.append(request)
            let stream = CoordinatorFakeStream()
            streams.append(stream)
            return stream
        })
        try coordinator.start(epoch: "é")
        XCTAssertEqual(streams[0].emit(.historyDone), .controlAccepted)
        try finishRecovery(coordinator, owner, fixture)
        XCTAssertEqual(streams[0].emit(batch("durable", epoch: "é")), .queued)
        _ = try coordinator.step(budget: scanBudget)
        XCTAssertEqual(streams[0].emit(batch("only-queued", epoch: "é")), .queued)
        try coordinator.stop()
        try coordinator.start(epoch: "é")
        XCTAssertEqual(requests.count, 2)
        assertCheckpoint(requests[1].resumeCheckpoint, .init(epoch: "é", cursor: "durable"))
        XCTAssertEqual(streams[0].emit(.historyDone), .rejectedClosed)
        XCTAssertEqual(streams[0].emit(batch("late", epoch: "é")), .rejectedClosed)
        XCTAssertFalse(try coordinator.snapshot().historyDone)
        try coordinator.stop()
        let beforeMismatch = try state(owner, fixture)
        try coordinator.start(epoch: "e\u{301}")
        XCTAssertEqual(try coordinator.snapshot().phase, .recoveryRequired)
        XCTAssertEqual(requests.count, 2, "mismatched epoch must not create a stream")
        XCTAssertEqual(try coordinator.snapshot().recoveryRevision, beforeMismatch.requestedRevision + 1)
        XCTAssertEqual(try coordinator.snapshot().persistedGapRevision, beforeMismatch.requestedRevision + 2)
        assertCheckpoint(try state(owner, fixture).eventCheckpoint, .init(epoch: "é", cursor: "durable"))
        try coordinator.stop()
    }

    func testOwnerCommitErrorClosesGenerationWithoutAckOrDirtyPrefix() throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        var failNextCommit = false
        let owner = try fixture.open(hooks: .init(beforeInventoryCommit: {
            if failNextCommit {
                failNextCommit = false
                throw CoordinatorFixture.Failure.injected
            }
        }))
        defer { try? owner.close() }
        let stream = CoordinatorFakeStream()
        let coordinator = make(owner, fixture, stream: stream)
        try ready(coordinator, stream, owner, fixture)
        XCTAssertEqual(stream.emit(batch("failed", paths: ["rollout-a.jsonl", "rollout-b.jsonl"])), .queued)
        failNextCommit = true
        XCTAssertThrowsError(try coordinator.step(budget: scanBudget)) {
            XCTAssertEqual($0 as? CoordinatorFixture.Failure, .injected)
        }
        XCTAssertNil(try state(owner, fixture).eventCheckpoint)
        XCTAssertNil(try coordinator.snapshot().lastAcknowledgedCheckpoint)
        XCTAssertEqual(try coordinator.snapshot().phase, .recoveryRequired)
        XCTAssertEqual(stream.emit(batch("late")), .rejectedClosed)
        _ = try coordinator.step(budget: scanBudget)
        try coordinator.stop()
        try owner.close()
        XCTAssertEqual(try fixture.integer("SELECT COUNT(*) FROM collector_locators"), 0)
    }

    func testCancellationBeforeAndInsideOwnerCommitDoesNotAckOrCommit() async throws {
        for cancelInsideCommit in [false, true] {
            let fixture = try CoordinatorFixture()
            defer { fixture.remove() }
            var cancelCurrentTask: (() -> Void)?
            let owner = try fixture.open(hooks: .init(beforeInventoryCommit: { cancelCurrentTask?() }))
            defer { try? owner.close() }
            let stream = CoordinatorFakeStream()
            let coordinator = make(owner, fixture, stream: stream)
            try ready(coordinator, stream, owner, fixture)
            XCTAssertEqual(stream.emit(batch("cancelled")), .queued)
            let before = try state(owner, fixture)
            let task = Task {
                try withUnsafeCurrentTask { currentTask in
                    XCTAssertNotNil(currentTask)
                    if cancelInsideCommit { cancelCurrentTask = { currentTask?.cancel() } }
                    else { currentTask?.cancel() }
                    defer { cancelCurrentTask = nil }
                    XCTAssertThrowsError(try coordinator.step(budget: self.scanBudget)) {
                        XCTAssertTrue($0 is CancellationError)
                    }
                    XCTAssertTrue(Task.isCancelled)
                    XCTAssertNil(try coordinator.snapshot().lastAcknowledgedCheckpoint)
                }
            }
            try await task.value
            XCTAssertNil(try state(owner, fixture).eventCheckpoint)
            XCTAssertEqual(try state(owner, fixture).requestedRevision, before.requestedRevision)
            try coordinator.stop()
            try owner.close()
            XCTAssertEqual(try fixture.integer("SELECT COUNT(*) FROM collector_locators"), 0)
        }
    }

    func testCancellationAfterOwnerCommitPreservesDurabilityButDoesNotInventAck() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let owner = try fixture.open()
        defer { try? owner.close() }
        var cancelCurrentTask: (() -> Void)?
        let stream = CoordinatorFakeStream()
        let coordinator = make(owner, fixture, stream: stream,
                               hooks: .init(afterApplyEvents: { cancelCurrentTask?() }))
        try ready(coordinator, stream, owner, fixture)
        XCTAssertEqual(stream.emit(batch("committed")), .queued)
        let task = Task {
            try withUnsafeCurrentTask { currentTask in
                XCTAssertNotNil(currentTask)
                cancelCurrentTask = { currentTask?.cancel() }
                defer { cancelCurrentTask = nil }
                XCTAssertThrowsError(try coordinator.step(budget: self.scanBudget)) {
                    XCTAssertTrue($0 is CancellationError)
                }
                XCTAssertTrue(Task.isCancelled)
                XCTAssertNil(try coordinator.snapshot().lastAcknowledgedCheckpoint)
            }
        }
        try await task.value
        assertCheckpoint(try state(owner, fixture).eventCheckpoint, .init(epoch: "epoch", cursor: "committed"))
        XCTAssertEqual(try coordinator.snapshot().phase, .recoveryRequired)
        XCTAssertEqual(stream.emit(batch("late")), .rejectedClosed)
        try coordinator.stop()
    }

    func testGapCommitFailureRetainsPendingGapAndRejectsFalseSuccessfulStop() throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        var rejectGap = false
        let owner = try fixture.open(hooks: .init(beforeInventoryCommit: {
            if rejectGap { throw CoordinatorFixture.Failure.injected }
        }))
        defer { try? owner.close() }
        let stream = CoordinatorFakeStream()
        let coordinator = make(owner, fixture, stream: stream)
        try ready(coordinator, stream, owner, fixture)
        XCTAssertEqual(stream.emit(batch("buffered")), .queued)
        let before = try state(owner, fixture)
        XCTAssertEqual(stream.emit(.loss(.overflow)), .recoveryRequired(.overflow))
        rejectGap = true
        XCTAssertThrowsError(try coordinator.step(budget: scanBudget)) {
            XCTAssertEqual($0 as? CoordinatorFixture.Failure, .injected)
        }
        XCTAssertThrowsError(try coordinator.stop()) {
            XCTAssertEqual($0 as? CoordinatorFixture.Failure, .injected)
        }
        XCTAssertEqual(try state(owner, fixture), before)
        XCTAssertEqual(try coordinator.snapshot().pendingGap, .overflow)
        XCTAssertNil(try coordinator.snapshot().persistedGapRevision)
        XCTAssertNotEqual(try coordinator.snapshot().phase, .stopped)
        XCTAssertEqual(stream.emit(batch("late")), .rejectedClosed)
        XCTAssertEqual(stream.stopCount, 1)
        rejectGap = false
        try coordinator.stop()
        XCTAssertEqual(try state(owner, fixture).requestedRevision, before.requestedRevision + 1)
        XCTAssertEqual(try coordinator.snapshot().phase, .stopped)
        XCTAssertNotNil(try owner.rootState(rootID: fixture.configuration.rootID))
    }

    func testInodeReplacementClosesGenerationWithoutRebindingOrAck() throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let owner = try fixture.open()
        defer { try? owner.close() }
        let stream = CoordinatorFakeStream()
        let coordinator = make(owner, fixture, stream: stream)
        try ready(coordinator, stream, owner, fixture)
        try fixture.replaceSourceRoot()
        XCTAssertEqual(stream.emit(batch("replaced")), .queued)
        XCTAssertThrowsError(try coordinator.step(budget: scanBudget)) {
            XCTAssertEqual($0 as? CollectorPOSIXEnumerationError, .rootIdentityChanged)
        }
        XCTAssertEqual(try coordinator.snapshot().phase, .recoveryRequired)
        XCTAssertNil(try state(owner, fixture).eventCheckpoint)
        XCTAssertEqual(stream.emit(batch("late")), .rejectedClosed)
        _ = try coordinator.step(budget: scanBudget)
        try coordinator.stop()
        XCTAssertThrowsError(try owner.enrollAndActivateRoot(fixture.configuration)) {
            XCTAssertEqual($0 as? CollectorPOSIXEnumerationError, .rootIdentityChanged)
        }
    }

    func testStreamStartFailureCleansOwnedResourcesWithoutClosingBorrowedOwner() throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let owner = try fixture.open()
        defer { try? owner.close() }
        let stream = CoordinatorFakeStream()
        stream.onStart = { throw CoordinatorFixture.Failure.injected }
        let coordinator = make(owner, fixture, stream: stream)
        XCTAssertThrowsError(try coordinator.start(epoch: "epoch")) {
            XCTAssertEqual($0 as? CoordinatorFixture.Failure, .injected)
        }
        XCTAssertEqual(stream.startCount, 1)
        XCTAssertEqual(stream.stopCount, 1)
        XCTAssertTrue(stream.resourcesReleased)
        XCTAssertEqual(try coordinator.snapshot().phase, .recoveryRequired)
        XCTAssertEqual(stream.emit(batch("late")), .rejectedClosed)
        XCTAssertNotNil(try owner.rootState(rootID: fixture.configuration.rootID))
        try coordinator.stop()
        XCTAssertEqual(stream.stopCount, 1)
    }

    func testStopRejectsReentrantCallbacksBeforeStreamStopAndNeverClosesOwner() throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let owner = try fixture.open()
        defer { try? owner.close() }
        let stream = CoordinatorFakeStream()
        let coordinator = make(owner, fixture, stream: stream)
        try ready(coordinator, stream, owner, fixture)
        XCTAssertEqual(stream.emit(batch("discarded")), .queued)
        let before = try state(owner, fixture)
        stream.onStop = {
            XCTAssertEqual(stream.emit(self.batch("reentrant")), .rejectedClosed)
            XCTAssertEqual(try coordinator.snapshot().phase, .stopping)
            XCTAssertNotNil(try owner.rootState(rootID: fixture.configuration.rootID))
        }
        try coordinator.stop()
        XCTAssertEqual(try coordinator.snapshot().phase, .stopped)
        XCTAssertEqual(try coordinator.snapshot().queuedBatchCount, 0)
        XCTAssertEqual(try state(owner, fixture).requestedRevision, before.requestedRevision + 1)
        XCTAssertNil(try state(owner, fixture).eventCheckpoint)
        XCTAssertEqual(stream.stopCount, 1)
        try coordinator.stop()
        XCTAssertEqual(stream.stopCount, 1)
        XCTAssertNotNil(try owner.rootState(rootID: fixture.configuration.rootID))
    }

    func testCancelledOrFailingStopCleansStreamButCannotClaimCompleteDrain() async throws {
        for cancelled in [false, true] {
            let fixture = try CoordinatorFixture()
            defer { fixture.remove() }
            let owner = try fixture.open()
            defer { try? owner.close() }
            let stream = CoordinatorFakeStream()
            let coordinator = make(owner, fixture, stream: stream)
            try ready(coordinator, stream, owner, fixture)
            XCTAssertEqual(stream.emit(batch("buffered")), .queued)
            let before = try state(owner, fixture)
            if cancelled {
                let task = Task {
                    withUnsafeCurrentTask { $0?.cancel() }
                    XCTAssertThrowsError(try coordinator.stop()) { XCTAssertTrue($0 is CancellationError) }
                }
                try await task.value
            } else {
                stream.onStop = { throw CoordinatorFixture.Failure.injected }
                XCTAssertThrowsError(try coordinator.stop()) {
                    XCTAssertEqual($0 as? CoordinatorFixture.Failure, .injected)
                }
                stream.onStop = nil
            }
            XCTAssertEqual(stream.stopCount, 1)
            XCTAssertTrue(stream.resourcesReleased)
            XCTAssertNotEqual(try coordinator.snapshot().phase, .stopped)
            XCTAssertEqual(stream.emit(batch("late")), .rejectedClosed)
            XCTAssertNotNil(try owner.rootState(rootID: fixture.configuration.rootID))
            try coordinator.stop()
            XCTAssertEqual(try coordinator.snapshot().phase, .stopped)
            XCTAssertEqual(stream.stopCount, 1)
            XCTAssertEqual(try state(owner, fixture).requestedRevision, before.requestedRevision + 1)
            XCTAssertNil(try state(owner, fixture).eventCheckpoint)
        }
    }

    func testLossDuringEnteredApplyAllowsOnlyEarlierAtomicBatchThenGap() throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let gate = CoordinatorBlockingGate()
        let owner = try fixture.open(hooks: .init(beforeInventoryCommit: { try gate.blockIfArmed() }))
        defer { try? owner.close() }
        let stream = CoordinatorFakeStream()
        let coordinator = make(owner, fixture, stream: stream)
        try ready(coordinator, stream, owner, fixture)
        let before = try state(owner, fixture)
        XCTAssertEqual(stream.emit(batch("entered")), .queued)
        XCTAssertEqual(stream.emit(batch("older-buffered", paths: ["rollout-buffered.jsonl"])), .queued)
        gate.arm()
        let operation = CoordinatorBackgroundOperation { _ = try coordinator.step(budget: self.scanBudget) }
        defer { gate.release() }
        try gate.awaitEntry()
        XCTAssertEqual(stream.emit(.loss(.overflow)), .recoveryRequired(.overflow))
        XCTAssertEqual(stream.emit(batch("after-loss")), .rejectedClosed)
        gate.release()
        try operation.finish()
        assertCheckpoint(try state(owner, fixture).eventCheckpoint, .init(epoch: "epoch", cursor: "entered"))
        assertCheckpoint(try coordinator.snapshot().lastAcknowledgedCheckpoint, .init(epoch: "epoch", cursor: "entered"))
        XCTAssertEqual(try coordinator.snapshot().pendingGap, .overflow)
        let next = try coordinator.step(budget: scanBudget)
        XCTAssertEqual(next.appliedBatches, 0)
        XCTAssertNil(next.bootstrap)
        XCTAssertEqual(try state(owner, fixture).requestedRevision, before.requestedRevision + 1)
        assertCheckpoint(try state(owner, fixture).eventCheckpoint, .init(epoch: "epoch", cursor: "entered"))
        try coordinator.stop()
        try owner.close()
        XCTAssertEqual(try fixture.integer("SELECT COUNT(*) FROM collector_locators"), 1)
    }

    func testStopDuringEnteredStepSealsBeforeDrainAndLateCompletionCannotReopen() throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let gate = CoordinatorBlockingGate()
        let owner = try fixture.open(hooks: .init(beforeInventoryCommit: { try gate.blockIfArmed() }))
        defer { try? owner.close() }
        let stream = CoordinatorFakeStream()
        let coordinator = make(owner, fixture, stream: stream)
        try ready(coordinator, stream, owner, fixture)
        XCTAssertEqual(stream.emit(batch("entered")), .queued)
        XCTAssertEqual(stream.emit(batch("discarded", paths: ["rollout-discarded.jsonl"])), .queued)
        gate.arm()
        let step = CoordinatorBackgroundOperation { _ = try coordinator.step(budget: self.scanBudget) }
        defer { gate.release() }
        try gate.awaitEntry()
        let streamStopped = DispatchSemaphore(value: 0)
        stream.onStop = {
            XCTAssertEqual(stream.emit(self.batch("reentrant")), .rejectedClosed)
            streamStopped.signal()
        }
        let stop = CoordinatorBackgroundOperation { try coordinator.stop() }
        XCTAssertEqual(streamStopped.wait(timeout: .now() + 5), .success)
        XCTAssertFalse(stop.isFinished, "successful stop must wait for entered Owner work")
        XCTAssertEqual(try coordinator.snapshot().phase, .stopping)
        XCTAssertEqual(stream.emit(batch("late")), .rejectedClosed)
        gate.release()
        try step.finish()
        try stop.finish()
        XCTAssertEqual(try coordinator.snapshot().phase, .stopped)
        XCTAssertEqual(stream.emit(batch("later")), .rejectedClosed)
        XCTAssertNotNil(try owner.rootState(rootID: fixture.configuration.rootID))
        let after = try state(owner, fixture)
        XCTAssertGreaterThan(after.requestedRevision, after.completedRevision)
        assertCheckpoint(after.eventCheckpoint, .init(epoch: "epoch", cursor: "entered"))
    }

    func testStopDuringStartSealsLateFactoryCompletionAndReleasesUnstartedStream() throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let owner = try fixture.open()
        defer { try? owner.close() }
        let factoryGate = CoordinatorBlockingGate()
        factoryGate.arm()
        let stream = CoordinatorFakeStream()
        let sealed = DispatchSemaphore(value: 0)
        let startProgress = DispatchSemaphore(value: 0)
        let coordinator = make(owner, fixture, hooks: .init(didSealForStop: { sealed.signal() }), factory: { _ in
            try factoryGate.blockIfArmed(onEntry: { startProgress.signal() })
            return stream
        })
        let start = CoordinatorBackgroundOperation(didComplete: { startProgress.signal() }) {
            try coordinator.start(epoch: "epoch")
        }
        defer { factoryGate.release() }
        guard startProgress.wait(timeout: .now() + 5) == .success else { throw CoordinatorFixture.Failure.timeout }
        if !factoryGate.hasEntered {
            // No synthetic gate timeout precedes the actual early startup error.
            try start.finish()
            XCTFail("start completed without entering the stream factory")
            return
        }
        let stop = CoordinatorBackgroundOperation { try coordinator.stop() }
        XCTAssertEqual(sealed.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(try coordinator.snapshot().phase, .stopping)
        XCTAssertFalse(stop.isFinished)
        factoryGate.release()
        // A stopped start may finish normally or return an explicit invalid-state error.
        do { try start.finish() }
        catch { XCTAssertEqual(error as? CollectorEventCoordinatorError, .invalidState) }
        try stop.finish()
        XCTAssertEqual(stream.startCount, 0)
        XCTAssertEqual(stream.stopCount, 1)
        XCTAssertTrue(stream.resourcesReleased)
        XCTAssertEqual(try coordinator.snapshot().phase, .stopped)
        XCTAssertNotNil(try owner.rootState(rootID: fixture.configuration.rootID))
    }

    private var scanBudget: CollectorBootstrapBudget {
        .init(maxEntriesVisited: 16, maxCandidateFiles: 8, maxDirectoryOpens: 2, maxMetadataBytes: 8192)
    }

    private var tinyScanBudget: CollectorBootstrapBudget {
        .init(maxEntriesVisited: 1, maxCandidateFiles: 1, maxDirectoryOpens: 1, maxMetadataBytes: 4096)
    }

    private func eventBudget(
        paths: Int = 64, perPath: Int = 4096, totalPaths: Int = 65536, checkpoints: Int = 4096,
        batches: Int = 64, queueBytes: Int = 131072
    ) -> CollectorEventCoordinatorBudget {
        .init(ingress: .init(maxIncomingPaths: paths, maxPathUTF8Bytes: perPath,
                            maxTotalPathUTF8Bytes: totalPaths, maxCheckpointUTF8Bytes: checkpoints),
              maxQueuedBatches: batches, maxQueuedUTF8Bytes: queueBytes)
    }

    private func batch(_ cursor: String, epoch: String = "epoch", paths: [String] = ["rollout-event.jsonl"]) -> CollectorEventStreamSignal {
        .batch(.init(nextCheckpoint: .init(epoch: epoch, cursor: cursor), dirtyRelativePaths: paths))
    }

    private func make(
        _ owner: CollectorInventoryOwner, _ fixture: CoordinatorFixture,
        stream: CoordinatorFakeStream? = nil, budget: CollectorEventCoordinatorBudget? = nil,
        hooks: CollectorEventCoordinatorTestHooks = .init(),
        factory: ((CollectorEventStreamRequest) throws -> any CollectorEventStream)? = nil
    ) -> CollectorEventCoordinator {
        let selectedFactory: (CollectorEventStreamRequest) throws -> any CollectorEventStream =
            factory ?? { _ in try XCTUnwrap(stream) }
        return CollectorEventCoordinator(
            enabled: true, configuration: fixture.configuration, budget: budget ?? eventBudget(),
            ownerFactory: { owner }, streamFactory: selectedFactory, testHooks: hooks
        )
    }

    private func state(_ owner: CollectorInventoryOwner, _ fixture: CoordinatorFixture) throws -> CollectorRootState {
        try XCTUnwrap(owner.rootState(rootID: fixture.configuration.rootID))
    }

    private func ready(
        _ coordinator: CollectorEventCoordinator, _ stream: CoordinatorFakeStream,
        _ owner: CollectorInventoryOwner, _ fixture: CoordinatorFixture, epoch: String = "epoch"
    ) throws {
        try coordinator.start(epoch: epoch)
        XCTAssertEqual(stream.emit(.historyDone), .controlAccepted)
        try finishRecovery(coordinator, owner, fixture)
    }

    private func finishRecovery(
        _ coordinator: CollectorEventCoordinator, _ owner: CollectorInventoryOwner, _ fixture: CoordinatorFixture
    ) throws {
        for _ in 0..<32 {
            if try coordinator.snapshot().phase == .watching {
                let snapshot = try coordinator.snapshot()
                let current = try state(owner, fixture)
                XCTAssertTrue(snapshot.historyDone)
                XCTAssertGreaterThanOrEqual(current.completedRevision, try XCTUnwrap(snapshot.recoveryRevision))
                XCTAssertGreaterThanOrEqual(current.completedRevision, current.requestedRevision)
                return
            }
            let step = try coordinator.step(budget: scanBudget)
            XCTAssertEqual(step.appliedBatches, 0)
        }
        XCTFail("recovery did not finish within its bounded fixture steps")
        throw CoordinatorFixture.Failure.timeout
    }

    private func assertCheckpoint(
        _ actual: CollectorEventCheckpoint?, _ expected: CollectorEventCheckpoint,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.map { Data($0.epoch.utf8) }, Data(expected.epoch.utf8), file: file, line: line)
        XCTAssertEqual(actual.map { Data($0.cursor.utf8) }, Data(expected.cursor.utf8), file: file, line: line)
    }
}

private final class CoordinatorFakeStream: CollectorEventStream {
    private let lock = NSLock()
    private var callback: ((CollectorEventStreamSignal) -> CollectorEventAdmission)?
    private var starts = 0
    private var stops = 0
    private var ownsResources = true
    var onStart: (() throws -> Void)?
    var onStop: (() throws -> Void)?
    var startCount: Int { lock.withLock { starts } }
    var stopCount: Int { lock.withLock { stops } }
    var resourcesReleased: Bool { lock.withLock { !ownsResources } }

    func start(deliver: @escaping (CollectorEventStreamSignal) -> CollectorEventAdmission) throws {
        lock.withLock { starts += 1; callback = deliver }
        try onStart?()
    }

    func stop() throws {
        lock.withLock { stops += 1 }
        defer { lock.withLock { ownsResources = false } }
        try onStop?()
    }

    func emit(_ signal: CollectorEventStreamSignal) -> CollectorEventAdmission {
        let deliver = lock.withLock { callback }
        return deliver?(signal) ?? .rejectedClosed
    }
}

private final class CoordinatorBlockingGate {
    private let lock = NSLock()
    private var armed = false
    private var didEnter = false
    private let entered = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)
    var hasEntered: Bool { lock.withLock { didEnter } }

    func arm() { lock.withLock { armed = true } }
    func blockIfArmed(onEntry: (() -> Void)? = nil) throws {
        let shouldBlock = lock.withLock { () -> Bool in
            guard armed else { return false }
            armed = false
            didEnter = true
            return true
        }
        guard shouldBlock else { return }
        entered.signal()
        onEntry?()
        guard released.wait(timeout: .now() + 5) == .success else { throw CoordinatorFixture.Failure.timeout }
    }
    func awaitEntry() throws {
        guard entered.wait(timeout: .now() + 5) == .success else { throw CoordinatorFixture.Failure.timeout }
    }
    func release() { released.signal() }
}

private final class CoordinatorBackgroundOperation {
    private let lock = NSLock()
    private let finished = DispatchSemaphore(value: 0)
    private var result: Result<Void, Error>?
    var isFinished: Bool { lock.withLock { result != nil } }

    init(didComplete: (() -> Void)? = nil, _ operation: @escaping () throws -> Void) {
        // Exactly one explicitly requested test operation, never one task per callback.
        let worker = Thread { [self] in
            let value = Result { try operation() }
            lock.withLock { result = value }
            finished.signal()
            didComplete?()
        }
        worker.qualityOfService = Thread.current.qualityOfService
        worker.start()
    }

    func finish() throws {
        guard finished.wait(timeout: .now() + 5) == .success else { throw CoordinatorFixture.Failure.timeout }
        try XCTUnwrap(lock.withLock { result }).get()
    }
}

private final class CoordinatorFixture {
    enum Failure: Error, Equatable { case injected, timeout }
    static let machineID = "11111111-2222-3333-4444-555555555555"
    let base: URL
    let liveRoot: URL
    let shadowRoot: URL
    let sourceParent: URL
    let sourceRoot: URL
    var liveCatalog: URL { liveRoot.appendingPathComponent("archive.sqlite") }
    var inventoryURL: URL { shadowRoot.appendingPathComponent("inventory/inventory.sqlite") }
    var configuration: CollectorRootConfiguration {
        .init(rootID: "synthetic-root", source: .codex, rootPath: sourceRoot.path, revision: 1)
    }

    init() throws {
        // Local copy of the frozen N2 fixture's private, pre-provisioned pattern.
        // No provider roots, user credentials, or non-fixture catalogs are accessed.
        let donor = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard donor.path.hasPrefix("/Users/") else { throw POSIXError(.EINVAL) }
        base = donor.appendingPathComponent(".engram-n3b1-coordinator-\(UUID().uuidString)", isDirectory: true)
        liveRoot = base.appendingPathComponent("live")
        shadowRoot = base.appendingPathComponent("task/shadow")
        sourceParent = base.appendingPathComponent("sources")
        sourceRoot = sourceParent.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            for path in [liveRoot, base.appendingPathComponent("task"), shadowRoot, sourceParent, sourceRoot] {
                try directory(path)
            }
            try catalog(liveCatalog)
            try catalog(shadowRoot.appendingPathComponent("archive.sqlite"))
        } catch {
            try? FileManager.default.removeItem(at: base)
            throw error
        }
    }

    func remove() { try? FileManager.default.removeItem(at: base) }

    func directory(_ path: URL) throws {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    func catalog(_ path: URL) throws {
        let queue = try DatabaseQueue(path: path.path)
        defer { try? queue.close() }
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE archive_metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            try db.execute(sql: "INSERT INTO archive_metadata VALUES ('machine_id', ?)", arguments: [Self.machineID])
        }
        try queue.close()
        guard chmod(path.path, 0o600) == 0 else { throw POSIXError(.EACCES) }
    }

    func open(hooks: CollectorInventoryOwnerTestHooks = .init()) throws -> CollectorInventoryOwner {
        try XCTUnwrap(CollectorInventoryOwner.open(enabled: true, shadowRoot: shadowRoot, identityCatalog: liveCatalog,
                                                   ownerRunID: "fixture-owner", testHooks: hooks))
    }

    func file(_ name: String) throws {
        let path = sourceRoot.appendingPathComponent(name)
        try Data("fixture".utf8).write(to: path)
        guard chmod(path.path, 0o600) == 0 else { throw POSIXError(.EACCES) }
    }

    func replaceSourceRoot() throws {
        try FileManager.default.moveItem(at: sourceRoot, to: sourceParent.appendingPathComponent("original-\(UUID().uuidString)"))
        try directory(sourceRoot)
    }

    func integer(_ sql: String) throws -> Int64? {
        // Caller closes Owner first; this read-only queue never escapes its scope.
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: inventoryURL.path, configuration: configuration)
        defer { try? queue.close() }
        return try queue.read { try Int64.fetchOne($0, sql: sql) }
    }
}
