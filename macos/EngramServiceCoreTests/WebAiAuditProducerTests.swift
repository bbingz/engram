import Foundation
import GRDB
import XCTest
@testable import EngramServiceCore

final class WebAiAuditProducerTests: XCTestCase {
    private let requestID = "AAAAAAAA-0000-4000-8000-000000000191"

    func testIntegerPrimaryKeyIsPublishedAsDecimalString() async throws {
        let fixture = try seeded()
        defer { fixture.remove() }
        try insert(fixture, ts: "2026-09-13T12:00:00.000", caller: "summary", model: "demo-chat")
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let page = try await producer.aiAudit(.init(), requestId: requestID, deadline: fixture.deadline())
        XCTAssertEqual(page.total, 1)
        XCTAssertEqual(page.items.first?.id, "1")
        XCTAssertEqual(Int64(try XCTUnwrap(page.items.first?.id)), 1)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(page)) as? [String: Any])
        let item = try XCTUnwrap((object["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(item["id"] as? String, "1")
        XCTAssertNil(item["requestBody"])
        XCTAssertNil(item["responseBody"])
        XCTAssertNil(item["meta"])
    }

    func testPagingRetainsTotalAndUsesDescendingTsThenId() async throws {
        let fixture = try seeded()
        defer { fixture.remove() }
        try insert(fixture, ts: "2026-09-13T10:00:00.000", model: "a")
        try insert(fixture, ts: "2026-09-13T11:00:00.000", model: "b")
        try insert(fixture, ts: "2026-09-13T11:00:00.000", model: "c")
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let first = try await producer.aiAudit(.init(limit: 1), requestId: requestID, deadline: fixture.deadline())
        XCTAssertEqual(first.total, 3)
        XCTAssertEqual(first.items.map(\.id), ["3"])
        XCTAssertEqual(first.items.first?.model, "c")
        XCTAssertNotNil(first.nextCursor)
        let second = try await producer.aiAudit(
            .init(limit: 1, snapshotId: first.snapshotId, cursor: try XCTUnwrap(first.nextCursor)),
            requestId: requestID, deadline: fixture.deadline())
        XCTAssertEqual(second.total, 3)
        XCTAssertEqual(second.items.map(\.id), ["2"])
        let third = try await producer.aiAudit(
            .init(limit: 1, snapshotId: second.snapshotId, cursor: try XCTUnwrap(second.nextCursor)),
            requestId: requestID, deadline: fixture.deadline())
        XCTAssertEqual(third.total, 3)
        XCTAssertEqual(third.items.map(\.id), ["1"])
        XCTAssertNil(third.nextCursor)
    }

    func testPageCapIsOneHundred() async throws {
        let fixture = try seeded()
        defer { fixture.remove() }
        for index in 0..<101 {
            try insert(fixture, ts: String(format: "2026-09-13T12:%02d:00.000", index % 60),
                       model: "m-\(index)")
        }
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let page = try await producer.aiAudit(.init(limit: 100), requestId: requestID, deadline: fixture.deadline())
        XCTAssertEqual(page.total, 101)
        XCTAssertEqual(page.items.count, 100)
        XCTAssertNotNil(page.nextCursor)
        XCTAssertThrowsError(try EngramServiceWebAiAuditRequest(limit: 101))
    }

    func testModelFilterAcceptsSlashAndColon() async throws {
        XCTAssertNoThrow(try EngramServiceWebAiAuditRequest(caller: "provider/model:variant",
                                                            model: "provider/model:variant"))
        let fixture = try seeded()
        defer { fixture.remove() }
        try insert(fixture, ts: "2026-09-13T12:00:00.000", model: "provider/model:variant")
        try insert(fixture, ts: "2026-09-13T11:00:00.000", model: "other")
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let page = try await producer.aiAudit(.init(model: "provider/model:variant"),
                                              requestId: requestID, deadline: fixture.deadline())
        XCTAssertEqual(page.total, 1)
        XCTAssertEqual(page.items.first?.model, "provider/model:variant")
    }

    func testHiddenSkipAgentAndUnboundSessionRowsAreOmittedAndNullSessionStays() async throws {
        let fixture = try visibilityFixture()
        defer { fixture.remove() }
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let page = try await producer.aiAudit(.init(), requestId: requestID, deadline: fixture.deadline())
        XCTAssertEqual(Set(page.items.compactMap(\.sessionId)), ["one"])
        XCTAssertEqual(page.items.filter { $0.sessionId == nil }.count, 1)
        XCTAssertEqual(page.total, 2)
        let hidden = try await producer.aiAudit(.init(sessionId: "hidden"),
                                                requestId: requestID, deadline: fixture.deadline())
        XCTAssertEqual(hidden.total, 0)
        XCTAssertEqual(hidden.items, [])
    }

    func testDetailMissingOrHiddenSessionIsNotFound() async throws {
        let fixture = try visibilityFixture()
        defer { fixture.remove() }
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        do {
            _ = try await producer.aiAuditDetail(.init(id: "999"), requestId: requestID, deadline: fixture.deadline())
            XCTFail("Missing detail must not look like an empty success")
        } catch { XCTAssertEqual(error as? ServiceWebMetadataError, .notFound) }
        let hiddenID = try rowID(fixture, session: "hidden")
        do {
            _ = try await producer.aiAuditDetail(.init(id: hiddenID), requestId: requestID, deadline: fixture.deadline())
            XCTFail("Hidden-session detail must not leak existence")
        } catch { XCTAssertEqual(error as? ServiceWebMetadataError, .notFound) }
    }

    func testDetailPublishesBodyFlagsOnly() async throws {
        let fixture = try seeded()
        defer { fixture.remove() }
        try insert(fixture, ts: "2026-09-13T12:00:00.000", session: "one",
                   requestBody: "secret request", responseBody: "secret response")
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let detail = try await producer.aiAuditDetail(.init(id: "1"), requestId: requestID, deadline: fixture.deadline())
        XCTAssertTrue(detail.hasRequestBody)
        XCTAssertTrue(detail.hasResponseBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(detail)) as? [String: Any])
        XCTAssertNil(object["requestBody"])
        XCTAssertNil(object["responseBody"])
        XCTAssertNil(object["meta"])
        XCTAssertEqual(object["hasRequestBody"] as? Bool, true)
        XCTAssertEqual(object["hasResponseBody"] as? Bool, true)
        let encoded = String(decoding: try JSONEncoder().encode(detail), as: UTF8.self)
        XCTAssertFalse(encoded.contains("secret request"))
        XCTAssertFalse(encoded.contains("secret response"))
    }

    func testEmptyTableIsEmptyNotUnavailable() async throws {
        let fixture = try seeded()
        defer { fixture.remove() }
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let page = try await producer.aiAudit(.init(), requestId: requestID, deadline: fixture.deadline())
        XCTAssertEqual(page.total, 0)
        XCTAssertEqual(page.items, [])
        XCTAssertNil(page.nextCursor)
        let stats = try await producer.aiStats(.init(), requestId: requestID, deadline: fixture.deadline())
        XCTAssertEqual(stats.totals.requests, 0)
        XCTAssertTrue(stats.timeRange.from.contains("T"))
        XCTAssertTrue(stats.timeRange.to.contains("T"))
    }

    func testMissingTableIsUnavailable() async throws {
        let fixture = try seeded()
        defer { fixture.remove() }
        try fixture.write { db in try db.execute(sql: "DROP TABLE ai_audit_log") }
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        do {
            _ = try await producer.aiAudit(.init(), requestId: requestID, deadline: fixture.deadline())
            XCTFail("Omitted audit storage must not look like an empty page")
        } catch { XCTAssertEqual(error as? ServiceWebMetadataError, .unavailable) }
        do {
            _ = try await producer.aiStats(.init(), requestId: requestID, deadline: fixture.deadline())
            XCTFail("Omitted audit storage must not invent zero stats")
        } catch { XCTAssertEqual(error as? ServiceWebMetadataError, .unavailable) }
    }

    func testContinuedPageRejectsRevokedVisibility() async throws {
        let fixture = try seeded()
        defer { fixture.remove() }
        try insert(fixture, ts: "2026-09-13T12:00:00.000", session: "one", model: "newer")
        try insert(fixture, ts: "2026-09-13T11:00:00.000", session: "one", model: "older")
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let first = try await producer.aiAudit(.init(limit: 1), requestId: requestID, deadline: fixture.deadline())
        try fixture.hide("one")
        do {
            _ = try await producer.aiAudit(
                .init(limit: 1, snapshotId: first.snapshotId, cursor: try XCTUnwrap(first.nextCursor)),
                requestId: requestID, deadline: fixture.deadline())
            XCTFail("A stale authorized page must not be released")
        } catch { XCTAssertEqual(error as? ServiceWebMetadataError, .stale) }
    }

    func testStatsAfterPreparationHideOfContributingSessionIsStale() async throws {
        let fixture = try seeded()
        defer { fixture.remove() }
        try insert(fixture, ts: recentUTC(), session: "one")
        let producer = try fixture.producer(hooks: .init(afterPreparation: { operation in
            guard operation == .aiStats else { return }
            try fixture.hide("one")
        }))
        defer { try? producer.stop() }
        do {
            _ = try await producer.aiStats(.init(), requestId: requestID, deadline: fixture.deadline())
            XCTFail("Hiding a contributing session must invalidate the prepared stats snapshot")
        } catch { XCTAssertEqual(error as? ServiceWebMetadataError, .stale) }
    }

    func testStatsAcceptsOneSidedDatesAndPublishesResolvedISOInterval() async throws {
        let fixture = try seeded()
        defer { fixture.remove() }
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let today = Self.localDay(Date())
        let fromOnly = try await producer.aiStats(.init(from: today),
                                                  requestId: requestID, deadline: fixture.deadline())
        XCTAssertTrue(fromOnly.timeRange.from.contains("T"))
        XCTAssertTrue(fromOnly.timeRange.to.contains("T"))
        XCTAssertLessThanOrEqual(fromOnly.timeRange.from, fromOnly.timeRange.to)
        let toOnly = try await producer.aiStats(.init(to: today),
                                                requestId: requestID, deadline: fixture.deadline())
        XCTAssertTrue(toOnly.timeRange.from.contains("T"))
        XCTAssertTrue(toOnly.timeRange.to.contains("T"))
        XCTAssertLessThanOrEqual(toOnly.timeRange.from, toOnly.timeRange.to)
        XCTAssertNoThrow(try EngramServiceWebAiStatsRequest(from: "2026-09-01"))
        XCTAssertNoThrow(try EngramServiceWebAiStatsRequest(to: today))
        XCTAssertThrowsError(try EngramServiceWebAiStatsRequest(from: "2026-09-13", to: "2026-09-01"))
    }

    private static func localDay(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    func testNativeFractionalTimestampInCurrentSecondIsIncludedInLast24h() async throws {
        let fixture = try seeded()
        defer { fixture.remove() }
        try fixture.write { db in
            try db.execute(sql: """
                INSERT INTO ai_audit_log(caller, operation, model, prompt_tokens, completion_tokens, total_tokens)
                VALUES ('summary', 'chat', 'demo-chat', 120, 30, 150)
                """)
        }
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let stats = try await producer.aiStats(.init(), requestId: requestID, deadline: fixture.deadline())
        XCTAssertEqual(stats.totals.requests, 1)
        XCTAssertEqual(stats.totals.promptTokens, 120)
        XCTAssertEqual(stats.totals.completionTokens, 30)
        XCTAssertTrue(stats.timeRange.to.contains("."))
    }

    func testJulianInstantBoundsExcludeOffsetTimestampThatLexicalCompareWouldAdmit() async throws {
        let fixture = try seeded()
        defer { fixture.remove() }
        let offset = "2026-09-13T01:00:00+08:00"
        try insert(fixture, ts: offset, session: nil, model: "offset")
        try insert(fixture, ts: recentUTC(), session: nil, model: "recent")
        try insert(fixture, ts: "2020-01-01T00:00:00.000", session: nil, model: "old")
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let stats = try await producer.aiStats(.init(), requestId: requestID, deadline: fixture.deadline())
        let bound = Date().addingTimeInterval(-86_400)
        let offsetInstant = try XCTUnwrap(ISO8601DateFormatter().date(from: offset))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let boundISO = formatter.string(from: bound)
        let lexical = offset > boundISO
        let julian = offsetInstant > bound
        let expected = 1 + (julian ? 1 : 0)
        XCTAssertEqual(stats.totals.requests, Int64(expected),
                       "last24h must follow julianday, not lexical ISO compare (lexical=\(lexical) julian=\(julian) bound=\(boundISO))")
        XCTAssertEqual(Set(stats.byModel.map(\.key)).contains("old"), false)
        XCTAssertEqual(Set(stats.byModel.map(\.key)).contains("recent"), true)
    }

    private func seeded() throws -> MetadataSQLFixture {
        let fixture = try MetadataSQLFixture()
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "one", start: "2026-09-01 12:00:00", nativeID: "native-one")
        return fixture
    }

    private func visibilityFixture() throws -> MetadataSQLFixture {
        let fixture = try seeded()
        try fixture.seedBoundSession(id: "hidden", start: "2026-09-01 12:00:00", nativeID: "native-hidden", hidden: true)
        try fixture.seedBoundSession(id: "skip", start: "2026-09-01 12:00:00", nativeID: "native-skip", tier: "skip")
        try fixture.seedBoundSession(id: "agent", start: "2026-09-01 12:00:00", nativeID: "native-agent", parent: "one")
        try fixture.seedLocalSession(id: "unbound")
        try insert(fixture, ts: "2026-09-13T12:00:00.000", session: "one", model: "visible")
        try insert(fixture, ts: "2026-09-13T11:00:00.000", session: "hidden", model: "hidden")
        try insert(fixture, ts: "2026-09-13T10:00:00.000", session: "skip", model: "skip")
        try insert(fixture, ts: "2026-09-13T09:00:00.000", session: "agent", model: "agent")
        try insert(fixture, ts: "2026-09-13T08:00:00.000", session: "unbound", model: "unbound")
        try insert(fixture, ts: "2026-09-13T07:00:00.000", session: nil, model: "unscoped")
        return fixture
    }

    private func insert(
        _ fixture: MetadataSQLFixture, ts: String, caller: String = "summary",
        session: String? = "one", model: String = "demo-chat",
        requestBody: String? = nil, responseBody: String? = nil,
        error: String? = nil
    ) throws {
        try fixture.write { db in
            try db.execute(sql: """
                INSERT INTO ai_audit_log(
                    ts, caller, operation, method, url, status_code, duration_ms, model, provider,
                    prompt_tokens, completion_tokens, total_tokens, request_body, response_body,
                    error, session_id)
                VALUES (?, ?, 'chat', 'POST', 'https://engram-ai.test/v1', 200, 12, ?, 'synthetic',
                        120, 30, 150, ?, ?, ?, ?)
                """, arguments: [ts, caller, model, requestBody, responseBody, error, session])
        }
    }

    private func rowID(_ fixture: MetadataSQLFixture, session: String) throws -> String {
        var id = ""
        try fixture.write { db in
            id = String(try XCTUnwrap(Int64.fetchOne(
                db, sql: "SELECT id FROM ai_audit_log WHERE session_id = ?", arguments: [session])))
        }
        return id
    }

    private func recentUTC() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
}
