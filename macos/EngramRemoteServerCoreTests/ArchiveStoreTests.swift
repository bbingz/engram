import CryptoKit
import Darwin
import Foundation
@testable import EngramRemoteServerCore
import XCTest

final class ArchiveStoreTests: XCTestCase {
    private var root: URL!
    private let key = SymmetricKey(data: Data(repeating: 0x33, count: 32))

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-remote-archive-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    func testObjectPublicationIsExactOwnerOnlyAndIdempotent() throws {
        let recorder = ArchiveStoreEventRecorder()
        let store = try ArchiveStore(
            root: root,
            key: key,
            serverID: "hq",
            testHooks: ArchiveStoreTestHooks(
                maximumWriteBytesPerCall: 3,
                afterWriteCall: { recorder.append($0) }
            )
        )
        let raw = Data([0x00, 0xff, 0x0d, 0x0a, 0xef, 0xbb, 0xbf, 0x80])
        let digest = ArchiveV2Hash.sha256(raw)

        XCTAssertEqual(try store.putObject(digest: digest, raw: raw), .published)
        XCTAssertEqual(try store.getObject(digest: digest), raw)
        let before = try identity(objectURL(digest).path)
        XCTAssertEqual(try store.putObject(digest: digest, raw: raw), .alreadyPresent)
        let after = try identity(objectURL(digest).path)

        XCTAssertEqual(before.inode, after.inode)
        XCTAssertEqual(before.mtimeSeconds, after.mtimeSeconds)
        XCTAssertEqual(before.mtimeNanoseconds, after.mtimeNanoseconds)
        XCTAssertGreaterThan(recorder.values.count, 1, "short writes must exercise the full loop")
        XCTAssertEqual(try permissions(root.path), 0o700)
        XCTAssertEqual(try permissions(objectURL(digest).path), 0o600)
    }

