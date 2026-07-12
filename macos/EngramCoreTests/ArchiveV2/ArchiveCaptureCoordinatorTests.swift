import Darwin
import Foundation
import GRDB
import XCTest
@testable import EngramCoreRead
@testable import EngramCoreWrite

final class ArchiveCaptureCoordinatorTests: XCTestCase {
    private let machineID = "11111111-2222-3333-4444-555555555555"
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-capture-coordinator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    func testCaptureCompletesBeforeParseMarkerAndParserFailureLeavesUnbound() async throws {
        let sourceURL = root.appendingPathComponent("source/session.jsonl")
        try FileManager.default.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not parseable, but exact\n".utf8).write(to: sourceURL)
        let recorder = ArchiveEventRecorder()
        let adapter = CoordinatorExactAdapter(
            source: .claudeCode,
            locators: [sourceURL.path],
            relativePaths: [sourceURL.path: "project/session.jsonl"],
            parseResult: .failure(.malformedJSON),
            recorder: recorder
        )
        let (cas, catalog) = try makeStore(name: "order")
        let coordinator = ArchiveCaptureCoordinator(
            cas: cas,
            catalog: catalog,
            testHooks: ArchiveCaptureCoordinatorTestHooks({ _ in
                recorder.append("captured")
            })
        )

        let cycle = try await coordinator.capture(adapters: [adapter])
        let parseResult = try await adapter.parseSessionInfo(locator: sourceURL.path)

        XCTAssertEqual(cycle.captures.count, 1)
        guard case .failure(.malformedJSON) = parseResult else {
            return XCTFail("expected injected parser failure")
        }
        XCTAssertEqual(recorder.snapshot(), ["list", "descriptor", "captured", "parse"])
        XCTAssertEqual(try catalog.unboundCaptures(limit: 10).count, 1)
    }

    func testParserFailureDoesNotBindCaptureToStaleSessionIdentity() async throws {
        let sourceURL = root.appendingPathComponent("stale-session/source.jsonl")
        try FileManager.default.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("new generation that failed parsing\n".utf8).write(to: sourceURL)
        let adapter = CoordinatorExactAdapter(
            source: .claudeCode,
            locators: [sourceURL.path],
            relativePaths: [sourceURL.path: "project/source.jsonl"],
            parseResult: .failure(.malformedJSON)
        )
        let (cas, catalog) = try makeStore(name: "stale-session")
        let coordinator = ArchiveCaptureCoordinator(cas: cas, catalog: catalog)

        let captureCycle = try await coordinator.capture(adapters: [adapter])
        XCTAssertEqual(captureCycle.captures.count, 1)
        let captured = try XCTUnwrap(captureCycle.captures.first?.capture)
        guard case .failure(.malformedJSON) = try await adapter.parseSessionInfo(
            locator: sourceURL.path
        ) else {
            return XCTFail("expected parser failure")
        }
        let staleProof = try indexedProof(
            capture: captured,
            expectedCaptureID: ArchiveV2Hash.sha256(Data("old-generation".utf8))
        )
        let staleIdentity = try ArchiveSessionIdentity(
            sessionID: "stale-session-row",
            source: .claudeCode,
            locator: sourceURL.path,
            indexedGenerationProof: staleProof
        )

        let result = try await coordinator.bind([staleIdentity])

        XCTAssertTrue(result.bindings.isEmpty)
        XCTAssertEqual(result.items.map(\.disposition), [.indexedGenerationMismatch])
        XCTAssertEqual(try catalog.unboundCaptures(limit: 10).count, 1)
    }

    func testUnsupportedAndUnsafeLocatorsNeverPublishObjectsManifestsOrCaptures() async throws {
        let ordinary = root.appendingPathComponent("unsupported/ordinary.jsonl")
        let directory = root.appendingPathComponent("unsupported/directory", isDirectory: true)
        let symlink = root.appendingPathComponent("unsupported/symlink.jsonl")
        let fifo = root.appendingPathComponent("unsupported/fifo.jsonl")
        let missing = root.appendingPathComponent("unsupported/missing.jsonl")
        try FileManager.default.createDirectory(
            at: ordinary.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("ordinary".utf8).write(to: ordinary)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: ordinary)
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)

        let undeclared = CoordinatorUndeclaredAdapter(source: .kimi, locators: [ordinary.path])
        let declared = CoordinatorExactAdapter(
            source: .claudeCode,
            locators: [
                missing.path,
                directory.path,
                symlink.path,
                fifo.path,
                "\(ordinary.path)::session",
                "\(ordinary.path)?composer=id",
            ],
            relativePaths: [:]
        )
        let (cas, catalog) = try makeStore(name: "unsupported")
        let coordinator = ArchiveCaptureCoordinator(cas: cas, catalog: catalog)

        let cycle = try await coordinator.capture(adapters: [undeclared, declared])

