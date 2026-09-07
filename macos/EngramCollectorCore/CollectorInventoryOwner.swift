import Darwin
import Foundation
import GRDB

enum CollectorInventoryOwnerError: Error, Equatable {
    case unsafePath
    case alreadyOwned
    case closed
    case rootNotEnrolled
    case rootNotActivated
    case invalidCaptureID
    case notImplemented
}

// These are local retry reasons, not capture/privacy,
// CAS residency, publication, or remote acknowledgement classifications.
enum CollectorDirtyDeferReason: String, Equatable {
    case sourceMissing
    case rootReplaced
    case unavailable
}

struct CollectorEventIngressBudget {
    let maxIncomingPaths: Int
    let maxPathUTF8Bytes: Int
    let maxTotalPathUTF8Bytes: Int
    // Sum of all epoch/cursor UTF-8 bytes in expected (if any) and next.
    let maxCheckpointUTF8Bytes: Int
}

enum CollectorEventGapReason: String, Equatable {
    case overflow
    case continuityLoss
    case restart
    case budgetExceeded
}

enum CollectorEventIngressResult: Equatable {
    case applied(inputPathCount: Int, checkpoint: CollectorEventCheckpoint)
    case reconciliationRequested(reason: CollectorEventGapReason, requestedRevision: Int64)
}

// Narrow fault/observation boundaries for temporary fixture tests only.
struct CollectorInventoryOwnerTestHooks {
    var beforeFilesystemAccess: (() throws -> Void)?
    var afterLockAcquired: (() throws -> Void)?
    var afterMainFilePrepared: (() throws -> Void)?
    var afterDatabaseOpened: (() throws -> Void)?
    var beforeRootActivation: (() throws -> Void)?
    var beforeInventoryCommit: (() throws -> Void)?
}

// Only values escape this owner. Its mutex covers each operation and close;
// flock covers cooperating processes, not arbitrary external filesystem writers.
final class CollectorInventoryOwner {
    private typealias Identity = CollectorPOSIXDirectoryIdentity
    private static let lockName = "collector-owner.lock"
    private static let databaseName = "inventory.sqlite"
    private static let sidecarNames = ["inventory.sqlite-wal", "inventory.sqlite-shm", "inventory.sqlite-journal"]

    private let mutex = NSLock()
    private let shadowRoot: URL
    private let identityCatalog: URL
    private let shadowIdentity: Identity
    private let liveRootIdentity: Identity
    private let machineID: String
    private let ownerRunID: String
    private let testHooks: CollectorInventoryOwnerTestHooks
    private var shadowDescriptor: Int32
    private var inventoryDescriptor: Int32 = -1
    private var lockDescriptor: Int32 = -1
    private var lockHeld = false
    private var mainDescriptor: Int32 = -1
    private var inventoryIdentity: Identity?
    private var lockIdentity: Identity?
    private var mainIdentity: Identity?
    private var sidecarIdentities: [String: Identity] = [:]
    private var database: DatabaseQueue?
    private var store: CollectorInventoryStore?
    private var activeRoots: [Data: (binding: CollectorPOSIXRootBinding, walker: CollectorBootstrapWalker)] = [:]
    private var eventCommitCancellationCheck: (() throws -> Void)?
    private var dirtyCommitFence: (() throws -> Void)?
    private var closed = false

    private var inventoryRoot: URL { shadowRoot.appendingPathComponent("inventory") }
    private var databaseURL: URL { inventoryRoot.appendingPathComponent(Self.databaseName) }

    private init(
        shadowRoot: URL, identityCatalog: URL, shadowDescriptor: Int32,
        shadowIdentity: Identity, liveRootIdentity: Identity, machineID: String,
        ownerRunID: String, testHooks: CollectorInventoryOwnerTestHooks
    ) {
        self.shadowRoot = shadowRoot
        self.identityCatalog = identityCatalog
        self.shadowDescriptor = shadowDescriptor
        self.shadowIdentity = shadowIdentity
        self.liveRootIdentity = liveRootIdentity
        self.machineID = machineID
        self.ownerRunID = ownerRunID
        self.testHooks = testHooks
    }

    deinit { try? close() }

