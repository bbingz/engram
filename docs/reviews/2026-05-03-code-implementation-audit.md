# Engram 代码实现质量审计报告

**审计人**: code-auditor
**日期**: 2026-05-03
**项目**: Engram — Cross-tool AI session aggregator (TypeScript MCP Server + macOS SwiftUI)
**代码行数**: ~11,300 行 TypeScript (src/core/ + src/index.ts + src/daemon.ts + src/web.ts)
**测试**: 114 个测试文件, 1276 个测试用例, ~54s

---

## 一、性能问题

### 🔴 P1: `backfillSuggestedParents` 中存在 N+1 查询模式

**文件**: `src/core/db/maintenance.ts:440-495`
**严重程度**: 🔴 严重

```typescript
for (const candidate of candidates) {
    // 每个 candidate 都执行一次独立的 parent 查询
    const parents = db.prepare(`
      SELECT id, start_time, end_time, project, cwd FROM sessions
      WHERE source IN ('claude-code', 'claude')
        AND start_time <= ?
        AND start_time >= datetime(?, '-24 hours')
        AND parent_session_id IS NULL
    `).all(candidate.start_time, candidate.start_time) as ...;
    // ... score each parent
}
```

**问题**: 对每个候选会话都执行一次独立的数据库查询来获取潜在父会话。当有 500 个候选时（LIMIT 500），会执行 500 次独立查询，每次扫描 sessions 表的子集。

**改进建议**:
- 预先计算所有候选的最小/最大 start_time 范围
- 执行一次批量查询获取所有可能的父会话
- 在内存中进行时间窗口匹配和评分

```typescript
// 改进方案：单次批量查询
const timeRange = computeTimeRange(candidates); // min-24h to max
const allParents = db.prepare(`
  SELECT id, start_time, end_time, project, cwd FROM sessions
  WHERE source IN ('claude-code', 'claude')
    AND start_time >= ? AND start_time <= ?
    AND parent_session_id IS NULL
`).all(timeRange.min, timeRange.max);
// 然后在内存中对每个 candidate 匹配并评分
```

---

### 🔴 P2: `backfillCodexOriginator` 使用同步文件 I/O 阻塞事件循环

**文件**: `src/core/db/maintenance.ts:395-430`
**严重程度**: 🔴 严重

```typescript
for (const { id, file_path } of candidates) {
    try {
      const fd = openSync(file_path, 'r');          // 阻塞
      const chunk = Buffer.alloc(16384);
      const bytesRead = readSync(fd, chunk, 0, 16384, 0);  // 阻塞
      closeSync(fd);                                 // 阻塞
      // ...
    }
}
```

**问题**: `openSync`/`readSync`/`closeSync` 是同步操作，在 daemon 主循环中执行时会阻塞整个事件循环。如果有 500 个候选文件，每个文件读取 16KB，I/O 延迟可能显著阻塞 HTTP 服务和 watcher。

**额外风险**: 如果 `readSync` 在 `openSync` 之后抛出异常，`closeSync` 不会被执行，导致文件描述符泄漏。

**改进建议**:
```typescript
import { open, read, close } from 'node:fs/promises';

for (const { id, file_path } of candidates) {
    let fd: FileHandle | undefined;
    try {
      fd = await open(file_path, 'r');
      const { buffer, bytesRead } = await fd.read(Buffer.alloc(16384), 0, 16384, 0);
      const text = buffer.toString('utf8', 0, bytesRead);
      // ...
    } catch { /* skip */ }
    finally { await fd?.close(); }
}
```

---

### 🟡 P3: `MetricsCollector.rollup()` 内存占用不可控

**文件**: `src/core/metrics.ts:139-175`
**严重程度**: 🟡 中等

```typescript
const allValues = this.db
    .prepare(
      `SELECT name, substr(ts, 1, 13) as hour, tags, value FROM metrics ORDER BY name, hour, tags, value`,
    )
    .all() as ...;

const valuesByGroup = new Map<string, number[]>();
for (const v of allValues) {
    // 把所有值加载到内存
    arr.push(v.value);
}
```

**问题**: 当 metrics 表积累了大量记录时（每 60s 上报一次 + 每 5s flush 一次 buffer），全量加载到内存中计算 p95 可能导致 OOM。例如 24 小时的数据量：约 17,280 条记录 × 多种 metric name。

**改进建议**:
- 使用 SQL 窗口函数或近似算法计算 p95
- 或者只对 `metrics_hourly` 做增量 rollup（只处理上次 rollup 之后的数据）

