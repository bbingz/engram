import Foundation
import GRDB
import XCTest
@testable import EngramCoreRead
@testable import EngramCoreWrite
@testable import EngramServiceCore

final class WebNormalizedTranscriptSnapshotProviderTests: XCTestCase {
    func testReadySnapshotPreservesCompleteNormalizedFieldsWithoutWrites() async throws {
        let fixture = try makeFixture()
        let before = try fixture.state()
        let snapshot = try await visible(fixture)
        XCTAssertEqual(snapshot.sessionId, fixture.receipt.sessionID)
        XCTAssertEqual(snapshot.generation, fixture.receipt.generationID)
        XCTAssertTrue(snapshot.messages == fixture.messages, "Preserve every complete normalized field")
        XCTAssertTrue(snapshot.totalKnownComplete)
        XCTAssertNil(snapshot.truncatedAt)
        XCTAssertNil(snapshot.parseFailure)
        XCTAssertEqual(try fixture.state(), before)
    }

    func testParsedArtifactAloneIsNotWebReady() async throws {
        let fixture = try makeFixture(ready: false)
        let stored = try fixture.writer.read {
            try CaptureIngestNormalizedStore.load($0, sessionID: fixture.receipt.sessionID,
                generationID: fixture.receipt.generationID, expectedParserRevision: TranscriptSQLFixture.parser,
                enabledSources: [.claudeCode])
        }
        XCTAssertTrue(stored.messages == fixture.messages, "A real parsed artifact exists before Web admission")
        let before = try fixture.state()
        await denied { try await fixture.snapshot() }
        XCTAssertEqual(try fixture.state(), before)
    }

    func testHiddenAndSkipVisibilityAreRecheckedOnEveryCall() async throws {
        for assignment in ["hidden_at = '2026-09-06T00:00:00Z'", "tier = 'skip'"] {
            let fixture = try makeFixture()
            _ = try await visible(fixture)
            try fixture.mutate("UPDATE sessions SET \(assignment)")
            let before = try fixture.state()
            await denied { try await fixture.snapshot() }
            XCTAssertEqual(try fixture.state(), before, assignment)
        }
    }

    func testAuthorizedAgentTranscriptRemainsReadableWithoutUpgradingTier() async throws {
        for assignment in ["parent_session_id = 'parent'", "suggested_parent_id = 'parent'",
                           "agent_role = 'subagent'", "agent_role = 'dispatched'"] {
            let fixture = try makeFixture()
            try fixture.mutate("UPDATE sessions SET \(assignment)")
            let before = try fixture.state()
            let snapshot = try await visible(fixture)
            XCTAssertTrue(snapshot.messages == fixture.messages, assignment)
            XCTAssertEqual(try fixture.state(), before, "Reads must not upgrade agent tiers")
            try fixture.mutate("UPDATE sessions SET tier = 'skip'")
            await denied { try await fixture.snapshot() }
        }
    }

    func testParsedReadyHeadsAndLedgerMustAgree() async throws {
        for sql in [
            "UPDATE capture_ingest_identity_bindings SET last_parsed_generation_id = NULL",
            "UPDATE capture_ingest_identity_bindings SET last_ready_generation_id = NULL",
            "UPDATE capture_ingest_ledger SET status = 'parsed'",
            "UPDATE capture_ingest_ledger SET failure_code = 'corrupt'",
        ] {
            let fixture = try makeFixture()
            _ = try await visible(fixture)
            try fixture.mutate(sql)
            let before = try fixture.state()
            await denied { try await fixture.snapshot() }
            XCTAssertEqual(try fixture.state(), before, sql)
        }
    }

    func testReadyScalarsCannotReplaceTheExactCompletedFTSJob() async throws {
        for sql in [
            "UPDATE session_index_jobs SET status = 'pending' WHERE job_kind = 'fts'",
            "UPDATE session_index_jobs SET target_sync_version = target_sync_version + 1 WHERE job_kind = 'fts'",
            "UPDATE capture_ingest_generations SET required_fts_job_id = NULL",
        ] {
            let fixture = try makeFixture()
            _ = try await visible(fixture)
            try fixture.mutate(sql)
            await denied { try await fixture.snapshot() }
        }
    }

