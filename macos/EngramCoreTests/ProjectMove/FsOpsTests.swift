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

    // MARK: - Destination parent provision (dirfd-pinned mkdirat/unlinkat)

    func testDestinationParentProvisionCreatesOnlyMissingAndRemovesEmpty_repro() throws {
        let leaf = tmpRoot.appendingPathComponent("a/b/c/proj").path
        let parent = (leaf as NSString).deletingLastPathComponent
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent))

        let token = try DestinationParentProvision.ensure(destinationPath: leaf)
        XCTAssertGreaterThan(token.ownedCountForTests, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: parent))

        // Second ensure: existing segments not owned.
        let again = try DestinationParentProvision.ensure(destinationPath: leaf)
        XCTAssertEqual(again.ownedCountForTests, 0, "EEXIST/existing must not be owned")
        again.release()
        XCTAssertTrue(again.isClosedForTests)

        token.cleanup()
        XCTAssertTrue(token.isClosedForTests)
        XCTAssertEqual(token.ownedCountForTests, 0)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: parent),
            "unlinkat must remove empty shells we created"
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
        let token = try DestinationParentProvision.ensure(destinationPath: nested)
        XCTAssertEqual(token.ownedCountForTests, 1, "only new-child is owned")

        let child = preexisting.appendingPathComponent("new-child")
        try "other".write(
            to: child.appendingPathComponent("other.txt"),
            atomically: true,
            encoding: .utf8
        )
        token.cleanup()
        XCTAssertTrue(token.isClosedForTests)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: child.path),
            "unlinkat must not remove non-empty dir (ENOTEMPTY)"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: preexisting.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: preexisting.appendingPathComponent("marker.txt").path
            )
        )
    }

    func testDestinationParentProvisionEEXISTDoesNotClaimOwnership_repro() throws {
        let foreignParent = tmpRoot.appendingPathComponent("foreign-empty", isDirectory: true)
        try FileManager.default.createDirectory(at: foreignParent, withIntermediateDirectories: true)
        let leaf = foreignParent.appendingPathComponent("proj").path

        let token = try DestinationParentProvision.ensure(destinationPath: leaf)
        XCTAssertEqual(token.ownedCountForTests, 0, "pre-existing parent not owned")
        token.cleanup()
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: foreignParent.path),
            "foreign empty parent must survive when we never owned it"
        )
        XCTAssertTrue(token.isClosedForTests)
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

    /// Ancestor rename + symlink rebind must not redirect cleanup into the replacement tree.
    func testDestinationParentProvisionCleanupSurvivesAncestorRebind_repro() throws {
        let originalRoot = tmpRoot.appendingPathComponent("orig-root", isDirectory: true)
        let leaf = originalRoot.appendingPathComponent("a/b/proj").path
        let ownedDeep = originalRoot.appendingPathComponent("a/b").path

        let token = try DestinationParentProvision.ensure(destinationPath: leaf)
        XCTAssertGreaterThan(token.ownedCountForTests, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ownedDeep))

        // Rebind: rename original tree, put a symlink at the old path to an evil tree.
        let movedRoot = tmpRoot.appendingPathComponent("moved-root", isDirectory: true)
        try FileManager.default.moveItem(at: originalRoot, to: movedRoot)
        let evilRoot = tmpRoot.appendingPathComponent("evil-root", isDirectory: true)
        let evilDeep = evilRoot.appendingPathComponent("a/b", isDirectory: true)
        try FileManager.default.createDirectory(at: evilDeep, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: originalRoot.path,
            withDestinationPath: evilRoot.path
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: evilDeep.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: movedRoot.appendingPathComponent("a/b").path)
        )

        token.cleanup()
        XCTAssertTrue(token.isClosedForTests)
        XCTAssertEqual(token.ownedCountForTests, 0)

        // Pinned unlinkat removes empties in the original (moved) tree only.
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: movedRoot.appendingPathComponent("a/b").path),
            "owned empty dir in original tree must be removed via pinned FD"
        )
        // Replacement tree must be untouched.
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: evilDeep.path),
            "replacement tree must not be deleted after ancestor rebind"
        )
    }

    func testDestinationParentProvisionReleaseClosesWithoutDelete_repro() throws {
        let leaf = tmpRoot.appendingPathComponent("keep-on-success/x/proj").path
        let parent = (leaf as NSString).deletingLastPathComponent
        let token = try DestinationParentProvision.ensure(destinationPath: leaf)
        XCTAssertGreaterThan(token.ownedCountForTests, 0)
        token.release()
        XCTAssertTrue(token.isClosedForTests)
        XCTAssertEqual(token.ownedCountForTests, 0)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: parent),
            "release keeps created parents"
        )
    }

    func testDestinationParentProvisionSourceUsesDirfdSemantics_repro() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ProjectMove/
            .deletingLastPathComponent() // EngramCoreTests/
            .deletingLastPathComponent() // macos/
            .appendingPathComponent("EngramCoreWrite/ProjectMove/FsOps.swift")
        let source = try String(contentsOf: root, encoding: .utf8)
        guard let mark = source.range(of: "public enum DestinationParentProvision") else {
            return XCTFail("DestinationParentProvision not found")
        }
        // Include DestinationParentToken + provision (~6k).
        let start = source.index(mark.lowerBound, offsetBy: -800, limitedBy: source.startIndex)
            ?? source.startIndex
        let segment = String(source[start...].prefix(6000))
        XCTAssertTrue(segment.contains("mkdirat"), "must create with mkdirat")
        XCTAssertTrue(segment.contains("unlinkat"), "must tear down with unlinkat")
        XCTAssertTrue(segment.contains("openat"), "must walk with openat")
        XCTAssertTrue(segment.contains("F_DUPFD_CLOEXEC") || segment.contains("fcntl"),
                      "must pin parent FD")
        XCTAssertFalse(
            segment.contains("FileManager.default.createDirectory"),
            "must not use FileManager createDirectory"
        )
        XCTAssertFalse(
            segment.contains(".removeItem(at")
                || segment.range(of: #"\.removeItem\s*\(\s*at(Path)?:"#, options: .regularExpression) != nil,
            "must not call recursive removeItem"
        )
        // Path-based cleanup is forbidden (TOCTOU under ancestor rebind).
        XCTAssertFalse(
            segment.range(of: #"Darwin\.rmdir\s*\("#, options: .regularExpression) != nil,
            "must not path-based rmdir for cleanup"
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

    func testCaseOnlyRenameIsNonConflictOnAPFS_repro() throws {
        let src = tmpRoot.appendingPathComponent("MyProject")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "note".write(to: src.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        let dst = tmpRoot.appendingPathComponent("myproject")
        let caseInsensitive = FileManager.default.fileExists(atPath: dst.path)
            && SafeMoveDir.isCaseOnlySamePath(src: src.path, dst: dst.path)
        guard caseInsensitive else {
            throw XCTSkip("volume is case-sensitive; case-only rename non-conflict not applicable")
        }
        let result = try SafeMoveDir.run(src: src.path, dst: dst.path)
        XCTAssertEqual(result.strategy, .rename)
        XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent("readme.txt"), encoding: .utf8), "note")
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
