import Darwin
import EngramCoreRead
import EngramCoreWrite
import Foundation
import GRDB
import XCTest

@testable import EngramServiceCore

final class ArchiveTranscriptResolverTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("engram-transcript-resolver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testLiveFileWinsAndParserRunsExactlyOnceWithoutRemoteCalls() async throws {
        let store = try makeStore(name: "live")
        let liveURL = root.appendingPathComponent("live.jsonl")
        try Data("live bytes".utf8).write(to: liveURL)
        let hq = RecordingArchiveBackend(replicaID: "hq")
        let m1 = RecordingArchiveBackend(replicaID: "m1")
        let resolver = try ArchiveTranscriptResolver(
            catalog: store.catalog,
            cas: store.cas,
            hq: hq,
            m1: m1,
            temporaryParent: root
        )
        let parserCalls = AsyncCallCounter()

        let resolved = try await resolver.withResolvedFile(
            sessionID: "live-session",
            liveURL: liveURL
        ) { url in
            await parserCalls.increment()
            return try Data(contentsOf: url)
        }

        XCTAssertEqual(resolved.tier, .live)
        XCTAssertEqual(resolved.value, Data("live bytes".utf8))
        let count = await parserCalls.value()
        XCTAssertEqual(count, 1)
        let hqEvents = await hq.events()
        let m1Events = await m1.events()
        XCTAssertEqual(hqEvents, [])
        XCTAssertEqual(m1Events, [])
    }

    func testSourceAwareResolutionUsesCurrentSourceForLiveAndManifestSourceForArchive() async throws {
        let store = try makeStore(name: "source-aware")
        let liveURL = root.appendingPathComponent("source-aware-live.jsonl")
        try Data("live bytes".utf8).write(to: liveURL)
        let archived = try addFixture(
            to: store,
            sessionID: "source-aware-archive",
            seed: "source-aware-archive",
            source: "codex",
            chunks: [Data("archive bytes".utf8)]
        )
        let resolver = try ArchiveTranscriptResolver(
            catalog: store.catalog,
            cas: store.cas,
            temporaryParent: root
        )

        let live = try await resolver.withResolvedFile(
            sessionID: "source-aware-live",
            liveURL: liveURL,
            liveSource: "claude-code"
        ) { url, source in
            (try Data(contentsOf: url), source)
        }
        let archive = try await resolver.withResolvedFile(
            sessionID: archived.sessionID,
            liveURL: root.appendingPathComponent("missing-source-aware-live.jsonl"),
            liveSource: "gemini-cli"
        ) { url, source in
            (try Data(contentsOf: url), source)
        }

        XCTAssertEqual(live.tier, .live)
        XCTAssertEqual(live.value.0, Data("live bytes".utf8))
        XCTAssertEqual(live.value.1, "claude-code")
        XCTAssertEqual(archive.tier, .local)
        XCTAssertEqual(archive.value.0, archived.raw)
        XCTAssertEqual(archive.value.1, "codex")
    }

    func testLiveFileIsParsedFromStablePrivateCopyWhenOriginalPathIsReplaced() async throws {
        let store = try makeStore(name: "live-stable-copy")
        let original = Data("opened live bytes".utf8)
        let replacement = Data("replacement bytes".utf8)
        let liveURL = root.appendingPathComponent("live-stable-copy.jsonl")
        try original.write(to: liveURL)
        let hq = RecordingArchiveBackend(replicaID: "hq")
        let tempParent = try makeTemporaryParent(name: "live-stable-copy-temp")
        let resolver = try ArchiveTranscriptResolver(
            catalog: store.catalog,
            cas: store.cas,
            hq: hq,
            temporaryParent: tempParent
        )

        let result = try await resolver.withResolvedFile(
            sessionID: "live-stable-copy-session",
            liveURL: liveURL
        ) { selectedURL in
            XCTAssertNotEqual(selectedURL.standardizedFileURL, liveURL.standardizedFileURL)
            try replacement.write(to: liveURL, options: .atomic)
            return try Data(contentsOf: selectedURL)
        }

        XCTAssertEqual(result.tier, .live)
        XCTAssertEqual(result.value, original)
        XCTAssertEqual(try Data(contentsOf: liveURL), replacement)
        let hqEvents = await hq.events()
        XCTAssertEqual(hqEvents, [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tempParent.path), [])
    }

    func testLiveParserErrorIsFinalAndPrivateCopyIsRemoved() async throws {
        let store = try makeStore(name: "live-parser-error")
        let liveURL = root.appendingPathComponent("live-parser-error.jsonl")
        try Data("live parser input".utf8).write(to: liveURL)
        let hq = RecordingArchiveBackend(replicaID: "hq")
        let parserCalls = AsyncCallCounter()
        let tempParent = try makeTemporaryParent(name: "live-parser-error-temp")
        let resolver = try ArchiveTranscriptResolver(
            catalog: store.catalog,
            cas: store.cas,
            hq: hq,
            temporaryParent: tempParent
        )

        do {
            let _: ArchiveTranscriptResolution<Data> = try await resolver.withResolvedFile(
                sessionID: "live-parser-error-session",
                liveURL: liveURL
            ) { _ in
                await parserCalls.increment()
                throw TestFailure.parser
            }
            XCTFail("expected parser failure")
        } catch ArchiveTranscriptResolverError.archiveParseFailed {
            // expected
        }

        let parserCallCount = await parserCalls.value()
        let hqEvents = await hq.events()
        XCTAssertEqual(parserCallCount, 1)
        XCTAssertEqual(hqEvents, [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tempParent.path), [])
    }

    func testUnexpectedLiveParserErrorIsNormalizedWithoutLeakingPrivateReplayPath() async throws {
        let store = try makeStore(name: "live-parser-private-error")
        let liveURL = root.appendingPathComponent("live-parser-private-error.jsonl")
        try Data("live parser input".utf8).write(to: liveURL)
        let tempParent = try makeTemporaryParent(name: "live-parser-private-error-temp")
        let resolver = try ArchiveTranscriptResolver(
            catalog: store.catalog,
            cas: store.cas,
            temporaryParent: tempParent
        )
        do {
            let _: ArchiveTranscriptResolution<Data> = try await resolver.withResolvedFile(
                sessionID: "live-parser-private-error-session",
                liveURL: liveURL
            ) { selectedURL in
                XCTAssertTrue(selectedURL.path.contains(".engram-transcript-"))
                throw NSError(
                    domain: "ArchiveParserFixture",
                    code: 73,
                    userInfo: [
                        NSLocalizedDescriptionKey: "parser failed at \(selectedURL.path)",
                    ]
                )
            }
            XCTFail("expected normalized parser failure")
        } catch {
            XCTAssertTrue(
                error is ArchiveTranscriptResolverError,
                "unexpected parser errors must be normalized at the resolver boundary: \(error)"
            )
            XCTAssertFalse(error.localizedDescription.contains(tempParent.path))
        }

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tempParent.path), [])
    }

    func testLiveParserCancellationRemainsCancellationAndRemovesPrivateCopy() async throws {
        let store = try makeStore(name: "live-parser-cancel")
        let liveURL = root.appendingPathComponent("live-parser-cancel.jsonl")
        try Data("live parser input".utf8).write(to: liveURL)
        let tempParent = try makeTemporaryParent(name: "live-parser-cancel-temp")
        let resolver = try ArchiveTranscriptResolver(
            catalog: store.catalog,
            cas: store.cas,
            temporaryParent: tempParent
        )

        do {
            let _: ArchiveTranscriptResolution<Data> = try await resolver.withResolvedFile(
                sessionID: "live-parser-cancel-session",
                liveURL: liveURL
            ) { _ in
                throw CancellationError()
            }
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        }

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tempParent.path), [])
    }

    func testLocalBoundManifestReassemblesVerifiedBytesIntoOwnerOnlyTemporaryFile() async throws {
        let store = try makeStore(name: "local")
        let fixture = try addFixture(
            to: store,
            sessionID: "session-local",
            seed: "local",
            chunks: [Data("first local bytes".utf8)],
            replayPath: "projects/x/local.jsonl"
        )
        let tempParent = try makeTemporaryParent(name: "local-temp")
        let resolver = try ArchiveTranscriptResolver(
            catalog: store.catalog,
            cas: store.cas,
            temporaryParent: tempParent
        )
        let result = try await resolver.withResolvedFile(
            sessionID: fixture.sessionID,
            liveURL: root.appendingPathComponent("missing-live.jsonl")
        ) { url in
            XCTAssertNotEqual(url.path, fixture.locator)
            XCTAssertTrue(url.path.hasSuffix("/projects/x/local.jsonl"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            var info = stat()
            XCTAssertEqual(Darwin.lstat(url.path, &info), 0)
            XCTAssertEqual(info.st_mode & S_IFMT, S_IFREG)
            XCTAssertEqual(info.st_mode & 0o777, 0o600)
            for directory in [
                url.deletingLastPathComponent(),
                url.deletingLastPathComponent().deletingLastPathComponent(),
            ] {
                var directoryInfo = stat()
                XCTAssertEqual(Darwin.lstat(directory.path, &directoryInfo), 0)
                XCTAssertEqual(directoryInfo.st_mode & S_IFMT, S_IFDIR)
                XCTAssertEqual(directoryInfo.st_mode & 0o777, 0o700)
            }
            return ParsedFileProbe(
                path: url.path,
                bytes: try Data(contentsOf: url)
            )
        }

        XCTAssertEqual(result.tier, .local)
        XCTAssertEqual(result.value.bytes, fixture.raw)
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.value.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tempParent.path), [])
    }

    func testTemporaryRootIsRemovedWhenReplayDirectoryCreationFailsEarly() async throws {
        let store = try makeStore(name: "temp-early-cleanup")
        let oversizedComponent = String(repeating: "a", count: 300)
        let fixture = try addFixture(
            to: store,
            sessionID: "session-temp-early-cleanup",
            seed: "temp-early-cleanup",
            chunks: [Data("never parsed".utf8)],
            replayPath: "\(oversizedComponent)/session.jsonl"
        )
        let parserCalls = AsyncCallCounter()
        let tempParent = try makeTemporaryParent(name: "temp-early-cleanup-parent")
        let resolver = try ArchiveTranscriptResolver(
            catalog: store.catalog,
            cas: store.cas,
            temporaryParent: tempParent
        )

        do {
            let _: ArchiveTranscriptResolution<Data> = try await resolver.withResolvedFile(
                sessionID: fixture.sessionID,
                liveURL: nil
            ) { url in
                await parserCalls.increment()
                return try Data(contentsOf: url)
            }
            XCTFail("expected temporary storage failure")
        } catch ArchiveTranscriptResolverError.temporaryStorageFailure(_, let code) {
            XCTAssertEqual(code, ENAMETOOLONG)
        }

        let parserCallCount = await parserCalls.value()
        XCTAssertEqual(parserCallCount, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tempParent.path), [])
    }

    func testTemporaryParentReplacementAfterInitializationIsRejected() async throws {
        let store = try makeStore(name: "temp-parent-replaced")
        let fixture = try addFixture(
            to: store,
            sessionID: "session-temp-parent-replaced",
            seed: "temp-parent-replaced",
            chunks: [Data("must not materialize".utf8)]
        )
        let parserCalls = AsyncCallCounter()
        let tempParent = try makeTemporaryParent(name: "temp-parent-replaced-parent")
        let resolver = try ArchiveTranscriptResolver(
            catalog: store.catalog,
            cas: store.cas,
            temporaryParent: tempParent
        )
        let originalParent = root.appendingPathComponent(
            "temp-parent-replaced-original",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: tempParent, to: originalParent)
        XCTAssertEqual(Darwin.mkdir(tempParent.path, S_IRWXU), 0)

        do {
            let _: ArchiveTranscriptResolution<Data> = try await resolver.withResolvedFile(
                sessionID: fixture.sessionID,
                liveURL: nil
            ) { url in
                await parserCalls.increment()
                return try Data(contentsOf: url)
            }
            XCTFail("expected replaced temporary parent rejection")
        } catch ArchiveTranscriptResolverError.unsafeTemporaryParent {
            // expected
        }

        let parserCallCount = await parserCalls.value()
        XCTAssertEqual(parserCallCount, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tempParent.path), [])
    }

    func testZeroByteLocalTranscriptIsResolvedWithoutChunks() async throws {
        let store = try makeStore(name: "zero")
        let fixture = try addFixture(
            to: store,
            sessionID: "session-zero",
            seed: "zero",
            chunks: []
        )
        let resolver = try ArchiveTranscriptResolver(
            catalog: store.catalog,
            cas: store.cas,
            temporaryParent: try makeTemporaryParent(name: "zero-temp")
        )

        let result = try await resolver.withResolvedFile(
            sessionID: fixture.sessionID,
            liveURL: nil
        ) { try Data(contentsOf: $0) }

        XCTAssertEqual(result.tier, .local)
        XCTAssertEqual(result.value, Data())
    }

    func testMultiChunkLocalTranscriptStreamsInManifestOrder() async throws {
        let store = try makeStore(name: "multi")
        let first = Data(repeating: 0x61, count: Int(ArchiveSourceManifest.rawChunkSize))
        let second = Data("tail".utf8)
        let fixture = try addFixture(
            to: store,
            sessionID: "session-multi",
            seed: "multi",
            chunks: [first, second]
        )
        let resolver = try ArchiveTranscriptResolver(
            catalog: store.catalog,
            cas: store.cas,
            temporaryParent: try makeTemporaryParent(name: "multi-temp")
        )

        let result = try await resolver.withResolvedFile(
            sessionID: fixture.sessionID,
            liveURL: nil
        ) { try Data(contentsOf: $0) }

        XCTAssertEqual(result.tier, .local)
        XCTAssertEqual(result.value.count, first.count + second.count)
        XCTAssertEqual(result.value.prefix(16), first.prefix(16))
        XCTAssertEqual(result.value.suffix(second.count), second)
    }

    func testMissingLocalObjectFallsThroughToHQWithPersistedVerifiedReceipt() async throws {
        let store = try makeStore(name: "hq")
        let fixture = try addFixture(
            to: store,
            sessionID: "session-hq",
            seed: "hq",
            chunks: [Data("remote hq bytes".utf8)],
            publishLocalObjects: false
        )
        let hq = RecordingArchiveBackend(replicaID: "hq")
        let m1 = RecordingArchiveBackend(replicaID: "m1")
        try await persistVerifiedReceipt(for: fixture, replicaID: "hq", store: store, backend: hq)
        let resolver = try ArchiveTranscriptResolver(
            catalog: store.catalog,
            cas: store.cas,
            hq: hq,
            m1: m1,
            temporaryParent: try makeTemporaryParent(name: "hq-temp")
        )

        let result = try await resolver.withResolvedFile(
            sessionID: fixture.sessionID,
            liveURL: nil
        ) { try Data(contentsOf: $0) }

        XCTAssertEqual(result.tier, .hq)
        XCTAssertEqual(result.value, fixture.raw)
        let hqEvents = await hq.events()
        let m1Events = await m1.events()
        XCTAssertEqual(hqEvents, ["getReceipt", "getManifest", "getObject"])
        XCTAssertEqual(m1Events, [])
    }

    func testCorruptLocalObjectFallsThroughToHQ() async throws {
        let store = try makeStore(name: "local-corrupt")
        let fixture = try addFixture(
            to: store,
            sessionID: "session-local-corrupt",
            seed: "local-corrupt",
            chunks: [Data("expected bytes".utf8)]
        )
        try Data("corrupt".utf8).write(to: objectURL(store: store, digest: fixture.objectDigests[0]))
        let hq = RecordingArchiveBackend(replicaID: "hq")
        try await persistVerifiedReceipt(for: fixture, replicaID: "hq", store: store, backend: hq)
        let resolver = try ArchiveTranscriptResolver(
            catalog: store.catalog,
            cas: store.cas,
            hq: hq,
            temporaryParent: try makeTemporaryParent(name: "local-corrupt-temp")
        )

        let result = try await resolver.withResolvedFile(
            sessionID: fixture.sessionID,
            liveURL: nil
        ) { try Data(contentsOf: $0) }

        XCTAssertEqual(result.tier, .hq)
        XCTAssertEqual(result.value, fixture.raw)
    }

    func testHQTransportFailureFallsThroughToM1() async throws {
        let store = try makeStore(name: "m1-transport")
        let fixture = try addFixture(
            to: store,
            sessionID: "session-m1-transport",
            seed: "m1-transport",
            chunks: [Data("m1 bytes".utf8)],
            publishLocalObjects: false
        )
        let hq = RecordingArchiveBackend(replicaID: "hq")
        let m1 = RecordingArchiveBackend(replicaID: "m1")
        try await persistVerifiedReceipt(for: fixture, replicaID: "hq", store: store, backend: hq)
        try await persistVerifiedReceipt(for: fixture, replicaID: "m1", store: store, backend: m1)
        await hq.setFailure(.transport, operation: "getReceipt")
        let resolver = try ArchiveTranscriptResolver(
            catalog: store.catalog,
            cas: store.cas,
            hq: hq,
            m1: m1,
            temporaryParent: try makeTemporaryParent(name: "m1-transport-temp")
        )

        let result = try await resolver.withResolvedFile(
            sessionID: fixture.sessionID,
            liveURL: nil
        ) { try Data(contentsOf: $0) }

        XCTAssertEqual(result.tier, .m1)
        XCTAssertEqual(result.value, fixture.raw)
        let hqEvents = await hq.events()
        let m1Events = await m1.events()
        XCTAssertEqual(hqEvents, ["getReceipt"])
        XCTAssertEqual(m1Events, ["getReceipt", "getManifest", "getObject"])
    }

    func testRemoteRecoveryProbeUsesVerifiedHQWithoutParserOrLocalCAS() async throws {
        let store = try makeStore(name: "probe-hq")
        let fixture = try addFixture(
            to: store,
            sessionID: "session-probe-hq",
            seed: "probe-hq",
            chunks: [Data("verified remote proof".utf8)],
            publishLocalObjects: false
        )
        let hq = RecordingArchiveBackend(replicaID: "hq")
        try await persistVerifiedReceipt(for: fixture, replicaID: "hq", store: store, backend: hq)
        let temporaryParent = try makeTemporaryParent(name: "probe-hq-temp")
        let resolver = try ArchiveTranscriptResolver(
            catalog: store.catalog,
            cas: store.cas,
            hq: hq,
            temporaryParent: temporaryParent
        )
        let bindingBefore = try store.catalog.latestBinding(sessionID: fixture.sessionID)
        let receiptBefore = try store.catalog.currentVerifiedReceipt(
            manifestSHA256: fixture.manifestDigest,
            replicaID: "hq"
        )
        let rowCountsBefore = try archiveRowCounts(store: store)

        let proof = try await resolver.remoteRecoveryProbe(sessionID: fixture.sessionID)

        XCTAssertEqual(proof.tier, .hq)
        XCTAssertEqual(proof.manifestSHA256, fixture.manifestDigest)
        XCTAssertEqual(proof.wholeSourceSHA256, ArchiveV2Hash.sha256(fixture.raw))
        XCTAssertEqual(proof.rawByteCount, Int64(fixture.raw.count))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporaryParent.path), [])
        let hqEvents = await hq.events()
        XCTAssertEqual(hqEvents, ["getReceipt", "getManifest", "getObject"])
        XCTAssertEqual(try store.catalog.latestBinding(sessionID: fixture.sessionID), bindingBefore)
        XCTAssertEqual(
            try store.catalog.currentVerifiedReceipt(
                manifestSHA256: fixture.manifestDigest,
                replicaID: "hq"
            ),
            receiptBefore
        )
        XCTAssertEqual(try archiveRowCounts(store: store), rowCountsBefore)
    }

    func testRemoteRecoveryProbeFallsThroughToM1AndCancellationDoesNotAdvance() async throws {
        let store = try makeStore(name: "probe-m1")
        let fixture = try addFixture(
            to: store,
            sessionID: "session-probe-m1",
            seed: "probe-m1",
            chunks: [Data("m1 recovery proof".utf8)],
            publishLocalObjects: false
        )
        let hq = RecordingArchiveBackend(replicaID: "hq")
        let m1 = RecordingArchiveBackend(replicaID: "m1")
        try await persistVerifiedReceipt(for: fixture, replicaID: "hq", store: store, backend: hq)
        try await persistVerifiedReceipt(for: fixture, replicaID: "m1", store: store, backend: m1)
        await hq.setFailure(.transport, operation: "getReceipt")
        let resolver = try ArchiveTranscriptResolver(
            catalog: store.catalog,
            cas: store.cas,
            hq: hq,
            m1: m1,
            temporaryParent: try makeTemporaryParent(name: "probe-m1-temp")
        )

        let proof = try await resolver.remoteRecoveryProbe(sessionID: fixture.sessionID)
        XCTAssertEqual(proof.tier, .m1)
        let m1Events = await m1.events()
        XCTAssertEqual(m1Events, ["getReceipt", "getManifest", "getObject"])

        let cancelledHQ = RecordingArchiveBackend(replicaID: "hq")
        let untouchedM1 = RecordingArchiveBackend(replicaID: "m1")
        await cancelledHQ.seed(fixture: fixture)
        await untouchedM1.seed(fixture: fixture)
        await cancelledHQ.setFailure(.cancel, operation: "getReceipt")
        let cancelledResolver = try ArchiveTranscriptResolver(
            catalog: store.catalog,
            cas: store.cas,
            hq: cancelledHQ,
            m1: untouchedM1,
            temporaryParent: try makeTemporaryParent(name: "probe-cancel-temp")
        )
        do {
            _ = try await cancelledResolver.remoteRecoveryProbe(sessionID: fixture.sessionID)
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        }
        let untouchedM1Events = await untouchedM1.events()
        XCTAssertEqual(untouchedM1Events, [])
    }

    func testRemoteRecoveryProbeCanRequireOneReplica() async throws {
        let store = try makeStore(name: "probe-required-replica")
        let fixture = try addFixture(
            to: store,
            sessionID: "session-probe-required-replica",
            seed: "probe-required-replica",
            chunks: [Data("required replica recovery proof".utf8)],
            publishLocalObjects: false
        )
        let hq = RecordingArchiveBackend(replicaID: "hq")
        let m1 = RecordingArchiveBackend(replicaID: "m1")
        try await persistVerifiedReceipt(for: fixture, replicaID: "hq", store: store, backend: hq)
        try await persistVerifiedReceipt(for: fixture, replicaID: "m1", store: store, backend: m1)
        let resolver = try ArchiveTranscriptResolver(
            catalog: store.catalog,
            cas: store.cas,
            hq: hq,
            m1: m1,
            temporaryParent: try makeTemporaryParent(name: "probe-required-replica-temp")
        )

        let proof = try await resolver.remoteRecoveryProbe(
            sessionID: fixture.sessionID,
            replicaID: "m1"
        )

        XCTAssertEqual(proof.tier, .m1)
        XCTAssertEqual(proof.rawByteCount, Int64(fixture.raw.count))
        let hqEvents = await hq.events()
        let m1Events = await m1.events()
        XCTAssertEqual(hqEvents, [])
        XCTAssertEqual(m1Events, ["getReceipt", "getManifest", "getObject"])
    }

    func testProductionRecoveryDrillRecordsLeaseAndCancellationPreservesPriorState() async throws {
        let successStore = try makeStore(name: "production-drill-success")
        let successFixture = try addFixture(
            to: successStore,
            sessionID: "production-drill-success",
            seed: "production-drill-success",
            chunks: [Data("production drill success".utf8)],
            publishLocalObjects: false
        )
        let successHQ = RecordingArchiveBackend(replicaID: "hq")
        try await persistVerifiedReceipt(
            for: successFixture,
            replicaID: "hq",
            store: successStore,
            backend: successHQ
        )
        let successResolver = try ArchiveTranscriptResolver(
            catalog: successStore.catalog,
            cas: successStore.cas,
            hq: successHQ,
            temporaryParent: try makeTemporaryParent(name: "production-drill-success-temp")
        )

        let lease = try await ArchiveV2ServiceCoordinator.executeRecoveryDrill(
            catalog: successStore.catalog,
            transcriptResolver: successResolver,
            replicaID: "hq",
            timeout: .seconds(1)
        )

        XCTAssertEqual(lease.manifestSHA256, successFixture.manifestDigest)
        XCTAssertEqual(lease.verifiedBytes, Int64(successFixture.raw.count))
        XCTAssertEqual(try successStore.catalog.recoveryLease(replicaID: "hq"), lease)
        XCTAssertNotNil(
            try successStore.catalog.archiveCursorCheckpoint(for: .recoveryDrillHQ)
        )

        let cancelledStore = try makeStore(name: "production-drill-cancelled")
        let cancelledFixture = try addFixture(
            to: cancelledStore,
            sessionID: "production-drill-cancelled",
            seed: "production-drill-cancelled",
            chunks: [Data("production drill cancellation".utf8)],
            publishLocalObjects: false
        )
        let cancelledHQ = RecordingArchiveBackend(replicaID: "hq")
        try await persistVerifiedReceipt(
            for: cancelledFixture,
            replicaID: "hq",
            store: cancelledStore,
            backend: cancelledHQ
        )
        let priorLease = try cancelledStore.catalog.recordRecoveryLease(
            replicaID: "hq",
            manifestSHA256: cancelledFixture.manifestDigest,
            verifiedAt: "2026-07-11T00:10:00.000Z",
            verifiedBytes: Int64(cancelledFixture.raw.count)
        )
        await cancelledHQ.setFailure(.cancel, operation: "getReceipt")
        let cancelledResolver = try ArchiveTranscriptResolver(
            catalog: cancelledStore.catalog,
            cas: cancelledStore.cas,
            hq: cancelledHQ,
            temporaryParent: try makeTemporaryParent(name: "production-drill-cancelled-temp")
        )

        do {
            _ = try await ArchiveV2ServiceCoordinator.executeRecoveryDrill(
                catalog: cancelledStore.catalog,
                transcriptResolver: cancelledResolver,
                replicaID: "hq",
                timeout: .seconds(1)
            )
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        }
        XCTAssertEqual(try cancelledStore.catalog.recoveryLease(replicaID: "hq"), priorLease)
        XCTAssertNil(
            try cancelledStore.catalog.archiveCursorCheckpoint(for: .recoveryDrillHQ)
        )
    }

    func testRemoteRecoveryProbeChecksCleanupBeforeProofAndDoesNotFallThrough() async throws {
        let store = try makeStore(name: "probe-cleanup")
        let fixture = try addFixture(
            to: store,
            sessionID: "session-probe-cleanup",
            seed: "probe-cleanup",
            chunks: [Data("cleanup must be proven".utf8)],
            publishLocalObjects: false
        )
        let hq = RecordingArchiveBackend(replicaID: "hq")
        let m1 = RecordingArchiveBackend(replicaID: "m1")
        try await persistVerifiedReceipt(for: fixture, replicaID: "hq", store: store, backend: hq)
        try await persistVerifiedReceipt(for: fixture, replicaID: "m1", store: store, backend: m1)
        let temporaryParent = try makeTemporaryParent(name: "probe-cleanup-temp")
        let resolver = try ArchiveTranscriptResolver(
            catalog: store.catalog,
            cas: store.cas,
            hq: hq,
            m1: m1,
            temporaryParent: temporaryParent,
            testHooks: ArchiveTranscriptResolverTestHooks(
                remoteReplaySelected: { fileURL in
                    XCTAssertEqual(Darwin.chflags(fileURL.path, UInt32(UF_IMMUTABLE)), 0)
                }
            )
        )

        do {
            _ = try await resolver.remoteRecoveryProbe(sessionID: fixture.sessionID)
            XCTFail("expected checked cleanup failure")
        } catch ArchiveTranscriptResolverError.temporaryStorageFailure(let operation, _) {
            XCTAssertTrue(operation.hasPrefix("cleanup"))
        }
        let m1Events = await m1.events()
        XCTAssertEqual(m1Events, [])
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: temporaryParent.path).isEmpty)
        clearImmutableFlagsAndContents(at: temporaryParent)
    }

    func testRemoteRecoveryProbeCancellationAfterSelectionCleansAndDoesNotFallThrough() async throws {
        let store = try makeStore(name: "probe-post-selection-cancel")
        let fixture = try addFixture(
            to: store,
            sessionID: "session-probe-post-selection-cancel",
            seed: "probe-post-selection-cancel",
            chunks: [Data("cancel after selection".utf8)],
            publishLocalObjects: false
        )
        let hq = RecordingArchiveBackend(replicaID: "hq")
        let m1 = RecordingArchiveBackend(replicaID: "m1")
        try await persistVerifiedReceipt(for: fixture, replicaID: "hq", store: store, backend: hq)
        try await persistVerifiedReceipt(for: fixture, replicaID: "m1", store: store, backend: m1)
        let temporaryParent = try makeTemporaryParent(name: "probe-post-selection-cancel-temp")
        let resolver = try ArchiveTranscriptResolver(
            catalog: store.catalog,
            cas: store.cas,
            hq: hq,
            m1: m1,
            temporaryParent: temporaryParent,
            testHooks: ArchiveTranscriptResolverTestHooks(
                remoteReplaySelected: { _ in throw CancellationError() }
            )
        )

        do {
            _ = try await resolver.remoteRecoveryProbe(sessionID: fixture.sessionID)
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        }
        let m1Events = await m1.events()
        XCTAssertEqual(m1Events, [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporaryParent.path), [])
    }

    func testAbsentHQBackendFallsThroughToM1() async throws {
        let store = try makeStore(name: "m1-hq-absent")
        let fixture = try addFixture(
            to: store,
            sessionID: "session-m1-hq-absent",
            seed: "m1-hq-absent",
            chunks: [Data("m1 survives absent hq".utf8)],
            publishLocalObjects: false
        )
        let hq = RecordingArchiveBackend(replicaID: "hq")
        let m1 = RecordingArchiveBackend(replicaID: "m1")
        try await persistVerifiedReceipt(for: fixture, replicaID: "hq", store: store, backend: hq)
        try await persistVerifiedReceipt(for: fixture, replicaID: "m1", store: store, backend: m1)
        let resolver = try ArchiveTranscriptResolver(
            catalog: store.catalog,
            cas: store.cas,
            hq: nil,
            m1: m1,
            temporaryParent: try makeTemporaryParent(name: "m1-hq-absent-temp")
        )

        let result = try await resolver.withResolvedFile(
            sessionID: fixture.sessionID,
            liveURL: nil
        ) { try Data(contentsOf: $0) }

        XCTAssertEqual(result.tier, .m1)
        XCTAssertEqual(result.value, fixture.raw)
        let hqEvents = await hq.events()
        let m1Events = await m1.events()
        XCTAssertEqual(hqEvents, [])
        XCTAssertEqual(m1Events, ["getReceipt", "getManifest", "getObject"])
    }

    func testHQIntegrityFailureFallsThroughToM1() async throws {
        let store = try makeStore(name: "m1-integrity")
        let fixture = try addFixture(
            to: store,
            sessionID: "session-m1-integrity",
            seed: "m1-integrity",
            chunks: [Data("verified m1 bytes".utf8)],
            publishLocalObjects: false
        )
        let hq = RecordingArchiveBackend(replicaID: "hq")
        let m1 = RecordingArchiveBackend(replicaID: "m1")
        try await persistVerifiedReceipt(for: fixture, replicaID: "hq", store: store, backend: hq)
        try await persistVerifiedReceipt(for: fixture, replicaID: "m1", store: store, backend: m1)
        await hq.setObject(Data("bad object".utf8), digest: fixture.objectDigests[0])
        let resolver = try ArchiveTranscriptResolver(
            catalog: store.catalog,
            cas: store.cas,
            hq: hq,
            m1: m1,
            temporaryParent: try makeTemporaryParent(name: "m1-integrity-temp")
        )

        let result = try await resolver.withResolvedFile(
            sessionID: fixture.sessionID,
            liveURL: nil
        ) { try Data(contentsOf: $0) }

        XCTAssertEqual(result.tier, .m1)
        XCTAssertEqual(result.value, fixture.raw)
    }

    func testHQOnlineReceiptMismatchFallsThroughToM1() async throws {
        let store = try makeStore(name: "m1-receipt-integrity")
        let fixture = try addFixture(
            to: store,
            sessionID: "session-m1-receipt-integrity",
            seed: "m1-receipt-integrity",
            chunks: [Data("receipt-verified m1 bytes".utf8)],
            publishLocalObjects: false
        )
        let hq = RecordingArchiveBackend(replicaID: "hq")
        let m1 = RecordingArchiveBackend(replicaID: "m1")
        try await persistVerifiedReceipt(for: fixture, replicaID: "hq", store: store, backend: hq)
        try await persistVerifiedReceipt(for: fixture, replicaID: "m1", store: store, backend: m1)
        await hq.setReceipt(Data("not the persisted receipt".utf8), digest: fixture.manifestDigest)
        let resolver = try ArchiveTranscriptResolver(
            catalog: store.catalog,
            cas: store.cas,
            hq: hq,
            m1: m1,
            temporaryParent: try makeTemporaryParent(name: "m1-receipt-integrity-temp")
        )

        let result = try await resolver.withResolvedFile(
            sessionID: fixture.sessionID,
            liveURL: nil
        ) { try Data(contentsOf: $0) }

        XCTAssertEqual(result.tier, .m1)
        XCTAssertEqual(result.value, fixture.raw)
        let hqEvents = await hq.events()
        XCTAssertEqual(hqEvents, ["getReceipt"])
    }

    func testCorruptPersistedHQReceiptDoesNotBlockVerifiedM1() async throws {
        let store = try makeStore(name: "m1-persisted-receipt-corrupt")
        let fixture = try addFixture(
            to: store,
            sessionID: "session-m1-persisted-receipt-corrupt",
            seed: "m1-persisted-receipt-corrupt",
            chunks: [Data("m1 survives persisted hq corruption".utf8)],
            publishLocalObjects: false
        )
        let hq = RecordingArchiveBackend(replicaID: "hq")
        let m1 = RecordingArchiveBackend(replicaID: "m1")
        try await persistVerifiedReceipt(for: fixture, replicaID: "hq", store: store, backend: hq)
        try await persistVerifiedReceipt(for: fixture, replicaID: "m1", store: store, backend: m1)
        try corruptPersistedReceipt(
            store: store,
            manifestSHA256: fixture.manifestDigest,
            replicaID: "hq"
        )
        let resolver = try ArchiveTranscriptResolver(
            catalog: store.catalog,
            cas: store.cas,
            hq: hq,
            m1: m1,
            temporaryParent: try makeTemporaryParent(name: "m1-persisted-receipt-corrupt-temp")
        )

        let result = try await resolver.withResolvedFile(
            sessionID: fixture.sessionID,
            liveURL: nil
        ) { try Data(contentsOf: $0) }

        XCTAssertEqual(result.tier, .m1)
        XCTAssertEqual(result.value, fixture.raw)
        let hqEvents = await hq.events()
        let m1Events = await m1.events()
        XCTAssertEqual(hqEvents, [])
        XCTAssertEqual(m1Events, ["getReceipt", "getManifest", "getObject"])
    }

    func testParserErrorDoesNotFallThroughAndTemporaryFileIsRemoved() async throws {
        let store = try makeStore(name: "parser-error")
        let fixture = try addFixture(
            to: store,
            sessionID: "session-parser-error",
            seed: "parser-error",
            chunks: [Data("parse me".utf8)]
        )
        let hq = RecordingArchiveBackend(replicaID: "hq")
        let parserCalls = AsyncCallCounter()
        let tempParent = try makeTemporaryParent(name: "parser-error-temp")
        let resolver = try ArchiveTranscriptResolver(
            catalog: store.catalog,
            cas: store.cas,
            hq: hq,
            temporaryParent: tempParent
        )

        do {
            let _: ArchiveTranscriptResolution<Data> = try await resolver.withResolvedFile(
                sessionID: fixture.sessionID,
                liveURL: nil
            ) { _ in
                await parserCalls.increment()
                throw TestFailure.parser
            }
            XCTFail("expected parser failure")
        } catch ArchiveTranscriptResolverError.archiveParseFailed {
            // expected
        }

        let parserCallCount = await parserCalls.value()
        let hqEvents = await hq.events()
        XCTAssertEqual(parserCallCount, 1)
        XCTAssertEqual(hqEvents, [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tempParent.path), [])
    }

    func testCleanupFailureAfterParserSuccessIsReportedAsTemporaryStorageFailure() async throws {
        let store = try makeStore(name: "cleanup-failure")
        let fixture = try addFixture(
            to: store,
            sessionID: "session-cleanup-failure",
            seed: "cleanup-failure",
            chunks: [Data("parsed before cleanup".utf8)]
        )
        let tempParent = try makeTemporaryParent(name: "cleanup-failure-temp")
        let resolver = try ArchiveTranscriptResolver(
            catalog: store.catalog,
            cas: store.cas,
            temporaryParent: tempParent
        )

        do {
            let _: ArchiveTranscriptResolution<Data> = try await resolver.withResolvedFile(
                sessionID: fixture.sessionID,
                liveURL: nil
            ) { url in
                let bytes = try Data(contentsOf: url)
                XCTAssertEqual(
                    Darwin.chflags(url.path, UInt32(UF_IMMUTABLE)),
                    0
                )
                return bytes
            }
            XCTFail("expected checked cleanup failure")
        } catch ArchiveTranscriptResolverError.temporaryStorageFailure(
            let operation,
            let code
        ) {
            XCTAssertTrue(operation.hasPrefix("cleanup"))
            XCTAssertTrue(code == EPERM || code == EACCES || code == EIO)
        }

        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: tempParent.path).isEmpty)
        clearImmutableFlagsAndContents(at: tempParent)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tempParent.path), [])
    }

    func testRemoteParserErrorRunsOnceAndNeverFallsThroughToM1() async throws {
        let store = try makeStore(name: "remote-parser-error")
        let fixture = try addFixture(
            to: store,
            sessionID: "session-remote-parser-error",
            seed: "remote-parser-error",
            chunks: [Data("remote parse me".utf8)],
            publishLocalObjects: false
        )
        let hq = RecordingArchiveBackend(replicaID: "hq")
        let m1 = RecordingArchiveBackend(replicaID: "m1")
        try await persistVerifiedReceipt(for: fixture, replicaID: "hq", store: store, backend: hq)
        try await persistVerifiedReceipt(for: fixture, replicaID: "m1", store: store, backend: m1)
        let parserCalls = AsyncCallCounter()
        let tempParent = try makeTemporaryParent(name: "remote-parser-error-temp")
        let resolver = try ArchiveTranscriptResolver(
            catalog: store.catalog,
            cas: store.cas,
            hq: hq,
            m1: m1,
            temporaryParent: tempParent
        )

        do {
            let _: ArchiveTranscriptResolution<Data> = try await resolver.withResolvedFile(
                sessionID: fixture.sessionID,
                liveURL: nil
            ) { _ in
                await parserCalls.increment()
                throw TestFailure.parser
            }
            XCTFail("expected parser failure")
        } catch ArchiveTranscriptResolverError.archiveParseFailed {
            // expected
        }

        let parserCallCount = await parserCalls.value()
        let m1Events = await m1.events()
        XCTAssertEqual(parserCallCount, 1)
        XCTAssertEqual(m1Events, [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tempParent.path), [])
    }

    func testCancellationFromHQStopsBeforeM1AndParser() async throws {
        let store = try makeStore(name: "cancel")
        let fixture = try addFixture(
            to: store,
            sessionID: "session-cancel",
            seed: "cancel",
            chunks: [Data("cancel bytes".utf8)],
            publishLocalObjects: false
        )
        let hq = RecordingArchiveBackend(replicaID: "hq")
        let m1 = RecordingArchiveBackend(replicaID: "m1")
        try await persistVerifiedReceipt(for: fixture, replicaID: "hq", store: store, backend: hq)
        try await persistVerifiedReceipt(for: fixture, replicaID: "m1", store: store, backend: m1)
        await hq.setFailure(.cancel, operation: "getObject")
        let parserCalls = AsyncCallCounter()
        let tempParent = try makeTemporaryParent(name: "cancel-temp")
        let resolver = try ArchiveTranscriptResolver(
            catalog: store.catalog,
            cas: store.cas,
            hq: hq,
            m1: m1,
            temporaryParent: tempParent
        )

        do {
            let _: ArchiveTranscriptResolution<Data> = try await resolver.withResolvedFile(
                sessionID: fixture.sessionID,
                liveURL: nil
            ) { url in
                await parserCalls.increment()
                return try Data(contentsOf: url)
            }
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        }

        let parserCallCount = await parserCalls.value()
        let m1Events = await m1.events()
        XCTAssertEqual(parserCallCount, 0)
        XCTAssertEqual(m1Events, [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tempParent.path), [])
    }

    func testLivePermissionFailureDoesNotFallThrough() async throws {
        let store = try makeStore(name: "permission")
        let liveURL = root.appendingPathComponent("permission.jsonl")
        try Data("secret".utf8).write(to: liveURL)
        XCTAssertEqual(Darwin.chmod(liveURL.path, 0), 0)
        defer { _ = Darwin.chmod(liveURL.path, S_IRUSR | S_IWUSR) }
        let hq = RecordingArchiveBackend(replicaID: "hq")
        let resolver = try ArchiveTranscriptResolver(
            catalog: store.catalog,
            cas: store.cas,
            hq: hq,
            temporaryParent: try makeTemporaryParent(name: "permission-temp")
        )

        do {
            let _: ArchiveTranscriptResolution<Data> = try await resolver.withResolvedFile(
                sessionID: "permission",
                liveURL: liveURL
            ) { try Data(contentsOf: $0) }
            XCTFail("expected permission failure")
        } catch ArchiveTranscriptResolverError.liveUnavailable(let code) {
            XCTAssertTrue(code == EACCES || code == EPERM)
        }
        let hqEvents = await hq.events()
        XCTAssertEqual(hqEvents, [])
    }

    func testRemoteWithoutPersistedVerifiedReceiptIsNeverCalled() async throws {
        let store = try makeStore(name: "no-receipt")
        let fixture = try addFixture(
            to: store,
            sessionID: "session-no-receipt",
            seed: "no-receipt",
            chunks: [Data("remote only".utf8)],
            publishLocalObjects: false
        )
        let hq = RecordingArchiveBackend(replicaID: "hq")
        await hq.seed(fixture: fixture)
        let resolver = try ArchiveTranscriptResolver(
            catalog: store.catalog,
            cas: store.cas,
            hq: hq,
            temporaryParent: try makeTemporaryParent(name: "no-receipt-temp")
        )

        do {
            let _: ArchiveTranscriptResolution<Data> = try await resolver.withResolvedFile(
                sessionID: fixture.sessionID,
                liveURL: nil
            ) { try Data(contentsOf: $0) }
            XCTFail("expected archive unavailable")
        } catch ArchiveTranscriptResolverError.archiveUnavailable {
            // expected
        }
        let hqEvents = await hq.events()
        XCTAssertEqual(hqEvents, [])
    }

    func testMissingRemoteObjectIsRejectedAndPartialTemporaryFileIsRemoved() async throws {
        let store = try makeStore(name: "remote-missing")
        let fixture = try addFixture(
            to: store,
            sessionID: "session-remote-missing",
            seed: "remote-missing",
            chunks: [Data("must not parse partial".utf8)],
            publishLocalObjects: false
        )
        let hq = RecordingArchiveBackend(replicaID: "hq")
        try await persistVerifiedReceipt(for: fixture, replicaID: "hq", store: store, backend: hq)
        await hq.removeObject(digest: fixture.objectDigests[0])
        let parserCalls = AsyncCallCounter()
        let tempParent = try makeTemporaryParent(name: "remote-missing-temp")
        let resolver = try ArchiveTranscriptResolver(
            catalog: store.catalog,
            cas: store.cas,
            hq: hq,
            temporaryParent: tempParent
        )

        do {
            let _: ArchiveTranscriptResolution<Data> = try await resolver.withResolvedFile(
                sessionID: fixture.sessionID,
                liveURL: nil
            ) { url in
                await parserCalls.increment()
                return try Data(contentsOf: url)
            }
            XCTFail("expected archive unavailable")
        } catch ArchiveTranscriptResolverError.archiveUnavailable {
            // expected
        }

        let parserCallCount = await parserCalls.value()
        XCTAssertEqual(parserCallCount, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tempParent.path), [])
    }

    func testSameLengthRemoteChunkDigestMismatchIsReportedAsArchiveCorrupt() async throws {
        let store = try makeStore(name: "remote-chunk-corrupt")
        let fixture = try addFixture(
            to: store,
            sessionID: "session-remote-chunk-corrupt",
            seed: "remote-chunk-corrupt",
            chunks: [Data("expected remote bytes".utf8)],
            publishLocalObjects: false
        )
        let hq = RecordingArchiveBackend(replicaID: "hq")
        try await persistVerifiedReceipt(for: fixture, replicaID: "hq", store: store, backend: hq)
        let sameLengthCorruption = Data(repeating: 0x7f, count: fixture.raw.count)
        XCTAssertNotEqual(ArchiveV2Hash.sha256(sameLengthCorruption), fixture.objectDigests[0])
        await hq.setObject(sameLengthCorruption, digest: fixture.objectDigests[0])
        let parserCalls = AsyncCallCounter()
        let tempParent = try makeTemporaryParent(name: "remote-chunk-corrupt-temp")
        let resolver = try ArchiveTranscriptResolver(
            catalog: store.catalog,
            cas: store.cas,
            hq: hq,
            temporaryParent: tempParent
        )

        do {
            let _: ArchiveTranscriptResolution<Data> = try await resolver.withResolvedFile(
                sessionID: fixture.sessionID,
                liveURL: nil
            ) { url in
                await parserCalls.increment()
                return try Data(contentsOf: url)
            }
            XCTFail("expected archive corruption")
        } catch ArchiveTranscriptResolverError.archiveCorrupt {
            // expected
        }

        let parserCallCount = await parserCalls.value()
        XCTAssertEqual(parserCallCount, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tempParent.path), [])
    }

    func testMalformedBackendResponseIsReportedAsArchiveCorrupt() async throws {
        let store = try makeStore(name: "remote-protocol-corrupt")
        let fixture = try addFixture(
            to: store,
            sessionID: "session-remote-protocol-corrupt",
            seed: "remote-protocol-corrupt",
            chunks: [Data("remote protocol bytes".utf8)],
            publishLocalObjects: false
        )
        let hq = RecordingArchiveBackend(replicaID: "hq")
        try await persistVerifiedReceipt(for: fixture, replicaID: "hq", store: store, backend: hq)
        await hq.setFailure(.protocolCorrupt, operation: "getReceipt")
        let resolver = try ArchiveTranscriptResolver(
            catalog: store.catalog,
            cas: store.cas,
            hq: hq,
            temporaryParent: try makeTemporaryParent(name: "remote-protocol-corrupt-temp")
        )

        do {
            let _: ArchiveTranscriptResolution<Data> = try await resolver.withResolvedFile(
                sessionID: fixture.sessionID,
                liveURL: nil
            ) { try Data(contentsOf: $0) }
            XCTFail("expected archive corruption")
        } catch ArchiveTranscriptResolverError.archiveCorrupt {
            // expected
        }
    }

    func testWholeSourceDigestMismatchIsReportedAsArchiveCorrupt() async throws {
        let store = try makeStore(name: "whole-source-corrupt")
        let wrongWholeDigest = ArchiveV2Hash.sha256(Data("different whole source".utf8))
        let fixture = try addFixture(
            to: store,
            sessionID: "session-whole-source-corrupt",
            seed: "whole-source-corrupt",
            chunks: [Data("correct chunk bytes".utf8)],
            wholeSourceSHA256: wrongWholeDigest
        )
        XCTAssertNotEqual(ArchiveV2Hash.sha256(fixture.raw), wrongWholeDigest)
        let parserCalls = AsyncCallCounter()
        let tempParent = try makeTemporaryParent(name: "whole-source-corrupt-temp")
        let resolver = try ArchiveTranscriptResolver(
            catalog: store.catalog,
            cas: store.cas,
            temporaryParent: tempParent
        )

        do {
            let _: ArchiveTranscriptResolution<Data> = try await resolver.withResolvedFile(
                sessionID: fixture.sessionID,
                liveURL: nil
            ) { url in
                await parserCalls.increment()
                return try Data(contentsOf: url)
            }
            XCTFail("expected archive corruption")
        } catch ArchiveTranscriptResolverError.archiveCorrupt {
            // expected
        }

        let parserCallCount = await parserCalls.value()
        XCTAssertEqual(parserCallCount, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tempParent.path), [])
    }

    func testLatestBindingIsLockedBeforeTierSelection() async throws {
        let store = try makeStore(name: "latest")
        _ = try addFixture(
            to: store,
            sessionID: "session-latest",
            seed: "older",
            chunks: [Data("older".utf8)],
            boundAt: "2026-07-11T00:00:00.000Z"
        )
        let latest = try addFixture(
            to: store,
            sessionID: "session-latest",
            seed: "newer",
            chunks: [Data("newer".utf8)],
            boundAt: "2026-07-11T00:00:01.000Z"
        )
        let resolver = try ArchiveTranscriptResolver(
            catalog: store.catalog,
            cas: store.cas,
            temporaryParent: try makeTemporaryParent(name: "latest-temp")
        )

        let result = try await resolver.withResolvedFile(
            sessionID: "session-latest",
            liveURL: nil
        ) { try Data(contentsOf: $0) }

        XCTAssertEqual(result.tier, .local)
        XCTAssertEqual(result.value, latest.raw)
    }

    func testTamperedLatestBindingIsReportedAsArchiveCorrupt() async throws {
        let store = try makeStore(name: "binding-corrupt")
        let fixture = try addFixture(
            to: store,
            sessionID: "session-binding-corrupt",
            seed: "binding-corrupt",
            chunks: [Data("binding bytes".utf8)]
        )
        try corruptBoundManifestBytes(
            store: store,
            manifestSHA256: fixture.manifestDigest
        )
        let parserCalls = AsyncCallCounter()
        let resolver = try ArchiveTranscriptResolver(
            catalog: store.catalog,
            cas: store.cas,
            temporaryParent: try makeTemporaryParent(name: "binding-corrupt-temp")
        )

        do {
            let _: ArchiveTranscriptResolution<Data> = try await resolver.withResolvedFile(
                sessionID: fixture.sessionID,
                liveURL: nil
            ) { url in
                await parserCalls.increment()
                return try Data(contentsOf: url)
            }
            XCTFail("expected corrupt binding")
        } catch ArchiveTranscriptResolverError.archiveCorrupt {
            // expected
        }

        let parserCallCount = await parserCalls.value()
        XCTAssertEqual(parserCallCount, 0)
    }

    func testCaptureReadFailureIsReportedAsArchiveUnavailable() async throws {
        let store = try makeStore(name: "capture-read-unavailable")
        let fixture = try addFixture(
            to: store,
            sessionID: "session-capture-read-unavailable",
            seed: "capture-read-unavailable",
            chunks: [Data("capture bytes".utf8)]
        )
        let parserCalls = AsyncCallCounter()
        let resolver = try ArchiveTranscriptResolver(
            catalog: store.catalog,
            cas: store.cas,
            temporaryParent: try makeTemporaryParent(name: "capture-read-unavailable-temp"),
            testHooks: ArchiveTranscriptResolverTestHooks(
                capture: { _ in throw TestFailure.catalogRead }
            )
        )

        do {
            let _: ArchiveTranscriptResolution<Data> = try await resolver.withResolvedFile(
                sessionID: fixture.sessionID,
                liveURL: nil
            ) { url in
                await parserCalls.increment()
                return try Data(contentsOf: url)
            }
            XCTFail("expected archive unavailable")
        } catch ArchiveTranscriptResolverError.archiveUnavailable {
            // expected
        }

        let parserCallCount = await parserCalls.value()
        XCTAssertEqual(parserCallCount, 0)
    }

    func testBindingRemainsLockedWhileAsyncRemoteFallbackIsPaused() async throws {
        let store = try makeStore(name: "binding-locked-async")
        let locked = try addFixture(
            to: store,
            sessionID: "session-binding-locked-async",
            seed: "binding-locked-async-older",
            chunks: [Data("locked older bytes".utf8)],
            publishLocalObjects: false,
            boundAt: "2026-07-11T00:00:00.000Z"
        )
        let hq = RecordingArchiveBackend(replicaID: "hq")
        try await persistVerifiedReceipt(for: locked, replicaID: "hq", store: store, backend: hq)
        await hq.pauseNext("getReceipt")
        let resolver = try ArchiveTranscriptResolver(
            catalog: store.catalog,
            cas: store.cas,
            hq: hq,
            temporaryParent: try makeTemporaryParent(name: "binding-locked-async-temp")
        )

        let resolutionTask = Task {
            try await resolver.withResolvedFile(
                sessionID: locked.sessionID,
                liveURL: nil
            ) { try Data(contentsOf: $0) }
        }
        await hq.waitUntilPaused()
        let newer = try addFixture(
            to: store,
            sessionID: locked.sessionID,
            seed: "binding-locked-async-newer",
            chunks: [Data("newer bytes".utf8)],
            boundAt: "2026-07-11T00:00:01.000Z"
        )
        await hq.resumePausedOperation()

        let result = try await resolutionTask.value
        XCTAssertEqual(result.tier, .hq)
        XCTAssertEqual(result.value, locked.raw)
        XCTAssertEqual(
            try store.catalog.latestBinding(sessionID: locked.sessionID)?.manifestSHA256,
            newer.manifestDigest
        )
        let hqEvents = await hq.events()
        XCTAssertEqual(hqEvents, ["getReceipt", "getManifest", "getObject"])
    }

    private struct Store {
        let root: URL
        let cas: ImmutableArchiveCAS
        let catalog: ArchiveCatalog
    }

    fileprivate struct Fixture: Sendable {
        let sessionID: String
        let locator: String
        let raw: Data
        let chunks: [Data]
        let objectDigests: [String]
        let manifestBytes: Data
        let manifestDigest: String
        let binding: ArchiveBinding
    }

    private func makeStore(name: String) throws -> Store {
        let storeRoot = root.appendingPathComponent(name, isDirectory: true)
        let cas = try ImmutableArchiveCAS(root: storeRoot)
        let catalog = try ArchiveCatalog(
            root: storeRoot,
            machineID: "11111111-1111-4111-8111-111111111111"
        )
        try catalog.migrate()
        return Store(root: storeRoot, cas: cas, catalog: catalog)
    }

    private func makeTemporaryParent(name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        XCTAssertEqual(Darwin.mkdir(url.path, S_IRWXU), 0)
        return url
    }

    private func addFixture(
        to store: Store,
        sessionID: String,
        seed: String,
        source: String = "codex",
        chunks: [Data],
        publishLocalObjects: Bool = true,
        publishLocalBoundManifest: Bool = true,
        boundAt: String = "2026-07-11T00:00:00.000Z",
        replayPath: String? = nil,
        wholeSourceSHA256: String? = nil
    ) throws -> Fixture {
        let raw = chunks.reduce(into: Data()) { $0.append($1) }
        let wholeDigest = wholeSourceSHA256 ?? ArchiveV2Hash.sha256(raw)
        let objectDigests = chunks.map(ArchiveV2Hash.sha256)
        if publishLocalObjects {
            for (chunk, digest) in zip(chunks, objectDigests) {
                _ = try store.cas.publishObject(raw: chunk, expectedSHA256: digest)
            }
        }
        let captureID = ArchiveV2Hash.sha256(Data("capture-\(seed)".utf8))
        let locator = "/audit/original/\(seed).jsonl"
        let generation = try ArchiveSourceGeneration(
            device: 1,
            inode: Int64(abs(seed.hashValue % 1_000_000) + 1),
            size: Int64(raw.count),
            mtimeNs: 3,
            ctimeNs: 4,
            mode: Int64(S_IFREG | 0o600)
        )
        let references = try zip(chunks.indices, zip(chunks, objectDigests)).map {
            try ArchiveChunkReference(
                ordinal: $0.0,
                rawSHA256: $0.1.1,
                rawByteCount: Int64($0.1.0.count)
            )
        }
        let replay = try ArchiveReplayLayout(
            strategy: .singleFile,
            relativePaths: [replayPath ?? "sessions/\(seed).jsonl"]
        )
        let unbound = try ArchiveSourceManifest(
            captureID: captureID,
            machineID: "11111111-1111-4111-8111-111111111111",
            source: source,
            locator: locator,
            sessionID: nil,
            capturedAt: "2026-07-11T00:00:00.000Z",
            generation: generation,
            wholeSourceSHA256: wholeDigest,
            rawByteCount: Int64(raw.count),
            chunks: references,
            replayLayout: replay
        )
        let unboundBytes = try ArchiveCanonicalJSON.encode(unbound)
        _ = try store.catalog.recordCapture(canonicalManifestBytes: unboundBytes)
        let bound = try ArchiveSourceManifest(
            captureID: captureID,
            machineID: "11111111-1111-4111-8111-111111111111",
            source: source,
            locator: locator,
            sessionID: sessionID,
            capturedAt: "2026-07-11T00:00:00.000Z",
            generation: generation,
            wholeSourceSHA256: wholeDigest,
            rawByteCount: Int64(raw.count),
            chunks: references,
            replayLayout: replay
        )
        let manifestBytes = try ArchiveCanonicalJSON.encode(bound)
        let manifestDigest = ArchiveV2Hash.sha256(manifestBytes)
        if publishLocalBoundManifest {
            _ = try store.cas.publishManifest(manifestBytes, expectedSHA256: manifestDigest)
        }
        let binding = try store.catalog.bind(
            canonicalManifestBytes: manifestBytes,
            sourceSnapshotFingerprint: ArchiveV2Hash.sha256(Data("snapshot-\(seed)".utf8)),
            boundAt: boundAt
        )
        return Fixture(
            sessionID: sessionID,
            locator: locator,
            raw: raw,
            chunks: chunks,
            objectDigests: objectDigests,
            manifestBytes: manifestBytes,
            manifestDigest: manifestDigest,
            binding: binding
        )
    }

    private func persistVerifiedReceipt(
        for fixture: Fixture,
        replicaID: String,
        store: Store,
        backend: RecordingArchiveBackend
    ) async throws {
        if try store.catalog.latestBinding(sessionID: fixture.sessionID)?.remoteEligibility == .unknown {
            _ = try store.catalog.setRemotePolicySnapshot(
                manifestSHA256: fixture.manifestDigest,
                projectRootSnapshot: "/tmp/project",
                eligibility: .eligible
            )
        }
        _ = try store.catalog.reconcileEligibleReplicaRows(
            updatedAt: "2026-07-11T00:01:00.000Z"
        )
        let claims = try store.catalog.claimReplicaWork(
            limit: 1,
            now: "2026-07-11T00:02:00.000Z"
        )
        let claim = try XCTUnwrap(claims.first { $0.replicaID == replicaID })
        XCTAssertTrue(try store.catalog.transitionReplicaClaim(
            claim,
            from: .uploadingObjects,
            to: .uploadingManifest,
            updatedAt: "2026-07-11T00:03:00.000Z"
        ))
        XCTAssertTrue(try store.catalog.transitionReplicaClaim(
            claim,
            from: .uploadingManifest,
            to: .requestingReceipt,
            updatedAt: "2026-07-11T00:04:00.000Z"
        ))
        XCTAssertTrue(try store.catalog.transitionReplicaClaim(
            claim,
            from: .requestingReceipt,
            to: .verifyingReceipt,
            updatedAt: "2026-07-11T00:05:00.000Z"
        ))
        let receiptBytes = try ArchiveCanonicalJSON.encode(
            ArchiveServerReceipt(
                serverID: replicaID,
                machineID: "11111111-1111-4111-8111-111111111111",
                sessionID: fixture.sessionID,
                captureID: claim.captureID,
                manifestSHA256: fixture.manifestDigest,
                wholeSourceSHA256: ArchiveV2Hash.sha256(fixture.raw),
                objectCount: fixture.chunks.count,
                rawByteCount: Int64(fixture.raw.count),
                storedAt: "2026-07-11T00:06:00.000Z"
            )
        )
        XCTAssertTrue(try store.catalog.recordVerifiedReceipt(
            claim,
            receipt: ArchiveVerifiedReceipt(
                canonicalBytes: receiptBytes,
                sha256: ArchiveV2Hash.sha256(receiptBytes),
                verifiedAt: "2026-07-11T00:07:00.000Z"
            ),
            updatedAt: "2026-07-11T00:07:00.000Z"
        ))
        await backend.seed(fixture: fixture, receipt: receiptBytes)
    }

    private func objectURL(store: Store, digest: String) -> URL {
        store.root
            .appendingPathComponent("objects/sha256", isDirectory: true)
            .appendingPathComponent(String(digest.prefix(2)), isDirectory: true)
            .appendingPathComponent(digest)
    }

    private func archiveRowCounts(store: Store) throws -> [Int] {
        let queue = try DatabaseQueue(
            path: store.root.appendingPathComponent("archive.sqlite").path
        )
        return try queue.read { db in
            try [
                "archive_captures",
                "archive_session_bindings",
                "archive_replica_receipts",
            ].map { table in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? -1
            }
        }
    }

    private func corruptPersistedReceipt(
        store: Store,
        manifestSHA256: String,
        replicaID: String
    ) throws {
        let queue = try DatabaseQueue(
            path: store.root.appendingPathComponent("archive.sqlite").path
        )
        try queue.write { db in
            try db.execute(
                sql: """
                UPDATE archive_replica_receipts
                SET receipt_sha256 = ?
                WHERE manifest_sha256 = ? AND replica_id = ?
                """,
                arguments: [String(repeating: "0", count: 64), manifestSHA256, replicaID]
            )
        }
    }

    private func corruptBoundManifestBytes(
        store: Store,
        manifestSHA256: String
    ) throws {
        let queue = try DatabaseQueue(
            path: store.root.appendingPathComponent("archive.sqlite").path
        )
        try queue.write { db in
            try db.execute(
                sql: """
                UPDATE archive_session_bindings
                SET bound_manifest_bytes = ?
                WHERE manifest_sha256 = ?
                """,
                arguments: [Data("{}".utf8), manifestSHA256]
            )
        }
    }

    private func clearImmutableFlagsAndContents(at directory: URL) {
        if let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        ) {
            var children: [URL] = []
            for case let child as URL in enumerator {
                children.append(child)
            }
            for child in children.reversed() {
                _ = Darwin.chflags(child.path, 0)
            }
        }
        if let children = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) {
            for child in children {
                try? FileManager.default.removeItem(at: child)
            }
        }
    }

}

