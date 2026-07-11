import CryptoKit
import Darwin
import EngramCoreRead
import Foundation

public enum ExactSourceCapturerError: Error, Equatable, Sendable {
    case invalidMachineID(String)
    case machineIDMismatch(expected: String, actual: String)
    case ineligible(ArchiveLocatorClassification)
    case generationChanged
    case existingCaptureConflict(String)
    case io(operation: String, code: Int32)
}

public struct ArchiveCaptureResult: Equatable, Sendable {
    public let capture: ArchiveCapture
    public let manifest: ArchiveSourceManifest

    public init(capture: ArchiveCapture, manifest: ArchiveSourceManifest) {
        self.capture = capture
        self.manifest = manifest
    }
}

struct ExactSourceCapturerTestHooks: Sendable {
    let maximumReadSize: Int?
    let afterStreamingBeforeFinalStat: (@Sendable (URL) throws -> Void)?

    init(
        maximumReadSize: Int? = nil,
        afterStreamingBeforeFinalStat: (@Sendable (URL) throws -> Void)? = nil
    ) {
        self.maximumReadSize = maximumReadSize
        self.afterStreamingBeforeFinalStat = afterStreamingBeforeFinalStat
    }
}

public struct ExactSourceCapturer: Sendable {
    private let cas: ImmutableArchiveCAS
    private let catalog: ArchiveCatalog
    private let descriptor: ArchiveSourceDescriptor
    private let testHooks: ExactSourceCapturerTestHooks

    public init(
        cas: ImmutableArchiveCAS,
        catalog: ArchiveCatalog,
        descriptor: ArchiveSourceDescriptor
    ) {
        self.init(
            cas: cas,
            catalog: catalog,
            descriptor: descriptor,
            testHooks: ExactSourceCapturerTestHooks()
        )
    }

    init(
        cas: ImmutableArchiveCAS,
        catalog: ArchiveCatalog,
        descriptor: ArchiveSourceDescriptor,
        testHooks: ExactSourceCapturerTestHooks
    ) {
        self.cas = cas
        self.catalog = catalog
        self.descriptor = descriptor
        self.testHooks = testHooks
    }

    public func capture(
        source: SourceName,
        locator: String,
        machineID: String
    ) throws -> ArchiveCaptureResult {
        try Task.checkCancellation()
        guard UUID(uuidString: machineID) != nil else {
            throw ExactSourceCapturerError.invalidMachineID(machineID)
        }
        let persistedMachineID = try catalog.machineID()
        guard machineID == persistedMachineID else {
            throw ExactSourceCapturerError.machineIDMismatch(
                expected: persistedMachineID,
                actual: machineID
            )
        }
        let classification = ArchiveLocatorClassifier.classify(
            descriptor: descriptor,
            enumeratedLocator: locator
        )
        guard case .declaredSingleFile(let sourceURL) = classification else {
            throw ExactSourceCapturerError.ineligible(classification)
        }

        let streamed = try streamStableSource(sourceURL)
        try Task.checkCancellation()
        let normalizedLocator = sourceURL.standardizedFileURL.path
        let captureID = try Self.captureID(
            machineID: machineID,
            source: source,
            locator: normalizedLocator,
            generation: streamed.generation,
            wholeSourceSHA256: streamed.wholeSourceSHA256
        )
        let replayLayout = try descriptor.singleFileReplayLayout()

        if let existing = try catalog.capture(captureID: captureID) {
            guard ArchiveV2Hash.sha256(existing.unboundManifestBytes)
                == existing.unboundManifestSHA256 else {
                throw ExactSourceCapturerError.existingCaptureConflict(captureID)
            }
            let manifest = try ArchiveCanonicalJSON.decode(
                ArchiveSourceManifest.self,
                from: existing.unboundManifestBytes
            )
            guard manifest.sessionID == nil,
                  manifest.captureID == captureID,
                  manifest.machineID == machineID,
                  manifest.source == source.rawValue,
                  manifest.locator == normalizedLocator,
                  manifest.generation == streamed.generation,
                  manifest.wholeSourceSHA256 == streamed.wholeSourceSHA256,
                  manifest.rawByteCount == streamed.generation.size,
                  manifest.chunks == streamed.chunks,
                  manifest.replayLayout == replayLayout else {
                throw ExactSourceCapturerError.existingCaptureConflict(captureID)
            }
            try Task.checkCancellation()
            _ = try cas.publishManifest(
                existing.unboundManifestBytes,
                expectedSHA256: existing.unboundManifestSHA256
            )
            return ArchiveCaptureResult(capture: existing, manifest: manifest)
        }

        let manifest = try ArchiveSourceManifest(
            captureID: captureID,
            machineID: machineID,
            source: source.rawValue,
            locator: normalizedLocator,
            sessionID: nil,
            capturedAt: Self.currentTimestamp(),
            generation: streamed.generation,
            wholeSourceSHA256: streamed.wholeSourceSHA256,
            rawByteCount: streamed.generation.size,
            chunks: streamed.chunks,
            replayLayout: replayLayout
        )
        let canonicalBytes = try ArchiveCanonicalJSON.encode(manifest)
        let manifestSHA256 = ArchiveV2Hash.sha256(canonicalBytes)
        try Task.checkCancellation()
        _ = try cas.publishManifest(canonicalBytes, expectedSHA256: manifestSHA256)
        let capture = try catalog.recordCapture(canonicalManifestBytes: canonicalBytes)
        return ArchiveCaptureResult(capture: capture, manifest: manifest)
    }

