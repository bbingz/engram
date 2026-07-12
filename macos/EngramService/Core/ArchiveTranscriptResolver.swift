import CryptoKit
import Darwin
import EngramCoreRead
import EngramCoreWrite
import Foundation

public enum ArchiveTranscriptTier: String, Equatable, Sendable {
    case live
    case local
    case hq
    case m1
}

public struct ArchiveTranscriptResolution<Value: Sendable>: Sendable {
    public let tier: ArchiveTranscriptTier
    public let value: Value

    public init(tier: ArchiveTranscriptTier, value: Value) {
        self.tier = tier
        self.value = value
    }
}

public struct ArchiveRemoteRecoveryProof: Equatable, Sendable {
    public let tier: ArchiveTranscriptTier
    public let receiptSHA256: String
    public let manifestSHA256: String
    public let wholeSourceSHA256: String
}

public enum ArchiveTranscriptResolverError: Error, Equatable, Sendable {
    case invalidSessionID
    case invalidReplicaBackend
    case liveUnavailable(code: Int32)
    case unsafeLiveFile
    case archiveParseFailed
    case archiveCorrupt
    case archiveUnavailable
    case unsafeTemporaryParent
    case temporaryStorageFailure(operation: String, code: Int32)
}

struct ArchiveTranscriptResolverTestHooks: Sendable {
    let latestBinding: (@Sendable (String) throws -> ArchiveBinding?)?
    let capture: (@Sendable (String) throws -> ArchiveCapture?)?
    let remoteReplaySelected: (@Sendable (URL) throws -> Void)?

    init(
        latestBinding: (@Sendable (String) throws -> ArchiveBinding?)? = nil,
        capture: (@Sendable (String) throws -> ArchiveCapture?)? = nil,
        remoteReplaySelected: (@Sendable (URL) throws -> Void)? = nil
    ) {
        self.latestBinding = latestBinding
        self.capture = capture
        self.remoteReplaySelected = remoteReplaySelected
    }
}

/// Selects one exact transcript source before invoking its parser. Archive
/// locators are audit evidence only: replay always uses a private temporary
/// path, while the live path is supplied independently by the current session.
public struct ArchiveTranscriptResolver: Sendable {
    private let catalog: ArchiveCatalog
    private let cas: ImmutableArchiveCAS
    private let hq: (any ArchiveReplicaBackend)?
    private let m1: (any ArchiveReplicaBackend)?
    private let temporaryParent: URL
    private let temporaryParentIdentity: TemporaryParentIdentity
    private let testHooks: ArchiveTranscriptResolverTestHooks

    public init(
        catalog: ArchiveCatalog,
        cas: ImmutableArchiveCAS,
        hq: (any ArchiveReplicaBackend)? = nil,
        m1: (any ArchiveReplicaBackend)? = nil,
        temporaryParent: URL
    ) throws {
        try self.init(
            catalog: catalog,
            cas: cas,
            hq: hq,
            m1: m1,
            temporaryParent: temporaryParent,
            testHooks: ArchiveTranscriptResolverTestHooks()
        )
    }

    init(
        catalog: ArchiveCatalog,
        cas: ImmutableArchiveCAS,
        hq: (any ArchiveReplicaBackend)? = nil,
        m1: (any ArchiveReplicaBackend)? = nil,
        temporaryParent: URL,
        testHooks: ArchiveTranscriptResolverTestHooks
    ) throws {
        guard hq == nil || hq?.replicaID == "hq",
              m1 == nil || m1?.replicaID == "m1" else {
            throw ArchiveTranscriptResolverError.invalidReplicaBackend
        }
        let canonicalTemporaryParent = temporaryParent.standardizedFileURL
        let temporaryParentIdentity = try Self.validateTemporaryParent(
            canonicalTemporaryParent
        )
        self.catalog = catalog
        self.cas = cas
        self.hq = hq
        self.m1 = m1
        self.temporaryParent = canonicalTemporaryParent
        self.temporaryParentIdentity = temporaryParentIdentity
        self.testHooks = testHooks
    }

    public func withResolvedFile<Value: Sendable>(
        sessionID: String,
        liveURL: URL?,
        _ parser: @Sendable (URL) async throws -> Value
    ) async throws -> ArchiveTranscriptResolution<Value> {
        try await withResolvedFileAndSource(
            sessionID: sessionID,
            liveURL: liveURL,
            liveSource: nil
        ) { url, _ in
            try await parser(url)
        }
    }

