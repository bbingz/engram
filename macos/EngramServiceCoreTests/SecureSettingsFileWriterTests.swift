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

    func testMutateJSONRefusesTruncatedExistingSettings_repro() throws {
        let file = tempDir.appendingPathComponent("settings.json")
        let original = Data(#"{"aiApiKey":"plaintext-secret""#.utf8)
        try original.write(to: file)
        chmod(file.path, 0o600)

        XCTAssertThrowsError(
            try EngramServiceCommandHandler.writeDisabledSourcesForTests(
                source: "codex",
                enabled: false,
                settingsURL: file
            )
        )
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testMutateJSONRefusesSymlinkWithoutTouchingTarget_repro() throws {
        let target = tempDir.appendingPathComponent("outside.json")
        let linked = tempDir.appendingPathComponent("settings.json")
        let original = Data(#"{"disabledSources":[]}"#.utf8)
        try original.write(to: target)
        chmod(target.path, 0o644)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: target)

        XCTAssertThrowsError(
            try SecureSettingsFileWriter.mutateJSON(at: linked) { object in
                object["disabledSources"] = ["codex"]
            }
        )

        var info = stat()
        XCTAssertEqual(lstat(target.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o644)
        XCTAssertEqual(try Data(contentsOf: target), original)
    }

    func testMutateJSONRefusesFIFOWithoutBlocking_repro() throws {
        let fifo = tempDir.appendingPathComponent("settings.json")
        XCTAssertEqual(mkfifo(fifo.path, S_IRUSR | S_IWUSR), 0)

        let started = Date()
        XCTAssertThrowsError(
            try SecureSettingsFileWriter.mutateJSON(at: fifo) { object in
                object["disabledSources"] = ["codex"]
            }
        )
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
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

    func testSettingsFileLockWaitsForChildProcessOwner_repro() throws {
        let file = tempDir.appendingPathComponent("settings.json")
        let child = Process()
        let output = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = [
            "-c",
            "import fcntl,sys,time; f=open(sys.argv[1],'a+'); fcntl.flock(f,fcntl.LOCK_EX); print('locked', flush=True); time.sleep(0.25)",
            file.appendingPathExtension("lock").path,
        ]
        child.standardOutput = output
        try child.run()
        let ready = output.fileHandleForReading.readData(ofLength: 7)
        XCTAssertEqual(String(data: ready, encoding: .utf8), "locked\n")

        let started = Date()
        XCTAssertNoThrow(
            try EngramSettingsFileLock.withExclusiveLock(for: file) {}
        )
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.15)
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)
    }

    func testSettingsFileLockRejectsFIFO_repro() throws {
        let file = tempDir.appendingPathComponent("settings.json")
        let lockPath = file.appendingPathExtension("lock").path
        XCTAssertEqual(mkfifo(lockPath, S_IRUSR | S_IWUSR), 0)

        XCTAssertThrowsError(
            try EngramSettingsFileLock.withExclusiveLock(for: file) {
                XCTFail("operation must not run with a FIFO lock")
            }
        )
    }
}