    func testCurrentSessionSnapshotAndOwnershipMustStillMatch() async throws {
        for assignment in ["sync_version = sync_version + 1", "snapshot_hash = '\(String(repeating: "f", count: 64))'",
                           "authoritative_node = 'another-node'", "source = 'codex'"] {
            let fixture = try makeFixture()
            _ = try await visible(fixture)
            try fixture.mutate("UPDATE sessions SET \(assignment)")
            await denied { try await fixture.snapshot() }
        }
    }

    func testCurrentRegistryAndEpochHistoryCannotReuseEarlierAdmission() async throws {
        for sql in [
            "UPDATE capture_ingest_source_registry SET configured_root = '/different-root'",
            "UPDATE capture_ingest_source_registry SET parse_format = 'claudeCustomProfile'",
            "UPDATE capture_ingest_source_registry SET authority_generation = authority_generation + 1",
            "DELETE FROM capture_ingest_epoch_history",
        ] {
            let fixture = try makeFixture()
            _ = try await visible(fixture)
            try fixture.mutate(sql)
            await denied { try await fixture.snapshot() }
        }
    }

    func testMissingInvalidDisabledAndChangedParserPolicyAreUnavailable() async throws {
        let fixture = try makeFixture()
        let policies: [ServiceWebMetadataPolicy?] = [nil,
            .init(parserRevision: " ", enabledSources: [.claudeCode]),
            .init(parserRevision: "different-parser", enabledSources: [.claudeCode]),
            .init(parserRevision: TranscriptSQLFixture.parser, enabledSources: []),
            .init(parserRevision: TranscriptSQLFixture.parser, enabledSources: [.codex])]
        for policy in policies {
            fixture.policy.value = TranscriptSQLFixture.allowedPolicy
            _ = try await visible(fixture)
            fixture.policy.value = policy
            await denied { try await fixture.snapshot() }
        }
    }

    func testPolicyRevocationDuringReadRejectsThePreparedSnapshot() async throws {
        let fixture = try makeFixture()
        _ = try await visible(fixture)
        fixture.policy.arm { [policy = fixture.policy] call in
            if call == 2 { policy.value = nil }
        }
        await denied { try await fixture.snapshot() }
        XCTAssertGreaterThanOrEqual(fixture.policy.calls, 2)
    }

    func testAuthorityRevocationAfterLoadRejectsThePreparedSnapshot() async throws {
        for sql in ["UPDATE sessions SET hidden_at = '2026-09-06T00:00:00Z'",
                    "UPDATE capture_ingest_source_registry SET configured_root = '/revoked-root'",
                    "UPDATE capture_ingest_identity_bindings SET last_ready_generation_id = NULL"] {
            let fixture = try makeFixture()
            _ = try await visible(fixture)
            let writer = try XCTUnwrap(fixture.writer)
            fixture.policy.arm { [writer] call in
                if call == 2 { try writer.write { try $0.execute(sql: sql) } }
            }
            await denied { try await fixture.snapshot() }
            XCTAssertGreaterThanOrEqual(fixture.policy.calls, 2)
        }
    }

    func testCorruptNormalizedPayloadNeverBecomesAnEmptyOrPartialSuccess() async throws {
        for assignment in ["normalized_messages_json = x'FF'",
                           "normalized_messages_sha256 = '\(String(repeating: "f", count: 64))'",
                           "normalized_message_count = normalized_message_count + 1",
                           "normalized_schema_version = 2"] {
            let fixture = try makeFixture()
            _ = try await visible(fixture)
            if assignment == "normalized_schema_version = 2" {
                try fixture.writer.write { db in
                    try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
                    defer { try? db.execute(sql: "PRAGMA ignore_check_constraints = OFF") }
                    try db.execute(sql: "UPDATE capture_ingest_generations SET \(assignment)")
                }
            } else {
                try fixture.mutate("UPDATE capture_ingest_generations SET \(assignment)")
            }
            let before = try fixture.state()
            await denied { try await fixture.snapshot() }
            XCTAssertEqual(try fixture.state(), before, assignment)
        }
    }

