import Foundation

/// Cooperative cancel + long-operation lifecycle for project migrations.
///
/// Wave 8 long-ops contracts:
/// - stable `operationId` with collision-safe fingerprints
/// - **explicit** cancel only via `requestCancel` (IPC `cancelProjectMoveBatch`)
/// - atomic pre-commit → commit transition via `beginCommitIfNotCancelled`
/// - peer disconnect / request-task cancel detaches waiters only (never calls cancel)
/// - terminal success/failure cached for reconnect/idempotence within a bounded TTL
/// - in-process only: restart loses entries (idempotence window is process-local)
final class ProjectMoveBatchCancelRegistry: @unchecked Sendable {
    static let shared = ProjectMoveBatchCancelRegistry()

    /// Structured terminal failure preserved for reconnect/duplicate (contract 7).
    struct CachedFailure: Codable, Equatable, Sendable {
        let name: String
        let message: String
        let retryPolicy: String
        let detailsJSON: String?

        init(
            name: String,
            message: String,
            retryPolicy: String = "never",
            detailsJSON: String? = nil
        ) {
            self.name = name
            self.message = message
            self.retryPolicy = retryPolicy
            self.detailsJSON = detailsJSON
        }
    }

    enum Terminal: Equatable, Sendable {
        case success(Data)
        case failure(CachedFailure)
    }

    enum BeginOutcome: Sendable {
        case proceed
        case completed(Terminal)
        case join(wait: @Sendable () async throws -> Terminal)
        case fingerprintConflict(existing: String)
    }

    /// Injectable clock + retention for tests (contract 5).
    struct Config: Sendable {
        var maxTerminalEntries: Int
        var terminalTTL: TimeInterval
        var now: @Sendable () -> Date

        static let `default` = Config(
            maxTerminalEntries: 64,
            terminalTTL: 30 * 60,
            now: { Date() }
        )
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Terminal, Error>
    }

    private struct Entry {
        var fingerprint: String
        var cancelRequested = false
        /// Commit sequence started or finished — cancel must not stop work.
        var pastCommit = false
        var terminal: Terminal?
        var terminalAt: Date?
        var waiters: [Waiter] = []
        var running = false
        var touchedAt: Date
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var config: Config

    init(config: Config = .default) {
        self.config = config
    }

    /// Test seam: replace shared-style instance config (only for non-shared test instances).
    func replaceConfigForTests(_ config: Config) {
        lock.lock()
        self.config = config
        lock.unlock()
    }

    // MARK: - Explicit cancel (IPC only)

    func requestCancel(operationId: String) {
        let id = normalize(operationId)
        guard !id.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var entry = entries[id] ?? Entry(
            fingerprint: "",
            running: false,
            touchedAt: config.now()
        )
        entry.cancelRequested = true
        entry.touchedAt = config.now()
        entries[id] = entry
    }

    func isCancelled(operationId: String?) -> Bool {
        shouldStop(operationId: operationId)
    }

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

    /// Atomic commit-boundary transition (contract 1).
    /// - Returns `false` when cancel already won → caller must cancel without committing.
    /// - Returns `true` when commit may proceed; subsequent `shouldStop` is false.
    @discardableResult
    func beginCommitIfNotCancelled(operationId: String?) -> Bool {
        guard let operationId else { return true }
        let id = normalize(operationId)
        guard !id.isEmpty else { return true }
        lock.lock()
        defer { lock.unlock() }
        var entry = entries[id] ?? Entry(
            fingerprint: "",
            running: true,
            touchedAt: config.now()
        )
        if entry.cancelRequested && !entry.pastCommit {
            entry.touchedAt = config.now()
            entries[id] = entry
            return false
        }
        entry.pastCommit = true
        entry.touchedAt = config.now()
        entries[id] = entry
        return true
    }

    func markPastCommit(operationId: String?) {
        _ = beginCommitIfNotCancelled(operationId: operationId)
    }

    func isPastCommit(operationId: String?) -> Bool {
        guard let operationId else { return false }
        let id = normalize(operationId)
        guard !id.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        return entries[id]?.pastCommit == true
    }

    // MARK: - Begin / join / complete

    func beginOrJoin(operationId: String, fingerprint: String) -> BeginOutcome {
        let id = normalize(operationId)
        guard !id.isEmpty else { return .proceed }
        lock.lock()
        defer { lock.unlock() }
        pruneLocked(now: config.now())

        if var existing = entries[id] {
            if let terminal = existing.terminal {
                return .completed(terminal)
            }
            if existing.fingerprint.isEmpty {
                existing.fingerprint = fingerprint
                existing.running = true
                existing.touchedAt = config.now()
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
                    return try await self.waitForTerminal(operationId: opId)
                })
            }
            existing.running = true
            existing.touchedAt = config.now()
            entries[id] = existing
            return .proceed
        }

