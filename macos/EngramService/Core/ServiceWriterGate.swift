import Darwin
import Foundation
import EngramCoreWrite

public struct ServiceWriterGateResult<Value: Sendable>: Sendable {
    public let value: Value
    public let databaseGeneration: Int
}

public actor ServiceWriterGate {
    public typealias WriterFactory = @Sendable (_ path: String) throws -> EngramDatabaseWriter

    public let databasePath: String
    private let lockFD: Int32
    private let lockPath: String
    private let databaseLockFD: Int32
    private let databaseLockPath: String
    private let writer: EngramDatabaseWriter
    private let writeSemaphore = ServiceAsyncSemaphore(value: 1)
    private var databaseGeneration = 0

    public init(
        databasePath: String,
        runtimeDirectory: URL,
        writerFactory: WriterFactory = { try EngramDatabaseWriter(path: $0) }
    ) throws {
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
        await writeSemaphore.wait()
        do {
            let value = try await operation(writer)
            databaseGeneration += 1
            await writeSemaphore.signal()
            return ServiceWriterGateResult(value: value, databaseGeneration: databaseGeneration)
        } catch {
            await writeSemaphore.signal()
            throw error
        }
    }

    public func checkpointWal() async throws {
        await writeSemaphore.wait()
        do {
            try writer.checkpointPassive()
            await writeSemaphore.signal()
        } catch {
            await writeSemaphore.signal()
            throw error
        }
    }

    /// Best-effort TRUNCATE checkpoint. Returns the SQLite result tuple so the
    /// caller can decide whether to log/retry. Throws only if the underlying
    /// pool write fails outright; a `busy=1` result is considered a normal
    /// outcome (a reader held the WAL) — caller inspects the tuple.
    @discardableResult
    public func checkpointTruncate() async throws -> (busy: Int64, logFrames: Int64, checkpointed: Int64) {
        await writeSemaphore.wait()
        do {
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
}

private actor ServiceAsyncSemaphore {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) {
        permits = value
    }

    func wait() async {
        if permits > 0 {
            permits -= 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        if waiters.isEmpty {
            permits += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
