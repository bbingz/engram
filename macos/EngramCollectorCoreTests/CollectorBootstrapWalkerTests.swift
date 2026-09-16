import Foundation
import GRDB
import XCTest
@testable import EngramCollectorCore

final class CollectorBootstrapWalkerTests: XCTestCase {
    func testLazyMillionEntrySourceCountsIgnoredEntriesAgainstVisitBudget() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        let store = try fixture.openRegistered()
        let scan = try store.beginBootstrap(configuration: fixture.configuration, scanID: "scan")
        let source = SyntheticCollectorEnumerator { _, index in
            guard index < 1_000_000 else { return nil }
            return index.isMultiple(of: 2) ? .file(fixture.file("f\(index).jsonl")) : .ignored("ignored-\(index)")
        }
        let result = try CollectorBootstrapWalker(store: store, enumerator: source)
            .step(scan: scan, budget: budget(entries: 5))
        XCTAssertEqual(result.outcome, .paused(.budget))
        XCTAssertEqual(result.entriesVisited, 5)
        XCTAssertEqual(result.candidateFiles, 3)
        XCTAssertEqual(source.nextCalls, 5)
        XCTAssertEqual(try store.pendingLocators(configuration: fixture.configuration, limit: 10).count, 3)
        XCTAssertEqual(try store.pendingDirectories(scan: scan, limit: 10), [""])
        XCTAssertEqual(source.openedConfigurations, [fixture.configuration])
    }

    func testCandidateFileBudgetStopsWithoutReadingAdditionalEntries() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        let store = try fixture.openRegistered()
        let scan = try store.beginBootstrap(configuration: fixture.configuration, scanID: "scan")
        let source = SyntheticCollectorEnumerator { _, index in .file(fixture.file("f\(index).jsonl")) }
        let walker = CollectorBootstrapWalker(store: store, enumerator: source)
        let result = try walker.step(scan: scan, budget: budget(files: 2))
        XCTAssertEqual(result.candidateFiles, 2)
        XCTAssertEqual(result.entriesVisited, 2)
        XCTAssertEqual(source.nextCalls, 2)
        XCTAssertEqual(result.metadataBytes, metadataBytes(fixture.file("f0.jsonl")) + metadataBytes(fixture.file("f1.jsonl")))
        let second = try walker.step(scan: scan, budget: budget(files: 1))
        XCTAssertEqual(second.candidateFiles, 1)
        XCTAssertEqual(source.nextCalls, 3)
        XCTAssertEqual(source.openedDirectories, [""])
        XCTAssertEqual(try store.pendingLocators(configuration: fixture.configuration, limit: 10).count, 3)
    }

    func testMetadataBudgetUsesUTF8BytesAndRetainsOverBudgetEntryForNextStep() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        let store = try fixture.openRegistered()
        let scan = try store.beginBootstrap(configuration: fixture.configuration, scanID: "scan")
        let first = fixture.file("一.jsonl", generation: "世")
        let second = fixture.file("second.jsonl")
        let source = SyntheticCollectorEnumerator { _, index in
            if index == 0 { return .file(first) }
            return index == 1 ? .file(second) : nil
        }
        let walker = CollectorBootstrapWalker(store: store, enumerator: source)
        let limited = try walker.step(scan: scan, budget: budget(bytes: metadataBytes(first) + 1))
        XCTAssertEqual(limited.outcome, .paused(.budget))
        XCTAssertEqual(limited.candidateFiles, 1)
        XCTAssertEqual(limited.metadataBytes, metadataBytes(first))
        XCTAssertEqual(source.nextCalls, 2)
        let completed = try walker.step(scan: scan, budget: budget())
        XCTAssertEqual(completed.outcome, .finished)
        XCTAssertEqual(completed.candidateFiles, 1)
        XCTAssertEqual(completed.metadataBytes, metadataBytes(second))
        XCTAssertEqual(source.nextCalls, 3)
        XCTAssertEqual(source.openedDirectories, [""])
        XCTAssertEqual(Set(try store.pendingLocators(configuration: fixture.configuration, limit: 10).map(\.relativePath)), [first.relativePath, second.relativePath])
    }

    func testDirectoryOpenBudgetPersistsChildFrontierWithoutPreopeningIt() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        let store = try fixture.openRegistered()
        let scan = try store.beginBootstrap(configuration: fixture.configuration, scanID: "scan")
        let source = nestedSource(fixture)
        let walker = CollectorBootstrapWalker(store: store, enumerator: source)
        let first = try walker.step(scan: scan, budget: budget(directories: 1))
        XCTAssertEqual(first.outcome, .paused(.budget))
        XCTAssertEqual(first.directoriesOpened, 1)
        XCTAssertEqual(first.entriesVisited, 1)
        XCTAssertEqual(first.metadataBytes, "nested".utf8.count)
        XCTAssertEqual(source.openedDirectories, [""])
        XCTAssertEqual(try store.pendingDirectories(scan: scan, limit: 10), ["nested"])
        let second = try walker.step(scan: scan, budget: budget(directories: 1))
        XCTAssertEqual(second.outcome, .finished)
        XCTAssertEqual(source.openedDirectories, ["", "nested"])
    }

    func testZeroAndNegativeBudgetsDoNotInvokeEnumerator() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        let store = try fixture.openRegistered()
        let scan = try store.beginBootstrap(configuration: fixture.configuration, scanID: "scan")
        let source = SyntheticCollectorEnumerator { _, _ in XCTFail("budget admitted enumeration"); return nil }
        let walker = CollectorBootstrapWalker(store: store, enumerator: source)
        for zero in [budget(entries: 0), budget(files: 0), budget(directories: 0), budget(bytes: 0)] {
            let result = try walker.step(scan: scan, budget: zero)
            XCTAssertEqual(result.outcome, .paused(.budget))
            XCTAssertEqual(result.entriesVisited, 0)
            XCTAssertEqual(result.candidateFiles, 0)
            XCTAssertEqual(result.directoriesOpened, 0)
            XCTAssertEqual(result.metadataBytes, 0)
        }
        for negative in [budget(entries: -1), budget(files: -1), budget(directories: -1), budget(bytes: -1)] {
            XCTAssertThrowsError(try walker.step(scan: scan, budget: negative)) {
                XCTAssertEqual($0 as? CollectorInventoryError, .invalidBudget)
            }
        }
        XCTAssertTrue(source.openedDirectories.isEmpty)
        XCTAssertEqual(source.nextCalls, 0)
    }

    func testIndependentLargeBudgetsDoNotOverflowAnAggregateCounter() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        let store = try fixture.openRegistered()
        let scan = try store.beginBootstrap(configuration: fixture.configuration, scanID: "scan")
        let source = SyntheticCollectorEnumerator { _, index in index == 0 ? .file(fixture.file("one.jsonl")) : nil }
        let result = try CollectorBootstrapWalker(store: store, enumerator: source)
            .step(scan: scan, budget: budget(entries: .max, files: .max, directories: .max, bytes: .max))
        XCTAssertEqual(result.outcome, .finished)
        XCTAssertEqual(result.candidateFiles, 1)
        XCTAssertEqual(result.entriesVisited, 1)
        XCTAssertEqual(result.directoriesOpened, 1)
        XCTAssertEqual(result.metadataBytes, metadataBytes(fixture.file("one.jsonl")))
    }

    func testRestartReplaysUnfinishedDirectoryFromHeadWithoutDuplicatingDirtyRevision() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        var store: CollectorInventoryStore? = try fixture.openRegistered(owner: "run-1")
        let scan = try store!.beginBootstrap(configuration: fixture.configuration, scanID: "scan")
        let source = finiteSource(fixture, count: 3)
        var walker: CollectorBootstrapWalker? = CollectorBootstrapWalker(store: store!, enumerator: source)
        XCTAssertEqual(try walker!.step(scan: scan, budget: budget(entries: 2)).entriesVisited, 2)
        let before = try XCTUnwrap(store!.locator(configuration: fixture.configuration, relativePath: "f0.jsonl"))
        walker = nil
        store = nil

        let reopened = try fixture.open(owner: "run-2")
        XCTAssertEqual(try reopened.rootState(rootID: fixture.configuration.rootID)?.activeScan, scan)
        let replay = finiteSource(fixture, count: 3)
        let completed = try CollectorBootstrapWalker(store: reopened, enumerator: replay).step(scan: scan, budget: budget())
        XCTAssertEqual(completed.outcome, .finished)
        XCTAssertEqual(replay.nextCalls, 4, "unfinished directories restart at their head, not an opaque offset")
        XCTAssertEqual(replay.openedDirectories, [""])
        XCTAssertEqual(try reopened.locator(configuration: fixture.configuration, relativePath: "f0.jsonl"), before)
        XCTAssertEqual(try reopened.pendingLocators(configuration: fixture.configuration, limit: 10).count, 3)
    }

    func testRestartKeepsCompletedParentCheckpointAndOpensOnlyRemainingChild() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        var store: CollectorInventoryStore? = try fixture.openRegistered(owner: "run-1")
        let scan = try store!.beginBootstrap(configuration: fixture.configuration, scanID: "scan")
        var walker: CollectorBootstrapWalker? = CollectorBootstrapWalker(store: store!, enumerator: nestedSource(fixture))
        _ = try walker!.step(scan: scan, budget: budget(directories: 1))
        XCTAssertEqual(try store!.pendingDirectories(scan: scan, limit: 10), ["nested"])
        walker = nil
        store = nil
        let reopened = try fixture.open(owner: "run-2")
        let replay = nestedSource(fixture)
        XCTAssertEqual(try CollectorBootstrapWalker(store: reopened, enumerator: replay).step(scan: scan, budget: budget()).outcome, .finished)
        XCTAssertEqual(replay.openedDirectories, ["nested"])
    }

    func testEnumerationFailureIsNotEOFAndRetainsReconciliationRequirement() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        let store = try fixture.openRegistered()
        let scan = try store.beginBootstrap(configuration: fixture.configuration, scanID: "scan")
        let source = SyntheticCollectorEnumerator { _, _ in throw SyntheticCollectorEnumerationFailure.permissionDenied }
        let result = try CollectorBootstrapWalker(store: store, enumerator: source).step(scan: scan, budget: budget())
        XCTAssertEqual(result.outcome, .blocked(.enumerationUnavailable))
        XCTAssertEqual(try store.pendingDirectories(scan: scan, limit: 10), [""])
        let state = try XCTUnwrap(store.rootState(rootID: fixture.configuration.rootID))
        XCTAssertGreaterThan(state.requestedRevision, state.completedRevision)
        XCTAssertEqual(state.lastScanFailure, .enumerationUnavailable)
        XCTAssertFalse(try store.finishBootstrap(scan))
    }

    func testSymlinkIsNotDescendedAndTraversalEntryBlocksRatherThanEscapingKnownRoot() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        let store = try fixture.openRegistered()
        let scan = try store.beginBootstrap(configuration: fixture.configuration, scanID: "scan")
        let source = SyntheticCollectorEnumerator { _, index in
            if index == 0 { return .symlink("linked") }
            if index == 1 { return .file(fixture.file("../escape.jsonl")) }
            XCTFail("unsafe entry did not stop enumeration")
            return nil
        }
        let result = try CollectorBootstrapWalker(store: store, enumerator: source).step(scan: scan, budget: budget())
        XCTAssertEqual(result.outcome, .blocked(.unsafeEntry))
        XCTAssertEqual(result.entriesVisited, 2)
        XCTAssertEqual(source.openedDirectories, [""])
        XCTAssertEqual(source.openedConfigurations, [fixture.configuration])
        XCTAssertTrue(try store.pendingLocators(configuration: fixture.configuration, limit: 10).isEmpty)
        XCTAssertEqual(try store.pendingDirectories(scan: scan, limit: 10), [""])
    }

    func testDiskPressurePausesWithoutSourceIOOrCompletion() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        let store = try fixture.openRegistered()
        let scan = try store.beginBootstrap(configuration: fixture.configuration, scanID: "scan")
        let source = finiteSource(fixture, count: 1)
        let result = try CollectorBootstrapWalker(store: store, enumerator: source)
            .step(scan: scan, budget: budget(), storageAvailable: false)
        XCTAssertEqual(result.outcome, .paused(.diskPressure))
        XCTAssertEqual(result.entriesVisited, 0)
        XCTAssertTrue(source.openedDirectories.isEmpty)
        XCTAssertEqual(source.nextCalls, 0)
        XCTAssertEqual(try store.pendingDirectories(scan: scan, limit: 10), [""])
        XCTAssertFalse(try store.finishBootstrap(scan))
    }

    func testFailedCommitDiscardsProcessCursorAndReplaysDirectoryOnNextStep() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        var shouldFail = false
        let store = try fixture.openRegistered(hooks: .init(beforeCommit: {
            if shouldFail { throw CollectorInventoryInjectedFailure.beforeCommit }
        }))
        let scan = try store.beginBootstrap(configuration: fixture.configuration, scanID: "scan")
        let source = finiteSource(fixture, count: 3)
        let walker = CollectorBootstrapWalker(store: store, enumerator: source)
        shouldFail = true
        XCTAssertThrowsError(try walker.step(scan: scan, budget: budget())) {
            XCTAssertEqual($0 as? CollectorInventoryInjectedFailure, .beforeCommit)
        }
        shouldFail = false
        XCTAssertTrue(try store.pendingLocators(configuration: fixture.configuration, limit: 10).isEmpty)
        XCTAssertEqual(try store.pendingDirectories(scan: scan, limit: 10), [""])
        XCTAssertEqual(try walker.step(scan: scan, budget: budget()).outcome, .finished)
        XCTAssertEqual(source.openedDirectories, ["", ""])
        XCTAssertEqual(try store.pendingLocators(configuration: fixture.configuration, limit: 10).count, 3)
    }

    func testGapArrivingDuringWalkRemainsPendingAfterThatWalkFinishes() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        let store = try fixture.openRegistered()
        let scan = try store.beginBootstrap(configuration: fixture.configuration, scanID: "scan")
        let source = SyntheticCollectorEnumerator { _, index in
            guard index == 0 else { return nil }
            try store.requestReconciliation(configuration: fixture.configuration)
            return .file(fixture.file("one.jsonl"))
        }
        let result = try CollectorBootstrapWalker(store: store, enumerator: source).step(scan: scan, budget: budget())
        XCTAssertEqual(result.outcome, .finished)
        let state = try XCTUnwrap(store.rootState(rootID: fixture.configuration.rootID))
        XCTAssertEqual(state.completedRevision, scan.requestedRevision)
        XCTAssertGreaterThan(state.requestedRevision, state.completedRevision)
    }

    func testCancellationThrownInsideNextDoesNotCommitPartialBatchOrClearGap() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        let store = try fixture.openRegistered()
        let scan = try store.beginBootstrap(configuration: fixture.configuration, scanID: "scan")
        var shouldCancel = true
        let source = SyntheticCollectorEnumerator { _, index in
            if index == 0 { return .file(fixture.file("one.jsonl")) }
            if shouldCancel { throw CancellationError() }
            return nil
        }
        let walker = CollectorBootstrapWalker(store: store, enumerator: source)
        XCTAssertThrowsError(try walker.step(scan: scan, budget: budget())) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(source.nextCalls, 2)
        XCTAssertNil(try store.locator(configuration: fixture.configuration, relativePath: "one.jsonl"))
        XCTAssertEqual(try store.pendingDirectories(scan: scan, limit: 10), [""])
        try assertScanStillPending(store, fixture: fixture, scan: scan)
        shouldCancel = false
        XCTAssertEqual(try walker.step(scan: scan, budget: budget()).outcome, .finished)
        XCTAssertEqual(source.openedDirectories, ["", ""])
    }

    func testCancellationSetInsideNextReturningEOFDoesNotCommitBatchOrDirectoryCompletion() async throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        let store = try fixture.openRegistered()
        let scan = try store.beginBootstrap(configuration: fixture.configuration, scanID: "scan")
        let stepBudget = budget()
        let cancelled = try await Task {
            try withUnsafeCurrentTask { currentTask in
                XCTAssertNotNil(currentTask)
                let source = SyntheticCollectorEnumerator { _, index in
                    if index == 0 { return .file(fixture.file("one.jsonl")) }
                    currentTask?.cancel()
                    return nil
                }
                let walker = CollectorBootstrapWalker(store: store, enumerator: source)
                do {
                    _ = try walker.step(scan: scan, budget: stepBudget)
                    return false
                } catch is CancellationError {
                    XCTAssertEqual(source.nextCalls, 2)
                    return true
                }
            }
        }.value
        XCTAssertTrue(cancelled)
        try assertScanStillPending(store, fixture: fixture, scan: scan)
        XCTAssertNil(try store.locator(configuration: fixture.configuration, relativePath: "one.jsonl"))
        XCTAssertEqual(try store.pendingDirectories(scan: scan, limit: 10), [""])
        let replay = finiteSource(fixture, count: 1)
        XCTAssertEqual(try CollectorBootstrapWalker(store: store, enumerator: replay).step(scan: scan, budget: budget()).outcome, .finished)
        XCTAssertEqual(replay.openedDirectories, [""])
    }

    func testCancellationSetInsideNextReturningLastBudgetFileCannotCommitOrReturnPaused() async throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        let store = try fixture.openRegistered()
        let scan = try store.beginBootstrap(configuration: fixture.configuration, scanID: "scan")
        let stepBudget = budget(entries: 1)
        let cancelled = try await Task {
            try withUnsafeCurrentTask { currentTask in
                XCTAssertNotNil(currentTask)
                let source = SyntheticCollectorEnumerator { _, _ in
                    currentTask?.cancel()
                    return .file(fixture.file("one.jsonl"))
                }
                let walker = CollectorBootstrapWalker(store: store, enumerator: source)
                do {
                    let result = try walker.step(scan: scan, budget: stepBudget)
                    XCTFail("Cancelled next() returned \(result.outcome) instead of cancellation")
                    return false
                } catch is CancellationError {
                    XCTAssertEqual(source.nextCalls, 1)
                    return true
                }
            }
        }.value
        XCTAssertTrue(cancelled)
        XCTAssertNil(try store.locator(configuration: fixture.configuration, relativePath: "one.jsonl"))
        XCTAssertEqual(try store.pendingDirectories(scan: scan, limit: 10), [""])
        try assertScanStillPending(store, fixture: fixture, scan: scan)
    }

    func testCancellationThrownBeforeCommitRollsBackAndReplaysWithoutClearingGap() throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        var shouldCancel = false
        let store = try fixture.openRegistered(hooks: .init(beforeCommit: {
            if shouldCancel { throw CancellationError() }
        }))
        let scan = try store.beginBootstrap(configuration: fixture.configuration, scanID: "scan")
        let source = finiteSource(fixture, count: 1)
        let walker = CollectorBootstrapWalker(store: store, enumerator: source)
        shouldCancel = true
        XCTAssertThrowsError(try walker.step(scan: scan, budget: budget())) { XCTAssertTrue($0 is CancellationError) }
        shouldCancel = false
        XCTAssertEqual(source.nextCalls, 2)
        XCTAssertNil(try store.locator(configuration: fixture.configuration, relativePath: "f0.jsonl"))
        XCTAssertEqual(try store.pendingDirectories(scan: scan, limit: 10), [""])
        try assertScanStillPending(store, fixture: fixture, scan: scan)
        XCTAssertEqual(try walker.step(scan: scan, budget: budget()).outcome, .finished)
        XCTAssertEqual(source.openedDirectories, ["", ""])
    }

    func testCancellationAfterDirectoryCommitPreservesCommittedProgressButNotScanCompletion() async throws {
        let fixture = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        let database = try fixture.openDatabase()
        let store = try CollectorInventoryStore(database: database, machineID: fixture.machineID, ownerRunID: "run-1")
        try store.registerRoot(fixture.configuration)
        let scan = try store.beginBootstrap(configuration: fixture.configuration, scanID: "scan")
        let source = finiteSource(fixture, count: 1)
        let walker = CollectorBootstrapWalker(store: store, enumerator: source)
        let stepBudget = budget()
        let cancelled = try await Task {
            try withUnsafeCurrentTask { currentTask in
                XCTAssertNotNil(currentTask)
                let observer = CollectorCommitCancellationProbe { currentTask?.cancel() }
                database.writeWithoutTransaction { $0.add(transactionObserver: observer) }
                defer {
                    // The borrowed task handle must not escape this scope even
                    // when a failing test never reaches its expected commit.
                    observer.onCommit = nil
                    database.writeWithoutTransaction { $0.remove(transactionObserver: observer) }
                }
                do {
                    _ = try walker.step(scan: scan, budget: stepBudget)
                    return false
                } catch is CancellationError {
                    XCTAssertEqual(observer.commits, 1)
                    return true
                }
            }
        }.value
        XCTAssertTrue(cancelled)
        try assertScanStillPending(store, fixture: fixture, scan: scan)
        XCTAssertNotNil(try store.locator(configuration: fixture.configuration, relativePath: "f0.jsonl"))
        XCTAssertTrue(try store.pendingDirectories(scan: scan, limit: 10).isEmpty)
        XCTAssertEqual(try walker.step(scan: scan, budget: budget()).outcome, .finished)
        XCTAssertEqual(source.openedDirectories, [""])
    }

    private func assertScanStillPending(
        _ store: CollectorInventoryStore,
        fixture: CollectorInventoryTestFixture,
        scan: CollectorScanToken,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let state = try XCTUnwrap(store.rootState(rootID: fixture.configuration.rootID), file: file, line: line)
        XCTAssertEqual(state.activeScan, scan, file: file, line: line)
        XCTAssertEqual(state.completedRevision, 0, file: file, line: line)
        XCTAssertEqual(state.requestedRevision, scan.requestedRevision, file: file, line: line)
        XCTAssertGreaterThan(state.requestedRevision, state.completedRevision, file: file, line: line)
        XCTAssertNil(state.lastScanFailure, file: file, line: line)
    }

    private func budget(entries: Int = 100, files: Int = 100, directories: Int = 10, bytes: Int = 10_000) -> CollectorBootstrapBudget {
        CollectorBootstrapBudget(maxEntriesVisited: entries, maxCandidateFiles: files, maxDirectoryOpens: directories, maxMetadataBytes: bytes)
    }

    private func metadataBytes(_ file: CollectorObservedFile) -> Int {
        file.relativePath.utf8.count + file.observedGeneration.utf8.count
    }

    private func finiteSource(_ fixture: CollectorInventoryTestFixture, count: Int) -> SyntheticCollectorEnumerator {
        SyntheticCollectorEnumerator { _, index in index < count ? .file(fixture.file("f\(index).jsonl")) : nil }
    }

    private func nestedSource(_ fixture: CollectorInventoryTestFixture) -> SyntheticCollectorEnumerator {
        SyntheticCollectorEnumerator { directory, index in
            guard index == 0 else { return nil }
            return directory.isEmpty ? .directory("nested") : .file(fixture.file("nested/one.jsonl"))
        }
    }
}