---

### 🟡 P4: `detectOrphans` 全量加载 + 逐条异步检查

**文件**: `src/core/db/maintenance.ts:313-380`
**严重程度**: 🟡 中等

```typescript
const rows = db.prepare(`
    SELECT id, source, file_path, source_locator, orphan_status, orphan_since
    FROM sessions
    WHERE (source_locator IS NOT NULL AND source_locator != '')
       OR (file_path IS NOT NULL AND file_path != '')
  `).all();

for (const row of rows) {
    accessible = await adapter.isAccessible(locator);  // 逐条 await
    // ...
}
```

**问题**:
1. 加载全部会话到内存（随着会话增长可能成为瓶颈）
2. 每个文件单独 `await adapter.isAccessible()`，无法利用批量 I/O

**改进建议**:
- 按 source 分组，让 adapter 提供批量 `areAccessible(paths)` 方法
- 或者使用 `Promise.allSettled` 并发检查（限制并发数如 50）

---

### 🟡 P5: `findDuplicateInsight` 全表扫描内存匹配

**文件**: `src/core/db/insight-repo.ts:53-68`
**严重程度**: 🟡 中等

```typescript
const rows = wing
    ? db.prepare(
        'SELECT * FROM insights WHERE wing = ? ORDER BY created_at DESC LIMIT 200'
      ).all(wing) as InsightRow[]
    : db.prepare(
        'SELECT * FROM insights WHERE wing IS NULL ORDER BY created_at DESC LIMIT 200'
      ).all() as InsightRow[];

for (const row of rows) {
    if (normalizeForDedup(row.content) === normalized) return row;
}
```

**问题**: 去重逻辑依赖加载最多 200 行全文内容到内存，然后逐行比较。虽然 LIMIT 200 控制了上界，但每次 `save_insight` 都会做这个扫描。

**改进建议**:
- 存储 content 的 hash（如 SHA-256）在单独列上建索引
- 用 SQL WHERE hash = ? 直接查找

---

### 🟡 P6: Watcher 缺少去抖/防抖机制

**文件**: `src/core/watcher.ts:103-130`
**严重程度**: 🟡 中等

```typescript
watcher.on('add', handleChange);
watcher.on('change', handleChange);
```

**问题**: chokidar 的 `awaitWriteFinish: { stabilityThreshold: 2000 }` 虽然提供了一定的写入稳定性检测，但对于高频写入场景（如 git 操作同时修改多个 JSONL 文件），每个文件变更都会触发一次独立的 `indexFile` 流程，包括文件读取、消息流式解析、数据库写入。多个 `indexFile` 可以同时执行（无并发限制），可能导致 I/O 风暴。

**改进建议**:
- 引入工作队列 + 并发限制（如 max 3 concurrent indexFile）
- 或者使用批量去抖（收集 500ms 内的变更，批量处理）

---

### 🟡 P7: `indexAll` 完全串行处理

**文件**: `src/core/indexer.ts:250-340`
**严重程度**: 🟡 中等

```typescript
for (const adapter of this.adapters) {
    for await (const filePath of adapter.listSessionFiles()) {
        // 逐文件串行处理
        const info = await adapter.parseSessionInfo(filePath);
        for await (const msg of adapter.streamMessages(filePath)) { ... }
    }
}
```

**问题**: 全量扫描 14 个适配器的所有文件是完全串行的。首次启动或全量重建索引时可能很慢。

**改进建议**:
- 不同 adapter 之间可以并行（不同 source 互不影响）
- 同一 adapter 内可以控制并发（如 5 个文件并行处理）

---

### 🟢 P8: `getSourceStats` 双查询可合并

**文件**: `src/core/db/session-repo.ts:261-295`
**严重程度**: 🟢 建议

`getSourceStats` 执行两次查询：一次获取源统计，一次获取最近 7 天的日统计。可以用一次 JOIN 或子查询完成。

---

## 二、代码质量

### 🔴 C1: `initVectorDeps` 吞掉所有异常（含编程错误）

**文件**: `src/core/bootstrap.ts:73-87`
**严重程度**: 🔴 严重

```typescript
function initVectorDeps(db, opts): VectorDeps | null {
  try {
    // ...
    return { vectorStore, embeddingClient, embeddingIndexer };
  } catch {
    return null;  // 吞掉所有异常
  }
}
```

