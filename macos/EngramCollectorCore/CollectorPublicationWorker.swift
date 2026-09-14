import Darwin
import Foundation

enum CollectorPublicationWorkerError: Error, Equatable {
    case invalidConfiguration
    case invalidCapture
    case invalidBudget
    case sequenceExhausted
    case reconciliationRequired
    case staleClaim
    case withheld
    case unsupportedReplica
    case transport
    case invalidACK
    case responseTooLarge
}

struct CollectorPublicationIntent: Equatable, Sendable {
    let captureID: String
    let rootID: String
    let rootRevision: Int64
    let relativePath: String
    let publication: CollectorPublicationEnvelope
    let canonicalBytes: Data
    let digest: String
}

struct CollectorPublicationClaim: Equatable, Sendable {
    let intent: CollectorPublicationIntent
    let replicaID: String
    let ownerRunID: String
    let claimGeneration: Int64
    let attempts: Int64
}

enum CollectorPublicationDeferral: String, Sendable {
    case unavailable, unsupportedReplica, invalidACK, privacyWithheld, localContentUnavailable
}

/// A durable pre-capture ordering reservation, not permission to send bytes.
/// Only one unfinished reservation per configured stream may exist.
struct CollectorCaptureReservation: Equatable, Sendable {
    let id: String
    let rootID: String
    let rootRevision: Int64
    let relativePath: String
    let dirtyRevision: Int64
    let generation: ArchiveSourceGeneration
    let sourceInstanceID: String
    let collectorEpoch: String
    let sequence: Int64
    let snapshot: CollectorDependencySnapshot?
    let sqliteSession: ArchiveSQLiteSessionContext?
    let cursorLegacySession: ArchiveCursorLegacyContext?
    let effectiveSource: SourceName?

    init(
        id: String, rootID: String, rootRevision: Int64, relativePath: String, dirtyRevision: Int64,
        generation: ArchiveSourceGeneration, sourceInstanceID: String, collectorEpoch: String, sequence: Int64,
        snapshot: CollectorDependencySnapshot? = nil, sqliteSession: ArchiveSQLiteSessionContext? = nil,
        cursorLegacySession: ArchiveCursorLegacyContext? = nil, effectiveSource: SourceName? = nil
    ) {
        self.id = id
        self.rootID = rootID
        self.rootRevision = rootRevision
        self.relativePath = relativePath
        self.dirtyRevision = dirtyRevision
        self.generation = generation
        self.sourceInstanceID = sourceInstanceID
        self.collectorEpoch = collectorEpoch
        self.sequence = sequence
        self.snapshot = snapshot
        self.sqliteSession = sqliteSession
        self.cursorLegacySession = cursorLegacySession
        self.effectiveSource = effectiveSource
    }
}

struct CollectorReplicaEndpoint: Sendable {
    let replicaID: String
    let baseURL: URL
    let bearerToken: String
}

struct CollectorPublicationBudget: Sendable {
    var maxCaptureFiles: Int = 4
    var maxCaptureBytes: Int64 = 32 * 1024 * 1024
    var maxUploadClaimsPerReplica: Int = 4
    var maxRecoveryCandidates: Int = 64
    var maxResponseBytes: Int = CollectorPublicationProtocolLimits.maxAcceptanceRecordBytes
    var minimumFreeDiskBytes: Int64 = 16 * 1024 * 1024
}

public enum CollectorDiskAdmissionStatus: Equatable, Sendable {
    case notEvaluated
    /// Per-cycle minimum bytes from actual admission samples; nil means that
    /// volume was not checked. These observations are not a health guarantee.
    case observed(minimumFreeDiskBytes: Int64, inventoryMinimumAvailableBytes: Int64?, captureMinimumAvailableBytes: Int64?)
}

struct CollectorPublicationCycle: Equatable, Sendable {
    var captured = 0
    var recovered = 0
    var acknowledgedHQ = 0
    var acknowledgedM1 = 0
    var deferred = 0
    var sourceHintBytesRead: Int64 = 0
    var diskAdmission: CollectorDiskAdmissionStatus = .notEvaluated
}

enum CollectorDiscoverModernPurpose: Sendable, Equatable {
    case observationHint
    case captureAuthorization
}

struct CollectorPublicationWorkerTestHooks: Sendable {
    var beforeCapture: (@Sendable (CollectorCaptureReservation) throws -> Void)?
    var beforeCaptureFDAdmission: (@Sendable (CollectorCaptureReservation) throws -> Void)?
    var afterCapture: (@Sendable (ArchiveCaptureResult) throws -> Void)?
    var beforeRequest: (@Sendable (_ replicaID: String, _ path: String) throws -> Void)?
    var beforeHTTP: (@Sendable (_ replicaID: String, _ path: String, _ method: String) throws -> Void)?
    var afterResponse: (@Sendable (_ replicaID: String, _ path: String, _ bytes: Data) throws -> Data)?
    var beforeACKCommit: (@Sendable (CollectorPublicationClaim) throws -> Void)?
    var beforeDiscoverModern: (@Sendable (_ rootPath: String, _ purpose: CollectorDiscoverModernPurpose) throws -> Void)?
    var beforePeerRootState: (@Sendable () throws -> Void)?
}

