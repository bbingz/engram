import Foundation

/// Resolves an `EmbeddingConfig` from env overrides then `~/.engram/settings.json`.
/// Returns nil — semantic search stays disabled (keyword fallback) — when no
/// usable API key is configured. Keeps semantic memory strictly opt-in.
///
/// Legacy plaintext `embeddingApiKey` values migrate once into the Keychain
/// (account `embeddingApiKey`) and are replaced with the `@keychain` marker only
/// after a successful set + read-back + settings rewrite. Interrupted or failed
/// migrations keep recoverable plaintext in the settings file.
public enum EmbeddingSettings {
    public static let keychainMarker = "@keychain"

    /// Public signature preserved for lane 1A call sites.
    public static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        settingsPath: String? = nil
    ) -> EmbeddingConfig? {
        load(
            environment: environment,
            settingsPath: settingsPath,
            secretStore: KeychainSecretStore.shared,
            persistSettings: nil
        )
    }

    /// Testable overload: inject a secret store and optional settings rewriter.
    public static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        settingsPath: String? = nil,
        secretStore: any KeychainSecretStoring,
        persistSettings: (([String: Any], String) throws -> Void)? = nil
    ) -> EmbeddingConfig? {
        let path = settingsPath
            ?? environment["ENGRAM_SETTINGS_PATH"]
            ?? defaultSettingsPath(environment)
        var file = settingsFields(path: path)
        let runtimeSecrets = runtimeSecretValues(environment: environment, settingsPath: path)

        func envPick(_ envKey: String) -> String? {
            if let value = environment[envKey], !value.isEmpty { return value }
            return nil
        }

        let baseURL = envPick("ENGRAM_EMBEDDING_BASE_URL")
            ?? nonEmptyString(file["embeddingBaseURL"])
            ?? nonEmptyString(file["aiBaseURL"])
            ?? "https://api.openai.com/v1"
        let model = envPick("ENGRAM_EMBEDDING_MODEL")
            ?? nonEmptyString(file["embeddingModel"])
            ?? "text-embedding-3-small"
        let configuredDimension = environment["ENGRAM_EMBEDDING_DIM"].flatMap { Int($0) }
            ?? (file["embeddingDimension"] as? Int)
        let dimension = configuredDimension ?? 1536
        let includeDimensions = ["1", "true", "yes"].contains(
            (environment["ENGRAM_EMBEDDING_INCLUDE_DIMENSIONS"] ?? "").lowercased()
        ) || (file["embeddingIncludeDimensions"] as? Bool == true)

        if let apiKey = envPick("ENGRAM_EMBEDDING_API_KEY") {
            return EmbeddingConfig(
                baseURL: baseURL,
                apiKey: apiKey,
                model: model,
                dimension: dimension,
                includeDimensions: includeDimensions,
                dimensionWasExplicit: configuredDimension != nil
            )
        }

        guard let apiKey = resolveAndMaybeMigrateApiKey(
            settings: &file,
            settingsPath: path,
            runtimeSecrets: runtimeSecrets,
            secretStore: secretStore,
            allowSecretStoreRead: environment["ENGRAM_RUNTIME_AI_SECRETS_PATH"] == nil,
            persistSettings: persistSettings
        ) else {
            return nil
        }

        return EmbeddingConfig(
            baseURL: baseURL,
            apiKey: apiKey,
            model: model,
            dimension: dimension,
            includeDimensions: includeDimensions,
            dimensionWasExplicit: configuredDimension != nil
        )
    }

    /// Resolves embedding API key from settings, migrating plaintext once.
    private static func resolveAndMaybeMigrateApiKey(
        settings: inout [String: Any],
        settingsPath: String,
        runtimeSecrets: [String: String],
        secretStore: any KeychainSecretStoring,
        allowSecretStoreRead: Bool,
        persistSettings: (([String: Any], String) throws -> Void)?
    ) -> String? {
        let embeddingRaw = nonEmptyString(settings["embeddingApiKey"])
        let aiRaw = nonEmptyString(settings["aiApiKey"])

        if let embeddingRaw {
            if embeddingRaw == keychainMarker {
                return nonEmptyString(runtimeSecrets[KeychainSecretStore.Account.embeddingApiKey])
                    ?? (allowSecretStoreRead
                        ? nonEmptyString(secretStore.get(KeychainSecretStore.Account.embeddingApiKey))
                        : nil)
            }
            return migratePlaintextIfPossible(
                plaintext: embeddingRaw,
                sourceKey: "embeddingApiKey",
                settings: &settings,
                settingsPath: settingsPath,
                secretStore: secretStore,
                persistSettings: persistSettings
            )
        }

        if let aiRaw {
            if aiRaw == keychainMarker {
                // Prefer embedding-account material; fall back to the shared aiApiKey account
                // used by the app title/AI settings facade.
                if let fromEmbedding = nonEmptyString(runtimeSecrets[KeychainSecretStore.Account.embeddingApiKey])
                    ?? (allowSecretStoreRead
                        ? nonEmptyString(secretStore.get(KeychainSecretStore.Account.embeddingApiKey))
                        : nil) {
                    return fromEmbedding
                }
                return nonEmptyString(runtimeSecrets[KeychainSecretStore.Account.aiApiKey])
                    ?? (allowSecretStoreRead
                        ? nonEmptyString(secretStore.get(KeychainSecretStore.Account.aiApiKey))
                        : nil)
            }
            // The app owns migration of the shared aiApiKey account. Do not create a
            // second marker from the embedding reader's snapshot.
            return nonEmptyString(runtimeSecrets[KeychainSecretStore.Account.embeddingApiKey])
                ?? (allowSecretStoreRead
                    ? nonEmptyString(secretStore.get(KeychainSecretStore.Account.embeddingApiKey))
                    : nil)
                ?? nonEmptyString(runtimeSecrets[KeychainSecretStore.Account.aiApiKey])
                ?? (allowSecretStoreRead
                    ? nonEmptyString(secretStore.get(KeychainSecretStore.Account.aiApiKey))
                    : nil)
                ?? aiRaw
        }

        // Settings may be absent or rejected as an unsafe/unreadable node while
        // the launcher bridge or Keychain still holds the live credential.
        // Resolve accounts directly without materializing or repairing the file.
        return nonEmptyString(runtimeSecrets[KeychainSecretStore.Account.embeddingApiKey])
            ?? (allowSecretStoreRead
                ? nonEmptyString(secretStore.get(KeychainSecretStore.Account.embeddingApiKey))
                : nil)
            ?? nonEmptyString(runtimeSecrets[KeychainSecretStore.Account.aiApiKey])
            ?? (allowSecretStoreRead
                ? nonEmptyString(secretStore.get(KeychainSecretStore.Account.aiApiKey))
                : nil)
    }

    private static func migratePlaintextIfPossible(
        plaintext: String,
        sourceKey: String,
        settings: inout [String: Any],
        settingsPath: String,
        secretStore: any KeychainSecretStoring,
        persistSettings: (([String: Any], String) throws -> Void)?
    ) -> String {
        let account = KeychainSecretStore.Account.embeddingApiKey

        // Already present and matching: just ensure marker, then return.
        if secretStore.get(account) == plaintext {
            applyMarkerIfNeeded(
                sourceKey: sourceKey,
                expectedPlaintext: plaintext,
                settings: &settings,
                settingsPath: settingsPath,
                persistSettings: persistSettings
            )
            return plaintext
        }

        // Persist to Keychain; only strip plaintext after set + verify + rewrite.
        guard secretStore.set(account, value: plaintext) else {
            return plaintext
        }
        guard secretStore.get(account) == plaintext else {
            return plaintext
        }

        applyMarkerIfNeeded(
            sourceKey: sourceKey,
            expectedPlaintext: plaintext,
            settings: &settings,
            settingsPath: settingsPath,
            persistSettings: persistSettings
        )
        return plaintext
    }

    private static func applyMarkerIfNeeded(
        sourceKey: String,
        expectedPlaintext: String,
        settings: inout [String: Any],
        settingsPath: String,
        persistSettings: (([String: Any], String) throws -> Void)?
    ) {
        let current = settings[sourceKey] as? String
        if current == keychainMarker { return }
        guard current == expectedPlaintext else { return }

        do {
            if let persistSettings {
                var next = settings
                next[sourceKey] = keychainMarker
                try persistSettings(next, settingsPath)
                settings = next
            } else {
                guard let next = try defaultPersistMarker(
                    sourceKey: sourceKey,
                    expectedPlaintext: expectedPlaintext,
                    path: settingsPath
                ) else { return }
                settings = next
            }
        } catch {
            // Interrupted/failed rewrite: keep recoverable plaintext in the file.
        }
    }

    private static func defaultPersistMarker(
        sourceKey: String,
        expectedPlaintext: String,
        path: String
    ) throws -> [String: Any]? {
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return try EngramSettingsFileLock.withExclusiveLock(for: url) {
            var fresh = settingsFields(path: path)
            guard nonEmptyString(fresh[sourceKey]) == expectedPlaintext else { return nil }
            fresh[sourceKey] = keychainMarker
            try defaultPersistSettings(fresh, path: path)
            return fresh
        }
    }

    private static func defaultPersistSettings(_ object: [String: Any], path: String) throws {
        let url = URL(fileURLWithPath: path)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try SecureRegularFile.writeAtomically(
            data,
            toPath: path,
            maximumExistingBytes: 1024 * 1024
        )
    }

    private static func runtimeSecretValues(
        environment: [String: String],
        settingsPath: String
    ) -> [String: String] {
        let path = environment["ENGRAM_RUNTIME_AI_SECRETS_PATH"]
            ?? URL(fileURLWithPath: settingsPath)
                .deletingLastPathComponent()
                .appendingPathComponent("run", isDirectory: true)
                .appendingPathComponent("ai-secrets.json")
                .path
        guard let data = SecureRegularFile.read(atPath: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object.reduce(into: [:]) { result, pair in
            guard let value = nonEmptyString(pair.value) else { return }
            result[pair.key] = value
        }
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func settingsFields(path: String) -> [String: Any] {
        guard let data = SecureRegularFile.read(
            atPath: path,
            maximumBytes: 1024 * 1024,
            repairPermissions: true
        ),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    private static func defaultSettingsPath(_ environment: [String: String]) -> String {
        let processEnvironment = ProcessInfo.processInfo.environment
        let isTestProcess = environment["XCTestConfigurationFilePath"] != nil
            || processEnvironment["XCTestConfigurationFilePath"] != nil
        if isTestProcess {
            // docs/invariants.md #6: in-process tests never fall back to the
            // passwd-backed production home when no settings path is supplied.
            if let fixedHome = environment["CFFIXED_USER_HOME"], !fixedHome.isEmpty {
                return fixedHome + "/.engram/settings.json"
            }
            return FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "engram-tests-\(ProcessInfo.processInfo.processIdentifier)",
                    isDirectory: true
                )
                .appendingPathComponent(".engram/settings.json")
                .path
        }
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/.engram/settings.json"
    }
}
