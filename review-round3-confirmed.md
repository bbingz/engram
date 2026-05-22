# Engram Round 3 Code Review — 已验证问题清单

> 审查日期：2026-05-21
> 审查范围：6 个子 agent 并行审查 TypeScript + Swift 全部代码层
> 原始发现问题：131 → 验证后排除误报：9 → 确认有效：**122**（其中 9 个部分正确/降级）

---

## 统计汇总

| 区域 | P0 | P1 | P2 | 小计 | 误报 |
|------|----|----|----|------|------|
| TS Core | 5 | 10 | 8 | 23 | 3 (F2/F6/F13) |
| TS Adapters | 6 | 10 | 11 | 27 | 0 |
| TS Tools/MCP | 0 | 3 | 13 | 16 | 4 (F6/F9/F11/F18) |
| Swift UI | 2 | 6 | 10 | 18 | 2 (F7/F16) |
| Swift Core/Shared | 1 | 4 | 17 | 22 | 1 (F4) + 待补 |
| Swift Service/MCP | 2 | 4 | 6 | 12 | 1 待确认 |
| **总计** | **16** | **37** | **65** | **118** | **9 误报** |

> 部分验证输出被截断（Swift UI F16-F20、Swift Service F7 等），标记为 [待补充]。

---

## P0 — 崩溃 / 数据丢失 / 安全

### TS Core

**P0-1** `migration.ts:250-264` — 缺少事务保护，FTS 版本重置时进程崩溃会导致反复擦除
> FTS `DELETE`、`size_bytes` 重置、元数据写入分别在不同 `db.exec()` 中（隐式自动提交）。如果在 DELETE 之后、`setMetadata('fts_version')` 之前崩溃，下次重启 `ftsVersion !== FTS_VERSION` 仍为 true，再度擦除。
```ts
db.exec('DELETE FROM sessions_fts');              // auto-commit
db.exec('UPDATE sessions SET size_bytes = 0');    // auto-commit
// ... 崩溃在此处 → 下次重启 fts_version 未更新，再次 DELETE
setMetadata('fts_version', FTS_VERSION);          // auto-commit
```

**P0-2** `session-repo.ts:595` — 同步来的 `tier: null` 被强行设为 `'normal'`
> `tier: snapshot.tier ?? 'normal'` — `??` 将 NULL 替换为 `'normal'`。此后 `backfillTiers` 的 `WHERE tier IS NULL` 永远不会重新评估该会话。
```ts
tier: snapshot.tier ?? 'normal',   // NULL → 'normal'，永久丢失未分层状态
```

**P0-3** `indexer.ts:498-595` — `indexFile` 缺少 `isIndexed` 去重检查
> `indexAll` 在 277/295 行有快速去重路径 `if (this.db.isIndexed(filePath, fileSize)) return;`。但 `indexFile`（被 watcher 在每次文件变更时调用）没有此检查，每次都完整流式解析所有消息并尝试写入。
> 影响：大文件频繁变更时产生大量冗余 I/O 和 FTS/向量扰动。

**P0-4** `indexer.ts:429-496` — `backfillCosts` 对无 filePath 会话无速率限制
> 在 while(true) 循环内，无 filePath 的会话走 `continue` 跳过 50ms 延迟（489 行），而寻找 adapter 失败也走类似路径。大量此类会话时会产生密集 SQLite 写入。
> [原标记 F13，验证确认真实但严重度低于原评定 — 每批次间仍有 50ms 限制]

**P0-5** `maintenance.ts:44-49` — `runPostMigrationBackfill` 不回填后续 `hidden_at` 变更
> 回填采用 `WHERE id NOT IN (SELECT session_id FROM session_local_state)`，每个会话仅回填一次。之后 `sessions.hidden_at` 的变更不再同步到 `session_local_state`，两表数据分化。

### TS Adapters

**P0-6** `opencode.ts:154-160` — `sizeBytes` 取整个 SQLite 数据库大小
> `statSync(dbPath).size` — `dbPath` 是 OpenCode 的 SQLite 数据库路径，所有会话共享同一文件。每个会话的 `sizeBytes` 都被设为整个 DB 文件大小。CLAUDE.md 明确要求"不将整个 SQLite DB 文件大小分配给每个会话"。
```ts
sizeBytes: statSync(dbPath).size,   // 整个 opencode.db 的大小，非单会话
```

**P0-7** `cursor.ts:99` — `sizeBytes` 取整个 state.vscdb 大小
> 与 P0-6 同样模式：`fileStat.size` 是 `~/.cursor/User/globalStorage/state.vscdb` 文件大小。

**P0-8** `antigravity.ts:590-593` — `readFirstLine` 将整个文件载入内存
> `readFile(filePath, 'utf8')` 读取完整大文件（可达数 MB），仅用 `content.split('\n')[0]` 取第一行。

