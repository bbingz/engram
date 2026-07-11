import EngramCoreRead
import Foundation

public struct ArchiveCaptureCycleItem: Equatable, Sendable {
    public let source: SourceName
    public let locator: String
    public let classification: ArchiveLocatorClassification
    public let captureID: String?
    public let diagnostic: String?

    public init(
        source: SourceName,
        locator: String,
        classification: ArchiveLocatorClassification,
        captureID: String?,
        diagnostic: String?
    ) {
        self.source = source
        self.locator = locator
        self.classification = classification
        self.captureID = captureID
        self.diagnostic = diagnostic
    }
}

public struct ArchiveCaptureCycleResult: Equatable, Sendable {
    public let items: [ArchiveCaptureCycleItem]
    public let captures: [ArchiveCaptureResult]

    public init(items: [ArchiveCaptureCycleItem], captures: [ArchiveCaptureResult]) {
        self.items = items
        self.captures = captures
    }
}

public enum ArchiveSessionIdentityError: Error, Equatable, Sendable {
    case invalidSessionID
    case invalidLocator(String)
    case invalidExpectedCaptureID(String)
    case invalidIndexedSize(Int64)
    case missingIndexedInode
    case invalidIndexedInode(Int64)
    case missingIndexedDevice
    case invalidIndexedDevice(Int64)
    case invalidIndexedParseStatus(String)
}

/// Proof that the product index accepted one exact local file generation.
/// Task 6 constructs this only from a capture-exact `file_index_state` row
/// whose parse status is `ok`; Task 3 independently compares every available
/// identity field with the captured generation before binding.
public struct ArchiveIndexedGenerationProof: Equatable, Sendable {
    public let expectedCaptureID: String
    public let source: SourceName
    public let locator: String
    public let sizeBytes: Int64
    public let modifiedAtNanos: Int64
    public let inode: Int64
    public let device: Int64
    public let parseStatus: FileIndexParseStatus

    public init(
        expectedCaptureID: String,
        source: SourceName,
        locator: String,
        sizeBytes: Int64,
        modifiedAtNanos: Int64,
        inode: Int64?,
        device: Int64?,
        parseStatus: FileIndexParseStatus
    ) throws {
        guard ArchiveV2Hash.isValidSHA256(expectedCaptureID) else {
            throw ArchiveSessionIdentityError.invalidExpectedCaptureID(expectedCaptureID)
        }
        guard let normalizedLocator = ArchiveLocatorClassifier.normalize(locator) else {
            throw ArchiveSessionIdentityError.invalidLocator(locator)
        }
        guard sizeBytes >= 0 else {
            throw ArchiveSessionIdentityError.invalidIndexedSize(sizeBytes)
        }
        guard let inode else {
            throw ArchiveSessionIdentityError.missingIndexedInode
        }
        guard inode >= 0 else {
            throw ArchiveSessionIdentityError.invalidIndexedInode(inode)
        }
        guard let device else {
            throw ArchiveSessionIdentityError.missingIndexedDevice
        }
        guard device >= 0 else {
            throw ArchiveSessionIdentityError.invalidIndexedDevice(device)
        }
        guard parseStatus.rawValue == FileIndexParseStatus.ok.rawValue else {
            throw ArchiveSessionIdentityError.invalidIndexedParseStatus(parseStatus.rawValue)
        }
        self.expectedCaptureID = expectedCaptureID
        self.source = source
        self.locator = normalizedLocator
        self.sizeBytes = sizeBytes
        self.modifiedAtNanos = modifiedAtNanos
        self.inode = inode
        self.device = device
        self.parseStatus = parseStatus
    }

    public static func == (
        lhs: ArchiveIndexedGenerationProof,
        rhs: ArchiveIndexedGenerationProof
    ) -> Bool {
        lhs.expectedCaptureID == rhs.expectedCaptureID
            && lhs.source == rhs.source
            && lhs.locator == rhs.locator
            && lhs.sizeBytes == rhs.sizeBytes
            && lhs.modifiedAtNanos == rhs.modifiedAtNanos
            && lhs.inode == rhs.inode
            && lhs.device == rhs.device
            && lhs.parseStatus.rawValue == rhs.parseStatus.rawValue
    }
}

public struct ArchiveSessionIdentity: Equatable, Sendable {
    public let sessionID: String
    public let source: SourceName
    public let locator: String
    public let indexedGenerationProof: ArchiveIndexedGenerationProof

