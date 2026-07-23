import Foundation

struct MCPToolDefinition {
    let name: String
    let description: String
    let inputSchema: JSONValue
    /// Present only for read tools that emit `structuredContent` (MCP `outputSchema`).
    let outputSchema: JSONValue?

    init(
        name: String,
        description: String,
        inputSchema: JSONValue,
        outputSchema: JSONValue? = nil
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
    }

    var jsonValue: JSONValue {
        var object: [String: JSONValue] = [
            "name": .string(name),
            "description": .string(description),
            "inputSchema": inputSchema,
        ]
        if let outputSchema {
            object["outputSchema"] = outputSchema
        }
        return .object(object)
    }

    var orderedJSONValue: OrderedJSONValue {
        var entries: [(String, OrderedJSONValue)] = [
            ("name", .string(name)),
            ("title", .string(MCPToolRegistry.humanTitle(for: name))),
            ("description", .string(description)),
            ("inputSchema", OrderedJSONValue(inputSchema)),
        ]
        if let outputSchema {
            entries.append(("outputSchema", OrderedJSONValue(outputSchema)))
        }
        entries.append(("annotations", MCPToolRegistry.toolAnnotations(for: name)))
        return .object(entries)
    }
}

enum MCPToolRegistry {
    enum ToolCategory: String {
        case readOnly
        case mutating
        case operational
        case longRunningRead

        var requiresServiceSocket: Bool {
            switch self {
            case .readOnly:
                return false
            case .mutating, .operational, .longRunningRead:
                return true
            }
        }
    }

    /// Reserved hook for tools that need to be filtered out of `tools/list`
    /// without removing their schema. Empty since Stage 4 wired the four
    /// project_* commands through to the Swift pipeline.
    private static let unavailableNativeProjectOperationTools: Set<String> = []

    /// Default tools list (probes the process MCP DB path for search modes).
    static var tools: [MCPToolDefinition] {
        tools(dbPath: MCPConfig.load().dbPath)
    }

    /// tools/list + argument validation surface. Search `mode` enum is gated by
    /// `SessionVectorSearchAvailability` on the given database path.
    static func tools(dbPath: String) -> [MCPToolDefinition] {
        let semanticUsable = SessionVectorSearchAvailability.probe(databasePath: dbPath).isUsable
        return allToolDefinitions.compactMap { definition in
            guard !unavailableNativeProjectOperationTools.contains(definition.name) else {
                return nil
            }
            if definition.name == "search" {
                return searchToolDefinition(semanticModesAvailable: semanticUsable)
            }
            return definition
        }
    }

