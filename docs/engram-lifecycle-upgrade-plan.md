# Engram 全周期管理与检索升级计划（最终版）

## Status as of 2026-07-09 (plan-completion audit)

Per-item status after verifying this plan against git history and product code
(27-agent plan-completion audit). Wave-6 task numbers mark work in the current
execution queue; `parked-see-roadmap` items are listed in
`docs/roadmap.md` → Decision pending.

| Plan item | Status |
|-----------|--------|
| P0-1 engine pragma (`mmap_size=256MB`) | **not_done — rejection final**: product keeps `PRAGMA mmap_size == 0`; regression test enforces it |
| P0-2 activate Command Palette + ⌘K | **done** (alignment WP / palette opener tests) |
| P0-3 `last_accessed_at` / `access_count` columns + bump | **done** (sessions + insights; service IPC bumps) |
| P0-4 Service path `snippet()` highlight + cleanSnippet | **done** (service search + tests) |
| P0-5 observability retention prune | **partial / restart-cadence by design**: `ObservabilityRetention` runs once per service start (`EngramServiceRunner` rationale ~:113-115: legacy metrics writer dormant, largely one-time backlog cleanup). Revisit periodic only if a live `ai_audit_log` writer lands |
| P0-5b `ai_audit_log` body desensitization | **parked-see-roadmap** (no Swift writer today; design precondition) |
| P0.5 quality_score → GUI band badge + `value_override` | **parked-see-roadmap** |
| 3.1 multi-factor value score | **parked-see-roadmap** (unblocked by wave-6 task 5 score parity only) |
| 3.1 same-input/same-output score test | **partial** → wave-6 **task 5** |
| 3.2 lifecycle_state / shadow archive | **not_done** / **parked-see-roadmap** (`lifecycle_state` column does not exist) |
| 3.3 insight decay / access ranking | **partial** (read-side ranking done; type filter → wave-6 **task 7**) |
| 3.4 BM25/CJK ranking + faceting | **parked-see-roadmap** |
| 3.5 tool-result normalization + structured summary job | **parked-see-roadmap** |
| 3.5 P2 auto insight extraction | **parked-see-roadmap** |
| 3.6 quality_score / lifecycle_state indexes | **partial**: `quality_score` has no index; decision in wave-6 **task 6** (add only if live query uses it). `lifecycle_state` index parked (column missing) |
| 3.6 periodic FTS optimize | **partial** (startup-only today) → wave-6 **task 6** |
| P2 sqlite-vec + hybrid RRF (app already has brute-force) | **parked-see-roadmap** (F2); app/service hybrid exists without sqlite-vec |

