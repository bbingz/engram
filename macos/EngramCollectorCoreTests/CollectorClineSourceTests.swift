import Darwin
import Foundation
import XCTest
@testable import EngramCollectorCore

final class CollectorClineSourceTests: XCTestCase {
    func testUIPrimaryTakesPrecedenceAndOwnsBothNamedFiles() throws {
        let f = try ClineFixture(); defer { f.remove() }
        try f.write(ui: "{}", legacy: "[]")
        let observed = try CollectorClineSource.observe(rootPath: f.root.path, primaryRelative: f.ui)
        XCTAssertEqual(observed.snapshot.entrypointRelativePath, f.ui)
        XCTAssertEqual(observed.snapshot.present.map(\.relativePath), [f.ui])
        XCTAssertEqual(observed.snapshot.absentRelativePaths, [])
        XCTAssertEqual(observed.generation, observed.snapshot.present[0].generation)
        XCTAssertEqual(try CollectorClineSource.owningPrimary(rootPath: f.root.path, dirtyRelative: f.ui), f.ui)
        XCTAssertEqual(try CollectorClineSource.owningPrimary(rootPath: f.root.path, dirtyRelative: f.legacy), f.ui)
        XCTAssertNoThrow(try CollectorClineSource.requireValidSnapshot(observed.snapshot, entrypoint: f.ui))
    }

    func testLegacyPrimaryRequiresAbsentUIProof() throws {
        let f = try ClineFixture(); defer { f.remove() }
        try f.write(legacy: "[]")
        let observed = try CollectorClineSource.observe(rootPath: f.root.path, primaryRelative: f.legacy)
        XCTAssertEqual(observed.snapshot.entrypointRelativePath, f.legacy)
        XCTAssertEqual(observed.snapshot.present.map(\.relativePath), [f.legacy])
        XCTAssertEqual(observed.snapshot.absentRelativePaths, [f.ui])
        XCTAssertEqual(try CollectorClineSource.owningPrimary(rootPath: f.root.path, dirtyRelative: f.ui), f.legacy)
        XCTAssertEqual(try CollectorClineSource.owningPrimary(rootPath: f.root.path, dirtyRelative: f.legacy), f.legacy)
        XCTAssertThrowsError(try CollectorClineSource.observe(rootPath: f.root.path, primaryRelative: f.ui))
        XCTAssertNoThrow(try CollectorClineSource.requireValidSnapshot(observed.snapshot, entrypoint: f.legacy))
    }

    func testUIArrivalInvalidatesLegacyChoice() throws {
        let f = try ClineFixture(); defer { f.remove() }
        try f.write(legacy: "[]")
        XCTAssertEqual(try CollectorClineSource.observe(rootPath: f.root.path, primaryRelative: f.legacy)
            .snapshot.absentRelativePaths, [f.ui])
        try f.write(ui: "{}")
        XCTAssertThrowsError(try CollectorClineSource.observe(rootPath: f.root.path, primaryRelative: f.legacy))
        let observed = try CollectorClineSource.observe(rootPath: f.root.path, primaryRelative: f.ui)
        XCTAssertEqual(observed.snapshot.present.map(\.relativePath), [f.ui])
        XCTAssertEqual(observed.snapshot.absentRelativePaths, [])
        XCTAssertEqual(try CollectorClineSource.owningPrimary(rootPath: f.root.path, dirtyRelative: f.legacy), f.ui)
    }

