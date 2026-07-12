import Darwin
import EngramCoreRead
import Foundation

public enum ArchivePublishResult: Equatable, Sendable {
    case published
    case alreadyPresent
}

public enum ArchiveRemovalResult: Equatable, Sendable {
    case removed(byteCount: Int64)
    case alreadyMissing
}

public enum ImmutableArchiveCASError: Error, Equatable, Sendable {
    case invalidSHA256(String)
    case digestMismatch(expected: String, actual: String)
    case existingContentConflict(expected: String, actual: String)
    case unsafeExistingPath(String)
    case io(operation: String, code: Int32)
}

struct ImmutableArchiveCASTestHooks: Sendable {
    let afterExistingFileVerified: (@Sendable (URL) throws -> Void)?
    let afterDirectoryFsync: (@Sendable (URL) -> Void)?
    let afterFinalLinkPublished: (@Sendable (URL) -> Void)?
    let beforeObjectUnlink: (@Sendable (URL) throws -> Void)?

    init(
        afterExistingFileVerified: (@Sendable (URL) throws -> Void)? = nil,
        afterDirectoryFsync: (@Sendable (URL) -> Void)? = nil,
        afterFinalLinkPublished: (@Sendable (URL) -> Void)? = nil,
        beforeObjectUnlink: (@Sendable (URL) throws -> Void)? = nil
    ) {
        self.afterExistingFileVerified = afterExistingFileVerified
        self.afterDirectoryFsync = afterDirectoryFsync
        self.afterFinalLinkPublished = afterFinalLinkPublished
        self.beforeObjectUnlink = beforeObjectUnlink
    }
}

/// Owner-only, file-backed content-addressed storage for exact archive bytes.
/// Final names are published with `link(2)`, so no operation can replace an
/// existing object. The only unlink performed by this type targets its unique
/// temporary files.
public struct ImmutableArchiveCAS: Sendable {
    private enum Kind {
        case object
        case manifest

        var directory: String {
            switch self {
            case .object: "objects/sha256"
            case .manifest: "manifests/sha256"
            }
        }

        var suffix: String {
            switch self {
            case .object: ""
            case .manifest: ".json"
            }
        }
    }

    private let root: URL
    private let testHooks: ImmutableArchiveCASTestHooks

    public init(root: URL) throws {
        try self.init(root: root, testHooks: ImmutableArchiveCASTestHooks())
    }

    init(root: URL, testHooks: ImmutableArchiveCASTestHooks) throws {
        self.root = root.standardizedFileURL
        self.testHooks = testHooks
        try Self.ensureDirectory(self.root, afterFsync: testHooks.afterDirectoryFsync)
        try Self.ensureDirectory(
            self.root.appendingPathComponent("objects", isDirectory: true),
            afterFsync: testHooks.afterDirectoryFsync
        )
        try Self.ensureDirectory(
            self.root.appendingPathComponent("objects/sha256", isDirectory: true),
            afterFsync: testHooks.afterDirectoryFsync
        )
        try Self.ensureDirectory(
            self.root.appendingPathComponent("manifests", isDirectory: true),
            afterFsync: testHooks.afterDirectoryFsync
        )
        try Self.ensureDirectory(
            self.root.appendingPathComponent("manifests/sha256", isDirectory: true),
            afterFsync: testHooks.afterDirectoryFsync
        )
        try Self.ensureDirectory(
            self.root.appendingPathComponent("tmp", isDirectory: true),
            afterFsync: testHooks.afterDirectoryFsync
        )
    }

    public func publishObject(raw: Data, expectedSHA256: String) throws -> ArchivePublishResult {
        try publish(raw, expectedSHA256: expectedSHA256, kind: .object)
    }

    public func readObject(sha256: String) throws -> Data {
        try read(sha256: sha256, kind: .object)
    }

    public func removeObject(sha256: String) throws -> ArchiveRemovalResult {
        try Self.validate(sha256)
        let objectURL = try url(for: sha256, kind: .object, createShard: false)
        var initial = stat()
        guard Darwin.lstat(objectURL.path, &initial) == 0 else {
            if errno == ENOENT { return .alreadyMissing }
            throw Self.io("lstat-remove-object", code: errno)
        }
        guard Self.isSafeFinalFile(initial) else {
            throw ImmutableArchiveCASError.unsafeExistingPath(objectURL.path)
        }
        let bytes = try Self.readVerified(objectURL, expectedSHA256: sha256)
        try testHooks.beforeObjectUnlink?(objectURL)
        var final = stat()
        guard Darwin.lstat(objectURL.path, &final) == 0 else {
            if errno == ENOENT { return .alreadyMissing }
            throw Self.io("lstat-remove-object-final", code: errno)
        }
        guard Self.isSafeFinalFile(final), Self.sameFileIdentity(initial, final) else {
            throw ImmutableArchiveCASError.unsafeExistingPath(objectURL.path)
        }
        guard Darwin.unlink(objectURL.path) == 0 else {
            if errno == ENOENT { return .alreadyMissing }
            throw Self.io("unlink-object", code: errno)
        }
        try Self.fsyncDirectory(
            objectURL.deletingLastPathComponent(),
            afterFsync: testHooks.afterDirectoryFsync
        )
        return .removed(byteCount: Int64(bytes.count))
    }

