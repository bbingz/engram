import CryptoKit
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import XCTest

@testable import EngramRemoteServerCore

final class ArchiveRouteTests: XCTestCase {
    private static let archiveToken = "archive-route-secret"
    private static let legacyToken = "legacy-route-secret"
    private static let mcpToken = "mcp-route-secret"
    private static let mcpProtocolVersion = "2026-07-28"
    private static let sourceRevision = String(repeating: "a", count: 40)

    private static let mcpProtocolVersionHeader = HTTPField.Name("MCP-Protocol-Version")!
    private static let mcpMethodHeader = HTTPField.Name("Mcp-Method")!
    private static let mcpNameHeader = HTTPField.Name("Mcp-Name")!
    private static let mcpOriginHeader = HTTPField.Name("Origin")!
    private static let allowHeader = HTTPField.Name("Allow")!

    private var tempDir: URL!
    private var archiveKey: SymmetricKey!
    private var legacyKey: SymmetricKey!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-archive-routes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        archiveKey = SymmetricKey(size: .bits256)
        legacyKey = SymmetricKey(size: .bits256)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    func testArchiveRoutesAreInvisibleWhenDisabledAndEveryEnabledRouteAuthenticates() async throws {
        let disabled = Application(router: try makeRemoteApp(enabled: false).buildRouter())
        try await disabled.test(.router) { client in
            let response = try await client.execute(
                uri: "/v2/archive/machines",
                method: .get,
                headers: Self.headers()
            )
            XCTAssertEqual(response.status.code, 404)
        }

        let digest = ArchiveV2Hash.sha256(Data("route-auth".utf8))
        let enabled = Application(router: try makeRemoteApp().buildRouter())
        try await enabled.test(.router) { client in
            let legacyCredentialResponse = try await client.execute(
                uri: "/v2/archive/machines",
                method: .get,
                headers: Self.headers(token: Self.legacyToken)
            )
            XCTAssertEqual(legacyCredentialResponse.status.code, 401)

            let protectedRoutes: [(HTTPRequest.Method, String)] = [
                (.put, "/v2/archive/objects/\(digest)"),
                (.head, "/v2/archive/objects/\(digest)"),
                (.get, "/v2/archive/objects/\(digest)"),
                (.put, "/v2/archive/manifests/\(digest)"),
                (.head, "/v2/archive/manifests/\(digest)"),
                (.get, "/v2/archive/manifests/\(digest)"),
                (.put, "/v2/archive/receipts/\(digest)"),
                (.get, "/v2/archive/receipts/\(digest)"),
                (.get, "/v2/archive/receipts?machine_id=\(UUID().uuidString)"),
                (.get, "/v2/archive/machines"),
                (.get, "/v2/archive/status"),
                (.delete, "/v2/archive"),
                (.delete, "/v2/archive/objects/\(digest)"),
                (.delete, "/v2/archive/manifests/\(digest)"),
                (.delete, "/v2/archive/receipts/\(digest)"),
                (.delete, "/v2/archive/receipts"),
                (.delete, "/v2/archive/machines"),
                (.delete, "/v2/archive/status"),
                (.delete, "/v2/archive/arbitrary/deeper/path"),
            ]

            for (method, uri) in protectedRoutes {
                let response = try await client.execute(uri: uri, method: method)
                XCTAssertEqual(response.status.code, 401, "\(method.rawValue) \(uri)")
                XCTAssertEqual(response.headers[.wwwAuthenticate], "Bearer")
                XCTAssertTrue(response.headers[.contentType]?.hasPrefix("application/json") == true)
                XCTAssertLessThanOrEqual(response.body.readableBytes, ArchiveV2ProtocolLimits.maxErrorBytes)
            }

            for uri in [
                "/v2/archive",
                "/v2/archive/objects/\(digest)",
                "/v2/archive/manifests/\(digest)",
                "/v2/archive/receipts/\(digest)",
                "/v2/archive/receipts",
                "/v2/archive/machines",
                "/v2/archive/status",
                "/v2/archive/arbitrary/deeper/path",
            ] {
                let response = try await client.execute(
                    uri: uri,
                    method: .delete,
                    headers: Self.headers()
                )
                XCTAssertEqual(response.status.code, 405, uri)
            }
        }
    }

    func testArchiveHeadErrorsNeverWriteResponseBodies() async throws {
        let digest = String(repeating: "0", count: 64)
        let app = Application(router: try makeRemoteApp().buildRouter())

        try await app.test(.router) { client in
            let cases: [(uri: String, headers: HTTPFields, status: Int)] = [
                ("/v2/archive/objects/\(digest)", HTTPFields(), 401),
                ("/v2/archive/objects/not-a-digest", Self.headers(), 400),
                ("/v2/archive/objects/\(digest)", Self.headers(), 404),
                ("/v2/archive/manifests/\(digest)", HTTPFields(), 401),
                ("/v2/archive/manifests/not-a-digest", Self.headers(), 400),
                ("/v2/archive/manifests/\(digest)", Self.headers(), 404),
            ]

            for entry in cases {
                let response = try await client.execute(
                    uri: entry.uri,
                    method: .head,
                    headers: entry.headers
                )
                XCTAssertEqual(response.status.code, entry.status, entry.uri)
                XCTAssertEqual(
                    response.body.readableBytes,
                    0,
                    "HEAD emitted a response body for \(entry.uri)"
                )
            }
        }
    }

    func testStatusRequiresArchiveTokenAndContainsOnlyPriorCanonicalTelemetry() async throws {
        let now = try Self.instant("2026-07-12T10:00:00.000Z")
        let raw = Data("observed archive bytes".utf8)
        let digest = ArchiveV2Hash.sha256(raw)
        let app = Application(
            router: try makeRemoteApp(
                sourceRevision: Self.sourceRevision,
                telemetryNow: { now }
            ).buildRouter()
        )

        try await app.test(.router) { client in
            var response = try await client.execute(
                uri: "/v2/archive/objects/\(digest)",
                method: .put,
                headers: Self.headers(
                    contentType: "application/octet-stream",
                    contentLength: raw.count
                ),
                body: ByteBuffer(data: raw)
            )
            XCTAssertEqual(response.status.code, 201)

            response = try await client.execute(
                uri: "/v2/archive/status",
                method: .get
            )
            XCTAssertEqual(response.status.code, 401)

            response = try await client.execute(
                uri: "/v2/archive/status",
                method: .get,
                headers: Self.headers()
            )
            XCTAssertEqual(response.status.code, 200)
            XCTAssertTrue(response.headers[.contentType]?.hasPrefix("application/json") == true)
            let bytes = Self.data(response)
            XCTAssertLessThanOrEqual(
                bytes.count,
                ArchiveRemoteTelemetrySnapshot.maximumEncodedBytes
            )
            let snapshot = try ArchiveCanonicalJSON.decode(
                ArchiveRemoteTelemetrySnapshot.self,
                from: bytes
            )
            XCTAssertEqual(try ArchiveCanonicalJSON.encode(snapshot), bytes)
            XCTAssertEqual(snapshot.serverID, "hq")
            XCTAssertEqual(snapshot.sourceRevision, Self.sourceRevision)
            XCTAssertEqual(snapshot.requestCount, 2)
            XCTAssertEqual(snapshot.successCount, 1)
            XCTAssertEqual(snapshot.clientErrorCount, 1)
            XCTAssertEqual(snapshot.requestBytes, Int64(raw.count))
            XCTAssertEqual(snapshot.lastArchiveMutationAt, "2026-07-12T10:00:00.000Z")
            XCTAssertEqual(snapshot.recentErrors.map(\.category), ["unauthorized"])
            XCTAssertEqual(Set(snapshot.endpoints.map(\.endpoint)), ["object", "status"])

            let text = String(decoding: bytes, as: UTF8.self)
            for forbidden in [digest, Self.archiveToken, tempDir.path, "observed archive bytes"] {
                XCTAssertFalse(text.contains(forbidden), "telemetry exposed \(forbidden)")
            }

            let persistedURL = tempDir
                .appendingPathComponent("archive", isDirectory: true)
                .appendingPathComponent(".telemetry", isDirectory: true)
                .appendingPathComponent("status-v1.json")
            let persisted = try ArchiveCanonicalJSON.decode(
                ArchiveRemoteTelemetrySnapshot.self,
                from: Data(contentsOf: persistedURL)
            )
            XCTAssertEqual(persisted.requestCount, 2, "status must force-flush prior traffic")

            response = try await client.execute(
                uri: "/v2/archive/status",
                method: .get,
                headers: Self.headers()
            )
            let next = try ArchiveCanonicalJSON.decode(
                ArchiveRemoteTelemetrySnapshot.self,
                from: Self.data(response)
            )
            XCTAssertEqual(next.requestCount, 3, "a status response records itself only afterward")
        }
    }

