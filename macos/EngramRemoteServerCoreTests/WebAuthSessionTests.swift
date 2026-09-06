import CryptoKit
import Foundation
@testable import EngramRemoteServerCore
import XCTest

final class WebAuthSessionTests: XCTestCase {
    private let viewer = "test-only-viewer-credential"

    private func makeStore(
        clock: WebTestClock = WebTestClock(),
        random: WebTestRandom = WebTestRandom()
    ) throws -> WebAuthSessionStore {
        WebAuthSessionStore(
            configuration: try EngramRemoteWebConfig(
                origin: "https://viewer.example", viewerCredential: viewer,
                serverBearerCredentials: ["test-v1-bearer", "test-archive-bearer", "test-mcp-bearer"]
            ),
            now: { clock.now }, randomBytes: { try random.next() }
        )
    }

    private func token(
        _ result: WebAuthSessionStore.LoginResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String? {
        guard case let .authenticated(token) = result else {
            XCTFail("Expected a fresh authenticated session, got \(result)", file: file, line: line)
            return nil
        }
        return token
    }

    func testMintsOpaque32ByteURLSafeSessionAndStoresOnlyItsDigestKey() async throws {
        let random = WebTestRandom(fixed: Data(repeating: 0xa5, count: 32))
        let store = try makeStore(random: random)
        guard let token = token(await store.login(credential: viewer)) else { return }
        XCTAssertEqual(token.count, 43)
        XCTAssertNotNil(token.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression))
        let decoded = Data(base64Encoded: token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "=")
        XCTAssertEqual(decoded, Data(repeating: 0xa5, count: 32))
        let digests = await store.sessionDigests
        XCTAssertEqual(digests, [Data(SHA256.hash(data: Data(token.utf8)))])
        XCTAssertFalse(digests.contains(Data(token.utf8)))
        XCTAssertFalse(token.contains(viewer))
        let authenticated = await store.isAuthenticated(sessionToken: token)
        XCTAssertTrue(authenticated)
    }

    func testWrongViewerAndEveryServerBearerAreRejectedWithoutMinting() async throws {
        let random = WebTestRandom()
        let store = try makeStore(random: random)
        for credential in ["", "wrong", "test-v1-bearer", "test-archive-bearer", "test-mcp-bearer"] {
            let outcome = await store.login(credential: credential)
            XCTAssertEqual(outcome, .unauthorized)
        }
        XCTAssertEqual(random.calls, 0)
        let digests = await store.sessionDigests
        XCTAssertTrue(digests.isEmpty)
    }

    func testSuccessfulLoginsCreateIndependentSessions() async throws {
        let store = try makeStore()
        guard let first = token(await store.login(credential: viewer)),
              let second = token(await store.login(credential: viewer)) else { return }
        XCTAssertNotEqual(first, second)
        let firstValid = await store.isAuthenticated(sessionToken: first)
        let secondValid = await store.isAuthenticated(sessionToken: second)
        XCTAssertTrue(firstValid)
        XCTAssertTrue(secondValid)
        let digests = await store.sessionDigests
        XCTAssertEqual(digests.count, 2)
    }

    func testExpiresAtExactlyFifteenMinutesWithoutSlidingOnReads() async throws {
        let clock = WebTestClock()
        let store = try makeStore(clock: clock)
        guard let token = token(await store.login(credential: viewer)) else { return }
        clock.advance(seconds: 899)
        let before = await store.isAuthenticated(sessionToken: token)
        XCTAssertTrue(before)
        clock.advance(seconds: 1)
        let atDeadline = await store.isAuthenticated(sessionToken: token)
        XCTAssertFalse(atDeadline)
        let digests = await store.sessionDigests
        XCTAssertTrue(digests.isEmpty)
    }