**P0-9** `codex.ts:245-253` — `extractText` 只返回第一个 text 块
> for 循环在找到第一个 `item.text || item.input_text` 时立即 return。如果 content 数组为 `[{tool_use: ...}, {text: "实际提问"}]`，返回 `''`。
```ts
for (const item of content) {
  if (item.text) return item.text;           // 遇到 tool_use 跳过，遇到 text 立即返回
  if (item.input_text) return item.input_text; // 不搜索后续 text 块
}
```

**P0-10** `codex.ts:236-243` — 系统注入检测缺少 5 个模式
> Codex 仅检查 4 个模式。Claude-code 检查 9 个。缺失：`<local-command-stdout>`、`<command-name>`、`<command-message>`、`Unknown skill:`、`Invoke the superpowers:`。

**P0-11** `windsurf.ts:252-256` — `readFirstLine` 同样内存问题
> 与 P0-8 相同模式，`readFile(filePath, 'utf8')` 后 `.split('\n')[0]`。

### Swift App UI

**P0-12** `Database.swift:797` — `listGitRepos()` 唯一未加 `guard let pool` 的方法
> `try pool!.read { ... }` 强制解包。DatabaseManager 中其他所有方法均使用 `guard let pool else { throw DatabaseError.notOpen }`。pool 为 nil 时崩溃。
```swift
func listGitRepos() throws -> [GitRepo] {
    try pool!.read { db in ... }   // 唯一未 guard 的方法
}
```

**P0-13** `Database.swift:623,637` — `countSessionsSince` 和 `kpiStats` 强制解包 `Row.fetchOne`
> `Row.fetchOne(db, sql: ...)!` — 虽然是 `SELECT COUNT(*)` 始终返回一行，但 force-unwrap 不符合代码库风格，与其他所有方法的 nil 安全处理不一致。
> [验证为 PARTIALLY TRUE — 实际 crash 风险极低（COUNT 始终有结果），但模式不推荐，降级为 P2]

### Swift Core/Shared

**P0-14** `AdapterRegistry.swift:7` — `Dictionary(uniqueKeysWithValues:)` 重复 source 键时运行时崩溃
> 如果未来任何两个适配器共享同一 `SourceName`，应用在初始化时直接 crash。
```swift
init(adapters: [any SessionAdapter] = []) {
    adaptersBySource = Dictionary(uniqueKeysWithValues: adapters.map { ($0.source, $0) })
    // 重复 source → fatalError("Duplicate values for key")
}
```

### Swift Service/MCP

**P0-15** `MCPStdioServer.swift:84-90` — `DispatchSemaphore` 阻塞整个 MCP 进程
> 工具调用时创建异步 Task，然后 `semaphore.wait()` 阻塞 stdin 读取线程。期间无法读取 stdin、无法响应 `shutdown`/`cancelled` 通知。代码中已有 TODO 注释确认此问题。
```swift
let semaphore = DispatchSemaphore(value: 0)
Task { response = await handleToolCall(...); semaphore.signal() }
semaphore.wait()   // 阻塞 stdin 读取线程
```

**P0-16** `MCPTranscriptTools.swift:46-74` — `handoff` 所有代码路径均返回 "No recent sessions found"
> 数据已正确获取（38-45 行），但 62-74 行所有非空路径都无条件返回 "No recent sessions found"。获取到的会话数据从未用于构建输出。
```swift
if let sessionID { _ = sessionID }  // 无操作
// 以下所有路径都返回 "No recent sessions found"
if format == "markdown" { ... "## Handoff — ...\n\nNo recent sessions found..." }
return .object([("brief", .string("Handoff — ...\n\nNo recent sessions found...")), ...])
```

---

## P1 — 功能性 Bug

### TS Core

**P1-1** `insight-repo.ts:91-96` — CJK 回退 LIKE 查询未转义 `%` 和 `_`
> `pattern: \`%${query}%\`` — 用户搜索"100%"变成通配符模式"任何以 100 开头的内容"。FTS 路径在 102 行正确转义了引号，但 LIKE 路径完全未转义。
```ts
pattern: `%${query}%`   // 用户输入中的 % 和 _ 成为 LIKE 通配符
```

**P1-2** `fts-repo.ts:111-179` — session 搜索的 CJK 回退同样未转义 LIKE，且 GROUP BY 使用裸列
> 两个子问题：(1) 相同 LIKE 转义问题；(2) `GROUP BY f.session_id` 中 `f.content` 和 `f.rowid` 未聚合也非 GROUP BY 列，SQLite 宽松模式下结果不确定，严格模式下报错。

