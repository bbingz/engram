import CryptoKit
import Darwin
import Dispatch
import Foundation
import Logging

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

/// One receipt as the MCP capture list reports it.
///
/// Every field is captured when the receipt is scanned or published, so a page
/// is served from the process-local index without a durable receipt read
/// (retro PR-3, F07).
public struct ArchiveCaptureSummary: Equatable, Sendable {
    public let manifestSHA256: String
    public let receiptSHA256: String
    public let sessionID: String
    public let captureID: String
    public let rawByteCount: Int64
    public let storedAt: String
}

public struct ArchiveCapturePage: Equatable, Sendable {
    public let captures: [ArchiveCaptureSummary]
    public let nextCursor: String?
}

/// A byte window of an archived source plus the manifest describing it.
public struct ArchiveSourceWindow: Sendable {
    public let manifest: ArchiveSourceManifest
    /// Window bytes, clamped to the end of the source.
    public let bytes: Data
    /// Raw byte count of the whole source, not of the window.
    public let totalBytes: Int64

    public init(manifest: ArchiveSourceManifest, bytes: Data, totalBytes: Int64) {
        self.manifest = manifest
        self.bytes = bytes
        self.totalBytes = totalBytes
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
    /// Invoked after a successful full disk scan that builds the list index,
    /// once per process lifetime for a given store instance (single-flight).
    let afterListIndexBuild: (@Sendable () -> Void)?

    init(
        maximumWriteBytesPerCall: Int? = nil,
        afterWriteCall: (@Sendable (Int) -> Void)? = nil,
        beforeFileFsync: (@Sendable (ArchiveEnvelopeKind) throws -> Void)? = nil,
        beforeDirectoryFsync: (@Sendable (ArchiveEnvelopeKind) throws -> Void)? = nil,
        beforeDirectoryParentFsync: (@Sendable (URL) throws -> Void)? = nil,
        beforeFinalPublish: (@Sendable (ArchiveEnvelopeKind, URL) throws -> Void)? = nil,
        afterFinalPublish: (@Sendable (ArchiveEnvelopeKind, URL) -> Void)? = nil,
        afterExistingEnvelopeVerified: (@Sendable (URL) throws -> Void)? = nil,
        afterListIndexBuild: (@Sendable () -> Void)? = nil
    ) {
        self.maximumWriteBytesPerCall = maximumWriteBytesPerCall
        self.afterWriteCall = afterWriteCall
        self.beforeFileFsync = beforeFileFsync
        self.beforeDirectoryFsync = beforeDirectoryFsync
        self.beforeDirectoryParentFsync = beforeDirectoryParentFsync
        self.beforeFinalPublish = beforeFinalPublish
        self.afterFinalPublish = afterFinalPublish
        self.afterExistingEnvelopeVerified = afterExistingEnvelopeVerified
        self.afterListIndexBuild = afterListIndexBuild
    }
}

/// Process-local index of published receipts for discovery.
///
/// Archive v2 is append-only on the product path (zero-delete), so a receipt
/// observed once stays. `listMachines`/`listReceipts` used to full-scan on
/// every call; even the scan fast path is ~18s on a real ~25k-receipt archive,
/// which makes remote MCP list tools unusable. This index is warmed once from
/// the scan path (single-flight) and then updated on each successful
/// `createReceipt`; subsequent lists are O(log n + page).
///
/// State machine (retro PR-3):
/// - `.cold` → `.building` → `.ready`. Receipts published while cold or
///   building queue in `pending` and are merged when the build lands.
/// - A build failure returns to `.cold` and memoizes the error for
///   `retryBackoff`. Within that window an implicit (list-triggered) build
///   throws the memoized error instead of re-running the multi-second scan;
///   an explicit `warmListIndex()` passes `forced: true` and always rebuilds
///   (retro PR-3, F05).
/// - `pending` is capped at `maxPendingEntries` (retro PR-3, F20).
/// - The merged structure is built outside the lock; the lock is held only for
///   the bounded pending merge and the swap (retro PR-3, F04).
private final class ArchiveReceiptListIndex: @unchecked Sendable {
    struct Entry: Equatable, Sendable {
        let machineID: String
        let manifestSHA256: String
        let receiptSHA256: String
        let sessionID: String
        let captureID: String
        let rawByteCount: Int64
        let storedAt: String
    }

