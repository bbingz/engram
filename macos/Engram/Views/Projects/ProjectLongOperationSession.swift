import Foundation

/// Durable client-side long-op identity for project migrations.
///
/// Value type: copy-in / copy-out. UI must call `prepare` and assign the returned
/// session to `@State` **before** any `await` so Cancel can see `operationId`.
struct ProjectLongOperationSession: Equatable, Sendable {
    private(set) var operationId: String?
    private(set) var unresolved: Bool = false
    private(set) var transientFailures: Int = 0
    var maxTransientRetries: Int

    init(maxTransientRetries: Int = 8) {
        self.maxTransientRetries = maxTransientRetries
    }

    var blocksDuplicateSubmit: Bool {
        unresolved && operationId != nil
    }

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

    mutating func noteTerminalFailure() {
        operationId = nil
        unresolved = false
        transientFailures = 0
    }

    mutating func noteTransientFailure() -> Bool {
        transientFailures += 1
        unresolved = true
        return transientFailures <= maxTransientRetries
    }

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

struct ProjectLongOperationPrepareResult: Equatable, Sendable {
    let session: ProjectLongOperationSession
    let operationId: String
}

struct ProjectLongOperationExecuteResult<T> {
    let session: ProjectLongOperationSession
    let result: Result<T, Error>
}

enum ProjectLongOperationRunner {
    /// Mint/reuse ID and return a session that already publishes it.
    /// Callers must assign `session` to `@State` before suspending.
    static func prepare(
        session: ProjectLongOperationSession,
        mint: () -> String = { UUID().uuidString }
    ) -> ProjectLongOperationPrepareResult {
        var next = session
        let id = next.beginOrReuseOperationId(mint: mint)
        return ProjectLongOperationPrepareResult(session: next, operationId: id)
    }

    /// Execute with an ID that was already published via `prepare`.
    static func execute<T>(
        session: ProjectLongOperationSession,
        operationId: String,
        isReconnectable: (Error) -> Bool,
        operation: (String) async throws -> T
    ) async -> ProjectLongOperationExecuteResult<T> {
        var next = session
        // Keep the published id for the whole reconnect loop.
        _ = next.beginOrReuseOperationId(mint: { operationId })
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
                return ProjectLongOperationExecuteResult(session: next, result: .failure(error))
            }
        }
    }
}
