# Codex 会话格式 — 权威参考

> 本文档为英文权威版 codex.md 的中文阅读副本;若有出入以英文版为准。

Last researched: 2026-06-21 (Engram session-format research workflow)

本文档是关于 **Codex CLI**(OpenAI 的编码代理)如何把会话持久化到磁盘、以及 Engram 的
`CodexAdapter` 如何消费它们的永久性、详尽参考。它针对两类事实来源进行了交叉核对:

1. **本机上 `~/.codex/` 下真实的磁盘文件**(2,505 个 rollout `.jsonl` 文件 + 5 个已归档,
   覆盖 Codex CLI `0.60.1` → `0.142.0-alpha.6`,2025 年 11 月 → 2026 年 6 月)。当格式与
   适配器发生分歧时,**以磁盘上的真实情况为准**,并标注该差异。
2. **已经在解析该格式的 Engram 适配器**:
   - `/Users/bing/-Code-/engram/macos/Shared/EngramCore/Adapters/Sources/CodexAdapter.swift`(已发布的产品解析器)
   - `/Users/bing/-Code-/engram/src/adapters/codex.ts`(TypeScript 参考/对等镜像)
   - `/Users/bing/-Code-/engram/macos/Shared/EngramCore/Adapters/SessionAdapter.swift`(`OriginatorClassifier`)
   - `/Users/bing/-Code-/engram/macos/Shared/EngramCore/Adapters/SessionAdapterFactory.swift`(发现)
   - `/Users/bing/-Code-/engram/src/adapters/codex-usage-probe.ts`(配额抓取 — 不是 rollout 解析器)

---

## 概览与 TL;DR

**保存了什么、保存在哪里、由哪个进程保存。** 每个 Codex 会话都由 Codex CLI/桌面运行时以
**两个互补层**写入磁盘:

- **Rollout JSONL 转录**(权威内容)— 每个会话一个仅追加的、按行分隔的 JSON 文件,位于
  `~/.codex/sessions/YYYY/MM/DD/rollout-<localtime>-<uuidv7>.jsonl`。每一次用户回合、模型
  输出、推理块、工具调用/结果、运行时事件和 token 计数都是一行 JSON。
- **SQLite 目录/索引数据库**(`~/.codex/state_5.sqlite` 等)— 在 rollout 之上的快速、可
  查询的*去规范化索引*(线程目录、父→子 spawn 图、记忆管线、目标、日志)。它们保存
  **状态、关系和派生数据**,而不是转录内容。该数据库可以从文件中重建。

这两层之间的关联是一个统一的连接键:**UUIDv7**,它同时是文件名 UUID、
`session_meta.payload.id`、`threads.id`、`session_index.jsonl.id` 以及
`history.jsonl.session_id`。

**一段话心智模型。** 打开一个 rollout 文件:第 1 行始终是 `session_meta` 头(身份、cwd、
originator、git、agent 角色)。其后的每一行都有相同的三键信封 `{timestamp, type, payload}`,
其中顶层 `type` 是*记录类别*(`response_item` / `event_msg` / `turn_context` / `compacted`),
而 `payload.type` 是*其内部的内容变体*(`message` / `reasoning` / `function_call` /
`token_count` / …)。模型对话存在于 `response_item` 行中;token 用量存在于
`event_msg`/`token_count` 行中;每回合配置存在于 `turn_context` 中;上下文压缩重写存在于顶层
`compacted` 记录中。Engram 流式读取该 JSONL,重新派生出一切(id、时间、cwd、model、计数、
用量、摘要),并且**从不读取 SQLite 层**。

**ASCII 分层示意图:**

```
~/.codex/                                          ← Codex home
│
├── sessions/2026/06/21/rollout-<localTS>-<uuid>.jsonl   ← AUTHORITATIVE transcript (append-only)
│     │
│     │   L0  one line = {timestamp, type, payload}      ← envelope
│     │        │
│     │        ├─ L1  type = session_meta | response_item | event_msg | turn_context | compacted
│     │        │         │
│     │        │         └─ L2  payload.type = message | reasoning | function_call |
│     │        │                  function_call_output | token_count | agent_message | ...
│     │        │                    │
│     │        │                    └─ L3  content[].type = input_text | output_text | input_image
│     │        │                            summary[].type = summary_text
│     │
├── archived_sessions/rollout-...jsonl              ← FLAT (no Y/M/D); moved here on archive
├── history.jsonl  session_index.jsonl              ← global append-log mirrors (user input / titles)
│
└── state_5.sqlite  memories_1.sqlite  goals_1.sqlite  logs_2.sqlite   ← INDEX/STATE layer
      │   threads (1 row/session) ── rollout_path ──► points back at the .jsonl
      │   thread_spawn_edges (parent→child subagent graph)
      └── sqlite/ {codex-dev.db + stale duplicate state/goals/logs}  ← LEGACY generation
```

---

## 磁盘布局与文件命名

### `~/.codex/` 的顶层布局

```
~/.codex/
  sessions/YYYY/MM/DD/rollout-<localtime>-<uuidv7>.jsonl   # per-session transcripts (AUTHORITATIVE)
  archived_sessions/rollout-<localtime>-<uuidv7>.jsonl     # FLAT — no YYYY/MM/DD; archived transcripts
  attachments/                                             # pasted/attached blobs
  generated_images/                                        # generated image blobs
  history.jsonl                                            # cross-session USER-INPUT history (append log, 3.9 MB)
  session_index.jsonl                                      # id → thread_name (human title) append log (100 KB)
  state_5.sqlite   (+ -wal, -shm)                          # 16 MB — THREADS catalog (DB index of truth)
  memories_1.sqlite (+wal/shm)                             # background memory-extraction job queue (940 KB)
  goals_1.sqlite    (+wal/shm)                             # per-thread goal/budget tracking (60 KB)
  logs_2.sqlite     (+wal/shm)                             # 1.3 GB — internal Rust tracing log sink
  config.toml  auth.json  AGENTS.md  installation_id       # config/identity (out of scope)
  sqlite/                                                  # SECONDARY dir: codex-dev.db + LEGACY copies
    codex-dev.db                                           # local app-server (automations/inbox) — dev-only
    state_5.sqlite, goals_1.sqlite, logs_2.sqlite,         # STALE earlier generation (mtime 2026-06-14/19)
    memories_1.sqlite (+wal/shm)
```

`_N` 后缀(`state_5`、`memories_1`、`goals_1`、`logs_2`)是一个**迁移代次(migration
generation)**:当 Codex 需要对某个数据库的 schema 家族做一次硬性的、非 `sqlx` 的重置时,
它会弃用旧文件并启动一个新的编号文件,而不是就地迁移。每个文件内部都有一张
`_sqlx_migrations` 表(Rust `sqlx` 账本)跟踪增量迁移。`~/.codex/sqlite/` 下的副本是一个
**更旧的位置/代次**(Codex 把数据库根目录从 `~/.codex/sqlite/` 上移到了 `~/.codex/` 本身)
— 它们因 mtime 陈旧 *并且* 迁移版本更低而被归类为遗留(遗留 `state_5` 处于迁移 **35** /
**2267 threads**;现行处于 **39** / **2510 threads**)。只有 `codex-dev.db` 是 `sqlite/`
子目录独有的。

### Rollout 转录:文件路径与命名语法

路径模板:`~/.codex/sessions/YYYY/MM/DD/rollout-<TS>-<UUID>.jsonl`

| 组成 | 格式 | 已验证行为 |
|---|---|---|
| `YYYY/MM/DD` | 零填充的日期目录 | 按**本地时间**日期分桶(与文件名 TS 一致,而非内部的 UTC)。目录按需惰性创建。空月份目录(`2025/09`、`2025/10`)存在但**零** rollout 文件 — 最早可读的 rollout 是 `2025/11/20`(cli `0.60.1`)。 |
| `rollout-` | 字面前缀 | Engram 的发现以该前缀 + `.jsonl` 扩展名为键。 |
| `<TS>` | `YYYY-MM-DDTHH-MM-SS` | **本地时间**,`:` 替换为 `-`,无小数秒,无时区。已验证:文件 `rollout-2025-11-20T11-08-12-...` 在 UTC+8 主机上对应内部 `session_meta.timestamp = 2025-11-20T03:08:12.198Z`(UTC)→ 文件名 TS = UTC+8。**文件名时间戳不是 UTC。** |
| `<UUID>` | UUIDv7(`019x...`) | **与 `session_meta.payload.id` 完全相等**,并且等于 `threads.id`、`session_index.jsonl.id`、`history.jsonl.session_id`。UUIDv7 是按时间排序的,因此它的前导字节编码了与文件名相同的创建时刻。 |

**`archived_sessions/` 语义。** 归档会**移动** rollout 文件,把它从 `YYYY/MM/DD` 树中移出
到一个**扁平**的 `archived_sessions/` 目录(文件名不变),设置 `threads.archived=1` +
`threads.archived_at`,并把 `threads.rollout_path` 重写为新位置。已验证:全部 5 行
`archived=1` 的 `rollout_path` 均为 `~/.codex/archived_sessions/rollout-...jsonl`;全部 2505 行
`archived=0` 都指向 `sessions/YYYY/MM/DD` 树。磁盘计数(2505 树内 + 5 归档)== 数据库计数
(2510)完全相等 — 此存储中两个方向都没有孤儿。

### 目录树示例

```
~/.codex/
├── sessions/
│   ├── 2025/11/20/rollout-2025-11-20T11-08-12-019a9f3b-de26-71f0-991d-b722717131eb.jsonl
│   └── 2026/06/21/
│       ├── rollout-2026-06-21T00-23-04-019ee5d7-c66e-7852-b0e0-9a09a0f4adf8.jsonl
│       ├── rollout-2026-06-21T03-58-01-019ee69c-91fe-7682-a524-a58015c593b6.jsonl
│       └── rollout-2026-06-21T01-39-16-019ee61d-8aa4-7883-bdc0-65be85460940.jsonl
├── archived_sessions/
│   └── rollout-2026-02-17T09-08-34-019c6924-53b5-7a42-9d67-18f8288bbc08.jsonl   (archived=1)
├── history.jsonl
├── session_index.jsonl
├── state_5.sqlite (+ -wal, -shm)
├── memories_1.sqlite  goals_1.sqlite  logs_2.sqlite
└── sqlite/  (legacy)  codex-dev.db  state_5.sqlite  goals_1.sqlite  logs_2.sqlite  memories_1.sqlite
```

---

## 文件生命周期与代次

- **仅追加,从不重写。** rollout `.jsonl` 随会话推进逐行写入。每一行都是一个以 `\n` 结尾的
  完整 JSON 对象。崩溃会留下一个截至最后一个完整行为止仍有效的文件;部分写入的末行只是无法
  解析的 JSON,两个适配器都会跳过它(`parseLine` 返回 `null` / `parseObject` 返回 `nil`)。
- **头部在先。** 第 1 行始终是 `session_meta`(权威头部)。在罕见的分叉/恢复文件中,额外的
  `session_meta` 行可能出现在后面;**第一个生效**(两个适配器都取第一个 `session_meta` 并
  忽略后续的)。
- **恢复 / 继续。** 恢复或分叉的会话会继续写入*同一个* rollout 文件(相同 UUID)。
  `session_meta.forked_from_id` 记录它从哪个会话分支而来;`parent_thread_id` 记录一个
  subagent 的派生线程。压缩也在同一文件中继续(见“摘要 / 压缩”)。
- **滚动。** 单个 rollout 不存在基于大小的滚动 — 一个会话 = 一个文件。日期*目录*在本地午夜
  滚动(当天的新会话落入一个新的 `YYYY/MM/DD` 目录,按需惰性创建)。
- **数据库物化。** SQLite 的 `threads` 行由一个回填扫描器从 rollout 的第一行
  (`session_meta`)物化而来。`backfill_state`(单行,CHECK id=1)保存游标:
  `status='complete'`、`last_watermark='sessions/2026/02/25/rollout-...'`、`last_success_at`。
  数据库相对于文件只会短暂地滞后或领先;在此存储中两者完全一致。
- **Engram 中对崩溃/部分写入的健壮性。** Engram 的 Swift 读取器在完整解析前后校验文件身份
  (size/mtime),如果文件在读取过程中发生变化则以 `.fileModifiedDuringParse` 失败;对于
  窗口化读取则跳过该检查。超过 `maxLineBytes` 的行或超过 `maxMessages` 的文件会被截断,而
  不是崩溃。

---

## 记录 / 行分类法

**分层规则(读取者常常混淆这一点)。** 最多有四个嵌套层。**不要**把顶层记录的 `type` 与
嵌套的 `payload.type` 混为一谈:

| 层级 | 它是什么 | 字段 | 示例 |
|---|---|---|---|
| **L0 信封** | 一行 JSONL = 一条记录 | `{timestamp, type, payload}` | — |
| **L1 记录类型** | 信封的种类 | `.type` | `session_meta`、`response_item`、`event_msg`、`turn_context`、`compacted` |
| **L2 payload 类型** | 其内部的变体 | `.payload.type` | `message`、`reasoning`、`function_call`、`token_count`、`agent_message` … |
| **L3 内容块** | 嵌套数组元素 | `.payload.content[].type` / `.payload.summary[].type` | `input_text`、`output_text`、`input_image`、`summary_text` |

> 关键名称陷阱:
> - `compacted` 是一个 **L1 记录类型**;`context_compacted` 是一个 **L2** `event_msg`
>   变体 — 不同层级上的不同事物。**不存在**字面上叫 `compaction` 的记录(它只作为摘要文本
>   内部的一个子串出现)。
> - `message` / `reasoning` / `function_call` / `token_count` 都是 **L2**,绝非 L1。
> - `input_text` / `output_text` / `summary_text` 都是 **L3**,绝非 L2。
> - 原指针中的 `search` / `read` / `list_files` 是**工具名称**,承载在
>   `function_call.name` 或 `mcp_tool_call_end.invocation.tool` 内部,而不是记录/payload
>   类型。

### L1(顶层)记录类型

在一个真实的近期文件中已验证的直方图:65 个 `response_item`、37 个 `event_msg`、
1 个 `session_meta`、1 个 `turn_context`。它们在磁盘上占主导,但磁盘上的这五种并非完整记录
集。官方已确认:权威的 `RolloutItem` 枚举
([protocol.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs))
有 **六个** 变体(`serde(tag="type", content="payload", rename_all="snake_case")`):
`SessionMeta`、`ResponseItem`、`InterAgentCommunication`、`Compacted`、`TurnContext`、
`EventMsg`。早期草稿遗漏了 **`inter_agent_communication`** —— 一个真实的顶层 rollout 记录
(持久的代理间投递元数据,被重构为对模型可见的 `agent_message`)。它已作为第 6 种 L1 类型
加入下表。

