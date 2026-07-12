import EngramCoreWrite
import Foundation

extension EngramServiceCommandHandler {
    func archiveReclamationStatusResponse() async throws -> EngramServiceArchiveReclamationStatusResponse {
        guard let coordinator = archiveV2Coordinator?.reclamationCoordinatorSnapshot else {
            return .init(enabled: false, hotWindowDays: 30, configurationError: nil, recoveryLeaseCurrent: false, cycleRunning: false, lastError: "archive_v2_disabled")
        }
        return await coordinator.status()
    }

    func archiveReclamationPreviewResponse() async throws -> EngramServiceArchiveReclamationPreviewResponse {
        guard let coordinator = archiveV2Coordinator?.reclamationCoordinatorSnapshot else {
            return .init(eligibleCount: 0, estimatedSourceBytes: 0, blockedCounts: ["archive_v2_disabled": 1])
        }
        return await coordinator.preview()
    }

    func archiveReclamationUpdateSettingsResponse(
        _ request: EngramServiceArchiveReclamationUpdateSettingsRequest
    ) async throws -> EngramServiceArchiveReclamationStatusResponse {
        guard let coordinator = archiveV2Coordinator?.reclamationCoordinatorSnapshot else {
            throw EngramServiceError.serviceUnavailable(message: "Archive reclamation unavailable")
        }
        return try await coordinator.updateSettings(request)
    }

    func archiveReclamationRunResponse() async throws -> EngramServiceArchiveReclamationRunResponse {
        guard let coordinator = archiveV2Coordinator?.reclamationCoordinatorSnapshot else {
            return .init(accepted: false, coalesced: false, sourceFilesReclaimed: 0, casObjectsEvicted: 0, releasedBytes: 0, error: "archive_v2_disabled")
        }
        return await coordinator.runNow()
    }

    func archiveV2RecoveryDrillResponse(
        _ request: EngramServiceArchiveV2RecoveryDrillRequest
    ) async throws -> EngramServiceArchiveV2RecoveryDrillResponse {
        guard request.replicaID == "hq" || request.replicaID == "m1",
              let archiveV2Coordinator else {
            throw EngramServiceError.invalidRequest(message: "Invalid archive recovery drill")
        }
        do {
            let lease = try await archiveV2Coordinator.runRecoveryDrill(replicaID: request.replicaID)
            return .init(replicaID: lease.replicaID, manifestSHA256: lease.manifestSHA256, verifiedAt: lease.verifiedAt, verifiedBytes: lease.verifiedBytes)
        } catch {
            throw EngramServiceError.serviceUnavailable(message: "Archive recovery drill unavailable")
        }
    }

    func archiveV2RemoteRecoveryProbeResponse(
        _ request: EngramServiceArchiveV2RemoteRecoveryProbeRequest
    ) async throws -> EngramServiceArchiveV2RemoteRecoveryProbeResponse {
        guard let archiveTranscriptResolver else {
            throw EngramServiceError.serviceUnavailable(
                message: "Archive recovery unavailable"
            )
        }
        do {
            let proof = try await archiveTranscriptResolver.remoteRecoveryProbe(
                sessionID: request.sessionId
            )
            return try EngramServiceArchiveV2RemoteRecoveryProbeResponse(
                tier: proof.tier.rawValue,
                receiptSHA256: proof.receiptSHA256,
                manifestSHA256: proof.manifestSHA256,
                wholeSourceSHA256: proof.wholeSourceSHA256
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw EngramServiceError.serviceUnavailable(
                message: "Archive recovery unavailable"
            )
        }
    }

    func archiveV2StoreTokenResponse(
        _ request: EngramServiceArchiveV2StoreTokenRequest
    ) async throws -> EngramServiceArchiveV2StoreTokenResponse {
        do {
            return try await archiveV2CredentialProvisioner.store(
                token: request.token,
                replicaID: request.replicaID
            )
        } catch is ArchiveV2CredentialProvisionerError {
            throw EngramServiceError.invalidRequest(message: "Invalid archive credential")
        } catch let error as ArchiveCredentialStoreError {
            switch error {
            case .invalidReplicaID, .invalidToken:
                throw EngramServiceError.invalidRequest(message: "Invalid archive credential")
            case .keychainStatus:
                throw EngramServiceError.serviceUnavailable(message: "Archive credential store unavailable")
            }
        } catch {
            throw EngramServiceError.serviceUnavailable(message: "Archive credential store unavailable")
        }
    }

    func archiveV2StatusResponse() async throws -> EngramServiceArchiveV2StatusResponse {
        if let archiveV2Coordinator {
            return await archiveV2Coordinator.status()
        }
        return try Self.archiveV2DisabledStatusResponse()
    }

    func archiveV2RetryResponse(
        _ request: EngramServiceArchiveV2RetryRequest
    ) async throws -> EngramServiceArchiveV2RetryResponse {
        guard let archiveV2Coordinator else {
            return try EngramServiceArchiveV2RetryResponse(
                accepted: false,
                resetRows: 0,
                error: "archive_v2_disabled"
            )
        }
        return await archiveV2Coordinator.retryQuarantined(
            replicaID: request.replicaID
        )
    }

    private static func archiveV2DisabledStatusResponse() throws
        -> EngramServiceArchiveV2StatusResponse
    {
        let replicas = try ["hq", "m1"].map { replicaID in
            try EngramServiceArchiveV2ReplicaStatus(
                replicaID: replicaID,
                queuedCount: 0,
                retryingCount: 0,
                quarantinedCount: 0,
                verifiedCount: 0
            )
        }
        return try EngramServiceArchiveV2StatusResponse(
            enabled: false,
            localCaptureEnabled: false,
            remoteReplicationEnabled: false,
            configurationError: nil,
            capturedCount: 0,
            boundCount: 0,
            unboundCount: 0,
            remotePolicyUnknownCount: 0,
            remotePolicyEligibleCount: 0,
            remotePolicyExcludedCount: 0,
            unsupportedLocatorCount: 0,
            unsafeLocatorCount: 0,
            replicas: replicas,
            singleReplicaVerifiedCount: 0,
            dualReplicaVerifiedCount: 0,
            latestReceipts: [],
            lastCaptureError: nil,
            lastReplicationError: nil,
            cycleRunning: false,
            cycleCoalesced: false
        )
    }
}
