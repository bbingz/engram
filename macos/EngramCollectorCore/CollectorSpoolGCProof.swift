import CryptoKit
import Darwin
import Foundation

/// Metadata only. The private operator file and its explicit hash bind approval;
/// no token, encryption key or source body is serialized here.
struct CollectorSpoolGCApproval: Codable {
    struct Replica: Codable {
        let serverID: String
        let endpoint: String
        let physicalHostID: String
        let storeIdentity: String
        let journalID: String
        let verifiedAt: Int64
        let acceptanceSHA256: [String: String]
        let manifests: [String: String] // manifest -> whole reconstructed SHA
        let objects: [String: Int64]
    }
    struct Escrow: Codable {
        let locationIdentity: String
        let protectedSetSHA256: String
        let verifiedAt: Int64
        let expiresAt: Int64
        let pKeyEvidenceID: String
        let replicaRestoreDrillIDs: [String: String]
        let objects: [String]
        let manifests: [String]
    }
    var schemaVersion = 1
    var verifierBuildID: String
    var centralInstanceIdentity: String
    var policyVersion = 1
    var action: String
    var runID: String
    var nonce: String
    var machineID: String
    var spoolIdentity: String
    var scopeSHA256: String
    var configurationSHA256: String
    var policySHA256: String
    var nativeSHA256: String
    var createdAt: Int64
    var expiresAt: Int64
    var freshAt: Int64
    var maxBytes: Int64
    var maxObjects: Int
    var holdSeconds: Int64
    var legacyAbsentReferenceSHA256: String? = nil
    var selectedDigests: [String]? = nil
    var central: CollectorSpoolGCPreview.Evidence
    var replicas: [Replica]
    var escrow: Escrow

    func bytes() throws -> Data { try ArchiveCanonicalJSON.encode(self) }
    func sha256() throws -> String { ArchiveV2Hash.sha256(try bytes()) }

    static func load(_ url: URL, approvedSHA256: String) throws -> (Self, Data) {
        guard ArchiveV2Hash.isValidSHA256(approvedSHA256),
              (try? CollectorMachineIdentityReader.canonicalExistingPath(url)) != nil else { throw CollectorSpoolGCError.invalidEvidence }
        var parent = stat()
        guard lstat(url.deletingLastPathComponent().path, &parent) == 0,
              parent.st_mode & S_IFMT == S_IFDIR, parent.st_uid == geteuid(), parent.st_mode & 0o077 == 0,
              let data = SecureRegularFile.read(atPath: url.path, maximumBytes: 256 * 1024 * 1024, repairPermissions: false),
              ArchiveV2Hash.sha256(data) == approvedSHA256,
              let result = try? ArchiveCanonicalJSON.decode(Self.self, from: data) else { throw CollectorSpoolGCError.invalidEvidence }
        return (result, data)
    }

