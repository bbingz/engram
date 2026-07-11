import CryptoKit
import Foundation
@testable import EngramRemoteServerCore
import XCTest

final class ArchiveConfigTests: XCTestCase {
    private let keyData = Data(repeating: 0x5a, count: 32)
    private let archiveKeyData = Data(repeating: 0xa5, count: 32)

    func testLegacyEnvironmentKeepsArchiveDisabledAndV1FieldsUnchanged() throws {
        let config = try EngramRemoteServerConfig.fromEnvironment([
            "ENGRAM_REMOTE_TOKEN": "legacy-token",
            "ENGRAM_REMOTE_AT_REST_KEY": keyData.base64EncodedString(),
            "ENGRAM_REMOTE_STORE": "/tmp/legacy-v1-store",
            "ENGRAM_REMOTE_HOST": "203.0.113.10",
            "ENGRAM_REMOTE_PORT": "9988",
        ])

        XCTAssertNil(config.archiveV2)
        XCTAssertEqual(config.storeRoot.path, "/tmp/legacy-v1-store")
        XCTAssertEqual(config.host, "203.0.113.10")
        XCTAssertEqual(config.port, 9988)
        XCTAssertEqual(config.bearerToken, "legacy-token")
        XCTAssertEqual(keyBytes(config.atRestKey), keyData)
    }