private enum SyntheticCollectorEnumerationFailure: Error { case permissionDenied }

private final class CollectorCommitCancellationProbe: TransactionObserver {
    var onCommit: (() -> Void)?
    private(set) var commits = 0

    init(onCommit: @escaping () -> Void) { self.onCommit = onCommit }
    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { false }
    func databaseDidChange(with event: DatabaseEvent) {}
    func databaseDidCommit(_ db: Database) { commits += 1; onCommit?() }
    func databaseDidRollback(_ db: Database) {}
}

private final class SyntheticCollectorEnumerator: CollectorRootEnumerator {
    private let entry: (String, Int) throws -> CollectorDirectoryEntry?
    private(set) var openedDirectories: [String] = []
    private(set) var openedConfigurations: [CollectorRootConfiguration] = []
    private(set) var nextCalls = 0

    init(entry: @escaping (String, Int) throws -> CollectorDirectoryEntry?) { self.entry = entry }

    func open(configuration: CollectorRootConfiguration, relativeDirectory: String) throws -> any CollectorDirectoryCursor {
        openedDirectories.append(relativeDirectory)
        openedConfigurations.append(configuration)
        return SyntheticCollectorCursor { [self] index in
            nextCalls += 1
            return try entry(relativeDirectory, index)
        }
    }
}

private final class SyntheticCollectorCursor: CollectorDirectoryCursor {
    private let entry: (Int) throws -> CollectorDirectoryEntry?
    private var index = 0

    init(entry: @escaping (Int) throws -> CollectorDirectoryEntry?) { self.entry = entry }

    func next() throws -> CollectorDirectoryEntry? {
        defer { index += 1 }
        return try entry(index)
    }
}
