import EngramCoreRead
import Foundation
import XCTest

/// In-memory secret store for migration / load tests (M13).
private final class InMemorySecretStore: KeychainSecretStoring, @unchecked Sendable {
    private var values: [String: String] = [:]
    var setShouldFail = false
    var setCallCount = 0
    var getCallCount = 0
    var deleteCallCount = 0
    var getHook: ((Int) -> Void)?

    func get(_ account: String) -> String? {
        getCallCount += 1
        getHook?(getCallCount)
        return values[account]
    }

    @discardableResult
    func set(_ account: String, value: String) -> Bool {
        setCallCount += 1
        if setShouldFail { return false }
        values[account] = value
        return true
    }

    func delete(_ account: String) {
        deleteCallCount += 1
        values.removeValue(forKey: account)
    }
}

final class EmbeddingSettingsKeychainTests: XCTestCase {
    private var tempDir: URL!
    private var settingsPath: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-embed-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        settingsPath = tempDir.appendingPathComponent("settings.json").path
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        settingsPath = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func writeSettings(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
    }

    private func readSettings() throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func load(
        store: InMemorySecretStore,
        environment: [String: String] = [:],
        persistShouldFail: Bool = false
    ) -> EmbeddingConfig? {
        EmbeddingSettings.load(
            environment: environment,
            settingsPath: settingsPath,
            secretStore: store,
            persistSettings: { object, path in
                if persistShouldFail {
                    throw NSError(domain: "test", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "simulated persist failure",
                    ])
                }
                let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
        )
    }

    // MARK: - M13: plaintext migration

    func testPlaintextEmbeddingApiKeyMigratesOnceToKeychain() throws {
        let secret = "sk-live-plaintext-embedding-key"
        try writeSettings([
            "embeddingApiKey": secret,
            "embeddingModel": "text-embedding-3-small",
            "embeddingDimension": 1536,
        ])
        let store = InMemorySecretStore()

        let config = load(store: store)

        XCTAssertEqual(config?.apiKey, secret)
        XCTAssertEqual(store.get(KeychainSecretStore.Account.embeddingApiKey), secret)
        let after = try readSettings()
        XCTAssertEqual(after["embeddingApiKey"] as? String, "@keychain")
        XCTAssertFalse((after["embeddingApiKey"] as? String) == secret)
        XCTAssertEqual(store.setCallCount, 1)
    }

    func testAtKeychainMarkerLoadsFromSecretStore() throws {
        let secret = "sk-from-keychain"
        try writeSettings([
            "embeddingApiKey": "@keychain",
            "embeddingBaseURL": "https://embeddings.example/v1",
            "embeddingModel": "custom-model",
            "embeddingDimension": 768,
        ])
        let store = InMemorySecretStore()
        store.set(KeychainSecretStore.Account.embeddingApiKey, value: secret)
        let initialSetCallCount = store.setCallCount

        let config = load(store: store)

        XCTAssertEqual(config?.apiKey, secret)
        XCTAssertEqual(config?.baseURL, "https://embeddings.example/v1")
        XCTAssertEqual(config?.model, "custom-model")
        XCTAssertEqual(config?.dimension, 768)
        XCTAssertEqual(
            store.setCallCount,
            initialSetCallCount,
            "already-migrated marker must not re-write Keychain"
        )
    }

    func testAtKeychainMarkerLoadsFromRuntimeSecretBridge() throws {
        let secret = "sk-runtime-bridge"
        try writeSettings(["embeddingApiKey": "@keychain"])
        let bridgePath = tempDir.appendingPathComponent("ai-secrets.json")
        try JSONSerialization.data(withJSONObject: ["embeddingApiKey": secret])
            .write(to: bridgePath)
        let store = InMemorySecretStore()

        let config = load(
            store: store,
            environment: ["ENGRAM_RUNTIME_AI_SECRETS_PATH": bridgePath.path]
        )

        XCTAssertEqual(config?.apiKey, secret)
        XCTAssertEqual(store.getCallCount, 0, "runtime bridge must resolve before direct Keychain access")
    }

    func testAtKeychainMarkerLoadsFromDefaultRuntimeSecretBridgeForMCP() throws {
        let secret = "sk-default-runtime-bridge"
        try writeSettings(["embeddingApiKey": "@keychain"])
        let runDirectory = tempDir.appendingPathComponent("run", isDirectory: true)
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        let bridgePath = runDirectory.appendingPathComponent("ai-secrets.json")
        try JSONSerialization.data(withJSONObject: ["embeddingApiKey": secret])
            .write(to: bridgePath)
        let store = InMemorySecretStore()

        let config = load(store: store)

        XCTAssertEqual(config?.apiKey, secret)
        XCTAssertEqual(store.getCallCount, 0)
    }

    func testMissingKeychainEntryReturnsNilConfig() throws {
        try writeSettings([
            "embeddingApiKey": "@keychain",
            "embeddingModel": "text-embedding-3-small",
        ])
        let store = InMemorySecretStore()

        let config = load(store: store)

        XCTAssertNil(config, "missing Keychain secret must keep semantic search disabled")
    }

    func testFailedKeychainSaveRetainsRecoverablePlaintext() throws {
        let secret = "sk-must-remain-in-file"
        try writeSettings([
            "embeddingApiKey": secret,
        ])
        let store = InMemorySecretStore()
        store.setShouldFail = true

        let config = load(store: store)

        XCTAssertEqual(config?.apiKey, secret, "load still resolves plaintext while migration is blocked")
        let after = try readSettings()
        XCTAssertEqual(after["embeddingApiKey"] as? String, secret, "failed set must not strip plaintext")
        XCTAssertNil(store.get(KeychainSecretStore.Account.embeddingApiKey))
    }