| L1 `type` | 角色 | 用途 | 何时发出 | Engram 是否消费? |
|---|---|---|---|---|
| `session_meta` | 每个 rollout 的**第一行**(头部) | 会话身份 + 环境 | 每文件恰好 1 个(第一个生效) | **是** — 身份 |
| `turn_context` | 每回合运行时配置快照 | 该回合的 model/sandbox/approval/effort/mode | 每回合 ≥1(仅较新 CLI;0.60.1 中缺失) | **否**(被忽略) |
| `response_item` | 模型 API 对话项 | 实际转录(消息、推理、工具调用/结果) | 占绝大多数行 | **是** — 消息 |
| `event_msg` | 运行时/UI 事件(不是模型项) | token 记账、任务生命周期、工具遥测、压缩标记 | 全程穿插 | **仅 `token_count`** |
| `compacted` | 上下文压缩检查点 | 重写/压缩对话历史 | 仅在上下文被压缩时 | **否**(被忽略) |
| `inter_agent_communication` | 持久的代理间投递记录 | 代理间投递元数据,被重构为对模型可见的 `agent_message` | 仅多代理会话 | **否**(被忽略) |

> Engram 仅在 `session_meta`、`response_item` 和 `event_msg` 上分支。它完全忽略
> `turn_context`、`compacted` 和 `inter_agent_communication`(`codex.ts`
> L78/L82/L201/L300;`CodexAdapter.swift` L279/L283/L467/L519)。

### 按记录区分的 L2(嵌套)类型

- **在 `response_item.payload.type` 内部:** `message`、`reasoning`、`function_call`、
  `function_call_output`、`custom_tool_call`、`custom_tool_call_output`、`web_search_call`、
  `tool_search_call`、`tool_search_output`。(单文件计数:`function_call` 20、
  `function_call_output` 20、`reasoning` 17、`message` 7、`web_search_call` 1。)
- **在 `event_msg.payload.type` 内部:** `token_count`、`agent_message`、`agent_reasoning`
  (legacy)、`user_message`、`task_started`、`task_complete`、`turn_aborted`、
  `context_compacted`、`exec_command_end`(legacy)、`patch_apply_end`、`mcp_tool_call_end`、
  `web_search_end`、`entered_review_mode`、`exited_review_mode`、`thread_rolled_back`、
  `thread_goal_updated`、`error`,**外加原生多代理 / 图像 / 动态工具家族**
  `thread_name_updated`、`collab_agent_spawn_end`、`collab_waiting_end`、
  `collab_close_end`、`collab_agent_interaction_end`、`collab_resume_end`、
  `view_image_tool_call`、`image_generation_end`、`item_completed`、
  `dynamic_tool_call_request`、`dynamic_tool_call_response`。(单文件计数:
  `token_count` 18、`mcp_tool_call_end` 11、`agent_message` 4、`task_started` 1、
  `user_message` 1、`web_search_end` 1、`task_complete` 1。)

> **`event_msg` 枚举不是一个有限的、封闭的集合。** 对全部 2,505 个 rollout 文件的全语料库
> 直方图(`/tmp/codex_all_types.txt`)发现了原始列表之外的 11 个额外 `event_msg`
> `payload.type` 值,其中若干达到数百:
> `thread_name_updated`(372)、`collab_waiting_end`(474)、`collab_agent_spawn_end`(441)、
> `collab_close_end`(289)、`collab_agent_interaction_end`(71)、`collab_resume_end`(1)、
> `view_image_tool_call`(403)、`image_generation_end`(227)、`item_completed`(14)、
> `dynamic_tool_call_request`(3)、`dynamic_tool_call_response`(3)。应把该分类法视为
> 随 CLI 版本而增长,而非可枚举且终结的。这 11 个的字段表 + 匿名示例见附录(且 `collab_*`
> 家族在 Subagent 章节中交叉引用)。**Engram 把它们全部丢弃**(没有一个匹配
> `message`/`function_call`/`function_call_output`/`token_count` 分支)。
>
> 注(web-checked 2026-06-21):`thread_name_updated` 是一个真实的 Codex 通知类型,但**不是**
> `protocol.rs` 中核心 rollout `EventMsg` 枚举的变体 —— 在源码中它是一个 app-server/TUI 通知
> (`ThreadNameUpdatedNotification`)。因此磁盘上标记为 `thread_name_updated` 的 `event_msg`
> 行,很可能来自桌面/app-server 写入路径,而非核心 rollout 记录器。
> ([common.rs](https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/src/protocol/common.rs))

---

## 共享信封 / 元数据字段

### L0 信封(每一行)

| 字段 | 类型 | 含义 | 是否可选? | 示例 |
|---|---|---|---|---|
| `timestamp` | string(ISO-8601,毫秒,`Z` = **UTC**) | 该行被追加到文件时的挂钟时间。Engram 使用**最后一个**携带 `timestamp` 的行作为 `endTime`。 | 几乎所有行都存在 | `"2026-06-21T06:06:38.238Z"` |
| `type` | string(枚举) | L1 记录类型 | 始终 | `"response_item"` |
| `payload` | object | 类型特定的主体(L2) | 始终 | `{ ... }` |

> 信封 `timestamp` 与 `session_meta` 内部的 `payload.timestamp` 略有差异(信封 = 行写入
> 时间;payload = 会话创建时间,早几秒)。

### `session_meta.payload` — 会话头部(身份的关键)

该字段集**随 CLI 版本而增长**(下表为并集)。始终为第 1 行;若 `id` 缺失/为空则被 Engram 拒绝。

| 字段 | 类型 | 含义 | 是否存在? | 示例(匿名) |
|---|---|---|---|---|
| `id` | string(UUIDv7) | **会话 id** = 文件名 UUID = `threads.id` | 始终 | `"019ee8c9-c5b3-78f0-bdc2-ab4c8e024293"` |
| `timestamp` | string(ISO UTC) | 会话开始 → Engram `startTime` | 始终 | `"2026-06-21T06:06:38.051Z"` |
| `cwd` | string(绝对路径) | 会话开始时的工作目录 → Engram `cwd` | 始终 | `"/Users/<user>/<project>"` |
| `originator` | string 枚举 | **派发信号本身** — 启动的客户端/宿主 | 始终 | `"codex-tui"`、`"Claude Code"` |
| `cli_version` | string semver | 写入该文件的 Codex CLI 版本(字段是 `cli_version`;**无 `version` 别名**) | 始终(较新) | `"0.142.0-alpha.6"` / `"0.60.1"` |
| `model_provider` | string | 仅提供方名称 — **不是 model id** | 始终 | `"openai"` |
| `source` | **string 或 object** | 启动入口;**多态**(见 Subagent 章节) | 始终 | `"cli"` / `"vscode"` / `{"subagent":{...}}` |
| `instructions` | string \| null | **遗留**(≤~0.6x):存储 `user_instructions`,现代 `session_meta` 中已无此字段。官方已确认:据 `SessionMeta` 源码注释,该字段的 `user_instructions` 被**移动到了 `TurnContext`** —— 而非改名为 `base_instructions`。([protocol.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs)) | 仅旧文件 | `null` |
| `base_instructions` | object `{text}` | **是一个不同的字段,而非 `instructions` 的改名**:它存储会话的**基础/系统**指令;`.text` 为数 KB。(`instructions`/user_instructions 迁移到了 `turn_context`;`base_instructions` 是独立的基础提示槽位。) | 较新文件 | `{"text":"You are Codex..."}` |
| `agent_path` | string \| null | AgentControl 派生子代理的规范 agent path。官方已确认:存在于 `SessionMeta` 上。([protocol.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs)) | subagent 文件 | `"<path>"` |
| `git` | object \| null | 仓库上下文 `{commit_hash, branch, repository_url}`;非仓库时为 `{}` | 大多数文件(≈2242/2505) | `{"commit_hash":"d941...","branch":"main","repository_url":"..."}` |
| `thread_source` | string 枚举 | 磁盘主导取值 `"user"` \| `"subagent"`。官方已确认:`ThreadSource` 枚举实际有**四个**变体 —— `User`、`Subagent`、`Feature(String)`、`MemoryConsolidation` —— 故磁盘取值集可能比 user/subagent 更宽。([protocol.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs)) | 较新 | `"subagent"` |
| `agent_role` | string \| null | subagent 角色 → Engram `agentRole`(优先级高于 originator)。官方已确认:带有 serde 别名 **`agent_type`**(旧 payload 用 `agent_type`),故两个键映射到同一字段。([protocol.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs)) | subagent 文件 | `"explorer"` / `"review"` / `null` |
| `agent_nickname` | string \| null | subagent 显示名(轮换的科学家/植物名,复用时为 `the Nth`) | subagent 文件 | `"Euclid"`、`"Explorer the 12th"` |
| `forked_from_id` | string(UUIDv7) \| null | 它从哪个会话分叉/恢复而来 | ≈276 文件 | `"019e8df9-551f-7e01-..."` |
| `parent_thread_id` | string(UUIDv7) | 派生的 subagent 的父线程(也嵌套在 `source` 中) | ≈239 文件 | `"019ee02d-c140-7813-8897-56f02fb68e88"` |
| `multi_agent_version` | string | 多代理协议版本 | ≈239 文件 | `"v1"` |
| `dynamic_tools` | object/array | 运行时注册的工具 | 罕见(≈42 文件) | `{...}` |
| `model` | string | meta 中很少出现;仅当未见到 `response_item.payload.model` 时 Engram 才使用它 | 罕见 | `"gpt-5.5"` |

**`originator` 的不同取值**(数据库 + 磁盘采样;约 2500 个会话上的近似计数):

| `originator` | 计数 | 含义 |
|---|---|---|
| `codex-tui` | ~1238–1271 | 现代交互式 Codex 终端 UI(当前默认) |
| `codex_cli_rs` | ~514–545 | 遗留的 Rust CLI originator 字符串(早于 `codex-tui`) |
| `Claude Code` | **~394** | 由 **Claude Code 派发 Codex 作为子代理**而启动的会话 → Engram Layer-1b |
| `Codex Desktop` | ~286–335 | Codex VS Code / 桌面应用(通常 `source:"vscode"`) |
| `codex_exec` | ~69 | 无头非交互式 `codex exec`(通常 `source:"exec"`) |
| `codex_sdk_ts` | ~4 | 编程式 TypeScript SDK 驱动 |

---

## 消息与内容块 schema

`response_item` 承载面向模型的转录。下面每个变体都是一个 `L2` `payload.type`。**L3 内容块**
嵌套在 `message.content[]` 和 `reasoning.summary[]` 内部。

### `message`(user / assistant / developer)

`payload` 键:`type`、`role`、`content`(+ 可选 `id`、`status`、`phase`、`metadata`、
`usage`)。

| 字段 | 类型 | 含义 | 是否可选? |
|---|---|---|---|
| `role` | `"user"` \| `"assistant"` \| `"developer"` | 说话方。`developer` 承载注入的系统/权限文本(多见于 `compacted.replacement_history` 内部)。 | 必需 |
| `content` | L3 块数组 | 文本/图像内容 | 必需 |
| `id` | string \| null | 提供方消息 id(较新;现代数据中为 `null`) | 可选 |
| `status` | string \| null | 消息状态(现代数据中为 `null`) | 可选 |
| `phase` | string | **遗留**的 assistant 字段:`"commentary"` \| `"final_answer"` | 遗留(2026 年 2 月),之后被移除,随后又以 `metadata.phase` 形式重现 |
| `metadata` | object | 较新遥测,例如 `{turn_id}` | 较新 |
| `usage` | object | **在现代磁盘上不存在** — 见下面的差异 | 仅遗留/Responses-API |

**`message.content[]` 内部的 L3 内容块类型:**

| `block.type` | 角色上下文 | 字段 | 说明 |
|---|---|---|---|
| `input_text` | user / developer | `{type, text}` | 文本在 `text` 下,**不是**在名为 `input_text` 的键下 |
| `output_text` | assistant | `{type, text}` | 文本在 `text` 下,**不是**在 `output_text` 下 |
| `input_image` | user | `{type, image_url, detail}` | `image_url` 是一个 `data:image/...;base64,...` URL;`detail` 例如 `"auto"` |
| `text` | 较旧 | `{type, text}` | 遗留的纯文本块;仍被 `extractText` 接受 |

```json
// response_item / message (user) — two text blocks
{
  "timestamp": "2026-06-21T06:06:38.500Z",
  "type": "response_item",
  "payload": {
    "type": "message",
    "role": "user",
    "id": null,
    "status": null,
    "content": [
      { "type": "input_text", "text": "<USER PROMPT — redacted>" },
      { "type": "input_text", "text": "<ENVIRONMENT/SKILLS INJECTION — redacted>" }
    ]
  }
}
```

```json
// response_item / message (assistant)
{
  "timestamp": "2026-06-21T06:06:40.100Z",
  "type": "response_item",
  "payload": {
    "type": "message",
    "role": "assistant",
    "content": [ { "type": "output_text", "text": "<ASSISTANT REPLY — redacted>" } ]
  }
}
```

```json
// response_item / message (user, image attachment)
{
  "type": "response_item",
  "payload": {
    "type": "message",
    "role": "user",
    "content": [ { "type": "input_image", "image_url": "data:image/jpeg;base64,<BASE64…>", "detail": "auto" } ]
  }
}
```

**关键差异(磁盘真实情况 vs 适配器):**

- *文本键:* 块的判别符是 `type:"input_text"`/`"output_text"`,但实际字符串**始终**在键
  `text` 下。两个适配器都防御性地额外尝试 `object["input_text"]` / `object["output_text"]`
  键(`codex.ts` L378-379;`CodexAdapter.swift` L611-614)— 这些回退**从不匹配现代 Codex
  数据**。
- *多块分歧:* Swift `extractText` 用 `\n\n` 连接**所有**文本块;TS `extractText` 只返回
  **第一个**文本块。在多块用户消息(确实出现)上,**TS 会少捕获**。
- *缺失每项用量:* 两个适配器都读取 assistant 的 `payload.usage`(`codex.ts` L216;
  `CodexAdapter.swift` L491)作为每条消息的用量来源,但对现代文件的扫描发现**零**个
  `response_item.payload.usage`。每回合用量完全来自 `event_msg/token_count`。这是一条潜伏的
  代码路径,如果未来 Codex 重新加入内联用量,它会悄然取得优先权。
- *项上缺失 model:* 两者都把 `response_item.payload.model` 读作真实的 model id
  (`codex.ts` L86;`CodexAdapter.swift` L289)。现代文件不在 `response_item` 上携带它;实际
  上 model 从 `turn_context.model` / 数据库 / 回退中恢复。在此存储中,适配器最终从 JSONL 得到
  `nil` model,因为 `response_item.payload.model` 和 `session_meta.model` 都不存在 —
  因此 Engram 仅凭一个现代 rollout 往往无法获得 model 名称。

---

## 工具调用与结果

Codex 工具执行表现为一对**配对的** `function_call`(请求)+ `function_call_output`(结果),
由 `call_id` 1:1 关联。对于自由格式工具(`apply_patch`、`js_repl`、…),还有一对并行的
`custom_tool_call` / `custom_tool_call_output`,外加动态 tool-search、web-search 和图像
(`ig_*`)调用。丰富的执行遥测在 `event_msg`(`exec_command_end`、`patch_apply_end`、
`mcp_tool_call_end`)下单独镜像。

