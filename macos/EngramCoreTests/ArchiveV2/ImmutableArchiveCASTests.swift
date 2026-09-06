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

    func testPostFinalLinkThrowRemovesOnlyStagingAlias_repro() throws {
        enum Marker: Error {
            case stopAfterFinalLink
        }

        let raw = Data("published before injected failure".utf8)
        let digest = ArchiveV2Hash.sha256(raw)
        let hooks = ImmutableArchiveCASTestHooks(
            afterFinalLinkPublished: { _ in
                throw Marker.stopAfterFinalLink
            }
        )
        let cas = try ImmutableArchiveCAS(root: root, testHooks: hooks)

        XCTAssertThrowsError(
            try cas.publishObject(raw: raw, expectedSHA256: digest)
        ) { error in
            guard case Marker.stopAfterFinalLink = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: objectURL(digest)), raw)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                at: root.appendingPathComponent("tmp", isDirectory: true),
                includingPropertiesForKeys: nil
            ).isEmpty
        )
        var info = stat()
        XCTAssertEqual(lstat(objectURL(digest).path, &info), 0)
        XCTAssertEqual(info.st_nlink, 1)
    }

    func testBoundedReadsAcceptExactLargerAndZeroEmptyBudgets() throws {
        let cas = try ImmutableArchiveCAS(root: root)
        for kind in CASReadKind.allCases {
            for bytes in [Data(), Data([0, 0xff, 0x0a, 0x80])] {
                let digest = try publishReadFixture(bytes, kind: kind, cas: cas)
                for budget in [Int64(bytes.count), Int64(bytes.count + 1), Int64.max] {
                    XCTAssertEqual(try Self.boundedRead(cas, kind: kind, digest: digest, budget: budget), bytes)
                }
                XCTAssertEqual(try Self.unboundedRead(cas, kind: kind, digest: digest), bytes)
            }
        }
    }

    func testBoundedReadsRejectNegativeBudgetsBeforeFilesystemAccess() throws {
        let cas = try ImmutableArchiveCAS(root: root)
        let missingDigest = ArchiveV2Hash.sha256(Data("never published".utf8))
        for kind in CASReadKind.allCases {
            for budget in [Int64(-1), Int64.min] {
                XCTAssertThrowsError(try Self.boundedRead(cas, kind: kind, digest: missingDigest, budget: budget)) {
                    XCTAssertEqual($0 as? ImmutableArchiveCASReadLimitError, .invalidMaximumByteCount)
                }
            }
        }
    }

    func testBoundedReadsRejectActualOversizeBeforeAllocationAndDigestWork() throws {
        let recorder = ArchiveCASEventRecorder()
        let cas = try ImmutableArchiveCAS(root: root, testHooks: ImmutableArchiveCASTestHooks(
            beforeBoundedReadAllocation: { _ in recorder.append("allocation") }
        ))
        for kind in CASReadKind.allCases {
            for validDigest in [true, false] {
                let bytes = Data("small oversize fixture \(kind) \(validDigest)".utf8)
                let digest = ArchiveV2Hash.sha256(validDigest ? bytes : Data("different digest \(kind)".utf8))
                try installReadFixture(bytes, digest: digest, kind: kind)
                for budget in [Int64(0), Int64(bytes.count - 1)] {
                    XCTAssertThrowsError(try Self.boundedRead(cas, kind: kind, digest: digest, budget: budget)) {
                        XCTAssertEqual($0 as? ImmutableArchiveCASReadLimitError, .exceeded(maximumByteCount: budget))
                    }
                }
            }
        }
        XCTAssertTrue(recorder.events.isEmpty, "Oversized fstat results must fail before the allocation hook")
    }

    func testBoundedReadsRejectGrowthAfterInitialFstat() throws {
        for kind in CASReadKind.allCases {
            let initial = Data("initial \(kind)".utf8)
            let suffix = Data(" growth".utf8)
            let digest = ArchiveV2Hash.sha256(initial + suffix)
            let recorder = ArchiveCASEventRecorder()
            let cas = try ImmutableArchiveCAS(root: root, testHooks: ImmutableArchiveCASTestHooks(
                beforeBoundedReadAllocation: { url in
                    recorder.append("opened")
                    try Self.appendReadFixture(suffix, to: url)
                }
            ))
            try installReadFixture(initial, digest: digest, kind: kind)
            let budget = Int64(initial.count)
            XCTAssertThrowsError(try Self.boundedRead(cas, kind: kind, digest: digest, budget: budget)) {
                XCTAssertEqual($0 as? ImmutableArchiveCASReadLimitError, .exceeded(maximumByteCount: budget))
            }
            XCTAssertEqual(recorder.events, ["opened"])
        }
    }

    func testBoundedReadsRejectGrowthBetweenChunksBeforeAppendingPastBudget() throws {
        for kind in CASReadKind.allCases {
            let initial = Data(repeating: 0x61, count: 64 * 1024)
            let suffix = Data([0x62, 0x63, 0x64])
            let digest = ArchiveV2Hash.sha256(initial + suffix)
            let budget = Int64(initial.count + 2)
            let recorder = ArchiveCASEventRecorder()
            let cas = try ImmutableArchiveCAS(root: root, testHooks: ImmutableArchiveCASTestHooks(
                afterBoundedReadChunk: { url, total in
                    recorder.append(String(total))
                    if total == initial.count { try Self.appendReadFixture(suffix, to: url) }
                }
            ))
            try installReadFixture(initial, digest: digest, kind: kind)
            XCTAssertThrowsError(try Self.boundedRead(cas, kind: kind, digest: digest, budget: budget)) {
                XCTAssertEqual($0 as? ImmutableArchiveCASReadLimitError, .exceeded(maximumByteCount: budget))
            }
            XCTAssertEqual(recorder.events, [String(initial.count)], "The over-budget chunk must not be appended")
        }
    }

    func testBoundedReadsRejectGrowthAfterDigestVerification() throws {
        for kind in CASReadKind.allCases {
            let bytes = Data("verified then grown \(kind)".utf8)
            let digest = ArchiveV2Hash.sha256(bytes)
            let recorder = ArchiveCASEventRecorder()
            let cas = try ImmutableArchiveCAS(root: root, testHooks: ImmutableArchiveCASTestHooks(
                afterExistingFileVerified: { url in
                    recorder.append("verified")
                    try Self.appendReadFixture(Data([0x21]), to: url)
                }
            ))
            try installReadFixture(bytes, digest: digest, kind: kind)
            let budget = Int64(bytes.count)
            XCTAssertThrowsError(try Self.boundedRead(cas, kind: kind, digest: digest, budget: budget)) {
                XCTAssertEqual($0 as? ImmutableArchiveCASReadLimitError, .exceeded(maximumByteCount: budget))
            }
            XCTAssertEqual(recorder.events, ["verified"])
        }
    }

    func testBoundedReadsRetainDigestValidationWithinBudget() throws {
        let cas = try ImmutableArchiveCAS(root: root)
        for kind in CASReadKind.allCases {
            let bytes = Data("corrupt within budget \(kind)".utf8)
            let expected = ArchiveV2Hash.sha256(Data("expected \(kind)".utf8))
            try installReadFixture(bytes, digest: expected, kind: kind)
            XCTAssertThrowsError(try Self.boundedRead(cas, kind: kind, digest: expected, budget: Int64(bytes.count))) {
                XCTAssertEqual($0 as? ImmutableArchiveCASError, .digestMismatch(expected: expected, actual: ArchiveV2Hash.sha256(bytes)))
            }
        }
    }

    func testBoundedReadsRetainModeHardLinkAndSymlinkChecksWithoutRepair() throws {
        let cas = try ImmutableArchiveCAS(root: root)
        for kind in CASReadKind.allCases {
            for mutation in ["mode", "hardlink", "symlink"] {
                let bytes = Data("unsafe \(kind) \(mutation)".utf8)
                let digest = ArchiveV2Hash.sha256(bytes)
                let final = readFixtureURL(digest, kind: kind)
                let adjacent = root.appendingPathComponent("adjacent-\(kind)-\(mutation)")
                if mutation == "symlink" {
                    try createFinalParent(for: final)
                    XCTAssertTrue(FileManager.default.createFile(atPath: adjacent.path, contents: bytes, attributes: [.posixPermissions: 0o600]))
                    try FileManager.default.createSymbolicLink(at: final, withDestinationURL: adjacent)
                } else {
                    try installReadFixture(bytes, digest: digest, kind: kind)
                    if mutation == "mode" { XCTAssertEqual(chmod(final.path, 0o644), 0) }
                    if mutation == "hardlink" { XCTAssertEqual(link(final.path, adjacent.path), 0) }
                }
                XCTAssertThrowsError(try Self.boundedRead(cas, kind: kind, digest: digest, budget: Int64(bytes.count))) {
                    XCTAssertEqual($0 as? ImmutableArchiveCASError, .unsafeExistingPath(final.path))
                }
                XCTAssertEqual(try Data(contentsOf: final), bytes)
                if mutation == "mode" { XCTAssertEqual(try permissions(final.path), 0o644) }
                if mutation == "symlink" { XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: final.path), adjacent.path) }
                if mutation == "hardlink" {
                    var info = stat()
                    XCTAssertEqual(lstat(final.path, &info), 0)
                    XCTAssertEqual(info.st_nlink, 2)
                }
            }
        }
    }

    func testBoundedReadsRetainFinalPathIdentityValidation() throws {
        for kind in CASReadKind.allCases {
            let bytes = Data("same bytes different inode \(kind)".utf8)
            let digest = ArchiveV2Hash.sha256(bytes)
            let final = readFixtureURL(digest, kind: kind)
            let backup = final.appendingPathExtension("backup")
            let cas = try ImmutableArchiveCAS(root: root, testHooks: ImmutableArchiveCASTestHooks(
                afterExistingFileVerified: { url in
                    try FileManager.default.moveItem(at: url, to: backup)
                    guard FileManager.default.createFile(atPath: url.path, contents: bytes, attributes: [.posixPermissions: 0o600]) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
            ))
            try installReadFixture(bytes, digest: digest, kind: kind)
            XCTAssertThrowsError(try Self.boundedRead(cas, kind: kind, digest: digest, budget: Int64(bytes.count))) {
                XCTAssertEqual($0 as? ImmutableArchiveCASError, .unsafeExistingPath(final.path))
            }
            XCTAssertEqual(try Data(contentsOf: final), bytes)
            XCTAssertEqual(try Data(contentsOf: backup), bytes)
        }
    }

    func testBoundedReadsPreserveAlreadyCancelledTaskWithoutChangingLegacyReads() async throws {
        let recorder = ArchiveCASEventRecorder()
        let cas = try ImmutableArchiveCAS(root: root, testHooks: ImmutableArchiveCASTestHooks(
            beforeBoundedReadAllocation: { _ in recorder.append("allocation") }
        ))
        for kind in CASReadKind.allCases {
            let bytes = Data("cancel before reading \(kind)".utf8)
            let digest = try publishReadFixture(bytes, kind: kind, cas: cas)
            let result = try await Task.detached {
                withUnsafeCurrentTask { $0?.cancel() }
                let legacy = try Self.unboundedRead(cas, kind: kind, digest: digest)
                do {
                    _ = try Self.boundedRead(cas, kind: kind, digest: digest, budget: Int64(bytes.count))
                    return (legacy, false)
                } catch is CancellationError {
                    return (legacy, true)
                }
            }.value
            XCTAssertEqual(result.0, bytes)
            XCTAssertTrue(result.1, "The new bounded API must preserve CancellationError")
        }
        XCTAssertTrue(recorder.events.isEmpty)
    }

    func testBoundedReadsObserveTaskCancellationBetweenChunks() async throws {
        for kind in CASReadKind.allCases {
            let bytes = Data(repeating: 0x61, count: 64 * 1024 + 1)
            let recorder = ArchiveCASEventRecorder()
            let cas = try ImmutableArchiveCAS(root: root, testHooks: ImmutableArchiveCASTestHooks(
                afterBoundedReadChunk: { _, total in
                    recorder.append(String(total))
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            ))
            let digest = try publishReadFixture(bytes, kind: kind, cas: cas)
            let cancelled = try await Task.detached {
                do {
                    _ = try Self.boundedRead(cas, kind: kind, digest: digest, budget: Int64(bytes.count))
                    return false
                } catch is CancellationError {
                    return true
                }
            }.value
            XCTAssertTrue(cancelled)
            XCTAssertEqual(recorder.events, [String(64 * 1024)])
        }
    }

    private enum CASReadKind: CaseIterable, Sendable { case object, manifest }

    private static func boundedRead(_ cas: ImmutableArchiveCAS, kind: CASReadKind, digest: String, budget: Int64) throws -> Data {
        switch kind {
        case .object: try cas.readObject(sha256: digest, maximumByteCount: budget)
        case .manifest: try cas.readManifest(sha256: digest, maximumByteCount: budget)
        }
    }

    private static func unboundedRead(_ cas: ImmutableArchiveCAS, kind: CASReadKind, digest: String) throws -> Data {
        switch kind {
        case .object: try cas.readObject(sha256: digest)
        case .manifest: try cas.readManifest(sha256: digest)
        }
    }

    private func publishReadFixture(_ bytes: Data, kind: CASReadKind, cas: ImmutableArchiveCAS) throws -> String {
        let digest = ArchiveV2Hash.sha256(bytes)
        switch kind {
        case .object: _ = try cas.publishObject(raw: bytes, expectedSHA256: digest)
        case .manifest: _ = try cas.publishManifest(bytes, expectedSHA256: digest)
        }
        return digest
    }

    private func installReadFixture(_ bytes: Data, digest: String, kind: CASReadKind) throws {
        let final = readFixtureURL(digest, kind: kind)
        try createFinalParent(for: final)
        guard FileManager.default.createFile(atPath: final.path, contents: bytes, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func readFixtureURL(_ digest: String, kind: CASReadKind) -> URL {
        switch kind {
        case .object: objectURL(digest)
        case .manifest: manifestURL(digest)
        }
    }

    private static func appendReadFixture(_ bytes: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: bytes)
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
            .appendingPathComponent("EngramCaptureShared/ImmutableArchiveCAS.swift")
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
