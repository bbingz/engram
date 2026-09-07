import EngramCoreRead
import Foundation
import XCTest

@testable import EngramCoreWrite
@testable import EngramServiceCore

final class ArchiveV2RunnerIntegrationTests: XCTestCase {
    func testStartupArchiveFallbackKeepsExactAdaptersUnrestricted_repro() throws {
        let source = try runnerSource()
        let start = try XCTUnwrap(source.range(of: "static func runInitialScan("))
        let end = try XCTUnwrap(
            source.range(of: "private static func elapsedMs", range: start.lowerBound ..< source.endIndex)
        )
        let initialScan = String(source[start.lowerBound ..< end.lowerBound])

        XCTAssertFalse(initialScan.contains("capturedExactLocators ?? [:]"))
        XCTAssertTrue(initialScan.contains("parserAdapters = startupAdapters"))

        let startupTask = try XCTUnwrap(source.range(of: "let initialScanTask = Task"))
        let startupTaskEnd = try XCTUnwrap(
            source.range(of: "let livePublishSignal = LiveIngestPublishSignal()", range: startupTask.lowerBound ..< source.endIndex)
        )
        let startupTaskBody = String(source[startupTask.lowerBound ..< startupTaskEnd.lowerBound])
        XCTAssertTrue(startupTaskBody.contains("await archiveV2Coordinator.captureEnabled"))
    }

