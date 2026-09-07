import CryptoKit
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import XCTest

@testable import EngramRemoteServerCore

final class ArchivePublicationRouteTests: XCTestCase {
    private static let token = "publication-route-test-token"
    private static let serverID = "hq"
    private static let digest = String(repeating: "a", count: 64)
    private static let machineID = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    private var tempDir: URL!
    private var key: SymmetricKey!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-publication-routes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        key = SymmetricKey(size: .bits256)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    func testEveryPublicationRouteAuthenticatesBeforeValidatingInput() async throws {
        let fixture = try makeRouter()
        let app = Application(router: fixture.router)
        let routes: [(HTTPRequest.Method, String)] = [
            (.get, "/v2/archive/publication-capabilities"),
            (.put, "/v2/archive/publications/not-a-digest"),
            (.get, "/v2/archive/publications/not-a-digest"),
            (.get, "/v2/archive/publications?limit=0"),
            (.delete, "/v2/archive/publications/\(Self.digest)"),
            (.delete, "/v2/archive/publications"),
            (.delete, "/v2/archive/publication-capabilities"),
        ]
        try await app.test(.router) { client in
            for token in [nil, "legacy-route-test-token", "mcp-route-test-token"] as [String?] {
                for (method, uri) in routes {
                    let response = try await client.execute(
                        uri: uri,
                        method: method,
                        headers: token.map { Self.headers(token: $0) } ?? HTTPFields()
                    )
                    try assertError(response, status: 401, code: "unauthorized")
                    XCTAssertEqual(response.headers[.wwwAuthenticate], "Bearer")
                }
            }
        }
    }

    func testCapabilitiesAreStaticWhilePublicationIndexIsCold() async throws {
        let fixture = try makeRouter()
        let app = Application(router: fixture.router)
        try await app.test(.router) { client in
            let response = try await client.execute(
                uri: "/v2/archive/publication-capabilities",
                method: .get,
                headers: Self.headers()
            )
            XCTAssertEqual(response.status.code, 200)
            guard response.status.code == 200 else { return }
            let fields = try Self.object(response)
            XCTAssertEqual(fields["schemaVersion"] as? Int, 1)
            XCTAssertEqual(fields["serverID"] as? String, Self.serverID)
            XCTAssertEqual(fields["publicationSchemaVersions"] as? [Int], [1])
            XCTAssertEqual(fields["representations"] as? [String], ["exact-source-v1"])
            XCTAssertEqual(fields["maxPublicationBytes"] as? Int, 2048)
            XCTAssertEqual(fields["maxAcceptanceRecordBytes"] as? Int, 4096)
            XCTAssertEqual(fields["maxPageBytes"] as? Int, 262144)
            XCTAssertEqual(fields["defaultPageLimit"] as? Int, 50)
            XCTAssertEqual(fields["maxPageItems"] as? Int, 100)
            XCTAssertEqual(fields["maxCursorBytes"] as? Int, 256)
            XCTAssertEqual(fields.count, 10, "capability discovery must not imply readiness or expose config")
            let text = String(decoding: response.body.readableBytesView, as: UTF8.self)
            XCTAssertFalse(text.contains(Self.token))
            XCTAssertFalse(text.contains(tempDir.path))
        }
    }

    func testPublicationPutRejectsWrongContentTypeAndOversizedBody() async throws {
        let fixture = try makeRouter()
        let app = Application(router: fixture.router)
        try await app.test(.router) { client in
            for contentType in [nil, "text/plain", "application/octet-stream"] as [String?] {
                let response = try await client.execute(
                    uri: "/v2/archive/publications/\(Self.digest)",
                    method: .put,
                    headers: Self.headers(contentType: contentType),
                    body: ByteBuffer(string: "{}")
                )
                try assertError(response, status: 415, code: "unsupported_media_type")
            }
            let atLimit = try await client.execute(
                uri: "/v2/archive/publications/\(Self.digest)",
                method: .put,
                headers: Self.headers(contentType: "application/json; charset=utf-8"),
                body: ByteBuffer(bytes: [UInt8](repeating: 32, count: 2048))
            )
            try assertError(atLimit, status: 400, code: "malformed_request")
            let response = try await client.execute(
                uri: "/v2/archive/publications/\(Self.digest)",
                method: .put,
                headers: Self.headers(contentType: "application/json"),
                body: ByteBuffer(bytes: [UInt8](repeating: 32, count: 2049))
            )
            try assertError(response, status: 413, code: "payload_too_large")
        }
    }

