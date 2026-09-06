import Foundation

enum CollectorEventCoordinatorError: Error, Equatable {
    case notImplemented
    case invalidState
}

struct CollectorEventCoordinatorBudget {
    let ingress: CollectorEventIngressBudget
    let maxQueuedBatches: Int
    // Owned paths plus next checkpoint epoch/cursor UTF-8 bytes, duplicates included.
    let maxQueuedUTF8Bytes: Int
}

struct CollectorEventBatch {
    let nextCheckpoint: CollectorEventCheckpoint
    let dirtyRelativePaths: [String]
}

enum CollectorEventStreamSignal {
    case batch(CollectorEventBatch)
    case historyDone
    case loss(CollectorEventGapReason)
    case terminated
}

enum CollectorEventAdmission: Equatable {
    case queued
    case controlAccepted
    case rejectedClosed
    case recoveryRequired(CollectorEventGapReason)
}

struct CollectorEventStreamRequest {
    let binding: CollectorPOSIXRootBinding
    let generation: UInt64
    let epoch: String
    let resumeCheckpoint: CollectorEventCheckpoint?
}

// Callback invocation is synchronous and must not retain borrowed native bytes.
// The coordinator callback only admits bounded owned values or seals a loss latch:
// no Owner calls, asynchronous dispatch, or Task creation occur in that callback.
protocol CollectorEventStream: AnyObject {
    func start(deliver: @escaping (CollectorEventStreamSignal) -> CollectorEventAdmission) throws
    // Idempotent resource cleanup, including a constructed but never started stream.
    // A thrown drain error must not skip releasing the stream's owned resources.
    func stop() throws
}

enum CollectorEventCoordinatorPhase: Equatable {
    case stopped
    case starting
    case recovering
    case watching
    case recoveryRequired
    case stopping
}

struct CollectorEventCoordinatorSnapshot {
    let phase: CollectorEventCoordinatorPhase
    let generation: UInt64?
    // The exact revision returned by the successful explicit .restart request.
    let recoveryRevision: Int64?
    let historyDone: Bool
    let queuedBatchCount: Int
    let queuedUTF8Bytes: Int
    let pendingGap: CollectorEventGapReason?
    let persistedGapRevision: Int64?
    // Acknowledged apply result, never a queued cursor or a substitute for rootState.
    let lastAcknowledgedCheckpoint: CollectorEventCheckpoint?
}

struct CollectorEventCoordinatorStep {
    let snapshot: CollectorEventCoordinatorSnapshot
    let bootstrap: CollectorBootstrapStepResult?
    let appliedBatches: Int
}

struct CollectorEventCoordinatorTestHooks {
    // Distinguishes committed durability from cancellation before in-memory ACK.
    var afterApplyEvents: (() -> Void)?
    // Runs after the mailbox is sealed and unlocked, before resource stop/drain.
    var didSealForStop: (() -> Void)?
}

// start/step execute synchronously in their caller's task and serialize Owner
// work; callbacks use a separate bounded mailbox lock. stop
// seals admission before waiting for entered work and never closes the borrowed
// Owner. No mailbox lock may be held while calling a stream or the Owner.
final class CollectorEventCoordinator {
    private struct QueuedBatch {
        let batch: CollectorEventBatch
        let bytes: Int
    }

    private let enabled: Bool
    private let configuration: CollectorRootConfiguration
    private let budget: CollectorEventCoordinatorBudget
    private let ownerFactory: () throws -> CollectorInventoryOwner
    private let streamFactory: (CollectorEventStreamRequest) throws -> any CollectorEventStream
    private let testHooks: CollectorEventCoordinatorTestHooks
    private let control = NSLock()
    private let stopControl = NSLock()
    private let mailbox = NSLock()
    // Borrowed for the coordinator's lifetime; never closed by this object.
    private var owner: CollectorInventoryOwner?
    private var rootEnrolled = false
    // All fields below are protected by mailbox, including lifecycle publication.
    private var phase: CollectorEventCoordinatorPhase = .stopped
    private var generation: UInt64?
    private var generationCounter: UInt64 = 0
    private var epoch = ""
    private var accepting = false
    private var stopRequested = false
    private var recoveryRevision: Int64?
    private var historyDone = false
    private var queue: [QueuedBatch] = []
    private var queuedBytes = 0
    private var pendingGap: CollectorEventGapReason?
    private var persistedGapRevision: Int64?
    private var lastAcknowledgedCheckpoint: CollectorEventCheckpoint?
    private var stream: CollectorCoordinatorStreamLifetime?

