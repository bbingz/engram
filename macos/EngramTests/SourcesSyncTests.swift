import XCTest
@testable import Engram

final class SourcesSyncTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: - Live-sync-disabled source set

    func testLiveSyncDisabledSourceSet() {
        XCTAssertEqual(LiveSyncDisabledSources.ids, ["windsurf", "antigravity"])
        XCTAssertTrue(LiveSyncDisabledSources.isLiveSyncDisabled("windsurf"))
        XCTAssertTrue(LiveSyncDisabledSources.isLiveSyncDisabled("antigravity"))
        // Regression guards: never re-add the dead id, and live sources stay off.
        XCTAssertFalse(LiveSyncDisabledSources.isLiveSyncDisabled("antigravity-legacy"))
        XCTAssertFalse(LiveSyncDisabledSources.isLiveSyncDisabled("claude-code"))
        XCTAssertFalse(LiveSyncDisabledSources.isLiveSyncDisabled("codex"))
    }

    // MARK: - DTO round-trip + back-compat

    func testSourceInfoEncodesLiveSyncDisabled() throws {
        let info = EngramServiceSourceInfo(
            name: "windsurf",
            sessionCount: 1,
            latestIndexed: nil,
            liveSyncDisabled: true
        )
        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(EngramServiceSourceInfo.self, from: data)
        XCTAssertTrue(decoded.liveSyncDisabled)
    }

    func testSourceInfoDecodesLegacyJsonWithoutFlagAsFalse() throws {
        let json = #"{"name":"codex","sessionCount":3,"healthStatus":"healthy"}"#
        let decoded = try JSONDecoder().decode(
            EngramServiceSourceInfo.self,
            from: Data(json.utf8)
        )
        XCTAssertFalse(decoded.liveSyncDisabled)
    }

    func testMemberwiseInitDefaultsLiveSyncDisabledFalse() {
        let info = EngramServiceSourceInfo(name: "codex", sessionCount: 0, latestIndexed: nil)
        XCTAssertFalse(info.liveSyncDisabled)
    }

    // MARK: - Source-text guards

    func testSourcePulseRendersCacheOnlyPillGatedOnFlag() throws {
        let text = try source("macos/Engram/Views/Pages/SourcePulseView.swift")
        XCTAssertTrue(text.contains("Cache only"))
        XCTAssertTrue(text.contains("source.liveSyncDisabled"))
    }

    func testSourcesSettingsHasNoDeadPathKeysAndIsReadOnly() throws {
        let text = try source("macos/Engram/Views/Settings/SourcesSettingsSection.swift")
        XCTAssertFalse(text.contains("\"path."))
        XCTAssertTrue(text.contains("read-only"))
    }

    func testSourceCatalogMatchesRegisteredAdapters() throws {
        // The static catalog moved out of Settings into SourceCatalog; assert it
        // there now that Settings only points at Workspace > Sources.
        let text = try source("macos/Engram/Models/SourceCatalog.swift")
        // Real Claude-Code-derived sources.
        XCTAssertTrue(text.contains("minimax"))
        XCTAssertTrue(text.contains("lobsterai"))
        // Never re-add unregistered sources.
        XCTAssertFalse(text.contains("OpenClaw"))
        XCTAssertFalse(text.contains("Hermes"))
        XCTAssertFalse(text.contains("openclaw"))
        XCTAssertFalse(text.contains("hermes"))
    }
}
