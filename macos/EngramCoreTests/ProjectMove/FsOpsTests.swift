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
