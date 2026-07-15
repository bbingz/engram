import Darwin
import Foundation

enum ArchiveV2DrainState: String, Equatable, Sendable {
    case idle
    case draining
    case waitingRetry
    case pausedLowPower
    case pausedThermal
    case needsAttention
    case stopped
}

enum ArchiveV2DrainStage: String, CaseIterable, Equatable, Sendable {
    case capture
    case indexing
    case binding
    case policy
    case hq
    case m1
}

struct ArchiveV2DrainConditions: Equatable, Sendable {
    let lowPower: Bool
    let thermalPressure: Bool

    static func current() -> ArchiveV2DrainConditions {
        let info = ProcessInfo.processInfo
        return ArchiveV2DrainConditions(
            lowPower: info.isLowPowerModeEnabled,
            thermalPressure: info.thermalState == .serious
                || info.thermalState == .critical
        )
    }

    var allowsNewWork: Bool {
        !lowPower && !thermalPressure
    }
}

struct ArchiveV2DrainPassSummary: Equatable, Sendable {
    let startedAt: Date
    let finishedAt: Date
    let capturedFiles: Int
    let capturedSourceBytes: Int64
    let boundRows: Int
    let policyRows: Int
    let hqVerified: Int
    let m1Verified: Int
    let retryScheduled: Int
    let quarantined: Int
    let hasRunnableWork: Bool
    let nextRetryAt: Date?
    let needsAttention: Bool

    init(
        startedAt: Date = .distantPast,
        finishedAt: Date = .distantPast,
        capturedFiles: Int = 0,
        capturedSourceBytes: Int64 = 0,
        boundRows: Int = 0,
        policyRows: Int = 0,
        hqVerified: Int = 0,
        m1Verified: Int = 0,
        retryScheduled: Int = 0,
        quarantined: Int = 0,
        hasRunnableWork: Bool = false,
        nextRetryAt: Date? = nil,
        needsAttention: Bool = false
    ) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.capturedFiles = max(capturedFiles, 0)
        self.capturedSourceBytes = max(capturedSourceBytes, 0)
        self.boundRows = max(boundRows, 0)
        self.policyRows = max(policyRows, 0)
        self.hqVerified = max(hqVerified, 0)
        self.m1Verified = max(m1Verified, 0)
        self.retryScheduled = max(retryScheduled, 0)
        self.quarantined = max(quarantined, 0)
        self.hasRunnableWork = hasRunnableWork
        self.nextRetryAt = nextRetryAt
        self.needsAttention = needsAttention
    }

    var productive: Bool {
        capturedFiles > 0
            || boundRows > 0
            || policyRows > 0
            || hqVerified > 0
            || m1Verified > 0
            || quarantined > 0
            || hasRunnableWork
    }
}

struct ArchiveV2DrainSnapshot: Equatable, Sendable {
    let state: ArchiveV2DrainState
    let activeStages: [ArchiveV2DrainStage]
    let lastPass: ArchiveV2DrainPassSummary?
    let nextWakeAt: Date?
}

