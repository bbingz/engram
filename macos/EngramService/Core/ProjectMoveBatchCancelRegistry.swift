import Foundation

/// Cooperative cancel + long-operation lifecycle for project migrations.
///
/// - Explicit cancel only via `requestCancel` (IPC `cancelProjectMoveBatch`)
/// - Atomic pre-commit → commit via `beginCommitIfNotCancelled`
/// - Peer disconnect detaches waiters only (never requestCancel)
/// - Fingerprint checked before every cached-terminal return
/// - Bounded TTL/LRU for terminals and cancel-only reservations
/// - Waiter register/cancel is race-safe under one lock
final class ProjectMoveBatchCancelRegistry: @unchecked Sendable {
    static let shared = ProjectMoveBatchCancelRegistry()

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

    struct Config: Sendable {
        var maxTerminalEntries: Int
        var maxCancelOnlyEntries: Int
        var terminalTTL: TimeInterval
        var cancelOnlyTTL: TimeInterval
        var now: @Sendable () -> Date

        static let `default` = Config(
            maxTerminalEntries: 64,
            maxCancelOnlyEntries: 32,
            terminalTTL: 30 * 60,
            cancelOnlyTTL: 60,
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
        var pastCommit = false
        var terminal: Terminal?
        var terminalAt: Date?
        var waiters: [Waiter] = []
        var running = false
        var touchedAt: Date
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    /// Waiter tokens cancelled before their continuation was registered.
    private var cancelledWaiterTokens = Set<UUID>()
    private var config: Config

    init(config: Config = .default) {
        self.config = config
    }

    func replaceConfigForTests(_ config: Config) {
        lock.lock()
        self.config = config
        lock.unlock()
    }

    // MARK: - Explicit cancel

    func requestCancel(operationId: String) {
        let id = normalize(operationId)
        guard !id.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let now = config.now()
        var entry = entries[id] ?? Entry(
            fingerprint: "",
            running: false,
            touchedAt: now
        )
        entry.cancelRequested = true
        entry.touchedAt = now
        entries[id] = entry
        pruneLocked(now: now)
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
            // Fingerprint before ANY terminal/cached return (finding 4).
            if !existing.fingerprint.isEmpty, existing.fingerprint != fingerprint {
                return .fingerprintConflict(existing: existing.fingerprint)
            }
            if let terminal = existing.terminal {
                // Adopt empty fingerprint from cancel-only into conflict-free path.
                if existing.fingerprint.isEmpty {
                    existing.fingerprint = fingerprint
                    entries[id] = existing
                }
                return .completed(terminal)
            }
            if existing.fingerprint.isEmpty {
                existing.fingerprint = fingerprint
                existing.running = true
                existing.touchedAt = config.now()
                entries[id] = existing
                return .proceed
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

    func cancelOnlyCountForTests() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.values.filter {
            $0.fingerprint.isEmpty && $0.terminal == nil && !$0.running && $0.waiters.isEmpty
        }.count
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

    /// Cancellation-aware wait with register/cancel race closed under one lock.
    func waitForTerminal(operationId: String) async throws -> Terminal {
        let id = normalize(operationId)
        let waiterId = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Terminal, Error>) in
                lock.lock()
                // Cancel arrived before registration (or task already cancelled).
                if cancelledWaiterTokens.remove(waiterId) != nil || Task.isCancelled {
                    lock.unlock()
                    cont.resume(throwing: CancellationError())
                    return
                }
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
                // Re-check cancel token after deciding to register (same critical section).
                if cancelledWaiterTokens.remove(waiterId) != nil {
                    lock.unlock()
                    cont.resume(throwing: CancellationError())
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
        if var entry = entries[operationId],
           let idx = entry.waiters.firstIndex(where: { $0.id == waiterId })
        {
            let removed = entry.waiters.remove(at: idx)
            entry.touchedAt = config.now()
            entries[operationId] = entry
            lock.unlock()
            removed.continuation.resume(throwing: CancellationError())
            return
        }
        // Cancel before registration: remember token so register path fails closed.
        cancelledWaiterTokens.insert(waiterId)
        // Bound token set growth.
        if cancelledWaiterTokens.count > 256 {
            cancelledWaiterTokens.removeAll(keepingCapacity: true)
        }
        lock.unlock()
    }

    private func pruneLocked(now: Date) {
        let terminalTTL = config.terminalTTL
        let cancelTTL = config.cancelOnlyTTL
        let maxTerminal = config.maxTerminalEntries
        let maxCancelOnly = config.maxCancelOnlyEntries

        for (key, entry) in entries {
            if entry.running || !entry.waiters.isEmpty { continue }
            if let terminalAt = entry.terminalAt,
               now.timeIntervalSince(terminalAt) > terminalTTL
            {
                entries.removeValue(forKey: key)
                continue
            }
            if entry.fingerprint.isEmpty,
               entry.terminal == nil,
               !entry.running,
               entry.waiters.isEmpty,
               now.timeIntervalSince(entry.touchedAt) > cancelTTL
            {
                entries.removeValue(forKey: key)
            }
        }

        // LRU terminals.
        let terminals = entries.filter { _, e in
            e.terminal != nil && !e.running && e.waiters.isEmpty
        }
        if terminals.count > maxTerminal {
            let sorted = terminals.sorted {
                ($0.value.terminalAt ?? $0.value.touchedAt) < ($1.value.terminalAt ?? $1.value.touchedAt)
            }
            for i in 0..<(sorted.count - maxTerminal) {
                entries.removeValue(forKey: sorted[i].key)
            }
        }

        // Bound cancel-only reservations (finding 7).
        let cancelOnly = entries.filter { _, e in
            e.fingerprint.isEmpty && e.terminal == nil && !e.running && e.waiters.isEmpty
        }
        if cancelOnly.count > maxCancelOnly {
            let sorted = cancelOnly.sorted { $0.value.touchedAt < $1.value.touchedAt }
            for i in 0..<(sorted.count - maxCancelOnly) {
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

enum ProjectMoveOperationFingerprint {
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
