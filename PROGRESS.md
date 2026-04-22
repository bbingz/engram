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

### 现状

- `src/tools/*.ts` 里的写工具（`save_insight` / `generate_summary` / `handoff` / `link_sessions` / `manage_project_alias` / `project_move` / `project_undo` / `project_archive` / `confirm-suggestion`…）**全部 `deps.db.xxx` 直连 SQLite**。
- `src/web.ts` 里 daemon 已经暴露了**几乎对应的全部 HTTP 写端点**：`/api/handoff` / `/api/link-sessions` / `/api/project/move` / `/api/project-aliases` / `/api/session/:id/generate-title` …
- Swift `DaemonClient` 已在走这些端点。
- **只剩 MCP 没用它** —— 这是最后一公里。

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

1. **清点写工具** — grep `src/tools/` 里所有 `deps.db.(save|insert|update|delete|upsert|mark|set)` 调用，落表对应 `/api/...`。缺口端点在 `web.ts` 补齐。
2. **写一个 `DaemonHttpClient`**（`src/core/daemon-client.ts`）—— 封装 `fetch` + 超时 + Bearer 鉴权 + error envelope 解析。
3. **`bootstrap.ts` 注入策略切换**：
   - daemon 进程内：直接注入 `db`（无 HTTP）
   - MCP 进程：注入 `DaemonHttpClient`，写调用转发；读调用仍直连
4. **离线 fallback**：daemon HTTP 连不通时（端口没起、daemon 挂了），MCP 能退回直写，避免完全断链。配 settings 开关 `mcpStrictSingleWriter`，默认 `false`（软约束），开启后 daemon 不可达直接返回错误。
5. **契约测试**：每个 write tool 写对照测试——走 HTTP 和走直连的行为必须一致。
6. **迁移顺序**：`save_insight`（最高频）→ `generate_summary` → project_move 家族 → link_sessions 家族 → 其余。每个 tool 切完跑全量 vitest + manual smoke，再切下一个。

### 成本估计

- 写工具约 **10 个**，每个 ~20-40 行（切端点 + fallback + 测试）
- DaemonHttpClient + bootstrap 注入点 ~1 天
- 契约测试 ~1 天
- **总计 1.5-2 天**

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

**当前不满足任一条**，保持观察。

---

## Open questions

- Phase A 的 24h 观察：是否 `database is locked` 频次下降到可接受？如果不降，说明 watcher 内部有长事务（> 30s），需要拆小
- 两个 MCP 实例（27 分钟 + 2 分钟）共存是否 Claude Code 的 `/restart` 没清进程？——Phase B 落地后这不再是问题（多实例也只是多个 HTTP client）
- 是否需要在 Phase A 和 B 之间加一个 **advisory file lock** 给 MCP 写路径，让两个 MCP 写时至少串行？成本低但临时性，Phase B 完成后即可删。待决。