> ## ⚠️ 实施前必读 — 主控亲自验证结果（2026-05-29）
>
> 本文由多 agent workflow 生成。**主控（Claude）随后亲自抽验了最承重的几条，结论是：诊断方向正确且核心叙事已坐实，但本文尚不是"实施就绪规格"——直接照 file:line 改会打偏。** 证据如下：
>
> **✅ 已坐实（实测/读码确认）**
> - "AI 能搜、人不能"是真的：`EngramMCP/Core/MCPDatabase.swift:627` 确有 `quality_score AS qualityScore`，`:696/:702/…` 多处 `ORDER BY quality_score DESC`，`:977` 一字不差是 `snippet(sessions_fts, 1, '<mark>', '</mark>', '...', 32) AS snippet`。AI/MCP 路径已用价值分排序 + 匹配高亮。
> - Command Palette 是死 UI：`MainWindowView.swift:7` 仅声明 `showPalette=false`，全文件只有两处 `=false`（关闭），无任何 `=true`、无快捷键、无按钮。
> - sqlite-vec 未实现：Swift 产品侧已删除无调用的 sqlite-vec probe / rebuild policy scaffold。**但注意 DB 里 `vec_sessions`/`vec_chunks`/`vec_insights` 表已存在**（schema 建了空表，只是扩展未加载）。
> - `IndexJobKind` 仅 `.fts`/`.embedding`（`IndexingEventTypes.swift:114-116`），无 summary job。（但 `EngramServiceModels.swift:138` 另有一个无关的 `case summary`。）
>
> **❌ 计划的硬伤（实施前必修）**
> 1. **文件路径系统性写错**：文中反复写的 `macos/Engram/MCP/MCPDatabase.swift` 实为 `macos/EngramMCP/Core/MCPDatabase.swift`；`macos/Engram/Core/EngramServiceReadProvider.swift` 实为 `macos/EngramService/Core/EngramServiceReadProvider.swift`。**文件名与行号大体正确，但目录路径错**——照搬会 grep/编辑失败。下方"已核对清单"也带着同样的错。
> 2. **所有阈值此前是占位**：现已实测（见下），硬编码 33/67 会错——**实测 `quality_score` 最大值仅 74，不是 100**。
>
> **📊 实测数据（`~/.engram/index.sqlite`，668.5 MB / 171147 页 × 4096，WAL）**
> - **FTS 主导增长被证实**：`sessions_fts_data` 272 MB + `sessions_fts_content` 98 MB = **370 MB ≈ 全库 55%**。
> - **观测表臃肿被证实，且比计划想的更偏**：`metrics` 56 MB（比 `ai_audit_log` 37 MB 还大）+ metrics 两个索引 34+22 MB + `session_index_jobs` 24 MB + `traces` 16 MB + `metrics_hourly` 15 MB ≈ **204 MB ≈ 30%**。`ai_audit_log` **173,441 行**。→ retention 应优先治 `metrics`，不只是 `ai_audit_log`。
> - **会话量**：总 11,786；非-skip 2,569（premium 1201 / normal 1066 / lite 302）；skip 9,217。
> - **quality_score 分布（非-skip）**：min 0 / **max 74** / avg 42.3；众数桶在 30（987 条）和 60（562 条）。→ 三档阈值须按真实分位取，不能套 0-100。
>
> **结论**：第 0 步（实测）已由主控完成，数据见上。诊断与优先级可信；但 P0 落地前仍需逐条把路径/行号改对、补齐 E1–E5。**最干净的首个 PR 是观测表 retention（孤立、零行为风险、实测 204MB/30% 收益明确）**，而非计划原列的 pragma（计划自己也承认"写连接 pragma 落点未找到"）。
>
> ---
>
> 本文以下为 workflow 原始产出（含上述待修的路径错误，保留以便对照）。所有承重事实已经过直接读码核对；凡标注 `file:line` 的引用，落地前仍需用 `grep`/`find` 二次确认行号（代码会随近期提交漂移）。
> 原则：**Swift 产品为权威**；新增列一律用 `EngramMigrations.swift` 现有 `addSessionColumnsIfNeeded` 幂等 `ALTER` 模式（追加元组，无需版本账本）；每项产线行为变更配 Swift 聚焦测试；最小 diff，不重构相邻无关代码。
> **sqlite-vec 在产品中未实现**——所有依赖向量的能力均为硬前置、隔离到 P2。

---

## 0. 执行摘要

**一句话诊断**：Engram 是一个"元数据丰富的会话目录 + 全量 trigram FTS"，但**生命周期层完全缺失**（无价值区分动作、无会话级归档、无记忆老化）；而面向"人"的检索弱到关键能力**已存在却未接线**——价值分 `quality_score` 已在 AI/MCP 路径被排序使用，却没接进 app 读模型；带高亮的 `snippet()` 已在 MCP 路径用上，app 服务读路径却返回整段正文；唯一的全局搜索面板（Command Palette）因 `showPalette` 从无 `= true` 而成为死 UI。

这印证了用户痛点的代码级根因：**"AI 能检索、人不能"在代码里字面成立**——AI 走的 `MCPDatabase` 已有 quality_score 排序 + `snippet()` 高亮，人走的 `EngramServiceReadProvider` 两者皆无。因此升级的本质是**把已为 AI 接好、却没给人接的能力补齐，并补上整个生命周期层**，而非从零造轮子。

**修正后的真 P0（本周可合、零依赖、不可辩驳）**：

1. **引擎 pragma**（`mmap_size=256MB` + 更大 `cache_size`）——约 5 行，30 分钟，零风险，对数百 MB 级 FTS 库的 MATCH/LIKE 读延迟立竿见影。
2. **激活 Command Palette**——翻转 `showPalette`，但**必须连带验证**其读路径与 ⌘K 在 split view + sheet 下的可靠触发（不是无脑"1 行"）。
3. **`last_accessed_at` / `access_count` 列 + 三处 bump 埋点**——价值分与老化的共同前置，越早埋点越早积累数据。
4. **Service 读路径加 `snippet()` 高亮**——直接复制 `MCPDatabase.swift:977` 的项目内现成配方（不是移植 TS），并同步改 `SearchPageView.cleanSnippet` 避免把 `<mark>` 剥掉。
5. **观测表 retention prune + `ai_audit_log` body 脱敏**——挂到现成的 5 分钟 `runIndexingLoop`，止住无界增长；`ai_audit_log` 明文存储请求/响应是隐私问题，脱敏从风险项提级到 P0。

**P0.5（P0 后立即，有 1 个核对前置）**：接活 `quality_score` 到 app GUI 读模型——但先**核对两个 `computeQualityScore` 实现一致性**、并**实测分数分布定三档阈值**，确认分数可信后再暴露给用户。单因子 band，**首版不做多因子融合**。