    func testInterruptedSettingsPersistRetainsRecoverablePlaintext() throws {
        let secret = "sk-interrupted-migration"
        try writeSettings([
            "embeddingApiKey": secret,
        ])
        let store = InMemorySecretStore()

        let config = load(store: store, persistShouldFail: true)

        XCTAssertEqual(config?.apiKey, secret)
        // Keychain may hold the secret after a successful set, but the file must keep
        // recoverable plaintext until settings rewrite completes.
        let after = try readSettings()
        XCTAssertEqual(after["embeddingApiKey"] as? String, secret)
        XCTAssertEqual(store.get(KeychainSecretStore.Account.embeddingApiKey), secret)
    }

    func testSuccessfulMigrationVerifiesReadBackBeforeRemovingPlaintext() throws {
        let secret = "sk-verify-readback"
        try writeSettings([
            "embeddingApiKey": secret,
        ])

        // A store that "accepts" set but fails verification (get returns different value).
        let flaky = FlakyVerifySecretStore(expected: secret)
        let config = EmbeddingSettings.load(
            environment: [:],
            settingsPath: settingsPath,
            secretStore: flaky,
            persistSettings: { object, path in
                let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
        )

        XCTAssertEqual(config?.apiKey, secret)
        let after = try readSettings()
        XCTAssertEqual(
            after["embeddingApiKey"] as? String,
            secret,
            "plaintext must remain when read-back verification fails"
        )
        XCTAssertEqual(flaky.setCallCount, 1, "set may succeed, but failed verify must block marker write")
    }

    func testMigrationIsIdempotentOnReload() throws {
        let secret = "sk-idempotent"
        try writeSettings([
            "embeddingApiKey": secret,
        ])
        let store = InMemorySecretStore()

        XCTAssertEqual(load(store: store)?.apiKey, secret)
        XCTAssertEqual(store.setCallCount, 1)

        let second = load(store: store)
        XCTAssertEqual(second?.apiKey, secret)
        XCTAssertEqual(store.setCallCount, 1, "second load must not re-set Keychain for already-migrated key")
        let after = try readSettings()
        XCTAssertEqual(after["embeddingApiKey"] as? String, "@keychain")
    }

    func testAiApiKeyFallbackRemainsOwnedByAppMigrationWhenEmbeddingKeyAbsent() throws {
        let secret = "sk-ai-fallback"
        try writeSettings([
            "aiApiKey": secret,
        ])
        let store = InMemorySecretStore()

        let config = load(store: store)

        XCTAssertEqual(config?.apiKey, secret)
        XCTAssertNil(store.get(KeychainSecretStore.Account.embeddingApiKey))
        let after = try readSettings()
        XCTAssertNil(after["embeddingApiKey"])
        XCTAssertEqual(after["aiApiKey"] as? String, secret)
    }

    func testDefaultMigrationPreservesConcurrentUnrelatedSettingsChange() throws {
        let secret = "sk-concurrent-migration"
        try writeSettings([
            "embeddingApiKey": secret,
            "disabledSources": ["claude-code"],
        ])
        let store = InMemorySecretStore()
        store.getHook = { [settingsPath] callCount in
            guard callCount == 2, let settingsPath else { return }
            let url = URL(fileURLWithPath: settingsPath)
            guard let data = try? Data(contentsOf: url),
                  var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            object["concurrentSetting"] = "preserve-me"
            if let updated = try? JSONSerialization.data(withJSONObject: object) {
                try? updated.write(to: url, options: .atomic)
            }
        }

        let config = EmbeddingSettings.load(
            environment: [:],
            settingsPath: settingsPath,
            secretStore: store,
            persistSettings: nil
        )

        XCTAssertEqual(config?.apiKey, secret)
        let after = try readSettings()
        XCTAssertEqual(after["embeddingApiKey"] as? String, "@keychain")
        XCTAssertEqual(after["concurrentSetting"] as? String, "preserve-me")
        XCTAssertEqual(after["disabledSources"] as? [String], ["claude-code"])
    }

    func testEnvironmentApiKeyBypassesKeychainAndDoesNotMigrate() throws {
        try writeSettings([
            "embeddingApiKey": "sk-file-key",
        ])
        let store = InMemorySecretStore()

        let config = load(
            store: store,
            environment: ["ENGRAM_EMBEDDING_API_KEY": "sk-env-key"]
        )

        XCTAssertEqual(config?.apiKey, "sk-env-key")
        XCTAssertEqual(store.setCallCount, 0)
        let after = try readSettings()
        XCTAssertEqual(after["embeddingApiKey"] as? String, "sk-file-key")
    }

    func testPublicLoadSignatureStillResolvesEnvironmentOverrideWithoutInjection() {
        // Preserves lane-1A call site without touching the user's real Keychain.
        let config = EmbeddingSettings.load(
            environment: ["ENGRAM_EMBEDDING_API_KEY": "sk-compat-signature"],
            settingsPath: settingsPath
        )

        XCTAssertEqual(config?.apiKey, "sk-compat-signature")
    }
}

/// Accepts set() but never returns the stored value, simulating a failed read-back.
private final class FlakyVerifySecretStore: KeychainSecretStoring, @unchecked Sendable {
    let expected: String
    private var written: String?
    private(set) var setCallCount = 0

    init(expected: String) {
        self.expected = expected
    }

    func get(_ account: String) -> String? {
        // Always return a different value so verification fails.
        if written != nil { return "wrong-readback-value" }
        return nil
    }

    @discardableResult
    func set(_ account: String, value: String) -> Bool {
        setCallCount += 1
        written = value
        return true
    }

    func delete(_ account: String) {
        written = nil
    }
}
