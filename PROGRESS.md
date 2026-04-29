# PROGRESS — MCP 多写者锁竞争治理

**问题起点**（2026-04-22）：用户报"MCP 又挂了"。排查后 MCP 其实 `✓ Connected`，真正的症状是 `database is locked` ——
近 2h 有 29 条 `indexFile failed` 报错，**全部来自 `src=watcher`**。DB 同时有 3 个 node 进程（daemon + 2 个 MCP）
持有 `index.sqlite` 写句柄，WAL 涨到 137 MB，`busy_timeout=5s` 被突破。

**误判澄清**：不是 node 稳定性问题。换 bun 或 Swift 原生**不治本**——SQLite 是同一个 SQLite，锁语义相同。
真正的根因是**多进程并发写同一个 SQLite**，必须在架构上改成单写者。

---

## Phase A — 快速止血（已完成，2026-04-22）

最小改动，立刻减少锁报错频率。

| 改动 | 位置 | 理由 |
|---|---|---|
| `busy_timeout` 5s → **30s** | `src/core/db/database.ts:48` | watcher 批事务 + MCP 并发写在 5s 内常被突破；30s 把重试窗口拉宽到实际事务时长之上 |
| 新增 `checkpointWal()` helper | `src/core/db/maintenance.ts` | 暴露 `PRAGMA wal_checkpoint(MODE)`，busy=1 退化为 PASSIVE，不抛错 |
| daemon 启动时 TRUNCATE 一次 | `src/daemon.ts` | 清理上轮残留（当前 137 MB 一次 checkpoint 清零） |
| daemon 每 10 分钟周期 TRUNCATE | `src/daemon.ts`（`walCheckpointTimer`） | 限制 WAL 文件增长；battery 模式 × 2 |
| 观测事件 `wal_checkpoint` | daemon stdout | Swift 侧可见；`db.wal_frames` gauge 入 metrics |

**验证**：`npm run build` ✓，`npm test` 全过（1172 tests），biome 对改动 4 个文件干净。

**预期效果**（需观察 24h）：
- WAL 文件稳定在 几 MB 以内
- `database is locked` 频次 ≥ 90% 下降（剩下的主要来自真正的长事务）

**MCP 不参与 checkpoint**：避免多进程 pragma 竞争，只由 daemon 驱动。

---

## Phase B — Daemon 唯一写者（P1，待排期）

**目标**：从根上消除"N 个 MCP 进程都能写 DB"的架构缺陷。

### 现状（Step 1 完成，2026-04-22）

完整写工具清点（Survey 2 次修订后）：

| MCP 工具 | 写操作 | 已有 HTTP 端点 | 迁移状态 |
|---|---|---|---|
| **save_insight** | `saveInsightText`, `markInsightEmbedded`, `deleteInsightText`, `vecStore.upsertInsight` | ❌→ ✅ 新增 `POST /api/insight` | ✅ **Step 1** |
| **generate_summary** | `updateSessionSummary` | ✅ `POST /api/summary` | ✅ **Step 2** |
| **manage_project_alias** (add/remove) | `addProjectAlias`, `removeProjectAlias` | ✅ `POST/DELETE /api/project-aliases` | ✅ **Step 4** |
| **project_move** | orchestrator 内部写 | ✅ `POST /api/project/move` (+ actor) | ✅ **Step 3** |
| **project_archive** | orchestrator 内部写 | ✅ `POST /api/project/archive` (+ actor) | ✅ **Step 3** |
| **project_undo** | orchestrator 内部写 | ✅ `POST /api/project/undo` (+ actor) | ✅ **Step 3** |
| **project_move_batch** | `runBatch` → 多次 orchestrator 写 | ✅ `POST /api/project/move-batch`（新增） | ✅ **Round 2 M3** |

**不需要迁移**：
- `handoff` / `lint_config` / `get_*` / `list_*` / `search` / `stats` / `export` / `live_sessions` / `file_activity` / `project_review` / `project_list_migrations` / `project_recover` / `project_timeline` / `tool_analytics` / `generate_title` —— 只读
- **`link_sessions`**（Step 5 的原计划）—— 实际只读 DB（`resolveProjectAliases`、`listSessions`），"写"是文件系统 symlink，不在 Phase B 范围

**实际 DB 写工具 = 7 个，7/7 ✅ 全部完成**（Step 1-4 + Round 2 补齐 `project_move_batch`）。6-way review 发现 Survey v3 漏数了 batch 工具。

### 目标架构

