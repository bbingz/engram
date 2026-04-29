# Engram Node→Swift 单栈迁移 Review 反馈

**Review 日期:** 2026-04-24
**Commit:** `6a47273 feat: migrate mac app to swift service stack`(单 commit,33,325 行新增)
**范围:** 新增 7 个 Swift 模块 / 12 个 Swift 适配器 / EngramService Unix socket IPC / 全套 parity fixtures;Node daemon + MCP 下线
**Review 方法:** 6 路并行子 agent(架构 / 数据层 / IPC / 适配器 parity / MCP 契约 / 测试基建)独立调查,文件/行号为证据

---

## 一、整体判定

**质量画像**:契约层和 schema 层迁移做得扎实(工具 1:1、tier/parent detection 语义对齐、fail-closed 一贯),但**运行时生命周期、数据库并发治理、以及测试真实度**存在多个会在"上线几周后爆"的坑。

**不建议这个分支直接合 main 并推用户更新**。建议分 2 批处理:先修 Critical 类,再合;Medium 类进 follow-up。

---

## 二、Critical — 会直接导致数据损坏 / 用户不可用

### C1. `memory_insights` 表 Swift 迁移中缺失

- **证据:** `macos/EngramCoreWrite/Database/EngramMigrations.swift` 无该表;Node 侧 `src/core/vector-store.ts:188` 负责创建。`StartupBackfills.swift:336-361` reconcileInsights 会查这张表,虽然 try-catch 吞错,但 `has_embedding` 位无法重置,孤儿向量漂浮
- **影响:** 纯 Swift 首次启动(或 sqlite-vec 加载失败)时,insight 双写层的一致性修复路径全部 no-op,text-only → embedded 的升级无法发生
- **建议:** Swift 迁移补 `CREATE TABLE memory_insights IF NOT EXISTS (...)`,列定义要与 Node vector-store 完全一致,包括 `deleted_at` 软删列

### C2. 无 PASSIVE WAL checkpoint

- **证据:** `macos/Shared/EngramCore/Database/SQLiteConnectionPolicy.swift:10-44` 只设 `busy_timeout=30s` 和 WAL 模式,没有周期性 checkpoint。Node 侧 `src/core/db/maintenance.ts` 定义了 `checkpointWal('PASSIVE'|...)` 并在 daemon 定期调用,Swift 无对等物
- **影响:** CLAUDE.md `feedback_sqlite_busy_timeout` 明确要求。长时间运行写入 WAL 可堆积到 1GB+,SQLITE_BUSY 概率显著上升
- **建议:** `EngramService` 后台每 15-30s 调 `PRAGMA wal_checkpoint(PASSIVE)`;`SQLiteConnectionPolicy` 补上 `wal_autocheckpoint` / `synchronous` pragma

### C3. 双栈并发无进程锁

- **证据:** `macos/EngramService/Core/ServiceWriterGate.swift:76-86` 的 flock 只防 Service 多开。GRDB 默认 IMMEDIATE 事务、better-sqlite3 默认 DEFERRED,切换/并存期脏读概率上升
- **影响:** 用户 Node daemon 还在跑 + Swift App 首次启动,WAL 冲突 + 事务隔离不一致 → 数据看起来"消失"或 FTS 索引错位
- **建议:** 引入**全库顶层 flock**(`~/.engram/.lock`),任何时刻只允许一个写者栈运行;在 App 启动时显式检测并拒绝

### C4. `projectMove` / `Archive` / `Undo` / `Batch` 在 CommandHandler 抛错

- **证据:** `macos/EngramService/Core/EngramServiceCommandHandler.swift:814-836` 这些命令 case 全部 `throw UnsupportedNativeCommand`。但 MCP 工具(MCPToolRegistry)还挂着它们,`tests/fixtures/mcp-golden/project_move_batch.dry_run.json` 等 golden 仍存在
- **影响:** UI 按钮或 MCP 调用触发后,Service 抛错、客户端不一定优雅降级。用户点"归档"会看到 crash/神秘错误
- **建议:** 两选一 —— (a) 补齐 Swift 实现(推荐,因为这是日常功能);(b) MCP 工具显式下线 + UI 按钮隐藏 + golden 移除。**不能留"按了就炸"的路径**

### C5. Service 死了没人拉

- **证据:** `macos/Engram/Core/EngramServiceLauncher.swift:47-61` 用 Foundation Process 起子进程,`EngramServiceRunner.swift:48-54` 睡眠循环无 structured logging。无 health check、无 exponential backoff、无 launchd plist
- **影响:** Service 崩 1 次后,所有写工具(save_insight / project_* / generate_summary / export / handoff)全部永久 fail-closed,直到用户重启 App。用户不会知道该重启
- **建议:** Launcher 加 health probe(每 5s `status()` 调用);连续失败 N 次后重启,重启 ≥3 次后标记 degraded 并 UI 提示用户

