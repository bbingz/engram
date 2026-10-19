// macos/Engram/Models/TranscriptBlock.swift
import Foundation

/// One rendered unit of the session-view transcript. Runs of consecutive
/// tool-ish rows (tool call / tool result / generic tool) collapse into a single
/// `.toolRun` block — the agent-sessions "N tool calls" pattern — so a busy
/// turn reads as one line instead of dozens. Errors stay standalone (red rows
/// must remain scannable) and single tool rows render unchanged.
enum TranscriptBlock: Identifiable, Equatable {
    case message(IndexedMessage)
    case toolRun([IndexedMessage])

    var id: UUID {
        switch self {
        case .message(let indexed): return indexed.id
        case .toolRun(let rows): return rows[0].id
        }
    }

    /// Identity-based equality — `IndexedMessage` is not Equatable, and blocks
    /// are equal when they render the same message sequence.
    static func == (lhs: TranscriptBlock, rhs: TranscriptBlock) -> Bool {
        switch (lhs, rhs) {
        case (.message(let a), .message(let b)):
            return a.id == b.id
        case (.toolRun(let a), .toolRun(let b)):
            return a.map(\.id) == b.map(\.id)
        default:
            return false
        }
    }
}

/// Pure emission-time grouping: `displayIndexed` (the filtered flat list) stays
/// the canonical row space — find indices, match counts, and type chips all
/// key on it — and blocks are only a rendering projection of it.
enum TranscriptBlockGrouper {
    static let collapsibleTypes: Set<MessageType> = [.tool, .toolCall, .toolResult]

    /// Merge runs of ≥2 consecutive collapsible rows; a run of length 1 and
    /// every non-collapsible row pass through as `.message`.
    static func group(_ visible: [IndexedMessage]) -> [TranscriptBlock] {
        var blocks: [TranscriptBlock] = []
        var run: [IndexedMessage] = []

        func flushRun() {
            if run.count >= 2 {
                blocks.append(.toolRun(run))
            } else {
                blocks.append(contentsOf: run.map(TranscriptBlock.message))
            }
            run = []
        }

        for indexed in visible {
            if collapsibleTypes.contains(indexed.messageType) {
                run.append(indexed)
            } else {
                flushRun()
                blocks.append(.message(indexed))
            }
        }
        flushRun()
        return blocks
    }

    /// Id of the collapsed tool run containing `messageId`, if any. Used by
    /// find navigation to expand the run before scrolling to a match inside it.
    static func toolRunId(containing messageId: UUID, in blocks: [TranscriptBlock]) -> UUID? {
        for case .toolRun(let rows) in blocks where rows.contains(where: { $0.id == messageId }) {
            return rows[0].id
        }
        return nil
    }
}