### `function_call`

| 字段 | 类型 | 含义 | 示例 |
|---|---|---|---|
| `type` | `"function_call"` | 判别符 | `"function_call"` |
| `name` | string | 工具名 | `"exec_command"`、`"write_stdin"`、`"spawn_agent"`、`"codegraph_explore"` |
| `arguments` | **string(JSON 编码)** | 字符串化的 JSON 参数 — 必须 `JSON.parse` | `"{\"cmd\":[\"/bin/zsh\",\"-lc\",\"…\"],\"workdir\":\"…\"}"` |
| `call_id` | string(`call_<rand>`) | 关联到匹配输出的唯一 id | `"call_TMg3Szj…"` |
| `id` | string | 提供方调用 id(较新) | `"<id>"` |
| `namespace` | string | MCP / 内置组的工具命名空间 | `"mcp__codegraph"`、`"multi_agent_v1"`、`"mcp__engram"` |
| `metadata` | object | 较新,例如 `{turn_id}` | `{}` |

### `function_call_output`

| 字段 | 类型 | 含义 |
|---|---|---|
| `type` | `"function_call_output"` | 判别符 |
| `call_id` | string | **匹配发起的 `function_call.call_id`**(不重复 `name`) |
| `output` | string(采样文件 100%)\| 结构化 | 工具结果。官方已确认:线上形式是 `FunctionCallOutputPayload`,**要么**是一个纯字符串(`content`),**要么**是一个结构化内容项数组(`content_items`)—— 而非早期草稿描述的 `{output, metadata}` 对象。`custom_tool_call_output` 使用相同编码。“output 可以非字符串”的前提成立;但具体的 `{output, metadata}` 形状是错的。([models.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/models.rs)) |

### `custom_tool_call` / `custom_tool_call_output`(自由格式工具 — `apply_patch`、`js_repl`、…)

`custom_tool_call` 键:`type`、`name`、`input`(**不是** `arguments` — 一个自由格式字符串,
例如一个补丁主体)、`call_id`、`status`。`custom_tool_call_output` 键:`type`、`call_id`、
`output`(string)。

> **`custom_tool_call.name` 不限于 `apply_patch`。** 全语料库的名称分布发现两个自由格式
> 工具:`apply_patch`(37,621)**和 `js_repl`(139)** — 一个 JS 求值工具,其 `input` 是一段
> JS 代码而非补丁主体。所以这是通用的*自由格式工具*通道,而非 apply-patch 通道。**Engram 不
> 处理任何 `custom_tool_call*`** — 所有自由格式工具调用(`apply_patch`、`js_repl` 以及任何
> 未来的名称)都从规范化转录中丢弃,并被排除在 `toolCount` 之外。(证据:跨 2025–2026 语料库
> 的 jq `custom_tool_call` 名称直方图。)

### 图像工具 — `image_generation_call` / `image_generation_end` / `view_image_tool_call`

一个先前分类法遗漏的**第三种工具输出机制**(图像生成 + 图像查看)。它使用一个不同的 id 命名
空间:id 是 `ig_<hex>`(例如 `ig_0a0…`,约 53 个字符),**不是**函数调用的 `call_<rand>`
id。在 `response_item` 一侧铸造的 `ig_` id(`image_generation_call.id`)在 `event_msg` 一侧
被复用为 `call_id`(`image_generation_end.call_id`)— 这就是连接键。

| 记录 / payload.type | 层级 | 键 | 含义 |
|---|---|---|---|
| `image_generation_call` | L2 `response_item` | `{type, id:ig_<hex>, status, revised_prompt, result}` | 模型的图像生成请求;`status` 例如 `generating`/`completed`;`revised_prompt` 是模型重写后的图像提示;`result` 是(base64/blob)输出容器 |
| `image_generation_end` | L2 `event_msg` | `{type, call_id:ig_<hex>, status, revised_prompt, result, saved_path}` | 运行时完成遥测;新增 `saved_path`(blob 落在 `generated_images/` 下的位置) |
| `view_image_tool_call` | L2 `event_msg` | `{type, call_id, path}` | *图像查看*工具 — 代理读取磁盘上 `path` 处的图像 |

> **Engram 一个都不处理** — 图像生成/查看对规范化转录和 `toolCount` 不可见。(证据:对
> `image_generation_call`/`image_generation_end`/`view_image_tool_call` 的 jq payload 检查;
> id 前缀检查确认 `ig_` ≠ `call_`。)

### `web_search_call` / `tool_search_call` / `tool_search_output`

- `web_search_call`:`{type, status}` 极简,或更丰富的 `{type, status, action}`,其中
  `action.type ∈ {search, open_page, find_in_page}`,带 `{query, queries, url}`。
- `tool_search_call`:`{type, call_id, status, execution, arguments}` — 此处 `arguments` 是
  一个**对象** `{query, limit}`(对比 `function_call.arguments` 是一个 JSON 字符串)。
- `tool_search_output`:`{type, call_id, status, execution, tools[]}`,带工具描述符。

### 调用↔结果的关联模型

在采样到的最大会话中已验证:`function_call` 中恰好 **3,565 个不同的 `call_id`**,
`function_call_output` 中也是 **3,565** 个 — 完美的 1:1 连接。配对就是简单的 `call_id`
相等。工具**名称**只在调用上;要给结果打标签,必须用 `call_id` 连接回去。

```json
{ "type":"response_item","payload":{ "type":"function_call",
    "name":"exec_command",
    "arguments":"{\"cmd\":[\"/bin/zsh\",\"-lc\",\"<CMD>\"],\"workdir\":\"<PATH>\",\"max_output_tokens\":10000,\"yield_time_ms\":250}",
    "call_id":"call_TMg3Szj<…>" } }
{ "type":"response_item","payload":{ "type":"function_call_output",
    "call_id":"call_TMg3Szj<…>","output":"<STDOUT/RESULT — redacted>" } }
```

```json
// MCP-namespaced function_call
{ "type":"response_item","payload":{ "type":"function_call",
    "name":"codegraph_explore","namespace":"mcp__codegraph",
    "arguments":"{\"query\":\"<QUERY>\"}","call_id":"call_Xja1jnx<…>" } }
```

```json
// custom_tool_call (apply_patch) — uses `input`, not `arguments`
{ "type":"response_item","payload":{ "type":"custom_tool_call",
    "name":"apply_patch",
    "input":"*** Begin Patch\n*** Update File: <PATH>\n<DIFF>\n*** End Patch",
    "call_id":"call_<…>","status":"completed" } }
```

**错误标志与遥测。** 内置工具错误表现为非零的 `exec_command_end.exit_code` 或
`patch_apply_end.success=false`;MCP 错误表现在 `mcp_tool_call_end.result` 中,它是一个
Rust-`Result` 标记联合:`{"Ok":{"content":[{"type":"text",…}],"is_error":null}}` **或**
`{"Err":"<error string>"}`。

### Review 模式 — `entered_review_mode` / `exited_review_mode`

Codex 内置的代码评审功能用两条 `event_msg` 记录框住一轮评审。
`entered_review_mode.target` 按 `target.type` **多态**,而
`exited_review_mode.review_output` 承载一个**结构化的代码评审 payload**(一个 findings 数组),
而非自由文本。

| 记录 / payload.type | 键 | 说明 |
|---|---|---|
| `entered_review_mode` | `{type, target, user_facing_hint}` | `target` 多态:`{type:"uncommittedChanges"}` \| `{type:"custom", instructions}` \| `{type:"baseBranch", branch}` \| `{type:"commit", sha, title}`(观察到的计数:9 / 8 / 3 / 6)。 |
| `exited_review_mode` | `{type, review_output}` | `review_output` = `{overall_correctness, overall_confidence_score, overall_explanation, findings[]}`。 |
| `review_output.findings[]` | `{title, body, priority, confidence_score, code_location}` | **每条 finding 的结构化评审数据** — `priority` int、`confidence_score` float、`code_location` 是一个 `file:line` 引用。 |

> **Engram 把两个 review-mode 事件都丢弃** — 结构化的 `findings[]`(可以说是整个 rollout 中
> 最丰富的派生产物)对 Engram 不可见。(证据:jq payload 检查 — `entered_review_mode` 键
> `[target, type, user_facing_hint]`,带 4 种不同的 `target.type` 形状;
> `exited_review_mode.review_output.findings[]` 键
> `[body, code_location, confidence_score, priority, title]`。)

**Engram 的工具处理。** `function_call` → 一条 `tool` 角色消息 `"<name> <args(truncated
500)>"`,在 `toolCount` 中**计一次**。`function_call_output` → 一条 `tool` 角色消息(输出
截断 2000),**不重复计数**(避免翻倍)。适配器**不**连接 调用↔输出;它们把每个作为单独的
消息发出。`custom_tool_call*`、`web_search_call`、`tool_search_*` 以及所有 `event_msg` 工具
遥测都被丢弃。

---

## 推理 / 思考

推理(思维链)存储为 `response_item.payload.type == "reasoning"`。真实的 CoT 通常是
**加密的**;只有启用 reasoning-summary 时才会出现明文摘要。

| 字段 | 类型 | 含义 | 何时存在 |
|---|---|---|---|
| `type` | `"reasoning"` | 判别符 | 始终 |
| `encrypted_content` | string(不透明加密 blob,观察到 `gAAAAAB…` 前缀) | 不透明的加密 CoT blob。官方已确认:源码仅将其类型标注为 `Option<String>`,**未**声明任何加密方案 —— “Fernet 风格”标签与 `gAAAAAB` 前缀均为观察推断,而非源码所述。([models.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/models.rs)) | 几乎总是 |
| `summary` | `{type:"summary_text", text}` 数组(L3) | 明文推理摘要 | 始终存在,常为空 `[]` |
| `content` | array | 遗留的原始推理块(实际为空) | 仅遗留键组合 |
| `metadata` | object `{turn_id}` | 把推理关联到它的回合 | 较新 |
| `id` | string(`rs_…`) | 服务端推理 id | 最新(2026 年 6 月) |

观察到的键组合(按频率排序):`[encrypted_content, summary, type]`(最常见)、
`[encrypted_content, metadata, summary, type]`、`[content, encrypted_content, summary, type]`
(遗留)、`[encrypted_content, id, metadata, summary, type]`(最新)。

```json
// reasoning, encrypted only (most common)
{ "type":"response_item","payload":{
    "type":"reasoning","summary":[],"encrypted_content":"gAAAAABqIEApny6G7M8X<…>" } }
```
```json
// reasoning with plaintext summary + metadata (newer)
{ "type":"response_item","payload":{
    "type":"reasoning",
    "summary":[ { "type":"summary_text","text":"<REASONING SUMMARY — redacted>" } ],
    "encrypted_content":"gAAAAAB<…>",
    "metadata":{ "turn_id":"019ee4ad-7753-7311-b6cb-12d0aeabce2a" } } }
```
```json
// newest (Jun 2026) — adds id
{ "type":"response_item","payload":{
    "type":"reasoning","id":"rs_02a<…>","summary":[],
    "encrypted_content":"gAAAAAB<…>","metadata":{ "turn_id":"<uuid>" } } }
```

还存在一条**遗留**的明文路径,位于 `event_msg.payload.type == "agent_reasoning"`
(`{type, text}`);现代 Codex 改为在 `response_item` 内部加密推理。

> **Engram 丢弃所有推理。** 两个适配器都不处理 `reasoning` 或 `agent_reasoning` —
> `message(from:)` 的 switch 只匹配 `message`/`function_call`/`function_call_output`,
> 因此推理对 Engram 的转录、搜索和计数都不可见。

---

## Token 用量与成本

### `token_count` 事件(权威用量来源)

`event_msg.payload.type == "token_count"`。已验证 `info` 键:
`[total_token_usage, last_token_usage, model_context_window]`;两个 `*_token_usage` 对象
共享 `[input_tokens, cached_input_tokens, output_tokens, reasoning_output_tokens, total_tokens]`。

| 字段 | 类型 | 含义 |
|---|---|---|
| `info` | object \| **null** | 用量容器;当 API 未返回用量(被中断 / 额度耗尽)时为 **null** — 适配器跳过这些 |
| `info.total_token_usage` | object | 整个会话的**累计运行总量**。`input_tokens` 增长到数百万(每回合都重发完整上下文)。**不要把它们相加。** |
| `info.last_token_usage` | object | **每回合(最近一次 API 调用)的用量** — 这是 Engram 求和的对象 |
| `info.model_context_window` | int | 模型最大上下文(例如 `258400`、`400000`) |
| `rate_limits` | object | 套餐与配额窗口(见下文) |

`*_token_usage` 子字段:

| 子字段 | 类型 | 含义 | Engram 用法 |
|---|---|---|---|
| `input_tokens` | int | 总提示 token(**包含**缓存) | `inputTokens = max(input_tokens − cached_input_tokens, 0)`(仅未缓存) |
| `cached_input_tokens` | int | 从缓存提供的提示 token | → `cacheReadTokens` |
| `output_tokens` | int | 补全 token(**包含**推理) | → `outputTokens` |
| `reasoning_output_tokens` | int | output 中属于推理/CoT 的子集 | **已观察到但未拆分** — 并入 `output_tokens` |
| `total_tokens` | int | `input + output` 便捷之和 | 不使用 |

`rate_limits` 键:`[limit_id, limit_name, primary, secondary, credits, individual_limit,
plan_type, rate_limit_reached_type]`。`primary`/`secondary` 是 `{used_percent,
window_minutes, resets_at(epoch s)}`;`credits` 是 `{has_credits, unlimited, balance}` 或
`null`;`plan_type` ∈ `{pro, premium, null}`。**`rate_limits` 中没有任何字段被 rollout
适配器消费。**

```json
{
  "timestamp": "2026-06-21T07:37:41.090Z",
  "type": "event_msg",
  "payload": {
    "type": "token_count",
    "info": {
      "total_token_usage": { "input_tokens": 33804, "cached_input_tokens": 2432, "output_tokens": 815, "reasoning_output_tokens": 516, "total_tokens": 34619 },
      "last_token_usage":  { "input_tokens": 33804, "cached_input_tokens": 2432, "output_tokens": 815, "reasoning_output_tokens": 516, "total_tokens": 34619 },
      "model_context_window": 258400
    },
    "rate_limits": {
      "limit_id": "codex", "limit_name": null,
      "primary":   { "used_percent": 1.0, "window_minutes": 300,   "resets_at": 1782044976 },
      "secondary": { "used_percent": 6.0, "window_minutes": 10080, "resets_at": 1782613776 },
      "credits": null, "individual_limit": null, "plan_type": "pro", "rate_limit_reached_type": null
    }
  }
}
```

```json
// info:null variant (no usage returned) — tokenCountUsage returns nil, event skipped
{ "type":"event_msg","payload":{ "type":"token_count","info":null,
    "rate_limits":{ "limit_id":"premium","limit_name":null,"primary":null,"secondary":null,
      "credits":{"has_credits":false,"unlimited":false,"balance":"0"},
      "individual_limit":null,"plan_type":null,"rate_limit_reached_type":null } } }
```

