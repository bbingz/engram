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
    public let processed: Int
    public let hasMore: Bool
    public let continuation: String?
    public let capturedSourceBytes: Int64
    public let failures: [ArchiveCaptureCycleItem]

    public init(
        items: [ArchiveCaptureCycleItem],
        captures: [ArchiveCaptureResult],
        processed: Int? = nil,
        hasMore: Bool = false,
        continuation: String? = nil,
        capturedSourceBytes: Int64? = nil
    ) {
        self.items = items
        self.captures = captures
        self.processed = processed ?? items.filter { !$0.locator.isEmpty }.count
        self.hasMore = hasMore
        self.continuation = continuation
        self.capturedSourceBytes = capturedSourceBytes
            ?? captures.reduce(into: 0) { total, capture in
                let addition = total.addingReportingOverflow(capture.manifest.rawByteCount)
                total = addition.overflow ? .max : addition.partialValue
            }
        failures = items.filter { $0.diagnostic != nil }
    }
}

public struct ArchiveCaptureBudget: Equatable, Sendable {
    public let locatorLimit: Int
    public let sourceByteLimit: Int64

    public init(locatorLimit: Int, sourceByteLimit: Int64) {
        self.locatorLimit = locatorLimit
        self.sourceByteLimit = sourceByteLimit
    }
}

public enum ArchiveCaptureCoordinatorError: Error, Equatable, Sendable {
    case invalidBudget(Int)
    case invalidSourceByteLimit(Int64)
    case invalidCaptureContinuation
    case invalidBindingContinuation
}

public enum ArchiveCaptureCursorScope: String, CaseIterable, Equatable, Sendable {
    case full
    case recent

    fileprivate var metadataKey: ArchiveCursorKey {
        switch self {
        case .full: .captureFull
        case .recent: .captureRecent
        }
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
    public let processed: Int
    public let hasMore: Bool
    public let continuation: String?
    public let failures: [ArchiveBindingCycleItem]

    public init(
        items: [ArchiveBindingCycleItem],
        bindings: [ArchiveBinding],
        processed: Int? = nil,
        hasMore: Bool = false,
        continuation: String? = nil
    ) {
        self.items = items
        self.bindings = bindings
        self.processed = processed ?? items.count
        self.hasMore = hasMore
        self.continuation = continuation
        failures = items.filter { item in
            if case .bound = item.disposition { return false }
            return true
        }
    }
}

struct ArchiveCaptureCoordinatorTestHooks: Sendable {
    let afterCaptureRecorded: (@Sendable (ArchiveCaptureResult) -> Void)?
    let afterBindingRowAdvanced: (@Sendable (ArchiveCapture) -> Void)?

    init(
        _ afterCaptureRecorded: (@Sendable (ArchiveCaptureResult) -> Void)? = nil,
        afterBindingRowAdvanced: (@Sendable (ArchiveCapture) -> Void)? = nil
    ) {
        self.afterCaptureRecorded = afterCaptureRecorded
        self.afterBindingRowAdvanced = afterBindingRowAdvanced
    }
}

public actor ArchiveCaptureCoordinator {
    private struct BindingKey: Hashable {
        let source: String
        let locator: String
    }

    private struct SourceCaptureProgress: Codable, Equatable {
        let source: String
        var locatorSetDigest: String?
        var lastLocator: String?
        var sweepUpperBound: String?
        var wrapEnd: String?
        var didWrap: Bool
        var exhaustedDigest: String?
    }

    private struct CaptureProgress: Codable, Equatable {
        let schemaVersion: Int
        var sources: [SourceCaptureProgress]
        var nextSourceIndex: Int
    }

    private struct LocatorSnapshot: Equatable {
        let locator: String
        let key: String
    }

    private struct LocatorSweepCache {
        let adapterSources: [SourceName]
        let exactAdapters: [Int: any ExactArchiveSourceAdapter]
        let locatorSnapshots: [Int: [LocatorSnapshot]]
        let enumerationItems: [ArchiveCaptureCycleItem]
    }

    private struct PersistedCaptureCursor: Codable, Equatable {
        let capturedAt: String
        let captureID: String

        init(_ cursor: ArchiveCaptureCursor) {
            capturedAt = cursor.capturedAt
            captureID = cursor.captureID
        }

        var value: ArchiveCaptureCursor {
            ArchiveCaptureCursor(capturedAt: capturedAt, captureID: captureID)
        }
    }

    private struct LockedBindingBatch: Codable, Equatable {
        let end: PersistedCaptureCursor
        let count: Int
        let captureIDsSHA256: String
    }

    private struct BindingProgress: Codable, Equatable {
        let schemaVersion: Int
        var boundary: PersistedCaptureCursor?
        var after: PersistedCaptureCursor?
        var lockedBatch: LockedBindingBatch?
    }

    private let cas: ImmutableArchiveCAS
    private let catalog: ArchiveCatalog
    private let unboundBatchLimit: Int
    private let testHooks: ArchiveCaptureCoordinatorTestHooks
    private var expectedBindingBatchFingerprint: String?
    private var locatorSweepCaches: [ArchiveCaptureCursorScope: LocatorSweepCache]

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
        expectedBindingBatchFingerprint = nil
        locatorSweepCaches = [:]
    }

