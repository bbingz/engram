import CoreFoundation
import Darwin
import Foundation
import GRDB

public enum CollectorRuntimeError: Error, Equatable, Sendable {
    case invalidSettings
    case invalidRole
    case invalidConfiguration
    case invalidCredential
    case closed
    case busy
    case reconciliationRequired
    case notStarted
}

public struct CollectorRuntimeCycle: Equatable, Sendable {
    public var scannedEntries = 0
    public var captured = 0
    public var recovered = 0
    public var acknowledgedHQ = 0
    public var acknowledgedM1 = 0
    public var deferred = 0
    public var diskAdmission: CollectorDiskAdmissionStatus = .notEvaluated
}

struct CollectorCaptureScheduleSample: Equatable, Sendable {
    var phase: CollectorEventCoordinatorPhase
    var historyDone: Bool
    var queuedBatchCount: Int
    var pendingGap: Bool
    var historyWaiting: Bool
}

struct CollectorCaptureWorkHints: Equatable, Sendable {
    var bootstrapProgressed: Bool
    var drainableBatchesRemaining: Bool
    var captured: Int
    var recovered: Int
}

enum CollectorCaptureScheduler {
    static let cheapWakeCapMilliseconds = 1_000

    static func cheapWakeMilliseconds(intervalMilliseconds: Int) -> Int {
        min(max(intervalMilliseconds, 0), cheapWakeCapMilliseconds)
    }

    static func shouldRunCapture(deadlineReached: Bool, samples: [CollectorCaptureScheduleSample]) -> Bool {
        if deadlineReached { return true }
        return samples.contains { sample in
            if sample.pendingGap || sample.phase == .recoveryRequired { return true }
            if sample.phase == .watching && sample.queuedBatchCount > 0 { return true }
            if sample.historyWaiting && sample.historyDone { return true }
            return false
        }
    }

    static func shouldContinuePromptly(_ hints: CollectorCaptureWorkHints) -> Bool {
        hints.bootstrapProgressed || hints.drainableBatchesRemaining || hints.captured > 0 || hints.recovered > 0
    }

    static func bootstrapProgressed(_ result: CollectorBootstrapStepResult) -> Bool {
        switch result.outcome {
        case .progress, .paused(.budget):
            return result.entriesVisited > 0 || result.candidateFiles > 0
                || result.directoriesOpened > 0 || result.metadataBytes > 0
        case .finished, .blocked, .paused(.diskPressure):
            return false
        }
    }

    static func isHistoryWaiting(phase: CollectorEventCoordinatorPhase, bootstrap: CollectorBootstrapStepResult?) -> Bool {
        guard phase == .recovering else { return false }
        return bootstrap == nil || bootstrap?.outcome == .finished
    }
}

