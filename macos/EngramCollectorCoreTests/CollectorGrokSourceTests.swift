import Darwin
import Foundation
import XCTest
@testable import EngramCollectorCore

final class CollectorGrokSourceTests: XCTestCase {
    private let machineID = "11111111-2222-3333-4444-555555555555"

    func testSelectedPrimaryIsSinglePreferredRegularFile_repro() throws {
        let f = try GrokFixture(); defer { f.remove() }
        try f.writeAllMembers()
        XCTAssertTrue(CollectorGrokSource.isSelectedPrimary(rootPath: f.root.path, components: f.chatComponents))
        XCTAssertFalse(CollectorGrokSource.isSelectedPrimary(rootPath: f.root.path, components: f.updatesComponents))
        XCTAssertFalse(CollectorGrokSource.isSelectedPrimary(rootPath: f.root.path, components: f.summaryComponents))
        XCTAssertFalse(CollectorGrokSource.isSelectedPrimary(rootPath: "", components: f.chatComponents))
        XCTAssertEqual(CollectorGrokSource.owningPrimary(rootPath: f.root.path, dirtyRelative: f.updates), f.chat)
        XCTAssertEqual(CollectorGrokSource.owningPrimary(rootPath: f.root.path, dirtyRelative: f.prompt), f.chat)
        try FileManager.default.removeItem(at: f.chatURL)
        XCTAssertFalse(CollectorGrokSource.isSelectedPrimary(rootPath: f.root.path, components: f.chatComponents))
        XCTAssertTrue(CollectorGrokSource.isSelectedPrimary(rootPath: f.root.path, components: f.updatesComponents))
        XCTAssertEqual(CollectorGrokSource.owningPrimary(rootPath: f.root.path, dirtyRelative: f.summary), f.updates)
        try FileManager.default.removeItem(at: f.updatesURL)
        XCTAssertTrue(CollectorGrokSource.isSelectedPrimary(rootPath: f.root.path, components: f.summaryComponents))
    }

    func testObserveDeclaresExplicitAbsentMembersAndCapturesExactBytes_repro() throws {
        let f = try GrokFixture(); defer { f.remove() }
        let payloads = try f.writePresent(["chat_history.jsonl", "summary.json", "prompt_context.json"])
        let observed = try CollectorGrokSource.observe(rootPath: f.root.path, primaryRelative: f.chat)
        XCTAssertEqual(observed.snapshot.entrypointRelativePath, f.chat)
        XCTAssertEqual(observed.snapshot.present.map(\.relativePath), [f.chat, f.prompt, f.summary].sorted())
        XCTAssertEqual(observed.snapshot.absentRelativePaths, [f.index, f.updates])
        XCTAssertEqual(observed.generation, observed.snapshot.present.first { $0.relativePath == f.chat }?.generation)
        XCTAssertNoThrow(try CollectorGrokSource.requireValidSnapshot(observed.snapshot, entrypoint: f.chat))

        let descriptor = try f.fileSet(snapshot: observed.snapshot)
        let store = f.base.appendingPathComponent("cas")
        let cas = try ImmutableArchiveCAS(root: store)
        let catalog = try ArchiveCatalog(root: store, machineID: machineID)
        try catalog.migrate()
        defer { try? catalog.close() }
        let captured = try ExactSourceCapturer(cas: cas, catalog: catalog, descriptor: descriptor)
            .capture(source: .grok, locator: f.chatURL.path, machineID: machineID)
        XCTAssertTrue(ArchiveSourceDescriptor.isGrokFileSet(captured.manifest))
        XCTAssertEqual(captured.manifest.replayLayout.absentRelativePaths, [f.index, f.updates])
        XCTAssertEqual(captured.manifest.replayLayout.entrypointRelativePath, f.chat)
        let expected = [f.chat, f.prompt, f.summary].sorted().reduce(into: Data()) { $0.append(payloads[$1]!) }
        XCTAssertEqual(try reconstruct(captured.manifest, from: cas), expected)
        XCTAssertEqual(captured.manifest.generation.size, Int64(payloads[f.chat]!.count))
    }