    private static func searchToolDefinition(semanticModesAvailable: Bool) -> MCPToolDefinition {
        let modeEnum: JSONValue
        let modeDescription: String
        let toolDescription: String
        if semanticModesAvailable {
            modeEnum = .array([
                .string("keyword"),
                .string("semantic"),
                .string("hybrid"),
            ])
            modeDescription =
                "Search mode: keyword (FTS), semantic (embedding KNN), or hybrid (RRF fusion of both)"
            toolDescription =
                "Full-text and semantic search across session content. Semantic and hybrid modes require usable session embeddings."
        } else {
            modeEnum = .array([.string("keyword")])
            modeDescription =
                "Search mode (keyword only; semantic/hybrid require usable session embeddings in embedding_meta)"
            toolDescription =
                "Full-text keyword search across all session content. Supports Chinese and English."
        }
        return MCPToolDefinition(
            name: "search",
            description: toolDescription,
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("query")]),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Search keywords; queries shorter than 3 characters use LIKE fallback"),
                    ]),
                    "source": .object([
                        "type": .string("string"),
                        "enum": sourceSchemaEnum,
                    ]),
                    "project": .object([
                        "type": .string("string"),
                        "description": .string("Filter by exact project name or alias"),
                    ]),
                    "since": .object([
                        "type": .string("string"),
                        "description": .string("Activity-time lower bound using end time when present, otherwise start time (ISO 8601)"),
                    ]),
                    "limit": .object([
                        "type": .string("number"),
                        "description": .string("Default 10, max 50"),
                    ]),
                    "mode": .object([
                        "type": .string("string"),
                        "enum": modeEnum,
                        "description": .string(modeDescription),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ]),
            outputSchema: MCPOutputSchemas.search
        )
    }

    private static let sourceSchemaEnum: JSONValue = .array(SourceName.allCases.map { .string($0.rawValue) })
    private static let minContextTokens = 1
    private static let maxContextTokens = 32_000
    private static let maxSessionPage = 100_000

    private static let allToolDefinitions: [MCPToolDefinition] = [
        MCPToolDefinition(
            name: "list_sessions",
            description: "列出 AI 编程助手的历史会话。默认只返回有明确人类指令的会话；支持按工具来源、项目、时间范围过滤。",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "source": .object([
                        "type": .string("string"),
                        "enum": sourceSchemaEnum,
                        "description": .string("过滤特定工具的会话"),
                    ]),
                    "project": .object([
                        "type": .string("string"),
                        "description": .string("按精确项目名或别名过滤"),
                    ]),
                    "since": .object([
                        "type": .string("string"),
                        "description": .string("开始时间（ISO 8601）"),
                    ]),
                    "until": .object([
                        "type": .string("string"),
                        "description": .string("结束时间（ISO 8601）"),
                    ]),
                    "limit": .object([
                        "type": .string("number"),
                        "description": .string("最多返回条数，默认 20，最大 100"),
                    ]),
                    "offset": .object([
                        "type": .string("number"),
                        "description": .string("分页偏移量"),
                    ]),
                    "include_all": .object([
                        "type": .string("boolean"),
                        "description": .string("包含单发/自动化会话，而不仅是人类驱动的会话（默认 false）"),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ]),
            outputSchema: MCPOutputSchemas.listSessions
        ),
        MCPToolDefinition(
            name: "stats",
            description: "统计各工具的会话数量、消息数等用量数据。",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "since": .object(["type": .string("string")]),
                    "until": .object(["type": .string("string")]),
                    "group_by": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("source"),
                            .string("project"),
                            .string("day"),
                            .string("week"),
                        ]),
                        "description": .string("按维度分组，默认 source"),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ]),
            outputSchema: MCPOutputSchemas.stats
        ),
        MCPToolDefinition(
            name: "get_costs",
            description: "Get token usage costs across sessions, grouped by model, source, project, or day.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "group_by": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("model"),
                            .string("source"),
                            .string("project"),
                            .string("day"),
                        ]),
                        "description": .string("Group dimension (default: model)"),
                    ]),
                    "since": .object([
                        "type": .string("string"),
                        "description": .string("Start time (ISO 8601)"),
                    ]),
                    "until": .object([
                        "type": .string("string"),
                        "description": .string("End time (ISO 8601)"),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ]),
            outputSchema: MCPOutputSchemas.getCosts
        ),
        MCPToolDefinition(
            name: "tool_analytics",
            description: "Analyze which tools (Read, Edit, Bash, etc.) are used most across sessions.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "project": .object([
                        "type": .string("string"),
                        "description": .string("Filter by project name (partial match)"),
                    ]),
                    "since": .object([
                        "type": .string("string"),
                        "description": .string("Start time (ISO 8601)"),
                    ]),
                    "group_by": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("tool"),
                            .string("session"),
                            .string("project"),
                        ]),
                        "description": .string("Group dimension (default: tool)"),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ]),
            outputSchema: MCPOutputSchemas.toolAnalytics
        ),
        MCPToolDefinition(
            name: "file_activity",
            description: "Show most frequently edited/read files across sessions for a project. Helps understand project activity patterns.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "project": .object([
                        "type": .string("string"),
                        "description": .string("Filter by project name"),
                    ]),
                    "since": .object([
                        "type": .string("string"),
                        "description": .string("ISO 8601 date filter"),
                    ]),
                    "limit": .object([
                        "type": .string("number"),
                        "description": .string("Max results (default 50)"),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ]),
            outputSchema: MCPOutputSchemas.fileActivity
        ),
        MCPToolDefinition(
            name: "project_timeline",
            description: "查看某个项目跨工具的操作时间线，了解在不同 AI 助手里分别做了什么。",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("project")]),
                "properties": .object([
                    "project": .object([
                        "type": .string("string"),
                        "description": .string("项目名或路径片段"),
                    ]),
                    "since": .object(["type": .string("string")]),
                    "until": .object(["type": .string("string")]),
                ]),
                "additionalProperties": .bool(false),
            ]),
            outputSchema: MCPOutputSchemas.projectTimeline
        ),
        MCPToolDefinition(
            name: "project_list_migrations",
            description: "List recent project-move migrations with state, paths, counts, and timestamps. Used to find a migration_id for undo/recover, or to build the daily audit table.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "limit": .object([
                        "type": .string("number"),
                        "default": .int(20),
                    ]),
                    "since": .object([
                        "type": .string("string"),
                        "description": .string("ISO timestamp — only rows started after this"),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ]),
            outputSchema: MCPOutputSchemas.projectListMigrations
        ),
        MCPToolDefinition(
            name: "live_sessions",
            description: "Live session monitoring is not available in MCP mode; returns an explicit unavailable result.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "additionalProperties": .bool(false),
            ]),
            outputSchema: MCPOutputSchemas.liveSessions
        ),
        MCPToolDefinition(
            name: "get_memory",
            description: "Retrieve curated insights and memories from past sessions. Use save_insight to add new memories.",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("query")]),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("What to remember (e.g. \"user's coding preferences\")"),
                    ]),
                    "type": .object([
                        "type": .string("string"),
                        "description": .string("Optional memory type filter: episodic, semantic, or procedural"),
                        "enum": .array([.string("episodic"), .string("semantic"), .string("procedural")]),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ]),
            outputSchema: MCPOutputSchemas.getMemory
        ),
        // Placeholder replaced by `searchToolDefinition` in `tools(dbPath:)`.
        MCPToolDefinition(
            name: "search",
            description: "Full-text keyword search across all session content. Supports Chinese and English.",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("query")]),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Search keywords; queries shorter than 3 characters use LIKE fallback"),
                    ]),
                    "source": .object([
                        "type": .string("string"),
                        "enum": sourceSchemaEnum,
                    ]),
                    "project": .object([
                        "type": .string("string"),
                        "description": .string("Filter by exact project name or alias"),
                    ]),
                    "since": .object([
                        "type": .string("string"),
                        "description": .string("Activity-time lower bound using end time when present, otherwise start time (ISO 8601)"),
                    ]),
                    "limit": .object([
                        "type": .string("number"),
                        "description": .string("Default 10, max 50"),
                    ]),
                    "mode": .object([
                        "type": .string("string"),
                        "enum": .array([.string("keyword")]),
                        "description": .string("Search mode (keyword only)"),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ]),
            outputSchema: MCPOutputSchemas.search
        ),
        MCPToolDefinition(
            name: "get_context",
            description: "为当前工作目录自动提取相关的历史会话上下文。在开始新任务时调用，获取该项目的历史记录。",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("cwd")]),
                "properties": .object([
                    "cwd": .object([
                        "type": .string("string"),
                        "description": .string("当前工作目录（绝对路径）"),
                    ]),
                    "task": .object([
                        "type": .string("string"),
                        "description": .string("当前任务描述（可选，用于相关上下文检索）"),
                    ]),
                    "max_tokens": .object([
                        "type": .string("number"),
                        "minimum": .int(minContextTokens),
                        "maximum": .int(maxContextTokens),
                        "description": .string("token 预算，默认 4000（约 16000 字符）"),
                    ]),
                    "detail": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("abstract"),
                            .string("overview"),
                            .string("full"),
                        ]),
                        "description": .string("详情级别: abstract (~100 tokens, cost+alerts only), overview (~2K tokens), full (default)"),
                    ]),
                    "sort_by": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("recency"),
                            .string("score"),
                        ]),
                        "description": .string("排序方式: recency (默认按时间倒序) 或 score (按质量分数倒序)"),
                    ]),
                    "include_environment": .object([
                        "type": .string("boolean"),
                        "description": .string("包含实时环境数据（活跃会话、今日成本、工具使用、告警），默认 true"),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ])
        ),
        MCPToolDefinition(
            name: "get_insights",
            description: "Report cost totals, projection, and high-confidence spend-distribution suggestions.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "since": .object([
                        "type": .string("string"),
                        "description": .string("ISO timestamp for start of analysis window (default: 7 days ago)"),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ]),
            outputSchema: MCPOutputSchemas.getInsights
        ),
        MCPToolDefinition(
            name: "link_sessions",
            description: "Create symlinks to all AI session files for a project in <targetDir>/conversation_log/<source>/",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("targetDir")]),
                "properties": .object([
                    "targetDir": .object([
                        "type": .string("string"),
                        "description": .string("Project directory (absolute path). Project name is derived from basename."),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ])
        ),
        MCPToolDefinition(
            name: "project_review",
            description: "Scan all \(MCPFileTools.projectReviewSourceRootCount) AI session roots for residual references to an old project path. Classifies hits into `own` (in the migrated project's own spaces — real leftovers) vs `other` (historical mentions in unrelated conversations — left alone by design).",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("old_path"), .string("new_path")]),
                "properties": .object([
                    "old_path": .object([
                        "type": .string("string"),
                        "description": .string("Absolute old path"),
                    ]),
                    "new_path": .object([
                        "type": .string("string"),
                        "description": .string("Absolute new path (used to identify own-scope CC dir)"),
                    ]),
                    "max_items": .object([
                        "type": .string("number"),
                        "description": .string("Cap own/other arrays (default 100). Response includes `truncated` if applied."),
                        "default": .int(100),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ]),
            outputSchema: MCPOutputSchemas.projectReview
        ),
        MCPToolDefinition(
            name: "get_session",
            description: "读取单个会话的完整对话内容。大会话支持分页（每页 50 条消息）。默认只返回 user/assistant 可见消息，并对消息内容做敏感信息脱敏；include_raw=true 可选择返回未脱敏原文（仅本地）。",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("id")]),
                "properties": .object([
                    "id": .object([
                        "type": .string("string"),
                        "description": .string("会话 ID"),
                    ]),
                    "page": .object([
                        "type": .string("number"),
                        "minimum": .int(1),
                        "maximum": .int(maxSessionPage),
                        "description": .string("页码，从 1 开始，默认 1"),
                    ]),
                    "roles": .object([
                        "type": .string("array"),
                        "items": .object([
                            "type": .string("string"),
                            "enum": .array([
                                .string("user"),
                                .string("assistant"),
                            ]),
                        ]),
                        "description": .string("Only return messages for these roles. Enum: user, assistant. Default (omit or empty): visible user/assistant messages only — never tool or system roles."),
                    ]),
                    "include_raw": .object([
                        "type": .string("boolean"),
                        "description": .string("When true, return unredacted message content (local-only opt-in). Default false: secrets redacted with the same policy as export."),
                        "default": .bool(false),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ]),
            outputSchema: MCPOutputSchemas.getSession
        ),
        MCPToolDefinition(
            name: "export",
            description: "将单个会话导出为 Markdown 或 JSON 文件，保存到 ~/.engram/exports/ 目录。",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("id")]),
                "properties": .object([
                    "id": .object([
                        "type": .string("string"),
                        "description": .string("会话 ID"),
                    ]),
                    "format": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("markdown"),
                            .string("json"),
                        ]),
                        "description": .string("默认 markdown"),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ])
        ),
        MCPToolDefinition(
            name: "handoff",
            description: "Generate a handoff brief for a project — summarizes recent sessions to help resume work.",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("cwd")]),
                "properties": .object([
                    "cwd": .object([
                        "type": .string("string"),
                        "description": .string("Project directory (absolute path)"),
                    ]),
                    "sessionId": .object([
                        "type": .string("string"),
                        "description": .string("Specific session to handoff (optional)"),
                    ]),
                    "format": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("markdown"),
                            .string("plain"),
                        ]),
                        "description": .string("Output format (default: markdown)"),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ]),
            outputSchema: MCPOutputSchemas.handoff
        ),
        MCPToolDefinition(
            name: "generate_summary",
            description: "Generate an AI summary for a conversation session",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("sessionId")]),
                "properties": .object([
                    "sessionId": .object([
                        "type": .string("string"),
                        "description": .string("The session ID to summarize"),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ])
        ),
        MCPToolDefinition(
            name: "save_insight",
            description: "Save an important insight, decision, or lesson learned for future retrieval. Use this to preserve knowledge that should persist across sessions.",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("content")]),
                "properties": .object([
                    "content": .object([
                        "type": .string("string"),
                        "description": .string("The insight or knowledge to save"),
                    ]),
                    "wing": .object([
                        "type": .string("string"),
                        "description": .string("Project or domain name (optional)"),
                    ]),
                    "room": .object([
                        "type": .string("string"),
                        "description": .string("Sub-area within the project (optional)"),
                    ]),
                    "importance": .object([
                        "type": .string("number"),
                        "description": .string("Importance level 0-5 (default: 5)"),
                        "minimum": .int(0),
                        "maximum": .int(5),
                    ]),
                    "type": .object([
                        "type": .string("string"),
                        "description": .string("Memory type: semantic, episodic, or procedural (default: semantic)"),
                        "enum": .array([.string("semantic"), .string("episodic"), .string("procedural")]),
                    ]),
                    "source_session_id": .object([
                        "type": .string("string"),
                        "description": .string("Session ID that generated this insight (optional)"),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ])
        ),
        MCPToolDefinition(
            name: "delete_insight",
            description: "Delete a saved insight by id. Normal calls are routed through EngramService; dry_run only validates input.",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("id")]),
                "properties": .object([
                    "id": .object([
                        "type": .string("string"),
                        "description": .string("Insight id to delete"),
                    ]),
                    "dry_run": .object([
                        "type": .string("boolean"),
                        "description": .string("Validate and show intent without deleting"),
                        "default": .bool(false),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ])
        ),
        MCPToolDefinition(
            name: "hide_session",
            description: "Hide or unhide a session by id. Normal calls are routed through EngramService; dry_run only validates input.",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("session_id")]),
                "properties": .object([
                    "session_id": .object([
                        "type": .string("string"),
                        "description": .string("Session id to hide or unhide"),
                    ]),
                    "hidden": .object([
                        "type": .string("boolean"),
                        "description": .string("true hides the session; false restores it"),
                        "default": .bool(true),
                    ]),
                    "dry_run": .object([
                        "type": .string("boolean"),
                        "description": .string("Validate and show intent without changing the session"),
                        "default": .bool(false),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ])
        ),
        MCPToolDefinition(
            name: "project_move",
            description: "⚠️ Cannot run concurrently with other project_* tools; execute sequentially. Move a project directory and keep all AI session history reachable. Patches cwd references in Claude Code / Codex / Gemini / iFlow / OpenCode / Antigravity / Copilot session files, renames per-project directories for every source that groups by project (Claude Code encoded cwd, Gemini basename, iFlow encoded), syncs Gemini's projects.json, updates engram DB, and creates a project alias. Transactional with compensation on failure.",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("src"), .string("dst")]),
                "properties": .object([
                    "src": .object([
                        "type": .string("string"),
                        "description": .string("Absolute source path (e.g. /Users/bing/-Code-/MyProject). ~-prefix accepted."),
                    ]),
                    "dst": .object([
                        "type": .string("string"),
                        "description": .string("Absolute destination path (e.g. /Users/bing/-Code-/MyProject-v2). ~-prefix accepted."),
                    ]),
                    "dry_run": .object([
                        "type": .string("boolean"),
                        "description": .string("Plan only, no side effects"),
                        "default": .bool(false),
                    ]),
                    "force": .object([
                        "type": .string("boolean"),
                        "description": .string("Bypass git-dirty warning on source"),
                        "default": .bool(false),
                    ]),
                    "note": .object([
                        "type": .string("string"),
                        "description": .string("Audit note stored in migration_log"),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ])
        ),
        MCPToolDefinition(
            name: "project_archive",
            description: "⚠️ Cannot run concurrently with other project_* tools; execute sequentially. Archive a project by moving it under _archive/ with auto-suggested category.",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("src")]),
                "properties": .object([
                    "src": .object([
                        "type": .string("string"),
                        "description": .string("Absolute source path (e.g. /Users/bing/-Code-/OldScript). ~-prefix accepted."),
                    ]),
                    "to": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("历史脚本"),
                            .string("空项目"),
                            .string("归档完成"),
                            .string("historical-scripts"),
                            .string("empty-project"),
                            .string("archived-done"),
                        ]),
                        "description": .string("Force archive category (bypasses heuristic, required for ambiguous projects)."),
                    ]),
                    "dry_run": .object([
                        "type": .string("boolean"),
                        "description": .string("Plan only, returns suggested target without moving"),
                        "default": .bool(false),
                    ]),
                    "force": .object([
                        "type": .string("boolean"),
                        "description": .string("Bypass git-dirty warning"),
                        "default": .bool(false),
                    ]),
                    "note": .object([
                        "type": .string("string"),
                        "description": .string("Audit note stored in migration_log"),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ])
        ),
        MCPToolDefinition(
            name: "project_undo",
            description: "⚠️ Cannot run concurrently with other project_* tools; execute sequentially. Reverse a committed project-move migration.",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("migration_id")]),
                "properties": .object([
                    "migration_id": .object([
                        "type": .string("string"),
                        "description": .string("Migration id returned from an earlier project_move"),
                    ]),
                    "force": .object([
                        "type": .string("boolean"),
                        "description": .string("Bypass git-dirty warning on the current destination"),
                        "default": .bool(false),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ])
        ),
        MCPToolDefinition(
            name: "project_move_batch",
            description: "⚠️ Cannot run concurrently with other project_* tools; execute sequentially. Run multiple project moves sequentially from an inline JSON document.",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("yaml")]),
                "properties": .object([
                    "yaml": .object([
                        "type": .string("string"),
                        "description": .string("Inline JSON document conforming to schema v1. Field name `yaml` is preserved for IPC compatibility but the Swift runtime accepts JSON only."),
                    ]),
                    "dry_run": .object([
                        "type": .string("boolean"),
                        "description": .string("If true, all operations run as dry-run regardless of YAML defaults."),
                        "default": .bool(false),
                    ]),
                    "force": .object([
                        "type": .string("boolean"),
                        "description": .string("Bypass git-dirty warning on every operation"),
                        "default": .bool(false),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ])
        ),
        MCPToolDefinition(
            name: "project_recover",
            description: "Diagnose stuck or failed migrations. Reads migration_log rows in state fs_pending/fs_done/failed, probes the filesystem, and returns a per-migration recommendation. Advisory — does NOT modify anything.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "since": .object([
                        "type": .string("string"),
                        "description": .string("ISO timestamp filter"),
                    ]),
                    "include_committed": .object([
                        "type": .string("boolean"),
                        "description": .string("Also inspect committed migrations (usually unnecessary; costs FS probes)"),
                        "default": .bool(false),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ]),
            outputSchema: MCPOutputSchemas.projectRecover
        ),
        MCPToolDefinition(
            name: "manage_project_alias",
            description: "Link two project names so sessions from one appear in queries for the other. Only use this for directories moved MANUALLY outside of engram (e.g. someone ran `mv` directly). Do NOT call after project_move — that tool already creates the alias automatically.",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("action")]),
                "properties": .object([
                    "action": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("add"),
                            .string("remove"),
                            .string("list"),
                        ]),
                        "description": .string("Action to perform"),
                    ]),
                    "old_project": .object([
                        "type": .string("string"),
                        "description": .string("Old project name (for add/remove). Absolute or multi-segment paths collapse to basename."),
                    ]),
                    "new_project": .object([
                        "type": .string("string"),
                        "description": .string("New project name (for add/remove). Absolute or multi-segment paths collapse to basename."),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ])
        ),
    ]

    static func handle(
        tool name: String,
        arguments: [String: JSONValue],
        config: MCPConfig
    ) async throws -> OrderedJSONValue {
        let catalog = tools(dbPath: config.dbPath)
        guard let definition = catalog.first(where: { $0.name == name }) else {
            return .toolError(message: "Unknown tool: \(name)")
        }
        try validateArguments(arguments, for: definition)

        if unavailableNativeProjectOperationTools.contains(name) {
            return .toolError(
                message: "\(name) is unavailable in the Swift-only runtime; use the Node CLI until the native project migration pipeline is ported."
            )
        }

        let category = toolCategory(name: name, arguments: arguments)
        if category.requiresServiceSocket, !(await config.canReachEngramService()) {
            return .serviceUnavailable(
                tool: name,
                category: category.rawValue,
                socketPath: config.serviceSocketPath
            )
        }

        switch name {
        case "list_sessions":
            let database = try MCPDatabase(path: config.dbPath)
            // M9: clamp limit to [1, 100] — SQLite treats negative LIMIT as unbounded.
            let listLimit = min(max(arguments["limit"]?.intValue ?? 20, 1), 100)
            let listOffset = max(arguments["offset"]?.intValue ?? 0, 0)
            let structured = try database.listSessions(
                source: arguments["source"]?.stringValue,
                project: arguments["project"]?.stringValue,
                since: arguments["since"]?.stringValue,
                until: arguments["until"]?.stringValue,
                limit: listLimit,
                offset: listOffset,
                includeAll: arguments["include_all"]?.boolValue ?? false
            )
            return .toolSuccess(structured)
        case "stats":
            let database = try MCPDatabase(path: config.dbPath)
            let groupBy = arguments["group_by"]?.stringValue ?? "source"
            let structured = try database.stats(
                groupBy: groupBy,
                since: arguments["since"]?.stringValue,
                until: arguments["until"]?.stringValue
            )
            return .toolSuccess(structured)
        case "get_costs":
            let database = try MCPDatabase(path: config.dbPath)
            let structured = try database.getCosts(
                groupBy: arguments["group_by"]?.stringValue ?? "model",
                since: arguments["since"]?.stringValue,
                until: arguments["until"]?.stringValue
            )
            return .toolSuccess(structured)
        case "tool_analytics":
            let database = try MCPDatabase(path: config.dbPath)
            let structured = try database.getToolAnalytics(
                project: arguments["project"]?.stringValue,
                since: arguments["since"]?.stringValue,
                groupBy: arguments["group_by"]?.stringValue ?? "tool"
            )
            return .toolSuccess(structured)
        case "file_activity":
            let database = try MCPDatabase(path: config.dbPath)
            // M9: clamp limit like search/list_sessions.
            let activityLimit = min(max(arguments["limit"]?.intValue ?? 50, 1), 200)
            let structured = try database.getFileActivity(
                project: arguments["project"]?.stringValue,
                since: arguments["since"]?.stringValue,
                limit: activityLimit
            )
            return .toolSuccess(structured)
        case "project_timeline":
            let database = try MCPDatabase(path: config.dbPath)
            let structured = try database.projectTimeline(
                project: try requiredString("project", in: arguments),
                since: arguments["since"]?.stringValue,
                until: arguments["until"]?.stringValue
            )
            return .toolSuccess(structured)
        case "project_list_migrations":
            let database = try MCPDatabase(path: config.dbPath)
            let structured = try database.listMigrations(
                limit: arguments["limit"]?.intValue ?? 20,
                since: arguments["since"]?.stringValue
            )
            return .toolSuccess(structured)
        case "live_sessions":
            // Live session monitoring is not available in MCP mode (no live
            // monitor process). Return an explicit unavailable result matching
            // the registered description instead of scanning the filesystem.
            return .toolSuccess(.object([
                ("sessions", .array([])),
                ("count", .int(0)),
                ("note", .string("Live session monitor not available (MCP server mode)")),
            ]))
        case "get_memory":
            let database = try MCPDatabase(path: config.dbPath)
            let structured = try await database.getMemory(
                query: try requiredString("query", in: arguments),
                type: arguments["type"]?.stringValue
            )
            await recordInsightAccessBestEffort(in: structured, config: config)
            return .toolSuccess(structured)
        case "search":
            let query = try requiredString("query", in: arguments)
            do {
                let database = try MCPDatabase(path: config.dbPath)
                let structured = try await database.searchSessions(
                    query: query,
                    source: arguments["source"]?.stringValue,
                    project: arguments["project"]?.stringValue,
                    since: arguments["since"]?.stringValue,
                    limit: min(arguments["limit"]?.intValue ?? 10, 50),
                    mode: arguments["mode"]?.stringValue ?? "keyword"
                )
                return .toolSuccess(structured)
            } catch let error as MCPDatabase.SearchError {
                return .toolError(
                    message: error.localizedDescription,
                    code: error.structuredCode
                )
            } catch {
                return .toolError(
                    message: "Search failed. Check the Engram database and retry.",
                    code: "searchFailed"
                )
            }
        case "get_context":
            let database = try MCPDatabase(path: config.dbPath)
            let text = try database.getContext(
                cwd: try requiredString("cwd", in: arguments),
                task: arguments["task"]?.stringValue,
                maxTokens: clampedInt(arguments["max_tokens"], default: 4000, min: minContextTokens, max: maxContextTokens),
                detail: arguments["detail"]?.stringValue ?? "full",
                sortBy: arguments["sort_by"]?.stringValue ?? "recency",
                includeEnvironment: arguments["include_environment"]?.boolValue ?? true
            )
            return .textOnly(text)
        case "get_insights":
            let database = try MCPDatabase(path: config.dbPath)
            let structured = try MCPInsightsTool.result(
                database: database,
                since: arguments["since"]?.stringValue
            )
            return .toolSuccess(structured)
        case "link_sessions":
            let serviceClient = makeServiceClient(config: config)
            defer { serviceClient.close() }
            let response = try await serviceClient.linkSessions(
                EngramServiceLinkSessionsRequest(
                    targetDir: try requiredString("targetDir", in: arguments),
                    actor: "mcp"
                )
            )
            let structured = orderedLinkSessionsResult(from: response)
            return .toolSuccess(structured)
        case "project_review":
            let structured = MCPFileTools.projectReview(
                oldPath: try requiredString("old_path", in: arguments),
                newPath: try requiredString("new_path", in: arguments),
                maxItems: arguments["max_items"]?.intValue ?? 100
            )
            return .toolSuccess(structured)
        case "get_session":
            let database = try MCPDatabase(path: config.dbPath)
            let structured = try await MCPTranscriptTools.getSession(
                database: database,
                id: try requiredString("id", in: arguments),
                page: clampedInt(arguments["page"], default: 1, min: 1, max: maxSessionPage),
                roles: arguments["roles"]?.arrayValue?.compactMap(\.stringValue),
                includeRaw: arguments["include_raw"]?.boolValue == true,
                archivePageReader: { request in
                    let serviceClient = makeServiceClient(config: config)
                    defer { serviceClient.close() }
                    return try await serviceClient.archiveReadSessionPage(request)
                }
            )
            return .toolSuccess(structured)
        case "export":
            let serviceClient = makeServiceClient(config: config)
            defer { serviceClient.close() }
            do {
                let response = try await serviceClient.exportSession(
                    EngramServiceExportSessionRequest(
                        id: try requiredString("id", in: arguments),
                        format: arguments["format"]?.stringValue ?? "markdown",
                        outputHome: ProcessInfo.processInfo.environment["HOME"],
                        actor: "mcp"
                    )
                )
                let structured = orderedExportSessionResult(from: response)
                return .toolSuccess(structured)
            } catch let error as EngramServiceError {
                // M12: surface transcriptTooLarge from service commandFailed name/details.
                if case .commandFailed(let name, let message, _, let details) = error {
                    let code = details?["code"].flatMap { value -> String? in
                        if case .string(let code) = value { return code }
                        return nil
                    } ?? name
                    if code == "transcriptTooLarge" || name == "transcriptTooLarge" {
                        return .toolError(message: message, code: "transcriptTooLarge")
                    }
                }
                throw error
            }
        case "handoff":
            let database = try MCPDatabase(path: config.dbPath)
            let structured = try MCPTranscriptTools.handoff(
                database: database,
                cwd: try requiredString("cwd", in: arguments),
                sessionID: arguments["sessionId"]?.stringValue,
                format: arguments["format"]?.stringValue ?? "markdown"
            )
            return .toolSuccess(structured)
        case "generate_summary":
            let serviceClient = makeServiceClient(config: config)
            defer { serviceClient.close() }
            let sessionId = try requiredString("sessionId", in: arguments)
            let response = try await serviceClient.generateSummary(
                EngramServiceGenerateSummaryRequest(sessionId: sessionId)
            )
            return .object([
                ("content", .array([
                    .object([
                        ("type", .string("text")),
                        ("text", .string(response.summary)),
                    ]),
                ])),
                ("metadata", .object([
                    ("sessionId", .string(sessionId)),
                ])),
            ])
        case "save_insight":
            let serviceClient = makeServiceClient(config: config)
            defer { serviceClient.close() }
            let raw = try await serviceClient.saveInsight(
                EngramServiceSaveInsightRequest(
                    content: try requiredString("content", in: arguments),
                    wing: arguments["wing"]?.stringValue,
                    room: arguments["room"]?.stringValue,
                    importance: arguments["importance"]?.doubleValue,
                    sourceSessionId: arguments["source_session_id"]?.stringValue,
                    actor: "mcp",
                    type: arguments["type"]?.stringValue
                )
            )
            let structured = orderedSaveInsight(from: jsonValue(raw))
            return .toolSuccess(structured)
        case "delete_insight":
            let id = try requiredString("id", in: arguments)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else {
                throw MCPToolError.invalidArguments("id is required")
            }
            if arguments["dry_run"]?.boolValue == true {
                return .toolSuccess(.object([
                    ("id", .string(id)),
                    ("deleted", .bool(false)),
                    ("dry_run", .bool(true)),
                ]))
            }
            let serviceClient = makeServiceClient(config: config)
            defer { serviceClient.close() }
            let raw = try await serviceClient.deleteInsight(
                EngramServiceDeleteInsightRequest(id: id)
            )
            return .toolSuccess(orderedDeleteInsight(from: jsonValue(raw)))
        case "hide_session":
            let sessionId = try requiredString("session_id", in: arguments)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sessionId.isEmpty else {
                throw MCPToolError.invalidArguments("session_id is required")
            }
            let hidden = arguments["hidden"]?.boolValue ?? true
            if arguments["dry_run"]?.boolValue != true {
                let serviceClient = makeServiceClient(config: config)
                defer { serviceClient.close() }
                try await serviceClient.setSessionHidden(sessionId: sessionId, hidden: hidden)
            }
            return .toolSuccess(.object([
                ("session_id", .string(sessionId)),
                ("hidden", .bool(hidden)),
                ("dry_run", .bool(arguments["dry_run"]?.boolValue ?? false)),
            ]))
        case "manage_project_alias":
            let action = try requiredString("action", in: arguments)
            switch action {
            case "list":
                let database = try MCPDatabase(path: config.dbPath)
                return .toolSuccess(try database.listProjectAliases())
            case "add", "remove":
                let serviceClient = makeServiceClient(config: config)
                defer { serviceClient.close() }
                let raw = try await serviceClient.manageProjectAlias(
                    EngramServiceProjectAliasRequest(
                        action: action,
                        oldProject: try requiredString("old_project", in: arguments),
                        newProject: try requiredString("new_project", in: arguments),
                        actor: "mcp"
                    )
                )
                return .toolSuccess(OrderedJSONValue(jsonValue(raw)))
            default:
                return .toolError(message: "Unknown action: \(action)")
            }
        case "project_move":
            let serviceClient = makeServiceClient(config: config)
            defer { serviceClient.close() }
            let originalSrc = try requiredString("src", in: arguments)
            let originalDst = try requiredString("dst", in: arguments)
            let src = expandHomePath(originalSrc)
            let dst = expandHomePath(originalDst)
            let response = try await serviceClient.projectMove(
                EngramServiceProjectMoveRequest(
                    src: src,
                    dst: dst,
                    dryRun: try optionalBool("dry_run", in: arguments),
                    force: try optionalBool("force", in: arguments),
                    auditNote: arguments["note"]?.stringValue,
                    actor: "mcp"
                )
            )
            let resolved: (src: String, dst: String)? = (src != originalSrc || dst != originalDst)
                ? (src, dst)
                : nil
            let ordered = orderedProjectMoveResult(from: response, resolved: resolved)
            return .toolSuccess(ordered)
        case "project_archive":
            let serviceClient = makeServiceClient(config: config)
            defer { serviceClient.close() }
            let src = expandHomePath(try requiredString("src", in: arguments))
            let response = try await serviceClient.projectArchive(
                EngramServiceProjectArchiveRequest(
                    src: src,
                    archiveTo: arguments["to"]?.stringValue,
                    dryRun: try optionalBool("dry_run", in: arguments),
                    force: try optionalBool("force", in: arguments),
                    auditNote: arguments["note"]?.stringValue,
                    actor: "mcp"
                )
            )
            return .toolSuccess(orderedProjectArchiveResult(from: response))
        case "project_undo":
            let serviceClient = makeServiceClient(config: config)
            defer { serviceClient.close() }
            let response = try await serviceClient.projectUndo(
                EngramServiceProjectUndoRequest(
                    migrationId: try requiredString("migration_id", in: arguments),
                    force: try optionalBool("force", in: arguments),
                    actor: "mcp"
                )
            )
            return .toolSuccess(orderedPipelineResult(from: response))
        case "project_move_batch":
            let serviceClient = makeServiceClient(config: config)
            defer { serviceClient.close() }
            let raw = try await serviceClient.projectMoveBatch(
                EngramServiceProjectMoveBatchRequest(
                    yaml: try requiredString("yaml", in: arguments),
                    dryRun: try optionalBool("dry_run", in: arguments),
                    force: try optionalBool("force", in: arguments),
                    actor: "mcp"
                )
            )
            return .toolSuccess(orderedProjectMoveBatchResult(from: jsonValue(raw)))
        case "project_recover":
            let database = try MCPDatabase(path: config.dbPath)
            let structured = try database.projectRecover(
                since: arguments["since"]?.stringValue,
                includeCommitted: arguments["include_committed"]?.boolValue ?? false
            )
            return .toolSuccess(structured)
        default:
            return .toolError(message: "Unknown tool: \(name)")
        }
    }

    static func toolCategory(name: String, arguments: [String: JSONValue] = [:]) -> ToolCategory {
        switch name {
        case "list_sessions",
             "stats",
             "get_costs",
             "tool_analytics",
             "file_activity",
             "project_timeline",
             "project_list_migrations",
             "live_sessions",
             "get_memory",
             "search",
             "get_context",
             "get_insights",
             "project_review",
             "get_session",
             "handoff",
             "project_recover":
            return .readOnly
        case "generate_summary":
            // Wave 7D H06: persists sessions.summary — must not advertise readOnlyHint.
            return .mutating
        case "save_insight",
             "delete_insight",
             "hide_session",
             "export",
             "link_sessions":
            return arguments["dry_run"]?.boolValue == true ? .readOnly : .mutating
        case "manage_project_alias":
            return arguments["action"]?.stringValue == "list" ? .readOnly : .mutating
        case "project_move",
             "project_archive",
             "project_undo",
             "project_move_batch":
            return .operational
        default:
            return .readOnly
        }
    }

    static func humanTitle(for name: String) -> String {
        name.split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private static func recordInsightAccessBestEffort(
        in structured: OrderedJSONValue,
        config: MCPConfig
    ) async {
        let ids = memoryIds(in: structured)
        guard !ids.isEmpty, await config.canReachEngramService() else { return }
        let serviceClient = makeServiceClient(config: config)
        defer { serviceClient.close() }
        try? await serviceClient.recordInsightAccess(ids: ids)
    }

    private static func memoryIds(in structured: OrderedJSONValue) -> [String] {
        guard case .object(let entries) = structured,
              let memories = entries.first(where: { $0.0 == "memories" })?.1,
              case .array(let items) = memories else { return [] }

        var seen: Set<String> = []
        var ids: [String] = []
        for item in items {
            guard case .object(let fields) = item,
                  let idValue = fields.first(where: { $0.0 == "id" })?.1,
                  case .string(let rawId) = idValue else { continue }
            let id = rawId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            ids.append(id)
        }
        return ids
    }

    /// Tools whose default (non-dry-run) invocation can irreversibly remove or
    /// overwrite user-visible state. Surfaced as `destructiveHint` so MCP clients
    /// can gate them behind confirmation.
    private static let destructiveTools: Set<String> = [
        "delete_insight", "hide_session", "project_move",
        "project_archive", "project_move_batch",
    ]

    /// Tools that are safe to retry with the same arguments.
    private static let idempotentTools: Set<String> = [
        "link_sessions", "manage_project_alias",
        "project_undo", "project_recover",
    ]

    /// MCP tool annotations derived from the existing `ToolCategory` so clients
    /// can auto-approve read-only calls and gate mutating/destructive ones. Uses
    /// the default (no-argument) category — the conservative read for tools whose
    /// category depends on arguments (e.g. `dry_run`, alias `action`).
    static func toolAnnotations(for name: String) -> OrderedJSONValue {
        let category = toolCategory(name: name)
        var entries: [(String, OrderedJSONValue)] = [
            ("title", .string(humanTitle(for: name))),
        ]
        switch category {
        case .readOnly, .longRunningRead:
            entries.append(("readOnlyHint", .bool(true)))
        case .mutating, .operational:
            entries.append(("readOnlyHint", .bool(false)))
            entries.append(("destructiveHint", .bool(destructiveTools.contains(name))))
            entries.append(("idempotentHint", .bool(idempotentTools.contains(name))))
        }
        entries.append(("openWorldHint", .bool(false)))
        return .object(entries)
    }

    // MARK: - MCP resources & prompts (deepen the agent-facing surface)

    static func resourcesList(config: MCPConfig) async throws -> OrderedJSONValue {
        let database = try MCPDatabase(path: config.dbPath)
        let catalog = (try? database.recentResourceCatalog(sessionLimit: 15, insightLimit: 15)) ?? []
        let items = catalog.map { entry -> OrderedJSONValue in
            .object([
                ("uri", .string(entry.uri)),
                ("name", .string(entry.name)),
                ("description", .string(entry.description)),
                ("mimeType", .string(entry.mimeType)),
            ])
        }
        return .object([("resources", .array(items))])
    }

    static func resourceRead(uri: String, config: MCPConfig) async throws -> OrderedJSONValue {
        guard let parsed = parseEngramResourceURI(uri) else {
            throw MCPToolError.invalidArguments("Unsupported resource uri: \(uri)")
        }
        let text: String
        let mimeType: String
        switch parsed.kind {
        case "session":
            let result = try await handle(
                tool: "get_session",
                arguments: ["id": .string(parsed.id)],
                config: config
            )
            text = result.firstToolText ?? ""
            mimeType = "text/markdown"
        case "insight":
            let database = try MCPDatabase(path: config.dbPath)
            guard let content = try database.insightContent(id: parsed.id) else {
                throw MCPToolError.invalidArguments("Insight not found: \(parsed.id)")
            }
            text = content
            mimeType = "text/plain"
        default:
            throw MCPToolError.invalidArguments("Unsupported resource uri: \(uri)")
        }
        return .object([
            ("contents", .array([
                .object([
                    ("uri", .string(uri)),
                    ("mimeType", .string(mimeType)),
                    ("text", .string(text)),
                ]),
            ])),
        ])
    }

    private static func parseEngramResourceURI(_ uri: String) -> (kind: String, id: String)? {
        let prefix = "engram://"
        guard uri.hasPrefix(prefix) else { return nil }
        let rest = String(uri.dropFirst(prefix.count))
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let kind = String(rest[rest.startIndex..<slash])
        let id = String(rest[rest.index(after: slash)...])
        guard !kind.isEmpty, !id.isEmpty else { return nil }
        return (kind, id)
    }

    /// (name, description, [(argName, argDescription, required)])
    static let promptDefinitions: [(name: String, description: String, arguments: [(String, String, Bool)])] = [
        (
            "engram:catch-up",
            "Inject Engram's cross-tool history for the current working directory before starting a task.",
            [
                ("cwd", "Absolute path of the project directory", true),
                ("task", "Optional task description for relevance ranking", false),
            ]
        ),
        (
            "engram:handoff",
            "Generate a handoff brief summarizing recent work in a project.",
            [("cwd", "Absolute path of the project directory", true)]
        ),
    ]

    static func promptsList() -> OrderedJSONValue {
        let items = promptDefinitions.map { prompt -> OrderedJSONValue in
            let args = prompt.arguments.map { arg -> OrderedJSONValue in
                .object([
                    ("name", .string(arg.0)),
                    ("description", .string(arg.1)),
                    ("required", .bool(arg.2)),
                ])
            }
            return .object([
                ("name", .string(prompt.name)),
                ("description", .string(prompt.description)),
                ("arguments", .array(args)),
            ])
        }
        return .object([("prompts", .array(items))])
    }

    static func promptGet(
        name: String,
        arguments: [String: JSONValue],
        config: MCPConfig
    ) async throws -> OrderedJSONValue {
        let tool: String
        let description: String
        switch name {
        case "engram:catch-up":
            tool = "get_context"
            description = "Engram project history for the current task"
        case "engram:handoff":
            tool = "handoff"
            description = "Engram handoff brief"
        default:
            throw MCPToolError.invalidArguments("Unknown prompt: \(name)")
        }
        guard let cwd = arguments["cwd"]?.stringValue, !cwd.isEmpty else {
            throw MCPToolError.invalidArguments("cwd is required")
        }
        var toolArgs: [String: JSONValue] = ["cwd": .string(cwd)]
        if name == "engram:catch-up",
           let task = arguments["task"]?.stringValue, !task.isEmpty {
            toolArgs["task"] = .string(task)
        }
        let result = try await handle(tool: tool, arguments: toolArgs, config: config)
        let text = result.firstToolText ?? "No Engram context available for \(cwd)."
        return .object([
            ("description", .string(description)),
            ("messages", .array([
                .object([
                    ("role", .string("user")),
                    ("content", .object([
                        ("type", .string("text")),
                        ("text", .string(text)),
                    ])),
                ]),
            ])),
        ])
    }

    private static func requiredString(
        _ key: String,
        in arguments: [String: JSONValue]
    ) throws -> String {
        guard let value = arguments[key]?.stringValue, !value.isEmpty else {
            throw MCPToolError.invalidArguments("\(key) is required")
        }
        return value
    }

    /// Optional boolean argument. Missing → default; present non-bool → error.
    /// Defense-in-depth beyond schema validateArgumentType (boolean).
    private static func optionalBool(
        _ key: String,
        in arguments: [String: JSONValue],
        default defaultValue: Bool = false
    ) throws -> Bool {
        guard let value = arguments[key] else { return defaultValue }
        guard let bool = value.boolValue else {
            throw MCPToolError.invalidArguments("\(key) must be a boolean")
        }
        return bool
    }

    private static func clampedInt(
        _ value: JSONValue?,
        default defaultValue: Int,
        min minValue: Int,
        max maxValue: Int
    ) -> Int {
        let raw = value?.intValue ?? defaultValue
        return Swift.max(minValue, Swift.min(maxValue, raw))
    }

    private static func validateArguments(
        _ arguments: [String: JSONValue],
        for definition: MCPToolDefinition
    ) throws {
        guard let schema = definition.inputSchema.objectValue else { return }
        let properties = schema["properties"]?.objectValue ?? [:]

        if schema["additionalProperties"]?.boolValue == false {
            for key in arguments.keys where properties[key] == nil {
                throw MCPToolError.invalidArguments("\(key) is not a valid argument")
            }
        }

        if let required = schema["required"]?.arrayValue {
            for case .string(let key) in required where arguments[key] == nil {
                throw MCPToolError.invalidArguments("\(key) is required")
            }
        }

        for (key, value) in arguments {
            guard let propertySchema = properties[key]?.objectValue else { continue }
            try validateArgument(value, toolName: definition.name, key: key, schema: propertySchema)
        }
    }

    private static func validateArgument(
        _ value: JSONValue,
        toolName: String,
        key: String,
        schema: [String: JSONValue]
    ) throws {
        if let type = schema["type"]?.stringValue {
            try validateArgumentType(value, key: key, type: type)
        }

        if let numericValue = value.doubleValue {
            if let minimum = schema["minimum"]?.doubleValue, numericValue < minimum {
                throw MCPToolError.invalidArguments("\(key) must be >= \(formatSchemaNumber(minimum))")
            }
            if let maximum = schema["maximum"]?.doubleValue, numericValue > maximum {
                throw MCPToolError.invalidArguments("\(key) must be <= \(formatSchemaNumber(maximum))")
            }
        }

        // Validate each element of an array against its declared items.enum so
        // bogus values (e.g. roles:["banana"]) are rejected instead of silently
        // passing the array-type check.
        if schema["type"]?.stringValue == "array",
           let items = schema["items"]?.objectValue,
           let allowedItems = items["enum"]?.arrayValue,
           let elements = value.arrayValue {
            for element in elements where !allowedItems.contains(element) {
                let formatted = allowedItems.compactMap(\.stringValue).joined(separator: ", ")
                if formatted.isEmpty {
                    throw MCPToolError.invalidArguments("\(key) has an unsupported value")
                }
                throw MCPToolError.invalidArguments("\(key) items must be one of: \(formatted)")
            }
        }

        // search.mode: accept known mode names even when tools/list currently
        // advertises only keyword so the search path can return structured
        // `searchModeUnavailable` instead of a generic invalidArguments error.
        if "\(toolName).\(key)" == "search.mode",
           let mode = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           ["keyword", "semantic", "hybrid", "both"].contains(mode) {
            return
        }

        if let allowed = schema["enum"]?.arrayValue, !allowed.contains(value) {
            let formattedAllowed = allowed.compactMap(\.stringValue).joined(separator: ", ")
            if formattedAllowed.isEmpty {
                throw MCPToolError.invalidArguments("\(key) has an unsupported value")
            }
            throw MCPToolError.invalidArguments("\(key) must be one of: \(formattedAllowed)")
        }
    }

    private static func validateArgumentType(
        _ value: JSONValue,
        key: String,
        type: String
    ) throws {
        switch type {
        case "string":
            guard value.stringValue != nil else {
                throw MCPToolError.invalidArguments("\(key) must be a string")
            }
        case "number", "integer":
            switch value {
            case .int, .double:
                return
            default:
                throw MCPToolError.invalidArguments("\(key) must be a number")
            }
        case "boolean":
            guard value.boolValue != nil else {
                throw MCPToolError.invalidArguments("\(key) must be a boolean")
            }
        case "array":
            guard value.arrayValue != nil else {
                throw MCPToolError.invalidArguments("\(key) must be an array")
            }
        case "object":
            guard value.objectValue != nil else {
                throw MCPToolError.invalidArguments("\(key) must be an object")
            }
        default:
            return
        }
    }

    private static func formatSchemaNumber(_ value: Double) -> String {
        if value.isFinite,
           value.rounded(.towardZero) == value,
           value >= Double(Int.min),
           value <= Double(Int.max) {
            return String(Int(value))
        }
        return String(value)
    }
}