    func validateTime(now: Int64) throws {
        guard schemaVersion == 1, policyVersion == 1,
              (1...256).contains(verifierBuildID.utf8.count), (1...4096).contains(centralInstanceIdentity.utf8.count),
              ["apply", "finalize"].contains(action), UUID(uuidString: runID) != nil,
              UUID(uuidString: nonce) != nil, UUID(uuidString: machineID) != nil,
              maxBytes >= 0, maxObjects >= 0, maxObjects <= 250_000, holdSeconds >= 14 * 86400,
              holdSeconds <= 365 * 86400, now >= 0, now <= Int64.max - 365 * 86400, createdAt >= 0, freshAt >= createdAt,
              createdAt <= now, freshAt <= now, now - freshAt <= 300,
              expiresAt >= now, expiresAt - createdAt <= 30 * 86400,
              [scopeSHA256, configurationSHA256, policySHA256, nativeSHA256].allSatisfy(ArchiveV2Hash.isValidSHA256),
              legacyAbsentReferenceSHA256.map(ArchiveV2Hash.isValidSHA256) ?? true,
              selectedDigests.map({ !$0.isEmpty && $0.count <= maxObjects && $0 == Set($0).sorted() && $0.allSatisfy(ArchiveV2Hash.isValidSHA256) }) ?? true
        else { throw CollectorSpoolGCError.invalidEvidence }
        guard replicas.count == 2, Set(replicas.map(\.serverID)) == ["hq", "m1"],
              Set(replicas.map(\.physicalHostID)).count == 2, Set(replicas.map(\.storeIdentity)).count == 2,
              Set(replicas.map(\.endpoint)).count == 2 else { throw CollectorSpoolGCError.proofMissing }
        for replica in replicas {
            guard Self.validEndpoint(replica.endpoint), !replica.physicalHostID.isEmpty, !replica.storeIdentity.isEmpty,
                  UUID(uuidString: replica.journalID) != nil, replica.verifiedAt >= 0,
                  replica.verifiedAt <= now, now - replica.verifiedAt <= 30 * 86400,
                  replica.acceptanceSHA256.count <= 250_000, replica.objects.count <= 2_000_000,
                  replica.manifests.count <= 250_000 else { throw CollectorSpoolGCError.proofMissing }
        }
        guard central.schemaVersion == 1, central.parserRevision == "swift-capture-v1",
              central.publications.count <= 250_000,
              Set(central.publications.map(\.publicationSHA256)).count == central.publications.count,
              let stamp = ISO8601DateFormatter().date(from: central.generatedAt),
              stamp.timeIntervalSince1970 <= Double(now), Double(now) - stamp.timeIntervalSince1970 <= 300
        else { throw CollectorSpoolGCError.invalidEvidence }
        guard escrow.objects == Set(escrow.objects).sorted(), escrow.manifests == Set(escrow.manifests).sorted(),
              escrow.objects.count <= 2_000_000, escrow.manifests.count <= 250_000,
              escrow.objects.allSatisfy(ArchiveV2Hash.isValidSHA256), escrow.manifests.allSatisfy(ArchiveV2Hash.isValidSHA256),
              !escrow.locationIdentity.isEmpty, !escrow.pKeyEvidenceID.isEmpty,
              escrow.verifiedAt >= 0, escrow.verifiedAt <= now, escrow.expiresAt >= now,
              now - escrow.verifiedAt <= 30 * 86400,
              Set(escrow.replicaRestoreDrillIDs.keys) == ["hq", "m1"],
              escrow.replicaRestoreDrillIDs.values.allSatisfy({ !$0.isEmpty }) else { throw CollectorSpoolGCError.escrowMissing }
    }

    static func validEndpoint(_ value: String) -> Bool {
        guard let url = URL(string: value), let host = url.host, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else { return false }
        return url.scheme == "https" || (url.scheme == "http" && ["127.0.0.1", "::1", "[::1]", "localhost"].contains(host))
    }
}