    func testEnabledArchiveRequiresServerIDAndAbsoluteRoot() {
        let base = environment(host: "127.0.0.1")

        XCTAssertThrowsError(
            try EngramRemoteServerConfig.fromEnvironment(
                base.merging(["ENGRAM_REMOTE_ARCHIVE_ENABLED": "1"]) { _, new in new }
            )
        ) { error in
            guard case EngramRemoteServerConfig.ConfigError.missingArchiveServerID = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        XCTAssertThrowsError(
            try EngramRemoteServerConfig.fromEnvironment(
                base.merging([
                    "ENGRAM_REMOTE_ARCHIVE_ENABLED": "1",
                    "ENGRAM_REMOTE_ARCHIVE_SERVER_ID": "hq",
                ]) { _, new in new }
            )
        ) { error in
            guard case EngramRemoteServerConfig.ConfigError.missingArchiveRoot = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        XCTAssertThrowsError(
            try EngramRemoteServerConfig.fromEnvironment(
                base.merging([
                    "ENGRAM_REMOTE_ARCHIVE_ENABLED": "1",
                    "ENGRAM_REMOTE_ARCHIVE_SERVER_ID": "hq",
                    "ENGRAM_REMOTE_ARCHIVE_ROOT": "relative/archive",
                ]) { _, new in new }
            )
        ) { error in
            guard case EngramRemoteServerConfig.ConfigError.archiveRootMustBeAbsolute = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testEnabledArchiveAcceptsOnlyLiteralLoopbackOrTailscaleBindAddresses() throws {
        let accepted = [
            "127.0.0.1",
            "127.42.0.9",
            "::1",
            "100.64.0.1",
            "100.127.255.254",
            "fd7a:115c:a1e0::1",
            "fd7a:115c:a1e0:ffff::abcd",
        ]
        for host in accepted {
            let config = try EngramRemoteServerConfig.fromEnvironment(
                enabledEnvironment(host: host)
            )
            let archive = try XCTUnwrap(config.archiveV2)
            XCTAssertEqual(archive.serverID, "hq")
            XCTAssertEqual(archive.root.path, "/tmp/engram-archive-v2")
            XCTAssertEqual(archive.bearerToken, "archive-token")
            XCTAssertEqual(keyBytes(archive.atRestKey), archiveKeyData)
        }

        let rejected = [
            "0.0.0.0",
            "::",
            "8.8.8.8",
            "93.184.216.34",
            "10.0.0.1",
            "172.16.0.1",
            "192.168.1.10",
            "169.254.1.1",
            "fe80::1",
            "localhost",
            "macmini-hq",
            "macmini-hq.tailnet.ts.net",
        ]
        for host in rejected {
            XCTAssertThrowsError(
                try EngramRemoteServerConfig.fromEnvironment(enabledEnvironment(host: host)),
                "expected \(host) to be rejected"
            ) { error in
                guard case EngramRemoteServerConfig.ConfigError.archiveBindAddressRejected = error else {
                    return XCTFail("unexpected error for \(host): \(error)")
                }
            }
        }
    }

    func testEnabledArchiveRequiresIndependentCredentials() throws {
        var missingToken = enabledEnvironment(host: "127.0.0.1")
        missingToken.removeValue(forKey: "ENGRAM_REMOTE_ARCHIVE_TOKEN")
        XCTAssertThrowsError(try EngramRemoteServerConfig.fromEnvironment(missingToken)) { error in
            guard case EngramRemoteServerConfig.ConfigError.missingArchiveToken = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(
                String(describing: error),
                "ENGRAM_REMOTE_ARCHIVE_TOKEN is required when archive v2 is enabled."
            )
        }

        var missingKey = enabledEnvironment(host: "127.0.0.1")
        missingKey.removeValue(forKey: "ENGRAM_REMOTE_ARCHIVE_AT_REST_KEY")
        XCTAssertThrowsError(try EngramRemoteServerConfig.fromEnvironment(missingKey)) { error in
            guard case EngramRemoteServerConfig.ConfigError.missingArchiveKey = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(
                String(describing: error),
                "ENGRAM_REMOTE_ARCHIVE_AT_REST_KEY is required when archive v2 is enabled (base64 of 32 random bytes)."
            )
        }

        var badKey = enabledEnvironment(host: "127.0.0.1")
        badKey["ENGRAM_REMOTE_ARCHIVE_AT_REST_KEY"] = "not-a-32-byte-base64-key"
        XCTAssertThrowsError(try EngramRemoteServerConfig.fromEnvironment(badKey)) { error in
            guard case EngramRemoteServerConfig.ConfigError.badArchiveKey = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(
                String(describing: error),
                "ENGRAM_REMOTE_ARCHIVE_AT_REST_KEY must be base64 of exactly 32 bytes."
            )
        }

        var reusedToken = enabledEnvironment(host: "127.0.0.1")
        reusedToken["ENGRAM_REMOTE_ARCHIVE_TOKEN"] = reusedToken["ENGRAM_REMOTE_TOKEN"]
        XCTAssertThrowsError(try EngramRemoteServerConfig.fromEnvironment(reusedToken)) { error in
            guard case EngramRemoteServerConfig.ConfigError.archiveCredentialsMustBeDistinct = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(
                String(describing: error),
                "Archive v2 token and at-rest key must be distinct from legacy v1 credentials."
            )
        }

        var reusedKey = enabledEnvironment(host: "127.0.0.1")
        reusedKey["ENGRAM_REMOTE_ARCHIVE_AT_REST_KEY"] = reusedKey["ENGRAM_REMOTE_AT_REST_KEY"]
        XCTAssertThrowsError(try EngramRemoteServerConfig.fromEnvironment(reusedKey)) { error in
            guard case EngramRemoteServerConfig.ConfigError.archiveCredentialsMustBeDistinct = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(
                String(describing: error),
                "Archive v2 token and at-rest key must be distinct from legacy v1 credentials."
            )
        }

        let config = try EngramRemoteServerConfig.fromEnvironment(
            enabledEnvironment(host: "127.0.0.1")
        )
        let archive = try XCTUnwrap(config.archiveV2)
        XCTAssertEqual(archive.bearerToken, "archive-token")
        XCTAssertEqual(keyBytes(archive.atRestKey), archiveKeyData)
    }

    func testProgrammaticAppRejectsSharedArchiveCredentials() throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }

        let reusedToken = programmaticConfig(
            base: base,
            archiveToken: "legacy-token",
            archiveKeyData: archiveKeyData
        )
        XCTAssertThrowsError(try EngramRemoteServerApp(config: reusedToken)) { error in
            guard case EngramRemoteServerConfig.ConfigError.archiveCredentialsMustBeDistinct = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(
                String(describing: error),
                "Archive v2 token and at-rest key must be distinct from legacy v1 credentials."
            )
        }

        let reusedKey = programmaticConfig(
            base: base,
            archiveToken: "archive-token",
            archiveKeyData: keyData
        )
        XCTAssertThrowsError(try EngramRemoteServerApp(config: reusedKey)) { error in
            guard case EngramRemoteServerConfig.ConfigError.archiveCredentialsMustBeDistinct = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(
                String(describing: error),
                "Archive v2 token and at-rest key must be distinct from legacy v1 credentials."
            )
        }
    }

    func testProgrammaticAppRejectsOverlappingStoreRootsBeforeConstruction() throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }

        let untouchedLegacy = base.appendingPathComponent("untouched", isDirectory: true)
        let untouchedArchive = untouchedLegacy.appendingPathComponent("archive", isDirectory: true)
        XCTAssertThrowsError(
            try EngramRemoteServerApp(
                config: programmaticConfig(
                    base: base,
                    legacyRoot: untouchedLegacy,
                    archiveRoot: untouchedArchive
                )
            )
        ) { error in
            guard case EngramRemoteServerConfig.ConfigError.storeRootsMustBeDisjoint = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(
                String(describing: error),
                "Legacy v1 and archive v2 store roots must be disjoint."
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: untouchedLegacy.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: untouchedArchive.path))

        let legacy = base.appendingPathComponent("legacy", isDirectory: true)
        let child = legacy.appendingPathComponent("archive", isDirectory: true)
        for (v1Root, v2Root) in [
            (legacy, legacy),
            (legacy, child),
            (child, legacy),
            (legacy, legacy.appendingPathComponent("../legacy", isDirectory: true)),
        ] {
            XCTAssertThrowsError(
                try EngramRemoteServerApp(
                    config: programmaticConfig(
                        base: base,
                        legacyRoot: v1Root,
                        archiveRoot: v2Root
                    )
                )
            ) { error in
                guard case EngramRemoteServerConfig.ConfigError.storeRootsMustBeDisjoint = error else {
                    return XCTFail("unexpected error: \(error)")
                }
                XCTAssertEqual(
                    String(describing: error),
                    "Legacy v1 and archive v2 store roots must be disjoint."
                )
            }
        }

        let real = base.appendingPathComponent("real", isDirectory: true)
        let alias = base.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        XCTAssertThrowsError(
            try EngramRemoteServerApp(
                config: programmaticConfig(
                    base: base,
                    legacyRoot: real,
                    archiveRoot: alias
                )
            )
        ) { error in
            guard case EngramRemoteServerConfig.ConfigError.storeRootsMustBeDisjoint = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(
                String(describing: error),
                "Legacy v1 and archive v2 store roots must be disjoint."
            )
        }
    }

