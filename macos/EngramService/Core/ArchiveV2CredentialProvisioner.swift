import EngramCoreWrite
import Foundation

enum ArchiveV2CredentialProvisionerError: Error, Equatable {
    case invalidReplicaID
    case invalidToken
    case duplicateReplicaToken
    case verificationFailed
}

actor ArchiveV2CredentialProvisioner {
    typealias Load = @Sendable (String) async throws -> String?
    typealias Save = @Sendable (String, String) async throws -> Void

    private let load: Load
    private let save: Save

    init(
        load: @escaping Load = { replicaID in try ArchiveCredentialStore().loadToken(replicaID: replicaID) },
        save: @escaping Save = { token, replicaID in try ArchiveCredentialStore().saveToken(token, replicaID: replicaID) }
    ) {
        self.load = load
        self.save = save
    }

    func store(token: String, replicaID: String) async throws -> EngramServiceArchiveV2StoreTokenResponse {
        guard replicaID == "hq" || replicaID == "m1" else {
            throw ArchiveV2CredentialProvisionerError.invalidReplicaID
        }
        guard let decoded = Data(base64Encoded: token), decoded.count == 32,
              decoded.base64EncodedString() == token else {
            throw ArchiveV2CredentialProvisionerError.invalidToken
        }
        let otherReplicaID = replicaID == "hq" ? "m1" : "hq"
        if try await load(otherReplicaID) == token {
            throw ArchiveV2CredentialProvisionerError.duplicateReplicaToken
        }
        try await save(token, replicaID)
        let storedToken = try await load(replicaID)
        let otherToken = try await load(otherReplicaID)
        guard storedToken == token else {
            throw ArchiveV2CredentialProvisionerError.verificationFailed
        }
        if otherToken == token {
            throw ArchiveV2CredentialProvisionerError.duplicateReplicaToken
        }
        return EngramServiceArchiveV2StoreTokenResponse(
            replicaID: replicaID,
            stored: true,
            pairReady: otherToken != nil,
            serviceRestartRequired: true
        )
    }
}