    func testExistingNonOwnerOnlyArchiveRootIsRejectedWithoutChangingMode() throws {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755]
        )
        XCTAssertEqual(chmod(root.path, 0o755), 0)

        XCTAssertThrowsError(try ArchiveStore(root: root, key: key, serverID: "hq"))
        XCTAssertEqual(try permissions(root.path), 0o755)
    }

    func testDangerousArchiveRootsAreRejectedBeforeFilesystemMutation() {
        XCTAssertThrowsError(
            try ArchiveStore(
                root: URL(fileURLWithPath: "/", isDirectory: true),
                key: key,
                serverID: "hq"
            )
        )
        XCTAssertThrowsError(
            try ArchiveStore(
                root: FileManager.default.homeDirectoryForCurrentUser,
                key: key,
                serverID: "hq"
            )
        )
    }

    func testWrongKeyRestartCannotReadOrOverwriteExistingObject() throws {
        let writer = try ArchiveStore(root: root, key: key, serverID: "hq")
        let raw = Data("same path must remain immutable".utf8)
        let digest = ArchiveV2Hash.sha256(raw)
        _ = try writer.putObject(digest: digest, raw: raw)
        let beforeBytes = try Data(contentsOf: objectURL(digest))
        let beforeIdentity = try identity(objectURL(digest).path)

        let wrongKeyStore = try ArchiveStore(
            root: root,
            key: SymmetricKey(data: Data(repeating: 0x44, count: 32)),
            serverID: "hq"
        )
        XCTAssertThrowsError(try wrongKeyStore.getObject(digest: digest)) { error in
            XCTAssertEqual(error as? ArchiveStoreError, .conflict)
        }
        XCTAssertThrowsError(try wrongKeyStore.putObject(digest: digest, raw: raw)) { error in
            XCTAssertEqual(error as? ArchiveStoreError, .conflict)
        }

        XCTAssertEqual(try Data(contentsOf: objectURL(digest)), beforeBytes)
        XCTAssertEqual(try identity(objectURL(digest).path).inode, beforeIdentity.inode)
    }

    func testCorruptSymlinkAndHardLinkedFinalsConflictWithoutOverwrite() throws {
        let store = try ArchiveStore(root: root, key: key, serverID: "hq")
        let raw = Data("expected object".utf8)
        let digest = ArchiveV2Hash.sha256(raw)
        try createParent(for: objectURL(digest))

        let corrupt = Data("not an envelope".utf8)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: objectURL(digest).path,
            contents: corrupt,
            attributes: [.posixPermissions: 0o600]
        ))
        XCTAssertThrowsError(try store.putObject(digest: digest, raw: raw)) { error in
            XCTAssertEqual(error as? ArchiveStoreError, .conflict)
        }
        XCTAssertEqual(try Data(contentsOf: objectURL(digest)), corrupt)

        try FileManager.default.removeItem(at: objectURL(digest))
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("archive-store-outside-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        XCTAssertTrue(FileManager.default.createFile(atPath: outside.path, contents: raw))
        try FileManager.default.createSymbolicLink(
            atPath: objectURL(digest).path,
            withDestinationPath: outside.path
        )
        XCTAssertThrowsError(try store.putObject(digest: digest, raw: raw)) { error in
            XCTAssertEqual(error as? ArchiveStoreError, .conflict)
        }
        XCTAssertEqual(try Data(contentsOf: outside), raw)

        try FileManager.default.removeItem(at: objectURL(digest))
        XCTAssertEqual(chmod(outside.path, 0o600), 0)
        XCTAssertEqual(link(outside.path, objectURL(digest).path), 0)
        XCTAssertThrowsError(try store.putObject(digest: digest, raw: raw)) { error in
            XCTAssertEqual(error as? ArchiveStoreError, .conflict)
        }
    }

    func testOversizedExistingEnvelopeConflictsWithoutReadOrOverwrite() throws {
        let store = try ArchiveStore(root: root, key: key, serverID: "hq")
        let raw = Data("bounded existing envelope".utf8)
        let digest = ArchiveV2Hash.sha256(raw)
        let finalURL = objectURL(digest)
        try createParent(for: finalURL)
        let oversized = Int64(ArchiveV2ProtocolLimits.maxObjectRawBytes + 48 + 12 + 16 + 1)
        let fd = Darwin.open(
            finalURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { return }
        XCTAssertEqual(Darwin.ftruncate(fd, oversized), 0)
        XCTAssertEqual(Darwin.close(fd), 0)
        let before = try identity(finalURL.path)

        XCTAssertThrowsError(try store.getObject(digest: digest)) { error in
            XCTAssertEqual(error as? ArchiveStoreError, .conflict)
        }
        XCTAssertThrowsError(try store.putObject(digest: digest, raw: raw)) { error in
            XCTAssertEqual(error as? ArchiveStoreError, .conflict)
        }
        XCTAssertEqual(try identity(finalURL.path).inode, before.inode)
        XCTAssertEqual(try fileSize(finalURL.path), oversized)
    }

    func testIntermediateObjectsDirectorySymlinkCannotEscapeArchiveRoot() throws {
        let store = try ArchiveStore(root: root, key: key, serverID: "hq")
        let raw = Data("must stay beneath archive root".utf8)
        let digest = ArchiveV2Hash.sha256(raw)
        let objects = root.appendingPathComponent("objects", isDirectory: true)
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("archive-store-escaped-objects-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }

        try FileManager.default.moveItem(at: objects, to: outside)
        try FileManager.default.createSymbolicLink(
            atPath: objects.path,
            withDestinationPath: outside.path
        )

        XCTAssertThrowsError(try store.putObject(digest: digest, raw: raw)) { error in
            XCTAssertEqual(error as? ArchiveStoreError, .conflict)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: outside
                .appendingPathComponent("sha256/\(digest.prefix(2))/\(digest)")
                .path
        ))
    }

    func testReadRejectsObjectReachedThroughIntermediateDirectorySymlink() throws {
        let store = try ArchiveStore(root: root, key: key, serverID: "hq")
        let raw = Data("escaped reads are not archive reads".utf8)
        let digest = ArchiveV2Hash.sha256(raw)
        _ = try store.putObject(digest: digest, raw: raw)
        let objects = root.appendingPathComponent("objects", isDirectory: true)
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("archive-store-escaped-read-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }

        try FileManager.default.moveItem(at: objects, to: outside)
        try FileManager.default.createSymbolicLink(
            atPath: objects.path,
            withDestinationPath: outside.path
        )

        XCTAssertThrowsError(try store.getObject(digest: digest)) { error in
            XCTAssertEqual(error as? ArchiveStoreError, .conflict)
        }
    }

    func testParentReplacementDuringExistingPublicationIsRejectedAsConflict() throws {
        let first = try ArchiveStore(root: root, key: key, serverID: "hq")
        let raw = Data("parent identity must remain stable".utf8)
        let digest = ArchiveV2Hash.sha256(raw)
        _ = try first.putObject(digest: digest, raw: raw)
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("archive-store-replaced-parent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }

        let raced = try ArchiveStore(
            root: root,
            key: key,
            serverID: "hq",
            testHooks: ArchiveStoreTestHooks(
                afterExistingEnvelopeVerified: { finalURL in
                    let parent = finalURL.deletingLastPathComponent()
                    try FileManager.default.moveItem(at: parent, to: outside)
                    try FileManager.default.createSymbolicLink(
                        atPath: parent.path,
                        withDestinationPath: outside.path
                    )
                }
            )
        )

        XCTAssertThrowsError(try raced.putObject(digest: digest, raw: raw)) { error in
            XCTAssertEqual(error as? ArchiveStoreError, .conflict)
        }
    }

    func testReplacementAfterExistingEnvelopeVerificationIsRejected() throws {
        let first = try ArchiveStore(root: root, key: key, serverID: "hq")
        let raw = Data("verified immutable envelope".utf8)
        let digest = ArchiveV2Hash.sha256(raw)
        _ = try first.putObject(digest: digest, raw: raw)
        let backup = objectURL(digest).appendingPathExtension("backup")

        let raced = try ArchiveStore(
            root: root,
            key: key,
            serverID: "hq",
            testHooks: ArchiveStoreTestHooks(
                afterExistingEnvelopeVerified: { finalURL in
                    try FileManager.default.moveItem(at: finalURL, to: backup)
                    guard FileManager.default.createFile(
                        atPath: finalURL.path,
                        contents: try Data(contentsOf: backup),
                        attributes: [.posixPermissions: 0o600]
                    ) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
            )
        )

        XCTAssertThrowsError(try raced.putObject(digest: digest, raw: raw)) { error in
            XCTAssertEqual(error as? ArchiveStoreError, .conflict)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
    }

    func testInjectedFsyncAndPublishFailuresLeaveNoFinalOrReceipt() throws {
        struct Injected: Error {}
        let raw = Data("failure injection".utf8)
        let digest = ArchiveV2Hash.sha256(raw)
        let fsyncFailing = try ArchiveStore(
            root: root,
            key: key,
            serverID: "hq",
            testHooks: ArchiveStoreTestHooks(
                beforeFileFsync: { kind in
                    if kind == .object { throw Injected() }
                }
            )
        )
        XCTAssertThrowsError(try fsyncFailing.putObject(digest: digest, raw: raw))
        XCTAssertFalse(FileManager.default.fileExists(atPath: objectURL(digest).path))
        XCTAssertEqual(
            try fsyncFailing.listMachines(cursor: nil, limit: 10).machineIDs,
            []
        )

        let publishFailing = try ArchiveStore(
            root: root,
            key: key,
            serverID: "hq",
            testHooks: ArchiveStoreTestHooks(
                beforeFinalPublish: { kind, _ in
                    if kind == .object { throw Injected() }
                }
            )
        )
        XCTAssertThrowsError(try publishFailing.putObject(digest: digest, raw: raw))
        XCTAssertFalse(FileManager.default.fileExists(atPath: objectURL(digest).path))
    }

    func testExistingShardRetryRepairsItsParentDirectoryDurability() throws {
        struct Injected: Error {}
        let raw = Data("shard parent fsync must be retried".utf8)
        let digest = ArchiveV2Hash.sha256(raw)
        let events = ArchiveStoreEventRecorder()
        let store = try ArchiveStore(
            root: root,
            key: key,
            serverID: "hq",
            testHooks: ArchiveStoreTestHooks(
                beforeDirectoryParentFsync: { directory in
                    guard directory.path.contains("/objects/sha256/") else { return }
                    events.append(1)
                    if events.values.count == 1 { throw Injected() }
                }
            )
        )

        XCTAssertThrowsError(try store.putObject(digest: digest, raw: raw))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: objectURL(digest).deletingLastPathComponent().path
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: objectURL(digest).path))

        XCTAssertEqual(try store.putObject(digest: digest, raw: raw), .published)
        XCTAssertEqual(events.values.count, 2)
        XCTAssertEqual(try store.getObject(digest: digest), raw)
    }

    func testExistingRootRetryRepairsItsExternalParentDirectoryDurability() throws {
        struct Injected: Error {}
        let events = ArchiveStoreEventRecorder()
        let rootURL = root.standardizedFileURL
        let hooks = ArchiveStoreTestHooks(
            beforeDirectoryParentFsync: { directory in
                guard directory.standardizedFileURL == rootURL else {
                    return
                }
                events.append(1)
                if events.values.count == 1 { throw Injected() }
            }
        )

        XCTAssertThrowsError(
            try ArchiveStore(root: root, key: key, serverID: "hq", testHooks: hooks)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))

        let recovered = try ArchiveStore(
            root: root,
            key: key,
            serverID: "hq",
            testHooks: hooks
        )
        XCTAssertEqual(events.values.count, 2)
        let raw = Data("root parent retry is durable".utf8)
        let digest = ArchiveV2Hash.sha256(raw)
        XCTAssertEqual(try recovered.putObject(digest: digest, raw: raw), .published)
    }

    func testReceiptDurabilityReadFailsClosedAfterPublicationDirectoryFsyncFailure() throws {
        struct Injected: Error {}
        let raw = Data("visible final is not yet receipt durable".utf8)
        let objectDigest = ArchiveV2Hash.sha256(raw)
        let manifestBytes = try boundManifestBytes(
            raw: raw,
            objectDigest: objectDigest,
            machineID: UUID().uuidString
        )
        let manifestDigest = ArchiveV2Hash.sha256(manifestBytes)
        let normal = try ArchiveStore(root: root, key: key, serverID: "hq")
        let failing = try ArchiveStore(
            root: root,
            key: key,
            serverID: "hq",
            testHooks: ArchiveStoreTestHooks(
                beforeDirectoryFsync: { kind in
                    if kind == .object { throw Injected() }
                }
            )
        )

        XCTAssertThrowsError(try failing.putObject(digest: objectDigest, raw: raw))
        XCTAssertTrue(FileManager.default.fileExists(atPath: objectURL(objectDigest).path))
        _ = try normal.putManifest(digest: manifestDigest, canonicalBytes: manifestBytes)

        XCTAssertThrowsError(try failing.createReceipt(manifestDigest: manifestDigest))
        XCTAssertThrowsError(try failing.getReceipt(manifestDigest: manifestDigest)) { error in
            XCTAssertEqual(error as? ArchiveStoreError, .notFound)
        }

        let receipt = try normal.createReceipt(manifestDigest: manifestDigest)
        XCTAssertEqual(try normal.getReceipt(manifestDigest: manifestDigest), receipt)
    }

    func testReceiptGateRejectsParentReplacementBeforeDurabilityFsync() throws {
        let raw = Data("old fd bytes cannot outlive their archive parent".utf8)
        let objectDigest = ArchiveV2Hash.sha256(raw)
        let manifestBytes = try boundManifestBytes(
            raw: raw,
            objectDigest: objectDigest,
            machineID: UUID().uuidString
        )
        let manifestDigest = ArchiveV2Hash.sha256(manifestBytes)
        let normal = try ArchiveStore(root: root, key: key, serverID: "hq")
        _ = try normal.putObject(digest: objectDigest, raw: raw)
        _ = try normal.putManifest(digest: manifestDigest, canonicalBytes: manifestBytes)
        let movedParent = root.deletingLastPathComponent()
            .appendingPathComponent("archive-store-moved-durable-parent-\(UUID().uuidString)")
        let objectParent = objectURL(objectDigest).deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: movedParent) }
        let raced = try ArchiveStore(
            root: root,
            key: key,
            serverID: "hq",
            testHooks: ArchiveStoreTestHooks(
                beforeDirectoryFsync: { kind in
                    guard kind == .object,
                          !FileManager.default.fileExists(atPath: movedParent.path) else {
                        return
                    }
                    try FileManager.default.moveItem(at: objectParent, to: movedParent)
                    try FileManager.default.createDirectory(
                        at: objectParent,
                        withIntermediateDirectories: false,
                        attributes: [.posixPermissions: 0o700]
                    )
                    guard chmod(objectParent.path, 0o700) == 0 else {
                        throw POSIXError(.EIO)
                    }
                }
            )
        )

        XCTAssertThrowsError(try raced.createReceipt(manifestDigest: manifestDigest)) { error in
            XCTAssertEqual(error as? ArchiveStoreError, .conflict)
        }
        XCTAssertThrowsError(try raced.getReceipt(manifestDigest: manifestDigest)) { error in
            XCTAssertEqual(error as? ArchiveStoreError, .notFound)
        }
    }

    func testReceiptGatePreservesStorageIOClassification() throws {
        let raw = Data("durability I/O is not a content conflict".utf8)
        let objectDigest = ArchiveV2Hash.sha256(raw)
        let manifestBytes = try boundManifestBytes(
            raw: raw,
            objectDigest: objectDigest,
            machineID: UUID().uuidString
        )
        let manifestDigest = ArchiveV2Hash.sha256(manifestBytes)
        let normal = try ArchiveStore(root: root, key: key, serverID: "hq")
        _ = try normal.putObject(digest: objectDigest, raw: raw)
        _ = try normal.putManifest(digest: manifestDigest, canonicalBytes: manifestBytes)
        let failing = try ArchiveStore(
            root: root,
            key: key,
            serverID: "hq",
            testHooks: ArchiveStoreTestHooks(
                beforeFileFsync: { kind in
                    if kind == .object { throw ArchiveStoreError.io }
                }
            )
        )

        XCTAssertThrowsError(try failing.createReceipt(manifestDigest: manifestDigest)) { error in
            XCTAssertEqual(error as? ArchiveStoreError, .io)
        }
    }

    func testReceiptPublicationResultIsAtomicAndIdempotent() throws {
        let raw = Data("receipt status must not use a preflight race".utf8)
        let objectDigest = ArchiveV2Hash.sha256(raw)
        let manifestBytes = try boundManifestBytes(
            raw: raw,
            objectDigest: objectDigest,
            machineID: UUID().uuidString
        )
        let manifestDigest = ArchiveV2Hash.sha256(manifestBytes)
        let store = try ArchiveStore(root: root, key: key, serverID: "hq")
        _ = try store.putObject(digest: objectDigest, raw: raw)
        _ = try store.putManifest(digest: manifestDigest, canonicalBytes: manifestBytes)

        let first = try store.createReceiptWithResult(manifestDigest: manifestDigest)
        let second = try store.createReceiptWithResult(manifestDigest: manifestDigest)

        XCTAssertEqual(first.result, .published)
        XCTAssertEqual(second.result, .alreadyPresent)
        XCTAssertEqual(first.bytes, second.bytes)
    }

    func testConcurrentReceiptCreationPublishesExactlyOneCanonicalReceipt() throws {
        let raw = Data("concurrent receipt publication".utf8)
        let objectDigest = ArchiveV2Hash.sha256(raw)
        let manifestBytes = try boundManifestBytes(
            raw: raw,
            objectDigest: objectDigest,
            machineID: UUID().uuidString
        )
        let manifestDigest = ArchiveV2Hash.sha256(manifestBytes)
        let setup = try ArchiveStore(root: root, key: key, serverID: "hq")
        _ = try setup.putObject(digest: objectDigest, raw: raw)
        _ = try setup.putManifest(digest: manifestDigest, canonicalBytes: manifestBytes)
        let finalPublished = DispatchSemaphore(value: 0)
        let releasePublisher = DispatchSemaphore(value: 0)
        let publisher = try ArchiveStore(
            root: root,
            key: key,
            serverID: "hq",
            testHooks: ArchiveStoreTestHooks(
                afterFinalPublish: { kind, _ in
                    guard kind == .receipt else { return }
                    finalPublished.signal()
                    _ = releasePublisher.wait(timeout: .now() + 10)
                }
            )
        )
        let contender = try ArchiveStore(
            root: root,
            key: key,
            serverID: "hq",
            now: { "2026-07-11T11:00:00.000Z" }
        )
        let recorder = ArchiveReceiptCreationRecorder()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            recorder.append(Result {
                try publisher.createReceiptWithResult(manifestDigest: manifestDigest)
            })
        }
        XCTAssertEqual(finalPublished.wait(timeout: .now() + 10), .success)
        let contenderResult = Result {
            try contender.createReceiptWithResult(manifestDigest: manifestDigest)
        }
        releasePublisher.signal()
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        let creations = try recorder.values.map { try $0.get() } + [try contenderResult.get()]

        XCTAssertEqual(creations.count, 2)
        XCTAssertEqual(creations.filter { $0.result == .published }.count, 1)
        XCTAssertEqual(creations.filter { $0.result == .alreadyPresent }.count, 1)
        XCTAssertEqual(Set(creations.map(\.bytes)).count, 1)
        XCTAssertEqual(
            try setup.getReceipt(manifestDigest: manifestDigest),
            creations[0].bytes
        )
    }

    func testReceiptDirectoryFsyncFailureCannotBecomeReadableAuthority() throws {
        struct Injected: Error {}
        let raw = Data("receipt authority starts only after durability".utf8)
        let objectDigest = ArchiveV2Hash.sha256(raw)
        let manifestBytes = try boundManifestBytes(
            raw: raw,
            objectDigest: objectDigest,
            machineID: UUID().uuidString
        )
        let manifestDigest = ArchiveV2Hash.sha256(manifestBytes)
        let normal = try ArchiveStore(root: root, key: key, serverID: "hq")
        _ = try normal.putObject(digest: objectDigest, raw: raw)
        _ = try normal.putManifest(digest: manifestDigest, canonicalBytes: manifestBytes)
        let failing = try ArchiveStore(
            root: root,
            key: key,
            serverID: "hq",
            testHooks: ArchiveStoreTestHooks(
                beforeDirectoryFsync: { kind in
                    if kind == .receipt { throw Injected() }
                }
            )
        )

        XCTAssertThrowsError(try failing.createReceipt(manifestDigest: manifestDigest))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: receiptURL(manifestDigest).path
        ))
        XCTAssertThrowsError(try failing.getReceipt(manifestDigest: manifestDigest))

        let recovered = try normal.createReceiptWithResult(manifestDigest: manifestDigest)
        XCTAssertEqual(recovered.result, .alreadyPresent)
        XCTAssertEqual(try normal.getReceipt(manifestDigest: manifestDigest), recovered.bytes)
    }

    func testDiscoveryReadsReceiptAuthorityWithoutReplayingArchivedObjects() throws {
        let machineID = UUID().uuidString
        let raw = Data("discovery is receipt metadata, not transcript replay".utf8)
        let objectDigest = ArchiveV2Hash.sha256(raw)
        let manifestBytes = try boundManifestBytes(
            raw: raw,
            objectDigest: objectDigest,
            machineID: machineID
        )
        let manifestDigest = ArchiveV2Hash.sha256(manifestBytes)
        let store = try ArchiveStore(root: root, key: key, serverID: "hq")
        _ = try store.putObject(digest: objectDigest, raw: raw)
        _ = try store.putManifest(digest: manifestDigest, canonicalBytes: manifestBytes)
        _ = try store.createReceipt(manifestDigest: manifestDigest)
        try FileManager.default.removeItem(at: objectURL(objectDigest))

        XCTAssertEqual(
            try store.listMachines(cursor: nil, limit: 10).machineIDs,
            [machineID]
        )
        XCTAssertEqual(
            try store.listReceipts(machineID: machineID, cursor: nil, limit: 10)
                .receipts.map(\.manifestSHA256),
            [manifestDigest]
        )
    }

    func testReceiptIsCanonicalImmutableAcrossRestartAndDiscoveryNormalizesMachineUUID() throws {
        let fixedFirst = "2026-07-11T12:00:00.000Z"
        let fixedSecond = "2026-07-11T13:00:00.000Z"
        let raw = Data("bound archived source".utf8)
        let objectDigest = ArchiveV2Hash.sha256(raw)
        let manifestBytes = try boundManifestBytes(
            raw: raw,
            objectDigest: objectDigest,
            machineID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        )
        let manifestDigest = ArchiveV2Hash.sha256(manifestBytes)

        let first = try ArchiveStore(
            root: root,
            key: key,
            serverID: "hq",
            now: { fixedFirst }
        )
        _ = try first.putObject(digest: objectDigest, raw: raw)
        _ = try first.putManifest(digest: manifestDigest, canonicalBytes: manifestBytes)
        let receiptBytes = try first.createReceipt(manifestDigest: manifestDigest)
        let receiptDigest = ArchiveV2Hash.sha256(receiptBytes)
        XCTAssertEqual(try permissions(manifestURL(manifestDigest).path), 0o600)
        XCTAssertEqual(try permissions(receiptURL(manifestDigest).path), 0o600)
        XCTAssertEqual(
            try permissions(receiptURL(manifestDigest).deletingLastPathComponent().path),
            0o700
        )

        let restarted = try ArchiveStore(
            root: root,
            key: key,
            serverID: "hq",
            now: { fixedSecond }
        )
        XCTAssertEqual(try restarted.createReceipt(manifestDigest: manifestDigest), receiptBytes)
        XCTAssertEqual(try restarted.getReceipt(manifestDigest: manifestDigest), receiptBytes)
        let receipt = try ArchiveCanonicalJSON.decode(
            ArchiveServerReceipt.self,
            from: receiptBytes
        )
        XCTAssertEqual(receipt.storedAt, fixedFirst)
        XCTAssertEqual(receipt.machineID, "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")

        let machines = try restarted.listMachines(cursor: nil, limit: 10)
        XCTAssertEqual(machines.machineIDs, ["AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"])
        let receipts = try restarted.listReceipts(
            machineID: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            cursor: nil,
            limit: 10
        )
        XCTAssertEqual(
            receipts.receipts,
            [try ArchiveReceiptSummary(
                manifestSHA256: manifestDigest,
                receiptSHA256: receiptDigest
            )]
        )
    }

    func testReceiptPublishFailureDoesNotCreateDiscoveryAuthority() throws {
        struct Injected: Error {}
        let raw = Data("receipt failure".utf8)
        let objectDigest = ArchiveV2Hash.sha256(raw)
        let manifestBytes = try boundManifestBytes(
            raw: raw,
            objectDigest: objectDigest,
            machineID: UUID().uuidString
        )
        let manifestDigest = ArchiveV2Hash.sha256(manifestBytes)
        let normal = try ArchiveStore(root: root, key: key, serverID: "hq")
        _ = try normal.putObject(digest: objectDigest, raw: raw)
        _ = try normal.putManifest(digest: manifestDigest, canonicalBytes: manifestBytes)

        let failing = try ArchiveStore(
            root: root,
            key: key,
            serverID: "hq",
            testHooks: ArchiveStoreTestHooks(
                beforeFinalPublish: { kind, _ in
                    if kind == .receipt { throw Injected() }
                }
            )
        )
        XCTAssertThrowsError(try failing.createReceipt(manifestDigest: manifestDigest))
        XCTAssertThrowsError(try failing.getReceipt(manifestDigest: manifestDigest)) { error in
            XCTAssertEqual(error as? ArchiveStoreError, .notFound)
        }
        XCTAssertEqual(try failing.listMachines(cursor: nil, limit: 10).machineIDs, [])
    }

    // MCP retro F08: cold LIST scan rejects receipt authority issued by another server.
    func testColdListRejectsReceiptWithForeignServerID() throws {
        let foreign = try ArchiveStore(root: root, key: key, serverID: "m1")
        _ = try publishReceipt(
            store: foreign,
            body: "foreign-server-receipt",
            machineID: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            captureSuffix: "foreign-server"
        )
        let cold = try ArchiveStore(root: root, key: key, serverID: "hq")

        XCTAssertThrowsError(try cold.listMachines(cursor: nil, limit: 10)) { error in
            XCTAssertEqual(error as? ArchiveStoreError, .conflict)
        }
    }

    // MCP retro F08: cold LIST scan rejects a receipt outside its digest shard.
    func testColdListRejectsReceiptInMismatchedDigestShard() throws {
        let setup = try ArchiveStore(root: root, key: key, serverID: "hq")
        let manifestDigest = try publishReceipt(
            store: setup,
            body: "mismatched-shard-receipt",
            machineID: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            captureSuffix: "mismatched-shard"
        )
        let wrongShard = manifestDigest.hasPrefix("00") ? "ff" : "00"
        let misplaced = root.appendingPathComponent(
            "receipts/sha256/\(wrongShard)/\(manifestDigest)"
        )
        try createParent(for: misplaced)
        try FileManager.default.moveItem(at: receiptURL(manifestDigest), to: misplaced)
        let cold = try ArchiveStore(root: root, key: key, serverID: "hq")

        XCTAssertThrowsError(try cold.listMachines(cursor: nil, limit: 10)) { error in
            XCTAssertEqual(error as? ArchiveStoreError, .conflict)
        }
    }

    // MCP retro F08: cold LIST scan rejects a symlink substituted for a receipt file.
    func testColdListRejectsSymlinkedReceiptFile() throws {
        let setup = try ArchiveStore(root: root, key: key, serverID: "hq")
        let manifestDigest = try publishReceipt(
            store: setup,
            body: "symlinked-receipt",
            machineID: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC",
            captureSuffix: "symlinked-receipt"
        )
        let receipt = receiptURL(manifestDigest)
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("archive-store-symlinked-receipt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.moveItem(at: receipt, to: outside)
        try FileManager.default.createSymbolicLink(
            atPath: receipt.path,
            withDestinationPath: outside.path
        )
        let cold = try ArchiveStore(root: root, key: key, serverID: "hq")

        XCTAssertThrowsError(try cold.listMachines(cursor: nil, limit: 10)) { error in
            XCTAssertEqual(error as? ArchiveStoreError, .conflict)
        }
    }

    // MCP retro F08: cold LIST scan rejects a hard-linked receipt file.
    func testColdListRejectsHardLinkedReceiptFile() throws {
        let setup = try ArchiveStore(root: root, key: key, serverID: "hq")
        let manifestDigest = try publishReceipt(
            store: setup,
            body: "hard-linked-receipt",
            machineID: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD",
            captureSuffix: "hard-linked-receipt"
        )
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("archive-store-hard-linked-receipt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        XCTAssertEqual(link(receiptURL(manifestDigest).path, outside.path), 0)
        let cold = try ArchiveStore(root: root, key: key, serverID: "hq")

        XCTAssertThrowsError(try cold.listMachines(cursor: nil, limit: 10)) { error in
            XCTAssertEqual(error as? ArchiveStoreError, .conflict)
        }
    }

    // MCP retro F08: cold LIST scan rejects a setup-time shard identity/symlink substitution.
    func testColdListRejectsSetupTimeShardIdentitySubstitution() throws {
        let setup = try ArchiveStore(root: root, key: key, serverID: "hq")
        let manifestDigest = try publishReceipt(
            store: setup,
            body: "swapped-shard-receipt",
            machineID: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE",
            captureSuffix: "swapped-shard"
        )
        let shard = receiptURL(manifestDigest).deletingLastPathComponent()
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("archive-store-swapped-shard-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.moveItem(at: shard, to: outside)
        try FileManager.default.createSymbolicLink(
            atPath: shard.path,
            withDestinationPath: outside.path
        )
        let cold = try ArchiveStore(root: root, key: key, serverID: "hq")

        XCTAssertThrowsError(try cold.listMachines(cursor: nil, limit: 10)) { error in
            XCTAssertEqual(error as? ArchiveStoreError, .conflict)
        }
    }

    // MCP retro F11: a receipt replacement that disagrees with a pending entry poisons lists.
    func testListIndexFailsClosedAfterReceiptDigestConflictDuringWarm() throws {
        let machineID = "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"
        let raw = Data("list-index-poison".utf8)
        let objectDigest = ArchiveV2Hash.sha256(raw)
        let manifestBytes = try boundManifestBytes(
            raw: raw,
            objectDigest: objectDigest,
            machineID: machineID,
            captureID: ArchiveV2Hash.sha256(Data("list-index-poison".utf8)),
            sessionID: "session-list-index-poison"
        )
        let manifestDigest = ArchiveV2Hash.sha256(manifestBytes)
        let store = try ArchiveStore(
            root: root,
            key: key,
            serverID: "hq",
            now: { "2026-07-11T11:00:00.000Z" }
        )
        _ = try store.putObject(digest: objectDigest, raw: raw)
        _ = try store.putManifest(digest: manifestDigest, canonicalBytes: manifestBytes)
        let publishedReceipt = try store.createReceipt(manifestDigest: manifestDigest)

        let alternateRoot = root.deletingLastPathComponent()
            .appendingPathComponent("archive-store-alternate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: alternateRoot) }
        let alternate = try ArchiveStore(
            root: alternateRoot,
            key: key,
            serverID: "hq",
            now: { "2026-07-11T12:00:00.000Z" }
        )
        _ = try alternate.putObject(digest: objectDigest, raw: raw)
        _ = try alternate.putManifest(digest: manifestDigest, canonicalBytes: manifestBytes)
        let replacementReceipt = try alternate.createReceipt(manifestDigest: manifestDigest)
        XCTAssertNotEqual(
            ArchiveV2Hash.sha256(publishedReceipt),
            ArchiveV2Hash.sha256(replacementReceipt)
        )

        let replacementURL = alternateRoot.appendingPathComponent(
            "receipts/sha256/\(manifestDigest.prefix(2))/\(manifestDigest)"
        )
        try FileManager.default.removeItem(at: receiptURL(manifestDigest))
        try FileManager.default.copyItem(at: replacementURL, to: receiptURL(manifestDigest))

        XCTAssertThrowsError(try store.warmListIndex()) { error in
            XCTAssertEqual(error as? ArchiveStoreError, .conflict)
        }
        XCTAssertThrowsError(try store.listMachines(cursor: nil, limit: 10)) { error in
            XCTAssertEqual(error as? ArchiveStoreError, .conflict)
        }
        XCTAssertThrowsError(
            try store.listReceipts(machineID: machineID, cursor: nil, limit: 10)
        ) { error in
            XCTAssertEqual(error as? ArchiveStoreError, .conflict)
        }
    }

    // MCP retro F11: a failed warm resets to cold so a repaired archive can rebuild.
    func testListIndexWarmFailureRecoversAfterArchiveRepair() throws {
        let machineID = "12121212-1212-1212-1212-121212121212"
        let store = try ArchiveStore(root: root, key: key, serverID: "hq")
        let manifestDigest = try publishReceipt(
            store: store,
            body: "list-index-recovery",
            machineID: machineID,
            captureSuffix: "list-index-recovery"
        )
        let invalidShard = root.appendingPathComponent("receipts/sha256/not-a-shard")
        try FileManager.default.createDirectory(
            at: invalidShard,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        XCTAssertThrowsError(try store.warmListIndex()) { error in
            XCTAssertEqual(error as? ArchiveStoreError, .conflict)
        }
        try FileManager.default.removeItem(at: invalidShard)

        XCTAssertNoThrow(try store.warmListIndex())
        XCTAssertEqual(
            try store.listMachines(cursor: nil, limit: 10).machineIDs,
            [machineID]
        )
        XCTAssertEqual(
            try store.listReceipts(machineID: machineID, cursor: nil, limit: 10)
                .receipts.map(\.manifestSHA256),
            [manifestDigest]
        )
    }

    func testListIndexWarmsOnceAndServesCursorPages() throws {
        let machineA = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        let machineB = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
        let store = try ArchiveStore(root: root, key: key, serverID: "hq")

        var aDigests: [String] = []
        var bDigests: [String] = []
        for i in 0..<3 {
            aDigests.append(try publishReceipt(
                store: store,
                body: "list-index-a-\(i)",
                machineID: machineA,
                captureSuffix: String(format: "a%02d", i)
            ))
        }
        for i in 0..<2 {
            bDigests.append(try publishReceipt(
                store: store,
                body: "list-index-b-\(i)",
                machineID: machineB,
                captureSuffix: String(format: "b%02d", i)
            ))
        }
        aDigests.sort()
        bDigests.sort()

        let firstMachines = try store.listMachines(cursor: nil, limit: 1)
        XCTAssertEqual(firstMachines.machineIDs, [machineA])
        XCTAssertNotNil(firstMachines.nextCursor)
        let secondMachines = try store.listMachines(
            cursor: firstMachines.nextCursor,
            limit: 1
        )
        XCTAssertEqual(secondMachines.machineIDs, [machineB])
        XCTAssertNil(secondMachines.nextCursor)

        let firstReceipts = try store.listReceipts(
            machineID: machineA,
            cursor: nil,
            limit: 2
        )
        XCTAssertEqual(
            firstReceipts.receipts.map(\.manifestSHA256),
            Array(aDigests.prefix(2))
        )
        XCTAssertNotNil(firstReceipts.nextCursor)
        let secondReceipts = try store.listReceipts(
            machineID: machineA,
            cursor: firstReceipts.nextCursor,
            limit: 2
        )
        XCTAssertEqual(
            secondReceipts.receipts.map(\.manifestSHA256),
            [aDigests[2]]
        )
        XCTAssertNil(secondReceipts.nextCursor)
        XCTAssertEqual(
            try store.listReceipts(machineID: machineB, cursor: nil, limit: 10)
                .receipts.map(\.manifestSHA256),
            bDigests
        )
    }

    func testListIndexSingleFlightBuildAndIncrementalNote() throws {
        // Single-flight: concurrent list/warm share one disk scan; receipts
        // published while cold still land in the index after build merges pending.
        let machineID = "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
        let buildCount = ArchiveStoreEventRecorder()
        let store = try ArchiveStore(
            root: root,
            key: key,
            serverID: "hq",
            testHooks: ArchiveStoreTestHooks(
                afterListIndexBuild: { buildCount.append(1) }
            )
        )
        let digestBefore = try publishReceipt(
            store: store,
            body: "list-index-before-warm",
            machineID: machineID,
            captureSuffix: "pre"
        )

        let group = DispatchGroup()
        let errors = ArchiveStoreEventRecorder()
        for _ in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                do {
                    _ = try store.listMachines(cursor: nil, limit: 10)
                } catch {
                    errors.append(1)
                }
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(errors.values, [])
        XCTAssertEqual(buildCount.values, [1], "warm must be single-flight")

        let digestAfter = try publishReceipt(
            store: store,
            body: "list-index-after-warm",
            machineID: machineID,
            captureSuffix: "post"
        )
        // No second disk rebuild: createReceipt notes into the ready index.
        XCTAssertEqual(buildCount.values, [1])
        XCTAssertEqual(
            try store.listReceipts(machineID: machineID, cursor: nil, limit: 10)
                .receipts.map(\.manifestSHA256).sorted(),
            [digestBefore, digestAfter].sorted()
        )
        try store.warmListIndex()
        XCTAssertEqual(buildCount.values, [1], "ready index is not rebuilt")
    }

    func testListIndexMergesReceiptPublishedDuringColdBuild() throws {
        let machineID = "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"
        let gate = DispatchSemaphore(value: 0)
        let buildEntered = DispatchSemaphore(value: 0)
        let store = try ArchiveStore(
            root: root,
            key: key,
            serverID: "hq",
            testHooks: ArchiveStoreTestHooks(
                afterListIndexBuild: {
                    buildEntered.signal()
                    gate.wait()
                }
            )
        )
        let digestPre = try publishReceipt(
            store: store,
            body: "list-index-during-pre",
            machineID: machineID,
            captureSuffix: "d0"
        )

        let listErrors = ArchiveStoreEventRecorder()
        let listGroup = DispatchGroup()
        listGroup.enter()
        DispatchQueue.global().async {
            do {
                _ = try store.listMachines(cursor: nil, limit: 10)
            } catch {
                listErrors.append(1)
            }
            listGroup.leave()
        }
        // Wait until the builder has finished forEachReceipt and is in the
        // afterListIndexBuild hook, then publish a receipt that must merge via pending.
        XCTAssertEqual(buildEntered.wait(timeout: .now() + 5), .success)
        let digestMid = try publishReceipt(
            store: store,
            body: "list-index-during-mid",
            machineID: machineID,
            captureSuffix: "d1"
        )
        gate.signal()
        listGroup.wait()
        XCTAssertEqual(listErrors.values, [])

        let listed = try store.listReceipts(
            machineID: machineID,
            cursor: nil,
            limit: 10
        ).receipts.map(\.manifestSHA256).sorted()
        XCTAssertEqual(listed, [digestPre, digestMid].sorted())
    }

    private func publishReceipt(
        store: ArchiveStore,
        body: String,
        machineID: String,
        captureSuffix: String
    ) throws -> String {
        let raw = Data(body.utf8)
        let objectDigest = ArchiveV2Hash.sha256(raw)
        // captureID must be a SHA-256 hex string; derive one from the suffix.
        let captureID = ArchiveV2Hash.sha256(Data(captureSuffix.utf8))
        let manifestBytes = try boundManifestBytes(
            raw: raw,
            objectDigest: objectDigest,
            machineID: machineID,
            captureID: captureID,
            sessionID: "session-\(captureSuffix)"
        )
        let manifestDigest = ArchiveV2Hash.sha256(manifestBytes)
        _ = try store.putObject(digest: objectDigest, raw: raw)
        _ = try store.putManifest(digest: manifestDigest, canonicalBytes: manifestBytes)
        _ = try store.createReceipt(manifestDigest: manifestDigest)
        return manifestDigest
    }

    private func boundManifestBytes(
        raw: Data,
        objectDigest: String,
        machineID: String,
        captureID: String = String(repeating: "e", count: 64),
        sessionID: String = "session-1"
    ) throws -> Data {
        let manifest = try ArchiveSourceManifest(
            captureID: captureID,
            machineID: machineID,
            source: "codex",
            locator: "/archive/source.jsonl",
            sessionID: sessionID,
            capturedAt: "2026-07-11T11:00:00.000Z",
            generation: ArchiveSourceGeneration(
                device: 1,
                inode: 2,
                size: Int64(raw.count),
                mtimeNs: 3,
                ctimeNs: 4,
                mode: Int64(S_IFREG | S_IRUSR | S_IWUSR)
            ),
            wholeSourceSHA256: objectDigest,
            rawByteCount: Int64(raw.count),
            chunks: [ArchiveChunkReference(
                ordinal: 0,
                rawSHA256: objectDigest,
                rawByteCount: Int64(raw.count)
            )],
            replayLayout: ArchiveReplayLayout(
                strategy: .singleFile,
                relativePaths: ["source.jsonl"]
            )
        )
        return try ArchiveCanonicalJSON.encode(manifest)
    }

    private func objectURL(_ digest: String) -> URL {
        root.appendingPathComponent("objects/sha256/\(digest.prefix(2))/\(digest)")
    }

    private func receiptURL(_ digest: String) -> URL {
        root.appendingPathComponent("receipts/sha256/\(digest.prefix(2))/\(digest)")
    }

    private func manifestURL(_ digest: String) -> URL {
        root.appendingPathComponent("manifests/sha256/\(digest.prefix(2))/\(digest)")
    }

    private func createParent(for url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func permissions(_ path: String) throws -> Int {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return Int(info.st_mode & 0o777)
    }

    private func fileSize(_ path: String) throws -> Int64 {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return info.st_size
    }

    private func identity(_ path: String) throws -> (
        inode: UInt64,
        mtimeSeconds: Int,
        mtimeNanoseconds: Int
    ) {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return (
            UInt64(info.st_ino),
            Int(info.st_mtimespec.tv_sec),
            Int(info.st_mtimespec.tv_nsec)
        )
    }
}

private final class ArchiveStoreEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int] = []

    var values: [Int] {
        lock.withLock { storage }
    }

    func append(_ value: Int) {
        lock.withLock { storage.append(value) }
    }
}

private final class ArchiveReceiptCreationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Result<ArchiveReceiptCreation, Error>] = []

    var values: [Result<ArchiveReceiptCreation, Error>] {
        lock.withLock { storage }
    }

    func append(_ value: Result<ArchiveReceiptCreation, Error>) {
        lock.withLock { storage.append(value) }
    }
}
