import CryptoKit
import Darwin
import EngramCoreRead
import Foundation

public enum CaptureIngestReplayQuarantineReason: String, Equatable, Sendable {
    case invalidManifest
    case manifestMismatch
    case unsupportedCaptureShape
    case bindingMismatch
    case invalidReplayLayout
    case sourceIntegrityMismatch
    case sourceMismatch
    case unsafeStaging
    case invalidNativeIdentity
}

public enum CaptureIngestReplayRetryReason: String, Equatable, Sendable {
    case casUnavailable
    case stagingUnavailable
}

public enum CaptureIngestReplayError: Error, Equatable, Sendable {
    case quarantined(CaptureIngestReplayQuarantineReason)
    case retryable(CaptureIngestReplayRetryReason)
    case parseFailed(ParserFailure)
}

public struct CaptureIngestReplayResult: Sendable {
    public let publicationSHA256: String
    public let verifiedManifest: ArchiveSourceManifest
    public let bindingSnapshot: CaptureIngestSourceBinding
    public let scan: IndexingScan
    public let rawSourceSessionID: String
    public let nativeIdentity: CaptureIngestIdentity
    public let parentIdentity: CaptureIngestIdentity?
    public let suggestedParentIdentity: CaptureIngestIdentity?
}

struct CaptureIngestReplayTestHooks: Sendable {
    let beforeParse: (@Sendable (URL) throws -> Void)?
    let afterParse: (@Sendable (URL) throws -> Void)?

    init(
        beforeParse: (@Sendable (URL) throws -> Void)? = nil,
        afterParse: (@Sendable (URL) throws -> Void)? = nil
    ) {
        self.beforeParse = beforeParse
        self.afterParse = afterParse
    }
}

/// Produces an immutable-byte parse artifact, not authority to publish a session.
/// The writer must recheck registry eligibility and this complete binding snapshot
/// at commit time, without holding its database transaction across replay awaits.
public enum CaptureIngestReplay {
    public static func replay(
        publication: CollectorPublicationEnvelope,
        bindingSnapshot: CaptureIngestSourceBinding,
        cas: ImmutableArchiveCAS,
        stagingParent: URL
    ) async throws -> CaptureIngestReplayResult {
        try await replay(
            publication: publication, bindingSnapshot: bindingSnapshot,
            cas: cas, stagingParent: stagingParent, testHooks: CaptureIngestReplayTestHooks()
        )
    }

