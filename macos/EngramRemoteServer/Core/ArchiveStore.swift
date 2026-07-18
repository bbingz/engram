import CryptoKit
import Darwin
import Foundation

public enum ArchivePublishResult: Equatable, Sendable {
    case published
    case alreadyPresent
}

public struct ArchiveReceiptCreation: Equatable, Sendable {
    public let bytes: Data
    public let result: ArchivePublishResult

    public init(bytes: Data, result: ArchivePublishResult) {
        self.bytes = bytes
        self.result = result
    }
}

public enum ArchiveStoreError: Error, Equatable, Sendable {
    case invalidDigest
    case digestMismatch
    case tooLarge
    case notFound
    case conflict
    case invalidManifest
    case invalidReceipt
    case missingReference
    case unboundManifest
    case invalidMachineID
    case invalidPage
    case io
}

struct ArchiveStoreTestHooks: Sendable {
    let maximumWriteBytesPerCall: Int?
    let afterWriteCall: (@Sendable (Int) -> Void)?
    let beforeFileFsync: (@Sendable (ArchiveEnvelopeKind) throws -> Void)?
    let beforeDirectoryFsync: (@Sendable (ArchiveEnvelopeKind) throws -> Void)?
    let beforeDirectoryParentFsync: (@Sendable (URL) throws -> Void)?
    let beforeFinalPublish: (@Sendable (ArchiveEnvelopeKind, URL) throws -> Void)?
    let afterFinalPublish: (@Sendable (ArchiveEnvelopeKind, URL) -> Void)?
    let afterExistingEnvelopeVerified: (@Sendable (URL) throws -> Void)?

    init(
        maximumWriteBytesPerCall: Int? = nil,
        afterWriteCall: (@Sendable (Int) -> Void)? = nil,
        beforeFileFsync: (@Sendable (ArchiveEnvelopeKind) throws -> Void)? = nil,
        beforeDirectoryFsync: (@Sendable (ArchiveEnvelopeKind) throws -> Void)? = nil,
        beforeDirectoryParentFsync: (@Sendable (URL) throws -> Void)? = nil,
        beforeFinalPublish: (@Sendable (ArchiveEnvelopeKind, URL) throws -> Void)? = nil,
        afterFinalPublish: (@Sendable (ArchiveEnvelopeKind, URL) -> Void)? = nil,
        afterExistingEnvelopeVerified: (@Sendable (URL) throws -> Void)? = nil
    ) {
        self.maximumWriteBytesPerCall = maximumWriteBytesPerCall
        self.afterWriteCall = afterWriteCall
        self.beforeFileFsync = beforeFileFsync
        self.beforeDirectoryFsync = beforeDirectoryFsync
        self.beforeDirectoryParentFsync = beforeDirectoryParentFsync
        self.beforeFinalPublish = beforeFinalPublish
        self.afterFinalPublish = afterFinalPublish
        self.afterExistingEnvelopeVerified = afterExistingEnvelopeVerified
    }
}

/// Server-local immutable encrypted archive storage.
///
/// This type intentionally shares neither implementation nor state with the
/// mutable legacy `BlobStore`. Its only unlink operations target unique temp
/// files created by this process.
public struct ArchiveStore: Sendable {
    private struct DirectoryIdentity: Equatable {
        let device: UInt64
        let inode: UInt64

        init(_ info: stat) {
            device = UInt64(info.st_dev)
            inode = UInt64(info.st_ino)
        }
    }

    private enum PublicationResult {
        case published
        case alreadyPresent(Data)
    }

    private let root: URL
    private let serverID: String
    private let codec: ArchiveEnvelopeCodec
    private let hooks: ArchiveStoreTestHooks
    private let now: @Sendable () -> String

    public init(root: URL, key: SymmetricKey, serverID: String) throws {
        try self.init(
            root: root,
            key: key,
            serverID: serverID,
            hooks: ArchiveStoreTestHooks(),
            now: { Self.currentTimestamp() }
        )
    }

    init(
        root: URL,
        key: SymmetricKey,
        serverID: String,
        testHooks: ArchiveStoreTestHooks
    ) throws {
        try self.init(
            root: root,
            key: key,
            serverID: serverID,
            hooks: testHooks,
            now: { Self.currentTimestamp() }
        )
    }

    init(
        root: URL,
        key: SymmetricKey,
        serverID: String,
        now: @escaping @Sendable () -> String
    ) throws {
        try self.init(
            root: root,
            key: key,
            serverID: serverID,
            hooks: ArchiveStoreTestHooks(),
            now: now
        )
    }

