import CryptoKit
import Darwin
import Dispatch
import Foundation
@testable import EngramRemoteServerCore
import XCTest

final class ArchivePublicationStoreTests: XCTestCase {
    private var root: URL!
    private let key = SymmetricKey(data: Data(repeating: 0x63, count: 32))
    private let machineID = "00000000-0000-4000-8000-0000000000AB"
    private let sourceInstanceID = "10000000-0000-4000-8000-0000000000AB"
    private let epoch = "20000000-0000-4000-8000-0000000000AB"
    private let timestamp = "2026-09-05T10:00:00.000Z"

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-publication-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    func testDefaultOffDoesNotCreatePublicationPathsAndLegacyObjectsStillWork() throws {
        let store = try ArchiveStore(root: root, key: key, serverID: "hq")
        let raw = Data("legacy object remains available".utf8)
        let digest = ArchiveV2Hash.sha256(raw)
        XCTAssertEqual(try store.putObject(digest: digest, raw: raw), .published)
        XCTAssertEqual(try store.getObject(digest: digest), raw)
        assertPublicationError(.unavailable) { try store.warmPublicationIndex() }
        assertPublicationError(.unavailable) { try store.getPublication(digest: digest) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: publicationRoot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL.path))
    }

    func testWarmPublicationIndexMakesPublicationDiscoveryAvailable() throws {
        let store = try makeStore()
        XCTAssertNoThrow(try store.warmPublicationIndex())
        XCTAssertNoThrow(try store.listPublications(cursor: nil, limit: 50))
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadataURL.path))
    }

    func testColdStoreFailsClosedWithoutAffectingOldPathsThenExposesReusableEmptyCursor() throws {
        let store = try makeStore()
        let manifestDigest = try publishManifest(store: store)
        let publication = try makePublication(manifestDigest: manifestDigest)
        assertPublicationError(.unavailable) { try self.accept(store, publication) }
        assertPublicationError(.unavailable) {
            try store.getPublication(digest: publication.sha256())
        }
        assertPublicationError(.unavailable) { try store.listPublications(cursor: nil, limit: 50) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: publicationRoot.path))
        XCTAssertNoThrow(try store.getManifest(digest: manifestDigest))

        try store.warmPublicationIndex()
        let page = try store.listPublications(cursor: nil, limit: 50)
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertFalse(page.hasMore)
        XCTAssertEqual(try CollectorPublicationCursor.decode(page.afterCursor).afterArrivalOrdinal, 0)
        XCTAssertEqual(try store.listPublications(cursor: page.afterCursor, limit: 50), page)
        XCTAssertEqual(try mode(publicationRoot), 0o700)
        XCTAssertEqual(try mode(metadataURL), 0o600)
        XCTAssertEqual(try mode(lockURL), 0o600)
    }

    func testFirstAcceptanceIsEncryptedImmutableAndIdenticalRetryReturnsOriginalACK() throws {
        let store = try makeStore()
        let manifestDigest = try publishManifest(store: store)
        let publication = try makePublication(manifestDigest: manifestDigest)
        try store.warmPublicationIndex()
        let first = try accept(store, publication)
        let digest = try publication.sha256()
        let originalIdentity = try identity(recordURL(digest))
        let sealed = try Data(contentsOf: recordURL(digest))
        let retry = try accept(store, publication)

        XCTAssertEqual(first.result, .published)
        XCTAssertEqual(retry.result, .alreadyPresent)
        XCTAssertEqual(retry.record, first.record)
        XCTAssertEqual(first.record.publication, publication)
        XCTAssertEqual(first.record.ack.serverID, "hq")
        XCTAssertEqual(first.record.ack.arrivalOrdinal, 1)
        XCTAssertEqual(first.record.ack.storedAt, timestamp)
        XCTAssertEqual(first.record.ack.publicationSHA256, digest)
        XCTAssertEqual(first.record.ack.manifestSHA256, manifestDigest)
        XCTAssertEqual(try identity(recordURL(digest)), originalIdentity)
        XCTAssertEqual(try mode(recordURL(digest)), 0o600)
        XCTAssertNil(sealed.range(of: Data(machineID.utf8)))
        XCTAssertEqual(try store.getPublication(digest: digest), first.record)
        let next = try makePublication(manifestDigest: manifestDigest, sequence: 2)
        XCTAssertEqual(try accept(store, next).record.ack.arrivalOrdinal, 2)
        XCTAssertThrowsError(try store.createReceipt(manifestDigest: manifestDigest)) { error in
            XCTAssertEqual(error as? ArchiveStoreError, .unboundManifest)
        }
    }

    func testAcceptedRecordSurvivesIndependentProcessRestart() throws {
        let environment = ProcessInfo.processInfo.environment
        if environment["ENGRAM_PUBLICATION_RESTART_PROBE"] == "1" {
            let probeRoot = try XCTUnwrap(environment["ENGRAM_PUBLICATION_RESTART_ROOT"])
            let encodedRecord = try XCTUnwrap(environment["ENGRAM_PUBLICATION_RESTART_RECORD"])
            let bytes = try XCTUnwrap(Data(base64Encoded: encodedRecord))
            let expected = try ArchiveCanonicalJSON.decode(
                CollectorPublicationAcceptanceRecord.self, from: bytes
            )
            let store = try ArchiveStore(
                root: URL(fileURLWithPath: probeRoot, isDirectory: true),
                key: key,
                serverID: "hq",
                publicationsEnabled: true
            )
            try store.warmPublicationIndex()
            XCTAssertEqual(
                try store.getPublication(digest: expected.ack.publicationSHA256), expected
            )
            XCTAssertEqual(
                try store.listPublications(cursor: nil, limit: 50).items, [expected]
            )
            return
        }

        let accepted: CollectorPublicationAcceptanceRecord = try {
            let store = try makeStore()
            let publication = try makePublication(manifestDigest: publishManifest(store: store))
            try store.warmPublicationIndex()
            return try accept(store, publication).record
        }()
        let process = Process()
        process.executableURL = try resolvedXCTestExecutable()
        process.arguments = [
            "-XCTest",
            "EngramRemoteServerCoreTests.ArchivePublicationStoreTests/testAcceptedRecordSurvivesIndependentProcessRestart",
            Bundle(for: Self.self).bundleURL.path,
        ]
        // A standalone runner must not inherit the parent's test-manager
        // session or injected XCTest configuration and wait for its coordinator.
        var probeEnvironment = environment.filter { entry in
            !entry.key.hasPrefix("XCTest") && !entry.key.hasPrefix("XCInject")
                && entry.key != "DYLD_INSERT_LIBRARIES"
        }
        probeEnvironment["ENGRAM_PUBLICATION_RESTART_PROBE"] = "1"
        probeEnvironment["ENGRAM_PUBLICATION_RESTART_ROOT"] = root.path
        probeEnvironment["ENGRAM_PUBLICATION_RESTART_RECORD"] =
            try ArchiveCanonicalJSON.encode(accepted).base64EncodedString()
        // Launch xctest directly: macOS SIP may strip DYLD values when
        // /usr/bin/xcrun is used to execute a test bundle.
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        probeEnvironment["DYLD_FRAMEWORK_PATH"] = [
            products.path,
            products.appendingPathComponent("PackageFrameworks").path,
            environment["DYLD_FRAMEWORK_PATH"] ?? "",
        ].filter { !$0.isEmpty }.joined(separator: ":")
        probeEnvironment["DYLD_LIBRARY_PATH"] = [
            products.path, environment["DYLD_LIBRARY_PATH"] ?? "",
        ].filter { !$0.isEmpty }.joined(separator: ":")
        process.environment = probeEnvironment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: bytes, as: UTF8.self))
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("Executed 1 test"))
    }

    func testValueCopiesShareAllocatorAndIndependentStoreCannotAcquireLifetimeLock() throws {
        var original: ArchiveStore? = try makeStore()
        let manifestDigest = try publishManifest(store: original!)
        try original!.warmPublicationIndex()
        var copy = original
        let publication = try makePublication(manifestDigest: manifestDigest)
        let first = try accept(copy!, publication)
        let secondStore = try makeStore()
        assertPublicationError(.unavailable) { try secondStore.warmPublicationIndex() }
        XCTAssertNoThrow(try secondStore.getManifest(digest: manifestDigest))
        original = nil
        assertPublicationError(.unavailable) { try secondStore.warmPublicationIndex() }
        copy = nil
        try secondStore.warmPublicationIndex()
        XCTAssertEqual(
            try secondStore.getPublication(digest: publication.sha256()), first.record
        )
        let next = try makePublication(manifestDigest: manifestDigest, sequence: 2)
        XCTAssertEqual(try accept(secondStore, next).record.ack.arrivalOrdinal, 2)
    }

    func testConcurrentCopiesPublishOneACKForIdenticalInputAndAllocateUniqueOrdinals() throws {
        let store = try makeStore()
        let copy = store
        let manifestDigest = try publishManifest(store: store)
        let publication = try makePublication(manifestDigest: manifestDigest)
        let canonical = try ArchiveCanonicalJSON.encode(publication)
        let digest = try publication.sha256()
        try store.warmPublicationIndex()
        let outcomes = PublicationStoreTestOutcomes()
        DispatchQueue.concurrentPerform(iterations: 12) { offset in
            outcomes.record {
                try (offset.isMultiple(of: 2) ? store : copy)
                    .acceptPublication(digest: digest, canonicalBytes: canonical)
            }
        }
        XCTAssertTrue(outcomes.errors.isEmpty, outcomes.errors.joined(separator: ", "))
        XCTAssertEqual(outcomes.values.count, 12)
        XCTAssertEqual(outcomes.values.filter { $0.result == .published }.count, 1)
        XCTAssertEqual(Set(outcomes.values.map { $0.record.ack.arrivalOrdinal }), [1])
        let publications = try (2...13).map {
            try makePublication(manifestDigest: manifestDigest, sequence: Int64($0))
        }
        let payloads = try publications.map { (try $0.sha256(), try ArchiveCanonicalJSON.encode($0)) }
        let nextOutcomes = PublicationStoreTestOutcomes()
        DispatchQueue.concurrentPerform(iterations: payloads.count) { offset in
            nextOutcomes.record {
                try (offset.isMultiple(of: 2) ? store : copy).acceptPublication(
                    digest: payloads[offset].0, canonicalBytes: payloads[offset].1
                )
            }
        }
        XCTAssertTrue(nextOutcomes.errors.isEmpty, nextOutcomes.errors.joined(separator: ", "))
        XCTAssertEqual(
            Set(nextOutcomes.values.map { $0.record.ack.arrivalOrdinal }), Set((2...13).map(Int64.init))
        )
    }

    func testSameSequenceDifferentDigestConflictsButOlderSequenceAndNewEpochAreRetained() throws {
        let store = try makeStore()
        let manifestDigest = try publishManifest(store: store)
        let otherManifest = try publishManifest(store: store, body: "another source generation")
        try store.warmPublicationIndex()
        let first = try makePublication(manifestDigest: manifestDigest, sequence: 10)
        _ = try accept(store, first)
        let conflict = try makePublication(manifestDigest: otherManifest, sequence: 10)
        assertPublicationError(.sequenceConflict) { try self.accept(store, conflict) }
        let older = try makePublication(manifestDigest: otherManifest, sequence: 2)
        XCTAssertEqual(try accept(store, older).record.ack.arrivalOrdinal, 2)
        let branch = try makePublication(
            manifestDigest: otherManifest, sequence: 1, collectorEpoch: UUID().uuidString
        )
        XCTAssertEqual(try accept(store, branch).record.ack.arrivalOrdinal, 3)
    }

    func testArrivalCursorReadsLaterSmallerDigestAndRemainsReusableAtEOF() throws {
        let store = try makeStore()
        let manifestDigest = try publishManifest(store: store)
        let candidates = try (1...20).map {
            try makePublication(manifestDigest: manifestDigest, sequence: Int64($0))
        }.sorted { try $0.sha256() < $1.sha256() }
        let earlier = try XCTUnwrap(candidates.last)
        let later = try XCTUnwrap(candidates.first)
        try store.warmPublicationIndex()
        let first = try accept(store, earlier).record
        let initialPage = try store.listPublications(cursor: nil, limit: 1)
        XCTAssertEqual(initialPage.items, [first])
        XCTAssertFalse(initialPage.hasMore)
        let empty = try store.listPublications(cursor: initialPage.afterCursor, limit: 1)
        XCTAssertTrue(empty.items.isEmpty)
        XCTAssertEqual(empty.afterCursor, initialPage.afterCursor)
        let second = try accept(store, later).record
        let appendedPage = try store.listPublications(cursor: empty.afterCursor, limit: 1)
        XCTAssertEqual(appendedPage.items, [second])
        XCTAssertFalse(appendedPage.hasMore)
        XCTAssertEqual(try CollectorPublicationCursor.decode(appendedPage.afterCursor).afterArrivalOrdinal, 2)
        let firstOfTwo = try store.listPublications(cursor: nil, limit: 1)
        XCTAssertTrue(firstOfTwo.hasMore)
        XCTAssertLessThanOrEqual(
            try ArchiveCanonicalJSON.encode(firstOfTwo).count,
            CollectorPublicationProtocolLimits.maxPageBytes
        )
    }

    func testCursorErrorsDistinguishMalformedForeignJournalAndAheadOfTail() throws {
        let store = try makeStore()
        try store.warmPublicationIndex()
        let empty = try store.listPublications(cursor: nil, limit: 50)
        let beginning = try CollectorPublicationCursor.decode(empty.afterCursor)
        let foreign = try CollectorPublicationCursor(
            journalID: UUID().uuidString, afterArrivalOrdinal: 0
        ).encoded()
        assertPublicationError(.cursorJournalMismatch) {
            try store.listPublications(cursor: foreign, limit: 1)
        }
        let ahead = try CollectorPublicationCursor(
            journalID: beginning.journalID, afterArrivalOrdinal: 1
        ).encoded()
        assertPublicationError(.cursorAheadOfTail) {
            try store.listPublications(cursor: ahead, limit: 1)
        }
        for cursor in ["", "bad cursor", empty.afterCursor + "=", String(repeating: "a", count: 257)] {
            assertLegacyError(.invalidPage) { try store.listPublications(cursor: cursor, limit: 1) }
        }
        for limit in [0, 101, Int.max] {
            assertLegacyError(.invalidPage) { try store.listPublications(cursor: nil, limit: limit) }
        }
    }

    func testIntakeRejectsOversizeNoncanonicalAndDigestMismatchBeforeTouchingJournal() throws {
        let store = try makeStore()
        let publication = try makePublication(manifestDigest: String(repeating: "a", count: 64))
        let digest = try publication.sha256()
        let bytes = try ArchiveCanonicalJSON.encode(publication)
        assertLegacyError(.tooLarge) {
            try store.acceptPublication(digest: digest, canonicalBytes: Data(repeating: 0, count: 2049))
        }
        assertLegacyError(.invalidDigest) {
            try store.acceptPublication(digest: digest.uppercased(), canonicalBytes: bytes)
        }
        assertLegacyError(.digestMismatch) {
            try store.acceptPublication(digest: String(repeating: "b", count: 64), canonicalBytes: bytes)
        }
        let noncanonical = bytes + Data("\n".utf8)
        assertLegacyError(.invalidPage) {
            try store.acceptPublication(
                digest: ArchiveV2Hash.sha256(noncanonical), canonicalBytes: noncanonical
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: publicationRoot.path))
    }

    func testOnlyUnboundClaudeCodexWithMatchingMachineMayBeAccepted() throws {
        let store = try makeStore()
        try store.warmPublicationIndex()
        for (source, session, machine) in [
            ("codex", Optional("already-bound"), machineID),
            ("opencode", nil, machineID),
            ("claude-code", nil, UUID().uuidString),
        ] {
            let manifest = try publishManifest(
                store: store, source: source, sessionID: session, manifestMachineID: machine
            )
            let publication = try makePublication(manifestDigest: manifest)
            assertPublicationError(.invalidPublication) { try self.accept(store, publication) }
        }
        for (offset, source) in ["codex", "claude-code"].enumerated() {
            let manifest = try publishManifest(
                store: store, source: source, manifestMachineID: machineID.lowercased()
            )
            let original = try store.getManifest(digest: manifest)
            let publication = try makePublication(manifestDigest: manifest, sequence: Int64(offset + 1))
            XCTAssertEqual(try accept(store, publication).result, .published)
            XCTAssertEqual(try store.getManifest(digest: manifest), original)
        }
    }

    func testMissingManifestMissingChunkAndWholeSourceMismatchCannotProduceACK() throws {
        let store = try makeStore()
        try store.warmPublicationIndex()
        let missing = try makePublication(manifestDigest: String(repeating: "a", count: 64))
        assertPublicationError(.invalidPublication) { try self.accept(store, missing) }
        let manifestDigest = try publishManifest(store: store)
        let manifest = try ArchiveCanonicalJSON.decode(
            ArchiveSourceManifest.self, from: store.getManifest(digest: manifestDigest)
        )
        let chunk = try XCTUnwrap(manifest.chunks.first)
        try FileManager.default.removeItem(at: objectURL(chunk.rawSHA256))
        let publication = try makePublication(manifestDigest: manifestDigest)
        assertPublicationError(.invalidPublication) { try self.accept(store, publication) }
        _ = try publishManifest(store: store)
        let badManifestBytes = try manifestBytes(
            body: "fixture source", wholeDigest: String(repeating: "f", count: 64)
        )
        let badDigest = ArchiveV2Hash.sha256(badManifestBytes)
        try installEnvelope(raw: badManifestBytes, digest: badDigest, kind: .manifest, at: manifestURL(badDigest))
        let bad = try makePublication(manifestDigest: badDigest)
        assertPublicationError(.invalidPublication) { try self.accept(store, bad) }
        XCTAssertTrue(try store.listPublications(cursor: nil, limit: 50).items.isEmpty)
    }

    func testRebuildReadsAcceptanceRecordsWithoutLoadingManifestOrTranscriptBodies() throws {
        let accepted: CollectorPublicationAcceptanceRecord = try {
            let store = try makeStore()
            let manifestDigest = try publishManifest(store: store)
            let manifest = try ArchiveCanonicalJSON.decode(
                ArchiveSourceManifest.self, from: store.getManifest(digest: manifestDigest)
            )
            try store.warmPublicationIndex()
            let record = try accept(store, makePublication(manifestDigest: manifestDigest)).record
            for chunk in manifest.chunks { try FileManager.default.removeItem(at: objectURL(chunk.rawSHA256)) }
            try FileManager.default.removeItem(at: manifestURL(manifestDigest))
            return record
        }()
        let reader = try makeStore()
        try reader.warmPublicationIndex()
        XCTAssertEqual(try reader.listPublications(cursor: nil, limit: 50).items, [accepted])
        XCTAssertEqual(try reader.getPublication(digest: accepted.ack.publicationSHA256), accepted)
    }

    func testColdRebuildDoesNotBlockOldArchiveAndCannotServePartialPublicationIndex() throws {
        let reached = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let completed = expectation(description: "publication warm finished")
        let outcomes = PublicationStoreTestOutcomes()
        let store = try makeStore(hooks: ArchiveStoreTestHooks(
            afterPublicationIndexScan: {
                reached.signal()
                _ = release.wait(timeout: .now() + 10)
            }
        ))
        let manifest = try publishManifest(store: store)
        DispatchQueue.global().async {
            outcomes.recordVoid { try store.warmPublicationIndex() }
            completed.fulfill()
        }
        XCTAssertEqual(reached.wait(timeout: .now() + 5), .success)
        assertPublicationError(.unavailable) { try store.listPublications(cursor: nil, limit: 50) }
        XCTAssertNoThrow(try store.getManifest(digest: manifest))
        release.signal()
        wait(for: [completed], timeout: 10)
        XCTAssertTrue(outcomes.errors.isEmpty, outcomes.errors.joined(separator: ", "))
    }

    func testAcceptanceFileFsyncFailurePoisonsUntilDurableReconciliation() throws {
        try assertAcceptanceFailure(.fileFsync)
    }

    func testAcceptanceBeforeRenameFailurePoisonsUntilDurableReconciliation() throws {
        try assertAcceptanceFailure(.beforeRename)
    }

    func testAcceptanceDirectoryFsyncFailureReconcilesTheOneRenamedRecord() throws {
        try assertAcceptanceFailure(.directoryFsync)
    }

    func testUncertainRenamedRecordIsRediscoveredOnRestartWithoutReusingItsOrdinal() throws {
        let armed = PublicationStoreTestFlag()
        let hooks = ArchiveStoreTestHooks(beforeDirectoryFsync: { kind in
            if kind.rawValue == 4, armed.value { throw PublicationStoreInjectedFailure.stop }
        })
        let publication: CollectorPublicationEnvelope = try {
            let store = try makeStore(hooks: hooks)
            let publication = try makePublication(manifestDigest: publishManifest(store: store))
            try store.warmPublicationIndex()
            armed.value = true
            assertPublicationError(.unavailable) { try self.accept(store, publication) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: recordURL(try publication.sha256()).path))
            return publication
        }()
        let restarted = try makeStore()
        try restarted.warmPublicationIndex()
        let recovered = try restarted.getPublication(digest: publication.sha256())
        XCTAssertEqual(recovered.ack.arrivalOrdinal, 1)
        XCTAssertEqual(try accept(restarted, publication).record, recovered)
        let next = try makePublication(manifestDigest: publication.manifestSHA256, sequence: 2)
        XCTAssertEqual(try accept(restarted, next).record.ack.arrivalOrdinal, 2)
    }

    func testMetadataFileFsyncFailureLeavesIntakeClosedAndCanBeRetried() throws {
        try assertMetadataFailure(directoryFsync: false)
    }

    func testMetadataDirectoryFsyncFailureLeavesIntakeClosedAndCanBeRetried() throws {
        try assertMetadataFailure(directoryFsync: true)
    }

    func testExistingRecordsWithoutMetadataFailClosedWithoutCreatingNewNamespace() throws {
        let accepted = try populateAndRelease()
        try FileManager.default.removeItem(at: metadataURL)
        let store = try makeStore()
        assertPublicationError(.unavailable) { try store.warmPublicationIndex() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadataURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordURL(accepted.ack.publicationSHA256).path))
        XCTAssertNoThrow(try store.getManifest(digest: accepted.publication.manifestSHA256))
    }

    func testReadyMetadataDisappearanceIsUnavailableRatherThanAnUnknownDigest() throws {
        let store = try makeStore()
        let publication = try makePublication(manifestDigest: publishManifest(store: store))
        try store.warmPublicationIndex()
        _ = try accept(store, publication)
        try FileManager.default.removeItem(at: metadataURL)
        assertPublicationError(.unavailable) {
            try store.getPublication(digest: publication.sha256())
        }
        assertPublicationError(.unavailable) { try store.listPublications(cursor: nil, limit: 50) }
        assertPublicationError(.unavailable) { try self.accept(store, publication) }
        XCTAssertNoThrow(try store.getManifest(digest: publication.manifestSHA256))
    }

    func testEmptyStoreWithMissingMetadataGetsANewCursorNamespace() throws {
        let previousCursor: String = try {
            let store = try makeStore()
            try store.warmPublicationIndex()
            return try store.listPublications(cursor: nil, limit: 50).afterCursor
        }()
        try FileManager.default.removeItem(at: metadataURL)
        let store = try makeStore()
        try store.warmPublicationIndex()
        XCTAssertNotEqual(try store.listPublications(cursor: nil, limit: 50).afterCursor, previousCursor)
        assertPublicationError(.cursorJournalMismatch) {
            try store.listPublications(cursor: previousCursor, limit: 50)
        }
    }

    func testCorruptedAcceptanceAndForeignServerMetadataFailClosedOnlyForPublication() throws {
        let accepted = try populateAndRelease()
        try Data("not an authenticated acceptance".utf8)
            .write(to: recordURL(accepted.ack.publicationSHA256))
        try assertRebuildUnavailable()
        let legacy = try ArchiveStore(root: root, key: key, serverID: "hq")
        XCTAssertNoThrow(try legacy.getManifest(digest: accepted.publication.manifestSHA256))
        let foreign = try ArchiveStore(root: root, key: key, serverID: "m1", publicationsEnabled: true)
        assertPublicationError(.unavailable) { try foreign.warmPublicationIndex() }
    }

    func testDuplicateOrdinalAndConflictingTupleCannotBecomeReadyAfterRebuild() throws {
        let accepted = try populateAndRelease()
        let secondPublication = try makePublication(
            manifestDigest: accepted.publication.manifestSHA256, sequence: 2
        )
        let duplicateOrdinal = try makeRecord(
            publication: secondPublication, journalID: accepted.ack.journalID, ordinal: 1
        )
        try installRecord(duplicateOrdinal)
        try assertRebuildUnavailable()
        try FileManager.default.removeItem(at: recordURL(duplicateOrdinal.ack.publicationSHA256))
        let conflictingPublication = try makePublication(manifestDigest: String(repeating: "b", count: 64))
        try installRecord(try makeRecord(
            publication: conflictingPublication, journalID: accepted.ack.journalID, ordinal: 2
        ))
        try assertRebuildUnavailable()
    }

    func testForeignJournalOrServerInAcceptanceCannotBecomeReadyAfterRebuild() throws {
        let accepted = try populateAndRelease()
        let next = try makePublication(manifestDigest: accepted.publication.manifestSHA256, sequence: 2)
        try installRecord(try makeRecord(publication: next, journalID: UUID().uuidString, ordinal: 2))
        try assertRebuildUnavailable()
        try FileManager.default.removeItem(at: recordURL(try next.sha256()))
        try installRecord(try makeRecord(
            publication: next, journalID: accepted.ack.journalID, ordinal: 2, serverID: "m1"
        ))
        try assertRebuildUnavailable()
    }

    func testOrdinalOverflowFailsExplicitlyWithoutHidingExistingRecords() throws {
        let accepted = try populateAndRelease()
        try installRecord(try makeRecord(
            publication: accepted.publication, journalID: accepted.ack.journalID, ordinal: Int64.max
        ))
        let store = try makeStore()
        try store.warmPublicationIndex()
        let next = try makePublication(manifestDigest: accepted.publication.manifestSHA256, sequence: 2)
        assertPublicationError(.ordinalOverflow) { try self.accept(store, next) }
        XCTAssertEqual(
            try store.getPublication(digest: accepted.ack.publicationSHA256).ack.arrivalOrdinal, Int64.max
        )
    }

    func testReplacingLifetimeLockPathClosesStaleAllocatorWithoutTouchingOldArchive() throws {
        let store = try makeStore()
        let manifest = try publishManifest(store: store)
        try store.warmPublicationIndex()
        try FileManager.default.removeItem(at: lockURL)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: lockURL.path, contents: Data(), attributes: [.posixPermissions: 0o600]
        ))
        let publication = try makePublication(manifestDigest: manifest)
        assertPublicationError(.unavailable) { try self.accept(store, publication) }
        XCTAssertNoThrow(try store.getManifest(digest: manifest))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordURL(try publication.sha256()).path))
    }

    func testLockSubstitutionAtFinalPublishBoundaryCannotReturnAnACK() throws {
        let lock = lockURL
        let hooks = ArchiveStoreTestHooks(beforeFinalPublish: { kind, _ in
            guard kind.rawValue == 4 else { return }
            try FileManager.default.removeItem(at: lock)
            guard FileManager.default.createFile(
                atPath: lock.path, contents: Data(), attributes: [.posixPermissions: 0o600]
            ) else { throw PublicationStoreInjectedFailure.stop }
        })
        let store = try makeStore(hooks: hooks)
        let publication = try makePublication(manifestDigest: publishManifest(store: store))
        try store.warmPublicationIndex()
        assertPublicationError(.unavailable) { try self.accept(store, publication) }
        assertPublicationError(.unavailable) { try store.listPublications(cursor: nil, limit: 50) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordURL(try publication.sha256()).path))
    }

    func testLockAndMetadataModesAndHardlinksAreRecheckedBeforeAllocation() throws {
        let store = try makeStore()
        let publication = try makePublication(manifestDigest: publishManifest(store: store))
        try store.warmPublicationIndex()
        XCTAssertEqual(chmod(lockURL.path, 0o644), 0)
        assertPublicationError(.unavailable) { try self.accept(store, publication) }
        XCTAssertEqual(chmod(lockURL.path, 0o600), 0)
        try store.warmPublicationIndex()
        let extraLink = root.appendingPathComponent("lock-hardlink")
        XCTAssertEqual(link(lockURL.path, extraLink.path), 0)
        assertPublicationError(.unavailable) { try self.accept(store, publication) }
        try FileManager.default.removeItem(at: extraLink)
        try store.warmPublicationIndex()
        XCTAssertEqual(chmod(metadataURL.path, 0o644), 0)
        assertPublicationError(.unavailable) { try self.accept(store, publication) }
        XCTAssertEqual(chmod(metadataURL.path, 0o600), 0)
        try store.warmPublicationIndex()
        let metadataLink = root.appendingPathComponent("metadata-hardlink")
        XCTAssertEqual(link(metadataURL.path, metadataLink.path), 0)
        assertPublicationError(.unavailable) { try self.accept(store, publication) }
    }

    func testExistingLockSymlinkCannotEscapeStoreAndMetadataReplacementPoisonsReadyOwner() throws {
        let outside = root.appendingPathComponent("outside-lock")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: outside.path, contents: Data("unchanged".utf8), attributes: [.posixPermissions: 0o600]
        ))
        try FileManager.default.createSymbolicLink(atPath: lockURL.path, withDestinationPath: outside.path)
        try assertRebuildUnavailable()
        XCTAssertEqual(try Data(contentsOf: outside), Data("unchanged".utf8))
        try FileManager.default.removeItem(at: lockURL)
        let store = try makeStore()
        let publication = try makePublication(manifestDigest: publishManifest(store: store))
        try store.warmPublicationIndex()
        let bytes = try Data(contentsOf: metadataURL)
        try bytes.write(to: metadataURL, options: .atomic)
        XCTAssertEqual(chmod(metadataURL.path, 0o600), 0)
        assertPublicationError(.unavailable) { try self.accept(store, publication) }
    }

    func testMetadataContentsAreRecheckedEvenWhenItsInodeDoesNotChange() throws {
        let store = try makeStore()
        let publication = try makePublication(manifestDigest: publishManifest(store: store))
        try store.warmPublicationIndex()
        let bytes = try Data(contentsOf: metadataURL)
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        fields["journalID"] = UUID().uuidString
        let replacement = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        try replacement.write(to: metadataURL)
        assertPublicationError(.unavailable) { try self.accept(store, publication) }
    }

    func testRootModeIsRecheckedBeforePublicationAllocation() throws {
        let store = try makeStore()
        let publication = try makePublication(manifestDigest: publishManifest(store: store))
        try store.warmPublicationIndex()
        XCTAssertEqual(chmod(root.path, 0o755), 0)
        defer { _ = chmod(root.path, 0o700) }
        assertPublicationError(.unavailable) { try self.accept(store, publication) }
    }

    func testRootDirectoryReplacementCannotReuseAStaleAllocator() throws {
        let store = try makeStore()
        let publication = try makePublication(manifestDigest: publishManifest(store: store))
        try store.warmPublicationIndex()
        let moved = root.deletingLastPathComponent()
            .appendingPathComponent("engram-publication-displaced-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: root, to: moved)
        defer { try? FileManager.default.removeItem(at: moved) }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        assertPublicationError(.unavailable) { try self.accept(store, publication) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: publicationRoot.path))
    }

    private enum AcceptanceFailure {
        case fileFsync, beforeRename, directoryFsync
    }

    private func assertAcceptanceFailure(_ failure: AcceptanceFailure) throws {
        let armed = PublicationStoreTestFlag()
        let hooks = ArchiveStoreTestHooks(
            beforeFileFsync: { kind in
                if kind.rawValue == 4, armed.value, failure == .fileFsync {
                    throw PublicationStoreInjectedFailure.stop
                }
            },
            beforeDirectoryFsync: { kind in
                if kind.rawValue == 4, armed.value, failure == .directoryFsync {
                    throw PublicationStoreInjectedFailure.stop
                }
            },
            beforeFinalPublish: { kind, _ in
                if kind.rawValue == 4, armed.value, failure == .beforeRename {
                    throw PublicationStoreInjectedFailure.stop
                }
            }
        )
        let store = try makeStore(hooks: hooks)
        let publication = try makePublication(manifestDigest: publishManifest(store: store))
        try store.warmPublicationIndex()
        armed.value = true
        assertPublicationError(.unavailable) { try self.accept(store, publication) }
        assertPublicationError(.unavailable) { try store.listPublications(cursor: nil, limit: 50) }
        XCTAssertEqual(
            FileManager.default.fileExists(atPath: recordURL(try publication.sha256()).path),
            failure == .directoryFsync
        )
        XCTAssertNoThrow(try store.getManifest(digest: publication.manifestSHA256))
        armed.value = false
        try store.warmPublicationIndex()
        let accepted = try accept(store, publication)
        XCTAssertEqual(accepted.record.ack.arrivalOrdinal, 1)
        XCTAssertEqual(accepted.result, failure == .directoryFsync ? .alreadyPresent : .published)
        XCTAssertEqual(try store.listPublications(cursor: nil, limit: 50).items, [accepted.record])
    }

    private func assertMetadataFailure(directoryFsync: Bool) throws {
        let armed = PublicationStoreTestFlag(true)
        let hooks = ArchiveStoreTestHooks(
            beforePublicationMetadataFileFsync: {
                if armed.value, !directoryFsync { throw PublicationStoreInjectedFailure.stop }
            },
            beforePublicationMetadataDirectoryFsync: {
                if armed.value, directoryFsync { throw PublicationStoreInjectedFailure.stop }
            }
        )
        let store = try makeStore(hooks: hooks)
        let publication = try makePublication(manifestDigest: publishManifest(store: store))
        assertPublicationError(.unavailable) { try store.warmPublicationIndex() }
        assertPublicationError(.unavailable) { try self.accept(store, publication) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordURL(try publication.sha256()).path))
        armed.value = false
        try store.warmPublicationIndex()
        XCTAssertEqual(try accept(store, publication).record.ack.arrivalOrdinal, 1)
    }

    private func populateAndRelease() throws -> CollectorPublicationAcceptanceRecord {
        let store = try makeStore()
        let publication = try makePublication(manifestDigest: publishManifest(store: store))
        try store.warmPublicationIndex()
        return try accept(store, publication).record
    }

    private func resolvedXCTestExecutable() throws -> URL {
        let resolver = Process()
        resolver.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        resolver.arguments = ["--find", "xctest"]
        let output = Pipe()
        resolver.standardOutput = output
        try resolver.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        resolver.waitUntilExit()
        guard resolver.terminationStatus == 0 else { throw PublicationStoreInjectedFailure.stop }
        let path = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else { throw PublicationStoreInjectedFailure.stop }
        return URL(fileURLWithPath: path)
    }

    private func assertRebuildUnavailable() throws {
        let store = try makeStore()
        assertPublicationError(.unavailable) { try store.warmPublicationIndex() }
    }

    private func makeStore(hooks: ArchiveStoreTestHooks? = nil) throws -> ArchiveStore {
        if let hooks {
            return try ArchiveStore(
                root: root, key: key, serverID: "hq", testHooks: hooks, publicationsEnabled: true
            )
        }
        let storedAt = timestamp
        return try ArchiveStore(
            root: root, key: key, serverID: "hq", now: { storedAt }, publicationsEnabled: true
        )
    }

    private func makePublication(
        manifestDigest: String,
        sequence: Int64 = 1,
        collectorEpoch: String? = nil
    ) throws -> CollectorPublicationEnvelope {
        try CollectorPublicationEnvelope(
            machineID: machineID, sourceInstanceID: sourceInstanceID,
            collectorEpoch: collectorEpoch ?? epoch, sequence: sequence, manifestSHA256: manifestDigest
        )
    }

    private func makeRecord(
        publication: CollectorPublicationEnvelope,
        journalID: String,
        ordinal: Int64,
        serverID: String = "hq"
    ) throws -> CollectorPublicationAcceptanceRecord {
        try CollectorPublicationAcceptanceRecord(
            publication: publication,
            ack: CollectorPublicationACK(
                serverID: serverID, journalID: journalID, arrivalOrdinal: ordinal,
                publicationSHA256: publication.sha256(), manifestSHA256: publication.manifestSHA256,
                storedAt: timestamp
            )
        )
    }

    private func accept(
        _ store: ArchiveStore, _ publication: CollectorPublicationEnvelope
    ) throws -> ArchivePublicationAcceptance {
        try store.acceptPublication(
            digest: publication.sha256(), canonicalBytes: ArchiveCanonicalJSON.encode(publication)
        )
    }

    private func publishManifest(
        store: ArchiveStore,
        body: String = "fixture source",
        source: String = "codex",
        sessionID: String? = nil,
        manifestMachineID: String? = nil
    ) throws -> String {
        let raw = Data(body.utf8)
        _ = try store.putObject(digest: ArchiveV2Hash.sha256(raw), raw: raw)
        let bytes = try manifestBytes(
            body: body, source: source, sessionID: sessionID, manifestMachineID: manifestMachineID
        )
        let digest = ArchiveV2Hash.sha256(bytes)
        _ = try store.putManifest(digest: digest, canonicalBytes: bytes)
        return digest
    }

    private func manifestBytes(
        body: String,
        source: String = "codex",
        sessionID: String? = nil,
        manifestMachineID: String? = nil,
        wholeDigest: String? = nil
    ) throws -> Data {
        let raw = Data(body.utf8)
        let digest = ArchiveV2Hash.sha256(raw)
        return try ArchiveCanonicalJSON.encode(ArchiveSourceManifest(
            captureID: ArchiveV2Hash.sha256(Data((body + source + (sessionID ?? "")).utf8)),
            machineID: manifestMachineID ?? machineID, source: source, locator: "/fixture/source.jsonl",
            sessionID: sessionID, capturedAt: timestamp,
            generation: ArchiveSourceGeneration(
                device: 1, inode: 2, size: Int64(raw.count), mtimeNs: 3, ctimeNs: 4,
                mode: Int64(S_IFREG | S_IRUSR | S_IWUSR)
            ),
            wholeSourceSHA256: wholeDigest ?? digest, rawByteCount: Int64(raw.count),
            chunks: [ArchiveChunkReference(ordinal: 0, rawSHA256: digest, rawByteCount: Int64(raw.count))],
            replayLayout: ArchiveReplayLayout(strategy: .singleFile, relativePaths: ["source.jsonl"])
        ))
    }

    private func installRecord(_ record: CollectorPublicationAcceptanceRecord) throws {
        let kind = try XCTUnwrap(ArchiveEnvelopeKind(rawValue: 4))
        try installEnvelope(
            raw: ArchiveCanonicalJSON.encode(record), digest: record.ack.publicationSHA256,
            kind: kind, at: recordURL(record.ack.publicationSHA256)
        )
    }

    private func installEnvelope(raw: Data, digest: String, kind: ArchiveEnvelopeKind, at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let envelope = try ArchiveEnvelopeCodec(key: key).encode(
            raw: raw, kind: kind, expectedDigest: digest
        )
        try envelope.write(to: url)
        XCTAssertEqual(chmod(url.path, 0o600), 0)
    }

    private var publicationRoot: URL { root.appendingPathComponent("publications", isDirectory: true) }
    private var metadataURL: URL { publicationRoot.appendingPathComponent("journal.json") }
    private var lockURL: URL { root.appendingPathComponent("publications.lock") }
    private func recordURL(_ digest: String) -> URL {
        publicationRoot.appendingPathComponent("sha256/\(digest.prefix(2))/\(digest)")
    }
    private func manifestURL(_ digest: String) -> URL {
        root.appendingPathComponent("manifests/sha256/\(digest.prefix(2))/\(digest)")
    }
    private func objectURL(_ digest: String) -> URL {
        root.appendingPathComponent("objects/sha256/\(digest.prefix(2))/\(digest)")
    }

    private func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }

    private func identity(_ url: URL) throws -> String {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw PublicationStoreInjectedFailure.stop }
        return "\(info.st_dev):\(info.st_ino):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)"
    }

    private func assertPublicationError<T>(
        _ expected: ArchivePublicationStoreError,
        file: StaticString = #filePath, line: UInt = #line,
        _ body: () throws -> T
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(
                error as? ArchivePublicationStoreError, expected,
                "Actual error: \(error)", file: file, line: line
            )
        }
    }

    private func assertLegacyError<T>(
        _ expected: ArchiveStoreError,
        file: StaticString = #filePath, line: UInt = #line,
        _ body: () throws -> T
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? ArchiveStoreError, expected, file: file, line: line)
        }
    }
}

private enum PublicationStoreInjectedFailure: Error {
    case stop
}

private final class PublicationStoreTestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool
    init(_ value: Bool = false) { stored = value }
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

private final class PublicationStoreTestOutcomes: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [ArchivePublicationAcceptance] = []
    private var storedErrors: [String] = []
    var values: [ArchivePublicationAcceptance] {
        lock.lock(); defer { lock.unlock() }; return storedValues
    }
    var errors: [String] {
        lock.lock(); defer { lock.unlock() }; return storedErrors
    }
    func record(_ operation: () throws -> ArchivePublicationAcceptance) {
        do {
            let value = try operation()
            lock.lock(); defer { lock.unlock() }; storedValues.append(value)
        } catch {
            lock.lock(); defer { lock.unlock() }; storedErrors.append(String(describing: error))
        }
    }
    func recordVoid(_ operation: () throws -> Void) {
        do { try operation() } catch {
            lock.lock(); defer { lock.unlock() }; storedErrors.append(String(describing: error))
        }
    }
}