    /// Verifies one persisted remote archive end-to-end without consulting the
    /// live source or local CAS and without invoking a transcript parser.
    public func remoteRecoveryProbe(
        sessionID: String
    ) async throws -> ArchiveRemoteRecoveryProof {
        let locked = try lockedManifest(sessionID: sessionID)
        let selected = try await selectVerifiedRemoteReplay(locked)
        let preCleanupResult: Result<Void, Error>
        do {
            try testHooks.remoteReplaySelected?(selected.replay.fileURL)
            try Task.checkCancellation()
            preCleanupResult = .success(())
        } catch {
            preCleanupResult = .failure(error)
        }
        try Self.cleanupChecked(selected.replay)
        try preCleanupResult.get()
        try Task.checkCancellation()
        return ArchiveRemoteRecoveryProof(
            tier: selected.replay.tier,
            receiptSHA256: selected.persistedReceipt.sha256,
            manifestSHA256: locked.binding.manifestSHA256,
            wholeSourceSHA256: locked.manifest.wholeSourceSHA256
        )
    }

    public func withResolvedFile<Value: Sendable>(
        sessionID: String,
        liveURL: URL?,
        liveSource: String,
        _ parser: @Sendable (URL, String) async throws -> Value
    ) async throws -> ArchiveTranscriptResolution<Value> {
        try await withResolvedFileAndSource(
            sessionID: sessionID,
            liveURL: liveURL,
            liveSource: liveSource
        ) { url, resolvedSource in
            guard let resolvedSource else {
                throw ArchiveTranscriptResolverError.archiveCorrupt
            }
            return try await parser(url, resolvedSource)
        }
    }