    init(
        enabled: Bool = false,
        configuration: CollectorRootConfiguration,
        budget: CollectorEventCoordinatorBudget,
        ownerFactory: @escaping () throws -> CollectorInventoryOwner,
        streamFactory: @escaping (CollectorEventStreamRequest) throws -> any CollectorEventStream,
        testHooks: CollectorEventCoordinatorTestHooks = .init()
    ) {
        self.enabled = enabled
        self.configuration = configuration
        self.budget = budget
        self.ownerFactory = ownerFactory
        self.streamFactory = streamFactory
        self.testHooks = testHooks
    }

    func start(epoch: String) throws {
        guard enabled else { return }
        try Task.checkCancellation()
        try validateBudget()
        control.lock()
        defer { control.unlock() }
        let previous = try mailbox.withLock { () -> (UInt64?, CollectorCoordinatorStreamLifetime?) in
            guard phase == .stopped || phase == .recoveryRequired else {
                throw CollectorEventCoordinatorError.invalidState
            }
            // Publish entry before external cleanup/Owner calls so a concurrent
            // stop cannot observe an apparently idle coordinator and miss start.
            phase = .starting
            stopRequested = false
            return (generation, stream)
        }
        do {
            previous.1?.stopOnce()
            if let error = previous.1?.takeFailure() { throw error }
            if let oldGeneration = previous.0 { try persistGap(for: oldGeneration) }
            try Task.checkCancellation()
        } catch {
            mailbox.withLock { if !stopRequested { phase = .recoveryRequired } }
            throw error
        }
        let token: UInt64 = try mailbox.withLock {
            guard !stopRequested, phase == .starting, generationCounter < UInt64.max else {
                throw CollectorEventCoordinatorError.invalidState
            }
            generationCounter += 1
            generation = generationCounter
            self.epoch = epoch
            phase = .starting
            accepting = false
            stopRequested = false
            recoveryRevision = nil
            historyDone = false
            pendingGap = nil
            persistedGapRevision = nil
            lastAcknowledgedCheckpoint = nil
            stream = nil
            return generationCounter
        }
        do {
            if owner == nil {
                try Task.checkCancellation()
                owner = try ownerFactory()
                try Task.checkCancellation()
            }
            guard let owner else { throw CollectorEventCoordinatorError.invalidState }
            try requireUnsealed(token)
            let binding = try owner.enrollAndActivateRoot(configuration)
            rootEnrolled = true
            try Task.checkCancellation()
            try requireUnsealed(token)
            let result = try owner.requestEventReconciliation(configuration: configuration, reason: .restart)
            guard case .reconciliationRequested(.restart, let revision) = result else {
                throw CollectorEventCoordinatorError.invalidState
            }
            mailbox.withLock { recoveryRevision = revision }
            try Task.checkCancellation()
            try requireUnsealed(token)
            let current = try readRoot(owner)
            guard !epoch.isEmpty, !epoch.contains("\0"),
                  current.eventCheckpoint.map({ $0.epoch.utf8.elementsEqual(epoch.utf8) }) ?? true else {
                recordLoss(.continuityLoss, for: token)
                try persistGap(for: token)
                return
            }
            let created = CollectorCoordinatorStreamLifetime(try streamFactory(.init(
                binding: binding, generation: token, epoch: epoch, resumeCheckpoint: current.eventCheckpoint
            )))
            mailbox.withLock { stream = created }
            try Task.checkCancellation()
            try requireUnsealed(token)
            mailbox.withLock { accepting = !stopRequested && generation == token && pendingGap == nil }
            let started = try created.start { [weak self] signal in
                self?.admit(signal, for: token) ?? .rejectedClosed
            }
            try Task.checkCancellation()
            guard started else { throw CollectorEventCoordinatorError.invalidState }
            let stopped = mailbox.withLock { () -> Bool in
                guard generation == token, !stopRequested else { return true }
                if pendingGap == nil { phase = .recovering }
                return false
            }
            if stopped { throw CollectorEventCoordinatorError.invalidState }
            if mailbox.withLock({ pendingGap != nil }) { created.stopOnce() }
        } catch {
            if rootEnrolled { recordLoss(.continuityLoss, for: token) }
            else { mailbox.withLock { if !stopRequested { phase = .recoveryRequired } } }
            mailbox.withLock { stream }?.stopOnce()
            throw error
        }
    }

