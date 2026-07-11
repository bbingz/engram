import XCTest
@testable import EngramServiceCore

final class ArchiveV2OperatorIPCTests: XCTestCase {
    actor MemoryStore {
        var values: [String: String] = [:]
        var saveCount = 0
        func load(_ replicaID: String) -> String? { values[replicaID] }
        func save(_ token: String, _ replicaID: String) {
            saveCount += 1
            values[replicaID] = token
        }
    }

    func testProvisionerStoresOnlyFixedReplicaAndRejectsDuplicatePair() async throws {
        let memory = MemoryStore()
        let provisioner = ArchiveV2CredentialProvisioner(
            load: { replicaID in await memory.load(replicaID) },
            save: { token, replicaID in await memory.save(token, replicaID) }
        )
        let hq = Data(repeating: 0x11, count: 32).base64EncodedString()
        let m1 = Data(repeating: 0x22, count: 32).base64EncodedString()

        let first = try await provisioner.store(token: hq, replicaID: "hq")
        XCTAssertEqual(first.replicaID, "hq")
        XCTAssertTrue(first.stored)
        XCTAssertFalse(first.pairReady)
        XCTAssertTrue(first.serviceRestartRequired)

        let second = try await provisioner.store(token: m1, replicaID: "m1")
        XCTAssertTrue(second.pairReady)
        await XCTAssertThrowsErrorAsync { try await provisioner.store(token: hq, replicaID: "m1") }
        await XCTAssertThrowsErrorAsync { try await provisioner.store(token: hq, replicaID: "other") }
    }

    func testProvisionerRejectsSaveNoOpAndLoadFailure() async throws {
        let token = Data(repeating: 0x44, count: 32).base64EncodedString()
        let noOp = ArchiveV2CredentialProvisioner(load: { _ in nil }, save: { _, _ in })
        await XCTAssertThrowsErrorAsync { try await noOp.store(token: token, replicaID: "hq") }

        let unavailable = ArchiveV2CredentialProvisioner(
            load: { _ in throw OperatorTestError.unavailable },
            save: { _, _ in XCTFail("save must not run after a failed preflight load") }
        )
        await XCTAssertThrowsErrorAsync { try await unavailable.store(token: token, replicaID: "hq") }
    }

    func testStoreTokenIPCIsCapabilityProtectedAndResponseCannotEchoSecret() throws {
        XCTAssertTrue(ServiceCapabilityToken.requiresToken("archiveV2StoreToken"))
        let token = Data(repeating: 0x33, count: 32).base64EncodedString()
        let response = EngramServiceArchiveV2StoreTokenResponse(replicaID: "hq", stored: true, pairReady: false, serviceRestartRequired: true)
        let encoded = try JSONEncoder().encode(response)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(token))
    }

    func testStoreTokenSocketRejectsWrongCapabilityBeforeHandlerAndAllowsAuthorizedRequest() async throws {
        let runtime = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("engram-a2operator-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: runtime,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: runtime) }
        let socket = runtime.appendingPathComponent("engram-service.sock")
        let calls = OperatorCallProbe()
        let server = UnixSocketServiceServer(socketPath: socket.path) { request in
            await calls.record()
            let response = EngramServiceArchiveV2StoreTokenResponse(
                replicaID: "hq", stored: true, pairReady: false, serviceRestartRequired: true
            )
            return .success(requestId: request.requestId, result: try! JSONEncoder().encode(response))
        }
        try server.start()
        defer { server.stop() }
        let transport = UnixSocketEngramServiceTransport(socketPath: socket.path)
        let secret = Data(repeating: 0x55, count: 32).base64EncodedString()
        let payload = try JSONEncoder().encode(EngramServiceArchiveV2StoreTokenRequest(replicaID: "hq", token: secret))

        let rejected = try await transport.send(
            EngramServiceRequestEnvelope(command: "archiveV2StoreToken", payload: payload, capabilityToken: "wrong-token"),
            timeout: 2
        )
        guard case .failure(_, let error) = rejected else { return XCTFail("expected Unauthorized") }
        XCTAssertEqual(error.name, "Unauthorized")
        let rejectedCallCount = await calls.count()
        XCTAssertEqual(rejectedCallCount, 0)

        let accepted = try await transport.send(
            EngramServiceRequestEnvelope(command: "archiveV2StoreToken", payload: payload),
            timeout: 2
        )
        guard case .success(_, let data, _) = accepted else { return XCTFail("expected success") }
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(secret))
        let acceptedCallCount = await calls.count()
        XCTAssertEqual(acceptedCallCount, 1)
    }

    func testHandlerDoesNotMisreportCredentialStoreFailureAsInvalidInput() async throws {
        let runtime = try makeOperatorRuntime()
        defer { try? FileManager.default.removeItem(at: runtime) }
        let gate = try ServiceWriterGate(
            databasePath: runtime.appendingPathComponent("index.sqlite").path,
            runtimeDirectory: runtime
        )
        let unavailable = ArchiveV2CredentialProvisioner(
            load: { _ in throw OperatorTestError.unavailable },
            save: { _, _ in XCTFail("save must not run") }
        )
        let handler = EngramServiceCommandHandler(
            writerGate: gate,
            archiveV2CredentialProvisioner: unavailable
        )
        let token = Data(repeating: 0x66, count: 32).base64EncodedString()
        let response = await handler.handle(
            EngramServiceRequestEnvelope(
                command: "archiveV2StoreToken",
                payload: try JSONEncoder().encode(
                    EngramServiceArchiveV2StoreTokenRequest(replicaID: "hq", token: token)
                )
            )
        )
        guard case .failure(_, let error) = response else { return XCTFail("expected failure") }
        XCTAssertEqual(error.name, "ServiceUnavailable")
        XCTAssertFalse(error.message.contains(token))
    }

    private func makeOperatorRuntime() throws -> URL {
        let runtime = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("engram-a2operator-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: runtime,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return runtime
    }
}

private enum OperatorTestError: Error { case unavailable }

private actor OperatorCallProbe {
    private var value = 0
    func record() { value += 1 }
    func count() -> Int { value }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("expected error", file: file, line: line)
    } catch {}
}