    private func withResolvedFileAndSource<Value: Sendable>(
        sessionID: String,
        liveURL: URL?,
        liveSource: String?,
        _ parser: @Sendable (URL, String?) async throws -> Value
    ) async throws -> ArchiveTranscriptResolution<Value> {
        guard !sessionID.isEmpty else {
            throw ArchiveTranscriptResolverError.invalidSessionID
        }
        try Task.checkCancellation()

        if let liveURL {
            let canonicalLiveURL = liveURL.standardizedFileURL
            if let replay = try replayFromLive(canonicalLiveURL) {
                return try await parse(
                    replay,
                    source: liveSource,
                    using: parser
                )
            }
        }

        try Task.checkCancellation()
        let locked: LockedManifest
        do {
            locked = try lockedManifest(sessionID: sessionID)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ArchiveTranscriptResolverError {
            throw error
        } catch {
            throw ArchiveTranscriptResolverError.archiveCorrupt
        }

        var sawCorruption = false
        let localReplay: ReplayFile?
        do {
            localReplay = try replayFromLocalIfValid(locked)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ArchiveTranscriptResolverError {
            localReplay = nil
            switch error {
            case .archiveCorrupt:
                sawCorruption = true
            case .archiveUnavailable:
                break
            case .temporaryStorageFailure, .unsafeTemporaryParent:
                throw error
            default:
                throw error
            }
        } catch {
            sawCorruption = true
            localReplay = nil
        }
        if let localReplay {
            return try await parse(
                localReplay,
                source: locked.manifest.source,
                using: parser
            )
        }

        let selected: RemoteReplaySelection?
        do {
            selected = try await selectVerifiedRemoteReplay(locked)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ArchiveTranscriptResolverError {
            switch error {
            case .temporaryStorageFailure, .unsafeTemporaryParent:
                throw error
            case .archiveCorrupt:
                sawCorruption = true
            default:
                break
            }
            selected = nil
        }
        if let selected {
            // Parsing is deliberately outside the tier-selection catch scope:
            // once bytes are selected and verified, parser errors are final.
            return try await parse(
                selected.replay,
                source: locked.manifest.source,
                using: parser
            )
        }

        throw sawCorruption
            ? ArchiveTranscriptResolverError.archiveCorrupt
            : ArchiveTranscriptResolverError.archiveUnavailable
    }

    private func lockedManifest(sessionID: String) throws -> LockedManifest {
        guard !sessionID.isEmpty else {
            throw ArchiveTranscriptResolverError.invalidSessionID
        }
        try Task.checkCancellation()
        let binding: ArchiveBinding
        do {
            guard let latest = try readLatestBinding(sessionID: sessionID) else {
                throw ArchiveTranscriptResolverError.archiveUnavailable
            }
            binding = latest
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ArchiveTranscriptResolverError {
            throw error
        } catch {
            throw Self.isStructuralCatalogError(error)
                ? ArchiveTranscriptResolverError.archiveCorrupt
                : ArchiveTranscriptResolverError.archiveUnavailable
        }
        do {
            return try lockAndValidate(binding: binding, sessionID: sessionID)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ArchiveTranscriptResolverError {
            throw error
        } catch {
            throw ArchiveTranscriptResolverError.archiveCorrupt
        }
    }

    private func selectVerifiedRemoteReplay(
        _ locked: LockedManifest
    ) async throws -> RemoteReplaySelection {
        var sawCorruption = false
        for (tier, backend) in [(ArchiveTranscriptTier.hq, hq), (.m1, m1)] {
            try Task.checkCancellation()
            guard let backend else { continue }
            let replicaID = tier.rawValue
            let persistedReceipt: ArchiveVerifiedReceipt
            do {
                guard let receipt = try catalog.currentVerifiedReceipt(
                    manifestSHA256: locked.binding.manifestSHA256,
                    replicaID: replicaID
                ) else { continue }
                persistedReceipt = receipt
            } catch is CancellationError {
                throw CancellationError()
            } catch is ArchiveCatalogError {
                sawCorruption = true
                continue
            } catch {
                continue
            }
            do {
                try Self.validatePersistedReceipt(
                    persistedReceipt,
                    replicaID: replicaID,
                    locked: locked
                )
                let replay = try await replayFromRemote(
                    locked,
                    persistedReceipt: persistedReceipt,
                    replicaID: replicaID,
                    backend: backend,
                    tier: tier
                )
                return RemoteReplaySelection(
                    replay: replay,
                    persistedReceipt: persistedReceipt
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ArchiveReplicaBackendError
                where error == .transport(.cancelled) {
                throw CancellationError()
            } catch let error as ArchiveReplicaBackendError {
                if Self.isBackendCorruption(error) { sawCorruption = true }
            } catch let error as ArchiveTranscriptResolverError {
                switch error {
                case .temporaryStorageFailure, .unsafeTemporaryParent:
                    throw error
                case .archiveCorrupt:
                    sawCorruption = true
                default:
                    break
                }
            } catch {
                sawCorruption = true
            }
        }
        throw sawCorruption
            ? ArchiveTranscriptResolverError.archiveCorrupt
            : ArchiveTranscriptResolverError.archiveUnavailable
    }

    private func parse<Value: Sendable>(
        _ replay: ReplayFile,
        source: String?,
        using parser: @Sendable (URL, String?) async throws -> Value
    ) async throws -> ArchiveTranscriptResolution<Value> {
        let value: Value
        do {
            try Task.checkCancellation()
            value = try await parser(replay.fileURL, source)
        } catch {
            let parserError = Self.normalizedParserError(error)
            try Self.cleanupChecked(replay)
            throw parserError
        }
        try Self.cleanupChecked(replay)
        return ArchiveTranscriptResolution(tier: replay.tier, value: value)
    }

    private static func normalizedParserError(_ error: Error) -> Error {
        if error is CancellationError
            || error is TranscriptSizeGuardError
            || error is ParserFailure
            || error is ArchiveTranscriptResolverError {
            return error
        }
        return ArchiveTranscriptResolverError.archiveParseFailed
    }

    private func readLatestBinding(sessionID: String) throws -> ArchiveBinding? {
        if let latestBinding = testHooks.latestBinding {
            return try latestBinding(sessionID)
        }
        return try catalog.latestBinding(sessionID: sessionID)
    }

    private func readCapture(captureID: String) throws -> ArchiveCapture? {
        if let capture = testHooks.capture {
            return try capture(captureID)
        }
        return try catalog.capture(captureID: captureID)
    }

    private func lockAndValidate(
        binding: ArchiveBinding,
        sessionID: String
    ) throws -> LockedManifest {
        try Task.checkCancellation()
        guard ArchiveV2Hash.sha256(binding.canonicalManifestBytes)
                == binding.manifestSHA256 else {
            throw ArchiveTranscriptResolverError.archiveCorrupt
        }
        let manifest = try ArchiveCanonicalJSON.decode(
            ArchiveSourceManifest.self,
            from: binding.canonicalManifestBytes
        )
        let capture: ArchiveCapture
        do {
            guard let storedCapture = try readCapture(captureID: binding.captureID) else {
                throw ArchiveTranscriptResolverError.archiveCorrupt
            }
            capture = storedCapture
        } catch let error as ArchiveTranscriptResolverError {
            throw error
        } catch {
            throw Self.isStructuralCatalogError(error)
                ? ArchiveTranscriptResolverError.archiveCorrupt
                : ArchiveTranscriptResolverError.archiveUnavailable
        }
        guard manifest.sessionID == sessionID,
              binding.sessionID == sessionID,
              manifest.captureID == binding.captureID,
              capture.captureID == manifest.captureID,
              capture.machineID == manifest.machineID,
              capture.source == manifest.source,
              capture.locator == manifest.locator,
              capture.generation == manifest.generation,
              capture.wholeSourceSHA256 == manifest.wholeSourceSHA256,
              capture.rawByteCount == manifest.rawByteCount,
              capture.chunkSize == manifest.chunkSize,
              ArchiveV2Hash.sha256(capture.unboundManifestBytes)
                == capture.unboundManifestSHA256 else {
            throw ArchiveTranscriptResolverError.archiveCorrupt
        }
        let unbound = try ArchiveCanonicalJSON.decode(
            ArchiveSourceManifest.self,
            from: capture.unboundManifestBytes
        )
        guard unbound.sessionID == nil,
              unbound.captureID == manifest.captureID,
              unbound.machineID == manifest.machineID,
              unbound.source == manifest.source,
              unbound.locator == manifest.locator,
              unbound.capturedAt == manifest.capturedAt,
              unbound.generation == manifest.generation,
              unbound.wholeSourceSHA256 == manifest.wholeSourceSHA256,
              unbound.rawByteCount == manifest.rawByteCount,
              unbound.chunkSize == manifest.chunkSize,
              unbound.chunks == manifest.chunks,
              unbound.replayLayout == manifest.replayLayout else {
            throw ArchiveTranscriptResolverError.archiveCorrupt
        }
        return LockedManifest(binding: binding, manifest: manifest)
    }

    private func replayFromLocalIfValid(_ locked: LockedManifest) throws -> ReplayFile {
        try Task.checkCancellation()
        do {
            let manifestBytes = try cas.readManifest(
                sha256: locked.binding.manifestSHA256
            )
            guard manifestBytes == locked.binding.canonicalManifestBytes else {
                throw ArchiveTranscriptResolverError.archiveCorrupt
            }
            return try writeReplay(tier: .local, manifest: locked.manifest) { chunk in
                try self.cas.readObject(sha256: chunk.rawSHA256)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ArchiveTranscriptResolverError {
            throw error
        } catch let error as ImmutableArchiveCASError {
            switch error {
            case .io:
                throw ArchiveTranscriptResolverError.archiveUnavailable
            case .invalidSHA256, .digestMismatch, .existingContentConflict,
                 .unsafeExistingPath:
                throw ArchiveTranscriptResolverError.archiveCorrupt
            }
        } catch {
            throw ArchiveTranscriptResolverError.archiveCorrupt
        }
    }

    private func replayFromRemote(
        _ locked: LockedManifest,
        persistedReceipt: ArchiveVerifiedReceipt,
        replicaID: String,
        backend: any ArchiveReplicaBackend,
        tier: ArchiveTranscriptTier
    ) async throws -> ReplayFile {
        try Task.checkCancellation()
        let receiptBytes = try await backend.getReceipt(
            manifestDigest: locked.binding.manifestSHA256
        )
        try Self.checkCancellation(after: receiptBytes)
        guard receiptBytes == persistedReceipt.canonicalBytes,
              ArchiveV2Hash.sha256(receiptBytes) == persistedReceipt.sha256 else {
            throw ArchiveTranscriptResolverError.archiveCorrupt
        }
        do {
            let receipt = try ArchiveCanonicalJSON.decode(
                ArchiveServerReceipt.self,
                from: receiptBytes
            )
            guard receipt.serverID == replicaID else {
                throw ArchiveTranscriptResolverError.archiveCorrupt
            }
            try receipt.validate(
                againstCanonicalManifestBytes: locked.binding.canonicalManifestBytes
            )
        } catch let error as ArchiveTranscriptResolverError {
            throw error
        } catch {
            throw ArchiveTranscriptResolverError.archiveCorrupt
        }

        try Task.checkCancellation()
        let manifestBytes = try await backend.getManifest(
            digest: locked.binding.manifestSHA256
        )
        try Self.checkCancellation(after: manifestBytes)
        guard manifestBytes == locked.binding.canonicalManifestBytes,
              ArchiveV2Hash.sha256(manifestBytes) == locked.binding.manifestSHA256 else {
            throw ArchiveTranscriptResolverError.archiveCorrupt
        }

        return try await writeRemoteReplay(
            tier: tier,
            manifest: locked.manifest,
            backend: backend
        )
    }

    private func writeRemoteReplay(
        tier: ArchiveTranscriptTier,
        manifest: ArchiveSourceManifest,
        backend: any ArchiveReplicaBackend
    ) async throws -> ReplayFile {
        let output = try createReplayFile(tier: tier, manifest: manifest)
        var descriptor = output.descriptor
        var succeeded = false
        defer {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            if !succeeded { Self.cleanup(output.replay) }
        }

        var wholeHasher = SHA256()
        var aggregate: Int64 = 0
        for chunk in manifest.chunks {
            try Task.checkCancellation()
            let bytes = try await backend.getObject(digest: chunk.rawSHA256)
            try Self.checkCancellation(after: bytes)
            try Self.validateAndWrite(
                bytes,
                chunk: chunk,
                descriptor: descriptor,
                wholeHasher: &wholeHasher,
                aggregate: &aggregate
            )
        }
        try Self.finishReplay(
            descriptor: descriptor,
            manifest: manifest,
            wholeHasher: wholeHasher,
            aggregate: aggregate
        )
        guard Darwin.close(descriptor) == 0 else {
            descriptor = -1
            throw Self.tempIO("close", code: errno)
        }
        descriptor = -1
        succeeded = true
        return output.replay
    }

    private func replayFromLive(_ url: URL) throws -> ReplayFile? {
        guard url.isFileURL else {
            throw ArchiveTranscriptResolverError.unsafeLiveFile
        }
        let sourceFD = Darwin.open(
            url.path,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard sourceFD >= 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR {
                return nil
            }
            if code == ELOOP {
                throw ArchiveTranscriptResolverError.unsafeLiveFile
            }
            throw ArchiveTranscriptResolverError.liveUnavailable(code: code)
        }
        defer { _ = Darwin.close(sourceFD) }

        var before = stat()
        guard Darwin.fstat(sourceFD, &before) == 0 else {
            throw ArchiveTranscriptResolverError.liveUnavailable(code: errno)
        }
        guard (before.st_mode & S_IFMT) == S_IFREG else {
            throw ArchiveTranscriptResolverError.unsafeLiveFile
        }

        let output = try createReplayFile(
            tier: .live,
            relativePath: url.lastPathComponent
        )
        var outputFD = output.descriptor
        var succeeded = false
        defer {
            if outputFD >= 0 { _ = Darwin.close(outputFD) }
            if !succeeded { Self.cleanup(output.replay) }
        }

        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var copiedByteCount: Int64 = 0
        while true {
            try Task.checkCancellation()
            let readCount = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(sourceFD, rawBuffer.baseAddress, rawBuffer.count)
            }
            if readCount < 0, errno == EINTR { continue }
            guard readCount >= 0 else {
                throw ArchiveTranscriptResolverError.liveUnavailable(code: errno)
            }
            if readCount == 0 { break }
            let (nextCount, overflow) = copiedByteCount.addingReportingOverflow(
                Int64(readCount)
            )
            guard !overflow else {
                throw ArchiveTranscriptResolverError.liveUnavailable(code: EOVERFLOW)
            }
            try buffer.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                try Self.writeAll(
                    baseAddress: baseAddress,
                    count: readCount,
                    descriptor: outputFD
                )
            }
            copiedByteCount = nextCount
        }

        var after = stat()
        guard Darwin.fstat(sourceFD, &after) == 0 else {
            throw ArchiveTranscriptResolverError.liveUnavailable(code: errno)
        }
        guard Self.sameLiveFile(before: before, after: after),
              copiedByteCount == before.st_size else {
            throw ArchiveTranscriptResolverError.liveUnavailable(code: ESTALE)
        }
        guard Darwin.fsync(outputFD) == 0 else {
            throw Self.tempIO("fsync-live", code: errno)
        }
        guard Darwin.close(outputFD) == 0 else {
            outputFD = -1
            throw Self.tempIO("close-live", code: errno)
        }
        outputFD = -1
        succeeded = true
        return output.replay
    }

    private func writeReplay(
        tier: ArchiveTranscriptTier,
        manifest: ArchiveSourceManifest,
        readChunk: (ArchiveChunkReference) throws -> Data
    ) throws -> ReplayFile {
        let output = try createReplayFile(tier: tier, manifest: manifest)
        var descriptor = output.descriptor
        var succeeded = false
        defer {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            if !succeeded { Self.cleanup(output.replay) }
        }

        var wholeHasher = SHA256()
        var aggregate: Int64 = 0
        for chunk in manifest.chunks {
            try Task.checkCancellation()
            let bytes = try readChunk(chunk)
            try Self.validateAndWrite(
                bytes,
                chunk: chunk,
                descriptor: descriptor,
                wholeHasher: &wholeHasher,
                aggregate: &aggregate
            )
        }
        try Self.finishReplay(
            descriptor: descriptor,
            manifest: manifest,
            wholeHasher: wholeHasher,
            aggregate: aggregate
        )
        guard Darwin.close(descriptor) == 0 else {
            descriptor = -1
            throw Self.tempIO("close", code: errno)
        }
        descriptor = -1
        succeeded = true
        return output.replay
    }

    private func createReplayFile(
        tier: ArchiveTranscriptTier,
        manifest: ArchiveSourceManifest
    ) throws -> (replay: ReplayFile, descriptor: Int32) {
        guard let relativePath = manifest.replayLayout.relativePaths.first else {
            throw ArchiveTranscriptResolverError.archiveCorrupt
        }
        return try createReplayFile(tier: tier, relativePath: relativePath)
    }

    private func createReplayFile(
        tier: ArchiveTranscriptTier,
        relativePath: String
    ) throws -> (replay: ReplayFile, descriptor: Int32) {
        try Task.checkCancellation()
        let currentParentIdentity = try Self.validateTemporaryParent(temporaryParent)
        guard currentParentIdentity == temporaryParentIdentity else {
            throw ArchiveTranscriptResolverError.unsafeTemporaryParent
        }
        let pathComponents = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard !relativePath.hasPrefix("/"),
              !pathComponents.isEmpty,
              pathComponents.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              let fileName = pathComponents.last else {
            throw ArchiveTranscriptResolverError.archiveCorrupt
        }
        let rootName = ".engram-transcript-\(UUID().uuidString)"
        let directory = temporaryParent.appendingPathComponent(
            rootName,
            isDirectory: true
        )
        var replayParent = directory
        for component in pathComponents.dropLast() {
            replayParent.appendPathComponent(component, isDirectory: true)
        }
        let fileURL = replayParent.appendingPathComponent(fileName, isDirectory: false)
        let replay = ReplayFile(tier: tier, directoryURL: directory, fileURL: fileURL)

        let parentFD = Darwin.open(
            temporaryParent.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard parentFD >= 0 else {
            let code = errno
            if code == ELOOP || code == ENOTDIR {
                throw ArchiveTranscriptResolverError.unsafeTemporaryParent
            }
            throw Self.tempIO("open-parent", code: code)
        }
        defer { _ = Darwin.close(parentFD) }
        var parentInfo = stat()
        guard Darwin.fstat(parentFD, &parentInfo) == 0 else {
            throw Self.tempIO("fstat-parent", code: errno)
        }
        guard temporaryParentIdentity.matches(parentInfo),
              Self.isSafeDirectory(parentInfo, exactPermissions: nil) else {
            throw ArchiveTranscriptResolverError.unsafeTemporaryParent
        }

        let rootCreated = rootName.withCString {
            Darwin.mkdirat(parentFD, $0, S_IRWXU)
        }
        guard rootCreated == 0 else {
            throw Self.tempIO("mkdir-root", code: errno)
        }
        var keepDirectory = false
        defer {
            if !keepDirectory { Self.cleanup(replay) }
        }

        var currentFD = rootName.withCString {
            Darwin.openat(
                parentFD,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard currentFD >= 0 else {
            throw Self.tempIO("open-root", code: errno)
        }
        defer {
            if currentFD >= 0 { _ = Darwin.close(currentFD) }
        }
        guard Darwin.fchmod(currentFD, S_IRWXU) == 0 else {
            throw Self.tempIO("chmod-root", code: errno)
        }
        var rootInfo = stat()
        guard Darwin.fstat(currentFD, &rootInfo) == 0 else {
            throw Self.tempIO("fstat-root", code: errno)
        }
        guard Self.isSafeDirectory(rootInfo, exactPermissions: S_IRWXU) else {
            throw ArchiveTranscriptResolverError.unsafeTemporaryParent
        }

        for component in pathComponents.dropLast() {
            try Task.checkCancellation()
            let created = component.withCString {
                Darwin.mkdirat(currentFD, $0, S_IRWXU)
            }
            guard created == 0 else {
                throw Self.tempIO("mkdir-replay", code: errno)
            }
            let nextFD = component.withCString {
                Darwin.openat(
                    currentFD,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard nextFD >= 0 else {
                throw Self.tempIO("open-replay-directory", code: errno)
            }
            guard Darwin.fchmod(nextFD, S_IRWXU) == 0 else {
                let code = errno
                _ = Darwin.close(nextFD)
                throw Self.tempIO("chmod-replay-directory", code: code)
            }
            var nextInfo = stat()
            guard Darwin.fstat(nextFD, &nextInfo) == 0 else {
                let code = errno
                _ = Darwin.close(nextFD)
                throw Self.tempIO("fstat-replay-directory", code: code)
            }
            guard Self.isSafeDirectory(nextInfo, exactPermissions: S_IRWXU) else {
                _ = Darwin.close(nextFD)
                throw ArchiveTranscriptResolverError.unsafeTemporaryParent
            }
            _ = Darwin.close(currentFD)
            currentFD = nextFD
        }

        let fd = fileName.withCString {
            Darwin.openat(
                currentFD,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        guard fd >= 0 else {
            throw Self.tempIO("open-replay-file", code: errno)
        }
        var descriptor = fd
        defer {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
        }
        guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw Self.tempIO("chmod", code: errno)
        }
        var fileInfo = stat()
        guard Darwin.fstat(descriptor, &fileInfo) == 0 else {
            throw Self.tempIO("fstat", code: errno)
        }
        guard (fileInfo.st_mode & S_IFMT) == S_IFREG,
              fileInfo.st_uid == geteuid(),
              fileInfo.st_mode & 0o777 == 0o600,
              fileInfo.st_nlink == 1 else {
            throw ArchiveTranscriptResolverError.unsafeTemporaryParent
        }

        var resolvedParentInfo = stat()
        var resolvedRootInfo = stat()
        var resolvedFileInfo = stat()
        guard Darwin.lstat(temporaryParent.path, &resolvedParentInfo) == 0,
              Darwin.lstat(directory.path, &resolvedRootInfo) == 0,
              Darwin.lstat(fileURL.path, &resolvedFileInfo) == 0,
              Self.sameNode(parentInfo, resolvedParentInfo),
              Self.sameNode(rootInfo, resolvedRootInfo),
              Self.sameNode(fileInfo, resolvedFileInfo),
              Self.isSafeDirectory(resolvedParentInfo, exactPermissions: nil),
              Self.isSafeDirectory(resolvedRootInfo, exactPermissions: S_IRWXU),
              (resolvedFileInfo.st_mode & S_IFMT) == S_IFREG,
              resolvedFileInfo.st_uid == geteuid(),
              resolvedFileInfo.st_mode & 0o777 == 0o600,
              resolvedFileInfo.st_nlink == 1 else {
            throw ArchiveTranscriptResolverError.unsafeTemporaryParent
        }
        descriptor = -1
        keepDirectory = true
        return (replay, fd)
    }

    private static func validateAndWrite(
        _ bytes: Data,
        chunk: ArchiveChunkReference,
        descriptor: Int32,
        wholeHasher: inout SHA256,
        aggregate: inout Int64
    ) throws {
        guard Int64(bytes.count) == chunk.rawByteCount,
              ArchiveV2Hash.sha256(bytes) == chunk.rawSHA256 else {
            throw ArchiveTranscriptResolverError.archiveCorrupt
        }
        let (next, overflow) = aggregate.addingReportingOverflow(Int64(bytes.count))
        guard !overflow else {
            throw ArchiveTranscriptResolverError.archiveCorrupt
        }
        try writeAll(bytes, descriptor: descriptor)
        wholeHasher.update(data: bytes)
        aggregate = next
    }

    private static func finishReplay(
        descriptor: Int32,
        manifest: ArchiveSourceManifest,
        wholeHasher: SHA256,
        aggregate: Int64
    ) throws {
        let wholeDigest = wholeHasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
        guard aggregate == manifest.rawByteCount,
              wholeDigest == manifest.wholeSourceSHA256 else {
            throw ArchiveTranscriptResolverError.archiveCorrupt
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw tempIO("fsync", code: errno)
        }
    }

    private static func validatePersistedReceipt(
        _ persisted: ArchiveVerifiedReceipt,
        replicaID: String,
        locked: LockedManifest
    ) throws {
        guard ArchiveV2Hash.sha256(persisted.canonicalBytes) == persisted.sha256 else {
            throw ArchiveTranscriptResolverError.archiveCorrupt
        }
        do {
            let receipt = try ArchiveCanonicalJSON.decode(
                ArchiveServerReceipt.self,
                from: persisted.canonicalBytes
            )
            guard receipt.serverID == replicaID else {
                throw ArchiveTranscriptResolverError.archiveCorrupt
            }
            try receipt.validate(
                againstCanonicalManifestBytes: locked.binding.canonicalManifestBytes
            )
        } catch let error as ArchiveTranscriptResolverError {
            throw error
        } catch {
            throw ArchiveTranscriptResolverError.archiveCorrupt
        }
    }

    private static func isBackendCorruption(
        _ error: ArchiveReplicaBackendError
    ) -> Bool {
        switch error {
        case .invalidDigest,
             .invalidRequest,
             .notHTTPResponse,
             .responseTooLarge,
             .redirectRejected,
             .finalURLMismatch,
             .invalidCanonicalResponse:
            true
        case .unexpectedStatus(409), .unexpectedStatus(422):
            true
        case .unexpectedStatus, .transport:
            false
        }
    }

    private static func isStructuralCatalogError(_ error: Error) -> Bool {
        if error is ArchiveCanonicalJSONError
            || error is ArchiveV2ValidationError
            || error is DecodingError {
            return true
        }
        guard let catalogError = error as? ArchiveCatalogError else {
            return false
        }
        switch catalogError {
        case .invalidMachineID,
             .databaseJournalModeNotWAL,
             .databaseSynchronousNotFull,
             .unsafeRoot,
             .unsafeDatabasePath,
             .sqliteFileControlFailed:
            return false
        case .missingMetadata,
             .manifestMachineIDMismatch,
             .captureManifestMustBeUnbound,
             .captureConflict,
             .captureNotFound,
             .captureAlreadyBound,
             .boundManifestRequiresSessionID,
             .boundManifestMismatch,
             .bindingConflict,
             .bindingNotFound,
             .invalidSHA256,
             .invalidReplicaID,
             .invalidAttempts,
             .invalidReplicaState,
             .receiptRequired,
             .unexpectedReceipt,
             .receiptDigestMismatch,
             .receiptReplicaMismatch,
             .receiptConflict,
             .invalidLimit,
             .invalidStaleInterval,
             .invalidTimestamp,
             .invalidRemoteEligibility,
             .invalidRemoteEligibilityValue,
             .invalidProjectRootSnapshot,
             .remotePolicyConflict,
             .invalidArchiveCursorPayloadSize,
             .invalidArchiveCursorCheckpoint,
             .invalidReplicaTransition,
             .invalidClaimGeneration,
             .invalidLastError:
            return true
        }
    }

    private static func sameLiveFile(before: stat, after: stat) -> Bool {
        before.st_dev == after.st_dev
            && before.st_ino == after.st_ino
            && before.st_mode == after.st_mode
            && before.st_size == after.st_size
            && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
            && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
            && before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec
            && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    }

    private static func isSafeDirectory(
        _ info: stat,
        exactPermissions: mode_t?
    ) -> Bool {
        guard (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(),
              info.st_mode & 0o077 == 0 else {
            return false
        }
        guard let exactPermissions else { return true }
        return info.st_mode & 0o777 == exactPermissions
    }

    private static func sameNode(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev
            && first.st_ino == second.st_ino
            && first.st_mode == second.st_mode
            && first.st_uid == second.st_uid
    }

    private static func validateTemporaryParent(
        _ url: URL
    ) throws -> TemporaryParentIdentity {
        guard url.isFileURL else {
            throw ArchiveTranscriptResolverError.unsafeTemporaryParent
        }
        var info = stat()
        guard Darwin.lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(),
              info.st_mode & 0o077 == 0 else {
            throw ArchiveTranscriptResolverError.unsafeTemporaryParent
        }
        return TemporaryParentIdentity(info)
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            try writeAll(
                baseAddress: base,
                count: rawBuffer.count,
                descriptor: descriptor
            )
        }
    }

    private static func writeAll(
        baseAddress: UnsafeRawPointer,
        count: Int,
        descriptor: Int32
    ) throws {
        var offset = 0
        while offset < count {
            try Task.checkCancellation()
            let written = Darwin.write(
                descriptor,
                baseAddress.advanced(by: offset),
                count - offset
            )
            if written < 0, errno == EINTR { continue }
            guard written > 0 else {
                throw tempIO("write", code: written < 0 ? errno : EIO)
            }
            offset += written
        }
    }

    private static func cleanup(_ replay: ReplayFile) {
        try? cleanupChecked(replay)
    }

    private static func cleanupChecked(_ replay: ReplayFile) throws {
        do {
            try FileManager.default.removeItem(at: replay.directoryURL)
        } catch {
            let removalCode = cleanupErrorCode(error)
            var remainingInfo = stat()
            if Darwin.lstat(replay.directoryURL.path, &remainingInfo) == 0 {
                throw tempIO("cleanup-remove", code: removalCode)
            }
            let verificationCode = errno
            guard verificationCode == ENOENT || verificationCode == ENOTDIR else {
                throw tempIO("cleanup-verify", code: verificationCode)
            }
            return
        }

        var remainingInfo = stat()
        if Darwin.lstat(replay.directoryURL.path, &remainingInfo) == 0 {
            throw tempIO("cleanup-verify", code: EIO)
        }
        let verificationCode = errno
        guard verificationCode == ENOENT || verificationCode == ENOTDIR else {
            throw tempIO("cleanup-verify", code: verificationCode)
        }
    }

    private static func cleanupErrorCode(_ error: Error) -> Int32 {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return Int32(nsError.code)
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain {
            return Int32(underlying.code)
        }
        return EIO
    }

    private static func checkCancellation(after _: Data) throws {
        try Task.checkCancellation()
    }

    private static func tempIO(
        _ operation: String,
        code: Int32
    ) -> ArchiveTranscriptResolverError {
        .temporaryStorageFailure(operation: operation, code: code)
    }
}

private struct LockedManifest: Sendable {
    let binding: ArchiveBinding
    let manifest: ArchiveSourceManifest
}

private struct RemoteReplaySelection: Sendable {
    let replay: ReplayFile
    let persistedReceipt: ArchiveVerifiedReceipt
}

private struct ReplayFile: Sendable {
    let tier: ArchiveTranscriptTier
    let directoryURL: URL
    let fileURL: URL
}

private struct TemporaryParentIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
    }

    func matches(_ info: stat) -> Bool {
        device == info.st_dev && inode == info.st_ino
    }
}
