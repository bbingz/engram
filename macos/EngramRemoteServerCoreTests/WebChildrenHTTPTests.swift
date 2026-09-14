import CryptoKit
import Foundation
@testable import EngramRemoteServerCore
import XCTest

final class WebChildrenHTTPTests: XCTestCase {
    private static let viewer = "d6-children-viewer"
    private static let origin = "https://127.0.0.1"
    private static let snapshot = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("eg-d6-children-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testChildrenQueryMapsLimitLeaseAndRejectsPartialCursor() async throws {
        let recorder = ChildrenRecorder()
        recorder.page = EngramServiceWebChildrenResponse(
            sessionId: "parent-a", snapshotId: Self.snapshot, observedAt: 1_778_000_000,
            items: [], nextCursor: nil)
        try await withServer(children: recorder.readSurface()) { server in
            let cookie = try await Self.login(server)
            let listed = try await server.request(
                "GET", "/web/api/sessions/parent-a/children?limit=20&snapshotId=\(Self.snapshot)&cursor=nextpage",
                headers: Self.headers + [("Cookie", cookie)]
            )
            XCTAssertEqual(listed.status, 200)
            let body = try JSONDecoder().decode(EngramServiceWebChildrenResponse.self, from: listed.body)
            XCTAssertEqual(body.sessionId, "parent-a")
            XCTAssertNil(body.nextCursor)
            let invalid = try await server.request(
                "GET", "/web/api/sessions/parent-a/children?cursor=nextpage",
                headers: Self.headers + [("Cookie", cookie)]
            )
            XCTAssertEqual(invalid.status, 400)
        }
        XCTAssertEqual(recorder.requests.map(\.sessionId), ["parent-a"])
        XCTAssertEqual(recorder.requests.map(\.limit), [20])
        XCTAssertEqual(recorder.requests.map(\.snapshotId), [Self.snapshot])
        XCTAssertEqual(recorder.requests.map(\.cursor), ["nextpage"])
    }

    func testTimelineRequiresGenerationAndMapsOffsetLimit() async throws {
        let generation = String(repeating: "ab", count: 32)
        let recorder = TimelineRecorder()
        recorder.page = EngramServiceWebTimelineResponse(
            sessionId: "session-a", generation: generation, totalEntries: 2,
            entries: [
                EngramServiceWebTimelineEntry(index: 1, role: .user, type: .message, preview: "hello"),
            ],
            nextOffset: nil)
        try await withServer(children: { _ in throw EngramServiceWebReadClientError.unavailable },
                             timeline: recorder.readSurface()) { server in
            let cookie = try await Self.login(server)
            let missing = try await server.request(
                "GET", "/web/api/sessions/session-a/timeline?limit=2",
                headers: Self.headers + [("Cookie", cookie)]
            )
            XCTAssertEqual(missing.status, 400)
            let listed = try await server.request(
                "GET", "/web/api/sessions/session-a/timeline?generation=\(generation)&offset=1&limit=2",
                headers: Self.headers + [("Cookie", cookie)]
            )
            XCTAssertEqual(listed.status, 200)
            let body = try JSONDecoder().decode(EngramServiceWebTimelineResponse.self, from: listed.body)
            XCTAssertEqual(body.generation, generation)
            XCTAssertEqual(body.totalEntries, 2)
            XCTAssertNil(body.nextOffset)
        }
        XCTAssertEqual(recorder.requests.map(\.sessionId), ["session-a"])
        XCTAssertEqual(recorder.requests.map(\.offset), [1])
        XCTAssertEqual(recorder.requests.map(\.limit), [2])
        XCTAssertEqual(recorder.requests.map(\.generation), [generation])
    }