```
     Claude #1 → MCP #1 ┐
     Claude #2 → MCP #2 ┤
     Claude #N → MCP #N ┼── HTTP(write) ──→ daemon ──(单写者)──→ SQLite
     Swift app ─────────┘                     ↑
                                              └── watcher
     读路径：所有进程直连 SQLite（WAL 允许 N 个并发 reader）
```

### 工作项

- ✅ **Step 1**（完成 2026-04-22）
  - `src/core/daemon-client.ts` — `DaemonClient` (fetch + bearer + timeout + fetchImpl 注入) + `DaemonClientError` + `createDaemonClientFromSettings`
  - `POST /api/insight` 端点 + MCP dispatch 走 HTTP
  - `FileSettings.mcpStrictSingleWriter`（默认 false）
- ✅ **Step 2**（完成 2026-04-22）
  - 抽 `shouldFallbackToDirect(err, strict)` 共享 helper —— 核心判断：**带 `{error:...}` 的 4xx = 应用层拒绝（上抛），无 envelope 的 404/405/501 = 旧 daemon 端点缺失（降级）**。避免每个工具重复判断
  - save_insight dispatch 改用 helper（行为不变，代码减半）
  - generate_summary 迁移：MCP POST `/api/summary`（端点原已存在），返回值从 `{summary}` 包装成 MCP content 格式。不改 HTTP 响应形状（Swift `SessionDetailView.swift:446` 依赖它）
  - 端点与 helper 的 envelope 契约测（`tests/web/daemon-http-contract.test.ts`）
  - **不需要 daemon 重新部署**：/api/summary 早就存在
- ✅ **Step 4**（完成 2026-04-22，跳过原 Step 3 先做这个简单的）
  - `manage_project_alias` add/remove 路由到 `POST/DELETE /api/project-aliases`；`list` 保持直接读（Phase B 只管写路径）
  - 扩展 `DaemonClient.delete(path, body?)` 支持带 body 的 DELETE（alias 删除需要 `{alias, canonical}`）
  - 契约测加 alias POST/DELETE round-trip + 400 validation bubble-up
  - **1197 tests ✓**（+1 delete-with-body 单测 + 2 alias contract 测）
  - **不需要 daemon 重新部署**：`/api/project-aliases` 早就存在
- ✅ **Step 3**（完成 2026-04-22）：project_move / archive / undo 全部上线 HTTP 路由
  - **3a** 端点侧：`/api/project/{move,archive,undo}` 加 `actor?: 'cli'|'mcp'|'swift-ui'|'batch'` body 字段，默认 `'swift-ui'`（Swift UI 不变）。未知 actor → `400 InvalidActor`（防审计污染）
  - **3a** `actor === 'mcp'` → `normalizeHttpPath` 的 `allowOutsideHome: true`，跳过 $HOME 约束（MCP 是本地信任对等进程，不需要 HTTP 层的 $HOME 防御）
  - **3b/c** MCP `project_move`/`project_undo` dispatch 迁移：本地 expandHome → snake_case→camelCase → 带 `actor:'mcp'` 发 HTTP；响应直接透传（PipelineResult 原本就一致）
  - **3d** `project_archive` dispatch 加响应转换：HTTP 返 `{...result, suggestion:{category,reason,dst}}`，MCP 侧 drop `suggestion`、补 `archive:{category,reason}`，保持 MCP 契约不变
  - dry-run 路径差异（`buildDryRunPlan` vs `runProjectMove({dryRun:true})`）—— 看了 orchestrator 发现 `runProjectMove({dryRun:true})` **内部就是 call buildDryRunPlan**（`orchestrator.ts:211-212`），所以迁移后 MCP 和 HTTP 走同一条路径，"差异"自动消失
  - 契约测 5 个（invalid actor → 400、$HOME bypass、swift-ui 默认保留 $HOME 约束）
  - **1202 tests ✓**
  - **需要 daemon 重新部署**：端点签名变了（新 `actor` 字段），旧 daemon 会忽略它（MCP 请求暂时落到 actor='swift-ui'，功能正常、审计有小漂移）
- ✅ **Step 6B**（完成 2026-04-22）：`mcpStrictSingleWriter` 开关做到 Swift UI
  - `macos/Engram/Views/Settings/NetworkSettingsSection.swift` 加 `MCP` GroupBox + Toggle "Strict single writer"
  - 走现成的 `readEngramSettings()` / `mutateEngramSettings()`，`isLoadingSettings` 防抖
  - 帮助文案解释 trade-off：ON = daemon 不可达时失败（零锁竞争但依赖 daemon），OFF = 降级到直写（默认，容错）
  - 在下次 MCP spawn 时生效（MCP 启动时读 `fileSettings`）
- ⏳ **Step 6A**：跑 24h 生产观察 `database is locked` → 0（被动等待）