### Engram 的 token 提取(TS + Swift 一致)

`tokenCountUsage()`(`codex.ts` L297-328;`CodexAdapter.swift` L518-545):
1. 匹配 `event_msg` → `token_count` → `info.last_token_usage`(不是 `total_token_usage`)。
2. `inputTokens = max(input_tokens − cached_input_tokens, 0)`、`outputTokens = output_tokens`、
   `cacheReadTokens = cached_input_tokens`、`cacheCreationTokens = 0`(Codex 没有 cache-write
   指标)。
3. 若这四个都为零则丢弃该事件。

归属(`streamMessages`,`codex.ts` L184-265;`CodexAdapter.swift` L419-449):每个
`token_count` 用量被附加到**待定的非用户(assistant/tool)消息**上。一条消息之前的多个
`token_count` 事件由 `mergeUsage` 求和。`pendingUsageCameFromTokenCount` 防止用 token-count
数据覆盖真实的 assistant `payload.usage`。净效果:**每回合用量在整个会话中累加** → 得到一个
正确的总量,而不会出现 `total_token_usage` 的重复计数。

### 成本如何派生

成本是一条**仅 TypeScript 参考**的路径:`src/core/pricing.ts` `MODEL_PRICING`(每 100 万
token 的美元价,字段 `input/output/cacheRead/cacheWrite`),`getModelPrice()` 做精确 → 最长
前缀匹配。索引器累积 `inputTokens/outputTokens/cacheReadTokens/cacheCreationTokens` 并持久化
到 `session_costs`;`get_costs` 按 model/source/project/day 分组对 `cost_usd` 求和。

> **成本盲点(真实存在)。** `MODEL_PRICING` 对这些 rollout 中实际使用的 Codex 模型**没有
> 条目**(`gpt-5.5`、`gpt-5.4`、`gpt-5.3-codex`、`gpt-5.4-mini`、`gpt-5.3-codex-spark`、
> `gpt-5.1-codex-mini`)。前缀匹配器不会把 `gpt-5.*` 映射到任何 `gpt-4*`/`o*` 条目 →
> **当前 Codex 会话成本为零**。`reasoning_output_tokens` 也从未单独计价。按 CLAUDE.md,TS
> 定价仅供参考;Swift 产品是否有自己的定价路径尚未验证。

---

## Subagent / 父子 / 派发

Codex 有**两个互不相关的“subagent”概念**。Engram 目前只消费第一个。

### (A) Claude Code 的外部派发(Engram Layer-1b)— Engram 唯一使用的那个

当 Claude Code 把 Codex 作为子代理派发时,**唯一的磁盘信号**是
`session_meta.originator == "Claude Code"`。该会话在 `thread_spawn_edges` 中**缺席**
(已验证)。Engram 的规则(两个适配器):

```
effectiveRole = explicit agent_role ?? (originator is Claude Code ? "dispatched" : nil)
```

- TS(`codex.ts` L121-126):严格精确比较 `originator === 'Claude Code'`。
- Swift(`CodexAdapter.swift` L322-324 → `OriginatorClassifier.isClaudeCode`,
  `SessionAdapter.swift` L23-32):比较前先**规范化** — trim → 小写 → `_`→`-` → 空格→`-`,
  再 `== "claude-code"`。因此 `"Claude Code"`、`"claude_code"`、`"CLAUDE-CODE"` 都匹配。

> **TS vs Swift 差异:** 一个 `originator: "claude_code"` 或 `"claude-code"` 的会话会被
> **Swift**(产品)判为派发,但不会被 **TS**(参考)判为派发。这可能导致 Swift 索引结果与
> 参考 TS 测试不匹配。以 Swift 产品为准。

下游(`src/core/db/maintenance.ts` `backfillCodexOriginator` L365-410):一个被派发的 Codex
会话获得 `agent_role='dispatched'`、**`tier='skip'`** 和 `link_checked_at=NULL`,从而重新进入
父级评分。`readCodexOriginator()` 只读取第一行 JSONL。净效果:一个由 Claude-Code 派发的 Codex
rollout 被隐藏(tier skip),通过其 Claude Code 父级访问,并被排除在独立显示之外。

### (B) Codex 的**原生** subagent spawn 树(`multi_agent_version: "v1"`)— Engram 消费(子级一侧)

Codex 自己的多代理功能会派生子线程(角色 `explorer`/`worker`/`awaiter`/`default`,外加
第三方 `lazycodex-*`/`metis`)。它在 rollout + 数据库中被**冗余地记录在三处**:

1. `session_meta.parent_thread_id`(payload 顶层)。
2. `session_meta.source` 作为一个 JSON 对象(多态的 source):
   `{"subagent":{"thread_spawn":{"parent_thread_id","depth","agent_path","agent_nickname","agent_role"}}}`。
   一种更简单的形式 `{"subagent":"review"}` 标记 review subagent。
3. `state_5.sqlite.thread_spawn_edges` — 权威的父→子图。

**Engram 消费方:** `StartupBackfills.backfillCodexNativeParents` 从 rollout 第一行读取 (1)
与 (2)(版本门控的启动回填;`link_source = 'path'`)。**不**读取 (3) 或下方父级一侧的
`collab_*` 事件。深度 `> 1` 与 skip 级父级会被拒绝,以保持子会话可达。见
`docs/codex-native-parentage-design-2026-07.md`。

`parent_thread_id` 出现**两次**(顶层 *和* 嵌套在 `source.subagent.thread_spawn` 中),
两者相等,都馈入 `thread_spawn_edges`。

#### (B-4) `collab_*` 事件家族 — 原生派生在**父级一侧**的 rollout 记录

上面“三处冗余”列表遗漏了原生 spawn 图的**第四处**磁盘记录,而它是最可直接利用的:
**写入父级自己 rollout 文件中的 `collab_*` `event_msg` 家族。** `parent_thread_id` /
`source.subagent` / `thread_spawn_edges` 都是*子级一侧*的(子级记录它的父级是谁,或数据库
事后记录),而 `collab_agent_spawn_end` 在父级派生子级的那一刻就把关系**内联记录在父级的
JSONL 中** — 发送方→子级,带角色/昵称/提示/模型 — 因此仅凭父级文件就能读出完整的边,
**无需**触碰 SQLite 的 `thread_spawn_edges` 表。

这些事件由父级发起的原生多代理**工具调用**发出:`spawn_agent`(function_call)→
`collab_agent_spawn_end`;`wait_agent` → `collab_waiting_end`;`close_agent` →
`collab_close_end`;代理间消息 → `collab_agent_interaction_end`;`resume_agent` →
`collab_resume_end`。全语料库 function_call 名称计数:`spawn_agent` 2085、`close_agent`
1348、`wait_agent` 1269、`resume_agent` 3。

| `event_msg` payload.type | 键 | 方向与含义 |
|---|---|---|
| `collab_agent_spawn_end` | `{type, call_id, sender_thread_id, new_thread_id, new_agent_nickname, new_agent_role, prompt, model, reasoning_effort, status}` | **父→新子边**(`sender_thread_id`→`new_thread_id`)。内联携带被派生子级的角色/昵称/提示/模型。`status` 例如 `pending_init`。这是确定性的 Layer-1 父→子信号。 |
| `collab_waiting_end` | `{type, call_id, sender_thread_id, agent_statuses, statuses}` | 父级等待其子级;`statuses` 是一个映射 `{child_thread_id: {completed: "<child result text>"}}`(以及一个并行的 `agent_statuses`)。把子级完成结果带回父级转录。 |
| `collab_close_end` | `{type, call_id, sender_thread_id, receiver_thread_id, receiver_agent_nickname, receiver_agent_role, status}` | 父级关闭了一个子级(`sender`→`receiver`);`status` 是一个对象 `{completed: "<final child summary>"}`。 |
| `collab_agent_interaction_end` | `{type, call_id, sender_thread_id, receiver_thread_id, receiver_agent_nickname, receiver_agent_role, prompt, status}` | sender↔receiver 消息交换;`prompt` = 所问内容,`status.completed` = receiver 的回复。 |
| `collab_resume_end` | `{type, call_id, sender_thread_id, receiver_thread_id, receiver_agent_nickname, receiver_agent_role, status}` | 父级恢复一个暂停的子级;`status.completed` = 被恢复子级的输出。(罕见 — 语料库中 1 个) |

> **这是一个 Engram 未挖掘的确定性 Layer-1 父→子信号。** 对父级 JSONL 的一次遍历就能直接从
> `collab_agent_spawn_end` 得到它所派生的全部子级集合(sender→子边,带角色和昵称),无需读取
> SQLite — 严格地比子级一侧的 `parent_thread_id` 更易获得,且不依赖 `thread_spawn_edges` 表
> 是否存在。Engram 不读取任何 `collab_*` 事件(它们落入适配器的默认丢弃分支)。(证据:对
> `collab_agent_spawn_end`/`collab_waiting_end`/`collab_close_end`/`collab_agent_interaction_end`/
> `collab_resume_end` 的逐类型 payload 键检查;function_call 名称直方图 `spawn_agent`/`wait_agent`/`close_agent`/`resume_agent`。)

**`session_meta.source` 多态性**(旧/正常 CLI 中为字符串,subagent 中为对象)。
数据库 `threads.source` 分布(meta source 的逐字拷贝),按
`{"subagent":{"thread_spawn":{...}}}` 前缀分组:

| `source` | 计数 | 备注 |
|---|---|---|
| `{"subagent":{"thread_spawn":{...}}}` | **1561** | **最大的单一类别** — 原生派生的 subagent;每个 blob 仅在嵌套的 parent/depth/role 上不同,但都共享此前缀。**占全部 2510 个 thread 的 62%。** 恰好等于 `thread_spawn_edges` 行数(1561)。 |
| `vscode` | 461 | Codex VS Code / 桌面应用 |
| `cli` | 399 | 交互式终端 |
| `exec` | 65 | 无头 `codex exec` |
| `{"subagent":"review"}` | 18 | review subagent(简单字符串形式;不在 `thread_spawn_edges` 中) |
| `unknown` | 6 | 未分类 |

> 此存储**以 subagent 为主**:`{subagent:{thread_spawn}}` 形式是占主导的单一类别(1561),
> 而非分散的长尾。任何把 `source` 当作小型字符串枚举的天真消费者都会错误分类多数行。(证据:
> `sqlite3 state_5.sqlite` 对 `source` 前缀 GROUP BY;`thread_spawn_edges` COUNT = 1561。)

> **两个 Engram 适配器都不读取 `meta.source`。** 丰富的 `{subagent:{thread_spawn:{...}}}`
> parent/depth/role 图目前**未被挖掘** — 这是一个超出 `parent_thread_id`、Engram 本可消费的
> 确定性 Layer-1 信号。

```json
// session_meta — subagent (NEW format) — key structure intact, content redacted
{
  "timestamp": "2026-06-21T06:06:38.238Z",
  "type": "session_meta",
  "payload": {
    "id": "019ee8c9-c5b3-78f0-bdc2-ab4c8e024293",
    "parent_thread_id": "019ee02d-c140-7813-8897-56f02fb68e88",
    "timestamp": "2026-06-21T06:06:38.051Z",
    "cwd": "/Users/<user>/<project>",
    "originator": "Codex Desktop",
    "cli_version": "0.142.0-alpha.6",
    "source": { "subagent": { "thread_spawn": {
        "parent_thread_id": "019ee02d-c140-7813-8897-56f02fb68e88",
        "depth": 1, "agent_path": null, "agent_nickname": "<name>", "agent_role": "explorer" } } },
    "thread_source": "subagent",
    "agent_nickname": "<name>", "agent_role": "explorer",
    "model_provider": "openai",
    "base_instructions": { "text": "<system prompt — redacted>" },
    "multi_agent_version": "v1",
    "git": { "commit_hash": "<sha>", "branch": "main" }
  }
}
```

> **合成器必须保持的区分:** `thread_spawn_edges` 只记录概念 (B)(Codex 内部派生),从不记录
> 概念 (A)(Claude Code 派发)。Engram 只消费 (A)。因此 Codex 原生 subagent
> (explorer/worker/awaiter)如今很可能被 Engram 当作独立会话呈现。

---

## 摘要 / 压缩

当上下文窗口被填满时,Codex 进行压缩。这会产生**两层上配对的两条记录**(扫描中已验证 1:1):

### `compacted` — **顶层(L1)记录**(持久化记录)

`payload` 键:`message`、`replacement_history`,以及(较新)`window_id`,然后(最新)
`window_number`。对每条 `compacted` 记录的全语料库扫描发现**三个键集代次**:
`[message, replacement_history]` × **2050**、`+ window_id` × **113**、以及
`+ window_id + window_number` × **55** — 即最新 CLI 同时发出 `window_id` 和
`window_number`。(证据:jq 全语料库 `compacted` 键集直方图:2050 / 113 / 55。)

官方已确认 —— 并附更正:权威的 `CompactedItem` 结构体
([protocol.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs))
为 `{ message: String, replacement_history: Option<Vec<ResponseItem>>, window_number:
Option<u64>, first_window_id: Option<String>, previous_window_id: Option<String>, window_id:
Option<String> }`。本文早期草稿中这两个 window 字段的**类型搞反了**:`window_number` 才是
整数(`u64`)单调计数器;`window_id` 是一个 **UUIDv7 字符串**(该上下文窗口的标识),而非
整数计数器。此外还有两个超出键集直方图的字段:`first_window_id` 和 `previous_window_id`
(均为 UUIDv7 字符串,构成窗口链)。下方磁盘示例中的 `"window_id": 1` 反映的是**更旧的 CLI
代次**;现行源码使 `window_id` 为 UUID 字符串,而 `window_number` 为整数。

| 字段 | 类型 | 含义 | 是否可选? |
|---|---|---|---|
| `message` | string | 压缩/摘要文本(常为 `""`;摘要往往存在于 `replacement_history` 的 developer 回合中) | 必需 |
| `replacement_history` | 消息对象数组(`Option<Vec<ResponseItem>>`) | **替换先前回合的重建上下文**。每个条目是 `{type:"message", role, content:[{type:"input_text", text}]}`。角色包括 `user`、`developer`、`assistant`。 | 源码中为可选 |
| `window_number` | int(`u64`) | **整数单调压缩计数器**(1、2、…)—— 真正的代次计数器 | 仅最新(55 条记录) |
| `window_id` | string(UUIDv7) | **该上下文窗口的 UUIDv7 标识** —— 是字符串 id,而非整数计数器(更旧的磁盘样本显示为 `1`,属较早 CLI 代次) | 较新(2026-06+);更早缺失 |
| `first_window_id` | string(UUIDv7)\| null | 压缩链中的第一个窗口(源码确认;不在语料库键集直方图中) | 源码字段 |
| `previous_window_id` | string(UUIDv7)\| null | 压缩链中的上一个窗口(源码确认) | 源码字段 |

