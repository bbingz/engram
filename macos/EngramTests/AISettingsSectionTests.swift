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
}
