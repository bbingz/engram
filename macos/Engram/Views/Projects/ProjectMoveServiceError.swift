import Foundation

let nativeProjectMigrationCommandsEnabled = true
let nativeProjectMigrationUnavailableMessage =
    "Project move/archive/undo are temporarily unavailable. Restart Engram to recover."

struct ProjectMoveServiceErrorDetails: Equatable {
    let sourceId: String?
    let oldDir: String?
    let newDir: String?
    let sharingCwds: [String]?
    let migrationId: String?
    let state: String?

    init(details: [String: EngramServiceJSONValue]?) {
        sourceId = details?.stringValue(for: "sourceId")
        oldDir = details?.stringValue(for: "oldDir")
        newDir = details?.stringValue(for: "newDir")
        sharingCwds = details?.stringArrayValue(for: "sharingCwds")
        migrationId = details?.stringValue(for: "migrationId")
        state = details?.stringValue(for: "state")
    }
}

func projectMoveErrorMessage(_ error: Error) -> String {
    if let serviceError = error as? EngramServiceError {
        return serviceError.errorDescription ?? String(describing: serviceError)
    }
    return error.localizedDescription
}

func projectMoveRetryPolicy(_ error: Error) -> String {
    guard let serviceError = error as? EngramServiceError else {
        return "safe"
    }
    if case .commandFailed(_, _, let retryPolicy, _) = serviceError {
        return retryPolicy
    }
    return "safe"
}

func projectMoveErrorDetails(_ error: Error) -> ProjectMoveServiceErrorDetails? {
    guard let serviceError = error as? EngramServiceError else {
        return nil
    }
    if case .commandFailed(_, _, _, let details) = serviceError {
        return ProjectMoveServiceErrorDetails(details: details)
    }
    return nil
}

/// Client timeout / transport drop after the service may already have passed the
/// commit boundary. Re-submit the same `operationId` instead of treating this as
/// user cancel (Wave 8 long-ops).
func projectMoveIsReconnectableError(_ error: Error) -> Bool {
    guard let serviceError = error as? EngramServiceError else {
        let ns = error as NSError
        // URL/socket style timeouts sometimes surface as Cocoa/POSIX errors.
        if ns.domain == NSPOSIXErrorDomain && (ns.code == 60 || ns.code == 57 || ns.code == 54) {
            return true
        }
        let text = error.localizedDescription.lowercased()
        return text.contains("timeout") || text.contains("timed out") || text.contains("broken pipe")
    }
    switch serviceError {
    case .serviceUnavailable, .transportClosed, .writerBusy:
        return true
    case .commandFailed(let name, let message, _, _):
        let blob = "\(name) \(message)".lowercased()
        return blob.contains("timeout") || blob.contains("timed out") || blob.contains("disconnect")
    default:
        return false
    }
}

/// Precise cancelled-before-commit copy (not residual-refs, not transport failure).
func projectMoveCancelledBeforeCommitMessage(kind: String = "Migration") -> String {
    "\(kind) cancelled before commit — no files or index rows were committed. Safe to retry."
}

/// Shown while re-submitting the same operationId after timeout/disconnect.
func projectMoveReconnectingMessage() -> String {
    "Connection lost after the operation may have committed — reconnecting by operation id (not cancelling)…"
}

private extension Dictionary where Key == String, Value == EngramServiceJSONValue {
    func stringValue(for key: String) -> String? {
        guard case .string(let value)? = self[key] else { return nil }
        return value
    }

    func stringArrayValue(for key: String) -> [String]? {
        guard case .array(let values)? = self[key] else { return nil }
        return values.compactMap {
            guard case .string(let value) = $0 else { return nil }
            return value
        }
    }
}
