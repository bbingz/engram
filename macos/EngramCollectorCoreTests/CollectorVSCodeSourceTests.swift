import Darwin
import Foundation
import XCTest
@testable import EngramCollectorCore

final class CollectorVSCodeSourceTests: XCTestCase {
    func testCapturedDependencyProbeDetectsWorkspaceExternalAndUnsafeChanges() throws {
        let f = try VSCodeFixture(); defer { f.remove() }
        try f.writePrimary()
        let config = try f.writeConfiguration(["folders": [["path": "/project"]]])
        try f.writeWorkspace(["configuration": config.absoluteString])
        func manifest() throws -> ArchiveSourceManifest {
            try manifestForObserved(CollectorVSCodeSource.observe(rootPath: f.root.path,
                primaryRelative: f.primary, maximumByteCount: 1_048_576), root: f.root.path)
        }
        let original = try manifest()
        XCTAssertFalse(try CollectorVSCodeSource.capturedDependenciesChanged(rootPath: f.root.path, manifest: original))
        try f.writeWorkspace(["folder": "file:///different"])
        XCTAssertTrue(try CollectorVSCodeSource.capturedDependenciesChanged(rootPath: f.root.path, manifest: original))
        try f.writeWorkspace(["configuration": config.absoluteString])
        let baseline = try manifest()
        XCTAssertFalse(try CollectorVSCodeSource.capturedDependenciesChanged(rootPath: f.root.path, manifest: baseline))
        // Invalid new payload still needs recapture/privacy rejection; this probe never parses it.
        try Data("invalid replacement configuration".utf8).write(to: config)
        XCTAssertTrue(try CollectorVSCodeSource.capturedDependenciesChanged(rootPath: f.root.path, manifest: baseline))
        try FileManager.default.removeItem(at: config)
        XCTAssertTrue(try CollectorVSCodeSource.capturedDependenciesChanged(rootPath: f.root.path, manifest: baseline))
        try FileManager.default.createSymbolicLink(at: config, withDestinationURL: f.primaryURL)
        XCTAssertTrue(try CollectorVSCodeSource.capturedDependenciesChanged(rootPath: f.root.path, manifest: baseline))
        XCTAssertEqual(try fixtureDescriptors(under: f.base), [])
    }

