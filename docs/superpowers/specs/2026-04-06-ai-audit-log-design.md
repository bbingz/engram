# AI Audit Log — 全链路 AI 可观测性

**Date:** 2026-04-06
**Status:** Approved
**Scope:** 所有外部 AI API 调用的请求/响应审计 + Viking Observer 代理

---

## 1. 动机

Engram 调用多个外部 AI 服务（Viking、标题生成、自动摘要、向量 embedding），但当前只记录"成功/失败/耗时"，不记录具体内容：

- 什么时候发了什么请求？
- 哪个模型响应？消耗了多少 Token？
- 响应了什么内容？

缺乏请求级别的可观测性，无法排查问题、控制成本、分析用量。

## 2. 覆盖范围

| 调用方 | 目标服务 | Token 信息 | 调用频率 |
|--------|----------|-----------|---------|
| VikingBridge | OpenViking (搜索/存储) | 无（不是 LLM） | 高 |
| TitleGenerator | Ollama/OpenAI/DashScope | 有 | 中 |
| summarizeConversation | OpenAI/Anthropic/Gemini | 有 | 低 |
| EmbeddingClient | Ollama/OpenAI SDK | 有 | 高 |

额外：代理 Viking 服务端的 5 个 observer 端点，拉取 Viking 内部的聚合 LLM token 消耗。

## 3. 数据模型

### 3.1 `ai_audit_log` 表

```sql
CREATE TABLE ai_audit_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f','now')),
  trace_id TEXT,

  -- 谁发的、做什么、谁触发的
  caller TEXT NOT NULL,         -- 'viking' | 'title' | 'summary' | 'embedding'
  operation TEXT NOT NULL,      -- 'pushSession' | 'find' | 'generate' | 'embed' ...
  request_source TEXT,          -- 'mcp' | 'http' | 'indexer' | 'watcher' | 'scheduler'

  -- HTTP 层 (全部 nullable — SDK 路径可能没有)
  method TEXT,
  url TEXT,                     -- sanitized (脱敏 API key)
  status_code INTEGER,
  duration_ms INTEGER,

  -- AI 层
  model TEXT,                   -- free text: 'kimi-k2.5' | 'qwen2.5:3b' | 'gpt-4o-mini' ...
  provider TEXT,                -- free text: 'ollama' | 'openai' | 'anthropic' | 'gemini' | 'dashscope' | 'custom' | 'viking'
  prompt_tokens INTEGER,
  completion_tokens INTEGER,
  total_tokens INTEGER,

  -- 内容 (默认不记录，需显式开启 logBodies)
  request_body TEXT,            -- sanitized + truncated to maxBodySize
  response_body TEXT,           -- sanitized + truncated to maxBodySize

  -- 上下文
  error TEXT,
  session_id TEXT,              -- 触发此调用的会话 ID
  meta TEXT                     -- JSON 扩展字段 (如 pushSession 的 messageCount)
);

CREATE INDEX idx_ai_audit_ts ON ai_audit_log(ts);
CREATE INDEX idx_ai_audit_caller ON ai_audit_log(caller, ts);
CREATE INDEX idx_ai_audit_model ON ai_audit_log(model, ts);
CREATE INDEX idx_ai_audit_session ON ai_audit_log(session_id);
CREATE INDEX idx_ai_audit_trace ON ai_audit_log(trace_id);
```

### 3.2 配置项 (`settings.json`)

```jsonc
{
  "aiAudit": {
    "enabled": true,           // 默认 true — 记录元数据
    "retentionDays": 30,       // 自动清理
    "maxBodySize": 10000,      // 请求/响应体截断字符数
    "logBodies": false         // 默认 false — 显式开启才存内容
  }
}
```

## 4. 核心组件

### 4.1 AiAuditWriter (`src/core/ai-audit.ts`)

轻量写入器，与现有 LogWriter/TraceWriter 模式一致：

```typescript
interface AiAuditRecord {
  traceId?: string
  caller: string              // 'viking' | 'title' | 'summary' | 'embedding'
  operation: string
  requestSource?: string      // from RequestContext
  method?: string
  url?: string
  statusCode?: number
  model?: string
  provider?: string
  promptTokens?: number
  completionTokens?: number
  totalTokens?: number
  requestBody?: unknown       // auto JSON.stringify + sanitize + truncate
  responseBody?: unknown
  durationMs: number
  error?: string
  sessionId?: string
  meta?: Record<string, unknown>
}

class AiAuditWriter extends EventEmitter {
  constructor(db: BetterSqlite3.Database, config: AiAuditConfig)

  /** 写入一条审计记录。永不抛出异常。 */
  record(entry: AiAuditRecord): void

  /** 清理超过 retentionDays 的记录 */
  cleanup(retentionDays: number): number
}
```

