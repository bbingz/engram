import Darwin
import Foundation
import GRDB
import XCTest
@testable import EngramCoreRead
@testable import EngramCoreWrite

final class ExactSourceCapturerTests: XCTestCase {
    private let machineID = "11111111-2222-3333-4444-555555555555"
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-exact-capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    func testLocatorClassificationIsDescriptorDeclaredAndDenyByDefault() async throws {
        let ordinary = root.appendingPathComponent("ordinary.jsonl")
        let missing = root.appendingPathComponent("missing.jsonl")
        let directory = root.appendingPathComponent("directory", isDirectory: true)
        let symlink = root.appendingPathComponent("linked.jsonl")
        let fifo = root.appendingPathComponent("pipe.jsonl")

        try Data("ordinary".utf8).write(to: ordinary)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: ordinary)
        XCTAssertEqual(mkfifo(fifo.path, S_IRUSR | S_IWUSR), 0)

        let adapter = ExactArchiveTestAdapter(
            source: .claudeCode,
            locators: [ordinary.path, missing.path, directory.path, symlink.path, fifo.path]
        )

        let ordinaryClassification = try await ArchiveLocatorClassifier.classify(
            adapter: adapter,
            locator: ordinary.path
        )
        let missingClassification = try await ArchiveLocatorClassifier.classify(
            adapter: adapter,
            locator: missing.path
        )
        let directoryClassification = try await ArchiveLocatorClassifier.classify(
            adapter: adapter,
            locator: directory.path
        )
        let symlinkClassification = try await ArchiveLocatorClassifier.classify(
            adapter: adapter,
            locator: symlink.path
        )
        let fifoClassification = try await ArchiveLocatorClassifier.classify(
            adapter: adapter,
            locator: fifo.path
        )
        XCTAssertEqual(ordinaryClassification, .declaredSingleFile(ordinary.standardizedFileURL))
        XCTAssertEqual(missingClassification, .missing)
        XCTAssertEqual(directoryClassification, .unsupportedComposite)
        assertUnsafe(symlinkClassification)
        assertUnsafe(fifoClassification)

        let undeclared = UndeclaredArchiveTestAdapter(source: .kimi, locators: [ordinary.path])
        let undeclaredClassification = try await ArchiveLocatorClassifier.classify(
            adapter: undeclared,
            locator: ordinary.path
        )
        let selectorClassification = try await ArchiveLocatorClassifier.classify(
            adapter: adapter,
            locator: "\(ordinary.path)::session-1"
        )
        let composerClassification = try await ArchiveLocatorClassifier.classify(
            adapter: adapter,
            locator: "\(ordinary.path)?composer=id"
        )
        XCTAssertEqual(undeclaredClassification, .unsupportedAdapter)
        XCTAssertEqual(selectorClassification, .unsupportedVirtual)
        XCTAssertEqual(composerClassification, .unsupportedVirtual)

        let secondFile = root.appendingPathComponent("second.jsonl")
        try Data("second".utf8).write(to: secondFile)
        let mismatchedDescriptor = try ArchiveSourceDescriptor(
            locator: ordinary.path,
            files: [
                try ArchiveSourceFileDescriptor(
                    sourceURL: secondFile,
                    replayRelativePath: "second.jsonl"
                ),
            ]
        )
        assertUnsafe(
            ArchiveLocatorClassifier.classify(
                descriptor: mismatchedDescriptor,
                enumeratedLocator: ordinary.path
            )
        )
        let compositeDescriptor = try ArchiveSourceDescriptor(
            locator: ordinary.path,
            files: [
                try ArchiveSourceFileDescriptor(
                    sourceURL: ordinary,
                    replayRelativePath: "ordinary.jsonl"
                ),
                try ArchiveSourceFileDescriptor(
                    sourceURL: secondFile,
                    replayRelativePath: "second.jsonl"
                ),
            ]
        )
        XCTAssertEqual(
            ArchiveLocatorClassifier.classify(
                descriptor: compositeDescriptor,
                enumeratedLocator: ordinary.path
            ),
            .unsupportedComposite
        )

