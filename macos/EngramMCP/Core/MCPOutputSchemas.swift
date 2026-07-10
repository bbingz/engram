import Foundation

/// JSON Schema declarations for MCP `structuredContent` on read tools.
/// Derived from actual emission sites (MCPDatabase / transcript / file / insights tools).
enum MCPOutputSchemas {
    static let coveredToolNames: Set<String> = [
        "list_sessions", "stats", "get_costs", "tool_analytics", "file_activity",
        "project_timeline", "project_list_migrations", "live_sessions", "get_memory",
        "search", "get_insights", "project_review", "get_session", "handoff", "project_recover",
    ]

    private static let listSessionItem =
        #"{"type":"object","additionalProperties":false,"required":["id","source","startTime","endTime","cwd","project","model","messageCount","userMessageCount","summary"],"properties":{"id":{"type":"string"},"source":{"type":"string"},"startTime":{"type":"string"},"endTime":{"type":"string"},"cwd":{"type":"string"},"project":{"type":["string","null"]},"model":{"type":["string","null"]},"messageCount":{"type":"integer"},"userMessageCount":{"type":"integer"},"summary":{"type":["string","null"]}}}"#

    private static let fullSession =
        #"{"type":"object","additionalProperties":false,"required":["id","source","startTime","endTime","cwd","project","model","messageCount","userMessageCount","assistantMessageCount","toolMessageCount","systemMessageCount","summary","filePath","sizeBytes","indexedAt","agentRole","origin","summaryMessageCount","tier","qualityScore","parentSessionId","suggestedParentId"],"properties":{"id":{"type":"string"},"source":{"type":"string"},"startTime":{"type":"string"},"endTime":{"type":["string","null"]},"cwd":{"type":"string"},"project":{"type":["string","null"]},"model":{"type":["string","null"]},"messageCount":{"type":"integer"},"userMessageCount":{"type":"integer"},"assistantMessageCount":{"type":"integer"},"toolMessageCount":{"type":"integer"},"systemMessageCount":{"type":"integer"},"summary":{"type":["string","null"]},"filePath":{"type":"string"},"sizeBytes":{"type":"integer"},"indexedAt":{"type":["string","null"]},"agentRole":{"type":["string","null"]},"origin":{"type":["string","null"]},"summaryMessageCount":{"type":["integer","null"]},"tier":{"type":["string","null"]},"qualityScore":{"type":["integer","null"]},"parentSessionId":{"type":["string","null"]},"suggestedParentId":{"type":["string","null"]}}}"#

    private static let memoryItem =
        #"{"type":"object","additionalProperties":false,"required":["id","content","wing","room","importance","distance","type"],"properties":{"id":{"type":"string"},"content":{"type":"string"},"wing":{"type":["string","null"]},"room":{"type":["string","null"]},"importance":{"type":"integer"},"distance":{"type":"number"},"type":{"type":"string"}}}"#

    static let listSessions = j(
        #"{"type":"object","additionalProperties":false,"required":["sessions","total"],"properties":{"sessions":{"type":"array","items":\#(listSessionItem)},"total":{"type":"integer"}}}"#
    )

    static let stats = j(
        #"{"type":"object","additionalProperties":false,"required":["groupBy","groups","indexJobs","totalSessions"],"properties":{"groupBy":{"type":"string"},"totalSessions":{"type":"integer"},"groups":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["key","sessionCount","messageCount","userMessageCount","assistantMessageCount","toolMessageCount"],"properties":{"key":{"type":"string"},"sessionCount":{"type":"integer"},"messageCount":{"type":"integer"},"userMessageCount":{"type":"integer"},"assistantMessageCount":{"type":"integer"},"toolMessageCount":{"type":"integer"}}}},"indexJobs":{"type":"object","additionalProperties":false,"required":["pending","running","failed_retryable","failed_permanent","failed_terminal","failed","completed","not_applicable"],"properties":{"pending":{"type":"integer"},"running":{"type":"integer"},"failed_retryable":{"type":"integer"},"failed_permanent":{"type":"integer"},"failed_terminal":{"type":"integer"},"failed":{"type":"integer"},"completed":{"type":"integer"},"not_applicable":{"type":"integer"}}}}}"#
    )

