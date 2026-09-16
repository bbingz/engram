import Foundation
import Hummingbird

/// Typed read seam. Metadata GET routes map onto one stored Surface.
enum WebReadRoutes {
    typealias MessagesReader = @Sendable (EngramServiceWebMessagesRequest) async throws -> EngramServiceWebMessagesResponse
    typealias OverviewReader = @Sendable (EngramServiceWebOverviewRequest) async throws -> EngramServiceWebOverviewResponse
    typealias SessionsReader = @Sendable (EngramServiceWebSessionsRequest) async throws -> EngramServiceWebSessionsResponse
    typealias DetailReader = @Sendable (EngramServiceWebSessionDetailRequest) async throws -> EngramServiceWebSessionDetailResponse
    typealias FacetsReader = @Sendable (EngramServiceWebFacetsRequest) async throws -> EngramServiceWebFacetsResponse
    typealias StatsReader = @Sendable (EngramServiceWebStatsRequest) async throws -> EngramServiceWebStatsResponse
    typealias SettingsReader = @Sendable (EngramServiceWebSettingsRequest) async throws -> EngramServiceWebSettingsResponse
    typealias SearchReader = @Sendable (EngramServiceWebSearchRequest) async throws -> EngramServiceWebSearchResponse
    typealias SearchStatusReader = @Sendable (EngramServiceWebSearchStatusRequest) async throws -> EngramServiceWebSearchStatusResponse
    typealias CostsReader = @Sendable (EngramServiceWebCostsRequest) async throws -> EngramServiceWebCostsResponse
    typealias CostSessionsReader = @Sendable (EngramServiceWebCostSessionsRequest) async throws -> EngramServiceWebCostSessionsResponse
    typealias SourceSettingsReader = @Sendable () async throws -> EngramServiceWebSourceSettingsResponse
    typealias AiSettingsReader = @Sendable () async throws -> EngramServiceWebAiSettingsResponse
    typealias ChildrenReader = @Sendable (EngramServiceWebChildrenRequest) async throws -> EngramServiceWebChildrenResponse
    typealias TimelineReader = @Sendable (EngramServiceWebTimelineRequest) async throws -> EngramServiceWebTimelineResponse

    typealias UsageReader = @Sendable (EngramServiceWebUsageRequest) async throws -> EngramServiceWebUsageResponse
    typealias ToolAnalyticsReader = @Sendable (EngramServiceWebToolAnalyticsRequest) async throws -> EngramServiceWebToolAnalyticsResponse
    typealias FileActivityReader = @Sendable (EngramServiceWebFileActivityRequest) async throws -> EngramServiceWebFileActivityResponse
    typealias ReposReader = @Sendable (EngramServiceWebReposRequest) async throws -> EngramServiceWebReposResponse
    typealias AiAuditReader = @Sendable (EngramServiceWebAiAuditRequest) async throws -> EngramServiceWebAiAuditResponse
    typealias AiAuditDetailReader = @Sendable (EngramServiceWebAiAuditDetailRequest) async throws -> EngramServiceWebAiAuditDetailResponse
    typealias AiStatsReader = @Sendable (EngramServiceWebAiStatsRequest) async throws -> EngramServiceWebAiStatsResponse
    typealias InsightDetailReader = @Sendable (EngramServiceWebInsightDetailRequest) async throws -> EngramServiceWebInsightDetailResponse
    typealias ProjectCwdsReader = @Sendable (EngramServiceWebProjectCwdsRequest) async throws -> EngramServiceWebProjectCwdsResponse

    struct Surface: Sendable {
        var messages: MessagesReader
        var overview: OverviewReader
        var sessions: SessionsReader
        var detail: DetailReader
        var facets: FacetsReader = { _ in throw EngramServiceWebReadClientError.unsupported }
        var stats: StatsReader = { _ in throw EngramServiceWebReadClientError.unsupported }
        var settings: SettingsReader = { _ in throw EngramServiceWebReadClientError.unsupported }
        var search: SearchReader = { _ in throw EngramServiceWebReadClientError.unsupported }
        var searchStatus: SearchStatusReader = { _ in throw EngramServiceWebReadClientError.unsupported }
        var costs: CostsReader = { _ in throw EngramServiceWebReadClientError.unsupported }
        var costSessions: CostSessionsReader = { _ in throw EngramServiceWebReadClientError.unsupported }
        var sourceSettings: SourceSettingsReader = { throw EngramServiceWebReadClientError.unsupported }
        var aiSettings: AiSettingsReader = { throw EngramServiceWebReadClientError.unsupported }
        var children: ChildrenReader = { _ in throw EngramServiceWebReadClientError.unsupported }
        var timeline: TimelineReader = { _ in throw EngramServiceWebReadClientError.unsupported }
        var usage: UsageReader = { _ in throw EngramServiceWebReadClientError.unsupported }
        var toolAnalytics: ToolAnalyticsReader = { _ in throw EngramServiceWebReadClientError.unsupported }
        var fileActivity: FileActivityReader = { _ in throw EngramServiceWebReadClientError.unsupported }
        var repos: ReposReader = { _ in throw EngramServiceWebReadClientError.unsupported }
        var aiAudit: AiAuditReader = { _ in throw EngramServiceWebReadClientError.unsupported }
        var aiAuditDetail: AiAuditDetailReader = { _ in throw EngramServiceWebReadClientError.unsupported }
        var aiStats: AiStatsReader = { _ in throw EngramServiceWebReadClientError.unsupported }
        var insightDetail: InsightDetailReader = { _ in throw EngramServiceWebReadClientError.unsupported }
        var projectCwds: ProjectCwdsReader = { _ in throw EngramServiceWebReadClientError.unsupported }
    }