**战略定位**：ReadOut（v0.0.11）、AgentSession（v3.8.2）在人工搜索/解析/分发上更成熟，但**三家都没有"价值区分驱动的动作 + 自动归档 + 记忆老化"**。Engram 已有真 LLM 摘要栈 + 分层启发式 + 单写者服务架构，使它能在"智能生命周期与记忆"上做出差异化，而非追赶式做第 N 个会话浏览器。

**相对草案的关键修正**：
- `quality_score` **不是死列**——MCP 路径已读取并排序（`MCPDatabase.swift:627/1141`）；它是 `INTEGER`（0-100），不是 REAL。
- `snippet()` 高亮 **MCP 路径已有**（`MCPDatabase.swift:977`），修复 = 项目内复制，不是"移植 TS"。
- P0 从 6 项瘦身为 5 项，且把被严重低估的项（多因子价值、ToolResultNormalizer、归档状态机、RRF）下调优先级或砍掉。
- 归档安全补两个必备设计：**影子模式（只标记不删）** + **救回需显式新写路径**（读路径当前纯只读）。

---

## 1. 现状诊断

### 1.1 人工检索/搜索

- **唯一全局搜索面板不可达**：`MainWindowView.swift` 声明 `@State showPalette = false` 并接了 sheet，但**全代码库无任何 `showPalette = true`**（无快捷键、无按钮、无 `CommandMenu`）。`CommandPaletteView.swift`（支持 `>` 命令、方向键导航）无法被用户打开。注意它当前发 `mode:"hybrid"`（`CommandPaletteView.swift:190`），而服务把 hybrid 降级为 keyword 并返回 warning，所以激活后语义上仍是关键词结果。
- **片段无高亮、给人的路径返回整段正文**：**关键修正**——`MCPDatabase.swift:977` 已用 `snippet(sessions_fts, 1, '<mark>', '</mark>', '…', 32)`，即**给 AI 的 MCP 路径已有匹配处高亮片段**；而给人的 Service 读路径 `SELECT s.*, f.content AS snippet`（`EngramServiceReadProvider.swift:448,479`；`Database.swift:423`）**返回整段 FTS content 全文**——截断（`.prefix`）发生在 DTO/IPC 层而非该 SQL 层（已确认 `EngramServiceReadProvider.swift:756` 注释 "Upper bound on the search snippet length returned over IPC"；草案"截前 600 字符"是臆测，落地前需确认截断到底在哪一层，否则 diff 会打偏）。`SearchPageView.cleanSnippet` 用正则 `<[^>]+>` 剥标签——若服务端改用 `snippet()`，**现有 cleanSnippet 会把 `<mark>` 一起剥掉**，必须同 PR 改 UI（强耦合）。
- **排序弱到几乎没有**：拉丁路径 `ORDER BY rank`（`EngramServiceReadProvider.swift:489`；`Database.swift:439`），因 `SELECT s.* … GROUP BY s.id`，rank 是被聚合掉的粗排，无字段权重/无时间/无 quality 加权；CJK 路径 `ORDER BY s.start_time DESC`（`EngramServiceReadProvider.swift:458`）纯按时间——**对中文用户，CJK 路径完全无相关性排序**。
- **无语义/混合检索 + 静默失败**：Swift 产品侧没有 sqlite-vec runtime，服务把 `semantic/hybrid/both` 降级为关键词 + warning；2 字符拉丁查询静默返回空（trigram 最少 3 字符）；FTS 特殊字符无 `try/catch` 重试（TS 有 `isFtsSyntaxError`，Swift 没有）；CJK 正则漏掉日文假名、韩文 Hangul、CJK Ext-B。

### 1.2 对话解析/清洗/AI利用

