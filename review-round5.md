# Engram Round 5 Code Review — 全新角度深度扫描

> 审查日期：2026-05-21
> 方法：6 个子 agent，每人一个全新审视角度（非复读 R3/R4）
> 基础 commit：`9e43f40b fix: remediate DeepSeek round-3 + round-4 review findings`（95 文件，+2864/-618）

---

## 总体统计

| 审查角度 | P0 | P1 | P2 | 小计 |
|---------|----|----|----|------|
| TS Core — 并发/竞态/事务安全 | 1 | 3 | 4 | **8** |
| TS Adapters — 数据完整性/边界/模糊测试 | 0 | 3 | 9 | **12** |
| TS Tools — 输入验证/协议合规/注入 | 2 | 4 | 4 | **10** |
| Swift UI — 状态一致性/内存/可访问性 | 0 | 2 | 8 | **10** |
| Swift Core — Sendable/Actor/数据竞争 | 0 | 3 | 6 | **9** |
| Swift Service — 错误恢复/优雅关闭/资源泄漏 | 0 | 6 | 6 | **12** |
| **合计** | **3** | **21** | **37** | **61** |

---

## P0 — 崩溃 / 数据丢失 / 安全

### TS Core

**R5-1** `session-writer.ts:15-61` + `database.ts:227-248` + `index-job-repo.ts:36-69` — **嵌套事务必然崩溃**

`SessionSnapshotWriter.writeAuthoritativeSnapshot` 在 `db.transaction()` 回调内调用两个各自创建独立事务的方法：
1. `Database.deleteIndexArtifacts`（database.ts:228，分层降级时触发）
2. `insertIndexJobs`（index-job-repo.ts:54，每个 merge 操作触发）

better-sqlite3 明确禁止嵌套事务——在已打开的事务回调中调用 `.transaction()` 会抛出错误。`insertIndexJobs` 路径在每次 session merge 时都会触发，意味着 `writeAuthoritativeSnapshot` 几乎每次调用都会崩溃。

> 注：TypeScript 运行时是 dev/reference 代码（CLAUDE.md），不影响 Swift 产品。但这是 TS 工具链中的真实可达崩溃路径。

### TS Tools

**R5-2** `web.ts:950-965` + `link_sessions.ts:37-112` — **`/api/link-sessions` 缺少 `$HOME` 路径限制**

与其他写端点（`/api/project/*`、`/api/lint`）不同，`/api/link-sessions` 完全跳过 `normalizeHttpPath()` 验证。可直接在文件系统任何位置创建目录和符号链接。

```typescript
app.post('/api/link-sessions', async (c) => {
    const targetDir = (body as Record<string, unknown>).targetDir as string | undefined;
    if (!targetDir) { return c.json({ error: 'Missing required field: targetDir' }, 400); }
    const result = await handleLinkSessions(db, { targetDir });
    // 无 normalizeHttpPath，无 $HOME 限制
```

**R5-3** `web.ts:912-947` — **`/api/handoff` 缺少路径验证**

同样跳过 `normalizeHttpPath()`，任意路径可传入。

---

## P1 — 功能性 Bug

### TS Core（3 个）

**R5-4** `indexer.ts:341-354,574-590` — **Snapshot 写入后在事务外追加 cost/tool/parent-link 数据，崩溃导致数据不完整**

`writeAuthoritativeSnapshot` 返回后，立即在事务外执行 `applyParentLink` + `writeExtractedData`。崩溃在此窗口内会导致 session 存在但无 cost/tool 数据。虽有 `backfillCosts()` 补救，但 tools/files/parent-link 无对应回填机制。

**R5-5** `watcher.ts:111-133` + `indexer.ts:277,526` — **Watcher 与 Indexer 的去重检查存在竞态窗口**

`isIndexed` 检查（简单 SELECT，无锁）在事务外执行。若 watcher 和 `indexAll` 同时检查同一文件，两者都可能通过检查然后重复写入。不导致数据损坏（`INSERT OR REPLACE` 幂等），但产生冗余写入。

**R5-6** `project-move/orchestrator.ts:223,242` — **锁获取后 SIGINT 处理器安装前存在窗口，SIGINT 导致锁文件残留**

```typescript
await acquireLock(migrationId, lockPath);     // 行 223
// ... 窗口（约 19 行代码）...
process.on('SIGINT', sigintHandler);           // 行 242
```

此窗口内收到 SIGINT → 锁文件未清理 → 后续启动时需等待锁超时。

### TS Adapters（3 个）

