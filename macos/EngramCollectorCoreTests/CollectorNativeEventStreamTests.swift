import CoreServices
import Darwin
import Foundation
import GRDB
import XCTest
@testable import EngramCollectorCore

// N3-B2 test DRAFT, not an executed RED or passing implementation claim.
// All native callbacks below enter the callback captured by API.create. There
// is deliberately no independent Swift-array decoder in the fixture. Unit tests
// perform no filesystem access; integration tests use only their own temporary
// Owner fixture and the same FAKE native API, never a real FSEvents stream.
final class CollectorNativeEventStreamTests: XCTestCase {
    // 01: Cold construction and never-started stop have no native/FS effects.
    func testConstructionAndNeverStartedStopAreColdAndIdempotent() throws {
        let rig = NativeDraftRig()
        XCTAssertTrue(rig.api.calls.isEmpty)
        try rig.stream.stop()
        try rig.stream.stop()
        XCTAssertTrue(rig.api.calls.isEmpty)
    }

    // 02: Native cursor grammar is stronger than the frozen opaque Owner DTO.
    func testInvalidDurableCursorsFailBeforeCreateWithoutRebase() {
        for cursor in ["", "0", "00", "01", "+1", "-1", " 1", "1 ", "1\n", "1.0", "１",
                       String(UInt64.max), "18446744073709551616", "1\0"] {
            let rig = NativeDraftRig(cursor: cursor)
            XCTAssertThrowsError(try rig.start()) {
                XCTAssertEqual($0 as? CollectorNativeEventStreamError, .invalidCheckpoint, cursor)
            }
            XCTAssertEqual(rig.api.count("create"), 0, cursor)
            XCTAssertEqual(rig.request.resumeCheckpoint?.cursor, cursor)
            XCTAssertTrue(rig.inbox.signals.isEmpty)
        }
    }

    // 03: Both finite boundary IDs are accepted; SinceNow is never durable.
    func testCanonicalFiniteCursorBoundariesReachCreateUnchanged() throws {
        for id in [UInt64(1), UInt64.max - 1] {
            let rig = NativeDraftRig(cursor: String(id))
            defer { try? rig.stream.stop() }
            try rig.start()
            XCTAssertEqual(rig.api.created?.sinceWhen, id)
            XCTAssertEqual(rig.inbox.historyCount, 0)
        }
    }

    // 04: Namespace spelling and UUID spelling are exact bytes, not aliases.
    func testInvalidEpochNamespacesAndNoncanonicalUUIDsFailClosed() {
        for epoch in ["", NativeDraft.uuid, "fsevents-device-v2:\(NativeDraft.uuid)",
                      "fsevents-device-v1:\(NativeDraft.uuid.lowercased())",
                      NativeDraft.epoch + " ", NativeDraft.epoch + "\0"] {
            let rig = NativeDraftRig(requestEpoch: epoch)
            XCTAssertThrowsError(try rig.start()) {
                XCTAssertEqual($0 as? CollectorNativeEventStreamError, .invalidEpoch)
            }
            XCTAssertEqual(rig.api.count("create"), 0)
        }
    }

    // 05: Request epoch, stored checkpoint epoch, and current DB UUID all agree.
    func testCheckpointEpochMismatchDoesNotClearOrReplaceExistingCheckpoint() {
        let rig = NativeDraftRig(checkpointEpoch: "fsevents-device-v1:\(NativeDraft.otherUUID)")
        XCTAssertThrowsError(try rig.start()) {
            XCTAssertEqual($0 as? CollectorNativeEventStreamError, .invalidEpoch)
        }
        XCTAssertEqual(rig.api.count("create"), 0)
        XCTAssertEqual(rig.request.resumeCheckpoint?.cursor, "10")
        XCTAssertEqual(rig.request.resumeCheckpoint?.epoch, "fsevents-device-v1:\(NativeDraft.otherUUID)")
    }

    // 06: UUID absence/change is not permission to reset history automatically.
    func testMissingOrChangedCurrentDatabaseUUIDRejectsExistingCheckpoint() {
        for uuid in [Optional<String>.none, Optional(NativeDraft.otherUUID)] {
            let rig = NativeDraftRig()
            rig.api.observations = [NativeDraft.observation(uuid: uuid)]
            XCTAssertThrowsError(try rig.start()) {
                XCTAssertEqual($0 as? CollectorNativeEventStreamError, .invalidEpoch)
            }
            XCTAssertEqual(rig.api.count("create"), 0)
            XCTAssertEqual(rig.api.count("close"), 1)
            XCTAssertTrue(rig.inbox.signals.isEmpty)
        }
    }