- **工具输出几乎被全部丢弃（最大信息损失）**：`ClaudeCodeAdapter.formatToolResult`（`:453-468`）除非以 `"User has answered"` 开头否则返回 `""`。文件 diff、测试通过/失败、错误信息、stdout 全部进不了 FTS 和摘要。各 adapter 还不一致（`QoderAdapter.swift` 反而保留 tool_result）。**~15 个活跃 adapter 工具结果格式各异**，统一归一是系统性工作量。
- **AI 看到的是二次扁平化文本**：摘要 transcript 由 `aiContext` 从 `sessions_fts` 重读拼接——模型看到的是已被 adapter 扁平化、又丢了 `[role]` 前缀的 FTS 文本，非原始 transcript。
- **摘要是无结构散文 + 无 summary job**：`IndexJobKind` 只有 `.fts`/`.embedding`（`IndexingEventTypes.swift:114-116`），**没有 summary job kind**（`SessionSnapshotWriter.jobKinds:375-384` 无 summary），自动摘要未接入索引管道，只能靠按需 `generateSummary`。摘要仅 OpenAI（`summaryConfig` 在非 openai 时返回 nil，`EngramServiceCommandHandler.swift:1694`），无 JSON schema、无 provenance（无 `model/prompt_version/generated_at`）。
- **无脱敏 + 无自动洞见抽取**：`src/core/sanitizer.ts` 是 TS-only，未在 Swift 写 FTS / 调外部 LLM 前应用——密钥/token/邮箱原样发给第三方 API，**且 `ai_audit_log` 把完整 request/response body 落库长期留存**（`EngramMigrations.swift:284-305`）。`insights` 表是**只写**（仅 MCP `save_insight`），无从已完成会话挖掘可复用知识的能力。

### 1.3 价值区分

- **`quality_score` 不是死列，但 app GUI 没接**（**重大修正**）：在 `SessionSnapshotWriter.swift:386` 计算并落库（`INTEGER DEFAULT 0`，0-100，5 因子：turn ratio/tool/density/project/volume），`StartupBackfills.swift:331` 回填。`grep quality_score` 在 `EngramCoreRead/` **0 命中**——但**MCP 路径已经在用**：`MCPDatabase.swift:627` 按它排序、`:1141` 经 DTO 暴露，`TranscriptExportService.swift` 也读出。准确表述：**"已在 AI/MCP 路径被排序消费，但 app GUI 读模型（EngramCoreRead/`Session.swift`）完全没接"**——恰好印证"AI 能检索、人不能"。⚠️ 注意：`computeQualityScore` 存在两处实现（`SessionSnapshotWriter.swift:386` 增量索引 + `StartupBackfills.swift:1002` 回填），暴露前**必须核对两者一致**，否则 UI 会看到分数抖动。
- **`tier` 是体量代理，不是价值代理**：`SessionTier.compute`（`SessionTier.swift:9-46`）只看消息数/时长/preamble——25 条没产出的对话是 `premium`，6 条修好生产 bug 的是 `normal`。无 outcome/复用/用户判断信号。
- **无高/中/低分类，无用户价值覆盖，无负向信号**：schema、服务协议、读模型、UI 全无 value band；favorites 是二元星标，不是分级；`session_files`/`session_tools`/`session_costs`/`git_repos` 等潜在价值信号未喂入评分；**且无降分维度**（探针/健康检查会话、被 abort、纯报错无解决、子代理会话靠 access/volume 会虚高）。

### 1.4 自动归档

- **会话级归档概念完全不存在**：代码库里所有 `archive` 都是**项目目录搬移**（`ProjectMove/Archive.swift`，手动确认、价值盲）。`sessions` 表无 `is_archived`/`archived_at`/`archive_reason`/`lifecycle_state`（读遍 `EngramMigrations.swift:372-409` 确认；该处即幂等 `addSessionColumnsIfNeeded` ALTER 模式）。
- **无 hot/warm/cold 分层、无定时归档任务**：所有非-skip 会话等权、永久全量索引展示。`maintenance` 只做 backfill + 物理维护（VACUUM/checkpoint/dedup/reconcile），**不归档/不保留/不衰减**。
- **现成机制可复用但有副作用须当心**：`deleteIndexArtifacts`（`SessionSnapshotWriter.swift:356-357`，`DELETE FROM sessions_fts`）与 `StartupBackfills.swift:501` 都做删行——正是归档需要的删行动作，但它**在 upsert 流程内被调用**（`SessionSnapshotWriter.swift:33`），且 5 分钟 `runIndexingLoop → indexRecentSessions`（`EngramServiceRunner.swift:257`）扫描会因源文件变化**把归档会话重新索引回来**。这是归档的致命回归点，必须加 `lifecycle_state='archived'` 扫描短路。

### 1.5 记忆老化

- **无 recency/access 追踪**：`sessions` 与 `insights` 均无 `last_accessed_at`/`access_count`——任何老化模型的核心输入都缺。
- **无衰减、无 TTL、无强化**：insights `importance INTEGER DEFAULT 5`（`EngramMigrations.swift:312-338`）写入后**永不更新/衰减**。`get_memory` **零 `ORDER BY`**——连 importance 排序都没有。注意 `importance` 是 **insight 的列，不是 session 的列**——session 老化与 insight 老化是两套不同输入，不能混进同一公式。
- **唯一"增长缓解"是物理 VACUUM**——回收碎片，不回收知识体量。FTS 随原始正文单调增长。

### 1.6 数据模型与规模（enabler）