### C6. FTSRebuildPolicy 用 DELETE 而非 DROP

- **证据:** `macos/EngramCoreWrite/Database/FTSRebuildPolicy.swift:14-20` `DELETE FROM sessions_fts`,而 `VectorRebuildPolicy.swift:5-63` 用 DROP。Node 侧 `vector-store.ts:160-205` 统一 DROP
- **影响:** FTS5 虚表的内部 shadow 表(`sessions_fts_content`、`sessions_fts_idx` 等)不清理,版本升级后索引状态残留。重建中途宕机则 session 搜不到
- **建议:** 改 `DROP TABLE IF EXISTS sessions_fts; CREATE VIRTUAL TABLE ...`,整个重建过程用事务包裹

---

## 三、High — 安全 / parity 语义偏差 / Stage Gate 虚假通过

### H1. Stage 5 gate 实际未通过

- **证据:** `docs/swift-single-stack/stage-gates.md:50-55` 声称"clean checkout 可不需 npm 构建";实际 `package.json` 完整保留,`src/` 全部在树,Xcode 构建链未解耦(`macos/scripts/build-node-bundle.sh` 虽删但 package.json scripts 齐全)。`docs/verification/swift-single-stack-stage4.md:55` 自己承认 Stage 5 compat debt
- **建议:** 文档**如实修正为"Stage 5 未完成"**;或在本次合并前把 Node 拔干净

### H2. TOCTOU + 路径信任

- **证据:**
  - `macos/Shared/Service/UnixSocketEngramServiceTransport.swift:60-84` — 创建 rundir 到 bind 之间有窗口可被替换为 symlink 指向 `/root` 等
  - `macos/EngramService/Core/TranscriptExportService.swift:38-46` — `outputHome` 只检查 `hasPrefix("/")`,允许 `/../../etc/passwd` 或 symlink 穿越
- **建议:**
  - Socket 创建前 `lstat` 目录,拒绝 symlink;bind 前 revalidate
  - TranscriptExport 把白名单收窄到 `$HOME/engram-exports/` 或 App sandbox container,拒绝 `..` 和 symlink

### H3. Gemini originator 大小写不一致

- **证据:**
  - `macos/Shared/EngramCore/Adapters/Sources/CodexAdapter.swift:213` 比对 `"Claude Code"`
  - `macos/Shared/EngramCore/Adapters/Sources/GeminiCliAdapter.swift:146` 比对 `"claude-code"`
  - Node 侧统一用 `"Claude Code"`(见 CLAUDE.md Layer 1b)
- **影响:** 所有 Claude Code 派发的 Gemini 子会话无法被识别为 `dispatched`,不会下调到 `skip` tier,污染 HomeView 时间线
- **建议:** 归一化成 case-insensitive 比对,两个 adapter 抽个 helper

### H4. 大文件 OOM 风险

- **证据:** `macos/Shared/EngramCore/Adapters/StreamingLineReader.swift` 本身是流式的,但 `macos/Shared/EngramCore/Adapters/AdapterRegistry.swift:92-96` / `macos/EngramCoreWrite/Indexing/SwiftIndexer.swift` 把 stream 全部 collect 进数组
- **影响:** Node `src/core/indexer.ts` 的 async generator 是真流式,Swift 这个实现对 150MB+ 的 Cursor/Codex 文件会把 Service RSS 打爆
- **建议:** 让 indexer 消费 AsyncSequence / Swift AsyncStream,不要 collect;或引入分批上限(如每 N 条 flush 一次)

### H5. `minimax` 和 `lobsterai` 有枚举无适配器

- **证据:** `macos/Shared/EngramCore/Adapters/SessionAdapter.swift:3-18` SourceName 含这两项;`Sources/*.swift` 无对应文件。仅靠 `ClaudeCodeAdapter.swift:161-172` 的 model string 推断
- **影响:** 若上游工具直接产出 `source="minimax"` 的 session,`SwiftIndexer.swift:44` 适配器查找失败,session 静默跳过
- **建议:** 要么删枚举值,要么补 adapter;不要留悬空枚举

### H6. Parity 测试只比行数/checksum,不比字段值

- **证据:**
  - `macos/EngramCoreTests/IndexerParityTests.swift:38-60` 只对比 table row count + checksum
  - `macos/EngramTests/AdapterParityTests.swift:95-174` 虽然有 Equatable 对比,但 failure message 只输出 source name,看不出哪个字段差
  - CLAUDE.md `feedback_stub_class_bugs` 教训"shape-only 测试会漏 hardcoded-0 stub"