private func makeServiceClient(config: MCPConfig) -> EngramServiceClient {
    EngramServiceClient(
        transport: UnixSocketEngramServiceTransport(socketPath: config.serviceSocketPath)
    )
}

private func orderedSaveInsight(from raw: JSONValue) -> OrderedJSONValue {
    var entries: [(String, OrderedJSONValue)] = []
    if let id = raw["id"] { entries.append(("id", OrderedJSONValue(id))) }
    if let content = raw["content"] { entries.append(("content", OrderedJSONValue(content))) }
    if let wing = raw["wing"] { entries.append(("wing", OrderedJSONValue(wing))) }
    if let room = raw["room"] { entries.append(("room", OrderedJSONValue(room))) }
    if let importance = raw["importance"] { entries.append(("importance", OrderedJSONValue(importance))) }
    if let duplicateWarning = raw["duplicateWarning"] {
        entries.append(("duplicateWarning", OrderedJSONValue(duplicateWarning)))
    }
    if let warning = raw["warning"] { entries.append(("warning", OrderedJSONValue(warning))) }
    return .object(entries)
}

private func orderedDeleteInsight(from raw: JSONValue) -> OrderedJSONValue {
    var entries: [(String, OrderedJSONValue)] = []
    if let id = raw["id"] { entries.append(("id", OrderedJSONValue(id))) }
    if let deleted = raw["deleted"] { entries.append(("deleted", OrderedJSONValue(deleted))) }
    return .object(entries)
}