    // 07: Per-device relative-root creation; no CFTypes, IgnoreSelf, or absolute guess.
    func testCreateUsesObservedVolumeMappingAndRequiredFlagsOnly() throws {
        let rig = NativeDraftRig()
        defer { try? rig.stream.stop() }
        try rig.start()
        let request = try XCTUnwrap(rig.api.created)
        XCTAssertEqual(request.device, 7)
        XCTAssertEqual(request.volumeRelativeRoot, NativeDraft.relativeRoot)
        XCTAssertEqual(request.sinceWhen, 10)
        XCTAssertEqual(request.flags, FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot
            | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagFullHistory))
    }

    // 08: Nil checkpoint has a synthetic barrier, but never a synthetic cursor.
    func testNilCheckpointUsesSinceNowAndSyntheticHistoryAfterPostStartFenceOnSameQueue() throws {
        let rig = NativeDraftRig(cursor: nil)
        var historyOnQueue = false
        rig.inbox.onSignal = { signal in
            if case .historyDone = signal {
                historyOnQueue = rig.api.isOnCallbackQueue
                XCTAssertEqual(rig.api.count("observe"), 2)
                XCTAssertEqual(rig.api.count("start"), 1)
            }
        }
        defer { try? rig.stream.stop() }
        try rig.start()
        XCTAssertEqual(rig.api.created?.sinceWhen, FSEventStreamEventId(kFSEventStreamEventIdSinceNow))
        XCTAssertEqual(rig.inbox.historyCount, 1)
        XCTAssertTrue(historyOnQueue)
        XCTAssertTrue(rig.inbox.batches.isEmpty)
        XCTAssertNil(rig.request.resumeCheckpoint)
    }

    // 09: Events delivered during Start precede the synthetic recovery barrier.
    func testNilCheckpointStartCallbackOrdersRealBatchBeforeSyntheticHistory() throws {
        let rig = NativeDraftRig(cursor: nil)
        rig.api.onStart = { rig.api.emit([NativeDraft.event("early.jsonl", 11)]) }
        defer { try? rig.stream.stop() }
        try rig.start()
        XCTAssertEqual(rig.inbox.kinds, ["batch", "history"])
        XCTAssertEqual(rig.inbox.batches.first?.nextCheckpoint.cursor, "11")
    }

    // 10: Failed post-start fence must not fake HistoryDone or leave a subscription.
    func testNilCheckpointFailedPostStartFenceEmitsNoSyntheticHistoryAndCleansResources() {
        let rig = NativeDraftRig(cursor: nil)
        rig.api.observations = [NativeDraft.observation(), NativeDraft.observation(route: NativeDraft.otherIdentity)]
        XCTAssertThrowsError(try rig.start()) {
            XCTAssertEqual($0 as? CollectorNativeEventStreamError, .invalidRoot)
        }
        XCTAssertEqual(rig.inbox.historyCount, 0)
        assertCleanup(rig.api, stop: 1, invalidate: 1, release: 1, close: 1)
    }

    // 11: Native HistoryDone remains mandatory for any persisted checkpoint.
    func testNonNilCheckpointDoesNotSynthesizeNativeReplayCompletion() throws {
        let rig = NativeDraftRig()
        defer { try? rig.stream.stop() }
        try rig.start()
        rig.api.emit([NativeDraft.event("replayed.jsonl", 11)])
        XCTAssertEqual(rig.inbox.historyCount, 0)
        rig.api.emit([.init(bytes: [0xFF], flags: NativeDraft.history, id: 0)])
        XCTAssertEqual(rig.inbox.historyCount, 1)
        XCTAssertTrue(rig.inbox.losses.isEmpty)
    }

    // 12: Apple's FullHistory can replay below sinceWhen; keep every dirty path.
    func testFullHistoryLowerRepeatedAndOutOfOrderIDsKeepPathsAndMonotonicHighWater() throws {
        let rig = NativeDraftRig()
        defer { try? rig.stream.stop() }
        try rig.start()
        rig.api.emit([NativeDraft.event("low.jsonl", 3), NativeDraft.event("equal.jsonl", 10),
                      NativeDraft.event("new.jsonl", 12), NativeDraft.event("repeat.jsonl", 3)])
        rig.api.emit([NativeDraft.event("later-low.jsonl", 4)])
        XCTAssertEqual(rig.inbox.batches.map(\.dirtyRelativePaths),
                       [["low.jsonl", "equal.jsonl", "new.jsonl", "repeat.jsonl"], ["later-low.jsonl"]])
        XCTAssertEqual(rig.inbox.batches.map { $0.nextCheckpoint.cursor }, ["12", "12"])
        XCTAssertTrue(rig.inbox.losses.isEmpty)
    }

    // 13: HistoryDone is an ordered control record, not an ordinary dirty path.
    func testNativeHistoryInsideCallbackPreservesBeforeAndAfterOrdering() throws {
        let rig = NativeDraftRig()
        defer { try? rig.stream.stop() }
        try rig.start()
        rig.api.emit([NativeDraft.event("old.jsonl", 8), NativeDraft.historyEvent,
                      NativeDraft.event("live.jsonl", 11)])
        XCTAssertEqual(rig.inbox.kinds, ["batch", "history", "batch"])
        XCTAssertEqual(rig.inbox.batches.map { $0.nextCheckpoint.cursor }, ["10", "11"])
        XCTAssertEqual(rig.inbox.batches.map(\.dirtyRelativePaths), [["old.jsonl"], ["live.jsonl"]])
    }

    // 14: Replay tolerance is not permission for unexplained live regression.
    func testLiveIDRegressionAfterNativeHistoryRequiresReconciliation() throws {
        let rig = NativeDraftRig()
        defer { try? rig.stream.stop() }
        try rig.start()
        rig.api.emit([NativeDraft.historyEvent])
        rig.api.emit([NativeDraft.event("new.jsonl", 12)])
        rig.api.emit([NativeDraft.event("regressed.jsonl", 11)])
        XCTAssertEqual(rig.inbox.losses, [.continuityLoss])
        XCTAssertEqual(rig.inbox.batches.map { $0.nextCheckpoint.cursor }, ["12"])
    }

    // 15: User/kernel drop is overflow; the signal latches exactly once.
    func testNativeDroppedFlagsAreOverflowAndLatchOnce() throws {
        for flag in [kFSEventStreamEventFlagUserDropped, kFSEventStreamEventFlagKernelDropped] {
            let rig = NativeDraftRig()
            defer { try? rig.stream.stop() }
            try rig.start()
            let drop = NativeDraftEvent(bytes: [], flags: FSEventStreamEventFlags(flag), id: 0)
            rig.api.emit([drop])
            rig.api.emit([drop, NativeDraft.historyEvent, NativeDraft.event("ignored.jsonl", 12)])
            XCTAssertEqual(rig.inbox.losses, [.overflow])
            XCTAssertEqual(rig.inbox.historyCount, 0)
            XCTAssertTrue(rig.inbox.batches.isEmpty)
        }
    }

    // 16: Structural reconciliation is application-level, not alleged OS loss.
    func testRootMountWrapAndMustScanFlagsRequireContinuityReconciliation() throws {
        for flag in [kFSEventStreamEventFlagMustScanSubDirs, kFSEventStreamEventFlagRootChanged,
                     kFSEventStreamEventFlagEventIdsWrapped, kFSEventStreamEventFlagMount,
                     kFSEventStreamEventFlagUnmount] {
            let rig = NativeDraftRig()
            defer { try? rig.stream.stop() }
            try rig.start()
            rig.api.emit([.init(bytes: [], flags: FSEventStreamEventFlags(flag), id: 0)])
            XCTAssertEqual(rig.inbox.losses, [.continuityLoss])
            XCTAssertTrue(rig.inbox.batches.isEmpty)
        }
    }

    // 17: A moved-in populated directory cannot become one ordinary locator.
    func testDirectoryAndUnknownTypeEventsRequireReconciliation() throws {
        for flags in [FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemRenamed),
                      FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemCreated),
                      FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir),
                      FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed), 0] {
            let rig = NativeDraftRig()
            defer { try? rig.stream.stop() }
            try rig.start()
            rig.api.emit([NativeDraft.event("directory", 11, flags: flags)])
            XCTAssertEqual(rig.inbox.losses, [.continuityLoss])
            XCTAssertTrue(rig.inbox.batches.isEmpty)
        }
    }

    // 18: Ordinary file creates/modifies/removes/renames remain bounded batches.
    func testFileLevelChangesDoNotForceInventoryReconciliation() throws {
        let rig = NativeDraftRig()
        defer { try? rig.stream.stop() }
        try rig.start()
        for (index, flag) in [kFSEventStreamEventFlagItemCreated, kFSEventStreamEventFlagItemModified,
                              kFSEventStreamEventFlagItemRemoved, kFSEventStreamEventFlagItemRenamed].enumerated() {
            rig.api.emit([NativeDraft.event("item-\(index).jsonl", UInt64(11 + index),
                                           flags: FSEventStreamEventFlags(flag | kFSEventStreamEventFlagItemIsFile))])
        }
        XCTAssertEqual(rig.inbox.batches.count, 4)
        XCTAssertTrue(rig.inbox.losses.isEmpty)
    }

    // 19: Validate whole callback before any prefix or HistoryDone is admitted.
    func testLossAnywhereDominatesOrdinaryPrefixAndHistoryControl() throws {
        for position in 0..<3 {
            let rig = NativeDraftRig()
            defer { try? rig.stream.stop() }
            try rig.start()
            var events = [NativeDraft.event("valid.jsonl", 11), NativeDraft.historyEvent]
            events.insert(.init(bytes: [], flags: FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped), id: 0),
                          at: position)
            rig.api.emit(events)
            XCTAssertEqual(rig.inbox.kinds, ["loss"])
            XCTAssertEqual(rig.inbox.losses, [.overflow])
        }
    }

    // 20: Count rejection must precede any C table, flag, or ID dereference.
    func testOverBudgetRawCountWithNilPointersIsRejectedBeforeCopy() throws {
        let rig = NativeDraftRig(budget: NativeDraft.budget(paths: 1))
        defer { try? rig.stream.stop() }
        try rig.start()
        rig.api.emitRaw(count: 2, paths: nil, flags: nil, ids: nil)
        XCTAssertEqual(rig.inbox.losses, [.budgetExceeded])
        XCTAssertTrue(rig.inbox.batches.isEmpty)
    }

    // 21: Empty callbacks are harmless, not fake checkpoints or history.
    func testZeroRawCountDoesNotReadBuffersOrEmitSignals() throws {
        let rig = NativeDraftRig()
        defer { try? rig.stream.stop() }
        try rig.start()
        rig.api.emitRaw(count: 0, paths: nil, flags: nil, ids: nil)
        XCTAssertTrue(rig.inbox.signals.isEmpty)
    }

    // 22: Nonempty callbacks require all three borrowed arrays.
    func testMissingRawArraysFailClosedWithoutPartialAdmission() throws {
        for missing in 0..<3 {
            let rig = NativeDraftRig()
            defer { try? rig.stream.stop() }
            try rig.start()
            rig.api.emit([NativeDraft.event("valid.jsonl", 11)], missingArray: missing)
            XCTAssertEqual(rig.inbox.losses, [.continuityLoss])
            XCTAssertTrue(rig.inbox.batches.isEmpty)
        }
    }

    // 23: A null C string pointer is not an empty, root-relative file.
    func testNullPathEntryRejectsWholeCallback() throws {
        let rig = NativeDraftRig()
        defer { try? rig.stream.stop() }
        try rig.start()
        rig.api.emit([NativeDraft.event("valid.jsonl", 11), NativeDraft.event("second.jsonl", 12)], nilPathIndex: 1)
        XCTAssertEqual(rig.inbox.losses, [.continuityLoss])
        XCTAssertTrue(rig.inbox.batches.isEmpty)
    }

    // 24: Strict UTF-8 rejection, no replacement-character path alias.
    func testInvalidUTF8SuffixRejectsValidPrefixAtomically() throws {
        let rig = NativeDraftRig()
        defer { try? rig.stream.stop() }
        try rig.start()
        rig.api.emit([NativeDraft.event("valid.jsonl", 11),
                      .init(bytes: Array((NativeDraft.relativeRoot + "/").utf8) + [0xFF], flags: NativeDraft.file, id: 12)])
        XCTAssertEqual(rig.inbox.losses, [.continuityLoss])
        XCTAssertTrue(rig.inbox.batches.isEmpty)
    }

    // 25: Per-path limit is UTF-8 bytes after the exact volume/root prefix.
    func testPerPathBudgetHasExactByteBoundaryAndBoundedCStringScan() throws {
        let allowed = NativeDraftRig(budget: NativeDraft.budget(perPath: 8))
        defer { try? allowed.stream.stop() }
        try allowed.start()
        allowed.api.emit([NativeDraft.event("éééé", 11)])
        XCTAssertEqual(allowed.inbox.batches.first?.dirtyRelativePaths, ["éééé"])
        let oversized = NativeDraftRig(budget: NativeDraft.budget(perPath: 8))
        defer { try? oversized.stream.stop() }
        try oversized.start()
        oversized.api.emit([NativeDraft.event(String(repeating: "x", count: 4096), 11)])
        XCTAssertEqual(oversized.inbox.losses, [.budgetExceeded])
        XCTAssertTrue(oversized.inbox.batches.isEmpty)
    }

    // 26: Duplicate paths still consume callback budget; reject before dedup.
    func testAggregatePathBudgetCountsDuplicateUTF8BytesBeforeAdmission() throws {
        let rig = NativeDraftRig(budget: NativeDraft.budget(total: 7))
        defer { try? rig.stream.stop() }
        try rig.start()
        rig.api.emit([NativeDraft.event("éé", 11), NativeDraft.event("éé", 12)])
        XCTAssertEqual(rig.inbox.losses, [.budgetExceeded])
        XCTAssertTrue(rig.inbox.batches.isEmpty)
    }

    // 27: A generated checkpoint is also bounded, not just dirty path bytes.
    func testNextCheckpointBudgetRejectsWithoutForwardingCandidate() throws {
        let rig = NativeDraftRig(cursor: nil, budget: NativeDraft.budget(checkpoints: NativeDraft.epoch.utf8.count + 4))
        defer { try? rig.stream.stop() }
        try rig.start()
        rig.api.emit([NativeDraft.event("x", 12345)])
        XCTAssertEqual(rig.inbox.losses, [.budgetExceeded])
        XCTAssertTrue(rig.inbox.batches.isEmpty)
    }

    // 28: Byte paths must be strict descendants, not prefix/normalization aliases.
    func testUnsafeAndOutsideRootPathsRequireReconciliation() throws {
        for path in ["", "/" + NativeDraft.relativeRoot + "/a", NativeDraft.relativeRoot,
                     NativeDraft.relativeRoot + "-sibling/a", NativeDraft.relativeRoot + "/../a",
                     NativeDraft.relativeRoot + "/./a", NativeDraft.relativeRoot + "//a",
                     NativeDraft.relativeRoot + "/a/", "Users/elsewhere/a"] {
            let rig = NativeDraftRig()
            defer { try? rig.stream.stop() }
            try rig.start()
            rig.api.emit([.init(bytes: Array(path.utf8), flags: NativeDraft.file, id: 11)])
            XCTAssertEqual(rig.inbox.losses, [.continuityLoss], path)
            XCTAssertTrue(rig.inbox.batches.isEmpty, path)
        }
    }

    // 29: Do not let Unicode-equivalent prefix spellings cross byte identity.
    func testUnicodeEquivalentButByteDifferentRootPrefixIsRejected() throws {
        let rig = NativeDraftRig()
        rig.api.observations = [NativeDraft.observation(physical: NativeDraft.mount + "/Users/fixture/café")]
        defer { try? rig.stream.stop() }
        try rig.start()
        rig.api.emit([.init(bytes: Array("Users/fixture/cafe\u{301}/a".utf8), flags: NativeDraft.file, id: 11)])
        XCTAssertEqual(rig.inbox.losses, [.continuityLoss])
        XCTAssertTrue(rig.inbox.batches.isEmpty)
    }

    // 30: Existing relative-component bounds remain in force.
    func testExcessiveRelativeDepthIsNotForwarded() throws {
        let rig = NativeDraftRig()
        defer { try? rig.stream.stop() }
        try rig.start()
        rig.api.emit([NativeDraft.event(Array(repeating: "a", count: 33).joined(separator: "/"), 11)])
        XCTAssertEqual(rig.inbox.losses, [.continuityLoss])
        XCTAssertTrue(rig.inbox.batches.isEmpty)
    }

    // 31: The signal owns bytes after C arrays are poisoned and freed.
    func testCallbackCopiesBorrowedPathsAndIDsBeforeReturn() throws {
        let rig = NativeDraftRig()
        defer { try? rig.stream.stop() }
        try rig.start()
        rig.api.emit([NativeDraft.event("sub/会话.jsonl", 11)])
        XCTAssertEqual(rig.inbox.batches.first?.dirtyRelativePaths, ["sub/会话.jsonl"])
        XCTAssertEqual(rig.inbox.batches.first?.nextCheckpoint, .init(epoch: NativeDraft.epoch, cursor: "11"))
    }

    // 32: Native IDs 0/SinceNow are controls only where explicitly documented.
    func testOrdinaryReservedNativeIDsNeverBecomeDurableCheckpoints() throws {
        for id in [UInt64(0), UInt64.max] {
            let rig = NativeDraftRig()
            defer { try? rig.stream.stop() }
            try rig.start()
            rig.api.emit([NativeDraft.event("ordinary.jsonl", id)])
            XCTAssertEqual(rig.inbox.losses, [.continuityLoss])
            XCTAssertTrue(rig.inbox.batches.isEmpty)
        }
    }

    // 33: Closed/recovery admission seals callbacks; no extra loss amplification.
    func testRejectedAdmissionStopsFurtherBatchAndHistoryDelivery() throws {
        for admission in [CollectorEventAdmission.rejectedClosed, .recoveryRequired(.budgetExceeded)] {
            let rig = NativeDraftRig()
            rig.inbox.admission = admission
            defer { try? rig.stream.stop() }
            try rig.start()
            rig.api.emit([NativeDraft.event("first.jsonl", 11)])
            rig.api.emit([NativeDraft.historyEvent, NativeDraft.event("later.jsonl", 12)])
            XCTAssertEqual(rig.inbox.kinds, ["batch"])
        }
    }

    // 34: The callback performs decoding/admission only, no new API/FS work.
    func testCallbackMakesNoFilesystemOrNativeLifecycleCalls() throws {
        let rig = NativeDraftRig()
        defer { try? rig.stream.stop() }
        try rig.start()
        let before = rig.api.calls
        rig.api.emit([NativeDraft.event("ordinary.jsonl", 11), NativeDraft.historyEvent])
        XCTAssertEqual(rig.api.calls, before)
        XCTAssertEqual(rig.inbox.kinds, ["batch", "history"])
    }

    // 35: Invalid budget fails before acquiring any descriptor or stream.
    func testNegativeBudgetsRejectBeforeRootOpen() {
        for invalid in 0..<4 {
            let rig = NativeDraftRig(budget: NativeDraft.budget(paths: invalid == 0 ? -1 : 16,
                perPath: invalid == 1 ? -1 : 256, total: invalid == 2 ? -1 : 4096,
                checkpoints: invalid == 3 ? -1 : 512))
            XCTAssertThrowsError(try rig.start()) {
                XCTAssertEqual($0 as? CollectorNativeEventStreamError, .invalidBudget)
            }
            XCTAssertTrue(rig.api.calls.isEmpty)
        }
    }

    // 36: Both held-descriptor identity and newly resolved route must match.
    func testPreStartIdentityAndDeviceFencesRejectBeforeCreate() {
        let observations = [NativeDraft.observation(descriptor: NativeDraft.otherIdentity),
                            NativeDraft.observation(route: NativeDraft.otherIdentity),
                            NativeDraft.observation(device: 8), NativeDraft.observation(device: Int64.max)]
        for observation in observations {
            let rig = NativeDraftRig()
            rig.api.observations = [observation]
            XCTAssertThrowsError(try rig.start()) {
                XCTAssertEqual($0 as? CollectorNativeEventStreamError, .invalidRoot)
            }
            XCTAssertEqual(rig.api.count("create"), 0)
            XCTAssertEqual(rig.api.count("close"), 1)
        }
    }

    // 37: Mount containment is component/byte exact; reject ambiguous mapping.
    func testInvalidPhysicalMountMappingFailsBeforeCreate() {
        for physical in [NativeDraft.mount + "-sibling/Users/fixture/sessions", "relative/root",
                         NativeDraft.mount + "/Users/../sessions", NativeDraft.mount + "//sessions"] {
            let rig = NativeDraftRig()
            rig.api.observations = [NativeDraft.observation(physical: physical)]
            XCTAssertThrowsError(try rig.start()) {
                XCTAssertEqual($0 as? CollectorNativeEventStreamError, .invalidRoot)
            }
            XCTAssertEqual(rig.api.count("create"), 0)
            XCTAssertEqual(rig.api.count("close"), 1)
        }
    }

    // 38: Database/root remapping during subscription is not hidden by precheck.
    func testPostStartDatabaseOrPhysicalMappingChangeCleansStartedStream() {
        for after in [NativeDraft.observation(uuid: NativeDraft.otherUUID),
                      NativeDraft.observation(physical: NativeDraft.mount + "/moved/sessions")] {
            let rig = NativeDraftRig()
            rig.api.observations = [NativeDraft.observation(), after]
            XCTAssertThrowsError(try rig.start())
            XCTAssertEqual(rig.inbox.historyCount, 0)
            assertCleanup(rig.api, stop: 1, invalidate: 1, release: 1, close: 1)
        }
    }

    // 39: Normal ownership cleanup order, exactly once, with no queue NULL detach.
    func testExternalStopDrainsAndReleasesEachOwnedResourceExactlyOnce() throws {
        let rig = NativeDraftRig()
        try rig.start()
        try rig.stream.stop()
        try rig.stream.stop()
        XCTAssertEqual(rig.api.calls, ["open", "observe", "create", "schedule", "start", "observe",
                                       "stop", "invalidate", "drain", "release", "close"])
        rig.api.emit([NativeDraft.event("after-stop.jsonl", 11), NativeDraft.historyEvent])
        XCTAssertTrue(rig.inbox.signals.isEmpty)
    }

    // 40: Failed open/observe/create clean only resources actually acquired.
    func testEarlyAPIFailuresDoNotLeakOrInvalidateUnscheduledStream() {
        for operation in ["open", "observe", "create"] {
            let rig = NativeDraftRig()
            rig.api.failure = operation
            XCTAssertThrowsError(try rig.start())
            assertCleanup(rig.api, stop: 0, invalidate: 0, release: 0, close: operation == "open" ? 0 : 1)
            XCTAssertNoThrow(try rig.stream.stop())
        }
    }

    // 41: Null create is a typed failure, not a constructed running stream.
    func testNilCreateClosesRootWithoutStreamCleanupCalls() {
        let rig = NativeDraftRig()
        rig.api.createReturnsNil = true
        XCTAssertThrowsError(try rig.start()) {
            XCTAssertEqual($0 as? CollectorNativeEventStreamError, .createFailed)
        }
        assertCleanup(rig.api, stop: 0, invalidate: 0, release: 0, close: 1)
    }

    // 42: Schedule failure precedes scheduling ownership; no invalid Invalidate.
    func testScheduleFailureReleasesCreatedButUnscheduledStream() {
        let rig = NativeDraftRig()
        rig.api.failure = "schedule"
        XCTAssertThrowsError(try rig.start())
        assertCleanup(rig.api, stop: 0, invalidate: 0, release: 1, close: 1)
    }

    // 43: Start false requires Invalidate/Release, but never native Stop.
    func testFailedNativeStartInvalidatesScheduledStreamWithoutStop() {
        let rig = NativeDraftRig(cursor: nil)
        rig.api.startResult = false
        XCTAssertThrowsError(try rig.start()) {
            XCTAssertEqual($0 as? CollectorNativeEventStreamError, .startFailed)
        }
        assertCleanup(rig.api, stop: 0, invalidate: 1, release: 1, close: 1)
        XCTAssertEqual(rig.inbox.historyCount, 0)
    }

    // 44: An external stop error does not excuse skipped resource destruction.
    func testExternalStopErrorsStillInvalidateDrainReleaseAndClose() throws {
        for operation in ["stop", "invalidate", "drain"] {
            let rig = NativeDraftRig()
            try rig.start()
            rig.api.failure = operation
            XCTAssertThrowsError(try rig.stream.stop()) {
                XCTAssertEqual($0 as? NativeDraftFailure, .injected(operation))
            }
            assertCleanup(rig.api, stop: 1, invalidate: 1, release: 1, close: 1)
            XCTAssertNoThrow(try rig.stream.stop())
            assertCleanup(rig.api, stop: 1, invalidate: 1, release: 1, close: 1)
        }
    }

    // 45: A stream is single-start; a second start cannot replace ownership.
    func testSecondStartRejectsWithoutCreatingAnotherStream() throws {
        let rig = NativeDraftRig()
        defer { try? rig.stream.stop() }
        try rig.start()
        XCTAssertThrowsError(try rig.start()) {
            XCTAssertEqual($0 as? CollectorNativeEventStreamError, .invalidState)
        }
        XCTAssertEqual(rig.api.count("create"), 1)
    }

    // 46: Stop racing native creation must retain the pending cleanup chance.
    func testStopWhileCreateIsBlockedCleansReturnedHandleExactlyOnce() throws {
        let entered = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let sealed = DispatchSemaphore(value: 0)
        let rig = NativeDraftRig(testHooks: .init(didSealForStop: { sealed.signal() }))
        rig.api.onCreate = { entered.signal(); _ = proceed.wait(timeout: .now() + 5) }
        let start = NativeDraftJob { try rig.start() }
        defer { proceed.signal(); try? rig.stream.stop() }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        let stop = NativeDraftJob { try rig.stream.stop() }
        XCTAssertEqual(sealed.wait(timeout: .now() + 5), .success)
        proceed.signal()
        _ = try start.result()
        try stop.success()
        XCTAssertEqual(rig.api.count("release"), 1)
        XCTAssertEqual(rig.api.count("close"), 1)
        XCTAssertLessThanOrEqual(rig.api.count("stop"), 1)
        XCTAssertNoThrow(try rig.stream.stop())
    }

    // 47: Stop racing Start must drain an eventually started subscription.
    func testStopWhileNativeStartIsBlockedDoesNotLoseStartedResource() throws {
        let entered = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let sealed = DispatchSemaphore(value: 0)
        let rig = NativeDraftRig(cursor: nil, testHooks: .init(didSealForStop: { sealed.signal() }))
        rig.api.onStart = { entered.signal(); _ = proceed.wait(timeout: .now() + 5) }
        let start = NativeDraftJob { try rig.start() }
        defer { proceed.signal(); try? rig.stream.stop() }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        let stop = NativeDraftJob { try rig.stream.stop() }
        XCTAssertEqual(sealed.wait(timeout: .now() + 5), .success)
        proceed.signal()
        _ = try start.result()
        try stop.success()
        assertCleanup(rig.api, stop: 1, invalidate: 1, release: 1, close: 1)
        XCTAssertEqual(rig.inbox.historyCount, 0)
    }

    // 48: Drain waits for entered callback without holding an admission lock.
    func testExternalStopWaitsForEnteredCallbackBeforeRelease() throws {
        let rig = NativeDraftRig()
        let entered = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let stopped = DispatchSemaphore(value: 0)
        rig.inbox.onSignal = { _ in entered.signal(); _ = proceed.wait(timeout: .now() + 5) }
        rig.api.onStop = { stopped.signal() }
        try rig.start()
        defer { proceed.signal(); try? rig.stream.stop() }
        let callback = NativeDraftJob { rig.api.emit([NativeDraft.event("entered.jsonl", 11)]) }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        let stop = NativeDraftJob { try rig.stream.stop() }
        XCTAssertEqual(stopped.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(rig.api.count("release"), 0)
        proceed.signal()
        try callback.success()
        try stop.success()
        assertCleanup(rig.api, stop: 1, invalidate: 1, release: 1, close: 1)
    }

    // 49: Prohibited reentrancy fails fast; a later external stop really cleans.
    func testReentrantStopFailsFastWithoutFalseDrainAndPreservesExternalCleanup() throws {
        let rig = NativeDraftRig()
        let failure = NativeDraftBox<CollectorNativeEventStreamError?>(nil)
        rig.inbox.onSignal = { _ in
            do { try rig.stream.stop(); XCTFail("Reentrant stop must not claim successful drain") }
            catch { failure.value = error as? CollectorNativeEventStreamError }
            XCTAssertEqual(rig.api.count("drain"), 0)
            XCTAssertEqual(rig.api.count("release"), 0)
        }
        try rig.start()
        rig.api.emit([NativeDraft.event("reentrant.jsonl", 11)])
        XCTAssertEqual(failure.value, .reentrantStopUnsupported)
        // A same-queue barrier observes any incorrectly queued hidden cleanup.
        rig.api.callbackBarrier()
        XCTAssertEqual(rig.api.count("release"), 0)
        try rig.stream.stop()
        assertCleanup(rig.api, stop: 1, invalidate: 1, release: 1, close: 1)
        XCTAssertNoThrow(try rig.stream.stop())
    }

    // 50: Real Owner durability changes only at coordinator.step, not callback.
    func testCoordinatorAppliesNativeBatchOnlyDuringStepAndPersistsCheckpoint() throws {
        let fixture = try NativeDraftOwnerFixture()
        defer { fixture.remove() }
        let commits = NativeDraftBox(0)
        let owner = try fixture.open(hooks: .init(beforeInventoryCommit: { commits.value += 1 }))
        defer { try? owner.close() }
        try fixture.seed(owner, cursor: "10")
        let api = NativeDraftAPI()
        let coordinator = fixture.coordinator(owner, api)
        defer { try? coordinator.stop() }
        try coordinator.start(epoch: NativeDraft.epoch)
        api.emit([NativeDraft.historyEvent])
        try fixture.finishRecovery(coordinator)
        let before = try fixture.state(owner)
        let commitCount = commits.value
        api.emit([NativeDraft.event("new.jsonl", 11)])
        XCTAssertEqual(commits.value, commitCount)
        XCTAssertEqual(try fixture.state(owner).eventCheckpoint, before.eventCheckpoint)
        _ = try coordinator.step(budget: NativeDraft.scanBudget)
        XCTAssertEqual(try fixture.state(owner).eventCheckpoint, .init(epoch: NativeDraft.epoch, cursor: "11"))
        XCTAssertEqual(commits.value, commitCount + 1)
    }

    // 51: Structural loss preserves old durable checkpoint and latches one gap.
    func testCoordinatorDirectoryMoveInKeepsCheckpointRequestsOneReconciliationAndNeverWatches() throws {
        let fixture = try NativeDraftOwnerFixture()
        defer { fixture.remove() }
        let owner = try fixture.open()
        defer { try? owner.close() }
        try fixture.seed(owner, cursor: "10")
        let api = NativeDraftAPI()
        let coordinator = fixture.coordinator(owner, api)
        defer { try? coordinator.stop() }
        try coordinator.start(epoch: NativeDraft.epoch)
        let before = try fixture.state(owner)
        let directory = NativeDraft.event("populated", 11,
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemRenamed))
        api.emit([directory, NativeDraft.historyEvent])
        api.emit([directory])
        XCTAssertEqual(try fixture.state(owner), before)
        for _ in 0..<4 { _ = try coordinator.step(budget: NativeDraft.scanBudget) }
        let after = try fixture.state(owner)
        XCTAssertEqual(after.eventCheckpoint, before.eventCheckpoint)
        XCTAssertEqual(after.requestedRevision, before.requestedRevision + 1)
        XCTAssertEqual(try coordinator.snapshot().phase, .recoveryRequired)
        XCTAssertFalse(try coordinator.snapshot().historyDone)
    }

    // 52: Synthetic baseline completion does not fabricate Owner persistence.
    func testCoordinatorNilCheckpointScansBeforeWatchingAndRemainsNilUntilRealEvent() throws {
        let fixture = try NativeDraftOwnerFixture()
        defer { fixture.remove() }
        let owner = try fixture.open()
        defer { try? owner.close() }
        let api = NativeDraftAPI()
        let coordinator = fixture.coordinator(owner, api)
        defer { try? coordinator.stop() }
        try coordinator.start(epoch: NativeDraft.epoch)
        XCTAssertEqual(try coordinator.snapshot().phase, .recovering)
        XCTAssertNil(try fixture.state(owner).eventCheckpoint)
        try fixture.finishRecovery(coordinator)
        let scanned = try fixture.state(owner)
        XCTAssertEqual(scanned.completedRevision, scanned.requestedRevision)
        XCTAssertNil(scanned.eventCheckpoint)
        api.emit([NativeDraft.event("first.jsonl", 11)])
        XCTAssertNil(try fixture.state(owner).eventCheckpoint)
        _ = try coordinator.step(budget: NativeDraft.scanBudget)
        XCTAssertEqual(try fixture.state(owner).eventCheckpoint?.cursor, "11")
    }

    // 53: A completed inventory scan alone cannot replace native HistoryDone.
    func testCoordinatorPersistedCheckpointWaitsForNativeHistoryEvenAfterScan() throws {
        let fixture = try NativeDraftOwnerFixture()
        defer { fixture.remove() }
        let owner = try fixture.open()
        defer { try? owner.close() }
        try fixture.seed(owner, cursor: "10")
        let api = NativeDraftAPI()
        let coordinator = fixture.coordinator(owner, api)
        defer { try? coordinator.stop() }
        try coordinator.start(epoch: NativeDraft.epoch)
        for _ in 0..<8 { _ = try coordinator.step(budget: NativeDraft.scanBudget) }
        let scanned = try fixture.state(owner)
        XCTAssertEqual(scanned.completedRevision, scanned.requestedRevision)
        XCTAssertEqual(try coordinator.snapshot().phase, .recovering)
        XCTAssertFalse(try coordinator.snapshot().historyDone)
        api.emit([NativeDraft.historyEvent])
        try fixture.finishRecovery(coordinator)
        XCTAssertEqual(try fixture.state(owner).eventCheckpoint?.cursor, "10")
    }

    // 54: Old replay paths reach the real inventory even without ID advancement.
    func testCoordinatorFullHistoryLowerIDCommitsDirtyLocatorWithoutCheckpointRegression() throws {
        let fixture = try NativeDraftOwnerFixture()
        defer { fixture.remove() }
        let owner = try fixture.open()
        defer { try? owner.close() }
        try fixture.seed(owner, cursor: "10")
        let api = NativeDraftAPI()
        let coordinator = fixture.coordinator(owner, api)
        defer { try? coordinator.stop() }
        try coordinator.start(epoch: NativeDraft.epoch)
        api.emit([NativeDraft.event("old-replay.jsonl", 3), NativeDraft.historyEvent])
        try fixture.finishRecovery(coordinator)
        XCTAssertEqual(try coordinator.step(budget: NativeDraft.scanBudget).appliedBatches, 1)
        XCTAssertEqual(try fixture.state(owner).eventCheckpoint?.cursor, "10")
        try coordinator.stop()
        try owner.close()
        XCTAssertEqual(try fixture.locatorCount("old-replay.jsonl"), 1)
    }

    // 55: Loss during SinceNow Start suppresses the synthetic history barrier.
    func testNilCheckpointLossDuringStartDoesNotSynthesizeHistoryOrCheckpoint() throws {
        let rig = NativeDraftRig(cursor: nil)
        rig.api.onStart = {
            rig.api.emit([.init(bytes: [], flags: FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped), id: 0)])
        }
        defer { try? rig.stream.stop() }
        try rig.start()
        XCTAssertEqual(rig.inbox.kinds, ["loss"])
        XCTAssertEqual(rig.inbox.losses, [.overflow])
        XCTAssertEqual(rig.inbox.historyCount, 0)
        XCTAssertTrue(rig.inbox.batches.isEmpty)
    }

    // 56: Cancellation is checked before acquisition and after native boundaries.
    func testCancelledStartCleansExactlyTheResourcesAlreadyAcquired() async throws {
        for stage in ["before", "create", "start"] {
            let rig = NativeDraftRig(cursor: nil)
            let task = Task {
                try withUnsafeCurrentTask { current in
                    XCTAssertNotNil(current)
                    if stage == "before" { current?.cancel() }
                    if stage == "create" { rig.api.onCreate = { current?.cancel() } }
                    if stage == "start" { rig.api.onStart = { current?.cancel() } }
                    defer { rig.api.onCreate = nil; rig.api.onStart = nil }
                    XCTAssertThrowsError(try rig.start()) { XCTAssertTrue($0 is CancellationError) }
                    XCTAssertTrue(Task.isCancelled)
                }
            }
            try await task.value
            assertCleanup(rig.api, stop: stage == "start" ? 1 : 0,
                          invalidate: stage == "start" ? 1 : 0,
                          release: stage == "before" ? 0 : 1, close: stage == "before" ? 0 : 1)
            XCTAssertEqual(rig.inbox.historyCount, 0)
            XCTAssertNoThrow(try rig.stream.stop())
        }
    }

    // 57: Cancellation cannot interrupt the external resource-release obligation.
    func testAlreadyCancelledExternalStopStillDrainsAndReleases() async throws {
        let rig = NativeDraftRig()
        try rig.start()
        let task = Task {
            try withUnsafeCurrentTask { current in
                current?.cancel()
                XCTAssertNoThrow(try rig.stream.stop())
            }
        }
        try await task.value
        assertCleanup(rig.api, stop: 1, invalidate: 1, release: 1, close: 1)
        XCTAssertNoThrow(try rig.stream.stop())
    }

    // 58: Negative raw count fails before range construction or pointer reads.
    func testNegativeRawCountWithNilPointersLatchesContinuityLossAndSealsCallbacks() throws {
        let rig = NativeDraftRig()
        defer { try? rig.stream.stop() }
        try rig.start()
        let lifecycleBefore = rig.api.calls
        rig.api.emitRaw(count: -1, paths: nil, flags: nil, ids: nil)
        XCTAssertEqual(rig.inbox.losses, [.continuityLoss])
        XCTAssertEqual(rig.inbox.kinds, ["loss"])
        XCTAssertTrue(rig.inbox.batches.isEmpty)

        rig.api.emitRaw(count: -1, paths: nil, flags: nil, ids: nil)
        rig.api.emit([NativeDraft.event("ignored.jsonl", 11), NativeDraft.historyEvent])
        XCTAssertEqual(rig.inbox.losses, [.continuityLoss])
        XCTAssertEqual(rig.inbox.kinds, ["loss"])
        XCTAssertTrue(rig.inbox.batches.isEmpty)
        XCTAssertEqual(rig.inbox.historyCount, 0)
        XCTAssertEqual(rig.api.calls, lifecycleBefore)
    }

    private func assertCleanup(_ api: NativeDraftAPI, stop: Int, invalidate: Int, release: Int, close: Int,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(api.count("stop"), stop, file: file, line: line)
        XCTAssertEqual(api.count("invalidate"), invalidate, file: file, line: line)
        XCTAssertEqual(api.count("release"), release, file: file, line: line)
        XCTAssertEqual(api.count("close"), close, file: file, line: line)
        if release > 0, let released = api.calls.firstIndex(of: "release"), let closed = api.calls.firstIndex(of: "close") {
            XCTAssertLessThan(released, closed, file: file, line: line)
        }
    }
}