    func testChatHistorySymlinkIsRejectedWithoutFallback_repro() throws {
        let f = try GrokFixture(); defer { f.remove() }
        try f.writeAllMembers()
        let outside = f.base.appendingPathComponent("outside-chat.jsonl")
        try Data("stolen".utf8).write(to: outside)
        try FileManager.default.removeItem(at: f.chatURL)
        try FileManager.default.createSymbolicLink(at: f.chatURL, withDestinationURL: outside)
        XCTAssertFalse(CollectorGrokSource.isSelectedPrimary(rootPath: f.root.path, components: f.chatComponents))
        XCTAssertFalse(CollectorGrokSource.isSelectedPrimary(rootPath: f.root.path, components: f.updatesComponents))
        XCTAssertNil(CollectorGrokSource.owningPrimary(rootPath: f.root.path, dirtyRelative: f.updates))
        XCTAssertThrowsError(try CollectorGrokSource.observe(rootPath: f.root.path, primaryRelative: f.updates))
    }

    func testMemberSymlinkIsNotRecordedAsAbsence_repro() throws {
        let f = try GrokFixture(); defer { f.remove() }
        try f.writePresent(["chat_history.jsonl", "summary.json"])
        let outside = f.base.appendingPathComponent("outside-prompt.json")
        try Data("{}".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: f.promptURL, withDestinationURL: outside)
        XCTAssertThrowsError(try CollectorGrokSource.observe(rootPath: f.root.path, primaryRelative: f.chat))
        XCTAssertTrue(CollectorGrokSource.isSelectedPrimary(rootPath: f.root.path, components: f.chatComponents))
    }

    func testAuxiliaryUpdatesLargerThan100MiBStayInTheClosedSet_repro() throws {
        let f = try GrokFixture(); defer { f.remove() }
        try f.writePresent(["chat_history.jsonl", "summary.json", "prompt_context.json"])
        let large = Int64(100 * 1024 * 1024) + 24
        XCTAssertTrue(FileManager.default.createFile(atPath: f.updatesURL.path, contents: nil, attributes: [.posixPermissions: 0o600]))
        XCTAssertEqual(truncate(f.updatesURL.path, large), 0)
        let observed = try CollectorGrokSource.observe(rootPath: f.root.path, primaryRelative: f.chat)
        let updates = try XCTUnwrap(observed.snapshot.present.first { $0.relativePath == f.updates })
        XCTAssertGreaterThan(updates.generation.size, 100 * 1024 * 1024)
        XCTAssertEqual(observed.snapshot.entrypointRelativePath, f.chat)
        XCTAssertEqual(observed.snapshot.absentRelativePaths, [f.index])
        let descriptor = try f.fileSet(snapshot: observed.snapshot)
        XCTAssertEqual(descriptor.files.count, 4)
        XCTAssertEqual(descriptor.absentFiles.count, 1)
        XCTAssertNoThrow(try CollectorGrokSource.requireValidSnapshot(observed.snapshot, entrypoint: f.chat))
    }

    func testGrokFileSetRequiresPreferredPrimaryAmongPresentMembers_repro() throws {
        let f = try GrokFixture(); defer { f.remove() }
        try f.writeAllMembers()
        let observed = try CollectorGrokSource.observe(rootPath: f.root.path, primaryRelative: f.updates)
        XCTAssertEqual(observed.snapshot.entrypointRelativePath, f.chat)
        let valid = try f.fileSet(snapshot: observed.snapshot)
        let store = f.base.appendingPathComponent("shape-cas")
        let cas = try ImmutableArchiveCAS(root: store)
        let catalog = try ArchiveCatalog(root: store, machineID: machineID)
        try catalog.migrate()
        defer { try? catalog.close() }
        let captured = try ExactSourceCapturer(cas: cas, catalog: catalog, descriptor: valid)
            .capture(source: .grok, locator: f.chatURL.path, machineID: machineID)
        XCTAssertTrue(ArchiveSourceDescriptor.isGrokFileSet(captured.manifest))

        let wrongPrimary = try ArchiveSourceDescriptor.fileSet(
            locator: f.updatesURL.path, root: f.root,
            files: [f.chatURL, f.updatesURL, f.summaryURL, f.promptURL]
        )
        let wrong = try ExactSourceCapturer(cas: cas, catalog: catalog, descriptor: wrongPrimary)
            .capture(source: .grok, locator: f.updatesURL.path, machineID: machineID)
        XCTAssertFalse(ArchiveSourceDescriptor.isGrokFileSet(wrong.manifest))
    }

