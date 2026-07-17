import XCTest

/// Source-inspection guards (mirroring AppSearchServiceCutoverScanTests) that
/// lock the off-main read + async-ordering fixes from audit round 2 (ui-1..7),
/// so these views don't regress to synchronous main-thread DB reads or
/// stale-response clobbering.
final class ViewMainThreadReadTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testAboutSettingsSectionReadsOffMainThread() throws {
        let s = try source("macos/Engram/Views/Settings/AboutSettingsSection.swift")
        XCTAssertTrue(s.contains("Task.detached"), "AboutSettingsSection must stat + count off the main thread (ui-6)")
        XCTAssertFalse(s.contains(".onAppear { loadInfo() }"), "must use .task with an async off-main loadInfo")
    }

    func testMainWindowNavigateReadsOffMainThread() throws {
        let s = try source("macos/Engram/Views/MainWindowView.swift")
        XCTAssertTrue(
            s.contains("Task.detached"),
            "navigateToSession must read the session off the main thread (ui-4)"
        )
    }

    func testMainWindowNavigationIgnoresSupersededLookups() throws {
        let s = try source("macos/Engram/Views/MainWindowView.swift")
        XCTAssertTrue(
            s.contains("@State private var pendingNavigationId: String?"),
            "palette navigation must track the latest requested session id"
        )
        XCTAssertTrue(
            s.contains("guard pendingNavigationId == id else { return }"),
            "a slower session lookup must not overwrite a newer palette navigation"
        )
    }

    func testAppDoesNotStartDuplicateStatusPollingStreams() throws {
        let s = try source("macos/Engram/App.swift")
        let directStatusObservationCalls = s
            .split(whereSeparator: \.isNewline)
            .filter { line in
                line.trimmingCharacters(in: .whitespaces) == "startServiceStatusObservation()"
            }

        XCTAssertTrue(
            directStatusObservationCalls.isEmpty,
            "App should not run the legacy events() status stream alongside EngramServiceLauncher health polling"
        )
        XCTAssertTrue(
            s.contains("serviceLauncher.startHealthMonitor"),
            "EngramServiceLauncher health polling remains the single periodic status probe"
        )
    }

    func testSearchPageGuardsAgainstStaleResponses() throws {
        let s = try source("macos/Engram/Views/Pages/SearchPageView.swift")
        XCTAssertTrue(
            s.contains("guard !Task.isCancelled"),
            "performSearch must guard against a superseded in-flight response clobbering results (ui-2)"
        )
    }

    func testSearchPageCancelsWorkOnDisappear() throws {
        let s = try source("macos/Engram/Views/Pages/SearchPageView.swift")
        XCTAssertTrue(s.contains("@State private var searchTask: Task<Void, Never>?"))
        XCTAssertTrue(
            s.contains(".onDisappear { searchTask?.cancel(); searchTask = nil }"),
            "SearchPageView must cancel delayed or in-flight search work when the page leaves the hierarchy"
        )
    }

    func testSearchPageFallbackSearchReadsOffMainThread() throws {
        let s = try source("macos/Engram/Views/Pages/SearchPageView.swift")
        let fallbackStart = try XCTUnwrap(s.range(of: "// Fallback to local FTS"))
        let fallbackEnd = try XCTUnwrap(s.range(of: "EngramLogger.error(\"SearchPage fallback search failed\"", options: [], range: fallbackStart.lowerBound..<s.endIndex))
        let fallback = String(s[fallbackStart.lowerBound..<fallbackEnd.lowerBound])

        XCTAssertTrue(
            fallback.contains("let localResults = try await Task.detached"),
            "SearchPageView offline fallback must run the heavy local FTS read off the main actor"
        )
        XCTAssertFalse(
            fallback.contains("let localResults = try db.searchWithSnippets"),
            "SearchPageView offline fallback must not synchronously scan the local DB on the main actor"
        )
    }

    func testCommandPaletteDebouncesAndOwnsSearchTask() throws {
        let s = try source("macos/Engram/Views/CommandPaletteView.swift")
        XCTAssertTrue(s.contains("@State private var searchTask: Task<Void, Never>?"))
        XCTAssertTrue(s.contains("searchTask?.cancel()"))
        XCTAssertTrue(
            s.contains("Task.sleep(nanoseconds: 300_000_000)"),
            "CommandPaletteView must debounce per-keystroke session searches instead of spawning one service call per input change"
        )
        XCTAssertTrue(
            s.contains("guard !Task.isCancelled"),
            "CommandPaletteView async callbacks must not publish stale search results after cancellation"
        )
        // Wave 7E H11: service catch starts a do/try local FTS path (empty ≠ fail).
        XCTAssertTrue(
            s.contains("} catch {\n                guard !Task.isCancelled else { return }\n                // Wave 7E H11")
                || s.contains("try await Task.detached {\n                        try db.search(query: q, limit: 10)"),
            "a cancelled service search must exit before starting the local DB fallback"
        )
        XCTAssertTrue(s.contains(".onDisappear { searchTask?.cancel(); searchTask = nil }"))
    }

    func testExpandableSessionCardInvalidatesOnEitherCount() throws {
        let s = try source("macos/Engram/Components/ExpandableSessionCard.swift")
        XCTAssertTrue(
            s.contains("onChange(of: [confirmedChildCount, suggestedChildCount])"),
            "child cache must invalidate when either count changes, not just the sum (ui-3)"
        )
        XCTAssertFalse(s.contains("onChange(of: confirmedChildCount + suggestedChildCount)"))
    }

    func testFilterChangesUseCancellingTaskId() throws {
        let timeline = try source("macos/Engram/Views/Pages/TimelinePageView.swift")
        XCTAssertTrue(timeline.contains(".task(id:"), "TimelinePageView must use a cancelling .task(id:) (ui-7)")
        XCTAssertFalse(timeline.contains("Task { await loadData() } }"))

        let sessions = try source("macos/Engram/Views/Pages/SessionsPageView.swift")
        XCTAssertTrue(sessions.contains(".task(id:"), "SessionsPageView must use a cancelling .task(id:) (ui-7)")
        XCTAssertFalse(sessions.contains(".onChange(of: timeFilter) { _, _ in Task { await loadData() } }"))
    }

    func testVisiblePagesReloadWhenServiceSessionCountChanges() throws {
        let pagePaths = [
            "macos/Engram/Views/Pages/HomeView.swift",
            "macos/Engram/Views/Pages/SessionsPageView.swift",
            "macos/Engram/Views/Pages/TimelinePageView.swift",
            "macos/Engram/Views/Pages/ActivityView.swift",
            "macos/Engram/Views/Pages/ProjectsView.swift",
        ]

        for path in pagePaths {
            let page = try source(path)
            XCTAssertTrue(page.contains("@Environment(EngramServiceStatusStore.self)"))
            XCTAssertTrue(
                page.contains("serviceStatusStore.totalSessions"),
                "\(path) must reload visible data when live service indexing changes the session count"
            )
            XCTAssertTrue(page.contains(".task(id:"))
        }
    }

    func testTimelineAndSessionsPagesWireSuggestedChildActions() throws {
        let pages = [
            try source("macos/Engram/Views/Pages/TimelinePageView.swift"),
            try source("macos/Engram/Views/Pages/SessionsPageView.swift"),
        ]

        for page in pages {
            XCTAssertTrue(page.contains("@Environment(EngramServiceClient.self)"))
            XCTAssertTrue(page.contains("onConfirmSuggestion: { child in confirmSuggestion(child) }"))
            XCTAssertTrue(page.contains("onDismissSuggestion: { child in dismissSuggestion(child) }"))
            XCTAssertTrue(page.contains("serviceClient.confirmSuggestion(sessionId: child.id)"))
            XCTAssertTrue(page.contains("serviceClient.dismissSuggestion("))
        }
    }

    func testTimelinePageReusesDateFormatters() throws {
        let s = try source("macos/Engram/Views/Pages/TimelinePageView.swift")
        let start = try XCTUnwrap(s.range(of: "private func formatDateLabel"))
        let end = try XCTUnwrap(s.range(of: "private func sessionCountLabel"))
        let functionSource = String(s[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(s.contains("private static let inputDateFormatter"))
        XCTAssertTrue(s.contains("private static let outputDateFormatter"))
        XCTAssertFalse(
            functionSource.contains("DateFormatter()"),
            "formatDateLabel runs for every timeline group and must not allocate DateFormatter per call"
        )
    }

    func testHeadingViewReusesCachedMarkdownParse() throws {
        let s = try source("macos/Engram/Views/ContentSegmentViews.swift")
        let start = try XCTUnwrap(s.range(of: "struct HeadingView"))
        let end = try XCTUnwrap(s.range(of: "struct CodeBlockView"))
        let headingSource = String(s[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(
            headingSource.contains("MarkdownText.cachedAttributed(text)"),
            "HeadingView must route through the shared markdown cache"
        )
        XCTAssertFalse(
            headingSource.contains("AttributedString(\n                markdown: text")
                || headingSource.contains("AttributedString(markdown: text"),
            "HeadingView must not re-parse markdown directly on every body evaluation"
        )
    }

    func testLiveAndReplayViewsReuseISO8601Formatters() throws {
        let live = try source("macos/Engram/Components/LiveSessionCard.swift")
        let elapsedStart = try XCTUnwrap(live.range(of: "private var elapsedText"))
        let elapsedEnd = try XCTUnwrap(live.range(of: "var body"))
        let elapsedSource = String(live[elapsedStart.lowerBound..<elapsedEnd.lowerBound])
        // Wave 7E L08: LiveSessionCard uses shared RelativeTimeText (not a private
        // fractional-only ISO formatter).
        XCTAssertTrue(
            elapsedSource.contains("RelativeTimeText.format")
                || live.contains("RelativeTimeText.format"),
            "LiveSessionCard.elapsedText must reuse the shared relative-time helper"
        )
        XCTAssertFalse(
            elapsedSource.contains("ISO8601DateFormatter()"),
            "LiveSessionCard.elapsedText must not allocate ISO8601DateFormatter per render"
        )

        let replay = try source("macos/Engram/Models/ReplayState.swift")
        let densityStart = try XCTUnwrap(replay.range(of: "var densityBuckets"))
        let densityEnd = try XCTUnwrap(replay.range(of: "func play()"))
        let densitySource = String(replay[densityStart.lowerBound..<densityEnd.lowerBound])
        XCTAssertTrue(replay.contains("private static let isoFormatter"))
        XCTAssertFalse(
            densitySource.contains("ISO8601DateFormatter()"),
            "ReplayState.densityBuckets runs repeatedly while rendering replay density and must reuse its parser"
        )
        XCTAssertTrue(
            densitySource.contains("max(0, min(99,"),
            "ReplayState.densityBuckets must clamp both lower and upper bucket bounds for out-of-order timestamps"
        )
    }

    func testLogStreamReloadsCancelSupersededWork() throws {
        let s = try source("macos/Engram/Views/Observability/LogStreamView.swift")
        XCTAssertTrue(s.contains("@State private var reloadTask: Task<Void, Never>?"))
        XCTAssertTrue(s.contains("reloadTask?.cancel()"))
        XCTAssertTrue(s.contains(".onDisappear { reloadTask?.cancel(); reloadTask = nil }"))
        XCTAssertFalse(s.contains(".onReceive(timer) { _ in Task { await reload() } }"))
        XCTAssertFalse(s.contains(".onChange(of: selectedLevel) { _, _ in Task { await reload() } }"))
        XCTAssertFalse(s.contains(".onChange(of: selectedModule) { _, _ in Task { await reload() } }"))
    }

    func testSegmentedMessageParsingRunsOffMainThread() throws {
        let s = try source("macos/Engram/Views/ContentSegmentViews.swift")
        XCTAssertTrue(s.contains("@State private var parsedSegments: [ContentSegment] = []"))
        XCTAssertTrue(s.contains(".task(id: content)"))
        XCTAssertTrue(s.contains("Task.detached(priority: .userInitiated)"))
        XCTAssertFalse(
            s.contains("ForEach(segments)"),
            "SegmentedMessageView must not synchronously parse markdown segments from body"
        )
        XCTAssertTrue(
            s.contains("ForEach(Array(displaySegments.enumerated()), id: \\.offset)"),
            "SegmentedMessageView must use positional IDs so repeated segments do not collide in SwiftUI"
        )
        XCTAssertFalse(
            s.contains("ForEach(displaySegments)"),
            "Content-derived ContentSegment.id collides for repeated horizontal rules and repeated content"
        )
    }

    func testMessageParserDoesNotBridgeAsyncAdaptersWithSemaphore() throws {
        let s = try source("macos/Engram/Core/MessageParser.swift")
        XCTAssertFalse(
            s.contains("DispatchSemaphore"),
            "MessageParser must stay async through adapter streams instead of blocking a thread on a semaphore"
        )
        XCTAssertFalse(s.contains("blockingAdapterMessages"))
    }

    func testAppTerminateClosesServiceClientSynchronously() throws {
        let s = try source("macos/Engram/App.swift")
        XCTAssertTrue(s.contains("serviceClient.close()"))
        XCTAssertFalse(
            s.contains("Task.detached { [serviceClient] in\n            await serviceClient.close()"),
            "applicationWillTerminate must not fire-and-forget service client close after returning"
        )
    }

    func testMenuBarAndThemeUseMainActorTrampolinesConsistently() throws {
        let menu = try source("macos/Engram/MenuBarController.swift")
        XCTAssertTrue(menu.contains("@MainActor\nclass MenuBarController"))
        XCTAssertFalse(
            menu.contains("DispatchQueue.main.async"),
            "MenuBarController is MainActor-isolated and should use Task { @MainActor in } for deferred UI work"
        )

        let theme = try source("macos/Engram/Components/Theme.swift")
        XCTAssertFalse(
            theme.contains("DispatchQueue.main.async"),
            "ModernScrollViewConfigurator should use MainActor tasks instead of GCD main-queue trampolines"
        )
        XCTAssertTrue(theme.contains("Task { @MainActor in"))
    }

    func testSettingsLoadsDoNotImmediatelyWriteBackUnchangedValues() throws {
        let ai = try source("macos/Engram/Views/Settings/AISettingsSection.swift")
        XCTAssertTrue(ai.contains("@State private var isLoadingSettings = false"))
        XCTAssertTrue(ai.contains("guard !isLoadingSettings else { return }"))
        XCTAssertFalse(
            ai.contains("defer { isLoadingSettings = false }"),
            "AI settings must keep the loading guard active through the post-load SwiftUI onChange pass"
        )
        XCTAssertTrue(ai.contains("Task { @MainActor in"))
        XCTAssertTrue(ai.contains("await Task.yield()"))

        let advanced = try source("macos/Engram/Views/SettingsView.swift")
        XCTAssertFalse(
            advanced.contains("defer { isLoadingSettings = false }"),
            "Advanced settings must keep the loading guard active through the post-load SwiftUI onChange pass"
        )
        XCTAssertTrue(advanced.contains("Task { @MainActor in"))
        XCTAssertTrue(advanced.contains("await Task.yield()"))

        XCTAssertFalse(
            advanced.contains("NetworkSettingsSection"),
            "Network settings had no remaining implemented controls after peer-sync deletion"
        )

        let sources = try source("macos/Engram/Views/Settings/SourcesSettingsSection.swift")
        XCTAssertFalse(
            sources.contains("TextField(def.defaultPath"),
            "Data source adapter paths are informational; editable fields imply a service override that does not exist"
        )
        XCTAssertFalse(sources.contains("UserDefaults.standard.string(forKey: def.key)"))
        XCTAssertFalse(sources.contains("UserDefaults.standard.set(value, forKey: def.key)"))
        XCTAssertFalse(sources.contains("private func savePath"))
    }

    func testIndexJobSelectionPrioritizesPendingJobsAheadOfRetryableBacklog() throws {
        let runner = try source("macos/EngramCoreWrite/Indexing/IndexJobRunner.swift")
        XCTAssertTrue(
            runner.contains("CASE status WHEN 'pending' THEN 0 ELSE 1 END"),
            "pending jobs must be selected before failed_retryable jobs so old retry backlogs cannot starve fresh work"
        )
        XCTAssertTrue(
            runner.contains("retry_count,\n              created_at"),
            "retryable jobs should be ordered by retry_count before age"
        )
        XCTAssertFalse(
            runner.contains("ORDER BY CASE job_kind WHEN 'fts' THEN 0 ELSE 1 END, created_at, id"),
            "created_at-only ordering lets old retryable FTS rows monopolize the batch"
        )
    }

    func testSkipTierBackfillsRemoveRecoverableIndexArtifacts() throws {
        let s = try source("macos/EngramCoreWrite/Indexing/StartupBackfills.swift")
        XCTAssertTrue(
            s.contains("private static func deleteRecoverableIndexArtifactsForSkippedSession"),
            "skip-tier backfills should share the same FTS/job cleanup helper"
        )
        XCTAssertTrue(s.contains("DELETE FROM sessions_fts"))
        XCTAssertTrue(s.contains("DELETE FROM session_index_jobs"))
        XCTAssertTrue(s.contains("status IN ('pending', 'failed_retryable')"))
        XCTAssertTrue(
            s.contains("try deleteRecoverableIndexArtifactsForSkippedSession(db, sessionId: id)"),
            "single-session backfills that set tier='skip' must remove recoverable jobs for that session"
        )
        XCTAssertTrue(
            s.contains("try deleteRecoverableIndexArtifactsForSkippedSessions(db, whereClause: \"agent_role = 'subagent'\")"),
            "batch subagent downgrade must remove recoverable jobs for all skipped subagents"
        )
    }

    func testPolycliBackfillLeavesGeminiCliForSuggestedParentScoring() throws {
        let s = try source("macos/EngramCoreWrite/Indexing/StartupBackfills.swift")
        let start = try XCTUnwrap(s.range(of: "public static func backfillPolycliProviderParents"))
        let end = try XCTUnwrap(s.range(of: "private static func scoredPolycliHosts"))
        let body = String(s[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(body.contains("let source: String = candidate[\"source\"]"))
        // Wave 7B M18: non-probe rows (including ordinary gemini-cli) are not
        // admitted by the candidate SQL without probe summary evidence.
        XCTAssertTrue(
            body.contains("isPolycliProviderSummary")
                || body.contains("summaryMatches"),
            "polycli admission must require probe/dispatch summary evidence"
        )
        XCTAssertFalse(
            body.contains("AND trim(cwd) != ''\n                )"),
            "bare same-cwd provider admission must stay removed (false-skip)"
        )
    }

    func testIndexJobRunnerMarksSkipTierFtsJobsNotApplicable() throws {
        let s = try source("macos/EngramCoreWrite/Indexing/IndexJobRunner.swift")
        XCTAssertTrue(s.contains("let tier: String?"))
        XCTAssertTrue(s.contains("s.tier AS tier"))
        XCTAssertTrue(
            s.contains("contentSource.tier == SessionTier.skip.rawValue"),
            "recoverable FTS jobs for skip-tier sessions must not rebuild searchable content"
        )
        XCTAssertTrue(s.contains("try Self.markNotApplicable(db, id: job.id)"))
    }

    func testAISettingsRefreshesRuntimeSecretBridgeAfterKeychainWrites() throws {
        let s = try source("macos/Engram/Views/Settings/AISettingsSection.swift")
        XCTAssertTrue(s.contains("private func refreshRuntimeAISecrets()"))
        XCTAssertTrue(s.contains("EngramServiceLauncher.writeRuntimeAISecrets("))
        XCTAssertTrue(s.contains("keychainReader: KeychainHelper.get"))
        XCTAssertTrue(
            s.contains("refreshRuntimeAISecrets()\n        mutateEngramSettings { settings in"),
            "AI settings saves must update the service-readable runtime secret bridge before writing the @keychain marker"
        )
        XCTAssertTrue(
            s.contains("refreshRuntimeAISecrets()\n        mutateEngramSettings { settings in\n            settings[\"titleProvider\"]"),
            "Title settings saves must update the service-readable runtime secret bridge before writing the @keychain marker"
        )
    }

    // Runtime debt repro: an installed Release launch emitted Security.framework
    // performance diagnostics because bundle trust validation ran on MainActor.
    func testKeychainStartupPolicyAvoidsSynchronousTrustEvaluation_repro() throws {
        let s = try source("macos/Engram/Views/Settings/SettingsIO.swift")

        XCTAssertFalse(
            s.contains("SecStaticCodeCheckValidity"),
            "Keychain startup policy must not synchronously validate bundle trust"
        )
        XCTAssertFalse(
            s.contains("kSecCSCheckAllArchitectures"),
            "Keychain startup policy must not validate every executable slice at launch"
        )
        XCTAssertTrue(s.contains("#if DEBUG"), "Debug Keychain bypass must be deterministic at build time")
        XCTAssertTrue(
            s.contains("path.contains(\"DerivedData\")"),
            "Xcode-run builds must retain the DerivedData Keychain bypass"
        )
    }

    func testDatabaseManagerIsNotGlobalMainActorIsolated() throws {
        let s = try source("macos/Engram/Core/Database.swift")
        XCTAssertFalse(
            s.contains("@MainActor\n@Observable\nfinal class DatabaseManager"),
            "DatabaseManager must not rely on a global MainActor annotation while views capture it into Task.detached"
        )
        XCTAssertTrue(s.contains("final class DatabaseManager: @unchecked Sendable"))
        XCTAssertFalse(s.contains("nonisolated(unsafe)"))
    }
}