private enum NativeDraft {
    static let uuid = "A1111111-B222-C333-D444-E55555555555"
    static let otherUUID = "F1111111-B222-C333-D444-E55555555555"
    static let epoch = "fsevents-device-v1:" + uuid
    static let mount = "/System/Volumes/Data"
    static let relativeRoot = "Users/fixture/sessions"
    static let identity = CollectorPOSIXDirectoryIdentity(device: 7, inode: 11, generation: 0, birthSeconds: 1, birthNanoseconds: 2)
    static let otherIdentity = CollectorPOSIXDirectoryIdentity(device: 7, inode: 12, generation: 0, birthSeconds: 1, birthNanoseconds: 2)
    static let binding = CollectorPOSIXRootBinding(
        configuration: .init(rootID: "synthetic-root", source: .codex, rootPath: "/Users/fixture/sessions", revision: 1),
        expectedIdentity: identity)
    static let file = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemModified)
    static let history = FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone)
    static let historyEvent = NativeDraftEvent(bytes: [], flags: history, id: 0)
    static let scanBudget = CollectorBootstrapBudget(maxEntriesVisited: 16, maxCandidateFiles: 8,
                                                     maxDirectoryOpens: 2, maxMetadataBytes: 8192)

    static func budget(paths: Int = 16, perPath: Int = 256, total: Int = 4096, checkpoints: Int = 512) -> CollectorEventIngressBudget {
        .init(maxIncomingPaths: paths, maxPathUTF8Bytes: perPath, maxTotalPathUTF8Bytes: total, maxCheckpointUTF8Bytes: checkpoints)
    }

    static func observation(descriptor: CollectorPOSIXDirectoryIdentity = identity,
                            route: CollectorPOSIXDirectoryIdentity = identity,
                            physical: String = mount + "/" + relativeRoot, device: Int64 = 7,
                            uuid: String? = NativeDraft.uuid) -> CollectorNativeRootObservation {
        .init(descriptorIdentity: descriptor, routeIdentity: route, physicalRootPath: physical,
              volumeMountPath: mount, volumeDevice: device, eventDatabaseUUID: uuid)
    }

    static func event(_ path: String, _ id: UInt64, flags: FSEventStreamEventFlags = file) -> NativeDraftEvent {
        .init(bytes: Array((relativeRoot + "/" + path).utf8), flags: flags, id: id)
    }
}