```json
{
  "timestamp": "2026-06-21T02:37:49.013Z",
  "type": "compacted",
  "payload": {
    "message": "",
    "window_id": 1,
    "replacement_history": [
      { "type": "message", "role": "user",
        "content": [ { "type": "input_text", "text": "<earlier user msg — redacted>" } ] },
      { "type": "message", "role": "developer",
        "content": [ { "type": "input_text", "text": "<permissions block — redacted>" },
                     { "type": "input_text", "text": "<more — redacted>" } ] }
    ]
  }
}
```

### `context_compacted` — `event_msg` 内部的**嵌套(L2)**(标记)

一个纯标记 — `payload` 只是类型标签。已验证:`{'type': 'context_compacted'}`,无主体。

```json
{ "timestamp":"2026-03-03T08:02:58.056Z","type":"event_msg","payload":{ "type":"context_compacted" } }
```

### 会话如何跨压缩继续

压缩在 token 流中可见:压缩之后,紧接着的下一回合的 `last_token_usage.input_tokens` 降到
**0**,然后从一个很小的基数攀升,而 `total_token_usage.input_tokens` 保持其终身累计的攀升。
会话**在同一个 rollout 文件中**继续(相同 UUID);实时模型上下文被重置,但文件被继续追加。

> **Engram 缺口。** 两个适配器都不处理 `compacted` 或 `context_compacted`。
> `replacement_history` 回合(可能包含压缩之前的 user/assistant 内容)对 Engram 的转录、搜索和
> `messageCount` **不可见**。一个被大量压缩的长会话只显示其压缩之后的实时消息。跳过*重复的*
> 压缩上下文可以说是正确的,但仅在 `replacement_history` 中幸存的压缩前回合对 Engram 是数据
> 丢失。

---

## (仅 Codex)SQLite 存储

> Claude Code 没有 SQLite 会话存储;**Codex 有。** 本节记录它。rollout JSONL 对*内容*权威;
> SQLite 对*状态 / 索引 / 关系 / 派生数据*权威。关联:`threads.id == rollout 文件名 UUID ==
> session_meta.payload.id`,且 `threads.rollout_path` 指向磁盘上的 `.jsonl`。

### 数据库清单(现行 vs 遗留)

| 路径 | 大小 | 状态 | 角色 |
|---|---|---|---|
| `~/.codex/state_5.sqlite` | 16 MB | **现行** | 线程目录 + agent-job + spawn 图(迁移 **39**,2510 threads) |
| `~/.codex/memories_1.sqlite` | 940 KB | **现行** | 记忆提取管线 |
| `~/.codex/goals_1.sqlite` | 60 KB | **现行** | 长运行线程目标 |
| `~/.codex/logs_2.sqlite` | **1.3 GB** | **现行** | 结构化 Rust 应用/trace 日志 |
| `~/.codex/sqlite/state_5.sqlite` | 15 MB | **遗留** | 更旧代次(迁移 **35**,2267 threads,无 `recency_at`) |
| `~/.codex/sqlite/memories_1.sqlite` | 40 KB | **遗留** | 迁移 1 |
| `~/.codex/sqlite/goals_1.sqlite` | 24 KB | **遗留** | 迁移 1 |
| `~/.codex/sqlite/logs_2.sqlite` | 29 MB | **遗留** | 迁移 2 |
| `~/.codex/sqlite/codex-dev.db` | 36 KB | **遗留 / 开发** | 桌面 app-server(inbox、automations)— 不是会话存储 |

**代次后缀 vs 迁移计数。** `_N` 文件名后缀是一个 **schema 家族代次**(硬重置 → 新文件)。每个
文件内部的 `_sqlx_migrations` 表(`version, description, installed_on, success, checksum,
execution_time`)是增量账本。`state_5` 账本是该机制演进的变更日志 — 标志性条目:
`1 threads`、`2 logs` → `23 drop logs`(日志拆分到 `logs_N`),`6/16 memories` →
`35 drop memory tables`(拆分到 `memories_1`),`29 thread goals` → `34 drop thread goals`
(拆分到 `goals_1`),`21 thread spawn edges`、`24 remote control enrollments`、
`38 external agent config imports`、`39 threads recency at`(最新;遗留 DB 缺少
`recency_at`/`recency_at_ms` 列 — 即迁移 39 的确切增量)。这就是*为什么*有四个 DB 文件:
体量庞大(logs)或独立版本化(memories、goals)的表被从 `state_5` 中切出到它们自己的带代次
后缀的文件中。

### `state_5.sqlite`(核心)

表:`threads`、`thread_dynamic_tools`、`thread_spawn_edges`、`agent_jobs`、
`agent_job_items`、`backfill_state`、`remote_control_enrollments`、
`external_agent_config_imports`、`_sqlx_migrations`。

#### `threads` — rollout 会话索引(2,510 行;每个 rollout 一行)

| 列 | 类型 | 含义 | 示例 |
|---|---|---|---|
| `id` | TEXT PK | thread UUID = rollout 文件名 UUID = `session_meta.id` | `019ee91c-8298-7c32-...` |
| `rollout_path` | TEXT NOT NULL | rollout `.jsonl` 的绝对路径(磁盘↔DB 连接) | `~/.codex/sessions/2026/06/21/rollout-...jsonl`(或 `archived_sessions/...`) |
| `created_at` / `updated_at` | INTEGER(unix s) | 开始 / 最后活动 | `1782027420` |
| `created_at_ms` / `updated_at_ms` | INTEGER | 毫秒精度镜像(由触发器自动填充,迁移 25) | `1782027420000` |
| `recency_at` / `recency_at_ms` | INTEGER(默认 0) | “最近”排序键,通过触发器从 `updated_at` 播种(迁移 39;遗留 DB 中缺失) | `1782027438` |
| `source` | TEXT NOT NULL | **多态**:纯字符串(`vscode`/`cli`/`exec`/`unknown`)或 JSON subagent 对象 — `session_meta.source` 的逐字拷贝 | `"vscode"` / `{"subagent":{"thread_spawn":{...}}}` |
| `model_provider` | TEXT NOT NULL | 提供方(2509 个 `openai`,1 个 `custom`) | `"openai"` |
| `model` | TEXT(可空) | 具体模型 | `gpt-5.5`(1302)、`gpt-5.4`(522)、`gpt-5.3-codex`(409)、`gpt-5.4-mini`(199)、`gpt-5.3-codex-spark`(23)、`gpt-5.1-codex-mini`(4)、NULL(51) |
| `reasoning_effort` | TEXT(可空) | `high`/`xhigh`/`low`/`medium`/NULL | `xhigh` |
| `cwd` | TEXT NOT NULL | 工作目录 | `/Users/<user>/<repo>` |
| `title` | TEXT NOT NULL | 自动生成的标题(镜像 `session_index.thread_name`) | `<title>` |
| `preview` | TEXT NOT NULL(默认 '') | 短预览;部分索引过滤 `preview <> ''`(可见行) | `<preview>` |
| `first_user_message` | TEXT NOT NULL(默认 '') | 缓存的首个用户提示 | `<prompt>` |
| `sandbox_policy` | TEXT NOT NULL | JSON:`{"type":"workspace-write",...}` / `managed` / `disabled` / `read-only` / `danger-full-access` | `{"type":"disabled"}` |
| `approval_mode` | TEXT NOT NULL | `never`(2422)/`on-request`(88) | `never` |
| `tokens_used` | INTEGER(默认 0) | 该线程的累计 token | `679270` |
| `has_user_event` | INTEGER(默认 0) | bool:是否有真实用户交互 | `0` / `1` |
| `archived` / `archived_at` | INTEGER / INTEGER | 归档标志(5 行 =1)+ 时间 | `0` / null |
| `git_sha` / `git_branch` / `git_origin_url` | TEXT(可空) | 仓库上下文 | `main` |
| `cli_version` | TEXT NOT NULL(默认 '') | 写入它的 Codex 版本 | `0.141.0` |
| `agent_nickname` / `agent_role` | TEXT(可空) | subagent 身份(`explorer`871/`worker`293/`awaiter`214/`default`103/`lazycodex-*`/`metis`/empty 1006) | `Epicurus` / `explorer` |
| `agent_path` | TEXT(可空) | agent 定义路径 | null |
| `thread_source` | TEXT(可空) | `user`(238)/`subagent`(611)/NULL(1661) | `subagent` |
| `memory_mode` | TEXT NOT NULL(默认 'enabled') | 记忆资格:`enabled`(2092)/`polluted`(418) | `enabled` |

**索引**(为列表视图大量优化):`created_at`、`updated_at`、`created_at_ms`、`updated_at_ms`、
`recency_at_ms`、`archived`、`source`、`model_provider`,用于按项目排序最近的复合索引
`(archived, cwd, *_ms DESC, id DESC)`,以及用于“仅可见线程”的**部分索引** `WHERE preview <> ''`。
**触发器**在插入/更新时自动填充 `*_ms` 和 `recency_at`。

```json
// threads row (subagent), anonymized
{
  "id": "019ee8db-ef59-7cc0-8911-e47edb28f2c9",
  "rollout_path": "/Users/<user>/.codex/sessions/2026/06/21/rollout-2026-06-21T14-26-28-019ee8db-...jsonl",
  "created_at": 1782023188, "updated_at": 1782023395,
  "source": "{\"subagent\":{\"thread_spawn\":{\"parent_thread_id\":\"019ee02d-...\",\"depth\":1,\"agent_path\":null,\"agent_nickname\":\"Epicurus\",\"agent_role\":\"default\"}}}",
  "model_provider": "openai", "model": "gpt-5.5", "reasoning_effort": "medium",
  "cwd": "/Users/<user>/<repo>", "title": "<title>",
  "sandbox_policy": "{\"type\":\"disabled\"}", "approval_mode": "never",
  "tokens_used": 1450054, "has_user_event": 0, "archived": 0,
  "git_sha": "f2fb1d69...", "git_branch": "main", "cli_version": "0.142.0-alpha.6",
  "agent_nickname": "Epicurus", "agent_role": "default",
  "memory_mode": "enabled", "thread_source": "subagent", "recency_at": 1782023188
}
```

#### `thread_spawn_edges` — subagent 父→子图(1,561 行)

```sql
CREATE TABLE thread_spawn_edges (
    parent_thread_id TEXT NOT NULL,
    child_thread_id  TEXT NOT NULL PRIMARY KEY,   -- a child has exactly one parent
    status           TEXT NOT NULL                 -- closed(834) / open(727)
);
CREATE INDEX idx_thread_spawn_edges_parent_status ON thread_spawn_edges(parent_thread_id, status);
```

| 列 | 类型 | 含义 |
|---|---|---|
| `parent_thread_id` | TEXT NOT NULL | 派生(父)线程 `id` |
| `child_thread_id` | TEXT PK | 被派生(子)subagent 线程 `id` |
| `status` | TEXT | `closed`(834) / `open`(727) — 推断的存活 vs 完成的派生关系 |

**已验证引用完整性:** 全部 1561 条边的两个端点都在 `threads` 中。顶层父级扇出很广(一个父级
→ 126 个子级)— 派发 subagent 集群的编排者。`threads.source` JSON 内部的 `parent_thread_id`
对同一子级等于 `thread_spawn_edges.parent_thread_id`(冗余编码)。**`review` subagent
(`{"subagent":"review"}`,18)不在 `thread_spawn_edges` 中** — 它们的来源只有 `source`
字符串标记。所以一个完整的 subagent 拓扑需要读取 `thread_spawn_edges` + `source` 标记,而不仅
是 `thread_source`。

#### `agent_jobs` / `agent_job_items` — 异步批量代理执行(此处 0 行)

“对一份输入 CSV 运行一个代理”的功能;每一行 → 在一个派生线程上运行一次代理。

`agent_jobs`:`id` PK、`name`、`status`、`instruction`、`output_schema_json`、
`input_headers_json`、`input_csv_path`、`output_csv_path`、`auto_export`(默认 1)、
`created_at`/`updated_at`/`started_at`/`completed_at`、`last_error`、`max_runtime_seconds`。

`agent_job_items`:PK `(job_id, item_id)`(FK → `agent_jobs(id)` CASCADE)、`row_index`、
`source_id`、`row_json`、`status`、`assigned_thread_id`(处理该行的派生线程 → 链接到
`threads`)、`attempt_count`、`result_json`、`last_error`、时间戳。

#### `thread_dynamic_tools` — 每线程工具注册表(106 行)

PK `(thread_id, position)`(FK → `threads` CASCADE)、`name`、`description`、`input_schema`
(JSON)、`defer_loading`(默认 0,迁移 19)、`namespace`(可空,迁移 26)。
示例:`read_thread_terminal`、`automation_update`。

#### 单例 / 控制表

- `backfill_state`(CHECK id=1,单行):rollout→DB 回填游标 —
  `status, last_watermark, last_success_at, updated_at`。观察到 `status='complete'`,
  `last_watermark='sessions/2026/02/25/rollout-...'`。
- `remote_control_enrollments`(1 行):web/桌面配对 —
  `websocket_url, account_id, app_server_client_name`(PK)、`server_id, environment_id,
  server_name, updated_at, remote_control_enabled`(迁移 37)。
- `external_agent_config_imports`(0 行,迁移 38):`import_id` PK、`completed_at_ms`、
  `successes` TEXT、`failures` TEXT(很可能是 JSON 数组 — 未采样)。

### `memories_1.sqlite` — 记忆提取管线

两张表。一个**两阶段管线**:stage1 提取每线程记忆 → 被选中 → 全局合并。

`stage1_outputs`(83 行):`thread_id` PK、`source_updated_at`(陈旧检查)、
`raw_memory`、`rollout_summary`、`rollout_slug`(可空,迁移 9)、`generated_at`、
`usage_count`、`last_usage`、`selected_for_phase2`(默认 0,迁移 17)、
`selected_for_phase2_source_updated_at`。

`jobs`(97 行):一个租约式工作队列 — PK `(kind, job_key)`(`job_key` = thread_id)、
`status`(`done`86/`error`10)、`worker_id`、`ownership_token`、
`started_at/finished_at/lease_until/retry_at`、`retry_remaining`、`last_error`、
`input_watermark/last_success_watermark`。`kind` ∈ `{memory_stage1, memory_consolidate_global}`。

### `goals_1.sqlite` — 长运行线程目标(`thread_goals`,57 行)

`thread_id` PK、`goal_id`、`objective`、`status` CHECK ∈
`{active, paused, blocked, usage_limited, budget_limited, complete}`、`token_budget`、
`tokens_used`(默认 0;观察到高达 34M)、`time_used_seconds`(高达 ~107k s ≈ 30 h)、
`created_at_ms`/`updated_at_ms`。这些是多天的自主“持续朝 X 努力”的目标。

### `logs_2.sqlite` — 结构化应用/trace 日志(1.3 GB;仅 schema + COUNT)