> ⚠️ **以下存储论证须先实测验证**：草案断言"FTS 把库推向 GB"但无实测。落地前应取 `PRAGMA page_count`、`dbstat` 各表字节占比、`quality_score` 实际分布，用真实数据决定 retention/归档窗口，而非拍脑袋 30/90 天。

- **存储增长预期由 `sessions_fts` 主导**：FTS 存每条非-skip 会话的全量 transcript，trigram 是最耗空间的 tokenizer（索引通常是源文本 2-4 倍）。需实测确认占比。
- **FTS 刷新是 delete+全量重插**：`replaceFtsContent`（`IndexJobRunner.swift:250`）任何计数变化都删该会话全部 FTS 行再重插；`optimize` 仅启动跑一次，长时运行积累 tombstone 膨胀。
- **`FTS_VERSION` bump = 重解析磁盘全语料**：`FTSRebuildPolicy.appVersionChanged` 触发全量重建（`FtsLifecycle.swift`）——语料越大越慢。
- **`access`/`value` 缺索引**：要按 recency/value 排序与归档筛选，需要 `last_accessed_at`、`lifecycle_state`、`quality_score` 上的索引，否则全表扫。

---

## 2. 竞品与业界洞察

### 2.1 ReadOut 可借鉴点（v0.0.11，已逆向）

- **"Card IS your answer" 摘要设计**：模型只输出 marker + 简短引导，长内容推给 UI 卡片（`EmbedType` 18 种）。Engram 可借此把"结构化摘要"渲染成卡片而非散文段。
- **`.summary: String` per-scanner 协议**：每个数据源实现统一的 AI 上下文注入契约——对应 Engram 应统一 ~15 个 adapter 的 transcript 归一化输出。
- **CostTracker 双缓存并行加载**（`async let`）：Engram 摘要/索引管道可借此并行化。
- **局限**：ReadOut 是"实时 chat + workspace 编排"工具，**无跨会话价值分级/归档/老化**——这正是 Engram 的差异化空间。

### 2.2 AgentSession 可借鉴点（agent-sessions，v3.8.2，有源码）

- **纯本地、隐私优先的会话浏览器**：成熟的人工浏览/过滤/搜索体验（这正是 Engram 人工检索的短板）。
- **多源会话解析**（Claude/Codex/Gemini）+ Ghostty 终端集成。
- **局限**：同样**无价值区分动作、无自动归档、无记忆老化**——确认这是全行业空白。

### 2.3 GitHub 同类 / 记忆系统做法

- **Mem0**：抽取-巩固式记忆，LLM 决定 add/update/delete，带 importance 加权；检索按 recency+relevance。
- **Zep（Graphiti）**：时序知识图谱，边带 `valid_at`/`invalid_at` 双时间戳，自动失效过期事实——**"记忆老化"的工业级范本**。
- **Letta/MemGPT**：分页式记忆，core memory（常驻）vs archival memory（可召回）——对应 hot/cold 分层。
- **Generative Agents（Stanford）**：记忆流三因子检索 `score = α·recency + β·importance + γ·relevance`，recency 用指数衰减——**直接可移植到 Engram 的 `get_memory` 排序**。

### 2.4 业界最佳实践要点（公式级）

- **多因子价值分**：`value = w1·outcome + w2·engagement + w3·reuse(access) + w4·user_signal − w5·noise`，归一到 0-100。
- **时间衰减**：`decay_weight = exp(−λ·age_days)`，半衰期 `t½ = ln2/λ`（如 90 天半衰期 → λ≈0.0077）。
- **检索融合 RRF**：`score = Σ 1/(k + rank_i)`（k=60 经验值），融合 FTS 与向量两路排名——**Engram P2 上向量后启用**。
- **BM25**：FTS5 内置 `bm25(sessions_fts, w1, w2, …)` 可加字段权重，**无需向量即可立即改善排序**。
- **三层存储生命周期**：hot（全索引+全文）→ warm（索引+摘要，原文可选）→ cold（仅摘要+元数据，原文归档/丢弃）。

---

## 3. 升级方案

> 落地点标注 Swift 产品路径为权威；TS 仅在保留的回归测试/fixture 依赖时同步。

### 3.1 价值区分（pillar 1）

**目标**：把已存在的 `quality_score` 接进人用 GUI，并演进为可解释的高/中/低三档 + 用户可覆盖。

