import Foundation

/// In-process cooperative cancel flags for projectMoveBatch (Wave 7C M05).
/// Cancel is best-effort between operations; already-committed moves stay committed.
final class ProjectMoveBatchCancelRegistry: @unchecked Sendable {
    static let shared = ProjectMoveBatchCancelRegistry()

    private let lock = NSLock()
    private var cancelled = Set<String>()

    func requestCancel(operationId: String) {
        let id = operationId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        lock.lock()
        cancelled.insert(id)
        lock.unlock()
    }

    func isCancelled(operationId: String?) -> Bool {
        guard let operationId, !operationId.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        return cancelled.contains(operationId)
    }

    func clear(operationId: String?) {
        guard let operationId, !operationId.isEmpty else { return }
        lock.lock()
        cancelled.remove(operationId)
        lock.unlock()
    }
}