**R5-7** `claude-code.ts:287-292` / `commandcode.ts:183-189` / `iflow.ts:163-168` — **`decodeCwd` 受损：路径中横线紧邻路径分隔符时丢失一层目录**

编码链（`/` → `-`，无转义）→ 解码链（`--` → `\x00`，`-` → `/`，`\x00` → `-`）在 `/-` 或 `-/` 出现时丢失一个 `/`。

```
/Users/bing/-Code-/engram → 编码 → -Users-bing--Code--engram
→ 解码 → /Users/bing-Code-engram  ❌（应为 /Users/bing/-Code-/engram）
```

影响所有含 `-` + `/` 相邻的 cwd 路径（如 `-Code-`、`-Projects-` 目录）。

**R5-8** `codex.ts:129` — **Codex 的 `startTime` 可为 undefined，无 mtime 回退**

```typescript
startTime: payload.timestamp as string,   // 无空值检查
```

`session_meta` 无 `timestamp` 字段时，`as string` 仅在 TypeScript 层面断言，运行时为 undefined。其他 adapter 有 `new Date(fileStat.mtimeMs).toISOString()` 回退。

**R5-9** `codex.ts:225-231` / `claude-code.ts:294-299` / `iflow.ts:170-176` / `qwen.ts:165-171` / `copilot.ts:170-176` — **5 个 adapter 的 `readLines` 缺少 `try/finally`，提前退出时泄漏文件描述符**

```typescript
private async *readLines(filePath: string): AsyncGenerator<string> {
    const stream = createReadStream(filePath, { encoding: 'utf8' });
    const rl = createInterface({ input: stream, crlfDelay: Infinity });
    for await (const line of rl) {
      if (line.trim()) yield line;
    }
    // 无 try/finally — 消费者提前 break 时 stream/rl 永不关闭
}
```

对比已正确实现的 adapter（commandcode.ts、qoder.ts、antigravity.ts、kimi.ts、windsurf.ts 均有 try/finally）。大量索引时可能触发 EMFILE。

### TS Tools（4 个）

**R5-10** `index.ts:316-331` — **`hide_session` 的模板字面量拼接 SQL（设计脆弱）**

```typescript
const hiddenExpr = hidden ? "datetime('now')" : 'NULL';
db.raw.prepare(`UPDATE sessions SET hidden_at = ${hiddenExpr} WHERE id = ?`).run(id);
```

当前 `hiddenExpr` 仅可选两个 SQL 安全的字面量，但这是脆弱的模式。应使用参数化或 `CASE WHEN`。

**R5-11** `generate_summary.ts:77-84` / `export.ts:40-47` / `web.ts:822-829` — **3 处全量消息加载无上限，可导致 DoS**

十万条消息 × 1KB = ~100MB 内存占用。MCP 服务器/daemon 进程可被大型会话的单个请求打崩。

**R5-12** `tools/project.ts:474-488` + `web.ts:782` — **YAML 解析无大小限制，可造成 YAML 炸弹攻击**

直接回退路径（daemon 不可达时）在 Node 内解析无保护的 `parseYaml(params.yaml)`。千兆字节或嵌套别名炸弹可导致进程崩溃。

**R5-13** `index.ts:685-741` — **MCP 服务器不响应 `progressToken` 和取消通知**

`CallToolRequestSchema` 忽略 `_meta.progressToken`。长运行的工具（search、generate_summary、export）不可被 MCP 客户端中途取消。

### Swift UI（2 个）

**R5-14** `ExpandableSessionCard.swift:52` — **子会话展开三角形非 Button，VoiceOver 不可见**

```swift
Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
    .onTapGesture { toggleExpand() }   // 非 Button，辅助技术不识别
```

**R5-15** `SessionDetailView.swift:247-261` — **隐藏快捷键按钮空标签污染无障碍树**

5 个 `Button("")` 仅为注册快捷键而生（Cmd+F、Cmd+G 等），标记 `frame(0,0).opacity(0)` 但仍在无障碍树中。

### Swift Core（3 个）

**R5-16** `MockEngramServiceClient.swift:3-34` — **`@unchecked Sendable` + 30+ 个可变 `var` 属性，零同步**

测试 mock 有 30+ 个 `var Result` 属性。TSAN 下并发读写是未定义行为。应改为 `let`（在 init 时设置）。

**R5-17** `SessionWatcher.swift:84-85,131-143,153` — **共享可变字典和计数器，多 async 方法并发访问无保护**

`observe()` 和 `drainReady()` 都读写 `pending` 字典和 `nextSequence`。无 actor/lock/queue 保护，并发时是竞态条件。