    func testProgrammaticAppAllowsSiblingPrefixStoreRoots() throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }

        XCTAssertNoThrow(
            try EngramRemoteServerApp(
                config: programmaticConfig(
                    base: base,
                    legacyRoot: base.appendingPathComponent("store", isDirectory: true),
                    archiveRoot: base.appendingPathComponent("store-v2", isDirectory: true)
                )
            )
        )
    }

    func testProgrammaticAppUsesTargetVolumeCaseSensitivityForRootIsolation() throws {
        let base = temporaryDirectory()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let values = try base.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        let supportsCaseSensitiveNames = try XCTUnwrap(values.volumeSupportsCaseSensitiveNames)
        let caseOnlySameA = base.appendingPathComponent("SameCase", isDirectory: true)
        let caseOnlySameB = base.appendingPathComponent("samecase", isDirectory: true)
        let caseOnlyAncestorA = base.appendingPathComponent("AncestorCase", isDirectory: true)
        let caseOnlyAncestorB = base
            .appendingPathComponent("ancestorcase", isDirectory: true)
            .appendingPathComponent("archive", isDirectory: true)

        if supportsCaseSensitiveNames {
            XCTAssertNoThrow(
                try EngramRemoteServerApp(
                    config: programmaticConfig(
                        base: base,
                        legacyRoot: caseOnlySameA,
                        archiveRoot: caseOnlySameB
                    )
                )
            )
            XCTAssertNoThrow(
                try EngramRemoteServerApp(
                    config: programmaticConfig(
                        base: base,
                        legacyRoot: caseOnlyAncestorA,
                        archiveRoot: caseOnlyAncestorB
                    )
                )
            )
        } else {
            for (v1Root, v2Root) in [
                (caseOnlySameA, caseOnlySameB),
                (caseOnlyAncestorA, caseOnlyAncestorB),
            ] {
                XCTAssertThrowsError(
                    try EngramRemoteServerApp(
                        config: programmaticConfig(
                            base: base,
                            legacyRoot: v1Root,
                            archiveRoot: v2Root
                        )
                    )
                ) { error in
                    guard case EngramRemoteServerConfig.ConfigError.storeRootsMustBeDisjoint = error else {
                        return XCTFail("unexpected error: \(error)")
                    }
                }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: caseOnlySameA.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: caseOnlyAncestorA.path))
        }
    }

    func testProgrammaticAppCanonicalizesUnicodeRootComponents() throws {
        let base = temporaryDirectory()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let precomposed = base.appendingPathComponent("caf\u{00E9}", isDirectory: true)
        let decomposed = base.appendingPathComponent("cafe\u{0301}", isDirectory: true)
        XCTAssertThrowsError(
            try EngramRemoteServerApp(
                config: programmaticConfig(
                    base: base,
                    legacyRoot: precomposed,
                    archiveRoot: decomposed
                )
            )
        ) { error in
            guard case EngramRemoteServerConfig.ConfigError.storeRootsMustBeDisjoint = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: precomposed.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: decomposed.path))
    }

    func testProgrammaticAppRejectsMissingLeafBelowExistingSymlinkAncestor() throws {
        let base = temporaryDirectory()
        let real = base.appendingPathComponent("real", isDirectory: true)
        let alias = base.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: base) }

        let realChild = real.appendingPathComponent("missing-child", isDirectory: true)
        let aliasChild = alias.appendingPathComponent("missing-child", isDirectory: true)
        XCTAssertThrowsError(
            try EngramRemoteServerApp(
                config: programmaticConfig(
                    base: base,
                    legacyRoot: realChild,
                    archiveRoot: aliasChild
                )
            )
        ) { error in
            guard case EngramRemoteServerConfig.ConfigError.storeRootsMustBeDisjoint = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: realChild.path))
    }

    func testProgrammaticAppRejectsMissingLeafThroughSystemTmpAlias() throws {
        let tmpAlias = URL(fileURLWithPath: "/tmp", isDirectory: true)
        let privateTmp = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        guard tmpAlias.resolvingSymlinksInPath().standardizedFileURL == privateTmp.standardizedFileURL else {
            throw XCTSkip("this macOS volume does not expose /tmp as /private/tmp")
        }

        let leaf = "engram-archive-root-alias-\(UUID().uuidString)"
        let aliasRoot = tmpAlias.appendingPathComponent(leaf, isDirectory: true)
        let physicalRoot = privateTmp.appendingPathComponent(leaf, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: aliasRoot)
            try? FileManager.default.removeItem(at: physicalRoot)
        }

        XCTAssertThrowsError(
            try EngramRemoteServerApp(
                config: programmaticConfig(
                    base: privateTmp,
                    legacyRoot: physicalRoot,
                    archiveRoot: aliasRoot
                )
            )
        ) { error in
            guard case EngramRemoteServerConfig.ConfigError.storeRootsMustBeDisjoint = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: physicalRoot.path))
    }

    func testProgrammaticAppRejectsDanglingRelativeRootAliasBeforeLegacyCreation() throws {
        let base = temporaryDirectory()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let real = base.appendingPathComponent("not-created-yet", isDirectory: true)
        let alias = base.appendingPathComponent("dangling-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            atPath: alias.path,
            withDestinationPath: "not-created-yet"
        )

        XCTAssertThrowsError(
            try EngramRemoteServerApp(
                config: programmaticConfig(
                    base: base,
                    legacyRoot: real,
                    archiveRoot: alias
                )
            )
        ) { error in
            guard case EngramRemoteServerConfig.ConfigError.storeRootsMustBeDisjoint = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: real.path))
        XCTAssertNotNil(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path))
    }

    func testProgrammaticAppRejectsRelativeSymlinkChainWithMissingLeaf() throws {
        let base = temporaryDirectory()
        let real = base.appendingPathComponent("chain-real", isDirectory: true)
        let first = base.appendingPathComponent("chain-first", isDirectory: true)
        let second = base.appendingPathComponent("chain-second", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: first.path,
            withDestinationPath: "chain-real"
        )
        try FileManager.default.createSymbolicLink(
            atPath: second.path,
            withDestinationPath: "chain-first"
        )
        defer { try? FileManager.default.removeItem(at: base) }

        let realChild = real.appendingPathComponent("missing-child", isDirectory: true)
        let chainedChild = second.appendingPathComponent("missing-child", isDirectory: true)
        XCTAssertThrowsError(
            try EngramRemoteServerApp(
                config: programmaticConfig(
                    base: base,
                    legacyRoot: realChild,
                    archiveRoot: chainedChild
                )
            )
        ) { error in
            guard case EngramRemoteServerConfig.ConfigError.storeRootsMustBeDisjoint = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: realChild.path))
    }

    func testProgrammaticAppRejectsSymlinkCycleWithoutCreatingRoots() throws {
        let base = temporaryDirectory()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let first = base.appendingPathComponent("cycle-first", isDirectory: true)
        let second = base.appendingPathComponent("cycle-second", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            atPath: first.path,
            withDestinationPath: "cycle-second"
        )
        try FileManager.default.createSymbolicLink(
            atPath: second.path,
            withDestinationPath: "cycle-first"
        )
        let untouched = base.appendingPathComponent("untouched", isDirectory: true)

        XCTAssertThrowsError(
            try EngramRemoteServerApp(
                config: programmaticConfig(
                    base: base,
                    legacyRoot: first.appendingPathComponent("child", isDirectory: true),
                    archiveRoot: untouched
                )
            )
        ) { error in
            guard case EngramRemoteServerConfig.ConfigError.storeRootsMustBeDisjoint = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: untouched.path))
    }

    func testArchiveServerIDIsAStableSafeToken() {
        for serverID in ["hq/../../escape", "hq one", "hq\"quoted", ".", "..", "hq:one"] {
            var env = enabledEnvironment(host: "127.0.0.1")
            env["ENGRAM_REMOTE_ARCHIVE_SERVER_ID"] = serverID
            XCTAssertThrowsError(
                try EngramRemoteServerConfig.fromEnvironment(env),
                "expected unsafe server ID \(serverID) to be rejected"
            ) { error in
                guard case EngramRemoteServerConfig.ConfigError.invalidArchiveServerID = error else {
                    return XCTFail("unexpected error for \(serverID): \(error)")
                }
            }
        }

        for serverID in ["hq", "m1-primary", "archive.server_2"] {
            var env = enabledEnvironment(host: "127.0.0.1")
            env["ENGRAM_REMOTE_ARCHIVE_SERVER_ID"] = serverID
            XCTAssertNoThrow(try EngramRemoteServerConfig.fromEnvironment(env))
        }
    }

    func testRemoteServerCoreIncludesOnlyPureArchiveWireSources() throws {
        let project = try String(contentsOf: projectYML(), encoding: .utf8)
        let coreStart = try XCTUnwrap(project.range(of: "  EngramRemoteServerCore:\n"))
        let executableStart = try XCTUnwrap(
            project.range(of: "  EngramRemoteServer:\n", range: coreStart.upperBound..<project.endIndex)
        )
        let target = String(project[coreStart.lowerBound..<executableStart.lowerBound])

        XCTAssertTrue(target.contains("Shared/EngramCore/ArchiveV2/ArchiveHash.swift"))
        XCTAssertTrue(target.contains("Shared/EngramCore/ArchiveV2/ArchiveCanonicalJSON.swift"))
        XCTAssertTrue(target.contains("Shared/EngramCore/ArchiveV2/ArchiveModels.swift"))
        XCTAssertFalse(target.contains("Shared/EngramCore/ArchiveV2\n"))
        XCTAssertFalse(target.contains("ArchiveSourceDescriptor.swift"))
        XCTAssertFalse(target.contains("target: EngramCoreRead"))
        XCTAssertFalse(target.contains("target: EngramCoreWrite"))
    }

    private func environment(host: String) -> [String: String] {
        [
            "ENGRAM_REMOTE_TOKEN": "legacy-token",
            "ENGRAM_REMOTE_AT_REST_KEY": keyData.base64EncodedString(),
            "ENGRAM_REMOTE_STORE": "/tmp/legacy-v1-store",
            "ENGRAM_REMOTE_HOST": host,
        ]
    }

    private func enabledEnvironment(host: String) -> [String: String] {
        environment(host: host).merging([
            "ENGRAM_REMOTE_ARCHIVE_ENABLED": "1",
            "ENGRAM_REMOTE_ARCHIVE_SERVER_ID": "hq",
            "ENGRAM_REMOTE_ARCHIVE_ROOT": "/tmp/engram-archive-v2",
            "ENGRAM_REMOTE_ARCHIVE_TOKEN": "archive-token",
            "ENGRAM_REMOTE_ARCHIVE_AT_REST_KEY": archiveKeyData.base64EncodedString(),
        ]) { _, new in new }
    }

    private func programmaticConfig(
        base: URL,
        legacyRoot: URL? = nil,
        archiveRoot: URL? = nil,
        archiveToken: String = "archive-token",
        archiveKeyData: Data? = nil
    ) -> EngramRemoteServerConfig {
        let v1Root = legacyRoot ?? base.appendingPathComponent("legacy", isDirectory: true)
        let v2Root = archiveRoot ?? base.appendingPathComponent("archive", isDirectory: true)
        return EngramRemoteServerConfig(
            host: "127.0.0.1",
            port: 0,
            storeRoot: v1Root,
            bearerToken: "legacy-token",
            atRestKey: SymmetricKey(data: keyData),
            archiveV2: EngramRemoteArchiveConfig(
                serverID: "hq",
                root: v2Root,
                bearerToken: archiveToken,
                atRestKey: SymmetricKey(data: archiveKeyData ?? self.archiveKeyData)
            )
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-archive-config-\(UUID().uuidString)", isDirectory: true)
    }

    private func keyBytes(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    private func projectYML() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("project.yml")
    }
}
