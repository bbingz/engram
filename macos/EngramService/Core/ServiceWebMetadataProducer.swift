import CryptoKit
import Foundation
import GRDB
import SQLite3
import EngramCoreRead
import EngramCoreWrite

enum ServiceWebMetadataError: Error, Equatable, Sendable {
    case notImplemented
    case unavailable
    case stale
    case invalidRequest
    case notFound
    case responseTooLarge
}

enum ServiceWebMetadataLimits {
    static let maximumSnapshots = 8
    static let maximumCursorPositions = 128
    static let leaseLifetime: Duration = .seconds(30)
    static let maximumRequestDuration: Duration = .seconds(2)
    static let maximumSearchDuration: Duration = .seconds(8)
    static let sortVersion = "web-metadata-order-v1"
}

struct ServiceWebMetadataPolicy: Equatable, Sendable {
    var parserRevision: String
    var enabledSources: Set<SourceName>
}

struct ServiceWebMetadataExpiryHandle: Sendable {
    let id: UUID
    let cancel: @Sendable () -> Void
}

struct ServiceWebMetadataClock: Sendable {
    var now: @Sendable () -> ContinuousClock.Instant
    var schedule: @Sendable (ContinuousClock.Instant, @escaping @Sendable () -> Void) -> ServiceWebMetadataExpiryHandle

    static var live: ServiceWebMetadataClock {
        ServiceWebMetadataClock(
            now: { ContinuousClock.now },
            schedule: { deadline, fire in
                let id = UUID()
                let queue = DispatchQueue(label: "com.engram.service.web-metadata.expiry.\(id.uuidString)")
                let timer = DispatchSource.makeTimerSource(queue: queue)
                let remaining = deadline - ContinuousClock.now
                let seconds = max(0, Double(remaining.components.seconds)
                    + Double(remaining.components.attoseconds) / 1e18)
                timer.schedule(deadline: .now() + seconds, leeway: .milliseconds(1))
                timer.setEventHandler(handler: fire)
                timer.resume()
                return ServiceWebMetadataExpiryHandle(id: id) {
                    timer.cancel()
                }
            }
        )
    }

    /// Cancel and join `operation` at `deadline`. Does not clamp to the 2s metadata cap.
    func run<Value: Sendable>(
        until deadline: ContinuousClock.Instant,
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        if now() >= deadline { throw ServiceWebMetadataError.unavailable }
        let work = Task { try await operation() }
        let expiry = schedule(deadline) { work.cancel() }
        do {
            let value = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
            expiry.cancel()
            try Task.checkCancellation()
            if now() >= deadline { throw ServiceWebMetadataError.unavailable }
            return value
        } catch is CancellationError {
            expiry.cancel()
            if Task.isCancelled { throw CancellationError() }
            throw ServiceWebMetadataError.unavailable
        } catch {
            expiry.cancel()
            throw error
        }
    }
}

enum ServiceWebMetadataOperation: Equatable, Sendable {
    case overview, sessions, detail, children, facets, stats, settings, costs, costSessions, toolAnalytics, fileActivity, repos, projectCwds, aiAudit, aiAuditDetail, aiStats, search, insightDetail
}

enum ServiceWebMetadataDatabasePhase: Equatable, Sendable {
    case snapshotConnectionSetup, snapshotRead
}

/// Synchronous observers of the production connection and request scopes.
struct ServiceWebMetadataTestHooks {
    /// Called on EVERY producer pool/snapshot connection, after reader pragmas.
    /// Observers install authorizer/trace probes here, never interrupt handlers.
    var prepareDatabase: ((Database) throws -> Void)?
    /// After a would-be response is prepared, outside its read callback and
    /// before fresh policy/registry/row-authority reads. Includes first pages.
    var afterPreparation: ((ServiceWebMetadataOperation) throws -> Void)?
    /// Borrowed Database must not escape this synchronous callback. Run inside
    /// the REAL operation's installed cancellation/deadline/progress scope:
    /// snapshotConnectionSetup = snapshot prepareDatabase before initial BEGIN;
    /// snapshotRead = snapshot.read closure before metadata SQL. A before-call
    /// hook or a hook after query completion cannot satisfy this contract.
    var inDatabaseOperation: ((ServiceWebMetadataDatabasePhase, Database) throws -> Void)?
}

protocol ServiceWebMetadataProviding: AnyObject, Sendable {
    func overview(
        _ request: EngramServiceWebOverviewRequest,
        requestId: String,
        deadline: ContinuousClock.Instant
    ) async throws -> EngramServiceWebOverviewResponse

    func sessions(
        _ request: EngramServiceWebSessionsRequest,
        requestId: String,
        deadline: ContinuousClock.Instant
    ) async throws -> EngramServiceWebSessionsResponse

    func sessionDetail(
        _ request: EngramServiceWebSessionDetailRequest,
        requestId: String,
        deadline: ContinuousClock.Instant
    ) async throws -> EngramServiceWebSessionDetailResponse

    func children(
        _ request: EngramServiceWebChildrenRequest,
        requestId: String,
        deadline: ContinuousClock.Instant
    ) async throws -> EngramServiceWebChildrenResponse

    func facets(
        _ request: EngramServiceWebFacetsRequest,
        requestId: String,
        deadline: ContinuousClock.Instant
    ) async throws -> EngramServiceWebFacetsResponse

    func stats(
        _ request: EngramServiceWebStatsRequest,
        requestId: String,
        deadline: ContinuousClock.Instant
    ) async throws -> EngramServiceWebStatsResponse

    func settings(
        _ request: EngramServiceWebSettingsRequest,
        requestId: String,
        deadline: ContinuousClock.Instant
    ) async throws -> EngramServiceWebSettingsResponse

    func searchScope(
        _ request: EngramServiceWebSearchRequest,
        requestId: String,
        deadline: ContinuousClock.Instant
    ) async throws -> EngramServiceSearchScope

    func admitSearch(
        _ request: EngramServiceWebSearchRequest,
        ranked: EngramServiceSearchResponse,
        requestId: String,
        deadline: ContinuousClock.Instant
    ) async throws -> EngramServiceWebSearchResponse

    func insightDetail(
        _ request: EngramServiceWebInsightDetailRequest,
        requestId: String,
        deadline: ContinuousClock.Instant
    ) async throws -> EngramServiceWebInsightDetailResponse

    func searchStatus(
        _ request: EngramServiceWebSearchStatusRequest,
        requestId: String,
        deadline: ContinuousClock.Instant
    ) async throws -> EngramServiceWebSearchStatusResponse

    func costs(
        _ request: EngramServiceWebCostsRequest,
        requestId: String,
        deadline: ContinuousClock.Instant
    ) async throws -> EngramServiceWebCostsResponse

    func costSessions(
        _ request: EngramServiceWebCostSessionsRequest,
        requestId: String,
        deadline: ContinuousClock.Instant
    ) async throws -> EngramServiceWebCostSessionsResponse

    func toolAnalytics(
        _ request: EngramServiceWebToolAnalyticsRequest,
        requestId: String,
        deadline: ContinuousClock.Instant
    ) async throws -> EngramServiceWebToolAnalyticsResponse

    func fileActivity(
        _ request: EngramServiceWebFileActivityRequest,
        requestId: String,
        deadline: ContinuousClock.Instant
    ) async throws -> EngramServiceWebFileActivityResponse

    func repos(
        _ request: EngramServiceWebReposRequest,
        requestId: String,
        deadline: ContinuousClock.Instant
    ) async throws -> EngramServiceWebReposResponse

    func projectCwds(
        _ request: EngramServiceWebProjectCwdsRequest,
        requestId: String,
        deadline: ContinuousClock.Instant
    ) async throws -> EngramServiceWebProjectCwdsResponse

    func aiAudit(
        _ request: EngramServiceWebAiAuditRequest,
        requestId: String,
        deadline: ContinuousClock.Instant
    ) async throws -> EngramServiceWebAiAuditResponse

    func aiAuditDetail(
        _ request: EngramServiceWebAiAuditDetailRequest,
        requestId: String,
        deadline: ContinuousClock.Instant
    ) async throws -> EngramServiceWebAiAuditDetailResponse

    func aiStats(
        _ request: EngramServiceWebAiStatsRequest,
        requestId: String,
        deadline: ContinuousClock.Instant
    ) async throws -> EngramServiceWebAiStatsResponse

    func usage(_ request: EngramServiceWebUsageRequest, requestId: String,
               deadline: ContinuousClock.Instant) async throws -> EngramServiceWebUsageResponse

    func addProjectAlias(
        _ request: EngramServiceWebAddAliasRequest,
        writer: EngramDatabaseWriter
    ) throws -> EngramServiceWebAliasMutationResponse

    func removeProjectAlias(
        _ request: EngramServiceWebRemoveAliasRequest,
        writer: EngramDatabaseWriter
    ) throws -> EngramServiceWebAliasMutationResponse

    func stop() throws
}

extension ServiceWebMetadataProviding {
    func usage(_ request: EngramServiceWebUsageRequest, requestId: String,
               deadline: ContinuousClock.Instant) async throws -> EngramServiceWebUsageResponse {
        throw ServiceWebMetadataError.unavailable
    }

    func toolAnalytics(_ request: EngramServiceWebToolAnalyticsRequest, requestId: String,
                       deadline: ContinuousClock.Instant) async throws -> EngramServiceWebToolAnalyticsResponse {
        throw ServiceWebMetadataError.unavailable
    }

    func fileActivity(_ request: EngramServiceWebFileActivityRequest, requestId: String,
                      deadline: ContinuousClock.Instant) async throws -> EngramServiceWebFileActivityResponse {
        throw ServiceWebMetadataError.unavailable
    }

    func repos(_ request: EngramServiceWebReposRequest, requestId: String,
               deadline: ContinuousClock.Instant) async throws -> EngramServiceWebReposResponse {
        throw ServiceWebMetadataError.unavailable
    }

    func projectCwds(_ request: EngramServiceWebProjectCwdsRequest, requestId: String,
                     deadline: ContinuousClock.Instant) async throws -> EngramServiceWebProjectCwdsResponse {
        throw ServiceWebMetadataError.unavailable
    }

    func aiAudit(_ request: EngramServiceWebAiAuditRequest, requestId: String,
                 deadline: ContinuousClock.Instant) async throws -> EngramServiceWebAiAuditResponse {
        throw ServiceWebMetadataError.unavailable
    }

    func aiAuditDetail(_ request: EngramServiceWebAiAuditDetailRequest, requestId: String,
                       deadline: ContinuousClock.Instant) async throws -> EngramServiceWebAiAuditDetailResponse {
        throw ServiceWebMetadataError.unavailable
    }

    func aiStats(_ request: EngramServiceWebAiStatsRequest, requestId: String,
                 deadline: ContinuousClock.Instant) async throws -> EngramServiceWebAiStatsResponse {
        throw ServiceWebMetadataError.unavailable
    }

    func children(
        _ request: EngramServiceWebChildrenRequest,
        requestId: String,
        deadline: ContinuousClock.Instant
    ) async throws -> EngramServiceWebChildrenResponse {
        throw ServiceWebMetadataError.unavailable
    }

    func facets(
        _ request: EngramServiceWebFacetsRequest,
        requestId: String,
        deadline: ContinuousClock.Instant
    ) async throws -> EngramServiceWebFacetsResponse {
        throw ServiceWebMetadataError.unavailable
    }

    func stats(
        _ request: EngramServiceWebStatsRequest,
        requestId: String,
        deadline: ContinuousClock.Instant
    ) async throws -> EngramServiceWebStatsResponse {
        throw ServiceWebMetadataError.unavailable
    }

    func settings(
        _ request: EngramServiceWebSettingsRequest,
        requestId: String,
        deadline: ContinuousClock.Instant
    ) async throws -> EngramServiceWebSettingsResponse {
        throw ServiceWebMetadataError.unavailable
    }

    func searchScope(
        _ request: EngramServiceWebSearchRequest,
        requestId: String,
        deadline: ContinuousClock.Instant
    ) async throws -> EngramServiceSearchScope {
        throw ServiceWebMetadataError.unavailable
    }

    func admitSearch(
        _ request: EngramServiceWebSearchRequest,
        ranked: EngramServiceSearchResponse,
        requestId: String,
        deadline: ContinuousClock.Instant
    ) async throws -> EngramServiceWebSearchResponse {
        throw ServiceWebMetadataError.unavailable
    }

    func insightDetail(
        _ request: EngramServiceWebInsightDetailRequest,
        requestId: String,
        deadline: ContinuousClock.Instant
    ) async throws -> EngramServiceWebInsightDetailResponse {
        throw ServiceWebMetadataError.unavailable
    }

    func searchStatus(
        _ request: EngramServiceWebSearchStatusRequest,
        requestId: String,
        deadline: ContinuousClock.Instant
    ) async throws -> EngramServiceWebSearchStatusResponse {
        throw ServiceWebMetadataError.unavailable
    }

    func costs(
        _ request: EngramServiceWebCostsRequest,
        requestId: String,
        deadline: ContinuousClock.Instant
    ) async throws -> EngramServiceWebCostsResponse {
        throw ServiceWebMetadataError.unavailable
    }

    func costSessions(
        _ request: EngramServiceWebCostSessionsRequest,
        requestId: String,
        deadline: ContinuousClock.Instant
    ) async throws -> EngramServiceWebCostSessionsResponse {
        throw ServiceWebMetadataError.unavailable
    }

    func addProjectAlias(
        _ request: EngramServiceWebAddAliasRequest,
        writer: EngramDatabaseWriter
    ) throws -> EngramServiceWebAliasMutationResponse {
        throw ServiceWebMetadataError.unavailable
    }

    func removeProjectAlias(
        _ request: EngramServiceWebRemoveAliasRequest,
        writer: EngramDatabaseWriter
    ) throws -> EngramServiceWebAliasMutationResponse {
        throw ServiceWebMetadataError.unavailable
    }
}

final class UnavailableServiceWebMetadataProducer: ServiceWebMetadataProviding, Sendable {
    func overview(
        _ request: EngramServiceWebOverviewRequest,
        requestId: String,
        deadline: ContinuousClock.Instant
    ) async throws -> EngramServiceWebOverviewResponse {
        throw ServiceWebMetadataError.unavailable
    }

    func sessions(
        _ request: EngramServiceWebSessionsRequest,
        requestId: String,
        deadline: ContinuousClock.Instant
    ) async throws -> EngramServiceWebSessionsResponse {
        throw ServiceWebMetadataError.unavailable
    }

    func sessionDetail(
        _ request: EngramServiceWebSessionDetailRequest,
        requestId: String,
        deadline: ContinuousClock.Instant
    ) async throws -> EngramServiceWebSessionDetailResponse {
        throw ServiceWebMetadataError.unavailable
    }

    func facets(
        _ request: EngramServiceWebFacetsRequest,
        requestId: String,
        deadline: ContinuousClock.Instant
    ) async throws -> EngramServiceWebFacetsResponse {
        throw ServiceWebMetadataError.unavailable
    }

    func stats(
        _ request: EngramServiceWebStatsRequest,
        requestId: String,
        deadline: ContinuousClock.Instant
    ) async throws -> EngramServiceWebStatsResponse {
        throw ServiceWebMetadataError.unavailable
    }

    func settings(
        _ request: EngramServiceWebSettingsRequest,
        requestId: String,
        deadline: ContinuousClock.Instant
    ) async throws -> EngramServiceWebSettingsResponse {
        throw ServiceWebMetadataError.unavailable
    }

    func stop() throws {}
}