    /// Window during which a failed build is not retried by a list call.
    static let defaultRetryBackoff: TimeInterval = 3

    /// Upper bound on receipts buffered while the index is cold or building.
    static let maxPendingEntries = 4096

    /// Rescans forced by a mid-scan `pending` overflow before giving up.
    private static let maxBuildAttempts = 3

    private enum Phase {
        case cold
        case building
        case ready
    }

    private struct FailureMemo {
        let error: Error
        /// Monotonic; unaffected by wall-clock changes.
        let at: DispatchTime
    }

    private let condition = NSCondition()
    private let retryBackoff: TimeInterval
    private let log = Logger(label: "engram.remote.archive-index")
    private var phase: Phase = .cold
    private var poisoned = false
    private var machineIDs: [String] = []
    private var receiptsByMachine: [String: [Entry]] = [:]
    private var pending: [Entry] = []
    private var failure: FailureMemo?
    /// Raised when `pending` overflowed while a scan was in flight: that scan
    /// may already have walked past the shard holding a dropped receipt, so its
    /// result is discarded and the scan re-run.
    private var rescanRequired = false

    init(retryBackoff: TimeInterval = ArchiveReceiptListIndex.defaultRetryBackoff) {
        self.retryBackoff = retryBackoff
    }

    func note(_ entry: Entry) {
        condition.lock()
        defer { condition.unlock() }
        switch phase {
        case .ready:
            applyLocked(entry)
        case .cold, .building:
            // Bounded queue (retro PR-3, F20): while a warm keeps failing this
            // array would otherwise grow for the whole process lifetime.
            // Dropping it loses nothing from the final index, and only because
            // every queued receipt is already durable on disk before `note`
            // runs, so a full rescan re-discovers it. The one unsafe case is a
            // drop during a scan that already walked past the receipt's shard;
            // that scan's result is therefore discarded and re-run.
            if pending.count >= Self.maxPendingEntries {
                pending.removeAll(keepingCapacity: false)
                if phase == .building { rescanRequired = true }
                return
            }
            pending.append(entry)
        }
    }

