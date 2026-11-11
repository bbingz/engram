import Darwin
import Foundation
import XCTest
@testable import EngramCollectorCore

final class CollectorSpoolGCCLITests: XCTestCase {
    func testNativeApplyThenRestoreWithoutCredentials_repro() throws {
        guard let binary = ProcessInfo.processInfo.environment["ENGRAM_COLLECTOR_BINARY"] else { throw XCTSkip("Explicit collector binary required") }
        let f = try GCExecutionFixture(); defer { f.remove() }
        try f.prepare()
        let approval = try f.approval(now: Int64(Date().timeIntervalSince1970))
        let file = f.base.appendingPathComponent("approval.json"), bytes = try approval.bytes()
        try bytes.write(to: file); XCTAssertEqual(chmod(file.path, 0o600), 0)
        f.session = nil; try f.catalog?.close(); f.catalog = nil; try f.owner?.close(); f.owner = nil
        let applied = try f.seed.cli(binary, ["--settings", f.settings.path, "--spool-gc", "--apply", "--approval-file", file.path, "--approve-sha256", ArchiveV2Hash.sha256(bytes)])
        XCTAssertEqual(applied.0, 0, applied.2)
        guard applied.0 == 0 else { return }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.seed.object(GCExecutionFixture.oldText).path))
        let restored = try f.seed.cli(binary, ["--settings", f.settings.path, "--spool-gc", "--restore", approval.runID])
        XCTAssertEqual(restored.0, 0, restored.2)
        XCTAssertEqual(try Data(contentsOf: f.seed.object(GCExecutionFixture.oldText)), Data(GCExecutionFixture.oldText.utf8))
    }

    func testNativeFinalizeAfterIsolatedHoldAndRejectMixedModes_repro() throws {
        guard let binary = ProcessInfo.processInfo.environment["ENGRAM_COLLECTOR_BINARY"] else { throw XCTSkip("Explicit collector binary required") }
        let f = try GCExecutionFixture(); defer { f.remove() }
        try f.prepare()
        let now = Int64(Date().timeIntervalSince1970), past = now - 14 * 86400 - 10
        let approval = try f.approval(now: past)
        try f.session!.apply(approval: approval, settingsURL: f.settings, now: past)
        let ready = try f.approval(action: "finalize", runID: approval.runID, now: now)
        let file = f.base.appendingPathComponent("approval.json"), bytes = try ready.bytes()
        try bytes.write(to: file); XCTAssertEqual(chmod(file.path, 0o600), 0)
        f.session = nil; try f.catalog?.close(); f.catalog = nil; try f.owner?.close(); f.owner = nil
        let invalid = try f.seed.cli(binary, ["--settings", f.settings.path, "--spool-gc", "--apply", "--restore", approval.runID])
        XCTAssertEqual(invalid.0, 64)
        let finalized = try f.seed.cli(binary, ["--settings", f.settings.path, "--spool-gc", "--finalize", approval.runID, "--approval-file", file.path, "--approve-sha256", ArchiveV2Hash.sha256(bytes)])
        XCTAssertEqual(finalized.0, 0, finalized.2)
        guard finalized.0 == 0 else { return }
        let path = try CollectorSpoolGCFiles.quarantine(f.oldDigest, runID: approval.runID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.seed.root.appendingPathComponent(path).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.seed.object(GCExecutionFixture.headText).path))
    }
}
