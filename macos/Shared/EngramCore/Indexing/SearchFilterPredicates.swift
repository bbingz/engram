import Foundation

/// Shared, transport-agnostic SQL predicates for session search filters.
///
/// Callers keep ownership of database access, DTOs, and project-alias lookup.
/// `projects` therefore accepts canonical and caller-expanded alias values, but
/// always matches those values exactly; this helper never introduces `LIKE`.
public enum SearchFilterPredicates {
    public struct Clause: Equatable, Sendable {
        public let sql: String
        public let bindings: [String]
    }

    /// Builds the common source/project/origin/activity-time clauses in binding order.
    /// Empty or whitespace-only values are ignored and exact values are
    /// de-duplicated deterministically.
    public static func clauses(
        sources: [String] = [],
        projects: [String] = [],
        origin: String? = nil,
        since: String? = nil,
        alias: String = "s"
    ) -> [Clause] {
        var clauses: [Clause] = []

        if let source = exactClause(
            column: column("source", alias: alias),
            values: sources
        ) {
            clauses.append(source)
        }
        if let project = exactClause(
            column: column("project", alias: alias),
            values: projects
        ) {
            clauses.append(project)
        }
        if let origin = normalized(origin) {
            let originColumn = column("origin", alias: alias)
            clauses.append(
                origin == "local"
                    ? Clause(
                        sql: "(\(originColumn) IS NULL OR \(originColumn) != ?)",
                        bindings: ["hq"]
                    )
                    : Clause(sql: "\(originColumn) = ?", bindings: [origin])
            )
        }
        if let since = normalized(since) {
            clauses.append(
                Clause(
                    sql: "\(activityTimeSQL(alias: alias)) >= ?",
                    bindings: [since]
                )
            )
        }

        return clauses
    }

    public static func activityTimeSQL(alias: String = "s") -> String {
        let endTime = column("end_time", alias: alias)
        let startTime = column("start_time", alias: alias)
        return "COALESCE(NULLIF(\(endTime), ''), \(startTime))"
    }

    private static func exactClause(column: String, values: [String]) -> Clause? {
        let values = Array(Set(values.compactMap(normalized))).sorted()
        guard !values.isEmpty else { return nil }

        if values.count == 1 {
            return Clause(sql: "\(column) = ?", bindings: values)
        }
        let placeholders = Array(repeating: "?", count: values.count).joined(separator: ", ")
        return Clause(sql: "\(column) IN (\(placeholders))", bindings: values)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func column(_ name: String, alias: String) -> String {
        precondition(
            !alias.isEmpty && alias.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" },
            "SQL alias must be a simple identifier"
        )
        return "\(alias).\(name)"
    }
}