    func testRequestedIdentityCannotSelectADifferentCurrentGeneration() async throws {
        let fixture = try makeFixture()
        _ = try await visible(fixture)
        await denied { try await fixture.snapshot(sessionID: "missing-session") }
        await denied { try await fixture.snapshot(generation: String(repeating: "f", count: 64)) }
        await denied { try await fixture.snapshot(generation: "invalid") }
        await denied { try await fixture.snapshot(sessionID: "") }
    }

    func testExpiredEntryDoesNotReadPolicyAndCancellationStaysCancellation() async throws {
        let fixture = try makeFixture()
        await denied { try await fixture.snapshot(deadline: ContinuousClock.now - .milliseconds(1)) }
        XCTAssertEqual(fixture.policy.calls, 0)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.snapshot()
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
        catch { XCTFail("Cancellation must not become \(error)") }
        XCTAssertEqual(fixture.policy.calls, 0)
    }

    func testCancellationAfterAsyncReadDoesNotReturnPreparedMessages() async throws {
        let fixture = try makeFixture()
        fixture.policy.arm { call in
            if call == 2 { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let task = Task { try await fixture.snapshot() }
        do { _ = try await task.value; XCTFail("Expected cancellation after read") }
        catch is CancellationError {}
        catch { XCTFail("Cancellation must not become \(error)") }
        XCTAssertGreaterThanOrEqual(fixture.policy.calls, 2)
    }

    func testExpiredPostReadDeadlineIsNotRenewed() async throws {
        let fixture = try makeFixture()
        fixture.policy.arm { call in
            if call == 2 { Thread.sleep(forTimeInterval: 0.08) }
        }
        await denied { try await fixture.snapshot(deadline: ContinuousClock.now + .milliseconds(50)) }
        XCTAssertGreaterThanOrEqual(fixture.policy.calls, 2)
    }

    func testStoppedProviderCannotReturnEarlierSnapshot() async throws {
        let fixture = try makeFixture()
        _ = try await visible(fixture)
        try fixture.stopProvider()
        await denied { try await fixture.snapshot() }
    }

    func testLongHistoryPageSkipsUnselectedRowsAndKeepsLastGlobalOrdinal() async throws {
        var messages = Array(repeating: NormalizedMessage(role: .tool, content: "unselected"), count: 10_001)
        messages[0] = .init(role: .user, content: "first visible")
        messages[10_000] = .init(role: .user, content: "last visible")
        let fixture = try makeFixture(messages: messages)
        // A nonselected row may not be fetched or decoded just to render this user page.
        try fixture.mutate("UPDATE capture_ingest_generation_messages SET message_json = x'FF' WHERE ordinal = 1")
        let request = try EngramServiceWebMessagesRequest(sessionId: fixture.receipt.sessionID,
            generation: fixture.receipt.generationID, roles: [.user], maxFragments: 1)
        let prepared = try await fixture.snapshot(request: request)
        let snapshot = try XCTUnwrap(prepared)
        XCTAssertEqual(snapshot.messageOrdinals, [0, 10_000])
        XCTAssertEqual(snapshot.messages.map(\.content), ["first visible", "last visible"])
        XCTAssertEqual(snapshot.totalMessageCount, 10_001)
        let first = try ServiceTranscriptContinuation.page(snapshot: snapshot, request: request, requestId: "first")
        XCTAssertEqual(first.fragments.map(\.messageOrdinal), [0])
        let next = try EngramServiceWebMessagesRequest(sessionId: fixture.receipt.sessionID,
            generation: fixture.receipt.generationID, roles: [.user], cursor: XCTUnwrap(first.nextCursor), maxFragments: 1)
        let tail = try await fixture.snapshot(request: next)
        let last = try ServiceTranscriptContinuation.page(snapshot: tail, request: next, requestId: "last")
        XCTAssertEqual(last.fragments.map(\.messageOrdinal), [10_000])
        XCTAssertTrue(last.isComplete)
        // Selecting the corrupt row must still fail closed.
        let toolRequest = try EngramServiceWebMessagesRequest(sessionId: fixture.receipt.sessionID,
            generation: fixture.receipt.generationID, roles: [.tool], maxFragments: 1)
        await denied { try await fixture.snapshot(request: toolRequest) }
        // Every continued page also rechecks visibility.
        try fixture.mutate("UPDATE sessions SET hidden_at = '2026-09-12T00:00:00Z'")
        await denied { try await fixture.snapshot(request: next) }
    }

    func testTimelineProjectsRolesToolsTokensGapsAndBoundedPreview() async throws {
        let secret = "sudo 密码是Example#4821，请继续"
        let messages: [NormalizedMessage] = [
            .init(role: .user, content: String(repeating: "A", count: 140),
                  timestamp: "2026-09-06T01:00:00Z"),
            .init(role: .assistant, content: "answer \(secret)",
                  timestamp: "2026-09-06T01:00:02Z",
                  toolCalls: [.init(name: "read_file", input: "/secret/path", output: "ok")],
                  usage: .init(inputTokens: 11, outputTokens: 7)),
            .init(role: .tool, content: "tool body", timestamp: "2026-09-06T01:00:03Z"),
            .init(role: .system, content: "sys", timestamp: "2026-09-06T01:00:04Z"),
        ]
        let fixture = try makeFixture(messages: messages)
        let page = try await fixture.timeline(offset: 0, limit: 10)
        XCTAssertEqual(page.totalEntries, 4)
        XCTAssertEqual(page.entries.map(\.index), [0, 1, 2, 3])
        XCTAssertEqual(page.entries.map(\.role), [.user, .assistant, .tool, .system])
        XCTAssertEqual(page.entries.map(\.type), [.message, .tool_use, .tool_result, .message])
        XCTAssertEqual(page.entries[0].preview.count, 100)
        XCTAssertFalse(page.entries[1].preview.contains("Example#4821"))
        XCTAssertEqual(page.entries[1].toolName, "read_file")
        XCTAssertEqual(page.entries[1].tokens?.input, 11)
        XCTAssertEqual(page.entries[1].tokens?.output, 7)
        XCTAssertEqual(page.entries[0].durationToNextMs, 2_000)
        XCTAssertNil(page.entries[3].durationToNextMs)
        XCTAssertNil(page.nextOffset)
        let messagesPage = try await visible(fixture)
        XCTAssertEqual(messagesPage.messages.count, 4)
    }

    func testTimelinePagesByOffsetAndPreservesCrossPageDuration() async throws {
        let messages = (0..<5).map { index in
            NormalizedMessage(role: .user, content: "m\(index)",
                              timestamp: "2026-09-06T01:00:0\(index)Z")
        }
        let fixture = try makeFixture(messages: messages)
        let first = try await fixture.timeline(offset: 0, limit: 2)
        XCTAssertEqual(first.entries.map(\.index), [0, 1])
        XCTAssertEqual(first.entries[1].durationToNextMs, 1_000)
        XCTAssertEqual(first.nextOffset, 2)
        XCTAssertEqual(first.totalEntries, 5)
        let second = try await fixture.timeline(offset: try XCTUnwrap(first.nextOffset), limit: 2)
        XCTAssertEqual(second.entries.map(\.index), [2, 3])
        XCTAssertEqual(second.nextOffset, 4)
        let last = try await fixture.timeline(offset: try XCTUnwrap(second.nextOffset), limit: 2)
        XCTAssertEqual(last.entries.map(\.index), [4])
        XCTAssertNil(last.nextOffset)
        XCTAssertNil(last.entries[0].durationToNextMs)
    }

    func testTimelineRejectsHiddenAndStaleGenerationBeforeContent() async throws {
        let fixture = try makeFixture()
        _ = try await fixture.timeline()
        try fixture.mutate("UPDATE sessions SET hidden_at = '2026-09-06T00:00:00Z'")
        do {
            _ = try await fixture.timeline()
            XCTFail("hidden generation must not emit timeline entries")
        } catch {
            XCTAssertTrue(error is EngramServiceWebReadError || error is ServiceWebTranscriptSnapshotError)
        }
        let visible = try makeFixture()
        do {
            _ = try await visible.timeline(generation: String(repeating: "a", count: 64))
            XCTFail("stale generation must not emit timeline entries")
        } catch {
            XCTAssertTrue(error is EngramServiceWebReadError || error is ServiceWebTranscriptSnapshotError)
        }
    }

    func testPagedReadRejectsPolicyChangeBeforeReleasingMessages() async throws {
        let fixture = try makeFixture()
        let request = try EngramServiceWebMessagesRequest(sessionId: fixture.receipt.sessionID,
            generation: fixture.receipt.generationID, roles: [.user], maxFragments: 1)
        fixture.policy.arm { call in
            if call == 2 { fixture.policy.value = nil }
        }
        await denied { try await fixture.snapshot(request: request) }
    }

    private func makeFixture(ready: Bool = true, messages: [NormalizedMessage]? = nil) throws -> TranscriptSQLFixture {
        let fixture = try TranscriptSQLFixture(ready: ready, messages: messages)
        addTeardownBlock { try fixture.close() }
        return fixture
    }

    private func visible(_ fixture: TranscriptSQLFixture) async throws -> ServiceTranscriptContinuation.Snapshot {
        let snapshot = try await fixture.snapshot()
        return try XCTUnwrap(snapshot, "The real completed generation must be admitted")
    }

    private func denied(_ operation: () async throws -> ServiceTranscriptContinuation.Snapshot?,
                        file: StaticString = #filePath, line: UInt = #line) async {
        do {
            let snapshot = try await operation()
            XCTAssertNil(snapshot, "No messages may escape a revoked authority", file: file, line: line)
        }
        catch { XCTAssertEqual(error as? ServiceWebTranscriptSnapshotError, .unavailable, file: file, line: line) }
    }
}

private final class TranscriptPolicyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = TranscriptSQLFixture.allowedPolicy as ServiceWebMetadataPolicy?
    private var count = 0
    private var hook: (@Sendable (Int) throws -> Void)?
    var value: ServiceWebMetadataPolicy? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    var calls: Int { lock.withLock { count } }
    func arm(_ hook: @escaping @Sendable (Int) throws -> Void) {
        lock.withLock { count = 0; self.hook = hook }
    }
    func read() throws -> ServiceWebMetadataPolicy? {
        let (call, callback) = lock.withLock { count += 1; return (count, hook) }
        try callback?(call)
        return value
    }
}

/// Real Ledger -> parsed generation -> FTS readiness, entirely in temporary SQLite.
/// The source manifest is evidence only: no source bytes are opened or replayed.
private final class TranscriptSQLFixture: @unchecked Sendable {
    static let parser = "swift-web-transcript-v1"
    static var allowedPolicy: ServiceWebMetadataPolicy { .init(parserRevision: parser, enabledSources: [.claudeCode]) }
    let root: URL
    let path: String
    let receipt: CaptureIngestCommittedGeneration
    let messages: [NormalizedMessage]
    let policy = TranscriptPolicyBox()
    var writer: EngramDatabaseWriter!
    private var provider: (any ServiceWebTranscriptSnapshotProviding)?
    private var providerStop: (() throws -> Void)?

