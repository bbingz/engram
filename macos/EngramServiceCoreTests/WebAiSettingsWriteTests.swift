import Darwin
import Foundation
import EngramCoreWrite
import LocalAuthentication
import Security
import XCTest
@testable import EngramServiceCore

final class WebAiSettingsWriteTests: XCTestCase {
    private static let unavailable = EngramServiceError.serviceUnavailable(
        message: "Web AI settings are unavailable."
    )
    private var root: URL!
    private var settingsURL: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("eg-d14-ai-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        settingsURL = root.appendingPathComponent("settings.json")
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testMissingFilePublishesNativeDefaults() throws {
        let page = try EngramServiceCommandHandler.webAiSettings(settingsURL: settingsURL)
        XCTAssertEqual(page.settings.aiProtocol, "openai")
        XCTAssertEqual(page.settings.aiBaseURL, "https://api.openai.com")
        XCTAssertEqual(page.settings.aiModel, "gpt-4o-mini")
        XCTAssertEqual(page.settings.summaryLanguage, "中文")
        XCTAssertEqual(page.settings.summaryPrompt, "")
        XCTAssertEqual(page.settings.summaryStyle, "")
        XCTAssertEqual(page.settings.summaryMaxTokens, 200)
        XCTAssertEqual(page.settings.titleProvider, "ollama")
        XCTAssertEqual(page.settings.titleBaseUrl, "http://localhost:11434")
        XCTAssertEqual(page.settings.titleBaseURL, "http://localhost:11434")
        XCTAssertEqual(page.settings.embeddingBaseURL, "https://api.openai.com/v1")
        XCTAssertEqual(page.settings.embeddingModel, "text-embedding-3-small")
        XCTAssertEqual(page.settings.embeddingDimension, 1536)
        XCTAssertFalse(page.settings.embeddingIncludeDimensions)
        XCTAssertEqual(page.settings.aiAudit.maxBodySize, 10_000)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(page), as: UTF8.self).contains("aiApiKey"))
    }

    func testSharedProviderFallsBackToStoredAiBaseURLForEmbedding() throws {
        try writeSettings([
            "aiBaseURL": "https://shared-provider.example/v1",
            "aiModel": "shared-model",
            "customSetting": "preserve-me",
            "aiApiKey": "fixture-only-not-a-real-key",
        ])
        let page = try EngramServiceCommandHandler.webAiSettings(settingsURL: settingsURL)
        XCTAssertEqual(page.settings.aiBaseURL, "https://shared-provider.example/v1")
        XCTAssertEqual(page.settings.embeddingBaseURL, "https://shared-provider.example/v1")
        XCTAssertEqual(page.settings.aiModel, "shared-model")
        let encoded = String(decoding: try JSONEncoder().encode(page), as: UTF8.self)
        XCTAssertFalse(encoded.contains("aiApiKey"))
        XCTAssertFalse(encoded.contains("fixture-only-not-a-real-key"))
        let saved = try currentObject()
        XCTAssertEqual(saved["customSetting"] as? String, "preserve-me")
        XCTAssertEqual(saved["aiApiKey"] as? String, "fixture-only-not-a-real-key")
    }

    // HQ settings.json carries the legacy Node `aiProtocol: "disabled"`; the Web
    // form only knew `openai`, so the deployed Settings page threw
    // "invalid AI settings" and showed "Settings unavailable". The published
    // value must stay a form choice and the editor must be able to toggle it.
    func testDisabledProtocolPublishesAndPatchesAsChoice_repro() throws {
        try writeSettings(["aiProtocol": "disabled", "customSetting": "preserve-me"])
        let page = try EngramServiceCommandHandler.webAiSettings(settingsURL: settingsURL)
        XCTAssertEqual(page.settings.aiProtocol, "disabled")
        XCTAssertTrue(EngramServiceWebAiSettingsValidation.aiProtocols.contains(page.settings.aiProtocol))

        try writeSettings(["aiProtocol": "anthropic"])
        XCTAssertEqual(
            try EngramServiceCommandHandler.webAiSettings(settingsURL: settingsURL).settings.aiProtocol,
            "disabled",
            "any non-openai stored vendor means summaries are off, matching summaryConfig"
        )

        try writeSettings(["aiProtocol": "disabled", "customSetting": "preserve-me"])
        let enabled = try EngramServiceCommandHandler.webPatchAiSettings(
            EngramServiceWebPatchAiSettingsRequest(aiProtocol: "openai"), settingsURL: settingsURL
        )
        XCTAssertEqual(enabled.settings.aiProtocol, "openai")
        XCTAssertEqual(try currentObject()["aiProtocol"] as? String, "openai")
        let disabled = try EngramServiceCommandHandler.webPatchAiSettings(
            EngramServiceWebPatchAiSettingsRequest(aiProtocol: "disabled"), settingsURL: settingsURL
        )
        XCTAssertEqual(disabled.settings.aiProtocol, "disabled")
        XCTAssertEqual(try currentObject()["aiProtocol"] as? String, "disabled")
        XCTAssertEqual(try currentObject()["customSetting"] as? String, "preserve-me")
    }

    func testExplicitEmbeddingBaseURLWinsOverAiBaseURL() throws {
        try writeSettings([
            "aiBaseURL": "https://shared-provider.example/v1",
            "embeddingBaseURL": "https://embed-only.example/v1",
        ])
        let page = try EngramServiceCommandHandler.webAiSettings(settingsURL: settingsURL)
        XCTAssertEqual(page.settings.aiBaseURL, "https://shared-provider.example/v1")
        XCTAssertEqual(page.settings.embeddingBaseURL, "https://embed-only.example/v1")
    }

    func testMultilinePromptAndStyleSurviveSaveAndRead() throws {
        try writeSettings(["customSetting": "preserve-me"])
        let prompt = "Decisions\nNext steps\r\n\tKeep going"
        let style = "concise\tdraft"
        let page = try EngramServiceCommandHandler.webPatchAiSettings(
            EngramServiceWebPatchAiSettingsRequest(summaryStyle: style, summaryPrompt: prompt),
            settingsURL: settingsURL
        )
        XCTAssertEqual(page.settings.summaryPrompt, prompt)
        XCTAssertEqual(page.settings.summaryStyle, style)
        let reread = try EngramServiceCommandHandler.webAiSettings(settingsURL: settingsURL)
        XCTAssertEqual(reread.settings.summaryPrompt, prompt)
        XCTAssertEqual(reread.settings.summaryStyle, style)
        let saved = try currentObject()
        XCTAssertEqual(saved["summaryPrompt"] as? String, prompt)
        XCTAssertEqual(saved["summaryStyle"] as? String, style)
        XCTAssertEqual(saved["customSetting"] as? String, "preserve-me")
        XCTAssertThrowsError(try EngramServiceWebPatchAiSettingsRequest(summaryPrompt: "line\0hidden"))
        XCTAssertThrowsError(try EngramServiceWebPatchAiSettingsRequest(summaryPrompt: "line\u{001B}hidden"))
        XCTAssertThrowsError(try EngramServiceWebPatchAiSettingsRequest(summaryStyle: "line\u{0007}"))
        XCTAssertThrowsError(try EngramServiceWebPatchAiSettingsRequest(aiModel: "gpt\n4"))
    }

    func testInvalidStoredURLsAreUnavailableAndNeverEchoed() throws {
        let poisoned = "https://user:token@evil.example/v1?api_key=sk-secret"
        try writeSettings(["aiBaseURL": poisoned, "customSetting": "preserve-me"])
        XCTAssertThrowsError(try EngramServiceCommandHandler.webAiSettings(settingsURL: settingsURL)) { error in
            XCTAssertEqual(error as? EngramServiceError, Self.unavailable)
            let rendered = String(describing: error)
            XCTAssertFalse(rendered.contains("user"))
            XCTAssertFalse(rendered.contains("token"))
            XCTAssertFalse(rendered.contains("sk-secret"))
            XCTAssertFalse(rendered.contains("evil.example"))
        }
        XCTAssertEqual(try currentObject()["aiBaseURL"] as? String, poisoned)
        XCTAssertEqual(try currentObject()["customSetting"] as? String, "preserve-me")
        try writeSettings(["titleBaseURL": "https://api.openai.com/v1#frag"])
        XCTAssertThrowsError(try EngramServiceCommandHandler.webAiSettings(settingsURL: settingsURL)) {
            XCTAssertEqual($0 as? EngramServiceError, Self.unavailable)
        }
        try writeSettings(["embeddingBaseURL": "https://api.openai.com/v1?api_key=sk-secret"])
        XCTAssertThrowsError(try EngramServiceCommandHandler.webAiSettings(settingsURL: settingsURL)) { error in
            XCTAssertEqual(error as? EngramServiceError, Self.unavailable)
            XCTAssertFalse(String(describing: error).contains("sk-secret"))
        }
    }

    func testPatchPreservesUnrelatedKeysAndRepairsPermissions() throws {
        try writeSettings([
            "customSetting": "preserve-me",
            "captureIngest": ["enabled": true, "serverID": "hq"],
            "aiModel": "old-model",
        ], mode: 0o644)
        let page = try EngramServiceCommandHandler.webPatchAiSettings(
            try EngramServiceWebPatchAiSettingsRequest(
                aiModel: "fixture-summary-model",
                summaryMaxTokens: 800,
                aiAudit: EngramServiceWebAiSettingsAuditPatch(enabled: true, logBodies: false, maxBodySize: 12_000)
            ),
            settingsURL: settingsURL
        )
        XCTAssertEqual(page.settings.aiModel, "fixture-summary-model")
        XCTAssertEqual(page.settings.summaryMaxTokens, 800)
        XCTAssertEqual(page.settings.aiAudit.maxBodySize, 12_000)
        let saved = try currentObject()
        XCTAssertEqual(saved["customSetting"] as? String, "preserve-me")
        XCTAssertNotNil(saved["captureIngest"])
        XCTAssertNil(saved["aiApiKey"])
        var info = stat()
        XCTAssertEqual(lstat(settingsURL.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
    }

    func testUnknownKeysSecretsAndBoundsAreRejectedWithoutWriting() throws {
        try writeSettings(["aiModel": "keep-me"])
        let original = try Data(contentsOf: settingsURL)
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                EngramServiceWebPatchAiSettingsRequest.self,
                from: Data(#"{"aiApiKey":"fixture-only-not-a-real-key"}"#.utf8)
            )
        )
        XCTAssertThrowsError(try EngramServiceWebPatchAiSettingsRequest(summaryMaxTokens: 0))
        XCTAssertThrowsError(try EngramServiceWebPatchAiSettingsRequest(summaryTemperature: 2.1))
        XCTAssertThrowsError(try EngramServiceWebPatchAiSettingsRequest(aiProtocol: "anthropic"))
        XCTAssertThrowsError(
            try EngramServiceWebPatchAiSettingsRequest(aiBaseURL: "https://user:token@evil.example")
        )
        XCTAssertEqual(try Data(contentsOf: settingsURL), original)
    }

    func testUnsafeSettingsFileIsUnavailable() throws {
        let target = root.appendingPathComponent("outside.json")
        try writeSettings(["aiModel": "keep-me"], url: target)
        try FileManager.default.createSymbolicLink(at: settingsURL, withDestinationURL: target)
        XCTAssertThrowsError(try EngramServiceCommandHandler.webAiSettings(settingsURL: settingsURL)) {
            XCTAssertEqual($0 as? EngramServiceError, Self.unavailable)
        }
        XCTAssertEqual(try currentObject(url: target)["aiModel"] as? String, "keep-me")
        XCTAssertThrowsError(
            try EngramServiceCommandHandler.webPatchAiSettings(
                EngramServiceWebPatchAiSettingsRequest(aiModel: "changed"),
                settingsURL: settingsURL
            )
        ) {
            XCTAssertEqual($0 as? EngramServiceError, Self.unavailable)
        }
        XCTAssertEqual(try currentObject(url: target)["aiModel"] as? String, "keep-me")
    }

    func testEndpointChangeCannotRedirectStoredCredential_repro() throws {
        try writeSettings([
            "aiBaseURL": "https://trusted.example/v1",
            "aiApiKey": "fixture-only-key",
            "aiModel": "keep-me",
        ])
        let original = try Data(contentsOf: settingsURL)
        XCTAssertThrowsError(try EngramServiceCommandHandler.webPatchAiSettings(
            EngramServiceWebPatchAiSettingsRequest(
                aiBaseURL: "https://other.example/v1", aiModel: "must-not-save"
            ), settingsURL: settingsURL
        )) { error in
            guard case .commandFailed(let name, _, let retry, _) = error as? EngramServiceError else {
                return XCTFail("Expected a structured endpoint rejection")
            }
            XCTAssertEqual(name, "WebAiEndpointRequiresLocalUpdate")
            XCTAssertEqual(retry, "never")
            XCTAssertFalse(String(describing: error).contains("fixture-only-key"))
        }
        XCTAssertEqual(try Data(contentsOf: settingsURL), original, "Reject the entire patch atomically")
        let config = EngramServiceCommandHandler.ServiceAISettings.read(
            settingsPath: settingsURL, environment: [:], keychainReader: { _ in nil }
        )
        XCTAssertEqual(config.summaryConfig?.baseURL, "https://trusted.example/v1")
        XCTAssertEqual(config.summaryConfig?.apiKey, "fixture-only-key")
    }

    func testProtectsSharedFallbackLegacyDefaultsAndDormantCredentials() throws {
        let cases: [([String: Any], EngramServiceWebPatchAiSettingsRequest)] = try [
            (["aiProtocol": "disabled", "aiApiKey": "@keychain"],
             .init(aiBaseURL: "https://other.example/v1")),
            (["embeddingApiKey": "fixture-embedding"],
             .init(aiBaseURL: "https://other.example/v1")),
            (["aiApiKey": "fixture-shared"],
             .init(embeddingBaseURL: "https://other.example/v1")),
            (["aiApiKey": "fixture-shared", "embeddingBaseURL": "https://trusted.example/v1"],
             .init(embeddingBaseURL: "")),
            (["titleApiKey": "@keychain", "titleBaseURL": "https://legacy.example/v1"],
             .init(titleBaseUrl: "https://other.example/v1")),
            (["titleApiKey": "fixture-title", "titleProvider": "ollama"],
             .init(titleBaseUrl: "https://other.example/v1")),
            (["titleApiKey": "fixture-title", "titleProvider": "ollama",
              "titleBaseUrl": "https://same.example/v1"], .init(titleProvider: "custom")),
            (["titleApiKey": "fixture-title", "titleProvider": "custom"], .init(titleProvider: "ollama")),
            (["aiApiKey": "@keychain", "aiBaseURL": "https://trusted.example/old"],
             .init(aiBaseURL: "https://trusted.example/new")),
        ]
        for (object, patch) in cases {
            try writeSettings(object)
            let original = try Data(contentsOf: settingsURL)
            XCTAssertThrowsError(try isolatedPatch(patch))
            XCTAssertEqual(try Data(contentsOf: settingsURL), original)
        }
        // A successful disable is not permission to retarget the dormant key.
        try writeSettings(["aiApiKey": "fixture-key"])
        _ = try isolatedPatch(.init(aiProtocol: "disabled"))
        XCTAssertThrowsError(try isolatedPatch(.init(aiBaseURL: "https://other.example")))
        XCTAssertEqual(try currentObject()["aiProtocol"] as? String, "disabled")
    }

    func testAllowsCredentialFreeAndUnrelatedEditsWithoutSecretReads() throws {
        try writeSettings([:])
        let changed = try isolatedPatch(.init(
            aiBaseURL: "https://new.example/v1", titleProvider: "custom",
            titleBaseUrl: "https://title.example/v1", embeddingBaseURL: "https://embed.example/v1"
        ))
        XCTAssertEqual(changed.settings.aiBaseURL, "https://new.example/v1")
        try writeSettings([
            "aiApiKey": "@keychain", "titleApiKey": "@keychain", "embeddingApiKey": "@keychain",
            "titleBaseURL": "http://localhost:11434",
        ])
        let edited = try EngramServiceCommandHandler.webPatchAiSettings(
            .init(aiBaseURL: "https://api.openai.com", aiModel: "new-model",
                  titleBaseUrl: "http://localhost:11434", embeddingBaseURL: "https://api.openai.com/v1"),
            settingsURL: settingsURL, environment: [:], keychainMayContain: { _ in
                XCTFail("Unchanged effective endpoints must not probe credentials")
                return true
            }
        )
        XCTAssertEqual(edited.settings.aiModel, "new-model")
        XCTAssertNil(try currentObject()["titleBaseURL"])
        // An independent embedding key must not lock a credential-free summary endpoint.
        try writeSettings(["embeddingApiKey": "@keychain", "embeddingBaseURL": "https://embed.example/v1"])
        XCTAssertNoThrow(try isolatedPatch(.init(aiBaseURL: "https://summary.example/v1")))
    }

    func testProtectsEnvironmentSidecarAndMarkerlessKeychainCredentials() throws {
        let patch = try EngramServiceWebPatchAiSettingsRequest(embeddingBaseURL: "https://other.example/v1")
        try writeSettings([:])
        XCTAssertThrowsError(try isolatedPatch(patch, environment: [
            "ENGRAM_EMBEDDING_API_KEY": "fixture-env",
            "ENGRAM_EMBEDDING_BASE_URL": "https://env.example/v1",
        ]))
        for account in ["aiApiKey", "embeddingApiKey", "titleApiKey"] {
            let request = try EngramServiceWebPatchAiSettingsRequest(
                aiBaseURL: "https://other.example/v1", titleBaseUrl: "https://other.example/v1",
                embeddingBaseURL: "https://other.example/v1"
            )
            XCTAssertThrowsError(try EngramServiceCommandHandler.webPatchAiSettings(
                request, settingsURL: settingsURL, environment: [:], keychainMayContain: { $0 == account }
            ))
            for explicit in [false, true] {
                let path = root.appendingPathComponent(explicit ? "custom-secrets.json" : "run/ai-secrets.json")
                try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                try writeSettings([account: "fixture-sidecar"], url: path)
                let environment = explicit ? ["ENGRAM_RUNTIME_AI_SECRETS_PATH": path.path] : [:]
                XCTAssertThrowsError(try isolatedPatch(request, environment: environment))
                try FileManager.default.removeItem(at: path)
            }
        }
        XCTAssertTrue(try currentObject().isEmpty)
    }

    func testUnreadableRuntimeSecretStateFailsClosedAndDoesNotFollowSymlink() throws {
        try writeSettings([:])
        let outside = root.appendingPathComponent("outside.json")
        try writeSettings(["aiApiKey": "fixture-outside"], url: outside)
        let sidecar = root.appendingPathComponent("secrets.json")
        let environment = ["ENGRAM_RUNTIME_AI_SECRETS_PATH": sidecar.path]
        let patch = try EngramServiceWebPatchAiSettingsRequest(aiBaseURL: "https://other.example/v1")
        try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: outside)
        XCTAssertThrowsError(try isolatedPatch(patch, environment: environment))
        XCTAssertEqual(try currentObject(url: outside)["aiApiKey"] as? String, "fixture-outside")
        try FileManager.default.removeItem(at: sidecar)
        try Data("invalid json".utf8).write(to: sidecar)
        XCTAssertThrowsError(try isolatedPatch(patch, environment: environment))
        try writeSettings([:], url: sidecar)
        XCTAssertNoThrow(try isolatedPatch(patch, environment: environment))
    }

    func testKeychainPresenceProbeNeverRequestsSecretDataOrInteraction() {
        for status in [errSecSuccess, errSecItemNotFound, errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable] {
            let possible = EngramServiceCommandHandler.webAiKeychainMayContain("aiApiKey") { raw in
                let query = raw as NSDictionary
                XCTAssertEqual(query[kSecAttrService] as? String, "com.engram.app")
                XCTAssertEqual(query[kSecAttrAccount] as? String, "aiApiKey")
                XCTAssertEqual(query[kSecReturnAttributes] as? Bool, true)
                XCTAssertNil(query[kSecReturnData])
                XCTAssertEqual((query[kSecUseAuthenticationContext] as? LAContext)?.interactionNotAllowed, true)
                return status
            }
            XCTAssertEqual(possible, status != errSecItemNotFound)
        }
    }

    func testEndpointRejectionSurvivesRealServiceIPCAndLeavesSettingsIntact() async throws {
        let previous = getenv("ENGRAM_SETTINGS_PATH").map { String(cString: $0) }
        setenv("ENGRAM_SETTINGS_PATH", settingsURL.path, 1)
        defer {
            if let previous { setenv("ENGRAM_SETTINGS_PATH", previous, 1) }
            else { unsetenv("ENGRAM_SETTINGS_PATH") }
        }
        try writeSettings(["aiApiKey": "fixture-ipc", "aiModel": "keep-me"])
        let original = try Data(contentsOf: settingsURL)
        let database = root.appendingPathComponent("index.sqlite")
        try EngramDatabaseWriter(path: database.path).migrate()
        let gate = try ServiceWriterGate(databasePath: database.path, runtimeDirectory: root)
        let handler = EngramServiceCommandHandler(writerGate: gate)
        let socket = root.appendingPathComponent("service.sock").path
        let server = UnixSocketServiceServer(socketPath: socket) { request in await handler.handle(request) }
        try server.start()
        defer { server.stop() }
        let client = try EngramServiceWebWriteClient(socketPath: socket)
        do {
            _ = try await client.patchAiSettings(.init(aiBaseURL: "https://other.example/v1", aiModel: "must-not-save"))
            XCTFail("Endpoint changes with saved credentials must be rejected through real IPC")
        } catch {
            XCTAssertEqual(error as? EngramServiceWebWriteClientError, .aiEndpointRequiresLocalUpdate)
        }
        XCTAssertEqual(try Data(contentsOf: settingsURL), original)
        let accepted = try await client.patchAiSettings(.init(aiModel: "safe-edit"))
        XCTAssertEqual(accepted.settings.aiModel, "safe-edit")
        XCTAssertEqual(try currentObject()["aiApiKey"] as? String, "fixture-ipc")
    }

    private func isolatedPatch(
        _ patch: EngramServiceWebPatchAiSettingsRequest, environment: [String: String] = [:]
    ) throws -> EngramServiceWebAiSettingsResponse {
        try EngramServiceCommandHandler.webPatchAiSettings(
            patch, settingsURL: settingsURL, environment: environment, keychainMayContain: { _ in false }
        )
    }

    private func writeSettings(_ object: [String: Any], mode: Int = 0o600, url: URL? = nil) throws {
        let destination = url ?? settingsURL!
        try JSONSerialization.data(withJSONObject: object).write(to: destination)
        XCTAssertEqual(chmod(destination.path, mode_t(mode)), 0)
    }

    private func currentObject(url: URL? = nil) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url ?? settingsURL!)) as? [String: Any])
    }
}
