import Foundation
import GRDB
import EngramCoreRead
import EngramCoreWrite

/// Admits only the current, visible, index-ready normalized generation. The
/// normalized store owns payload decoding and complete capture authority checks.
final class ServiceWebNormalizedTranscriptSnapshotProvider: ServiceWebTranscriptSnapshotProviding, @unchecked Sendable {
    private let pool: DatabasePool
    private let policySource: @Sendable () throws -> ServiceWebMetadataPolicy?
    private let queue = DispatchQueue(label: "com.engram.service.web-normalized-transcript", qos: .userInitiated)

    var supportsNormalizedTranscripts: Bool { true }

    init(databasePath: String, policy: @escaping @Sendable () throws -> ServiceWebMetadataPolicy?) throws {
        policySource = policy
        pool = try DatabasePool(path: databasePath, configuration: SQLiteConnectionPolicy.immediateReaderConfiguration())
    }

    deinit { try? stop() }

    func stop() throws { try pool.close() }

    func snapshot(sessionID: String, generation: String,
                  deadline: ContinuousClock.Instant) async throws -> ServiceTranscriptContinuation.Snapshot? {
        try await snapshot(sessionID: sessionID, generation: generation, request: nil, deadline: deadline)
    }

    func snapshot(request: EngramServiceWebMessagesRequest,
                  deadline: ContinuousClock.Instant) async throws -> ServiceTranscriptContinuation.Snapshot? {
        _ = try ServiceTranscriptContinuation.startingOrdinal(for: request)
        return try await snapshot(sessionID: request.sessionId, generation: request.generation,
                                  request: request, deadline: deadline)
    }

    func timeline(request: EngramServiceWebTimelineRequest,
                  deadline: ContinuousClock.Instant) async throws -> EngramServiceWebTimelineResponse {
        let window = try await window(
            sessionID: request.sessionId, generation: request.generation,
            admission: .timeline(offset: request.offset, limit: request.limit), deadline: deadline)
        guard let window else { throw EngramServiceWebReadError.staleCursor }
        return try ServiceWebTimelineProjection.response(request: request, loaded: window)
    }

    fileprivate struct Loaded: Equatable, Sendable {
        let snapshot: CaptureIngestNormalizedSnapshot
        let ordinals: [Int]
        let hasMore: Bool
    }

    private func snapshot(sessionID: String, generation: String, request: EngramServiceWebMessagesRequest?,
                          deadline: ContinuousClock.Instant) async throws -> ServiceTranscriptContinuation.Snapshot? {
        let admission = request.map { Admission.messages($0) } ?? .complete
        let prepared = try await window(sessionID: sessionID, generation: generation,
                                        admission: admission, deadline: deadline)
        guard let prepared else { return nil }
        var result = ServiceTranscriptContinuation.Snapshot(
            sessionId: prepared.snapshot.sessionID, generation: prepared.snapshot.generationID,
            messages: prepared.snapshot.messages)
        result.messageOrdinals = prepared.ordinals
        result.totalMessageCount = prepared.snapshot.totalMessageCount
        if prepared.hasMore {
            guard prepared.ordinals.count >= 2 else { throw ServiceWebTranscriptSnapshotError.unavailable }
            result.maximumPageFragments = prepared.ordinals.count - 1
        }
        return result
    }

    private func window(sessionID: String, generation: String, admission: Admission,
                        deadline: ContinuousClock.Instant) async throws -> Loaded? {
        do {
            try Self.checkpoint(deadline)
            let policy = try currentPolicy()
            try Self.checkpoint(deadline)
            let prepared = try await read { db in
                try Self.load(db, sessionID: sessionID, generation: generation, policy: policy,
                              admission: admission, deadline: deadline)
            }
            try Self.checkpoint(deadline)
            let current = try currentPolicy()
            guard Self.samePolicy(policy, current) else { throw ServiceWebTranscriptSnapshotError.unavailable }
            try Self.checkpoint(deadline)
            guard let prepared else { return nil }

            // The first read transaction has ended. Re-enter the existing
            // authority reader with fresh policy before releasing its messages;
            // neither a cached readiness scalar nor an earlier page authorizes it.
            let fresh = try await read { db in
                try Self.load(db, sessionID: sessionID, generation: generation, policy: current,
                              admission: admission, deadline: deadline)
            }
            try Self.checkpoint(deadline)
            guard Self.samePolicy(current, try currentPolicy()), let fresh, fresh == prepared else {
                throw ServiceWebTranscriptSnapshotError.unavailable
            }
            try Self.checkpoint(deadline)
            return fresh
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CaptureIngestReadinessError where error == .invalidArgument && admission.isBounded {
            throw EngramServiceWebReadError.invalidCursor
        } catch {
            try Task.checkCancellation()
            throw ServiceWebTranscriptSnapshotError.unavailable
        }
    }

    private func currentPolicy() throws -> ServiceWebMetadataPolicy {
        guard let policy = try policySource(),
              ServiceWebMetadataProducer.isValidParserRevision(policy.parserRevision),
              !policy.enabledSources.isEmpty else { throw ServiceWebTranscriptSnapshotError.unavailable }
        return policy
    }

    private static func samePolicy(_ lhs: ServiceWebMetadataPolicy, _ rhs: ServiceWebMetadataPolicy) -> Bool {
        lhs.parserRevision.utf8.elementsEqual(rhs.parserRevision.utf8) && lhs.enabledSources == rhs.enabledSources
    }

    private static func checkpoint(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw ServiceWebTranscriptSnapshotError.unavailable }
    }

