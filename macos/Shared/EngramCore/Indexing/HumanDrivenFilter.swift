import Foundation

/// Single source of truth for the "human-driven" default-visibility filter — the
/// sessions a human actually drove with substantive instructions. Used by every
/// default browse surface (app session list, Home, Timeline, menu-bar popover,
/// native web UI, MCP `list_sessions`). Keyword search is intentionally NOT
/// filtered, so single-shot sessions stay recall-able.
///
/// Tunable: change the two thresholds here (re-index-free) to retune visibility.
public enum HumanDrivenFilter {
    /// Sources whose user-message stream is reliable enough to extract
    /// instruction signals. For these sources, NULL instruction columns mean
    /// "not populated yet" rather than "unknown provider"; default visibility
    /// should not treat them as automatically human-driven.
    public static let instructionSignalSources = ["claude-code", "codex"]
    /// Minimum distinct human instructions to qualify as human-driven.
    public static let minInstructions = 2
    /// Minimum substantive human turns — the literal "dozen-plus user messages"
    /// rescue for long iterative threads that dedup below `minInstructions`.
    public static let minHumanTurns = 12

    /// SQL predicate (no leading `AND`, with surrounding parens) selecting
    /// human-driven sessions. NULL-tolerant only for sources that do not yet
    /// have instruction extraction; reliable sources must pass instruction,
    /// turn-count, legacy user-message, or premium gates.
    public static var sqlPredicate: String {
        sqlPredicate(alias: nil)
    }

    /// SQL predicate selecting human-driven sessions, optionally qualifying all
    /// session columns with a trusted SQL table alias.
    public static func sqlPredicate(alias: String) -> String {
        sqlPredicate(alias: Optional(alias))
    }

    private static func sqlPredicate(alias: String?) -> String {
        let reliableSources = instructionSignalSources.map { "'\($0)'" }.joined(separator: ", ")
        let agentRole = column("agent_role", alias: alias)
        let source = column("source", alias: alias)
        let instructionCount = column("instruction_count", alias: alias)
        let humanTurnCount = column("human_turn_count", alias: alias)
        let userMessageCount = column("user_message_count", alias: alias)
        let tier = column("tier", alias: alias)
        return "("
            + "\(agentRole) IS NULL AND ("
            + "(\(source) NOT IN (\(reliableSources)) AND \(instructionCount) IS NULL)"
            + " OR \(instructionCount) >= \(minInstructions)"
            + " OR \(humanTurnCount) >= \(minHumanTurns)"
            + " OR \(userMessageCount) >= \(minHumanTurns)"
            + " OR \(tier) = 'premium'))"
    }

    private static func column(_ name: String, alias: String?) -> String {
        guard let alias, !alias.isEmpty else { return name }
        precondition(alias.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }, "SQL alias must be a simple identifier")
        return "\(alias).\(name)"
    }
}