单张大 `logs` 表(~419k 行,AUTOINCREMENT):`id` PK、`ts`(unix s)、`ts_nanos`、
`level`(`INFO`/`TRACE`/`DEBUG`/`WARN`/`ERROR`)、`target`、`feedback_log_body`(消息主体,
可空)、`module_path`/`file`/`line`(可空)、`thread_id`(可空;连接到 `threads`)、
`process_uuid`(`pid:<pid>:<uuid>`,迁移 10)、`estimated_bytes`(保留/剪枝,迁移 12)。
索引:`idx_logs_ts`、`idx_logs_thread_id`、`idx_logs_thread_id_ts`,以及一个**部分**
`idx_logs_process_uuid_threadless_ts WHERE thread_id IS NULL`。这是可观测性/诊断,不是会话
内容 — 对重建最无用,因此有大小警告。**永远不要 dump 它;只用 `.schema` 和 `LIMIT`/`COUNT`。**

### `sqlite/codex-dev.db` — 桌面开发 DB(超出范围)

不同的 schema:`automation_runs`、`automations`、`inbox_items`、
`local_app_server_feature_enablement`。不是会话/rollout 机制的一部分。

### Rollout JSONL ↔ SQLite 映射(连接层)

`threads` 行从 `session_meta` 物化:

| `session_meta.payload` 字段 | → `threads` 列 | 备注 |
|---|---|---|
| `id` | `id`(PK) | == 文件名 UUID |
| `cwd` | `cwd` | |
| `cli_version` | `cli_version` | |
| `model_provider` | `model_provider` | |
| `source` | `source` | 逐字拷贝(字符串或 JSON) |
| `thread_source` | `thread_source` | `user`/`subagent` |
| `agent_nickname` / `agent_role` | `agent_nickname` / `agent_role` | 仅 subagent |
| `parent_thread_id` | → `thread_spawn_edges.parent_thread_id` | 驱动 spawn 图 |
| `git.commit_hash` / `git.branch` | `git_sha` / `git_branch` | 嵌套的 `git` 对象 |
| `originator` | (不是列;仅 JSONL) | 例如 `Codex Desktop`、`Claude Code` — Engram 使用它 |
| `multi_agent_version`、`base_instructions` | (不存储) | 仅 JSONL |

> 边缘情况:JSONL `session_meta` 可能省略 `timestamp`(TS 回退到 `lastTimestamp`/mtime;
> Swift 要求它存在,缺失则解析失败),但 DB `created_at` 始终被填充 — 因此在边缘情况下 DB 是更
> 可靠的开始时间来源。

---

## 辅助文件

### `history.jsonl` — 跨会话用户输入历史(3.9 MB;扁平结构,不是信封)

| 字段 | 类型 | 含义 | 示例 |
|---|---|---|---|
| `session_id` | string(UUID) | 所属会话;连接到 rollout/`threads` | `"019ee858-92b6-7853-ba71-074b9c042711"` |
| `ts` | int(Unix **秒**) | 输入提交的时间 | `1757248180` |
| `text` | string | 用户的原始提示文本(完整,未截断) | `"<prompt — redacted>"` |

```json
{ "session_id":"019ee858-92b6-7853-ba71-074b9c042711", "ts":1757248180, "text":"<user prompt>" }
```

> 注意:少数行使用遗留的 **UUIDv4** `session_id`(早于 v7 的会话,其 rollout 文件可能不存在于
> v7 树中)。**Engram 不读取 `history.jsonl`** — 它是 Codex TUI 的上箭头回溯日志。

### `session_index.jsonl` — id → 人类标题(100 KB)

| 字段 | 类型 | 含义 | 示例 |
|---|---|---|---|
| `id` | string(UUIDv7) | 会话 id(连接到 rollout/`threads`) | `"019ca318-d9f3-7a12-a4f1-0352b065e5b6"` |
| `thread_name` | string | 人类/自动标题(可含 CJK;可能乱码) | `"CIP_Pro_Rebuild"` |
| `updated_at` | string(ISO UTC,µs) | 最后标题更新 | `"2026-03-01T03:06:53.593906Z"` |

```json
{ "id":"019ca318-d9f3-7a12-a4f1-0352b065e5b6", "thread_name":"<title>", "updated_at":"2026-03-01T03:06:53.593906Z" }
```

> 仅追加的标题索引,镜像 `threads.title`。**Engram 不读取它** — Engram 从首个用户消息派生其
> 摘要(`firstUserText`,上限 200 字符),因此 Engram 的标题与 Codex 自己的不同。

### 其他辅助目录(非会话内容)

`attachments/`、`generated_images/`(图像消息引用的 blob),外加配置/身份文件
(`config.toml`、`auth.json`、`AGENTS.md`、`installation_id`)。像 Gemini 那样的 sidecar
`{sessionId}.engram.json` 对 Codex **不存在** — Codex 派发纯粹从 `session_meta.originator`
检测。

---

## Engram 映射

具体表:源记录/字段 → Engram `Session`/`Message` 字段 → 适配器 file:line。

| 磁盘源(record.field) | Engram 字段 / 行为 | TS `codex.ts` | Swift `CodexAdapter.swift` |
|---|---|---|---|
| `session_meta.payload.id` | `SessionInfo.id` — **缺失/为空则拒绝** | L119-120 | L316 |
| `session_meta.payload.timestamp` | `startTime`(TS 回退:lastTimestamp → file mtime;Swift 要求它存在) | L129-134 | L317, L330 |
| 最后一行 `.timestamp` | `endTime`(最后一个携带 timestamp 的行) | L74-76, L139 | L275-277, L330 |
| `session_meta.payload.cwd` | `cwd` | L140 | L331 |
| `session_meta.payload.originator` | `originator`;驱动派发 | L122, L151 | L323, L344 |
| `session_meta.payload.agent_role` | `agentRole`(优先级高于 originator) | L121, L125 | L322, L324 |
| `originator == "Claude Code"`(无角色) | `agentRole = "dispatched"`(Layer-1b) | L125-126(精确匹配) | L324 经由 `OriginatorClassifier.isClaudeCode`(规范化) |
| (分类器) | 规范化 trim/lower/`_`→`-`/space→`-` 后 `== "claude-code"` | — | `SessionAdapter.swift` L23-32 |
| `response_item.payload.model` | `model`(真实 model id;首次出现) | L84-88 | L289-291 |
| `session_meta.payload.model` | 若无项级 model 则作 `model` 回退 | L141 | L333 |
| `response_item`/`message`/`user`(经 `extractText` 取文本) | 用户消息;`summary` = 首个用户文本(200) | L89-100, L360-382 | L294-305, L478-485, L604-618 |
| 用户文本系统注入剥离 | `<INSTRUCTIONS>`、`<environment_context>`、`<local-command-caveat>`、AGENTS.md、skills/plugins → `systemCount` | L93, L345-358 | L296-305, L563-602 |
| `response_item`/`message`/`assistant` | assistant 消息;`assistantCount` | L101-103, L207-230 | L306-307, L473-492 |
| `response_item`/`function_call`(`name`、`arguments` 500 截断) | `tool` 消息;`toolCount` +1;`toolCalls:[{name,input}]` | L104-108, L231-239 | L308-312, L493-501 |
| `response_item`/`function_call_output`(`output` 2000 截断) | `tool` 消息;**不**重复计数 | L240-249 | L502-512 |
| `response_item`/`message`/assistant `.usage` | 每条消息 `TokenUsage`(遗留/现代磁盘上缺失) | L216-228 | L491, L220-228(`JSONLAdapterSupport.usage`) |
| `event_msg`/`token_count`/`info.last_token_usage` | 每条消息 `TokenUsage`;`inputTokens=max(in−cached,0)`、`cacheReadTokens=cached` | L297-328 | L518-545 |
| token 用量归属 | 附加到待定的非用户消息;多个合并 | L184-265 | L419-449 |
| 发现根 | `sessions/` + 同级 `archived_sessions/` | L51-54 | L376-382 |
| 枚举 | TS glob `**/rollout-*.jsonl`;Swift 递归 `rollout-` 前缀 + `.jsonl`,不跟随符号链接 | L38-49 | L250-258 |
| 增量快速路径 | 最近 N(本地)天的每日根 `~/.codex/sessions/YYYY/MM/DD`(仅 sessions/;排除归档) | — | `SessionAdapterFactory.swift` `recentCodexAdapters` L31-51 |
| 注册 | `defaultAdapters()` / `recentActiveAdapters()` 中的 `CodexAdapter()` | — | `SessionAdapterFactory.swift` L8-11, L53-74 |
| `reasoning`、`custom_tool_call*`、`web_search_call`、`tool_search_*`、`turn_context`、`compacted`、所有非 `token_count` 的 `event_msg` | **丢弃**(默认分支) | (缺口) | `message(from:)` `default` L513-514 |
| `session_meta.source`、`parent_thread_id`、`forked_from_id`、`thread_source`、`git`、`base_instructions` | **不读取** | (缺口) | (缺口) |
| 任何 SQLite DB(`state_5`/`threads`/`thread_spawn_edges`/…) | **从不读取** — Engram 仅从 JSONL 重新派生 | (缺口) | (缺口) |

> 已验证:在所有 Codex 适配器文件上对 `state_5` / `.sqlite` / `thread_spawn` / `stage1` 的
> grep 一无所获(唯一的 `state_5` 命中是无关的 vendored swift-nio C 代码)。Engram 的 Codex
> 摄取是**仅 JSONL** 的,因此 Engram 的会话计数/标题/归档视图可能与 Codex 的 DB 驱动视图分歧。
>
> `codex-usage-probe.ts` 尽管名字如此,但**不**解析 rollout — 它通过一个无头 tmux 抓取
> `codex /status` 获取配额 %(`Usage: NN%` / `NN/MM`)。它对格式解析没有贡献。没有确认的
> Swift 产品等价物;`rate_limits` 数据在每个 `token_count` 事件中闲置未用。

---

## 坑、版本漂移与边缘情况

1. **文件名时间戳是本地时间,不是 UTC。** `rollout-2025-11-20T11-08-12-...` ↔ 内部
   `2025-11-20T03:08:12.198Z`(UTC+8 主机)。日期目录分桶也是本地的。Engram 的增量日根使用
   **本地**日历以匹配。
2. **分层混淆。** `compacted`(L1)≠ `context_compacted`(L2)。`message`/`reasoning`/
   `token_count` 是 L2,绝非 L1。`input_text`/`output_text`/`summary_text` 是 L3。
3. **`source` 是多态的**(字符串 vs 嵌套 subagent 对象),在 `session_meta` 和
   `threads.source` 中都是。天真的字符串消费者必须处理对象形式。
4. **`instructions` 与 `base_instructions` 是两个不同的字段,而非重命名。**
   官方已确认:遗留的 `instructions` 存储 `user_instructions`,该内容被**移动到了
   `TurnContext`**;`base_instructions` 是独立的基础/系统提示槽位。两者均在 v0.60 与 v0.14x
   之间发生变动(确切边界未锁定)。`git`、`agent_nickname`、`thread_source`、
   `parent_thread_id`、`multi_agent_version`、`agent_path` 都是后来的新增,在 0.60.1 中缺失。
   ([protocol.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs))
5. **文本键陷阱:** 值始终在 `text` 下,绝非 `input_text`/`output_text`。适配器在这些键上的
   回退对现代数据是死分支。
6. **TS 多块少捕获:** TS `extractText` 只返回第一个块;Swift 用 `\n\n` 连接所有块。多块用户
   消息确实存在。
7. **现代文件不携带 `response_item.payload.model` / `.usage`:** model 现在来自
   `turn_context`/DB(Engram 仅凭 JSONL 往往得到 `nil` model);用量仅来自
   `event_msg.token_count`。潜伏点:如果 Codex 重新加入内联用量,适配器会悄然优先使用它。
8. **TS vs Swift originator 匹配分歧**(精确 vs 规范化)— `claude_code`/`claude-code`
   originator 在 Swift 上派发但在 TS 上不派发。
9. **成本盲点:** `gpt-5.*`/`*-codex` 模型没有 `MODEL_PRICING` 条目,也不会前缀匹配到
   `gpt-4*` 条目 → 当前 Codex 会话成本为零。`reasoning_output_tokens` 从未单独计价。
10. **压缩不可见:** Engram 跳过 `compacted`/`context_compacted`,因此仅在
    `replacement_history` 中幸存的压缩前回合不在 Engram 的转录/搜索/`messageCount` 中。
11. **原生 subagent 图未挖掘:** `thread_spawn_edges` + `meta.source` 提供一个确定性的父→子图
    (explorer/worker/awaiter),但 Engram 一个都不读 — Codex 原生 subagent 很可能被当作独立
    会话呈现。
12. **`token_count.info` 可以是 `null`**(被中断/额度耗尽的回合)— 两个适配器都做 null 防护
    并跳过。
13. **`function_call_output.output` 的非字符串形式是 `content_items`,而非 `{output,
    metadata}`。** 官方已确认:线上 payload(`FunctionCallOutputPayload`)**要么**是纯字符串
    (`content`),**要么**是结构化内容项数组(`content_items`);`custom_tool_call_output`
    使用相同编码。在此 2025–2026 存储中 100% 为字符串的观察仍成立,但早期的 `{output,
    metadata}` 对象形状是错的。
    ([models.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/models.rs))
14. **两个 DB 位置:** 任何未来的 SQLite 读取器都必须以 `~/.codex/*.sqlite`(当前)为目标并
    忽略 `~/.codex/sqlite/`(遗留),通过 mtime 和 `_sqlx_migrations` `MAX(version)`(39 vs 35)
    区分。
15. **空的早期日期目录:** `2025/09` 和 `2025/10` 存在但零 rollout 文件;最早可读的 rollout 是
    `2025/11/20`(cli 0.60.1)— 最最早的 schema 变体未被捕获。
16. **`thread_goal_updated` 使用 camelCase** — 完整键是 `{type, goal, threadId, turnId}`
    (`goal`、`threadId`、`turnId` 全为 camelCase;只有 `type` 是普通的),而 schema 的其余部分
    是 snake_case — 很可能是不同的发出子系统。`turnId` 存在且此前未被记录。(证据:jq
    `thread_goal_updated` 键直方图 → 每条记录都恰好是 `[goal, threadId, turnId, type]`。)
    (web-checked 2026-06-21: no authoritative source found —— `thread_goal_updated` 已确认是
    `protocol.rs` 中的 `EventMsg` 变体,但其内部 `goal`/`threadId`/`turnId` 字段大小写无法对照
    源码确认;故将 camelCase 主张视为磁盘观察。)

---

## 附录:真实匿名行样本

每个记录 / payload 类型一个 JSON 代码块。所有内容已脱敏;完整键结构保持完整。

```json
// L1 session_meta — NEW format (cli 0.141.0, normal user session)
{ "timestamp":"2026-06-21T07:37:18.453Z","type":"session_meta","payload":{
    "id":"019ee91c-8298-7c32-a***","timestamp":"2026-06-21T07:37:00.471Z",
    "cwd":"/Users/<user>/<repo>","originator":"codex-tui","cli_version":"0.141.0",
    "source":"cli","thread_source":"user","model_provider":"openai",
    "base_instructions":{"text":"You are Codex, a coding agent... <~12KB redacted>"},
    "git":{"commit_hash":"d941bde***","branch":"main"} } }
```

