# Engram Web API 接口审计报告

**审计人**: api-auditor
**审计日期**: 2026-05-03
**审计范围**: `src/web.ts`（Hono HTTP API）、`src/tools/`（MCP 工具对比）、`src/core/db/`（数据库层）、Swift IPC 通信层
**代码版本**: 当前 HEAD

---

## 一、API 总览

| 维度 | 数值 |
|------|------|
| HTTP API 端点总数 | **~60**（含 HTML 路由） |
| GET 端点 | ~35 |
| POST 端点 | ~18 |
| DELETE 端点 | ~5 |
| PUT/PATCH 端点 | 0 |
| MCP 工具文件 | 19 |
| MCP 工具有对应 HTTP 端点 | ~12 |
| MCP 工具**无** HTTP 对应 | ~7 |

### MCP 工具 vs HTTP API 对应关系

| MCP 工具 | HTTP 端点 | 状态 |
|----------|----------|------|
| `search` | `GET /api/search` | ✅ |
| `list_sessions` | `GET /api/sessions` | ✅ |
| `get_session` | `GET /api/sessions/:id` | ✅ |
| `save_insight` | `POST /api/insight` | ✅ |
| `get_costs` | `GET /api/costs` | ✅ |
| `stats` | `GET /api/stats` | ✅ |
| `tool_analytics` | `GET /api/tool-analytics` | ✅ |
| `file_activity` | `GET /api/file-activity` | ✅ |
| `handoff` | `POST /api/handoff` | ✅ |
| `link_sessions` | `POST /api/link-sessions` | ✅ |
| `lint_config` | `POST /api/lint` | ✅ |
| `project_*` (6个) | `/api/project/*` | ✅ |
| **`get_context`** | 无 | ❌ 缺失 |
| **`get_memory`** | `GET /api/memory` | ⚠️ 功能不完整 |
| **`get_insights`** | 无 | ❌ 缺失 |
| **`get_session` (MCP)** | `GET /api/sessions/:id` | ⚠️ 功能差异 |
| **`export`** | 无 | ❌ 缺失 |
| **`project_timeline`** | 无 | ❌ 缺失 |
| **`generate_summary`** | `POST /api/summary` | ✅ |
| **`live_sessions`** | `GET /api/live` | ✅ |

---

## 二、API 设计问题

### 2.1 URL 命名不一致

#### 🟡 中等 — 单复数混用

```
POST /api/session/:id/resume          ← 单数 session
GET  /api/sessions/:id                ← 复数 sessions
POST /api/session/:id/generate-title  ← 单数 session
GET  /api/sessions/:id/children       ← 复数 sessions
GET  /api/sessions/:id/timeline       ← 复数 sessions
```

**问题**: `/api/session/:id/resume` 和 `/api/session/:id/generate-title` 使用了单数 `session`，而其他端点均使用复数 `sessions`。这违反了 RESTful 惯例（集合资源用复数）。

**影响**: 客户端需要记住哪个端点用单数、哪个用复数，增加认知负担。

**建议**:
```diff
- POST /api/session/:id/resume
+ POST /api/sessions/:id/resume

- POST /api/session/:id/generate-title
+ POST /api/sessions/:id/generate-title
```

---

#### 🟡 中等 — 路径层级不一致

```
/api/project/migrations       ← project 单数 + 子资源
/api/project-aliases          ← 用连字符分隔
/api/project/move             ← 动作嵌入资源路径
/api/health/sources           ← health 作为顶级资源
/api/monitor/alerts           ← monitor 作为顶级资源
```

**问题**:
- `project-aliases` 用连字符，而 `project/migrations` 用路径层级。同一概念用了两种风格。
- `project/move` 将动词放在资源路径中，更 RESTful 的做法应为 `POST /api/projects/:name/move` 或将其视为 RPC 风格端点明确标注。

**建议**: 统一使用 `/api/projects/*`（复数）作为前缀：
```diff
- /api/project/migrations
+ /api/projects/migrations

- /api/project-aliases
+ /api/projects/aliases
```

---

### 2.2 HTTP 方法使用

#### 🟢 建议 — DELETE 端点使用 body 传参

```typescript
// web.ts line 544-551
app.delete('/api/sessions/:id/suggestion', async (c) => {
    const body = await c.req.json<{ suggestedParentId: string }>();
    // ...
});
```

