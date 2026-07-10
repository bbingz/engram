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

    /// Tear down any pending scheduled work. If work is in flight, cancels it
    /// (best-effort; prefer cancelling the `performWhenDue` caller task so the
    /// await-for-exit contract applies).
    func invalidate()
}

// MARK: - Production NSBackgroundActivityScheduler

/// Production scheduler: `NSBackgroundActivityScheduler` at background QoS.
/// Activity completion and the `performWhenDue` return both wait for work exit,
/// including on cancellation (no orphaned scan Task).
public final class NSIndexingBackgroundActivityScheduler: IndexingBackgroundActivityScheduling, @unchecked Sendable {
    public static let identifier = "com.engram.service.periodic-index"
    public let backendName = "NSBackgroundActivityScheduler"

    private enum Phase {
        case idle
        /// Waiting for the OS to fire the scheduled activity.
        case awaitingSchedule
        /// Running indexing work under an open activity completion handler.
        case runningWork
    }

    private let lock = NSLock()
    private var scheduler: NSBackgroundActivityScheduler?
    private var scheduleWait: CheckedContinuation<ScheduleFire, Never>?
    private var activeWork: Task<Void, Never>?
    private var activityCompletion: ((NSBackgroundActivityScheduler.Result) -> Void)?
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
        // Phase 1: wait for OS schedule (or cancel/defer).
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
            // Phase 2: run work on a tracked Task so cancel can await exit.
            return await runTrackedWork(work: work, completeActivity: completeActivity)
        }
    }

    public func invalidate() {
        lock.lock()
        scheduler?.invalidate()
        scheduler = nil
        cancelledWhileWaiting = true
        let wait = scheduleWait
        scheduleWait = nil
        let work = activeWork
        let completion = activityCompletion
        activityCompletion = nil
        phase = .idle
        lock.unlock()

        wait?.resume(returning: .cancelled)
        work?.cancel()
        // Best-effort: do not block invalidate on work exit (caller should cancel
        // the performWhenDue task, which awaits). Still complete OS activity.
        if let work {
            Task {
                await work.value
                completion?(.finished)
            }
        } else {
            completion?(.finished)
        }
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
            self.cancelScheduleWait()
        }
    }

    private func cancelScheduleWait() {
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
            // Hand the OS completion to the work phase — do not finish yet.
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

        lock.lock()
        activeWork = workTask
        activityCompletion = completeActivity
        phase = .runningWork
        let alreadyCancelled = cancelledWhileWaiting || Task.isCancelled
        lock.unlock()

        if alreadyCancelled {
            workTask.cancel()
        }

        await withTaskCancellationHandler {
            await workTask.value
        } onCancel: {
            workTask.cancel()
        }

        // Work has fully exited. Only now finish the OS activity and clear state.
        lock.lock()
        activeWork = nil
        activityCompletion = nil
        phase = .idle
        let wasCancelled = cancelledWhileWaiting || Task.isCancelled
        cancelledWhileWaiting = false
        lock.unlock()

        completeActivity(.finished)
        return wasCancelled ? .cancelled : .run
    }

    deinit {
        invalidate()
    }
}

// MARK: - Sleep fallback

/// Test / fallback scheduler: sleep, then run work on a tracked Task so cancel
/// waits for work exit (same contract as production).
public final class SleepIndexingBackgroundActivityScheduler: IndexingBackgroundActivityScheduling, @unchecked Sendable {
    public let backendName = "Task.sleep"

    private let lock = NSLock()
    private var activeWork: Task<Void, Never>?

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
        if Task.isCancelled { return .cancelled }

        let workTask = Task { await work() }
        lock.lock()
        activeWork = workTask
        lock.unlock()

        await withTaskCancellationHandler {
            await workTask.value
        } onCancel: {
            workTask.cancel()
        }

        lock.lock()
        activeWork = nil
        lock.unlock()
        return Task.isCancelled ? .cancelled : .run
    }

    public func invalidate() {
        lock.lock()
        let work = activeWork
        activeWork = nil
        lock.unlock()
        work?.cancel()
    }
}

// MARK: - Recording test double

/// Test double that records finish-after-work ordering and cancel-wait behavior.
public final class RecordingIndexingBackgroundActivityScheduler: IndexingBackgroundActivityScheduling, @unchecked Sendable {
    public let backendName = "Recording"

    public private(set) var workInvocations = 0
    public private(set) var finishedAfterWorkCount = 0
    public private(set) var lastRunFinishedAfterWork = false
    /// True when a cancel during work waited for work to exit before returning.
    public private(set) var lastCancelWaitedForWork = false
    public var forceDeferred = false
    public var immediate = true
    /// Artificial work delay (for cancel-during-work tests).
    public var workDelayNanoseconds: UInt64 = 0

    private let lock = NSLock()
    private var activeWork: Task<Void, Never>?

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

        lock.lock()
        workInvocations += 1
        lock.unlock()

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
        lock.lock()
        activeWork = workTask
        lock.unlock()

        await withTaskCancellationHandler {
            await workTask.value
        } onCancel: {
            workTask.cancel()
        }

        let cancelled = Task.isCancelled
        lock.lock()
        activeWork = nil
        if cancelled {
            lastCancelWaitedForWork = true
        } else {
            finishedAfterWorkCount += 1
            lastRunFinishedAfterWork = true
        }
        lock.unlock()
        return cancelled ? .cancelled : .run
    }

    public func invalidate() {
        lock.lock()
        let work = activeWork
        activeWork = nil
        lock.unlock()
        work?.cancel()
    }
}
