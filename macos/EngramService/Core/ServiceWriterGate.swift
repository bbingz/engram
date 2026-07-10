import Darwin
import Foundation
import EngramCoreWrite

public struct ServiceWriterGateResult<Value: Sendable>: Sendable {
    public let value: Value
    public let databaseGeneration: Int
}

public actor ServiceWriterGate {
    public typealias WriterFactory = @Sendable (_ path: String) throws -> EngramDatabaseWriter

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
    private var writeInProgress = false
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
        lockFD = try Self.acquireProcessLock(path: lockPath)
        databaseLockPath = URL(fileURLWithPath: databasePath)
            .deletingLastPathComponent()
            .appendingPathComponent(".lock")
            .path
        do {
            databaseLockFD = try Self.acquireProcessLock(path: databaseLockPath)
        } catch {
            flock(lockFD, LOCK_UN)
            close(lockFD)
            throw error
        }

        do {
            writer = try writerFactory(databasePath)
        } catch {
            flock(databaseLockFD, LOCK_UN)
            close(databaseLockFD)
            flock(lockFD, LOCK_UN)
            close(lockFD)
            throw error
        }
    }

    deinit {
        flock(databaseLockFD, LOCK_UN)
        close(databaseLockFD)
        flock(lockFD, LOCK_UN)
        close(lockFD)
    }

    public func performWriteCommand<Value: Sendable>(
        name: String,
        operation: @Sendable (EngramDatabaseWriter) async throws -> Value
    ) async throws -> ServiceWriterGateResult<Value> {
        let timeout = longRunningWriteInProgress ? nil : queueTimeoutNanoseconds
        try await writeSemaphore.wait(timeoutNanoseconds: timeout)
        longRunningWriteInProgress = Self.isLongRunningWriteCommand(name)
        writeInProgress = true
        indexStatusCache = nil
        do {
            try Task.checkCancellation()
            let value = try await operation(writer)
            databaseGeneration += 1
            indexStatusCache = nil
            longRunningWriteInProgress = false
            writeInProgress = false
            await writeSemaphore.signal()
            return ServiceWriterGateResult(value: value, databaseGeneration: databaseGeneration)
        } catch {
            longRunningWriteInProgress = false
            writeInProgress = false
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
        let timeout = longRunningWriteInProgress ? nil : queueTimeoutNanoseconds
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
        try await writeSemaphore.wait()
        do {
            try Task.checkCancellation()
            try writer.checkpointPassive()
            await writeSemaphore.signal()
        } catch {
            await writeSemaphore.signal()
            throw error
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

    /// Best-effort TRUNCATE checkpoint. Returns the SQLite result tuple so the
    /// caller can decide whether to log/retry. Throws only if the underlying
    /// pool write fails outright; a `busy=1` result is considered a normal
    /// outcome (a reader held the WAL) — caller inspects the tuple.
    @discardableResult
    public func checkpointTruncate() async throws -> (busy: Int64, logFrames: Int64, checkpointed: Int64) {
        try await writeSemaphore.wait()
        do {
            try Task.checkCancellation()
            let result = try writer.checkpointTruncate()
            await writeSemaphore.signal()
            return result
        } catch {
            await writeSemaphore.signal()
            throw error
        }
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
        let fd = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw EngramServiceError.writerBusy(message: "Cannot open EngramService writer lock")
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
        switch name {
        case "projectMove", "projectArchive", "projectUndo", "projectMoveBatch":
            return true
        // VACUUM rebuilds the whole DB file; let user writes queue (unbounded)
        // rather than hit the 60s WriterBusy timeout while it runs.
        case "remoteVacuum", "userDataBackup":
            return true
        // Wave 7C H02: multi-minute index/backfill/FTS/embed phases hold the gate
        // under healthy progress — do not false-timeout followers at 60s.
        case "initialScanIndex",
             "initialScanBackfills",
             "indexRecent",
             "indexAll",
             "periodicFtsDrain",
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
            {
                return true
            }
            return false
        }
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