**问题**: `catch` 块没有区分预期错误（sqlite-vec 加载失败、Ollama 不可达）和编程错误（TypeError、ReferenceError、SyntaxError）。如果 `SqliteVecStore` 构造函数中有 bug，也会被静默吞掉，返回 null，导致难以调试。

**改进建议**:
```typescript
} catch (err) {
    if (err instanceof Error && (
        err.message.includes('sqlite-vec') ||
        err.message.includes('SQLITE_ERROR')
    )) {
        return null;  // 预期的向量存储不可用
    }
    throw err;  // 编程错误应向上传播
}
```

---

### 🟡 C2: `ai-audit.ts` 大量使用 `as any` 类型断言

**文件**: `src/core/ai-audit.ts:218-279`（6 处 `as any[]` 和 `as any`）
**严重程度**: 🟡 中等

```typescript
.all({ ...params, limit, offset }) as any[];
.get(params) as any;
.get(id) as any;
```

**问题**: 虽然 `biome` lint 对此有豁免注释，但类型断言绕过了 TypeScript 的类型检查，容易在字段名变更时引入运行时错误。

**改进建议**:
- 定义 `AuditEntryRow`、`AuditStatsRow` 等接口类型
- 使用 `as AuditEntryRow[]` 替代 `as any[]`

---

### 🟡 C3: `Database` facade 过度委托（350+ 行纯转发）

**文件**: `src/core/db/database.ts`
**严重程度**: 🟡 中等

`Database` 类包含 80+ 个方法，每个都是对底层 repo 模块的纯转发调用：

```typescript
upsertSession(session: SessionInfo): void {
    sessions.upsertSession(this.db, session);
}
getSessionByFilePath(filePath: string): SessionInfo | null {
    return sessions.getSessionByFilePath(this.db, filePath);
}
// ... 80+ 个类似方法
```

**问题**: 这个 facade 增加了间接层，但提供的价值有限。所有调用者本可以直接导入 repo 模块。这导致每次添加新功能需要在三个地方修改：repo → facade → 调用者。

**改进建议**:
- 考虑让调用者直接使用 `db.raw` + repo 模块
- 或者保留 facade 但使用更轻量的方式（如 Proxy 或 getter）

---

### 🟡 C4: `web.ts` 过大（1978 行）

**文件**: `src/web.ts`
**严重程度**: 🟡 中等

单个文件包含所有 HTTP 路由、中间件、错误处理、视图渲染。这使得：
- 代码导航困难
- 合并冲突概率高
- 测试隔离困难

**改进建议**: 按功能域拆分路由：
- `src/web/routes/sessions.ts` — session CRUD
- `src/web/routes/projects.ts` — project move/archive/undo
- `src/web/routes/search.ts` — search + semantic
- `src/web/middleware/` — auth, tracing, CORS

---

### 🟢 C5: `watcher.ts` handleChange 内部无错误边界

**文件**: `src/core/watcher.ts:103-125`
**严重程度**: 🟢 建议

```typescript
const handleChange = async (filePath: string) => {
    if (opts?.shouldSkip?.(filePath)) return;
    await runWithContext(
      { requestId: randomUUID(), source: 'watcher' },
      async () => {
        for (const [watchPath, adapter] of Object.entries(watchMap)) {
          if (filePath.startsWith(watchPath)) {
            const result = await indexer.indexFile(adapter, filePath);
            // ...
            break;
          }
        }
      },
    );
};
```

**问题**: 如果 `indexFile` 抛出未捕获异常，`handleChange` 返回的 Promise rejection 不会被任何地方处理（chokidar 的事件回调）。虽然 `indexFile` 内部有 try/catch，但如果出现意外错误（如内存不足），异常会成为 unhandled rejection。

**改进建议**: 添加顶层 catch：
```typescript
const handleChange = async (filePath: string) => {
    try {
        // ...existing code...
    } catch (err) {
        // watcher event handler must not crash
    }
};
```

---

## 三、资源管理

### 🔴 R1: `web.ts` CLI 入口缺少 shutdown handler

**文件**: `src/web.ts:1944-1978`（文件末尾）
**严重程度**: 🔴 严重

```typescript
if (isMain) {
    const db = new Database(join(DB_DIR, 'index.sqlite'));
    // ...
    serve({ fetch: app.fetch, port, hostname: host }, (info) => {
        process.stderr.write(`[engram-web] Listening on ...\n`);
    });
    // 没有 SIGTERM/SIGINT handler！
    // 没有 db.close()！
}
```

**问题**: 当 `web.ts` 作为独立 CLI 运行时，SIGTERM/SIGINT 不会关闭数据库连接，可能导致 WAL 文件残留和数据损坏。