    func testRunnerFactoryDefaultsOffWithoutCreatingArchiveStorage() async throws {
        let harness = try makeHarness()

        let settings = ArchiveV2Settings.load(
            settingsURL: harness.root.appendingPathComponent("missing-settings.json"),
            environment: [:]
        )
        let coordinator = EngramServiceRunner.makeArchiveV2Coordinator(
            gate: harness.gate,
            databasePath: harness.database.path,
            settings: settings
        )
        let expected = EngramDatabaseIndexResult(indexed: 3, total: 8, todayParents: 2)

        let result = try await EngramServiceRunner.runArchiveV2IndexCycle(
            coordinator: coordinator,
            captureAdapters: [],
            indexingAdapters: [],
            cursorScope: .full
        ) { _ in
            expected
        }
        let status = await coordinator.status()

        XCTAssertEqual(result.indexResult, expected)
        XCTAssertEqual(result.indexPlan, .unrestricted)
        XCTAssertFalse(status.enabled)
        XCTAssertFalse(status.remoteReplicationEnabled)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: harness.root.appendingPathComponent("archive-v2").path
            ),
            "default-off composition must not create CAS/catalog storage"
        )
    }

    func testArchiveIndexCycleKeepsSuccessfulIndexResultWhenRemoteReplicationFails() async throws {
        let harness = try makeHarness()
        let events = RunnerEventLog()
        let settings = ArchiveV2Settings(
            exactArchiveEnabled: true,
            remoteConfiguration: ArchiveV2RemoteConfiguration(
                enabled: true,
                batchSize: 4,
                replicas: [],
                excludedProjectRoots: []
            ),
            configurationError: nil
        )
        let operations = ArchiveV2ServiceCoordinatorOperations(
            capture: { _, _, _ in
                await events.append("capture")
                return ArchiveV2ServiceCaptureSummary(unsupported: 0, unsafe: 0)
            },
            bindingTargets: { _ in
                await events.append("targets")
                return []
            },
            historicalUnknown: { _ in
                await events.append("historical")
                return ArchiveV2ServiceUnknownPage(targets: [])
            },
            advancePolicyCursor: { _ in await events.append("cursor") },
            snapshot: { _, _ in
                await events.append("snapshot")
                return ArchiveV2ServiceIndexSnapshot(rows: [])
            },
            bindOne: { _, _ in
                await events.append("bind")
                return nil
            },
            applyRemotePolicy: { _, _, _ in await events.append("policy") },
            replicate: { _ in
                await events.append("replicate")
                return ArchiveReplicationCycleResult(cycleError: "transport_failure")
            },
            status: { Self.zeroAggregate() },
            retry: { _ in ArchiveV2ServiceRetryOutcome(resetRows: 0) }
        )
        let coordinator = ArchiveV2ServiceCoordinator(
            settings: settings,
            writerGate: harness.gate,
            remoteReady: true,
            configurationError: nil,
            operations: operations
        )
        let expected = EngramDatabaseIndexResult(indexed: 5, total: 13, todayParents: 1)

        let result = try await EngramServiceRunner.runArchiveV2IndexCycle(
            coordinator: coordinator,
            captureAdapters: [],
            indexingAdapters: [],
            cursorScope: .recent
        ) { _ in
            await events.append("index")
            return expected
        }
        let status = await coordinator.status()

        XCTAssertEqual(result.indexResult, expected)
        XCTAssertEqual(status.lastReplicationError, "transport_failure")
        let recorded = await events.values()
        XCTAssertEqual(
            recorded,
            ["capture", "index", "targets", "historical", "snapshot", "replicate"]
        )
    }

    func testIndexLoopWaitsForInitialScanBeforeStartingPeriodicWork() async {
        let initialGate = RunnerAsyncGate()
        let events = RunnerEventLog()
        let initialScanTask = Task {
            await events.append("initial-start")
            await initialGate.wait()
            await events.append("initial-end")
        }
        await initialGate.waitUntilSuspended()

        let indexingTask = Task {
            await EngramServiceRunner.runAfterInitialScan(initialScanTask: initialScanTask) {
                await events.append("periodic")
            }
        }
        for _ in 0 ..< 10 { await Task.yield() }
        let whileBlocked = await events.values()
        XCTAssertEqual(whileBlocked, ["initial-start"])

        await initialGate.open()
        await indexingTask.value
        let completed = await events.values()
        XCTAssertEqual(completed, ["initial-start", "initial-end", "periodic"])
    }

    func testCancelledIndexLoopDoesNotStartPeriodicWorkAfterInitialScanFinishes() async {
        let initialGate = RunnerAsyncGate()
        let events = RunnerEventLog()
        let initialScanTask = Task {
            await initialGate.wait()
        }
        await initialGate.waitUntilSuspended()

        let indexingTask = Task {
            await EngramServiceRunner.runAfterInitialScan(initialScanTask: initialScanTask) {
                await events.append("periodic")
            }
        }
        indexingTask.cancel()
        await initialGate.open()
        await indexingTask.value

        let recorded = await events.values()
        XCTAssertEqual(recorded, [])
    }

    func testArchiveAdapterProjectionPreservesOnlyExactConformersAndOrder() {
        let recent = SessionAdapterFactory.recentActiveAdapters(
            now: Date(timeIntervalSince1970: 1_700_000_000),
            days: 2
        )
        let expectedSources = recent.compactMap {
            ($0 as? any ExactArchiveSourceAdapter)?.source
        }

        let archiveAdapters = EngramServiceRunner.exactArchiveAdapters(from: recent)

        XCTAssertFalse(archiveAdapters.isEmpty)
        XCTAssertTrue(archiveAdapters.allSatisfy { $0 is any ExactArchiveSourceAdapter })
        XCTAssertEqual(archiveAdapters.map(\.source), expectedSources)
    }

    func testBatchLimitedCaptureAllowlistDefersThirdExactLocatorUntilNextFullCycle() async throws {
        let harness = try makeHarness()
        let events = RunnerEventLog()
        let first = harness.root.appendingPathComponent("first.jsonl").path
        let second = harness.root.appendingPathComponent("second.jsonl").path
        let third = harness.root.appendingPathComponent("third.jsonl").path
        let exact = RunnerParsingExactAdapter(
            source: .codex,
            locators: [first, second, third],
            events: events
        )
        let ordinary = RunnerParsingAdapter(
            source: .kimi,
            locator: harness.root.appendingPathComponent("ordinary.jsonl").path,
            events: events
        )
        let summaries = RunnerCaptureSummaryQueue([
            ArchiveV2ServiceCaptureSummary(
                unsupported: 0,
                unsafe: 0,
                successfulLocators: [.codex: [first, second]],
                hasMore: true
            ),
            ArchiveV2ServiceCaptureSummary(
                unsupported: 0,
                unsafe: 0,
                successfulLocators: [.codex: [third]],
                hasMore: false
            ),
        ])
        let settings = ArchiveV2Settings(
            exactArchiveEnabled: true,
            remoteConfiguration: ArchiveV2RemoteConfiguration(
                enabled: false,
                batchSize: 2,
                replicas: [],
                excludedProjectRoots: []
            ),
            configurationError: nil
        )
        var operations = Self.noopOperations()
        operations.capture = { _, _, _ in
            let summary = try await summaries.next()
            let captured = summary.successfulLocators[.codex] ?? []
            await events.append("capture:\(captured.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ","))")
            return summary
        }
        let coordinator = ArchiveV2ServiceCoordinator(
            settings: settings,
            writerGate: harness.gate,
            remoteReady: false,
            configurationError: nil,
            operations: operations
        )
        let parse: @Sendable ([any SessionAdapter]) async throws -> EngramDatabaseIndexResult = { adapters in
            for adapter in adapters {
                for locator in try await adapter.listSessionLocators() {
                    _ = try await adapter.parseSessionInfo(locator: locator)
                }
            }
            return EngramDatabaseIndexResult(indexed: 0, total: 0, todayParents: 0)
        }

        let firstCycle = try await EngramServiceRunner.runArchiveV2IndexCycle(
            coordinator: coordinator,
            captureAdapters: [exact],
            indexingAdapters: [exact, ordinary],
            cursorScope: .full,
            indexOperation: parse
        )
        XCTAssertEqual(
            firstCycle.indexPlan.capturedExactLocators,
            [.codex: [first, second]]
        )
        let fullPending = await coordinator.needsFullCaptureContinuation()
        XCTAssertTrue(fullPending)

        let continuation = await EngramServiceRunner.archiveCaptureInputsForPeriodicCycle(
            coordinator: coordinator,
            fullAdapters: [exact, ordinary],
            recentAdapters: [ordinary]
        )
        XCTAssertEqual(continuation.cursorScope, .full)
        XCTAssertEqual(continuation.adapters.map(\.source), [.codex])

        let secondCycle = try await EngramServiceRunner.runArchiveV2IndexCycle(
            coordinator: coordinator,
            captureAdapters: continuation.adapters,
            indexingAdapters: [exact, ordinary],
            cursorScope: continuation.cursorScope,
            indexOperation: parse
        )
        XCTAssertEqual(secondCycle.indexPlan.capturedExactLocators, [.codex: [third]])
        let fullDrained = await coordinator.needsFullCaptureContinuation()
        XCTAssertFalse(fullDrained)

        let names = await events.values()
        XCTAssertEqual(
            names,
            [
                "capture:first.jsonl,second.jsonl",
                "parse:codex:first.jsonl",
                "parse:codex:second.jsonl",
                "parse:kimi:ordinary.jsonl",
                "capture:third.jsonl",
                "parse:codex:third.jsonl",
                "parse:kimi:ordinary.jsonl",
            ]
        )
    }

    func testPeriodicAdaptersIncludeBoundedTransientRetryAndStillHonorDisabledSources() async throws {
        let harness = try makeHarness()
        let retryLocator = harness.root
            .appendingPathComponent("aged-out-codex-session.jsonl")
            .path
        let settings = ArchiveV2Settings(
            exactArchiveEnabled: true,
            remoteConfiguration: ArchiveV2RemoteConfiguration(
                enabled: false,
                batchSize: 4,
                replicas: [],
                excludedProjectRoots: []
            ),
            configurationError: nil
        )
        let operations = ArchiveV2ServiceCoordinatorOperations(
            capture: { _, _, _ in
                ArchiveV2ServiceCaptureSummary(
                    unsupported: 0,
                    unsafe: 1,
                    transientRetryLocators: [.codex: [retryLocator]]
                )
            },
            bindingTargets: { _ in [] },
            historicalUnknown: { _ in ArchiveV2ServiceUnknownPage(targets: []) },
            advancePolicyCursor: { _ in },
            snapshot: { _, _ in ArchiveV2ServiceIndexSnapshot(rows: []) },
            bindOne: { _, _ in nil },
            applyRemotePolicy: { _, _, _ in },
            replicate: { _ in ArchiveReplicationCycleResult() },
            status: { Self.zeroAggregate() },
            retry: { _ in ArchiveV2ServiceRetryOutcome(resetRows: 0) }
        )
        let coordinator = ArchiveV2ServiceCoordinator(
            settings: settings,
            writerGate: harness.gate,
            remoteReady: false,
            configurationError: nil,
            operations: operations
        )
        _ = try await coordinator.runCycle(adapters: [], cursorScope: .recent) { _ in
            EngramDatabaseIndexResult(indexed: 0, total: 0, todayParents: 0)
        }

        let enabled = await EngramServiceRunner.recentAdaptersForPeriodicCycle(
            archiveV2Coordinator: coordinator,
            disabledSources: [],
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let codexRetryAdapter = try XCTUnwrap(enabled.last { $0.source == .codex })
        XCTAssertTrue(codexRetryAdapter is any ExactArchiveSourceAdapter)
        let retryAdapterLocators = try await codexRetryAdapter.listSessionLocators()
        XCTAssertEqual(retryAdapterLocators, [retryLocator])

        let disabled = await EngramServiceRunner.recentAdaptersForPeriodicCycle(
            archiveV2Coordinator: coordinator,
            disabledSources: [SourceName.codex.rawValue],
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertFalse(disabled.contains { $0.source == .codex })
    }

    // Audit SRC-001: backlog adapterProvider must reread disabledSources each pass
    // instead of capturing the startup snapshot for the service lifetime.
    func testArchiveBacklogDrainerRereadsDisabledSourcesAfterToggle_repro() throws {
        let harness = try makeHarness()
        let settingsURL = harness.root.appendingPathComponent("settings.json")

        try writeDisabledSources([], to: settingsURL)
        let enabledPass = EngramServiceRunner.exactArchiveAdaptersForBacklogPass(
            environment: [:],
            settingsURL: settingsURL
        )
        XCTAssertTrue(
            enabledPass.contains { $0.source == .codex },
            "first backlog pass must include Codex while enabled"
        )

        try writeDisabledSources([SourceName.codex.rawValue], to: settingsURL)
        let disabledPass = EngramServiceRunner.exactArchiveAdaptersForBacklogPass(
            environment: [:],
            settingsURL: settingsURL
        )
        XCTAssertFalse(
            disabledPass.contains { $0.source == .codex },
            "second backlog pass must drop Codex after mid-life disable"
        )

        try writeDisabledSources([], to: settingsURL)
        let reenabledPass = EngramServiceRunner.exactArchiveAdaptersForBacklogPass(
            environment: [:],
            settingsURL: settingsURL
        )
        XCTAssertTrue(
            reenabledPass.contains { $0.source == .codex },
            "third backlog pass must restore Codex after re-enable"
        )
    }

    private func writeDisabledSources(_ sources: [String], to settingsURL: URL) throws {
        let object: [String: Any] = [
            "disabledSources": sources,
            ArchivedDefaultOffSources.settingsMigrationKey: true,
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        try data.write(to: settingsURL, options: .atomic)
    }

    func testPeriodicMissingLocatorRetriesAndClearsAfterLaterCaptureSuccess() async throws {
        let harness = try makeHarness()
        let missing = harness.root.appendingPathComponent("later-created.jsonl")
        let summaries = RunnerCaptureSummaryQueue([
            ArchiveV2ServiceCoordinator.captureSummary(from: ArchiveCaptureCycleResult(
                items: [ArchiveCaptureCycleItem(
                    source: .codex,
                    locator: missing.path,
                    classification: .missing,
                    captureID: nil,
                    diagnostic: nil
                )],
                captures: []
            )),
            ArchiveV2ServiceCoordinator.captureSummary(from: ArchiveCaptureCycleResult(
                items: [ArchiveCaptureCycleItem(
                    source: .codex,
                    locator: missing.path,
                    classification: .declaredSingleFile(missing),
                    captureID: String(repeating: "a", count: 64),
                    diagnostic: nil
                )],
                captures: []
            )),
        ])
        let settings = ArchiveV2Settings(
            exactArchiveEnabled: true,
            remoteConfiguration: ArchiveV2RemoteConfiguration(
                enabled: false,
                batchSize: 4,
                replicas: [],
                excludedProjectRoots: []
            ),
            configurationError: nil
        )
        var operations = Self.noopOperations()
        operations.capture = { _, _, _ in try await summaries.next() }
        let coordinator = ArchiveV2ServiceCoordinator(
            settings: settings,
            writerGate: harness.gate,
            remoteReady: false,
            configurationError: nil,
            operations: operations
        )

        _ = try await coordinator.runCycle(adapters: [], cursorScope: .recent) { _ in
            EngramDatabaseIndexResult(indexed: 0, total: 0, todayParents: 0)
        }
        let retryAdapters = await EngramServiceRunner.recentAdaptersForPeriodicCycle(
            archiveV2Coordinator: coordinator,
            disabledSources: [],
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let retryAdapter = try XCTUnwrap(retryAdapters.last { $0.source == .codex })
        let retryLocators = try await retryAdapter.listSessionLocators()
        XCTAssertEqual(retryLocators, [missing.path])

        try Data("captured later\n".utf8).write(to: missing)
        _ = try await coordinator.runCycle(
            adapters: EngramServiceRunner.exactArchiveAdapters(from: retryAdapters),
            cursorScope: .recent
        ) { _ in
            EngramDatabaseIndexResult(indexed: 0, total: 0, todayParents: 0)
        }

        let retryState = await coordinator.recentCaptureRetryLocators(maximumPerSource: 100)
        XCTAssertEqual(retryState, [:])
    }

    func testCompositionUsesOneCoordinatorAndV2PrecedesLegacyRemoteOffload() throws {
        let source = try runnerSource()
        XCTAssertEqual(
            source.components(separatedBy: "ArchiveV2ServiceCoordinator.make(").count - 1,
            1,
            "composition root must create exactly one Archive V2 coordinator"
        )

        let composition = try XCTUnwrap(
            source.range(of: "let archiveV2Coordinator = Self.makeArchiveV2Coordinator(")
        )
        let handler = try XCTUnwrap(source.range(of: "let handler = EngramServiceCommandHandler("))
        XCTAssertLessThan(composition.lowerBound, handler.lowerBound)

        let handlerEnd = try XCTUnwrap(
            source.range(of: "let server = UnixSocketServiceServer", range: handler.lowerBound ..< source.endIndex)
        )
        let handlerBlock = String(source[handler.lowerBound ..< handlerEnd.lowerBound])
        XCTAssertTrue(handlerBlock.contains("archiveV2Coordinator: archiveV2Coordinator"))

        let initialTask = try XCTUnwrap(source.range(of: "let initialScanTask = Task"))
        let initialTaskEnd = try XCTUnwrap(
            source.range(of: "let livePublishSignal = LiveIngestPublishSignal()", range: initialTask.lowerBound ..< source.endIndex)
        )
        let initialBlock = String(source[initialTask.lowerBound ..< initialTaskEnd.lowerBound])
        XCTAssertTrue(initialBlock.contains("archiveV2Coordinator: archiveV2Coordinator"))

        let initialScanStart = try XCTUnwrap(source.range(of: "static func runInitialScan("))
        let initialScanEnd = try XCTUnwrap(
            source.range(of: "private static func elapsedMs", range: initialScanStart.lowerBound ..< source.endIndex)
        )
        let initialScanBlock = String(source[initialScanStart.lowerBound ..< initialScanEnd.lowerBound])
        let archiveWrappedIndex = try XCTUnwrap(
            initialScanBlock.range(of: "runInitialArchiveV2IndexPhase(")
        )
        let firstTargetedParser = try XCTUnwrap(
            initialScanBlock.range(of: #"name: "initialInstructionBackfill""#)
        )
        XCTAssertLessThan(
            archiveWrappedIndex.lowerBound,
            firstTargetedParser.lowerBound,
            "exact capture must precede every startup phase that parses transcripts"
        )
        let defaultOffIndex = try XCTUnwrap(
            initialScanBlock.range(of: #"name: "initialScanIndex""#)
        )
        XCTAssertLessThan(
            firstTargetedParser.lowerBound,
            defaultOffIndex.lowerBound,
            "default-off startup must preserve the legacy targeted-backfill ordering"
        )
        XCTAssertTrue(initialScanBlock.contains("if archiveV2CaptureEnabled"))
        XCTAssertTrue(initialScanBlock.contains("if !archiveV2CaptureEnabled"))

        let archivePhaseHelperStart = try XCTUnwrap(
            source.range(of: "private static func runInitialArchiveV2IndexPhase(")
        )
        let runInitialStart = try XCTUnwrap(
            source.range(of: "static func runInitialScan(", range: archivePhaseHelperStart.lowerBound ..< source.endIndex)
        )
        let archivePhaseHelper = String(source[archivePhaseHelperStart.lowerBound ..< runInitialStart.lowerBound])
        XCTAssertTrue(archivePhaseHelper.contains("runArchiveV2IndexCycle("))

        let indexingTask = try XCTUnwrap(source.range(of: "let indexingTask = Task"))
        let truncateTask = try XCTUnwrap(
            source.range(of: "// Best-effort startup TRUNCATE", range: indexingTask.lowerBound ..< source.endIndex)
        )
        let indexingBlock = String(source[indexingTask.lowerBound ..< truncateTask.lowerBound])
        let waitForInitial = try XCTUnwrap(indexingBlock.range(of: "runAfterInitialScan("))
        let startLoop = try XCTUnwrap(indexingBlock.range(of: "runIndexingLoop("))
        XCTAssertLessThan(waitForInitial.lowerBound, startLoop.lowerBound)
        XCTAssertTrue(indexingBlock.contains("archiveV2Coordinator: archiveV2Coordinator"))

        let loopStart = try XCTUnwrap(source.range(of: "static func runIndexingLoop("))
        let loopEnd = try XCTUnwrap(
            source.range(of: "private static func runOnePeriodicIndexCycle(", range: loopStart.lowerBound ..< source.endIndex)
        )
        let loopBlock = String(source[loopStart.lowerBound ..< loopEnd.lowerBound])
        XCTAssertTrue(loopBlock.contains("await archiveV2Coordinator?.recordNextScheduledCycle("))
        XCTAssertTrue(loopBlock.contains("Date().addingTimeInterval(sleepSeconds)"))
        XCTAssertTrue(
            loopBlock.contains("withBacklogDrainPaused"),
            "the whole periodic maintenance cycle must exclude archive backlog passes"
        )

        let waitHelperStart = try XCTUnwrap(source.range(of: "static func runAfterInitialScan("))
        let waitHelperEnd = try XCTUnwrap(
            source.range(of: "static func runArchiveV2IndexCycle(", range: waitHelperStart.lowerBound ..< source.endIndex)
        )
        let waitHelper = String(source[waitHelperStart.lowerBound ..< waitHelperEnd.lowerBound])
        XCTAssertTrue(waitHelper.contains("await initialScanTask.value"))
        XCTAssertTrue(waitHelper.contains("guard !Task.isCancelled else { return }"))

        let periodicStart = try XCTUnwrap(source.range(of: "private static func runOnePeriodicIndexCycle("))
        let periodicEnd = try XCTUnwrap(
            source.range(of: "private final class IndexingScheduleBox", range: periodicStart.lowerBound ..< source.endIndex)
        )
        let periodicBlock = String(source[periodicStart.lowerBound ..< periodicEnd.lowerBound])
        XCTAssertTrue(periodicBlock.contains("recentAdaptersForPeriodicCycle("))
        XCTAssertTrue(periodicBlock.contains("archiveV2Coordinator: archiveV2Coordinator"))
        XCTAssertTrue(periodicBlock.contains("archiveCaptureInputsForPeriodicCycle("))
        XCTAssertTrue(periodicBlock.contains("indexRecentSessions("))
        XCTAssertTrue(periodicBlock.contains("adapters: parserAdapters"))
        XCTAssertTrue(periodicBlock.contains("excludedSnapshotSources: excludedSnapshotSources"))
        XCTAssertTrue(periodicBlock.contains("drainRecoverableFtsJobs("))
        XCTAssertTrue(periodicBlock.contains("adapters: enabledAdapters"))
        XCTAssertTrue(source.contains("IndexJobRunner(writer: writer, adapters: adapters)"))

        let retryHelperStart = try XCTUnwrap(source.range(of: "static func recentAdaptersForPeriodicCycle("))
        let retryHelperEnd = try XCTUnwrap(
            source.range(of: "private static func runObservabilityRetention(", range: retryHelperStart.lowerBound ..< source.endIndex)
        )
        let retryHelper = String(source[retryHelperStart.lowerBound ..< retryHelperEnd.lowerBound])
        XCTAssertTrue(retryHelper.contains("recentCaptureRetryLocators("))
        XCTAssertTrue(retryHelper.contains("priorTransientRetryLocators:"))
        XCTAssertEqual(
            retryHelper.components(separatedBy: "SessionAdapterFactory.maximumTransientRetryLocatorsPerSource").count - 1,
            2,
            "coordinator and adapter factory must share the same bounded retry limit"
        )
        let archiveV2 = try XCTUnwrap(periodicBlock.range(of: "runArchiveV2IndexCycle("))
        let legacyRemote = try XCTUnwrap(periodicBlock.range(of: "remoteSync.runOnce()"))
        XCTAssertLessThan(archiveV2.lowerBound, legacyRemote.lowerBound)

        for parserUse in [
            "indexInstructionBackfillSessions(adapters: parserAdapters)",
            "indexImplementationBeatBackfillSessions(adapters: parserAdapters)",
            "WriterStartupIndexing(",
            "adapters: parserAdapters",
            "IndexJobRunner(writer: writer, adapters: startupAdapters)",
        ] {
            XCTAssertTrue(initialScanBlock.contains(parserUse), "missing capture-safe startup parser path: \(parserUse)")
        }
        XCTAssertTrue(initialScanBlock.contains("excludedSnapshotSources: excludedSnapshotSources"))
    }

    func testLiveCoordinatorIsIndependentOfOffloadRunOnce_repro() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let home = harness.root.appendingPathComponent("home", isDirectory: true)
        let store = harness.root.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        _ = try await harness.gate.performWriteCommand(name: "liveIndependenceSeed") { writer in
            try writer.migrate()
            try writer.write { db in
                try db.execute(sql: """
                    INSERT INTO sessions (
                      id, source, start_time, end_time, cwd, project, file_path,
                      message_count, user_message_count, assistant_message_count,
                      summary, size_bytes, indexed_at, tier, offload_state
                    ) VALUES (
                      'live-independent', 'codex', '2020-01-01T00:00:00Z',
                      '2020-01-01T01:00:00Z', '/tmp/live-independent', 'engram',
                      '/tmp/live-independent.jsonl', 2, 1, 1,
                      'live publish must not offload', 8192, '2020-01-01T01:00:00Z',
                      'premium', 'local'
                    );
                    INSERT INTO sessions_fts(session_id, content) VALUES
                      ('live-independent', 'user live independence request'),
                      ('live-independent', 'assistant live independence response');
                    """)
            }
        }

        let inner = try LocalDirectoryBackend(root: store)
        let backend = RunnerRecordingRemoteStorageBackend(inner: inner)
        let coordinator = RemoteSyncCoordinator(
            gate: harness.gate,
            backend: backend,
            config: RemoteSyncConfig(
                enabled: true,
                storeRoot: store,
                policy: OffloadPolicy(coldAgeDays: 0, minResidencyHours: 0),
                offloadBatch: 20,
                rehydrateBatch: 20,
                vacuumFreelistThreshold: 1_000_000
            ),
            peer: "hq"
        )
        let environment = [
            "HOME": home.path,
            "CFFIXED_USER_HOME": home.path,
            "XCTestConfigurationFilePath": "hermetic",
            "ENGRAM_LIVE_PUBLISH_ENABLED": "true",
            "ENGRAM_LIVE_INGEST_PEER": "hq",
        ]

        let published = await EngramServiceRunner.runLiveIngestCycle(
            coordinator: coordinator,
            environment: environment,
            debouncePublish: false,
            completeWalk: true
        )
        let observations = await backend.observations()
        let persisted = try await harness.gate.performReadCommand(name: "liveIndependenceVerify") { writer in
            try writer.read { db in
                (
                    try String.fetchOne(
                        db,
                        sql: "SELECT offload_state FROM sessions WHERE id = 'live-independent'"
                    ),
                    try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM sessions_fts WHERE session_id = 'live-independent'"
                    ) ?? 0,
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM offload_queue") ?? 0
                )
            }
        }.value

        XCTAssertTrue(published)
        XCTAssertTrue(observations.putKeys.contains(LiveIngestKeys.head(peer: "hq")))
        XCTAssertTrue(observations.putKeys.contains { $0.hasPrefix("live.hq.") })
        XCTAssertEqual(persisted.0, "local")
        XCTAssertEqual(persisted.1, 2)
        XCTAssertEqual(persisted.2, 0, "the live runner must never enqueue offload work")
    }

    func testLiveRunnerUsesSteadyStatePublishModeAfterInitialCycle_repro() throws {
        let source = try runnerSource()
        let loopStart = try XCTUnwrap(source.range(of: "static func runLiveIngestLoop("))
        let loopEnd = try XCTUnwrap(
            source.range(of: "static func runIndexingLoop(", range: loopStart.lowerBound ..< source.endIndex)
        )
        let loop = String(source[loopStart.lowerBound ..< loopEnd.lowerBound])

        XCTAssertTrue(loop.contains("var completePublishWalk = true"))
        XCTAssertTrue(loop.contains("completeWalk: completePublishWalk"))
        XCTAssertTrue(
            loop.contains("completePublishWalk = false"),
            "only the initial successful publish may force a complete corpus walk"
        )
        XCTAssertFalse(
            loop.contains("completeWalk: true"),
            "steady-state cycles must use the bounded dirty-row publish mode"
        )
    }

    func testLiveRunnerIdlePublisherUsesConfiguredTimerInterval_repro() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let home = harness.root.appendingPathComponent("home", isDirectory: true)
        let store = harness.root.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        _ = try await harness.gate.performWriteCommand(name: "liveIdleMigrate") { try $0.migrate() }

        let coordinator = RemoteSyncCoordinator(
            gate: harness.gate,
            backend: try LocalDirectoryBackend(root: store),
            config: RemoteSyncConfig(
                enabled: true,
                storeRoot: store,
                policy: OffloadPolicy(coldAgeDays: 90),
                offloadBatch: 20,
                rehydrateBatch: 20,
                vacuumFreelistThreshold: 1_000_000
            ),
            peer: "hq"
        )
        let clock = RunnerLiveIngestIdleClock()
        let environment = [
            "HOME": home.path,
            "CFFIXED_USER_HOME": home.path,
            "XCTestConfigurationFilePath": "hermetic",
            "ENGRAM_LIVE_PUBLISH_ENABLED": "true",
            "ENGRAM_LIVE_INGEST_PEER": "hq",
            "ENGRAM_LIVE_INGEST_INTERVAL_SECONDS": "900",
        ]

        await EngramServiceRunner.runLiveIngestLoop(
            coordinator: coordinator,
            gate: harness.gate,
            environment: environment,
            sleep: { try await clock.sleep(nanoseconds: $0) }
        )

        let sleepSeconds = await clock.sleepSeconds()
        XCTAssertEqual(
            sleepSeconds,
            [60, 900],
            "an idle HQ publisher must debounce its initial indexed state once, then return to the configured timer"
        )
    }

    func testLiveRunnerPublishesWithinDebounceSoIndependentPullMeetsSixteenMinuteSLA_repro() async throws {
        let hq = try makeHarness()
        let mac = try makeHarness()
        defer {
            try? FileManager.default.removeItem(at: hq.root)
            try? FileManager.default.removeItem(at: mac.root)
        }
        let hqHome = hq.root.appendingPathComponent("home", isDirectory: true)
        let macHome = mac.root.appendingPathComponent("home", isDirectory: true)
        let store = hq.root.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: hqHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: macHome, withIntermediateDirectories: true)
        _ = try await hq.gate.performWriteCommand(name: "liveSLAMigrateHQ") { try $0.migrate() }
        _ = try await mac.gate.performWriteCommand(name: "liveSLAMigrateMac") { try $0.migrate() }

        let backend = RunnerRecordingRemoteStorageBackend(
            inner: try LocalDirectoryBackend(root: store)
        )
        let remoteConfig = RemoteSyncConfig(
            enabled: true,
            storeRoot: store,
            policy: OffloadPolicy(coldAgeDays: 90),
            offloadBatch: 20,
            rehydrateBatch: 20,
            vacuumFreelistThreshold: 1_000_000
        )
        let hqCoordinator = RemoteSyncCoordinator(
            gate: hq.gate,
            backend: backend,
            config: remoteConfig,
            peer: "hq"
        )
        let macCoordinator = RemoteSyncCoordinator(
            gate: mac.gate,
            backend: backend,
            config: remoteConfig,
            peer: "mac"
        )
        let environment = [
            "HOME": hqHome.path,
            "CFFIXED_USER_HOME": hqHome.path,
            "XCTestConfigurationFilePath": "hermetic",
            "ENGRAM_LIVE_PUBLISH_ENABLED": "true",
            "ENGRAM_LIVE_INGEST_PEER": "hq",
            "ENGRAM_LIVE_INGEST_INTERVAL_SECONDS": "900",
        ]
        let publishSignal = LiveIngestPublishSignal()
        let clock = RunnerLiveIngestSLAClock(
            hqGate: hq.gate,
            macGate: mac.gate,
            macCoordinator: macCoordinator,
            environment: environment,
            publishSignal: publishSignal,
            pullIntervalSeconds: 900
        )

        await EngramServiceRunner.runLiveIngestLoop(
            coordinator: hqCoordinator,
            gate: hq.gate,
            environment: environment,
            publishSignal: publishSignal,
            sleep: { try await clock.sleep(nanoseconds: $0) }
        )

        let outcome = await clock.outcome()
        let observations = await backend.observations()
        XCTAssertEqual(outcome.indexedAtSeconds, 61)
        XCTAssertNotNil(outcome.importedAtSeconds, "the deterministic puller must receive the tail")
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(outcome.importedAtSeconds) - outcome.indexedAtSeconds,
            960,
            "60-second publish debounce plus a 900-second pull interval is the accepted 16-minute bound"
        )
        XCTAssertEqual(
            Array(outcome.sleepSeconds.prefix(3)),
            [60, 900, 60],
            "the idle timer must remain 900 seconds and an index signal must replace it with one 60-second debounce"
        )
        XCTAssertEqual(
            observations.putKeys.filter { $0 == LiveIngestKeys.head(peer: "hq") }.count,
            2,
            "one initial complete head and one debounced changed head must publish before the pull imports the tail"
        )
    }

    func testLiveRunnerPullsAtServiceReadyWhilePublisherWaitsForInitialScan_repro() async throws {
        let hq = try makeHarness()
        let mac = try makeHarness()
        defer {
            try? FileManager.default.removeItem(at: hq.root)
            try? FileManager.default.removeItem(at: mac.root)
        }
        let hqHome = hq.root.appendingPathComponent("home", isDirectory: true)
        let macHome = mac.root.appendingPathComponent("home", isDirectory: true)
        let store = hq.root.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: hqHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: macHome, withIntermediateDirectories: true)
        _ = try await hq.gate.performWriteCommand(name: "readyPullMigrateHQ") { try $0.migrate() }
        _ = try await mac.gate.performWriteCommand(name: "readyPullMigrateMac") { try $0.migrate() }
        _ = try await hq.gate.performWriteCommand(name: "readyPullSeed") { writer in
            try writer.write { db in
                try db.execute(sql: """
                    INSERT INTO sessions (
                      id, source, start_time, end_time, cwd, project, file_path,
                      message_count, user_message_count, assistant_message_count,
                      summary, size_bytes, indexed_at, tier, offload_state
                    ) VALUES (
                      'ready-pull', 'codex', '2026-08-30T01:00:00Z',
                      '2026-08-30T01:01:00Z', '/tmp/ready-pull', 'engram',
                      '/tmp/ready-pull.jsonl', 2, 1, 1, 'ready pull', 8192,
                      '2026-08-30T01:01:00Z', 'premium', 'local'
                    );
                    INSERT INTO sessions_fts(session_id, content)
                    VALUES ('ready-pull', 'service ready pull before initial scan');
                    """)
            }
        }

        let backend = RunnerRecordingRemoteStorageBackend(
            inner: try LocalDirectoryBackend(root: store)
        )
        let remoteConfig = RemoteSyncConfig(
            enabled: true,
            storeRoot: store,
            policy: OffloadPolicy(coldAgeDays: 90),
            offloadBatch: 20,
            rehydrateBatch: 20,
            vacuumFreelistThreshold: 1_000_000
        )
        let hqCoordinator = RemoteSyncCoordinator(
            gate: hq.gate,
            backend: backend,
            config: remoteConfig,
            peer: "hq"
        )
        let macCoordinator = RemoteSyncCoordinator(
            gate: mac.gate,
            backend: backend,
            config: remoteConfig,
            peer: "mac"
        )
        let hqEnvironment = [
            "HOME": hqHome.path,
            "CFFIXED_USER_HOME": hqHome.path,
            "XCTestConfigurationFilePath": "hermetic",
            "ENGRAM_LIVE_PUBLISH_ENABLED": "true",
            "ENGRAM_LIVE_INGEST_PEER": "hq",
        ]
        let macEnvironment = [
            "HOME": macHome.path,
            "CFFIXED_USER_HOME": macHome.path,
            "XCTestConfigurationFilePath": "hermetic",
            "ENGRAM_LIVE_INGEST_ENABLED": "true",
            "ENGRAM_LIVE_INGEST_PEER": "hq",
            "ENGRAM_LIVE_INGEST_SOURCES": "hq",
            "ENGRAM_LIVE_INGEST_INTERVAL_SECONDS": "900",
        ]
        let initialPublished = await EngramServiceRunner.runLiveIngestCycle(
            coordinator: hqCoordinator,
            environment: hqEnvironment,
            debouncePublish: false,
            completeWalk: true
        )
        XCTAssertTrue(initialPublished)
        await backend.resetObservations()

        let macInitialGate = RunnerAsyncGate()
        let hqInitialGate = RunnerAsyncGate()
        let macInitialScan = Task { await macInitialGate.wait() }
        let hqInitialScan = Task { await hqInitialGate.wait() }
        await macInitialGate.waitUntilSuspended()
        await hqInitialGate.waitUntilSuspended()

        let macReadyPullCompleted = expectation(description: "Mac ready pull completed")
        let hqClock = RunnerLiveIngestIdleClock()
        let macLoop = Task {
            await EngramServiceRunner.runLiveIngestLoop(
                coordinator: macCoordinator,
                gate: mac.gate,
                environment: macEnvironment,
                publisherReadyTask: macInitialScan,
                sleep: { _ in
                    macReadyPullCompleted.fulfill()
                    throw CancellationError()
                }
            )
        }
        let hqLoop = Task {
            await EngramServiceRunner.runLiveIngestLoop(
                coordinator: hqCoordinator,
                gate: hq.gate,
                environment: hqEnvironment,
                publisherReadyTask: hqInitialScan,
                sleep: { try await hqClock.sleep(nanoseconds: $0) }
            )
        }
        await fulfillment(of: [macReadyPullCompleted], timeout: 2)
        for _ in 0 ..< 100 { await Task.yield() }

        let imported = try await mac.gate.performReadCommand(name: "readyPullVerify") { writer in
            try writer.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM sessions WHERE id = ? AND origin = 'hq'",
                    arguments: [ImportRepo.importedLocalId(peer: "hq", sessionId: "ready-pull")]
                ) ?? 0
            }
        }.value
        let observations = await backend.observations()
        XCTAssertEqual(imported, 1, "the ready-time Mac pull must not wait for initial scan completion")
        XCTAssertFalse(
            observations.putKeys.contains(LiveIngestKeys.head(peer: "hq")),
            "HQ must not publish its initial complete walk while initial scan is suspended"
        )

        macLoop.cancel()
        hqLoop.cancel()
        await macInitialGate.open()
        await hqInitialGate.open()
        await macLoop.value
        await hqLoop.value
        await macInitialScan.value
        await hqInitialScan.value
    }

    func testLivePublishSignalUsesActualReadyDeltaThroughWriterGate_repro() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let home = harness.root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        _ = try await harness.gate.performWriteCommand(name: "liveDeltaMigrate") { writer in
            try writer.migrate()
            try writer.write { db in
                try db.execute(sql: """
                    INSERT INTO sessions (
                      id, source, start_time, file_path, message_count,
                      sync_version, snapshot_hash, tier, offload_state
                    ) VALUES
                      ('skip', 'codex', '2026-08-30T00:00:00Z', '/tmp/skip.jsonl', 1,
                       1, 'skip-v1', 'skip', 'local'),
                      ('imported', 'codex', '2026-08-30T00:01:00Z', '/tmp/imported.jsonl', 1,
                       1, 'imported-v1', 'premium', 'local'),
                      ('unready', 'codex', '2026-08-30T00:02:00Z', '/tmp/unready.jsonl', 1,
                       1, 'unready-v1', 'premium', 'local');
                    UPDATE sessions SET origin = 'hq' WHERE id = 'imported';
                    INSERT INTO sessions_fts(session_id, content) VALUES
                      ('skip', 'skip noise'),
                      ('imported', 'imported noise'),
                      ('unready', 'stale unready content');
                    INSERT INTO session_index_jobs(
                      id, session_id, job_kind, target_sync_version, status
                    ) VALUES ('unready:1:fts', 'unready', 'fts', 1, 'pending');
                    """)
            }
        }
        let environment = [
            "HOME": home.path,
            "CFFIXED_USER_HOME": home.path,
            "XCTestConfigurationFilePath": "hermetic",
            "ENGRAM_LIVE_PUBLISH_ENABLED": "true",
            "ENGRAM_LIVE_INGEST_PEER": "hq",
            "ENGRAM_LIVE_INGEST_INTERVAL_SECONDS": "900",
        ]
        let signal = LiveIngestPublishSignal()
        let clock = RunnerLivePublishSignalClock()
        let generationBefore = await harness.gate.currentDatabaseGeneration()

        await EngramServiceRunner.signalLivePublishIfNeeded(
            gate: harness.gate,
            environment: environment,
            publishSignal: signal
        )
        do {
            _ = try await signal.wait(
                intervalNanoseconds: 900_000_000_000,
                debounceNanoseconds: 60_000_000_000,
                respondsToIndexChanges: true,
                sleep: { try await clock.recordThenStop(nanoseconds: $0) }
            )
            XCTFail("the probe sleep must stop the idle wait")
        } catch RunnerLivePublishSignalProbeError.stop {
            // Expected: no real delta means the signal remains on its idle timer.
        } catch {
            XCTFail("unexpected idle signal probe error: \(error)")
        }
        let idleSleeps = await clock.sleepSeconds()
        XCTAssertEqual(idleSleeps, [900])

        _ = try await harness.gate.performWriteCommand(name: "liveDeltaReadySeed") { writer in
            try writer.write { db in
                try db.execute(sql: """
                    INSERT INTO sessions (
                      id, source, start_time, file_path, message_count,
                      sync_version, snapshot_hash, tier, offload_state
                    ) VALUES (
                      'ready', 'codex', '2026-08-30T00:03:00Z', '/tmp/ready.jsonl', 1,
                      1, 'ready-v1', 'premium', 'local'
                    );
                    INSERT INTO sessions_fts(session_id, content)
                    VALUES ('ready', 'ready publishable delta');
                    """)
            }
        }
        let generationAfterSeed = await harness.gate.currentDatabaseGeneration()
        await EngramServiceRunner.signalLivePublishIfNeeded(
            gate: harness.gate,
            environment: environment,
            publishSignal: signal
        )
        let wake = try await signal.wait(
            intervalNanoseconds: 900_000_000_000,
            debounceNanoseconds: 60_000_000_000,
            respondsToIndexChanges: true,
            sleep: { await clock.record(nanoseconds: $0) }
        )

        let deltaSleeps = await clock.sleepSeconds()
        let generationAfterProbe = await harness.gate.currentDatabaseGeneration()
        XCTAssertEqual(wake, .indexChanged(changeGeneration: 1))
        XCTAssertEqual(deltaSleeps, [900, 60])
        XCTAssertEqual(generationBefore + 1, generationAfterSeed)
        XCTAssertEqual(
            generationAfterProbe,
            generationAfterSeed,
            "the delta probe must remain a read-only ServiceWriterGate command"
        )
    }

    func testLivePublishSignalCoalescesRepeatedLevelTrueProbeWithinArmedDebounce_repro() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let home = harness.root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        _ = try await harness.gate.performWriteCommand(name: "liveLevelSignalMigrate") { writer in
            try writer.migrate()
            try writer.write { db in
                try db.execute(sql: """
                    INSERT INTO sessions (
                      id, source, start_time, file_path, message_count,
                      sync_version, snapshot_hash, tier, offload_state
                    ) VALUES (
                      'level-ready', 'codex', '2026-08-30T00:00:00Z',
                      '/tmp/level-ready.jsonl', 1, 1, 'level-ready-v1',
                      'premium', 'local'
                    );
                    INSERT INTO sessions_fts(session_id, content)
                    VALUES ('level-ready', 'level-triggered publish delta');
                    """)
            }
        }
        let environment = [
            "HOME": home.path,
            "CFFIXED_USER_HOME": home.path,
            "XCTestConfigurationFilePath": "hermetic",
            "ENGRAM_LIVE_PUBLISH_ENABLED": "true",
            "ENGRAM_LIVE_INGEST_PEER": "hq",
            "ENGRAM_LIVE_INGEST_INTERVAL_SECONDS": "900",
        ]
        let signal = LiveIngestPublishSignal()
        await EngramServiceRunner.signalLivePublishIfNeeded(
            gate: harness.gate,
            environment: environment,
            publishSignal: signal
        )
        let clock = RunnerRepeatedLiveDeltaClock(
            gate: harness.gate,
            environment: environment,
            signal: signal
        )

        let wake = try await signal.wait(
            intervalNanoseconds: 900_000_000_000,
            debounceNanoseconds: 60_000_000_000,
            respondsToIndexChanges: true,
            sleep: { try await clock.sleep(nanoseconds: $0) }
        )

        let sleepSeconds = await clock.sleepSeconds()
        let noOpGenerationAdvance = await clock.noOpGenerationAdvance()
        XCTAssertEqual(wake, .indexChanged(changeGeneration: 1))
        XCTAssertEqual(
            sleepSeconds,
            [60],
            "the same level-true delta must not keep extending an already-armed deadline"
        )
        XCTAssertEqual(
            noOpGenerationAdvance,
            1,
            "a successful zero-row write must advance the gate generation without becoming a publish mutation epoch"
        )
    }

    func testLivePublishSignalDebouncesGenerationArrivingAtTimerCompletion_repro() async throws {
        let signal = LiveIngestPublishSignal()
        let clock = RunnerTimerBoundarySignalClock(signal: signal)

        let wake = try await signal.wait(
            intervalNanoseconds: 900_000_000_000,
            debounceNanoseconds: 60_000_000_000,
            respondsToIndexChanges: true,
            sleep: { try await clock.sleep(nanoseconds: $0) }
        )

        let sleepSeconds = await clock.sleepSeconds()
        XCTAssertEqual(wake, .indexChanged(changeGeneration: 1))
        XCTAssertEqual(
            sleepSeconds,
            [900, 60],
            "a generation at timer completion must receive its own trailing debounce"
        )
    }

    func testLivePublishSignalIdleTimerWakeUsesGenerationZero_repro() async throws {
        let signal = LiveIngestPublishSignal()
        let clock = RunnerLivePublishSignalClock()

        let wake = try await signal.wait(
            intervalNanoseconds: 900_000_000_000,
            debounceNanoseconds: 60_000_000_000,
            respondsToIndexChanges: true,
            sleep: { await clock.record(nanoseconds: $0) }
        )

        let sleepSeconds = await clock.sleepSeconds()
        XCTAssertEqual(wake, .timer(changeGeneration: 0))
        XCTAssertEqual(sleepSeconds, [900])
    }

    func testLivePublishSignalRearmsSameResidualTokenAfterPublishedGeneration_repro() async throws {
        let signal = LiveIngestPublishSignal()
        let tokenA = runnerReadyDeltaToken(id: "residual", snapshotHash: "a")
        let firstClock = RunnerLivePublishSignalClock()

        await signal.signalIndexChange(token: tokenA)
        let firstWake = try await signal.wait(
            intervalNanoseconds: 900_000_000_000,
            debounceNanoseconds: 60_000_000_000,
            respondsToIndexChanges: true,
            sleep: { await firstClock.record(nanoseconds: $0) }
        )
        await signal.markPublished(through: firstWake.changeGeneration)
        await signal.signalIndexChange(token: tokenA)

        let secondClock = RunnerLivePublishSignalClock()
        let secondWake = try await signal.wait(
            intervalNanoseconds: 900_000_000_000,
            debounceNanoseconds: 60_000_000_000,
            respondsToIndexChanges: true,
            sleep: { await secondClock.record(nanoseconds: $0) }
        )

        let firstSleepSeconds = await firstClock.sleepSeconds()
        let secondSleepSeconds = await secondClock.sleepSeconds()
        XCTAssertEqual(firstWake, .indexChanged(changeGeneration: 1))
        XCTAssertEqual(secondWake, .indexChanged(changeGeneration: 2))
        XCTAssertEqual(firstSleepSeconds, [60])
        XCTAssertEqual(secondSleepSeconds, [60])
    }

    func testLivePublishSignalTracksABATokensAndPreservesNewerGeneration_repro() async throws {
        let signal = LiveIngestPublishSignal()
        let tokenA = runnerReadyDeltaToken(id: "aba", snapshotHash: "a")
        let tokenB = runnerReadyDeltaToken(id: "aba", snapshotHash: "b")
        let firstClock = RunnerLivePublishSignalClock()

        await signal.signalIndexChange(token: tokenA)
        let firstWake = try await signal.wait(
            intervalNanoseconds: 900_000_000_000,
            debounceNanoseconds: 60_000_000_000,
            respondsToIndexChanges: true,
            sleep: { await firstClock.record(nanoseconds: $0) }
        )
        await signal.signalIndexChange(token: tokenB)
        await signal.markPublished(through: firstWake.changeGeneration)

        let cycleClock = RunnerDeltaTokenCycleClock(signal: signal, nextToken: tokenA)
        let secondWake = try await signal.wait(
            intervalNanoseconds: 900_000_000_000,
            debounceNanoseconds: 60_000_000_000,
            respondsToIndexChanges: true,
            sleep: { try await cycleClock.sleep(nanoseconds: $0) }
        )

        let firstSleepSeconds = await firstClock.sleepSeconds()
        let cycleSleepSeconds = await cycleClock.sleepSeconds()
        XCTAssertEqual(firstWake, .indexChanged(changeGeneration: 1))
        XCTAssertEqual(secondWake, .indexChanged(changeGeneration: 3))
        XCTAssertEqual(firstSleepSeconds, [60])
        XCTAssertEqual(cycleSleepSeconds, [60, 60])
    }

    func testLivePublishSignalRestartsTrailingDebounceForSecondIndexGeneration_repro() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let home = harness.root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        _ = try await harness.gate.performWriteCommand(name: "liveTrailingMigrate") { writer in
            try writer.migrate()
            try writer.write { db in
                try db.execute(sql: """
                    INSERT INTO sessions (
                      id, source, start_time, file_path, message_count,
                      sync_version, snapshot_hash, tier, offload_state
                    ) VALUES (
                      'trailing-ready', 'codex', '2026-08-30T00:00:00Z',
                      '/tmp/trailing-ready.jsonl', 1, 1, 'trailing-ready-v1',
                      'premium', 'local'
                    );
                    INSERT INTO sessions_fts(session_id, content)
                    VALUES ('trailing-ready', 'first publishable generation');
                    """)
            }
        }
        let environment = [
            "HOME": home.path,
            "CFFIXED_USER_HOME": home.path,
            "XCTestConfigurationFilePath": "hermetic",
            "ENGRAM_LIVE_PUBLISH_ENABLED": "true",
            "ENGRAM_LIVE_INGEST_PEER": "hq",
        ]
        let signal = LiveIngestPublishSignal()
        await EngramServiceRunner.signalLivePublishIfNeeded(
            gate: harness.gate,
            environment: environment,
            publishSignal: signal
        )
        let clock = RunnerSecondIndexGenerationClock(
            gate: harness.gate,
            environment: environment,
            signal: signal
        )

        let wake = try await signal.wait(
            intervalNanoseconds: 900_000_000_000,
            debounceNanoseconds: 60_000_000_000,
            respondsToIndexChanges: true,
            sleep: { try await clock.sleep(nanoseconds: $0) }
        )

        let sleepSeconds = await clock.sleepSeconds()
        XCTAssertEqual(wake, .indexChanged(changeGeneration: 2))
        XCTAssertEqual(
            sleepSeconds,
            [60, 60],
            "a real second index generation must restart the trailing 60-second debounce"
        )
    }

    func testLivePublishSignalDoesNotRestartForUnrelatedCompletedJob_repro() async throws {
        try await assertDeltaIdentitySignal(
            scenario: .unrelatedCompletedJob,
            expectedWake: .indexChanged(changeGeneration: 1),
            expectedSleeps: [60]
        )
    }

    func testLivePublishSignalRestartsForParentBackfillRetractionWithNoFtsProgress_repro() async throws {
        try await assertDeltaIdentitySignal(
            scenario: .eligibilityRetraction,
            expectedWake: .indexChanged(changeGeneration: 2),
            expectedSleeps: [60, 60]
        )
    }

    func testLiveRunnerKeepsDeltaCreatedDuringPublishPendingForNextDebounce_repro() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let home = harness.root.appendingPathComponent("home", isDirectory: true)
        let store = harness.root.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        _ = try await harness.gate.performWriteCommand(name: "liveInFlightMigrate") { writer in
            try writer.migrate()
            try writer.write { db in
                try db.execute(sql: """
                    INSERT INTO sessions (
                      id, source, start_time, file_path, message_count,
                      sync_version, snapshot_hash, tier, offload_state
                    ) VALUES (
                      'in-flight-base', 'codex', '2026-08-30T00:00:00Z',
                      '/tmp/in-flight-base.jsonl', 1, 1, 'in-flight-base-v1',
                      'premium', 'local'
                    );
                    INSERT INTO sessions_fts(session_id, content)
                    VALUES ('in-flight-base', 'initial complete publish');
                    """)
            }
        }
        let environment = [
            "HOME": home.path,
            "CFFIXED_USER_HOME": home.path,
            "XCTestConfigurationFilePath": "hermetic",
            "ENGRAM_LIVE_PUBLISH_ENABLED": "true",
            "ENGRAM_LIVE_INGEST_PEER": "hq",
            "ENGRAM_LIVE_INGEST_INTERVAL_SECONDS": "900",
        ]
        let signal = LiveIngestPublishSignal()
        let backend = RunnerInFlightMutationBackend(
            inner: try LocalDirectoryBackend(root: store),
            gate: harness.gate
        )
        let coordinator = RemoteSyncCoordinator(
            gate: harness.gate,
            backend: backend,
            config: RemoteSyncConfig(
                enabled: true,
                storeRoot: store,
                policy: OffloadPolicy(coldAgeDays: 90),
                offloadBatch: 20,
                rehydrateBatch: 20,
                vacuumFreelistThreshold: 1_000_000
            ),
            peer: "hq"
        )
        let clock = RunnerPublishInFlightClock(
            gate: harness.gate,
            environment: environment,
            signal: signal
        )

        await EngramServiceRunner.runLiveIngestLoop(
            coordinator: coordinator,
            gate: harness.gate,
            environment: environment,
            publishSignal: signal,
            sleep: { try await clock.sleep(nanoseconds: $0) }
        )

        let sleeps = await clock.sleepSeconds()
        let headPutCount = await backend.headPutCount()
        let inFlightCurrent = try await harness.gate.performReadCommand(
            name: "liveInFlightVerify"
        ) { writer in
            try writer.read { db in
                try Int.fetchOne(
                    db,
                    sql: """
                    SELECT COUNT(*)
                    FROM sync_ledger l
                    JOIN sessions s ON s.id = l.session_id
                    WHERE l.remote_peer = 'hq' AND l.direction = 'out'
                      AND l.session_id = 'in-flight-tail'
                      AND l.source_snapshot_hash = s.snapshot_hash
                    """
                ) ?? 0
            }
        }.value

        XCTAssertEqual(
            sleeps,
            [60, 900, 60, 60, 900],
            "the in-flight mutation must retain its own debounce before the idle timer resumes"
        )
        XCTAssertEqual(headPutCount, 3, "the in-flight tail must publish in a distinct third head")
        XCTAssertEqual(inFlightCurrent, 1)
    }

    func testNormalIndexingSignalsPublishImmediatelyAfterFtsDrainBeforeMaintenance_repro() async throws {
        try await assertFtsDrainSignalsBeforeBlockedMaintenance(
            sessionId: "normal-post-fts",
            commandName: "normalPostFtsReady"
        )
    }

    func testScheduledFtsRetrySignalsPublishImmediatelyAfterDrainBeforeMaintenance_repro() async throws {
        try await assertFtsDrainSignalsBeforeBlockedMaintenance(
            sessionId: "scheduled-post-fts",
            commandName: "scheduledPostFtsReady"
        )
    }

    func testLiveRunnerPublishesNewTailOnFirstSteadyStateCycleWithoutCorpusRewalk_repro() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let home = harness.root.appendingPathComponent("home", isDirectory: true)
        let store = harness.root.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        _ = try await harness.gate.performWriteCommand(name: "liveMultipageSeed") { writer in
            try writer.migrate()
            try writer.write { db in
                for index in 0..<5 {
                    let id = "initial-\(index)"
                    try db.execute(
                        sql: """
                        INSERT INTO sessions (
                          id, source, start_time, end_time, cwd, project, file_path,
                          message_count, user_message_count, assistant_message_count,
                          summary, size_bytes, indexed_at, tier, offload_state
                        ) VALUES (?, 'codex', ?, ?, '/tmp/initial', 'engram', ?,
                                  2, 1, 1, ?, 8192, '2020-01-01T00:00:00Z',
                                  'premium', 'local')
                        """,
                        arguments: [
                            id,
                            "2020-01-0\(index + 1)T00:00:00Z",
                            "2020-01-0\(index + 1)T01:00:00Z",
                            "/tmp/\(id).jsonl",
                            "initial summary \(index)",
                        ]
                    )
                    try db.execute(
                        sql: "INSERT INTO sessions_fts(session_id, content) VALUES (?, ?)",
                        arguments: [id, "initial corpus \(index)"]
                    )
                }
            }
        }

        let inner = try LocalDirectoryBackend(root: store)
        let backend = RunnerRecordingRemoteStorageBackend(inner: inner)
        let coordinator = RemoteSyncCoordinator(
            gate: harness.gate,
            backend: backend,
            config: RemoteSyncConfig(
                enabled: true,
                storeRoot: store,
                policy: OffloadPolicy(coldAgeDays: 0, minResidencyHours: 0),
                offloadBatch: 20,
                rehydrateBatch: 20,
                vacuumFreelistThreshold: 1_000_000
            ),
            peer: "hq"
        )
        let environment = [
            "HOME": home.path,
            "CFFIXED_USER_HOME": home.path,
            "XCTestConfigurationFilePath": "hermetic",
            "ENGRAM_LIVE_PUBLISH_ENABLED": "true",
            "ENGRAM_LIVE_INGEST_PEER": "hq",
            "ENGRAM_LIVE_PUBLISH_BATCH": "2",
        ]

        let initialPublished = await EngramServiceRunner.runLiveIngestCycle(
            coordinator: coordinator,
            environment: environment,
            debouncePublish: false,
            completeWalk: true
        )
        XCTAssertTrue(initialPublished)
        let initialObservations = await backend.observations()
        XCTAssertEqual(
            initialObservations.headKeys.count,
            5,
            "the initial complete walk must exercise more than one two-row page"
        )

        _ = try await harness.gate.performWriteCommand(name: "liveTailSeedAndFtsTrap") { writer in
            try writer.write { db in
                try db.execute(sql: """
                    INSERT INTO sessions (
                      id, source, start_time, end_time, cwd, project, file_path,
                      message_count, user_message_count, assistant_message_count,
                      summary, size_bytes, indexed_at, tier, offload_state
                    ) VALUES (
                      'new-tail', 'codex', '2030-01-01T00:00:00Z',
                      '2030-01-01T01:00:00Z', '/tmp/new-tail', 'engram',
                      '/tmp/new-tail.jsonl', 2, 1, 1, 'new tail summary', 8192,
                      '2030-01-01T01:00:00Z', 'premium', 'local'
                    );
                    INSERT INTO sessions_fts(session_id, content)
                    VALUES ('new-tail', 'unique newly indexed tail');
                    DROP TABLE sessions_fts;
                    CREATE TABLE sessions_fts(session_id TEXT NOT NULL, content TEXT NOT NULL);
                    INSERT INTO sessions_fts(session_id, content)
                    VALUES ('new-tail', 'unique newly indexed tail');
                    """)
            }
        }
        await backend.resetObservations()
        let generationBefore = await harness.gate.currentDatabaseGeneration()

        let steadyStatePublished = await EngramServiceRunner.runLiveIngestCycle(
            coordinator: coordinator,
            environment: environment,
            debouncePublish: false,
            completeWalk: false
        )
        XCTAssertTrue(steadyStatePublished)

        let observations = await backend.observations()
        XCTAssertEqual(
            observations.headKeys.count,
            1,
            "the first steady-state cycle must probe only the new tail bundle"
        )
        XCTAssertEqual(
            observations.putKeys.count,
            3,
            "the cycle writes one bundle plus the changed manifest and head"
        )
        let head = try ManifestCodec.decodeLiveHead(
            try await backend.get(key: LiveIngestKeys.head(peer: "hq"))
        )
        let manifest = try ManifestCodec.decodeLiveManifest(
            try await backend.get(key: head.manifestKey)
        )
        XCTAssertTrue(head.complete)
        XCTAssertEqual(manifest.entries.count, 6)
        XCTAssertTrue(manifest.entries.contains { $0.sessionId == "new-tail" })
        let tailLedgerCount = try await harness.gate.performReadCommand(name: "liveTailVerify") { writer in
            try writer.read { db in
                try Int.fetchOne(
                    db,
                    sql: """
                    SELECT COUNT(*) FROM sync_ledger
                    WHERE remote_peer = 'hq' AND direction = 'out' AND session_id = 'new-tail'
                    """
                ) ?? 0
            }
        }.value
        XCTAssertEqual(tailLedgerCount, 1)
        let generationAfter = await harness.gate.currentDatabaseGeneration()
        XCTAssertEqual(
            generationAfter - generationBefore,
            2,
            "only the new-tail ledger commit and publish metadata may write"
        )
    }

    func testLiveRunnerDrainsSteadyWaveLargerThanBatchWithoutWaitingForTimer_repro() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let home = harness.root.appendingPathComponent("home", isDirectory: true)
        let store = harness.root.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        _ = try await harness.gate.performWriteCommand(name: "liveSteadyWaveSeed") { writer in
            try writer.migrate()
            try writer.write { db in
                for index in 0 ... 50 {
                    let id = String(format: "steady-wave-%02d", index)
                    let startTime = String(format: "2026-08-30T00:%02d:00Z", index)
                    try db.execute(
                        sql: """
                        INSERT INTO sessions (
                          id, source, start_time, file_path, message_count,
                          sync_version, snapshot_hash, tier, offload_state
                        ) VALUES (?, 'codex', ?, ?, 1, 1, ?, 'premium', 'local')
                        """,
                        arguments: [id, startTime, "/tmp/\(id).jsonl", "\(id)-v1"]
                    )
                    try db.execute(
                        sql: "INSERT INTO sessions_fts(session_id, content) VALUES (?, ?)",
                        arguments: [id, "steady wave v1 \(index)"]
                    )
                }
            }
        }

        let inner = try LocalDirectoryBackend(root: store)
        let backend = RunnerRecordingRemoteStorageBackend(inner: inner)
        let coordinator = RemoteSyncCoordinator(
            gate: harness.gate,
            backend: backend,
            config: RemoteSyncConfig(
                enabled: true,
                storeRoot: store,
                policy: OffloadPolicy(coldAgeDays: 90),
                offloadBatch: 20,
                rehydrateBatch: 20,
                vacuumFreelistThreshold: 1_000_000
            ),
            peer: "hq"
        )
        let environment = [
            "HOME": home.path,
            "CFFIXED_USER_HOME": home.path,
            "XCTestConfigurationFilePath": "hermetic",
            "ENGRAM_LIVE_PUBLISH_ENABLED": "true",
            "ENGRAM_LIVE_INGEST_PEER": "hq",
            "ENGRAM_LIVE_PUBLISH_BATCH": "50",
            "ENGRAM_LIVE_INGEST_INTERVAL_SECONDS": "900",
        ]
        let initialPublished = await EngramServiceRunner.runLiveIngestCycle(
            coordinator: coordinator,
            environment: environment,
            debouncePublish: false,
            completeWalk: true
        )
        XCTAssertTrue(initialPublished)
        await backend.resetObservations()

        _ = try await harness.gate.performWriteCommand(name: "liveSteadyWaveChange") { writer in
            try writer.write { db in
                try db.execute(sql: """
                    UPDATE sessions
                    SET snapshot_hash = id || '-v2'
                    WHERE id LIKE 'steady-wave-%';
                    UPDATE sessions_fts
                    SET content = 'steady wave v2 ' || session_id
                    WHERE session_id LIKE 'steady-wave-%';
                    """)
            }
        }

        let steadyPublished = await EngramServiceRunner.runLiveIngestCycle(
            coordinator: coordinator,
            environment: environment,
            debouncePublish: false,
            completeWalk: false
        )
        XCTAssertTrue(steadyPublished)

        let head = try ManifestCodec.decodeLiveHead(
            try await backend.get(key: LiveIngestKeys.head(peer: "hq"))
        )
        let currentLedgerCount = try await harness.gate.performReadCommand(
            name: "liveSteadyWaveVerify"
        ) { writer in
            try writer.read { db in
                try Int.fetchOne(
                    db,
                    sql: """
                    SELECT COUNT(DISTINCT l.session_id)
                    FROM sync_ledger l
                    JOIN sessions s ON s.id = l.session_id
                    WHERE l.remote_peer = 'hq' AND l.direction = 'out'
                      AND l.source_snapshot_hash = s.snapshot_hash
                      AND s.id LIKE 'steady-wave-%'
                    """
                ) ?? 0
            }
        }.value
        XCTAssertTrue(head.complete, "the same steady wake must reach its authoritative complete head")
        XCTAssertEqual(
            currentLedgerCount,
            51,
            "item 51 must publish in the same runner cycle instead of waiting for the 900-second timer"
        )
    }

    private func assertFtsDrainSignalsBeforeBlockedMaintenance(
        sessionId: String,
        commandName: String
    ) async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let home = harness.root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        _ = try await harness.gate.performWriteCommand(name: "postFtsSignalMigrate") {
            try $0.migrate()
        }
        let environment = [
            "HOME": home.path,
            "CFFIXED_USER_HOME": home.path,
            "XCTestConfigurationFilePath": "hermetic",
            "ENGRAM_LIVE_PUBLISH_ENABLED": "true",
            "ENGRAM_LIVE_INGEST_PEER": "hq",
            "ENGRAM_LIVE_INGEST_INTERVAL_SECONDS": "900",
        ]
        let signal = LiveIngestPublishSignal()
        let maintenanceGate = RunnerAsyncGate()
        let cycle = Task {
            _ = try await EngramServiceRunner.runFtsDrainThenSignal(
                gate: harness.gate,
                environment: environment,
                publishSignal: signal
            ) {
                _ = try await harness.gate.performWriteCommand(name: commandName) { writer in
                    try writer.write { db in
                        try db.execute(
                            sql: """
                            INSERT INTO sessions (
                              id, source, start_time, file_path, message_count,
                              sync_version, snapshot_hash, tier, offload_state
                            ) VALUES (?, 'codex', '2026-08-30T00:00:00Z', ?,
                                      1, 1, ?, 'premium', 'local');
                            INSERT INTO sessions_fts(session_id, content)
                            VALUES (?, 'FTS completed before blocked maintenance');
                            """,
                            arguments: [
                                sessionId,
                                "/tmp/\(sessionId).jsonl",
                                "\(sessionId)-v1",
                                sessionId,
                            ]
                        )
                    }
                }
                return StartupIndexJobRecoveryResult(completed: 1, notApplicable: 0)
            }
            await maintenanceGate.wait()
        }
        await maintenanceGate.waitUntilSuspended()

        let clock = RunnerPostFtsSignalClock()
        let wake: LiveIngestPublishSignal.Wake?
        do {
            wake = try await signal.wait(
                intervalNanoseconds: 900_000_000_000,
                debounceNanoseconds: 60_000_000_000,
                respondsToIndexChanges: true,
                sleep: { try await clock.sleep(nanoseconds: $0) }
            )
        } catch RunnerLivePublishSignalProbeError.stop {
            wake = nil
        }
        let sleepSeconds = await clock.sleepSeconds()
        XCTAssertEqual(wake, .indexChanged(changeGeneration: 1))
        XCTAssertEqual(
            sleepSeconds,
            [60],
            "the publish debounce must be armed before any post-FTS maintenance can suspend"
        )

        await maintenanceGate.open()
        _ = try await cycle.value
    }

    private func assertDeltaIdentitySignal(
        scenario: RunnerDeltaIdentityScenario,
        expectedWake: LiveIngestPublishSignal.Wake,
        expectedSleeps: [Int]
    ) async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let home = harness.root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        _ = try await harness.gate.performWriteCommand(name: "liveDeltaIdentityMigrate") { writer in
            try writer.migrate()
            try writer.write { db in
                try db.execute(sql: """
                    INSERT INTO sessions (
                      id, source, start_time, file_path, message_count,
                      sync_version, snapshot_hash, tier, offload_state
                    ) VALUES (
                      'identity-old-delta', 'codex', '2026-08-30T00:00:00Z',
                      '/tmp/identity-old-delta.jsonl', 1, 1, 'identity-old-v1',
                      'premium', 'local'
                    );
                    INSERT INTO sessions_fts(session_id, content)
                    VALUES ('identity-old-delta', 'existing unresolved outbound delta');
                    """)
                if scenario == .eligibilityRetraction {
                    try db.execute(sql: """
                        INSERT INTO sessions (
                          id, source, start_time, file_path, message_count,
                          sync_version, snapshot_hash, tier, offload_state
                        ) VALUES (
                          'identity-published', 'codex', '2026-08-30T00:01:00Z',
                          '/tmp/identity-published.jsonl', 1, 1, 'identity-published-v1',
                          'premium', 'local'
                        );
                        INSERT INTO sessions_fts(session_id, content)
                        VALUES ('identity-published', 'already published row');
                        INSERT INTO sync_ledger(
                          session_id, remote_peer, remote_session_id, remote_key,
                          direction, content_hash, source_sync_version, source_snapshot_hash
                        ) VALUES (
                          'identity-published', 'hq', 'identity-published',
                          'sessions/identity-published.json', 'out', 'published-content',
                          1, 'identity-published-v1'
                        );
                        """)
                }
            }
        }
        let environment = [
            "HOME": home.path,
            "CFFIXED_USER_HOME": home.path,
            "XCTestConfigurationFilePath": "hermetic",
            "ENGRAM_LIVE_PUBLISH_ENABLED": "true",
            "ENGRAM_LIVE_INGEST_PEER": "hq",
        ]
        let signal = LiveIngestPublishSignal()
        await EngramServiceRunner.signalLivePublishIfNeeded(
            gate: harness.gate,
            environment: environment,
            publishSignal: signal
        )
        let clock = RunnerDeltaIdentityClock(
            gate: harness.gate,
            environment: environment,
            signal: signal,
            scenario: scenario
        )

        let wake = try await signal.wait(
            intervalNanoseconds: 900_000_000_000,
            debounceNanoseconds: 60_000_000_000,
            respondsToIndexChanges: true,
            sleep: { try await clock.sleep(nanoseconds: $0) }
        )

        let sleepSeconds = await clock.sleepSeconds()
        XCTAssertEqual(wake, expectedWake)
        XCTAssertEqual(sleepSeconds, expectedSleeps)
    }

    /// R2.P1 source-disable linearization: every parser write must reread the
    /// disabled output set only after ServiceWriterGate is acquired. The scan's
    /// adapter snapshot alone is stale-able by an interleaved source toggle.
    func testRunnerReadsDisabledOutputsInsideEachWriterGate_repro() throws {
        let source = try runnerSource()

        let periodicStart = try XCTUnwrap(
            source.range(of: #"performWriteCommand(name: "indexRecent")"#)
        )
        let periodicEnd = try XCTUnwrap(
            source.range(of: "}.value", range: periodicStart.lowerBound ..< source.endIndex)
        )
        let periodicGate = String(source[periodicStart.lowerBound ..< periodicEnd.upperBound])
        XCTAssertTrue(periodicGate.contains("readDisabledSources(environment: environment)"))

        let archiveHelperStart = try XCTUnwrap(
            source.range(of: "private static func runInitialArchiveV2IndexPhase(")
        )
        let initialScanStart = try XCTUnwrap(
            source.range(of: "static func runInitialScan(", range: archiveHelperStart.lowerBound ..< source.endIndex)
        )
        let archiveHelper = String(source[archiveHelperStart.lowerBound ..< initialScanStart.lowerBound])
        XCTAssertTrue(archiveHelper.contains("readDisabledSources(environment: environment)"))

        let initialScanEnd = try XCTUnwrap(
            source.range(of: "private static func elapsedMs", range: initialScanStart.lowerBound ..< source.endIndex)
        )
        let initialScan = String(source[initialScanStart.lowerBound ..< initialScanEnd.lowerBound])
        let defaultIndexStart = try XCTUnwrap(
            initialScan.range(of: #"performWriteCommand(name: "initialScanIndex")"#)
        )
        let defaultIndexEnd = try XCTUnwrap(
            initialScan.range(of: "}.value", range: defaultIndexStart.lowerBound ..< initialScan.endIndex)
        )
        let defaultIndexGate = String(
            initialScan[defaultIndexStart.lowerBound ..< defaultIndexEnd.upperBound]
        )
        XCTAssertTrue(defaultIndexGate.contains("readDisabledSources(environment: environment)"))

        let maintenanceStart = try XCTUnwrap(
            initialScan.range(of: #"performWriteCommand(name: "initialScanBackfills")"#)
        )
        let maintenanceEnd = try XCTUnwrap(
            initialScan.range(of: "}", range: maintenanceStart.lowerBound ..< initialScan.endIndex)
        )
        let maintenanceGate = String(
            initialScan[maintenanceStart.lowerBound ..< maintenanceEnd.upperBound]
        )
        XCTAssertTrue(maintenanceGate.contains("readDisabledSources(environment: environment)"))
    }

    private func makeHarness() throws -> RunnerHarness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-archive-v2-runner-\(UUID().uuidString)", isDirectory: true)
        let runtime = root.appendingPathComponent("run", isDirectory: true)
        try FileManager.default.createDirectory(
            at: runtime,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let database = root.appendingPathComponent("index.sqlite")
        return RunnerHarness(
            root: root,
            database: database,
            gate: try ServiceWriterGate(databasePath: database.path, runtimeDirectory: runtime)
        )
    }

    private func runnerSource() throws -> String {
        let macosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: macosRoot
                .appendingPathComponent("EngramService/Core/EngramServiceRunner.swift"),
            encoding: .utf8
        )
    }

    private static func zeroAggregate() -> ArchiveStatusAggregate {
        let zero = ArchiveReplicaStatusCounts(
            pending: 0,
            inflight: 0,
            retry: 0,
            quarantine: 0,
            verified: 0
        )
        return ArchiveStatusAggregate(
            captured: 0,
            bound: 0,
            unbound: 0,
            unknown: 0,
            eligible: 0,
            excluded: 0,
            hq: zero,
            m1: zero,
            singleVerified: 0,
            dualVerified: 0,
            latestReceipts: []
        )
    }

    private static func noopOperations() -> ArchiveV2ServiceCoordinatorOperations {
        ArchiveV2ServiceCoordinatorOperations(
            capture: { _, _, _ in ArchiveV2ServiceCaptureSummary(unsupported: 0, unsafe: 0) },
            bindingTargets: { _ in [] },
            historicalUnknown: { _ in ArchiveV2ServiceUnknownPage(targets: []) },
            advancePolicyCursor: { _ in },
            snapshot: { _, _ in ArchiveV2ServiceIndexSnapshot(rows: []) },
            bindOne: { _, _ in nil },
            applyRemotePolicy: { _, _, _ in },
            replicate: { _ in ArchiveReplicationCycleResult() },
            status: { zeroAggregate() },
            retry: { _ in ArchiveV2ServiceRetryOutcome(resetRows: 0) }
        )
    }
}

private struct RunnerHarness {
    let root: URL
    let database: URL
    let gate: ServiceWriterGate
}

private actor RunnerRecordingRemoteStorageBackend: RemoteStorageBackend {
    struct Observations: Sendable {
        let headKeys: [String]
        let putKeys: [String]
    }

    private let inner: LocalDirectoryBackend
    private var headKeys: [String] = []
    private var putKeys: [String] = []

    init(inner: LocalDirectoryBackend) {
        self.inner = inner
    }

    func observations() -> Observations {
        Observations(headKeys: headKeys, putKeys: putKeys)
    }

    func resetObservations() {
        headKeys = []
        putKeys = []
    }

    func head(key: String) async throws -> Bool {
        headKeys.append(key)
        return try await inner.head(key: key)
    }

    func put(key: String, data: Data) async throws {
        putKeys.append(key)
        try await inner.put(key: key, data: data)
    }

    func get(key: String) async throws -> Data {
        try await inner.get(key: key)
    }

    func delete(key: String) async throws {
        try await inner.delete(key: key)
    }

    func catalog() async throws -> Data {
        try await inner.catalog()
    }
}

private actor RunnerInFlightMutationBackend: RemoteStorageBackend {
    private let inner: LocalDirectoryBackend
    private let gate: ServiceWriterGate
    private var liveHeadPutCount = 0

    init(
        inner: LocalDirectoryBackend,
        gate: ServiceWriterGate
    ) {
        self.inner = inner
        self.gate = gate
    }

    func headPutCount() -> Int {
        liveHeadPutCount
    }

    func head(key: String) async throws -> Bool {
        try await inner.head(key: key)
    }

    func put(key: String, data: Data) async throws {
        try await inner.put(key: key, data: data)
        guard key == LiveIngestKeys.head(peer: "hq") else { return }
        liveHeadPutCount += 1
        guard liveHeadPutCount == 2 else { return }

        _ = try await gate.performWriteCommand(name: "liveInFlightSecondDelta") { writer in
            try writer.write { db in
                try db.execute(sql: """
                    INSERT INTO sessions (
                      id, source, start_time, file_path, message_count,
                      sync_version, snapshot_hash, tier, offload_state
                    ) VALUES (
                      'in-flight-tail', 'codex', '2026-08-30T00:02:00Z',
                      '/tmp/in-flight-tail.jsonl', 1, 1, 'in-flight-tail-v1',
                      'premium', 'local'
                    );
                    INSERT INTO sessions_fts(session_id, content)
                    VALUES ('in-flight-tail', 'delta created after the final remaining probe');
                    """)
            }
        }
    }

    func get(key: String) async throws -> Data {
        try await inner.get(key: key)
    }

    func delete(key: String) async throws {
        try await inner.delete(key: key)
    }

    func catalog() async throws -> Data {
        try await inner.catalog()
    }
}

private actor RunnerEventLog {
    private var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }

    func values() -> [String] {
        events
    }
}

