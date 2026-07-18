import XCTest
@testable import EngramCoreRead

/// SEC-L3: product subdirs under `~/.engram` must be mode 0700, not umask 0755.
final class EngramUserDataDirectoryTests: XCTestCase {
    func testEnsureSecureSubdirectoryCreatesOwnerOnlyMode_repro() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-user-data-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let exports = try EngramUserDataDirectory.ensureSecureSubdirectory(
            "exports",
            homeDirectory: home
        )
        let attrs = try FileManager.default.attributesOfItem(atPath: exports.path)
        let mode = attrs[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700, "SEC-L3: exports must be 0700, got \(String(describing: mode))")

        let root = home.appendingPathComponent(".engram", isDirectory: true)
        let rootMode = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int
        XCTAssertEqual(rootMode, 0o700)
    }

    func testSecureExistingProductSubdirectoriesRepairsLooseModes_repro() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-user-data-repair-\(UUID().uuidString)", isDirectory: true)
        let cache = home
            .appendingPathComponent(".engram", isDirectory: true)
            .appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cache.path)
        defer { try? FileManager.default.removeItem(at: home) }

        EngramUserDataDirectory.secureExistingProductSubdirectories(homeDirectory: home)

        let mode = try FileManager.default.attributesOfItem(atPath: cache.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700, "SEC-L3: repair must tighten cache from 0755 to 0700")
    }
}
