# Engram 功能设计审计报告

**审计日期**: 2026-05-03
**审计范围**: 会话分层、噪声过滤、父子会话分组、Insight 系统、整体功能完整性
**审计文件**: `src/core/session-tier.ts`, `src/core/parent-detection.ts`, `src/core/indexer.ts`, `src/core/config.ts`, `src/core/sync.ts`, `src/core/chunker.ts`, `src/core/vector-store.ts`, `src/core/embeddings.ts`, `src/adapters/types.ts`, `src/tools/*` (19 个工具)

---

## 1. 会话分层（Session Tiering）设计审计

### 1.1 分层逻辑总览

当前 4 层设计（`src/core/session-tier.ts`）：

| 层级 | 条件 | 处理方式 |
|------|------|----------|
| `skip` | preamble-only / probe / agent_role / subagents 路径 / ≤1 条消息 | 仅 DB 存储，无 FTS/Embedding |
| `lite` | 无 AI 回复（assistantCount=0 且 toolCount=0）/ 噪声摘要（/usage、title 生成提示） | +FTS 索引 |
| `normal` | 满足基本会话标准 | +FTS +Embedding |
| `premium` | ≥20 条消息 / ≥10 条且有项目 / 持续 >30 分钟 | +FTS +Embedding +自动摘要 |

### 1.2 发现的问题

#### 🟡 中等 — "无回复"判断时机不一致

**问题描述**: `computeTier()` 中检查 `assistantCount === 0` 使用 `!== undefined` 做严格判断，这意味着当 `assistantCount` 未传入（undefined）时不会触发 lite 分层。但 `SyncEngine.normalizeRemoteSnapshot()` 调用 `computeTier()` 时并未传入 `assistantCount` 和 `toolCount`（同步的快照数据中无这些字段），导致同步会话可能被错误地分到 `normal` 层。

**影响**: 来自远程同步的无回复会话可能被过度索引（生成 embedding），浪费计算资源。

**建议**: 在 `computeTier()` 入口处，当 `assistantCount === undefined` 时通过 `messageCount - userMessageCount` 推断 assistant count，或者在同步快照中携带这些字段。

```typescript
// 修复建议
const effectiveAssistantCount = input.assistantCount ??
  Math.max(0, input.messageCount - (input.userMessageCount ?? 0));
```

#### 🟡 中等 — "lite" 层过于宽泛，既包含噪声也包含有价值的沉默会话

**问题描述**: `lite` 层将以下两类截然不同的会话混为一谈：
1. **噪声会话**: 摘要匹配 `/usage` 或 `"Generate a short, clear title"`
2. **无回复会话**: 用户发了消息但 AI 没回复（可能是网络问题、上下文过长等）

无回复会话可能包含重要的用户意图信息，值得 FTS 索引但也可能值得 embedding。而当前的 `isTierHidden()` 在 `hide-skip` 模式下不会过滤 `lite`，在 `hide-noise` 模式下才过滤——用户实际上无法区分这两种 lite。

**建议**: 考虑将 `lite` 拆分为 `lite-noise`（纯粹噪声）和 `lite-silent`（无回复），或在 UI 层增加对 lite 会话的子分类展示。

#### 🟢 建议 — Premium 层的 30 分钟阈值可能过低

**问题描述**: 持续 30 分钟即升级为 premium。考虑到很多 AI 会话是后台运行的（用户开始一个问题然后去做别的事），30 分钟的阈值会将很多被动长会话升级到 premium 层，导致 auto-summary 资源消耗。

**建议**: 可考虑引入"活跃时间"而非"挂钟时间"的概念，或者将阈值提升到 60 分钟。也可以将 `durationMinutes` 结合 `messageCount` 做交叉验证（30 分钟但只有 3 条消息 = 可能是挂起的会话）。

#### 🟢 建议 — 缺少对 `summary` 为空时的噪声检测

**问题描述**: `computeTier()` 第 54 行仅在 `summary` 存在时才检查噪声模式。但某些噪声会话（如空的 probe 消息）可能没有 summary，此时会 fallback 到 `normal` 层。

**影响**: 少量无 summary 的噪声会话会被过度索引。

---

## 2. 噪声问题审计

