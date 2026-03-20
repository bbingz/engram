# Engram

> MCP Server + Web UI：聚合 15 种 AI 编程助手的历史会话，实现跨工具上下文共享、混合搜索和多机同步。

在 Codex 里做了半天，切到 Claude Code 继续时，AI 不需要你手动解释之前做了什么——它可以直接调用 `get_context` 查询你的历史。

```
┌─────────┐ ┌───────────┐ ┌──────────┐ ┌──────────┐ ┌─────────┐
│  Codex  │ │Claude Code│ │Gemini CLI│ │  Cursor  │ │ Cline …│
│ sessions│ │ projects  │ │   tmp    │ │  vscdb   │ │  tasks  │
└────┬────┘ └─────┬─────┘ └────┬─────┘ └────┬─────┘ └────┬────┘
     └────────────┴──────┬─────┴─────────────┴────────────┘
                         ▼
              ┌──────────────────────┐
              │       engram         │
              │    MCP + Web + Sync  │
              │    ~/.engram/        │
              │    index.sqlite      │
              └──────────┬───────────┘
                    ┌────┴────┐
                    ▼         ▼
                MCP Tools   Web UI
              (AI 调用)   (浏览器)
```

## 目录

- [支持的工具](#支持的工具)
- [快速上手](#快速上手)
- [注册为 MCP Server](#注册为-mcp-server)
- [Web UI](#web-ui)
- [MCP Tools 参考](#mcp-tools-参考)
- [混合搜索](#混合搜索)
- [项目别名](#项目别名)
- [多机同步](#多机同步)
- [配置](#配置)
- [添加新适配器](#添加新适配器)
- [数据存储与隐私](#数据存储与隐私)
- [开发](#开发)

## 支持的工具

| 工具 | 日志路径 | 状态 |
|------|---------|------|
| [Codex CLI](https://github.com/openai/codex) | `~/.codex/sessions/` | ✅ 完整支持 |
| [Claude Code](https://claude.ai/code) | `~/.claude/projects/` | ✅ 完整支持 |
| [Gemini CLI](https://github.com/google-gemini/gemini-cli) | `~/.gemini/tmp/` | ✅ 完整支持 |
| [Antigravity](https://idx.google.com) | gRPC + `~/.gemini/antigravity/` | ✅ 完整支持 |
| [Windsurf](https://codeium.com/windsurf) | gRPC + `~/.codeium/windsurf/` | ✅ 完整支持 |
| [Cursor](https://cursor.sh) | `~/Library/Application Support/Cursor/…/state.vscdb` | ✅ 完整支持 |
| [VS Code Copilot](https://code.visualstudio.com) | `~/Library/Application Support/Code/…/chatSessions/` | ✅ 完整支持 |
| [GitHub Copilot](https://github.com/features/copilot) | `~/Library/Application Support/Code/…/chatSessions/` | ✅ 完整支持 |
| [iflow](https://iflow.ai) | `~/.iflow/projects/` | ✅ 完整支持 |
| [Qwen Code](https://qwen.ai) | `~/.qwen/projects/` | ✅ 完整支持 |
| [OpenCode](https://opencode.ai) | `~/.local/share/opencode/opencode.db` | ✅ 完整支持 |
| [Kimi](https://kimi.moonshot.cn) | `~/.kimi/sessions/` | ✅ 完整支持 |
| [MiniMax](https://minimax.chat) | `~/.minimax/sessions/` | ✅ 完整支持 |
| [Lobster AI](https://lobster.ai) | `~/.lobsterai/sessions/` | ✅ 完整支持 |
| [Cline](https://github.com/cline/cline) | `~/.cline/data/tasks/` | ✅ 完整支持 |

## 快速上手

**前置要求：** Node.js 18+

```bash
# 1. 克隆并构建
git clone https://github.com/bbingz/engram
cd engram
npm install && npm run build

# 2. 注册到你使用的 AI 工具（见下一节）

# 3. 重启 AI 工具，在对话中调用：
# get_context cwd=/your/project/path
```

首次启动时，MCP Server 会自动扫描所有会话文件并建立索引（存储在 `~/.engram/index.sqlite`）。之后通过文件监听增量更新，无需手动维护。

## 注册为 MCP Server

### Claude Code

```bash
claude mcp add --scope user engram node /absolute/path/to/engram/dist/index.js
```

或者手动编辑 `~/.claude/settings.json`：

```json
{
  "mcpServers": {
    "engram": {
      "command": "node",
      "args": ["/absolute/path/to/engram/dist/index.js"]
    }
  }
}
```

### Codex

编辑 `~/.codex/config.toml`：

```toml
[mcp_servers.engram]
command = "node"
args = ["/absolute/path/to/engram/dist/index.js"]
```

### 其他支持 MCP 的客户端

任何支持 MCP stdio transport 的客户端均可使用。将以下内容加入对应的 MCP 配置：

```json
{
  "command": "node",
  "args": ["/absolute/path/to/engram/dist/index.js"]
}
```

## Web UI

Engram 内置 Web 界面，通过 daemon 进程自动启动，默认监听 `http://127.0.0.1:3457`。

```bash
# 启动 daemon（包含 Web UI + 索引器 + 文件监听）
node dist/daemon.js
```

Web UI 功能：
- **会话列表**：按来源、项目、时间筛选，支持多选过滤和分页
- **会话详情**：完整对话内容，Markdown 渲染
- **混合搜索**：FTS 关键词 + 语义向量搜索，实时高亮
- **用量统计**：按来源 / 项目 / 天 / 周分组统计
- **同步设置**：配置多机同步节点

API 端点：
- `GET /api/sessions` — 会话列表（支持 source、project、since、limit、offset）
- `GET /api/sessions/:id` — 会话详情
- `GET /api/search?q=...` — 混合搜索（支持 source、project、since、mode、UUID 直查）
- `GET /api/search/semantic?q=...` — 纯语义搜索
- `GET /api/search/status` — embedding 状态（可用性、模型、进度）
- `GET /api/stats` — 用量统计
- `GET /api/project-aliases` — 列出项目别名
- `POST /api/project-aliases` — 添加别名
- `DELETE /api/project-aliases` — 删除别名
- `GET /api/sync/status` — 同步状态
- `POST /api/sync/trigger` — 手动触发同步

## MCP Tools 参考

### `get_context` — 核心工具

为当前工作目录自动提取相关历史上下文。**在开始新任务时调用**，获取该项目的历史记录。支持语义搜索增强（需配置 embedding provider）。

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
| `source` | string | `codex` / `claude-code` / `copilot` / `gemini-cli` / `antigravity` / `windsurf` / `cursor` / `vscode` / `opencode` / `iflow` / `qwen` / `kimi` / `minimax` / `lobsterai` / `cline` |
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

### `search` — 混合搜索

在所有会话内容中搜索，支持三种模式：关键词（FTS5 trigram）、语义向量搜索、混合模式（RRF 融合排序）。

**参数：**

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `query` | string | ✅ | 搜索关键词（关键词搜索至少 3 字符，语义搜索至少 2 字符） |
| `source` | string | — | 限定工具来源 |
| `project` | string | — | 限定项目 |
| `since` | string | — | 限定时间范围 |
| `limit` | number | — | 默认 10，最大 50 |
| `mode` | string | — | `hybrid`（默认）/ `keyword` / `semantic` |

**示例：**

```json
{ "query": "JWT 认证", "source": "claude-code", "mode": "hybrid" }
```

**返回：** 每条结果包含会话元数据、高亮文本片段（`<mark>` 标签）、匹配类型（keyword / semantic / both）和融合分数。

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

### `generate_summary` — AI 摘要生成

使用 AI 为指定会话生成摘要，并更新到数据库中。需要在 `~/.engram/settings.json` 中配置 OpenAI 或 Anthropic API Key。

**参数：**

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `sessionId` | string | ✅ | 会话 ID |

**示例：**

```json
{ "sessionId": "019c9d89-e65c-7df0-9e7a-ca361961f6a5" }
```

**返回：** 生成的摘要文本。

---

### `link_sessions` — 链接会话文件

将某项目的所有 AI 会话文件以符号链接形式集中到项目目录下的 `conversation_log/<source>/`，方便查看和管理。

**参数：**

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `targetDir` | string | ✅ | 项目目录（绝对路径），自动从 basename 推导项目名 |

**示例：**

```json
{ "targetDir": "/Users/me/my-project" }
```

**返回：** `created`（新建链接数）、`skipped`（已存在跳过数）、`errors`（错误列表）

---

### `get_memory` — 记忆检索

从历史会话中提取的记忆信息中搜索。需要配置 OpenViking。

**参数：**

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `query` | string | ✅ | 要回忆的内容，如 "用户的编码偏好" |

**示例：**

```json
{ "query": "用户的编码偏好" }
```

**返回：** 匹配的记忆列表。未配置 OpenViking 时返回空列表和配置提示。

---

### `manage_project_alias` — 项目别名管理

声明两个项目名是同一个项目，所有按项目过滤的查询自动展开别名。详见[项目别名](#项目别名)。

**参数：**

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `action` | string | ✅ | `add` / `remove` / `list` |
| `old_project` | string | add/remove | 旧项目名 |
| `new_project` | string | add/remove | 新项目名 |

**示例：**

```json
{ "action": "add", "old_project": "wechat-decrypt", "new_project": "wechat-decrypt-bing" }
```

---

## 混合搜索

Engram 支持三种搜索模式，默认使用混合模式自动融合：

| 模式 | 技术 | 适用场景 |
|------|------|----------|
| **keyword** | SQLite FTS5 trigram 索引 | 精确匹配关键词、代码片段、函数名 |
| **semantic** | Embedding 向量 + sqlite-vec KNN | 语义相似，如「认证」匹配「登录鉴权」 |
| **hybrid** | RRF 融合排序 (k=60) | 两者结合，覆盖面最广 |

搜索覆盖范围：用户消息 + 助手回复 + 会话摘要。

搜索还支持**直接粘贴会话 UUID** 进行精确查找，无需关键词或语义匹配。

### 配置语义搜索

语义搜索需要 embedding provider。在 `~/.engram/settings.json` 中配置：

**Ollama（推荐，本地/远程均可）：**

```json
{
  "ollamaUrl": "http://10.0.8.107:11434",
  "ollamaModel": "qwen3-embedding:4b",
  "embeddingDimension": 2560
}
```

**OpenAI：**

```json
{
  "openaiApiKey": "sk-..."
}
```

支持的 embedding provider：
- **Ollama**：默认 `localhost:11434` + `nomic-embed-text` (768 维)，可配置远程地址、模型和维度
- **OpenAI**：使用 `text-embedding-3-small` (1536 维)

向量维度变化时（如从 768 切换到 2560），向量表会自动重建并重新索引。

未配置时自动降级为纯关键词搜索。

## 项目别名

当你移动了项目目录（例如从 `~/Code/wechat-decrypt` 移到 `~/Code/wechat-decrypt-bing`），AI 助手会找不到旧路径下的历史会话。通过项目别名，可以声明两个项目名是同一个项目，所有查询自动展开。

### 添加别名

**通过 MCP 工具（在 AI 对话中）：**

```json
{ "name": "manage_project_alias", "arguments": { "action": "add", "old_project": "wechat-decrypt", "new_project": "wechat-decrypt-bing" } }
```

**通过 Web API：**

```bash
curl -X POST http://127.0.0.1:3457/api/project-aliases \
  -H 'Content-Type: application/json' \
  -d '{"alias": "wechat-decrypt", "canonical": "wechat-decrypt-bing"}'
```

**通过 Web UI：** Settings 页面 → Project Aliases 区域，输入两个项目名并点击添加。

添加后，在任意路径下调用 `get_context`、`search`、`list_sessions` 等工具，两个项目名的会话都会出现。别名是双向的——查哪个名字都能找到另一个。

### 管理别名

```json
// 列出所有别名
{ "action": "list" }

// 删除别名
{ "action": "remove", "old_project": "wechat-decrypt", "new_project": "wechat-decrypt-bing" }
```

> **注意：** 项目别名解决的是 Engram 层面的查询问题。各 AI 工具自身的 `/resume` 等功能仍然依赖原始路径，这不在 Engram 的控制范围内。

## 多机同步

Engram 支持多台机器之间同步会话索引（pull-based）。

### 配置

编辑 `~/.engram/settings.json`：

```json
{
  "syncNodeName": "macbook-pro",
  "syncEnabled": true,
  "syncIntervalMinutes": 10,
  "syncPeers": [
    { "name": "desktop", "url": "http://192.168.1.100:3457" }
  ]
}
```

也可通过 Web UI 的 Settings 页面配置。

### 工作原理

- 每台机器运行 daemon 并暴露 `/api/sync/sessions` 端点
- 定时从配置的 peer 拉取新增/更新的会话元数据
- 使用 `indexed_at` 游标分页，增量同步
- 同步的会话标记 `origin` 为来源机器名
- 仅同步元数据（ID、摘要、时间等），不同步完整对话内容

## 配置

配置文件路径：`~/.engram/settings.json`

```json
{
  "httpPort": 3457,
  "aiProvider": "openai",
  "openaiApiKey": "sk-...",
  "syncNodeName": "my-machine",
  "syncEnabled": false,
  "syncIntervalMinutes": 10,
  "syncPeers": []
}
```

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `httpPort` | number | `3457` | Web UI 监听端口 |
| `aiProvider` | string | `"openai"` | AI 摘要生成器：`openai` 或 `anthropic` |
| `openaiApiKey` | string | — | OpenAI API Key（用于摘要生成和语义搜索） |
| `openaiModel` | string | `"gpt-4o-mini"` | OpenAI 摘要模型 |
| `anthropicApiKey` | string | — | Anthropic API Key |
| `anthropicModel` | string | `"claude-3-haiku-20240307"` | Anthropic 摘要模型 |
| `ollamaUrl` | string | `"http://localhost:11434"` | Ollama 服务地址（支持远程） |
| `ollamaModel` | string | `"nomic-embed-text"` | Ollama embedding 模型 |
| `embeddingDimension` | number | `768` | 向量维度（需与模型输出维度匹配） |
| `syncNodeName` | string | `"unnamed"` | 当前节点名称 |
| `syncEnabled` | boolean | `false` | 是否启用同步 |
| `syncIntervalMinutes` | number | `10` | 同步间隔（分钟） |
| `syncPeers` | array | `[]` | 同步节点列表 `[{ name, url }]` |

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
3. 在 `src/core/bootstrap.ts` 的 `createAdapters()` 中注册新适配器
4. 在 `src/core/watcher.ts` 中添加对应的监听路径
5. 参照现有测试（`tests/adapters/codex.test.ts`）编写测试

**实现参考：** `src/adapters/codex.ts` 是最完整的参考实现，包含 JSONL 逐行流式读取、系统注入消息过滤、元数据提取等完整逻辑。

## 数据存储与隐私

- **索引库位置：** `~/.engram/index.sqlite`，存储元数据（会话 ID、时间、路径、摘要）、FTS 全文搜索索引和 embedding 向量
- **原始文件：** 完整消息内容始终从 AI 工具的原始日志文件流式读取，不做额外拷贝
- **隐私脱敏：** 可在配置中设置正则，匹配内容在建立索引时会被替换为 `[REDACTED]`
- **数据不离本机：** MCP Server 和 Web UI 本地运行（`127.0.0.1`），不向任何远程服务发送数据（除非启用同步或使用 OpenAI embedding）

## 开发

```bash
npm test              # 运行测试（278 tests）
npm run test:watch    # 监听模式
npm run test:coverage # 覆盖率报告
npm run build         # 编译 TypeScript -> dist/
npm run dev           # 开发模式（tsx 直接运行，无需编译）
```

macOS 应用（Menu Bar）：

```bash
cd macos
xcodegen generate     # 从 project.yml 生成 Xcode 项目
open Engram.xcodeproj # 在 Xcode 中构建和运行
```

## License

MIT
