# Engram

> Native Swift MCP helper + macOS App：聚合 17 种 AI 编程助手的历史会话，实现跨工具上下文共享、关键词搜索和项目迁移。

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
              │  Swift MCP + App UI  │
              │    ~/.engram/        │
              │    index.sqlite      │
              └──────────┬───────────┘
                    ┌────┴────┐
                    ▼         ▼
                MCP Tools   macOS App
              (AI 调用)   (桌面 UI)
```

## 目录

- [支持的工具](#支持的工具)
- [适配器与显示一致性](#适配器与显示一致性)
- [快速上手](#快速上手)
- [注册为 MCP Server](#注册为-mcp-server)
- [macOS App](#macos-app)
- [MCP Tools 参考](#mcp-tools-参考)
- [搜索现状](#搜索现状)
- [项目别名](#项目别名)
- [Peer Sync 状态](#peer-sync-状态)
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
| [Antigravity](https://idx.google.com) | CLI brain `~/.gemini/antigravity-cli/brain/` + legacy gRPC cache | ✅ 完整支持 |
| [Windsurf](https://codeium.com/windsurf) | gRPC + `~/.codeium/windsurf/` | ✅ 完整支持 |
| [Cursor](https://cursor.sh) | `~/Library/Application Support/Cursor/…/state.vscdb` | ✅ 完整支持 |
| [VS Code Copilot](https://code.visualstudio.com) | `~/Library/Application Support/Code/…/chatSessions/` | ✅ 完整支持 |
| [GitHub Copilot](https://github.com/features/copilot) | `~/.copilot/session-state/<uuid>/events.jsonl` | ✅ 完整支持 |
| [iflow](https://iflow.ai) | `~/.iflow/projects/` | ✅ 完整支持 |
| [Qwen Code](https://qwen.ai) | `~/.qwen/projects/` | ✅ 完整支持 |
| Qoder | `~/.qoder/projects/` | ✅ 完整支持 |
| [OpenCode](https://opencode.ai) | `~/.local/share/opencode/opencode.db` | ✅ 完整支持 |
| [Kimi](https://kimi.moonshot.cn) | `~/.kimi/sessions/` | ✅ 完整支持 |
| [MiniMax](https://minimax.chat) | `~/.minimax/sessions/` | ✅ 完整支持 |
| [Lobster AI](https://lobster.ai) | `~/.lobsterai/sessions/` | ✅ 完整支持 |
| Command Code | `~/.commandcode/projects/` | ✅ 完整支持 |
| [Cline](https://github.com/cline/cline) | `~/.cline/data/tasks/` | ✅ 完整支持 |

## 适配器与显示一致性

Engram 的产品解析路径在 Swift 侧：`macos/Shared/EngramCore/Adapters/Sources/` 负责读取各工具原始日志，`macos/EngramCoreWrite/Indexing/` 负责写入索引库。TypeScript 适配器保留为 dev/reference/fixture tooling，用于生成和校验 fixture parity。

会话详情只把 `user` / `assistant` 消息作为可见正文展示；tool/event/system-like 数据用于索引、工具统计或诊断，不作为普通对话气泡混入正文。历史 HTTP/API reference 视图也遵循同一可见消息规则，因此分页 offset 按可见消息计算，而不是按原始日志行数计算。

Antigravity CLI、Command Code、Qoder 是重点覆盖来源。Antigravity CLI 使用 `~/.gemini/antigravity-cli/brain/` 下的 CLI transcript，并兼容旧 gRPC cache；Qoder 覆盖顶层 session 与 nested `subagents/` 父子关系；Command Code 覆盖 `tool-call` 的 `input` / `args` 形态。发布前的 parser/parity smoke：

```bash
npm run check:adapter-parity-fixtures
npm test -- tests/adapters
xcodebuild test -project macos/Engram.xcodeproj -scheme EngramCoreTests -destination 'platform=macOS' -only-testing:EngramCoreTests/AdapterParityTests/testSwiftAdaptersMatchNodeParityGoldensForAllProviders
xcodebuild test -project macos/Engram.xcodeproj -scheme Engram -destination 'platform=macOS' -only-testing:EngramTests/MessageParserTests
```

当前 fixture/parity gate 覆盖 15 个独立产品适配器：Antigravity CLI、Claude Code、Cline、Codex CLI、Command Code、GitHub Copilot、Cursor、Gemini CLI、iflow、Kimi、OpenCode、Qoder、Qwen Code、VS Code Copilot、Windsurf。MiniMax 和 Lobster AI 作为 Claude-compatible derived sources 走 Claude Code parser，但会以独立 source 写入索引；Swift/Node 回归测试覆盖该派生分类。Swift App、Swift MCP、Swift Service export、Swift HTTP transcript endpoint 都只展示非空 `user` / `assistant` 可见正文；tool/system/event-like 行保留给索引、工具统计和诊断，不混入普通对话气泡。provider parser parity 由 `tests/fixtures/adapter-parity/**` 约束；HTTP/Swift/MCP/export 的可见消息一致性由 Swift service/core 测试覆盖。如果出现同一会话在两端解析或显示不同，先补对应 fixture，再改 adapter 或可见消息过滤逻辑。

最近一次完整 provider/parser ship 记录见 [`docs/verification/provider-parser-parity-2026-05-20.md`](docs/verification/provider-parser-parity-2026-05-20.md)，其中包含两轮 Polycli review 与最终验证命令。

## 快速上手

**前置要求：** 已安装 `Engram.app`，或从源码构建 macOS App。

```bash
# 源码构建
git clone https://github.com/bbingz/engram
cd engram
macos/scripts/build-release.sh --local-only

# 2. 安装到 /Applications
macos/scripts/deploy-local.sh macos/build/EngramExport/Engram.app

#    如果没有 Developer ID 证书，--local-only 会生成
#    macos/build/EngramExport/Engram-local-only.app，只能本机安装，不能分发/公证。

# 3. 重启 AI 工具，在对话中调用：
# get_context cwd=/your/project/path
```

首次启动 `Engram.app` 时，`EngramService` 会自动扫描所有会话文件并建立索引（存储在 `~/.engram/index.sqlite`）。之后通过文件监听增量更新，无需手动维护。

## 注册为 MCP Server

### Claude Code

```bash
claude mcp add --scope user engram /Applications/Engram.app/Contents/Helpers/EngramMCP
```

或者手动编辑 `~/.claude/settings.json`：

```json
{
  "mcpServers": {
    "engram": {
      "command": "/Applications/Engram.app/Contents/Helpers/EngramMCP",
      "args": []
    }
  }
}
```

### Codex

Codex 会在会话启动时持有 MCP stdio 子进程。为了避免发布时替换
`/Applications/Engram.app` 影响已经打开的 Codex 会话，建议先创建一个稳定
shim：

```bash
mkdir -p ~/.engram/bin
cat > ~/.engram/bin/engram-mcp <<'EOF'
#!/bin/sh
set -eu

HELPER="/Applications/Engram.app/Contents/Helpers/EngramMCP"
if [ ! -x "$HELPER" ]; then
  echo "Engram MCP helper is not executable at $HELPER" >&2
  exit 127
fi

exec "$HELPER" "$@"
EOF
chmod 755 ~/.engram/bin/engram-mcp
```

编辑 `~/.codex/config.toml`：

```toml
[mcp_servers.engram]
command = "/Users/<you>/.engram/bin/engram-mcp"
args = []
```

### 其他支持 MCP 的客户端

任何支持 MCP stdio transport 的客户端均可使用。将以下内容加入对应的 MCP 配置：

```json
{
  "command": "/Applications/Engram.app/Contents/Helpers/EngramMCP",
  "args": []
}
```

## macOS App

Engram 的产品 UI 是原生 macOS App。`Engram.app` 启动后会管理 `EngramService`，并通过 Swift/GRDB 读取索引库。

App 功能：
- **会话列表**：按来源、项目、时间筛选，支持多选过滤和分页
- **父子会话归组**：Claude Code → Codex/Gemini 等派发子会话自动挂到父会话下
- **今日父会话 badge**：菜单栏徽标显示今天的顶层父会话数量，而不是全部子任务总数
- **会话详情**：完整对话内容、Markdown 渲染、收藏、导出
- **搜索**：Swift 产品路径使用 SQLite FTS5 trigram 关键词搜索，支持中英文、UUID 直查和结果高亮
- **价值提示**：索引时计算 `quality_score`，列表/搜索结果用高/中/低 value band 做快速判断
- **会话整理**：收藏、重命名、隐藏低信号/空会话
- **项目视图**：项目 rename / move / archive / undo 走 Swift service single-writer pipeline
- **用量统计**：按来源 / 项目 / 天 / 周、模型成本、工具调用、文件活动分组统计
- **网络设置**：配置 MCP single-writer 策略，并明确 peer sync 在 Swift service 中未实现

历史 TypeScript Web/API 代码仍保留为开发/reference material，不是当前 macOS 产品运行路径；其中部分 semantic/hybrid 路由是旧路径能力，不代表 Swift App/MCP 当前已启用语义搜索。
- `GET /api/sessions/:id` — 会话详情
- `GET /api/search?q=...` — 历史搜索 API（支持 source、project、since、mode、UUID 直查）
- `GET /api/search/semantic?q=...` — 历史语义搜索 API（TypeScript reference path）
- `GET /api/search/status` — embedding 状态（可用性、模型、进度）
- `GET /api/stats` — 用量统计
- `GET /api/project-aliases` — 列出项目别名
- `POST /api/project-aliases` — 添加别名
- `DELETE /api/project-aliases` — 删除别名
- `GET /api/sync/status` — 同步状态
- `POST /api/sync/trigger` — 手动触发同步

## MCP Tools 参考

Engram 的 Swift MCP runtime 当前暴露 28 个工具，覆盖上下文获取、搜索、记忆管理、统计分析、会话整理和项目迁移等场景：

| 工具 | 说明 |
|------|------|
| `get_context` | 🔑 **核心工具** — 自动提取当前项目的历史上下文，开始新任务时调用 |
| `search` | FTS 关键词搜索；旧客户端传 `semantic`/`hybrid` 会降级为 keyword 并返回 warning |
| `list_sessions` | 列出历史会话，支持按来源/项目/时间过滤 |
| `get_session` | 读取单个会话完整对话，支持分页 |
| `save_insight` | 保存重要知识片段，跨会话持久化 |
| `delete_insight` | 删除已保存的 insight |
| `get_memory` | 检索已保存的记忆和知识 |
| `project_timeline` | 查看项目跨工具的操作时间线 |
| `stats` | 用量统计（按来源/项目/天/周分组） |
| `get_costs` | Token 用量和费用统计 |
| `tool_analytics` | 分析各工具（Read/Edit/Bash 等）调用频率 |
| `file_activity` | 项目中最常编辑/读取的文件 |
| `handoff` | 生成项目交接简报 |
| `export` | 导出会话为 Markdown/JSON |
| `generate_summary` | AI 生成会话摘要 |
| `link_sessions` | 在项目目录创建会话文件软链接 |
| `manage_project_alias` | 管理项目别名（目录移动后保持关联） |
| `live_sessions` | MCP mode 下返回明确 unavailable 结果 |
| `lint_config` | 校验 CLAUDE.md 等配置文件 |
| `get_insights` | 获取费用优化建议 |
| `hide_session` | 隐藏或恢复指定会话 |
| `project_move` | 移动项目目录并保持 AI 会话历史可达 |
| `project_archive` | 将项目归档到 `_archive/` 分类目录 |
| `project_undo` | 回滚已提交的 project move |
| `project_move_batch` | 批量执行 project move/archive |
| `project_list_migrations` | 查看 project move 迁移记录 |
| `project_recover` | 诊断失败或卡住的迁移 |
| `project_review` | 扫描迁移后的旧路径残留引用 |

**快速示例：**

```json
// 获取项目上下文
{ "cwd": "/Users/me/my-project", "task": "重构认证模块" }

// 搜索历史
{ "query": "JWT 认证", "mode": "keyword" }

// 保存知识
{ "content": "项目使用 Hono 作为 HTTP 框架", "wing": "engram" }
```

> 完整参数文档见 [MCP Tools Reference](docs/mcp-tools.md)。

---

## 搜索现状

当前 Swift 产品路径使用 SQLite FTS5 trigram 关键词搜索。MCP、App service 读路径和会话详情展示共用同一套 Swift 索引库与可见消息规则。

- **keyword**：已上线。覆盖用户消息、助手回复、摘要和索引文本；支持中英文、代码片段、函数名、UUID 直查。
- **semantic / hybrid**：Swift service 当前没有 embedding provider，也没有 sqlite-vec KNN 查询链路。旧客户端传 `semantic`、`hybrid` 或 `both` 会被兼容接收，但实际降级为 keyword，并返回 warning。
- **insights memory**：`save_insight` / `get_memory` 当前以 FTS/recent fallback 为主；embedding 字段保留在 schema 中，尚不是产品可用的语义检索能力。

搜索覆盖范围：用户消息 + 助手回复 + 会话摘要 + 部分 adapter 归一化后的工具/诊断文本。

搜索还支持**直接粘贴会话 UUID** 进行精确查找，无需关键词或语义匹配。

### Embedding 配置状态

`~/.engram/settings.json` 仍可能包含旧版 TypeScript/reference tooling 使用过的 embedding 字段：

| 字段 | 当前状态 |
|------|----------|
| `ollamaUrl` / `ollamaModel` / `embeddingDimension` | 兼容保留；Swift service 不会因此启用语义搜索 |
| `openaiApiKey` | 仍可用于 AI summary/title 等 LLM 请求；不代表 Swift semantic search 已启用 |
| `session_embeddings` / `vec_sessions` | schema/backfill 兼容表；FTS 版本或向量版本变化时可能被清空重建 |

## 项目别名

当你移动了项目目录（例如从 `~/Code/wechat-decrypt` 移到 `~/Code/wechat-decrypt-bing`），AI 助手会找不到旧路径下的历史会话。通过项目别名，可以声明两个项目名是同一个项目，所有查询自动展开。

### 添加别名

**通过 MCP 工具（在 AI 对话中）：**

```json
{ "name": "manage_project_alias", "arguments": { "action": "add", "old_project": "wechat-decrypt", "new_project": "wechat-decrypt-bing" } }
```

历史 TypeScript Web/API 仍保留为开发/reference material；当前产品路径优先使用 MCP 工具。macOS App 暂未提供 Project Aliases 管理 UI。

```bash
curl -X POST http://127.0.0.1:3457/api/project-aliases \
  -H 'Content-Type: application/json' \
  -d '{"alias": "wechat-decrypt", "canonical": "wechat-decrypt-bing"}'
```

添加后，在任意路径下调用 `get_context`、`search`、`list_sessions` 等工具，两个项目名的会话都会出现。别名是双向的——查哪个名字都能找到另一个。

### 管理别名

```json
// 列出所有别名
{ "action": "list" }

// 删除别名
{ "action": "remove", "old_project": "wechat-decrypt", "new_project": "wechat-decrypt-bing" }
```

> **注意：** 项目别名解决的是 Engram 层面的查询问题。各 AI 工具自身的 `/resume` 等功能仍然依赖原始路径，这不在 Engram 的控制范围内。

## Peer Sync 状态

Swift service 目前未实现 peer sync。macOS App 不会启用或触发 sync；`triggerSync` 在 service 层返回 unsupported 状态，避免把未实现功能包装成成功操作。

旧版 TypeScript reference tooling 仍保留 peer-sync 配置字段和 API 路由，供开发/迁移参考；它们不是当前 macOS 产品运行路径。

`~/.engram/settings.json` 中可能仍存在这些兼容字段：

```json
{
  "syncNodeName": "macbook-pro",
  "syncEnabled": false,
  "syncIntervalMinutes": 10,
  "syncPeers": [
    { "name": "desktop", "url": "http://192.168.1.100:3457" }
  ]
}
```

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
| `httpPort` | number | `3457` | 历史 HTTP/API 监听端口；当前产品路径优先使用 Swift service |
| `httpHost` | string | `"127.0.0.1"` | 历史 Web/API 绑定地址；默认仅 localhost |
| `httpAllowCIDR` | string[] | `[]` | 当历史 HTTP/API 绑定非 localhost 时必须提供 |
| `httpBearerToken` | string | auto | 非 localhost 首次启动时自动生成，用于写接口鉴权 |
| `aiProvider` | string | `"openai"` | AI 摘要生成器：`openai` 或 `anthropic` |
| `openaiApiKey` | string | — | OpenAI API Key（用于摘要/标题等 LLM 请求；不启用 Swift semantic search） |
| `openaiModel` | string | `"gpt-4o-mini"` | OpenAI 摘要模型 |
| `anthropicApiKey` | string | — | Anthropic API Key |
| `anthropicModel` | string | `"claude-3-haiku-20240307"` | Anthropic 摘要模型 |
| `ollamaUrl` | string | `"http://localhost:11434"` | Ollama 服务地址（支持远程） |
| `ollamaModel` | string | `"nomic-embed-text"` | Ollama embedding 模型 |
| `embeddingDimension` | number | `768` | 旧版 embedding 兼容字段；Swift service 当前不使用 |
| `syncNodeName` | string | `"unnamed"` | 旧版 peer-sync 兼容字段；Swift service 当前不使用 |
| `syncEnabled` | boolean | `false` | 旧版 peer-sync 兼容字段；Swift service 当前不使用 |
| `syncIntervalMinutes` | number | `10` | 旧版 peer-sync 兼容字段；Swift service 当前不使用 |
| `syncPeers` | array | `[]` | 旧版 peer-sync 兼容字段；Swift service 当前不使用 |

> **安全说明：** 如果把历史 HTTP/API 的 `httpHost` 设为 `0.0.0.0` 或其他非 localhost 地址，但没有配置 `httpAllowCIDR`，服务会直接拒绝启动，不会自动回退到 localhost。

## 添加新适配器

产品适配器优先在 Swift 中实现；TypeScript 适配器保留为 dev/reference/fixture material。

**Swift 产品路径：**

- 适配器：`macos/Shared/EngramCore/Adapters/Sources/`
- 索引与 backfill：`macos/EngramCoreWrite/Indexing/`
- 服务命令：`macos/EngramService/Core/`
- MCP 路由：`macos/EngramMCP/Core/MCPToolRegistry.swift`

TypeScript reference 接口（`src/adapters/types.ts`）：

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

1. 先在 Swift adapter/indexer/backfill 路径实现产品行为
2. 补 Swift fixture/parity tests
3. 仅当 retained TypeScript fixture tooling 需要时，再同步 `src/adapters/**`
4. 参照现有测试编写对应 Swift/TypeScript 回归测试

**实现参考：** Swift adapters 是产品实现；`src/adapters/codex.ts` 仍可作为历史/reference 参考。

## 数据存储与隐私

- **索引库位置：** `~/.engram/index.sqlite`，存储元数据（会话 ID、时间、路径、摘要）、FTS 全文搜索索引和兼容保留的 embedding 表
- **原始文件：** 完整消息内容始终从 AI 工具的原始日志文件流式读取，不做额外拷贝
- **隐私脱敏：** 可在配置中设置正则，匹配内容在建立索引时会被替换为 `[REDACTED]`
- **数据不离本机：** `EngramService`、`EngramMCP` 和 macOS App 本地运行，不向任何远程服务发送数据（除非使用远程 AI/embedding provider）

## 开发

```bash
npm test              # 运行测试
npm run test:watch    # 监听模式
npm run test:coverage # 覆盖率报告
npm run build         # 编译 TypeScript dev/reference tooling -> dist/
npm run check:adapter-parity-fixtures # 校验 provider parser parity fixtures
npm run dev           # TypeScript 开发/reference 模式；不是 shipped app runtime
```

macOS 应用（Menu Bar）：

```bash
cd macos
xcodegen generate     # 从 project.yml 生成 Xcode 项目
open Engram.xcodeproj # 在 Xcode 中构建和运行
```

## License

MIT