    public func publishManifest(_ bytes: Data, expectedSHA256: String) throws -> ArchivePublishResult {
        try publish(bytes, expectedSHA256: expectedSHA256, kind: .manifest)
    }

    public func readManifest(sha256: String) throws -> Data {
        try read(sha256: sha256, kind: .manifest)
    }

    private func publish(
        _ bytes: Data,
        expectedSHA256: String,
        kind: Kind
    ) throws -> ArchivePublishResult {
        try Self.validate(expectedSHA256)
        let actual = ArchiveV2Hash.sha256(bytes)
        guard actual == expectedSHA256 else {
            throw ImmutableArchiveCASError.digestMismatch(expected: expectedSHA256, actual: actual)
        }

        let finalURL = try url(for: expectedSHA256, kind: kind, createShard: true)
        let parent = finalURL.deletingLastPathComponent()
        let temporaryURL = parent.appendingPathComponent(
            ".engram-archive-\(UUID().uuidString).tmp",
            isDirectory: false
        )

        let fd = Darwin.open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard fd >= 0 else {
            throw Self.io("open-temp", code: errno)
        }
        var descriptor = fd
        var temporaryExists = true
        defer {
            if descriptor >= 0 {
                _ = Darwin.close(descriptor)
            }
            if temporaryExists {
                _ = Darwin.unlink(temporaryURL.path)
            }
        }

        guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw Self.io("chmod-temp", code: errno)
        }
        try Self.writeAll(bytes, to: descriptor)
        guard Darwin.fsync(descriptor) == 0 else {
            throw Self.io("fsync-temp", code: errno)
        }
        guard Darwin.close(descriptor) == 0 else {
            descriptor = -1
            throw Self.io("close-temp", code: errno)
        }
        descriptor = -1

        if Darwin.link(temporaryURL.path, finalURL.path) == 0 {
            testHooks.afterFinalLinkPublished?(finalURL)
            guard Darwin.unlink(temporaryURL.path) == 0 else {
                throw Self.io("unlink-temp", code: errno)
            }
            temporaryExists = false
            try Self.fsyncDirectory(
                parent,
                afterFsync: testHooks.afterDirectoryFsync
            )
            return .published
        }

        let linkError = errno
        guard Darwin.unlink(temporaryURL.path) == 0 else {
            throw Self.io("unlink-temp", code: errno)
        }
        temporaryExists = false
        try Self.fsyncDirectory(
            parent,
            afterFsync: testHooks.afterDirectoryFsync
        )
        guard linkError == EEXIST else {
            throw Self.io("link-final", code: linkError)
        }