    func testPublicationPutRejectsNoncanonicalEnvelopeAndBodyDigestMismatch() async throws {
        let fixture = try makeRouter()
        let app = Application(router: fixture.router)
        let canonical = try ArchiveCanonicalJSON.encode(Self.publication())
        var unknown = try XCTUnwrap(JSONSerialization.jsonObject(with: canonical) as? [String: Any])
        unknown["unexpected"] = true
        var unsupported = unknown
        unsupported.removeValue(forKey: "unexpected")
        unsupported["representation"] = "unproved-derived-v1"
        let invalidBodies = [
            Data("{}".utf8), canonical + Data("\n".utf8),
            try JSONSerialization.data(withJSONObject: unknown, options: [.sortedKeys, .withoutEscapingSlashes]),
            try JSONSerialization.data(withJSONObject: unsupported, options: [.sortedKeys, .withoutEscapingSlashes]),
        ]
        try await app.test(.router) { client in
            for body in invalidBodies {
                let response = try await client.execute(
                    uri: "/v2/archive/publications/\(ArchiveV2Hash.sha256(body))",
                    method: .put,
                    headers: Self.headers(contentType: "application/json"),
                    body: ByteBuffer(data: body)
                )
                try assertError(response, status: 400, code: "malformed_request")
            }
            let response = try await client.execute(
                uri: "/v2/archive/publications/\(Self.digest)",
                method: .put,
                headers: Self.headers(contentType: "application/json"),
                body: ByteBuffer(data: canonical)
            )
            try assertError(response, status: 400, code: "malformed_request")
        }
    }

    func testRealAppDefaultsPublicationRoutesOffAndPreservesLegacyDelete() async throws {
        let remote = try makeRemoteApp()
        let archiveRoot = tempDir.appendingPathComponent("app-archive")
        let before = try FileManager.default.subpathsOfDirectory(atPath: archiveRoot.path)
        XCTAssertFalse(before.contains { $0.contains("publication") })
        let app = Application(router: remote.buildRouter())
        try await app.test(.router) { client in
            for (method, uri) in [
                (HTTPRequest.Method.get, "/v2/archive/publication-capabilities"),
                (.get, "/v2/archive/publications"),
                (.get, "/v2/archive/publications/\(Self.digest)"),
                (.put, "/v2/archive/publications/\(Self.digest)"),
            ] {
                let response = try await client.execute(uri: uri, method: method, headers: Self.headers())
                XCTAssertEqual(response.status.code, 404)
            }
            let denied = try await client.execute(uri: "/v2/archive/publications", method: .delete)
            try assertError(denied, status: 401, code: "unauthorized")
            let noDelete = try await client.execute(
                uri: "/v2/archive/publications/\(Self.digest)", method: .delete, headers: Self.headers()
            )
            try assertError(noDelete, status: 405, code: "method_not_allowed")
            let legacy = try await client.execute(uri: "/v1/health", method: .get)
            XCTAssertEqual(legacy.status.code, 200)
        }
        let after = try FileManager.default.subpathsOfDirectory(atPath: archiveRoot.path)
        XCTAssertFalse(after.contains { $0.contains("publication") }, "disabled requests must not create a journal or lock")
    }

