// macos/EngramTests/SettingsHonestyTests.swift
import XCTest
@testable import Engram

private final class LockedAdvancedPersistenceHistory: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []

    func append(_ value: Double) {
        lock.lock()
        defer { lock.unlock() }
        values.append(value)
    }

    func snapshot() -> [Double] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

/// Source-honesty + behavior tests for WP12: the Settings surface must not
/// advertise persisted-but-unread controls, must not surface the deleted HTTP
/// transcript Web UI, and must report title regeneration honestly.
final class SettingsHonestyTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: - Source honesty

    func testNetworkSettingsSectionIsDeleted() throws {
        let settingsView = try source("macos/Engram/Views/SettingsView.swift")
        XCTAssertFalse(settingsView.contains("case network"), "Network settings only hosted deleted peer-sync controls")
        XCTAssertFalse(settingsView.contains("NetworkSettingsSection"), "Deleted peer-sync settings must not leave an empty Network tab")

        let networkSettings = repoRoot.appendingPathComponent("macos/Engram/Views/Settings/NetworkSettingsSection.swift")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: networkSettings.path),
            "NetworkSettingsSection should be deleted with the dead peer-sync settings surface"
        )
    }

    func testGeneralSettingsDropsMcpEndpointAndHasDeveloperToolsToggle() throws {
        let source = try source("macos/Engram/Views/Settings/GeneralSettingsSection.swift")
        XCTAssertFalse(source.contains("/mcp"), "MCP is stdio-only; the misleading /mcp endpoint row must be removed")
        XCTAssertFalse(source.contains("mcpEndpointText"), "Orphaned mcpEndpointText property must be removed")
        XCTAssertTrue(source.contains("showDeveloperTools"), "Developer Tools toggle must write the showDeveloperTools key B1's Observability gate reads")
        XCTAssertTrue(source.contains("Show Developer Tools"))
    }

    func testHttpTranscriptWebUiSurfaceIsDeleted() throws {
        let settingsView = try source("macos/Engram/Views/SettingsView.swift")
        XCTAssertFalse(settingsView.contains("Toggle(\"Enable Web UI\""), "Settings must not expose the deleted HTTP transcript Web UI gate")
        XCTAssertFalse(settingsView.contains("Enable Web UI"), "Settings must not offer a deleted Web UI toggle")

        let generalSettings = try source("macos/Engram/Views/Settings/GeneralSettingsSection.swift")
        XCTAssertFalse(generalSettings.contains("Open Web UI"), "General settings must not link to the deleted HTTP transcript Web UI")
        XCTAssertFalse(generalSettings.contains("webUIURL"), "General settings must not compute a deleted Web UI endpoint")

        let statusStore = try source("macos/Shared/Service/EngramServiceStatusStore.swift")
        XCTAssertFalse(statusStore.contains("endpointHost"), "Status store must not track a deleted Web UI host")
        XCTAssertFalse(statusStore.contains("endpointPort"), "Status store must not track a deleted Web UI port")
        XCTAssertFalse(statusStore.contains(#""web_ready""#), "Status store must not decode deleted web_ready events")
        XCTAssertFalse(statusStore.contains(#""web_error""#), "Status store must not decode deleted web_error events")

        let runner = try source("macos/EngramService/Core/EngramServiceRunner.swift")
        XCTAssertFalse(runner.contains("EngramWebUIServer"), "Service runner must not start the deleted HTTP transcript Web UI")
        XCTAssertFalse(runner.contains("readWebUIEnabled"), "Service runner must not read the deleted Web UI gate")
        XCTAssertFalse(runner.contains("provisionWebToken"), "Service runner must not provision deleted Web UI tokens")
        XCTAssertFalse(runner.contains(#""web_ready""#), "Service runner must not emit deleted web_ready events")
        XCTAssertFalse(runner.contains(#""web_error""#), "Service runner must not emit deleted web_error events")
    }

    func testAdvancedSettingsHasNoWebApiSecurityControls() throws {
        let source = try source("macos/Engram/Views/SettingsView.swift")
        XCTAssertFalse(source.contains("Web API & Security"), "The misleading Web API & Security GroupBox must be removed")
        XCTAssertFalse(source.contains("$httpBearerToken"), "The unread bearer-token input control must be removed")
        XCTAssertFalse(source.contains("$httpAllowCIDR"), "The unread CIDR input control must be removed")
        XCTAssertFalse(source.contains("$httpHost"), "The unread HTTP host input control must be removed")
        // The scrub removeValue calls must remain so stale persisted values are wiped on next save.
        XCTAssertTrue(source.contains(#"removeValue(forKey: "httpBearerToken")"#))
        XCTAssertTrue(source.contains(#"removeValue(forKey: "httpAllowCIDR")"#))
        XCTAssertTrue(source.contains(#"removeValue(forKey: "httpHost")"#))
        XCTAssertTrue(source.contains(#"removeValue(forKey: "webUIEnabled")"#))
    }

    /// concurrency-5: Advanced settings file reads and exclusive-lock writes
    /// must run off MainActor; only the state snapshot/application stays on it.
    func testAdvancedSettingsFileIOIsOffMain_repro() throws {
        let text = try source("macos/Engram/Views/SettingsView.swift")
        XCTAssertTrue(text.contains(".task { await loadAdvancedSettings() }"))
        XCTAssertFalse(text.contains(".onAppear { loadAdvancedSettings() }"))

        let loadStart = try XCTUnwrap(text.range(of: "private func loadAdvancedSettings() async"))
        let loadEnd = try XCTUnwrap(
            text.range(of: "private func clearLoadingSettingsAfterViewUpdate", range: loadStart.lowerBound..<text.endIndex)
        )
        let loadBody = String(text[loadStart.lowerBound..<loadEnd.lowerBound])
        XCTAssertTrue(loadBody.contains("await AdvancedSettingsIO.loadOffMain()"))
        XCTAssertFalse(loadBody.contains("readEngramSettings()"))

        let saveStart = try XCTUnwrap(text.range(of: "private func saveAdvancedSettings"))
        let saveEnd = try XCTUnwrap(
            text.range(of: "private func addUsageLimitRow", range: saveStart.lowerBound..<text.endIndex)
        )
        let saveBody = String(text[saveStart.lowerBound..<saveEnd.lowerBound])
        XCTAssertTrue(saveBody.contains("AdvancedSettingsIO.persistOffMain"))
        XCTAssertFalse(saveBody.contains("mutateEngramSettings"))

        let ioStart = try XCTUnwrap(text.range(of: "enum AdvancedSettingsIO"))
        let ioBody = String(text[ioStart.lowerBound...])
        XCTAssertTrue(ioBody.contains("Task.detached"))
        XCTAssertTrue(ioBody.contains("actor Mailbox"))
        XCTAssertTrue(ioBody.contains("mutateEngramSettings"))
    }

    /// core-read-2 / ui-search-settings-4: the archive Settings section must
    /// keep settings.json and SQLite reads/writes off MainActor.
    @MainActor
    func testLiveIngestBlockingIOIsOffMain_repro() async throws {
        let text = try source("macos/Engram/Views/SettingsView.swift")

        let sectionStart = try XCTUnwrap(text.range(of: "private struct LiveIngestSettingsSection"))
        let sectionEnd = try XCTUnwrap(
            text.range(of: "private struct SettingsSidebarRow", range: sectionStart.upperBound..<text.endIndex)
        )
        let section = String(text[sectionStart.lowerBound..<sectionEnd.lowerBound])
        XCTAssertTrue(section.contains(".task { await load() }"), section)
        XCTAssertFalse(section.contains(".onAppear {\n            load()"), section)

        for function in ["private func load() async", "private func persistEnabled(_ value: Bool) async"] {
            XCTAssertTrue(section.contains(function), "missing async \(function):\n\(section)")
        }
        XCTAssertGreaterThanOrEqual(
            section.components(separatedBy: "await LiveIngestSettingsIO.runOffMain").count - 1,
            3,
            "load, persist, and post-reset status reads must all cross the detached I/O seam"
        )

        let ioStart = try XCTUnwrap(text.range(of: "enum LiveIngestSettingsIO"))
        let ioEnd = try XCTUnwrap(
            text.range(of: "private struct SettingsSidebarRow", range: ioStart.upperBound..<text.endIndex)
        )
        let io = String(text[ioStart.lowerBound..<ioEnd.lowerBound])
        XCTAssertTrue(io.contains("Task.detached"), io)

        let ranOnMainThread = await LiveIngestSettingsIO.runOffMain {
            Thread.isMainThread
        }
        XCTAssertFalse(ranOnMainThread)
    }

    @MainActor
    func testAdvancedSettingsNewestSubmissionWinsWhenDetachedArrivalInverts_repro() async {
        let history = LockedAdvancedPersistenceHistory()
        let hooks = AdvancedSettingsPersistenceHooks(
            beforeMailbox: { snapshot in
                if snapshot.dailyCostBudget == 1 {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            },
            persist: { snapshot in
                history.append(snapshot.dailyCostBudget)
            }
        )

        AdvancedSettingsIO.persistOffMain(
            advancedSnapshot(dailyCostBudget: 1),
            testHooks: hooks,
            onPersisted: {}
        )
        AdvancedSettingsIO.persistOffMain(
            advancedSnapshot(dailyCostBudget: 2),
            testHooks: hooks,
            onPersisted: {}
        )

        var completed = false
        for _ in 0..<100 {
            if history.snapshot().count >= 2 {
                completed = true
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(completed)
        XCTAssertEqual(history.snapshot().last, 2)
    }

    func testServiceCoreDoesNotLinkDeletedHttpStack() throws {
        let source = try source("macos/project.yml")
        let serviceCoreBlock = try XCTUnwrap(
            source.range(of: "  EngramServiceCore:")?.lowerBound
        )
        let serviceTargetBlock = try XCTUnwrap(
            source.range(of: "  EngramService:", range: serviceCoreBlock..<source.endIndex)?.lowerBound
        )
        let block = String(source[serviceCoreBlock..<serviceTargetBlock])

        XCTAssertFalse(block.contains("Hummingbird"), "EngramServiceCore must not link the deleted HTTP Web UI stack")
    }

    func testAppTargetDoesNotLinkDeletedHttpStack() throws {
        let source = try source("macos/project.yml")
        let appTargetBlock = try XCTUnwrap(
            source.range(of: "  Engram:")?.lowerBound
        )
        let cliTargetBlock = try XCTUnwrap(
            source.range(of: "  EngramCLI:", range: appTargetBlock..<source.endIndex)?.lowerBound
        )
        let block = String(source[appTargetBlock..<cliTargetBlock])

        XCTAssertFalse(block.contains("Hummingbird"), "Engram.app must not link the deleted HTTP Web UI stack")
    }

    func testRegenerateAllStatusCopyIsHonest() throws {
        let source = try source("macos/Engram/Views/Settings/AISettingsSection.swift")
        XCTAssertFalse(source.contains("Service status: "), "Status must not freeze on the raw service status string")
        XCTAssertTrue(source.contains("Regenerating in background"), "Status must honestly say regeneration runs in the background")
        XCTAssertTrue(source.contains("case service(String, Int?)"), "Status enum must carry the optional session total")
    }

    // MARK: - Behavior

    func testRegenerationStatusLabelRendersHonestCopy() {
        // The enum carries (status, total); both with and without a total must
        // produce a non-nil, in-background label rather than the raw status.
        XCTAssertNotNil(TitleRegenerationStatus.service("started", 42).label)
        XCTAssertNotNil(TitleRegenerationStatus.service("running", nil).label)
        XCTAssertNil(TitleRegenerationStatus.idle.label)
        XCTAssertNotNil(TitleRegenerationStatus.queued.label)
        XCTAssertNotNil(TitleRegenerationStatus.error.label)
    }

    func testRegenerateAllTitlesDrivesServiceResponse() async throws {
        let mock = MockEngramServiceClient(
            regenerateAllTitles: EngramServiceRegenerateTitlesResponse(
                status: "started",
                total: 17,
                message: nil
            )
        )
        let response = try await mock.regenerateAllTitles()
        let status = TitleRegenerationStatus.service(response.status, response.total)
        XCTAssertEqual(status, .service("started", 17))
        XCTAssertNotNil(status.label)
    }

    func testLiveIngestToggleFailedWriteRestoresPersistedStateAndShowsError_repro() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-live-ingest-toggle-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let target = root.appendingPathComponent("persisted-settings.json")
        let linked = root.appendingPathComponent("settings.json")
        let original = Data(#"{"liveIngestEnabled":false}"#.utf8)
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: target)

        let result = persistLiveIngestEnabled(
            requestedValue: true,
            currentPersistedValue: false,
            serviceIsRunning: true,
            mutateSettings: { transform in
                mutateEngramSettingsIfNeeded(at: linked) { settings in
                    transform(&settings)
                    return true
                }
            }
        )

        XCTAssertFalse(result.enabled)
        XCTAssertFalse(result.restartNeeded)
        XCTAssertEqual(
            result.message,
            "Could not save HQ live ingest setting. The previous setting remains active."
        )
        XCTAssertEqual(try Data(contentsOf: target), original)
    }

    func testLiveIngestToggleSuccessfulWriteKeepsRequestedStateAndRestartHint_repro() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-live-ingest-toggle-success-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")

        let result = persistLiveIngestEnabled(
            requestedValue: true,
            currentPersistedValue: false,
            serviceIsRunning: true,
            mutateSettings: { transform in
                mutateEngramSettingsIfNeeded(at: file) { settings in
                    transform(&settings)
                    return true
                }
            }
        )

        XCTAssertTrue(result.enabled)
        XCTAssertTrue(result.restartNeeded)
        XCTAssertNil(result.message)
        let data = try XCTUnwrap(readEngramSettingsData(at: file))
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(settings["liveIngestEnabled"] as? Bool, true)
        XCTAssertEqual(settings["liveIngestSources"] as? [String], ["hq"])
        XCTAssertEqual(settings["liveIngestPeerId"] as? String, "hq")
    }

    // UI-iteration 2026-08-30 (Wave-1 item 6): the mock previously hardcoded a
    // success result for liveIngestResetShrinkGuard, so previews/tests could
    // not drive the Settings failure branch. Init injection must win.
    func testLiveIngestResetShrinkGuardInjectedFailure_repro() async throws {
        struct StubError: Error {}
        let failing = MockEngramServiceClient(
            liveIngestResetShrinkGuardResult: .failure(StubError())
        )
        do {
            _ = try await failing.liveIngestResetShrinkGuard(peer: "hq")
            XCTFail("expected injected failure to throw")
        } catch {
            XCTAssertTrue(error is StubError)
        }

        let succeeding = MockEngramServiceClient()
        let response = try await succeeding.liveIngestResetShrinkGuard(peer: "hq")
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.peer, "hq")
    }

    private func advancedSnapshot(dailyCostBudget: Double) -> AdvancedSettingsPersistSnapshot {
        AdvancedSettingsPersistSnapshot(
            monitorEnabled: true,
            dailyCostBudget: dailyCostBudget,
            monthlyCostBudget: 0,
            longSessionMinutes: 180,
            notifyOnCostThreshold: true,
            notifyOnUsagePressure: true,
            notifyOnLongSession: true,
            usageLimitRows: [],
            removedUsageLimitSourceIDs: [],
            logLevel: "info",
            logRetentionDays: 7,
            aiAuditEnabled: true,
            aiAuditRetentionDays: 30,
            aiAuditMaxBodySize: 10_000,
            aiAuditLogBodies: false,
            devMode: false
        )
    }
}
