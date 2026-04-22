import Foundation
import GRDB

struct MCPStatsRow: FetchableRecord, Decodable {
    let key: String
    let sessionCount: Int
    let messageCount: Int
    let userMessageCount: Int
    let assistantMessageCount: Int
    let toolMessageCount: Int
}

struct MCPProjectAliasRow: FetchableRecord, Decodable {
    let alias: String
    let canonical: String
}

final class MCPDatabase {
    private let queue: DatabaseQueue

    init(path: String) throws {
        var configuration = Configuration()
        configuration.readonly = true
        queue = try DatabaseQueue(path: path, configuration: configuration)
    }

    func stats(groupBy: String, since: String?, until: String?) throws -> OrderedJSONValue {
        let groupExpr: String
        switch groupBy {
        case "project":
            groupExpr = "COALESCE(project, '(unknown)')"
        case "day":
            groupExpr = "date(start_time, 'localtime')"
        case "week":
            groupExpr = "date(start_time, 'localtime', 'weekday 0', '-6 days')"
        default:
            groupExpr = "source"
        }

        var conditions = ["hidden_at IS NULL", "orphan_status IS NULL"]
        var arguments: [DatabaseValueConvertible] = []
        if let since {
            conditions.append("start_time >= ?")
            arguments.append(since)
        }
        if let until {
            conditions.append("start_time <= ?")
            arguments.append(until)
        }

        let sql = """
        SELECT \(groupExpr) AS key,
               COUNT(*) AS sessionCount,
               SUM(message_count) AS messageCount,
               SUM(CASE WHEN tier IS NOT NULL AND tier IN ('skip', 'lite') THEN 0 ELSE user_message_count END) AS userMessageCount,
               SUM(assistant_message_count) AS assistantMessageCount,
               SUM(tool_message_count) AS toolMessageCount
        FROM sessions
        WHERE \(conditions.joined(separator: " AND "))
        GROUP BY \(groupExpr)
        ORDER BY sessionCount DESC
        """

        let rows = try queue.read { db in
            try MCPStatsRow.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        }
        let totalSessions = rows.reduce(0) { $0 + $1.sessionCount }

        return .object([
            ("groupBy", .string(groupBy)),
            ("groups", .array(rows.map { row in
                .object([
                    ("key", .string(row.key)),
                    ("sessionCount", .int(row.sessionCount)),
                    ("messageCount", .int(row.messageCount)),
                    ("userMessageCount", .int(row.userMessageCount)),
                    ("assistantMessageCount", .int(row.assistantMessageCount)),
                    ("toolMessageCount", .int(row.toolMessageCount)),
                ])
            })),
            ("totalSessions", .int(totalSessions)),
        ])
    }

    func listProjectAliases() throws -> OrderedJSONValue {
        let rows = try queue.read { db in
            try MCPProjectAliasRow.fetchAll(
                db,
                sql: "SELECT alias, canonical FROM project_aliases ORDER BY canonical, alias"
            )
        }
        return .array(rows.map { row in
            .object([
                ("alias", .string(row.alias)),
                ("canonical", .string(row.canonical)),
            ])
        })
    }
}
