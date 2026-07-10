// macos/EngramCoreTests/ProjectMove/FsOpsTests.swift
// Mirrors tests/core/project-move/fs-ops.test.ts (Node parity baseline).
//
// Same-volume rename is exercised against real /tmp; EXDEV cross-volume
// fallback uses `FsOpsHooks` injection to simulate cross-device errors
// without needing two real filesystems.
import Darwin
import Foundation
import XCTest
@testable import EngramCoreWrite

final class FsOpsTests: XCTestCase {
    private var tmpRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("engram-fsops-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmpRoot {
            try? FileManager.default.removeItem(at: tmpRoot)
        }
        try super.tearDownWithError()
    }

    // MARK: - Destination parent provision (POSIX mkdir/rmdir)

    func testDestinationParentProvisionCreatesOnlyMissingAndRemovesEmpty_repro() throws {
        let leaf = tmpRoot.appendingPathComponent("a/b/c/proj").path
        let parent = (leaf as NSString).deletingLastPathComponent
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent))

        let created = try DestinationParentProvision.ensure(destinationPath: leaf)
        XCTAssertFalse(created.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: parent))
        // Deepest first for teardown.
        XCTAssertEqual(created.first, parent)

        // Second ensure: EEXIST paths are not owned (empty created list).
        let again = try DestinationParentProvision.ensure(destinationPath: leaf)
        XCTAssertTrue(again.isEmpty, "EEXIST must not be recorded as created-by-us")

        DestinationParentProvision.removeEmptyCreated(created)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: parent),
            "rmdir must remove empty shells we created"
        )
    }

    func testDestinationParentProvisionNeverDeletesPreexistingOrNonEmpty_repro() throws {
        let preexisting = tmpRoot.appendingPathComponent("keep", isDirectory: true)
        try FileManager.default.createDirectory(at: preexisting, withIntermediateDirectories: true)
        try "marker".write(
            to: preexisting.appendingPathComponent("marker.txt"),
            atomically: true,
            encoding: .utf8
        )
        let nested = preexisting.appendingPathComponent("new-child/proj").path
        let created = try DestinationParentProvision.ensure(destinationPath: nested)
        XCTAssertFalse(created.contains(preexisting.path))
        XCTAssertTrue(created.contains(preexisting.appendingPathComponent("new-child").path))

        // Concurrent content before teardown: rmdir must fail safely (ENOTEMPTY).
        let child = preexisting.appendingPathComponent("new-child")
        try "other".write(
            to: child.appendingPathComponent("other.txt"),
            atomically: true,
            encoding: .utf8
        )
        DestinationParentProvision.removeEmptyCreated(created)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: child.path),
            "rmdir must not remove non-empty dir (ENOTEMPTY)"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: preexisting.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: preexisting.appendingPathComponent("marker.txt").path
            )
        )
    }

    func testDestinationParentProvisionEEXISTDoesNotClaimOwnership_repro() throws {
        // Simulate "another process created the empty dir first": pre-create,
        // then ensure must not list it as created-by-us, and teardown of that
        // empty list must not remove the foreign empty directory.
        let foreignParent = tmpRoot.appendingPathComponent("foreign-empty", isDirectory: true)
        try FileManager.default.createDirectory(at: foreignParent, withIntermediateDirectories: true)
        let leaf = foreignParent.appendingPathComponent("proj").path

        let created = try DestinationParentProvision.ensure(destinationPath: leaf)
        XCTAssertFalse(
            created.contains(foreignParent.path),
            "EEXIST empty dir must not be attributed to this call"
        )
        DestinationParentProvision.removeEmptyCreated(created)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: foreignParent.path),
            "foreign empty parent must survive when we never owned it"
        )
    }

    func testDestinationParentProvisionRejectsFileAtSegment_repro() throws {
        let filePath = tmpRoot.appendingPathComponent("not-a-dir")
        try "x".write(to: filePath, atomically: true, encoding: .utf8)
        let leaf = filePath.appendingPathComponent("child/proj").path
        XCTAssertThrowsError(try DestinationParentProvision.ensure(destinationPath: leaf)) { error in
            guard case DestinationParentProvision.Error.existsButNotDirectory = error else {
                return XCTFail("expected existsButNotDirectory, got \(error)")
            }
        }
    }

    func testDestinationParentProvisionSourceUsesPosixAtomicSemantics_repro() throws {
        // Source-level contract: mkdir/rmdir only — never FileManager races.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ProjectMove/
            .deletingLastPathComponent() // EngramCoreTests/
            .deletingLastPathComponent() // macos/
            .appendingPathComponent("EngramCoreWrite/ProjectMove/FsOps.swift")
        let source = try String(contentsOf: root, encoding: .utf8)
        guard let mark = source.range(of: "public enum DestinationParentProvision") else {
            return XCTFail("DestinationParentProvision not found")
        }
        let body = String(source[mark.lowerBound...])
        // Bound roughly to next top-level after the enum (best-effort).
        let segment = String(body.prefix(3500))
        XCTAssertTrue(segment.contains("Darwin.mkdir"), "must create with mkdir")
        XCTAssertTrue(segment.contains("Darwin.rmdir"), "must tear down with rmdir")
        XCTAssertTrue(segment.contains("EEXIST"), "must handle EEXIST without ownership")
        XCTAssertFalse(
            segment.contains("FileManager.default.createDirectory"),
            "must not use FileManager createDirectory"
        )
        XCTAssertFalse(
            segment.contains("removeItem"),
            "must not use recursive removeItem"
        )
        XCTAssertFalse(
            segment.contains("contentsOfDirectory"),
            "must not TOCTOU empty-check before delete"
        )
    }

    // MARK: - rename fast path

    func testRenamesDirectoryOnSameVolume() throws {
        let src = tmpRoot.appendingPathComponent("proj")
        let dst = tmpRoot.appendingPathComponent("renamed")
        try FileManager.default.createDirectory(
            at: src.appendingPathComponent("sub"),
            withIntermediateDirectories: true
        )
        try "hello".write(
            to: src.appendingPathComponent("file.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "world".write(
            to: src.appendingPathComponent("sub/nested.txt"),
            atomically: true,
            encoding: .utf8
        )

        let result = try SafeMoveDir.run(src: src.path, dst: dst.path)

        XCTAssertEqual(result.strategy, .rename)
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path))
        XCTAssertEqual(
            try String(contentsOf: dst.appendingPathComponent("file.txt"), encoding: .utf8),
            "hello"
        )
        XCTAssertEqual(
            try String(contentsOf: dst.appendingPathComponent("sub/nested.txt"), encoding: .utf8),
            "world"
        )
    }

    func testPreservesFileModeOnRenamePath() throws {
        let src = tmpRoot.appendingPathComponent("proj")
        let dst = tmpRoot.appendingPathComponent("renamed")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let exec = src.appendingPathComponent("exec.sh")
        try "#!/bin/sh\n".write(to: exec, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: exec.path
        )

        _ = try SafeMoveDir.run(src: src.path, dst: dst.path)

        let attrs = try FileManager.default.attributesOfItem(
            atPath: dst.appendingPathComponent("exec.sh").path
        )
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(mode & 0o777, 0o755)
    }

    func testRefusesToOverwriteExistingDestination() throws {
        let src = tmpRoot.appendingPathComponent("proj")
        let dst = tmpRoot.appendingPathComponent("renamed")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)

        XCTAssertThrowsError(try SafeMoveDir.run(src: src.path, dst: dst.path)) { err in
            guard let fsErr = err as? FsOpsError, case .destinationExists = fsErr else {
                return XCTFail("expected .destinationExists, got \(err)")
            }
        }
        // src must still exist
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path))
    }

    func testRefusesToMoveSymlinkSource() throws {
        let real = tmpRoot.appendingPathComponent("real")
        let link = tmpRoot.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        do {
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        } catch {
            throw XCTSkip("symlink permission denied: \(error.localizedDescription)")
        }

        XCTAssertThrowsError(
            try SafeMoveDir.run(src: link.path, dst: tmpRoot.appendingPathComponent("dest").path)
        ) { err in
            guard let fsErr = err as? FsOpsError, case .symlinkSource = fsErr else {
                return XCTFail("expected .symlinkSource, got \(err)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: real.path))
    }

    func testFollowSymlinksAllowsMovingSymlinkSource() throws {
        let real = tmpRoot.appendingPathComponent("real")
        let link = tmpRoot.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try "content".write(
            to: real.appendingPathComponent("x.txt"),
            atomically: true,
            encoding: .utf8
        )
        do {
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        } catch {
            throw XCTSkip("symlink permission denied: \(error.localizedDescription)")
        }

        let dest = tmpRoot.appendingPathComponent("dest")
        let result = try SafeMoveDir.run(
            src: link.path,
            dst: dest.path,
            options: MoveOptions(followSymlinks: true)
        )
        XCTAssertEqual(result.strategy, .rename)
    }

    func testEnoentOnNonExistentSource() {
        let missing = tmpRoot.appendingPathComponent("nope").path
        let dst = tmpRoot.appendingPathComponent("dst").path
        XCTAssertThrowsError(try SafeMoveDir.run(src: missing, dst: dst)) { err in
            guard let fsErr = err as? FsOpsError, fsErr.isEnoent else {
                return XCTFail("expected ENOENT, got \(err)")
            }
        }
    }

    // MARK: - EXDEV cross-volume fallback (mocked)

    func testFallsBackToCopyDeleteOnExdev() throws {
        let src = tmpRoot.appendingPathComponent("src")
        let dst = tmpRoot.appendingPathComponent("dst")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "hello".write(
            to: src.appendingPathComponent("file.txt"),
            atomically: true,
            encoding: .utf8
        )

        var renameCalls = 0
        let hooks = FsOpsHooks(
            rename: { srcPath, dstPath in
                renameCalls += 1
                if renameCalls == 1 {
                    throw FsOpsError.posix(code: EXDEV, message: "EXDEV simulated")
                }
                // Second call (tempDst → dst): real rename.
                if Darwin.rename(srcPath, dstPath) != 0 {
                    let code = errno
                    throw FsOpsError.posix(code: code, message: String(cString: strerror(code)))
                }
            },
            copyDirectory: FsOpsHooks.production.copyDirectory,
            removeItem: FsOpsHooks.production.removeItem,
            fileExists: FsOpsHooks.production.fileExists,
            isSymlink: FsOpsHooks.production.isSymlink
        )

        let result = try SafeMoveDir.run(src: src.path, dst: dst.path, hooks: hooks)

        XCTAssertEqual(result.strategy, .copyThenDelete)
        XCTAssertGreaterThanOrEqual(renameCalls, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path))
        XCTAssertEqual(
            try String(contentsOf: dst.appendingPathComponent("file.txt"), encoding: .utf8),
            "hello"
        )
    }

    func testSourceDeleteFailureAfterTempRenameStillSucceeds() throws {
        // After the temp dir is renamed into `dst`, the move has logically
        // succeeded. If deleting the original `src` then fails, run() must NOT
        // throw — throwing would trigger rollback while BOTH src and dst exist,
        // wedging the migration. `dst` must be populated; `src` may remain as
        // best-effort residual.
        let src = tmpRoot.appendingPathComponent("src")
        let dst = tmpRoot.appendingPathComponent("dst")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "hello".write(
            to: src.appendingPathComponent("file.txt"),
            atomically: true,
            encoding: .utf8
        )

        var renameCalls = 0
        let hooks = FsOpsHooks(
            rename: { srcPath, dstPath in
                renameCalls += 1
                if renameCalls == 1 {
                    throw FsOpsError.posix(code: EXDEV, message: "EXDEV simulated")
                }
                if Darwin.rename(srcPath, dstPath) != 0 {
                    let code = errno
                    throw FsOpsError.posix(code: code, message: String(cString: strerror(code)))
                }
            },
            copyDirectory: FsOpsHooks.production.copyDirectory,
            removeItem: { path in
                // Simulate a source-delete failure (e.g. EPERM) ONLY for `src`;
                // temp cleanup paths still delete normally.
                if path == src.path {
                    throw FsOpsError.posix(code: EPERM, message: "EPERM simulated")
                }
                try FsOpsHooks.production.removeItem(path)
            },
            fileExists: FsOpsHooks.production.fileExists,
            isSymlink: FsOpsHooks.production.isSymlink
        )

        let result = try SafeMoveDir.run(src: src.path, dst: dst.path, hooks: hooks)

        XCTAssertEqual(result.strategy, .copyThenDelete)
        XCTAssertEqual(
            try String(contentsOf: dst.appendingPathComponent("file.txt"), encoding: .utf8),
            "hello",
            "dst must be fully populated after a successful temp-rename"
        )
        // `src` survived the failed delete — acceptable residual, not an error.
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path))
    }

    func testPartialCopyFailureCleansTempLeavesDstUntouched() throws {
        let src = tmpRoot.appendingPathComponent("src")
        let dst = tmpRoot.appendingPathComponent("dst")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "x".write(
            to: src.appendingPathComponent("a.txt"),
            atomically: true,
            encoding: .utf8
        )

        var capturedTempDst: String?
        let hooks = FsOpsHooks(
            rename: { _, _ in
                throw FsOpsError.posix(code: EXDEV, message: "EXDEV mock")
            },
            copyDirectory: { _, tempDst in
                capturedTempDst = tempDst
                throw NSError(
                    domain: "test",
                    code: 28, // ENOSPC
                    userInfo: [NSLocalizedDescriptionKey: "ENOSPC simulated"]
                )
            },
            removeItem: FsOpsHooks.production.removeItem,
            fileExists: FsOpsHooks.production.fileExists,
            isSymlink: FsOpsHooks.production.isSymlink
        )

        XCTAssertThrowsError(try SafeMoveDir.run(src: src.path, dst: dst.path, hooks: hooks)) {
            err in
            XCTAssertTrue(
                err.localizedDescription.contains("ENOSPC"),
                "expected ENOSPC error, got \(err)"
            )
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dst.path),
            "dst must not exist on partial-copy failure"
        )
        if let temp = capturedTempDst {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: temp),
                "tempDst must be cleaned up on partial-copy failure"
            )
        }
        // src must still be intact
        XCTAssertEqual(
            try String(contentsOf: src.appendingPathComponent("a.txt"), encoding: .utf8),
            "x"
        )
    }
}
