import CryptoKit
import Darwin
import Foundation

/// Descriptor-relative operations confined to this private, pinned spool.
final class CollectorSpoolGCFiles {
    struct Identity: Codable, Equatable {
        let device: Int64
        let inode: UInt64
        let bytes: Int64
        let allocatedBytes: Int64
    }
    private let root: URL
    private let descriptor: Int32
    private let device: dev_t
    private let inode: ino_t

    init(root: URL) throws {
        self.root = URL(fileURLWithPath: try CollectorMachineIdentityReader.canonicalExistingPath(root))
        descriptor = Darwin.open(self.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CollectorSpoolGCError.unsafePath }
        var info = stat()
        guard fstat(descriptor, &info) == 0, Self.privateDirectory(info) else {
            close(descriptor); throw CollectorSpoolGCError.unsafePath
        }
        device = info.st_dev; inode = info.st_ino
    }
    deinit { close(descriptor) }

    var scopeIdentity: String { "\(device):\(inode)" }

    static func resident(_ digest: String) throws -> String {
        guard ArchiveV2Hash.isValidSHA256(digest) else { throw CollectorSpoolGCError.invalidInput }
        return "capture/objects/sha256/\(digest.prefix(2))/\(digest)"
    }
    static func quarantine(_ digest: String, runID: String) throws -> String {
        guard UUID(uuidString: runID) != nil, ArchiveV2Hash.isValidSHA256(digest) else { throw CollectorSpoolGCError.invalidInput }
        return "capture/quarantine/k5/\(runID)/sha256/\(digest.prefix(2))/\(digest)"
    }

    func verify(_ relative: String, digest: String, bytes: Int64, hash: Bool = true, consume: ((Data) throws -> Void)? = nil) throws -> Identity? {
        let started = ProcessInfo.processInfo.systemUptime
        guard ArchiveV2Hash.isValidSHA256(digest), bytes > 0, bytes <= 256 * 1024 * 1024 * 1024 else { throw CollectorSpoolGCError.invalidInput }
        return try withParent(relative, create: false, missing: nil) { parent, name, validateParents in
            var before = stat()
            guard fstatat(parent, name, &before, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { return nil }
                throw CollectorSpoolGCError.ioFailure
            }
            guard Self.privateFile(before), Int64(before.st_size) == bytes, before.st_dev == device else { throw CollectorSpoolGCError.spoolIntegrityBlocked }
            let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw CollectorSpoolGCError.unsafePath }
            defer { close(fd) }
            var opened = stat()
            guard fstat(fd, &opened) == 0, Self.same(before, opened) else { throw CollectorSpoolGCError.scopeChanged }
            if hash {
                var hasher = SHA256(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
                var total: Int64 = 0
                while true {
                    try Task.checkCancellation()
                    guard ProcessInfo.processInfo.systemUptime - started <= 300 else { throw CollectorSpoolGCError.budgetExceeded }
                    let n = Darwin.read(fd, &buffer, buffer.count)
                    if n < 0 && errno == EINTR { continue }
                    guard n >= 0 else { throw CollectorSpoolGCError.ioFailure }
                    if n == 0 { break }
                    guard Int64(n) <= bytes - total else { throw CollectorSpoolGCError.spoolIntegrityBlocked }
                    let chunk = Data(buffer.prefix(n))
                    try consume?(chunk)
                    total += Int64(n); hasher.update(data: chunk)
                }
                guard total == bytes, hasher.finalize().map({ String(format: "%02x", $0) }).joined() == digest else {
                    throw CollectorSpoolGCError.spoolIntegrityBlocked
                }
            }
            var after = stat(), path = stat()
            guard fstat(fd, &after) == 0, fstatat(parent, name, &path, AT_SYMLINK_NOFOLLOW) == 0,
                  Self.same(before, after), Self.same(before, path) else { throw CollectorSpoolGCError.scopeChanged }
            try validateParents()
            return Identity(device: Int64(before.st_dev), inode: UInt64(before.st_ino), bytes: bytes, allocatedBytes: Int64(before.st_blocks) * 512)
        }
    }

