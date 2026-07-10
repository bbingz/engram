import Foundation

/// Durable client-side long-op identity for project migrations (Wave 8 contract 8).
///
/// - Keeps one stable `operationId` across repeated transient failures so
///   reconnect/duplicate-submit is idempotent on the service.
/// - Clears only on terminal success, terminal non-reconnectable failure, or
///   explicit `reset()`.
/// - Blocks a second concurrent submit while unresolved.
///
/// Value type by design: SwiftUI `@State` must not be passed `inout` across
/// `async` suspension. Runners copy the session, return an updated copy, and
/// the view assigns it back on the main actor after the await completes.
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

/// Pure value outcome: updated session is always returned (no inout across await).
struct ProjectLongOperationExecuteResult<T> {
    let session: ProjectLongOperationSession
    let result: Result<T, Error>
}

enum ProjectLongOperationRunner {
    /// Copy-in / copy-out reconnect loop. Does not hold `inout` across suspension,
    /// so SwiftUI `@State` can assign `longOpSession = executeResult.session` after await.
    static func execute<T>(
        session: ProjectLongOperationSession,
        isReconnectable: (Error) -> Bool,
        operation: (String) async throws -> T
    ) async -> ProjectLongOperationExecuteResult<T> {
        var next = session
        let operationId = next.beginOrReuseOperationId()
        while true {
            do {
                let value = try await operation(operationId)
                next.noteTerminalSuccess()
                return ProjectLongOperationExecuteResult(session: next, result: .success(value))
            } catch {
                if isReconnectable(error), next.noteTransientFailure() {
                    continue
                }
                if !isReconnectable(error) {
                    next.noteTerminalFailure()
                }
                // Exhausted retries: keep operationId for explicit Resume.
                return ProjectLongOperationExecuteResult(session: next, result: .failure(error))
            }
        }
    }
}