private func orderedLinkSessionsResult(from response: EngramServiceLinkSessionsResponse) -> OrderedJSONValue {
    var entries: [(String, OrderedJSONValue)] = [
        ("created", .int(response.created)),
        ("skipped", .int(response.skipped)),
        ("errors", .array(response.errors.map(OrderedJSONValue.string))),
        ("targetDir", .string(response.targetDir)),
        ("projectNames", .array(response.projectNames.map(OrderedJSONValue.string))),
    ]
    if let truncated = response.truncated {
        entries.append(("truncated", .bool(truncated)))
    }
    return .object(entries)
}

private func orderedExportSessionResult(from response: EngramServiceExportSessionResponse) -> OrderedJSONValue {
    .object([
        ("outputPath", .string(response.outputPath)),
        ("format", .string(response.format)),
        ("messageCount", .int(response.messageCount)),
    ])
}

private func expandHomePath(_ path: String) -> String {
    let homePath = ProcessInfo.processInfo.environment["HOME"]
        .flatMap { $0.isEmpty ? nil : $0 }
        ?? FileManager.default.homeDirectoryForCurrentUser.path
    if path == "~" {
        return homePath
    }
    if path.hasPrefix("~/") {
        return URL(fileURLWithPath: homePath, isDirectory: true)
            .appendingPathComponent(String(path.dropFirst(2)))
            .path
    }
    return path
}

