import Foundation

/// Pure adaptive scan schedule (Wave 7C / S01). No timers or global state.
public struct IndexingSchedulePolicy: Sendable, Equatable {
    public enum ThermalPressure: String, Sendable, Equatable {
        case nominal
        case fair
        case serious
        case critical
    }

    public struct SystemConditions: Sendable, Equatable {
        public var lowPower: Bool
        public var thermal: ThermalPressure

        public init(lowPower: Bool = false, thermal: ThermalPressure = .nominal) {
            self.lowPower = lowPower
            self.thermal = thermal
        }
    }

    public struct ScanOutcome: Sendable, Equatable {
        public var indexed: Int
        public var failed: Bool

        public init(indexed: Int, failed: Bool = false) {
            self.indexed = indexed
            self.failed = failed
        }
    }

    public static let minInterval: TimeInterval = 15 * 60
    public static let midInterval: TimeInterval = 30 * 60
    public static let maxInterval: TimeInterval = 60 * 60
    public static let fallbackInterval: TimeInterval = 60 * 60

    public private(set) var targetInterval: TimeInterval
    public private(set) var consecutiveIdleScans: Int

    public init(targetInterval: TimeInterval = minInterval, consecutiveIdleScans: Int = 0) {
        self.targetInterval = min(max(targetInterval, Self.minInterval), Self.maxInterval)
        self.consecutiveIdleScans = max(0, consecutiveIdleScans)
    }

    /// Whether discretionary work should wait (Low Power or serious thermal).
    public static func shouldDefer(conditions: SystemConditions) -> Bool {
        if conditions.lowPower { return true }
        switch conditions.thermal {
        case .serious, .critical:
            return true
        case .nominal, .fair:
            return false
        }
    }

    /// Update backoff after a completed incremental scan.
    public mutating func recordScan(_ outcome: ScanOutcome) {
        if outcome.failed {
            // Keep current interval on failure; do not accelerate or reset blindly.
            return
        }
        if outcome.indexed > 0 {
            consecutiveIdleScans = 0
            targetInterval = Self.minInterval
            return
        }
        consecutiveIdleScans += 1
        switch consecutiveIdleScans {
        case 0, 1:
            targetInterval = Self.minInterval
        case 2:
            targetInterval = Self.midInterval
        default:
            targetInterval = Self.maxInterval
        }
    }

    /// Manual refresh bypasses idle backoff (returns min interval) but callers
    /// still honor `shouldDefer` and single-writer rules.
    public func nextInterval(manualRefresh: Bool = false) -> TimeInterval {
        if manualRefresh { return Self.minInterval }
        return targetInterval
    }
}