**改进建议**:
```typescript
const server = serve({ fetch: app.fetch, port, hostname: host });
const cleanup = () => { server.close(); db.close(); process.exit(0); };
process.on('SIGTERM', cleanup);
process.on('SIGINT', cleanup);
```

---

### 🟡 R2: daemon 定时器未 `unref()`

**文件**: `src/daemon.ts:295-490`
**严重程度**: 🟡 中等

daemon 创建了 9 个 `setInterval`/`setTimeout` 定时器，但没有调用 `.unref()`。与 MCP server 的 `lifecycle.ts` 形成对比——后者正确调用了 `.unref()`。

**影响**: 如果 `SIGTERM`/`SIGINT` handler 因某种原因未触发，这些定时器会阻止进程退出。

**说明**: 对 daemon 而言这可能是设计决策（daemon 应该常驻），但建议在 `createShutdownHandler` 中添加 `unref()` 以确保 graceful shutdown 后能快速退出。

---

### 🟡 R3: `shutdownHandler` 没有 `metrics.flush()` 的显式调用

**文件**: `src/core/bootstrap.ts:272-305`
**严重程度**: 🟡 中等

```typescript
export function createShutdownHandler(resources: ShutdownResources, log?): () => void {
  return () => {
    if (shuttingDown) return;
    shuttingDown = true;
    // Clear timers
    for (const timer of resources.timers) { ... }
    // Stop collectors
    resources.metrics?.destroy();  // destroy() 内部调用 flush()
    resources.watcher?.close();
    resources.webServer?.close();
    resources.db.close();
  };
}
```

**好消息**: `MetricsCollector.destroy()` 内部确实调用了 `this.flush()`。但 flush 中如果出错（数据库已关闭），会丢失 metrics 数据。`db.close()` 在最后执行是正确的。

**建议**: 确保 `resources.metrics?.destroy()` 在 `db.close()` 之前执行——目前是这样，但注释说明这个顺序依赖很重要。

---

### 🟢 R4: `shutdownHandler` 缺少 `async` 支持

**文件**: `src/core/bootstrap.ts:272-305`
**严重程度**: 🟢 建议

当前 `createShutdownHandler` 返回同步函数。但 `webServer?.close()` 可能涉及异步操作（如关闭 HTTP 连接）。虽然 Node.js 在 `process.exit(0)` 时会强制终止，但对于优雅关闭，可以考虑返回 Promise 并等待连接排空。

---

## 四、数据库设计与查询效率

### 🟡 D1: 缺少 `sessions.project` 索引

**文件**: `src/core/db/migration.ts`
**严重程度**: 🟡 中等

sessions 表有以下索引：
```sql
CREATE INDEX IF NOT EXISTS idx_sessions_source ON sessions(source);
CREATE INDEX IF NOT EXISTS idx_sessions_start_time ON sessions(start_time);
CREATE INDEX IF NOT EXISTS idx_sessions_cwd ON sessions(cwd);
CREATE INDEX IF NOT EXISTS idx_sessions_file_path ON sessions(file_path);
CREATE INDEX IF NOT EXISTS idx_sessions_agent_role ON sessions(agent_role);
CREATE INDEX IF NOT EXISTS idx_sessions_tier ON sessions(tier);
CREATE INDEX IF NOT EXISTS idx_sessions_parent ON sessions(parent_session_id, start_time DESC);
```

**缺失索引**: `sessions.project` 列没有索引，但被大量查询使用：
- `listSessions` 的 project 过滤
- `countSessions` 的 project 过滤
- `statsGroupBy('project')`
- `getToolAnalytics` 的 project 过滤
- `getFileActivity` 的 project 过滤
- `getSourceStats` 的 daily counts 查询

**改进建议**:
```sql
CREATE INDEX IF NOT EXISTS idx_sessions_project ON sessions(project) WHERE project IS NOT NULL;
```

---

### 🟡 D2: `sessions.origin` 列缺少索引

**严重程度**: 🟡 中等

`origin` 列用于多节点同步过滤、stats groupBy、listSessions 过滤，但没有专门索引。查询中使用 `COALESCE(NULLIF(origin, ''), 'local')` 表达式也无法使用普通索引。

---

### 🟡 D3: `listSessionsAfterCursor` 未 JOIN session_local_state

**文件**: `src/core/db/session-repo.ts:190-220`
**严重程度**: 🟡 中等