        entries[id] = Entry(
            fingerprint: fingerprint,
            running: true,
            touchedAt: config.now()
        )
        return .proceed
    }

    func complete(operationId: String?, payload: Data) {
        completeTerminal(operationId: operationId, terminal: .success(payload))
    }

    func completeWithFailure(operationId: String?, failure: CachedFailure) {
        completeTerminal(operationId: operationId, terminal: .failure(failure))
    }

    /// Backward-compatible string failure → structured name/message only.
    func completeWithError(operationId: String?, message: String) {
        completeWithFailure(
            operationId: operationId,
            failure: CachedFailure(
                name: "ProjectMoveOperationError",
                message: message,
                retryPolicy: "never"
            )
        )
    }

    func clear(operationId: String?) {
        guard let operationId else { return }
        let id = normalize(operationId)
        guard !id.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[id] else { return }
        entry.cancelRequested = false
        entry.touchedAt = config.now()
        if !entry.running, entry.terminal == nil, entry.waiters.isEmpty {
            entries.removeValue(forKey: id)
        } else {
            entries[id] = entry
        }
    }

    func remove(operationId: String?) {
        guard let operationId else { return }
        let id = normalize(operationId)
        guard !id.isEmpty else { return }
        lock.lock()
        entries.removeValue(forKey: id)
        lock.unlock()
    }

    /// Test inspection: number of retained entries.
    func entryCountForTests() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    func isRunningForTests(_ operationId: String) -> Bool {
        let id = normalize(operationId)
        lock.lock()
        defer { lock.unlock() }
        return entries[id]?.running == true
    }

    // MARK: - Internals

    private func completeTerminal(operationId: String?, terminal: Terminal) {
        guard let operationId else { return }
        let id = normalize(operationId)
        guard !id.isEmpty else { return }
        lock.lock()
        var entry = entries[id] ?? Entry(
            fingerprint: "",
            running: false,
            touchedAt: config.now()
        )
        entry.terminal = terminal
        entry.terminalAt = config.now()
        entry.running = false
        entry.touchedAt = config.now()
        let waiters = entry.waiters
        entry.waiters = []
        entries[id] = entry
        pruneLocked(now: config.now())
        lock.unlock()
        for waiter in waiters {
            waiter.continuation.resume(returning: terminal)
        }
    }

    /// Cancellation-aware wait: request cancel removes only this waiter (contract 2).
    func waitForTerminal(operationId: String) async throws -> Terminal {
        let id = normalize(operationId)
        let waiterId = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Terminal, Error>) in
                lock.lock()
                if let terminal = entries[id]?.terminal {
                    lock.unlock()
                    cont.resume(returning: terminal)
                    return
                }
                guard var entry = entries[id] else {
                    lock.unlock()
                    cont.resume(
                        throwing: ProjectMoveOperationRegistryError.completedWithError("operation missing")
                    )
                    return
                }
                entry.waiters.append(Waiter(id: waiterId, continuation: cont))
                entry.touchedAt = config.now()
                entries[id] = entry
                lock.unlock()
            }
        } onCancel: { [weak self] in
            self?.removeWaiter(operationId: id, waiterId: waiterId)
        }
    }

    private func removeWaiter(operationId: String, waiterId: UUID) {
        lock.lock()
        guard var entry = entries[operationId] else {
            lock.unlock()
            return
        }
        var removed: Waiter?
        if let idx = entry.waiters.firstIndex(where: { $0.id == waiterId }) {
            removed = entry.waiters.remove(at: idx)
        }
        entry.touchedAt = config.now()
        entries[operationId] = entry
        lock.unlock()
        removed?.continuation.resume(throwing: CancellationError())
    }

    /// Evict expired/stale terminal and cancel-only entries. Never running or waiter-bearing.
    private func pruneLocked(now: Date) {
        let ttl = config.terminalTTL
        let maxTerminal = config.maxTerminalEntries

        // Drop expired terminals and stale cancel-only reservations.
        for (key, entry) in entries {
            if entry.running || !entry.waiters.isEmpty { continue }
            if let terminalAt = entry.terminalAt,
               now.timeIntervalSince(terminalAt) > ttl
            {
                entries.removeValue(forKey: key)
                continue
            }
            // Cancel-only reservation with no fingerprint / no work.
            if entry.fingerprint.isEmpty,
               entry.terminal == nil,
               !entry.running,
               entry.waiters.isEmpty,
               now.timeIntervalSince(entry.touchedAt) > ttl
            {
                entries.removeValue(forKey: key)
            }
        }

        // LRU cap among terminal-only entries.
        let terminals = entries.filter { _, e in
            e.terminal != nil && !e.running && e.waiters.isEmpty
        }
        if terminals.count > maxTerminal {
            let sorted = terminals.sorted { a, b in
                (a.value.terminalAt ?? a.value.touchedAt) < (b.value.terminalAt ?? b.value.touchedAt)
            }
            let overflow = sorted.count - maxTerminal
            for i in 0..<overflow {
                entries.removeValue(forKey: sorted[i].key)
            }
        }
    }

    private func normalize(_ operationId: String) -> String {
        operationId.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ProjectMoveOperationRegistryError: Error, Equatable, LocalizedError {
    case completedWithError(String)
    case fingerprintConflict
    case structuredFailure(ProjectMoveBatchCancelRegistry.CachedFailure)

    var errorDescription: String? {
        switch self {
        case .completedWithError(let message):
            return message
        case .fingerprintConflict:
            return "operation_id already used with a different project migration request"
        case .structuredFailure(let failure):
            return failure.message
        }
    }
}

// MARK: - Collision-safe fingerprints (contract 6)

enum ProjectMoveOperationFingerprint {
    /// Canonical JSON object with sorted keys — paths may contain `|` safely.
    static func encode(_ fields: [String: String]) -> String {
        let sorted = fields.keys.sorted()
        var obj = "{"
        for (i, key) in sorted.enumerated() {
            if i > 0 { obj += "," }
            obj += jsonString(key) + ":" + jsonString(fields[key] ?? "")
        }
        obj += "}"
        return obj
    }

    private static func jsonString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
}