- **影响:** 适配器在 Swift 侧丢了 `model` 字段、时间戳格式错了、截断策略跟 Node 不一致 —— 测试全绿,线上慢慢分叉
- **建议:**
  - IndexerParityTests 逐列对比关键字段(model / summary / token counts / parent_session_id)
  - AdapterParityTests failure message 输出具体字段 diff
  - 增加一批 malformed/edge-case fixture(truncated JSON、invalid UTF-8、超大 message)—— `tests/fixtures/adapter-malformed/manifest.json` 只有 51 行 manifest 没有真实 input

### H7. Schema compat check 不在 CI 门禁

- **证据:** `scripts/db/check-swift-schema-compat.ts:50-70` 需要手跑 `xcodebuild + npx tsx`;`.github/workflows/test.yml` swift-unit job 未接入
- **影响:** 改 Node schema 忘改 Swift → CI 绿,用户升级后 DB 迁移失败或字段丢失
- **建议:** 加一个 CI stage,构建 `EngramCoreSchemaTool` 后跑 compat check 作为硬门禁

---

## 四、Medium — 设计债 / DX / 可观测性

| # | 风险 | 证据 |
|---|------|------|
| **M1** | `macos/Shared/Service/` 既被 App 也被 CLI 直接 import(`project.yml:202-203`),IPC 协议类型可绕过 socket 被当内部 API 用 | — |
| **M2** 5 条 Node CLI 命令(logs / traces / health / diagnose / resume)被 `docs/swift-single-stack/cli-replacement-table.md:19-22` 标记"无替代",但 `package.json` 未下线 | — |
| **M3** | `ParentDetection.detectionVersion` Swift 侧写死常量,Node 升级版本后不重编译 Swift 则不会 reset stale detections | `macos/Shared/EngramCore/Indexing/ParentDetection.swift:14` |
| **M4** | `UnixSocketEngramServiceTransport.events()` 实现为空 `AsyncStream.finish()`,UI 计数只能轮询 `status()`,断线无推送 | `macos/Shared/Service/UnixSocketEngramServiceTransport.swift:36-40` |
| **M5** | `ParserLimits` 接受未知 JSON 字段但静默丢弃。`tests/fixtures/adapter-parity/kimi/input/schema_drift.jsonl` 通过不代表真的测了前向兼容 | — |
| **M6** | 非监视源 rescan 间隔 10 分钟 | `macos/EngramCoreWrite/Indexing/NonWatchableSourceRescanner.swift:34` |
| **M7** | `scripts/measure-swift-single-stack-baseline.sh` 只有 16 行空壳,对标 `scripts/perf/capture-node-baseline.ts`(533 行)。**Swift 侧没有可比性能数据**,ship 后劣化无法量化 | — |
| **M8** | Boundary 脚本全是正则 grep,易被 `typealias` / 反射 / 注释绕过;`check-stage3-daemon-cutover.sh:190` 的 allowlist 会漂移 | — |
| **M9** | 恶意 fixture `tests/fixtures/adapter-malformed/` 只有 manifest,没有真实 input,malformed parity 等于没测 | — |

---

## 五、做得好的地方(值得延续)

1. **MCP 工具层完全对等** — 27 个 handler + 34 个 golden + `ServiceUnavailableMutatingToolTests` 验证 fail-closed,对外部 Claude Code 用户透明
2. **Read/Write 模块分层** — `scripts/check-swift-module-boundaries.sh` 脚本强制,不是口头纪律
3. **Session tier + parent detection 语义逐字段对齐** — `SessionTier.swift` vs `src/core/session-tier.ts`、dispatch pattern 完全一致
4. **CJK LIKE fallback 保留** — `macos/EngramMCP/Core/MCPDatabase.swift:206-208`
5. **Startup backfill 顺序完整 port 5 步** — downgradeSubagentTiers → backfillParentLinks → resetStaleDetections → backfillCodexOriginator → backfillSuggestedParents
6. **Schema 基础字段 1:1 对齐** — 三级索引、trigram FTS、parent_cascade 触发器全部对上
7. **Fail-closed 一贯** — 写工具在 Service 不可用时不创建 DB、不写文件,不是半成品状态

---

## 六、方向性讨论(需要回复)