    func move(_ from: String, to: String, digest: String, expected: Identity) throws {
        guard try verify(from, digest: digest, bytes: expected.bytes) == expected else { throw CollectorSpoolGCError.scopeChanged }
        try withParent(from, create: false, missing: (), requireParent: true) { source, sourceName, validateSource in
            try withParent(to, create: true, missing: (), requireParent: true) { destination, destinationName, validateDestination in
                try validateSource(); try validateDestination()
                var sourceInfo = stat()
                guard fstatat(source, sourceName, &sourceInfo, AT_SYMLINK_NOFOLLOW) == 0,
                      Self.privateFile(sourceInfo), Int64(sourceInfo.st_dev) == expected.device,
                      UInt64(sourceInfo.st_ino) == expected.inode, Int64(sourceInfo.st_size) == expected.bytes else {
                    throw CollectorSpoolGCError.scopeChanged
                }
                guard renameatx_np(source, sourceName, destination, destinationName, UInt32(RENAME_EXCL)) == 0 else {
                    throw CollectorSpoolGCError.ioFailure
                }
                guard fsync(source) == 0, fsync(destination) == 0 else { throw CollectorSpoolGCError.ioFailure }
            }
        }
        guard try verify(to, digest: digest, bytes: expected.bytes) == expected else { throw CollectorSpoolGCError.scopeChanged }
    }

    /// Sole collector unlink boundary. The caller rechecks durable unlinkPrepared
    /// intent, evidence, hold, references and generation immediately at this site.
    func finalizeUnlink(_ relative: String, digest: String, expected: Identity, authorizeIntent: () throws -> Void) throws {
        guard relative.hasPrefix("capture/quarantine/k5/"),
              try verify(relative, digest: digest, bytes: expected.bytes) == expected else { throw CollectorSpoolGCError.scopeChanged }
        try withParent(relative, create: false, missing: (), requireParent: true) { quarantineParent, name, validateParents in
            try authorizeIntent()
            try validateParents()
            var info = stat()
            guard fstatat(quarantineParent, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  Self.privateFile(info), Int64(info.st_dev) == expected.device,
                  UInt64(info.st_ino) == expected.inode, Int64(info.st_size) == expected.bytes else { throw CollectorSpoolGCError.scopeChanged }
            guard unlinkat(quarantineParent, name, 0) == 0 else { throw CollectorSpoolGCError.ioFailure }
            guard fsync(quarantineParent) == 0 else { throw CollectorSpoolGCError.ioFailure }
        }
    }

    /// Metadata-only census for reporting. Orphans are retained and never become
    /// candidates. Every lookup stays beneath pinned no-follow descriptors.
    func census(check: () throws -> Void) throws -> [String: Identity] {
        var result: [String: Identity] = [:]
        func names(_ fd: Int32) throws -> [String] {
            let copy = dup(fd)
            guard copy >= 0 else { throw CollectorSpoolGCError.ioFailure }
            guard let stream = fdopendir(copy) else { close(copy); throw CollectorSpoolGCError.ioFailure }
            defer { closedir(stream) }
            var values: [String] = []
            while true {
                try check(); errno = 0
                guard let entry = readdir(stream) else {
                    guard errno == 0 else { throw CollectorSpoolGCError.ioFailure }; break
                }
                let name = withUnsafeBytes(of: entry.pointee.d_name) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
                if name == "." || name == ".." { continue }
                guard values.count < 2_000_000 else { throw CollectorSpoolGCError.budgetExceeded }
                values.append(name)
            }
            return values.sorted()
        }
        try withParent("capture/objects/sha256/_", create: false, missing: (), requireParent: true) { shards, _, validateShards in
            for prefix in try names(shards) {
                guard prefix.count == 2, prefix.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw CollectorSpoolGCError.unsafePath }
                try withParent("capture/objects/sha256/\(prefix)/_", create: false, missing: (), requireParent: true) { objects, _, validateObjects in
                    for digest in try names(objects) {
                        guard result.count < 2_000_000, ArchiveV2Hash.isValidSHA256(digest), digest.hasPrefix(prefix) else { throw CollectorSpoolGCError.unsafePath }
                        var info = stat()
                        guard fstatat(objects, digest, &info, AT_SYMLINK_NOFOLLOW) == 0,
                              Self.privateFile(info), info.st_dev == device, info.st_size >= 0 else { throw CollectorSpoolGCError.unsafePath }
                        result[digest] = Identity(device: Int64(info.st_dev), inode: UInt64(info.st_ino), bytes: Int64(info.st_size), allocatedBytes: Int64(info.st_blocks) * 512)
                    }
                    try validateObjects()
                }
            }
            try validateShards()
        }
        return result
    }

