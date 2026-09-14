import Darwin
import Foundation
import GRDB
import XCTest
@testable import EngramCollectorCore

final class CollectorMachineIdentityReaderTests: XCTestCase {
    private let machineID = "11111111-2222-3333-4444-555555555555"
    private let otherMachineID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-collector-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        root = root.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }

    func testSameProcessWritableSharedMemoryIsRejectedWithoutChangingFiles() throws {
        let databaseURL = root.appendingPathComponent("archive.sqlite")
        let writer = try fixtureDatabase(databaseURL, machineID: otherMachineID, wal: true)
        try writer.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            try db.execute(sql: "UPDATE archive_metadata SET value = ? WHERE key = 'machine_id'", arguments: [machineID])
        }
        try secureFixtureFiles()
        XCTAssertGreaterThan(try Data(contentsOf: URL(fileURLWithPath: databaseURL.path + "-wal")).count, 32)
        let before = try snapshot()

        XCTAssertThrowsError(try CollectorMachineIdentityReader.read(from: databaseURL)) { error in
            XCTAssertEqual(error as? CollectorMachineIdentityError, .writableSharedMemory)
        }
        let after = try snapshot()
        XCTAssertEqual(after, before, snapshotDifferences(before: before, after: after))
        XCTAssertEqual(try writer.read { try String.fetchOne($0, sql: "SELECT value FROM archive_metadata WHERE key = 'machine_id'") }, machineID)
    }

    func testReadsExistingRollbackCatalogAndChecksExplicitIdentity() throws {
        let databaseURL = root.appendingPathComponent("archive.sqlite")
        let writer = try fixtureDatabase(databaseURL, machineID: machineID)
        try secureFixtureFiles()
        let before = try snapshot()
        XCTAssertEqual(try CollectorMachineIdentityReader.read(from: databaseURL, expectedMachineID: machineID), machineID)
        XCTAssertEqual(try snapshot(), before)
        XCTAssertEqual(chmod(databaseURL.path, 0o400), 0)
        let readOnlyBefore = try snapshot()
        XCTAssertEqual(try CollectorMachineIdentityReader.read(from: databaseURL), machineID)
        XCTAssertEqual(try snapshot(), readOnlyBefore)
        withExtendedLifetime(writer) {}
    }

    func testRejectedWALProbeReleasesSharedMemoryReferenceBeforeWriterCloses() throws {
        let databaseURL = root.appendingPathComponent("archive.sqlite")
        let writer = try fixtureDatabase(databaseURL, machineID: machineID, wal: true)
        try secureFixtureFiles()
        let sharedMemoryURL = URL(fileURLWithPath: databaseURL.path + "-shm")
        let resolved = try XCTUnwrap(Darwin.realpath(sharedMemoryURL.path, nil))
        let sharedMemoryPath = String(cString: resolved)
        Darwin.free(resolved)
        XCTAssertGreaterThan(try fixtureDescriptorCount(path: sharedMemoryPath), 0)
        let before = try snapshot()
        XCTAssertThrowsError(try CollectorMachineIdentityReader.read(from: databaseURL)) { error in
            XCTAssertEqual(error as? CollectorMachineIdentityError, .writableSharedMemory)
        }
        let after = try snapshot()
        XCTAssertEqual(after, before, snapshotDifferences(before: before, after: after))
        try writer.close()
        XCTAssertEqual(try fixtureDescriptorCount(path: sharedMemoryPath), 0, "Rejected preflight must not retain the writer's SHM descriptor")
    }

    func testIndependentProcessReadsCommittedWALWithoutChangingAnyFile() throws {
        let environment = ProcessInfo.processInfo.environment
        if let fixturePath = environment["ENGRAM_C1_IDENTITY_FIXTURE"] {
            XCTAssertNotEqual(String(getpid()), environment["ENGRAM_C1_IDENTITY_PARENT_PID"])
            let identity = try CollectorMachineIdentityReader.read(from: URL(fileURLWithPath: fixturePath))
            XCTAssertEqual(identity, machineID)
            let resolved = try XCTUnwrap(Darwin.realpath(fixturePath + "-shm", nil))
            let sharedMemoryPath = String(cString: resolved)
            Darwin.free(resolved)
            XCTAssertEqual(try fixtureDescriptorCount(path: sharedMemoryPath), 0, "Successful reader must release its SHM descriptor")
            print("C1_IDENTITY_PROBE_SUCCESS:\(identity);sqlite=\(String(cString: sqlite3_libversion()))")
            return
        }

        let databaseURL = root.appendingPathComponent("archive.sqlite")
        let writer = try fixtureDatabase(databaseURL, machineID: otherMachineID, wal: true)
        try writer.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            try db.execute(sql: "UPDATE archive_metadata SET value = ? WHERE key = 'machine_id'", arguments: [machineID])
        }
        try secureFixtureFiles()
        XCTAssertGreaterThan(try Data(contentsOf: URL(fileURLWithPath: databaseURL.path + "-wal")).count, 32)
        let before = try snapshot()

        let bundleURL = Bundle(for: Self.self).bundleURL
        let productsPath = bundleURL.deletingLastPathComponent().path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xctest", "-XCTest",
            "EngramCollectorCoreTests.CollectorMachineIdentityReaderTests/testIndependentProcessReadsCommittedWALWithoutChangingAnyFile",
            bundleURL.path,
        ]
        // A failed xctest invocation can dump its environment. Do not inherit
        // unrelated credentials or agent/runtime settings into the probe.
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "DYLD_FRAMEWORK_PATH": productsPath,
            "DYLD_LIBRARY_PATH": productsPath,
            "ENGRAM_C1_IDENTITY_FIXTURE": databaseURL.path,
            "ENGRAM_C1_IDENTITY_PARENT_PID": String(getpid()),
        ]
        for key in ["DEVELOPER_DIR", "CFFIXED_USER_HOME", "TEST_RUNNER_CFFIXED_USER_HOME", "TMPDIR"] {
            if let value = environment[key] { process.environment?[key] = value }
        }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        let outputText = String(decoding: outputData, as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, outputText)
        XCTAssertTrue(outputText.contains("C1_IDENTITY_PROBE_SUCCESS:\(machineID)"), outputText)
        if let marker = outputText.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("C1_IDENTITY_PROBE_SUCCESS:") }) {
            print(marker)
        }
        let after = try snapshot()
        XCTAssertEqual(after, before, snapshotDifferences(before: before, after: after))
        withExtendedLifetime(writer) {}
    }

    func testMissingCatalogDoesNotCreateCatalogOrParentDirectory() throws {
        let databaseURL = root.appendingPathComponent("missing/archive.sqlite")
        let before = try snapshot()
        XCTAssertThrowsError(try CollectorMachineIdentityReader.read(from: databaseURL))
        XCTAssertEqual(try snapshot(), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.deletingLastPathComponent().path))
    }

    func testMissingShadowIsValidatedWithoutCreatingOrChangingAnything() throws {
        let shadow = root.appendingPathComponent("shadow")
        let before = try snapshot()
        XCTAssertNoThrow(try CollectorMachineIdentityReader.verifyShadowIfPresent(at: shadow, machineID: machineID))
        XCTAssertEqual(try snapshot(), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: shadow.path))
    }

    func testExistingShadowIdentityMismatchDoesNotCreateFilesOrRepairPermissions() throws {
        let shadow = root.appendingPathComponent("shadow")
        try FileManager.default.createDirectory(at: shadow, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let writer = try fixtureDatabase(shadow.appendingPathComponent("archive.sqlite"), machineID: otherMachineID)
        XCTAssertEqual(chmod(shadow.appendingPathComponent("archive.sqlite").path, 0o600), 0)
        let before = try snapshot()
        XCTAssertThrowsError(try CollectorMachineIdentityReader.verifyShadowIfPresent(at: shadow, machineID: machineID)) { error in
            XCTAssertEqual(error as? CollectorMachineIdentityError, .identityMismatch(expected: self.machineID, actual: self.otherMachineID))
        }
        XCTAssertEqual(try snapshot(), before)
        XCTAssertEqual(chmod(shadow.path, 0o755), 0)
        let insecureBefore = try snapshot()
        XCTAssertThrowsError(try CollectorMachineIdentityReader.verifyShadowIfPresent(at: shadow, machineID: machineID))
        XCTAssertEqual(try snapshot(), insecureBefore)
        withExtendedLifetime(writer) {}
    }

    func testExistingShadowWithoutCatalogDoesNotReceiveNewIdentity() throws {
        let shadow = root.appendingPathComponent("shadow")
        try FileManager.default.createDirectory(at: shadow, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let before = try snapshot()
        XCTAssertThrowsError(try CollectorMachineIdentityReader.verifyShadowIfPresent(at: shadow, machineID: machineID))
        XCTAssertEqual(try snapshot(), before)
    }

    func testMissingInvalidAndDuplicateIdentityFailClosedWithoutMetadataMigration() throws {
        for value in [nil, "", "not-a-uuid", machineID] as [String?] {
            let directory = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let databaseURL = directory.appendingPathComponent("archive.sqlite")
            let database = try DatabaseQueue(path: databaseURL.path)
            try database.write { db in
                try db.execute(sql: "CREATE TABLE archive_metadata(key TEXT, value TEXT)")
                if let value {
                    try db.execute(sql: "INSERT INTO archive_metadata VALUES ('machine_id', ?)", arguments: [value])
                    if value == machineID {
                        try db.execute(sql: "INSERT INTO archive_metadata VALUES ('machine_id', ?)", arguments: [otherMachineID])
                    }
                }
            }
            XCTAssertEqual(chmod(databaseURL.path, 0o600), 0)
            let before = try snapshot()
            XCTAssertThrowsError(try CollectorMachineIdentityReader.read(from: databaseURL))
            XCTAssertEqual(try snapshot(), before)
            withExtendedLifetime(database) {}
        }
    }

    func testSymlinkHardLinkFIFOAndDirectoryAreRejectedWithoutFollowingThem() throws {
        let databaseURL = root.appendingPathComponent("archive.sqlite")
        let writer = try fixtureDatabase(databaseURL, machineID: machineID)
        try secureFixtureFiles()
        let linked = root.appendingPathComponent("linked.sqlite")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: databaseURL)
        let pipe = root.appendingPathComponent("pipe.sqlite")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        for unsafe in [linked, pipe, root!] {
            XCTAssertThrowsError(try CollectorMachineIdentityReader.read(from: unsafe))
        }
        let hardLink = root.appendingPathComponent("hardlink.sqlite")
        XCTAssertEqual(link(databaseURL.path, hardLink.path), 0)
        XCTAssertThrowsError(try CollectorMachineIdentityReader.read(from: hardLink))
        withExtendedLifetime(writer) {}
    }

    func testClosedWALCatalogDoesNotCreateMissingSidecars() throws {
        let databaseURL = root.appendingPathComponent("archive.sqlite")
        var writer: DatabaseQueue? = try fixtureDatabase(databaseURL, machineID: machineID, wal: true)
        try writer!.writeWithoutTransaction { try $0.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
        try writer!.close()
        writer = nil
        // Sidecar retention differs by SQLite build. Construct the missing-
        // sidecar fixture explicitly after a verified checkpoint and close.
        let wal = URL(fileURLWithPath: databaseURL.path + "-wal")
        if FileManager.default.fileExists(atPath: wal.path) {
            XCTAssertEqual(try Data(contentsOf: wal).count, 0)
            try FileManager.default.removeItem(at: wal)
        }
        let shm = URL(fileURLWithPath: databaseURL.path + "-shm")
        if FileManager.default.fileExists(atPath: shm.path) { try FileManager.default.removeItem(at: shm) }
        try secureFixtureFiles()
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path + "-shm"))
        let before = try snapshot()
        XCTAssertThrowsError(try CollectorMachineIdentityReader.read(from: databaseURL)) { error in
            XCTAssertEqual(error as? CollectorMachineIdentityError, .walSidecarsUnavailable)
        }
        XCTAssertEqual(try snapshot(), before)
    }

    func testOrphanedOrEmptySharedMemoryIsNotInitializedOrAccepted() throws {
        let source = root.appendingPathComponent("archive.sqlite")
        let writer = try fixtureDatabase(source, machineID: machineID, wal: true)
        try secureFixtureFiles()
        for emptySHM in [false, true] {
            let directory = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let clone = directory.appendingPathComponent("archive.sqlite")
            for suffix in ["", "-wal", "-shm"] {
                let bytes = suffix == "-shm" && emptySHM ? Data() : try Data(contentsOf: URL(fileURLWithPath: source.path + suffix))
                let path = clone.path + suffix
                try bytes.write(to: URL(fileURLWithPath: path))
                XCTAssertEqual(chmod(path, 0o600), 0)
            }
            let before = try snapshot()
            XCTAssertThrowsError(try CollectorMachineIdentityReader.read(from: clone)) { error in
                XCTAssertEqual(error as? CollectorMachineIdentityError, .unavailable)
            }
            let after = try snapshot()
            XCTAssertEqual(after, before, snapshotDifferences(before: before, after: after))
        }
        withExtendedLifetime(writer) {}
    }

    private func fixtureDatabase(_ url: URL, machineID: String, wal: Bool = false) throws -> DatabaseQueue {
        var configuration = Configuration()
        if wal {
            configuration.prepareDatabase { db in
                try db.execute(sql: "PRAGMA journal_mode = WAL")
                try db.execute(sql: "PRAGMA wal_autocheckpoint = 0")
            }
        }
        let database = try DatabaseQueue(path: url.path, configuration: configuration)
        try database.write { db in
            try db.execute(sql: "CREATE TABLE archive_metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            try db.execute(sql: "INSERT INTO archive_metadata VALUES ('machine_id', ?)", arguments: [machineID])
        }
        return database
    }

    private func secureFixtureFiles() throws {
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            XCTAssertEqual(chmod(url.path, 0o600), 0)
        }
    }

    private func fixtureDescriptorCount(path: String) throws -> Int {
        // Inspect only this XCTest process's descriptor numbers and count the
        // exact fixture path; never emit other paths or inspect another process.
        try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").reduce(into: 0) { count, entry in
            guard let descriptor = CInt(entry) else { return }
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let result = buffer.withUnsafeMutableBufferPointer { fcntl(descriptor, F_GETPATH, $0.baseAddress!) }
            if result == 0, String(cString: buffer) == path { count += 1 }
        }
    }

    private struct FileSnapshot: Equatable {
        let mode: UInt16
        let bytes: Data?
    }

    private func snapshot() throws -> [String: FileSnapshot] {
        var result: [String: FileSnapshot] = [:]
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        for url in [root!] + enumerator.allObjects.compactMap({ $0 as? URL }) {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw POSIXError(.ENOENT) }
            result[url.path] = FileSnapshot(mode: info.st_mode, bytes: (info.st_mode & S_IFMT) == S_IFREG ? try Data(contentsOf: url) : nil)
        }
        return result
    }

    private func snapshotDifferences(before: [String: FileSnapshot], after: [String: FileSnapshot]) -> String {
        Set(before.keys).union(after.keys).sorted().compactMap { path -> String? in
            guard let old = before[path], let new = after[path] else { return "file set changed" }
            guard old != new else { return nil }
            let oldBytes = old.bytes ?? Data()
            let newBytes = new.bytes ?? Data()
            let offsets = zip(oldBytes, newBytes).enumerated().compactMap { index, pair in
                pair.0 == pair.1 ? nil : "\(index):\(pair.0)->\(pair.1)"
            }
            return "\(URL(fileURLWithPath: path).lastPathComponent): mode \(old.mode)->\(new.mode), bytes \(oldBytes.count)->\(newBytes.count), differences \(offsets.prefix(32).joined(separator: ","))"
        }.joined(separator: "; ")
    }
}
