import CryptoKit
import Foundation
@testable import EngramRemoteServerCore
import XCTest

final class ArchiveConfigTests: XCTestCase {
    private let keyData = Data(repeating: 0x5a, count: 32)

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
            XCTAssertEqual(archive.bearerToken, "legacy-token")
            XCTAssertEqual(keyBytes(archive.atRestKey), keyData)
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
        ]) { _, new in new }
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