/// Owns only a provisioned collector spool. Call stop before relinquishing the
/// runtime: it joins work and closes the capture pool before releasing its lock.
public actor CollectorRuntime {
    private let settingsURL: URL
    private let configuration: CollectorRuntimeConfiguration
    private var owner: CollectorInventoryOwner?
    private var catalog: ArchiveCatalog?
    private var worker: CollectorPublicationWorker?
    private var uploader: CollectorPublicationWorker?
    private var coordinators: [Int: CollectorEventCoordinator] = [:]
    private var cycle: Task<CollectorRuntimeCycle, Error>?
    private var loop: Task<Void, Error>?
    private var cleanup: Task<Void, Error>?
    private var stopping = false
    private var closed = false

    private init(settingsURL: URL, configuration: CollectorRuntimeConfiguration,
                 owner: CollectorInventoryOwner, catalog: ArchiveCatalog,
                 worker: CollectorPublicationWorker, uploader: CollectorPublicationWorker) {
        self.settingsURL = settingsURL
        self.configuration = configuration
        self.owner = owner
        self.catalog = catalog
        self.worker = worker
        self.uploader = uploader
    }

    public static func open(
        settingsURL: URL,
        secretLoader: @escaping @Sendable (String) throws -> String
    ) throws -> CollectorRuntime? {
        try Task.checkCancellation()
        guard let configuration = try CollectorRuntimeConfiguration.load(at: settingsURL) else { return nil }
        guard let owner = try CollectorInventoryOwner.open(enabled: true,
            shadowRoot: configuration.shadowURL, identityCatalog: configuration.identityURL,
            ownerRunID: UUID().uuidString) else { throw CollectorRuntimeError.invalidConfiguration }
        do {
            // Owner exclusion precedes opening the owned capture database. The
            // borrowed identity catalog and shadow marker retain strict readers.
            let catalog = try openExistingCapture(configuration, machineID: owner.machineIdentity())
            do {
                let replicas = try configuration.replicas.map { reference -> CollectorReplicaEndpoint in
                    try Task.checkCancellation()
                    let secret = try secretLoader(reference.credentialID)
                    guard (1...4096).contains(secret.utf8.count), secret.utf8.allSatisfy({ (33...126).contains($0) }) else {
                        throw CollectorRuntimeError.invalidCredential
                    }
                    return .init(replicaID: reference.serverID, baseURL: URL(string: reference.baseURL)!, bearerToken: secret)
                }
                guard replicas[0].bearerToken != replicas[1].bearerToken else { throw CollectorRuntimeError.invalidCredential }
                let cas = try ImmutableArchiveCAS(root: configuration.captureURL)
                let worker = try makePublicationWorker(owner: owner, catalog: catalog, cas: cas,
                    configuration: configuration, replicas: replicas, settingsURL: settingsURL)
                let uploader = try makePublicationWorker(owner: owner, catalog: catalog, cas: cas,
                    configuration: configuration, replicas: replicas, settingsURL: settingsURL)
                return CollectorRuntime(settingsURL: settingsURL, configuration: configuration,
                    owner: owner, catalog: catalog, worker: worker, uploader: uploader)
            } catch {
                try catalog.close()
                throw error
            }
        } catch {
            try owner.close()
            throw error
        }
    }

    /// Explicitly creates a new spool from the configured, read-only machine
    /// identity. It does not start workers, read credentials or enroll roots.
    public static func initialize(settingsURL: URL) throws {
        try Task.checkCancellation()
        guard let configuration = try CollectorRuntimeConfiguration.load(at: settingsURL) else {
            throw CollectorRuntimeError.invalidConfiguration
        }
        try CollectorSpoolInitializer.create(root: configuration.shadowURL, identityCatalog: configuration.identityURL)
    }

    private static func makePublicationWorker(
        owner: CollectorInventoryOwner, catalog: ArchiveCatalog, cas: ImmutableArchiveCAS,
        configuration: CollectorRuntimeConfiguration, replicas: [CollectorReplicaEndpoint],
        settingsURL: URL
    ) throws -> CollectorPublicationWorker {
        try CollectorPublicationWorker(
            owner: owner, catalog: catalog, cas: cas, roots: configuration.rootConfigurations,
            formats: configuration.rootFormats, projectRegistryPaths: configuration.projectRegistryPaths,
            replicas: replicas, policy: {
                // Every request must still have explicit persisted role,
                // root/replica authority and the current privacy policy.
                try configuration.freshPolicy(at: settingsURL)
            }, budget: configuration.budgets.publication)
    }

    public func runOnce(now: Int64) async throws -> CollectorRuntimeCycle {
        guard !stopping, !closed, let owner, let worker else { throw CollectorRuntimeError.closed }
        guard loop == nil else { throw CollectorRuntimeError.busy }
        guard cycle == nil else { throw CollectorRuntimeError.busy }
        guard now >= 0 else { throw CollectorRuntimeError.invalidConfiguration }
        try Task.checkCancellation()
        let inventory = try advanceInventory(owner: owner)
        let unavailableCount = configuration.rootConfigurations.count - inventory.availableRoots.count
        let entered = Task {
            let publication = try await worker.runOnce(now: now, captureRootIDs: inventory.availableRoots)
            return CollectorRuntimeCycle(scannedEntries: inventory.scannedEntries, captured: publication.captured,
                recovered: publication.recovered, acknowledgedHQ: publication.acknowledgedHQ,
                acknowledgedM1: publication.acknowledgedM1, deferred: publication.deferred + unavailableCount,
                diskAdmission: publication.diskAdmission)
        }
        cycle = entered
        defer { cycle = nil }
        return try await withTaskCancellationHandler {
            try await entered.value
        } onCancel: { entered.cancel() }
    }

    private func advanceInventory(owner: CollectorInventoryOwner) throws -> (
        scannedEntries: Int, availableRoots: Set<Data>, steps: [(Int, CollectorEventCoordinatorStep)]
    ) {
        _ = try configuration.freshPolicy(at: settingsURL)
        let started = try startEventsIfNeeded(owner: owner)
        var captureRootIDs = started.available
        var scannedEntries = 0
        var steps: [(Int, CollectorEventCoordinatorStep)] = []
        for index in coordinators.keys.sorted() {
            try Task.checkCancellation()
            guard let coordinator = coordinators[index] else { continue }
            do {
                let observed = started.observations[Data(configuration.rootConfigurations[index].rootID.utf8)]
                let step = try coordinator.step(budget: configuration.budgets.bootstrap, observed: observed)
                scannedEntries += step.bootstrap?.entriesVisited ?? 0
                steps.append((index, step))
            } catch where Self.isUnavailableSource(error) {
                try suspendSource(at: index, owner: owner)
                captureRootIDs.remove(Data(configuration.rootConfigurations[index].rootID.utf8))
            }
        }
        return (scannedEntries, captureRootIDs, steps)
    }

    private func mailboxSamples(historyWaiting: [Int: Bool]) throws -> [CollectorCaptureScheduleSample] {
        try coordinators.keys.sorted().compactMap { index in
            guard let coordinator = coordinators[index] else { return nil }
            let snap = try coordinator.snapshot()
            return CollectorCaptureScheduleSample(
                phase: snap.phase, historyDone: snap.historyDone, queuedBatchCount: snap.queuedBatchCount,
                pendingGap: snap.pendingGap != nil, historyWaiting: historyWaiting[index] ?? false)
        }
    }

    private func runCaptureTurn(
        now: Int64, historyWaiting: [Int: Bool]
    ) async throws -> (hints: CollectorCaptureWorkHints, historyWaiting: [Int: Bool]) {
        guard !stopping, !closed, let owner, let worker else { throw CollectorRuntimeError.closed }
        guard now >= 0 else { throw CollectorRuntimeError.invalidConfiguration }
        try Task.checkCancellation()
        let inventory = try advanceInventory(owner: owner)
        let publication = try await worker.captureOnce(now: now, captureRootIDs: inventory.availableRoots)
        var waiting = historyWaiting
        var bootstrapProgressed = false
        var drainable = false
        for (index, step) in inventory.steps {
            if let bootstrap = step.bootstrap, CollectorCaptureScheduler.bootstrapProgressed(bootstrap) {
                bootstrapProgressed = true
            }
            if step.snapshot.phase == .watching && step.snapshot.queuedBatchCount > 0 { drainable = true }
            waiting[index] = CollectorCaptureScheduler.isHistoryWaiting(
                phase: step.snapshot.phase, bootstrap: step.bootstrap)
        }
        return (
            hints: .init(
                bootstrapProgressed: bootstrapProgressed, drainableBatchesRemaining: drainable,
                captured: publication.captured, recovered: publication.recovered),
            historyWaiting: waiting
        )
    }

    private func runUploadOnce(replicaID: String, now: Int64) async throws {
        guard !stopping, !closed, let uploader else { throw CollectorRuntimeError.closed }
        try Task.checkCancellation()
        _ = try await uploader.uploadOnce(replicaID: replicaID, now: now)
    }

    public func start() async throws {
        guard !stopping, !closed, let owner else { throw CollectorRuntimeError.closed }
        guard loop == nil, cycle == nil else { throw CollectorRuntimeError.busy }
        try Task.checkCancellation()
        _ = try configuration.freshPolicy(at: settingsURL)
        _ = try startEventsIfNeeded(owner: owner)
        let interval = configuration.budgets.pollIntervalMilliseconds
        let cheapWake = CollectorCaptureScheduler.cheapWakeMilliseconds(intervalMilliseconds: interval)
        loop = Task { [weak self] in
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    let clock = ContinuousClock()
                    var periodicDeadline = clock.now
                    var historyWaiting: [Int: Bool] = [:]
                    var forceRun = true
                    while !Task.isCancelled {
                        guard let self else { return }
                        try Task.checkCancellation()
                        let now = clock.now
                        let deadlineReached = now >= periodicDeadline
                        let samples = try await self.mailboxSamples(historyWaiting: historyWaiting)
                        if forceRun || CollectorCaptureScheduler.shouldRunCapture(
                            deadlineReached: deadlineReached, samples: samples)
                        {
                            forceRun = false
                            do {
                                let turn = try await self.runCaptureTurn(
                                    now: Int64(Date().timeIntervalSince1970), historyWaiting: historyWaiting)
                                historyWaiting = turn.historyWaiting
                                if deadlineReached {
                                    periodicDeadline = clock.now.advanced(by: .milliseconds(interval))
                                }
                                if CollectorCaptureScheduler.shouldContinuePromptly(turn.hints) {
                                    await Task.yield()
                                    forceRun = true
                                    continue
                                }
                            } catch let error as DatabaseError
                                where error.resultCode == .SQLITE_BUSY || error.resultCode == .SQLITE_LOCKED
                            {
                                try await Task.sleep(for: .milliseconds(cheapWake))
                                continue
                            }
                        }
                        try Task.checkCancellation()
                        let remaining = periodicDeadline - clock.now
                        let cheap = Duration.milliseconds(cheapWake)
                        if remaining <= .zero {
                            await Task.yield()
                            continue
                        }
                        try await Task.sleep(for: remaining < cheap ? remaining : cheap)
                    }
                }
                group.addTask { [weak self] in
                    while !Task.isCancelled {
                        guard let self else { return }
                        do {
                            try await self.runUploadOnce(replicaID: "hq", now: Int64(Date().timeIntervalSince1970))
                        } catch let error as DatabaseError where error.resultCode == .SQLITE_BUSY || error.resultCode == .SQLITE_LOCKED {}
                        try await Task.sleep(for: .milliseconds(interval))
                    }
                }
                group.addTask { [weak self] in
                    while !Task.isCancelled {
                        guard let self else { return }
                        do {
                            try await self.runUploadOnce(replicaID: "m1", now: Int64(Date().timeIntervalSince1970))
                        } catch let error as DatabaseError where error.resultCode == .SQLITE_BUSY || error.resultCode == .SQLITE_LOCKED {}
                        try await Task.sleep(for: .milliseconds(interval))
                    }
                }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
        }
    }

    public func waitUntilStopped() async throws {
        guard let joining = loop else { throw closed ? CollectorRuntimeError.closed : .notStarted }
        try await withTaskCancellationHandler {
            try await joining.value
            try Task.checkCancellation()
        } onCancel: { joining.cancel() }
    }

    public func stop() async throws {
        if closed { return }
        if let cleanup { try await cleanup.value; return }
        stopping = true
        loop?.cancel()
        cycle?.cancel()
        let joiningLoop = loop
        let joiningCycle = cycle
        // This cleanup task is not cancelled with the caller. All callers join
        // this same handle, including a second stop during HTTP cancellation.
        let joining = Task { [self] in
            var producerFailure: Error?
            do { _ = try await joiningLoop?.value }
            catch is CancellationError {}
            catch { producerFailure = error }
            do { _ = try await joiningCycle?.value }
            catch is CancellationError {}
            catch { if producerFailure == nil { producerFailure = error } }
            try finishStop()
            if let producerFailure { throw producerFailure }
        }
        cleanup = joining
        do { try await joining.value }
        catch { cleanup = nil; throw error }
    }

    private static func isUnavailableSource(_ error: Error) -> Bool {
        switch error {
        case CollectorPOSIXEnumerationError.io(.openComponent, ENOENT),
             CollectorPOSIXEnumerationError.rootIdentityChanged:
            return true
        default:
            return false
        }
    }

    private func suspendSource(at index: Int, owner: CollectorInventoryOwner) throws {
        // Revalidate storage even when source validation failed: a missing
        // inventory must never be misclassified as an unavailable source.
        _ = try owner.activateStoredRootForPublication(configuration.rootConfigurations[index])
        if let coordinator = coordinators[index] {
            do { try coordinator.stop() }
            catch where Self.isUnavailableSource(error) {
                // stop seals and joins the stream before persisting its gap.
                // A later full start requests reconciliation before scanning.
                _ = try owner.activateStoredRootForPublication(configuration.rootConfigurations[index])
            }
            coordinators.removeValue(forKey: index)
        }
    }

    private func startEventsIfNeeded(owner: CollectorInventoryOwner) throws -> (
        available: Set<Data>, observations: [Data: CollectorRootState]
    ) {
        var available = Set<Data>()
        var observations: [Data: CollectorRootState] = [:]
        var live: [(Int, CollectorRootConfiguration)] = []
        for (index, root) in configuration.rootConfigurations.enumerated() {
            try Task.checkCancellation()
            if let coordinator = coordinators[index],
               try coordinator.snapshot().phase != .recoveryRequired {
                live.append((index, root))
            }
        }
        if !live.isEmpty {
            let observed = try owner.observeLiveEnrolledRoots(live.map(\.1))
            for (entry, observation) in zip(live, observed) {
                if observation.unavailable {
                    try suspendSource(at: entry.0, owner: owner)
                } else {
                    available.insert(Data(entry.1.rootID.utf8))
                    if let state = observation.state {
                        observations[Data(entry.1.rootID.utf8)] = state
                    }
                }
            }
        }
        for (index, root) in configuration.rootConfigurations.enumerated() {
            try Task.checkCancellation()
            if live.contains(where: { $0.0 == index }) { continue }
            do {
                // Missing or recovery-required coordinators still enroll and start.
                let binding = try owner.enrollAndActivateRoot(root)
                if let coordinator = coordinators[index] {
                    try coordinator.start(epoch: CollectorNativeEventStream.currentEpoch(binding: binding))
                } else {
                    let epoch = try CollectorNativeEventStream.currentEpoch(binding: binding)
                    let budget = configuration.budgets.events
                    let coordinator = CollectorEventCoordinator(enabled: true, configuration: root, budget: budget,
                        ownerFactory: { owner }, streamFactory: { request in
                            CollectorNativeEventStream(request: request, budget: budget.ingress)
                        })
                    coordinators[index] = coordinator
                    try coordinator.start(epoch: epoch)
                }
                guard try coordinators[index]?.snapshot().phase != .recoveryRequired else {
                    // A changed native epoch is not permission to erase history.
                    throw CollectorRuntimeError.reconciliationRequired
                }
                available.insert(Data(root.rootID.utf8))
            } catch where Self.isUnavailableSource(error) {
                try suspendSource(at: index, owner: owner)
            }
        }
        return (available, observations)
    }

    private func finishStop() throws {
        var streamFailure: Error?
        for coordinator in coordinators.values {
            do { try coordinator.stop() }
            catch { if streamFailure == nil { streamFailure = error } }
        }
        // A failed synchronous pool close keeps Owner held and is retryable by
        // another stop. ARC lifetime is not a database-close barrier.
        try catalog?.close()
        uploader = nil
        worker = nil
        catalog = nil
        coordinators.removeAll()
        cycle = nil
        loop = nil
        try owner?.close()
        owner = nil
        closed = true
        if let streamFailure { throw streamFailure }
    }

    private static func openExistingCapture(_ configuration: CollectorRuntimeConfiguration, machineID: String) throws -> ArchiveCatalog {
        let root = configuration.captureURL
        let path = root.appendingPathComponent("archive.sqlite")
        let components = try CollectorPOSIXDirectoryAccess.components(root.path)
        let directory: (descriptor: Int32, info: stat)
        do { directory = try CollectorPOSIXDirectoryAccess.openAbsolute(components: components) }
        catch { throw CollectorRuntimeError.invalidConfiguration }
        defer { CollectorPOSIXDirectoryAccess.close(directory.descriptor) }
        try privateDirectory(directory.info)
        let directoryIdentity = try CollectorPOSIXDirectoryAccess.identity(directory.info)
        // Provisioned means all fixed CAS directories already exist. Neither
        // ArchiveCatalog nor ImmutableArchiveCAS may supply missing roots here.
        for relative in ["objects", "objects/sha256", "manifests", "manifests/sha256", "tmp"] {
            do {
                let opened = try CollectorPOSIXDirectoryAccess.openAbsolute(components: components + relative.split(separator: "/").map(String.init))
                defer { CollectorPOSIXDirectoryAccess.close(opened.descriptor) }
                try privateDirectory(opened.info)
            } catch { throw CollectorRuntimeError.invalidConfiguration }
        }
        let descriptor = openat(directory.descriptor, "archive.sqlite", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw CollectorRuntimeError.invalidConfiguration }
        defer { _ = Darwin.close(descriptor) }
        var original = stat()
        guard fstat(descriptor, &original) == 0, safeFile(original) else { throw CollectorRuntimeError.invalidConfiguration }

        func fence(checkContents: Bool) throws {
            let route = try CollectorPOSIXDirectoryAccess.openAbsolute(components: components)
            defer { CollectorPOSIXDirectoryAccess.close(route.descriptor) }
            guard try CollectorPOSIXDirectoryAccess.identity(route.info) == directoryIdentity else {
                throw CollectorRuntimeError.invalidConfiguration
            }
            var named = stat()
            var held = stat()
            guard fstatat(directory.descriptor, "archive.sqlite", &named, AT_SYMLINK_NOFOLLOW) == 0,
                  fstat(descriptor, &held) == 0, safeFile(named), safeFile(held),
                  named.st_dev == original.st_dev, named.st_ino == original.st_ino,
                  held.st_dev == original.st_dev, held.st_ino == original.st_ino else {
                throw CollectorRuntimeError.invalidConfiguration
            }
            if checkContents {
                guard held.st_size == original.st_size,
                      held.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec,
                      held.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec,
                      held.st_ctimespec.tv_sec == original.st_ctimespec.tv_sec,
                      held.st_ctimespec.tv_nsec == original.st_ctimespec.tv_nsec else {
                    throw CollectorRuntimeError.invalidConfiguration
                }
            }
            for name in ["archive.sqlite-wal", "archive.sqlite-shm", "archive.sqlite-journal"] {
                var info = stat()
                if fstatat(directory.descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                    guard safeFile(info) else { throw CollectorRuntimeError.invalidConfiguration }
                } else if errno != ENOENT { throw CollectorRuntimeError.invalidConfiguration }
            }
        }

        try fence(checkContents: true)
        guard let resolved = Darwin.realpath(path.path, nil) else { throw CollectorRuntimeError.invalidConfiguration }
        let canonicalPath = String(cString: resolved)
        Darwin.free(resolved)
        var readConfiguration = Configuration()
        readConfiguration.readonly = false
        readConfiguration.foreignKeysEnabled = false
        readConfiguration.busyMode = .timeout(0.5)
        readConfiguration.prepareDatabase { database in
            try database.execute(sql: "PRAGMA query_only = ON")
            var moved: Int32 = 0
            guard sqlite3_db_readonly(database.sqliteConnection, "main") == 0,
                  try Int.fetchOne(database, sql: "PRAGMA query_only") == 1,
                  let filename = sqlite3_db_filename(database.sqliteConnection, "main"),
                  let mode = sqlite3_uri_parameter(filename, "mode"), String(cString: mode) == "rw",
                  String(cString: filename) == canonicalPath,
                  sqlite3_file_control(database.sqliteConnection, "main", SQLITE_FCNTL_HAS_MOVED, &moved) == SQLITE_OK,
                  moved == 0 else { throw CollectorRuntimeError.invalidConfiguration }
        }
        // This is the exclusively owned capture spool, NOT the borrowed identity
        // catalog. mode=rw requires an existing main file and lets SQLite
        // initialize this spool's own WAL/SHM. Only fixed SELECT statements run
        // with query_only enabled; this is not a read-only-main guarantee.
        // Neither borrowed identity reader uses this owned-storage topology.
        var parts = URLComponents(url: path, resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "mode", value: "rw")]
        let database: DatabaseQueue
        do { database = try DatabaseQueue(path: parts.url!.absoluteString, configuration: readConfiguration) }
        catch { throw CollectorRuntimeError.invalidConfiguration }
        var openedCatalog: ArchiveCatalog?
        do {
            // GRDB.read resets query_only when its scope exits. Access the
            // already query-only connection without that flag transition.
            try database.writeWithoutTransaction { db in
                guard try Int.fetchOne(db, sql: "PRAGMA query_only") == 1 else {
                    throw CollectorRuntimeError.invalidConfiguration
                }
                let identities = try String.fetchAll(db, sql: """
                    SELECT value FROM archive_metadata
                    WHERE key = 'machine_id' AND typeof(value) = 'text' AND length(CAST(value AS BLOB)) = 36 LIMIT 2
                    """)
                guard identities.count == 1, identities[0] == machineID,
                      try String.fetchOne(db, sql: "SELECT value FROM archive_metadata WHERE key = 'schema_version'") == ArchiveCatalogMigrations.currentSchemaVersion else {
                    throw CollectorRuntimeError.invalidConfiguration
                }
                // Prepare the capture-owned schema without scanning rows or
                // migrating a stale/spoofed version marker into readiness.
                _ = try Row.fetchAll(db, sql: "SELECT capture_id, machine_id, source, locator, generation_device, generation_inode, generation_size, generation_mtime_ns, generation_ctime_ns, generation_mode, whole_source_sha256, raw_byte_count, chunk_size, unbound_manifest_sha256, unbound_manifest_bytes, status, captured_at FROM archive_captures LIMIT 0")
                _ = try Row.fetchAll(db, sql: "SELECT capture_id, manifest_sha256 FROM archive_session_bindings LIMIT 0")
                _ = try Row.fetchAll(db, sql: "SELECT object_sha256 FROM archive_local_objects LIMIT 0")
                _ = try Row.fetchAll(db, sql: "SELECT manifest_sha256, object_sha256 FROM archive_manifest_objects LIMIT 0")
                try fence(checkContents: true)
            }
            try fence(checkContents: true)
            try Task.checkCancellation()
            // Do not make preflight the last connection before entering the
            // validated writer phase: its close may checkpoint committed WAL
            // left by a previously closed pool. Keep all content fences before
            // this ordinary owned-writer open, and all identity fences after it.
            let catalog = try ArchiveCatalog(root: root, machineID: machineID)
            openedCatalog = catalog
            try fence(checkContents: false)
            guard try catalog.machineID() == machineID else { throw CollectorRuntimeError.invalidConfiguration }
            try database.close()
            try fence(checkContents: false)
            return catalog
        } catch {
            let originalError = error
            var cleanupError: Error?
            if let openedCatalog {
                do { try openedCatalog.close() }
                catch { cleanupError = error }
            }
            do { try database.close() }
            catch { if cleanupError == nil { cleanupError = error } }
            if let cleanupError { throw cleanupError }
            if originalError is CancellationError { throw CancellationError() }
            throw CollectorRuntimeError.invalidConfiguration
        }
    }

    private static func privateDirectory(_ info: stat) throws {
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else {
            throw CollectorRuntimeError.invalidConfiguration
        }
    }

    private static func safeFile(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFREG && info.st_uid == geteuid() && info.st_nlink == 1 && info.st_mode & 0o777 == 0o600
    }
}