    func testRealAppMountsEnabledCapabilitiesButColdIntakeRemainsUnavailable() async throws {
        let remote = try makeRemoteApp(publicationsEnabled: true)
        let app = Application(router: remote.buildRouter())
        let publication = try ArchiveCanonicalJSON.encode(Self.publication())
        let digest = ArchiveV2Hash.sha256(publication)
        try await app.test(.router) { client in
            var originHeaders = Self.headers()
            originHeaders[HTTPField.Name("Origin")!] = "https://untrusted.example"
            let capabilities = try await client.execute(
                uri: "/v2/archive/publication-capabilities", method: .get, headers: originHeaders
            )
            XCTAssertEqual(capabilities.status.code, 200, "existing archive Origin behavior must remain unchanged")
            XCTAssertNil(capabilities.headers[HTTPField.Name("Access-Control-Allow-Origin")!])
            for uri in ["/v2/archive/publications", "/v2/archive/publications/\(digest)"] {
                let response = try await client.execute(uri: uri, method: .get, headers: Self.headers())
                try assertError(response, status: 503, code: "storage_unavailable")
            }
            let put = try await client.execute(
                uri: "/v2/archive/publications/\(digest)", method: .put,
                headers: Self.headers(contentType: "application/json"), body: ByteBuffer(data: publication)
            )
            try assertError(put, status: 503, code: "storage_unavailable")
            let legacy = try await client.execute(
                uri: "/v2/archive/objects/\(Self.digest)", method: .get, headers: Self.headers()
            )
            XCTAssertEqual(legacy.status.code, 404, "cold publication state must not disable old archive reads")
        }
    }

    func testPublicationStoreFailuresUseOnlyFrozenSafeErrorCodes() async throws {
        let cases: [(ArchivePublicationStoreError, Int, String)] = [
            (.sequenceConflict, 409, "sequence_conflict"),
            (.cursorJournalMismatch, 409, "cursor_journal_mismatch"),
            (.cursorAheadOfTail, 409, "cursor_ahead_of_tail"),
            (.invalidPublication, 422, "invalid_content"),
            (.unavailable, 503, "storage_unavailable"),
            (.ordinalOverflow, 503, "storage_unavailable"),
        ]
        let router = Router<BasicRequestContext>()
        for (index, entry) in cases.enumerated() {
            let error = entry.0
            router.get(RouterPath("/error-\(index)")) { _, _ in
                ArchivePublicationRoutes.storeErrorResponse(error)
            }
        }
        try await Application(router: router).test(.router) { client in
            for (index, entry) in cases.enumerated() {
                let response = try await client.execute(uri: "/error-\(index)", method: .get)
                try assertError(response, status: entry.1, code: entry.2)
            }
        }
    }

    func testPublicationRoutesRejectMalformedDigestAndQueryBeforeStorage() async throws {
        let fixture = try makeRouter()
        let app = Application(router: fixture.router)
        try await app.test(.router) { client in
            for method in [HTTPRequest.Method.get, .put] {
                let response = try await client.execute(
                    uri: "/v2/archive/publications/NOT-a-sha256",
                    method: method,
                    headers: Self.headers(contentType: "application/json")
                )
                try assertError(response, status: 400, code: "malformed_request")
            }
            for query in [
                "limit=0", "limit=-1", "limit=101", "limit=01", "limit=",
                "limit=1&limit=2", "unknown=1", "cursor=", "cursor=one&cursor=two",
                "cursor=not_base64", "cursor=" + String(repeating: "a", count: 257),
            ] {
                let response = try await client.execute(
                    uri: "/v2/archive/publications?\(query)",
                    method: .get,
                    headers: Self.headers()
                )
                try assertError(response, status: 400, code: "malformed_request")
            }
        }
    }

