# Engram 两日 PR 复审合成 — 2026-07-18

**分支：** `fix/audit-2026-07-18-r4plus` @ committed HEAD `2940e6c9` + pre-submit working tree
**范围：** PR #181–#187（可用复审证据）、#196（已合并）、#197（开放）；#188–#195 已折叠进 #196，不重复计缺陷。  
**方法：** 父编排器提供的 per-PR 复审 + 对抗性 majority-vote 验证；本文件只综合 **已验证** 结论，不发明新 finding。

---

## 总览

| PR | 状态 | 裁决 | 一句话 |
|----|------|------|--------|
| #181 | merged | SOLID_MERGE_LOW_RESIDUAL | TS 7.0.2 工具链升级，产品面无影响 |
| #183 | merged | ACCEPTABLE_WITH_RESIDUAL_RISKS | 维护内存边界扎实；**idle 嵌入饿死**残留仍在 HEAD |
| #184 | merged | SOLID_MERGE_WITH_RESIDUALS | Keychain 主线程债 / noVisibleMessages / 部分 withLock |
| #185 | merged | SOLID_MERGE | Archive 收据 `renameatx_np` 原子发布 |
| #186 | merged | SOLID_MERGE_LOW_RESIDUAL | MCP 两工具 object-root；**manage_project_alias list 仍是 array-root** |
| #187 | — | 无本轮独立复审包 | 若存在，未进入本合成输入；不臆测 |
| #188–#195 | closed into #196 | n/a | 并行 stack 折叠，避免双合并 |
| #196 | merged | ACCEPTABLE_WITH_RESIDUALS | 07-17 High 关闭 + R1–R3；合并时 M3-insight/M4-budget/M14 证据未完整 |
| #197 | **open** | **PRE_SUBMIT_REVIEW_PENDING** | 原 Grok APPROVE_WITH_NITS；Codex taxonomy blocker 已按 TDD 修正，等待 fresh PASS |

**对 #197 的建议：** 暂不提交/推送。当前工作树已将 R4 收窄为只有明确 input-local 拒绝消耗永久预算，并修正 `docs/followups.md` 的 R1 状态；测试和真实 Service/MCP runtime 已通过，仍须 fresh Codex PASS。dual-tx 与 recovery ordered-stop 适合后续小 PR。

---

## PR #181 — TypeScript 7.0.2

**Verdict:** SOLID_MERGE_LOW_RESIDUAL  
**Summary:** 仅 `package.json` + lock 升 TS 6→7.0.2；无 Swift/产品路径变更。设计文档与 CI 证据充分。

**Strengths**
- 变更面极小；lock 仅官方 typescript + optional native packages
- 产品边界清晰：TS 非 shipped runtime
- pre-merge CI（Node / fixture / Swift / CodeQL / Dependency Review）绿

**Findings：** 无缺陷级

**Residual risks**
- `typescript@^7.0.2` caret 可能浮到未重跑 emit 合同的 7.x
- 可选依赖若被 `--omit=optional` 会破坏 tsc
- 编辑器/tsserver 行为非产品门禁

---

## PR #183 — 维护内存与冗余工作边界

**Verdict:** ACCEPTABLE_WITH_RESIDUAL_RISKS  
**Summary:** 嵌入 batch 限、archive 节流、policy 跳过、stale-status 与自适应扫描对齐。合并质量总体好，但 **merge-only `scan.indexed` × 周期嵌入门控** 仍导致 idle 机上 embedding backlog 饿死（仍在当前 HEAD）。

### Findings（合入后仍相关）

| ID | Severity | 位置 | 说明 |
|----|----------|------|------|
| F1 / EMB-STARVE | **High（仍 open）** | `EngramServiceRunner` periodic gate；`SwiftIndexer.writeBatchCountingSuccesses` merge-only | `scan.indexed > 0` 才跑 session/insight embed；idle 且仅有 pending/retry 任务时永久跳过直到 merge 或重启 |
| F2 | Medium | EmbeddingMaintenanceBackoff | circuitOpen 触发 1h–1d 维护退避，偏激进 |
| F3 | Medium | RepoDiscoveryMaintenanceThrottle | 选中即写 6h cooldown，probe 失败也吃满窗 |
| F4 | Medium（历史） | session embed all-or-nothing | 后续隔离路径已缓解；属 #183 合并质量残留 |
| F5 | Low | insight 单次 embed 请求 | 后由 R4 改为 per-item isolation，批处理仍弱 |