    init(ready: Bool, messages customMessages: [NormalizedMessage]? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("web-normalized-\(UUID().uuidString)")
        path = root.appendingPathComponent("index.sqlite").path
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let writer = try EngramDatabaseWriter(path: path)
        self.writer = writer
        try writer.migrate()
        let machine = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
        let instance = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
        let epoch = "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"
        let journal = "11111111-1111-4111-8111-111111111111"
        let timestamp = "2026-09-06T01:02:03.000Z"
        let nativeID = "normalized-demo-session"
        messages = customMessages ?? [
            .init(role: .system, content: "Fixture system", timestamp: timestamp),
            .init(role: .user, content: "  Preserve 界🌍 and all normalized fields.  ", timestamp: timestamp),
            .init(role: .assistant, content: "Complete fixture answer.", timestamp: timestamp,
                  toolCalls: [.init(name: "fixture_tool", input: "input \\\"界", output: String(repeating: "界🌍\\\"\n", count: 24_000))],
                  usage: .init(inputTokens: 10, outputTokens: 20, cacheReadTokens: 3, cacheCreationTokens: 4)),
            .init(role: .tool, content: "Complete tool result", timestamp: timestamp),
        ]
        let binding = try writer.write {
            try CaptureIngestSourceRegistry.provision($0, machineID: machine, sourceInstanceID: instance,
                source: .claudeCode, parseFormat: .claudeDefault, configuredRoot: "/offline-client/.claude/projects", initialEpoch: epoch)
        }
        let bytes = try ArchiveCanonicalJSON.encode(messages)
        let digest = ArchiveV2Hash.sha256(bytes)
        let relative = "fixture/session.jsonl"
        let manifest = try ArchiveSourceManifest(captureID: ArchiveV2Hash.sha256(Data(nativeID.utf8)),
            machineID: machine, source: "claude-code", locator: binding.configuredRoot + "/" + relative,
            sessionID: nil, capturedAt: timestamp,
            generation: .init(device: 1, inode: 2, size: Int64(bytes.count), mtimeNs: 3, ctimeNs: 4, mode: 0o100600),
            wholeSourceSHA256: digest, rawByteCount: Int64(bytes.count),
            chunks: [try .init(ordinal: 0, rawSHA256: digest, rawByteCount: Int64(bytes.count))],
            replayLayout: .init(strategy: .singleFile, relativePaths: [relative]))
        let publication = try CollectorPublicationEnvelope(machineID: machine, sourceInstanceID: instance,
            collectorEpoch: epoch, sequence: 1, manifestSHA256: ArchiveV2Hash.sha256(ArchiveCanonicalJSON.encode(manifest)))
        let publicationSHA = try publication.sha256()
        let ack = try CollectorPublicationACK(serverID: "hq", journalID: journal, arrivalOrdinal: 1,
            publicationSHA256: publicationSHA, manifestSHA256: publication.manifestSHA256, storedAt: timestamp)
        let page = try CollectorPublicationPage(items: [try .init(publication: publication, ack: ack)],
            afterCursor: CollectorPublicationCursor(journalID: journal, afterArrivalOrdinal: 1).encoded(), hasMore: false)
        let claim = try writer.write { db in
            try CaptureIngestLedger.accept(db, page: page, requestedCursor: nil, serverID: "hq", parserRevision: Self.parser)
            return try XCTUnwrap(CaptureIngestLedger.claim(db, publicationSHA256: publicationSHA,
                parserRevision: Self.parser, now: 100, leaseDuration: 10))
        }
        let identity = try CaptureIngestIdentity(machineID: machine, sourceInstanceID: instance, source: .claudeCode, nativeID: nativeID)
        let info = NormalizedSessionInfo(id: nativeID, source: .claudeCode, startTime: timestamp, endTime: timestamp,
            cwd: "/offline-client/project", project: "fixture", model: "offline-fixture", messageCount: messages.count,
            userMessageCount: 1, assistantMessageCount: 1, toolMessageCount: 1, systemMessageCount: 1,
            summary: "Complete fixture summary", displayTitle: "Normalized transcript fixture", filePath: manifest.locator,
            sizeBytes: manifest.rawByteCount, originator: "claude-code")
        let replay = CaptureIngestReplayResult(publicationSHA256: publicationSHA, verifiedManifest: manifest,
            bindingSnapshot: binding, scan: .init(info: info, messages: messages), rawSourceSessionID: nativeID,
            nativeIdentity: identity, parentIdentity: nil, suggestedParentIdentity: nil)
        receipt = try writer.write { db in
            let receipt = try CaptureIngestCommitter.commitParsed(db, claim: claim, replay: replay,
                expectedParserRevision: Self.parser, now: 101, indexedAt: timestamp)
            if let job = receipt.requiredFTSJobID {
                try db.execute(sql: "UPDATE session_index_jobs SET not_before = NULL WHERE id = ?", arguments: [job])
            }
            return receipt
        }
        if ready {
            let snapshot = try writer.read {
                try CaptureIngestNormalizedStore.load($0, sessionID: receipt.sessionID, generationID: receipt.generationID,
                    expectedParserRevision: Self.parser, enabledSources: [.claudeCode])
            }
            let completed = try writer.write {
                try CaptureIngestReadiness.commit($0, snapshot: snapshot, expectedParserRevision: Self.parser, enabledSources: [.claudeCode])
            }
            XCTAssertEqual(completed.disposition, .indexed)
        }
        // The existing unavailable default produced the executable RED before
        // this factory was connected to the real normalized authority reader.
        let actual = try ServiceWebNormalizedTranscriptSnapshotProvider(databasePath: path,
            policy: { [policy = self.policy] in try policy.read() })
        provider = actual
        providerStop = { try actual.stop() }
    }

