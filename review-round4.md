# Engram Round 4 Code Review — 修复验证 + 新发现

> 审查日期：2026-05-21
> 基于：Round 3 确认的 118 个问题
> 审查方式：6 个子 agent 并行逐文件验证 + 全新扫描

---

## 一、总体概览

| 区域 | R3 问题数 | 已修复 | 未修复 | 部分修复 | 修复率 | 新发现 |
|------|----------|--------|--------|----------|--------|--------|
| TS Core | 23 | 15 | 7 | 1 | **65%** | 10 |
| TS Adapters | 25 | 10 | 14 | 1 | **40%** | 11 |
| TS Tools/MCP | (截断) | — | — | — | — | — |
| Swift UI | 16 | 5 | 11 | 0 | **31%** | 12 |
| Swift Core/Shared | 22 | 5 | 15 | 1 | **23%** | 6 |
| Swift Service/MCP | 14 | 3 | 7 | 2 | **21%** | 6 |
| **合计** | **~100** | **~38** | **~54** | **~5** | **~38%** | **45** |

---

## 二、P0 修复状态（最高优先级）

| R3 编号 | 区域 | 描述 | 状态 |
|---------|------|------|------|
| P0-1 | TS Core | FTS 版本重置缺少事务保护 | **已修复** — `BEGIN IMMEDIATE` + `COMMIT`/`ROLLBACK` |
| P0-2 | TS Core | 同步来的 `tier: null` 被强制设为 `'normal'` | **已修复** — 改为 `tier: snapshot.tier ?? null` |
| P0-3 | TS Core | `indexFile` 缺少 `isIndexed` 去重 | **已修复** — 新增快速去重检查 |
| P0-4 | TS Core | `backfillCosts` 无速率限制 | **已修复** — 50ms 延迟移到 `finally` 块 |
| P0-5 | TS Core | `hidden_at` 变更不同步 | **已修复** — 新增启动时 reconcilation UPDATE |
| P0-6 | TS Adapters | opencode `sizeBytes` 整库大小 | **已修复** — 改为按消息 payload 累加 |
| P0-7 | TS Adapters | cursor `sizeBytes` 整库大小 | **已修复** — 同上 |
| P0-8 | TS Adapters | antigravity 整文件读入内存 | **已修复** — 改用流式读第一行 |
| P0-9 | TS Adapters | codex `extractText` 只返回第一块 | **已修复** — 遍历全部，跳过非文本块 |
| P0-10 | TS Adapters | codex 系统注入检测缺 5 模式 | **已修复** — 补齐 10 个模式 |
| P0-11 | TS Adapters | windsurf 整文件读入内存 | **已修复** — 同 antigravity |
| P0-12 | Swift UI | `listGitRepos()` 强制解包 `pool!` | **已修复** — 改为 `readInBackground` |
| P0-13 | Swift UI | `countSessionsSince/kpiStats` 强制解包 | **已修复** — 改为 `guard let ... else` |
| P0-14 | Swift Core | AdapterRegistry 重复键崩溃 | **已修复** — 改为手动循环 + 首次优先 |
| P0-15 | Swift SVMCP | Semaphore 阻塞 MCP 进程 | **已修复** — 改为 `async` stdin 循环 |
| P0-16 | Swift SVMCP | `handoff` 永远返回空结果 | **已修复** — 实现完整 `buildBrief()` |

**P0 修复率: 16/16 = 100%**

---

## 三、未修复的 P1 问题（重要）

### TS Core（3 个）

| 编号 | 文件:行 | 描述 | 现状 |
|------|---------|------|------|
| P1-5 | `session-repo.ts:208` | COALESCE 阻止本地覆盖远程 authority | 仍未修改，未加文档说明 |
| P1-6 | `indexer.ts:128` | Cache token 数据不进入同步管道 | SessionInfo/Snapshot 类型仍未包含这些字段 |
| P1-7 | `title-generator.ts:121` | 原始用户消息发给 LLM，无 PII 脱敏 | 仍未调用 `sanitizer.ts` |

### TS Adapters（7 个）

| 编号 | 文件 | 描述 |
|------|------|------|
| P1-11 | qwen/qoder/iflow | startTime 为空时缺少文件 mtime 回退 |
| P1-12 | qoder.ts | sessionId 在类型过滤内部捕获，丢失 metadata-only 记录 |
| P1-15 | usage-probes | `execSync('which ...')` 仍无 timeout |
| P1-16 | cascade-client.ts | 步骤类型匹配仍区分大小写 |
| P1-17 | windsurf.ts | `sync()` 每次 `listSessionFiles` 都调用 |
| P1-18 | cline.ts | `extractCwd` 正则匹配硬编码英文字符串 |
| P1-19 | 多个适配器 | 跨适配器消息类型处理无统一契约 |

