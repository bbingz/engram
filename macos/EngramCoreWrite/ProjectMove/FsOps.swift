// macos/EngramCoreWrite/ProjectMove/FsOps.swift
// Mirrors src/core/project-move/fs-ops.ts (Node parity baseline).
//
// `safeMoveDir` performs an atomic same-volume rename, falling back to
// copy-then-delete on EXDEV. Preserves file mode (rename is metadata-only)
// and refuses to follow symlinks at the source by default. Partial-copy
// failures clean up the temp dir so `dst` is never half-populated.
//
// Test injection: callers can substitute `FsOpsHooks` to simulate EXDEV
// or copy failure without needing two real volumes.
import Darwin
import Foundation

public enum FsOpsError: Error, Equatable {
    case posix(code: Int32, message: String)
    case symlinkSource(path: String)
    case destinationExists(path: String)
    case partialCopyCleanupFailed(tempPath: String, original: String)

    public var localizedMessage: String {
        switch self {
        case .posix(_, let message): return message
        case .symlinkSource(let path):
            return "safeMoveDir: source is a symlink (\(path)); refusing to move the target"
        case .destinationExists(let path):
            return "safeMoveDir: destination already exists (\(path)); refusing to overwrite"
        case .partialCopyCleanupFailed(let temp, let original):
            return "safeMoveDir: cleanup of \(temp) failed after copy error: \(original)"
        }
    }

    public var isExdev: Bool {
        if case .posix(let code, _) = self { return code == EXDEV }
        return false
    }

    public var isEnoent: Bool {
        if case .posix(let code, _) = self { return code == ENOENT }
        return false
    }
}

public struct MoveResult: Equatable, Sendable {
    public enum Strategy: String, Equatable, Sendable {
        case rename
        case copyThenDelete = "copy-then-delete"
    }
    public let strategy: Strategy
    public let bytesCopied: Int64

    public init(strategy: Strategy, bytesCopied: Int64) {
        self.strategy = strategy
        self.bytesCopied = bytesCopied
    }
}

public struct MoveOptions {
    /// Move what a symlink source points at instead of refusing. Default
    /// false — we don't want to chase symlinks during a project move.
    public var followSymlinks: Bool
    /// Override partial-copy cleanup (test hook). Default removes the temp
    /// directory recursively.
    public var onPartialCopyFailure: ((_ tempDst: String, _ error: Error) -> Void)?

    public init(
        followSymlinks: Bool = false,
        onPartialCopyFailure: ((String, Error) -> Void)? = nil
    ) {
        self.followSymlinks = followSymlinks
        self.onPartialCopyFailure = onPartialCopyFailure
    }
}

public struct FsOpsHooks {
    /// Rename `src` → `dst`. Throws `.posix(EXDEV, …)` on cross-volume
    /// renames so the caller can fall back to copy+delete.
    public var rename: (_ src: String, _ dst: String) throws -> Void
    /// Recursively copy a directory tree. Returns total bytes of regular
    /// files copied (best-effort; 0 if the size couldn't be measured).
    public var copyDirectory: (_ src: String, _ dst: String) throws -> Int64
    /// Recursively remove a path. Idempotent: missing paths are not errors.
    public var removeItem: (_ path: String) throws -> Void
    /// Whether `path` exists at all (file, dir, or symlink).
    public var fileExists: (_ path: String) -> Bool
    /// Whether `path` is itself a symlink (does NOT follow). Throws on
    /// missing source so callers see ENOENT instead of "false".
    public var isSymlink: (_ path: String) throws -> Bool

    public static let production = FsOpsHooks(
        rename: { src, dst in
            if Darwin.rename(src, dst) != 0 {
                let code = errno
                throw FsOpsError.posix(code: code, message: String(cString: strerror(code)))
            }
        },
        copyDirectory: { src, dst in
            try FileManager.default.copyItem(atPath: src, toPath: dst)
            return Self.directorySize(at: dst)
        },
        removeItem: { path in
            do {
                try FileManager.default.removeItem(atPath: path)
            } catch CocoaError.fileNoSuchFile {
                return
            }
        },
        fileExists: { path in
            FileManager.default.fileExists(atPath: path)
        },
        isSymlink: { path in
            var info = stat()
            if lstat(path, &info) != 0 {
                let code = errno
                throw FsOpsError.posix(code: code, message: String(cString: strerror(code)))
            }
            return (info.st_mode & S_IFMT) == S_IFLNK
        }
    )

    public init(
        rename: @escaping (String, String) throws -> Void,
        copyDirectory: @escaping (String, String) throws -> Int64,
        removeItem: @escaping (String) throws -> Void,
        fileExists: @escaping (String) -> Bool,
        isSymlink: @escaping (String) throws -> Bool
    ) {
        self.rename = rename
        self.copyDirectory = copyDirectory
        self.removeItem = removeItem
        self.fileExists = fileExists
        self.isSymlink = isSymlink
    }

    private static func directorySize(at path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys)
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let resources = try? fileURL.resourceValues(forKeys: keys),
               resources.isRegularFile == true,
               let size = resources.fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}

public enum SafeMoveDir {
    /// Move `src` to `dst`. Same-volume → atomic rename; cross-volume →
    /// recursive copy to a sibling temp + atomic rename + delete source.
    public static func run(
        src: String,
        dst: String,
        options: MoveOptions = MoveOptions(),
        hooks: FsOpsHooks = .production
    ) throws -> MoveResult {
        // 1. Preflight: refuse symlinks, refuse existing dst.
        let srcIsSymlink = try hooks.isSymlink(src)
        if srcIsSymlink && !options.followSymlinks {
            throw FsOpsError.symlinkSource(path: src)
        }
        if hooks.fileExists(dst) {
            throw FsOpsError.destinationExists(path: dst)
        }

        // 2. Fast path: same-volume rename.
        do {
            try hooks.rename(src, dst)
            return MoveResult(strategy: .rename, bytesCopied: 0)
        } catch let err as FsOpsError where err.isExdev {
            // fall through to cross-volume fallback
        }

        // 3. Cross-volume: copy to a sibling temp, then atomic rename into
        //    place. Partial-copy cleanup only touches the temp; `dst` is
        //    never clobbered.
        let dstParent = (dst as NSString).deletingLastPathComponent
        let tempDst = (dstParent as NSString)
            .appendingPathComponent(".engram-move-tmp-\(getpid())-\(Self.randomHex(3))")

        var bytesCopied: Int64 = 0
        do {
            bytesCopied = try hooks.copyDirectory(src, tempDst)
        } catch {
            if let custom = options.onPartialCopyFailure {
                custom(tempDst, error)
            } else {
                _ = try? hooks.removeItem(tempDst)
            }
            throw error
        }

        do {
            try hooks.rename(tempDst, dst)
        } catch {
            _ = try? hooks.removeItem(tempDst)
            throw error
        }

        try hooks.removeItem(src)
        return MoveResult(strategy: .copyThenDelete, bytesCopied: bytesCopied)
    }

    private static func randomHex(_ bytes: Int) -> String {
        var raw = [UInt8](repeating: 0, count: bytes)
        arc4random_buf(&raw, bytes)
        return raw.map { String(format: "%02x", $0) }.joined()
    }
}
