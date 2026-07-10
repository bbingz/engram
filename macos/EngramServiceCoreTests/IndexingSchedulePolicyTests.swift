import XCTest
@testable import EngramServiceCore

final class IndexingSchedulePolicyTests: XCTestCase {
    func testBackoff15_30_60AndCap() {
        var policy = IndexingSchedulePolicy()
        XCTAssertEqual(policy.nextInterval(), 15 * 60)

        policy.recordScan(.init(indexed: 0))
        XCTAssertEqual(policy.nextInterval(), 15 * 60)

        policy.recordScan(.init(indexed: 0))
        XCTAssertEqual(policy.nextInterval(), 30 * 60)

        policy.recordScan(.init(indexed: 0))
        XCTAssertEqual(policy.nextInterval(), 60 * 60)

        policy.recordScan(.init(indexed: 0))
        XCTAssertEqual(policy.nextInterval(), 60 * 60, "cap at 60m")
    }

    func testIndexedWorkResetsTo15m() {
        var policy = IndexingSchedulePolicy()
        policy.recordScan(.init(indexed: 0))
        policy.recordScan(.init(indexed: 0))
        XCTAssertEqual(policy.nextInterval(), 30 * 60)

        policy.recordScan(.init(indexed: 3))
        XCTAssertEqual(policy.nextInterval(), 15 * 60)
        XCTAssertEqual(policy.consecutiveIdleScans, 0)
    }

    func testManualRefreshBypassesBackoff() {
        var policy = IndexingSchedulePolicy()
        policy.recordScan(.init(indexed: 0))
        policy.recordScan(.init(indexed: 0))
        policy.recordScan(.init(indexed: 0))
        XCTAssertEqual(policy.nextInterval(), 60 * 60)
        XCTAssertEqual(policy.nextInterval(manualRefresh: true), 15 * 60)
    }

    func testDeferUnderLowPowerOrSeriousThermal() {
        XCTAssertTrue(IndexingSchedulePolicy.shouldDefer(conditions: .init(lowPower: true)))
        XCTAssertTrue(IndexingSchedulePolicy.shouldDefer(conditions: .init(thermal: .serious)))
        XCTAssertTrue(IndexingSchedulePolicy.shouldDefer(conditions: .init(thermal: .critical)))
        XCTAssertFalse(IndexingSchedulePolicy.shouldDefer(conditions: .init(lowPower: false, thermal: .nominal)))
        XCTAssertFalse(IndexingSchedulePolicy.shouldDefer(conditions: .init(thermal: .fair)))
    }

    func testNSSchedulerBackendIdentifierAndSleepFallbackExist() throws {
        // Production path uses NSBackgroundActivityScheduler; sleep fallback is for tests/hosts.
        let ns = NSIndexingBackgroundActivityScheduler()
        XCTAssertEqual(NSIndexingBackgroundActivityScheduler.identifier, "com.engram.service.periodic-index")
        XCTAssertEqual(ns.backendName, "NSBackgroundActivityScheduler")
        ns.invalidate()
        let sleep = SleepIndexingBackgroundActivityScheduler()
        XCTAssertEqual(sleep.backendName, "Task.sleep")
        sleep.invalidate()
    }

    func testMinIntervalIsNotFixedFiveMinutes() {
        XCTAssertGreaterThanOrEqual(IndexingSchedulePolicy.minInterval, 15 * 60)
        XCTAssertNotEqual(IndexingSchedulePolicy.minInterval, 5 * 60)
        XCTAssertEqual(IndexingSchedulePolicy().nextInterval(), 15 * 60)
    }

    /// S01: activity completion must only fire after work returns (not before).
    func testRecordingSchedulerFinishesOnlyAfterWork_repro() async {
        let recorder = RecordingIndexingBackgroundActivityScheduler()
        var workStarted = false
        var workFinished = false
        let outcome = await recorder.performWhenDue(interval: 0.001, tolerance: 0) {
            workStarted = true
            try? await Task.sleep(nanoseconds: 5_000_000)
            workFinished = true
        }
        XCTAssertEqual(outcome, .run)
        XCTAssertTrue(workStarted)
        XCTAssertTrue(workFinished)
        XCTAssertEqual(recorder.workInvocations, 1)
        XCTAssertTrue(
            recorder.lastRunFinishedAfterWork,
            "OS-style finished must be ordered after work completes"
        )
        XCTAssertEqual(recorder.finishedAfterWorkCount, 1)
    }

    func testRecordingSchedulerDeferredSkipsWork() async {
        let recorder = RecordingIndexingBackgroundActivityScheduler()
        recorder.forceDeferred = true
        var ran = false
        let outcome = await recorder.performWhenDue(interval: 0.001, tolerance: 0) {
            ran = true
        }
        XCTAssertEqual(outcome, .deferred)
        XCTAssertFalse(ran)
        XCTAssertEqual(recorder.workInvocations, 0)
    }
}