    func testExpiredOrRevokedSessionsCannotReviveAfterInjectedClockRollback() async throws {
        let clock = WebTestClock()
        let store = try makeStore(clock: clock)
        guard let expired = token(await store.login(credential: viewer)),
              let revoked = token(await store.login(credential: viewer)) else { return }
        await store.logout(sessionToken: revoked)
        clock.advance(seconds: 900)
        let expiredNow = await store.isAuthenticated(sessionToken: expired)
        XCTAssertFalse(expiredNow)
        clock.set(nanoseconds: 0)
        let expiredAfterRollback = await store.isAuthenticated(sessionToken: expired)
        let revokedAfterRollback = await store.isAuthenticated(sessionToken: revoked)
        XCTAssertFalse(expiredAfterRollback)
        XCTAssertFalse(revokedAfterRollback)
    }

    func testLogoutRevokesOnlyTargetAndIsIdempotent() async throws {
        let store = try makeStore()
        guard let first = token(await store.login(credential: viewer)),
              let second = token(await store.login(credential: viewer)) else { return }
        await store.logout(sessionToken: first)
        await store.logout(sessionToken: first)
        await store.logout(sessionToken: "unknown")
        let firstValid = await store.isAuthenticated(sessionToken: first)
        let secondValid = await store.isAuthenticated(sessionToken: second)
        XCTAssertFalse(firstValid)
        XCTAssertTrue(secondValid)
        let digests = await store.sessionDigests
        XCTAssertEqual(digests.count, 1)
    }

    func testMalformedUnknownAndViewerTokensHaveNoAuthority() async throws {
        let store = try makeStore()
        for value in ["", viewer, "test-v1-bearer", String(repeating: "A", count: 43), "a=b", "x;y", String(repeating: "a", count: 4096)] {
            let valid = await store.isAuthenticated(sessionToken: value)
            XCTAssertFalse(valid)
        }
    }

    func testGlobalFiveAttemptWindowCountsBothFailedAndSuccessfulLogins() async throws {
        let clock = WebTestClock()
        let store = try makeStore(clock: clock)
        for _ in 0..<4 {
            let outcome = await store.login(credential: "wrong")
            XCTAssertEqual(outcome, .unauthorized)
        }
        guard token(await store.login(credential: viewer)) != nil else { return }
        let blocked = await store.login(credential: viewer)
        XCTAssertEqual(blocked, .throttled(retryAfterSeconds: 60))
        clock.advance(seconds: 59)
        let almostReset = await store.login(credential: viewer)
        XCTAssertEqual(almostReset, .throttled(retryAfterSeconds: 1))
        clock.advance(seconds: 1)
        let afterReset = await store.login(credential: viewer)
        XCTAssertNotNil(token(afterReset))
    }

    func testConcurrentAttemptsCannotRacePastGlobalFiveAttemptLimit() async throws {
        let store = try makeStore()
        let credential = viewer
        let outcomes = await withTaskGroup(of: WebAuthSessionStore.LoginResult.self) { group in
            for _ in 0..<20 { group.addTask { await store.login(credential: credential) } }
            var results: [WebAuthSessionStore.LoginResult] = []
            for await result in group { results.append(result) }
            return results
        }
        let accepted = outcomes.filter { if case .authenticated = $0 { return true }; return false }
        XCTAssertEqual(accepted.count, 5)
        XCTAssertEqual(outcomes.filter { $0 == .throttled(retryAfterSeconds: 60) }.count, 15)
        let digests = await store.sessionDigests
        XCTAssertEqual(digests.count, 5)
    }

    func testLogoutDoesNotResetGlobalLoginThrottle() async throws {
        let store = try makeStore()
        guard let token = token(await store.login(credential: viewer)) else { return }
        for _ in 0..<4 { _ = await store.login(credential: "wrong") }
        await store.logout(sessionToken: token)
        let outcome = await store.login(credential: viewer)
        XCTAssertEqual(outcome, .throttled(retryAfterSeconds: 60))
    }

