import Darwin
import Foundation
import GRDB
import XCTest
import EngramCoreRead
import EngramCoreWrite
@testable import EngramServiceCore

final class WebGenerationWriteTests: XCTestCase {
    private let requestID = "AAAAAAAA-0000-4000-8000-000000000213"

    func testLongSummarySurvivesGatePersistAndSessionDetail() async throws {
        let env = try prepared()
        defer { env.tearDown() }
        try env.fixture.seedBoundSession(
            id: "one", start: "2026-09-01 12:00:00", nativeID: "native-one", title: nil, indexReady: true
        )
        let generation = try readyGeneration(env, id: "one")
        let long = Array(repeating: "Generated constellation summary.", count: 10).joined(separator: " ")
        XCTAssertGreaterThan(long.count, 200)
        XCTAssertEqual(TranscriptRedactionPolicy.redactedSummary(long).count, 200)
        let saved = try await EngramServiceCommandHandler.webGenerateSummary(
            EngramServiceWebGenerateSummaryRequest(sessionId: "one", generation: generation),
            writerGate: env.gate,
            snapshotProvider: StubTranscriptProvider(sessionId: "one", generation: generation),
            settingsURL: env.settingsURL,
            summaryConfig: Self.config,
            summarize: { context, _ in
                XCTAssertTrue(context.transcript.contains("constellation"))
                XCTAssertTrue(context.nativeSummary.isEmpty)
                return long
            }
        ).value
        XCTAssertEqual(saved.summary, long)
        let stored = try env.writer.read { db in
            try String.fetchOne(db, sql: "SELECT summary FROM sessions WHERE id = 'one'")
        }
        XCTAssertEqual(stored, long)
        XCTAssertGreaterThan(try XCTUnwrap(stored).count, 200)
        let producer = try env.fixture.producer()
        defer { try? producer.stop() }
        let detail = try await producer.sessionDetail(
            try EngramServiceWebSessionDetailRequest(sessionId: "one"),
            requestId: requestID,
            deadline: env.fixture.deadline()
        )
        XCTAssertEqual(detail.detail?.summary, long)
    }

    func testMissingProviderIsUnavailableAndDoesNotWrite() async throws {
        let env = try prepared()
        defer { env.tearDown() }
        try env.fixture.seedBoundSession(
            id: "one", start: "2026-09-01 12:00:00", nativeID: "native-one", title: nil, indexReady: true
        )
        let generation = try readyGeneration(env, id: "one")
        do {
            _ = try await EngramServiceCommandHandler.webGenerateSummary(
                EngramServiceWebGenerateSummaryRequest(sessionId: "one", generation: generation),
                writerGate: env.gate,
                snapshotProvider: StubTranscriptProvider(sessionId: "one", generation: generation),
                settingsURL: env.settingsURL,
                summaryConfig: nil,
                summarize: { _, _ in
                    XCTFail("Missing provider must not call the model")
                    return "should-not-persist"
                }
            )
            XCTFail("Missing provider must fail")
        } catch {
            guard case .serviceUnavailable? = error as? EngramServiceError else {
                return XCTFail("Expected unavailable, got \(error)")
            }
        }
        let stored = try env.writer.read { db in
            try String.fetchOne(db, sql: "SELECT summary FROM sessions WHERE id = 'one'")
        }
        XCTAssertNil(stored)
    }

