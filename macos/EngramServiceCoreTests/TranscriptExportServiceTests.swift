import XCTest
@testable import EngramServiceCore
import EngramCoreRead
import EngramCoreWrite
import GRDB
import Darwin

final class TranscriptExportServiceTests: XCTestCase {
    func testArchiveReadSessionPageWireRoundTripsAndRejectsUnsupportedRoles() throws {
        let request = try EngramServiceArchiveReadSessionPageRequest(
            sessionId: "session-1",
            page: 2,
            pageSize: 50,
            roles: ["user", "assistant"]
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                EngramServiceArchiveReadSessionPageRequest.self,
                from: JSONEncoder().encode(request)
            ),
            request
        )

        let response = try EngramServiceArchiveReadSessionPageResponse(
            messages: [
                EngramServiceArchiveTranscriptMessage(
                    role: "user",
                    content: "hello",
                    timestamp: "2026-07-12T00:00:00Z"
                ),
            ],
            totalPages: 3,
            currentPage: 2,
            totalKnownComplete: true,
            truncatedAt: nil,
            responseBudgetTruncated: false
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                EngramServiceArchiveReadSessionPageResponse.self,
                from: JSONEncoder().encode(response)
            ),
            response
        )

        let invalidPayloads = [
            #"{"sessionId":"session-1","page":1,"pageSize":50,"roles":["tool"]}"#,
            #"{"sessionId":"session-1","page":0,"pageSize":50}"#,
            #"{"sessionId":"session-1","page":1,"pageSize":501}"#,
            #"{"sessionId":"session-1","page":1,"pageSize":50,"roles":[]}"#,
            #"{"sessionId":"session-1","page":1,"pageSize":50,"roles":["user","user"]}"#,
            "{\"sessionId\":\"bad\\u0000id\",\"page\":1,\"pageSize\":50}",
            "{\"sessionId\":\"\(String(repeating: "s", count: 513))\",\"page\":1,\"pageSize\":50}",
        ]
        for invalid in invalidPayloads {
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    EngramServiceArchiveReadSessionPageRequest.self,
                    from: Data(invalid.utf8)
                ),
                invalid
            )
        }
    }

    func testArchiveReadSessionPageClientUsesBoundedReadOnlyCommand() async throws {
        let expected = try EngramServiceArchiveReadSessionPageResponse(
            messages: [
                EngramServiceArchiveTranscriptMessage(
                    role: "assistant",
                    content: "answer",
                    timestamp: nil
                ),
            ],
            totalPages: 1,
            currentPage: 1,
            totalKnownComplete: true,
            truncatedAt: nil,
            responseBudgetTruncated: false
        )
        let transport = ArchivePageRecordingTransport { request in
            .success(
                requestId: request.requestId,
                result: try JSONEncoder().encode(expected)
            )
        }
        let client = EngramServiceClient(transport: transport)
        let page = try await client.archiveReadSessionPage(
            EngramServiceArchiveReadSessionPageRequest(
                sessionId: "session-1",
                page: 1,
                pageSize: 50,
                roles: ["assistant"]
            )
        )

        XCTAssertEqual(page, expected)
        let request = try XCTUnwrap(transport.requestsSnapshot().only)
        XCTAssertEqual(request.command, "archiveReadSessionPage")
        XCTAssertNil(request.capabilityToken)
        let payload = try XCTUnwrap(request.payload)
        XCTAssertEqual(
            try JSONDecoder().decode(
                EngramServiceArchiveReadSessionPageRequest.self,
                from: payload
            ).roles,
            ["assistant"]
        )
    }

    func testArchiveReadSessionPageHandlerUsesResolverAndBoundsActualOuterFrame() async throws {
        let harness = try await makeArchivePageHarness(name: "live-frame")
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let transcript = harness.root.appendingPathComponent("session.jsonl")
        let hugeEscapable = String(repeating: "\"\\🙂\n", count: 45_000)
        try writeCodexTranscript(
            [
                ("user", hugeEscapable),
                ("assistant", "second"),
                ("user", "third"),
            ],
            to: transcript
        )
        try await insertArchivePageSession(
            gate: harness.gate,
            id: "session-live",
            source: "codex",
            filePath: transcript.path,
            messageCount: 3
        )
        let archiveRoot = harness.root.appendingPathComponent("archive", isDirectory: true)
        let cas = try ImmutableArchiveCAS(root: archiveRoot)
        let catalog = try ArchiveCatalog(
            root: archiveRoot,
            machineID: "11111111-1111-4111-8111-111111111111"
        )
        try catalog.migrate()
        let replayParent = harness.root.appendingPathComponent("replay", isDirectory: true)
        try FileManager.default.createDirectory(
            at: replayParent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let resolver = try ArchiveTranscriptResolver(
            catalog: catalog,
            cas: cas,
            temporaryParent: replayParent
        )
        let handler = EngramServiceCommandHandler(
            writerGate: harness.gate,
            archiveTranscriptResolver: resolver
        )
        let request = EngramServiceRequestEnvelope(
            requestId: "archive-page-frame",
            command: "archiveReadSessionPage",
            payload: try JSONEncoder().encode(
                EngramServiceArchiveReadSessionPageRequest(
                    sessionId: "session-live",
                    page: 1,
                    pageSize: 50,
                    roles: nil
                )
            )
        )

        let envelope = await handler.handle(request)
        let resultData = try archivePageSuccessData(envelope)
        let page = try JSONDecoder().decode(
            EngramServiceArchiveReadSessionPageResponse.self,
            from: resultData
        )

        XCTAssertEqual(page.messages.map(\.role), ["user", "assistant", "user"])
        XCTAssertEqual(page.messages.count, 3, "budgeting must retain page cardinality")
        XCTAssertEqual(page.totalPages, 1)
        XCTAssertEqual(page.currentPage, 1)
        XCTAssertTrue(page.responseBudgetTruncated)
        XCTAssertLessThanOrEqual(resultData.count, 160 * 1024)
        XCTAssertLessThan(
            try JSONEncoder().encode(envelope).count,
            UnixSocketEngramServiceTransport.maximumFrameLength
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: resultData) as? [String: Any]
        )
        XCTAssertEqual(
            Set(object.keys),
            Set([
                "messages",
                "totalPages",
                "currentPage",
                "totalKnownComplete",
                "responseBudgetTruncated",
            ])
        )
        for forbidden in ["path", "digest", "manifest", "receipt", "archiveBytes"] {
            XCTAssertNil(object[forbidden])
        }
    }

    func testArchiveCoordinatorResolverSnapshotIsEnabledOnlyAndDefaultOffHasNoStorageEffects() async throws {
        let harness = try await makeArchivePageHarness(name: "composition")
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let archiveRoot = harness.root.appendingPathComponent("archive-v2", isDirectory: true)
        let disabled = ArchiveV2ServiceCoordinator.make(
            settings: ArchiveV2Settings(
                exactArchiveEnabled: false,
                remoteConfiguration: nil,
                configurationError: nil
            ),
            databasePath: harness.root.appendingPathComponent("index.sqlite").path,
            writerGate: harness.gate
        )

        XCTAssertNil(disabled.transcriptResolverSnapshot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveRoot.path))

        let enabled = ArchiveV2ServiceCoordinator.make(
            settings: ArchiveV2Settings(
                exactArchiveEnabled: true,
                remoteConfiguration: nil,
                configurationError: nil
            ),
            databasePath: harness.root.appendingPathComponent("index.sqlite").path,
            writerGate: harness.gate
        )

        XCTAssertNotNil(enabled.transcriptResolverSnapshot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveRoot.path))
    }

    func testExportSessionFallsBackToSameLocalArchiveResolver() async throws {
        let harness = try await makeArchivePageHarness(name: "export-local")
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let missingLive = harness.root.appendingPathComponent("missing-session.jsonl")
        try await insertArchivePageSession(
            gate: harness.gate,
            id: "session-export-local",
            source: "codex",
            filePath: missingLive.path,
            messageCount: 1
        )
        let archiveRoot = harness.root.appendingPathComponent("archive", isDirectory: true)
        let cas = try ImmutableArchiveCAS(root: archiveRoot)
        let catalog = try ArchiveCatalog(
            root: archiveRoot,
            machineID: "11111111-1111-4111-8111-111111111111"
        )
        try catalog.migrate()
        let raw = try codexTranscriptData([("user", "archived export body")])
        try addLocalArchiveFixture(
            catalog: catalog,
            cas: cas,
            sessionID: "session-export-local",
            raw: raw,
            seed: "export-local"
        )
        let replayParent = harness.root.appendingPathComponent("replay-export", isDirectory: true)
        try FileManager.default.createDirectory(
            at: replayParent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let resolver = try ArchiveTranscriptResolver(
            catalog: catalog,
            cas: cas,
            temporaryParent: replayParent
        )
        let previousHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", harness.root.path, 1)
        defer {
            if let previousHome {
                setenv("HOME", previousHome, 1)
            } else {
                unsetenv("HOME")
            }
        }

        let result = try await TranscriptExportService.exportSession(
            EngramServiceExportSessionRequest(
                id: "session-export-local",
                format: "markdown",
                outputHome: harness.root.path,
                actor: "test"
            ),
            databasePath: harness.gate.databasePath,
            archiveTranscriptResolver: resolver
        )

        XCTAssertEqual(result.messageCount, 1)
        let body = try String(contentsOfFile: result.outputPath, encoding: .utf8)
        XCTAssertTrue(body.contains("archived export body"), body)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingLive.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: replayParent.path), [])
    }

    func testArchivePageAndExportUseLockedManifestSourceInsteadOfStaleSessionSource() async throws {
        let harness = try await makeArchivePageHarness(name: "manifest-source")
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let missingLive = harness.root.appendingPathComponent("missing-manifest-source.jsonl")
        try await insertArchivePageSession(
            gate: harness.gate,
            id: "session-manifest-source",
            source: "claude-code",
            filePath: missingLive.path,
            messageCount: 1
        )
        let archiveRoot = harness.root.appendingPathComponent("archive", isDirectory: true)
        let cas = try ImmutableArchiveCAS(root: archiveRoot)
        let catalog = try ArchiveCatalog(
            root: archiveRoot,
            machineID: "11111111-1111-4111-8111-111111111111"
        )
        try catalog.migrate()
        try addLocalArchiveFixture(
            catalog: catalog,
            cas: cas,
            sessionID: "session-manifest-source",
            source: "codex",
            raw: try codexTranscriptData([("user", "manifest source wins")]),
            seed: "manifest-source"
        )
        let replayParent = harness.root.appendingPathComponent("replay-manifest-source", isDirectory: true)
        try FileManager.default.createDirectory(
            at: replayParent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let resolver = try ArchiveTranscriptResolver(
            catalog: catalog,
            cas: cas,
            temporaryParent: replayParent
        )
        let handler = EngramServiceCommandHandler(
            writerGate: harness.gate,
            archiveTranscriptResolver: resolver
        )
        let pageEnvelope = await handler.handle(
            EngramServiceRequestEnvelope(
                requestId: "manifest-source-page",
                command: "archiveReadSessionPage",
                payload: try JSONEncoder().encode(
                    EngramServiceArchiveReadSessionPageRequest(
                        sessionId: "session-manifest-source",
                        page: 1,
                        pageSize: 50,
                        roles: nil
                    )
                )
            )
        )
        let page = try JSONDecoder().decode(
            EngramServiceArchiveReadSessionPageResponse.self,
            from: archivePageSuccessData(pageEnvelope)
        )

        let previousHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", harness.root.path, 1)
        defer {
            if let previousHome {
                setenv("HOME", previousHome, 1)
            } else {
                unsetenv("HOME")
            }
        }
        let exported = try await TranscriptExportService.exportSession(
            EngramServiceExportSessionRequest(
                id: "session-manifest-source",
                format: "markdown",
                outputHome: harness.root.path,
                actor: "test"
            ),
            databasePath: harness.gate.databasePath,
            archiveTranscriptResolver: resolver
        )
        let body = try String(contentsOfFile: exported.outputPath, encoding: .utf8)

        XCTAssertEqual(page.messages.map(\.content), ["manifest source wins"])
        XCTAssertEqual(exported.messageCount, 1)
        XCTAssertTrue(body.contains("manifest source wins"), body)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingLive.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: replayParent.path), [])
    }

    func testArchiveTranscriptReaderStopsOnAuthoritativeAdapterFailureWithoutFallback() async throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("engram-archive-strict-reader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let malformed = root.appendingPathComponent("malformed.json")
        try Data(#"{"messages":["#.utf8).write(to: malformed)

        do {
            _ = try await ServiceTranscriptReader.readArchiveMessagesWithMetadata(
                filePath: malformed.path,
                source: "gemini-cli"
            )
            XCTFail("expected the authoritative adapter failure to be terminal")
        } catch {
            XCTAssertFalse(error is TranscriptSizeGuardError)
        }
    }

    func testArchiveTranscriptTooLargeMapperStabilizesParserAndSizeGuardFailures() {
        assertTranscriptTooLarge(
            ArchiveTranscriptServiceErrorMapper.serviceError(
                for: ParserFailure.fileTooLarge
            )
        )
        assertTranscriptTooLarge(
            ArchiveTranscriptServiceErrorMapper.serviceError(
                for: TranscriptSizeGuardError.fileTooLarge(
                    source: "gemini-cli",
                    sizeBytes: 2,
                    maxBytes: 1
                )
            )
        )
        guard case .commandFailed(let name, _, let retryPolicy, _) =
            ArchiveTranscriptServiceErrorMapper.serviceError(for: ParserFailure.malformedJSON)
        else {
            return XCTFail("expected terminal archive parser failure")
        }
        XCTAssertEqual(name, "archiveParseFailed")
        XCTAssertEqual(retryPolicy, "never")
    }

    func testDefaultOffDirectParserFailureKeepsLegacyGenericErrorSemantics() async throws {
        let harness = try await makeArchivePageHarness(name: "default-off-parser-failure")
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let invalidTranscript = harness.root.appendingPathComponent("invalid-utf8.jsonl")
        try Data([0xFF, 0x0A]).write(to: invalidTranscript)
        try await insertArchivePageSession(
            gate: harness.gate,
            id: "session-default-off-invalid-utf8",
            source: "codex",
            filePath: invalidTranscript.path,
            messageCount: 1
        )
        let exportRequest = EngramServiceExportSessionRequest(
            id: "session-default-off-invalid-utf8",
            format: "markdown",
            outputHome: harness.root.path,
            actor: "test"
        )

        do {
            _ = try await TranscriptExportService.exportSession(
                exportRequest,
                databasePath: harness.gate.databasePath,
                archiveTranscriptResolver: nil
            )
            XCTFail("expected direct parser failure")
        } catch let failure as ParserFailure {
            XCTAssertEqual(failure, .invalidUtf8)
        }

        let handler = EngramServiceCommandHandler(writerGate: harness.gate)
        let envelope = await handler.handle(
            EngramServiceRequestEnvelope(
                requestId: "default-off-invalid-utf8",
                command: "exportSession",
                payload: try JSONEncoder().encode(exportRequest)
            )
        )
        guard case .failure(_, let error) = envelope else {
            return XCTFail("expected generic service failure")
        }
        XCTAssertEqual(error.name, "CommandFailed")
        XCTAssertEqual(error.retryPolicy, "safe")
        XCTAssertNotEqual(error.name, "archiveParseFailed")
    }

    func testArchivePageAndExportNormalizeUnknownAuthoritativeParserErrors() async throws {
        let harness = try await makeArchivePageHarness(name: "unknown-authoritative-source")
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let missingLive = harness.root.appendingPathComponent("missing-unknown-source.jsonl")
        try await insertArchivePageSession(
            gate: harness.gate,
            id: "session-unknown-source",
            source: "codex",
            filePath: missingLive.path,
            messageCount: 1
        )
        let archiveRoot = harness.root.appendingPathComponent("archive", isDirectory: true)
        let cas = try ImmutableArchiveCAS(root: archiveRoot)
        let catalog = try ArchiveCatalog(
            root: archiveRoot,
            machineID: "11111111-1111-4111-8111-111111111111"
        )
        try catalog.migrate()
        try addLocalArchiveFixture(
            catalog: catalog,
            cas: cas,
            sessionID: "session-unknown-source",
            source: "unknown-authoritative-source",
            raw: Data("opaque archive bytes".utf8),
            seed: "unknown-source"
        )
        let replayParent = harness.root.appendingPathComponent("replay-unknown-source", isDirectory: true)
        try FileManager.default.createDirectory(
            at: replayParent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let resolver = try ArchiveTranscriptResolver(
            catalog: catalog,
            cas: cas,
            temporaryParent: replayParent
        )
        let handler = EngramServiceCommandHandler(
            writerGate: harness.gate,
            archiveTranscriptResolver: resolver
        )

        let pageEnvelope = await handler.handle(
            EngramServiceRequestEnvelope(
                requestId: "unknown-source-page",
                command: "archiveReadSessionPage",
                payload: try JSONEncoder().encode(
                    EngramServiceArchiveReadSessionPageRequest(
                        sessionId: "session-unknown-source",
                        page: 1,
                        pageSize: 50,
                        roles: nil
                    )
                )
            )
        )
        guard case .failure(_, let pageError) = pageEnvelope else {
            return XCTFail("expected archive parser failure")
        }
        assertStableArchiveParseFailure(
            name: pageError.name,
            message: pageError.message,
            retryPolicy: pageError.retryPolicy,
            forbiddenPath: replayParent.path
        )

        let previousHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", harness.root.path, 1)
        defer {
            if let previousHome {
                setenv("HOME", previousHome, 1)
            } else {
                unsetenv("HOME")
            }
        }
        do {
            _ = try await TranscriptExportService.exportSession(
                EngramServiceExportSessionRequest(
                    id: "session-unknown-source",
                    format: "markdown",
                    outputHome: harness.root.path,
                    actor: "test"
                ),
                databasePath: harness.gate.databasePath,
                archiveTranscriptResolver: resolver
            )
            XCTFail("expected archive parser failure")
        } catch let error as EngramServiceError {
            guard case .commandFailed(let name, let message, let retryPolicy, _) = error else {
                return XCTFail("unexpected service error: \(error)")
            }
            assertStableArchiveParseFailure(
                name: name,
                message: message,
                retryPolicy: retryPolicy,
                forbiddenPath: replayParent.path
            )
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: replayParent.path), [])
    }

    func testArchivePageAndExportExposeStableTranscriptTooLargeServiceError() async throws {
        let harness = try await makeArchivePageHarness(name: "too-large")
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let missingLive = harness.root.appendingPathComponent("missing-too-large.jsonl")
        try await insertArchivePageSession(
            gate: harness.gate,
            id: "session-too-large",
            source: "codex",
            filePath: missingLive.path,
            messageCount: 1
        )
        let archiveRoot = harness.root.appendingPathComponent("archive", isDirectory: true)
        let cas = try ImmutableArchiveCAS(root: archiveRoot)
        let catalog = try ArchiveCatalog(
            root: archiveRoot,
            machineID: "11111111-1111-4111-8111-111111111111"
        )
        try catalog.migrate()
        let raw = try JSONSerialization.data(
            withJSONObject: [
                "sessionId": "session-too-large",
                "startTime": "2026-07-12T00:00:00Z",
                "messages": [
                    ["type": "user", "content": String(repeating: "x", count: 256)],
                ],
            ],
            options: [.sortedKeys]
        )
        try addLocalArchiveFixture(
            catalog: catalog,
            cas: cas,
            sessionID: "session-too-large",
            source: "gemini-cli",
            raw: raw,
            seed: "too-large"
        )
        let replayParent = harness.root.appendingPathComponent("replay-too-large", isDirectory: true)
        try FileManager.default.createDirectory(
            at: replayParent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let resolver = try ArchiveTranscriptResolver(
            catalog: catalog,
            cas: cas,
            temporaryParent: replayParent
        )
        let handler = EngramServiceCommandHandler(
            writerGate: harness.gate,
            archiveTranscriptResolver: resolver
        )
        let environmentKey = TranscriptSizeGuard.maxFullJSONTranscriptBytesEnvironmentKey
        let previousLimit = ProcessInfo.processInfo.environment[environmentKey]
        setenv(environmentKey, "32", 1)
        defer {
            if let previousLimit {
                setenv(environmentKey, previousLimit, 1)
            } else {
                unsetenv(environmentKey)
            }
        }

        let pageEnvelope = await handler.handle(
            EngramServiceRequestEnvelope(
                requestId: "too-large-page",
                command: "archiveReadSessionPage",
                payload: try JSONEncoder().encode(
                    EngramServiceArchiveReadSessionPageRequest(
                        sessionId: "session-too-large",
                        page: 1,
                        pageSize: 50,
                        roles: nil
                    )
                )
            )
        )
        guard case .failure(_, let pageError) = pageEnvelope else {
            return XCTFail("expected transcriptTooLarge page failure")
        }
        XCTAssertEqual(pageError.name, "transcriptTooLarge")
        XCTAssertEqual(pageError.retryPolicy, "never")
        XCTAssertEqual(pageError.details?["code"], .string("transcriptTooLarge"))

        do {
            _ = try await TranscriptExportService.exportSession(
                EngramServiceExportSessionRequest(
                    id: "session-too-large",
                    format: "markdown",
                    outputHome: harness.root.path,
                    actor: "test"
                ),
                databasePath: harness.gate.databasePath,
                archiveTranscriptResolver: resolver
            )
            XCTFail("expected transcriptTooLarge export failure")
        } catch let error as EngramServiceError {
            assertTranscriptTooLarge(error)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: replayParent.path), [])
    }

    func testExportSessionMapsMissingArchiveToStableBoundedServiceError() async throws {
        let harness = try await makeArchivePageHarness(name: "export-unavailable")
        defer { try? FileManager.default.removeItem(at: harness.root) }
        try await insertArchivePageSession(
            gate: harness.gate,
            id: "session-export-unavailable",
            source: "codex",
            filePath: harness.root.appendingPathComponent("missing.jsonl").path,
            messageCount: 1
        )
        let archiveRoot = harness.root.appendingPathComponent("archive", isDirectory: true)
        let cas = try ImmutableArchiveCAS(root: archiveRoot)
        let catalog = try ArchiveCatalog(
            root: archiveRoot,
            machineID: "11111111-1111-4111-8111-111111111111"
        )
        try catalog.migrate()
        let replayParent = harness.root.appendingPathComponent("replay", isDirectory: true)
        try FileManager.default.createDirectory(
            at: replayParent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let resolver = try ArchiveTranscriptResolver(
            catalog: catalog,
            cas: cas,
            temporaryParent: replayParent
        )

        do {
            _ = try await TranscriptExportService.exportSession(
                EngramServiceExportSessionRequest(
                    id: "session-export-unavailable",
                    format: "markdown",
                    outputHome: harness.root.path,
                    actor: "test"
                ),
                databasePath: harness.gate.databasePath,
                archiveTranscriptResolver: resolver
            )
            XCTFail("expected stable archiveUnavailable error")
        } catch let error as EngramServiceError {
            guard case .commandFailed(let name, let message, let retryPolicy, _) = error else {
                return XCTFail("unexpected service error: \(error)")
            }
            XCTAssertEqual(name, "archiveUnavailable")
            XCTAssertEqual(retryPolicy, "safe")
            XCTAssertEqual(message, "No verified transcript source is currently available")
            XCTAssertFalse(message.contains(harness.root.path))
        }
    }

    func testArchiveReadSessionPageRealSocketClientReadsLocalArchiveAndFiltersRoles() async throws {
        let harness = try await makeArchivePageHarness(name: "socket-local")
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let missingLive = harness.root.appendingPathComponent("missing-local.jsonl")
        try await insertArchivePageSession(
            gate: harness.gate,
            id: "session-socket-local",
            source: "codex",
            filePath: missingLive.path,
            messageCount: 3
        )
        let archiveRoot = harness.root.appendingPathComponent("archive", isDirectory: true)
        let cas = try ImmutableArchiveCAS(root: archiveRoot)
        let catalog = try ArchiveCatalog(
            root: archiveRoot,
            machineID: "11111111-1111-4111-8111-111111111111"
        )
        try catalog.migrate()
        try addLocalArchiveFixture(
            catalog: catalog,
            cas: cas,
            sessionID: "session-socket-local",
            raw: try codexTranscriptData([
                ("user", "first"),
                ("assistant", "second"),
                ("user", "third"),
            ]),
            seed: "socket-local"
        )
        let replayParent = harness.root.appendingPathComponent("replay", isDirectory: true)
        try FileManager.default.createDirectory(
            at: replayParent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let resolver = try ArchiveTranscriptResolver(
            catalog: catalog,
            cas: cas,
            temporaryParent: replayParent
        )
        let handler = EngramServiceCommandHandler(
            writerGate: harness.gate,
            archiveTranscriptResolver: resolver
        )
        let socket = harness.root
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent("archive-page.sock")
        let server = UnixSocketServiceServer(socketPath: socket.path) { request in
            await handler.handle(request)
        }
        try server.start()
        defer { server.stop() }
        let client = EngramServiceClient(
            transport: UnixSocketEngramServiceTransport(socketPath: socket.path)
        )
        defer { client.close() }

        let page = try await client.archiveReadSessionPage(
            EngramServiceArchiveReadSessionPageRequest(
                sessionId: "session-socket-local",
                page: 1,
                pageSize: 2,
                roles: ["assistant"]
            )
        )

        XCTAssertFalse(ServiceCapabilityToken.requiresToken("archiveReadSessionPage"))
        XCTAssertEqual(page.messages.map(\.role), ["assistant"])
        XCTAssertEqual(page.messages.map(\.content), ["second"])
        XCTAssertEqual(page.totalPages, 1)
        XCTAssertEqual(page.currentPage, 1)
        XCTAssertTrue(page.totalKnownComplete)
        XCTAssertNil(page.truncatedAt)
        XCTAssertFalse(page.responseBudgetTruncated)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: replayParent.path), [])
    }

    func testArchiveReadSessionPageHandlerRejectsMalformedWirePayload() async throws {
        let harness = try await makeArchivePageHarness(name: "invalid-payload")
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let handler = EngramServiceCommandHandler(writerGate: harness.gate)

        let response = await handler.handle(
            EngramServiceRequestEnvelope(
                command: "archiveReadSessionPage",
                payload: Data(
                    #"{"sessionId":"session-1","page":1,"pageSize":50,"roles":["tool"]}"#.utf8
                )
            )
        )

        guard case .failure(_, let error) = response else {
            return XCTFail("expected InvalidRequest failure")
        }
        XCTAssertEqual(error.name, "InvalidRequest")
        XCTAssertEqual(error.retryPolicy, "never")
        XCTAssertFalse(error.message.contains("tool"))
    }

    func testRedactionCoversCommonTokenFamilies() {
        let input = """
        sk-abcdefghij0123456789
        ghp_1234567890abcdefghij
        xoxb-1234567890-abcdefghij
        github_pat_1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZ
        AKIA1234567890ABCDEF
        npm_1234567890abcdef
        xoxe-1234567890-abcdef
        -----BEGIN PRIVATE KEY-----
        secret
        -----END PRIVATE KEY-----
        """
        let redacted = TranscriptExportService.redactSensitiveContent(input)
        let shared = TranscriptRedactionPolicy.redact(input)

        XCTAssertEqual(redacted, shared, "export facade must match shared transcript redaction policy")
        XCTAssertFalse(redacted.contains("sk-abcdefghij0123456789"))
        XCTAssertFalse(redacted.contains("ghp_1234567890abcdefghij"))
        XCTAssertFalse(redacted.contains("xoxb-1234567890-abcdefghij"))
        XCTAssertFalse(redacted.contains("github_pat_1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZ"))
        XCTAssertFalse(redacted.contains("AKIA1234567890ABCDEF"))
        XCTAssertFalse(redacted.contains("npm_1234567890abcdef"))
        XCTAssertFalse(redacted.contains("xoxe-1234567890-abcdef"))
        XCTAssertFalse(redacted.contains("BEGIN PRIVATE KEY"))
        XCTAssertTrue(redacted.contains("[REDACTED]"))
    }

    func testRedactionStaticPatternsProduceByteIdenticalOutput() {
        let samples = [
            "api_key: ABCDEF0123456789 tail",
            "Authorization: Bearer ABCDEF0123456789",
            "token=sk-abcdefghij0123456789 done",
            "sk-abcdefghij0123456789 and ghp_1234567890abcdefghij and xoxb-1234567890-abcdefghij",
            "github_pat_1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZ here",
            "AKIA1234567890ABCDEF and npm_1234567890abcdef and xoxe-1234567890-abcdef",
            "-----BEGIN PRIVATE KEY-----\nsecret\n-----END PRIVATE KEY-----",
            "no secrets here, just prose about tokens and passwords in general",
        ]
        let expected = [
            "[REDACTED] tail",
            "[REDACTED]",
            "[REDACTED] done",
            "[REDACTED] and [REDACTED] and [REDACTED]",
            "[REDACTED] here",
            "[REDACTED] and [REDACTED] and [REDACTED]",
            "[REDACTED]",
            "no secrets here, just prose about tokens and passwords in general",
        ]
        for (input, want) in zip(samples, expected) {
            let first = TranscriptExportService.redactSensitiveContent(input)
            XCTAssertEqual(first, want, "redaction output changed for: \(input)")
            XCTAssertEqual(TranscriptExportService.redactSensitiveContent(input), first)
        }
    }
}