    private init(
        root: URL,
        key: SymmetricKey,
        serverID: String,
        hooks: ArchiveStoreTestHooks,
        now: @escaping @Sendable () -> String
    ) throws {
        guard Self.isSafeServerID(serverID) else {
            throw ArchiveStoreError.invalidReceipt
        }
        self.root = root.standardizedFileURL
        self.serverID = serverID
        self.codec = ArchiveEnvelopeCodec(key: key)
        self.hooks = hooks
        self.now = now

        guard Self.isSafeArchiveRoot(self.root) else {
            throw ArchiveStoreError.conflict
        }
        try Self.ensureDirectory(
            self.root,
            parentRequiresArchiveOwnership: false,
            beforeParentFsync: hooks.beforeDirectoryParentFsync
        )
        for relative in [
            "objects",
            "objects/sha256",
            "manifests",
            "manifests/sha256",
            "receipts",
            "receipts/sha256",
            "tmp",
        ] {
            try Self.ensureDirectory(
                self.root.appendingPathComponent(relative, isDirectory: true),
                beforeParentFsync: hooks.beforeDirectoryParentFsync
            )
        }
    }

    public func putObject(digest: String, raw: Data) throws -> ArchivePublishResult {
        try Self.validateDigest(digest)
        guard raw.count <= ArchiveV2ProtocolLimits.maxObjectRawBytes else {
            throw ArchiveStoreError.tooLarge
        }
        guard ArchiveV2Hash.sha256(raw) == digest else {
            throw ArchiveStoreError.digestMismatch
        }
        let envelope = try encode(raw, kind: .object, expectedDigest: digest)
        switch try publish(envelope, expectedDigest: digest, kind: .object) {
        case .published:
            return .published
        case .alreadyPresent(let existing):
            guard existing == raw else { throw ArchiveStoreError.conflict }
            return .alreadyPresent
        }
    }

    public func getObject(digest: String) throws -> Data {
        try Self.validateDigest(digest)
        return try readEnvelope(
            at: url(for: digest, kind: .object, createShard: false),
            expectedKind: .object,
            expectedDigest: digest
        )
    }

    /// M14: existence-only probe for HEAD — lstat regular file, no decrypt.
    public func hasObject(digest: String) throws -> Bool {
        try Self.validateDigest(digest)
        return try Self.regularFilePresent(at: url(for: digest, kind: .object, createShard: false))
    }

    /// M14: existence-only probe for HEAD manifests — no chunk re-validation.
    public func hasManifest(digest: String) throws -> Bool {
        try Self.validateDigest(digest)
        return try Self.regularFilePresent(at: url(for: digest, kind: .manifest, createShard: false))
    }

    public func putManifest(
        digest: String,
        canonicalBytes: Data
    ) throws -> ArchivePublishResult {
        try Self.validateDigest(digest)
        guard canonicalBytes.count <= ArchiveV2ProtocolLimits.maxManifestBytes else {
            throw ArchiveStoreError.tooLarge
        }
        guard ArchiveV2Hash.sha256(canonicalBytes) == digest else {
            throw ArchiveStoreError.digestMismatch
        }
        _ = try validatedManifest(
            canonicalBytes,
            expectedDigest: digest,
            durableReferences: false
        )
        let envelope = try encode(canonicalBytes, kind: .manifest, expectedDigest: digest)
        switch try publish(envelope, expectedDigest: digest, kind: .manifest) {
        case .published:
            return .published
        case .alreadyPresent(let existing):
            guard existing == canonicalBytes else { throw ArchiveStoreError.conflict }
            return .alreadyPresent
        }
    }

    public func getManifest(digest: String) throws -> Data {
        try Self.validateDigest(digest)
        let bytes = try readEnvelope(
            at: url(for: digest, kind: .manifest, createShard: false),
            expectedKind: .manifest,
            expectedDigest: digest
        )
        _ = try validatedManifest(
            bytes,
            expectedDigest: digest,
            durableReferences: false
        )
        return bytes
    }

    public func createReceipt(manifestDigest: String) throws -> Data {
        try createReceiptWithResult(manifestDigest: manifestDigest).bytes
    }

    public func createReceiptWithResult(
        manifestDigest: String
    ) throws -> ArchiveReceiptCreation {
        try Self.validateDigest(manifestDigest)
        let manifestBytes = try readDurableEnvelope(
            digest: manifestDigest,
            kind: .manifest
        )
        let manifest: ArchiveSourceManifest
        do {
            manifest = try validatedManifest(
                manifestBytes,
                expectedDigest: manifestDigest,
                durableReferences: true
            )
        } catch let error as ArchiveStoreError {
            throw error
        } catch {
            throw ArchiveStoreError.invalidManifest
        }
        do {
            let existing = try getReceipt(manifestDigest: manifestDigest)
            try validateReceiptBytes(
                existing,
                manifestDigest: manifestDigest,
                manifest: manifest
            )
            return ArchiveReceiptCreation(bytes: existing, result: .alreadyPresent)
        } catch ArchiveStoreError.notFound {
            // Create the first immutable receipt below.
        }
        guard let sessionID = manifest.sessionID else {
            throw ArchiveStoreError.unboundManifest
        }
        let storedAt = now()
        guard Self.isCanonicalTimestamp(storedAt) else {
            throw ArchiveStoreError.invalidReceipt
        }
        let receipt: ArchiveServerReceipt
        do {
            receipt = try ArchiveServerReceipt(
                serverID: serverID,
                machineID: manifest.machineID,
                sessionID: sessionID,
                captureID: manifest.captureID,
                manifestSHA256: manifestDigest,
                wholeSourceSHA256: manifest.wholeSourceSHA256,
                objectCount: manifest.chunks.count,
                rawByteCount: manifest.rawByteCount,
                storedAt: storedAt
            )
        } catch {
            throw ArchiveStoreError.invalidReceipt
        }
        let receiptBytes: Data
        do {
            receiptBytes = try ArchiveCanonicalJSON.encode(receipt)
        } catch {
            throw ArchiveStoreError.invalidReceipt
        }
        guard receiptBytes.count <= ArchiveV2ProtocolLimits.maxReceiptBytes else {
            throw ArchiveStoreError.tooLarge
        }
        let envelope = try encode(
            receiptBytes,
            kind: .receipt,
            expectedDigest: manifestDigest
        )
        switch try publish(envelope, expectedDigest: manifestDigest, kind: .receipt) {
        case .published:
            return ArchiveReceiptCreation(bytes: receiptBytes, result: .published)
        case .alreadyPresent(let existing):
            try validateReceiptBytes(
                existing,
                manifestDigest: manifestDigest,
                manifest: manifest
            )
            return ArchiveReceiptCreation(bytes: existing, result: .alreadyPresent)
        }
    }

