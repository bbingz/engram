import Foundation
import EngramCoreRead
import EngramCoreWrite

extension EngramServiceCommandHandler {
    static func webSourceSettings(
        settingsURL: URL = EngramServiceRunner.engramSettingsURL(
            environment: ProcessInfo.processInfo.environment
        )
    ) throws -> EngramServiceWebSourceSettingsResponse {
        guard let policy = ServiceCaptureIngestRuntime.policy(at: settingsURL) else {
            throw EngramServiceError.serviceUnavailable(message: "Web source settings are unavailable.")
        }
        return try EngramServiceWebSourceSettingsValidation.projection(
            enabledSources: Set(policy.enabledSources.map(\.rawValue))
        )
    }

    static func webSetSourceEnabled(
        _ request: EngramServiceWebSetSourceEnabledRequest,
        writer: EngramDatabaseWriter,
        settingsURL: URL
    ) throws -> EngramServiceWebSetSourceEnabledResponse {
        _ = try webSourceSettings(settingsURL: settingsURL)
        try setSourceEnabled(
            EngramServiceSetSourceEnabledRequest(source: request.source, enabled: request.enabled),
            writer: writer,
            settingsURL: settingsURL
        )
        return try webSourceEnabledResponse(source: request.source, settingsURL: settingsURL)
    }

    static func webSourceEnabledResponse(
        source: String,
        settingsURL: URL
    ) throws -> EngramServiceWebSetSourceEnabledResponse {
        guard let policy = ServiceCaptureIngestRuntime.policy(at: settingsURL) else {
            throw EngramServiceError.serviceUnavailable(message: "Web source settings are unavailable.")
        }
        guard let name = SourceName(rawValue: source) else {
            throw EngramServiceError.invalidRequest(message: "Web source request is invalid.")
        }
        return try EngramServiceWebSetSourceEnabledResponse(
            source: name.rawValue,
            enabled: policy.enabledSources.contains(name)
        )
    }
}