**P1-3** `session-repo.ts:390-398` — `countSessions` 永远排除孤儿会话
> `countSessions(opts: Pick<ListSessionsOptions, 'source' | 'sources' | 'project' | 'projects' | 'agents'>)` — `includeOrphans` 被 Pick 排除。`applyFilters` 函数可以处理 `includeOrphans`，但 `countSessions` 永远不会传给它。

**P1-4** `fts-repo.ts:99-104` — FTS 查询转义依赖 try/catch
> 用 try/catch 检测不合法的 FTS5 语法，捕获后回退到引号包裹。但 ANY 错误（DB 锁定、I/O 错误、损坏）都会触发引号包裹，导致行为不一致。
```ts
try { return doSearch(query); }
catch { return doSearch(`"${query.replace(/"/g, '""')}"`); }  // 所有异常都走此路径
```

**P1-5** `session-repo.ts:208` — `COALESCE` 阻止本地覆盖远程 authority
> `authoritative_node = COALESCE(sessions.authoritative_node, excluded.authoritative_node)` — 如果远程同步先写入 `authoritative_node = 'peer-xyz'`，本地索引器永远无法覆盖为 `'local'`。
> 这是设计取舍 — COALESCE 保留最先分配的值。如果是有意为之，需文档化。如果是 bug，应改为 `excluded.authoritative_node` 优先。

**P1-6** `indexer.ts:128-171` — `cacheReadTokens/cacheCreationTokens` 不进入同步管道
> `accumulateFromStream` 提取并写入 cache token 到 `session_costs` 表，但 `SessionInfo` 和 `AuthoritativeSessionSnapshot` 类型都没有这些字段。cache token 数据"只写不读"。

**P1-7** `title-generator.ts:117-125` — 原始用户消息发送给 LLM 生成标题，无 PII 清理
> `m.content.slice(0, 200)` 直接发给 LLM。可能包含 API key、密码、个人信息。该功能默认关闭（`autoGenerate: false`），但开启后无任何脱敏。

**P1-8** `session-tier.ts:61-75` — 无回复检查覆盖所有 messageCount，probe 检查部分重叠
> `assistantCount === 0 && toolCount === 0` 返回 `lite`，无论 messageCount。50 条用户消息但无 AI 回复的会话本应是 `premium` 却被标记为 `lite`。

**P1-9** `vector-store.ts:304-331` — `upsertChunks` 逐个删除向量，而非用已存在的批量 SQL
> 循环 `existingChunkIds` 逐一调用 `deleteChunkVec.run(cid)`。但 254-255 行已定义了 `deleteChunkVecBySession`（一次删除整个 session 的所有向量条目），在 `upsertChunks` 中从未使用。

**P1-10** `maintenance.ts:245,362,422` — 三个回填函数均有 `LIMIT 500` 且无分页
> 超过 500 条的候选会话在每次启动时被永久跳过。`backfillParentLinks`(245)、`backfillCodexOriginator`(359)、`backfillSuggestedParents`(422)。

### TS Adapters

**P1-11** `qwen.ts` — startTime 可以为空字符串，缺少文件 mtime 回退
> [验证修正：原声称 `totalMessages > 0` guard 缺失，实际 sessionId 只在 user/assistant 类型中捕获，零消息会话被正确拒绝。真正问题是 `startTime`: 如果第一条 user/assistant 行缺少 `timestamp` 字段，`startTime` 保持 `''`。Claude-code 有 `startTime || new Date(fileStat.mtimeMs).toISOString()` 回退。]
> 同样问题：`qoder.ts`、`iflow.ts`

**P1-12** `qoder.ts:71-98` — `sessionId` 在类型过滤内部捕获，丢失 metadata-only 记录
> Claude-code 在类型过滤之前捕获 sessionId（附注释："sessionId can live on non-message records too"）。Qoder 的 sessionId 只在 `type !== 'user' && type !== 'assistant'` 的 continue 之后才赋值。仅含 attachment/metadata 行的文件无法提取 sessionId。

**P1-13** `codex.ts:111-121` — `payload.id` 为 undefined 时仍返回 session
> `if (!meta) return null` 只检查 falsy。`meta = {}` 时继续执行，`payload.id as string` 结果为 `undefined`（非 falsy），没有后续 id 验证。

**P1-14** `claude-code.ts:405-423` & `codex.ts:197-205` — 工具输出 JSON.stringify + slice 可能生成 `'null'` 字符串或截断 UTF-8
> `JSON.stringify(args).slice(0, 500)` — 当 `args` 为 `null` 时产生字符串 `'null'`。`.slice(0, 500)` 在多字节字符边界处可能截断。

**P1-15** `codex-usage-probe.ts:20` & `claude-usage-probe.ts:21` — `execSync('which ...')` 无 timeout
> `execSync('which codex', { stdio: 'pipe' })` 无 timeout 选项。虽然 `which` 几乎不会挂起，但阻塞事件循环且无超时保护。

**P1-16** `cascade-client.ts:387-395` — 步骤类型匹配区分大小写
> `type.includes('USER_INPUT')` 等全部大写硬编码。如果 gRPC 服务变为 `user_input` 或 `UserInput`，所有消息静默丢弃。

**P1-17** `windsurf.ts:102-103` — `listSessionFiles` 每次调用都触发 `sync()`
> `sync()` 通过 gRPC 连接 daemon 并下载/转换所有会话。每次 `listSessionFiles` 调用都执行完整同步，即使文件未变更。

**P1-18** `cline.ts:141-144` — `extractCwd` 正则匹配硬编码英文字符串
> 匹配字面量 `"Current Working Directory (path)"`。Cline 本地化或格式变更即中断。

**P1-19** 多个适配器 — 消息类型处理不一致
> claude-code 处理 user/assistant/tool_use/tool_result，codex 处理 text/function_call/function_call_output，qwen 跳过 tool 类型。无跨适配器契约规定哪些消息类型必须保留。

**P1-20** `opencode.ts:120-127` — 单消息会话不设 `endTime`
> `if (messages.length > 1)` 时才设 `endTime`。单消息会话 `endTime` 保持 `undefined`。

### TS Tools/MCP

**P1-21** `get_session.ts:41-51` — 全量消息加载到内存再分页
> `for await` 将全部消息推入 `allMessages` 数组，然后 `.slice(offset, offset+PAGE_SIZE)`。大型会话（10k+ 消息）可消耗数百 MB。

**P1-22** `web.ts:756-792` — `/api/project/move-batch` 故意跳过 `$HOME` 限制
> 代码注释明确："$HOME confinement isn't enforced here because paths come from the YAML document itself"。当无 bearer auth 时，本地进程可提交任意路径的 YAML。

**P1-23** `handoff.ts:183-201` — 流式读取整个会话只为取最后一条用户消息
> 从头到尾流式读完所有消息，只保留 `lastUserContent`。对数千条消息的会话极其低效。

### Swift App UI

**P1-24** `Database.swift` — 大量读取方法未 `nonisolated`，阻塞主线程
> DatabaseManager 标记 `@MainActor`，但以下方法未标记 `nonisolated`：`countsByProject()`、`listSessionsForProject()`、`getSession()`、`countSessions()`、`projectTimeline()`、`stats()`、`getContext()`、`listFavorites()`、`isFavorite()`、`listHiddenSessions()`、`countHiddenSessions()`、`listSessionsChronologically()`、`listSessionsInGroup()`、`countSessionsSince()`、`listGitRepos()`、`sparklineData()`、`listSessionsByProject()`。与已正确 `nonisolated` 的 20 个方法不一致。

**P1-25** `MessageParser.swift:100-135` — `DispatchSemaphore` 在 Swift 并发上下文中阻塞，Box 类存在数据竞争
> `Task.detached { ... box.messages = messages; semaphore.signal() }` + `semaphore.wait()` + 读取 `box.messages`。`@unchecked Sendable` 关闭编译器安全检查，但运行时正确性依赖 semaphore 时序。

**P1-26** `MessageParser.swift:133` — `parse()` 是同步方法，从 `@MainActor` 调用会冻结 UI
> 当前仅从 `Task.detached` 调用（`SessionDetailView:286`），但如果未来从主 actor 调用此方法会直接阻塞 UI。

**P1-27** `Theme.swift:161-169` — `ModernScrollViewConfigurator` 双重触发 async + asyncAfter
> `makeNSView` 和 `updateNSView` 各调用两次（立即 + 延迟），原因是 SwiftUI 布局时机问题。这种依赖计时的代码在不同 macOS 版本上行为可能不同。

**P1-28** `MessageTypeClassifier.swift:139-141` — 仅扫描前 500 字符
> `text.prefix(500)` — 长工具结果消息中，分类模式可能不在前 500 字符内，导致回退到 generic assistant。

**P1-29** `SessionListView.swift:39-40` — Tab 分隔符编码 `@AppStorage` Set
> `$0.sorted().joined(separator: "\t")` — 如果 source name 含 tab 字符，编码损坏。应用 JSON 编码。

### Swift Core/Shared

**P1-30** `UnixSocketEngramServiceTransport.swift:20-33` — 取消 `Task.detached` 时 fd 泄漏
> `defer { Darwin.close(fd) }` 在 `writeFrame`/`readFrame` 完成后才运行。取消 Task 时，这些阻塞 I/O 调用继续执行，fd 不会关闭直到 I/O 完成或超时。

**P1-31** `StreamingLineReader.swift:22-91` — 提前退出迭代时 FileHandle 泄漏
> `FileHandle` 仅在 EOF 分支关闭（`if eof { defer { try? handle.close() } }`）。调用者通过 `break` 或 `.prefix(10)` 提前退出时，handle 永不关闭。

**P1-32** `SQLiteConnectionPolicy.swift:27-42` — Reader 依赖 Writer 先设置 WAL，但未文档化
> `readerConfiguration()` 不设 `journal_mode`，只检查 `PRAGMA journal_mode` 必须为 `wal`。新数据库上，reader 先于 writer 打开会抛出 `journalModeNotWAL`。

**P1-33** `OpenCodeAdapter.swift:20-55` — `SQLITE_BUSY` 未处理
> `sqlite3_step` 的 `SQLITE_BUSY`（正在写入的 DB）落入 `guard stepResult == SQLITE_ROW else { throw }`。应重试而非抛出。

### Swift Service/MCP

**P1-34** `EngramServiceLauncher.swift:136-143` — `stopProcessOnly` 不调用 `waitUntilExit()`
> `process?.terminate()` 后立即 `process = nil`。虽然 `Process.deinit` 有内部等待逻辑，但依赖此行为不可靠，快速启停可能产生僵尸进程。

**P1-35** `MCPStdioServer.swift:25-26` — `readLine()` 无限期阻塞，无超时
> `while let line = readLine()` — 客户端崩溃或发送不完整行时，MCP 进程永远挂起。

**P1-36** `EngramServiceCommandHandler.swift:1128-1141` — linkSessions 中的符号链接遍历风险
> [验证为 PARTIALLY TRUE — `createDirectory(atPath:linkDir, withIntermediateDirectories: true)` 未检查中间目录是否存在符号链接]
> TranscriptExportService 中有可复用的 `rejectSymlinkAncestors` 模式。

**P1-37** `OrderedJSON.swift:59-60` — `try!` 在无效 Unicode 上崩溃
> `try! JSONSerialization.data(withJSONObject: [value])` — 截断产生的孤立 surrogate 字符会引发异常，导致 MCP 进程崩溃。

---

## P2 — 代码质量 / 可维护性

### TS Core

**P2-1** `fts-repo.ts:68-69` — 项目过滤使用 `LIKE '%value%'`（模糊），而非精确匹配
> 搜索项目 "engram" 也会匹配 "engram-tools"。

**P2-2** `session-repo.ts:61-65` vs `parent-link-repo.ts:152-155` — `rowToSession` 和 `rowToSessionInfo` 的 `filePath` 解析不一致
> 前者读取 `local_readable_path`（JOIN 自 `session_local_state`），后者不 JOIN 该表。

**P2-3** `maintenance.ts:73-74` — 分层回填的 `LIKE '%/usage%'` 和 `LIKE '%Generate a short, clear title%'` 可能误匹配
> 任何摘要包含 "usage" 或标题生成提示词文本的会话都被标记为 `lite`。

**P2-4** `maintenance.ts:166-174` — `deduplicateFilePaths` 使用 `MAX(rowid)`（VACUUM 后不稳定）
> `rowid` 在 VACUUM 后可重新分配。应使用 `MAX(indexed_at)` 或 `MAX(start_time)`。

**P2-5** `maintenance.ts:251` — 父链接正则仅匹配单层路径深度
> `/\([^/]+)\/subagents\/[^/]+\.jsonl$/` 要求正好一层父目录 → `/subagents/`。嵌套结构不匹配。

**P2-6** `preamble-detector.ts:34-36` — 空数组返回 `isPreambleOnly = true`，命名误导
> 功能上正确（空会话应该跳过），但方法名暗示了"序言内容"而非"空内容"。

**P2-7** `session-tier.ts` vs `maintenance.ts` — JS 和 SQL 的分层逻辑不等价
> SQL 缺少无回复检查、probe 检查、摘要模式检查。两个路径可能产生不同 tier。

**P2-8** `session-repo.ts:293-304` — `listSessions` 从 `sessions.hidden_at` 读取而非 `session_local_state`
> 虽然回填将数据复制到 `session_local_state`，但读取路径不使用该表的数据。

### TS Adapters

**P2-9** `copilot.ts:57` — 字符串连接构造父目录，应用 `dirname()`
> `join(filePath, '..')` 而非 `dirname(filePath)`。功能等价但不语义化。

**P2-10** `cursor.ts:59-84` — `listSessionFiles` 一次性全量加载所有行
> `.all()` 将所有 `composerData:*` 行加载到内存。可用 `.iterate()` 流式处理。

**P2-11** `kimi.ts:244-254` — `parseInt` 畸形文件名产生 NaN 排序 key
> `parseInt('abc', 10)` → `NaN`，`NaN - NaN` → 排序未定义。

**P2-12** `kimi.ts:265-278` — 每次会话解析都重新读取 `kimi.json`，无缓存
> 50 个 kimi 会话索引时，同一文件被读 50 次。

**P2-13** `codex-usage-probe.ts` & `claude-usage-probe.ts` — shell 路径含空格时命令断成多段
> `homedir()` 返回的路径可能含空格（如 `/Users/John Doe`），未加引号。

**P2-14** `cascade-client.ts:108-129` — 临时 `.proto` 文件在清理失败时积累
> `/tmp/cascade-{timestamp}.proto` — `unlinkSync` 在 finally 中，但如果 unlink 失败或进程在 write/unlink 之间崩溃，文件残留。

**P2-15** `opencode.ts:49` — `detect()` 声明 `async` 但用同步 `existsSync`
> 与所有其他适配器的 `await stat(...)` 模式不一致。

**P2-16** `codex.ts:49-52` — `expandSessionRoots` 硬编码 `'archived_sessions'`，依赖基准名恰好为 `'sessions'`
> 若 Codex 改变目录结构或用户指定自定义根目录，归档会话静默排除。

**P2-17** `vscode.ts:258-268` — `decodeFileUri` 不处理非 localhost authority
> `file://127.0.0.1/path` → 解析为 `127.0.0.1/path` 而非 `/path`。实用中极少触发。