        XCTAssertTrue(cycle.captures.isEmpty)
        XCTAssertEqual(cycle.items.count, 7)
        XCTAssertEqual(cycle.items.first?.locator, "")
        XCTAssertEqual(cycle.items.first?.classification, .unsupportedAdapter)
        XCTAssertTrue(try catalog.unboundCaptures(limit: 10).isEmpty)
        XCTAssertEqual(try archivePayloadFileCount(name: "unsupported", leaf: "objects/sha256"), 0)
        XCTAssertEqual(try archivePayloadFileCount(name: "unsupported", leaf: "manifests/sha256"), 0)
    }

    func testBindingSurvivesCoordinatorRestartAndRequiresUniqueExactSessionIdentity() async throws {
        let sourceURL = root.appendingPathComponent("bind/source.jsonl")
        try FileManager.default.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("stable generation\n".utf8).write(to: sourceURL)
        let adapter = CoordinatorExactAdapter(
            source: .claudeCode,
            locators: [sourceURL.path],
            relativePaths: [sourceURL.path: "project/source.jsonl"]
        )
        let (cas, catalog) = try makeStore(name: "restart-bind")
        var firstCoordinator: ArchiveCaptureCoordinator? = ArchiveCaptureCoordinator(
            cas: cas,
            catalog: catalog
        )
        let captureCycle = try await firstCoordinator!.capture(adapters: [adapter])
        let captured = try XCTUnwrap(captureCycle.captures.first?.capture)
        let captureID = captured.captureID
        firstCoordinator = nil

        let reopenedCatalog = try ArchiveCatalog(
            root: archiveRoot(name: "restart-bind"),
            machineID: machineID
        )
        try reopenedCatalog.migrate()
        let restartedCoordinator = ArchiveCaptureCoordinator(cas: cas, catalog: reopenedCatalog)
        let proof = try indexedProof(capture: captured)
        let identity = try ArchiveSessionIdentity(
            sessionID: "session-1",
            source: .claudeCode,
            locator: sourceURL.path,
            indexedGenerationProof: proof
        )

        let bindingCycle = try await restartedCoordinator.bind([identity])

        XCTAssertEqual(bindingCycle.bindings.count, 1)
        XCTAssertEqual(bindingCycle.bindings.first?.captureID, captureID)
        let expectedFingerprint = ArchiveV2Hash.sha256(
            try ArchiveCanonicalJSON.encode(
                ExpectedSourceSnapshotFingerprintSeed(
                    schemaVersion: 1,
                    sessionID: identity.sessionID,
                    captureID: captured.captureID,
                    wholeSourceSHA256: captured.wholeSourceSHA256,
                    indexedExpectedCaptureID: proof.expectedCaptureID,
                    indexedSource: proof.source.rawValue,
                    indexedLocator: proof.locator,
                    indexedSizeBytes: proof.sizeBytes,
                    indexedModifiedAtNanos: proof.modifiedAtNanos,
                    indexedInode: proof.inode,
                    indexedDevice: proof.device,
                    indexedParseStatus: proof.parseStatus.rawValue
                )
            )
        )
        XCTAssertEqual(bindingCycle.bindings.first?.sourceSnapshotFingerprint, expectedFingerprint)
        XCTAssertTrue(try reopenedCatalog.unboundCaptures(limit: 10).isEmpty)
        XCTAssertEqual(
            try reopenedCatalog.latestBinding(sessionID: "session-1")?.captureID,
            captureID
        )
    }

    func testBindingLeavesAppendReplaceDuplicateAndSourceMismatchUnbound() async throws {
        let append = try await capturedBindingFixture(name: "append")
        let appendFD = Darwin.open(append.sourceURL.path, O_WRONLY | O_APPEND | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(appendFD, 0)
        _ = Data("appended".utf8).withUnsafeBytes {
            Darwin.write(appendFD, $0.baseAddress, $0.count)
        }
        _ = Darwin.close(appendFD)
        let appendResult = try await append.coordinator.bind([
            try sessionIdentity(
                capture: append.capture,
                source: .claudeCode,
                locator: append.sourceURL.path,
                id: "append"
            )
        ])
        XCTAssertEqual(appendResult.items.map(\.disposition), [.generationChanged])

        let replace = try await capturedBindingFixture(name: "replace")
        let replacement = replace.sourceURL.deletingLastPathComponent()
            .appendingPathComponent("replacement.jsonl")
        try Data("replacement".utf8).write(to: replacement)
        XCTAssertEqual(rename(replacement.path, replace.sourceURL.path), 0)
        let replaceResult = try await replace.coordinator.bind([
            try sessionIdentity(
                capture: replace.capture,
                source: .claudeCode,
                locator: replace.sourceURL.path,
                id: "replace"
            )
        ])
        XCTAssertEqual(replaceResult.items.map(\.disposition), [.generationChanged])

        let duplicate = try await capturedBindingFixture(name: "duplicate")
        let duplicateResult = try await duplicate.coordinator.bind([
            try sessionIdentity(
                capture: duplicate.capture,
                source: .claudeCode,
                locator: duplicate.sourceURL.path,
                id: "one"
            ),
            try sessionIdentity(
                capture: duplicate.capture,
                source: .claudeCode,
                locator: duplicate.sourceURL.path,
                id: "two"
            ),
        ])
        XCTAssertEqual(duplicateResult.items.map(\.disposition), [.ambiguousMatch(2)])

        let mismatch = try await capturedBindingFixture(name: "source-mismatch")
        let mismatchResult = try await mismatch.coordinator.bind([
            try sessionIdentity(
                capture: mismatch.capture,
                source: .minimax,
                locator: mismatch.sourceURL.path,
                id: "derived"
            )
        ])
        XCTAssertEqual(mismatchResult.items.map(\.disposition), [.noMatch])

        XCTAssertEqual(try append.catalog.unboundCaptures(limit: 10).count, 1)
        XCTAssertEqual(try replace.catalog.unboundCaptures(limit: 10).count, 1)
        XCTAssertEqual(try duplicate.catalog.unboundCaptures(limit: 10).count, 1)
        XCTAssertEqual(try mismatch.catalog.unboundCaptures(limit: 10).count, 1)
    }

    func testBindingRejectsEveryIndexedGenerationProofMismatch() async throws {
        let fixture = try await capturedBindingFixture(name: "proof-mismatches")
        let capture = fixture.capture
        let wrongLocator = root.appendingPathComponent("other/source.jsonl").path
        let proofs = try [
            indexedProof(
                capture: capture,
                expectedCaptureID: ArchiveV2Hash.sha256(Data("wrong-capture".utf8))
            ),
            indexedProof(capture: capture, source: .codex),
            indexedProof(capture: capture, locator: wrongLocator),
            indexedProof(capture: capture, sizeBytes: capture.generation.size + 1),
            indexedProof(
                capture: capture,
                modifiedAtNanos: capture.generation.mtimeNs + 1
            ),
            indexedProof(capture: capture, inode: capture.generation.inode + 1),
            indexedProof(capture: capture, device: capture.generation.device + 1),
        ]

        for (index, proof) in proofs.enumerated() {
            let identity = try ArchiveSessionIdentity(
                sessionID: "proof-mismatch-\(index)",
                source: .claudeCode,
                locator: fixture.sourceURL.path,
                indexedGenerationProof: proof
            )
            let result = try await fixture.coordinator.bind([identity])
            XCTAssertEqual(
                result.items.map(\.disposition),
                [.indexedGenerationMismatch],
                "proof mismatch \(index)"
            )
            XCTAssertTrue(result.bindings.isEmpty, "proof mismatch \(index)")
        }
        XCTAssertEqual(try fixture.catalog.unboundCaptures(limit: 10).count, 1)
    }

    func testIndexedGenerationProofRequiresOKStatusAndDeviceInode() throws {
        let captureID = ArchiveV2Hash.sha256(Data("capture".utf8))
        let locator = root.appendingPathComponent("proof/source.jsonl").path

        XCTAssertThrowsError(
            try ArchiveIndexedGenerationProof(
                expectedCaptureID: captureID,
                source: .claudeCode,
                locator: locator,
                sizeBytes: 1,
                modifiedAtNanos: 1,
                inode: 1,
                device: 1,
                parseStatus: .terminal
            )
        ) { error in
            XCTAssertEqual(
                error as? ArchiveSessionIdentityError,
                .invalidIndexedParseStatus(FileIndexParseStatus.terminal.rawValue)
            )
        }
        XCTAssertThrowsError(
            try ArchiveIndexedGenerationProof(
                expectedCaptureID: captureID,
                source: .claudeCode,
                locator: locator,
                sizeBytes: 1,
                modifiedAtNanos: 1,
                inode: nil,
                device: 1,
                parseStatus: .ok
            )
        ) { error in
            XCTAssertEqual(error as? ArchiveSessionIdentityError, .missingIndexedInode)
        }
        XCTAssertThrowsError(
            try ArchiveIndexedGenerationProof(
                expectedCaptureID: captureID,
                source: .claudeCode,
                locator: locator,
                sizeBytes: 1,
                modifiedAtNanos: 1,
                inode: 1,
                device: nil,
                parseStatus: .ok
            )
        ) { error in
            XCTAssertEqual(error as? ArchiveSessionIdentityError, .missingIndexedDevice)
        }
    }

    func testBindingPagesPastUnbindableOldestCaptureWithoutStarvingLaterCapture() async throws {
        let firstURL = root.appendingPathComponent("paging/first.jsonl")
        let secondURL = root.appendingPathComponent("paging/second.jsonl")
        try FileManager.default.createDirectory(
            at: firstURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("first".utf8).write(to: firstURL)
        try Data("second".utf8).write(to: secondURL)
        let adapter = CoordinatorExactAdapter(
            source: .claudeCode,
            locators: [firstURL.path, secondURL.path],
            relativePaths: [
                firstURL.path: "project/first.jsonl",
                secondURL.path: "project/second.jsonl",
            ]
        )
        let (cas, catalog) = try makeStore(name: "paging")
        let captureCoordinator = ArchiveCaptureCoordinator(cas: cas, catalog: catalog)
        let captureCycle = try await captureCoordinator.capture(adapters: [adapter])
        XCTAssertEqual(captureCycle.captures.count, 2)
        let ordered = try catalog.unboundCaptures(limit: 10)
        XCTAssertEqual(ordered.count, 2)
        let blocked = try XCTUnwrap(ordered.first)
        let blockedFD = Darwin.open(blocked.locator, O_WRONLY | O_APPEND | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(blockedFD, 0)
        _ = Data("changed".utf8).withUnsafeBytes {
            Darwin.write(blockedFD, $0.baseAddress, $0.count)
        }
        _ = Darwin.close(blockedFD)

        let pagingCoordinator = ArchiveCaptureCoordinator(
            cas: cas,
            catalog: catalog,
            unboundBatchLimit: 1
        )
        let identities = try ordered.enumerated().map { index, capture in
            try sessionIdentity(
                capture: capture,
                source: .claudeCode,
                locator: capture.locator,
                id: "page-\(index)"
            )
        }
        let result = try await pagingCoordinator.bind(identities)

        XCTAssertEqual(result.items.count, 2)
        XCTAssertEqual(result.bindings.count, 1)
        XCTAssertTrue(result.items.contains { $0.disposition == .generationChanged })
        XCTAssertTrue(result.items.contains { $0.disposition == .bound })
    }

    func testClaudeAndCodexReplayFromArchiveWithFreshAdaptersAfterOriginalTreesDeleted() async throws {
        let claudeRoot = root.appendingPathComponent("live/claude-projects", isDirectory: true)
        let claudeFile = claudeRoot
            .appendingPathComponent("-repo/session-parent/subagents", isDirectory: true)
            .appendingPathComponent("agent-child.jsonl")
        try FileManager.default.createDirectory(
            at: claudeFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let claudeLines = [
            #"{"type":"user","sessionId":"child","cwd":"/repo","timestamp":"2026-07-11T01:00:00Z","message":{"role":"user","content":"hello claude"}}"#,
            #"{"type":"assistant","sessionId":"child","cwd":"/repo","timestamp":"2026-07-11T01:00:01Z","message":{"role":"assistant","model":"claude-opus-4-6","content":[{"type":"text","text":"hello back"}]}}"#,
        ]
        try (claudeLines.joined(separator: "\n") + "\n")
            .write(to: claudeFile, atomically: true, encoding: .utf8)

        let codexHome = root.appendingPathComponent("live/codex-home", isDirectory: true)
        let codexSessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
        let codexFile = codexSessions
            .appendingPathComponent("2026/07/11", isDirectory: true)
            .appendingPathComponent("rollout-replay.jsonl")
        try FileManager.default.createDirectory(
            at: codexFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try codexFixtureData().write(to: codexFile)

        let originalClaude = ClaudeCodeAdapter(projectsRoot: claudeRoot.path)
        let originalCodex = CodexAdapter(sessionsRoot: codexSessions.path)
        let expectedClaude = try await listedMessages(originalClaude)
        let expectedCodex = try await listedMessages(originalCodex)
        let (cas, catalog) = try makeStore(name: "adapter-replay")
        let coordinator = ArchiveCaptureCoordinator(cas: cas, catalog: catalog)
        let cycle = try await coordinator.capture(adapters: [originalClaude, originalCodex])
        XCTAssertEqual(cycle.captures.count, 2)

        try FileManager.default.removeItem(at: claudeRoot)
        try FileManager.default.removeItem(at: codexHome)

        let replayClaudeRoot = root.appendingPathComponent("replay/claude-projects", isDirectory: true)
        let replayCodexHome = root.appendingPathComponent("replay/codex-home", isDirectory: true)
        for captured in cycle.captures {
            let base = captured.manifest.source == SourceName.claudeCode.rawValue
                ? replayClaudeRoot
                : replayCodexHome
            try reconstruct(captured.manifest, from: cas, under: base)
        }

        let freshClaude = ClaudeCodeAdapter(projectsRoot: replayClaudeRoot.path)
        let freshCodex = CodexAdapter(
            sessionsRoot: replayCodexHome.appendingPathComponent("sessions", isDirectory: true).path
        )
        let replayedClaude = try await listedMessages(freshClaude)
        let replayedCodex = try await listedMessages(freshCodex)
        XCTAssertEqual(replayedClaude, expectedClaude)
        XCTAssertEqual(replayedCodex, expectedCodex)
    }

    func testCodexDescriptorPreservesSessionsAndArchivedSessionsRootSemantics() async throws {
        let home = root.appendingPathComponent("codex-layout", isDirectory: true)
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        let archived = home.appendingPathComponent("archived_sessions", isDirectory: true)
        let liveFile = sessions.appendingPathComponent("2026/07/11/rollout-live.jsonl")
        let archivedFile = archived.appendingPathComponent("rollout-archived.jsonl")
        try FileManager.default.createDirectory(
            at: liveFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        try Data().write(to: liveFile)
        try Data().write(to: archivedFile)
        let adapter = CodexAdapter(sessionsRoot: sessions.path)

        let live = try await adapter.archiveSourceDescriptor(locator: liveFile.path)
        let old = try await adapter.archiveSourceDescriptor(locator: archivedFile.path)

        XCTAssertEqual(live.files.first?.replayRelativePath, "sessions/2026/07/11/rollout-live.jsonl")
        XCTAssertEqual(old.files.first?.replayRelativePath, "archived_sessions/rollout-archived.jsonl")
    }

    func testCodexDescriptorPreservesLogicalSessionsRootThroughSymlink() async throws {
        let home = root.appendingPathComponent("codex-symlink-layout", isDirectory: true)
        let realSessions = root.appendingPathComponent("codex-real-sessions", isDirectory: true)
        let linkedSessions = home.appendingPathComponent("sessions", isDirectory: true)
        let sourceURL = realSessions.appendingPathComponent("2026/07/11/rollout-linked.jsonl")
        try FileManager.default.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data().write(to: sourceURL)
        try FileManager.default.createSymbolicLink(
            at: linkedSessions,
            withDestinationURL: realSessions
        )
        let adapter = CodexAdapter(sessionsRoot: linkedSessions.path)
        let locators = try await adapter.listSessionLocators()
        let locator = try XCTUnwrap(locators.first)

        let descriptor = try await adapter.archiveSourceDescriptor(locator: locator)

        XCTAssertEqual(
            descriptor.files.first?.replayRelativePath,
            "sessions/2026/07/11/rollout-linked.jsonl"
        )
    }

    func testCapturePropagatesAdapterCancellationWithoutRecordingFailure() async throws {
        let sourceURL = root.appendingPathComponent("cancel/session.jsonl")
        try FileManager.default.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("cancel".utf8).write(to: sourceURL)
        let adapter = CoordinatorCancellingExactAdapter(locator: sourceURL.path)
        let (cas, catalog) = try makeStore(name: "cancel")
        let coordinator = ArchiveCaptureCoordinator(cas: cas, catalog: catalog)

        do {
            _ = try await coordinator.capture(adapters: [adapter])
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Cancellation is control flow, never a per-locator diagnostic.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertTrue(try catalog.unboundCaptures(limit: 10).isEmpty)
        XCTAssertEqual(try archivePayloadFileCount(name: "cancel", leaf: "objects/sha256"), 0)
        XCTAssertEqual(try archivePayloadFileCount(name: "cancel", leaf: "manifests/sha256"), 0)
    }

    func testCaptureCancellationAfterRecordedRowPersistsFairProgressAcrossRestart() async throws {
        let claudeURL = try XCTUnwrap(
            try makeSourceFiles(
                directory: "capture-cancel-progress/claude",
                names: ["first.jsonl"]
            ).first
        )
        let codexURL = try XCTUnwrap(
            try makeSourceFiles(
                directory: "capture-cancel-progress/codex",
                names: ["second.jsonl"]
            ).first
        )
        let adapters: [any SessionAdapter] = [
            CoordinatorExactAdapter(
                source: .claudeCode,
                locators: [claudeURL.path],
                relativePaths: [claudeURL.path: "claude/first.jsonl"]
            ),
            CoordinatorExactAdapter(
                source: .codex,
                locators: [codexURL.path],
                relativePaths: [codexURL.path: "codex/second.jsonl"]
            ),
        ]
        let (cas, catalog) = try makeStore(name: "capture-cancel-progress")
        let cancelling = ArchiveCaptureCoordinator(
            cas: cas,
            catalog: catalog,
            testHooks: ArchiveCaptureCoordinatorTestHooks(
                { _ in withUnsafeCurrentTask { $0?.cancel() } }
            )
        )

        let cancelledCycle = Task {
            try await cancelling.capture(
                adapters: adapters,
                locatorBudget: 2,
                cursorScope: .full
            )
        }
        do {
            _ = try await cancelledCycle.value
            XCTFail("expected cancellation after the first durable capture")
        } catch is CancellationError {
            // The recorded Claude row must already have advanced the fair cursor.
        }
        XCTAssertEqual(try catalog.unboundCaptures(limit: 10).count, 1)

        let reopenedCatalog = try ArchiveCatalog(
            root: archiveRoot(name: "capture-cancel-progress"),
            machineID: machineID
        )
        try reopenedCatalog.migrate()
        let restarted = ArchiveCaptureCoordinator(cas: cas, catalog: reopenedCatalog)
        let resumed = try await restarted.capture(
            adapters: adapters,
            locatorBudget: 1,
            cursorScope: .full
        )

        XCTAssertEqual(resumed.items.map(\.source), [.codex])
        XCTAssertEqual(resumed.items.map(\.locator), [codexURL.path])
        XCTAssertEqual(try reopenedCatalog.unboundCaptures(limit: 10).count, 2)
    }

    func testCaptureBudgetIsGlobalFairAndResumesAfterCatalogRestart() async throws {
        let claudeURLs = try makeSourceFiles(
            directory: "budget/claude",
            names: ["claude-1.jsonl", "claude-2.jsonl"]
        )
        let codexURLs = try makeSourceFiles(
            directory: "budget/codex",
            names: ["codex-1.jsonl", "codex-2.jsonl"]
        )
        let claude = CoordinatorExactAdapter(
            source: .claudeCode,
            locators: claudeURLs.map(\.path),
            relativePaths: Dictionary(
                uniqueKeysWithValues: claudeURLs.map { ($0.path, "claude/\($0.lastPathComponent)") }
            )
        )
        let codex = CoordinatorExactAdapter(
            source: .codex,
            locators: codexURLs.map(\.path),
            relativePaths: Dictionary(
                uniqueKeysWithValues: codexURLs.map { ($0.path, "codex/\($0.lastPathComponent)") }
            )
        )
        let (cas, catalog) = try makeStore(name: "capture-budget")
        let firstCoordinator = ArchiveCaptureCoordinator(cas: cas, catalog: catalog)

        let zero = try await firstCoordinator.capture(
            adapters: [claude, codex],
            locatorBudget: 0
        )
        XCTAssertEqual(zero.processed, 0)
        XCTAssertTrue(zero.items.isEmpty)
        XCTAssertTrue(zero.captures.isEmpty)
        XCTAssertTrue(zero.hasMore)
        XCTAssertNotNil(zero.continuation)
        XCTAssertTrue(zero.failures.isEmpty)

        let first = try await firstCoordinator.capture(
            adapters: [claude, codex],
            locatorBudget: 1
        )
        XCTAssertEqual(first.processed, 1)
        XCTAssertEqual(first.items.map(\.source), [.claudeCode])
        XCTAssertEqual(first.captures.count, 1)
        XCTAssertTrue(first.hasMore)
        XCTAssertNotNil(first.continuation)

        let reopenedCatalog = try ArchiveCatalog(
            root: archiveRoot(name: "capture-budget"),
            machineID: machineID
        )
        try reopenedCatalog.migrate()
        let restartedCoordinator = ArchiveCaptureCoordinator(
            cas: cas,
            catalog: reopenedCatalog
        )
        let second = try await restartedCoordinator.capture(
            adapters: [claude, codex],
            locatorBudget: 1
        )
        XCTAssertEqual(second.processed, 1)
        XCTAssertEqual(second.items.map(\.source), [.codex])
        XCTAssertTrue(second.hasMore)

        let third = try await restartedCoordinator.capture(
            adapters: [claude, codex],
            locatorBudget: 1
        )
        XCTAssertEqual(third.items.map(\.source), [.claudeCode])
        XCTAssertTrue(third.hasMore)
        let fourth = try await restartedCoordinator.capture(
            adapters: [claude, codex],
            locatorBudget: 1
        )
        XCTAssertEqual(fourth.items.map(\.source), [.codex])
        XCTAssertFalse(fourth.hasMore)
        XCTAssertNil(fourth.continuation)
        XCTAssertEqual(try reopenedCatalog.unboundCaptures(limit: 10).count, 4)
    }

    func testCaptureCursorUsesStableLocatorIdentityAcrossReordering() async throws {
        let urls = try makeSourceFiles(
            directory: "capture-reorder",
            names: ["one.jsonl", "two.jsonl", "three.jsonl"]
        )
        let adapter = CoordinatorMutableExactAdapter(
            source: .claudeCode,
            locators: urls.map(\.path)
        )
        let (cas, catalog) = try makeStore(name: "capture-reorder")
        let coordinator = ArchiveCaptureCoordinator(cas: cas, catalog: catalog)

        let first = try await coordinator.capture(
            adapters: [adapter],
            locatorBudget: 1
        )
        let firstLocator = try XCTUnwrap(first.items.first?.locator)
        let remaining = urls.map(\.path).filter { $0 != firstLocator }
        adapter.replaceLocators([remaining[0], firstLocator, remaining[1]])

        let second = try await coordinator.capture(
            adapters: [adapter],
            locatorBudget: 1
        )

        XCTAssertNotEqual(
            second.items.first?.locator,
            firstLocator,
            "reordering must not move an already-processed locator back under a numeric offset"
        )
    }

    func testCaptureCursorRestartsChangedLocatorEpochWithoutSkippingCurrentMembers() async throws {
        let initialURLs = try makeSourceFiles(
            directory: "capture-mutation",
            names: ["initial-a.jsonl", "initial-b.jsonl"]
        )
        let insertedURL = try XCTUnwrap(
            try makeSourceFiles(
                directory: "capture-mutation",
                names: ["inserted.jsonl"]
            ).first
        )
        let adapter = CoordinatorMutableExactAdapter(
            source: .claudeCode,
            locators: initialURLs.map(\.path)
        )
        let (cas, catalog) = try makeStore(name: "capture-mutation")
        let coordinator = ArchiveCaptureCoordinator(cas: cas, catalog: catalog)

        let first = try await coordinator.capture(
            adapters: [adapter],
            locatorBudget: 1
        )
        let processedLocator = try XCTUnwrap(first.items.first?.locator)
        let retainedLocator = try XCTUnwrap(
            initialURLs.map(\.path).first { $0 != processedLocator }
        )
        let currentLocators = [insertedURL.path, retainedLocator]
        adapter.replaceLocators(currentLocators.reversed())

        var seen = Set<String>()
        var completed = false
        for _ in 0 ..< 4 {
            let cycle = try await coordinator.capture(
                adapters: [adapter],
                locatorBudget: 1
            )
            seen.formUnion(cycle.items.map(\.locator))
            if !cycle.hasMore {
                completed = true
                break
            }
        }

        XCTAssertTrue(completed)
        XCTAssertEqual(seen, Set(currentLocators))
    }

    func testCaptureCursorKeepsAdvancingWhenEveryEnumerationAppendsAndReorders() async throws {
        let originals = try makeSourceFiles(
            directory: "capture-continuous-append",
            names: (0 ..< 5).map { "original-\($0).jsonl" }
        )
        let adapter = CoordinatorMutableExactAdapter(
            source: .claudeCode,
            locators: originals.map(\.path)
        )
        let (cas, catalog) = try makeStore(name: "capture-continuous-append")
        let coordinator = ArchiveCaptureCoordinator(cas: cas, catalog: catalog)
        var current = originals.map(\.path)
        var seen = Set<String>()
        let earlier = try XCTUnwrap(
            try makeSourceFiles(
                directory: "capture-continuous-append",
                names: ["aa-inserted-earlier.jsonl"]
            ).first
        )

        for index in 0 ..< 16 {
            let appended = try XCTUnwrap(
                try makeSourceFiles(
                    directory: "capture-continuous-append",
                    names: ["zz-appended-\(index).jsonl"]
                ).first
            )
            current.insert(appended.path, at: 0)
            if index == 1 {
                current.insert(earlier.path, at: 0)
            }
            adapter.replaceLocators(current)
            let cycle = try await coordinator.capture(
                adapters: [adapter],
                locatorBudget: 1
            )
            seen.formUnion(cycle.items.map(\.locator))
        }

        XCTAssertTrue(
            Set(originals.map(\.path)).isSubset(of: seen),
            "continuous tail growth plus enumeration reorder must not pin the cursor at the head"
        )
        XCTAssertTrue(
            seen.contains(earlier.path),
            "a key inserted before the cursor must be reached after the fixed sweep boundary wraps"
        )
    }

    func testCaptureDiscoversLocatorAddedAfterSourceWasExhausted() async throws {
        let urls = try makeSourceFiles(
            directory: "capture-after-exhausted",
            names: ["existing.jsonl", "new.jsonl"]
        )
        let adapter = CoordinatorMutableExactAdapter(
            source: .claudeCode,
            locators: [urls[0].path]
        )
        let (cas, catalog) = try makeStore(name: "capture-after-exhausted")
        let coordinator = ArchiveCaptureCoordinator(cas: cas, catalog: catalog)

        let exhausted = try await coordinator.capture(
            adapters: [adapter],
            locatorBudget: 1
        )
        XCTAssertFalse(exhausted.hasMore)
        adapter.replaceLocators(urls.map(\.path).reversed())

        var discoveredNewLocator = false
        for _ in 0 ..< 3 {
            let cycle = try await coordinator.capture(
                adapters: [adapter],
                locatorBudget: 1
            )
            discoveredNewLocator = discoveredNewLocator
                || cycle.items.contains { $0.locator == urls[1].path }
            if !cycle.hasMore { break }
        }

        XCTAssertTrue(discoveredNewLocator)
    }

    func testFullAndRecentCaptureScopesPersistIndependentFairCursors() async throws {
        let fullURLs = try makeSourceFiles(
            directory: "scope/full",
            names: ["full-claude.jsonl", "full-codex.jsonl"]
        )
        let recentURLs = try makeSourceFiles(
            directory: "scope/recent",
            names: ["recent-claude.jsonl", "recent-codex.jsonl"]
        )
        let fullAdapters: [any SessionAdapter] = [
            CoordinatorExactAdapter(
                source: .claudeCode,
                locators: [fullURLs[0].path],
                relativePaths: [fullURLs[0].path: "full/claude.jsonl"]
            ),
            CoordinatorExactAdapter(
                source: .codex,
                locators: [fullURLs[1].path],
                relativePaths: [fullURLs[1].path: "full/codex.jsonl"]
            ),
        ]
        let recentAdapters: [any SessionAdapter] = [
            CoordinatorExactAdapter(
                source: .claudeCode,
                locators: [recentURLs[0].path],
                relativePaths: [recentURLs[0].path: "recent/claude.jsonl"]
            ),
            CoordinatorExactAdapter(
                source: .codex,
                locators: [recentURLs[1].path],
                relativePaths: [recentURLs[1].path: "recent/codex.jsonl"]
            ),
        ]
        let (cas, catalog) = try makeStore(name: "capture-scopes")
        let coordinator = ArchiveCaptureCoordinator(cas: cas, catalog: catalog)

        let fullFirst = try await coordinator.capture(
            adapters: fullAdapters,
            locatorBudget: 1,
            cursorScope: .full
        )
        let recentFirst = try await coordinator.capture(
            adapters: recentAdapters,
            locatorBudget: 1,
            cursorScope: .recent
        )
        XCTAssertEqual(fullFirst.items.map(\.source), [.claudeCode])
        XCTAssertEqual(recentFirst.items.map(\.source), [.claudeCode])
        XCTAssertTrue(fullFirst.hasMore)
        XCTAssertTrue(recentFirst.hasMore)

        let reopenedCatalog = try ArchiveCatalog(
            root: archiveRoot(name: "capture-scopes"),
            machineID: machineID
        )
        try reopenedCatalog.migrate()
        let restarted = ArchiveCaptureCoordinator(cas: cas, catalog: reopenedCatalog)
        let fullSecond = try await restarted.capture(
            adapters: fullAdapters,
            locatorBudget: 1,
            cursorScope: .full
        )
        let recentSecond = try await restarted.capture(
            adapters: recentAdapters,
            locatorBudget: 1,
            cursorScope: .recent
        )
        XCTAssertEqual(fullSecond.items.map(\.source), [.codex])
        XCTAssertEqual(recentSecond.items.map(\.source), [.codex])
        XCTAssertFalse(fullSecond.hasMore)
        XCTAssertFalse(recentSecond.hasMore)
        XCTAssertEqual(try reopenedCatalog.unboundCaptures(limit: 10).count, 4)
    }

    func testBindingBudgetPersistsPastPoisonRowAndDoesNotStarveLaterCapture() async throws {
        let urls = try makeSourceFiles(
            directory: "bind-budget",
            names: ["first.jsonl", "second.jsonl"]
        )
        let adapter = CoordinatorExactAdapter(
            source: .claudeCode,
            locators: urls.map(\.path),
            relativePaths: Dictionary(
                uniqueKeysWithValues: urls.map { ($0.path, "project/\($0.lastPathComponent)") }
            )
        )
        let (cas, catalog) = try makeStore(name: "bind-budget")
        let captureCoordinator = ArchiveCaptureCoordinator(cas: cas, catalog: catalog)
        let captureCycle = try await captureCoordinator.capture(adapters: [adapter])
        XCTAssertEqual(captureCycle.captures.count, 2)
        let ordered = try catalog.unboundCaptures(limit: 10)
        let poison = try XCTUnwrap(ordered.first)
        let poisonFD = Darwin.open(poison.locator, O_WRONLY | O_APPEND | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(poisonFD, 0)
        _ = Data("changed".utf8).withUnsafeBytes {
            Darwin.write(poisonFD, $0.baseAddress, $0.count)
        }
        _ = Darwin.close(poisonFD)
        let identities = try ordered.enumerated().map { index, capture in
            try sessionIdentity(
                capture: capture,
                source: .claudeCode,
                locator: capture.locator,
                id: "bounded-bind-\(index)"
            )
        }
        let coordinator = ArchiveCaptureCoordinator(
            cas: cas,
            catalog: catalog,
            unboundBatchLimit: 1
        )

        let zeroTargets = try await coordinator.bindingTargets(rowBudget: 0)
        XCTAssertTrue(zeroTargets.isEmpty)
        let initialTargets = try await coordinator.bindingTargets(rowBudget: 1)
        XCTAssertEqual(initialTargets.map(\.captureID), [ordered[0].captureID])
        let repeatedTargets = try await coordinator.bindingTargets(rowBudget: 1)
        XCTAssertEqual(
            repeatedTargets.map(\.captureID),
            [ordered[0].captureID],
            "read-only target snapshots must not advance the binding cursor"
        )
        let zero = try await coordinator.bind(identities, rowBudget: 0)
        XCTAssertEqual(zero.processed, 0)
        XCTAssertTrue(zero.items.isEmpty)
        XCTAssertTrue(zero.hasMore)
        XCTAssertNotNil(zero.continuation)

        let first = try await coordinator.bind([identities[0]], rowBudget: 1)
        XCTAssertEqual(first.processed, 1)
        XCTAssertEqual(first.items.map(\.disposition), [.generationChanged])
        XCTAssertTrue(first.bindings.isEmpty)
        XCTAssertTrue(first.hasMore)
        XCTAssertNotNil(first.continuation)

        let reopenedCatalog = try ArchiveCatalog(
            root: archiveRoot(name: "bind-budget"),
            machineID: machineID
        )
        try reopenedCatalog.migrate()
        let restarted = ArchiveCaptureCoordinator(
            cas: cas,
            catalog: reopenedCatalog,
            unboundBatchLimit: 1
        )
        let resumedTargets = try await restarted.bindingTargets(rowBudget: 1)
        XCTAssertEqual(resumedTargets.map(\.captureID), [ordered[1].captureID])
        let second = try await restarted.bind(identities, rowBudget: 1)
        XCTAssertEqual(second.processed, 1)
        XCTAssertEqual(second.items.map(\.disposition), [.bound])
        XCTAssertEqual(second.bindings.count, 1)
        XCTAssertFalse(second.hasMore)
        XCTAssertNil(second.continuation)
        XCTAssertEqual(try reopenedCatalog.unboundCaptures(limit: 10).count, 1)
    }

    func testBindingTargetsFailClosedInsteadOfSwitchingBatchAfterCatalogMutation() async throws {
        let urls = try makeSourceFiles(
            directory: "bind-locked-batch",
            names: ["first.jsonl", "second.jsonl"]
        )
        let adapter = CoordinatorExactAdapter(
            source: .claudeCode,
            locators: urls.map(\.path),
            relativePaths: Dictionary(
                uniqueKeysWithValues: urls.map { ($0.path, "project/\($0.lastPathComponent)") }
            )
        )
        let (cas, catalog) = try makeStore(name: "bind-locked-batch")
        let captureCoordinator = ArchiveCaptureCoordinator(cas: cas, catalog: catalog)
        _ = try await captureCoordinator.capture(adapters: [adapter])
        let ordered = try catalog.unboundCaptures(limit: 10)
        let identities = try ordered.enumerated().map { index, capture in
            try sessionIdentity(
                capture: capture,
                source: .claudeCode,
                locator: capture.locator,
                id: "locked-batch-\(index)"
            )
        }
        let coordinator = ArchiveCaptureCoordinator(
            cas: cas,
            catalog: catalog,
            unboundBatchLimit: 1
        )
        let targets = try await coordinator.bindingTargets(rowBudget: 1)
        XCTAssertEqual(targets.map(\.captureID), [ordered[0].captureID])

        let competingCoordinator = ArchiveCaptureCoordinator(cas: cas, catalog: catalog)
        let competing = try await competingCoordinator.bind([identities[0]], rowBudget: 1)
        XCTAssertEqual(competing.bindings.count, 1)

        do {
            _ = try await coordinator.bind(identities, rowBudget: 1)
            XCTFail("expected the locked target batch to fail closed")
        } catch {
            XCTAssertEqual(
                error as? ArchiveCaptureCoordinatorError,
                .invalidBindingContinuation
            )
        }
        XCTAssertNil(try catalog.latestBinding(sessionID: identities[1].sessionID))
    }

    func testLockedBindingBatchSupportsExactPrefixConsumptionAcrossRestart() async throws {
        let urls = try makeSourceFiles(
            directory: "bind-prefix-restart",
            names: ["first.jsonl", "second.jsonl", "third.jsonl"]
        )
        let adapter = CoordinatorExactAdapter(
            source: .claudeCode,
            locators: urls.map(\.path),
            relativePaths: Dictionary(
                uniqueKeysWithValues: urls.map { ($0.path, "project/\($0.lastPathComponent)") }
            )
        )
        let (cas, catalog) = try makeStore(name: "bind-prefix-restart")
        let captureCoordinator = ArchiveCaptureCoordinator(cas: cas, catalog: catalog)
        _ = try await captureCoordinator.capture(adapters: [adapter])
        let ordered = try catalog.unboundCaptures(limit: 10)
        XCTAssertEqual(ordered.count, 3)
        let identities = try ordered.enumerated().map { index, capture in
            try sessionIdentity(
                capture: capture,
                source: .claudeCode,
                locator: capture.locator,
                id: "prefix-restart-\(index)"
            )
        }
        let coordinator = ArchiveCaptureCoordinator(
            cas: cas,
            catalog: catalog,
            unboundBatchLimit: 3
        )
        let targets = try await coordinator.bindingTargets(rowBudget: 3)
        XCTAssertEqual(targets.map(\.captureID), ordered.map(\.captureID))

        let first = try await coordinator.bind(identities, rowBudget: 1)
        XCTAssertEqual(first.bindings.map(\.captureID), [ordered[0].captureID])
        XCTAssertTrue(first.hasMore)

        let reopenedCatalog = try ArchiveCatalog(
            root: archiveRoot(name: "bind-prefix-restart"),
            machineID: machineID
        )
        try reopenedCatalog.migrate()
        let restarted = ArchiveCaptureCoordinator(
            cas: cas,
            catalog: reopenedCatalog,
            unboundBatchLimit: 3
        )
        let remainingTargets = try await restarted.bindingTargets(rowBudget: 3)
        XCTAssertEqual(
            remainingTargets.map(\.captureID),
            Array(ordered.dropFirst()).map(\.captureID)
        )
        let second = try await restarted.bind([identities[1]], rowBudget: 1)
        let third = try await restarted.bind([identities[2]], rowBudget: 1)
        XCTAssertEqual(second.bindings.map(\.captureID), [ordered[1].captureID])
        XCTAssertEqual(third.bindings.map(\.captureID), [ordered[2].captureID])
        XCTAssertFalse(third.hasMore)
    }

    func testBindingCancellationPersistsProcessedPoisonRowButNotUnprocessedRow() async throws {
        let urls = try makeSourceFiles(
            directory: "bind-cancel-restart",
            names: ["first.jsonl", "second.jsonl"]
        )
        let adapter = CoordinatorExactAdapter(
            source: .claudeCode,
            locators: urls.map(\.path),
            relativePaths: Dictionary(
                uniqueKeysWithValues: urls.map { ($0.path, "project/\($0.lastPathComponent)") }
            )
        )
        let (cas, catalog) = try makeStore(name: "bind-cancel-restart")
        let captureCoordinator = ArchiveCaptureCoordinator(cas: cas, catalog: catalog)
        _ = try await captureCoordinator.capture(adapters: [adapter])
        let ordered = try catalog.unboundCaptures(limit: 10)
        XCTAssertEqual(ordered.count, 2)
        let poison = ordered[0]
        let poisonFD = Darwin.open(poison.locator, O_WRONLY | O_APPEND | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(poisonFD, 0)
        _ = Data("changed".utf8).withUnsafeBytes {
            Darwin.write(poisonFD, $0.baseAddress, $0.count)
        }
        _ = Darwin.close(poisonFD)
        let identities = try ordered.enumerated().map { index, capture in
            try sessionIdentity(
                capture: capture,
                source: .claudeCode,
                locator: capture.locator,
                id: "cancel-restart-\(index)"
            )
        }
        let coordinator = ArchiveCaptureCoordinator(
            cas: cas,
            catalog: catalog,
            unboundBatchLimit: 2,
            testHooks: ArchiveCaptureCoordinatorTestHooks(
                afterBindingRowAdvanced: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            )
        )

        let cancelledBind = Task {
            try await coordinator.bind(identities, rowBudget: 2)
        }
        do {
            _ = try await cancelledBind.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // The poison row was consumed; the second row was never processed.
        }

        let reopenedCatalog = try ArchiveCatalog(
            root: archiveRoot(name: "bind-cancel-restart"),
            machineID: machineID
        )
        try reopenedCatalog.migrate()
        let restarted = ArchiveCaptureCoordinator(
            cas: cas,
            catalog: reopenedCatalog,
            unboundBatchLimit: 2
        )
        let resumedTargets = try await restarted.bindingTargets(rowBudget: 2)
        XCTAssertEqual(resumedTargets.map(\.captureID), [ordered[1].captureID])
        let resumed = try await restarted.bind(identities, rowBudget: 2)
        XCTAssertEqual(resumed.bindings.map(\.captureID), [ordered[1].captureID])
        XCTAssertNil(try reopenedCatalog.latestBinding(sessionID: identities[0].sessionID))
    }

    func testBindingCancellationAfterFinalPoisonRowPersistsExhaustedSnapshotPosition() async throws {
        let fixture = try await capturedBindingFixture(name: "cancel-final-poison")
        let poisonFD = Darwin.open(fixture.sourceURL.path, O_WRONLY | O_APPEND | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(poisonFD, 0)
        _ = Data("changed".utf8).withUnsafeBytes {
            Darwin.write(poisonFD, $0.baseAddress, $0.count)
        }
        _ = Darwin.close(poisonFD)
        let identity = try sessionIdentity(
            capture: fixture.capture,
            source: .claudeCode,
            locator: fixture.sourceURL.path,
            id: "cancel-final-poison"
        )
        let coordinator = ArchiveCaptureCoordinator(
            cas: try ImmutableArchiveCAS(root: archiveRoot(name: "binding-cancel-final-poison")),
            catalog: fixture.catalog,
            unboundBatchLimit: 1,
            testHooks: ArchiveCaptureCoordinatorTestHooks(
                afterBindingRowAdvanced: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            )
        )
        let cancelledBind = Task {
            try await coordinator.bind([identity], rowBudget: 1)
        }
        do {
            _ = try await cancelledBind.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // The final poison row was advanced before cancellation surfaced.
        }

        let reopenedCatalog = try ArchiveCatalog(
            root: archiveRoot(name: "binding-cancel-final-poison"),
            machineID: machineID
        )
        try reopenedCatalog.migrate()
        let restarted = ArchiveCaptureCoordinator(
            cas: try ImmutableArchiveCAS(root: archiveRoot(name: "binding-cancel-final-poison")),
            catalog: reopenedCatalog,
            unboundBatchLimit: 1
        )
        let restartedTargets = try await restarted.bindingTargets(rowBudget: 1)
        XCTAssertTrue(restartedTargets.isEmpty)
        let exhausted = try await restarted.bind([identity], rowBudget: 1)
        XCTAssertEqual(exhausted.processed, 0)
        XCTAssertFalse(exhausted.hasMore)
    }

    func testBindingTargetsFailClosedForInvalidPersistedContinuation() async throws {
        let (cas, catalog) = try makeStore(name: "bind-target-tamper")
        _ = try catalog.storeArchiveCursorCheckpoint(
            Data("{}".utf8),
            for: .bindingCycle,
            updatedAt: "2026-07-11T00:00:00.000Z"
        )
        let coordinator = ArchiveCaptureCoordinator(cas: cas, catalog: catalog)

        do {
            _ = try await coordinator.bindingTargets(rowBudget: 1)
            XCTFail("expected invalid continuation")
        } catch {
            XCTAssertEqual(
                error as? ArchiveCaptureCoordinatorError,
                .invalidBindingContinuation
            )
        }
    }

    func testCaptureFailsClosedWhenPersistedEnvelopePayloadDigestIsTampered() async throws {
        let (cas, catalog) = try makeStore(name: "capture-envelope-tamper")
        let payload = Data("{\"schemaVersion\":2}".utf8)
        _ = try catalog.storeArchiveCursorCheckpoint(
            payload,
            for: .captureFull,
            updatedAt: "2026-07-11T00:00:00.000Z"
        )
        let envelope = CoordinatorCursorEnvelopeFixture(
            schemaVersion: 1,
            key: ArchiveCursorKey.captureFull.rawValue,
            payload: payload,
            payloadSHA256: String(repeating: "0", count: 64),
            updatedAt: "2026-07-11T00:00:00.000Z"
        )
        let stored = String(
            decoding: try ArchiveCanonicalJSON.encode(envelope),
            as: UTF8.self
        )
        let database = try DatabaseQueue(
            path: archiveRoot(name: "capture-envelope-tamper")
                .appendingPathComponent("archive.sqlite")
                .path
        )
        try await database.write { db in
            try db.execute(
                sql: "UPDATE archive_metadata SET value = ? WHERE key = ?",
                arguments: [stored, ArchiveCursorKey.captureFull.rawValue]
            )
        }
        let coordinator = ArchiveCaptureCoordinator(cas: cas, catalog: catalog)

        do {
            _ = try await coordinator.capture(adapters: [], locatorBudget: 1)
            XCTFail("expected tampered cursor envelope to fail closed")
        } catch {
            XCTAssertEqual(
                error as? ArchiveCatalogError,
                .invalidArchiveCursorCheckpoint(ArchiveCursorKey.captureFull.rawValue)
            )
        }
    }

    func testBindingPropagatesPreCancellationWithEmptyCatalog() async throws {
        let (cas, catalog) = try makeStore(name: "bind-cancel-empty")
        let coordinator = ArchiveCaptureCoordinator(cas: cas, catalog: catalog)

        let task = Task {
            withUnsafeCurrentTask { current in
                current?.cancel()
            }
            return try await coordinator.bind([])
        }

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Cancellation is control flow even when the catalog has no work.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    private struct BindingFixture {
        let sourceURL: URL
        let capture: ArchiveCapture
        let catalog: ArchiveCatalog
        let coordinator: ArchiveCaptureCoordinator
    }

    private func capturedBindingFixture(name: String) async throws -> BindingFixture {
        let sourceURL = root.appendingPathComponent("binding-\(name)/source.jsonl")
        try FileManager.default.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("generation \(name)".utf8).write(to: sourceURL)
        let adapter = CoordinatorExactAdapter(
            source: .claudeCode,
            locators: [sourceURL.path],
            relativePaths: [sourceURL.path: "project/source.jsonl"]
        )
        let (cas, catalog) = try makeStore(name: "binding-\(name)")
        let coordinator = ArchiveCaptureCoordinator(cas: cas, catalog: catalog)
        let captureCycle = try await coordinator.capture(adapters: [adapter])
        XCTAssertEqual(captureCycle.captures.count, 1)
        return BindingFixture(
            sourceURL: sourceURL,
            capture: try XCTUnwrap(captureCycle.captures.first?.capture),
            catalog: catalog,
            coordinator: coordinator
        )
    }

    private func sessionIdentity(
        capture: ArchiveCapture,
        source: SourceName,
        locator: String,
        id: String
    ) throws -> ArchiveSessionIdentity {
        try ArchiveSessionIdentity(
            sessionID: id,
            source: source,
            locator: locator,
            indexedGenerationProof: try indexedProof(
                capture: capture,
                source: source,
                locator: locator
            )
        )
    }

    private func indexedProof(
        capture: ArchiveCapture,
        expectedCaptureID: String? = nil,
        source: SourceName? = nil,
        locator: String? = nil,
        sizeBytes: Int64? = nil,
        modifiedAtNanos: Int64? = nil,
        inode: Int64? = nil,
        device: Int64? = nil
    ) throws -> ArchiveIndexedGenerationProof {
        try ArchiveIndexedGenerationProof(
            expectedCaptureID: expectedCaptureID ?? capture.captureID,
            source: source ?? SourceName(rawValue: capture.source)!,
            locator: locator ?? capture.locator,
            sizeBytes: sizeBytes ?? capture.generation.size,
            modifiedAtNanos: modifiedAtNanos ?? capture.generation.mtimeNs,
            inode: inode ?? capture.generation.inode,
            device: device ?? capture.generation.device,
            parseStatus: .ok
        )
    }

    private func listedMessages(_ adapter: any SessionAdapter) async throws -> [NormalizedMessage] {
        var messages: [NormalizedMessage] = []
        for locator in try await adapter.listSessionLocators() {
            let stream = try await adapter.streamMessages(
                locator: locator,
                options: StreamMessagesOptions()
            )
            for try await message in stream {
                messages.append(message)
            }
        }
        return messages
    }

    private func reconstruct(
        _ manifest: ArchiveSourceManifest,
        from cas: ImmutableArchiveCAS,
        under root: URL
    ) throws {
        let relative = try XCTUnwrap(manifest.replayLayout.relativePaths.first)
        let target = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var bytes = Data()
        for chunk in manifest.chunks {
            bytes.append(try cas.readObject(sha256: chunk.rawSHA256))
        }
        try bytes.write(to: target)
    }

    private func codexFixtureData() throws -> Data {
        let lines: [[String: Any]] = [
            [
                "timestamp": "2026-07-11T02:00:00.000Z",
                "type": "session_meta",
                "payload": [
                    "id": "codex-replay",
                    "timestamp": "2026-07-11T02:00:00.000Z",
                    "cwd": "/repo",
                ],
            ],
            [
                "timestamp": "2026-07-11T02:00:01.000Z",
                "type": "response_item",
                "payload": [
                    "type": "message",
                    "role": "user",
                    "content": [["type": "input_text", "text": "hello codex"]],
                ],
            ],
            [
                "timestamp": "2026-07-11T02:00:02.000Z",
                "type": "response_item",
                "payload": [
                    "type": "message",
                    "role": "assistant",
                    "content": [["type": "output_text", "text": "hello back"]],
                ],
            ],
        ]
        let strings = try lines.map { object -> String in
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return String(decoding: data, as: UTF8.self)
        }
        return Data((strings.joined(separator: "\n") + "\n").utf8)
    }

    private func makeStore(name: String) throws -> (ImmutableArchiveCAS, ArchiveCatalog) {
        let storeRoot = archiveRoot(name: name)
        let cas = try ImmutableArchiveCAS(root: storeRoot)
        let catalog = try ArchiveCatalog(root: storeRoot, machineID: machineID)
        try catalog.migrate()
        return (cas, catalog)
    }

    private func archiveRoot(name: String) -> URL {
        root.appendingPathComponent("archive-\(name)", isDirectory: true)
    }

    private func archivePayloadFileCount(name: String, leaf: String) throws -> Int {
        let payloadRoot = archiveRoot(name: name).appendingPathComponent(leaf, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(atPath: payloadRoot.path) else { return 0 }
        var count = 0
        while let path = enumerator.nextObject() as? String {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(
                atPath: payloadRoot.appendingPathComponent(path).path,
                isDirectory: &isDirectory
            ), !isDirectory.boolValue {
                count += 1
            }
        }
        return count
    }

    private func makeSourceFiles(directory: String, names: [String]) throws -> [URL] {
        let directoryURL = root.appendingPathComponent(directory, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        return try names.enumerated().map { index, name in
            let url = directoryURL.appendingPathComponent(name)
            try Data("source-\(index)\n".utf8).write(to: url)
            return url
        }
    }
}

private final class ArchiveEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func append(_ value: String) {
        lock.lock()
        events.append(value)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

private final class CoordinatorExactAdapter: ExactArchiveSourceAdapter, @unchecked Sendable {
    let source: SourceName
    private let locators: [String]
    private let relativePaths: [String: String]
    private let parseResult: AdapterParseResult<NormalizedSessionInfo>
    private let recorder: ArchiveEventRecorder?

    init(
        source: SourceName,
        locators: [String],
        relativePaths: [String: String],
        parseResult: AdapterParseResult<NormalizedSessionInfo> = .failure(.malformedJSON),
        recorder: ArchiveEventRecorder? = nil
    ) {
        self.source = source
        self.locators = locators
        self.relativePaths = relativePaths
        self.parseResult = parseResult
        self.recorder = recorder
    }

    func detect() async -> Bool { true }

    func listSessionLocators() async throws -> [String] {
        recorder?.append("list")
        return locators
    }

    func archiveSourceDescriptor(locator: String) async throws -> ArchiveSourceDescriptor {
        recorder?.append("descriptor")
        return try ArchiveSourceDescriptor.singleFile(
            locator: locator,
            sourceURL: URL(fileURLWithPath: locator),
            replayRelativePath: relativePaths[locator] ?? "unsupported/session.jsonl"
        )
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        recorder?.append("parse")
        return parseResult
    }

    func streamMessages(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> AsyncThrowingStream<NormalizedMessage, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func isAccessible(locator: String) async -> Bool { true }
}

private final class CoordinatorMutableExactAdapter: ExactArchiveSourceAdapter, @unchecked Sendable {
    let source: SourceName
    private let lock = NSLock()
    private var locators: [String]

    init(source: SourceName, locators: [String]) {
        self.source = source
        self.locators = locators
    }

    func replaceLocators<S: Sequence>(_ values: S) where S.Element == String {
        lock.withLock {
            locators = Array(values)
        }
    }

    func detect() async -> Bool { true }

    func listSessionLocators() async throws -> [String] {
        lock.withLock { locators }
    }

    func archiveSourceDescriptor(locator: String) async throws -> ArchiveSourceDescriptor {
        try ArchiveSourceDescriptor.singleFile(
            locator: locator,
            sourceURL: URL(fileURLWithPath: locator),
            replayRelativePath: "mutable/\(URL(fileURLWithPath: locator).lastPathComponent)"
        )
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        .failure(.malformedJSON)
    }

    func streamMessages(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> AsyncThrowingStream<NormalizedMessage, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func isAccessible(locator: String) async -> Bool { true }
}

private final class CoordinatorUndeclaredAdapter: SessionAdapter, @unchecked Sendable {
    let source: SourceName
    private let locators: [String]

    init(source: SourceName, locators: [String]) {
        self.source = source
        self.locators = locators
    }

    func detect() async -> Bool { true }
    func listSessionLocators() async throws -> [String] {
        throw CoordinatorUndeclaredAdapterError.listMustNotBeCalled
    }
    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        .failure(.malformedJSON)
    }
    func streamMessages(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> AsyncThrowingStream<NormalizedMessage, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func isAccessible(locator: String) async -> Bool { true }
}

private enum CoordinatorUndeclaredAdapterError: Error {
    case listMustNotBeCalled
}

private struct ExpectedSourceSnapshotFingerprintSeed: Codable {
    let schemaVersion: Int
    let sessionID: String
    let captureID: String
    let wholeSourceSHA256: String
    let indexedExpectedCaptureID: String
    let indexedSource: String
    let indexedLocator: String
    let indexedSizeBytes: Int64
    let indexedModifiedAtNanos: Int64
    let indexedInode: Int64
    let indexedDevice: Int64
    let indexedParseStatus: String
}

private struct CoordinatorCursorEnvelopeFixture: Codable {
    let schemaVersion: Int
    let key: String
    let payload: Data
    let payloadSHA256: String
    let updatedAt: String
}

private final class CoordinatorCancellingExactAdapter: ExactArchiveSourceAdapter, @unchecked Sendable {
    let source: SourceName = .claudeCode
    private let locator: String

    init(locator: String) {
        self.locator = locator
    }

    func detect() async -> Bool { true }
    func listSessionLocators() async throws -> [String] { [locator] }
    func archiveSourceDescriptor(locator: String) async throws -> ArchiveSourceDescriptor {
        throw CancellationError()
    }
    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        .failure(.malformedJSON)
    }
    func streamMessages(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> AsyncThrowingStream<NormalizedMessage, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func isAccessible(locator: String) async -> Bool { true }
}
