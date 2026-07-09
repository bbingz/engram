import Foundation

/// Per-provider circuit breaker for embedding transport failures.
///
/// State machine: `closed` → (N consecutive transport failures) → `open` →
/// (cooldown elapsed) → `halfOpen` (single probe) → success/`closed` or
/// failure/`open`. Thread-safe under concurrent backfills and search embeds.
///
/// Defaults: **N = 5**, **cooldown = 60s** (see
/// `docs/embedding-guardrails-design-2026-07.md`). Process-local only — no DB,
/// no `ai_audit_log`.
public final class EmbeddingCircuitBreaker: @unchecked Sendable {
    public static let defaultFailureThreshold = 5
    public static let defaultCooldown: TimeInterval = 60

    public enum State: String, Sendable, Equatable {
        case closed
        case open
        case halfOpen
    }

    public struct Config: Sendable, Equatable {
        public var failureThreshold: Int
        public var cooldown: TimeInterval

        public init(
            failureThreshold: Int = EmbeddingCircuitBreaker.defaultFailureThreshold,
            cooldown: TimeInterval = EmbeddingCircuitBreaker.defaultCooldown
        ) {
            self.failureThreshold = max(1, failureThreshold)
            self.cooldown = max(0, cooldown)
        }
    }

    public struct ProviderSnapshot: Sendable, Equatable {
        public let providerKey: String
        public let state: String
        public let consecutiveFailures: Int
        public let transportFailures: Int
        public let successes: Int
        public let opens: Int
        public let rejections: Int
        public let halfOpenProbes: Int
        public let cooldownRemainingMs: Double?

        public init(
            providerKey: String,
            state: String,
            consecutiveFailures: Int,
            transportFailures: Int,
            successes: Int,
            opens: Int,
            rejections: Int,
            halfOpenProbes: Int,
            cooldownRemainingMs: Double?
        ) {
            self.providerKey = providerKey
            self.state = state
            self.consecutiveFailures = consecutiveFailures
            self.transportFailures = transportFailures
            self.successes = successes
            self.opens = opens
            self.rejections = rejections
            self.halfOpenProbes = halfOpenProbes
            self.cooldownRemainingMs = cooldownRemainingMs
        }
    }

    public enum Transition: String, Sendable {
        case opened
        case halfOpenProbe
        case closed
        case reopened
    }

    private struct ProviderState {
        var state: State = .closed
        var consecutiveFailures = 0
        var transportFailures = 0
        var successes = 0
        var opens = 0
        var rejections = 0
        var halfOpenProbes = 0
        var openUntil: Date?
        var probeInFlight = false
    }

    public let config: Config
    private let now: @Sendable () -> Date
    private var onTransition: (@Sendable (String, Transition) -> Void)?
    private let lock = NSLock()
    private var providers: [String: ProviderState] = [:]

    public init(
        config: Config = Config(),
        now: @escaping @Sendable () -> Date = { Date() },
        onTransition: (@Sendable (String, Transition) -> Void)? = nil
    ) {
        self.config = config
        self.now = now
        self.onTransition = onTransition
    }

    /// Install/replace transition logging (e.g. service `os_log` via
    /// `ServiceLogger`). Safe to call once at process start.
    public func setOnTransition(_ handler: (@Sendable (String, Transition) -> Void)?) {
        lock.lock()
        onTransition = handler
        lock.unlock()
    }

    /// Stable key for per-provider state (base URL + model).
    public static func providerKey(for config: EmbeddingConfig) -> String {
        "\(config.baseURL)|\(config.model)"
    }

    /// Whether `error` should count toward the consecutive-failure threshold.
    public static func isTransportFailure(_ error: Error) -> Bool {
        if error is CancellationError {
            return false
        }
        if let embedding = error as? EmbeddingError {
            switch embedding {
            case .http(let status):
                return status >= 500 || status == 429
            case .notConfigured, .malformedResponse, .circuitOpen:
                return false
            }
        }
        if error is URLError {
            return true
        }
        // Non-EmbeddingError throws from URLSession / JSON are treated as transport.
        return true
    }

    /// Admit one embed attempt, or throw `EmbeddingError.circuitOpen`.
    public func allowRequest(providerKey: String) throws {
        let outcome: (Transition?, Bool) = {
            lock.lock()
            defer { lock.unlock() }
            var state = providers[providerKey] ?? ProviderState()
            let instant = now()
            var transition: Transition?
            switch state.state {
            case .closed:
                break
            case .open:
                if let openUntil = state.openUntil, instant >= openUntil {
                    state.state = .halfOpen
                    state.probeInFlight = true
                    state.halfOpenProbes += 1
                    transition = .halfOpenProbe
                } else {
                    state.rejections += 1
                    providers[providerKey] = state
                    return (nil, false)
                }
            case .halfOpen:
                if state.probeInFlight {
                    state.rejections += 1
                    providers[providerKey] = state
                    return (nil, false)
                }
                state.probeInFlight = true
                state.halfOpenProbes += 1
                transition = .halfOpenProbe
            }
            providers[providerKey] = state
            return (transition, true)
        }()
        guard outcome.1 else { throw EmbeddingError.circuitOpen }
        if let transition = outcome.0 {
            emitTransition(providerKey, transition)
        }
    }

