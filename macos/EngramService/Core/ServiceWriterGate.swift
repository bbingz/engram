import Darwin
import Foundation
import EngramCoreWrite

public struct ServiceWriterGateResult<Value: Sendable>: Sendable {
    public let value: Value
    public let databaseGeneration: Int
}

public actor ServiceWriterGate {
    public typealias WriterFactory = @Sendable (_ path: String) throws -> EngramDatabaseWriter

    /// Set only around an accepted Unix-socket handler. Once that handler has
    /// entered the writer gate, its producer must remain queued/running even if
    /// the peer disconnects; the request waiter itself remains cancellable.
    @TaskLocal static var preserveAcceptedWriteProducer = false

    private struct CachedIndexStatus {
        let databaseGeneration: Int
        let cachedAt: Date
        let status: EngramDatabaseIndexStatus
    }

    public let databasePath: String
    private let lockFD: Int32
    private let lockPath: String
    private let databaseLockFD: Int32
    private let databaseLockPath: String
    private let writer: EngramDatabaseWriter
    private let writeSemaphore = ServiceAsyncSemaphore(value: 1)
    private var databaseGeneration = 0
    private var indexStatusCache: CachedIndexStatus?
    private var longRunningWriteInProgress = false
    /// Pending (queued, not yet holding) + active long-running writes. Followers
    /// pass `timeout=nil` while this is > 0 so a write enqueued behind a still-
    /// queued project migration does not arm a 60s timeout that fires while the
    /// migration is legitimately waiting, then holding, for minutes (audit M1).
    private var pendingOrActiveLongWrites = 0
    private var writeInProgress = false
    private var acceptingWrites = true
    private let indexStatusCacheTTL: TimeInterval
    private let now: @Sendable () -> Date
    // Upper bound a queued write may wait for the gate before giving up. Sized
    // well above any legitimate single write (which complete in ms) so it only
    // trips when a normal holder is genuinely wedged. Project migration commands
    // can legitimately hold the gate for minutes; queued writes wait unbounded
    // behind those holders instead of surfacing false writerBusy errors. 0
    // disables the timeout.
    private let queueTimeoutNanoseconds: UInt64?

    public init(
        databasePath: String,
        runtimeDirectory: URL,
        acquireRuntimeLock: Bool = true,
        queueTimeoutNanoseconds: UInt64? = 60_000_000_000,
        indexStatusCacheTTL: TimeInterval = 10,
        now: @escaping @Sendable () -> Date = { Date() },
        writerFactory: WriterFactory = { try EngramDatabaseWriter(path: $0) }
    ) throws {
        self.queueTimeoutNanoseconds = (queueTimeoutNanoseconds == 0) ? nil : queueTimeoutNanoseconds
        self.indexStatusCacheTTL = indexStatusCacheTTL
        self.now = now
        try Self.validateRuntimeDirectory(runtimeDirectory)
        self.databasePath = databasePath
        lockPath = runtimeDirectory.appendingPathComponent("engram-service.lock").path
        lockFD = acquireRuntimeLock ? try Self.acquireProcessLock(path: lockPath) : -1
        databaseLockPath = URL(fileURLWithPath: databasePath)
            .deletingLastPathComponent()
            .appendingPathComponent(".lock")
            .path
        do {
            databaseLockFD = try Self.acquireProcessLock(path: databaseLockPath)
        } catch {
            if lockFD >= 0 {
                flock(lockFD, LOCK_UN)
                close(lockFD)
            }
            throw error
        }

        do {
            writer = try writerFactory(databasePath)
        } catch {
            flock(databaseLockFD, LOCK_UN)
            close(databaseLockFD)
            if lockFD >= 0 {
                flock(lockFD, LOCK_UN)
                close(lockFD)
            }
            throw error
        }
    }

    deinit {
        flock(databaseLockFD, LOCK_UN)
        close(databaseLockFD)
        if lockFD >= 0 {
            flock(lockFD, LOCK_UN)
            close(lockFD)
        }
    }

    /// Snapshot of the monotonic generation counter (for long-op waiters that
    /// completed work under a detached gate holder).
    public func currentDatabaseGeneration() -> Int {
        databaseGeneration
    }

    public func performWriteCommand<Value: Sendable>(
        name: String,
        operation: @escaping @Sendable (EngramDatabaseWriter) async throws -> Value
    ) async throws -> ServiceWriterGateResult<Value> {
        guard Self.preserveAcceptedWriteProducer else {
            return try await runWriteCommand(name: name, operation: operation)
        }

        let completion = AcceptedWriteCommandCompletion<Value>()
        Task.detached(priority: .userInitiated) { [self] in
            do {
                await completion.finish(
                    .success(try await runWriteCommand(name: name, operation: operation))
                )
            } catch {
                await completion.finish(.failure(error))
            }
        }
        return try await completion.wait()
    }

    private func runWriteCommand<Value: Sendable>(
        name: String,
        operation: @escaping @Sendable (EngramDatabaseWriter) async throws -> Value
    ) async throws -> ServiceWriterGateResult<Value> {
        guard acceptingWrites || Self.isShutdownCheckpointCommand(name) else {
            throw EngramServiceError.serviceUnavailable(message: "EngramService is shutting down")
        }
        let isLongRunning = Self.isLongRunningWriteCommand(name)
        // Count pending long writes *before* wait so short followers enqueued
        // behind a still-queued migration get timeout=nil (M1).
        if isLongRunning {
            pendingOrActiveLongWrites += 1
        }
        // Timeout policy:
        // - Short write: nil if any long write is pending/active (don't false
        //   WriterBusy behind projectMove / index).
        // - Long write: nil only when *another* long write is pending/active or
        //   currently holding. A sole long-op waiting on a short holder must
        //   still arm the queue timeout or it hangs forever (CI hang 2026-07-18).
        let otherLongWrites = pendingOrActiveLongWrites - (isLongRunning ? 1 : 0)
        let timeout: UInt64?
        if isLongRunning {
            timeout = (otherLongWrites > 0 || longRunningWriteInProgress)
                ? nil
                : queueTimeoutNanoseconds
        } else {
            timeout = (pendingOrActiveLongWrites > 0 || longRunningWriteInProgress)
                ? nil
                : queueTimeoutNanoseconds
        }
        do {
            try await writeSemaphore.wait(timeoutNanoseconds: timeout)
        } catch {
            if isLongRunning {
                pendingOrActiveLongWrites = max(0, pendingOrActiveLongWrites - 1)
            }
            throw error
        }
        // The actor is reentrant while the semaphore wait is suspended. A
        // command that queued before SIGTERM must re-check the shutdown fence
        // after receiving the permit, otherwise it can begin a fresh write
        // after the listener and existing handlers have already been stopped.
        guard acceptingWrites || Self.isShutdownCheckpointCommand(name) else {
            if isLongRunning {
                pendingOrActiveLongWrites = max(0, pendingOrActiveLongWrites - 1)
            }
            await writeSemaphore.signal()
            throw EngramServiceError.serviceUnavailable(message: "EngramService is shutting down")
        }
        longRunningWriteInProgress = isLongRunning
        writeInProgress = true
        indexStatusCache = nil
        do {
            try Task.checkCancellation()
            let value = try await operation(writer)
            databaseGeneration += 1
            indexStatusCache = nil
            longRunningWriteInProgress = false
            writeInProgress = false
            if isLongRunning {
                pendingOrActiveLongWrites = max(0, pendingOrActiveLongWrites - 1)
            }
            await writeSemaphore.signal()
            return ServiceWriterGateResult(value: value, databaseGeneration: databaseGeneration)
        } catch {
            longRunningWriteInProgress = false
            writeInProgress = false
            if isLongRunning {
                pendingOrActiveLongWrites = max(0, pendingOrActiveLongWrites - 1)
            }
            indexStatusCache = nil
            await writeSemaphore.signal()
            throw error
        }
    }

    /// Wave 7C M01: pure reads through the gate must not bump databaseGeneration.
    public func performReadCommand<Value: Sendable>(
        name: String,
        operation: @Sendable (EngramDatabaseWriter) async throws -> Value
    ) async throws -> ServiceWriterGateResult<Value> {
        _ = name
        let timeout = pendingOrActiveLongWrites > 0 ? nil : queueTimeoutNanoseconds
        try await writeSemaphore.wait(timeoutNanoseconds: timeout)
        writeInProgress = true
        do {
            try Task.checkCancellation()
            let value = try await operation(writer)
            writeInProgress = false
            await writeSemaphore.signal()
            return ServiceWriterGateResult(value: value, databaseGeneration: databaseGeneration)
        } catch {
            writeInProgress = false
            await writeSemaphore.signal()
            throw error
        }
    }

    public func checkpointWal() async throws {
        _ = try await performWriteCommand(name: "checkpointWal") { writer in
            try writer.checkpointPassive()
        }
    }

    public func indexStatus() throws -> EngramDatabaseIndexStatus {
        guard indexStatusCacheTTL > 0 else {
            return try writer.indexStatus()
        }

        let currentTime = now()
        guard !writeInProgress else {
            return try writer.indexStatus()
        }
        if let cached = indexStatusCache,
           cached.databaseGeneration == databaseGeneration {
            // `now()` defaults to wall-clock `Date()`, which is not monotonic: an
            // NTP/manual/sleep correction can move it backward. A negative elapsed
            // value is always `< TTL`, which would pin a stale cache past its TTL,
            // so require non-negative elapsed too (treat a backward jump as expiry).
            let elapsed = currentTime.timeIntervalSince(cached.cachedAt)
            if elapsed >= 0, elapsed < indexStatusCacheTTL {
                return cached.status
            }
        }

        let status = try writer.indexStatus()
        indexStatusCache = CachedIndexStatus(
            databaseGeneration: databaseGeneration,
            cachedAt: currentTime,
            status: status
        )
        return status
    }

    func queuedWriteWaiterCountForTesting() async -> Int {
        await writeSemaphore.waiterCount
    }

    func beginShutdown() {
        // docs/invariants.md #1: once shutdown starts, the single service writer
        // admits only the final WAL checkpoints; queued/product writes must not
        // begin after the listener and client handlers are stopped.
        acceptingWrites = false
    }

    func isIdleForShutdown() async -> Bool {
        // docs/invariants.md #1: shutdown maintenance may run only after every
        // service-owned writer has released the single-writer gate.
        guard !writeInProgress, pendingOrActiveLongWrites == 0 else { return false }
        return await writeSemaphore.waiterCount == 0
    }

    /// Best-effort TRUNCATE checkpoint. Returns the SQLite result tuple so the
    /// caller can decide whether to log/retry. Throws only if the underlying
    /// pool write fails outright; a `busy=1` result is considered a normal
    /// outcome (a reader held the WAL) — caller inspects the tuple.
    @discardableResult
    public func checkpointTruncate(
        waitForReaders: Bool = true
    ) async throws -> (busy: Int64, logFrames: Int64, checkpointed: Int64) {
        try await performWriteCommand(name: "checkpointTruncate") { writer in
            try writer.checkpointTruncate(waitForReaders: waitForReaders)
        }.value
    }

    private static func validateRuntimeDirectory(_ directory: URL) throws {
        var info = stat()
        guard lstat(directory.path, &info) == 0 else {
            throw EngramServiceError.serviceUnavailable(message: "Cannot stat service runtime directory")
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            throw EngramServiceError.serviceUnavailable(message: "Service runtime path is not a directory")
        }
        guard info.st_uid == geteuid() else {
            throw EngramServiceError.serviceUnavailable(message: "Service runtime directory is owned by another user")
        }
        guard (info.st_mode & 0o077) == 0 else {
            throw EngramServiceError.serviceUnavailable(message: "Service runtime directory must be mode 0700")
        }
    }

    private static func acquireProcessLock(path: String) throws -> Int32 {
        let fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw EngramServiceError.writerBusy(message: "Cannot open EngramService writer lock")
        }
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              fchmod(fd, S_IRUSR | S_IWUSR) == 0 else {
            close(fd)
            throw EngramServiceError.writerBusy(message: "Cannot secure EngramService writer lock")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw EngramServiceError.writerBusy(message: "Another EngramService writer owns the lock")
        }
        return fd
    }

    /// Classifies maintenance/index holders so followers skip the 60s queue timeout.
    /// Internal for unit tests (Wave 7C H02).
    static func isLongRunningWriteCommand(_ name: String) -> Bool {
        // docs/invariants.md #1: every product write stays serialized here, so
        // healthy maintenance holders must be classified before followers queue.
        switch name {
        case "projectMove", "projectArchive", "projectUndo", "projectMoveBatch":
            return true
        // VACUUM rebuilds the whole DB file; let user writes queue (unbounded)
        // rather than hit the 60s WriterBusy timeout while it runs.
        case "remoteVacuum", "userDataBackup", "checkpointWal", "checkpointTruncate":
            return true
        // Wave 7C H02: multi-minute index/backfill/FTS/embed phases hold the gate
        // under healthy progress — do not false-timeout followers at 60s.
        case "initialScanIndex",
             "initialScanBackfills",
             "initialInstructionBackfill",
             "initialImplementationBeatBackfill",
             "initialFtsDrain",
             "indexRecent",
             "indexAll",
             "periodicFtsDrain",
             "scheduledFtsRetryDrain",
             "deferredActivityFtsDrain",
             "ftsOptimize",
             "embeddingBackfill",
             "embeddingDrain",
             "parentBackfill",
             "startupBackfills":
            return true
        default:
            // Prefix match for runner-owned maintenance names.
            if name.hasPrefix("index") || name.hasPrefix("fts") || name.hasPrefix("embed")
                || name.hasPrefix("backfill") || name.hasPrefix("initialScan")
                || name.hasPrefix("periodic") || name.contains("EmbeddingBackfill")
            {
                return true
            }
            return false
        }
    }

    private static func isShutdownCheckpointCommand(_ name: String) -> Bool {
        name == "checkpointWal" || name == "checkpointTruncate"
    }
}