### 2.1 噪声过滤机制分析

当前噪声过滤有两层：

1. **分层过滤**（`buildTierFilter()` / `isTierHidden()`）：
   - `hide-skip`：隐藏 `tier = 'skip'`
   - `hide-noise`：隐藏 `tier IN ('skip', 'lite')`
   - `all`：不过滤

2. **UI 层额外过滤**（`config.ts`）：
   - `hideUsageSessions`：隐藏 /usage 会话
   - `hideEmptySessions`：隐藏摘要 <10 字符且 ≤3 条消息
   - `hideAutoSummary`：隐藏 auto-summary 泄露

### 2.2 发现的问题

#### 🔴 严重 — 噪声过滤配置迁移不一致

**问题描述**: `readFileSettings()` 中有噪声迁移逻辑：当 `noiseFilter` 未设置时，根据旧的布尔开关推断。但这个推断逻辑有问题：

```typescript
if (migrated.noiseFilter === undefined) {
  const hasExplicitFalse =
    migrated.hideUsageSessions === false ||
    migrated.hideEmptySessions === false ||
    migrated.hideAutoSummary === false;
  migrated.noiseFilter = hasExplicitFalse ? 'all' : 'hide-skip';
}
```

如果用户从未设置过任何噪声相关配置（全新安装），`hasExplicitFalse` 为 false，默认为 `hide-skip`——这是合理的。但如果用户只设置了 `hideUsageSessions = true` 而没有设置其他两个（显式开启了一个过滤），迁移后仍然是 `hide-skip`，丢失了细粒度控制。

**影响**: 用户升级后可能发现噪声变多了（原来 `hideEmptySessions` 默认 true 的细粒度过滤被合并为一个粗糙的 `hide-skip`）。

**建议**: 将 `noiseFilter` 的迁移逻辑做得更精确，或者直接废弃旧的布尔开关，在 UI 中暴露 3 级选择器。

#### 🟡 中等 — 最可能的噪声源缺乏统计分析能力

**问题描述**: 通过代码分析，以下来源最可能是噪声源：

1. **Codex/Claude Code 的 probe 会话**: 发送 "ping"、"What is 2+2?" 等探测消息的会话
2. **title 生成泄露**: `"Generate a short, clear title"` 出现在会话摘要中
3. **/usage 检查**: 工具检查用量的瞬时会话
4. **Preamble-only 会话**: 仅有系统提示词的空壳会话

但当前系统缺少噪声来源的统计和报告能力。用户无法看到"你的 2000 个会话中，有 500 个是 Codex 的 probe 会话"这类信息。

**建议**: 在 `stats` 工具中增加 `group_by: 'tier'` 维度，并增加一个 `noise_breakdown` 工具或统计项，帮助用户了解噪声分布。

#### 🟡 中等 — `buildTierFilter()` 不过滤 orphan 会话

**问题描述**: `buildTierFilter()` 和 `buildOrphanFilter()` 是分开应用的。在 `applyFilters()` 中，`buildOrphanFilter()` 会隐藏 orphan 会话，但只有在非 `includeOrphans` 模式下。然而 `buildTierFilter()` 独立于 orphan 状态——一个 orphan 的 `skip` 会话和一个正常的 `skip` 会话被同等对待。

**影响**: 如果用户删除了某些项目文件夹，对应的会话会先变成 `suspect`，30 天后变成 `confirmed` orphan。在这 30 天内，这些会话仍然占用搜索结果的位次。

**建议**: 在 `buildTierFilter()` 中考虑将 `suspect` orphan 视为更低优先级，或提供独立的 orphan 过滤选项给用户。

#### 🟢 建议 — 噪声模式列表过于简短

**问题描述**: `NOISE_PATTERNS` 只有两个模式（`/usage` 和 `"Generate a short, clear title"`）。实际上还可能有其他噪声模式，如工具初始化消息、认证流程等。

**建议**: 将 `NOISE_PATTERNS` 扩展为可配置的列表，或者从 `PREAMBLE_MARKERS` 和 `PROBE_MESSAGES` 中提取更多模式。

---

## 3. 父子会话分组审计

### 3.1 检测层次总览