private actor RunnerLiveIngestIdleClock {
    private var sleeps: [Int] = []

    func sleep(nanoseconds: UInt64) throws {
        sleeps.append(Int(nanoseconds / 1_000_000_000))
        if sleeps.count == 2 {
            throw CancellationError()
        }
    }

    func sleepSeconds() -> [Int] {
        sleeps
    }
}

private enum RunnerLivePublishSignalProbeError: Error {
    case stop
}

private enum RunnerDeltaIdentityScenario: Equatable, Sendable {
    case unrelatedCompletedJob
    case eligibilityRetraction
}

private func runnerReadyDeltaToken(
    id: String,
    syncVersion: Int = 1,
    snapshotHash: String
) -> OffloadRepo.LivePublishDeltaToken {
    OffloadRepo.LivePublishDeltaToken(
        readySessions: [
            .init(id: id, syncVersion: syncVersion, snapshotHash: snapshotHash),
        ],
        retractionSessionIds: []
    )
}

private actor RunnerLivePublishSignalClock {
    private var sleeps: [Int] = []

    func recordThenStop(nanoseconds: UInt64) throws {
        sleeps.append(Int(nanoseconds / 1_000_000_000))
        throw RunnerLivePublishSignalProbeError.stop
    }

    func record(nanoseconds: UInt64) {
        sleeps.append(Int(nanoseconds / 1_000_000_000))
    }

    func sleepSeconds() -> [Int] {
        sleeps
    }
}

