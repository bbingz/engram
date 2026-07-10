import Foundation

/// Durable client-side long-op identity for project migrations (Wave 8 contract 8).
///
/// - Keeps one stable `operationId` across repeated transient failures so
///   reconnect/duplicate-submit is idempotent on the service.
/// - Clears only on terminal success, terminal non-reconnectable failure, or
///   explicit `reset()`.
/// - Blocks a second concurrent submit while unresolved.
struct ProjectLongOperationSession: Equatable, Sendable {
    private(set) var operationId: String?
    private(set) var unresolved: Bool = false
    private(set) var transientFailures: Int = 0
    /// Bounded automatic reconnect attempts for one continuous submit action.
    var maxTransientRetries: Int

    init(maxTransientRetries: Int = 8) {
        self.maxTransientRetries = maxTransientRetries
    }

    /// True when UI must disable duplicate submit (in-flight or awaiting resume).
    var blocksDuplicateSubmit: Bool {
        unresolved && operationId != nil
    }

    /// Reuse an existing id or mint a new one for a fresh operation.
    mutating func beginOrReuseOperationId(mint: () -> String = { UUID().uuidString }) -> String {
        if let operationId {
            unresolved = true
            return operationId
        }
        let id = mint()
        operationId = id
        unresolved = true
        transientFailures = 0
        return id
    }

    mutating func noteTerminalSuccess() {
        operationId = nil
        unresolved = false
        transientFailures = 0
    }

    /// Non-reconnectable failure: clear id so the next user action is a new op.
    mutating func noteTerminalFailure() {
        operationId = nil
        unresolved = false
        transientFailures = 0
    }

    /// Transient transport failure. Returns true when automatic retry should continue
    /// with the **same** operation id. When false, id is retained for explicit Resume.
    mutating func noteTransientFailure() -> Bool {
        transientFailures += 1
        unresolved = true
        return transientFailures <= maxTransientRetries
    }

    /// User-driven Resume / Check Status keeps the same id.
    mutating func prepareResume() -> String? {
        guard let operationId else { return nil }
        unresolved = true
        return operationId
    }

    mutating func reset() {
        operationId = nil
        unresolved = false
        transientFailures = 0
    }
}

enum ProjectLongOperationRunner {
    /// Run `operation` with durable operation id + bounded reconnect loop.
    static func execute<T>(
        session: inout ProjectLongOperationSession,
        isReconnectable: (Error) -> Bool,
        operation: (String) async throws -> T
    ) async throws -> T {
        let operationId = session.beginOrReuseOperationId()
        while true {
            do {
                let value = try await operation(operationId)
                session.noteTerminalSuccess()
                return value
            } catch {
                if isReconnectable(error), session.noteTransientFailure() {
                    continue
                }
                if !isReconnectable(error) {
                    session.noteTerminalFailure()
                }
                // Exhausted retries: keep operationId for explicit Resume.
                throw error
            }
        }
    }
}