```typescript
export function listSessionsAfterCursor(db, cursor, limit): AuthoritativeSessionSnapshot[] {
  const rows = cursor
    ? db.prepare(`
        SELECT * FROM sessions
        WHERE hidden_at IS NULL AND ...
        ORDER BY indexed_at ASC, id ASC
        LIMIT @limit
      `).all(...)
    : db.prepare(`...`).all(...);
  return rows.map(r => rowToAuthoritativeSnapshot(r));
}
```

**问题**: 该函数返回 `AuthoritativeSessionSnapshot` 类型，不需要 `session_local_state` JOIN。但如果其他调用者期望看到本地路径信息（如 `local_readable_path`），可能会得到空值。这是正确的设计（sync 不需要 local path），但值得文档化。

---

### 🟢 D4: migration.ts 中使用 PRAGMA table_info 的冗余检查

**文件**: `src/core/db/migration.ts:15-70`
**严重程度**: 🟢 建议

migration 使用 `PRAGMA table_info(sessions)` 获取已有列，然后逐一 `ALTER TABLE ADD COLUMN`。这个模式本身是正确的（幂等），但每次启动都执行所有检查。对于已稳定的 schema，可以：
- 在 metadata 中存储上次检查的列集合 hash
- 只有 hash 变化时才执行 PRAGMA

**注意**: 这是微优化，当前实现已经足够快（PRAGMA 只读，很快）。

---

## 五、测试质量

### 🟡 T1: 缺少 daemon.ts 集成测试

**严重程度**: 🟡 中等

114 个测试文件覆盖了：adapters（16）、core（24+）、tools（12）、web（10）、cli（3）。但 **daemon.ts 本身没有集成测试**。

daemon.ts 是最复杂的入口点（530 行），包含：
- 定时器注册（9 个）
- 信号处理
- 初始化序列
- 事件输出
- 多个后台任务

**风险**: daemon 的初始化顺序、shutdown 流程、定时器交互缺乏测试覆盖。

**建议**: 创建 `tests/integration/daemon.test.ts`，测试：
1. `createDaemonDeps` 初始化成功
2. `createShutdownHandler` 正确清理所有资源
3. 定时器在 shutdown 后不再触发

---

### 🟡 T2: 缺少竞态条件测试

**严重程度**: 🟡 中等

watcher 和 indexer 之间的交互缺少并发测试：
- 同一文件同时被 watcher 和 periodic rescan 处理
- `indexAll` 和 `indexFile` 并发执行时的行为
- `shouldSkip` 在 project move 期间是否正确阻止所有事件

---

### 🟢 T3: 测试质量总体良好

**说明**:
- 测试使用真实 fixtures（无 mocking），可靠性高
- 适配器测试覆盖所有 15 个 source
- 数据库迁移测试验证幂等性
- Web API 测试覆盖核心端点

---

## 六、安全与稳健性

### 🟡 S1: `config.ts` 中的 Keychain 哨兵值处理

**文件**: `src/core/config.ts:217-245`
**严重程度**: 🟡 中等

```typescript
if (migrated.aiApiKey === '@keychain') {
    const kc = readKeychainValue('aiApiKey');
    if (!kc) {
        process.stderr.write('[engram] WARNING: ...\n');
        delete migrated.aiApiKey;  // 静默降级
    } else {
        migrated.aiApiKey = kc;
    }
}
```

**问题**: 当 Keychain 值缺失时，`aiApiKey` 被静默删除。后续所有 AI 功能（summary、embedding）会以"未配置"的方式失败，但用户可能不知道原因。虽然 stderr 有警告，但在 daemon 场景下 stderr 不一定可见。

**改进建议**:
- 在 daemon 事件流中输出 `warning` 事件
- 在 HTTP `/api/status` 中暴露 Keychain 配置状态（不暴露实际值）

---

### 🟡 S2: `web.ts` 的 CORS 允许任何 localhost origin

**文件**: `src/web.ts:135-160`
**严重程度**: 🟡 中等

```typescript
const isLocal = url.hostname === '127.0.0.1' || url.hostname === 'localhost' || url.hostname === '::1';
if (!isLocal) { return c.text('CORS rejected', 403); }
c.header('Access-Control-Allow-Origin', origin);
```

**问题**: 允许任何 localhost origin 的跨域请求。虽然注释说明这是"可接受的本地开发工具"设计，但任何运行在 localhost 的 web 页面（包括恶意页面）都可以发起对 Engram API 的请求。