private actor RunnerRepeatedLiveDeltaClock {
    private let gate: ServiceWriterGate
    private let environment: [String: String]
    private let signal: LiveIngestPublishSignal
    private var probedAgain = false
    private var sleeps: [Int] = []
    private var generationAdvance = 0

    init(
        gate: ServiceWriterGate,
        environment: [String: String],
        signal: LiveIngestPublishSignal
    ) {
        self.gate = gate
        self.environment = environment
        self.signal = signal
    }

    func sleep(nanoseconds: UInt64) async throws {
        sleeps.append(Int(nanoseconds / 1_000_000_000))
        guard !probedAgain else { return }
        probedAgain = true
        let generationBefore = await gate.currentDatabaseGeneration()
        _ = try await EngramServiceRunner.runFtsDrainThenSignal(
            gate: gate,
            environment: environment,
            publishSignal: signal
        ) {
            _ = try await gate.performWriteCommand(name: "liveLevelNoOpWrite") { writer in
                try writer.write { db in
                    try db.execute(
                        sql: "UPDATE sessions SET summary = summary WHERE id = 'missing-level-row'"
                    )
                }
            }
            return StartupIndexJobRecoveryResult(completed: 0, notApplicable: 0)
        }
        generationAdvance = await gate.currentDatabaseGeneration() - generationBefore
        try Task.checkCancellation()
    }

    func sleepSeconds() -> [Int] {
        sleeps
    }

    func noOpGenerationAdvance() -> Int {
        generationAdvance
    }
}