    func testPublicationDeleteNeverCreatesDeletionAuthority() async throws {
        let fixture = try makeRouter()
        let app = Application(router: fixture.router)
        try await app.test(.router) { client in
            for uri in [
                "/v2/archive/publication-capabilities",
                "/v2/archive/publications",
                "/v2/archive/publications/\(Self.digest)",
            ] {
                let response = try await client.execute(
                    uri: uri,
                    method: .delete,
                    headers: Self.headers()
                )
                try assertError(response, status: 405, code: "method_not_allowed")
            }
        }
    }

    func testAcceptedPublicationReturnsStableACKAndDoesNotCreateLegacyReceipt() async throws {
        let fixture = try makeRouter()
        let manifest = try seedManifest(in: fixture.store, seed: "accepted")
        let publication = try Self.publication(manifestDigest: manifest)
        let body = try ArchiveCanonicalJSON.encode(publication)
        let digest = ArchiveV2Hash.sha256(body)
        try fixture.store.warmPublicationIndex()
        let app = Application(router: fixture.router)

        try await app.test(.router) { client in
            let created = try await client.execute(
                uri: "/v2/archive/publications/\(digest)", method: .put,
                headers: Self.headers(contentType: "application/json"), body: ByteBuffer(data: body)
            )
            XCTAssertEqual(created.status.code, 201)
            guard created.status.code == 201 else { return }
            let ack = try Self.decode(CollectorPublicationACK.self, created)
            try ack.validate(against: publication, expectedServerID: Self.serverID)
            XCTAssertEqual(ack.arrivalOrdinal, 1)

            let retry = try await client.execute(
                uri: "/v2/archive/publications/\(digest)", method: .put,
                headers: Self.headers(contentType: "application/json; charset=utf-8"), body: ByteBuffer(data: body)
            )
            XCTAssertEqual(retry.status.code, 200)
            XCTAssertEqual(Data(retry.body.readableBytesView), Data(created.body.readableBytesView))

            let read = try await client.execute(
                uri: "/v2/archive/publications/\(digest)", method: .get, headers: Self.headers()
            )
            XCTAssertEqual(read.status.code, 200)
            guard read.status.code == 200 else { return }
            XCTAssertLessThanOrEqual(read.body.readableBytes, 4096)
            let record = try Self.decode(CollectorPublicationAcceptanceRecord.self, read)
            XCTAssertEqual(record.publication, publication)
            XCTAssertEqual(record.ack, ack)

            let missing = try await client.execute(
                uri: "/v2/archive/publications/\(Self.digest)", method: .get, headers: Self.headers()
            )
            try assertError(missing, status: 404, code: "not_found")
        }
        XCTAssertThrowsError(try fixture.store.getReceipt(manifestDigest: manifest)) { error in
            XCTAssertEqual(error as? ArchiveStoreError, .notFound, "a capture ACK must never become a legacy session receipt")
        }
    }