    /// Build the index if it is not ready. `forced` skips the failure backoff.
    func ensureReady(forced: Bool, _ build: () throws -> [Entry]) throws {
        var attemptsLeft = Self.maxBuildAttempts
        while true {
            condition.lock()
            while phase == .building {
                condition.wait()
            }
            if phase == .ready {
                let failed = poisoned
                condition.unlock()
                if failed { throw ArchiveStoreError.conflict }
                return
            }
            if !forced, let memo = failure, !Self.hasExpired(memo, backoff: retryBackoff) {
                // Negative caching (retro PR-3, F05): without it every waiting
                // lister wakes, sees cold, and serially re-runs the full scan.
                condition.unlock()
                throw memo.error
            }
            phase = .building
            failure = nil
            rescanRequired = false
            condition.unlock()

            let built: [Entry]
            do {
                built = try build()
            } catch {
                condition.lock()
                phase = .cold
                failure = FailureMemo(error: error, at: DispatchTime.now())
                condition.broadcast()
                condition.unlock()
                throw error
            }

            // Off-lock (retro PR-3, F04): grouping, manifest-keyed dedup and
            // the per-machine sort are the O(n log n) part of the merge and run
            // without the lock, so `note()` (and therefore `createReceipt`) is
            // never blocked behind a full-archive merge.
            var grouped: [String: [String: Entry]] = [:]
            var conflict: (manifest: String, first: String, second: String)?
            for entry in built {
                if let existing = grouped[entry.machineID]?[entry.manifestSHA256] {
                    if existing.receiptSHA256 != entry.receiptSHA256 {
                        conflict = (
                            entry.manifestSHA256,
                            existing.receiptSHA256,
                            entry.receiptSHA256
                        )
                        break
                    }
                } else {
                    grouped[entry.machineID, default: [:]][entry.manifestSHA256] = entry
                }
            }
            var sorted: [String: [Entry]] = [:]
            if conflict == nil {
                sorted.reserveCapacity(grouped.count)
                for (machineID, entries) in grouped {
                    sorted[machineID] = entries.values.sorted { $0.manifestSHA256 < $1.manifestSHA256 }
                }
            }

            condition.lock()
            attemptsLeft -= 1
            if rescanRequired {
                rescanRequired = false
                phase = .cold
                let exhausted = attemptsLeft <= 0
                if exhausted {
                    // Fail closed rather than publish a page set that is
                    // knowingly missing receipts.
                    failure = FailureMemo(error: ArchiveStoreError.io, at: DispatchTime.now())
                }
                condition.broadcast()
                condition.unlock()
                if exhausted { throw ArchiveStoreError.io }
                continue
            }
            if let conflict {
                poisonLocked(
                    manifestSHA256: conflict.manifest,
                    receiptSHA256: conflict.first,
                    conflictingReceiptSHA256: conflict.second
                )
            } else {
                machineIDs = sorted.keys.sorted()
                receiptsByMachine = sorted
                // `note` appends under this same lock, so every entry queued
                // before the swap is merged here exactly once (the
                // manifest-keyed dedup absorbs scan/pending overlap) and every
                // entry queued after it applies directly to the ready index.
                for entry in pending {
                    applyLocked(entry)
                }
            }
            pending.removeAll(keepingCapacity: false)
            phase = .ready
            let failed = poisoned
            condition.broadcast()
            condition.unlock()
            if failed { throw ArchiveStoreError.conflict }
            return
        }
    }

    func listMachineIDs(after cursor: String?, limit: Int) throws -> [String] {
        condition.lock()
        defer { condition.unlock() }
        guard phase == .ready else {
            throw ArchiveStoreError.io
        }
        if poisoned { throw ArchiveStoreError.conflict }
        let start = cursor.map { key in
            Self.partitionPoint(machineIDs.count) { machineIDs[$0] > key }
        } ?? 0
        let end = min(start + limit + 1, machineIDs.count)
        guard start < end else { return [] }
        return Array(machineIDs[start..<end])
    }

    func listEntries(
        machineID: String,
        after cursor: String?,
        limit: Int
    ) throws -> [Entry] {
        condition.lock()
        defer { condition.unlock() }
        guard phase == .ready else {
            throw ArchiveStoreError.io
        }
        if poisoned { throw ArchiveStoreError.conflict }
        let entries = receiptsByMachine[machineID] ?? []
        // Binary search over the entries themselves: projecting their manifest
        // digests into a fresh array allocated O(n) per page under this lock
        // (retro PR-3, F19).
        let start = cursor.map { key in
            Self.partitionPoint(entries.count) { entries[$0].manifestSHA256 > key }
        } ?? 0
        let end = min(start + limit + 1, entries.count)
        guard start < end else { return [] }
        return Array(entries[start..<end])
    }

    private func applyLocked(_ entry: Entry) {
        if poisoned { return }
        var insertAt = 0
        var existing: Entry?
        if let list = receiptsByMachine[entry.machineID] {
            insertAt = Self.partitionPoint(list.count) {
                list[$0].manifestSHA256 >= entry.manifestSHA256
            }
            if insertAt < list.count, list[insertAt].manifestSHA256 == entry.manifestSHA256 {
                existing = list[insertAt]
            }
        }
        if let existing {
            if existing.receiptSHA256 != entry.receiptSHA256 {
                poisonLocked(
                    manifestSHA256: entry.manifestSHA256,
                    receiptSHA256: existing.receiptSHA256,
                    conflictingReceiptSHA256: entry.receiptSHA256
                )
            }
            return
        }
        receiptsByMachine[entry.machineID, default: []].insert(entry, at: insertAt)
        let machineAt = Self.partitionPoint(machineIDs.count) { machineIDs[$0] >= entry.machineID }
        if machineAt == machineIDs.count || machineIDs[machineAt] != entry.machineID {
            machineIDs.insert(entry.machineID, at: machineAt)
        }
    }