private actor RunnerDeltaIdentityClock {
    private let gate: ServiceWriterGate
    private let environment: [String: String]
    private let signal: LiveIngestPublishSignal
    private let scenario: RunnerDeltaIdentityScenario
    private var mutated = false
    private var sleeps: [Int] = []

    init(
        gate: ServiceWriterGate,
        environment: [String: String],
        signal: LiveIngestPublishSignal,
        scenario: RunnerDeltaIdentityScenario
    ) {
        self.gate = gate
        self.environment = environment
        self.signal = signal
        self.scenario = scenario
    }

    func sleep(nanoseconds: UInt64) async throws {
        sleeps.append(Int(nanoseconds / 1_000_000_000))
        guard !mutated else { return }
        mutated = true
        _ = try await EngramServiceRunner.runFtsDrainThenSignal(
            gate: gate,
            environment: environment,
            publishSignal: signal
        ) {
            switch scenario {
            case .unrelatedCompletedJob:
                _ = try await gate.performWriteCommand(name: "liveUnrelatedCompletedJob") { writer in
                    try writer.write { db in
                        try db.execute(sql: """
                            INSERT INTO sessions (
                              id, source, start_time, file_path, message_count,
                              sync_version, snapshot_hash, tier, offload_state, origin
                            ) VALUES (
                              'identity-imported-job', 'codex', '2026-08-30T00:02:00Z',
                              'remote://hq/identity-imported-job', 1, 1,
                              'identity-imported-v1', 'premium', 'local', 'hq'
                            );
                            INSERT INTO sessions_fts(session_id, content)
                            VALUES ('identity-imported-job', 'unrelated imported completed job');
                            """)
                    }
                }
                return StartupIndexJobRecoveryResult(completed: 1, notApplicable: 0)
            case .eligibilityRetraction:
                _ = try await gate.performWriteCommand(name: "periodicParentBackfillEligibility") { writer in
                    try writer.write { db in
                        try db.execute(sql: """
                            UPDATE sessions
                            SET tier = 'skip', agent_role = 'subagent'
                            WHERE id = 'identity-published';
                            DELETE FROM sessions_fts
                            WHERE session_id = 'identity-published';
                            DELETE FROM session_index_jobs
                            WHERE session_id = 'identity-published';
                            """)
                    }
                }
                return StartupIndexJobRecoveryResult(completed: 0, notApplicable: 0)
            }
        }
        try Task.checkCancellation()
    }

    func sleepSeconds() -> [Int] {
        sleeps
    }
}