    func testArrivalCursorRemainsReusableAtEOFAfterALowerDigestArrives() async throws {
        let fixture = try makeRouter()
        let publications = try ["first", "second"].enumerated().map { index, seed in
            try Self.publication(
                manifestDigest: seedManifest(in: fixture.store, seed: seed),
                sequence: Int64(index + 1)
            )
        }
        let candidates = try publications.map { publication -> (publication: CollectorPublicationEnvelope, body: Data, digest: String) in
            let body = try ArchiveCanonicalJSON.encode(publication)
            return (publication, body, ArchiveV2Hash.sha256(body))
        }.sorted { $0.digest > $1.digest }
        let first = candidates[0]
        let second = candidates[1]
        XCTAssertGreaterThan(first.digest, second.digest)
        try fixture.store.warmPublicationIndex()
        let app = Application(router: fixture.router)

        try await app.test(.router) { client in
            let emptyResponse = try await client.execute(
                uri: "/v2/archive/publications", method: .get, headers: Self.headers()
            )
            XCTAssertEqual(emptyResponse.status.code, 200)
            guard emptyResponse.status.code == 200 else { return }
            let initial = try Self.decode(CollectorPublicationPage.self, emptyResponse)
            try initial.validate(after: nil, expectedServerID: Self.serverID)
            XCTAssertTrue(initial.items.isEmpty)
            XCTAssertFalse(initial.hasMore)
            let initialCursor = try CollectorPublicationCursor.decode(initial.afterCursor)

            let created = try await client.execute(
                uri: "/v2/archive/publications/\(first.digest)", method: .put,
                headers: Self.headers(contentType: "application/json"), body: ByteBuffer(data: first.body)
            )
            XCTAssertEqual(created.status.code, 201)
            let firstResponse = try await client.execute(
                uri: "/v2/archive/publications?cursor=\(initial.afterCursor)&limit=1",
                method: .get, headers: Self.headers()
            )
            XCTAssertEqual(firstResponse.status.code, 200)
            guard firstResponse.status.code == 200 else { return }
            let firstPage = try Self.decode(CollectorPublicationPage.self, firstResponse)
            try firstPage.validate(after: initialCursor, expectedServerID: Self.serverID)
            XCTAssertEqual(firstPage.items.map(\.ack.publicationSHA256), [first.digest])
            XCTAssertFalse(firstPage.hasMore)

            let eofResponse = try await client.execute(
                uri: "/v2/archive/publications?cursor=\(firstPage.afterCursor)", method: .get, headers: Self.headers()
            )
            let eof = try Self.decode(CollectorPublicationPage.self, eofResponse)
            let firstCursor = try CollectorPublicationCursor.decode(firstPage.afterCursor)
            try eof.validate(after: firstCursor, expectedServerID: Self.serverID)
            XCTAssertTrue(eof.items.isEmpty)
            XCTAssertEqual(eof.afterCursor, firstPage.afterCursor)

            let later = try await client.execute(
                uri: "/v2/archive/publications/\(second.digest)", method: .put,
                headers: Self.headers(contentType: "application/json"), body: ByteBuffer(data: second.body)
            )
            XCTAssertEqual(later.status.code, 201)
            let laterResponse = try await client.execute(
                uri: "/v2/archive/publications?cursor=\(eof.afterCursor)", method: .get, headers: Self.headers()
            )
            let laterPage = try Self.decode(CollectorPublicationPage.self, laterResponse)
            try laterPage.validate(after: firstCursor, expectedServerID: Self.serverID)
            XCTAssertEqual(laterPage.items.map(\.ack.publicationSHA256), [second.digest])
            XCTAssertEqual(laterPage.items.map(\.ack.arrivalOrdinal), [2])
            XCTAssertLessThanOrEqual(laterResponse.body.readableBytes, 262144)

            let boundedResponse = try await client.execute(
                uri: "/v2/archive/publications?limit=1", method: .get, headers: Self.headers()
            )
            let bounded = try Self.decode(CollectorPublicationPage.self, boundedResponse)
            XCTAssertEqual(bounded.items.map(\.ack.publicationSHA256), [first.digest])
            XCTAssertTrue(bounded.hasMore)
        }
    }

