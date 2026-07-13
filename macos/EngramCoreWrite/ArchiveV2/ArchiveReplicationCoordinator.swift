import CryptoKit
import Darwin
import EngramCoreRead
import Foundation

public struct ArchiveReplicationCycleResult: Equatable, Sendable {
    public let claimed: Int
    public let verified: Int
    public let retryScheduled: Int
    public let quarantined: Int
    public let lostClaims: Int
    public let staleRecovered: Int
    public let reconciled: Int
    public let cancelled: Bool
    public let cycleError: String?
    public let pausedReplicaIDs: [String]
    public let verifiedByReplica: [String: Int]

    public init(
        claimed: Int = 0,
        verified: Int = 0,
        retryScheduled: Int = 0,
        quarantined: Int = 0,
        lostClaims: Int = 0,
        staleRecovered: Int = 0,
        reconciled: Int = 0,
        cancelled: Bool = false,
        cycleError: String? = nil,
        pausedReplicaIDs: [String] = [],
        verifiedByReplica: [String: Int] = [:]
    ) {
        self.claimed = claimed
        self.verified = verified
        self.retryScheduled = retryScheduled
        self.quarantined = quarantined
        self.lostClaims = lostClaims
        self.staleRecovered = staleRecovered
        self.reconciled = reconciled
        self.cancelled = cancelled
        self.cycleError = cycleError
        self.pausedReplicaIDs = pausedReplicaIDs.sorted()
        self.verifiedByReplica = verifiedByReplica.filter {
            ArchiveCatalog.currentReplicaIDs.contains($0.key) && $0.value >= 0
        }
    }
}

public struct ArchiveRetryJitter: Sendable {
    private let sampleUnit: @Sendable () -> Double

    public init(sampleUnit: @escaping @Sendable () -> Double = {
        Double.random(in: 0 ... 1)
    }) {
        self.sampleUnit = sampleUnit
    }

    public static func maximumDelay(failureNumber: Int) -> TimeInterval {
        let normalizedFailureNumber = max(failureNumber, 1)
        let exponent = min(normalizedFailureNumber - 1, 11)
        return min(86_400, 60 * pow(2, Double(exponent)))
    }

    static func failureNumber(afterAttempts attempts: Int) -> Int {
        let normalizedAttempts = max(attempts, 0)
        let (next, overflow) = normalizedAttempts.addingReportingOverflow(1)
        return overflow ? Int.max : next
    }

    public func delay(failureNumber: Int) -> TimeInterval {
        let sampled = sampleUnit()
        let unit = sampled.isFinite ? min(max(sampled, 0), 1) : 0
        return Self.maximumDelay(failureNumber: failureNumber) * unit
    }
}

