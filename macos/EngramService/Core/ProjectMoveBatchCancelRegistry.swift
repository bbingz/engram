import Foundation

/// Cooperative cancel + long-operation lifecycle for project migrations.
///
/// Wave 7C M05 added cancel flags for `projectMoveBatch`. Wave 8 long-ops
/// extends the same registry so rename/archive/undo/batch share:
/// - stable `operationId`
/// - cancel effective only **before** the commit boundary
/// - after commit, cancel/client disconnect does not false-stop the service work
/// - duplicate submit with the same id is idempotent (join or return cached result)
///
/// `cancelProjectMoveBatch` IPC still only calls `requestCancel`; status/reconnect
/// is achieved by re-submitting the same `operationId` on move/archive/undo/batch.
final class ProjectMoveBatchCancelRegistry: @unchecked Sendable {
    static let shared = ProjectMoveBatchCancelRegistry()

    enum BeginOutcome: Sendable {
        /// No prior work — caller should start the pipeline.
        case proceed
        /// Prior work finished; `payload` is the encoded success result.
        case completed(Data)
        /// Prior work is still running; await `wait()` for the same result.
        case join(wait: @Sendable () async throws -> Data)
        /// Same operationId was used with a different fingerprint.
        case fingerprintConflict(existing: String)
    }

    private struct Entry {
        var fingerprint: String
        var cancelRequested = false
        /// Once true, cooperative cancel must not stop the pipeline.
        var pastCommit = false
        var completedPayload: Data?
        var completedError: String?
        var waiters: [CheckedContinuation<Data, Error>] = []
        /// True while a producer is still running (including after client detach).
        var running = false
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    // MARK: - Cancel (pre-commit only)

    func requestCancel(operationId: String) {
        let id = normalize(operationId)
        guard !id.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var entry = entries[id] ?? Entry(fingerprint: "", running: false)
        entry.cancelRequested = true
        entries[id] = entry
    }

    /// Legacy name used by existing call sites; equivalent to `shouldStop`.
    func isCancelled(operationId: String?) -> Bool {
        shouldStop(operationId: operationId)
    }

    /// True only when cancel was requested **and** the op has not crossed commit.
    func shouldStop(operationId: String?) -> Bool {
        guard let operationId else { return false }
        let id = normalize(operationId)
        guard !id.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[id] else { return false }
        if entry.pastCommit { return false }
        return entry.cancelRequested
    }

    func markPastCommit(operationId: String?) {
        guard let operationId else { return }
        let id = normalize(operationId)
        guard !id.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[id] else {
            entries[id] = Entry(fingerprint: "", pastCommit: true, running: false)
            return
        }
        entry.pastCommit = true
        entries[id] = entry
    }

    func isPastCommit(operationId: String?) -> Bool {
        guard let operationId else { return false }
        let id = normalize(operationId)
        guard !id.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        return entries[id]?.pastCommit == true
    }

    // MARK: - Idempotence / reconnect

    /// Register or join a long operation.
    /// - Parameter fingerprint: stable request identity (src/dst/dryRun/…); empty
    ///   fingerprint on a pure cancel reservation is ignored for conflict checks.
    func beginOrJoin(operationId: String, fingerprint: String) -> BeginOutcome {
        let id = normalize(operationId)
        guard !id.isEmpty else { return .proceed }
        lock.lock()
        defer { lock.unlock() }

        if var existing = entries[id] {
            if let payload = existing.completedPayload {
                return .completed(payload)
            }
            if let err = existing.completedError {
                let message = err
                return .join(wait: {
                    throw ProjectMoveOperationRegistryError.completedWithError(message)
                })
            }
            // Cancel-only reservation has empty fingerprint — adopt caller's.
            if existing.fingerprint.isEmpty {
                existing.fingerprint = fingerprint
                existing.running = true
                entries[id] = existing
                return .proceed
            }
            if existing.fingerprint != fingerprint {
                return .fingerprintConflict(existing: existing.fingerprint)
            }
            if existing.running {
                let opId = id
                return .join(wait: { [weak self] in
                    guard let self else {
                        throw ProjectMoveOperationRegistryError.completedWithError("registry deallocated")
                    }
                    return try await self.waitForCompletion(operationId: opId)
                })
            }
            existing.running = true
            entries[id] = existing
            return .proceed
        }

        entries[id] = Entry(fingerprint: fingerprint, running: true)
        return .proceed
    }

    func complete(operationId: String?, payload: Data) {
        guard let operationId else { return }
        let id = normalize(operationId)
        guard !id.isEmpty else { return }
        lock.lock()
        var entry = entries[id] ?? Entry(fingerprint: "", running: false)
        entry.completedPayload = payload
        entry.completedError = nil
        entry.running = false
        let waiters = entry.waiters
        entry.waiters = []
        entries[id] = entry
        lock.unlock()
        for waiter in waiters {
            waiter.resume(returning: payload)
        }
    }

    func completeWithError(operationId: String?, message: String) {
        guard let operationId else { return }
        let id = normalize(operationId)
        guard !id.isEmpty else { return }
        lock.lock()
        var entry = entries[id] ?? Entry(fingerprint: "", running: false)
        entry.completedError = message
        entry.completedPayload = nil
        entry.running = false
        let waiters = entry.waiters
        entry.waiters = []
        entries[id] = entry
        lock.unlock()
        let error = ProjectMoveOperationRegistryError.completedWithError(message)
        for waiter in waiters {
            waiter.resume(throwing: error)
        }
    }

    /// Drop cancel flag only (keep completed payload for reconnect/idempotence).
    func clear(operationId: String?) {
        guard let operationId else { return }
        let id = normalize(operationId)
        guard !id.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[id] else { return }
        entry.cancelRequested = false
        // Retain completed payload / pastCommit so reconnect can still join.
        if !entry.running,
           entry.completedPayload == nil,
           entry.completedError == nil,
           entry.waiters.isEmpty
        {
            entries.removeValue(forKey: id)
        } else {
            entries[id] = entry
        }
    }

    /// Test / maintenance: fully remove an operation record.
    func remove(operationId: String?) {
        guard let operationId else { return }
        let id = normalize(operationId)
        guard !id.isEmpty else { return }
        lock.lock()
        entries.removeValue(forKey: id)
        lock.unlock()
    }

    // MARK: - Internals

    private func waitForCompletion(operationId: String) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            lock.lock()
            if let payload = entries[operationId]?.completedPayload {
                lock.unlock()
                cont.resume(returning: payload)
                return
            }
            if let message = entries[operationId]?.completedError {
                lock.unlock()
                cont.resume(throwing: ProjectMoveOperationRegistryError.completedWithError(message))
                return
            }
            guard var entry = entries[operationId] else {
                lock.unlock()
                cont.resume(throwing: ProjectMoveOperationRegistryError.completedWithError("operation missing"))
                return
            }
            entry.waiters.append(cont)
            entries[operationId] = entry
            lock.unlock()
        }
    }

    private func normalize(_ operationId: String) -> String {
        operationId.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ProjectMoveOperationRegistryError: Error, Equatable, LocalizedError {
    case completedWithError(String)
    case fingerprintConflict

    var errorDescription: String? {
        switch self {
        case .completedWithError(let message):
            return message
        case .fingerprintConflict:
            return "operation_id already used with a different project migration request"
        }
    }
}
