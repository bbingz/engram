# coding-memory MCP Server 设计文档

**日期：** 2026-02-27
**状态：** 已审批，待实现

---

## 项目概述

`coding-memory` 是一个 MCP Server，读取多个 AI 编程助手（Codex、Claude Code、Gemini CLI、OpenCode）的本地会话日志，让这些工具之间能共享历史上下文。

**核心价值：** 在 Codex 里做了半天工作切到 Claude Code 继续时，不需要手动解释之前做了什么，AI 助手可以直接查询历史。

---

## 第一部分：整体架构

### 技术选型

- **运行时：** Node.js + TypeScript
- **MCP SDK：** `@modelcontextprotocol/sdk`
- **数据库：** `better-sqlite3`（同步 API，简单可靠）
- **文件监听：** `chokidar`
- **配置：** `js-yaml` 读取 `config.yaml`

### 启动逻辑

1. 第一次启动：扫描所有会话文件，在 `~/.coding-memory/index.sqlite` 建立索引
2. 后续启动：`chokidar` 监听文件变化，增量更新索引
3. 大文件（如 200MB 的 Codex 会话）永远不整体加载——索引只存元信息和摘要，消息按需流式读取

### 项目结构

```
coding-memory/
├── src/
│   ├── index.ts                  # MCP server 入口
│   ├── adapters/                 # 各工具的日志解析适配器
│   │   ├── types.ts              # 统一接口定义
│   │   ├── codex.ts              # Codex：~/.codex/sessions/
│   │   ├── claude-code.ts        # Claude Code：~/.claude/projects/
│   │   ├── gemini-cli.ts         # Gemini CLI：~/.gemini/tmp/
│   │   └── opencode.ts           # OpenCode：SQLite + JSON
│   ├── core/
│   │   ├── db.ts                 # SQLite 操作（better-sqlite3）
│   │   ├── indexer.ts            # 全量扫描 + 增量更新
│   │   ├── watcher.ts            # 文件变更监听（chokidar）
│   │   └── project.ts            # cwd → 项目名（读 git remote）
│   └── tools/                    # MCP tools，各一个文件
│       ├── list_sessions.ts
│       ├── get_session.ts
│       ├── search.ts
│       ├── project_timeline.ts
│       ├── get_context.ts
│       ├── stats.ts
│       └── export.ts
├── config.yaml
└── package.json
```

---

## 第二部分：数据模型

### 统一会话结构

```typescript
interface SessionInfo {
  id: string
  source: 'codex' | 'claude-code' | 'gemini-cli' | 'opencode'
  startTime: string          // ISO 时间戳
  endTime?: string
  cwd: string                // 工作目录
  project?: string           // 解析后的项目名（来自 git remote 或目录名）
  model?: string             // 使用的模型
  messageCount: number       // 总消息数
  userMessageCount: number   // 用户消息数
  summary?: string           // 首条用户消息（作为摘要）
  filePath: string           // 原始文件路径
  sizeBytes: number          // 原始文件大小
}
```

### 统一消息结构

```typescript
interface Message {
  role: 'user' | 'assistant' | 'system' | 'tool'
  content: string
  timestamp?: string
  toolCalls?: {
    name: string
    input?: string
    output?: string
  }[]
}
```

### SQLite 索引表

```sql
-- 会话元信息表
CREATE TABLE sessions (
  id TEXT PRIMARY KEY,
  source TEXT NOT NULL,
  start_time TEXT NOT NULL,
  end_time TEXT,
  cwd TEXT,
  project TEXT,
  model TEXT,
  message_count INTEGER,
  user_message_count INTEGER,
  summary TEXT,
  file_path TEXT NOT NULL,
  size_bytes INTEGER,
  indexed_at TEXT NOT NULL
);

-- 全文搜索（只索引用户消息，避免索引过大）
CREATE VIRTUAL TABLE sessions_fts USING fts5(
  session_id,
  content,
  role
);
```

---

## 第三部分：MCP Tools