actor ArchiveV2BacklogDrainer {
    private static let productivePassCooldown: TimeInterval = 30

    typealias Conditions = @Sendable () -> ArchiveV2DrainConditions
    typealias Clock = @Sendable () -> Date
    typealias Sleeper = @Sendable (Date) async throws -> Void
    typealias MemoryPressureRelief = @Sendable () -> Int
    typealias Pass = @Sendable () async throws -> ArchiveV2DrainPassSummary

    private let conditions: Conditions
    private let now: Clock
    private let sleepUntil: Sleeper
    private let relieveMemoryPressure: MemoryPressureRelief
    private let runPass: Pass
    private let notificationCenter: NotificationCenter

    private var workerTask: Task<Void, Never>?
    private var sleeperTask: Task<Void, Error>?
    private var workContinuation: CheckedContinuation<Void, Never>?
    private var notificationTokens: [NSObjectProtocol] = []
    private var pendingSignal = false
    private var stopped = false
    private var state: ArchiveV2DrainState = .idle
    private var activeStages: [ArchiveV2DrainStage] = []
    private var lastPass: ArchiveV2DrainPassSummary?
    private var nextWakeAt: Date?

    init(
        conditions: @escaping Conditions = { .current() },
        now: @escaping Clock = { Date() },
        sleepUntil: @escaping Sleeper = { deadline in
            let delay = max(deadline.timeIntervalSinceNow, 0)
            try await Task.sleep(for: .seconds(delay))
        },
        notificationCenter: NotificationCenter = .default,
        relieveMemoryPressure: @escaping MemoryPressureRelief = {
            Int(malloc_zone_pressure_relief(nil, 0))
        },
        runPass: @escaping Pass
    ) {
        self.conditions = conditions
        self.now = now
        self.sleepUntil = sleepUntil
        self.notificationCenter = notificationCenter
        self.relieveMemoryPressure = relieveMemoryPressure
        self.runPass = runPass
    }

    func start() {
        guard workerTask == nil else { return }
        stopped = false
        state = .idle
        installConditionObservers()
        workerTask = Task(priority: .utility) { [weak self] in
            await self?.runLoop()
        }
    }

    func signal() {
        guard !stopped else { return }
        pendingSignal = true
        sleeperTask?.cancel()
        sleeperTask = nil
        nextWakeAt = nil
        workContinuation?.resume()
        workContinuation = nil
    }

    func setActiveStages(_ stages: [ArchiveV2DrainStage]) {
        guard state == .draining else { return }
        activeStages = Array(stages.prefix(2))
    }

    func snapshot() -> ArchiveV2DrainSnapshot {
        ArchiveV2DrainSnapshot(
            state: state,
            activeStages: activeStages,
            lastPass: lastPass,
            nextWakeAt: nextWakeAt
        )
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        pendingSignal = false
        sleeperTask?.cancel()
        sleeperTask = nil
        workContinuation?.resume()
        workContinuation = nil
        let task = workerTask
        workerTask = nil
        task?.cancel()
        removeConditionObservers()
        await task?.value
        state = .stopped
        activeStages = []
        nextWakeAt = nil
    }

    private func runLoop() async {
        while !stopped, !Task.isCancelled {
            await waitForWork()
            guard !stopped, !Task.isCancelled else { break }
            pendingSignal = false

            let currentConditions = conditions()
            if currentConditions.thermalPressure {
                state = .pausedThermal
                activeStages = []
                continue
            }
            if currentConditions.lowPower {
                state = .pausedLowPower
                activeStages = []
                continue
            }

            state = .draining
            activeStages = []
            nextWakeAt = nil
            do {
                let summary = try await runPassWithMemoryRelief()
                guard !stopped, !Task.isCancelled else { break }
                lastPass = summary
                ServiceLogger.info(
                    "archive backlog pass captured=\(summary.capturedFiles) bytes=\(summary.capturedSourceBytes) bound=\(summary.boundRows) policy=\(summary.policyRows) hq=\(summary.hqVerified) m1=\(summary.m1Verified) retry=\(summary.retryScheduled) quarantine=\(summary.quarantined) runnable=\(summary.hasRunnableWork)",
                    category: .runner
                )
                activeStages = []
                if pendingSignal {
                    state = .idle
                    continue
                }
                if summary.needsAttention,
                   !summary.hasRunnableWork,
                   summary.nextRetryAt == nil {
                    state = .needsAttention
                    continue
                }
                if summary.productive {
                    state = .idle
                    try await waitUntil(now().addingTimeInterval(Self.productivePassCooldown))
                    if !stopped { pendingSignal = true }
                } else if let retryAt = summary.nextRetryAt {
                    state = .waitingRetry
                    try await waitUntil(retryAt)
                    if !stopped { pendingSignal = true }
                } else {
                    state = .idle
                }
            } catch is CancellationError {
                if stopped || Task.isCancelled { break }
            } catch {
                state = .needsAttention
                activeStages = []
            }
        }
    }

    private func runPassWithMemoryRelief() async throws -> ArchiveV2DrainPassSummary {
        defer {
            let releasedBytes = relieveMemoryPressure()
            ServiceLogger.info(
                "archive backlog memory pressure relief complete: releasedBytes=\(releasedBytes)",
                category: .runner
            )
        }
        return try await runPass()
    }

    private func waitForWork() async {
        if pendingSignal || stopped || Task.isCancelled { return }
        await withCheckedContinuation { continuation in
            if pendingSignal || stopped || Task.isCancelled {
                continuation.resume()
            } else {
                workContinuation = continuation
            }
        }
    }

    private func waitUntil(_ deadline: Date) async throws {
        nextWakeAt = deadline
        let task = Task { try await sleepUntil(deadline) }
        sleeperTask = task
        defer {
            sleeperTask = nil
            nextWakeAt = nil
        }
        try await task.value
    }

    private func installConditionObservers() {
        guard notificationTokens.isEmpty else { return }
        let names: [Notification.Name] = [
            ProcessInfo.thermalStateDidChangeNotification,
            Notification.Name.NSProcessInfoPowerStateDidChange,
        ]
        notificationTokens = names.map { name in
            notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                Task { await self?.signal() }
            }
        }
    }

    private func removeConditionObservers() {
        for token in notificationTokens {
            notificationCenter.removeObserver(token)
        }
        notificationTokens = []
    }
}