    func testSequenceAndCursorConflictsHaveDistinctSafeResponses() async throws {
        let fixture = try makeRouter()
        let original = try Self.publication(manifestDigest: seedManifest(in: fixture.store, seed: "original"))
        let conflicting = try Self.publication(manifestDigest: seedManifest(in: fixture.store, seed: "conflicting"))
        let originalBody = try ArchiveCanonicalJSON.encode(original)
        let conflictingBody = try ArchiveCanonicalJSON.encode(conflicting)
        try fixture.store.warmPublicationIndex()
        let app = Application(router: fixture.router)

        try await app.test(.router) { client in
            let created = try await client.execute(
                uri: "/v2/archive/publications/\(ArchiveV2Hash.sha256(originalBody))", method: .put,
                headers: Self.headers(contentType: "application/json"), body: ByteBuffer(data: originalBody)
            )
            XCTAssertEqual(created.status.code, 201)
            guard created.status.code == 201 else { return }
            let ack = try Self.decode(CollectorPublicationACK.self, created)
            let conflict = try await client.execute(
                uri: "/v2/archive/publications/\(ArchiveV2Hash.sha256(conflictingBody))", method: .put,
                headers: Self.headers(contentType: "application/json"), body: ByteBuffer(data: conflictingBody)
            )
            try assertError(conflict, status: 409, code: "sequence_conflict")

            let otherJournal = try CollectorPublicationCursor(journalID: UUID().uuidString, afterArrivalOrdinal: 0).encoded()
            let wrongJournal = try await client.execute(
                uri: "/v2/archive/publications?cursor=\(otherJournal)", method: .get, headers: Self.headers()
            )
            try assertError(wrongJournal, status: 409, code: "cursor_journal_mismatch")
            let ahead = try CollectorPublicationCursor(journalID: ack.journalID, afterArrivalOrdinal: Int64.max).encoded()
            let aheadResponse = try await client.execute(
                uri: "/v2/archive/publications?cursor=\(ahead)", method: .get, headers: Self.headers()
            )
            try assertError(aheadResponse, status: 409, code: "cursor_ahead_of_tail")
        }
    }

    func testPublicationReferenceProofFailureDoesNotReturnAnACK() async throws {
        let fixture = try makeRouter()
        let missing = try Self.publication()
        let bound = try Self.publication(
            manifestDigest: seedManifest(in: fixture.store, seed: "bound", sessionID: "legacy-session"), sequence: 2
        )
        let wrongMachine = try Self.publication(
            manifestDigest: seedManifest(
                in: fixture.store, seed: "wrong-machine", machineID: "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD"
            ), sequence: 3
        )
        try fixture.store.warmPublicationIndex()
        let app = Application(router: fixture.router)
        try await app.test(.router) { client in
            for publication in [missing, bound, wrongMachine] {
                let body = try ArchiveCanonicalJSON.encode(publication)
                let response = try await client.execute(
                    uri: "/v2/archive/publications/\(ArchiveV2Hash.sha256(body))", method: .put,
                    headers: Self.headers(contentType: "application/json"), body: ByteBuffer(data: body)
                )
                try assertError(response, status: 422, code: "invalid_content")
            }
            let response = try await client.execute(uri: "/v2/archive/publications", method: .get, headers: Self.headers())
            let page = try Self.decode(CollectorPublicationPage.self, response)
            XCTAssertTrue(page.items.isEmpty, "failed proof must not become discoverable acceptance")
        }
    }

    private func makeRouter() throws -> (router: Router<BasicRequestContext>, store: ArchiveStore) {
        let store = try ArchiveStore(
            root: tempDir.appendingPathComponent("archive"), key: key, serverID: Self.serverID,
            now: { "2026-09-05T00:00:00.000Z" },
            publicationsEnabled: true
        )
        let router = Router<BasicRequestContext>()
        // Match the real App's mount order, including the existing no-delete guard.
        ArchiveRoutes.mount(on: router, store: store, token: Self.token)
        ArchivePublicationRoutes.mount(on: router, store: store, token: Self.token, serverID: Self.serverID)
        return (router, store)
    }