    public func getReceipt(manifestDigest: String) throws -> Data {
        try Self.validateDigest(manifestDigest)
        let bytes = try readDurableEnvelope(
            digest: manifestDigest,
            kind: .receipt
        )
        try validateReceiptBytes(bytes, manifestDigest: manifestDigest)
        return bytes
    }

    public func listMachines(cursor: String?, limit: Int) throws -> ArchiveMachinePage {
        try Self.validateLimit(limit)
        let cursorKey = try Self.decodeCursor(cursor)
        if let cursorKey,
           UUID(uuidString: cursorKey)?.uuidString != cursorKey {
            throw ArchiveStoreError.invalidPage
        }

        var candidates: [String] = []
        try forEachReceipt { _, receiptBytes in
            let receipt = try Self.decodeReceiptForDiscovery(receiptBytes)
            guard let canonicalMachineID = UUID(uuidString: receipt.machineID)?.uuidString else {
                throw ArchiveStoreError.conflict
            }
            guard cursorKey.map({ canonicalMachineID > $0 }) ?? true else { return }
            Self.insertBoundedUnique(
                canonicalMachineID,
                into: &candidates,
                maximumCount: limit + 1
            )
        }
        let hasMore = candidates.count > limit
        if hasMore { candidates.removeLast() }
        let nextCursor = hasMore ? candidates.last.map(Self.encodeCursor) : nil
        do {
            return try ArchiveMachinePage(machineIDs: candidates, nextCursor: nextCursor)
        } catch {
            throw ArchiveStoreError.invalidPage
        }
    }

    public func listReceipts(
        machineID: String,
        cursor: String?,
        limit: Int
    ) throws -> ArchiveReceiptPage {
        try Self.validateLimit(limit)
        guard let canonicalMachineID = UUID(uuidString: machineID)?.uuidString else {
            throw ArchiveStoreError.invalidMachineID
        }
        let cursorKey = try Self.decodeCursor(cursor)
        if let cursorKey, !ArchiveV2Hash.isValidSHA256(cursorKey) {
            throw ArchiveStoreError.invalidPage
        }

        var candidates: [ArchiveReceiptSummary] = []
        try forEachReceipt { manifestDigest, receiptBytes in
            let receipt = try Self.decodeReceiptForDiscovery(receiptBytes)
            guard UUID(uuidString: receipt.machineID)?.uuidString == canonicalMachineID else {
                return
            }
            guard cursorKey.map({ manifestDigest > $0 }) ?? true else { return }
            let summary: ArchiveReceiptSummary
            do {
                summary = try ArchiveReceiptSummary(
                    manifestSHA256: manifestDigest,
                    receiptSHA256: ArchiveV2Hash.sha256(receiptBytes)
                )
            } catch {
                throw ArchiveStoreError.conflict
            }
            Self.insertBoundedSummary(
                summary,
                into: &candidates,
                maximumCount: limit + 1
            )
        }
        let hasMore = candidates.count > limit
        if hasMore { candidates.removeLast() }
        let nextCursor = hasMore
            ? candidates.last.map { Self.encodeCursor($0.manifestSHA256) }
            : nil
        do {
            return try ArchiveReceiptPage(receipts: candidates, nextCursor: nextCursor)
        } catch {
            throw ArchiveStoreError.invalidPage
        }
    }

    private func validatedManifest(
        _ bytes: Data,
        expectedDigest: String,
        durableReferences: Bool
    ) throws -> ArchiveSourceManifest {
        guard ArchiveV2Hash.sha256(bytes) == expectedDigest else {
            throw ArchiveStoreError.digestMismatch
        }
        let manifest: ArchiveSourceManifest
        do {
            manifest = try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: bytes)
        } catch {
            throw ArchiveStoreError.invalidManifest
        }