    func testObserveRetainsCompactionIndexAndSortedSegmentsExactCASBytesAfterOriginalsRemoved_repro() throws {
        let f = try GrokFixture(); defer { f.remove() }
        var payloads = try f.writePresent(["chat_history.jsonl", "updates.jsonl", "summary.json", "prompt_context.json"])
        let extra = try f.writeCompaction(
            index: Data("# index\n".utf8),
            segments: [
                ("segment_001.md", Data("# later\n".utf8)),
                ("segment_000.md", Data("# earlier\n".utf8)),
            ]
        )
        payloads.merge(extra) { _, new in new }
        try f.writeSiblingCheckpoints()

        XCTAssertEqual(CollectorGrokSource.owningPrimary(rootPath: f.root.path, dirtyRelative: f.index), f.chat)
        XCTAssertEqual(CollectorGrokSource.owningPrimary(rootPath: f.root.path, dirtyRelative: f.segment("segment_000.md")), f.chat)
        XCTAssertEqual(CollectorGrokSource.owningPrimary(rootPath: f.root.path, dirtyRelative: f.segment("segment_001.md")), f.chat)
        XCTAssertEqual(CollectorGrokSource.sessionOwning(f.segment("segment_000.md")), f.project + "/" + f.session)
        XCTAssertNil(CollectorGrokSource.owningPrimary(
            rootPath: f.root.path, dirtyRelative: f.prefix + "compaction/../chat_history.jsonl"
        ))

        let observed = try CollectorGrokSource.observe(rootPath: f.root.path, primaryRelative: f.chat)
        XCTAssertEqual(
            observed.snapshot.present.map(\.relativePath),
            [f.chat, f.index, f.segment("segment_000.md"), f.segment("segment_001.md"), f.prompt, f.summary, f.updates]
        )
        XCTAssertEqual(observed.snapshot.absentRelativePaths, [])
        XCTAssertFalse(observed.snapshot.present.contains { $0.relativePath.contains("compaction_checkpoints") })
        XCTAssertNoThrow(try CollectorGrokSource.requireValidSnapshot(observed.snapshot, entrypoint: f.chat))

        let descriptor = try f.fileSet(snapshot: observed.snapshot)
        let store = f.base.appendingPathComponent("compaction-cas")
        let cas = try ImmutableArchiveCAS(root: store)
        let catalog = try ArchiveCatalog(root: store, machineID: machineID)
        try catalog.migrate()
        defer { try? catalog.close() }
        let captured = try ExactSourceCapturer(cas: cas, catalog: catalog, descriptor: descriptor)
            .capture(source: .grok, locator: f.chatURL.path, machineID: machineID)
        XCTAssertTrue(ArchiveSourceDescriptor.isGrokFileSet(captured.manifest))
        let expected = observed.snapshot.present.map(\.relativePath).reduce(into: Data()) { $0.append(payloads[$1]!) }
        XCTAssertEqual(try reconstruct(captured.manifest, from: cas), expected)

        try FileManager.default.removeItem(at: f.root.appendingPathComponent(f.project + "/" + f.session))
        XCTAssertEqual(try reconstruct(captured.manifest, from: cas), expected)
    }

    func testObserveDeclaresAbsentCompactionWhenDirectoryMissing_repro() throws {
        let f = try GrokFixture(); defer { f.remove() }
        try f.writeAllMembers()
        let observed = try CollectorGrokSource.observe(rootPath: f.root.path, primaryRelative: f.chat)
        XCTAssertEqual(observed.snapshot.present.map(\.relativePath), [f.chat, f.prompt, f.summary, f.updates])
        XCTAssertEqual(observed.snapshot.absentRelativePaths, [f.index])
        XCTAssertEqual(CollectorGrokSource.owningPrimary(rootPath: f.root.path, dirtyRelative: f.index), f.chat)
        XCTAssertNoThrow(try CollectorGrokSource.requireValidSnapshot(observed.snapshot, entrypoint: f.chat))
        let descriptor = try f.fileSet(snapshot: observed.snapshot)
        XCTAssertEqual(descriptor.files.count, 4)
        XCTAssertEqual(descriptor.absentFiles.map(\.replayRelativePath), [f.index])
        let store = f.base.appendingPathComponent("absent-compaction-cas")
        let cas = try ImmutableArchiveCAS(root: store)
        let catalog = try ArchiveCatalog(root: store, machineID: machineID)
        try catalog.migrate()
        defer { try? catalog.close() }
        let captured = try ExactSourceCapturer(cas: cas, catalog: catalog, descriptor: descriptor)
            .capture(source: .grok, locator: f.chatURL.path, machineID: machineID)
        XCTAssertTrue(ArchiveSourceDescriptor.isGrokFileSet(captured.manifest))
    }