    public func capture(
        adapters: [any SessionAdapter]
    ) async throws -> ArchiveCaptureCycleResult {
        try await capture(
            adapters: adapters,
            budget: ArchiveCaptureBudget(locatorLimit: .max, sourceByteLimit: .max),
            cursorScope: .full,
            refreshLocatorSnapshot: true
        )
    }

    public func capture(
        adapters: [any SessionAdapter],
        locatorBudget: Int,
        cursorScope: ArchiveCaptureCursorScope = .full
    ) async throws -> ArchiveCaptureCycleResult {
        try await capture(
            adapters: adapters,
            budget: ArchiveCaptureBudget(
                locatorLimit: locatorBudget,
                sourceByteLimit: .max
            ),
            cursorScope: cursorScope,
            refreshLocatorSnapshot: true
        )
    }

    public func capture(
        adapters: [any SessionAdapter],
        budget: ArchiveCaptureBudget,
        cursorScope: ArchiveCaptureCursorScope = .full,
        refreshLocatorSnapshot: Bool
    ) async throws -> ArchiveCaptureCycleResult {
        guard budget.locatorLimit >= 0 else {
            throw ArchiveCaptureCoordinatorError.invalidBudget(budget.locatorLimit)
        }
        guard budget.sourceByteLimit >= 0 else {
            throw ArchiveCaptureCoordinatorError.invalidSourceByteLimit(budget.sourceByteLimit)
        }
        let machineID = try catalog.machineID()
        var items: [ArchiveCaptureCycleItem] = []
        var captures: [ArchiveCaptureResult] = []
        var progress = try captureProgress(
            for: adapters,
            cursorScope: cursorScope
        )
        if budget.locatorLimit == 0 || budget.sourceByteLimit == 0 {
            let payload = try ArchiveCanonicalJSON.encode(progress)
            _ = try catalog.storeArchiveCursorCheckpoint(
                payload,
                for: cursorScope.metadataKey
            )
            return ArchiveCaptureCycleResult(
                items: [],
                captures: [],
                processed: 0,
                hasMore: !adapters.isEmpty,
                continuation: adapters.isEmpty ? nil : ArchiveV2Hash.sha256(payload)
            )
        }

        var exactAdapters: [Int: any ExactArchiveSourceAdapter] = [:]
        var locatorSnapshots: [Int: [LocatorSnapshot]] = [:]
        var unavailableSources = Set<Int>()
        let adapterSources = adapters.map(\.source)
        let cachedSweep = refreshLocatorSnapshot
            ? nil
            : locatorSweepCaches[cursorScope].flatMap { cache in
                cache.adapterSources == adapterSources ? cache : nil
            }
        if let cachedSweep {
            exactAdapters = cachedSweep.exactAdapters
            locatorSnapshots = cachedSweep.locatorSnapshots
            items.append(contentsOf: cachedSweep.enumerationItems)
        } else {
            locatorSweepCaches[cursorScope] = nil
            var enumerationItems: [ArchiveCaptureCycleItem] = []
            for (sourceIndex, adapter) in adapters.enumerated() {
                try Task.checkCancellation()
                guard let exactAdapter = adapter as? any ExactArchiveSourceAdapter else {
                    let emptyDigest = try Self.locatorSetDigest([])
                    progress.sources[sourceIndex].locatorSetDigest = emptyDigest
                    progress.sources[sourceIndex].lastLocator = nil
                    progress.sources[sourceIndex].sweepUpperBound = nil
                    progress.sources[sourceIndex].wrapEnd = nil
                    progress.sources[sourceIndex].didWrap = true
                    progress.sources[sourceIndex].exhaustedDigest = emptyDigest
                    enumerationItems.append(
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
                do {
                    let listed = try await adapter.listSessionLocators()
                    let snapshots = Self.stableLocatorSnapshots(listed)
                    let digest = try Self.locatorSetDigest(snapshots)
                    var sourceProgress = progress.sources[sourceIndex]
                    if sourceProgress.locatorSetDigest == nil
                        || (sourceProgress.locatorSetDigest != digest
                            && sourceProgress.exhaustedDigest == sourceProgress.locatorSetDigest) {
                        Self.startSweep(
                            &sourceProgress,
                            digest: digest,
                            snapshots: snapshots
                        )
                    }
                    if snapshots.isEmpty {
                        sourceProgress.lastLocator = nil
                        sourceProgress.sweepUpperBound = nil
                        sourceProgress.wrapEnd = nil
                        sourceProgress.didWrap = true
                        sourceProgress.exhaustedDigest = sourceProgress.locatorSetDigest
                    }
                    progress.sources[sourceIndex] = sourceProgress
                    exactAdapters[sourceIndex] = exactAdapter
                    locatorSnapshots[sourceIndex] = snapshots
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    unavailableSources.insert(sourceIndex)
                    enumerationItems.append(
                        ArchiveCaptureCycleItem(
                            source: adapter.source,
                            locator: "",
                            classification: .unsafe("locator enumeration failed"),
                            captureID: nil,
                            diagnostic: String(describing: error)
                        )
                    )
                }
            }
            items.append(contentsOf: enumerationItems)
            if unavailableSources.isEmpty {
                locatorSweepCaches[cursorScope] = LocatorSweepCache(
                    adapterSources: adapterSources,
                    exactAdapters: exactAdapters,
                    locatorSnapshots: locatorSnapshots,
                    enumerationItems: enumerationItems
                )
            }
        }

        var processed = 0
        var capturedSourceBytes: Int64 = 0
        while processed < budget.locatorLimit,
              capturedSourceBytes < budget.sourceByteLimit,
              let sourceIndex = Self.nextCaptureSource(
                  in: progress,
                  availableSources: Set(locatorSnapshots.keys)
              ) {
            try Task.checkCancellation()
            progress.nextSourceIndex = adapters.isEmpty
                ? 0
                : (sourceIndex + 1) % adapters.count
            let adapter = adapters[sourceIndex]
            guard let exactAdapter = exactAdapters[sourceIndex],
                  let snapshots = locatorSnapshots[sourceIndex] else {
                continue
            }
            guard let selection = Self.nextLocator(
                in: snapshots,
                progress: &progress.sources[sourceIndex]
            ) else {
                let currentDigest = try Self.locatorSetDigest(snapshots)
                if progress.sources[sourceIndex].locatorSetDigest != currentDigest {
                    Self.startSweep(
                        &progress.sources[sourceIndex],
                        digest: currentDigest,
                        snapshots: snapshots
                    )
                }
                continue
            }
            processed += 1
            let outcome = try await captureLocator(
                adapter: adapter,
                exactAdapter: exactAdapter,
                locator: selection.snapshot.locator,
                machineID: machineID
            )
            items.append(outcome.item)
            if let capture = outcome.capture {
                captures.append(capture)
                let addition = capturedSourceBytes.addingReportingOverflow(
                    capture.manifest.rawByteCount
                )
                capturedSourceBytes = addition.overflow ? .max : addition.partialValue
            }
            progress.sources[sourceIndex].lastLocator = selection.snapshot.key
            Self.finishSweepIfAtCurrentBoundary(
                &progress.sources[sourceIndex],
                snapshots: snapshots
            )
            let currentDigest = try Self.locatorSetDigest(snapshots)
            if progress.sources[sourceIndex].exhaustedDigest
                == progress.sources[sourceIndex].locatorSetDigest,
               progress.sources[sourceIndex].locatorSetDigest != currentDigest {
                Self.startSweep(
                    &progress.sources[sourceIndex],
                    digest: currentDigest,
                    snapshots: snapshots
                )
            }
            // A capture may already be durable when cancellation arrives (for
            // example, the service is shutting down immediately after the CAS
            // and catalog write). Persist the fair cursor for that exact row
            // before observing cancellation so restart never spends the same
            // bounded budget at the old head and starves later sources.
            try persistCaptureProgress(progress, cursorScope: cursorScope)
            try Task.checkCancellation()
        }
        try Task.checkCancellation()
        // Enumeration failures are not immediately runnable backlog. Treating
        // them as `hasMore` would make the event-driven worker retry a broken
        // source every cool-down interval. A later discovery/index signal will
        // rebuild the uncached snapshot and retry the source.
        let hasMore = progress.sources.enumerated().contains { index, source in
            !unavailableSources.contains(index)
                && (source.locatorSetDigest == nil
                    || source.exhaustedDigest != source.locatorSetDigest)
        }
        if !hasMore {
            progress = Self.initialCaptureProgress(for: adapters)
            locatorSweepCaches[cursorScope] = nil
        }
        let payload = try persistCaptureProgress(
            progress,
            cursorScope: cursorScope
        )
        return ArchiveCaptureCycleResult(
            items: items,
            captures: captures,
            processed: processed,
            hasMore: hasMore,
            continuation: hasMore ? ArchiveV2Hash.sha256(payload) : nil,
            capturedSourceBytes: capturedSourceBytes
        )
    }

    @discardableResult
    private func persistCaptureProgress(
        _ progress: CaptureProgress,
        cursorScope: ArchiveCaptureCursorScope
    ) throws -> Data {
        let payload = try ArchiveCanonicalJSON.encode(progress)
        _ = try catalog.storeArchiveCursorCheckpoint(
            payload,
            for: cursorScope.metadataKey
        )
        return payload
    }

    public func bindingTargets(rowBudget: Int) throws -> [ArchiveCapture] {
        guard rowBudget >= 0 else {
            throw ArchiveCaptureCoordinatorError.invalidBudget(rowBudget)
        }
        guard rowBudget > 0 else { return [] }
        try Task.checkCancellation()
        var progress = try bindingProgress()
        if progress.boundary == nil {
            progress.boundary = try catalog.unboundCaptureBoundary().map(
                PersistedCaptureCursor.init
            )
            try persistBindingProgress(progress)
        }
        guard let boundary = progress.boundary?.value else { return [] }

        if progress.lockedBatch != nil {
            let targets = try lockedBindingTargets(progress)
            expectedBindingBatchFingerprint = try Self.bindingBatchFingerprint(
                progress.lockedBatch
            )
            return targets
        }
        let targets = try catalog.unboundCaptures(
            limit: min(unboundBatchLimit, rowBudget),
            after: progress.after?.value,
            through: boundary
        )
        guard !targets.isEmpty else { return [] }
        progress.lockedBatch = try Self.lockedBatch(for: targets)
        try persistBindingProgress(progress)
        expectedBindingBatchFingerprint = try Self.bindingBatchFingerprint(
            progress.lockedBatch
        )
        try Task.checkCancellation()
        return targets
    }

    public func bind(
        _ sessions: [ArchiveSessionIdentity]
    ) throws -> ArchiveBindingCycleResult {
        try bind(sessions, rowBudget: Int.max)
    }

    public func bind(
        _ sessions: [ArchiveSessionIdentity],
        rowBudget: Int
    ) throws -> ArchiveBindingCycleResult {
        guard rowBudget >= 0 else {
            throw ArchiveCaptureCoordinatorError.invalidBudget(rowBudget)
        }
        try Task.checkCancellation()
        var grouped: [BindingKey: [ArchiveSessionIdentity]] = [:]
        for session in sessions {
            try Task.checkCancellation()
            let key = BindingKey(source: session.source.rawValue, locator: session.locator)
            grouped[key, default: []].append(session)
        }

        var items: [ArchiveBindingCycleItem] = []
        var bindings: [ArchiveBinding] = []
        var progress = try bindingProgress()
        if let expectedBindingBatchFingerprint,
           try Self.bindingBatchFingerprint(progress.lockedBatch)
            != expectedBindingBatchFingerprint {
            throw ArchiveCaptureCoordinatorError.invalidBindingContinuation
        }
        if progress.boundary == nil {
            progress.boundary = try catalog.unboundCaptureBoundary().map(
                PersistedCaptureCursor.init
            )
        }
        guard let boundary = progress.boundary?.value else {
            try persistBindingProgress(progress)
            try Task.checkCancellation()
            return ArchiveBindingCycleResult(
                items: [],
                bindings: [],
                processed: 0,
                hasMore: false,
                continuation: nil
            )
        }
        if rowBudget == 0 {
            try persistBindingProgress(progress)
            let payload = try ArchiveCanonicalJSON.encode(progress)
            return ArchiveBindingCycleResult(
                items: [],
                bindings: [],
                processed: 0,
                hasMore: true,
                continuation: ArchiveV2Hash.sha256(payload)
            )
        }

        let enteredWithLockedBatch = progress.lockedBatch != nil
        var processed = 0
        var exhaustedSnapshot = false
        while processed < rowBudget {
            let lockedTargets: [ArchiveCapture]
            if progress.lockedBatch != nil {
                lockedTargets = try lockedBindingTargets(progress)
            } else {
                lockedTargets = try catalog.unboundCaptures(
                    limit: min(unboundBatchLimit, rowBudget - processed),
                    after: progress.after?.value,
                    through: boundary
                )
                if !lockedTargets.isEmpty {
                    progress.lockedBatch = try Self.lockedBatch(for: lockedTargets)
                    try persistBindingProgress(progress)
                }
            }
            guard !lockedTargets.isEmpty else {
                exhaustedSnapshot = true
                break
            }
            let targets = Array(lockedTargets.prefix(rowBudget - processed))
            for (targetIndex, capture) in targets.enumerated() {
                try Task.checkCancellation()
                processed += 1
                let outcome = try bindCapture(capture, grouped: grouped)
                items.append(outcome.item)
                if let binding = outcome.binding {
                    bindings.append(binding)
                }

                progress.after = PersistedCaptureCursor(
                    ArchiveCaptureCursor(
                        capturedAt: capture.capturedAt,
                        captureID: capture.captureID
                    )
                )
                let remainingTargets = Array(lockedTargets.dropFirst(targetIndex + 1))
                progress.lockedBatch = remainingTargets.isEmpty
                    ? nil
                    : try Self.lockedBatch(for: remainingTargets)
                try persistBindingProgress(progress)
                expectedBindingBatchFingerprint = try Self.bindingBatchFingerprint(
                    progress.lockedBatch
                )
                testHooks.afterBindingRowAdvanced?(capture)
                try Task.checkCancellation()
            }
            if enteredWithLockedBatch { break }
        }

        if !exhaustedSnapshot {
            exhaustedSnapshot = try catalog.unboundCaptures(
                limit: 1,
                after: progress.after?.value,
                through: boundary
            ).isEmpty
        }
        let hasMore = !exhaustedSnapshot
        if !hasMore {
            progress = BindingProgress(
                schemaVersion: 2,
                boundary: nil,
                after: nil,
                lockedBatch: nil
            )
        }
        try persistBindingProgress(progress)
        expectedBindingBatchFingerprint = try Self.bindingBatchFingerprint(
            progress.lockedBatch
        )
        let payload = try ArchiveCanonicalJSON.encode(progress)
        return ArchiveBindingCycleResult(
            items: items,
            bindings: bindings,
            processed: processed,
            hasMore: hasMore,
            continuation: hasMore ? ArchiveV2Hash.sha256(payload) : nil
        )
    }

    private func bindCapture(
        _ capture: ArchiveCapture,
        grouped: [BindingKey: [ArchiveSessionIdentity]]
    ) throws -> (item: ArchiveBindingCycleItem, binding: ArchiveBinding?) {
        guard let normalizedLocator = ArchiveLocatorClassifier.normalize(capture.locator) else {
            return (
                ArchiveBindingCycleItem(
                    captureID: capture.captureID,
                    disposition: .failed("invalid captured locator")
                ),
                nil
            )
        }
        let key = BindingKey(source: capture.source, locator: normalizedLocator)
        let matches = grouped[key] ?? []
        guard matches.count == 1 else {
            return (
                ArchiveBindingCycleItem(
                    captureID: capture.captureID,
                    disposition: matches.isEmpty ? .noMatch : .ambiguousMatch(matches.count)
                ),
                nil
            )
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
                return (
                    ArchiveBindingCycleItem(
                        captureID: capture.captureID,
                        disposition: .failed("capture/session identity mismatch")
                    ),
                    nil
                )
            }
            guard Self.indexedGenerationMatches(
                session.indexedGenerationProof,
                capture: capture,
                manifest: unbound
            ) else {
                return (
                    ArchiveBindingCycleItem(
                        captureID: capture.captureID,
                        disposition: .indexedGenerationMismatch
                    ),
                    nil
                )
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
            return (
                ArchiveBindingCycleItem(
                    captureID: capture.captureID,
                    disposition: .bound
                ),
                binding
            )
        } catch ExactSourceCapturerError.generationChanged {
            return (
                ArchiveBindingCycleItem(
                    captureID: capture.captureID,
                    disposition: .generationChanged
                ),
                nil
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ExactSourceCapturerError {
            return (
                ArchiveBindingCycleItem(
                    captureID: capture.captureID,
                    disposition: .failed(String(describing: error))
                ),
                nil
            )
        } catch {
            return (
                ArchiveBindingCycleItem(
                    captureID: capture.captureID,
                    disposition: .failed(String(describing: error))
                ),
                nil
            )
        }
    }

    private static func initialCaptureProgress(
        for adapters: [any SessionAdapter]
    ) -> CaptureProgress {
        CaptureProgress(
            schemaVersion: 2,
            sources: adapters.map {
                SourceCaptureProgress(
                    source: $0.source.rawValue,
                    locatorSetDigest: nil,
                    lastLocator: nil,
                    sweepUpperBound: nil,
                    wrapEnd: nil,
                    didWrap: true,
                    exhaustedDigest: nil
                )
            },
            nextSourceIndex: 0
        )
    }

    private func captureProgress(
        for adapters: [any SessionAdapter],
        cursorScope: ArchiveCaptureCursorScope
    ) throws -> CaptureProgress {
        guard let checkpoint = try catalog.archiveCursorCheckpoint(
            for: cursorScope.metadataKey
        ) else {
            return Self.initialCaptureProgress(for: adapters)
        }
        let decoded: CaptureProgress
        do {
            decoded = try ArchiveCanonicalJSON.decode(
                CaptureProgress.self,
                from: checkpoint.payload
            )
            guard try ArchiveCanonicalJSON.encode(decoded) == checkpoint.payload else {
                throw ArchiveCaptureCoordinatorError.invalidCaptureContinuation
            }
        } catch {
            throw ArchiveCaptureCoordinatorError.invalidCaptureContinuation
        }
        let sources = adapters.map { $0.source.rawValue }
        guard decoded.schemaVersion == 2,
              decoded.sources.allSatisfy(Self.valid),
              (decoded.sources.isEmpty
                  ? decoded.nextSourceIndex == 0
                  : decoded.sources.indices.contains(decoded.nextSourceIndex)) else {
            throw ArchiveCaptureCoordinatorError.invalidCaptureContinuation
        }
        guard decoded.sources.map(\.source) == sources else {
            return Self.initialCaptureProgress(for: adapters)
        }
        return decoded
    }

    private static func valid(_ progress: SourceCaptureProgress) -> Bool {
        guard !progress.source.isEmpty else { return false }
        if let digest = progress.locatorSetDigest,
           !ArchiveV2Hash.isValidSHA256(digest) {
            return false
        }
        if let exhaustedDigest = progress.exhaustedDigest,
           !ArchiveV2Hash.isValidSHA256(exhaustedDigest) {
            return false
        }
        for locator in [
            progress.lastLocator,
            progress.sweepUpperBound,
            progress.wrapEnd,
        ].compactMap({ $0 }) {
            if locator.isEmpty || locator.utf8.count > 4_096 { return false }
        }
        return progress.locatorSetDigest != nil || (
            progress.lastLocator == nil
                && progress.sweepUpperBound == nil
                && progress.wrapEnd == nil
                && progress.didWrap
                && progress.exhaustedDigest == nil
        )
    }

    private static func stableLocatorSnapshots(_ locators: [String]) -> [LocatorSnapshot] {
        var byKey: [String: String] = [:]
        for locator in locators {
            let key = ArchiveLocatorClassifier.normalize(locator) ?? locator
            guard !key.isEmpty else { continue }
            if let existing = byKey[key] {
                byKey[key] = min(existing, locator)
            } else {
                byKey[key] = locator
            }
        }
        return byKey.map { LocatorSnapshot(locator: $0.value, key: $0.key) }
            .sorted { ($0.key, $0.locator) < ($1.key, $1.locator) }
    }

    private static func locatorSetDigest(_ snapshots: [LocatorSnapshot]) throws -> String {
        ArchiveV2Hash.sha256(
            try ArchiveCanonicalJSON.encode(snapshots.map(\.key).sorted())
        )
    }

    private static func nextCaptureSource(
        in progress: CaptureProgress,
        availableSources: Set<Int>
    ) -> Int? {
        guard !progress.sources.isEmpty else { return nil }
        for offset in 0 ..< progress.sources.count {
            let index = (progress.nextSourceIndex + offset) % progress.sources.count
            let source = progress.sources[index]
            if availableSources.contains(index),
               source.locatorSetDigest != nil,
               source.exhaustedDigest != source.locatorSetDigest {
                return index
            }
        }
        return nil
    }

    private static func startSweep(
        _ progress: inout SourceCaptureProgress,
        digest: String,
        snapshots: [LocatorSnapshot]
    ) {
        let anchor = progress.lastLocator
        progress.locatorSetDigest = digest
        progress.sweepUpperBound = snapshots.last?.key
        progress.wrapEnd = anchor.flatMap { anchor in
            snapshots.last(where: { $0.key <= anchor })?.key
        }
        progress.didWrap = anchor == nil
        progress.exhaustedDigest = nil
    }

    private static func nextLocator(
        in snapshots: [LocatorSnapshot],
        progress: inout SourceCaptureProgress
    ) -> (snapshot: LocatorSnapshot, didWrap: Bool)? {
        guard !snapshots.isEmpty,
              let upperBound = progress.sweepUpperBound,
              progress.exhaustedDigest != progress.locatorSetDigest else {
            return nil
        }

        if !progress.didWrap {
            if let next = snapshots.first(where: {
                $0.key > (progress.lastLocator ?? "") && $0.key <= upperBound
            }) {
                return (next, false)
            }
            progress.didWrap = true
            progress.lastLocator = nil
        }

        let phaseEnd = progress.wrapEnd ?? upperBound
        if let next = snapshots.first(where: {
            $0.key > (progress.lastLocator ?? "") && $0.key <= phaseEnd
        }) {
            return (next, true)
        }
        progress.exhaustedDigest = progress.locatorSetDigest
        return nil
    }

    private static func finishSweepIfAtCurrentBoundary(
        _ progress: inout SourceCaptureProgress,
        snapshots: [LocatorSnapshot]
    ) {
        guard let lastLocator = progress.lastLocator,
              let upperBound = progress.sweepUpperBound else { return }
        let phaseEnd = progress.didWrap ? (progress.wrapEnd ?? upperBound) : upperBound
        let hasLaterInPhase = snapshots.contains {
            $0.key > lastLocator && $0.key <= phaseEnd
        }
        guard !hasLaterInPhase else { return }
        if progress.didWrap || progress.wrapEnd == nil {
            progress.exhaustedDigest = progress.locatorSetDigest
        }
    }

    private static func lockedBatch(
        for captures: [ArchiveCapture]
    ) throws -> LockedBindingBatch {
        guard let last = captures.last, !captures.isEmpty else {
            throw ArchiveCaptureCoordinatorError.invalidBindingContinuation
        }
        return LockedBindingBatch(
            end: PersistedCaptureCursor(
                ArchiveCaptureCursor(
                    capturedAt: last.capturedAt,
                    captureID: last.captureID
                )
            ),
            count: captures.count,
            captureIDsSHA256: ArchiveV2Hash.sha256(
                try ArchiveCanonicalJSON.encode(captures.map(\.captureID))
            )
        )
    }

    private static func bindingBatchFingerprint(
        _ batch: LockedBindingBatch?
    ) throws -> String? {
        guard let batch else { return nil }
        return ArchiveV2Hash.sha256(try ArchiveCanonicalJSON.encode(batch))
    }

    private func lockedBindingTargets(
        _ progress: BindingProgress
    ) throws -> [ArchiveCapture] {
        guard let lockedBatch = progress.lockedBatch else {
            throw ArchiveCaptureCoordinatorError.invalidBindingContinuation
        }
        let targets = try catalog.unboundCaptures(
            limit: lockedBatch.count,
            after: progress.after?.value,
            through: lockedBatch.end.value
        )
        guard targets.count == lockedBatch.count,
              targets.last.map({
                  ($0.capturedAt, $0.captureID)
                      == (lockedBatch.end.capturedAt, lockedBatch.end.captureID)
              }) == true,
              ArchiveV2Hash.sha256(
                  try ArchiveCanonicalJSON.encode(targets.map(\.captureID))
              ) == lockedBatch.captureIDsSHA256 else {
            throw ArchiveCaptureCoordinatorError.invalidBindingContinuation
        }
        return targets
    }

    private func persistBindingProgress(_ progress: BindingProgress) throws {
        _ = try catalog.storeArchiveCursorCheckpoint(
            try ArchiveCanonicalJSON.encode(progress),
            for: .bindingCycle
        )
    }

    private func bindingProgress() throws -> BindingProgress {
        guard let checkpoint = try catalog.archiveCursorCheckpoint(for: .bindingCycle) else {
            return BindingProgress(
                schemaVersion: 2,
                boundary: nil,
                after: nil,
                lockedBatch: nil
            )
        }
        let decoded: BindingProgress
        do {
            decoded = try ArchiveCanonicalJSON.decode(
                BindingProgress.self,
                from: checkpoint.payload
            )
            guard try ArchiveCanonicalJSON.encode(decoded) == checkpoint.payload else {
                throw ArchiveCaptureCoordinatorError.invalidBindingContinuation
            }
        } catch {
            throw ArchiveCaptureCoordinatorError.invalidBindingContinuation
        }
        guard decoded.schemaVersion == 2,
              decoded.boundary != nil || (decoded.after == nil && decoded.lockedBatch == nil),
              Self.valid(decoded.boundary),
              Self.valid(decoded.after),
              Self.valid(decoded.lockedBatch) else {
            throw ArchiveCaptureCoordinatorError.invalidBindingContinuation
        }
        if let after = decoded.after, let boundary = decoded.boundary,
           (after.capturedAt, after.captureID) > (boundary.capturedAt, boundary.captureID) {
            throw ArchiveCaptureCoordinatorError.invalidBindingContinuation
        }
        if let lockedBatch = decoded.lockedBatch,
           let boundary = decoded.boundary {
            if (lockedBatch.end.capturedAt, lockedBatch.end.captureID)
                > (boundary.capturedAt, boundary.captureID) {
                throw ArchiveCaptureCoordinatorError.invalidBindingContinuation
            }
            if let after = decoded.after,
               (lockedBatch.end.capturedAt, lockedBatch.end.captureID)
                <= (after.capturedAt, after.captureID) {
                throw ArchiveCaptureCoordinatorError.invalidBindingContinuation
            }
        }
        return decoded
    }

    private static func valid(_ batch: LockedBindingBatch?) -> Bool {
        guard let batch else { return true }
        return batch.count > 0
            && valid(batch.end)
            && ArchiveV2Hash.isValidSHA256(batch.captureIDsSHA256)
    }

    private static func valid(_ cursor: PersistedCaptureCursor?) -> Bool {
        guard let cursor else { return true }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return ArchiveV2Hash.isValidSHA256(cursor.captureID)
            && formatter.date(from: cursor.capturedAt).map(formatter.string(from:)) == cursor.capturedAt
    }

    private func captureLocator(
        adapter: any SessionAdapter,
        exactAdapter: any ExactArchiveSourceAdapter,
        locator: String,
        machineID: String
    ) async throws -> (item: ArchiveCaptureCycleItem, capture: ArchiveCaptureResult?) {
        try Task.checkCancellation()
        if ArchiveLocatorClassifier.isVirtual(locator) {
            return (
                ArchiveCaptureCycleItem(
                    source: adapter.source,
                    locator: locator,
                    classification: .unsupportedVirtual,
                    captureID: nil,
                    diagnostic: nil
                ),
                nil
            )
        }
        let descriptor: ArchiveSourceDescriptor
        do {
            descriptor = try await exactAdapter.archiveSourceDescriptor(locator: locator)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return (
                ArchiveCaptureCycleItem(
                    source: adapter.source,
                    locator: locator,
                    classification: .unsafe("descriptor rejected"),
                    captureID: nil,
                    diagnostic: String(describing: error)
                ),
                nil
            )
        }
        try Task.checkCancellation()
        let classification = ArchiveLocatorClassifier.classify(
            descriptor: descriptor,
            enumeratedLocator: locator
        )
        guard case .declaredSingleFile = classification else {
            return (
                ArchiveCaptureCycleItem(
                    source: adapter.source,
                    locator: locator,
                    classification: classification,
                    captureID: nil,
                    diagnostic: nil
                ),
                nil
            )
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
            testHooks.afterCaptureRecorded?(result)
            return (
                ArchiveCaptureCycleItem(
                    source: adapter.source,
                    locator: locator,
                    classification: classification,
                    captureID: result.capture.captureID,
                    diagnostic: nil
                ),
                result
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return (
                ArchiveCaptureCycleItem(
                    source: adapter.source,
                    locator: locator,
                    classification: classification,
                    captureID: nil,
                    diagnostic: String(describing: error)
                ),
                nil
            )
        }
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