1. **为什么单 commit 33k 行?** 既然有清晰的 Stage 0-5 分层设计,单 commit 合入放弃了 bisect 能力。建议 merge 时至少按 Stage 切成 6 个 commit(commit message 里贴上各 Stage 的验证脚本结果)
2. **Node 代码什么时候真删?** 目前 `src/` 全保留、`package.json` 没瘦身。建议设定一个删除日期(如 2026-06-01),写进 `CHANGELOG.md`,否则 Node 会以"做 parity baseline"的名义永久存在并慢慢 rot
3. **老用户升级路径**。已有 `~/.engram/index.sqlite`(Node WAL)的用户第一次启动新 Swift 版本:C1/C6 会触发 FTS/vector 重建窗口,期间搜不到东西。需要**首次启动 one-shot rebuild 的 UI 提示**
4. **是否要 staged rollout?** 建议先让 TestFlight / 内部用户跑 2 周,通过 `EngramServiceStatusStore` 采集 Service crash 次数和 restart 频次,确认 C5 不是大问题
5. **Review 流程**。后续大型迁移建议用 **Stage-PR** 模式:每 Stage 一个 PR,独立 reviewer 各审一次,最后整合 PR,而不是一把梭

---

## 七、最小修复清单(合并前必须)

按优先级,总工作量估计 **2-3 天**:

- [ ] **C1** Swift 迁移补 `memory_insights` 表(30min)
- [ ] **C2** Service 侧周期 PASSIVE checkpoint(2h)
- [ ] **C3** 全库顶层 flock(2h)
- [ ] **C4** projectMove/Archive/Undo/Batch 补实现 或 UI+MCP 下线(2-6h)
- [ ] **C5** Service 健康检查 + 有限重启(4h)
- [ ] **C6** FTSRebuildPolicy 改 DROP+重建(1h)
- [ ] **H2** outputHome 白名单 + lstat + symlink 拒绝(2h)
- [ ] **H3** Gemini originator case-insensitive(10min + 补测试 20min)
- [ ] **H7** schema-compat 加 CI gate(1h)
- [ ] **文档** Stage 5 gate 真实状态如实修正(`docs/swift-single-stack/stage-gates.md` + `docs/verification/swift-single-stack-stage5.md`)(30min)

**H4 / H5 / H6 / 所有 Medium** 类可进 follow-up PR,但 H6(parity 字段级断言)建议也在本轮做掉,因为它是信心基础。

---

## 八、证据文件索引

所有关键断言都有 `file:line` 证据。review 涉及的主要文件:

**架构/文档**
- `docs/swift-single-stack/stage-gates.md`
- `docs/swift-single-stack/cli-replacement-table.md`
- `docs/verification/swift-single-stack-stage4.md` / `stage5.md`
- `macos/project.yml`

**数据库层**
- `macos/EngramCoreWrite/Database/EngramMigrations.swift` / `FTSRebuildPolicy.swift` / `VectorRebuildPolicy.swift`
- `macos/Shared/EngramCore/Database/SQLiteConnectionPolicy.swift`
- `macos/EngramCoreWrite/Indexing/StartupBackfills.swift`
- `src/core/db/migration.ts` / `src/core/vector-store.ts`(Node 对照)

**IPC / 服务**
- `macos/EngramService/Core/EngramServiceCommandHandler.swift` / `ServiceWriterGate.swift` / `EngramServiceRunner.swift` / `TranscriptExportService.swift`
- `macos/Shared/Service/UnixSocketEngramServiceTransport.swift` / `EngramServiceClient.swift`
- `macos/Engram/Core/EngramServiceLauncher.swift`

**适配器**
- `macos/Shared/EngramCore/Adapters/SessionAdapter.swift` / `AdapterRegistry.swift` / `StreamingLineReader.swift` / `ParserLimits.swift`
- `macos/Shared/EngramCore/Adapters/Sources/*.swift`(12 个)
- `macos/EngramTests/AdapterParityTests.swift`

**MCP**
- `macos/EngramMCP/Core/MCPToolRegistry.swift` / `MCPDatabase.swift`
- `macos/EngramMCPTests/ServiceUnavailableMutatingToolTests.swift`
- `tests/fixtures/mcp-golden/*`

**测试基建**
- `macos/EngramCoreTests/IndexerParityTests.swift` / `StartupBackfillTests.swift`
- `scripts/check-*.sh` / `scripts/gen-*-parity-fixtures.ts`
- `scripts/db/check-swift-schema-compat.ts`
- `scripts/perf/capture-node-baseline.ts` / `scripts/measure-swift-single-stack-baseline.sh`

---

**最后一句话:** Codex 把"形"搬得很到位(模块、接口、契约、语义对齐),但"神"(并发治理、生命周期 supervision、测试断言强度)需要再过一轮人工。修完 C1-C6 + H1-H3 + H7,这次迁移就可以放心合 main。
