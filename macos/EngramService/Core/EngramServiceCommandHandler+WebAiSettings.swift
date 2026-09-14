import Darwin
import Foundation
import EngramCoreRead

extension EngramServiceCommandHandler {
    static func webAiSettings(
        settingsURL: URL = EngramServiceRunner.engramSettingsURL(
            environment: ProcessInfo.processInfo.environment
        )
    ) throws -> EngramServiceWebAiSettingsResponse {
        let object = try readWebAiSettingsObject(at: settingsURL)
        return try EngramServiceWebAiSettingsResponse(settings: projectWebAiSettings(object))
    }

    static func webPatchAiSettings(
        _ request: EngramServiceWebPatchAiSettingsRequest,
        settingsURL: URL
    ) throws -> EngramServiceWebAiSettingsResponse {
        do {
            try SecureSettingsFileWriter.mutateJSON(at: settingsURL) { object in
                applyWebAiSettingsPatch(request, to: &object)
            }
        } catch {
            throw webAiSettingsUnavailable
        }
        return try webAiSettings(settingsURL: settingsURL)
    }

    private static func readWebAiSettingsObject(at url: URL) throws -> [String: Any] {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return [:] }
            throw webAiSettingsUnavailable
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw webAiSettingsUnavailable }
        guard let data = SecureRegularFile.read(
            atPath: url.path,
            maximumBytes: 1024 * 1024,
            repairPermissions: true
        ),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw webAiSettingsUnavailable
        }
        return object
    }

    private static func applyWebAiSettingsPatch(
        _ request: EngramServiceWebPatchAiSettingsRequest,
        to object: inout [String: Any]
    ) {
        if let value = request.aiProtocol { object["aiProtocol"] = value }
        if let value = request.aiBaseURL { setOrRemove(&object, "aiBaseURL", value) }
        if let value = request.aiModel { object["aiModel"] = value }
        if let value = request.summaryLanguage { object["summaryLanguage"] = value }
        if let value = request.summaryMaxSentences { object["summaryMaxSentences"] = value }
        if let value = request.summaryStyle { setOrRemove(&object, "summaryStyle", value) }
        if let value = request.summaryPrompt { setOrRemove(&object, "summaryPrompt", value) }
        if let value = request.summaryMaxTokens { object["summaryMaxTokens"] = value }
        if let value = request.summaryTemperature { object["summaryTemperature"] = value }
        if let value = request.summarySampleFirst { object["summarySampleFirst"] = value }
        if let value = request.summarySampleLast { object["summarySampleLast"] = value }
        if let value = request.summaryTruncateChars { object["summaryTruncateChars"] = value }
        if let value = request.titleProvider { object["titleProvider"] = value }
        if let value = request.titleBaseUrl {
            object.removeValue(forKey: "titleBaseURL")
            setOrRemove(&object, "titleBaseUrl", value)
        }
        if let value = request.titleModel { object["titleModel"] = value }
        if let value = request.embeddingBaseURL { setOrRemove(&object, "embeddingBaseURL", value) }
        if let value = request.embeddingModel { object["embeddingModel"] = value }
        if let value = request.embeddingDimension { object["embeddingDimension"] = value }
        if let value = request.embeddingIncludeDimensions { object["embeddingIncludeDimensions"] = value }
        if let audit = request.aiAudit {
            var current = object["aiAudit"] as? [String: Any] ?? [:]
            if let enabled = audit.enabled { current["enabled"] = enabled }
            if let logBodies = audit.logBodies { current["logBodies"] = logBodies }
            if let maxBodySize = audit.maxBodySize { current["maxBodySize"] = maxBodySize }
            object["aiAudit"] = current
        }
    }

    private static func setOrRemove(_ object: inout [String: Any], _ key: String, _ value: String) {
        if value.isEmpty {
            object.removeValue(forKey: key)
        } else {
            object[key] = value
        }
    }

    private static func projectWebAiSettings(_ object: [String: Any]) throws -> EngramServiceWebAiSettings {
        let presetRaw = text(object["summaryPreset"]) ?? "standard"
        let preset = ["concise", "standard", "detailed"].contains(presetRaw) ? presetRaw : "standard"
        let titleProviderRaw = text(object["titleProvider"]) ?? "ollama"
        let titleProvider = ["ollama", "custom", "openai"].contains(titleProviderRaw) ? titleProviderRaw : "ollama"
        let titleDefault = titleProvider == "ollama" ? "http://localhost:11434" : "https://api.openai.com"
        let titleBase = object["titleBaseUrl"] != nil
            ? try publishedURL(object["titleBaseUrl"], fallback: titleDefault)
            : try publishedURL(object["titleBaseURL"], fallback: titleDefault)
        let audit = object["aiAudit"] as? [String: Any] ?? [:]
        // Mirror `summaryConfig`: a missing key means openai; any other stored
        // value (legacy `disabled`, unknown vendors) means summaries are off.
        let protocolRaw = text(object["aiProtocol"]) ?? "openai"
        return try EngramServiceWebAiSettings(
            aiProtocol: protocolRaw == "openai" ? "openai" : "disabled",
            aiBaseURL: try publishedURL(object["aiBaseURL"], fallback: "https://api.openai.com"),
            aiModel: text(object["aiModel"]) ?? "gpt-4o-mini",
            summaryLanguage: text(object["summaryLanguage"]) ?? "中文",
            summaryMaxSentences: int(object["summaryMaxSentences"]) ?? 3,
            summaryStyle: try publishedMultiline(
                object["summaryStyle"],
                maxBytes: EngramServiceWebAiSettingsValidation.maximumStyleBytes
            ),
            summaryPrompt: try publishedMultiline(
                object["summaryPrompt"],
                maxBytes: EngramServiceWebAiSettingsValidation.maximumPromptBytes
            ),
            summaryMaxTokens: int(object["summaryMaxTokens"]) ?? (preset == "concise" ? 100 : preset == "detailed" ? 400 : 200),
            summaryTemperature: double(object["summaryTemperature"]) ?? (preset == "concise" ? 0.2 : preset == "detailed" ? 0.4 : 0.3),
            summarySampleFirst: int(object["summarySampleFirst"]) ?? 20,
            summarySampleLast: int(object["summarySampleLast"]) ?? 30,
            summaryTruncateChars: int(object["summaryTruncateChars"]) ?? 500,
            summaryPreset: preset,
            titleProvider: titleProvider,
            titleBaseUrl: titleBase,
            titleBaseURL: titleBase,
            titleModel: text(object["titleModel"]) ?? "gpt-4o-mini",
            embeddingBaseURL: try publishedURL(
                object["embeddingBaseURL"],
                fallback: try publishedURL(object["aiBaseURL"], fallback: "https://api.openai.com/v1")
            ),
            embeddingModel: text(object["embeddingModel"]) ?? "text-embedding-3-small",
            embeddingDimension: int(object["embeddingDimension"]) ?? 1536,
            embeddingIncludeDimensions: bool(object["embeddingIncludeDimensions"]) ?? false,
            aiAudit: EngramServiceWebAiSettingsAudit(
                enabled: bool(audit["enabled"]) ?? true,
                logBodies: bool(audit["logBodies"]) ?? false,
                maxBodySize: int(audit["maxBodySize"]) ?? 10_000
            )
        )
    }

    private static func text(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.utf8.contains(0),
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return trimmed
    }

    private static func publishedURL(_ value: Any?, fallback: String) throws -> String {
        guard let raw = value as? String else { return fallback }
        do {
            let url = try EngramServiceWebAiSettingsValidation.optionalURL(raw)
            return url.isEmpty ? fallback : url
        } catch {
            throw webAiSettingsUnavailable
        }
    }

    private static func publishedMultiline(_ value: Any?, maxBytes: Int) throws -> String {
        guard let raw = value as? String else { return "" }
        do {
            return try EngramServiceWebAiSettingsValidation.multilineText(
                raw, maxBytes: maxBytes, emptyAllowed: true
            )
        } catch {
            throw webAiSettingsUnavailable
        }
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Int64, let exact = Int(exactly: value) { return exact }
        if let value = value as? Double, value.isFinite, let exact = Int(exactly: value) { return exact }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let value = value as? Double, value.isFinite { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? Int64 { return Double(value) }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool? {
        value as? Bool
    }

    private static let webAiSettingsUnavailable = EngramServiceError.serviceUnavailable(
        message: "Web AI settings are unavailable."
    )
}
