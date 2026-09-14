import Foundation
import EngramCoreWrite

extension EngramServiceCommandHandler {
    func addWebProjectAlias(
        _ request: EngramServiceWebAddAliasRequest,
        writer: EngramDatabaseWriter
    ) throws -> EngramServiceWebAliasMutationResponse {
        do {
            return try webMetadataProducer.addProjectAlias(request, writer: writer)
        } catch {
            throw Self.webAliasServiceError(error)
        }
    }

    func removeWebProjectAlias(
        _ request: EngramServiceWebRemoveAliasRequest,
        writer: EngramDatabaseWriter
    ) throws -> EngramServiceWebAliasMutationResponse {
        do {
            return try webMetadataProducer.removeProjectAlias(request, writer: writer)
        } catch {
            throw Self.webAliasServiceError(error)
        }
    }

    private static func webAliasServiceError(_ error: Error) -> EngramServiceError {
        if let service = error as? EngramServiceError { return service }
        guard let metadata = error as? ServiceWebMetadataError else {
            return .serviceUnavailable(message: "Web alias service is unavailable.")
        }
        switch metadata {
        case .invalidRequest:
            return .invalidRequest(message: "Web alias request is invalid.")
        case .stale:
            return .commandFailed(
                name: "StaleCursor",
                message: "Web alias authorization is stale.",
                retryPolicy: "never",
                details: nil
            )
        case .notImplemented, .unavailable, .responseTooLarge, .notFound:
            return .serviceUnavailable(message: "Web alias service is unavailable.")
        }
    }
}