final class ServiceWebMetadataProducer: ServiceWebMetadataProviding, @unchecked Sendable {
    private let policySource: @Sendable () throws -> ServiceWebMetadataPolicy?
    private let clock: ServiceWebMetadataClock
    private let hooks: ServiceWebMetadataTestHooks
    private let embeddingEnvironment: [String: String]
    private let pool: DatabasePool
    private let queue = DispatchQueue(label: "com.engram.service.web-metadata.sql", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let admission = NSCondition()
    private let relay: RequestRelay
    private var stopping = false
    private var closed = false
    private var closeFailed = false
    private var pending: [UUID: RequestControl] = [:]
    // All lease and cursor state belongs to queue, never a SQLite callback.
    private var leases: [String: Lease] = [:]
    private var creationOrder: UInt64 = 0

    var retainedLeaseCount: Int {
        if DispatchQueue.getSpecific(key: queueKey) == true { return leases.count }
        return queue.sync { leases.count }
    }

    init(
        databasePath: String,
        policy: @escaping @Sendable () throws -> ServiceWebMetadataPolicy?,
        clock: ServiceWebMetadataClock = .live,
        hooks: ServiceWebMetadataTestHooks = .init(),
        embeddingEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        self.policySource = policy
        self.clock = clock
        self.hooks = hooks
        self.embeddingEnvironment = embeddingEnvironment
        let relay = RequestRelay()
        self.relay = relay
        var configuration = SQLiteConnectionPolicy.immediateReaderConfiguration()
        // The shared prepareDatabase callback resets GRDB's cloned reader
        // busy mode before its format check and initial snapshot transaction.
        configuration.prepareDatabase { db in
            guard let connection = db.sqliteConnection else { throw ServiceWebMetadataError.unavailable }
            // Configuration retains relay for the entire connection lifetime,
            // including failed snapshot initialization and GRDB close_v2. No
            // raw SQLite pointer or borrowed Database escapes this callback.
            sqlite3_progress_handler(connection, 1000, { context in
                guard let context else { return 0 }
                return Unmanaged<RequestRelay>.fromOpaque(context).takeUnretainedValue().shouldInterrupt ? 1 : 0
            }, Unmanaged.passUnretained(relay).toOpaque())
            try hooks.prepareDatabase?(db)
            if db.description.contains(".snapshot.") {
                try relay.check()
                try hooks.inDatabaseOperation?(.snapshotConnectionSetup, db)
                try relay.check()
            }
        }
        self.pool = try DatabasePool(path: databasePath, configuration: configuration)
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit {
        try? stop()
    }

    func overview(
        _ request: EngramServiceWebOverviewRequest,
        requestId: String,
        deadline: ContinuousClock.Instant
    ) async throws -> EngramServiceWebOverviewResponse {
        try await submit(deadline: deadline) { control in
            let policy = try self.currentPolicy()
            let key = try Self.bindingKey(["overview", String(request.limit), ServiceWebMetadataLimits.sortVersion])
            let (lease, position) = try self.acquire(snapshotID: request.snapshotId, cursor: request.cursor,
                key: key, policy: policy, control: control)
            let prepared = try self.read(lease.snapshot, control: control) { db in
                try self.overviewRows(db, policy: policy, after: position.key, limit: request.limit,
                                      observedAt: lease.observedAt)
            }
            let token = position.successor ?? Self.token()
            let count = try Self.fittingCount(prepared.rows.count, limit: request.limit, fixed: position.count) { count in
                try Self.encodedSuccessFrame(requestId: requestId, result: EngramServiceWebOverviewResponse(
                    snapshotId: lease.id, observedAt: lease.observedAt,
                    capabilities: .init(keywordSearch: lease.hasFTS ? .available : .unavailable, transcriptRead: .unavailable),
                    streams: prepared.rows.prefix(count).map(\.overview),
                    nextCursor: prepared.rows.count > count || prepared.hasMore ? token : nil))
            }
            let page = Array(prepared.rows.prefix(count))
            try self.hooks.afterPreparation?(.overview)
            try self.requirePolicy(policy)
            try self.pool.read { db in
                try self.requireSchema(db, lease: lease)
                for stream in page {
                    try control.check()
                    guard let fresh = try self.binding(db, machineID: stream.machineID, instanceID: stream.instanceID,
                                                      policy: policy),
                          try Self.bindingKey(Self.bindingFields(fresh)) == stream.authority else { throw ServiceWebMetadataError.stale }
                }
            }
            try self.requirePolicy(policy)
            try control.check()
            let next = try self.successor(lease, position: position, count: count,
                hasMore: prepared.rows.count > count || prepared.hasMore,
                last: page.last.map { .stream($0.machineID, $0.instanceID) }, proposed: token)
            let result = EngramServiceWebOverviewResponse(snapshotId: lease.id, observedAt: lease.observedAt,
                capabilities: .init(keywordSearch: lease.hasFTS ? .available : .unavailable, transcriptRead: .unavailable),
                streams: page.map(\.overview), nextCursor: next)
            try Self.validate(result, requestID: requestId)
            return result
        }
    }

    func sessions(
        _ request: EngramServiceWebSessionsRequest,
        requestId: String,
        deadline: ContinuousClock.Instant
    ) async throws -> EngramServiceWebSessionsResponse {
        try await submit(deadline: deadline) { control in
            let policy = try self.currentPolicy()
            let key = try Self.bindingKey(["sessions", request.query, request.source,
                try Self.listIdentity(request.sources), request.machineId, request.sourceInstanceId,
                request.projectKey, try Self.listIdentity(request.projectKeys),
                request.sessionId, request.agents.rawValue, request.since, request.until,
                request.tools.rawValue, String(request.limit), ServiceWebMetadataLimits.sortVersion])
            let (lease, position) = try self.acquire(snapshotID: request.snapshotId, cursor: request.cursor,
                key: key, policy: policy, control: control)
            let cachedTotal = lease.sessionsTotal
            let prepared = try self.read(lease.snapshot, control: control) { db in
                let rows = try self.sessionRows(db, request: request, policy: policy, after: position.key,
                                     limit: request.limit + 1, sessionIDs: nil)
                let total = try cachedTotal ?? self.sessionCount(db, request: request, policy: policy)
                return SessionsPrepared(rows: rows, total: total)
            }
            if lease.sessionsTotal == nil {
                lease.sessionsTotal = prepared.total
            }
            let token = position.successor ?? Self.token()
            let count = try Self.fittingCount(prepared.rows.count, limit: request.limit, fixed: position.count) { count in
                try Self.encodedSuccessFrame(requestId: requestId, result: EngramServiceWebSessionsResponse(
                    snapshotId: lease.id, observedAt: lease.observedAt, items: prepared.rows.prefix(count).map(\.summary),
                    nextCursor: prepared.rows.count > count ? token : nil, totalCount: prepared.totalCount))
            }
            let page = Array(prepared.rows.prefix(count))
            try self.hooks.afterPreparation?(.sessions)
            try self.requirePolicy(policy)
            try self.pool.read { db in
                try self.requireSchema(db, lease: lease)
                try control.check()
                for stream in lease.sessionsTotal?.streams ?? [] {
                    try control.check()
                    guard let fresh = try self.binding(db, machineID: stream.machineID, instanceID: stream.instanceID,
                                                      policy: policy),
                          try Self.bindingKey(Self.bindingFields(fresh)) == stream.authority else {
                        throw ServiceWebMetadataError.stale
                    }
                }
                if !page.isEmpty {
                    try control.check()
                    let ids = page.map(\.summary.sessionId)
                    let fresh = try self.sessionRows(db, request: request, policy: policy, after: nil,
                        limit: ids.count, sessionIDs: ids)
                    var byID: [Data: SessionRecord] = [:]
                    byID.reserveCapacity(fresh.count)
                    for row in fresh { byID[Data(row.summary.sessionId.utf8)] = row }
                    for item in page {
                        try control.check()
                        guard let row = byID[Data(item.summary.sessionId.utf8)],
                              row.authority == item.authority else { throw ServiceWebMetadataError.stale }
                    }
                }
            }
            try self.requirePolicy(policy)
            try control.check()
            let next = try self.successor(lease, position: position, count: count, hasMore: prepared.rows.count > count,
                last: page.last.map { .session($0.summary.startedAt, $0.summary.sessionId) }, proposed: token)
            let result = EngramServiceWebSessionsResponse(snapshotId: lease.id, observedAt: lease.observedAt,
                items: page.map(\.summary), nextCursor: next, totalCount: prepared.totalCount)
            try Self.validate(result, requestID: requestId)
            return result
        }
    }

    func sessionDetail(
        _ request: EngramServiceWebSessionDetailRequest,
        requestId: String,
        deadline: ContinuousClock.Instant
    ) async throws -> EngramServiceWebSessionDetailResponse {
        try await submit(deadline: deadline) { control in
            let policy = try self.currentPolicy()
            let snapshot = try self.makeSnapshot(control)
            // DatabaseSnapshot deinit commits its read transaction, then closes
            // its reader. Explicit close would leave deinit a NULL connection.
            defer { withExtendedLifetime(snapshot) {} }
            let filter = try EngramServiceWebSessionsRequest(agents: .all, limit: 1)
            let prepared = try self.read(snapshot, control: control) { db -> (SessionRecord, EngramServiceWebSessionDetail)? in
                guard let row = try self.sessionRows(db, request: filter, policy: policy, after: nil,
                                                    limit: 1, sessionIDs: [request.sessionId]).first else { return nil }
                let detail = EngramServiceWebSessionDetail(session: row.summary,
                    lastParsed: try self.generation(db, id: row.parsedID, sessionID: request.sessionId),
                    lastReady: try self.generation(db, id: row.readyID, sessionID: request.sessionId),
                    transcriptAvailability: .unavailable, transcriptGeneration: nil, currentAttempt: nil,
                    summary: try Self.publishedSessionSummary(db, sessionID: request.sessionId))
                return (row, detail)
            }
            try self.hooks.afterPreparation?(.detail)
            let current = try self.currentPolicy()
            var detail: EngramServiceWebSessionDetail?
            if Self.samePolicy(current, policy), let prepared {
                let fresh = try self.pool.read { db in
                    try self.sessionRows(db, request: filter, policy: current, after: nil,
                                         limit: 1, sessionIDs: [request.sessionId]).first
                }
                if fresh?.authority == prepared.0.authority {
                    let summary = try self.pool.read { db in
                        try Self.publishedSessionSummary(db, sessionID: request.sessionId)
                    }
                    detail = EngramServiceWebSessionDetail(
                        session: prepared.1.session,
                        lastParsed: prepared.1.lastParsed,
                        lastReady: prepared.1.lastReady,
                        transcriptAvailability: prepared.1.transcriptAvailability,
                        transcriptGeneration: prepared.1.transcriptGeneration,
                        currentAttempt: prepared.1.currentAttempt,
                        summary: summary
                    )
                }
            }
            if !Self.samePolicy(try self.currentPolicy(), policy) { detail = nil }
            try control.check()
            let result = EngramServiceWebSessionDetailResponse(observedAt: Self.observedAt(), detail: detail)
            try Self.validate(result, requestID: requestId)
            return result
        }
    }

    func children(
        _ request: EngramServiceWebChildrenRequest,
        requestId: String,
        deadline: ContinuousClock.Instant
    ) async throws -> EngramServiceWebChildrenResponse {
        try await submit(deadline: deadline) { control in
            let policy = try self.currentPolicy()
            let key = try Self.bindingKey(["children", request.sessionId, String(request.limit),
                                           ServiceWebMetadataLimits.sortVersion])
            let (lease, position) = try self.acquire(snapshotID: request.snapshotId, cursor: request.cursor,
                key: key, policy: policy, control: control)
            let parentFilter = try EngramServiceWebSessionsRequest(agents: .all, limit: 1)
            let prepared = try self.read(lease.snapshot, control: control) { db -> (SessionRecord, [ChildRecord]) in
                guard let parent = try self.sessionRows(db, request: parentFilter, policy: policy, after: nil,
                                                       limit: 1, sessionIDs: [request.sessionId]).first else {
                    throw ServiceWebMetadataError.unavailable
                }
                let rows = try self.childRows(db, parentID: request.sessionId, policy: policy,
                                              after: position.key, limit: request.limit + 1, sessionIDs: nil)
                return (parent, rows)
            }
            let token = position.successor ?? Self.token()
            let count = try Self.fittingCount(prepared.1.count, limit: request.limit, fixed: position.count) { count in
                try Self.encodedSuccessFrame(requestId: requestId, result: EngramServiceWebChildrenResponse(
                    sessionId: request.sessionId, snapshotId: lease.id, observedAt: lease.observedAt,
                    items: prepared.1.prefix(count).map(\.item),
                    nextCursor: prepared.1.count > count ? token : nil))
            }
            let page = Array(prepared.1.prefix(count))
            try self.hooks.afterPreparation?(.children)
            try self.requirePolicy(policy)
            try self.pool.read { db in
                try self.requireSchema(db, lease: lease)
                try control.check()
                guard let freshParent = try self.sessionRows(db, request: parentFilter, policy: policy, after: nil,
                                                            limit: 1, sessionIDs: [request.sessionId]).first,
                      freshParent.authority == prepared.0.authority else {
                    throw ServiceWebMetadataError.stale
                }
                if !page.isEmpty {
                    try control.check()
                    let ids = page.map(\.item.session.sessionId)
                    let fresh = try self.childRows(db, parentID: request.sessionId, policy: policy, after: nil,
                                                   limit: ids.count, sessionIDs: ids)
                    var byID: [Data: ChildRecord] = [:]
                    byID.reserveCapacity(fresh.count)
                    for row in fresh { byID[Data(row.item.session.sessionId.utf8)] = row }
                    for item in page {
                        try control.check()
                        guard let row = byID[Data(item.item.session.sessionId.utf8)],
                              row.authority == item.authority,
                              row.item.relationship == item.item.relationship else {
                            throw ServiceWebMetadataError.stale
                        }
                    }
                }
            }
            try self.requirePolicy(policy)
            try control.check()
            let next = try self.successor(lease, position: position, count: count, hasMore: prepared.1.count > count,
                last: page.last.map { .session($0.item.session.startedAt, $0.item.session.sessionId) }, proposed: token)
            let result = EngramServiceWebChildrenResponse(
                sessionId: request.sessionId, snapshotId: lease.id, observedAt: lease.observedAt,
                items: page.map(\.item), nextCursor: next)
            try Self.validate(result, requestID: requestId)
            return result
        }
    }

    func facets(
        _ request: EngramServiceWebFacetsRequest,
        requestId: String,
        deadline: ContinuousClock.Instant
    ) async throws -> EngramServiceWebFacetsResponse {
        try await submit(deadline: deadline) { control in
            let policy = try self.currentPolicy()
            let key = try Self.bindingKey(["facets", request.kind.rawValue, request.query,
                request.agents.rawValue, String(request.limit), ServiceWebMetadataLimits.sortVersion])
            let (lease, position) = try self.acquire(snapshotID: request.snapshotId, cursor: request.cursor,
                key: key, policy: policy, control: control)
            let prepared = try self.read(lease.snapshot, control: control) { db in
                try self.facetRows(db, request: request, policy: policy, after: position.key,
                                   limit: request.limit + 1)
            }
            let token = position.successor ?? Self.token()
            let count = try Self.fittingCount(prepared.count, limit: request.limit, fixed: position.count) { count in
                try Self.encodedSuccessFrame(requestId: requestId, result: EngramServiceWebFacetsResponse(
                    snapshotId: lease.id, observedAt: lease.observedAt, items: prepared.prefix(count).map(\.item),
                    nextCursor: prepared.count > count ? token : nil))
            }
            let page = Array(prepared.prefix(count))
            try self.hooks.afterPreparation?(.facets)
            try self.requirePolicy(policy)
            try self.pool.read { db in
                try self.requireSchema(db, lease: lease)
                if !page.isEmpty {
                    try control.check()
                    let keys = page.map(\.item.key)
                    let fresh = try self.facetRows(db, request: request, policy: policy, after: nil,
                                                  limit: keys.count, keys: keys)
                    var byKey: [Data: FacetRecord] = [:]
                    byKey.reserveCapacity(fresh.count)
                    for row in fresh { byKey[Data(row.item.key.utf8)] = row }
                    for item in page {
                        try control.check()
                        guard let row = byKey[Data(item.item.key.utf8)],
                              row.authority == item.authority else { throw ServiceWebMetadataError.stale }
                    }
                }
            }
            try self.requirePolicy(policy)
            try control.check()
            let next = try self.successor(lease, position: position, count: count, hasMore: prepared.count > count,
                last: page.last.map { .facet($0.item.key) }, proposed: token)
            let result = EngramServiceWebFacetsResponse(snapshotId: lease.id, observedAt: lease.observedAt,
                items: page.map(\.item), nextCursor: next)
            try Self.validate(result, requestID: requestId)
            return result
        }
    }

    func stats(
        _ request: EngramServiceWebStatsRequest,
        requestId: String,
        deadline: ContinuousClock.Instant
    ) async throws -> EngramServiceWebStatsResponse {
        try await submit(deadline: deadline) { control in
            let policy = try self.currentPolicy()
            let key = try Self.bindingKey(["stats", request.groupBy.rawValue, request.since, request.until,
                request.excludeNoise ? "1" : "0", request.agents.rawValue, String(request.limit),
                ServiceWebMetadataLimits.sortVersion])
            let (lease, position) = try self.acquire(snapshotID: request.snapshotId, cursor: request.cursor,
                key: key, policy: policy, control: control)
            let prepared = try self.read(lease.snapshot, control: control) { db in
                try self.statsAggregate(db, request: request, policy: policy, after: position.key,
                                        limit: request.limit + 1)
            }
            let token = position.successor ?? Self.token()
            let timeZone = TimeZone.current.identifier
            let count = try Self.fittingCount(prepared.items.count, limit: request.limit, fixed: position.count) { count in
                try Self.encodedSuccessFrame(requestId: requestId, result: EngramServiceWebStatsResponse(
                    snapshotId: lease.id, observedAt: lease.observedAt, groupBy: request.groupBy, timeZone: timeZone,
                    totals: prepared.totals, items: prepared.items.prefix(count).map(\.item),
                    nextCursor: prepared.items.count > count ? token : nil))
            }
            let page = Array(prepared.items.prefix(count))
            try self.hooks.afterPreparation?(.stats)
            try self.requirePolicy(policy)
            try self.pool.read { db in
                try self.requireSchema(db, lease: lease)
                try control.check()
                let fresh = try self.statsAggregate(db, request: request, policy: policy, after: nil,
                                                    limit: max(page.count, 1), keys: page.map(\.item.key))
                guard fresh.totals == prepared.totals else { throw ServiceWebMetadataError.stale }
                if !page.isEmpty {
                    var byKey: [Data: StatsRecord] = [:]
                    byKey.reserveCapacity(fresh.items.count)
                    for row in fresh.items { byKey[Data(row.item.key.utf8)] = row }
                    for item in page {
                        try control.check()
                        guard let row = byKey[Data(item.item.key.utf8)],
                              row.authority == item.authority else { throw ServiceWebMetadataError.stale }
                    }
                }
            }
            try self.requirePolicy(policy)
            try control.check()
            let next = try self.successor(lease, position: position, count: count, hasMore: prepared.items.count > count,
                last: page.last.map { .facet($0.item.key) }, proposed: token)
            let result = EngramServiceWebStatsResponse(
                snapshotId: lease.id, observedAt: lease.observedAt, groupBy: request.groupBy, timeZone: timeZone,
                totals: prepared.totals, items: page.map(\.item), nextCursor: next)
            try Self.validate(result, requestID: requestId)
            return result
        }
    }

    func settings(
        _ request: EngramServiceWebSettingsRequest,
        requestId: String,
        deadline: ContinuousClock.Instant
    ) async throws -> EngramServiceWebSettingsResponse {
        try await submit(deadline: deadline) { control in
            let policy = try self.currentPolicy()
            let key = try Self.bindingKey(["settings", String(request.limit), ServiceWebMetadataLimits.sortVersion])
            let (lease, position) = try self.acquire(snapshotID: request.snapshotId, cursor: request.cursor,
                key: key, policy: policy, control: control)
            let prepared = try self.read(lease.snapshot, control: control) { db in
                try self.settingsSnapshot(db, policy: policy, after: position.key, limit: request.limit + 1)
            }
            let token = position.successor ?? Self.token()
            let count = try Self.fittingCount(prepared.aliases.count, limit: request.limit, fixed: position.count) { count in
                try Self.encodedSuccessFrame(requestId: requestId, result: Self.settingsResponse(
                    lease: lease, prepared: prepared, aliasCount: count,
                    nextCursor: prepared.aliases.count > count ? token : nil))
            }
            let page = Array(prepared.aliases.prefix(count))
            try self.hooks.afterPreparation?(.settings)
            try self.requirePolicy(policy)
            try self.pool.read { db in
                try self.requireSchema(db, lease: lease)
                try control.check()
                let fresh = try self.settingsSnapshot(db, policy: policy, after: nil, limit: max(page.count, 1),
                                                      keys: page.map(\.cursorKey))
                guard fresh.totalSessions == prepared.totalSessions,
                      fresh.sources == prepared.sources else { throw ServiceWebMetadataError.stale }
                if !page.isEmpty {
                    var byKey: [Data: SettingsAliasRecord] = [:]
                    byKey.reserveCapacity(fresh.aliases.count)
                    for row in fresh.aliases { byKey[Data(row.cursorKey.utf8)] = row }
                    for item in page {
                        try control.check()
                        guard let row = byKey[Data(item.cursorKey.utf8)],
                              row.authority == item.authority else { throw ServiceWebMetadataError.stale }
                    }
                }
            }
            try self.requirePolicy(policy)
            try control.check()
            let next = try self.successor(lease, position: position, count: count, hasMore: prepared.aliases.count > count,
                last: page.last.map { .facet($0.cursorKey) }, proposed: token)
            let result = Self.settingsResponse(lease: lease, prepared: prepared, aliasCount: count, nextCursor: next)
            try Self.validate(result, requestID: requestId)
            return result
        }
    }

    func searchScope(
        _ request: EngramServiceWebSearchRequest,
        requestId: String,
        deadline: ContinuousClock.Instant
    ) async throws -> EngramServiceSearchScope {
        try await submit(deadline: deadline) { control in
            let policy = try self.currentPolicy()
            return try self.pool.read { db in
                try control.check()
                return try self.makeSearchScope(db, request: self.sessionsFilter(from: request), policy: policy)
            }
        }
    }

    func admitSearch(
        _ request: EngramServiceWebSearchRequest,
        ranked: EngramServiceSearchResponse,
        requestId: String,
        deadline: ContinuousClock.Instant
    ) async throws -> EngramServiceWebSearchResponse {
        try await submit(deadline: deadline) { control in
            let policy = try self.currentPolicy()
            let filter = try self.sessionsFilter(from: request)
            let prepared = try self.pool.read { db -> ([EngramServiceWebSearchHit], [EngramServiceWebSearchInsight]) in
                try control.check()
                var admitted: [EngramServiceWebSearchHit] = []
                for item in ranked.items {
                    try control.check()
                    let rows = try self.sessionRows(db, request: filter, policy: policy, after: nil,
                                                    limit: 1, sessionIDs: [item.id])
                    guard let row = rows.first,
                          row.summary.sessionId.utf8.elementsEqual(item.id.utf8) else { continue }
                    let matchType = item.matchType == "semantic" ? "semantic" : "keyword"
                    admitted.append(EngramServiceWebSearchHit(
                        session: row.summary,
                        snippet: item.snippet,
                        matchType: matchType,
                        score: item.score
                    ))
                }
                let insights = try self.admittedSearchInsights(db, ranked: ranked, policy: policy)
                return (admitted, insights)
            }
            try self.hooks.afterPreparation?(.search)
            try self.requirePolicy(policy)
            let freshInsights = try self.pool.read { db in
                try control.check()
                return try self.admittedSearchInsights(db, ranked: ranked, policy: policy)
            }
            try self.requirePolicy(policy); try control.check()
            guard freshInsights == prepared.1 else { throw ServiceWebMetadataError.stale }
            let result = EngramServiceWebSearchResponse(
                observedAt: Self.observedAt(),
                query: request.query,
                items: prepared.0,
                insightResults: freshInsights,
                searchModes: ranked.searchModes ?? [],
                warning: ranked.warning,
                warningCode: ranked.warningCode
            )
            try Self.validate(result, requestID: requestId)
            return result
        }
    }

    func insightDetail(
        _ request: EngramServiceWebInsightDetailRequest,
        requestId: String,
        deadline: ContinuousClock.Instant
    ) async throws -> EngramServiceWebInsightDetailResponse {
        try await submit(deadline: deadline) { control in
            let policy = try self.currentPolicy()
            let prepared = try self.pool.read { db in
                try control.check()
                return try self.insightDetailPage(db, request: request, policy: policy)
            }
            try self.hooks.afterPreparation?(.insightDetail)
            try self.requirePolicy(policy); try control.check()
            guard let prepared else { throw ServiceWebMetadataError.notFound }
            let fresh = try self.pool.read { db in
                try control.check()
                return try self.insightDetailPage(db, request: request, policy: policy)
            }
            try self.requirePolicy(policy); try control.check()
            guard let fresh else { throw ServiceWebMetadataError.notFound }
            guard fresh == prepared else {
                throw fresh.revision == prepared.revision
                    ? ServiceWebMetadataError.notFound
                    : ServiceWebMetadataError.stale
            }
            try Self.validate(fresh, requestID: requestId)
            return fresh
        }
    }

    private func admittedSearchInsights(
        _ db: Database,
        ranked: EngramServiceSearchResponse,
        policy: ServiceWebMetadataPolicy
    ) throws -> [EngramServiceWebSearchInsight] {
        guard try db.tableExists("insights") else { return [] }
        let admitted = try admittedAuditSessionIDs(db, policy: policy)
        var insights: [EngramServiceWebSearchInsight] = []
        for item in ranked.insightResults {
            guard let row = try Row.fetchOne(db, sql: """
                SELECT id, content, source_session_id
                FROM insights
                WHERE id = ? COLLATE BINARY AND superseded_by IS NULL
                """, arguments: [item.id]) else { continue }
            let sourceSessionId = try Self.optionalString(row, "source_session_id")
            // Any stored linkage, including empty string, must be currently admitted.
            // NULL is the only global-library note.
            if let sourceSessionId {
                guard let admitted, admitted.contains(ByteKey(sourceSessionId)) else { continue }
            }
            guard let preview = Self.insightPreview(try Self.string(row, "content")) else { continue }
            let matchType = item.matchType == "semantic" ? "semantic" : "keyword"
            insights.append(EngramServiceWebSearchInsight(
                id: try Self.string(row, "id"), content: preview, sourceSessionId: sourceSessionId,
                matchType: matchType, score: item.score))
            if insights.count == 5 { break }
        }
        return insights
    }

    private func insightDetailPage(
        _ db: Database,
        request: EngramServiceWebInsightDetailRequest,
        policy: ServiceWebMetadataPolicy
    ) throws -> EngramServiceWebInsightDetailResponse? {
        guard try db.tableExists("insights") else { throw ServiceWebMetadataError.unavailable }
        guard let row = try Row.fetchOne(db, sql: """
            SELECT id, content, source_session_id
            FROM insights
            WHERE id = ? COLLATE BINARY AND superseded_by IS NULL
            """, arguments: [request.id]) else { return nil }
        let sourceSessionId = try Self.optionalString(row, "source_session_id")
        if let sourceSessionId {
            let admitted = try admittedAuditSessionIDs(db, policy: policy)
            guard let admitted, admitted.contains(ByteKey(sourceSessionId)) else { return nil }
        }
        let raw = try Self.string(row, "content")
        let redacted = TranscriptRedactionPolicy.redact(raw)
        let revision = ArchiveV2Hash.sha256(Data(redacted.utf8))
        if let expected = request.revision, expected != revision {
            throw ServiceWebMetadataError.stale
        }
        let scalars = Array(redacted.unicodeScalars)
        if request.offset > scalars.count { throw ServiceWebMetadataError.stale }
        let end = min(scalars.count, request.offset + request.limit)
        let content = String(String.UnicodeScalarView(scalars[request.offset..<end]))
        return EngramServiceWebInsightDetailResponse(
            id: try Self.string(row, "id"),
            revision: revision,
            offset: request.offset,
            totalLength: scalars.count,
            content: content,
            nextOffset: end < scalars.count ? end : nil,
            sourceSessionId: sourceSessionId
        )
    }

    private static func insightPreview(_ value: String) -> String? {
        let redacted = TranscriptRedactionPolicy.redact(value)
        guard !redacted.isEmpty else { return nil }
        let clipped = redacted.unicodeScalars.prefix(600)
        let text = String(String.UnicodeScalarView(clipped))
        return text.isEmpty ? nil : text
    }

    func searchStatus(
        _ request: EngramServiceWebSearchStatusRequest,
        requestId: String,
        deadline: ContinuousClock.Instant
    ) async throws -> EngramServiceWebSearchStatusResponse {
        try await submit(deadline: deadline) { control in
            let policy = try self.currentPolicy()
            let filter = try self.sessionsFilter(from: request)
            let result = try self.pool.read { db in
                try control.check()
                return try self.searchStatusSnapshot(db, request: filter, policy: policy)
            }
            try Self.validate(result, requestID: requestId)
            return result
        }
    }

    func usage(_ request: EngramServiceWebUsageRequest, requestId: String,
               deadline: ContinuousClock.Instant) async throws -> EngramServiceWebUsageResponse {
        try await submit(deadline: deadline) { control in
            let policy = try self.currentPolicy()
            let items = try self.pool.read { db -> [EngramServiceWebUsageItem] in
                try control.check()
                guard try db.tableExists("usage_snapshots") else { throw ServiceWebMetadataError.unavailable }
                let sources = policy.enabledSources.map(\.rawValue).sorted()
                guard !sources.isEmpty else { return [] }
                let placeholders = sources.map { _ in "?" }.joined(separator: ",")
                // Legacy getLatest keeps the latest observation for every metric,
                // not only metrics present at a source's newest timestamp.
                let rows = try Row.fetchAll(db, sql: """
                    SELECT * FROM (
                        SELECT source, metric, value, unit, limit_value, reset_at, status, collected_at,
                               ROW_NUMBER() OVER (PARTITION BY source, metric ORDER BY collected_at DESC, id DESC) AS rank
                        FROM usage_snapshots WHERE source IN (\(placeholders))
                    ) WHERE rank = 1 ORDER BY source COLLATE BINARY, metric COLLATE BINARY LIMIT 1001
                    """, arguments: StatementArguments(sources))
                guard rows.count <= 1000 else { throw ServiceWebMetadataError.responseTooLarge }
                let indexedMetrics: Set<String> = ["5h token pressure", "5h token share", "5h token total",
                    "7d cost share", "weekly token pressure", "7d token share", "7d token total"]
                return try rows.map { row in
                    try control.check()
                    let source = try Self.string(row, "source"), metric = try Self.string(row, "metric")
                    guard let label = Self.safeText(metric, maximumBytes: 128), !label.isEmpty,
                          let collected = Self.safeText(try Self.string(row, "collected_at"), maximumBytes: 64) else {
                        throw ServiceWebMetadataError.unavailable
                    }
                    let value: Double = row["value"]
                    let limit: Double? = row["limit_value"]
                    guard value.isFinite, value >= 0, limit.map({ $0.isFinite && $0 >= 0 }) ?? true else {
                        throw ServiceWebMetadataError.unavailable
                    }
                    return .init(source: source, metric: label, value: value,
                        unit: Self.safeText(try Self.optionalString(row, "unit"), maximumBytes: 128), limit: limit,
                        resetAt: Self.safeText(try Self.optionalString(row, "reset_at"), maximumBytes: 128),
                        status: Self.safeText(try Self.optionalString(row, "status"), maximumBytes: 128),
                        collectedAt: collected, basis: indexedMetrics.contains(metric) ? .indexedSessions : .reported)
                }
            }
            try self.requirePolicy(policy); try control.check()
            let response = EngramServiceWebUsageResponse(observedAt: Self.observedAt(), items: items)
            try Self.validate(response, requestID: requestId)
            return response
        }
    }

    func toolAnalytics(_ request: EngramServiceWebToolAnalyticsRequest, requestId: String,
                       deadline: ContinuousClock.Instant) async throws -> EngramServiceWebToolAnalyticsResponse {
        try await submit(deadline: deadline) { control in
            let policy = try self.currentPolicy()
            let key = try Self.bindingKey(["toolAnalytics", request.project, request.since, request.until,
                request.agents.rawValue, request.groupBy.rawValue, String(request.limit), ServiceWebMetadataLimits.sortVersion])
            let (lease, position) = try self.acquire(snapshotID: request.snapshotId, cursor: request.cursor,
                key: key, policy: policy, control: control)
            let prepared = try self.read(lease.snapshot, control: control) { db in
                try self.toolAnalyticsRows(db, request: request, policy: policy)
            }
            var total: Int64 = 0
            for row in prepared { total = try Self.addToolCalls(total, row.item.callCount) }
            var remaining = prepared
            if let key = position.key {
                guard case .facet(let last) = key,
                      let index = prepared.firstIndex(where: { $0.item.key.utf8.elementsEqual(last.utf8) }) else {
                    throw ServiceWebMetadataError.stale
                }
                remaining = Array(prepared.dropFirst(index + 1))
            }
            let token = position.successor ?? Self.token()
            let count = try Self.fittingCount(remaining.count, limit: request.limit, fixed: position.count) { count in
                try Self.encodedSuccessFrame(requestId: requestId, result: EngramServiceWebToolAnalyticsResponse(
                    snapshotId: lease.id, observedAt: lease.observedAt, groupBy: request.groupBy,
                    totalCalls: total, groupCount: prepared.count, items: remaining.prefix(count).map(\.item),
                    nextCursor: remaining.count > count ? token : nil))
            }
            let page = Array(remaining.prefix(count))
            try self.hooks.afterPreparation?(.toolAnalytics)
            try self.requirePolicy(policy)
            try self.pool.read { db in
                try self.requireSchema(db, lease: lease)
                try control.check()
                let fresh = try self.toolAnalyticsRows(db, request: request, policy: policy)
                guard fresh == prepared else { throw ServiceWebMetadataError.stale }
            }
            try self.requirePolicy(policy); try control.check()
            let next = try self.successor(lease, position: position, count: count, hasMore: remaining.count > count,
                last: page.last.map { .facet($0.item.key) }, proposed: token)
            let response = EngramServiceWebToolAnalyticsResponse(snapshotId: lease.id, observedAt: lease.observedAt,
                groupBy: request.groupBy, totalCalls: total, groupCount: prepared.count, items: page.map(\.item), nextCursor: next)
            try Self.validate(response, requestID: requestId)
            return response
        }
    }

    func fileActivity(_ request: EngramServiceWebFileActivityRequest, requestId: String,
                      deadline: ContinuousClock.Instant) async throws -> EngramServiceWebFileActivityResponse {
        try await submit(deadline: deadline) { control in
            let policy = try self.currentPolicy()
            let key = try Self.bindingKey(["fileActivity", request.project, request.since, request.until,
                request.agents.rawValue, String(request.limit), ServiceWebMetadataLimits.sortVersion])
            let (lease, position) = try self.acquire(snapshotID: request.snapshotId, cursor: request.cursor,
                key: key, policy: policy, control: control)
            let prepared = try self.read(lease.snapshot, control: control) { db in
                try self.fileActivityRows(db, request: request, policy: policy)
            }
            var totalOperations: Int64 = 0
            for row in prepared {
                totalOperations = try Self.addToolCalls(totalOperations, row.operations)
            }
            var remaining = prepared
            if let key = position.key {
                guard case .facet(let last) = key,
                      let index = prepared.firstIndex(where: { $0.key.utf8.elementsEqual(last.utf8) }) else {
                    throw ServiceWebMetadataError.stale
                }
                remaining = Array(prepared.dropFirst(index + 1))
            }
            let token = position.successor ?? Self.token()
            let count = try Self.fittingCount(remaining.count, limit: request.limit, fixed: position.count) { count in
                try Self.encodedSuccessFrame(requestId: requestId, result: EngramServiceWebFileActivityResponse(
                    snapshotId: lease.id, observedAt: lease.observedAt, totalFiles: prepared.count,
                    totalOperations: totalOperations, items: remaining.prefix(count).map(\.item),
                    nextCursor: remaining.count > count ? token : nil))
            }
            let page = Array(remaining.prefix(count))
            try self.hooks.afterPreparation?(.fileActivity)
            try self.requirePolicy(policy)
            try self.pool.read { db in
                try self.requireSchema(db, lease: lease)
                try control.check()
                let fresh = try self.fileActivityRows(db, request: request, policy: policy)
                guard fresh == prepared else { throw ServiceWebMetadataError.stale }
            }
            try self.requirePolicy(policy); try control.check()
            let next = try self.successor(lease, position: position, count: count, hasMore: remaining.count > count,
                last: page.last.map { .facet($0.key) }, proposed: token)
            let response = EngramServiceWebFileActivityResponse(snapshotId: lease.id, observedAt: lease.observedAt,
                totalFiles: prepared.count, totalOperations: totalOperations, items: page.map(\.item), nextCursor: next)
            try Self.validate(response, requestID: requestId)
            return response
        }
    }

    func repos(_ request: EngramServiceWebReposRequest, requestId: String,
               deadline: ContinuousClock.Instant) async throws -> EngramServiceWebReposResponse {
        try await submit(deadline: deadline) { control in
            let policy = try self.currentPolicy()
            let key = try Self.bindingKey(["repos", String(request.limit), ServiceWebMetadataLimits.sortVersion])
            let (lease, position) = try self.acquire(snapshotID: request.snapshotId, cursor: request.cursor,
                key: key, policy: policy, control: control)
            let prepared = try self.read(lease.snapshot, control: control) { db in
                try self.repoRows(db, policy: policy)
            }
            var remaining = prepared
            if let key = position.key {
                guard case .facet(let last) = key,
                      let index = prepared.firstIndex(where: { $0.item.key.utf8.elementsEqual(last.utf8) }) else {
                    throw ServiceWebMetadataError.stale
                }
                remaining = Array(prepared.dropFirst(index + 1))
            }
            let token = position.successor ?? Self.token()
            let count = try Self.fittingCount(remaining.count, limit: request.limit, fixed: position.count) { count in
                try Self.encodedSuccessFrame(requestId: requestId, result: EngramServiceWebReposResponse(
                    snapshotId: lease.id, observedAt: lease.observedAt, totalRepos: prepared.count,
                    items: remaining.prefix(count).map(\.item),
                    nextCursor: remaining.count > count ? token : nil))
            }
            let page = Array(remaining.prefix(count))
            try self.hooks.afterPreparation?(.repos)
            try self.requirePolicy(policy)
            try self.pool.read { db in
                try self.requireSchema(db, lease: lease)
                try control.check()
                let fresh = try self.repoRows(db, policy: policy)
                guard fresh == prepared else { throw ServiceWebMetadataError.stale }
            }
            try self.requirePolicy(policy); try control.check()
            let next = try self.successor(lease, position: position, count: count, hasMore: remaining.count > count,
                last: page.last.map { .facet($0.item.key) }, proposed: token)
            let response = EngramServiceWebReposResponse(snapshotId: lease.id, observedAt: lease.observedAt,
                totalRepos: prepared.count, items: page.map(\.item), nextCursor: next)
            try Self.validate(response, requestID: requestId)
            return response
        }
    }

    func projectCwds(_ request: EngramServiceWebProjectCwdsRequest, requestId: String,
                     deadline: ContinuousClock.Instant) async throws -> EngramServiceWebProjectCwdsResponse {
        try await submit(deadline: deadline) { control in
            let policy = try self.currentPolicy()
            let key = try Self.bindingKey([
                "projectCwds", request.projectKey, String(request.limit), ServiceWebMetadataLimits.sortVersion,
            ])
            let (lease, position) = try self.acquire(
                snapshotID: request.snapshotId, cursor: request.cursor, key: key, policy: policy, control: control
            )
            let prepared = try self.read(lease.snapshot, control: control) { db in
                try self.projectCwdRows(db, request: request, policy: policy)
            }
            var remaining = prepared
            if let key = position.key {
                guard case .facet(let last) = key,
                      let index = prepared.firstIndex(where: { $0.item.key.utf8.elementsEqual(last.utf8) }) else {
                    throw ServiceWebMetadataError.stale
                }
                remaining = Array(prepared.dropFirst(index + 1))
            }
            let token = position.successor ?? Self.token()
            let count = try Self.fittingCount(remaining.count, limit: request.limit, fixed: position.count) { count in
                try Self.encodedSuccessFrame(requestId: requestId, result: EngramServiceWebProjectCwdsResponse(
                    snapshotId: lease.id, observedAt: lease.observedAt, projectKey: request.projectKey,
                    totalCount: prepared.count, items: remaining.prefix(count).map(\.item),
                    nextCursor: remaining.count > count ? token : nil))
            }
            let page = Array(remaining.prefix(count))
            try self.hooks.afterPreparation?(.projectCwds)
            try self.requirePolicy(policy)
            try self.pool.read { db in
                try self.requireSchema(db, lease: lease)
                try control.check()
                let fresh = try self.projectCwdRows(db, request: request, policy: policy)
                guard fresh == prepared else { throw ServiceWebMetadataError.stale }
            }
            try self.requirePolicy(policy); try control.check()
            let next = try self.successor(
                lease, position: position, count: count, hasMore: remaining.count > count,
                last: page.last.map { .facet($0.item.key) }, proposed: token
            )
            let response = EngramServiceWebProjectCwdsResponse(
                snapshotId: lease.id, observedAt: lease.observedAt, projectKey: request.projectKey,
                totalCount: prepared.count, items: page.map(\.item), nextCursor: next
            )
            try Self.validate(response, requestID: requestId)
            return response
        }
    }

    func aiAudit(_ request: EngramServiceWebAiAuditRequest, requestId: String,
                 deadline: ContinuousClock.Instant) async throws -> EngramServiceWebAiAuditResponse {
        try await submit(deadline: deadline) { control in
            let policy = try self.currentPolicy()
            let key = try Self.bindingKey(["aiAudit", request.caller, request.model, request.sessionId,
                request.from, request.to, request.hasError.map { $0 ? "1" : "0" }, String(request.limit),
                ServiceWebMetadataLimits.sortVersion])
            let (lease, position) = try self.acquire(snapshotID: request.snapshotId, cursor: request.cursor,
                key: key, policy: policy, control: control)
            let prepared = try self.read(lease.snapshot, control: control) { db in
                try self.aiAuditRows(db, request: request, policy: policy)
            }
            var remaining = prepared
            if let key = position.key {
                guard case .facet(let last) = key,
                      let index = prepared.firstIndex(where: { $0.item.id.utf8.elementsEqual(last.utf8) }) else {
                    throw ServiceWebMetadataError.stale
                }
                remaining = Array(prepared.dropFirst(index + 1))
            }
            let token = position.successor ?? Self.token()
            let count = try Self.fittingCount(remaining.count, limit: request.limit, fixed: position.count) { count in
                try Self.encodedSuccessFrame(requestId: requestId, result: EngramServiceWebAiAuditResponse(
                    snapshotId: lease.id, observedAt: lease.observedAt, total: prepared.count,
                    items: remaining.prefix(count).map(\.item),
                    nextCursor: remaining.count > count ? token : nil))
            }
            let page = Array(remaining.prefix(count))
            try self.hooks.afterPreparation?(.aiAudit)
            try self.requirePolicy(policy)
            try self.pool.read { db in
                try self.requireSchema(db, lease: lease)
                try control.check()
                let fresh = try self.aiAuditRows(db, request: request, policy: policy)
                guard fresh == prepared else { throw ServiceWebMetadataError.stale }
            }
            try self.requirePolicy(policy); try control.check()
            let next = try self.successor(lease, position: position, count: count, hasMore: remaining.count > count,
                last: page.last.map { .facet($0.item.id) }, proposed: token)
            let response = EngramServiceWebAiAuditResponse(snapshotId: lease.id, observedAt: lease.observedAt,
                total: prepared.count, items: page.map(\.item), nextCursor: next)
            try Self.validate(response, requestID: requestId)
            return response
        }
    }

    func aiAuditDetail(_ request: EngramServiceWebAiAuditDetailRequest, requestId: String,
                       deadline: ContinuousClock.Instant) async throws -> EngramServiceWebAiAuditDetailResponse {
        try await submit(deadline: deadline) { control in
            let policy = try self.currentPolicy()
            let prepared = try self.pool.read { db -> (EngramServiceWebAiAuditItem, Bool, Bool)? in
                try control.check()
                return try self.aiAuditDetailRow(db, id: request.id, policy: policy)
            }
            try self.hooks.afterPreparation?(.aiAuditDetail)
            try self.requirePolicy(policy); try control.check()
            guard let prepared else { throw ServiceWebMetadataError.notFound }
            let fresh = try self.pool.read { db in
                try control.check()
                return try self.aiAuditDetailRow(db, id: request.id, policy: policy)
            }
            try self.requirePolicy(policy); try control.check()
            guard let fresh, fresh == prepared else { throw ServiceWebMetadataError.notFound }
            let response = EngramServiceWebAiAuditDetailResponse(
                observedAt: Self.observedAt(), item: fresh.0,
                hasRequestBody: fresh.1, hasResponseBody: fresh.2)
            try Self.validate(response, requestID: requestId)
            return response
        }
    }

    func aiStats(_ request: EngramServiceWebAiStatsRequest, requestId: String,
                 deadline: ContinuousClock.Instant) async throws -> EngramServiceWebAiStatsResponse {
        try await submit(deadline: deadline) { control in
            let policy = try self.currentPolicy()
            let now = Date()
            let snapshot = try self.makeSnapshot(control)
            defer { withExtendedLifetime(snapshot) {} }
            let prepared = try self.read(snapshot, control: control) { db in
                try self.aiStatsSnapshot(db, request: request, policy: policy, now: now)
            }
            try self.hooks.afterPreparation?(.aiStats)
            try self.requirePolicy(policy)
            try self.pool.read { db in
                try control.check()
                let fresh = try self.aiStatsSnapshot(db, request: request, policy: policy, now: now)
                guard fresh == prepared else { throw ServiceWebMetadataError.stale }
            }
            try self.requirePolicy(policy); try control.check()
            let response = EngramServiceWebAiStatsResponse(
                observedAt: Self.observedAt(), timeRange: prepared.timeRange, totals: prepared.totals,
                byCaller: prepared.byCaller, byModel: prepared.byModel, hourly: prepared.hourly)
            try Self.validate(response, requestID: requestId)
            return response
        }
    }

    private struct CwdRecord: Equatable {
        let item: EngramServiceWebProjectCwdItem
        let raw: String
        let authority: Data
    }

    private func projectCwdRows(
        _ db: Database,
        request: EngramServiceWebProjectCwdsRequest,
        policy: ServiceWebMetadataPolicy
    ) throws -> [CwdRecord] {
        let filterRequest = try EngramServiceWebSessionsRequest(
            projectKey: request.projectKey, agents: .hide, limit: 1
        )
        guard let filter = try sessionFilter(db, request: filterRequest, policy: policy, sessionIDs: nil) else {
            return []
        }
        var predicates = filter.predicates
        predicates.append("s.cwd IS NOT NULL AND TRIM(s.cwd) != ''")
        let rows = try Row.fetchAll(db, sql: """
            SELECT s.cwd, i.machine_id, i.source_instance_id
            FROM capture_ingest_identity_bindings i
            JOIN sessions s ON s.id = i.stored_session_id COLLATE BINARY
            \(Self.registryJoinSQL)
            WHERE \(predicates.joined(separator: " AND "))
            ORDER BY s.cwd COLLATE BINARY, i.machine_id COLLATE BINARY, i.source_instance_id COLLATE BINARY
            """, arguments: StatementArguments(filter.arguments))
        var totals: [Data: (raw: String, item: EngramServiceWebProjectCwdItem, fields: [String?])] = [:]
        for row in rows {
            try relay.check()
            let raw = try Self.string(row, "cwd")
            guard !raw.isEmpty, !raw.utf8.contains(0) else { continue }
            guard let binding = try binding(
                db,
                machineID: try Self.string(row, "machine_id"),
                instanceID: try Self.string(row, "source_instance_id"),
                policy: policy
            ) else { continue }
            guard let published = Self.publishedProjectKey(raw) else { continue }
            let id = Data(published.utf8)
            if let existing = totals[id], !existing.raw.utf8.elementsEqual(raw.utf8) {
                throw ServiceWebMetadataError.unavailable
            }
            var fields = totals[id]?.fields ?? []
            fields.append(contentsOf: Self.bindingFields(binding))
            let label = Self.cwdLabel(raw)
            guard let item = try? EngramServiceWebProjectCwdItem(key: published, label: label) else {
                throw ServiceWebMetadataError.unavailable
            }
            totals[id] = (raw, item, fields)
        }
        return try totals.values.map { entry in
            CwdRecord(
                item: entry.item,
                raw: entry.raw,
                authority: try Self.bindingKey(["cwd", entry.item.key] + entry.fields)
            )
        }.sorted { $0.item.key.utf8.lexicographicallyPrecedes($1.item.key.utf8) }
    }

    private static func cwdLabel(_ raw: String) -> String {
        let label = fileActivityLabel(raw)
        return label == "Unknown file" ? "Location" : label
    }

    private struct RepoRecord: Equatable {
        let item: EngramServiceWebRepoItem
        let path: String
        let authority: Data
    }

    private func repoRows(_ db: Database, policy: ServiceWebMetadataPolicy) throws -> [RepoRecord] {
        guard try db.tableExists("git_repos") else { throw ServiceWebMetadataError.unavailable }
        let rows = try Row.fetchAll(db, sql: """
            SELECT path, name, branch, dirty_count, untracked_count, unpushed_count,
                   last_commit_hash, last_commit_msg, last_commit_at, probed_at,
                   CAST(strftime('%s', last_commit_at) AS INTEGER) AS last_commit_epoch,
                   CAST(strftime('%s', probed_at) AS INTEGER) AS probed_epoch
            FROM git_repos
            """)
        let counts = try repoSessionCounts(db, policy: policy)
        return try rows.map { row in
            try relay.check()
            let path = try Self.string(row, "path")
            guard !path.isEmpty, !path.utf8.contains(0) else { throw ServiceWebMetadataError.unavailable }
            let name = try Self.string(row, "name")
            let dirty = try Self.integer(row, "dirty_count")
            let untracked = try Self.integer(row, "untracked_count")
            let unpushed = try Self.integer(row, "unpushed_count")
            try EngramServiceWebMetadataValidation.count(dirty)
            try EngramServiceWebMetadataValidation.count(untracked)
            try EngramServiceWebMetadataValidation.count(unpushed)
            let sessions = counts[Data(path.utf8)] ?? 0
            try EngramServiceWebMetadataValidation.count(sessions)
            let item = EngramServiceWebRepoItem(
                key: Self.publishedProjectKey(path) ?? "u.repo",
                name: Self.repoName(name, path: path),
                branch: Self.repoDisplayText(try Self.optionalString(row, "branch"), maximumBytes: 256),
                dirtyCount: dirty, untrackedCount: untracked, unpushedCount: unpushed,
                lastCommitHash: Self.repoCommitHash(try Self.optionalString(row, "last_commit_hash")),
                lastCommitMessage: Self.repoDisplayText(try Self.optionalString(row, "last_commit_msg"), maximumBytes: 1024),
                lastCommitAt: try Self.optionalInteger(row, "last_commit_epoch"),
                sessionCount: sessions,
                probedAt: try Self.optionalInteger(row, "probed_epoch")
            )
            return RepoRecord(item: item, path: path,
                authority: try Self.bindingKey([path, name, item.branch, String(dirty), String(untracked),
                    String(unpushed), item.lastCommitHash, item.lastCommitMessage,
                    item.lastCommitAt.map(String.init), String(sessions), item.probedAt.map(String.init)]))
        }.sorted {
            let lhs = $0.item.lastCommitAt ?? -1
            let rhs = $1.item.lastCommitAt ?? -1
            if lhs != rhs { return lhs > rhs }
            return $0.path.utf8.lexicographicallyPrecedes($1.path.utf8)
        }
    }

    private func repoSessionCounts(_ db: Database, policy: ServiceWebMetadataPolicy) throws -> [Data: Int64] {
        guard let filter = try sessionFilter(db, request: .init(agents: .hide), policy: policy, sessionIDs: nil) else {
            return [:]
        }
        var predicates = filter.predicates, arguments = filter.arguments
        predicates.append("s.cwd IS NOT NULL AND TRIM(s.cwd) != ''")
        let sessions = try Row.fetchAll(db, sql: """
            SELECT s.id, s.cwd, i.machine_id, i.source_instance_id
            FROM sessions s
            JOIN capture_ingest_identity_bindings i ON i.stored_session_id = s.id COLLATE BINARY
            \(Self.registryJoinSQL)
            WHERE \(predicates.joined(separator: " AND "))
            ORDER BY s.id COLLATE BINARY
            """, arguments: StatementArguments(arguments))
        let aliases: [(cwd: String, realCwd: String, repoPath: String)]
        if try db.tableExists("git_repo_cwd_aliases") {
            aliases = try Row.fetchAll(db, sql: "SELECT cwd, real_cwd, repo_path FROM git_repo_cwd_aliases").map { row in
                (try Self.string(row, "cwd"), try Self.string(row, "real_cwd"), try Self.string(row, "repo_path"))
            }
        } else {
            aliases = []
        }
        let repoPaths = try String.fetchAll(db, sql: "SELECT path FROM git_repos WHERE path != '/'")
            .sorted { $0.utf8.count > $1.utf8.count }
        var counts: [Data: Int64] = [:]
        for row in sessions {
            try relay.check()
            guard try binding(db, machineID: Self.string(row, "machine_id"),
                instanceID: Self.string(row, "source_instance_id"), policy: policy) != nil else { continue }
            let cwd = try Self.string(row, "cwd")
            guard let repo = Self.storedRepoPath(cwd: cwd, aliases: aliases, repoPaths: repoPaths) else { continue }
            let key = Data(repo.utf8)
            counts[key] = try Self.addToolCalls(counts[key] ?? 0, 1)
        }
        return counts
    }

    private static func storedRepoPath(
        cwd: String,
        aliases: [(cwd: String, realCwd: String, repoPath: String)],
        repoPaths: [String]
    ) -> String? {
        if let alias = aliases.first(where: { $0.cwd.utf8.elementsEqual(cwd.utf8) || $0.realCwd.utf8.elementsEqual(cwd.utf8) }),
           repoPaths.contains(where: { $0.utf8.elementsEqual(alias.repoPath.utf8) }) {
            return alias.repoPath
        }
        return repoPaths.first { path in
            cwd.utf8.elementsEqual(path.utf8)
                || (cwd.utf8.count > path.utf8.count && cwd.hasPrefix(path + "/"))
        }
    }

    private struct AiAuditRecord: Equatable {
        let item: EngramServiceWebAiAuditItem
        let authority: Data
    }

    private struct AiStatsPrepared: Equatable {
        let timeRange: EngramServiceWebAiStatsTimeRange
        let totals: EngramServiceWebAiStatsTotals
        let byCaller: [EngramServiceWebAiStatsCaller]
        let byModel: [EngramServiceWebAiStatsModel]
        let hourly: [EngramServiceWebAiStatsHour]
    }

    private func aiAuditRows(_ db: Database, request: EngramServiceWebAiAuditRequest,
                             policy: ServiceWebMetadataPolicy) throws -> [AiAuditRecord] {
        let filter = try aiAuditFilter(db, caller: request.caller, model: request.model,
            sessionId: request.sessionId, from: request.from, to: request.to, hasError: request.hasError,
            policy: policy)
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, caller, operation, method, url, status_code, duration_ms, model, provider,
                   prompt_tokens, completion_tokens, total_tokens, error, session_id,
                   CAST(strftime('%s', ts) AS INTEGER) AS at
            FROM ai_audit_log a
            WHERE \(filter.predicates.joined(separator: " AND "))
            ORDER BY a.ts DESC, a.id DESC
            """, arguments: StatementArguments(filter.arguments))
        return try rows.map { row in
            try relay.check()
            let item = try Self.aiAuditItem(row)
            return AiAuditRecord(item: item, authority: try Self.bindingKey([
                item.id, try Self.optionalString(row, "session_id"),
                try Self.optionalString(row, "error"), try Self.optionalString(row, "caller"),
                try Self.optionalString(row, "model")
            ]))
        }
    }

    private func aiAuditDetailRow(_ db: Database, id: String, policy: ServiceWebMetadataPolicy) throws
        -> (EngramServiceWebAiAuditItem, Bool, Bool)? {
        guard try db.tableExists("ai_audit_log") else { throw ServiceWebMetadataError.unavailable }
        guard let row = try Row.fetchOne(db, sql: """
            SELECT id, caller, operation, method, url, status_code, duration_ms, model, provider,
                   prompt_tokens, completion_tokens, total_tokens, error, session_id,
                   CAST(strftime('%s', ts) AS INTEGER) AS at,
                   CASE WHEN request_body IS NOT NULL AND TRIM(request_body) != '' THEN 1 ELSE 0 END AS has_request_body,
                   CASE WHEN response_body IS NOT NULL AND TRIM(response_body) != '' THEN 1 ELSE 0 END AS has_response_body
            FROM ai_audit_log WHERE id = ?
            """, arguments: [id]) else { return nil }
        if let sessionId = try Self.optionalString(row, "session_id") {
            let admitted = try admittedAuditSessionIDs(db, policy: policy)
            guard let admitted, admitted.contains(ByteKey(sessionId)) else { return nil }
        }
        return (try Self.aiAuditItem(row), try Self.integer(row, "has_request_body") == 1,
                try Self.integer(row, "has_response_body") == 1)
    }

    private func aiStatsSnapshot(_ db: Database, request: EngramServiceWebAiStatsRequest,
                                 policy: ServiceWebMetadataPolicy, now: Date) throws -> AiStatsPrepared {
        let range = Self.resolvedStatsRange(request, now: now)
        let filter = try aiAuditFilter(db, caller: nil, model: nil, sessionId: nil,
            from: range.calendarFrom, to: range.calendarTo, hasError: nil,
            instantFrom: range.instantFrom, instantTo: range.instantTo, policy: policy)
        let whereSQL = filter.predicates.joined(separator: " AND ")
        guard let args = StatementArguments(filter.arguments) else {
            throw ServiceWebMetadataError.unavailable
        }
        let totalsRow = try Row.fetchOne(db, sql: """
            SELECT COUNT(*) AS requests,
                   COALESCE(SUM(CASE WHEN error IS NOT NULL THEN 1 ELSE 0 END), 0) AS errors,
                   COALESCE(SUM(prompt_tokens), 0) AS prompt_tokens,
                   COALESCE(SUM(completion_tokens), 0) AS completion_tokens,
                   CAST(COALESCE(ROUND(AVG(duration_ms)), 0) AS INTEGER) AS avg_duration_ms
            FROM ai_audit_log a WHERE \(whereSQL)
            """, arguments: args) ?? Row()
        let callers = try Row.fetchAll(db, sql: """
            SELECT caller, COUNT(*) AS requests,
                   COALESCE(SUM(CASE WHEN error IS NOT NULL THEN 1 ELSE 0 END), 0) AS errors,
                   COALESCE(SUM(prompt_tokens), 0) AS prompt_tokens,
                   COALESCE(SUM(completion_tokens), 0) AS completion_tokens
            FROM ai_audit_log a WHERE \(whereSQL)
            GROUP BY caller ORDER BY caller COLLATE BINARY
            """, arguments: args)
        let models = try Row.fetchAll(db, sql: """
            SELECT model, COUNT(*) AS requests,
                   COALESCE(SUM(prompt_tokens), 0) AS prompt_tokens,
                   COALESCE(SUM(completion_tokens), 0) AS completion_tokens
            FROM ai_audit_log a WHERE \(whereSQL) AND model IS NOT NULL AND TRIM(model) != ''
            GROUP BY model ORDER BY model COLLATE BINARY
            """, arguments: args)
        let hours = try Row.fetchAll(db, sql: """
            SELECT strftime('%Y-%m-%dT%H:00', ts) AS hour, COUNT(*) AS requests,
                   COALESCE(SUM(COALESCE(prompt_tokens, 0) + COALESCE(completion_tokens, 0)), 0) AS tokens
            FROM ai_audit_log a WHERE \(whereSQL)
            GROUP BY hour ORDER BY hour COLLATE BINARY
            """, arguments: args)
        return AiStatsPrepared(
            timeRange: .init(from: range.published.from, to: range.published.to),
            totals: .init(requests: try Self.integer(totalsRow, "requests"),
                errors: try Self.integer(totalsRow, "errors"),
                promptTokens: try Self.integer(totalsRow, "prompt_tokens"),
                completionTokens: try Self.integer(totalsRow, "completion_tokens"),
                avgDurationMs: try Self.integer(totalsRow, "avg_duration_ms")),
            byCaller: try callers.map { row in
                try relay.check()
                return EngramServiceWebAiStatsCaller(
                    key: try Self.requiredAuditText(row, "caller"),
                    requests: try Self.integer(row, "requests"), errors: try Self.integer(row, "errors"),
                    promptTokens: try Self.integer(row, "prompt_tokens"),
                    completionTokens: try Self.integer(row, "completion_tokens"))
            },
            byModel: try models.map { row in
                try relay.check()
                return EngramServiceWebAiStatsModel(
                    key: try Self.requiredAuditText(row, "model"),
                    requests: try Self.integer(row, "requests"),
                    promptTokens: try Self.integer(row, "prompt_tokens"),
                    completionTokens: try Self.integer(row, "completion_tokens"))
            },
            hourly: try hours.map { row in
                try relay.check()
                return EngramServiceWebAiStatsHour(
                    hour: try Self.string(row, "hour"),
                    requests: try Self.integer(row, "requests"), tokens: try Self.integer(row, "tokens"))
            })
    }

    private struct AiAuditFilter {
        let predicates: [String]
        let arguments: [DatabaseValueConvertible]
    }

    private func aiAuditFilter(_ db: Database, caller: String?, model: String?, sessionId: String?,
                               from: String?, to: String?, hasError: Bool?,
                               instantFrom: String? = nil, instantTo: String? = nil,
                               policy: ServiceWebMetadataPolicy) throws -> AiAuditFilter {
        guard try db.tableExists("ai_audit_log") else { throw ServiceWebMetadataError.unavailable }
        var predicates: [String] = []
        var arguments: [DatabaseValueConvertible] = []
        if let admitted = try admittedAuditSessionIDs(db, policy: policy), !admitted.isEmpty {
            let placeholders = admitted.map { _ in "?" }.joined(separator: ",")
            predicates.append("(a.session_id IS NULL OR a.session_id COLLATE BINARY IN (\(placeholders)))")
            arguments.append(contentsOf: admitted.map(\.string))
        } else {
            predicates.append("a.session_id IS NULL")
        }
        if let sessionId {
            predicates.append("a.session_id = ? COLLATE BINARY")
            arguments.append(sessionId)
        }
        if let caller {
            predicates.append("a.caller = ? COLLATE BINARY")
            arguments.append(caller)
        }
        if let model {
            predicates.append("a.model = ? COLLATE BINARY")
            arguments.append(model)
        }
        if let from { predicates.append("date(a.ts, 'localtime') >= ?"); arguments.append(from) }
        if let to { predicates.append("date(a.ts, 'localtime') <= ?"); arguments.append(to) }
        if let instantFrom { predicates.append("julianday(a.ts) > julianday(?)"); arguments.append(instantFrom) }
        if let instantTo { predicates.append("julianday(a.ts) <= julianday(?)"); arguments.append(instantTo) }
        if hasError == true { predicates.append("a.error IS NOT NULL") }
        if hasError == false { predicates.append("a.error IS NULL") }
        return AiAuditFilter(predicates: predicates, arguments: arguments)
    }

    /// Currently admitted session ids, keyed byte-exactly. On HQ this set holds
    /// tens of thousands of long shared-prefix ids, so it must not be `Set<Data>`
    /// (see `ByteKey`).
    private func admittedAuditSessionIDs(_ db: Database, policy: ServiceWebMetadataPolicy) throws -> Set<ByteKey>? {
        let request = try EngramServiceWebSessionsRequest(agents: .hide, limit: 1)
        guard let filter = try sessionFilter(db, request: request, policy: policy, sessionIDs: nil) else {
            return nil
        }
        let rows = try Row.fetchAll(db, sql: """
            SELECT s.id FROM sessions s
            JOIN capture_ingest_identity_bindings i ON i.stored_session_id = s.id COLLATE BINARY
            \(Self.registryJoinSQL)
            WHERE \(filter.predicates.joined(separator: " AND "))
            """, arguments: StatementArguments(filter.arguments))
        return Set(try rows.map { ByteKey(try Self.string($0, "id")) })
    }

    private static func resolvedStatsRange(_ request: EngramServiceWebAiStatsRequest, now: Date)
        -> (calendarFrom: String?, calendarTo: String?, instantFrom: String?, instantTo: String?,
            published: (from: String, to: String)) {
        let last24h = now.addingTimeInterval(-86_400)
        switch (request.from, request.to) {
        case let (from?, to?):
            return (from, to, nil, nil,
                    (isoUTC(localDay(from, end: false)), isoUTC(localDay(to, end: true))))
        case let (from?, nil):
            return (from, nil, nil, isoUTC(now),
                    (isoUTC(localDay(from, end: false)), isoUTC(now)))
        case let (nil, to?):
            return (nil, to, isoUTC(last24h), nil,
                    (isoUTC(last24h), isoUTC(localDay(to, end: true))))
        case (nil, nil):
            return (nil, nil, isoUTC(last24h), isoUTC(now), (isoUTC(last24h), isoUTC(now)))
        }
    }

    private static func aiAuditItem(_ row: Row) throws -> EngramServiceWebAiAuditItem {
        let id = String(try integer(row, "id"))
        try EngramServiceWebMetadataValidation.positiveDecimal(id)
        let at = try integer(row, "at")
        let error = publishedAuditText(try optionalString(row, "error"), maximumBytes: 1024)
        let sessionId = try optionalString(row, "session_id").flatMap { value in
            (try? EngramServiceWebMetadataValidation.sessionID(value)).map { _ in value }
        }
        return EngramServiceWebAiAuditItem(
            id: id, at: at,
            caller: try requiredAuditText(row, "caller"),
            operation: try requiredAuditText(row, "operation"),
            method: publishedAuditText(try optionalString(row, "method"), maximumBytes: 16),
            url: publishedAuditURL(try optionalString(row, "url")),
            statusCode: try optionalInteger(row, "status_code"),
            durationMs: try optionalInteger(row, "duration_ms"),
            model: publishedAuditText(try optionalString(row, "model"), maximumBytes: 256),
            provider: publishedAuditText(try optionalString(row, "provider"), maximumBytes: 256),
            promptTokens: try optionalInteger(row, "prompt_tokens"),
            completionTokens: try optionalInteger(row, "completion_tokens"),
            totalTokens: try optionalInteger(row, "total_tokens"),
            hasError: error != nil, error: error, sessionId: sessionId)
    }

    private static func requiredAuditText(_ row: Row, _ column: String) throws -> String {
        guard let value = publishedAuditText(try optionalString(row, column), maximumBytes: 256) else {
            throw ServiceWebMetadataError.unavailable
        }
        return value
    }

    private static func publishedAuditText(_ value: String?, maximumBytes: Int) -> String? {
        guard let value, !value.isEmpty, !value.utf8.contains(0) else { return nil }
        var text = TranscriptRedactionPolicy.redact(value)
        if text.utf8.count > maximumBytes {
            text = String(decoding: Data(text.utf8.prefix(maximumBytes)), as: UTF8.self)
        }
        return text.isEmpty ? nil : text
    }

    private static func publishedAuditURL(_ value: String?) -> String? {
        guard let text = publishedAuditText(value, maximumBytes: 1024),
              let url = URL(string: text), let host = url.host else { return nil }
        return "\(url.scheme ?? "https")://\(host)\(url.path)"
    }

    private static func isoUTC(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func localDay(_ value: String, end: Bool) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let bytes = Array(value.utf8)
        var components = DateComponents()
        components.year = Int(String(decoding: bytes[0..<4], as: UTF8.self))
        components.month = Int(String(decoding: bytes[5..<7], as: UTF8.self))
        components.day = Int(String(decoding: bytes[8..<10], as: UTF8.self))
        if end {
            components.hour = 23; components.minute = 59; components.second = 59
        } else {
            components.hour = 0; components.minute = 0; components.second = 0
        }
        return calendar.date(from: components) ?? Date()
    }

    /// One aggregated file. The display label is derived on `item`, so only
    /// the page that is actually returned pays `fileActivityLabel` (the
    /// redaction pass cost ~50µs per distinct path; HQ has ~16k of them and
    /// the freshness re-check aggregates a second time).
    private struct FileActivityRecord: Equatable {
        let path: String
        let key: String
        let readCount: Int64
        let editCount: Int64
        let writeCount: Int64
        let sessionCount: Int64
        let authority: Data
        var operations: Int64 { readCount + editCount + writeCount }
        var item: EngramServiceWebFileActivityItem {
            .init(key: key, label: ServiceWebMetadataProducer.fileActivityLabel(path), readCount: readCount,
                  editCount: editCount, writeCount: writeCount, sessionCount: sessionCount)
        }
    }

    /// Published keys of file paths seen by `fileActivityRows`, shared by the
    /// snapshot read, the freshness re-check and later requests. The key is a
    /// pure function of the path (`publishedProjectKey`: a SHA-256 for
    /// anything that is not a bare token), so caching cannot go stale; it is
    /// bounded and simply starts over when full.
    private final class FileKeyCache: @unchecked Sendable {
        private let lock = NSLock()
        private var keys: [ByteKey: String] = [:]
        private static let capacity = 65_536

        func key(for path: String) -> String {
            let pathKey = ByteKey(path)
            if let known = lock.withLock({ keys[pathKey] }) { return known }
            let key = ServiceWebMetadataProducer.publishedProjectKey(path) ?? "u.file"
            lock.withLock {
                if keys.count >= Self.capacity { keys.removeAll(keepingCapacity: true) }
                keys[pathKey] = key
            }
            return key
        }
    }
    private let fileKeys = FileKeyCache()

    private func fileActivityRows(_ db: Database, request: EngramServiceWebFileActivityRequest,
                                  policy: ServiceWebMetadataPolicy) throws -> [FileActivityRecord] {
        guard try db.tableExists("session_files") else { throw ServiceWebMetadataError.unavailable }
        guard let filter = try sessionFilter(db, request: .init(agents: request.agents), policy: policy, sessionIDs: nil) else {
            return []
        }
        var predicates = filter.predicates, arguments = filter.arguments
        if let project = request.project {
            predicates.append("s.project LIKE ? ESCAPE '\\'")
            arguments.append("%" + CJKText.escapeLikePattern(project) + "%")
        }
        let activity = "date(COALESCE(NULLIF(s.end_time, ''), s.start_time), 'localtime')"
        if let since = request.since { predicates.append("\(activity) >= ?"); arguments.append(since) }
        if let until = request.until { predicates.append("\(activity) <= ?"); arguments.append(until) }
        // No ORDER BY: the sort of the joined rows in a temp B-tree was 0.46s
        // of a 0.50s statement on HQ (23k rows after the agent filter) and
        // runs twice per request. Group authority is made order-independent
        // below instead, so the planner's row order does not matter.
        let rows = try Row.fetchAll(db, sql: """
            SELECT f.file_path, f.action, f.count, s.id, i.machine_id, i.source_instance_id
            FROM session_files f \(Self.sessionsJoinSQL(agents: request.agents, on: "s.id = f.session_id COLLATE BINARY"))
            JOIN capture_ingest_identity_bindings i ON i.stored_session_id = s.id COLLATE BINARY
            \(Self.registryJoinSQL)
            WHERE \(predicates.joined(separator: " AND ")) AND f.count > 0
            """, arguments: StatementArguments(arguments))
        // Same shape as toolAnalyticsRows: cached stream bindings and
        // sole-owner group mutation instead of per-row copies. File paths
        // under one checkout and HQ session ids both share long prefixes, so
        // keys are `ByteKey` rather than the 80-byte-hashed `Data`. Each row
        // contributes one fixed-size digest; the group digest absorbs them in
        // byte order at the end, so equal row sets give equal authorities
        // whatever order SQLite returned them in.
        struct Group {
            var path: String
            var read: Int64 = 0; var edit: Int64 = 0; var write: Int64 = 0
            var sessions: Set<ByteKey> = []; var rows: [Data] = []
        }
        var groups: [ByteKey: Group] = [:]
        var bindings: [StreamKey: CaptureIngestSourceBinding?] = [:]
        for row in rows {
            try relay.check()
            let binding = try cachedBinding(db, row: row, policy: policy, cache: &bindings)
            guard let binding else { continue }
            let path = try Self.string(row, "file_path")
            guard !path.isEmpty, !path.utf8.contains(0) else { throw ServiceWebMetadataError.unavailable }
            let action = try Self.string(row, "action")
            let count = try Self.integer(row, "count")
            try EngramServiceWebMetadataValidation.count(count)
            let pathKey = ByteKey(path)
            var group = groups.removeValue(forKey: pathKey) ?? Group(path: path)
            switch action {
            case "read": group.read = try Self.addToolCalls(group.read, count)
            case "edit": group.edit = try Self.addToolCalls(group.edit, count)
            case "write": group.write = try Self.addToolCalls(group.write, count)
            default:
                groups[pathKey] = group
                continue
            }
            group.sessions.insert(ByteKey(try Self.string(row, "id")))
            var rowDigest = SHA256()
            Self.absorb(&rowDigest, Self.bindingFields(binding) + [path, action, String(count)])
            group.rows.append(Data(rowDigest.finalize()))
            groups[pathKey] = group
        }
        return try groups.values.compactMap { group -> FileActivityRecord? in
            let operations = try Self.addToolCalls(try Self.addToolCalls(group.read, group.edit), group.write)
            guard operations > 0 else { return nil }
            var authority = SHA256()
            for digest in group.rows.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
                authority.update(data: digest)
            }
            return FileActivityRecord(
                path: group.path, key: fileKeys.key(for: group.path), readCount: group.read,
                editCount: group.edit, writeCount: group.write, sessionCount: Int64(group.sessions.count),
                authority: Data(authority.finalize()))
        }.sorted {
            if $0.operations != $1.operations { return $0.operations > $1.operations }
            return $0.key.utf8.lexicographicallyPrecedes($1.key.utf8)
        }
    }

    private struct ToolAnalyticsRecord: Equatable {
        let item: EngramServiceWebToolAnalyticsItem
        let authority: Data
    }

    private static func addToolCalls(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow, sum >= 0 else { throw ServiceWebMetadataError.unavailable }
        try EngramServiceWebMetadataValidation.count(sum)
        return sum
    }

    private func toolAnalyticsRows(_ db: Database, request: EngramServiceWebToolAnalyticsRequest,
                                   policy: ServiceWebMetadataPolicy) throws -> [ToolAnalyticsRecord] {
        guard try db.tableExists("session_tools"),
              let filter = try sessionFilter(db, request: .init(agents: request.agents), policy: policy, sessionIDs: nil) else { return [] }
        var predicates = filter.predicates, arguments = filter.arguments
        if let project = request.project {
            predicates.append("s.project LIKE ? ESCAPE '\\'")
            arguments.append("%" + CJKText.escapeLikePattern(project) + "%")
        }
        let activity = "date(COALESCE(NULLIF(s.end_time, ''), s.start_time), 'localtime')"
        if let since = request.since { predicates.append("\(activity) >= ?"); arguments.append(since) }
        if let until = request.until { predicates.append("\(activity) <= ?"); arguments.append(until) }
        let rows = try Row.fetchAll(db, sql: """
            SELECT t.tool_name, t.call_count, s.id, s.project, s.custom_name, s.generated_title,
                   i.machine_id, i.source_instance_id
            FROM session_tools t \(Self.sessionsJoinSQL(agents: request.agents, on: "s.id = t.session_id COLLATE BINARY"))
            JOIN capture_ingest_identity_bindings i ON i.stored_session_id = s.id COLLATE BINARY
            \(Self.registryJoinSQL)
            WHERE \(predicates.joined(separator: " AND ")) AND t.call_count > 0
            ORDER BY s.id COLLATE BINARY, t.tool_name COLLATE BINARY
            """, arguments: StatementArguments(arguments))
        // Authority is a running digest over the canonical row fields in the
        // query's ORDER BY. The earlier shape appended every row's fields to
        // one array per group, read the group out of the dictionary by value
        // (copying its sets/array on every row) and canonical-JSON-encoded the
        // whole array at the end; on HQ (21k joined rows, twice per request
        // for the freshness re-check) that exceeded the 2s metadata deadline.
        // Keys are `ByteKey`, not `Data`: with HQ's long shared-prefix session
        // ids a `Data`-keyed dictionary/set degrades to linear probing (see
        // `ByteKey`), which is what kept `groupBy=session` over the deadline.
        struct Group {
            var key: String; var label: String; var calls: Int64 = 0
            var sessions: Set<ByteKey> = []; var tools: Set<ByteKey> = []; var authority = SHA256()
        }
        var groups: [ByteKey: Group] = [:]
        var bindings: [StreamKey: CaptureIngestSourceBinding?] = [:]
        var derived: [String?: (key: String, label: String)] = [:]
        for row in rows {
            try relay.check()
            let binding = try cachedBinding(db, row: row, policy: policy, cache: &bindings)
            guard let binding else { continue }
            let id = try Self.string(row, "id"), tool = try Self.string(row, "tool_name")
            let calls = try Self.integer(row, "call_count")
            try EngramServiceWebMetadataValidation.count(calls)
            // Key/label derivation runs the redaction regex set; memoize it per
            // raw grouping value instead of per joined row.
            let raw: String?
            switch request.groupBy {
            case .tool: raw = tool
            case .session: raw = id
            case .project: raw = try Self.optionalString(row, "project")
            }
            let key: String, label: String
            if let known = derived[raw] {
                (key, label) = known
            } else {
                switch request.groupBy {
                case .tool:
                    key = Self.publishedProjectKey(tool) ?? "u.tool"
                    label = Self.safeText(tool, maximumBytes: 1024) ?? "Unknown tool"
                case .session:
                    key = id
                    let title = try Self.optionalString(row, "custom_name") ?? Self.optionalString(row, "generated_title")
                    label = Self.safeText(title, maximumBytes: 1024) ?? "Untitled session"
                case .project:
                    key = Self.publishedProjectKey(raw) ?? EngramServiceWebMetadataValidation.unknownProjectKey
                    label = raw.map { Self.facetProjectLabel($0) } ?? "Unknown project"
                }
                derived[raw] = (key, label)
            }
            let groupKey = ByteKey(key)
            // removeValue hands back the sole owner, so the mutations below do
            // not copy the group's sets (docs: Swift copy-on-write).
            var group = groups.removeValue(forKey: groupKey) ?? Group(key: key, label: label)
            group.calls = try Self.addToolCalls(group.calls, calls)
            group.sessions.insert(ByteKey(id)); group.tools.insert(ByteKey(tool))
            Self.absorb(&group.authority, Self.bindingFields(binding) + [id, tool, String(calls)])
            groups[groupKey] = group
        }
        return groups.values.map { group in
            ToolAnalyticsRecord(item: .init(key: group.key, label: group.label, callCount: group.calls,
                sessionCount: Int64(group.sessions.count), toolCount: Int64(group.tools.count),
                sessionId: request.groupBy == .session ? group.key : nil),
                authority: Data(group.authority.finalize()))
        }.sorted {
            if $0.item.callCount != $1.item.callCount { return $0.item.callCount > $1.item.callCount }
            return $0.item.key.utf8.lexicographicallyPrecedes($1.item.key.utf8)
        }
    }

    func costs(
        _ request: EngramServiceWebCostsRequest,
        requestId: String,
        deadline: ContinuousClock.Instant
    ) async throws -> EngramServiceWebCostsResponse {
        try await submit(deadline: deadline) { control in
            let policy = try self.currentPolicy()
            let key = try Self.bindingKey([
                "costs", request.groupBy.rawValue, request.source, try Self.listIdentity(request.sources),
                request.machineId, request.sourceInstanceId, request.projectKey,
                try Self.listIdentity(request.projectKeys), request.sessionId, request.agents.rawValue,
                request.since, request.until, request.tools.rawValue, String(request.limit),
                ServiceWebMetadataLimits.sortVersion,
            ])
            let (lease, position) = try self.acquire(snapshotID: request.snapshotId, cursor: request.cursor,
                key: key, policy: policy, control: control)
            let prepared = try self.read(lease.snapshot, control: control) { db in
                try self.costsAggregate(db, request: request, policy: policy, after: position.key,
                                        limit: request.limit + 1)
            }
            let token = position.successor ?? Self.token()
            let timeZone = TimeZone.current.identifier
            let count = try Self.fittingCount(prepared.items.count, limit: request.limit, fixed: position.count) { count in
                try Self.encodedSuccessFrame(requestId: requestId, result: Self.costsResponse(
                    lease: lease, groupBy: request.groupBy, timeZone: timeZone, prepared: prepared,
                    count: count, nextCursor: prepared.items.count > count ? token : nil))
            }
            let page = Array(prepared.items.prefix(count))
            try self.hooks.afterPreparation?(.costs)
            try self.requirePolicy(policy)
            try self.pool.read { db in
                try self.requireSchema(db, lease: lease)
                try control.check()
                let fresh = try self.costsAggregate(db, request: request, policy: policy, after: nil,
                                                    limit: max(page.count, 1), keys: page.map(\.item.key))
                guard fresh.totals == prepared.totals, fresh.unpriced == prepared.unpriced else {
                    throw ServiceWebMetadataError.stale
                }
                if !page.isEmpty {
                    var byKey: [Data: CostRecord] = [:]
                    byKey.reserveCapacity(fresh.items.count)
                    for row in fresh.items { byKey[Data(row.item.key.utf8)] = row }
                    for item in page {
                        try control.check()
                        guard let row = byKey[Data(item.item.key.utf8)],
                              row.authority == item.authority else { throw ServiceWebMetadataError.stale }
                    }
                }
            }
            try self.requirePolicy(policy)
            try control.check()
            let next = try self.successor(lease, position: position, count: count, hasMore: prepared.items.count > count,
                last: page.last.map { .facet($0.item.key) }, proposed: token)
            let result = Self.costsResponse(lease: lease, groupBy: request.groupBy, timeZone: timeZone,
                                            prepared: prepared, count: count, nextCursor: next)
            try Self.validate(result, requestID: requestId)
            return result
        }
    }

    func costSessions(
        _ request: EngramServiceWebCostSessionsRequest,
        requestId: String,
        deadline: ContinuousClock.Instant
    ) async throws -> EngramServiceWebCostSessionsResponse {
        try await submit(deadline: deadline) { control in
            let policy = try self.currentPolicy()
            let filter = try self.sessionsFilter(from: request)
            let prepared = try self.pool.read { db in
                try control.check()
                return try self.costSessionRows(db, request: filter, policy: policy, limit: request.limit)
            }
            try self.hooks.afterPreparation?(.costSessions)
            try self.requirePolicy(policy)
            try self.pool.read { db in
                try control.check()
                for item in prepared {
                    try control.check()
                    let rows = try self.costSessionRows(db, request: filter, policy: policy, limit: 1,
                                                       sessionIDs: [item.item.session.sessionId])
                    guard let row = rows.first,
                          row.item.session.sessionId.utf8.elementsEqual(item.item.session.sessionId.utf8),
                          row.authority == item.authority else { throw ServiceWebMetadataError.stale }
                }
            }
            let result = EngramServiceWebCostSessionsResponse(
                observedAt: Self.observedAt(), items: prepared.map(\.item))
            try Self.validate(result, requestID: requestId)
            return result
        }
    }

    func stop() throws {
        admission.lock()
        if closed {
            let failed = closeFailed
            admission.unlock()
            if failed { throw ServiceWebMetadataError.unavailable }
            return
        }
        let onQueue = DispatchQueue.getSpecific(key: queueKey) == true
        if onQueue, !pending.isEmpty {
            // A synchronous API cannot join itself. No timer or internal work
            // path calls stop; reentrant test hooks must not pretend to drain.
            admission.unlock()
            throw ServiceWebMetadataError.unavailable
        }
        if stopping {
            while !closed { admission.wait() }
            let failed = closeFailed
            admission.unlock()
            if failed { throw ServiceWebMetadataError.unavailable }
            return
        }
        stopping = true
        let controls = Array(pending.values)
        admission.unlock()
        controls.forEach { $0.cancel() }
        let closeAll = {
            var failed = false
            for id in Array(self.leases.keys) {
                do { try self.retire(id) } catch { failed = true }
            }
            do { try self.pool.close() } catch { failed = true }
            return failed
        }
        // Every admitted operation was enqueued before releasing admission.
        // The barrier joins entered work and its cleanup, not just its waiter.
        let failed = onQueue ? closeAll() : queue.sync(execute: closeAll)
        admission.lock()
        closeFailed = closeFailed || failed
        closed = true
        admission.broadcast()
        let resultFailed = closeFailed
        admission.unlock()
        if resultFailed { throw ServiceWebMetadataError.unavailable }
    }

    static func encodedSuccessFrame(requestId: String, result: some Encodable) throws -> Data {
        let payload = try JSONEncoder().encode(result)
        return try JSONEncoder().encode(
            EngramServiceResponseEnvelope.success(requestId: requestId, result: payload)
        )
    }

    static func isValidParserRevision(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 128
            && !value.utf8.contains(0)
            && value.utf8.elementsEqual(value.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
    }

    private func currentPolicy() throws -> ServiceWebMetadataPolicy {
        guard let policy = try policySource() else { throw ServiceWebMetadataError.unavailable }
        guard Self.isValidParserRevision(policy.parserRevision), !policy.enabledSources.isEmpty else {
            throw ServiceWebMetadataError.unavailable
        }
        return policy
    }

    // MARK: - Bounded scalar metadata (no archive or normalized payload reads)

    private static func schema(_ db: Database) throws -> Schema {
        let captureTables = ["capture_ingest_source_registry", "capture_ingest_epoch_history",
            "capture_ingest_publications", "capture_ingest_ledger", "capture_ingest_identity_bindings",
            "capture_ingest_generations"]
        var capture = true
        for table in captureTables { if try !db.tableExists(table) { capture = false } }
        return Schema(capture: capture, fts: try db.tableExists("sessions_fts"))
    }

    /// Fail-closed owned internal-content FTS5. `sqlite_master.sql` must match
    /// the known create/rename identifier variants; `fts_map` / `tableExists`
    /// are not enough to seek `c0`.
    private static func hasOwnedInternalFTSContent(_ db: Database) throws -> Bool {
        try FTSRebuildPolicy.hasOwnedInternalFTSContent(db)
    }

    private static let privacySQL = privacyPredicate(column: "s.")
    /// Children statement only. The unary plus on each `sessions` column keeps
    /// the privacy terms from being used as index constraints. An HQ database
    /// that has never been `ANALYZE`d has no `sqlite_stat1`, so the planner
    /// assumes any indexed equality returns ~10 rows: it took the partial
    /// `idx_sessions_visible (hidden_at=?)`, which matches every visible
    /// session (44k on HQ, 1.53s per children request, a 503 at the 2s
    /// deadline), and with that gone and few enabled sources it takes
    /// `idx_sessions_source (source=?)` through the transitive
    /// `s.source = i.source AND i.source IN (…)`, a scan of one source's
    /// sessions. With neither available the multi-index OR over
    /// `idx_sessions_parent` / `idx_sessions_suggested_parent` is the only
    /// cheap plan for any source count, with or without statistics (0.08s on
    /// the same HQ database, 2,315 children). The list statements keep the
    /// plain columns.
    private static let childPrivacySQL = privacyPredicate(column: "+s.")
    private static func privacyPredicate(column: String) -> String {
        """
        \(column)hidden_at IS NULL
        AND \(column)source = i.source COLLATE BINARY
        AND \(column)authoritative_node = ('capture-v1.' || i.machine_id || '.' || i.source_instance_id) COLLATE BINARY
        """
    }
    private static let skipSQL = "(s.tier IS NULL OR s.tier != 'skip')"
    /// `sessions s` join for statements driven by the whole visible session
    /// set. `.hide` statements carry `parent_session_id IS NULL AND
    /// suggested_parent_id IS NULL`, three equalities that make the planner
    /// take the covering partial `idx_sessions_web_list_keys` by itself.
    /// `.all` and `.only` have `hidden_at IS NULL` as their only index
    /// constraint; without statistics (HQ has none) the planner takes
    /// `idx_sessions_visible` and reads every visible session's row, 44k on
    /// HQ of which 32k are skip-tier and discarded: 2.4s for tool analytics and
    /// file activity (503 at the 2s deadline), 1.7s for the list. The
    /// skip-excluding partial `idx_sessions_activity_time` (a migration-owned
    /// index that exists wherever the schema does) visits 11.8k entries
    /// instead: 0.63s, 0.56s and 0.03s for the same statements, and the
    /// search total (`sessionCount` with the FTS hit set as an IN filter)
    /// 1.65s → 0.02s. `INDEXED BY` makes that choice deterministic; it must
    /// not be used where `s` has to be reached by primary key (the list's id
    /// batches and its identity-first search page).
    static let visibleSessionsIndex = "idx_sessions_activity_time"
    static func sessionsJoinSQL(agents: EngramServiceWebAgentFilter, on: String) -> String {
        agents == .hide ? "JOIN sessions s ON \(on)" : "JOIN sessions s INDEXED BY \(visibleSessionsIndex) ON \(on)"
    }
    /// The live id batch (the freshness re-check of one page, at most 50
    /// ids). With `agents=all` and a `query`, the plain join was planned from
    /// `idx_sessions_visible` as well and re-read all 44k visible rows to
    /// re-check 20 ids (1.2s of a 1.8s request on HQ). The primary key is the
    /// only sane driver for an id batch under any filter, so pin it when the
    /// implicit index carries its usual name; otherwise leave the planner alone.
    static let sessionsPrimaryKeyIndex = "sqlite_autoindex_sessions_1"
    static func primaryKeyJoinSQL(_ db: Database, on: String) throws -> String {
        let present = try Bool.fetchOne(db, sql: """
            SELECT EXISTS (SELECT 1 FROM sqlite_master WHERE type = 'index' AND tbl_name = 'sessions' AND name = ?)
            """, arguments: [sessionsPrimaryKeyIndex]) ?? false
        return present ? "JOIN sessions s INDEXED BY \(sessionsPrimaryKeyIndex) ON \(on)" : "JOIN sessions s ON \(on)"
    }
    /// Children of one parent, confirmed or suggested. No explicit COLLATE on
    /// either term: both columns are plain TEXT (BINARY by default), and an
    /// explicit `COLLATE` on either side of an OR term disables SQLite's
    /// multi-index OR optimisation outright, so HQ walked every one of its 38k
    /// identity bindings per children request (1.96s cold). Eligibility alone
    /// is not enough; see `childPrivacySQL` for the term that made the planner
    /// take this OR on a statistics-free database.
    static let childParentPredicateSQL = "(s.parent_session_id = ? OR s.suggested_parent_id = ?)"
    /// Visibility predicate the children statement sends: `.all` agents, with
    /// the children-only `hidden_at` term.
    static let childVisibilitySQL = "\(childPrivacySQL) AND \(skipSQL)"
    private static let topLevelSQL = "s.parent_session_id IS NULL AND s.suggested_parent_id IS NULL"
    private static let isAgentSQL = """
        (s.parent_session_id IS NOT NULL OR s.suggested_parent_id IS NOT NULL
         OR s.agent_role IN ('subagent', 'dispatched'))
        """
    /// NULL agent_role is not an agent. `NOT (role IN (...))` is unknown for NULL
    /// and would drop ordinary top-level rows from hide.
    private static let notAgentSQL = """
        s.parent_session_id IS NULL AND s.suggested_parent_id IS NULL
        AND (s.agent_role IS NULL OR s.agent_role NOT IN ('subagent', 'dispatched'))
        """
    private static let visibleSQL = """
        \(privacySQL)
        AND \(skipSQL)
        AND \(topLevelSQL)
        """

    private static func sessionVisibilitySQL(_ agents: EngramServiceWebAgentFilter) -> String {
        switch agents {
        case .hide: return "\(privacySQL) AND \(skipSQL) AND \(notAgentSQL)"
        case .all: return "\(privacySQL) AND \(skipSQL)"
        case .only: return "\(privacySQL) AND \(skipSQL) AND \(isAgentSQL)"
        }
    }

    private static func listIdentity(_ values: [String]?) throws -> String? {
        guard let values else { return nil }
        return String(decoding: try ArchiveCanonicalJSON.encode(values), as: UTF8.self)
    }
    private static let registryJoinSQL = """
        JOIN capture_ingest_source_registry r
          ON r.machine_id = i.machine_id COLLATE BINARY AND r.source_instance_id = i.source_instance_id COLLATE BINARY
          AND r.source = i.source COLLATE BINARY
        JOIN capture_ingest_epoch_history h
          ON h.machine_id = r.machine_id COLLATE BINARY AND h.source_instance_id = r.source_instance_id COLLATE BINARY
          AND h.authority_generation = r.authority_generation AND h.approved_epoch = r.approved_epoch COLLATE BINARY
        """
    private static let startSQL = """
        CASE WHEN CAST(strftime('%s', s.start_time) AS INTEGER) BETWEEN 0 AND 253402300799
             THEN CAST(strftime('%s', s.start_time) AS INTEGER) ELSE NULL END
        """
    /// Legacy `5013bab7` `src/tools/search.ts` 279–282: hide only proven tool-only sessions.
    private static let toolOnlyHideSQL = """
        NOT (
          typeof(s.tool_message_count) = 'integer' AND s.tool_message_count > 0
          AND typeof(s.user_message_count) = 'integer' AND s.user_message_count = 0
        )
        """

    private struct SessionRecord {
        let summary: EngramServiceWebSessionSummary
        let authority: Data
        let parsedID: String?
        let readyID: String?
    }
    private struct ChildRecord {
        let item: EngramServiceWebChildItem
        let authority: Data
    }
    private struct CountedStream {
        let machineID: String
        let instanceID: String
        let authority: Data
    }
    private struct SessionsTotal {
        let count: Int64
        let streams: [CountedStream]
    }
    private struct SessionsPrepared {
        let rows: [SessionRecord]
        let total: SessionsTotal
        var totalCount: Int64 { total.count }
    }
    private struct FacetRecord {
        let item: EngramServiceWebFacetItem
        let authority: Data
    }
    private struct StreamRecord {
        let overview: EngramServiceWebStreamOverview
        let authority: Data
        var machineID: String { overview.machineId }
        var instanceID: String { overview.sourceInstanceId }
    }

    private func binding(_ db: Database, machineID: String, instanceID: String,
                         policy: ServiceWebMetadataPolicy) throws -> CaptureIngestSourceBinding? {
        do {
            guard let value = try CaptureIngestSourceRegistry.binding(db, machineID: machineID, sourceInstanceID: instanceID),
                  policy.enabledSources.contains(value.source) else { return nil }
            return value
        } catch is CaptureIngestSourceRegistryError { return nil }
    }

    private struct StreamKey: Hashable {
        let machineID: String
        let sourceInstanceID: String
    }

    /// Byte-exact hashable key for identifier-keyed aggregation.
    ///
    /// `Data.hash(into:)` hashes at most the first 80 bytes. HQ session ids are
    /// `remote:capture-v1.<machine>.<instance>:<native>` (about 196 bytes) and
    /// every session of one capture stream shares well over 80 leading bytes,
    /// so a `[Data: _]` or `Set<Data>` keyed by them collapses into a single
    /// bucket chain: 8k such keys cost about 9s of probing against 12ms with
    /// full-byte hashing (measured 2026-09-14). Equality stays byte-exact, as
    /// with `Data`; only the hash covers every byte.
    private struct ByteKey: Hashable {
        let bytes: Data

        init(_ string: String) { bytes = Data(string.utf8) }

        var string: String { String(decoding: bytes, as: UTF8.self) }

        static func == (lhs: ByteKey, rhs: ByteKey) -> Bool { lhs.bytes == rhs.bytes }

        func hash(into hasher: inout Hasher) {
            bytes.withUnsafeBytes { hasher.combine(bytes: $0) }
        }
    }

    /// Feeds fields into a running authority digest as length-prefixed UTF-8
    /// with a distinct nil tag, so the encoding is injective without the
    /// per-row `JSONEncoder` that `bindingKey` pays (tens of µs per call).
    private static func absorb(_ hasher: inout SHA256, _ fields: [String?]) {
        for field in fields {
            guard let field else {
                hasher.update(data: Data([0xFF]))
                continue
            }
            var length = UInt64(field.utf8.count).littleEndian
            withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
            hasher.update(data: Data(field.utf8))
        }
    }

    /// `binding(_:machineID:instanceID:policy:)` memoized per capture stream for
    /// row loops: a stream contributes thousands of rows but resolves once.
    private func cachedBinding(_ db: Database, row: Row, policy: ServiceWebMetadataPolicy,
                               cache: inout [StreamKey: CaptureIngestSourceBinding?]) throws -> CaptureIngestSourceBinding? {
        let key = StreamKey(machineID: try Self.string(row, "machine_id"),
                            sourceInstanceID: try Self.string(row, "source_instance_id"))
        if let known = cache[key] { return known }
        let resolved = try binding(db, machineID: key.machineID, instanceID: key.sourceInstanceID, policy: policy)
        cache[key] = .some(resolved)
        return resolved
    }

    private static func bindingFields(_ value: CaptureIngestSourceBinding) -> [String?] {
        [value.machineID, value.sourceInstanceID, value.source.rawValue, value.parseFormat.rawValue,
         value.configuredRoot, value.approvedEpoch, String(value.authorityGeneration)]
    }

    private func overviewRows(_ db: Database, policy: ServiceWebMetadataPolicy, after: PositionKey?,
                              limit: Int, observedAt: Int64) throws -> (rows: [StreamRecord], hasMore: Bool) {
        guard try Self.schema(db).capture else { return ([], false) }
        let sources = policy.enabledSources.map(\.rawValue).sorted()
        let placeholders = Array(repeating: "?", count: sources.count).joined(separator: ",")
        var position = after
        var result: [StreamRecord] = []
        repeat {
            try relay.check()
            let batch = max(limit - result.count, 1)
            var args: [DatabaseValueConvertible] = sources.map { $0 }
            var predicate = "r.source IN (\(placeholders))"
            if let position {
                guard case .stream(let machine, let instance) = position else { throw ServiceWebMetadataError.stale }
                predicate += " AND (r.machine_id COLLATE BINARY > ? OR (r.machine_id = ? COLLATE BINARY AND r.source_instance_id COLLATE BINARY > ?))"
                args.append(contentsOf: [machine, machine, instance])
            }
            args.append(batch)
            let rows = try Row.fetchAll(db, sql: """
                SELECT r.machine_id, r.source_instance_id FROM capture_ingest_source_registry r
                WHERE \(predicate) ORDER BY r.machine_id COLLATE BINARY, r.source_instance_id COLLATE BINARY LIMIT ?
                """, arguments: StatementArguments(args))
            for row in rows {
                let machine = try Self.string(row, "machine_id")
                let instance = try Self.string(row, "source_instance_id")
                position = .stream(machine, instance)
                if result.count < limit {
                    if let record = try stream(db, machineID: machine, instanceID: instance, policy: policy, observedAt: observedAt) {
                        result.append(record)
                    }
                } else if try binding(db, machineID: machine, instanceID: instance, policy: policy) != nil {
                    return (result, true)
                }
            }
            if rows.count < batch { return (result, false) }
        } while true
    }

    private func stream(_ db: Database, machineID: String, instanceID: String,
                        policy: ServiceWebMetadataPolicy, observedAt: Int64) throws -> StreamRecord? {
        guard try Self.schema(db).capture,
              let binding = try binding(db, machineID: machineID, instanceID: instanceID, policy: policy) else { return nil }
        try relay.check()
        let args: StatementArguments = [machineID, instanceID]
        let publications = try Self.count(db, sql: """
            SELECT COUNT(*) AS value FROM capture_ingest_publications WHERE machine_id = ? AND source_instance_id = ?
            """, arguments: args)
        var counts: [String: Int64] = [:]
        var failures: Int64 = 0
        var oldest: Int64?
        for row in try Row.fetchAll(db, sql: """
            SELECT l.status, COUNT(*) AS value,
            SUM(CASE WHEN l.status IN ('failed_retryable','quarantined') AND substr(l.failure_code,1,6)='parse.' THEN 1 ELSE 0 END) AS parse_failures,
            MIN(CASE WHEN l.status='pending' THEN CAST(strftime('%s',l.created_at) AS INTEGER) END) AS oldest_pending FROM capture_ingest_ledger l
            JOIN capture_ingest_publications p ON p.publication_sha256 = l.publication_sha256 COLLATE BINARY
            WHERE p.machine_id = ? AND p.source_instance_id = ? GROUP BY l.status
            """, arguments: args) {
            let status = try Self.string(row, "status")
            guard ["pending", "processing", "parsed", "index_ready", "failed_retryable", "quarantined"].contains(status) else {
                throw ServiceWebMetadataError.unavailable
            }
            counts[status] = try Self.integer(row, "value")
            failures += try Self.integer(row, "parse_failures")
            if status == "pending" {
                oldest = try Self.optionalInteger(row, "oldest_pending")
            }
        }
        guard (0...9_007_199_254_740_991).contains(failures) else { throw ServiceWebMetadataError.unavailable }
        let fts: EngramServiceWebFTSObservation?
        if try Self.schema(db).fts {
            fts = .init(observedAt: observedAt,
                readyLogicalSessions: try readyCount(db, binding: binding, parser: policy.parserRevision))
        } else { fts = nil }
        let overview = EngramServiceWebStreamOverview(machineId: machineID, sourceInstanceId: instanceID,
            registry: .init(source: binding.source.rawValue, approvedEpoch: binding.approvedEpoch,
                            authorityGeneration: String(binding.authorityGeneration)),
            ingest: .init(publicationCount: publications,
                taskCounts: .init(pending: counts["pending"] ?? 0, processing: counts["processing"] ?? 0,
                    parsed: counts["parsed"] ?? 0, indexReady: counts["index_ready"] ?? 0,
                    retryableFailure: counts["failed_retryable"] ?? 0, quarantined: counts["quarantined"] ?? 0),
                parseFailureTasks: failures, oldestPendingAt: oldest),
            heartbeatAt: nil, lastCapture: nil, replicaACKs: nil, fts: fts, ai: nil)
        return StreamRecord(overview: overview, authority: try Self.bindingKey(Self.bindingFields(binding)))
    }

    private func readyCount(_ db: Database, binding: CaptureIngestSourceBinding, parser: String) throws -> Int64 {
        // This is metadata corroboration, not transcript admission. In
        // particular it neither reads nor authenticates the three opaque BLOBs.
        // The planner otherwise prefers the primary key and reads overflow pages
        // for trailing authority columns, exceeding the overview deadline.
        // session_id is UNINDEXED in FTS5. Seek through the existing rowid
        // map, corroborating the actual FTS row. Missing/stale mappings retain
        // the full membership fallback, including legacy databases without it.
        let membership = "g.stored_session_id COLLATE BINARY IN (SELECT session_id COLLATE BINARY FROM sessions_fts)"
        let ftsMembership: String
        if try db.tableExists("fts_map") {
            // Fail-closed: only the owned internal-content FTS5 layout may seek
            // sessions_fts_content.c0. Any other sqlite_master.sql keeps the
            // virtual-table corroboration. tableExists/fts_version are not enough.
            if try Self.hasOwnedInternalFTSContent(db) {
                ftsMembership = """
                    (EXISTS (SELECT 1 FROM fts_map m JOIN sessions_fts_content f ON f.id = m.fts_rowid
                        WHERE m.session_id = g.stored_session_id COLLATE BINARY
                          AND f.c0 = g.stored_session_id COLLATE BINARY)
                     OR \(membership))
                    """
            } else {
                ftsMembership = """
                    (EXISTS (SELECT 1 FROM fts_map m JOIN sessions_fts f ON f.rowid = m.fts_rowid
                        WHERE m.session_id = g.stored_session_id COLLATE BINARY
                          AND f.session_id = g.stored_session_id COLLATE BINARY)
                     OR \(membership))
                    """
            }
        } else { ftsMembership = membership }
        // CROSS JOIN enforces identity-first join order.
        return try Self.count(db, sql: """
            SELECT COUNT(DISTINCT i.stored_session_id COLLATE BINARY) AS value
            FROM capture_ingest_identity_bindings i
            CROSS JOIN sessions s ON s.id = i.stored_session_id COLLATE BINARY
            \(Self.registryJoinSQL)
            JOIN capture_ingest_generations g INDEXED BY capture_ingest_generations_ready_metadata ON g.generation_id = i.last_parsed_generation_id COLLATE BINARY
              AND g.generation_id = i.last_ready_generation_id COLLATE BINARY
              AND g.stored_session_id = i.stored_session_id COLLATE BINARY
              AND g.machine_id = i.machine_id COLLATE BINARY AND g.source_instance_id = i.source_instance_id COLLATE BINARY
              AND g.source = i.source COLLATE BINARY AND g.native_id = i.native_id COLLATE BINARY
              AND g.parse_format = r.parse_format COLLATE BINARY AND g.configured_root = r.configured_root COLLATE BINARY
              AND g.collector_epoch = r.approved_epoch COLLATE BINARY AND g.authority_generation = r.authority_generation
              AND typeof(g.sync_version) = 'integer' AND g.sync_version > 0
              AND typeof(i.last_sync_version) = 'integer' AND i.last_sync_version = g.sync_version
              AND typeof(s.sync_version) = 'integer' AND s.sync_version = g.sync_version
              AND s.snapshot_hash = g.snapshot_hash COLLATE BINARY
            JOIN capture_ingest_publications p ON p.publication_sha256 = g.publication_sha256 COLLATE BINARY
              AND p.machine_id = g.machine_id COLLATE BINARY AND p.source_instance_id = g.source_instance_id COLLATE BINARY
              AND p.collector_epoch = g.collector_epoch COLLATE BINARY
              AND typeof(g.sequence) = 'integer' AND g.sequence > 0 AND p.sequence = g.sequence
            JOIN capture_ingest_ledger l ON l.publication_sha256 = g.publication_sha256 COLLATE BINARY
              AND l.parser_revision = g.parser_revision COLLATE BINARY AND l.status = 'index_ready'
              AND l.failure_code IS NULL AND l.claim_token IS NULL AND l.claim_started_at IS NULL
              AND l.claim_expires_at IS NULL AND l.retry_after IS NULL
            WHERE i.last_parsed_generation_id = i.last_ready_generation_id COLLATE BINARY
              AND \(Self.visibleSQL) AND \(SessionSemanticSearchPolicy.searchableTierSQL)
              AND i.machine_id = ? AND i.source_instance_id = ? AND i.source = ? AND g.parser_revision = ? COLLATE BINARY
              AND length(g.generation_id) = 64 AND g.generation_id NOT GLOB '*[^0-9a-f]*'
              AND length(g.publication_sha256) = 64 AND g.publication_sha256 NOT GLOB '*[^0-9a-f]*'
              AND length(g.snapshot_hash) = 64 AND g.snapshot_hash NOT GLOB '*[^0-9a-f]*'
              AND \(ftsMembership)
            """, arguments: [binding.machineID, binding.sourceInstanceID, binding.source.rawValue, parser])
    }

    private struct SessionFilter {
        let predicates: [String]
        let arguments: [DatabaseValueConvertible]
        let identityFirstSearch: Bool
    }

    private func sessionFilter(_ db: Database, request: EngramServiceWebSessionsRequest,
                               policy: ServiceWebMetadataPolicy, sessionIDs: [String]?) throws -> SessionFilter? {
        let schema = try Self.schema(db)
        guard schema.capture else { return nil }
        let sources = policy.enabledSources.map(\.rawValue).sorted()
        var predicates = [Self.sessionVisibilitySQL(request.agents),
                    "i.source IN (\(Array(repeating: "?", count: sources.count).joined(separator: ",")))"]
        var arguments: [DatabaseValueConvertible] = sources.map { $0 }
        if let sessionIDs {
            guard !sessionIDs.isEmpty else { return nil }
            predicates.append("s.id COLLATE BINARY IN (\(Array(repeating: "?", count: sessionIDs.count).joined(separator: ",")))")
            for id in sessionIDs { arguments.append(id) }
        }
        if let filter = request.resolvedSources {
            predicates.append("i.source COLLATE BINARY IN (\(Array(repeating: "?", count: filter.count).joined(separator: ",")))")
            arguments.append(contentsOf: filter)
        }
        if let filter = request.resolvedProjectKeys {
            let raws = try matchingProjects(db, keys: filter, policy: policy, agents: request.agents)
            guard !raws.isEmpty else { return nil }
            predicates.append("s.project COLLATE BINARY IN (\(Array(repeating: "?", count: raws.count).joined(separator: ",")))")
            arguments.append(contentsOf: raws)
        }
        if let filter = request.sessionId {
            predicates.append("(s.id = ? COLLATE BINARY OR i.native_id = ? COLLATE BINARY)")
            arguments.append(filter)
            arguments.append(filter)
        }
        for (column, value) in [("i.machine_id", request.machineId), ("i.source_instance_id", request.sourceInstanceId)] {
            if let value { predicates.append("\(column) = ? COLLATE BINARY"); arguments.append(value) }
        }
        if let since = request.since {
            predicates.append("date(s.start_time, 'localtime') >= ?")
            arguments.append(since)
        }
        if let until = request.until {
            predicates.append("date(s.start_time, 'localtime') <= ?")
            arguments.append(until)
        }
        if request.tools == .hide {
            predicates.append(Self.toolOnlyHideSQL)
        }
        var identityFirstSearch = false
        if let query = request.query {
            guard schema.fts else { throw ServiceWebMetadataError.unavailable }
            let terms = CJKText.searchableTerms(query)
            guard !terms.isEmpty else { return nil }
            predicates.append(SessionSemanticSearchPolicy.searchableTierSQL)
            let matches = CJKText.ftsMatchTerms(terms)
            let owned = try Self.hasOwnedInternalFTSContent(db)
            let identityIndex: Bool
            if owned {
                identityIndex = try FTSRebuildPolicy.hasOwnedContentIdentityIndex(db)
            } else {
                identityIndex = false
            }
            for (index, term) in terms.enumerated() {
                if !CJKText.usesTrigramMatch(term) {
                    // No trigram below 3 scalars, so the term costs one LIKE
                    // content scan. A non-correlated IN materializes that scan
                    // once per term; the earlier correlated EXISTS re-scanned
                    // the whole content table for every outer row (44k sessions
                    // on HQ). Terms of >= 3 scalars, CJK included, take the
                    // MATCH branch: trigram MATCH is a substring match.
                    predicates.append("""
                        s.id COLLATE BINARY IN (
                            SELECT session_id COLLATE BINARY FROM sessions_fts
                            WHERE content LIKE ? ESCAPE '\\')
                        """)
                    arguments.append("%\(CJKText.escapeLikePattern(term))%")
                } else if owned {
                    // MATCH once; project UNINDEXED session_id from the owned
                    // shadow PK. Do not route through fts_map: a mapped row can
                    // miss the term while another same-id row hits.
                    // Initial search (no page IDs) seeks i.stored_session_id so
                    // the planner starts from the hit set. Live ID batch keeps
                    // s.id so 50 page IDs stay the driver, not the full hit set.
                    // INDEXED BY only after this snapshot's owned FTS/content/
                    // index DDL all match; otherwise the unhinted JOIN.
                    let member = sessionIDs == nil ? "i.stored_session_id" : "s.id"
                    if sessionIDs == nil { identityFirstSearch = true }
                    let contentJoin = identityIndex
                        ? "JOIN sessions_fts_content f INDEXED BY \(FTSRebuildPolicy.contentIdentityIndexName) ON f.id = sessions_fts.rowid"
                        : "JOIN sessions_fts_content f ON f.id = sessions_fts.rowid"
                    predicates.append("""
                        \(member) COLLATE BINARY IN (
                            SELECT f.c0 FROM sessions_fts
                            \(contentJoin)
                            WHERE sessions_fts MATCH ?)
                        """)
                    arguments.append(matches[index])
                } else {
                    predicates.append("EXISTS (SELECT 1 FROM sessions_fts WHERE session_id = s.id COLLATE BINARY AND sessions_fts MATCH ?)")
                    arguments.append(matches[index])
                }
            }
        }
        return SessionFilter(predicates: predicates, arguments: arguments, identityFirstSearch: identityFirstSearch)
    }

    private func sessionRows(_ db: Database, request: EngramServiceWebSessionsRequest,
                             policy: ServiceWebMetadataPolicy, after: PositionKey?, limit: Int,
                             sessionIDs: [String]?) throws -> [SessionRecord] {
        guard let filter = try sessionFilter(db, request: request, policy: policy, sessionIDs: sessionIDs) else {
            return []
        }
        let base = filter.predicates
        let arguments = filter.arguments
        let identityFirstSearch = filter.identityFirstSearch
        // Identity-first search seeks `s` by primary key from the hit set and
        // live id batches must seek it by `s.id IN (...)`; neither may be
        // pinned to the visible-sessions index.
        let sessionsJoin: String
        if identityFirstSearch {
            sessionsJoin = "CROSS JOIN sessions s ON s.id = i.stored_session_id COLLATE BINARY"
        } else if sessionIDs != nil {
            sessionsJoin = try Self.primaryKeyJoinSQL(db, on: "s.id = i.stored_session_id COLLATE BINARY")
        } else {
            sessionsJoin = Self.sessionsJoinSQL(agents: request.agents, on: "s.id = i.stored_session_id COLLATE BINARY")
        }
        var position = after
        var records: [SessionRecord] = []
        repeat {
            try relay.check()
            var predicates = base
            var args = arguments
            if let position {
                guard case .session(let time, let id) = position else { throw ServiceWebMetadataError.stale }
                if let time {
                    predicates.append("(\(Self.startSQL) IS NULL OR \(Self.startSQL) < ? OR (\(Self.startSQL) = ? AND s.id COLLATE BINARY > ?))")
                    args.append(time)
                    args.append(time)
                    args.append(id)
                } else {
                    predicates.append("(\(Self.startSQL) IS NULL AND s.id COLLATE BINARY > ?)")
                    args.append(id)
                }
            }
            args.append(limit)
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.id, s.source, s.authoritative_node, s.sync_version, s.snapshot_hash, s.tier,
                    s.agent_role, s.parent_session_id, s.suggested_parent_id,
                    s.user_message_count, s.assistant_message_count, s.system_message_count, s.tool_message_count,
                    typeof(s.generated_title) AS generated_title_storage, CAST(s.generated_title AS BLOB) AS generated_title_bytes,
                    typeof(s.custom_name) AS custom_name_storage, CAST(s.custom_name AS BLOB) AS custom_name_bytes,
                    typeof(s.project) AS project_storage, CAST(s.project AS BLOB) AS project_bytes,
                    \(Self.startSQL) AS started_at,
                    i.machine_id, i.source_instance_id, i.native_id, i.last_sync_version,
                    i.last_parsed_generation_id, i.last_ready_generation_id
                FROM capture_ingest_identity_bindings i \(sessionsJoin)
                \(Self.registryJoinSQL)
                WHERE \(predicates.joined(separator: " AND "))
                ORDER BY started_at IS NULL, started_at DESC, s.id COLLATE BINARY LIMIT ?
                """, arguments: StatementArguments(args))
            for row in rows {
                try relay.check()
                let id = try Self.string(row, "id")
                let start = try Self.optionalInteger(row, "started_at")
                position = .session(start, id)
                let machine = try Self.string(row, "machine_id")
                let instance = try Self.string(row, "source_instance_id")
                guard let binding = try binding(db, machineID: machine, instanceID: instance, policy: policy) else { continue }
                let parsed = try Self.optionalString(row, "last_parsed_generation_id")
                let ready = try Self.optionalString(row, "last_ready_generation_id")
                let project = try Self.metadataText(row, "project")
                let generatedTitle = try Self.metadataText(row, "generated_title")
                let customName = try Self.metadataText(row, "custom_name")
                let title = customName ?? generatedTitle
                let parent = try Self.optionalString(row, "parent_session_id")
                let suggested = try Self.optionalString(row, "suggested_parent_id")
                let role = try Self.optionalString(row, "agent_role")
                let native = try Self.optionalString(row, "native_id")
                let nativeId = native.flatMap { value -> String? in
                    guard !value.isEmpty, value.utf8.count <= EngramServiceWebReadLimits.maximumSessionIDBytes,
                          !value.utf8.contains(0) else { return nil }
                    return value
                }
                let isAgent = parent != nil || suggested != nil
                    || role == "subagent" || role == "dispatched"
                let summary = EngramServiceWebSessionSummary(sessionId: id, source: try Self.string(row, "source"),
                    captureIdentity: .init(machineId: machine, sourceInstanceId: instance), metadataGeneration: parsed,
                    title: Self.safeText(title, maximumBytes: 1024), projectKey: Self.publishedProjectKey(project),
                    projectLabel: {
                        guard let project, !project.isEmpty else { return nil }
                        return Self.facetProjectLabel(project)
                    }(), startedAt: start,
                    isAgent: isAgent, userMessageCount: try Self.scalarCount(row, "user_message_count"),
                    assistantMessageCount: try Self.scalarCount(row, "assistant_message_count"),
                    systemMessageCount: try Self.scalarCount(row, "system_message_count"), nativeId: nativeId)
                var fields = Self.bindingFields(binding)
                for name in ["id", "source", "authoritative_node", "snapshot_hash", "tier", "native_id"] {
                    fields.append(try Self.optionalString(row, name))
                }
                fields.append(contentsOf: [generatedTitle, customName, project, parsed, ready, parent, suggested, role])
                fields.append(String(try Self.integer(row, "sync_version")))
                fields.append(String(try Self.integer(row, "last_sync_version")))
                fields.append(start.map { String($0) })
                fields.append(contentsOf: ["user_message_count", "assistant_message_count", "system_message_count",
                                           "tool_message_count"].map {
                    String((try? Self.integer(row, $0)) ?? -1)
                })
                records.append(SessionRecord(summary: summary, authority: try Self.bindingKey(fields), parsedID: parsed, readyID: ready))
                if records.count == limit { return records }
            }
            if rows.count < limit { return records }
        } while true
    }

