import CryptoKit
import Darwin
import Dispatch
import Foundation
import GRDB
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

    func testCursorLegacyBodiesAreDurableOnIndependentStoresAcrossReopen() throws {
        let generation = try ArchiveSourceGeneration(device: 1, inode: 2, size: 819200,
            mtimeNs: 3, ctimeNs: 4, mode: 0o100600)
        for serverID in ["hq", "m1"] {
            let directory = root.appendingPathComponent("legacy-" + serverID)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            var store: ArchiveStore? = try ArchiveStore(root: directory, key: key, serverID: serverID, publicationsEnabled: true)
            try store?.warmPublicationIndex()
            var expected: [(String, Data, String, Data)] = []
            for sequence in 1...2 {
                let body = try ArchiveCursorLegacySession(logicalDatabaseLocator: "/offline/globalStorage/state.vscdb",
                    composerID: "owned", cwd: "/offline/project-\(sequence)", databaseGeneration: generation,
                    walGeneration: nil, composer: .init(rowID: 1, key: "composerData:owned",
                        value: Data(#"{"composerId":"owned","conversation":[{"type":1,"text":"durable"}]}"#.utf8)), bubbles: [])
                let raw = try body.encodeCanonical()
                let hash = ArchiveV2Hash.sha256(raw)
                _ = try XCTUnwrap(store).putObject(digest: hash, raw: raw)
                let manifest = try ArchiveSourceManifest(schemaVersion: 6,
                    captureID: ArchiveV2Hash.sha256(Data("legacy-generation-\(sequence)".utf8)),
                    machineID: machineID, source: "cursor", locator: body.logicalLocator, sessionID: nil,
                    capturedAt: timestamp, generation: generation, wholeSourceSHA256: hash, rawByteCount: Int64(raw.count),
                    chunks: [ArchiveChunkReference(ordinal: 0, rawSHA256: hash, rawByteCount: Int64(raw.count))],
                    replayLayout: ArchiveReplayLayout(strategy: .singleFile, relativePaths: ["session.cursor-legacy.json"],
                        cursorLegacySession: ArchiveCursorLegacyContext(session: body)))
                let bytes = try ArchiveCanonicalJSON.encode(manifest)
                let digest = ArchiveV2Hash.sha256(bytes)
                _ = try XCTUnwrap(store).putManifest(digest: digest, canonicalBytes: bytes)
                let publication = try makePublication(manifestDigest: digest, sequence: Int64(sequence))
                let first = try accept(XCTUnwrap(store), publication)
                XCTAssertEqual(first.record.ack.serverID, serverID)
                XCTAssertEqual(first.record.ack.manifestSHA256, digest)
                XCTAssertEqual(try accept(XCTUnwrap(store), publication).record, first.record)
                expected.append((digest, bytes, hash, raw))
            }
            store = nil
            store = try ArchiveStore(root: directory, key: key, serverID: serverID, publicationsEnabled: true)
            try store?.warmPublicationIndex()
            for (digest, bytes, hash, raw) in expected {
                XCTAssertEqual(try XCTUnwrap(store).getManifest(digest: digest), bytes)
                XCTAssertEqual(try XCTUnwrap(store).getObject(digest: hash), raw)
            }
            XCTAssertEqual(try XCTUnwrap(store).listPublications(cursor: nil, limit: 8).items.count, 2)
        }
    }

    func testSchemaFourOpenCodeImagesAreDurableOnIndependentHQAndM1Stores() throws {
        let imageFile = root.appendingPathComponent("session.sqlite")
        let database = try DatabaseQueue(path: imageFile.path)
        try database.write {
            try $0.execute(sql: "CREATE TABLE session(id TEXT, directory TEXT); INSERT INTO session VALUES ('ses-one','/offline/project')")
        }
        try database.close()
        let image = try Data(contentsOf: imageFile)
        let imageHash = ArchiveV2Hash.sha256(image)
        let generation = try ArchiveSourceGeneration(device: 1, inode: 2, size: 819200,
            mtimeNs: 3, ctimeNs: 4, mode: 0o100600)
        for serverID in ["hq", "m1"] {
            let directory = root.appendingPathComponent(serverID)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            let store = try ArchiveStore(root: directory, key: key, serverID: serverID, publicationsEnabled: true)
            try store.warmPublicationIndex()
            _ = try store.putObject(digest: imageHash, raw: image)
            for sequence in 1...2 {
                let wal = try ArchiveSourceGeneration(device: 1, inode: 5, size: Int64(sequence * 8192),
                    mtimeNs: Int64(sequence + 5), ctimeNs: Int64(sequence + 6), mode: 0o100600)
                let context = try ArchiveSQLiteSessionContext(databaseLocator: "/offline/opencode.db",
                    nativeSessionID: "ses-one", nativePayloadByteCount: 0, walGeneration: wal)
                let manifest = try ArchiveSourceManifest(schemaVersion: 4,
                    captureID: ArchiveV2Hash.sha256(Data("image-generation-\(sequence)".utf8)),
                    machineID: machineID, source: "opencode", locator: "/offline/opencode.db::ses-one",
                    sessionID: nil, capturedAt: timestamp, generation: generation,
                    wholeSourceSHA256: imageHash, rawByteCount: Int64(image.count),
                    chunks: [ArchiveChunkReference(ordinal: 0, rawSHA256: imageHash, rawByteCount: Int64(image.count))],
                    replayLayout: ArchiveReplayLayout(strategy: .singleFile, relativePaths: ["session.sqlite"], sqliteSession: context))
                let bytes = try ArchiveCanonicalJSON.encode(manifest)
                let digest = ArchiveV2Hash.sha256(bytes)
                _ = try store.putManifest(digest: digest, canonicalBytes: bytes)
                let publication = try makePublication(manifestDigest: digest, sequence: Int64(sequence))
                let first = try accept(store, publication)
                XCTAssertEqual(first.record.ack.serverID, serverID)
                XCTAssertEqual(first.record.ack.manifestSHA256, digest)
                XCTAssertEqual(try accept(store, publication).record, first.record)
                XCTAssertEqual(try store.getManifest(digest: digest), bytes)
                XCTAssertEqual(try store.getObject(digest: imageHash), image)
            }
            XCTAssertEqual(try store.listPublications(cursor: nil, limit: 8).items.count, 2)
        }
    }

    func testSchemaFiveKimiContextOnlyVersionsAreDurableOnIndependentStores() throws {
        let raw = Data("{\"role\":\"user\",\"content\":\"native Kimi\"}\n".utf8)
        let hash = ArchiveV2Hash.sha256(raw)
        let primary = "workspace/session-one/context.jsonl"
        let generation = try ArchiveSourceGeneration(device: 1, inode: 2, size: Int64(raw.count),
            mtimeNs: 3, ctimeNs: 4, mode: 0o100600)
        for serverID in ["hq", "m1"] {
            let directory = root.appendingPathComponent(serverID)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            let store = try ArchiveStore(root: directory, key: key, serverID: serverID, publicationsEnabled: true)
            try store.warmPublicationIndex()
            _ = try store.putObject(digest: hash, raw: raw)
            for sequence in 1...2 {
                let context = try ArchiveKimiProjectContext(workspaceName: "workspace", nativeSessionID: "session-one",
                    cwd: "/offline/kimi-\(sequence)", registryLocator: "/offline/kimi.json",
                    registryGeneration: generation, registrySHA256: ArchiveV2Hash.sha256(Data("registry-\(sequence)".utf8)))
                let manifest = try ArchiveSourceManifest(schemaVersion: 5,
                    captureID: ArchiveV2Hash.sha256(Data("kimi-generation-\(sequence)".utf8)),
                    machineID: machineID, source: "kimi", locator: "/offline/sessions/" + primary,
                    sessionID: nil, capturedAt: timestamp, generation: generation, wholeSourceSHA256: hash,
                    rawByteCount: Int64(raw.count),
                    chunks: [ArchiveChunkReference(ordinal: 0, rawSHA256: hash, rawByteCount: Int64(raw.count))],
                    replayLayout: ArchiveReplayLayout(strategy: .fileSet, relativePaths: [primary],
                        entrypointRelativePath: primary,
                        files: [ArchiveFileSetEntry(relativePath: primary, byteOffset: 0, rawByteCount: Int64(raw.count),
                            wholeSourceSHA256: hash, generation: generation)],
                        absentRelativePaths: ["workspace/session-one/wire.jsonl"], kimiProjectContext: context))
                let bytes = try ArchiveCanonicalJSON.encode(manifest)
                let digest = ArchiveV2Hash.sha256(bytes)
                _ = try store.putManifest(digest: digest, canonicalBytes: bytes)
                let publication = try makePublication(manifestDigest: digest, sequence: Int64(sequence))
                let first = try accept(store, publication)
                XCTAssertEqual(first.record.ack.serverID, serverID)
                XCTAssertEqual(first.record.ack.manifestSHA256, digest)
                XCTAssertEqual(try accept(store, publication).record, first.record)
                XCTAssertEqual(try store.getManifest(digest: digest), bytes)
                XCTAssertEqual(try store.getObject(digest: hash), raw)
            }
            XCTAssertEqual(try store.listPublications(cursor: nil, limit: 8).items.count, 2)
        }
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

    func testVSCodeSchemaSevenPublicationPreservesFrozenWorkspaceAbsenceAndIdempotentACK() throws {
        let store = try makeStore()
        try store.warmPublicationIndex()
        let raw = Data("AAAA".utf8)
        let hash = ArchiveV2Hash.sha256(raw)
        let generation = try ArchiveSourceGeneration(device: 1, inode: 2, size: 4, mtimeNs: 3, ctimeNs: 4, mode: 0o100600)
        let primary = "ws/chatSessions/session.jsonl"
        let layout = try ArchiveReplayLayout(strategy: .fileSet, relativePaths: [primary],
            entrypointRelativePath: primary, files: [ArchiveFileSetEntry(relativePath: primary,
                byteOffset: 0, rawByteCount: 4, wholeSourceSHA256: hash, generation: generation)],
            absentRelativePaths: ["ws/workspace.json"], vscodeWorkspaceContext: ArchiveVSCodeWorkspaceContext())
        let manifest = try ArchiveSourceManifest(schemaVersion: 7, captureID: hash, machineID: machineID,
            source: "vscode", locator: "/fixture/storage/" + primary, sessionID: nil, capturedAt: timestamp,
            generation: generation, wholeSourceSHA256: hash, rawByteCount: 4,
            chunks: [ArchiveChunkReference(ordinal: 0, rawSHA256: hash, rawByteCount: 4)], replayLayout: layout)
        let bytes = try ArchiveCanonicalJSON.encode(manifest)
        let digest = ArchiveV2Hash.sha256(bytes)
        _ = try store.putObject(digest: hash, raw: raw)
        _ = try store.putManifest(digest: digest, canonicalBytes: bytes)
        let publication = try makePublication(manifestDigest: digest)
        let accepted = try accept(store, publication)
        XCTAssertEqual(accepted.result, .published)
        XCTAssertEqual(try accept(store, publication).record, accepted.record)
        XCTAssertEqual(try store.getManifest(digest: digest), bytes)
        XCTAssertEqual(try store.listPublications(cursor: nil, limit: 50).items, [accepted.record])
        var downgraded = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        downgraded["schemaVersion"] = 2
        var oldLayout = downgraded["replayLayout"] as! [String: Any]
        oldLayout.removeValue(forKey: "vscodeWorkspaceContext")
        downgraded["replayLayout"] = oldLayout
        let oldModel = try JSONDecoder().decode(ArchiveSourceManifest.self,
            from: JSONSerialization.data(withJSONObject: downgraded))
        let oldBytes = try ArchiveCanonicalJSON.encode(oldModel)
        let oldDigest = ArchiveV2Hash.sha256(oldBytes)
        _ = try store.putManifest(digest: oldDigest, canonicalBytes: oldBytes)
        assertPublicationError(.invalidPublication) {
            try self.accept(store, self.makePublication(manifestDigest: oldDigest, sequence: 2))
        }
    }

    func testMiniMaxPublicationRetainsItsExplicitSourceAndIdempotentACK() throws {
        try assertAdditionalSourcePublication("minimax")
    }

    func testLobsterAIPublicationRetainsItsExplicitSourceAndIdempotentACK() throws {
        try assertAdditionalSourcePublication("lobsterai")
    }

    func testIflowPublicationReturnsDurableIdempotentACKWithExactManifestBytes() throws {
        try assertAdditionalSourcePublication("iflow")
    }

    func testQwenPublicationReturnsDurableIdempotentACKWithExactManifestBytes() throws {
        let store = try makeStore()
        try store.warmPublicationIndex()
        let digest = try publishManifest(store: store, source: "qwen")
        let original = try store.getManifest(digest: digest)
        let publication = try makePublication(manifestDigest: digest)
        let accepted = try accept(store, publication)
        XCTAssertEqual(accepted.result, .published)
        XCTAssertEqual(try accept(store, publication).record, accepted.record)
        XCTAssertEqual(try store.getManifest(digest: digest), original)
        XCTAssertEqual(try store.listPublications(cursor: nil, limit: 50).items, [accepted.record])
        let bound = try publishManifest(store: store, source: "qwen", sessionID: "bound")
        assertPublicationError(.invalidPublication) {
            try self.accept(store, self.makePublication(manifestDigest: bound, sequence: 2))
        }
    }

    func testQoderPublicationIsAcceptedWithoutRelabeling() throws {
        try assertAdditionalSourcePublication("qoder")
    }

    func testPiPublicationIsAcceptedWithoutRelabeling() throws {
        try assertAdditionalSourcePublication("pi")
    }

    func testCommandCodePublicationIsAcceptedWithoutRelabeling() throws {
        try assertAdditionalSourcePublication("commandcode")
    }

    func testGrokFileSetPublicationIsAcceptedAndSingleFileGrokIsRejected_repro() throws {
        let store = try makeStore()
        try store.warmPublicationIndex()
        let bytes = try grokManifestBytes()
        let manifest = try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: bytes)
        XCTAssertTrue(ArchiveSourceDescriptor.isGrokFileSet(manifest))
        let raw = Data(repeating: 0x41, count: Int(manifest.rawByteCount))
        _ = try store.putObject(digest: ArchiveV2Hash.sha256(raw), raw: raw)
        let digest = ArchiveV2Hash.sha256(bytes)
        _ = try store.putManifest(digest: digest, canonicalBytes: bytes)
        let publication = try makePublication(manifestDigest: digest)
        let accepted = try accept(store, publication)
        XCTAssertEqual(accepted.result, .published)
        XCTAssertEqual(try accept(store, publication).record, accepted.record)
        XCTAssertEqual(try store.getManifest(digest: digest), bytes)

        let single = try publishManifest(store: store, source: "grok")
        assertPublicationError(.invalidPublication) {
            try self.accept(store, self.makePublication(manifestDigest: single, sequence: 2))
        }
    }

    func testCopilotFileSetPublicationPreservesMembersAndReturnsIdempotentACK() throws {
        let store = try makeStore()
        try store.warmPublicationIndex()
        for (index, checkpoint) in [false, true].enumerated() {
            let bytes = try copilotManifestBytes(checkpoint: checkpoint)
            let manifest = try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: bytes)
            let raw = Data(repeating: 0x41, count: Int(manifest.rawByteCount))
            _ = try store.putObject(digest: ArchiveV2Hash.sha256(raw), raw: raw)
            let digest = ArchiveV2Hash.sha256(bytes)
            _ = try store.putManifest(digest: digest, canonicalBytes: bytes)
            let publication = try makePublication(manifestDigest: digest, sequence: Int64(index + 1))
            let accepted = try accept(store, publication)
            XCTAssertEqual(accepted.result, .published)
            XCTAssertEqual(try accept(store, publication).record, accepted.record)
            XCTAssertEqual(try store.getManifest(digest: digest), bytes)
        }
        XCTAssertEqual(try store.listPublications(cursor: nil, limit: 50).items.count, 2)
    }

    func testCopilotManifestRejectsWrongMemberHashWithCorrectAggregateHash() throws {
        let store = try makeStore()
        var object = try JSONSerialization.jsonObject(with: copilotManifestBytes(checkpoint: false)) as! [String: Any]
        var layout = object["replayLayout"] as! [String: Any]
        var files = layout["files"] as! [[String: Any]]
        files[1]["wholeSourceSHA256"] = String(repeating: "b", count: 64)
        layout["files"] = files
        object["replayLayout"] = layout
        let model = try JSONDecoder().decode(ArchiveSourceManifest.self, from: JSONSerialization.data(withJSONObject: object))
        let bytes = try ArchiveCanonicalJSON.encode(model)
        let raw = Data(repeating: 0x41, count: Int(model.rawByteCount))
        _ = try store.putObject(digest: ArchiveV2Hash.sha256(raw), raw: raw)
        assertLegacyError(.invalidManifest) {
            try store.putManifest(digest: ArchiveV2Hash.sha256(bytes), canonicalBytes: bytes)
        }
    }

    func testCopilotPublicationRejectsCrossSessionMembersAndMissingAbsenceWitnesses() throws {
        let store = try makeStore()
        try store.warmPublicationIndex()
        for crossSession in [false, true] {
            var object = try JSONSerialization.jsonObject(with: copilotManifestBytes(checkpoint: crossSession)) as! [String: Any]
            var layout = object["replayLayout"] as! [String: Any]
            if crossSession {
                var files = layout["files"] as! [[String: Any]]
                files[0]["relativePath"] = "s0/checkpoints/other-session.md"
                layout["files"] = files
                layout["relativePaths"] = files.map { $0["relativePath"]! }
            } else {
                layout["absentRelativePaths"] = [String]()
            }
            object["replayLayout"] = layout
            let model = try JSONDecoder().decode(ArchiveSourceManifest.self, from: JSONSerialization.data(withJSONObject: object))
            let bytes = try ArchiveCanonicalJSON.encode(model)
            let raw = Data(repeating: 0x41, count: Int(model.rawByteCount))
            _ = try store.putObject(digest: ArchiveV2Hash.sha256(raw), raw: raw)
            let digest = ArchiveV2Hash.sha256(bytes)
            _ = try store.putManifest(digest: digest, canonicalBytes: bytes)
            assertPublicationError(.invalidPublication) {
                try self.accept(store, self.makePublication(manifestDigest: digest))
            }
        }
        XCTAssertTrue(try store.listPublications(cursor: nil, limit: 50).items.isEmpty)
    }

    func testCursorModernFileSetPublicationIsDurableAndIdempotentOnIndependentStores() throws {
        let fixture = try cursorModernPairedBytes()
        let manifest = try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: fixture.bytes)
        XCTAssertTrue(ArchiveSourceDescriptor.isCursorModernFileSet(manifest))
        XCTAssertEqual(manifest.schemaVersion, 2)
        XCTAssertEqual(manifest.source, "cursor")
        XCTAssertEqual(manifest.replayLayout.entrypointRelativePath, fixture.primary)
        let rawHash = ArchiveV2Hash.sha256(fixture.raw)
        for serverID in ["hq", "m1"] {
            let directory = root.appendingPathComponent("cursor-" + serverID)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            let store = try ArchiveStore(root: directory, key: key, serverID: serverID, publicationsEnabled: true)
            try store.warmPublicationIndex()
            _ = try store.putObject(digest: rawHash, raw: fixture.raw)
            let digest = ArchiveV2Hash.sha256(fixture.bytes)
            _ = try store.putManifest(digest: digest, canonicalBytes: fixture.bytes)
            let publication = try makePublication(manifestDigest: digest)
            let first = try accept(store, publication)
            XCTAssertEqual(first.result, .published)
            XCTAssertEqual(first.record.ack.serverID, serverID)
            XCTAssertEqual(first.record.ack.manifestSHA256, digest)
            XCTAssertEqual(try accept(store, publication).record, first.record)
            XCTAssertEqual(try store.getManifest(digest: digest), fixture.bytes)
            let stored = try store.getObject(digest: rawHash)
            XCTAssertEqual(stored, fixture.raw)
            for file in try XCTUnwrap(manifest.replayLayout.files) {
                let member = stored.subdata(in: Int(file.byteOffset)..<Int(file.byteOffset + file.rawByteCount))
                XCTAssertEqual(member, fixture.members[file.relativePath])
                XCTAssertEqual(ArchiveV2Hash.sha256(member), file.wholeSourceSHA256)
            }
            XCTAssertEqual(try store.listPublications(cursor: nil, limit: 8).items.count, 1)
        }
    }

    func testCursorPublicationRejectsLegacySharedDatabaseAndMismatchedSessionFileSet() throws {
        let store = try makeStore()
        try store.warmPublicationIndex()
        for bytes in [try cursorLegacySharedDatabaseBytes(), try cursorMismatchedSessionFileSetBytes()] {
            let manifest = try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: bytes)
            XCTAssertFalse(ArchiveSourceDescriptor.isCursorModernFileSet(manifest))
            let raw = Data(repeating: 0x41, count: Int(manifest.rawByteCount))
            _ = try store.putObject(digest: ArchiveV2Hash.sha256(raw), raw: raw)
            let digest = ArchiveV2Hash.sha256(bytes)
            _ = try store.putManifest(digest: digest, canonicalBytes: bytes)
            assertPublicationError(.invalidPublication) {
                try self.accept(store, self.makePublication(manifestDigest: digest))
            }
        }
        XCTAssertTrue(try store.listPublications(cursor: nil, limit: 50).items.isEmpty)
    }

    func testWindsurfHookReplicaAcceptsExactLayoutAndRejectsCacheOrReboundPaths() throws {
        let store = try makeStore()
        try store.warmPublicationIndex()
        let body = "immutable raw transcript"
        let raw = Data(body.utf8)
        _ = try store.putObject(digest: ArchiveV2Hash.sha256(raw), raw: raw)
        let relative = "native.jsonl"
        let variants = [relative, ".hidden.jsonl", "native/cache/transcript.jsonl", "extra/" + relative]
        for (index, path) in variants.enumerated() {
            var object = try JSONSerialization.jsonObject(with: manifestBytes(body: body, source: "windsurf")) as! [String: Any]
            object["locator"] = "/fixture/transcripts/" + path
            // Preserve the protocol's strategy spelling from its encoder.
            let original = try JSONSerialization.jsonObject(with: manifestBytes(body: body, source: "windsurf")) as! [String: Any]
            var layout = original["replayLayout"] as! [String: Any]
            layout["relativePaths"] = [path]
            object["replayLayout"] = layout
            let model = try JSONDecoder().decode(ArchiveSourceManifest.self, from: JSONSerialization.data(withJSONObject: object))
            let bytes = try ArchiveCanonicalJSON.encode(model)
            let digest = ArchiveV2Hash.sha256(bytes)
            _ = try store.putManifest(digest: digest, canonicalBytes: bytes)
            let publication = try makePublication(manifestDigest: digest, sequence: Int64(index + 1))
            if index == 0 {
                let accepted = try accept(store, publication)
                XCTAssertEqual(accepted.result, .published)
                XCTAssertEqual(try accept(store, publication).record, accepted.record)
                XCTAssertEqual(try store.getManifest(digest: digest), bytes)
            } else {
                assertPublicationError(.invalidPublication) { try self.accept(store, publication) }
            }
        }
        XCTAssertEqual(try store.listPublications(cursor: nil, limit: 50).items.count, 1)
    }

    func testAntigravityCLIReplicaAcceptsExactLayoutAndRejectsCacheOrReboundPaths() throws {
        let store = try makeStore()
        try store.warmPublicationIndex()
        let body = "immutable raw transcript"
        let raw = Data(body.utf8)
        _ = try store.putObject(digest: ArchiveV2Hash.sha256(raw), raw: raw)
        let relative = "native/.system_generated/logs/transcript.jsonl"
        let variants = [relative, "transcript.jsonl", "native/cache/transcript.jsonl", "extra/" + relative]
        for (index, path) in variants.enumerated() {
            var object = try JSONSerialization.jsonObject(with: manifestBytes(body: body, source: "antigravity")) as! [String: Any]
            object["locator"] = "/fixture/brain/" + path
            // Preserve the protocol's strategy spelling from its encoder.
            let original = try JSONSerialization.jsonObject(with: manifestBytes(body: body, source: "antigravity")) as! [String: Any]
            var layout = original["replayLayout"] as! [String: Any]
            layout["relativePaths"] = [path]
            object["replayLayout"] = layout
            let model = try JSONDecoder().decode(ArchiveSourceManifest.self, from: JSONSerialization.data(withJSONObject: object))
            let bytes = try ArchiveCanonicalJSON.encode(model)
            let digest = ArchiveV2Hash.sha256(bytes)
            _ = try store.putManifest(digest: digest, canonicalBytes: bytes)
            let publication = try makePublication(manifestDigest: digest, sequence: Int64(index + 1))
            if index == 0 {
                let accepted = try accept(store, publication)
                XCTAssertEqual(accepted.result, .published)
                XCTAssertEqual(try accept(store, publication).record, accepted.record)
                XCTAssertEqual(try store.getManifest(digest: digest), bytes)
            } else {
                assertPublicationError(.invalidPublication) { try self.accept(store, publication) }
            }
        }
        XCTAssertEqual(try store.listPublications(cursor: nil, limit: 50).items.count, 1)
    }

    func testGeminiNativeAndRegistryProjectionPublicationsReturnIdempotentACK() throws {
        let store = try makeStore()
        try store.warmPublicationIndex()
        for (index, registryOnly) in [false, true].enumerated() {
            let bytes = try geminiManifestBytes(registryOnly: registryOnly)
            let manifest = try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: bytes)
            let raw = Data(repeating: 0x41, count: Int(manifest.rawByteCount))
            _ = try store.putObject(digest: ArchiveV2Hash.sha256(raw), raw: raw)
            let digest = ArchiveV2Hash.sha256(bytes)
            _ = try store.putManifest(digest: digest, canonicalBytes: bytes)
            let publication = try makePublication(manifestDigest: digest, sequence: Int64(index + 1))
            let accepted = try accept(store, publication)
            XCTAssertEqual(accepted.result, .published)
            XCTAssertEqual(try accept(store, publication).record, accepted.record)
            XCTAssertEqual(try store.getManifest(digest: digest), bytes)
        }
        XCTAssertEqual(try store.listPublications(cursor: nil, limit: 50).items.count, 2)
    }

    func testGeminiPublicationRejectsMissingRootWitnessAndForeignSidecar() throws {
        let store = try makeStore()
        try store.warmPublicationIndex()
        for foreign in [false, true] {
            var object = try JSONSerialization.jsonObject(with: geminiManifestBytes(registryOnly: true)) as! [String: Any]
            var layout = object["replayLayout"] as! [String: Any]
            layout["absentRelativePaths"] = foreign
                ? ["other/chats/native.engram.json", "project/.project_root"]
                : ["project/chats/native.engram.json"]
            object["replayLayout"] = layout
            let model = try JSONDecoder().decode(ArchiveSourceManifest.self, from: JSONSerialization.data(withJSONObject: object))
            let bytes = try ArchiveCanonicalJSON.encode(model)
            let raw = Data(repeating: 0x41, count: Int(model.rawByteCount))
            _ = try store.putObject(digest: ArchiveV2Hash.sha256(raw), raw: raw)
            let digest = ArchiveV2Hash.sha256(bytes)
            _ = try store.putManifest(digest: digest, canonicalBytes: bytes)
            assertPublicationError(.invalidPublication) {
                try self.accept(store, self.makePublication(manifestDigest: digest))
            }
        }
        XCTAssertTrue(try store.listPublications(cursor: nil, limit: 50).items.isEmpty)
    }

    private func geminiManifestBytes(registryOnly: Bool) throws -> Data {
        let primary = "project/chats/stem.json"
        let paths = registryOnly ? [primary] : ["project/.project_root", primary]
        let payload = Data("AAAA".utf8)
        let entries = try paths.enumerated().map { index, path in
            try ArchiveFileSetEntry(relativePath: path, byteOffset: Int64(index * 4), rawByteCount: 4,
                wholeSourceSHA256: ArchiveV2Hash.sha256(payload), generation: ArchiveSourceGeneration(
                    device: 1, inode: Int64(index + 2), size: 4, mtimeNs: 3, ctimeNs: 4, mode: 0o100600))
        }
        let raw = Data(repeating: 0x41, count: entries.count * 4)
        let hash = ArchiveV2Hash.sha256(raw)
        let context = try registryOnly ? ArchiveGeminiProjectContext(projectName: "project", cwd: "/repo/gemini",
            registryLocator: "/fixture/projects.json", registryGeneration: entries[0].generation,
            registrySHA256: ArchiveV2Hash.sha256(payload)) : nil
        return try ArchiveCanonicalJSON.encode(ArchiveSourceManifest(schemaVersion: registryOnly ? 3 : 2,
            captureID: hash, machineID: machineID, source: "gemini-cli", locator: "/fixture/tmp/" + primary,
            sessionID: nil, capturedAt: timestamp, generation: XCTUnwrap(entries.first { $0.relativePath == primary }).generation,
            wholeSourceSHA256: hash, rawByteCount: Int64(raw.count),
            chunks: [ArchiveChunkReference(ordinal: 0, rawSHA256: hash, rawByteCount: Int64(raw.count))],
            replayLayout: ArchiveReplayLayout(strategy: .fileSet, relativePaths: paths, entrypointRelativePath: primary,
                files: entries, absentRelativePaths: registryOnly
                    ? ["project/.project_root", "project/chats/native.engram.json"] : ["project/chats/native.engram.json"],
                geminiProjectContext: context)))
    }

    private func grokManifestBytes() throws -> Data {
        let prefix = "%2FUsers%2Ftest%2Fproject/019dd6e3-91d1-7326-8299-314858773a0e/"
        let paths = [prefix + "chat_history.jsonl", prefix + "prompt_context.json", prefix + "summary.json"]
        let payload = Data("AAAA".utf8)
        let entries = try paths.enumerated().map { index, path in
            try ArchiveFileSetEntry(relativePath: path, byteOffset: Int64(index * 4), rawByteCount: 4,
                wholeSourceSHA256: ArchiveV2Hash.sha256(payload), generation: ArchiveSourceGeneration(
                    device: 1, inode: Int64(index + 2), size: 4, mtimeNs: 3, ctimeNs: 4, mode: 0o100600))
        }
        let raw = Data(repeating: 0x41, count: entries.count * 4)
        let hash = ArchiveV2Hash.sha256(raw)
        let primary = paths[0]
        return try ArchiveCanonicalJSON.encode(ArchiveSourceManifest(schemaVersion: 2,
            captureID: hash, machineID: machineID, source: "grok", locator: "/fixture/grok/" + primary,
            sessionID: nil, capturedAt: timestamp, generation: XCTUnwrap(entries.first { $0.relativePath == primary }).generation,
            wholeSourceSHA256: hash, rawByteCount: Int64(raw.count),
            chunks: [ArchiveChunkReference(ordinal: 0, rawSHA256: hash, rawByteCount: Int64(raw.count))],
            replayLayout: ArchiveReplayLayout(strategy: .fileSet, relativePaths: paths, entrypointRelativePath: primary,
                files: entries, absentRelativePaths: [prefix + "compaction/INDEX.md", prefix + "updates.jsonl"])))
    }

    private func copilotManifestBytes(checkpoint: Bool) throws -> Data {
        let paths = checkpoint ? ["s1/checkpoints/001.md", "s1/checkpoints/index.md", "s1/events.jsonl", "s1/workspace.yaml"]
            : ["s1/events.jsonl", "s1/workspace.yaml"]
        let primary = checkpoint ? "s1/checkpoints/index.md" : "s1/events.jsonl"
        let payload = Data("AAAA".utf8)
        let entries = try paths.enumerated().map { index, path in
            try ArchiveFileSetEntry(relativePath: path, byteOffset: Int64(index * 4), rawByteCount: 4,
                wholeSourceSHA256: ArchiveV2Hash.sha256(payload), generation: ArchiveSourceGeneration(
                    device: 1, inode: Int64(index + 2), size: 4, mtimeNs: 3, ctimeNs: 4, mode: 0o100600))
        }
        let raw = Data(repeating: 0x41, count: entries.count * 4)
        let hash = ArchiveV2Hash.sha256(raw)
        return try ArchiveCanonicalJSON.encode(ArchiveSourceManifest(schemaVersion: 2,
            captureID: hash, machineID: machineID, source: "copilot", locator: "/fixture/session-state/" + primary,
            sessionID: nil, capturedAt: timestamp, generation: XCTUnwrap(entries.first { $0.relativePath == primary }).generation,
            wholeSourceSHA256: hash, rawByteCount: Int64(raw.count),
            chunks: [ArchiveChunkReference(ordinal: 0, rawSHA256: hash, rawByteCount: Int64(raw.count))],
            replayLayout: ArchiveReplayLayout(strategy: .fileSet, relativePaths: paths, entrypointRelativePath: primary,
                files: entries, absentRelativePaths: checkpoint ? [] : ["s1/checkpoints/index.md"])))
    }

    private func cursorModernPairedBytes() throws -> (
        bytes: Data, raw: Data, primary: String, members: [String: Data]
    ) {
        let ordered = [
            ("chats/ws/sid/meta.json", Data("META".utf8)),
            ("chats/ws/sid/store.db", Data("STORE".utf8)),
            ("chats/ws/sid/store.db-wal", Data("WAL!".utf8)),
            ("projects/proj/agent-transcripts/sid/sid.jsonl", Data("JSONL\n".utf8)),
        ]
        var offset: Int64 = 0
        var raw = Data()
        let entries = try ordered.enumerated().map { index, member in
            let entry = try ArchiveFileSetEntry(relativePath: member.0, byteOffset: offset,
                rawByteCount: Int64(member.1.count), wholeSourceSHA256: ArchiveV2Hash.sha256(member.1),
                generation: ArchiveSourceGeneration(device: 1, inode: Int64(index + 2),
                    size: Int64(member.1.count), mtimeNs: 3, ctimeNs: 4, mode: 0o100600))
            raw.append(member.1)
            offset += Int64(member.1.count)
            return entry
        }
        let primary = "projects/proj/agent-transcripts/sid/sid.jsonl"
        let hash = ArchiveV2Hash.sha256(raw)
        let bytes = try ArchiveCanonicalJSON.encode(ArchiveSourceManifest(schemaVersion: 2,
            captureID: hash, machineID: machineID, source: "cursor", locator: "/offline/cursor/" + primary,
            sessionID: nil, capturedAt: timestamp,
            generation: XCTUnwrap(entries.first { $0.relativePath == primary }).generation,
            wholeSourceSHA256: hash, rawByteCount: Int64(raw.count),
            chunks: [ArchiveChunkReference(ordinal: 0, rawSHA256: hash, rawByteCount: Int64(raw.count))],
            replayLayout: ArchiveReplayLayout(strategy: .fileSet, relativePaths: ordered.map(\.0),
                entrypointRelativePath: primary, files: entries, absentRelativePaths: [])))
        return (bytes, raw, primary, Dictionary(uniqueKeysWithValues: ordered))
    }

    private func cursorLegacySharedDatabaseBytes() throws -> Data {
        let raw = Data(repeating: 0x41, count: 4)
        let hash = ArchiveV2Hash.sha256(raw)
        return try ArchiveCanonicalJSON.encode(ArchiveSourceManifest(
            captureID: hash, machineID: machineID, source: "cursor",
            locator: "/offline/Cursor/User/globalStorage/state.vscdb?composer=legacy",
            sessionID: nil, capturedAt: timestamp,
            generation: ArchiveSourceGeneration(device: 1, inode: 2, size: 4, mtimeNs: 3, ctimeNs: 4, mode: 0o100600),
            wholeSourceSHA256: hash, rawByteCount: 4,
            chunks: [ArchiveChunkReference(ordinal: 0, rawSHA256: hash, rawByteCount: 4)],
            replayLayout: ArchiveReplayLayout(strategy: .singleFile, relativePaths: ["state.vscdb"])))
    }

    private func cursorMismatchedSessionFileSetBytes() throws -> Data {
        let paths = ["chats/ws/sid/store.db", "projects/proj/agent-transcripts/other/other.jsonl"]
        let payload = Data("AAAA".utf8)
        let entries = try paths.enumerated().map { index, path in
            try ArchiveFileSetEntry(relativePath: path, byteOffset: Int64(index * 4), rawByteCount: 4,
                wholeSourceSHA256: ArchiveV2Hash.sha256(payload), generation: ArchiveSourceGeneration(
                    device: 1, inode: Int64(index + 2), size: 4, mtimeNs: 3, ctimeNs: 4, mode: 0o100600))
        }
        let raw = Data(repeating: 0x41, count: 8)
        let hash = ArchiveV2Hash.sha256(raw)
        let primary = paths[1]
        return try ArchiveCanonicalJSON.encode(ArchiveSourceManifest(schemaVersion: 2,
            captureID: hash, machineID: machineID, source: "cursor", locator: "/offline/cursor/" + primary,
            sessionID: nil, capturedAt: timestamp, generation: entries[1].generation,
            wholeSourceSHA256: hash, rawByteCount: 8,
            chunks: [ArchiveChunkReference(ordinal: 0, rawSHA256: hash, rawByteCount: 8)],
            replayLayout: ArchiveReplayLayout(strategy: .fileSet, relativePaths: paths,
                entrypointRelativePath: primary, files: entries,
                absentRelativePaths: ["chats/ws/sid/meta.json", "chats/ws/sid/store.db-wal"])))
    }

    private func assertAdditionalSourcePublication(_ source: String) throws {
        let store = try makeStore()
        try store.warmPublicationIndex()
        let digest = try publishManifest(store: store, source: source)
        let bytes = try store.getManifest(digest: digest)
        let publication = try makePublication(manifestDigest: digest)
        let accepted = try accept(store, publication)
        XCTAssertEqual(accepted.result, .published)
        XCTAssertEqual(try accept(store, publication).record, accepted.record)
        XCTAssertEqual(try store.getManifest(digest: digest), bytes)
        XCTAssertEqual(try store.listPublications(cursor: nil, limit: 50).items, [accepted.record])
        let bound = try publishManifest(store: store, source: source, sessionID: "bound")
        assertPublicationError(.invalidPublication) {
            try self.accept(store, self.makePublication(manifestDigest: bound, sequence: 2))
        }
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
