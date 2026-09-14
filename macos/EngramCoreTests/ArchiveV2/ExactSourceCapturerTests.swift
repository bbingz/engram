import Darwin
import Foundation
import GRDB
import XCTest
@testable import EngramCoreRead
@testable import EngramCoreWrite

final class ExactSourceCapturerTests: XCTestCase {
    private let machineID = "11111111-2222-3333-4444-555555555555"
    private var root: URL!

    func testSQLiteImageCaptureUsesSchemaFourWithoutReadingLogicalSource() throws {
        let image = try sqliteImageFixture()
        let archive = root.appendingPathComponent("image-archive")
        let cas = try ImmutableArchiveCAS(root: archive)
        let catalog = try ArchiveCatalog(root: archive, machineID: machineID)
        try catalog.migrate()
        defer { try? catalog.close() }
        let generation = try ArchiveSourceGeneration(device: 1, inode: 2, size: 819200,
            mtimeNs: 5, ctimeNs: 6, mode: 0o100600)
        let context = try ArchiveSQLiteSessionContext(databaseLocator: "/offline/opencode.db",
            nativeSessionID: "ses-one", nativePayloadByteCount: 10, walGeneration: nil)
        let result = try ExactSourceCapturer.captureSQLiteSessionImage(image, context: context,
            generation: generation, machineID: machineID, cas: cas, catalog: catalog)
        XCTAssertEqual(result.manifest.schemaVersion, 4)
        XCTAssertEqual(result.manifest.source, "opencode")
        XCTAssertEqual(result.manifest.locator, "/offline/opencode.db::ses-one")
        XCTAssertNil(result.manifest.sessionID)
        XCTAssertEqual(result.manifest.generation, generation)
        XCTAssertEqual(result.manifest.rawByteCount, Int64(image.count))
        XCTAssertEqual(result.manifest.replayLayout.sqliteSession, context)
        let restored = try result.manifest.chunks.reduce(into: Data()) { bytes, chunk in
            bytes.append(try cas.readObject(sha256: chunk.rawSHA256))
        }
        XCTAssertEqual(restored, image)
        XCTAssertEqual(try catalog.capture(captureID: result.manifest.captureID), result.capture)
        let repeated = try ExactSourceCapturer.captureSQLiteSessionImage(image, context: context,
            generation: generation, machineID: machineID, cas: cas, catalog: catalog)
        XCTAssertEqual(repeated, result, "recovery must reuse canonical manifest bytes and capture time")
    }

    func testSQLiteImageIdentityIncludesNativeScopeAndObservedWALProvenance() throws {
        let image = try sqliteImageFixture()
        let archive = root.appendingPathComponent("image-identities")
        let cas = try ImmutableArchiveCAS(root: archive)
        let catalog = try ArchiveCatalog(root: archive, machineID: machineID)
        try catalog.migrate()
        defer { try? catalog.close() }
        let generation = try ArchiveSourceGeneration(device: 1, inode: 2, size: 819200,
            mtimeNs: 5, ctimeNs: 6, mode: 0o100600)
        var ids = Set<String>()
        for (id, wal) in [("ses-one", nil), ("ses-other", nil), ("ses-one", generation)] {
            let context = try ArchiveSQLiteSessionContext(databaseLocator: "/offline/opencode.db",
                nativeSessionID: id, nativePayloadByteCount: 10, walGeneration: wal)
            let result = try ExactSourceCapturer.captureSQLiteSessionImage(image, context: context,
                generation: generation, machineID: machineID, cas: cas, catalog: catalog)
            ids.insert(result.manifest.captureID)
            XCTAssertEqual(result.manifest.wholeSourceSHA256, ArchiveV2Hash.sha256(image))
        }
        XCTAssertEqual(ids.count, 3)
    }