    func testToolAnalyticsMapsLegacyGroupFilterAndRejectsInvalidQueries() async throws {
        try await withServer(children: { _ in throw EngramServiceWebReadClientError.unsupported },
                             toolAnalytics: { request in
            XCTAssertEqual(request.groupBy, .project)
            XCTAssertEqual(request.project, "alpha")
            XCTAssertEqual(request.since, "2026-09-01")
            XCTAssertEqual(request.agents, .all)
            return .init(snapshotId: Self.snapshot, observedAt: 1_778_000_000, groupBy: .project,
                         totalCalls: 0, groupCount: 0, items: [], nextCursor: nil)
        }) { server in
            let cookie = try await Self.login(server)
            let headers = Self.headers + [("Cookie", cookie)]
            let response = try await server.request("GET",
                "/web/api/tool-analytics?group_by=project&project=alpha&since=2026-09-01&agents=all", headers: headers)
            XCTAssertEqual(response.status, 200)
            for query in ["groupBy=tool&group_by=project", "groupBy=unknown", "limit=0", "project=",
                          "since=2026-02-30", "cursor=next", "unexpected=1", "agents=all&agents=hide"] {
                let invalid = try await server.request("GET", "/web/api/tool-analytics?" + query, headers: headers)
                XCTAssertEqual(invalid.status, 400, query)
            }
            let unauthenticated = try await server.request("GET", "/web/api/tool-analytics", headers: Self.headers)
            XCTAssertEqual(unauthenticated.status, 401)
        }
    }

    func testFileActivityMapsFiltersDefaultLimitAndRejectsInvalidQueries() async throws {
        try await withServer(children: { _ in throw EngramServiceWebReadClientError.unsupported },
                             fileActivity: { request in
            XCTAssertEqual(request.project, "alpha")
            XCTAssertEqual(request.since, "2026-09-01")
            XCTAssertEqual(request.until, "2026-09-02")
            XCTAssertEqual(request.agents, .all)
            XCTAssertEqual(request.limit, 100)
            return .init(snapshotId: Self.snapshot, observedAt: 1_778_000_000,
                         totalFiles: 0, totalOperations: 0, items: [], nextCursor: nil)
        }) { server in
            let cookie = try await Self.login(server)
            let headers = Self.headers + [("Cookie", cookie)]
            let response = try await server.request("GET",
                "/web/api/file-activity?project=alpha&since=2026-09-01&until=2026-09-02&agents=all",
                headers: headers)
            XCTAssertEqual(response.status, 200)
            for query in ["limit=0", "project=", "since=2026-02-30", "cursor=next",
                          "unexpected=1", "agents=all&agents=hide", "groupBy=tool"] {
                let invalid = try await server.request("GET", "/web/api/file-activity?" + query, headers: headers)
                XCTAssertEqual(invalid.status, 400, query)
            }
            let unauthenticated = try await server.request("GET", "/web/api/file-activity", headers: Self.headers)
            XCTAssertEqual(unauthenticated.status, 401)
        }
    }

    func testReposMapsDefaultLimitLeaseAndRejectsInvalidQueries() async throws {
        let recorder = ReposRecorder()
        recorder.page = EngramServiceWebReposResponse(
            snapshotId: Self.snapshot, observedAt: 1_778_000_000, totalRepos: 0, items: [], nextCursor: nil)
        try await withServer(children: { _ in throw EngramServiceWebReadClientError.unsupported },
                             repos: recorder.readSurface()) { server in
            let cookie = try await Self.login(server)
            let headers = Self.headers + [("Cookie", cookie)]
            let listed = try await server.request("GET", "/web/api/repos", headers: headers)
            XCTAssertEqual(listed.status, 200)
            let body = try JSONDecoder().decode(EngramServiceWebReposResponse.self, from: listed.body)
            XCTAssertEqual(body.scope, "serverFilesystem")
            XCTAssertEqual(body.totalRepos, 0)
            let leased = try await server.request(
                "GET", "/web/api/repos?limit=20&snapshotId=\(Self.snapshot)&cursor=nextpage",
                headers: headers)
            XCTAssertEqual(leased.status, 200)
            for query in ["limit=0", "cursor=next", "unexpected=1", "project=alpha", "agents=hide"] {
                let invalid = try await server.request("GET", "/web/api/repos?" + query, headers: headers)
                XCTAssertEqual(invalid.status, 400, query)
            }
            let unauthenticated = try await server.request("GET", "/web/api/repos", headers: Self.headers)
            XCTAssertEqual(unauthenticated.status, 401)
        }
        XCTAssertEqual(recorder.requests.map(\.limit), [50, 20])
        XCTAssertEqual(recorder.requests.map(\.snapshotId), [nil, Self.snapshot])
        XCTAssertEqual(recorder.requests.map(\.cursor), [nil, "nextpage"])
    }

