import EngramCoreRead
import Foundation
import XCTest

/// Unit tests for embedding circuit-breaker guardrails (wave-6 task 9).
/// Params under test: N=5 consecutive transport failures, 60s cooldown.
final class EmbeddingCircuitBreakerTests: XCTestCase {
    private let key = "https://api.example.com/v1|probe-model"

    private func makeBreaker(
        threshold: Int = 5,
        cooldown: TimeInterval = 60,
        clock: TestClock = TestClock()
    ) -> EmbeddingCircuitBreaker {
        EmbeddingCircuitBreaker(
            config: .init(failureThreshold: threshold, cooldown: cooldown),
            now: { clock.now }
        )
    }

    func testOpensAfterNConsecutiveTransportFailures() throws {
        let clock = TestClock()
        let breaker = makeBreaker(clock: clock)

        for _ in 0..<4 {
            try breaker.allowRequest(providerKey: key)
            breaker.recordTransportFailure(providerKey: key)
            XCTAssertEqual(breaker.state(for: key), .closed)
        }
        try breaker.allowRequest(providerKey: key)
        breaker.recordTransportFailure(providerKey: key)
        XCTAssertEqual(breaker.state(for: key), .open)

        XCTAssertThrowsError(try breaker.allowRequest(providerKey: key)) { error in
            XCTAssertEqual(error as? EmbeddingError, .circuitOpen)
        }
        let snap = try XCTUnwrap(breaker.snapshots().first)
        XCTAssertEqual(snap.opens, 1)
        XCTAssertEqual(snap.transportFailures, 5)
        XCTAssertEqual(snap.consecutiveFailures, 5)
        XCTAssertEqual(snap.rejections, 1)
    }

    func testNonTransportFailuresDoNotOpenBreaker() throws {
        let breaker = makeBreaker(threshold: 2)
        for _ in 0..<5 {
            try breaker.allowRequest(providerKey: key)
            // Simulate recording only when isTransportFailure is true.
            XCTAssertFalse(EmbeddingCircuitBreaker.isTransportFailure(EmbeddingError.notConfigured))
            XCTAssertFalse(EmbeddingCircuitBreaker.isTransportFailure(EmbeddingError.malformedResponse))
            XCTAssertFalse(EmbeddingCircuitBreaker.isTransportFailure(EmbeddingError.http(401)))
            XCTAssertFalse(EmbeddingCircuitBreaker.isTransportFailure(EmbeddingError.circuitOpen))
            XCTAssertTrue(EmbeddingCircuitBreaker.isTransportFailure(EmbeddingError.http(500)))
            XCTAssertTrue(EmbeddingCircuitBreaker.isTransportFailure(EmbeddingError.http(429)))
            XCTAssertTrue(EmbeddingCircuitBreaker.isTransportFailure(URLError(.timedOut)))
        }
        XCTAssertEqual(breaker.state(for: key), .closed)
    }

    func testHalfOpenProbeSuccessCloses() async throws {
        let clock = TestClock()
        let breaker = makeBreaker(threshold: 2, cooldown: 60, clock: clock)
        let failing = CountingProvider(mode: .failTransport)
        let guarded = GuardedEmbeddingProvider(inner: failing, breaker: breaker, providerKey: key)

        for _ in 0..<2 {
            do { _ = try await guarded.embed(["x"]) } catch { /* expected */ }
        }
        XCTAssertEqual(breaker.state(for: key), .open)

        // Still open before cooldown.
        do {
            _ = try await guarded.embed(["probe"])
            XCTFail("expected circuitOpen")
        } catch EmbeddingError.circuitOpen {
            // ok
        }

        clock.advance(by: 60)
        let recovering = CountingProvider(mode: .succeed)
        let guarded2 = GuardedEmbeddingProvider(inner: recovering, breaker: breaker, providerKey: key)
        let vectors = try await guarded2.embed(["probe"])
        XCTAssertEqual(vectors.count, 1)
        XCTAssertEqual(breaker.state(for: key), .closed)
        let snap = try XCTUnwrap(breaker.snapshots().first)
        XCTAssertEqual(snap.halfOpenProbes, 1)
        XCTAssertEqual(snap.successes, 1)
    }

