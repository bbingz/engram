import Foundation
import EngramCoreRead

/// In-process, ephemeral telemetry for the service. Holds a bounded span ring
/// buffer, per-command latency aggregates over a bounded sample window, and
/// scan counters. Deliberately NOT persisted: it resets on every service
/// restart and is summarized through the `telemetry` read command. This is not
/// distributed tracing — flat per-command spans, coarse one-span-per-IPC
/// granularity, and approximate percentiles over a bounded window.
actor ServiceTelemetryCollector {
    private let spanCapacity: Int
    private let latencyWindow: Int
    private let embeddingBreaker: EmbeddingCircuitBreaker

    private var spans: [ServiceSpan] = []
    private var commandSamples: [String: [Double]] = [:]
    private var commandCounts: [String: Int] = [:]
    private var commandErrors: [String: Int] = [:]

    private var lastScanDurationMs: Double?
    private var lastScanIndexed: Int = 0
    private var lastScanTotal: Int = 0
    private var scanCount: Int = 0
    private var lastScanAt: String?

    // Wave 7C S01 schedule visibility (adaptive 15→30→60m, not fixed 5m).
    private var nextScanIntervalSeconds: Int?
    private var scheduleTargetIntervalSeconds: Int?
    private var scheduleMinIntervalSeconds: Int? = Int(IndexingSchedulePolicy.minInterval)
    private var scheduleConsecutiveIdleScans: Int?
    private var scheduleBackend: String?

    init(
        spanCapacity: Int = 200,
        latencyWindow: Int = 100,
        embeddingBreaker: EmbeddingCircuitBreaker = EmbeddingGuardrails.sharedBreaker
    ) {
        self.spanCapacity = max(1, spanCapacity)
        self.latencyWindow = max(1, latencyWindow)
        self.embeddingBreaker = embeddingBreaker
    }

    func recordSchedule(
        nextScanIntervalSeconds: Int,
        targetIntervalSeconds: Int,
        consecutiveIdleScans: Int,
        minIntervalSeconds: Int = Int(IndexingSchedulePolicy.minInterval),
        backend: String
    ) {
        self.nextScanIntervalSeconds = nextScanIntervalSeconds
        self.scheduleTargetIntervalSeconds = targetIntervalSeconds
        self.scheduleConsecutiveIdleScans = consecutiveIdleScans
        self.scheduleMinIntervalSeconds = minIntervalSeconds
        self.scheduleBackend = backend
    }

    func record(span: ServiceSpan) {
        spans.append(span)
        if spans.count > spanCapacity {
            spans.removeFirst(spans.count - spanCapacity)
        }

        commandCounts[span.command, default: 0] += 1
        if !span.ok {
            commandErrors[span.command, default: 0] += 1
        }
        var samples = commandSamples[span.command] ?? []
        samples.append(span.durationMs)
        if samples.count > latencyWindow {
            samples.removeFirst(samples.count - latencyWindow)
        }
        commandSamples[span.command] = samples
    }

    func recordScan(durationMs: Double, indexed: Int, total: Int) {
        lastScanDurationMs = durationMs
        lastScanIndexed = indexed
        lastScanTotal = total
        scanCount += 1
        lastScanAt = Self.isoNow()
    }

    func snapshot() -> ServiceTelemetrySnapshot {
        let commands = commandCounts.keys.sorted().map { command -> ServiceCommandLatency in
            let samples = commandSamples[command] ?? []
            return ServiceCommandLatency(
                command: command,
                count: commandCounts[command] ?? 0,
                p50Ms: Self.percentile(samples, 0.5),
                p95Ms: Self.percentile(samples, 0.95),
                maxMs: samples.max() ?? 0,
                errorCount: commandErrors[command] ?? 0
            )
        }
        // Newest-first span list for the trace explorer.
        let orderedSpans = Array(spans.reversed())
        let breakers = embeddingBreaker.snapshots().map { snap in
            EmbeddingBreakerTelemetry(
                providerKey: snap.providerKey,
                state: snap.state,
                consecutiveFailures: snap.consecutiveFailures,
                transportFailures: snap.transportFailures,
                successes: snap.successes,
                opens: snap.opens,
                rejections: snap.rejections,
                halfOpenProbes: snap.halfOpenProbes,
                cooldownRemainingMs: snap.cooldownRemainingMs
            )
        }
        return ServiceTelemetrySnapshot(
            lastScanDurationMs: lastScanDurationMs,
            lastScanIndexed: lastScanIndexed,
            lastScanTotal: lastScanTotal,
            scanCount: scanCount,
            lastScanAt: lastScanAt,
            commands: commands,
            spans: orderedSpans,
            embeddingBreakers: breakers,
            nextScanIntervalSeconds: nextScanIntervalSeconds,
            scheduleTargetIntervalSeconds: scheduleTargetIntervalSeconds,
            scheduleMinIntervalSeconds: scheduleMinIntervalSeconds,
            scheduleConsecutiveIdleScans: scheduleConsecutiveIdleScans,
            scheduleBackend: scheduleBackend
        )
    }

    /// Nearest-rank percentile over a bounded sample window. Approximate by
    /// design (the window caps history), which is the documented trade-off.
    private static func percentile(_ samples: [Double], _ fraction: Double) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        let index = min(max(rank - 1, 0), sorted.count - 1)
        return sorted[index]
    }

    private static func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
