import Foundation
import EngramCoreRead

public struct KnownIndexedFileState: Equatable, Sendable {
    public let sizeBytes: Int64
    public let indexedAt: String?
    public let needsInstructionBackfill: Bool

    public init(sizeBytes: Int64, indexedAt: String?, needsInstructionBackfill: Bool = false) {
        self.sizeBytes = sizeBytes
        self.indexedAt = indexedAt
        self.needsInstructionBackfill = needsInstructionBackfill
    }

    static func fromIndexedSessionRow(
        sizeBytes: Int64?,
        indexedAt: String?,
        needsInstructionBackfill: Bool
    ) -> KnownIndexedFileState? {
        if let sizeBytes {
            return KnownIndexedFileState(
                sizeBytes: sizeBytes,
                indexedAt: indexedAt,
                needsInstructionBackfill: needsInstructionBackfill
            )
        }
        guard needsInstructionBackfill else { return nil }
        return KnownIndexedFileState(
            sizeBytes: 0,
            indexedAt: indexedAt,
            needsInstructionBackfill: true
        )
    }
}

public struct FileIndexStat: Equatable, Sendable {
    public let sizeBytes: Int64
    public let modifiedAtNanos: Int64
    public let inode: Int64?
    public let device: Int64?

    public init(sizeBytes: Int64, modifiedAtNanos: Int64, inode: Int64?, device: Int64?) {
        self.sizeBytes = sizeBytes
        self.modifiedAtNanos = modifiedAtNanos
        self.inode = inode
        self.device = device
    }

    public static func directFileStat(locator: String) -> FileIndexStat? {
        guard !locator.hasPrefix("sync://"),
              !locator.hasPrefix("cursor-modern:"),
              !locator.contains("::"),
              locator.range(of: "?composer=") == nil
        else {
            return nil
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: locator),
              let size = attributes[.size] as? NSNumber,
              let modifiedAt = attributes[.modificationDate] as? Date
        else {
            return nil
        }
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.int64Value
        let device = (attributes[.systemNumber] as? NSNumber)?.int64Value
        return FileIndexStat(
            sizeBytes: size.int64Value,
            modifiedAtNanos: Int64((modifiedAt.timeIntervalSince1970 * 1_000_000_000).rounded()),
            inode: inode,
            device: device
        )
    }

    var legacyState: (sizeBytes: Int64, modifiedAt: Date) {
        (
            sizeBytes: sizeBytes,
            modifiedAt: Date(timeIntervalSince1970: TimeInterval(modifiedAtNanos) / 1_000_000_000)
        )
    }
}

public enum FileIndexParseStatus: String, Sendable {
    case ok
    case terminal
    case retry
}

public enum FileIndexDecision: Equatable, Sendable {
    case skip
    case full

    public static func decide(stat: FileIndexStat, state: FileIndexState?, now: Date) -> FileIndexDecision {
        guard let state else { return .full }
        guard state.schemaVersion == FileIndexState.currentSchemaVersion else { return .full }
        guard state.sameFileIdentity(as: stat) else { return .full }

        switch state.parseStatus {
        case .ok, .terminal:
            return .skip
        case .retry:
            guard let retryAfter = state.retryAfterEpochSeconds else { return .full }
            return Int64(now.timeIntervalSince1970) < retryAfter ? .skip : .full
        }
    }
}

public struct FileIndexState: Equatable, Sendable {
    // v3 forces one authoritative reparse for Qoder's project-level subagent
    // identity introduced after v2. docs/invariants.md #2: genuine subagent
    // layouts remain skip and must receive their collision-free child id.
    public static let currentSchemaVersion = 3
    private static let retryBaseSeconds: Int64 = 300
    private static let retryMaxSeconds: Int64 = 3_600
    public let source: SourceName
    public let locator: String
    public var sizeBytes: Int64
    public var modifiedAtNanos: Int64
    public var inode: Int64?
    public var device: Int64?
    public var parsedOffset: Int64
    public var boundaryHash: String?
    public var parseStatus: FileIndexParseStatus
    public var failureKind: ParserFailure?
    public var retryAfterEpochSeconds: Int64?
    public var retryCount: Int
    public var lastError: String?
    public var schemaVersion: Int
    public var updatedAtEpochSeconds: Int64