private struct NativeDraftEvent {
    let bytes: [UInt8]
    let flags: FSEventStreamEventFlags
    let id: FSEventStreamEventId
}

private enum NativeDraftFailure: Error, Equatable {
    case injected(String)
    case timeout
}

private final class NativeDraftRig {
    let request: CollectorEventStreamRequest
    let api = NativeDraftAPI()
    let inbox = NativeDraftInbox()
    let stream: CollectorNativeEventStream

    init(cursor: String? = "10", requestEpoch: String = NativeDraft.epoch, checkpointEpoch: String? = nil,
         budget: CollectorEventIngressBudget = NativeDraft.budget(), testHooks: CollectorNativeEventStreamTestHooks = .init()) {
        request = .init(binding: NativeDraft.binding, generation: 1, epoch: requestEpoch,
                        resumeCheckpoint: cursor.map { .init(epoch: checkpointEpoch ?? requestEpoch, cursor: $0) })
        stream = CollectorNativeEventStream(request: request, budget: budget, api: api, testHooks: testHooks)
    }

    func start() throws { try stream.start(deliver: inbox.admit) }
}

private final class NativeDraftInbox {
    private let lock = NSLock()
    private var stored: [CollectorEventStreamSignal] = []
    var onSignal: ((CollectorEventStreamSignal) -> Void)?
    var admission: CollectorEventAdmission?
    var signals: [CollectorEventStreamSignal] { lock.withLock { stored } }
    var batches: [CollectorEventBatch] { signals.compactMap { if case let .batch(batch) = $0 { return batch }; return nil } }
    var losses: [CollectorEventGapReason] { signals.compactMap { if case let .loss(reason) = $0 { return reason }; return nil } }
    var historyCount: Int { kinds.filter { $0 == "history" }.count }
    var kinds: [String] {
        signals.map { switch $0 { case .batch: "batch"; case .historyDone: "history"; case .loss: "loss"; case .terminated: "terminated" } }
    }

