# GitHub Copilot CLI — 会话格式参考

> 本文档为英文权威版 copilot.md 的中文阅读副本；若有出入以英文版为准。

Last researched: 2026-07-02 (Engram provider audit recheck)
Current-state verification: 2026-07-02 (live store + adapter/DB diff)

> **适用范围。** 本文档描述的是 **GitHub Copilot CLI / 编码代理**
> （`producer: "copilot-agent"`，`client_name: github/cli`，二进制 `copilot-agent`），
> 它在 `~/.copilot/session-state/` 下为每个会话写入一个目录。这
> **不是** VS Code Copilot Chat 扩展（后者将聊天存储在 VS Code 的 SQLite
> `state.vscdb` 中，由 Engram 的 `VSCodeAdapter` 解析）。Engram 的 `CopilotAdapter`
> **仅**针对 CLI 代理。关于这个品牌名称为何具有误导性，参见
> [§15 谱系](#15-谱系陷阱版本漂移与边界情况)。

---

## 证据基础

| 基础 | 详情 |
|---|---|
| **磁盘上的实时存储** | `~/.copilot/session-state/` —— 本机有 **470 个会话目录**。其中 **227** 个带有 `events.jsonl`；全部 470 个都带有 `workspace.yaml` + `checkpoints/`。此外还有存储级的 `~/.copilot/session-store.db`（5.1 MB SQLite，`schema_version = 4`）。事件类型普查是对多个大型 `events.jsonl` 文件聚合统计得到的；深入采样了一个 8643 事件的会话和一个 1990 事件的会话（`67b3717b-…`）。 |
| **仓库 fixture** | `/Users/bing/-Code-/engram/tests/fixtures/copilot/session-1/`（合成数据，3 行 `events.jsonl` + 4 键 `workspace.yaml`）；`/Users/bing/-Code-/engram/tests/fixtures/adapter-parity/copilot/success.expected.json`（黄金 parity）。 |
| **适配器（已编码的知识）** | Swift 产品：`macos/Shared/EngramCore/Adapters/Sources/CopilotAdapter.swift`。TS 参考：`src/adapters/copilot.ts`。测试：`tests/adapters/copilot.test.ts`。 |

**方法：** 我首先阅读了两个适配器，以了解权威的根目录与存储技术，然后对实时存储进行采样并与 fixture 交叉核对。**发生冲突时，以真实数据为准。** 主要冲突在于：实时存储远比任一适配器所消费的内容丰富得多（约 28 种事件类型、按消息的 tokens/model/reasoning、内容丰富的 `workspace.yaml`、一个结构完整的并行 SQLite 镜像），而适配器只消费 4 种事件类型 + 4 字段的 token 子集。两个适配器都解析的是一个严格、有损的子集。未发现格式层面的矛盾；所有差异都是覆盖缺口，已在文中逐处标注。

**当前 Engram 状态：** 2026-07-02 只读 smoke 列出并解析了 227/227 个
event locator，stream 出 20,868 条消息（946 user + 19,922 assistant），把
shutdown usage 挂到 208 条 assistant 消息上，parser/stream count mismatch 为 0。
实时 Engram DB 有 227 条 `copilot` 行和 227 条 `file_index_state` 行
（`ok`，schema v1），当前 id 缺失 0、DB-only id 0。字段新鲜度仍有
8 条历史行落后：6 条 summary-only 行保留旧 YAML 引号，2 条保留旧
count/end-time 快照。

---

## 1. 概览与 TL;DR

**是什么。** 每个 Copilot CLI 会话是一个**以 UUID 命名的目录**，其中包含一个**仅追加的 JSONL 事件日志**（`events.jsonl`）、一个扁平的 **`workspace.yaml`** 元数据文件，以及一个 **Markdown 检查点存储**（`checkpoints/`）。Copilot CLI *还*维护一个并行的、存储级的 **SQLite 镜像**（`~/.copilot/session-store.db`），其中包含配对好的回合 + 结构化检查点 + git 引用 + FTS5 —— 但 **Engram 完全忽略该 DB**，只读取每个会话的文件。

**在哪里。** `~/.copilot/session-state/<uuid>/`（默认；可通过适配器构造函数配置）。SQLite 镜像位于上一级目录 `~/.copilot/session-store.db`。

**如何保存。** `events.jsonl` 是**实时、仅追加**写入的（每行一个 JSON 对象，从不重写）。`workspace.yaml` 是一个小型元数据文件，随 `updated_at` 推进而**被重写**。每次检查点会追加一个新的编号 `.md` 正文 + 在 `index.md` 表中追加一个新行。

**心智模型。** Copilot CLI 是一个 **JSONL 代理 CLI**，在磁盘存储*家族*上与 **OpenAI Codex CLI** 同属一类（带类型的 `type`+`data`+`timestamp` 事件，`session.start` / `session.shutdown` 信封）—— 尽管共享 "Copilot" 品牌，它并**不属于** VS Code/Cursor 的 SQLite-`.vscdb` 家族。参见 [§15](#15-谱系陷阱版本漂移与边界情况)。

**Engram 的视角（有损）。** Engram 只呈现 `session.start`、`user.message`、`assistant.message` 和 `session.shutdown`（用于 token 合计）。所有工具 I/O、hook、子代理、skill、reasoning、压缩、按消息的 tokens/model，以及 SQLite 镜像都被**丢弃**。在当前 470 目录的存储中，Engram 呈现 **227 个会话**（那些带有真实事件日志的）；其余 243 个无事件目录（空的检查点模板）被静默跳过。

```
                          ~/.copilot/
                          ├── session-store.db  ← parallel SQLite mirror (Engram IGNORES)
                          │     sessions / turns / checkpoints / session_refs / FTS5
                          └── session-state/
                                └── <uuid>/          ← ONE DIR PER SESSION
   Engram reads ───────────────►  events.jsonl       (PRIMARY: append-only JSONL log)
   Engram reads (metadata) ─────► workspace.yaml      (flat key: value metadata)
   Engram fallback (no events) ─► checkpoints/index.md + NNN-<slug>.md
   Engram IGNORES ──────────────► session.db  files/  research/  rewind-snapshots/  plan.md  inuse.<pid>.lock

   Engram parse priority (per dir):
     1. events.jsonl present?          → parse as JSONL events session   (227/470)
     2. else checkpoints/index.md has  → parse as checkpoint-only session  (0/470 live)
        ≥1 valid table row?
     3. else                           → skip silently                    (243/470)
```

**所用证据基础：** 实时存储（470 个目录，227 个带事件）+ 仓库 fixture（1 个合成会话 + 黄金 parity JSON）+ 两个适配器。实时数据具有权威性。

---

## 2. 磁盘布局与文件命名

| 属性 | 取值 | 来源 |
|---|---|---|
| 根目录（默认） | `~/.copilot/session-state/` | `CopilotAdapter.swift:11`、`copilot.ts:25` |
| 存储技术（Engram 读取的内容） | **每个会话一个目录**，每个目录含仅追加的 **JSONL**（`events.jsonl`）+ 扁平 **YAML**（`workspace.yaml`）+ **Markdown** 检查点。读取路径中**没有 SQLite/leveldb**。 | 适配器 |
| 会话目录命名 | 小写 **UUID v4**（`8-4-4-4-12` 十六进制），例如 `00f0af74-c7a0-440c-812a-29bad956c597` | `ls ~/.copilot/session-state/` |
| 权限 | 会话目录 `0700`；`events.jsonl`/`workspace.yaml` `0600`（私有） | `ls -la` |
| 时间戳 | ISO-8601 UTC，毫秒精度 + `Z`，例如 `2026-06-20T04:00:26.804Z` | `events.jsonl` |
| 会话 id 身份 | 目录名 == `workspace.yaml id:` == `session.start.data.sessionId` | 实时 |

**命名语法。**
- 会话目录：`<uuid-v4>/`
- 事件日志：`events.jsonl`（固定名称）
- 元数据：`workspace.yaml`（固定名称）
- 检查点索引：`checkpoints/index.md`（固定名称）
- 检查点正文：`checkpoints/NNN-<kebab-slug-of-title>.md`（3 位零填充编号 + slug，例如 `001-designing-nvr-playback-feature.md`）
- 粘贴文件：`files/paste-<epoch-ms>.txt`
- 回退备份：`rewind-snapshots/backups/<16-hex-hash>-<epoch-ms>`
- 存活锁：`inuse.<pid>.lock`（内容 = 裸的所属 PID）

**每会话子项名称频率**（在全部 470 个目录上聚合统计，已实时核实）：

| 子项 | 类型 | 计数 / 470 | Engram 使用？ | 含义 |
|---|---|---|---|---|
| `workspace.yaml` | 文件 | 470 | **是**（元数据） | 会话元数据：id、cwd、repo、branch、时间戳、summary |
| `checkpoints/` | 目录 | 470 | **是**（回退 + 索引） | 检查点历史（`index.md` + 编号 `.md` 正文） |
| `files/` | 目录 | 470（大多为空） | 否 | 用户粘贴/附加的负载（`paste-<epochms>.txt`） |
| `research/` | 目录 | 470（观测到为空） | 否 | Web/研究产物（本存储中为空） |
| `events.jsonl` | 文件 | **227** | **是**（主日志） | 仅追加的事件流 —— 即转录文本 |
| `session.db` | 文件 | 155 | 否 | 每会话 SQLite：`todos`、`todo_deps`、`inbox_entries` |
| `rewind-snapshots/` | 目录 | 32 | 否 | "回退/撤销" 功能的文件编辑备份 |
| `plan.md` | 文件 | 15 | 否 | 代理的自由形式工作计划 |
| `inuse.<pid>.lock` | 文件 | 瞬态（4 个存活） | 否 | 存活锁；内容 = 所属 PID |
| `.DS_Store` | 文件 | 1 | 否 | macOS Finder 杂物 |

**关键事实：** 在 470 个目录中，仅 **227 个带有 `events.jsonl`**。其余 **243** 个只有一个空的 `checkpoints/index.md` 模板（零数据行），会被 Engram **静默跳过**（参见 [§9 发现](#9-engram-如何发现并枚举会话)）。

**`~/.copilot/` 下被 Engram 忽略的兄弟级顶层状态**（已实时核实）：
`session-store.db`（+`-shm`/`-wal`）、`config.json`、`settings.json`、`mcp-config.json`、
`command-history-state.json`、`copilot-instructions.md`，以及目录 `ide/`、
`installed-plugins/`、`logs/`、`marketplace-cache/`、`pkg/`、`plugin-data/`。

**目录树示例**（已脱敏；三种真实会话形态）：

```
~/.copilot/session-state/
├── 00f0af74-...-29bad956c597/        # full events session
│   ├── events.jsonl                  # append-only event log (up to ~38 MB)
│   ├── workspace.yaml                # metadata
│   ├── session.db                    # todos / inbox (SQLite, ~36 KB)
│   ├── checkpoints/
│   │   └── index.md                  # checkpoint table (may be empty)
│   ├── files/                        # (empty here)
│   ├── research/                     # (empty)
│   └── rewind-snapshots/
│       ├── index.json                # {version, snapshots, filePathMap}
│       └── backups/
│           └── 67cc2383df63f241-1780277667725   # <hash>-<epochms> file copy
├── 6b25f406-...-25c61ff0817c/        # checkpoint-rich session
│   ├── events.jsonl
│   ├── workspace.yaml
│   ├── checkpoints/
│   │   ├── index.md                  # 6 numbered rows
│   │   ├── 001-designing-nvr-playback-feature.md
│   │   ├── 002-implementing-nvr-playback-feat.md
│   │   └── ... 006-...
│   └── files/
│       └── paste-1772580434059.txt   # paste-<epochms>.txt
└── 00c41951-...-796ccbb46351/        # SKIPPED: no events.jsonl, empty index.md template
    ├── workspace.yaml                # cwd: /, created_at == updated_at
    ├── checkpoints/index.md          # header only → 0 rows → not enumerated
    ├── files/
    └── research/
```

---

## 3. 文件生命周期与生成

| 方面 | 行为 | 证据 |
|---|---|---|
| 每会话 | 会话开始时创建一个 UUID 目录 | 目录名 == `workspace.yaml id:` |
| 事件日志 | **仅追加的 JSONL**，实时写入；从不原地重写 | 单调递增的时间戳；shutdown 中的 `eventsFileSizeBytes`；多 MB 文件 |
| `workspace.yaml` | **被重写**（小型元数据文件）；`updated_at` 推进 | `created_at` 与 `updated_at` 不同 |
| 检查点 | 每次检查点追加新的编号正文 `.md` + 在 `index.md` 表中追加新行；索引表头恒定 | `001..006-*.md` 递增 |
| 恢复（Resume） | 重新打开已有目录；追加新事件；`alreadyInUse` / `inuse.<pid>.lock` 守护并发。一个专门的 `session.resume` 事件记录重新打开 | `session.resume.data.{resumeTime,eventCount,...}`、锁文件 |
| Token 用量 | 仅在 `session.shutdown` 时定稿（按模型的 `modelMetrics`）；运行中的会话没有合计值 | 文件末尾有一条 `session.shutdown` 记录 |
| 滚动（Rollover） | **无** —— 没有基于大小的文件轮转；`events.jsonl` 无界增长（见过 38 MB） | 每会话单文件 |
| 压缩（Compaction） | 流内 `session.compaction_start` / `session.compaction_complete`；压缩与某个检查点关联（`checkpointNumber`、`checkpointPath`、`summaryContent`） | 实时事件 |
| 模型切换 | 通过 `session.model_change` 在流内捕获；`modelMetrics` 中出现多个 model id | 一个会话同时有 `claude-haiku-4.5`+`claude-opus-4.6`+`claude-sonnet-4.6` |
| 归档 / GC | 未观测到归档；目录持久存在（最早可追溯到 3 月）。**没有*自动* TTL/清理**，但 Copilot 提供显式的用户触发保留命令：`/session prune --older-than DAYS`、`/session delete [ID]`、`/session delete-all [--yes]`、`/session cleanup`（仅本地会话；GitHub.com 上的同步副本是独立的）（[CLI reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference)） | mtime 跨越 3 月—6 月 |
| 存储技术 | JSONL + 扁平 YAML + Markdown（读取路径）。SQLite（`session.db`、`session-store.db`）存在，但**不在**读取路径上 | 实时 |

**DB 与文件。** 存在两个 SQLite 存储（每会话的 `session.db`、存储级的 `session-store.db`）—— 参见 [§12](#12-sqlite--db-内部细节)。两者都不被 Engram 读取；文件系统上的 JSONL/YAML/Markdown 才是适配器的真相来源。

---

## 4. 记录 / 行分类（`events.jsonl` 事件类型）

每一行是一个 JSON 对象。当前实时数据有两种信封键集合：111,216 条事件使用基础
5 键（`type`、`id`、`parentId`、`timestamp`、`data`），14,629 条事件在同一组键上额外带
`agentId`。`agentId` 信封出现在子代理作用域内的 assistant/tool/hook/skill/error
事件上；Engram 当前忽略它，因此不改变解析后的消息计数。下面是实时观测到的**完整事件类型词汇表**（约 28 种不同类型；计数来自采样的大型会话，用以传达相对体量）。**Engram** 列标记了适配器解析的那 4 种类型。

| `type` | Engram | `data` 层承载的内容 / 含义 |
|---|---|---|
| `session.start` | **是**（cwd/startTime 回退） | 会话启动记录：sessionId、version、producer、copilotVersion、startTime、context{cwd[,branch,gitRoot,repository]}、alreadyInUse?、remoteSteerable?、contextTier?、selectedModel?、reasoningEffort?（末尾键随版本可变） |
| `session.shutdown` | **是**（token 合计） | 最终记录：modelMetrics（按模型用量）、conversation/system/tool token 细分、codeChanges、合计 |
| `user.message` | **是**（`role:user`） | 用户提示：content、transformedContent、interactionId、attachments |
| `assistant.message` | **是**（`role:assistant`） | 助手回复块：content、messageId、model、outputTokens、toolRequests[]、turnId、interactionId、reasoningText?、reasoningOpaque?、encryptedContent?、phase?、parentToolCallId?（子代理嵌套） |
| `assistant.turn_start` / `assistant.turn_end` | 否 | 回合边界：turnId、interactionId |
| `tool.execution_start` / `tool.execution_complete` | 否 | 工具调用：toolCallId、toolName、arguments、result/error、success、model、toolTelemetry、parentToolCallId? |
| `hook.start` / `hook.end` | 否 | Hook 生命周期：hookInvocationId、hookType、input/success |
| `skill.invoked` | 否 | Skill 调用：name、path、content（完整 SKILL.md）、description、source、trigger |
| `subagent.started` / `subagent.completed` | 否 | 派发的子代理生命周期：agentName、agentDisplayName、agentDescription、model、durationMs、totalTokens、totalToolCalls、toolCallId |
| `session.model_change` | 否 | 会话中途模型切换：newModel（例如 `"auto"`） |
| `session.compaction_start` / `session.compaction_complete` | 否 | 上下文压缩；complete 携带 checkpointNumber、checkpointPath、summaryContent、preCompactionTokens、compactionTokensUsed |
| `session.context_changed` | 否 | 完整 git 上下文：repository、branch、gitRoot、cwd、baseCommit、headCommit、hostType |
| `session.resume` | 否 | 重新打开：resumeTime、eventCount、selectedModel、reasoningEffort、context、alreadyInUse |
| `session.info` | 否 | 信息性：infoType、message |
| `session.task_complete` | 否 | success、summary |
| `session.plan_changed` | 否 | operation |
| `session.mode_changed` | 否 | newMode、previousMode |
| `session.workspace_file_changed` | 否 | operation、path |
| `session.error` | 否 | errorType、message、statusCode、providerCallId、stack |
| `session.warning` | 否 | warningType、message |
| `system.message` | 否 | role、content |
| `system.notification` | 否 | kind{type,...}（带判别符的对象）、content |
| `abort` | 否 | reason |

> **覆盖缺口（标注）。** Engram 解析约 28 种类型中的 **4 种**。约 85% 的事件（所有工具 I/O、reasoning、子代理、skill、压缩、hook、代码变更统计、按消息 tokens）被丢弃。在 Engram 的转录文本中，Copilot 的工具调用、结果与 reasoning **不会**被呈现。参见 [§14](#14-engram-映射) 的数据丢失清单。

---

## 5. 共享信封 / 元数据字段

### 5.1 `events.jsonl` 行信封（第 1 层）

已核实：100% 的采样行恰好携带这 5 个键。

| 字段 | 类型 | 含义 | 可选 | 示例 |
|---|---|---|---|---|
| `type` | string | 事件判别符（见 [§4](#4-记录--行分类eventsjsonl-事件类型)） | 否 | `"assistant.message"` |
| `id` | string (uuid) | 此事件的唯一 id | 否 | `"c72d6d32-7036-473a-9bab-662a973560db"` |
| `parentId` | string\|null | **紧邻的前一个**事件的 id（线性发射链，**非**语义回复指针）；在 `session.start` 上为 `null` | 否（可空） | `"0ad3552e-06e1-4db5-b613-17396bd709b8"` |
| `timestamp` | string (ISO-8601) | 事件时间，毫秒精度，`Z` | 否 | `"2026-04-05T13:47:43.481Z"` |
| `data` | object | 类型特定的负载（第 2 层，[§6](#6-消息与内容-schema)） | 否 | `{...}` |

**`parentId` 语义（已核实）。** 它构成一个*按发射顺序的单向链表* —— 每个事件指向上一个事件的 `id`，与类型无关（`assistant.message` → `assistant.turn_start` → `hook.end` → `hook.start` → `user.message` → `session.start`）。它**不是**用户↔助手的回复指针。两个适配器都完全忽略 `id` 与 `parentId`。

### 5.2 `workspace.yaml` 元数据（完整超集，已实时核实）

扁平 YAML（`key: value`）。两个适配器都使用**朴素的逐行解析器**（不是真正的 YAML 解析器）：Swift `readWorkspace` 在每行的第一个 `:` 处分割，要求键匹配 `^\w+$`，并剥离匹配到的外层引号（`CopilotAdapter.swift:363-389`）；TS `readWorkspace` 使用 `/^(\w+):\s*(.+)$/`，也会剥离匹配到的外层引号（`copilot.ts:364-378`、`stripYamlQuotes:438-446`）。两者都能挺过 ISO 时间戳中的冒号；嵌套/多行 YAML 会被静默丢弃。频率是在全部 470 个文件上的精确计数。

| 键 | 频率 /470 | 类型 | 含义 | Engram 使用 |
|---|---:|---|---|---|
| `id` | 470 | string(uuid) | 会话 UUID（覆盖目录名） | **是** → `Session.id` |
| `cwd` | 470 | string(path) | 工作目录 | **是** → `cwd`（回退：`session.start.context.cwd`） |
| `created_at` | 470 | ISO-8601 | 会话开始 | **是** → `startTime` |
| `updated_at` | 470 | ISO-8601 | 最后活动 | **是** → `endTime` 种子 |
| `summary_count` | 470 | int | summary/压缩的数量 | 否 |
| `git_root` | 224 | string(path) | 仓库根 | 否 |
| `branch` | 224 | string | Git 分支 | 否 |
| `repository` | 171 | string | `owner/repo` | 否 |
| `summary` | 159 | string | 预先生成的会话摘要 | **是** → `summary`（第 1 优先级） |
| `host_type` | 153 | string | Forge 类型（例如 `github`） | 否 |
| `user_named` | 146 | bool | `name` 是否由用户设置？ | 否 |
| `name` | 138 | string | 显示**标题**（常为 AI 生成） | **否** —— 见 [§14](#14-engram-映射) 数据丢失 |
| `client_name` | 19 | string | 客户端（`github/cli`） | 否 |
| `remote_steerable` | 3 | bool | 远程控制标志 | 否 |
| `mc_task_id` | 3 | string(uuid) | Mission-control 任务关联 | 否 |
| `mc_session_id` | 3 | string(uuid) | Mission-control 会话关联 | 否 |
| `mc_last_event_id` | 3 | string(uuid) | Mission-control 末事件关联 | 否 |

> **对 Dim 报告的更正。** `summary` 并**非** "罕见/缺失" —— 它出现在 **159/470** 个实时文件中，且 Engram 优先使用它而非首条用户文本回退。在深入采样的会话中，`summary` + `summary_count` 都存在。

---

## 6. 消息与内容 schema

`data` 是第 2 层；嵌套的数组/对象（例如 `toolRequests[]`）是第 3 层。下面是已核实的实时键集负载（已脱敏 —— 键逐字保留，值已编辑）。

### 6.1 `session.start.data`

| 字段 | 类型 | 含义 | 示例 |
|---|---|---|---|
| `sessionId` | string(uuid) | 会话 id（镜像目录名） | `"00f0af74-…"` |
| `version` | int | 事件 schema 版本 | `1` |
| `producer` | string | 发射方 id | `"copilot-agent"` |
| `copilotVersion` | string | CLI 版本 | `"1.0.65"` |
| `startTime` | string(ISO) | 开始时间（Engram 回退的开始时间） | `"2026-06-20T04:00:25.530Z"` |
| `contextTier` | string\|null | 上下文窗口层级。**可选/随版本可变 —— 实时罕见（4/60 文件）** | `null` |
| `alreadyInUse` | bool | 已恢复/已锁定。**可选/随版本可变（51/60 文件；在最大的实时会话中缺失）** | `false` |
| `remoteSteerable` | bool | 已启用远程控制。**可选/随版本可变（42/60 文件；在最大的实时会话中缺失）** | `false` |
| `selectedModel` | string | （较新版本）该会话用户选择的 model id。**可选/部分版本（5/60 文件）** | `"<model-id>"` |
| `reasoningEffort` | string | （较新版本）reasoning-effort 设置。**可选/部分版本（4/60 文件）** | `"<effort>"` |
| `context` | object | 仓库上下文。**实时：形态随版本可变** —— 当前 Copilot 版本通常将**丰富的 git 上下文内联携带**（最大的实时会话：`["branch","cwd","gitRoot","repository"]`），而较旧/精简版本只携带 `{cwd}`。更完整的集合（`gitRoot, branch, headCommit, repository, hostType, repositoryHost, baseCommit`）也可能通过 `session.context_changed` 到达。Engram 只读取 `context.cwd`。 | `{"branch":"…","cwd":"<path>","gitRoot":"<path>","repository":"<owner>/<repo>"}` |

```json
// Common current shape (largest live session): rich git context inline,
// NO contextTier/alreadyInUse/remoteSteerable keys
{"type":"session.start","timestamp":"2026-06-20T04:00:25.530Z","id":"<uuid>","parentId":null,
 "data":{"sessionId":"<uuid>","producer":"copilot-agent","version":1,"copilotVersion":"1.0.63",
         "startTime":"2026-06-20T04:00:25.530Z",
         "context":{"branch":"<branch>","cwd":"<path>","gitRoot":"<path>","repository":"<owner>/<repo>"}}}

// Minimal/older shape: only {cwd}, plus the version-variable flags
{"type":"session.start","timestamp":"2026-06-20T04:00:25.530Z","id":"<uuid>","parentId":null,
 "data":{"sessionId":"<uuid>","producer":"copilot-agent","version":1,"copilotVersion":"1.0.63",
         "startTime":"2026-06-20T04:00:25.530Z","contextTier":null,"alreadyInUse":false,
         "remoteSteerable":false,"context":{"cwd":"<path>"}}}
```

### 6.2 `user.message.data`

| 字段 | 类型 | 含义 | 可选 |
|---|---|---|---|
| `content` | string | 用户文本（**Engram 读取此项**） | 否 |
| `transformedContent` | string\|null | 实际发送的提示，含注入的 `<current_datetime>` / `<system_reminder>` 块 | 可空 |
| `interactionId` | string(uuid) | 把一次用户→助手交换分组 | 否 |
| `attachments` | array | 附加引用；元素 = `{displayName, path, type}` | 通常为 `[]` |
| `supportedNativeDocumentMimeTypes` | array | （部分版本）支持的附件 MIME 类型 | 可选 |
| `parentAgentTaskId` | string\|null | （部分版本）父代理任务 id | 可选 |

```json
{"type":"user.message","timestamp":"…","id":"<uuid>","parentId":"<uuid>",
 "data":{"content":"<REDACTED>","transformedContent":null,"attachments":[],
         "interactionId":"<uuid>"}}
```

### 6.3 `assistant.message.data`（同时是工具调用的**来源** + reasoning 的承载者）

| 字段 | 类型 | 含义 | 可选 |
|---|---|---|---|
| `content` | string | 助手文本（**Engram 读取此项**） | 否（在仅工具回合时常为**空**） |
| `messageId` | string | 提供方消息 id | 否 |
| `model` | string | 此消息使用的模型（例如 `gpt-5.5`、`claude-sonnet-4.6`） | 部分版本存在 |
| `interactionId` | string(uuid) | 匹配触发它的 user.message | 否 |
| `outputTokens` | int | **按消息**的输出 token 计数 | 否 |
| `toolRequests` | array | 此消息发出的工具调用（第 3 层，[§7](#7-工具调用与结果)） | 否（可能为 `[]`） |
| `reasoningText` | string | 思维链文本 | **可选**（实时约 ⅓ 的消息：采样 59/261） |
| `reasoningOpaque` | string | 不透明/加密的 reasoning blob | 可选（与 `reasoningText` 共现） |
| `requestId` / `serviceRequestId` / `apiCallId` | string | 提供方请求关联 id | 可选 |
| `turnId` | string(uuid) | 将此消息链接到其 `assistant.turn_start`（其 `data` = `{interactionId, turnId}`）—— 把一个助手回合的所有块分组 | 可选/随版本而定（实时会话 00f0af74 中 1247 个 assistant.message 全部带有） |
| `encryptedContent` | string | 不透明加密消息正文；**与**明文 `content` **共现**（不是替代） | 可选/随版本而定（00f0af74 中 874/1247） |
| `phase` | string | 该回合的流式阶段标记 | 可选/随版本而定（00f0af74 中 134/1247） |
| `parentToolCallId` | string | 当助手消息**在子代理 / 嵌套工具上下文内**发出时存在；链接到启动它的工具调用 | 可选/随版本而定（子代理密集的实时会话 51835c08 中 1839/2827） |

> **全部四项**（`turnId`、`encryptedContent`、`phase`、`parentToolCallId`）都**被 Engram 丢弃** —— 解析器只读取 `data.content`（`MessageParser.swift:235`、`CopilotAdapter.swift:210-224`）。此行集仅用于说明磁盘上的完整性；映射不受影响。

```json
{"type":"assistant.message","timestamp":"…","id":"<uuid>","parentId":"<uuid>",
 "data":{"messageId":"<uuid>","model":"claude-sonnet-4.6","content":"<REDACTED>",
         "interactionId":"<uuid>","turnId":"<uuid>","outputTokens":643,"phase":"<REDACTED>",
         "requestId":"<uuid>","serviceRequestId":"<uuid>","apiCallId":"<uuid>",
         "reasoningText":"<REDACTED>","reasoningOpaque":"<REDACTED>","encryptedContent":"<REDACTED>",
         "parentToolCallId":"toolu_…",
         "toolRequests":[{"toolCallId":"toolu_…","name":"…","arguments":{…},"type":"function"}]}}
```

> **空内容的助手消息（已实时核实）。** 相当大的一部分 —— **⅓ 到约 ½，视会话而定** —— 的 `assistant.message` 事件其 `content` 为空（仅工具调用的回合）。一个采样会话：261 个事件中只有 175 个内容非空（86 个为空 ≈ ⅓）。一个更大的实时会话（51835c08）更糟：**1445 个空 / 2827 个总计 ≈ 51%**。Engram 把**全部**计为助手消息 → `assistantMessageCount` 被夸大，且转录文本会显示空白的助手行。参见 [§15](#15-谱系陷阱版本漂移与边界情况)。

### 6.4 检查点正文内容（`NNN-<slug>.md`）

带分节的 XML 标签 Markdown，含 6 个分节（已实时核实），与 SQLite `checkpoints` 列一一对应（[§12](#12-sqlite--db-内部细节)）：

```
<overview> … </overview>
<history> … </history>
<work_done> … </work_done>
<technical_details> … </technical_details>
<important_files> … </important_files>
<next_steps> … </next_steps>
```

当 Engram 走检查点回退时，每个条目会成为一条 `role: system` 消息：
`"Checkpoint N: <title>\n\n<body>"`，正文截断到 **4000 字符**
（`CopilotAdapter.swift:5,358`；`copilot.ts:20,353`）。

---

## 7. 工具调用与结果

> **对 Engram 的转录输出而言 N/A** —— Copilot 的工具调用存在于磁盘上，但适配器**完全丢弃它们**（`toolMessageCount` 硬编码为 `0`）。这里记录是为了完整性，因为磁盘上的链接关系很丰富。

连接键是 **`toolCallId`**（**不是**信封的 `id`）。链条：
`assistant.message.data.toolRequests[].toolCallId` → `tool.execution_start.data.toolCallId`
→ `tool.execution_complete.data.toolCallId`。

### 7.1 `assistant.message.data.toolRequests[]`（第 3 层）

| 字段 | 类型 | 含义 | 可选 |
|---|---|---|---|
| `toolCallId` | string | **连接键**（`toolu_…` Anthropic 风格或 `call_…` OpenAI 风格） | 否 |
| `name` | string | 工具名称 | 否 |
| `arguments` | object | 工具参数（形态因工具而异） | 否 |
| `type` | string | 请求类型（例如 `"function"`） | 否 |
| `intentionSummary` | string | 人类可读的意图 | 可选 |
| `mcpServerName` | string | MCP 服务器（仅 MCP 工具） | 可选 |
| `toolTitle` | string | 显示标题 | 可选 |

### 7.2 `tool.execution_start.data`

| 字段 | 类型 | 含义 |
|---|---|---|
| `toolCallId` | string | 链接到请求 |
| `toolName` | string | 工具名称 |
| `arguments` | object | 已解析的参数 |
| `parentToolCallId` | string | 用于嵌套/子代理发起的工具调用时存在（已实时核实） |
| `mcpServerName` / `mcpToolName` | string | 仅 MCP 工具 |

### 7.3 `tool.execution_complete.data`

| 字段 | 类型 | 含义 |
|---|---|---|
| `toolCallId` | string | 链接到 start/request |
| `success` | bool | 结果 |
| `model` | string | 发起它的模型（例如 `"claude-opus-4.6"`） |
| `interactionId` | string | 交换 id |
| `result` | object\|null | 成功时为 `{content, detailedContent}`（均为字符串） |
| `error` | object | `success=false` 时为 `{code, message}`（取代 `result`） |
| `parentToolCallId` | string | 用于嵌套工具调用时存在（已实时核实） |
| `toolTelemetry` | object | `{metrics{responseTokenLimit,resultForLlmLength,resultLength}, properties{command,fileExtension,inputs,options,resolvedPathAgainstCwd,viewType}, restrictedProperties?}` 或 `{}` |

```json
{"type":"tool.execution_complete","data":{"toolCallId":"toolu_0142…","success":true,
  "model":"claude-opus-4.6","interactionId":"<uuid>",
  "result":{"content":"<REDACTED>","detailedContent":"<REDACTED>"},
  "toolTelemetry":{"metrics":{"responseTokenLimit":0,"resultForLlmLength":0,"resultLength":0},
                   "properties":{"command":"<REDACTED>","viewType":"…"}}}}
```

---

## 8. Reasoning / thinking

**存储于磁盘；被 Engram 丢弃。** `assistant.message.data` 携带两个 reasoning 字段（已实时核实，约 ⅓ 的消息）：

| 字段 | 类型 | 含义 |
|---|---|---|
| `reasoningText` | string | 人类可读的思维链文本 |
| `reasoningOpaque` | string | 不透明/加密的 reasoning blob（格式未解码；已确认是与 `reasoningText` 共现的字符串） |

此外，`session.shutdown.data.modelMetrics[<model>].usage.reasoningTokens`
按模型记录 reasoning-token 计数（实时 `gpt-5.5`：179832）。

Engram **既不**呈现 reasoning 文本，**也不**呈现 `reasoningTokens` —— `message(from:)`
只读取 `data.content`（`CopilotAdapter.swift:210-224`），且用量映射中没有
`reasoningTokens` 槽位（[§9 token 用量](#9-token-用量与成本)）。

---

## 9. Token 用量与成本

Token 合计仅在 `session.shutdown` 时定稿。Engram 对按模型的 `usage` 块求和，并将聚合值附加到**最后一条助手消息**上。

### 9.1 `session.shutdown.data`（完整，已实时核实）

| 字段 | 类型 | 含义 |
|---|---|---|
| `shutdownType` | string | 如何结束（例如 `"routine"`） |
| `sessionStartTime` | int (epoch ms) | 开始 |
| `currentModel` | string | 最后使用的模型 |
| `currentTokens` | int | 当前上下文 token 计数 |
| `conversationTokens` | int | 对话 token 计数 |
| `systemTokens` | int | 系统提示 token 计数 |
| `toolDefinitionsTokens` | int | 工具定义 token 计数 |
| `totalApiDurationMs` | int | 累计 API 时间 |
| `totalPremiumRequests` | int | 高级请求计数 |
| `totalNanoAiu` | number | （部分版本）AIU 用量指标 |
| `tokenDetails` | object | （部分版本）`{input,cache_read,output,cache_write}`，各为 `{tokenCount}` |
| `codeChanges` | object | `{linesAdded:int, linesRemoved:int, filesModified:[paths]}` |
| `modelMetrics` | object | 以 **model id** 为键 → `{requests:{count,cost}, usage:{…}, totalNanoAiu?, tokenDetails?}` |
| `eventsFileSizeBytes` | int | （部分版本）`events.jsonl` 的最终大小 |

### 9.2 `modelMetrics[<model>].usage`（Engram 求和的那个块）

| 字段 | 类型 | Engram 映射到 | Swift | TS |
|---|---|---|---|---|
| `inputTokens` | int | `inputTokens` | `CopilotAdapter.swift:254` | `copilot.ts:391` |
| `outputTokens` | int | `outputTokens` | `:255` | `:392` |
| `cacheReadTokens` | int | `cacheReadTokens` | `:256` | `:393` |
| `cacheWriteTokens` | int | `cacheCreationTokens`（**已重命名**） | `:257` | `:394-396` |
| `reasoningTokens` | int | **丢弃**（`TokenUsage` 中无此字段） | — | — |

**推导。** 两个适配器都遍历 `modelMetrics` 中的**所有**模型，对 4 个被映射字段求和，且当全部为零时 `mergeUsage`/`shutdownUsage` 不做任何操作（`CopilotAdapter.swift:261-267`；`copilot.ts:414-422`）。合计值被附加到**最后一条助手消息**上（`CopilotAdapter.swift:228-234`；`copilot.ts:184-191`）。按消息的 `outputTokens` 与按模型的拆分**不**被保留 —— 粒度是最终助手回合上的一个聚合值。已由 `tests/adapters/copilot.test.ts:53-95` 核实。

```json
{"type":"session.shutdown","data":{"shutdownType":"routine","currentModel":"claude-opus-4.6",
  "conversationTokens":60168,"systemTokens":7640,"toolDefinitionsTokens":19409,
  "totalApiDurationMs":560974,"totalPremiumRequests":27,
  "codeChanges":{"linesAdded":67,"linesRemoved":4,"filesModified":["<path1>","<path2>"]},
  "modelMetrics":{
    "claude-opus-4.6":{"requests":{"count":62,"cost":27},
      "usage":{"inputTokens":3749137,"outputTokens":27465,
               "cacheReadTokens":3433631,"cacheWriteTokens":0,"reasoningTokens":179832}},
    "claude-haiku-4.5":{"requests":{…},"usage":{…}},
    "claude-sonnet-4.6":{"requests":{…},"usage":{…}}}}}
```

---

## 10. 子代理 / 父子 / 派发

> **对 Engram 的父子检测而言 N/A** —— 磁盘上 Copilot CLI **确实**派发子代理（`subagent.started` / `subagent.completed` 事件），但这些**全都不**进入 Engram 的代理分组。适配器硬编码 `parentSessionId = nil` 与 `suggestedParentId = nil`（`CopilotAdapter.swift:120-121`；TS 两者都不发射）。因此每个 Copilot CLI 会话在 Engram 中都是**顶层**的。Copilot **没有** Gemini 风格的 `.engram.json` sidecar，**也没有**路径/originator 链接。

磁盘上的子代理链接（信息性，已丢弃）：

| 事件 | `data` 字段 |
|---|---|
| `subagent.started` | `{agentName, agentDisplayName, agentDescription, toolCallId}` |
| `subagent.completed` | `{agentName, agentDisplayName, model, durationMs, totalTokens, totalToolCalls, toolCallId}` |

`toolCallId` 将子代理链接到启动它的工具调用；子代理内部的嵌套工具调用携带 `parentToolCallId`。每会话的 `session.db` `inbox_entries` 表（[§12](#12-sqlite--db-内部细节)）是代理间消息收件箱（`recipient_session_id`、`sender_id`、`sender_type`）—— 同样不被 Engram 使用。

---

## 11. 摘要 / 压缩

磁盘上存在两种摘要机制：

1. **`workspace.yaml summary:`** —— 预先生成的会话摘要（实时 159/470）。**Engram 使用它**作为第一优先级的 `summary`（`CopilotAdapter.swift:110`；`copilot.ts:129`），回退为首条用户消息的前 200 字符。
2. **流内压缩** —— `session.compaction_start` / `session.compaction_complete` 事件。`complete.data` = `{checkpointNumber, checkpointPath, summaryContent, preCompactionTokens, compactionTokensUsed, preCompactionMessagesLength, requestId, success}`，将一次压缩与一个检查点文件关联。**Engram 忽略这两个事件。**
3. **检查点**（[§5/§6.4](#64-检查点正文内容nnn-slugmd)）是会话状态的结构化摘要；Engram 仅在 `events.jsonl` 缺失时将其用作**回退**（实时从未触发 —— 参见 [§9 发现](#9-engram-如何发现并枚举会话)）。

`workspace.yaml summary_count` 记录 summary/压缩的数量（全部 470 个实时文件都有取值；采样到的全部为 `0`）。

---

## 12. SQLite / DB 内部细节

Copilot CLI 维护**两个** SQLite 存储。**Engram 两者都不读取** —— 这里记录是为了完整性，因为它们是 JSONL/Markdown 数据的结构完整镜像。

### 12.1 `~/.copilot/session-store.db` —— 存储级镜像（`schema_version = 4`）

WAL 模式 SQLite（+`-shm`/`-wal`）。实时行计数：sessions=140、turns=241、checkpoints=9、session_refs=27、session_files=0、forge_trajectory_events=0、dynamic_context_items=0。**行计数滞后于文件系统**（140 个会话 vs 470 个目录）—— 它是一个派生/近期活动缓存，**不是**真相来源。

```sql
CREATE TABLE schema_version (version INTEGER NOT NULL);          -- value = 4

CREATE TABLE sessions (
  id TEXT PRIMARY KEY, cwd TEXT, repository TEXT, host_type TEXT,
  branch TEXT, summary TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now')));

CREATE TABLE turns (                          -- ALREADY-PAIRED user↔assistant transcript
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL REFERENCES sessions(id),
  turn_index INTEGER NOT NULL,
  user_message TEXT, assistant_response TEXT,
  timestamp TEXT DEFAULT (datetime('now')),
  UNIQUE(session_id, turn_index));

CREATE TABLE checkpoints (                     -- structured form of the NNN-<slug>.md section tags
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL REFERENCES sessions(id),
  checkpoint_number INTEGER NOT NULL,
  title TEXT, overview TEXT, history TEXT, work_done TEXT,
  technical_details TEXT, important_files TEXT, next_steps TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  UNIQUE(session_id, checkpoint_number));

CREATE TABLE session_files (                    -- file touched per session/tool (0 rows live)
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL REFERENCES sessions(id),
  file_path TEXT NOT NULL, tool_name TEXT, turn_index INTEGER,
  first_seen_at TEXT DEFAULT (datetime('now')),
  UNIQUE(session_id, file_path));

CREATE TABLE session_refs (                     -- git refs: ref_type observed ∈ {commit, pr}; format also supports 'issue'
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL REFERENCES sessions(id),
  ref_type TEXT NOT NULL, ref_value TEXT NOT NULL, turn_index INTEGER,
  created_at TEXT DEFAULT (datetime('now')),
  UNIQUE(session_id, ref_type, ref_value));

CREATE TABLE forge_trajectory_events (          -- tool trajectory (0 rows live)
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL REFERENCES sessions(id),
  tool_call_id TEXT, turn_index INTEGER, event_type TEXT NOT NULL,
  command TEXT, output TEXT, exit_code INTEGER,
  event_key TEXT, event_value TEXT,
  created_at TEXT DEFAULT (datetime('now')));

CREATE TABLE dynamic_context_items (
  repository TEXT NOT NULL, branch TEXT NOT NULL, src TEXT NOT NULL,
  name TEXT NOT NULL, description TEXT NOT NULL DEFAULT '',
  content TEXT NOT NULL DEFAULT '',
  read_count INTEGER NOT NULL DEFAULT 0, count INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (repository, branch, src, name));

CREATE VIRTUAL TABLE search_index USING fts5(   -- FTS5 over content
  content, session_id UNINDEXED, source_type UNINDEXED, source_id UNINDEXED);
-- + shadow tables search_index_{data,idx,content,docsize,config}
-- Indexes: idx_sessions_repo, idx_sessions_cwd, idx_session_files_path,
--          idx_session_refs_type_value, idx_turns_session, idx_checkpoints_session
```

> `turns` 表是比 `events.jsonl` **更干净**的用户↔助手转录（已配对，没有空的仅工具行），而 `checkpoints` 列是 `.md` 分节标签的结构化形态。Engram 本可以索引它来取代降级的检查点 Markdown 回退，但目前没有这么做 —— 参见 [§15](#15-谱系陷阱版本漂移与边界情况)。
>
> **`session_refs.ref_type` 取值域。** `{commit, pr}` 只是*本*存储中出现过的值；schema 还支持 `issue` 引用（两份独立的逆向工程来源都将 `session_refs` 描述为保存与会话关联的 commits、PRs **和** issues）
> （[jonmagic](https://jonmagic.com/posts/github-copilot-session-search-and-resume-cli/)、
> [dfberry](https://dfberry.github.io/2026-04-16-session-storage-decision-guide)）。

### 12.2 `~/.copilot/session-state/<uuid>/session.db` —— 每会话（155 个目录）

代理的 TODO 列表 + 代理间收件箱（已实时核实的 schema）：

```sql
CREATE TABLE todos (
  id TEXT PRIMARY KEY, title TEXT NOT NULL, description TEXT,
  status TEXT DEFAULT 'pending' CHECK(status IN ('pending','in_progress','done','blocked')),
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now')));

CREATE TABLE todo_deps (
  todo_id TEXT NOT NULL, depends_on TEXT NOT NULL,
  PRIMARY KEY (todo_id, depends_on),
  FOREIGN KEY (todo_id) REFERENCES todos(id),
  FOREIGN KEY (depends_on) REFERENCES todos(id));

CREATE TABLE inbox_entries (                     -- inter-agent message inbox
  id TEXT PRIMARY KEY, recipient_session_id TEXT NOT NULL,
  sender_id TEXT NOT NULL, sender_name TEXT NOT NULL, sender_type TEXT NOT NULL,
  interaction_id TEXT NOT NULL, sequence INTEGER NOT NULL DEFAULT 0,
  summary TEXT NOT NULL, content TEXT NOT NULL,
  unread INTEGER NOT NULL DEFAULT 1,
  sent_at INTEGER NOT NULL, read_at INTEGER, notified_at INTEGER);
```

---

## 13. 辅助文件

| 产物 | 位置 | 类型 | Engram | 含义 |
|---|---|---|---|---|
| `session.db` | `<uuid>/session.db` | SQLite | 否 | TODO + 代理间收件箱（[§12.2](#122-copilotsession-stateuuidsessiondb--每会话155-个目录)） |
| `rewind-snapshots/` | `<uuid>/rewind-snapshots/` | 目录 | 否 | `index.json` = `{version, snapshots, filePathMap}`；`backups/<16-hex-hash>-<epoch-ms>` = 供 "回退/撤销" 用的逐字编辑前文件副本 |
| `files/` | `<uuid>/files/` | 目录 | 否 | 用户粘贴负载：`paste-<epoch-ms>.txt` |
| `research/` | `<uuid>/research/` | 目录 | 否 | Web/研究产物（本存储中为空） |
| `plan.md` | `<uuid>/plan.md` | Markdown | 否 | 代理的自由形式工作计划（15 个目录） |
| `inuse.<pid>.lock` | `<uuid>/inuse.<pid>.lock` | 文件 | 否 | 存活锁；内容 = 裸的所属 PID |
| `session-store.db` | `~/.copilot/session-store.db` | SQLite | 否 | 存储级镜像 + FTS5（[§12.1](#121-copilotsession-storedb--存储级镜像schema_version--4)） |
| `config.json` / `settings.json` / `mcp-config.json` | `~/.copilot/` | JSON | 否 | CLI 配置 |
| `command-history-state.json` | `~/.copilot/` | JSON | 否 | Shell 命令历史 |
| `copilot-instructions.md` | `~/.copilot/` | Markdown | 否 | 全局指令 |
| `ide/` `installed-plugins/` `logs/` `marketplace-cache/` `pkg/` `plugin-data/` | `~/.copilot/` | 目录 | 否 | CLI 运行时状态 |

---

## 14. Engram 映射

源字段/记录 → Engram `Session`/`Message` 字段 → 适配器 `file:line`（Swift + TS）。

| Engram 字段 | 真相来源 | Swift `CopilotAdapter.swift` | TS `copilot.ts` | 备注 |
|---|---|---|---|---|
| **id** | `workspace.id` → 否则目录名 | `:54`（events）/ `:179`（checkpoint） | `:77` / `:278` | UUID |
| **source** | 常量 `copilot` | `:4`,`:99` | `:19`,`:120` | |
| **summary** | `workspace.summary` → 否则首条 `user.message.content` 的前 200 字符 → 否则（检查点）首个条目标题 | `:110` / `:194` | `:129` / `:291` | ⚠️ `workspace.name`（通常是更好的 AI 标题）**被忽略** |
| **cwd** | `workspace.cwd` → 否则 `session.start.context.cwd` | `:57`,`:72`；project=`nil` `:103` | `:80`,`:97` | `project` 始终为 null；之后由索引器从 cwd 派生 |
| **startTime** | `workspace.created_at` → 否则 `session.start.startTime` → 否则 min(`user.message.ts`) | `:55`,`:69`,`:81` / `:184` | `:78`,`:95-96`,`:105` / `:283` | |
| **endTime** | `workspace.updated_at` → 否则 max(message ts)；若 == startTime 则为 `nil`/`undefined` | `:56`,`:82`,`:86`,`:101` / `:185` | `:79`,`:106`,`:111`,`:122` / `:284` | 单瞬时会话得到 null endTime |
| **model** | **未映射**（按消息 `model` + `currentModel` 被丢弃） | `:102`（`model: nil`） | — | ⚠️ 多模型会话丢失模型归属 |
| **messageCount** | `userCount + assistantCount`（检查点：条目数） | `:105` / `:189` | `:124` / `:286` | ⚠️ 不含工具/系统/回合事件 |
| **userMessageCount** | `user.message` 计数（检查点：0） | `:76`,`:106` / `:190` | `:101`,`:125` / `:287` | |
| **assistantMessageCount** | `assistant.message` 计数（检查点：0） | `:85`,`:107` / `:191` | `:110`,`:126` / `:288` | ⚠️ 也计入空的仅工具回合 |
| **toolMessageCount** | 硬编码 `0` | `:108` / `:192` | `:127` / `:289` | Copilot 工具事件从不呈现 |
| **systemMessageCount** | events 为 `0`；检查点会话为条目数 | `:109` / `:193` | `:128` / `:290` | |
| **role（每条消息）** | `user.message`→user，`assistant.message`→assistant，检查点条目→system | `:218` / `:139` | `:231` / `:150` | 工具/系统/skill 事件从不成为消息 |
| **content（每条消息）** | 仅 `data.content` | `:219` | `:232` | reasoning/toolRequests 被丢弃 |
| **usage（tokens）** | `session.shutdown.data.modelMetrics[*].usage` 求和 → 附加到**最后一条**助手消息 | `:228-269` | `:177-191`,`:380-400` | inputTokens、outputTokens、cacheReadTokens、cacheCreationTokens←`cacheWriteTokens`；`reasoningTokens` 被丢弃 |
| **filePath / locator** | `events.jsonl` 或 `checkpoints/index.md` 的路径 | `:111` / `:196` | `:130` / `:292` | |
| **sizeBytes** | 仅 locator 文件的文件大小 | `:112` / `:196` | `:131` / `:293` | ⚠️ 仅 events/index 文件，不是整个目录 |
| **agentRole / originator / origin** | 硬编码 `nil` | `:114-116` | —（不发射） | 无派发检测 |
| **parentSessionId / suggestedParentId** | 硬编码 `nil` | `:120-121` | —（不发射） | 子代理从不分组 —— [§10](#10-子代理--父子--派发) |
| **tier / qualityScore / indexedAt / summaryMessageCount** | `nil` | `:113`,`:117-119` | — | 下游设置 |

### 数据丢失清单（Engram 不消费的内容）

1. **`workspace.name`** —— 一个真实的、常为 AI 生成的**标题**（实时 138/470）。Engram 转而使用首条用户提示的前 200 字符。最大的 UX 缺失。
2. **工具活动** —— `tool.execution_start/complete` 与 `assistant.message.toolRequests` 完全丢弃；`toolMessageCount` 硬编码 0 → 零 Copilot 工具/文件分析。
3. **子代理谱系** —— `subagent.started/completed` 从不进入父子检测（[§10](#10-子代理--父子--派发)）。
4. **按消息的模型 + tokens** —— `assistant.message.model` / `.outputTokens` 被丢弃；仅 shutdown 聚合留存。
5. **Reasoning** —— `reasoningText` / `reasoningOpaque` / `reasoningTokens` 被丢弃（[§8](#8-reasoning--thinking)）。
6. **`transformedContent`**（真实注入的提示）与用户消息上的 `attachments`。
7. **Hook、skill、回合帧、压缩、system/notification、模式/计划变更** —— 全部丢弃。
8. **丰富的 shutdown 统计** —— `conversationTokens`、`currentTokens`、`totalPremiumRequests`、`codeChanges`、`tokenDetails` 被丢弃（仅保留 `modelMetrics.*.usage` 的 4 字段子集）。
9. **Git/主机上下文** —— `git_root`、`repository`、`branch`、`headCommit` 被丢弃；`project` 仅从 `cwd` 在下游派生。
10. **两个 SQLite 存储** —— `session.db` 与 `session-store.db`（含更干净的 `turns` 表）完全被忽略。

---

## 15. 谱系、陷阱、版本漂移与边界情况

### 共享格式谱系（兄弟工具）

| 工具 | Engram 适配器 | 存储 | 格式家族 |
|---|---|---|---|
| **GitHub Copilot CLI** | `CopilotAdapter` | `~/.copilot/session-state/<uuid>/events.jsonl` + `workspace.yaml` | **JSONL 事件流** |
| **OpenAI Codex CLI** | `CodexAdapter` | `~/.codex/sessions/.../*.jsonl` | **JSONL 事件流**（最近的兄弟） |
| **Cursor** | `CursorAdapter` | `…/Cursor/User/globalStorage/…` | **SQLite `.vscdb`** |
| **VS Code Copilot Chat** | `VSCodeAdapter` | `…/Code/User/workspaceStorage/…` | **SQLite `.vscdb`** |
| **Cline** | `ClineAdapter` | `~/.cline/data/tasks/` | 每任务 JSON |
| **Gemini CLI / Qwen / iFlow** | `Gemini/Qwen/IFlowAdapter` | `~/.gemini/`、`~/.qwen/`、`~/.iflow/` | 共享 Gemini-CLI JSON 谱系 |

**关键谱系更正。** "Copilot" 这个名字诱使人们把它与 VS Code Copilot / Cursor（编辑器扩展，SQLite `.vscdb`）家族归为一类 —— 但在磁盘上，Copilot **CLI** 属于**与 Codex CLI 并列的 JSONL 代理 CLI 家族**，而非 VS Code SQLite 家族。Copilot CLI 与 Codex CLI 都使用换行分隔的带类型事件（`type` + `data` + `timestamp`），并带有 `session.start`/`session.shutdown` 信封。Gemini↔Qwen↔iFlow 三者共享一种*不同的*（源自 Gemini-CLI 的）JSON 布局。**尽管品牌名称重叠，却是三种不同的格式谱系。** 关于最近的兄弟，参见本目录下的 Codex CLI 文档。

### 陷阱 / 版本漂移 / 边界情况

- **YAML 引号处理已对齐。** Swift 与 TS 都会从 `workspace.yaml` 值中剥离一对匹配的外层引号（`CopilotAdapter.swift:363-389`、`copilot.ts:364-378`、`stripYamlQuotes:438-446`）。实时：6 个带引号的 `name:` 值（Engram 无论如何都忽略），今天有 0 个带引号的 `cwd`/`id`。由 TS `tests/adapters/copilot.test.ts` 与 Swift `AdapterMessageCountTests.testCopilotStripsMatchedYamlQuotePairs` 覆盖。
- **空但非零的助手消息。** 实时：相当大的一部分 —— **⅓ 到约 ½，视会话而定**（一个会话 86/261 ≈ ⅓；另一个 51835c08，1445/2827 ≈ 51%）—— 的 `assistant.message` 事件其 `content` 为空（仅工具调用的回合）。Engram 把全部计为助手消息 → `assistantMessageCount` 相对人类可读回合被夸大；转录文本显示空白行。其量级比引用的那个 ⅓ 样本泛化得更糟。
- **即使 locator 已闭合，实时 DB 字段新鲜度仍落后于 parser 修复。**
  2026-07-02 adapter-vs-DB id diff 是干净的（227 个 adapter locator、227 条
  DB row、227 条 `file_index_state ok/v1`），但 8 条既有 DB row 仍保留旧
  parser 快照。6 条是 Swift/TS YAML quote fix 之前留下的 summary-only 引号债，
  例如 DB `"Reply with only: OK"` vs 当前 `Reply with only: OK`。另外两条是
  旧 count/end-time 快照：`51835c08-bea0-4594-83e7-9fe69b71808a` 为
  DB 1,952 vs 当前解析 2,863 messages，`ad05ab2d-ddcb-419f-8452-57ec21d4b96f`
  为 DB 2,009 vs 当前解析 2,103。文件大小与 file-index state 已对齐；
  需要 reindex/cleanup 才能刷新这 8 条历史 row。
- **`messageCount` 的两个相反扭曲。** 它排除工具/hook 流量（对工具密集的会话低估真实活动），又计入空的助手行（高估对话回合）。
- **两者都存在的目录。** 一个同时含 `events.jsonl` **和**已填充 `checkpoints/` 的目录会按 events 解析；检查点摘要从不呈现。
- **仅含表头的 `index.md`**（实时 243/470）→ 0 个条目 → 目录被**静默跳过**（无报错，会话从 Engram 中消失）。
- **`cwd: /` 的检查点会话**会成为根作用域、近乎空的 Session 行（常 `created_at == updated_at`）。
- **检查点回退未在实时数据中验证。** events 缺失 → 检查点索引这条路径在两个适配器中都已实现，但在本实时存储上**从未被触发**：26 个检查点索引有可解析条目，但每个也都有 `events.jsonl`；243 个无事件目录的模板是空的。仅凭磁盘无法证明它对真实回退数据的行为。
- **`copilotVersion` 漂移 / 无版本化的 schema。** 当前实时数据包含 `0.0.420`/`0.0.421`/`0.0.422`，以及从 `1.0.2` 到 `1.0.65` 的若干 `1.0.x` 版本（有缺口）；`1.0.63` 仍存在但不是观测到的最新版本。适配器很宽容 —— 它会忽略未知的 `type` 值，因此新类型（`skill.invoked`、`subagent.*`、`session.model_change`，这些都不在合成 fixture 中）都被容忍。对 `user.message`/`assistant.message`/`session.shutdown` 的破坏性重命名会**静默地把**一个会话**清零**。
- **Fixture 严重滞后于现实。** 合成 fixture 只有 3 个事件（没有 shutdown、检查点、子代理、tokens）；parity 黄金反映了那个最小形态。通过的 parity 测试证明的是适配器*一致地*忽略实时丰富性，而**不是**它能处理这些丰富性。
- **Token 合计正确，拆分丢失。** `modelMetrics` 跨所有模型求和（实时：一个会话 3-4 个模型）→ 正确的会话合计，但没有按模型/按回合的拆分。
- **无代理角色 / 父链接。** 每个 Copilot 会话在 Engram 中都是顶层的（[§10](#10-子代理--父子--派发)）。
- **SQLite 镜像滞后。** `session-store.db`（140 会话 / 241 回合 / 9 检查点）滞后于文件系统（470 目录）。它是派生/近期活动的；Engram 不读取它。

### 待解问题

- **为何忽略 `session-store.db`？** 它的 `turns` 表是更干净的配对转录，`checkpoints` 是结构化的 —— 选择 events.jsonl/Markdown 是刻意为之还是一个值得弥补的索引缺口？**（Engram 内部设计 —— 无法通过 web 验证。）** 不过有两个格式事实与此相关：GitHub 官方文档指出会话存储仅保存 "a subset of the full data stored in the session files"（因此 `events.jsonl` 是更完整/无损的记录），且该 DB 是一个*派生*存储，用户通过 `/chronicle reindex` 从文件重建它 —— 它可能滞后并发生分歧（目录被清理后记录仍残留；当 sync 为 local-only 时返回 0 行）。把 events.jsonl 视为真相来源的选择与 GitHub 对该存储的描述一致
  （[docs](https://docs.github.com/en/copilot/concepts/agents/copilot-cli/chronicle)、
  [issue #2654](https://github.com/github/copilot-cli/issues/2654)）。
- **`forge_trajectory_events` / `session_files`** 带有工具/文件列却存在，但在本存储中为 **0 行**。**Confirmed (official, partial)：** `session_files` 是一个真实、有文档的表，其用途是记录 "every file touched during the session"（由两份独立的逆向工程文章佐证），所以它**确实**被设计为可填充；0 行的观测是存储特定的，并非死列。没有任何公开来源提及 `forge_trajectory_events` 或 `dynamic_context_items`（Copilot CLI 闭源；公开逆向工程只枚举了 6 张表），因此较新版本是否会填充 `forge_trajectory_events` **无法从公开来源确认**
  （[jonmagic](https://jonmagic.com/posts/github-copilot-session-search-and-resume-cli/)、
  [dfberry](https://dfberry.github.io/2026-04-16-session-storage-decision-guide)）。
- **243/470 个无事件目录**（约 52%）。**Confirmed (official)：** 它们是中止/从未输入提示的启动，而非清理产物。GitHub
  [issue #1451](https://github.com/github/copilot-cli/issues/1451) 记录了空会话目录由 "opened but never interacted with" / 未收到任何响应的会话累积而成，并将 "Empty" 定义为 "No events.jsonl file, or no user messages at all"。没有自动 GC —— 该 issue 之所以请求一个手动 `/cleanup`，正是因为它们会堆积。
- **`reasoningOpaque`** 格式未解码（已确认是与 `reasoningText` 共现的字符串）。**（web-checked 2026-06-21: no authoritative source found。）** 官方文档确认 extended-thinking/reasoning 会被跟踪并在压缩中保留，但 Copilot CLI 闭源，没有公开来源记录 `reasoningOpaque` blob 的内部编码
  （[DeepWiki](https://deepwiki.com/github/copilot-cli/3.7-context-and-token-management)）。
- **`mc_*` / `remote_steerable` / `client_name`**（mission-control / 远程操控）。**Confirmed (official, partial)：** `remote_steerable` 映射到一个真实、有文档的功能 —— CLI 会话的 "remote control"（GitHub Mobile / github.com / VS Code），受组织/企业级 "Store local sessions in the Cloud" 策略门控。`mc_*` 字段很可能关联到 GitHub 的 "Mission Control"（Agent HQ），它跨会话分配/操控/跟踪 Copilot 编码代理任务。然而，没有官方来源指明字面的 `workspace.yaml` 键（`mc_task_id` / `mc_session_id` / `mc_last_event_id` / `remote_steerable` / `client_name`），因此字段到功能的精确映射是推断性的；它们是否应驱动 Engram 的父子分组仍是一个 Engram 设计问题
  （[remote-control docs](https://docs.github.com/en/copilot/concepts/agents/copilot-cli/about-remote-control)、
  [Mission Control changelog](https://github.blog/changelog/2025-10-28-a-mission-control-to-assign-steer-and-track-copilot-coding-agent-tasks/)）。
- **无自动文件滚动/TTL**（events.jsonl 最大达 38 MB，目录可追溯到 3 月）。**Confirmed (official)：** `events.jsonl` 没有基于大小的自动轮转或 TTL（仅追加的流式日志；在 95% token 容量时的流内自动压缩会创建检查点，但不会轮转/缩减磁盘上的日志）。保留是用户触发的，而非自动的：存在 `/session prune --older-than DAYS`、`/session delete [ID]`、`/session delete-all [--yes]` 和 `/session cleanup`（仅本地会话；跳过正在使用的会话；GitHub.com 上的同步副本须单独移除）
  （[docs](https://docs.github.com/en/copilot/concepts/agents/copilot-cli/chronicle)、
  [CLI reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference)）。

---

## 16. 附录：真实脱敏样本

### `events.jsonl` —— `session.start`（当前富上下文形态；末尾标志随版本可变）
```json
{"type":"session.start","timestamp":"2026-06-20T04:00:25.530Z","id":"<uuid>","parentId":null,
 "data":{"sessionId":"<uuid>","producer":"copilot-agent","version":1,"copilotVersion":"1.0.63",
         "startTime":"2026-06-20T04:00:25.530Z",
         "context":{"branch":"<branch>","cwd":"<path>","gitRoot":"<path>","repository":"<owner>/<repo>"}}}
```

### `events.jsonl` —— `user.message`
```json
{"type":"user.message","timestamp":"…","id":"<uuid>","parentId":"<uuid>",
 "data":{"content":"<REDACTED>","transformedContent":null,"attachments":[],"interactionId":"<uuid>"}}
```

### `events.jsonl` —— `assistant.message`（含 reasoning + 工具请求 + 回合/关联 id）
```json
{"type":"assistant.message","timestamp":"…","id":"<uuid>","parentId":"<uuid>",
 "data":{"messageId":"<uuid>","model":"claude-sonnet-4.6","content":"<REDACTED>",
         "interactionId":"<uuid>","turnId":"<uuid>","outputTokens":643,"phase":"<REDACTED>",
         "requestId":"<uuid>","serviceRequestId":"<uuid>","apiCallId":"<uuid>",
         "reasoningText":"<REDACTED>","reasoningOpaque":"<REDACTED>","encryptedContent":"<REDACTED>",
         "parentToolCallId":"toolu_…",
         "toolRequests":[{"toolCallId":"toolu_…","name":"<tool>","arguments":{…},
                          "type":"function","intentionSummary":"<REDACTED>"}]}}
```

### `events.jsonl` —— `tool.execution_complete`
```json
{"type":"tool.execution_complete","timestamp":"…","id":"<uuid>","parentId":"<uuid>",
 "data":{"toolCallId":"toolu_…","success":true,"model":"claude-opus-4.6","interactionId":"<uuid>",
         "result":{"content":"<REDACTED>","detailedContent":"<REDACTED>"},
         "toolTelemetry":{"metrics":{"responseTokenLimit":0,"resultForLlmLength":0,"resultLength":0},
                          "properties":{"command":"<REDACTED>","viewType":"…"}}}}
```

### `events.jsonl` —— `subagent.completed`
```json
{"type":"subagent.completed","timestamp":"…","id":"<uuid>","parentId":"<uuid>",
 "data":{"agentName":"<REDACTED>","agentDisplayName":"<REDACTED>","model":"claude-sonnet-4.6",
         "durationMs":12345,"totalTokens":6789,"totalToolCalls":4,"toolCallId":"toolu_…"}}
```

### `events.jsonl` —— `session.shutdown`
```json
{"type":"session.shutdown","timestamp":"…","id":"<uuid>","parentId":"<uuid>",
 "data":{"shutdownType":"routine","currentModel":"claude-opus-4.6",
         "conversationTokens":60168,"systemTokens":7640,"toolDefinitionsTokens":19409,
         "totalApiDurationMs":560974,"totalPremiumRequests":27,
         "codeChanges":{"linesAdded":67,"linesRemoved":4,"filesModified":["<path>"]},
         "modelMetrics":{"claude-opus-4.6":{"requests":{"count":62,"cost":27},
           "usage":{"inputTokens":3749137,"outputTokens":27465,
                    "cacheReadTokens":3433631,"cacheWriteTokens":0,"reasoningTokens":179832}}}}}
```

### `workspace.yaml`（完整超集）
```yaml
id: 00f0af74-c7a0-440c-812a-29bad956c597
cwd: /Users/<user>/<project>
git_root: /Users/<user>/<project>
repository: <owner>/<repo>
host_type: github
branch: feat/<branch>
client_name: github/cli
name: <REDACTED title>
user_named: false
summary: <REDACTED>
summary_count: 0
created_at: 2026-06-20T04:00:25.530Z
updated_at: 2026-06-20T04:02:29.076Z
remote_steerable: false
mc_task_id: <uuid>
mc_session_id: <uuid>
mc_last_event_id: <uuid>
```

### `checkpoints/index.md`
```markdown
# Checkpoint History

Checkpoints are listed in chronological order. Checkpoint 1 is the oldest, higher numbers are more recent.

| # | Title | File |
|---|-------|------|
| 1 | <Title text> | 001-<slug>.md |
| 2 | <Title text> | 002-<slug>.md |
```

### `checkpoints/NNN-<slug>.md`（正文）
```markdown
<overview>
<REDACTED>
</overview>
<history>
<REDACTED>
</history>
<work_done>
<REDACTED>
</work_done>
<technical_details>
<REDACTED>
</technical_details>
<important_files>
<REDACTED>
</important_files>
<next_steps>
<REDACTED>
</next_steps>
```

### `session-store.db` 行（结构逐字，内容已编辑）
```json
// sessions
{"id":"4bb3e088-…","cwd":"<path>","repository":"<owner>/<repo>","host_type":"github",
 "branch":"main","summary":"<REDACTED>","created_at":"2026-05-02T05:24:29.274Z","updated_at":"2026-05-02T05:24:36.193Z"}
// turns  (already-paired transcript)
{"id":1,"session_id":"4bb3e088-…","turn_index":0,"user_message":"<REDACTED>","assistant_response":"<REDACTED>","timestamp":"2026-05-02T05:24:39.126Z"}
// checkpoints  (structured form of .md section tags)
{"id":1,"session_id":"6e89dd68-…","checkpoint_number":1,"title":"<REDACTED>","overview":"<REDACTED>","work_done":"<REDACTED>","created_at":"2026-05-04T12:58:16.128Z"}
// session_refs  (ref_type observed ∈ {commit, pr}; format also supports 'issue')
{"ref_type":"commit","ref_value":"<sha REDACTED>","turn_index":5}
{"ref_type":"pr","ref_value":"<REDACTED>","turn_index":3}
```

### `session.db`（每会话）行（结构逐字，内容已编辑）
```json
// todos  (status ∈ pending|in_progress|done|blocked)
{"id":"<uuid>","title":"<REDACTED>","description":"<REDACTED>","status":"in_progress","created_at":"…","updated_at":"…"}
// inbox_entries  (inter-agent inbox)
{"id":"<uuid>","recipient_session_id":"<uuid>","sender_id":"<uuid>","sender_name":"<REDACTED>","sender_type":"agent","interaction_id":"<uuid>","sequence":0,"summary":"<REDACTED>","content":"<REDACTED>","unread":1,"sent_at":1780000000000,"read_at":null,"notified_at":null}
```

### Fixture `events.jsonl`（合成，供参考）
```json
{"type":"session.start","timestamp":"2026-01-01T00:00:00Z","data":{"startTime":"2026-01-01T00:00:00Z","context":{"cwd":"/tmp/test-project"}}}
{"type":"user.message","timestamp":"2026-01-01T00:01:00Z","data":{"content":"Help me fix the bug"}}
{"type":"assistant.message","timestamp":"2026-01-01T00:02:00Z","data":{"content":"I'll look into that."}}
```

---

## References (official sources)

2026-06-21 的 web 确认轮次使用了以下来源。官方 GitHub 文档与 `github/copilot-cli`
仓库具有权威性；社区逆向工程仅作佐证（Copilot CLI 闭源）。

**Official (GitHub Docs / Changelog / repo)：**
- [About GitHub Copilot CLI session data (chronicle) — GitHub Docs](https://docs.github.com/en/copilot/concepts/agents/copilot-cli/chronicle)
- [Using GitHub Copilot CLI session data — GitHub Docs](https://docs.github.com/en/copilot/how-tos/copilot-cli/use-copilot-cli/chronicle)
- [GitHub Copilot CLI command reference — GitHub Docs](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference)
- [About remote control of GitHub Copilot CLI sessions — GitHub Docs](https://docs.github.com/en/copilot/concepts/agents/copilot-cli/about-remote-control)
- [A mission control to assign, steer, and track Copilot coding agent tasks — GitHub Changelog](https://github.blog/changelog/2025-10-28-a-mission-control-to-assign-steer-and-track-copilot-coding-agent-tasks/)
- [Remote control for Copilot CLI sessions GA on Mobile, Web, and VS Code — GitHub Changelog](https://github.blog/changelog/2026-05-18-remote-control-for-copilot-cli-sessions-now-generally-available-on-mobile-web-and-vs-code/)
- [github/copilot-cli repository](https://github.com/github/copilot-cli)
- [Issue #3551: Formalize events.jsonl as an official hook/integration API](https://github.com/github/copilot-cli/issues/3551)
- [Issue #1451: /cleanup command to remove empty/abandoned sessions](https://github.com/github/copilot-cli/issues/1451)
- [Issue #3046: session-store.db not created on Windows WSL2](https://github.com/github/copilot-cli/issues/3046)
- [Issue #2654: session_store_sql silently returns empty when session sync is local](https://github.com/github/copilot-cli/issues/2654)
- [Issue #2012: Session file corrupted — raw U+2028/U+2029 in events.jsonl](https://github.com/github/copilot-cli/issues/2012)

**Community（逆向工程，佐证）：**
- [jonmagic: GitHub Copilot Session Search and Resume CLI](https://jonmagic.com/posts/github-copilot-session-search-and-resume-cli/)
- [dfberry: Exploring Copilot CLI Session Management](https://dfberry.github.io/2026-04-16-session-storage-decision-guide)
- [DeepWiki: github/copilot-cli — Session State & Lifecycle Management](https://deepwiki.com/github/copilot-cli/6.2-session-state-and-lifecycle-management)
- [DeepWiki: github/copilot-cli — Context and Token Management](https://deepwiki.com/github/copilot-cli/3.7-context-and-token-management)
