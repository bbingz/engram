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
    /// True when `src` and `dst` resolve to the same inode (case-only rename
    /// on a case-insensitive volume). Missing paths are not same-path.
    public static func isCaseOnlySamePath(src: String, dst: String) -> Bool {
        guard let srcReal = realpathSafe(src), let dstReal = realpathSafe(dst) else {
            return false
        }
        return srcReal == dstReal
    }

    private static func realpathSafe(_ path: String) -> String? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buf) != nil else { return nil }
        return String(cString: buf)
    }

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
            // M13: case-only rename on case-insensitive APFS — same inode is
            // not a third-party collision.
            if !isCaseOnlySamePath(src: src, dst: dst) {
                throw FsOpsError.destinationExists(path: dst)
            }
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

        // `dst` is now fully populated — the move has logically succeeded.
        // A failure to delete the original `src` must NOT throw: throwing here
        // would trigger compensation/rollback while BOTH `src` and `dst` exist,
        // which then fails its own "destination exists" preflight and wedges
        // the migration. Treat a residual `src` as best-effort cleanup instead.
        _ = try? hooks.removeItem(src)
        return MoveResult(strategy: .copyThenDelete, bytesCopied: bytesCopied)
    }

    private static func randomHex(_ bytes: Int) -> String {
        var raw = [UInt8](repeating: 0, count: bytes)
        arc4random_buf(&raw, bytes)
        return raw.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Destination parent provision (dirfd-pinned, compensatable)

/// macOS/Darwin `AT_REMOVEDIR` for `unlinkat` (empty-directory only).
/// Defined explicitly so Swift does not need a platform module import dance.
private let engramATRemovedir: Int32 = 0x0080

/// Pinned ownership token for destination-parent directories created by
/// `DestinationParentProvision.ensure`.
///
/// Owned entries store a **dup'd parent dirfd + basename**, never a re-parsed
/// path. Cleanup uses `unlinkat(parentFD, name, AT_REMOVEDIR)` so ancestor
/// rename/symlink rebinding cannot redirect deletion into another tree.
public final class DestinationParentToken: @unchecked Sendable {
    fileprivate struct OwnedEntry {
        /// Dup'd O_DIRECTORY fd of the parent that held `name` at creation.
        let parentFD: Int32
        /// Single path component (no slashes).
        let name: String
    }

    private let lock = NSLock()
    /// Shallow→deep creation order; cleanup walks reversed (deepest first).
    private var owned: [OwnedEntry] = []
    private var closed = false

    fileprivate init(owned: [OwnedEntry]) {
        self.owned = owned
    }

    /// Test seam: number of mkdirat-owned segments still pinned.
    public var ownedCountForTests: Int {
        lock.lock(); defer { lock.unlock() }
        return owned.count
    }

    /// Test seam: whether all parent FDs have been closed.
    public var isClosedForTests: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    /// Failure/cancel path: remove empty owned dirs deepest-first, then close FDs.
    public func cleanup() {
        lock.lock()
        let entries = owned
        owned = []
        let alreadyClosed = closed
        closed = true
        lock.unlock()
        // Deepest first.
        for entry in entries.reversed() {
            _ = entry.name.withCString { cName in
                unlinkat(entry.parentFD, cName, engramATRemovedir)
            }
            // ENOTEMPTY / races fail safely — never escalate to removeItem.
            if !alreadyClosed {
                close(entry.parentFD)
            }
        }
    }

    /// Success path: close pinned FDs without deleting directories.
    public func release() {
        lock.lock()
        let entries = owned
        owned = []
        let alreadyClosed = closed
        closed = true
        lock.unlock()
        guard !alreadyClosed else { return }
        for entry in entries {
            close(entry.parentFD)
        }
    }

    deinit {
        // Leak-safety only: close FDs; do not delete (token may outlive success).
        lock.lock()
        let entries = owned
        owned = []
        let alreadyClosed = closed
        closed = true
        lock.unlock()
        guard !alreadyClosed else { return }
        for entry in entries {
            close(entry.parentFD)
        }
    }
}

/// Creates missing destination-parent directories with dirfd-pinned ownership.
///
/// - Walk is absolute, symlink-following for *existing* segments (`openat`
///   without `O_NOFOLLOW`) so macOS `/var` → `/private/var` works.
/// - **Ownership** is recorded only when `mkdirat` returns 0, as
///   `(dup(parentFD), basename)` — never a path string.
/// - **Cleanup** uses `unlinkat(AT_REMOVEDIR)` on the pinned parent FD only.
public enum DestinationParentProvision {
    public enum Error: Swift.Error, Equatable, LocalizedError {
        case mkdirFailed(path: String, errno: Int32)
        case existsButNotDirectory(path: String)
        case openFailed(path: String, errno: Int32)

        public var errorDescription: String? {
            switch self {
            case .mkdirFailed(let path, let code):
                return "mkdirat \(path) failed: \(String(cString: strerror(code))) (\(code))"
            case .existsButNotDirectory(let path):
                return "path exists but is not a directory: \(path)"
            case .openFailed(let path, let code):
                return "openat \(path) failed: \(String(cString: strerror(code))) (\(code))"
            }
        }
    }

    private static let openDirFlags: Int32 = O_RDONLY | O_DIRECTORY | O_CLOEXEC

    /// Ensure the parent directory of `destinationPath` exists.
    /// - Returns: a token owning only segments this call created via mkdirat.
    @discardableResult
    public static func ensure(destinationPath: String) throws -> DestinationParentToken {
        let parent = (destinationPath as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != "/", parent != "." else {
            return DestinationParentToken(owned: [])
        }
        return try ensureDirectory(atPath: parent)
    }

    /// Ensure `path` exists as a directory via per-segment openat/mkdirat.
    public static func ensureDirectory(atPath path: String) throws -> DestinationParentToken {
        let absolute = absolutePath(path)
        guard !absolute.isEmpty, absolute != "/", absolute != "." else {
            return DestinationParentToken(owned: [])
        }

        let components = pathComponents(absolute)
        guard !components.isEmpty else {
            return DestinationParentToken(owned: [])
        }

        // Start at filesystem root; openat follows symlinks on existing segments.
        var parentFD = open("/", openDirFlags)
        guard parentFD >= 0 else {
            throw Error.openFailed(path: "/", errno: errno)
        }

        var owned: [DestinationParentToken.OwnedEntry] = []
        var logical = ""
        var transferred = false
        defer {
            if !transferred {
                if parentFD >= 0 {
                    close(parentFD)
                    parentFD = -1
                }
                if !owned.isEmpty {
                    DestinationParentToken(owned: owned).cleanup()
                    owned = []
                }
            }
        }

        for name in components {
            logical += "/" + name
            // Try enter existing directory (follows symlink parents like /var).
            let existing = name.withCString { cName in
                openat(parentFD, cName, openDirFlags)
            }
            if existing >= 0 {
                close(parentFD)
                parentFD = existing
                continue
            }
            let openErr = errno
            if openErr != ENOENT {
                if openErr == ENOTDIR {
                    throw Error.existsButNotDirectory(path: logical)
                }
                throw Error.openFailed(path: logical, errno: openErr)
            }

            // Missing: create under pinned parent FD.
            let mk = name.withCString { cName in
                mkdirat(parentFD, cName, 0o755)
            }
            if mk == 0 {
                // Only mkdirat success claims ownership — pin parent FD + basename.
                let pin = fcntl(parentFD, F_DUPFD_CLOEXEC, 0)
                if pin < 0 {
                    let code = errno
                    _ = name.withCString { cName in
                        unlinkat(parentFD, cName, engramATRemovedir)
                    }
                    throw Error.openFailed(path: logical, errno: code)
                }
                owned.append(.init(parentFD: pin, name: name))
                let child = name.withCString { cName in
                    openat(parentFD, cName, openDirFlags)
                }
                if child < 0 {
                    throw Error.openFailed(path: logical, errno: errno)
                }
                close(parentFD)
                parentFD = child
                continue
            }

            let mkErr = errno
            if mkErr == EEXIST {
                // Concurrent creator — never claim ownership; enter dir.
                let raced = name.withCString { cName in
                    openat(parentFD, cName, openDirFlags)
                }
                if raced < 0 {
                    let code = errno
                    if code == ENOTDIR {
                        throw Error.existsButNotDirectory(path: logical)
                    }
                    throw Error.openFailed(path: logical, errno: code)
                }
                close(parentFD)
                parentFD = raced
                continue
            }

            throw Error.mkdirFailed(path: logical, errno: mkErr)
        }

        // Walk complete: close the leaf walk FD; ownership pins remain in token.
        close(parentFD)
        parentFD = -1
        let token = DestinationParentToken(owned: owned)
        owned = []
        transferred = true
        return token
    }

    private static func absolutePath(_ path: String) -> String {
        if path.hasPrefix("/") {
            return (path as NSString).standardizingPath
        }
        let cwd = FileManager.default.currentDirectoryPath
        return ((cwd as NSString).appendingPathComponent(path) as NSString).standardizingPath
    }

    /// Absolute path components without the root slash (e.g. `/a/b` → `["a","b"]`).
    private static func pathComponents(_ absolute: String) -> [String] {
        absolute.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }
}