| 层级 | 方法 | 来源 | 置信度 |
|------|------|------|--------|
| Layer 1 (path) | 解析 `/subagents/` 路径提取 parent ID | Codex | 确定性 |
| Layer 1b (originator) | `session_meta.originator === "Claude Code"` | Codex | 确定性 |
| Layer 1c (sidecar) | `*.engram.json` 侧车文件 | Gemini | 确定性 |
| Layer 2 (heuristic) | dispatch 模式 + 时间/CWD 评分 | gemini-cli, codex | 启发式 |
| Layer 3 (manual) | HTTP API 手动确认/取消 | 所有 | 用户确认 |

### 3.2 发现的问题

#### 🔴 严重 — Layer 2 候选人评分仅考虑 claude-code 来源

**问题描述**: `backfillSuggestedParents()` 中，候选人来源限制为 `source IN ('gemini-cli', 'codex')`，但父会话（candidates）也限制为 `source IN ('claude-code', 'claude')`：

```sql
SELECT id, start_time, end_time, project, cwd FROM sessions
WHERE source IN ('claude-code', 'claude')
  AND start_time <= ?
  AND start_time >= datetime(?, '-24 hours')
  AND parent_session_id IS NULL
```

这意味着：
1. **只有 gemini-cli 和 codex 的子会话会被检测** — 如果未来有新的 agent 来源（如 Cursor 的 agent 模式），Layer 2 不会自动覆盖。
2. **只有 claude-code 的会话会被选为父会话** — 但实际上 pi、cursor 等工具也可能作为"父"分发子 agent 任务。
3. **`backfillSuggestedParents()` 的 LIMIT 500** — 每次启动只处理 500 个，大型历史库可能需要多次启动才能完成。

**影响**: 遗漏大量跨工具的父子关系。

**建议**:
1. 将候选人和父候选人的来源扩展，或使用排除法（排除已知的 "子" 来源）。
2. 将 500 的 limit 提高，或改为分批处理直到完成。

#### 🟡 中等 — `scoreCandidate()` 中的 `endedBeforeAgent` 软惩罚可能过于宽松

**问题描述**: 当父会话在子会话启动前结束时，系统给了 4 小时的宽限期。这个设计的注释说"parent can dispatch agents hours after its last message if it was still open"，但实际上如果父会话的 `end_time` 是最后一条消息的时间（而非用户关闭的时间），4 小时的窗口可能导致跨会话的误匹配。

例如：用户在上午 10 点用 Claude Code 完成一个会话，下午 2 点用 Codex 开始一个子 agent。如果 Claude Code 会话在 10:05 结束，gap 是 3h55m，在 4h 窗口内，可能被误匹配为父子关系。

**影响**: 误匹配概率随时间 gap 增加而增加，4h 的阈值可能过于宽松。

**建议**:
1. 考虑将 4h 窗口缩短到 2h。
2. 增加 "连续性" 信号：如果父会话最后一条消息是 `user` 角色（说明用户在等待 AI 回复），则更大可能是活跃的；如果最后一条是 `assistant`（AI 已经回复完），则更可能已结束。

#### 🟡 中等 — `pickBestCandidate()` 不拒绝模糊匹配

**问题描述**: 注释说"When the top two candidates score within 5% of each other, the result is considered ambiguous. We still return the highest-scoring candidate because a possibly-wrong suggestion is more useful than no suggestion."

这意味着系统永远不会因为模糊而返回 null——总是返回最高分的候选人。在真实场景中，如果用户有多个几乎同时运行的 Claude Code 会话（如在不同终端中），系统可能会频繁误匹配。

**影响**: 用户看到的 `suggested_parent_id` 可能经常是错的，降低对自动建议的信任。

**建议**: 增加一个可配置的置信度阈值（如 0.15），低于此阈值时不返回建议。或者在 UI 层显示置信度分数，让用户自行判断。

#### 🟡 中等 — Orphan 处理的 30 天宽限期缺乏渐进通知

**问题描述**: `detectOrphans()` 使用 `suspect → confirmed` 的状态机，宽限期 30 天。但在这 30 天内，用户不会收到任何通知。如果某个项目被意外删除，用户可能在 30 天后才发现相关会话数据已被标记为 orphan。