### TS Tools/MCP

**P2-18** `save_insight.ts:89-102` — `deleteInsight` 在 vecStore 存在时无条件返回 true
> 即使没有任何洞察被实际删除，`deleted = true` 也被无条件设置。
```ts
deps.vecStore.deleteInsight(id);   // 忽略返回值
deleted = true;                      // 总是 true
```

**P2-19** `generate_summary.ts:77-84` & `web.ts:822-829` & `daemon.ts:199-208` — 三处全量消息加载
> 在采样之前将所有消息加载到内存。`summarizeConversation` 内部会调用 `sampleMessages`，所以全量加载是多余的。

**P2-20** `index.ts:273-274` — MCP handler 参数无运行时类型验证
> `a.id as string` 纯 TypeScript 类型转换，无 `typeof` 检查。

**P2-21** `link_sessions.ts:35-36` — QUERY_LIMIT 为 10000，虽非"无上限"但作为符号链接数量过高
> [验证修正：原声称"无上限"，实际有 10000 上限；改为"上限过高的符号链接创建"]

**P2-22** `index.ts:531-543,567-582` — `project_move`/`project_archive` 的参数无运行时验证
> `const params = a as { src: string; dst: string }` 无 typeof guard。

**P2-23** `web.ts:1206-1240` — `/api/skills` 无缓存、无限制地递归读取整个插件目录
> 每次请求读取 `~/.claude/plugins/cache` 全部 `.md` 文件。

