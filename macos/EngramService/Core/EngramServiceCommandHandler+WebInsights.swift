import Foundation
import GRDB
import EngramCoreRead
import EngramCoreWrite

extension EngramServiceCommandHandler {
    static func webSaveInsight(
        _ request: EngramServiceWebSaveInsightRequest,
        writer: EngramDatabaseWriter,
        settingsURL: URL = EngramServiceRunner.engramSettingsURL(
            environment: ProcessInfo.processInfo.environment
        )
    ) throws -> EngramServiceWebSaveInsightResponse {
        let sources = ServiceCaptureIngestRuntime.policy(at: settingsURL)?.enabledSources ?? []
        let json = try saveInsight(
            EngramServiceSaveInsightRequest(
                content: request.content,
                wing: request.wing,
                room: request.room,
                importance: request.importance,
                sourceSessionId: request.sourceSessionId
            ),
            writer: writer,
            prepare: { db in
                guard let sourceSessionId = request.sourceSessionId else { return }
                guard !sources.isEmpty else { throw Self.insightSourceNotFound }
                do {
                    _ = try authorizeWebSession(db, sessionId: sourceSessionId, enabledSources: sources)
                } catch {
                    throw Self.insightSourceNotFound
                }
            },
            shouldSupersede: { db, sourceSessionId in
                guard let sourceSessionId else { return true }
                guard !sources.isEmpty else { return false }
                do {
                    _ = try authorizeWebSession(db, sessionId: sourceSessionId, enabledSources: sources)
                    return true
                } catch {
                    return false
                }
            }
        )
        return try insightResponse(from: json)
    }

    private static let insightSourceNotFound = EngramServiceError.commandFailed(
        name: "NotFound",
        message: "Source session is not admitted.",
        retryPolicy: "never",
        details: nil
    )

    private static func insightResponse(
        from value: EngramServiceJSONValue
    ) throws -> EngramServiceWebSaveInsightResponse {
        guard case .object(let object) = value,
              case .string(let id)? = object["id"], !id.isEmpty else {
            throw EngramServiceError.serviceUnavailable(message: "Web insight save is unavailable.")
        }
        let warning: String?
        if case .string(let text)? = object["warning"] {
            warning = text
        } else {
            warning = nil
        }
        return try EngramServiceWebSaveInsightResponse(id: id, warning: warning)
    }
}