**建议**: 在 `suspect` 阶段即通过 daemon 事件或 UI 提示用户，而非等到 `confirmed` 后静默处理。

#### 🟢 建议 — `DETECTION_VERSION` 重置逻辑缺少审计日志

**问题描述**: `resetStaleDetections()` 在检测版本升级时会重置大量 `link_checked_at`，触发重新评估。但这个过程没有审计日志记录重置了多少会话、从哪个版本升级到哪个版本。

**建议**: 在 metadata 表中记录每次版本升级的 timestamp 和 affected count。

#### 🟢 建议 — `backfillCodexOriginator()` 的 16KB 读取限制

**问题描述**: `backfillCodexOriginator()` 只读取文件的前 16KB 来查找 `originator` 字段。如果 Codex 的 session_meta 行超过 16KB（不太可能但理论上可能），会漏检。

**影响**: 极低概率，可以忽略。

---

## 4. Insight 系统审计

### 4.1 系统架构

Insight 系统采用双层存储：
1. **`insights` 表**（文本 + FTS）: 始终可用，支持关键词搜索
2. **`memory_insights` 表 + `vec_insights`**（向量）: 需要 sqlite-vec + embedding provider

降级路径：save_insight → 无 embedding → 仅文本存储 → 关键词搜索 fallback → 有 embedding 后由 daemon 回填。

### 4.2 发现的问题

#### 🔴 严重 — `save_insight` 的语义去重阈值可能导致误报

**问题描述**: `save_insight.ts` 中语义去重使用 `DEDUP_THRESHOLD = 0.85`，但在 SQLite vec 中使用 L2 距离转换 cosine similarity 的公式是：

```typescript
const cosineSim = 1 - (dist * dist) / 2;
```

这个近似公式**仅在向量已经 L2 归一化时才成立**。`embeddings.ts` 中 Ollama 和 Transformers.js 的路径有归一化处理，但 **OpenAI 的路径没有做 L2 归一化**：

```typescript
// OpenAI path — 直接返回 Float32Array，没有归一化
return new Float32Array(res.data[0].embedding);
```

如果用户使用 OpenAI 作为 embedding provider，L2 距离和 cosine similarity 之间的转换不准确，0.85 的阈值可能产生误报（标记为重复但实际不是）。

**影响**: 使用 OpenAI embedding 时，可能误判新 insight 为重复而跳过保存。

**建议**: 在 `createEmbeddingClient()` 的 OpenAI 路径中增加 L2 归一化，或在去重时根据 provider 使用不同的转换公式。

#### 🟡 中等 — 文本去重过于简单

**问题描述**: `findDuplicateInsight()` 使用 `normalizeForDedup()` 做精确匹配（转小写 + 合并空格），然后遍历最近 200 条 insights 比较。这意味着：
1. 语义相似但措辞不同的 insight 不会被文本去重捕获
2. 仅检查同 wing 下的最近 200 条——如果 insights 总量很大，可能会漏检更早的重复

**建议**: 在有 embedding 支持时，优先使用语义去重；文本去重仅作为 fallback。

#### 🟡 中等 — `get_memory` 的 FTS fallback 不支持语义排序

**问题描述**: 当没有 embedding provider 时，`get_memory` 使用 FTS 关键词搜索。但 FTS 返回的是 `distance: 0`（无意义的占位值），且没有按重要性排序的逻辑。此外，当 FTS 也失败时，它会 fallback 到 `listInsightsByWing(undefined, 10)`——返回最近 10 条，与查询完全无关。

**影响**: 用户在没有 embedding provider 的情况下，`get_memory` 的结果质量很低，可能返回不相关的 insights。

**建议**:
1. FTS fallback 时按 `importance DESC` 排序
2. 全量列表 fallback 时限制为 "最近 N 天内的 insights"，而非全局最近 10 条

#### 🟡 中等 — Insight 无过期机制

**问题描述**: Insights 没有过期时间或衰减机制。一个 6 个月前保存的 "当前项目使用 React" 可能已经不适用了，但仍然会出现在搜索结果中。`importance` 字段是静态的（默认 5），不会随时间变化。