private actor AsyncCallCounter {
    private var count = 0
    func increment() { count += 1 }
    func value() -> Int { count }
}

private struct ParsedFileProbe: Sendable {
    let path: String
    let bytes: Data
}

private enum TestFailure: Error {
    case parser
    case catalogRead
}

private enum BackendFailure: Sendable {
    case transport
    case cancel
    case protocolCorrupt
}

private actor RecordingArchiveBackend: ArchiveReplicaBackend {
    nonisolated let replicaID: String
    private var recordedEvents: [String] = []
    private var objects: [String: Data] = [:]
    private var manifests: [String: Data] = [:]
    private var receipts: [String: Data] = [:]
    private var failures: [String: BackendFailure] = [:]
    private var operationToPause: String?
    private var operationIsPaused = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    init(replicaID: String) {
        self.replicaID = replicaID
    }

    func events() -> [String] { recordedEvents }

    func seed(fixture: ArchiveTranscriptResolverTests.Fixture) {
        manifests[fixture.manifestDigest] = fixture.manifestBytes
        for (digest, bytes) in zip(fixture.objectDigests, fixture.chunks) {
            objects[digest] = bytes
        }
    }

    func seed(fixture: ArchiveTranscriptResolverTests.Fixture, receipt: Data) {
        seed(fixture: fixture)
        receipts[fixture.manifestDigest] = receipt
    }

    func setObject(_ data: Data, digest: String) {
        objects[digest] = data
    }

    func removeObject(digest: String) {
        objects.removeValue(forKey: digest)
    }

    func setReceipt(_ data: Data, digest: String) {
        receipts[digest] = data
    }

    func setFailure(_ failure: BackendFailure, operation: String) {
        failures[operation] = failure
    }

    func pauseNext(_ operation: String) {
        operationToPause = operation
    }

    func waitUntilPaused() async {
        if operationIsPaused { return }
        await withCheckedContinuation { continuation in
            pauseWaiters.append(continuation)
        }
    }

    func resumePausedOperation() {
        operationIsPaused = false
        let continuation = resumeContinuation
        resumeContinuation = nil
        continuation?.resume()
    }

    private func record(_ operation: String) async throws {
        recordedEvents.append(operation)
        switch failures[operation] {
        case .transport:
            throw ArchiveReplicaBackendError.transport(.network)
        case .cancel:
            throw CancellationError()
        case .protocolCorrupt:
            throw ArchiveReplicaBackendError.invalidCanonicalResponse
        case nil:
            break
        }
        if operationToPause == operation {
            operationToPause = nil
            operationIsPaused = true
            let waiters = pauseWaiters
            pauseWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            await withCheckedContinuation { continuation in
                resumeContinuation = continuation
            }
        }
    }

    func headObject(digest: String) async throws -> Bool {
        try await record("headObject")
        return objects[digest] != nil
    }

    func putObject(digest: String, data: Data) async throws {
        try await record("putObject")
        objects[digest] = data
    }

    func getObject(digest: String) async throws -> Data {
        try await record("getObject")
        guard let data = objects[digest] else {
            throw ArchiveReplicaBackendError.unexpectedStatus(404)
        }
        return data
    }

    func headManifest(digest: String) async throws -> Bool {
        try await record("headManifest")
        return manifests[digest] != nil
    }

    func putManifest(digest: String, data: Data) async throws {
        try await record("putManifest")
        manifests[digest] = data
    }

    func getManifest(digest: String) async throws -> Data {
        try await record("getManifest")
        guard let data = manifests[digest] else {
            throw ArchiveReplicaBackendError.unexpectedStatus(404)
        }
        return data
    }

    func createReceipt(manifestDigest: String) async throws -> Data {
        try await record("createReceipt")
        guard let data = receipts[manifestDigest] else {
            throw ArchiveReplicaBackendError.unexpectedStatus(404)
        }
        return data
    }

    func getReceipt(manifestDigest: String) async throws -> Data {
        try await record("getReceipt")
        guard let data = receipts[manifestDigest] else {
            throw ArchiveReplicaBackendError.unexpectedStatus(404)
        }
        return data
    }

    func listMachines(cursor: String?, limit: Int) async throws -> ArchiveMachinePage {
        try await record("listMachines")
        return try ArchiveMachinePage(machineIDs: [], nextCursor: nil)
    }

    func listReceipts(
        machineID: String,
        cursor: String?,
        limit: Int
    ) async throws -> ArchiveReceiptPage {
        try await record("listReceipts")
        return try ArchiveReceiptPage(receipts: [], nextCursor: nil)
    }
}