    /// Fail every list closed for the rest of the process lifetime.
    ///
    /// The blast radius is deliberate — a receipt digest that diverges for a
    /// manifest is unexplained, so no list is trusted afterwards — but it used
    /// to be silent, leaving an operator with `conflict` from every list and
    /// nothing in the logs (retro PR-3, F06).
    private func poisonLocked(
        manifestSHA256: String,
        receiptSHA256: String,
        conflictingReceiptSHA256: String
    ) {
        poisoned = true
        machineIDs = []
        receiptsByMachine = [:]
        log.error(
            """
            archive list index poisoned: two receipt digests for one manifest; \
            every archive list fails closed until this process restarts
            """,
            metadata: [
                "manifestSHA256": "\(manifestSHA256)",
                "receiptSHA256": "\(receiptSHA256)",
                "conflictingReceiptSHA256": "\(conflictingReceiptSHA256)",
            ]
        )
    }

    private static func hasExpired(_ memo: FailureMemo, backoff: TimeInterval) -> Bool {
        guard backoff > 0 else { return true }
        let elapsed = DispatchTime.now().uptimeNanoseconds &- memo.at.uptimeNanoseconds
        return Double(elapsed) >= backoff * 1_000_000_000
    }

    /// First index in `0..<count` satisfying the monotone predicate, or `count`.
    private static func partitionPoint(_ count: Int, _ isAtOrAfter: (Int) -> Bool) -> Int {
        var low = 0
        var high = count
        while low < high {
            let mid = low + (high - low) / 2
            if isAtOrAfter(mid) {
                high = mid
            } else {
                low = mid + 1
            }
        }
        return low
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
    /// Shared across value copies of this store so list warm and receipt
    /// publication see one process-local index.
    private let listIndex: ArchiveReceiptListIndex

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
        testHooks: ArchiveStoreTestHooks,
        listIndexRetryBackoff: TimeInterval = ArchiveReceiptListIndex.defaultRetryBackoff
    ) throws {
        try self.init(
            root: root,
            key: key,
            serverID: serverID,
            hooks: testHooks,
            now: { Self.currentTimestamp() },
            listIndexRetryBackoff: listIndexRetryBackoff
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
        now: @escaping @Sendable () -> String,
        listIndexRetryBackoff: TimeInterval = ArchiveReceiptListIndex.defaultRetryBackoff
    ) throws {
        guard Self.isSafeServerID(serverID) else {
            throw ArchiveStoreError.invalidReceipt
        }
        self.root = root.standardizedFileURL
        self.serverID = serverID
        self.codec = ArchiveEnvelopeCodec(key: key)
        self.hooks = hooks
        self.now = now
        self.listIndex = ArchiveReceiptListIndex(retryBackoff: listIndexRetryBackoff)

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

    /// Read one byte window of an archived source.
    ///
    /// Only chunks overlapping `[offset, offset + maxBytes)` are fetched and
    /// decrypted, so the cost tracks the window instead of the whole source
    /// (retro PR-2, F01). Integrity of the served bytes rests on the manifest
    /// envelope AEAD plus each fetched chunk's `rawByteCount`/`rawSHA256`; the
    /// `wholeSourceSHA256` fold that `getManifest` performs is deliberately not
    /// done here, because it can only be computed by reading every chunk —
    /// exactly the cost this path exists to avoid. Callers that need the
    /// whole-source guarantee keep using `getManifest`.
    public func readSourceWindow(
        manifestDigest: String,
        offset: Int,
        maxBytes: Int
    ) throws -> ArchiveSourceWindow {
        try Self.validateDigest(manifestDigest)
        guard offset >= 0, maxBytes > 0 else {
            throw ArchiveStoreError.invalidPage
        }
        let bytes = try readEnvelope(
            at: url(for: manifestDigest, kind: .manifest, createShard: false),
            expectedKind: .manifest,
            expectedDigest: manifestDigest
        )
        let manifest = try decodedManifest(bytes, expectedDigest: manifestDigest)

        let windowEnd = offset > Int.max - maxBytes ? Int.max : offset + maxBytes
        var window = Data()
        var position = 0
        for chunk in manifest.chunks.sorted(by: { $0.ordinal < $1.ordinal }) {
            let chunkLength = Int(chunk.rawByteCount)
            let chunkStart = position
            position += chunkLength
            if position <= offset { continue }
            if chunkStart >= windowEnd { break }
            let object = try chunkObject(chunk, durableReferences: false)
            let sliceStart = max(0, offset - chunkStart)
            let sliceEnd = min(chunkLength, windowEnd - chunkStart)
            guard sliceStart < sliceEnd else { continue }
            window.append(object.subdata(in: sliceStart..<sliceEnd))
        }
        return ArchiveSourceWindow(
            manifest: manifest,
            bytes: window,
            totalBytes: manifest.rawByteCount
        )
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
            // Keep the list index complete if a concurrent warm is mid-scan.
            notePublishedReceipt(bytes: existing, manifestDigest: manifestDigest)
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
            notePublishedReceipt(bytes: receiptBytes, manifestDigest: manifestDigest)
            return ArchiveReceiptCreation(bytes: receiptBytes, result: .published)
        case .alreadyPresent(let existing):
            try validateReceiptBytes(
                existing,
                manifestDigest: manifestDigest,
                manifest: manifest
            )
            // Idempotent publish still contributes to the list index so a
            // concurrent warm that missed the file race sees the receipt.
            notePublishedReceipt(bytes: existing, manifestDigest: manifestDigest)
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

    /// Build the process-local list index from disk if it is not ready yet.
    ///
    /// Safe to call repeatedly and from concurrent threads: the first caller
    /// runs the scan, later callers wait and then return. Server startup
    /// should fire this in the background so the first client list is warm.
    ///
    /// This is the forced entry point: it rebuilds even inside the backoff
    /// window a previous failure opened, so an operator (or a restart of the
    /// warm task) can recover the index as soon as the cause is fixed. Lists
    /// take the implicit path and honor the backoff (retro PR-3, F05).
    public func warmListIndex() throws {
        try ensureListIndexReady(forced: true)
    }

    public func listMachines(cursor: String?, limit: Int) throws -> ArchiveMachinePage {
        try Self.validateLimit(limit)
        let cursorKey = try Self.decodeCursor(cursor)
        if let cursorKey,
           UUID(uuidString: cursorKey)?.uuidString != cursorKey {
            throw ArchiveStoreError.invalidPage
        }

        try ensureListIndexReady(forced: false)
        var candidates = try listIndex.listMachineIDs(after: cursorKey, limit: limit)
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
        let page = try listIndexPage(machineID: machineID, cursor: cursor, limit: limit)
        let summaries = try page.entries.map { entry in
            try ArchiveReceiptSummary(
                manifestSHA256: entry.manifestSHA256,
                receiptSHA256: entry.receiptSHA256
            )
        }
        do {
            return try ArchiveReceiptPage(receipts: summaries, nextCursor: page.nextCursor)
        } catch {
            throw ArchiveStoreError.invalidPage
        }
    }

    /// Receipt page carrying the fields the MCP capture list reports.
    ///
    /// Served from the index alone: the enrichment used to cost one durable
    /// `getReceipt` per entry, i.e. ~100 fsync-heavy reads for a default page
    /// (retro PR-3, F07).
    public func listCaptures(
        machineID: String,
        cursor: String?,
        limit: Int
    ) throws -> ArchiveCapturePage {
        let page = try listIndexPage(machineID: machineID, cursor: cursor, limit: limit)
        return ArchiveCapturePage(
            captures: page.entries.map { entry in
                ArchiveCaptureSummary(
                    manifestSHA256: entry.manifestSHA256,
                    receiptSHA256: entry.receiptSHA256,
                    sessionID: entry.sessionID,
                    captureID: entry.captureID,
                    rawByteCount: entry.rawByteCount,
                    storedAt: entry.storedAt
                )
            },
            nextCursor: page.nextCursor
        )
    }

    private func listIndexPage(
        machineID: String,
        cursor: String?,
        limit: Int
    ) throws -> (entries: [ArchiveReceiptListIndex.Entry], nextCursor: String?) {
        try Self.validateLimit(limit)
        guard let canonicalMachineID = UUID(uuidString: machineID)?.uuidString else {
            throw ArchiveStoreError.invalidMachineID
        }
        let cursorKey = try Self.decodeCursor(cursor)
        if let cursorKey, !ArchiveV2Hash.isValidSHA256(cursorKey) {
            throw ArchiveStoreError.invalidPage
        }

        try ensureListIndexReady(forced: false)
        var candidates = try listIndex.listEntries(
            machineID: canonicalMachineID,
            after: cursorKey,
            limit: limit
        )
        let hasMore = candidates.count > limit
        if hasMore { candidates.removeLast() }
        let nextCursor = hasMore
            ? candidates.last.map { Self.encodeCursor($0.manifestSHA256) }
            : nil
        return (candidates, nextCursor)
    }

    private func ensureListIndexReady(forced: Bool) throws {
        try listIndex.ensureReady(forced: forced) {
            var entries: [ArchiveReceiptListIndex.Entry] = []
            try forEachReceipt { manifestDigest, receiptBytes, receipt in
                guard let canonicalMachineID = UUID(uuidString: receipt.machineID)?.uuidString else {
                    throw ArchiveStoreError.conflict
                }
                entries.append(
                    Self.listIndexEntry(
                        machineID: canonicalMachineID,
                        manifestDigest: manifestDigest,
                        receiptBytes: receiptBytes,
                        receipt: receipt
                    )
                )
            }
            hooks.afterListIndexBuild?()
            return entries
        }
    }

    private func notePublishedReceipt(bytes: Data, manifestDigest: String) {
        guard let receipt = try? Self.decodeReceiptForDiscovery(bytes),
              let machineID = UUID(uuidString: receipt.machineID)?.uuidString else {
            return
        }
        listIndex.note(
            Self.listIndexEntry(
                machineID: machineID,
                manifestDigest: manifestDigest,
                receiptBytes: bytes,
                receipt: receipt
            )
        )
    }

    private static func listIndexEntry(
        machineID: String,
        manifestDigest: String,
        receiptBytes: Data,
        receipt: ArchiveServerReceipt
    ) -> ArchiveReceiptListIndex.Entry {
        ArchiveReceiptListIndex.Entry(
            machineID: machineID,
            manifestSHA256: manifestDigest,
            receiptSHA256: ArchiveV2Hash.sha256(receiptBytes),
            sessionID: receipt.sessionID,
            captureID: receipt.captureID,
            rawByteCount: receipt.rawByteCount,
            storedAt: receipt.storedAt
        )
    }

    /// Manifest envelope checks only: digest match plus canonical decode.
    /// Chunk verification is the caller's choice, so a windowed read does not
    /// pay for chunks it never serves (retro PR-2, F01).
    private func decodedManifest(
        _ bytes: Data,
        expectedDigest: String
    ) throws -> ArchiveSourceManifest {
        guard ArchiveV2Hash.sha256(bytes) == expectedDigest else {
            throw ArchiveStoreError.digestMismatch
        }
        do {
            return try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: bytes)
        } catch {
            throw ArchiveStoreError.invalidManifest
        }
    }

    /// Fetch one chunk object and verify it against its manifest reference.
    private func chunkObject(
        _ chunk: ArchiveChunkReference,
        durableReferences: Bool
    ) throws -> Data {
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
        return object
    }

    private func validatedManifest(
        _ bytes: Data,
        expectedDigest: String,
        durableReferences: Bool
    ) throws -> ArchiveSourceManifest {
        let manifest = try decodedManifest(bytes, expectedDigest: expectedDigest)

        var wholeHasher = SHA256()
        for chunk in manifest.chunks {
            let object = try chunkObject(chunk, durableReferences: durableReferences)
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

    /// Read and authenticate one envelope.
    ///
    /// `knownParentIdentity` lets an enumeration supply a shard identity it has
    /// already validated, which skips the three per-file directory-chain walks
    /// this function otherwise performs. Callers that pass it must bracket the
    /// whole scan with their own identity checks — see `forEachReceipt`.
    private func readEnvelope(
        at url: URL,
        expectedKind: ArchiveEnvelopeKind,
        expectedDigest: String,
        fsyncBeforeAccept: Bool = false,
        knownParentIdentity: DirectoryIdentity? = nil,
        afterVerified: (@Sendable (URL) throws -> Void)? = nil
    ) throws -> Data {
        let parentIdentity = try knownParentIdentity ?? requiredParentIdentity(
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
        if knownParentIdentity == nil {
            try assertParentIdentity(
                parentIdentity,
                digest: expectedDigest,
                kind: expectedKind
            )
        }

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
        if knownParentIdentity == nil {
            try assertParentIdentity(
                parentIdentity,
                digest: expectedDigest,
                kind: expectedKind
            )
        }
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

    /// Read one receipt for enumeration only.
    ///
    /// `getReceipt` is the durable single-receipt contract: it fsyncs the file
    /// and the shard directory, re-walks the directory chain three times, and
    /// re-reads plus re-encodes the referenced manifest to cross-check it.
    /// None of that is needed to enumerate, and all of it is per receipt — at
    /// ~25k receipts the fsyncs alone cost minutes, which made
    /// `listMachines`/`listReceipts` time out on a real archive.
    ///
    /// Every substitution defence is retained: `O_NOFOLLOW`, the
    /// regular-file/owner/link-count checks before and after the read, the
    /// descriptor-vs-path identity comparison, the envelope AEAD, and the
    /// header digest bound to the path digest. The receipt's own `serverID`
    /// and `manifestSHA256` are still checked against this store and this
    /// path. What is dropped is durability (meaningless for a read) and the
    /// receipt↔manifest cross-check, which still runs whenever a caller
    /// actually fetches a receipt or manifest.
    private func scanReceipt(
        manifestDigest: String,
        shardIdentity: DirectoryIdentity
    ) throws -> (Data, ArchiveServerReceipt) {
        let bytes = try readEnvelope(
            at: url(for: manifestDigest, kind: .receipt, createShard: false),
            expectedKind: .receipt,
            expectedDigest: manifestDigest,
            knownParentIdentity: shardIdentity
        )
        guard bytes.count <= ArchiveV2ProtocolLimits.maxReceiptBytes else {
            throw ArchiveStoreError.conflict
        }
        let receipt = try Self.decodeReceiptForDiscovery(bytes)
        guard receipt.serverID == serverID,
              receipt.manifestSHA256 == manifestDigest,
              Self.isCanonicalTimestamp(receipt.storedAt) else {
            throw ArchiveStoreError.conflict
        }
        return (bytes, receipt)
    }

    private func forEachReceipt(
        _ body: (String, Data, ArchiveServerReceipt) throws -> Void
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
                let (receiptBytes, receipt) = try scanReceipt(
                    manifestDigest: manifestDigest,
                    shardIdentity: shardIdentity
                )
                try body(manifestDigest, receiptBytes, receipt)
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