    func testObserveDetectsSegmentCreationChangeAndRemoval_repro() throws {
        let f = try GrokFixture(); defer { f.remove() }
        try f.writeAllMembers()
        let missing = try CollectorGrokSource.observe(rootPath: f.root.path, primaryRelative: f.chat)
        XCTAssertEqual(missing.snapshot.absentRelativePaths, [f.index])

        _ = try f.writeCompaction(index: Data("# index\n".utf8), segments: [("segment_000.md", Data("# a\n".utf8))])
        let created = try CollectorGrokSource.observe(rootPath: f.root.path, primaryRelative: f.chat)
        XCTAssertFalse(CollectorGrokSource.membershipEquals(missing.snapshot, created.snapshot))
        let createdSegment = try XCTUnwrap(created.snapshot.present.first { $0.relativePath == f.segment("segment_000.md") })

        try Data("# mutated\n".utf8).write(to: f.segmentURL("segment_000.md"))
        XCTAssertEqual(chmod(f.segmentURL("segment_000.md").path, 0o600), 0)
        let changed = try CollectorGrokSource.observe(rootPath: f.root.path, primaryRelative: f.chat)
        let changedSegment = try XCTUnwrap(changed.snapshot.present.first { $0.relativePath == f.segment("segment_000.md") })
        XCTAssertFalse(CollectorGrokSource.membershipEquals(created.snapshot, changed.snapshot))
        XCTAssertNotEqual(createdSegment.generation, changedSegment.generation)

        try FileManager.default.removeItem(at: f.segmentURL("segment_000.md"))
        let removed = try CollectorGrokSource.observe(rootPath: f.root.path, primaryRelative: f.chat)
        XCTAssertFalse(CollectorGrokSource.membershipEquals(changed.snapshot, removed.snapshot))
        XCTAssertFalse(removed.snapshot.present.contains { $0.relativePath == f.segment("segment_000.md") })
        XCTAssertEqual(removed.snapshot.present.map(\.relativePath), [f.chat, f.index, f.prompt, f.summary, f.updates])
        XCTAssertEqual(CollectorGrokSource.owningPrimary(rootPath: f.root.path, dirtyRelative: f.segment("segment_000.md")), f.chat)
    }

    func testCompactionDirectorySymlinkIsRejected_repro() throws {
        let f = try GrokFixture(); defer { f.remove() }
        try f.writeAllMembers()
        let outside = f.base.appendingPathComponent("outside-compaction")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("# stolen-index\n".utf8).write(to: outside.appendingPathComponent("INDEX.md"))
        try Data("# stolen-segment\n".utf8).write(to: outside.appendingPathComponent("segment_000.md"))
        try FileManager.default.createSymbolicLink(at: f.compactionDir, withDestinationURL: outside)
        XCTAssertTrue(CollectorGrokSource.isSelectedPrimary(rootPath: f.root.path, components: f.chatComponents))
        XCTAssertThrowsError(try CollectorGrokSource.observe(rootPath: f.root.path, primaryRelative: f.chat))
    }

    func testCompactionMemberSymlinkIsRejected_repro() throws {
        let f = try GrokFixture(); defer { f.remove() }
        try f.writeAllMembers()
        try FileManager.default.createDirectory(at: f.compactionDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let outsideIndex = f.base.appendingPathComponent("outside-index.md")
        try Data("# stolen-index\n".utf8).write(to: outsideIndex)
        try FileManager.default.createSymbolicLink(at: f.indexURL, withDestinationURL: outsideIndex)
        XCTAssertThrowsError(try CollectorGrokSource.observe(rootPath: f.root.path, primaryRelative: f.chat))

        try FileManager.default.removeItem(at: f.indexURL)
        try Data("# index\n".utf8).write(to: f.indexURL)
        XCTAssertEqual(chmod(f.indexURL.path, 0o600), 0)
        let outsideSegment = f.base.appendingPathComponent("outside-segment.md")
        try Data("# stolen-segment\n".utf8).write(to: outsideSegment)
        try FileManager.default.createSymbolicLink(at: f.segmentURL("segment_000.md"), withDestinationURL: outsideSegment)
        XCTAssertThrowsError(try CollectorGrokSource.observe(rootPath: f.root.path, primaryRelative: f.chat))
    }
}

private struct GrokFixture {
    let base: URL
    let root: URL
    let project = "%2FUsers%2Ftest%2Fproject"
    let session = "019dd6e3-91d1-7326-8299-314858773a0e"