private actor RunnerTimerBoundarySignalClock {
    private let signal: LiveIngestPublishSignal
    private var signaled = false
    private var sleeps: [Int] = []

    init(signal: LiveIngestPublishSignal) {
        self.signal = signal
    }

    func sleep(nanoseconds: UInt64) async throws {
        sleeps.append(Int(nanoseconds / 1_000_000_000))
        guard !signaled else { return }
        signaled = true
        await signal.signalIndexChange(
            token: runnerReadyDeltaToken(id: "timer-boundary", snapshotHash: "v1")
        )
    }

    func sleepSeconds() -> [Int] {
        sleeps
    }
}

private actor RunnerDeltaTokenCycleClock {
    private let signal: LiveIngestPublishSignal
    private let nextToken: OffloadRepo.LivePublishDeltaToken
    private var didSignal = false
    private var sleeps: [Int] = []

    init(signal: LiveIngestPublishSignal, nextToken: OffloadRepo.LivePublishDeltaToken) {
        self.signal = signal
        self.nextToken = nextToken
    }

    func sleep(nanoseconds: UInt64) async throws {
        sleeps.append(Int(nanoseconds / 1_000_000_000))
        guard !didSignal else { return }
        didSignal = true
        await signal.signalIndexChange(token: nextToken)
        try Task.checkCancellation()
    }

    func sleepSeconds() -> [Int] {
        sleeps
    }
}

