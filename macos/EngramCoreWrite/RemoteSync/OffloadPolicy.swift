import Foundation

/// Pure, deterministic offload eligibility + prioritization. A sibling of
/// `SessionTier` (and, like it, stays local — never moved to the remote). Per the
/// owner's locked decision, eligibility includes *visible-but-cold* sessions
/// (older than `coldAgeDays`), not just archived/hidden ones.
public struct OffloadPolicy: Sendable {
    public var coldAgeDays: Int
    public var minResidencyHours: Int

    public init(coldAgeDays: Int = 90, minResidencyHours: Int = 24) {
        self.coldAgeDays = coldAgeDays
        self.minResidencyHours = minResidencyHours
    }

    public struct SessionRow: Sendable {
        public let id: String
        public let offloadState: String?
        public let hiddenAt: String?
        public let tier: String?
        public let agentRole: String?
        /// end_time ?? start_time — the most recent activity timestamp (ISO-8601).
        public let lastActivity: String?
        public let sizeBytes: Int

        public init(
            id: String,
            offloadState: String?,
            hiddenAt: String?,
            tier: String?,
            agentRole: String?,
            lastActivity: String?,
            sizeBytes: Int
        ) {
            self.id = id
            self.offloadState = offloadState
            self.hiddenAt = hiddenAt
            self.tier = tier
            self.agentRole = agentRole
            self.lastActivity = lastActivity
            self.sizeBytes = sizeBytes
        }
    }

    public func isEligible(_ row: SessionRow, now: Date) -> Bool {
        // Already offloaded (or mid-flight) → not a candidate.
        guard (row.offloadState ?? "local") == "local" else { return false }
        // skip-tier and subagents are accessed through their parent, never
        // offloaded independently (mirrors the tiering invariant).
        if row.tier == "skip" { return false }
        if row.agentRole == "subagent" { return false }
        // Archived/hidden sessions are always eligible (already search-excluded).
        if row.hiddenAt != nil { return true }
        // Visible-but-cold: eligible once untouched for `coldAgeDays`.
        guard let last = Self.parseDate(row.lastActivity) else { return false }
        return now.timeIntervalSince(last) >= Double(coldAgeDays) * 86_400
    }

    /// Higher = offload first. Prioritize large + stale: bytes scaled by age in days.
    public func score(_ row: SessionRow, now: Date) -> Double {
        let ageDays = Self.parseDate(row.lastActivity)
            .map { max(0, now.timeIntervalSince($0)) / 86_400 } ?? Double(coldAgeDays)
        return Double(row.sizeBytes) * (1.0 + ageDays)
    }

    private static let isoFormatters: [ISO8601DateFormatter] = {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return [withFractional, plain]
    }()

    static func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        for formatter in isoFormatters {
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}
