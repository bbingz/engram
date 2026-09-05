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

    func testSourceInfoRoundTripsListVisibleSessionCount_repro() throws {
        let info = EngramServiceSourceInfo(
            name: "codex",
            sessionCount: 7,
            latestIndexed: nil,
            listVisibleSessionCount: 3
        )

        let decoded = try JSONDecoder().decode(
            EngramServiceSourceInfo.self,
            from: JSONEncoder().encode(info)
        )

        XCTAssertEqual(decoded.listVisibleSessionCount, 3)
    }

    func testSourceInfoLegacyPayloadDefaultsListVisibleCountToRawCount_repro() throws {
        let json = #"{"name":"codex","sessionCount":7,"healthStatus":"healthy"}"#
        let decoded = try JSONDecoder().decode(
            EngramServiceSourceInfo.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(decoded.listVisibleSessionCount, 7)
    }

    func testSourceInfoInitializerDefaultsListVisibleCountToRawCount_repro() {
        let info = EngramServiceSourceInfo(name: "codex", sessionCount: 7, latestIndexed: nil)
        XCTAssertEqual(info.listVisibleSessionCount, 7)
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

    func testSourcePulseTimerCoalescesWithoutCancellingInflightPoll_repro() throws {
        let text = try source("macos/Engram/Views/Pages/SourcePulseView.swift")
        let taskStart = try XCTUnwrap(text.range(of: ".task {"))
        let disappear = try XCTUnwrap(
            text.range(of: ".onDisappear", range: taskStart.upperBound..<text.endIndex)
        )
        let timerSlice = String(text[taskStart.lowerBound..<disappear.lowerBound])
        XCTAssertTrue(timerSlice.contains("requestLiveRefresh()"), timerSlice)
        XCTAssertFalse(
            timerSlice.contains("liveRefreshTask?.cancel()"),
            "a cadence tick must not cancel the producer request it needs to populate the cache"
        )

        let coalescerStart = try XCTUnwrap(text.range(of: "private func requestLiveRefresh()"))
        let loaderStart = try XCTUnwrap(
            text.range(of: "private func loadLiveSessions()", range: coalescerStart.upperBound..<text.endIndex)
        )
        let coalescer = String(text[coalescerStart.lowerBound..<loaderStart.lowerBound])
        XCTAssertTrue(coalescer.contains("guard liveRefreshTask == nil else { return }"), coalescer)
        XCTAssertTrue(coalescer.contains("liveRefreshTask = nil"), coalescer)
    }

    func testSourcePulseDisabledSourcesFailClosedUntilAuthoritativeLoad_repro() throws {
        let text = try source("macos/Engram/Views/Pages/SourcePulseView.swift")

        XCTAssertTrue(
            text.contains("@State private var disabledSources = ArchivedDefaultOffSources.ids"),
            "archived adapters must render disabled before the service responds"
        )
        XCTAssertTrue(
            text.contains("@State private var disabledSourcesLoaded = false"),
            "toggle interaction must have an explicit authoritative-load gate"
        )
        XCTAssertTrue(
            text.contains(".disabled(!disabledSourcesLoaded)"),
            "ingest toggles must stay unavailable until disabledSources succeeds"
        )
        XCTAssertTrue(text.contains("disabledSourcesLoaded = true"))
        XCTAssertTrue(text.contains("disabledSourcesLoaded = false"))
        XCTAssertFalse(
            text.contains("if let disabled = try? await serviceClient.disabledSources()"),
            "a failed fetch must be distinguishable from an authoritative empty set"
        )
    }

    func testSourceHealthPredicatesUseListVisibleSQL() throws {
        let text = try source("macos/EngramService/Core/EngramServiceReadProvider.swift")
        guard
            let start = text.range(of: "private func sourceIndexEligibleCounts"),
            let mid = text.range(of: "private func sourceSearchableCounts", range: start.upperBound..<text.endIndex),
            let end = text.range(of: "private func sourceFailedIndexJobCounts", range: mid.upperBound..<text.endIndex)
        else {
            return XCTFail("could not locate sourceIndexEligibleCounts / sourceSearchableCounts slice")
        }
        let slice = String(text[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(slice.contains("SessionVisibilityFilter.listVisibleSQL"), slice)
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
