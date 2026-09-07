import Foundation
import XCTest
import CryptoKit
import Darwin
import GRDB
import Security
import EngramCoreRead
@testable import EngramCollectorCore
@testable import EngramCoreWrite
@testable import EngramServiceCore

/// Accounting contracts are independent of the opt-in real-binary runner below.
/// The runner remains a TEST DRAFT until root review and actual execution.
/// This is a synthetic loopback profile, never healthy-tailnet acceptance.
final class CollectorBinaryPerformanceContractTests: XCTestCase {
    func testDeclaredProfileDoesNotReuseTheFiftyMillisecondRuntimeFixture() {
        let profile = CollectorPerformanceProfile.syntheticLoopback
        XCTAssertEqual(profile.configuration, "Release")
        XCTAssertEqual(profile.architecture, "arm64")
        XCTAssertEqual(profile.fileCount, 256)
        XCTAssertEqual(profile.directoryCount, 16)
        XCTAssertEqual(profile.targetFileBytes, 64 * 1024)
        XCTAssertEqual(profile.pollMilliseconds, 1000)
        XCTAssertEqual(profile.bootstrapSeconds, 600)
        XCTAssertEqual(profile.steadySeconds, 1800)
        XCTAssertEqual(profile.drainSeconds, 120)
        XCTAssertEqual(profile.targetAppendBytes, 1024)
        XCTAssertEqual(profile.activeFileCount, 8)
        XCTAssertEqual(profile.resourceSampleSeconds, 1)
        XCTAssertEqual(profile.maximumSampleGapSeconds, 2.5)
        XCTAssertEqual(profile.appendTimeoutSeconds, 120)
        XCTAssertEqual(profile.webRequestTimeoutSeconds, 5)
        XCTAssertEqual(profile.maximumCPUPercentOfOneCore, 2)
        XCTAssertEqual(profile.maximumRSSMiB, 150)
        XCTAssertEqual(profile.maximumWebP95Seconds, 2)
        XCTAssertEqual(profile.networkScope, "synthetic-loopback-not-tailnet")
    }

    func testAbsoluteScheduleHasSixtyAppendsAndThreeIndependentWebSeries() throws {
        let schedule = try CollectorPerformanceAccounting.schedule(.syntheticLoopback)
        XCTAssertEqual(schedule.appends.count, 60)
        XCTAssertEqual(schedule.appends.map(\.offsetSeconds), Array(stride(from: 0, to: 1800, by: 30)))
        XCTAssertEqual(schedule.appends.map(\.fileOrdinal), (0..<60).map { $0 % 8 })
        XCTAssertEqual(Set(schedule.webReads.map(\.endpoint)), Set(CollectorPerformanceEndpoint.allCases))
        for endpoint in CollectorPerformanceEndpoint.allCases {
            let reads = schedule.webReads.filter { $0.endpoint == endpoint }
            XCTAssertEqual(reads.count, 360)
            XCTAssertEqual(reads.map(\.offsetSeconds), Array(stride(from: 0, to: 1800, by: 5)))
        }
        // Schedule offsets are relative to one fixed steady-state start. A slow
        // request must not move the next launch or remove a scheduled attempt.
        XCTAssertEqual(schedule.appends.last?.offsetSeconds, 1770)
    }

    func testMachTickConversionUsesNonUnitTimebaseAndKeepsFractionalNanoseconds() throws {
        let timebase = CollectorPerformanceTimebase(numerator: 125, denominator: 3)
        XCTAssertEqual(try CollectorPerformanceAccounting.nanoseconds(ticks: 24_000_000, timebase: timebase),
                       1_000_000_000, accuracy: 0.001)
        XCTAssertEqual(try CollectorPerformanceAccounting.nanoseconds(ticks: 1, timebase: timebase),
                       125.0 / 3.0, accuracy: 0.000_001)
        XCTAssertEqual(try CollectorPerformanceAccounting.nanoseconds(ticks: 0, timebase: timebase), 0)
    }

    func testMachTickConversionRejectsAnInvalidTimebase() {
        expectFailure(.invalidTimebase) {
            _ = try CollectorPerformanceAccounting.nanoseconds(ticks: 24, timebase: .init(numerator: 125, denominator: 0))
        }
        expectFailure(.invalidTimebase) {
            _ = try CollectorPerformanceAccounting.nanoseconds(ticks: 24, timebase: .init(numerator: 0, denominator: 3))
        }
    }

    func testCPUUsesWholeWindowDeltaForOneCoreWithoutCountingBootstrapOrDividingByCoreCount() throws {
        // Two raw CPU counters each advance 240000 Mach ticks/second. With a
        // 125/3 timebase their combined advance is 20ms CPU per wall second.
        // Large pre-window totals model bootstrap and must cancel in the delta.
        let samples = (0...1800).map { second in
            sample(second: second, userTicks: 9_000_000_000 + UInt64(second) * 240_000,
                   systemTicks: 7_000_000_000 + UInt64(second) * 240_000)
        }
        let result = try CollectorPerformanceAccounting.resources(samples, timebase: .init(numerator: 125, denominator: 3),
            expectedWindowSeconds: 1800, maximumSampleGapSeconds: 2.5)
        XCTAssertEqual(result.elapsedSeconds, 1800)
        XCTAssertEqual(result.cpuPercentOfOneCore, 2, accuracy: 0.000_001)
        XCTAssertEqual(result.timeWeightedMeanRSSMiB, 100, accuracy: 0.000_001)
        XCTAssertEqual(result.sampledMaximumRSSMiB, 100)
        XCTAssertTrue(result.withinThresholds(cpuPercent: 2, rssMiB: 150))
    }

    func testRSSUsesTimeWeightedTrapezoidsAndSampledMaximumRatherThanMeanForGate() throws {
        let samples = [sample(second: 0, rssMiB: 100), sample(second: 1, rssMiB: 200), sample(second: 3, rssMiB: 100)]
        let result = try CollectorPerformanceAccounting.resources(samples, timebase: .init(numerator: 1, denominator: 1),
            expectedWindowSeconds: 3, maximumSampleGapSeconds: 2.5)
        XCTAssertEqual(result.timeWeightedMeanRSSMiB, 150, accuracy: 0.000_001)
        XCTAssertEqual(result.sampledMaximumRSSMiB, 200)
        XCTAssertFalse(result.withinThresholds(cpuPercent: 2, rssMiB: 150))
        // The result deliberately has no field claiming an unsampled peak.
    }

    func testResourceWindowRejectsEmptyShortOrGappedEvidenceInsteadOfFillingZeros() {
        for samples in [[], [sample(second: 0)], [sample(second: 0), sample(second: 1)]] {
            expectFailure(.incompleteWindow) {
                _ = try CollectorPerformanceAccounting.resources(samples, timebase: .init(numerator: 1, denominator: 1),
                    expectedWindowSeconds: 1800, maximumSampleGapSeconds: 2.5)
            }
        }
        expectFailure(.sampleGap) {
            _ = try CollectorPerformanceAccounting.resources([sample(second: 0), sample(second: 4)],
                timebase: .init(numerator: 1, denominator: 1), expectedWindowSeconds: 4, maximumSampleGapSeconds: 2.5)
        }
    }

    func testResourceWindowRejectsReusedPidExitedProcessBackwardClockAndCounterReset() {
        let initial = sample(second: 0, userTicks: 500, systemTicks: 400)
        let cases: [(CollectorPerformanceRawSample, CollectorPerformanceFailure)] = [
            (sample(second: 1, userTicks: 501, systemTicks: 401, processID: 5678), .processIdentityChanged),
            (sample(second: 1, userTicks: 501, systemTicks: 401, startTicks: 999), .processIdentityChanged),
            (sample(second: 1, userTicks: 501, systemTicks: 401, exitTicks: 1), .processExited),
            (sample(second: 0, userTicks: 501, systemTicks: 401), .nonMonotonicClock),
            (sample(second: 1, userTicks: 499, systemTicks: 401), .cpuCounterReset),
            (sample(second: 1, userTicks: 501, systemTicks: 399), .cpuCounterReset),
        ]
        for (last, failure) in cases {
            expectFailure(failure) {
                _ = try CollectorPerformanceAccounting.resources([initial, last], timebase: .init(numerator: 1, denominator: 1),
                    expectedWindowSeconds: 1, maximumSampleGapSeconds: 2.5)
            }
        }
    }

    func testP95UsesNearestRankAcrossTheEntireDeclaredAttemptSet() throws {
        let attempts = (1...20).map { CollectorPerformanceAttempt(ordinal: $0 - 1, status: .success, elapsedSeconds: Double($0)) }
        let result = try CollectorPerformanceAccounting.latencies(attempts, expectedCount: 20, thresholdSeconds: 19)
        XCTAssertEqual(result.p95Seconds, 19)
        XCTAssertEqual(result.attemptCount, 20)
        XCTAssertEqual(result.failedAttemptCount, 0)
        XCTAssertTrue(result.passed)
    }

    func testEvenOneTimeoutFailsAlthoughItsP95IsStillFast() throws {
        var attempts = (0..<100).map { CollectorPerformanceAttempt(ordinal: $0, status: .success, elapsedSeconds: 1) }
        attempts[99] = .init(ordinal: 99, status: .timeout, elapsedSeconds: 120)
        let result = try CollectorPerformanceAccounting.latencies(attempts, expectedCount: 100, thresholdSeconds: 120)
        XCTAssertEqual(result.attemptCount, 100)
        XCTAssertEqual(result.failedAttemptCount, 1)
        XCTAssertEqual(result.p95Seconds, 1)
        XCTAssertFalse(result.passed)
    }

    func testErrorsWrongContentMissesAndCancellationsCannotDisappearFromLatencyDenominator() throws {
        for status in [CollectorPerformanceAttemptStatus.timeout, .httpError, .wrongContent, .missedSchedule, .cancelled] {
            let attempts = [CollectorPerformanceAttempt(ordinal: 0, status: .success, elapsedSeconds: 1),
                            CollectorPerformanceAttempt(ordinal: 1, status: status, elapsedSeconds: nil)]
            let result = try CollectorPerformanceAccounting.latencies(attempts, expectedCount: 2, thresholdSeconds: 2)
            XCTAssertEqual(result.attemptCount, 2)
            XCTAssertEqual(result.failedAttemptCount, 1)
            XCTAssertNil(result.p95Seconds, "censored p95 must serialize as null, never a fabricated zero or JSON infinity")
            XCTAssertFalse(result.passed)
        }
    }

    func testLatencyAccountingRejectsEmptyMissingDuplicatedOrInvalidSuccessDurations() {
        expectFailure(.incompleteAttempts) {
            _ = try CollectorPerformanceAccounting.latencies([], expectedCount: 60, thresholdSeconds: 120)
        }
        expectFailure(.incompleteAttempts) {
            _ = try CollectorPerformanceAccounting.latencies([.init(ordinal: 0, status: .success, elapsedSeconds: 1)],
                expectedCount: 60, thresholdSeconds: 120)
        }
        expectFailure(.incompleteAttempts) {
            _ = try CollectorPerformanceAccounting.latencies([.init(ordinal: 0, status: .success, elapsedSeconds: 1),
                .init(ordinal: 0, status: .success, elapsedSeconds: 1)], expectedCount: 2, thresholdSeconds: 2)
        }
        for elapsed in [Double.nan, .infinity, -1] {
            expectFailure(.invalidDuration) {
                _ = try CollectorPerformanceAccounting.latencies([.init(ordinal: 0, status: .success, elapsedSeconds: elapsed)],
                    expectedCount: 1, thresholdSeconds: 2)
            }
        }
    }

    func testReleaseEvidenceChecksMetadataAndObservedDigestNotTheDirectoryName() throws {
        let good = releaseEvidence()
        try CollectorPerformanceAccounting.validateReleaseEvidence([good])
        var debug = good
        debug.configuration = "Debug"
        expectFailure(.releaseEvidence) { try CollectorPerformanceAccounting.validateReleaseEvidence([debug]) }
        var mismatch = good
        mismatch.observedSHA256 = String(repeating: "b", count: 64)
        expectFailure(.releaseEvidence) { try CollectorPerformanceAccounting.validateReleaseEvidence([mismatch]) }
        var wrongArchitecture = good
        wrongArchitecture.architecture = "x86_64"
        expectFailure(.releaseEvidence) { try CollectorPerformanceAccounting.validateReleaseEvidence([wrongArchitecture]) }
    }

    private func sample(second: Int, userTicks: UInt64 = 0, systemTicks: UInt64 = 0,
                        rssMiB: UInt64 = 100, processID: Int32 = 1234,
                        startTicks: UInt64 = 123, exitTicks: UInt64 = 0) -> CollectorPerformanceRawSample {
        .init(monotonicNanoseconds: UInt64(second) * 1_000_000_000, processID: processID,
            processStartMachTicks: startTicks, processExitMachTicks: exitTicks,
            userMachTicks: userTicks, systemMachTicks: systemTicks, residentBytes: rssMiB * 1_048_576)
    }

    private func releaseEvidence() -> CollectorPerformanceReleaseEvidence {
        .init(product: "EngramCollector", configuration: "Release", architecture: "arm64",
            executablePath: "/synthetic/package/bin/EngramCollector", sourceRevision: String(repeating: "a", count: 40),
            expectedSHA256: String(repeating: "a", count: 64), observedSHA256: String(repeating: "a", count: 64))
    }

    private func expectFailure(_ expected: CollectorPerformanceFailure, file: StaticString = #filePath,
                               line: UInt = #line, _ body: () throws -> Void) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? CollectorPerformanceFailure, expected, file: file, line: line)
        }
    }
}

final class CollectorBinaryPerformanceFinalSessionContractTests: XCTestCase {
    func testFixedSchedulePinsTheCompleteFinalSessionBuckets() throws {
        let schedule = try CollectorPerformanceAccounting.schedule(.syntheticLoopback)
        let expected = try PerformanceFinalSessionOracle.expectedBuckets(schedule)
        XCTAssertEqual(expected, [
            .init(source: "codex", tier: "normal", messageCount: 2): 248,
            .init(source: "codex", tier: "normal", messageCount: 9): 4,
            .init(source: "codex", tier: "premium", messageCount: 10): 4,
        ])
        XCTAssertEqual(expected.values.reduce(0, +), 256)
    }

    func testFinalOracleAcceptsTheFourScheduledPremiumPromotions() throws {
        XCTAssertTrue(try matches(validRows()))
    }

    func testFinalOracleRejectsAllNormalEvenWithExactly256Sessions() throws {
        let rows = validRows().map {
            PerformanceFinalSessionBucket(source: $0.source, tier: "normal", messageCount: $0.messageCount)
        }
        XCTAssertFalse(try matches(rows))
    }

    func testFinalOracleRejectsSwappedTiersEvenWith252NormalAndFourPremium() throws {
        var rows = validRows()
        rows[0] = .init(source: "codex", tier: "premium", messageCount: 2)
        rows[255] = .init(source: "codex", tier: "normal", messageCount: 10)
        XCTAssertEqual(rows.filter { $0.tier == "normal" }.count, 252)
        XCTAssertEqual(rows.filter { $0.tier == "premium" }.count, 4)
        XCTAssertFalse(try matches(rows))
    }

    func testFinalOracleRejectsWrongSourceSkipLiteAndWrongMessageCount() throws {
        for replacement in [
            PerformanceFinalSessionBucket(source: "claude-code", tier: "normal", messageCount: 2),
            .init(source: "codex", tier: "skip", messageCount: 2),
            .init(source: "codex", tier: "lite", messageCount: 2),
            .init(source: "codex", tier: "normal", messageCount: 3),
        ] {
            var rows = validRows()
            rows[0] = replacement
            XCTAssertFalse(try matches(rows), "Unexpectedly accepted \(replacement)")
        }
    }

    func testFinalOracleRejectsMissingExtraAndEmptyRows() throws {
        XCTAssertFalse(try matches(Array(validRows().dropLast())))
        XCTAssertFalse(try matches(validRows() + [.init(source: "codex", tier: "normal", messageCount: 2)]))
        XCTAssertFalse(try matches([]))
    }

    private func validRows() -> [PerformanceFinalSessionBucket] {
        // Independent literals: do not populate the SQL fixture from the oracle.
        Array(repeating: .init(source: "codex", tier: "normal", messageCount: 2), count: 248)
            + Array(repeating: .init(source: "codex", tier: "normal", messageCount: 9), count: 4)
            + Array(repeating: .init(source: "codex", tier: "premium", messageCount: 10), count: 4)
    }