    func testRevokedAdmissionAfterGenerateDoesNotPersist() async throws {
        let env = try prepared()
        defer { env.tearDown() }
        try env.fixture.seedBoundSession(
            id: "one", start: "2026-09-01 12:00:00", nativeID: "native-one", title: nil, indexReady: true
        )
        let generation = try readyGeneration(env, id: "one")
        do {
            _ = try await EngramServiceCommandHandler.webGenerateSummary(
                EngramServiceWebGenerateSummaryRequest(sessionId: "one", generation: generation),
                writerGate: env.gate,
                snapshotProvider: StubTranscriptProvider(sessionId: "one", generation: generation),
                settingsURL: env.settingsURL,
                summaryConfig: Self.config,
                summarize: { _, _ in
                    try env.writer.write { db in
                        try db.execute(sql: "UPDATE sessions SET hidden_at = '2026-09-13 00:00:00' WHERE id = 'one'")
                    }
                    return String(repeating: "Generated constellation summary. ", count: 10)
                }
            )
            XCTFail("Revoked session must not persist")
        } catch {
            guard case .commandFailed(let name, _, _, _)? = error as? EngramServiceError else {
                return XCTFail("Expected stale persist, got \(error)")
            }
            XCTAssertEqual(name, "StaleCursor")
        }
        let stored = try env.writer.read { db in
            try String.fetchOne(db, sql: "SELECT summary FROM sessions WHERE id = 'one'")
        }
        XCTAssertNil(stored)
    }

    func testStaleGenerationNeverCallsProvider() async throws {
        let env = try prepared()
        defer { env.tearDown() }
        try env.fixture.seedBoundSession(
            id: "one", start: "2026-09-01 12:00:00", nativeID: "native-one", title: nil, indexReady: true
        )
        let stale = String(repeating: "cd", count: 32)
        do {
            _ = try await EngramServiceCommandHandler.webGenerateTitle(
                EngramServiceWebGenerateTitleRequest(sessionId: "one", generation: stale),
                writerGate: env.gate,
                snapshotProvider: StubTranscriptProvider(sessionId: "one", generation: stale),
                settingsURL: env.settingsURL,
                titleConfig: Self.config,
                titleProvider: { _, _ in
                    XCTFail("Stale generation must not call the model")
                    return "Stale Title"
                }
            )
            XCTFail("Stale generation must fail")
        } catch {
            guard case .commandFailed(let name, _, _, _)? = error as? EngramServiceError else {
                return XCTFail("Expected stale, got \(error)")
            }
            XCTAssertEqual(name, "StaleCursor")
        }
    }