**Strengths**
- 多层内存边界清晰；merge-only 计数与回归测试
- archive policy skip / historical freeze 设计谨慎
- 聚焦测试覆盖 guardrails / telemetry / archive coordinator

**Residual risks**
- **F1 仍是 post-#183 最大产品风险之一**（配置了 embedding 的 idle 主机）
- 长 backoff 与 discovery 冷却的运维延迟

---

## PR #184 — Swift runtime debt

**Verdict:** SOLID_MERGE_WITH_RESIDUALS  
**Summary:** 三刀：(1) Keychain 启动不再主线程 SecStaticCodeCheckValidity；(2) Claude/Qwen/VS Code 空/元数据-only → `noVisibleMessages`；(3) 部分 cancel/work 路径 `NSLock.withLock`。

### Findings

| ID | Severity | 说明 |
|----|----------|------|
| R184-1 | Medium | async NSLock 现代化不完整；同文件仍有 raw lock/unlock |
| R184-2 | Medium | Keychain bypass 改为 DEBUG/DerivedData；非 DerivedData ad-hoc Release 可能弹 Keychain（后被 SEC-M3 失败关闭策略吸收为 UX 权衡） |
| R184-3 | Low | `noVisibleMessages` 仅 3/17 adapters |
| R184-4 | Low | tail vs full-parse 终端策略仍分叉 |

**Strengths**
- 范围外科手术 (+267/−116)；adapter `_repro` 测试
- `FileIndexState.isTerminalFailure` exhaustive
- cancel 路径 snapshot under lock 再 await 的正确模式

**Residual risks**
- 产品内大量 `@unchecked Sendable` + NSLock 模式未清
- 其他 adapter 空会话噪声/重试债

---

## PR #185 — Archive 收据原子发布

**Verdict:** SOLID_MERGE  
**Summary:** `link` 双 hard-link 窗口 → Darwin `renameatx_np` + `RENAME_EXCL`，关闭并发 `st_nlink==2` 被拒。

**Strengths**
- 根因与修复对齐；fsync → exclusive rename → dir fsync 顺序正确
- 并发 already-present 恢复路径保留

**Findings：** 无

**Residual risks**
- rename 成功后、parent fsync 前的断电窗口（固有；读路径 re-fsync 缓解）
- path-based rename 仍依赖 parent identity assert，非 dirfd

---

## PR #186 — MCP structuredContent object roots

**Verdict:** SOLID_MERGE_LOW_RESIDUAL  
**Summary:** `project_list_migrations` / `project_recover` 数组根改为 object 信封；catalog-wide object-root 门禁。

**Strengths**
- schema / emission / golden / 消费断言同步
- Claude Code 2.1.212 tools/list 兼容证据

**Findings：** 本 PR 范围无；**后续 MCP-001** 指出同工具族 `manage_project_alias` list 仍为 array-root（#186 只覆盖有 outputSchema 的工具）

**Residual risks**
- 两工具有意 wire break；无 dual-shape 过渡窗
- TS 参考 handler 仍为 array API（非产品路径）

---

## PR #188–#195 → #196 折叠说明

并行 audit closeout stack（batch A–H / R1–R3 等）在 #196 以 main-based 巩固 PR **单点合并**，避免双合并与分叉 CI。后续复审以 #196 tip 与 post-merge R4+（#197）为准。

---

## PR #196 — 07-17 审计关闭 + R1–R3

**Verdict:** ACCEPTABLE_WITH_RESIDUALS  
**Title:** consolidated 2026-07-17 audit closeout + R1–R3 follow-ups  
**状态：** merged 2026-07-18 → `main`（`feb80e5d`）  
**规模：** ~+4529 / −425，约 74 files（含 stack 折叠）

### Summary

成功关闭命名 **High 产品缺陷** 与主要安全 High，并落地 R1 部分共享可见性过滤、R2 JsonlPatch 中流修复、R3 部分 skip 聚合。PR tip 产品 CI 绿；合并后 `origin/main` 因 **npm audit 在 push 严格 / PR soft** 不对称一度红（策略问题，非本 PR 引入 adm-zip）。

### 已关闭（有行为证据）