    private func matches(_ rows: [PerformanceFinalSessionBucket]) throws -> Bool {
        let queue = try DatabaseQueue()
        defer { try? queue.close() }
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE sessions (source TEXT NOT NULL, tier TEXT NOT NULL, message_count INTEGER NOT NULL)")
            for row in rows {
                try db.execute(sql: "INSERT INTO sessions (source, tier, message_count) VALUES (?, ?, ?)",
                    arguments: [row.source, row.tier, row.messageCount])
            }
        }
        let schedule = try CollectorPerformanceAccounting.schedule(.syntheticLoopback)
        return try queue.read { try PerformanceFinalSessionOracle.matches($0, schedule: schedule) }
    }
}

private struct PerformanceFinalSessionBucket: Hashable {
    let source: String
    let tier: String
    let messageCount: Int
}

private enum PerformanceFinalSessionOracle {
    static func expectedBuckets(_ schedule: CollectorPerformanceSchedule) throws -> [PerformanceFinalSessionBucket: Int] {
        var messageCounts = Array(repeating: 2, count: CollectorPerformanceProfile.syntheticLoopback.fileCount)
        for append in schedule.appends {
            guard messageCounts.indices.contains(append.fileOrdinal) else { throw PerformanceRunError.configuration }
            messageCounts[append.fileOrdinal] += 1
        }
        var expected: [PerformanceFinalSessionBucket: Int] = [:]
        for (ordinal, count) in messageCounts.enumerated() {
            // The declared corpus has one user, then assistants, a project,
            // no preamble/noise, and timestamps spanning less than two minutes.
            let tier = SessionTier.compute(TierInput(messageCount: count,
                filePath: "/synthetic/performance/rollout-\(ordinal).jsonl", project: "/synthetic/performance/project",
                startTime: "2026-09-07T00:00:00Z", endTime: "2026-09-07T00:01:01Z", source: "codex",
                assistantCount: count - 1, toolCount: 0))
            expected[.init(source: "codex", tier: tier.rawValue, messageCount: count), default: 0] += 1
        }
        return expected
    }

    static func matches(_ db: Database, schedule: CollectorPerformanceSchedule) throws -> Bool {
        let expected = try expectedBuckets(schedule)
        let rows = try Row.fetchAll(db, sql: "SELECT source, tier, message_count, COUNT(*) AS row_count FROM sessions GROUP BY source, tier, message_count")
        var observed: [PerformanceFinalSessionBucket: Int] = [:]
        for row in rows {
            guard let source = String.fromDatabaseValue(row["source"]), let tier = String.fromDatabaseValue(row["tier"]),
                  let messageCount = Int.fromDatabaseValue(row["message_count"]), let count = Int.fromDatabaseValue(row["row_count"]),
                  messageCount >= 0, count > 0 else { return false }
            observed[.init(source: source, tier: tier, messageCount: messageCount)] = count
        }
        return observed == expected
    }
}

final class CollectorBinaryPerformanceAuthenticationContractTests: XCTestCase {
    func testTwoAbsoluteRefreshesCoverTheWindowWithoutExtendingTheNineHundredSecondCookieLifetime() throws {
        let schedule = try PerformanceAuthenticationSchedule.syntheticLoopback()
        XCTAssertEqual(schedule.cookieLifetimeSeconds, 900)
        XCTAssertEqual(schedule.initialValidityUntilSeconds, 900)
        XCTAssertEqual(schedule.refreshOffsetsSeconds, [600, 1200])
        XCTAssertEqual(schedule.refreshValidityUntilSeconds, [1500, 2100])
        var validUntil = schedule.initialValidityUntilSeconds
        for (offset, nextExpiry) in zip(schedule.refreshOffsetsSeconds, schedule.refreshValidityUntilSeconds) {
            XCTAssertLessThan(offset + CollectorPerformanceProfile.syntheticLoopback.webRequestTimeoutSeconds, validUntil)
            validUntil = nextExpiry
        }
        XCTAssertEqual(validUntil, 2100)
        XCTAssertGreaterThan(validUntil, CollectorPerformanceProfile.syntheticLoopback.steadySeconds
            + CollectorPerformanceProfile.syntheticLoopback.drainSeconds)
    }
}

final class CollectorBinaryPerformanceTests: XCTestCase {
    func testReleaseCollectorSyntheticLoopbackThirtyMinuteWindow() async throws {
        guard ProcessInfo.processInfo.environment["ENGRAM_COLLECTOR_PERFORMANCE"] == "1" else {
            throw XCTSkip("Performance run requires explicit opt-in; no files, processes or samples were created")
        }
        let inputs = try PerformanceInputs.preflight(ProcessInfo.processInfo.environment)
        executionTimeAllowance = 2700
        let evidence = try PerformanceEvidence(inputs: inputs)
        var scope: PerformanceScope?
        var failure: Error?
        do {
            let owned = try PerformanceScope(inputs: inputs, evidence: evidence)
            scope = owned
            try await owned.run()
        } catch {
            failure = error
            evidence.fail(PerformanceRunError.code(error))
        }
        evidence.fillMissing(series: "append", count: 60, interval: 30, status: .cancelled)
        for endpoint in CollectorPerformanceEndpoint.allCases {
            evidence.fillMissing(series: endpoint.rawValue, count: 360, interval: 5, status: .cancelled)
        }
        evidence.fillMissingAuthentication()
        let retaining = failure != nil || evidence.shouldAbort
        let ownedScope = scope
        let cleanup = Task.detached { try await ownedScope?.close(retainFixture: retaining) }
        do { try await cleanup.value }
        catch { failure = error; evidence.fail("cleanup_failed") }
        do { try evidence.finish(fixtureRetained: retaining || failure != nil) }
        catch { failure = error }
        if let failure { throw failure }
        guard !evidence.shouldAbort else { throw PerformanceRunError.threshold }
    }
}

private struct CollectorPerformanceProfile {
    static let syntheticLoopback = Self()
    let configuration = "Release"
    let architecture = "arm64"
    let fileCount = 256
    let directoryCount = 16
    let targetFileBytes = 64 * 1024
    let pollMilliseconds = 1000 // An explicitly synthetic choice, not a product default.
    let bootstrapSeconds = 600
    let steadySeconds = 1800
    let drainSeconds = 120
    let appendEverySeconds = 30
    let activeFileCount = 8
    let targetAppendBytes = 1024
    let readEverySeconds = 5
    let resourceSampleSeconds = 1
    let maximumSampleGapSeconds = 2.5
    let appendTimeoutSeconds = 120
    let webRequestTimeoutSeconds = 5
    let maximumCPUPercentOfOneCore = 2.0
    let maximumRSSMiB = 150.0
    let maximumWebP95Seconds = 2.0
    let networkScope = "synthetic-loopback-not-tailnet"
}

private enum CollectorPerformanceEndpoint: String, CaseIterable, Hashable { case sessions, detail, messages }
private struct CollectorPerformanceSchedule {
    struct Append { let offsetSeconds: Int; let fileOrdinal: Int }
    struct Read { let offsetSeconds: Int; let endpoint: CollectorPerformanceEndpoint }
    let appends: [Append]
    let webReads: [Read]
}

private struct CollectorPerformanceTimebase: Codable {
    let numerator: UInt32
    let denominator: UInt32
}

/// Preserve raw kernel values and identity alongside the manifest timebase.
/// SDK inspected: Xcode-beta.app/.../MacOSX27.0.sdk/usr/include/sys/resource.h
/// (rusage_info_v2) and usr/include/libproc.h (proc_pid_rusage).
/// Apple XNU unit trace, inspected 2026-09-07 (not a host measurement):
/// https://github.com/apple-oss-distributions/xnu/blob/main/libsyscall/wrappers/libproc/libproc.c#L129-L132
/// https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_resource.c#L3219-L3222
/// https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_resource.c#L3271-L3276
/// https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c#L1193-L1211
/// https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/task.c#L6391-L6392
/// https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/task.c#L1197-L1198
/// CPU is Mach time (convert with recorded numer/denom); resident_size is bytes.
private struct CollectorPerformanceRawSample: Codable {
    let monotonicNanoseconds: UInt64
    let processID: Int32
    let processStartMachTicks: UInt64
    let processExitMachTicks: UInt64
    let userMachTicks: UInt64
    let systemMachTicks: UInt64
    let residentBytes: UInt64
}

private struct CollectorPerformanceResourceResult {
    let elapsedSeconds: Double
    let cpuPercentOfOneCore: Double
    let timeWeightedMeanRSSMiB: Double
    let sampledMaximumRSSMiB: Double
    func withinThresholds(cpuPercent: Double, rssMiB: Double) -> Bool {
        cpuPercentOfOneCore <= cpuPercent && sampledMaximumRSSMiB <= rssMiB
    }
}

private enum CollectorPerformanceAttemptStatus: String, Codable {
    case success, timeout, httpError, wrongContent, missedSchedule, cancelled
}
private struct CollectorPerformanceAttempt: Codable {
    let ordinal: Int
    let status: CollectorPerformanceAttemptStatus
    let elapsedSeconds: Double?
}
private struct CollectorPerformanceLatencyResult {
    let attemptCount: Int
    let failedAttemptCount: Int
    let p95Seconds: Double?
    let passed: Bool
}
private struct CollectorPerformanceReleaseEvidence {
    let product: String
    var configuration: String
    var architecture: String
    let executablePath: String
    let sourceRevision: String
    let expectedSHA256: String
    var observedSHA256: String
}

private enum CollectorPerformanceFailure: Error, Equatable {
    case notImplemented, invalidTimebase, incompleteWindow, sampleGap
    case processIdentityChanged, processExited, nonMonotonicClock, cpuCounterReset
    case incompleteAttempts, invalidDuration, releaseEvidence
}

/// Deliberate TEST-DRAFT stubs. The parent must establish actual RED before any
/// accounting implementation or side-effectful measurement lifecycle is added.
private enum CollectorPerformanceAccounting {
    static func schedule(_ profile: CollectorPerformanceProfile) throws -> CollectorPerformanceSchedule {
        let appends = stride(from: 0, to: profile.steadySeconds, by: profile.appendEverySeconds)
            .enumerated().map { ordinal, offset in
                CollectorPerformanceSchedule.Append(offsetSeconds: offset, fileOrdinal: ordinal % profile.activeFileCount)
            }
        let reads = stride(from: 0, to: profile.steadySeconds, by: profile.readEverySeconds).flatMap { offset in
            CollectorPerformanceEndpoint.allCases.map {
                CollectorPerformanceSchedule.Read(offsetSeconds: offset, endpoint: $0)
            }
        }
        return .init(appends: appends, webReads: reads)
    }
    static func nanoseconds(ticks: UInt64, timebase: CollectorPerformanceTimebase) throws -> Double {
        guard timebase.numerator > 0, timebase.denominator > 0 else { throw CollectorPerformanceFailure.invalidTimebase }
        return Double(ticks) * Double(timebase.numerator) / Double(timebase.denominator)
    }
    static func resources(_ samples: [CollectorPerformanceRawSample], timebase: CollectorPerformanceTimebase,
                          expectedWindowSeconds: Double, maximumSampleGapSeconds: Double) throws -> CollectorPerformanceResourceResult {
        _ = try nanoseconds(ticks: 0, timebase: timebase)
        guard expectedWindowSeconds.isFinite, expectedWindowSeconds > 0,
              maximumSampleGapSeconds.isFinite, maximumSampleGapSeconds > 0,
              samples.count >= 2, let first = samples.first, let last = samples.last else {
            throw CollectorPerformanceFailure.incompleteWindow
        }
        guard first.processID > 0, first.processStartMachTicks > 0 else {
            throw CollectorPerformanceFailure.processIdentityChanged
        }
        var previous: CollectorPerformanceRawSample?
        var rssMiBSeconds = 0.0
        var maximumRSSMiB = 0.0
        for current in samples {
            guard current.processID == first.processID, current.processStartMachTicks == first.processStartMachTicks else {
                throw CollectorPerformanceFailure.processIdentityChanged
            }
            guard current.processExitMachTicks == 0 else { throw CollectorPerformanceFailure.processExited }
            let currentRSSMiB = Double(current.residentBytes) / 1_048_576
            maximumRSSMiB = max(maximumRSSMiB, currentRSSMiB)
            if let prior = previous {
                guard current.monotonicNanoseconds > prior.monotonicNanoseconds else {
                    throw CollectorPerformanceFailure.nonMonotonicClock
                }
                guard current.userMachTicks >= prior.userMachTicks, current.systemMachTicks >= prior.systemMachTicks else {
                    throw CollectorPerformanceFailure.cpuCounterReset
                }
                let gapSeconds = Double(current.monotonicNanoseconds - prior.monotonicNanoseconds) / 1_000_000_000
                guard gapSeconds <= maximumSampleGapSeconds else { throw CollectorPerformanceFailure.sampleGap }
                let priorRSSMiB = Double(prior.residentBytes) / 1_048_576
                rssMiBSeconds += (priorRSSMiB + currentRSSMiB) * 0.5 * gapSeconds
            }
            previous = current
        }
        let elapsedNanoseconds = Double(last.monotonicNanoseconds - first.monotonicNanoseconds)
        let elapsedSeconds = elapsedNanoseconds / 1_000_000_000
        guard elapsedSeconds >= expectedWindowSeconds,
              elapsedSeconds - expectedWindowSeconds <= maximumSampleGapSeconds else {
            throw CollectorPerformanceFailure.incompleteWindow
        }
        // Subtract each UInt64 counter before conversion. Never subtract large
        // floating-point lifetime totals or add raw counters that could overflow.
        let userNanoseconds = try nanoseconds(ticks: last.userMachTicks - first.userMachTicks, timebase: timebase)
        let systemNanoseconds = try nanoseconds(ticks: last.systemMachTicks - first.systemMachTicks, timebase: timebase)
        return .init(elapsedSeconds: elapsedSeconds,
            cpuPercentOfOneCore: (userNanoseconds + systemNanoseconds) / elapsedNanoseconds * 100,
            timeWeightedMeanRSSMiB: rssMiBSeconds / elapsedSeconds, sampledMaximumRSSMiB: maximumRSSMiB)
    }
    static func latencies(_ attempts: [CollectorPerformanceAttempt], expectedCount: Int,
                          thresholdSeconds: Double) throws -> CollectorPerformanceLatencyResult {
        guard expectedCount > 0, attempts.count == expectedCount,
              Set(attempts.map(\.ordinal)) == Set(0..<expectedCount) else {
            throw CollectorPerformanceFailure.incompleteAttempts
        }
        guard thresholdSeconds.isFinite, thresholdSeconds >= 0 else { throw CollectorPerformanceFailure.invalidDuration }
        var successes: [Double] = []
        for attempt in attempts {
            if let elapsed = attempt.elapsedSeconds, !elapsed.isFinite || elapsed < 0 {
                throw CollectorPerformanceFailure.invalidDuration
            }
            if attempt.status == .success {
                guard let elapsed = attempt.elapsedSeconds else { throw CollectorPerformanceFailure.invalidDuration }
                successes.append(elapsed)
            }
        }
        successes.sort()
        let failedCount = attempts.count - successes.count
        // ceil(0.95 * n), calculated without floating-point rank rounding.
        // Failures sort after every success and remain censored, not omitted.
        let rank = expectedCount - expectedCount / 20
        let p95 = rank <= successes.count ? successes[rank - 1] : nil
        return .init(attemptCount: expectedCount, failedAttemptCount: failedCount, p95Seconds: p95,
            passed: failedCount == 0 && p95.map { $0 <= thresholdSeconds } == true)
    }
    static func validateReleaseEvidence(_ evidence: [CollectorPerformanceReleaseEvidence]) throws {
        guard !evidence.isEmpty, Set(evidence.map(\.product)).count == evidence.count,
              Set(evidence.map(\.executablePath)).count == evidence.count else {
            throw CollectorPerformanceFailure.releaseEvidence
        }
        let products: Set<String> = ["EngramCollector", "EngramService", "EngramRemoteServer"]
        func lowercaseHex(_ text: String, count: Int) -> Bool {
            text.utf8.count == count && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        for binary in evidence {
            guard products.contains(binary.product), binary.configuration == "Release", binary.architecture == "arm64",
                  binary.executablePath.hasPrefix("/"), !binary.executablePath.utf8.contains(0),
                  lowercaseHex(binary.sourceRevision, count: 40), lowercaseHex(binary.expectedSHA256, count: 64),
                  lowercaseHex(binary.observedSHA256, count: 64), binary.expectedSHA256 == binary.observedSHA256 else {
                throw CollectorPerformanceFailure.releaseEvidence
            }
        }
    }
}

// MARK: - Opt-in real-binary runner (independent draft; not runtime proof)

private struct PerformanceAuthenticationSchedule {
    let cookieLifetimeSeconds: Int
    let initialValidityUntilSeconds: Int
    let refreshOffsetsSeconds: [Int]
    let refreshValidityUntilSeconds: [Int]