    static func open(
        enabled: Bool = false,
        shadowRoot: URL,
        identityCatalog: URL,
        ownerRunID: String,
        testHooks: CollectorInventoryOwnerTestHooks = .init()
    ) throws -> CollectorInventoryOwner? {
        guard enabled else { return nil }
        guard !ownerRunID.isEmpty, !ownerRunID.contains("\0") else { throw CollectorInventoryError.invalidState }
        try validateURL(shadowRoot)
        try validateURL(identityCatalog)
        try testHooks.beforeFilesystemAccess?()
        let shadow = try openDirectory(shadowRoot)
        var shadowDescriptor = shadow.descriptor
        defer { if shadowDescriptor >= 0 { CollectorPOSIXDirectoryAccess.close(shadowDescriptor) } }
        let live = try openDirectory(identityCatalog.deletingLastPathComponent())
        defer { CollectorPOSIXDirectoryAccess.close(live.descriptor) }
        try requirePrivateDirectory(shadow.info)
        try requirePrivateDirectory(live.info)
        try requireSeparateStorage(shadow: shadow.descriptor, live: live.descriptor)

        // No file or directory may be created before both existing identities
        // pass. In particular, never use the writable ArchiveCatalog opener here.
        let machineID = try CollectorMachineIdentityReader.read(from: identityCatalog)
        try CollectorMachineIdentityReader.verifyShadowIfPresent(at: shadowRoot, machineID: machineID)
        let owner = try CollectorInventoryOwner(
            shadowRoot: shadowRoot, identityCatalog: identityCatalog, shadowDescriptor: shadowDescriptor,
            shadowIdentity: CollectorPOSIXDirectoryAccess.identity(shadow.info),
            liveRootIdentity: CollectorPOSIXDirectoryAccess.identity(live.info),
            machineID: machineID, ownerRunID: ownerRunID, testHooks: testHooks
        )
        shadowDescriptor = -1
        do {
            try owner.prepareExistingInventory()
            try owner.validateStorage()
            let lock = try Self.openOwnedFile(parent: owner.shadowDescriptor, name: Self.lockName, expected: owner.lockIdentity)
            owner.lockDescriptor = lock.descriptor
            owner.lockIdentity = lock.identity
            guard flock(lock.descriptor, LOCK_EX | LOCK_NB) == 0 else {
                if errno == EWOULDBLOCK || errno == EAGAIN { throw CollectorInventoryOwnerError.alreadyOwned }
                throw Self.posixError()
            }
            owner.lockHeld = true
            try testHooks.afterLockAcquired?()
            try owner.validateStorage()
            _ = try CollectorMachineIdentityReader.read(from: identityCatalog, expectedMachineID: machineID)
            try CollectorMachineIdentityReader.verifyShadowIfPresent(at: shadowRoot, machineID: machineID)
            try owner.prepareDatabase()
            return owner
        } catch {
            try? owner.close()
            throw error
        }
    }

    func enrollAndActivateRoot(_ configuration: CollectorRootConfiguration) throws -> CollectorPOSIXRootBinding {
        try withStore { store in
            let previous = try store.rootState(rootID: configuration.rootID)
            if let previous, previous.configuration != configuration,
               configuration.revision <= previous.configuration.revision { throw CollectorInventoryError.invalidRoot }
            let binding: CollectorPOSIXRootBinding
            if previous?.configuration == configuration,
               let enrolled = try store.enrolledRoot(configuration: configuration) {
                binding = enrolled
                try CollectorPOSIXRootEnumerator.validateRoot(binding: binding)
            } else {
                // Observe before even registering an unbound path. The stored
                // identity is never silently replaced for an existing revision.
                binding = try CollectorPOSIXRootEnumerator.observeRoot(configuration: configuration)
                try store.registerRoot(configuration)
                try store.enrollRoot(binding: binding)
            }
            try testHooks.beforeRootActivation?()
            try CollectorPOSIXRootEnumerator.validateRoot(binding: binding)
            guard let activated = try store.activateEnrolledRoot(configuration: configuration) else {
                throw CollectorInventoryError.invalidState
            }
            let key = Data(configuration.rootID.utf8)
            if activeRoots[key]?.binding.configuration != configuration {
                activeRoots[key] = (
                    activated,
                    CollectorBootstrapWalker(store: store, enumerator: try CollectorPOSIXRootEnumerator(binding: activated))
                )
            }
            return activated
        }
    }

    func rootState(rootID: String) throws -> CollectorRootState? {
        try withStore { try $0.rootState(rootID: rootID) }
    }

    func reserveCapture(
        _ claim: CollectorDirtyClaim, configuration: CollectorRootConfiguration,
        generation: ArchiveSourceGeneration
    ) throws -> CollectorCaptureReservation? {
        try withDirtyStore(configuration: configuration, validateInput: {
            try Self.requireClaimConfiguration(claim, configuration)
            guard CollectorInventoryStore.isSafeRelativePath(claim.relativePath) else {
                throw CollectorInventoryError.invalidRelativePath
            }
        }) { try $0.reserveCapture(claim, configuration: configuration, generation: generation) }
    }

    func captureReservations(limit: Int) throws -> [CollectorCaptureReservation] {
        try withPublicationStore { try $0.captureReservations(limit: limit) }
    }

    func finishCapture(
        _ reservation: CollectorCaptureReservation, configuration: CollectorRootConfiguration,
        capture: ArchiveCapture
    ) throws -> CollectorPublicationIntent? {
        // Finishing a durable generation does not re-read a changed/missing
        // source. Configuration, enrolled ownership and the storage commit
        // fence remain mandatory; this never grants remote privacy authority.
        try withDirtyStore(configuration: configuration, allowsUnavailableRoot: true, validateInput: {
            guard reservation.rootID.utf8.elementsEqual(configuration.rootID.utf8),
                  reservation.rootRevision == configuration.revision else {
                throw CollectorInventoryError.unknownRoot
            }
            guard CollectorInventoryStore.isSafeRelativePath(reservation.relativePath),
                  ArchiveV2Hash.isValidSHA256(capture.captureID) else {
                throw CollectorPublicationWorkerError.invalidCapture
            }
        }) { try $0.finishCapture(reservation, capture: capture) }
    }

