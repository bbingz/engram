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
}