    func testCustomNameKeepsDisplayTitlePrecedence() async throws {
        let env = try prepared()
        defer { env.tearDown() }
        try env.fixture.seedBoundSession(
            id: "one", start: "2026-09-01 12:00:00", nativeID: "native-one", title: nil, indexReady: true
        )
        try env.writer.write { db in
            try db.execute(sql: "UPDATE sessions SET custom_name = 'Pinned name' WHERE id = 'one'")
        }
        let generation = try readyGeneration(env, id: "one")
        let saved = try await EngramServiceCommandHandler.webGenerateTitle(
            EngramServiceWebGenerateTitleRequest(sessionId: "one", generation: generation),
            writerGate: env.gate,
            snapshotProvider: StubTranscriptProvider(sessionId: "one", generation: generation),
            settingsURL: env.settingsURL,
            titleConfig: Self.config,
            titleProvider: { _, _ in "Generated title" }
        ).value
        XCTAssertEqual(saved.title, "Generated title")
        XCTAssertEqual(saved.displayTitle, "Pinned name")
        let stored = try env.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT custom_name, generated_title FROM sessions WHERE id = 'one'")
        }
        XCTAssertEqual(stored?["custom_name"] as String?, "Pinned name")
        XCTAssertEqual(stored?["generated_title"] as String?, "Generated title")
    }

    func testMissingTitleBatchExcludesHiddenSkipLiteTitledAndUnbound() async throws {
        let env = try prepared()
        defer { env.tearDown() }
        try env.fixture.seedBoundSession(
            id: "missing-a", start: "2026-09-01 12:00:00", nativeID: "native-a", title: nil, indexReady: true
        )
        try env.fixture.seedBoundSession(
            id: "missing-b", start: "2026-09-01 11:00:00", nativeID: "native-b", title: nil, indexReady: true
        )
        try env.fixture.seedBoundSession(
            id: "already-titled", start: "2026-09-01 10:00:00", nativeID: "native-titled", indexReady: true
        )
        try env.fixture.seedBoundSession(
            id: "lite", start: "2026-09-01 09:00:00", nativeID: "native-lite", title: nil, tier: "lite", indexReady: true
        )
        try env.fixture.seedBoundSession(
            id: "skip", start: "2026-09-01 08:00:00", nativeID: "native-skip", title: nil, tier: "skip", indexReady: true
        )
        try env.fixture.seedBoundSession(
            id: "hidden", start: "2026-09-01 07:00:00", nativeID: "native-hidden", title: nil, hidden: true, indexReady: true
        )
        try env.fixture.seedLocalSession(id: "unbound")
        try env.writer.write { db in
            try db.execute(sql: """
                UPDATE sessions SET message_count = 4
                WHERE id IN ('missing-a', 'missing-b', 'already-titled', 'lite', 'skip', 'hidden', 'unbound')
                """)
        }
        let candidates = try EngramServiceCommandHandler.webMissingTitleCandidates(
            databasePath: env.fixture.path, settingsURL: env.settingsURL
        )
        XCTAssertEqual(candidates.map(\.sessionId), ["missing-a", "missing-b"])
        let hold = GenerationHold()
        let first = try await EngramServiceCommandHandler.webRegenerateTitles(
            writerGate: env.gate,
            snapshotProvider: AnyReadyTranscriptProvider(),
            settingsURL: env.settingsURL,
            titleConfig: Self.config,
            titleProvider: { _, _ in
                await hold.park()
                return "Batch Title"
            }
        )
        XCTAssertEqual(first.status, "started")
        XCTAssertEqual(first.total, 2)
        let second = try await EngramServiceCommandHandler.webRegenerateTitles(
            writerGate: env.gate,
            snapshotProvider: AnyReadyTranscriptProvider(),
            settingsURL: env.settingsURL,
            titleConfig: Self.config,
            titleProvider: { _, _ in "Should not run" }
        )
        XCTAssertEqual(second.status, "running")
        XCTAssertNil(second.total)
        hold.go()
        let deadline = Date().addingTimeInterval(5)
        var titled: [String] = []
        repeat {
            titled = try env.writer.read { db in
                try String.fetchAll(db, sql: """
                    SELECT id FROM sessions
                    WHERE generated_title = 'Batch Title'
                    ORDER BY id
                    """)
            }
            if titled == ["missing-a", "missing-b"] { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        } while Date() < deadline
        XCTAssertEqual(titled, ["missing-a", "missing-b"])
        let titledKept = try env.writer.read { db in
            try String.fetchOne(db, sql: "SELECT generated_title FROM sessions WHERE id = 'already-titled'")
        }
        XCTAssertEqual(titledKept, "title")
        let liteTitle = try env.writer.read { db in
            try String.fetchOne(db, sql: "SELECT generated_title FROM sessions WHERE id = 'lite'")
        }
        XCTAssertNil(liteTitle)
    }

    func testBatchPersistRechecksLiteAndMessageCount() async throws {
        let env = try prepared()
        defer { env.tearDown() }
        try env.fixture.seedBoundSession(
            id: "per-session-lite", start: "2026-09-01 12:00:00", nativeID: "native-per-lite",
            title: nil, tier: "lite", indexReady: true
        )
        try env.writer.write { db in
            try db.execute(sql: "UPDATE sessions SET message_count = 1 WHERE id = 'per-session-lite'")
        }
        let perSessionGeneration = try readyGeneration(env, id: "per-session-lite")
        let perSession = try await EngramServiceCommandHandler.webGenerateTitle(
            EngramServiceWebGenerateTitleRequest(sessionId: "per-session-lite", generation: perSessionGeneration),
            writerGate: env.gate,
            snapshotProvider: StubTranscriptProvider(sessionId: "per-session-lite", generation: perSessionGeneration),
            settingsURL: env.settingsURL,
            titleConfig: Self.config,
            titleProvider: { _, _ in "Per session title" }
        ).value
        XCTAssertEqual(perSession.title, "Per session title")
        for (id, native, mutation) in [
            ("batch-lite", "native-batch-lite", "tier = 'lite'"),
            ("batch-short", "native-batch-short", "message_count = 1"),
        ] {
            try env.fixture.seedBoundSession(
                id: id, start: "2026-09-01 13:00:00", nativeID: native, title: nil, indexReady: true
            )
            try env.writer.write { db in
                try db.execute(sql: "UPDATE sessions SET message_count = 4, generated_title = NULL WHERE id = ?",
                               arguments: [id])
            }
            let started = try await EngramServiceCommandHandler.webRegenerateTitles(
                writerGate: env.gate,
                snapshotProvider: AnyReadyTranscriptProvider(),
                settingsURL: env.settingsURL,
                titleConfig: Self.config,
                titleProvider: { _, _ in
                    try env.writer.write { db in
                        try db.execute(sql: "UPDATE sessions SET \(mutation) WHERE id = ?", arguments: [id])
                    }
                    return "Batch Title"
                }
            )
            XCTAssertEqual(started.status, "started")
            let deadline = Date().addingTimeInterval(5)
            var running = true
            while running && Date() < deadline {
                let again = try await EngramServiceCommandHandler.webRegenerateTitles(
                    writerGate: env.gate,
                    snapshotProvider: AnyReadyTranscriptProvider(),
                    settingsURL: env.settingsURL,
                    titleConfig: Self.config,
                    titleProvider: { _, _ in "Should not run" }
                )
                running = again.status == "running"
                if running { try await Task.sleep(nanoseconds: 50_000_000) }
            }
            XCTAssertFalse(running, "\(id) batch must finish")
            let stored = try env.writer.read { db in
                try String.fetchOne(db, sql: "SELECT generated_title FROM sessions WHERE id = ?", arguments: [id])
            }
            XCTAssertNil(stored, "\(mutation) must keep the missing-title batch from writing")
        }
    }

    func testOversizedSummaryIsRejectedWithoutPreviewTruncation() async throws {
        let env = try prepared()
        defer { env.tearDown() }
        try env.fixture.seedBoundSession(
            id: "one", start: "2026-09-01 12:00:00", nativeID: "native-one", title: nil, indexReady: true
        )
        let generation = try readyGeneration(env, id: "one")
        do {
            _ = try await EngramServiceCommandHandler.webGenerateSummary(
                EngramServiceWebGenerateSummaryRequest(sessionId: "one", generation: generation),
                writerGate: env.gate,
                snapshotProvider: StubTranscriptProvider(sessionId: "one", generation: generation),
                settingsURL: env.settingsURL,
                summaryConfig: Self.config,
                summarize: { _, _ in String(repeating: "x", count: 50_001) }
            )
            XCTFail("Oversized summary must be rejected")
        } catch {
            guard case .invalidRequest? = error as? EngramServiceError else {
                return XCTFail("Expected invalid size rejection, got \(error)")
            }
        }
        let stored = try env.writer.read { db in
            try String.fetchOne(db, sql: "SELECT summary FROM sessions WHERE id = 'one'")
        }
        XCTAssertNil(stored)
    }

    func testGenerationReadsUseHardenedReadOnlyPool() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("EngramService/Core/EngramServiceCommandHandler+WebGeneration.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(source.contains("EngramDatabaseWriter(path:"))
        XCTAssertTrue(source.contains("readOnlyPool(path: databasePath)"))
        XCTAssertTrue(source.contains("databasePath: writerGate.databasePath"))
        XCTAssertTrue(source.contains("tier == \"lite\" || messageCount < 2"))
    }

    func testHandlerRejectsUnknownKeysBeforeGeneration() async throws {
        let env = try prepared()
        defer { env.tearDown() }
        let handler = EngramServiceCommandHandler(writerGate: env.gate)
        let unknown = await handler.handle(EngramServiceRequestEnvelope(
            requestId: requestID,
            command: "webGenerateSummary",
            payload: try JSONSerialization.data(withJSONObject: [
                "sessionId": "one",
                "generation": String(repeating: "ab", count: 32),
                "prompt": "extra",
            ])
        ))
        guard case .failure(_, let error) = unknown else {
            return XCTFail("Unknown keys must not reach generation")
        }
        XCTAssertEqual(error.name, "InvalidRequest")
    }

    private static let config = EngramServiceCommandHandler.ServiceAISettings.ChatConfig(
        provider: "openai",
        baseURL: "http://127.0.0.1",
        apiKey: "test",
        model: "test-model",
        maxTokens: 200,
        temperature: 0.3
    )

    private struct Env {
        let fixture: MetadataSQLFixture
        let writer: EngramDatabaseWriter
        let gate: ServiceWriterGate
        let settingsURL: URL
        func tearDown() { fixture.remove() }
    }

    private func prepared() throws -> Env {
        let fixture = try MetadataSQLFixture()
        try fixture.migrate()
        try fixture.seedRegistry()
        let settingsURL = fixture.directory.appendingPathComponent("settings.json")
        let document: [String: Any] = [
            "runtimeRole": "index",
            "disabledSources": EngramServiceWebSourceSettingsValidation.knownKeys.filter { $0 != "claude-code" }.sorted(),
            ArchivedDefaultOffSources.settingsMigrationKey: true,
            "captureIngest": [
                "enabled": true, "serverID": "hq", "baseURL": "http://127.0.0.1",
                "credentialID": "hq", "requestTimeout": 0.2, "retryCount": 0,
            ],
        ]
        try JSONSerialization.data(withJSONObject: document).write(to: settingsURL)
        XCTAssertEqual(chmod(settingsURL.path, 0o600), 0)
        let runtime = fixture.directory.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(
            at: runtime, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        return Env(
            fixture: fixture,
            writer: try EngramDatabaseWriter(path: fixture.path),
            gate: try ServiceWriterGate(databasePath: fixture.path, runtimeDirectory: runtime),
            settingsURL: settingsURL
        )
    }

    private func readyGeneration(_ env: Env, id: String) throws -> String {
        try XCTUnwrap(env.writer.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT last_ready_generation_id FROM capture_ingest_identity_bindings WHERE stored_session_id = ?",
                arguments: [id]
            )
        })
    }
}