private struct CollectorRuntimeConfiguration {
    struct Root: Decodable {
        let rootID: String
        let source: String
        let rootPath: String
        let revision: Int64
        let parseFormat: String?
        let projectRegistryPath: String?
        let cursorLegacy: Bool?
        let cursorModernRootID: String?
    }
    struct Replica: Decodable {
        let serverID: String
        let baseURL: String
        let credentialID: String
    }
    struct Privacy: Decodable {
        let revision: Int64
        let excludedProjectRoots: [String]
    }
    struct Document: Decodable {
        let shadowRoot: String
        let identityCatalog: String
        let roots: [Root]
        let replicas: [Replica]
        let privacy: Privacy
        let budgets: Budgets
    }
    struct Budgets: Decodable {
        let maxEntriesVisited: Int
        let maxCandidateFiles: Int
        let maxDirectoryOpens: Int
        let maxMetadataBytes: Int
        let maxCaptureFiles: Int
        let maxCaptureBytes: Int64
        let maxUploadClaimsPerReplica: Int
        let maxRecoveryCandidates: Int
        let maxResponseBytes: Int
        let minimumFreeDiskBytes: Int64
        let maxIncomingPaths: Int
        let maxPathUTF8Bytes: Int
        let maxTotalPathUTF8Bytes: Int
        let maxCheckpointUTF8Bytes: Int
        let maxQueuedBatches: Int
        let maxQueuedUTF8Bytes: Int
        let pollIntervalMilliseconds: Int