    static let getCosts = j(
        #"{"type":"object","additionalProperties":false,"required":["totalCostUsd","totalInputTokens","totalOutputTokens","breakdown"],"properties":{"totalCostUsd":{"type":"number"},"totalInputTokens":{"type":"integer"},"totalOutputTokens":{"type":"integer"},"breakdown":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["key","inputTokens","outputTokens","cacheReadTokens","cacheCreationTokens","costUsd","sessionCount"],"properties":{"key":{"type":["string","null"]},"inputTokens":{"type":"integer"},"outputTokens":{"type":"integer"},"cacheReadTokens":{"type":"integer"},"cacheCreationTokens":{"type":"integer"},"costUsd":{"type":"number"},"sessionCount":{"type":"integer"}}}}}}"#
    )

    static let toolAnalytics = j(
        #"{"type":"object","additionalProperties":false,"required":["tools","totalCalls","groupCount"],"properties":{"totalCalls":{"type":"integer"},"groupCount":{"type":"integer"},"tools":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["key","callCount"],"properties":{"key":{"type":["string","null"]},"callCount":{"type":"integer"},"sessionCount":{"type":"integer"},"toolCount":{"type":"integer"},"label":{"type":["string","null"]}}}}}}"#
    )

    static let fileActivity = j(
        #"{"type":"object","additionalProperties":false,"required":["files","totalFiles"],"properties":{"totalFiles":{"type":"integer"},"files":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["file_path","action","total_count","session_count"],"properties":{"file_path":{"type":"string"},"action":{"type":"string"},"total_count":{"type":"integer"},"session_count":{"type":"integer"}}}}}}"#
    )

    static let projectTimeline = j(
        #"{"type":"object","additionalProperties":false,"required":["project","timeline","total"],"properties":{"project":{"type":"string"},"total":{"type":"integer"},"timeline":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["time","source","summary","sessionId","messageCount"],"properties":{"time":{"type":"string"},"source":{"type":"string"},"summary":{"type":"string"},"sessionId":{"type":"string"},"messageCount":{"type":"integer"}}}}}}"#
    )

    static let projectListMigrations = j(
        #"{"type":"array","items":{"type":"object","additionalProperties":false,"required":["id","oldPath","newPath","oldBasename","newBasename","state","filesPatched","occurrences","sessionsUpdated","aliasCreated","ccDirRenamed","startedAt","finishedAt","dryRun","rolledBackOf","auditNote","archived","actor","detail","error"],"properties":{"id":{"type":"string"},"oldPath":{"type":"string"},"newPath":{"type":"string"},"oldBasename":{"type":"string"},"newBasename":{"type":"string"},"state":{"type":"string"},"filesPatched":{"type":"integer"},"occurrences":{"type":"integer"},"sessionsUpdated":{"type":"integer"},"aliasCreated":{"type":"boolean"},"ccDirRenamed":{"type":"boolean"},"startedAt":{"type":"string"},"finishedAt":{"type":["string","null"]},"dryRun":{"type":"boolean"},"rolledBackOf":{"type":["string","null"]},"auditNote":{"type":["string","null"]},"archived":{"type":"boolean"},"actor":{"type":"string"},"detail":{"type":["object","null"],"additionalProperties":true},"error":{"type":["string","null"]}}}}"#
    )

    static let liveSessions = j(
        #"{"type":"object","additionalProperties":false,"required":["sessions","count","note"],"properties":{"sessions":{"type":"array","items":{"type":"object","additionalProperties":true}},"count":{"type":"integer"},"note":{"type":"string"}}}"#
    )