    func availableBytes() throws -> Int64 {
        try validateRoot()
        var info = statfs()
        guard fstatfs(descriptor, &info) == 0 else { throw CollectorSpoolGCError.ioFailure }
        let product = UInt64(info.f_bavail).multipliedReportingOverflow(by: UInt64(info.f_bsize))
        guard !product.overflow, let value = Int64(exactly: product.partialValue) else { throw CollectorSpoolGCError.budgetExceeded }
        return value
    }

    func read(_ relative: String, digest: String, bytes: Int64, maximumBytes: Int64) throws -> Data {
        guard bytes <= maximumBytes, bytes <= Int64(ArchiveV2ProtocolLimits.maxObjectRawBytes) else {
            throw CollectorSpoolGCError.budgetExceeded
        }
        var data = Data()
        guard try verify(relative, digest: digest, bytes: bytes, consume: { data.append($0) }) != nil else {
            throw CollectorSpoolGCError.spoolIntegrityBlocked
        }
        return data
    }

    private func withParent<T>(_ relative: String, create: Bool, missing: T, requireParent: Bool = false,
        _ body: (Int32, String, () throws -> Void) throws -> T) throws -> T {
        try validateRoot()
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (2...16).contains(parts.count), relative.utf8.count <= 4096,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.utf8.contains(0) }) else {
            throw CollectorSpoolGCError.unsafePath
        }
        let first = dup(descriptor)
        guard first >= 0 else { throw CollectorSpoolGCError.ioFailure }
        var chain = [first]
        defer { chain.forEach { close($0) } }
        func validateParents() throws {
            try validateRoot()
            for index in 1..<chain.count {
                var info = stat(), path = stat()
                guard fstat(chain[index], &info) == 0,
                      fstatat(chain[index - 1], parts[index - 1], &path, AT_SYMLINK_NOFOLLOW) == 0,
                      Self.privateDirectory(info), Self.privateDirectory(path), info.st_dev == device,
                      info.st_dev == path.st_dev, info.st_ino == path.st_ino else {
                    throw CollectorSpoolGCError.scopeChanged
                }
            }
        }
        for part in parts.dropLast() {
            let current = chain.last!
            try validateParents()
            if create {
                if mkdirat(current, part, 0o700) == 0 {
                    guard fsync(current) == 0 else { throw CollectorSpoolGCError.ioFailure }
                } else if errno != EEXIST { throw CollectorSpoolGCError.ioFailure }
            }
            let next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0, errno == ENOENT, !create, !requireParent { return missing }
            guard next >= 0 else { throw CollectorSpoolGCError.unsafePath }
            chain.append(next)
            try validateParents()
        }
        let result = try body(chain.last!, parts.last!, validateParents)
        try validateParents()
        return result
    }

    private func validateRoot() throws {
        var info = stat(), opened = stat()
        guard lstat(root.path, &info) == 0, fstat(descriptor, &opened) == 0,
              Self.privateDirectory(info), Self.privateDirectory(opened),
              info.st_dev == device, info.st_ino == inode, opened.st_dev == device, opened.st_ino == inode else {
            throw CollectorSpoolGCError.scopeChanged
        }
    }
    private static func privateDirectory(_ s: stat) -> Bool { s.st_mode & S_IFMT == S_IFDIR && s.st_uid == geteuid() && s.st_mode & 0o077 == 0 }
    private static func privateFile(_ s: stat) -> Bool { s.st_mode & S_IFMT == S_IFREG && s.st_uid == geteuid() && s.st_nlink == 1 && s.st_mode & 0o7777 == 0o600 }
    private static func same(_ a: stat, _ b: stat) -> Bool {
        privateFile(b) && a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size
            && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
}
