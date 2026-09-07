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
    var diskAdmission: CollectorDiskAdmissionStatus = .notEvaluated
}

struct CollectorPublicationWorkerTestHooks: Sendable {
    var beforeCapture: (@Sendable (CollectorCaptureReservation) throws -> Void)?
    var beforeCaptureFDAdmission: (@Sendable (CollectorCaptureReservation) throws -> Void)?
    var afterCapture: (@Sendable (ArchiveCaptureResult) throws -> Void)?
    var beforeRequest: (@Sendable (_ replicaID: String, _ path: String) throws -> Void)?
    var afterResponse: (@Sendable (_ replicaID: String, _ path: String, _ bytes: Data) throws -> Data)?
    var beforeACKCommit: (@Sendable (CollectorPublicationClaim) throws -> Void)?
}

/// Native capture and publication only. No index, app, service or product writer.
actor CollectorPublicationWorker {
    private let owner: CollectorInventoryOwner
    private let catalog: ArchiveCatalog
    private let cas: ImmutableArchiveCAS
    private let roots: [CollectorRootConfiguration]
    private let replicas: [CollectorReplicaEndpoint]
    private let policy: @Sendable () throws -> CollectorPrivacyPolicy
    private let budget: CollectorPublicationBudget
    private let testHooks: CollectorPublicationWorkerTestHooks
    private let transport: CollectorPublicationHTTPTransport
    private var running = false

    init(
        owner: CollectorInventoryOwner,
        catalog: ArchiveCatalog,
        cas: ImmutableArchiveCAS,
        roots: [CollectorRootConfiguration],
        replicas: [CollectorReplicaEndpoint],
        policy: @escaping @Sendable () throws -> CollectorPrivacyPolicy,
        budget: CollectorPublicationBudget = .init(),
        testHooks: CollectorPublicationWorkerTestHooks = .init()
    ) throws {
        guard (1...64).contains(roots.count),
              Set(roots.map { Data($0.rootID.utf8) }).count == roots.count,
              roots.allSatisfy({ !$0.rootID.isEmpty && !$0.rootID.contains("\0") && $0.revision > 0
                  && ($0.source == .codex || $0.source == .claudeCode)
                  && (try? CollectorPOSIXDirectoryAccess.components($0.rootPath)) != nil }),
              replicas.count == 2, Set(replicas.map(\.replicaID)) == Set(["hq", "m1"]),
              replicas.allSatisfy(Self.validEndpoint),
              Set(replicas.map(Self.origin)).count == 2,
              replicas[0].bearerToken != replicas[1].bearerToken else {
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
        self.replicas = replicas.sorted { $0.replicaID < $1.replicaID }
        self.policy = policy
        self.budget = budget
        self.testHooks = testHooks
        transport = CollectorPublicationHTTPTransport()
    }

    func runOnce(now: Int64) async throws -> CollectorPublicationCycle {
        guard now >= 0 else { throw CollectorPublicationWorkerError.invalidBudget }
        try Task.checkCancellation()
        guard !running else { return .init() }
        running = true
        defer { running = false }
        var result = CollectorPublicationCycle()
        var remainingFiles = budget.maxCaptureFiles
        var remainingBytes = budget.maxCaptureBytes
        var remainingRecovery = budget.maxRecoveryCandidates
        let reservations = try owner.captureReservations(limit: 64)
        // A pre-existing reservation is reconciled before that stream can mint
        // another sequence. No timestamp/digest is used as publication order.
        for reservation in reservations {
            try Task.checkCancellation()
            guard let root = configuration(rootID: reservation.rootID, revision: reservation.rootRevision) else { continue }
            let recovery = try recover(reservation, root: root, remainingCandidates: &remainingRecovery)
            switch recovery {
            case .completed: result.recovered += 1
            case .pending: result.deferred += 1
            case .uncaptured:
                guard remainingFiles > 0, reservation.generation.size <= remainingBytes,
                      try admitsCaptureDisk(recording: &result.diskAdmission) else {
                    result.deferred += 1
                    continue
                }
                remainingFiles -= 1
                do {
                    let current = try Self.sourceGeneration(root: root, relativePath: reservation.relativePath)
                    guard current == reservation.generation else {
                        _ = try owner.abandonCapture(reservation)
                        result.deferred += 1
                        continue
                    }
                    let capture = try performCapture(reservation, root: root, maximumByteCount: remainingBytes)
                    remainingBytes -= capture.capture.rawByteCount
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
        for root in roots {
            guard remainingFiles > 0 else { break }
            // Do not capture a newer generation in a stream reconciled during
            // this same bounded pass, even if the old reservation just finished.
            if reservations.contains(where: { $0.rootID.utf8.elementsEqual(root.rootID.utf8) && $0.rootRevision == root.revision }) { continue }
            let claims = try owner.claimDirty(configuration: root, limit: remainingFiles, now: now)
            for claim in claims {
                try Task.checkCancellation()
                remainingFiles -= 1
                let generation: ArchiveSourceGeneration
                do { generation = try Self.sourceGeneration(root: root, relativePath: claim.relativePath) }
                catch is CancellationError { throw CancellationError() }
                catch {
                    try deferDirty(claim, root: root, now: now)
                    result.deferred += 1
                    continue
                }
                guard generation.size > 0, generation.size <= remainingBytes,
                      try admitsCaptureDisk(recording: &result.diskAdmission) else {
                    try deferDirty(claim, root: root, now: now)
                    result.deferred += 1
                    continue
                }
                guard let reservation = try owner.reserveCapture(claim, configuration: root, generation: generation) else {
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
        }
        // Both requests are direct collector -> replica. One replica's backoff,
        // authorization failure or ACK never supplies the other replica's proof.
        async let hq = upload(to: replicas[0], now: now)
        async let m1 = upload(to: replicas[1], now: now)
        let completed = try await (hq, m1)
        result.acknowledgedHQ = completed.0.acknowledged
        result.acknowledgedM1 = completed.1.acknowledged
        result.deferred += completed.0.deferred + completed.1.deferred
        return result
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

    private func deferDirty(_ claim: CollectorDirtyClaim, root: CollectorRootConfiguration, now: Int64) throws {
        let next = now.addingReportingOverflow(1)
        guard !next.overflow else { throw CollectorPublicationWorkerError.invalidBudget }
        _ = try owner.deferClaim(claim, configuration: root, retryNotBefore: next.partialValue, reason: .unavailable)
    }

    private func performCapture(
        _ reservation: CollectorCaptureReservation, root: CollectorRootConfiguration, maximumByteCount: Int64
    ) throws -> ArchiveCaptureResult {
        try Task.checkCancellation()
        try testHooks.beforeCapture?(reservation)
        guard try Self.sourceGeneration(root: root, relativePath: reservation.relativePath) == reservation.generation else {
            throw ExactSourceCapturerError.generationChanged
        }
        let source = URL(fileURLWithPath: root.rootPath).appendingPathComponent(reservation.relativePath)
        let descriptor = try ArchiveSourceDescriptor.singleFile(locator: source.path, sourceURL: source,
            replayRelativePath: reservation.relativePath)
        try testHooks.beforeCaptureFDAdmission?(reservation)
        let result = try ExactSourceCapturer(cas: cas, catalog: catalog, descriptor: descriptor)
            .capture(source: root.source, locator: source.path, machineID: catalog.machineID(),
                maximumByteCount: maximumByteCount, expectedGeneration: reservation.generation)
        guard result.manifest.generation == reservation.generation,
              result.capture.rawByteCount <= maximumByteCount else {
            throw ExactSourceCapturerError.generationChanged
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
        let page = try catalog.unboundCaptures(limit: maximum, after: after, through: boundary)
        remainingCandidates -= page.count
        let locator = URL(fileURLWithPath: root.rootPath).appendingPathComponent(reservation.relativePath).path
        for capture in page {
            try Task.checkCancellation()
            guard capture.source == root.source.rawValue, capture.locator.utf8.elementsEqual(locator.utf8),
                  capture.generation == reservation.generation else { continue }
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
        for claim in claims {
            try Task.checkCancellation()
            let bytes: Data
            do { bytes = try await transmit(claim, to: replica) }
            catch is CancellationError { throw CancellationError() }
            catch let error as CollectorPublicationWorkerError {
                try Task.checkCancellation()
                if error == .staleClaim { continue }
                let reason: CollectorPublicationDeferral
                switch error {
                case .withheld: reason = .privacyWithheld
                case .invalidCapture: reason = .localContentUnavailable
                case .invalidACK: reason = .invalidACK
                case .unsupportedReplica: reason = .unsupportedReplica
                default: reason = .unavailable
                }
                if try owner.deferPublication(claim, now: now, reason: reason) { deferred += 1 }
                continue
            }
            try testHooks.beforeACKCommit?(claim)
            try Task.checkCancellation()
            // SQL/storage failures propagate. They are not relabeled as network
            // retries, and a cancelled ACK never produces an index/receipt write.
            if try owner.recordPublicationACK(claim, canonicalBytes: bytes) { acknowledged += 1 }
        }
        return (acknowledged, deferred)
    }

    private func transmit(_ claim: CollectorPublicationClaim, to replica: CollectorReplicaEndpoint) async throws -> Data {
        guard let root = configuration(rootID: claim.intent.rootID, revision: claim.intent.rootRevision),
              let capture = try catalog.capture(captureID: claim.intent.captureID),
              capture.unboundManifestSHA256 == claim.intent.publication.manifestSHA256,
              capture.machineID == claim.intent.publication.machineID,
              capture.source == root.source.rawValue, capture.rawByteCount <= budget.maxCaptureBytes else {
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
            let sent = try await request(replica, path: "/v2/archive/objects/\(chunk.rawSHA256)", method: "PUT",
                body: object, capture: result, root: root, claim: claim, proof: proof)
            proof = sent.proof
        }
        let manifestSent = try await request(replica, path: "/v2/archive/manifests/\(capture.unboundManifestSHA256)", method: "PUT",
            body: capture.unboundManifestBytes, capture: result, root: root, claim: claim, proof: proof)
        let publicationSent = try await request(replica, path: "/v2/archive/publications/\(claim.intent.digest)", method: "PUT",
            body: claim.intent.canonicalBytes, capture: result, root: root, claim: claim, proof: manifestSent.proof)
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
        let format: SourceMetadataProjection.Format = root.source == .codex ? .codex : .claudeCode(forceClaudeCodeSource: false)
        if let prior, prior.isCurrent(for: capture, policy: current, format: format) { return prior }
        let assessment = try CollectorPrivacyProof.assess(capture: capture, cas: cas, format: format, policy: current,
            limits: .init(maxSourceBytes: budget.maxCaptureBytes))
        guard case .eligible(let proof) = assessment else { throw CollectorPublicationWorkerError.withheld }
        return proof
    }

    private func request(
        _ replica: CollectorReplicaEndpoint, path: String, method: String, body: Data?,
        capture: ArchiveCaptureResult, root: CollectorRootConfiguration,
        claim: CollectorPublicationClaim, proof: CollectorPrivacyProof
    ) async throws -> (bytes: Data, proof: CollectorPrivacyProof) {
        try Task.checkCancellation()
        try testHooks.beforeRequest?(replica.replicaID, path)
        let freshProof = try authorize(capture, root: root, prior: proof)
        guard try owner.isPublicationClaimCurrent(claim) else { throw CollectorPublicationWorkerError.staleClaim }
        try Task.checkCancellation()
        guard let url = URL(string: path, relativeTo: replica.baseURL)?.absoluteURL else {
            throw CollectorPublicationWorkerError.invalidConfiguration
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
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
        guard response.status == 200 || (method == "PUT" && response.status == 201) else {
            throw CollectorPublicationWorkerError.transport
        }
        let bytes = try testHooks.afterResponse?(replica.replicaID, path, response.bytes) ?? response.bytes
        guard bytes.count <= budget.maxResponseBytes else { throw CollectorPublicationWorkerError.responseTooLarge }
        return (bytes, freshProof)
    }

    private static func origin(_ replica: CollectorReplicaEndpoint) -> String {
        let scheme = replica.baseURL.scheme?.lowercased() ?? ""
        return scheme + "://" + (replica.baseURL.host?.lowercased() ?? "") + ":" + String(replica.baseURL.port ?? (scheme == "https" ? 443 : 80))
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

    private static func sourceGeneration(root: CollectorRootConfiguration, relativePath: String) throws -> ArchiveSourceGeneration {
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
        return try ArchiveSourceGeneration(device: Int64(info.st_dev), inode: inode, size: Int64(info.st_size),
            mtimeNs: nanoseconds(info.st_mtimespec), ctimeNs: nanoseconds(info.st_ctimespec), mode: Int64(info.st_mode))
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
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
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