    func testCapacityRejectsSixtyFifthWithoutEvictingValidSessionsThenReclaimsExpired() async throws {
        let clock = WebTestClock()
        let store = try makeStore(clock: clock)
        var issued: [String] = []
        for index in 0..<64 {
            if index > 0, index.isMultiple(of: 5) { clock.advance(seconds: 60) }
            guard let token = token(await store.login(credential: viewer)) else { return }
            issued.append(token)
        }
        let full = await store.login(credential: viewer)
        XCTAssertEqual(full, .unavailable)
        for token in issued {
            let valid = await store.isAuthenticated(sessionToken: token)
            XCTAssertTrue(valid, "Capacity pressure must not evict valid sessions")
        }
        let fullDigests = await store.sessionDigests
        XCTAssertEqual(fullDigests.count, 64)
        clock.advance(seconds: 180)
        let afterExpiry = await store.login(credential: viewer)
        XCTAssertNotNil(token(afterExpiry))
        let lastStillValid = await store.isAuthenticated(sessionToken: issued[63])
        let firstExpired = await store.isAuthenticated(sessionToken: issued[0])
        XCTAssertTrue(lastStillValid)
        XCTAssertFalse(firstExpired)
        let reclaimed = await store.sessionDigests
        XCTAssertEqual(reclaimed.count, 60)
    }

    func testRNGFailureAndWrongLengthFailClosedWithoutCreatingSessions() async throws {
        let variants = [WebTestRandom(throwsError: true), WebTestRandom(fixed: Data()), WebTestRandom(fixed: Data(count: 31)), WebTestRandom(fixed: Data(count: 33))]
        for random in variants {
            let store = try makeStore(random: random)
            let outcome = await store.login(credential: viewer)
            XCTAssertEqual(outcome, .unavailable)
            let digests = await store.sessionDigests
            XCTAssertTrue(digests.isEmpty)
        }
    }

    func testRandomCollisionNeverReusesOrRevokesAnExistingSession() async throws {
        let store = try makeStore(random: WebTestRandom(fixed: Data(repeating: 42, count: 32)))
        guard let first = token(await store.login(credential: viewer)) else { return }
        let collided = await store.login(credential: viewer)
        XCTAssertEqual(collided, .unavailable)
        let stillValid = await store.isAuthenticated(sessionToken: first)
        XCTAssertTrue(stillValid)
        let digests = await store.sessionDigests
        XCTAssertEqual(digests.count, 1)
    }

    func testUnrepresentableClockDeadlinesFailClosedWithoutMintingOrTrapping() async throws {
        for instant in [UInt64.max, UInt64.max - 899_000_000_000] {
            let clock = WebTestClock()
            clock.set(nanoseconds: instant)
            let random = WebTestRandom()
            let store = try makeStore(clock: clock, random: random)
            let outcome = await store.login(credential: viewer)
            XCTAssertEqual(outcome, .unavailable)
            XCTAssertEqual(random.calls, 0)
            let digests = await store.sessionDigests
            XCTAssertTrue(digests.isEmpty)
        }
    }
}

/// Locked deterministic fixtures shared only by the Web unit tests.
final class WebTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: UInt64 = 0
    var now: UInt64 { lock.withLock { instant } }
    func advance(seconds: UInt64) { lock.withLock { instant += seconds * 1_000_000_000 } }
    func set(nanoseconds: UInt64) { lock.withLock { instant = nanoseconds } }
}

final class WebTestRandom: @unchecked Sendable {
    private enum Failure: Error { case unavailable }
    private let lock = NSLock()
    private var count = 0
    private let fixed: Data?
    private let throwsError: Bool

    init(fixed: Data? = nil, throwsError: Bool = false) {
        self.fixed = fixed
        self.throwsError = throwsError
    }

    var calls: Int { lock.withLock { count } }

    func next() throws -> Data {
        try lock.withLock {
            count += 1
            if throwsError { throw Failure.unavailable }
            if let fixed { return fixed }
            var bytes = Data(repeating: 0xa5, count: 32)
            withUnsafeBytes(of: UInt64(count).bigEndian) { bytes.replaceSubrange(24..<32, with: $0) }
            return bytes
        }
    }
}