**R5-18** `SwiftIndexer.swift:12,52-55` — **GRDB `Database` 句柄跨越 async 挂起点存储**

`SwiftIndexer` 将 `Database?` 存储为属性。`indexAll()` 在 `for try await streamSnapshots()` 循环（含 async 挂起）中使用，之后再访问存储的 `db`——可能在错误的线程上使用 GRDB 句柄。

### Swift Service（6 个）

**R5-19** `EngramServiceRunner.swift:149-168` — **优雅关闭时不做最终 WAL checkpoint**

`defer` 取消 `checkpointTask` 但不触发 checkpoin。WAL 积累的帧留到下次启动的 TRUNCATE 处理。产生不必要的重启 I/O。

**R5-20** `ServiceWriterGate.swift:154-172` — **写信号量无限阻塞，一个挂起的写操作阻塞所有后续写入**

`wait()` 无 timeout。慢 SQLite 事务/NFS 卡住时，所有 queue 中的写入永久阻塞。唯一逃生路径是 Task 取消（但此时所有排队写入被丢弃）。

**R5-21** `TranscriptExportService.swift:308-343` / `MCPTranscriptReader.swift:38-73` — **转录读取器中的 DispatchSemaphore 阻塞 Swift 并发线程池**

两个模块均使用 `semaphore.wait()` 桥接 async→sync。多个并发导出/MCP 请求可耗尽协作线程池导致死锁。

**R5-22** `ServiceWriterGate.swift:27-51` — **写入锁失败时整个服务退出，无降级只读模式**

`flock()` 失败 → `exit(1)`。无法在另一个实例运行时提供只读服务。

**R5-23** `EngramWebUIServer.swift:19` — **Web UI 以读写模式打开数据库（应是只读）**

```swift
self.databaseQueue = try DatabaseQueue(path: databasePath)  // 默认读写
```

对比 `MCPDatabase` 正确使用 `configuration.readonly = true`。

**R5-24** `UnixSocketServiceServer.swift:50-73` — **`project_move` 取消时文件系统操作继续运行**

Task 取消传播到 `performWriteCommand` 信号量，但 `rename(2)`/文件 patching 不观察取消。操作半途终止时文件系统状态不确定。

---

## P2 — 代码质量 / 可维护性

### TS Core（4 个）

| # | 文件:行 | 描述 |
|---|---------|------|
| R5-25 | `vector-store.ts:414-441` | `upsertInsight` 两次写入（metadata + vec）无事务包装 |
| R5-26 | `daemon-startup.ts:214-229` | 孤儿扫描无关闭取消机制——daemon 关闭时可能与 `db.close()` 竞态 |
| R5-27 | `maintenance.ts:99-141` | `backfillScores` 在事务外 SELECT、事务内 UPDATE——分数基于可能过期的值 |
| R5-28 | `metrics.ts:83-108` | `MetricsCollector.flush` 失败时永久丢失已 splice 的指标数据，无重试/死信队列 |

### TS Adapters（9 个）

| # | 文件:行 | 描述 |
|---|---------|------|
| R5-29 | `codex.ts:103-108` | 工具调用双重计数（call + output 都 +1），其他 adapter 均计为 1 |
| R5-30 | `kimi.ts:235,308` | `new Date(num * 1000).toISOString()` 在 Infinity/极端值上崩溃 |
| R5-31 | `gemini-cli.ts:145` | originator 大小写不匹配 Codex 惯例（`'claude-code'` vs `"Claude Code"`）→ parent-link 静默失效 |
| R5-32 | `cline.ts:142` | cwd regex 在路径含 `)` 时截断 |
| R5-33 | `opencode.ts:76-83` | `::` 分隔符在 dbPath 本身含 `::` 时误解析 |
| R5-34 | `windsurf.ts:158` | Windsurf 会话 cwd 始终为空——无法通过项目过滤搜索 |
| R5-35 | `kimi.ts:80` | sessionId 从 `basename(dirname(...))` 直接派生，无清理验证 |
| R5-36 | `_truncate.ts:28-32` | 仅处理 high-surrogate 截断，不处理 low-surrogate 截断 |
| R5-37 | `vscode.ts:220` | 整文件读取只为取第一行（同 antigravity/windsurf 问题，已修复部分） |

### TS Tools（4 个）

| # | 文件:行 | 描述 |
|---|---------|------|
| R5-38 | `save_insight.ts:89-102` | deleteInsight 在 vecStore 存在时无条件返回 true |
| R5-39 | `save_insight.ts:124,273` | `source_session_id` 不经格式或存在性验证即存储 |
| R5-40 | `web.ts:1566-1606` | `/api/log` 的 `data` 字段无大小限制 |
| R5-41 | `project.ts:86-88` | `project_move` 的 `note` 参数无长度限制 |