| ID | 证据要点 |
|----|----------|
| H1 | Projects `listSessionsByProject` GROUP BY + 测试 |
| H2 | MCP CJK/short LIKE + app CJKText 对齐 |
| SEC-H1 | bare-label 禁 + `requireTLS` 默认 true |
| SEC-H2 | ai-secrets scrub + 0700 data dirs |
| SEC-M1 | 无 /tmp resume log |
| M1 | `pendingOrActiveLongWrites` / sole long waiter 策略 |
| M12/R2 | mid-stream non-`$` + trim + unit repro（大文件 opt-in） |
| M18/M19/M24 等 | MCP list/costs fixtures |

### Findings（合并 tip 上成立；部分由 #197 关闭）

| ID | Sev | 合入后状态 |
|----|-----|------------|
| F1 M3-insight | Medium | **#197 R4 关闭** 产品路径隔离 + permanent |
| F2 M4-budget cursor | Medium | **#197 R5 关闭** 预算 skip 不推进 cursor |
| F3 M14 grep theater | Medium | **#197 R10 关闭** PUT→hasObject/hasManifest 行为测试 |
| F4 R3 次级 skip 表面 | Medium | **仍 open** listProjects/countsBySource/stats/timeline/context 等 |
| F5 npm audit push 严格 | Medium | **CI 策略残留**（main 红风险） |
| F6 disposition 无证据列 | Low | **#197 R11 改善** |
| F7 SEC-H1 陈旧注释 | Low | 仍属 R7 文档/注释残留 |

### Strengths
- 干净 consolidation；High 有 production-path 代码 + TDD
- SessionVisibilityFilter 是 R1 的第一刀
- 安全矩阵 / MCP fixture 深度好

### Residual risks（#196 后 → 仍 open 或 #197 部分关）
- 三套 Read SQL 结构风险（R1 / ARCH-001）
- 次级 skip 可见性（F4）
- 合并后 insight/reclaim/M14 缺口 → **#197 目标**
- npm audit 门禁不对称

---

## PR #197 — R4+（当前 HEAD，**开放**）

**Verdict:** **PRE_SUBMIT_REVIEW_PENDING**（原 Grok：APPROVE_WITH_NITS；Codex taxonomy blocker 已修，待 fresh PASS）
**Title:** R4 insight embed terminalization, R5 reclaim budget cursor, R10/R11  
**分支：** `fix/audit-2026-07-18-r4plus` @ committed HEAD `2940e6c9` + pre-submit working tree
**当前工作树规模：** +369 / −71，11 files（相对 committed HEAD；提交前再次生成）

### Summary

正确关闭意图中的产品缺口：

1. **R4** — insight 隔离只将 provider 明确声明的 input-local hard rejection 记入失败预算并最终 `failed_permanent`；HTTP/transport、malformed response、dimension/config 与 cancellation 传播并保持可恢复；产品 runner 路径与真实 Service/MCP surface 均有验证
2. **R5** — reclaim cursor 不再越过 byte-budget skip 的 eligible
3. **R10** — 行为级 PUT→hasObject/hasManifest（含 wrong-key）
4. **R11** — disposition 证据列 + followups 提升，R1 明确保留为 open

无 Critical/High 回归。

### Findings（nits / 后续）

| ID | Sev | 位置 | 说明 |
|----|-----|------|------|
| **R4-dual-tx** | Medium | `EngramServiceRunner` ~1550–1565；`InsightEmbeddingBackfill` writeEmbeddings/recordFailures | 成功写与失败记账分属两次 `writer.write`；若中间崩溃/抛错，本轮失败项保持 pending，下一合格周期会重复 provider 调用并延后 retry/terminal 收敛；已成功项不会再选 |
| **R5-recovery-residual** | Low | `ArchiveReclamationCoordinator` recovery 循环 | recovery intent 对 over-budget 用 `continue` 而非 ordered stop；非 R5 候选 cursor 回归 |

### Strengths
- committed PR 路径已接入真实产品 runner；pre-submit follow-up 进一步收窄 failure taxonomy
- schema `insight_embedding_failures` + pending 排除 permanent 健全，且只有 explicit input-local rejection 消耗预算
- 产品 runner repro 覆盖 explicit rejection terminalization 与 dimension/config mismatch recoverability
- R5 最小正确：ineligible 推进 / over-budget break 不推进 / reclaimed 推进
- R10 替换源码 grep 剧场

### Test gaps
- 无 dual-tx 崩溃/半提交 repro
- R10 以 store 级为主（route HEAD 已有 ArchiveRouteTests）
- provider 错误传播有 unit repro、runner-level dimension/config repro 与真实 Service/MCP HTTP 500 恢复证据；尚无 focused service-unit HTTP all-fail/backoff 专项
- 无 >256MB policy ineligible 推进 vs budget skip 对比用例