    // At most one bootstrap step or one ordinary batch per call. Pending loss
    // takes priority. Recovery never applies batches or chases a newer gap fence.
    // A completed scan waits without rescanning until explicit historyDone.
    func step(budget: CollectorBootstrapBudget) throws -> CollectorEventCoordinatorStep {
        guard enabled else { return stepResult() }
        control.lock()
        defer { control.unlock() }
        guard let token = mailbox.withLock({ generation }) else { return stepResult() }
        do {
            try Task.checkCancellation()
            let state = mailbox.withLock { (phase, pendingGap != nil) }
            if state.0 == .stopped || state.0 == .stopping { return stepResult() }
            if state.1 {
                mailbox.withLock { stream }?.stopOnce()
                try persistGap(for: token)
                return stepResult()
            }
            guard state.0 == .recovering || state.0 == .watching,
                  let owner, let fence = mailbox.withLock({ recoveryRevision }) else { return stepResult() }
            let current = try readRoot(owner)
            if try rejectChangedFence(current, fence: fence, token: token) { return stepResult() }
            if state.0 == .recovering {
                if current.completedRevision >= current.requestedRevision && current.completedRevision >= fence {
                    releaseRecovery(for: token)
                    return stepResult()
                }
                guard mailbox.withLock({ !stopRequested && pendingGap == nil }) else { return stepResult() }
                try Task.checkCancellation()
                let bootstrap = try owner.stepRoot(configuration, budget: budget)
                try Task.checkCancellation()
                let after = try readRoot(owner)
                if try rejectChangedFence(after, fence: fence, token: token) { return stepResult(bootstrap: bootstrap) }
                if case .blocked = bootstrap.outcome {
                    recordLoss(.continuityLoss, for: token)
                    mailbox.withLock { stream }?.stopOnce()
                    try persistGap(for: token)
                } else if after.completedRevision >= after.requestedRevision && after.completedRevision >= fence {
                    releaseRecovery(for: token)
                }
                return stepResult(bootstrap: bootstrap)
            }
            let entered = mailbox.withLock { () -> QueuedBatch? in
                guard generation == token, !stopRequested, accepting, pendingGap == nil else { return nil }
                // Reservation is the entered-batch boundary. It retains its queue
                // budget until completion, including while Owner work is in flight.
                return queue.first
            }
            guard let entered else { return stepResult() }
            try Task.checkCancellation()
            let result = try owner.applyEvents(
                configuration: configuration, expectedCheckpoint: current.eventCheckpoint,
                nextCheckpoint: entered.batch.nextCheckpoint, dirtyRelativePaths: entered.batch.dirtyRelativePaths,
                budget: self.budget.ingress
            )
            testHooks.afterApplyEvents?()
            switch result {
            case .applied(_, let checkpoint):
                try Task.checkCancellation()
                mailbox.withLock {
                    queue.removeFirst()
                    queuedBytes -= entered.bytes
                    lastAcknowledgedCheckpoint = checkpoint
                }
                return stepResult(applied: 1)
            case .reconciliationRequested(_, let revision):
                // This transaction already supplied the durable gap. Do not add
                // a second request or acknowledge the rejected ordinary batch.
                mailbox.withLock {
                    accepting = false
                    if !stopRequested { phase = .recoveryRequired }
                    pendingGap = nil
                    persistedGapRevision = revision
                    queue.removeAll(keepingCapacity: false)
                    queuedBytes = 0
                }
                mailbox.withLock { stream }?.stopOnce()
                try Task.checkCancellation()
                return stepResult()
            }
        } catch {
            recordLoss(.continuityLoss, for: token)
            mailbox.withLock { stream }?.stopOnce()
            throw error
        }
    }

    func snapshot() throws -> CollectorEventCoordinatorSnapshot {
        currentSnapshot()
    }