    func testAiAuditMapsFiltersDefaultLimitAndRejectsInvalidQueries() async throws {
        let recorder = AiAuditRecorder()
        recorder.page = EngramServiceWebAiAuditResponse(
            snapshotId: Self.snapshot, observedAt: 1_778_000_000, total: 0, items: [], nextCursor: nil)
        try await withServer(children: { _ in throw EngramServiceWebReadClientError.unsupported },
                             aiAudit: recorder.readSurface()) { server in
            let cookie = try await Self.login(server)
            let headers = Self.headers + [("Cookie", cookie)]
            let listed = try await server.request("GET", "/web/api/ai/audit", headers: headers)
            XCTAssertEqual(listed.status, 200)
            let filtered = try await server.request(
                "GET",
                "/web/api/ai/audit?caller=summary&model=provider/model:variant&sessionId=session-a&from=2026-09-01&to=2026-09-13&hasError=false&limit=20&snapshotId=\(Self.snapshot)&cursor=nextpage",
                headers: headers)
            XCTAssertEqual(filtered.status, 200)
            for query in ["unexpected=1", "hasError=yes", "limit=0", "cursor=next",
                          "from=2026-09-13&to=2026-09-01", "limit=101"] {
                let invalid = try await server.request("GET", "/web/api/ai/audit?" + query, headers: headers)
                XCTAssertEqual(invalid.status, 400, query)
            }
            let unauthenticated = try await server.request("GET", "/web/api/ai/audit", headers: Self.headers)
            XCTAssertEqual(unauthenticated.status, 401)
        }
        XCTAssertEqual(recorder.requests.map(\.limit), [50, 20])
        XCTAssertEqual(recorder.requests.last?.caller, "summary")
        XCTAssertEqual(recorder.requests.last?.model, "provider/model:variant")
        XCTAssertEqual(recorder.requests.last?.hasError, false)
        XCTAssertEqual(recorder.requests.last?.snapshotId, Self.snapshot)
    }

    func testAiAuditDetailRejectsQueryAndMapsNotFound() async throws {
        try await withServer(children: { _ in throw EngramServiceWebReadClientError.unsupported },
                             aiAuditDetail: { request in
            XCTAssertEqual(request.id, "12")
            throw EngramServiceWebReadClientError.notFound
        }) { server in
            let cookie = try await Self.login(server)
            let headers = Self.headers + [("Cookie", cookie)]
            let missing = try await server.request("GET", "/web/api/ai/audit/12", headers: headers)
            XCTAssertEqual(missing.status, 404)
            let withQuery = try await server.request("GET", "/web/api/ai/audit/12?limit=1", headers: headers)
            XCTAssertEqual(withQuery.status, 400)
            let unauthenticated = try await server.request("GET", "/web/api/ai/audit/12", headers: Self.headers)
            XCTAssertEqual(unauthenticated.status, 401)
        }
    }

