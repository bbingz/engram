import XCTest
@testable import EngramServiceCore

final class EngramServiceInspectorClientTests: XCTestCase {
    func testInspectSessionEncodesIdAndDecodesInspectorDTO() async throws {
        let dtoJSON = #"""
        {
          "session": {"id":"abc-123","source":"codex","messageCount":4,"cwd":"/cwd"},
          "provenance": {"transcript":"local_file","title":"fallback","cost":"unknown","parentLink":"unknown"},
          "summaries": {
            "provenance": {"firstMessageSummary":"unknown","storedSummary":"unknown","llmSummary":"unknown","compactSummary":"unknown"}
          },
          "status": {"label":"unknown","confidence":"low","source":"fallback","basisTags":[]},
          "agentGraph": {"childCount":0,"suggestedChildCount":0},
          "llm": {"auditRecordCount":0,"callers":[]},
          "resume": {
            "capability":"unsupported",
            "tool":"codex",
            "cwd":"/cwd",
            "evidence":"fallback",
            "warning":"codex command path not resolved (no resolver provided)"
          },
          "cost": {"source":"unknown","warning":"No cost data available"}
        }
        """#
        let transport = InspectorRecordingTransport { request in
            XCTAssertEqual(request.command, "inspectSession")
            let payload = try JSONDecoder().decode(
                EngramServiceSessionInspectorRequest.self,
                from: try XCTUnwrap(request.payload)
            )
            XCTAssertEqual(payload.id, "abc-123")
            return .success(
                requestId: request.requestId,
                result: Data(dtoJSON.utf8)
            )
        }
        let client = EngramServiceClient(transport: transport)

        let dto = try await client.inspectSession(id: "abc-123")
        XCTAssertEqual(dto.session.id, "abc-123")
        XCTAssertEqual(dto.session.source, "codex")
        XCTAssertEqual(dto.resume.capability, "unsupported")
        XCTAssertNil(dto.resume.command)
        XCTAssertNil(dto.resume.args)
        XCTAssertEqual(dto.summaries.provenance.llmSummary, "unknown")
        XCTAssertNil(dto.summaries.llmSummary)

        let requests = await transport.recordedRequests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.command, "inspectSession")
    }

    func testInspectSessionMissingSessionMapsToInvalidRequestError() async throws {
        let transport = InspectorRecordingTransport { request in
            .failure(
                requestId: request.requestId,
                error: EngramServiceErrorEnvelope(
                    name: "InvalidRequest",
                    message: "Session not found: ghost",
                    retryPolicy: "never"
                )
            )
        }
        let client = EngramServiceClient(transport: transport)

        do {
            _ = try await client.inspectSession(id: "ghost")
            XCTFail("Expected invalidRequest error")
        } catch let error as EngramServiceError {
            XCTAssertEqual(error, .invalidRequest(message: "Session not found: ghost"))
        }
    }
}

private actor InspectorRecordingTransport: EngramServiceTransport {
    private let handler: @Sendable (EngramServiceRequestEnvelope) async throws -> EngramServiceResponseEnvelope
    private(set) var recordedRequests: [EngramServiceRequestEnvelope] = []

    init(handler: @escaping @Sendable (EngramServiceRequestEnvelope) async throws -> EngramServiceResponseEnvelope) {
        self.handler = handler
    }

    func send(_ request: EngramServiceRequestEnvelope, timeout: TimeInterval?) async throws -> EngramServiceResponseEnvelope {
        recordedRequests.append(request)
        return try await handler(request)
    }

    nonisolated func events() -> AsyncThrowingStream<EngramServiceEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func close() async {}
}