    public init(
        sessionID: String,
        source: SourceName,
        locator: String,
        indexedGenerationProof: ArchiveIndexedGenerationProof
    ) throws {
        guard !sessionID.isEmpty else {
            throw ArchiveSessionIdentityError.invalidSessionID
        }
        guard let normalizedLocator = ArchiveLocatorClassifier.normalize(locator) else {
            throw ArchiveSessionIdentityError.invalidLocator(locator)
        }
        self.sessionID = sessionID
        self.source = source
        self.locator = normalizedLocator
        self.indexedGenerationProof = indexedGenerationProof
    }
}

public enum ArchiveBindingDisposition: Equatable, Sendable {
    case bound
    case noMatch
    case ambiguousMatch(Int)
    case indexedGenerationMismatch
    case generationChanged
    case failed(String)
}

public struct ArchiveBindingCycleItem: Equatable, Sendable {
    public let captureID: String
    public let disposition: ArchiveBindingDisposition

    public init(captureID: String, disposition: ArchiveBindingDisposition) {
        self.captureID = captureID
        self.disposition = disposition
    }
}

public struct ArchiveBindingCycleResult: Equatable, Sendable {
    public let items: [ArchiveBindingCycleItem]
    public let bindings: [ArchiveBinding]

    public init(items: [ArchiveBindingCycleItem], bindings: [ArchiveBinding]) {
        self.items = items
        self.bindings = bindings
    }
}

struct ArchiveCaptureCoordinatorTestHooks: Sendable {
    let afterCaptureRecorded: (@Sendable (ArchiveCaptureResult) -> Void)?

    init(_ afterCaptureRecorded: (@Sendable (ArchiveCaptureResult) -> Void)? = nil) {
        self.afterCaptureRecorded = afterCaptureRecorded
    }
}

