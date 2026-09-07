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
    case responseTooLarge
}

enum ServiceWebMetadataLimits {
    static let maximumSnapshots = 8
    static let maximumCursorPositions = 128
    static let leaseLifetime: Duration = .seconds(30)
    static let maximumRequestDuration: Duration = .seconds(2)
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
}

enum ServiceWebMetadataOperation: Equatable, Sendable {
    case overview, sessions, detail
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

    func stop() throws
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

    func stop() throws {}
}

final class ServiceWebMetadataProducer: ServiceWebMetadataProviding, @unchecked Sendable {
    private let policySource: @Sendable () throws -> ServiceWebMetadataPolicy?
    private let clock: ServiceWebMetadataClock
    private let hooks: ServiceWebMetadataTestHooks
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
        hooks: ServiceWebMetadataTestHooks = .init()
    ) throws {
        self.policySource = policy
        self.clock = clock
        self.hooks = hooks
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
                try self.overviewRows(db, policy: policy, after: position.key, limit: request.limit + 1,
                                      observedAt: lease.observedAt)
            }
            let token = position.successor ?? Self.token()
            let count = try Self.fittingCount(prepared.count, limit: request.limit, fixed: position.count) { count in
                try Self.encodedSuccessFrame(requestId: requestId, result: EngramServiceWebOverviewResponse(
                    snapshotId: lease.id, observedAt: lease.observedAt,
                    capabilities: .init(keywordSearch: lease.hasFTS ? .available : .unavailable, transcriptRead: .unavailable),
                    streams: prepared.prefix(count).map(\.overview), nextCursor: prepared.count > count ? token : nil))
            }
            let page = Array(prepared.prefix(count))
            try self.hooks.afterPreparation?(.overview)
            try self.requirePolicy(policy)
            try self.pool.read { db in
                try self.requireSchema(db, lease: lease)
                for stream in page {
                    try control.check()
                    guard let fresh = try self.stream(db, machineID: stream.machineID, instanceID: stream.instanceID,
                                                     policy: policy, observedAt: lease.observedAt),
                          fresh.authority == stream.authority else { throw ServiceWebMetadataError.stale }
                }
            }
            try self.requirePolicy(policy)
            try control.check()
            let next = try self.successor(lease, position: position, count: count, hasMore: prepared.count > count,
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
            let key = try Self.bindingKey(["sessions", request.query, request.source, request.machineId,
                request.sourceInstanceId, request.projectKey, String(request.limit), ServiceWebMetadataLimits.sortVersion])
            let (lease, position) = try self.acquire(snapshotID: request.snapshotId, cursor: request.cursor,
                key: key, policy: policy, control: control)
            let prepared = try self.read(lease.snapshot, control: control) { db in
                try self.sessionRows(db, request: request, policy: policy, after: position.key,
                                     limit: request.limit + 1, sessionID: nil)
            }
            let token = position.successor ?? Self.token()
            let count = try Self.fittingCount(prepared.count, limit: request.limit, fixed: position.count) { count in
                try Self.encodedSuccessFrame(requestId: requestId, result: EngramServiceWebSessionsResponse(
                    snapshotId: lease.id, observedAt: lease.observedAt, items: prepared.prefix(count).map(\.summary),
                    nextCursor: prepared.count > count ? token : nil))
            }
            let page = Array(prepared.prefix(count))
            try self.hooks.afterPreparation?(.sessions)
            try self.requirePolicy(policy)
            try self.pool.read { db in
                try self.requireSchema(db, lease: lease)
                for item in page {
                    try control.check()
                    guard let fresh = try self.sessionRows(db, request: request, policy: policy, after: nil,
                        limit: 1, sessionID: item.summary.sessionId).first,
                          fresh.authority == item.authority else { throw ServiceWebMetadataError.stale }
                }
            }
            try self.requirePolicy(policy)
            try control.check()
            let next = try self.successor(lease, position: position, count: count, hasMore: prepared.count > count,
                last: page.last.map { .session($0.summary.startedAt, $0.summary.sessionId) }, proposed: token)
            let result = EngramServiceWebSessionsResponse(snapshotId: lease.id, observedAt: lease.observedAt,
                items: page.map(\.summary), nextCursor: next)
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
            let filter = try EngramServiceWebSessionsRequest(limit: 1)
            let prepared = try self.read(snapshot, control: control) { db -> (SessionRecord, EngramServiceWebSessionDetail)? in
                guard let row = try self.sessionRows(db, request: filter, policy: policy, after: nil,
                                                    limit: 1, sessionID: request.sessionId).first else { return nil }
                let detail = EngramServiceWebSessionDetail(session: row.summary,
                    lastParsed: try self.generation(db, id: row.parsedID, sessionID: request.sessionId),
                    lastReady: try self.generation(db, id: row.readyID, sessionID: request.sessionId),
                    transcriptAvailability: .unavailable, transcriptGeneration: nil, currentAttempt: nil)
                return (row, detail)
            }
            try self.hooks.afterPreparation?(.detail)
            let current = try self.currentPolicy()
            var detail: EngramServiceWebSessionDetail?
            if Self.samePolicy(current, policy), let prepared {
                let fresh = try self.pool.read { db in
                    try self.sessionRows(db, request: filter, policy: current, after: nil,
                                         limit: 1, sessionID: request.sessionId).first
                }
                if fresh?.authority == prepared.0.authority { detail = prepared.1 }
            }
            if !Self.samePolicy(try self.currentPolicy(), policy) { detail = nil }
            try control.check()
            let result = EngramServiceWebSessionDetailResponse(observedAt: Self.observedAt(), detail: detail)
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

    private static let visibleSQL = """
        s.hidden_at IS NULL AND s.parent_session_id IS NULL AND s.suggested_parent_id IS NULL
        AND (s.tier IS NULL OR s.tier != 'skip')
        AND s.source = i.source COLLATE BINARY
        AND s.authoritative_node = ('capture-v1.' || i.machine_id || '.' || i.source_instance_id) COLLATE BINARY
        """
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

    private struct SessionRecord {
        let summary: EngramServiceWebSessionSummary
        let authority: Data
        let parsedID: String?
        let readyID: String?
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

    private static func bindingFields(_ value: CaptureIngestSourceBinding) -> [String?] {
        [value.machineID, value.sourceInstanceID, value.source.rawValue, value.parseFormat.rawValue,
         value.configuredRoot, value.approvedEpoch, String(value.authorityGeneration)]
    }

    private func overviewRows(_ db: Database, policy: ServiceWebMetadataPolicy, after: PositionKey?,
                              limit: Int, observedAt: Int64) throws -> [StreamRecord] {
        guard try Self.schema(db).capture else { return [] }
        let sources = policy.enabledSources.map(\.rawValue).sorted()
        let placeholders = Array(repeating: "?", count: sources.count).joined(separator: ",")
        var position = after
        var result: [StreamRecord] = []
        repeat {
            try relay.check()
            var args: [DatabaseValueConvertible] = sources.map { $0 }
            var predicate = "r.source IN (\(placeholders))"
            if let position {
                guard case .stream(let machine, let instance) = position else { throw ServiceWebMetadataError.stale }
                predicate += " AND (r.machine_id COLLATE BINARY > ? OR (r.machine_id = ? COLLATE BINARY AND r.source_instance_id COLLATE BINARY > ?))"
                args.append(contentsOf: [machine, machine, instance])
            }
            args.append(limit)
            let rows = try Row.fetchAll(db, sql: """
                SELECT r.machine_id, r.source_instance_id FROM capture_ingest_source_registry r
                WHERE \(predicate) ORDER BY r.machine_id COLLATE BINARY, r.source_instance_id COLLATE BINARY LIMIT ?
                """, arguments: StatementArguments(args))
            for row in rows {
                let machine = try Self.string(row, "machine_id")
                let instance = try Self.string(row, "source_instance_id")
                position = .stream(machine, instance)
                if let record = try stream(db, machineID: machine, instanceID: instance, policy: policy, observedAt: observedAt) {
                    result.append(record)
                    if result.count == limit { return result }
                }
            }
            if rows.count < limit { return result }
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
        for row in try Row.fetchAll(db, sql: """
            SELECT l.status, COUNT(*) AS value FROM capture_ingest_ledger l
            JOIN capture_ingest_publications p ON p.publication_sha256 = l.publication_sha256 COLLATE BINARY
            WHERE p.machine_id = ? AND p.source_instance_id = ? GROUP BY l.status
            """, arguments: args) {
            let status = try Self.string(row, "status")
            guard ["pending", "processing", "parsed", "index_ready", "failed_retryable", "quarantined"].contains(status) else {
                throw ServiceWebMetadataError.unavailable
            }
            counts[status] = try Self.integer(row, "value")
        }
        let failures = try Self.count(db, sql: """
            SELECT COUNT(*) AS value FROM capture_ingest_ledger l
            JOIN capture_ingest_publications p ON p.publication_sha256 = l.publication_sha256 COLLATE BINARY
            WHERE p.machine_id = ? AND p.source_instance_id = ? AND l.status IN ('failed_retryable', 'quarantined')
              AND substr(l.failure_code, 1, 6) = 'parse.'
            """, arguments: args)
        let oldestRow = try Row.fetchOne(db, sql: """
            SELECT MIN(CAST(strftime('%s', l.created_at) AS INTEGER)) AS value FROM capture_ingest_ledger l
            JOIN capture_ingest_publications p ON p.publication_sha256 = l.publication_sha256 COLLATE BINARY
            WHERE p.machine_id = ? AND p.source_instance_id = ? AND l.status = 'pending'
            """, arguments: args)
        let oldest = try oldestRow.map { try Self.optionalInteger($0, "value") } ?? nil
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
        try Self.count(db, sql: """
            SELECT COUNT(DISTINCT i.stored_session_id COLLATE BINARY) AS value
            FROM capture_ingest_identity_bindings i
            JOIN sessions s ON s.id = i.stored_session_id COLLATE BINARY
            \(Self.registryJoinSQL)
            JOIN capture_ingest_generations g ON g.generation_id = i.last_parsed_generation_id COLLATE BINARY
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
            WHERE \(Self.visibleSQL) AND \(SessionSemanticSearchPolicy.searchableTierSQL)
              AND i.machine_id = ? AND i.source_instance_id = ? AND i.source = ? AND g.parser_revision = ? COLLATE BINARY
              AND length(g.generation_id) = 64 AND g.generation_id NOT GLOB '*[^0-9a-f]*'
              AND length(g.publication_sha256) = 64 AND g.publication_sha256 NOT GLOB '*[^0-9a-f]*'
              AND length(g.snapshot_hash) = 64 AND g.snapshot_hash NOT GLOB '*[^0-9a-f]*'
              AND EXISTS (SELECT 1 FROM sessions_fts f WHERE f.session_id = i.stored_session_id COLLATE BINARY)
            """, arguments: [binding.machineID, binding.sourceInstanceID, binding.source.rawValue, parser])
    }

    private func sessionRows(_ db: Database, request: EngramServiceWebSessionsRequest,
                             policy: ServiceWebMetadataPolicy, after: PositionKey?, limit: Int,
                             sessionID: String?) throws -> [SessionRecord] {
        let schema = try Self.schema(db)
        guard schema.capture else { return [] }
        let sources = policy.enabledSources.map(\.rawValue).sorted()
        var base = [Self.visibleSQL, "i.source IN (\(Array(repeating: "?", count: sources.count).joined(separator: ",")))"]
        var arguments: [DatabaseValueConvertible] = sources.map { $0 }
        for (column, value) in [("s.id", sessionID), ("i.source", request.source), ("i.machine_id", request.machineId),
                                ("i.source_instance_id", request.sourceInstanceId), ("s.project", request.projectKey)] {
            if let value { base.append("\(column) = ? COLLATE BINARY"); arguments.append(value) }
        }
        if let query = request.query {
            guard schema.fts else { throw ServiceWebMetadataError.unavailable }
            let terms = CJKText.searchableTerms(query)
            guard !terms.isEmpty else { return [] }
            base.append(SessionSemanticSearchPolicy.searchableTierSQL)
            let matches = CJKText.ftsMatchTerms(terms)
            for (index, term) in terms.enumerated() {
                if CJKText.containsCJK(term) || term.count < 3 {
                    base.append("EXISTS (SELECT 1 FROM sessions_fts f WHERE f.session_id = s.id COLLATE BINARY AND f.content LIKE ? ESCAPE '\\')")
                    arguments.append("%\(CJKText.escapeLikePattern(term))%")
                } else {
                    base.append("EXISTS (SELECT 1 FROM sessions_fts WHERE session_id = s.id COLLATE BINARY AND sessions_fts MATCH ?)")
                    arguments.append(matches[index])
                }
            }
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
                    typeof(s.generated_title) AS generated_title_storage, CAST(s.generated_title AS BLOB) AS generated_title_bytes,
                    typeof(s.custom_name) AS custom_name_storage, CAST(s.custom_name AS BLOB) AS custom_name_bytes,
                    typeof(s.project) AS project_storage, CAST(s.project AS BLOB) AS project_bytes,
                    \(Self.startSQL) AS started_at,
                    i.machine_id, i.source_instance_id, i.native_id, i.last_sync_version,
                    i.last_parsed_generation_id, i.last_ready_generation_id
                FROM capture_ingest_identity_bindings i JOIN sessions s ON s.id = i.stored_session_id COLLATE BINARY
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
                let summary = EngramServiceWebSessionSummary(sessionId: id, source: try Self.string(row, "source"),
                    captureIdentity: .init(machineId: machine, sourceInstanceId: instance), metadataGeneration: parsed,
                    title: Self.safeText(title, maximumBytes: 1024), projectKey: Self.projectKey(project),
                    projectLabel: Self.safeText(project, maximumBytes: 256), startedAt: start)
                var fields = Self.bindingFields(binding)
                for name in ["id", "source", "authoritative_node", "snapshot_hash", "tier", "native_id"] {
                    fields.append(try Self.optionalString(row, name))
                }
                fields.append(contentsOf: [generatedTitle, customName, project, parsed, ready])
                fields.append(String(try Self.integer(row, "sync_version")))
                fields.append(String(try Self.integer(row, "last_sync_version")))
                fields.append(start.map { String($0) })
                records.append(SessionRecord(summary: summary, authority: try Self.bindingKey(fields), parsedID: parsed, readyID: ready))
                if records.count == limit { return records }
            }
            if rows.count < limit { return records }
        } while true
    }

    private func generation(_ db: Database, id: String?, sessionID: String) throws -> EngramServiceWebGenerationSummary? {
        guard let id, let row = try Row.fetchOne(db, sql: """
            SELECT generation_id, publication_sha256, parser_revision, collector_epoch, authority_generation, sequence,
                CAST(strftime('%s', created_at) AS INTEGER) AS committed_at, normalized_message_count
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

    private enum PositionKey { case session(Int64?, String), stream(String, String) }
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