    func publicationIntents(limit: Int) throws -> [CollectorPublicationIntent] {
        try withPublicationStore { try $0.publicationIntents(limit: limit) }
    }

    func claimPublications(replicaID: String, limit: Int, now: Int64) throws -> [CollectorPublicationClaim] {
        try withPublicationStore { try $0.claimPublications(replicaID: replicaID, limit: limit, now: now) }
    }

    func recordPublicationACK(_ claim: CollectorPublicationClaim, canonicalBytes: Data) throws -> Bool {
        try withPublicationStore { try $0.recordPublicationACK(claim, canonicalBytes: canonicalBytes) }
    }

    func deferPublication(
        _ claim: CollectorPublicationClaim, now: Int64, reason: CollectorPublicationDeferral
    ) throws -> Bool {
        try withPublicationStore { try $0.deferPublication(claim, now: now, reason: reason) }
    }

    func isPublicationClaimCurrent(_ claim: CollectorPublicationClaim) throws -> Bool {
        try withPublicationStore { try $0.isPublicationClaimCurrent(claim) }
    }

    func abandonCapture(_ reservation: CollectorCaptureReservation) throws -> Bool {
        try withPublicationStore { try $0.abandonCapture(reservation) }
    }

    func captureRecoveryState(_ reservation: CollectorCaptureReservation) throws -> Data? {
        try withPublicationStore { try $0.captureRecoveryState(reservation) }
    }

    func storeCaptureRecoveryState(_ reservation: CollectorCaptureReservation, payload: Data?) throws -> Bool {
        try withPublicationStore { try $0.storeCaptureRecoveryState(reservation, payload: payload) }
    }

    /// Available bytes on the inventory/spool volume, not a count of source
    /// files or a promise that an independently supplied CAS volume is healthy.
    func availableSpoolBytes() throws -> Int64 {
        try withPublicationStore { _ in
            var info = statfs()
            guard fstatfs(shadowDescriptor, &info) == 0 else { throw Self.posixError() }
            guard let blocks = Int64(exactly: info.f_bavail),
                  let blockSize = Int64(exactly: info.f_bsize) else {
                throw CollectorPublicationWorkerError.invalidBudget
            }
            let bytes = blocks.multipliedReportingOverflow(by: blockSize)
            return bytes.overflow ? Int64.max : max(0, bytes.partialValue)
        }
    }

    func machineIdentity() throws -> String {
        try withPublicationStore { _ in machineID }
    }

    func claimDirty(
        configuration: CollectorRootConfiguration, limit: Int, now: Int64
    ) throws -> [CollectorDirtyClaim] {
        try withDirtyStore(configuration: configuration, validateInput: {
            guard (1...64).contains(limit), now >= 0 else { throw CollectorInventoryError.invalidBudget }
        }) { store in
            // The limit bounds candidates, not successful claims. Do not refill
            // an empty result: deferred/in-flight work may still be pending.
            try store.claimDirty(configuration: configuration, limit: limit, now: now)
        }
    }