    func testHalfOpenProbeFailureReopens() async throws {
        let clock = TestClock()
        let breaker = makeBreaker(threshold: 2, cooldown: 30, clock: clock)
        let failing = CountingProvider(mode: .failTransport)
        let guarded = GuardedEmbeddingProvider(inner: failing, breaker: breaker, providerKey: key)

        for _ in 0..<2 {
            do { _ = try await guarded.embed(["x"]) } catch { /* expected */ }
        }
        XCTAssertEqual(breaker.state(for: key), .open)

        clock.advance(by: 30)
        do {
            _ = try await guarded.embed(["probe"])
            XCTFail("expected transport failure")
        } catch {
            XCTAssertEqual(error as? EmbeddingError, .http(503))
        }
        XCTAssertEqual(breaker.state(for: key), .open)
        let snap = try XCTUnwrap(breaker.snapshots().first)
        XCTAssertEqual(snap.opens, 2)
        XCTAssertEqual(snap.halfOpenProbes, 1)
    }

    func testConcurrentRequestsShareConsistentOpenState() async throws {
        let clock = TestClock()
        let breaker = makeBreaker(threshold: 3, cooldown: 60, clock: clock)
        let failing = CountingProvider(mode: .failTransport)
        let guarded = GuardedEmbeddingProvider(inner: failing, breaker: breaker, providerKey: key)

        // Trip the breaker with sequential failures first.
        for _ in 0..<3 {
            do { _ = try await guarded.embed(["x"]) } catch { /* expected */ }
        }
        XCTAssertEqual(breaker.state(for: key), .open)

        // Concurrent rejections must not corrupt counters or call the provider.
        let beforeCalls = await failing.callCount()
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    do {
                        _ = try await guarded.embed(["concurrent"])
                        return false
                    } catch EmbeddingError.circuitOpen {
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var rejected = 0
            for await ok in group where ok {
                rejected += 1
            }
            XCTAssertEqual(rejected, 32)
        }
        let afterCalls = await failing.callCount()
        XCTAssertEqual(afterCalls, beforeCalls, "open breaker must not call the provider")
        XCTAssertEqual(breaker.state(for: key), .open)
        let snap = try XCTUnwrap(breaker.snapshots().first)
        XCTAssertEqual(snap.rejections, 32)
        XCTAssertEqual(snap.opens, 1)
    }

    func testSuccessResetsConsecutiveFailureStreak() async throws {
        let breaker = makeBreaker(threshold: 3)
        let failing = CountingProvider(mode: .failTransport)
        let succeeding = CountingProvider(mode: .succeed)
        let failGuarded = GuardedEmbeddingProvider(inner: failing, breaker: breaker, providerKey: key)
        let okGuarded = GuardedEmbeddingProvider(inner: succeeding, breaker: breaker, providerKey: key)

        // 2 failures + 1 success should leave breaker closed (threshold 3).
        for _ in 0..<2 {
            do { _ = try await failGuarded.embed(["f"]) } catch { /* expected */ }
        }
        _ = try await okGuarded.embed(["ok"])
        XCTAssertEqual(breaker.state(for: key), .closed)

        // Need 3 more consecutive failures to open.
        for _ in 0..<2 {
            do { _ = try await failGuarded.embed(["f"]) } catch { /* expected */ }
        }
        XCTAssertEqual(breaker.state(for: key), .closed)
        do { _ = try await failGuarded.embed(["f"]) } catch { /* expected */ }
        XCTAssertEqual(breaker.state(for: key), .open)
    }
}

// MARK: - Helpers

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now = Date(timeIntervalSince1970: 1_000_000)
    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return _now
    }
    func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        _now = _now.addingTimeInterval(seconds)
    }
}

private actor CountingProvider: EmbeddingProvider {
    enum Mode: Sendable {
        case failTransport
        case succeed
    }

    let model = "probe-model"
    let dimension = 3
    private let mode: Mode
    private var calls = 0

    init(mode: Mode) {
        self.mode = mode
    }

    func callCount() -> Int { calls }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        calls += 1
        switch mode {
        case .failTransport:
            throw EmbeddingError.http(503)
        case .succeed:
            return texts.map { _ in VectorMath.l2Normalize([1, 0, 0]) }
        }
    }
}