    func testSymlinkOrUnsafeUIFailsWithoutLegacyFallbackAndReleasesFDs() throws {
        let f = try ClineFixture(); defer { f.remove() }
        try f.write(legacy: "[]")
        let outside = f.base.appendingPathComponent("outside.json")
        try Data("{}".utf8).write(to: outside)
        XCTAssertEqual(chmod(outside.path, 0o600), 0)
        try FileManager.default.createSymbolicLink(at: f.uiURL, withDestinationURL: outside)
        let before = try fixtureDescriptors(under: f.base)
        XCTAssertThrowsError(try CollectorClineSource.observe(rootPath: f.root.path, primaryRelative: f.ui))
        XCTAssertThrowsError(try CollectorClineSource.observe(rootPath: f.root.path, primaryRelative: f.legacy))
        XCTAssertThrowsError(try CollectorClineSource.owningPrimary(rootPath: f.root.path, dirtyRelative: f.legacy))
        XCTAssertEqual(try fixtureDescriptors(under: f.base), before)
        try FileManager.default.removeItem(at: f.uiURL)
        XCTAssertEqual(mkfifo(f.uiURL.path, 0o600), 0)
        XCTAssertThrowsError(try CollectorClineSource.observe(rootPath: f.root.path, primaryRelative: f.legacy))
        XCTAssertEqual(try fixtureDescriptors(under: f.base), before)
        try FileManager.default.removeItem(at: f.uiURL)
        try f.write(ui: "{}")
        _ = try CollectorClineSource.observe(rootPath: f.root.path, primaryRelative: f.ui)
        XCTAssertEqual(try fixtureDescriptors(under: f.base), before)
    }

    func testSelectedPrimaryRequiresExactlyTwoNonHiddenComponents() {
        XCTAssertTrue(CollectorClineSource.isSelectedPrimary(rootPath: "", components: ["task", "ui_messages.json"]))
        XCTAssertTrue(CollectorClineSource.isSelectedPrimary(rootPath: "", components: ["task", "claude_messages.json"]))
        XCTAssertFalse(CollectorClineSource.isSelectedPrimary(rootPath: "", components: ["task", "notes.json"]))
        XCTAssertFalse(CollectorClineSource.isSelectedPrimary(rootPath: "", components: [".hidden", "ui_messages.json"]))
        XCTAssertFalse(CollectorClineSource.isSelectedPrimary(rootPath: "", components: ["task", ".ui_messages.json"]))
        XCTAssertFalse(CollectorClineSource.isSelectedPrimary(rootPath: "", components: ["task", "nested", "ui_messages.json"]))
        XCTAssertFalse(CollectorClineSource.isSelectedPrimary(rootPath: "", components: ["ui_messages.json"]))
        XCTAssertFalse(CollectorClineSource.isSelectedPrimary(rootPath: "", components: ["..", "ui_messages.json"]))
    }
}

private struct ClineFixture {
    let base: URL
    let root: URL
    let task = "task-one"
    var ui: String { task + "/" + CollectorClineSource.uiName }
    var legacy: String { task + "/" + CollectorClineSource.legacyName }
    var taskURL: URL { root.appendingPathComponent(task) }
    var uiURL: URL { root.appendingPathComponent(ui) }
    var legacyURL: URL { root.appendingPathComponent(legacy) }

    init() throws {
        if let expectedHome = ProcessInfo.processInfo.environment["ENGRAM_DEMO_EXPECTED_HOME"] {
            guard FileManager.default.homeDirectoryForCurrentUser.path == expectedHome else {
                throw CollectorPublicationWorkerError.invalidCapture
            }
        }
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        base = checkout.appendingPathComponent(".engram-cline-test-\(UUID().uuidString)")
        root = base.appendingPathComponent("tasks")
        try FileManager.default.createDirectory(at: taskURL, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    func write(ui: String? = nil, legacy: String? = nil) throws {
        if let ui {
            try Data(ui.utf8).write(to: uiURL)
            XCTAssertEqual(chmod(uiURL.path, 0o600), 0)
        }
        if let legacy {
            try Data(legacy.utf8).write(to: legacyURL)
            XCTAssertEqual(chmod(legacyURL.path, 0o600), 0)
        }
    }

    func remove() { try? FileManager.default.removeItem(at: base) }
}

private func fixtureDescriptors(under root: URL) throws -> [Int32] {
    try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").compactMap { name -> Int32? in
        guard let descriptor = Int32(name) else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let result = buffer.withUnsafeMutableBufferPointer { fcntl(descriptor, F_GETPATH, $0.baseAddress!) }
        guard result == 0 else { return nil }
        let path = String(cString: buffer)
        return path == root.path || path.hasPrefix(root.path + "/") ? descriptor : nil
    }.sorted()
}
