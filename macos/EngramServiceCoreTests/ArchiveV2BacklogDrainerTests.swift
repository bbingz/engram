import Foundation
@testable import EngramServiceCore
import XCTest

final class ArchiveV2BacklogDrainerTests: XCTestCase {
    func testEveryPassRelievesAllocatorPressureAfterPassReturns() async throws {
        let passes = DrainPassRecorder(results: [ArchiveV2DrainPassSummary()])
        let relief = DrainReliefRecorder()
        let drainer = ArchiveV2BacklogDrainer(
            conditions: { ArchiveV2DrainConditions(lowPower: false, thermalPressure: false) },
            relieveMemoryPressure: { relief.record() },
            runPass: { try await passes.run() }
        )

        await drainer.start()
        await drainer.signal()
        try await passes.waitForPassCount(1)
        try await waitForState(.idle, drainer: drainer)
        await drainer.stop()

        XCTAssertEqual(relief.count(), 1)
    }

    func testProductivePassCoolsDownThenRunsAgainWithoutOverlap() async throws {
        let recorder = DrainPassRecorder(results: [
            ArchiveV2DrainPassSummary(
                startedAt: Date(timeIntervalSince1970: 100),
                finishedAt: Date(timeIntervalSince1970: 101),
                capturedFiles: 1,
                capturedSourceBytes: 64,
                hasRunnableWork: true
            ),
            ArchiveV2DrainPassSummary(
                startedAt: Date(timeIntervalSince1970: 102),
                finishedAt: Date(timeIntervalSince1970: 103)
            ),
        ])
        let sleeps = DrainSleepRecorder()
        let drainer = ArchiveV2BacklogDrainer(
            conditions: { ArchiveV2DrainConditions(lowPower: false, thermalPressure: false) },
            now: { Date(timeIntervalSince1970: 100) },
            sleepUntil: { deadline in try await sleeps.record(deadline) },
            runPass: { try await recorder.run() }
        )

        await drainer.start()
        await drainer.signal()
        try await recorder.waitForPassCount(2)
        try await waitForState(.idle, drainer: drainer)
        let snapshot = await drainer.snapshot()
        let passCount = await recorder.passCount()
        let maximumConcurrency = await recorder.maximumConcurrency()
        let deadlines = await sleeps.deadlines()
        await drainer.stop()

        XCTAssertEqual(passCount, 2)
        XCTAssertEqual(maximumConcurrency, 1)
        XCTAssertEqual(deadlines, [Date(timeIntervalSince1970: 130)])
        XCTAssertEqual(snapshot.state, .idle)
        XCTAssertNil(snapshot.nextWakeAt)
    }

    func testIdlePassDoesNotPollOrSleep() async throws {
        let recorder = DrainPassRecorder(results: [
            ArchiveV2DrainPassSummary(
                startedAt: Date(timeIntervalSince1970: 100),
                finishedAt: Date(timeIntervalSince1970: 101)
            ),
        ])
        let sleeps = DrainSleepRecorder()
        let drainer = ArchiveV2BacklogDrainer(
            conditions: { ArchiveV2DrainConditions(lowPower: false, thermalPressure: false) },
            now: { Date(timeIntervalSince1970: 100) },
            sleepUntil: { deadline in try await sleeps.record(deadline) },
            runPass: { try await recorder.run() }
        )

        await drainer.start()
        await drainer.signal()
        try await recorder.waitForPassCount(1)
        try await Task.sleep(for: .milliseconds(20))
        let snapshot = await drainer.snapshot()
        let passCount = await recorder.passCount()
        let deadlines = await sleeps.deadlines()
        await drainer.stop()

        XCTAssertEqual(passCount, 1)
        XCTAssertTrue(deadlines.isEmpty)
        XCTAssertEqual(snapshot.state, .idle)
    }

    func testRetryDeadlineAndResourcePausesAreExplicit() async throws {
        let retryAt = Date(timeIntervalSince1970: 160)
        let recorder = DrainPassRecorder(results: [
            ArchiveV2DrainPassSummary(
                startedAt: Date(timeIntervalSince1970: 100),
                finishedAt: Date(timeIntervalSince1970: 101),
                retryScheduled: 1,
                nextRetryAt: retryAt
            ),
        ])
        let conditions = DrainConditionsBox(
            ArchiveV2DrainConditions(lowPower: true, thermalPressure: false)
        )
        let sleeps = DrainSleepRecorder(blocking: true)
        let drainer = ArchiveV2BacklogDrainer(
            conditions: { conditions.value() },
            now: { Date(timeIntervalSince1970: 100) },
            sleepUntil: { deadline in try await sleeps.record(deadline) },
            runPass: { try await recorder.run() }
        )

        await drainer.start()
        await drainer.signal()
        try await waitForState(.pausedLowPower, drainer: drainer)
        conditions.set(ArchiveV2DrainConditions(lowPower: false, thermalPressure: false))
        await drainer.signal()
        try await recorder.waitForPassCount(1)
        try await waitForState(.waitingRetry, drainer: drainer)
        let snapshot = await drainer.snapshot()
        let deadlines = await sleeps.deadlines()
        await drainer.stop()

        XCTAssertEqual(snapshot.nextWakeAt, retryAt)
        XCTAssertEqual(deadlines, [retryAt])
    }