        let forbidden: Set<SourceName> = [.kimi, .copilot, .antigravity, .cursor, .opencode]
        let defaults = SessionAdapterFactory.defaultAdapters()
        XCTAssertEqual(
            Set(defaults.compactMap { ($0 as? any ExactArchiveSourceAdapter)?.source }),
            [.claudeCode, .codex]
        )
        for adapter in defaults where forbidden.contains(adapter.source) {
            XCTAssertFalse(adapter is any ExactArchiveSourceAdapter, "\(adapter.source) must stay unsupported")
        }
    }

    func testCaptureRoundTripsExactBytesAndFillsEightMiBChunksAcrossShortReads() throws {
        let binaryEdge = Data([0xEF, 0xBB, 0xBF])
            + Data("{\"line\":1}\r\n".utf8)
            + Data([0x00, 0xFF, 0xFE])
            + Data("{\"truncated\":".utf8)
        let payloads: [(String, Data, [Int64])] = [
            ("empty", Data(), []),
            (
                "binary-edge",
                binaryEdge,
                [Int64(binaryEdge.count)]
            ),
            (
                "exact-eight-mib",
                Data(repeating: 0xA5, count: Int(ArchiveSourceManifest.rawChunkSize)),
                [ArchiveSourceManifest.rawChunkSize]
            ),
            (
                "eight-mib-plus-one",
                Data(repeating: 0x5A, count: Int(ArchiveSourceManifest.rawChunkSize) + 1),
                [ArchiveSourceManifest.rawChunkSize, 1]
            ),
        ]

        for (name, payload, expectedChunkSizes) in payloads {
            let storeRoot = root.appendingPathComponent("store-\(name)", isDirectory: true)
            let sourceURL = root.appendingPathComponent("source-\(name).jsonl")
            try payload.write(to: sourceURL)
            XCTAssertEqual(chmod(sourceURL.path, 0o640), 0)
            let sourceBefore = try sourceObservation(sourceURL)
            let descriptor = try ArchiveSourceDescriptor.singleFile(
                locator: sourceURL.path,
                sourceURL: sourceURL,
                replayRelativePath: "project/subagents/session.jsonl"
            )
            let (cas, catalog) = try makeStore(storeRoot)
            let capturer = ExactSourceCapturer(
                cas: cas,
                catalog: catalog,
                descriptor: descriptor,
                testHooks: ExactSourceCapturerTestHooks(maximumReadSize: 17 * 1024)
            )

            let result = try capturer.capture(
                source: .claudeCode,
                locator: sourceURL.path,
                machineID: machineID
            )

            XCTAssertEqual(result.manifest.chunks.map(\.rawByteCount), expectedChunkSizes, name)
            XCTAssertEqual(try reconstruct(result.manifest, from: cas), payload, name)
            XCTAssertEqual(try sourceObservation(sourceURL), sourceBefore, name)
        }
    }

    func testUnchangedCaptureIsIdempotentAndReusesCanonicalCapturedAt() throws {
        let storeRoot = root.appendingPathComponent("store-idempotent", isDirectory: true)
        let sourceURL = root.appendingPathComponent("stable.jsonl")
        try Data("stable bytes\n".utf8).write(to: sourceURL)
        let descriptor = try ArchiveSourceDescriptor.singleFile(
            locator: sourceURL.path,
            sourceURL: sourceURL,
            replayRelativePath: "project/stable.jsonl"
        )
        let (cas, catalog) = try makeStore(storeRoot)
        let capturer = ExactSourceCapturer(cas: cas, catalog: catalog, descriptor: descriptor)

        let first = try capturer.capture(
            source: .claudeCode,
            locator: sourceURL.path,
            machineID: machineID
        )
        let manifestURL = manifestURL(
            storeRoot: storeRoot,
            sha256: first.capture.unboundManifestSHA256
        )
        try FileManager.default.removeItem(at: manifestURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifestURL.path))
        usleep(10_000)
        let second = try capturer.capture(
            source: .claudeCode,
            locator: sourceURL.path,
            machineID: machineID
        )

        XCTAssertEqual(second, first)
        XCTAssertEqual(second.manifest.capturedAt, first.manifest.capturedAt)
        XCTAssertEqual(try catalog.capture(captureID: first.capture.captureID), first.capture)
        XCTAssertEqual(try catalog.unboundCaptures(limit: 10), [first.capture])
        XCTAssertEqual(try Data(contentsOf: manifestURL), first.capture.unboundManifestBytes)
        XCTAssertEqual(try manifestFileCount(storeRoot), 1)
    }

    func testUnchangedCaptureRejectsCorruptExistingManifestWithoutOverwrite() throws {
        let storeRoot = root.appendingPathComponent("store-corrupt-manifest", isDirectory: true)
        let sourceURL = root.appendingPathComponent("stable-corrupt.jsonl")
        try Data("stable bytes\n".utf8).write(to: sourceURL)
        let descriptor = try ArchiveSourceDescriptor.singleFile(
            locator: sourceURL.path,
            sourceURL: sourceURL,
            replayRelativePath: "project/stable-corrupt.jsonl"
        )
        let (cas, catalog) = try makeStore(storeRoot)
        let capturer = ExactSourceCapturer(cas: cas, catalog: catalog, descriptor: descriptor)
        let first = try capturer.capture(
            source: .claudeCode,
            locator: sourceURL.path,
            machineID: machineID
        )
        let finalURL = manifestURL(
            storeRoot: storeRoot,
            sha256: first.capture.unboundManifestSHA256
        )
        try FileManager.default.removeItem(at: finalURL)
        let corrupt = Data("corrupt".utf8)
        try corrupt.write(to: finalURL)
        XCTAssertEqual(chmod(finalURL.path, 0o600), 0)

        XCTAssertThrowsError(
            try capturer.capture(
                source: .claudeCode,
                locator: sourceURL.path,
                machineID: machineID
            )
        ) { error in
            guard case .existingContentConflict = error as? ImmutableArchiveCASError else {
                return XCTFail("expected existing manifest conflict, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: finalURL), corrupt)
    }

    func testGenerationAppendRacePublishesNoManifestOrCatalogCapture() throws {
        try assertGenerationRaceDoesNotCommit { sourceURL in
            let fd = Darwin.open(sourceURL.path, O_WRONLY | O_APPEND | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(fd, 0)
            defer { _ = Darwin.close(fd) }
            let extra = Data("appended".utf8)
            _ = extra.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            _ = Darwin.fsync(fd)
        }
    }

    func testGenerationAtomicReplacementRacePublishesNoManifestOrCatalogCapture() throws {
        try assertGenerationRaceDoesNotCommit { sourceURL in
            let replacement = sourceURL.deletingLastPathComponent()
                .appendingPathComponent("replacement-\(UUID().uuidString).jsonl")
            try Data("replacement generation".utf8).write(to: replacement)
            XCTAssertEqual(rename(replacement.path, sourceURL.path), 0)
        }
    }

    func testGenerationModeChangeRacePublishesNoManifestOrCatalogCapture() throws {
        try assertGenerationRaceDoesNotCommit { sourceURL in
            XCTAssertEqual(chmod(sourceURL.path, 0o600), 0)
        }
    }

    func testCaptureCancellationLeavesNoUntrackedCASFiles_repro() async throws {
        let storeRoot = root.appendingPathComponent("store-cancelled-capture", isDirectory: true)
        let sourceURL = root.appendingPathComponent("cancelled-capture.jsonl")
        try Data("cancel after staging\n".utf8).write(to: sourceURL)
        let descriptor = try ArchiveSourceDescriptor.singleFile(
            locator: sourceURL.path,
            sourceURL: sourceURL,
            replayRelativePath: "cancelled/session.jsonl"
        )
        let (cas, catalog) = try makeStore(storeRoot)
        let capturer = ExactSourceCapturer(
            cas: cas,
            catalog: catalog,
            descriptor: descriptor,
            testHooks: ExactSourceCapturerTestHooks(
                afterStreamingBeforeFinalStat: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            )
        )

        let result = await Task {
            try capturer.capture(
                source: .claudeCode,
                locator: sourceURL.path,
                machineID: machineID
            )
        }.result

        guard case .failure(let error) = result else {
            return XCTFail("expected capture cancellation")
        }
        XCTAssertTrue(error is CancellationError, "unexpected error: \(error)")
        XCTAssertTrue(try catalog.unboundCaptures(limit: 10).isEmpty)
        try assertNoCASContent(in: storeRoot)
    }

    func testCatalogRecordFailureLeavesPublishedCASReusableAndNoStagedTemp_repro() throws {
        let storeRoot = root.appendingPathComponent("store-catalog-failure", isDirectory: true)
        let sourceURL = root.appendingPathComponent("catalog-failure.jsonl")
        let payload = Data("record failure after staging\n".utf8)
        try payload.write(to: sourceURL)
        let descriptor = try ArchiveSourceDescriptor.singleFile(
            locator: sourceURL.path,
            sourceURL: sourceURL,
            replayRelativePath: "catalog-failure/session.jsonl"
        )
        let (cas, catalog) = try makeStore(storeRoot)
        let triggerDatabase = try DatabaseQueue(
            path: storeRoot.appendingPathComponent("archive.sqlite").path
        )
        try triggerDatabase.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_archive_capture_insert
                BEFORE INSERT ON archive_captures
                BEGIN
                    SELECT RAISE(ABORT, 'forced capture insert failure');
                END
                """)
        }
        let capturer = ExactSourceCapturer(cas: cas, catalog: catalog, descriptor: descriptor)

        XCTAssertThrowsError(
            try capturer.capture(
                source: .claudeCode,
                locator: sourceURL.path,
                machineID: machineID
            )
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains("forced capture insert failure"),
                "unexpected error: \(error)"
            )
        }
        XCTAssertTrue(try catalog.unboundCaptures(limit: 10).isEmpty)
        XCTAssertEqual(
            try cas.readObject(sha256: ArchiveV2Hash.sha256(payload)),
            payload
        )
        XCTAssertEqual(try manifestFileCount(storeRoot), 1)
        XCTAssertEqual(
            try regularFileCount(in: storeRoot.appendingPathComponent("tmp", isDirectory: true)),
            0
        )
    }

    func testCatalogRecordFailureDoesNotDeleteChunkCommittedByConcurrentCapture_repro() async throws {
        let storeRoot = root.appendingPathComponent("store-shared-cas-race", isDirectory: true)
        let payload = Data("shared immutable archive bytes\n".utf8)
        let failingSourceURL = root.appendingPathComponent("shared-cas-failing.jsonl")
        let committedSourceURL = root.appendingPathComponent("shared-cas-committed.jsonl")
        try payload.write(to: failingSourceURL)
        try payload.write(to: committedSourceURL)
        let failingDescriptor = try ArchiveSourceDescriptor.singleFile(
            locator: failingSourceURL.path,
            sourceURL: failingSourceURL,
            replayRelativePath: "shared/failing.jsonl"
        )
        let committedDescriptor = try ArchiveSourceDescriptor.singleFile(
            locator: committedSourceURL.path,
            sourceURL: committedSourceURL,
            replayRelativePath: "shared/committed.jsonl"
        )
        let publishGate = CASObjectPublishGate()
        let failingCAS = try ImmutableArchiveCAS(
            root: storeRoot,
            testHooks: ImmutableArchiveCASTestHooks(
                afterDirectoryFsync: { directory in
                    publishGate.observeDirectoryFsync(directory)
                }
            )
        )
        let committedCAS = try ImmutableArchiveCAS(root: storeRoot)
        let catalog = try ArchiveCatalog(root: storeRoot, machineID: machineID)
        try catalog.migrate()
        let triggerDatabase = try DatabaseQueue(
            path: storeRoot.appendingPathComponent("archive.sqlite").path
        )
        try await triggerDatabase.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_claude_archive_capture_insert
                BEFORE INSERT ON archive_captures
                WHEN NEW.source = 'claude-code'
                BEGIN
                    SELECT RAISE(ABORT, 'forced concurrent capture insert failure');
                END
                """)
        }
        let failingCapturer = ExactSourceCapturer(
            cas: failingCAS,
            catalog: catalog,
            descriptor: failingDescriptor
        )
        let committedCapturer = ExactSourceCapturer(
            cas: committedCAS,
            catalog: catalog,
            descriptor: committedDescriptor
        )
        let testMachineID = machineID

        let failingTask = Task.detached(priority: .high) {
            Result {
                try failingCapturer.capture(
                    source: .claudeCode,
                    locator: failingSourceURL.path,
                    machineID: testMachineID
                )
            }
        }
        guard publishGate.waitUntilObjectPublished() else {
            publishGate.releaseFailingCapture()
            _ = await failingTask.value
            return XCTFail("failing capture did not pause after publishing its object")
        }
        let committedAttempt = Result {
            try committedCapturer.capture(
                source: .codex,
                locator: committedSourceURL.path,
                machineID: machineID
            )
        }
        publishGate.releaseFailingCapture()
        let failingAttempt = await failingTask.value
        let committed = try committedAttempt.get()

        guard case .failure(let error) = failingAttempt else {
            return XCTFail("expected the first catalog insert to fail")
        }
        XCTAssertTrue(
            String(describing: error).contains("forced concurrent capture insert failure"),
            "unexpected error: \(error)"
        )
        XCTAssertEqual(
            try catalog.capture(captureID: committed.capture.captureID),
            committed.capture
        )
        XCTAssertEqual(
            try committedCAS.readManifest(sha256: committed.capture.unboundManifestSHA256),
            committed.capture.unboundManifestBytes
        )
        XCTAssertEqual(try reconstruct(committed.manifest, from: committedCAS), payload)
        XCTAssertEqual(
            try regularFileCount(in: storeRoot.appendingPathComponent("tmp", isDirectory: true)),
            0
        )
    }

    func testPublishFailureDoesNotRecordCapturedRow_repro() throws {
        enum Marker: Error {
            case publishFailed
        }

        let storeRoot = root.appendingPathComponent("store-publish-failure", isDirectory: true)
        let sourceURL = root.appendingPathComponent("publish-failure.jsonl")
        try Data("publish must finish before catalog record\n".utf8).write(to: sourceURL)
        let descriptor = try ArchiveSourceDescriptor.singleFile(
            locator: sourceURL.path,
            sourceURL: sourceURL,
            replayRelativePath: "publish-failure/session.jsonl"
        )
        let cas = try ImmutableArchiveCAS(
            root: storeRoot,
            testHooks: ImmutableArchiveCASTestHooks(
                afterFinalLinkPublished: { _ in throw Marker.publishFailed }
            )
        )
        let catalog = try ArchiveCatalog(root: storeRoot, machineID: machineID)
        try catalog.migrate()
        let capturer = ExactSourceCapturer(cas: cas, catalog: catalog, descriptor: descriptor)

        XCTAssertThrowsError(
            try capturer.capture(
                source: .claudeCode,
                locator: sourceURL.path,
                machineID: machineID
            )
        ) { error in
            guard case Marker.publishFailed = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertTrue(try catalog.unboundCaptures(limit: 10).isEmpty)
    }

    func testFIFOReplacementCannotBlockCaptureOrVerification() throws {
        let storeRoot = root.appendingPathComponent("store-fifo-race", isDirectory: true)
        let fifo = root.appendingPathComponent("race-fifo.jsonl")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let descriptor = try ArchiveSourceDescriptor.singleFile(
            locator: fifo.path,
            sourceURL: fifo,
            replayRelativePath: "race/fifo.jsonl"
        )
        let (cas, catalog) = try makeStore(storeRoot)
        let capturer = ExactSourceCapturer(cas: cas, catalog: catalog, descriptor: descriptor)

        let captureError = try runFIFOOperationPromptly(fifo: fifo) {
            _ = try capturer.streamStableSource(fifo)
        }
        guard case .ineligible(.unsafe) = captureError as? ExactSourceCapturerError else {
            return XCTFail("expected unsafe non-regular capture, got \(captureError)")
        }

        let expectedGeneration = try ArchiveSourceGeneration(
            device: 1,
            inode: 1,
            size: 1,
            mtimeNs: 1,
            ctimeNs: 1,
            mode: Int64(S_IFREG | 0o600)
        )
        let verifyError = try runFIFOOperationPromptly(fifo: fifo) {
            try ExactSourceCapturer.verify(
                sourceURL: fifo,
                expectedGeneration: expectedGeneration,
                expectedWholeSourceSHA256: ArchiveV2Hash.sha256(Data([0]))
            )
        }
        XCTAssertEqual(verifyError as? ExactSourceCapturerError, .generationChanged)
    }

    func testCaptureFDBudgetRejectsBeforeStreamingOrPublishing() throws {
        let storeRoot = root.appendingPathComponent("store-fd-budget")
        let source = root.appendingPathComponent("budget.jsonl")
        let bytes = Data(repeating: 0x41, count: 128)
        try bytes.write(to: source)
        let (cas, catalog) = try makeStore(storeRoot)
        let descriptor = try ArchiveSourceDescriptor.singleFile(locator: source.path,
            sourceURL: source, replayRelativePath: "budget.jsonl")
        let capturer = ExactSourceCapturer(cas: cas, catalog: catalog, descriptor: descriptor,
            testHooks: .init(afterStreamingBeforeFinalStat: { _ in
                XCTFail("FD admission must reject before source streaming")
            }))

        XCTAssertThrowsError(try capturer.capture(source: .claudeCode, locator: source.path,
            machineID: machineID, maximumByteCount: 64)) {
            XCTAssertEqual($0 as? ExactSourceCapturerError, .exceededMaximumByteCount(64))
        }
        XCTAssertTrue(try catalog.unboundCaptures(limit: 10).isEmpty)
        try assertNoCASContent(in: storeRoot)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testCaptureFDReservationRejectsChangedGenerationWithoutNewCASContent() throws {
        let storeRoot = root.appendingPathComponent("store-fd-reservation")
        let source = root.appendingPathComponent("reservation.jsonl")
        try Data("reserved\n".utf8).write(to: source)
        let (cas, catalog) = try makeStore(storeRoot)
        let descriptor = try ArchiveSourceDescriptor.singleFile(locator: source.path,
            sourceURL: source, replayRelativePath: "reservation.jsonl")
        let capturer = ExactSourceCapturer(cas: cas, catalog: catalog, descriptor: descriptor)
        let original = try capturer.capture(source: .claudeCode, locator: source.path, machineID: machineID)
        let changed = Data("reserved\nappended after reservation\n".utf8)
        try changed.write(to: source)

        XCTAssertThrowsError(try capturer.capture(source: .claudeCode, locator: source.path,
            machineID: machineID, maximumByteCount: 1024, expectedGeneration: original.manifest.generation)) {
            XCTAssertEqual($0 as? ExactSourceCapturerError, .generationChanged)
        }
        XCTAssertEqual(try catalog.unboundCaptures(limit: 10).map(\.captureID), [original.capture.captureID])
        XCTAssertEqual(try regularFileCount(in: storeRoot.appendingPathComponent("objects/sha256")), 1)
        XCTAssertEqual(try manifestFileCount(storeRoot), 1)
        XCTAssertEqual(try regularFileCount(in: storeRoot.appendingPathComponent("tmp")), 0)
        XCTAssertEqual(try Data(contentsOf: source), changed)
    }

    func testCaptureFDBudgetValidationAndExactBoundaryPreserveDefaultBehavior() throws {
        let storeRoot = root.appendingPathComponent("store-fd-boundary")
        let source = root.appendingPathComponent("boundary.jsonl")
        let bytes = Data("exact boundary\n".utf8)
        try bytes.write(to: source)
        let (cas, catalog) = try makeStore(storeRoot)
        let descriptor = try ArchiveSourceDescriptor.singleFile(locator: source.path,
            sourceURL: source, replayRelativePath: "boundary.jsonl")
        let capturer = ExactSourceCapturer(cas: cas, catalog: catalog, descriptor: descriptor)
        XCTAssertThrowsError(try capturer.capture(source: .claudeCode, locator: source.path,
            machineID: machineID, maximumByteCount: -1)) {
            XCTAssertEqual($0 as? ExactSourceCapturerError, .invalidMaximumByteCount)
        }
        XCTAssertTrue(try catalog.unboundCaptures(limit: 10).isEmpty)
        try assertNoCASContent(in: storeRoot)
        let original = try capturer.capture(source: .claudeCode, locator: source.path, machineID: machineID)
        let repeated = try capturer.capture(source: .claudeCode, locator: source.path,
            machineID: machineID, maximumByteCount: Int64(bytes.count), expectedGeneration: original.manifest.generation)
        XCTAssertEqual(repeated, original)
        XCTAssertEqual(try reconstruct(repeated.manifest, from: cas), bytes)
        XCTAssertEqual(try catalog.unboundCaptures(limit: 10).count, 1)
    }

    private func assertGenerationRaceDoesNotCommit(
        mutation: @escaping @Sendable (URL) throws -> Void
    ) throws {
        let storeRoot = root.appendingPathComponent("store-race-\(UUID().uuidString)", isDirectory: true)
        let sourceURL = root.appendingPathComponent("race-\(UUID().uuidString).jsonl")
        try Data(repeating: 0x42, count: 128 * 1024).write(to: sourceURL)
        XCTAssertEqual(chmod(sourceURL.path, 0o640), 0)
        let descriptor = try ArchiveSourceDescriptor.singleFile(
            locator: sourceURL.path,
            sourceURL: sourceURL,
            replayRelativePath: "race/session.jsonl"
        )
        let (cas, catalog) = try makeStore(storeRoot)
        let capturer = ExactSourceCapturer(
            cas: cas,
            catalog: catalog,
            descriptor: descriptor,
            testHooks: ExactSourceCapturerTestHooks(afterStreamingBeforeFinalStat: mutation)
        )

        XCTAssertThrowsError(
            try capturer.capture(
                source: .claudeCode,
                locator: sourceURL.path,
                machineID: machineID
            )
        ) { error in
            XCTAssertEqual(error as? ExactSourceCapturerError, .generationChanged)
        }
        XCTAssertTrue(try catalog.unboundCaptures(limit: 10).isEmpty)
        XCTAssertEqual(try manifestFileCount(storeRoot), 0)
    }

    /// A blocking FIFO open is deliberately unblocked after the promptness
    /// deadline so the RED test fails without hanging the test process.
    private func runFIFOOperationPromptly(
        fifo: URL,
        operation: @escaping @Sendable () throws -> Void
    ) throws -> Error {
        let outcome = FIFOOperationOutcome()
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try operation()
                outcome.set(.success(()))
            } catch {
                outcome.set(.failure(error))
            }
            completed.signal()
        }

        let promptResult = completed.wait(timeout: .now() + 0.25)
        if promptResult == .timedOut {
            let writer = Darwin.open(fifo.path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
            if writer >= 0 {
                _ = Darwin.close(writer)
            }
            XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
        }
        XCTAssertEqual(promptResult, .success, "FIFO source operation blocked in open(2)")
        switch try XCTUnwrap(outcome.get()) {
        case .success:
            XCTFail("expected FIFO operation to fail")
            return FIFOOperationTestError.unexpectedSuccess
        case .failure(let error):
            return error
        }
    }

    private func makeStore(_ storeRoot: URL) throws -> (ImmutableArchiveCAS, ArchiveCatalog) {
        let cas = try ImmutableArchiveCAS(root: storeRoot)
        let catalog = try ArchiveCatalog(root: storeRoot, machineID: machineID)
        try catalog.migrate()
        return (cas, catalog)
    }

    private func reconstruct(
        _ manifest: ArchiveSourceManifest,
        from cas: ImmutableArchiveCAS
    ) throws -> Data {
        var reconstructed = Data()
        for chunk in manifest.chunks {
            reconstructed.append(try cas.readObject(sha256: chunk.rawSHA256))
        }
        return reconstructed
    }

    private func manifestFileCount(_ storeRoot: URL) throws -> Int {
        let manifestsRoot = storeRoot.appendingPathComponent("manifests/sha256", isDirectory: true)
        guard FileManager.default.fileExists(atPath: manifestsRoot.path) else { return 0 }
        var count = 0
        let all = FileManager.default.enumerator(atPath: manifestsRoot.path)
        while let path = all?.nextObject() as? String {
            if path.hasSuffix(".json") { count += 1 }
        }
        return count
    }

    private func assertNoCASContent(in storeRoot: URL) throws {
        XCTAssertEqual(
            try regularFileCount(
                in: storeRoot.appendingPathComponent("objects/sha256", isDirectory: true)
            ),
            0
        )
        XCTAssertEqual(try manifestFileCount(storeRoot), 0)
        XCTAssertEqual(
            try regularFileCount(in: storeRoot.appendingPathComponent("tmp", isDirectory: true)),
            0
        )
    }

    private func regularFileCount(in directory: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
        let keys: [URLResourceKey] = [.isRegularFileKey]
        let contents = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys
        )
        var count = 0
        while let url = contents?.nextObject() as? URL {
            if try url.resourceValues(forKeys: Set(keys)).isRegularFile == true {
                count += 1
            }
        }
        return count
    }

    private func manifestURL(storeRoot: URL, sha256: String) -> URL {
        storeRoot
            .appendingPathComponent("manifests/sha256", isDirectory: true)
            .appendingPathComponent(String(sha256.prefix(2)), isDirectory: true)
            .appendingPathComponent("\(sha256).json")
    }

    private struct SourceObservation: Equatable {
        let bytes: Data
        let mode: mode_t
        let size: off_t
    }

    private func sourceObservation(_ url: URL) throws -> SourceObservation {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return SourceObservation(
            bytes: try Data(contentsOf: url),
            mode: info.st_mode,
            size: info.st_size
        )
    }

    private func assertUnsafe(
        _ classification: ArchiveLocatorClassification,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .unsafe = classification else {
            return XCTFail("expected unsafe, got \(classification)", file: file, line: line)
        }
    }
}

private final class FIFOOperationOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?

    func set(_ value: Result<Void, Error>) {
        lock.lock()
        result = value
        lock.unlock()
    }

    func get() -> Result<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

private enum FIFOOperationTestError: Error {
    case unexpectedSuccess
}

private final class CASObjectPublishGate: @unchecked Sendable {
    private let lock = NSLock()
    private let objectPublished = DispatchSemaphore(value: 0)
    private let resumeFailingCapture = DispatchSemaphore(value: 0)
    private var objectShardFsyncCount = 0

    func observeDirectoryFsync(_ directory: URL) {
        guard directory.deletingLastPathComponent().lastPathComponent == "sha256",
              directory.deletingLastPathComponent()
                .deletingLastPathComponent().lastPathComponent == "objects" else {
            return
        }
        lock.lock()
        objectShardFsyncCount += 1
        let shouldPause = objectShardFsyncCount == 2
        lock.unlock()
        guard shouldPause else { return }
        objectPublished.signal()
        _ = resumeFailingCapture.wait(timeout: .now() + 5)
    }

    func waitUntilObjectPublished() -> Bool {
        objectPublished.wait(timeout: .now() + 5) == .success
    }

    func releaseFailingCapture() {
        resumeFailingCapture.signal()
    }
}

private final class ExactArchiveTestAdapter: ExactArchiveSourceAdapter, @unchecked Sendable {
    let source: SourceName
    private let locators: [String]

    init(source: SourceName, locators: [String]) {
        self.source = source
        self.locators = locators
    }

    func detect() async -> Bool { true }
    func listSessionLocators() async throws -> [String] { locators }
    func isAccessible(locator: String) async -> Bool { true }

    func archiveSourceDescriptor(locator: String) async throws -> ArchiveSourceDescriptor {
        try ArchiveSourceDescriptor.singleFile(
            locator: locator,
            sourceURL: URL(fileURLWithPath: locator),
            replayRelativePath: "session.jsonl"
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
}

private final class UndeclaredArchiveTestAdapter: SessionAdapter, @unchecked Sendable {
    let source: SourceName
    private let locators: [String]

    init(source: SourceName, locators: [String]) {
        self.source = source
        self.locators = locators
    }

    func detect() async -> Bool { true }
    func listSessionLocators() async throws -> [String] { locators }
    func isAccessible(locator: String) async -> Bool { true }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        .failure(.malformedJSON)
    }

    func streamMessages(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> AsyncThrowingStream<NormalizedMessage, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
