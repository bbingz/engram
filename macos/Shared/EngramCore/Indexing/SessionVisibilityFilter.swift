import Foundation

/// Shared SQL fragments for list/aggregate session visibility across app
/// (`DatabaseManager`), service reads, and MCP.
///
/// Searchable FTS/vector tiers live in `SessionSemanticSearchPolicy`
/// (`skip` + `lite` excluded). List/KPI surfaces keep `lite` visible and only
/// hide `skip` noise — use the helpers here so those predicates cannot drift.
public enum SessionVisibilityFilter {
    /// Browseable / aggregate sessions: hide skip-tier noise only.
    /// Bare-column form for queries without a sessions alias.
    public static let nonSkipTierSQL = "(tier IS NULL OR tier != 'skip')"

    /// Same as `nonSkipTierSQL` with a table alias (`s.tier`, …).
    public static func nonSkipTierSQL(alias: String) -> String {
        let tier = column("tier", alias: alias)
        return "(\(tier) IS NULL OR \(tier) != 'skip')"
    }

    /// Hidden sessions are never listed on default surfaces.
    public static let notHiddenSQL = "hidden_at IS NULL"

    public static func notHiddenSQL(alias: String) -> String {
        "\(column("hidden_at", alias: alias)) IS NULL"
    }

    /// Default aggregate visibility: not hidden and not skip-tier.
    public static let listVisibleSQL =
        "\(notHiddenSQL) AND \(nonSkipTierSQL)"

    public static func listVisibleSQL(alias: String) -> String {
        "\(notHiddenSQL(alias: alias)) AND \(nonSkipTierSQL(alias: alias))"
    }

    private static func column(_ name: String, alias: String) -> String {
        precondition(
            alias.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" },
            "SQL alias must be a simple identifier"
        )
        return "\(alias).\(name)"
    }
}
