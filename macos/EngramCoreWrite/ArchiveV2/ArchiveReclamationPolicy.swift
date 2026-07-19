import Foundation

public struct ArchiveReclamationCandidate: Equatable, Sendable {
    public let source: String
    public let lastActivityNs: Int64
    public let isLive: Bool
    public let isFavorite: Bool
    public let generationMatchesCapture: Bool
    public let verifiedReceiptReplicaIDs: Set<String>
    public let hasNewerCapture: Bool
    public let hasActiveOperation: Bool
    public let sourceByteCount: Int64

    public init(
        source: String,
        lastActivityNs: Int64,
        isLive: Bool,
        isFavorite: Bool,
        generationMatchesCapture: Bool,
        verifiedReceiptReplicaIDs: Set<String>,
        hasNewerCapture: Bool,
        hasActiveOperation: Bool,
        sourceByteCount: Int64
    ) {
        self.source = source
        self.lastActivityNs = lastActivityNs
        self.isLive = isLive
        self.isFavorite = isFavorite
        self.generationMatchesCapture = generationMatchesCapture
        self.verifiedReceiptReplicaIDs = verifiedReceiptReplicaIDs
        self.hasNewerCapture = hasNewerCapture
        self.hasActiveOperation = hasActiveOperation
        self.sourceByteCount = sourceByteCount
    }
}

public struct ArchiveReclamationContext: Equatable, Sendable {
    public let enabled: Bool
    public let hotWindowDays: Int
    public let nowNs: Int64
    public let recoveryLeaseVerifiedAtNs: [String: Int64]

    public init(
        enabled: Bool,
        hotWindowDays: Int,
        nowNs: Int64,
        recoveryLeaseVerifiedAtNs: [String: Int64]
    ) {
        self.enabled = enabled
        self.hotWindowDays = hotWindowDays
        self.nowNs = nowNs
        self.recoveryLeaseVerifiedAtNs = recoveryLeaseVerifiedAtNs
    }
}

public enum ArchiveReclamationBlocker: String, Equatable, Sendable {
    case disabled
    case invalidHotWindow = "invalid_hot_window"
    case unsupportedSource = "unsupported_source"
    case missingProductSession = "missing_product_session"
    case invalidProductActivity = "invalid_product_activity"
    case insufficientAge = "insufficient_age"
    case live
    case favorite
    case generationChanged = "generation_changed"
    case missingReceipt = "missing_receipt"
    case expiredDrill = "expired_drill"
    case newerCapture = "newer_capture"
    case activeOperation = "active_operation"
    case sourceTooLarge = "source_too_large"
}

public enum ArchiveReclamationDecision: Equatable, Sendable {
    case eligible
    case blocked(ArchiveReclamationBlocker)
}

public enum ArchiveReclamationPolicy {
    private static let supportedHotWindowDays = Set([30, 60, 90, 180])
    private static let requiredReplicaIDs = Set(["hq", "m1"])
    private static let supportedSources = Set(["claude-code", "codex"])
    private static let nanosecondsPerDay: Int64 = 86_400_000_000_000
    private static let recoveryLeaseDays: Int64 = 30
    private static let maximumSourceBytes: Int64 = 256 * 1_024 * 1_024

    public static func preflight(
        source: String,
        context: ArchiveReclamationContext
    ) -> ArchiveReclamationDecision? {
        guard context.enabled else { return .blocked(.disabled) }
        guard supportedHotWindowDays.contains(context.hotWindowDays),
              durationNs(days: Int64(context.hotWindowDays)) != nil else {
            return .blocked(.invalidHotWindow)
        }
        guard supportedSources.contains(source) else {
            return .blocked(.unsupportedSource)
        }
        return nil
    }

    public static func evaluate(
        candidate: ArchiveReclamationCandidate,
        context: ArchiveReclamationContext
    ) -> ArchiveReclamationDecision {
        if let decision = preflight(source: candidate.source, context: context) {
            return decision
        }
        guard let hotWindowNs = durationNs(days: Int64(context.hotWindowDays)) else {
            return .blocked(.invalidHotWindow)
        }
        guard elapsedNs(since: candidate.lastActivityNs, now: context.nowNs)
            .map({ $0 >= hotWindowNs }) == true else {
            return .blocked(.insufficientAge)
        }
        guard !candidate.isLive else { return .blocked(.live) }
        guard !candidate.isFavorite else { return .blocked(.favorite) }
        guard candidate.generationMatchesCapture else {
            return .blocked(.generationChanged)
        }
        guard requiredReplicaIDs.isSubset(of: candidate.verifiedReceiptReplicaIDs) else {
            return .blocked(.missingReceipt)
        }
        guard recoveryLeasesAreCurrent(context) else {
            return .blocked(.expiredDrill)
        }
        guard !candidate.hasNewerCapture else { return .blocked(.newerCapture) }
        guard !candidate.hasActiveOperation else { return .blocked(.activeOperation) }
        guard (0 ... maximumSourceBytes).contains(candidate.sourceByteCount) else {
            return .blocked(.sourceTooLarge)
        }
        return .eligible
    }

    private static func recoveryLeasesAreCurrent(
        _ context: ArchiveReclamationContext
    ) -> Bool {
        guard let maximumAge = durationNs(days: recoveryLeaseDays) else { return false }
        return requiredReplicaIDs.allSatisfy { replicaID in
            guard let verifiedAt = context.recoveryLeaseVerifiedAtNs[replicaID],
                  let age = elapsedNs(since: verifiedAt, now: context.nowNs) else {
                return false
            }
            return age <= maximumAge
        }
    }

    private static func elapsedNs(since start: Int64, now: Int64) -> Int64? {
        let (value, overflow) = now.subtractingReportingOverflow(start)
        return !overflow && value >= 0 ? value : nil
    }

    private static func durationNs(days: Int64) -> Int64? {
        let (value, overflow) = days.multipliedReportingOverflow(by: nanosecondsPerDay)
        return overflow ? nil : value
    }
}