    func testAiStatsMapsOneSidedDatesAndRejectsInvertedRange() async throws {
        let recorder = AiStatsRecorder()
        recorder.page = EngramServiceWebAiStatsResponse(
            observedAt: 1_778_000_000,
            timeRange: .init(from: "2026-09-12T00:00:00Z", to: "2026-09-13T12:00:00Z"),
            totals: .init(requests: 0, errors: 0, promptTokens: 0, completionTokens: 0, avgDurationMs: 0),
            byCaller: [], byModel: [], hourly: [])
        try await withServer(children: { _ in throw EngramServiceWebReadClientError.unsupported },
                             aiStats: recorder.readSurface()) { server in
            let cookie = try await Self.login(server)
            let headers = Self.headers + [("Cookie", cookie)]
            let both = try await server.request("GET", "/web/api/ai/stats", headers: headers)
            XCTAssertEqual(both.status, 200)
            let fromOnly = try await server.request("GET", "/web/api/ai/stats?from=2026-09-01", headers: headers)
            XCTAssertEqual(fromOnly.status, 200)
            let toOnly = try await server.request("GET", "/web/api/ai/stats?to=2026-09-13", headers: headers)
            XCTAssertEqual(toOnly.status, 200)
            let inverted = try await server.request(
                "GET", "/web/api/ai/stats?from=2026-09-13&to=2026-09-01", headers: headers)
            XCTAssertEqual(inverted.status, 400)
            let unknown = try await server.request("GET", "/web/api/ai/stats?sessionId=x", headers: headers)
            XCTAssertEqual(unknown.status, 400)
            let unauthenticated = try await server.request("GET", "/web/api/ai/stats", headers: Self.headers)
            XCTAssertEqual(unauthenticated.status, 401)
        }
        XCTAssertEqual(recorder.requests.map(\.from), [nil, "2026-09-01", nil])
        XCTAssertEqual(recorder.requests.map(\.to), [nil, nil, "2026-09-13"])
    }

    func testInsightDetailMapsPagingQueryAndAuth() async throws {
        let recorder = InsightDetailRecorder()
        recorder.page = EngramServiceWebInsightDetailResponse(
            id: "insight-global", revision: String(repeating: "ab", count: 32),
            offset: 0, totalLength: 4, content: "note", nextOffset: nil, sourceSessionId: nil)
        try await withServer(children: { _ in throw EngramServiceWebReadClientError.unsupported },
                             insightDetail: recorder.readSurface()) { server in
            let cookie = try await Self.login(server)
            let headers = Self.headers + [("Cookie", cookie)]
            let listed = try await server.request(
                "GET", "/web/api/insights/insight-global",
                headers: headers)
            XCTAssertEqual(listed.status, 200)
            let body = try JSONDecoder().decode(EngramServiceWebInsightDetailResponse.self, from: listed.body)
            XCTAssertEqual(body.id, "insight-global")
            XCTAssertNil(body.nextOffset)
            let paged = try await server.request(
                "GET", "/web/api/insights/insight-global?offset=0&limit=8000",
                headers: headers)
            XCTAssertEqual(paged.status, 200)
            let unknown = try await server.request(
                "GET", "/web/api/insights/insight-global?sessionId=x", headers: headers)
            XCTAssertEqual(unknown.status, 400)
            let zeroLimit = try await server.request(
                "GET", "/web/api/insights/insight-global?limit=0", headers: headers)
            XCTAssertEqual(zeroLimit.status, 400)
            let missingRevision = try await server.request(
                "GET", "/web/api/insights/insight-global?offset=1", headers: headers)
            XCTAssertEqual(missingRevision.status, 400)
            let unauthenticated = try await server.request(
                "GET", "/web/api/insights/insight-global", headers: Self.headers)
            XCTAssertEqual(unauthenticated.status, 401)
        }
        XCTAssertEqual(recorder.requests.map(\.id), ["insight-global", "insight-global"])
        XCTAssertEqual(recorder.requests.map(\.limit), [8000, 8000])
        XCTAssertEqual(recorder.requests.first?.offset, 0)
    }

