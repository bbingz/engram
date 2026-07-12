import Darwin
import EngramCoreRead
@testable import EngramCoreWrite
import XCTest

final class ImmutableArchiveCASTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-archive-cas-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    func testObjectAndManifestRoundTripExactBytesIncludingEmptyInput() throws {
        let cas = try ImmutableArchiveCAS(root: root)
        let binary = Data([0x00, 0xff, 0x0d, 0x0a, 0xef, 0xbb, 0xbf, 0x80])
        let binaryHash = ArchiveV2Hash.sha256(binary)
        let empty = Data()
        let emptyHash = ArchiveV2Hash.sha256(empty)
        let manifest = Data("{\"raw\":\"bytes\"}".utf8)
        let manifestHash = ArchiveV2Hash.sha256(manifest)

        XCTAssertEqual(
            try cas.publishObject(raw: binary, expectedSHA256: binaryHash),
            .published
        )
        XCTAssertEqual(try cas.readObject(sha256: binaryHash), binary)
        XCTAssertEqual(
            try cas.publishObject(raw: empty, expectedSHA256: emptyHash),
            .published
        )
        XCTAssertEqual(try cas.readObject(sha256: emptyHash), empty)
        XCTAssertEqual(
            try cas.publishManifest(manifest, expectedSHA256: manifestHash),
            .published
        )
        XCTAssertEqual(try cas.readManifest(sha256: manifestHash), manifest)
    }

    func testDuplicatePublishRevalidatesWithoutChangingInodeOrModificationTime() throws {
        let cas = try ImmutableArchiveCAS(root: root)
        let raw = Data("immutable payload".utf8)
        let digest = ArchiveV2Hash.sha256(raw)

        XCTAssertEqual(try cas.publishObject(raw: raw, expectedSHA256: digest), .published)
        let path = objectURL(digest).path
        let before = try fileIdentity(path)

        Thread.sleep(forTimeInterval: 0.02)
        XCTAssertEqual(try cas.publishObject(raw: raw, expectedSHA256: digest), .alreadyPresent)
        let after = try fileIdentity(path)

        XCTAssertEqual(after.inode, before.inode)
        XCTAssertEqual(after.mtimeSeconds, before.mtimeSeconds)
        XCTAssertEqual(after.mtimeNanoseconds, before.mtimeNanoseconds)
    }

    func testExpectedDigestMismatchPublishesNothing() throws {
        let cas = try ImmutableArchiveCAS(root: root)
        let raw = Data("actual".utf8)
        let expected = ArchiveV2Hash.sha256(Data("different".utf8))
        let actual = ArchiveV2Hash.sha256(raw)

        XCTAssertThrowsError(try cas.publishObject(raw: raw, expectedSHA256: expected)) { error in
            XCTAssertEqual(
                error as? ImmutableArchiveCASError,
                .digestMismatch(expected: expected, actual: actual)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: objectURL(expected).path))
    }

    func testCorruptExistingObjectConflictsWithoutOverwrite() throws {
        let cas = try ImmutableArchiveCAS(root: root)
        let raw = Data("correct bytes".utf8)
        let expected = ArchiveV2Hash.sha256(raw)
        let corrupt = Data("corrupt bytes".utf8)
        try createFinalParent(for: objectURL(expected))
        XCTAssertTrue(FileManager.default.createFile(
            atPath: objectURL(expected).path,
            contents: corrupt,
            attributes: [.posixPermissions: 0o600]
        ))

        XCTAssertThrowsError(try cas.publishObject(raw: raw, expectedSHA256: expected)) { error in
            XCTAssertEqual(
                error as? ImmutableArchiveCASError,
                .existingContentConflict(
                    expected: expected,
                    actual: ArchiveV2Hash.sha256(corrupt)
                )
            )
        }
        XCTAssertEqual(try Data(contentsOf: objectURL(expected)), corrupt)
    }

    func testCorrectExistingObjectWithNonOwnerOnlyModeIsRejected() throws {
        let cas = try ImmutableArchiveCAS(root: root)
        let raw = Data("correct but exposed".utf8)
        let digest = ArchiveV2Hash.sha256(raw)
        try createFinalParent(for: objectURL(digest))
        XCTAssertTrue(FileManager.default.createFile(
            atPath: objectURL(digest).path,
            contents: raw
        ))
        XCTAssertEqual(chmod(objectURL(digest).path, 0o644), 0)

        XCTAssertThrowsError(
            try cas.publishObject(raw: raw, expectedSHA256: digest)
        ) { error in
            XCTAssertEqual(
                error as? ImmutableArchiveCASError,
                .unsafeExistingPath(objectURL(digest).path)
            )
        }
        XCTAssertEqual(try permissions(objectURL(digest).path), 0o644)
    }

    func testHardLinkedFinalObjectIsRejected() throws {
        let cas = try ImmutableArchiveCAS(root: root)
        let raw = Data("linked archive bytes".utf8)
        let digest = ArchiveV2Hash.sha256(raw)
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("engram-archive-hardlink-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        XCTAssertTrue(FileManager.default.createFile(
            atPath: outside.path,
            contents: raw,
            attributes: [.posixPermissions: 0o600]
        ))
        try createFinalParent(for: objectURL(digest))
        XCTAssertEqual(link(outside.path, objectURL(digest).path), 0)

        XCTAssertThrowsError(
            try cas.publishObject(raw: raw, expectedSHA256: digest)
        ) { error in
            XCTAssertEqual(
                error as? ImmutableArchiveCASError,
                .unsafeExistingPath(objectURL(digest).path)
            )
        }
        XCTAssertEqual(try Data(contentsOf: outside), raw)
    }

    func testExistingFinalReplacementAfterVerifiedReadIsRejected() throws {
        let raw = Data("verified archive bytes".utf8)
        let digest = ArchiveV2Hash.sha256(raw)
        let initial = try ImmutableArchiveCAS(root: root)
        XCTAssertEqual(
            try initial.publishObject(raw: raw, expectedSHA256: digest),
            .published
        )

        let backup = objectURL(digest).appendingPathExtension("verified-backup")
        let hooks = ImmutableArchiveCASTestHooks(
            afterExistingFileVerified: { finalURL in
                try FileManager.default.moveItem(at: finalURL, to: backup)
                guard FileManager.default.createFile(
                    atPath: finalURL.path,
                    contents: raw,
                    attributes: [.posixPermissions: 0o600]
                ) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
        )
        let raced = try ImmutableArchiveCAS(root: root, testHooks: hooks)

        XCTAssertThrowsError(
            try raced.publishObject(raw: raw, expectedSHA256: digest)
        ) { error in
            XCTAssertEqual(
                error as? ImmutableArchiveCASError,
                .unsafeExistingPath(objectURL(digest).path)
            )
        }
        XCTAssertEqual(try Data(contentsOf: objectURL(digest)), raw)
        XCTAssertEqual(try Data(contentsOf: backup), raw)
    }

    func testSymlinkAtFinalPathIsRejectedWithoutTouchingTarget() throws {
        let cas = try ImmutableArchiveCAS(root: root)
        let raw = Data("archive bytes".utf8)
        let digest = ArchiveV2Hash.sha256(raw)
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("engram-archive-outside-\(UUID().uuidString)")
        let outsideBytes = Data("outside".utf8)
        XCTAssertTrue(FileManager.default.createFile(atPath: outside.path, contents: outsideBytes))
        defer { try? FileManager.default.removeItem(at: outside) }
        try createFinalParent(for: objectURL(digest))
        try FileManager.default.createSymbolicLink(
            atPath: objectURL(digest).path,
            withDestinationPath: outside.path
        )

        XCTAssertThrowsError(try cas.publishObject(raw: raw, expectedSHA256: digest)) { error in
            guard case ImmutableArchiveCASError.unsafeExistingPath = error else {
                return XCTFail("expected unsafeExistingPath, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: outside), outsideBytes)
    }

    func testArchiveDirectoriesAndFinalFilesAreOwnerOnly() throws {
        let cas = try ImmutableArchiveCAS(root: root)
        let object = Data("object".utf8)
        let objectHash = ArchiveV2Hash.sha256(object)
        let manifest = Data("manifest".utf8)
        let manifestHash = ArchiveV2Hash.sha256(manifest)
        _ = try cas.publishObject(raw: object, expectedSHA256: objectHash)
        _ = try cas.publishManifest(manifest, expectedSHA256: manifestHash)

        for directory in [
            root!,
            root.appendingPathComponent("objects/sha256", isDirectory: true),
            objectURL(objectHash).deletingLastPathComponent(),
            root.appendingPathComponent("manifests/sha256", isDirectory: true),
            manifestURL(manifestHash).deletingLastPathComponent(),
            root.appendingPathComponent("tmp", isDirectory: true),
        ] {
            XCTAssertEqual(try permissions(directory.path), 0o700, directory.path)
        }
        XCTAssertEqual(try permissions(objectURL(objectHash).path), 0o600)
        XCTAssertEqual(try permissions(manifestURL(manifestHash).path), 0o600)
    }

    func testCASExposesOnlyObjectScopedRemoval() throws {
        let text = try casSource()
        XCTAssertFalse(text.contains("public func delete"))
        XCTAssertTrue(text.contains("public func removeObject"))
        XCTAssertFalse(text.contains("removeManifest"))
    }

    func testNewDirectoryPublicationFsyncsDirectoryAndItsParent() throws {
        let recorder = ArchiveCASEventRecorder()
        let hooks = ImmutableArchiveCASTestHooks(
            afterDirectoryFsync: { url in
                recorder.append("fsync:\(url.path)")
            },
            afterFinalLinkPublished: { url in
                recorder.append("link:\(url.path)")
            }
        )
        let cas = try ImmutableArchiveCAS(root: root, testHooks: hooks)
        let raw = Data("directory durability".utf8)
        let digest = ArchiveV2Hash.sha256(raw)
        _ = try cas.publishObject(raw: raw, expectedSHA256: digest)

        let shard = objectURL(digest).deletingLastPathComponent()
        let base = shard.deletingLastPathComponent()
        let events = recorder.events
        let shardCreation = try XCTUnwrap(events.firstIndex(of: "fsync:\(shard.path)"))
        XCTAssertEqual(events[events.index(after: shardCreation)], "fsync:\(base.path)")
        let linkPublication = try XCTUnwrap(
            events.firstIndex(of: "link:\(objectURL(digest).path)")
        )
        XCTAssertGreaterThan(linkPublication, shardCreation)
        XCTAssertTrue(
            events[events.index(after: linkPublication)...]
                .contains("fsync:\(shard.path)")
        )
    }

    private func objectURL(_ digest: String) -> URL {
        root.appendingPathComponent("objects/sha256/\(digest.prefix(2))/\(digest)")
    }

    private func manifestURL(_ digest: String) -> URL {
        root.appendingPathComponent("manifests/sha256/\(digest.prefix(2))/\(digest).json")
    }

    private func createFinalParent(for url: URL) throws {
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

    private func casSource() throws -> String {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("EngramCoreWrite/ArchiveV2/ImmutableArchiveCAS.swift")
        return try String(contentsOf: source, encoding: .utf8)
    }

    private func fileIdentity(_ path: String) throws -> (
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

private final class ArchiveCASEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var events: [String] {
        lock.withLock { storage }
    }

    func append(_ event: String) {
        lock.withLock { storage.append(event) }
    }
}