**建议**:
1. 引入 `created_at` 的时间衰减权重
2. 或允许用户标记 insight 为 "已过期"
3. 或在 search/get_memory 中增加时间权重

#### 🟡 中等 — Insight 的 `wing`/`room` 分类系统使用率可能很低

**问题描述**: `wing` 和 `room` 是可选的分类维度，但没有默认值推断逻辑。用户需要主动传入这些参数。大多数用户可能不会填写，导致大量 insights 的 `wing` 和 `room` 为 null。

在 `searchInsightsFts()` 中，当 wing 为 null 时做的是全局搜索，这没问题。但 `listInsightsByWing()` 在 wing 为 undefined 时返回全局最近条目——这些分类字段的语义不够清晰。

**建议**: 考虑自动从 `source_session_id` 推断 `wing`（使用会话的 project 名），减少用户负担。

#### 🟢 建议 — `deleteInsight` 的软删除不删除 FTS 条目

**问题描述**: `vector-store.ts` 的 `deleteInsight()` 使用软删除（设置 `deleted_at`），而 `insight-repo.ts` 的 `deleteInsightText()` 使用硬删除（DELETE FROM）。`save_insight.ts` 的 `_deleteInsight()` 调用两个删除方法。

但 `reconcileInsights()` 中只处理 `memory_insights` 的软删除，不处理 `insights` 表的 FTS 条目。如果 `deleteInsightText()` 删除了 `insights` 行但 FTS 条目残留（可能因为事务失败），FTS 搜索可能返回已删除 insight 的内容。

**建议**: 在 `reconcileInsights()` 中增加对 `insights_fts` 孤儿条目的检查。

---

## 5. 整体功能完整性审计

### 5.1 工具清单总览

共 19 个 MCP 工具：

| 类别 | 工具 | 功能 |
|------|------|------|
| 会话检索 | `list_sessions`, `get_session`, `search`, `get_context`, `project_timeline` | 浏览和搜索历史会话 |
| 会话操作 | `export`, `link_sessions`, `handoff`, `generate_summary` | 导出、链接、交接、生成摘要 |
| Insight | `save_insight`, `get_memory` | 保存和检索主动记忆 |
| 成本分析 | `get_costs`, `get_insights`, `stats`, `tool_analytics`, `file_activity` | 成本和使用分析 |
| 实时监控 | `live_sessions` | 当前活跃会话 |
| 项目管理 | `project_move`, `project_archive`, `project_review`, `project_undo`, `project_list_migrations`, `project_recover`, `project_move_batch` | 项目迁移/归档 |
| 配置 | `lint_config` | 配置检查 |

### 5.2 发现的问题

#### 🔴 严重 — 缺少 `delete_insight` 工具

**问题描述**: 有 `save_insight` 但没有对应的 `delete_insight` MCP 工具。底层函数 `_deleteInsight()` 和 `deleteInsightText()` 都已实现，但未暴露给 MCP 客户端。用户保存了错误的 insight 后无法通过工具删除。

**建议**: 新增 `delete_insight` MCP 工具，调用已有的底层删除函数。

#### 🔴 严重 — 缺少 `delete_session` / `hide_session` 工具

**问题描述**: `session-repo.ts` 有 `deleteSession()` 函数，但没有 MCP 工具暴露它。`session_local_state` 表有 `hidden_at` 字段，但没有工具来设置它。用户无法通过 AI 助手隐藏或删除不需要的会话。

**影响**: 用户只能在 Swift UI 中手动管理会话，AI 助手无法帮助清理噪声数据。

**建议**: 新增 `hide_session` 工具（设置 `hidden_at`），并考虑是否需要 `delete_session`（危险操作，需要确认参数）。

#### 🟡 中等 — `get_session` 工具不支持按 tier 过滤

**问题描述**: `get_session` 工具通过 ID 获取单个会话。但 `list_sessions` 工具没有暴露 `tier` 过滤参数。用户无法直接列出所有 `premium` 会话或所有 `lite` 会话。

在 `session-repo.ts` 的 `applyFilters()` 中，`agents` 参数只支持 `'hide'` / `'only'` / undefined，不支持按具体 tier 过滤。

**建议**: 在 `list_sessions` 中增加 `tier` 过滤参数。