    func testInsightDetailNotFoundAndStaleMapToSafeStatuses() async throws {
        try await withServer(children: { _ in throw EngramServiceWebReadClientError.unsupported },
                             insightDetail: { request in
            if request.revision != nil { throw EngramServiceWebReadClientError.stale }
            throw EngramServiceWebReadClientError.notFound
        }) { server in
            let cookie = try await Self.login(server)
            let headers = Self.headers + [("Cookie", cookie)]
            let missing = try await server.request("GET", "/web/api/insights/missing-insight", headers: headers)
            XCTAssertEqual(missing.status, 404)
            let stale = try await server.request(
                "GET",
                "/web/api/insights/insight-global?offset=1&revision=\(String(repeating: "ab", count: 32))",
                headers: headers)
            XCTAssertEqual(stale.status, 409)
        }
    }

    func testUsageReadRequiresViewerAndRejectsUnknownFilters() async throws {
        try await withServer(children: { _ in throw EngramServiceWebReadClientError.unsupported },
                             usage: { _ in .init(observedAt: 1_778_000_000, items: []) }) { server in
            let cookie = try await Self.login(server)
            let response = try await server.request("GET", "/web/api/usage", headers: Self.headers + [("Cookie", cookie)])
            XCTAssertEqual(response.status, 200)
            let body = try JSONDecoder().decode(EngramServiceWebUsageResponse.self, from: response.body)
            XCTAssertEqual(body.scope, "server")
            let invalid = try await server.request("GET", "/web/api/usage?refresh=true", headers: Self.headers + [("Cookie", cookie)])
            XCTAssertEqual(invalid.status, 400)
            let unauthenticated = try await server.request("GET", "/web/api/usage", headers: Self.headers)
            XCTAssertEqual(unauthenticated.status, 401)
        }
    }

    private func withServer(
        children: @escaping WebReadRoutes.ChildrenReader,
        timeline: @escaping WebReadRoutes.TimelineReader = { _ in throw EngramServiceWebReadClientError.unsupported },
        toolAnalytics: @escaping WebReadRoutes.ToolAnalyticsReader = { _ in throw EngramServiceWebReadClientError.unsupported },
        fileActivity: @escaping WebReadRoutes.FileActivityReader = { _ in throw EngramServiceWebReadClientError.unsupported },
        usage: @escaping WebReadRoutes.UsageReader = { _ in throw EngramServiceWebReadClientError.unsupported },
        repos: @escaping WebReadRoutes.ReposReader = { _ in throw EngramServiceWebReadClientError.unsupported },
        aiAudit: @escaping WebReadRoutes.AiAuditReader = { _ in throw EngramServiceWebReadClientError.unsupported },
        aiAuditDetail: @escaping WebReadRoutes.AiAuditDetailReader = { _ in throw EngramServiceWebReadClientError.unsupported },
        aiStats: @escaping WebReadRoutes.AiStatsReader = { _ in throw EngramServiceWebReadClientError.unsupported },
        insightDetail: @escaping WebReadRoutes.InsightDetailReader = { _ in throw EngramServiceWebReadClientError.unsupported },
        operation: (D4HTTPServer) async throws -> Void
    ) async throws {
        var surface = WebReadRoutes.messagesOnly({ _ in throw EngramServiceWebReadClientError.unavailable })
        surface.children = children
        surface.timeline = timeline
        surface.usage = usage
        surface.toolAnalytics = toolAnalytics
        surface.fileActivity = fileActivity
        surface.repos = repos
        surface.aiAudit = aiAudit
        surface.aiAuditDetail = aiAuditDetail
        surface.aiStats = aiStats
        surface.insightDetail = insightDetail
        let app = try EngramRemoteServerApp(
            config: try EngramRemoteServerConfig(
                host: "127.0.0.1", port: 0, storeRoot: directory.appendingPathComponent("legacy"),
                bearerToken: "d6-bearer", atRestKey: SymmetricKey(data: Data(repeating: 1, count: 32)),
                web: try EngramRemoteWebConfig(
                    origin: Self.origin, viewerCredential: Self.viewer,
                    serverBearerCredentials: ["d6-bearer"], editorCredential: nil
                ),
                webServiceSocketPath: directory.appendingPathComponent("service.sock").path
            ),
            webReadClientFactory: { _ in surface }
        )
        let server = try await D4HTTPServer(app: app)
        do { try await operation(server) } catch {
            do { try await server.stop() } catch { XCTFail("Server cleanup failed: \(error)") }
            throw error
        }
        try await server.stop()
    }

