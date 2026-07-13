import Foundation
import XCTest

@testable import EngramServiceCore

final class EngramServiceWireCommandTests: XCTestCase {
    func testClaudeProfileCapabilityContractProtectsConfigureOnly() {
        XCTAssertFalse(ServiceCapabilityToken.requiresToken("claudeCodeProfilesStatus"))
        XCTAssertTrue(ServiceCapabilityToken.requiresToken("configureClaudeCodeProfiles"))
    }

    func testClaudeProfileStatusRoundTripsAndOlderCountsDefaultToZero() throws {
        let status = try makeStatus()
        let encoded = try JSONEncoder().encode(status)
        XCTAssertEqual(
            try JSONDecoder().decode(
                EngramServiceClaudeCodeProfilesStatusResponse.self,
                from: encoded
            ),
            status
        )

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
        for key in [
            "discoveredFileCount",
            "discoveredSourceBytes",
            "indexedLocatorCount",
            "capturedCount",
            "ignoredEmptyCaptureCount",
            "hqVerifiedCount",
            "m1VerifiedCount",
            "error",
        ] {
            profiles[0].removeValue(forKey: key)
        }
        object["profiles"] = profiles
        object.removeValue(forKey: "configurationError")

        let oldDecoded = try JSONDecoder().decode(
            EngramServiceClaudeCodeProfilesStatusResponse.self,
            from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        )
        let row = try XCTUnwrap(oldDecoded.profiles.first)
        XCTAssertEqual(row.discoveredFileCount, 0)
        XCTAssertEqual(row.discoveredSourceBytes, 0)
        XCTAssertEqual(row.indexedLocatorCount, 0)
        XCTAssertEqual(row.capturedCount, 0)
        XCTAssertEqual(row.ignoredEmptyCaptureCount, 0)
        XCTAssertEqual(row.hqVerifiedCount, 0)
        XCTAssertEqual(row.m1VerifiedCount, 0)
        XCTAssertNil(row.error)
        XCTAssertNil(oldDecoded.configurationError)
    }

    func testClaudeProfileStatusRejectsNegativeCountsAndMoreThan128Rows() throws {
        XCTAssertThrowsError(
            try EngramServiceClaudeCodeProfileStatus(
                id: "automatic-id",
                displayName: "api",
                projectsRoot: "/tmp/api/projects",
                origin: "automatic",
                available: true,
                sourceReclamationAllowed: true,
                discoveredFileCount: -1,
                discoveredSourceBytes: 0,
                indexedLocatorCount: 0,
                capturedCount: 0,
                ignoredEmptyCaptureCount: 0,
                hqVerifiedCount: 0,
                m1VerifiedCount: 0,
                error: nil
            )
        )
        let row = try makeStatus().profiles[0]
        XCTAssertThrowsError(
            try EngramServiceClaudeCodeProfilesStatusResponse(
                autoDiscover: true,
                customProjectsRoots: [],
                profiles: Array(repeating: row, count: 129),
                configurationError: nil
            )
        )
    }

    func testClaudeProfileHandlerRequiresAbsentStatusPayloadAndAvailableFeature() async throws {
        let harness = try makeGateHarness()
        let handler = EngramServiceCommandHandler(writerGate: harness.gate)

        let payloadResponse = await handler.handle(
            EngramServiceRequestEnvelope(
                command: "claudeCodeProfilesStatus",
                payload: Data("{}".utf8)
            )
        )
        assertFailure(payloadResponse, name: "InvalidRequest")

        let statusResponse = await handler.handle(
            EngramServiceRequestEnvelope(command: "claudeCodeProfilesStatus")
        )
        assertFailure(
            statusResponse,
            name: "ServiceUnavailable",
            message: "feature_unavailable"
        )

        let configureResponse = await handler.handle(
            EngramServiceRequestEnvelope(
                command: "configureClaudeCodeProfiles",
                payload: try JSONEncoder().encode(
                    EngramServiceConfigureClaudeCodeProfilesRequest(
                        autoDiscover: true,
                        customProjectsRoots: []
                    )
                )
            )
        )
        assertFailure(
            configureResponse,
            name: "ServiceUnavailable",
            message: "feature_unavailable"
        )
    }