public actor ArchiveCaptureCoordinator {
    private struct BindingKey: Hashable {
        let source: String
        let locator: String
    }

    private let cas: ImmutableArchiveCAS
    private let catalog: ArchiveCatalog
    private let unboundBatchLimit: Int
    private let testHooks: ArchiveCaptureCoordinatorTestHooks

    public init(
        cas: ImmutableArchiveCAS,
        catalog: ArchiveCatalog,
        unboundBatchLimit: Int = 1_000
    ) {
        self.init(
            cas: cas,
            catalog: catalog,
            unboundBatchLimit: unboundBatchLimit,
            testHooks: ArchiveCaptureCoordinatorTestHooks()
        )
    }

    init(
        cas: ImmutableArchiveCAS,
        catalog: ArchiveCatalog,
        unboundBatchLimit: Int = 1_000,
        testHooks: ArchiveCaptureCoordinatorTestHooks
    ) {
        self.cas = cas
        self.catalog = catalog
        self.unboundBatchLimit = max(unboundBatchLimit, 1)
        self.testHooks = testHooks
    }

    public func capture(
        adapters: [any SessionAdapter]
    ) async throws -> ArchiveCaptureCycleResult {
        let machineID = try catalog.machineID()
        var items: [ArchiveCaptureCycleItem] = []
        var captures: [ArchiveCaptureResult] = []

        for adapter in adapters {
            try Task.checkCancellation()
            guard let exactAdapter = adapter as? any ExactArchiveSourceAdapter else {
                items.append(
                    ArchiveCaptureCycleItem(
                        source: adapter.source,
                        locator: "",
                        classification: .unsupportedAdapter,
                        captureID: nil,
                        diagnostic: nil
                    )
                )
                continue
            }
            let locators: [String]
            do {
                locators = try await adapter.listSessionLocators()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                items.append(
                    ArchiveCaptureCycleItem(
                        source: adapter.source,
                        locator: "",
                        classification: .unsafe("locator enumeration failed"),
                        captureID: nil,
                        diagnostic: String(describing: error)
                    )
                )
                continue
            }

            for locator in locators {
                try Task.checkCancellation()
                if ArchiveLocatorClassifier.isVirtual(locator) {
                    items.append(
                        ArchiveCaptureCycleItem(
                            source: adapter.source,
                            locator: locator,
                            classification: .unsupportedVirtual,
                            captureID: nil,
                            diagnostic: nil
                        )
                    )
                    continue
                }
                let descriptor: ArchiveSourceDescriptor
                do {
                    descriptor = try await exactAdapter.archiveSourceDescriptor(locator: locator)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    items.append(
                        ArchiveCaptureCycleItem(
                            source: adapter.source,
                            locator: locator,
                            classification: .unsafe("descriptor rejected"),
                            captureID: nil,
                            diagnostic: String(describing: error)
                        )
                    )
                    continue
                }
                try Task.checkCancellation()
                let classification = ArchiveLocatorClassifier.classify(
                    descriptor: descriptor,
                    enumeratedLocator: locator
                )
                guard case .declaredSingleFile = classification else {
                    items.append(
                        ArchiveCaptureCycleItem(
                            source: adapter.source,
                            locator: locator,
                            classification: classification,
                            captureID: nil,
                            diagnostic: nil
                        )
                    )
                    continue
                }

                do {
                    let result = try ExactSourceCapturer(
                        cas: cas,
                        catalog: catalog,
                        descriptor: descriptor
                    ).capture(
                        source: adapter.source,
                        locator: locator,
                        machineID: machineID
                    )
                    captures.append(result)
                    items.append(
                        ArchiveCaptureCycleItem(
                            source: adapter.source,
                            locator: locator,
                            classification: classification,
                            captureID: result.capture.captureID,
                            diagnostic: nil
                        )
                    )
                    testHooks.afterCaptureRecorded?(result)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    items.append(
                        ArchiveCaptureCycleItem(
                            source: adapter.source,
                            locator: locator,
                            classification: classification,
                            captureID: nil,
                            diagnostic: String(describing: error)
                        )
                    )
                }
            }
        }
        try Task.checkCancellation()
        return ArchiveCaptureCycleResult(items: items, captures: captures)
    }

    public func bind(
        _ sessions: [ArchiveSessionIdentity]
    ) throws -> ArchiveBindingCycleResult {
        try Task.checkCancellation()
        var grouped: [BindingKey: [ArchiveSessionIdentity]] = [:]
        for session in sessions {
            try Task.checkCancellation()
            let key = BindingKey(source: session.source.rawValue, locator: session.locator)
            grouped[key, default: []].append(session)
        }

        var items: [ArchiveBindingCycleItem] = []
        var bindings: [ArchiveBinding] = []
        guard let boundary = try catalog.unboundCaptureBoundary() else {
            try Task.checkCancellation()
            return ArchiveBindingCycleResult(items: [], bindings: [])
        }
        var cursor: ArchiveCaptureCursor?
        while cursor != boundary {
            let page = try catalog.unboundCaptures(
                limit: unboundBatchLimit,
                after: cursor,
                through: boundary
            )
            guard !page.isEmpty else { break }
            for capture in page {
                try Task.checkCancellation()
                guard let normalizedLocator = ArchiveLocatorClassifier.normalize(capture.locator) else {
                    items.append(
                        ArchiveBindingCycleItem(
                            captureID: capture.captureID,
                            disposition: .failed("invalid captured locator")
                        )
                    )
                    continue
                }
                let key = BindingKey(source: capture.source, locator: normalizedLocator)
                let matches = grouped[key] ?? []
                guard matches.count == 1 else {
                    items.append(
                        ArchiveBindingCycleItem(
                            captureID: capture.captureID,
                            disposition: matches.isEmpty ? .noMatch : .ambiguousMatch(matches.count)
                        )
                    )
                    continue
                }
                let session = matches[0]

                do {
                    let unbound = try ArchiveCanonicalJSON.decode(
                        ArchiveSourceManifest.self,
                        from: capture.unboundManifestBytes
                    )
                    guard unbound.sessionID == nil,
                          unbound.source == session.source.rawValue,
                          unbound.locator == session.locator else {
                        items.append(
                            ArchiveBindingCycleItem(
                                captureID: capture.captureID,
                                disposition: .failed("capture/session identity mismatch")
                            )
                        )
                        continue
                    }
                    guard Self.indexedGenerationMatches(
                        session.indexedGenerationProof,
                        capture: capture,
                        manifest: unbound
                    ) else {
                        items.append(
                            ArchiveBindingCycleItem(
                                captureID: capture.captureID,
                                disposition: .indexedGenerationMismatch
                            )
                        )
                        continue
                    }
                    try ExactSourceCapturer.verify(
                        sourceURL: URL(fileURLWithPath: session.locator),
                        expectedGeneration: unbound.generation,
                        expectedWholeSourceSHA256: unbound.wholeSourceSHA256
                    )
                    try Task.checkCancellation()
                    let bound = try ArchiveSourceManifest(
                        captureID: unbound.captureID,
                        machineID: unbound.machineID,
                        source: unbound.source,
                        locator: unbound.locator,
                        sessionID: session.sessionID,
                        capturedAt: unbound.capturedAt,
                        generation: unbound.generation,
                        wholeSourceSHA256: unbound.wholeSourceSHA256,
                        rawByteCount: unbound.rawByteCount,
                        chunkSize: unbound.chunkSize,
                        chunks: unbound.chunks,
                        replayLayout: unbound.replayLayout
                    )
                    let canonicalBytes = try ArchiveCanonicalJSON.encode(bound)
                    let manifestSHA256 = ArchiveV2Hash.sha256(canonicalBytes)
                    let sourceSnapshotFingerprint = try Self.sourceSnapshotFingerprint(
                        session: session,
                        manifest: unbound
                    )
                    _ = try cas.publishManifest(
                        canonicalBytes,
                        expectedSHA256: manifestSHA256
                    )
                    let binding = try catalog.bind(
                        canonicalManifestBytes: canonicalBytes,
                        sourceSnapshotFingerprint: sourceSnapshotFingerprint
                    )
                    bindings.append(binding)
                    items.append(
                        ArchiveBindingCycleItem(
                            captureID: capture.captureID,
                            disposition: .bound
                        )
                    )
                } catch ExactSourceCapturerError.generationChanged {
                    items.append(
                        ArchiveBindingCycleItem(
                            captureID: capture.captureID,
                            disposition: .generationChanged
                        )
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as ExactSourceCapturerError {
                    items.append(
                        ArchiveBindingCycleItem(
                            captureID: capture.captureID,
                            disposition: .failed(String(describing: error))
                        )
                    )
                } catch {
                    items.append(
                        ArchiveBindingCycleItem(
                            captureID: capture.captureID,
                            disposition: .failed(String(describing: error))
                        )
                    )
                }
            }
            guard let last = page.last else { break }
            cursor = ArchiveCaptureCursor(
                capturedAt: last.capturedAt,
                captureID: last.captureID
            )
        }
        try Task.checkCancellation()
        return ArchiveBindingCycleResult(items: items, bindings: bindings)
    }

    private struct SourceSnapshotFingerprintSeed: Codable {
        let schemaVersion: Int
        let sessionID: String
        let captureID: String
        let wholeSourceSHA256: String
        let indexedExpectedCaptureID: String
        let indexedSource: String
        let indexedLocator: String
        let indexedSizeBytes: Int64
        let indexedModifiedAtNanos: Int64
        let indexedInode: Int64
        let indexedDevice: Int64
        let indexedParseStatus: String
    }

    private static func indexedGenerationMatches(
        _ proof: ArchiveIndexedGenerationProof,
        capture: ArchiveCapture,
        manifest: ArchiveSourceManifest
    ) -> Bool {
        capture.captureID == manifest.captureID
            && capture.source == manifest.source
            && capture.locator == manifest.locator
            && capture.generation == manifest.generation
            && capture.wholeSourceSHA256 == manifest.wholeSourceSHA256
            && proof.expectedCaptureID == capture.captureID
            && proof.source.rawValue == capture.source
            && proof.locator == capture.locator
            && proof.sizeBytes == capture.generation.size
            && proof.modifiedAtNanos == capture.generation.mtimeNs
            && proof.inode == capture.generation.inode
            && proof.device == capture.generation.device
            && proof.parseStatus.rawValue == FileIndexParseStatus.ok.rawValue
    }

    private static func sourceSnapshotFingerprint(
        session: ArchiveSessionIdentity,
        manifest: ArchiveSourceManifest
    ) throws -> String {
        let proof = session.indexedGenerationProof
        let seed = SourceSnapshotFingerprintSeed(
            schemaVersion: 1,
            sessionID: session.sessionID,
            captureID: manifest.captureID,
            wholeSourceSHA256: manifest.wholeSourceSHA256,
            indexedExpectedCaptureID: proof.expectedCaptureID,
            indexedSource: proof.source.rawValue,
            indexedLocator: proof.locator,
            indexedSizeBytes: proof.sizeBytes,
            indexedModifiedAtNanos: proof.modifiedAtNanos,
            indexedInode: proof.inode,
            indexedDevice: proof.device,
            indexedParseStatus: proof.parseStatus.rawValue
        )
        return ArchiveV2Hash.sha256(try ArchiveCanonicalJSON.encode(seed))
    }
}
