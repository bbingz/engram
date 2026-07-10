import Foundation

/// Outcome of one scheduled opportunity (Wave 7C S01).
public enum IndexingActivityOpportunity: Sendable, Equatable {
    /// OS (or fake) granted a run slot and `work` completed under the activity.
    case run
    /// `shouldDefer` / discretionary deferral — `work` was not invoked.
    case deferred
    /// Task cancelled or scheduler invalidated.
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
    func performWhenDue(
        interval: TimeInterval,
        tolerance: TimeInterval,
        work: @escaping @Sendable () async -> Void
    ) async -> IndexingActivityOpportunity

    /// Tear down any pending scheduled work.
    func invalidate()
}

/// Production scheduler: `NSBackgroundActivityScheduler` at background QoS.
/// The activity completion handler is invoked only after indexing `work` finishes.
public final class NSIndexingBackgroundActivityScheduler: IndexingBackgroundActivityScheduling, @unchecked Sendable {
    public static let identifier = "com.engram.service.periodic-index"
    public let backendName = "NSBackgroundActivityScheduler"

    private let lock = NSLock()
    private var scheduler: NSBackgroundActivityScheduler?
    private var pending: CheckedContinuation<IndexingActivityOpportunity, Never>?

    public init() {}

    public func performWhenDue(
        interval: TimeInterval,
        tolerance: TimeInterval,
        work: @escaping @Sendable () async -> Void
    ) async -> IndexingActivityOpportunity {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<IndexingActivityOpportunity, Never>) in
                self.lock.lock()
                if Task.isCancelled {
                    self.lock.unlock()
                    continuation.resume(returning: .cancelled)
                    return
                }
                if let previous = self.pending {
                    self.pending = continuation
                    self.lock.unlock()
                    previous.resume(returning: .cancelled)
                } else {
                    self.pending = continuation
                    self.lock.unlock()
                }
                self.armScheduler(
                    interval: max(1, interval),
                    tolerance: max(0, tolerance),
                    work: work
                )
            }
        } onCancel: {
            self.finishPending(.cancelled)
        }
    }

    public func invalidate() {
        lock.lock()
        scheduler?.invalidate()
        scheduler = nil
        let cont = pending
        pending = nil
        lock.unlock()
        cont?.resume(returning: .cancelled)
    }

    private func armScheduler(
        interval: TimeInterval,
        tolerance: TimeInterval,
        work: @escaping @Sendable () async -> Void
    ) {
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
            if next.shouldDefer {
                // Defer without running work; OS activity ends as deferred.
                completion(NSBackgroundActivityScheduler.Result.deferred)
                self.finishPending(.deferred)
                return
            }
            // Keep the activity alive until indexing work returns (S01 contract).
            Task {
                await work()
                completion(NSBackgroundActivityScheduler.Result.finished)
                self.finishPending(.run)
            }
        }
    }

    private func finishPending(_ outcome: IndexingActivityOpportunity) {
        lock.lock()
        let cont = pending
        pending = nil
        lock.unlock()
        cont?.resume(returning: outcome)
    }

    deinit {
        invalidate()
    }
}

/// Test / fallback scheduler: sleep, then run work synchronously in the caller's
/// task (completion-after-work ordering preserved for tests).
public final class SleepIndexingBackgroundActivityScheduler: IndexingBackgroundActivityScheduling, @unchecked Sendable {
    public let backendName = "Task.sleep"

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
        await work()
        return .run
    }

    public func invalidate() {}
}

/// Test double that records whether OS-style completion is ordered after work.
public final class RecordingIndexingBackgroundActivityScheduler: IndexingBackgroundActivityScheduling, @unchecked Sendable {
    public let backendName = "Recording"

    public private(set) var workInvocations = 0
    public private(set) var finishedAfterWorkCount = 0
    /// True only if the last run completed work before signalling finished.
    public private(set) var lastRunFinishedAfterWork = false
    public var forceDeferred = false
    public var immediate = true

    private let lock = NSLock()

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

        var finishedAfter = false
        await work()
        finishedAfter = true

        lock.lock()
        if finishedAfter {
            finishedAfterWorkCount += 1
            lastRunFinishedAfterWork = true
        }
        lock.unlock()
        return .run
    }

    public func invalidate() {}
}