### Swift UI（8 个）

| # | 文件:行 | 描述 |
|---|---------|------|
| R5-42 | `CommandPaletteView.swift:182-209` | 搜索 Task 未取消——dissmiss 后仍修改 state，多次调用竞态 |
| R5-43 | `GlobalSearchOverlay.swift:99-128` | 同上模式 |
| R5-44 | `SessionDetailView.swift:385-423` | `loadParentInfo()` 3 个入口各自 spawn Task.detached，并发回写竞态 |
| R5-45 | `SessionDetailView.swift:262-265` | 双重 `.task` 修饰符生命周期依赖不明确 |
| R5-46 | `SourcePulseView.swift:90-92` | Timer 闭包内的内部 Task 未跟踪取消 |
| R5-47 | `SkeletonRow.swift:22` | 每行 `repeatForever` 动画触发不必要的 display link |
| R5-48 | 多个文件 | "Copied" 反馈的 Task 在视图消失后继续运行 |
| R5-49 | `ContentSegmentViews.swift:12,62` | 静态 NSCache 无 `totalCostLimit` |

### Swift Core（6 个）

| # | 文件:行 | 描述 |
|---|---------|------|
| R5-50 | `StreamingLineReader.swift:7,42-72` | `failures` 数组在 AnyIterator 闭包内修改，潜在的跨线程访问 |
| R5-51 | 15+ 个 adapter 类 | 所有 immutable adapter 类未声明 `Sendable` |
| R5-52 | `EngramDatabaseReader.swift` / `EngramDatabaseWriter.swift` | 两个 GRDB 封装类未显式声明 `Sendable` |
| R5-53 | `EngramServiceClient.swift:5` | `@unchecked Sendable` 不必要——全部 `let` 属性，移除可让编译器验证 |
| R5-54 | `OpenCodeAdapter.swift:4-59` | Phase4SQLiteDatabase 包装 raw sqlite3* 指针，多任务重用会触发 SQLITE_MISUSE |
| R5-55 | `EngramDatabaseIndexer.swift:16-31` | IndexingWriteSink 协议和实现未声明 Sendable |

### Swift Service（6 个）

| # | 文件:行 | 描述 |
|---|---------|------|
| R5-56 | `EngramServiceReadProvider.swift:311-359` | `mode` 参数静默忽略——semantic 模式从未布线 |
| R5-57 | `EngramServiceLauncher.swift:136-143` | `stopProcessOnly` 不 `waitUntilExit()`——旧进程可能在新进程启动后仍在运行 |
| R5-58 | `EngramServiceLauncher.swift:88-127` | 健康监控 `[weak self]` + `guard let self else return`——释放时静默退出 |
| R5-59 | `EngramServiceLauncher.swift:80-127` | 3 次固定间隔重试后永久停止——无指数回退 |
| R5-60 | `EngramWebUIServer.swift:9,19` | DatabaseQueue 未被显式释放——ARC 时机不可预测 |
| R5-61 | `EngramServiceCommandHandler.swift:305-314` | FTS 语法错误被标记 `retryPolicy: "safe"`（应为 `"never"`） |

---

## 关键交叉发现（与先前轮次关联）

| R3 问题 | R5 新视角发现 |
|---------|-------------|
| SetMetrics Proxy（R3 P0-4 误报，验证通过） | R5 独立确认 Proxy 安全：只拦截 run/get/all，所有其他属性正确转发 |
| 跨 adapter 不一致（R3 P1-19, R4 N3） | R5 发现 codex 工具调用双重计数、gemini-cli originator 大小写等新的不一致维度 |
| 文件描述符泄漏（R3 P1-31 已修复） | R5 发现 5 个 adapter 仍缺失 try/finally，与已修复的 StreamingLineReader 形成对比 |
| WAL 检查点安全（R3 关注） | R5 发现优雅关闭不做最终 checkpoint + Web UI 以读写模式打开 DB |

---

## 本轮的误报声明

经详细验证，`setMetrics` Proxy 包装器（数据库代理）**无问题**：
- `originalPrepare` 在替换之前绑定，内部使用保持原始值
- Proxy 仅拦截 `run`/`get`/`all` 用于计时
- 所有其他属性和方法（`pluck()`、`raw()`、`columns()` 等）通过 `val.bind(target)` 正确转发
- `setMetrics` 在 daemon 启动期间调用一次，在任何并发操作开始之前
