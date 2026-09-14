import Darwin
import Foundation
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

    private func writeSettings(_ object: [String: Any], mode: Int = 0o600, url: URL? = nil) throws {
        let destination = url ?? settingsURL!
        try JSONSerialization.data(withJSONObject: object).write(to: destination)
        XCTAssertEqual(chmod(destination.path, mode_t(mode)), 0)
    }

    private func currentObject(url: URL? = nil) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url ?? settingsURL!)) as? [String: Any])
    }
}
