import EngramCoreWrite
import Foundation

extension EngramServiceCommandHandler {
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
