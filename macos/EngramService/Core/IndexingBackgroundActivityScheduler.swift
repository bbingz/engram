import Foundation

/// Outcome of one scheduled opportunity (Wave 7C S01).
public enum IndexingActivityOpportunity: Sendable, Equatable {
    /// OS (or fake) granted a run slot — do work.
    case run
    /// `shouldDefer` / discretionary deferral — skip this tick.
    case deferred
    /// Task cancelled or scheduler invalidated.
    case cancelled
}

/// Injectable background activity surface for adaptive periodic indexing.
/// Production uses `NSBackgroundActivityScheduler` (background QoS, tolerance,
/// `shouldDefer`). Tests use an immediate/fake implementation.
public protocol IndexingBackgroundActivityScheduling: AnyObject, Sendable {
    /// Suspend until the next scheduled opportunity for the given interval.
    /// Callers may change `interval` between waits (adaptive 15→30→60m).
    func waitForOpportunity(interval: TimeInterval, tolerance: TimeInterval) async -> IndexingActivityOpportunity

    /// Tear down any pending scheduled work.
    func invalidate()
}

/// Production scheduler: `NSBackgroundActivityScheduler` at background QoS.
public final class NSIndexingBackgroundActivityScheduler: IndexingBackgroundActivityScheduling, @unchecked Sendable {
    public static let identifier = "com.engram.service.periodic-index"

    private let lock = NSLock()
    private var scheduler: NSBackgroundActivityScheduler?
    private var pending: CheckedContinuation<IndexingActivityOpportunity, Never>?

    public init() {}

    public func waitForOpportunity(interval: TimeInterval, tolerance: TimeInterval) async -> IndexingActivityOpportunity {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<IndexingActivityOpportunity, Never>) in
                self.lock.lock()
                if Task.isCancelled {
                    self.lock.unlock()
                    continuation.resume(returning: .cancelled)
                    return
                }
                // Replace any previous wait (should not stack in production loop).
                if let previous = self.pending {
                    self.pending = continuation
                    self.lock.unlock()
                    previous.resume(returning: .cancelled)
                } else {
                    self.pending = continuation
                    self.lock.unlock()
                }
                self.armScheduler(interval: max(1, interval), tolerance: max(0, tolerance))
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

    private func armScheduler(interval: TimeInterval, tolerance: TimeInterval) {
        lock.lock()
        scheduler?.invalidate()
        let next = NSBackgroundActivityScheduler(identifier: Self.identifier)
        next.repeats = false
        next.interval = interval
        // Cap tolerance at 25% of interval (design: tolerance + shouldDefer).
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
                completion(NSBackgroundActivityScheduler.Result.deferred)
                self.finishPending(.deferred)
                return
            }
            completion(NSBackgroundActivityScheduler.Result.finished)
            self.finishPending(.run)
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

/// Test / fallback scheduler: `Task.sleep` for the interval (no OS activity API).
/// Still honors Task cancellation. Used when NSBackgroundActivityScheduler is
/// unavailable in unit-test hosts that need deterministic timing.
public final class SleepIndexingBackgroundActivityScheduler: IndexingBackgroundActivityScheduling, @unchecked Sendable {
    public init() {}

    public func waitForOpportunity(interval: TimeInterval, tolerance: TimeInterval) async -> IndexingActivityOpportunity {
        _ = tolerance
        if Task.isCancelled { return .cancelled }
        let nanos = UInt64(max(0, interval) * 1_000_000_000)
        do {
            try await Task.sleep(nanoseconds: nanos)
        } catch {
            return .cancelled
        }
        return Task.isCancelled ? .cancelled : .run
    }

    public func invalidate() {}
}