    func admit(_ signal: CollectorEventStreamSignal) -> CollectorEventAdmission {
        lock.withLock { stored.append(signal) }
        onSignal?(signal)
        if let admission { return admission }
        if case .batch = signal { return .queued }
        return .controlAccepted
    }
}

private final class NativeDraftHandle: CollectorNativeEventHandle {}

private final class NativeDraftAPI: CollectorNativeEventAPI {
    private let lock = NSLock()
    private var journal: [String] = []
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var queue: DispatchQueue?
    private var callback: CollectorNativeRawEventCallback?
    var observations = [NativeDraft.observation()]
    var created: CollectorNativeEventCreateRequest?
    var failure: String?
    var createReturnsNil = false
    var startResult = true
    var onCreate: (() -> Void)?
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var calls: [String] { lock.withLock { journal } }
    var isOnCallbackQueue: Bool { DispatchQueue.getSpecific(key: queueKey) == 1 }

    func count(_ operation: String) -> Int { calls.filter { $0 == operation }.count }
    private func record(_ operation: String) { lock.withLock { journal.append(operation) } }
    private func fail(_ operation: String) throws {
        if failure == operation { throw NativeDraftFailure.injected(operation) }
    }

    func openRoot(_ binding: CollectorPOSIXRootBinding) throws -> Int32 {
        record("open")
        try fail("open")
        return 101 // A fake token only; never an OS descriptor or a real open.
    }