private actor RunnerSecondIndexGenerationClock {
    private let gate: ServiceWriterGate
    private let environment: [String: String]
    private let signal: LiveIngestPublishSignal
    private var signaled = false
    private var sleeps: [Int] = []

    init(
        gate: ServiceWriterGate,
        environment: [String: String],
        signal: LiveIngestPublishSignal
    ) {
        self.gate = gate
        self.environment = environment
        self.signal = signal
    }

    func sleep(nanoseconds: UInt64) async throws {
        sleeps.append(Int(nanoseconds / 1_000_000_000))
        guard !signaled else { return }
        signaled = true
        _ = try await EngramServiceRunner.runFtsDrainThenSignal(
            gate: gate,
            environment: environment,
            publishSignal: signal
        ) {
            _ = try await gate.performWriteCommand(name: "liveTrailingSecondGeneration") { writer in
                try writer.write { db in
                    try db.execute(sql: """
                        UPDATE sessions
                        SET snapshot_hash = 'trailing-ready-v2'
                        WHERE id = 'trailing-ready';
                        UPDATE sessions_fts
                        SET content = 'second publishable generation'
                        WHERE session_id = 'trailing-ready';
                        """)
                }
            }
            return StartupIndexJobRecoveryResult(completed: 1, notApplicable: 0)
        }
        try Task.checkCancellation()
    }

    func sleepSeconds() -> [Int] {
        sleeps
    }
}