**问题**: `DELETE /api/sessions/:id/suggestion` 需要请求体 (`suggestedParentId`)。虽然 RFC 7231 不禁止 DELETE 有 body，但许多 HTTP 客户端和代理会丢弃 DELETE 请求体。这是跨平台兼容性隐患。

**建议**: 将 `suggestedParentId` 移到查询参数或路径中：
```diff
- DELETE /api/sessions/:id/suggestion  { suggestedParentId: "xxx" }
+ DELETE /api/sessions/:id/suggestion/:suggestedParentId
```

#### 🟢 建议 — DELETE /api/project-aliases 使用 body

同上问题，`DELETE /api/project-aliases` 也通过请求体传递 `alias` 和 `canonical`。

---

### 2.3 状态码使用

#### 🟡 中等 — 错误响应格式不统一

审计发现 **至少三种不同的错误响应格式** 在同一 API 中共存：

**格式 A — 简单字符串错误**（大多数端点）:
```json
{ "error": "Session not found" }
```

**格式 B — 结构化错误包络**（project-move 相关端点）:
```json
{
  "error": {
    "name": "InvalidPath",
    "message": "path must be absolute",
    "retry_policy": "never"
  }
}
```

**格式 C — 混合**（resume 端点）:
```json
{ "error": "Session not found", "hint": "" }
```

**格式 D — 简单对象**（audit 端点）:
```json
{ "error": "Audit not configured" }
// 但查询端点又返回：
{ "error": "not found" }
```

**问题**: Swift 客户端需要多种解码策略来处理不同的错误格式。`validationError()` 函数生成格式 B，而大多数其他端点用格式 A。

**建议**:
1. 统一使用结构化错误包络（格式 B），至少在 `/api/*` 端点上。
2. 定义一个 `ErrorResponse` 类型并强制所有端点使用。

---

#### 🟢 建议 — 409 使用过窄

```typescript
// web.ts line 550
if (!cleared) return c.json({ error: 'stale-suggestion' }, 409);
```

409 (Conflict) 只用在了 `clearSuggestedParent` 上。其他有冲突语义的操作（如 `confirmSuggestion` 失败、`link` 验证失败）使用 400。建议统一冲突场景都使用 409。

---

## 三、接口完整性问题

### 3.1 缺失的接口

#### 🔴 严重 — 没有 Insights 查询/搜索 HTTP API

```typescript
// MCP 工具 get_insights.ts 存在，但 web.ts 中没有对应的 GET 端点
// 只有 POST /api/insight（保存）和 db.searchInsightsFts()
```

**问题**: 用户只能通过 MCP 协议查询 insights，Swift UI 和 HTTP 客户端无法列出或搜索 insights。

**现有功能**:
- `POST /api/insight` — 保存 insight ✅
- `GET /api/insights` — **不存在** ❌
- `GET /api/insights/search?q=xxx` — **不存在** ❌
- `DELETE /api/insights/:id` — **不存在** ❌

**建议**:
```
GET    /api/insights              → 列出 insights（分页、按 wing 过滤）
GET    /api/insights/search?q=xx → 全文搜索 insights
DELETE /api/insights/:id          → 删除 insight
```

---

#### 🔴 严重 — 没有 `get_context` HTTP API

`get_context` 是 MCP 工具中功能最丰富的接口之一，可获取会话的完整上下文（消息、元数据、相关 sessions）。Swift UI 的 `SessionDetailView` 可能需要这些数据，但只能通过数据库直接读取。

**建议**: 添加 `GET /api/sessions/:id/context` 端点。

---

#### 🟡 中等 — 缺少 `export` 端点

MCP 有 `export` 工具可导出会话为 Markdown/JSON 格式。Swift UI 可能也需要此功能（如分享会话内容）。

**建议**: 添加 `GET /api/sessions/:id/export?format=markdown` 端点。

---

#### 🟡 中等 — 缺少 `project_timeline` 端点

MCP 有 `project_timeline` 工具可查看项目的会话时间线。HTTP API 无对应。

**建议**: 添加 `GET /api/projects/:name/timeline` 端点。

---

### 3.2 分页支持不完整

#### 🟡 中等 — 多数端点没有返回总数

对比以下端点的响应：