/// Native capture and publication only. No index, app, service or product writer.
actor CollectorPublicationWorker {
    private let owner: CollectorInventoryOwner
    private let catalog: ArchiveCatalog
    private let cas: ImmutableArchiveCAS
    private let roots: [CollectorRootConfiguration]
    private let formats: [String: SourceMetadataProjection.Format]
    private let projectRegistryPaths: [String: String]
    private let replicas: [CollectorReplicaEndpoint]
    private let policy: @Sendable () throws -> CollectorPrivacyPolicy
    private let budget: CollectorPublicationBudget
    private let testHooks: CollectorPublicationWorkerTestHooks
    private let transport: CollectorPublicationHTTPTransport
    private var capturing = false
    private var pendingUnavailableDeferrals: [PendingUnavailableDeferral] = []
    private var uploading: Set<String> = []

    private struct PendingUnavailableDeferral {
        let claim: CollectorDirtyClaim
        let configuration: CollectorRootConfiguration
        let retryNotBefore: Int64
    }
    private var dependencyObservationTime: Int64?
    private var cursorLegacyObservationTime: Int64?
    private var cursorLegacyObservationRoot = 0
    private var captureRootStart = 0
    private var recoveryReservationStart = 0
    private var dependencyObservationRoot = 0
    private var dependencyObservationAfter: [Data: String] = [:]
    private var peerFingerprintHints: [Data: PeerFingerprintHint] = [:]

    private struct PeerFingerprintHint {
        let configuration: CollectorRootConfiguration
        let fingerprint: String
        let observedAt: Int64
        let eventCheckpoint: CollectorEventCheckpoint?
        let requestedRevision: Int64
        let completedRevision: Int64
    }

    init(
        owner: CollectorInventoryOwner,
        catalog: ArchiveCatalog,
        cas: ImmutableArchiveCAS,
        roots: [CollectorRootConfiguration],
        formats: [String: SourceMetadataProjection.Format] = [:],
        projectRegistryPaths: [String: String] = [:],
        replicas: [CollectorReplicaEndpoint],
        policy: @escaping @Sendable () throws -> CollectorPrivacyPolicy,
        budget: CollectorPublicationBudget = .init(),
        testHooks: CollectorPublicationWorkerTestHooks = .init()
    ) throws {
        guard (1...64).contains(roots.count),
              Set(roots.map { Data($0.rootID.utf8) }).count == roots.count,
              roots.allSatisfy({ !$0.rootID.isEmpty && !$0.rootID.contains("\0") && $0.revision > 0
                  && ($0.source == .codex || $0.source == .claudeCode || $0.source == .qwen
                      || $0.source == .qoder || $0.source == .iflow || $0.source == .vscode || $0.source == .cline || $0.source == .commandcode || $0.source == .copilot
                      || $0.source == .geminiCli || $0.source == .opencode || $0.source == .kimi || $0.source == .cursor || $0.source == .antigravity || $0.source == .windsurf || $0.source == .pi || $0.source == .grok)
                  && $0.validCursorLayout
                  && (try? CollectorPOSIXDirectoryAccess.components($0.rootPath)) != nil }),
              replicas.count == 2, Set(replicas.map(\.replicaID)) == Set(["hq", "m1"]),
              replicas.allSatisfy(Self.validEndpoint),
              Set(replicas.map(Self.origin)).count == 2,
              replicas[0].bearerToken != replicas[1].bearerToken,
              formats.allSatisfy({ id, format in
                  roots.contains { root in
                      root.rootID.utf8.elementsEqual(id.utf8) && Self.compatible(source: root.source, format: format)
                  }
              }),
              projectRegistryPaths.allSatisfy({ id, path in
                  roots.contains { root in
                      root.rootID.utf8.elementsEqual(id.utf8)
                          && (root.source == .geminiCli || root.source == .kimi)
                          && ArchiveSourceDescriptor.fileSetAbsolutePath(path) == path
                          && !path.utf8.elementsEqual(root.rootPath.utf8)
                          && !path.hasPrefix(root.rootPath + "/")
                          && !root.rootPath.hasPrefix(path + "/")
                  }
              }),
              roots.allSatisfy({ root in
                  guard let peer = root.cursorModernRootID else { return true }
                  return roots.contains { $0.rootID.utf8.elementsEqual(peer.utf8) && $0.source == .cursor && !$0.cursorLegacy }
              }),
              roots.allSatisfy({ root in
                  root.source != .kimi || projectRegistryPaths.contains {
                      $0.key.utf8.elementsEqual(root.rootID.utf8)
                  }
              }) else {
            throw CollectorPublicationWorkerError.invalidConfiguration
        }
        guard (0...64).contains(budget.maxCaptureFiles), budget.maxCaptureBytes > 0,
              (1...64).contains(budget.maxUploadClaimsPerReplica),
              (1...64).contains(budget.maxRecoveryCandidates),
              (1...CollectorPublicationProtocolLimits.maxAcceptanceRecordBytes).contains(budget.maxResponseBytes),
              budget.minimumFreeDiskBytes >= 0 else { throw CollectorPublicationWorkerError.invalidBudget }
        guard try catalog.machineID() == owner.machineIdentity() else {
            throw CollectorPublicationWorkerError.invalidConfiguration
        }
        self.owner = owner
        self.catalog = catalog
        self.cas = cas
        self.roots = roots
        self.formats = formats
        self.projectRegistryPaths = projectRegistryPaths
        self.replicas = replicas.sorted { $0.replicaID < $1.replicaID }
        self.policy = policy
        self.budget = budget
        self.testHooks = testHooks
        transport = CollectorPublicationHTTPTransport()
    }

    func runOnce(now: Int64, captureRootIDs: Set<Data>? = nil) async throws -> CollectorPublicationCycle {
        var result = try await captureOnce(now: now, captureRootIDs: captureRootIDs)
        async let hq = uploadOnce(replicaID: replicas[0].replicaID, now: now)
        async let m1 = uploadOnce(replicaID: replicas[1].replicaID, now: now)
        let completed = try await (hq, m1)
        result.acknowledgedHQ = completed.0.acknowledged
        result.acknowledgedM1 = completed.1.acknowledged
        result.deferred += completed.0.deferred + completed.1.deferred
        return result
    }

    func captureOnce(now: Int64, captureRootIDs: Set<Data>? = nil) async throws -> CollectorPublicationCycle {
        guard now >= 0 else { throw CollectorPublicationWorkerError.invalidBudget }
        try Task.checkCancellation()
        guard !capturing else { return .init() }
        capturing = true
        defer { capturing = false }
        try drainUnavailableDeferrals()
        var captureRootIDs = captureRootIDs ?? Set(roots.map { Data($0.rootID.utf8) })
        var result = CollectorPublicationCycle()
        while true {
            do {
                try reconcileConfiguredRegistries(captureRootIDs: captureRootIDs)
                try reconcileCapturedDependencies(now: now, captureRootIDs: captureRootIDs)
                try reconcileCursorLegacyObservations(now: now, captureRootIDs: captureRootIDs)
                break
            } catch {
                switch error {
                case CollectorPOSIXEnumerationError.io(.openComponent, ENOENT),
                     CollectorPOSIXEnumerationError.rootIdentityChanged:
                    break
                default:
                    throw error
                }
                let previousCount = captureRootIDs.count
                for root in roots where captureRootIDs.contains(Data(root.rootID.utf8)) {
                    if try owner.sourceRootIsUnavailable(root) {
                        captureRootIDs.remove(Data(root.rootID.utf8))
                    }
                }
                // Each retry removes at least one configured root, bounding
                // this loop. Storage/configuration failures are never deferred.
                guard captureRootIDs.count < previousCount else { throw error }
                result.deferred += previousCount - captureRootIDs.count
            }
        }
        var remainingFiles = budget.maxCaptureFiles
        var remainingBytes = budget.maxCaptureBytes
        var remainingHintBytes = budget.maxCaptureBytes
        var remainingComparisonBytes = budget.maxCaptureBytes
        var remainingRecovery = budget.maxRecoveryCandidates
        let reservations = try owner.captureReservations(limit: 64)
        // A pre-existing reservation is reconciled before that stream can mint
        // another sequence. No timestamp/digest is used as publication order.
        // Rotate the first scanned reservation so one unfinished catalog page
        // cannot consume every cycle's shared recovery budget.
        let recoveryStart = reservations.isEmpty ? 0 : recoveryReservationStart % reservations.count
        if !reservations.isEmpty { recoveryReservationStart = recoveryStart + 1 }
        // Yield only between independent recovery/capture units so a queued
        // uploader can enter the actor. Never yield inside performCapture or a
        // SQLite snapshot/transaction lease. A legacy/OpenCode dirty walk stays
        // one unit for its whole page (startup revalidation of tracked rows).
        var allowQueuedWork = false
        func cooperateBetweenIndependentUnits() async throws {
            if allowQueuedWork {
                try Task.checkCancellation()
                await Task.yield()
                try Task.checkCancellation()
            }
            allowQueuedWork = true
        }
        for offset in reservations.indices {
            try await cooperateBetweenIndependentUnits()
            let reservation = reservations[(recoveryStart + offset) % reservations.count]
            try Task.checkCancellation()
            guard let root = configuration(rootID: reservation.rootID, revision: reservation.rootRevision) else { continue }
            let recovery = try recover(reservation, root: root, remainingCandidates: &remainingRecovery)
            switch recovery {
            case .completed: result.recovered += 1
            case .pending: result.deferred += 1
            case .uncaptured:
                guard allowsLiveCapture(root, captureRootIDs) else {
                    result.deferred += 1
                    continue
                }
                if reservation.cursorLegacySession != nil {
                    guard remainingFiles > 0, try admitsCaptureDisk(recording: &result.diskAdmission) else {
                        result.deferred += 1
                        continue
                    }
                    remainingFiles -= 1
                    do {
                        let capture = try performCursorLegacyReservedCapture(
                            reservation, root: root, maximumByteCount: remainingBytes
                        )
                        remainingBytes -= capture.capture.rawByteCount
                        result.captured += 1
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error as ExactSourceCapturerError {
                        if error == .generationChanged {
                            _ = try owner.abandonCapture(reservation)
                        }
                        result.deferred += 1
                    } catch let error as CollectorCursorLegacySource.LegacyError {
                        switch error {
                        case .exceededBudget:
                            break
                        case .unavailable, .sourceChanged, .invalidComposer, .ambiguousScope, .unsupportedSchema:
                            _ = try owner.abandonCapture(reservation)
                        }
                        result.deferred += 1
                    } catch is CollectorPOSIXEnumerationError {
                        _ = try owner.abandonCapture(reservation)
                        result.deferred += 1
                    } catch let error as POSIXError where error.code == .ENOENT {
                        _ = try owner.abandonCapture(reservation)
                        result.deferred += 1
                    } catch let error as CollectorPublicationWorkerError where error == .invalidCapture {
                        _ = try owner.abandonCapture(reservation)
                        result.deferred += 1
                    }
                    continue
                }
                if reservation.sqliteSession != nil {
                    guard remainingFiles > 0, try admitsCaptureDisk(recording: &result.diskAdmission) else {
                        result.deferred += 1
                        continue
                    }
                    remainingFiles -= 1
                    do {
                        guard try currentMatchesReservation(reservation, root: root) else {
                            _ = try owner.abandonCapture(reservation)
                            result.deferred += 1
                            continue
                        }
                        let capture = try performOpenCodeReservedCapture(
                            reservation, root: root, maximumByteCount: remainingBytes
                        )
                        remainingBytes -= capture.capture.rawByteCount
                        result.captured += 1
                    } catch is CancellationError { throw CancellationError() }
                    catch let error as ExactSourceCapturerError {
                        if error == .generationChanged { _ = try owner.abandonCapture(reservation) }
                        result.deferred += 1
                    } catch let error as CollectorOpenCodeSourceError {
                        if error == .unavailable || error == .sourceChanged {
                            _ = try owner.abandonCapture(reservation)
                        }
                        result.deferred += 1
                    }
                    continue
                }
                let reservedBytes = try reservation.snapshot?.presentByteCount() ?? reservation.generation.size
                guard remainingFiles > 0, reservedBytes <= remainingBytes,
                      try admitsCaptureDisk(recording: &result.diskAdmission) else {
                    result.deferred += 1
                    continue
                }
                remainingFiles -= 1
                do {
                    let matches: Bool
                    do {
                        matches = try currentMatchesReservation(reservation, root: root)
                    } catch let error as CollectorPublicationWorkerError
                        where (root.source == .kimi || root.source == .cursor || root.source == .cline || root.source == .vscode) && error == .invalidCapture {
                        // Recovery proved this reservation has no durable capture.
                        // An unavailable Cursor primary or Kimi primary/registry must not block the
                        // stream; abandoning retains its unacknowledged dirty work.
                        matches = false
                    }
                    guard matches else {
                        _ = try owner.abandonCapture(reservation)
                        result.deferred += 1
                        continue
                    }
                    let capture = try performCapture(reservation, root: root, maximumByteCount: remainingBytes)
                    remainingBytes -= root.source == .vscode ? reservedBytes : capture.capture.rawByteCount
                    result.captured += 1
                } catch is CancellationError { throw CancellationError() }
                catch let error as ExactSourceCapturerError {
                    if error == .generationChanged { _ = try owner.abandonCapture(reservation) }
                    result.deferred += 1
                } catch let error as CollectorPOSIXEnumerationError {
                    // A missing intermediate directory is the same proven
                    // uncaptured absence as a missing final file. Unsafe
                    // identities and other enumeration failures stay fenced.
                    if case .io(.openComponent, let code) = error, code == ENOENT {
                        _ = try owner.abandonCapture(reservation)
                    }
                    result.deferred += 1
                }
                catch let error as POSIXError {
                    // Recovery proved no durable generation exists. A missing
                    // source must not reserve the entire stream indefinitely.
                    if error.code == .ENOENT { _ = try owner.abandonCapture(reservation) }
                    result.deferred += 1
                }
            }
        }
        // After reconcilers and reservation recovery: a same-tick registry
        // dirty is visible here. Do not accept a caller-supplied pending set.
        var pendingDirtyRootIDs: Set<Data>?
        if remainingFiles > 0 {
            let candidates = roots.filter { root in
                allowsLiveCapture(root, captureRootIDs)
                    && !reservations.contains(where: {
                        $0.rootID.utf8.elementsEqual(root.rootID.utf8) && $0.rootRevision == root.revision
                    })
            }
            if !candidates.isEmpty {
                pendingDirtyRootIDs = try owner.rootsWithUnacknowledgedDirty(candidates)
            }
        }
        // Rotate the first eligible source between bounded cycles so a busy
        // root cannot consume every cycle's shared file budget indefinitely.
        let rootStart = captureRootStart
        if remainingFiles > 0 { captureRootStart = (captureRootStart + 1) % roots.count }
        for offset in roots.indices {
            let root = roots[(rootStart + offset) % roots.count]
            guard remainingFiles > 0 else { break }
            guard allowsLiveCapture(root, captureRootIDs) else { continue }
            // Do not capture a newer generation in a stream reconciled during
            // this same bounded pass, even if the old reservation just finished.
            if reservations.contains(where: { $0.rootID.utf8.elementsEqual(root.rootID.utf8) && $0.rootRevision == root.revision }) { continue }
            if let pendingDirtyRootIDs, !pendingDirtyRootIDs.contains(Data(root.rootID.utf8)) { continue }
            let claimLimit = root.source == .opencode || root.cursorLegacy ? min(1, remainingFiles) : remainingFiles
            let claims: [CollectorDirtyClaim]
            do {
                claims = try owner.claimDirty(configuration: root, limit: claimLimit, now: now)
            } catch CollectorPOSIXEnumerationError.io(.openComponent, ENOENT) {
                // An unavailable source must not prevent durable publications
                // from reaching replicas later in this cycle. Never ACK it.
                result.deferred += 1
                continue
            } catch CollectorPOSIXEnumerationError.rootIdentityChanged {
                result.deferred += 1
                continue
            }
            var handled = Set<String>()
            for claim in claims {
                try await cooperateBetweenIndependentUnits()
                try Task.checkCancellation()
                if root.source == .opencode {
                    if claim.relativePath == "opencode.db" {
                        try captureOpenCodeWalk(
                            claim, root: root, now: now, remainingFiles: &remainingFiles,
                            remainingBytes: &remainingBytes, result: &result
                        )
                    } else {
                        try deferDirty(claim, root: root, now: now)
                        result.deferred += 1
                    }
                    continue
                }
                if root.cursorLegacy {
                    if claim.relativePath == "state.vscdb" {
                        try captureCursorLegacyWalk(claim, root: root, now: now, remainingFiles: &remainingFiles,
                            remainingBytes: &remainingBytes, remainingComparisonBytes: &remainingComparisonBytes, result: &result)
                    } else {
                        try deferDirty(claim, root: root, now: now)
                        result.deferred += 1
                    }
                    continue
                }
                remainingFiles -= 1
                if root.source == .cursor {
                    let id = CollectorCursorSource.sessionOwning(claim.relativePath)
                    let key = id.map { Data($0.utf8).base64EncodedString() }
                    if let key, handled.contains(key) { continue }
                    if let key { handled.insert(key) }
                    let group = id.map { id in
                        claims.filter { CollectorCursorSource.sessionOwning($0.relativePath)?.utf8.elementsEqual(id.utf8) == true }
                    } ?? [claim]
                    try captureCursorGroup(group, root: root, now: now, remainingBytes: &remainingBytes, result: &result)
                    continue
                }
                if root.source == .vscode {
                    try captureVSCodePrimary(claim, root: root, now: now, remainingBytes: &remainingBytes,
                        result: &result)
                    continue
                }
                if root.source == .cline {
                    let task = claim.relativePath.split(separator: "/", omittingEmptySubsequences: false).first.map(String.init)
                    let key = task.map { Data($0.utf8).base64EncodedString() }
                    if let key, handled.contains(key) { continue }
                    if let key { handled.insert(key) }
                    let group = task.map { task in
                        claims.filter { $0.relativePath.split(separator: "/", omittingEmptySubsequences: false)
                            .first?.utf8.elementsEqual(task.utf8) == true }
                    } ?? [claim]
                    try captureClineGroup(group, root: root, now: now, remainingBytes: &remainingBytes, result: &result)
                    continue
                }
                if root.source == .copilot {
                    let session = CollectorCopilotSource.sessionOwning(claim.relativePath)
                    if let session, handled.contains(session) { continue }
                    if let session { handled.insert(session) }
                    let group = session.map { name in
                        claims.filter { CollectorCopilotSource.sessionOwning($0.relativePath) == name }
                    } ?? [claim]
                    try captureCopilotGroup(
                        group, root: root, now: now,
                        remainingBytes: &remainingBytes, result: &result
                    )
                    continue
                }
                if root.source == .geminiCli {
                    let session = CollectorGeminiSource.sessionOwning(claim.relativePath)
                    if let session, handled.contains(session) { continue }
                    if let session { handled.insert(session) }
                    let group = session.map { name in
                        claims.filter { CollectorGeminiSource.sessionOwning($0.relativePath) == name }
                    } ?? [claim]
                    try captureGeminiGroup(
                        group, root: root, now: now,
                        remainingBytes: &remainingBytes, result: &result
                    )
                    continue
                }
                if root.source == .kimi {
                    let session = CollectorKimiSource.sessionOwning(claim.relativePath)
                    if let session, handled.contains(session) { continue }
                    if let session { handled.insert(session) }
                    let group = session.map { name in
                        claims.filter { CollectorKimiSource.sessionOwning($0.relativePath) == name }
                    } ?? [claim]
                    try captureKimiGroup(
                        group, root: root, now: now,
                        remainingBytes: &remainingBytes, result: &result
                    )
                    continue
                }
                if root.source == .grok {
                    let session = CollectorGrokSource.sessionOwning(claim.relativePath)
                    if let session, handled.contains(session) { continue }
                    if let session { handled.insert(session) }
                    let group = session.map { name in
                        claims.filter { CollectorGrokSource.sessionOwning($0.relativePath) == name }
                    } ?? [claim]
                    try captureGrokGroup(
                        group, root: root, now: now,
                        remainingBytes: &remainingBytes, result: &result
                    )
                    continue
                }
                let generation: ArchiveSourceGeneration
                do {
                    generation = try Self.sourceGeneration(root: root, relativePath: claim.relativePath)
                }
                catch is CancellationError { throw CancellationError() }
                catch {
                    try deferDirty(claim, root: root, now: now, sourceUnavailable: true)
                    result.deferred += 1
                    continue
                }
                guard generation.size > 0, generation.size <= remainingBytes,
                      try admitsCaptureDisk(recording: &result.diskAdmission) else {
                    try deferDirty(claim, root: root, now: now)
                    result.deferred += 1
                    continue
                }
                var effectiveSource = root.source
                if root.source == .claudeCode,
                   (formats[root.rootID] ?? Self.defaultFormat(root.source)) == .claudeCode(forceClaudeCodeSource: false) {
                    do {
                        let observed = try Self.sourceGeneration(root: root, relativePath: claim.relativePath) { descriptor, observedGeneration in
                            effectiveSource = try Self.claudeSourceHint(descriptor: descriptor,
                                locator: root.rootPath + "/" + claim.relativePath, sourceByteCount: observedGeneration.size,
                                remainingBytes: &remainingHintBytes)
                        }
                        guard observed == generation else { throw ExactSourceCapturerError.generationChanged }
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        try deferDirty(claim, root: root, now: now)
                        result.deferred += 1
                        continue
                    }
                }
                guard let reservation = try owner.reserveCapture(
                    claim, configuration: root, generation: generation, snapshot: nil, effectiveSource: effectiveSource
                ) else {
                    try deferDirty(claim, root: root, now: now)
                    result.deferred += 1
                    continue
                }
                do {
                    let capture = try performCapture(reservation, root: root, maximumByteCount: remainingBytes)
                    remainingBytes -= capture.capture.rawByteCount
                    result.captured += 1
                } catch is CancellationError { throw CancellationError() }
                catch let error as ExactSourceCapturerError {
                    if error == .generationChanged { _ = try owner.abandonCapture(reservation) }
                    result.deferred += 1
                }
            }
            try drainUnavailableDeferrals()
        }
        let freshPolicy: CollectorPrivacyPolicy?
        do { freshPolicy = try policy() }
        catch is CancellationError { throw CancellationError() }
        catch { freshPolicy = nil } // Transmit retains its existing fail-closed policy assessment.
        if let freshPolicy {
            try owner.reconcilePublicationPrivacy(policySHA256: freshPolicy.sha256())
        }
        result.sourceHintBytesRead = budget.maxCaptureBytes - remainingHintBytes
        return result
    }

    func uploadOnce(replicaID: String, now: Int64) async throws -> (acknowledged: Int, deferred: Int) {
        try Task.checkCancellation()
        guard let replica = replicas.first(where: { $0.replicaID == replicaID }) else {
            throw CollectorPublicationWorkerError.invalidConfiguration
        }
        guard uploading.insert(replica.replicaID).inserted else { return (0, 0) }
        defer { uploading.remove(replica.replicaID) }
        return try await upload(to: replica, now: now)
    }

    private func admitsCaptureDisk(recording status: inout CollectorDiskAdmissionStatus) throws -> Bool {
        var inventoryMinimum: Int64?
        var captureMinimum: Int64?
        if case .observed(_, let inventory, let capture) = status {
            inventoryMinimum = inventory
            captureMinimum = capture
        }
        let inventory = try owner.availableSpoolBytes()
        inventoryMinimum = min(inventoryMinimum ?? inventory, inventory)
        status = .observed(minimumFreeDiskBytes: budget.minimumFreeDiskBytes,
            inventoryMinimumAvailableBytes: inventoryMinimum, captureMinimumAvailableBytes: captureMinimum)
        guard inventory >= budget.minimumFreeDiskBytes else { return false }
        let capture = try cas.availableVolumeBytes()
        captureMinimum = min(captureMinimum ?? capture, capture)
        status = .observed(minimumFreeDiskBytes: budget.minimumFreeDiskBytes,
            inventoryMinimumAvailableBytes: inventoryMinimum, captureMinimumAvailableBytes: captureMinimum)
        return capture >= budget.minimumFreeDiskBytes
    }

    private func configuration(rootID: String, revision: Int64) -> CollectorRootConfiguration? {
        roots.first { $0.rootID.utf8.elementsEqual(rootID.utf8) && $0.revision == revision }
    }

    private func allowsLiveCapture(_ root: CollectorRootConfiguration, _ captureRootIDs: Set<Data>?) -> Bool {
        captureRootIDs.map { $0.contains(Data(root.rootID.utf8)) } ?? true
    }

    private func reconcileCursorLegacyObservations(now: Int64, captureRootIDs: Set<Data>?) throws {
        let legacyRoots = roots.filter { $0.source == .cursor && $0.cursorLegacy && allowsLiveCapture($0, captureRootIDs) }
        guard !legacyRoots.isEmpty, budget.maxCaptureFiles > 0 else { return }
        // Bound repeated workspace scans while allowing clock rollback to observe immediately.
        if let previous = cursorLegacyObservationTime, now >= previous, now - previous < 10 { return }
        cursorLegacyObservationTime = now
        let root = legacyRoots[cursorLegacyObservationRoot % legacyRoots.count]
        cursorLegacyObservationRoot = (cursorLegacyObservationRoot + 1) % legacyRoots.count
        let after = try owner.cursorLegacyOwnershipAfter(configuration: root)
        let page: CollectorCursorLegacyOwnership.OwnershipObservationPage
        let mainFingerprint: String
        do {
            page = try CollectorCursorLegacyOwnership.ownershipObservationPage(
                globalStorageRoot: URL(fileURLWithPath: root.rootPath), after: after,
                limit: min(64, budget.maxCaptureFiles))
            let observed = try CollectorSQLiteSnapshotLease.observe(
                root: URL(fileURLWithPath: root.rootPath), databaseName: "state.vscdb")
            mainFingerprint = ArchiveV2Hash.sha256(try ArchiveCanonicalJSON.encode(
                [observed.databaseGeneration, observed.walGeneration]))
        } catch is CancellationError { throw CancellationError() }
        catch CollectorPublicationWorkerError.invalidConfiguration {
            throw CollectorPublicationWorkerError.invalidConfiguration
        } catch {
            // Source observation failures are hints, never permission to ACK.
            // Coalesce repeated failures; recovery forces a fresh ownership walk.
            try owner.recordCursorLegacyObservationFailure(configuration: root,
                fingerprint: ArchiveV2Hash.sha256(Data(String(reflecting: type(of: error)).utf8)))
            return
        }
        let peerFingerprint: String
        if let peerID = root.cursorModernRootID {
            guard let peer = roots.first(where: { $0.rootID.utf8.elementsEqual(peerID.utf8) }),
                  peer.source == .cursor, !peer.cursorLegacy else {
                throw CollectorPublicationWorkerError.invalidConfiguration
            }
            try testHooks.beforePeerRootState?()
            // Inventory rootState is not a source-observation failure.
            let state = try owner.rootState(rootID: peer.rootID)
            if let state, let cached = cachedPeerFingerprintHint(peer: peer, state: state, now: now) {
                peerFingerprint = cached
            } else {
                peerFingerprintHints.removeValue(forKey: Data(peer.rootID.utf8))
                do {
                    try testHooks.beforeDiscoverModern?(peer.rootPath, .observationHint)
                    let peerIDs = Array(Set(try CollectorCursorSource.discoverModern(rootPath: peer.rootPath)
                        .map { Data($0.nativeSessionID.utf8) })).sorted { $0.lexicographicallyPrecedes($1) }
                    peerFingerprint = ArchiveV2Hash.sha256(try ArchiveCanonicalJSON.encode(peerIDs))
                    if let state, state.configuration == peer {
                        storePeerFingerprintHint(peer: peer, state: state, now: now, fingerprint: peerFingerprint)
                    }
                } catch is CancellationError { throw CancellationError() }
                catch CollectorPublicationWorkerError.invalidConfiguration {
                    throw CollectorPublicationWorkerError.invalidConfiguration
                } catch {
                    try owner.recordCursorLegacyObservationFailure(configuration: root,
                        fingerprint: ArchiveV2Hash.sha256(Data(String(reflecting: type(of: error)).utf8)))
                    return
                }
            }
        } else {
            peerFingerprint = ArchiveV2Hash.sha256(try ArchiveCanonicalJSON.encode([Data]()))
        }
        // Keep inventory failures outside the source-error boundary.
        try owner.applyCursorLegacyObservation(configuration: root, after: after,
            membershipFingerprint: ArchiveV2Hash.sha256(Data(page.membershipFingerprint.utf8)),
            workspaces: page.workspaces.map { ($0.workspaceID, ArchiveV2Hash.sha256(Data($0.fingerprint.utf8))) },
            nextAfter: page.nextAfter, mainFingerprint: mainFingerprint, peerFingerprint: peerFingerprint)
    }

    private func cachedPeerFingerprintHint(
        peer: CollectorRootConfiguration, state: CollectorRootState, now: Int64
    ) -> String? {
        guard state.configuration == peer,
              let cached = peerFingerprintHints[Data(peer.rootID.utf8)],
              cached.configuration == state.configuration,
              now >= cached.observedAt, now - cached.observedAt < 30,
              cached.requestedRevision == state.requestedRevision,
              cached.completedRevision == state.completedRevision,
              cached.eventCheckpoint == state.eventCheckpoint else { return nil }
        return cached.fingerprint
    }

    private func storePeerFingerprintHint(
        peer: CollectorRootConfiguration, state: CollectorRootState, now: Int64, fingerprint: String
    ) {
        guard state.configuration == peer else { return }
        let allowed = Set(roots.compactMap { $0.cursorModernRootID.map { Data($0.utf8) } })
        peerFingerprintHints = peerFingerprintHints.filter { allowed.contains($0.key) }
        peerFingerprintHints[Data(peer.rootID.utf8)] = PeerFingerprintHint(
            configuration: state.configuration, fingerprint: fingerprint, observedAt: now,
            eventCheckpoint: state.eventCheckpoint,
            requestedRevision: state.requestedRevision, completedRevision: state.completedRevision)
    }

    private func reconcileCapturedDependencies(now: Int64, captureRootIDs: Set<Data>?) throws {
        let observedRoots = roots.filter { ($0.source == .vscode || ($0.source == .cursor && !$0.cursorLegacy)) && allowsLiveCapture($0, captureRootIDs) }
        guard !observedRoots.isEmpty, budget.maxCaptureFiles > 0 else { return }
        if let previous = dependencyObservationTime, now >= previous, now - previous < 1 { return }
        dependencyObservationTime = now
        let root = observedRoots[dependencyObservationRoot % observedRoots.count]
        dependencyObservationRoot = (dependencyObservationRoot + 1) % observedRoots.count
        let key = Data(root.rootID.utf8)
        let page = try owner.capturedDependencyObservationPage(configuration: root,
            after: dependencyObservationAfter[key], limit: budget.maxCaptureFiles)
        dependencyObservationAfter[key] = page.count == budget.maxCaptureFiles ? page.last?.relativePath : nil
        // The cursor is a process-local scheduling hint. Restarted workers
        // recheck from the beginning; only normal capture can ACK dirty work.
        for locator in page where locator.dirtyRevision == locator.acknowledgedRevision {
            try Task.checkCancellation()
            guard let id = locator.lastCaptureID, let capture = try catalog.capture(captureID: id),
                  capture.source == root.source.rawValue,
                  capture.locator.utf8.elementsEqual((root.rootPath + "/" + locator.relativePath).utf8) else { continue }
            guard capture.unboundManifestBytes.count <= ArchiveV2ProtocolLimits.maxManifestBytes,
                  ArchiveV2Hash.sha256(capture.unboundManifestBytes) == capture.unboundManifestSHA256 else {
                throw CollectorPublicationWorkerError.invalidCapture
            }
            let manifest = try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: capture.unboundManifestBytes)
            let changed = try root.source == .vscode
                ? CollectorVSCodeSource.capturedDependenciesChanged(rootPath: root.rootPath, manifest: manifest)
                : CollectorCursorSource.capturedDependenciesChanged(rootPath: root.rootPath, manifest: manifest)
            if changed {
                try owner.dirtyCapturedDependencyObservation(configuration: root, locator: locator)
            }
        }
    }

    private func captureCursorGroup(
        _ group: [CollectorDirtyClaim], root: CollectorRootConfiguration, now: Int64,
        remainingBytes: inout Int64, result: inout CollectorPublicationCycle
    ) throws {
        func deferAll() throws {
            for claim in group { try deferDirty(claim, root: root, now: now); result.deferred += 1 }
        }
        guard let probe = group.first else { return }
        let observed: CollectorCursorSource.SessionObservation
        do {
            let before = try CollectorCursorSource.observe(rootPath: root.rootPath, primaryRelative: probe.relativePath)
            observed = try CollectorCursorSource.observe(rootPath: root.rootPath,
                primaryRelative: before.snapshot.entrypointRelativePath)
            guard before.snapshot == observed.snapshot,
                  CollectorCursorSource.reservedPathsEqual(before.snapshot, observed.snapshot),
                  before.generation == observed.generation else { try deferAll(); return }
        } catch is CancellationError { throw CancellationError() }
        catch { try deferAll(); return }
        let size = try observed.snapshot.presentByteCount()
        guard size > 0, size <= remainingBytes, try admitsCaptureDisk(recording: &result.diskAdmission) else {
            try deferAll(); return
        }
        let primary = observed.snapshot.entrypointRelativePath
        let winner: CollectorDirtyClaim?
        if let exact = group.first(where: { $0.relativePath.utf8.elementsEqual(primary.utf8) }) { winner = exact }
        else { winner = try owner.claimFileSetPrimary(probe, configuration: root, snapshot: observed.snapshot) }
        guard let winner else { try deferAll(); return }
        guard let reservation = try owner.reserveCapture(winner, configuration: root,
            generation: observed.generation, snapshot: observed.snapshot) else {
            if !group.contains(winner) { try deferDirty(winner, root: root, now: now) }
            try deferAll(); return
        }
        do {
            let capture = try performCapture(reservation, root: root, maximumByteCount: remainingBytes)
            remainingBytes -= capture.capture.rawByteCount
            result.captured += 1
            for alias in group where !alias.relativePath.utf8.elementsEqual(winner.relativePath.utf8) {
                _ = try owner.acknowledge(alias, configuration: root, captureID: capture.capture.captureID)
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as ExactSourceCapturerError {
            if error == .generationChanged { _ = try owner.abandonCapture(reservation) }
            if !group.contains(winner) { try deferDirty(winner, root: root, now: now) }
            try deferAll()
        }
    }

    private func captureVSCodePrimary(
        _ claim: CollectorDirtyClaim, root: CollectorRootConfiguration, now: Int64,
        remainingBytes: inout Int64, result: inout CollectorPublicationCycle
    ) throws {
        func deferOne() throws {
            try deferDirty(claim, root: root, now: now)
            result.deferred += 1
        }
        let observed: (generation: ArchiveSourceGeneration, snapshot: CollectorDependencySnapshot)
        do {
            observed = try CollectorVSCodeSource.observe(rootPath: root.rootPath,
                primaryRelative: claim.relativePath, maximumByteCount: remainingBytes)
        } catch is CancellationError { throw CancellationError() }
        catch { try deferOne(); return }
        let bytes = try observed.snapshot.presentByteCount()
        guard bytes > 0, bytes <= remainingBytes, try admitsCaptureDisk(recording: &result.diskAdmission),
              let reservation = try owner.reserveCapture(claim, configuration: root,
                generation: observed.generation, snapshot: observed.snapshot, allowExisting: false) else {
            try deferOne(); return
        }
        // Only fresh reservations reach here; earlier reservations recover at the start of the cycle.
        do {
            _ = try performCapture(reservation, root: root, maximumByteCount: remainingBytes)
            remainingBytes -= bytes
            result.captured += 1
        } catch is CancellationError { throw CancellationError() }
        catch let error as ExactSourceCapturerError {
            if error == .generationChanged { _ = try owner.abandonCapture(reservation) }
            try deferOne()
        } catch let error as POSIXError where error.code == .ENOENT {
            try deferOne()
        } catch let error as CollectorPOSIXEnumerationError {
            guard case .io(.openComponent, let code) = error, code == ENOENT else { throw error }
            try deferOne()
        } catch let error as CollectorPublicationWorkerError where error == .invalidCapture {
            _ = try owner.abandonCapture(reservation)
            try deferOne()
        }
    }

    private func captureClineGroup(
        _ group: [CollectorDirtyClaim], root: CollectorRootConfiguration, now: Int64,
        remainingBytes: inout Int64, result: inout CollectorPublicationCycle
    ) throws {
        var claimed = group
        func deferAll() throws {
            for claim in claimed { try deferDirty(claim, root: root, now: now); result.deferred += 1 }
        }
        guard let probe = group.first else { return }
        let observed: (generation: ArchiveSourceGeneration, snapshot: CollectorDependencySnapshot)
        do {
            guard let primary = try CollectorClineSource.owningPrimary(rootPath: root.rootPath, dirtyRelative: probe.relativePath) else {
                try deferAll(); return
            }
            observed = try CollectorClineSource.observe(rootPath: root.rootPath, primaryRelative: primary)
        } catch is CancellationError { throw CancellationError() }
        catch { try deferAll(); return }
        let size = try observed.snapshot.presentByteCount()
        guard size > 0, size <= remainingBytes, try admitsCaptureDisk(recording: &result.diskAdmission) else {
            try deferAll(); return
        }
        let primary = observed.snapshot.entrypointRelativePath
        let winner: CollectorDirtyClaim?
        if let exact = group.first(where: { $0.relativePath.utf8.elementsEqual(primary.utf8) }) { winner = exact }
        else { winner = try owner.claimFileSetPrimary(probe, configuration: root, snapshot: observed.snapshot) }
        guard let winner else { try deferAll(); return }
        if let alias = try owner.claimClinePendingAlias(winner, configuration: root) { claimed.append(alias) }
        guard let reservation = try owner.reserveCapture(winner, configuration: root,
            generation: observed.generation, snapshot: observed.snapshot) else {
            if !group.contains(winner) { try deferDirty(winner, root: root, now: now) }
            try deferAll(); return
        }
        do {
            let capture = try performCapture(reservation, root: root, maximumByteCount: remainingBytes)
            remainingBytes -= capture.capture.rawByteCount
            result.captured += 1
            // A dependency event is resolved only by an actual durable selected capture.
            for alias in claimed where !alias.relativePath.utf8.elementsEqual(winner.relativePath.utf8) {
                _ = try owner.acknowledge(alias, configuration: root, captureID: capture.capture.captureID)
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as ExactSourceCapturerError {
            if error == .generationChanged { _ = try owner.abandonCapture(reservation) }
            if !group.contains(winner) { try deferDirty(winner, root: root, now: now) }
            try deferAll()
        } catch let error as POSIXError where error.code == .ENOENT {
            // Retain the reservation: the next recovery pass first checks for
            // durable CAS before deciding that missing live input is uncaptured.
            if !group.contains(winner) { try deferDirty(winner, root: root, now: now) }
            try deferAll()
        } catch let error as CollectorPOSIXEnumerationError {
            guard case .io(.openComponent, let code) = error, code == ENOENT else { throw error }
            if !group.contains(winner) { try deferDirty(winner, root: root, now: now) }
            try deferAll()
        } catch let error as CollectorPublicationWorkerError where error == .invalidCapture {
            _ = try owner.abandonCapture(reservation)
            if !group.contains(winner) { try deferDirty(winner, root: root, now: now) }
            try deferAll()
        }
    }

    private func captureCopilotGroup(
        _ group: [CollectorDirtyClaim], root: CollectorRootConfiguration, now: Int64,
        remainingBytes: inout Int64, result: inout CollectorPublicationCycle
    ) throws {
        func deferAll(sourceUnavailable: Bool = false) throws {
            for claim in group {
                try deferDirty(claim, root: root, now: now, sourceUnavailable: sourceUnavailable)
                result.deferred += 1
            }
        }
        let probe = group.first { CollectorCopilotSource.sessionName(fromPrimary: $0.relativePath) != nil }
            ?? group.first
        guard let probe else { try deferAll(); return }
        let before: (generation: ArchiveSourceGeneration, snapshot: CollectorDependencySnapshot)
        let after: (generation: ArchiveSourceGeneration, snapshot: CollectorDependencySnapshot)
        let chosen: String
        do {
            before = try CollectorCopilotSource.observe(
                rootPath: root.rootPath, primaryRelative: probe.relativePath
            )
            guard let preferred = try CollectorCopilotSource.preferredEntrypoint(
                rootPath: root.rootPath, snapshot: before.snapshot, maximumByteCount: budget.maxCaptureBytes
            ) else { try deferAll(sourceUnavailable: true); return }
            chosen = preferred
            after = try CollectorCopilotSource.observe(rootPath: root.rootPath, primaryRelative: chosen)
            guard CollectorCopilotSource.membershipEquals(before.snapshot, after.snapshot),
                  after.snapshot.entrypointRelativePath.utf8.elementsEqual(chosen.utf8),
                  after.generation == before.snapshot.present.first(where: {
                      $0.relativePath.utf8.elementsEqual(chosen.utf8)
                  })?.generation else {
                try deferAll()
                return
            }
        } catch is CancellationError { throw CancellationError() }
        catch {
            try deferAll(sourceUnavailable: true)
            return
        }
        let reservedBytes: Int64
        do { reservedBytes = try after.snapshot.presentByteCount() }
        catch {
            try deferAll()
            return
        }
        guard reservedBytes > 0, reservedBytes <= remainingBytes,
              try admitsCaptureDisk(recording: &result.diskAdmission) else {
            try deferAll()
            return
        }
        let winner: CollectorDirtyClaim?
        if let exact = group.first(where: { $0.relativePath.utf8.elementsEqual(chosen.utf8) }) { winner = exact }
        else { winner = try owner.claimFileSetPrimary(probe, configuration: root, snapshot: after.snapshot) }
        guard let winner else { try deferAll(); return }
        guard let reservation = try owner.reserveCapture(
            winner, configuration: root, generation: after.generation, snapshot: after.snapshot
        ) else {
            if !group.contains(winner) { try deferDirty(winner, root: root, now: now) }
            try deferAll()
            return
        }
        do {
            let capture = try performCapture(reservation, root: root, maximumByteCount: remainingBytes)
            remainingBytes -= capture.capture.rawByteCount
            result.captured += 1
            for alias in group where !alias.relativePath.utf8.elementsEqual(winner.relativePath.utf8) {
                _ = try owner.acknowledge(alias, configuration: root, captureID: capture.capture.captureID)
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as ExactSourceCapturerError {
            if error == .generationChanged { _ = try owner.abandonCapture(reservation) }
            if !group.contains(winner) { try deferDirty(winner, root: root, now: now) }
            try deferAll()
        }
    }

    private func captureGeminiGroup(
        _ group: [CollectorDirtyClaim], root: CollectorRootConfiguration, now: Int64,
        remainingBytes: inout Int64, result: inout CollectorPublicationCycle
    ) throws {
        func deferAll() throws {
            for claim in group {
                try deferDirty(claim, root: root, now: now)
                result.deferred += 1
            }
        }
        let probe = group.first { CollectorGeminiSource.sessionOwning($0.relativePath) != nil }
            ?? group.first
        guard let probe else { try deferAll(); return }
        let before: (generation: ArchiveSourceGeneration, snapshot: CollectorDependencySnapshot)
        let after: (generation: ArchiveSourceGeneration, snapshot: CollectorDependencySnapshot)
        let chosen: String
        let registry = projectRegistryPaths.first { $0.key.utf8.elementsEqual(root.rootID.utf8) }?.value
        do {
            before = try CollectorGeminiSource.observe(
                rootPath: root.rootPath, primaryRelative: probe.relativePath,
                registryLocator: registry, maximumByteCount: budget.maxCaptureBytes
            )
            chosen = before.snapshot.entrypointRelativePath
            after = try CollectorGeminiSource.observe(
                rootPath: root.rootPath, primaryRelative: chosen,
                registryLocator: registry, maximumByteCount: budget.maxCaptureBytes
            )
            guard CollectorGeminiSource.provenanceEquals(before.snapshot, after.snapshot),
                  after.generation == before.generation,
                  after.generation == after.snapshot.present.first(where: {
                      $0.relativePath.utf8.elementsEqual(chosen.utf8)
                  })?.generation else {
                try deferAll()
                return
            }
        } catch is CancellationError { throw CancellationError() }
        catch {
            try deferAll()
            return
        }
        let reservedBytes: Int64
        do { reservedBytes = try after.snapshot.presentByteCount() }
        catch {
            try deferAll()
            return
        }
        guard reservedBytes > 0, reservedBytes <= remainingBytes,
              try admitsCaptureDisk(recording: &result.diskAdmission) else {
            try deferAll()
            return
        }
        guard let winner = group.first(where: { $0.relativePath.utf8.elementsEqual(chosen.utf8) }) else {
            try deferAll()
            return
        }
        for loser in group where !loser.relativePath.utf8.elementsEqual(chosen.utf8) {
            try deferDirty(loser, root: root, now: now)
            result.deferred += 1
        }
        guard let reservation = try owner.reserveCapture(
            winner, configuration: root, generation: after.generation, snapshot: after.snapshot
        ) else {
            try deferDirty(winner, root: root, now: now)
            result.deferred += 1
            return
        }
        do {
            let capture = try performCapture(reservation, root: root, maximumByteCount: remainingBytes)
            remainingBytes -= capture.capture.rawByteCount
            result.captured += 1
        } catch is CancellationError { throw CancellationError() }
        catch let error as ExactSourceCapturerError {
            if error == .generationChanged { _ = try owner.abandonCapture(reservation) }
            result.deferred += 1
        }
    }

    private func captureKimiGroup(
        _ group: [CollectorDirtyClaim], root: CollectorRootConfiguration, now: Int64,
        remainingBytes: inout Int64, result: inout CollectorPublicationCycle
    ) throws {
        func deferAll(sourceUnavailable: Bool = false) throws {
            for claim in group {
                try deferDirty(claim, root: root, now: now, sourceUnavailable: sourceUnavailable)
                result.deferred += 1
            }
        }
        guard let registry = configuredRegistryLocator(root), let probe = group.first,
              let primary = CollectorKimiSource.sessionOwning(probe.relativePath) else {
            try deferAll()
            return
        }
        let before: CollectorKimiSource.Observation
        let after: CollectorKimiSource.Observation
        do {
            before = try CollectorKimiSource.observe(
                rootPath: root.rootPath, primaryRelative: primary, registryLocator: registry
            )
            after = try CollectorKimiSource.observe(
                rootPath: root.rootPath, primaryRelative: before.snapshot.entrypointRelativePath,
                registryLocator: registry
            )
            guard CollectorKimiSource.provenanceEquals(before.snapshot, after.snapshot),
                  after.generation == before.generation,
                  after.generation == after.snapshot.present.first(where: {
                      $0.relativePath.utf8.elementsEqual(after.snapshot.entrypointRelativePath.utf8)
                  })?.generation else {
                try deferAll()
                return
            }
        } catch is CancellationError { throw CancellationError() }
        catch {
            try deferAll(sourceUnavailable: true)
            return
        }
        let reservedBytes: Int64
        do { reservedBytes = try after.snapshot.presentByteCount() }
        catch {
            try deferAll()
            return
        }
        guard reservedBytes > 0 else {
            try deferAll(sourceUnavailable: true)
            return
        }
        guard reservedBytes <= remainingBytes,
              try admitsCaptureDisk(recording: &result.diskAdmission) else {
            try deferAll()
            return
        }
        let chosen = after.snapshot.entrypointRelativePath
        guard let winner = group.first(where: { $0.relativePath.utf8.elementsEqual(chosen.utf8) })
                ?? group.first(where: {
                    CollectorKimiSource.sessionOwning($0.relativePath)?.utf8.elementsEqual(chosen.utf8) == true
                }) else {
            try deferAll()
            return
        }
        for loser in group where !loser.relativePath.utf8.elementsEqual(winner.relativePath.utf8) {
            try deferDirty(loser, root: root, now: now)
            result.deferred += 1
        }
        guard let reservation = try owner.reserveCapture(
            winner, configuration: root, generation: after.generation, snapshot: after.snapshot
        ) else {
            try deferDirty(winner, root: root, now: now)
            result.deferred += 1
            return
        }
        do {
            let capture = try performCapture(reservation, root: root, maximumByteCount: remainingBytes)
            remainingBytes -= capture.capture.rawByteCount
            result.captured += 1
        } catch is CancellationError { throw CancellationError() }
        catch let error as ExactSourceCapturerError {
            if error == .generationChanged { _ = try owner.abandonCapture(reservation) }
            result.deferred += 1
        }
    }

    private func captureGrokGroup(
        _ group: [CollectorDirtyClaim], root: CollectorRootConfiguration, now: Int64,
        remainingBytes: inout Int64, result: inout CollectorPublicationCycle
    ) throws {
        func deferAll() throws {
            for claim in group {
                try deferDirty(claim, root: root, now: now)
                result.deferred += 1
            }
        }
        let probe = group.first { CollectorGrokSource.sessionOwning($0.relativePath) != nil }
            ?? group.first
        guard let probe,
              let observedPrimary = CollectorGrokSource.owningPrimary(
                  rootPath: root.rootPath, dirtyRelative: probe.relativePath
              ) else {
            try deferAll()
            return
        }
        let before: (generation: ArchiveSourceGeneration, snapshot: CollectorDependencySnapshot)
        let after: (generation: ArchiveSourceGeneration, snapshot: CollectorDependencySnapshot)
        let chosen: String
        do {
            before = try CollectorGrokSource.observe(
                rootPath: root.rootPath, primaryRelative: observedPrimary
            )
            chosen = before.snapshot.entrypointRelativePath
            after = try CollectorGrokSource.observe(
                rootPath: root.rootPath, primaryRelative: chosen
            )
            guard CollectorGrokSource.provenanceEquals(before.snapshot, after.snapshot),
                  after.generation == before.generation,
                  after.generation == after.snapshot.present.first(where: {
                      $0.relativePath.utf8.elementsEqual(chosen.utf8)
                  })?.generation else {
                try deferAll()
                return
            }
        } catch is CancellationError { throw CancellationError() }
        catch {
            try deferAll()
            return
        }
        let reservedBytes: Int64
        do { reservedBytes = try after.snapshot.presentByteCount() }
        catch {
            try deferAll()
            return
        }
        guard reservedBytes > 0, reservedBytes <= remainingBytes,
              try admitsCaptureDisk(recording: &result.diskAdmission) else {
            try deferAll()
            return
        }
        guard let winner = group.first(where: { $0.relativePath.utf8.elementsEqual(chosen.utf8) }) else {
            try deferAll()
            return
        }
        for loser in group where !loser.relativePath.utf8.elementsEqual(chosen.utf8) {
            try deferDirty(loser, root: root, now: now)
            result.deferred += 1
        }
        guard let reservation = try owner.reserveCapture(
            winner, configuration: root, generation: after.generation, snapshot: after.snapshot
        ) else {
            try deferDirty(winner, root: root, now: now)
            result.deferred += 1
            return
        }
        do {
            let capture = try performCapture(reservation, root: root, maximumByteCount: remainingBytes)
            remainingBytes -= capture.capture.rawByteCount
            result.captured += 1
        } catch is CancellationError { throw CancellationError() }
        catch let error as ExactSourceCapturerError {
            if error == .generationChanged { _ = try owner.abandonCapture(reservation) }
            result.deferred += 1
        }
    }

    private func captureCursorLegacyWalk(
        _ claim: CollectorDirtyClaim, root: CollectorRootConfiguration, now: Int64,
        remainingFiles: inout Int, remainingBytes: inout Int64,
        remainingComparisonBytes: inout Int64, result: inout CollectorPublicationCycle
    ) throws {
        func deferWalk() throws {
            try deferDirty(claim, root: root, now: now)
            result.deferred += 1
        }
        guard remainingFiles > 0, try admitsCaptureDisk(recording: &result.diskAdmission) else {
            try deferWalk(); return
        }
        do {
            let modernIDs: Set<Data>
            if let peerID = root.cursorModernRootID {
                guard let peer = roots.first(where: { $0.rootID.utf8.elementsEqual(peerID.utf8) }),
                      peer.source == .cursor, !peer.cursorLegacy else {
                    throw CollectorPublicationWorkerError.invalidConfiguration
                }
                try testHooks.beforeDiscoverModern?(peer.rootPath, .captureAuthorization)
                modernIDs = Set(try CollectorCursorSource.discoverModern(rootPath: peer.rootPath)
                    .map { Data($0.nativeSessionID.utf8) })
            } else { modernIDs = [] }
            var pageBudget = CollectorCursorLegacyOwnership.Budget()
            pageBudget.rows.maximumOutputBytes = min(pageBudget.rows.maximumOutputBytes, remainingBytes)
            try CollectorCursorLegacyOwnership.withSnapshotLease(
                globalStorageRoot: URL(fileURLWithPath: root.rootPath),
                stagingParent: cas.snapshotStagingParent, budget: pageBudget
            ) { lease in
                let main = lease.databaseGeneration, wal = lease.walGeneration
                let after = try owner.reconcileCursorLegacyWalk(claim, configuration: root,
                    generation: main, walGeneration: wal)
                let limit = min(remainingFiles, 64)
                let ids = try lease.composerIDs(after: after, limit: limit)
                for id in ids {
                    try Task.checkCancellation()
                    guard remainingFiles > 0, try admitsCaptureDisk(recording: &result.diskAdmission) else {
                        try deferWalk(); return
                    }
                    let session = try lease.capture(composerID: id).archiveSession()
                    let context = try ArchiveCursorLegacyContext(session: session)
                    if modernIDs.contains(Data(id.utf8)) {
                        try owner.advanceCursorLegacySkippedSession(claim, configuration: root,
                            generation: main, session: context, previousCaptureID: nil)
                        remainingFiles -= 1
                        continue
                    }
                    if let previous = try owner.lastCursorLegacyCapture(configuration: root, composerID: id),
                       try cursorLegacyContentsUnchanged(session, previousCaptureID: previous, remainingComparisonBytes: &remainingComparisonBytes) {
                        try owner.advanceCursorLegacySkippedSession(claim, configuration: root,
                            generation: main, session: context, previousCaptureID: previous)
                        remainingFiles -= 1
                        continue
                    }
                    let bytes = try session.encodeCanonical()
                    guard Int64(bytes.count) <= remainingBytes else { try deferWalk(); return }
                    guard let reservation = try owner.reserveCapture(claim, configuration: root,
                        generation: main, cursorLegacySession: context) else { try deferWalk(); return }
                    try testHooks.beforeCapture?(reservation)
                    try testHooks.beforeCaptureFDAdmission?(reservation)
                    let capture = try ExactSourceCapturer.captureCursorLegacySession(session,
                        machineID: catalog.machineID(), cas: cas, catalog: catalog, maximumByteCount: remainingBytes)
                    try testHooks.afterCapture?(capture)
                    try Task.checkCancellation()
                    guard try owner.finishCapture(reservation, configuration: root, capture: capture.capture) != nil else {
                        throw CollectorPublicationWorkerError.staleClaim
                    }
                    remainingFiles -= 1
                    remainingBytes -= capture.capture.rawByteCount
                    result.captured += 1
                }
                if ids.count < limit {
                    _ = try owner.finishCursorLegacyWalk(claim, configuration: root, generation: main, walGeneration: wal)
                } else { try deferWalk() }
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as CollectorPublicationWorkerError where error == .staleClaim || error == .invalidConfiguration { throw error }
        catch { try deferWalk() }
    }

    private func cursorLegacyContentsUnchanged(
        _ session: ArchiveCursorLegacySession, previousCaptureID: String,
        remainingComparisonBytes: inout Int64
    ) throws -> Bool {
        guard ArchiveV2Hash.isValidSHA256(previousCaptureID),
              let previous = try catalog.capture(captureID: previousCaptureID), previous.source == SourceName.cursor.rawValue,
              previous.locator.utf8.elementsEqual(session.logicalLocator.utf8),
              previous.rawByteCount > 0,
              previous.rawByteCount <= ArchiveCursorLegacySession.maximumEncodedByteCount,
              previous.unboundManifestBytes.count <= ArchiveV2ProtocolLimits.maxManifestBytes else { return false }
        let cost = previous.rawByteCount + Int64(previous.unboundManifestBytes.count)
        // An individually oversized prior capture is only an optional dedup
        // candidate. Recapture current bounded bytes rather than starve forever.
        guard cost <= budget.maxCaptureBytes else { return false }
        // Reserve the entire comparison before any CAS allocation. Exhaustion
        // leaves this ID pending; the persisted walk resumes next cycle.
        guard cost <= remainingComparisonBytes else {
            throw CollectorCursorLegacySource.LegacyError.exceededBudget
        }
        remainingComparisonBytes -= cost
        do {
            guard try cas.readManifest(sha256: previous.unboundManifestSHA256,
                maximumByteCount: Int64(previous.unboundManifestBytes.count)) == previous.unboundManifestBytes else { return false }
            let manifest = try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: previous.unboundManifestBytes)
            guard ArchiveSourceDescriptor.isCursorLegacySession(manifest),
                  manifest.captureID == previousCaptureID, manifest.machineID == (try catalog.machineID()),
                  manifest.locator.utf8.elementsEqual(previous.locator.utf8),
                  manifest.generation == previous.generation,
                  manifest.rawByteCount == previous.rawByteCount,
                  manifest.wholeSourceSHA256 == previous.wholeSourceSHA256,
                  let context = manifest.replayLayout.cursorLegacySession,
                  try ExactSourceCapturer.cursorLegacySessionCaptureID(machineID: manifest.machineID,
                      context: context, generation: manifest.generation,
                      wholeSourceSHA256: manifest.wholeSourceSHA256) == previousCaptureID,
                  context.rawPayloadByteCount == session.rawPayloadByteCount,
                  context.nativePayloadByteCount == session.nativePayloadByteCount,
                  context.cwd.utf8.elementsEqual(session.cwd.utf8) else { return false }
            var bytes = Data()
            for chunk in manifest.chunks {
                try Task.checkCancellation()
                guard chunk.rawByteCount <= previous.rawByteCount - Int64(bytes.count) else { return false }
                let data = try cas.readObject(sha256: chunk.rawSHA256, maximumByteCount: chunk.rawByteCount)
                guard Int64(data.count) == chunk.rawByteCount else { return false }
                bytes.append(data)
            }
            guard Int64(bytes.count) == previous.rawByteCount,
                  ArchiveV2Hash.sha256(bytes) == previous.wholeSourceSHA256 else { return false }
            let prior = try ArchiveCursorLegacySession.decodeCanonical(bytes)
            guard prior.databaseGeneration == manifest.generation,
                  try ArchiveCursorLegacyContext(session: prior) == context else { return false }
            return prior.logicalDatabaseLocator.utf8.elementsEqual(session.logicalDatabaseLocator.utf8)
                && prior.composerID.utf8.elementsEqual(session.composerID.utf8)
                && prior.cwd.utf8.elementsEqual(session.cwd.utf8)
                && prior.composer == session.composer && prior.bubbles == session.bubbles
        } catch is CancellationError { throw CancellationError() }
        catch { return false }
    }

    private func captureOpenCodeWalk(
        _ claim: CollectorDirtyClaim, root: CollectorRootConfiguration, now: Int64,
        remainingFiles: inout Int, remainingBytes: inout Int64, result: inout CollectorPublicationCycle
    ) throws {
        func deferWalk() throws {
            try deferDirty(claim, root: root, now: now)
            result.deferred += 1
        }
        guard remainingFiles > 0, try admitsCaptureDisk(recording: &result.diskAdmission) else {
            try deferWalk()
            return
        }
        var leaseBudget = CollectorOpenCodeSource.Budget()
        leaseBudget.maximumByteCount = remainingBytes
        do {
            try CollectorOpenCodeSource.withSnapshotLease(
                root: URL(fileURLWithPath: root.rootPath),
                stagingParent: cas.snapshotStagingParent,
                budget: leaseBudget
            ) { lease in
                let main = lease.databaseGeneration
                let wal = lease.walGeneration
                let after = try owner.reconcileOpenCodeWalk(
                    claim, configuration: root, generation: main, walGeneration: wal
                )
                let limit = min(remainingFiles, 64)
                guard limit > 0 else {
                    try deferDirty(claim, root: root, now: now)
                    result.deferred += 1
                    return
                }
                let ids = try lease.sessionIDs(after: after, limit: limit)
                if ids.isEmpty {
                    _ = try owner.finishOpenCodeWalk(
                        claim, configuration: root, generation: main, walGeneration: wal
                    )
                    return
                }
                for id in ids {
                    try Task.checkCancellation()
                    guard remainingFiles > 0, try admitsCaptureDisk(recording: &result.diskAdmission) else {
                        try deferDirty(claim, root: root, now: now)
                        result.deferred += 1
                        return
                    }
                    let snap = try lease.snapshot(sessionID: id)
                    guard snap.image.count > 0, Int64(snap.image.count) <= remainingBytes else {
                        try deferDirty(claim, root: root, now: now)
                        result.deferred += 1
                        return
                    }
                    let context = try ArchiveSQLiteSessionContext(
                        databaseLocator: URL(fileURLWithPath: root.rootPath)
                            .appendingPathComponent("opencode.db").path,
                        nativeSessionID: snap.sessionID,
                        nativePayloadByteCount: snap.nativePayloadByteCount,
                        walGeneration: wal
                    )
                    guard let reservation = try owner.reserveCapture(
                        claim, configuration: root, generation: main, sqliteSession: context
                    ) else {
                        try deferDirty(claim, root: root, now: now)
                        result.deferred += 1
                        return
                    }
                    do {
                        try testHooks.beforeCapture?(reservation)
                        try testHooks.beforeCaptureFDAdmission?(reservation)
                        let capture = try ExactSourceCapturer.captureSQLiteSessionImage(
                            snap.image, context: context, generation: main,
                            machineID: catalog.machineID(), cas: cas, catalog: catalog,
                            maximumByteCount: remainingBytes
                        )
                        try testHooks.afterCapture?(capture)
                        try Task.checkCancellation()
                        guard try owner.finishCapture(
                            reservation, configuration: root, capture: capture.capture
                        ) != nil else {
                            throw CollectorPublicationWorkerError.staleClaim
                        }
                        remainingFiles -= 1
                        remainingBytes -= capture.capture.rawByteCount
                        result.captured += 1
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error as ExactSourceCapturerError {
                        if error == .generationChanged { _ = try owner.abandonCapture(reservation) }
                        try deferDirty(claim, root: root, now: now)
                        result.deferred += 1
                        return
                    }
                }
                if ids.count < limit {
                    _ = try owner.finishOpenCodeWalk(
                        claim, configuration: root, generation: main, walGeneration: wal
                    )
                } else {
                    try deferDirty(claim, root: root, now: now)
                    result.deferred += 1
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CollectorPublicationWorkerError where error == .staleClaim {
            throw error
        } catch {
            try deferWalk()
        }
    }

    private func performCursorLegacyReservedCapture(
        _ reservation: CollectorCaptureReservation, root: CollectorRootConfiguration, maximumByteCount: Int64
    ) throws -> ArchiveCaptureResult {
        try Task.checkCancellation()
        guard root.source == .cursor, reservation.snapshot == nil, reservation.sqliteSession == nil,
              let reserved = reservation.cursorLegacySession else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        // Retry reads only the explicitly configured root.
        let configuredRoot = URL(fileURLWithPath: root.rootPath)
        guard reservation.relativePath.utf8.elementsEqual("state.vscdb".utf8),
              reserved.databaseLocator.utf8.elementsEqual((root.rootPath + "/state.vscdb").utf8),
              reserved.databaseLocator.utf8.elementsEqual(
                configuredRoot.appendingPathComponent("state.vscdb").path.utf8
              ) else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        try testHooks.beforeCapture?(reservation)
        let owned = try CollectorCursorLegacyOwnership.capture(
            globalStorageRoot: configuredRoot, composerID: reserved.composerID,
            stagingParent: cas.snapshotStagingParent
        )
        let session = try owned.archiveSession()
        let context = try ArchiveCursorLegacyContext(session: session)
        // One live read: compare that body, then persist it. Do not recapture.
        guard context == reserved,
              session.databaseGeneration == reservation.generation,
              session.walGeneration == reserved.walGeneration else {
            throw ExactSourceCapturerError.generationChanged
        }
        let body = try session.encodeCanonical()
        guard Int64(body.count) <= maximumByteCount else {
            throw ExactSourceCapturerError.exceededMaximumByteCount(maximumByteCount)
        }
        try testHooks.beforeCaptureFDAdmission?(reservation)
        let result = try ExactSourceCapturer.captureCursorLegacySession(
            session, machineID: catalog.machineID(), cas: cas, catalog: catalog,
            maximumByteCount: maximumByteCount
        )
        guard result.capture.rawByteCount == Int64(body.count),
              result.capture.wholeSourceSHA256 == ArchiveV2Hash.sha256(body),
              result.manifest.replayLayout.cursorLegacySession == reserved,
              result.capture.generation == reservation.generation else {
            throw ExactSourceCapturerError.generationChanged
        }
        try testHooks.afterCapture?(result)
        try Task.checkCancellation()
        guard try owner.finishCapture(reservation, configuration: root, capture: result.capture) != nil else {
            throw CollectorPublicationWorkerError.staleClaim
        }
        return result
    }

    private func performOpenCodeReservedCapture(
        _ reservation: CollectorCaptureReservation, root: CollectorRootConfiguration, maximumByteCount: Int64
    ) throws -> ArchiveCaptureResult {
        try Task.checkCancellation()
        try testHooks.beforeCapture?(reservation)
        guard let session = reservation.sqliteSession,
              try currentMatchesReservation(reservation, root: root) else {
            throw ExactSourceCapturerError.generationChanged
        }
        var leaseBudget = CollectorOpenCodeSource.Budget()
        leaseBudget.maximumByteCount = maximumByteCount
        return try CollectorOpenCodeSource.withSnapshotLease(
            root: URL(fileURLWithPath: root.rootPath),
            stagingParent: cas.snapshotStagingParent,
            budget: leaseBudget
        ) { lease in
            guard lease.databaseGeneration == reservation.generation,
                  lease.walGeneration == session.walGeneration else {
                throw ExactSourceCapturerError.generationChanged
            }
            let snap = try lease.snapshot(sessionID: session.nativeSessionID)
            try testHooks.beforeCaptureFDAdmission?(reservation)
            guard try currentMatchesReservation(reservation, root: root) else {
                throw ExactSourceCapturerError.generationChanged
            }
            let capture = try ExactSourceCapturer.captureSQLiteSessionImage(
                snap.image, context: session, generation: reservation.generation,
                machineID: catalog.machineID(), cas: cas, catalog: catalog,
                maximumByteCount: maximumByteCount
            )
            try testHooks.afterCapture?(capture)
            try Task.checkCancellation()
            guard try owner.finishCapture(reservation, configuration: root, capture: capture.capture) != nil else {
                throw CollectorPublicationWorkerError.staleClaim
            }
            return capture
        }
    }

    private func deferDirty(
        _ claim: CollectorDirtyClaim, root: CollectorRootConfiguration, now: Int64,
        sourceUnavailable: Bool = false
    ) throws {
        let delay: Int64 = sourceUnavailable && claim.lastCaptureID == nil ? 60 : 1
        let next = now.addingReportingOverflow(delay)
        guard !next.overflow else { throw CollectorPublicationWorkerError.invalidBudget }
        if sourceUnavailable {
            try enqueueUnavailableDeferral(claim, root: root, retryNotBefore: next.partialValue)
            return
        }
        _ = try owner.deferClaim(claim, configuration: root, retryNotBefore: next.partialValue, reason: .unavailable)
    }

    private func enqueueUnavailableDeferral(
        _ claim: CollectorDirtyClaim, root: CollectorRootConfiguration, retryNotBefore: Int64
    ) throws {
        if let first = pendingUnavailableDeferrals.first {
            guard first.configuration.rootID.utf8.elementsEqual(root.rootID.utf8),
                  first.configuration.revision == root.revision else {
                throw CollectorPublicationWorkerError.invalidBudget
            }
        }
        guard pendingUnavailableDeferrals.count < 64 else { throw CollectorPublicationWorkerError.invalidBudget }
        pendingUnavailableDeferrals.append(
            .init(claim: claim, configuration: root, retryNotBefore: retryNotBefore)
        )
    }

    private func drainUnavailableDeferrals() throws {
        try Task.checkCancellation()
        guard !pendingUnavailableDeferrals.isEmpty else { return }
        let items = pendingUnavailableDeferrals
        _ = try owner.deferClaims(
            items.map { (claim: $0.claim, retryNotBefore: $0.retryNotBefore) },
            configuration: items[0].configuration,
            reason: .unavailable
        )
        pendingUnavailableDeferrals.removeAll()
    }

    private func performCapture(
        _ reservation: CollectorCaptureReservation, root: CollectorRootConfiguration, maximumByteCount: Int64
    ) throws -> ArchiveCaptureResult {
        try Task.checkCancellation()
        try testHooks.beforeCapture?(reservation)
        guard reservation.sqliteSession == nil, reservation.cursorLegacySession == nil else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        if root.source == .cursor {
            return try performCursorCapture(reservation, root: root, maximumByteCount: maximumByteCount)
        }
        guard try currentMatchesReservation(reservation, root: root) else {
            throw ExactSourceCapturerError.generationChanged
        }
        let source = URL(fileURLWithPath: root.rootPath).appendingPathComponent(reservation.relativePath)
        let descriptor: ArchiveSourceDescriptor
        let locator: String
        if let snapshot = reservation.snapshot {
            descriptor = try Self.fileSetDescriptor(root: root, reservation: reservation, snapshot: snapshot)
            locator = descriptor.locator
        } else {
            descriptor = try ArchiveSourceDescriptor.singleFile(locator: source.path, sourceURL: source,
                replayRelativePath: reservation.relativePath)
            locator = source.path
        }
        try testHooks.beforeCaptureFDAdmission?(reservation)
        guard try currentMatchesReservation(reservation, root: root) else {
            throw ExactSourceCapturerError.generationChanged
        }
        let result = try ExactSourceCapturer(cas: cas, catalog: catalog, descriptor: descriptor)
            .capture(source: reservation.effectiveSource ?? root.source, locator: locator, machineID: catalog.machineID(),
                maximumByteCount: maximumByteCount, expectedGeneration: reservation.generation)
        guard result.manifest.generation == reservation.generation,
              result.capture.rawByteCount <= maximumByteCount else {
            throw ExactSourceCapturerError.generationChanged
        }
        if reservation.snapshot != nil {
            guard try currentMatchesReservation(reservation, root: root) else {
                throw ExactSourceCapturerError.generationChanged
            }
        }
        // Capture already verified its stable FD generation and committed the
        // immutable bytes. Later live appends are new dirty work, not grounds
        // for discarding this generation's ordering reservation.
        // A thrown test interruption here models a crash after the original
        // capture writer committed but before the inventory transaction exists.
        try testHooks.afterCapture?(result)
        try Task.checkCancellation()
        guard try owner.finishCapture(reservation, configuration: root, capture: result.capture) != nil else {
            throw CollectorPublicationWorkerError.staleClaim
        }
        return result
    }

    private func performCursorCapture(
        _ reservation: CollectorCaptureReservation, root: CollectorRootConfiguration, maximumByteCount: Int64
    ) throws -> ArchiveCaptureResult {
        guard let snapshot = reservation.snapshot else { throw CollectorPublicationWorkerError.invalidCapture }
        let sealed: CollectorCursorSource.ModernCapture
        do {
            let current = try CollectorCursorSource.observe(rootPath: root.rootPath, primaryRelative: reservation.relativePath)
            guard current.generation == reservation.generation, current.snapshot == snapshot,
                  CollectorCursorSource.reservedPathsEqual(current.snapshot, snapshot) else {
                throw ExactSourceCapturerError.generationChanged
            }
            try testHooks.beforeCaptureFDAdmission?(reservation)
            sealed = try CollectorCursorSource.captureModern(rootPath: root.rootPath, session: current.session,
                stagingParent: cas.snapshotStagingParent, maximumByteCount: maximumByteCount)
        } catch is CancellationError { throw CancellationError() }
        catch { throw ExactSourceCapturerError.generationChanged }
        let result = try CollectorCursorSource.persistModern(sealed, machineID: catalog.machineID(), cas: cas,
            catalog: catalog, maximumByteCount: maximumByteCount)
        guard result.manifest.generation == reservation.generation,
              CollectorCursorSource.matchesReservedSnapshot(snapshot, manifest: result.manifest) else {
            throw ExactSourceCapturerError.generationChanged
        }
        try testHooks.afterCapture?(result)
        try Task.checkCancellation()
        guard try owner.finishCapture(reservation, configuration: root, capture: result.capture) != nil else {
            throw CollectorPublicationWorkerError.staleClaim
        }
        return result
    }

    private enum RecoveryResult { case completed, pending, uncaptured }

    private struct RecoveryProgress: Codable {
        let reservationID: String
        let boundaryTime: String
        let boundaryID: String
        var afterTime: String?
        var afterID: String?
        var matchedCaptureID: String?
    }

    private func recover(
        _ reservation: CollectorCaptureReservation, root: CollectorRootConfiguration,
        remainingCandidates: inout Int
    ) throws -> RecoveryResult {
        guard remainingCandidates > 0 else { return .pending }
        guard configuredAuthorityMatchesReservation(reservation, root: root) else { return .pending }
        var progress: RecoveryProgress
        if let bytes = try owner.captureRecoveryState(reservation) {
            progress = try ArchiveCanonicalJSON.decode(RecoveryProgress.self, from: bytes)
            guard progress.reservationID == reservation.id, (progress.afterTime == nil) == (progress.afterID == nil),
                  progress.matchedCaptureID.map(ArchiveV2Hash.isValidSHA256) ?? true else {
                throw CollectorPublicationWorkerError.reconciliationRequired
            }
        } else {
            guard let boundary = try catalog.unboundCaptureBoundary() else { return .uncaptured }
            progress = .init(reservationID: reservation.id, boundaryTime: boundary.capturedAt, boundaryID: boundary.captureID)
        }
        let after: ArchiveCaptureCursor? = progress.afterTime.flatMap { time in
            progress.afterID.map { .init(capturedAt: time, captureID: $0) }
        }
        let boundary = ArchiveCaptureCursor(capturedAt: progress.boundaryTime, captureID: progress.boundaryID)
        let maximum = remainingCandidates
        let locators = Self.reservationLocators(reservation: reservation, root: root)
        let page = try catalog.unboundCaptures(
            limit: maximum, after: after, through: boundary,
            matching: (
                source: (reservation.effectiveSource ?? root.source).rawValue,
                locators: locators,
                generation: reservation.generation
            )
        )
        remainingCandidates -= page.count
        for capture in page {
            try Task.checkCancellation()
            guard capture.source == (reservation.effectiveSource ?? root.source).rawValue,
                  locators.contains(where: { capture.locator.utf8.elementsEqual($0.utf8) }),
                  capture.generation == reservation.generation else { continue }
            if let snapshot = reservation.snapshot {
                guard let manifest = try? ArchiveCanonicalJSON.decode(
                    ArchiveSourceManifest.self, from: capture.unboundManifestBytes
                ), Self.matchesReservedSnapshot(snapshot, manifest: manifest, source: root.source) else {
                    continue
                }
            }
            if let session = reservation.cursorLegacySession {
                guard let manifest = try? ArchiveCanonicalJSON.decode(
                    ArchiveSourceManifest.self, from: capture.unboundManifestBytes
                ), manifest.replayLayout.cursorLegacySession == session,
                   (try? ExactSourceCapturer.cursorLegacySessionCaptureID(
                    machineID: capture.machineID, context: session, generation: reservation.generation,
                    wholeSourceSHA256: capture.wholeSourceSHA256)) == capture.captureID else {
                    continue
                }
            }
            if let session = reservation.sqliteSession {
                guard let manifest = try? ArchiveCanonicalJSON.decode(
                    ArchiveSourceManifest.self, from: capture.unboundManifestBytes
                ), manifest.replayLayout.sqliteSession == session,
                   (try? ExactSourceCapturer.sqliteSessionImageCaptureID(
                    machineID: capture.machineID, context: session, generation: reservation.generation,
                    wholeSourceSHA256: capture.wholeSourceSHA256)) == capture.captureID else {
                    continue
                }
            }
            if let prior = progress.matchedCaptureID, prior != capture.captureID {
                throw CollectorPublicationWorkerError.reconciliationRequired
            }
            progress.matchedCaptureID = capture.captureID
        }
        if let last = page.last {
            progress.afterTime = last.capturedAt
            progress.afterID = last.captureID
        }
        let atBoundary = progress.afterTime == boundary.capturedAt && progress.afterID == boundary.captureID
        if page.count == maximum, !atBoundary {
            guard try owner.storeCaptureRecoveryState(reservation, payload: ArchiveCanonicalJSON.encode(progress)) else {
                throw CollectorPublicationWorkerError.staleClaim
            }
            return .pending
        }
        guard let captureID = progress.matchedCaptureID else {
            // A subsequent capture may commit beyond this negative scan's
            // frozen boundary. Clear it durably before recapture can begin.
            guard try owner.storeCaptureRecoveryState(reservation, payload: nil) else {
                throw CollectorPublicationWorkerError.staleClaim
            }
            return .uncaptured
        }
        guard let capture = try catalog.capture(captureID: captureID), capture.generation == reservation.generation else {
            throw CollectorPublicationWorkerError.reconciliationRequired
        }
        if let snapshot = reservation.snapshot {
            guard let manifest = try? ArchiveCanonicalJSON.decode(
                ArchiveSourceManifest.self, from: capture.unboundManifestBytes
            ), Self.matchesReservedSnapshot(snapshot, manifest: manifest, source: root.source) else {
                throw CollectorPublicationWorkerError.reconciliationRequired
            }
        }
        if let session = reservation.cursorLegacySession {
            guard let manifest = try? ArchiveCanonicalJSON.decode(
                ArchiveSourceManifest.self, from: capture.unboundManifestBytes
            ), manifest.replayLayout.cursorLegacySession == session,
               (try? ExactSourceCapturer.cursorLegacySessionCaptureID(
                machineID: capture.machineID, context: session, generation: reservation.generation,
                wholeSourceSHA256: capture.wholeSourceSHA256)) == capture.captureID else {
                throw CollectorPublicationWorkerError.reconciliationRequired
            }
        }
        if let session = reservation.sqliteSession {
            guard let manifest = try? ArchiveCanonicalJSON.decode(
                ArchiveSourceManifest.self, from: capture.unboundManifestBytes
            ), manifest.replayLayout.sqliteSession == session,
               (try? ExactSourceCapturer.sqliteSessionImageCaptureID(
                machineID: capture.machineID, context: session, generation: reservation.generation,
                wholeSourceSHA256: capture.wholeSourceSHA256)) == capture.captureID else {
                throw CollectorPublicationWorkerError.reconciliationRequired
            }
        }
        // Finish only the reserved generation; do not read current source bytes.
        guard try owner.finishCapture(reservation, configuration: root, capture: capture) != nil else {
            throw CollectorPublicationWorkerError.staleClaim
        }
        return .completed
    }

    private func upload(to replica: CollectorReplicaEndpoint, now: Int64) async throws -> (acknowledged: Int, deferred: Int) {
        let claims = try owner.claimPublications(replicaID: replica.replicaID, limit: budget.maxUploadClaimsPerReplica, now: now)
        var acknowledged = 0
        var deferred = 0
        var offset = 0
        while offset < claims.count {
            try Task.checkCancellation()
            let end = min(offset + 2, claims.count)
            try await withThrowingTaskGroup(of: (Int, Int).self) { group in
                for claim in claims[offset..<end] {
                    group.addTask {
                        try await self.finishReplicaClaim(claim, to: replica, now: now)
                    }
                }
                for try await part in group {
                    acknowledged += part.0
                    deferred += part.1
                }
            }
            offset = end
        }
        return (acknowledged, deferred)
    }

    private func finishReplicaClaim(
        _ claim: CollectorPublicationClaim, to replica: CollectorReplicaEndpoint, now: Int64
    ) async throws -> (Int, Int) {
        try Task.checkCancellation()
        let bytes: Data
        do { bytes = try await transmit(claim, to: replica) }
        catch is CancellationError { throw CancellationError() }
        catch let error as CollectorPublicationWorkerError {
            try Task.checkCancellation()
            if error == .staleClaim { return (0, 0) }
            let reason: CollectorPublicationDeferral
            switch error {
            case .withheld: reason = .privacyWithheld
            case .invalidCapture: reason = .localContentUnavailable
            case .invalidACK: reason = .invalidACK
            case .unsupportedReplica: reason = .unsupportedReplica
            default: reason = .unavailable
            }
            if try owner.deferPublication(claim, now: now, reason: reason) { return (0, 1) }
            return (0, 0)
        }
        try testHooks.beforeACKCommit?(claim)
        try Task.checkCancellation()
        // SQL/storage failures propagate. They are not relabeled as network
        // retries, and a cancelled ACK never produces an index/receipt write.
        if try owner.recordPublicationACK(claim, canonicalBytes: bytes) { return (1, 0) }
        return (0, 0)
    }

    private func transmit(_ claim: CollectorPublicationClaim, to replica: CollectorReplicaEndpoint) async throws -> Data {
        guard let root = configuration(rootID: claim.intent.rootID, revision: claim.intent.rootRevision),
              let capture = try catalog.capture(captureID: claim.intent.captureID),
              capture.unboundManifestSHA256 == claim.intent.publication.manifestSHA256,
              capture.machineID == claim.intent.publication.machineID,
              capture.source == (try owner.publicationSource(claim.intent)).rawValue, capture.rawByteCount <= budget.maxCaptureBytes else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        let result: ArchiveCaptureResult
        do {
            let manifestBytes = try cas.readManifest(sha256: capture.unboundManifestSHA256,
                maximumByteCount: Int64(ArchiveV2ProtocolLimits.maxManifestBytes))
            guard manifestBytes == capture.unboundManifestBytes else { throw CollectorPublicationWorkerError.invalidCapture }
            let manifest = try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: manifestBytes)
            for chunk in manifest.chunks {
                _ = try cas.readObject(sha256: chunk.rawSHA256, maximumByteCount: chunk.rawByteCount)
            }
            result = ArchiveCaptureResult(capture: capture, manifest: manifest)
        } catch is CancellationError { throw CancellationError() }
        catch { throw CollectorPublicationWorkerError.invalidCapture }
        var proof = try authorize(result, root: root, prior: nil)
        let capabilities = try await request(replica, path: "/v2/archive/publication-capabilities", method: "GET",
            body: nil, capture: result, root: root, claim: claim, proof: proof)
        proof = capabilities.proof
        do {
            let value = try ArchiveCanonicalJSON.decode(CollectorPublicationCapabilities.self, from: capabilities.bytes)
            guard value.serverID == replica.replicaID else { throw CollectorPublicationWorkerError.unsupportedReplica }
        } catch { throw CollectorPublicationWorkerError.unsupportedReplica }
        for chunk in result.manifest.chunks {
            try Task.checkCancellation()
            let object: Data
            do { object = try cas.readObject(sha256: chunk.rawSHA256, maximumByteCount: chunk.rawByteCount) }
            catch is CancellationError { throw CancellationError() }
            catch { throw CollectorPublicationWorkerError.invalidCapture }
            guard Int64(object.count) == chunk.rawByteCount else { throw CollectorPublicationWorkerError.invalidCapture }
            let path = "/v2/archive/objects/\(chunk.rawSHA256)"
            let probed = try await request(replica, path: path, method: "HEAD",
                body: nil, capture: result, root: root, claim: claim, proof: proof)
            proof = probed.proof
            if probed.status == 200 { continue }
            guard probed.status == 404 else { throw CollectorPublicationWorkerError.transport }
            let sent = try await request(replica, path: path, method: "PUT",
                body: object, capture: result, root: root, claim: claim, proof: proof)
            proof = sent.proof
        }
        let manifestPath = "/v2/archive/manifests/\(capture.unboundManifestSHA256)"
        let probedManifest = try await request(replica, path: manifestPath, method: "HEAD",
            body: nil, capture: result, root: root, claim: claim, proof: proof)
        proof = probedManifest.proof
        if probedManifest.status != 200 {
            guard probedManifest.status == 404 else { throw CollectorPublicationWorkerError.transport }
            let manifestSent = try await request(replica, path: manifestPath, method: "PUT",
                body: capture.unboundManifestBytes, capture: result, root: root, claim: claim, proof: proof)
            proof = manifestSent.proof
        }
        let publicationSent = try await request(replica, path: "/v2/archive/publications/\(claim.intent.digest)", method: "PUT",
            body: claim.intent.canonicalBytes, capture: result, root: root, claim: claim, proof: proof)
        do {
            let ack = try ArchiveCanonicalJSON.decode(CollectorPublicationACK.self, from: publicationSent.bytes)
            try ack.validate(against: claim.intent.publication, expectedServerID: replica.replicaID)
        } catch { throw CollectorPublicationWorkerError.invalidACK }
        return publicationSent.bytes
    }

    private func authorize(_ capture: ArchiveCaptureResult, root: CollectorRootConfiguration, prior: CollectorPrivacyProof?) throws -> CollectorPrivacyProof {
        let current: CollectorPrivacyPolicy
        do { current = try policy() }
        catch is CancellationError { throw CancellationError() }
        catch { throw CollectorPublicationWorkerError.withheld }
        let format = formats[root.rootID] ?? Self.defaultFormat(root.source)
        if let prior, prior.isCurrent(for: capture, policy: current, format: format) { return prior }
        let maximumLineBytes: Int
        switch format {
        case .codex, .claudeCode, .pi, .copilot: maximumLineBytes = 32 * 1024 * 1024
        default: maximumLineBytes = CollectorPrivacyLimits().maxLineBytes
        }
        let assessment = try CollectorPrivacyProof.assess(capture: capture, cas: cas, format: format, policy: current,
            limits: .init(maxSourceBytes: budget.maxCaptureBytes, maxLineBytes: maximumLineBytes))
        guard case .eligible(let proof) = assessment else { throw CollectorPublicationWorkerError.withheld }
        return proof
    }

    private func request(
        _ replica: CollectorReplicaEndpoint, path: String, method: String, body: Data?,
        capture: ArchiveCaptureResult, root: CollectorRootConfiguration,
        claim: CollectorPublicationClaim, proof: CollectorPrivacyProof
    ) async throws -> (bytes: Data, status: Int, proof: CollectorPrivacyProof) {
        try Task.checkCancellation()
        try testHooks.beforeRequest?(replica.replicaID, path)
        try testHooks.beforeHTTP?(replica.replicaID, path, method)
        let freshProof = try authorize(capture, root: root, prior: proof)
        guard try owner.isPublicationClaimCurrent(claim) else { throw CollectorPublicationWorkerError.staleClaim }
        try Task.checkCancellation()
        guard let url = URL(string: path, relativeTo: replica.baseURL)?.absoluteURL else {
            throw CollectorPublicationWorkerError.invalidConfiguration
        }
        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeoutInterval(path: path, method: method))
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(replica.bearerToken)", forHTTPHeaderField: "Authorization")
        if body != nil {
            request.setValue(path.hasPrefix("/v2/archive/objects/") ? "application/octet-stream" : "application/json", forHTTPHeaderField: "Content-Type")
        }
        let response = try await transport.send(request, maximumBytes: budget.maxResponseBytes)
        try Task.checkCancellation()
        if path == "/v2/archive/publication-capabilities", response.status == 404 {
            throw CollectorPublicationWorkerError.unsupportedReplica
        }
        let accepted = response.status == 200
            || (method == "PUT" && response.status == 201)
            || (method == "HEAD" && response.status == 404)
        guard accepted else { throw CollectorPublicationWorkerError.transport }
        let bytes = try testHooks.afterResponse?(replica.replicaID, path, response.bytes) ?? response.bytes
        guard bytes.count <= budget.maxResponseBytes else { throw CollectorPublicationWorkerError.responseTooLarge }
        return (bytes, response.status, freshProof)
    }

    private static func requestTimeoutInterval(path: String, method: String) -> TimeInterval {
        if method == "PUT",
           path.hasPrefix("/v2/archive/manifests/") || path.hasPrefix("/v2/archive/publications/") {
            return 180
        }
        return 30
    }

    private static func origin(_ replica: CollectorReplicaEndpoint) -> String {
        let scheme = replica.baseURL.scheme?.lowercased() ?? ""
        return scheme + "://" + (replica.baseURL.host?.lowercased() ?? "") + ":" + String(replica.baseURL.port ?? (scheme == "https" ? 443 : 80))
    }

    private static func compatible(source: SourceName, format: SourceMetadataProjection.Format) -> Bool {
        switch (source, format) {
        case (.codex, .codex):
            return true
        case (.claudeCode, .claudeCode):
            return true
        case (.qwen, .qwen):
            return true
        case (.vscode, .vscode), (.cline, .cline):
            return true
        case (.iflow, .iflow):
            return true
        case (.qoder, .qoder):
            return true
        case (.commandcode, .commandcode):
            return true
        case (.copilot, .copilot):
            return true
        case (.geminiCli, .geminiCli):
            return true
        case (.opencode, .opencode):
            return true
        case (.kimi, .kimi), (.cursor, .cursor):
            return true
        case (.antigravity, .antigravityCLITranscript):
            return true
        case (.windsurf, .windsurfHookTranscript):
            return true
        case (.pi, .pi):
            return true
        case (.grok, .grok):
            return true
        default:
            return false
        }
    }

    private static func defaultFormat(_ source: SourceName) -> SourceMetadataProjection.Format {
        switch source {
        case .codex: return .codex
        case .qwen: return .qwen
        case .qoder: return .qoder
        case .vscode: return .vscode
        case .cline: return .cline
        case .iflow: return .iflow
        case .commandcode: return .commandcode
        case .copilot: return .copilot
        case .geminiCli: return .geminiCli
        case .opencode: return .opencode
        case .kimi: return .kimi
        case .cursor: return .cursor
        case .antigravity: return .antigravityCLITranscript
        case .windsurf: return .windsurfHookTranscript
        case .pi: return .pi
        case .grok: return .grok
        default: return .claudeCode(forceClaudeCodeSource: false)
        }
    }

    private static func matchesReservedSnapshot(
        _ snapshot: CollectorDependencySnapshot, manifest: ArchiveSourceManifest, source: SourceName
    ) -> Bool {
        switch source {
        case .vscode:
            return CollectorVSCodeSource.matchesReservedSnapshot(snapshot, manifest: manifest)
        case .cline:
            return CollectorClineSource.matchesReservedSnapshot(snapshot, manifest: manifest)
        case .geminiCli:
            return CollectorGeminiSource.matchesReservedSnapshot(snapshot, manifest: manifest)
        case .copilot:
            return CollectorCopilotSource.matchesReservedSnapshot(snapshot, manifest: manifest)
        case .kimi:
            return CollectorKimiSource.matchesReservedSnapshot(snapshot, manifest: manifest)
        case .grok:
            return CollectorGrokSource.matchesReservedSnapshot(snapshot, manifest: manifest)
        case .cursor:
            return CollectorCursorSource.matchesReservedSnapshot(snapshot, manifest: manifest)
        default:
            return false
        }
    }

    private func configuredRegistryLocator(_ root: CollectorRootConfiguration) -> String? {
        projectRegistryPaths.first { $0.key.utf8.elementsEqual(root.rootID.utf8) }?.value
    }

    private func configuredAuthorityMatchesReservation(
        _ reservation: CollectorCaptureReservation, root: CollectorRootConfiguration
    ) -> Bool {
        if root.source == .geminiCli {
            guard let reserved = reservation.snapshot?.geminiProjectContext?.registryLocator else {
                return true
            }
            guard let configured = configuredRegistryLocator(root) else { return false }
            return configured.utf8.elementsEqual(reserved.utf8)
        }
        if root.source == .kimi {
            guard let reserved = reservation.snapshot?.kimiProjectContext?.registryLocator,
                  let configured = configuredRegistryLocator(root) else { return false }
            return configured.utf8.elementsEqual(reserved.utf8)
        }
        return true
    }

    private func reconcileConfiguredRegistries(captureRootIDs: Set<Data>?) throws {
        // gemini_registry_* columns page each root independently for Gemini and Kimi.
        for root in roots where (root.source == .geminiCli || root.source == .kimi) && allowsLiveCapture(root, captureRootIDs) {
            try Task.checkCancellation()
            guard let locator = configuredRegistryLocator(root) else { continue }
            let current = try CollectorGeminiSource.registryGeneration(locator: locator)
            try owner.reconcileGeminiRegistry(configuration: root, locator: locator, generation: current)
        }
    }

    private func currentMatchesReservation(
        _ reservation: CollectorCaptureReservation, root: CollectorRootConfiguration
    ) throws -> Bool {
        if let session = reservation.sqliteSession {
            let live = try CollectorOpenCodeSource.observe(root: URL(fileURLWithPath: root.rootPath))
            return live.databaseGeneration == reservation.generation
                && live.walGeneration == session.walGeneration
        }
        if let snapshot = reservation.snapshot {
            if root.source == .vscode {
                let current = try CollectorVSCodeSource.observe(rootPath: root.rootPath,
                    primaryRelative: reservation.relativePath, maximumByteCount: budget.maxCaptureBytes)
                return current.generation == reservation.generation && current.snapshot == snapshot
            }
            if root.source == .cline {
                let current = try CollectorClineSource.observe(rootPath: root.rootPath, primaryRelative: reservation.relativePath)
                return current.generation == reservation.generation
                    && current.snapshot == snapshot
                    && current.snapshot.entrypointRelativePath.utf8.elementsEqual(snapshot.entrypointRelativePath.utf8)
            }
            if root.source == .cursor {
                let current = try CollectorCursorSource.observe(rootPath: root.rootPath, primaryRelative: reservation.relativePath)
                return current.generation == reservation.generation && current.snapshot == snapshot
                    && CollectorCursorSource.reservedPathsEqual(current.snapshot, snapshot)
            }
            if root.source == .geminiCli {
                let current = try CollectorGeminiSource.observe(
                    rootPath: root.rootPath, primaryRelative: reservation.relativePath,
                    registryLocator: configuredRegistryLocator(root),
                    maximumByteCount: budget.maxCaptureBytes
                )
                return current.generation == reservation.generation
                    && CollectorGeminiSource.provenanceEquals(current.snapshot, snapshot)
            }
            if root.source == .kimi {
                guard let locator = configuredRegistryLocator(root) else { return false }
                let current = try CollectorKimiSource.observe(
                    rootPath: root.rootPath, primaryRelative: reservation.relativePath,
                    registryLocator: locator
                )
                return current.generation == reservation.generation
                    && CollectorKimiSource.provenanceEquals(current.snapshot, snapshot)
            }
            if root.source == .grok {
                let current = try CollectorGrokSource.observe(
                    rootPath: root.rootPath, primaryRelative: reservation.relativePath
                )
                return current.generation == reservation.generation
                    && CollectorGrokSource.provenanceEquals(current.snapshot, snapshot)
            }
            let current = try CollectorCopilotSource.observe(
                rootPath: root.rootPath, primaryRelative: reservation.relativePath
            )
            return current.generation == reservation.generation && current.snapshot == snapshot
        }
        return try Self.sourceGeneration(root: root, relativePath: reservation.relativePath) == reservation.generation
    }

    private static func fileSetDescriptor(
        root: CollectorRootConfiguration, reservation: CollectorCaptureReservation,
        snapshot: CollectorDependencySnapshot
    ) throws -> ArchiveSourceDescriptor {
        if root.source == .vscode {
            try CollectorVSCodeSource.requireValidSnapshot(snapshot, entrypoint: reservation.relativePath)
        } else if root.source == .cline {
            try CollectorClineSource.requireValidSnapshot(snapshot, entrypoint: reservation.relativePath)
        } else if root.source == .kimi {
            try CollectorKimiSource.requireValidSnapshot(snapshot, entrypoint: reservation.relativePath)
        } else if root.source == .geminiCli {
            try CollectorGeminiSource.requireValidSnapshot(snapshot, entrypoint: reservation.relativePath)
        } else if root.source == .grok {
            try CollectorGrokSource.requireValidSnapshot(snapshot, entrypoint: reservation.relativePath)
        } else {
            try CollectorCopilotSource.requireValidSnapshot(snapshot, entrypoint: reservation.relativePath)
        }
        guard let rootPath = ArchiveSourceDescriptor.fileSetAbsolutePath(root.rootPath) else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        let files = snapshot.present.map { URL(fileURLWithPath: rootPath + "/" + $0.relativePath) }
        let absent = snapshot.absentRelativePaths.map { URL(fileURLWithPath: rootPath + "/" + $0) }
        return try ArchiveSourceDescriptor.fileSet(
            locator: rootPath + "/" + reservation.relativePath,
            root: URL(fileURLWithPath: rootPath), files: files, absentFiles: absent,
            vscodeWorkspaceContext: snapshot.vscodeWorkspaceContext,
            geminiProjectContext: snapshot.geminiProjectContext,
            kimiProjectContext: snapshot.kimiProjectContext
        )
    }

    private static func reservationLocators(
        reservation: CollectorCaptureReservation, root: CollectorRootConfiguration
    ) -> [String] {
        if let legacy = reservation.cursorLegacySession { return [legacy.logicalLocator] }
        if let session = reservation.sqliteSession {
            return [session.databaseLocator + "::" + session.nativeSessionID]
        }
        var values = [URL(fileURLWithPath: root.rootPath).appendingPathComponent(reservation.relativePath).path]
        if let rootPath = ArchiveSourceDescriptor.fileSetAbsolutePath(root.rootPath) {
            values.append(rootPath + "/" + reservation.relativePath)
        }
        return values
    }

    private static func validEndpoint(_ replica: CollectorReplicaEndpoint) -> Bool {
        let url = replica.baseURL
        let scheme = url.scheme?.lowercased()
        let host = url.host?.lowercased()
        let loopback = host == "127.0.0.1" || host == "::1" || host == "[::1]" || host == "localhost"
        return host != nil && (scheme == "https" || (scheme == "http" && loopback))
            && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
            && (url.path.isEmpty || url.path == "/") && (url.port.map { (1...65_535).contains($0) } ?? true)
            && (1...4_096).contains(replica.bearerToken.utf8.count)
            && replica.bearerToken.utf8.allSatisfy { (33...126).contains($0) }
    }

    private static func sourceGeneration(root: CollectorRootConfiguration, relativePath: String,
        inspect: ((Int32, ArchiveSourceGeneration) throws -> Void)? = nil) throws -> ArchiveSourceGeneration {
        guard CollectorInventoryStore.isSafeRelativePath(relativePath),
              root.rootPath.utf8.count + relativePath.utf8.count + 1 <= CollectorPOSIXRootEnumerator.maximumPathBytes else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        let parts = relativePath.split(separator: "/").map(String.init)
        let opened = try CollectorPOSIXDirectoryAccess.openAbsolute(components: CollectorPOSIXDirectoryAccess.components(root.rootPath))
        var parent = opened.descriptor
        defer { CollectorPOSIXDirectoryAccess.close(parent) }
        for part in parts.dropLast() {
            let next = try CollectorPOSIXDirectoryAccess.openComponent(part, parent: parent)
            CollectorPOSIXDirectoryAccess.close(parent)
            parent = next
        }
        let name = parts[parts.count - 1]
        let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = Darwin.close(descriptor) }
        var info = stat()
        var pathInfo = stat()
        guard fstat(descriptor, &info) == 0, fstatat(parent, name, &pathInfo, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_dev == pathInfo.st_dev, info.st_ino == pathInfo.st_ino,
              info.st_mode & S_IFMT == S_IFREG, let inode = Int64(exactly: info.st_ino) else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        func nanoseconds(_ value: timespec) throws -> Int64 {
            let seconds = Int64(value.tv_sec).multipliedReportingOverflow(by: 1_000_000_000)
            let nanos = seconds.partialValue.addingReportingOverflow(Int64(value.tv_nsec))
            guard !seconds.overflow, !nanos.overflow else { throw CollectorPublicationWorkerError.invalidCapture }
            return nanos.partialValue
        }
        let generation = try ArchiveSourceGeneration(device: Int64(info.st_dev), inode: inode, size: Int64(info.st_size),
            mtimeNs: nanoseconds(info.st_mtimespec), ctimeNs: nanoseconds(info.st_ctimespec), mode: Int64(info.st_mode))
        if let inspect {
            try inspect(descriptor, generation)
            var after = stat()
            var pathAfter = stat()
            guard fstat(descriptor, &after) == 0, fstatat(parent, name, &pathAfter, AT_SYMLINK_NOFOLLOW) == 0,
                  after.st_dev == info.st_dev, after.st_ino == info.st_ino,
                  pathAfter.st_dev == info.st_dev, pathAfter.st_ino == info.st_ino,
                  after.st_size == info.st_size, after.st_mode == info.st_mode,
                  after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec,
                  after.st_ctimespec.tv_sec == info.st_ctimespec.tv_sec, after.st_ctimespec.tv_nsec == info.st_ctimespec.tv_nsec else {
                throw ExactSourceCapturerError.generationChanged
            }
        }
        return generation
    }

    // A bounded routing hint, not a parser or permission to upload. Complete
    // frozen CAS metadata still supplies the independent privacy proof.
    private static func claudeSourceHint(descriptor: Int32, locator: String, sourceByteCount: Int64,
        remainingBytes: inout Int64) throws -> SourceName {
        if SourceMetadataProjection.claudeSource(model: "", filePath: locator) == .lobsterai { return .lobsterai }
        var projection = SourceMetadataProjection(format: .claudeCode(forceClaudeCodeSource: false), locator: locator)
        var line = Data()
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        let maximumLine = 32 * 1024 * 1024
        var unreadBytes = sourceByteCount
        func consume() {
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                projection.consume(object)
            }
            line.removeAll(keepingCapacity: true)
        }
        while true {
            try Task.checkCancellation()
            if unreadBytes == 0 {
                if !line.isEmpty { consume() }
                return projection.source
            }
            guard remainingBytes > 0 else { throw CollectorPublicationWorkerError.withheld }
            let maximum = Int(min(Int64(buffer.count), min(remainingBytes, unreadBytes)))
            let count = Darwin.read(descriptor, &buffer, maximum)
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if count == 0 {
                if !line.isEmpty { consume() }
                return projection.source
            }
            remainingBytes -= Int64(count)
            unreadBytes -= Int64(count)
            for byte in buffer.prefix(count) {
                if byte == 0x0A {
                    consume()
                    if projection.model != nil { return projection.source }
                } else {
                    guard line.count < maximumLine else { throw CollectorPublicationWorkerError.withheld }
                    line.append(byte)
                }
            }
        }
    }
}

private struct CollectorPublicationHTTPResponse: Sendable {
    let status: Int
    let bytes: Data
}

/// Bounded response accumulation, no cookies/cache/proxy/credential store, no
/// redirects. Register the continuation before cancellation can reach the task.
private final class CollectorPublicationHTTPTransport: @unchecked Sendable {
    private let delegate = CollectorPublicationHTTPDelegate()
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCredentialStorage = nil
        configuration.connectionProxyDictionary = [:]
        configuration.waitsForConnectivity = false
        // Per-request URLRequest.timeoutInterval stays 30s except manifest/publication
        // PUT (180s). Session request idle must not undercut those longer PUTs;
        // resource cap stays above 180s so a valid slow verification is not cut at 120s.
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 240
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func send(_ request: URLRequest, maximumBytes: Int) async throws -> CollectorPublicationHTTPResponse {
        let cancellation = CollectorPublicationRequestCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                delegate.register(task, expectedURL: request.url!, limit: maximumBytes, continuation: continuation)
                cancellation.install(task)
                task.resume()
            }
        } onCancel: { cancellation.cancel() }
    }
}

private final class CollectorPublicationRequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false
    func install(_ task: URLSessionDataTask) {
        lock.lock()
        self.task = task
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { task.cancel() }
    }
    func cancel() {
        lock.lock()
        cancelled = true
        let selected = task
        lock.unlock()
        selected?.cancel()
    }
}

private final class CollectorPublicationHTTPDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Pending {
        let expectedURL: URL
        let limit: Int
        let continuation: CheckedContinuation<CollectorPublicationHTTPResponse, Error>
        var response: HTTPURLResponse?
        var bytes = Data()
        var failure: CollectorPublicationWorkerError?
    }
    private let lock = NSLock()
    private var requests: [Int: Pending] = [:]

    func register(_ task: URLSessionDataTask, expectedURL: URL, limit: Int, continuation: CheckedContinuation<CollectorPublicationHTTPResponse, Error>) {
        lock.lock()
        requests[task.taskIdentifier] = .init(expectedURL: expectedURL, limit: limit, continuation: continuation)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        var reject = true
        if var pending = requests[dataTask.taskIdentifier] {
            if let http = response as? HTTPURLResponse, http.url == pending.expectedURL {
                pending.response = http
                if http.expectedContentLength > Int64(pending.limit) { pending.failure = .responseTooLarge }
            } else { pending.failure = .transport }
            reject = pending.failure != nil
            requests[dataTask.taskIdentifier] = pending
        }
        lock.unlock()
        completionHandler(reject ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        var reject = false
        if var pending = requests[dataTask.taskIdentifier], pending.failure == nil {
            if data.count > pending.limit - pending.bytes.count {
                pending.failure = .responseTooLarge
                reject = true
            } else { pending.bytes.append(data) }
            requests[dataTask.taskIdentifier] = pending
        }
        lock.unlock()
        if reject { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock()
        requests[task.taskIdentifier]?.failure = .transport
        lock.unlock()
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let pending = requests.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let pending else { return }
        if let failure = pending.failure { pending.continuation.resume(throwing: failure) }
        else if error != nil { pending.continuation.resume(throwing: CollectorPublicationWorkerError.transport) }
        else if let response = pending.response {
            pending.continuation.resume(returning: .init(status: response.statusCode, bytes: pending.bytes))
        } else { pending.continuation.resume(throwing: CollectorPublicationWorkerError.transport) }
    }
}
