import XCTest
@testable import Engram

final class EngramServiceClientTests: XCTestCase {
    func testStatusRequestUsesUniqueRequestIdsAndDecodesTypedStatus() async throws {
        let transport = RecordingServiceTransport { request in
            XCTAssertEqual(request.command, "status")
            return .success(
                requestId: request.requestId,
                result: #"{"state":"running","total":42,"todayParents":7}"#.data(using: .utf8)!
            )
        }
        let client = EngramServiceClient(transport: transport)

        let first = try await client.status()
        let second = try await client.status()

        XCTAssertEqual(first, .running(total: 42, todayParents: 7))
        XCTAssertEqual(second, .running(total: 42, todayParents: 7))
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertNotEqual(requests[0].requestId, requests[1].requestId)
    }

    func testStructuredErrorsPreserveRetryPolicyAndDetails() async throws {
        let transport = RecordingServiceTransport { request in
            .failure(
                requestId: request.requestId,
                error: EngramServiceErrorEnvelope(
                    name: "PermissionDeniedError",
                    message: "service token mismatch",
                    retryPolicy: "never",
                    details: [
                        "migrationId": .string("mig-123"),
                        "state": .string("failed")
                    ]
                )
            )
        }
        let client = EngramServiceClient(transport: transport)

        do {
            _ = try await client.status()
            XCTFail("Expected status to throw")
        } catch let error as EngramServiceError {
            guard case .commandFailed(let name, let message, let retryPolicy, let details) = error else {
                return XCTFail("Expected commandFailed, got \(error)")
            }
            XCTAssertEqual(name, "PermissionDeniedError")
            XCTAssertEqual(message, "service token mismatch")
            XCTAssertEqual(retryPolicy, "never")
            XCTAssertEqual(details?["migrationId"], .string("mig-123"))
            XCTAssertEqual(details?["state"], .string("failed"))
        }
    }