    func observeRoot(_ descriptor: Int32, binding: CollectorPOSIXRootBinding) throws -> CollectorNativeRootObservation {
        record("observe")
        try fail("observe")
        return observations[min(count("observe") - 1, observations.count - 1)]
    }

    func closeRoot(_ descriptor: Int32) { record("close") }

    func create(_ request: CollectorNativeEventCreateRequest,
                callback: @escaping CollectorNativeRawEventCallback) throws -> (any CollectorNativeEventHandle)? {
        record("create")
        try fail("create")
        onCreate?()
        created = request
        self.callback = callback
        return createReturnsNil ? nil : NativeDraftHandle()
    }

    func schedule(_ stream: any CollectorNativeEventHandle, on queue: DispatchQueue) throws {
        record("schedule")
        try fail("schedule") // Failure means not scheduled; no hidden ownership transition.
        self.queue = queue
        queue.setSpecific(key: queueKey, value: 1)
    }

    func start(_ stream: any CollectorNativeEventHandle) -> Bool {
        record("start")
        onStart?()
        return startResult
    }

    func stop(_ stream: any CollectorNativeEventHandle) throws {
        record("stop")
        onStop?()
        try fail("stop")
    }

    func invalidate(_ stream: any CollectorNativeEventHandle) throws {
        record("invalidate")
        try fail("invalidate")
    }