private struct ArchivePageHarness {
    let root: URL
    let gate: ServiceWriterGate
}

private enum ArchivePageTestError: Error {
    case expectedSuccess
}

private func assertTranscriptTooLarge(
    _ error: EngramServiceError,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case .commandFailed(let name, _, let retryPolicy, let details) = error else {
        return XCTFail("expected commandFailed, got \(error)", file: file, line: line)
    }
    XCTAssertEqual(name, "transcriptTooLarge", file: file, line: line)
    XCTAssertEqual(retryPolicy, "never", file: file, line: line)
    XCTAssertEqual(details?["code"], .string("transcriptTooLarge"), file: file, line: line)
}

private func assertStableArchiveParseFailure(
    name: String,
    message: String,
    retryPolicy: String,
    forbiddenPath: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(name, "archiveParseFailed", file: file, line: line)
    XCTAssertEqual(
        message,
        "The authoritative archive transcript parser rejected the selected bytes",
        file: file,
        line: line
    )
    XCTAssertEqual(retryPolicy, "never", file: file, line: line)
    XCTAssertFalse(message.contains(forbiddenPath), file: file, line: line)
    XCTAssertFalse(message.contains(".engram-transcript-"), file: file, line: line)
}

private func makeArchivePageHarness(name: String) async throws -> ArchivePageHarness {
    let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent("engram-archive-page-\(name)-\(UUID().uuidString)", isDirectory: true)
    let runtime = root.appendingPathComponent("runtime", isDirectory: true)
    try FileManager.default.createDirectory(
        at: runtime,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    let database = root.appendingPathComponent("index.sqlite")
    let gate = try ServiceWriterGate(databasePath: database.path, runtimeDirectory: runtime)
    _ = try await gate.performWriteCommand(name: "test.migrate") { writer in
        try writer.migrate()
    }
    return ArchivePageHarness(root: root, gate: gate)
}

private func insertArchivePageSession(
    gate: ServiceWriterGate,
    id: String,
    source: String,
    filePath: String,
    messageCount: Int
) async throws {
    _ = try await gate.performWriteCommand(name: "test.seed.archivePage") { writer in
        try writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO sessions (
                      id, source, start_time, cwd, message_count,
                      user_message_count, assistant_message_count, file_path, size_bytes, indexed_at
                    ) VALUES (?, ?, '2026-07-12T00:00:00Z', '/tmp/project', ?, ?, 0, ?, 0,
                              '2026-07-12T00:00:00Z')
                    """,
                arguments: [id, source, messageCount, messageCount, filePath]
            )
        }
    }
}

private func writeCodexTranscript(_ messages: [(String, String)], to url: URL) throws {
    try codexTranscriptData(messages).write(to: url)
}

private func codexTranscriptData(_ messages: [(String, String)]) throws -> Data {
    let lines = try messages.map { role, content -> String in
        let object: [String: Any] = [
            "timestamp": "2026-07-12T00:00:00Z",
            "type": "response_item",
            "payload": [
                "type": "message",
                "role": role,
                "content": [["type": "text", "text": content]],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }
    return Data(lines.joined(separator: "\n").utf8)
}

private func addLocalArchiveFixture(
    catalog: ArchiveCatalog,
    cas: ImmutableArchiveCAS,
    sessionID: String,
    source: String = "codex",
    raw: Data,
    seed: String
) throws {
    let digest = ArchiveV2Hash.sha256(raw)
    _ = try cas.publishObject(raw: raw, expectedSHA256: digest)
    let captureID = ArchiveV2Hash.sha256(Data("capture-\(seed)".utf8))
    let generation = try ArchiveSourceGeneration(
        device: 1,
        inode: 2,
        size: Int64(raw.count),
        mtimeNs: 3,
        ctimeNs: 4,
        mode: Int64(S_IFREG | 0o600)
    )
    let chunk = try ArchiveChunkReference(
        ordinal: 0,
        rawSHA256: digest,
        rawByteCount: Int64(raw.count)
    )
    let replay = try ArchiveReplayLayout(
        strategy: .singleFile,
        relativePaths: ["sessions/\(seed).jsonl"]
    )
    let unbound = try ArchiveSourceManifest(
        captureID: captureID,
        machineID: "11111111-1111-4111-8111-111111111111",
        source: source,
        locator: "/audit/\(seed).jsonl",
        sessionID: nil,
        capturedAt: "2026-07-12T00:00:00.000Z",
        generation: generation,
        wholeSourceSHA256: digest,
        rawByteCount: Int64(raw.count),
        chunks: [chunk],
        replayLayout: replay
    )
    _ = try catalog.recordCapture(
        canonicalManifestBytes: ArchiveCanonicalJSON.encode(unbound)
    )
    let bound = try ArchiveSourceManifest(
        captureID: captureID,
        machineID: "11111111-1111-4111-8111-111111111111",
        source: source,
        locator: "/audit/\(seed).jsonl",
        sessionID: sessionID,
        capturedAt: "2026-07-12T00:00:00.000Z",
        generation: generation,
        wholeSourceSHA256: digest,
        rawByteCount: Int64(raw.count),
        chunks: [chunk],
        replayLayout: replay
    )
    let boundBytes = try ArchiveCanonicalJSON.encode(bound)
    _ = try cas.publishManifest(
        boundBytes,
        expectedSHA256: ArchiveV2Hash.sha256(boundBytes)
    )
    _ = try catalog.bind(
        canonicalManifestBytes: boundBytes,
        sourceSnapshotFingerprint: ArchiveV2Hash.sha256(Data("snapshot-\(seed)".utf8)),
        boundAt: "2026-07-12T00:00:01.000Z"
    )
}

private func archivePageSuccessData(_ response: EngramServiceResponseEnvelope) throws -> Data {
    guard case .success(_, let data, _) = response else {
        XCTFail("expected archive page success, got \(response)")
        throw ArchivePageTestError.expectedSuccess
    }
    return data
}

private final class ArchivePageRecordingTransport: EngramServiceTransport, @unchecked Sendable {
    typealias Responder = @Sendable (
        EngramServiceRequestEnvelope
    ) throws -> EngramServiceResponseEnvelope

    private let lock = NSLock()
    private var requests: [EngramServiceRequestEnvelope] = []
    private let responder: Responder

    init(responder: @escaping Responder) {
        self.responder = responder
    }

    func send(
        _ request: EngramServiceRequestEnvelope,
        timeout _: TimeInterval?
    ) async throws -> EngramServiceResponseEnvelope {
        lock.lock()
        requests.append(request)
        lock.unlock()
        return try responder(request)
    }

    func events() -> AsyncThrowingStream<EngramServiceEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func close() {}

    func requestsSnapshot() -> [EngramServiceRequestEnvelope] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