    typealias ClientFactory = @Sendable (String) throws -> Surface
    private static let maximumQueryBytes = 4096
    private static let messageQueryNames: Set<String> = ["generation", "roles", "cursor", "maxFragments"]
    private static let childrenQueryNames: Set<String> = ["limit", "snapshotId", "cursor"]
    private static let timelineQueryNames: Set<String> = ["generation", "offset", "limit"]
    private static let overviewQueryNames: Set<String> = ["limit", "snapshotId", "cursor"]
    private static let sessionsQueryNames: Set<String> = [
        "query", "source", "sources", "machineId", "sourceInstanceId", "projectKey", "projectKeys",
        "sessionId", "agents", "since", "until", "tools", "limit", "snapshotId", "cursor",
    ]
    private static let facetsQueryNames: Set<String> = [
        "kind", "query", "agents", "limit", "snapshotId", "cursor",
    ]
    private static let statsQueryNames: Set<String> = [
        "groupBy", "since", "until", "excludeNoise", "agents", "limit", "snapshotId", "cursor",
    ]
    private static let settingsQueryNames: Set<String> = ["limit", "snapshotId", "cursor"]
    private static let searchQueryNames: Set<String> = [
        "query", "source", "sources", "machineId", "sourceInstanceId", "projectKey", "projectKeys",
        "sessionId", "agents", "since", "until", "tools", "mode", "limit",
    ]
    private static let searchStatusQueryNames: Set<String> = [
        "source", "sources", "machineId", "sourceInstanceId", "projectKey", "projectKeys",
        "sessionId", "agents", "since", "until", "tools",
    ]
    private static let costsQueryNames: Set<String> = [
        "source", "sources", "machineId", "sourceInstanceId", "projectKey", "projectKeys",
        "sessionId", "agents", "since", "until", "tools", "groupBy", "limit", "snapshotId", "cursor",
    ]
    private static let costSessionsQueryNames: Set<String> = [
        "source", "sources", "machineId", "sourceInstanceId", "projectKey", "projectKeys",
        "sessionId", "agents", "since", "until", "tools", "limit",
    ]
    private static let fileActivityQueryNames: Set<String> = [
        "project", "since", "until", "agents", "limit", "snapshotId", "cursor",
    ]
    private static let reposQueryNames: Set<String> = ["limit", "snapshotId", "cursor"]
    private static let projectCwdsQueryNames: Set<String> = ["projectKey", "limit", "snapshotId", "cursor"]
    private static let aiAuditQueryNames: Set<String> = [
        "caller", "model", "sessionId", "from", "to", "hasError", "limit", "snapshotId", "cursor",
    ]
    private static let aiStatsQueryNames: Set<String> = ["from", "to"]
    private static let insightDetailQueryNames: Set<String> = ["offset", "limit", "revision"]

    static func makeSurface(socketPath: String) throws -> Surface {
        let client = try EngramServiceWebReadClient(socketPath: socketPath)
        return Surface(
            messages: { request in try await client.messages(request) },
            overview: { request in try await client.overview(request) },
            sessions: { request in try await client.sessions(request) },
            detail: { request in try await client.sessionDetail(request) },
            facets: { request in try await client.facets(request) },
            stats: { request in try await client.stats(request) },
            settings: { request in try await client.settings(request) },
            search: { request in try await client.search(request) },
            searchStatus: { request in try await client.searchStatus(request) },
            costs: { request in try await client.costs(request) },
            costSessions: { request in try await client.costSessions(request) },
            sourceSettings: { try await client.sourceSettings() },
            aiSettings: { try await client.aiSettings() },
            children: { request in try await client.children(request) },
            timeline: { request in try await client.timeline(request) },
            usage: { _ in try await client.usage() },
            toolAnalytics: { request in try await client.toolAnalytics(request) },
            fileActivity: { request in try await client.fileActivity(request) },
            repos: { request in try await client.repos(request) },
            aiAudit: { request in try await client.aiAudit(request) },
            aiAuditDetail: { request in try await client.aiAuditDetail(request) },
            aiStats: { request in try await client.aiStats(request) },
            insightDetail: { request in try await client.insightDetail(request) },
            projectCwds: { request in try await client.projectCwds(request) }
        )
    }