        var bootstrap: CollectorBootstrapBudget {
            .init(maxEntriesVisited: maxEntriesVisited, maxCandidateFiles: maxCandidateFiles,
                maxDirectoryOpens: maxDirectoryOpens, maxMetadataBytes: maxMetadataBytes)
        }
        var events: CollectorEventCoordinatorBudget {
            .init(ingress: .init(maxIncomingPaths: maxIncomingPaths, maxPathUTF8Bytes: maxPathUTF8Bytes,
                maxTotalPathUTF8Bytes: maxTotalPathUTF8Bytes, maxCheckpointUTF8Bytes: maxCheckpointUTF8Bytes),
                maxQueuedBatches: maxQueuedBatches, maxQueuedUTF8Bytes: maxQueuedUTF8Bytes)
        }
        var publication: CollectorPublicationBudget {
            .init(maxCaptureFiles: maxCaptureFiles, maxCaptureBytes: maxCaptureBytes,
                maxUploadClaimsPerReplica: maxUploadClaimsPerReplica, maxRecoveryCandidates: maxRecoveryCandidates,
                maxResponseBytes: maxResponseBytes, minimumFreeDiskBytes: minimumFreeDiskBytes)
        }
        var valid: Bool {
            (1...4096).contains(maxEntriesVisited) && (1...1024).contains(maxCandidateFiles)
                && (1...128).contains(maxDirectoryOpens) && (512...1_048_576).contains(maxMetadataBytes)
                && (1...64).contains(maxCaptureFiles) && (1...1_073_741_824).contains(maxCaptureBytes)
                && (1...64).contains(maxUploadClaimsPerReplica) && (1...64).contains(maxRecoveryCandidates)
                && (1...CollectorPublicationProtocolLimits.maxAcceptanceRecordBytes).contains(maxResponseBytes)
                && minimumFreeDiskBytes >= 0 && (1...1024).contains(maxIncomingPaths)
                && (1...65_536).contains(maxPathUTF8Bytes) && (1...1_048_576).contains(maxTotalPathUTF8Bytes)
                && (128...4096).contains(maxCheckpointUTF8Bytes) && (1...64).contains(maxQueuedBatches)
                && (512...8_388_608).contains(maxQueuedUTF8Bytes) && (10...60_000).contains(pollIntervalMilliseconds)
        }
    }