    func stop() throws {
        guard enabled else { return }
        let request = mailbox.withLock { () -> (Bool, UInt64?) in
            guard phase != .stopped else { return (false, generation) }
            accepting = false
            stopRequested = true
            phase = .stopping
            return (true, generation)
        }
        guard request.0 else { return }
        testHooks.didSealForStop?()
        stopControl.lock()
        defer { stopControl.unlock() }
        let stillCurrent = mailbox.withLock { () -> Bool in
            guard generation == request.1, phase != .stopped else { return false }
            accepting = false
            stopRequested = true
            phase = .stopping
            return true
        }
        guard stillCurrent else { return }
        // Stop an existing stream before waiting for entered synchronous Owner
        // work. A late factory result is stopped by start before releasing control.
        mailbox.withLock { stream }?.stopOnce()
        control.lock()
        defer { control.unlock() }
        let active = mailbox.withLock { (generation, stream) }
        active.1?.stopOnce()
        do {
            if let token = active.0 {
                if mailbox.withLock({ !queue.isEmpty && pendingGap == nil && persistedGapRevision == nil }) {
                    recordLoss(.restart, for: token)
                }
                try Task.checkCancellation()
                try persistGap(for: token)
            }
            try Task.checkCancellation()
            if let error = active.1?.takeFailure() { throw error }
            mailbox.withLock { phase = .stopped }
        } catch {
            mailbox.withLock { phase = .recoveryRequired }
            throw error
        }
    }

    private func validateBudget() throws {
        let raw = budget.ingress
        guard raw.maxIncomingPaths >= 0, raw.maxPathUTF8Bytes >= 0, raw.maxTotalPathUTF8Bytes >= 0,
              raw.maxCheckpointUTF8Bytes >= 0, budget.maxQueuedBatches >= 0, budget.maxQueuedUTF8Bytes >= 0 else {
            throw CollectorInventoryError.invalidBudget
        }
    }

    private func requireUnsealed(_ token: UInt64) throws {
        try Task.checkCancellation()
        guard mailbox.withLock({ generation == token && !stopRequested && pendingGap == nil }) else {
            throw CollectorEventCoordinatorError.invalidState
        }
    }

    private func readRoot(_ owner: CollectorInventoryOwner) throws -> CollectorRootState {
        try Task.checkCancellation()
        guard let current = try owner.rootState(rootID: configuration.rootID), current.configuration == configuration else {
            throw CollectorInventoryError.unknownRoot
        }
        try Task.checkCancellation()
        return current
    }

    private func rejectChangedFence(_ current: CollectorRootState, fence: Int64, token: UInt64) throws -> Bool {
        let sameEpoch = mailbox.withLock {
            current.eventCheckpoint.map({ $0.epoch.utf8.elementsEqual(epoch.utf8) }) ?? true
        }
        guard current.requestedRevision == fence, sameEpoch else {
            recordLoss(.continuityLoss, for: token)
            mailbox.withLock { stream }?.stopOnce()
            try persistGap(for: token)
            return true
        }
        return false
    }

    private func releaseRecovery(for token: UInt64) {
        mailbox.withLock {
            guard generation == token, !stopRequested, pendingGap == nil, historyDone else { return }
            phase = .watching
        }
    }

    private func recordLoss(_ reason: CollectorEventGapReason, for token: UInt64) {
        mailbox.withLock { recordLossLocked(reason, for: token) }
    }

    private func recordLossLocked(_ reason: CollectorEventGapReason, for token: UInt64) {
        guard generation == token else { return }
        accepting = false
        if !stopRequested { phase = .recoveryRequired }
        if pendingGap == nil && persistedGapRevision == nil { pendingGap = reason }
    }

    private func persistGap(for token: UInt64) throws {
        guard let reason = mailbox.withLock({ generation == token ? pendingGap : nil }) else { return }
        guard let owner, rootEnrolled else { throw CollectorEventCoordinatorError.invalidState }
        try Task.checkCancellation()
        let result = try owner.requestEventReconciliation(configuration: configuration, reason: reason)
        guard case .reconciliationRequested(_, let revision) = result else {
            throw CollectorEventCoordinatorError.invalidState
        }
        // Record committed durability before a post-call cancellation can throw.
        mailbox.withLock {
            pendingGap = nil
            persistedGapRevision = revision
            queue.removeAll(keepingCapacity: false)
            queuedBytes = 0
        }
        try Task.checkCancellation()
    }