    static func messagesOnly(_ reader: @escaping MessagesReader) -> Surface {
        Surface(
            messages: reader,
            overview: { _ in throw EngramServiceWebReadClientError.unsupported },
            sessions: { _ in throw EngramServiceWebReadClientError.unsupported },
            detail: { _ in throw EngramServiceWebReadClientError.unsupported },
            facets: { _ in throw EngramServiceWebReadClientError.unsupported }
        )
    }

    static func makeReader(socketPath: String) throws -> MessagesReader {
        try makeSurface(socketPath: socketPath).messages
    }

    static func mount<Context: RequestContext>(on router: Router<Context>, surface: Surface) {
        router.get("/web/api/sessions/:id/messages") { request, context in
            let input: EngramServiceWebMessagesRequest
            do {
                input = try messagesRequest(request, rawSessionID: context.parameters.get("id"))
            } catch {
                return Response(status: .badRequest)
            }
            return try await respond(surface.messages, input)
        }
        router.get("/web/api/sessions/:id/children") { request, context in
            let input: EngramServiceWebChildrenRequest
            do {
                input = try childrenRequest(request, rawSessionID: context.parameters.get("id"))
            } catch {
                return Response(status: .badRequest)
            }
            return try await respond(surface.children, input)
        }
        router.get("/web/api/sessions/:id/timeline") { request, context in
            let input: EngramServiceWebTimelineRequest
            do {
                input = try timelineRequest(request, rawSessionID: context.parameters.get("id"))
            } catch {
                return Response(status: .badRequest)
            }
            return try await respond(surface.timeline, input)
        }
        router.get("/web/api/overview") { request, _ in
            let input: EngramServiceWebOverviewRequest
            do {
                input = try overviewRequest(request)
            } catch {
                return Response(status: .badRequest)
            }
            return try await respond(surface.overview, input)
        }
        router.get("/web/api/sessions") { request, _ in
            let input: EngramServiceWebSessionsRequest
            do {
                input = try sessionsRequest(request)
            } catch {
                return Response(status: .badRequest)
            }
            return try await respond(surface.sessions, input)
        }
        router.get("/web/api/sessions/:id") { request, context in
            let input: EngramServiceWebSessionDetailRequest
            do {
                input = try detailRequest(request, rawSessionID: context.parameters.get("id"))
            } catch {
                return Response(status: .badRequest)
            }
            return try await respond(surface.detail, input)
        }
        router.get("/web/api/facets") { request, _ in
            let input: EngramServiceWebFacetsRequest
            do {
                input = try facetsRequest(request)
            } catch {
                return Response(status: .badRequest)
            }
            return try await respond(surface.facets, input)
        }
        router.get("/web/api/stats") { request, _ in
            let input: EngramServiceWebStatsRequest
            do {
                input = try statsRequest(request)
            } catch {
                return Response(status: .badRequest)
            }
            return try await respond(surface.stats, input)
        }
        router.get("/web/api/settings") { request, _ in
            let input: EngramServiceWebSettingsRequest
            do {
                input = try settingsRequest(request)
            } catch {
                return Response(status: .badRequest)
            }
            return try await respond(surface.settings, input)
        }
        router.get("/web/api/search/status") { request, _ in
            let input: EngramServiceWebSearchStatusRequest
            do {
                input = try searchStatusRequest(request)
            } catch {
                return Response(status: .badRequest)
            }
            return try await respond(surface.searchStatus, input)
        }
        router.get("/web/api/search") { request, _ in
            let input: EngramServiceWebSearchRequest
            do {
                input = try searchRequest(request)
            } catch {
                return Response(status: .badRequest)
            }
            return try await respond(surface.search, input)
        }
        router.get("/web/api/costs/sessions") { request, _ in
            let input: EngramServiceWebCostSessionsRequest
            do {
                input = try costSessionsRequest(request)
            } catch {
                return Response(status: .badRequest)
            }
            return try await respond(surface.costSessions, input)
        }
        router.get("/web/api/usage") { request, _ in
            do { _ = try queryFields(request, names: []) } catch { return Response(status: .badRequest) }
            return try await respond(surface.usage, EngramServiceWebUsageRequest())
        }
        router.get("/web/api/tool-analytics") { request, _ in
            let input: EngramServiceWebToolAnalyticsRequest
            do { input = try toolAnalyticsRequest(request) } catch { return Response(status: .badRequest) }
            return try await respond(surface.toolAnalytics, input)
        }
        router.get("/web/api/file-activity") { request, _ in
            let input: EngramServiceWebFileActivityRequest
            do { input = try fileActivityRequest(request) } catch { return Response(status: .badRequest) }
            return try await respond(surface.fileActivity, input)
        }
        router.get("/web/api/repos") { request, _ in
            let input: EngramServiceWebReposRequest
            do { input = try reposRequest(request) } catch { return Response(status: .badRequest) }
            return try await respond(surface.repos, input)
        }
        router.get("/web/api/ai/audit") { request, _ in
            let input: EngramServiceWebAiAuditRequest
            do { input = try aiAuditRequest(request) } catch { return Response(status: .badRequest) }
            return try await respond(surface.aiAudit, input)
        }
        router.get("/web/api/ai/audit/:id") { request, context in
            let input: EngramServiceWebAiAuditDetailRequest
            do { input = try aiAuditDetailRequest(request, rawID: context.parameters.get("id")) }
            catch { return Response(status: .badRequest) }
            return try await respond(surface.aiAuditDetail, input)
        }
        router.get("/web/api/ai/stats") { request, _ in
            let input: EngramServiceWebAiStatsRequest
            do { input = try aiStatsRequest(request) } catch { return Response(status: .badRequest) }
            return try await respond(surface.aiStats, input)
        }
        router.get("/web/api/insights/:id") { request, context in
            let input: EngramServiceWebInsightDetailRequest
            do { input = try insightDetailRequest(request, rawID: context.parameters.get("id")) }
            catch { return Response(status: .badRequest) }
            return try await respond(surface.insightDetail, input)
        }
        router.get("/web/api/costs") { request, _ in
            let input: EngramServiceWebCostsRequest
            do {
                input = try costsRequest(request)
            } catch {
                return Response(status: .badRequest)
            }
            return try await respond(surface.costs, input)
        }
        router.get("/web/api/settings/sources") { request, _ in
            do { try sourceSettingsRequest(request) } catch { return Response(status: .badRequest) }
            return try await respond(surface.sourceSettings)
        }
        router.get("/web/api/settings/ai") { request, _ in
            do { try sourceSettingsRequest(request) } catch { return Response(status: .badRequest) }
            return try await respond(surface.aiSettings)
        }
        router.get("/web/api/projects/cwds") { request, _ in
            let input: EngramServiceWebProjectCwdsRequest
            do { input = try projectCwdsRequest(request) } catch { return Response(status: .badRequest) }
            return try await respond(surface.projectCwds, input)
        }
    }

