import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import EngramCollectorCore
@testable import EngramCoreRead
@testable import EngramCoreWrite

final class KimiSnapshotReplayTests: XCTestCase {
    func testCapturedShardsAndScopedRegistryPreserveNativeReplayAfterOriginalRemoval() async throws {
        try await verifyReplay(withWire: true)
    }

    func testAbsentWirePreservesNativeFallbackTimeAfterOriginalRemoval() async throws {
        try await verifyReplay(withWire: false)
    }

    func testCapturedKimiFactoryPreservesNativeMetadataWithWire() async throws {
        try await verifyReplay(withWire: true, throughFactory: true)
    }

    func testCapturedKimiFactoryPreservesNativeFallbackWithoutWire() async throws {
        try await verifyReplay(withWire: false, throughFactory: true)
    }

    func testCollectorKimiCASReplaysThroughHQWithoutOriginalInputs() async throws {
        try await verifyReplay(withWire: true, throughHQ: true)
    }

    func testCollectorKimiCASReplaysThroughHQWithNativeFallbackTime() async throws {
        try await verifyReplay(withWire: false, throughHQ: true)
    }

    private func verifyReplay(withWire: Bool, throughFactory: Bool = false, throughHQ: Bool = false) async throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("engram-kimi-replay-" + UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: false)
        let physical = try XCTUnwrap(realpath(temporary.path, nil))
        defer { free(physical) }
        let base = URL(fileURLWithPath: String(cString: physical))
        defer { try? fm.removeItem(at: base) }
        let source = base.appendingPathComponent("source")
        let root = source.appendingPathComponent("sessions")
        let registry = source.appendingPathComponent("kimi.json")
        let workspace = Insecure.MD5.hash(data: Data("/repo/native-kimi".utf8)).map { String(format: "%02x", $0) }.joined()
        let relative = workspace + "/native-session/context.jsonl"
        let primary = root.appendingPathComponent(relative)
        try fm.createDirectory(at: primary.deletingLastPathComponent(), withIntermediateDirectories: true)
        func write(_ name: String, _ rows: [[String: Any]]) throws {
            var data = Data()
            for row in rows { data.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])); data.append(10) }
            let path = primary.deletingLastPathComponent().appendingPathComponent(name)
            try data.write(to: path)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_788_825_600)], ofItemAtPath: path.path)
        }
        try write("context.jsonl", [["role": "user", "content": "constellation first turn"]])
        try write("context_sub_1.jsonl", [["role": "assistant", "content": "sub family turn"]])
        try write("context_1.jsonl", [["role": "assistant", "content": "rotation family turn"]])
        try write("context_sub_2.jsonl", [["role": "assistant", "content": "first response",
            "tool_calls": [["function": ["name": "read_file", "arguments": "{\"path\":\"hello.swift\"}"]]]]])
        try write("context_10.jsonl", [["role": "tool", "content": "tool output"],
            ["role": "user", "content": "aurora second turn"], ["role": "assistant", "content": "second response"]])
        let rotationBytes = try Data(contentsOf: primary.deletingLastPathComponent().appendingPathComponent("context_1.jsonl"))
        let subFamilyBytes = try Data(contentsOf: primary.deletingLastPathComponent().appendingPathComponent("context_sub_1.jsonl"))
        if withWire {
            try write("wire.jsonl", [
                ["timestamp": 1_788_825_601, "message": ["type": "TurnBegin"]],
                ["timestamp": 1_788_825_602, "message": ["type": "StatusUpdate", "payload": ["token_usage": ["input_other": 96, "output": 12, "input_cache_read": 4, "input_cache_creation": 3]]]],
                ["timestamp": 1_788_825_603, "message": ["type": "TurnEnd"]],
                ["timestamp": 1_788_825_604, "message": ["type": "TurnBegin"]],
                ["timestamp": 1_788_825_605, "message": ["type": "StatusUpdate", "payload": ["token_usage": ["input_other": 24, "output": 8]]]],
                ["timestamp": 1_788_825_606, "message": ["type": "TurnEnd"]]
            ])
        }
        try JSONSerialization.data(withJSONObject: ["work_dirs": [
            ["path": "/repo/native-kimi", "last_session_id": "native-session"],
            ["path": "/SIBLING-SECRET", "last_session_id": "another-session"]
        ], "UNRELATED-SECRET": "must never be captured"]).write(to: registry)
        let native = KimiAdapter(sessionsRoot: root.path, kimiJsonPath: registry.path)
        guard case .success(let before) = try await native.scanForIndexing(locator: primary.path) else {
            return XCTFail("native fixture must parse before capture")
        }
        XCTAssertNil(before.parseFailure)
        XCTAssertEqual(before.messages.map(\.content), ["constellation first turn", "rotation family turn", "sub family turn", "first response", "tool output", "aurora second turn", "second response"])
        XCTAssertEqual(before.info.id, "native-session")
        XCTAssertEqual(before.info.cwd, "/repo/native-kimi")
        if withWire {
            let firstTurn = try XCTUnwrap(before.messages.first { $0.content == "first response" })
            XCTAssertEqual(firstTurn.usage?.inputTokens, 96)
            XCTAssertEqual(firstTurn.usage?.outputTokens, 12)
            XCTAssertEqual(firstTurn.usage?.cacheReadTokens, 4)
            XCTAssertEqual(firstTurn.usage?.cacheCreationTokens, 3)
        }
        let observed = try CollectorKimiSource.observe(rootPath: root.path, primaryRelative: relative, registryLocator: registry.path)
        let snapshot = observed.snapshot
        let expectedPresent = Set(
            (["context.jsonl", "context_1.jsonl", "context_sub_1.jsonl", "context_sub_2.jsonl", "context_10.jsonl"]
                + (withWire ? ["wire.jsonl"] : [])
            ).map { workspace + "/native-session/" + $0 }
        )
        XCTAssertEqual(Set(snapshot.present.map(\.relativePath)), expectedPresent)
        XCTAssertEqual(
            try Data(contentsOf: primary.deletingLastPathComponent().appendingPathComponent("context_1.jsonl")),
            rotationBytes
        )
        XCTAssertEqual(
            try Data(contentsOf: primary.deletingLastPathComponent().appendingPathComponent("context_sub_1.jsonl")),
            subFamilyBytes
        )
        let context = try XCTUnwrap(snapshot.kimiProjectContext)
        let descriptor = try EngramCollectorCore.ArchiveSourceDescriptor.fileSet(locator: primary.path, root: root,
            files: snapshot.present.map { root.appendingPathComponent($0.relativePath) },
            absentFiles: snapshot.absentRelativePaths.map { root.appendingPathComponent($0) }, kimiProjectContext: context)
        let archive = base.appendingPathComponent("archive")
        let machineID = "11111111-2222-3333-4444-555555555555"
        let cas = try EngramCollectorCore.ImmutableArchiveCAS(root: archive)
        let catalog = try EngramCollectorCore.ArchiveCatalog(root: archive, machineID: machineID)
        try catalog.migrate()
        defer { try? catalog.close() }
        let captured = try EngramCollectorCore.ExactSourceCapturer(cas: cas, catalog: catalog, descriptor: descriptor)
            .capture(source: .kimi, locator: primary.path, machineID: machineID, expectedGeneration: observed.generation)
        XCTAssertEqual(try CollectorKimiSource.observe(rootPath: root.path, primaryRelative: relative, registryLocator: registry.path), observed)
        let raw = try captured.manifest.chunks.reduce(into: Data()) { bytes, chunk in bytes.append(try cas.readObject(sha256: chunk.rawSHA256)) }
        XCTAssertNil(raw.range(of: Data("SIBLING-SECRET".utf8)))
        XCTAssertNil(observed.context.scopedRegistryBytes.range(of: Data("UNRELATED-SECRET".utf8)))
        try fm.removeItem(at: source)
        let stage = base.appendingPathComponent("stage")
        for file in try XCTUnwrap(captured.manifest.replayLayout.files) {
            let path = stage.appendingPathComponent(file.relativePath)
            try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bytes = raw.subdata(in: Int(file.byteOffset)..<Int(file.byteOffset + file.rawByteCount))
            XCTAssertEqual(EngramCollectorCore.ArchiveV2Hash.sha256(bytes), file.wholeSourceSHA256)
            if file.relativePath.hasSuffix("/context_1.jsonl") { XCTAssertEqual(bytes, rotationBytes) }
            if file.relativePath.hasSuffix("/context_sub_1.jsonl") { XCTAssertEqual(bytes, subFamilyBytes) }
            try bytes.write(to: path)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(file.generation.mtimeNs) / 1_000_000_000)], ofItemAtPath: path.path)
        }
        let stagedRegistry = stage.appendingPathComponent("scoped-kimi.json")
        let roundTripped = try EngramCollectorCore.ArchiveCanonicalJSON.decode(
            EngramCollectorCore.ArchiveSourceManifest.self,
            from: EngramCollectorCore.ArchiveCanonicalJSON.encode(captured.manifest))
        XCTAssertEqual(roundTripped.schemaVersion, 5)
        let restoredContext = try XCTUnwrap(roundTripped.replayLayout.kimiProjectContext)
        XCTAssertEqual(restoredContext, context)
        let scoped = try JSONSerialization.data(withJSONObject: ["work_dirs": [[
            "path": restoredContext.cwd, "last_session_id": restoredContext.nativeSessionID]]])
        try scoped.write(to: stagedRegistry)
        let replay = KimiAdapter(sessionsRoot: stage.path, kimiJsonPath: stagedRegistry.path)
        guard case .success(let after) = try await replay.scanForIndexing(locator: stage.appendingPathComponent(relative).path) else {
            return XCTFail("captured native inputs must replay without original source")
        }
        var actualInfo = after.info
        actualInfo.filePath = before.info.filePath
        XCTAssertEqual(actualInfo, before.info)
        XCTAssertEqual(after.messages, before.messages)
        XCTAssertNil(after.parseFailure)
        XCTAssertEqual(after.info.sizeBytes, before.info.sizeBytes)
        if withWire { XCTAssertGreaterThan(captured.manifest.rawByteCount, after.info.sizeBytes) }
        XCTAssertFalse(fm.fileExists(atPath: source.path))
        if throughFactory {
            let layout = try EngramCoreRead.ArchiveCanonicalJSON.decode(EngramCoreRead.ArchiveReplayLayout.self,
                from: EngramCollectorCore.ArchiveCanonicalJSON.encode(captured.manifest.replayLayout))
            let contents = try fm.subpathsOfDirectory(atPath: stage.path).sorted()
            guard case .success(let replay) = try await SessionAdapterFactory.scanCapturedSource(
                physicalLocator: stage.appendingPathComponent(relative).path, stagingRoot: stage.path,
                logicalLocator: primary.path, format: .kimi,
                capturedModificationNanoseconds: captured.manifest.generation.mtimeNs,
                capturedReplayLayout: layout) else { return XCTFail("native captured Kimi factory must parse immutable inputs") }
            XCTAssertEqual(replay.scan.info, before.info)
            XCTAssertEqual(replay.scan.messages, before.messages)
            XCTAssertEqual(replay.rawSourceSessionID, "native-session")
            XCTAssertEqual(try fm.subpathsOfDirectory(atPath: stage.path).sorted(), contents,
                "captured parsing must not create unverified side inputs")
        }
        if throughHQ {
            let format = try XCTUnwrap(EngramCoreWrite.CaptureIngestParseFormat(rawValue: "kimi"))
            let hqWriter = try EngramCoreWrite.EngramDatabaseWriter(path: base.appendingPathComponent("hq-index.sqlite").path)
            try hqWriter.migrate()
            let instance = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
            let epoch = "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"
            let binding = try hqWriter.write { db in
                try EngramCoreWrite.CaptureIngestSourceRegistry.provision(db, machineID: machineID,
                    sourceInstanceID: instance, source: .kimi, parseFormat: format,
                    configuredRoot: root.path, initialEpoch: epoch)
            }
            let publication = try EngramCoreRead.CollectorPublicationEnvelope(machineID: machineID,
                sourceInstanceID: instance, collectorEpoch: epoch, sequence: 1,
                manifestSHA256: captured.capture.unboundManifestSHA256)
            let hqCAS = try EngramCoreWrite.ImmutableArchiveCAS(root: archive)
            let hqStage = base.appendingPathComponent("hq-stage")
            try fm.createDirectory(at: hqStage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let replay = try await EngramCoreWrite.CaptureIngestReplay.replay(publication: publication,
                bindingSnapshot: binding, cas: hqCAS, stagingParent: hqStage)
            XCTAssertEqual(replay.scan.info, before.info)
            XCTAssertEqual(replay.scan.messages, before.messages)
            XCTAssertEqual(replay.rawSourceSessionID, "native-session")
            XCTAssertEqual(replay.nativeIdentity.nativeID, "native-session")
            XCTAssertEqual(replay.verifiedManifest.replayLayout.kimiProjectContext?.cwd, before.info.cwd)
            XCTAssertTrue(try fm.contentsOfDirectory(atPath: hqStage.path).isEmpty)
            XCTAssertFalse(fm.fileExists(atPath: source.path))
        }
        // Scoped provenance now survives the immutable manifest round-trip;
        // Runtime admission, network publication and HQ commit remain separate.
    }
}