public actor ArchiveReplicationCoordinator {
    private let catalog: ArchiveCatalog
    private let cas: ImmutableArchiveCAS
    private let backends: [String: any ArchiveReplicaBackend]
    private let clock: @Sendable () -> Date
    private let jitter: ArchiveRetryJitter
    private var isRunning = false
    private var attentionPausedReplicaIDs = Set<String>()

    public init(
        catalog: ArchiveCatalog,
        cas: ImmutableArchiveCAS,
        backends: [any ArchiveReplicaBackend],
        clock: @escaping @Sendable () -> Date = { Date() },
        jitter: ArchiveRetryJitter = ArchiveRetryJitter()
    ) throws {
        guard backends.count == 2,
              Set(backends.map(\.replicaID)) == Set(ArchiveCatalog.currentReplicaIDs) else {
            throw ArchiveReplicaConfigurationError.invalidReplicaSet
        }
        self.catalog = catalog
        self.cas = cas
        self.backends = Dictionary(
            uniqueKeysWithValues: backends.map { ($0.replicaID, $0) }
        )
        self.clock = clock
        self.jitter = jitter
    }

    public func runOnce(limit: Int) async -> ArchiveReplicationCycleResult {
        guard limit > 0 else {
            return ArchiveReplicationCycleResult(cycleError: "invalid_limit")
        }
        guard !isRunning else {
            return ArchiveReplicationCycleResult(cycleError: "already_running")
        }
        isRunning = true
        defer { isRunning = false }

        var cycle = CycleAccumulator()
        do {
            guard !Task.isCancelled else {
                cycle.cancelled = true
                return cycle.result
            }
            let cycleNow = timestamp(clock())
            guard !Task.isCancelled else {
                cycle.cancelled = true
                return cycle.result
            }
            cycle.staleRecovered = try catalog.recoverStaleInflight(
                now: cycleNow,
                olderThanSeconds: 600
            )
            guard !Task.isCancelled else {
                cycle.cancelled = true
                return cycle.result
            }
            cycle.reconciled = try catalog.reconcileEligibleReplicaRows(
                updatedAt: cycleNow
            )
            guard !Task.isCancelled else {
                cycle.cancelled = true
                return cycle.result
            }
            let claims = try catalog.claimReplicaWork(limit: limit, now: cycleNow)
            cycle.claimed = claims.count
            cycle.merge(try await processClaims(claims, stopOnInfrastructureFailure: false))
        } catch is CancellationError {
            cycle.cancelled = true
        } catch {
            cycle.cycleError = "catalog_failure"
        }
        return cycle.result
    }

    public func runBacklogPass(perReplicaLimit: Int) async -> ArchiveReplicationCycleResult {
        guard perReplicaLimit > 0 else {
            return ArchiveReplicationCycleResult(cycleError: "invalid_limit")
        }
        guard !isRunning else {
            return ArchiveReplicationCycleResult(cycleError: "already_running")
        }
        isRunning = true
        defer { isRunning = false }

        var cycle = CycleAccumulator()
        do {
            guard !Task.isCancelled else {
                cycle.cancelled = true
                return cycle.result
            }
            let cycleNow = timestamp(clock())
            cycle.staleRecovered = try catalog.recoverStaleInflight(
                now: cycleNow,
                olderThanSeconds: 600
            )
            cycle.reconciled = try catalog.reconcileEligibleReplicaRows(
                updatedAt: cycleNow
            )
            let retryQuota = perReplicaLimit / 2
            cycle.pausedReplicaIDs = Array(attentionPausedReplicaIDs)
            let hqClaims = attentionPausedReplicaIDs.contains("hq")
                ? []
                : try catalog.claimReplicaWork(
                    replicaID: "hq",
                    limit: perReplicaLimit,
                    retryQuota: retryQuota,
                    now: cycleNow
                )
            let m1Claims = attentionPausedReplicaIDs.contains("m1")
                ? []
                : try catalog.claimReplicaWork(
                    replicaID: "m1",
                    limit: perReplicaLimit,
                    retryQuota: retryQuota,
                    now: cycleNow
                )
            cycle.claimed = hqClaims.count + m1Claims.count

            async let hq = processClaims(
                hqClaims,
                stopOnInfrastructureFailure: true
            )
            async let m1 = processClaims(
                m1Claims,
                stopOnInfrastructureFailure: true
            )
            let batches = try await (hq, m1)
            cycle.merge(batches.0)
            cycle.merge(batches.1)
            attentionPausedReplicaIDs.formUnion(cycle.pausedReplicaIDs)
        } catch is CancellationError {
            cycle.cancelled = true
        } catch {
            cycle.cycleError = "catalog_failure"
        }
        return cycle.result
    }

    public func retryQuarantined(replicaID: String?) throws {
        guard !Task.isCancelled else { throw CancellationError() }
        _ = try catalog.retryQuarantined(
            replicaID: replicaID,
            now: timestamp(clock())
        )
        if let replicaID {
            attentionPausedReplicaIDs.remove(replicaID)
        } else {
            attentionPausedReplicaIDs.removeAll()
        }
    }

    public func resumeAfterAttention(replicaID: String?) {
        if let replicaID {
            attentionPausedReplicaIDs.remove(replicaID)
        } else {
            attentionPausedReplicaIDs.removeAll()
        }
    }

    private func processClaims(
        _ claims: [ArchiveReplicaClaim],
        stopOnInfrastructureFailure: Bool
    ) async throws -> CycleAccumulator {
        var cycle = CycleAccumulator()
        let transientInfrastructure = Set([
            "transport_timeout",
            "transport_network",
            "remote_rate_limited",
            "remote_server_unavailable",
        ])
        let attentionInfrastructure = Set([
            "remote_auth_rejected",
            "replica_configuration_failure",
        ])

        for (index, claim) in claims.enumerated() {
            guard !Task.isCancelled else {
                cycle.cancelled = true
                break
            }
            guard let backend = backends[claim.replicaID] else {
                cycle.cycleError = "replica_configuration_failure"
                cycle.pausedReplicaIDs.append(claim.replicaID)
                _ = try catalog.releaseUnstartedReplicaClaims(
                    Array(claims[index...]),
                    updatedAt: timestamp(clock())
                )
                break
            }

            let outcome = try await replicate(claim, to: backend)
            guard !Task.isCancelled else {
                cycle.cancelled = true
                return cycle
            }
            switch outcome {
            case .verified:
                cycle.verified += 1
                cycle.verifiedByReplica[claim.replicaID, default: 0] += 1
            case .lostClaim:
                cycle.lostClaims += 1
            case .cancelled:
                cycle.cancelled = true
                return cycle
            case let .failed(action, symbol, state):
                let changed: Bool
                let failureDate = clock()
                let failureAt = timestamp(failureDate)
                switch action {
                case .retry:
                    let delay = jitter.delay(
                        failureNumber: ArchiveRetryJitter.failureNumber(
                            afterAttempts: claim.attempts
                        )
                    )
                    guard !Task.isCancelled else {
                        cycle.cancelled = true
                        return cycle
                    }
                    changed = try catalog.markReplicaRetry(
                        claim,
                        from: state,
                        nextRetryAt: timestamp(failureDate.addingTimeInterval(delay)),
                        lastError: symbol,
                        updatedAt: failureAt
                    )
                    if changed { cycle.retryScheduled += 1 }
                case .quarantine:
                    guard !Task.isCancelled else {
                        cycle.cancelled = true
                        return cycle
                    }
                    changed = try catalog.markReplicaQuarantined(
                        claim,
                        from: state,
                        lastError: symbol,
                        updatedAt: failureAt
                    )
                    if changed { cycle.quarantined += 1 }
                }
                if !changed { cycle.lostClaims += 1 }
                if attentionInfrastructure.contains(symbol) {
                    cycle.pausedReplicaIDs.append(claim.replicaID)
                }
                if stopOnInfrastructureFailure,
                   transientInfrastructure.contains(symbol)
                    || attentionInfrastructure.contains(symbol) {
                    _ = try catalog.releaseUnstartedReplicaClaims(
                        Array(claims.dropFirst(index + 1)),
                        updatedAt: timestamp(clock())
                    )
                    return cycle
                }
            }
        }
        return cycle
    }

    private func replicate(
        _ claim: ArchiveReplicaClaim,
        to backend: any ArchiveReplicaBackend
    ) async throws -> ClaimOutcome {
        guard !Task.isCancelled else { return .cancelled }

        let manifestBytes: Data
        do {
            manifestBytes = try cas.readManifest(sha256: claim.manifestSHA256)
        } catch {
            return localFailure(error, kind: .manifest, state: .uploadingObjects)
        }
        guard manifestBytes.count <= ArchiveV2ProtocolLimits.maxManifestBytes else {
            return .failed(.quarantine, "local_manifest_corrupt", .uploadingObjects)
        }
        guard manifestBytes == claim.canonicalManifestBytes else {
            return .failed(.quarantine, "local_binding_mismatch", .uploadingObjects)
        }

        let manifest: ArchiveSourceManifest
        do {
            manifest = try ArchiveCanonicalJSON.decode(
                ArchiveSourceManifest.self,
                from: manifestBytes
            )
        } catch {
            return .failed(.quarantine, "local_manifest_corrupt", .uploadingObjects)
        }
        let machineID = try catalog.machineID()
        guard ArchiveV2Hash.sha256(manifestBytes) == claim.manifestSHA256,
              manifest.captureID == claim.captureID,
              manifest.sessionID == claim.sessionID,
              manifest.machineID == machineID else {
            return .failed(.quarantine, "local_binding_mismatch", .uploadingObjects)
        }

        var wholeSourceHasher = SHA256()
        for chunk in manifest.chunks {
            guard !Task.isCancelled else { return .cancelled }
            let objectBytes: Data
            do {
                objectBytes = try cas.readObject(sha256: chunk.rawSHA256)
            } catch {
                return localFailure(error, kind: .object, state: .uploadingObjects)
            }
            guard Int64(objectBytes.count) == chunk.rawByteCount else {
                return .failed(
                    .quarantine,
                    "local_object_size_mismatch",
                    .uploadingObjects
                )
            }
            guard ArchiveV2Hash.sha256(objectBytes) == chunk.rawSHA256 else {
                return .failed(.quarantine, "local_object_corrupt", .uploadingObjects)
            }
            wholeSourceHasher.update(data: objectBytes)

            let objectExists: Bool
            do {
                objectExists = try await backend.headObject(digest: chunk.rawSHA256)
            } catch {
                return remoteFailure(error, state: .uploadingObjects)
            }
            guard !Task.isCancelled else { return .cancelled }
            if !objectExists {
                do {
                    try await backend.putObject(
                        digest: chunk.rawSHA256,
                        data: objectBytes
                    )
                } catch {
                    return remoteFailure(error, state: .uploadingObjects)
                }
                guard !Task.isCancelled else { return .cancelled }
            }
            guard !Task.isCancelled else { return .cancelled }
            guard try catalog.heartbeatReplicaClaim(
                claim,
                state: .uploadingObjects,
                at: timestamp(clock())
            ) else {
                return .lostClaim
            }
        }

        guard Self.hexDigest(wholeSourceHasher.finalize())
            == manifest.wholeSourceSHA256 else {
            return .failed(
                .quarantine,
                "local_whole_hash_mismatch",
                .uploadingObjects
            )
        }
        guard !Task.isCancelled else { return .cancelled }
        guard try catalog.transitionReplicaClaim(
            claim,
            from: .uploadingObjects,
            to: .uploadingManifest,
            updatedAt: timestamp(clock())
        ) else {
            return .lostClaim
        }

        let manifestExists: Bool
        do {
            manifestExists = try await backend.headManifest(
                digest: claim.manifestSHA256
            )
        } catch {
            return remoteFailure(error, state: .uploadingManifest)
        }
        guard !Task.isCancelled else { return .cancelled }
        if !manifestExists {
            do {
                try await backend.putManifest(
                    digest: claim.manifestSHA256,
                    data: manifestBytes
                )
            } catch {
                return remoteFailure(error, state: .uploadingManifest)
            }
            guard !Task.isCancelled else { return .cancelled }
        }
        guard !Task.isCancelled else { return .cancelled }
        guard try catalog.transitionReplicaClaim(
            claim,
            from: .uploadingManifest,
            to: .requestingReceipt,
            updatedAt: timestamp(clock())
        ) else {
            return .lostClaim
        }

        do {
            _ = try await backend.createReceipt(
                manifestDigest: claim.manifestSHA256
            )
        } catch {
            return remoteFailure(error, state: .requestingReceipt)
        }
        guard !Task.isCancelled else { return .cancelled }
        guard try catalog.transitionReplicaClaim(
            claim,
            from: .requestingReceipt,
            to: .verifyingReceipt,
            updatedAt: timestamp(clock())
        ) else {
            return .lostClaim
        }

        let receiptBytes: Data
        do {
            receiptBytes = try await backend.getReceipt(
                manifestDigest: claim.manifestSHA256
            )
        } catch {
            return remoteFailure(
                error,
                state: .verifyingReceipt,
                isReceiptRead: true
            )
        }
        guard !Task.isCancelled else { return .cancelled }
        guard receiptBytes.count <= ArchiveV2ProtocolLimits.maxReceiptBytes else {
            return .failed(
                .quarantine,
                "remote_response_too_large",
                .verifyingReceipt
            )
        }

        let receipt: ArchiveServerReceipt
        do {
            receipt = try ArchiveCanonicalJSON.decode(
                ArchiveServerReceipt.self,
                from: receiptBytes
            )
        } catch {
            return .failed(
                .quarantine,
                "remote_receipt_noncanonical",
                .verifyingReceipt
            )
        }
        do {
            guard receipt.serverID == claim.replicaID else {
                return .failed(
                    .quarantine,
                    "remote_receipt_mismatch",
                    .verifyingReceipt
                )
            }
            try receipt.validate(againstCanonicalManifestBytes: manifestBytes)
        } catch {
            return .failed(
                .quarantine,
                "remote_receipt_mismatch",
                .verifyingReceipt
            )
        }

        guard !Task.isCancelled else { return .cancelled }
        let verifiedAt = timestamp(clock())
        guard !Task.isCancelled else { return .cancelled }
        let verified = try catalog.recordVerifiedReceipt(
            claim,
            receipt: ArchiveVerifiedReceipt(
                canonicalBytes: receiptBytes,
                sha256: ArchiveV2Hash.sha256(receiptBytes),
                verifiedAt: verifiedAt
            ),
            updatedAt: verifiedAt
        )
        return verified ? .verified : .lostClaim
    }

    private func localFailure(
        _ error: Error,
        kind: LocalPayloadKind,
        state: ArchiveReplicaState
    ) -> ClaimOutcome {
        guard let casError = error as? ImmutableArchiveCASError else {
            return .failed(
                .quarantine,
                kind == .manifest ? "local_manifest_corrupt" : "local_object_corrupt",
                state
            )
        }
        switch casError {
        case let .io(_, code) where code == ENOENT:
            return .failed(
                .quarantine,
                kind == .manifest ? "local_manifest_missing" : "local_object_missing",
                state
            )
        case .digestMismatch, .existingContentConflict, .unsafeExistingPath, .invalidSHA256:
            return .failed(
                .quarantine,
                kind == .manifest ? "local_manifest_corrupt" : "local_object_corrupt",
                state
            )
        case let .io(_, code):
            if Self.isTemporaryLocalIO(code) {
                return .failed(.retry, "local_io_unavailable", state)
            }
            return .failed(
                .quarantine,
                kind == .manifest ? "local_manifest_corrupt" : "local_object_corrupt",
                state
            )
        }
    }

    private func remoteFailure(
        _ error: Error,
        state: ArchiveReplicaState,
        isReceiptRead: Bool = false
    ) -> ClaimOutcome {
        guard !Task.isCancelled else { return .cancelled }
        guard let backendError = error as? ArchiveReplicaBackendError else {
            if error is CancellationError {
                return .cancelled
            }
            return .failed(.quarantine, "remote_protocol_contradiction", state)
        }
        switch backendError {
        case .transport(.cancelled):
            return .cancelled
        case .transport(.timedOut):
            return .failed(.retry, "transport_timeout", state)
        case .transport(.network):
            return .failed(.retry, "transport_network", state)
        case .transport(.tls):
            return .failed(.quarantine, "transport_tls", state)
        case let .unexpectedStatus(status) where isReceiptRead && status == 404:
            return .failed(.quarantine, "remote_receipt_missing", state)
        case .unexpectedStatus(408):
            return .failed(.retry, "transport_timeout", state)
        case .unexpectedStatus(429):
            return .failed(.retry, "remote_rate_limited", state)
        case let .unexpectedStatus(status) where (500 ... 599).contains(status):
            return .failed(.retry, "remote_server_unavailable", state)
        case .unexpectedStatus(401), .unexpectedStatus(403):
            return .failed(.quarantine, "remote_auth_rejected", state)
        case .redirectRejected, .finalURLMismatch:
            return .failed(.quarantine, "remote_origin_violation", state)
        case .unexpectedStatus(409):
            return .failed(.quarantine, "remote_content_conflict", state)
        case .unexpectedStatus(422):
            return .failed(.quarantine, "remote_invalid_content", state)
        case .responseTooLarge:
            return .failed(.quarantine, "remote_response_too_large", state)
        case .invalidDigest,
             .invalidRequest,
             .notHTTPResponse,
             .invalidCanonicalResponse,
             .telemetryUnsupported,
             .unexpectedStatus:
            return .failed(.quarantine, "remote_protocol_contradiction", state)
        }
    }

    private func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func hexDigest(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func isTemporaryLocalIO(_ code: Int32) -> Bool {
        switch code {
        case EAGAIN, EBUSY, EINTR, EIO, EMFILE, ENFILE, ESTALE, ETIMEDOUT:
            true
        default:
            false
        }
    }
}

private enum FailureAction {
    case retry
    case quarantine
}

private enum LocalPayloadKind {
    case object
    case manifest
}

private enum ClaimOutcome {
    case verified
    case lostClaim
    case cancelled
    case failed(FailureAction, String, ArchiveReplicaState)
}

private struct CycleAccumulator {
    var claimed = 0
    var verified = 0
    var retryScheduled = 0
    var quarantined = 0
    var lostClaims = 0
    var staleRecovered = 0
    var reconciled = 0
    var cancelled = false
    var cycleError: String?
    var pausedReplicaIDs: [String] = []
    var verifiedByReplica: [String: Int] = [:]

    mutating func merge(_ other: CycleAccumulator) {
        verified += other.verified
        retryScheduled += other.retryScheduled
        quarantined += other.quarantined
        lostClaims += other.lostClaims
        cancelled = cancelled || other.cancelled
        if cycleError == nil { cycleError = other.cycleError }
        pausedReplicaIDs.append(contentsOf: other.pausedReplicaIDs)
        for (replicaID, count) in other.verifiedByReplica {
            verifiedByReplica[replicaID, default: 0] += count
        }
    }

    var result: ArchiveReplicationCycleResult {
        ArchiveReplicationCycleResult(
            claimed: claimed,
            verified: verified,
            retryScheduled: retryScheduled,
            quarantined: quarantined,
            lostClaims: lostClaims,
            staleRecovered: staleRecovered,
            reconciled: reconciled,
            cancelled: cancelled,
            cycleError: cycleError,
            pausedReplicaIDs: Array(Set(pausedReplicaIDs)).sorted(),
            verifiedByReplica: verifiedByReplica
        )
    }
}
