import CryptoKit
import Foundation
import XCTest
@testable import EngramRemoteServerCore

/// R10/M14: HEAD existence probes exercise the shipped store APIs
/// (PUT → hasObject/hasManifest), not source-string greps alone.
final class ArchiveHeadExistenceTests: XCTestCase {
    private var root: URL!
    private var key: SymmetricKey!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Do not pre-create the root: ArchiveStore owns 0700 layout (mirrors ArchiveStoreTests).
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-m14-head-\(UUID().uuidString)", isDirectory: true)
        key = SymmetricKey(size: .bits256)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    func testHasObjectAfterPut_behavioral_repro() throws {
        let store = try ArchiveStore(root: root, key: key, serverID: "m14-hq")
        let raw = Data("m14-existence-probe-payload".utf8)
        let digest = ArchiveV2Hash.sha256(raw)

        XCTAssertFalse(
            try store.hasObject(digest: digest),
            "R10: missing object must report false without decrypt"
        )

        let put = try store.putObject(digest: digest, raw: raw)
        XCTAssertEqual(put, .published)

        XCTAssertTrue(
            try store.hasObject(digest: digest),
            "R10: after PUT, hasObject must be true (existence-only)"
        )
        XCTAssertEqual(try store.getObject(digest: digest), raw)

        // Wrong at-rest key: presence still true; decrypt still conflicts.
        let wrongKeyStore = try ArchiveStore(
            root: root,
            key: SymmetricKey(data: Data(repeating: 0x55, count: 32)),
            serverID: "m14-hq"
        )
        XCTAssertTrue(
            try wrongKeyStore.hasObject(digest: digest),
            "R10/M14: hasObject is key-agnostic presence"
        )
        XCTAssertThrowsError(try wrongKeyStore.getObject(digest: digest)) { error in
            XCTAssertEqual(error as? ArchiveStoreError, .conflict)
        }
    }

    func testHasManifestAfterPut_behavioral_repro() throws {
        let store = try ArchiveStore(root: root, key: key, serverID: "m14-hq")
        let raw = Data("manifest-ref-object".utf8)
        let objectDigest = ArchiveV2Hash.sha256(raw)
        _ = try store.putObject(digest: objectDigest, raw: raw)

        let (manifestBytes, manifestDigest) = try Self.manifest(raw: raw, seed: "m14-manifest")
        XCTAssertFalse(try store.hasManifest(digest: manifestDigest))

        let put = try store.putManifest(digest: manifestDigest, canonicalBytes: manifestBytes)
        XCTAssertEqual(put, .published)
        XCTAssertTrue(
            try store.hasManifest(digest: manifestDigest),
            "R10: after PUT, hasManifest must be true without full decrypt of chunks"
        )
    }

    private static func manifest(raw: Data, seed: String) throws -> (Data, String) {
        let chunks = [
            try ArchiveChunkReference(
                ordinal: 0,
                rawSHA256: ArchiveV2Hash.sha256(raw),
                rawByteCount: Int64(raw.count)
            ),
        ]
        let body = try ArchiveSourceManifest(
            captureID: ArchiveV2Hash.sha256(Data("capture-\(seed)".utf8)),
            machineID: UUID().uuidString.lowercased(),
            source: "codex",
            locator: "/private/m14-test/\(seed).jsonl",
            sessionID: "m14-session",
            capturedAt: "2026-07-18T00:00:00.000Z",
            generation: try ArchiveSourceGeneration(
                device: 1,
                inode: 42,
                size: Int64(raw.count),
                mtimeNs: 1,
                ctimeNs: 1,
                mode: 0o100600
            ),
            wholeSourceSHA256: ArchiveV2Hash.sha256(raw),
            rawByteCount: Int64(raw.count),
            chunks: chunks,
            replayLayout: try ArchiveReplayLayout(
                strategy: .singleFile,
                relativePaths: ["m14-test/\(seed).jsonl"]
            )
        )
        let bytes = try ArchiveCanonicalJSON.encode(body)
        return (bytes, ArchiveV2Hash.sha256(bytes))
    }
}
