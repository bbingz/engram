import Foundation

/// Resolves an `EmbeddingConfig` from env overrides then `~/.engram/settings.json`.
/// Returns nil — semantic search stays disabled (keyword fallback) — when no
/// usable API key is configured. Keeps semantic memory strictly opt-in.
public enum EmbeddingSettings {
    public static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        settingsPath: String? = nil
    ) -> EmbeddingConfig? {
        let file = settingsFields(
            path: settingsPath
                ?? environment["ENGRAM_SETTINGS_PATH"]
                ?? defaultSettingsPath(environment)
        )

        func pick(_ envKey: String, _ fileKeys: [String]) -> String? {
            if let value = environment[envKey], !value.isEmpty { return value }
            for key in fileKeys {
                if let value = file[key] as? String, !value.isEmpty, value != "@keychain" {
                    return value
                }
            }
            return nil
        }

        guard let apiKey = pick("ENGRAM_EMBEDDING_API_KEY", ["embeddingApiKey", "aiApiKey"]) else {
            return nil
        }
        let baseURL = pick("ENGRAM_EMBEDDING_BASE_URL", ["embeddingBaseURL", "aiBaseURL"])
            ?? "https://api.openai.com/v1"
        let model = pick("ENGRAM_EMBEDDING_MODEL", ["embeddingModel"]) ?? "text-embedding-3-small"
        let dimension = environment["ENGRAM_EMBEDDING_DIM"].flatMap { Int($0) }
            ?? (file["embeddingDimension"] as? Int)
            ?? 1536
        return EmbeddingConfig(baseURL: baseURL, apiKey: apiKey, model: model, dimension: dimension)
    }

    private static func settingsFields(path: String) -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    private static func defaultSettingsPath(_ environment: [String: String]) -> String {
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/.engram/settings.json"
    }
}
