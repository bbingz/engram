import Foundation

/// Outcome of one scheduled opportunity (Wave 7C S01).
public enum IndexingActivityOpportunity: Sendable, Equatable {
    /// OS (or fake) granted a run slot and `work` completed under the activity.
    case run
    /// `shouldDefer` / discretionary deferral — `work` was not invoked.
    case deferred
    /// Task cancelled or scheduler invalidated. If work was in flight, it was
    /// cancelled **and awaited** before this outcome is returned.
    case cancelled
}

/// Injectable background activity surface for adaptive periodic indexing.
/// Production uses `NSBackgroundActivityScheduler` (background QoS, tolerance,
/// `shouldDefer`) and only reports `.finished` **after** `work` returns.
public protocol IndexingBackgroundActivityScheduling: AnyObject, Sendable {
    /// Backend name published to telemetry (must match real implementation).
    var backendName: String { get }

    /// Wait until the next scheduled opportunity, then run `work` inside the
    /// activity's lifetime. OS completion is only signaled after `work` ends.
    ///
    /// Cancellation contract: if the calling task is cancelled while `work` is
    /// running, implementations must cancel that work and **wait for it to
    /// return** before `performWhenDue` itself returns `.cancelled`.
    func performWhenDue(
        interval: TimeInterval,
        tolerance: TimeInterval,
        work: @escaping @Sendable () async -> Void
    ) async -> IndexingActivityOpportunity

    /// Tear down schedule/work. If work is in flight, cancels it and **awaits
    /// exit** before returning (same contract as cancel of `performWhenDue`).
    func invalidate() async
}

// MARK: - Production NSBackgroundActivityScheduler

/// Production scheduler: `NSBackgroundActivityScheduler` at background QoS.
/// Activity completion and the `performWhenDue` return both wait for work exit,
/// including on cancellation / invalidate (no orphaned scan Task).
public final class NSIndexingBackgroundActivityScheduler: IndexingBackgroundActivityScheduling, @unchecked Sendable {
    public static let identifier = "com.engram.service.periodic-index"
    public let backendName = "NSBackgroundActivityScheduler"

    private enum Phase {
        case idle
        case awaitingSchedule
        case runningWork
    }

    private let lock = NSLock()
    private var scheduler: NSBackgroundActivityScheduler?
    private var scheduleWait: CheckedContinuation<ScheduleFire, Never>?
    private var activeWork: Task<Void, Never>?
    private var activityCompletion: ((NSBackgroundActivityScheduler.Result) -> Void)?
    /// Ensures OS activity completion is invoked at most once per work cycle.
    private var activityFinished = false
    private var phase: Phase = .idle
    private var cancelledWhileWaiting = false

    private enum ScheduleFire: Sendable {
        case run(complete: @Sendable (NSBackgroundActivityScheduler.Result) -> Void)
        case deferred
        case cancelled
    }

    public init() {}

    public func performWhenDue(
        interval: TimeInterval,
        tolerance: TimeInterval,
        work: @escaping @Sendable () async -> Void
    ) async -> IndexingActivityOpportunity {
        let fire = await waitForScheduleFire(
            interval: max(1, interval),
            tolerance: max(0, tolerance)
        )
        switch fire {
        case .cancelled:
            return .cancelled
        case .deferred:
            return .deferred
        case .run(let completeActivity):
            return await runTrackedWork(work: work, completeActivity: completeActivity)
        }
    }

    public func invalidate() async {
        await cancelAndAwaitWork(completeOSActivity: true)
    }

    // MARK: Shared cancel / invalidate

    /// Cancel schedule wait + active work, await work exit, finish OS activity.
    private func cancelAndAwaitWork(completeOSActivity: Bool) async {
        let (wait, work, completion) = lock.withLock {
            cancelledWhileWaiting = true
            scheduler?.invalidate()
            scheduler = nil
            let wait = scheduleWait
            scheduleWait = nil
            let work = activeWork
            let completion = activityCompletion
            if phase == .awaitingSchedule {
                phase = .idle
            }
            return (wait, work, completion)
        }

        wait?.resume(returning: .cancelled)
        work?.cancel()

        if let work {
            await work.value
        }

        lock.withLock {
            activeWork = nil
            if phase == .runningWork {
                phase = .idle
            }
        }

        if completeOSActivity {
            finishActivityOnce(completion)
        }
    }

