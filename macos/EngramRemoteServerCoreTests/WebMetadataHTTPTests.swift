import CryptoKit
import Darwin
import Foundation
@testable import EngramRemoteServerCore
import XCTest

/// Loopback HTTP draft for typed metadata GET routes.
///
/// Metadata handlers stay unmounted, so 200/400/502/503 contracts are executable
/// RED. Recorders, not an unrelated Unix-socket accept count, prove whether a
/// reader ran. `makeSurface` round-trips are the positive IPC/DTO proof. This is
/// not a Service metadata producer or full-transcript proof.
final class WebMetadataHTTPTests: XCTestCase {
    private static let viewer = "a5b-test-viewer"
    private static let origin = "http://127.0.0.1:8787"
    private static let snapshot = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    private static let machine = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
    private static let instance = "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("engram-a5b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    private var socketPath: String { directory.appendingPathComponent("service.sock").path }

    func testOverviewDefaultQueryReturnsTypedDTO() async throws {
        let fixture = try fixture()
        defer { fixture.stop() }
        let recorders = A5bRouteRecorders()
        try await withServer(surface: recordingSurface(recorders: recorders)) { server in
            let cookie = try await Self.login(server)
            let response = try await server.request("GET", "/web/api/overview", headers: Self.originHeaders + [("Cookie", cookie)])
            XCTAssertEqual(response.status, 200)
            Self.assertSecurityHeaders(response)
            XCTAssertTrue(response.header("content-type")?.hasPrefix("application/json") == true)
            let body: EngramServiceWebOverviewResponse = try JSONDecoder().decode(EngramServiceWebOverviewResponse.self, from: response.body)
            XCTAssertEqual(body.snapshotId, Self.snapshot)
            XCTAssertEqual(body.streams.count, 1)
            XCTAssertEqual(body.streams[0].machineId, Self.machine)
        }
        XCTAssertEqual(recorders.overview.values.map(\.limit), [50])
        XCTAssertEqual(recorders.overview.values.map(\.snapshotId), [nil])
        XCTAssertEqual(recorders.overview.values.map(\.cursor), [nil])
        XCTAssertTrue(recorders.sessions.values.isEmpty)
        XCTAssertTrue(recorders.detail.values.isEmpty)
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testOverviewContinuationPassesSnapshotIdAndCursor() async throws {
        let fixture = try fixture()
        defer { fixture.stop() }
        let recorders = A5bRouteRecorders()
        try await withServer(surface: recordingSurface(recorders: recorders)) { server in
            let cookie = try await Self.login(server)
            let path = "/web/api/overview?limit=2&snapshotId=\(Self.snapshot)&cursor=next"
            let response = try await server.request("GET", path, headers: Self.originHeaders + [("Cookie", cookie)])
            XCTAssertEqual(response.status, 200)
            let body: EngramServiceWebOverviewResponse = try JSONDecoder().decode(EngramServiceWebOverviewResponse.self, from: response.body)
            XCTAssertEqual(body.snapshotId, Self.snapshot)
            XCTAssertEqual(body.nextCursor, "after")
        }
        XCTAssertEqual(recorders.overview.values.map(\.limit), [2])
        XCTAssertEqual(recorders.overview.values.map(\.snapshotId), [Self.snapshot])
        XCTAssertEqual(recorders.overview.values.map(\.cursor), ["next"])
        XCTAssertTrue(recorders.sessions.values.isEmpty)
        XCTAssertTrue(recorders.detail.values.isEmpty)
    }

    func testNoOriginGetUsesExactFetchMetadataTriple() async throws {
        let fixture = try fixture()
        defer { fixture.stop() }
        let recorders = A5bRouteRecorders()
        let sessionID = "session-a"
        try await withServer(surface: recordingSurface(recorders: recorders)) { server in
            let cookie = try await Self.login(server)
            for path in ["/web/api/overview", "/web/api/sessions", "/web/api/sessions/\(sessionID)"] {
                let response = try await server.request("GET", path, headers: Self.metadataHeaders + [("Cookie", cookie)])
                XCTAssertEqual(response.status, 200, path)
                Self.assertSecurityHeaders(response)
            }
        }
        XCTAssertEqual(recorders.overview.values.count, 1)
        XCTAssertEqual(recorders.sessions.values.count, 1)
        XCTAssertEqual(recorders.detail.values, [sessionID])
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testSessionsKeywordPreservesLiteralPlusAndUnicodeBytes() async throws {
        let fixture = try fixture()
        defer { fixture.stop() }
        let recorders = A5bRouteRecorders()
        let unicode = "中文-e\u{301}"
        try await withServer(surface: recordingSurface(recorders: recorders)) { server in
            let cookie = try await Self.login(server)
            let plus = try await server.request(
                "GET", "/web/api/sessions?query=foo+bar&source=claude-code&limit=2",
                headers: Self.originHeaders + [("Cookie", cookie)]
            )
            XCTAssertEqual(plus.status, 200)
            let encodedPlus = try await server.request(
                "GET", "/web/api/sessions?query=foo%2Bbar&limit=1",
                headers: Self.originHeaders + [("Cookie", cookie)]
            )
            XCTAssertEqual(encodedPlus.status, 200)
            let encodedUnicode = try await server.request(
                "GET", "/web/api/sessions?query=\(Self.queryEncode(unicode))&limit=1",
                headers: Self.originHeaders + [("Cookie", cookie)]
            )
            XCTAssertEqual(encodedUnicode.status, 200)
            let body: EngramServiceWebSessionsResponse = try JSONDecoder().decode(EngramServiceWebSessionsResponse.self, from: plus.body)
            XCTAssertEqual(body.items.map(\.sessionId), ["session-a"])
        }
        XCTAssertEqual(recorders.sessions.values.map(\.query), ["foo+bar", "foo+bar", unicode])
        guard recorders.sessions.values.count == 3 else { return }
        XCTAssertEqual(Data((recorders.sessions.values[0].query ?? "").utf8), Data("foo+bar".utf8))
        XCTAssertEqual(Data((recorders.sessions.values[2].query ?? "").utf8), Data(unicode.utf8))
        XCTAssertNotEqual(Data(unicode.utf8), Data("中文-é".utf8))
        XCTAssertTrue(recorders.overview.values.isEmpty)
        XCTAssertTrue(recorders.detail.values.isEmpty)
    }

    func testSessionsRejectsUntrimmedDuplicateUnknownAndNoncanonicalQueryBeforeReader() async throws {
        let fixture = try fixture()
        defer { fixture.stop() }
        let recorders = A5bRouteRecorders()
        try await withServer(surface: recordingSurface(recorders: recorders)) { server in
            let cookie = try await Self.login(server)
            for rejected in [
                "query=%20foo", "query=foo%20", "query=foo%0abar", "query=foo&query=bar", "query=",
                "limit=01", "limit=0", "limit=101", "limit=", "cursor=next", "snapshotId=\(Self.snapshot)",
                "sourceInstanceId=\(Self.instance)", "unknown=1", "foo=1",
            ] {
                let response = try await server.request(
                    "GET", "/web/api/sessions?" + rejected,
                    headers: Self.originHeaders + [("Cookie", cookie)]
                )
                XCTAssertEqual(response.status, 400, rejected)
                Self.assertSecurityHeaders(response)
            }
        }
        recorders.assertIdle()
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testSessionsContinuationPassesAllFiltersIncludingProjectKeyAndSourceInstanceId() async throws {
        let fixture = try fixture()
        defer { fixture.stop() }
        let recorders = A5bRouteRecorders()
        let path = "/web/api/sessions?query=foo+bar&source=claude-code&machineId=\(Self.machine)"
            + "&sourceInstanceId=\(Self.instance)&projectKey=project_1&limit=2"
            + "&snapshotId=\(Self.snapshot)&cursor=next"
        try await withServer(surface: recordingSurface(recorders: recorders)) { server in
            let cookie = try await Self.login(server)
            let response = try await server.request("GET", path, headers: Self.originHeaders + [("Cookie", cookie)])
            XCTAssertEqual(response.status, 200)
            let body: EngramServiceWebSessionsResponse = try JSONDecoder().decode(EngramServiceWebSessionsResponse.self, from: response.body)
            XCTAssertEqual(body.snapshotId, Self.snapshot)
            XCTAssertEqual(body.nextCursor, "after")
            XCTAssertEqual(body.items.first?.projectKey, "project_1")
            XCTAssertEqual(body.items.first?.captureIdentity?.sourceInstanceId, Self.instance)
        }
        XCTAssertEqual(recorders.sessions.values.count, 1)
        let recorded = try XCTUnwrap(recorders.sessions.values.first)
        XCTAssertEqual(recorded.query, "foo+bar")
        XCTAssertEqual(recorded.source, "claude-code")
        XCTAssertEqual(recorded.machineId, Self.machine)
        XCTAssertEqual(recorded.sourceInstanceId, Self.instance)
        XCTAssertEqual(recorded.projectKey, "project_1")
        XCTAssertEqual(recorded.limit, 2)
        XCTAssertEqual(recorded.snapshotId, Self.snapshot)
        XCTAssertEqual(recorded.cursor, "next")
        XCTAssertTrue(recorders.overview.values.isEmpty)
        XCTAssertTrue(recorders.detail.values.isEmpty)
    }

    func testMakeSurfaceSocketRoundTripForOverviewSessionsAndDetailDTOs() async throws {
        let fixture = try metadataFixture()
        defer { fixture.stop() }
        let expectedSocket = socketPath
        let sessionID = "session-中文-e\u{301}"
        try await withServer(factory: { path in
            XCTAssertEqual(path, expectedSocket)
            return try WebReadRoutes.makeSurface(socketPath: path)
        }) { server in
            let cookie = try await Self.login(server)
            let overview = try await server.request(
                "GET", "/web/api/overview?limit=2&snapshotId=\(Self.snapshot)&cursor=next",
                headers: Self.originHeaders + [("Cookie", cookie)]
            )
            XCTAssertEqual(overview.status, 200)
            let overviewBody: EngramServiceWebOverviewResponse = try JSONDecoder().decode(EngramServiceWebOverviewResponse.self, from: overview.body)
            XCTAssertEqual(overviewBody.snapshotId, Self.snapshot)
            XCTAssertEqual(overviewBody.nextCursor, "after")

            let sessionsPath = "/web/api/sessions?query=foo+bar&source=claude-code&machineId=\(Self.machine)"
                + "&sourceInstanceId=\(Self.instance)&projectKey=project_1&limit=2"
                + "&snapshotId=\(Self.snapshot)&cursor=next"
            let sessions = try await server.request("GET", sessionsPath, headers: Self.originHeaders + [("Cookie", cookie)])
            XCTAssertEqual(sessions.status, 200)
            let sessionsBody: EngramServiceWebSessionsResponse = try JSONDecoder().decode(EngramServiceWebSessionsResponse.self, from: sessions.body)
            XCTAssertEqual(sessionsBody.snapshotId, Self.snapshot)
            XCTAssertEqual(sessionsBody.items.first?.projectKey, "project_1")

            let detail = try await server.request(
                "GET", "/web/api/sessions/\(Self.queryEncode(sessionID))",
                headers: Self.originHeaders + [("Cookie", cookie)]
            )
            XCTAssertEqual(detail.status, 200)
            let detailBody: EngramServiceWebSessionDetailResponse = try JSONDecoder().decode(EngramServiceWebSessionDetailResponse.self, from: detail.body)
            XCTAssertEqual(Data(try XCTUnwrap(detailBody.detail).session.sessionId.utf8), Data(sessionID.utf8))
        }
        XCTAssertEqual(fixture.requests.map(\.command), ["webOverview", "webSessions", "webSessionDetail"])
        guard fixture.requests.count == 3 else { return }
        XCTAssertTrue(fixture.requests.allSatisfy { $0.capabilityToken == nil })
        let overviewRequest = try JSONDecoder().decode(EngramServiceWebOverviewRequest.self, from: try XCTUnwrap(fixture.requests[0].payload))
        XCTAssertEqual(overviewRequest.limit, 2)
        XCTAssertEqual(overviewRequest.snapshotId, Self.snapshot)
        XCTAssertEqual(overviewRequest.cursor, "next")
        let sessionsRequest = try JSONDecoder().decode(EngramServiceWebSessionsRequest.self, from: try XCTUnwrap(fixture.requests[1].payload))
        XCTAssertEqual(sessionsRequest.query, "foo+bar")
        XCTAssertEqual(sessionsRequest.source, "claude-code")
        XCTAssertEqual(sessionsRequest.machineId, Self.machine)
        XCTAssertEqual(sessionsRequest.sourceInstanceId, Self.instance)
        XCTAssertEqual(sessionsRequest.projectKey, "project_1")
        XCTAssertEqual(sessionsRequest.limit, 2)
        XCTAssertEqual(sessionsRequest.snapshotId, Self.snapshot)
        XCTAssertEqual(sessionsRequest.cursor, "next")
        let detailRequest = try JSONDecoder().decode(EngramServiceWebSessionDetailRequest.self, from: try XCTUnwrap(fixture.requests[2].payload))
        XCTAssertEqual(Data(detailRequest.sessionId.utf8), Data(sessionID.utf8))
    }

    func testSessionDetailRejectsNonemptyQueryWith400BeforeReader() async throws {
        let fixture = try fixture()
        defer { fixture.stop() }
        let recorders = A5bRouteRecorders()
        try await withServer(surface: recordingSurface(recorders: recorders)) { server in
            let cookie = try await Self.login(server)
            let ok = try await server.request("GET", "/web/api/sessions/session-a", headers: Self.originHeaders + [("Cookie", cookie)])
            XCTAssertEqual(ok.status, 200)
            for query in ["limit=1", "query=foo", "cursor=next", "snapshotId=\(Self.snapshot)", "unknown=1"] {
                let response = try await server.request(
                    "GET", "/web/api/sessions/session-a?" + query,
                    headers: Self.originHeaders + [("Cookie", cookie)]
                )
                XCTAssertEqual(response.status, 400, query)
                Self.assertSecurityHeaders(response)
            }
        }
        XCTAssertEqual(recorders.detail.values, ["session-a"])
        XCTAssertTrue(recorders.overview.values.isEmpty)
        XCTAssertTrue(recorders.sessions.values.isEmpty)
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testSessionDetailMalformedRouterPathMayBe404Separately() async throws {
        let fixture = try fixture()
        defer { fixture.stop() }
        let recorders = A5bRouteRecorders()
        let overlength = String(repeating: "x", count: EngramServiceWebReadLimits.maximumSessionIDBytes + 1)
        try await withServer(surface: recordingSurface(recorders: recorders)) { server in
            let cookie = try await Self.login(server)
            for path in [
                "/web/api/sessions/session-a#frag",
                "/web/api/sessions/session-a%00",
                "/web/api/sessions/%ZZ",
                "/web/api/sessions/\(overlength)",
            ] {
                let response = try await server.request("GET", path, headers: Self.originHeaders + [("Cookie", cookie)])
                XCTAssertNotEqual(response.status, 200, path)
                XCTAssertTrue([400, 404].contains(response.status), "\(path) -> \(response.status)")
                Self.assertSecurityHeaders(response)
            }
        }
        recorders.assertIdle()
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testSearchPathIsNotARouteAndDoesNotInvokeReaders() async throws {
        let fixture = try fixture()
        defer { fixture.stop() }
        let recorders = A5bRouteRecorders()
        try await withServer(surface: recordingSurface(recorders: recorders)) { server in
            let cookie = try await Self.login(server)
            let response = try await server.request("GET", "/web/api/search?query=foo", headers: Self.originHeaders + [("Cookie", cookie)])
            XCTAssertEqual(response.status, 404)
            Self.assertSecurityHeaders(response)
        }
        recorders.assertIdle()
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testOtherwiseValidEncodedQueryAccepts4096ButRejects4097BeforeReader() async throws {
        let fixture = try fixture()
        defer { fixture.stop() }
        let recorders = A5bRouteRecorders()
        let cursor = String(repeating: "a", count: 1024)
        let keyword = String(repeating: "x", count: 1024)
        let encodedKeyword = String(repeating: "%78", count: 989) + String(repeating: "x", count: 35)
        let suffix = "&snapshotId=\(Self.snapshot)&cursor=\(cursor)&query=\(encodedKeyword)"
        let accepted = "limit=1" + suffix
        let rejected = "limit=10" + suffix
        XCTAssertEqual(accepted.utf8.count, 4096)
        XCTAssertEqual(rejected.utf8.count, 4097)
        XCTAssertEqual(encodedKeyword.removingPercentEncoding, keyword)
        // Both decoded requests are valid. Only the encoded HTTP query budget
        // distinguishes these requests; no unknown field or DTO limit masks it.
        let expected = try EngramServiceWebSessionsRequest(query: keyword, limit: 1, snapshotId: Self.snapshot, cursor: cursor)
        _ = try EngramServiceWebSessionsRequest(query: keyword, limit: 10, snapshotId: Self.snapshot, cursor: cursor)
        try await withServer(surface: recordingSurface(recorders: recorders)) { server in
            let cookie = try await Self.login(server)
            let headers = Self.originHeaders + [("Cookie", cookie)]
            let success = try await server.request("GET", "/web/api/sessions?" + accepted, headers: headers)
            XCTAssertEqual(success.status, 200)
            Self.assertSecurityHeaders(success)
            XCTAssertEqual(recorders.sessions.values, [expected])
            let failure = try await server.request("GET", "/web/api/sessions?" + rejected, headers: headers)
            XCTAssertEqual(failure.status, 400)
            Self.assertSecurityHeaders(failure)
            XCTAssertEqual(recorders.sessions.values, [expected])
        }
        XCTAssertTrue(recorders.overview.values.isEmpty)
        XCTAssertTrue(recorders.detail.values.isEmpty)
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testEncodedQueryOver4096RejectedBeforeReader() async throws {
        let fixture = try fixture()
        defer { fixture.stop() }
        let recorders = A5bRouteRecorders()
        try await withServer(surface: recordingSurface(recorders: recorders)) { server in
            let cookie = try await Self.login(server)
            let overviewQuery = Self.paddedQuery(prefix: "limit=1&pad=", totalBytes: 4097)
            XCTAssertEqual(overviewQuery.utf8.count, 4097)
            let sessionsQuery = Self.paddedQuery(prefix: "limit=1&pad=", totalBytes: 4097)
            let detailQuery = Self.paddedQuery(prefix: "pad=", totalBytes: 4097)
            for path in [
                "/web/api/overview?" + overviewQuery,
                "/web/api/sessions?" + sessionsQuery,
                "/web/api/sessions/session-a?" + detailQuery,
            ] {
                let response = try await server.request("GET", path, headers: Self.originHeaders + [("Cookie", cookie)])
                XCTAssertEqual(response.status, 400, "encoded query \(path.utf8.count) bytes")
                Self.assertSecurityHeaders(response)
            }
        }
        recorders.assertIdle()
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testOverviewRejectsUnknownDuplicateAndNoncanonicalLimitBeforeReader() async throws {
        let fixture = try fixture()
        defer { fixture.stop() }
        let recorders = A5bRouteRecorders()
        try await withServer(surface: recordingSurface(recorders: recorders)) { server in
            let cookie = try await Self.login(server)
            for query in [
                "limit=01", "limit=1&limit=2", "foo=1", "limit=1&snapshotId=\(Self.snapshot)",
                "cursor=next", "limit=", "unknown=1",
            ] {
                let response = try await server.request(
                    "GET", "/web/api/overview?" + query,
                    headers: Self.originHeaders + [("Cookie", cookie)]
                )
                XCTAssertEqual(response.status, 400, query)
                Self.assertSecurityHeaders(response)
            }
        }
        recorders.assertIdle()
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testMetadataAuthAndWriteMethodsNeverInvokeReaders() async throws {
        let fixture = try fixture()
        defer { fixture.stop() }
        let recorders = A5bRouteRecorders()
        try await withServer(surface: recordingSurface(recorders: recorders)) { server in
            for path in ["/web/api/overview", "/web/api/sessions", "/web/api/sessions/session-a"] {
                let unauthorized = try await server.request("GET", path, headers: Self.originHeaders)
                XCTAssertEqual(unauthorized.status, 401, path)
                let cookie = try await Self.login(server)
                let missingHeader = try await server.request("GET", path, headers: [("Origin", Self.origin), ("Cookie", cookie)])
                XCTAssertEqual(missingHeader.status, 403, path)
                for method in ["POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"] {
                    let response = try await server.request(method, path, headers: Self.originHeaders + [("Cookie", cookie)])
                    XCTAssertEqual(response.status, 405, "\(method) \(path)")
                }
            }
        }
        recorders.assertIdle()
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testMetadataClientErrorsAndGenericFailuresMapToSafeStatusesWithoutSecrets() async throws {
        let cases: [(EngramServiceWebReadClientError, Int)] = [
            (.stale, 409), (.unavailable, 503), (.unsupported, 503), (.malformed, 502),
        ]
        for (error, status) in cases {
            let fixture = try fixture()
            defer { fixture.stop() }
            let recorders = A5bRouteRecorders()
            try await withServer(surface: recordingSurface(recorders: recorders, overview: { _ in throw error })) { server in
                let cookie = try await Self.login(server)
                let response = try await server.request("GET", "/web/api/overview", headers: Self.originHeaders + [("Cookie", cookie)])
                XCTAssertEqual(response.status, status, String(describing: error))
                Self.assertSafeFailure(response)
            }
            XCTAssertEqual(recorders.overview.values.count, 1)
            XCTAssertTrue(fixture.requests.isEmpty)
        }
        let fixture = try fixture()
        defer { fixture.stop() }
        let recorders = A5bRouteRecorders()
        try await withServer(surface: recordingSurface(recorders: recorders, overview: { _ in throw A5bSecretError() })) { server in
            let cookie = try await Self.login(server)
            let response = try await server.request("GET", "/web/api/overview", headers: Self.originHeaders + [("Cookie", cookie)])
            XCTAssertEqual(response.status, 503)
            Self.assertSafeFailure(response)
        }
        XCTAssertEqual(recorders.overview.values.count, 1)
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testInjectedReaderCancellationErrorMapsToSafeHandlingAndCompletes() async throws {
        // Injected reader throw → safe HTTP mapping and observed completion.
        // This does not prove Hummingbird handler-task cancellation, App.run
        // orphan freedom, or that cancelling the Darwin client aborts the server.
        let fixture = try fixture()
        defer { fixture.stop() }
        let recorders = A5bRouteRecorders()
        let probe = A5bJoinProbe()
        try await withServer(surface: recordingSurface(recorders: recorders, overview: { _ in
            probe.enter()
            defer { probe.complete() }
            throw CancellationError()
        })) { server in
            let cookie = try await Self.login(server)
            let response = try await server.request("GET", "/web/api/overview", headers: Self.originHeaders + [("Cookie", cookie)])
            XCTAssertEqual(response.status, 503)
            Self.assertSafeFailure(response)
        }
        XCTAssertEqual(probe.entered, 1, "Unmounted handlers yield entered=0; that is honest RED")
        XCTAssertEqual(probe.completed, 1)
        XCTAssertEqual(recorders.overview.values.count, 1)
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testOversizedEncodedResponseBudgetIs502() async throws {
        let fixture = try fixture()
        defer { fixture.stop() }
        let recorders = A5bRouteRecorders()
        try await withServer(surface: recordingSurface(recorders: recorders, overview: { _ in
            Self.oversizedOverviewPage()
        })) { server in
            let cookie = try await Self.login(server)
            let response = try await server.request("GET", "/web/api/overview", headers: Self.originHeaders + [("Cookie", cookie)])
            XCTAssertEqual(response.status, 502)
            XCTAssertLessThanOrEqual(response.body.count, EngramServiceWebReadLimits.maximumPageEnvelopeBytes)
            Self.assertSafeFailure(response)
        }
        XCTAssertEqual(recorders.overview.values.count, 1)
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testValidSessionsDTOOverEncodedBudgetIs502AfterOneReaderCall() async throws {
        let fixture = try fixture()
        defer { fixture.stop() }
        let recorders = A5bRouteRecorders()
        let items = (0..<100).map { index in
            EngramServiceWebSessionSummary(
                sessionId: String(repeating: "s", count: 4000) + "-\(index)", source: "claude-code",
                captureIdentity: nil, metadataGeneration: nil, title: nil,
                projectKey: nil, projectLabel: nil, startedAt: nil
            )
        }
        let oversized = EngramServiceWebSessionsResponse(snapshotId: Self.snapshot, observedAt: 1, items: items, nextCursor: nil)
        let encoded = try JSONEncoder().encode(oversized)
        let decoded = try JSONDecoder().decode(EngramServiceWebSessionsResponse.self, from: encoded)
        XCTAssertEqual(decoded, oversized)
        XCTAssertGreaterThan(encoded.count, EngramServiceWebReadLimits.maximumPageEnvelopeBytes)
        XCTAssertLessThan(encoded.count, 1024 * 1024)
        try await withServer(surface: recordingSurface(recorders: recorders, sessions: { request in
            request.limit == 100 ? oversized : Self.sessionsPage(request)
        })) { server in
            let cookie = try await Self.login(server)
            let headers = Self.originHeaders + [("Cookie", cookie)]
            let success = try await server.request("GET", "/web/api/sessions?limit=1", headers: headers)
            XCTAssertEqual(success.status, 200)
            Self.assertSecurityHeaders(success)
            let before = recorders.sessions.values.count
            XCTAssertEqual(before, 1)
            let failure = try await server.request("GET", "/web/api/sessions?limit=100", headers: headers)
            XCTAssertEqual(failure.status, 502)
            Self.assertSafeFailure(failure)
            XCTAssertLessThanOrEqual(failure.body.count, EngramServiceWebReadLimits.maximumPageEnvelopeBytes)
            XCTAssertEqual(recorders.sessions.values.count, before + 1)
        }
        XCTAssertEqual(recorders.sessions.values.map(\.limit), [1, 100])
        XCTAssertTrue(recorders.overview.values.isEmpty)
        XCTAssertTrue(recorders.detail.values.isEmpty)
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testMessagesOnlySurfaceStillServesExistingMessagesRoute() async throws {
        let fixture = try fixture { request in
            XCTAssertEqual(request.command, "webMessages")
            let page = try WebMetadataHTTPTests.messagesPage(WebMetadataHTTPTests.decodeMessages(request))
            return try WebMetadataHTTPTests.success(page, id: request.requestId)
        }
        defer { fixture.stop() }
        let expectedSocket = socketPath
        try await withServer(factory: { path in
            XCTAssertEqual(path, expectedSocket)
            return try WebReadRoutes.makeSurface(socketPath: path)
        }) { server in
            let cookie = try await Self.login(server)
            let response = try await server.request(
                "GET", "/web/api/sessions/session-a/messages?generation=\(String(repeating: "a", count: 64))",
                headers: Self.originHeaders + [("Cookie", cookie)]
            )
            XCTAssertEqual(response.status, 200)
        }
        XCTAssertEqual(fixture.requests.map(\.command), ["webMessages"])
    }

    private func config() throws -> EngramRemoteServerConfig {
        try EngramRemoteServerConfig(
            host: "127.0.0.1", port: 0, storeRoot: directory.appendingPathComponent("legacy"),
            bearerToken: "a5b-v1-token", atRestKey: SymmetricKey(data: Data(repeating: 1, count: 32)),
            web: try .forLoopbackHTTPTesting(origin: Self.origin, viewerCredential: Self.viewer, serverBearerCredentials: []),
            webServiceSocketPath: socketPath
        )
    }

    private func recordingSurface(
        recorders: A5bRouteRecorders,
        overview: (@Sendable (EngramServiceWebOverviewRequest) async throws -> EngramServiceWebOverviewResponse)? = nil,
        sessions: (@Sendable (EngramServiceWebSessionsRequest) async throws -> EngramServiceWebSessionsResponse)? = nil,
        detail: (@Sendable (EngramServiceWebSessionDetailRequest) async throws -> EngramServiceWebSessionDetailResponse)? = nil
    ) -> WebReadRoutes.Surface {
        WebReadRoutes.Surface(
            messages: { _ in throw EngramServiceWebReadClientError.unavailable },
            overview: { request in
                recorders.overview.append(request)
                if let overview { return try await overview(request) }
                return Self.overviewPage(snapshot: request.snapshotId ?? Self.snapshot, nextCursor: request.cursor == nil ? nil : "after")
            },
            sessions: { request in
                recorders.sessions.append(request)
                if let sessions { return try await sessions(request) }
                return Self.sessionsPage(request)
            },
            detail: { request in
                recorders.detail.append(request.sessionId)
                if let detail { return try await detail(request) }
                return Self.detailPage(request.sessionId)
            }
        )
    }

    private func withServer(surface: WebReadRoutes.Surface, operation: (A5bHTTPServer) async throws -> Void) async throws {
        try await withServer(factory: { _ in surface }, operation: operation)
    }

    private func withServer(factory: @escaping WebReadRoutes.ClientFactory, operation: (A5bHTTPServer) async throws -> Void) async throws {
        let app = try EngramRemoteServerApp(config: config(), webReadClientFactory: factory)
        let server = try await A5bHTTPServer(app: app)
        do { try await operation(server) } catch {
            do { try await server.stop() } catch { XCTFail("Server cleanup failed: \(error)") }
            throw error
        }
        try await server.stop()
    }

    private func fixture(response: @escaping @Sendable (EngramServiceRequestEnvelope) throws -> Data = { _ in
        throw A5bFailure("Metadata HTTP draft must not open IPC")
    }) throws -> A5bSocketFixture {
        try A5bSocketFixture(path: socketPath, response: response)
    }

    private func metadataFixture() throws -> A5bSocketFixture {
        try fixture { request in
            switch request.command {
            case "webOverview":
                let input = try JSONDecoder().decode(EngramServiceWebOverviewRequest.self, from: try XCTUnwrap(request.payload))
                return try Self.success(
                    Self.overviewPage(snapshot: input.snapshotId ?? Self.snapshot, nextCursor: input.cursor == nil ? nil : "after"),
                    id: request.requestId
                )
            case "webSessions":
                let input = try JSONDecoder().decode(EngramServiceWebSessionsRequest.self, from: try XCTUnwrap(request.payload))
                return try Self.success(Self.sessionsPage(input), id: request.requestId)
            case "webSessionDetail":
                let input = try JSONDecoder().decode(EngramServiceWebSessionDetailRequest.self, from: try XCTUnwrap(request.payload))
                return try Self.success(Self.detailPage(input.sessionId), id: request.requestId)
            default:
                throw A5bFailure("Unexpected metadata command \(request.command)")
            }
        }
    }

    private static func overviewPage(snapshot: String = snapshot, nextCursor: String? = nil) -> EngramServiceWebOverviewResponse {
        EngramServiceWebOverviewResponse(
            snapshotId: snapshot, observedAt: 1,
            capabilities: .init(keywordSearch: .available, transcriptRead: .available),
            streams: [.init(machineId: machine, sourceInstanceId: instance, registry: nil, ingest: nil,
                            heartbeatAt: nil, lastCapture: nil, replicaACKs: nil, fts: nil, ai: nil)],
            nextCursor: nextCursor
        )
    }

    private static func oversizedOverviewPage() -> EngramServiceWebOverviewResponse {
        EngramServiceWebOverviewResponse(
            snapshotId: snapshot, observedAt: 1,
            capabilities: .init(keywordSearch: .available, transcriptRead: .available),
            streams: [.init(machineId: machine, sourceInstanceId: instance, registry: nil, ingest: nil,
                            heartbeatAt: nil, lastCapture: nil, replicaACKs: nil, fts: nil, ai: nil)],
            nextCursor: String(repeating: "x", count: EngramServiceWebReadLimits.maximumPageEnvelopeBytes)
        )
    }

    private static func sessionsPage(_ request: EngramServiceWebSessionsRequest) -> EngramServiceWebSessionsResponse {
        EngramServiceWebSessionsResponse(
            snapshotId: request.snapshotId ?? snapshot, observedAt: 1,
            items: [.init(sessionId: "session-a", source: request.source ?? "claude-code",
                          captureIdentity: .init(machineId: request.machineId ?? machine,
                                                 sourceInstanceId: request.sourceInstanceId ?? instance),
                          metadataGeneration: String(repeating: "a", count: 64), title: nil,
                          projectKey: request.projectKey, projectLabel: nil, startedAt: 1)],
            nextCursor: request.cursor == nil ? nil : "after"
        )
    }

    private static func detailPage(_ sessionID: String) -> EngramServiceWebSessionDetailResponse {
        EngramServiceWebSessionDetailResponse(
            observedAt: 1,
            detail: .init(
                session: .init(sessionId: sessionID, source: "claude-code", captureIdentity: nil,
                               metadataGeneration: nil, title: nil, projectKey: nil, projectLabel: nil, startedAt: nil),
                lastParsed: nil, lastReady: nil, transcriptAvailability: .unavailable,
                transcriptGeneration: nil, currentAttempt: nil
            )
        )
    }

    private static func decodeMessages(_ envelope: EngramServiceRequestEnvelope) throws -> EngramServiceWebMessagesRequest {
        try JSONDecoder().decode(EngramServiceWebMessagesRequest.self, from: try XCTUnwrap(envelope.payload))
    }

    private static func success<Value: Encodable>(_ value: Value, id: String) throws -> Data {
        try JSONEncoder().encode(EngramServiceResponseEnvelope.success(requestId: id, result: JSONEncoder().encode(value)))
    }

    private static func messagesPage(_ request: EngramServiceWebMessagesRequest) throws -> EngramServiceWebMessagesResponse {
        let payload = "{\"role\":\"user\",\"content\":\"ok\"}"
        let digest = Data(SHA256.hash(data: Data(payload.utf8))).map { String(format: "%02x", $0) }.joined()
        return try EngramServiceWebMessagesResponse(
            sessionId: request.sessionId, generation: request.generation, roles: request.roles,
            fragments: [.init(messageOrdinal: 0, role: .user, payloadSHA256: digest, utf8Offset: 0,
                              payloadFragment: payload, isLastFragment: true)],
            nextCursor: nil, totalKnownComplete: true, truncatedAt: nil, parseFailure: nil
        )
    }

    private static var originHeaders: [(String, String)] { [("X-Engram-Web", "1"), ("Origin", origin)] }
    private static var metadataHeaders: [(String, String)] {
        [("X-Engram-Web", "1"), ("Sec-Fetch-Site", "same-origin"), ("Sec-Fetch-Mode", "cors"), ("Sec-Fetch-Dest", "empty")]
    }

    private static func login(_ server: A5bHTTPServer) async throws -> String {
        let body = Data("{\"credential\":\"\(viewer)\"}".utf8)
        let response = try await server.request("POST", "/web/api/auth",
            headers: originHeaders + [("Content-Type", "application/json")], body: body)
        XCTAssertEqual(response.status, 204)
        assertSecurityHeaders(response)
        return try XCTUnwrap(response.header("set-cookie")?.split(separator: ";").first.map(String.init))
    }

    private static func assertSecurityHeaders(_ response: A5bHTTPResponse, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(response.header("cache-control"), "no-store", file: file, line: line)
        XCTAssertEqual(response.header("x-content-type-options"), "nosniff", file: file, line: line)
        let csp = response.header("content-security-policy") ?? ""
        for directive in ["default-src 'none'", "script-src 'self'", "style-src 'self'", "connect-src 'self'"] {
            XCTAssertTrue(csp.contains(directive), directive, file: file, line: line)
        }
        for name in ["access-control-allow-origin", "access-control-allow-credentials"] {
            XCTAssertNil(response.header(name), file: file, line: line)
        }
    }

    private static func assertSafeFailure(_ response: A5bHTTPResponse, file: StaticString = #filePath, line: UInt = #line) {
        assertSecurityHeaders(response, file: file, line: line)
        let text = String(decoding: response.body, as: UTF8.self)
        for secret in [viewer, "a5b-v1-token", A5bSecretMarker.raw] {
            XCTAssertFalse(text.contains(secret), file: file, line: line)
        }
        XCTAssertNotEqual(response.status, 200, file: file, line: line)
    }

    private static func queryEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"))!
    }

    private static func paddedQuery(prefix: String, totalBytes: Int) -> String {
        prefix + String(repeating: "x", count: max(0, totalBytes - prefix.utf8.count))
    }
}

private struct A5bFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct A5bSecretError: Error, CustomStringConvertible {
    var description: String { A5bSecretMarker.raw }
}

private enum A5bSecretMarker {
    static let raw = "a5b-raw-secret-must-not-leak"
}

private final class A5bRecorder<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []
    var values: [Value] { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ value: Value) { lock.lock(); storage.append(value); lock.unlock() }
}

private final class A5bRouteRecorders: @unchecked Sendable {
    let overview = A5bRecorder<EngramServiceWebOverviewRequest>()
    let sessions = A5bRecorder<EngramServiceWebSessionsRequest>()
    let detail = A5bRecorder<String>()

    func assertIdle(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(overview.values.isEmpty, "overview reader must not run", file: file, line: line)
        XCTAssertTrue(sessions.values.isEmpty, "sessions reader must not run", file: file, line: line)
        XCTAssertTrue(detail.values.isEmpty, "detail reader must not run", file: file, line: line)
    }
}

private final class A5bJoinProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var enteredCount = 0
    private var completedCount = 0
    var entered: Int { lock.lock(); defer { lock.unlock() }; return enteredCount }
    var completed: Int { lock.lock(); defer { lock.unlock() }; return completedCount }
    func enter() { lock.lock(); enteredCount += 1; lock.unlock() }
    func complete() { lock.lock(); completedCount += 1; lock.unlock() }
}

private final class A5bServerState: @unchecked Sendable {
    private let lock = NSLock()
    private var boundPort: Int?
    private var completion: Result<Void, Error>?
    func bound(_ port: Int) { lock.lock(); boundPort = port; lock.unlock() }
    func finished(_ result: Result<Void, Error>) { lock.lock(); completion = result; lock.unlock() }
    private func snapshot() -> (Int?, Result<Void, Error>?) {
        lock.lock(); defer { lock.unlock() }; return (boundPort, completion)
    }
    func awaitPort() async throws -> Int {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            let (port, completion) = snapshot()
            if let completion { try completion.get(); throw A5bFailure("HTTP server stopped before binding") }
            if let port { return port }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw A5bFailure("HTTP server did not bind within five seconds")
    }
    func awaitCompletion() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if let completion = snapshot().1 {
                do { try completion.get() } catch is CancellationError { return }
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw A5bFailure("HTTP server did not stop within three seconds")
    }
}

private final class A5bHTTPServer: @unchecked Sendable {
    let port: Int
    private let state: A5bServerState
    private let task: Task<Void, Never>

    init(app: EngramRemoteServerApp) async throws {
        let state = A5bServerState()
        let task = Task {
            do { try await app.run(onBound: { state.bound($0) }); state.finished(.success(())) }
            catch { state.finished(.failure(error)) }
        }
        do { port = try await state.awaitPort() }
        catch {
            task.cancel()
            do { try await Task.detached { try await state.awaitCompletion() }.value }
            catch { XCTFail("Failed startup cleanup: \(error)") }
            throw error
        }
        self.state = state
        self.task = task
    }

    func stop() async throws {
        task.cancel()
        let state = state
        try await Task.detached { try await state.awaitCompletion() }.value
    }

    func request(_ method: String, _ path: String, headers: [(String, String)] = [], body: Data = Data()) async throws -> A5bHTTPResponse {
        try Task.checkCancellation()
        let port = port
        let child: Task<A5bHTTPResponse, Error> = Task.detached {
            try Task.checkCancellation()
            return try A5bHTTPResponse.exchange(port: port, method: method, path: path, headers: headers, body: body)
        }
        let response = try await withTaskCancellationHandler {
            try await child.value
        } onCancel: {
            child.cancel()
        }
        try Task.checkCancellation()
        return response
    }
}

private struct A5bHTTPResponse: Sendable {
    let status: Int
    let headers: [String: [String]]
    let body: Data
    func header(_ name: String) -> String? { headers[name.lowercased()]?.first }

    static func exchange(port: Int, method: String, path: String, headers: [(String, String)], body: Data) throws -> Self {
        try Task.checkCancellation()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw A5bFailure("Cannot create HTTP test socket") }
        defer { close(fd) }
        try EngramServiceSocketIO.disableSigPipe(fd)
        try EngramServiceSocketIO.setSocketTimeout(fd, seconds: 3)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else { throw A5bFailure("Invalid loopback") }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw A5bFailure("HTTP connect failed: \(errno)") }
        var request = "\(method) \(path) HTTP/1.1\r\nHost: \(WebMetadataHTTPTestsAuthority.host)\r\nConnection: close\r\nContent-Length: \(body.count)\r\n"
        for (name, value) in headers { request += "\(name): \(value)\r\n" }
        request += "\r\n"
        var bytes = Data(request.utf8)
        bytes.append(body)
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw A5bFailure("HTTP exchange exceeded its total deadline") }
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw A5bFailure("HTTP write failed") }
                offset += count
            }
        }
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw A5bFailure("HTTP exchange exceeded its total deadline") }
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw A5bFailure("HTTP response read timed out or failed: \(errno)") }
            if count == 0 { break }
            received.append(contentsOf: buffer.prefix(count))
            guard received.count <= 1024 * 1024 else { throw A5bFailure("HTTP fixture response exceeded one MiB") }
        }
        try Task.checkCancellation()
        guard let boundary = received.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: received[..<boundary.lowerBound], encoding: .utf8) else { throw A5bFailure("Malformed HTTP response headers") }
        let lines = head.components(separatedBy: "\r\n")
        guard let first = lines.first, let status = Int(first.split(separator: " ").dropFirst().first ?? "") else {
            throw A5bFailure("Missing HTTP response status")
        }
        var fields: [String: [String]] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw A5bFailure("Malformed HTTP response field") }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields[name, default: []].append(value)
        }
        let rawBody = Data(received[boundary.upperBound...])
        let decoded: Data
        if method == "HEAD" { decoded = rawBody }
        else if fields["transfer-encoding"]?.first?.lowercased() == "chunked" { decoded = try decodeChunks(rawBody) }
        else {
            if let length = fields["content-length"]?.first.flatMap(Int.init), length != rawBody.count {
                throw A5bFailure("Truncated HTTP response body")
            }
            decoded = rawBody
        }
        return Self(status: status, headers: fields, body: decoded)
    }

    private static func decodeChunks(_ data: Data) throws -> Data {
        var index = data.startIndex
        var result = Data()
        let terminator = Data("\r\n".utf8)
        while index < data.endIndex {
            guard let line = data.range(of: terminator, in: index..<data.endIndex),
                  let text = String(data: data[index..<line.lowerBound], encoding: .utf8),
                  let size = Int(text.split(separator: ";").first ?? "", radix: 16), size >= 0 else {
                throw A5bFailure("Malformed HTTP chunk length")
            }
            index = line.upperBound
            let end = data.index(index, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
            guard data.distance(from: index, to: end) == size else { throw A5bFailure("Truncated HTTP chunk") }
            result.append(data[index..<end])
            index = end
            guard let breakIndex = data.range(of: terminator, in: index..<data.endIndex),
                  breakIndex.lowerBound == index else { throw A5bFailure("Malformed HTTP chunk terminator") }
            index = breakIndex.upperBound
            if size == 0 { break }
        }
        return result
    }
}