    func testSQLiteImageCaptureRejectsBudgetAndMachineMismatchBeforeCatalogInsert() throws {
        let image = try sqliteImageFixture()
        let archive = root.appendingPathComponent("image-refusal")
        let cas = try ImmutableArchiveCAS(root: archive)
        let catalog = try ArchiveCatalog(root: archive, machineID: machineID)
        try catalog.migrate()
        defer { try? catalog.close() }
        let generation = try ArchiveSourceGeneration(device: 1, inode: 2, size: 819200,
            mtimeNs: 5, ctimeNs: 6, mode: 0o100600)
        let context = try ArchiveSQLiteSessionContext(databaseLocator: "/offline/opencode.db",
            nativeSessionID: "ses-one", nativePayloadByteCount: 10, walGeneration: nil)
        XCTAssertThrowsError(try ExactSourceCapturer.captureSQLiteSessionImage(image, context: context,
            generation: generation, machineID: machineID, cas: cas, catalog: catalog, maximumByteCount: 1)) {
            XCTAssertEqual($0 as? ExactSourceCapturerError, .exceededMaximumByteCount(1))
        }
        XCTAssertThrowsError(try ExactSourceCapturer.captureSQLiteSessionImage(image, context: context,
            generation: generation, machineID: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA", cas: cas, catalog: catalog)) {
            XCTAssertEqual($0 as? ExactSourceCapturerError,
                .machineIDMismatch(expected: self.machineID, actual: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"))
        }
    }

    func testSQLiteImageCrossChunkCaptureRepairsMissingManifestWithoutChangingIdentity() throws {
        let image = try sqliteImageFixture(payloadBytes: Int(ArchiveSourceManifest.rawChunkSize) + 4096)
        let archive = root.appendingPathComponent("image-repair")
        let cas = try ImmutableArchiveCAS(root: archive)
        let catalog = try ArchiveCatalog(root: archive, machineID: machineID)
        try catalog.migrate()
        defer { try? catalog.close() }
        let generation = try ArchiveSourceGeneration(device: 1, inode: 2, size: 819200,
            mtimeNs: 5, ctimeNs: 6, mode: 0o100600)
        let context = try ArchiveSQLiteSessionContext(databaseLocator: "/offline/opencode.db",
            nativeSessionID: "ses-one", nativePayloadByteCount: 10, walGeneration: nil)
        let first = try ExactSourceCapturer.captureSQLiteSessionImage(image, context: context,
            generation: generation, machineID: machineID, cas: cas, catalog: catalog)
        XCTAssertEqual(first.manifest.chunks.count, 2)
        XCTAssertEqual(first.manifest.chunks[0].rawByteCount, ArchiveSourceManifest.rawChunkSize)
        let file = manifestURL(storeRoot: archive, sha256: first.capture.unboundManifestSHA256)
        try FileManager.default.removeItem(at: file)
        let repeated = try ExactSourceCapturer.captureSQLiteSessionImage(image, context: context,
            generation: generation, machineID: machineID, cas: cas, catalog: catalog)
        XCTAssertEqual(repeated, first)
        XCTAssertEqual(try Data(contentsOf: file), first.capture.unboundManifestBytes)
        let restored = try first.manifest.chunks.reduce(into: Data()) { result, chunk in
            result.append(try cas.readObject(sha256: chunk.rawSHA256))
        }
        XCTAssertEqual(restored, image)
        XCTAssertEqual(try catalog.unboundCaptures(limit: 10), [first.capture])
    }

    func testCursorSealedMembersPersistOriginalProvenanceAcrossChunksAndReopen() throws {
        let archive = root.appendingPathComponent("cursor-sealed")
        let (cas, catalog) = try makeStore(archive)
        defer { try? catalog.close() }
        let main = try cursorMember("chats/ws/id/store.db", Data(repeating: 0xff, count: Int(ArchiveSourceManifest.rawChunkSize) - 3))
        let wal = try cursorMember("chats/ws/id/store.db-wal", Data([0, 128, 255, 10]))
        let meta = try cursorMember("chats/ws/id/meta.json", Data("{invalid-json".utf8))
        let transcript = try cursorMember("projects/proj/agent-transcripts/id/id.jsonl", Data([255, 13, 10]))
        let members = [transcript, wal, main, meta]
        let locator = root.appendingPathComponent("deleted-source/" + transcript.relativePath).path
        XCTAssertFalse(FileManager.default.fileExists(atPath: locator))
        let capture = try ExactSourceCapturer.captureCursorModernFileSet(members, locator: locator,
            absentRelativePaths: [], machineID: machineID, cas: cas, catalog: catalog)
        XCTAssertEqual(capture.manifest.schemaVersion, 2)
        XCTAssertTrue(ArchiveSourceDescriptor.isCursorModernFileSet(capture.manifest))
        XCTAssertEqual(capture.manifest.generation, transcript.generation)
        XCTAssertEqual(capture.manifest.locator, locator)
        XCTAssertEqual(capture.manifest.chunks.count, 2)
        let sorted = members.sorted { $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8) }
        let original = sorted.reduce(into: Data()) { $0.append($1.bytes) }
        XCTAssertEqual(try reconstruct(capture.manifest, from: cas), original)
        for (entry, member) in zip(try XCTUnwrap(capture.manifest.replayLayout.files), sorted) {
            XCTAssertEqual(entry.relativePath, member.relativePath)
            XCTAssertEqual(entry.generation, member.generation)
            XCTAssertEqual(entry.wholeSourceSHA256, ArchiveV2Hash.sha256(member.bytes))
            XCTAssertEqual(original.subdata(in: Int(entry.byteOffset)..<Int(entry.byteOffset + entry.rawByteCount)), member.bytes)
        }
        try catalog.close()
        let reopened = try ArchiveCatalog(root: archive, machineID: machineID)
        try reopened.migrate()
        defer { try? reopened.close() }
        XCTAssertEqual(try reopened.capture(captureID: capture.manifest.captureID), capture.capture)
        let repeated = try ExactSourceCapturer.captureCursorModernFileSet(members, locator: locator,
            absentRelativePaths: [], machineID: machineID, cas: cas, catalog: reopened)
        XCTAssertEqual(repeated, capture, "canonical bytes and capture timestamp survive restart")
    }

    func testCursorSealedIdentityIncludesEmptyWALMembershipAndAuxiliaryGeneration() throws {
        let (cas, catalog) = try makeStore(root.appendingPathComponent("cursor-identity"))
        defer { try? catalog.close() }
        let main = try cursorMember("chats/ws/id/store.db", Data("raw-main".utf8))
        let wal = try cursorMember("chats/ws/id/store.db-wal", Data())
        let laterWAL = try cursorMember(wal.relativePath, Data(), mtime: 99)
        let locator = root.appendingPathComponent("missing/" + main.relativePath).path
        var captures: [ArchiveCaptureResult] = []
        for members in [[main], [main, wal], [main, laterWAL]] {
            let absent = members.count == 1 ? ["chats/ws/id/meta.json", wal.relativePath] : ["chats/ws/id/meta.json"]
            captures.append(try ExactSourceCapturer.captureCursorModernFileSet(members, locator: locator,
                absentRelativePaths: absent, machineID: machineID, cas: cas, catalog: catalog))
        }
        XCTAssertEqual(Set(captures.map { $0.manifest.captureID }).count, 3)
        XCTAssertEqual(Set(captures.map { $0.manifest.wholeSourceSHA256 }).count, 1)
        XCTAssertTrue(captures.allSatisfy { $0.manifest.generation == main.generation })
    }

    func testCursorSealedCaptureRejectsInvalidShapeSizeBudgetAndMachineBeforeCatalogWrite() throws {
        let archive = root.appendingPathComponent("cursor-refusal")
        let (cas, catalog) = try makeStore(archive)
        defer { try? catalog.close() }
        let main = try cursorMember("chats/ws/id/store.db", Data("main".utf8))
        let locator = root.appendingPathComponent("missing/" + main.relativePath).path
        let absent = ["chats/ws/id/meta.json", "chats/ws/id/store.db-wal"]
        let badSize = ArchiveCapturedFile(relativePath: main.relativePath, generation: main.generation, bytes: Data())
        let shm = try cursorMember("chats/ws/id/store.db-shm", Data("SECRET".utf8))
        for members in [[], [badSize], [main, main], [main, shm]] {
            XCTAssertThrowsError(try ExactSourceCapturer.captureCursorModernFileSet(members, locator: locator,
                absentRelativePaths: absent, machineID: machineID, cas: cas, catalog: catalog))
        }
        for limit in [Int64(-1), Int64(3)] {
            XCTAssertThrowsError(try ExactSourceCapturer.captureCursorModernFileSet([main], locator: locator,
                absentRelativePaths: absent, machineID: machineID, cas: cas, catalog: catalog, maximumByteCount: limit))
        }
        for identity in ["invalid", "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"] {
            XCTAssertThrowsError(try ExactSourceCapturer.captureCursorModernFileSet([main], locator: locator,
                absentRelativePaths: absent, machineID: identity, cas: cas, catalog: catalog))
        }
        XCTAssertEqual(try catalog.unboundCaptures(limit: 10).count, 0)
        XCTAssertEqual(try manifestFileCount(archive), 0)
        let exact = try ExactSourceCapturer.captureCursorModernFileSet([main], locator: locator,
            absentRelativePaths: absent, machineID: machineID, cas: cas, catalog: catalog, maximumByteCount: 4)
        XCTAssertEqual(exact.manifest.rawByteCount, 4)
    }

    private func cursorMember(_ path: String, _ bytes: Data, mtime: Int64 = 7) throws -> ArchiveCapturedFile {
        ArchiveCapturedFile(relativePath: path, generation: try ArchiveSourceGeneration(device: 101, inode: 202,
            size: Int64(bytes.count), mtimeNs: mtime, ctimeNs: 8, mode: 0o100600), bytes: bytes)
    }

    private func sqliteImageFixture(payloadBytes: Int = 0) throws -> Data {
        let file = root.appendingPathComponent("scoped-\(UUID().uuidString).sqlite")
        do {
            let database = try DatabaseQueue(path: file.path)
            try database.write { db in
                try db.execute(sql: "CREATE TABLE session(id TEXT, directory TEXT); INSERT INTO session VALUES ('ses-one','/offline/project')")
                if payloadBytes > 0 {
                    try db.execute(sql: "CREATE TABLE payload(value BLOB); INSERT INTO payload VALUES (zeroblob(?))",
                        arguments: [payloadBytes])
                }
            }
        }
        return try Data(contentsOf: file)
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-exact-capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let physical = realpath(root.path, nil) else { throw POSIXError(.EIO) }
        defer { free(physical) }
        root = URL(fileURLWithPath: String(cString: physical))
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

    func testDeclaredFileSetRoundTripsBytesAndTracksAuxiliaryOnlyGenerations() throws {
        let sources = root.appendingPathComponent("file-set-source")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let primary = sources.appendingPathComponent("events.jsonl")
        let auxiliary = sources.appendingPathComponent("workspace.yaml")
        let absent = sources.appendingPathComponent("missing.md")
        let primaryBytes = Data("{\"type\":\"user.message\"}\n".utf8)
        try primaryBytes.write(to: primary)
        try Data("cwd: /first\n".utf8).write(to: auxiliary)
        let original = try sourceObservation(primary)
        let (cas, catalog) = try makeStore(root.appendingPathComponent("file-set-store"))
        let descriptor = try ArchiveSourceDescriptor.fileSet(locator: primary.path, root: sources,
            files: [auxiliary, primary], absentFiles: [absent])
        XCTAssertEqual(descriptor.fileSetRoot?.path, sources.path, "physical roots must not be rewritten into symlink aliases")
        XCTAssertEqual(descriptor.files.map(\.sourceURL.path), [primary.path, auxiliary.path])
        let capturer = ExactSourceCapturer(cas: cas, catalog: catalog, descriptor: descriptor)
        let first = try capturer.capture(source: .copilot, locator: primary.path, machineID: machineID)
        XCTAssertEqual(first.manifest.schemaVersion, 2)
        XCTAssertEqual(first.manifest.generation.size, Int64(primaryBytes.count))
        XCTAssertEqual(try reconstruct(first.manifest, from: cas), primaryBytes + Data("cwd: /first\n".utf8))
        XCTAssertEqual(first.manifest.replayLayout.relativePaths, ["events.jsonl", "workspace.yaml"])
        let repeated = try capturer.capture(source: .copilot, locator: primary.path, machineID: machineID)
        XCTAssertEqual(repeated, first, "unchanged file sets reuse the original immutable manifest")
        try Data("cwd: /second\n".utf8).write(to: auxiliary)
        let second = try capturer.capture(source: .copilot, locator: primary.path, machineID: machineID)
        XCTAssertNotEqual(second.capture.captureID, first.capture.captureID)
        XCTAssertEqual(second.manifest.generation, first.manifest.generation)
        XCTAssertEqual(try sourceObservation(primary), original)
        XCTAssertEqual(try reconstruct(second.manifest, from: cas), primaryBytes + Data("cwd: /second\n".utf8))
        XCTAssertEqual(try catalog.unboundCaptures(limit: 10).count, 2)
    }

    func testDeclaredFileSetFillsGlobalChunksAcrossFileBoundaries() throws {
        let sources = root.appendingPathComponent("chunked-file-set")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let primary = sources.appendingPathComponent("a.jsonl")
        let auxiliary = sources.appendingPathComponent("b.yaml")
        let firstBytes = Data(repeating: 0x41, count: Int(ArchiveSourceManifest.rawChunkSize) - 3)
        let secondBytes = Data([0, 0xFF, 0xEF, 0xBB, 0xBF, 10, 13])
        try firstBytes.write(to: primary)
        try secondBytes.write(to: auxiliary)
        let (cas, catalog) = try makeStore(root.appendingPathComponent("chunked-file-set-store"))
        let descriptor = try ArchiveSourceDescriptor.fileSet(locator: primary.path, root: sources, files: [primary, auxiliary])
        let capturer = ExactSourceCapturer(cas: cas, catalog: catalog, descriptor: descriptor,
            testHooks: .init(maximumReadSize: 31))
        let result = try capturer.capture(source: .copilot, locator: primary.path, machineID: machineID)
        XCTAssertEqual(result.manifest.chunks.map(\.rawByteCount), [ArchiveSourceManifest.rawChunkSize, 4])
        XCTAssertEqual(try reconstruct(result.manifest, from: cas), firstBytes + secondBytes)
        XCTAssertEqual(result.manifest.wholeSourceSHA256, ArchiveV2Hash.sha256(firstBytes + secondBytes))
    }

    func testDeclaredFileSetEmptyAndAbsentDependenciesHaveDistinctIdentities() throws {
        let sources = root.appendingPathComponent("optional-file-set")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let primary = sources.appendingPathComponent("a.jsonl")
        let auxiliary = sources.appendingPathComponent("b.yaml")
        let optional = sources.appendingPathComponent("c.md")
        try Data("primary".utf8).write(to: primary)
        try Data("auxiliary".utf8).write(to: auxiliary)
        let (cas, catalog) = try makeStore(root.appendingPathComponent("optional-file-set-store"))
        let missing = try ArchiveSourceDescriptor.fileSet(locator: primary.path, root: sources,
            files: [primary, auxiliary], absentFiles: [optional])
        let first = try ExactSourceCapturer(cas: cas, catalog: catalog, descriptor: missing)
            .capture(source: .copilot, locator: primary.path, machineID: machineID)
        try Data().write(to: optional)
        let present = try ArchiveSourceDescriptor.fileSet(locator: primary.path, root: sources,
            files: [primary, auxiliary, optional])
        let second = try ExactSourceCapturer(cas: cas, catalog: catalog, descriptor: present)
            .capture(source: .copilot, locator: primary.path, machineID: machineID)
        XCTAssertEqual(first.manifest.wholeSourceSHA256, second.manifest.wholeSourceSHA256)
        XCTAssertNotEqual(first.capture.captureID, second.capture.captureID)
        XCTAssertNotEqual(first.capture.unboundManifestSHA256, second.capture.unboundManifestSHA256)
    }

    func testFileSetBudgetCountsAllFilesBeforeStreamingOrPublishing() throws {
        let fixture = try makeFileSetFixture("budget")
        let bytes = Data(repeating: 0x41, count: 128)
        try bytes.write(to: fixture.auxiliary)
        let capturer = ExactSourceCapturer(cas: fixture.cas, catalog: fixture.catalog,
            descriptor: fixture.descriptor, testHooks: .init(afterStreamingBeforeFinalStat: { _ in
                XCTFail("sum admission must run before any member is streamed")
            }))
        XCTAssertThrowsError(try capturer.capture(source: .copilot, locator: fixture.primary.path,
            machineID: machineID, maximumByteCount: 16)) {
            XCTAssertEqual($0 as? ExactSourceCapturerError, .exceededMaximumByteCount(16))
        }
        XCTAssertTrue(try fixture.catalog.unboundCaptures(limit: 10).isEmpty)
        try assertNoCASContent(in: fixture.store)
        XCTAssertEqual(try Data(contentsOf: fixture.auxiliary), bytes)
    }

    func testFileSetRevalidatesEarlierAndLaterMembersAcrossTheWholeRead() throws {
        for mutateEarlier in [false, true] {
            let fixture = try makeFileSetFixture(mutateEarlier ? "earlier-race" : "later-race")
            let hook = FileSetHookCounter()
            let trigger = mutateEarlier ? fixture.auxiliary : fixture.primary
            let victim = mutateEarlier ? fixture.primary : fixture.auxiliary
            let capturer = ExactSourceCapturer(cas: fixture.cas, catalog: fixture.catalog,
                descriptor: fixture.descriptor, testHooks: .init(afterStreamingBeforeFinalStat: { url in
                    if url == trigger {
                        hook.mark()
                        try Data("changed-member\n".utf8).write(to: victim)
                    }
                }))
            XCTAssertThrowsError(try capturer.capture(source: .copilot, locator: fixture.primary.path,
                machineID: machineID)) {
                XCTAssertEqual($0 as? ExactSourceCapturerError, .generationChanged)
            }
            XCTAssertEqual(hook.count, 1, "the test must reach the intended mutation seam")
            XCTAssertTrue(try fixture.catalog.unboundCaptures(limit: 10).isEmpty)
            try assertNoCASContent(in: fixture.store)
        }
    }

    func testFileSetAbsentDependencyCreatedDuringReadRejectsTheGeneration() throws {
        let fixture = try makeFileSetFixture("absence-race")
        let hook = FileSetHookCounter()
        let capturer = ExactSourceCapturer(cas: fixture.cas, catalog: fixture.catalog,
            descriptor: fixture.descriptor, testHooks: .init(afterStreamingBeforeFinalStat: { url in
                if url == fixture.auxiliary {
                    hook.mark()
                    try Data().write(to: fixture.absent)
                }
            }))
        XCTAssertThrowsError(try capturer.capture(source: .copilot, locator: fixture.primary.path,
            machineID: machineID)) {
            XCTAssertEqual($0 as? ExactSourceCapturerError, .generationChanged)
        }
        XCTAssertEqual(hook.count, 1)
        XCTAssertTrue(try fixture.catalog.unboundCaptures(limit: 10).isEmpty)
        try assertNoCASContent(in: fixture.store)
    }

    func testFileSetRejectsSymlinkedCompanionAndIntermediateDirectoryWithoutReadingTargets() throws {
        for intermediate in [false, true] {
            let fixture = try makeFileSetFixture(intermediate ? "parent-link" : "leaf-link")
            let outside = root.appendingPathComponent("outside-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let target = outside.appendingPathComponent("private.yaml")
            let bytes = Data("must remain untouched".utf8)
            try bytes.write(to: target)
            let linked: URL
            if intermediate {
                let parent = fixture.sources.appendingPathComponent("linked")
                try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside)
                linked = parent.appendingPathComponent("private.yaml")
            } else {
                linked = fixture.sources.appendingPathComponent("linked.yaml")
                try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: target)
            }
            let descriptor = try ArchiveSourceDescriptor.fileSet(locator: fixture.primary.path,
                root: fixture.sources, files: [fixture.primary, linked])
            let capturer = ExactSourceCapturer(cas: fixture.cas, catalog: fixture.catalog,
                descriptor: descriptor, testHooks: .init(afterStreamingBeforeFinalStat: { _ in
                    XCTFail("all source descriptors must be admitted before reading any content")
                }))
            XCTAssertThrowsError(try capturer.capture(source: .copilot, locator: fixture.primary.path, machineID: machineID))
            XCTAssertTrue(try fixture.catalog.unboundCaptures(limit: 10).isEmpty)
            try assertNoCASContent(in: fixture.store)
            XCTAssertEqual(try Data(contentsOf: target), bytes)
        }
    }

    func testFileSetFIFOCompanionCannotBlockCapture() throws {
        let fixture = try makeFileSetFixture("fifo")
        let fifo = fixture.sources.appendingPathComponent("fifo.yaml")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let descriptor = try ArchiveSourceDescriptor.fileSet(locator: fixture.primary.path, root: fixture.sources,
            files: [fixture.primary, fifo])
        let capturer = ExactSourceCapturer(cas: fixture.cas, catalog: fixture.catalog, descriptor: descriptor)
        _ = try runFIFOOperationPromptly(fifo: fifo) {
            _ = try capturer.capture(source: .copilot, locator: fixture.primary.path, machineID: self.machineID)
        }
        XCTAssertTrue(try fixture.catalog.unboundCaptures(limit: 10).isEmpty)
        try assertNoCASContent(in: fixture.store)
    }

    func testFileSetMissingNestedMembersAndAbsentPathsDoNotLeakDirectoryDescriptors() throws {
        for declaredAbsent in [false, true] {
            let fixture = try makeFileSetFixture(declaredAbsent ? "missing-absent-fds" : "missing-present-fds")
            let parent = fixture.sources.appendingPathComponent("outer")
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let missing = parent.appendingPathComponent("missing/child.yaml")
            let descriptor = try ArchiveSourceDescriptor.fileSet(locator: fixture.primary.path, root: fixture.sources,
                files: declaredAbsent ? [fixture.primary, fixture.auxiliary] : [fixture.primary, missing],
                absentFiles: declaredAbsent ? [missing] : [])
            let before = try directoryDescriptors(for: parent)
            defer {
                // A failing RED must clean only leaked descriptors for this
                // test-owned unique directory before handing back to XCTest.
                if let after = try? directoryDescriptors(for: parent) {
                    for fd in after.subtracting(before) { _ = Darwin.close(fd) }
                }
            }
            let capturer = ExactSourceCapturer(cas: fixture.cas, catalog: fixture.catalog, descriptor: descriptor)
            for _ in 0..<3 {
                if declaredAbsent {
                    XCTAssertNoThrow(try capturer.capture(source: .copilot, locator: fixture.primary.path, machineID: machineID))
                } else {
                    XCTAssertThrowsError(try capturer.capture(source: .copilot, locator: fixture.primary.path, machineID: machineID))
                }
            }
            XCTAssertEqual(try directoryDescriptors(for: parent), before,
                "failed directory descent and declared absence must release every opened parent")
        }
    }

    func testFileSetRevalidationClosesParentsWhenNestedDirectoryDisappears() throws {
        let fixture = try makeFileSetFixture("revalidation-fds")
        let parent = fixture.sources.appendingPathComponent("outer")
        let nested = parent.appendingPathComponent("inner")
        let moved = fixture.sources.appendingPathComponent("held-inner")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let companion = nested.appendingPathComponent("body.md")
        try Data("checkpoint".utf8).write(to: companion)
        let descriptor = try ArchiveSourceDescriptor.fileSet(locator: fixture.primary.path, root: fixture.sources,
            files: [fixture.primary, companion])
        let before = try directoryDescriptors(for: parent)
        defer {
            if let after = try? directoryDescriptors(for: parent) {
                for fd in after.subtracting(before) { _ = Darwin.close(fd) }
            }
        }
        let hook = FileSetHookCounter()
        let capturer = ExactSourceCapturer(cas: fixture.cas, catalog: fixture.catalog,
            descriptor: descriptor, testHooks: .init(afterStreamingBeforeFinalStat: { url in
                if url == companion {
                    hook.mark()
                    try FileManager.default.moveItem(at: nested, to: moved)
                }
            }))
        for _ in 0..<3 {
            XCTAssertThrowsError(try capturer.capture(source: .copilot, locator: fixture.primary.path,
                machineID: machineID)) {
                XCTAssertEqual($0 as? ExactSourceCapturerError, .generationChanged)
            }
            try FileManager.default.moveItem(at: moved, to: nested)
        }
        XCTAssertEqual(hook.count, 3)
        XCTAssertEqual(try directoryDescriptors(for: parent), before)
        XCTAssertTrue(try fixture.catalog.unboundCaptures(limit: 10).isEmpty)
        try assertNoCASContent(in: fixture.store)
    }

    func testFileSetPhysicalPathsStillRejectSymlinkedRootsAndLexicalEscapes() throws {
        let fixture = try makeFileSetFixture("root-link")
        let linkedRoot = root.appendingPathComponent("root-alias")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: fixture.sources)
        let linkedPrimary = linkedRoot.appendingPathComponent(fixture.primary.lastPathComponent)
        let descriptor = try ArchiveSourceDescriptor.fileSet(locator: linkedPrimary.path, root: linkedRoot,
            files: [linkedPrimary])
        let capturer = ExactSourceCapturer(cas: fixture.cas, catalog: fixture.catalog,
            descriptor: descriptor, testHooks: .init(afterStreamingBeforeFinalStat: { _ in
                XCTFail("symbolic root must be rejected before streaming")
            }))
        XCTAssertThrowsError(try capturer.capture(source: .copilot, locator: linkedPrimary.path, machineID: machineID))
        let escape = URL(fileURLWithPath: fixture.sources.path + "/../outside")
        XCTAssertThrowsError(try ArchiveSourceDescriptor.fileSet(locator: fixture.primary.path,
            root: fixture.sources, files: [fixture.primary, escape]))
        XCTAssertThrowsError(try ArchiveSourceDescriptor.fileSet(locator: fixture.primary.path,
            root: URL(fileURLWithPath: "/./"), files: [fixture.primary]))
        XCTAssertTrue(try fixture.catalog.unboundCaptures(limit: 10).isEmpty)
        try assertNoCASContent(in: fixture.store)
    }

    func testVSCodeFrozenExternalConfigurationSurvivesDeletionAndChangesCaptureIdentity() throws {
        let sources = root.appendingPathComponent("vscode-storage")
        let primary = sources.appendingPathComponent("ws/chatSessions/session.jsonl")
        let workspace = sources.appendingPathComponent("ws/workspace.json")
        let external = root.appendingPathComponent("project.code-workspace")
        try FileManager.default.createDirectory(at: primary.deletingLastPathComponent(), withIntermediateDirectories: true)
        let primaryBytes = Data("{\"kind\":0,\"v\":{}}\n".utf8)
        try primaryBytes.write(to: primary)
        let workspaceBytes = try JSONSerialization.data(withJSONObject: ["configuration": external.absoluteString])
        try workspaceBytes.write(to: workspace)
        let bytes = Data(#"{"folders":[{"path":"../project"}]}"#.utf8)
        try bytes.write(to: external)
        var info = stat()
        guard lstat(external.path, &info) == 0 else { throw POSIXError(.EIO) }
        let observation = try ArchiveSourceGeneration(device: Int64(info.st_dev), inode: Int64(info.st_ino),
            size: info.st_size, mtimeNs: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
            ctimeNs: Int64(info.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(info.st_ctimespec.tv_nsec), mode: Int64(info.st_mode))
        let context = try ArchiveVSCodeWorkspaceContext(configurationLocator: external.path,
            configurationGeneration: observation, configurationData: bytes, configurationSHA256: ArchiveV2Hash.sha256(bytes))
        try FileManager.default.removeItem(at: external)
        let (cas, catalog) = try makeStore(root.appendingPathComponent("vscode-store"))
        func capture(_ context: ArchiveVSCodeWorkspaceContext, maximumBytes: Int64? = nil) throws -> ArchiveCaptureResult {
            let descriptor = try ArchiveSourceDescriptor.fileSet(locator: primary.path, root: sources,
                files: [primary, workspace], vscodeWorkspaceContext: context)
            return try ExactSourceCapturer(cas: cas, catalog: catalog, descriptor: descriptor)
                .capture(source: .vscode, locator: primary.path, machineID: machineID, maximumByteCount: maximumBytes)
        }
        let first = try capture(context)
        XCTAssertEqual(first.manifest.schemaVersion, 7)
        XCTAssertEqual(first.manifest.replayLayout.vscodeWorkspaceContext?.configurationData, bytes)
        XCTAssertEqual(try reconstruct(first.manifest, from: cas), primaryBytes + workspaceBytes)
        let absent = try ArchiveVSCodeWorkspaceContext(configurationLocator: external.path)
        let second = try capture(absent)
        XCTAssertNotEqual(first.capture.captureID, second.capture.captureID)
        XCTAssertEqual(first.manifest.chunks, second.manifest.chunks)
        XCTAssertEqual(try capture(context), first)
        XCTAssertThrowsError(try capture(context, maximumBytes: Int64(primaryBytes.count + workspaceBytes.count)))
        let mismatched = try ArchiveVSCodeWorkspaceContext(configurationLocator: "/other/project.code-workspace")
        XCTAssertThrowsError(try capture(mismatched))
        try FileManager.default.removeItem(at: sources)
        let persisted = try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self,
            from: cas.readManifest(sha256: first.capture.unboundManifestSHA256))
        XCTAssertEqual(persisted.replayLayout.vscodeWorkspaceContext, context)
    }

    func testDeclaredGeminiRegistryProjectionChangesIdentityWithoutAddingRegistryBytes() throws {
        let sources = root.appendingPathComponent("gemini-tmp")
        let chats = sources.appendingPathComponent("project/chats")
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let primary = chats.appendingPathComponent("stem.json")
        let sourceBytes = Data("{\"sessionId\":\"native\"}".utf8)
        try sourceBytes.write(to: primary)
        let (cas, catalog) = try makeStore(root.appendingPathComponent("gemini-store"))
        let registryGeneration = try ArchiveSourceGeneration(device: 1, inode: 9, size: 80,
            mtimeNs: 10, ctimeNs: 11, mode: 0o100600)
        func capture(cwd: String, registryHash: String) throws -> ArchiveCaptureResult {
            let context = try ArchiveGeminiProjectContext(projectName: "project", cwd: cwd,
                registryLocator: root.appendingPathComponent("projects.json").path,
                registryGeneration: registryGeneration, registrySHA256: registryHash)
            let descriptor = try ArchiveSourceDescriptor.fileSet(locator: primary.path, root: sources, files: [primary],
                absentFiles: [sources.appendingPathComponent("project/.project_root"), chats.appendingPathComponent("native.engram.json")],
                geminiProjectContext: context)
            return try ExactSourceCapturer(cas: cas, catalog: catalog, descriptor: descriptor)
                .capture(source: .geminiCli, locator: primary.path, machineID: machineID)
        }
        // This primitive transports caller-validated projection metadata. The
        // Collector tests separately fence actual registry reads and recovery.
        let first = try capture(cwd: "/repo/first", registryHash: ArchiveV2Hash.sha256(Data("registry one".utf8)))
        let second = try capture(cwd: "/repo/second", registryHash: ArchiveV2Hash.sha256(Data("registry two".utf8)))
        XCTAssertEqual(first.manifest.schemaVersion, 3)
        XCTAssertEqual(second.manifest.schemaVersion, 3)
        XCTAssertEqual(first.manifest.replayLayout.geminiProjectContext?.cwd, "/repo/first")
        XCTAssertEqual(second.manifest.replayLayout.geminiProjectContext?.cwd, "/repo/second")
        XCTAssertNotEqual(first.capture.captureID, second.capture.captureID)
        XCTAssertEqual(first.manifest.generation, second.manifest.generation)
        XCTAssertEqual(first.manifest.chunks, second.manifest.chunks)
        XCTAssertEqual(first.manifest.wholeSourceSHA256, second.manifest.wholeSourceSHA256)
        XCTAssertEqual(first.manifest.rawByteCount, Int64(sourceBytes.count))
        XCTAssertEqual(try reconstruct(first.manifest, from: cas), sourceBytes)
        let repeated = try capture(cwd: "/repo/second", registryHash: ArchiveV2Hash.sha256(Data("registry two".utf8)))
        XCTAssertEqual(repeated.capture, second.capture)
        XCTAssertEqual(try catalog.unboundCaptures(limit: 10).count, 2)
    }

    func testFileSetAllEmptyMembersHaveNoChunksAndRemainIdempotent() throws {
        let fixture = try makeFileSetFixture("all-empty")
        try Data().write(to: fixture.primary)
        try Data().write(to: fixture.auxiliary)
        let capturer = ExactSourceCapturer(cas: fixture.cas, catalog: fixture.catalog, descriptor: fixture.descriptor)
        let captured = try capturer.capture(source: .copilot, locator: fixture.primary.path,
            machineID: machineID, maximumByteCount: 0)
        XCTAssertEqual(captured.manifest.rawByteCount, 0)
        XCTAssertEqual(captured.manifest.wholeSourceSHA256, ArchiveV2Hash.sha256(Data()))
        XCTAssertTrue(captured.manifest.chunks.isEmpty)
        XCTAssertEqual(captured.manifest.replayLayout.files?.count, 2)
        XCTAssertEqual(captured, try capturer.capture(source: .copilot, locator: fixture.primary.path,
            machineID: machineID, maximumByteCount: 0))
    }

    func testFileSetCancellationAndLateMutationDiscardAlreadyStagedChunks() async throws {
        for cancel in [false, true] {
            let fixture = try makeFileSetFixture(cancel ? "staged-cancel" : "staged-mutation")
            try Data(repeating: 0x41, count: Int(ArchiveSourceManifest.rawChunkSize) + 1).write(to: fixture.primary)
            let hook = FileSetHookCounter()
            let capturer = ExactSourceCapturer(cas: fixture.cas, catalog: fixture.catalog,
                descriptor: fixture.descriptor, testHooks: .init(afterStreamingBeforeFinalStat: { url in
                    if url == fixture.auxiliary {
                        hook.mark()
                        XCTAssertGreaterThan(try self.regularFileCount(in: fixture.store.appendingPathComponent("tmp")), 0,
                            "the failure must occur after a full chunk is staged")
                        if cancel {
                            withUnsafeCurrentTask { $0?.cancel() }
                        } else {
                            try Data("mutated".utf8).write(to: fixture.primary)
                        }
                    }
                }))
            let result = await Task {
                try capturer.capture(source: .copilot, locator: fixture.primary.path, machineID: machineID)
            }.result
            guard case .failure(let error) = result else { return XCTFail("capture must fail") }
            if cancel { XCTAssertTrue(error is CancellationError) }
            else { XCTAssertEqual(error as? ExactSourceCapturerError, .generationChanged) }
            XCTAssertEqual(hook.count, 1)
            XCTAssertTrue(try fixture.catalog.unboundCaptures(limit: 10).isEmpty)
            try assertNoCASContent(in: fixture.store)
        }
    }

    private func directoryDescriptors(for directory: URL) throws -> Set<Int32> {
        var target = stat()
        guard lstat(directory.path, &target) == 0 else { throw POSIXError(.EIO) }
        var descriptors: Set<Int32> = []
        for fd in Int32(0)..<getdtablesize() {
            var info = stat()
            if fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
               info.st_dev == target.st_dev, info.st_ino == target.st_ino {
                descriptors.insert(fd)
            }
        }
        return descriptors
    }

    private struct FileSetFixture: Sendable {
        let sources: URL
        let primary: URL
        let auxiliary: URL
        let absent: URL
        let store: URL
        let cas: ImmutableArchiveCAS
        let catalog: ArchiveCatalog
        let descriptor: ArchiveSourceDescriptor
    }

    private func makeFileSetFixture(_ name: String) throws -> FileSetFixture {
        let sources = root.appendingPathComponent("file-set-\(name)")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let primary = sources.appendingPathComponent("a.jsonl")
        let auxiliary = sources.appendingPathComponent("b.yaml")
        let absent = sources.appendingPathComponent("c.md")
        try Data("primary\n".utf8).write(to: primary)
        try Data("auxiliary\n".utf8).write(to: auxiliary)
        let store = root.appendingPathComponent("file-set-store-\(name)")
        let (cas, catalog) = try makeStore(store)
        let descriptor = try ArchiveSourceDescriptor.fileSet(locator: primary.path, root: sources,
            files: [primary, auxiliary], absentFiles: [absent])
        return FileSetFixture(sources: sources, primary: primary, auxiliary: auxiliary, absent: absent,
            store: store, cas: cas, catalog: catalog, descriptor: descriptor)
    }

    private final class FileSetHookCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func mark() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
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