| 端点 | 返回 `total` | 返回 `hasMore` |
|------|-------------|---------------|
| `GET /api/sessions` | ❌ | ✅ |
| `GET /api/sessions/:id/children` | ❌ | ❌ |
| `GET /api/sessions/:id/timeline` | ⚠️ 用 `totalEntries` | ✅ |
| `GET /api/ai/audit` | ✅ `total` | ❌ |
| `GET /api/sync/sessions` | ❌ | ❌ |
| `GET /api/file-activity` | ⚠️ `totalFiles` | ❌ |
| `GET /api/costs/sessions` | ❌ | ❌ |

**问题**: 分页模式不统一。有些用 `hasMore`，有些用 `total`，有些两者都没有。Swift UI 需要知道是否还有更多数据来触发无限滚动。

**建议**: 统一分页响应格式：
```typescript
interface PaginatedResponse<T> {
  data: T[];
  pagination: {
    offset: number;
    limit: number;
    total?: number;     // 如果可以廉价获取
    hasMore: boolean;
  };
}
```

---

#### 🟡 中等 — `/api/sessions/:id/children` 无分页对 `suggested`

```typescript
// web.ts line 554-565
const confirmed = db.childSessions(parentId, limit, offset);   // ✅ 有分页
const suggested = db.suggestedChildSessions(parentId);          // ❌ 无分页
```

**问题**: `confirmed` 支持分页，但 `suggested` 没有。如果建议链接很多，会导致响应过大。

---

### 3.3 缺少批量操作

#### 🟡 中等 — 没有批量 session 操作

当前只能逐个操作 session：
- `POST /api/sessions/:id/link` — 单个链接
- `DELETE /api/sessions/:id/link` — 单个取消
- `POST /api/session/:id/generate-title` — 单个生成标题

Swift UI 如果需要批量操作（如批量隐藏、批量链接），需要发 N 个请求。

**建议**: 考虑添加批量端点：
```
POST /api/sessions/batch/link
POST /api/sessions/batch/hide
```

---

## 四、数据一致性问题

### 4.1 输入验证不充分

#### 🔴 严重 — `parseInt` 缺少 NaN 检查（多个端点）

```typescript
// web.ts line 422 — /api/sync/sessions
const limit = parseInt(c.req.query('limit') ?? '100', 10);
// ❌ 没有 NaN 检查，输入 "abc" → NaN → 传入 SQL

// web.ts line 490 — /api/sessions
const limit = Math.min(limitParam ? parseInt(limitParam, 10) : 20, 100);
// ❌ parseInt("abc") → NaN → Math.min(NaN, 100) → NaN → 传入 SQL

// web.ts line 491
const offset = offsetParam ? parseInt(offsetParam, 10) : 0;
// ❌ 同上
```

**受影响端点清单**:
| 端点 | 行号 | 参数 |
|------|------|------|
| `GET /api/ai/audit` | 372-373 | limit, offset |
| `GET /api/sync/sessions` | 422 | limit |
| `GET /api/sessions` | 490-491 | limit, offset |
| `GET /api/sessions/:id/children` | 558-559 | limit, offset |
| `GET /api/search` | 715 | limit |
| `GET /api/search/semantic` | 756 | limit |
| `GET /api/costs/sessions` | 800 | limit |

**影响**: NaN 传入 better-sqlite3 的 `.all({ limit: NaN })` 会导致不可预测的行为（可能返回全部行或报错）。

**建议**: 使用工具函数统一验证：
```typescript
function parseLimit(raw: string | undefined, defaultVal = 20, max = 100): number {
  if (!raw) return defaultVal;
  const n = parseInt(raw, 10);
  if (Number.isNaN(n) || n < 1) return defaultVal;
  return Math.min(n, max);
}
```

---

#### 🟡 中等 — `/api/sessions/:id/timeline` 的 offset 验证不完整

```typescript
// web.ts line 577-582 — timeline 端点有 NaN 检查 ✅
// 但 /api/sessions（line 490-491）没有 ❌
```

**说明**: 仅 `timeline` 端点正确检查了 `Number.isNaN(limit)` 和 `Number.isNaN(offset)`。其他端点均未检查。

---

#### 🟡 中等 — 请求体验证不统一

一些端点对请求体字段有验证，一些没有：

```typescript
// /api/sessions/:id/link — 有验证 ✅
if (!body?.parentId) return c.json({ error: 'parentId required' }, 400);

// /api/summary — 有验证 ✅
if (!sessionId) return c.json({ error: 'Missing required field: sessionId' }, 400);

// /api/project/move — 有验证 ✅（使用 validationError）

// /api/project-aliases (POST) — 有验证 ✅
if (!body.alias || !body.canonical) return c.json({ error: '...' }, 400);
```