    struct StableSourceRead: Equatable, Sendable {
        let generation: ArchiveSourceGeneration
        let wholeSourceSHA256: String
        let chunks: [ArchiveChunkReference]
    }

    func streamStableSource(_ sourceURL: URL) throws -> StableSourceRead {
        try Task.checkCancellation()
        // O_NONBLOCK closes the lstat/open race where a regular file is
        // replaced by a FIFO. It has no effect on regular-file reads, and the
        // immediate fstat gate below still rejects every non-regular object.
        let fd = Darwin.open(
            sourceURL.path,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard fd >= 0 else {
            let openError = errno
            if openError == ENOENT {
                throw ExactSourceCapturerError.ineligible(.missing)
            }
            if openError == ELOOP {
                throw ExactSourceCapturerError.ineligible(.unsafe("symlink locator"))
            }
            throw Self.io("open-source", code: openError)
        }
        defer { _ = Darwin.close(fd) }

        let before = try Self.secureGeneration(fd: fd, path: sourceURL.path)
        var remaining = before.size
        var wholeHasher = SHA256()
        var chunks: [ArchiveChunkReference] = []
        var ordinal = 0

        while remaining > 0 {
            try Task.checkCancellation()
            let expected = Int(min(remaining, ArchiveSourceManifest.rawChunkSize))
            var chunk = Data(count: expected)
            var filled = 0
            while filled < expected {
                try Task.checkCancellation()
                let requested = min(
                    expected - filled,
                    max(testHooks.maximumReadSize ?? (expected - filled), 1)
                )
                let count = chunk.withUnsafeMutableBytes { rawBuffer -> Int in
                    guard let base = rawBuffer.baseAddress else { return 0 }
                    return Darwin.read(fd, base.advanced(by: filled), requested)
                }
                if count < 0, errno == EINTR {
                    continue
                }
                guard count > 0 else {
                    if count == 0 {
                        throw ExactSourceCapturerError.generationChanged
                    }
                    throw Self.io("read-source", code: errno)
                }
                filled += count
            }

            wholeHasher.update(data: chunk)
            let rawSHA256 = ArchiveV2Hash.sha256(chunk)
            _ = try cas.publishObject(raw: chunk, expectedSHA256: rawSHA256)
            chunks.append(
                try ArchiveChunkReference(
                    ordinal: ordinal,
                    rawSHA256: rawSHA256,
                    rawByteCount: Int64(chunk.count)
                )
            )
            ordinal += 1
            remaining -= Int64(chunk.count)
        }

        try testHooks.afterStreamingBeforeFinalStat?(sourceURL)
        try Task.checkCancellation()
        let after = try Self.generation(fd: fd)
        var pathInfo = stat()
        guard Darwin.lstat(sourceURL.path, &pathInfo) == 0 else {
            throw ExactSourceCapturerError.generationChanged
        }
        let pathGeneration = try Self.generation(info: pathInfo)
        guard before == after,
              after == pathGeneration else {
            throw ExactSourceCapturerError.generationChanged
        }

        return StableSourceRead(
            generation: before,
            wholeSourceSHA256: Self.hexDigest(wholeHasher.finalize()),
            chunks: chunks
        )
    }

    static func verify(
        sourceURL: URL,
        expectedGeneration: ArchiveSourceGeneration,
        expectedWholeSourceSHA256: String
    ) throws {
        try Task.checkCancellation()
        let fd = Darwin.open(
            sourceURL.path,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard fd >= 0 else {
            throw ExactSourceCapturerError.generationChanged
        }
        defer { _ = Darwin.close(fd) }
        let before: ArchiveSourceGeneration
        do {
            before = try secureGeneration(fd: fd, path: sourceURL.path)
        } catch ExactSourceCapturerError.ineligible,
                ExactSourceCapturerError.generationChanged {
            throw ExactSourceCapturerError.generationChanged
        }
        guard before == expectedGeneration else {
            throw ExactSourceCapturerError.generationChanged
        }

        var hasher = SHA256()
        var remaining = before.size
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while remaining > 0 {
            try Task.checkCancellation()
            let request = min(buffer.count, Int(remaining))
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(fd, rawBuffer.baseAddress, request)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw count == 0
                    ? ExactSourceCapturerError.generationChanged
                    : Self.io("read-source-verify", code: errno)
            }
            hasher.update(data: Data(buffer[0..<count]))
            remaining -= Int64(count)
        }
        try Task.checkCancellation()
        let after = try generation(fd: fd)
        var pathInfo = stat()
        guard Darwin.lstat(sourceURL.path, &pathInfo) == 0,
              let pathGeneration = try? generation(info: pathInfo),
              before == after,
              after == pathGeneration,
              hexDigest(hasher.finalize()) == expectedWholeSourceSHA256 else {
            throw ExactSourceCapturerError.generationChanged
        }
    }

    private static func secureGeneration(fd: Int32, path: String) throws -> ArchiveSourceGeneration {
        let descriptorGeneration = try generation(fd: fd)
        var pathInfo = stat()
        guard Darwin.lstat(path, &pathInfo) == 0 else {
            throw ExactSourceCapturerError.generationChanged
        }
        let pathGeneration = try generation(info: pathInfo)
        guard descriptorGeneration == pathGeneration else {
            throw ExactSourceCapturerError.generationChanged
        }
        return descriptorGeneration
    }

    private static func generation(fd: Int32) throws -> ArchiveSourceGeneration {
        var info = stat()
        guard Darwin.fstat(fd, &info) == 0 else {
            throw io("fstat-source", code: errno)
        }
        return try generation(info: info)
    }

    private static func generation(info: stat) throws -> ArchiveSourceGeneration {
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw ExactSourceCapturerError.ineligible(.unsafe("non-regular locator"))
        }
        return try ArchiveSourceGeneration(
            device: Int64(info.st_dev),
            inode: Int64(info.st_ino),
            size: Int64(info.st_size),
            mtimeNs: try nanoseconds(info.st_mtimespec, operation: "mtime"),
            ctimeNs: try nanoseconds(info.st_ctimespec, operation: "ctime"),
            mode: Int64(info.st_mode)
        )
    }