private actor AcceptedWriteCommandCompletion<Value: Sendable> {
    typealias Output = ServiceWriterGateResult<Value>

    private var result: Result<Output, Error>?
    private var waiters: [UUID: CheckedContinuation<Output, Error>] = [:]

    func wait() async throws -> Output {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let result {
                    continuation.resume(with: result)
                } else if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func finish(_ result: Result<Output, Error>) {
        guard self.result == nil else { return }
        self.result = result
        let pending = waiters.values
        waiters.removeAll()
        for continuation in pending {
            continuation.resume(with: result)
        }
    }

    private func cancel(id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

actor ServiceAsyncSemaphore {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var permits: Int
    private var waiters: [Waiter] = []

    init(value: Int) {
        permits = value
    }

    /// Test support: number of currently-queued waiters. Used to
    /// deterministically confirm a waiter has enqueued before driving the
    /// cancel/signal race in tests.
    var waiterCount: Int { waiters.count }

    /// Acquire a permit. If `timeoutNanoseconds` is non-nil, a queued waiter
    /// that has not been signalled within the window throws
    /// `EngramServiceError.writerBusy` and removes itself from the queue. This
    /// prevents a single stuck write (e.g. a hung SQLite/NFS write that never
    /// calls `signal()`) from wedging every queued write forever — the only
    /// other escape was Task cancellation, which drops the caller's work.
    func wait(timeoutNanoseconds: UInt64? = nil) async throws {
        try Task.checkCancellation()
        if permits > 0 {
            permits -= 1
            return
        }

        let id = UUID()
        let timeoutTask: Task<Void, Never>?
        if let timeoutNanoseconds {
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                guard !Task.isCancelled else { return }
                await self?.timeOut(id: id)
            }
        } else {
            timeoutTask = nil
        }

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            } onCancel: {
                Task {
                    await cancel(id: id)
                }
            }
        } catch {
            timeoutTask?.cancel()
            throw error
        }
        timeoutTask?.cancel()
        if Task.isCancelled {
            // Reaching here means the continuation resumed NORMALLY (signal()
            // handed us the permit) — cancel()/timeOut() resume by throwing and
            // are caught above. If our task was cancelled in the window before
            // the async cancel handler could dequeue us, signal() still picked
            // us as `waiters.first` and gave us the permit. Release it before
            // surfacing cancellation, otherwise the permit is lost and the
            // single writer gate wedges permanently (every later write times
            // out with writerBusy).
            signal()
            throw CancellationError()
        }
    }

    private func cancel(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }

        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func timeOut(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }

        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(
            throwing: EngramServiceError.writerBusy(
                message: "Timed out waiting for the EngramService write lock"
            )
        )
    }

    func signal() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.continuation.resume()
        } else {
            permits += 1
        }
    }
}