```json
// L1 session_meta — LEGACY format (cli 0.60.1)
{ "timestamp":"2025-11-20T03:08:12.225Z","type":"session_meta","payload":{
    "id":"019a9f3b-de26-71f0-***","timestamp":"2025-11-20T03:08:12.198Z",
    "cwd":"/Users/<user>","originator":"codex_cli_rs","cli_version":"0.60.1",
    "instructions":null,"source":"cli","model_provider":"openai" } }
```

```json
// L1 session_meta — subagent (source is an OBJECT)
{ "timestamp":"2026-06-20T17:39:16.296Z","type":"session_meta","payload":{
    "id":"019ee61d-8aa4-7883-***","parent_thread_id":"019ee02d-***",
    "timestamp":"2026-06-20T17:39:16.296Z","cwd":"<redacted>",
    "originator":"Codex Desktop","cli_version":"0.142.0-alpha.6",
    "source":{"subagent":{"thread_spawn":{"parent_thread_id":"019ee02d-***",
        "depth":1,"agent_path":null,"agent_nickname":"Explorer the 12th","agent_role":"explorer"}}},
    "thread_source":"subagent","agent_nickname":"Explorer the 12th","agent_role":"explorer",
    "model_provider":"openai","base_instructions":{"text":"<redacted>"},
    "multi_agent_version":"v1","git":{"commit_hash":"1f29fa8f***","branch":"main"} } }
```

```json
// L1 turn_context — per-turn config (ignored by Engram)
{ "timestamp":"2026-06-21T07:37:18.935Z","type":"turn_context","payload":{
    "turn_id":"019ee91c-***","cwd":"/Users/<user>/p","workspace_roots":["/Users/<user>/p"],
    "current_date":"2026-06-21","timezone":"Asia/Shanghai","approval_policy":"never",
    "sandbox_policy":{"type":"danger-full-access"},"permission_profile":{"type":"disabled"},
    "model":"gpt-5.5","comp_hash":"2911","personality":"pragmatic",
    "collaboration_mode":{"mode":"default","settings":{"model":"gpt-5.5","reasoning_effort":"xhigh","developer_instructions":"<redacted>"}},
    "multi_agent_version":"v1","realtime_active":false,"effort":"xhigh","summary":"auto" } }
```

```json
// L2 response_item / message (user)
{ "timestamp":"2026-06-03T14:54:23.911Z","type":"response_item","payload":{
    "type":"message","role":"user","id":null,"status":null,
    "content":[ {"type":"input_text","text":"<USER PROMPT>"},
                {"type":"input_text","text":"<SECOND BLOCK>"} ] } }
```

```json
// L2 response_item / message (assistant)
{ "type":"response_item","payload":{
    "type":"message","role":"assistant","id":null,"status":null,
    "content":[ {"type":"output_text","text":"<ASSISTANT REPLY>"} ] } }
```

```json
// L2 response_item / message (user, image attachment)
{ "type":"response_item","payload":{
    "type":"message","role":"user",
    "content":[ {"type":"input_image","image_url":"data:image/jpeg;base64,<BASE64>","detail":"auto"} ] } }
```

```json
// L2 response_item / reasoning (encrypted, summary empty)
{ "type":"response_item","payload":{
    "type":"reasoning","id":"rs_02a<…>","summary":[],
    "encrypted_content":"gAAAAAB<…>","metadata":{"turn_id":"<uuid>"} } }
```

```json
// L2 response_item / function_call + paired function_call_output
{ "type":"response_item","payload":{
    "type":"function_call","name":"exec_command",
    "arguments":"{\"cmd\":[\"/bin/zsh\",\"-lc\",\"<CMD>\"],\"workdir\":\"<PATH>\"}",
    "call_id":"call_TMg3Szj<…>" } }
{ "type":"response_item","payload":{
    "type":"function_call_output","call_id":"call_TMg3Szj<…>","output":"<STDOUT>" } }
```

```json
// L2 response_item / custom_tool_call (apply_patch)
{ "type":"response_item","payload":{
    "type":"custom_tool_call","name":"apply_patch",
    "input":"*** Begin Patch\n*** Update File: <PATH>\n<DIFF>\n*** End Patch",
    "call_id":"call_<…>","status":"completed" } }
```

```json
// L2 response_item / web_search_call
{ "type":"response_item","payload":{
    "type":"web_search_call","status":"completed",
    "action":{"type":"search","query":"<QUERY>","queries":["<Q>"]} } }
```

```json
// L2 response_item / tool_search_call (arguments is an OBJECT here)
{ "type":"response_item","payload":{
    "type":"tool_search_call","call_id":"<id>","status":"completed",
    "execution":"client","arguments":{"query":"<QUERY>","limit":10} } }
```

```json
// L2 event_msg / token_count (authoritative usage)
{ "type":"event_msg","payload":{
    "type":"token_count",
    "info":{
      "total_token_usage":{"input_tokens":33804,"cached_input_tokens":2432,"output_tokens":815,"reasoning_output_tokens":516,"total_tokens":34619},
      "last_token_usage":{"input_tokens":33804,"cached_input_tokens":2432,"output_tokens":815,"reasoning_output_tokens":516,"total_tokens":34619},
      "model_context_window":258400 },
    "rate_limits":{"limit_id":"codex","limit_name":null,
      "primary":{"used_percent":1.0,"window_minutes":300,"resets_at":1782044976},
      "secondary":{"used_percent":6.0,"window_minutes":10080,"resets_at":1782613776},
      "credits":null,"individual_limit":null,"plan_type":"pro","rate_limit_reached_type":null} } }
```

```json
// L2 event_msg / agent_message (UI mirror of assistant text)
{ "type":"event_msg","payload":{
    "type":"agent_message","message":"<TEXT>","phase":"commentary","memory_citation":null } }
```

```json
// L2 event_msg / user_message (UI form with attachment metadata)
{ "type":"event_msg","payload":{
    "type":"user_message","message":"<TEXT>","images":[],"local_images":[],"text_elements":[] } }
```

```json
// L2 event_msg / task_started + task_complete (linked by turn_id)
{ "type":"event_msg","payload":{
    "type":"task_started","turn_id":"727cc762-***","started_at":1780498463,
    "model_context_window":258400,"collaboration_mode_kind":"default" } }
{ "type":"event_msg","payload":{
    "type":"task_complete","turn_id":"727cc762-***","last_agent_message":"<TEXT>",
    "completed_at":1780503250,"duration_ms":4786545,"time_to_first_token_ms":9140 } }
```

```json
// L2 event_msg / exec_command_end (verbose shell telemetry, legacy)
{ "type":"event_msg","payload":{
    "type":"exec_command_end","call_id":"call_<…>","process_id":"<PID>","turn_id":"<uuid>",
    "command":["/bin/zsh","-lc","<CMD>"],"cwd":"<PATH>",
    "parsed_cmd":[{"type":"unknown","cmd":"<CMD>"}],"source":"<src>",
    "stdout":"<STDOUT>","stderr":"<STDERR>","aggregated_output":"<OUT>","exit_code":0,
    "duration":{"secs":1,"nanos":165817834},"formatted_output":"<OUT>","status":"completed" } }
```

```json
// L2 event_msg / patch_apply_end (apply_patch telemetry)
{ "type":"event_msg","payload":{
    "type":"patch_apply_end","call_id":"call_<…>","turn_id":"<uuid>",
    "stdout":"<OUT>","stderr":"","success":true,
    "changes":{"<FILE_PATH>":{"type":"update","move_path":null,"unified_diff":"<DIFF>"}},
    "status":"completed" } }
```

```json
// L2 event_msg / mcp_tool_call_end (Rust-Result tagged union)
{ "type":"event_msg","payload":{
    "type":"mcp_tool_call_end","call_id":"call_bnQGN<…>","duration":{"secs":0,"nanos":446001833},
    "invocation":{"server":"codegraph","tool":"codegraph_explore","arguments":{"query":"<QUERY>"}},
    "result":{"Ok":{"content":[{"type":"text","text":"<RESULT>"}],"is_error":null}} } }
{ "type":"event_msg","payload":{
    "type":"mcp_tool_call_end","call_id":"call_<…>","duration":{"secs":0,"nanos":1},
    "invocation":{"server":"<srv>","tool":"<tool>","arguments":{}},"result":{"Err":"<ERROR STRING>"} } }
```

```json
// L2 event_msg / error
{ "type":"event_msg","payload":{
    "type":"error","message":"<MESSAGE>","codex_error_info":"context_window_exceeded" } }
```

```json
// L2 event_msg / smaller lifecycle variants
{ "type":"event_msg","payload":{"type":"context_compacted"} }
{ "type":"event_msg","payload":{"type":"agent_reasoning","text":"<REASONING TEXT — legacy>"} }
{ "type":"event_msg","payload":{"type":"turn_aborted","turn_id":"<uuid>","reason":"interrupted","completed_at":1780500000,"duration_ms":12000} }
{ "type":"event_msg","payload":{"type":"web_search_end","call_id":"<id>","query":"<QUERY>","action":{"type":"open_page","url":"https://example.com"}} }
{ "type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":3} }
{ "type":"event_msg","payload":{"type":"thread_goal_updated","goal":{},"threadId":"<uuid>","turnId":"<uuid>"} }
```

```json
// L2 event_msg / entered_review_mode + exited_review_mode (structured code-review payload)
// entered_review_mode.target is POLYMORPHIC by target.type:
//   uncommittedChanges -> {type}            custom    -> {type, instructions}
//   baseBranch         -> {type, branch}    commit    -> {type, sha, title}
{ "type":"event_msg","payload":{
    "type":"entered_review_mode",
    "target":{"type":"commit","sha":"<sha>","title":"<commit title>"},
    "user_facing_hint":"<HINT>" } }
{ "type":"event_msg","payload":{
    "type":"exited_review_mode",
    "review_output":{
      "overall_correctness":"<verdict>","overall_confidence_score":0.0,
      "overall_explanation":"<SUMMARY>",
      "findings":[
        {"title":"<FINDING TITLE>","body":"<DETAIL>","priority":0,
         "confidence_score":0.0,"code_location":"<file:line>"} ] } } }
```

### 新的原生多代理 / 图像 / 动态工具 `event_msg` 变体

这 11 个 `event_msg` payload 类型(见上面 L2 枚举说明)在原始分类法中缺失。`collab_*` 家族在
Subagent 章节(B-4)中有结构化记录;图像工具在工具调用的“图像工具”小节中。字段表 + 样本:

| payload.type | 键 | 含义 |
|---|---|---|
| `thread_name_updated` | `{type, thread_id, thread_name}` | **标题更新事件** — DB 驱动的线程重命名。与 `session_index.jsonl.thread_name` 和 `threads.title` 并行;这是同一标题更改的 rollout 内发出。官方已确认:`ThreadNameUpdated` **不是** `protocol.rs` 中核心 rollout `EventMsg` 枚举的变体;在源码中它位于 app-server-protocol / app-server / TUI 通知层(`ThreadNameUpdatedNotification`)。故磁盘上 `payload.type=thread_name_updated` 的 `event_msg` 行,很可能来自桌面/app-server 写入路径,而非核心 rollout 记录器。([common.rs](https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/src/protocol/common.rs)) |
| `collab_agent_spawn_end` | `{type, call_id, sender_thread_id, new_thread_id, new_agent_nickname, new_agent_role, prompt, model, reasoning_effort, status}` | 父→子 spawn 边,内联在父级 rollout 中(见 B-4)。 |
| `collab_waiting_end` | `{type, call_id, sender_thread_id, agent_statuses, statuses}` | 父级等待子级;`statuses`/`agent_statuses` 把子级 id 映射到结果。 |
| `collab_close_end` | `{type, call_id, sender_thread_id, receiver_thread_id, receiver_agent_nickname, receiver_agent_role, status}` | 父级关闭一个子级;`status` = `{completed:"<summary>"}`。 |
| `collab_agent_interaction_end` | `{type, call_id, sender_thread_id, receiver_thread_id, receiver_agent_nickname, receiver_agent_role, prompt, status}` | 代理↔代理消息;`prompt` 询问,`status.completed` 回复。 |
| `collab_resume_end` | `{type, call_id, sender_thread_id, receiver_thread_id, receiver_agent_nickname, receiver_agent_role, status}` | 父级恢复一个暂停的子级。 |
| `view_image_tool_call` | `{type, call_id, path}` | 代理查看了磁盘上 `path` 处的图像。 |
| `image_generation_end` | `{type, call_id:ig_<hex>, status, revised_prompt, result, saved_path}` | 图像生成完成遥测;`call_id` 是 `ig_` id,`saved_path` 在 `generated_images/` 下。 |
| `item_completed` | `{type, thread_id, turn_id, item}` | 一个结构化代理项完成;`item` 例如 `{type:"Plan", id:"<id>-plan", text:"<plan markdown>"}`。 |
| `dynamic_tool_call_request` | `{type, callId, turnId, namespace, tool, arguments}` | 运行时注册的动态工具**请求** — **camelCase** `callId`/`turnId`。`namespace` 可能是 `null`;`arguments` 是一个对象。 |
| `dynamic_tool_call_response` | `{type, call_id, turn_id, namespace, tool, arguments, content_items, success, error, duration}` | 动态工具**响应** — 此处为 **snake_case**(`call_id`/`turn_id`,与请求的 camelCase 不一致)。`content_items[]` 块使用块类型 **`inputText`**(camelCase L3)。 |

```json
// L2 event_msg / thread_name_updated (rollout-resident title rename)
{ "type":"event_msg","payload":{
    "type":"thread_name_updated","thread_id":"<uuid>","thread_name":"<title>"} }
```

```json
// L2 event_msg / collab_agent_spawn_end (parent-side spawn edge: sender -> new child)
{ "type":"event_msg","payload":{
    "type":"collab_agent_spawn_end","call_id":"<id>",
    "sender_thread_id":"<parent uuid>","new_thread_id":"<child uuid>",
    "new_agent_nickname":"<name>","new_agent_role":"worker","prompt":"<SPAWN PROMPT>",
    "model":"gpt-5.5","reasoning_effort":"medium","status":"pending_init"} }
```

```json
// L2 event_msg / collab_waiting_end (children results map back to parent)
{ "type":"event_msg","payload":{
    "type":"collab_waiting_end","call_id":"<id>","sender_thread_id":"<parent uuid>",
    "agent_statuses":"<v>",
    "statuses":{ "<child uuid>":{"completed":"<CHILD RESULT TEXT>"} } } }
```

```json
// L2 event_msg / collab_close_end (status is an OBJECT, not a plain string)
{ "type":"event_msg","payload":{
    "type":"collab_close_end","call_id":"<id>",
    "sender_thread_id":"<parent uuid>","receiver_thread_id":"<child uuid>",
    "receiver_agent_nickname":"<name>","receiver_agent_role":"worker",
    "status":{"completed":"<FINAL CHILD SUMMARY>"} } }
```

