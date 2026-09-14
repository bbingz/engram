import Darwin
import Foundation
import XCTest
@testable import EngramCoreRead

final class RuntimeRoleSettingsTests: XCTestCase {
    private var root: URL!
    private var settings: URL { root.appendingPathComponent("settings.json") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-role-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testMissingFileAndMissingKeyRetainLocalWithoutCreatingSettings() throws {
        XCTAssertEqual(RuntimeRoleSettings.load(at: settings), .local)
        XCTAssertFalse(FileManager.default.fileExists(atPath: settings.path))
        XCTAssertEqual(RuntimeRoleSettings.load(at: root.appendingPathComponent("missing/settings.json")), .local)
        try write(#"{"unrelated":true}"#)
        XCTAssertEqual(RuntimeRoleSettings.load(at: settings), .local)
    }

    func testOnlyFourExactPersistedRolesAreAccepted_repro() throws {
        for (value, expected) in [("local", EngramRuntimeRole.local), ("collector", .collector), ("index", .index), ("replica", .replica)] {
            try write("{\"runtimeRole\":\"\(value)\",\"unrelated\":true}")
            XCTAssertEqual(RuntimeRoleSettings.load(at: settings), expected, value)
        }
    }

    func testExplicitNullWrongTypeAndUnknownRolesFailClosed_repro() throws {
        for value in ["null", "false", "1", "[]", "{}", #""""#, #""LOCAL""#, #"" local""#, #""invalidSettings""#] {
            try write("{\"runtimeRole\":\(value)}")
            XCTAssertEqual(RuntimeRoleSettings.load(at: settings), .invalidSettings, value)
        }
    }

    func testCorruptAndNonObjectDocumentsFailClosed_repro() throws {
        for document in ["", "{", "[]", "null", #""collector""#, #"{"runtimeRole":"collector"}trailing"#] {
            try write(document)
            XCTAssertEqual(RuntimeRoleSettings.load(at: settings), .invalidSettings, document)
        }
    }

    func testUnsafePermissionsFailClosedWithoutRepair_repro() throws {
        try write(#"{"runtimeRole":"collector"}"#)
        for mode in [mode_t(0o644), 0o400, 0o000] {
            XCTAssertEqual(chmod(settings.path, mode), 0)
            XCTAssertEqual(RuntimeRoleSettings.load(at: settings), .invalidSettings)
            var info = stat()
            XCTAssertEqual(lstat(settings.path, &info), 0)
            XCTAssertEqual(info.st_mode & 0o777, mode)
        }
    }

    func testSymlinksHardlinksAndNonRegularFilesFailClosed_repro() throws {
        let target = root.appendingPathComponent("target.json")
        try Data(#"{"runtimeRole":"collector"}"#.utf8).write(to: target)
        XCTAssertEqual(chmod(target.path, 0o600), 0)
        try FileManager.default.createSymbolicLink(at: settings, withDestinationURL: target)
        XCTAssertEqual(RuntimeRoleSettings.load(at: settings), .invalidSettings)
        try FileManager.default.removeItem(at: settings)
        try FileManager.default.linkItem(at: target, to: settings)
        XCTAssertEqual(RuntimeRoleSettings.load(at: settings), .invalidSettings)
        try FileManager.default.removeItem(at: settings)
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: false)
        XCTAssertEqual(RuntimeRoleSettings.load(at: settings), .invalidSettings)
        try FileManager.default.removeItem(at: settings)
        XCTAssertEqual(mkfifo(settings.path, 0o600), 0)
        XCTAssertEqual(RuntimeRoleSettings.load(at: settings), .invalidSettings)
    }

    func testDanglingSymlinkAndUnreadableParentAreNotMissingFile_repro() throws {
        let parent = root.appendingPathComponent("unsafe", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: root.appendingPathComponent("absent"))
        XCTAssertEqual(RuntimeRoleSettings.load(at: parent.appendingPathComponent("settings.json")), .invalidSettings)
        try FileManager.default.removeItem(at: parent)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(parent.path, 0o000), 0)
        defer { _ = chmod(parent.path, 0o700) }
        XCTAssertEqual(RuntimeRoleSettings.load(at: parent.appendingPathComponent("settings.json")), .invalidSettings)
    }

    func testSettingsReadIsBoundedAtOneMiB_repro() throws {
        let prefix = #"{"runtimeRole":"collector","padding":""#
        let suffix = #""}"#
        let document = prefix + String(repeating: "x", count: RuntimeRoleSettings.maximumBytes - prefix.utf8.count - suffix.utf8.count) + suffix
        try write(document)
        XCTAssertEqual(RuntimeRoleSettings.load(at: settings), .collector)
        try write(document + " ")
        XCTAssertEqual(RuntimeRoleSettings.load(at: settings), .invalidSettings)
    }

    func testRolePermissionsDoNotAuthorizeCollectorReplicaOrInvalidIndexing() {
        for role in [EngramRuntimeRole.collector, .replica, .invalidSettings] {
            XCTAssertFalse(role.allowsLocalIndex)
            XCTAssertTrue(role.unavailableMessage.contains("runtimeRole"))
        }
        XCTAssertTrue(EngramRuntimeRole.local.allowsLocalIndex)
        XCTAssertTrue(EngramRuntimeRole.index.allowsLocalIndex)
    }

    private func write(_ text: String) throws {
        try Data(text.utf8).write(to: settings)
        XCTAssertEqual(chmod(settings.path, 0o600), 0)
    }
}