    func testRouteTelemetryUsesFixedCategoriesAndNormalizedEndpointNames() async throws {
        let now = try Self.instant("2026-07-12T10:00:00.000Z")
        let archiveRoot = tempDir.appendingPathComponent("archive", isDirectory: true)
        let store = try ArchiveStore(
            root: archiveRoot,
            key: archiveKey,
            serverID: "hq",
            testHooks: ArchiveStoreTestHooks(beforeFileFsync: { _ in
                throw CocoaError(.fileWriteUnknown)
            })
        )
        let telemetry = try ArchiveRemoteTelemetryStore(
            archiveRoot: archiveRoot,
            serverID: "hq",
            sourceRevision: Self.sourceRevision,
            now: { now }
        )
        let router = Router<BasicRequestContext>()
        ArchiveRoutes.mount(
            on: router,
            store: store,
            token: Self.archiveToken,
            telemetry: telemetry
        )
        let app = Application(router: router)
        try await app.test(.router) { client in
            var response = try await client.execute(
                uri: "/v2/archive/objects/not-a-digest",
                method: .get,
                headers: Self.headers()
            )
            XCTAssertEqual(response.status.code, 400)

            let raw = Data("server failure bytes".utf8)
            let digest = ArchiveV2Hash.sha256(raw)
            response = try await client.execute(
                uri: "/v2/archive/objects/\(digest)",
                method: .put,
                headers: Self.headers(contentType: "application/octet-stream"),
                body: ByteBuffer(data: raw)
            )
            XCTAssertEqual(response.status.code, 500)

            response = try await client.execute(
                uri: "/v2/archive/status",
                method: .get,
                headers: Self.headers()
            )
            let snapshot = try ArchiveCanonicalJSON.decode(
                ArchiveRemoteTelemetrySnapshot.self,
                from: Self.data(response)
            )
            XCTAssertEqual(
                snapshot.recentErrors.map(\.category),
                ["malformed_request", "internal_error"]
            )
            XCTAssertEqual(snapshot.endpoints.map(\.endpoint), ["object"])
            let encoded = String(decoding: Self.data(response), as: UTF8.self)
            XCTAssertFalse(encoded.contains(digest))
            XCTAssertFalse(encoded.contains("not-a-digest"))
            XCTAssertFalse(encoded.contains(archiveRoot.path))
        }
    }

    func testTelemetryPersistenceFailureDoesNotChangeSuccessfulArchivePut() async throws {
        let now = try Self.instant("2026-07-12T10:00:00.000Z")
        let app = Application(
            router: try makeRemoteApp(
                sourceRevision: Self.sourceRevision,
                telemetryNow: { now },
                telemetrySnapshotWriter: { _, _ in
                    throw CocoaError(.fileWriteNoPermission)
                }
            ).buildRouter()
        )
        let raw = Data("business success survives telemetry".utf8)
        let digest = ArchiveV2Hash.sha256(raw)

        try await app.test(.router) { client in
            var response = try await client.execute(
                uri: "/v2/archive/objects/\(digest)",
                method: .put,
                headers: Self.headers(contentType: "application/octet-stream"),
                body: ByteBuffer(data: raw)
            )
            XCTAssertEqual(response.status.code, 201)

            response = try await client.execute(
                uri: "/v2/archive/status",
                method: .get,
                headers: Self.headers()
            )
            let snapshot = try ArchiveCanonicalJSON.decode(
                ArchiveRemoteTelemetrySnapshot.self,
                from: Self.data(response)
            )
            XCTAssertEqual(snapshot.requestCount, 1)
            XCTAssertEqual(snapshot.lastArchiveMutationAt, "2026-07-12T10:00:00.000Z")
            XCTAssertEqual(snapshot.persistenceError, "snapshot_write_failed")
        }
    }