        do {
            _ = try Self.readVerified(
                finalURL,
                expectedSHA256: expectedSHA256,
                fsyncBeforeAccept: true,
                afterVerified: testHooks.afterExistingFileVerified
            )
            try Self.fsyncDirectory(
                parent,
                afterFsync: testHooks.afterDirectoryFsync
            )
            return .alreadyPresent
        } catch ImmutableArchiveCASError.digestMismatch(_, let existingActual) {
            throw ImmutableArchiveCASError.existingContentConflict(
                expected: expectedSHA256,
                actual: existingActual
            )
        }
    }

    private func read(sha256: String, kind: Kind) throws -> Data {
        try Self.validate(sha256)
        return try Self.readVerified(
            url(for: sha256, kind: kind, createShard: false),
            expectedSHA256: sha256
        )
    }

    private func url(for digest: String, kind: Kind, createShard: Bool) throws -> URL {
        try Self.validate(digest)
        let base = root.appendingPathComponent(kind.directory, isDirectory: true)
        let shard = base.appendingPathComponent(String(digest.prefix(2)), isDirectory: true)
        if createShard {
            try Self.ensureDirectory(
                shard,
                afterFsync: testHooks.afterDirectoryFsync
            )
        }
        return shard.appendingPathComponent("\(digest)\(kind.suffix)", isDirectory: false)
    }

    private static func validate(_ digest: String) throws {
        guard ArchiveV2Hash.isValidSHA256(digest) else {
            throw ImmutableArchiveCASError.invalidSHA256(digest)
        }
    }

    private static func ensureDirectory(
        _ url: URL,
        afterFsync: (@Sendable (URL) -> Void)?
    ) throws {
        let path = url.path
        let created: Bool
        if Darwin.mkdir(path, S_IRWXU) == 0 {
            created = true
        } else if errno == EEXIST {
            created = false
        } else {
            throw io("mkdir", code: errno)
        }
        var info = stat()
        guard Darwin.lstat(path, &info) == 0 else {
            throw io("lstat-directory", code: errno)
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid() else {
            throw ImmutableArchiveCASError.unsafeExistingPath(path)
        }
        guard Darwin.chmod(path, S_IRWXU) == 0 else {
            throw io("chmod-directory", code: errno)
        }
        try fsyncDirectory(url, afterFsync: afterFsync)
        if created {
            try fsyncDirectory(
                url.deletingLastPathComponent(),
                afterFsync: afterFsync
            )
        }
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let result = Darwin.write(
                    fd,
                    base.advanced(by: written),
                    rawBuffer.count - written
                )
                if result < 0, errno == EINTR {
                    continue
                }
                guard result > 0 else {
                    throw io("write-temp", code: result < 0 ? errno : EIO)
                }
                written += result
            }
        }
    }

    private static func readVerified(
        _ url: URL,
        expectedSHA256: String,
        fsyncBeforeAccept: Bool = false,
        afterVerified: (@Sendable (URL) throws -> Void)? = nil
    ) throws -> Data {
        var pathInfo = stat()
        guard Darwin.lstat(url.path, &pathInfo) == 0 else {
            throw io("lstat-final", code: errno)
        }
        guard Self.isSafeFinalFile(pathInfo) else {
            throw ImmutableArchiveCASError.unsafeExistingPath(url.path)
        }

        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ELOOP {
                throw ImmutableArchiveCASError.unsafeExistingPath(url.path)
            }
            throw io("open-final", code: errno)
        }
        defer { _ = Darwin.close(fd) }

        var descriptorInfo = stat()
        guard Darwin.fstat(fd, &descriptorInfo) == 0 else {
            throw io("fstat-final", code: errno)
        }
        guard Self.isSafeFinalFile(descriptorInfo),
              descriptorInfo.st_ino == pathInfo.st_ino,
              descriptorInfo.st_dev == pathInfo.st_dev else {
            throw ImmutableArchiveCASError.unsafeExistingPath(url.path)
        }

        var data = Data()
        if descriptorInfo.st_size > 0 {
            data.reserveCapacity(Int(descriptorInfo.st_size))
        }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(fd, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count < 0, errno == EINTR {
                continue
            }
            guard count >= 0 else {
                throw io("read-final", code: errno)
            }
            if count == 0 { break }
            data.append(buffer, count: count)
        }

        let actual = ArchiveV2Hash.sha256(data)
        guard actual == expectedSHA256 else {
            throw ImmutableArchiveCASError.digestMismatch(
                expected: expectedSHA256,
                actual: actual
            )
        }
        if fsyncBeforeAccept, Darwin.fsync(fd) != 0 {
            throw io("fsync-final", code: errno)
        }
        try afterVerified?(url)

        var finalDescriptorInfo = stat()
        guard Darwin.fstat(fd, &finalDescriptorInfo) == 0 else {
            throw io("fstat-final-after-read", code: errno)
        }
        var finalPathInfo = stat()
        guard Darwin.lstat(url.path, &finalPathInfo) == 0 else {
            throw io("lstat-final-after-read", code: errno)
        }
        guard Self.isSafeFinalFile(finalDescriptorInfo),
              Self.isSafeFinalFile(finalPathInfo),
              Self.sameFileIdentity(descriptorInfo, finalDescriptorInfo),
              Self.sameFileIdentity(finalDescriptorInfo, finalPathInfo) else {
            throw ImmutableArchiveCASError.unsafeExistingPath(url.path)
        }
        return data
    }

    private static func fsyncDirectory(
        _ url: URL,
        afterFsync: (@Sendable (URL) -> Void)?
    ) throws {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw io("open-directory-fsync", code: errno)
        }
        defer { _ = Darwin.close(fd) }
        guard Darwin.fsync(fd) == 0 else {
            throw io("fsync-directory", code: errno)
        }
        afterFsync?(url)
    }

    private static func io(_ operation: String, code: Int32) -> ImmutableArchiveCASError {
        .io(operation: operation, code: code)
    }

    private static func isSafeFinalFile(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFREG
            && info.st_uid == geteuid()
            && info.st_nlink == 1
            && Int(info.st_mode & 0o777) == 0o600
    }

    private static func sameFileIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }
}
