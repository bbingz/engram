# Engram 多智能体全量代码审计 — 2026-07-18

**Original audit baseline:** `fix/audit-2026-07-18-r4plus` @ `2940e6c9`

**Blind-audit closeout:** 2026-07-19 on `docs/audit-2026-07-19-blind-closeout`, based on PR #203 tip `62247c9e`

**Product authority:** local-first macOS Swift (`macos/`); `src/` TypeScript is reference/fixture material, not the shipped runtime.

---

## Executive summary

Engram 在 **写路径完整性、Archive V2 CAS、Unix socket 跨用户隔离、单写者门控** 上仍是健康的 local-first 产品。2026-07-17 命名 High（H1/H2/SEC-H1/H2）与 #196 关闭；#197 补完 R4 明确 input-local insight 拒绝的隔离终端化、R5 reclaim 预算游标、R10 HEAD 行为证据与 R11 账本。

The original audit found **no Critical** issue. Its confirmed **High** findings concentrated on the three independent Read SQL stacks, reclamation cursor starvation, skip-tier semantic artifact cleanup, idle embedding starvation, writer-gate name drift, and the Advanced Session Filter dead controls. Confirmed **Medium** findings included offload durability, MCP result/visibility contracts, settings persistence and main-thread I/O, and the R4 dual-transaction residual.

The 2026-07-19 blind-audit closeout then completed **15/15 discovery scopes**, explicitly named all **17 Swift source adapters**, and adjudicated **23 canonical candidates**: **22 confirmed** and **1 refuted**. Two current IDs retain document-scoped legacy references, while one duplicate MCP submission maps to the existing MCP-001 row. The 22 confirmed findings comprise 2 High, 19 Medium, and 1 Low; MCP-001 was already in the original inventory, so the closeout adds 21 unique inventory rows. Twenty-one findings are implementation-ready; CURSOR-CWD-001 remains design/evidence pending.

**#197 outcome:** the R4 taxonomy follow-up received fresh Codex `PASS` before commit/push. PR #197 remains part of the open stacked PR chain and is not auto-merged; R4-dual-tx remains a separate follow-up.

| Inventory view | Critical | High | Medium | Low |
|----------------|----------|------|--------|-----|
| Original 2026-07-18 confirmed set | 0 | 8 | 7 | selective rows in §A.4 |
| Blind closeout confirmed set | 0 | 2 | 19 | 1 |
| Current unique machine-readable inventory | 0 | 10 | 25 | 2 |

The closeout's `_repro` names are proposed TDD entry points only. None of those 22 blind-audit repros had been created or executed at documentation closeout.

---

## Methodology

| 项 | 说明 |
|----|------|
| 领域专家 | architecture、service-write、security、db-read-parity、embeddings-search、Archive/project-move、mcp-contract、SwiftUI/UX、concurrency-memory、tests-ci 等并行读源 |
| PR 复审 | #181, #183–#186, #196, #197（#188–#195 折叠入 #196） |
| 验证 | 对抗性 majority vote（`real_votes` ≥ 2–3）；弱声明由 critic 标注 |
| 合成规则 | Critical/High/Medium **仅确认项**；Low 可标 `unverified/selective`；按根因去重；severity DESC，同组 effort ASC |
| 非目标 | 不发明 finding；不重扫全库；引用以验证过的 file:line 为准 |

**Coverage update:** the closeout removed the earlier statement that most of the 17 Swift adapters were unnamed or unaudited. All 17 sources were explicitly covered by the 15/15 discovery scopes, and adapter/indexing/MCP candidates were majority-adjudicated. Areas with few or no retained findings—backup/restore, capture→CAS→replicate, transcript export, MCP framing/stdio, project-move undo/batch cancellation, CLI resume, and observability retention—remain limitations rather than health proofs.

### 2026-07-19 blind-audit adjudication

| Result | Count / disposition |
|--------|---------------------|
| Discovery scopes | 15 / 15 completed |
| Swift sources explicitly named | 17 / 17 |
| Canonical candidates | 23 |
| Confirmed | 22 (2 High, 19 Medium, 1 Low) |
| Refuted | 1 (`AG-BYTES-001`, 1 confirmed / 2 refuted) |
| Legacy references / duplicate | KIMI-001 → `2026-06-10-multi-expert-audit.md#H08`; WRITER-LOCATOR-001 → `2026-07-17-engram-full-audit.md#L3`; duplicate MCP submission → `MCP-001` |
| MCP-001 | **CONFIRMED VIOLATION**: MCP 2025-11-25 requires an object-root `structuredContent`; no `outputSchema` does not exempt array roots |
| Implementation plan | 11 ownership batches, A1–D1: 21 findings TDD-ready; CURSOR-CWD-001 design/evidence pending |

