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