但有些端点的 `.catch(() => ({}))` 会静默吞掉 JSON 解析错误：

```typescript
// web.ts line 1123 — /api/summary
const body = await c.req.json().catch(() => ({}));
// 如果 body 是无效 JSON，会被静默当作空对象，然后因缺少 sessionId 返回 400
// 这掩盖了真正的错误（JSON 格式错误应该是 400 但 message 不同）
```

---

### 4.2 并发处理

#### 🟡 中等 — 写操作缺少幂等性保证

```typescript
// /api/titles/regenerate-all — 火后不管模式
(async () => {
    // 后台生成标题...
    // ❌ 如果同时触发两次，会并行运行两个生成器
})();
```

**问题**: `POST /api/titles/regenerate-all` 立即返回并在后台运行。如果客户端快速连续调用两次，会并行启动两个后台任务，导致重复工作和潜在的数据库写冲突。

**建议**: 添加一个 in-flight 标志或互斥锁：
```typescript
let titleRegenInProgress = false;
app.post('/api/titles/regenerate-all', async (c) => {
    if (titleRegenInProgress) return c.json({ error: 'Already running' }, 409);
    titleRegenInProgress = true;
    // ...
});
```

---

#### 🟢 建议 — `/api/dev/mock` 无并发保护

```typescript
app.post('/api/dev/mock', async (c) => {
    // 无互斥保护，可以被多次触发
    const stats = await populateMockData(db);
    return c.json(stats);
});
```

---

### 4.3 事务使用

#### 🟢 建议 — 数据库层事务使用正确

审计数据库层代码后确认：
- `insight-repo.ts` 的 `saveInsightText` 使用 `db.transaction()` ✅
- `fts-repo.ts` 的 `indexSessionContent` 和 `replaceFtsContent` 使用 `db.transaction()` ✅
- `parent-link-repo.ts` 的写操作是单语句 SQL ✅
- `session-repo.ts` 的 `upsertSession` 使用 `ON CONFLICT` 保证原子性 ✅

数据库层的事务使用是正确的。问题主要在 HTTP 层的输入验证。

---

## 五、安全问题

### 5.1 认证与授权

#### 🟡 中等 — Bearer Token 认证覆盖不完整

```typescript
// 只对 POST/PUT/DELETE/PATCH /api/* 做认证
const WRITE_METHODS = new Set(['POST', 'PUT', 'DELETE', 'PATCH']);
app.use('/api/*', async (c, next) => {
    if (WRITE_METHODS.has(c.req.method)) { /* 检查 token */ }
});

// 对 /api/ai/* 额外保护（包括 GET）
app.use('/api/ai/*', async (c, next) => { /* 检查 token */ });
```

**问题**:
- 大多数 GET 端点不受 token 保护。即使用户设置了 `httpBearerToken`，任何人（同一机器上的其他进程）都可以读取所有 session 数据、搜索结果、统计信息。
- 代码注释中承认了这一点："All GET endpoints are unauthenticated"。

**影响**: 在 localhost 场景下风险较低，但如果用户将 `httpHost` 设置为 `0.0.0.0`（虽然系统会发出警告），任何能访问该端口的人都能读取所有数据。

**建议**:
1. 当 `httpBearerToken` 存在时，对所有 `/api/*` 端点（包括 GET）都要求认证。
2. 或者至少提供一个 `httpAuthMode: 'write-only' | 'all'` 配置项。

---

#### 🟡 中等 — CORS 策略过宽

```typescript
// web.ts line 244-247
const isLocal =
    url.hostname === '127.0.0.1' ||
    url.hostname === 'localhost' ||
    url.hostname === '::1';
// 允许任何 localhost 端口的跨域请求
```

**问题**: 允许来自任何 `localhost` 端口的 CORS 请求。如果用户在浏览器中访问恶意网页，该网页可以通过 `localhost:3457` 读取 Engram 数据（如果未设置 token）。

**影响**: 本地开发工具场景下风险可控，但仍是一个攻击面。

---

### 5.2 路径遍历防护

#### 🟢 建议 — 路径规范化使用正确