    func drain(_ queue: DispatchQueue) throws {
        record("drain")
        queue.sync {} // The fixture models the same serial-queue drain boundary.
        try fail("drain")
    }

    func release(_ stream: any CollectorNativeEventHandle) { record("release") }

    func callbackBarrier() { onCallbackQueue {} }

    private func onCallbackQueue(_ body: () -> Void) {
        guard let queue else { XCTFail("Native callback queue has not been scheduled"); return }
        if isOnCallbackQueue { body() } else { queue.sync(execute: body) }
    }

    func emitRaw(count: Int, paths: UnsafeRawPointer?, flags: UnsafePointer<FSEventStreamEventFlags>?,
                 ids: UnsafePointer<FSEventStreamEventId>?) {
        onCallbackQueue { callback?(count, paths, flags, ids) }
    }

    func emit(_ events: [NativeDraftEvent], missingArray: Int? = nil, nilPathIndex: Int? = nil) {
        onCallbackQueue {
            let allocated = events.map { event -> UnsafeMutablePointer<CChar> in
                let path = UnsafeMutablePointer<CChar>.allocate(capacity: event.bytes.count + 1)
                path.initialize(repeating: 0, count: event.bytes.count + 1)
                for (index, byte) in event.bytes.enumerated() { path[index] = CChar(bitPattern: byte) }
                return path
            }
            defer {
                for (index, path) in allocated.enumerated() {
                    // Poison and release AFTER the actual captured callback returns.
                    memset(path, 0x58, events[index].bytes.count + 1)
                    path.deinitialize(count: events[index].bytes.count + 1)
                    path.deallocate()
                }
            }
            let paths: [UnsafeMutablePointer<CChar>?] = allocated.enumerated().map { index, path in
                index == nilPathIndex ? nil : path
            }
            let flags = events.map(\.flags)
            let ids = events.map(\.id)
            paths.withUnsafeBufferPointer { pathBuffer in
                flags.withUnsafeBufferPointer { flagBuffer in
                    ids.withUnsafeBufferPointer { idBuffer in
                        callback?(events.count,
                                  missingArray == 0 ? nil : pathBuffer.baseAddress.map(UnsafeRawPointer.init),
                                  missingArray == 1 ? nil : flagBuffer.baseAddress,
                                  missingArray == 2 ? nil : idBuffer.baseAddress)
                    }
                }
            }
        }
    }
}