private enum WebMetadataHTTPTestsAuthority {
    static let host = "127.0.0.1:8787"
}

private final class A5bSocketFixture: @unchecked Sendable {
    private let lock = NSLock()
    private let group = DispatchGroup()
    private let path: String
    private var listener: Int32
    private var peer: Int32?
    private var stopped = false
    private var frames: [EngramServiceRequestEnvelope] = []
    private var failures: [String] = []
    var requests: [EngramServiceRequestEnvelope] { lock.lock(); defer { lock.unlock() }; return frames }

    init(path: String, response: @escaping @Sendable (EngramServiceRequestEnvelope) throws -> Data) throws {
        self.path = path
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw A5bFailure("Cannot create service fixture socket") }
        do {
            try EngramServiceSocketIO.withSockAddr(path: path) {
                guard Darwin.bind(listener, $0, $1) == 0 else { throw A5bFailure("Cannot bind service fixture") }
            }
            guard chmod(path, 0o600) == 0, listen(listener, 8) == 0,
                  fcntl(listener, F_SETFL, O_NONBLOCK) == 0 else { throw A5bFailure("Cannot prepare private service fixture") }
        } catch { close(listener); throw error }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer {
                lock.lock()
                if let peer { close(peer); self.peer = nil }
                close(listener)
                listener = -1
                lock.unlock()
                group.leave()
            }
            while true {
                lock.lock(); let shouldStop = stopped; lock.unlock()
                if shouldStop { return }
                var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, 50)
                if ready < 0 && errno == EINTR { continue }
                if ready <= 0 { continue }
                let fd = accept(listener, nil, nil)
                if fd < 0 { continue }
                lock.lock()
                peer = fd
                let stopping = stopped
                lock.unlock()
                if stopping { return }
                do {
                    let flags = fcntl(fd, F_GETFL)
                    guard flags >= 0, fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) == 0 else { throw A5bFailure("Cannot configure accepted service socket") }
                    try EngramServiceSocketIO.disableSigPipe(fd)
                    try EngramServiceSocketIO.setSocketTimeout(fd, seconds: 1)
                    let bytes = try EngramServiceSocketIO.readFrame(from: fd, requestTimeout: 1)
                    let request = try JSONDecoder().decode(EngramServiceRequestEnvelope.self, from: bytes)
                    lock.lock(); frames.append(request); lock.unlock()
                    try EngramServiceSocketIO.writeFrame(response(request), to: fd, requestTimeout: 1)
                } catch {
                    lock.lock(); failures.append(String(describing: error)); lock.unlock()
                }
                lock.lock(); close(fd); peer = nil; lock.unlock()
            }
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        if let peer { _ = shutdown(peer, SHUT_RDWR) }
        if listener >= 0 { _ = shutdown(listener, SHUT_RDWR) }
        lock.unlock()
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success, "Service fixture must stop within two seconds")
        lock.lock(); let errors = failures; lock.unlock()
        XCTAssertTrue(errors.isEmpty, "Service fixture failed: \(errors)")
        do { try FileManager.default.removeItem(atPath: path) }
        catch { XCTFail("Cannot remove task-owned service fixture: \(error)") }
    }
}