    private func childRows(_ db: Database, parentID: String, policy: ServiceWebMetadataPolicy,
                           after: PositionKey?, limit: Int, sessionIDs: [String]?) throws -> [ChildRecord] {
        let schema = try Self.schema(db)
        guard schema.capture else { return [] }
        let sources = policy.enabledSources.map(\.rawValue).sorted()
        var predicates = [Self.childVisibilitySQL,
                          "i.source IN (\(Array(repeating: "?", count: sources.count).joined(separator: ",")))",
                          Self.childParentPredicateSQL]
        var arguments: [DatabaseValueConvertible] = sources.map { $0 }
        arguments.append(parentID)
        arguments.append(parentID)
        if let sessionIDs {
            guard !sessionIDs.isEmpty else { return [] }
            predicates.append("s.id COLLATE BINARY IN (\(Array(repeating: "?", count: sessionIDs.count).joined(separator: ",")))")
            for id in sessionIDs { arguments.append(id) }
        }
        var position = after
        var records: [ChildRecord] = []
        repeat {
            try relay.check()
            var pagePredicates = predicates
            var args = arguments
            if let position {
                guard case .session(let time, let id) = position else { throw ServiceWebMetadataError.stale }
                if let time {
                    pagePredicates.append("(\(Self.startSQL) IS NULL OR \(Self.startSQL) < ? OR (\(Self.startSQL) = ? AND s.id COLLATE BINARY > ?))")
                    args.append(time)
                    args.append(time)
                    args.append(id)
                } else {
                    pagePredicates.append("(\(Self.startSQL) IS NULL AND s.id COLLATE BINARY > ?)")
                    args.append(id)
                }
            }
            args.append(limit)
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.id, s.source, s.authoritative_node, s.sync_version, s.snapshot_hash, s.tier,
                    s.agent_role, s.parent_session_id, s.suggested_parent_id,
                    s.user_message_count, s.assistant_message_count, s.system_message_count, s.tool_message_count,
                    typeof(s.generated_title) AS generated_title_storage, CAST(s.generated_title AS BLOB) AS generated_title_bytes,
                    typeof(s.custom_name) AS custom_name_storage, CAST(s.custom_name AS BLOB) AS custom_name_bytes,
                    typeof(s.project) AS project_storage, CAST(s.project AS BLOB) AS project_bytes,
                    \(Self.startSQL) AS started_at,
                    i.machine_id, i.source_instance_id, i.native_id, i.last_sync_version,
                    i.last_parsed_generation_id, i.last_ready_generation_id
                FROM capture_ingest_identity_bindings i
                JOIN sessions s ON s.id = i.stored_session_id COLLATE BINARY
                \(Self.registryJoinSQL)
                WHERE \(pagePredicates.joined(separator: " AND "))
                ORDER BY started_at IS NULL, started_at DESC, s.id COLLATE BINARY LIMIT ?
                """, arguments: StatementArguments(args))
            for row in rows {
                try relay.check()
                let id = try Self.string(row, "id")
                let start = try Self.optionalInteger(row, "started_at")
                position = .session(start, id)
                let machine = try Self.string(row, "machine_id")
                let instance = try Self.string(row, "source_instance_id")
                guard let binding = try binding(db, machineID: machine, instanceID: instance, policy: policy) else {
                    continue
                }
                let parent = try Self.optionalString(row, "parent_session_id")
                let relationship: EngramServiceWebChildRelationship =
                    parent.map { $0.utf8.elementsEqual(parentID.utf8) } == true ? .confirmed : .suggested
                let summary = try sessionSummary(from: row)
                var fields = Self.bindingFields(binding)
                fields.append(contentsOf: [id, relationship.rawValue, parent,
                                           try Self.optionalString(row, "suggested_parent_id")])
                fields.append(start.map { String($0) })
                records.append(ChildRecord(
                    item: EngramServiceWebChildItem(relationship: relationship, session: summary),
                    authority: try Self.bindingKey(fields)))
                if records.count == limit { return records }
            }
            if rows.count < limit { return records }
        } while true
    }

    private func matchingProjects(_ db: Database, keys: [String], policy: ServiceWebMetadataPolicy,
                                  agents: EngramServiceWebAgentFilter) throws -> [String] {
        let wanted = Set(keys.map { Data($0.utf8) })
        // Published identities only. A raw fallback would also select a project
        // literally named `p.<digest>` when the caller asked for that opaque key.
        return try authorizedProjects(db, policy: policy, agents: agents).compactMap { project in
            wanted.contains(Data(project.published.utf8)) ? project.raw : nil
        }
    }

    private func sessionCount(_ db: Database, request: EngramServiceWebSessionsRequest,
                              policy: ServiceWebMetadataPolicy) throws -> SessionsTotal {
        guard let filter = try sessionFilter(db, request: request, policy: policy, sessionIDs: nil) else {
            return SessionsTotal(count: 0, streams: [])
        }
        let rows = try Row.fetchAll(db, sql: """
            SELECT i.machine_id, i.source_instance_id, COUNT(*) AS value
            FROM capture_ingest_identity_bindings i
            \(Self.sessionsJoinSQL(agents: request.agents, on: "s.id = i.stored_session_id COLLATE BINARY"))
            \(Self.registryJoinSQL)
            WHERE \(filter.predicates.joined(separator: " AND "))
            GROUP BY i.machine_id, i.source_instance_id
            """, arguments: StatementArguments(filter.arguments))
        var total: Int64 = 0
        var streams: [CountedStream] = []
        for row in rows {
            try relay.check()
            let machineID = try Self.string(row, "machine_id")
            let instanceID = try Self.string(row, "source_instance_id")
            guard let admitted = try binding(db, machineID: machineID, instanceID: instanceID, policy: policy) else {
                continue
            }
            total = try Self.addCount(total, try Self.integer(row, "value"))
            streams.append(CountedStream(machineID: machineID, instanceID: instanceID,
                                         authority: try Self.bindingKey(Self.bindingFields(admitted))))
        }
        return SessionsTotal(count: total, streams: streams)
    }

    private func sessionsFilter(from request: EngramServiceWebSearchRequest) throws -> EngramServiceWebSessionsRequest {
        try EngramServiceWebSessionsRequest(
            source: request.source, sources: request.sources,
            machineId: request.machineId, sourceInstanceId: request.sourceInstanceId,
            projectKey: request.projectKey, projectKeys: request.projectKeys,
            sessionId: request.sessionId, agents: request.agents,
            since: request.since, until: request.until, tools: request.tools, limit: 1
        )
    }

    private func sessionsFilter(from request: EngramServiceWebSearchStatusRequest) throws -> EngramServiceWebSessionsRequest {
        try EngramServiceWebSessionsRequest(
            source: request.source, sources: request.sources,
            machineId: request.machineId, sourceInstanceId: request.sourceInstanceId,
            projectKey: request.projectKey, projectKeys: request.projectKeys,
            sessionId: request.sessionId, agents: request.agents,
            since: request.since, until: request.until, tools: request.tools, limit: 1
        )
    }

    private func sessionsFilter(from request: EngramServiceWebCostsRequest) throws -> EngramServiceWebSessionsRequest {
        try EngramServiceWebSessionsRequest(
            source: request.source, sources: request.sources,
            machineId: request.machineId, sourceInstanceId: request.sourceInstanceId,
            projectKey: request.projectKey, projectKeys: request.projectKeys,
            sessionId: request.sessionId, agents: request.agents,
            since: request.since, until: request.until, tools: request.tools, limit: 1
        )
    }

    private func sessionsFilter(from request: EngramServiceWebCostSessionsRequest) throws -> EngramServiceWebSessionsRequest {
        try EngramServiceWebSessionsRequest(
            source: request.source, sources: request.sources,
            machineId: request.machineId, sourceInstanceId: request.sourceInstanceId,
            projectKey: request.projectKey, projectKeys: request.projectKeys,
            sessionId: request.sessionId, agents: request.agents,
            since: request.since, until: request.until, tools: request.tools, limit: 1
        )
    }

    private func makeSearchScope(_ db: Database, request: EngramServiceWebSessionsRequest,
                                 policy: ServiceWebMetadataPolicy) throws -> EngramServiceSearchScope {
        guard let filter = try sessionFilter(db, request: request, policy: policy, sessionIDs: nil) else {
            return .none
        }
        var predicates = filter.predicates
        predicates.append(SessionSemanticSearchPolicy.searchableTierSQL)
        let exists = """
            EXISTS (
                SELECT 1 FROM capture_ingest_identity_bindings i
                \(Self.registryJoinSQL)
                WHERE i.stored_session_id = s.id COLLATE BINARY
                  AND \(predicates.joined(separator: " AND "))
            )
            """
        return .predicates([exists], arguments: filter.arguments)
    }

    private func searchStatusSnapshot(_ db: Database, request: EngramServiceWebSessionsRequest,
                                      policy: ServiceWebMetadataPolicy) throws -> EngramServiceWebSearchStatusResponse {
        let schema = try Self.schema(db)
        let keyword: EngramServiceWebAvailability = schema.capture && schema.fts ? .available : .unavailable
        let eligible = schema.capture
            ? try authorizedDistinctCount(db, request: request, policy: policy)
            : nil
        let probe = schema.capture ? try SessionVectorSearchAvailability.probe(db: db) : .unavailable
        let storedModel = probe.model
        let storedDimension = probe.dimension
        let embedded: Int64?
        if schema.capture, let model = storedModel, let dimension = storedDimension, dimension > 0 {
            embedded = try authorizedDistinctCount(
                db, request: request, policy: policy,
                extraJoin: """
                    JOIN semantic_chunks sc ON sc.session_id = s.id COLLATE BINARY
                      AND sc.embedding IS NOT NULL AND sc.model = ? AND sc.dim = ?
                    """,
                extraArguments: [model, dimension]
            )
        } else {
            embedded = nil
        }
        let insightCorpus = try hasAdmittedInsightVectorCorpus(
            db, model: storedModel, dimension: storedDimension, policy: policy)
        let effectiveProbe: SessionVectorSearchAvailability.Snapshot
        if (probe.isUsable || insightCorpus), let model = storedModel, let dimension = storedDimension {
            effectiveProbe = .init(isUsable: true, model: model, dimension: dimension)
        } else {
            effectiveProbe = probe
        }
        let config = EmbeddingSettings.load(environment: embeddingEnvironment)
        let degrade: SessionVectorSearchAvailability.SemanticDegradeReason?
        let semantic: EngramServiceWebAvailability
        if keyword != .available {
            semantic = .unavailable
            degrade = nil
        } else if let config {
            if let model = storedModel, let dimension = storedDimension {
                switch SessionVectorSearchAvailability.queryCompatibility(
                    configuredModel: config.model,
                    configuredDimension: config.dimension,
                    dimensionsWereSent: EmbeddingRequestPolicy.dimensionsWereSentForCompatibility(
                        config, storedDimension: dimension
                    ),
                    snapshot: effectiveProbe
                ) {
                case .compatible:
                    if (embedded ?? 0) > 0 || insightCorpus {
                        semantic = .available
                        degrade = nil
                    } else {
                        semantic = .unavailable
                        degrade = .corpusMissing
                    }
                case .corpusUnavailable:
                    semantic = .unavailable
                    degrade = .corpusMissing
                case .modelMismatch:
                    semantic = .unavailable
                    degrade = .modelMismatch
                }
            } else {
                semantic = .unavailable
                degrade = .corpusMissing
            }
        } else {
            semantic = .unavailable
            degrade = .providerUnavailable
        }
        let hybrid: EngramServiceWebAvailability = keyword == .available && semantic == .available
            ? .available : .unavailable
        let progress: Int?
        if let eligible, let embedded {
            progress = eligible == 0 ? 0 : min(100, Int((Double(embedded) / Double(eligible) * 100).rounded()))
        } else {
            progress = nil
        }
        return EngramServiceWebSearchStatusResponse(
            observedAt: Self.observedAt(),
            keyword: keyword,
            semantic: semantic,
            hybrid: hybrid,
            warning: degrade?.serviceWarning,
            warningCode: degrade?.structuredCode,
            model: storedModel,
            dimension: storedDimension,
            eligibleSessionCount: eligible,
            embeddedSessionCount: embedded,
            progressPercent: progress
        )
    }

    private func hasAdmittedInsightVectorCorpus(
        _ db: Database,
        model: String?,
        dimension: Int?,
        policy: ServiceWebMetadataPolicy
    ) throws -> Bool {
        guard let model, let dimension, dimension > 0,
              try db.tableExists("insight_embeddings"),
              try db.tableExists("insights") else { return false }
        let admitted = try admittedAuditSessionIDs(db, policy: policy)
        let linkedIDs = (admitted ?? []).compactMap { String(data: $0.bytes, encoding: .utf8) }
        var sql = """
            SELECT 1
            FROM insight_embeddings e
            JOIN insights i ON i.id = e.insight_id
            WHERE e.embedding IS NOT NULL
              AND e.model = ?
              AND e.dim = ?
              AND i.superseded_by IS NULL
            """
        var arguments: [DatabaseValueConvertible] = [model, dimension]
        if linkedIDs.isEmpty {
            sql += " AND i.source_session_id IS NULL"
        } else {
            sql += """
                 AND (
                    i.source_session_id IS NULL
                    OR i.source_session_id COLLATE BINARY IN (\(Array(repeating: "?", count: linkedIDs.count).joined(separator: ",")))
                )
                """
            arguments.append(contentsOf: linkedIDs)
        }
        sql += " LIMIT 1"
        return try Int.fetchOne(db, sql: sql, arguments: StatementArguments(arguments)) != nil
    }

    private func authorizedDistinctCount(
        _ db: Database,
        request: EngramServiceWebSessionsRequest,
        policy: ServiceWebMetadataPolicy,
        extraJoin: String = "",
        extraArguments: [DatabaseValueConvertible] = []
    ) throws -> Int64 {
        guard var filter = try sessionFilter(db, request: request, policy: policy, sessionIDs: nil) else {
            return 0
        }
        filter = SessionFilter(
            predicates: filter.predicates + [SessionSemanticSearchPolicy.searchableTierSQL],
            arguments: filter.arguments,
            identityFirstSearch: filter.identityFirstSearch
        )
        var args = extraArguments + filter.arguments
        let rows = try Row.fetchAll(db, sql: """
            SELECT i.machine_id, i.source_instance_id, COUNT(DISTINCT s.id) AS value
            FROM capture_ingest_identity_bindings i
            JOIN sessions s ON s.id = i.stored_session_id COLLATE BINARY
            \(Self.registryJoinSQL)
            \(extraJoin)
            WHERE \(filter.predicates.joined(separator: " AND "))
            GROUP BY i.machine_id, i.source_instance_id
            """, arguments: StatementArguments(args))
        var total: Int64 = 0
        for row in rows {
            try relay.check()
            guard try binding(db, machineID: try Self.string(row, "machine_id"),
                              instanceID: try Self.string(row, "source_instance_id"),
                              policy: policy) != nil else { continue }
            total = try Self.addCount(total, try Self.integer(row, "value"))
        }
        return total
    }

    private func facetRows(_ db: Database, request: EngramServiceWebFacetsRequest,
                           policy: ServiceWebMetadataPolicy, after: PositionKey?, limit: Int,
                           keys: [String]? = nil) throws -> [FacetRecord] {
        switch request.kind {
        case .source:
            return try sourceFacets(db, request: request, policy: policy, after: after, limit: limit, keys: keys)
        case .project:
            return try projectFacets(db, request: request, policy: policy, after: after, limit: limit, keys: keys)
        }
    }

    private func sourceFacets(_ db: Database, request: EngramServiceWebFacetsRequest,
                              policy: ServiceWebMetadataPolicy, after: PositionKey?, limit: Int,
                              keys: [String]?) throws -> [FacetRecord] {
        let schema = try Self.schema(db)
        guard schema.capture else { return [] }
        let wanted = keys.map { Set($0.map { Data($0.utf8) }) }
        let (predicates, arguments) = try authorizedFacetBase(policy: policy, agents: request.agents)
        let rows = try Row.fetchAll(db, sql: """
            SELECT i.source AS facet_key, i.machine_id, i.source_instance_id, COUNT(*) AS value
            FROM capture_ingest_identity_bindings i
            JOIN sessions s ON s.id = i.stored_session_id COLLATE BINARY
            \(Self.registryJoinSQL)
            WHERE \(predicates.joined(separator: " AND "))
            GROUP BY i.source, i.machine_id, i.source_instance_id
            ORDER BY i.source COLLATE BINARY, i.machine_id COLLATE BINARY, i.source_instance_id COLLATE BINARY
            """, arguments: StatementArguments(arguments))
        var totals: [Data: (source: String, count: Int64, fields: [String?])] = [:]
        for row in rows {
            try relay.check()
            let source = try Self.string(row, "facet_key")
            if let wanted, !wanted.contains(Data(source.utf8)) { continue }
            guard let binding = try binding(db, machineID: try Self.string(row, "machine_id"),
                                           instanceID: try Self.string(row, "source_instance_id"),
                                           policy: policy) else { continue }
            let count = try Self.addCount(totals[Data(source.utf8)]?.count ?? 0, try Self.integer(row, "value"))
            var fields = totals[Data(source.utf8)]?.fields ?? []
            fields.append(contentsOf: Self.bindingFields(binding))
            totals[Data(source.utf8)] = (source, count, fields)
        }
        var records: [FacetRecord] = []
        for entry in totals.values {
            if let query = request.query,
               !EngramServiceWebMetadataValidation.queryMatches(entry.source, query: query) { continue }
            records.append(FacetRecord(
                item: EngramServiceWebFacetItem(key: entry.source, label: entry.source, sessionCount: entry.count),
                authority: try Self.bindingKey(["source", entry.source, String(entry.count)] + entry.fields)))
        }
        return try Self.pageFacets(records, after: after, limit: limit)
    }

    private func projectFacets(_ db: Database, request: EngramServiceWebFacetsRequest,
                               policy: ServiceWebMetadataPolicy, after: PositionKey?, limit: Int,
                               keys: [String]?) throws -> [FacetRecord] {
        let wanted = keys.map { Set($0.map { Data($0.utf8) }) }
        var items: [FacetRecord] = []
        for project in try authorizedProjects(db, policy: policy, agents: request.agents) {
            try relay.check()
            if let wanted, !wanted.contains(Data(project.published.utf8)) { continue }
            let label = Self.facetProjectLabel(project.raw)
            if let query = request.query,
               !EngramServiceWebMetadataValidation.queryMatches(label, query: query),
               !EngramServiceWebMetadataValidation.queryMatches(project.published, query: query) { continue }
            items.append(FacetRecord(
                item: EngramServiceWebFacetItem(key: project.published, label: label, sessionCount: project.count),
                authority: project.authority))
        }
        return try Self.pageFacets(items, after: after, limit: limit)
    }

    private static func pageFacets(_ items: [FacetRecord], after: PositionKey?, limit: Int) throws -> [FacetRecord] {
        var items = items.sorted { $0.item.key.utf8.lexicographicallyPrecedes($1.item.key.utf8) }
        if let after {
            guard case .facet(let last) = after else { throw ServiceWebMetadataError.stale }
            items.removeAll {
                $0.item.key.utf8.lexicographicallyPrecedes(last.utf8) || $0.item.key.utf8.elementsEqual(last.utf8)
            }
        }
        if items.count > limit { items = Array(items.prefix(limit)) }
        return items
    }

    private struct StatsRecord {
        let item: EngramServiceWebStatsItem
        let authority: Data
    }

    private struct StatsAggregate {
        let totals: EngramServiceWebStatsTotals
        let items: [StatsRecord]
    }

    private func statsAggregate(_ db: Database, request: EngramServiceWebStatsRequest,
                                policy: ServiceWebMetadataPolicy, after: PositionKey?, limit: Int,
                                keys: [String]? = nil) throws -> StatsAggregate {
        var records: [StatsRecord]
        switch request.groupBy {
        case .source:
            records = try sourceStats(db, request: request, policy: policy)
        case .project:
            records = try projectStats(db, request: request, policy: policy)
        case .day, .week:
            records = try dateStats(db, request: request, policy: policy)
        }
        let totals = try Self.sumStats(records.map(\.item))
        if let keys {
            let wanted = Set(keys.map { Data($0.utf8) })
            records = records.filter { wanted.contains(Data($0.item.key.utf8)) }
        }
        return StatsAggregate(totals: totals, items: try Self.pageStats(records, after: after, limit: limit))
    }

    private func sourceStats(_ db: Database, request: EngramServiceWebStatsRequest,
                             policy: ServiceWebMetadataPolicy) throws -> [StatsRecord] {
        let schema = try Self.schema(db)
        guard schema.capture else { return [] }
        let (predicates, arguments) = try authorizedStatsBase(request: request, policy: policy)
        let rows = try Row.fetchAll(db, sql: """
            SELECT i.source AS facet_key, i.machine_id, i.source_instance_id,
                COUNT(*) AS session_count,
                COALESCE(SUM(s.message_count), 0) AS message_count,
                COALESCE(SUM(s.user_message_count), 0) AS user_message_count,
                COALESCE(SUM(s.assistant_message_count), 0) AS assistant_message_count,
                COALESCE(SUM(s.tool_message_count), 0) AS tool_message_count
            FROM capture_ingest_identity_bindings i
            JOIN sessions s ON s.id = i.stored_session_id COLLATE BINARY
            \(Self.registryJoinSQL)
            WHERE \(predicates.joined(separator: " AND "))
            GROUP BY i.source, i.machine_id, i.source_instance_id
            ORDER BY i.source COLLATE BINARY, i.machine_id COLLATE BINARY, i.source_instance_id COLLATE BINARY
            """, arguments: StatementArguments(arguments))
        var totals: [Data: (source: String, counts: StatsCounts, fields: [String?])] = [:]
        for row in rows {
            try relay.check()
            let source = try Self.string(row, "facet_key")
            guard let binding = try binding(db, machineID: try Self.string(row, "machine_id"),
                                           instanceID: try Self.string(row, "source_instance_id"),
                                           policy: policy) else { continue }
            let added = try Self.rowCounts(row)
            let current = totals[Data(source.utf8)]
            var fields = current?.fields ?? []
            fields.append(contentsOf: Self.bindingFields(binding))
            totals[Data(source.utf8)] = (source, try Self.addCounts(current?.counts, added), fields)
        }
        return try totals.values.map { entry in
            StatsRecord(
                item: Self.statsItem(key: entry.source, label: entry.source, counts: entry.counts),
                authority: try Self.bindingKey(["source", entry.source] + Self.countFields(entry.counts) + entry.fields))
        }
    }

    private func projectStats(_ db: Database, request: EngramServiceWebStatsRequest,
                              policy: ServiceWebMetadataPolicy) throws -> [StatsRecord] {
        let schema = try Self.schema(db)
        guard schema.capture else { return [] }
        let (predicates, arguments) = try authorizedStatsBase(request: request, policy: policy)
        let rows = try Row.fetchAll(db, sql: """
            SELECT typeof(s.project) AS project_storage, CAST(s.project AS BLOB) AS project_bytes,
                i.machine_id, i.source_instance_id,
                COUNT(*) AS session_count,
                COALESCE(SUM(s.message_count), 0) AS message_count,
                COALESCE(SUM(s.user_message_count), 0) AS user_message_count,
                COALESCE(SUM(s.assistant_message_count), 0) AS assistant_message_count,
                COALESCE(SUM(s.tool_message_count), 0) AS tool_message_count
            FROM capture_ingest_identity_bindings i
            JOIN sessions s ON s.id = i.stored_session_id COLLATE BINARY
            \(Self.registryJoinSQL)
            WHERE \(predicates.joined(separator: " AND "))
            GROUP BY CAST(s.project AS BLOB), i.machine_id, i.source_instance_id
            ORDER BY CAST(s.project AS BLOB), i.machine_id COLLATE BINARY, i.source_instance_id COLLATE BINARY
            """, arguments: StatementArguments(arguments))
        var totals: [Data: (raw: String?, published: String, counts: StatsCounts, fields: [String?])] = [:]
        for row in rows {
            try relay.check()
            let raw = try Self.metadataText(row, "project")
            let published = Self.publishedProjectKey(raw) ?? EngramServiceWebMetadataValidation.unknownProjectKey
            guard let binding = try binding(db, machineID: try Self.string(row, "machine_id"),
                                           instanceID: try Self.string(row, "source_instance_id"),
                                           policy: policy) else { continue }
            let id = Data(published.utf8)
            if published != EngramServiceWebMetadataValidation.unknownProjectKey,
               let existing = totals[id], let existingRaw = existing.raw, let raw,
               !existingRaw.utf8.elementsEqual(raw.utf8) {
                throw ServiceWebMetadataError.unavailable
            }
            let added = try Self.rowCounts(row)
            let current = totals[id]
            var fields = current?.fields ?? []
            fields.append(contentsOf: Self.bindingFields(binding))
            totals[id] = (raw ?? current?.raw, published, try Self.addCounts(current?.counts, added), fields)
        }
        return try totals.values.map { entry in
            let label = entry.published == EngramServiceWebMetadataValidation.unknownProjectKey
                ? "Unknown" : Self.facetProjectLabel(entry.raw ?? "")
            return StatsRecord(
                item: Self.statsItem(key: entry.published, label: label, counts: entry.counts),
                authority: try Self.bindingKey(["project", entry.published] + Self.countFields(entry.counts) + entry.fields))
        }
    }

    private func dateStats(_ db: Database, request: EngramServiceWebStatsRequest,
                           policy: ServiceWebMetadataPolicy) throws -> [StatsRecord] {
        let schema = try Self.schema(db)
        guard schema.capture else { return [] }
        let (predicates, arguments) = try authorizedStatsBase(request: request, policy: policy)
        let expression = request.groupBy == .day
            ? "date(s.start_time, 'localtime')"
            : "date(s.start_time, 'localtime', 'weekday 0', '-6 days')"
        let rows = try Row.fetchAll(db, sql: """
            SELECT \(expression) AS facet_key, i.machine_id, i.source_instance_id,
                COUNT(*) AS session_count,
                COALESCE(SUM(s.message_count), 0) AS message_count,
                COALESCE(SUM(s.user_message_count), 0) AS user_message_count,
                COALESCE(SUM(s.assistant_message_count), 0) AS assistant_message_count,
                COALESCE(SUM(s.tool_message_count), 0) AS tool_message_count
            FROM capture_ingest_identity_bindings i
            JOIN sessions s ON s.id = i.stored_session_id COLLATE BINARY
            \(Self.registryJoinSQL)
            WHERE \(predicates.joined(separator: " AND "))
            GROUP BY \(expression), i.machine_id, i.source_instance_id
            ORDER BY \(expression), i.machine_id COLLATE BINARY, i.source_instance_id COLLATE BINARY
            """, arguments: StatementArguments(arguments))
        var totals: [Data: (key: String, counts: StatsCounts, fields: [String?])] = [:]
        for row in rows {
            try relay.check()
            let raw = try Self.optionalString(row, "facet_key")
            let key = raw ?? EngramServiceWebMetadataValidation.unknownDateKey
            guard let binding = try binding(db, machineID: try Self.string(row, "machine_id"),
                                           instanceID: try Self.string(row, "source_instance_id"),
                                           policy: policy) else { continue }
            let added = try Self.rowCounts(row)
            let current = totals[Data(key.utf8)]
            var fields = current?.fields ?? []
            fields.append(contentsOf: Self.bindingFields(binding))
            totals[Data(key.utf8)] = (key, try Self.addCounts(current?.counts, added), fields)
        }
        return try totals.values.map { entry in
            let label = entry.key == EngramServiceWebMetadataValidation.unknownDateKey ? "Unknown" : entry.key
            return StatsRecord(
                item: Self.statsItem(key: entry.key, label: label, counts: entry.counts),
                authority: try Self.bindingKey([request.groupBy.rawValue, entry.key]
                    + Self.countFields(entry.counts) + entry.fields))
        }
    }

    private struct CostRecord {
        let item: EngramServiceWebCostItem
        let authority: Data
    }

    private struct CostUnpriced: Equatable {
        let unattributedSessions: Int
        let noPriceSessions: Int
        let unattributedTokens: Int
        let noPriceTokens: Int

        static let zero = CostUnpriced(unattributedSessions: 0, noPriceSessions: 0,
                                       unattributedTokens: 0, noPriceTokens: 0)
    }

    private struct CostsAggregate {
        let totals: EngramServiceWebCostTotals
        let items: [CostRecord]
        let unpriced: CostUnpriced?
    }

    private struct CostCounts {
        var usd: Double
        var input: Int64
        var output: Int64
        var cacheRead: Int64
        var cacheCreation: Int64
        var session: Int64
    }

    private struct CostSessionRecord {
        let item: EngramServiceWebCostSessionItem
        let authority: Data
    }

    private static let zeroCostTotals = EngramServiceWebCostTotals(
        costUsd: 0, inputTokens: 0, outputTokens: 0, cacheReadTokens: 0,
        cacheCreationTokens: 0, sessionCount: 0)

    private static func costsResponse(
        lease: Lease, groupBy: EngramServiceWebCostsGroupBy, timeZone: String,
        prepared: CostsAggregate, count: Int, nextCursor: String?
    ) -> EngramServiceWebCostsResponse {
        EngramServiceWebCostsResponse(
            snapshotId: lease.id, observedAt: lease.observedAt, groupBy: groupBy, timeZone: timeZone,
            totals: prepared.totals, items: prepared.items.prefix(count).map(\.item),
            nextCursor: nextCursor,
            unpricedUnattributedSessions: prepared.unpriced?.unattributedSessions,
            unpricedNoPriceSessions: prepared.unpriced?.noPriceSessions,
            unpricedUnattributedTokens: prepared.unpriced?.unattributedTokens,
            unpricedNoPriceTokens: prepared.unpriced?.noPriceTokens)
    }

    private func costsAggregate(_ db: Database, request: EngramServiceWebCostsRequest,
                                policy: ServiceWebMetadataPolicy, after: PositionKey?, limit: Int,
                                keys: [String]? = nil) throws -> CostsAggregate {
        let schema = try Self.schema(db)
        guard schema.capture, try db.tableExists("session_costs") else {
            return CostsAggregate(totals: Self.zeroCostTotals, items: [], unpriced: nil)
        }
        let filterRequest = try sessionsFilter(from: request)
        guard let filter = try sessionFilter(db, request: filterRequest, policy: policy, sessionIDs: nil) else {
            return CostsAggregate(totals: Self.zeroCostTotals, items: [], unpriced: .zero)
        }
        var records: [CostRecord]
        switch request.groupBy {
        case .model:
            records = try modelCosts(db, filter: filter, policy: policy)
        case .source:
            records = try sourceCosts(db, filter: filter, policy: policy)
        case .project:
            records = try projectCosts(db, filter: filter, policy: policy)
        case .day:
            records = try dayCosts(db, filter: filter, policy: policy)
        }
        let totals = try Self.sumCosts(records.map(\.item))
        let unpriced = try costUnpriced(db, filter: filter, policy: policy)
        if let keys {
            let wanted = Set(keys.map { Data($0.utf8) })
            records = records.filter { wanted.contains(Data($0.item.key.utf8)) }
        }
        return CostsAggregate(totals: totals, items: try Self.pageCosts(records, after: after, limit: limit),
                              unpriced: unpriced)
    }

    private func modelCosts(_ db: Database, filter: SessionFilter,
                            policy: ServiceWebMetadataPolicy) throws -> [CostRecord] {
        try groupedCosts(db, filter: filter, policy: policy, groupBy: .model,
                         select: "c.model AS facet_key",
                         group: "c.model",
                         extra: "")
    }

    private func sourceCosts(_ db: Database, filter: SessionFilter,
                             policy: ServiceWebMetadataPolicy) throws -> [CostRecord] {
        try groupedCosts(db, filter: filter, policy: policy, groupBy: .source,
                         select: "i.source AS facet_key",
                         group: "i.source",
                         extra: "")
    }

    private func dayCosts(_ db: Database, filter: SessionFilter,
                          policy: ServiceWebMetadataPolicy) throws -> [CostRecord] {
        let expression = "date(s.start_time, 'localtime')"
        return try groupedCosts(db, filter: filter, policy: policy, groupBy: .day,
                                select: "\(expression) AS facet_key",
                                group: expression,
                                extra: "")
    }

    private func groupedCosts(_ db: Database, filter: SessionFilter, policy: ServiceWebMetadataPolicy,
                              groupBy: EngramServiceWebCostsGroupBy, select: String, group: String,
                              extra: String) throws -> [CostRecord] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT \(select), i.machine_id, i.source_instance_id,
                COALESCE(SUM(c.cost_usd), 0) AS cost_usd,
                COALESCE(SUM(c.input_tokens), 0) AS input_tokens,
                COALESCE(SUM(c.output_tokens), 0) AS output_tokens,
                COALESCE(SUM(c.cache_read_tokens), 0) AS cache_read_tokens,
                COALESCE(SUM(c.cache_creation_tokens), 0) AS cache_creation_tokens,
                COUNT(*) AS session_count
            FROM session_costs c
            JOIN sessions s ON s.id = c.session_id COLLATE BINARY
            JOIN capture_ingest_identity_bindings i ON s.id = i.stored_session_id COLLATE BINARY
            \(Self.registryJoinSQL)
            WHERE \(filter.predicates.joined(separator: " AND "))
            GROUP BY \(group), i.machine_id, i.source_instance_id
            ORDER BY i.machine_id COLLATE BINARY, i.source_instance_id COLLATE BINARY
            \(extra)
            """, arguments: StatementArguments(filter.arguments))
        var totals: [Data: (key: String, counts: CostCounts, fields: [String?])] = [:]
        for row in rows {
            try relay.check()
            let raw = try Self.optionalString(row, "facet_key")
            let key: String
            switch groupBy {
            case .model:
                key = (raw?.isEmpty == false) ? raw! : EngramServiceWebMetadataValidation.unknownModelKey
            case .day:
                key = raw ?? EngramServiceWebMetadataValidation.unknownDateKey
            case .source:
                key = try Self.string(row, "facet_key")
            case .project:
                key = raw ?? EngramServiceWebMetadataValidation.unknownProjectKey
            }
            guard let binding = try binding(db, machineID: try Self.string(row, "machine_id"),
                                           instanceID: try Self.string(row, "source_instance_id"),
                                           policy: policy) else { continue }
            let added = try Self.rowCostCounts(row)
            let current = totals[Data(key.utf8)]
            var fields = current?.fields ?? []
            fields.append(contentsOf: Self.bindingFields(binding))
            totals[Data(key.utf8)] = (key, try Self.addCostCounts(current?.counts, added), fields)
        }
        return try totals.values.map { entry in
            let label: String
            switch groupBy {
            case .model:
                label = entry.key == EngramServiceWebMetadataValidation.unknownModelKey ? "Unknown" : entry.key
            case .day:
                label = entry.key == EngramServiceWebMetadataValidation.unknownDateKey ? "Unknown" : entry.key
            case .source:
                label = entry.key
            case .project:
                label = entry.key == EngramServiceWebMetadataValidation.unknownProjectKey ? "Unknown" : entry.key
            }
            return CostRecord(
                item: Self.costItem(key: entry.key, label: label, counts: entry.counts),
                authority: try Self.bindingKey([groupBy.rawValue, entry.key]
                    + Self.costFields(entry.counts) + entry.fields))
        }
    }