    static func syntheticLoopback() throws -> Self {
        // WebAuthSessionStore issues independent 900-second sessions. Refresh
        // before expiry; never change product TTL or repair a failed read by login.
        let lifetime = 900
        let offsets = [600, 1200]
        return Self(cookieLifetimeSeconds: lifetime, initialValidityUntilSeconds: lifetime,
            refreshOffsetsSeconds: offsets, refreshValidityUntilSeconds: offsets.map { $0 + lifetime })
    }
}

private enum PerformanceRunError: Error {
    case configuration, evidenceIO, binaryChanged, childExited, cleanup, sampling
    case deadline, httpStatus(Int), payloadLimit, wrongContent, sourceChanged, threshold

    static func code(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let url = error as? URLError { return url.code == .timedOut ? "timeout" : "http_transport" }
        if let value = error as? Self {
            switch value {
            case .configuration: return "configuration"
            case .evidenceIO: return "evidence_io"
            case .binaryChanged: return "binary_changed"
            case .childExited: return "child_exited"
            case .cleanup: return "cleanup_failed"
            case .sampling: return "sampling_failed"
            case .deadline: return "deadline"
            case .httpStatus(let status): return "http_status_\(status)"
            case .payloadLimit: return "payload_limit"
            case .wrongContent: return "wrong_content"
            case .sourceChanged: return "source_changed"
            case .threshold: return "threshold"
            }
        }
        return "validation_failed" // Never serialize underlying paths, credentials or error descriptions.
    }

    static func attemptStatus(_ error: Error) -> CollectorPerformanceAttemptStatus {
        switch code(error) {
        case "cancelled": return .cancelled
        case "timeout", "deadline": return .timeout
        case "wrong_content", "source_changed", "validation_failed": return .wrongContent
        default: return .httpError
        }
    }
}

private enum PerformanceFiles {
    static func absolute(_ text: String) throws -> URL {
        guard text.hasPrefix("/"), !text.utf8.contains(0),
              !text.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw PerformanceRunError.configuration
        }
        return URL(fileURLWithPath: text)
    }

    static func directory(_ url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { throw PerformanceRunError.configuration }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
    }

    static func read(_ url: URL, maximum: Int, privateFile: Bool = true, allowMissing: Bool = false) throws -> Data? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0, allowMissing, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw PerformanceRunError.configuration }
        defer { _ = Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0, before.st_size <= maximum,
              !privateFile || (before.st_uid == geteuid() && before.st_mode & 0o7777 == 0o600) else {
            throw PerformanceRunError.configuration
        }
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: min(maximum + 1, 65_536))
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw PerformanceRunError.configuration }
            if count == 0 { break }
            guard output.count <= maximum - count else { throw PerformanceRunError.payloadLimit }
            output.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, output.count == Int(after.st_size),
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw PerformanceRunError.binaryChanged
        }
        return output
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    static func write(_ data: Data, to url: URL, append: Bool = false, synchronize: Bool = false) throws {
        let flags = O_WRONLY | O_NOFOLLOW | O_NONBLOCK | (append ? O_APPEND : O_CREAT | O_EXCL)
        let descriptor = Darwin.open(url.path, flags, 0o600)
        guard descriptor >= 0 else { throw PerformanceRunError.evidenceIO }
        var closed = false
        defer { if !closed { _ = Darwin.close(descriptor) } }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_mode & 0o7777 == 0o600 else { throw PerformanceRunError.evidenceIO }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw PerformanceRunError.evidenceIO }
                offset += count
            }
        }
        if synchronize, fsync(descriptor) != 0 { throw PerformanceRunError.evidenceIO }
        guard Darwin.close(descriptor) == 0 else { closed = true; throw PerformanceRunError.evidenceIO }
        closed = true
    }
}

private struct PerformanceInputs: @unchecked Sendable {
    struct Binary: Codable, Sendable {
        let product: String
        let executablePath: String
        let configuration: String
        let architecture: String
        let sourceRevision: String
        let sha256: String
    }
    struct Node: Codable, Sendable { let executablePath: String; let sha256: String }
    struct Receipt: Decodable { let schemaVersion: Int; let binaries: [Binary]; let node: Node }
    let binaries: [Binary]
    let node: Node
    let helper: URL
    let helperSHA256: String
    let artifactRoot: URL
    let runID: String

    func binary(_ product: String) throws -> URL {
        guard let entry = binaries.first(where: { $0.product == product }) else { throw PerformanceRunError.configuration }
        return URL(fileURLWithPath: entry.executablePath)
    }

    static func preflight(_ environment: [String: String]) throws -> Self {
        let required = ["ENGRAM_COLLECTOR_BINARY", "ENGRAM_SERVICE_BINARY", "ENGRAM_REMOTE_SERVER_BINARY",
            "ENGRAM_SHADOW_NODE_BINARY", "ENGRAM_COLLECTOR_PERFORMANCE_BUILD_EVIDENCE",
            "ENGRAM_COLLECTOR_PERFORMANCE_ARTIFACT_DIR"]
        guard required.allSatisfy({ environment[$0]?.isEmpty == false }) else {
            throw XCTSkip("Performance requires three explicit Release binaries, Node, build evidence and artifact directory; no fixture was created")
        }
        let receiptURL = try PerformanceFiles.absolute(environment[required[4]]!)
        let receipt = try JSONDecoder().decode(Receipt.self, from: XCTUnwrap(PerformanceFiles.read(receiptURL, maximum: 65_536)))
        guard receipt.schemaVersion == 1, receipt.binaries.count == 3,
              Set(receipt.binaries.map(\.product)) == ["EngramCollector", "EngramService", "EngramRemoteServer"] else {
            throw PerformanceRunError.configuration
        }
        let products = ["EngramCollector", "EngramService", "EngramRemoteServer"]
        var evidence: [CollectorPerformanceReleaseEvidence] = []
        for (index, product) in products.enumerated() {
            let path = try PerformanceFiles.absolute(environment[required[index]]!)
            guard let binary = receipt.binaries.first(where: { $0.product == product }),
                  binary.executablePath == path.path, FileManager.default.isExecutableFile(atPath: path.path) else {
                throw PerformanceRunError.configuration
            }
            let digest = PerformanceFiles.digest(try XCTUnwrap(PerformanceFiles.read(path, maximum: 512 * 1024 * 1024, privateFile: false)))
            evidence.append(.init(product: product, configuration: binary.configuration, architecture: binary.architecture,
                executablePath: path.path, sourceRevision: binary.sourceRevision, expectedSHA256: binary.sha256, observedSHA256: digest))
        }
        try CollectorPerformanceAccounting.validateReleaseEvidence(evidence)
        let nodeURL = try PerformanceFiles.absolute(environment[required[3]]!)
        guard receipt.node.executablePath == nodeURL.path, FileManager.default.isExecutableFile(atPath: nodeURL.path),
              PerformanceFiles.digest(try XCTUnwrap(PerformanceFiles.read(nodeURL, maximum: 512 * 1024 * 1024, privateFile: false))) == receipt.node.sha256,
              FileManager.default.isExecutableFile(atPath: "/usr/bin/openssl") else { throw PerformanceRunError.configuration }
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helper = checkout.appendingPathComponent("scripts/collector-shadow-tls.mjs")
        let helperHash = PerformanceFiles.digest(try XCTUnwrap(PerformanceFiles.read(helper, maximum: 65_536, privateFile: false)))
        guard helperHash == "c1e04b4ec204098036c6785e054e47fc6bc0a3b1a54bbe04c7d646f970410121" else {
            throw PerformanceRunError.configuration
        }
        let artifact = try PerformanceFiles.absolute(environment[required[5]]!)
        var info = stat()
        if lstat(artifact.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o7777 == 0o700,
                  try FileManager.default.contentsOfDirectory(atPath: artifact.path).isEmpty else { throw PerformanceRunError.configuration }
        } else {
            guard errno == ENOENT else { throw PerformanceRunError.configuration }
            var parent = stat()
            guard stat(artifact.deletingLastPathComponent().path, &parent) == 0, parent.st_mode & S_IFMT == S_IFDIR else {
                throw PerformanceRunError.configuration
            }
        }
        return Self(binaries: receipt.binaries, node: receipt.node, helper: helper, helperSHA256: helperHash,
            artifactRoot: artifact, runID: UUID().uuidString)
    }
}

private struct PerformanceAttemptRecord: Codable {
    let series: String
    let ordinal: Int
    let scheduledOffsetSeconds: Int
    let status: CollectorPerformanceAttemptStatus
    let elapsedSeconds: Double?
    let startedNanoseconds: UInt64?
    let finishedNanoseconds: UInt64?
    let errorCode: String?
    let marker: String?
    let sessionID: String?
    let generation: String?
    var observationNanoseconds: UInt64? = nil
    var accounting: CollectorPerformanceAttempt { .init(ordinal: ordinal, status: status, elapsedSeconds: elapsedSeconds) }
}

private struct PerformanceAuthenticationRecord: Codable {
    let ordinal: Int // 0: fresh pre-steady login; 1 and 2: independent refreshes.
    let scheduledOffsetSeconds: Int?
    let status: CollectorPerformanceAttemptStatus
    let elapsedSeconds: Double?
    let startedNanoseconds: UInt64?
    let finishedNanoseconds: UInt64?
    let errorCode: String?
}

private final class PerformanceEvidence: @unchecked Sendable {
    let root: URL
    private let lock = NSLock()
    private var samples: [CollectorPerformanceRawSample] = []
    private var attempts: [String: [Int: PerformanceAttemptRecord]] = [:]
    private var authenticationAttempts: [Int: PerformanceAuthenticationRecord] = [:]
    private var failures: [String] = []
    private var metrics: [String: Any] = [:]
    var shouldAbort: Bool { lock.withLock { !failures.isEmpty } }

    init(tlsProbeInputs inputs: PerformanceInputs) throws {
        root = inputs.artifactRoot
        if !FileManager.default.fileExists(atPath: root.path) { try PerformanceFiles.directory(root) }
        try PerformanceFiles.write(Data(), to: root.appendingPathComponent("lifecycle.jsonl"))
        let nodeJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(inputs.node))
        try PerformanceFiles.write(PerformanceFiles.json([
            "schemaVersion": 1, "runID": inputs.runID, "runKind": "native-async-bytes-tls-contract",
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "networkScope": "synthetic-loopback-not-tailnet", "node": nodeJSON,
            "tlsHelperSHA256": inputs.helperSHA256, "deadlineSeconds": 30,
            "workDeadlineSeconds": 22, "requestMaximumSeconds": 5,
            "productBinariesStarted": 0, "corpusGenerated": false, "performanceMeasured": false,
            "differentDERPin": "Original DER with one signature byte changed; parseable, not a second valid signed certificate",
        ]), to: root.appendingPathComponent("tls-inputs.json"), synchronize: true)
        print("COLLECTOR_TLS_PROBE_ARTIFACTS path=\(root.path)")
    }

    init(inputs: PerformanceInputs) throws {
        root = inputs.artifactRoot
        if !FileManager.default.fileExists(atPath: root.path) { try PerformanceFiles.directory(root) }
        for name in ["samples.jsonl", "attempts.jsonl", "authentication.jsonl", "lifecycle.jsonl"] {
            try PerformanceFiles.write(Data(), to: root.appendingPathComponent(name))
        }
        let binaryJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(inputs.binaries))
        let nodeJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(inputs.node))
        let host = ProcessInfo.processInfo
        let authentication = try PerformanceAuthenticationSchedule.syntheticLoopback()
        try PerformanceFiles.write(PerformanceFiles.json([
            "schemaVersion": 1, "runID": inputs.runID, "createdAt": ISO8601DateFormatter().string(from: Date()),
            "networkScope": "synthetic-loopback-not-tailnet", "binaries": binaryJSON, "node": nodeJSON,
            "tlsHelperSHA256": inputs.helperSHA256,
            "host": ["os": host.operatingSystemVersionString, "logicalCPUCount": host.processorCount,
                "activeCPUCount": host.activeProcessorCount, "physicalMemoryBytes": host.physicalMemory],
            "profile": PerformanceScope.declaredProfile,
            "authentication": ["cookieLifetimeSeconds": authentication.cookieLifetimeSeconds,
                "freshLoginBeforeFirstSteadySample": true, "refreshOffsetsSeconds": authentication.refreshOffsetsSeconds,
                "refreshValidityUntilSeconds": authentication.refreshValidityUntilSeconds,
                "scheduledRefreshAttemptCount": 2, "totalMeasuredAuthenticationAttemptCount": 3,
                "includedInReadLatencyDenominators": false, "retries": 0, "failureFailsOverallGate": true],
            "authority": "Explicit root-supplied build receipt plus matching on-disk hashes; no package-only requirement",
            "limitations": ["Synthetic Codex corpus only", "Loopback, not healthy tailnet", "RSS maximum is sampled, not an unsampled peak",
                "HTTPS API latency is not browser rendering latency", "Other host work is not stopped or adjusted"],
        ]), to: root.appendingPathComponent("inputs.json"), synchronize: true)
        print("COLLECTOR_PERFORMANCE_ARTIFACTS path=\(root.path)")
    }

    private func append<T: Encodable>(_ value: T, file: String) throws {
        var bytes = try JSONEncoder().encode(value); bytes.append(10)
        try PerformanceFiles.write(bytes, to: root.appendingPathComponent(file), append: true)
    }

    func lifecycle(_ code: String, values: [String: Any] = [:]) throws {
        try lock.withLock {
            var item = values; item["event"] = code
            var bytes = try PerformanceFiles.json(item); bytes.append(10)
            try PerformanceFiles.write(bytes, to: root.appendingPathComponent("lifecycle.jsonl"), append: true)
        }
    }

    func fail(_ code: String) {
        lock.withLock {
            failures.append(code)
            var bytes = (try? PerformanceFiles.json(["event": "failure", "code": code])) ?? Data()
            bytes.append(10)
            try? PerformanceFiles.write(bytes, to: root.appendingPathComponent("lifecycle.jsonl"), append: true)
        }
    }

    func sample(_ value: CollectorPerformanceRawSample) throws {
        try lock.withLock { try append(value, file: "samples.jsonl"); samples.append(value) }
    }

    func attempt(_ value: PerformanceAttemptRecord) throws {
        try lock.withLock {
            guard attempts[value.series]?[value.ordinal] == nil else { throw PerformanceRunError.evidenceIO }
            try append(value, file: "attempts.jsonl")
            attempts[value.series, default: [:]][value.ordinal] = value
        }
    }

    func fillMissing(series: String, count: Int, interval: Int, status: CollectorPerformanceAttemptStatus) {
        for ordinal in 0..<count {
            let present = lock.withLock { attempts[series]?[ordinal] != nil }
            if !present {
                do {
                    try attempt(.init(series: series, ordinal: ordinal, scheduledOffsetSeconds: ordinal * interval,
                        status: status, elapsedSeconds: nil, startedNanoseconds: nil, finishedNanoseconds: nil,
                        errorCode: "scheduled_attempt_not_completed", marker: nil, sessionID: nil, generation: nil))
                } catch { fail("evidence_io") }
            }
        }
    }

    func authentication(_ value: PerformanceAuthenticationRecord) throws {
        let offsets = try PerformanceAuthenticationSchedule.syntheticLoopback().refreshOffsetsSeconds
        guard (0...offsets.count).contains(value.ordinal),
              value.scheduledOffsetSeconds == (value.ordinal == 0 ? nil : offsets[value.ordinal - 1]) else {
            throw PerformanceRunError.evidenceIO
        }
        try lock.withLock {
            guard authenticationAttempts[value.ordinal] == nil else { throw PerformanceRunError.evidenceIO }
            try append(value, file: "authentication.jsonl")
            authenticationAttempts[value.ordinal] = value
            if value.status != .success { failures.append("authentication_" + (value.errorCode ?? "failed")) }
        }
    }

    func fillMissingAuthentication() {
        do {
            let offsets = try PerformanceAuthenticationSchedule.syntheticLoopback().refreshOffsetsSeconds
            for ordinal in 0...offsets.count {
                let present = lock.withLock { authenticationAttempts[ordinal] != nil }
                if !present {
                    try authentication(.init(ordinal: ordinal, scheduledOffsetSeconds: ordinal == 0 ? nil : offsets[ordinal - 1],
                        status: .cancelled, elapsedSeconds: nil, startedNanoseconds: nil, finishedNanoseconds: nil,
                        errorCode: "scheduled_authentication_not_completed"))
                }
            }
        } catch { fail("authentication_evidence_io") }
    }

    func evaluate(timebase: CollectorPerformanceTimebase) throws {
        try lock.withLock {
            let resources = try CollectorPerformanceAccounting.resources(samples, timebase: timebase,
                expectedWindowSeconds: 1800, maximumSampleGapSeconds: 2.5)
            let authenticationPassed = authenticationAttempts.count == 3
                && authenticationAttempts.values.allSatisfy { $0.status == .success }
            var passed = resources.withinThresholds(cpuPercent: 2, rssMiB: 150) && authenticationPassed
            var latencyJSON: [String: Any] = [:]
            for series in ["append", "sessions", "detail", "messages"] {
                let values = Array(attempts[series, default: [:]].values).map(\.accounting)
                let result = try CollectorPerformanceAccounting.latencies(values, expectedCount: series == "append" ? 60 : 360,
                    thresholdSeconds: series == "append" ? 120 : 2)
                passed = passed && result.passed
                latencyJSON[series] = ["attemptCount": result.attemptCount, "failedAttemptCount": result.failedAttemptCount,
                    "p95Seconds": result.p95Seconds.map { $0 as Any } ?? NSNull(), "passed": result.passed]
            }
            metrics = ["elapsedSeconds": resources.elapsedSeconds, "cpuPercentOfOneCore": resources.cpuPercentOfOneCore,
                "timeWeightedMeanRSSMiB": resources.timeWeightedMeanRSSMiB, "sampledMaximumRSSMiB": resources.sampledMaximumRSSMiB,
                "sampleCount": samples.count, "latencies": latencyJSON,
                "authentication": ["attemptCount": authenticationAttempts.count,
                    "successfulAttemptCount": authenticationAttempts.values.filter { $0.status == .success }.count,
                    "passed": authenticationPassed], "thresholdsPassed": passed]
            if !passed { failures.append("threshold") }
        }
    }

    func finish(fixtureRetained: Bool) throws {
        let value: [String: Any] = lock.withLock {
            ["schemaVersion": 1, "status": failures.isEmpty && !metrics.isEmpty ? "PASS" : "FAIL_OR_INCOMPLETE",
                "failures": failures, "metrics": metrics, "fixtureRetained": fixtureRetained,
                "observedSamples": samples.count, "recordedAttempts": attempts.mapValues(\.count),
                "recordedAuthenticationAttempts": authenticationAttempts.count,
                "networkScope": "synthetic-loopback-not-tailnet"]
        }
        try PerformanceFiles.write(PerformanceFiles.json(value), to: root.appendingPathComponent("summary.json"), synchronize: true)
    }
}

