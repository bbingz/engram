import Darwin
import EngramCoreRead
import Foundation
import XCTest
@testable import EngramServiceCore

/// M15: every service settings create/update uses atomic temp+rename and final POSIX 0600.
final class SecureSettingsFileWriterTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-secure-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        try super.tearDownWithError()
    }

    func testCreateWritesSettingsWithMode0600() throws {
        let file = tempDir.appendingPathComponent(".engram/settings.json")
        let payload = Data(#"{"disabledSources":[]}"#.utf8)

        try SecureSettingsFileWriter.write(payload, to: file)

        var info = stat()
        XCTAssertEqual(lstat(file.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600, "create must end at POSIX 0600")
        XCTAssertEqual(try Data(contentsOf: file), payload)

        var dirInfo = stat()
        XCTAssertEqual(lstat(file.deletingLastPathComponent().path, &dirInfo), 0)
        XCTAssertEqual(dirInfo.st_mode & 0o777, 0o700)
    }

    func testUpdateRepairsBroaderPermissionsTo0600() throws {
        let directory = tempDir.appendingPathComponent(".engram", isDirectory: true)
        let file = directory.appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        try Data(#"{"disabledSources":[]}"#.utf8).write(to: file)
        chmod(directory.path, 0o755)
        chmod(file.path, 0o644)

        let updated = Data(#"{"disabledSources":["codex"]}"#.utf8)
        try SecureSettingsFileWriter.write(updated, to: file)

        var fileInfo = stat()
        var dirInfo = stat()
        XCTAssertEqual(lstat(file.path, &fileInfo), 0)
        XCTAssertEqual(lstat(directory.path, &dirInfo), 0)
        XCTAssertEqual(fileInfo.st_mode & 0o777, 0o600, "update must force final 0600 even when prior mode was broader")
        XCTAssertEqual(dirInfo.st_mode & 0o777, 0o700)
        XCTAssertEqual(try Data(contentsOf: file), updated)
    }

    func testUpdateDisabledSourcesSettingUsesSecureWriterPermissions() throws {
        let file = tempDir.appendingPathComponent("settings.json")
        let seed: [String: Any] = [
            "customSetting": true,
            "disabledSources": [],
            ArchivedDefaultOffSources.settingsMigrationKey: true,
        ]
        let seedData = try JSONSerialization.data(withJSONObject: seed)
        try seedData.write(to: file)
        chmod(file.path, 0o644)

        try EngramServiceCommandHandler.writeDisabledSourcesForTests(
            source: "codex",
            enabled: false,
            settingsURL: file
        )

        var info = stat()
        XCTAssertEqual(lstat(file.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        )
        XCTAssertEqual(object["customSetting"] as? Bool, true)
        XCTAssertEqual(object["disabledSources"] as? [String], ["codex"])
    }

    func testSettingsFileLockSerializesSameProcessCallers() throws {
        let file = tempDir.appendingPathComponent("settings.json")
        let firstEntered = expectation(description: "first entered")
        let releaseFirst = DispatchSemaphore(value: 0)
        let secondEntered = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "engram.settings-lock.test", attributes: .concurrent)

        queue.async {
            try? EngramSettingsFileLock.withExclusiveLock(for: file) {
                firstEntered.fulfill()
                _ = releaseFirst.wait(timeout: .now() + 2)
            }
        }
        wait(for: [firstEntered], timeout: 1)

        queue.async {
            try? EngramSettingsFileLock.withExclusiveLock(for: file) {
                secondEntered.signal()
            }
        }
        XCTAssertEqual(secondEntered.wait(timeout: .now() + 0.05), .timedOut)

        releaseFirst.signal()
        XCTAssertEqual(secondEntered.wait(timeout: .now() + 1), .success)
    }

    func testSettingsFileLockBlocksChildProcessContender() throws {
        let file = tempDir.appendingPathComponent("settings.json")
        let child = Process()
        let output = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = [
            "-c",
            "import fcntl,sys; f=open(sys.argv[1],'a+'); fcntl.flock(f,fcntl.LOCK_EX); print('acquired')",
            file.appendingPathExtension("lock").path,
        ]
        child.standardOutput = output

        try EngramSettingsFileLock.withExclusiveLock(for: file) {
            try child.run()
            usleep(100_000)
            XCTAssertTrue(child.isRunning, "child must remain blocked while parent owns flock")
        }

        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        XCTAssertEqual(text?.trimmingCharacters(in: .whitespacesAndNewlines), "acquired")
    }
}