    func testObjectRoutesEnforceContentTypeDigestAndExactEightMiBBound() async throws {
        let app = Application(router: try makeRemoteApp().buildRouter())
        try await app.test(.router) { client in
            let raw = Data(repeating: 0x5a, count: ArchiveV2ProtocolLimits.maxObjectRawBytes)
            let digest = ArchiveV2Hash.sha256(raw)
            let objectURI = "/v2/archive/objects/\(digest)"

            var response = try await client.execute(
                uri: objectURI,
                method: .put,
                headers: Self.headers(contentType: "application/octet-stream"),
                body: ByteBuffer(data: raw)
            )
            XCTAssertEqual(response.status.code, 201)

            response = try await client.execute(
                uri: objectURI,
                method: .put,
                headers: Self.headers(contentType: "application/octet-stream"),
                body: ByteBuffer(data: raw)
            )
            XCTAssertEqual(response.status.code, 200)

            response = try await client.execute(
                uri: objectURI,
                method: .head,
                headers: Self.headers()
            )
            XCTAssertEqual(response.status.code, 200)
            XCTAssertEqual(response.body.readableBytes, 0)

            response = try await client.execute(
                uri: objectURI,
                method: .get,
                headers: Self.headers()
            )
            XCTAssertEqual(response.status.code, 200)
            XCTAssertEqual(Self.data(response), raw)
            XCTAssertTrue(response.headers[.contentType]?.hasPrefix("application/octet-stream") == true)

            let oversized = Data(repeating: 0x33, count: ArchiveV2ProtocolLimits.maxObjectRawBytes + 1)
            response = try await client.execute(
                uri: "/v2/archive/objects/\(ArchiveV2Hash.sha256(oversized))",
                method: .put,
                headers: Self.headers(contentType: "application/octet-stream"),
                body: ByteBuffer(data: oversized)
            )
            XCTAssertEqual(response.status.code, 413)
            self.assertSafeError(response, forbidden: [Self.archiveToken, tempDir.path])

            let tiny = Data("actual-body".utf8)
            response = try await client.execute(
                uri: "/v2/archive/objects/\(ArchiveV2Hash.sha256(Data("other-body".utf8)))",
                method: .put,
                headers: Self.headers(contentType: "application/octet-stream"),
                body: ByteBuffer(data: tiny)
            )
            XCTAssertEqual(response.status.code, 422)
            self.assertSafeError(response, forbidden: [Self.archiveToken, tempDir.path, "actual-body"])

            response = try await client.execute(
                uri: "/v2/archive/objects/not-a-digest",
                method: .put,
                headers: Self.headers(contentType: "application/octet-stream"),
                body: ByteBuffer(data: tiny)
            )
            XCTAssertEqual(response.status.code, 400)

            response = try await client.execute(
                uri: "/v2/archive/objects/not-a-digest",
                method: .put,
                headers: Self.headers(contentType: "text/plain"),
                body: ByteBuffer(data: tiny)
            )
            XCTAssertEqual(response.status.code, 400, "path validation has priority over content type")

            response = try await client.execute(
                uri: "/v2/archive/objects/\(ArchiveV2Hash.sha256(tiny))",
                method: .put,
                headers: Self.headers(contentType: "text/plain"),
                body: ByteBuffer(data: tiny)
            )
            XCTAssertEqual(response.status.code, 415)
            self.assertSafeError(response, forbidden: [Self.archiveToken, tempDir.path, "actual-body"])

            let absentDigest = ArchiveV2Hash.sha256(Data("absent".utf8))
            response = try await client.execute(
                uri: "/v2/archive/objects/\(absentDigest)",
                method: .get,
                headers: Self.headers()
            )
            XCTAssertEqual(response.status.code, 404)
        }
    }