    public func recordSuccess(providerKey: String) {
        let transition: Transition? = {
            lock.lock()
            defer { lock.unlock() }
            var state = providers[providerKey] ?? ProviderState()
            state.successes += 1
            state.consecutiveFailures = 0
            state.probeInFlight = false
            state.openUntil = nil
            var transition: Transition?
            if state.state != .closed {
                state.state = .closed
                transition = .closed
            }
            providers[providerKey] = state
            return transition
        }()
        if let transition {
            emitTransition(providerKey, transition)
        }
    }

    public func recordTransportFailure(providerKey: String) {
        let transition: Transition? = {
            lock.lock()
            defer { lock.unlock() }
            var state = providers[providerKey] ?? ProviderState()
            state.transportFailures += 1
            state.consecutiveFailures += 1
            state.probeInFlight = false
            let instant = now()
            var transition: Transition?
            if state.state == .halfOpen {
                state.state = .open
                state.opens += 1
                state.openUntil = instant.addingTimeInterval(config.cooldown)
                transition = .reopened
            } else if state.state == .closed, state.consecutiveFailures >= config.failureThreshold {
                state.state = .open
                state.opens += 1
                state.openUntil = instant.addingTimeInterval(config.cooldown)
                transition = .opened
            }
            providers[providerKey] = state
            return transition
        }()
        if let transition {
            emitTransition(providerKey, transition)
        }
    }

    private func emitTransition(_ providerKey: String, _ transition: Transition) {
        lock.lock()
        let handler = onTransition
        lock.unlock()
        handler?(providerKey, transition)
    }

    public func state(for providerKey: String) -> State {
        lock.lock()
        defer { lock.unlock() }
        return providers[providerKey]?.state ?? .closed
    }

    public func snapshots() -> [ProviderSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        let instant = now()
        return providers.keys.sorted().compactMap { key -> ProviderSnapshot? in
            guard let state = providers[key] else { return nil }
            let remaining: Double?
            if state.state == .open, let openUntil = state.openUntil {
                remaining = max(0, openUntil.timeIntervalSince(instant) * 1000)
            } else {
                remaining = nil
            }
            return ProviderSnapshot(
                providerKey: key,
                state: state.state.rawValue,
                consecutiveFailures: state.consecutiveFailures,
                transportFailures: state.transportFailures,
                successes: state.successes,
                opens: state.opens,
                rejections: state.rejections,
                halfOpenProbes: state.halfOpenProbes,
                cooldownRemainingMs: remaining
            )
        }
    }
}

/// Decorator that admits `embed` through an `EmbeddingCircuitBreaker`.
public struct GuardedEmbeddingProvider: EmbeddingProvider {
    public let model: String
    public let dimension: Int
    public let providerKey: String
    private let inner: any EmbeddingProvider
    private let breaker: EmbeddingCircuitBreaker

    public init(
        inner: any EmbeddingProvider,
        breaker: EmbeddingCircuitBreaker,
        providerKey: String
    ) {
        self.inner = inner
        self.breaker = breaker
        self.providerKey = providerKey
        self.model = inner.model
        self.dimension = inner.dimension
    }

    public init(
        config: EmbeddingConfig,
        breaker: EmbeddingCircuitBreaker,
        session: URLSession = .shared
    ) {
        self.init(
            inner: OpenAICompatibleEmbeddingClient(config: config, session: session),
            breaker: breaker,
            providerKey: EmbeddingCircuitBreaker.providerKey(for: config)
        )
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        try breaker.allowRequest(providerKey: providerKey)
        do {
            let vectors = try await inner.embed(texts)
            breaker.recordSuccess(providerKey: providerKey)
            return vectors
        } catch {
            if EmbeddingCircuitBreaker.isTransportFailure(error) {
                breaker.recordTransportFailure(providerKey: providerKey)
            }
            throw error
        }
    }
}

/// Process-wide store used by the service runner and read provider so search
/// and backfill share the same per-provider breaker state. Tests should
/// construct private `EmbeddingCircuitBreaker` instances instead.
public enum EmbeddingGuardrails {
    public static let sharedBreaker = EmbeddingCircuitBreaker()

    public static func guardedProvider(
        for config: EmbeddingConfig,
        breaker: EmbeddingCircuitBreaker = sharedBreaker
    ) -> any EmbeddingProvider {
        GuardedEmbeddingProvider(config: config, breaker: breaker)
    }
}