    static let getMemory = j(
        #"{"type":"object","additionalProperties":false,"required":["memories"],"properties":{"memories":{"type":"array","items":\#(memoryItem)},"type":{"type":"string"},"warning":{"type":"string"},"message":{"type":"string"},"retrieval":{"type":"string"}}}"#
    )

    static let search = j(
        #"{"type":"object","additionalProperties":false,"required":["results","query","searchModes"],"properties":{"query":{"type":"string"},"searchModes":{"type":"array","items":{"type":"string"}},"warning":{"type":"string"},"insightResults":{"type":"array","items":{"type":"string"}},"results":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["session","snippet","matchType","score"],"properties":{"session":\#(fullSession),"snippet":{"type":"string"},"matchType":{"type":"string"},"score":{"type":"number"}}}}}}"#
    )

    static let getInsights = j(
        #"{"type":"object","additionalProperties":false,"required":["content"],"properties":{"content":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["type","text"],"properties":{"type":{"type":"string"},"text":{"type":"string"}}}}}}"#
    )

    static let projectReview = j(
        #"{"type":"object","additionalProperties":false,"required":["own","other"],"properties":{"own":{"type":"array","items":{"type":"string"}},"other":{"type":"array","items":{"type":"string"}},"truncated":{"type":"object","additionalProperties":false,"required":["own","other"],"properties":{"own":{"type":"integer"},"other":{"type":"integer"}}}}}"#
    )

    static let getSession = j(
        #"{"type":"object","additionalProperties":false,"required":["session","messages","totalPages","currentPage","redacted"],"properties":{"session":\#(fullSession),"totalPages":{"type":"integer"},"currentPage":{"type":"integer"},"redacted":{"type":"boolean"},"totalKnownComplete":{"type":"boolean"},"truncated":{"type":"boolean"},"truncatedAt":{"type":"integer"},"messages":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["role","content"],"properties":{"role":{"type":"string"},"content":{"type":"string"},"timestamp":{"type":"string"}}}}}}"#
    )

    static let handoff = j(
        #"{"type":"object","additionalProperties":false,"required":["brief","sessionCount"],"properties":{"brief":{"type":"string"},"sessionCount":{"type":"integer"}}}"#
    )

    static let projectRecover = j(
        #"{"type":"array","items":{"type":"object","additionalProperties":false,"required":["migrationId","state","oldPath","newPath","startedAt","finishedAt","error","fs","recommendation"],"properties":{"migrationId":{"type":"string"},"state":{"type":"string"},"oldPath":{"type":"string"},"newPath":{"type":"string"},"startedAt":{"type":"string"},"finishedAt":{"type":["string","null"]},"error":{"type":["string","null"]},"recommendation":{"type":"string"},"fs":{"type":"object","additionalProperties":false,"required":["oldPathExists","newPathExists","oldPathState","newPathState","tempArtifacts","probeError"],"properties":{"oldPathExists":{"type":"boolean"},"newPathExists":{"type":"boolean"},"oldPathState":{"type":"string"},"newPathState":{"type":"string"},"tempArtifacts":{"type":"array","items":{"type":"string"}},"probeError":{"type":["string","null"]}}}}}}"#
    )

    static func schema(for toolName: String) -> JSONValue? {
        switch toolName {
        case "list_sessions": return listSessions
        case "stats": return stats
        case "get_costs": return getCosts
        case "tool_analytics": return toolAnalytics
        case "file_activity": return fileActivity
        case "project_timeline": return projectTimeline
        case "project_list_migrations": return projectListMigrations
        case "live_sessions": return liveSessions
        case "get_memory": return getMemory
        case "search": return search
        case "get_insights": return getInsights
        case "project_review": return projectReview
        case "get_session": return getSession
        case "handoff": return handoff
        case "project_recover": return projectRecover
        default: return nil
        }
    }

    private static func j(_ raw: String) -> JSONValue {
        do {
            return try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
        } catch {
            preconditionFailure("MCPOutputSchemas invalid JSON: \(error)")
        }
    }
}
