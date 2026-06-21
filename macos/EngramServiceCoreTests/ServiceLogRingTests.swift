import XCTest
@testable import EngramServiceCore

final class ServiceLogRingTests: XCTestCase {
    func testBoundedCapacityRetainsNewestNewestFirst() async {
        let ring = ServiceLogRing(capacity: 10)
        for i in 0..<25 {
            await ring.record(level: "info", category: "runner", message: "line \(i)")
        }
        let snapshot = await ring.snapshot()
        // Only the last 10 are retained.
        XCTAssertEqual(snapshot.lines.count, 10)
        // Newest-first: line 24 first, oldest retained is line 15.
        XCTAssertEqual(snapshot.lines.first?.message, "line 24")
        XCTAssertEqual(snapshot.lines.last?.message, "line 15")
    }

    func testLevelFilter() async {
        let ring = ServiceLogRing(capacity: 100)
        await ring.record(level: "info", category: "runner", message: "a")
        await ring.record(level: "error", category: "runner", message: "b")
        await ring.record(level: "info", category: "ipc", message: "c")
        let snapshot = await ring.snapshot(level: "error")
        XCTAssertEqual(snapshot.lines.count, 1)
        XCTAssertEqual(snapshot.lines.first?.message, "b")
    }

    func testCategoryFilter() async {
        let ring = ServiceLogRing(capacity: 100)
        await ring.record(level: "info", category: "runner", message: "a")
        await ring.record(level: "info", category: "ipc", message: "b")
        await ring.record(level: "info", category: "ipc", message: "c")
        let snapshot = await ring.snapshot(category: "ipc")
        XCTAssertEqual(snapshot.lines.count, 2)
        XCTAssertTrue(snapshot.lines.allSatisfy { $0.category == "ipc" })
    }

    func testLimitHonored() async {
        let ring = ServiceLogRing(capacity: 100)
        for i in 0..<20 {
            await ring.record(level: "info", category: "runner", message: "line \(i)")
        }
        let snapshot = await ring.snapshot(limit: 5)
        XCTAssertEqual(snapshot.lines.count, 5)
        // Newest-first, so the limit takes the 5 most recent.
        XCTAssertEqual(snapshot.lines.first?.message, "line 19")
    }

    func testStoresSanitizedMessage() async {
        let ring = ServiceLogRing(capacity: 10)
        await ring.record(
            level: "info",
            category: "runner",
            message: "indexing /Users/bing/.engram/index.sqlite now"
        )
        let snapshot = await ring.snapshot()
        let stored = snapshot.lines.first?.message ?? ""
        XCTAssertFalse(stored.contains("/Users/bing/.engram/index.sqlite"))
        XCTAssertTrue(stored.contains("<path>"))
        XCTAssertTrue(stored.contains("indexing"))
    }

    func testConcurrentRecordsDoNotExceedCapacity() async {
        let ring = ServiceLogRing(capacity: 50)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<500 {
                group.addTask {
                    await ring.record(level: "info", category: "runner", message: "msg \(i)")
                }
            }
        }
        let snapshot = await ring.snapshot()
        // No crash under concurrent writes; count is bounded by capacity.
        XCTAssertLessThanOrEqual(snapshot.lines.count, 50)
        XCTAssertEqual(snapshot.lines.count, 50)
    }
}