    func snapshot(sessionID: String? = nil, generation: String? = nil,
                  deadline: ContinuousClock.Instant = ContinuousClock.now + .seconds(2)) async throws -> ServiceTranscriptContinuation.Snapshot? {
        try await XCTUnwrap(provider).snapshot(sessionID: sessionID ?? receipt.sessionID,
            generation: generation ?? receipt.generationID, deadline: deadline)
    }

    func snapshot(request: EngramServiceWebMessagesRequest,
                  deadline: ContinuousClock.Instant = ContinuousClock.now + .seconds(2)) async throws -> ServiceTranscriptContinuation.Snapshot? {
        try await XCTUnwrap(provider).snapshot(request: request, deadline: deadline)
    }

    func timeline(offset: Int = 0, limit: Int = 100, generation: String? = nil,
                  deadline: ContinuousClock.Instant = ContinuousClock.now + .seconds(2)
    ) async throws -> EngramServiceWebTimelineResponse {
        try await XCTUnwrap(provider).timeline(
            request: try EngramServiceWebTimelineRequest(
                sessionId: receipt.sessionID, generation: generation ?? receipt.generationID,
                offset: offset, limit: limit),
            deadline: deadline)
    }

    func mutate(_ sql: String) throws { try writer.write { try $0.execute(sql: sql) } }

    func state() throws -> [String: [Row]] {
        try writer.read { db in
            var result: [String: [Row]] = [:]
            for table in ["sessions", "session_index_jobs", "sessions_fts", "fts_map", "metadata",
                          "capture_ingest_generations", "capture_ingest_identity_bindings", "capture_ingest_ledger",
                          "capture_ingest_publications", "capture_ingest_source_registry", "capture_ingest_epoch_history"] {
                result[table] = try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY rowid")
            }
            return result
        }
    }

    func stopProvider() throws { try providerStop?() }

    func close() throws {
        policy.arm { _ in }
        try stopProvider()
        providerStop = nil
        provider = nil
        writer = nil
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }
}