    private func projectCosts(_ db: Database, filter: SessionFilter,
                              policy: ServiceWebMetadataPolicy) throws -> [CostRecord] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT typeof(s.project) AS project_storage, CAST(s.project AS BLOB) AS project_bytes,
                i.machine_id, i.source_instance_id,
                COALESCE(SUM(c.cost_usd), 0) AS cost_usd,
                COALESCE(SUM(c.input_tokens), 0) AS input_tokens,
                COALESCE(SUM(c.output_tokens), 0) AS output_tokens,
                COALESCE(SUM(c.cache_read_tokens), 0) AS cache_read_tokens,
                COALESCE(SUM(c.cache_creation_tokens), 0) AS cache_creation_tokens,
                COUNT(*) AS session_count
            FROM session_costs c
            JOIN sessions s ON s.id = c.session_id COLLATE BINARY
            JOIN capture_ingest_identity_bindings i ON s.id = i.stored_session_id COLLATE BINARY
            \(Self.registryJoinSQL)
            WHERE \(filter.predicates.joined(separator: " AND "))
            GROUP BY CAST(s.project AS BLOB), i.machine_id, i.source_instance_id
            ORDER BY i.machine_id COLLATE BINARY, i.source_instance_id COLLATE BINARY
            """, arguments: StatementArguments(filter.arguments))
        var totals: [Data: (raw: String?, published: String, counts: CostCounts, fields: [String?])] = [:]
        for row in rows {
            try relay.check()
            let raw = try Self.metadataText(row, "project")
            let published = Self.publishedProjectKey(raw) ?? EngramServiceWebMetadataValidation.unknownProjectKey
            guard let binding = try binding(db, machineID: try Self.string(row, "machine_id"),
                                           instanceID: try Self.string(row, "source_instance_id"),
                                           policy: policy) else { continue }
            let id = Data(published.utf8)
            if published != EngramServiceWebMetadataValidation.unknownProjectKey,
               let existing = totals[id], let existingRaw = existing.raw, let raw,
               !existingRaw.utf8.elementsEqual(raw.utf8) {
                throw ServiceWebMetadataError.unavailable
            }
            let added = try Self.rowCostCounts(row)
            let current = totals[id]
            var fields = current?.fields ?? []
            fields.append(contentsOf: Self.bindingFields(binding))
            totals[id] = (raw ?? current?.raw, published, try Self.addCostCounts(current?.counts, added), fields)
        }
        return try totals.values.map { entry in
            let label = entry.published == EngramServiceWebMetadataValidation.unknownProjectKey
                ? "Unknown" : Self.facetProjectLabel(entry.raw ?? "")
            return CostRecord(
                item: Self.costItem(key: entry.published, label: label, counts: entry.counts),
                authority: try Self.bindingKey(["project", entry.published]
                    + Self.costFields(entry.counts) + entry.fields))
        }
    }

    private func costUnpriced(_ db: Database, filter: SessionFilter,
                              policy: ServiceWebMetadataPolicy) throws -> CostUnpriced {
        let rows = try Row.fetchAll(db, sql: """
            SELECT i.machine_id, i.source_instance_id,
                SUM(CASE WHEN COALESCE(c.cost_usd,0)=0
                         AND (c.input_tokens+c.output_tokens+c.cache_read_tokens+c.cache_creation_tokens) > 0
                         AND (c.model IS NULL OR c.model = '')
                    THEN 1 ELSE 0 END) AS unpriced_unattributed_sessions,
                SUM(CASE WHEN COALESCE(c.cost_usd,0)=0
                         AND (c.input_tokens+c.output_tokens+c.cache_read_tokens+c.cache_creation_tokens) > 0
                         AND c.model IS NOT NULL AND c.model <> ''
                    THEN 1 ELSE 0 END) AS unpriced_no_price_sessions,
                SUM(CASE WHEN COALESCE(c.cost_usd,0)=0
                         AND (c.input_tokens+c.output_tokens+c.cache_read_tokens+c.cache_creation_tokens) > 0
                         AND (c.model IS NULL OR c.model = '')
                    THEN (c.input_tokens+c.output_tokens+c.cache_read_tokens+c.cache_creation_tokens)
                    ELSE 0 END) AS unpriced_unattributed_tokens,
                SUM(CASE WHEN COALESCE(c.cost_usd,0)=0
                         AND (c.input_tokens+c.output_tokens+c.cache_read_tokens+c.cache_creation_tokens) > 0
                         AND c.model IS NOT NULL AND c.model <> ''
                    THEN (c.input_tokens+c.output_tokens+c.cache_read_tokens+c.cache_creation_tokens)
                    ELSE 0 END) AS unpriced_no_price_tokens
            FROM session_costs c
            JOIN sessions s ON s.id = c.session_id COLLATE BINARY
            JOIN capture_ingest_identity_bindings i ON s.id = i.stored_session_id COLLATE BINARY
            \(Self.registryJoinSQL)
            WHERE \(filter.predicates.joined(separator: " AND "))
            GROUP BY i.machine_id, i.source_instance_id
            """, arguments: StatementArguments(filter.arguments))
        var unattributedSessions: Int64 = 0
        var noPriceSessions: Int64 = 0
        var unattributedTokens: Int64 = 0
        var noPriceTokens: Int64 = 0
        for row in rows {
            try relay.check()
            guard try binding(db, machineID: try Self.string(row, "machine_id"),
                              instanceID: try Self.string(row, "source_instance_id"),
                              policy: policy) != nil else { continue }
            unattributedSessions = try Self.addCount(unattributedSessions, try Self.integer(row, "unpriced_unattributed_sessions"))
            noPriceSessions = try Self.addCount(noPriceSessions, try Self.integer(row, "unpriced_no_price_sessions"))
            unattributedTokens = try Self.addCount(unattributedTokens, try Self.integer(row, "unpriced_unattributed_tokens"))
            noPriceTokens = try Self.addCount(noPriceTokens, try Self.integer(row, "unpriced_no_price_tokens"))
        }
        return CostUnpriced(unattributedSessions: Int(unattributedSessions), noPriceSessions: Int(noPriceSessions),
                            unattributedTokens: Int(unattributedTokens), noPriceTokens: Int(noPriceTokens))
    }

    private func costSessionRows(_ db: Database, request: EngramServiceWebSessionsRequest,
                                 policy: ServiceWebMetadataPolicy, limit: Int,
                                 sessionIDs: [String]? = nil) throws -> [CostSessionRecord] {
        guard try db.tableExists("session_costs") else { return [] }
        guard let filter = try sessionFilter(db, request: request, policy: policy, sessionIDs: sessionIDs) else {
            return []
        }
        var args = filter.arguments
        args.append(limit)
        let rows = try Row.fetchAll(db, sql: """
            SELECT s.id, s.source, s.authoritative_node, s.sync_version, s.snapshot_hash, s.tier,
                s.agent_role, s.parent_session_id, s.suggested_parent_id,
                s.user_message_count, s.assistant_message_count, s.system_message_count, s.tool_message_count,
                typeof(s.generated_title) AS generated_title_storage, CAST(s.generated_title AS BLOB) AS generated_title_bytes,
                typeof(s.custom_name) AS custom_name_storage, CAST(s.custom_name AS BLOB) AS custom_name_bytes,
                typeof(s.project) AS project_storage, CAST(s.project AS BLOB) AS project_bytes,
                \(Self.startSQL) AS started_at,
                i.machine_id, i.source_instance_id, i.native_id, i.last_sync_version,
                i.last_parsed_generation_id, i.last_ready_generation_id,
                c.cost_usd, c.model, c.input_tokens, c.output_tokens,
                c.cache_read_tokens, c.cache_creation_tokens
            FROM session_costs c
            JOIN sessions s ON s.id = c.session_id COLLATE BINARY
            JOIN capture_ingest_identity_bindings i ON s.id = i.stored_session_id COLLATE BINARY
            \(Self.registryJoinSQL)
            WHERE \(filter.predicates.joined(separator: " AND "))
            ORDER BY c.cost_usd DESC, s.id COLLATE BINARY LIMIT ?
            """, arguments: StatementArguments(args))
        var records: [CostSessionRecord] = []
        for row in rows {
            try relay.check()
            let machine = try Self.string(row, "machine_id")
            let instance = try Self.string(row, "source_instance_id")
            guard let binding = try binding(db, machineID: machine, instanceID: instance, policy: policy) else {
                continue
            }
            let summary = try sessionSummary(from: row)
            let model = try Self.optionalString(row, "model")
            let publishedModel = model.flatMap { $0.isEmpty ? nil : $0 }
            let item = EngramServiceWebCostSessionItem(
                session: summary,
                costUsd: try Self.money(try Self.double(row, "cost_usd")),
                model: publishedModel,
                inputTokens: try Self.integer(row, "input_tokens"),
                outputTokens: try Self.integer(row, "output_tokens"),
                cacheReadTokens: try Self.integer(row, "cache_read_tokens"),
                cacheCreationTokens: try Self.integer(row, "cache_creation_tokens"))
            var fields = Self.bindingFields(binding)
            fields.append(contentsOf: [summary.sessionId, publishedModel,
                                       String(item.inputTokens), String(item.outputTokens),
                                       String(item.cacheReadTokens), String(item.cacheCreationTokens),
                                       String(EngramServiceWebMetadataValidation.moneyCents(item.costUsd))])
            records.append(CostSessionRecord(item: item, authority: try Self.bindingKey(fields)))
        }
        return records
    }

    private func sessionSummary(from row: Row) throws -> EngramServiceWebSessionSummary {
        let id = try Self.string(row, "id")
        let start = try Self.optionalInteger(row, "started_at")
        let machine = try Self.string(row, "machine_id")
        let instance = try Self.string(row, "source_instance_id")
        let parsed = try Self.optionalString(row, "last_parsed_generation_id")
        let project = try Self.metadataText(row, "project")
        let generatedTitle = try Self.metadataText(row, "generated_title")
        let customName = try Self.metadataText(row, "custom_name")
        let title = customName ?? generatedTitle
        let parent = try Self.optionalString(row, "parent_session_id")
        let suggested = try Self.optionalString(row, "suggested_parent_id")
        let role = try Self.optionalString(row, "agent_role")
        let native = try Self.optionalString(row, "native_id")
        let nativeId = native.flatMap { value -> String? in
            guard !value.isEmpty, value.utf8.count <= EngramServiceWebReadLimits.maximumSessionIDBytes,
                  !value.utf8.contains(0) else { return nil }
            return value
        }
        let isAgent = parent != nil || suggested != nil
            || role == "subagent" || role == "dispatched"
        return EngramServiceWebSessionSummary(
            sessionId: id, source: try Self.string(row, "source"),
            captureIdentity: .init(machineId: machine, sourceInstanceId: instance), metadataGeneration: parsed,
            title: Self.safeText(title, maximumBytes: 1024), projectKey: Self.publishedProjectKey(project),
            projectLabel: {
                guard let project, !project.isEmpty else { return nil }
                return Self.facetProjectLabel(project)
            }(), startedAt: start,
            isAgent: isAgent, userMessageCount: try Self.scalarCount(row, "user_message_count"),
            assistantMessageCount: try Self.scalarCount(row, "assistant_message_count"),
            systemMessageCount: try Self.scalarCount(row, "system_message_count"), nativeId: nativeId)
    }

    private static func pageCosts(_ items: [CostRecord], after: PositionKey?, limit: Int) throws -> [CostRecord] {
        var items = items.sorted { lhs, rhs in
            if lhs.item.costUsd != rhs.item.costUsd { return lhs.item.costUsd > rhs.item.costUsd }
            return lhs.item.key.utf8.lexicographicallyPrecedes(rhs.item.key.utf8)
        }
        if let after {
            guard case .facet(let last) = after else { throw ServiceWebMetadataError.stale }
            guard let index = items.firstIndex(where: { $0.item.key.utf8.elementsEqual(last.utf8) }) else {
                throw ServiceWebMetadataError.stale
            }
            items = Array(items.dropFirst(index + 1))
        }
        if items.count > limit { items = Array(items.prefix(limit)) }
        return items
    }

    private static func rowCostCounts(_ row: Row) throws -> CostCounts {
        CostCounts(usd: try money(try double(row, "cost_usd")),
                   input: try integer(row, "input_tokens"), output: try integer(row, "output_tokens"),
                   cacheRead: try integer(row, "cache_read_tokens"),
                   cacheCreation: try integer(row, "cache_creation_tokens"),
                   session: try integer(row, "session_count"))
    }

    private static func addCostCounts(_ existing: CostCounts?, _ added: CostCounts) throws -> CostCounts {
        let base = existing ?? CostCounts(usd: 0, input: 0, output: 0, cacheRead: 0, cacheCreation: 0, session: 0)
        return CostCounts(usd: try addMoney(base.usd, added.usd),
                          input: try addCount(base.input, added.input),
                          output: try addCount(base.output, added.output),
                          cacheRead: try addCount(base.cacheRead, added.cacheRead),
                          cacheCreation: try addCount(base.cacheCreation, added.cacheCreation),
                          session: try addCount(base.session, added.session))
    }

    private static func sumCosts(_ items: [EngramServiceWebCostItem]) throws -> EngramServiceWebCostTotals {
        var totals = CostCounts(usd: 0, input: 0, output: 0, cacheRead: 0, cacheCreation: 0, session: 0)
        for item in items {
            totals = try addCostCounts(totals, CostCounts(
                usd: item.costUsd,
                input: item.inputTokens, output: item.outputTokens,
                cacheRead: item.cacheReadTokens, cacheCreation: item.cacheCreationTokens,
                session: item.sessionCount))
        }
        return EngramServiceWebCostTotals(costUsd: totals.usd, inputTokens: totals.input,
            outputTokens: totals.output, cacheReadTokens: totals.cacheRead,
            cacheCreationTokens: totals.cacheCreation, sessionCount: totals.session)
    }

    private static func costItem(key: String, label: String, counts: CostCounts) -> EngramServiceWebCostItem {
        EngramServiceWebCostItem(key: key, label: label, costUsd: counts.usd,
            inputTokens: counts.input, outputTokens: counts.output,
            cacheReadTokens: counts.cacheRead, cacheCreationTokens: counts.cacheCreation,
            sessionCount: counts.session)
    }

    private static func costFields(_ counts: CostCounts) -> [String?] {
        [String(counts.usd.bitPattern), String(counts.input), String(counts.output),
         String(counts.cacheRead), String(counts.cacheCreation), String(counts.session)]
    }

    private static func money(_ value: Double) throws -> Double {
        guard value.isFinite, value >= 0, value <= 1_000_000_000 else {
            throw ServiceWebMetadataError.unavailable
        }
        return value
    }

    private static func addMoney(_ existing: Double, _ added: Double) throws -> Double {
        try money(existing + added)
    }

    private static func pageStats(_ items: [StatsRecord], after: PositionKey?, limit: Int) throws -> [StatsRecord] {
        var items = items.sorted { $0.item.key.utf8.lexicographicallyPrecedes($1.item.key.utf8) }
        if let after {
            guard case .facet(let last) = after else { throw ServiceWebMetadataError.stale }
            items.removeAll {
                $0.item.key.utf8.lexicographicallyPrecedes(last.utf8) || $0.item.key.utf8.elementsEqual(last.utf8)
            }
        }
        if items.count > limit { items = Array(items.prefix(limit)) }
        return items
    }

    private struct StatsCounts {
        var session: Int64
        var message: Int64
        var user: Int64
        var assistant: Int64
        var tool: Int64
    }

    private static func rowCounts(_ row: Row) throws -> StatsCounts {
        StatsCounts(session: try integer(row, "session_count"), message: try integer(row, "message_count"),
                    user: try integer(row, "user_message_count"), assistant: try integer(row, "assistant_message_count"),
                    tool: try integer(row, "tool_message_count"))
    }

    private static func addCounts(_ existing: StatsCounts?, _ added: StatsCounts) throws -> StatsCounts {
        let base = existing ?? StatsCounts(session: 0, message: 0, user: 0, assistant: 0, tool: 0)
        return StatsCounts(session: try addCount(base.session, added.session),
                           message: try addCount(base.message, added.message),
                           user: try addCount(base.user, added.user),
                           assistant: try addCount(base.assistant, added.assistant),
                           tool: try addCount(base.tool, added.tool))
    }

    private static func sumStats(_ items: [EngramServiceWebStatsItem]) throws -> EngramServiceWebStatsTotals {
        var totals = StatsCounts(session: 0, message: 0, user: 0, assistant: 0, tool: 0)
        for item in items {
            totals = try addCounts(totals, StatsCounts(session: item.sessionCount, message: item.messageCount,
                user: item.userMessageCount, assistant: item.assistantMessageCount, tool: item.toolMessageCount))
        }
        return EngramServiceWebStatsTotals(sessionCount: totals.session, messageCount: totals.message,
            userMessageCount: totals.user, assistantMessageCount: totals.assistant, toolMessageCount: totals.tool)
    }

    private static func statsItem(key: String, label: String, counts: StatsCounts) -> EngramServiceWebStatsItem {
        EngramServiceWebStatsItem(key: key, label: label, sessionCount: counts.session, messageCount: counts.message,
            userMessageCount: counts.user, assistantMessageCount: counts.assistant, toolMessageCount: counts.tool)
    }

    private static func countFields(_ counts: StatsCounts) -> [String?] {
        [String(counts.session), String(counts.message), String(counts.user),
         String(counts.assistant), String(counts.tool)]
    }

    private struct AuthorizedProject {
        let raw: String
        let published: String
        let count: Int64
        let authority: Data
    }

    private struct SettingsAliasRecord {
        let item: EngramServiceWebSettingsAlias
        let cursorKey: String
        let authority: Data
        let rawAlias: String
        let rawCanonical: String
    }

    private struct SettingsPrepared {
        let sources: [EngramServiceWebSettingsSource]
        let totalSessions: Int64
        let aliases: [SettingsAliasRecord]
    }

    private static func settingsSources(_ policy: ServiceWebMetadataPolicy) -> [EngramServiceWebSettingsSource] {
        policy.enabledSources.map(\.rawValue).sorted().map { EngramServiceWebSettingsSource(key: $0, label: $0) }
    }

    private static func settingsResponse(
        lease: Lease, prepared: SettingsPrepared, aliasCount: Int, nextCursor: String?
    ) -> EngramServiceWebSettingsResponse {
        EngramServiceWebSettingsResponse(
            snapshotId: lease.id, observedAt: lease.observedAt, sources: prepared.sources,
            totalSessions: prepared.totalSessions, aliases: prepared.aliases.prefix(aliasCount).map(\.item),
            nextCursor: nextCursor, nodeName: .init(), peers: .init(), port: .init())
    }

    private func settingsSnapshot(_ db: Database, policy: ServiceWebMetadataPolicy, after: PositionKey?,
                                  limit: Int, keys: [String]? = nil) throws -> SettingsPrepared {
        let sources = Self.settingsSources(policy)
        let totalSessions = try authorizedSessionCount(db, policy: policy)
        var aliases = try settingsAliases(db, policy: policy)
        if let keys {
            let wanted = Set(keys.map { Data($0.utf8) })
            aliases = aliases.filter { wanted.contains(Data($0.cursorKey.utf8)) }
        }
        return SettingsPrepared(sources: sources, totalSessions: totalSessions,
            aliases: try Self.pageSettingsAliases(aliases, after: keys == nil ? after : nil, limit: limit))
    }

    private func authorizedSessionCount(_ db: Database, policy: ServiceWebMetadataPolicy) throws -> Int64 {
        let schema = try Self.schema(db)
        guard schema.capture else { return 0 }
        let (predicates, arguments) = try authorizedFacetBase(policy: policy, agents: .hide)
        let rows = try Row.fetchAll(db, sql: """
            SELECT i.machine_id, i.source_instance_id, COUNT(*) AS value
            FROM capture_ingest_identity_bindings i
            JOIN sessions s ON s.id = i.stored_session_id COLLATE BINARY
            \(Self.registryJoinSQL)
            WHERE \(predicates.joined(separator: " AND "))
            GROUP BY i.machine_id, i.source_instance_id
            ORDER BY i.machine_id COLLATE BINARY, i.source_instance_id COLLATE BINARY
            """, arguments: StatementArguments(arguments))
        var total: Int64 = 0
        for row in rows {
            try relay.check()
            guard try binding(db, machineID: try Self.string(row, "machine_id"),
                              instanceID: try Self.string(row, "source_instance_id"),
                              policy: policy) != nil else { continue }
            total = try Self.addCount(total, try Self.integer(row, "value"))
        }
        return total
    }

    private func settingsAliases(_ db: Database, policy: ServiceWebMetadataPolicy) throws -> [SettingsAliasRecord] {
        try settingsAliases(db, policy: policy, checkpoint: { try self.relay.check() })
    }

    private func settingsAliases(
        _ db: Database,
        policy: ServiceWebMetadataPolicy,
        checkpoint: () throws -> Void
    ) throws -> [SettingsAliasRecord] {
        guard try db.tableExists("project_aliases") else { return [] }
        let projects = try authorizedProjects(db, policy: policy, agents: .hide, checkpoint: checkpoint)
        var authorityByRaw: [Data: Data] = [:]
        for project in projects {
            authorityByRaw[Data(project.raw.utf8)] = project.authority
        }
        guard !authorityByRaw.isEmpty else { return [] }
        let rows = try Row.fetchAll(db, sql: """
            SELECT typeof(alias) AS alias_storage, CAST(alias AS BLOB) AS alias_bytes,
                typeof(canonical) AS canonical_storage, CAST(canonical AS BLOB) AS canonical_bytes
            FROM project_aliases
            """)
        var items: [SettingsAliasRecord] = []
        var seen: Set<Data> = []
        for row in rows {
            try checkpoint()
            guard let rawAlias = try Self.metadataText(row, "alias"),
                  let rawCanonical = try Self.metadataText(row, "canonical"),
                  let publishedAlias = Self.publishedProjectKey(rawAlias),
                  let publishedCanonical = Self.publishedProjectKey(rawCanonical),
                  !publishedAlias.utf8.elementsEqual(publishedCanonical.utf8),
                  let matched = authorityByRaw[Data(rawCanonical.utf8)] else { continue }
            let item = EngramServiceWebSettingsAlias(
                alias: publishedAlias, canonical: publishedCanonical,
                aliasLabel: Self.facetProjectLabel(rawAlias),
                canonicalLabel: Self.facetProjectLabel(rawCanonical))
            guard (try? EngramServiceWebMetadataValidation.settingsAlias(item)) != nil else { continue }
            let pair = Data((publishedCanonical + "\u{1E}" + publishedAlias).utf8)
            guard seen.insert(pair).inserted else { continue }
            items.append(SettingsAliasRecord(
                item: item, cursorKey: publishedCanonical + "\u{1E}" + publishedAlias,
                authority: try Self.bindingKey(
                    ["alias", publishedAlias, publishedCanonical, rawAlias, rawCanonical]) + matched,
                rawAlias: rawAlias, rawCanonical: rawCanonical))
        }
        return items
    }

    func addProjectAlias(
        _ request: EngramServiceWebAddAliasRequest,
        writer: EngramDatabaseWriter
    ) throws -> EngramServiceWebAliasMutationResponse {
        try writer.write { db in
            try Self.ensureProjectAliasTable(db)
            let policy = try self.currentPolicy()
            let projects = try self.authorizedProjects(
                db, policy: policy, agents: .hide, checkpoint: { try Task.checkCancellation() }
            )
            let matches = projects.filter { $0.published.utf8.elementsEqual(request.canonical.utf8) }
            if matches.count > 1 { throw ServiceWebMetadataError.stale }
            guard matches.count == 1, let rawCanonical = matches.first?.raw,
                  let publishedAlias = Self.publishedProjectKey(request.alias),
                  !publishedAlias.utf8.elementsEqual(request.canonical.utf8) else {
                throw ServiceWebMetadataError.invalidRequest
            }
            let before = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM project_aliases WHERE alias = ? AND canonical = ?",
                arguments: [request.alias, rawCanonical]
            ) ?? 0
            try db.execute(
                sql: "INSERT OR IGNORE INTO project_aliases (alias, canonical) VALUES (?, ?)",
                arguments: [request.alias, rawCanonical]
            )
            let after = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM project_aliases WHERE alias = ? AND canonical = ?",
                arguments: [request.alias, rawCanonical]
            ) ?? 0
            return try EngramServiceWebAliasMutationResponse(
                action: "add", alias: publishedAlias, canonical: request.canonical, changed: after > before ? 1 : 0
            )
        }
    }

    func removeProjectAlias(
        _ request: EngramServiceWebRemoveAliasRequest,
        writer: EngramDatabaseWriter
    ) throws -> EngramServiceWebAliasMutationResponse {
        try writer.write { db in
            try Self.ensureProjectAliasTable(db)
            let policy = try self.currentPolicy()
            let pairs = try self.settingsAliases(
                db, policy: policy, checkpoint: { try Task.checkCancellation() }
            )
            let matches = pairs.filter {
                $0.item.alias.utf8.elementsEqual(request.alias.utf8)
                    && $0.item.canonical.utf8.elementsEqual(request.canonical.utf8)
            }
            if matches.count > 1 { throw ServiceWebMetadataError.stale }
            guard let pair = matches.first else {
                return try EngramServiceWebAliasMutationResponse(
                    action: "remove", alias: request.alias, canonical: request.canonical, changed: 0
                )
            }
            try db.execute(
                sql: "DELETE FROM project_aliases WHERE alias = ? AND canonical = ?",
                arguments: [pair.rawAlias, pair.rawCanonical]
            )
            let changed = db.changesCount > 0 ? 1 : 0
            return try EngramServiceWebAliasMutationResponse(
                action: "remove", alias: request.alias, canonical: request.canonical, changed: changed
            )
        }
    }

    /// Pins a cancelled metadata-read control so tests can prove alias writes
    /// do not share that relay.
    func withPinnedCancelledReadRelay<T>(_ body: () throws -> T) throws -> T {
        let control = RequestControl(clock: clock, deadline: clock.now())
        control.cancel()
        relay.set(control)
        defer { relay.set(nil) }
        return try body()
    }

    private static func ensureProjectAliasTable(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS project_aliases (
              alias TEXT NOT NULL,
              canonical TEXT NOT NULL,
              created_at TEXT NOT NULL DEFAULT (datetime('now')),
              PRIMARY KEY (alias, canonical)
            );
        """)
    }

    private static func pageSettingsAliases(_ items: [SettingsAliasRecord], after: PositionKey?,
                                            limit: Int) throws -> [SettingsAliasRecord] {
        var items = items.sorted { $0.cursorKey.utf8.lexicographicallyPrecedes($1.cursorKey.utf8) }
        if let after {
            guard case .facet(let last) = after else { throw ServiceWebMetadataError.stale }
            items.removeAll {
                $0.cursorKey.utf8.lexicographicallyPrecedes(last.utf8) || $0.cursorKey.utf8.elementsEqual(last.utf8)
            }
        }
        if items.count > limit { items = Array(items.prefix(limit)) }
        return items
    }

    private func authorizedProjects(_ db: Database, policy: ServiceWebMetadataPolicy,
                                    agents: EngramServiceWebAgentFilter) throws -> [AuthorizedProject] {
        try authorizedProjects(db, policy: policy, agents: agents, checkpoint: { try self.relay.check() })
    }

    private func authorizedProjects(_ db: Database, policy: ServiceWebMetadataPolicy,
                                    agents: EngramServiceWebAgentFilter,
                                    checkpoint: () throws -> Void) throws -> [AuthorizedProject] {
        let schema = try Self.schema(db)
        guard schema.capture else { return [] }
        let (predicates, arguments) = try authorizedFacetBase(policy: policy, agents: agents)
        var sqlPredicates = predicates
        sqlPredicates.append("typeof(s.project) = 'text'")
        sqlPredicates.append("length(s.project) > 0")
        let rows = try Row.fetchAll(db, sql: """
            SELECT typeof(s.project) AS project_storage, CAST(s.project AS BLOB) AS project_bytes,
                i.machine_id, i.source_instance_id, COUNT(*) AS value
            FROM capture_ingest_identity_bindings i
            JOIN sessions s ON s.id = i.stored_session_id COLLATE BINARY
            \(Self.registryJoinSQL)
            WHERE \(sqlPredicates.joined(separator: " AND "))
            GROUP BY CAST(s.project AS BLOB), i.machine_id, i.source_instance_id
            ORDER BY CAST(s.project AS BLOB), i.machine_id COLLATE BINARY, i.source_instance_id COLLATE BINARY
            """, arguments: StatementArguments(arguments))
        var totals: [Data: (raw: String, published: String, count: Int64, fields: [String?])] = [:]
        for row in rows {
            try checkpoint()
            guard let raw = try Self.metadataText(row, "project"),
                  let published = Self.publishedProjectKey(raw) else { continue }
            guard let binding = try binding(db, machineID: try Self.string(row, "machine_id"),
                                           instanceID: try Self.string(row, "source_instance_id"),
                                           policy: policy) else { continue }
            let id = Data(published.utf8)
            if let existing = totals[id], !existing.raw.utf8.elementsEqual(raw.utf8) {
                throw ServiceWebMetadataError.unavailable
            }
            let count = try Self.addCount(totals[id]?.count ?? 0, try Self.integer(row, "value"))
            var fields = totals[id]?.fields ?? []
            fields.append(contentsOf: Self.bindingFields(binding))
            totals[id] = (raw, published, count, fields)
        }
        return try totals.values.map { entry in
            AuthorizedProject(raw: entry.raw, published: entry.published, count: entry.count,
                authority: try Self.bindingKey(["project", entry.published, String(entry.count)] + entry.fields))
        }
    }

    private static func addCount(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let total = lhs + rhs
        guard (0...9_007_199_254_740_991).contains(rhs), (0...9_007_199_254_740_991).contains(total) else {
            throw ServiceWebMetadataError.unavailable
        }
        return total
    }

    private func authorizedFacetBase(policy: ServiceWebMetadataPolicy,
                                     agents: EngramServiceWebAgentFilter) throws -> ([String], [DatabaseValueConvertible]) {
        let sources = policy.enabledSources.map(\.rawValue).sorted()
        guard !sources.isEmpty else { throw ServiceWebMetadataError.unavailable }
        return ([Self.sessionVisibilitySQL(agents),
                 "i.source IN (\(Array(repeating: "?", count: sources.count).joined(separator: ",")))"],
                sources.map { $0 as DatabaseValueConvertible })
    }

    private func authorizedStatsBase(request: EngramServiceWebStatsRequest,
                                     policy: ServiceWebMetadataPolicy) throws -> ([String], [DatabaseValueConvertible]) {
        var (predicates, arguments) = try authorizedFacetBase(policy: policy, agents: request.agents)
        if request.excludeNoise { predicates.append("(s.tier IS NULL OR s.tier != 'lite')") }
        if let since = request.since {
            predicates.append("date(s.start_time, 'localtime') >= ?")
            arguments.append(since)
        }
        if let until = request.until {
            predicates.append("date(s.start_time, 'localtime') <= ?")
            arguments.append(until)
        }
        return (predicates, arguments)
    }

    private func generation(_ db: Database, id: String?, sessionID: String) throws -> EngramServiceWebGenerationSummary? {
        guard let id, let row = try Row.fetchOne(db, sql: """
            SELECT generation_id, publication_sha256, parser_revision, collector_epoch, authority_generation, sequence,
                CAST(strftime('%s', created_at) AS INTEGER) AS committed_at,
                COALESCE(normalized_total_message_count, normalized_message_count) AS normalized_message_count
            FROM capture_ingest_generations WHERE generation_id = ? AND stored_session_id = ?
            """, arguments: [id, sessionID]) else { return nil }
        return EngramServiceWebGenerationSummary(generationId: try Self.string(row, "generation_id"),
            publicationSHA256: try Self.string(row, "publication_sha256"), parserRevision: try Self.string(row, "parser_revision"),
            collectorEpoch: try Self.string(row, "collector_epoch"), authorityGeneration: String(try Self.integer(row, "authority_generation")),
            sequence: String(try Self.integer(row, "sequence")), committedAt: try Self.optionalInteger(row, "committed_at"),
            normalizedMessageCount: Int(try Self.integer(row, "normalized_message_count")))
    }

    private static func safeText(_ value: String?, maximumBytes: Int) -> String? {
        guard let value else { return nil }
        let redacted = TranscriptRedactionPolicy.redact(value)
        guard redacted.utf8.count <= maximumBytes, !redacted.utf8.contains(0),
              !redacted.contains("/"), !redacted.contains("\\"), !redacted.contains("~") else { return nil }
        return redacted
    }

    private static func projectKey(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 128,
              value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              TranscriptRedactionPolicy.redact(value).utf8.elementsEqual(value.utf8) else { return nil }
        return value
    }

    private static func publishedProjectKey(_ value: String?) -> String? {
        guard let value, !value.isEmpty, !value.utf8.contains(0) else { return nil }
        if let token = projectKey(value) { return token }
        return "p." + ArchiveV2Hash.sha256(Data(value.utf8))
    }

    private static func facetProjectLabel(_ raw: String) -> String {
        let redacted = TranscriptRedactionPolicy.redact(raw)
        if let label = safeText(redacted, maximumBytes: 256) { return label }
        let base = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let baseRedacted = TranscriptRedactionPolicy.redact(base)
        if let label = safeText(baseRedacted, maximumBytes: 256), !label.isEmpty { return label }
        return "Project"
    }

    private static let fileActivityBreadcrumb = " › "

    /// Display-only breadcrumb. Never used as a filesystem locator.
    private static func fileActivityLabel(_ raw: String) -> String {
        let redacted = TranscriptRedactionPolicy.redact(raw)
        let parts = redacted.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
        var index = 0
        if let first = parts.first, first.count == 2, first.last == ":",
           let letter = first.first, letter.isLetter {
            index = 1
        }
        if index < parts.count {
            switch parts[index].lowercased() {
            case "users", "home", "volumes":
                index += 2
            case "private":
                index += 1
                if index < parts.count {
                    switch parts[index].lowercased() {
                    case "tmp", "var", "etc":
                        index += 1
                    case "users":
                        index += 2
                    default:
                        break
                    }
                }
            case "tmp", "var", "root":
                index += 1
            default:
                break
            }
        }
        var labels: [String] = []
        while index < parts.count {
            let part = parts[index]
            index += 1
            if part == "." || part == ".." { continue }
            if let safe = safeText(part, maximumBytes: 256), !safe.isEmpty {
                labels.append(safe)
            }
        }
        if labels.isEmpty { return "Unknown file" }
        let joined = labels.joined(separator: fileActivityBreadcrumb)
        if joined.utf8.count <= 1024 { return joined }
        var kept: [String] = []
        var size = 0
        let separator = fileActivityBreadcrumb.utf8.count
        for part in labels.reversed() {
            let extra = part.utf8.count + (kept.isEmpty ? 0 : separator)
            if size + extra > 1024 { break }
            kept.insert(part, at: 0)
            size += extra
        }
        return kept.isEmpty ? "Unknown file" : kept.joined(separator: fileActivityBreadcrumb)
    }

    private static func repoName(_ stored: String, path: String) -> String {
        if let name = safeText(stored, maximumBytes: 256), !name.isEmpty { return name }
        let breadcrumb = fileActivityLabel(path)
        return breadcrumb == "Unknown file" ? "Repository" : breadcrumb
    }

    private static func repoDisplayText(_ value: String?, maximumBytes: Int) -> String? {
        guard let value, !value.isEmpty, !value.utf8.contains(0) else { return nil }
        var text = TranscriptRedactionPolicy.redact(value)
        while text.hasSuffix("\u{FFFD}") { text.removeLast() }
        guard !text.isEmpty, !text.utf8.contains(0), text.utf8.count <= maximumBytes else { return nil }
        return text
    }

    private static func repoCommitHash(_ value: String?) -> String? {
        guard let value, (7...64).contains(value.utf8.count),
              value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }) else {
            return nil
        }
        return value
    }

    private static func metadataText(_ row: Row, _ column: String) throws -> String? {
        // GRDB's TEXT decoder uses String(cString:) and loses bytes after NUL.
        // Only these display fields use byte projections; preserve TEXT/NULL
        // storage checks and the full UTF-8 string before redaction and fences.
        switch (try string(row, column + "_storage"), (row[column + "_bytes"] as DatabaseValue).storage) {
        case ("null", .null): return nil
        case ("text", .blob(let bytes)):
            guard let value = String(data: bytes, encoding: .utf8), value.utf8.elementsEqual(bytes) else {
                throw ServiceWebMetadataError.unavailable
            }
            return value
        default: throw ServiceWebMetadataError.unavailable
        }
    }

    private static func publishedSessionSummary(_ db: Database, sessionID: String) throws -> String? {
        guard let value = try String.fetchOne(
            db,
            sql: "SELECT summary FROM sessions WHERE id = ? COLLATE BINARY",
            arguments: [sessionID]
        ) else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !value.utf8.contains(0),
              value.utf8.count <= EngramServiceWebReadLimits.maximumSessionSummaryBytes else {
            return nil
        }
        return value
    }

    private static func optionalString(_ row: Row, _ column: String) throws -> String? {
        switch (row[column] as DatabaseValue).storage {
        case .null: return nil
        case .string(let value): return value
        default: throw ServiceWebMetadataError.unavailable
        }
    }
    private static func string(_ row: Row, _ column: String) throws -> String {
        guard let value = try optionalString(row, column) else { throw ServiceWebMetadataError.unavailable }
        return value
    }
    private static func optionalInteger(_ row: Row, _ column: String) throws -> Int64? {
        switch (row[column] as DatabaseValue).storage {
        case .null: return nil
        case .int64(let value): return value
        default: throw ServiceWebMetadataError.unavailable
        }
    }
    private static func integer(_ row: Row, _ column: String) throws -> Int64 {
        guard let value = try optionalInteger(row, column) else { throw ServiceWebMetadataError.unavailable }
        return value
    }
    private static func optionalDouble(_ row: Row, _ column: String) throws -> Double? {
        switch (row[column] as DatabaseValue).storage {
        case .null: return nil
        case .double(let value): return value
        case .int64(let value): return Double(value)
        default: throw ServiceWebMetadataError.unavailable
        }
    }
    private static func double(_ row: Row, _ column: String) throws -> Double {
        guard let value = try optionalDouble(row, column) else { throw ServiceWebMetadataError.unavailable }
        return value
    }
    private static func scalarCount(_ row: Row, _ column: String) throws -> Int? {
        guard let value = try optionalInteger(row, column),
              (0...Int64(EngramServiceWebReadLimits.maximumMessages)).contains(value) else { return nil }
        return Int(value)
    }
    private static func count(_ db: Database, sql: String, arguments: StatementArguments) throws -> Int64 {
        guard let row = try Row.fetchOne(db, sql: sql, arguments: arguments) else { throw ServiceWebMetadataError.unavailable }
        let value = try integer(row, "value")
        guard (0...9_007_199_254_740_991).contains(value) else { throw ServiceWebMetadataError.unavailable }
        return value
    }

    // MARK: - One owned operation, cooperative SQLite cancellation, and leases

    private func submit<Value: Sendable>(deadline: ContinuousClock.Instant,
        _ operation: @escaping @Sendable (RequestControl) throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let control = RequestControl(clock: clock, deadline: min(deadline, clock.now() + ServiceWebMetadataLimits.maximumRequestDuration))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
                admission.lock()
                guard !stopping, !closeFailed else {
                    admission.unlock()
                    continuation.resume(throwing: ServiceWebMetadataError.unavailable)
                    return
                }
                pending[control.id] = control
                queue.async { [self] in
                    relay.set(control)
                    let result: Result<Value, Error>
                    do {
                        try control.check()
                        let value = try operation(control)
                        try control.check()
                        result = .success(value)
                    } catch {
                        for id in control.leaseIDs { try? retire(id) }
                        result = .failure(control.failure ?? Self.publicError(error))
                    }
                    relay.set(nil)
                    admission.lock()
                    pending[control.id] = nil
                    admission.unlock()
                    continuation.resume(with: result)
                    withExtendedLifetime(self) {}
                }
                admission.unlock()
            }
        } onCancel: {
            // This never resumes the continuation. The queue operation must
            // observe cancellation, unwind SQLite, and join before returning.
            control.cancel()
        }
    }

    private func read<Value>(_ snapshot: DatabaseSnapshot, control: RequestControl,
                             _ body: (Database) throws -> Value) throws -> Value {
        try control.check()
        return try snapshot.read { db in
            try control.check()
            try hooks.inDatabaseOperation?(.snapshotRead, db)
            try control.check()
            let value = try body(db)
            try control.check()
            return value
        }
    }

    private func makeSnapshot(_ control: RequestControl) throws -> DatabaseSnapshot {
        for id in leases.values.filter({ clock.now() >= $0.expiresAt }).map(\.id) { try retire(id) }
        if leases.count >= ServiceWebMetadataLimits.maximumSnapshots,
           let oldest = leases.values.min(by: { $0.order < $1.order }) { try retire(oldest.id) }
        try control.check()
        // Never called from a pool transaction. relay already belongs to this
        // request before makeSnapshot invokes prepareDatabase on GRDB's queue.
        return try pool.makeSnapshot()
    }

    private func acquire(snapshotID: String?, cursor: String?, key: Data, policy: ServiceWebMetadataPolicy,
                         control: RequestControl) throws -> (Lease, CursorPosition) {
        if let snapshotID, let cursor {
            guard let lease = leases[snapshotID], clock.now() < lease.expiresAt,
                  lease.key == key, Self.samePolicy(lease.policy, policy), let position = lease.cursors[cursor] else {
                throw ServiceWebMetadataError.stale
            }
            control.bind(lease.id, expiresAt: lease.expiresAt)
            try control.check()
            return (lease, position)
        }
        guard snapshotID == nil, cursor == nil else { throw ServiceWebMetadataError.stale }
        let created = clock.now()
        let snapshot = try makeSnapshot(control)
        do {
            try control.check()
            let schema = try snapshot.read { try Self.schema($0) }
            guard creationOrder < UInt64.max else { throw ServiceWebMetadataError.unavailable }
            creationOrder += 1
            let lease = Lease(snapshot: snapshot, key: key, policy: policy, order: creationOrder,
                expiresAt: created + ServiceWebMetadataLimits.leaseLifetime, schema: schema)
            leases[lease.id] = lease
            control.bind(lease.id, expiresAt: lease.expiresAt)
            lease.timer = clock.schedule(lease.expiresAt) { [weak self, id = lease.id] in self?.expire(id) }
            return (lease, CursorPosition(key: nil))
        } catch {
            // ARC ends the snapshot transaction before closing its reader.
            throw error
        }
    }

    private func expire(_ id: String) {
        admission.lock()
        guard !stopping else { admission.unlock(); return }
        // Enqueue under the same admission lock as stop's seal. A retirement
        // cannot slip behind the stop barrier while still owning a snapshot.
        queue.async { [weak self] in
            guard let self else { return }
            do { try self.retire(id) }
            catch {
                self.admission.lock()
                self.closeFailed = true
                self.admission.unlock()
            }
        }
        admission.unlock()
    }

    private func retire(_ id: String) throws {
        guard let lease = leases.removeValue(forKey: id) else { return }
        lease.timer?.cancel()
        lease.timer = nil
        // Releasing the last lease lets GRDB end the snapshot transaction and
        // close the connection in its required order. Never close it twice.
    }

    private func successor(_ lease: Lease, position: CursorPosition, count: Int, hasMore: Bool,
                           last: PositionKey?, proposed: String) throws -> String? {
        if let fixed = position.count, fixed != count { throw ServiceWebMetadataError.stale }
        position.count = count
        guard hasMore else { return nil }
        guard let last else { throw ServiceWebMetadataError.unavailable }
        if let cached = position.successor { return cached }
        lease.cursors[proposed] = CursorPosition(key: last)
        lease.cursorOrder.append(proposed)
        while lease.cursorOrder.count > ServiceWebMetadataLimits.maximumCursorPositions {
            lease.cursors[lease.cursorOrder.removeFirst()] = nil
        }
        position.successor = proposed
        return proposed
    }

    private func requirePolicy(_ original: ServiceWebMetadataPolicy) throws {
        guard Self.samePolicy(try currentPolicy(), original) else { throw ServiceWebMetadataError.stale }
    }

    private func requireSchema(_ db: Database, lease: Lease) throws {
        guard try Self.schema(db) == lease.schema else { throw ServiceWebMetadataError.stale }
    }

    private static func samePolicy(_ lhs: ServiceWebMetadataPolicy, _ rhs: ServiceWebMetadataPolicy) -> Bool {
        lhs.parserRevision.utf8.elementsEqual(rhs.parserRevision.utf8) && lhs.enabledSources == rhs.enabledSources
    }

    private static func publicError(_ error: Error) -> Error {
        if error is CancellationError { return CancellationError() }
        return (error as? ServiceWebMetadataError) ?? .unavailable
    }

    private static func bindingKey(_ values: [String?]) throws -> Data { try ArchiveCanonicalJSON.encode(values) }
    private static func token() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "") }
    private static func observedAt() -> Int64 { Int64(Date().timeIntervalSince1970) }

    private static func validate<Value: Codable>(_ value: Value, requestID: String) throws {
        let bytes = try JSONEncoder().encode(value)
        _ = try JSONDecoder().decode(Value.self, from: bytes)
        guard try encodedSuccessFrame(requestId: requestID, result: value).count <= EngramServiceWebReadLimits.maximumPageEnvelopeBytes else {
            throw ServiceWebMetadataError.unavailable
        }
    }

    private static func fittingCount(_ available: Int, limit: Int, fixed: Int?,
                                     frame: (Int) throws -> Data) throws -> Int {
        if let fixed {
            guard fixed <= available, try frame(fixed).count <= EngramServiceWebReadLimits.maximumPageEnvelopeBytes else {
                throw ServiceWebMetadataError.unavailable
            }
            return fixed
        }
        if available == 0 {
            guard try frame(0).count <= EngramServiceWebReadLimits.maximumPageEnvelopeBytes else {
                throw ServiceWebMetadataError.unavailable
            }
            return 0
        }
        var lower = 1
        var upper = min(limit, available)
        var best = 0
        while lower <= upper {
            let candidate = lower + (upper - lower) / 2
            if try frame(candidate).count <= EngramServiceWebReadLimits.maximumPageEnvelopeBytes {
                best = candidate
                lower = candidate + 1
            } else { upper = candidate - 1 }
        }
        guard best > 0 else { throw ServiceWebMetadataError.unavailable }
        return best
    }

    private final class RequestControl: @unchecked Sendable {
        let id = UUID()
        private let lock = NSLock()
        private let clock: ServiceWebMetadataClock
        private var deadline: ContinuousClock.Instant
        private var cancelled = false
        // Written and consumed only on the producer queue.
        var leaseIDs: [String] = []
        init(clock: ServiceWebMetadataClock, deadline: ContinuousClock.Instant) {
            self.clock = clock
            self.deadline = deadline
        }
        var failure: Error? {
            lock.withLock {
                if cancelled { return CancellationError() }
                return clock.now() >= deadline ? ServiceWebMetadataError.unavailable : nil
            }
        }
        func cancel() { lock.withLock { cancelled = true } }
        func check() throws { if let failure { throw failure } }
        func bind(_ id: String, expiresAt: ContinuousClock.Instant) {
            leaseIDs.append(id)
            lock.withLock { deadline = min(deadline, expiresAt) }
        }
    }

    private final class RequestRelay: @unchecked Sendable {
        private let lock = NSLock()
        private var current: RequestControl?
        func set(_ value: RequestControl?) { lock.withLock { current = value } }
        var shouldInterrupt: Bool { lock.withLock { current }?.failure != nil }
        func check() throws { try lock.withLock { current }?.check() }
    }

    private enum PositionKey { case session(Int64?, String), stream(String, String), facet(String) }
    private final class CursorPosition {
        let key: PositionKey?
        var count: Int?
        var successor: String?
        init(key: PositionKey?) { self.key = key }
    }
    private struct Schema: Equatable { let capture: Bool; let fts: Bool }
    private final class Lease {
        let id = UUID().uuidString
        let snapshot: DatabaseSnapshot
        let key: Data
        let policy: ServiceWebMetadataPolicy
        let order: UInt64
        let expiresAt: ContinuousClock.Instant
        let observedAt = ServiceWebMetadataProducer.observedAt()
        let schema: Schema
        var hasFTS: Bool { schema.fts }
        var timer: ServiceWebMetadataExpiryHandle?
        var cursors: [String: CursorPosition] = [:]
        var cursorOrder: [String] = []
        var sessionsTotal: SessionsTotal?
        init(snapshot: DatabaseSnapshot, key: Data, policy: ServiceWebMetadataPolicy, order: UInt64,
             expiresAt: ContinuousClock.Instant, schema: Schema) {
            self.snapshot = snapshot
            self.key = key
            self.policy = policy
            self.order = order
            self.expiresAt = expiresAt
            self.schema = schema
        }
    }
}