    private func finishActivityOnce(
        _ completion: ((NSBackgroundActivityScheduler.Result) -> Void)?
    ) {
        lock.lock()
        guard !activityFinished else {
            lock.unlock()
            return
        }
        activityFinished = true
        activityCompletion = nil
        lock.unlock()
        completion?(.finished)
    }

    // MARK: Schedule wait

    private func waitForScheduleFire(
        interval: TimeInterval,
        tolerance: TimeInterval
    ) async -> ScheduleFire {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ScheduleFire, Never>) in
                self.lock.lock()
                if Task.isCancelled || self.cancelledWhileWaiting {
                    self.lock.unlock()
                    continuation.resume(returning: .cancelled)
                    return
                }
                if let previous = self.scheduleWait {
                    self.scheduleWait = continuation
                    self.phase = .awaitingSchedule
                    self.lock.unlock()
                    previous.resume(returning: .cancelled)
                } else {
                    self.scheduleWait = continuation
                    self.phase = .awaitingSchedule
                    self.lock.unlock()
                }
                self.armScheduler(interval: interval, tolerance: tolerance)
            }
        } onCancel: {
            self.cancelScheduleWaitOnly()
        }
    }

    private func cancelScheduleWaitOnly() {
        lock.lock()
        cancelledWhileWaiting = true
        scheduler?.invalidate()
        scheduler = nil
        let wait = scheduleWait
        scheduleWait = nil
        if phase == .awaitingSchedule {
            phase = .idle
        }
        lock.unlock()
        wait?.resume(returning: .cancelled)
    }

    private func armScheduler(interval: TimeInterval, tolerance: TimeInterval) {
        lock.lock()
        scheduler?.invalidate()
        let next = NSBackgroundActivityScheduler(identifier: Self.identifier)
        next.repeats = false
        next.interval = interval
        next.tolerance = min(tolerance, interval * 0.25)
        next.qualityOfService = .background
        scheduler = next
        lock.unlock()

        next.schedule { [weak self] completion in
            guard let self else {
                completion(NSBackgroundActivityScheduler.Result.finished)
                return
            }
            self.lock.lock()
            let wait = self.scheduleWait
            self.scheduleWait = nil
            if self.cancelledWhileWaiting || wait == nil {
                self.phase = .idle
                self.lock.unlock()
                completion(NSBackgroundActivityScheduler.Result.finished)
                return
            }
            if next.shouldDefer {
                self.phase = .idle
                self.lock.unlock()
                completion(NSBackgroundActivityScheduler.Result.deferred)
                wait?.resume(returning: .deferred)
                return
            }
            self.lock.unlock()
            wait?.resume(returning: .run(complete: { result in
                completion(result)
            }))
        }
    }

    // MARK: Tracked work

    private func runTrackedWork(
        work: @escaping @Sendable () async -> Void,
        completeActivity: @escaping @Sendable (NSBackgroundActivityScheduler.Result) -> Void
    ) async -> IndexingActivityOpportunity {
        let workTask = Task {
            await work()
        }

        let alreadyCancelled = lock.withLock {
            activeWork = workTask
            activityCompletion = completeActivity
            activityFinished = false
            phase = .runningWork
            return cancelledWhileWaiting || Task.isCancelled
        }

        if alreadyCancelled {
            workTask.cancel()
        }

        await withTaskCancellationHandler {
            await workTask.value
        } onCancel: {
            workTask.cancel()
        }

        let (wasCancelled, completion) = lock.withLock {
            activeWork = nil
            let wasCancelled = cancelledWhileWaiting || Task.isCancelled
            if !wasCancelled {
                cancelledWhileWaiting = false
            }
            phase = .idle
            return (wasCancelled, activityCompletion)
        }

        finishActivityOnce(completion ?? completeActivity)
        return wasCancelled ? .cancelled : .run
    }

    deinit {
        // deinit cannot await; cancel without waiting (process is going away).
        lock.lock()
        scheduler?.invalidate()
        scheduler = nil
        cancelledWhileWaiting = true
        let wait = scheduleWait
        scheduleWait = nil
        let work = activeWork
        activeWork = nil
        let completion = activityCompletion
        let alreadyFinished = activityFinished
        activityFinished = true
        activityCompletion = nil
        phase = .idle
        lock.unlock()
        wait?.resume(returning: .cancelled)
        work?.cancel()
        if !alreadyFinished {
            completion?(.finished)
        }
    }
}

