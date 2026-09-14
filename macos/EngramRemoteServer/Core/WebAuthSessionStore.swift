import CryptoKit
import Dispatch
import Foundation

/// Process-local session authority; never persists bearer session material.
actor WebAuthSessionStore {
    static let lifetimeSeconds = 900
    private static let lifetimeNanoseconds = UInt64(lifetimeSeconds) * 1_000_000_000
    private static let attemptWindowNanoseconds: UInt64 = 60_000_000_000
    private static let capacity = 64

    enum LoginResult: Equatable, Sendable {
        case authenticated(sessionToken: String)
        case unauthorized
        case throttled(retryAfterSeconds: Int)
        case unavailable
    }

    private let configuration: EngramRemoteWebConfig
    private let now: @Sendable () -> UInt64
    private let randomBytes: @Sendable () throws -> Data
    private struct Session: Sendable {
        let expiresAt: UInt64
        let canWrite: Bool
    }
    private var sessions: [Data: Session] = [:]
    private var attemptTimes: [UInt64] = []
    private var lastObservedTime: UInt64 = 0
    var sessionDigests: Set<Data> { Set(sessions.keys) }

    init(
        configuration: EngramRemoteWebConfig,
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        randomBytes: @escaping @Sendable () throws -> Data = {
            SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        }
    ) {
        self.configuration = configuration
        self.now = now
        self.randomBytes = randomBytes
    }

    func login(credential: String) -> LoginResult {
        let instant = monotonicNow()
        purgeExpired(at: instant)
        let (expiresAt, overflow) = instant.addingReportingOverflow(Self.lifetimeNanoseconds)
        guard !overflow else { return .unavailable }

        // At most five timestamps are retained. Rejected attempts do not extend
        // the window, and no client address or forwarded header partitions it.
        attemptTimes.removeAll { instant >= $0 && instant - $0 >= Self.attemptWindowNanoseconds }
        if attemptTimes.count >= 5, let oldest = attemptTimes.first {
            let remaining = Self.attemptWindowNanoseconds - (instant - oldest)
            return .throttled(retryAfterSeconds: Int((remaining + 999_999_999) / 1_000_000_000))
        }
        attemptTimes.append(instant)

        let submittedDigest = Data(SHA256.hash(data: Data(credential.utf8)))
        let isViewer = constantTimeEqual(submittedDigest, configuration.credentialDigest)
        let isEditor = configuration.editorCredentialDigest.map { constantTimeEqual(submittedDigest, $0) } ?? false
        guard isViewer || isEditor else { return .unauthorized }
        guard sessions.count < Self.capacity else { return .unavailable }
        let bytes: Data
        do { bytes = try randomBytes() } catch { return .unavailable }
        guard bytes.count == 32 else { return .unavailable }
        let token = bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let digest = Self.sessionDigest(token)
        guard sessions[digest] == nil else { return .unavailable }
        sessions[digest] = Session(expiresAt: expiresAt, canWrite: isEditor)
        return .authenticated(sessionToken: token)
    }

    func isAuthenticated(sessionToken: String) -> Bool {
        validSession(sessionToken: sessionToken) != nil
    }

    func canWrite(sessionToken: String) -> Bool {
        validSession(sessionToken: sessionToken)?.canWrite ?? false
    }

    private func validSession(sessionToken: String) -> Session? {
        let instant = monotonicNow()
        purgeExpired(at: instant)
        guard Self.isWellFormedToken(sessionToken) else { return nil }
        return sessions[Self.sessionDigest(sessionToken)]
    }

    func logout(sessionToken: String) {
        guard Self.isWellFormedToken(sessionToken) else { return }
        sessions.removeValue(forKey: Self.sessionDigest(sessionToken))
    }

    static func isWellFormedToken(_ token: String) -> Bool {
        token.utf8.count == 43 && token.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }

    private static func sessionDigest(_ token: String) -> Data {
        Data(SHA256.hash(data: Data(token.utf8)))
    }

    private func monotonicNow() -> UInt64 {
        lastObservedTime = max(lastObservedTime, now())
        return lastObservedTime
    }

    private func purgeExpired(at instant: UInt64) {
        sessions = sessions.filter { $0.value.expiresAt > instant }
    }

    private func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == 32, rhs.count == 32 else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) { difference |= left ^ right }
        return difference == 0
    }
}