    func testClaudeProfileClientUsesFrozenCommandsAndAbsentStatusPayload() async throws {
        let status = try makeStatus()
        let transport = ClaudeProfileRecordingTransport { request in
            .success(
                requestId: request.requestId,
                result: try JSONEncoder().encode(status)
            )
        }
        let client = EngramServiceClient(transport: transport)

        let clientStatus = try await client.claudeCodeProfilesStatus()
        XCTAssertEqual(clientStatus, status)
        let configure = EngramServiceConfigureClaudeCodeProfilesRequest(
            autoDiscover: false,
            customProjectsRoots: ["/tmp/custom/projects"]
        )
        let configuredStatus = try await client.configureClaudeCodeProfiles(configure)
        XCTAssertEqual(configuredStatus, status)

        let requests = transport.snapshot()
        XCTAssertEqual(
            requests.map(\.command),
            ["claudeCodeProfilesStatus", "configureClaudeCodeProfiles"]
        )
        XCTAssertNil(requests[0].payload)
        XCTAssertEqual(
            try JSONDecoder().decode(
                EngramServiceConfigureClaudeCodeProfilesRequest.self,
                from: try XCTUnwrap(requests[1].payload)
            ),
            configure
        )
    }

    func testMockClientImplementsClaudeProfileContract() async throws {
        let status = try makeStatus()
        let client = MockEngramServiceClient(claudeCodeProfilesStatus: status)

        let clientStatus = try await client.claudeCodeProfilesStatus()
        let configuredStatus = try await client.configureClaudeCodeProfiles(
            EngramServiceConfigureClaudeCodeProfilesRequest(
                autoDiscover: true,
                customProjectsRoots: []
            )
        )
        XCTAssertEqual(clientStatus, status)
        XCTAssertEqual(configuredStatus, status)
    }

    private func makeStatus() throws -> EngramServiceClaudeCodeProfilesStatusResponse {
        try EngramServiceClaudeCodeProfilesStatusResponse(
            autoDiscover: true,
            customProjectsRoots: ["/tmp/custom/projects"],
            profiles: [
                try EngramServiceClaudeCodeProfileStatus(
                    id: "automatic-abc",
                    displayName: "api",
                    projectsRoot: "/tmp/api/projects",
                    origin: "automatic",
                    available: true,
                    sourceReclamationAllowed: true,
                    discoveredFileCount: 3,
                    discoveredSourceBytes: 42,
                    indexedLocatorCount: 2,
                    capturedCount: 2,
                    ignoredEmptyCaptureCount: 1,
                    hqVerifiedCount: 1,
                    m1VerifiedCount: 1,
                    error: nil
                ),
            ],
            configurationError: nil
        )
    }

    private func makeGateHarness() throws -> (gate: ServiceWriterGate, root: URL) {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("engram-profile-wire-\(UUID().uuidString)", isDirectory: true)
        let runtime = root.appendingPathComponent("run", isDirectory: true)
        try FileManager.default.createDirectory(
            at: runtime,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (
            try ServiceWriterGate(
                databasePath: root.appendingPathComponent("index.sqlite").path,
                runtimeDirectory: runtime
            ),
            root
        )
    }

    private func assertFailure(
        _ response: EngramServiceResponseEnvelope,
        name: String,
        message: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .failure(_, let error) = response else {
            return XCTFail("expected failure", file: file, line: line)
        }
        XCTAssertEqual(error.name, name, file: file, line: line)
        if let message {
            XCTAssertEqual(error.message, message, file: file, line: line)
        }
    }
}

private final class ClaudeProfileRecordingTransport: EngramServiceTransport, @unchecked Sendable {
    typealias Responder = @Sendable (
        EngramServiceRequestEnvelope
    ) throws -> EngramServiceResponseEnvelope

    private let lock = NSLock()
    private var requests: [EngramServiceRequestEnvelope] = []
    private let responder: Responder

    init(responder: @escaping Responder) {
        self.responder = responder
    }

    func send(
        _ request: EngramServiceRequestEnvelope,
        timeout _: TimeInterval?
    ) async throws -> EngramServiceResponseEnvelope {
        lock.lock()
        requests.append(request)
        lock.unlock()
        return try responder(request)
    }

    func events() -> AsyncThrowingStream<EngramServiceEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func close() {}

    func snapshot() -> [EngramServiceRequestEnvelope] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}