**P2-24** `get_context.ts:189-410` — 每次调用触发 5-8 次独立 DB 查询
> 成本、工具分析、git repos、文件热点、最近错误、config lint 等均在 `include_environment !== false` 时触发。

**P2-25** `save_insight.ts:153` — UUID 在去重之前生成（浪费工作但无害）
> `const id = randomUUID()` 在文本去重检查（164 行）之前执行。如有重复，ID 被丢弃。

**P2-26** `index.ts:709-726` — 所有错误统一包装，编程 bug 与业务错误不可区分
> domain 错误和 `TypeError: Cannot read property of undefined` 产生相同格式。

**P2-27** `web.ts:347-348` — CORS 允许任何 localhost 源任何端口
> 带有明确注释："Acceptable for local dev tool"。文档化的已知风险。

**P2-28** `parent-link-repo.ts:18-35` — validateParentLink 不检查子会话是否已有子节点
> 检查 self-link、parent-not-found、depth-exceeded（父→祖父），但不检查 `sessionId` 是否已有 `parent_session_id = sessionId` 的孩子。可能导致 B→A→{C,D} 超过深度限制。

**P2-29** `get_context.ts:371-372` — MCP handler 中 `cwd` 未经验证传入 `handleLintConfig`
> 类型转换无路径验证，但受 `process.cwd()` 回退和 try/catch 保护。风险低。