### Swift（9 个）

| 编号 | 文件 | 描述 |
|------|------|------|
| P1-25 | MessageParser.swift | DispatchSemaphore 阻塞 + Box 数据竞争 |
| P1-26 | MessageParser.swift | `parse()` 同步方法，MainActor 调用会冻结 UI |
| P1-27 | Theme.swift | ModernScrollViewConfigurator 双重触发 async+asyncAfter |
| P1-28 | MessageTypeClassifier.swift | 仅扫描前 500 字符 |
| P1-29 | SessionListView.swift | Tab 分隔符编码 @AppStorage Set |
| P1-34 | EngramServiceLauncher.swift | `stopProcessOnly` 不调用 `waitUntilExit()` |
| P1-36 | EngramServiceCommandHandler.swift | linkSessions 未检查符号链接遍历 |
| P1-31 | StreamingLineReader.swift | **已在 Shared 层修复**；副本待确认 |

---

## 四、新发现（Round 4 全新问题）

### TS Core（10 个）

| # | 文件:行 | 严重度 | 描述 |
|---|---------|--------|------|
| N1 | `session-merge.ts:23-33` | **P1** | `coalesceSnapshot` 不合并 `tier` 和 `agentRole`——同步端可能覆盖本地计算的分层 |
| N2 | `index-job-runner.ts:62` | P2 | 含 hash 的重试任务会丢弃已有 FTS 全文内容，替换为仅摘要 |
| N3 | `chunker.ts:66` | P2 | `overlap >= windowSize` 时 `step <= 0`，进入死循环 |
| N4 | `config.ts:338` | P2 | `readFileSettings` 吞掉所有错误并返回 `{}`，无法区分"首次运行"和"配置文件损坏" |
| N5 | `auto-summary.ts:17` | P2 | daemon 关闭时未触发的 auto-summary timer 被静默丢弃 |
| N6 | `daemon-startup.ts:50` | P2 | `backfillSuggestedParents` 的 dispatched 计数不返回不发出 |
| N7 | `embeddings.ts:133` | P2 | Ollama 向量维度不足时未校验即插入 sqlite-vec |
| N8 | `parent-detection.ts:69` | P3 | 短指令(<10字符)被拒绝，可能遗漏合法 dispatch |
| N9 | `sync.ts:130` | P2 | 对端传来的 tier 被 `computeTier` 无条件覆盖 |
| N10 | `watcher.ts:143` | P3 | unlink 错误 handler 吞噬所有异常包括编程 bug |

### TS Adapters（11 个）

| # | 文件:行 | 严重度 | 描述 |
|---|---------|--------|------|
| N1 | antigravity/qoder/commandcode | **P1** | 3 个适配器中仍有原始 `JSON.stringify().slice()`（产生 `'null'` 字符串/截断 UTF-8） |
| N2 | commandcode.ts | **P1** | **完全没有 `isSystemInjection` 方法**，系统消息均计为用户消息 |
| N3 | 多个适配器 | P2 | 系统注入检测覆盖率不一致：qwen 3 个模式，iflow 3 个，qoder 2 个，commandcode 0 个 |
| N4 | gemini-cli.ts:132 | P2 | `endTime` 不检查是否等于 `startTime` |
| N5 | gemini-cli.ts:188 | P2 | `projectsCache` 永不失效 |
| N6 | antigravity.ts:439 | **P1** | startTime 无 mtime 回退（同 P1-11 模式） |
| N7 | commandcode.ts:56 | **P1** | startTime 无 mtime 回退 |
| N8 | cascade-client.ts:121 | P2 | gRPC 仅支持不安全连接，远程部署无保护 |
| N9 | antigravity.ts:296,548 | P2 | 两处几乎相同的 CWD 推断代码应提取为共享方法 |
| N10 | codex.ts:168 | P2 | assistant 消息可能在 `extractText=''` 时产出空消息 |
| N11 | vscode.ts:220 | P2 | 整文件读入内存只为取第一行 |

### Swift UI（12 个）