    public init(
        source: SourceName,
        locator: String,
        sizeBytes: Int64,
        modifiedAtNanos: Int64,
        inode: Int64?,
        device: Int64?,
        parsedOffset: Int64,
        boundaryHash: String?,
        parseStatus: FileIndexParseStatus,
        failureKind: ParserFailure?,
        retryAfterEpochSeconds: Int64?,
        retryCount: Int,
        lastError: String?,
        schemaVersion: Int,
        updatedAtEpochSeconds: Int64
    ) {
        self.source = source
        self.locator = locator
        self.sizeBytes = sizeBytes
        self.modifiedAtNanos = modifiedAtNanos
        self.inode = inode
        self.device = device
        self.parsedOffset = parsedOffset
        self.boundaryHash = boundaryHash
        self.parseStatus = parseStatus
        self.failureKind = failureKind
        self.retryAfterEpochSeconds = retryAfterEpochSeconds
        self.retryCount = retryCount
        self.lastError = lastError
        self.schemaVersion = schemaVersion
        self.updatedAtEpochSeconds = updatedAtEpochSeconds
    }

    public static func success(
        source: SourceName,
        locator: String,
        stat: FileIndexStat,
        now: Date,
        parsedOffset: Int64? = nil,
        boundaryHash: String? = nil
    ) -> FileIndexState {
        FileIndexState(
            source: source,
            locator: locator,
            sizeBytes: stat.sizeBytes,
            modifiedAtNanos: stat.modifiedAtNanos,
            inode: stat.inode,
            device: stat.device,
            parsedOffset: parsedOffset ?? stat.sizeBytes,
            boundaryHash: boundaryHash,
            parseStatus: .ok,
            failureKind: nil,
            retryAfterEpochSeconds: nil,
            retryCount: 0,
            lastError: nil,
            schemaVersion: currentSchemaVersion,
            updatedAtEpochSeconds: Int64(now.timeIntervalSince1970)
        )
    }

    public static func failure(
        source: SourceName,
        locator: String,
        stat: FileIndexStat,
        failure: ParserFailure,
        previous: FileIndexState?,
        now: Date
    ) -> FileIndexState {
        let isTerminal = isTerminalFailure(failure)
        let retryCount = isTerminal ? 0 : (previous?.retryCount ?? 0) + 1
        let retryAfter = isTerminal ? nil : Int64(now.timeIntervalSince1970) + retryDelaySeconds(retryCount: retryCount)
        return FileIndexState(
            source: source,
            locator: locator,
            sizeBytes: stat.sizeBytes,
            modifiedAtNanos: stat.modifiedAtNanos,
            inode: stat.inode,
            device: stat.device,
            parsedOffset: previous?.parsedOffset ?? 0,
            boundaryHash: previous?.boundaryHash,
            parseStatus: isTerminal ? .terminal : .retry,
            failureKind: failure,
            retryAfterEpochSeconds: retryAfter,
            retryCount: retryCount,
            lastError: failure.rawValue,
            schemaVersion: currentSchemaVersion,
            updatedAtEpochSeconds: Int64(now.timeIntervalSince1970)
        )
    }

    public func sameFileIdentity(as stat: FileIndexStat) -> Bool {
        sizeBytes == stat.sizeBytes
            && modifiedAtNanos == stat.modifiedAtNanos
            && inode == stat.inode
            && device == stat.device
    }

    private static func retryDelaySeconds(retryCount: Int) -> Int64 {
        let shift = max(0, min(retryCount - 1, 4))
        return min(retryBaseSeconds << shift, retryMaxSeconds)
    }