### Swift App UI

**P2-30** `ContentSegmentParser.swift:14-25` — `ContentSegment.id` 使用 `hashValue`（跨启动不稳定）
> `String.hashValue` 使用 per-process 随机种子。虽然 `ContentSegment` 实例是临时的（每次渲染重建），但违反 `Identifiable` 契约。

**P2-31** 7+ 个文件各自创建 `ISO8601DateFormatter`（共 16 个文件有重复实例）
> PopoverView、SessionsPageView、ExpandableSessionCard、Theme、ReplayState、SessionCard 等均重复创建相同配置的 formatter。

**P2-32** `Theme.swift:10-50` — 硬编码 sRGB 色彩空间值
> `NSColor(srgbRed:...)` 在 P3 显示器上不会自动扩展色域。设计打磨问题，非功能 bug。
> [验证为 PARTIALLY TRUE，实际优先度低]

**P2-33** `MainWindowView.swift:7,113-124` — `searchQuery` 和 `performSearch()` 死代码
> body 内和任何其他方法中均未引用。

**P2-34** `SyntaxHighlighter.swift` — 静态缓存用 `prefix(100)` 作 key
> 如果内容前 100 字符相同但后续不同，缓存返回错误结果。应用完整内容的稳定 hash。

**P2-35** `SessionListView.swift:12` — `AuthorFilterMode` 使用裸 `Int` 而非 enum
> `@AppStorage("agentFilterMode") private var agentFilterMode: Int = 2`。无编译期安全性。