```typescript
// web.ts — normalizeHttpPath 函数
const canonical = pathResolve(p);
if (!opts.allowOutsideHome) {
    const home = homedir();
    if (canonical !== home && !canonical.startsWith(`${home}/`)) {
        return { ok: false, error: `path must live under ${home}` };
    }
}
```

路径规范化逻辑是正确的：先展开 `~`，然后 `pathResolve` 折叠 `..`，最后检查是否在 `$HOME` 内。这可以防止 `~/../../etc/passwd` 类型的攻击。

---

### 5.3 速率限制

#### 🟡 中等 — 仅语义搜索有速率限制

```typescript
const semanticLimiter = createRateLimiter(30); // 30 req/min

// 只在 /api/search/semantic 上使用
if (!semanticLimiter()) {
    return c.json({ error: 'Rate limit exceeded' }, 429);
}
```

**问题**: 只有 `/api/search/semantic` 有速率限制。其他端点（包括昂贵的 `/api/summary`、`/api/titles/regenerate-all`、`/api/project/move`）没有任何限制。

**建议**:
1. 对所有 POST 端点添加全局速率限制器。
2. 特别是 AI 相关端点（`/api/summary`）应有独立限制。

---

## 六、性能问题

### 6.1 查询效率

#### 🟡 中等 — `/api/repos` 无分页

```typescript
app.get('/api/repos', (c) => {
    const rows = db.getRawDb()
        .prepare('SELECT * FROM git_repos ORDER BY last_commit_at DESC')
        .all();
    return c.json({ repos: rows });
});
```

**问题**: 无 `LIMIT`，返回所有 git repos。如果 repos 很多（理论可能），响应会很大。

**建议**: 添加分页参数。

---

#### 🟡 中等 — `/api/live` 对每个 session 做单独 DB 查询

```typescript
// web.ts line 1810-1826 — /api/live
const dbRow = s.filePath
    ? (db.getRawDb().prepare(
        'SELECT generated_title, summary, project, model, tier, agent_role FROM sessions WHERE file_path = ? LIMIT 1'
      ).get(s.filePath) as ...)
    : undefined;
```

**问题**: 在循环中对每个 live session 做独立的 SQL 查询（N+1 查询模式）。如果有 50 个 live sessions，就是 50 次查询。

**建议**: 批量查询，用 `WHERE file_path IN (...)` 一次获取所有匹配的 session 元数据。

---

#### 🟢 建议 — `/api/skills` 和 `/api/memory` 做文件系统遍历

```typescript
// /api/skills — 遍历 ~/.claude/plugins/cache/ 目录
// /api/memory — 遍历 ~/.claude/projects/ 目录下所有 memory 文件
```

这两个端点每次都重新遍历文件系统，没有缓存。如果文件很多，响应会很慢。

**建议**: 添加内存缓存（TTL 60秒）。

---

### 6.2 响应数据大小

#### 🟢 建议 — 部分端点返回过多字段

```typescript
// GET /api/sessions/:id — 返回完整的 SessionInfo 对象
return c.json(session); // 包含 filePath, sizeBytes 等客户端可能不需要的字段
```

**建议**: 考虑使用 `fields` 查询参数允许客户端选择需要的字段（GraphQL 风格），或为列表视图和详情视图提供不同的响应格式。

---

#### 🟡 中等 — `/api/costs/sessions` 使用原始 SQL

```typescript
// web.ts line 803-811
const rows = db.getRawDb().prepare(`
    SELECT c.*, s.source, s.project, s.start_time, s.summary
    FROM session_costs c JOIN sessions s ON c.session_id = s.id
    ORDER BY c.cost_usd DESC LIMIT ?
`).all(limit);
```

**问题**:
1. 使用 `SELECT *`（通过 `c.*`）可能返回不需要的列。
2. 绕过了 Database facade 层，直接访问 `getRawDb()`。这破坏了抽象层，使 metrics 层的变更无法被追踪。
3. 没有 `WHERE` 条件（如 `hidden_at IS NULL`），可能返回已隐藏 session 的成本数据。

**建议**:
1. 将此查询移入 `metrics-repo.ts`。
2. 添加 `hidden_at IS NULL` 过滤条件。
3. 明确列出需要的列，避免 `SELECT *`。

---

### 6.3 缓存策略

#### 🟡 中等 — 没有任何 HTTP 层缓存

