import XCTest
@testable import Engram

final class MemoryViewTests: XCTestCase {
    func testReloadDropsSelectionMissingFromActiveInsights_repro() {
        let selected = EngramServiceInsightInfo(
            id: "deleted", content: "deleted insight", wing: nil, room: nil,
            importance: 3, createdAt: "2026-08-22T00:00:00Z"
        )

        XCTAssertNil(MemoryView.retainedSelection(selected, in: []))
    }

    func testReloadRetainsTheFreshlyLoadedInsightRow_repro() throws {
        let stale = EngramServiceInsightInfo(
            id: "active", content: "stale preview", wing: nil, room: nil,
            importance: 3, createdAt: "2026-08-22T00:00:00Z"
        )
        let loaded = EngramServiceInsightInfo(
            id: "active", content: "fresh preview", wing: "engram", room: nil,
            importance: 5, createdAt: "2026-08-24T00:00:00Z"
        )

        let retained = try XCTUnwrap(MemoryView.retainedSelection(stale, in: [loaded]))

        XCTAssertEqual(retained.content, "fresh preview")
        XCTAssertEqual(retained.importance, 5)
    }

    func testInsightLoadsAreGenerationGatedAndNeverFallbackToListPreview_repro() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("macos/Engram/Views/Pages/MemoryView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("@State private var loadGeneration"))
        XCTAssertTrue(source.contains("guard generation == loadGeneration else { return }"))
        XCTAssertFalse(source.contains("selectedInsightDetail ?? selected"))
        XCTAssertFalse(source.contains("detail ?? insight"))
        XCTAssertFalse(source.contains("selectedInsightDetail = insight"))
    }

    func testInsightReloadAndDeleteInvalidateDetailAndDropDeletedRowImmediately_repro() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("macos/Engram/Views/Pages/MemoryView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("insights.removeAll { $0.id == insight.id }"))
        XCTAssertTrue(source.contains("if let retainedInsight"))
        XCTAssertTrue(source.contains("insightDetailGeneration &+= 1"))
    }

    func testInsightsCommandRoundTrips() async throws {
        let transport = RecordingMemoryTransport { request in
            XCTAssertEqual(request.command, "insights")
            return .success(
                requestId: request.requestId,
                result: #"[{"id":"i1","content":"a long enough insight body","wing":"eng","room":null,"importance":7,"created_at":"2026-06-01T00:00:00Z"}]"#.data(using: .utf8)!
            )
        }
        let client = EngramServiceClient(transport: transport)

        let rows = try await client.insights()
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.id, "i1")
        XCTAssertEqual(row.content, "a long enough insight body")
        XCTAssertEqual(row.wing, "eng")
        XCTAssertNil(row.room)
        XCTAssertEqual(row.importance, 7)
        XCTAssertEqual(row.createdAt, "2026-06-01T00:00:00Z")
    }

    func testMemoryFileOptionalContentAndDetailFallback() throws {
        let decoder = JSONDecoder()

        let withContent = try decoder.decode(
            EngramServiceMemoryFile.self,
            from: #"{"name":"A.md","project":"engram","path":"~/A.md","sizeBytes":9,"preview":"short","content":"FULL FILE BODY"}"#.data(using: .utf8)!
        )
        XCTAssertEqual(withContent.content, "FULL FILE BODY")
        XCTAssertEqual(MemoryView.detailText(for: withContent), "FULL FILE BODY")

        let withoutContent = try decoder.decode(
            EngramServiceMemoryFile.self,
            from: #"{"name":"B.md","project":"engram","path":"~/B.md","sizeBytes":5,"preview":"only preview"}"#.data(using: .utf8)!
        )
        XCTAssertNil(withoutContent.content)
        XCTAssertEqual(MemoryView.detailText(for: withoutContent), "only preview")
    }

    func testInsightContentValidation() {
        XCTAssertFalse(MemoryView.insightContentIsValid("too short"))
        XCTAssertFalse(MemoryView.insightContentIsValid("   short   "))
        XCTAssertTrue(MemoryView.insightContentIsValid("this is definitely long enough"))
    }

    func testInsightImportanceRangeMatchesBackend() {
        // Backend normalizedImportance accepts only 0...5, so the stepper must
        // cap at 5 — 6...10 always failed the round-trip.
        XCTAssertEqual(MemoryView.insightImportanceRange, 1...5)
    }

    func testInsightDetailCommandRoundTrips() async throws {
        let transport = RecordingMemoryTransport { request in
            XCTAssertEqual(request.command, "insightDetail")
            return .success(
                requestId: request.requestId,
                result: #"{"id":"i1","content":"the full untruncated insight body","wing":"eng","room":null,"importance":4,"created_at":"2026-06-01T00:00:00Z"}"#.data(using: .utf8)!
            )
        }
        let client = EngramServiceClient(transport: transport)

        let detail = try await client.insightDetail(id: "i1")
        XCTAssertEqual(detail?.id, "i1")
        XCTAssertEqual(detail?.content, "the full untruncated insight body")
        XCTAssertEqual(detail?.importance, 4)
    }

    func testMemoryFileContentCommandRoundTrips() async throws {
        let transport = RecordingMemoryTransport { request in
            XCTAssertEqual(request.command, "memoryFileContent")
            return .success(
                requestId: request.requestId,
                result: #"{"path":"~/A.md","content":"FULL FILE BODY","truncated":false}"#.data(using: .utf8)!
            )
        }
        let client = EngramServiceClient(transport: transport)

        let response = try await client.memoryFileContent(path: "~/A.md")
        XCTAssertEqual(response.path, "~/A.md")
        XCTAssertEqual(response.content, "FULL FILE BODY")
        XCTAssertFalse(response.truncated)
    }
}

private actor RecordingMemoryTransport: EngramServiceTransport {
    private let handler: @Sendable (EngramServiceRequestEnvelope) async throws -> EngramServiceResponseEnvelope

    init(handler: @escaping @Sendable (EngramServiceRequestEnvelope) async throws -> EngramServiceResponseEnvelope) {
        self.handler = handler
    }

    func send(_ request: EngramServiceRequestEnvelope, timeout: TimeInterval?) async throws -> EngramServiceResponseEnvelope {
        try await handler(request)
    }

    nonisolated func events() -> AsyncThrowingStream<EngramServiceEvent, Error> {
        AsyncThrowingStream { _ in }
    }

    nonisolated func close() {}
}