    let document: Document
    let authorityBytes: Data
    var shadowURL: URL { URL(fileURLWithPath: document.shadowRoot) }
    var captureURL: URL { shadowURL.appendingPathComponent("capture") }
    var identityURL: URL { URL(fileURLWithPath: document.identityCatalog) }
    var replicas: [Replica] { document.replicas }
    var budgets: Budgets { document.budgets }
    var rootConfigurations: [CollectorRootConfiguration] {
        document.roots.map { .init(rootID: $0.rootID, source: SourceName(rawValue: $0.source)!, rootPath: $0.rootPath, revision: $0.revision,
            cursorLegacy: $0.cursorLegacy ?? false, cursorModernRootID: $0.cursorModernRootID) }
    }

    var rootFormats: [String: SourceMetadataProjection.Format] {
        Dictionary(uniqueKeysWithValues: document.roots.compactMap { root in
            Self.rootFormat(source: root.source, parseFormat: root.parseFormat).map { (root.rootID, $0) }
        })
    }

    var projectRegistryPaths: [String: String] {
        Dictionary(uniqueKeysWithValues: document.roots.compactMap { root in
            root.projectRegistryPath.map { (root.rootID, $0) }
        })
    }

    func freshPolicy(at url: URL) throws -> CollectorPrivacyPolicy {
        guard let current = try Self.load(at: url), current.authorityBytes == authorityBytes,
              current.document.privacy.revision >= document.privacy.revision else {
            throw CollectorRuntimeError.invalidConfiguration
        }
        return try current.policy()
    }