所有 GET 端点都没有设置 `Cache-Control` 头。对于变化不频繁的数据（如 `/api/status`、`/api/repos`、`/api/sources`），缺少缓存会导致不必要的重复查询。

**建议**:
- 对 `/api/status`、`/api/repos`、`/api/sources` 等添加 `Cache-Control: max-age=5`。
- 对 `/api/sessions/:id` 添加 `Cache-Control: max-age=60`（session 数据变化不频繁）。

---

## 七、文档与可维护性

### 7.1 API 文档

#### 🔴 严重 — 没有 OpenAPI/Swagger 文档

整个 API 没有自动化文档。开发者（包括 Swift UI 开发者）需要阅读 `web.ts` 源码才能了解端点的行为、参数和响应格式。

**影响**:
1. 新开发者上手困难。
2. Swift 端需要手动保持与 HTTP API 的同步。
3. 无法使用 Postman/Swagger UI 等工具进行测试。

**建议**:
1. 使用 `@hono/zod-openapi` 或手动维护 OpenAPI spec。
2. 至少在 `docs/api.md` 中维护一个手动文档。

---

### 7.2 API 版本管理

#### 🟡 中等 — 没有版本管理策略

所有端点都在 `/api/*` 下，没有版本前缀（如 `/api/v1/*`）。如果需要破坏性变更，没有平滑迁移路径。

**当前情况**: Swift 应用通过 IPC（Unix socket）直接与 daemon 通信，而不是通过 HTTP API。这意味着 HTTP API 主要被 MCP 客户端和 CLI 使用。

**建议**: 至少在文档中声明 API 的稳定性保证。如果未来有第三方客户端，考虑添加版本前缀。

---

### 7.3 向后兼容性

#### 🟢 建议 — 已有良好的兼容性意识

代码中有多处体现了向后兼容性的考虑：
- `/api/search/semantic` 作为向后兼容端点保留（委托给 hybrid search）。
- `SSE endpoint` 的 TODO 注释表明未来会添加但不会破坏现有端点。
- `SyncCursor` 分页机制支持增量同步。

---

## 八、错误处理问题

### 8.1 异常捕获

#### 🟡 中等 — 部分端点异常处理不一致

```typescript
// /api/search — 有 try/catch ✅
try {
    const result = await handleSearch(...);
    return c.json(result);
} catch (err) {
    return c.json({ results: [], ..., warning: `Search failed: ${String(err)}` });
}

// /api/sessions — 没有 try/catch ❌
app.get('/api/sessions', (c) => {
    const sessions = db.listSessions({...}); // 如果 DB 报错，会返回 500 但没有友好消息
    return c.json({...});
});

// /api/stats — 有 try/catch（隐式通过 handleStats）
```

**问题**: 有些端点有 try/catch 包裹，有些直接让异常冒泡。Hono 会捕获未处理的异常并返回 500，但响应格式不一致。

**建议**: 添加全局错误处理中间件：
```typescript
app.onError((err, c) => {
    console.error(`[api] Unhandled error: ${err}`);
    return c.json({
        error: {
            name: 'InternalServerError',
            message: process.env.NODE_ENV === 'development' ? err.message : 'Internal server error',
            retry_policy: 'safe'
        }
    }, 500);
});
```

---

### 8.2 错误消息泄露

#### 🟡 中等 — 部分错误消息泄露内部细节

```typescript
// /api/sessions/:id/timeline line 652
return c.json({ error: `Failed to read session: ${err}` }, 500);
// err 可能包含文件路径、堆栈信息等

// /api/summary line 1174
return c.json({ error: msg }, 500); // msg 可能来自 AI API 的错误
```

**建议**: 生产环境下返回通用错误消息，开发环境下可返回详细信息。

---

## 九、Swift IPC 通信审计

### 9.1 架构观察

#### 🟢 建议 — IPC 架构设计合理

Swift 应用通过 Unix socket IPC（而非 HTTP）与 daemon 通信。这是一个好的设计决策：

1. **读操作**（`EngramServiceReadProvider`）：直接读取 SQLite（GRDB 只读连接），无需经过 HTTP 层。
2. **写操作**（`ServiceWriterGate`）：通过 IPC 发送写命令到 daemon，daemon 持有数据库写锁。
3. **事件通知**：daemon 通过 stdout JSON lines 推送事件到 Swift。

这种设计避免了 HTTP 的开销和网络延迟，同时保持了单写者纪律。

---