    private static var headers: [(String, String)] {
        [("X-Engram-Web", "1"), ("Origin", origin)]
    }

    private static func login(_ server: D4HTTPServer) async throws -> String {
        let body = Data("{\"credential\":\"\(viewer)\"}".utf8)
        let response = try await server.request(
            "POST", "/web/api/auth",
            headers: headers + [("Content-Type", "application/json")],
            body: body
        )
        XCTAssertEqual(response.status, 204)
        return try XCTUnwrap(response.header("set-cookie")?.split(separator: ";").first.map(String.init))
    }
}

private final class ChildrenRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [EngramServiceWebChildrenRequest] = []
    var page: EngramServiceWebChildrenResponse?
    var requests: [EngramServiceWebChildrenRequest] { lock.lock(); defer { lock.unlock() }; return calls }

    func readSurface() -> WebReadRoutes.ChildrenReader {
        { request in
            self.lock.lock(); self.calls.append(request); self.lock.unlock()
            return try XCTUnwrap(self.page)
        }
    }
}

private final class ReposRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [EngramServiceWebReposRequest] = []
    var page: EngramServiceWebReposResponse?
    var requests: [EngramServiceWebReposRequest] { lock.lock(); defer { lock.unlock() }; return calls }

    func readSurface() -> WebReadRoutes.ReposReader {
        { request in
            self.lock.lock(); self.calls.append(request); self.lock.unlock()
            return try XCTUnwrap(self.page)
        }
    }
}

private final class AiAuditRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [EngramServiceWebAiAuditRequest] = []
    var page: EngramServiceWebAiAuditResponse?
    var requests: [EngramServiceWebAiAuditRequest] { lock.lock(); defer { lock.unlock() }; return calls }

    func readSurface() -> WebReadRoutes.AiAuditReader {
        { request in
            self.lock.lock(); self.calls.append(request); self.lock.unlock()
            return try XCTUnwrap(self.page)
        }
    }
}

private final class AiStatsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [EngramServiceWebAiStatsRequest] = []
    var page: EngramServiceWebAiStatsResponse?
    var requests: [EngramServiceWebAiStatsRequest] { lock.lock(); defer { lock.unlock() }; return calls }

    func readSurface() -> WebReadRoutes.AiStatsReader {
        { request in
            self.lock.lock(); self.calls.append(request); self.lock.unlock()
            return try XCTUnwrap(self.page)
        }
    }
}

private final class InsightDetailRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [EngramServiceWebInsightDetailRequest] = []
    var page: EngramServiceWebInsightDetailResponse?
    var requests: [EngramServiceWebInsightDetailRequest] { lock.lock(); defer { lock.unlock() }; return calls }

    func readSurface() -> WebReadRoutes.InsightDetailReader {
        { request in
            self.lock.lock(); self.calls.append(request); self.lock.unlock()
            return try XCTUnwrap(self.page)
        }
    }
}

private final class TimelineRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [EngramServiceWebTimelineRequest] = []
    var page: EngramServiceWebTimelineResponse?
    var requests: [EngramServiceWebTimelineRequest] { lock.lock(); defer { lock.unlock() }; return calls }

    func readSurface() -> WebReadRoutes.TimelineReader {
        { request in
            self.lock.lock(); self.calls.append(request); self.lock.unlock()
            return try XCTUnwrap(self.page)
        }
    }
}