private struct StubTranscriptProvider: ServiceWebTranscriptSnapshotProviding {
    let sessionId: String
    let generation: String
    var supportsNormalizedTranscripts: Bool { true }

    func snapshot(
        sessionID: String,
        generation: String,
        deadline: ContinuousClock.Instant
    ) async throws -> ServiceTranscriptContinuation.Snapshot? {
        guard sessionID.utf8.elementsEqual(sessionId.utf8),
              generation.utf8.elementsEqual(self.generation.utf8) else {
            return nil
        }
        return ServiceTranscriptContinuation.Snapshot(
            sessionId: sessionID,
            generation: generation,
            messages: [
                NormalizedMessage(role: .user, content: "Explain the constellation capture path."),
                NormalizedMessage(role: .assistant, content: "The constellation travels from exact capture through central indexing."),
            ]
        )
    }
}

private struct AnyReadyTranscriptProvider: ServiceWebTranscriptSnapshotProviding {
    var supportsNormalizedTranscripts: Bool { true }

    func snapshot(
        sessionID: String,
        generation: String,
        deadline: ContinuousClock.Instant
    ) async throws -> ServiceTranscriptContinuation.Snapshot? {
        try await StubTranscriptProvider(sessionId: sessionID, generation: generation)
            .snapshot(sessionID: sessionID, generation: generation, deadline: deadline)
    }
}

private final class GenerationHold: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func park() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if released {
                lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func go() {
        lock.lock()
        released = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}