/// GET-only K9 algorithm. The caller owns transport authorization. Tests supply
/// fake replicas; this type cannot discover credentials or perform a mutation.
enum CollectorSpoolGCVerifier {
    struct Target {
        let serverID: String
        let endpoint: String
        let physicalHostID: String
        let storeIdentity: String
    }
    static func readBack(
        publications: [CollectorPublicationEnvelope], manifests: [String: ArchiveSourceManifest],
        expectedACKs: [String: [String: CollectorPublicationACK]], targets: [Target], now: Int64,
        maximumBytes: Int64 = 4 * 1024 * 1024 * 1024,
        get: (Target, String, Int) async throws -> Data
    ) async throws -> [CollectorSpoolGCApproval.Replica] {
        guard now >= 0, maximumBytes >= 0, !publications.isEmpty, publications.count <= 250_000,
              targets.count == 2, Set(targets.map(\.serverID)) == ["hq", "m1"],
              Set(targets.map(\.physicalHostID)).count == 2, Set(targets.map(\.storeIdentity)).count == 2,
              Set(targets.map(\.endpoint)).count == 2,
              targets.allSatisfy({ !$0.physicalHostID.isEmpty && !$0.storeIdentity.isEmpty }),
              targets.allSatisfy({ CollectorSpoolGCApproval.validEndpoint($0.endpoint) }) else { throw CollectorSpoolGCError.proofMissing }
        let started = ProcessInfo.processInfo.systemUptime
        var remaining = maximumBytes, proofs: [CollectorSpoolGCApproval.Replica] = []
        for target in targets {
            var journal: String?, acceptances: [String: String] = [:], covered: [String: String] = [:], objects: [String: Int64] = [:]
            for publication in publications {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime - started <= 300 else { throw CollectorSpoolGCError.budgetExceeded }
                let digest = try publication.sha256()
                let accepted = try await get(target, "/v2/archive/publications/\(digest)", CollectorPublicationProtocolLimits.maxAcceptanceRecordBytes)
                guard accepted.count <= CollectorPublicationProtocolLimits.maxAcceptanceRecordBytes,
                      Int64(accepted.count) <= remaining,
                      let record = try? ArchiveCanonicalJSON.decode(CollectorPublicationAcceptanceRecord.self, from: accepted),
                      record.publication == publication, record.ack == expectedACKs[target.serverID]?[digest],
                      record.ack.serverID == target.serverID,
                      journal == nil || journal == record.ack.journalID else { throw CollectorSpoolGCError.proofMissing }
                remaining -= Int64(accepted.count); journal = record.ack.journalID
                acceptances[digest] = ArchiveV2Hash.sha256(accepted)
                guard let manifest = manifests[publication.manifestSHA256], manifest.machineID == publication.machineID, manifest.sessionID == nil else { throw CollectorSpoolGCError.proofMissing }
                let bytes = try await get(target, "/v2/archive/manifests/\(publication.manifestSHA256)", ArchiveV2ProtocolLimits.maxManifestBytes)
                guard bytes.count <= ArchiveV2ProtocolLimits.maxManifestBytes, Int64(bytes.count) <= remaining,
                      try bytes == ArchiveCanonicalJSON.encode(manifest), ArchiveV2Hash.sha256(bytes) == publication.manifestSHA256 else {
                    throw CollectorSpoolGCError.proofMissing
                }
                remaining -= Int64(bytes.count)
                var whole = SHA256(), offset: Int64 = 0
                let parts = manifest.replayLayout.files ?? []
                var partHashes = parts.map { _ in SHA256() }
                for chunk in manifest.chunks {
                    guard ProcessInfo.processInfo.systemUptime - started <= 300, chunk.rawByteCount <= Int64(Int.max), chunk.rawByteCount <= remaining else { throw CollectorSpoolGCError.budgetExceeded }
                    let raw = try await get(target, "/v2/archive/objects/\(chunk.rawSHA256)", Int(chunk.rawByteCount))
                    guard Int64(raw.count) == chunk.rawByteCount, ArchiveV2Hash.sha256(raw) == chunk.rawSHA256,
                          objects[chunk.rawSHA256] == nil || objects[chunk.rawSHA256] == chunk.rawByteCount else { throw CollectorSpoolGCError.proofMissing }
                    remaining -= chunk.rawByteCount; whole.update(data: raw)
                    for (index, part) in parts.enumerated() {
                        let lower = max(offset, part.byteOffset), upper = min(offset + chunk.rawByteCount, part.byteOffset + part.rawByteCount)
                        if lower < upper { partHashes[index].update(data: raw.subdata(in: Int(lower - offset)..<Int(upper - offset))) }
                    }
                    offset += chunk.rawByteCount; objects[chunk.rawSHA256] = chunk.rawByteCount
                }
                guard offset == manifest.rawByteCount,
                      whole.finalize().map({ String(format: "%02x", $0) }).joined() == manifest.wholeSourceSHA256 else { throw CollectorSpoolGCError.proofMissing }
                for (index, part) in parts.enumerated() {
                    guard partHashes[index].finalize().map({ String(format: "%02x", $0) }).joined() == part.wholeSourceSHA256 else { throw CollectorSpoolGCError.proofMissing }
                }
                covered[publication.manifestSHA256] = manifest.wholeSourceSHA256
            }
            guard let journal else { throw CollectorSpoolGCError.proofMissing }
            proofs.append(.init(serverID: target.serverID, endpoint: target.endpoint, physicalHostID: target.physicalHostID,
                storeIdentity: target.storeIdentity, journalID: journal, verifiedAt: now,
                acceptanceSHA256: acceptances, manifests: covered, objects: objects))
        }
        return proofs
    }
}
