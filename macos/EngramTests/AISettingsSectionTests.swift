import XCTest
@testable import Engram

final class AISettingsSectionTests: XCTestCase {
    private var macOSRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    func testAISettingsSaveIsDebounced_repro() throws {
        let source = try String(
            contentsOf: macOSRoot.appendingPathComponent("Engram/Views/Settings/AISettingsSection.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("settingsSaveDebounceNanoseconds"))
        XCTAssertTrue(source.contains("scheduleSaveAISettings"))
        XCTAssertFalse(source.contains(".onChange(of: aiBaseURL) { saveAISettings() }"))
        XCTAssertTrue(source.contains(".onChange(of: aiBaseURL) { scheduleSaveAISettings() }"))
        XCTAssertGreaterThanOrEqual(AISettingsSection.settingsSaveDebounceNanoseconds, 100_000_000)
    }

    /// R9/M21 residual: leave before debounce fires must flush pending saves.
    func testAISettingsFlushesPendingSavesOnDisappear_repro() throws {
        let source = try String(
            contentsOf: macOSRoot.appendingPathComponent("Engram/Views/Settings/AISettingsSection.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains(".onDisappear { flushPendingAISettingsSaves() }"))
        XCTAssertTrue(source.contains("func flushPendingAISettingsSaves()"))
        XCTAssertTrue(source.contains("AISettingsSaveFlush.shouldFlush"))
        XCTAssertTrue(AISettingsSaveFlush.shouldFlush(pendingTask: true, isLoadingSettings: false))
        XCTAssertFalse(AISettingsSaveFlush.shouldFlush(pendingTask: false, isLoadingSettings: false))
        XCTAssertFalse(AISettingsSaveFlush.shouldFlush(pendingTask: true, isLoadingSettings: true))
    }

    /// R9: debounce/flush snapshot on MainActor, persist Keychain + settings.json off-main.
    func testAISettingsPersistsKeychainAndFileOffMain_repro() throws {
        let source = try String(
            contentsOf: macOSRoot.appendingPathComponent("Engram/Views/Settings/AISettingsSection.swift"),
            encoding: .utf8
        )
        let saveStart = try XCTUnwrap(source.range(of: "private func saveAISettings()"))
        let saveEnd = try XCTUnwrap(
            source.range(of: "private func saveTitleSettings()", range: saveStart.lowerBound..<source.endIndex)
        )
        let saveBody = String(source[saveStart.lowerBound..<saveEnd.lowerBound])
        XCTAssertTrue(saveBody.contains("AISettingsPersister.persistAIOffMain"))
        XCTAssertFalse(saveBody.contains("KeychainHelper.set"))
        XCTAssertFalse(saveBody.contains("mutateEngramSettings"))

        let persistStart = try XCTUnwrap(source.range(of: "static func persistAIOffMain"))
        let persistEnd = try XCTUnwrap(
            source.range(of: "static func persistTitleOffMain", range: persistStart.lowerBound..<source.endIndex)
        )
        let persistOffMain = String(source[persistStart.lowerBound..<persistEnd.lowerBound])
        XCTAssertTrue(persistOffMain.contains("Task.detached"))

        let mailboxStart = try XCTUnwrap(source.range(of: "func persistAI(_ snapshot: AISettingsPersistSnapshot)"))
        let mailboxEnd = try XCTUnwrap(
            source.range(of: "func persistTitle(_ snapshot: TitleSettingsPersistSnapshot)", range: mailboxStart.lowerBound..<source.endIndex)
        )
        let mailboxBody = String(source[mailboxStart.lowerBound..<mailboxEnd.lowerBound])
        XCTAssertTrue(mailboxBody.contains("applyAPIKey"))
        XCTAssertTrue(mailboxBody.contains("mutateEngramSettings"))
    }

    /// M20: pure helper — invalid/empty free-text URLs must fail closed.
    func testParseConnectionURLRejectsInvalidAndEmpty_repro() {
        XCTAssertNil(AISettingsURLValidation.parseConnectionURL(""))
        XCTAssertNil(AISettingsURLValidation.parseConnectionURL("   "))
        XCTAssertNil(AISettingsURLValidation.parseConnectionURL(" not a url"))
        XCTAssertNil(AISettingsURLValidation.parseConnectionURL("localhost:11434"))
        XCTAssertNil(AISettingsURLValidation.parseConnectionURL("http://"))
        XCTAssertNil(AISettingsURLValidation.parseConnectionURL("file:///tmp/x"))
        // Leading space after trim OK if still valid absolute URL
        let ok = AISettingsURLValidation.parseConnectionURL("  http://localhost:11434  ")
        XCTAssertEqual(ok?.scheme, "http")
        XCTAssertEqual(ok?.host, "localhost")
        XCTAssertEqual(ok?.port, 11434)
        let https = AISettingsURLValidation.parseConnectionURL("https://api.example.com/v1")
        XCTAssertEqual(https?.host, "api.example.com")
    }

    /// M20: Test Connection path must call the pure helper (not force-unwrap).
    func testTestConnectionUsesParseConnectionURLHelper_repro() throws {
        let source = try String(
            contentsOf: macOSRoot.appendingPathComponent("Engram/Views/Settings/AISettingsSection.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("AISettingsURLValidation.parseConnectionURL(testURL)"))
        XCTAssertFalse(source.contains("URLRequest(url: URL(string: testURL)!)"))
    }
}
