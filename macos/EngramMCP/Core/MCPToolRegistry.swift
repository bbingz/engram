import Foundation

struct MCPToolDefinition {
    let name: String
    let description: String
    let inputSchema: JSONValue

    var jsonValue: JSONValue {
        .object([
            "name": .string(name),
            "description": .string(description),
            "inputSchema": inputSchema,
        ])
    }

    var orderedJSONValue: OrderedJSONValue {
        .object([
            ("name", .string(name)),
            ("description", .string(description)),
            ("inputSchema", OrderedJSONValue(inputSchema)),
        ])
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

    static let tools: [MCPToolDefinition] = allToolDefinitions.filter {
        !unavailableNativeProjectOperationTools.contains($0.name)
    }

    private static let allToolDefinitions: [MCPToolDefinition] = [
        MCPToolDefinition(
            name: "list_sessions",
            description: "列出 AI 编程助手的历史会话。支持按工具来源、项目、时间范围过滤。",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "source": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("codex"),
                            .string("claude-code"),
                            .string("gemini-cli"),
                            .string("opencode"),
                            .string("iflow"),
                            .string("qwen"),
                            .string("kimi"),
                            .string("cline"),
                            .string("cursor"),
                            .string("vscode"),
                            .string("antigravity"),
                            .string("windsurf"),
                        ]),
                        "description": .string("过滤特定工具的会话"),
                    ]),
                    "project": .object([
                        "type": .string("string"),
                        "description": .string("过滤特定项目（部分匹配）"),
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
                ]),
                "additionalProperties": .bool(false),
            ])
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
            ])
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
            ])
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
            ])
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
            ])
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
            ])
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
            ])
        ),
        MCPToolDefinition(
            name: "live_sessions",
            description: "List currently active coding sessions detected by file activity.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "additionalProperties": .bool(false),
            ])
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
                ]),
                "additionalProperties": .bool(false),
            ])
        ),
        MCPToolDefinition(
            name: "search",
            description: "Full-text and semantic search across all session content. Supports Chinese and English.",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("query")]),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Search keywords (at least 2 characters for semantic, 3 for keyword)"),
                    ]),
                    "source": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("codex"),
                            .string("claude-code"),
                            .string("gemini-cli"),
                            .string("opencode"),
                            .string("iflow"),
                            .string("qwen"),
                            .string("kimi"),
                            .string("cline"),
                            .string("cursor"),
                            .string("vscode"),
                            .string("antigravity"),
                            .string("windsurf"),
                        ]),
                    ]),
                    "project": .object(["type": .string("string")]),
                    "since": .object(["type": .string("string")]),
                    "limit": .object([
                        "type": .string("number"),
                        "description": .string("Default 10, max 50"),
                    ]),
                    "mode": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("hybrid"),
                            .string("keyword"),
                            .string("semantic"),
                        ]),
                        "description": .string("Search mode (default: hybrid)"),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ])
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
                        "description": .string("当前任务描述（可选，用于语义搜索）"),
                    ]),
                    "max_tokens": .object([
                        "type": .string("number"),
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
            description: "Get actionable cost optimization suggestions with savings estimates",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "since": .object([
                        "type": .string("string"),
                        "description": .string("ISO timestamp for start of analysis window (default: 7 days ago)"),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ])
        ),
        MCPToolDefinition(
            name: "lint_config",
            description: "Lint CLAUDE.md and similar config files: verify file references exist, npm scripts are valid, and detect stale instructions.",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("cwd")]),
                "properties": .object([
                    "cwd": .object([
                        "type": .string("string"),
                        "description": .string("Project root directory"),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ])
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
            description: "Scan all 7 AI session roots for residual references to an old project path. Classifies hits into `own` (in the migrated project's own spaces — real leftovers) vs `other` (historical mentions in unrelated conversations — left alone by design).",
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
            ])
        ),
        MCPToolDefinition(
            name: "get_session",
            description: "读取单个会话的完整对话内容。大会话支持分页（每页 50 条消息）。",
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
                        "description": .string("只返回指定角色的消息，默认返回全部"),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ])
        ),
        MCPToolDefinition(
            name: "export",
            description: "将单个会话导出为 Markdown 或 JSON 文件，保存到 ~/codex-exports/ 目录。",
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
            ])
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
                    "source_session_id": .object([
                        "type": .string("string"),
                        "description": .string("Session ID that generated this insight (optional)"),
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
                        "description": .string("Absolute source path (e.g. /Users/example/-Code-/MyProject). ~-prefix accepted."),
                    ]),
                    "dst": .object([
                        "type": .string("string"),
                        "description": .string("Absolute destination path (e.g. /Users/example/-Code-/MyProject-v2). ~-prefix accepted."),
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
                        "description": .string("Absolute source path (e.g. /Users/example/-Code-/OldScript). ~-prefix accepted."),
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
            ])
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
                        "description": .string("Old project name (for add/remove)"),
                    ]),
                    "new_project": .object([
                        "type": .string("string"),
                        "description": .string("New project name (for add/remove)"),
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
            let structured = try database.listSessions(
                source: arguments["source"]?.stringValue,
                project: arguments["project"]?.stringValue,
                since: arguments["since"]?.stringValue,
                until: arguments["until"]?.stringValue,
                limit: min(arguments["limit"]?.intValue ?? 20, 100),
                offset: arguments["offset"]?.intValue ?? 0
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
            let structured = try database.getFileActivity(
                project: arguments["project"]?.stringValue,
                since: arguments["since"]?.stringValue,
                limit: arguments["limit"]?.intValue ?? 50
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
            return .toolSuccess(
                .object([
                    ("sessions", .array([])),
                    ("count", .int(0)),
                    ("note", .string("Live session monitor not available (MCP server mode)")),
                ])
            )
        case "get_memory":
            let database = try MCPDatabase(path: config.dbPath)
            let structured = try database.getMemory(query: try requiredString("query", in: arguments))
            return .toolSuccess(structured)
        case "search":
            let database = try MCPDatabase(path: config.dbPath)
            let structured = try database.searchSessions(
                query: try requiredString("query", in: arguments),
                source: arguments["source"]?.stringValue,
                project: arguments["project"]?.stringValue,
                since: arguments["since"]?.stringValue,
                limit: min(arguments["limit"]?.intValue ?? 10, 50),
                mode: arguments["mode"]?.stringValue ?? "hybrid"
            )
            return .toolSuccess(structured)
        case "get_context":
            let database = try MCPDatabase(path: config.dbPath)
            let text = try database.getContext(
                cwd: try requiredString("cwd", in: arguments),
                task: arguments["task"]?.stringValue,
                maxTokens: arguments["max_tokens"]?.intValue ?? 4000,
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
        case "lint_config":
            return .toolSuccess(MCPFileTools.lintConfig(cwd: try requiredString("cwd", in: arguments)))
        case "link_sessions":
            let serviceClient = makeServiceClient(config: config)
            defer {
                Task {
                    await serviceClient.close()
                }
            }
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
            let structured = try MCPTranscriptTools.getSession(
                database: database,
                id: try requiredString("id", in: arguments),
                page: arguments["page"]?.intValue ?? 1,
                roles: arguments["roles"]?.arrayValue?.compactMap(\.stringValue)
            )
            return .toolSuccess(structured)
        case "export":
            let serviceClient = makeServiceClient(config: config)
            defer {
                Task {
                    await serviceClient.close()
                }
            }
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
            defer {
                Task {
                    await serviceClient.close()
                }
            }
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
            defer {
                Task {
                    await serviceClient.close()
                }
            }
            let raw = try await serviceClient.saveInsight(
                EngramServiceSaveInsightRequest(
                    content: try requiredString("content", in: arguments),
                    wing: arguments["wing"]?.stringValue,
                    room: arguments["room"]?.stringValue,
                    importance: arguments["importance"]?.doubleValue,
                    sourceSessionId: arguments["source_session_id"]?.stringValue,
                    actor: "mcp"
                )
            )
            let structured = orderedSaveInsight(from: jsonValue(raw))
            return .toolSuccess(structured)
        case "manage_project_alias":
            let action = try requiredString("action", in: arguments)
            switch action {
            case "list":
                let database = try MCPDatabase(path: config.dbPath)
                return .toolSuccess(try database.listProjectAliases())
            case "add", "remove":
                let serviceClient = makeServiceClient(config: config)
                defer {
                    Task {
                        await serviceClient.close()
                    }
                }
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
            defer {
                Task {
                    await serviceClient.close()
                }
            }
            let originalSrc = try requiredString("src", in: arguments)
            let originalDst = try requiredString("dst", in: arguments)
            let src = expandHomePath(originalSrc)
            let dst = expandHomePath(originalDst)
            let response = try await serviceClient.projectMove(
                EngramServiceProjectMoveRequest(
                    src: src,
                    dst: dst,
                    dryRun: arguments["dry_run"]?.boolValue ?? false,
                    force: arguments["force"]?.boolValue ?? false,
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
            defer {
                Task {
                    await serviceClient.close()
                }
            }
            let src = expandHomePath(try requiredString("src", in: arguments))
            let response = try await serviceClient.projectArchive(
                EngramServiceProjectArchiveRequest(
                    src: src,
                    archiveTo: arguments["to"]?.stringValue,
                    dryRun: arguments["dry_run"]?.boolValue ?? false,
                    force: arguments["force"]?.boolValue ?? false,
                    auditNote: arguments["note"]?.stringValue,
                    actor: "mcp"
                )
            )
            return .toolSuccess(orderedProjectArchiveResult(from: response))
        case "project_undo":
            let serviceClient = makeServiceClient(config: config)
            defer {
                Task {
                    await serviceClient.close()
                }
            }
            let response = try await serviceClient.projectUndo(
                EngramServiceProjectUndoRequest(
                    migrationId: try requiredString("migration_id", in: arguments),
                    force: arguments["force"]?.boolValue ?? false,
                    actor: "mcp"
                )
            )
            return .toolSuccess(orderedPipelineResult(from: response))
        case "project_move_batch":
            let serviceClient = makeServiceClient(config: config)
            defer {
                Task {
                    await serviceClient.close()
                }
            }
            let raw = try await serviceClient.projectMoveBatch(
                EngramServiceProjectMoveBatchRequest(
                    yaml: try requiredString("yaml", in: arguments),
                    dryRun: arguments["dry_run"]?.boolValue ?? false,
                    force: arguments["force"]?.boolValue ?? false,
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
             "lint_config",
             "project_review",
             "get_session",
             "handoff",
             "project_recover":
            return .readOnly
        case "generate_summary":
            return .longRunningRead
        case "save_insight",
             "export",
             "link_sessions":
            return .mutating
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

    private static func requiredString(
        _ key: String,
        in arguments: [String: JSONValue]
    ) throws -> String {
        guard let value = arguments[key]?.stringValue, !value.isEmpty else {
            throw MCPToolError.invalidArguments("\(key) is required")
        }
        return value
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

private func orderedProjectMoveResult(
    from raw: JSONValue,
    resolved: (src: String, dst: String)?
) -> OrderedJSONValue {
    guard case .object(let object) = raw else { return OrderedJSONValue(raw) }
    var entries = orderedPipelineEntries(from: object)
    if let resolved {
        entries.append((
            "resolved",
            .object([
                ("src", .string(resolved.src)),
                ("dst", .string(resolved.dst)),
            ])
        ))
    }
    return .object(entries)
}

private func orderedProjectMoveResult(
    from result: EngramServiceProjectMoveResult,
    resolved: (src: String, dst: String)?
) -> OrderedJSONValue {
    var entries = orderedPipelineEntries(from: result)
    if let resolved {
        entries.append((
            "resolved",
            .object([
                ("src", .string(resolved.src)),
                ("dst", .string(resolved.dst)),
            ])
        ))
    }
    return .object(entries)
}

private func orderedProjectArchiveResult(from raw: JSONValue) -> OrderedJSONValue {
    guard case .object(let object) = raw else {
        return OrderedJSONValue(raw)
    }
    var entries = orderedPipelineEntries(from: object)
    if let suggestion = object["suggestion"] {
        entries.append(("archive", orderedArchiveSuggestion(from: suggestion)))
    }
    return .object(entries)
}

private func orderedProjectArchiveResult(from result: EngramServiceProjectMoveResult) -> OrderedJSONValue {
    var entries = orderedPipelineEntries(from: result)
    if let suggestion = result.suggestion {
        entries.append(("archive", orderedArchiveSuggestion(suggestion)))
    }
    return .object(entries)
}

private func orderedProjectMoveBatchResult(from raw: JSONValue) -> OrderedJSONValue {
    guard case .object(let object) = raw else { return OrderedJSONValue(raw) }
    return .object([
        ("completed", .array(object["completed"]?.arrayValue?.map(orderedPipelineResultWithoutExtras) ?? [])),
        ("failed", OrderedJSONValue(object["failed"] ?? .array([]))),
        ("skipped", OrderedJSONValue(object["skipped"] ?? .array([]))),
    ])
}

private func orderedPipelineResult(from raw: JSONValue) -> OrderedJSONValue {
    guard case .object(let object) = raw else { return OrderedJSONValue(raw) }
    return .object(orderedPipelineEntries(from: object))
}

private func orderedPipelineResult(from result: EngramServiceProjectMoveResult) -> OrderedJSONValue {
    .object(orderedPipelineEntries(from: result))
}

private func orderedPipelineResultWithoutExtras(_ raw: JSONValue) -> OrderedJSONValue {
    guard case .object(let object) = raw else { return OrderedJSONValue(raw) }
    return .object(orderedPipelineEntries(from: object))
}

private func orderedPipelineEntries(from object: [String: JSONValue]) -> [(String, OrderedJSONValue)] {
    var entries: [(String, OrderedJSONValue)] = []
    if let migrationId = object["migrationId"] {
        entries.append(("migrationId", OrderedJSONValue(migrationId)))
    }
    if let state = object["state"] {
        entries.append(("state", OrderedJSONValue(state)))
    }
    if let moveStrategy = object["moveStrategy"] {
        entries.append(("moveStrategy", OrderedJSONValue(moveStrategy)))
    }
    if let ccDirRenamed = object["ccDirRenamed"] {
        entries.append(("ccDirRenamed", OrderedJSONValue(ccDirRenamed)))
    }
    if let renamedDirs = object["renamedDirs"] {
        entries.append(("renamedDirs", OrderedJSONValue(renamedDirs)))
    }
    if let skippedDirs = object["skippedDirs"]?.arrayValue {
        entries.append(("skippedDirs", .array(skippedDirs.map(orderedSkippedDir))))
    }
    if let perSource = object["perSource"]?.arrayValue {
        entries.append(("perSource", .array(perSource.map(orderedPerSourceResult))))
    }
    if let totalFilesPatched = object["totalFilesPatched"] {
        entries.append(("totalFilesPatched", OrderedJSONValue(totalFilesPatched)))
    }
    if let totalOccurrences = object["totalOccurrences"] {
        entries.append(("totalOccurrences", OrderedJSONValue(totalOccurrences)))
    }
    if let sessionsUpdated = object["sessionsUpdated"] {
        entries.append(("sessionsUpdated", OrderedJSONValue(sessionsUpdated)))
    }
    if let aliasCreated = object["aliasCreated"] {
        entries.append(("aliasCreated", OrderedJSONValue(aliasCreated)))
    }
    if let review = object["review"]?.objectValue {
        entries.append((
            "review",
            .object([
                ("own", OrderedJSONValue(review["own"] ?? .array([]))),
                ("other", OrderedJSONValue(review["other"] ?? .array([]))),
            ])
        ))
    }
    if let git = object["git"]?.objectValue {
        entries.append((
            "git",
            .object([
                ("isGitRepo", OrderedJSONValue(git["isGitRepo"] ?? .bool(false))),
                ("dirty", OrderedJSONValue(git["dirty"] ?? .bool(false))),
                ("untrackedOnly", OrderedJSONValue(git["untrackedOnly"] ?? .bool(false))),
                ("porcelain", OrderedJSONValue(git["porcelain"] ?? .string(""))),
            ])
        ))
    }
    if let manifest = object["manifest"] {
        entries.append(("manifest", OrderedJSONValue(manifest)))
    }
    return entries
}

private func orderedSkippedDir(_ raw: JSONValue) -> OrderedJSONValue {
    guard case .object(let object) = raw else { return OrderedJSONValue(raw) }
    return .object([
        ("sourceId", OrderedJSONValue(object["sourceId"] ?? .null)),
        ("reason", OrderedJSONValue(object["reason"] ?? .null)),
    ])
}

private func orderedPerSourceResult(_ raw: JSONValue) -> OrderedJSONValue {
    guard case .object(let object) = raw else { return OrderedJSONValue(raw) }
    return .object([
        ("id", OrderedJSONValue(object["id"] ?? .null)),
        ("root", OrderedJSONValue(object["root"] ?? .null)),
        ("filesPatched", OrderedJSONValue(object["filesPatched"] ?? .int(0))),
        ("occurrences", OrderedJSONValue(object["occurrences"] ?? .int(0))),
        ("issues", OrderedJSONValue(object["issues"] ?? .array([]))),
    ])
}

private func orderedArchiveSuggestion(from raw: JSONValue) -> OrderedJSONValue {
    guard case .object(let object) = raw else { return OrderedJSONValue(raw) }
    return .object([
        ("category", OrderedJSONValue(object["category"] ?? .null)),
        ("reason", OrderedJSONValue(object["reason"] ?? .null)),
        ("dst", OrderedJSONValue(object["dst"] ?? .null)),
    ])
}

private func orderedPipelineEntries(from result: EngramServiceProjectMoveResult) -> [(String, OrderedJSONValue)] {
    var entries: [(String, OrderedJSONValue)] = [
        ("migrationId", .string(result.migrationId)),
        ("state", .string(result.state)),
    ]
    if let moveStrategy = result.moveStrategy {
        entries.append(("moveStrategy", .string(moveStrategy)))
    }
    entries.append(("ccDirRenamed", .bool(result.ccDirRenamed)))
    if let renamedDirs = result.renamedDirs {
        entries.append(("renamedDirs", OrderedJSONValue.jsonArray(renamedDirs)))
    }
    if let skippedDirs = result.skippedDirs {
        entries.append(("skippedDirs", .array(skippedDirs.map(orderedSkippedDir))))
    }
    if let perSource = result.perSource {
        entries.append(("perSource", .array(perSource.map(orderedPerSourceResult))))
    }
    entries.append(("totalFilesPatched", .int(result.totalFilesPatched)))
    entries.append(("totalOccurrences", .int(result.totalOccurrences)))
    entries.append(("sessionsUpdated", .int(result.sessionsUpdated)))
    entries.append(("aliasCreated", .bool(result.aliasCreated)))
    entries.append((
        "review",
        .object([
            ("own", OrderedJSONValue.jsonArray(result.review.own)),
            ("other", OrderedJSONValue.jsonArray(result.review.other)),
        ])
    ))
    if let git = result.git {
        entries.append((
            "git",
            .object([
                ("isGitRepo", .bool(git.isGitRepo)),
                ("dirty", .bool(git.dirty)),
                ("untrackedOnly", .bool(git.untrackedOnly)),
                ("porcelain", .string(git.porcelain)),
            ])
        ))
    }
    if let manifest = result.manifest {
        entries.append(("manifest", .array(manifest.map(orderedManifestEntry))))
    }
    return entries
}

private func orderedManifestEntry(_ entry: EngramServiceProjectMoveResult.ManifestEntry) -> OrderedJSONValue {
    .object([
        ("path", .string(entry.path)),
        ("occurrences", .int(entry.occurrences)),
    ])
}

private func orderedSkippedDir(_ item: EngramServiceProjectMoveResult.SkippedDir) -> OrderedJSONValue {
    .object([
        ("sourceId", .string(item.sourceId)),
        ("reason", .string(item.reason)),
    ])
}

private func orderedPerSourceResult(_ item: EngramServiceProjectMoveResult.PerSource) -> OrderedJSONValue {
    .object([
        ("id", .string(item.id)),
        ("root", .string(item.root)),
        ("filesPatched", .int(item.filesPatched)),
        ("occurrences", .int(item.occurrences)),
        ("issues", .array((item.issues ?? []).map(orderedWalkIssue))),
    ])
}

private func orderedWalkIssue(_ item: EngramServiceProjectMoveResult.PerSource.WalkIssue) -> OrderedJSONValue {
    var entries: [(String, OrderedJSONValue)] = [
        ("path", .string(item.path)),
        ("reason", .string(item.reason)),
    ]
    if let detail = item.detail {
        entries.append(("detail", .string(detail)))
    }
    return .object(entries)
}

private func orderedArchiveSuggestion(_ suggestion: EngramServiceProjectMoveResult.ArchiveSuggestion) -> OrderedJSONValue {
    .object([
        ("category", suggestion.category.map(OrderedJSONValue.string) ?? .null),
        ("reason", .string(suggestion.reason)),
        ("dst", .string(suggestion.dst)),
    ])
}

private extension OrderedJSONValue {
    static func jsonArray(_ values: [String]) -> OrderedJSONValue {
        .array(values.map(OrderedJSONValue.string))
    }
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

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message):
            return message
        }
    }
}

extension OrderedJSONValue {
    static func toolSuccess(_ structured: OrderedJSONValue) -> OrderedJSONValue {
        .object([
            ("content", .array([
                .object([
                    ("type", .string("text")),
                    ("text", .string(structured.prettyJSONString())),
                ]),
            ])),
            ("structuredContent", structured),
        ])
    }

    static func toolError(message: String) -> OrderedJSONValue {
        .object([
            ("content", .array([
                .object([
                    ("type", .string("text")),
                    ("text", .string(message)),
                ]),
            ])),
            ("isError", .bool(true)),
        ])
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
