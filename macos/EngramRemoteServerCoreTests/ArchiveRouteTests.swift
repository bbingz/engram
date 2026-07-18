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
    private static let sourceRevision = String(repeating: "a", count: 40)

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