    private enum Admission: Equatable, Sendable {
        case messages(EngramServiceWebMessagesRequest)
        case timeline(offset: Int, limit: Int)
        case complete

        var isBounded: Bool {
            switch self {
            case .messages, .timeline: return true
            case .complete: return false
            }
        }
    }

    private static func load(_ db: Database, sessionID: String, generation: String,
                             policy: ServiceWebMetadataPolicy, admission: Admission,
                             deadline: ContinuousClock.Instant) throws -> Loaded? {
        try checkpoint(deadline)
        // Visibility follows the metadata read surface. Ready is stricter:
        // parsed, ready and requested heads must agree with the ready ledger.
        guard try Int.fetchOne(db, sql: """
            SELECT 1
            FROM sessions s
            JOIN capture_ingest_identity_bindings i ON i.stored_session_id = s.id COLLATE BINARY
            JOIN capture_ingest_generations g ON g.stored_session_id = s.id COLLATE BINARY
            JOIN capture_ingest_ledger l ON l.publication_sha256 = g.publication_sha256 COLLATE BINARY
                AND l.parser_revision = g.parser_revision COLLATE BINARY
            WHERE s.id = ? COLLATE BINARY AND g.generation_id = ? COLLATE BINARY
                AND i.last_parsed_generation_id = g.generation_id COLLATE BINARY
                AND i.last_ready_generation_id = g.generation_id COLLATE BINARY
                AND l.status = 'index_ready'
                AND s.hidden_at IS NULL
                AND s.tier IN ('lite', 'normal', 'premium')
            """, arguments: [sessionID, generation]) == 1 else { return nil }
        let loaded: Loaded
        switch admission {
        case .messages(let request):
            let roles = Set(request.roles.compactMap { NormalizedMessageRole(rawValue: $0.rawValue) })
            let page = try CaptureIngestNormalizedStore.loadPage(db, sessionID: sessionID, generationID: generation,
                expectedParserRevision: policy.parserRevision, enabledSources: policy.enabledSources,
                fromOrdinal: ServiceTranscriptContinuation.startingOrdinal(for: request),
                maximumMessages: request.maxFragments + 1, roles: roles, deadline: deadline)
            loaded = Loaded(snapshot: page.snapshot, ordinals: page.ordinals, hasMore: page.hasMore)
        case .timeline(let offset, let limit):
            let page = try CaptureIngestNormalizedStore.loadPage(db, sessionID: sessionID, generationID: generation,
                expectedParserRevision: policy.parserRevision, enabledSources: policy.enabledSources,
                fromOrdinal: offset, maximumMessages: limit + 1,
                roles: [.user, .assistant, .system, .tool], deadline: deadline)
            loaded = Loaded(snapshot: page.snapshot, ordinals: page.ordinals, hasMore: page.hasMore)
        case .complete:
            let snapshot = try CaptureIngestNormalizedStore.load(db, sessionID: sessionID, generationID: generation,
                expectedParserRevision: policy.parserRevision, enabledSources: policy.enabledSources, deadline: deadline)
            loaded = Loaded(snapshot: snapshot, ordinals: Array(snapshot.messages.indices), hasMore: false)
        }
        let snapshot = loaded.snapshot
        try checkpoint(deadline)
        // Readiness.commit requires this exact completed FTS job for a visible
        // generation. A later edit of ready scalars cannot replace that proof.
        let expectedJob = "\(snapshot.sessionID):\(snapshot.syncVersion):\(snapshot.snapshotHash):fts"
        guard let jobID = snapshot.requiredFTSJobID, jobID.utf8.elementsEqual(expectedJob.utf8),
              let job = try Row.fetchOne(db, sql: """
                SELECT session_id, job_kind, target_sync_version, status FROM session_index_jobs WHERE id = ?
                """, arguments: [jobID]),
              case .string(let storedID) = (job["session_id"] as DatabaseValue).storage,
              storedID.utf8.elementsEqual(sessionID.utf8),
              case .string("fts") = (job["job_kind"] as DatabaseValue).storage,
              case .int64(let version) = (job["target_sync_version"] as DatabaseValue).storage,
              version == Int64(snapshot.syncVersion),
              case .string("completed") = (job["status"] as DatabaseValue).storage else {
            throw ServiceWebTranscriptSnapshotError.unavailable
        }
        try checkpoint(deadline)
        return loaded
    }

