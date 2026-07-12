import Foundation

public enum ArchiveCASEvictionBlocker: String, Equatable, Sendable {
    case intentNotSourceDeleted = "intent_not_source_deleted"
    case missingReceipt = "missing_receipt"
    case expiredDrill = "expired_drill"
    case unsafeSharedReference = "unsafe_shared_reference"
    case byteBudgetExhausted = "byte_budget_exhausted"
}

public struct ArchiveCASEvictionResult: Equatable, Sendable {
    public let examinedObjects: Int
    public let evictedObjects: Int
    public let releasedBytes: Int64
    public let blocker: ArchiveCASEvictionBlocker?
}

public struct ArchiveCASEvictor: Sendable {
    public static let maximumBytesPerCycle: Int64 = 256 * 1_024 * 1_024
    public static let recoveryLeaseLifetime: TimeInterval = 30 * 86_400

    private let catalog: ArchiveCatalog
    private let cas: ImmutableArchiveCAS

    public init(catalog: ArchiveCatalog, cas: ImmutableArchiveCAS) {
        self.catalog = catalog
        self.cas = cas
    }

    public func evictEligibleObjects(
        for manifestSHA256: String,
        now: Date = Date(),
        maximumBytes: Int64 = Self.maximumBytesPerCycle
    ) throws -> ArchiveCASEvictionResult {
        guard maximumBytes > 0 else {
            throw ArchiveCatalogError.invalidLimit(Int(maximumBytes))
        }
        guard let targetIntent = try catalog.reclamationIntent(
            manifestSHA256: manifestSHA256
        ), targetIntent.phase == .sourceDeleted || targetIntent.phase == .localContentEvicted else {
            return result(blocker: .intentNotSourceDeleted)
        }
        guard try recoveryLeasesAreCurrent(now: now) else {
            return result(blocker: .expiredDrill)
        }
        guard try manifestHasDualReceipts(manifestSHA256) else {
            return result(blocker: .missingReceipt)
        }

        let objects = try catalog.localObjects(manifestSHA256: manifestSHA256)
        var examined = 0
        var evicted = 0
        var released: Int64 = 0
        var blocker: ArchiveCASEvictionBlocker?

        for object in objects where object.residency == .resident {
            examined += 1
            guard object.rawByteCount <= maximumBytes - released else {
                blocker = blocker ?? .byteBudgetExhausted
                continue
            }
            guard try everyReferenceIsRemoteSafe(
                objectSHA256: object.objectSHA256,
                now: now
            ) else {
                blocker = blocker ?? .unsafeSharedReference
                continue
            }
            let removal = try cas.removeObject(sha256: object.objectSHA256)
            let removedBytes: Int64
            switch removal {
            case .removed(let byteCount):
                guard byteCount == object.rawByteCount else {
                    throw ImmutableArchiveCASError.existingContentConflict(
                        expected: object.objectSHA256,
                        actual: "unexpected_byte_count"
                    )
                }
                removedBytes = byteCount
            case .alreadyMissing:
                removedBytes = 0
            }
            guard try catalog.markLocalObjectEvicted(
                objectSHA256: object.objectSHA256,
                updatedAt: Self.timestamp(now)
            ) else {
                throw ArchiveCatalogError.boundManifestMismatch(field: "localObject.residency")
            }
            evicted += 1
            released += removedBytes
        }

        let remaining = try catalog.localObjects(manifestSHA256: manifestSHA256)
            .contains { $0.residency == .resident }
        if !remaining, targetIntent.phase == .sourceDeleted {
            guard try catalog.transitionReclamationIntent(
                manifestSHA256: manifestSHA256,
                from: .sourceDeleted,
                to: .localContentEvicted,
                expectedClaimGeneration: targetIntent.claimGeneration,
                quarantinePath: nil,
                updatedAt: Self.timestamp(now),
                releasedCASBytes: released
            ) else {
                throw ArchiveSourceReclaimerError.staleIntent
            }
        }

        return ArchiveCASEvictionResult(
            examinedObjects: examined,
            evictedObjects: evicted,
            releasedBytes: released,
            blocker: blocker
        )
    }

    private func everyReferenceIsRemoteSafe(
        objectSHA256: String,
        now: Date
    ) throws -> Bool {
        guard try recoveryLeasesAreCurrent(now: now) else { return false }
        for manifestSHA256 in try catalog.referencingManifests(objectSHA256: objectSHA256) {
            guard let intent = try catalog.reclamationIntent(manifestSHA256: manifestSHA256),
                  intent.phase == .sourceDeleted || intent.phase == .localContentEvicted,
                  try manifestHasDualReceipts(manifestSHA256) else {
                return false
            }
        }
        return true
    }

    private func manifestHasDualReceipts(_ manifestSHA256: String) throws -> Bool {
        let receipts = try catalog.currentVerifiedReceipts(manifestSHA256: manifestSHA256)
        return Set(receipts.keys) == Set(ArchiveCatalog.currentReplicaIDs)
    }

    private func recoveryLeasesAreCurrent(now: Date) throws -> Bool {
        for replicaID in ArchiveCatalog.currentReplicaIDs {
            guard let lease = try catalog.recoveryLease(replicaID: replicaID),
                  let verifiedAt = Self.date(lease.verifiedAt),
                  verifiedAt <= now,
                  now.timeIntervalSince(verifiedAt) <= Self.recoveryLeaseLifetime else {
                return false
            }
        }
        return true
    }

    private func result(blocker: ArchiveCASEvictionBlocker) -> ArchiveCASEvictionResult {
        ArchiveCASEvictionResult(
            examinedObjects: 0,
            evictedObjects: 0,
            releasedBytes: 0,
            blocker: blocker
        )
    }

    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: value)
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