关键约束：
- `record()` 内部 try-catch，**永不抛出** — 审计失败不影响 AI 调用行为
- URL/body 写入前过 sanitizer 脱敏（复用 `src/core/sanitizer.ts`）
- `logBodies: false` 时，`request_body` 和 `response_body` 不写入
- 写入后 emit `'entry'` 事件，供 daemon stdout 发最小通知

### 4.2 AiAuditQuery (`src/core/ai-audit.ts`)

查询/统计分离：

```typescript
class AiAuditQuery {
  constructor(db: BetterSqlite3.Database)

  /** 分页查询 */
  list(filters: {
    caller?: string
    model?: string
    sessionId?: string
    from?: string
    to?: string
    hasError?: boolean
    limit?: number
    offset?: number
  }): { records: AiAuditRecord[]; total: number }

  /** 单条详情 */
  get(id: number): AiAuditRecord | null

  /** 聚合统计 */
  stats(timeRange?: { from?: string; to?: string }): AiAuditStats
}

interface AiAuditStats {
  timeRange: { from: string; to: string }
  totals: {
    requests: number
    errors: number
    promptTokens: number
    completionTokens: number
    avgDurationMs: number
  }
  byCaller: Record<string, { requests: number; errors: number; promptTokens: number; completionTokens: number }>
  byModel: Record<string, { requests: number; promptTokens: number; completionTokens: number }>
  hourly: { hour: string; requests: number; tokens: number }[]
}
```

## 5. 拦截集成

### 5.1 VikingBridge

在 VikingBridge 内部新增 `auditedFetch()` 包装器，所有出口统一走它：

- `post()` → `auditedFetch()`
- `getContent()` → `auditedFetch()`
- `find()` / `grep()` / `ls()` / `addResource()` / `deleteResources()` / `isAvailable()` 全部覆盖

**pushSession 特殊处理：** 不逐条 `/messages` POST 记录，只记一条汇总：
```jsonc
{
  "caller": "viking",
  "operation": "pushSession",
  "meta": { "messageCount": 50, "sessionId": "claude-code::project::uuid" },
  "durationMs": 5200
}
```

新增 5 个 observer 代理方法：
```typescript
async observerSystem(): Promise<unknown>
async observerQueue(): Promise<unknown>
async observerVlm(): Promise<unknown>
async observerVikingdb(): Promise<unknown>
async observerTransaction(): Promise<unknown>
```

替换 `web.ts` 中现有的 raw fetch 调用。

### 5.2 TitleGenerator

在 `generate()` 中提取 token：

| Provider | prompt_tokens | completion_tokens |
|----------|--------------|-------------------|
| Ollama | `json.prompt_eval_count` | `json.eval_count` |
| OpenAI/DashScope/Custom | `json.usage.prompt_tokens` | `json.usage.completion_tokens` |

### 5.3 summarizeConversation

在 `ai-client.ts` 中三个协议各自提取：

| Protocol | prompt_tokens | completion_tokens |
|----------|--------------|-------------------|
| OpenAI | `data.usage.prompt_tokens` | `data.usage.completion_tokens` |
| Anthropic | `data.usage.input_tokens` | `data.usage.output_tokens` |
| Gemini | `data.usageMetadata.promptTokenCount` | `data.usageMetadata.candidatesTokenCount` |

### 5.4 EmbeddingClient

| Provider | prompt_tokens | 说明 |
|----------|--------------|------|
| Ollama (fetch) | `json.prompt_eval_count` | 直接从响应提取 |
| OpenAI (SDK) | `res.usage.prompt_tokens` | method/url/status_code 为 null |

不存 embedding 向量到 responseBody（太大且无意义），只在 meta 中记 dimension。

## 6. 注入方式

`AiAuditWriter` 实例在 bootstrap/daemon 创建，通过构造器参数传入各调用方：

```
daemon.ts:
  const audit = new AiAuditWriter(db.getRawDb(), auditConfig)
  new VikingBridge(url, key, { audit, ... })
  new TitleGenerator({ audit, ... })
  new EmbeddingClient({ audit, ... })
  summarizeConversation(messages, settings, { audit })
  createWebApp(... { audit, auditQuery })
```