    func testStage3AppFacingCommandsEncodePayloadsAndDecodeTypedResponses() async throws {
        let transport = RecordingServiceTransport { request in
            switch request.command {
            case "health":
                return .success(requestId: request.requestId, result: #"{"ok":true,"status":"healthy","message":"ready"}"#.data(using: .utf8)!)
            case "liveSessions":
                return .success(requestId: request.requestId, result: #"{"sessions":[{"source":"codex","sessionId":"s-live","project":"engram","title":"Live","cwd":"/tmp/engram","filePath":"/tmp/s-live.jsonl","startedAt":"2026-04-23T01:00:00Z","model":"gpt-5","currentActivity":"coding","lastModifiedAt":"2026-04-23T01:01:00Z","activityLevel":"active"}],"count":1}"#.data(using: .utf8)!)
            case "sources":
                return .success(requestId: request.requestId, result: #"[{"name":"codex","sessionCount":2,"latestIndexed":"2026-04-23T01:02:00Z"}]"#.data(using: .utf8)!)
            case "skills":
                return .success(requestId: request.requestId, result: #"[{"name":"test-driven-development","description":"TDD","path":"~/.codex/skills/tdd/SKILL.md","scope":"global"}]"#.data(using: .utf8)!)
            case "memoryFiles":
                return .success(requestId: request.requestId, result: #"[{"name":"AGENTS.md","project":"engram","path":"~/project/AGENTS.md","sizeBytes":123,"preview":"rules"}]"#.data(using: .utf8)!)
            case "hooks":
                return .success(requestId: request.requestId, result: #"[{"event":"PostToolUse","command":"rtk test","scope":"project"}]"#.data(using: .utf8)!)
            case "hygiene":
                XCTAssertEqual(try Self.payload(request.payload, as: EngramServiceHygieneRequest.self), EngramServiceHygieneRequest(force: true))
                return .success(requestId: request.requestId, result: #"{"issues":[{"kind":"config","severity":"warning","message":"stale","detail":"fix","repo":"engram","action":"update"}],"score":91,"checkedAt":"2026-04-23T01:03:00Z"}"#.data(using: .utf8)!)
            case "handoff":
                XCTAssertEqual(try Self.payload(request.payload, as: EngramServiceHandoffRequest.self), EngramServiceHandoffRequest(cwd: "/tmp/engram", sessionId: "s1", format: "markdown"))
                return .success(requestId: request.requestId, result: "{\"brief\":\"## Handoff\",\"sessionCount\":3}".data(using: .utf8)!)
            case "replayTimeline":
                XCTAssertEqual(try Self.payload(request.payload, as: EngramServiceReplayTimelineRequest.self), EngramServiceReplayTimelineRequest(sessionId: "s1", limit: 500))
                return .success(requestId: request.requestId, result: #"{"sessionId":"s1","source":"codex","entries":[{"index":0,"role":"user","type":"message","preview":"hello","timestamp":"2026-04-23T01:04:00Z","tokens":{"input":4,"output":0},"durationToNextMs":15}],"totalEntries":1,"hasMore":false}"#.data(using: .utf8)!)
            case "embeddingStatus":
                return .success(requestId: request.requestId, result: #"{"available":true,"model":"text-embedding-3-small","embeddedCount":10,"totalSessions":20,"progress":50}"#.data(using: .utf8)!)
            case "generateSummary":
                XCTAssertEqual(try Self.payload(request.payload, as: EngramServiceGenerateSummaryRequest.self), EngramServiceGenerateSummaryRequest(sessionId: "s1"))
                return .success(requestId: request.requestId, result: #"{"summary":"Short summary"}"#.data(using: .utf8)!)
            case "confirmSuggestion":
                XCTAssertEqual(
                    try Self.payload(request.payload, as: EngramServiceConfirmSuggestionRequest.self),
                    EngramServiceConfirmSuggestionRequest(sessionId: "s1")
                )
                return .success(requestId: request.requestId, result: #"{"ok":true,"error":null}"#.data(using: .utf8)!)
            case "dismissSuggestion":
                XCTAssertEqual(
                    try Self.payload(request.payload, as: EngramServiceDismissSuggestionRequest.self),
                    EngramServiceDismissSuggestionRequest(sessionId: "s1", suggestedParentId: "parent-1")
                )
                return .success(requestId: request.requestId, result: #"{}"#.data(using: .utf8)!)
            case "triggerSync":
                XCTAssertEqual(try Self.payload(request.payload, as: EngramServiceTriggerSyncRequest.self), EngramServiceTriggerSyncRequest(peer: "laptop"))
                return .success(requestId: request.requestId, result: #"{"results":[{"peer":"laptop","ok":true,"pulled":2,"pushed":1}]}"#.data(using: .utf8)!)
            case "regenerateAllTitles":
                return .success(requestId: request.requestId, result: #"{"status":"started","total":4,"message":"Regenerating titles for 4 sessions in background"}"#.data(using: .utf8)!)
            case "projectMigrations":
                XCTAssertEqual(try Self.payload(request.payload, as: EngramServiceProjectMigrationsRequest.self), EngramServiceProjectMigrationsRequest(state: "committed", limit: 5))
                return .success(requestId: request.requestId, result: #"{"migrations":[{"id":"mig-1","oldPath":"/old","newPath":"/new","oldBasename":"old","newBasename":"new","state":"committed","startedAt":"2026-04-23T01:05:00Z","finishedAt":"2026-04-23T01:06:00Z","archived":false,"auditNote":"note","actor":"app"}]}"#.data(using: .utf8)!)
            case "projectCwds":
                XCTAssertEqual(try Self.payload(request.payload, as: EngramServiceProjectCwdsRequest.self), EngramServiceProjectCwdsRequest(project: "engram"))
                return .success(requestId: request.requestId, result: #"{"project":"engram","cwds":["/tmp/engram"]}"#.data(using: .utf8)!)
            case "linkSessions":
                XCTAssertEqual(
                    try Self.payload(request.payload, as: EngramServiceLinkSessionsRequest.self),
                    EngramServiceLinkSessionsRequest(targetDir: "/tmp/engram", actor: "mcp")
                )
                return .success(requestId: request.requestId, result: #"{"created":2,"skipped":1,"errors":[],"targetDir":"/tmp/engram","projectNames":["engram","engram-legacy"],"truncated":false}"#.data(using: .utf8)!)
            default:
                XCTFail("Unexpected command \(request.command)")
                return .success(requestId: request.requestId, result: Data("{}".utf8))
            }
        }
        let client = EngramServiceClient(transport: transport)

        let health = try await client.health()
        let liveSessions = try await client.liveSessions()
        let sources = try await client.sources()
        let skills = try await client.skills()
        let memoryFiles = try await client.memoryFiles()
        let hooks = try await client.hooks()
        let hygiene = try await client.hygiene(force: true)
        let handoff = try await client.handoff(EngramServiceHandoffRequest(cwd: "/tmp/engram", sessionId: "s1", format: "markdown"))
        let timeline = try await client.replayTimeline(sessionId: "s1", limit: 500)
        let embeddingStatus = try await client.embeddingStatus()
        let summary = try await client.generateSummary(EngramServiceGenerateSummaryRequest(sessionId: "s1"))
        let confirmSuggestion = try await client.confirmSuggestion(sessionId: "s1")
        try await client.dismissSuggestion(sessionId: "s1", suggestedParentId: "parent-1")
        let sync = try await client.triggerSync(EngramServiceTriggerSyncRequest(peer: "laptop"))
        let regenerateTitles = try await client.regenerateAllTitles()
        let migrations = try await client.projectMigrations(EngramServiceProjectMigrationsRequest(state: "committed", limit: 5))
        let cwds = try await client.projectCwds(project: "engram")
        let linkSessions = try await client.linkSessions(EngramServiceLinkSessionsRequest(targetDir: "/tmp/engram", actor: "mcp"))

        XCTAssertEqual(health.status, "healthy")
        XCTAssertEqual(liveSessions.sessions.first?.sessionId, "s-live")
        XCTAssertEqual(sources.first?.name, "codex")
        XCTAssertEqual(skills.first?.name, "test-driven-development")
        XCTAssertEqual(memoryFiles.first?.sizeBytes, 123)
        XCTAssertEqual(hooks.first?.event, "PostToolUse")
        XCTAssertEqual(hygiene.issues.first?.kind, "config")
        XCTAssertEqual(handoff.sessionCount, 3)
        XCTAssertEqual(timeline.entries.first?.tokens?.input, 4)
        XCTAssertEqual(embeddingStatus.progress, 50)
        XCTAssertEqual(summary.summary, "Short summary")
        XCTAssertTrue(confirmSuggestion.ok)
        XCTAssertEqual(sync.results.first?.pulled, 2)
        XCTAssertEqual(regenerateTitles.total, 4)
        XCTAssertEqual(migrations.migrations.first?.id, "mig-1")
        XCTAssertEqual(cwds.cwds, ["/tmp/engram"])
        XCTAssertEqual(linkSessions.projectNames, ["engram", "engram-legacy"])
        XCTAssertEqual(linkSessions.created, 2)
    }

    func testStage3ProjectMutationRequestsPreserveDaemonJsonFieldNames() async throws {
        let expectedMove = EngramServiceProjectMoveRequest(src: "/old", dst: "/new", dryRun: true, force: false, auditNote: "preview", actor: "app")
        let expectedArchive = EngramServiceProjectArchiveRequest(src: "/old", archiveTo: "归档完成", dryRun: true, force: true, auditNote: "archive", actor: "app")
        let expectedUndo = EngramServiceProjectUndoRequest(migrationId: "mig-1", force: true, actor: "app")
        let transport = RecordingServiceTransport { request in
            switch request.command {
            case "projectMove":
                XCTAssertEqual(try Self.payload(request.payload, as: EngramServiceProjectMoveRequest.self), expectedMove)
            case "projectArchive":
                XCTAssertEqual(try Self.payload(request.payload, as: EngramServiceProjectArchiveRequest.self), expectedArchive)
            case "projectUndo":
                XCTAssertEqual(try Self.payload(request.payload, as: EngramServiceProjectUndoRequest.self), expectedUndo)
            default:
                XCTFail("Unexpected command \(request.command)")
            }
            return .success(requestId: request.requestId, result: #"{"migrationId":"dry-run","state":"dry-run","ccDirRenamed":false,"totalFilesPatched":1,"totalOccurrences":2,"sessionsUpdated":0,"aliasCreated":false,"review":{"own":[],"other":[]},"manifest":[{"path":"/tmp/session.jsonl","occurrences":2}],"perSource":[{"id":"codex","root":"~/.codex","filesPatched":1,"occurrences":2,"issues":[{"path":"/tmp/large","reason":"too_large","detail":"skipped"}]}],"skippedDirs":[{"sourceId":"gemini-cli","reason":"encoded_name_unchanged","dir":"~/.gemini/tmp/engram"}],"suggestion":{"dst":"/archive/old","reason":"finished"}}"#.data(using: .utf8)!)
        }
        let client = EngramServiceClient(transport: transport)

        let move = try await client.projectMove(expectedMove)
        let archive = try await client.projectArchive(expectedArchive)
        let undo = try await client.projectUndo(expectedUndo)

        XCTAssertEqual(move.migrationId, "dry-run")
        XCTAssertEqual(archive.manifest?.first?.occurrences, 2)
        XCTAssertEqual(undo.perSource?.first?.issues?.first?.reason, "too_large")
    }

    func testConcurrentRequestsResolveAgainstMatchingRequestIds() async throws {
        let transport = RecordingServiceTransport { request in
            if request.command == "search" {
                try await Task.sleep(nanoseconds: 20_000_000)
                return .success(
                    requestId: request.requestId,
                    result: #"{"items":[{"id":"search-result","title":"Search Result"}]}"#.data(using: .utf8)!
                )
            }
            return .success(
                requestId: request.requestId,
                result: #"{"state":"running","total":3,"todayParents":1}"#.data(using: .utf8)!
            )
        }
        let client = EngramServiceClient(transport: transport)

        async let search = client.search(EngramServiceSearchRequest(query: "session", mode: "keyword", limit: 5))
        async let status = client.status()

        let (searchResult, statusResult) = try await (search, status)
        XCTAssertEqual(searchResult.items.map(\.id), ["search-result"])
        XCTAssertEqual(statusResult, .running(total: 3, todayParents: 1))
    }

    func testEventStreamCancellationClosesSubscription() async throws {
        let transport = RecordingServiceTransport { request in
            .success(requestId: request.requestId, result: Data("{}".utf8))
        }
        let client = EngramServiceClient(transport: transport)

        let stream = client.events()
        let task = Task {
            for try await _ in stream {}
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        task.cancel()
        _ = await task.result
        try await Task.sleep(nanoseconds: 10_000_000)

        let cancelled = await transport.eventSubscriptionCancelled
        XCTAssertTrue(cancelled)
    }

    func testMissingEndpointMapsToServiceUnavailable() async throws {
        let transport = RecordingServiceTransport { _ in
            throw EngramServiceError.serviceUnavailable(message: "socket missing")
        }
        let client = EngramServiceClient(transport: transport)

        do {
            _ = try await client.status()
            XCTFail("Expected serviceUnavailable")
        } catch let error as EngramServiceError {
            guard case .serviceUnavailable(let message) = error else {
                return XCTFail("Expected serviceUnavailable, got \(error)")
            }
            XCTAssertEqual(message, "socket missing")
        }
    }

    private static func payload<T: Decodable>(_ data: Data?, as type: T.Type) throws -> T {
        let data = try XCTUnwrap(data)
        return try JSONDecoder().decode(T.self, from: data)
    }
}

private actor RecordingServiceTransport: EngramServiceTransport {
    private let handler: @Sendable (EngramServiceRequestEnvelope) async throws -> EngramServiceResponseEnvelope
    private(set) var requests: [EngramServiceRequestEnvelope] = []
    private(set) var eventSubscriptionCancelled = false

    init(
        handler: @escaping @Sendable (EngramServiceRequestEnvelope) async throws -> EngramServiceResponseEnvelope
    ) {
        self.handler = handler
    }

    func send(_ request: EngramServiceRequestEnvelope, timeout: TimeInterval?) async throws -> EngramServiceResponseEnvelope {
        requests.append(request)
        return try await handler(request)
    }

    nonisolated func events() -> AsyncThrowingStream<EngramServiceEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { [weak self] _ in
                Task { await self?.markEventSubscriptionCancelled() }
            }
        }
    }

    func close() async {}

    private func markEventSubscriptionCancelled() {
        eventSubscriptionCancelled = true
    }
}
