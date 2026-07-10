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
        ns.invalidate()
        let sleep = SleepIndexingBackgroundActivityScheduler()
        sleep.invalidate()
    }

    func testMinIntervalIsNotFixedFiveMinutes() {
        XCTAssertGreaterThanOrEqual(IndexingSchedulePolicy.minInterval, 15 * 60)
        XCTAssertNotEqual(IndexingSchedulePolicy.minInterval, 5 * 60)
        XCTAssertEqual(IndexingSchedulePolicy().nextInterval(), 15 * 60)
    }
}