| # | 文件:行 | 严重度 | 描述 |
|---|---------|--------|------|
| NEW-1 | `ToolCallParser.swift:24` | **P1** | `try? NSRegularExpression` — 正则编译失败静默返回 nil。所有工具调用解析失败，app 继续运行无报错 |
| NEW-2 | `MCPServer.swift:26` | **P1** | `try? removeItem` — socket 文件无法删除时 server 照常启动 |
| NEW-3 | `MCPServer.swift:32-42` | **P1** | `serverTask` 被 `Task.detached` 启动但从未被 `await`——server 错误静默丢弃，`isRunning` 仍为 `true` |
| NEW-4 | `MCPServer.swift:46` | P2 | `stop()` 在 server 实际终止前设 `isRunning=false`，存在竞态窗口 |
| NEW-5 | `RepoDetailView.swift:57` | **P1** | `NSAppleScript.executeAndReturnError(nil)` 同步阻塞主线程 |
| NEW-6 | `TerminalLauncher.swift:49` | P2 | 日志写入 /tmp 的竞争条件 + 同步 AppleScript |
| NEW-7 | `SourcePulseView.swift:116` | P2 | 空 catch 块静默吞掉所有 DB 错误 |
| NEW-8 | `ToolCallParser.swift:40` | P2 | 同 P1-28，前 500 字符截断 |
| NEW-9 | `SourcesSettingsSection.swift:97` | P2 | 原始 `UserDefaults.standard` 而非 `@AppStorage` |
| NEW-10 | `MCPServer.swift:46-50` | P3 | `stop()` 不 `await serverTask.value` |
| NEW-11 | `StreamingJSONLReader.swift:22` | P2 | 同 Shared 层的 FileHandle 泄漏模式 |
| NEW-12 | `PopoverView.swift:243` | P2 | 又一个重复 `ISO8601DateFormatter` 实例 |

### Swift Core/Shared（6 个）

| # | 文件:行 | 严重度 | 描述 |
|---|---------|--------|------|
| NEW-1 | `CursorAdapter.swift:87` | **P1** | **Swift 版同 TS P0-7 的 Bug** — `sizeBytes` 取整个 vscode.db 大小 |
| NEW-2 | `SwiftIndexer.swift:224` | P2 | `try! JSONSerialization` + `String(...)!` 双强制解包，无效 Unicode 时崩溃 |
| NEW-3 | `KimiAdapter.swift:155` | P2 | 每次 `parseSessionInfo` 重新读取 kimi.json（同 TS P2-12） |
| NEW-4 | `CursorAdapter.swift:22` | P2 | `listSessionLocators` 全量表物化，含完整 JSON blob |
| NEW-5 | `VectorRebuildPolicy.swift:22` | P2 | 向量表在重建时静默删除，零指标零事件 |
| NEW-6 | `SessionWatcher.swift:130` | P2 | pending 字典无上限容量保护，无过期驱逐 |

### Swift Service/MCP（6 个）

| # | 文件:行 | 严重度 | 描述 |
|---|---------|--------|------|
| NEW-1 | `EngramServiceReadProvider.swift:329` | **P1** | CJK 搜索回退 `LIKE '%\(query)%'` 未转义 `%` 和 `_`（**同 TS P1-1 的 Swift 复现**） |
| NEW-2 | MCPTranscriptReader + TranscriptExportService | **P1** | Semaphore 阻塞模式在转录读取器中残留（MCPStdioServer 已修，此处未修） |
| NEW-3 | `MCPTranscriptTools.swift:14` | P2 | `getSession` 全量加载所有消息到内存再分页（同 TS P1-21） |
| NEW-4 | `MCPConfig.swift:15` | P2 | `URL(string: envVar)!` — 环境变量无效 URL 时崩溃 |
| NEW-5 | `MCPConfig.swift:7,14` | P2 | `daemonBaseURL` / `bearerToken` 死字段——HTTP daemon 已移除 |
| NEW-6 | `EngramWebUIServer.swift:20` | P2 | 同 P0-14 的 `uniqueKeysWithValues` 崩溃风险 |

---

## 五、关键交叉问题（跨层复现）

| TS Round 3 问题 | Swift 对应复现 | 描述 |
|----------------|---------------|------|
| P0-7 cursor sizeBytes | Core/Shared NEW-1 | CursorAdapter 同样用整库大小 |
| P1-1 CJK LIKE 注入 | Service NEW-1 | EngramServiceReadProvider 同样未转义 |
| P1-21 get_session 全量加载 | Service NEW-3 | MCPTranscriptTools 同样全量加载 |
| P2-12 kimi.json 缓存 | Core/Shared NEW-3 | KimiAdapter 同样未缓存 |
| P2-10 cursor .all() | Core/Shared NEW-4 | CursorAdapter 同样全量表物化 |

---

## 六、统计

| 指标 | 数值 |
|------|------|
| R3 确认问题数 | ~118 |
| R4 已修复 | ~43（**38%**） |
| R4 未修复 | ~54 |
| R4 部分修复/设计如此 | ~5 |
| R4 新发现问题 | 45（P1: 11, P2: 30, P3: 4） |
| P0 修复率 | **100%**（16/16） |
| P1 修复率 | ~38% |
| P2 修复率 | ~19% |
| 本轮新 Bug 模式 | Swift 复现 TS bug（跨层复制）、静默错误丢弃、Semaphore 残留 |

---

> 验证方法：6 个 agent 独立逐行读取源代码与 R3 报告对比，交叉确认修复状态后汇总。