private actor RunnerPublishInFlightClock {
    private let gate: ServiceWriterGate
    private let environment: [String: String]
    private let signal: LiveIngestPublishSignal
    private var sleeps: [Int] = []

    init(
        gate: ServiceWriterGate,
        environment: [String: String],
        signal: LiveIngestPublishSignal
    ) {
        self.gate = gate
        self.environment = environment
        self.signal = signal
    }

    func sleep(nanoseconds: UInt64) async throws {
        let seconds = Int(nanoseconds / 1_000_000_000)
        sleeps.append(seconds)
        if sleeps.count == 2 {
            _ = try await EngramServiceRunner.runFtsDrainThenSignal(
                gate: gate,
                environment: environment,
                publishSignal: signal
            ) {
                _ = try await gate.performWriteCommand(name: "liveInFlightFirstDelta") { writer in
                    try writer.write { db in
                        try db.execute(sql: """
                            INSERT INTO sessions (
                              id, source, start_time, file_path, message_count,
                              sync_version, snapshot_hash, tier, offload_state
                            ) VALUES (
                              'pre-flight-tail', 'codex', '2026-08-30T00:01:00Z',
                              '/tmp/pre-flight-tail.jsonl', 1, 1, 'pre-flight-tail-v1',
                              'premium', 'local'
                            );
                            INSERT INTO sessions_fts(session_id, content)
                            VALUES ('pre-flight-tail', 'delta that starts the publish');
                            """)
                    }
                }
                return StartupIndexJobRecoveryResult(completed: 1, notApplicable: 0)
            }
            try Task.checkCancellation()
        }
        if sleeps.count == 4, seconds != 60 {
            throw RunnerLivePublishSignalProbeError.stop
        }
        if sleeps.count == 5 {
            throw RunnerLivePublishSignalProbeError.stop
        }
    }

    func sleepSeconds() -> [Int] {
        sleeps
    }
}

private actor RunnerPostFtsSignalClock {
    private var sleeps: [Int] = []

    func sleep(nanoseconds: UInt64) throws {
        let seconds = Int(nanoseconds / 1_000_000_000)
        sleeps.append(seconds)
        if seconds == 900 {
            throw RunnerLivePublishSignalProbeError.stop
        }
    }

    func sleepSeconds() -> [Int] {
        sleeps
    }
}

private actor RunnerLiveIngestSLAClock {
    struct Outcome: Sendable {
        let sleepSeconds: [Int]
        let indexedAtSeconds: Int
        let importedAtSeconds: Int?
    }

    private let hqGate: ServiceWriterGate
    private let macGate: ServiceWriterGate
    private let macCoordinator: RemoteSyncCoordinator
    private let environment: [String: String]
    private let publishSignal: LiveIngestPublishSignal
    private let pullIntervalSeconds: Int
    private var nowSeconds = 0
    private var nextPullSeconds: Int
    private var sleeps: [Int] = []
    private var tailSeeded = false
    private var importedAtSeconds: Int?

    init(
        hqGate: ServiceWriterGate,
        macGate: ServiceWriterGate,
        macCoordinator: RemoteSyncCoordinator,
        environment: [String: String],
        publishSignal: LiveIngestPublishSignal,
        pullIntervalSeconds: Int
    ) {
        self.hqGate = hqGate
        self.macGate = macGate
        self.macCoordinator = macCoordinator
        self.environment = environment
        self.publishSignal = publishSignal
        self.pullIntervalSeconds = pullIntervalSeconds
        nextPullSeconds = pullIntervalSeconds
    }

    func sleep(nanoseconds: UInt64) async throws {
        let seconds = Int(nanoseconds / 1_000_000_000)
        sleeps.append(seconds)
        if sleeps.count == 2 {
            nowSeconds += 1
            try await seedTailAfterInitialPublish()
            await EngramServiceRunner.signalLivePublishIfNeeded(
                gate: hqGate,
                environment: environment,
                publishSignal: publishSignal
            )
            try Task.checkCancellation()
        }

        let wakeSeconds = nowSeconds + seconds
        while nextPullSeconds <= wakeSeconds {
            nowSeconds = nextPullSeconds
            _ = try await macCoordinator.pullLivePeer(peer: "hq")
            if try await tailWasImported() {
                importedAtSeconds = nowSeconds
                throw CancellationError()
            }
            nextPullSeconds += pullIntervalSeconds
        }
        nowSeconds = wakeSeconds
    }

    func outcome() -> Outcome {
        Outcome(
            sleepSeconds: sleeps,
            indexedAtSeconds: 61,
            importedAtSeconds: importedAtSeconds
        )
    }

    private func seedTailAfterInitialPublish() async throws {
        guard !tailSeeded else { return }
        tailSeeded = true
        _ = try await hqGate.performWriteCommand(name: "liveSLASeedTail") { writer in
            try writer.write { db in
                try db.execute(sql: """
                    INSERT INTO sessions (
                      id, source, start_time, end_time, cwd, project, file_path,
                      message_count, user_message_count, assistant_message_count,
                      summary, size_bytes, indexed_at, tier, offload_state
                    ) VALUES (
                      'sla-tail', 'codex', '2026-08-30T00:01:01Z',
                      '2026-08-30T00:02:00Z', '/tmp/sla-tail', 'engram',
                      '/tmp/sla-tail.jsonl', 2, 1, 1, 'SLA tail', 8192,
                      '2026-08-30T00:01:01Z', 'premium', 'local'
                    );
                    INSERT INTO sessions_fts(session_id, content)
                    VALUES ('sla-tail', 'deterministic sixteen minute tail');
                    """)
            }
        }
    }

    private func tailWasImported() async throws -> Bool {
        try await macGate.performReadCommand(name: "liveSLACheckTail") { writer in
            try writer.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM sessions WHERE id = ? AND origin = 'hq'",
                    arguments: [ImportRepo.importedLocalId(peer: "hq", sessionId: "sla-tail")]
                ) ?? 0
            }
        }.value == 1
    }
}

private actor RunnerAsyncGate {
    private var isOpen = false
    private var isSuspended = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var suspensionObservers: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        isSuspended = true
        let observers = suspensionObservers
        suspensionObservers.removeAll()
        observers.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func waitUntilSuspended() async {
        guard !isSuspended else { return }
        await withCheckedContinuation { continuation in
            suspensionObservers.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let suspended = waiters
        waiters.removeAll()
        suspended.forEach { $0.resume() }
    }
}

private actor RunnerCaptureSummaryQueue {
    private var summaries: [ArchiveV2ServiceCaptureSummary]

    init(_ summaries: [ArchiveV2ServiceCaptureSummary]) {
        self.summaries = summaries
    }

    func next() throws -> ArchiveV2ServiceCaptureSummary {
        guard !summaries.isEmpty else { throw RunnerArchiveTestError.noSummary }
        return summaries.removeFirst()
    }
}

private enum RunnerArchiveTestError: Error {
    case noSummary
}

private class RunnerParsingAdapter: SessionAdapter, @unchecked Sendable {
    let source: SourceName
    private let locator: String
    private let events: RunnerEventLog

    init(source: SourceName, locator: String, events: RunnerEventLog) {
        self.source = source
        self.locator = locator
        self.events = events
    }

    func detect() async -> Bool { true }
    func listSessionLocators() async throws -> [String] { [locator] }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        await events.append("parse:\(source.rawValue):\(URL(fileURLWithPath: locator).lastPathComponent)")
        return .failure(.noVisibleMessages)
    }

    func streamMessages(
        locator _: String,
        options _: StreamMessagesOptions
    ) async throws -> AsyncThrowingStream<NormalizedMessage, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func isAccessible(locator _: String) async -> Bool { true }
}

private final class RunnerParsingExactAdapter: RunnerParsingAdapter, ExactArchiveSourceAdapter, @unchecked Sendable {
    private let allLocators: [String]

    init(source: SourceName, locators: [String], events: RunnerEventLog) {
        allLocators = locators
        super.init(source: source, locator: locators[0], events: events)
    }

    override func listSessionLocators() async throws -> [String] { allLocators }

    func archiveSourceDescriptor(locator: String) async throws -> ArchiveSourceDescriptor {
        try ArchiveSourceDescriptor.singleFile(
            locator: locator,
            sourceURL: URL(fileURLWithPath: locator),
            replayRelativePath: "fixtures/\(URL(fileURLWithPath: locator).lastPathComponent)"
        )
    }
}