    static func replay(
        publication: CollectorPublicationEnvelope,
        bindingSnapshot: CaptureIngestSourceBinding,
        cas: ImmutableArchiveCAS,
        stagingParent: URL,
        testHooks: CaptureIngestReplayTestHooks
    ) async throws -> CaptureIngestReplayResult {
        try Task.checkCancellation()
        let manifest: ArchiveSourceManifest
        do {
            let bytes = try cas.readManifest(
                sha256: publication.manifestSHA256,
                maximumByteCount: Int64(ArchiveV2ProtocolLimits.maxManifestBytes)
            )
            manifest = try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: bytes)
        } catch is CancellationError {
            throw CancellationError()
        } catch ImmutableArchiveCASError.io {
            throw CaptureIngestReplayError.retryable(.casUnavailable)
        } catch {
            throw CaptureIngestReplayError.quarantined(.invalidManifest)
        }
        guard let manifestMachine = UUID(uuidString: manifest.machineID)?.uuidString,
              exact(manifestMachine, publication.machineID) else {
            throw CaptureIngestReplayError.quarantined(.manifestMismatch)
        }
        guard exact(publication.representation, "exact-source-v1"), manifest.sessionID == nil,
              manifest.source == SourceName.claudeCode.rawValue || manifest.source == SourceName.codex.rawValue,
              manifest.replayLayout.strategy == .singleFile,
              manifest.replayLayout.relativePaths.count == 1,
              manifest.locator.hasSuffix(".jsonl") else {
            throw CaptureIngestReplayError.quarantined(.unsupportedCaptureShape)
        }
        let format = try validatedFormat(publication: publication, binding: bindingSnapshot, manifest: manifest)
        let relativePath = try validatedRelativePath(manifest: manifest, binding: bindingSnapshot)
        guard manifest.rawByteCount <= SessionAdapterFactory.maximumCapturedSourceBytes else {
            throw CaptureIngestReplayError.parseFailed(.fileTooLarge)
        }
        let stage = try Staging.create(parent: stagingParent, relativePath: relativePath)
        let outcome: Result<CaptureIngestReplayResult, Error>
        do {
            var whole = SHA256()
            var byteCount: Int64 = 0
            for chunk in manifest.chunks {
                try Task.checkCancellation()
                let bytes: Data
                do {
                    bytes = try cas.readObject(sha256: chunk.rawSHA256, maximumByteCount: chunk.rawByteCount)
                } catch is CancellationError {
                    throw CancellationError()
                } catch ImmutableArchiveCASError.io {
                    throw CaptureIngestReplayError.retryable(.casUnavailable)
                } catch {
                    throw CaptureIngestReplayError.quarantined(.sourceIntegrityMismatch)
                }
                guard Int64(bytes.count) == chunk.rawByteCount,
                      ArchiveV2Hash.sha256(bytes) == chunk.rawSHA256,
                      Int64(bytes.count) <= manifest.rawByteCount - byteCount else {
                    throw CaptureIngestReplayError.quarantined(.sourceIntegrityMismatch)
                }
                try stage.append(bytes)
                whole.update(data: bytes)
                byteCount += Int64(bytes.count)
            }
            guard byteCount == manifest.rawByteCount, hex(whole.finalize()) == manifest.wholeSourceSHA256 else {
                throw CaptureIngestReplayError.quarantined(.sourceIntegrityMismatch)
            }
            try stage.seal(byteCount: manifest.rawByteCount)
            try testHooks.beforeParse?(stage.fileURL)
            try stage.verify(byteCount: manifest.rawByteCount, sha256: manifest.wholeSourceSHA256)
            let parsed = try await SessionAdapterFactory.scanCapturedSource(
                physicalLocator: stage.fileURL.path, stagingRoot: stage.rootURL.path,
                logicalLocator: manifest.locator, format: format
            )
            try Task.checkCancellation()
            try testHooks.afterParse?(stage.fileURL)
            try stage.verify(byteCount: manifest.rawByteCount, sha256: manifest.wholeSourceSHA256)
            let captured = try requireCompleteScan(parsed)
            guard exact(captured.scan.info.source.rawValue, manifest.source),
                  captured.scan.info.source == bindingSnapshot.source else {
                throw CaptureIngestReplayError.quarantined(.sourceMismatch)
            }
            let identity: CaptureIngestIdentity
            let parent: CaptureIngestIdentity?
            let suggestedParent: CaptureIngestIdentity?
            do {
                identity = try CaptureIngestIdentity(
                    machineID: publication.machineID, sourceInstanceID: publication.sourceInstanceID,
                    source: captured.scan.info.source, nativeID: captured.scan.info.id
                )
                parent = try captured.scan.info.parentSessionId.map { try identity.mapping(nativeID: $0) }
                suggestedParent = try captured.scan.info.suggestedParentId.map { try identity.mapping(nativeID: $0) }
            } catch {
                throw CaptureIngestReplayError.quarantined(.invalidNativeIdentity)
            }
            outcome = .success(CaptureIngestReplayResult(
                publicationSHA256: try publication.sha256(), verifiedManifest: manifest,
                bindingSnapshot: bindingSnapshot, scan: captured.scan,
                rawSourceSessionID: captured.rawSourceSessionID, nativeIdentity: identity,
                parentIdentity: parent, suggestedParentIdentity: suggestedParent
            ))
        } catch {
            outcome = .failure(error)
        }
        let primaryError: Error?
        switch outcome {
        case .success: primaryError = nil
        case .failure(let error): primaryError = error
        }
        try finishStaging(primaryError: primaryError) { try stage.cleanup() }
        try Task.checkCancellation()
        return try outcome.get()
    }

    static func requireCompleteScan(
        _ result: AdapterParseResult<CapturedSourceScan>
    ) throws -> CapturedSourceScan {
        switch result {
        case .success(let captured):
            if let failure = captured.scan.parseFailure { throw CaptureIngestReplayError.parseFailed(failure) }
            return captured
        case .failure(let failure): throw CaptureIngestReplayError.parseFailed(failure)
        }
    }

    static func finishStaging(primaryError: Error?, cleanup: () throws -> Void) throws {
        do {
            try cleanup()
        } catch {
            CoreWriteLogger(category: "capture-ingest").error("capture replay staging cleanup failed")
            if let primaryError { throw primaryError }
            throw CaptureIngestReplayError.retryable(.stagingUnavailable)
        }
        if let primaryError { throw primaryError }
    }

    private static func validatedFormat(
        publication: CollectorPublicationEnvelope, binding: CaptureIngestSourceBinding, manifest: ArchiveSourceManifest
    ) throws -> SourceMetadataProjection.Format {
        guard exact(binding.machineID, publication.machineID),
              exact(binding.sourceInstanceID, publication.sourceInstanceID),
              exact(binding.approvedEpoch, publication.collectorEpoch), binding.authorityGeneration > 0,
              exact(binding.source.rawValue, manifest.source) else {
            throw CaptureIngestReplayError.quarantined(.bindingMismatch)
        }
        switch (binding.source, binding.parseFormat) {
        case (.claudeCode, .claudeDefault): return .claudeCode(forceClaudeCodeSource: false)
        case (.claudeCode, .claudeCustomProfile): return .claudeCode(forceClaudeCodeSource: true)
        case (.codex, .codex): return .codex
        default: throw CaptureIngestReplayError.quarantined(.bindingMismatch)
        }
    }

    private static func validatedRelativePath(manifest: ArchiveSourceManifest, binding: CaptureIngestSourceBinding) throws -> String {
        let root = binding.configuredRoot
        let locator = manifest.locator
        guard canonicalAbsolutePath(root), canonicalAbsolutePath(locator) else {
            throw CaptureIngestReplayError.quarantined(.invalidReplayLayout)
        }
        let prefix = root + "/"
        guard locator.utf8.starts(with: prefix.utf8) else {
            throw CaptureIngestReplayError.quarantined(.invalidReplayLayout)
        }
        let relative = String(decoding: locator.utf8.dropFirst(prefix.utf8.count), as: UTF8.self)
        let layout = manifest.replayLayout.relativePaths[0]
        if exact(layout, relative) { return layout }
        let leaf = root.split(separator: "/").last.map(String.init) ?? ""
        if binding.source == .codex, leaf == "sessions" || leaf == "archived_sessions",
           exact(layout, leaf + "/" + relative) { return layout }
        throw CaptureIngestReplayError.quarantined(.invalidReplayLayout)
    }

    private static func canonicalAbsolutePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path != "/", !path.utf8.contains(0) else { return false }
        return path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    private static func exact(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.elementsEqual(rhs.utf8) }
    private static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    /// Descriptors pin the single owned replay tree. Client locators never enter
    /// these filesystem operations; they remain lexical parser metadata only.
    private final class Staging {
        private struct Identity: Equatable {
            let device: dev_t
            let inode: ino_t
            let owner: uid_t
            let mode: mode_t
            let links: nlink_t
            let size: off_t
            let modifiedSeconds: Int
            let modifiedNanos: Int
            let changedSeconds: Int
            let changedNanos: Int

            init(_ value: stat) {
                device = value.st_dev; inode = value.st_ino; owner = value.st_uid
                mode = value.st_mode; links = value.st_nlink; size = value.st_size
                modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanos = value.st_mtimespec.tv_nsec
                changedSeconds = value.st_ctimespec.tv_sec; changedNanos = value.st_ctimespec.tv_nsec
            }

            func sameInode(_ other: Self) -> Bool { device == other.device && inode == other.inode }
            var safeDirectory: Bool { mode & S_IFMT == S_IFDIR && mode & 0o777 == 0o700 && owner == geteuid() }
            var safeFile: Bool { mode & S_IFMT == S_IFREG && mode & 0o777 == 0o600 && owner == geteuid() && links == 1 }
        }

        private struct Directory {
            let descriptor: Int32
            let parentDescriptor: Int32
            let name: String
            var identity: Identity
        }

        let rootURL: URL
        let fileURL: URL
        private let parentURL: URL
        private let parentDescriptor: Int32
        private let parentIdentity: Identity
        private let rootName: String
        private let fileName: String
        private var directories: [Directory] = []
        private var fileDescriptor: Int32 = -1
        private var fileIdentity: Identity?
        private var createdRoot = false

        private init(parent: URL, parentDescriptor: Int32, identity: Identity, relativePath: String) {
            parentURL = parent
            self.parentDescriptor = parentDescriptor
            parentIdentity = identity
            rootName = ".capture-replay-" + UUID().uuidString
            rootURL = parent.appendingPathComponent(rootName, isDirectory: true)
            fileURL = rootURL.appendingPathComponent(relativePath)
            fileName = relativePath.split(separator: "/").last.map(String.init) ?? ""
        }

        deinit {
            if fileDescriptor >= 0 { _ = Darwin.close(fileDescriptor) }
            for directory in directories.reversed() { _ = Darwin.close(directory.descriptor) }
            _ = Darwin.close(parentDescriptor)
        }

        static func create(parent: URL, relativePath: String) throws -> Staging {
            let descriptor = try openParent(parent)
            let stage: Staging
            do {
                stage = Staging(parent: parent, parentDescriptor: descriptor, identity: try identity(descriptor), relativePath: relativePath)
            } catch {
                _ = Darwin.close(descriptor)
                throw error
            }
            do {
                guard stage.fileURL.path.utf8.count < Int(PATH_MAX),
                      relativePath.split(separator: "/").allSatisfy({ $0.utf8.count <= Int(NAME_MAX) }) else {
                    throw CaptureIngestReplayError.quarantined(.invalidReplayLayout)
                }
                guard Darwin.mkdirat(descriptor, stage.rootName, 0o700) == 0 else { throw unavailable() }
                stage.createdRoot = true
                try stage.openCreatedDirectory(parent: descriptor, name: stage.rootName)
                for component in relativePath.split(separator: "/").dropLast() {
                    try Task.checkCancellation()
                    let parent = stage.directories.last!.descriptor
                    guard Darwin.mkdirat(parent, String(component), 0o700) == 0 else { throw unavailable() }
                    try stage.openCreatedDirectory(parent: parent, name: String(component))
                }
                stage.fileDescriptor = Darwin.openat(
                    stage.directories.last!.descriptor, stage.fileName,
                    O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600
                )
                guard stage.fileDescriptor >= 0 else { throw unavailable() }
                stage.fileIdentity = try identity(stage.fileDescriptor)
                try stage.verifyLinks(sealed: false)
                return stage
            } catch {
                let primary = error
                try finishStaging(primaryError: primary) { try stage.cleanup() }
                throw primary
            }
        }

        func append(_ bytes: Data) throws {
            try bytes.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    try Task.checkCancellation()
                    let count = Darwin.write(fileDescriptor, base.advanced(by: offset), buffer.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw Self.unavailable() }
                    offset += count
                }
            }
        }

        func seal(byteCount: Int64) throws {
            try verifyLinks(sealed: false)
            for index in directories.indices {
                directories[index].identity = try Self.identity(directories[index].descriptor)
            }
            fileIdentity = try Self.identity(fileDescriptor)
            guard fileIdentity?.size == byteCount else { throw Self.unsafe() }
        }

        func verify(byteCount: Int64, sha256: String) throws {
            try Task.checkCancellation()
            try verifyLinks(sealed: true)
            guard fileIdentity?.size == byteCount else { throw Self.unsafe() }
            var hasher = SHA256()
            var offset: Int64 = 0
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                try Task.checkCancellation()
                let limit = Int(min(Int64(buffer.count), byteCount - offset + 1))
                let count = buffer.withUnsafeMutableBytes { Darwin.pread(fileDescriptor, $0.baseAddress, limit, off_t(offset)) }
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw Self.unavailable() }
                if count == 0 { break }
                guard Int64(count) <= byteCount - offset else { throw Self.unsafe() }
                hasher.update(data: Data(buffer.prefix(count)))
                offset += Int64(count)
            }
            guard offset == byteCount, hex(hasher.finalize()) == sha256 else { throw Self.unsafe() }
            try verifyLinks(sealed: true)
        }

        private func verifyLinks(sealed: Bool) throws {
            let currentParent = try Self.openParent(parentURL)
            defer { _ = Darwin.close(currentParent) }
            guard try Self.identity(currentParent).sameInode(parentIdentity) else { throw Self.unsafe() }
            for directory in directories {
                let descriptor = try Self.identity(directory.descriptor)
                let path = try Self.identity(parent: directory.parentDescriptor, name: directory.name)
                guard descriptor.safeDirectory, path.safeDirectory,
                      descriptor.sameInode(directory.identity), path.sameInode(descriptor),
                      !sealed || (descriptor == directory.identity && path == descriptor) else { throw Self.unsafe() }
            }
            guard let expected = fileIdentity, let parent = directories.last?.descriptor else { throw Self.unsafe() }
            let descriptor = try Self.identity(fileDescriptor)
            let path = try Self.identity(parent: parent, name: fileName)
            guard descriptor.safeFile, path.safeFile, descriptor.sameInode(expected), path.sameInode(descriptor),
                  !sealed || (descriptor == expected && path == descriptor) else { throw Self.unsafe() }
        }

        private func openCreatedDirectory(parent: Int32, name: String) throws {
            let path = try Self.identity(parent: parent, name: name)
            guard path.safeDirectory else { throw Self.unsafe() }
            let descriptor = Darwin.openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw Self.unavailable() }
            do {
                let opened = try Self.identity(descriptor)
                guard opened.safeDirectory, opened.sameInode(path) else { throw Self.unsafe() }
                directories.append(Directory(descriptor: descriptor, parentDescriptor: parent, name: name, identity: opened))
            } catch {
                _ = Darwin.close(descriptor)
                throw error
            }
        }

        func cleanup() throws {
            guard createdRoot else { return }
            if let root = directories.first {
                try Self.removeContents(root.descriptor)
                let path = try Self.identity(parent: parentDescriptor, name: rootName)
                guard path.sameInode(root.identity), path.mode & S_IFMT == S_IFDIR else { throw Self.unavailable() }
            }
            guard Darwin.unlinkat(parentDescriptor, rootName, AT_REMOVEDIR) == 0 else { throw Self.unavailable() }
            createdRoot = false
        }

        /// Do not follow a replaced child, even while cleaning a failed replay.
        private static func removeContents(_ descriptor: Int32) throws {
            let duplicate = Darwin.dup(descriptor)
            guard duplicate >= 0 else { throw unavailable() }
            guard let stream = Darwin.fdopendir(duplicate) else {
                _ = Darwin.close(duplicate)
                throw unavailable()
            }
            defer { _ = Darwin.closedir(stream) }
            while true {
                errno = 0
                guard let entry = Darwin.readdir(stream) else {
                    if errno != 0 { throw unavailable() }
                    break
                }
                let name = withUnsafeBytes(of: entry.pointee.d_name) {
                    String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
                }
                if name == "." || name == ".." { continue }
                let before = try identity(parent: descriptor, name: name)
                if before.mode & S_IFMT == S_IFDIR {
                    let child = Darwin.openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw unavailable() }
                    do {
                        guard try identity(child).sameInode(before) else { throw unavailable() }
                        try removeContents(child)
                        guard try identity(parent: descriptor, name: name).sameInode(before),
                              Darwin.unlinkat(descriptor, name, AT_REMOVEDIR) == 0 else { throw unavailable() }
                        _ = Darwin.close(child)
                    } catch {
                        _ = Darwin.close(child)
                        throw error
                    }
                } else if Darwin.unlinkat(descriptor, name, 0) != 0 {
                    throw unavailable()
                }
            }
        }

        private static func openParent(_ parent: URL) throws -> Int32 {
            guard parent.isFileURL, canonicalAbsolutePath(parent.path) else { throw unsafe() }
            var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard descriptor >= 0 else { throw unavailable() }
            do {
                for component in parent.path.split(separator: "/") {
                    let child = Darwin.openat(descriptor, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else {
                        if errno == ELOOP || errno == ENOTDIR { throw unsafe() }
                        throw unavailable()
                    }
                    _ = Darwin.close(descriptor)
                    descriptor = child
                }
                guard try identity(descriptor).safeDirectory else { throw unsafe() }
                return descriptor
            } catch {
                _ = Darwin.close(descriptor)
                throw error
            }
        }

        private static func identity(_ descriptor: Int32) throws -> Identity {
            var value = stat()
            guard Darwin.fstat(descriptor, &value) == 0 else { throw unavailable() }
            return Identity(value)
        }

        private static func identity(parent: Int32, name: String) throws -> Identity {
            var value = stat()
            guard Darwin.fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else { throw unsafe() }
            return Identity(value)
        }

        private static func unavailable() -> CaptureIngestReplayError { .retryable(.stagingUnavailable) }
        private static func unsafe() -> CaptureIngestReplayError { .quarantined(.unsafeStaging) }
    }
}