    func acknowledge(
        _ claim: CollectorDirtyClaim, configuration: CollectorRootConfiguration, captureID: String
    ) throws -> CollectorClaimCompletion {
        try withDirtyStore(configuration: configuration, validateInput: {
            guard captureID.utf8.count == 64,
                  captureID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw CollectorInventoryOwnerError.invalidCaptureID
            }
            try Self.requireClaimConfiguration(claim, configuration)
        }) { store in
            // A forged NUL path must not alias a locator through SQLite's text
            // binding. Other claim authority remains the Store's responsibility.
            guard CollectorInventoryStore.isSafeRelativePath(claim.relativePath) else { return .stale }
            // This is only the caller's durable-capture assertion, not a CAS,
            // privacy, publication or remote-acknowledgement verification.
            return try store.acknowledge(claim, captureID: captureID)
        }
    }

    func deferClaim(
        _ claim: CollectorDirtyClaim, configuration: CollectorRootConfiguration,
        retryNotBefore: Int64, reason: CollectorDirtyDeferReason
    ) throws -> Bool {
        try withDirtyStore(configuration: configuration, allowsUnavailableRoot: true, validateInput: {
            guard retryNotBefore >= 0 else { throw CollectorInventoryError.invalidBudget }
            try Self.requireClaimConfiguration(claim, configuration)
        }) { store in
            guard CollectorInventoryStore.isSafeRelativePath(claim.relativePath) else { return false }
            return try store.deferClaim(claim, retryNotBefore: retryNotBefore, reason: reason.rawValue)
        }
    }

    func stepRoot(
        _ configuration: CollectorRootConfiguration,
        budget: CollectorBootstrapBudget
    ) throws -> CollectorBootstrapStepResult {
        try withStore { store in
            guard let active = activeRoots[Data(configuration.rootID.utf8)],
                  active.binding.configuration == configuration else { throw CollectorInventoryError.unknownRoot }
            let scan = try store.beginBootstrap(configuration: configuration, scanID: UUID().uuidString)
            return try active.walker.step(scan: scan, budget: budget)
        }
    }

    // Checkpoints are opaque bytes. No native FSEvents ordering is implied.
    func applyEvents(
        configuration: CollectorRootConfiguration,
        expectedCheckpoint: CollectorEventCheckpoint?,
        nextCheckpoint: CollectorEventCheckpoint,
        dirtyRelativePaths: [String],
        budget: CollectorEventIngressBudget
    ) throws -> CollectorEventIngressResult {
        try withEventStore { store in
            let (state, binding) = try Self.requireEnrolledEventRoot(store, configuration)
            guard let active = activeRoots[Data(configuration.rootID.utf8)],
                  active.binding.configuration == configuration,
                  active.binding.expectedIdentity == binding.expectedIdentity else {
                throw CollectorInventoryOwnerError.rootNotActivated
            }
            if try Self.exceedsEventBudget(dirtyRelativePaths, expectedCheckpoint, nextCheckpoint, budget) {
                // Preserve loss even when the source is gone; accept no prefix
                // and never send an oversized batch to the checkpoint writer.
                return try Self.recordEventGap(store, state, .budgetExceeded)
            }
            guard Self.validEventCheckpoint(nextCheckpoint),
                  expectedCheckpoint.map(Self.validEventCheckpoint) ?? true,
                  Self.sameEventCheckpoint(state.eventCheckpoint, expectedCheckpoint),
                  state.eventCheckpoint.map({ $0.epoch.utf8.elementsEqual(nextCheckpoint.epoch.utf8) }) ?? true else {
                throw CollectorInventoryError.staleCheckpoint
            }
            for path in dirtyRelativePaths {
                try Task.checkCancellation()
                guard CollectorInventoryStore.isSafeRelativePath(path) else {
                    throw CollectorInventoryError.invalidRelativePath
                }
            }
            try CollectorPOSIXRootEnumerator.validateRoot(binding: binding)
            try store.applyEventBatch(
                configuration: configuration, expectedCheckpoint: expectedCheckpoint, nextCheckpoint: nextCheckpoint,
                dirtyRelativePaths: dirtyRelativePaths, requiresReconciliation: false
            )
            return .applied(inputPathCount: dirtyRelativePaths.count, checkpoint: nextCheckpoint)
        }
    }

    func requestEventReconciliation(
        configuration: CollectorRootConfiguration,
        reason: CollectorEventGapReason
    ) throws -> CollectorEventIngressResult {
        try withEventStore { store in
            let (state, _) = try Self.requireEnrolledEventRoot(store, configuration)
            return try Self.recordEventGap(store, state, reason)
        }
    }

    func close() throws {
        mutex.lock()
        defer { mutex.unlock() }
        guard !closed else { return }
        activeRoots.removeAll() // Releases process-local cursors before the queue.
        store = nil
        try database?.close()
        database = nil
        for descriptor in [mainDescriptor, inventoryDescriptor] where descriptor >= 0 { _ = Darwin.close(descriptor) }
        mainDescriptor = -1
        inventoryDescriptor = -1
        // A failed queue close retains the lock; never admit a new writer early.
        if lockDescriptor >= 0 {
            if lockHeld { _ = flock(lockDescriptor, LOCK_UN) }
            _ = Darwin.close(lockDescriptor)
            lockDescriptor = -1
            lockHeld = false
        }
        if shadowDescriptor >= 0 { _ = Darwin.close(shadowDescriptor); shadowDescriptor = -1 }
        closed = true
    }

    private func withStore<T>(_ operation: (CollectorInventoryStore) throws -> T) throws -> T {
        mutex.lock()
        defer { mutex.unlock() }
        guard !closed, let store else { throw CollectorInventoryOwnerError.closed }
        try validateStorage()
        let result = try operation(store)
        try validateStorage()
        return result
    }

    private func withEventStore<T>(_ operation: (CollectorInventoryStore) throws -> T) throws -> T {
        try withStore { store in
            try withUnsafeCurrentTask { task in
                try Task.checkCancellation()
                // The queue's synchronous commit hook may run on another
                // thread. Borrow the caller's task only for this locked call.
                eventCommitCancellationCheck = {
                    if task?.isCancelled == true { throw CancellationError() }
                }
                defer { eventCommitCancellationCheck = nil }
                return try operation(store)
            }
        }
    }

    /// Publication operations use immutable captured data, not a live source
    /// root. Retain the exact same owner/storage/cancellation transaction fence
    /// as dirty work without turning root disappearance into permission to
    /// reopen a queue or to acknowledge an obsolete owner claim.
    private func withPublicationStore<T>(_ operation: (CollectorInventoryStore) throws -> T) throws -> T {
        mutex.lock()
        defer { mutex.unlock() }
        guard !closed, let store else { throw CollectorInventoryOwnerError.closed }
        return try withUnsafeCurrentTask { task in
            if task?.isCancelled == true { throw CancellationError() }
            try validateStorage()
            dirtyCommitFence = { [unowned self] in
                if task?.isCancelled == true { throw CancellationError() }
                try self.validateStorageFilesystem()
                if task?.isCancelled == true { throw CancellationError() }
            }
            defer { dirtyCommitFence = nil }
            let result = try operation(store)
            try validateStorage()
            return result
        }
    }

    private func withDirtyStore<T>(
        configuration: CollectorRootConfiguration,
        allowsUnavailableRoot: Bool = false,
        validateInput: () throws -> Void,
        _ operation: (CollectorInventoryStore) throws -> T
    ) throws -> T {
        mutex.lock()
        defer { mutex.unlock() }
        guard !closed, let store else { throw CollectorInventoryOwnerError.closed }
        try validateInput()
        // Reject a possible SQLite text-binding alias before any Store lookup.
        guard !configuration.rootID.contains("\0") else { throw CollectorInventoryError.unknownRoot }
        return try withUnsafeCurrentTask { task in
            if task?.isCancelled == true { throw CancellationError() }
            try validateStorage()
            let (_, binding) = try Self.requireEnrolledEventRoot(store, configuration)
            guard let active = activeRoots[Data(configuration.rootID.utf8)],
                  active.binding.configuration == configuration,
                  active.binding.expectedIdentity == binding.expectedIdentity else {
                throw CollectorInventoryOwnerError.rootNotActivated
            }
            try Self.validateDirtyRoot(binding, allowsUnavailableRoot: allowsUnavailableRoot)
            // Borrowed on the caller's thread, before any synchronous queue
            // operation. The hook may execute on GRDB's thread without a task.
            dirtyCommitFence = { [unowned self] in
                if task?.isCancelled == true { throw CancellationError() }
                try self.validateStorageFilesystem()
                try Self.validateDirtyRoot(binding, allowsUnavailableRoot: allowsUnavailableRoot)
                if task?.isCancelled == true { throw CancellationError() }
            }
            // Neither the borrowed task nor this operation's physical-root
            // policy may survive into another Owner API or a later transaction.
            defer { dirtyCommitFence = nil }
            if task?.isCancelled == true { throw CancellationError() }
            let result = try operation(store)
            try validateStorage()
            return result
        }
    }

    private static func requireClaimConfiguration(
        _ claim: CollectorDirtyClaim, _ configuration: CollectorRootConfiguration
    ) throws {
        guard claim.rootID.utf8.elementsEqual(configuration.rootID.utf8),
              claim.rootRevision == configuration.revision else { throw CollectorInventoryError.unknownRoot }
    }

    private static func validateDirtyRoot(
        _ binding: CollectorPOSIXRootBinding, allowsUnavailableRoot: Bool
    ) throws {
        do {
            try CollectorPOSIXRootEnumerator.validateRoot(binding: binding)
        } catch CollectorPOSIXEnumerationError.rootIdentityChanged where allowsUnavailableRoot {
            // Keep the old binding so capture failure can defer, never rebind.
        } catch CollectorPOSIXEnumerationError.io(_, ENOENT) where allowsUnavailableRoot {
            // Every entry and pre-commit call validates anew; no cached bypass.
        }
    }

    private static func requireEnrolledEventRoot(
        _ store: CollectorInventoryStore, _ configuration: CollectorRootConfiguration
    ) throws -> (CollectorRootState, CollectorPOSIXRootBinding) {
        guard let state = try store.rootState(rootID: configuration.rootID), state.configuration == configuration else {
            throw CollectorInventoryError.unknownRoot
        }
        guard let binding = try store.enrolledRoot(configuration: configuration) else {
            throw CollectorInventoryOwnerError.rootNotEnrolled
        }
        return (state, binding)
    }

    private static func recordEventGap(
        _ store: CollectorInventoryStore, _ state: CollectorRootState, _ reason: CollectorEventGapReason
    ) throws -> CollectorEventIngressResult {
        try store.requestReconciliation(configuration: state.configuration)
        // Store rejects revision exhaustion before this result is formed.
        return .reconciliationRequested(reason: reason, requestedRevision: state.requestedRevision + 1)
    }

    private static func exceedsEventBudget(
        _ paths: [String], _ expected: CollectorEventCheckpoint?, _ next: CollectorEventCheckpoint,
        _ budget: CollectorEventIngressBudget
    ) throws -> Bool {
        guard budget.maxIncomingPaths >= 0, budget.maxPathUTF8Bytes >= 0,
              budget.maxTotalPathUTF8Bytes >= 0, budget.maxCheckpointUTF8Bytes >= 0 else {
            throw CollectorInventoryError.invalidBudget
        }
        if paths.count > budget.maxIncomingPaths { return true }
        var remainingPathBytes = budget.maxTotalPathUTF8Bytes
        for path in paths {
            try Task.checkCancellation()
            let bytes = path.utf8.count
            if bytes > budget.maxPathUTF8Bytes || bytes > remainingPathBytes { return true }
            remainingPathBytes -= bytes // Count every input, including duplicates, without overflowing.
        }
        var remainingCheckpointBytes = budget.maxCheckpointUTF8Bytes
        for checkpoint in [expected, next].compactMap({ $0 }) {
            for token in [checkpoint.epoch, checkpoint.cursor] {
                let bytes = token.utf8.count
                if bytes > remainingCheckpointBytes { return true }
                remainingCheckpointBytes -= bytes
            }
        }
        return false
    }

    private static func validEventCheckpoint(_ checkpoint: CollectorEventCheckpoint) -> Bool {
        !checkpoint.epoch.isEmpty && !checkpoint.cursor.isEmpty
            && !checkpoint.epoch.contains("\0") && !checkpoint.cursor.contains("\0")
    }

    private static func sameEventCheckpoint(_ left: CollectorEventCheckpoint?, _ right: CollectorEventCheckpoint?) -> Bool {
        switch (left, right) {
        case (nil, nil): return true
        case let (left?, right?):
            return left.epoch.utf8.elementsEqual(right.epoch.utf8) && left.cursor.utf8.elementsEqual(right.cursor.utf8)
        default: return false
        }
    }

    private func prepareExistingInventory() throws {
        lockIdentity = try Self.fileIdentity(parent: shadowDescriptor, name: Self.lockName)
        if let info = try Self.status(parent: shadowDescriptor, name: "inventory") {
            try Self.requirePrivateDirectory(info)
            let descriptor = try CollectorPOSIXDirectoryAccess.openComponent("inventory", parent: shadowDescriptor)
            inventoryDescriptor = descriptor
            inventoryIdentity = try CollectorPOSIXDirectoryAccess.identity(info)
            try Self.validateDirectoryDescriptor(descriptor, expected: inventoryIdentity!)
            mainIdentity = try Self.fileIdentity(parent: descriptor, name: Self.databaseName)
            sidecarIdentities = try Self.validateSidecars(parent: descriptor, expected: [:])
        }
    }

    private func prepareDatabase() throws {
        if inventoryDescriptor < 0 {
            if mkdirat(shadowDescriptor, "inventory", 0o700) != 0, errno != EEXIST { throw Self.posixError() }
            inventoryDescriptor = try CollectorPOSIXDirectoryAccess.openComponent("inventory", parent: shadowDescriptor)
            let info = try CollectorPOSIXDirectoryAccess.directoryStat(inventoryDescriptor)
            try Self.requirePrivateDirectory(info)
            inventoryIdentity = try CollectorPOSIXDirectoryAccess.identity(info)
            guard fsync(shadowDescriptor) == 0 else { throw Self.posixError() }
        }
        try validateStorage()
        let main = try Self.openOwnedFile(parent: inventoryDescriptor, name: Self.databaseName, expected: mainIdentity)
        mainDescriptor = main.descriptor
        mainIdentity = main.identity
        try testHooks.afterMainFilePrepared?()
        try validateStorage()

        let url = databaseURL
        let directory = inventoryRoot
        let directoryIdentity = inventoryIdentity!
        let descriptor = inventoryDescriptor
        let openedMain = mainDescriptor
        let identity = main.identity
        let expectedSidecars = sidecarIdentities
        guard let resolved = Darwin.realpath(url.path, nil) else { throw Self.posixError() }
        let canonicalPath = String(cString: resolved)
        Darwin.free(resolved)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = false
        configuration.busyMode = .timeout(0.5)
        // Capture only immutable values/fd numbers, not the owner: retaining the
        // owner in GRDB's configuration would make deinit unable to release it.
        configuration.prepareDatabase { db in
            try Self.validateDatabase(
                db, url: url, canonicalPath: canonicalPath, directory: directory,
                directoryIdentity: directoryIdentity, parent: descriptor,
                mainDescriptor: openedMain, mainIdentity: identity
            )
            _ = try Self.validateSidecars(parent: descriptor, expected: expectedSidecars)
            var persistWAL: CInt = 1
            guard sqlite3_file_control(db.sqliteConnection, "main", SQLITE_FCNTL_PERSIST_WAL, &persistWAL) == SQLITE_OK else {
                throw CollectorInventoryOwnerError.unsafePath
            }
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA synchronous = FULL")
            try db.execute(sql: "PRAGMA wal_autocheckpoint = \(SQLiteBusyDefaults.walAutocheckpointPages)")
            guard try String.fetchOne(db, sql: "PRAGMA journal_mode")?.lowercased() == "wal",
                  try Int.fetchOne(db, sql: "PRAGMA synchronous") == 2 else {
                throw CollectorInventoryOwnerError.unsafePath
            }
        }
        guard var uri = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw CollectorInventoryOwnerError.unsafePath }
        uri.queryItems = [URLQueryItem(name: "mode", value: "rw")]
        guard let writableURI = uri.url?.absoluteString else { throw CollectorInventoryOwnerError.unsafePath }
        let queue = try DatabaseQueue(path: writableURI, configuration: configuration)
        database = queue
        try validateStorage()
        sidecarIdentities = try Self.validateSidecars(parent: descriptor, expected: sidecarIdentities)
        let openedSidecars = sidecarIdentities
        try testHooks.afterDatabaseOpened?()
        guard try Self.validateSidecars(parent: descriptor, expected: openedSidecars) == openedSidecars else {
            throw CollectorInventoryOwnerError.unsafePath
        }
        try validateStorage()
        let beforeCommit = testHooks.beforeInventoryCommit
        store = try CollectorInventoryStore(
            database: queue, machineID: machineID, ownerRunID: ownerRunID,
            testHooks: .init(beforeCommit: { [weak self] in
                try self?.eventCommitCancellationCheck?()
                try beforeCommit?()
                try self?.eventCommitCancellationCheck?()
                try self?.dirtyCommitFence?()
            })
        )
        try validateStorage()
    }

    private func validateStorage() throws {
        try validateStorageFilesystem()
        if inventoryDescriptor >= 0, let inventoryIdentity, let database, let mainIdentity {
            guard let resolved = Darwin.realpath(databaseURL.path, nil) else { throw Self.posixError() }
            let canonicalPath = String(cString: resolved)
            Darwin.free(resolved)
            try database.read { db in
                try Self.validateDatabase(
                    db, url: databaseURL, canonicalPath: canonicalPath, directory: inventoryRoot,
                    directoryIdentity: inventoryIdentity, parent: inventoryDescriptor,
                    mainDescriptor: mainDescriptor, mainIdentity: mainIdentity
                )
            }
        }
    }

    // Queue-free: safe inside Store.beforeCommit. The complete outer validator
    // above still checks SQLite's connection filename and HAS_MOVED state.
    private func validateStorageFilesystem() throws {
        let shadow = try Self.openDirectory(shadowRoot)
        defer { CollectorPOSIXDirectoryAccess.close(shadow.descriptor) }
        let live = try Self.openDirectory(identityCatalog.deletingLastPathComponent())
        defer { CollectorPOSIXDirectoryAccess.close(live.descriptor) }
        try Self.validateDirectoryDescriptor(shadowDescriptor, expected: shadowIdentity)
        try Self.validateDirectoryDescriptor(shadow.descriptor, expected: shadowIdentity)
        try Self.validateDirectoryDescriptor(live.descriptor, expected: liveRootIdentity)
        try Self.requireSeparateStorage(shadow: shadow.descriptor, live: live.descriptor)
        _ = try Self.fileIdentity(parent: shadowDescriptor, name: Self.lockName, expected: lockIdentity, descriptor: lockDescriptor)
        if inventoryDescriptor >= 0, let inventoryIdentity {
            let current = try Self.openDirectory(inventoryRoot)
            defer { CollectorPOSIXDirectoryAccess.close(current.descriptor) }
            try Self.validateDirectoryDescriptor(inventoryDescriptor, expected: inventoryIdentity)
            try Self.validateDirectoryDescriptor(current.descriptor, expected: inventoryIdentity)
            _ = try Self.fileIdentity(parent: inventoryDescriptor, name: Self.databaseName, expected: mainIdentity, descriptor: mainDescriptor)
            sidecarIdentities = try Self.validateSidecars(parent: inventoryDescriptor, expected: sidecarIdentities)
        }
    }

    private static func validateURL(_ url: URL) throws {
        guard url.isFileURL, url.host == nil || url.host == "", url.query == nil, url.fragment == nil else {
            throw CollectorInventoryOwnerError.unsafePath
        }
        _ = try CollectorPOSIXDirectoryAccess.components(url.path)
    }

    private static func openDirectory(_ url: URL) throws -> (descriptor: Int32, info: stat) {
        let components = try CollectorPOSIXDirectoryAccess.components(url.path)
        return try CollectorPOSIXDirectoryAccess.openAbsolute(components: components)
    }

    private static func requirePrivateDirectory(_ info: stat) throws {
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o7777 == 0o700 else {
            throw CollectorInventoryOwnerError.unsafePath
        }
    }

    private static func validateDirectoryDescriptor(_ descriptor: Int32, expected: Identity) throws {
        let info = try CollectorPOSIXDirectoryAccess.directoryStat(descriptor)
        try requirePrivateDirectory(info)
        guard try CollectorPOSIXDirectoryAccess.identity(info) == expected else { throw CollectorInventoryOwnerError.unsafePath }
    }

    private static func sameInode(_ lhs: Identity, _ rhs: Identity) -> Bool {
        lhs.device == rhs.device && lhs.inode == rhs.inode
    }

    private static func requireSeparateStorage(shadow: Int32, live: Int32) throws {
        let shadowIdentity = try CollectorPOSIXDirectoryAccess.identity(CollectorPOSIXDirectoryAccess.directoryStat(shadow))
        let liveIdentity = try CollectorPOSIXDirectoryAccess.identity(CollectorPOSIXDirectoryAccess.directoryStat(live))
        // Walk actual parent directories, not text prefixes or realpath strings.
        // This includes paths reached through macOS Users/Data firmlink aliases.
        guard try !ancestorIdentities(shadow).contains(where: { sameInode($0, liveIdentity) }),
              try !ancestorIdentities(live).contains(where: { sameInode($0, shadowIdentity) }) else {
            throw CollectorInventoryOwnerError.unsafePath
        }
    }

    private static func ancestorIdentities(_ start: Int32) throws -> [Identity] {
        var current = try CollectorPOSIXDirectoryAccess.openComponent(".", parent: start)
        defer { CollectorPOSIXDirectoryAccess.close(current) }
        var identities: [Identity] = []
        for _ in 0...CollectorPOSIXRootEnumerator.maximumAbsoluteComponents {
            let identity = try CollectorPOSIXDirectoryAccess.identity(CollectorPOSIXDirectoryAccess.directoryStat(current))
            identities.append(identity)
            let parent = try CollectorPOSIXDirectoryAccess.openComponent("..", parent: current)
            let parentIdentity: Identity
            do { parentIdentity = try CollectorPOSIXDirectoryAccess.identity(CollectorPOSIXDirectoryAccess.directoryStat(parent)) }
            catch { CollectorPOSIXDirectoryAccess.close(parent); throw error }
            if sameInode(identity, parentIdentity) {
                CollectorPOSIXDirectoryAccess.close(parent)
                return identities
            }
            CollectorPOSIXDirectoryAccess.close(current)
            current = parent
        }
        throw CollectorInventoryOwnerError.unsafePath
    }

    private static func status(parent: Int32, name: String) throws -> stat? {
        var info = stat()
        if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return info }
        guard errno == ENOENT else { throw posixError() }
        return nil
    }

    private static func fileIdentity(
        parent: Int32, name: String, expected: Identity? = nil, descriptor: Int32 = -1
    ) throws -> Identity? {
        guard let info = try status(parent: parent, name: name) else {
            guard expected == nil, descriptor < 0 else { throw CollectorInventoryOwnerError.unsafePath }
            return nil
        }
        try requirePrivateFile(info)
        let identity = try CollectorPOSIXDirectoryAccess.identity(info)
        guard expected == nil || identity == expected else { throw CollectorInventoryOwnerError.unsafePath }
        if descriptor >= 0 {
            var opened = stat()
            guard fstat(descriptor, &opened) == 0 else { throw posixError() }
            try requirePrivateFile(opened)
            guard try CollectorPOSIXDirectoryAccess.identity(opened) == identity else { throw CollectorInventoryOwnerError.unsafePath }
        }
        return identity
    }

    private static func requirePrivateFile(_ info: stat) throws {
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_mode & 0o7777 == 0o600 else { throw CollectorInventoryOwnerError.unsafePath }
    }

    private static func openOwnedFile(parent: Int32, name: String, expected: Identity?) throws -> (descriptor: Int32, identity: Identity) {
        _ = try fileIdentity(parent: parent, name: name, expected: expected)
        let flags = O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        var descriptor = openat(parent, name, flags | O_CREAT | O_EXCL, 0o600)
        let created = descriptor >= 0
        if descriptor < 0 {
            guard errno == EEXIST else { throw posixError() }
            descriptor = openat(parent, name, flags)
        }
        guard descriptor >= 0 else { throw posixError() }
        do {
            let descriptorFlags = fcntl(descriptor, F_GETFD)
            guard let identity = try fileIdentity(parent: parent, name: name, expected: expected, descriptor: descriptor),
                  descriptorFlags >= 0, descriptorFlags & FD_CLOEXEC != 0 else { throw CollectorInventoryOwnerError.unsafePath }
            if created, fsync(descriptor) != 0 || fsync(parent) != 0 { throw posixError() }
            return (descriptor, identity)
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private static func validateSidecars(parent: Int32, expected: [String: Identity]) throws -> [String: Identity] {
        var result: [String: Identity] = [:]
        for name in sidecarNames {
            if let identity = try fileIdentity(parent: parent, name: name, expected: expected[name]) { result[name] = identity }
        }
        return result
    }

    private static func validateDatabase(
        _ db: Database, url: URL, canonicalPath: String, directory: URL,
        directoryIdentity: Identity, parent: Int32, mainDescriptor: Int32, mainIdentity: Identity
    ) throws {
        let opened = try openDirectory(directory)
        defer { CollectorPOSIXDirectoryAccess.close(opened.descriptor) }
        try validateDirectoryDescriptor(opened.descriptor, expected: directoryIdentity)
        try validateDirectoryDescriptor(parent, expected: directoryIdentity)
        guard sqlite3_db_readonly(db.sqliteConnection, "main") == 0,
              let filename = sqlite3_db_filename(db.sqliteConnection, "main"),
              String(cString: filename).utf8.elementsEqual(canonicalPath.utf8) else { throw CollectorInventoryOwnerError.unsafePath }
        var moved: CInt = 0
        guard sqlite3_file_control(db.sqliteConnection, "main", SQLITE_FCNTL_HAS_MOVED, &moved) == SQLITE_OK,
              moved == 0 else { throw CollectorInventoryOwnerError.unsafePath }
        _ = try fileIdentity(parent: parent, name: databaseName, expected: mainIdentity, descriptor: mainDescriptor)
        var pathInfo = stat()
        guard lstat(url.path, &pathInfo) == 0 else { throw CollectorInventoryOwnerError.unsafePath }
        try requirePrivateFile(pathInfo)
        guard try CollectorPOSIXDirectoryAccess.identity(pathInfo) == mainIdentity else { throw CollectorInventoryOwnerError.unsafePath }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
