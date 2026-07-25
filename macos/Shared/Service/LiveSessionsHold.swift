import Foundation

/// Last-good live-session list with a **per-site** live window.
///
/// A failed poll must not blank the UI (row 9). Each consumer polls at a
/// different cadence (SourcePulse 10s, popover/badge 30s), so the live window
/// is supplied by the owner — never a shared constant. A single 15s threshold
/// would leave the 30s sites at age ~29s for most of every healthy interval and
/// permanently caption them "as of HH:mm" (false degradation, inverted).
///
/// `.live` is a **window**, not `age == 0`: callers compute `freshness(now:)` a
/// moment after `succeeded(at:)`, so exact-equality would never match at real
/// render time and every fresh poll would miscaption as stale.
struct LiveSessionsHold: Equatable, Sendable {
    private(set) var sessions: [EngramServiceLiveSessionInfo] = []
    private(set) var lastSuccessAt: Date?
    private(set) var lastAttemptAt: Date?

    /// Max age that still counts as `.live` for this hold's owner.
    /// Pass poll cadence × slack (1.5×) so a healthy site stays live across one
    /// full interval plus jitter without waiting for the next tick.
    let liveWindow: TimeInterval

    init(liveWindow: TimeInterval) {
        self.liveWindow = liveWindow
    }

    /// A *successful* poll (including one that returns `[]`) replaces the list
    /// and stamps the clock. Never call this on a thrown poll.
    mutating func succeeded(_ sessions: [EngramServiceLiveSessionInfo], at now: Date = Date()) {
        self.sessions = sessions
        self.lastSuccessAt = now
        self.lastAttemptAt = now
    }

    /// Record a failed poll without replacing the last-good list or success
    /// clock. The attempt stamp also gives `@State` owners a changed value so
    /// they re-evaluate time-derived freshness after every completed failure.
    mutating func failed(at now: Date = Date()) {
        self.lastAttemptAt = now
    }

    /// Freshness of the held list on the **live-poll** clock (not the status channel).
    func freshness(now: Date = Date()) -> ServiceDataFreshness {
        guard let lastSuccessAt else { return .expired }
        let age = max(0, now.timeIntervalSince(lastSuccessAt))
        if age <= liveWindow { return .live }
        if age <= EngramServiceStatusStore.staleUsefulInterval { return .stale(asOf: lastSuccessAt) }
        return .expired
    }
}