    func testAttentionOnOneReplicaDoesNotStopOtherRunnableWork() async throws {
        let recorder = DrainPassRecorder(results: [
            ArchiveV2DrainPassSummary(
                capturedFiles: 1,
                hasRunnableWork: true,
                needsAttention: true
            ),
            ArchiveV2DrainPassSummary(),
        ])
        let drainer = ArchiveV2BacklogDrainer(
            conditions: { ArchiveV2DrainConditions(lowPower: false, thermalPressure: false) },
            sleepUntil: { _ in },
            runPass: { try await recorder.run() }
        )

        await drainer.start()
        await drainer.signal()
        try await recorder.waitForPassCount(2)
        let count = await recorder.passCount()
        await drainer.stop()

        XCTAssertEqual(count, 2)
    }

    func testAttentionOnOneReplicaStillWaitsForHealthyReplicaRetry() async throws {
        let retryAt = Date(timeIntervalSince1970: 160)
        let recorder = DrainPassRecorder(results: [
            ArchiveV2DrainPassSummary(
                nextRetryAt: retryAt,
                needsAttention: true
            ),
        ])
        let sleeps = DrainSleepRecorder(blocking: true)
        let drainer = ArchiveV2BacklogDrainer(
            conditions: { ArchiveV2DrainConditions(lowPower: false, thermalPressure: false) },
            now: { Date(timeIntervalSince1970: 100) },
            sleepUntil: { deadline in try await sleeps.record(deadline) },
            runPass: { try await recorder.run() }
        )

        await drainer.start()
        await drainer.signal()
        try await recorder.waitForPassCount(1)
        try await waitForState(.waitingRetry, drainer: drainer)
        let deadlines = await sleeps.deadlines()
        await drainer.stop()

        XCTAssertEqual(deadlines, [retryAt])
    }

    func testSignalsCoalesceToOneAdditionalPassWhileRunning() async throws {
        let recorder = BlockingFirstDrainPassRecorder()
        let drainer = ArchiveV2BacklogDrainer(
            conditions: { ArchiveV2DrainConditions(lowPower: false, thermalPressure: false) },
            runPass: { try await recorder.run() }
        )

        await drainer.start()
        await drainer.signal()
        try await recorder.waitForPassCount(1)
        await drainer.signal()
        await drainer.signal()
        await drainer.signal()
        await recorder.releaseFirstPass()
        try await recorder.waitForPassCount(2)
        try await Task.sleep(for: .milliseconds(20))
        let count = await recorder.passCount()
        await drainer.stop()

        XCTAssertEqual(count, 2)
    }

    func testWaitingForPipelineDoesNotPublishCaptureStage() async throws {
        let recorder = BlockingFirstDrainPassRecorder()
        let drainer = ArchiveV2BacklogDrainer(
            conditions: { ArchiveV2DrainConditions(lowPower: false, thermalPressure: false) },
            runPass: { try await recorder.run() }
        )

        await drainer.start()
        await drainer.signal()
        try await recorder.waitForPassCount(1)
        let snapshot = await drainer.snapshot()
        await recorder.releaseFirstPass()
        await drainer.stop()

        XCTAssertEqual(snapshot.state, .draining)
        XCTAssertTrue(snapshot.activeStages.isEmpty)
    }

    func testSignalDuringPassBypassesReturnedRetryDeadline() async throws {
        let retryAt = Date(timeIntervalSince1970: 160)
        let recorder = BlockingFirstDrainPassRecorder(
            firstResult: ArchiveV2DrainPassSummary(
                startedAt: Date(timeIntervalSince1970: 100),
                finishedAt: Date(timeIntervalSince1970: 101),
                retryScheduled: 1,
                nextRetryAt: retryAt
            )
        )
        let sleeps = DrainSleepRecorder()
        let drainer = ArchiveV2BacklogDrainer(
            conditions: { ArchiveV2DrainConditions(lowPower: false, thermalPressure: false) },
            sleepUntil: { deadline in try await sleeps.record(deadline) },
            runPass: { try await recorder.run() }
        )

        await drainer.start()
        await drainer.signal()
        try await recorder.waitForPassCount(1)
        await drainer.signal()
        await recorder.releaseFirstPass()
        try await recorder.waitForPassCount(2)
        try await Task.sleep(for: .milliseconds(20))
        let count = await recorder.passCount()
        let deadlines = await sleeps.deadlines()
        await drainer.stop()

        XCTAssertEqual(count, 2)
        XCTAssertTrue(
            deadlines.isEmpty,
            "an explicit signal received during the pass must outrank its stale retry deadline"
        )
    }