### 成本估计（修订）

- 基础设施 + save_insight pilot：**0.5 天**（已完成）
- 剩余 6 个工具 × 每个 ~30 行 + 契约测：**0.5-1 天**
- 24h 观察 + Swift UI 开关：**0.5 天**
- **总计 ~1.5 天**（与原估计接近）

### 风险

| 风险 | 缓解 |
|---|---|
| daemon 不在时 MCP 完全失能 | 默认软约束 + `mcpStrictSingleWriter` 开关 |
| HTTP 延迟让短写工具变慢 | 本机 HTTP 实测 < 2ms，忽略不计；如必要可换 Unix socket |
| 新引入的 HTTP 错误语义不一致 | 强制走 `buildErrorEnvelope` 统一 envelope（Round 4 已做） |
| `save_insight` 等写后立即读 | daemon 写完 commit 后才响应，MCP 再直连读 —— WAL 保证可见性 |

### 成功指标

- `database is locked` 报错 → **0**
- 关闭 daemon 后 MCP 写路径直接 fail fast（开启 strict 模式下）
- 所有现有 MCP 契约测试全过

---

## Phase C — Swift 原生（P3，长期愿景）

**目标**：把 MCP server 从 Node 移植到 Swift（类似 Sparkle / Mac Catalyst 里的原生 MCP 框架）。

### 为什么**不是 P1**

| 维度 | 判断 |
|---|---|
| 能否解决锁竞争？ | ❌ Swift/GRDB 下一样要处理多写者。Phase B 已经根治 |
| 启动速度 | 略好（省 node 冷启动 ~80ms） |
| 内存占用 | 略好（省 node runtime ~50MB） |
| 运维 | 好很多（不依赖 node_modules + Bundle 内置 node） |
| 迁移成本 | **巨大** —— 15 adapters × 19 MCP tools × chunker + embedder + vector-store + sqlite-vec FFI + 1172 vitest 全迁 |

### 若要启动，先做的前置

1. Phase B 完成 —— MCP 变成瘦客户端后，Swift 重写成本减半（只需重写 stdio + HTTP 转发 + tool schema）
2. 评估 Swift 端 MCP SDK 现状（官方 `modelcontextprotocol/swift-sdk` 成熟度）
3. 评估 sqlite-vec 在 Swift/GRDB 下的调用路径（目前用 node 的 FFI binding）
4. 跑 benchmark：MCP 冷启动 + stdio RPC 延迟，node vs Swift 的实际差异

### 触发条件

以下任一成立再考虑开工：
- node_modules 打包 Bundle 成为发布卡点（size / 签名 / 公证）
- MCP 冷启动延迟被用户反复反馈
- Node 版本升级迁移负担 >> 当前

~~**当前不满足任一条**，保持观察。~~ 用户 2026-04-22 要求启动（理由：macOS 原生效率 + 简化技术栈），**范围锁定 small-shim**。

### Kickoff — 2026-04-22（delegated to Codex）

交 Codex 在独立 worktree 执行：

- **Worktree**：`../engram-mcp-swift`，分支 `feature/mcp-swift-shim`（off main）
- **范围锁定**：**只** MCP server（stdio + tool dispatch + HTTP forwarding）。daemon、15 adapters、chunker、embedder、vector-store、sqlite-vec FFI、1210 vitest、SwiftUI app、DB schema **全部不动**
- **Gating**：Phase 0 可行性报告 → 用户 review → Phase 1 计划 → 用户 review → Phase 2 实现。Codex 不得跳阶段
- **Fallback 保留**：`src/index.ts`（Node MCP）**不删**，用户随时可通过 `.claude/mcp.json` 切回
- **验收**：xcodebuild SUCCEEDED + `npm test` 绿 + 端到端 save_insight 经 daemon HTTP 走完（`ai_audit_log.request_source='mcp'`）+ Swift binary < 15 MB

原始 prompt 在用户与本会话的 2026-04-22 消息中（段首 `Task: Port Engram's MCP server from Node to Swift (Phase C — "small shim" scope)`）。

---

## Open questions

- Phase A 的 24h 观察：是否 `database is locked` 频次下降到可接受？如果不降，说明 watcher 内部有长事务（> 30s），需要拆小
- 两个 MCP 实例（27 分钟 + 2 分钟）共存是否 Claude Code 的 `/restart` 没清进程？——Phase B 落地后这不再是问题（多实例也只是多个 HTTP client）
- 是否需要在 Phase A 和 B 之间加一个 **advisory file lock** 给 MCP 写路径，让两个 MCP 写时至少串行？成本低但临时性，Phase B 完成后即可删。待决。