#### 🟡 中等 — `search` 工具的 agents/tools 过滤未暴露给 schema

**问题描述**: `handleSearch()` 接受 `agents: 'hide'` 和 `tools: 'hide'` 参数，但 `searchTool.inputSchema` 中没有声明这些参数。AI 客户端不知道这些过滤器的存在。

**建议**: 在 `searchTool.inputSchema.properties` 中添加 `agents` 和 `tools` 参数声明。

#### 🟡 中等 — `get_context` 缺少对子会话的聚合展示

**问题描述**: `get_context` 列出项目的历史会话，但不展示父子关系。如果一个项目有 10 个父会话，每个有 3 个子 agent，get_context 只显示 10 个父会话，子 agent 的信息完全丢失。但子 agent 可能包含重要的执行细节。

**建议**: 在 `get_context` 中可选地展开子会话的摘要（如 `include_children: true`），或者在结果中标注"此会话有 N 个子会话"。

#### 🟡 中等 — `handoff` 工具读取最后用户消息的性能问题

**问题描述**: `handleHandoff()` 通过 `getLastUserMessage()` 读取整个会话的消息流来找到最后一条用户消息。对于大型会话（如 200+ 条消息），这会触发完整的文件 I/O，而实际上只需读取最后 N 条消息。

**建议**: 使用 `streamMessages()` 的 `opts.offset/limit` 参数反向读取（如果支持），或在 SessionInfo 中缓存最后一条用户消息。

#### 🟡 中等 — 分块策略过于简单

**问题描述**: `chunker.ts` 使用 800 字符/200 重叠的滑动窗口，以消息边界为优先分割。但：
1. 800 字符对于代码块来说太短——一个函数定义可能跨多个 chunk
2. `[role] content` 的格式前缀占用了宝贵的字符预算
3. 没有对代码和自然语言使用不同的分割策略

**影响**: 代码片段在 chunk 中被截断，影响语义搜索的召回质量。