### 9.2 Swift IPC vs HTTP API 功能对比

#### 🟡 中等 — Swift IPC 提供了 HTTP API 没有的功能

| 功能 | Swift IPC | HTTP API |
|------|-----------|----------|
| `setFavorite` | ✅ | ❌ |
| `setSessionHidden` | ✅ | ❌ |
| `renameSession` | ✅ | ❌ |
| `hideEmptySessions` | ✅ | ❌ |
| `exportSession` | ✅ | ❌ |

**说明**: 这些功能只通过 Swift IPC 暴露，HTTP API 客户端无法使用。

**建议**: 如果这些功能也需要 MCP 客户端使用，应添加对应的 HTTP 端点。如果只面向 Swift UI，可以不添加。

---

## 十、改进建议优先级汇总

### 🔴 严重（应尽快修复）

| # | 问题 | 位置 | 建议 |
|---|------|------|------|
| 1 | `parseInt` 缺少 NaN 检查 | 7个端点 | 添加 `parseLimit/parseOffset` 工具函数 |
| 2 | 缺少 Insights 查询/搜索 API | web.ts | 添加 `GET /api/insights` 端点 |
| 3 | 缺少 `get_context` HTTP API | web.ts | 添加 `GET /api/sessions/:id/context` |
| 4 | 没有 API 文档 | 全局 | 添加 OpenAPI spec 或手动文档 |

### 🟡 中等（建议修复）

| # | 问题 | 位置 | 建议 |
|---|------|------|------|
| 5 | URL 单复数不一致 | `/api/session/` vs `/api/sessions/` | 统一为复数 |
| 6 | 路径层级风格不一致 | `/api/project-aliases` vs `/api/project/` | 统一风格 |
| 7 | 错误响应格式不统一 | 3+ 种格式 | 统一为结构化包络 |
| 8 | DELETE 端点用 body 传参 | 2个端点 | 改为路径/查询参数 |
| 9 | 分页格式不统一 | 多个端点 | 定义 `PaginatedResponse<T>` |
| 10 | `/api/live` N+1 查询 | web.ts line 1810 | 批量查询 |
| 11 | Bearer Token 覆盖不完整 | 所有 GET 端点 | 配置化认证范围 |
| 12 | 速率限制不完整 | 仅语义搜索 | 扩展到 POST 端点 |
| 13 | 缺少 HTTP 缓存头 | 所有 GET 端点 | 添加 Cache-Control |
| 14 | `/api/costs/sessions` 绕过 facade | web.ts | 移入 metrics-repo |
| 15 | 后台任务无并发保护 | regenerate-all | 添加 in-flight 标志 |
| 16 | 缺少 `export` HTTP 端点 | web.ts | 添加 |
| 17 | 缺少全局错误处理中间件 | web.ts | 添加 `app.onError` |

### 🟢 建议（可选优化）

| # | 问题 | 位置 | 建议 |
|---|------|------|------|
| 18 | CORS 策略过宽 | web.ts | 考虑限制特定端口 |
| 19 | 无 API 版本管理 | 全局 | 至少文档声明稳定性 |
| 20 | `/api/repos` 无分页 | web.ts | 添加 LIMIT |
| 21 | 部分错误消息泄露细节 | 多个端点 | 生产环境隐藏 |
| 22 | `/api/skills` 和 `/api/memory` 无缓存 | web.ts | 添加 TTL 缓存 |

---

## 十一、总结

Engram 的 Web API 设计整体上是**实用且功能完整**的。作为本地开发工具的 API，它在安全性方面做了合理的权衡（localhost-only、$HOME 路径限制、可选 Bearer Token）。

**主要优点**:
1. 丰富的搜索功能（FTS + 语义 + RRF 融合）
2. 完善的父子会话链接管理 API
3. 项目迁移/归档功能设计合理（dry-run、undo、batch）
4. 良好的可观测性（tracing、metrics、logging 中间件）
5. Swift IPC 架构避免了不必要的 HTTP 开销

**主要改进方向**:
1. **输入验证统一化** — 最紧迫的问题，`parseInt` NaN 检查缺失可导致不可预测行为
2. **错误响应格式统一** — 减少客户端解码复杂度
3. **补齐缺失端点** — insights 查询、get_context、export
4. **添加 API 文档** — 降低维护和集成成本

---

*报告结束。如有疑问请联系 api-auditor。*