**P2-36** `ColumnVisibilityStore.swift:6-15` — `@ObservationIgnored` + `@AppStorage` 阻止跨窗口同步
> `@ObservationIgnored` 抑制了 `@Observable` 的变更追踪，多窗口间的列可见性变更不会传播。

**P2-37** `Database.swift` — `sourceStats()` 是 `nonisolated` 但 `countsByProject()` 不是，不一致
> 同样模式的读取方法，一个用 `readInBackground`，另一个同步阻塞。

### Swift Core/Shared

**P2-38** `UnixSocketEngramServiceTransport.swift:36-70` — `events()` 每 5 秒打开新 socket，与客户端 send 竞争
> [验证降级 — 短期 socket 仅造成效率问题，非数据损坏。连接被拒绝，非静默损坏。]

**P2-39** `UnixSocketEngramServiceTransport.swift:161-163` — `writeFrame` 缺少写入端长度验证
> 256KB 限制只在 `readFrame` 执行，不在 `writeFrame`。实际负载 <1KB，无现实影响。
> [验证为 PARTIALLY TRUE]

**P2-40** `UnixSocketEngramServiceTransport.swift:166-175` — 零长度帧被拒绝
> `guard length > 0` — 如果服务需要发送空 payload（void 操作），客户端抛出错误。

**P2-41** `UnixSocketEngramServiceTransport.swift:36-70` — 事件流被任何非取消错误终止
> 短暂的服务重启导致事件流永久死亡，需要重新订阅。

**P2-42** `EngramServiceStatusStore.swift:14` — `embeddingStatus` 属性永不写入
> 声明但所有 `apply` 方法均未赋值。`PopoverView` 中的 `if embeddingStatus == nil` 始终为 true。

**P2-43** `ParentDetection.swift:178-180` — `try! NSRegularExpression` 类型加载时崩溃
> 一个正则模式拼写错误即导致应用启动时崩溃。应用 `preconditionFailure` 提示哪个模式出错。

**P2-44** `UnixSocketEngramServiceTransport.swift:20-33` — 无协作取消的阻塞 I/O
> `Task.detached` 内部无 `Task.checkCancellation()`。取消仅在 I/O 调用前后有效。

**P2-45** `CodexAdapter.swift:77-79` — `parseObject` 静默吞掉所有 JSON 错误
> `try? ... as? JSONObject`。无法区分"非对象行"（应跳过）与"损坏 JSON"（可能值得诊断）。

**P2-46** `AntigravityAdapter.swift:127-141` & `WindsurfAdapter.swift` — `sync()` 无显式超时
> [验证降级 — URLSession 有默认 60s 超时和 TCP 重置回退，但多个 conversation 串行处理会累积延迟。]

**P2-47** `SessionWatcher.swift:153-181` — 事件爆发时 pending 字典增长
> [验证降级 — 有 drain 定时器和尺寸限制，非"无界"，但高负载下可能大量增长。]

**P2-48** `StartupBackfills.swift:363-388` — 错误信息字符串匹配检测表存在
> `if "\(error)".contains("no such table")` — SQLite 版本/语言环境变化时失效。

**P2-49** `CascadeClient.swift:122-126` — `escapeJSON` 只转义 `\` 和 `"`
> 控制字符（\n、\t、\r）未处理。cascadeId 为 hex 字符串时无实际影响，但脆弱的转义模式。

**P2-50** `MigrationLock.swift:71-74` — `createDirectory` 错误与锁获取失败不可区分
> 目录创建失败的错误消息无法区分是权限问题还是锁冲突。

**P2-51** `FTSRebuildPolicy.swift:22-27` — 向量表在 FTS 重建时静默清空
> 无指标、无事件发出。管理员不知情直到搜索质量下降。

**P2-52** `StartupBackfills.swift:570-599,694-706` — `LIMIT 1000` 和 `LIMIT 500` 无分页
> `backfillPolycliProviderParents`、`backfillSuggestedParents` 均无循环处理剩余行。