`index.ts` (MCP server) 同理。

## 7. HTTP API 端点

### 7.1 审计查询

```
GET  /api/ai/audit
     ?caller=viking|title|summary|embedding
     ?model=qwen2.5:3b
     ?sessionId=xxx
     ?from=2026-04-01&to=2026-04-06
     ?hasError=true
     ?limit=50&offset=0

GET  /api/ai/audit/:id

GET  /api/ai/stats
     ?from=&to=
```

所有 `/api/ai/*` 端点需要 bearer token 鉴权（与现有写 API 一致）。

### 7.2 Viking Observer 代理

```
GET  /api/viking/observer              → /api/v1/observer/system
GET  /api/viking/observer/queue        → /api/v1/observer/queue
GET  /api/viking/observer/vlm          → /api/v1/observer/vlm
GET  /api/viking/observer/vikingdb     → /api/v1/observer/vikingdb
GET  /api/viking/observer/transaction  → /api/v1/observer/transaction
```

## 8. 实时监控

### 8.1 轮询

客户端每 2-3 秒调用：
```
GET /api/ai/audit?from=<lastSeenTs>&limit=20
```

### 8.2 Daemon stdout 最小通知

AiAuditWriter emit `'entry'` → daemon 写 JSON line 到 stdout：

```jsonc
{ "event": "ai_audit", "id": 42, "caller": "title", "operation": "generate",
  "model": "qwen2.5:3b", "durationMs": 1200, "promptTokens": 500 }
```

**不发送 body 内容** — macOS app 按需轮询详情。

## 9. 生命周期

### 9.1 初始化顺序

```
daemon.ts:
  1. Database
  2. AiAuditWriter(db, config)          ← DB migration 在此触发
  3. initViking(settings, { audit })
  4. TitleGenerator({ audit })
  5. EmbeddingClient({ audit })
  6. AutoSummaryManager(... { audit })
  7. Indexer(...)
  8. createWebApp(... { audit, auditQuery })
```

### 9.2 DB Migration

在 `db.ts:migrate()` 中 idempotent 创建：
```typescript
if (!tableExists('ai_audit_log')) {
  db.exec(`CREATE TABLE ai_audit_log (...)`)
  db.exec(`CREATE INDEX ...`)
}
```

### 9.3 清理

- 启动时清理一次
- 接入现有小时级维护循环（与 metrics rollup、log rotation 一起）
- 删除超过 `retentionDays` 的记录

## 10. 安全

- URL 写入前过 sanitizer — 脱敏 API key、bearer token（复用 `src/core/sanitizer.ts`）
- `logBodies` 默认 false — 不存请求/响应内容
- 开启 `logBodies` 时，body 也过 sanitizer
- `/api/ai/*` 端点加 bearer token 鉴权
- 审计记录跟随 retentionDays 自动清理

## 11. 文件变更清单

| 文件 | 变更类型 | 说明 |
|------|---------|------|
| `src/core/ai-audit.ts` | **新增** | AiAuditWriter + AiAuditQuery |
| `src/core/config.ts` | 修改 | 新增 `AiAuditConfig` 接口 |
| `src/core/db.ts` | 修改 | 新增 `ai_audit_log` 表 migration |
| `src/core/viking-bridge.ts` | 修改 | 注入 audit + `auditedFetch()` + 5 个 observer 代理方法 |
| `src/core/title-generator.ts` | 修改 | 注入 audit + 提取 token |
| `src/core/ai-client.ts` | 修改 | 注入 audit + 三个协议提取 token |
| `src/core/embeddings.ts` | 修改 | 注入 audit + 提取 token |
| `src/core/bootstrap.ts` | 修改 | 创建 AiAuditWriter 实例 |
| `src/daemon.ts` | 修改 | 接入 audit，注册清理 |
| `src/index.ts` | 修改 | 接入 audit (MCP 模式) |
| `src/web.ts` | 修改 | 新增 `/api/ai/*` 端点 + Viking observer 代理 + 鉴权 |
| `tests/core/ai-audit.test.ts` | **新增** | AiAuditWriter + AiAuditQuery 测试 |

## 12. 不做的事

- macOS app UI 页面 — 后续单独设计
- SSE 推送 — 轮询 + daemon 事件流已够用
- Token 成本计算（$/token）— 有了 token 数据后是简单后续工作
- 请求体加密 — 本地 SQLite，sanitizer 脱敏足够
- OpenTelemetry 导出 — 当前无外部可观测平台需求