    private struct CaptureIdentity: Codable {
        let machineID: String
        let source: String
        let locator: String
        let generation: ArchiveSourceGeneration
        let wholeSourceSHA256: String
    }

    private static func captureID(
        machineID: String,
        source: SourceName,
        locator: String,
        generation: ArchiveSourceGeneration,
        wholeSourceSHA256: String
    ) throws -> String {
        let identity = CaptureIdentity(
            machineID: machineID,
            source: source.rawValue,
            locator: locator,
            generation: generation,
            wholeSourceSHA256: wholeSourceSHA256
        )
        return ArchiveV2Hash.sha256(try ArchiveCanonicalJSON.encode(identity))
    }

    private static func nanoseconds(_ value: timespec, operation: String) throws -> Int64 {
        let (seconds, multiplyOverflow) = Int64(value.tv_sec).multipliedReportingOverflow(by: 1_000_000_000)
        let (result, addOverflow) = seconds.addingReportingOverflow(Int64(value.tv_nsec))
        guard !multiplyOverflow, !addOverflow else {
            throw io("\(operation)-overflow", code: EOVERFLOW)
        }
        return result
    }

    private static func hexDigest<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func currentTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private static func io(_ operation: String, code: Int32) -> ExactSourceCapturerError {
        .io(operation: operation, code: code)
    }
}