private struct PerformanceRole {
    let name: String
    let root: URL
    let home: URL
    let temporary: URL
    init(parent: URL, name: String) throws {
        self.name = name; root = parent.appendingPathComponent(name)
        home = root.appendingPathComponent("home"); temporary = home.appendingPathComponent("tmp")
        for directory in [root, home, temporary] { try PerformanceFiles.directory(directory) }
    }
}

private final class PerformanceChild: @unchecked Sendable {
    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var result: (Int32, Process.TerminationReason)?
        var value: (Int32, Process.TerminationReason)? { lock.withLock { result } }
        func record(_ process: Process) { lock.withLock { result = (process.terminationStatus, process.terminationReason) } }
    }
    let role: String
    private let process = Process()
    private let completion = Completion()
    private let stdout: FileHandle
    private let stderr: FileHandle
    private var closed = false
    var running: Bool { completion.value == nil && process.isRunning }
    var ownedPID: Int32 { process.processIdentifier }

    init(binary: URL, role: PerformanceRole, arguments: [String] = [], environment: [String: String] = [:]) throws {
        let allowed: Set<String> = ["ENGRAM_SETTINGS_PATH", "ENGRAM_RUNTIME_AI_SECRETS_PATH", "ENGRAM_REMOTE_OFFLOAD_ENABLED",
            "ENGRAM_LIVE_PUBLISH_ENABLED", "ENGRAM_LIVE_INGEST_ENABLED", "ENGRAM_DISABLED_SOURCES", "ENGRAM_USAGE_TOKEN_LIMITS",
            "ENGRAM_REMOTE_HOST", "ENGRAM_REMOTE_PORT", "ENGRAM_REMOTE_STORE", "ENGRAM_REMOTE_TOKEN", "ENGRAM_REMOTE_AT_REST_KEY",
            "ENGRAM_REMOTE_ARCHIVE_ENABLED", "ENGRAM_REMOTE_COLLECTOR_PUBLICATIONS_ENABLED", "ENGRAM_REMOTE_ARCHIVE_SERVER_ID",
            "ENGRAM_REMOTE_ARCHIVE_ROOT", "ENGRAM_REMOTE_ARCHIVE_TOKEN", "ENGRAM_REMOTE_ARCHIVE_AT_REST_KEY",
            "ENGRAM_REMOTE_MCP_ENABLED", "ENGRAM_REMOTE_WEB_ENABLED", "ENGRAM_REMOTE_WEB_ORIGIN",
            "ENGRAM_REMOTE_WEB_VIEWER_CREDENTIAL", "ENGRAM_REMOTE_WEB_SERVICE_SOCKET"]
        guard Set(environment.keys).isSubset(of: allowed), environment.values.allSatisfy({ !$0.utf8.contains(0) }) else {
            throw PerformanceRunError.configuration
        }
        self.role = role.name
        let out = role.root.appendingPathComponent("stdout.log"), err = role.root.appendingPathComponent("stderr.log")
        try PerformanceFiles.write(Data(), to: out); try PerformanceFiles.write(Data(), to: err)
        stdout = try FileHandle(forWritingTo: out)
        do { stderr = try FileHandle(forWritingTo: err) } catch { try? stdout.close(); throw error }
        process.executableURL = binary; process.arguments = arguments; process.currentDirectoryURL = role.root
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": role.home.path,
            "CFFIXED_USER_HOME": role.home.path, "TMPDIR": role.temporary.path, "LANG": "C", "LC_ALL": "C"]
            .merging(environment) { original, _ in original }
        process.standardInput = FileHandle.nullDevice; process.standardOutput = stdout; process.standardError = stderr
        let callback = completion
        process.terminationHandler = { callback.record($0) }
        do { try process.run() } catch { try? stdout.close(); try? stderr.close(); throw error }
    }

    func requireRunning() throws {
        try Task.checkCancellation()
        guard running, ownedPID > 0 else { throw PerformanceRunError.childExited }
    }

    private func join(seconds: Int) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(seconds))
        while completion.value == nil {
            try Task.checkCancellation()
            guard ContinuousClock.now < end else { throw PerformanceRunError.cleanup }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func requireSuccessfulExit(seconds: Int) async throws {
        try await join(seconds: seconds)
        guard let result = completion.value, result.0 == 0, result.1 == .exit else { throw PerformanceRunError.configuration }
    }

    func stopAndJoin() async throws {
        if process.isRunning {
            guard ownedPID > 0 else { throw PerformanceRunError.cleanup }
            _ = Darwin.kill(ownedPID, SIGTERM)
            do { try await join(seconds: 2) }
            catch {
                if process.isRunning { _ = Darwin.kill(ownedPID, SIGKILL) }
                try await join(seconds: 3)
            }
        } else { try await join(seconds: 1) }
        if !closed { try stdout.close(); try stderr.close(); closed = true }
    }
}

private struct PerformanceClock: Sendable {
    let origin = ContinuousClock.now
    func nanoseconds(at instant: ContinuousClock.Instant = .now) throws -> UInt64 {
        let parts = origin.duration(to: instant).components
        guard parts.seconds >= 0, parts.attoseconds >= 0 else { throw PerformanceRunError.sampling }
        let seconds = UInt64(parts.seconds).multipliedReportingOverflow(by: 1_000_000_000)
        let result = seconds.partialValue.addingReportingOverflow(UInt64(parts.attoseconds / 1_000_000_000))
        guard !seconds.overflow, !result.overflow else { throw PerformanceRunError.sampling }
        return result.partialValue
    }
}

private struct PerformanceNativeSampler {
    let child: PerformanceChild
    let timebase: CollectorPerformanceTimebase
    let clock: PerformanceClock
    private let startTicks: UInt64
    private let processID: Int32

    init(child: PerformanceChild, clock: PerformanceClock) throws {
        self.child = child; self.clock = clock
        var base = mach_timebase_info_data_t()
        guard mach_timebase_info(&base) == KERN_SUCCESS, base.numer > 0, base.denom > 0 else { throw PerformanceRunError.sampling }
        timebase = .init(numerator: base.numer, denominator: base.denom)
        let initial = try Self.raw(child)
        guard initial.ri_proc_start_abstime > 0, initial.ri_proc_exit_abstime == 0 else { throw PerformanceRunError.sampling }
        startTicks = initial.ri_proc_start_abstime; processID = child.ownedPID
    }

    private static func raw(_ child: PerformanceChild) throws -> rusage_info_v2 {
        try child.requireRunning()
        var usage = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(child.ownedPID, RUSAGE_INFO_V2, $0)
            }
        }
        guard result == 0 else { throw PerformanceRunError.sampling }
        try child.requireRunning()
        return usage
    }

    func sample() throws -> (CollectorPerformanceRawSample, ContinuousClock.Instant) {
        let raw = try Self.raw(child)
        let instant = ContinuousClock.now
        guard child.ownedPID == processID, raw.ri_proc_start_abstime == startTicks, raw.ri_proc_exit_abstime == 0 else {
            throw PerformanceRunError.sampling
        }
        return (.init(monotonicNanoseconds: try clock.nanoseconds(at: instant), processID: processID,
            processStartMachTicks: raw.ri_proc_start_abstime, processExitMachTicks: raw.ri_proc_exit_abstime,
            userMachTicks: raw.ri_user_time, systemMachTicks: raw.ri_system_time, residentBytes: raw.ri_resident_size), instant)
    }
}