private final class NativeDraftBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class NativeDraftJob: @unchecked Sendable {
    private let finished = DispatchSemaphore(value: 0)
    private let outcome = NativeDraftBox<Result<Void, Error>?>(nil)

    init(_ body: @escaping () throws -> Void) {
        // One explicitly requested fixture operation, never callback-spawned work.
        let worker = Thread {
            self.outcome.value = Result { try body() }
            self.finished.signal()
        }
        worker.qualityOfService = Thread.current.qualityOfService
        worker.start()
    }

    func result() throws -> Result<Void, Error> {
        guard finished.wait(timeout: .now() + 5) == .success else { throw NativeDraftFailure.timeout }
        return try XCTUnwrap(outcome.value)
    }

    func success() throws { try result().get() }
}

private final class NativeDraftOwnerFixture {
    private static let machineID = "11111111-2222-3333-4444-555555555555"
    let base: URL
    let live: URL
    let shadow: URL
    let source: URL
    var configuration: CollectorRootConfiguration {
        .init(rootID: "synthetic-root", source: .codex, rootPath: source.path, revision: 1)
    }

    init() throws {
        let donor = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard donor.path.hasPrefix("/Users/") else { throw POSIXError(.EINVAL) }
        base = donor.appendingPathComponent(".engram-n3b2-native-\(UUID().uuidString)", isDirectory: true)
        live = base.appendingPathComponent("live")
        shadow = base.appendingPathComponent("task/shadow")
        source = base.appendingPathComponent("sources/sessions")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            for url in [live, base.appendingPathComponent("task"), shadow, base.appendingPathComponent("sources"), source] {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            try catalog(live.appendingPathComponent("archive.sqlite"))
            try catalog(shadow.appendingPathComponent("archive.sqlite"))
        } catch {
            try? FileManager.default.removeItem(at: base)
            throw error
        }
    }

    func remove() { try? FileManager.default.removeItem(at: base) }

    private func catalog(_ url: URL) throws {
        let queue = try DatabaseQueue(path: url.path)
        defer { try? queue.close() }
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE archive_metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            try db.execute(sql: "INSERT INTO archive_metadata VALUES ('machine_id', ?)", arguments: [Self.machineID])
        }
        try queue.close()
        guard chmod(url.path, 0o600) == 0 else { throw POSIXError(.EACCES) }
    }

    func open(hooks: CollectorInventoryOwnerTestHooks = .init()) throws -> CollectorInventoryOwner {
        try XCTUnwrap(CollectorInventoryOwner.open(enabled: true, shadowRoot: shadow,
            identityCatalog: live.appendingPathComponent("archive.sqlite"), ownerRunID: "native-fixture", testHooks: hooks))
    }

    func seed(_ owner: CollectorInventoryOwner, cursor: String) throws {
        _ = try owner.enrollAndActivateRoot(configuration)
        _ = try owner.applyEvents(configuration: configuration, expectedCheckpoint: nil,
            nextCheckpoint: .init(epoch: NativeDraft.epoch, cursor: cursor), dirtyRelativePaths: [], budget: NativeDraft.budget())
    }

    func state(_ owner: CollectorInventoryOwner) throws -> CollectorRootState {
        try XCTUnwrap(owner.rootState(rootID: configuration.rootID))
    }

    func coordinator(_ owner: CollectorInventoryOwner, _ api: NativeDraftAPI) -> CollectorEventCoordinator {
        CollectorEventCoordinator(enabled: true, configuration: configuration,
            budget: .init(ingress: NativeDraft.budget(), maxQueuedBatches: 16, maxQueuedUTF8Bytes: 8192),
            ownerFactory: { owner }, streamFactory: { request in
                // Native FS facts are injected for the actual temporary Owner
                // binding. Raw event paths still use the fake volume mapping.
                api.observations = [NativeDraft.observation(descriptor: request.binding.expectedIdentity,
                    route: request.binding.expectedIdentity, device: request.binding.expectedIdentity.device)]
                return CollectorNativeEventStream(request: request, budget: NativeDraft.budget(), api: api)
            })
    }

    func finishRecovery(_ coordinator: CollectorEventCoordinator) throws {
        for _ in 0..<32 {
            _ = try coordinator.step(budget: NativeDraft.scanBudget)
            if try coordinator.snapshot().phase == .watching { return }
        }
        XCTFail("Native history and the exact inventory scan fence did not complete")
        throw NativeDraftFailure.timeout
    }

    func locatorCount(_ path: String) throws -> Int {
        var config = Configuration()
        config.readonly = true
        let queue = try DatabaseQueue(path: shadow.appendingPathComponent("inventory/inventory.sqlite").path, configuration: config)
        defer { try? queue.close() }
        return try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM collector_locators WHERE root_id = ? AND relative_path = ?",
                             arguments: [configuration.rootID, path]) ?? 0
        }
    }
}