**建议**:
1. 增加 chunk 大小到 1500-2000 字符
2. 对包含代码块的消息保持完整性（识别 ``` 标记）
3. 考虑将 `role` 标记移到 metadata 而非占用 chunk 空间

#### 🟡 中等 — 同步引擎缺少冲突解决策略

**问题描述**: `sync.ts` 的 `SyncEngine` 从对等节点拉取会话并使用 `writeAuthoritativeSnapshot()` 写入。但没有明确的冲突解决策略——如果本地和远程都有同一个会话的修改版本，`snapshotHash` 的比较会决定是否更新，但 `syncVersion` 的单调递增可能不适用于多主写入场景。

当前实现中，`normalizeRemoteSnapshot()` 的 `syncVersion` 使用 `raw.syncVersion ?? raw.messageCount`，这意味着不同节点的 version 计数可能不一致。

**建议**: 在文档中明确说明同步是"最后写入胜出"还是"版本号胜出"，并增加对网络分区场景的处理。

#### 🟡 中等 — `live_sessions` 工具在 MCP 模式下不可用

**问题描述**: `handleLiveSessions()` 在 monitor 为 null 时返回空结果和 note。但 MCP server 模式下 monitor 确实为 null（只有 daemon 模式有 monitor）。这意味着在 Codex 中使用 Engram 时，`live_sessions` 工具完全无用。

**建议**: 在 MCP server 模式下不注册 `live_sessions` 工具，或在 MCP 模式下使用文件系统 watcher 的数据提供近似结果。

#### 🟢 建议 — 缺少批量导出功能

**问题描述**: `export` 工具只能导出单个会话。用户可能需要导出某个项目的所有会话或某个时间段的所有会话。

**建议**: 新增 `export_project` 或在 `export` 中支持 `project`/`since` 参数进行批量导出。

#### 🟢 建议 — `lint_config` 与 `get_insights` 功能重叠

**问题描述**: `lint_config` 检查配置健康度，`get_insights` 提供成本优化建议。两者都包含在 `get_context` 的 environment 部分。但对于直接调用的用户来说，需要知道该调用哪个。

**建议**: 考虑将 `lint_config` 的结果合并到 `get_insights` 中，减少工具数量。

#### 🟢 建议 — 工具描述语言不一致

**问题描述**: 部分工具描述使用中文（`list_sessions`："列出 AI 编程助手的历史会话"），部分使用英文（`search`："Full-text and semantic search across all session content"）。这会影响 AI 助手选择工具的准确性。

**建议**: 统一使用英文描述（考虑到 MCP 客户端可能使用不同语言的 AI），或在 description 中同时包含中英文。

---

## 6. 综合评估与优先级建议

### 高优先级（应尽快修复）

| 编号 | 问题 | 严重度 | 工作量 |
|------|------|--------|--------|
| 5.2.1 | 缺少 `delete_insight` 工具 | 🔴 | 1-2h |
| 5.2.2 | 缺少 `hide_session` 工具 | 🔴 | 2-3h |
| 4.2.1 | OpenAI embedding 缺少 L2 归一化导致去重误判 | 🔴 | 30min |
| 3.2.1 | Layer 2 父子检测来源限制过窄 | 🔴 | 2-4h |

### 中优先级（下个迭代处理）

| 编号 | 问题 | 严重度 | 工作量 |
|------|------|--------|--------|
| 1.2.1 | 同步会话的 assistantCount 缺失导致 tier 判断不准 | 🟡 | 1h |
| 1.2.2 | lite 层混合噪声和有价值的沉默会话 | 🟡 | 2-3h |
| 2.2.1 | 噪声过滤配置迁移不一致 | 🟡 | 1-2h |
| 3.2.2 | 父子评分 4h 窗口过于宽松 | 🟡 | 1h |
| 4.2.3 | get_memory 的 FTS fallback 质量低 | 🟡 | 1-2h |
| 5.2.4 | search 工具隐藏参数未暴露 | 🟡 | 30min |
| 5.2.7 | chunker 策略过于简单 | 🟡 | 3-4h |

### 低优先级（有时间再处理）

| 编号 | 问题 | 严重度 | 工作量 |
|------|------|--------|--------|
| 1.2.3 | Premium 30 分钟阈值可能过低 | 🟢 | 1h |
| 1.2.4 | 无 summary 时噪声检测缺失 | 🟢 | 30min |
| 2.2.4 | 噪声模式列表过短 | 🟢 | 30min |
| 3.2.5 | orphan 30 天宽限期无通知 | 🟢 | 2-3h |
| 4.2.4 | Insight 无过期机制 | 🟢 | 3-5h |
| 4.2.5 | wing/room 分类使用率低 | 🟢 | 1-2h |
| 5.2.8 | 同步引擎冲突解决策略不明确 | 🟢 | 文档工作 |
| 5.2.10 | 缺少批量导出功能 | 🟢 | 2-3h |
| 5.2.12 | 工具描述语言不一致 | 🟢 | 1h |

---

## 7. 架构层面的优点

审计过程中也发现了以下设计亮点，值得肯定：

1. **Bootstrap 工厂模式** (`bootstrap.ts`): `createMCPDeps()` 和 `createDaemonDeps()` 清晰地分离了两种入口的依赖初始化，避免了循环依赖。

2. **降级设计**: Insight 系统的 text-only → embedding 双层存储 + daemon 回填策略非常健壮，确保了在没有 embedding provider 时系统仍然可用。

3. **Preamble 检测器**: `isPreambleContent()` 使用多级策略（标记匹配 + 正则 + 结构化行比例），对各种 preamble 格式的覆盖很全面。

4. **项目迁移管道**: `project_move` 系列工具的事务性设计（dry_run → 执行 → undo → recover）非常成熟，补偿事务的设计减少了用户风险。

5. **SQLite-vec 的模型感知**: `vector-store.ts` 在 dimension 或 model 变化时自动重建向量表，避免了混合不同 embedding 空间的问题。

6. **Process lifecycle 的时序保护**: `setupProcessLifecycle()` 必须在 `server.connect()` 之后调用的设计，以及 `idleTimeoutMs: 0` 的明确注释，都体现了对边界条件的深入理解。

---

*报告完成。建议团队在下次迭代中优先处理 🔴 严重级别问题，特别是 `delete_insight` 工具的缺失和 OpenAI embedding 的 L2 归一化问题。*