    func testManifestAndReceiptRoutesValidateReferencesAndPreserveFirstReceipt() async throws {
        let app = Application(router: try makeRemoteApp().buildRouter())
        try await app.test(.router) { client in
            let raw = Data("canonical archive source".utf8)
            let rawDigest = ArchiveV2Hash.sha256(raw)
            let machineID = UUID().uuidString
            let (manifest, manifestDigest) = try Self.manifest(
                raw: raw,
                machineID: machineID,
                seed: "coherent"
            )

            var response = try await client.execute(
                uri: "/v2/archive/manifests/\(manifestDigest)",
                method: .put,
                headers: Self.headers(contentType: "application/json"),
                body: ByteBuffer(data: manifest)
            )
            XCTAssertEqual(response.status.code, 409, "referenced object is absent")
            self.assertSafeError(response, forbidden: [Self.archiveToken, tempDir.path, "canonical archive source"])

            response = try await client.execute(
                uri: "/v2/archive/objects/\(rawDigest)",
                method: .put,
                headers: Self.headers(contentType: "application/octet-stream"),
                body: ByteBuffer(data: raw)
            )
            XCTAssertEqual(response.status.code, 201)

            response = try await client.execute(
                uri: "/v2/archive/manifests/\(manifestDigest)",
                method: .put,
                headers: Self.headers(contentType: "application/json"),
                body: ByteBuffer(data: manifest)
            )
            XCTAssertEqual(response.status.code, 201)

            response = try await client.execute(
                uri: "/v2/archive/manifests/\(manifestDigest)",
                method: .put,
                headers: Self.headers(contentType: "application/json; charset=utf-8"),
                body: ByteBuffer(data: manifest)
            )
            XCTAssertEqual(response.status.code, 200)

            response = try await client.execute(
                uri: "/v2/archive/manifests/\(manifestDigest)",
                method: .head,
                headers: Self.headers()
            )
            XCTAssertEqual(response.status.code, 200)
            XCTAssertEqual(response.body.readableBytes, 0)

            response = try await client.execute(
                uri: "/v2/archive/manifests/\(manifestDigest)",
                method: .get,
                headers: Self.headers()
            )
            XCTAssertEqual(response.status.code, 200)
            XCTAssertEqual(Self.data(response), manifest)
            XCTAssertTrue(response.headers[.contentType]?.hasPrefix("application/json") == true)

            let receiptURI = "/v2/archive/receipts/\(manifestDigest)"
            response = try await client.execute(
                uri: receiptURI,
                method: .put,
                headers: Self.headers()
            )
            XCTAssertEqual(response.status.code, 201)
            let firstReceipt = Self.data(response)
            let decoded = try ArchiveCanonicalJSON.decode(ArchiveServerReceipt.self, from: firstReceipt)
            XCTAssertEqual(decoded.manifestSHA256, manifestDigest)
            XCTAssertEqual(decoded.machineID, machineID)

            response = try await client.execute(
                uri: receiptURI,
                method: .put,
                headers: Self.headers()
            )
            XCTAssertEqual(response.status.code, 200)
            XCTAssertEqual(Self.data(response), firstReceipt)

            response = try await client.execute(
                uri: receiptURI,
                method: .get,
                headers: Self.headers()
            )
            XCTAssertEqual(response.status.code, 200)
            XCTAssertEqual(Self.data(response), firstReceipt)

            let invalid = Data(#"{"schemaVersion":1}"#.utf8)
            response = try await client.execute(
                uri: "/v2/archive/manifests/\(ArchiveV2Hash.sha256(invalid))",
                method: .put,
                headers: Self.headers(contentType: "application/json"),
                body: ByteBuffer(data: invalid)
            )
            XCTAssertEqual(response.status.code, 422)

            response = try await client.execute(
                uri: "/v2/archive/manifests/\(manifestDigest)",
                method: .put,
                headers: Self.headers(contentType: "text/plain"),
                body: ByteBuffer(data: manifest)
            )
            XCTAssertEqual(response.status.code, 415)

            let (unbound, unboundDigest) = try Self.manifest(
                raw: Data(),
                machineID: machineID,
                seed: "unbound",
                sessionID: nil
            )
            response = try await client.execute(
                uri: "/v2/archive/manifests/\(unboundDigest)",
                method: .put,
                headers: Self.headers(contentType: "application/json"),
                body: ByteBuffer(data: unbound)
            )
            XCTAssertEqual(response.status.code, 201)
            response = try await client.execute(
                uri: "/v2/archive/receipts/\(unboundDigest)",
                method: .put,
                headers: Self.headers()
            )
            XCTAssertEqual(response.status.code, 422)
            self.assertSafeError(response, forbidden: [Self.archiveToken, tempDir.path])
        }
    }

    func testManifestPutReturnsConflictForCorruptReferencedObject() async throws {
        let raw = Data("reference-that-will-be-corrupted".utf8)
        let rawDigest = ArchiveV2Hash.sha256(raw)
        let (manifest, manifestDigest) = try Self.manifest(
            raw: raw,
            machineID: UUID().uuidString,
            seed: "corrupt-reference"
        )
        let app = Application(router: try makeRemoteApp().buildRouter())
        try await app.test(.router) { client in
            var response = try await client.execute(
                uri: "/v2/archive/objects/\(rawDigest)",
                method: .put,
                headers: Self.headers(contentType: "application/octet-stream"),
                body: ByteBuffer(data: raw)
            )
            XCTAssertEqual(response.status.code, 201)

            try Data("corrupt envelope".utf8).write(
                to: self.archiveObjectURL(digest: rawDigest),
                options: []
            )
            response = try await client.execute(
                uri: "/v2/archive/manifests/\(manifestDigest)",
                method: .put,
                headers: Self.headers(contentType: "application/json"),
                body: ByteBuffer(data: manifest)
            )
            XCTAssertEqual(response.status.code, 409)
            self.assertSafeError(
                response,
                forbidden: [Self.archiveToken, tempDir.path, "corrupt envelope"]
            )
        }
    }

    func testReceiptDiscoveryUsesStrictBoundedDeterministicPagination() async throws {
        let app = Application(router: try makeRemoteApp().buildRouter())
        try await app.test(.router) { client in
            let machineA = "00000000-0000-4000-8000-000000000001"
            let machineB = "00000000-0000-4000-8000-000000000002"
            var expectedByMachine: [String: [String]] = [machineA: [], machineB: []]

            for (index, machineID) in [machineA, machineA, machineB].enumerated() {
                let (bytes, digest) = try Self.manifest(
                    raw: Data(),
                    machineID: machineID,
                    seed: "page-\(index)"
                )
                var response = try await client.execute(
                    uri: "/v2/archive/manifests/\(digest)",
                    method: .put,
                    headers: Self.headers(contentType: "application/json"),
                    body: ByteBuffer(data: bytes)
                )
                XCTAssertEqual(response.status.code, 201)
                response = try await client.execute(
                    uri: "/v2/archive/receipts/\(digest)",
                    method: .put,
                    headers: Self.headers()
                )
                XCTAssertEqual(response.status.code, 201)
                expectedByMachine[machineID, default: []].append(digest)
            }

            var response = try await client.execute(
                uri: "/v2/archive/machines?limit=1",
                method: .get,
                headers: Self.headers()
            )
            XCTAssertEqual(response.status.code, 200)
            let firstMachines = try ArchiveCanonicalJSON.decode(
                ArchiveMachinePage.self,
                from: Self.data(response)
            )
            XCTAssertEqual(firstMachines.machineIDs.count, 1)
            let machineCursor = try XCTUnwrap(firstMachines.nextCursor)

            response = try await client.execute(
                uri: "/v2/archive/machines?limit=1&cursor=\(machineCursor)",
                method: .get,
                headers: Self.headers()
            )
            let secondMachines = try ArchiveCanonicalJSON.decode(
                ArchiveMachinePage.self,
                from: Self.data(response)
            )
            XCTAssertEqual(firstMachines.machineIDs + secondMachines.machineIDs, [machineA, machineB])
            XCTAssertNil(secondMachines.nextCursor)

            response = try await client.execute(
                uri: "/v2/archive/receipts?machine_id=\(machineA)&limit=1",
                method: .get,
                headers: Self.headers()
            )
            XCTAssertEqual(response.status.code, 200)
            XCTAssertLessThanOrEqual(response.body.readableBytes, ArchiveV2ProtocolLimits.maxPageBytes)
            let firstReceipts = try ArchiveCanonicalJSON.decode(
                ArchiveReceiptPage.self,
                from: Self.data(response)
            )
            let receiptCursor = try XCTUnwrap(firstReceipts.nextCursor)

            response = try await client.execute(
                uri: "/v2/archive/receipts?machine_id=\(machineA)&limit=1&cursor=\(receiptCursor)",
                method: .get,
                headers: Self.headers()
            )
            let secondReceipts = try ArchiveCanonicalJSON.decode(
                ArchiveReceiptPage.self,
                from: Self.data(response)
            )
            let discovered = (firstReceipts.receipts + secondReceipts.receipts)
                .map(\.manifestSHA256)
            XCTAssertEqual(discovered, expectedByMachine[machineA]!.sorted())
            XCTAssertNil(secondReceipts.nextCursor)

            let malformedQueries = [
                "/v2/archive/machines?limit=1&limit=2",
                "/v2/archive/machines?cursor=bad!cursor",
                "/v2/archive/machines?limit=0",
                "/v2/archive/machines?limit=\(ArchiveV2ProtocolLimits.maxPageItems + 1)",
                "/v2/archive/machines?unexpected=1",
                "/v2/archive/receipts",
                "/v2/archive/receipts?machine_id=\(machineA)&machine_id=\(machineB)",
                "/v2/archive/receipts?machine_id=not-a-uuid",
                "/v2/archive/receipts?machine_id=\(machineA)&cursor=a&cursor=b",
            ]
            for uri in malformedQueries {
                response = try await client.execute(
                    uri: uri,
                    method: .get,
                    headers: Self.headers()
                )
                XCTAssertEqual(response.status.code, 400, uri)
            }
        }
    }

    func testWrongKeyRestartReturnsConflictWithoutOverwriteAndErrorsAreBoundedRedactedJSON() async throws {
        let raw = Data("wrong-key-protected".utf8)
        let digest = ArchiveV2Hash.sha256(raw)
        let (manifest, manifestDigest) = try Self.manifest(
            raw: raw,
            machineID: UUID().uuidString,
            seed: "wrong-key-receipt"
        )
        let writer = Application(router: try makeRemoteApp().buildRouter())
        try await writer.test(.router) { client in
            var response = try await client.execute(
                uri: "/v2/archive/objects/\(digest)",
                method: .put,
                headers: Self.headers(contentType: "application/octet-stream"),
                body: ByteBuffer(data: raw)
            )
            XCTAssertEqual(response.status.code, 201)
            response = try await client.execute(
                uri: "/v2/archive/manifests/\(manifestDigest)",
                method: .put,
                headers: Self.headers(contentType: "application/json"),
                body: ByteBuffer(data: manifest)
            )
            XCTAssertEqual(response.status.code, 201)
        }

        let wrongKey = Application(
            router: try makeRemoteApp(archiveKey: SymmetricKey(size: .bits256)).buildRouter()
        )
        try await wrongKey.test(.router) { client in
            // M14: HEAD is existence-only (no decrypt). Wrong at-rest key still
            // reports the object present so clients do not re-upload blindly.
            let headResponse = try await client.execute(
                uri: "/v2/archive/objects/\(digest)",
                method: .head,
                headers: Self.headers()
            )
            XCTAssertEqual(
                headResponse.status.code,
                200,
                "M14: HEAD must not decrypt; presence with wrong key is still 200"
            )

            // GET still decrypts and must fail closed on wrong key.
            let getResponse = try await client.execute(
                uri: "/v2/archive/objects/\(digest)",
                method: .get,
                headers: Self.headers()
            )
            XCTAssertEqual(getResponse.status.code, 409)
            self.assertSafeError(getResponse, forbidden: [Self.archiveToken, tempDir.path, "wrong-key-protected"])

            let response = try await client.execute(
                uri: "/v2/archive/objects/\(digest)",
                method: .put,
                headers: Self.headers(contentType: "application/octet-stream"),
                body: ByteBuffer(data: raw)
            )
            XCTAssertEqual(response.status.code, 409)
            self.assertSafeError(response, forbidden: [Self.archiveToken, tempDir.path, "wrong-key-protected"])

            let receiptResponse = try await client.execute(
                uri: "/v2/archive/receipts/\(manifestDigest)",
                method: .put,
                headers: Self.headers()
            )
            XCTAssertEqual(receiptResponse.status.code, 409)
            self.assertSafeError(receiptResponse, forbidden: [Self.archiveToken, tempDir.path])
        }

        let correctKeyRestart = Application(router: try makeRemoteApp().buildRouter())
        try await correctKeyRestart.test(.router) { client in
            let response = try await client.execute(
                uri: "/v2/archive/receipts/\(manifestDigest)",
                method: .get,
                headers: Self.headers()
            )
            XCTAssertEqual(response.status.code, 404, "wrong key must not mint receipt authority")
        }

        let app = Application(router: try makeRemoteApp().buildRouter())
        try await app.test(.router) { client in
            let secretPath = "invalid-\(Self.archiveToken)-digest"
            let response = try await client.execute(
                uri: "/v2/archive/objects/\(secretPath)",
                method: .get,
                headers: Self.headers()
            )
            XCTAssertEqual(response.status.code, 400)
            XCTAssertTrue(response.headers[.contentType]?.hasPrefix("application/json") == true)
            XCTAssertLessThanOrEqual(response.body.readableBytes, ArchiveV2ProtocolLimits.maxErrorBytes)
            let body = String(decoding: Self.data(response), as: UTF8.self)
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Self.data(response)))
            XCTAssertFalse(body.contains(Self.archiveToken))
            XCTAssertFalse(body.contains(secretPath))
            XCTAssertFalse(body.contains(tempDir.path))
        }
    }

    // MARK: - MCP Streamable HTTP endpoint (revision 2026-07-28, read-only)

    func testMCPEndpointNotMountedWhenDisabled() async throws {
        let app = Application(router: try makeRemoteApp().buildRouter())
        try await app.test(.router) { client in
            let response = try await client.execute(
                uri: "/mcp",
                method: .post,
                headers: Self.mcpHeaders(method: "server/discover"),
                body: try Self.mcpBody(method: "server/discover")
            )
            XCTAssertEqual(response.status.code, 404, "MCP must be invisible without EngramRemoteMCPConfig")

            let getResponse = try await client.execute(
                uri: "/mcp",
                method: .get,
                headers: Self.headers(token: Self.mcpToken)
            )
            XCTAssertEqual(getResponse.status.code, 404)
        }
    }

    func testMCPEndpointRequiresMCPBearerToken() async throws {
        let app = Application(router: try makeRemoteApp(mcpToken: Self.mcpToken).buildRouter())
        try await app.test(.router) { client in
            let rejected: [String?] = [nil, Self.legacyToken, Self.archiveToken, "not-a-token"]
            for token in rejected {
                let response = try await client.execute(
                    uri: "/mcp",
                    method: .post,
                    headers: Self.mcpHeaders(method: "server/discover", token: token),
                    body: try Self.mcpBody(method: "server/discover")
                )
                XCTAssertEqual(response.status.code, 401, "token \(token ?? "<absent>") was accepted")
                XCTAssertEqual(response.headers[.wwwAuthenticate], "Bearer")
            }

            let accepted = try await client.execute(
                uri: "/mcp",
                method: .post,
                headers: Self.mcpHeaders(method: "server/discover"),
                body: try Self.mcpBody(method: "server/discover")
            )
            XCTAssertEqual(accepted.status.code, 200)
        }
    }

    func testMCPGetRefusedWithMethodNotAllowed() async throws {
        let app = Application(router: try makeRemoteApp(mcpToken: Self.mcpToken).buildRouter())
        try await app.test(.router) { client in
            var response = try await client.execute(uri: "/mcp", method: .get)
            XCTAssertEqual(response.status.code, 401, "auth must precede the method refusal")
            XCTAssertEqual(response.headers[.wwwAuthenticate], "Bearer")

            response = try await client.execute(
                uri: "/mcp",
                method: .get,
                headers: Self.headers(token: Self.mcpToken)
            )
            XCTAssertEqual(response.status.code, 405, "the legacy GET stream is not served")
            XCTAssertEqual(response.headers[Self.allowHeader], "POST")
        }
    }

    func testMCPRejectsOriginHeader() async throws {
        let app = Application(router: try makeRemoteApp(mcpToken: Self.mcpToken).buildRouter())
        try await app.test(.router) { client in
            let response = try await client.execute(
                uri: "/mcp",
                method: .post,
                headers: Self.mcpHeaders(
                    method: "server/discover",
                    origin: "https://example.com"
                ),
                body: try Self.mcpBody(method: "server/discover")
            )
            XCTAssertEqual(response.status.code, 403)
            let message = try Self.mcpEnvelope(response)
            let id = try XCTUnwrap(message["id"])
            XCTAssertTrue(id is NSNull, "a refused request echoes a null id")
            let error = try XCTUnwrap(message["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? Int, -32600)
        }
    }

    func testMCPNotificationAccepted() async throws {
        let app = Application(router: try makeRemoteApp(mcpToken: Self.mcpToken).buildRouter())
        try await app.test(.router) { client in
            let response = try await client.execute(
                uri: "/mcp",
                method: .post,
                headers: Self.mcpHeaders(method: "tools/list"),
                body: try Self.mcpBody(method: "tools/list", id: nil)
            )
            XCTAssertEqual(response.status.code, 202)
            XCTAssertEqual(response.body.readableBytes, 0, "a notification gets no JSON-RPC response")
        }
    }

    func testMCPHeaderMismatchRejections() async throws {
        let app = Application(router: try makeRemoteApp(mcpToken: Self.mcpToken).buildRouter())
        try await app.test(.router) { client in
            let cases: [(label: String, headers: HTTPFields, body: ByteBuffer)] = [
                (
                    "missing MCP-Protocol-Version",
                    Self.mcpHeaders(method: "tools/list", protocolVersion: nil),
                    try Self.mcpBody(method: "tools/list")
                ),
                (
                    "header/body protocol version mismatch",
                    Self.mcpHeaders(method: "tools/list"),
                    try Self.mcpBody(method: "tools/list", metaVersion: "2026-01-01")
                ),
                (
                    "body missing _meta protocol version",
                    Self.mcpHeaders(method: "tools/list"),
                    try Self.mcpBody(method: "tools/list", metaVersion: nil)
                ),
                (
                    "Mcp-Method mismatch",
                    Self.mcpHeaders(method: "tools/list"),
                    try Self.mcpBody(method: "server/discover")
                ),
                (
                    "missing Mcp-Method",
                    Self.mcpHeaders(method: nil),
                    try Self.mcpBody(method: "tools/list")
                ),
                (
                    "tools/call missing Mcp-Name",
                    Self.mcpHeaders(method: "tools/call"),
                    try Self.mcpToolCallBody(name: "archive_list_machines")
                ),
                (
                    "tools/call Mcp-Name mismatch",
                    Self.mcpHeaders(method: "tools/call", name: "archive_get_session"),
                    try Self.mcpToolCallBody(name: "archive_list_machines")
                ),
            ]

            for entry in cases {
                let response = try await client.execute(
                    uri: "/mcp",
                    method: .post,
                    headers: entry.headers,
                    body: entry.body
                )
                XCTAssertEqual(response.status.code, 400, entry.label)
                let error = try Self.mcpError(response)
                XCTAssertEqual(error["code"] as? Int, -32020, entry.label)
                XCTAssertTrue(
                    (error["message"] as? String ?? "").hasPrefix("Header mismatch:"),
                    entry.label
                )
            }
        }
    }

    func testMCPNameHeaderBase64Sentinel() async throws {
        let app = Application(router: try makeRemoteApp(mcpToken: Self.mcpToken).buildRouter())
        try await app.test(.router) { client in
            let name = "archive_list_machines"
            let encoded = "=?base64?\(Data(name.utf8).base64EncodedString())?="
            let response = try await client.execute(
                uri: "/mcp",
                method: .post,
                headers: Self.mcpHeaders(method: "tools/call", name: encoded),
                body: try Self.mcpToolCallBody(name: name)
            )
            XCTAssertEqual(response.status.code, 200, "the base64 sentinel must decode to the body name")
            let result = try Self.mcpResult(response)
            XCTAssertNil(result["isError"])
            let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
            XCTAssertEqual(structured["machines"] as? [String], [])
        }
    }

    func testMCPUnsupportedVersionError() async throws {
        let app = Application(router: try makeRemoteApp(mcpToken: Self.mcpToken).buildRouter())
        try await app.test(.router) { client in
            let requested = "2999-01-01"
            let response = try await client.execute(
                uri: "/mcp",
                method: .post,
                headers: Self.mcpHeaders(method: "tools/list", protocolVersion: requested),
                body: try Self.mcpBody(method: "tools/list", metaVersion: requested)
            )
            XCTAssertEqual(response.status.code, 400)
            let error = try Self.mcpError(response)
            XCTAssertEqual(error["code"] as? Int, -32022)
            XCTAssertEqual(error["message"] as? String, "Unsupported protocol version")
            let errorData = try XCTUnwrap(error["data"] as? [String: Any])
            XCTAssertEqual(errorData["supported"] as? [String], [Self.mcpProtocolVersion])
            XCTAssertEqual(errorData["requested"] as? String, requested)
        }
    }

    func testMCPUnknownMethodIs404MethodNotFound() async throws {
        let app = Application(router: try makeRemoteApp(mcpToken: Self.mcpToken).buildRouter())
        try await app.test(.router) { client in
            // `initialize`/`ping` belong to the pre-2026-07-28 handshake and
            // `subscriptions/listen` opts into notifications this endpoint never
            // advertises: all are simply unknown methods here.
            for method in ["initialize", "ping", "subscriptions/listen", "resources/list"] {
                let response = try await client.execute(
                    uri: "/mcp",
                    method: .post,
                    headers: Self.mcpHeaders(method: method),
                    body: try Self.mcpBody(method: method)
                )
                XCTAssertEqual(response.status.code, 404, method)
                let error = try Self.mcpError(response)
                XCTAssertEqual(error["code"] as? Int, -32601, method)
                XCTAssertEqual(error["message"] as? String, "Method not found", method)
            }
        }
    }

    func testMCPServerDiscover() async throws {
        let app = Application(router: try makeRemoteApp(mcpToken: Self.mcpToken).buildRouter())
        try await app.test(.router) { client in
            let response = try await client.execute(
                uri: "/mcp",
                method: .post,
                headers: Self.mcpHeaders(method: "server/discover"),
                body: try Self.mcpBody(method: "server/discover", id: "discover-1")
            )
            XCTAssertEqual(response.status.code, 200)
            let message = try Self.mcpEnvelope(response)
            XCTAssertEqual(message["id"] as? String, "discover-1")

            let result = try Self.mcpResult(response)
            XCTAssertEqual(result["resultType"] as? String, "complete")
            XCTAssertEqual(result["supportedVersions"] as? [String], [Self.mcpProtocolVersion])
            let capabilities = try XCTUnwrap(result["capabilities"] as? [String: Any])
            XCTAssertNotNil(capabilities["tools"] as? [String: Any])
            XCTAssertFalse((result["instructions"] as? String ?? "").isEmpty)
            XCTAssertEqual(result["ttlMs"] as? Int, 3_600_000)
            XCTAssertEqual(result["cacheScope"] as? String, "private")
            let meta = try XCTUnwrap(result["_meta"] as? [String: Any])
            let serverInfo = try XCTUnwrap(
                meta["io.modelcontextprotocol/serverInfo"] as? [String: Any]
            )
            XCTAssertEqual(serverInfo["name"] as? String, "engram-remote")
            XCTAssertEqual(serverInfo["version"] as? String, "0.1.0")
        }
    }

    func testMCPToolsListShape() async throws {
        let app = Application(router: try makeRemoteApp(mcpToken: Self.mcpToken).buildRouter())
        try await app.test(.router) { client in
            let response = try await client.execute(
                uri: "/mcp",
                method: .post,
                headers: Self.mcpHeaders(method: "tools/list"),
                body: try Self.mcpBody(method: "tools/list")
            )
            XCTAssertEqual(response.status.code, 200)
            let result = try Self.mcpResult(response)
            XCTAssertEqual(result["resultType"] as? String, "complete")
            XCTAssertEqual(result["ttlMs"] as? Int, 3_600_000)
            XCTAssertEqual(result["cacheScope"] as? String, "private")
            XCTAssertNotNil(result["_meta"] as? [String: Any])

            let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
            XCTAssertEqual(
                tools.map { $0["name"] as? String },
                ["archive_list_machines", "archive_list_captures", "archive_get_session"]
            )
            for tool in tools {
                let name = tool["name"] as? String ?? "<unnamed>"
                XCTAssertFalse((tool["title"] as? String ?? "").isEmpty, name)
                XCTAssertFalse((tool["description"] as? String ?? "").isEmpty, name)
                let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any], name)
                XCTAssertEqual(schema["type"] as? String, "object", name)
                XCTAssertEqual(schema["additionalProperties"] as? Bool, false, name)
                XCTAssertNotNil(schema["properties"] as? [String: Any], name)
                let annotations = try XCTUnwrap(tool["annotations"] as? [String: Any], name)
                XCTAssertEqual(annotations["readOnlyHint"] as? Bool, true, name)
                XCTAssertEqual(annotations["openWorldHint"] as? Bool, false, name)
            }

            let machinesSchema = try XCTUnwrap(tools[0]["inputSchema"] as? [String: Any])
            let capturesSchema = try XCTUnwrap(tools[1]["inputSchema"] as? [String: Any])
            let sessionSchema = try XCTUnwrap(tools[2]["inputSchema"] as? [String: Any])
            XCTAssertNil(machinesSchema["required"], "archive_list_machines takes no required argument")
            XCTAssertEqual(capturesSchema["required"] as? [String], ["machine_id"])
            XCTAssertEqual(sessionSchema["required"] as? [String], ["manifest_sha256"])
        }
    }

    func testMCPArchiveToolsRoundTrip() async throws {
        let app = Application(router: try makeRemoteApp(mcpToken: Self.mcpToken).buildRouter())
        try await app.test(.router) { client in
            let machineID = "00000000-0000-4000-8000-000000000007"
            let raw = Data(String(repeating: "abcdefghij", count: 8).utf8)
            let rawDigest = ArchiveV2Hash.sha256(raw)
            let (manifestBytes, manifestDigest) = try Self.manifest(
                raw: raw,
                machineID: machineID,
                seed: "mcp-round-trip"
            )

            var response = try await client.execute(
                uri: "/v2/archive/objects/\(rawDigest)",
                method: .put,
                headers: Self.headers(contentType: "application/octet-stream"),
                body: ByteBuffer(data: raw)
            )
            XCTAssertEqual(response.status.code, 201)
            response = try await client.execute(
                uri: "/v2/archive/manifests/\(manifestDigest)",
                method: .put,
                headers: Self.headers(contentType: "application/json"),
                body: ByteBuffer(data: manifestBytes)
            )
            XCTAssertEqual(response.status.code, 201)
            response = try await client.execute(
                uri: "/v2/archive/receipts/\(manifestDigest)",
                method: .put,
                headers: Self.headers()
            )
            XCTAssertEqual(response.status.code, 201)

            response = try await client.execute(
                uri: "/mcp",
                method: .post,
                headers: Self.mcpHeaders(method: "tools/call", name: "archive_list_machines"),
                body: try Self.mcpToolCallBody(name: "archive_list_machines")
            )
            XCTAssertEqual(response.status.code, 200)
            var result = try Self.mcpResult(response)
            XCTAssertEqual(result["resultType"] as? String, "complete")
            XCTAssertNil(result["isError"])
            XCTAssertNil(result["ttlMs"], "tool results are not cacheable")
            XCTAssertNil(result["cacheScope"])
            XCTAssertNotNil(result["_meta"] as? [String: Any])
            var structured = try Self.mcpStructuredContent(response)
            XCTAssertEqual(structured["machines"] as? [String], [machineID])
            XCTAssertNil(structured["nextCursor"])

            response = try await client.execute(
                uri: "/mcp",
                method: .post,
                headers: Self.mcpHeaders(method: "tools/call", name: "archive_list_captures"),
                body: try Self.mcpToolCallBody(
                    name: "archive_list_captures",
                    arguments: ["machine_id": machineID]
                )
            )
            XCTAssertEqual(response.status.code, 200)
            structured = try Self.mcpStructuredContent(response)
            let captures = try XCTUnwrap(structured["captures"] as? [[String: Any]])
            XCTAssertEqual(captures.count, 1)
            XCTAssertEqual(captures[0]["manifestSHA256"] as? String, manifestDigest)
            XCTAssertEqual(captures[0]["sessionID"] as? String, "route-session")
            XCTAssertEqual(
                captures[0]["captureID"] as? String,
                ArchiveV2Hash.sha256(Data("capture-mcp-round-trip".utf8))
            )
            XCTAssertEqual(captures[0]["rawByteCount"] as? Int, raw.count)
            XCTAssertFalse((captures[0]["receiptSHA256"] as? String ?? "").isEmpty)
            XCTAssertFalse((captures[0]["storedAt"] as? String ?? "").isEmpty)
            XCTAssertNil(structured["nextCursor"])

            response = try await client.execute(
                uri: "/mcp",
                method: .post,
                headers: Self.mcpHeaders(method: "tools/call", name: "archive_get_session"),
                body: try Self.mcpToolCallBody(
                    name: "archive_get_session",
                    arguments: ["manifest_sha256": manifestDigest]
                )
            )
            XCTAssertEqual(response.status.code, 200)
            XCTAssertEqual(try Self.mcpContentText(response), String(decoding: raw, as: UTF8.self))
            structured = try Self.mcpStructuredContent(response)
            XCTAssertEqual(structured["sessionID"] as? String, "route-session")
            XCTAssertEqual(structured["source"] as? String, "codex")
            XCTAssertEqual(structured["machineID"] as? String, machineID)
            XCTAssertEqual(
                structured["locator"] as? String,
                "/private/route-test/mcp-round-trip.jsonl"
            )
            XCTAssertEqual(structured["capturedAt"] as? String, "2026-07-11T00:00:00.000Z")
            XCTAssertEqual(structured["totalBytes"] as? Int, raw.count)
            XCTAssertEqual(structured["offset"] as? Int, 0)
            XCTAssertEqual(structured["byteCount"] as? Int, raw.count)
            XCTAssertNil(structured["nextOffset"], "a complete read is not truncated")

            response = try await client.execute(
                uri: "/mcp",
                method: .post,
                headers: Self.mcpHeaders(method: "tools/call", name: "archive_get_session"),
                body: try Self.mcpToolCallBody(
                    name: "archive_get_session",
                    arguments: [
                        "manifest_sha256": manifestDigest,
                        "offset": 10,
                        "max_bytes": 20,
                    ]
                )
            )
            XCTAssertEqual(response.status.code, 200)
            XCTAssertEqual(try Self.mcpContentText(response), "abcdefghijabcdefghij")
            structured = try Self.mcpStructuredContent(response)
            XCTAssertEqual(structured["offset"] as? Int, 10)
            XCTAssertEqual(structured["byteCount"] as? Int, 20)
            XCTAssertEqual(structured["totalBytes"] as? Int, raw.count)
            XCTAssertEqual(structured["nextOffset"] as? Int, 30)

            response = try await client.execute(
                uri: "/mcp",
                method: .post,
                headers: Self.mcpHeaders(method: "tools/call", name: "archive_get_session"),
                body: try Self.mcpToolCallBody(
                    name: "archive_get_session",
                    arguments: [
                        "manifest_sha256": ArchiveV2Hash.sha256(Data("absent-manifest".utf8)),
                    ]
                )
            )
            XCTAssertEqual(response.status.code, 200, "tool failures stay JSON-RPC successes")
            result = try Self.mcpResult(response)
            XCTAssertEqual(result["isError"] as? Bool, true)
            structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
            XCTAssertEqual(structured["code"] as? String, "notFound")

            response = try await client.execute(
                uri: "/mcp",
                method: .post,
                headers: Self.mcpHeaders(method: "tools/call", name: "archive_list_machines"),
                body: try Self.mcpToolCallBody(
                    name: "archive_list_machines",
                    arguments: ["bogus": 1]
                )
            )
            XCTAssertEqual(response.status.code, 200)
            result = try Self.mcpResult(response)
            XCTAssertEqual(result["isError"] as? Bool, true)
            structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
            XCTAssertEqual(structured["code"] as? String, "invalidArguments")

            response = try await client.execute(
                uri: "/mcp",
                method: .post,
                headers: Self.mcpHeaders(method: "tools/call", name: "archive_unknown_tool"),
                body: try Self.mcpToolCallBody(name: "archive_unknown_tool")
            )
            XCTAssertEqual(response.status.code, 200)
            result = try Self.mcpResult(response)
            XCTAssertEqual(result["isError"] as? Bool, true)
            structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
            XCTAssertEqual(structured["code"] as? String, "unknownTool")
        }
    }

    private func archiveObjectURL(digest: String) -> URL {
        tempDir
            .appendingPathComponent("archive/objects/sha256", isDirectory: true)
            .appendingPathComponent(String(digest.prefix(2)), isDirectory: true)
            .appendingPathComponent(digest, isDirectory: false)
    }

    private func assertSafeError(
        _ response: TestResponse,
        forbidden: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            response.headers[.contentType]?.hasPrefix("application/json") == true,
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            response.body.readableBytes,
            ArchiveV2ProtocolLimits.maxErrorBytes,
            file: file,
            line: line
        )
        let body = Self.data(response)
        XCTAssertNoThrow(
            try JSONSerialization.jsonObject(with: body),
            file: file,
            line: line
        )
        let text = String(decoding: body, as: UTF8.self)
        for value in forbidden where !value.isEmpty {
            XCTAssertFalse(text.contains(value), "echoed forbidden value", file: file, line: line)
        }
    }

    private func makeRemoteApp(
        enabled: Bool = true,
        archiveKey overrideArchiveKey: SymmetricKey? = nil,
        sourceRevision: String = "unknown",
        mcpToken: String? = nil,
        telemetryNow: @escaping @Sendable () -> Date = { Date() },
        telemetrySnapshotWriter: @escaping ArchiveRemoteTelemetryStore.SnapshotWriter =
            { data, url in
                try ArchiveRemoteTelemetryStore.defaultSnapshotWriter(data, url)
            }
    ) throws -> EngramRemoteServerApp {
        let archive = enabled
            ? EngramRemoteArchiveConfig(
                serverID: "hq",
                root: tempDir.appendingPathComponent("archive", isDirectory: true),
                bearerToken: Self.archiveToken,
                atRestKey: overrideArchiveKey ?? archiveKey
            )
            : nil
        return try EngramRemoteServerApp(
            config: EngramRemoteServerConfig(
                host: "127.0.0.1",
                port: 0,
                storeRoot: tempDir.appendingPathComponent("legacy", isDirectory: true),
                bearerToken: Self.legacyToken,
                atRestKey: legacyKey,
                archiveV2: archive,
                mcp: mcpToken.map { EngramRemoteMCPConfig(bearerToken: $0) },
                sourceRevision: sourceRevision
            ),
            archiveTelemetryNow: telemetryNow,
            archiveTelemetrySnapshotWriter: telemetrySnapshotWriter
        )
    }

    private static func headers(
        contentType: String? = nil,
        contentLength: Int? = nil,
        token: String = archiveToken
    ) -> HTTPFields {
        var headers: HTTPFields = [.authorization: "Bearer \(token)"]
        if let contentType {
            headers[.contentType] = contentType
        }
        if let contentLength {
            headers[.contentLength] = "\(contentLength)"
        }
        return headers
    }

    /// Streamable HTTP request metadata for `/mcp`. `nil` omits the header so a
    /// test can exercise the endpoint's required-header rejections.
    private static func mcpHeaders(
        method: String?,
        name: String? = nil,
        token: String? = mcpToken,
        protocolVersion: String? = mcpProtocolVersion,
        origin: String? = nil
    ) -> HTTPFields {
        var headers = HTTPFields()
        if let token {
            headers[.authorization] = "Bearer \(token)"
        }
        headers[.contentType] = "application/json"
        if let protocolVersion {
            headers[mcpProtocolVersionHeader] = protocolVersion
        }
        if let method {
            headers[mcpMethodHeader] = method
        }
        if let name {
            headers[mcpNameHeader] = name
        }
        if let origin {
            headers[mcpOriginHeader] = origin
        }
        return headers
    }

    private static func mcpBody(
        method: String,
        id: Any? = 1,
        params: [String: Any] = [:],
        metaVersion: String? = mcpProtocolVersion
    ) throws -> ByteBuffer {
        var message: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let id {
            message["id"] = id
        }
        var params = params
        if let metaVersion {
            params["_meta"] = ["io.modelcontextprotocol/protocolVersion": metaVersion]
        }
        if !params.isEmpty {
            message["params"] = params
        }
        return ByteBuffer(data: try JSONSerialization.data(withJSONObject: message))
    }

    private static func mcpToolCallBody(
        name: String,
        arguments: [String: Any] = [:]
    ) throws -> ByteBuffer {
        try mcpBody(
            method: "tools/call",
            params: ["name": name, "arguments": arguments]
        )
    }

    private static func mcpEnvelope(_ response: TestResponse) throws -> [String: Any] {
        XCTAssertTrue(response.headers[.contentType]?.hasPrefix("application/json") == true)
        let object = try JSONSerialization.jsonObject(with: data(response))
        let message = try XCTUnwrap(object as? [String: Any])
        XCTAssertEqual(message["jsonrpc"] as? String, "2.0")
        return message
    }

    private static func mcpResult(_ response: TestResponse) throws -> [String: Any] {
        let message = try mcpEnvelope(response)
        XCTAssertNil(message["error"])
        return try XCTUnwrap(message["result"] as? [String: Any])
    }

    private static func mcpError(_ response: TestResponse) throws -> [String: Any] {
        let message = try mcpEnvelope(response)
        XCTAssertNil(message["result"])
        return try XCTUnwrap(message["error"] as? [String: Any])
    }

    private static func mcpStructuredContent(_ response: TestResponse) throws -> [String: Any] {
        let result = try mcpResult(response)
        return try XCTUnwrap(result["structuredContent"] as? [String: Any])
    }

    private static func mcpContentText(_ response: TestResponse) throws -> String {
        let result = try mcpResult(response)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "text")
        return try XCTUnwrap(content.first?["text"] as? String)
    }

    private static func instant(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return try XCTUnwrap(formatter.date(from: value))
    }

    private static func data(_ response: TestResponse) -> Data {
        Data(response.body.readableBytesView)
    }

    private static func manifest(
        raw: Data,
        machineID: String,
        seed: String,
        sessionID: String? = "route-session"
    ) throws -> (Data, String) {
        let chunks: [ArchiveChunkReference]
        if raw.isEmpty {
            chunks = []
        } else {
            chunks = [
                try ArchiveChunkReference(
                    ordinal: 0,
                    rawSHA256: ArchiveV2Hash.sha256(raw),
                    rawByteCount: Int64(raw.count)
                )
            ]
        }
        let manifest = try ArchiveSourceManifest(
            captureID: ArchiveV2Hash.sha256(Data("capture-\(seed)".utf8)),
            machineID: machineID,
            source: "codex",
            locator: "/private/route-test/\(seed).jsonl",
            sessionID: sessionID,
            capturedAt: "2026-07-11T00:00:00.000Z",
            generation: try ArchiveSourceGeneration(
                device: 1,
                inode: Int64(seed.utf8.reduce(UInt64(0)) { $0 + UInt64($1) }),
                size: Int64(raw.count),
                mtimeNs: 1,
                ctimeNs: 1,
                mode: 0o100600
            ),
            wholeSourceSHA256: ArchiveV2Hash.sha256(raw),
            rawByteCount: Int64(raw.count),
            chunks: chunks,
            replayLayout: try ArchiveReplayLayout(
                strategy: .singleFile,
                relativePaths: ["route-test/\(seed).jsonl"]
            )
        )
        let bytes = try ArchiveCanonicalJSON.encode(manifest)
        return (bytes, ArchiveV2Hash.sha256(bytes))
    }
}