// MARK: - Sleep fallback

public final class SleepIndexingBackgroundActivityScheduler: IndexingBackgroundActivityScheduling, @unchecked Sendable {
    public let backendName = "Task.sleep"

    private let lock = NSLock()
    private var activeWork: Task<Void, Never>?
    /// Set by invalidate() so performWhenDue returns `.cancelled` even when the
    /// caller task itself was not cancelled (parity with production).
    private var cancelRequested = false

    public init() {}

    public func performWhenDue(
        interval: TimeInterval,
        tolerance: TimeInterval,
        work: @escaping @Sendable () async -> Void
    ) async -> IndexingActivityOpportunity {
        _ = tolerance
        if Task.isCancelled { return .cancelled }
        let nanos = UInt64(max(0, interval) * 1_000_000_000)
        do {
            try await Task.sleep(nanoseconds: nanos)
        } catch {
            return .cancelled
        }
        let preCancel = lock.withLock {
            cancelRequested || Task.isCancelled
        }
        if preCancel { return .cancelled }

        let workTask = Task { await work() }
        lock.withLock {
            activeWork = workTask
        }

        await withTaskCancellationHandler {
            await workTask.value
        } onCancel: {
            workTask.cancel()
        }

        let cancelled = lock.withLock {
            activeWork = nil
            let cancelled = Task.isCancelled || cancelRequested
            cancelRequested = false
            return cancelled
        }
        return cancelled ? .cancelled : .run
    }

    public func invalidate() async {
        let work = lock.withLock {
            cancelRequested = true
            let work = activeWork
            activeWork = nil
            return work
        }
        work?.cancel()
        if let work {
            await work.value
        }
    }
}

// MARK: - Recording test double

public final class RecordingIndexingBackgroundActivityScheduler: IndexingBackgroundActivityScheduling, @unchecked Sendable {
    public let backendName = "Recording"

    public private(set) var workInvocations = 0
    public private(set) var finishedAfterWorkCount = 0
    public private(set) var lastRunFinishedAfterWork = false
    public private(set) var lastCancelWaitedForWork = false
    /// True when `invalidate()` awaited in-flight work exit.
    public private(set) var lastInvalidateWaitedForWork = false
    public var forceDeferred = false
    public var immediate = true
    public var workDelayNanoseconds: UInt64 = 0

    private let lock = NSLock()
    private var activeWork: Task<Void, Never>?
    private var cancelRequested = false

    public init() {}

    public func performWhenDue(
        interval: TimeInterval,
        tolerance: TimeInterval,
        work: @escaping @Sendable () async -> Void
    ) async -> IndexingActivityOpportunity {
        _ = interval
        _ = tolerance
        if forceDeferred { return .deferred }
        if !immediate {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        if Task.isCancelled { return .cancelled }

        lock.withLock {
            workInvocations += 1
        }

        let delay = workDelayNanoseconds
        let workTask = Task {
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            await work()
        }
        lock.withLock {
            activeWork = workTask
        }

        await withTaskCancellationHandler {
            await workTask.value
        } onCancel: {
            workTask.cancel()
        }

        let cancelled = lock.withLock {
            activeWork = nil
            let cancelled = Task.isCancelled || cancelRequested
            cancelRequested = false
            if cancelled {
                lastCancelWaitedForWork = true
            } else {
                finishedAfterWorkCount += 1
                lastRunFinishedAfterWork = true
            }
            return cancelled
        }
        return cancelled ? .cancelled : .run
    }

    public func invalidate() async {
        let work = lock.withLock {
            cancelRequested = true
            let work = activeWork
            activeWork = nil
            return work
        }
        work?.cancel()
        if let work {
            await work.value
            lock.withLock {
                lastInvalidateWaitedForWork = true
            }
        }
    }
}