    func testCapturedDependencyProbeDetectsPreviouslyAbsentConfigurationAndSourceReplacement() throws {
        let f = try VSCodeFixture(); defer { f.remove() }
        try f.writePrimary()
        let config = f.projects.appendingPathComponent("later.code-workspace")
        try f.writeWorkspace(["configuration": config.absoluteString])
        let observed = try CollectorVSCodeSource.observe(rootPath: f.root.path,
            primaryRelative: f.primary, maximumByteCount: 1_048_576)
        let manifest = try manifestForObserved(observed, root: f.root.path)
        XCTAssertFalse(try CollectorVSCodeSource.capturedDependenciesChanged(rootPath: f.root.path, manifest: manifest))
        try Data("{}".utf8).write(to: config)
        XCTAssertTrue(try CollectorVSCodeSource.capturedDependenciesChanged(rootPath: f.root.path, manifest: manifest))
        try FileManager.default.moveItem(at: f.root, to: f.base.appendingPathComponent("previous-root"))
        try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: false)
        XCTAssertTrue(try CollectorVSCodeSource.capturedDependenciesChanged(rootPath: f.root.path, manifest: manifest))
        XCTAssertEqual(try fixtureDescriptors(under: f.base), [])
    }

    func testSelectedPrimaryRequiresWorkspaceChatSessionsJsonl() {
        XCTAssertTrue(CollectorVSCodeSource.isSelectedPrimary(
            rootPath: "", components: ["ws", "chatSessions", "native.jsonl"]))
        XCTAssertFalse(CollectorVSCodeSource.isSelectedPrimary(
            rootPath: "", components: ["ws", "chatSessions", ".jsonl"]))
        XCTAssertFalse(CollectorVSCodeSource.isSelectedPrimary(
            rootPath: "", components: ["ws", "chatSessions", "native.json"]))
        XCTAssertFalse(CollectorVSCodeSource.isSelectedPrimary(
            rootPath: "", components: ["ws", "sessions", "native.jsonl"]))
        XCTAssertFalse(CollectorVSCodeSource.isSelectedPrimary(
            rootPath: "", components: ["ws", "native.jsonl"]))
        XCTAssertFalse(CollectorVSCodeSource.isSelectedPrimary(
            rootPath: "", components: [".", "chatSessions", "native.jsonl"]))
        XCTAssertFalse(CollectorVSCodeSource.isSelectedPrimary(
            rootPath: "", components: ["ws", "..", "native.jsonl"]))
    }

    func testFolderStringPrecedesConfigurationAndSkipsExternalBytes() throws {
        let f = try VSCodeFixture(); defer { f.remove() }
        let config = try f.writeConfiguration(["folders": [["path": "/must-not-freeze"]]])
        try f.writePrimary()
        try f.writeWorkspace([
            "folder": "file://localhost/project%20one",
            "configuration": config.absoluteString,
        ])
        let observed = try CollectorVSCodeSource.observe(
            rootPath: f.root.path, primaryRelative: f.primary, maximumByteCount: 1_048_576
        )
        XCTAssertEqual(observed.snapshot.entrypointRelativePath, f.primary)
        XCTAssertEqual(Set(observed.snapshot.present.map(\.relativePath)), [f.primary, f.workspaceRelative])
        XCTAssertEqual(observed.snapshot.absentRelativePaths, [])
        XCTAssertEqual(observed.generation, observed.snapshot.present.first {
            $0.relativePath.utf8.elementsEqual(f.primary.utf8)
        }?.generation)
        let context = try XCTUnwrap(observed.snapshot.vscodeWorkspaceContext)
        XCTAssertNil(context.configurationLocator)
        XCTAssertNil(context.configurationData)
        XCTAssertNoThrow(try CollectorVSCodeSource.requireValidSnapshot(observed.snapshot, entrypoint: f.primary))
        XCTAssertTrue(try matchesObserved(observed, root: f.root.path))
    }

    func testEmptyFolderStringStillBlocksConfiguration() throws {
        let f = try VSCodeFixture(); defer { f.remove() }
        let config = try f.writeConfiguration(["folders": [["path": "/ignored"]]])
        try f.writePrimary()
        try f.writeWorkspace(["folder": "", "configuration": config.absoluteString])
        let context = try XCTUnwrap(CollectorVSCodeSource.observe(
            rootPath: f.root.path, primaryRelative: f.primary, maximumByteCount: 1_048_576
        ).snapshot.vscodeWorkspaceContext)
        XCTAssertNil(context.configurationLocator)
        XCTAssertNil(context.configurationData)
    }

    func testRelativeConfigurationFolderBytesAreFrozen() throws {
        let f = try VSCodeFixture(); defer { f.remove() }
        let configuration: [String: Any] = [
            "folders": ["ignored", ["path": "../project with spaces"], ["path": "/unselected"]],
        ]
        let config = try f.writeConfiguration(configuration)
        try f.writePrimary()
        try f.writeWorkspace(["configuration": config.absoluteString])
        let observed = try CollectorVSCodeSource.observe(
            rootPath: f.root.path, primaryRelative: f.primary, maximumByteCount: 1_048_576
        )
        let context = try XCTUnwrap(observed.snapshot.vscodeWorkspaceContext)
        XCTAssertEqual(context.configurationLocator.map { Data($0.utf8) }, Data(config.path.utf8))
        XCTAssertEqual(context.configurationData, try JSONSerialization.data(withJSONObject: configuration))
        XCTAssertEqual(context.configurationSHA256, context.configurationData.map(ArchiveV2Hash.sha256))
        XCTAssertEqual(context.configurationGeneration?.size, Int64(context.configurationData?.count ?? -1))
        XCTAssertTrue(try matchesObserved(observed, root: f.root.path))
    }

    func testMissingConfigurationFileIsReferencedAbsence() throws {
        let f = try VSCodeFixture(); defer { f.remove() }
        let missing = f.projects.appendingPathComponent("missing.code-workspace")
        try f.writePrimary()
        try f.writeWorkspace(["configuration": missing.absoluteString])
        let context = try XCTUnwrap(CollectorVSCodeSource.observe(
            rootPath: f.root.path, primaryRelative: f.primary, maximumByteCount: 1_048_576
        ).snapshot.vscodeWorkspaceContext)
        XCTAssertEqual(context.configurationLocator.map { Data($0.utf8) }, Data(missing.path.utf8))
        XCTAssertNil(context.configurationData)
        XCTAssertNil(context.configurationGeneration)
        XCTAssertNil(context.configurationSHA256)
    }

    func testMissingNestedParentDoesNotReadSameNamedDecoyInAncestor() throws {
        let f = try VSCodeFixture(); defer { f.remove() }
        let decoy = try JSONSerialization.data(withJSONObject: ["folders": [["path": "/decoy-must-not-read"]]])
        try decoy.write(to: f.projects.appendingPathComponent("decoy.code-workspace"))
        XCTAssertEqual(chmod(f.projects.appendingPathComponent("decoy.code-workspace").path, 0o600), 0)
        let nested = f.projects.appendingPathComponent("missing-parent/decoy.code-workspace")
        try f.writePrimary()
        try f.writeWorkspace(["configuration": nested.absoluteString])
        let before = try fixtureDescriptors(under: f.base)
        let context = try XCTUnwrap(CollectorVSCodeSource.observe(
            rootPath: f.root.path, primaryRelative: f.primary, maximumByteCount: 1_048_576
        ).snapshot.vscodeWorkspaceContext)
        XCTAssertEqual(context.configurationLocator.map { Data($0.utf8) }, Data(nested.path.utf8))
        XCTAssertNil(context.configurationData)
        XCTAssertNotEqual(context.configurationSHA256, ArchiveV2Hash.sha256(decoy))
        XCTAssertEqual(try fixtureDescriptors(under: f.base), before)
    }

    func testAbsentWorkspaceIsExplicitAndHasNoExternalReference() throws {
        let f = try VSCodeFixture(); defer { f.remove() }
        try f.writePrimary()
        let observed = try CollectorVSCodeSource.observe(
            rootPath: f.root.path, primaryRelative: f.primary, maximumByteCount: 1_048_576
        )
        XCTAssertEqual(observed.snapshot.present.map(\.relativePath), [f.primary])
        XCTAssertEqual(observed.snapshot.absentRelativePaths, [f.workspaceRelative])
        let context = try XCTUnwrap(observed.snapshot.vscodeWorkspaceContext)
        XCTAssertNil(context.configurationLocator)
        XCTAssertNil(context.configurationData)
    }

    func testSymlinkWorkspaceOrPrimaryOrExternalIsNeverAbsence() throws {
        let f = try VSCodeFixture(); defer { f.remove() }
        try f.writePrimary()
        let outside = f.base.appendingPathComponent("outside.json")
        try Data("{}".utf8).write(to: outside)
        XCTAssertEqual(chmod(outside.path, 0o600), 0)
        try FileManager.default.createSymbolicLink(at: f.workspaceJSONURL, withDestinationURL: outside)
        let before = try fixtureDescriptors(under: f.base)
        XCTAssertThrowsError(try CollectorVSCodeSource.observe(
            rootPath: f.root.path, primaryRelative: f.primary, maximumByteCount: 1_048_576
        ))
        XCTAssertEqual(try fixtureDescriptors(under: f.base), before)
        try FileManager.default.removeItem(at: f.workspaceJSONURL)
        try f.writeWorkspace(["folder": "file:///project"])
        try FileManager.default.removeItem(at: f.primaryURL)
        try FileManager.default.createSymbolicLink(at: f.primaryURL, withDestinationURL: outside)
        XCTAssertThrowsError(try CollectorVSCodeSource.observe(
            rootPath: f.root.path, primaryRelative: f.primary, maximumByteCount: 1_048_576
        ))
        try FileManager.default.removeItem(at: f.primaryURL)
        try f.writePrimary()
        let config = f.projects.appendingPathComponent("linked.code-workspace")
        try FileManager.default.createSymbolicLink(at: config, withDestinationURL: outside)
        try f.writeWorkspace(["configuration": config.absoluteString])
        XCTAssertThrowsError(try CollectorVSCodeSource.observe(
            rootPath: f.root.path, primaryRelative: f.primary, maximumByteCount: 1_048_576
        ))
        XCTAssertEqual(try fixtureDescriptors(under: f.base), before)
    }

    func testNamedAncestryRecheckRejectsReplacedWorkspaceDirectory() throws {
        let f = try VSCodeFixture(); defer { f.remove() }
        try f.writePrimary()
        try f.writeWorkspace(["folder": "file:///project"])
        var seen = 0
        var hooks = CollectorPOSIXRootEnumeratorTestHooks()
        hooks.beforeOpenComponent = { name in
            guard name == f.workspace else { return }
            seen += 1
            guard seen == 2 else { return }
            let moved = f.base.appendingPathComponent("moved-ws")
            try FileManager.default.moveItem(at: f.workspaceURL, to: moved)
            try FileManager.default.createDirectory(at: f.workspaceURL, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(
                at: f.workspaceURL.appendingPathComponent(CollectorVSCodeSource.chatsName),
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        }
        XCTAssertThrowsError(try CollectorVSCodeSource.observe(
            rootPath: f.root.path, primaryRelative: f.primary, maximumByteCount: 1_048_576, testHooks: hooks
        ))
        XCTAssertGreaterThanOrEqual(seen, 2)
    }

    func testBudgetsAdmitPrimaryBeforeMetadataAndBoundSidecars() throws {
        let f = try VSCodeFixture(); defer { f.remove() }
        try f.writePrimary(Data(repeating: 0x61, count: 64))
        try f.writeWorkspace(["folder": "file:///project"])
        XCTAssertThrowsError(try CollectorVSCodeSource.observe(
            rootPath: f.root.path, primaryRelative: f.primary, maximumByteCount: 32
        ))
        try f.writeWorkspace(Data(repeating: 0x7B, count: ArchiveVSCodeWorkspaceContext.maximumContextBytes + 1))
        XCTAssertThrowsError(try CollectorVSCodeSource.observe(
            rootPath: f.root.path, primaryRelative: f.primary, maximumByteCount: 1_048_576
        ))
        let oversized = Data(repeating: 0x7B, count: ArchiveVSCodeWorkspaceContext.maximumContextBytes + 1)
        let config = f.projects.appendingPathComponent("huge.code-workspace")
        try oversized.write(to: config)
        XCTAssertEqual(chmod(config.path, 0o600), 0)
        try f.writeWorkspace(["configuration": config.absoluteString])
        XCTAssertThrowsError(try CollectorVSCodeSource.observe(
            rootPath: f.root.path, primaryRelative: f.primary, maximumByteCount: 1_048_576
        ))
        let small = try f.writeConfiguration(["folders": [["path": "/ok"]]])
        try f.writePrimary(Data(repeating: 0x61, count: 20))
        try f.writeWorkspace(["configuration": small.absoluteString])
        let workspaceSize = try Int64(f.workspaceJSONURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let configSize = try Int64(small.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        XCTAssertThrowsError(try CollectorVSCodeSource.observe(
            rootPath: f.root.path, primaryRelative: f.primary,
            maximumByteCount: 20 + workspaceSize + configSize - 1
        ))
        XCTAssertNoThrow(try CollectorVSCodeSource.observe(
            rootPath: f.root.path, primaryRelative: f.primary,
            maximumByteCount: 20 + workspaceSize + configSize
        ))
    }

    func testRequireValidSnapshotRejectsOpenSetOrForeignContext() throws {
        let f = try VSCodeFixture(); defer { f.remove() }
        try f.writePrimary()
        let observed = try CollectorVSCodeSource.observe(
            rootPath: f.root.path, primaryRelative: f.primary, maximumByteCount: 1_048_576
        )
        XCTAssertThrowsError(try CollectorVSCodeSource.requireValidSnapshot(
            observed.snapshot, entrypoint: "other/chatSessions/native.jsonl"
        ))
        let stripped = CollectorDependencySnapshot(
            entrypointRelativePath: f.primary, present: observed.snapshot.present,
            absentRelativePaths: observed.snapshot.absentRelativePaths
        )
        XCTAssertThrowsError(try CollectorVSCodeSource.requireValidSnapshot(stripped, entrypoint: f.primary))
        XCTAssertFalse(CollectorVSCodeSource.matchesReservedSnapshot(observed.snapshot, manifest: try dummySingleFileManifest()))
    }
}

private struct VSCodeFixture {
    let base: URL
    let root: URL
    let projects: URL
    let workspace = "ws"
    var primary: String { workspace + "/chatSessions/native.jsonl" }
    var workspaceRelative: String { workspace + "/" + CollectorVSCodeSource.workspaceName }
    var workspaceURL: URL { root.appendingPathComponent(workspace) }
    var primaryURL: URL { root.appendingPathComponent(primary) }
    var workspaceJSONURL: URL { root.appendingPathComponent(workspaceRelative) }

    init() throws {
        if let expectedHome = ProcessInfo.processInfo.environment["ENGRAM_DEMO_EXPECTED_HOME"] {
            guard FileManager.default.homeDirectoryForCurrentUser.path == expectedHome else {
                throw CollectorPublicationWorkerError.invalidCapture
            }
        }
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        base = checkout.appendingPathComponent(".engram-vscode-test-\(UUID().uuidString)")
        root = base.appendingPathComponent("storage")
        projects = base.appendingPathComponent("projects")
        try FileManager.default.createDirectory(
            at: primaryURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: projects, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
    }

    func writePrimary(_ data: Data = Data("{}\n".utf8)) throws {
        try data.write(to: primaryURL)
        XCTAssertEqual(chmod(primaryURL.path, 0o600), 0)
    }

    func writeWorkspace(_ object: [String: Any]) throws {
        try writeWorkspace(JSONSerialization.data(withJSONObject: object))
    }

    func writeWorkspace(_ data: Data) throws {
        try data.write(to: workspaceJSONURL)
        XCTAssertEqual(chmod(workspaceJSONURL.path, 0o600), 0)
    }

    func writeConfiguration(_ object: [String: Any]) throws -> URL {
        let url = projects.appendingPathComponent("example.code-workspace")
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        XCTAssertEqual(chmod(url.path, 0o600), 0)
        return url
    }

    func remove() { try? FileManager.default.removeItem(at: base) }
}

private func matchesObserved(
    _ observed: (generation: ArchiveSourceGeneration, snapshot: CollectorDependencySnapshot), root: String
) throws -> Bool {
    CollectorVSCodeSource.matchesReservedSnapshot(observed.snapshot, manifest: try manifestForObserved(observed, root: root))
}

private func manifestForObserved(
    _ observed: (generation: ArchiveSourceGeneration, snapshot: CollectorDependencySnapshot), root: String
) throws -> ArchiveSourceManifest {
    var offset: Int64 = 0
    let files = try observed.snapshot.present.map { member -> ArchiveFileSetEntry in
        let entry = try ArchiveFileSetEntry(
            relativePath: member.relativePath, byteOffset: offset, rawByteCount: member.generation.size,
            wholeSourceSHA256: member.generation.size == 0
                ? ArchiveV2Hash.sha256(Data()) : ArchiveV2Hash.sha256(Data(String(offset).utf8)),
            generation: member.generation
        )
        offset += member.generation.size
        return entry
    }
    let layout = try ArchiveReplayLayout(
        strategy: .fileSet, relativePaths: files.map(\.relativePath),
        entrypointRelativePath: observed.snapshot.entrypointRelativePath, files: files,
        absentRelativePaths: observed.snapshot.absentRelativePaths,
        vscodeWorkspaceContext: observed.snapshot.vscodeWorkspaceContext
    )
    let digest = ArchiveV2Hash.sha256(Data("capture".utf8))
    let manifest = try ArchiveSourceManifest(
        schemaVersion: 7, captureID: digest, machineID: UUID().uuidString, source: "vscode",
        locator: root + "/" + observed.snapshot.entrypointRelativePath, sessionID: nil,
        capturedAt: "2026-09-09T00:00:00.000Z", generation: observed.generation,
        wholeSourceSHA256: offset == 0 ? ArchiveV2Hash.sha256(Data()) : digest, rawByteCount: offset,
        chunks: offset == 0 ? [] : [try ArchiveChunkReference(ordinal: 0, rawSHA256: digest, rawByteCount: offset)],
        replayLayout: layout
    )
    return manifest
}

private func dummySingleFileManifest() throws -> ArchiveSourceManifest {
    let generation = try ArchiveSourceGeneration(
        device: 1, inode: 1, size: 1, mtimeNs: 1, ctimeNs: 1, mode: 0o100644
    )
    let digest = ArchiveV2Hash.sha256(Data("x".utf8))
    return try ArchiveSourceManifest(
        captureID: digest, machineID: UUID().uuidString, source: "codex",
        locator: "/tmp/session.jsonl", sessionID: nil, capturedAt: "2026-09-09T00:00:00.000Z",
        generation: generation, wholeSourceSHA256: digest, rawByteCount: 1,
        chunks: [try ArchiveChunkReference(ordinal: 0, rawSHA256: digest, rawByteCount: 1)],
        replayLayout: try ArchiveReplayLayout(strategy: .singleFile, relativePaths: ["session.jsonl"])
    )
}

private func fixtureDescriptors(under root: URL) throws -> [Int32] {
    try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").compactMap { name -> Int32? in
        guard let descriptor = Int32(name) else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let result = buffer.withUnsafeMutableBufferPointer { fcntl(descriptor, F_GETPATH, $0.baseAddress!) }
        guard result == 0 else { return nil }
        let path = String(cString: buffer)
        return path == root.path || path.hasPrefix(root.path + "/") ? descriptor : nil
    }.sorted()
}