    var prefix: String { project + "/" + session + "/" }
    var chat: String { prefix + "chat_history.jsonl" }
    var updates: String { prefix + "updates.jsonl" }
    var summary: String { prefix + "summary.json" }
    var prompt: String { prefix + "prompt_context.json" }
    var index: String { prefix + "compaction/INDEX.md" }
    var compactionDir: URL { root.appendingPathComponent(project + "/" + session + "/compaction") }
    var chatComponents: [String] { [project, session, "chat_history.jsonl"] }
    var updatesComponents: [String] { [project, session, "updates.jsonl"] }
    var summaryComponents: [String] { [project, session, "summary.json"] }
    var chatURL: URL { root.appendingPathComponent(chat) }
    var updatesURL: URL { root.appendingPathComponent(updates) }
    var summaryURL: URL { root.appendingPathComponent(summary) }
    var promptURL: URL { root.appendingPathComponent(prompt) }
    var indexURL: URL { root.appendingPathComponent(index) }

    func segment(_ name: String) -> String { prefix + "compaction/" + name }
    func segmentURL(_ name: String) -> URL { root.appendingPathComponent(segment(name)) }

    init() throws {
        if let expectedHome = ProcessInfo.processInfo.environment["ENGRAM_DEMO_EXPECTED_HOME"] {
            guard FileManager.default.homeDirectoryForCurrentUser.path == expectedHome else {
                throw CollectorPublicationWorkerError.invalidCapture
            }
        }
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        base = checkout.appendingPathComponent(".engram-grok-test-\(UUID().uuidString)")
        root = base.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(project + "/" + session),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func writeAllMembers() throws {
        _ = try writePresent(["chat_history.jsonl", "updates.jsonl", "summary.json", "prompt_context.json"])
    }

    @discardableResult
    func writePresent(_ names: [String]) throws -> [String: Data] {
        var payloads: [String: Data] = [:]
        for name in names {
            let relative = prefix + name
            let bytes: Data
            switch name {
            case "chat_history.jsonl":
                bytes = Data("{\"type\":\"user\",\"content\":\"<user_query>Inspect</user_query>\"}\n".utf8)
            case "updates.jsonl":
                bytes = Data("{\"type\":\"assistant\",\"content\":\"ok\"}\n".utf8)
            case "summary.json":
                bytes = Data("{\"info\":{\"id\":\"019dd6e3-91d1-7326-8299-314858773a0e\",\"cwd\":\"/Users/test/project\"}}\n".utf8)
            default:
                bytes = Data("{\"working_directory\":\"/Users/test/project\"}\n".utf8)
            }
            try bytes.write(to: root.appendingPathComponent(relative))
            XCTAssertEqual(chmod(root.appendingPathComponent(relative).path, 0o600), 0)
            payloads[relative] = bytes
        }
        return payloads
    }

    @discardableResult
    func writeCompaction(index: Data, segments: [(String, Data)]) throws -> [String: Data] {
        try FileManager.default.createDirectory(
            at: compactionDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        var payloads: [String: Data] = [:]
        try index.write(to: indexURL)
        XCTAssertEqual(chmod(indexURL.path, 0o600), 0)
        payloads[self.index] = index
        for (name, bytes) in segments {
            try bytes.write(to: segmentURL(name))
            XCTAssertEqual(chmod(segmentURL(name).path, 0o600), 0)
            payloads[segment(name)] = bytes
        }
        return payloads
    }

    func writeSiblingCheckpoints() throws {
        let dir = root.appendingPathComponent(project + "/" + session + "/compaction_checkpoints")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let bytes = Data("{\"schema_version\":1}\n".utf8)
        try bytes.write(to: dir.appendingPathComponent("ignored.json"))
        XCTAssertEqual(chmod(dir.appendingPathComponent("ignored.json").path, 0o600), 0)
    }

    func fileSet(snapshot: CollectorDependencySnapshot) throws -> ArchiveSourceDescriptor {
        let files = snapshot.present.map { URL(fileURLWithPath: root.path + "/" + $0.relativePath) }
        let absent = snapshot.absentRelativePaths.map { URL(fileURLWithPath: root.path + "/" + $0) }
        return try ArchiveSourceDescriptor.fileSet(
            locator: root.path + "/" + snapshot.entrypointRelativePath,
            root: root, files: files, absentFiles: absent
        )
    }

    func remove() { try? FileManager.default.removeItem(at: base) }
}

private func reconstruct(_ manifest: ArchiveSourceManifest, from cas: ImmutableArchiveCAS) throws -> Data {
    try manifest.chunks.reduce(into: Data()) { bytes, chunk in
        bytes.append(try cas.readObject(sha256: chunk.rawSHA256))
    }
}