    private func admit(_ signal: CollectorEventStreamSignal, for token: UInt64) -> CollectorEventAdmission {
        mailbox.withLock {
            guard generation == token, accepting, !stopRequested, pendingGap == nil else { return .rejectedClosed }
            switch signal {
            case .historyDone:
                historyDone = true
                return .controlAccepted
            case .loss(let reason):
                recordLossLocked(reason, for: token)
                return .recoveryRequired(reason)
            case .terminated:
                recordLossLocked(.continuityLoss, for: token)
                return .recoveryRequired(.continuityLoss)
            case .batch(let batch):
                guard let bytes = incomingBytes(batch), queue.count < budget.maxQueuedBatches,
                      bytes <= budget.maxQueuedUTF8Bytes - queuedBytes else {
                    recordLossLocked(.budgetExceeded, for: token)
                    return .recoveryRequired(.budgetExceeded)
                }
                guard batch.nextCheckpoint.epoch.utf8.elementsEqual(epoch.utf8) else {
                    recordLossLocked(.continuityLoss, for: token)
                    return .recoveryRequired(.continuityLoss)
                }
                queue.append(.init(batch: batch, bytes: bytes))
                queuedBytes += bytes
                return .queued
            }
        }
    }

    private func incomingBytes(_ batch: CollectorEventBatch) -> Int? {
        let raw = budget.ingress
        guard batch.dirtyRelativePaths.count <= raw.maxIncomingPaths else { return nil }
        var remainingPaths = raw.maxTotalPathUTF8Bytes
        for path in batch.dirtyRelativePaths {
            guard let count = Self.utf8Count(path, limit: min(raw.maxPathUTF8Bytes, remainingPaths)) else { return nil }
            remainingPaths -= count
        }
        var remainingCheckpoint = raw.maxCheckpointUTF8Bytes
        for value in [batch.nextCheckpoint.epoch, batch.nextCheckpoint.cursor] {
            guard let count = Self.utf8Count(value, limit: remainingCheckpoint) else { return nil }
            remainingCheckpoint -= count
        }
        let paths = raw.maxTotalPathUTF8Bytes - remainingPaths
        let checkpoint = raw.maxCheckpointUTF8Bytes - remainingCheckpoint
        guard paths <= budget.maxQueuedUTF8Bytes, checkpoint <= budget.maxQueuedUTF8Bytes - paths else { return nil }
        return paths + checkpoint
    }

    private static func utf8Count(_ value: String, limit: Int) -> Int? {
        var count = 0
        for _ in value.utf8 {
            guard count < limit else { return nil }
            count += 1
        }
        return count
    }

    private func currentSnapshot() -> CollectorEventCoordinatorSnapshot {
        mailbox.withLock {
            .init(phase: phase, generation: generation, recoveryRevision: recoveryRevision,
                  historyDone: historyDone, queuedBatchCount: queue.count, queuedUTF8Bytes: queuedBytes,
                  pendingGap: pendingGap, persistedGapRevision: persistedGapRevision,
                  lastAcknowledgedCheckpoint: lastAcknowledgedCheckpoint)
        }
    }

    private func stepResult(bootstrap: CollectorBootstrapStepResult? = nil, applied: Int = 0) -> CollectorEventCoordinatorStep {
        .init(snapshot: currentSnapshot(), bootstrap: bootstrap, appliedBatches: applied)
    }
}

// Only lifecycle coordination lives here; native handles remain the stream's
// responsibility. No condition lock is held while invoking a stream callback.
private final class CollectorCoordinatorStreamLifetime {
    private let stream: any CollectorEventStream
    private let condition = NSCondition()
    private var starting = false
    private var stopping = false
    private var stopped = false
    private var stopRequested = false
    private var failure: Error?

    init(_ stream: any CollectorEventStream) { self.stream = stream }

    func start(deliver: @escaping (CollectorEventStreamSignal) -> CollectorEventAdmission) throws -> Bool {
        condition.lock()
        guard !stopRequested else { condition.unlock(); return false }
        starting = true
        condition.unlock()
        defer {
            condition.lock()
            starting = false
            condition.broadcast()
            condition.unlock()
        }
        try stream.start(deliver: deliver)
        return true
    }

    func stopOnce() {
        condition.lock()
        stopRequested = true
        while starting || stopping { condition.wait() }
        guard !stopped else { condition.unlock(); return }
        stopping = true
        condition.unlock()
        var result: Error?
        do { try stream.stop() } catch { result = error }
        condition.lock()
        failure = result
        stopped = true
        stopping = false
        condition.broadcast()
        condition.unlock()
    }

    func takeFailure() -> Error? {
        condition.lock()
        defer { condition.unlock() }
        let result = failure
        failure = nil
        return result
    }
}
