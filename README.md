# coding-memory

> MCP Server：聚合多个 AI 编程助手的历史会话，实现跨工具上下文共享。

在 Codex 里做了半天，切到 Claude Code 继续时，AI 不需要你手动解释之前做了什么——它可以直接调用 `get_context` 查询你的历史。

```
┌─────────────┐   ┌──────────────┐   ┌─────────────────┐
│ Codex CLI   │   │ Claude Code  │   │   Gemini CLI    │
│  sessions   │   │   projects   │   │      tmp        │
└──────┬──────┘   └──────┬───────┘   └────────┬────────┘
       │                 │                    │
       └─────────────────┼────────────────────┘
                         ▼
              ┌──────────────────────┐
              │   coding-memory      │
              │   (MCP Server)       │
              │  ~/.coding-memory/   │
              │   index.sqlite       │
              └──────────┬───────────┘
                         │  MCP
           ┌─────────────┼─────────────┐
           ▼             ▼             ▼
       Codex        Claude Code    Gemini CLI
   (下一个会话)    (下一个会话)   (下一个会话)
```

## 目录

- [支持的工具](#支持的工具)
- [快速上手](#快速上手)
- [注册为 MCP Server](#注册为-mcp-server)
- [MCP Tools 参考](#mcp-tools-参考)
- [配置](#配置)
- [添加新适配器](#添加新适配器)
- [数据存储与隐私](#数据存储与隐私)

## 支持的工具

| 工具 | 日志路径 | 状态 |
|------|---------|------|
| [Codex CLI](https://github.com/openai/codex) | `~/.codex/sessions/` | ✅ 完整支持 |
| [Claude Code](https://claude.ai/code) | `~/.claude/projects/` | ✅ 完整支持 |
| [Gemini CLI](https://github.com/google-gemini/gemini-cli) | `~/.gemini/tmp/` | ✅ 完整支持 |
| [iflow](https://iflow.ai) | `~/.iflow/projects/` | ✅ 完整支持 |
| [Qwen Code](https://qwen.ai) | `~/.qwen/projects/` | ✅ 完整支持 |
| [OpenCode](https://opencode.ai) | `~/.local/share/opencode/opencode.db` | ✅ 完整支持 |
| [Kimi](https://kimi.moonshot.cn) | `~/.kimi/sessions/` | ✅ 完整支持 |
| [Cline CLI](https://github.com/cline/cline) | `~/.cline/data/tasks/` | ✅ 完整支持 |

## 快速上手

**前置要求：** Node.js 18+

```bash
# 1. 克隆并构建
git clone https://github.com/bbingz/coding-memory
cd coding-memory
npm install && npm run build

# 2. 注册到你使用的 AI 工具（见下一节）

# 3. 重启 AI 工具，在对话中调用：
# get_context cwd=/your/project/path
```

首次启动时，MCP Server 会自动扫描所有会话文件并建立索引（存储在 `~/.coding-memory/index.sqlite`）。之后通过文件监听增量更新，无需手动维护。

## 注册为 MCP Server

### Claude Code

```bash
claude mcp add --scope user coding-memory node /absolute/path/to/coding-memory/dist/index.js
```

或者手动编辑 `~/.claude/settings.json`：

```json
{
  "mcpServers": {
    "coding-memory": {
      "command": "node",
      "args": ["/absolute/path/to/coding-memory/dist/index.js"]
    }
  }
}
```

### Codex

编辑 `~/.codex/config.toml`：

```toml
[mcp_servers.coding-memory]
command = "node"
args = ["/absolute/path/to/coding-memory/dist/index.js"]
```

### 其他支持 MCP 的客户端

任何支持 MCP stdio transport 的客户端均可使用。将以下内容加入对应的 MCP 配置：

```json
{
  "command": "node",
  "args": ["/absolute/path/to/coding-memory/dist/index.js"]
}
```

## MCP Tools 参考

### `get_context` — 核心工具

为当前工作目录自动提取相关历史上下文。**在开始新任务时调用**，获取该项目的历史记录。

**参数：**

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `cwd` | string | ✅ | 当前工作目录（绝对路径） |
| `task` | string | — | 当前任务描述，会附在上下文开头 |
| `max_tokens` | number | — | token 预算，默认 4000 |

**示例：**

```json
{
  "cwd": "/Users/me/my-project",
  "task": "重构认证模块"
}
```

**返回：** `contextText`（直接可读的上下文摘要）+ `sessions`（匹配的会话列表）+ `estimatedTokens`

---

### `list_sessions` — 列出会话

列出历史会话，支持按工具来源、项目、时间范围过滤。

**参数：**

| 参数 | 类型 | 说明 |
|------|------|------|
| `source` | string | `codex` / `claude-code` / `gemini-cli` / `opencode` / `iflow` / `qwen` / `kimi` / `cline` |
| `project` | string | 项目名关键词（部分匹配） |
| `since` | string | 开始时间（ISO 8601），如 `2026-01-01` |
| `until` | string | 结束时间（ISO 8601） |
| `limit` | number | 最多返回条数，默认 20，最大 100 |
| `offset` | number | 分页偏移量 |

**示例：**

```json
{ "source": "codex", "project": "my-project", "limit": 10 }
```

---

### `get_session` — 读取会话内容

读取单个会话的完整对话内容，大会话支持分页（每页 50 条消息）。

**参数：**

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `id` | string | ✅ | 会话 ID（从 `list_sessions` 或 `search` 获取） |
| `page` | number | — | 页码，从 1 开始，默认 1 |
| `roles` | array | — | 只返回指定角色，如 `["user"]` |

**示例：**

```json
{ "id": "019c9d89-e65c-7df0-9e7a-ca361961f6a5", "page": 1, "roles": ["user", "assistant"] }
```

---

### `search` — 全文搜索

在所有会话内容中全文搜索，支持中英文，基于 SQLite FTS5 trigram 索引，毫秒级响应。

**参数：**

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `query` | string | ✅ | 搜索关键词（至少 3 个字符） |
| `source` | string | — | 限定工具来源 |
| `project` | string | — | 限定项目 |
| `since` | string | — | 限定时间范围 |
| `limit` | number | — | 默认 10，最大 50 |

**示例：**

```json
{ "query": "JWT 认证", "source": "claude-code" }
```

**返回：** 每条结果包含会话元数据和匹配位置的文本片段（snippet）。

---

### `project_timeline` — 项目时间线

查看某个项目跨工具的操作时间线，了解在不同 AI 助手中分别做了什么、先后顺序如何。

**参数：**

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `project` | string | ✅ | 项目名或路径片段 |
| `since` | string | — | 开始时间 |
| `until` | string | — | 结束时间 |

**示例：**

```json
{ "project": "my-project", "since": "2026-01-01" }
```

---

### `stats` — 用量统计

统计各工具的会话数量、消息数等数据，支持按不同维度分组。

**参数：**

| 参数 | 类型 | 说明 |
|------|------|------|
| `group_by` | string | `source`（默认）/ `project` / `day` / `week` |
| `since` | string | 开始时间 |
| `until` | string | 结束时间 |

**示例：**

```json
{ "group_by": "day", "since": "2026-02-01" }
```

---

### `export` — 导出会话

将单个会话导出为 Markdown 或 JSON 文件，保存到 `~/codex-exports/` 目录。

**参数：**

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `id` | string | ✅ | 会话 ID |
| `format` | string | — | `markdown`（默认）或 `json` |

**示例：**

```json
{ "id": "019c9d89-...", "format": "markdown" }
```

**返回：** 导出文件的路径。

---

## 配置

配置文件为可选项，不存在时使用默认路径。将 `config.yaml` 放置在项目根目录即可自动读取。

```yaml
# 数据源配置
sources:
  codex:
    enabled: true
    # paths:
    #   - ~/.codex/sessions   # 可覆盖默认路径

  claude-code:
    enabled: true

  gemini-cli:
    enabled: true

  opencode:
    enabled: true

# 索引数据库路径
index:
  db_path: ~/.coding-memory/index.sqlite

# 隐私：敏感信息脱敏（正则匹配，在索引时过滤）
privacy:
  redact_patterns:
    - 'sk-[a-zA-Z0-9]{20,}'      # OpenAI API Key
    - 'AKIA[A-Z0-9]{16}'          # AWS Access Key
```

## 添加新适配器

实现 `SessionAdapter` 接口即可支持新的 AI 工具。

**接口定义（`src/adapters/types.ts`）：**

```typescript
interface SessionAdapter {
  readonly name: SourceName          // 工具标识符
  detect(): Promise<boolean>         // 检测该工具是否已安装
  listSessionFiles(): AsyncGenerator<string>                   // 枚举所有会话文件路径
  parseSessionInfo(filePath: string): Promise<SessionInfo | null>  // 解析文件元数据
  streamMessages(filePath: string, opts?: StreamMessagesOptions): AsyncGenerator<Message>  // 流式读取消息
}
```

**步骤：**

1. 在 `src/adapters/types.ts` 的 `SourceName` 联合类型中添加新工具名称
2. 新建 `src/adapters/<tool-name>.ts`，实现 `SessionAdapter` 接口
3. 在 `src/index.ts` 中将新适配器加入 `adapters` 数组
4. 在 `src/core/watcher.ts` 中添加对应的监听路径
5. 参照现有测试（`tests/adapters/codex.test.ts`）编写测试

**实现参考：** `src/adapters/codex.ts` 是最完整的参考实现，包含 JSONL 逐行流式读取、系统注入消息过滤、元数据提取等完整逻辑。

## 数据存储与隐私

- **索引库位置：** `~/.coding-memory/index.sqlite`，仅存储元数据（会话 ID、时间、路径、摘要）和全文搜索索引，不存储完整对话内容。
- **原始文件：** 完整消息内容始终从 AI 工具的原始日志文件流式读取，不做额外拷贝。
- **隐私脱敏：** 可在 `config.yaml` 的 `privacy.redact_patterns` 中配置正则，匹配内容在建立搜索索引时会被替换为 `[REDACTED]`。
- **数据不离本机：** MCP Server 本地运行，所有数据存储和检索均在本地完成，不向任何远程服务发送数据。

## 开发

```bash
npm test              # 运行测试（59 tests）
npm run test:watch    # 监听模式
npm run test:coverage # 覆盖率报告
npm run build         # 编译 TypeScript → dist/
npm run dev           # 开发模式（tsx 直接运行，无需编译）
```

## License

MIT