        var wholeHasher = SHA256()
        for chunk in manifest.chunks {
            let object: Data
            do {
                object = durableReferences
                    ? try readDurableEnvelope(digest: chunk.rawSHA256, kind: .object)
                    : try getObject(digest: chunk.rawSHA256)
            } catch ArchiveStoreError.notFound {
                throw ArchiveStoreError.missingReference
            } catch ArchiveStoreError.io {
                throw ArchiveStoreError.io
            } catch {
                throw ArchiveStoreError.conflict
            }
            guard object.count == chunk.rawByteCount,
                  ArchiveV2Hash.sha256(object) == chunk.rawSHA256 else {
                throw ArchiveStoreError.conflict
            }
            wholeHasher.update(data: object)
        }
        let wholeDigest = Data(wholeHasher.finalize())
            .map { String(format: "%02x", $0) }
            .joined()
        guard wholeDigest == manifest.wholeSourceSHA256 else {
            throw ArchiveStoreError.invalidManifest
        }
        return manifest
    }

    private func readDurableEnvelope(
        digest: String,
        kind: ArchiveEnvelopeKind
    ) throws -> Data {
        let parentIdentity = try requiredParentIdentity(
            digest: digest,
            kind: kind,
            createShard: false
        )
        let finalURL = try url(for: digest, kind: kind, createShard: false)
        let raw = try readEnvelope(
            at: finalURL,
            expectedKind: kind,
            expectedDigest: digest,
            fsyncBeforeAccept: true
        )
        try hooks.beforeDirectoryFsync?(kind)
        try assertParentIdentity(
            parentIdentity,
            digest: digest,
            kind: kind
        )
        try Self.fsyncDirectory(finalURL.deletingLastPathComponent())
        try assertParentIdentity(
            parentIdentity,
            digest: digest,
            kind: kind
        )
        return raw
    }

    private func validateReceiptBytes(
        _ bytes: Data,
        manifestDigest: String,
        manifest suppliedManifest: ArchiveSourceManifest? = nil
    ) throws {
        guard bytes.count <= ArchiveV2ProtocolLimits.maxReceiptBytes else {
            throw ArchiveStoreError.conflict
        }
        let receipt: ArchiveServerReceipt
        do {
            receipt = try ArchiveCanonicalJSON.decode(ArchiveServerReceipt.self, from: bytes)
        } catch {
            throw ArchiveStoreError.conflict
        }
        guard receipt.serverID == serverID,
              receipt.manifestSHA256 == manifestDigest,
              Self.isCanonicalTimestamp(receipt.storedAt) else {
            throw ArchiveStoreError.conflict
        }
        let manifest: ArchiveSourceManifest
        do {
            if let suppliedManifest {
                manifest = suppliedManifest
            } else {
                let manifestBytes = try readEnvelope(
                    at: url(for: manifestDigest, kind: .manifest, createShard: false),
                    expectedKind: .manifest,
                    expectedDigest: manifestDigest
                )
                manifest = try ArchiveCanonicalJSON.decode(
                    ArchiveSourceManifest.self,
                    from: manifestBytes
                )
            }
            let canonicalManifestBytes = try ArchiveCanonicalJSON.encode(manifest)
            guard ArchiveV2Hash.sha256(canonicalManifestBytes) == manifestDigest else {
                throw ArchiveStoreError.conflict
            }
            try receipt.validate(
                againstCanonicalManifestBytes: canonicalManifestBytes
            )
        } catch ArchiveStoreError.notFound {
            throw ArchiveStoreError.conflict
        } catch let error as ArchiveStoreError {
            if error == .io { throw error }
            throw ArchiveStoreError.conflict
        } catch {
            throw ArchiveStoreError.conflict
        }
    }

    private func encode(
        _ raw: Data,
        kind: ArchiveEnvelopeKind,
        expectedDigest: String
    ) throws -> Data {
        do {
            return try codec.encode(raw: raw, kind: kind, expectedDigest: expectedDigest)
        } catch ArchiveEnvelopeError.invalidExpectedDigest {
            throw ArchiveStoreError.invalidDigest
        } catch ArchiveEnvelopeError.inputTooLarge {
            throw ArchiveStoreError.tooLarge
        } catch ArchiveEnvelopeError.rawDigestMismatch {
            throw ArchiveStoreError.digestMismatch
        } catch {
            throw ArchiveStoreError.io
        }
    }

    private func publish(
        _ envelope: Data,
        expectedDigest: String,
        kind: ArchiveEnvelopeKind
    ) throws -> PublicationResult {
        let finalURL = try url(for: expectedDigest, kind: kind, createShard: true)
        let parent = finalURL.deletingLastPathComponent()
        let parentIdentity = try requiredParentIdentity(
            digest: expectedDigest,
            kind: kind,
            createShard: false
        )
        let temporaryURL = parent.appendingPathComponent(
            ".engram-archive-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let fd = Darwin.open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard fd >= 0 else { throw ArchiveStoreError.io }
        try assertParentIdentity(
            parentIdentity,
            digest: expectedDigest,
            kind: kind
        )
        var descriptor = fd
        var temporaryExists = true
        defer {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            if temporaryExists { _ = Darwin.unlink(temporaryURL.path) }
        }

        guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw ArchiveStoreError.io
        }
        try writeAll(envelope, to: descriptor)
        try hooks.beforeFileFsync?(kind)
        guard Darwin.fsync(descriptor) == 0 else { throw ArchiveStoreError.io }
        guard Darwin.close(descriptor) == 0 else {
            descriptor = -1
            throw ArchiveStoreError.io
        }
        descriptor = -1
        try hooks.beforeFinalPublish?(kind, finalURL)
        try assertParentIdentity(
            parentIdentity,
            digest: expectedDigest,
            kind: kind
        )

        if Darwin.renameatx_np(
            AT_FDCWD,
            temporaryURL.path,
            AT_FDCWD,
            finalURL.path,
            UInt32(RENAME_EXCL)
        ) == 0 {
            temporaryExists = false
            try assertParentIdentity(
                parentIdentity,
                digest: expectedDigest,
                kind: kind
            )
            hooks.afterFinalPublish?(kind, finalURL)
            try hooks.beforeDirectoryFsync?(kind)
            try Self.fsyncDirectory(parent)
            try assertParentIdentity(
                parentIdentity,
                digest: expectedDigest,
                kind: kind
            )
            return .published
        }

        let renameError = errno
        try assertParentIdentity(
            parentIdentity,
            digest: expectedDigest,
            kind: kind
        )
        guard Darwin.unlink(temporaryURL.path) == 0 else {
            throw ArchiveStoreError.io
        }
        temporaryExists = false
        try Self.fsyncDirectory(parent)
        guard renameError == EEXIST else { throw ArchiveStoreError.io }

        let existing = try readEnvelope(
            at: finalURL,
            expectedKind: kind,
            expectedDigest: expectedDigest,
            fsyncBeforeAccept: true,
            afterVerified: hooks.afterExistingEnvelopeVerified
        )
        try hooks.beforeDirectoryFsync?(kind)
        try Self.fsyncDirectory(parent)
        try assertParentIdentity(
            parentIdentity,
            digest: expectedDigest,
            kind: kind
        )
        return .alreadyPresent(existing)
    }

    private func readEnvelope(
        at url: URL,
        expectedKind: ArchiveEnvelopeKind,
        expectedDigest: String,
        fsyncBeforeAccept: Bool = false,
        afterVerified: (@Sendable (URL) throws -> Void)? = nil
    ) throws -> Data {
        let parentIdentity = try requiredParentIdentity(
            digest: expectedDigest,
            kind: expectedKind,
            createShard: false
        )
        var pathInfo = stat()
        guard Darwin.lstat(url.path, &pathInfo) == 0 else {
            if errno == ENOENT { throw ArchiveStoreError.notFound }
            throw ArchiveStoreError.io
        }
        guard Self.isSafeFinalFile(pathInfo),
              pathInfo.st_size <= Self.maximumEnvelopeBytes(for: expectedKind) else {
            throw ArchiveStoreError.conflict
        }

        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { throw ArchiveStoreError.notFound }
            throw ArchiveStoreError.conflict
        }
        defer { _ = Darwin.close(fd) }
        try assertParentIdentity(
            parentIdentity,
            digest: expectedDigest,
            kind: expectedKind
        )

        var initialDescriptorInfo = stat()
        guard Darwin.fstat(fd, &initialDescriptorInfo) == 0 else {
            throw ArchiveStoreError.io
        }
        guard Self.isSafeFinalFile(initialDescriptorInfo),
              Self.sameFileIdentity(pathInfo, initialDescriptorInfo),
              initialDescriptorInfo.st_size <= Self.maximumEnvelopeBytes(for: expectedKind) else {
            throw ArchiveStoreError.conflict
        }

        var envelope = Data()
        if initialDescriptorInfo.st_size > 0 {
            envelope.reserveCapacity(Int(initialDescriptorInfo.st_size))
        }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(fd, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw ArchiveStoreError.io }
            if count == 0 { break }
            guard Int64(envelope.count)
                <= Self.maximumEnvelopeBytes(for: expectedKind) - Int64(count) else {
                throw ArchiveStoreError.conflict
            }
            envelope.append(buffer, count: count)
        }

        let raw: Data
        do {
            raw = try codec.decode(
                envelope,
                expectedKind: expectedKind,
                expectedDigest: expectedDigest
            )
        } catch {
            throw ArchiveStoreError.conflict
        }
        if fsyncBeforeAccept {
            try hooks.beforeFileFsync?(expectedKind)
            guard Darwin.fsync(fd) == 0 else { throw ArchiveStoreError.io }
        }
        try afterVerified?(url)

        var finalDescriptorInfo = stat()
        guard Darwin.fstat(fd, &finalDescriptorInfo) == 0 else {
            throw ArchiveStoreError.io
        }
        var finalPathInfo = stat()
        guard Darwin.lstat(url.path, &finalPathInfo) == 0 else {
            throw ArchiveStoreError.conflict
        }
        guard Self.isSafeFinalFile(finalDescriptorInfo),
              Self.isSafeFinalFile(finalPathInfo),
              Self.sameFileIdentity(initialDescriptorInfo, finalDescriptorInfo),
              Self.sameFileIdentity(finalDescriptorInfo, finalPathInfo) else {
            throw ArchiveStoreError.conflict
        }
        try assertParentIdentity(
            parentIdentity,
            digest: expectedDigest,
            kind: expectedKind
        )
        return raw
    }

    private func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let remaining = rawBuffer.count - written
                let requested = min(
                    remaining,
                    max(1, hooks.maximumWriteBytesPerCall ?? remaining)
                )
                let result = Darwin.write(fd, base.advanced(by: written), requested)
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw ArchiveStoreError.io }
                hooks.afterWriteCall?(result)
                written += result
            }
        }
    }

    private func url(
        for digest: String,
        kind: ArchiveEnvelopeKind,
        createShard: Bool
    ) throws -> URL {
        try Self.validateDigest(digest)
        let directory: String
        switch kind {
        case .object: directory = "objects/sha256"
        case .manifest: directory = "manifests/sha256"
        case .receipt: directory = "receipts/sha256"
        }
        let base = root.appendingPathComponent(directory, isDirectory: true)
        let shard = base.appendingPathComponent(String(digest.prefix(2)), isDirectory: true)
        _ = try validatedDirectoryChain(
            kind: kind,
            digest: digest,
            createShard: createShard
        )
        return shard.appendingPathComponent(digest, isDirectory: false)
    }

    private func forEachReceipt(
        _ body: (String, Data) throws -> Void
    ) throws {
        let base = root.appendingPathComponent("receipts/sha256", isDirectory: true)
        let baseIdentity = try validatedBaseDirectoryIdentity(kind: .receipt)
        guard let baseDirectory = Darwin.opendir(base.path) else {
            throw ArchiveStoreError.io
        }
        defer { Darwin.closedir(baseDirectory) }

        while let shardEntry = Darwin.readdir(baseDirectory) {
            let shard = Self.directoryEntryName(shardEntry)
            if shard == "." || shard == ".." { continue }
            if shard.hasPrefix(".") { continue }
            guard shard.utf8.count == 2,
                  shard.utf8.allSatisfy({ byte in
                      (48...57).contains(byte) || (97...102).contains(byte)
                  }) else {
                throw ArchiveStoreError.conflict
            }
            let shardURL = base.appendingPathComponent(shard, isDirectory: true)
            guard let shardIdentity = try Self.validatedDirectoryIdentity(shardURL) else {
                throw ArchiveStoreError.conflict
            }
            guard let shardDirectory = Darwin.opendir(shardURL.path) else {
                throw ArchiveStoreError.conflict
            }
            defer { Darwin.closedir(shardDirectory) }
            guard try Self.validatedDirectoryIdentity(shardURL) == shardIdentity else {
                throw ArchiveStoreError.conflict
            }

            while let receiptEntry = Darwin.readdir(shardDirectory) {
                let manifestDigest = Self.directoryEntryName(receiptEntry)
                if manifestDigest == "." || manifestDigest == ".." { continue }
                if manifestDigest.hasPrefix(".") { continue }
                guard shard == String(manifestDigest.prefix(2)),
                      ArchiveV2Hash.isValidSHA256(manifestDigest) else {
                    throw ArchiveStoreError.conflict
                }
                let receiptBytes = try getReceipt(manifestDigest: manifestDigest)
                try body(manifestDigest, receiptBytes)
            }
            guard try Self.validatedDirectoryIdentity(shardURL) == shardIdentity else {
                throw ArchiveStoreError.conflict
            }
        }
        guard try validatedBaseDirectoryIdentity(kind: .receipt) == baseIdentity else {
            throw ArchiveStoreError.conflict
        }
    }

    private static func directoryEntryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
        withUnsafePointer(to: &entry.pointee.d_name) { namePointer in
            namePointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                String(cString: $0)
            }
        }
    }

    private static func decodeReceiptForDiscovery(_ bytes: Data) throws -> ArchiveServerReceipt {
        do {
            return try ArchiveCanonicalJSON.decode(ArchiveServerReceipt.self, from: bytes)
        } catch {
            throw ArchiveStoreError.conflict
        }
    }

    private func validatedDirectoryChain(
        kind: ArchiveEnvelopeKind,
        digest: String,
        createShard: Bool
    ) throws -> DirectoryIdentity? {
        let baseIdentity = try validatedBaseDirectoryIdentity(kind: kind)
        let shard = baseURL(for: kind)
            .appendingPathComponent(String(digest.prefix(2)), isDirectory: true)
        var shardIdentity = try Self.validatedDirectoryIdentity(shard)
        if createShard {
            guard try validatedBaseDirectoryIdentity(kind: kind) == baseIdentity else {
                throw ArchiveStoreError.conflict
            }
            try Self.ensureDirectory(
                shard,
                beforeParentFsync: hooks.beforeDirectoryParentFsync
            )
            shardIdentity = try Self.validatedDirectoryIdentity(shard)
        }
        guard let shardIdentity else { return nil }
        guard try validatedBaseDirectoryIdentity(kind: kind) == baseIdentity,
              try Self.validatedDirectoryIdentity(shard) == shardIdentity else {
            throw ArchiveStoreError.conflict
        }
        return shardIdentity
    }

    private func requiredParentIdentity(
        digest: String,
        kind: ArchiveEnvelopeKind,
        createShard: Bool
    ) throws -> DirectoryIdentity {
        guard let identity = try validatedDirectoryChain(
            kind: kind,
            digest: digest,
            createShard: createShard
        ) else {
            throw ArchiveStoreError.notFound
        }
        return identity
    }

    private func assertParentIdentity(
        _ expected: DirectoryIdentity,
        digest: String,
        kind: ArchiveEnvelopeKind
    ) throws {
        guard try validatedDirectoryChain(
            kind: kind,
            digest: digest,
            createShard: false
        ) == expected else {
            throw ArchiveStoreError.conflict
        }
    }

    private func validatedBaseDirectoryIdentity(
        kind: ArchiveEnvelopeKind
    ) throws -> DirectoryIdentity {
        let top = root.appendingPathComponent(topDirectoryName(for: kind), isDirectory: true)
        let base = top.appendingPathComponent("sha256", isDirectory: true)
        let urls = [root, top, base]
        let identities = try urls.map { url -> DirectoryIdentity in
            guard let identity = try Self.validatedDirectoryIdentity(url) else {
                throw ArchiveStoreError.conflict
            }
            return identity
        }
        for (url, expected) in zip(urls, identities) {
            guard try Self.validatedDirectoryIdentity(url) == expected else {
                throw ArchiveStoreError.conflict
            }
        }
        return identities[2]
    }

    private func baseURL(for kind: ArchiveEnvelopeKind) -> URL {
        root
            .appendingPathComponent(topDirectoryName(for: kind), isDirectory: true)
            .appendingPathComponent("sha256", isDirectory: true)
    }

    private func topDirectoryName(for kind: ArchiveEnvelopeKind) -> String {
        switch kind {
        case .object: return "objects"
        case .manifest: return "manifests"
        case .receipt: return "receipts"
        }
    }

    private static func validatedDirectoryIdentity(
        _ url: URL
    ) throws -> DirectoryIdentity? {
        var pathInfo = stat()
        guard Darwin.lstat(url.path, &pathInfo) == 0 else {
            if errno == ENOENT { return nil }
            throw ArchiveStoreError.io
        }
        guard isSafeDirectory(pathInfo) else {
            throw ArchiveStoreError.conflict
        }
        let fd = Darwin.open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw ArchiveStoreError.conflict
        }
        defer { _ = Darwin.close(fd) }
        var descriptorInfo = stat()
        var finalPathInfo = stat()
        guard Darwin.fstat(fd, &descriptorInfo) == 0,
              Darwin.lstat(url.path, &finalPathInfo) == 0,
              isSafeDirectory(descriptorInfo),
              isSafeDirectory(finalPathInfo),
              sameFileIdentity(pathInfo, descriptorInfo),
              sameFileIdentity(descriptorInfo, finalPathInfo) else {
            throw ArchiveStoreError.conflict
        }
        return DirectoryIdentity(descriptorInfo)
    }

    private static func insertBoundedUnique(
        _ value: String,
        into values: inout [String],
        maximumCount: Int
    ) {
        guard !values.contains(value) else { return }
        values.append(value)
        values.sort()
        if values.count > maximumCount { values.removeLast() }
    }

    private static func insertBoundedSummary(
        _ value: ArchiveReceiptSummary,
        into values: inout [ArchiveReceiptSummary],
        maximumCount: Int
    ) {
        if let existing = values.first(where: {
            $0.manifestSHA256 == value.manifestSHA256
        }) {
            if existing != value { values.removeAll() }
            return
        }
        values.append(value)
        values.sort { $0.manifestSHA256 < $1.manifestSHA256 }
        if values.count > maximumCount { values.removeLast() }
    }

    private static func validateDigest(_ digest: String) throws {
        guard ArchiveV2Hash.isValidSHA256(digest) else {
            throw ArchiveStoreError.invalidDigest
        }
    }

    private static func validateLimit(_ limit: Int) throws {
        guard (1...ArchiveV2ProtocolLimits.maxPageItems).contains(limit) else {
            throw ArchiveStoreError.invalidPage
        }
    }

    private static func encodeCursor(_ key: String) -> String {
        Data(key.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeCursor(_ cursor: String?) throws -> String? {
        do { try ArchiveV2ProtocolLimits.validateCursor(cursor) } catch {
            throw ArchiveStoreError.invalidPage
        }
        guard let cursor else { return nil }
        var base64 = cursor
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        base64.append(String(repeating: "=", count: padding))
        guard let bytes = Data(base64Encoded: base64),
              let key = String(data: bytes, encoding: .utf8),
              encodeCursor(key) == cursor else {
            throw ArchiveStoreError.invalidPage
        }
        return key
    }

    private static func ensureDirectory(
        _ url: URL,
        syncParentWhenExisting: Bool = true,
        parentRequiresArchiveOwnership: Bool = true,
        beforeParentFsync: (@Sendable (URL) throws -> Void)? = nil
    ) throws {
        let created: Bool
        if Darwin.mkdir(url.path, S_IRWXU) == 0 {
            created = true
        } else if errno == EEXIST {
            created = false
        } else {
            throw ArchiveStoreError.io
        }
        var info = stat()
        guard Darwin.lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid() else {
            throw ArchiveStoreError.conflict
        }
        if created {
            guard Darwin.chmod(url.path, S_IRWXU) == 0 else {
                throw ArchiveStoreError.io
            }
        } else if Int(info.st_mode & 0o777) != 0o700 {
            throw ArchiveStoreError.conflict
        }
        try fsyncDirectory(url)
        if created || syncParentWhenExisting {
            try beforeParentFsync?(url)
            if parentRequiresArchiveOwnership {
                try fsyncDirectory(url.deletingLastPathComponent())
            } else {
                try fsyncExternalParentDirectory(url.deletingLastPathComponent())
            }
        }
    }

    private static func fsyncExternalParentDirectory(_ url: URL) throws {
        var pathInfo = stat()
        guard Darwin.lstat(url.path, &pathInfo) == 0,
              (pathInfo.st_mode & S_IFMT) == S_IFDIR else {
            throw ArchiveStoreError.io
        }
        let fd = Darwin.open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard fd >= 0 else { throw ArchiveStoreError.io }
        defer { _ = Darwin.close(fd) }
        var descriptorInfo = stat()
        guard Darwin.fstat(fd, &descriptorInfo) == 0,
              (descriptorInfo.st_mode & S_IFMT) == S_IFDIR,
              sameFileIdentity(pathInfo, descriptorInfo),
              Darwin.fsync(fd) == 0 else {
            throw ArchiveStoreError.io
        }
        var finalPathInfo = stat()
        guard Darwin.lstat(url.path, &finalPathInfo) == 0,
              (finalPathInfo.st_mode & S_IFMT) == S_IFDIR,
              sameFileIdentity(descriptorInfo, finalPathInfo) else {
            throw ArchiveStoreError.conflict
        }
    }

    /// M14: lstat-only presence (regular file, owner euid). No open/decrypt.
    private static func regularFilePresent(at url: URL) throws -> Bool {
        var info = stat()
        guard Darwin.lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return false }
            throw ArchiveStoreError.io
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw ArchiveStoreError.conflict
        }
        guard info.st_uid == geteuid() else {
            throw ArchiveStoreError.conflict
        }
        return true
    }

    private static func fsyncDirectory(_ url: URL) throws {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ArchiveStoreError.io }
        defer { _ = Darwin.close(fd) }
        var info = stat()
        guard Darwin.fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(),
              Darwin.fsync(fd) == 0 else {
            throw ArchiveStoreError.io
        }
    }

    private static func isSafeFinalFile(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFREG
            && info.st_uid == geteuid()
            && info.st_nlink == 1
            && Int(info.st_mode & 0o777) == 0o600
    }

    private static func isSafeDirectory(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFDIR
            && info.st_uid == geteuid()
            && Int(info.st_mode & 0o777) == 0o700
    }

    private static func sameFileIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    private static func maximumEnvelopeBytes(for kind: ArchiveEnvelopeKind) -> Int64 {
        let rawBytes: Int
        switch kind {
        case .object: rawBytes = ArchiveV2ProtocolLimits.maxObjectRawBytes
        case .manifest: rawBytes = ArchiveV2ProtocolLimits.maxManifestBytes
        case .receipt: rawBytes = ArchiveV2ProtocolLimits.maxReceiptBytes
        }
        return Int64(rawBytes + 48 + 12 + 16)
    }

    private static func isSafeServerID(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && value.utf8.count <= ArchiveV2ProtocolLimits.maxServerIDBytes
            && value.utf8.allSatisfy { byte in
                (48...57).contains(byte)
                    || (65...90).contains(byte)
                    || (97...122).contains(byte)
                    || byte == 45
                    || byte == 46
                    || byte == 95
            }
    }

    private static func isSafeArchiveRoot(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        return url.isFileURL
            && path.hasPrefix("/")
            && path != "/"
            && path != home
            && url.pathComponents.count >= 3
    }

    private static func currentTimestamp() -> String {
        timestampFormatter().string(from: Date())
    }

    private static func isCanonicalTimestamp(_ value: String) -> Bool {
        let formatter = timestampFormatter()
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }

    private static func timestampFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }
}