    static func isTerminalFailure(_ failure: ParserFailure) -> Bool {
        switch failure {
        case .fileTooLarge,
             .messageLimitExceeded,
             .lineTooLarge,
             .unsupportedVirtualLocator,
             .noVisibleMessages:
            return true
        case .fileMissing,
             .invalidUtf8,
             .truncatedJSON,
             .truncatedJSONL,
             .malformedJSON,
             .malformedToolCall,
             .deeplyNestedRecord,
             .fileModifiedDuringParse,
             .sqliteUnreadable,
             .grpcUnavailable:
            return false
        }
    }
}

// Not refined to `Sendable`: a conforming type (`SessionBatchUpsert`) wraps a
// connection-bound GRDB `Database` that must stay on its owning thread, so the
// protocol cannot promise cross-thread safety for all conformers.
public protocol IndexingWriteSink {
    func upsertBatch(
        _ snapshots: [AuthoritativeSessionSnapshot],
        reason: IndexingWriteReason
    ) throws -> SessionBatchUpsertResult

    /// Atomically pair each snapshot write with its parsed file identity when
    /// the sink supports a transactional writer. The array preserves batch
    /// index pairing for adapters that emit duplicate session ids.
    func upsertBatch(
        _ snapshots: [AuthoritativeSessionSnapshot],
        fileIndexStates: [FileIndexState?],
        reason: IndexingWriteReason
    ) throws -> SessionBatchUpsertResult

    /// Reclassify and hide any existing rows whose latest parsed snapshot
    /// belongs to a disabled output source. This intentionally does not mark
    /// the backing file as indexed, so re-enabling the source reparses it.
    func suppressExcludedSnapshots(_ snapshots: [AuthoritativeSessionSnapshot]) throws

    func knownIndexedFileStates(source: SourceName, locators: [String]) throws -> [String: KnownIndexedFileState]
    func knownFileIndexStates(source: SourceName, locators: [String]) throws -> [String: FileIndexState]
    func knownTailMergeSnapshots(source: SourceName, locators: [String]) throws -> [String: AuthoritativeSessionSnapshot]
    func upsertFileIndexState(_ state: FileIndexState) throws
    /// Delete `file_index_state` rows for `source` whose locator is not in
    /// `locators` and falls under at least one of `roots`. Empty keep-set or
    /// empty roots: no-op (return 0).
    func pruneOrphanFileIndexStates(
        source: SourceName,
        keeping locators: [String],
        under roots: [String]
    ) throws -> Int
}

public extension IndexingWriteSink {
    func upsertBatch(
        _ snapshots: [AuthoritativeSessionSnapshot],
        fileIndexStates: [FileIndexState?],
        reason: IndexingWriteReason
    ) throws -> SessionBatchUpsertResult {
        let result = try upsertBatch(snapshots, reason: reason)
        for (index, item) in result.results.enumerated() {
            guard item.action == .merge || item.action == .noop,
                  index < fileIndexStates.count,
                  let state = fileIndexStates[index] else {
                continue
            }
            do {
                try upsertFileIndexState(state)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Test/custom sinks keep the historical best-effort behavior.
                // The production database sink overrides this method and writes
                // the snapshot + state in one per-item savepoint.
            }
        }
        return result
    }

    func suppressExcludedSnapshots(_ snapshots: [AuthoritativeSessionSnapshot]) throws {}

    func knownIndexedFileStates(source: SourceName, locators: [String]) throws -> [String: KnownIndexedFileState] {
        [:]
    }

    func knownFileIndexStates(source: SourceName, locators: [String]) throws -> [String: FileIndexState] {
        [:]
    }

    func knownTailMergeSnapshots(source: SourceName, locators: [String]) throws -> [String: AuthoritativeSessionSnapshot] {
        [:]
    }

    func upsertFileIndexState(_ state: FileIndexState) throws {}

    func pruneOrphanFileIndexStates(
        source: SourceName,
        keeping locators: [String],
        under roots: [String]
    ) throws -> Int {
        0
    }
}
