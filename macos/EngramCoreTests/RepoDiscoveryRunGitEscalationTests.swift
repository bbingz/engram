import Foundation
import XCTest
import Darwin
@testable import EngramCoreWrite

/// Focused coverage for the runGit timeout-escalation and success-path fixes:
/// a child that ignores SIGTERM must be SIGKILLed so runGit always returns
/// (never blocks forever on ioGroup.wait), and a slow-but-successful run must
/// keep its output instead of being discarded by a wall-clock recheck.
final class RepoDiscoveryRunGitEscalationTests: XCTestCase {
    private func makeFakeGit(_ root: URL, script: String) throws -> (bin: URL, work: URL) {
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let fakeGit = bin.appendingPathComponent("git")
        try script.write(to: fakeGit, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(fakeGit.path, 0o755), 0)
        return (bin, work)
    }

    func testRunGitEscalatesToSigkillWhenChildIgnoresSigterm() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rungit-sigkill-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        // A child that traps SIGTERM and keeps sleeping. SIGTERM alone would
        // never terminate it, so without the SIGKILL escalation runGit would
        // block on ioGroup.wait() until the long sleep finished.
        let (bin, work) = try makeFakeGit(
            root,
            script: """
            #!/bin/sh
            trap '' TERM
            /bin/sleep 30
            """
        )

        let started = Date()
        let output = RepoDiscovery.runGit(
            ["status"],
            cwd: work.path,
            timeoutSeconds: 0.5,
            environment: ["PATH": bin.path]
        )
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertNil(output)
        // 0.5s timeout + 1s SIGTERM grace + 1s SIGKILL grace + slack. Must NOT
        // run for the full 30s sleep.
        XCTAssertLessThan(elapsed, 5.0, "SIGKILL escalation must unblock runGit promptly")
    }

    func testRunGitKeepsOutputForSlowButSuccessfulRun() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rungit-slow-success-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        // Exits 0 well within the timeout but after a small delay, so the dropped
        // post-success elapsed recheck cannot discard a valid result.
        let (bin, work) = try makeFakeGit(
            root,
            script: """
            #!/bin/sh
            /bin/sleep 1
            echo OK
            """
        )

        let output = RepoDiscovery.runGit(
            ["status"],
            cwd: work.path,
            timeoutSeconds: 5,
            environment: ["PATH": bin.path]
        )

        XCTAssertEqual(output?.trimmingCharacters(in: .whitespacesAndNewlines), "OK")
    }

    func testRunGitBoundsSuccessPathDrainWhenGrandchildKeepsPipeOpen() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rungit-success-drain-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        // The parent exits 0 immediately, but the background child inherits the
        // stdout pipe and keeps it open. runGit must not block the indexing loop
        // until that child exits.
        let (bin, work) = try makeFakeGit(
            root,
            script: """
            #!/bin/sh
            /bin/sleep 5 &
            echo OK
            exit 0
            """
        )

        let started = Date()
        let output = RepoDiscovery.runGit(
            ["status"],
            cwd: work.path,
            timeoutSeconds: 1,
            environment: ["PATH": bin.path]
        )
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertNil(output)
        XCTAssertLessThan(elapsed, 3.5, "success-path pipe drain must be bounded")
    }
}