private func jsonValue(_ value: EngramServiceJSONValue) -> JSONValue {
    switch value {
    case .string(let string):
        return .string(string)
    case .number(let number):
        if number.rounded(.towardZero) == number,
           number >= Double(Int.min),
           number <= Double(Int.max) {
            return .int(Int(number))
        }
        return .double(number)
    case .bool(let bool):
        return .bool(bool)
    case .object(let object):
        return .object(object.mapValues(jsonValue))
    case .array(let array):
        return .array(array.map(jsonValue))
    case .null:
        return .null
    }
}

private struct SaveInsightBody: Encodable {
    let actor: String
    let content: String
    let wing: String?
    let room: String?
    let importance: Double?
    let sourceSessionID: String?

    enum CodingKeys: String, CodingKey {
        case actor
        case content
        case wing
        case room
        case importance
        case sourceSessionID = "source_session_id"
    }
}

private struct GenerateSummaryBody: Encodable {
    let actor: String
    let sessionId: String
}

private struct GenerateSummaryResponse: Decodable {
    let summary: String
}

private struct ProjectAliasBody: Encodable {
    let actor: String
    let alias: String
    let canonical: String
}

private struct ProjectMoveBody: Encodable {
    let actor: String
    let src: String
    let dst: String
    let dryRun: Bool
    let force: Bool
    let auditNote: String?
}

