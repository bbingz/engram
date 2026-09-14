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

    func testSessionsParsesCommaSeparatedPluralFiltersAndRejectsConflicts_repro() async throws {
        let fixture = try fixture()
        defer { fixture.stop() }
        let recorders = A5bRouteRecorders()
        try await withServer(surface: recordingSurface(recorders: recorders)) { server in
            let cookie = try await Self.login(server)
            let accepted = "/web/api/sessions?sources=codex,claude-code&projectKeys=project_2,project_1"
                + "&sessionId=old-uuid&agents=only&limit=2"
            let response = try await server.request("GET", accepted, headers: Self.originHeaders + [("Cookie", cookie)])
            XCTAssertEqual(response.status, 200)
            for rejected in [
                "source=codex&sources=codex",
                "projectKey=project_1&projectKeys=project_1",
                "sources=",
                "sources=codex,codex",
                "agents=visible",
                "sources=codex&sources=claude-code",
                "sessionIds=old-uuid",
            ] {
                let failure = try await server.request(
                    "GET", "/web/api/sessions?" + rejected,
                    headers: Self.originHeaders + [("Cookie", cookie)]
                )
                XCTAssertEqual(failure.status, 400, rejected)
            }
        }
        XCTAssertEqual(recorders.sessions.values.count, 1)
        let recorded = try XCTUnwrap(recorders.sessions.values.first)
        XCTAssertEqual(recorded.sources, ["claude-code", "codex"])
        XCTAssertEqual(recorded.projectKeys, ["project_1", "project_2"])
        XCTAssertEqual(recorded.sessionId, "old-uuid")
        XCTAssertEqual(recorded.agents, .only)
        XCTAssertNil(recorded.source)
        XCTAssertNil(recorded.projectKey)
    }

    func testSessionsRejectsInvalidDateToolQueryAndPreservesOptionalTotalCount_repro() async throws {
        let fixture = try fixture()
        defer { fixture.stop() }
        let recorders = A5bRouteRecorders()
        try await withServer(surface: recordingSurface(recorders: recorders, sessions: { request in
            if request.tools == .hide {
                return EngramServiceWebSessionsResponse(
                    snapshotId: request.snapshotId ?? Self.snapshot, observedAt: 1,
                    items: [EngramServiceWebSessionSummary(
                        sessionId: "session-a", source: "claude-code",
                        captureIdentity: .init(machineId: Self.machine, sourceInstanceId: Self.instance),
                        metadataGeneration: String(repeating: "a", count: 64), title: nil,
                        projectKey: "project_1", projectLabel: "engram",
                        startedAt: 1_757_246_400, isAgent: false)],
                    nextCursor: nil, totalCount: 4)
            }
            return Self.sessionsPage(request)
        })) { server in
            let cookie = try await Self.login(server)
            let headers = Self.originHeaders + [("Cookie", cookie)]
            for rejected in [
                "since=2026-9-07", "since=2026-02-30", "since=2026-09-13&until=2026-09-07",
                "tools=yes", "tools=", "tools=all&tools=hide", "unknown=1",
            ] {
                let response = try await server.request(
                    "GET", "/web/api/sessions?" + rejected, headers: headers)
                XCTAssertEqual(response.status, 400, rejected)
                Self.assertSecurityHeaders(response)
            }
            let absent = try await server.request("GET", "/web/api/sessions?limit=1", headers: headers)
            XCTAssertEqual(absent.status, 200)
            let absentBody: EngramServiceWebSessionsResponse = try JSONDecoder().decode(
                EngramServiceWebSessionsResponse.self, from: absent.body)
            XCTAssertNil(absentBody.totalCount)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: absent.body) as? [String: Any])
            XCTAssertNil(object["totalCount"], "HTTP must preserve absent totalCount")
            let accepted = try await server.request(
                "GET",
                "/web/api/sessions?since=2026-09-07&until=2026-09-13&tools=hide&limit=2",
                headers: headers)
            XCTAssertEqual(accepted.status, 200)
            let acceptedBody: EngramServiceWebSessionsResponse = try JSONDecoder().decode(
                EngramServiceWebSessionsResponse.self, from: accepted.body)
            XCTAssertEqual(acceptedBody.totalCount, 4)
        }
        XCTAssertEqual(recorders.sessions.values.map(\.since), [nil, "2026-09-07"])
        XCTAssertEqual(recorders.sessions.values.map(\.until), [nil, "2026-09-13"])
        XCTAssertEqual(recorders.sessions.values.map(\.tools), [.all, .hide])
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

    func testFacetsRejectsInvalidQueryBeforeReaderAndAcceptsExactContract_repro() async throws {
        let fixture = try fixture()
        defer { fixture.stop() }
        let recorders = A5bRouteRecorders()
        try await withServer(surface: recordingSurface(recorders: recorders)) { server in
            let cookie = try await Self.login(server)
            let headers = Self.originHeaders + [("Cookie", cookie)]
            for rejected in [
                "", "kind=sources", "kind=project&kind=source", "kind=source&query=%20foo",
                "kind=source&query=foo%20", "kind=source&query=", "kind=source&agents=visible",
                "kind=source&limit=0", "kind=source&limit=101", "kind=source&cursor=next",
                "kind=source&snapshotId=\(Self.snapshot)", "kind=source&sessionIds=old-uuid",
                "kind=source&unknown=1", "sessionIds=old-uuid",
            ] {
                let path = rejected.isEmpty ? "/web/api/facets" : "/web/api/facets?" + rejected
                let response = try await server.request("GET", path, headers: headers)
                XCTAssertEqual(response.status, 400, path)
                Self.assertSecurityHeaders(response)
            }
            let source = try await server.request("GET", "/web/api/facets?kind=source", headers: headers)
            XCTAssertEqual(source.status, 200)
            let sourceBody: EngramServiceWebFacetsResponse = try JSONDecoder().decode(EngramServiceWebFacetsResponse.self, from: source.body)
            XCTAssertEqual(sourceBody.items.map(\.key), ["claude-code"])
            let project = try await server.request(
                "GET", "/web/api/facets?kind=project&query=engram&agents=only&limit=2",
                headers: headers)
            XCTAssertEqual(project.status, 200)
            let projectBody: EngramServiceWebFacetsResponse = try JSONDecoder().decode(EngramServiceWebFacetsResponse.self, from: project.body)
            XCTAssertEqual(projectBody.items.first?.label, "engram")
            let continued = try await server.request(
                "GET", "/web/api/facets?kind=source&limit=2&snapshotId=\(Self.snapshot)&cursor=next",
                headers: headers)
            XCTAssertEqual(continued.status, 200)
        }
        XCTAssertEqual(recorders.facets.values.map(\.kind), [.source, .project, .source])
        XCTAssertEqual(recorders.facets.values.map(\.query), [nil, "engram", nil])
        XCTAssertEqual(recorders.facets.values.map(\.agents), [.hide, .only, .hide])
        XCTAssertEqual(recorders.facets.values.map(\.limit), [50, 2, 2])
        XCTAssertEqual(recorders.facets.values[2].snapshotId, Self.snapshot)
        XCTAssertEqual(recorders.facets.values[2].cursor, "next")
        XCTAssertTrue(recorders.overview.values.isEmpty)
        XCTAssertTrue(recorders.sessions.values.isEmpty)
        XCTAssertTrue(recorders.detail.values.isEmpty)
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testMakeSurfaceSocketRoundTripForFacetsDTO_repro() async throws {
        let fixture = try metadataFixture()
        defer { fixture.stop() }
        try await withServer(factory: { path in
            try WebReadRoutes.makeSurface(socketPath: path)
        }) { server in
            let cookie = try await Self.login(server)
            let response = try await server.request(
                "GET", "/web/api/facets?kind=project&query=engram&agents=only&limit=2",
                headers: Self.originHeaders + [("Cookie", cookie)])
            XCTAssertEqual(response.status, 200)
            let body: EngramServiceWebFacetsResponse = try JSONDecoder().decode(EngramServiceWebFacetsResponse.self, from: response.body)
            XCTAssertEqual(body.snapshotId, Self.snapshot)
            XCTAssertEqual(body.items.first?.label, "engram")
            XCTAssertEqual(body.items.first?.sessionCount, 1)
        }
        XCTAssertEqual(fixture.requests.map(\.command), ["webFacets"])
        let request = try JSONDecoder().decode(EngramServiceWebFacetsRequest.self, from: try XCTUnwrap(fixture.requests.first?.payload))
        XCTAssertEqual(request.kind, .project)
        XCTAssertEqual(request.query, "engram")
        XCTAssertEqual(request.agents, .only)
        XCTAssertEqual(request.limit, 2)
        XCTAssertNil(request.snapshotId)
        XCTAssertNil(request.cursor)
    }

    func testStatsRejectsInvalidQueryBeforeReaderAndAcceptsExactContract_repro() async throws {
        let fixture = try fixture()
        defer { fixture.stop() }
        let recorders = A5bRouteRecorders()
        try await withServer(surface: recordingSurface(recorders: recorders)) { server in
            let cookie = try await Self.login(server)
            let headers = Self.originHeaders + [("Cookie", cookie)]
            for rejected in [
                "groupBy=month", "groupBy=source&groupBy=day", "since=2026-9-07", "since=2026-02-30",
                "since=2026-09-13&until=2026-09-07", "excludeNoise=yes", "excludeNoise=1",
                "agents=visible", "limit=0", "limit=101", "cursor=next",
                "snapshotId=\(Self.snapshot)", "unknown=1",
            ] {
                let response = try await server.request("GET", "/web/api/stats?" + rejected, headers: headers)
                XCTAssertEqual(response.status, 400, rejected)
                Self.assertSecurityHeaders(response)
            }
            let source = try await server.request("GET", "/web/api/stats", headers: headers)
            XCTAssertEqual(source.status, 200)
            let sourceBody: EngramServiceWebStatsResponse = try JSONDecoder().decode(
                EngramServiceWebStatsResponse.self, from: source.body)
            XCTAssertEqual(sourceBody.groupBy, .source)
            XCTAssertEqual(sourceBody.items.map(\.key), ["claude-code"])
            let ranged = try await server.request(
                "GET", "/web/api/stats?groupBy=day&since=2026-09-07&until=2026-09-13&excludeNoise=true&agents=only&limit=2",
                headers: headers)
            XCTAssertEqual(ranged.status, 200)
            let continued = try await server.request(
                "GET", "/web/api/stats?limit=2&snapshotId=\(Self.snapshot)&cursor=next",
                headers: headers)
            XCTAssertEqual(continued.status, 200)
        }
        XCTAssertEqual(recorders.stats.values.map(\.groupBy), [.source, .day, .source])
        XCTAssertEqual(recorders.stats.values.map(\.since), [nil, "2026-09-07", nil])
        XCTAssertEqual(recorders.stats.values.map(\.until), [nil, "2026-09-13", nil])
        XCTAssertEqual(recorders.stats.values.map(\.excludeNoise), [false, true, false])
        XCTAssertEqual(recorders.stats.values.map(\.agents), [.hide, .only, .hide])
        XCTAssertEqual(recorders.stats.values.map(\.limit), [50, 2, 2])
        XCTAssertEqual(recorders.stats.values[2].snapshotId, Self.snapshot)
        XCTAssertEqual(recorders.stats.values[2].cursor, "next")
        XCTAssertTrue(recorders.overview.values.isEmpty)
        XCTAssertTrue(recorders.sessions.values.isEmpty)
        XCTAssertTrue(recorders.detail.values.isEmpty)
        XCTAssertTrue(recorders.facets.values.isEmpty)
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testMakeSurfaceSocketRoundTripForStatsDTO_repro() async throws {
        let fixture = try metadataFixture()
        defer { fixture.stop() }
        try await withServer(factory: { path in
            try WebReadRoutes.makeSurface(socketPath: path)
        }) { server in
            let cookie = try await Self.login(server)
            let response = try await server.request(
                "GET", "/web/api/stats?groupBy=project&excludeNoise=true&limit=2",
                headers: Self.originHeaders + [("Cookie", cookie)])
            XCTAssertEqual(response.status, 200)
            let body: EngramServiceWebStatsResponse = try JSONDecoder().decode(
                EngramServiceWebStatsResponse.self, from: response.body)
            XCTAssertEqual(body.snapshotId, Self.snapshot)
            XCTAssertEqual(body.groupBy, .project)
            XCTAssertEqual(body.items.first?.key, "project_1")
            XCTAssertEqual(body.totals.sessionCount, 1)
        }
        XCTAssertEqual(fixture.requests.map(\.command), ["webStats"])
        let request = try JSONDecoder().decode(EngramServiceWebStatsRequest.self, from: try XCTUnwrap(fixture.requests.first?.payload))
        XCTAssertEqual(request.groupBy, .project)
        XCTAssertEqual(request.excludeNoise, true)
        XCTAssertEqual(request.limit, 2)
        XCTAssertNil(request.snapshotId)
        XCTAssertNil(request.cursor)
    }

    func testSettingsRejectsInvalidQueryBeforeReaderAndAcceptsExactContract_repro() async throws {
        let fixture = try fixture()
        defer { fixture.stop() }
        let recorders = A5bRouteRecorders()
        try await withServer(surface: recordingSurface(recorders: recorders)) { server in
            let cookie = try await Self.login(server)
            let headers = Self.originHeaders + [("Cookie", cookie)]
            for rejected in [
                "limit=0", "limit=101", "limit=01", "cursor=next",
                "snapshotId=\(Self.snapshot)", "unknown=1", "port=3457",
            ] {
                let response = try await server.request("GET", "/web/api/settings?" + rejected, headers: headers)
                XCTAssertEqual(response.status, 400, rejected)
                Self.assertSecurityHeaders(response)
            }
            let first = try await server.request("GET", "/web/api/settings", headers: headers)
            XCTAssertEqual(first.status, 200)
            let body: EngramServiceWebSettingsResponse = try JSONDecoder().decode(
                EngramServiceWebSettingsResponse.self, from: first.body)
            XCTAssertEqual(body.sources.map(\.key), ["claude-code"])
            XCTAssertEqual(body.totalSessions, 1)
            XCTAssertEqual(body.nodeName.availability, .unavailable)
            XCTAssertEqual(body.port.availability, .unavailable)
            let continued = try await server.request(
                "GET", "/web/api/settings?limit=2&snapshotId=\(Self.snapshot)&cursor=next",
                headers: headers)
            XCTAssertEqual(continued.status, 200)
        }
        XCTAssertEqual(recorders.settings.values.map(\.limit), [50, 2])
        XCTAssertEqual(recorders.settings.values[1].snapshotId, Self.snapshot)
        XCTAssertEqual(recorders.settings.values[1].cursor, "next")
        XCTAssertTrue(recorders.overview.values.isEmpty)
        XCTAssertTrue(recorders.sessions.values.isEmpty)
        XCTAssertTrue(recorders.detail.values.isEmpty)
        XCTAssertTrue(recorders.facets.values.isEmpty)
        XCTAssertTrue(recorders.stats.values.isEmpty)
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testMakeSurfaceSocketRoundTripForSettingsDTO_repro() async throws {
        let fixture = try metadataFixture()
        defer { fixture.stop() }
        try await withServer(factory: { path in
            try WebReadRoutes.makeSurface(socketPath: path)
        }) { server in
            let cookie = try await Self.login(server)
            let response = try await server.request(
                "GET", "/web/api/settings?limit=2",
                headers: Self.originHeaders + [("Cookie", cookie)])
            XCTAssertEqual(response.status, 200)
            let body: EngramServiceWebSettingsResponse = try JSONDecoder().decode(
                EngramServiceWebSettingsResponse.self, from: response.body)
            XCTAssertEqual(body.snapshotId, Self.snapshot)
            XCTAssertEqual(body.sources.map(\.key), ["claude-code"])
            XCTAssertEqual(body.aliases.first?.alias, "old_keep")
            XCTAssertEqual(body.aliases.first?.aliasLabel, "old_keep")
            XCTAssertEqual(body.aliases.first?.canonicalLabel, "project_1")
            XCTAssertEqual(body.port.availability, .unavailable)
        }
        XCTAssertEqual(fixture.requests.map(\.command), ["webSettings"])
        let request = try JSONDecoder().decode(EngramServiceWebSettingsRequest.self, from: try XCTUnwrap(fixture.requests.first?.payload))
        XCTAssertEqual(request.limit, 2)
        XCTAssertNil(request.snapshotId)
        XCTAssertNil(request.cursor)
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

    func testSearchAndStatusParseFiltersAndRejectInvalidMode_repro() async throws {
        let fixture = try fixture()
        defer { fixture.stop() }
        let recorders = A5bRouteRecorders()
        try await withServer(surface: recordingSurface(recorders: recorders)) { server in
            let cookie = try await Self.login(server)
            let headers = Self.originHeaders + [("Cookie", cookie)]
            for rejected in [
                "", "mode=semantic", "query=foo&mode=both", "query=foo&mode=keyword&mode=semantic",
                "query=foo&tools=yes", "query=foo&limit=51", "query=foo&unknown=1",
                "query=foo&snapshotId=\(Self.snapshot)", "query=foo&cursor=next",
            ] {
                let path = rejected.isEmpty ? "/web/api/search" : "/web/api/search?" + rejected
                let response = try await server.request("GET", path, headers: headers)
                XCTAssertEqual(response.status, 400, path)
                Self.assertSecurityHeaders(response)
            }
            let accepted = try await server.request(
                "GET",
                "/web/api/search?query=foo+bar&since=2026-09-07&until=2026-09-13&tools=hide&mode=semantic&limit=25",
                headers: headers)
            XCTAssertEqual(accepted.status, 200)
            let body: EngramServiceWebSearchResponse = try JSONDecoder().decode(
                EngramServiceWebSearchResponse.self, from: accepted.body)
            XCTAssertEqual(body.query, "foo+bar")
            XCTAssertNil(body.warning)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: accepted.body) as? [String: Any])
            XCTAssertNil(object["totalCount"])
            XCTAssertNil(object["nextCursor"])
            let statusRejected = try await server.request(
                "GET", "/web/api/search/status?query=foo", headers: headers)
            XCTAssertEqual(statusRejected.status, 400)
            let status = try await server.request(
                "GET", "/web/api/search/status?since=2026-09-07&tools=hide", headers: headers)
            XCTAssertEqual(status.status, 200)
            let statusBody: EngramServiceWebSearchStatusResponse = try JSONDecoder().decode(
                EngramServiceWebSearchStatusResponse.self, from: status.body)
            XCTAssertEqual(statusBody.eligibleSessionCount, 2)
            XCTAssertEqual(statusBody.embeddedSessionCount, 1)
            XCTAssertEqual(statusBody.progressPercent, 50)
            XCTAssertEqual(statusBody.model, "probe")
        }
        XCTAssertEqual(recorders.search.values.count, 1)
        let recorded = try XCTUnwrap(recorders.search.values.first)
        XCTAssertEqual(recorded.query, "foo+bar")
        XCTAssertEqual(recorded.since, "2026-09-07")
        XCTAssertEqual(recorded.until, "2026-09-13")
        XCTAssertEqual(recorded.tools, .hide)
        XCTAssertEqual(recorded.mode, .semantic)
        XCTAssertEqual(recorded.limit, 25)
        XCTAssertEqual(recorders.searchStatus.values.map(\.since), ["2026-09-07"])
        XCTAssertEqual(recorders.searchStatus.values.map(\.tools), [.hide])
        XCTAssertTrue(recorders.sessions.values.isEmpty)
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testSearchSemanticAliasAndPrefixedPathsStayClosed_repro() async throws {
        let fixture = try fixture()
        defer { fixture.stop() }
        let recorders = A5bRouteRecorders()
        try await withServer(surface: recordingSurface(recorders: recorders)) { server in
            let cookie = try await Self.login(server)
            for path in ["/web/api/search/", "/web/api/search/semantic", "/web/api/search/status/"] {
                let response = try await server.request(
                    "GET", path, headers: Self.originHeaders + [("Cookie", cookie)])
                XCTAssertEqual(response.status, 404, path)
                Self.assertSecurityHeaders(response)
            }
        }
        recorders.assertIdle()
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testMakeSurfaceSocketRoundTripForSearchAndStatusDTOs_repro() async throws {
        let fixture = try metadataFixture()
        defer { fixture.stop() }
        try await withServer(factory: { path in
            try WebReadRoutes.makeSurface(socketPath: path)
        }) { server in
            let cookie = try await Self.login(server)
            let headers = Self.originHeaders + [("Cookie", cookie)]
            let search = try await server.request(
                "GET", "/web/api/search?query=foo&limit=10", headers: headers)
            XCTAssertEqual(search.status, 200)
            let searchBody: EngramServiceWebSearchResponse = try JSONDecoder().decode(
                EngramServiceWebSearchResponse.self, from: search.body)
            XCTAssertEqual(searchBody.query, "foo")
            XCTAssertEqual(searchBody.items.first?.matchType, "keyword")
            let searchObject = try XCTUnwrap(JSONSerialization.jsonObject(with: search.body) as? [String: Any])
            XCTAssertNil(searchObject["totalCount"])
            let omitted = try await server.request("GET", "/web/api/search/status", headers: headers)
            XCTAssertEqual(omitted.status, 200)
            let omittedBody: EngramServiceWebSearchStatusResponse = try JSONDecoder().decode(
                EngramServiceWebSearchStatusResponse.self, from: omitted.body)
            XCTAssertNil(omittedBody.eligibleSessionCount)
            XCTAssertNil(omittedBody.embeddedSessionCount)
            XCTAssertNil(omittedBody.progressPercent)
            let omittedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: omitted.body) as? [String: Any])
            XCTAssertNil(omittedObject["eligibleSessionCount"])
            XCTAssertNil(omittedObject["embeddedSessionCount"])
            XCTAssertNil(omittedObject["progressPercent"])
            XCTAssertNil(omittedObject["model"])
        }
        XCTAssertEqual(fixture.requests.map(\.command), ["webSearch", "webSearchStatus"])
    }

    func testCostsRejectsInvalidQueryBeforeReaderAndAcceptsExactContract_repro() async throws {
        let fixture = try fixture()
        defer { fixture.stop() }
        let recorders = A5bRouteRecorders()
        try await withServer(surface: recordingSurface(recorders: recorders)) { server in
            let cookie = try await Self.login(server)
            let headers = Self.originHeaders + [("Cookie", cookie)]
            for rejected in [
                "groupBy=week", "groupBy=model&groupBy=source", "since=2026-9-07", "since=2026-02-30",
                "since=2026-09-13&until=2026-09-07", "agents=visible", "limit=0", "limit=101",
                "cursor=next", "snapshotId=\(Self.snapshot)", "unknown=1", "query=foo", "mode=keyword",
            ] {
                let response = try await server.request("GET", "/web/api/costs?" + rejected, headers: headers)
                XCTAssertEqual(response.status, 400, rejected)
                Self.assertSecurityHeaders(response)
            }
            let omitted = try await server.request("GET", "/web/api/costs", headers: headers)
            XCTAssertEqual(omitted.status, 200)
            let omittedBody: EngramServiceWebCostsResponse = try JSONDecoder().decode(
                EngramServiceWebCostsResponse.self, from: omitted.body)
            XCTAssertEqual(omittedBody.groupBy, .model)
            XCTAssertEqual(omittedBody.timeZone, "Asia/Shanghai")
            XCTAssertEqual(omittedBody.totals.sessionCount, 2)
            let ranged = try await server.request(
                "GET",
                "/web/api/costs?groupBy=day&since=2026-09-07&until=2026-09-13&tools=hide&agents=only&limit=2",
                headers: headers)
            XCTAssertEqual(ranged.status, 200)
            let continued = try await server.request(
                "GET", "/web/api/costs?limit=2&snapshotId=\(Self.snapshot)&cursor=next",
                headers: headers)
            XCTAssertEqual(continued.status, 200)
        }
        XCTAssertEqual(recorders.costs.values.map(\.groupBy), [.model, .day, .model])
        XCTAssertEqual(recorders.costs.values.map(\.since), [nil, "2026-09-07", nil])
        XCTAssertEqual(recorders.costs.values.map(\.until), [nil, "2026-09-13", nil])
        XCTAssertEqual(recorders.costs.values.map(\.tools), [.all, .hide, .all])
        XCTAssertEqual(recorders.costs.values.map(\.agents), [.hide, .only, .hide])
        XCTAssertEqual(recorders.costs.values.map(\.limit), [50, 2, 2])
        XCTAssertEqual(recorders.costs.values[2].snapshotId, Self.snapshot)
        XCTAssertEqual(recorders.costs.values[2].cursor, "next")
        XCTAssertTrue(recorders.costSessions.values.isEmpty)
        XCTAssertTrue(recorders.search.values.isEmpty)
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testCostSessionsRejectsCursorGroupByAndAcceptsTopN_repro() async throws {
        let fixture = try fixture()
        defer { fixture.stop() }
        let recorders = A5bRouteRecorders()
        try await withServer(surface: recordingSurface(recorders: recorders)) { server in
            let cookie = try await Self.login(server)
            let headers = Self.originHeaders + [("Cookie", cookie)]
            for rejected in [
                "groupBy=model", "snapshotId=\(Self.snapshot)", "cursor=next",
                "limit=0", "limit=101", "unknown=1", "query=foo",
            ] {
                let response = try await server.request(
                    "GET", "/web/api/costs/sessions?" + rejected, headers: headers)
                XCTAssertEqual(response.status, 400, rejected)
                Self.assertSecurityHeaders(response)
            }
            let accepted = try await server.request(
                "GET",
                "/web/api/costs/sessions?since=2026-09-07&until=2026-09-13&tools=hide&limit=20",
                headers: headers)
            XCTAssertEqual(accepted.status, 200)
            let body: EngramServiceWebCostSessionsResponse = try JSONDecoder().decode(
                EngramServiceWebCostSessionsResponse.self, from: accepted.body)
            XCTAssertEqual(body.items.count, 1)
            XCTAssertEqual(body.items.first?.session.sessionId, "session-a")
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: accepted.body) as? [String: Any])
            XCTAssertNil(object["totalCount"])
            XCTAssertNil(object["nextCursor"])
            let defaulted = try await server.request("GET", "/web/api/costs/sessions", headers: headers)
            XCTAssertEqual(defaulted.status, 200)
        }
        XCTAssertEqual(recorders.costSessions.values.map(\.limit), [20, 20])
        XCTAssertEqual(recorders.costSessions.values.map(\.since), ["2026-09-07", nil])
        XCTAssertEqual(recorders.costSessions.values.map(\.tools), [.hide, .all])
        XCTAssertTrue(recorders.costs.values.isEmpty)
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testCostsPrefixedPathsStayClosed_repro() async throws {
        let fixture = try fixture()
        defer { fixture.stop() }
        let recorders = A5bRouteRecorders()
        try await withServer(surface: recordingSurface(recorders: recorders)) { server in
            let cookie = try await Self.login(server)
            for path in ["/web/api/costs/", "/web/api/costs/day", "/web/api/costs/sessions/"] {
                let response = try await server.request(
                    "GET", path, headers: Self.originHeaders + [("Cookie", cookie)])
                XCTAssertEqual(response.status, 404, path)
                Self.assertSecurityHeaders(response)
            }
        }
        recorders.assertIdle()
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testMakeSurfaceSocketRoundTripForCostsDTOs_repro() async throws {
        let fixture = try metadataFixture()
        defer { fixture.stop() }
        try await withServer(factory: { path in
            try WebReadRoutes.makeSurface(socketPath: path)
        }) { server in
            let cookie = try await Self.login(server)
            let headers = Self.originHeaders + [("Cookie", cookie)]
            let costs = try await server.request(
                "GET", "/web/api/costs?groupBy=project&limit=2", headers: headers)
            XCTAssertEqual(costs.status, 200)
            let costsBody: EngramServiceWebCostsResponse = try JSONDecoder().decode(
                EngramServiceWebCostsResponse.self, from: costs.body)
            XCTAssertEqual(costsBody.groupBy, .project)
            XCTAssertEqual(costsBody.items.first?.key, "project_1")
            XCTAssertEqual(costsBody.totals.sessionCount, 2)
            let sessions = try await server.request(
                "GET", "/web/api/costs/sessions?limit=20", headers: headers)
            XCTAssertEqual(sessions.status, 200)
            let sessionsBody: EngramServiceWebCostSessionsResponse = try JSONDecoder().decode(
                EngramServiceWebCostSessionsResponse.self, from: sessions.body)
            XCTAssertEqual(sessionsBody.items.first?.costUsd, 1.25)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: sessions.body) as? [String: Any])
            XCTAssertNil(object["totalCount"])
            XCTAssertNil(object["nextCursor"])
        }
        XCTAssertEqual(fixture.requests.map(\.command), ["webCosts", "webCostSessions"])
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
            let cookie = try await Self.login(server)
            for path in ["/web/api/overview", "/web/api/sessions", "/web/api/sessions/session-a",
                         "/web/api/settings", "/web/api/search", "/web/api/search/status",
                         "/web/api/costs", "/web/api/costs/sessions"] {
                let unauthorized = try await server.request("GET", path, headers: Self.originHeaders)
                XCTAssertEqual(unauthorized.status, 401, path)
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
        detail: (@Sendable (EngramServiceWebSessionDetailRequest) async throws -> EngramServiceWebSessionDetailResponse)? = nil,
        facets: (@Sendable (EngramServiceWebFacetsRequest) async throws -> EngramServiceWebFacetsResponse)? = nil,
        stats: (@Sendable (EngramServiceWebStatsRequest) async throws -> EngramServiceWebStatsResponse)? = nil,
        settings: (@Sendable (EngramServiceWebSettingsRequest) async throws -> EngramServiceWebSettingsResponse)? = nil,
        search: (@Sendable (EngramServiceWebSearchRequest) async throws -> EngramServiceWebSearchResponse)? = nil,
        searchStatus: (@Sendable (EngramServiceWebSearchStatusRequest) async throws -> EngramServiceWebSearchStatusResponse)? = nil,
        costs: (@Sendable (EngramServiceWebCostsRequest) async throws -> EngramServiceWebCostsResponse)? = nil,
        costSessions: (@Sendable (EngramServiceWebCostSessionsRequest) async throws -> EngramServiceWebCostSessionsResponse)? = nil
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
            },
            facets: { request in
                recorders.facets.append(request)
                if let facets { return try await facets(request) }
                return Self.facetsPage(request)
            },
            stats: { request in
                recorders.stats.append(request)
                if let stats { return try await stats(request) }
                return Self.statsPage(request)
            },
            settings: { request in
                recorders.settings.append(request)
                if let settings { return try await settings(request) }
                return Self.settingsPage(request)
            },
            search: { request in
                recorders.search.append(request)
                if let search { return try await search(request) }
                return Self.searchPage(request)
            },
            searchStatus: { request in
                recorders.searchStatus.append(request)
                if let searchStatus { return try await searchStatus(request) }
                return Self.searchStatusPage(request)
            },
            costs: { request in
                recorders.costs.append(request)
                if let costs { return try await costs(request) }
                return Self.costsPage(request)
            },
            costSessions: { request in
                recorders.costSessions.append(request)
                if let costSessions { return try await costSessions(request) }
                return Self.costSessionsPage(request)
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
            case "webFacets":
                let input = try JSONDecoder().decode(EngramServiceWebFacetsRequest.self, from: try XCTUnwrap(request.payload))
                return try Self.success(Self.facetsPage(input), id: request.requestId)
            case "webStats":
                let input = try JSONDecoder().decode(EngramServiceWebStatsRequest.self, from: try XCTUnwrap(request.payload))
                return try Self.success(Self.statsPage(input), id: request.requestId)
            case "webSettings":
                let input = try JSONDecoder().decode(EngramServiceWebSettingsRequest.self, from: try XCTUnwrap(request.payload))
                return try Self.success(Self.settingsPage(input), id: request.requestId)
            case "webSearch":
                let input = try JSONDecoder().decode(EngramServiceWebSearchRequest.self, from: try XCTUnwrap(request.payload))
                return try Self.success(Self.searchPage(input), id: request.requestId)
            case "webSearchStatus":
                let input = try JSONDecoder().decode(EngramServiceWebSearchStatusRequest.self, from: try XCTUnwrap(request.payload))
                return try Self.success(Self.searchStatusPage(input, includeCounts: false), id: request.requestId)
            case "webCosts":
                let input = try JSONDecoder().decode(EngramServiceWebCostsRequest.self, from: try XCTUnwrap(request.payload))
                return try Self.success(Self.costsPage(input), id: request.requestId)
            case "webCostSessions":
                let input = try JSONDecoder().decode(EngramServiceWebCostSessionsRequest.self, from: try XCTUnwrap(request.payload))
                return try Self.success(Self.costSessionsPage(input), id: request.requestId)
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
        let isAgent: Bool?
        switch request.agents {
        case .hide: isAgent = false
        case .only: isAgent = true
        case .all: isAgent = nil
        }
        return EngramServiceWebSessionsResponse(
            snapshotId: request.snapshotId ?? snapshot, observedAt: 1,
            items: [.init(sessionId: request.sessionId ?? "session-a",
                          source: request.resolvedSources?.first ?? "claude-code",
                          captureIdentity: .init(machineId: request.machineId ?? machine,
                                                 sourceInstanceId: request.sourceInstanceId ?? instance),
                          metadataGeneration: String(repeating: "a", count: 64), title: nil,
                          projectKey: request.resolvedProjectKeys?.first, projectLabel: nil, startedAt: 1,
                          isAgent: isAgent, nativeId: request.sessionId)],
            nextCursor: request.cursor == nil ? nil : "after"
        )
    }

    private static func facetsPage(_ request: EngramServiceWebFacetsRequest) -> EngramServiceWebFacetsResponse {
        let key = request.kind == .source ? "claude-code" : "project_1"
        return EngramServiceWebFacetsResponse(
            snapshotId: request.snapshotId ?? snapshot, observedAt: 1,
            items: [.init(key: key, label: request.query ?? key, sessionCount: 1)],
            nextCursor: request.cursor == nil ? nil : "after"
        )
    }

    private static func settingsPage(_ request: EngramServiceWebSettingsRequest) -> EngramServiceWebSettingsResponse {
        EngramServiceWebSettingsResponse(
            snapshotId: request.snapshotId ?? snapshot, observedAt: 1,
            sources: [.init(key: "claude-code", label: "claude-code")],
            totalSessions: 1,
            aliases: [.init(alias: "old_keep", canonical: "project_1",
                            aliasLabel: "old_keep", canonicalLabel: "project_1")],
            nextCursor: request.cursor == nil ? nil : "after",
            nodeName: .init(), peers: .init(), port: .init()
        )
    }

    private static func statsPage(_ request: EngramServiceWebStatsRequest) -> EngramServiceWebStatsResponse {
        let key: String
        switch request.groupBy {
        case .source: key = "claude-code"
        case .project: key = "project_1"
        case .day, .week: key = request.since ?? "2026-09-07"
        }
        let item = EngramServiceWebStatsItem(key: key, label: key, sessionCount: 1, messageCount: 2,
            userMessageCount: 1, assistantMessageCount: 1, toolMessageCount: 0)
        return EngramServiceWebStatsResponse(
            snapshotId: request.snapshotId ?? snapshot, observedAt: 1, groupBy: request.groupBy,
            timeZone: "Asia/Shanghai",
            totals: .init(sessionCount: 1, messageCount: 2, userMessageCount: 1,
                          assistantMessageCount: 1, toolMessageCount: 0),
            items: [item], nextCursor: request.cursor == nil ? nil : "after"
        )
    }

    private static func searchPage(_ request: EngramServiceWebSearchRequest) -> EngramServiceWebSearchResponse {
        let isAgent: Bool?
        switch request.agents {
        case .hide: isAgent = false
        case .only: isAgent = true
        case .all: isAgent = nil
        }
        let session = EngramServiceWebSessionSummary(
            sessionId: request.sessionId ?? "session-a",
            source: request.resolvedSources?.first ?? "claude-code",
            captureIdentity: .init(machineId: request.machineId ?? machine,
                                   sourceInstanceId: request.sourceInstanceId ?? instance),
            metadataGeneration: String(repeating: "a", count: 64), title: nil,
            projectKey: request.resolvedProjectKeys?.first, projectLabel: nil,
            startedAt: 1_757_246_400, isAgent: isAgent, nativeId: request.sessionId)
        return EngramServiceWebSearchResponse(
            observedAt: 1, query: request.query,
            items: [.init(session: session, snippet: "hit", matchType: "keyword", score: 1)],
            searchModes: request.mode == .keyword ? ["keyword"] : [request.mode.rawValue],
            warning: nil, warningCode: nil
        )
    }

    private static func costsPage(_ request: EngramServiceWebCostsRequest) -> EngramServiceWebCostsResponse {
        let key: String
        switch request.groupBy {
        case .model: key = "claude-sonnet"
        case .source: key = "claude-code"
        case .project: key = "project_1"
        case .day: key = request.since ?? "2026-09-07"
        }
        let item = EngramServiceWebCostItem(
            key: key, label: key, costUsd: 1.25, inputTokens: 10, outputTokens: 4,
            cacheReadTokens: 1, cacheCreationTokens: 2, sessionCount: 1)
        return EngramServiceWebCostsResponse(
            snapshotId: request.snapshotId ?? snapshot, observedAt: 1, groupBy: request.groupBy,
            timeZone: "Asia/Shanghai",
            totals: .init(costUsd: 2.5, inputTokens: 20, outputTokens: 8,
                          cacheReadTokens: 2, cacheCreationTokens: 4, sessionCount: 2),
            items: [item], nextCursor: request.cursor == nil ? nil : "after",
            unpricedUnattributedSessions: 0, unpricedNoPriceSessions: 0,
            unpricedUnattributedTokens: 0, unpricedNoPriceTokens: 0)
    }

    private static func costSessionsPage(_ request: EngramServiceWebCostSessionsRequest) -> EngramServiceWebCostSessionsResponse {
        let isAgent: Bool?
        switch request.agents {
        case .hide: isAgent = false
        case .only: isAgent = true
        case .all: isAgent = nil
        }
        let session = EngramServiceWebSessionSummary(
            sessionId: request.sessionId ?? "session-a",
            source: request.resolvedSources?.first ?? "claude-code",
            captureIdentity: .init(machineId: request.machineId ?? machine,
                                   sourceInstanceId: request.sourceInstanceId ?? instance),
            metadataGeneration: String(repeating: "a", count: 64), title: nil,
            projectKey: request.resolvedProjectKeys?.first, projectLabel: nil,
            startedAt: 1_757_246_400, isAgent: isAgent, nativeId: request.sessionId)
        return EngramServiceWebCostSessionsResponse(
            observedAt: 1,
            items: [.init(session: session, costUsd: 1.25, model: "claude-sonnet",
                          inputTokens: 10, outputTokens: 4, cacheReadTokens: 1, cacheCreationTokens: 2)]
        )
    }

    private static func searchStatusPage(
        _ request: EngramServiceWebSearchStatusRequest,
        includeCounts: Bool = true
    ) -> EngramServiceWebSearchStatusResponse {
        EngramServiceWebSearchStatusResponse(
            observedAt: 1, keyword: .available, semantic: .unavailable, hybrid: .unavailable,
            warning: "Semantic search unavailable: embedding provider is not configured; returning keyword results only.",
            warningCode: "embeddingProviderUnavailable",
            model: includeCounts ? "probe" : nil,
            dimension: includeCounts ? 3 : nil,
            eligibleSessionCount: includeCounts ? 2 : nil,
            embeddedSessionCount: includeCounts ? 1 : nil,
            progressPercent: includeCounts ? 50 : nil
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
    let facets = A5bRecorder<EngramServiceWebFacetsRequest>()
    let stats = A5bRecorder<EngramServiceWebStatsRequest>()
    let settings = A5bRecorder<EngramServiceWebSettingsRequest>()
    let search = A5bRecorder<EngramServiceWebSearchRequest>()
    let searchStatus = A5bRecorder<EngramServiceWebSearchStatusRequest>()
    let costs = A5bRecorder<EngramServiceWebCostsRequest>()
    let costSessions = A5bRecorder<EngramServiceWebCostSessionsRequest>()

    func assertIdle(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(overview.values.isEmpty, "overview reader must not run", file: file, line: line)
        XCTAssertTrue(sessions.values.isEmpty, "sessions reader must not run", file: file, line: line)
        XCTAssertTrue(detail.values.isEmpty, "detail reader must not run", file: file, line: line)
        XCTAssertTrue(facets.values.isEmpty, "facets reader must not run", file: file, line: line)
        XCTAssertTrue(stats.values.isEmpty, "stats reader must not run", file: file, line: line)
        XCTAssertTrue(settings.values.isEmpty, "settings reader must not run", file: file, line: line)
        XCTAssertTrue(search.values.isEmpty, "search reader must not run", file: file, line: line)
        XCTAssertTrue(searchStatus.values.isEmpty, "search status reader must not run", file: file, line: line)
        XCTAssertTrue(costs.values.isEmpty, "costs reader must not run", file: file, line: line)
        XCTAssertTrue(costSessions.values.isEmpty, "cost sessions reader must not run", file: file, line: line)
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
