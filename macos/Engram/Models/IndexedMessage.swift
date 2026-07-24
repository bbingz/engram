// macos/Engram/Models/IndexedMessage.swift
import Foundation

struct IndexedMessage: Identifiable {
    let id: UUID
    let message: ChatMessage
    let messageType: MessageType
    let typeIndex: Int
    /// Seconds for the turn this assistant message opens; nil when unknown/skewed (row 30).
    var turnDurationSeconds: Double?

    init(
        message: ChatMessage,
        messageType: MessageType,
        typeIndex: Int,
        turnDurationSeconds: Double? = nil
    ) {
        self.id = message.id
        self.message = message
        self.messageType = messageType
        self.typeIndex = typeIndex
        self.turnDurationSeconds = turnDurationSeconds
    }

    static func build(from messages: [ChatMessage]) -> (messages: [IndexedMessage], counts: [MessageType: Int]) {
        var counters: [MessageType: Int] = [:]
        for type in MessageType.allCases { counters[type] = 0 }

        var indexed = messages.map { msg in
            let type = MessageTypeClassifier.classify(msg)
            counters[type, default: 0] += 1
            return IndexedMessage(message: msg, messageType: type, typeIndex: counters[type]!)
        }
        applyTurnDurations(to: &indexed)
        return (indexed, counters)
    }

    /// Append-only rebuild for paging (row 27): classify only `newPage`, carry
    /// `typeIndex` counters forward. Turn durations: leave prior chips untouched
    /// and O(page) close turns that end on the new page, including a single-row
    /// `var` backfill of the boundary first-assistant (row 30 cross-coupling).
    static func appending(
        _ newPage: [ChatMessage],
        to prior: [IndexedMessage],
        counts: [MessageType: Int]
    ) -> (messages: [IndexedMessage], counts: [MessageType: Int]) {
        var counters = counts
        for type in MessageType.allCases where counters[type] == nil {
            counters[type] = 0
        }
        var next = prior
        let priorCount = prior.count
        for msg in newPage {
            let type = MessageTypeClassifier.classify(msg)
            counters[type, default: 0] += 1
            next.append(IndexedMessage(message: msg, messageType: type, typeIndex: counters[type]!))
        }
        closeTurnsAfterAppend(priorCount: priorCount, indexed: &next)
        return (next, counters)
    }

    /// Test seam: ISO parses performed by the most recent duration walk
    /// (`applyTurnDurations` or `closeTurnsAfterAppend`). Append must stay O(page).
    static private(set) var lastDurationWalkISOParses = 0

    /// Full-sequence turn walk for initial `build()` only. Resets all chips then
    /// re-keys durations. Must **not** be used on the append path.
    ///
    /// A user row with a missing/unparseable timestamp is a hard break: it does
    /// not close the previous turn (chip stays hidden) and does not open a new
    /// timed turn — so durations never stretch across unstamped users.
    static func applyTurnDurations(to indexed: inout [IndexedMessage]) {
        lastDurationWalkISOParses = 0
        for i in indexed.indices {
            indexed[i].turnDurationSeconds = nil
        }
        walkTurns(in: &indexed, from: 0, seedOpenUser: nil)
    }

    /// After appending a page, close turns whose end user is on the new page:
    /// - boundary: last prior open user → first new user (mutates at most one
    ///   prior first-assistant row — the committed O(1) backfill)
    /// - within-page: consecutive new-page users
    /// Never clears durations already set on prior-only turns.
    private static func closeTurnsAfterAppend(priorCount: Int, indexed: inout [IndexedMessage]) {
        lastDurationWalkISOParses = 0
        guard priorCount < indexed.count else { return }

        // Seed with the last open prior user (if any). An unparseable user at
        // the seam breaks the chain (no boundary backfill).
        var seed: (index: Int, date: Date)?
        if priorCount > 0 {
            var i = priorCount - 1
            while i >= 0 {
                let row = indexed[i]
                if row.message.role == "user", !row.message.isSystem {
                    if let date = parseUserTimestamp(row.message.timestamp) {
                        seed = (i, date)
                    } else {
                        seed = nil
                    }
                    break
                }
                i -= 1
            }
        }
        walkTurns(in: &indexed, from: priorCount, seedOpenUser: seed)
    }

    /// Sequential turn walk from `from`..end. Optional `seedOpenUser` is a prior
    /// open user awaiting a closing timestamp on this range.
    private static func walkTurns(
        in indexed: inout [IndexedMessage],
        from: Int,
        seedOpenUser: (index: Int, date: Date)?
    ) {
        var openUser = seedOpenUser
        guard from < indexed.count else { return }
        for i in from..<indexed.count {
            let row = indexed[i]
            guard row.message.role == "user", !row.message.isSystem else { continue }
            guard let date = parseUserTimestamp(row.message.timestamp) else {
                // Hard break: do not close previous turn with a fake endpoint.
                openUser = nil
                continue
            }
            if let start = openUser {
                applyOneTurn(from: start, to: (i, date), onto: &indexed)
            }
            openUser = (i, date)
        }
    }

    private static func parseUserTimestamp(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        lastDurationWalkISOParses += 1
        return ReplayState.parseISO(raw)
    }

    private static func applyOneTurn(
        from start: (index: Int, date: Date),
        to end: (index: Int, date: Date),
        onto indexed: inout [IndexedMessage]
    ) {
        let delta = end.date.timeIntervalSince(start.date)
        guard delta > 0 else { return }
        let rangeStart = start.index + 1
        let rangeEnd = end.index
        guard rangeStart < rangeEnd else { return }
        if let firstAssistant = (rangeStart..<rangeEnd).first(where: {
            indexed[$0].message.role == "assistant" && !indexed[$0].message.isSystem
        }) {
            indexed[firstAssistant].turnDurationSeconds = delta
        }
    }
}

// MARK: - Duration chip formatting (row 30)

enum TurnDurationFormat {
    /// `<10s` → one decimal; `10–59s` → whole seconds; `≥60s` → `Nm Ns`. No call count.
    static func chip(_ seconds: Double) -> String {
        if seconds < 10 {
            return String(format: "%.1fs", seconds)
        }
        if seconds < 60 {
            return "\(Int(seconds.rounded()))s"
        }
        // Round once so minute/second buckets stay consistent at whole-minute edges
        // (e.g. 119.6s → "2m 0s", not "1m 0s").
        let total = Int(seconds.rounded())
        let mins = total / 60
        let secs = total % 60
        return "\(mins)m \(secs)s"
    }
}