    private func policy() throws -> CollectorPrivacyPolicy {
        var sources = Set(rootConfigurations.map(\.source))
        if rootFormats.values.contains(.claudeCode(forceClaudeCodeSource: false)) {
            sources.formUnion([.minimax, .lobsterai])
        }
        return try .init(revision: document.privacy.revision, excludedProjectRoots: document.privacy.excludedProjectRoots,
            allowedSources: sources)
    }

    static func load(at url: URL) throws -> Self? {
        guard url.isFileURL, (try? CollectorPOSIXDirectoryAccess.components(url.path)) != nil else {
            throw CollectorRuntimeError.invalidSettings
        }
        guard let bytes = SecureRegularFile.read(atPath: url.path, maximumBytes: RuntimeRoleSettings.maximumBytes, repairPermissions: false) else {
            var info = stat()
            if lstat(url.path, &info) != 0, errno == ENOENT { return nil }
            throw CollectorRuntimeError.invalidSettings
        }
        guard let settings = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw CollectorRuntimeError.invalidSettings
        }
        guard let raw = settings["collector"] else { return nil }
        guard let block = raw as? [String: Any], let flag = block["enabled"],
              CFGetTypeID(flag as CFTypeRef) == CFBooleanGetTypeID(), let enabled = flag as? Bool else {
            throw CollectorRuntimeError.invalidConfiguration
        }
        if !enabled {
            guard block.count == 1 else { throw CollectorRuntimeError.invalidConfiguration }
            return nil
        }
        guard settings["runtimeRole"] as? String == "collector" else { throw CollectorRuntimeError.invalidRole }
        do {
            try keys(block, exactly: ["enabled", "shadowRoot", "identityCatalog", "roots", "replicas", "privacy", "budgets"])
            guard let roots = block["roots"] as? [[String: Any]], let replicas = block["replicas"] as? [[String: Any]],
                  let privacy = block["privacy"] as? [String: Any], let budgets = block["budgets"] as? [String: Any] else {
                throw CollectorRuntimeError.invalidConfiguration
            }
            for root in roots {
                try keys(root, exactly: ["rootID", "source", "rootPath", "revision"],
                    allowing: ["parseFormat", "projectRegistryPath", "cursorLegacy", "cursorModernRootID"])
            }
            for replica in replicas { try keys(replica, exactly: ["serverID", "baseURL", "credentialID"]) }
            try keys(privacy, exactly: ["revision", "excludedProjectRoots"])
            try keys(budgets, exactly: ["maxEntriesVisited", "maxCandidateFiles", "maxDirectoryOpens", "maxMetadataBytes",
                "maxCaptureFiles", "maxCaptureBytes", "maxUploadClaimsPerReplica", "maxRecoveryCandidates", "maxResponseBytes",
                "minimumFreeDiskBytes", "maxIncomingPaths", "maxPathUTF8Bytes", "maxTotalPathUTF8Bytes", "maxCheckpointUTF8Bytes",
                "maxQueuedBatches", "maxQueuedUTF8Bytes", "pollIntervalMilliseconds"])
            let data = try JSONSerialization.data(withJSONObject: block, options: [.sortedKeys])
            let value = try JSONDecoder().decode(Document.self, from: data)
            guard value.budgets.valid, validPath(value.shadowRoot), validPath(value.identityCatalog),
                  (1...64).contains(value.roots.count), Set(value.roots.map { Data($0.rootID.utf8) }).count == value.roots.count,
                  value.roots.allSatisfy({ identifier($0.rootID) && ($0.source == "codex" || $0.source == "claude-code" || $0.source == "qwen"
                      || $0.source == "qoder" || $0.source == "iflow" || $0.source == "vscode" || $0.source == "cline" || $0.source == "commandcode" || $0.source == "copilot"
                      || $0.source == "gemini-cli" || $0.source == "opencode" || $0.source == "kimi" || $0.source == "cursor"
                      || $0.source == "antigravity" || $0.source == "windsurf" || $0.source == "pi"
                      || $0.source == "grok")
                      && validPath($0.rootPath) && $0.revision > 0
                      && rootFormat(source: $0.source, parseFormat: $0.parseFormat) != nil
                      && !overlaps($0.rootPath, value.shadowRoot)
                      && !overlaps($0.rootPath, URL(fileURLWithPath: value.identityCatalog).deletingLastPathComponent().path)
                      && validRegistry($0, shadowRoot: value.shadowRoot, identityCatalog: value.identityCatalog) }),
                  value.replicas.count == 2, Set(value.replicas.map(\.serverID)) == Set(["hq", "m1"]),
                  Set(value.replicas.map(\.credentialID)).count == 2,
                  value.replicas.allSatisfy({ identifier($0.credentialID) && endpoint($0.baseURL) != nil }),
                  Set(value.replicas.compactMap { endpoint($0.baseURL) }).count == 2,
                  value.privacy.revision > 0, value.privacy.excludedProjectRoots.count <= 128,
                  value.privacy.excludedProjectRoots.allSatisfy(validPath) else {
                throw CollectorRuntimeError.invalidConfiguration
            }
            var authority = block
            authority.removeValue(forKey: "privacy")
            let result = Self(document: value, authorityBytes: try JSONSerialization.data(withJSONObject: authority, options: [.sortedKeys]))
            for root in result.rootConfigurations {
                guard root.validCursorLayout else { throw CollectorRuntimeError.invalidConfiguration }
                if root.cursorLegacy {
                    let ownershipRoot = URL(fileURLWithPath: root.rootPath).deletingLastPathComponent().path
                    guard !overlaps(ownershipRoot, value.shadowRoot),
                          !overlaps(ownershipRoot, URL(fileURLWithPath: value.identityCatalog).deletingLastPathComponent().path) else {
                        throw CollectorRuntimeError.invalidConfiguration
                    }
                }
                if let modernID = root.cursorModernRootID {
                    guard let modern = result.rootConfigurations.first(where: { $0.rootID.utf8.elementsEqual(modernID.utf8) }),
                          modern.source == .cursor, !modern.cursorLegacy,
                          !overlaps(root.rootPath, modern.rootPath) else { throw CollectorRuntimeError.invalidConfiguration }
                }
            }
            _ = try result.policy()
            return result
        } catch { throw CollectorRuntimeError.invalidConfiguration }
    }

    private static func keys(_ value: [String: Any], exactly: Set<String>, allowing: Set<String> = []) throws {
        let present = Set(value.keys)
        guard exactly.isSubset(of: present), present.subtracting(exactly).isSubset(of: allowing) else {
            throw CollectorRuntimeError.invalidConfiguration
        }
    }

    private static func rootFormat(source: String, parseFormat: String?) -> SourceMetadataProjection.Format? {
        switch (source, parseFormat) {
        case ("codex", nil), ("codex", "codex"):
            return .codex
        case ("claude-code", nil), ("claude-code", "claudeDefault"):
            return .claudeCode(forceClaudeCodeSource: false)
        case ("claude-code", "claudeCustomProfile"):
            return .claudeCode(forceClaudeCodeSource: true)
        case ("qwen", nil), ("qwen", "qwen"):
            return .qwen
        case ("vscode", nil), ("vscode", "vscode"):
            return .vscode
        case ("cline", nil), ("cline", "cline"):
            return .cline
        case ("iflow", nil), ("iflow", "iflow"):
            return .iflow
        case ("qoder", nil), ("qoder", "qoder"):
            return .qoder
        case ("commandcode", nil), ("commandcode", "commandcode"):
            return .commandcode
        case ("copilot", nil), ("copilot", "copilot"):
            return .copilot
        case ("gemini-cli", nil), ("gemini-cli", "gemini-cli"):
            return .geminiCli
        case ("opencode", nil), ("opencode", "opencode"):
            return .opencode
        case ("kimi", nil), ("kimi", "kimi"):
            return .kimi
        case ("cursor", nil), ("cursor", "cursor"):
            return .cursor
        case ("antigravity", nil), ("antigravity", "antigravityCLITranscript"):
            return .antigravityCLITranscript
        case ("windsurf", nil), ("windsurf", "windsurfHookTranscript"):
            return .windsurfHookTranscript
        case ("pi", nil), ("pi", "pi"):
            return .pi
        case ("grok", nil), ("grok", "grok"):
            return .grok
        default:
            return nil
        }
    }

    private static func identifier(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count) && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 || $0 == 46
        }
    }

    private static func validPath(_ path: String) -> Bool {
        path.utf8.count <= CollectorPOSIXRootEnumerator.maximumPathBytes
            && (try? CollectorPOSIXDirectoryAccess.components(path)) != nil
    }

    private static func validRegistry(_ root: Root, shadowRoot: String, identityCatalog: String) -> Bool {
        if root.source == "kimi" {
            guard let path = root.projectRegistryPath else { return false }
            return validConfiguredRegistry(path, rootPath: root.rootPath, shadowRoot: shadowRoot,
                identityCatalog: identityCatalog)
        }
        guard let path = root.projectRegistryPath else { return true }
        return root.source == "gemini-cli"
            && validConfiguredRegistry(path, rootPath: root.rootPath, shadowRoot: shadowRoot,
                identityCatalog: identityCatalog)
    }

    private static func validConfiguredRegistry(
        _ path: String, rootPath: String, shadowRoot: String, identityCatalog: String
    ) -> Bool {
        validPath(path)
            && ArchiveSourceDescriptor.fileSetAbsolutePath(path) == path
            && !overlaps(path, rootPath)
            && !overlaps(path, shadowRoot)
            && !overlaps(path, URL(fileURLWithPath: identityCatalog).deletingLastPathComponent().path)
    }

    private static func overlaps(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || lhs.hasPrefix(rhs + "/") || rhs.hasPrefix(lhs + "/")
    }

    private static func endpoint(_ value: String) -> String? {
        guard value.utf8.count <= 2048, value.utf8.allSatisfy({ (33...126).contains($0) }), !value.contains("%"),
              let url = URLComponents(string: value), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/", url.port.map({ (1...65535).contains($0) }) ?? true,
              url.scheme == "https" || (url.scheme == "http" && ["127.0.0.1", "[::1]"].contains(host)) else { return nil }
        return "\(url.scheme!)://\(host.lowercased()):\(url.port ?? (url.scheme == "https" ? 443 : 80))"
    }
}