Sources with retained findings: claude-code, codex, gemini-cli, opencode, qwen, kimi, commandcode, copilot, vscode, and cursor. Sources without a retained finding in this pass: qoder, minimax, iflow, cline, windsurf, lobsterai, and antigravity (whose sole candidate was majority-refuted). “No retained finding” means only that the submitted evidence did not meet the confirmation threshold; it is not a defect-free certification.

---

## Baseline comparison（vs 07-17 / 07-18）

| 主题 | 07-17 full audit | 07-18 full-project review | 本审计 HEAD |
|------|------------------|---------------------------|-------------|
| H1 Projects 计数 | High open | fixed (#196) | **closed** |
| H2 MCP CJK/short | High open | fixed | **closed** |
| SEC-H1 TLS/bare-label | High open | fixed | **closed**（R7 传输深度仍 open） |
| SEC-H2 secrets scrub | High open | fixed | **closed** |
| M3 session embed | Medium | fixed | **closed** |
| M3 insight | 不全/误标 | R4 open | **#197 关**：仅明确 input-local 拒绝终端化；provider/protocol/config 错误可恢复；dual-tx Medium |
| M4 reclaim count | fixed | fixed | **closed** |
| M4 budget cursor | 不全 | R5 open | **#197 关** |
| M14 HEAD | 代码对、测试弱 | R10 | **#197 行为测试** |
| R1 triple SQL | 结构 | **High #1** | **仍 High #1**（具体漂移已钉死） |
| R2 JsonlPatch stream | M12 | residual | **#196 关**（大文件 CI skip） |
| Disposition 证据 | 弱 | R11 | **#197 改善** |
| 本轮确认 High | — | — | UI-001 仍 open；SVC-001、EMB-001、EMB-STARVE、CONC-001 已在后续 TDD 关闭 |

**已修复不再重复开单：** H1, H2, SEC-H1/H2 主路径, M1 核心策略, M12/R2 中流, M18/M19/M24 主路径, R4 明确 input-local 拒绝隔离+permanent（HTTP/transport、malformed provider response、dimension/config mismatch 不消耗该预算）, R5 候选预算游标, R10 行为 HEAD, R11 证据列。

---

## What’s healthy

1. **Swift 产品权威** + 机械门禁（`check-swift-module-boundaries` / `check-app-mcp-cli-direct-writes` / invariant-gates）
2. **单写者** `ServiceWriterGate` + 进程 flock；App/MCP 突变走 service + capability token
3. **Archive V2** 双收据 reclaim、quarantine rename、远程 `RENAME_EXCL` 发布、M14 existence HEAD
4. **ProjectMove** LIFO 补偿、JsonlPatch 流式中流修复、symlink 拒绝
5. **Socket 信任边界** 0700 runtime / 0600 sock / peer euid / token 矩阵测试
6. **嵌入** session 隔离 + insight R4 显式 input-local 拒绝产品路径；provider/protocol/config 错误可恢复；circuit breaker；model/dim reconcile
7. **CI** 变更分类、Swift unit、MCP executable fixtures、remote-server、UI smoke、CodeQL、Dependency Review
8. **TS 边界** 明确为参考/夹具，不 bundled

**R4 runtime evidence（isolated temp DB，真实 EngramService + EngramMCP）：** 连续 3 次 HTTP 500 与连续 3 次 2D-vs-configured-3D mismatch 均未写 `insight_embedding_failures`；provider 恢复后同一完整 insight 重新发送、写入 embedding，并通过 hybrid `get_memory` 检索。明确 `param: "input"` 的 HTTP 400 连续 3 次后变为 `failed_permanent`，healthy 重启未重试其完整 content。

---

# A) Issues & Fixes

> 仅 **CONFIRMED**。严重度：产品正确性/完整性/一致性影响，非文案夸张。

## A.1 Critical

*无。*

## A.2 High

### ARCH-001 — 三套独立 Read SQL 栈（R1 结构残留）

| 字段 | 内容 |
|------|------|
| **Location** | `macos/Engram/Core/Database.swift` (~1725 LOC)；`macos/EngramMCP/Core/MCPDatabase.swift` (~2928)；`macos/EngramService/Core/EngramServiceReadProvider.swift` (~2184)；`macos/EngramCoreRead/Database/EngramDatabaseReader.swift`（约 18 行 pool 包装，无共享谓词） |
| **Impact** | 同一用户查询在 App online（service）、App offline fallback、MCP、service IPC 上可得到不同 session 集合/计数；历史 H1/H2 只修单面，漂移继续 |
| **Root cause** | 产品迁切保留三读所有者，CoreRead 未成为查询层 |
| **Fix** | 将 list/search/cost 谓词迁入 EngramCoreRead（或多方消费的 Shared query 模块）；一套 multi-term CTE + since/project/tier 策略；跨表面 id-set 相等 fixture |
| **Effort** | L |
| **Source** | architecture（3/3 real） |

### READ-001 — MCP 多词 keyword 为行级 MATCH，非 session-scoped AND

| 字段 | 内容 |
|------|------|
| **Location** | `MCPDatabase.swift` keywordSearch ~2121–2190 vs `Database.swift` keywordSearchSQL ~480–552 vs `EngramServiceReadProvider.swift` ~634–686 |
| **Impact** | 代理用 MCP `search` 时多词召回系统低于 App/Service（FTS 每消息一行，词跨行时 MCP 假阴性） |
| **Root cause** | R1；H2 只移植 CJK/short LIKE |
| **Fix** | 移植 CTE-per-term 或共享 builder |
| **Status** | **Post-audit follow-up fixed**：MCP keyword search 现在为每个 token 建立 FTS CTE，并按 `session_id` inner join；跨多条 FTS row 的同一 session 可命中，缺少任一 token 的 session 不命中。ARCH-001 共享查询层总项仍 open。 |
| **Evidence** | `testKeywordSearchMatchesTermsAcrossFTSRows_repro` 先 RED（0 results）后 GREEN；11 个 selected search regression 与完整 `EngramMCPTests` 160/160 通过；Debug `Engram` build 成功。 |
| **Effort** | M |
| **Source** | db-read-parity（3/3） |

### READ-002 — Search `since` 谓词分裂（end_time vs start_time）

| 字段 | 内容 |
|------|------|
| **Location** | App `Database.swift` ~464–466；Service ~1886–1888：`COALESCE(s.end_time,s.start_time)`；MCP semantic、FTS keyword、LIKE fallback 三条路径原仅使用 `s.start_time` |
| **Impact** | 长会话/活动在窗口内的 session 出现在 App/Service search，MCP keyword/semantic 消失 |
| **Root cause** | MCP 未对齐 appendSearchFilters |
| **Fix** | 共享 since 谓词；MCP keyword+semantic 用 COALESCE |
| **Status** | **Post-audit follow-up fixed**：MCP semantic candidate、FTS keyword 与 CJK/short-query LIKE 均使用 `COALESCE(s.end_time, s.start_time) >= ?`。ARCH-001 共享查询层总项仍 open。 |
| **Evidence** | keyword 与 semantic 两个 `since` `_repro` 均先 RED（活动窗口内长会话缺失）后 GREEN；11 个 selected search regression 与完整 `EngramMCPTests` 160/160 通过；Debug `Engram` build 成功。 |
| **Effort** | S |
| **Source** | db-read-parity（3/3） |

### SVC-001 — Reclaim 丢弃 product-missing binding 且不推进 cursor，可卡死周期

| 字段 | 内容 |
|------|------|
| **Location** | `ArchiveReclamationCoordinator.swift` evaluateCandidates compactMap + productState ~255–281, 352–367；executeCycle lastProcessedBinding/storeReclamationCursor ~179–212 |
| **Impact** | 产品 session 擦除/orphan 后，整页 1000 个 catalog binding 若皆 product-missing → 评估列表空 → 不存 cursor → 同页死循环，后续 dual-receipt eligible 永不执行；源文件与磁盘占用滞留 |
| **Root cause** | M4/R5 只跟踪返回的 decision；compactMap 静默丢弃对 cursor 不可见 |
| **Fix** | product-missing/不可解析活动视为 examined blocked 以推进 cursor；加 full-page missing repro |
| **Status** | **Post-audit follow-up fixed**：missing row 与 malformed activity 分别报告 `missing_product_session` / `invalid_product_activity`；disabled、invalid-window、unsupported-source 仍保持 policy precedence；完整 1,000-row missing page 可安全推进 cursor |
| **Evidence** | `testReclamationCursorAdvancesPastProductMissingPage_repro` + 两个 preview blocker-precedence `_repro`（均 RED 后 GREEN） |
| **Effort** | S |
| **Source** | service-write-path（3/3） |

### EMB-001 — skip 层 artifact 清理从不删除 `semantic_chunks`

| 字段 | 内容 |
|------|------|
| **Location** | `SessionSnapshotWriter.deleteIndexArtifacts` ~745–761；`StartupBackfills` skip/orphan 清理 ~689–693, 920–925, 1060–1127；`SessionVectorSearchAvailability.probe` ~181–196 |
| **Impact** | 降级为 skip 后 FTS/messages 删除但 chunk 向量永驻膨胀；仅剩 skip 向量时 tools/list 仍可宣称 semantic/hybrid 可用而扫描无候选（违反 CLAUDE.md skip 产物应移除） |
| **Root cause** | 清理路径停在 legacy `session_embeddings`，未跟进 product `semantic_chunks` |
| **Fix** | deleteIndexArtifacts + skip startup 清理 `DELETE FROM semantic_chunks`；probe 要求可搜索 tier；tier 降级 `_repro` |
| **Status** | **Post-audit follow-up fixed**：direct snapshot、startup per-session/batch classification 与 reconciliation 均清除 skip-tier `semantic_chunks`；nullable-tier subagent 会先降为 skip；probe 复用共享 semantic tier predicate，不再把 skip/lite-only corpus 宣告为可用 |
| **Evidence** | 5 个 selected `_repro` 初始产生 6 个行为失败；Codex 要求的 nullable-tier 扩展再捕获 2 个失败，修复后均全绿；`EngramCoreTests` 930 passed + 1 skipped（931 total），`EngramServiceCore` 571 passed + 1 skipped（572 total），`EngramMCPTests` 157/157；Debug `Engram` build 成功 |
| **Effort** | S |
| **Source** | embeddings-search（3/3） |

### EMB-STARVE — 周期嵌入在 merge-only `scan.indexed==0` 时饿死

| 字段 | 内容 |
|------|------|
| **Location** | `EngramServiceRunner` periodic gate ~814–825；`SwiftIndexer.writeBatchCountingSuccesses` ~71–92；`EngramDatabaseIndexer` indexed 管道；`IndexJobRunner` 排除 embedding |
| **Impact** | idle 且仅有 pending/failed_retryable embed（含 insight-only）时，自适应周期永不跑 backfill，直到某次 merge 或重启（重启也仅一批） |
| **Root cause** | Wave 7C idle-skip 与 merge-only 计数语义交互；`indexed` 不再表示「有索引相关工作」 |
| **Fix** | 解耦：periodic idle scan 通过共享 pending selectors 检查 session/insight backlog；仅在已有 merge 或 backlog 时运行现有 best-effort drains |
| **Status** | **Post-audit follow-up fixed**：`scan.indexed == 0` 时不再直接跳过；`pending` / `failed_retryable` session job 与 insight-only backlog 均可触发 drain，无 backlog 仍跳过 provider work |
| **Evidence** | 新增 2 个 `_repro`；原 gate contract 初始产生 1 个行为失败，修复后 selected 2/2；`EngramServiceCore` 573 passed + 1 skipped（574 total）；Debug `Engram` build 成功 |
| **Effort** | M |
| **Source** | PR #183 F1 historical residual；post-audit TDD closed in `2a919e79` |

### CONC-001 — Startup/长维护写命令名未进 `isLongRunningWriteCommand`

| 字段 | 内容 |
|------|------|
| **Location** | `ServiceWriterGate.swift` ~274–303；`EngramServiceRunner` `initialFtsDrain` / `initialInstructionBackfill` / `initialImplementationBeatBackfill` ~1078–1188 |
| **Impact** | 首启 FTS drain（batch 200）与 instruction/beat backfill 持锁期间，短写（saveInsight 等）走 60s 队列超时 → 假 writerBusy（M1 启动路径残留） |
| **Root cause** | 脆性名称白名单与真实 `performWriteCommand(name:)` 漂移；H02 测试只锁部分名 |
| **Fix** | 将三个真实 startup phase 名加入 long-running 分类，并补 exact-name classification + queue behavior 测试 |
| **Status** | **Post-audit follow-up fixed**：`initialInstructionBackfill`、`initialImplementationBeatBackfill`、`initialFtsDrain` 均使用 long-running queue policy；short follower 不再假超时 |
| **Evidence** | `testStartupMaintenanceNamesAreLongRunning_repro` 与 `testFollowerBehindInitialFtsDrainDoesNotTimeout_repro` 均先 RED 后 GREEN；完整 `ServiceWriterGateTests` 20/20、`EngramServiceCore` 571 passed + 1 skipped（572 total） |
| **Effort** | S |
| **Source** | concurrency-memory（3/3） |

### UI-001 — Advanced Session Filter 为死控件

| 字段 | 内容 |
|------|------|
| **Location** | `SettingsView.swift` ~232–263, 450–463；`SessionsPageView` AppStorage `sessions.showAll`；`HumanDrivenFilter`；产品路径无 `noiseFilter`/`hideUsageSessions`/`hideAutoSummary` 读者 |
| **Impact** | 用户切换 Session Filter / Noise Details 以为列表变化，实际只认 AppStorage human-driven + 硬编码 skip 过滤 — 核心可见性模型假控件 |
| **Root cause** | 设置键序列化遗留，浏览已迁 AppStorage + SessionVisibilityFilter |
| **Fix** | 接线到共享 list 谓词，或移除/改标指向 Sessions「显示全部」 |
| **Effort** | M |
| **Source** | SwiftUI/UX（3/3） |

## A.3 Medium

### SEC-001 — Offload 信任远程 HEAD 后 collapse 本地 FTS，未证明 blob 耐久

| 字段 | 内容 |
|------|------|
| **Location** | `OffloadRunner.swift` ~83–107；`RemoteSyncCoordinator.swift` ~223–245；`OffloadRepo.commitOffloaded` ~184–215；`EngramRemoteBackend.head` ~92–98；`IndexJobRunner` offloaded 拒绝全量 FTS 重建 ~153–172 |
| **Impact** | opt-in 远程 offload 下，假 HEAD 200 → shadow 行替换全文 FTS；rehydrate 才 hash 校验；恶意/MITM/`requireTLS=false` 或损坏副本可导致冷会话关键词永久残缺（源 transcript 通常仍在磁盘，但产品索引路径不自动回填） |
| **Root cause** | HEAD 被当 PUT 成功的耐久证明；注释要求 PUT 成功却允许 HEAD-true 跳过 |
| **Fix** | HEAD 仅软优化；始终 idempotent PUT 或 GET+hash 后再 `commitOffloaded` |
| **Effort** | M |
| **Source** | security（3/3）；severity 按完整性/opt-in 定为 Medium |

### READ-003 — Project 过滤 App/Service 精确、MCP 子串 LIKE

| 字段 | 内容 |
|------|------|
| **Location** | App ~459–462 `IN`；Service ~1882–1884 `=`；MCP list/search/semantic ~177–185, 1361–1369, 2152–2160 LIKE `%alias%`；MCP 内 timeline/file 精确 vs tool_analytics LIKE |
| **Impact** | MCP `project=app` 可吞 `my-app`；MCP 工具间也不一致 |
| **Root cause** | 无共享 project 谓词；历史 MCP 部分匹配合同 |
| **Fix** | 默认 exact + alias；子串需显式 flag/文档 |
| **Status** | **Post-audit follow-up fixed**: `list_sessions`, FTS keyword, short-query LIKE, and semantic candidate filtering now use exact `IN` predicates after alias expansion. Tool schemas and the complete MCP parameter reference document the exact-name-or-alias contract. ARCH-001 remains open. |
| **Evidence** | `testListSessionsProjectFilterIsExact_repro` and `testSearchProjectFilterIsExactAcrossModes_repro` captured 6 pre-fix assertion failures across all four paths, then passed; 16 adjacent regressions and the complete `EngramMCPTests` suite passed at 161/161; Debug `Engram` build succeeded. |
| **Effort** | M |
| **Source** | db-read-parity（3/3） |

### MCP-001 — `manage_project_alias` list 仍发 array-root structuredContent

| 字段 | 内容 |
|------|------|
| **Location** | `MCPDatabase.listProjectAliases` ~1545–1557；`MCPToolRegistry` list ~1141–1146；golden `manage_project_alias.list.json` |
| **Impact** | 2025-11-25 客户端期望 object structuredContent 时 list 失败；同工具 add/remove 为 object，根形状按 action 不一致 |
| **Root cause** | #186 只覆盖有 outputSchema 的工具 |
| **Fix** | `{ "aliases": [...] }` + schema + object-root 覆盖无 schema 工具 |
| **Effort** | S |
| **Source** | mcp-contract（3/3） |

### MCP-002 — get_context / tool_analytics / file_activity 省略 skip/hidden 完整可见性

| 字段 | 内容 |
|------|------|
| **Location** | `listContextSessions` ~2084–2117（仅 hidden+orphan）；`getToolAnalytics` ~289–347；`getFileActivity` ~349–388；`topToolsSince`/`fileHotspotsSince` |
| **Impact** | get_context 注入 skip/子代理噪声；analytics 相对 list_sessions/stats 过计 hidden/skip |
| **Root cause** | M18/M19 只关主路径 |
| **Fix** | 套 `SessionVisibilityFilter.listVisibleSQL`（及合适的 top-level parent）；fixture repro |
| **Effort** | M |
| **Source** | mcp-contract（3/3） |

### UI-002 / R9 — AI/Advanced 设置可丢末次编辑并堵主线程

| 字段 | 内容 |
|------|------|
| **Location** | `AISettingsSection` scheduleSave ~330–336；`SettingsView` Advanced ~250–381；`SettingsIO.mutateEngramSettings` ~136–161 |
| **Impact** | AI 400ms debounce 取消且无 onDisappear flush → 离开可丢密钥/预算编辑；Advanced 每次 onChange 同步 flock+写 JSON 可卡 UI |
| **Root cause** | 设置仍 MainActor 文件 I/O；AI 半 debounce 无 leave-flush |
| **Fix** | Advanced debounce；离开/scenePhase flush；I/O 离主线程 |
| **Effort** | M |
| **Source** | SwiftUI/UX（3/3）；followups R9/M21 |

### R4-dual-tx — Insight 成功嵌入与失败记账非原子（#197 nit）

| 字段 | 内容 |
|------|------|
| **Location** | `EngramServiceRunner` ~1550–1565；`InsightEmbeddingBackfill` writeEmbeddings/recordFailures ~99–110, 138–212 |
| **Impact** | writeEmbeddings 提交后、recordFailures 提交前崩溃/抛错 → 本轮失败项保持 pending，下一合格周期可能重复 provider 调用并延后 retry/terminal 收敛；已成功写入项不会再选（session 路径单事务更强） |
| **Root cause** | 产品 runner 分两次 `writer.write`；与 session backfill 不一致 |
| **Fix** | 单事务写成功向量 + 失败行；或失败先/同批 |
| **Effort** | S |
| **Source** | PR #197 review |

### F5-CI — npm audit 在 push 严格、PR soft（#196 后 main 风险）

| 字段 | 内容 |
|------|------|
| **Location** | `.github/workflows/test.yml` ~93–95 |
| **Impact** | PR 绿、merge 后 main Node quality/CI Gate 可因 adm-zip 等红，破坏发布基线信心 |
| **Root cause** | continue-on-error 仅 pull_request |
| **Fix** | 对齐 PR/push 策略，或锁/替换传递依赖 |
| **Effort** | S |
| **Source** | PR #196 F5 |

## A.4 Low（选择性；含 unverified 标签）

| ID | 标签 | 摘要 | Effort |
|----|------|------|--------|
| R5-recovery | confirmed pre-existing | recovery intent over-budget `continue` 非 ordered stop | S |
| R11-r1-overclaim | resolved in PR #197 pre-submit | followups 已明确 R1 open (partially mitigated) | — |
| SVC-005 | selective | `periodicFtsOptimize` 与 long-running 分类（与 CONC-001 同根，可能部分被 prefix 覆盖 — 需再钉名） | S |
| EMB-008 | selective | insight embed 逐条 HTTP 无 batch | M |
| EMB-009 | selective | `insights.has_embedding` 成功写后从不置 1 | S |
| ARCHV-005 | selective | Gemini projects.json 无 temp/parent fsync（L26） | S |
| ARCHV-006 | selective | JsonlPatch parent fsync fire-and-forget | S |
| MCP-010 | selective | list_sessions endTime `""` vs fullSession null | S |
| MCP-011 | selective | save_insight schema 无 min/maxLength | S |
| MCP-012 | selective | project_timeline 缺 skip/top-level | S |
| SEC-006 | selective | Warp tab config 未强制 0600 | S |
| UI-009 | selective | Search UI 拦 1 字 CJK | S |
| TEST-009 | selective | Swift 产品无 coverage 门禁 | M |
| ARCH-006..009 | positive | 单写者门禁/远程隔离/adapter 工厂/project-move 分层健康 | — |

## A.5 有意非 High / 设计接受（勿当缺陷重开）

| ID | 结论 |
|----|------|
| ARCHV-001 JsonlPatch soft-fail | **有意** Round-4 soft-issue 策略；非静默半写；最多设计增强为 fail-closed |
| SEC-005 Keychain DerivedData bypass | **接受** 开发策略 + SEC-M3 fail-closed；非安装 Release 缺陷 |
| SEC-008 / SEC-M5 MCP same-user | **接受** T2 设计 residual |
| READ-005 MCP orphan_status | **有意** MCP hygiene vs App 可见；文档已述 |

## A.6 Refuted（本轮多数否决）

See `2026-07-18-multi-agent-full-code-audit-findings.json` → `refuted_ids`. The blind closeout adds `AG-BYTES-001`: 1 confirmed / 2 refuted because Antigravity's retained `pbSizeBytes` is the documented historical logical size of the complete `.pb` session, not the physical size of the derived JSONL locator.

## A.7 Blind-audit implementation inventory (open)

All tests named below are proposed `_repro` starting points and were **not executed** during adjudication.

| Batch | Confirmed IDs | Severity |
|-------|---------------|----------|
| **A1 — Codex parser and indexing integrity** | ADAPTER-CODEX-001, ADAPTER-CODEX-002, IDX-PARTIAL-001 | 3 Medium |
| **A2 — Kimi composite session correctness** | KIMI-001, KIMI-002, KIMI-003 | 3 Medium |
| **A3 — Qwen product integration** | SRC-QWEN-001, SRC-QWEN-002 | 2 High |
| **A4 — Adapter ingestion guardrails** | ADAPTER-CC-001, SRC-COMMANDCODE-001, VSCODE-INCR-001 | 3 Medium |
| **B1 — Composite-input discovery and invalidation** | ADAPTER-GEMINI-001, COPILOT-AUX-001, COPILOT-DISCOVERY-001 | 3 Medium |
| **B2 — OpenCode archive and byte accounting** | ADAPTER-OPENCODE-001, ADAPTER-OPENCODE-002 | 1 Medium, 1 Low |
| **B3 — Cursor content and ownership** | CURSOR-CONTENT-001 TDD-ready; CURSOR-CWD-001 design/evidence pending | 2 Medium |
| **C1a — Archive V2 source-toggle convergence** | SRC-001 | 1 Medium |
| **C1b — Writer locator relocation** | WRITER-LOCATOR-001 | 1 Medium |
| **C1c — Startup parent-backfill pagination** | PARENT-BACKFILL-STARVE-001 | 1 Medium |
| **D1 — MCP result contract** | MCP-001 | 1 Medium; existing inventory row reconfirmed |

Each implementation-ready finding must follow TDD: create a failing `_repro`, record RED, apply the minimum production fix, validate focused/full GREEN, obtain a fresh Codex `PASS`, and only then commit/push/create the stacked PR. CURSOR-CWD-001 must first establish a deterministic workspace-ownership contract and must never infer authoritative project state from an unrelated file selection. No automatic merge is authorized.

---

# B) Implemented Features Inventory

（用户/运维可感知与产品权威模块；TS 参考不单列功能。）

### 运行时与权威
- **Engram.app**：菜单栏 + 主窗；启动 EngramService；GRDB 只读 facade；设置/UI
- **EngramService**：Unix socket IPC；单写者；索引/归档/项目迁移命令分发
- **EngramMCP**：stdio MCP；本地只读工具 + 经 service 的突变
- **EngramCoreWrite**：schema/migrations、indexer、snapshot、embedding、ProjectMove、ArchiveV2、RemoteSync
- **EngramCoreRead**：只读 pool / connection policy（查询层仍薄）
- **Shared/EngramCore**：adapters、tier、CJK、redaction、可见性过滤
- **EngramRemoteServer**：独立 CAS 副本服务（不进 App bundle）
- **EngramCLI**：resume/archive 小表面

### 会话与索引
- 17 源 adapters（14 默认开；cline/iflow/lobsterai archived default-off；minimax 默认开）
- Tier：skip / lite / normal / premium；skip 隐藏噪声；lite 可见但不进 keyword
- 父子会话：path / originator / sidecar / heuristic / manual；Polycli provider-parent
- FTS 版本化 rebuild；bounded periodic merge
- 可选 embedding → semantic_chunks + insight_embeddings；混合 RRF

### 搜索与记忆
- Keyword FTS + CJK/short LIKE（H2）
- Service/MCP semantic/hybrid（可用性 probe、model/dim fail-closed、breaker）
- get_memory hybrid + 降级警告；save_insight 文本始终可用
- Insight R4：仅明确 input-local 拒绝进入失败表/permanent；HTTP/transport、malformed response、dimension/config mismatch 传播并保持 pending；产品 runner 接线

### Archive / Project
- Archive V2 双副本、双收据 reclaim、R5 预算游标、recovery lease
- Project move/archive/undo/batch；LIFO 补偿；JsonlPatch 流式
- 可选 legacy remote offload（FTS bundle）

### 安全
- 0700/0600、peer euid、capability token 全 mutator
- 路径禁闭、export 0600、memory O_NOFOLLOW
- Keychain AI/archive/offload；Release fail-closed
- Transcript 默认 redaction；`include_raw` 可选

### UI 表面
- Today/Sessions/Timeline/Search/Projects/Agents/Activity/Memory/Hygiene/Workspace/Observability
- ExpandableSessionCard；Command palette；Popover human-driven
- Settings：General/AI/Sources/Archive/Advanced（**Advanced noiseFilter 死控件见 UI-001**）

### CI / 发布
- test.yml 变更分类 + Swift/MCP/remote/UI/CodeQL
- release-verify 无 Node 包 hygiene；自托管 ad-hoc；公证手工（L21）

---

# C) Roadmap

## Now — blind-audit ownership stack

| Order | Batch | IDs |
|-------|-------|-----|
| 1 | A1 Codex parser and indexing integrity | ADAPTER-CODEX-001, ADAPTER-CODEX-002, IDX-PARTIAL-001 |
| 2 | A2 Kimi composite session correctness | KIMI-001, KIMI-002, KIMI-003 |
| 3 | A3 Qwen product integration | SRC-QWEN-001, SRC-QWEN-002 |
| 4 | A4 Adapter ingestion guardrails | ADAPTER-CC-001, SRC-COMMANDCODE-001, VSCODE-INCR-001 |
| 5 | B1 Composite-input discovery and invalidation | ADAPTER-GEMINI-001, COPILOT-AUX-001, COPILOT-DISCOVERY-001 |
| 6 | B2 OpenCode archive and byte accounting | ADAPTER-OPENCODE-001, ADAPTER-OPENCODE-002 |
| 7 | B3 Cursor content and ownership | CURSOR-CONTENT-001 TDD-ready; CURSOR-CWD-001 design/evidence pending |
| 8 | C1a Archive V2 source-toggle convergence | SRC-001 |
| 9 | C1b Writer locator relocation | WRITER-LOCATOR-001 |
| 10 | C1c Startup parent-backfill pagination | PARENT-BACKFILL-STARVE-001 |
| 11 | D1 MCP result contract | MCP-001 |

R4-dual-tx and F5-CI remain separate small follow-ups. The earlier SVC-001, EMB-001, CONC-001, EMB-STARVE, and READ-001/002/003 follow-ups are closed with executable RED→GREEN evidence; ARCH-001 remains open.

## Next — existing confirmed inventory

| Item | IDs |
|------|-----|
| Shared CoreRead query module + cross-surface parity | ARCH-001 / R1 |
| get_context / analytics visibility | MCP-002 |
| Offload durability proof | SEC-001 |
| Settings flush/off-main I/O | UI-002 / R9 |
| Wire or remove Advanced Session Filter | UI-001 |
| Offload HTTP depth parity | R7 |
| Secondary skip aggregates | R3 residual |

## Later / conditional

| Item | IDs / boundary |
|------|----------------|
| Project-move writer-gate availability redesign | R6 |
| Codex content tail implementation or product-claim reduction | R8 |
| Notarization automation and public release assets | L21 / ops |
| ANN index, batched insight embedding, split embedding metadata | performance/design |
| MCP allowlists / include_raw confirmation UX | SEC-M5 enhancement |
| Remote server GC, multi-tenancy, and rate limits | intentionally out of current scope |
| Deeper runtime evidence for backup/restore, capture stack, export, MCP stdio/framing, undo/batch cancellation, and observability retention | remaining coverage limitation |

---

## Coverage limitations

1. **Adapter coverage is now explicit, not exhaustive proof.** The closeout named all 17 sources and adjudicated every submitted candidate, but a source with no retained finding was not proven defect-free.
2. **No proposed blind-audit `_repro` was created or run.** Twenty-one confirmed findings have TDD entry points; CURSOR-CWD-001 instead has a design-safety test pending a deterministic workspace-ownership contract. These are specifications, not validation evidence. Real occurrence frequency remains unquantified for several edge inputs, including Cursor empty `text` with non-empty `rawText`, Copilot empty-events checkpoint fallback, CommandCode missing timestamps, and legacy parent-backfill starvation.
3. **Other low-finding surfaces remain limited:** Archive capture→CAS→replicate, UserDataBackup/restore, transcript export, MigrationRunner/FTS rebuild concurrency, MCP stdio/framing, project-move undo/batch cancellation, CLI resume, and observability retention.
4. **ARCHV-001** remains an intentional soft-issue policy rather than a High defect. Large JsonlPatch soak coverage also remains a test-depth limitation rather than a reopened R2 logic bug.
5. The original synthesis did not run a complete Xcode build. Later fixed batches record their own focused/full suites; READ-001/002/003 reached `EngramMCPTests` 161/161 and a successful Debug `Engram` build. No production test result is claimed for the documentation-only blind-closeout update.
6. `readyToImplementAll = false`: 21 of 22 confirmed blind findings are sufficiently adjudicated to start TDD, while CURSOR-CWD-001 remains design/evidence pending. This scoped readiness does not close the repository-wide audit, existing confirmed inventory, accepted residuals, or R1/R6/R7/R8/R9.

---

## Related

- `docs/reviews/2026-07-18-two-day-pr-review.md`
- `docs/reviews/2026-07-18-multi-agent-full-code-audit-findings.json`
- `docs/reviews/2026-07-18-full-project-review.md`
- `docs/reviews/2026-07-17-engram-full-audit.md`
- `docs/reviews/2026-07-17-finding-disposition.md`
- `docs/followups.md`