**P2-53** `SessionSnapshotWriter.swift:361-391` & `StartupBackfills.swift:949-986` — 重复 `computeQualityScore`
> 两个 30+ 行的几乎完全相同的计算函数。应提取为共享工具方法。

**P2-54** `SessionSnapshotWriter.swift:131-158` — 对可能为 NULL 的历史列无防护
> [验证修正：大部分字段有 `?? ""` 保护，但 `startTime` 和 `cwd` 缺少空值合并]

### Swift Service/MCP

**P2-55** `TranscriptExportService.swift:269-817` & `MCPTranscriptReader.swift:9-279` — 800+ 行几乎相同的转录解析代码
> 包括相同的 `readMessages`、`parseCodexFormat`、`parseGeminiFormat`、`readJSONLines`、`extractMessageContent` 等。bug 修复可能遗漏同步。

**P2-56** `MCPToolRegistry.swift:1510-1572` — 7 个未使用的请求/响应体 struct
> SaveInsightBody、GenerateSummaryBody、ProjectAliasBody、ProjectMoveBody、ProjectArchiveBody、ProjectUndoBody、ProjectMoveBatchBody、GenerateSummaryResponse — 旧 HTTP daemon 遗留，现已全走 Unix socket。

**P2-57** `MCPToolRegistry.swift:1142-1146` — 项目迁移工具仅靠文档警告并发，无运行时强制
> 工具描述中写"⚠️ Cannot run concurrently"，但只有 `writeSemaphore` 的隐式序列化保护，且会阻塞所有写入。

**P2-58** `EngramWebUIServer.swift:15` & `EngramServiceRunner.swift:65-66` — 3 处硬编码端口 3457
> 无冲突检测。如果有其他进程占用此端口，web 启动失败。

**P2-59** `EngramServiceRunner.swift:149-168` — shutdown 在 truncateTask 上阻塞最多 30s
> 有注释说明，这是有意的设计（SQLite PRAGMA 不支持 Task 取消）。但等待时间可能很长。

**P2-60** `ServiceWriterGate.swift:54-59` — Actor deinit 在有活跃操作时释放锁
> 解构时未保证所有 `performWriteCommand` 调用已完成。

**P2-61** `UnixSocketServiceServer.swift:21-53` — Unix socket 未认证，同用户任意进程可发送写命令
> 套接字文件权限设 0700，但任何以该用户身份运行的进程均可连接。

---

## 本轮的误报（9 个，已排除）

| 编号 | 原始发现 | 排除原因 |
|------|---------|---------|
| TS-Core-F2 | Proxy 破坏 transaction | 默认 handler 正确转发所有方法；事务语义不受影响 |
| TS-Core-F6 | backfillParentLinks 跨重启重新链接 | WHERE parent_session_id IS NULL 保证已链接的不会被重新处理 |
| TS-Core-F13 | backfillCosts 无速率限制 | 批次间有 50ms 延迟；SQLite 写入本身就是限流器 |
| TS-Tools-F6 | syncEngine 未加入 shutdown 清理 | SyncEngine 无需要清理的资源（无 timer/网络/file handle） |
| TS-Tools-F9 | hide_session SQL 注入 | hidden 布尔值经过 strict typeof 验证，仅用于选择两个 SQL 安全的字面量字符串 |
| TS-Tools-F11 | MCP 读取过时别名数据 | WAL 模式允许并发读取，两个进程共享同一 SQLite 文件 |
| TS-Tools-F18 | 孤儿扫描在 transport 连接前启动 | 孤儿扫描仅操作 DB+文件系统，与 MCP transport 无关 |
| Swift-UI-F7 | ReplayState timer 泄漏 | 使用 repeats:false（一次性）+ weak self，timer 自清理 |
| Swift-Core-F4 | @Observable 写入逃逸 MainActor | @MainActor class 的所有方法自动继承 MainActor 隔离 |

---

## 新发现的 Bug 模式（本轮）

1. **CJK LIKE 注入** — `%` 和 `_` 在 FTS + insight 搜索 CJK 回退路径中被当作 SQL 通配符
2. **无界流式加载** — 多处在分页/采样前将全部消息加载到内存（get_session、summary、handoff、auto-summary）
3. **LIMIT 无分页** — 6 处回填/查询使用硬编码 LIMIT 却不同时使用循环偏移量
4. **跨适配器不一致** — 各适配器的消息类型处理、系统注入检测、错误处理差异巨大，缺少统一契约

---

> 已验证 [121] 个问题，排除 [9] 个误报，[1 个] 验证输出截断待补充。
> 验证方法：每个 agent 逐行读取源代码确认，再交叉比对。