**方案设计**：
- **P0.5 第一步（接线，非造新）**：在 `EngramCoreRead/Session.swift` 读模型加 `qualityScore: Int` 字段，从已有 `sessions.quality_score` 读出；`SessionCard`/`SessionListView` 显示 band 角标。**前置核对**：`SessionSnapshotWriter.computeQualityScore`（:386）与 `StartupBackfills`（:1002）两处实现必须一致——先写一个 Swift 测试断言同输入同输出。
- **定档阈值**：先用脚本实测 `quality_score` 在真实库的分布（分位数），用 p33/p67 分位定 低/中/高，而非硬编码 33/67。
- **用户覆盖列**：幂等 ALTER 加 `value_override INTEGER DEFAULT NULL`（`addSessionColumnsIfNeeded` 模式，`EngramMigrations.swift:372`）；最终展示 band = `value_override ?? band(quality_score)`。
- **P1 演进多因子**：把 `session_files`/`session_tools`/`session_costs` 计数 + `access_count` + outcome 信号（有无 error-resolved、有无 git commit）并入 `computeQualityScore`，引入降分维度（探针/健康会话、纯报错、abort）。**bump `QUALITY_SCORE_VERSION` 触发回填**。

**落地点**：`SessionSnapshotWriter.swift`、`StartupBackfills.swift`、`EngramCoreRead/Session.swift`、`EngramMigrations.swift`、`SessionCard.swift`。
**验证**：Swift 测试断言两处 score 实现一致、band 阈值映射、override 优先级。
**优先级**：P0.5（接线）→ P1（多因子）。**工作量**：接线 0.5d；多因子 2-3d。**风险**：两处实现漂移导致 UI 抖动（已用一致性测试兜底）。

### 3.2 自动归档（pillar 2）

**目标**：低价值"过程性"会话自动降级到 cold，止住 FTS 膨胀与列表噪声，**默认只标记不删（影子模式）**。

**方案设计**：
- **状态机**：`lifecycle_state TEXT DEFAULT 'active'`，取值 `active`/`archived`/`purged`；幂等 ALTER 加 `archived_at`、`archive_reason`。**首版只实现 `active↔archived`**，`purged`（删原文）留到验证期后。
- **归档判据**（保守）：`quality_score < 低档阈值 AND age > N 天 AND access_count == 0 AND NOT favorited AND tier != 'premium'`。N 由 1.6 实测定，初值偏大（如 90d）。
- **影子模式**：归档**只置 `lifecycle_state='archived'` + 从默认列表/默认搜索过滤**，**不删 FTS 行、不删原文**。先观察 2-4 周命中是否合理，再考虑 cold 压缩。
- **致命回归点防护**：`runIndexingLoop → indexRecentSessions`（`EngramServiceRunner.swift:257`）与 `SessionSnapshotWriter` upsert 必须加 `WHERE lifecycle_state != 'archived'` 短路，否则源文件 mtime 变化会把归档会话重新索引回 active。**这是本项最高风险，需专门测试。**
- **救回路径**：当前 app/MCP 读路径纯只读；"取消归档"需经 `EngramServiceClient`/`ServiceWriterGate` 新增写命令（不可绕过单写者）。
- **cold 压缩（P2，可选）**：对确认无价值的 archived 会话，summarize-and-drop——保留摘要+元数据，删 FTS content 与原文引用，回收空间。**必须 dry-run + 用户确认 + 可导出备份**。

**落地点**：`EngramMigrations.swift`、`EngramServiceRunner.swift`（loop 短路 + 定时归档任务挂到 5min loop）、`SessionSnapshotWriter.swift`、`EngramServiceCommandHandler.swift`（archive/unarchive 写命令）、`EngramServiceReadProvider.swift`（默认过滤）、归档审阅 UI。
**验证**：Swift 测试——归档会话不被 reindex 回 active、默认列表过滤、unarchive 往返、dry-run 不删数据。
**优先级**：P1（影子归档）→ P2（cold 压缩）。**工作量**：影子模式 3-4d；cold 压缩 3d。**风险**：reindex 回流（专项测试）、误归档（影子模式 + 救回兜底）。

### 3.3 记忆老化（pillar 3）

**目标**：让 `get_memory`/insight 检索按"时间衰减 + 重要度 + 访问强化"排序，旧而无用的自然沉底。

**方案设计**：
- **session 与 insight 分两套，不混公式**。
- **access 强化前置（P0 列）**：`last_accessed_at`、`access_count` 加到 `sessions` 与 `insights`；打开会话/命中检索时 bump（经服务写路径）。
- **insight 检索排序**：`get_memory` 当前**零 ORDER BY**——先加 `ORDER BY importance DESC`（即时改善），再升级为 `score = α·exp(−λ·age) + β·(importance/10) + γ·relevance(FTS rank) + δ·log(1+access_count)`。λ 由半衰期定（默认 90d→λ≈0.0077）。
- **importance 衰减/强化**：访问时 `importance = min(10, importance + 1)`（强化）；后台周期对长期未访问 insight `importance = max(1, importance − 1)`（衰减）。**不物理删除 insight**，只降权。
- **session 老化**：喂入 3.1 的 `access_count` 作为价值正信号，旧且零访问者参与 3.2 归档判据。

