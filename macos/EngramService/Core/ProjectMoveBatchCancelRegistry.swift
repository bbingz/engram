import Foundation

/// Cooperative cancel + long-operation lifecycle for project migrations.
///
/// - Explicit cancel only via `requestCancel` (IPC `cancelProjectMoveBatch`)
/// - Atomic pre-commit → commit via `beginCommitIfNotCancelled`
/// - Batch uses `endItemCommitWindow` so cancel can stop *between* items
/// - Peer disconnect detaches waiters only (never requestCancel)
/// - Fingerprint checked before every cached-terminal return; hits refresh LRU touch
/// - Waiter lifecycle: pending → registered → finished (exactly-once resume)
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

    /// Explicit waiter lifecycle under one lock (finding F).
    private enum WaiterState {
        case pendingCancel
        case registered(CheckedContinuation<Terminal, Error>)
        case finished
    }

    private struct Entry {
        var fingerprint: String
        var cancelRequested = false
        /// Inside irreversible commit for the *current* single-item window.
        var pastCommit = false
        var terminal: Terminal?
        var terminalAt: Date?
        var waiters: [UUID: WaiterState] = [:]
        var running = false
        var touchedAt: Date
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var config: Config
    /// Instance-scoped test seams for deterministic waiter registration races.
    private var testBeforeWaiterRegister: (@Sendable () async -> Void)?
    private var testOnWaiterRegistered: (@Sendable () -> Void)?

    init(config: Config = .default) {
        self.config = config
    }

    func replaceConfigForTests(_ config: Config) {
        lock.lock()
        self.config = config
        lock.unlock()
    }

    /// Install instance-scoped waiter barriers (nil = production no-op).
    func installWaiterTestSeamsForTests(
        beforeRegister: (@Sendable () async -> Void)? = nil,
        onRegistered: (@Sendable () -> Void)? = nil
    ) {
        lock.lock()
        testBeforeWaiterRegister = beforeRegister
        testOnWaiterRegistered = onRegistered
        lock.unlock()
    }

    func clearWaiterTestSeamsForTests() {
        installWaiterTestSeamsForTests(beforeRegister: nil, onRegistered: nil)
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

    /// After a batch item fully settles, re-open the cancel window for the next item.
    /// Single move/archive/undo leave pastCommit set until terminal complete.
    func endItemCommitWindow(operationId: String?) {
        guard let operationId else { return }
        let id = normalize(operationId)
        guard !id.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[id] else { return }
        entry.pastCommit = false
        entry.touchedAt = config.now()
        entries[id] = entry
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
            if !existing.fingerprint.isEmpty, existing.fingerprint != fingerprint {
                return .fingerprintConflict(existing: existing.fingerprint)
            }
            if let terminal = existing.terminal {
                // LRU: refresh last-touch on cached terminal hit (finding B).
                existing.touchedAt = config.now()
                if existing.fingerprint.isEmpty {
                    existing.fingerprint = fingerprint
                }
                entries[id] = existing
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

    func waiterStateCountForTests() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.values.reduce(0) { $0 + $1.waiters.count }
    }

    func hasTerminalForTests(_ operationId: String) -> Bool {
        let id = normalize(operationId)
        lock.lock()
        defer { lock.unlock() }
        return entries[id]?.terminal != nil
    }

    /// Count of waiters currently parked in `.registered` for an operation.
    func registeredWaiterCountForTests(_ operationId: String) -> Int {
        let id = normalize(operationId)
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[id] else { return 0 }
        return entry.waiters.values.reduce(0) { count, state in
            if case .registered = state { return count + 1 }
            return count
        }
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
        entry.pastCommit = false
        entry.touchedAt = config.now()
        var toResume: [CheckedContinuation<Terminal, Error>] = []
        for (wid, state) in entry.waiters {
            if case .registered(let cont) = state {
                toResume.append(cont)
            }
            entry.waiters[wid] = .finished
        }
        entry.waiters.removeAll()
        entries[id] = entry
        pruneLocked(now: config.now())
        lock.unlock()
        for cont in toResume {
            cont.resume(returning: terminal)
        }
    }

    func waitForTerminal(operationId: String) async throws -> Terminal {
        let id = normalize(operationId)
        let waiterId = UUID()

        return try await withTaskCancellationHandler {
            // Barrier inside cancellation handler so Task.cancel() is observed
            // as pendingCancel before register (deterministic cancel-before-register).
            let before: (@Sendable () async -> Void)?
            lock.lock()
            before = testBeforeWaiterRegister
            lock.unlock()
            if let before {
                await before()
            }

            return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Terminal, Error>) in
                lock.lock()
                // Cancel arrived before register → exactly-once cancel resume.
                if case .pendingCancel? = entries[id]?.waiters[waiterId] {
                    entries[id]?.waiters[waiterId] = .finished
                    entries[id]?.waiters.removeValue(forKey: waiterId)
                    lock.unlock()
                    cont.resume(throwing: CancellationError())
                    return
                }
                if Task.isCancelled {
                    if entries[id] != nil {
                        entries[id]?.waiters[waiterId] = .finished
                        entries[id]?.waiters.removeValue(forKey: waiterId)
                    }
                    lock.unlock()
                    cont.resume(throwing: CancellationError())
                    return
                }
                if let terminal = entries[id]?.terminal {
                    // Terminal already present: resume success, no waiter parked.
                    lock.unlock()
                    cont.resume(returning: terminal)
                    return
                }
                guard entries[id] != nil else {
                    lock.unlock()
                    cont.resume(
                        throwing: ProjectMoveOperationRegistryError.completedWithError("operation missing")
                    )
                    return
                }
                if case .pendingCancel? = entries[id]?.waiters[waiterId] {
                    entries[id]?.waiters[waiterId] = .finished
                    entries[id]?.waiters.removeValue(forKey: waiterId)
                    lock.unlock()
                    cont.resume(throwing: CancellationError())
                    return
                }
                entries[id]?.waiters[waiterId] = .registered(cont)
                entries[id]?.touchedAt = config.now()
                let onRegistered = testOnWaiterRegistered
                lock.unlock()
                onRegistered?()
            }
        } onCancel: { [weak self] in
            self?.cancelWaiter(operationId: id, waiterId: waiterId)
        }
    }

    private func cancelWaiter(operationId: String, waiterId: UUID) {
        lock.lock()
        guard var entry = entries[operationId] else {
            lock.unlock()
            return
        }
        // Cancellation after terminal resolution is a no-op (no pendingCancel insert).
        if entry.terminal != nil {
            lock.unlock()
            return
        }
        switch entry.waiters[waiterId] {
        case .registered(let cont):
            entry.waiters[waiterId] = .finished
            entry.waiters.removeValue(forKey: waiterId)
            entry.touchedAt = config.now()
            entries[operationId] = entry
            lock.unlock()
            cont.resume(throwing: CancellationError())
        case .finished:
            lock.unlock()
        case .pendingCancel:
            lock.unlock()
        case .none:
            // Cancel-before-register only when still running (no terminal).
            entry.waiters[waiterId] = .pendingCancel
            entry.touchedAt = config.now()
            entries[operationId] = entry
            lock.unlock()
        }
    }

    /// Test-only: invoke cancel path for a known waiter id (deterministic races).
    func cancelWaiterForTests(operationId: String, waiterId: UUID) {
        cancelWaiter(operationId: normalize(operationId), waiterId: waiterId)
    }

    private func pruneLocked(now: Date) {
        let terminalTTL = config.terminalTTL
        let cancelTTL = config.cancelOnlyTTL
        let maxTerminal = config.maxTerminalEntries
        let maxCancelOnly = config.maxCancelOnlyEntries

        for (key, entry) in entries {
            if entry.running || !entry.waiters.isEmpty { continue }
            // Absolute TTL from terminalAt (finding B: intentional).
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

        // LRU among terminals by last touch (finding B).
        let terminals = entries.filter { _, e in
            e.terminal != nil && !e.running && e.waiters.isEmpty
        }
        if terminals.count > maxTerminal {
            let sorted = terminals.sorted { $0.value.touchedAt < $1.value.touchedAt }
            for i in 0..<(sorted.count - maxTerminal) {
                entries.removeValue(forKey: sorted[i].key)
            }
        }

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