    func testThermalNotificationResumesPausedWorker() async throws {
        let notificationCenter = NotificationCenter()
        let conditions = DrainConditionsBox(
            ArchiveV2DrainConditions(lowPower: false, thermalPressure: true)
        )
        let recorder = DrainPassRecorder(results: [ArchiveV2DrainPassSummary()])
        let drainer = ArchiveV2BacklogDrainer(
            conditions: { conditions.value() },
            notificationCenter: notificationCenter,
            runPass: { try await recorder.run() }
        )

        await drainer.start()
        await drainer.signal()
        try await waitForState(.pausedThermal, drainer: drainer)
        conditions.set(ArchiveV2DrainConditions(lowPower: false, thermalPressure: false))
        notificationCenter.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        try await recorder.waitForPassCount(1)
        try await waitForState(.idle, drainer: drainer)
        let count = await recorder.passCount()
        await drainer.stop()

        XCTAssertEqual(count, 1)
    }

    func testStopCancelsAnInFlightPassAndPublishesStoppedState() async throws {
        let recorder = DrainStartRecorder()
        let drainer = ArchiveV2BacklogDrainer(
            conditions: { ArchiveV2DrainConditions(lowPower: false, thermalPressure: false) },
            runPass: {
                await recorder.recordStart()
                try await Task.sleep(for: .seconds(60))
                return ArchiveV2DrainPassSummary()
            }
        )

        await drainer.start()
        await drainer.signal()
        try await recorder.waitUntilStarted()
        await drainer.stop()
        let state = await drainer.snapshot().state

        XCTAssertEqual(state, .stopped)
    }

    private func waitForState(
        _ state: ArchiveV2DrainState,
        drainer: ArchiveV2BacklogDrainer
    ) async throws {
        for _ in 0 ..< 200 {
            if await drainer.snapshot().state == state { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out waiting for \(state)")
    }
}

private final class DrainReliefRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func record() -> Int {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        return 4096
    }

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

private actor DrainPassRecorder {
    private var results: [ArchiveV2DrainPassSummary]
    private var calls = 0
    private var concurrent = 0
    private var maximum = 0

    init(results: [ArchiveV2DrainPassSummary]) {
        self.results = results
    }

    func run() async throws -> ArchiveV2DrainPassSummary {
        concurrent += 1
        maximum = max(maximum, concurrent)
        calls += 1
        await Task.yield()
        concurrent -= 1
        return results.isEmpty ? ArchiveV2DrainPassSummary() : results.removeFirst()
    }

    func waitForPassCount(_ expected: Int) async throws {
        for _ in 0 ..< 200 where calls < expected {
            try await Task.sleep(for: .milliseconds(5))
        }
        if calls < expected { throw DrainTestError.timeout }
    }

    func passCount() -> Int { calls }
    func maximumConcurrency() -> Int { maximum }
}

private actor DrainSleepRecorder {
    private var values: [Date] = []
    private let blocking: Bool

    init(blocking: Bool = false) {
        self.blocking = blocking
    }

    func record(_ deadline: Date) async throws {
        values.append(deadline)
        if blocking {
            try await Task.sleep(for: .seconds(60))
        }
    }

    func deadlines() -> [Date] { values }
}

private actor BlockingFirstDrainPassRecorder {
    private var calls = 0
    private var firstPassContinuation: CheckedContinuation<Void, Never>?
    private let firstResult: ArchiveV2DrainPassSummary

    init(firstResult: ArchiveV2DrainPassSummary = ArchiveV2DrainPassSummary()) {
        self.firstResult = firstResult
    }

    func run() async throws -> ArchiveV2DrainPassSummary {
        calls += 1
        if calls == 1 {
            await withCheckedContinuation { continuation in
                firstPassContinuation = continuation
            }
            return firstResult
        }
        return ArchiveV2DrainPassSummary()
    }

    func releaseFirstPass() {
        firstPassContinuation?.resume()
        firstPassContinuation = nil
    }

    func waitForPassCount(_ expected: Int) async throws {
        for _ in 0 ..< 200 where calls < expected {
            try await Task.sleep(for: .milliseconds(5))
        }
        if calls < expected { throw DrainTestError.timeout }
    }

    func passCount() -> Int { calls }
}

private actor DrainStartRecorder {
    private var started = false

    func recordStart() { started = true }

    func waitUntilStarted() async throws {
        for _ in 0 ..< 200 where !started {
            try await Task.sleep(for: .milliseconds(5))
        }
        if !started { throw DrainTestError.timeout }
    }
}

private final class DrainConditionsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var conditions: ArchiveV2DrainConditions

    init(_ conditions: ArchiveV2DrainConditions) {
        self.conditions = conditions
    }

    func value() -> ArchiveV2DrainConditions {
        lock.withLock { conditions }
    }

    func set(_ value: ArchiveV2DrainConditions) {
        lock.withLock { conditions = value }
    }
}

private enum DrainTestError: Error {
    case timeout
}