### `get_context`（核心功能）

为当前任务自动提取相关历史上下文。

- **输入：** `cwd`（当前目录）、`task?`（任务描述）、`max_tokens?`（默认 4000）
- **输出：** 按相关性排序的历史片段，总长度不超过 token 预算
- **逻辑：** 按 cwd 匹配项目 → 时间倒序 → 摘要拼接直到 token 用完

### `list_sessions`

列出会话，支持过滤。

- **输入：** `source?`、`project?`、`since?`、`until?`、`limit?`（默认 20）、`offset?`
- **输出：** `SessionInfo[]`

### `get_session`

读取单个会话完整对话，支持分页。

- **输入：** `id`、`page?`（每页 50 条）、`roles?`（可只看 user/assistant）
- **输出：** `{ session, messages, totalPages }`

### `search`

全文搜索（SQLite FTS5，毫秒级响应）。

- **输入：** `query`、`source?`、`project?`、`since?`、`limit?`
- **输出：** 匹配会话列表 + 高亮片段

### `project_timeline`

某项目跨工具的操作时间线。

- **输入：** `project`（项目名或路径片段）、`since?`、`until?`
- **输出：** 按时间排序的 `{ time, source, summary, sessionId }[]`

### `stats`

用量统计。

- **输入：** `since?`、`until?`、`group_by?`（source/project/day/week）
- **输出：** 各维度的会话数、消息数

### `export`

导出单个会话。

- **输入：** `id`、`format`（'markdown' | 'json'）、`outputPath?`
- **输出：** 文件内容或保存路径

---

## 第四部分：适配器实现

### 统一接口

```typescript
interface SessionAdapter {
  name: string
  detect(): Promise<boolean>
  listSessionFiles(): AsyncGenerator<string>
  parseSessionInfo(filePath: string): Promise<SessionInfo>
  streamMessages(filePath: string, opts?: {
    offset?: number
    limit?: number
  }): AsyncGenerator<Message>
}
```

### Codex 适配器

- **路径：** `~/.codex/sessions/YYYY/MM/DD/*.jsonl`
- **解析：** 逐行读取，取 `type == "response_item"` 且 `payload.type == "message"` 的记录
- **元信息：** 来自第一条 `session_meta` 记录（含 cwd、model、timestamp）
- **关键：** 逐行流式读取，不整体 `JSON.parse`

### Claude Code 适配器

- **路径：** `~/.claude/projects/*/`
- **格式：** JSONL
- **项目名：** 从目录名解码（`-Users-bing--Code--project` → `/Users/bing/-Code-/project`）

### Gemini CLI 适配器

- **路径：** `~/.gemini/tmp/<project_hash>/chats/*.json`
- **格式：** 标准 JSON（文件较小，可直接 `JSON.parse`）
- **难点：** project_hash 不可读，从会话内容的 `cwd` 字段反推项目

### OpenCode 适配器

- **路径：** `~/.local/share/opencode/storage/`
- **格式：** 混合——会话元信息在 `session/<hash>/<sessionID>.json`，消息在 `message/<sessionID>/msg_*.json`（每条消息一个文件）
- **读取：** 先读 session 文件获取元信息，消息按需遍历目录

---

## 注册方式

### Claude Code

```json
// ~/.claude/settings.json
{
  "mcpServers": {
    "coding-memory": {
      "command": "node",
      "args": ["/path/to/coding-memory/dist/index.js"]
    }
  }
}
```

### Codex

```toml
# ~/.codex/config.toml
[mcp_servers.coding-memory]
command = "node"
args = ["/path/to/coding-memory/dist/index.js"]
```

---

## 实现优先级

1. **MVP：** Codex + Claude Code 适配器 + `list_sessions` + `get_session` + `search` + SQLite 索引
2. **v1.1：** Gemini CLI + OpenCode 适配器 + `project_timeline` + `stats` + file watcher
3. **v1.2：** `get_context` 智能上下文 + `export`