**落地点**：`EngramMigrations.swift`、`insight-repo`/`MCPDatabase`（get_memory ORDER BY + 评分）、服务写路径（access bump）、`EngramServiceRunner`（衰减任务挂 loop）。
**验证**：Swift/TS 测试——评分排序、强化与衰减边界（封顶/封底）、access bump 原子性。
**优先级**：P0（access 列+bump）→ P1（get_memory 评分 + 强化/衰减）。**工作量**：列+bump 1d；评分 2d。**风险**：bump 写放大（批量/节流）、衰减误伤（只降权不删）。

### 3.4 人工检索升级（enabler 1）

**目标**：把"已为 AI 接好"的检索能力补给人，CJK 用户拿到真排序。

**方案设计**：
- **P0 高亮片段**：Service 读路径改用 `snippet(sessions_fts, …, '<mark>', '</mark>', '…', 32)`——**直接复制 `MCPDatabase.swift:977`**；同 PR 改 `SearchPageView.cleanSnippet` 保留 `<mark>`（强耦合，必须同改）。
- **P0 激活 Command Palette**：翻转 `showPalette` + 绑 ⌘K + 验证 split view/sheet 下可靠触发。
- **P1 BM25 排序**：拉丁路径改 `ORDER BY bm25(sessions_fts, w_title, w_content)` 加字段权重；**修掉聚合掉 rank 的 `GROUP BY` 粗排问题**。CJK 路径从纯 `start_time DESC` 改为 `bm25 + 时间加权`，给中文用户真相关性。可叠加 recency/quality boost：`final = bm25 + boost·exp(−λ·age) + boost2·quality_score/100`。
- **P1 faceting**：按 source/project/date/value band/lifecycle 过滤（复用现有 `FilterPills`）。
- **P1 鲁棒性**：移植 TS `isFtsSyntaxError` 重试；2 字符查询回退 LIKE；CJK 正则补假名/Hangul/Ext-B。
- **P2 语义/混合**：重新引入有运行时调用与测试覆盖的 sqlite-vec 支持 + 嵌入 → hybrid 用 RRF 融合（`k=60`）。**硬前置：sqlite-vec 落地**。

**落地点**：`EngramServiceReadProvider.swift`、`Database.swift`、`MainWindowView.swift`、`SearchPageView.swift`、`CommandPaletteView.swift`、新增 sqlite-vec runtime 支持(P2)。
**验证**：Swift 测试——snippet 含 mark、bm25 排序、CJK 排序非纯时间、facet 过滤、特殊字符不崩。
**优先级**：P0（高亮+palette）→ P1（BM25+facet+鲁棒）→ P2（向量）。**工作量**：P0 1d；P1 3-4d；P2 5d+。**风险**：cleanSnippet 漏改（同 PR）、bm25 权重需调。

### 3.5 解析/清洗/总结升级（enabler 2）

**目标**：止住工具输出信息损失，摘要结构化 + 有 provenance，写外部 LLM 前脱敏。

**方案设计**：
- **P0 脱敏（提级）**：把 `src/core/sanitizer.ts` 逻辑用 Swift 实现，在**写 FTS 前 + 调外部 LLM 前**应用；`ai_audit_log` 落库前对 request/response body 脱敏（密钥/token/邮箱/路径）。
- **P1 工具结果归一**：定义 `ToolResultNormalizer` 统一契约，让各 adapter 至少保留"结果摘要"（成功/失败、文件、错误首行、命令）——**不是全量保留原始 stdout**，而是有损但有信息的归一。优先修 `ClaudeCodeAdapter.formatToolResult` 的全丢弃。
- **P1 结构化摘要 + summary job**：加 `IndexJobKind.summary` 接入索引管道；摘要走 JSON schema（problem/approach/outcome/artifacts/decisions），存 provenance（`model`/`prompt_version`/`generated_at`）；渲染成卡片（借 ReadOut "Card IS answer"）。摘要 provider 不限 OpenAI。
- **P2 自动洞见抽取**：从 premium/高价值已完成会话抽取可复用 insight 写入 `insights`（当前只写表变可读可挖），喂入记忆层。