**说明**: 这是已知的权衡（本地工具的安全模型），且有 bearer token 保护写操作。读操作（session 列表、搜索）确实暴露给任何 localhost 页面。

---

## 七、进程生命周期

### 🟢 L1: MCP Server 生命周期设计合理

**文件**: `src/index.ts:740-755`, `src/core/lifecycle.ts`

MCP server 的 4 层进程生命周期设计非常健全：
1. stdin end/close（管道断开检测）
2. Parent PID 存活检查（2s 轮询，unref）
3. 空闲超时（已禁用 `idleTimeoutMs: 0`——正确）
4. SIGTERM/SIGINT 信号

`unref()` 的正确使用确保这些机制不会阻止进程退出。

---

### 🟢 L2: `createShutdownHandler` 幂等性正确

**文件**: `src/core/bootstrap.ts:267-305`

```typescript
let shuttingDown = false;
return () => {
    if (shuttingDown) return;
    shuttingDown = true;
    // ...
};
```

shutdown handler 使用 `shuttingDown` 标志确保幂等——即使 SIGTERM 和 stdin close 同时触发，清理也只执行一次。

---

## 八、总结与优先级排序

### 优先修复（严重）

| # | 问题 | 文件 | 影响 |
|---|------|------|------|
| P1 | backfillSuggestedParents N+1 查询 | maintenance.ts | 大数据量时启动缓慢 |
| P2 | backfillCodexOriginator 同步 I/O | maintenance.ts | 阻塞事件循环 + fd 泄漏 |
| C1 | initVectorDeps 吞掉所有异常 | bootstrap.ts | 隐藏编程错误 |
| R1 | web.ts CLI 缺少 shutdown handler | web.ts | 数据库连接泄漏 |

### 建议修复（中等）

| # | 问题 | 文件 | 影响 |
|---|------|------|------|
| P3 | MetricsCollector.rollup() 内存不可控 | metrics.ts | 大数据量 OOM |
| P4 | detectOrphans 全量加载 + 逐条检查 | maintenance.ts | 大数据量时慢 |
| P5 | findDuplicateInsight 全表扫描 | insight-repo.ts | save_insight 变慢 |
| P6 | Watcher 缺少去抖 | watcher.ts | 高频写入时 I/O 风暴 |
| C2 | ai-audit.ts 类型断言 | ai-audit.ts | 类型安全缺失 |
| C3 | Database facade 过度委托 | database.ts | 代码维护负担 |
| C4 | web.ts 过大 | web.ts | 可维护性差 |
| D1 | 缺少 project 索引 | migration.ts | project 查询全表扫描 |
| R2 | daemon 定时器未 unref | daemon.ts | shutdown 延迟 |
| T1 | 缺少 daemon 集成测试 | tests/ | 回归风险 |

### 优化建议（低优先级）

| # | 问题 | 文件 |
|---|------|------|
| P7 | indexAll 完全串行 | indexer.ts |
| P8 | getSourceStats 双查询 | session-repo.ts |
| C5 | watcher handleChange 无顶层 catch | watcher.ts |
| D2 | origin 缺少索引 | migration.ts |
| D4 | PRAGMA 冗余检查 | migration.ts |
| S1 | Keychain 静默降级 | config.ts |
| S2 | CORS 允许 localhost | web.ts |

---

## 九、整体评价

**优势**:
1. **架构设计优秀**: Bootstrap 工厂模式、Adapter 模式、Facade 模式清晰分层
2. **迁移策略健壮**: 幂等迁移、PRAGMA table_info 检查、FTS 版本强制重建
3. **进程生命周期完善**: MCP server 4 层生命周期、daemon 信号处理、幂等 shutdown
4. **测试覆盖充分**: 1276 个测试、真实 fixtures、无 mocking 策略
5. **事务使用得当**: 所有批量写操作（FTS、metrics、migration）使用 DB 事务
6. **向后兼容良好**: FTS 版本升级、schema 迁移、降级路径完备
7. **可观测性全面**: metrics、traces、logs、alerts、ai-audit 全栈覆盖

**风险点**:
1. 大数据量场景下的性能（N+1 查询、全量加载）
2. 同步文件 I/O 在 daemon 主循环中的阻塞风险
3. 部分异常处理过于宽泛（`catch {}` 吞掉所有错误）
4. web.ts 作为独立入口时缺少资源管理

**总体评分**: 8.2/10 — 代码质量高、架构合理、测试充分。主要改进方向是大数据量场景下的性能优化和部分异常处理的精细化。
