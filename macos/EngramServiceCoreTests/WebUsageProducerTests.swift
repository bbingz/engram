import Foundation
import GRDB
import XCTest
@testable import EngramServiceCore

final class WebUsageProducerTests: XCTestCase {
    func testLatestPerMetricKeepsIndependentObservationsAndDeduplicatesTimestampTies() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate(); try fixture.seedRegistry()
        try fixture.write { db in
            for (metric, value, time) in [("5h token total", 500, "2026-09-01T00:00:00Z"),
                                           ("5h token total", 800, "2026-09-02T00:00:00Z"),
                                           ("weekly usage", 40, "2026-09-01T00:00:00Z"),
                                           ("weekly usage", 45, "2026-09-01T00:00:00Z")] {
                try db.execute(sql: "INSERT INTO usage_snapshots(source,metric,value,collected_at) VALUES('claude-code',?,?,?)",
                               arguments: [metric, value, time])
            }
            try db.execute(sql: "INSERT INTO usage_snapshots(source,metric,value,collected_at) VALUES('codex','weekly usage',99,'2026-09-03T00:00:00Z')")
        }
        let producer = try fixture.producer(policy: { .init(parserRevision: "parser-v1", enabledSources: [.claudeCode]) })
        defer { try? producer.stop() }
        let response = try await producer.usage(.init(), requestId: "AAAAAAAA-0000-4000-8000-000000000199", deadline: fixture.deadline())
        XCTAssertEqual(response.scope, "server")
        XCTAssertEqual(response.items.map(\.source), ["claude-code", "claude-code"])
        XCTAssertEqual(response.items.map(\.value), [800, 45])
        XCTAssertEqual(response.items.map(\.basis), [.indexedSessions, .reported])
        XCTAssertEqual(response.items.last?.collectedAt, "2026-09-01T00:00:00Z")
    }

    func testMissingUsageStorageIsUnavailableRatherThanInventedEmptyUsage() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate(); try fixture.seedRegistry()
        try fixture.write { db in try db.execute(sql: "DROP TABLE usage_snapshots") }
        let producer = try fixture.producer(policy: { .init(parserRevision: "parser-v1", enabledSources: [.claudeCode]) })
        defer { try? producer.stop() }
        do {
            _ = try await producer.usage(.init(), requestId: "AAAAAAAA-0000-4000-8000-000000000199", deadline: fixture.deadline())
            XCTFail("Missing storage must be explicit")
        } catch { XCTAssertEqual(error as? ServiceWebMetadataError, .unavailable) }
    }
}