**落地点**：Swift sanitizer（新）、`EngramMigrations.swift`（ai_audit_log 脱敏/provenance 列）、adapter 层（`ClaudeCodeAdapter.swift` 等）、`IndexingEventTypes.swift`（job kind）、`SessionSnapshotWriter.swift`（summary job）、摘要 prompt/schema。
**验证**：Swift 测试——脱敏命中密钥模式、归一保留关键信息、summary job 入队、schema 解析、provenance 落库。
**优先级**：P0（脱敏）→ P1（归一+结构化摘要）→ P2（洞见抽取）。**工作量**：脱敏 1-2d；归一 3-4d（~15 adapter）；结构化摘要 3d。**风险**：adapter 归一回归面大（逐个测试 + fixture）。

### 3.6 数据模型与规模支撑（enabler 3）

**目标**：用实测数据驱动决策，加必要索引，支撑价值/归档/老化查询。

**方案设计**：
- **P0 实测**：脚本采 `PRAGMA page_count`、`dbstat` 各表字节、`quality_score` 分布、各 tier 会话数与 FTS 占比——**先量后裁**。
- **P0 引擎 pragma**：`mmap_size=256MB` + 调大 `cache_size`。
- **P1 索引**：`last_accessed_at`、`lifecycle_state`、`quality_score` 建索引（支撑排序/归档筛选免全表扫）。
- **P1 FTS 维护**：周期 `INSERT INTO sessions_fts(sessions_fts) VALUES('optimize')` 收 tombstone（不止启动一次）。
- **P2 cold 压缩**：见 3.2，summarize-and-drop 回收 FTS 体量。

**落地点**：诊断脚本、`Database.swift`(pragma)、`EngramMigrations.swift`(索引)、`IndexJobRunner.swift`/`FtsLifecycle.swift`(optimize)。
**验证**：实测前后读延迟、索引命中（EXPLAIN QUERY PLAN）、optimize 后体量。
**优先级**：P0（实测+pragma）→ P1（索引+optimize）→ P2（压缩）。**工作量**：实测 0.5d；pragma 0.5d；索引 1d。**风险**：低。

---

## 4. 实施路线图

| 阶段 | 工作项 | 依赖 | 工作量 | 价值 |
|------|--------|------|--------|------|
| **P0**（本周，零依赖可合） | ① 引擎 pragma（3.6）；② 激活 Command Palette+验证（3.4）；③ `last_accessed_at`/`access_count` 列+bump 埋点（3.3）；④ Service 读路径 `snippet()` 高亮+cleanSnippet 同改（3.4）；⑤ 观测表 retention prune + `ai_audit_log` 脱敏（3.5/3.6）；实测脚本（3.6） | 无 | ~4-5d | 立即改善人工检索可达性/可读性/延迟；埋点开始积累老化数据；堵隐私洞 |
| **P0.5** | 接 `quality_score` 到 GUI 读模型+band 角标（前置：两处实现一致性核对+分布实测定档）（3.1） | P0③实测 | ~1d | 人工"价值区分"可见，复用已有列 |
| **P1** | 多因子价值分+降分维度（3.1）；影子归档状态机+reindex 回流防护（3.2）；get_memory 评分+强化/衰减（3.3）；BM25 排序+CJK 真排序+facet+鲁棒性（3.4）；工具结果归一+结构化摘要+summary job（3.5）；索引+FTS optimize（3.6） | P0/P0.5 | ~3-4 周 | 三大支柱成型；检索/解析质变 |
| **P2** | sqlite-vec+hybrid RRF（3.4）；cold 压缩 summarize-and-drop（3.2）；自动洞见抽取（3.5） | sqlite-vec 落地 | ~3-4 周 | 语义检索；体量回收；记忆自生长 |

---

## 5. 风险与未决问题

1. **归档 reindex 回流**（最高技术风险）：5min loop + upsert 必须短路 `archived`，否则归档无效。需专项测试。
2. **误归档不可感知**：影子模式（只标记）+ 救回写路径 + 归档审阅 UI 三重兜底；cold 删原文前强制 dry-run+备份。
3. **quality_score 可信度**：两处实现一致性未核对前不得暴露给用户；阈值须实测分布而非硬编码。
4. **隐私**：`ai_audit_log` 明文 body 已是现存问题，P0 脱敏；写外部 LLM 前脱敏是合规底线。
5. **adapter 归一回归面**：~15 个 adapter 行为各异，逐个 fixture 测试，避免一刀切破坏现有解析。
6. **bump 写放大**：access 埋点高频写，需节流/批量，避免与单写者服务争锁。
7. **未决**：cold 压缩"丢原文"的用户接受度？是否需"导出后再删"？value band 三档还是五档？λ 半衰期默认值需用真实访问数据回测。
8. **TS/Swift 同步**：凡产品行为变更以 Swift 为准，TS 仅在保留回归测试依赖时同步，不双轨开发。