private struct ProjectArchiveBody: Encodable {
    let actor: String
    let src: String
    let archiveTo: String?
    let dryRun: Bool
    let force: Bool
    let auditNote: String?
}

private struct ProjectUndoBody: Encodable {
    let actor: String
    let migrationId: String
    let force: Bool
}

private struct ProjectMoveBatchBody: Encodable {
    let actor: String
    let yaml: String
    let dryRun: Bool
    let force: Bool
}

enum MCPToolError: LocalizedError {
    case invalidArguments(String)
    case transcriptTooLarge(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message):
            return message
        case .transcriptTooLarge(let message):
            return message
        }
    }

    var structuredCode: String? {
        switch self {
        case .invalidArguments:
            return nil
        case .transcriptTooLarge:
            return "transcriptTooLarge"
        }
    }
}

extension OrderedJSONValue {
    static func toolSuccess(_ structured: OrderedJSONValue) -> OrderedJSONValue {
        let textMirrorLimit = 4_096
        let prettyText = structured.prettyJSONString()
        let text = prettyText.count <= textMirrorLimit
            ? prettyText
            : "Structured content omitted from text because it exceeds \(textMirrorLimit) characters. Read structuredContent."
        return .object([
            ("content", .array([
                .object([
                    ("type", .string("text")),
                    ("text", .string(text)),
                ]),
            ])),
            ("structuredContent", structured),
        ])
    }

