import XCTest
@testable import Engram

final class SessionActionsTests: XCTestCase {
    // Drives EngramServiceClient through a recording transport, asserting each
    // session write command encodes the right command name + payload fields.
    // No capabilityToken assertion — the recording transport doesn't enforce it
    // and the client may attach one.
    func testSessionWriteCommandsEncodePayloads() async throws {
        let transport = RecordingTransport { request in
            switch request.command {
            case "setSessionHidden":
                let payload = try Self.payload(request.payload, as: EngramServiceSessionHiddenRequest.self)
                XCTAssertEqual(payload.sessionId, "s1")
                XCTAssertTrue(payload.hidden)
                return Self.empty(request)
            case "renameSession":
                let payload = try Self.payload(request.payload, as: EngramServiceRenameSessionRequest.self)
                XCTAssertEqual(payload.sessionId, "s1")
                // Asserted both nil (clear) and a real name below by call order.
                return Self.empty(request)
            case "setFavorite":
                let payload = try Self.payload(request.payload, as: EngramServiceFavoriteRequest.self)
                XCTAssertEqual(payload.sessionId, "s1")
                XCTAssertTrue(payload.favorite)
                return Self.empty(request)
            case "recordSessionAccess":
                let payload = try Self.payload(request.payload, as: EngramServiceSessionAccessRequest.self)
                XCTAssertEqual(payload.sessionId, "s1")
                return Self.empty(request)
            case "exportSession":
                let payload = try Self.payload(request.payload, as: EngramServiceExportSessionRequest.self)
                XCTAssertEqual(payload.id, "s1")
                XCTAssertTrue(payload.format == "markdown" || payload.format == "json")
                return .success(
                    requestId: request.requestId,
                    result: #"{"outputPath":"/tmp/exports/s1.md","format":"\#(payload.format)","messageCount":12}"#
                        .data(using: .utf8)!
                )
            default:
                XCTFail("Unexpected command \(request.command)")
                return Self.empty(request)
            }
        }
        let client = EngramServiceClient(transport: transport)

        try await client.setSessionHidden(sessionId: "s1", hidden: true)
        try await client.renameSession(sessionId: "s1", name: nil)
        try await client.renameSession(sessionId: "s1", name: "Auth refactor")
        try await client.setFavorite(sessionId: "s1", favorite: true)
        try await client.recordSessionAccess(sessionId: "s1")
        let mdExport = try await client.exportSession(
            EngramServiceExportSessionRequest(id: "s1", format: "markdown", outputHome: nil, actor: "app")
        )
        let jsonExport = try await client.exportSession(
            EngramServiceExportSessionRequest(id: "s1", format: "json", outputHome: nil, actor: "app")
        )

        XCTAssertEqual(mdExport.outputPath, "/tmp/exports/s1.md")
        XCTAssertEqual(mdExport.format, "markdown")
        XCTAssertEqual(mdExport.messageCount, 12)
        XCTAssertEqual(jsonExport.format, "json")

        // Assert the two rename payloads round-tripped nil then the trimmed name.
        let renamePayloads = try await transport.requests
            .filter { $0.command == "renameSession" }
            .map { try Self.payload($0.payload, as: EngramServiceRenameSessionRequest.self).name }
        XCTAssertEqual(renamePayloads, [nil, "Auth refactor"])

        let order = await transport.sentCommands
        XCTAssertEqual(order, [
            "setSessionHidden",
            "renameSession",
            "renameSession",
            "setFavorite",
            "recordSessionAccess",
            "exportSession",
            "exportSession",
        ])
    }

    func testRenameNameNormalization() {
        XCTAssertNil(SessionActionHandlers.normalizedName(""))
        XCTAssertNil(SessionActionHandlers.normalizedName("   "))
        XCTAssertEqual(SessionActionHandlers.normalizedName("  Auth refactor  "), "Auth refactor")
        XCTAssertEqual(SessionActionHandlers.normalizedName("x"), "x")
    }

    private static func empty(_ request: EngramServiceRequestEnvelope) -> EngramServiceResponseEnvelope {
        .success(requestId: request.requestId, result: Data("{}".utf8))
    }

    private static func payload<T: Decodable>(_ data: Data?, as type: T.Type) throws -> T {
        let data = try XCTUnwrap(data)
        return try JSONDecoder().decode(T.self, from: data)
    }
}

private actor RecordingTransport: EngramServiceTransport {
    private let handler: @Sendable (EngramServiceRequestEnvelope) throws -> EngramServiceResponseEnvelope
    private(set) var requests: [EngramServiceRequestEnvelope] = []
    private(set) var sentCommands: [String] = []

    init(handler: @escaping @Sendable (EngramServiceRequestEnvelope) throws -> EngramServiceResponseEnvelope) {
        self.handler = handler
    }

    func send(_ request: EngramServiceRequestEnvelope, timeout: TimeInterval?) async throws -> EngramServiceResponseEnvelope {
        requests.append(request)
        sentCommands.append(request.command)
        return try handler(request)
    }

    nonisolated func events() -> AsyncThrowingStream<EngramServiceEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    nonisolated func close() {}
}