    /// Like other Service read facades, join the blocking SQLite read before
    /// checking caller cancellation again. No detached timeout work survives it.
    private func read<Value: Sendable>(_ operation: @escaping @Sendable (Database) throws -> Value) async throws -> Value {
        let pool = pool
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try pool.read(operation)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

enum ServiceWebTimelineProjection {
    fileprivate static func response(request: EngramServiceWebTimelineRequest,
                                     loaded: ServiceWebNormalizedTranscriptSnapshotProvider.Loaded
    ) throws -> EngramServiceWebTimelineResponse {
        let total = loaded.snapshot.totalMessageCount
        guard Data(loaded.snapshot.sessionID.utf8) == Data(request.sessionId.utf8),
              loaded.snapshot.generationID == request.generation,
              loaded.ordinals.count == loaded.snapshot.messages.count,
              (0...EngramServiceWebReadLimits.maximumMessages).contains(total) else {
            throw ServiceWebTranscriptSnapshotError.unavailable
        }
        if loaded.hasMore {
            guard loaded.ordinals.count >= 2 else { throw ServiceWebTranscriptSnapshotError.unavailable }
        }
        let keep: Int
        if loaded.hasMore || loaded.ordinals.count > request.limit {
            keep = min(request.limit, max(0, loaded.ordinals.count - 1))
        } else {
            keep = loaded.ordinals.count
        }
        let returned = Array(loaded.snapshot.messages.prefix(keep))
        let ordinals = Array(loaded.ordinals.prefix(keep))
        let sentinel = keep < loaded.snapshot.messages.count ? loaded.snapshot.messages[keep] : nil
        let nextOffset: Int?
        if let next = loaded.ordinals.dropFirst(keep).first {
            nextOffset = next
        } else if loaded.hasMore, let last = ordinals.last {
            nextOffset = last + 1
        } else {
            nextOffset = nil
        }
        var entries: [EngramServiceWebTimelineEntry] = []
        entries.reserveCapacity(returned.count)
        for index in returned.indices {
            let message = returned[index]
            let following = index + 1 < returned.count ? returned[index + 1] : sentinel
            entries.append(try entry(ordinal: ordinals[index], message: message, next: following))
        }
        return EngramServiceWebTimelineResponse(
            sessionId: request.sessionId, generation: request.generation,
            totalEntries: total, entries: entries, nextOffset: nextOffset)
    }

    static func entry(ordinal: Int, message: NormalizedMessage, next: NormalizedMessage?) throws -> EngramServiceWebTimelineEntry {
        guard let role = EngramServiceWebMessageRole(rawValue: message.role.rawValue) else {
            throw ServiceWebTranscriptSnapshotError.unavailable
        }
        let toolCalls = message.toolCalls ?? []
        let type: EngramServiceWebTimelineEntryType
        if message.role == .tool {
            type = .tool_result
        } else if !toolCalls.isEmpty {
            type = .tool_use
        } else {
            type = .message
        }
        let toolName = toolCalls.first.map { TranscriptRedactionPolicy.redact($0.name) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let timestamp = message.timestamp.map(TranscriptRedactionPolicy.redact)
            .flatMap { $0.isEmpty ? nil : $0 }
        let tokens = message.usage.map {
            EngramServiceWebTimelineTokens(input: $0.inputTokens, output: $0.outputTokens)
        }
        return EngramServiceWebTimelineEntry(
            index: ordinal, role: role, type: type,
            preview: preview(message.content), timestamp: timestamp, toolName: toolName,
            tokens: tokens, durationToNextMs: durationToNextMs(from: message.timestamp, to: next?.timestamp))
    }

    static func preview(_ content: String) -> String {
        let redacted = TranscriptRedactionPolicy.redact(content)
        if redacted.count <= EngramServiceWebReadLimits.maximumTimelinePreviewCharacters { return redacted }
        return String(redacted.prefix(EngramServiceWebReadLimits.maximumTimelinePreviewCharacters))
    }

    static func durationToNextMs(from: String?, to: String?) -> Int? {
        guard let start = parseISO(from), let end = parseISO(to) else { return nil }
        return max(0, Int((end.timeIntervalSince(start) * 1000).rounded()))
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func parseISO(_ value: String?) -> Date? {
        guard let value else { return nil }
        return isoFractional.date(from: value) ?? isoPlain.date(from: value)
    }
}
