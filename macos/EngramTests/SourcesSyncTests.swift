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

    // MARK: - healthReason DTO

    func testSourceInfoEncodesHealthReason() throws {
        let info = EngramServiceSourceInfo(
            name: "codex",
            sessionCount: 1,
            latestIndexed: nil,
            healthStatus: "partial",
            healthReason: "1 of 4 indexable sessions are missing search-index rows."
        )
        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(EngramServiceSourceInfo.self, from: data)
        XCTAssertEqual(decoded.healthReason, info.healthReason)
    }

    func testSourceInfoDecodesLegacyJsonWithoutHealthReasonAsNil() throws {
        let json = #"{"name":"codex","sessionCount":3,"healthStatus":"healthy"}"#
        let decoded = try JSONDecoder().decode(
            EngramServiceSourceInfo.self,
            from: Data(json.utf8)
        )
        XCTAssertNil(decoded.healthReason)
    }

    func testMemberwiseInitDefaultsHealthReasonNil() {
        let info = EngramServiceSourceInfo(name: "codex", sessionCount: 0, latestIndexed: nil)
        XCTAssertNil(info.healthReason)
    }

    // MARK: - Source-text guards

    func testSourcePulseRendersCacheOnlyPillGatedOnFlag() throws {
        let text = try source("macos/Engram/Views/Pages/SourcePulseView.swift")
        XCTAssertTrue(text.contains("Cache only"))
        XCTAssertTrue(text.contains("source.liveSyncDisabled"))
    }

    func testSourceHealthPredicatesUseNonSkipTierSQL() throws {
        let text = try source("macos/EngramService/Core/EngramServiceReadProvider.swift")
        guard
            let start = text.range(of: "private func sourceIndexEligibleCounts"),
            let mid = text.range(of: "private func sourceSearchableCounts", range: start.upperBound..<text.endIndex),
            let end = text.range(of: "private func sourceFailedIndexJobCounts", range: mid.upperBound..<text.endIndex)
        else {
            return XCTFail("could not locate sourceIndexEligibleCounts / sourceSearchableCounts slice")
        }
        let slice = String(text[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(slice.contains("SessionVisibilityFilter.nonSkipTierSQL"), slice)
        XCTAssertFalse(slice.contains("searchableTierSQL"), slice)
        XCTAssertFalse(slice.contains("'lite'"), slice)
    }

    func testSourcePulseHealthBadgeExposesReason() throws {
        let text = try source("macos/Engram/Views/Pages/SourcePulseView.swift")
        XCTAssertTrue(text.contains("source.healthReason"))
        guard
            let start = text.range(of: "private func healthBadge"),
            let end = text.range(of: "private func usageColor", range: start.upperBound..<text.endIndex)
        else {
            return XCTFail("could not locate healthBadge / usageColor slice")
        }
        let slice = String(text[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(slice.contains(".accessibilityLabel"), slice)
        XCTAssertTrue(slice.contains(".help("), slice)
        XCTAssertTrue(slice.contains("reason"), slice)
    }

    func testSourcesSettingsHasNoDeadPathKeysAndKeepsCatalogReadOnly() throws {
        let text = try source("macos/Engram/Views/Settings/SourcesSettingsSection.swift")
        XCTAssertFalse(text.contains("\"path."))
        XCTAssertTrue(text.contains("read-only"))
        XCTAssertTrue(text.contains("Archived"))
        XCTAssertTrue(text.contains("stay off until enabled"))
        XCTAssertTrue(text.contains("Workspace > Sources > Archived"))
        XCTAssertFalse(text.contains("UserDefaults.standard.string(forKey:"))
        XCTAssertFalse(text.contains("UserDefaults.standard.set("))
        XCTAssertTrue(text.contains("configureClaudeCodeProfiles"))
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

    func testOnboardingDoesNotPresentArchivedSourcesAsReadyToIndex() throws {
        let text = try source("macos/Engram/Onboarding/OnboardingView.swift")
        XCTAssertTrue(text.contains("!ArchivedDefaultOffSources.contains($0.id)"))
        XCTAssertFalse(text.contains("(\"lobsterai\""))
    }
}