```json
// L2 event_msg / collab_agent_interaction_end + collab_resume_end
{ "type":"event_msg","payload":{
    "type":"collab_agent_interaction_end","call_id":"<id>",
    "sender_thread_id":"<parent uuid>","receiver_thread_id":"<child uuid>",
    "receiver_agent_nickname":"<name>","receiver_agent_role":"explorer",
    "prompt":"<INTERACTION PROMPT>","status":{"completed":"<RECEIVER REPLY>"} } }
{ "type":"event_msg","payload":{
    "type":"collab_resume_end","call_id":"<id>",
    "sender_thread_id":"<parent uuid>","receiver_thread_id":"<child uuid>",
    "receiver_agent_nickname":"<name>","receiver_agent_role":"explorer",
    "status":{"completed":"<RESUMED CHILD OUTPUT>"} } }
```

```json
// L2 event_msg / view_image_tool_call
{ "type":"event_msg","payload":{
    "type":"view_image_tool_call","call_id":"<id>","path":"<image path>"} }
```

```json
// L2 response_item / image_generation_call (id is ig_<hex>, NOT call_<rand>)
// paired with L2 event_msg / image_generation_end (call_id == that ig_<hex>)
{ "type":"response_item","payload":{
    "type":"image_generation_call","id":"ig_<hex>","status":"generating",
    "revised_prompt":"<REWRITTEN IMAGE PROMPT>","result":"<blob/base64>"} }
{ "type":"event_msg","payload":{
    "type":"image_generation_end","call_id":"ig_<hex>","status":"completed",
    "revised_prompt":"<REWRITTEN IMAGE PROMPT>","result":"<blob/base64>",
    "saved_path":"<generated_images/...png>"} }
```

```json
// L2 event_msg / item_completed (structured agent item — e.g. a Plan)
{ "type":"event_msg","payload":{
    "type":"item_completed","thread_id":"<uuid>","turn_id":"<uuid>",
    "item":{"type":"Plan","id":"<id>-plan","text":"<plan markdown — redacted>"} } }
```

```json
// L2 event_msg / dynamic_tool_call_request (camelCase callId/turnId)
//          and dynamic_tool_call_response (snake_case call_id/turn_id; block type inputText)
{ "type":"event_msg","payload":{
    "type":"dynamic_tool_call_request","callId":"<id>","turnId":"<uuid>",
    "namespace":null,"tool":"load_workspace_dependencies","arguments":{} } }
{ "type":"event_msg","payload":{
    "type":"dynamic_tool_call_response","call_id":"<id>","turn_id":"<uuid>",
    "namespace":null,"tool":"load_workspace_dependencies","arguments":{},
    "content_items":[{"type":"inputText","text":"<TOOL OUTPUT — redacted>"}],
    "success":"<v>","error":"<v>","duration":"<v>"} }
```

```json
// L1 compacted — context-compaction checkpoint
// (3 observed generations: [message,replacement_history] ×2050;
//  +window_id ×113; +window_id+window_number ×55 — newest emits BOTH counters)
{ "timestamp":"2026-06-21T02:37:49.013Z","type":"compacted","payload":{
    "message":"","window_id":1,"window_number":1,
    "replacement_history":[
      {"type":"message","role":"user","content":[{"type":"input_text","text":"<earlier user msg>"}]},
      {"type":"message","role":"developer","content":[{"type":"input_text","text":"<permissions block>"}]} ] } }
```

```json
// Aux: history.jsonl line (flat shape — NOT the {timestamp,type,payload} envelope)
{ "session_id":"019ee858-92b6-7853-ba71-074b9c042711","ts":1757248180,"text":"<user prompt>" }
```

```json
// Aux: session_index.jsonl line
{ "id":"019ca318-d9f3-7a12-a4f1-0352b065e5b6","thread_name":"<title>","updated_at":"2026-03-01T03:06:53.593906Z" }
```

---

## 开放问题 / web 确认状态(2026-06-21)

本文的结构性主张已于 2026-06-21 对照**官方 `openai/codex` Rust 源码**进行了交叉核对
(`web_access_ok=true`)。语料库统计(文件计数、originator 分布、model 分布、迁移行数)是本机
测量值,按设计无法通过 web 验证。各项此前开放问题的状态如下:

- **官方已确认:** L1 信封形状为 `RolloutLine = {timestamp, #[serde(flatten)] item}`,其中
  `RolloutItem` 为 `serde(tag="type", content="payload")`,故每行是
  `{"timestamp", "type":"<snake_case>", "payload":{...}}`。
  ([protocol.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs))
- **官方已确认:** L1 记录集有 **六个** 变体,而非五个 —— `inter_agent_communication` 是缺失的
  第 6 个(已并入上方分类法)。
  ([protocol.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs))
- **官方已确认:** `session_meta.payload` 携带 `id`、`forked_from_id`、`parent_thread_id`、
  `timestamp`、`cwd`、`originator`、`cli_version`、`source`、`thread_source`、
  `agent_nickname`、`agent_role`(别名 `agent_type`)、`agent_path`、`model_provider`、
  `base_instructions`、`dynamic_tools`、`memory_mode`、`multi_agent_version`;`git` 通过
  `#[serde(flatten)]` 位于包装器 `SessionMetaLine` 上。`GitInfo = {commit_hash, branch,
  repository_url}`,全部可选。
  ([protocol.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs))
- **官方已确认:** `originator` 是自由格式的 `String`(开放/可扩展集合,而非封闭枚举);
  `DEFAULT_ORIGINATOR = "codex_cli_rs"`,可通过 `CODEX_INTERNAL_ORIGINATOR_OVERRIDE` 覆盖。
  `codex_cli_rs`/`codex_exec`/`codex_sdk_ts` 是源码中的字面 originator 字符串。
  ([default_client.rs](https://github.com/openai/codex/blob/main/codex-rs/login/src/auth/default_client.rs))
- **官方已确认:** `source` 是多态的 —— `SessionSource` =
  `Cli | VSCode | Exec | Mcp | Custom(String) | Internal | SubAgent(SubAgentSource) |
  Unknown`;`SubAgentSource` = `Review | Compact | ThreadSpawn{parent_thread_id, depth,
  agent_path, agent_nickname, agent_role(alias agent_type)} | MemoryConsolidation |
  Other(String)`。纯字符串形式以及嵌套的 `{subagent:{thread_spawn:{…}}}` /
  `{subagent:"review"}` 形式均已确认(变体比本文列出的六种更多)。
  ([protocol.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs))
- **官方已确认:** L3 内容块 —— `ContentItem` = `InputText{text}` |
  `InputImage{image_url, detail:Option<ImageDetail>}` | `OutputText{text}`;字符串始终在
  `text` 下。`ImageDetail` = `Auto/Low/High/Original`(默认 `High`)。当前枚举中不存在独立的
  `text` 块变体(遗留的 `text` 块已被移除/更旧)。
  ([models.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/models.rs))
- **官方已确认:** `ResponseItem::Message` 只有 `{id, role, content, phase, metadata}` ——
  **没有 `usage`,也没有 `status`** 字段。读取 assistant `payload.usage`/`payload.status` 的
  适配器对现代 Codex 命中死路径;每回合用量仅来自 `event_msg/token_count`。
  `phase` = `MessagePhase::{Commentary, FinalAnswer}`。
  ([models.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/models.rs))
- **官方已确认:** 没有任何 `ResponseItem` 变体带有 `model` 字段;model 位于
  `TurnContextItem.model`(必需 `String`)。故现代 rollout 不携带
  `response_item.payload.model` —— model 来自 `turn_context`。
  ([models.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/models.rs),
  [protocol.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs))
- **官方已确认:** `ResponseItem::Reasoning` = `{id, summary, content, encrypted_content,
  metadata}`;`ResponseItemMetadata = {turn_id, source_call_id}`。`encrypted_content` 是不透明
  的 `Option<String>`(未声明加密方案 —— 见 D8)。
  ([models.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/models.rs))
- **官方已确认 —— 并附更正:** `FunctionCall` = `{id, name, namespace, arguments:String
  (JSON 字符串), call_id, metadata}`。`function_call_output` 的结构化形式是 `content_items`
  (数组),而非 `{output, metadata}`(见 D3)。
  ([models.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/models.rs))
- **官方已确认:** `CustomToolCall` 使用 `input`(自由格式 `String`),且 `name` 是任意
  `String` —— 通用的自由格式工具通道。`ToolSearchCall.arguments` 是 `serde_json::Value`
  (结构化对象),对比 `FunctionCall.arguments: String`。
  ([models.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/models.rs))
- **官方已确认:** `TokenUsageInfo = {total_token_usage, last_token_usage,
  model_context_window:Option<i64>}`;`TokenUsage = {input_tokens, cached_input_tokens,
  output_tokens, reasoning_output_tokens, total_tokens}`(全为 `i64`)。`TokenCountEvent.info`
  为 `Option`(可为 null)。
  ([protocol.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs))
- **官方已确认:** `EventMsg` 枚举庞大且随版本演进(开放/增长,而非封闭);`token_count`、
  `context_compacted`、`agent_reasoning`、完整的 `collab_*` begin/end 家族、
  `view_image_tool_call`、`image_generation_end`、`item_completed`、
  `dynamic_tool_call_request`/`response`、review 模式事件等等都是真实变体。
  `task_started`/`task_complete` 是 `TurnStarted`/`TurnComplete` 的 serde 别名。
  ([protocol.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs))
- **官方已确认:** `context_compacted` 是一个纯标记 `EventMsg` 变体,与 L1
  `Compacted(CompactedItem)` 记录不同 —— 印证了 L1-vs-L2 名称陷阱。
  ([protocol.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs))
- **官方已确认:** `thread_spawn_edges` schema 为 `(parent_thread_id TEXT NOT NULL,
  child_thread_id TEXT NOT NULL PRIMARY KEY, status TEXT NOT NULL)` + 索引
  `idx_thread_spawn_edges_parent_status(parent_thread_id, status)` —— 一父对一子。
  ([0021_thread_spawn_edges.sql](https://github.com/openai/codex/blob/main/codex-rs/state/migrations/0021_thread_spawn_edges.sql))
- **官方已确认:** `_N` 迁移代次模型与 `threads` schema —— `0001_threads.sql` 创建基础
  `threads` 表;后续列(`model`、`cli_version`、`agent_role`、`agent_nickname`、
  `thread_source`、`memory_mode`、`recency_at`)通过后续迁移加入;`0039_threads_recency_at.sql`
  是最新的(添加 `recency_at`,故遗留 DB 缺少它)。
  ([migrations/](https://github.com/openai/codex/tree/main/codex-rs/state/migrations))
- **官方已确认:** rollout 文件名语法 ——
  `sessions/YYYY/MM/DD/rollout-{date}-{conversation_id}.jsonl`;文件名 TS 格式
  `[year]-[month]-[day]T[hour]-[minute]-[second]`(连字符),JSON 记录 TS
  `…T[hour]:[minute]:[second].[subsecond:3]Z`;第一行必须是 `SessionMeta`。(文件名=本地 /
  内部=UTC 的区分是磁盘观察,并未编码在格式常量中。)
  ([recorder.rs](https://github.com/openai/codex/blob/main/codex-rs/rollout/src/recorder.rs))
- **官方已确认:** `TurnContextItem` 携带每回合配置 —— `turn_id`、`cwd`、`workspace_roots`、
  `current_date`、`timezone`、`approval_policy`、`sandbox_policy`、`permission_profile`、
  `network`、`file_system_sandbox_policy`、`model:String`、`comp_hash`、`personality`、
  `collaboration_mode`、`multi_agent_version`、`multi_agent_mode`、`realtime_active`、
  `effort`、`summary`(仅兼容性)。Engram 是否忽略它是 Engram 内部设计事实。
  ([protocol.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs))
- **已被推翻 → 已修正(官方):** `compacted` 的 window 字段类型搞反了 —— `window_number` 是
  `u64` 整数计数器,`window_id` 是 UUIDv7 字符串;此外还存在
  `first_window_id`/`previous_window_id`(已在“摘要 / 压缩”章节修正,D2)。
  ([protocol.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs))
- **未知(web-checked 2026-06-21: no authoritative source found):**
  `thread_goal_updated` 已确认是 `EventMsg` 变体,但其内部字段大小写
  (`goal`/`threadId`/`turnId` camelCase)无法对照源码确认 —— 视为磁盘观察。
  ([protocol.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs))
- **Engram 内部设计 —— 无法通过 web 验证:** Swift 产品是否有自己的定价路径,以及
  `turn_context`/`compacted`/`inter_agent_communication` 被 Engram 忽略,都是 Engram 内部
  事实,超出 web 范围。
- **超出范围 —— 按设计无法通过 web 验证:** `history.jsonl` / `session_index.jsonl` 的形状,
  以及所有本机语料库统计(文件计数、originator/model 分布、归档计数、迁移行数)都是本机测量值,
  而非工具格式事实。

---

## References(官方来源)

于 2026-06-21 对照 `openai/codex` 仓库(`main` 分支)验证:

- [codex-rs/protocol/src/protocol.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs) — `RolloutLine`/`RolloutItem`/`SessionMeta`/`SessionMetaLine`/`GitInfo`/`CompactedItem`/`TurnContextItem`/`TokenUsage`/`TokenUsageInfo`/`EventMsg`/`SessionSource`/`ThreadSource`/`SubAgentSource`
- [codex-rs/protocol/src/models.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/models.rs) — `ResponseItem`/`ContentItem`/`Reasoning`/`FunctionCall`/`FunctionCallOutputPayload`/`CustomToolCall`
- [codex-rs/rollout/src/recorder.rs](https://github.com/openai/codex/blob/main/codex-rs/rollout/src/recorder.rs) — rollout path + filename + timestamp format
- [codex-rs/login/src/auth/default_client.rs](https://github.com/openai/codex/blob/main/codex-rs/login/src/auth/default_client.rs) — `DEFAULT_ORIGINATOR = codex_cli_rs`, originator override env
- [codex-rs/state/migrations/0021_thread_spawn_edges.sql](https://github.com/openai/codex/blob/main/codex-rs/state/migrations/0021_thread_spawn_edges.sql) — thread spawn edges table
- [codex-rs/state/migrations/0001_threads.sql](https://github.com/openai/codex/blob/main/codex-rs/state/migrations/0001_threads.sql) — base `threads` table
- [codex-rs/state/migrations/0039_threads_recency_at.sql](https://github.com/openai/codex/blob/main/codex-rs/state/migrations/0039_threads_recency_at.sql) — newest migration (`recency_at`)
- [codex-rs/state/migrations/](https://github.com/openai/codex/tree/main/codex-rs/state/migrations) — full migration ledger
- [codex-rs/app-server-protocol/src/protocol/common.rs](https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/src/protocol/common.rs) — `ThreadNameUpdatedNotification`(app-server 层)
- [DeepWiki — Rollout Persistence and Replay (openai/codex)](https://deepwiki.com/openai/codex/3.5.2-rollout-persistence-and-replay) — 社区参考