    private func seedManifest(
        in store: ArchiveStore,
        seed: String,
        sessionID: String? = nil,
        machineID: String = ArchivePublicationRouteTests.machineID
    ) throws -> String {
        let raw = Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(seed)\",\"cwd\":\"/private/publication-fixture\"}}\n".utf8)
        let chunk = try ArchiveChunkReference(ordinal: 0, rawSHA256: ArchiveV2Hash.sha256(raw), rawByteCount: Int64(raw.count))
        _ = try store.putObject(digest: chunk.rawSHA256, raw: raw)
        let manifest = try ArchiveSourceManifest(
            captureID: ArchiveV2Hash.sha256(Data("capture-\(seed)".utf8)),
            machineID: machineID,
            source: "codex",
            locator: "/private/publication-fixture/\(seed).jsonl",
            sessionID: sessionID,
            capturedAt: "2026-09-05T00:00:00.000Z",
            generation: try ArchiveSourceGeneration(
                device: 1, inode: 1, size: Int64(raw.count), mtimeNs: 1, ctimeNs: 1, mode: 0o100600
            ),
            wholeSourceSHA256: chunk.rawSHA256,
            rawByteCount: Int64(raw.count),
            chunks: [chunk],
            replayLayout: try ArchiveReplayLayout(strategy: .singleFile, relativePaths: ["codex/\(seed).jsonl"])
        )
        let bytes = try ArchiveCanonicalJSON.encode(manifest)
        let digest = ArchiveV2Hash.sha256(bytes)
        _ = try store.putManifest(digest: digest, canonicalBytes: bytes)
        return digest
    }

    private func makeRemoteApp(publicationsEnabled: Bool? = nil) throws -> EngramRemoteServerApp {
        var archive = EngramRemoteArchiveConfig(
            serverID: Self.serverID,
            root: tempDir.appendingPathComponent("app-archive"),
            bearerToken: Self.token,
            atRestKey: key
        )
        if let publicationsEnabled {
            archive = EngramRemoteArchiveConfig(
                serverID: Self.serverID,
                root: tempDir.appendingPathComponent("app-archive"),
                bearerToken: Self.token,
                atRestKey: key,
                publicationsEnabled: publicationsEnabled
            )
        }
        return try EngramRemoteServerApp(config: EngramRemoteServerConfig(
            host: "127.0.0.1", port: 0,
            storeRoot: tempDir.appendingPathComponent("legacy"),
            bearerToken: "legacy-publication-route-token",
            atRestKey: SymmetricKey(size: .bits256),
            archiveV2: archive
        ))
    }

    private static func publication(
        manifestDigest: String = ArchivePublicationRouteTests.digest,
        sequence: Int64 = 1
    ) throws -> CollectorPublicationEnvelope {
        try CollectorPublicationEnvelope(
            machineID: machineID,
            sourceInstanceID: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB",
            collectorEpoch: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC",
            sequence: sequence,
            manifestSHA256: manifestDigest
        )
    }

    private static func headers(
        contentType: String? = nil,
        token: String = ArchivePublicationRouteTests.token
    ) -> HTTPFields {
        var headers: HTTPFields = [.authorization: "Bearer \(token)"]
        if let contentType { headers[.contentType] = contentType }
        return headers
    }

    private static func object(_ response: TestResponse) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any])
    }

    private static func decode<T: Codable>(_ type: T.Type, _ response: TestResponse) throws -> T {
        XCTAssertEqual(response.headers[.contentType], "application/json; charset=utf-8")
        XCTAssertEqual(response.headers[.contentLength], String(response.body.readableBytes))
        return try ArchiveCanonicalJSON.decode(type, from: Data(response.body.readableBytesView))
    }

    private func assertError(
        _ response: TestResponse,
        status: Int,
        code: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(response.status.code, status, file: file, line: line)
        XCTAssertEqual(response.headers[.contentType], "application/json; charset=utf-8", file: file, line: line)
        XCTAssertLessThanOrEqual(response.body.readableBytes, 4096, file: file, line: line)
        guard let fields = (try? JSONSerialization.jsonObject(
            with: Data(response.body.readableBytesView)
        )) as? [String: Any] else {
            XCTFail("expected a JSON error object", file: file, line: line)
            return
        }
        XCTAssertEqual(Set(fields.keys), ["error"], file: file, line: line)
        XCTAssertEqual(fields["error"] as? String, code, file: file, line: line)
        let text = String(decoding: response.body.readableBytesView, as: UTF8.self)
        XCTAssertFalse(text.contains(Self.token), file: file, line: line)
        XCTAssertFalse(text.contains(tempDir.path), file: file, line: line)
    }
}