    private static func respond<Output: Encodable>(
        _ reader: @escaping @Sendable () async throws -> Output
    ) async throws -> Response {
        try await respond({ (_: Bool) in try await reader() }, false)
    }

    private static func respond<Input: Sendable, Output: Encodable>(
        _ reader: @escaping @Sendable (Input) async throws -> Output,
        _ input: Input
    ) async throws -> Response {
        do {
            try Task.checkCancellation()
            let page = try await reader(input)
            try Task.checkCancellation()
            let encoded = try JSONEncoder().encode(page)
            guard encoded.count <= EngramServiceWebReadLimits.maximumPageEnvelopeBytes else {
                return Response(status: .badGateway)
            }
            return EngramRemoteServerApp.json(encoded)
        } catch let error as EngramServiceWebReadClientError {
            switch error {
            case .stale: return Response(status: .conflict)
            case .unsupported, .unavailable: return Response(status: .serviceUnavailable)
            case .notFound: return Response(status: .notFound)
            case .malformed: return Response(status: .badGateway)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return Response(status: .serviceUnavailable)
        }
    }

    private static func overviewRequest(_ request: Request) throws -> EngramServiceWebOverviewRequest {
        let fields = try queryFields(request, names: overviewQueryNames)
        let limit = try fields["limit"].map { try integer($0, name: "limit") } ?? 2
        return try EngramServiceWebOverviewRequest(
            limit: limit, snapshotId: fields["snapshotId"], cursor: fields["cursor"]
        )
    }

    private static func sessionsRequest(_ request: Request) throws -> EngramServiceWebSessionsRequest {
        let fields = try queryFields(request, names: sessionsQueryNames)
        let limit = try fields["limit"].map { try integer($0, name: "limit") } ?? 50
        return try EngramServiceWebSessionsRequest(
            query: fields["query"], source: fields["source"],
            sources: try fields["sources"].map { try commaList($0, name: "sources") },
            machineId: fields["machineId"], sourceInstanceId: fields["sourceInstanceId"],
            projectKey: fields["projectKey"],
            projectKeys: try fields["projectKeys"].map { try commaList($0, name: "projectKeys") },
            sessionId: fields["sessionId"],
            agents: try fields["agents"].map {
                guard let agents = EngramServiceWebAgentFilter(rawValue: $0) else {
                    throw EngramServiceWebReadError.invalidField("agents")
                }
                return agents
            } ?? .hide,
            since: fields["since"], until: fields["until"],
            tools: try fields["tools"].map {
                guard let tools = EngramServiceWebToolFilter(rawValue: $0) else {
                    throw EngramServiceWebReadError.invalidField("tools")
                }
                return tools
            } ?? .all,
            limit: limit, snapshotId: fields["snapshotId"], cursor: fields["cursor"]
        )
    }

    private static func facetsRequest(_ request: Request) throws -> EngramServiceWebFacetsRequest {
        let fields = try queryFields(request, names: facetsQueryNames)
        guard let rawKind = fields["kind"], let kind = EngramServiceWebFacetKind(rawValue: rawKind) else {
            throw EngramServiceWebReadError.invalidField("kind")
        }
        let limit = try fields["limit"].map { try integer($0, name: "limit") } ?? 50
        return try EngramServiceWebFacetsRequest(
            kind: kind, query: fields["query"],
            agents: try fields["agents"].map {
                guard let agents = EngramServiceWebAgentFilter(rawValue: $0) else {
                    throw EngramServiceWebReadError.invalidField("agents")
                }
                return agents
            } ?? .hide,
            limit: limit, snapshotId: fields["snapshotId"], cursor: fields["cursor"]
        )
    }

    private static func statsRequest(_ request: Request) throws -> EngramServiceWebStatsRequest {
        let fields = try queryFields(request, names: statsQueryNames)
        let groupBy = try fields["groupBy"].map { raw -> EngramServiceWebStatsGroupBy in
            guard let value = EngramServiceWebStatsGroupBy(rawValue: raw) else {
                throw EngramServiceWebReadError.invalidField("groupBy")
            }
            return value
        } ?? .source
        let excludeNoise = try fields["excludeNoise"].map { raw -> Bool in
            guard raw == "true" || raw == "false" else {
                throw EngramServiceWebReadError.invalidField("excludeNoise")
            }
            return raw == "true"
        } ?? false
        let limit = try fields["limit"].map { try integer($0, name: "limit") } ?? 50
        return try EngramServiceWebStatsRequest(
            groupBy: groupBy, since: fields["since"], until: fields["until"],
            excludeNoise: excludeNoise,
            agents: try fields["agents"].map {
                guard let agents = EngramServiceWebAgentFilter(rawValue: $0) else {
                    throw EngramServiceWebReadError.invalidField("agents")
                }
                return agents
            } ?? .hide,
            limit: limit, snapshotId: fields["snapshotId"], cursor: fields["cursor"]
        )
    }

    private static func sourceSettingsRequest(_ request: Request) throws {
        let fields = try queryFields(request, names: [])
        guard fields.isEmpty else { throw EngramServiceWebReadError.invalidField("query") }
    }

    private static func settingsRequest(_ request: Request) throws -> EngramServiceWebSettingsRequest {
        let fields = try queryFields(request, names: settingsQueryNames)
        let limit = try fields["limit"].map { try integer($0, name: "limit") } ?? 50
        return try EngramServiceWebSettingsRequest(
            limit: limit, snapshotId: fields["snapshotId"], cursor: fields["cursor"]
        )
    }

    private static func searchRequest(_ request: Request) throws -> EngramServiceWebSearchRequest {
        let fields = try queryFields(request, names: searchQueryNames)
        guard let query = fields["query"] else { throw EngramServiceWebReadError.invalidField("query") }
        let limit = try fields["limit"].map { try integer($0, name: "limit") } ?? 10
        return try EngramServiceWebSearchRequest(
            query: query, source: fields["source"],
            sources: try fields["sources"].map { try commaList($0, name: "sources") },
            machineId: fields["machineId"], sourceInstanceId: fields["sourceInstanceId"],
            projectKey: fields["projectKey"],
            projectKeys: try fields["projectKeys"].map { try commaList($0, name: "projectKeys") },
            sessionId: fields["sessionId"],
            agents: try fields["agents"].map {
                guard let agents = EngramServiceWebAgentFilter(rawValue: $0) else {
                    throw EngramServiceWebReadError.invalidField("agents")
                }
                return agents
            } ?? .hide,
            since: fields["since"], until: fields["until"],
            tools: try fields["tools"].map {
                guard let tools = EngramServiceWebToolFilter(rawValue: $0) else {
                    throw EngramServiceWebReadError.invalidField("tools")
                }
                return tools
            } ?? .all,
            mode: try fields["mode"].map {
                guard let mode = EngramServiceWebSearchMode(rawValue: $0) else {
                    throw EngramServiceWebReadError.invalidField("mode")
                }
                return mode
            } ?? .keyword,
            limit: limit
        )
    }

    private static func toolAnalyticsRequest(_ request: Request) throws -> EngramServiceWebToolAnalyticsRequest {
        let fields = try queryFields(request, names: ["project", "since", "until", "agents", "groupBy", "group_by", "limit", "snapshotId", "cursor"])
        guard fields["groupBy"] == nil || fields["group_by"] == nil else { throw EngramServiceWebReadError.invalidField("groupBy") }
        let groupBy = try (fields["groupBy"] ?? fields["group_by"]).map { raw in
            guard let value = EngramServiceWebToolAnalyticsGroupBy(rawValue: raw) else { throw EngramServiceWebReadError.invalidField("groupBy") }
            return value
        } ?? .tool
        let agents = try fields["agents"].map { raw in
            guard let value = EngramServiceWebAgentFilter(rawValue: raw) else { throw EngramServiceWebReadError.invalidField("agents") }
            return value
        } ?? .hide
        return try .init(project: fields["project"], since: fields["since"], until: fields["until"], agents: agents, groupBy: groupBy,
            limit: fields["limit"].map { try integer($0, name: "limit") } ?? 50, snapshotId: fields["snapshotId"], cursor: fields["cursor"])
    }

    private static func fileActivityRequest(_ request: Request) throws -> EngramServiceWebFileActivityRequest {
        let fields = try queryFields(request, names: fileActivityQueryNames)
        let agents = try fields["agents"].map { raw in
            guard let value = EngramServiceWebAgentFilter(rawValue: raw) else { throw EngramServiceWebReadError.invalidField("agents") }
            return value
        } ?? .hide
        return try .init(project: fields["project"], since: fields["since"], until: fields["until"], agents: agents,
            limit: fields["limit"].map { try integer($0, name: "limit") } ?? 100,
            snapshotId: fields["snapshotId"], cursor: fields["cursor"])
    }

    private static func reposRequest(_ request: Request) throws -> EngramServiceWebReposRequest {
        let fields = try queryFields(request, names: reposQueryNames)
        return try .init(limit: fields["limit"].map { try integer($0, name: "limit") } ?? 50,
            snapshotId: fields["snapshotId"], cursor: fields["cursor"])
    }

    private static func aiAuditRequest(_ request: Request) throws -> EngramServiceWebAiAuditRequest {
        let fields = try queryFields(request, names: aiAuditQueryNames)
        let hasError = try fields["hasError"].map { raw -> Bool in
            switch raw {
            case "true": return true
            case "false": return false
            default: throw EngramServiceWebReadError.invalidField("hasError")
            }
        }
        return try .init(caller: fields["caller"], model: fields["model"], sessionId: fields["sessionId"],
            from: fields["from"], to: fields["to"], hasError: hasError,
            limit: fields["limit"].map { try integer($0, name: "limit") } ?? 50,
            snapshotId: fields["snapshotId"], cursor: fields["cursor"])
    }

    private static func aiAuditDetailRequest(_ request: Request, rawID: String?) throws -> EngramServiceWebAiAuditDetailRequest {
        guard let rawID, !request.uri.string.contains("#") else {
            throw EngramServiceWebReadError.invalidField("id")
        }
        if let query = request.uri.query {
            guard query.utf8.count <= maximumQueryBytes, query.isEmpty else {
                throw EngramServiceWebReadError.invalidField("query")
            }
        }
        return try .init(id: try decodedComponent(rawID))
    }

    private static func aiStatsRequest(_ request: Request) throws -> EngramServiceWebAiStatsRequest {
        let fields = try queryFields(request, names: aiStatsQueryNames)
        return try .init(from: fields["from"], to: fields["to"])
    }

    private static func insightDetailRequest(
        _ request: Request, rawID: String?
    ) throws -> EngramServiceWebInsightDetailRequest {
        guard let rawID, !request.uri.string.contains("#") else {
            throw EngramServiceWebReadError.invalidField("id")
        }
        let fields = try queryFields(request, names: insightDetailQueryNames)
        return try .init(
            id: try decodedComponent(rawID),
            offset: try fields["offset"].map { try integer($0, name: "offset") } ?? 0,
            limit: try fields["limit"].map { try integer($0, name: "limit") } ?? 8000,
            revision: fields["revision"]
        )
    }

    private static func costsRequest(_ request: Request) throws -> EngramServiceWebCostsRequest {
        let fields = try queryFields(request, names: costsQueryNames)
        let limit = try fields["limit"].map { try integer($0, name: "limit") } ?? 50
        return try EngramServiceWebCostsRequest(
            source: fields["source"],
            sources: try fields["sources"].map { try commaList($0, name: "sources") },
            machineId: fields["machineId"], sourceInstanceId: fields["sourceInstanceId"],
            projectKey: fields["projectKey"],
            projectKeys: try fields["projectKeys"].map { try commaList($0, name: "projectKeys") },
            sessionId: fields["sessionId"],
            agents: try fields["agents"].map {
                guard let agents = EngramServiceWebAgentFilter(rawValue: $0) else {
                    throw EngramServiceWebReadError.invalidField("agents")
                }
                return agents
            } ?? .hide,
            since: fields["since"], until: fields["until"],
            tools: try fields["tools"].map {
                guard let tools = EngramServiceWebToolFilter(rawValue: $0) else {
                    throw EngramServiceWebReadError.invalidField("tools")
                }
                return tools
            } ?? .all,
            groupBy: try fields["groupBy"].map {
                guard let groupBy = EngramServiceWebCostsGroupBy(rawValue: $0) else {
                    throw EngramServiceWebReadError.invalidField("groupBy")
                }
                return groupBy
            } ?? .model,
            limit: limit, snapshotId: fields["snapshotId"], cursor: fields["cursor"]
        )
    }

    private static func costSessionsRequest(_ request: Request) throws -> EngramServiceWebCostSessionsRequest {
        let fields = try queryFields(request, names: costSessionsQueryNames)
        let limit = try fields["limit"].map { try integer($0, name: "limit") } ?? 20
        return try EngramServiceWebCostSessionsRequest(
            source: fields["source"],
            sources: try fields["sources"].map { try commaList($0, name: "sources") },
            machineId: fields["machineId"], sourceInstanceId: fields["sourceInstanceId"],
            projectKey: fields["projectKey"],
            projectKeys: try fields["projectKeys"].map { try commaList($0, name: "projectKeys") },
            sessionId: fields["sessionId"],
            agents: try fields["agents"].map {
                guard let agents = EngramServiceWebAgentFilter(rawValue: $0) else {
                    throw EngramServiceWebReadError.invalidField("agents")
                }
                return agents
            } ?? .hide,
            since: fields["since"], until: fields["until"],
            tools: try fields["tools"].map {
                guard let tools = EngramServiceWebToolFilter(rawValue: $0) else {
                    throw EngramServiceWebReadError.invalidField("tools")
                }
                return tools
            } ?? .all,
            limit: limit
        )
    }

    private static func searchStatusRequest(_ request: Request) throws -> EngramServiceWebSearchStatusRequest {
        let fields = try queryFields(request, names: searchStatusQueryNames)
        return try EngramServiceWebSearchStatusRequest(
            source: fields["source"],
            sources: try fields["sources"].map { try commaList($0, name: "sources") },
            machineId: fields["machineId"], sourceInstanceId: fields["sourceInstanceId"],
            projectKey: fields["projectKey"],
            projectKeys: try fields["projectKeys"].map { try commaList($0, name: "projectKeys") },
            sessionId: fields["sessionId"],
            agents: try fields["agents"].map {
                guard let agents = EngramServiceWebAgentFilter(rawValue: $0) else {
                    throw EngramServiceWebReadError.invalidField("agents")
                }
                return agents
            } ?? .hide,
            since: fields["since"], until: fields["until"],
            tools: try fields["tools"].map {
                guard let tools = EngramServiceWebToolFilter(rawValue: $0) else {
                    throw EngramServiceWebReadError.invalidField("tools")
                }
                return tools
            } ?? .all
        )
    }

    private static func childrenRequest(_ request: Request, rawSessionID: String?) throws -> EngramServiceWebChildrenRequest {
        guard let rawSessionID, rawSessionID.utf8.count <= EngramServiceWebReadLimits.maximumSessionIDBytes * 3,
              !request.uri.string.contains("#") else {
            throw EngramServiceWebReadError.invalidField("query")
        }
        let fields = try queryFields(request, names: childrenQueryNames)
        let limit = try fields["limit"].map { try integer($0, name: "limit") }
            ?? EngramServiceWebReadLimits.defaultChildrenLimit
        return try EngramServiceWebChildrenRequest(
            sessionId: try decodedComponent(rawSessionID),
            limit: limit, snapshotId: fields["snapshotId"], cursor: fields["cursor"]
        )
    }

    private static func timelineRequest(_ request: Request, rawSessionID: String?) throws -> EngramServiceWebTimelineRequest {
        guard let rawSessionID, rawSessionID.utf8.count <= EngramServiceWebReadLimits.maximumSessionIDBytes * 3,
              !request.uri.string.contains("#") else {
            throw EngramServiceWebReadError.invalidField("query")
        }
        let fields = try queryFields(request, names: timelineQueryNames)
        guard let generation = fields["generation"] else { throw EngramServiceWebReadError.invalidField("generation") }
        let offset = try fields["offset"].map { try integer($0, name: "offset") } ?? 0
        let limit = try fields["limit"].map { try integer($0, name: "limit") }
            ?? EngramServiceWebReadLimits.defaultTimelineLimit
        return try EngramServiceWebTimelineRequest(
            sessionId: try decodedComponent(rawSessionID), generation: generation, offset: offset, limit: limit
        )
    }

    private static func detailRequest(_ request: Request, rawSessionID: String?) throws -> EngramServiceWebSessionDetailRequest {
        guard let rawSessionID, rawSessionID.utf8.count <= EngramServiceWebReadLimits.maximumSessionIDBytes * 3,
              !request.uri.string.contains("#") else {
            throw EngramServiceWebReadError.invalidField("query")
        }
        if let query = request.uri.query {
            guard query.utf8.count <= maximumQueryBytes, query.isEmpty else {
                throw EngramServiceWebReadError.invalidField("query")
            }
        }
        return try EngramServiceWebSessionDetailRequest(sessionId: try decodedComponent(rawSessionID))
    }

    private static func messagesRequest(_ request: Request, rawSessionID: String?) throws -> EngramServiceWebMessagesRequest {
        guard let rawSessionID, rawSessionID.utf8.count <= EngramServiceWebReadLimits.maximumSessionIDBytes * 3,
              !request.uri.string.contains("#"), let query = request.uri.query,
              !query.isEmpty, query.utf8.count <= maximumQueryBytes else {
            throw EngramServiceWebReadError.invalidField("query")
        }
        let sessionID = try decodedComponent(rawSessionID)
        let fields = try decodeFields(query, names: messageQueryNames)
        guard let generation = fields["generation"] else { throw EngramServiceWebReadError.invalidField("generation") }
        let roles: [EngramServiceWebMessageRole]
        if let value = fields["roles"] {
            roles = try value.split(separator: ",", omittingEmptySubsequences: false).map {
                guard let role = EngramServiceWebMessageRole(rawValue: String($0)) else {
                    throw EngramServiceWebReadError.invalidField("roles")
                }
                return role
            }
        } else {
            roles = EngramServiceWebMessageRole.allCases
        }
        let maxFragments: Int
        if let value = fields["maxFragments"] {
            maxFragments = try integer(value, name: "maxFragments")
        } else {
            maxFragments = 50
        }
        return try EngramServiceWebMessagesRequest(sessionId: sessionID, generation: generation, roles: roles,
                                                   cursor: fields["cursor"], maxFragments: maxFragments)
    }

    private static func projectCwdsRequest(_ request: Request) throws -> EngramServiceWebProjectCwdsRequest {
        let fields = try queryFields(request, names: projectCwdsQueryNames)
        guard let projectKey = fields["projectKey"] else {
            throw EngramServiceWebReadError.invalidField("projectKey")
        }
        let limit = try fields["limit"].map { try integer($0, name: "limit") } ?? 50
        return try EngramServiceWebProjectCwdsRequest(
            projectKey: projectKey, limit: limit,
            snapshotId: fields["snapshotId"], cursor: fields["cursor"]
        )
    }

    private static func queryFields(_ request: Request, names: Set<String>) throws -> [String: String] {
        guard !request.uri.string.contains("#") else { throw EngramServiceWebReadError.invalidField("query") }
        guard let query = request.uri.query else { return [:] }
        guard query.utf8.count <= maximumQueryBytes else { throw EngramServiceWebReadError.invalidField("query") }
        if query.isEmpty { return [:] }
        return try decodeFields(query, names: names)
    }

    private static func decodeFields(_ query: String, names: Set<String>) throws -> [String: String] {
        var fields: [String: String] = [:]
        for field in query.split(separator: "&", omittingEmptySubsequences: false) {
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { throw EngramServiceWebReadError.invalidField("query") }
            let name = try decodedComponent(String(pair[0]))
            guard names.contains(name), fields[name] == nil else {
                throw EngramServiceWebReadError.invalidField("query")
            }
            fields[name] = try decodedComponent(String(pair[1]))
        }
        return fields
    }

    private static func commaList(_ value: String, name: String) throws -> [String] {
        try value.split(separator: ",", omittingEmptySubsequences: false).map { token in
            let item = String(token)
            guard !item.isEmpty else { throw EngramServiceWebReadError.invalidField(name) }
            return item
        }
    }

    private static func integer(_ value: String, name: String) throws -> Int {
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
              let parsed = Int(value), String(parsed) == value else {
            throw EngramServiceWebReadError.invalidField(name)
        }
        return parsed
    }

    private static func decodedComponent(_ value: String) throws -> String {
        // URL components preserve literal '+'. This is not application/x-www-form-urlencoded.
        guard let decoded = value.removingPercentEncoding,
              !decoded.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw EngramServiceWebReadError.invalidField("query")
        }
        return decoded
    }
}
