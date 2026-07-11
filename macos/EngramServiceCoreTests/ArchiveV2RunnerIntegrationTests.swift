import EngramCoreRead
import Foundation
import XCTest

@testable import EngramCoreWrite
@testable import EngramServiceCore

final class ArchiveV2RunnerIntegrationTests: XCTestCase {
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
            retry: { _ in 0 }
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
            retry: { _ in 0 }
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
        let remoteSync = try XCTUnwrap(source.range(of: "let remoteSync = RemoteSyncCoordinator"))
        let initialBlock = String(source[initialTask.lowerBound ..< remoteSync.lowerBound])
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
        XCTAssertTrue(periodicBlock.contains("indexRecentSessions(adapters: parserAdapters)"))
        XCTAssertTrue(periodicBlock.contains("IndexJobRunner(writer: writer, adapters: periodicParserAdapters)"))

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
            "WriterStartupIndexing(writer: writer, adapters: parserAdapters)",
            "adapters: parserAdapters",
            "IndexJobRunner(writer: writer, adapters: parserAdapters)",
        ] {
            XCTAssertTrue(initialScanBlock.contains(parserUse), "missing capture-safe startup parser path: \(parserUse)")
        }
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
            retry: { _ in 0 }
        )
    }
}

private struct RunnerHarness {
    let root: URL
    let database: URL
    let gate: ServiceWriterGate
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