private final class PerformanceTrust: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    let origin: URL
    let leaf: Data?
    private let trace: PerformanceTLSTrace?
    init(origin: URL, leaf: Data?, trace: PerformanceTLSTrace? = nil) {
        self.origin = origin; self.leaf = leaf; self.trace = trace
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        respond(to: challenge, callback: "session-didReceive", completionHandler: completionHandler)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        respond(to: challenge, callback: "task-didReceive", completionHandler: completionHandler)
    }
    private func respond(to challenge: URLAuthenticationChallenge, callback: String,
                         completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard origin.scheme == "https", challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == "127.0.0.1", challenge.protectionSpace.port == origin.port,
              let leaf, let trust = challenge.protectionSpace.serverTrust,
              let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let certificate = certificates.first,
              SecCertificateCopyData(certificate) as Data == leaf else {
            trace?.record(origin: origin, expectedLeaf: leaf, challenge: challenge, callback: callback, accepted: false)
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        trace?.record(origin: origin, expectedLeaf: leaf, challenge: challenge, callback: callback, accepted: true)
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private final class PerformanceHTTP: @unchecked Sendable {
    let origin: URL
    private let session: URLSession
    private let trust: PerformanceTrust
    init(origin: URL, leaf: Data? = nil, trace: PerformanceTLSTrace? = nil) throws {
        guard origin.host == "127.0.0.1", let port = origin.port, (1...65535).contains(port),
              origin.user == nil, origin.password == nil, origin.query == nil, origin.fragment == nil,
              (origin.scheme == "http" && leaf == nil) || (origin.scheme == "https" && leaf != nil) else {
            throw PerformanceRunError.configuration
        }
        self.origin = origin
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 5; configuration.timeoutIntervalForResource = 5
        configuration.httpMaximumConnectionsPerHost = 4
        let trust = PerformanceTrust(origin: origin, leaf: leaf, trace: trace)
        self.trust = trust
        session = URLSession(configuration: configuration, delegate: trust, delegateQueue: nil)
    }
    func close() { session.invalidateAndCancel() }

    static func segment(_ value: String) throws -> String {
        guard !value.isEmpty, let encoded = value.addingPercentEncoding(withAllowedCharacters:
            CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) else {
            throw PerformanceRunError.configuration
        }
        return encoded
    }

    func request(path: String, query: [URLQueryItem] = [], method: String = "GET", cookie: String? = nil,
                 bearer: String? = nil, body: Data? = nil, timeout: Double = 5, maximumBytes: Int = 1_048_576) async throws -> (Data, HTTPURLResponse) {
        guard path.hasPrefix("/"), !path.hasPrefix("//"), timeout > 0, timeout <= 5 else { throw PerformanceRunError.configuration }
        var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = path; components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw PerformanceRunError.configuration }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method; request.httpShouldHandleCookies = false
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if origin.scheme == "https" {
            request.setValue(origin.absoluteString, forHTTPHeaderField: "Origin")
            request.setValue("1", forHTTPHeaderField: "X-Engram-Web")
        }
        if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        if let body { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let outgoing = request
        // Bound the whole operation, including a slow response body. Foundation's
        // request timeout alone may reset while bytes continue to arrive.
        return try await withThrowingTaskGroup(of: (Data, HTTPURLResponse).self) { group in
            group.addTask { try await self.readResponse(outgoing, maximumBytes: maximumBytes) }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw PerformanceRunError.deadline
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw PerformanceRunError.deadline }
            return value
        }
    }

    private func readResponse(_ request: URLRequest, maximumBytes: Int) async throws -> (Data, HTTPURLResponse) {
        let (stream, response) = try await session.bytes(for: request, delegate: trust)
        guard let http = response as? HTTPURLResponse else { throw PerformanceRunError.wrongContent }
        var bytes = Data()
        for try await byte in stream {
            try Task.checkCancellation()
            guard bytes.count < maximumBytes else { throw PerformanceRunError.payloadLimit }
            bytes.append(byte)
        }
        return (bytes, http)
    }

    func json<T: Decodable>(_ type: T.Type, path: String, query: [URLQueryItem] = [], cookie: String? = nil,
                            bearer: String? = nil, timeout: Double = 5) async throws -> T {
        let (bytes, response) = try await request(path: path, query: query, cookie: cookie, bearer: bearer, timeout: timeout)
        guard response.statusCode == 200 else { throw PerformanceRunError.httpStatus(response.statusCode) }
        return try JSONDecoder().decode(type, from: bytes)
    }
}

private final class PerformancePort: @unchecked Sendable {
    let port: UInt16
    private var descriptor: Int32
    init() throws {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw PerformanceRunError.configuration }
        var complete = false
        defer { if !complete { _ = Darwin.close(descriptor) } }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else { throw PerformanceRunError.configuration }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &size) }
        }
        guard result == 0, named == 0, address.sin_port != 0 else { throw PerformanceRunError.configuration }
        port = UInt16(bigEndian: address.sin_port); self.descriptor = descriptor; complete = true
    }

    func prepareResetListener() throws {
        guard descriptor >= 0 else { throw PerformanceRunError.configuration }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
              Darwin.listen(descriptor, 1) == 0 else { throw PerformanceRunError.configuration }
    }

    // Only the reset task borrows the listening FD. Its owner closes that FD
    // after the task group joins; the accepted FD never escapes this method.
    func resetOneConnection(until deadline: ContinuousClock.Instant) async throws {
        while true {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw PerformanceRunError.deadline }
            let accepted = Darwin.accept(descriptor, nil, nil)
            if accepted >= 0 {
                var resetLinger = linger(l_onoff: 1, l_linger: 0)
                let configured = setsockopt(accepted, SOL_SOCKET, SO_LINGER, &resetLinger,
                    socklen_t(MemoryLayout<linger>.size))
                // Close even if SO_LINGER fails; never leave an accepted socket owned by nobody.
                let closed = Darwin.close(accepted)
                guard configured == 0, closed == 0 else { throw PerformanceRunError.cleanup }
                return
            }
            guard errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR else {
                throw PerformanceRunError.configuration
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func close() throws {
        guard descriptor >= 0 else { return }
        let fd = descriptor; descriptor = -1
        guard Darwin.close(fd) == 0 else { throw PerformanceRunError.cleanup }
    }
}

private typealias PerformancePublication = EngramCollectorCore.CollectorPublicationEnvelope
private typealias PerformanceAcceptance = EngramCollectorCore.CollectorPublicationAcceptanceRecord
private typealias PerformancePublicationPage = EngramCollectorCore.CollectorPublicationPage
private typealias PerformanceManifest = EngramCollectorCore.ArchiveSourceManifest

private struct PerformanceReplica: @unchecked Sendable {
    let id: String
    let http: PerformanceHTTP
    let token: String
}
private struct PerformanceExpectedMessage: Codable, Sendable {
    let role: String
    let content: String
    let timestamp: String
}
private struct PerformanceSource: Sendable {
    let ordinal: Int
    let relativePath: String
    let url: URL
    let marker: String
    let initialSHA256: String
    let initialBytes: Int
    let messages: [PerformanceExpectedMessage]
}
private struct PerformanceTarget: Sendable {
    let sessionID: String
    let generation: String
    let publicationSHA256: String
    let messages: [PerformanceExpectedMessage]
}
private struct PerformanceAppend: Sendable {
    let source: PerformanceSource
    let marker: String
    let sha256: String
    let bytes: Int
    let messages: [PerformanceExpectedMessage]
    let started: ContinuousClock.Instant
    let startedNanoseconds: UInt64
}

/// Setup mutates owned state on one task. During measurement, only the append
/// scheduler mutates source histories; other tasks read immutable targets and
/// write evidence through its lock. Cleanup begins after every group task joins.
private final class PerformanceScope: @unchecked Sendable {
    static let budgets: [String: Int] = [
        "maxEntriesVisited": 64, "maxCandidateFiles": 16, "maxDirectoryOpens": 4, "maxMetadataBytes": 65_536,
        "maxCaptureFiles": 4, "maxCaptureBytes": 32 * 1024 * 1024, "maxUploadClaimsPerReplica": 4,
        "maxRecoveryCandidates": 64, "maxResponseBytes": 4096, "minimumFreeDiskBytes": 16 * 1024 * 1024,
        "maxIncomingPaths": 64, "maxPathUTF8Bytes": 4096, "maxTotalPathUTF8Bytes": 32_768,
        "maxCheckpointUTF8Bytes": 512, "maxQueuedBatches": 16, "maxQueuedUTF8Bytes": 65_536,
        "pollIntervalMilliseconds": 1000,
    ]
    static let declaredProfile: [String: Any] = [
        "configuration": "Release", "architecture": "arm64", "fileCount": 256, "directoryCount": 16,
        "targetFileBytes": 65_536, "activeFileCount": 8, "targetAppendBytes": 1024,
        "bootstrapDeadlineSeconds": 600, "steadySeconds": 1800, "drainMaximumSeconds": 120,
        "appendOffsetsSeconds": Array(stride(from: 0, to: 1800, by: 30)), "appendCount": 60,
        "readIntervalSeconds": 5, "readCountPerEndpoint": 360, "readEndpoints": ["sessions", "detail", "messages"],
        "readConcurrencyPerEndpoint": 1, "appendConfirmationMaximumConcurrency": 4,
        "resourceSampleIntervalSeconds": 1, "maximumSampleGapSeconds": 2.5, "maximumScheduleLatenessSeconds": 0.5,
        "appendSearchTimeoutSeconds": 120, "httpRequestTimeoutSeconds": 5, "appendSearchPollSeconds": 0.5,
        "cpuLimitPercentOfOneCore": 2, "rssSampledMaximumLimitMiB": 150, "webP95LimitSeconds": 2,
        "collectorBudgets": budgets, "pollProfile": "explicit synthetic 1000ms, not a product default",
        "serviceCaptureSettings": ["pageLimit": 10, "maxPages": 2, "requestTimeout": 5, "retryCount": 0],
        "readTarget": "The immutable last corpus session; login and warm-up are outside steady state",
        "appendLatency": "Source write start to matching HQ HTTPS search response, validated against detail, messages and both exact-byte replicas",
        "rssMean": "Time-weighted trapezoidal sampled RSS; bootstrap and drain are excluded",
        "schedule": "Absolute steady-state offsets; late or uncompleted attempts remain failures, never rescheduled",
        "bootstrap": "TLS, corpus, real capture, dual ACK, HQ replay and all 256 normal sessions; no transcript rows are seeded",
    ]
    private let inputs: PerformanceInputs
    private let evidence: PerformanceEvidence
    private let fixture: RuntimeFixture
    private let clock = PerformanceClock()
    private let overallDeadline = ContinuousClock.now.advanced(by: .seconds(2640))
    private let bootstrapDeadline = ContinuousClock.now.advanced(by: .seconds(600))
    private let socketRoot: URL
    private let collectorRole: PerformanceRole
    private let serviceRole: PerformanceRole
    private var children: [PerformanceChild] = []
    private var persistent: [PerformanceChild] = []
    private var ports: [PerformancePort] = []
    private var replicas: [PerformanceReplica] = []
    private var tls: PerformanceChild?
    private var web: PerformanceHTTP?
    private let cookieLock = NSLock()
    private var storedCookie: String?
    private var cookie: String? { cookieLock.withLock { storedCookie } }
    private var viewer: String?
    private var sources: [PerformanceSource] = []
    private var histories: [Int: [PerformanceExpectedMessage]] = [:]
    private var finalHashes: [Int: String] = [:]
    private var targets: [Int: PerformanceTarget] = [:]
    private var replicaBaselineCursors: [String: String] = [:]
    private var authority: PerformancePublication?
    private var sampler: PerformanceNativeSampler?
    private var seedDatabase: DatabaseQueue?
    private var serviceStarted = false
    private let confirmationLock = NSLock()
    private var activeConfirmations = 0
    private var socket: String { socketRoot.appendingPathComponent("service.sock").path }
    private var database: URL { serviceRole.root.appendingPathComponent("index.sqlite") }

    init(inputs: PerformanceInputs, evidence: PerformanceEvidence) throws {
        self.inputs = inputs; self.evidence = evidence
        let ownedFixture = try RuntimeFixture()
        fixture = ownedFixture
        var initialized = false
        var createdSocketRoot: URL?
        defer {
            if !initialized {
                // No child can exist during initialization. Retain this bounded
                // partial fixture for inspection; never lose its location.
                print("COLLECTOR_PERFORMANCE_PARTIAL fixture=\(ownedFixture.base.path) socketRoot=\(createdSocketRoot?.path ?? "not-created")")
            }
        }
        var template = Array("/private/tmp/eg-perf-XXXXXX".utf8CString)
        guard let path = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress!) }) else {
            throw PerformanceRunError.configuration
        }
        socketRoot = URL(fileURLWithPath: String(cString: path), isDirectory: true)
        createdSocketRoot = socketRoot
        guard chmod(socketRoot.path, 0o700) == 0 else { throw PerformanceRunError.configuration }
        collectorRole = try PerformanceRole(parent: fixture.base, name: "collector")
        serviceRole = try PerformanceRole(parent: fixture.base, name: "hq-service")
        initialized = true
    }

    private func requireRunning(bootstrap: Bool = false, allowReportedFailure: Bool = false) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < overallDeadline, !bootstrap || ContinuousClock.now < bootstrapDeadline else {
            throw PerformanceRunError.deadline
        }
        for child in persistent { try child.requireRunning() }
        guard allowReportedFailure || !evidence.shouldAbort else { throw PerformanceRunError.threshold }
    }

    private func launch(_ binary: URL, role: PerformanceRole, arguments: [String] = [],
                        environment: [String: String] = [:], persistent: Bool = true) throws -> PerformanceChild {
        if binary.path != "/usr/bin/openssl" {
            let expected = inputs.binaries.first(where: { $0.executablePath == binary.path })?.sha256
                ?? (inputs.node.executablePath == binary.path ? inputs.node.sha256 : nil)
            guard let expected, PerformanceFiles.digest(try XCTUnwrap(PerformanceFiles.read(binary,
                maximum: 512 * 1024 * 1024, privateFile: false))) == expected else { throw PerformanceRunError.binaryChanged }
        }
        let child = try PerformanceChild(binary: binary, role: role, arguments: arguments, environment: environment)
        children.append(child)
        if persistent { self.persistent.append(child) }
        try evidence.lifecycle("owned_child_started", values: ["role": role.name, "pid": child.ownedPID])
        return child
    }

    private func privateJSON(_ value: Any, to url: URL) throws {
        try PerformanceFiles.write(PerformanceFiles.json(value), to: url)
    }

    private func openssl(_ arguments: [String], name: String) async throws {
        try requireRunning(bootstrap: true)
        let role = try PerformanceRole(parent: fixture.base, name: "openssl-\(name)")
        let child = try launch(URL(fileURLWithPath: "/usr/bin/openssl"), role: role, arguments: arguments, persistent: false)
        try await child.requireSuccessfulExit(seconds: 5)
        try await child.stopAndJoin()
    }

    private func startTLS(upstream: UInt16) async throws {
        let role = try PerformanceRole(parent: fixture.base, name: "private-tls")
        let key = role.home.appendingPathComponent("key.pem"), cert = role.home.appendingPathComponent("cert.pem")
        let der = role.home.appendingPathComponent("cert.der"), config = role.home.appendingPathComponent("openssl.cnf")
        try PerformanceFiles.write(Data("""
            [req]
            distinguished_name = dn
            prompt = no
            [dn]
            CN = 127.0.0.1
            [v3_req]
            subjectAltName = IP:127.0.0.1
            basicConstraints = critical,CA:FALSE
            keyUsage = critical,digitalSignature,keyEncipherment
            extendedKeyUsage = serverAuth

            """.utf8), to: config)
        try await openssl(["genrsa", "-out", key.path, "2048"], name: "key")
        guard chmod(key.path, 0o600) == 0 else { throw PerformanceRunError.configuration }
        try await openssl(["req", "-new", "-x509", "-key", key.path, "-out", cert.path, "-days", "1",
            "-subj", "/CN=127.0.0.1", "-config", config.path, "-extensions", "v3_req"], name: "cert")
        guard chmod(cert.path, 0o600) == 0 else { throw PerformanceRunError.configuration }
        try await openssl(["x509", "-in", cert.path, "-outform", "DER", "-out", der.path], name: "der")
        guard chmod(der.path, 0o600) == 0 else { throw PerformanceRunError.configuration }
        let leaf = try XCTUnwrap(PerformanceFiles.read(der, maximum: 65_536))
        _ = try PerformanceFiles.read(key, maximum: 65_536)
        _ = try PerformanceFiles.read(cert, maximum: 65_536)
        tls = try launch(URL(fileURLWithPath: inputs.node.executablePath), role: role,
            arguments: [inputs.helper.path, "--cert", cert.path, "--key", key.path,
                "--upstream", "http://127.0.0.1:\(upstream)", "--port", "0"])
        struct Ready: Decodable { let actualPort: Int }
        while true {
            try requireRunning(bootstrap: true)
            let bytes = try XCTUnwrap(PerformanceFiles.read(role.root.appendingPathComponent("stdout.log"), maximum: 4096))
            if bytes.last == 10 {
                guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                      Set(object.keys) == ["actualPort"] else { throw PerformanceRunError.configuration }
                let ready = try JSONDecoder().decode(Ready.self, from: bytes)
                guard (1...65535).contains(ready.actualPort), let origin = URL(string: "https://127.0.0.1:\(ready.actualPort)") else {
                    throw PerformanceRunError.configuration
                }
                web = try PerformanceHTTP(origin: origin, leaf: leaf)
                viewer = "synthetic-perf-viewer-\(UUID().uuidString)"
                try evidence.lifecycle("private_tls_ready", values: ["origin": origin.absoluteString,
                    "leafCertificateSHA256": PerformanceFiles.digest(leaf)])
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private func startReplicas() async throws {
        ports.append(try PerformancePort())
        ports.append(try PerformancePort())
        try await startTLS(upstream: ports[0].port)
        for (index, id) in ["hq", "m1"].enumerated() {
            let role = try PerformanceRole(parent: fixture.base, name: "remote-\(id)")
            let token = "synthetic-perf-\(id)-\(UUID().uuidString)"
            let port = ports[index].port
            var environment = ["ENGRAM_REMOTE_HOST": "127.0.0.1", "ENGRAM_REMOTE_PORT": String(port),
                "ENGRAM_REMOTE_STORE": role.root.appendingPathComponent("legacy").path,
                "ENGRAM_REMOTE_TOKEN": "synthetic-legacy-\(UUID().uuidString)",
                "ENGRAM_REMOTE_AT_REST_KEY": Data(repeating: UInt8(7 + index), count: 32).base64EncodedString(),
                "ENGRAM_REMOTE_ARCHIVE_ENABLED": "1", "ENGRAM_REMOTE_COLLECTOR_PUBLICATIONS_ENABLED": "1",
                "ENGRAM_REMOTE_ARCHIVE_SERVER_ID": id, "ENGRAM_REMOTE_ARCHIVE_ROOT": role.root.appendingPathComponent("archive").path,
                "ENGRAM_REMOTE_ARCHIVE_TOKEN": token,
                "ENGRAM_REMOTE_ARCHIVE_AT_REST_KEY": Data(repeating: UInt8(17 + index), count: 32).base64EncodedString(),
                "ENGRAM_REMOTE_MCP_ENABLED": "0", "ENGRAM_REMOTE_WEB_ENABLED": "0"]
            if id == "hq" {
                environment["ENGRAM_REMOTE_WEB_ENABLED"] = "1"
                environment["ENGRAM_REMOTE_WEB_ORIGIN"] = try XCTUnwrap(web).origin.absoluteString
                environment["ENGRAM_REMOTE_WEB_VIEWER_CREDENTIAL"] = try XCTUnwrap(viewer)
                environment["ENGRAM_REMOTE_WEB_SERVICE_SOCKET"] = socket
            }
            try ports[index].close()
            _ = try launch(inputs.binary("EngramRemoteServer"), role: role, environment: environment)
            replicas.append(.init(id: id, http: try PerformanceHTTP(origin: URL(string: "http://127.0.0.1:\(port)")!), token: token))
        }
        while true {
            try requireRunning(bootstrap: true)
            do {
                let hq = try await publicationPage(replicas[0], cursor: nil)
                let m1 = try await publicationPage(replicas[1], cursor: nil)
                guard hq.items.isEmpty, m1.items.isEmpty,
                      try EngramCollectorCore.CollectorPublicationCursor.decode(hq.afterCursor).journalID
                        != EngramCollectorCore.CollectorPublicationCursor.decode(m1.afterCursor).journalID else {
                    throw PerformanceRunError.wrongContent
                }
                return
            } catch {
                try evidence.lifecycle("bootstrap_replica_wait", values: ["code": PerformanceRunError.code(error)])
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func timestamp(_ offset: Int) -> String {
        let base = ISO8601DateFormatter().date(from: "2026-09-07T00:00:00Z")!
        return ISO8601DateFormatter().string(from: base.addingTimeInterval(TimeInterval(offset)))
    }

    private static func padding(_ bytes: Int) -> String {
        String(repeating: "payload ", count: bytes / 8) + String(repeating: "p", count: bytes % 8)
    }

    private static func record(_ message: PerformanceExpectedMessage) -> [String: Any] {
        ["type": "response_item", "timestamp": message.timestamp,
            "payload": ["type": "message", "role": message.role,
                "content": [["type": message.role == "user" ? "input_text" : "output_text", "text": message.content]]]]
    }

    private static func lines(_ records: [[String: Any]]) throws -> Data {
        try records.reduce(into: Data()) { result, record in
            result.append(try PerformanceFiles.json(record)); result.append(10)
        }
    }

    private func writeCorpus() throws {
        for directory in 0..<16 {
            try PerformanceFiles.directory(fixture.sources.appendingPathComponent(String(format: "group-%02d", directory)))
        }
        for index in 0..<256 {
            try requireRunning(bootstrap: true)
            let marker = String(format: "perfcorpusmarker%04d", index)
            let relative = String(format: "group-%02d/rollout-%04d.jsonl", index / 16, index)
            let user = PerformanceExpectedMessage(role: "user", content: "\(marker) Please preserve this synthetic baseline transcript.", timestamp: Self.timestamp(0))
            let prefix = "Baseline assistant response for \(marker). "
            let shortReply = PerformanceExpectedMessage(role: "assistant", content: prefix, timestamp: Self.timestamp(1))
            let metadata: [String: Any] = ["type": "session_meta", "timestamp": Self.timestamp(0),
                "payload": ["id": "perf-codex-\(index)", "cwd": fixture.project.path, "originator": "codex-cli", "timestamp": Self.timestamp(0)]]
            let shortBytes = try Self.lines([metadata, Self.record(user), Self.record(shortReply)])
            guard shortBytes.count < 65_536 else { throw PerformanceRunError.configuration }
            let reply = PerformanceExpectedMessage(role: "assistant", content: prefix + Self.padding(65_536 - shortBytes.count), timestamp: Self.timestamp(1))
            let bytes = try Self.lines([metadata, Self.record(user), Self.record(reply)])
            guard bytes.count == 65_536 else { throw PerformanceRunError.configuration }
            let url = fixture.sources.appendingPathComponent(relative)
            try PerformanceFiles.write(bytes, to: url)
            let hash = PerformanceFiles.digest(bytes)
            sources.append(.init(ordinal: index, relativePath: relative, url: url, marker: marker,
                initialSHA256: hash, initialBytes: bytes.count, messages: [user, reply]))
            histories[index] = [user, reply]; finalHashes[index] = hash
        }
        try privateJSON(sources.map { ["ordinal": $0.ordinal, "relativePath": $0.relativePath,
            "bytes": $0.initialBytes, "sha256": $0.initialSHA256, "nativeSessionID": "perf-codex-\($0.ordinal)"] },
            to: evidence.root.appendingPathComponent("corpus.json"))
    }

    private func startCollector() throws {
        var settings = fixture.document()
        var collector = try XCTUnwrap(settings["collector"] as? [String: Any])
        collector["budgets"] = Self.budgets
        collector["replicas"] = replicas.map { ["serverID": $0.id, "baseURL": $0.http.origin.absoluteString, "credentialID": "\($0.id)-reference"] }
        settings["collector"] = collector
        try fixture.writeSettings(settings)
        let credentials = collectorRole.home.appendingPathComponent("credentials.json")
        try privateJSON(Dictionary(uniqueKeysWithValues: replicas.map { ("\($0.id)-reference", $0.token) }), to: credentials)
        let child = try launch(inputs.binary("EngramCollector"), role: collectorRole,
            arguments: ["--settings", fixture.settings.path, "--credentials-file", credentials.path])
        let sampler = try PerformanceNativeSampler(child: child, clock: clock)
        self.sampler = sampler
        let sample = try sampler.sample().0
        try evidence.lifecycle("collector_bootstrap_start", values: ["rawUserMachTicks": sample.userMachTicks,
            "rawSystemMachTicks": sample.systemMachTicks, "residentBytes": sample.residentBytes,
            "monotonicNanoseconds": sample.monotonicNanoseconds, "processID": sample.processID,
            "processStartMachTicks": sample.processStartMachTicks,
            "timebaseNumerator": sampler.timebase.numerator, "timebaseDenominator": sampler.timebase.denominator])
    }

    private func requestTimeout(until end: ContinuousClock.Instant?) throws -> Double {
        try requireRunning()
        let remaining = Self.seconds(ContinuousClock.now.duration(to: min(end ?? overallDeadline, overallDeadline)))
        guard remaining > 0 else { throw PerformanceRunError.deadline }
        return min(5, remaining)
    }

    private func publicationPage(_ replica: PerformanceReplica, cursor: String?,
                                 until end: ContinuousClock.Instant? = nil) async throws -> PerformancePublicationPage {
        let query = [URLQueryItem(name: "limit", value: "100")] + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
        let page = try await replica.http.json(PerformancePublicationPage.self, path: "/v2/archive/publications", query: query,
            bearer: replica.token, timeout: requestTimeout(until: end))
        try page.validate(after: cursor.map(EngramCollectorCore.CollectorPublicationCursor.decode), expectedServerID: replica.id)
        return page
    }

    private func allPublications(_ replica: PerformanceReplica, after: String? = nil,
                                 until end: ContinuousClock.Instant? = nil) async throws -> ([PerformanceAcceptance], String) {
        var cursor = after
        var records: [PerformanceAcceptance] = []
        for _ in 0..<5 {
            try requireRunning()
            let page = try await publicationPage(replica, cursor: cursor, until: end)
            records.append(contentsOf: page.items)
            guard records.count <= 400 else { throw PerformanceRunError.wrongContent }
            for record in page.items { try record.ack.validate(against: record.publication, expectedServerID: replica.id) }
            if !page.hasMore { return (records, page.afterCursor) }
            guard cursor != page.afterCursor else { throw PerformanceRunError.wrongContent }
            cursor = page.afterCursor
        }
        throw PerformanceRunError.payloadLimit
    }

    private func fetch(_ replica: PerformanceReplica, path: String, until end: ContinuousClock.Instant?) async throws -> Data {
        let (bytes, response) = try await replica.http.request(path: path, bearer: replica.token, timeout: requestTimeout(until: end))
        guard response.statusCode == 200 else { throw PerformanceRunError.httpStatus(response.statusCode) }
        return bytes
    }

    private func verifyBytes(_ publication: PerformancePublication, replica: PerformanceReplica,
                             expectedHash: String? = nil, expectedCount: Int? = nil,
                             until end: ContinuousClock.Instant? = nil) async throws -> String {
        let bytes = try await fetch(replica, path: "/v2/archive/manifests/\(publication.manifestSHA256)", until: end)
        guard PerformanceFiles.digest(bytes) == publication.manifestSHA256 else { throw PerformanceRunError.wrongContent }
        let manifest = try EngramCollectorCore.ArchiveCanonicalJSON.decode(PerformanceManifest.self, from: bytes)
        var raw = Data()
        for chunk in manifest.chunks {
            let bytes = try await fetch(replica, path: "/v2/archive/objects/\(chunk.rawSHA256)", until: end)
            guard bytes.count == Int(chunk.rawByteCount), PerformanceFiles.digest(bytes) == chunk.rawSHA256,
                  raw.count + bytes.count <= 131_072 else { throw PerformanceRunError.wrongContent }
            raw.append(bytes)
        }
        let digest = PerformanceFiles.digest(raw)
        guard digest == manifest.wholeSourceSHA256, expectedHash == nil || digest == expectedHash,
              expectedCount == nil || raw.count == expectedCount else { throw PerformanceRunError.wrongContent }
        return digest
    }

    private func awaitFirstPublication() async throws -> PerformancePublication {
        while true {
            try requireRunning(bootstrap: true)
            if FileManager.default.fileExists(atPath: fixture.inventory.path),
               let publications = try? fixture.publications(), let first = publications.first { return first }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func startService(_ publication: PerformancePublication) throws {
        guard !serviceStarted, seedDatabase == nil else { throw PerformanceRunError.configuration }
        var configuration = Configuration()
        configuration.prepareDatabase { try $0.execute(sql: "PRAGMA journal_mode = WAL") }
        let queue = try DatabaseQueue(path: database.path, configuration: configuration)
        seedDatabase = queue
        try queue.write { db in
            try EngramCoreWrite.EngramMigrationRunner.migrate(db)
            _ = try EngramCoreWrite.CaptureIngestSourceRegistry.provision(db, machineID: publication.machineID,
                sourceInstanceID: publication.sourceInstanceID, source: .codex, parseFormat: .codex,
                configuredRoot: fixture.sources.path, initialEpoch: publication.collectorEpoch)
            for table in ["sessions", "capture_ingest_publications", "capture_ingest_ledger", "capture_ingest_identity_bindings",
                          "capture_ingest_generations", "session_index_jobs", "sessions_fts", "fts_map"] {
                guard try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") == 0 else { throw PerformanceRunError.wrongContent }
            }
        }
        try queue.writeWithoutTransaction { try $0.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
        try queue.close(); seedDatabase = nil
        guard chmod(database.path, 0o600) == 0 else { throw PerformanceRunError.configuration }
        let settings = serviceRole.home.appendingPathComponent("settings.json")
        let credentials = serviceRole.home.appendingPathComponent("capture-credentials.json")
        let ai = serviceRole.home.appendingPathComponent("empty-ai.json")
        let allSources = EngramCoreRead.SourceName.allCases.map(\.rawValue)
        try privateJSON(["runtimeRole": "index", "disabledSources": allSources.filter { $0 != "codex" },
            "archivedDefaultOffSourcesMigrated": true, "aiProtocol": "disabled", "titleProvider": "native",
            "remoteOffloadEnabled": false, "livePublishEnabled": false, "liveIngestEnabled": false,
            "captureIngest": ["enabled": true, "serverID": "hq", "baseURL": replicas[0].http.origin.absoluteString,
                "credentialID": "hq", "pageLimit": 10, "maxPages": 2, "requestTimeout": 5, "retryCount": 0]], to: settings)
        try privateJSON(["hq": replicas[0].token], to: credentials); try privateJSON([:], to: ai)
        _ = try launch(inputs.binary("EngramService"), role: serviceRole,
            arguments: ["--expected-home", serviceRole.home.path, "--capture-credentials-file", credentials.path,
                "--database-path", database.path, "--service-socket", socket],
            environment: ["ENGRAM_SETTINGS_PATH": settings.path, "ENGRAM_RUNTIME_AI_SECRETS_PATH": ai.path,
                "ENGRAM_REMOTE_OFFLOAD_ENABLED": "false", "ENGRAM_LIVE_PUBLISH_ENABLED": "false",
                "ENGRAM_LIVE_INGEST_ENABLED": "false", "ENGRAM_DISABLED_SOURCES": allSources.joined(separator: ","),
                "ENGRAM_USAGE_TOKEN_LIMITS": "{}"])
        serviceStarted = true; authority = publication
    }

    private func integer(_ sql: String) throws -> Int {
        var configuration = Configuration(); configuration.readonly = true
        let queue = try DatabaseQueue(path: database.path, configuration: configuration)
        do {
            let result = try queue.read { try XCTUnwrap(Int.fetchOne($0, sql: sql)) }
            try queue.close(); return result
        } catch { try? queue.close(); throw error }
    }

    private func finalSessionTiersMatch(_ schedule: CollectorPerformanceSchedule) throws -> Bool {
        var configuration = Configuration(); configuration.readonly = true
        let queue = try DatabaseQueue(path: database.path, configuration: configuration)
        do {
            let result = try queue.read { try PerformanceFinalSessionOracle.matches($0, schedule: schedule) }
            try queue.close(); return result
        } catch { try? queue.close(); throw error }
    }

    private func login(timeout: Double = 5) async throws {
        let web = try XCTUnwrap(web)
        let response = try await web.request(path: "/web/api/auth", method: "POST",
            body: PerformanceFiles.json(["credential": try XCTUnwrap(viewer)]), timeout: timeout)
        guard response.1.statusCode == 204 else { throw PerformanceRunError.httpStatus(response.1.statusCode) }
        let attributes = response.1.value(forHTTPHeaderField: "Set-Cookie")?.components(separatedBy: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        let lifetime = try PerformanceAuthenticationSchedule.syntheticLoopback().cookieLifetimeSeconds
        guard let value = attributes.first, !value.isEmpty,
              attributes.filter({ $0.lowercased().hasPrefix("max-age=") }) == ["Max-Age=\(lifetime)"] else {
            throw PerformanceRunError.wrongContent
        }
        cookieLock.withLock { storedCookie = value }
    }

    private func authenticationAttempt(ordinal: Int, offset: Int?, scheduled: ContinuousClock.Instant?,
                                       until end: ContinuousClock.Instant) async throws {
        var began: ContinuousClock.Instant?
        var beganNanoseconds: UInt64?
        var failureStatus: CollectorPerformanceAttemptStatus?
        var failureCode: String?
        do {
            if let scheduled {
                try await ContinuousClock().sleep(until: scheduled, tolerance: .milliseconds(10))
                if scheduled.duration(to: .now) > .milliseconds(500) {
                    failureStatus = .missedSchedule; failureCode = "schedule_lateness"
                    throw PerformanceRunError.deadline
                }
            }
            try requireRunning(bootstrap: ordinal == 0)
            let instant = ContinuousClock.now
            began = instant; beganNanoseconds = try clock.nanoseconds(at: instant)
            try await login(timeout: requestTimeout(until: end))
            let finished = try clock.nanoseconds()
            try evidence.authentication(.init(ordinal: ordinal, scheduledOffsetSeconds: offset, status: .success,
                elapsedSeconds: Double(finished - beganNanoseconds!) / 1_000_000_000,
                startedNanoseconds: beganNanoseconds, finishedNanoseconds: finished, errorCode: nil))
        } catch {
            do {
                try evidence.authentication(.init(ordinal: ordinal, scheduledOffsetSeconds: offset,
                    status: failureStatus ?? PerformanceRunError.attemptStatus(error),
                    elapsedSeconds: began.map { Self.seconds($0.duration(to: .now)) },
                    startedNanoseconds: beganNanoseconds, finishedNanoseconds: try? clock.nanoseconds(),
                    errorCode: failureCode ?? PerformanceRunError.code(error)))
            } catch { evidence.fail("authentication_evidence_io") }
            throw error
        }
    }

    private func refreshAuthentication(_ schedule: PerformanceAuthenticationSchedule, start: ContinuousClock.Instant) async {
        for (index, offset) in schedule.refreshOffsetsSeconds.enumerated() {
            do {
                try await authenticationAttempt(ordinal: index + 1, offset: offset,
                    scheduled: start.advanced(by: .seconds(offset)), until: start.advanced(by: .seconds(1800)))
            } catch { return } // A failed auth attempt is terminal; never retry or repair a 401.
        }
    }

    private func sessions(query: String? = nil, cursor: String? = nil, snapshot: String? = nil,
                          timeout: Double = 5) async throws -> EngramServiceWebSessionsResponse {
        let authority = try XCTUnwrap(authority)
        var fields = [URLQueryItem(name: "source", value: "codex"), URLQueryItem(name: "machineId", value: authority.machineID),
            URLQueryItem(name: "sourceInstanceId", value: authority.sourceInstanceID), URLQueryItem(name: "limit", value: "100")]
        if let query { fields.append(.init(name: "query", value: query)) }
        if let cursor { fields.append(.init(name: "cursor", value: cursor)) }
        if let snapshot { fields.append(.init(name: "snapshotId", value: snapshot)) }
        return try await XCTUnwrap(web).json(EngramServiceWebSessionsResponse.self, path: "/web/api/sessions",
            query: fields, cookie: cookie, timeout: timeout)
    }

    private func detail(_ sessionID: String, timeout: Double = 5) async throws -> EngramServiceWebSessionDetail {
        let response = try await XCTUnwrap(web).json(EngramServiceWebSessionDetailResponse.self,
            path: "/web/api/sessions/\(PerformanceHTTP.segment(sessionID))", cookie: cookie, timeout: timeout)
        return try XCTUnwrap(response.detail)
    }

    private func messages(_ sessionID: String, generation: String, timeout: Double = 5) async throws -> EngramServiceWebMessagesResponse {
        try await XCTUnwrap(web).json(EngramServiceWebMessagesResponse.self, path: "/web/api/sessions/\(PerformanceHTTP.segment(sessionID))/messages",
            query: [.init(name: "generation", value: generation)], cookie: cookie, timeout: timeout)
    }

    private func validate(_ detail: EngramServiceWebSessionDetail, sessionID: String,
                          expectedCount: Int, generation: String? = nil) throws -> String {
        let authority = try XCTUnwrap(authority)
        guard detail.session.sessionId == sessionID, detail.session.source == "codex",
              detail.session.captureIdentity?.machineId == authority.machineID,
              detail.session.captureIdentity?.sourceInstanceId == authority.sourceInstanceID,
              detail.transcriptAvailability == .available, let current = detail.transcriptGeneration,
              detail.lastReady?.generationId == current, detail.lastReady?.normalizedMessageCount == expectedCount,
              generation == nil || current == generation else { throw PerformanceRunError.wrongContent }
        return current
    }

    private func validate(_ page: EngramServiceWebMessagesResponse, sessionID: String, generation: String,
                          expected: [PerformanceExpectedMessage]) throws {
        guard page.sessionId == sessionID, page.generation == generation, page.isComplete,
              page.projection == EngramServiceWebReadLimits.projection,
              page.redactionRevision == EngramServiceWebReadLimits.redactionRevision else { throw PerformanceRunError.wrongContent }
        var ordinal = 0, payload = Data(), digest: String?, role: EngramServiceWebMessageRole?
        for fragment in page.fragments {
            guard fragment.messageOrdinal == ordinal, fragment.utf8Offset == payload.count else { throw PerformanceRunError.wrongContent }
            if payload.isEmpty { digest = fragment.payloadSHA256; role = fragment.role }
            guard fragment.payloadSHA256 == digest, fragment.role == role else { throw PerformanceRunError.wrongContent }
            payload.append(Data(fragment.payloadFragment.utf8))
            guard payload.count <= 131_072 else { throw PerformanceRunError.payloadLimit }
            if fragment.isLastFragment {
                guard ordinal < expected.count, PerformanceFiles.digest(payload) == digest else { throw PerformanceRunError.wrongContent }
                let message = try JSONDecoder().decode(EngramServiceWebNormalizedMessage.self, from: payload)
                let wanted = expected[ordinal]
                guard message.role.rawValue == wanted.role, message.content == wanted.content,
                      message.usage == nil, message.toolCalls == nil,
                      message.timestamp.flatMap(Self.parsedTimestamp) == Self.parsedTimestamp(wanted.timestamp) else {
                    throw PerformanceRunError.wrongContent
                }
                ordinal += 1; payload = Data(); digest = nil; role = nil
            }
        }
        guard ordinal == expected.count, payload.isEmpty else { throw PerformanceRunError.wrongContent }
    }

    private static func parsedTimestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    private func awaitBootstrap() async throws {
        while true {
            try requireRunning(bootstrap: true)
            if try fixture.integer("SELECT count(*) FROM collector_publication_replicas WHERE state = 'acknowledged'") == 512,
               try integer("SELECT count(*) FROM sessions WHERE source = 'codex' AND tier = 'normal'") == 256,
               try integer("SELECT count(*) FROM capture_ingest_ledger WHERE status = 'index_ready'") == 256 { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        let local = try fixture.publications()
        guard local.count == 256, let authority,
              local.allSatisfy({ $0.machineID == authority.machineID && $0.sourceInstanceID == authority.sourceInstanceID
                  && $0.collectorEpoch == authority.collectorEpoch }) else { throw PerformanceRunError.wrongContent }
        let hashes = Set(sources.map(\.initialSHA256))
        for replica in replicas {
            let (records, cursor) = try await allPublications(replica, until: bootstrapDeadline)
            guard records.count == 256, Set(try records.map { try $0.publication.sha256() }) == Set(try local.map { try $0.sha256() }) else {
                throw PerformanceRunError.wrongContent
            }
            var observed = Set<String>()
            for record in records {
                try requireRunning(bootstrap: true)
                let digest = try await verifyBytes(record.publication, replica: replica, expectedCount: 65_536, until: bootstrapDeadline)
                guard hashes.contains(digest), observed.insert(digest).inserted else { throw PerformanceRunError.wrongContent }
            }
            guard observed == hashes else { throw PerformanceRunError.wrongContent }
            replicaBaselineCursors[replica.id] = cursor
        }
        try requireRunning(bootstrap: true)
        try await login()
        var cursor: String?, snapshot: String?, ids = Set<String>()
        for _ in 0..<4 {
            try requireRunning(bootstrap: true)
            let page = try await sessions(cursor: cursor, snapshot: snapshot, timeout: requestTimeout(until: bootstrapDeadline))
            if let snapshot { guard snapshot == page.snapshotId else { throw PerformanceRunError.wrongContent } }
            else { snapshot = page.snapshotId }
            for item in page.items {
                guard item.source == "codex", item.captureIdentity?.machineId == authority.machineID,
                      item.captureIdentity?.sourceInstanceId == authority.sourceInstanceID,
                      ids.insert(item.sessionId).inserted else { throw PerformanceRunError.wrongContent }
            }
            cursor = page.nextCursor
            if cursor == nil { break }
        }
        guard cursor == nil, ids.count == 256, try integer("SELECT count(*) FROM sessions") == 256 else {
            throw PerformanceRunError.wrongContent
        }
        var mapped = Set<String>()
        for source in sources {
            try requireRunning(bootstrap: true)
            let page = try await sessions(query: source.marker, timeout: requestTimeout(until: bootstrapDeadline))
            guard page.items.count == 1, page.nextCursor == nil, let item = page.items.first,
                  ids.contains(item.sessionId), mapped.insert(item.sessionId).inserted else { throw PerformanceRunError.wrongContent }
            let detail = try await detail(item.sessionId, timeout: requestTimeout(until: bootstrapDeadline))
            let generation = try validate(detail, sessionID: item.sessionId, expectedCount: 2)
            try validate(await messages(item.sessionId, generation: generation, timeout: requestTimeout(until: bootstrapDeadline)), sessionID: item.sessionId,
                generation: generation, expected: source.messages)
            targets[source.ordinal] = .init(sessionID: item.sessionId, generation: generation,
                publicationSHA256: try XCTUnwrap(detail.lastReady?.publicationSHA256), messages: source.messages)
        }
        try requireRunning(bootstrap: true)
        guard mapped == ids else { throw PerformanceRunError.wrongContent }
        try evidence.lifecycle("bootstrap_verified", values: ["normalSessions": ids.count, "dualReplicaPublications": 256,
            "monotonicNanoseconds": try clock.nanoseconds(), "collectorBudgets": Self.budgets])
    }

    func run() async throws {
        try evidence.lifecycle("bootstrap_begin", values: ["deadlineSeconds": 600])
        try await startReplicas(); try writeCorpus(); try startCollector()
        try startService(await awaitFirstPublication())
        try await awaitBootstrap()
        let sampler = try XCTUnwrap(sampler)
        let authentication = try PerformanceAuthenticationSchedule.syntheticLoopback()
        try await authenticationAttempt(ordinal: 0, offset: nil, scheduled: nil, until: bootstrapDeadline)
        try requireRunning(bootstrap: true)
        let (first, start) = try sampler.sample()
        try evidence.sample(first)
        try evidence.lifecycle("steady_begin", values: ["monotonicNanoseconds": first.monotonicNanoseconds,
            "rawUserMachTicks": first.userMachTicks, "rawSystemMachTicks": first.systemMachTicks,
            "residentBytes": first.residentBytes, "timebaseNumerator": sampler.timebase.numerator,
            "timebaseDenominator": sampler.timebase.denominator])
        let stable = try XCTUnwrap(targets[255])
        let schedule = try CollectorPerformanceAccounting.schedule(.syntheticLoopback)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.collectSamples(sampler, start: start) }
            group.addTask { await self.scheduleAppends(schedule.appends, start: start) }
            group.addTask { await self.refreshAuthentication(authentication, start: start) }
            for endpoint in CollectorPerformanceEndpoint.allCases {
                group.addTask { await self.scheduleReads(endpoint, target: stable, start: start) }
            }
            // A fatal completed task must cancel a sleeping refresh immediately;
            // structured scope exit still joins every task before owned cleanup.
            for await _ in group {
                if evidence.shouldAbort { group.cancelAll() }
            }
        }
        evidence.fillMissing(series: "append", count: 60, interval: 30, status: .cancelled)
        for endpoint in CollectorPerformanceEndpoint.allCases {
            evidence.fillMissing(series: endpoint.rawValue, count: 360, interval: 5, status: .cancelled)
        }
        evidence.fillMissingAuthentication()
        try evidence.evaluate(timebase: sampler.timebase)
        try requireRunning(allowReportedFailure: true)
        for source in sources {
            let bytes = try XCTUnwrap(PerformanceFiles.read(source.url, maximum: 131_072))
            guard PerformanceFiles.digest(bytes) == finalHashes[source.ordinal] else { throw PerformanceRunError.sourceChanged }
        }
        guard try fixture.publications().count == 316,
              try fixture.integer("SELECT count(*) FROM collector_publication_replicas WHERE state = 'acknowledged'") == 632,
              try finalSessionTiersMatch(schedule) else {
            throw PerformanceRunError.wrongContent
        }
        try privateJSON(sources.map { ["ordinal": $0.ordinal, "relativePath": $0.relativePath,
            "initialSHA256": $0.initialSHA256, "finalSHA256": finalHashes[$0.ordinal]!] },
            to: evidence.root.appendingPathComponent("corpus-final.json"))
        if evidence.shouldAbort { throw PerformanceRunError.threshold }
    }

    private func collectSamples(_ sampler: PerformanceNativeSampler, start: ContinuousClock.Instant) async {
        do {
            for second in 1...1800 {
                try await ContinuousClock().sleep(until: start.advanced(by: .seconds(second)), tolerance: .milliseconds(10))
                try requireRunning()
                try evidence.sample(sampler.sample().0)
            }
            try evidence.lifecycle("steady_resource_window_end", values: ["monotonicNanoseconds": try clock.nanoseconds()])
        } catch { evidence.fail(PerformanceRunError.code(error)) }
    }

    private func scheduleReads(_ endpoint: CollectorPerformanceEndpoint, target: PerformanceTarget,
                               start: ContinuousClock.Instant) async {
        for ordinal in 0..<360 {
            let scheduled = start.advanced(by: .seconds(ordinal * 5))
            var began: UInt64?
            var instant: ContinuousClock.Instant?
            do {
                try await ContinuousClock().sleep(until: scheduled, tolerance: .milliseconds(10))
                try requireRunning()
                let now = ContinuousClock.now
                guard scheduled.duration(to: now) <= .milliseconds(500) else {
                    try evidence.attempt(.init(series: endpoint.rawValue, ordinal: ordinal, scheduledOffsetSeconds: ordinal * 5,
                        status: .missedSchedule, elapsedSeconds: nil, startedNanoseconds: nil, finishedNanoseconds: try clock.nanoseconds(),
                        errorCode: "schedule_lateness", marker: nil, sessionID: target.sessionID, generation: target.generation))
                    continue
                }
                instant = now; began = try clock.nanoseconds(at: now)
                switch endpoint {
                case .sessions:
                    let response = try await sessions(query: sources[255].marker)
                    guard response.items.count == 1, response.nextCursor == nil,
                          response.items.first?.sessionId == target.sessionID,
                          response.items.first?.metadataGeneration != nil else { throw PerformanceRunError.wrongContent }
                case .detail:
                    let value = try await detail(target.sessionID)
                    _ = try validate(value, sessionID: target.sessionID, expectedCount: target.messages.count, generation: target.generation)
                    guard value.lastReady?.publicationSHA256 == target.publicationSHA256 else { throw PerformanceRunError.wrongContent }
                case .messages:
                    let response = try await messages(target.sessionID, generation: target.generation)
                    try validate(response, sessionID: target.sessionID, generation: target.generation, expected: target.messages)
                }
                let finished = try clock.nanoseconds()
                try evidence.attempt(.init(series: endpoint.rawValue, ordinal: ordinal, scheduledOffsetSeconds: ordinal * 5,
                    status: .success, elapsedSeconds: Double(finished - began!) / 1_000_000_000,
                    startedNanoseconds: began, finishedNanoseconds: finished, errorCode: nil, marker: nil,
                    sessionID: target.sessionID, generation: target.generation))
            } catch {
                let finished = try? clock.nanoseconds()
                do {
                    try evidence.attempt(.init(series: endpoint.rawValue, ordinal: ordinal, scheduledOffsetSeconds: ordinal * 5,
                        status: PerformanceRunError.attemptStatus(error),
                        elapsedSeconds: instant.map { Self.seconds($0.duration(to: .now)) }, startedNanoseconds: began,
                        finishedNanoseconds: finished, errorCode: PerformanceRunError.code(error), marker: nil,
                        sessionID: target.sessionID, generation: target.generation))
                } catch { evidence.fail("evidence_io") }
                if Task.isCancelled || evidence.shouldAbort { break }
            }
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
    }

    private func append(ordinal: Int, fileOrdinal: Int) throws -> PerformanceAppend {
        let source = sources[fileOrdinal]
        let marker = String(format: "perfappendmarker%04d", ordinal)
        let prefix = "\(marker) Synthetic append response. "
        let timestamp = Self.timestamp(ordinal + 2)
        let short = PerformanceExpectedMessage(role: "assistant", content: prefix, timestamp: timestamp)
        let shortBytes = try Self.lines([Self.record(short)])
        guard shortBytes.count < 1024 else { throw PerformanceRunError.configuration }
        let message = PerformanceExpectedMessage(role: "assistant", content: prefix + Self.padding(1024 - shortBytes.count), timestamp: timestamp)
        let appended = try Self.lines([Self.record(message)])
        guard appended.count == 1024 else { throw PerformanceRunError.configuration }
        let before = try XCTUnwrap(PerformanceFiles.read(source.url, maximum: 131_072))
        guard PerformanceFiles.digest(before) == finalHashes[fileOrdinal] else { throw PerformanceRunError.sourceChanged }
        let began = ContinuousClock.now
        let beganNanoseconds = try clock.nanoseconds(at: began)
        try PerformanceFiles.write(appended, to: source.url, append: true, synchronize: true)
        let expected = before + appended
        guard try PerformanceFiles.read(source.url, maximum: 131_072) == expected else { throw PerformanceRunError.sourceChanged }
        let hash = PerformanceFiles.digest(expected)
        finalHashes[fileOrdinal] = hash
        histories[fileOrdinal, default: []].append(message)
        return .init(source: source, marker: marker, sha256: hash, bytes: expected.count,
            messages: histories[fileOrdinal]!, started: began, startedNanoseconds: beganNanoseconds)
    }

    private func scheduleAppends(_ appends: [CollectorPerformanceSchedule.Append], start: ContinuousClock.Instant) async {
        await withTaskGroup(of: Void.self) { group in
            for (ordinal, entry) in appends.enumerated() {
                do {
                    let scheduled = start.advanced(by: .seconds(entry.offsetSeconds))
                    try await ContinuousClock().sleep(until: scheduled, tolerance: .milliseconds(10))
                    try requireRunning()
                    guard scheduled.duration(to: .now) <= .milliseconds(500) else {
                        try evidence.attempt(.init(series: "append", ordinal: ordinal, scheduledOffsetSeconds: entry.offsetSeconds,
                            status: .missedSchedule, elapsedSeconds: nil, startedNanoseconds: nil,
                            finishedNanoseconds: try clock.nanoseconds(), errorCode: "schedule_lateness",
                            marker: nil, sessionID: nil, generation: nil))
                        continue
                    }
                    let admitted = confirmationLock.withLock {
                        guard activeConfirmations < 4 else { return false }
                        activeConfirmations += 1; return true
                    }
                    guard admitted else {
                        try evidence.attempt(.init(series: "append", ordinal: ordinal, scheduledOffsetSeconds: entry.offsetSeconds,
                            status: .missedSchedule, elapsedSeconds: nil, startedNanoseconds: nil,
                            finishedNanoseconds: try clock.nanoseconds(), errorCode: "confirmation_concurrency_limit",
                            marker: nil, sessionID: nil, generation: nil))
                        continue
                    }
                    let appended: PerformanceAppend
                    do { appended = try append(ordinal: ordinal, fileOrdinal: entry.fileOrdinal) }
                    catch { confirmationLock.withLock { activeConfirmations -= 1 }; throw error }
                    group.addTask { await self.confirmAppend(appended, ordinal: ordinal, steadyStart: start) }
                } catch {
                    do {
                        try evidence.attempt(.init(series: "append", ordinal: ordinal, scheduledOffsetSeconds: entry.offsetSeconds,
                            status: PerformanceRunError.attemptStatus(error), elapsedSeconds: nil, startedNanoseconds: nil,
                            finishedNanoseconds: try? clock.nanoseconds(), errorCode: PerformanceRunError.code(error),
                            marker: nil, sessionID: nil, generation: nil))
                    } catch { evidence.fail("evidence_io") }
                    if Task.isCancelled || evidence.shouldAbort { break }
                }
            }
            await group.waitForAll()
        }
    }

    private func confirmAppend(_ appended: PerformanceAppend, ordinal: Int, steadyStart: ContinuousClock.Instant) async {
        defer { confirmationLock.withLock { activeConfirmations -= 1 } }
        let end = min(appended.started.advanced(by: .seconds(120)), steadyStart.advanced(by: .seconds(1920)))
        var observed: UInt64?
        var generation: String?
        var foundSession: String?
        var firstPollFailure: (CollectorPerformanceAttemptStatus, String)?
        do {
            let target = try XCTUnwrap(targets[appended.source.ordinal])
            while true {
                try requireRunning()
                let remaining = Self.seconds(ContinuousClock.now.duration(to: end))
                guard remaining > 0 else { throw PerformanceRunError.deadline }
                do {
                    let page = try await sessions(query: appended.marker, timeout: min(5, remaining))
                    let searchObserved = try clock.nanoseconds()
                    if page.items.isEmpty {
                        try await Task.sleep(for: .milliseconds(500)); continue
                    }
                    guard page.items.count == 1, page.nextCursor == nil, page.items.first?.sessionId == target.sessionID else {
                        throw PerformanceRunError.wrongContent
                    }
                    let value = try await detail(target.sessionID, timeout: requestTimeout(until: end))
                    let current = try validate(value, sessionID: target.sessionID, expectedCount: appended.messages.count)
                    guard current != target.generation, let digest = value.lastReady?.publicationSHA256 else { throw PerformanceRunError.wrongContent }
                    try validate(await messages(target.sessionID, generation: current,
                        timeout: requestTimeout(until: end)),
                        sessionID: target.sessionID, generation: current, expected: appended.messages)
                    guard ContinuousClock.now <= end else { throw PerformanceRunError.deadline }
                    observed = searchObserved; generation = current; foundSession = target.sessionID
                    for replica in replicas {
                        let records = try await allPublications(replica, after: replicaBaselineCursors[replica.id], until: end).0
                        guard let record = try records.first(where: { try $0.publication.sha256() == digest }) else {
                            throw PerformanceRunError.wrongContent
                        }
                        _ = try await verifyBytes(record.publication, replica: replica, expectedHash: appended.sha256,
                            expectedCount: appended.bytes, until: end)
                    }
                    guard ContinuousClock.now <= end else { throw PerformanceRunError.deadline }
                    var record = PerformanceAttemptRecord(series: "append", ordinal: ordinal, scheduledOffsetSeconds: ordinal * 30,
                        status: firstPollFailure?.0 ?? .success,
                        elapsedSeconds: Double(searchObserved - appended.startedNanoseconds) / 1_000_000_000,
                        startedNanoseconds: appended.startedNanoseconds, finishedNanoseconds: try clock.nanoseconds(), errorCode: firstPollFailure?.1,
                        marker: appended.marker, sessionID: target.sessionID, generation: current)
                    record.observationNanoseconds = searchObserved
                    try evidence.attempt(record)
                    return
                } catch {
                    if firstPollFailure == nil { firstPollFailure = (PerformanceRunError.attemptStatus(error), PerformanceRunError.code(error)) }
                    try evidence.lifecycle("append_poll_error", values: ["ordinal": ordinal, "code": PerformanceRunError.code(error),
                        "elapsedSeconds": Self.seconds(appended.started.duration(to: .now))])
                    if error is CancellationError { throw error }
                    if let failure = error as? PerformanceRunError {
                        switch failure {
                        case .wrongContent, .sourceChanged, .evidenceIO, .httpStatus(401): throw error
                        default: break
                        }
                    }
                    try await Task.sleep(for: .milliseconds(500))
                }
            }
        } catch {
            do {
                var record = PerformanceAttemptRecord(series: "append", ordinal: ordinal, scheduledOffsetSeconds: ordinal * 30,
                    status: PerformanceRunError.attemptStatus(error), elapsedSeconds: Self.seconds(appended.started.duration(to: .now)),
                    startedNanoseconds: appended.startedNanoseconds, finishedNanoseconds: try clock.nanoseconds(),
                    errorCode: PerformanceRunError.code(error), marker: appended.marker, sessionID: foundSession, generation: generation)
                record.observationNanoseconds = observed
                try evidence.attempt(record)
            } catch { evidence.fail("evidence_io") }
        }
    }

    func close(retainFixture: Bool) async throws {
        web?.close()
        for replica in replicas { replica.http.close() }
        var failed = false
        if let tls { do { try await tls.stopAndJoin() } catch { failed = true } }
        for child in children.reversed() {
            do { try await child.stopAndJoin() } catch { failed = true }
        }
        for port in ports { do { try port.close() } catch { failed = true } }
        if let queue = seedDatabase {
            do { try queue.close(); seedDatabase = nil } catch { failed = true }
        }
        guard !failed else { throw PerformanceRunError.cleanup }
        try evidence.lifecycle("owned_children_joined", values: ["count": children.count])
        if retainFixture {
            print("COLLECTOR_PERFORMANCE_RETAINED fixture=\(fixture.base.path) socketRoot=\(socketRoot.path)")
            return
        }
        try FileManager.default.removeItem(at: socketRoot)
        fixture.remove()
        guard !FileManager.default.fileExists(atPath: fixture.base.path) else { throw PerformanceRunError.cleanup }
    }
}

/// A short diagnostic of the same native bytes API used by the long runner.
/// No product process, transcript corpus, authentication or resource sample is started.
final class CollectorBinaryPerformanceTLSContractTests: XCTestCase {
    func testNativeAsyncBytesAdmitsOnlyItsPinnedPrivateLeaf() async throws {
        guard ProcessInfo.processInfo.environment["ENGRAM_COLLECTOR_TLS_PROBE"] == "1" else {
            throw XCTSkip("TLS probe requires explicit opt-in; no files or processes were created")
        }
        // Receipt/hash checks are read-only and precede the owned lifecycle budget.
        let inputs = try PerformanceInputs.preflight(ProcessInfo.processInfo.environment)
        let started = ContinuousClock.now
        let deadline = started.advanced(by: .seconds(30))
        let workDeadline = started.advanced(by: .seconds(22))
        executionTimeAllowance = 45 // A harness ceiling, not the asserted 30-second lifecycle contract.
        let evidence = try PerformanceEvidence(tlsProbeInputs: inputs)
        let state = PerformanceTLSProbeState()
        var scope: PerformanceScope?
        var failure: Error?
        do {
            let owned = try PerformanceScope(inputs: inputs, evidence: evidence)
            scope = owned
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await owned.runTLSProbe(state: state, until: workDeadline) }
                group.addTask {
                    try await ContinuousClock().sleep(until: workDeadline)
                    throw PerformanceRunError.deadline
                }
                defer { group.cancelAll() }
                guard try await group.next() != nil else { throw PerformanceRunError.deadline }
            } // Both the worker and deadline task join before any child cleanup.
            if let observedFailure = state.firstUnexpectedError { throw observedFailure }
            guard state.completeAndPassed else { throw PerformanceRunError.wrongContent }
        } catch {
            // Keep the original positive transport error even if a later case times out.
            failure = state.firstUnexpectedError ?? error
        }
        let retaining = failure != nil
        let ownedScope = scope
        let cleanup = Task.detached { try await ownedScope?.closeTLSProbe(retainFixture: retaining) }
        var cleanupPassed = false
        do { try await cleanup.value; cleanupPassed = true }
        catch { if failure == nil { failure = error } }
        let deadlinePassed = ContinuousClock.now <= deadline
        if !deadlinePassed, failure == nil { failure = PerformanceRunError.deadline }
        do {
            try state.finish(root: evidence.root, failure: failure, cleanupPassed: cleanupPassed,
                deadlinePassed: deadlinePassed, fixtureRetained: retaining || !cleanupPassed,
                elapsed: started.duration(to: .now))
        } catch { if failure == nil { failure = error } }
        if let failure { throw failure }
    }
}

/// Observation only: no challenge routing, anchor mutation or disposition override.
private final class PerformanceTLSTrace: @unchecked Sendable {
    struct Event: Codable {
        let callback: String
        let httpsOrigin: Bool
        let serverTrustMethod: Bool
        let exactLoopbackHost: Bool
        let exactPort: Bool
        let expectedLeafPresent: Bool
        let peerLeafPresent: Bool
        let leafMatches: Bool
        let accepted: Bool
    }
    private let lock = NSLock()
    private var events: [Event] = []
    var snapshot: [Event] { lock.withLock { events } }

    func record(origin: URL, expectedLeaf: Data?, challenge: URLAuthenticationChallenge, callback: String, accepted: Bool) {
        let space = challenge.protectionSpace
        let certificates = space.serverTrust.flatMap { SecTrustCopyCertificateChain($0) as? [SecCertificate] }
        let peerLeaf = certificates?.first.map { SecCertificateCopyData($0) as Data }
        let event = Event(callback: callback, httpsOrigin: origin.scheme == "https",
            serverTrustMethod: space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            exactLoopbackHost: space.host == "127.0.0.1", exactPort: space.port == origin.port,
            expectedLeafPresent: expectedLeaf != nil, peerLeafPresent: peerLeaf != nil,
            leafMatches: expectedLeaf != nil && peerLeaf != nil && expectedLeaf == peerLeaf, accepted: accepted)
        lock.withLock { events.append(event) }
    }
}

private final class PerformanceTLSProbeState: @unchecked Sendable {
    struct Attempt: Codable {
        let name: String
        let expected: String
        let passed: Bool
        let httpStatus: Int?
        let errorCode: String?
        let urlErrorCode: Int?
        let elapsedSeconds: Double
        let trace: [PerformanceTLSTrace.Event]
    }
    private let lock = NSLock()
    private var attempts: [Attempt] = []
    private var unexpectedError: Error?
    var firstUnexpectedError: Error? { lock.withLock { unexpectedError } }
    var completeAndPassed: Bool {
        lock.withLock {
            attempts.map(\.name) == ["pinned-leaf", "malformed-pin", "different-parseable-der-pin"]
                && attempts.allSatisfy(\.passed)
        }
    }

    func record(_ attempt: Attempt, error: Error?) {
        lock.withLock {
            attempts.append(attempt)
            if !attempt.passed, unexpectedError == nil { unexpectedError = error ?? PerformanceRunError.wrongContent }
        }
    }

    func finish(root: URL, failure: Error?, cleanupPassed: Bool, deadlinePassed: Bool,
                fixtureRetained: Bool, elapsed: Duration) throws {
        let values = lock.withLock { attempts }
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(values))
        let parts = elapsed.components
        try PerformanceFiles.write(PerformanceFiles.json([
            "schemaVersion": 1, "runKind": "native-async-bytes-tls-contract", "stage": "tls-contract-only",
            "status": failure == nil && completeAndPassed && cleanupPassed && deadlinePassed ? "PASS" : "FAIL_OR_INCOMPLETE",
            "attempts": encoded, "expectedAttemptCount": 3, "recordedAttemptCount": values.count,
            "failureCode": failure.map { PerformanceRunError.code($0) as Any } ?? NSNull(),
            "ownedChildrenJoined": cleanupPassed, "withinThirtySecondLifecycle": deadlinePassed,
            "elapsedSeconds": Double(parts.seconds) + Double(parts.attoseconds) / 1e18,
            "fixtureRetained": fixtureRetained, "performanceMeasured": false, "productBinariesStarted": 0,
            "networkScope": "synthetic-loopback-not-tailnet",
        ]), to: root.appendingPathComponent("tls-result.json"), synchronize: true)
    }
}

extension PerformanceScope {
    func runTLSProbe(state: PerformanceTLSProbeState, until deadline: ContinuousClock.Instant) async throws {
        let upstream = try PerformancePort()
        ports.append(upstream)
        // A bound, non-listening Darwin socket can time out instead of refusing.
        // Accept and reset one connection on this owned listener, without HTTP.
        try upstream.prepareResetListener()
        try await startTLS(upstream: upstream.port)
        let origin = try XCTUnwrap(web).origin
        let leafURL = fixture.base.appendingPathComponent("private-tls/home/cert.der")
        let leaf = try XCTUnwrap(PerformanceFiles.read(leafURL, maximum: 65_536))
        guard !leaf.isEmpty, SecCertificateCreateWithData(nil, leaf as CFData) != nil else {
            throw PerformanceRunError.configuration
        }
        let malformed = Data([0, 1, 2, 3])
        var different = leaf
        // Change only a signature byte: preserve ASN.1 structure, not signature validity.
        different[different.index(before: different.endIndex)] ^= 1
        guard malformed != leaf, SecCertificateCreateWithData(nil, malformed as CFData) == nil,
              different != leaf, SecCertificateCreateWithData(nil, different as CFData) != nil else {
            throw PerformanceRunError.configuration
        }
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                try await upstream.resetOneConnection(until: deadline)
                try self.evidence.lifecycle("owned_upstream_connection_reset", values: ["count": 1])
                return false
            }
            group.addTask {
                try await self.runTLSProbeRequests(origin: origin, leaf: leaf, malformed: malformed,
                    different: different, state: state, until: deadline)
                return true
            }
            defer { group.cancelAll() }
            var didFinishRequests = false
            while let requestsFinished = try await group.next() {
                if requestsFinished { didFinishRequests = true; group.cancelAll() }
                // A completed reset must not cancel the in-flight positive or either negative request.
            }
            guard didFinishRequests else { throw PerformanceRunError.deadline }
        } // Reset/request tasks both join before owned listener cleanup.
    }

    private func runTLSProbeRequests(origin: URL, leaf: Data, malformed: Data, different: Data,
                                     state: PerformanceTLSProbeState, until deadline: ContinuousClock.Instant) async throws {
        for (name, pin, positive) in [("pinned-leaf", leaf, true), ("malformed-pin", malformed, false),
                                      ("different-parseable-der-pin", different, false)] {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw PerformanceRunError.deadline }
            try requireRunning(bootstrap: true)
            let trace = PerformanceTLSTrace()
            let client = try PerformanceHTTP(origin: origin, leaf: pin, trace: trace)
            defer { client.close() } // A new ephemeral session for every case; no accepted-connection reuse.
            let started = ContinuousClock.now
            var status: Int?
            var caught: Error?
            var bytesEmpty = false
            do {
                let remaining = Self.seconds(started.duration(to: deadline))
                let (bytes, response) = try await client.request(path: "/", timeout: min(5, remaining), maximumBytes: 4096)
                status = response.statusCode; bytesEmpty = bytes.isEmpty
            } catch { caught = error }
            let events = trace.snapshot
            let leafRejection = !events.isEmpty && events.allSatisfy {
                $0.httpsOrigin && $0.serverTrustMethod && $0.exactLoopbackHost && $0.exactPort
                    && $0.expectedLeafPresent && $0.peerLeafPresent && !$0.leafMatches && !$0.accepted
            }
            let nsError = caught.map { $0 as NSError }
            let urlCode = nsError.flatMap { $0.domain == NSURLErrorDomain ? $0.code : nil }
            let expectedRejectionCodes = [NSURLErrorCancelled, NSURLErrorUserCancelledAuthentication,
                NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted]
            let passed = positive ? (caught == nil && status == 502 && bytesEmpty)
                : (status == nil && leafRejection && urlCode.map { expectedRejectionCodes.contains($0) } == true
                    && !Task.isCancelled)
            state.record(.init(name: name, expected: positive ? "https-helper-502" : "observed-leaf-rejection",
                passed: passed, httpStatus: status, errorCode: caught.map(PerformanceRunError.code), urlErrorCode: urlCode,
                elapsedSeconds: Self.seconds(started.duration(to: .now)), trace: events), error: caught)
            try evidence.lifecycle("tls_probe_attempt_completed", values: ["name": name, "passed": passed,
                "sessionChallengeCount": events.filter { $0.callback == "session-didReceive" }.count,
                "taskChallengeCount": events.filter { $0.callback == "task-didReceive" }.count])
        }
    }

    func closeTLSProbe(retainFixture: Bool) async throws {
        web?.close()
        // The sequential TLS setup creates at most three completed OpenSSL jobs
        // plus one live helper. Join each owned child exactly once, in parallel:
        // existing TERM(2s)/KILL(3s) bounds fit the eight-second cleanup reserve.
        let owned = children
        let joined = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            for child in owned {
                group.addTask {
                    do { try await child.stopAndJoin(); return true }
                    catch { return false }
                }
            }
            var complete = true
            for await success in group { complete = success && complete }
            return complete
        }
        guard joined else { throw PerformanceRunError.cleanup }
        for port in ports { try port.close() }
        try evidence.lifecycle("owned_children_joined", values: ["count": owned.count])
        if retainFixture {
            print("COLLECTOR_TLS_PROBE_RETAINED fixture=\(fixture.base.path) socketRoot=\(socketRoot.path)")
            return
        }
        try FileManager.default.removeItem(at: socketRoot)
        fixture.remove()
        guard !FileManager.default.fileExists(atPath: fixture.base.path) else { throw PerformanceRunError.cleanup }
    }
}
