import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import EngramCollectorCore

final class CollectorKimiSourceTests: XCTestCase {
    func testObservationCarriesItsScopedRegistryInTheDurableSnapshot() throws {
        let f = try KimiFixture(); defer { f.remove() }
        let observed = try f.observe()
        let durable = try XCTUnwrap(observed.snapshot.kimiProjectContext)
        XCTAssertEqual(durable.workspaceName, observed.context.workspaceName)
        XCTAssertEqual(durable.nativeSessionID, observed.context.nativeSessionID)
        XCTAssertEqual(durable.cwd, observed.context.cwd)
        XCTAssertEqual(durable.registryLocator, observed.context.registryLocator)
        XCTAssertEqual(durable.registryGeneration, observed.context.registryGeneration)
        XCTAssertEqual(durable.registrySHA256, observed.context.registrySHA256)
        XCTAssertNoThrow(try CollectorKimiSource.requireValidSnapshot(observed.snapshot, entrypoint: f.primary))
    }

    func testObserveCapturesOnlyNativeDependenciesAndScopedDirectoryEvidence() throws {
        let f = try KimiFixture(); defer { f.remove() }
        try f.file("context_10.jsonl", "ten")
        try f.file("context_sub_2.jsonl", "two")
        try f.file("context_-1.jsonl", "negative index is accepted by the native adapter")
        try f.file("wire.jsonl", "wire")
        try f.file("context_backup.jsonl", "not a native shard")
        try f.file("private.txt", "UNRELATED-SECRET")
        try f.registryRows([["path": "/repo/kimi", "last_session_id": "session-one", "private_note": "SELECTED-ROW-SECRET"],
            ["path": "/UNRELATED-SECRET", "last_session_id": "other"]])
        let before = try Data(contentsOf: f.registry)
        let value = try f.observe()
        XCTAssertEqual(value.snapshot.present.map(\.relativePath),
            ["context.jsonl", "context_-1.jsonl", "context_10.jsonl", "context_sub_2.jsonl", "wire.jsonl"].map { f.prefix + $0 }.sorted())
        XCTAssertTrue(value.snapshot.absentRelativePaths.isEmpty)
        XCTAssertNil(value.snapshot.geminiProjectContext)
        XCTAssertEqual(value.generation, value.snapshot.present.first { $0.relativePath == f.primary }?.generation)
        XCTAssertEqual(value.context.workspaceName, f.workspace)
        XCTAssertEqual(value.context.nativeSessionID, "session-one")
        XCTAssertEqual(value.context.cwd, "/repo/kimi")
        XCTAssertEqual(value.context.registryLocator, f.registry.path)
        XCTAssertEqual(value.context.registrySHA256, ArchiveV2Hash.sha256(before))
        XCTAssertNil(value.context.scopedRegistryBytes.range(of: Data("UNRELATED-SECRET".utf8)))
        XCTAssertNil(value.context.scopedRegistryBytes.range(of: Data("SELECTED-ROW-SECRET".utf8)))
        let scoped = try XCTUnwrap(JSONSerialization.jsonObject(with: value.context.scopedRegistryBytes) as? [String: Any])
        let rows = try XCTUnwrap(scoped["work_dirs"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["path"] as? String, "/repo/kimi")
        XCTAssertEqual(try Data(contentsOf: f.registry), before)
    }

    func testAbsentWireAndShardOnlyChangesArePartOfTheObservation() throws {
        let f = try KimiFixture(); defer { f.remove() }
        let first = try f.observe()
        XCTAssertEqual(first.snapshot.absentRelativePaths, [f.prefix + "wire.jsonl"])
        try f.file("context_1.jsonl", "assistant shard")
        let shard = try f.observe()
        XCTAssertEqual(first.generation, shard.generation)
        XCTAssertNotEqual(first.snapshot, shard.snapshot)
        try f.file("wire.jsonl", "timestamp and usage")
        let wire = try f.observe()
        XCTAssertEqual(first.generation, wire.generation)
        XCTAssertNotEqual(shard.snapshot, wire.snapshot)
        try FileManager.default.removeItem(at: f.session.appendingPathComponent("context_1.jsonl"))
        XCTAssertNotEqual(try f.observe().snapshot, wire.snapshot)
    }

    func testHashMappingWinsOverLastSessionFallbackAndSupportsKaos() throws {
        let f = try KimiFixture(kaos: "remote"); defer { f.remove() }
        try f.registryRows([
            ["path": "/wrong/fallback", "last_session_id": "session-one"],
            ["path": "/repo/kimi", "kaos": "remote", "last_session_id": "other"]
        ])
        XCTAssertEqual(try f.observe().context.cwd, "/repo/kimi")
    }

    func testUnrelatedNonObjectRegistryRowsDoNotBlockNativeDirectoryMapping() throws {
        let f = try KimiFixture(); defer { f.remove() }
        let rows: [Any] = [NSNull(), "legacy invalid entry", ["path": "/repo/kimi", "last_session_id": "other"]]
        try JSONSerialization.data(withJSONObject: ["work_dirs": rows]).write(to: f.registry)
        XCTAssertEqual(try f.observe().context.cwd, "/repo/kimi",
            "the native adapter skips non-object rows before resolving a valid workspace hash")
    }

    func testHashSelectedProjectionDoesNotRetainAnotherSessionIdentifier() throws {
        let f = try KimiFixture(); defer { f.remove() }
        try f.registryRows([["path": "/repo/kimi", "last_session_id": "OTHER-SESSION-SECRET"]])
        let value = try f.observe()
        XCTAssertEqual(value.context.nativeSessionID, "session-one")
        XCTAssertEqual(value.context.cwd, "/repo/kimi")
        XCTAssertNil(value.context.scopedRegistryBytes.range(of: Data("OTHER-SESSION-SECRET".utf8)),
            "hash mapping already supplies cwd; another session identifier is not a replay dependency")
    }

    func testUniqueLastSessionFallbackAndRegistryOnlyChangeKeepPrimaryIdentity() throws {
        let f = try KimiFixture(workspaceOverride: "legacy-workspace"); defer { f.remove() }
        let first = try f.observe()
        try f.registryRows([["path": "/repo/new", "last_session_id": "session-one"]])
        let changed = try f.observe()
        XCTAssertEqual(first.generation, changed.generation)
        XCTAssertEqual(first.snapshot.present, changed.snapshot.present)
        XCTAssertNotEqual(first.snapshot, changed.snapshot,
            "registry-only changes must be visible to durable reservation identity")
        XCTAssertNotEqual(first.context, changed.context)
        XCTAssertEqual(changed.context.cwd, "/repo/new")
    }

    func testAmbiguousFallbackAndMissingOrInvalidDirectoryEvidenceAreRefused() throws {
        let f = try KimiFixture(workspaceOverride: "legacy-workspace"); defer { f.remove() }
        for rows in [
            [["path": "/repo/one", "last_session_id": "session-one"], ["path": "/repo/two", "last_session_id": "session-one"]],
            [["path": "relative", "last_session_id": "session-one"]],
            [["path": "/repo/\u{0000}bad", "last_session_id": "session-one"]],
            [["path": "/unmatched", "last_session_id": "other"]]
        ] {
            try f.registryRows(rows)
            XCTAssertThrowsError(try f.observe())
        }
    }

    func testRegistryMustBeBoundedRegularJSONAndCannotBeASymlink() throws {
        let f = try KimiFixture(); defer { f.remove() }
        try Data(repeating: 0x20, count: 65_537).write(to: f.registry)
        XCTAssertThrowsError(try f.observe())
        try Data("not JSON".utf8).write(to: f.registry)
        XCTAssertThrowsError(try f.observe())
        try FileManager.default.removeItem(at: f.registry)
        let target = f.base.appendingPathComponent("outside.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: f.registry, withDestinationURL: target)
        XCTAssertThrowsError(try f.observe())
    }

    func testRecognizedSymlinkAndFIFOShardsAreRefusedWithoutReadingThem() throws {
        let f = try KimiFixture(); defer { f.remove() }
        let shard = f.session.appendingPathComponent("context_1.jsonl")
        try FileManager.default.createSymbolicLink(at: shard, withDestinationURL: f.registry)
        XCTAssertThrowsError(try f.observe())
        try FileManager.default.removeItem(at: shard)
        XCTAssertEqual(mkfifo(shard.path, 0o600), 0)
        XCTAssertThrowsError(try f.observe())
    }

    func testMixedFamilyShardsAtTheSameNumericIndexArePreservedExactly() throws {
        let f = try KimiFixture(); defer { f.remove() }
        let rotation = "{\"role\":\"assistant\",\"content\":\"rotation family turn\"}\n"
        let sub = "{\"role\":\"assistant\",\"content\":\"sub family turn\"}\n"
        try f.file("context_sub_1.jsonl", sub)
        try f.file("context_1.jsonl", rotation)
        let observed = try f.observe()
        XCTAssertEqual(try Data(contentsOf: f.session.appendingPathComponent("context_1.jsonl")), Data(rotation.utf8))
        XCTAssertEqual(try Data(contentsOf: f.session.appendingPathComponent("context_sub_1.jsonl")), Data(sub.utf8))
        XCTAssertEqual(Set(observed.snapshot.present.map(\.relativePath)),
            [f.primary, f.prefix + "context_1.jsonl", f.prefix + "context_sub_1.jsonl"])
        XCTAssertEqual(observed.snapshot.absentRelativePaths, [f.prefix + "wire.jsonl"])
        XCTAssertNoThrow(try CollectorKimiSource.requireValidSnapshot(observed.snapshot, entrypoint: f.primary))
        try f.file("context_01.jsonl", "same family padded index remains ambiguous")
        XCTAssertThrowsError(try f.observe())
        try FileManager.default.removeItem(at: f.session.appendingPathComponent("context_01.jsonl"))
        try f.file("context_sub_01.jsonl", "same sub family padded index remains ambiguous")
        XCTAssertThrowsError(try f.observe())
    }

    func testAmbiguousShardOrderAndTooManyDependenciesAreRefused() throws {
        let f = try KimiFixture(); defer { f.remove() }
        try f.file("context_1.jsonl", "one")
        try f.file("context_01.jsonl", "same family padded index, undefined order")
        XCTAssertThrowsError(try f.observe())
        try FileManager.default.removeItem(at: f.session.appendingPathComponent("context_01.jsonl"))
        for i in 2...63 { try f.file("context_\(i).jsonl", "shard") }
        XCTAssertThrowsError(try f.observe(), "primary plus absent wire consume two of the 64 slots")
    }

    func testRegistryReplacementDuringObservationIsRefused() throws {
        let f = try KimiFixture(); defer { f.remove() }
        XCTAssertThrowsError(try f.observe {
            try f.registryRows([["path": "/repo/changed", "last_session_id": "session-one"]])
        })
    }

    func testNewShardAndSessionDirectoryReplacementDuringObservationAreRefused() throws {
        let f = try KimiFixture(); defer { f.remove() }
        XCTAssertThrowsError(try f.observe { try f.file("context_2.jsonl", "late shard") })
        XCTAssertThrowsError(try f.observe {
            try FileManager.default.moveItem(at: f.session, to: f.base.appendingPathComponent("old-session"))
            try FileManager.default.createDirectory(at: f.session, withIntermediateDirectories: true)
            try f.file("context.jsonl", "replacement")
        })
    }

    func testUnsafeOrNonCanonicalEntrypointsAreRefused() throws {
        let f = try KimiFixture(); defer { f.remove() }
        for primary in ["../context.jsonl", "/" + f.primary, f.prefix + "wire.jsonl", "workspace/context.jsonl", f.prefix + "../context.jsonl"] {
            XCTAssertThrowsError(try CollectorKimiSource.observe(rootPath: f.root.path,
                primaryRelative: primary, registryLocator: f.registry.path))
        }
    }
}

private struct KimiFixture {
    let base: URL
    let root: URL
    let registry: URL
    let workspace: String
    var prefix: String { workspace + "/session-one/" }
    var primary: String { prefix + "context.jsonl" }
    var session: URL { root.appendingPathComponent(prefix) }

    init(kaos: String? = nil, workspaceOverride: String? = nil) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("engram-kimi-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        let physical = try XCTUnwrap(realpath(temporary.path, nil))
        defer { free(physical) }
        base = URL(fileURLWithPath: String(cString: physical))
        root = base.appendingPathComponent("sessions")
        registry = base.appendingPathComponent("kimi.json")
        let digest = Insecure.MD5.hash(data: Data("/repo/kimi".utf8)).map { String(format: "%02x", $0) }.joined()
        workspace = workspaceOverride ?? ((kaos.map { $0 + "_" } ?? "") + digest)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try file("context.jsonl", "{\"role\":\"user\",\"content\":\"hello\"}\n")
        var row = ["path": "/repo/kimi", "last_session_id": "session-one"]
        if let kaos { row["kaos"] = kaos }
        try registryRows([row, ["path": "/UNRELATED-SECRET", "last_session_id": "other"]])
    }

    func file(_ name: String, _ body: String) throws { try Data(body.utf8).write(to: session.appendingPathComponent(name)) }
    func registryRows(_ rows: [[String: String]]) throws {
        try JSONSerialization.data(withJSONObject: ["work_dirs": rows], options: [.sortedKeys]).write(to: registry, options: .atomic)
    }
    func observe(_ hook: (() throws -> Void)? = nil) throws -> CollectorKimiSource.Observation {
        try CollectorKimiSource.observe(rootPath: root.path, primaryRelative: primary,
            registryLocator: registry.path, beforeFinalValidation: hook)
    }
    func remove() { try? FileManager.default.removeItem(at: base) }
}