### Residual risks
- `testMaximumSourceBytesPerCycle` 进程全局可变
- R6–R9 与结构 R1 仍 open

### 提交与合并建议

| 动作 | 建议 |
|------|------|
| 提交/推送 #197 | **阻塞**：必须先获得 fresh Codex `PASS` |
| pre-submit docs | taxonomy、runtime evidence、R1/R11 状态需与最终 diff 一致 |
| PASS 后后续小 PR | R4 成功+失败同一事务；可选 recovery ordered stop |

---

## 跨 PR 主题

### 1. 审计关闭的“证据深度”螺旋
#196 关掉命名 High，但 M3-insight / M4-budget / M14 在合并 tip 上证据不足 → #197 用行为 repro 补完。**模式：** disposition “fixed” 必须挂可执行 repro，避免 grep theater。

### 2. 三读表面漂移（R1）是贯穿主线
#196 SessionVisibilityFilter 只切了 list/KPI 一刀；#197 不处理 Read SQL。**READ-001/002/003 + ARCH-001** 在当前 HEAD 仍是 #1 架构风险。

### 3. 写者门控名称白名单易漂移
#196 加固 M1 策略；**CONC-001** post-review follow-up 已将三个遗漏 startup phase 名与 `isLongRunningWriteCommand` 对齐，并用分类+排队行为 `_repro` 锁定。SVC-005 仍按其独立证据处理。

### 4. 维护调度指标语义收窄的副作用
#183 将 `indexed` 收窄为 merge-only 后，idle 嵌入饿死（F1）仍在 — 与 R4 产品路径并存：隔离修好了，**调度可能永远不跑**。

### 5. MCP 合同局部修复
#186 object-root 只覆盖有 schema 的工具；`manage_project_alias` list、get_context 可见性仍 residual。

### 6. 安全默认 hardening vs 传输深度
SEC-H1/H2 在 #196 关主路径；**SEC-001**（offload HEAD 后 shadow FTS）与 **R7**（URLSession.shared / 无 redirect 深度）仍是 opt-in 网络面残留。

---

## 与 07-17 / 07-18 基线对照（PR 视角）

| 基线项 | 07-17 审计 | 07-18 full review | 本两日 PR 复审后 |
|--------|------------|-------------------|------------------|
| H1/H2/SEC-H1/H2 | open → #196 fixed | 确认 fixed | 仍 closed |
| M3 session | fixed in stack | fixed | fixed |
| M3 insight | 误标/不全 | R4 open | **#197 关**（dual-tx Medium 残留） |
| M4 count | fixed | fixed | fixed |
| M4 budget | 不全 | R5 open | **#197 关** |
| M14 HEAD | 代码对、测试弱 | R10 | **#197 行为测试** |
| R1 triple read | 结构 | High residual | **仍 High** |
| R2 JsonlPatch | M12 | residual → #196 关 | closed（大 IO CI skip 覆盖残留） |
| R6–R9 | — | open | open |
| Disposition 证据 | 弱 | R11 | **#197 改善** |

---

## 最终建议

1. **暂不提交、推送或合并 #197**；R1 followups overclaim 与过宽 provider poison taxonomy 已在工作树修正，但必须先完成最终验证并取得 fresh Codex `PASS`。
2. **下一波工程优先（跨 PR）：**  
   - 共享 Read 谓词 / 跨表面 parity（ARCH-001 族）  
   - idle embedding drain 与 merge-only indexed 解耦（#183 F1）  
   - reclaim product-missing 页 cursor 推进（SVC-001；post-review follow-up 已关闭并有 full-page `_repro`）
   - skip 时删除 `semantic_chunks`（EMB-001）  
   - long-running startup 命令名与 call site 对齐（CONC-001；post-review follow-up 已关闭并有 classification + queue behavior `_repro`）
3. **勿**在 #197 范围膨胀做 R6 项目移动门控 redesign 或完整 R1 统一。

---

## 相关文档

- `docs/reviews/2026-07-18-multi-agent-full-code-audit.md` — 全量 multi-agent 审计
- `docs/reviews/2026-07-18-multi-agent-full-code-audit-findings.json` — 机器可读 findings
- `docs/reviews/2026-07-18-full-project-review.md` — 07-18 项目态
- `docs/reviews/2026-07-17-finding-disposition.md` — disposition 账本
- `docs/followups.md` — 开放 residual 路由