    static func toolError(
        message: String,
        structured: OrderedJSONValue? = nil,
        code: String? = nil
    ) -> OrderedJSONValue {
        var entries: [(String, OrderedJSONValue)] = [
            ("content", .array([
                .object([
                    ("type", .string("text")),
                    ("text", .string(message)),
                ]),
            ])),
            ("isError", .bool(true)),
        ]
        if let structured {
            entries.append(("structuredContent", structured))
        } else if let code {
            entries.append(("structuredContent", .object([
                ("code", .string(code)),
                ("message", .string(message)),
            ])))
        }
        return .object(entries)
    }

    static func serviceUnavailable(
        tool: String,
        category: String,
        socketPath: String
    ) -> OrderedJSONValue {
        let message = "EngramService is unavailable; mutating and operational MCP tools fail closed until the service socket is available."
        let structured: OrderedJSONValue = .object([
            ("code", .string("serviceUnavailable")),
            ("tool", .string(tool)),
            ("category", .string(category)),
            ("socketPath", .string(socketPath)),
            ("message", .string(message)),
        ])
        return .object([
            ("content", .array([
                .object([
                    ("type", .string("text")),
                    ("text", .string(message)),
                ]),
            ])),
            ("structuredContent", structured),
            ("isError", .bool(true)),
        ])
    }

    static func textOnly(_ text: String) -> OrderedJSONValue {
        .object([
            ("content", .array([
                .object([
                    ("type", .string("text")),
                    ("text", .string(text)),
                ]),
            ])),
        ])
    }
}

extension JSONValue {
    var objectValue: [String: JSONValue]? {
        guard case .object(let object) = self else { return nil }
        return object
    }

    var doubleValue: Double? {
        switch self {
        case .double(let value):
            return value
        case .int(let value):
            return Double(value)
        default:
            return nil
        }
    }
}
