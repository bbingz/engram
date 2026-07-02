# Kimi CLI — 会话格式参考

Last researched: 2026-07-02 (Engram provider audit recheck).
Adapter sync updated: 2026-06-30.

> 本文档为英文权威版 kimi.md 的中文阅读副本;若有出入以英文版为准。

> **Kimi CLI**（Moonshot AI 的 "kimi-code" 编码 CLI）如何把会话持久化到磁盘,
> 以及 Engram 的适配器如何消费它们的权威英文参考。结构上与 Claude Code 和
> Codex 格式文档平行。不适用于 Kimi 的小节会标记为 **"N/A for Kimi"**，而不是直接删除。

**证据基础（本文档）：**
- **本机磁盘上的实时存储** `~/.kimi/` —— **49 个 workspace 目录**
  （`/bin/ls -1 ~/.kimi/sessions` = 49；`find -mindepth1 -maxdepth1 -type d` = 49；
  与 `kimi.json` `work_dirs` 匹配 = 49），
  **573 个 `context.jsonl`** *(= `sessions/<ws>/<sess>/` 下 459 个主会话
  context + 114 个更深层 `subagents/<id>/context.jsonl` 子会话 context；当前适配器
  都会枚举)*，**566 个 `wire.jsonl`** *(= 452 个会话级 + 114
  个 subagent)*，**393 个 `state.json`**，**42
  个 `context_sub_*.jsonl`**，**2 个 `context_1.jsonl`**，**6 个 `subagents/`** 目录，**1
  个 `tasks/`** 目录，**1 个 `notifications/`** 目录。角色、键集、块类型、
  wire 消息类型、token 用量形态、`md5(cwd)` workspace 哈希以及
  `config.toml` model 均经过直接探查（每次探查 ≥40–80 个文件；
  确凿的 `message.type` 和压缩扫描覆盖了全部 452 个会话级
  `wire.jsonl`）。
- **仓库 fixtures** —— `tests/fixtures/kimi/`（1 个合成会话 +
  `schema_drift.jsonl` + `kimi.json`）以及 `tests/fixtures/adapter-parity/kimi/`
  （`success.expected.json`）。
- **两个 Engram 适配器** —— Swift 产品解析器
  `macos/Shared/EngramCore/Adapters/Sources/KimiAdapter.swift` 和 TS 参考实现
  `src/adapters/kimi.ts`（已完整阅读）。

发生冲突时，**以磁盘上的真实数据为准**，并在行内标注差异。
所有引用的样本都已 **匿名化为结构（键 + 值类型）**；不会复现任何
消息文本、代码、路径、token 或密钥。

## 当前本机审计

2026-07-02 native `~/.kimi/sessions` smoke 列出并解析 573/573 个 canonical
`context.jsonl` locator 为 `kimi`：459 个主会话 context，114 个
`subagents/<id>/context.jsonl` 子会话 context。114 个 subagent context 全部带
`agentRole='subagent'` 和 `parentSessionId`；当前 102 个 session 能通过
`~/.kimi/kimi.json` 解析出 cwd。同一 raw store 仍有 566 个 `wire.jsonl` 和
44 个轮转分片（`2 context_N`，`42 context_sub_N`），它们作为辅助数据读取，
不是独立 session locator。
TS live stream smoke 产出 4,036 条 transcript messages（1,061 user + 2,975
assistant），parser/stream count mismatch 为 0。

当前 `~/.engram/index.sqlite` 在 `/Users/bing/.kimi/%` 下有 689 个 native `kimi`
行。全部 573 个当前 canonical `context.jsonl` locator 都已进入
`file_index_state`（`ok`/schema v1，最新 native `indexed_at`
`2026-07-01T05:46:43Z`），也都存在于 `sessions.source_locator`；仍有 116 个
source-locator 口径的 DB-only native 行属于 stale cleanup。不要只用
`sessions.file_path` 判断 Kimi locator 是否闭合：当前只有 251 行的 `file_path`
等于当前 context locator，另有 438 个 native 行保留旧的 readable/sidecar 路径
（`264 wire.jsonl`、`56 notification`、`26 state.json`、`89 other sidecar/artifact`
以及 `3 obsolete context.jsonl`）。当前还有 2 行的 parser-owned 计数/大小字段陈旧。
更宽的 parser-vs-DB metadata diff 也能看到当前行上保留下来的旧 `cwd`、
`agent_role`、`parent_session_id` 以及 start/end/path 值；这些主要来自
`SessionSnapshotWriter` 的保留规则，不应直接解读为 parser 计数漂移。
已安装 `/Applications/Engram.app` build `20260701074505`
的 MCP 对真实 native Kimi 行 `ed48cf04-9543-45f0-8cbc-988406b1ca65` 返回
50 条 page-1 messages,`sessionMessageCount=201`。

独立的 Claude Code provider-root 路线 `~/.claude-kimi/projects` 不是 native Kimi
存储；它使用 Claude Code JSONL，由 `ClaudeCodeAdapter` 以 `kimi` source 解析。
2026-07-02 审计列出 2,090 个 provider-root JSONL 文件、95,845 条记录、0 条畸形行，
解析 2,076 个 conversation，发现 2,067 个带 parent link 的 subagent，且
stream/count mismatch 为 0。已安装 `/Applications/Engram.app` build
`20260701074505` 在 `/Users/bing/.claude-kimi/%` 下有 2,076 个 DB 行，locator diff
已闭合。2,090 个 `.claude-kimi` `file_index_state` 行仍全是 schema version 1，但修正后的
visible-tool-result parser 报告 0 个字段陈旧的当前 provider-root 行。此前 809 行
stale-count 结论是 retained TS 审计工具误报：TS 当时会计入 Swift 产品已丢弃的非可见
Claude `tool_result` 行。

---

## 1. Overview & TL;DR

**是什么 / 在哪里 / 怎么做：**
- **是什么：** Kimi CLI 是 Moonshot AI 自家的编码 CLI（"kimi-code" 血统；
  `~/.kimi/.migrated-to-kimi-code` 标记 + `config.toml` provider
  `type = "kimi"` 可以确认）。它是一种 **每个工具自定义的 JSONL 格式** —— 既不是
  Gemini-CLI 家族，也不是 OpenAI/Codex。
- **在哪里：** 位于 `~/.kimi/sessions/<md5(cwd)>/<session-uuid>/` 之下。
- **怎么做：** 每个会话是一个 **目录**，由扁平的 **JSONL** 文件 +
  单对象 JSON 旁车文件构成。Kimi 存储中 **任何地方都没有数据库**（没有 SQLite、没有 leveldb、
  没有 gRPC cache）。

**心智模型：** 一个会话 = 一个目录。两条并行的日志描述它：
`context.jsonl`（*模型上下文* 对话：以角色区分的消息记录）和 `wire.jsonl`
（*agent 协议* 事件流：**唯一**的挂钟时间戳和 token 用量来源）。旁车文件
（`state.json`、`kimi.json`、`meta.json`、`spec.json` 等）保存生命周期/注册表元数据。
Engram 解析 `context.jsonl`（+ 轮转分片）以获取计数/文本，解析
`wire.jsonl` 以获取时间戳/用量，通过 `~/.kimi/kimi.json` 解析 `cwd`，
并忽略其他一切。

```
~/.kimi/
 ├─ kimi.json                     ← workspace→cwd registry (last_session_id ⇒ path)   [PARSED for cwd]
 ├─ config.toml                   ← model/provider config (default_model=Kimi-k2.6)   [NOT parsed]
 └─ sessions/
     └─ <md5(cwd)>/               ← workspace hash dir (32 hex)                        [grouping key, not decoded]
         └─ <session-uuid>/       ← session dir; dir name = Engram session id
             ├─ context.jsonl     ← conversation records (role-discriminated)         [PARSED]
             ├─ context_<N>.jsonl ← rotation shards in CURRENT kimi-cli source        [PARSED]
             ├─ context_sub_N.jsonl ← rotation shards in OLDER kimi-cli (on disk)     [PARSED]
             ├─ context_1.jsonl   ← legitimate current rotation shard (2 dirs)        [PARSED]
             ├─ wire.jsonl        ← agent-protocol events (ts + token usage)          [PARSED: 3 of 16 types]
             ├─ state.json        ← lifecycle/title/todos/plan/archive               [NOT parsed]
             ├─ subagents/<id>/   ← nested child agents (own context+wire+meta)        [PARSED as child sessions]
             ├─ tasks/agent-<id>/ ← async shell/tool tasks (spec/runtime/output)       [NOT parsed]
             └─ notifications/n*/ ← per-session notifications (event+delivery)          [NOT parsed]
```

**分层（记录 vs 内容块 vs 事件）：**
```
context.jsonl line            wire.jsonl line
   = {role, ...}                 = {timestamp, message:{type,payload}}
        │                                  │
   content (string OR array)        message.payload
        │                                  │
   content-block {type:think|text}   token_usage{input_other,output,...}
```

**给 Engram 的 TL;DR：** `id` = 会话目录 UUID；`cwd` 来自 `kimi.json`；
`summary` = 首条用户消息（≤200 字符）；时间戳来自 `wire.jsonl` 的
`TurnBegin`/`TurnEnd`；token 用量来自 `wire.jsonl` `StatusUpdate`（**仅 Swift**）；
subagent `context.jsonl` 会作为子会话索引并带上 `agentRole=subagent` 与
`parentSessionId`；只计入 `user`+`assistant` 记录；**`tool` 记录、数组内容块、
tool 调用、reasoning 以及 `state.json.custom_title` 全部被丢弃。**

---

## 2. On-disk layout & file naming

**根目录：** `~/.kimi/`（两个适配器，`KimiAdapter.swift:12-17`，`kimi.ts:38-39`）。
**会话根目录：** `~/.kimi/sessions/`。

```
~/.kimi/
├── kimi.json                 # workspace registry → cwd resolution (work_dirs[])
├── kimi.json.bak-*           # timestamped backup copies of kimi.json (rotation; not read)
├── config.toml              # CLI config: default_model, providers, loop_control, ...
├── device_id                 # 32-char device id
├── .migrated-to-kimi-code    # migration marker (kimi → kimi-code lineage)
├── latest_version.txt
├── credentials/  logs/  plans/  plugin-cc/  telemetry/  user-history/
└── sessions/
    └── <workspace-hash>/                  # = md5(absolute_cwd)  [32 lowercase hex]
        └── <session-uuid>/                # RFC-4122 UUID v4  ← Engram session id
            ├── context.jsonl              # PRIMARY conversation log (always present)
            ├── context_<N>.jsonl          # CURRENT kimi-cli rotation output (context_1.jsonl, context_2.jsonl…)
            ├── context_1.jsonl            # legitimate current rotation shard (2 dirs); NOT a rare snapshot
            ├── context_sub_1.jsonl …      # OLDER kimi-cli rotation naming, still on disk (up to _42 seen)
            ├── wire.jsonl                 # agent-protocol event log (ts + usage)
            ├── state.json                 # session lifecycle/title/todos/plan/archive
            ├── notifications/             # optional, per session
            │   └── n<8-hex>/
            │       ├── event.json         # notification record
            │       └── delivery.json      # delivery sink status
            ├── subagents/                 # optional — nested child agents
            │   └── <9-hex agent id>/
            │       ├── context.jsonl      # subagent conversation
            │       ├── wire.jsonl
            │       ├── prompt.txt         # subagent launch prompt (plaintext)
            │       ├── output             # subagent final output (plaintext)
            │       └── meta.json          # subagent metadata
            └── tasks/                     # optional — async tool/shell tasks
                └── agent-<8-alnum>/
                    ├── spec.json          # task spec
                    ├── runtime.json       # task runtime/exit state
                    ├── control.json       # control channel
                    ├── consumer.json      # consumer binding
                    └── output.log         # task stdout/stderr log
```

**命名语法（实时验证）：**

| Token | 语法 | 推导 | 是否验证 |
|---|---|---|---|
| `<workspace-hash>` | `^[0-9a-f]{32}$`（本地 kaos）/ `<kaos>_<md5>`（非本地） | 当 `kaos == local`（默认）时为 **`md5(absolute_cwd_path)`**；否则为 `f'{kaos}_{md5}'` | **是** —— 本机 49/49 个 `work_dirs[].path` 其 `md5(path)` 都等于一个真实的 workspace 目录。源码确认：`metadata.py` `WorkDirMeta.sessions_dir` |
| `<session-uuid>` | RFC-4122 UUID v4 | 每个会话随机生成 | 实时（`64892815-2590-475c-8112-9c82df9b16f2`） |
| `context_<N>.jsonl` | `N` = 十进制整数 | 当前 kimi-cli 源码中的轮转索引（`utils/path.next_available_rotation` → `f'{stem}_{N}{suffix}'`） | 源码确认；当前 `contextShardIndex` 会匹配 |
| `context_sub_<N>.jsonl` | `N` = 十进制整数 | 旧版 kimi-cli 中的轮转索引（磁盘上观察到 1..42） | 实时；当前 `contextShardIndex` 为兼容旧存储仍会匹配 |
| subagent id | `^[0-9a-f]{9}$` | 每个 subagent | 实时（`a616a2fc4`） |
| task id | `agent-<8 lowercase alnum>` | 每个 task | 实时（`agent-oiyhtezo`） |
| notification id | `n<8 hex>` | 每个 notification | 实时（`n0838353a`） |

> **实现说明：** 当前适配器把会话路径第一层当作不透明组件，因为 `kimi.json`
> 才是 cwd 的事实来源。在常见的本地场景中，这一层是 **`md5(cwd)`** —— 本机已验证
> 49/49 匹配；但非本地 kaos root 会使用 `<kaos>_<md5>`，所以适配器有意不反解它。
>
> **CORRECTED（web-checked 2026-06-21）：** 目录名 **仅当 `kaos == local`**（默认）时
> 才是 `md5(path)`。源码 `metadata.py` `WorkDirMeta.sessions_dir`
> 构造 `dir_basename = path_md5 if kaos == local else f'{kaos}_{path_md5}'`，所以
> 对于非本地的 kaos，basename 是 `<kaos>_<md5>`，而不是裸的 32 位十六进制字符串。
> 因此 `^[0-9a-f]{32}$` 语法是常见情形的形态，而非普遍适用。
> [metadata.py](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/metadata.py)

---

## 3. File lifecycle & generation

| 方面 | 行为 | 证据 |
|---|---|---|
| 存储技术 | 纯 **JSONL**（每行一个 JSON 对象）+ 单对象 JSON 旁车文件 | 实时 |
| 数据库？ | **无** —— 没有 SQLite/leveldb/gRPC cache | 实时 `find` |
| 追加 vs 重写 | 在一个会话内，`context.jsonl` 和 `wire.jsonl` 是 **仅追加**；从不原地重写 | 实时 |
| 轮转（即 rotation） | 当上下文增长时，Kimi 会溢出到与主文件 **共存** 的轮转分片中。**当前 kimi-cli 源码把它们命名为 `context_<N>.jsonl`**（`context_1.jsonl`、`context_2.jsonl` 等），通过 `soul/context.py` → `utils/path.next_available_rotation`（`f'{stem}_{N}{suffix}'`）；磁盘上的 **`context_sub_<N>.jsonl`**（观察到最多 `_sub_42`）是一种 **旧版 kimi-cli** 的命名。当前适配器两种形式都解析。重建方式 = 先主文件 + `context_<N>` / `context_sub_<N>` 按数字排序 | Swift `contextFiles()`；TS `getAllContextFiles()` |
| 恢复 / "上次会话" | `kimi.json.work_dirs[].last_session_id` 记录每个 cwd 最新的会话 uuid（用于恢复 + cwd 回填）。一次新运行会在同一个 `md5(cwd)` workspace 下铸造一个新的 `<session-uuid>` 目录 | `kimi.json` |
| Subagents | 一个会话会派生嵌套的 `subagents/<id>/` —— 拥有各自 `context.jsonl`/`wire.jsonl`/`meta.json` 的完整子对话 | 实时 |
| Tasks | 异步 `tasks/agent-<id>/`（带 `runtime.json` 退出状态的 shell/tool 任务）；`config.toml` 中的 `[background]` 管理它们（`max_running_tasks=4`，`agent_task_timeout_s=900`） | 实时 |
| 归档 | `state.json.archived`/`archived_at`/`auto_archive_exempt` 建模了一套归档生命周期；**采样的 0/200 被归档**。Engram 完全忽略此项 | 实时 |
| 压缩 | 上下文窗口压缩在 `context.jsonl` 中由 `_checkpoint` 记录标记，在 `wire.jsonl` 中由 `CompactionBegin`/`CompactionEnd` 事件标记（驼峰式，无空格 —— 逐字的 wire 类型）；`config.toml` `compaction_trigger_ratio=0.85` | 实时 + config |
| 通知 | `notifications/n*/` 以不可变的 `event.json`+`delivery.json` 成对累积 | 实时 |

> **已在 Engram 适配器中解决（2026-06-30）：** `context_1.jsonl` 是合法的
> 当前轮转输出，而非 "罕见的预轮转/遗留快照"。当前发布的 kimi-cli 源码
> 通过 `soul/context.py` → `utils/path.next_available_rotation` 轮转到
> `context_<N>.jsonl`（`context_1.jsonl`、`context_2.jsonl` 等）；较旧的
> 磁盘 `context_sub_*` 文件反映的是旧版 kimi-cli 命名。Engram 现在同时匹配
> 两类分片。
> [next_available_rotation](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/utils/path.py),
> [soul/context.py](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/soul/context.py)

---

## 4. Record / line taxonomy (`context.jsonl`)

每行一个 JSON 对象，由 **`role`** 区分。任何实时 `context.jsonl` 行上都
**没有顶层 `timestamp`**（跨 60 个文件确认）—— 所以适配器的逐行时间戳路径
对实时数据来说实际上是死代码，并始终回退到 `wire.jsonl`。

实时记录分布（50 个文件的代表性样本）以及确切的顶层键集：

| `role` | 确切键集（实时） | 实时计数（样本） | 用途 | Engram 是否处理？ |
|---|---|---|---|---|
| `_usage` | `role, token_count` | 182 | 每快照累计 token 水位线（int） | **否** —— Engram 改从 `wire.jsonl` 读取 token |
| `tool` | `content, role, tool_call_id` | 167 | 回喂给模型的 tool 结果；`content` 是结果块 **数组** | **否** —— `isConversation` 拒绝它；`toolMessageCount` 硬编码为 `0` |
| `_checkpoint` | `id, role` | 158 | 压缩/回滚标记；`id` 是 int（0,1,2…） | **否** —— TS 显式 `continue`（`kimi.ts:119`）；Swift 通过 `isConversation` 过滤 |
| `user` | `content, role` | 93 | 用户回合；`content` 通常是 **字符串**（极少为数组） | **是** → 用户消息 |
| `assistant` | `content, role, tool_calls` / `content, role` | 62 + 29 | 模型回合；`content` 为 **字符串或块数组**；可选 `tool_calls[]` | **是** → 助手消息 |
| `_system_prompt` | `content, role` | 50 | 完整系统提示快照（`content` 字符串，实时约 43 KB） | **否** —— 被跳过；`systemMessageCount` 硬编码为 `0` |

> **DISCREPANCY（Dim-2 报告 vs 实时）：** Dim 2 声称 `_system_prompt` 是
> `{role, id:null, content}`。实时数据显示 **只有 `content, role`**（采样的 79/79
> 都没有 `id` 键）。**以实时为准：`_system_prompt` 上没有 `id` 字段。**

> **磁盘上存在 tool 调用 ↔ 结果的关联**（`assistant.tool_calls[].id` →
> `tool.tool_call_id`），但 **Engram 完全不捕获它**（见 §7）。

---

## 5. Shared envelope / metadata fields

`context.jsonl` 记录共享一个轻量信封：**`role`**（区分器）
加上特定角色的负载键。各记录类型之间没有共享的 id/timestamp/uuid 信封
（不同于 Claude Code / Codex）。信封见 §4。

`wire.jsonl` 事件行共享一个统一的信封：

| 字段 | 类型 | 含义 | 可选性 | 示例 |
|---|---|---|---|---|
| `timestamp` | number（epoch **秒**，float） | 事件挂钟 | 每个事件行（在头行上缺失） | `1770000060.0` |
| `message` | object `{type, payload?}` | 带类型的事件负载 | 每个事件行 | `{"type":"TurnBegin","payload":{...}}` |
| `type` | string | 头部标记（`"metadata"`） | **仅头行** | `"metadata"` |
| `protocol_version` | string | wire 协议版本 | **仅头行** | `"1.9"` |

`kimi.json`（workspace 注册表）信封：单一顶层键 `work_dirs[]`，元素为
`{path, kaos, last_session_id}` —— 见 §13。

---

## 6. Message & content schema

### 6a. `user` record
`content` 是普通的 **字符串**（实时样本中 112/112 为字符串；仓库范围内存在 2 个数组案例）。
无块包裹。

```json
{"role": "user", "content": "<user prompt text>"}
```

| 字段 | 类型 | 可选 | 含义 |
|---|---|---|---|
| `role` | string | req | `"user"` |
| `content` | string（极少为 `{type:"text",text}` 数组） | req | 原始用户文本 |

### 6b. `assistant` record
`content` 是 **多态的** —— 在常见的实时情形中是 **内容块数组**，
或者是普通 **字符串**（罕见）。`tool_calls[]` 是可选的。样本中实时内容类型
比例：数组 ≫ 字符串（74 个数组 vs 9 个字符串助手回合；块类型 `think`=69，`text`=38）。

```json
{
  "role": "assistant",
  "content": [
    {"type": "think", "think": "<reasoning text>", "encrypted": null},
    {"type": "text",  "text":  "<visible answer text>"}
  ],
  "tool_calls": [
    {"id": "tool_<rand>", "type": "function",
     "function": {"name": "<ToolName>", "arguments": "{\"<arg>\":\"<val>\"}"}}
  ]
}
```

| 字段 | 类型 | 可选 | 含义 |
|---|---|---|---|
| `role` | string | req | `"assistant"` |
| `content` | string \| 块数组 | req | 纯文本或内容块列表 |
| `tool_calls` | array | opt | 本回合的 OpenAI 风格函数调用 |

**嵌套层 —— assistant `content` 块**（块 `type` 区分器）：

| 块 `type` | 字段 | 类型 | 含义 |
|---|---|---|---|
| `think` | `type`, `think`, `encrypted` | str, **string（reasoning 文本）**, null | 思维链；`encrypted` 在所有实时数据中为 null |
| `text` | `type`, `text` | str, string | 可见的助手散文 |

**嵌套层 —— assistant `tool_calls[]`**（实时键集 `function,id,type`）：

| 字段 | 类型 | 含义 | 示例 |
|---|---|---|---|
| `id` | string | tool 调用 id；关联到 `tool.tool_call_id` + wire `ToolCall.payload.id` | `"tool_<rand>"` |
| `type` | string | 始终为 `"function"` | `"function"` |
| `function.name` | string | tool 名称 | `"<ToolName>"` |
| `function.arguments` | **string** | JSON 编码的参数（字符串化，而非对象） | `"{\"<arg>\":\"<val>\"}"` |

> **DISCREPANCY（实时 vs 适配器 —— 助手正文丢失，HIGH 影响）：** 两个
> 适配器都用一个 **仅字符串** 的访问器读取正文：
> - Swift `KimiAdapter.swift:258` → `JSONLAdapterSupport.string(object["content"]) ?? ""`
> - TS `kimi.ts:226` → `typeof obj.content === 'string' ? obj.content : ''`
>
> 当 `content` 是 **数组**（占主导的实时情形）时，两者都返回 `""`。因此
> 对数组形式的会话来说 **助手文本与 reasoning 都被丢弃**；消息仍被 *计数*
> （所以 `assistantMessageCount` 是对的），但它的 transcript/搜索正文是 **空的**。
> fixtures 只演练了 **字符串** 形式，所以 parity 测试从不会捕获到这一点。
> **以实时为准：助手内容在该字段中是数组形态；被索引的正文为空。**

### 6c. `tool` record
`content` **通常是结果块数组**，但 **偶尔是普通字符串**（实时：数组 ≫ 字符串
—— 例如在 80 个文件的样本中 77 个数组 vs 11 个字符串 `tool` 记录）；`tool_call_id`
关联回助手调用。Engram **不索引**。

```json
{"role": "tool", "tool_call_id": "tool_<rand>",
 "content": [{"type": "text", "text": "<tool output>"}]}
```

| 字段 | 类型 | 含义 |
|---|---|---|
| `role` | string | `"tool"` |
| `tool_call_id` | string | 关联到 `assistant.tool_calls[].id` |
| `content` | 块数组（通常） \| 普通字符串（偶尔） | 结果块，或一个原始字符串结果 |

**嵌套层 —— tool `content` 块：**

| 块 `type` | 字段 | 含义 |
|---|---|---|
| `text` | `type`, `text` | tool stdout / 文本结果（占主导） |
| `image_url` | `type`, `image_url{id,url}` | 图像结果（`image_url` 是一个对象） |

### 6d. Marker records（不承载消息）
- `_system_prompt`: `{"role":"_system_prompt","content":"<system text>"}`
- `_checkpoint`: `{"role":"_checkpoint","id":0}`（id 是 int）
- `_usage`: `{"role":"_usage","token_count":10863}`（运行中的上下文大小水位线）

---

## 7. Tool calls & results

**磁盘上（丰富）：** 调用 ↔ 结果的关联完整存在 ——
`assistant.tool_calls[].id`（字符串 `tool_<rand>`）连接到 `tool.tool_call_id`；
同一个 id 也以 `ToolCall.payload.id` 和
`ToolResult.payload.tool_call_id` 的形式出现在 `wire.jsonl` 中。错误信息
携带在 `wire.jsonl` `ToolResult.payload.return_value.is_error` + `.output`/`.message` 中。

**在 Engram 中（无）：** Kimi 适配器 **从不提取 tool 调用**。
`KimiAdapter.message(...)` 始终传入 **`toolCalls: nil`**
（`KimiAdapter.swift:260`）；TS 省略该字段。parity fixture 确认
`"toolCalls": []`，`toolCallCount: 0`。`tool` 角色记录（样本中 167 个；
重度会话中约占对话记录的 ~24%）被完全丢弃：
`toolMessageCount` 硬编码为 `0`（`KimiAdapter.swift:82`，`kimi.ts:153`）。

```json
// assistant tool_calls[i] (live, anonymized)
{"id": "tool_<rand>", "type": "function",
 "function": {"name": "<ToolName>", "arguments": "{\"<arg>\":\"<val>\"}"}}
// matching tool result record
{"role": "tool", "tool_call_id": "tool_<rand>",
 "content": [{"type": "text", "text": "<tool output>"}]}
```

---

## 8. Reasoning / thinking

**磁盘上存储：** 是。助手 reasoning 存在于 `type: "think"` 的 `content` 块中
（字段 `think` = 纯文本 reasoning 字符串；`encrypted` 在所有实时数据中为 null）。
同时以 `ContentPart` 事件的形式在 `wire.jsonl` 中流式输出，形态为
`{type:"think",think,encrypted}`。`config.toml` `default_thinking=true` +
`show_thinking_stream=true` 证实 reasoning 在 Kimi 中是一等公民。

**被 Engram 捕获：** 否。因为 `think` 是一个数组块，而适配器
使用仅字符串的内容访问器（§6b），reasoning 被丢弃为 `""`。Engram
对 Kimi 没有单独的 reasoning/thinking 字段。

---

## 9. Token usage & cost

**来源：** `wire.jsonl` `StatusUpdate.payload.token_usage`（`context.jsonl` 内部
的 `_usage` 记录被 **忽略**）。实时 `token_usage` 键集
（采样 30/30）：`input_cache_creation, input_cache_read, input_other, output`。

```json
{"timestamp": 1770000060.0, "message": {"type": "StatusUpdate", "payload": {
  "context_usage": <float>, "context_tokens": <int>, "max_context_tokens": <int>,
  "token_usage": {"input_other": <int>, "output": <int>,
                  "input_cache_read": <int>, "input_cache_creation": <int>},
  "message_id": "<id>", "plan_mode": <bool>, "mcp_status": null}}}
```

映射（`usage(from:)` `KimiAdapter.swift:265-281`）：

| 源字段 | Engram `TokenUsage` |
|---|---|
| `input_other` | `inputTokens` |
| `output` | `outputTokens` |
| `input_cache_read` | `cacheReadTokens` |
| `input_cache_creation` | `cacheCreationTokens` |

每回合用量在一对 `TurnBegin`/`TurnEnd` 之间的所有 `StatusUpdate` 上
**累加**，并附加到该回合的助手消息上
（`accumulatedUsage`，`KimiAdapter.swift:283-291`）。全零用量被丢弃为
`nil`（`KimiAdapter.swift:273-279`）。**不计算成本**（未解析 model 价格）。

> **Swift/TS PARITY GAP（真实分歧）：** TS `readTurnTimestamps`
> （`kimi.ts:303-327`）**只** 读取 `TurnBegin`/`TurnEnd`，从不读取
> `StatusUpdate`/`token_usage`。**只有 Swift 产品解析器填充
> 用量；TS 参考适配器不发出任何 token 数据。** parity fixture 的
> `usageTotals` 全为零，所以这个缺口未被覆盖。

---

## 10. Subagent / parent-child / dispatch

**磁盘上：** Kimi 拥有一个 **一等的 subagent 模型**：
- 每个会话有 `subagents/<9-hex id>/`：完整的子对话，拥有自己的
  `context.jsonl`/`wire.jsonl`/`meta.json`/`prompt.txt`/`output`。
- `meta.json` 键（实时）：`agent_id, subagent_type, status, description,
  created_at, updated_at, last_task_id, launch_spec`。
- `wire.jsonl` `SubagentEvent`（样本中 131 个）包裹一个完整的子事件流：
  `{parent_tool_call_id, agent_id, subagent_type, event{type,payload}}`（内层
  `event.payload` 镜像 ToolCall/ToolResult/StatusUpdate/TurnBegin/
  StepBegin 的形态）。

**在 Engram 中：** Kimi subagent context 会作为独立子会话枚举。
`subagents/<id>/context.jsonl` 会成为一个 Kimi 会话，`id=<id>`，
`agentRole="subagent"`，`parentSessionId=<parent session id>`。没有
`.engram.json` 旁车文件（那是 Gemini-CLI 的机制）；`suggestedParentId`
仍为 nil，因为父级来自路径推导。

---

## 11. Summary / compaction

- **Summary：** Engram 的会话 `summary` = **首条用户消息文本**，
  `prefix(200)`（`KimiAdapter.swift:67,84`，`kimi.ts:124,155`）。Kimi 自己
  生成的标题（`state.json.custom_title`）被 **忽略**（见 §15）。
- **Compaction：** 磁盘上以 `_checkpoint` 记录（`context.jsonl`）和
  `CompactionBegin`/`CompactionEnd` 事件（`wire.jsonl`；驼峰式单 token，
  无空格 —— 与其他所有 wire `message.type` 一样）的形式存在，由
  `config.toml` `compaction_trigger_ratio=0.85` / `reserved_context_size=50000` 驱动。
  Engram 跳过 `_checkpoint` 且不解释压缩。
  `context_<N>.jsonl` / `context_sub_<N>.jsonl` 轮转分片是增长超出窗口后在磁盘上的后果。

---

## 12. SQLite / DB internals

**N/A for Kimi。** Kimi 使用 **无数据库** —— 纯扁平 JSONL + JSON 旁车文件。
（`find ~/.kimi` 显示没有 `.sqlite`/`.vscdb`/leveldb。）这与
别处记录的 DB 支持的工具（Cursor / VS Code / Copilot / Cline 使用
`.vscdb`/leveldb）形成对比。

---

## 13. Auxiliary files

### 13a. `~/.kimi/kimi.json` — workspace registry (PARSED for cwd)
单一对象，唯一顶层键 `work_dirs[]`。**实时 49 个条目**（每个 workspace 一个，
以 *最后一个* 会话为键）。

```json
{"work_dirs": [{"path": "<absolute cwd>", "kaos": "local", "last_session_id": "<uuid>"}]}
```

| 字段 | 类型 | 含义 | Engram 用途 |
|---|---|---|---|
| `path` | string | 绝对工作目录 | → 会话 `cwd` |
| `kaos` | string | 存储类标签（`"local"`） | 未使用 |
| `last_session_id` | string | 该 cwd 最近的会话 uuid | cwd 查找的匹配键 |

> **LIMITATION：** 只有 **49** 个 work_dirs vs **573** 个会话目录 → 只有
> 每个 workspace 最近的会话能解析出 cwd；其余的会得到 `cwd = ""`。
> 备份 `kimi.json.bak-*` 是轮转副本，不被读取。

### 13b. `state.json` — session lifecycle (NOT parsed)
跨 200 个实时会话的键的并集（最常见的在前；199/200 携带
title/archive/todo 集合，1 个较新 schema 变体改为携带 `dynamic_subagents`）：

| 字段 | 类型 | 含义 |
|---|---|---|
| `version` | int | state schema 版本 |
| `approval` | object | `{yolo, afk, auto_approve_actions[]}` 权限状态 |
| `additional_dirs` | array | 额外允许的 workspace 目录 |
| `custom_title` / `title_generated` / `title_generate_attempts` | str? / bool / int | 会话标题生成状态 |
| `plan_mode` / `plan_session_id` / `plan_slug` | bool / str / str | plan 模式关联 |
| `wire_mtime` | null | 缓存的 wire mtime |
| `archived` / `archived_at` / `auto_archive_exempt` | bool / null·num / bool | 归档生命周期 |
| `todos` | array | 会话待办列表 |
| `dynamic_subagents` | array/object | （较新 schema 变体）动态注册的 subagents |

### 13c. Subagent `meta.json` (NOT parsed)
`agent_id, subagent_type, status, description, created_at(num), updated_at(num),
last_task_id, launch_spec(obj)`。

### 13d. Task files (NOT parsed)
- `spec.json`: `version, id, kind, session_id, description, tool_call_id,
  owner_role, created_at(num), command, shell_name, shell_path, cwd, timeout_s,
  kind_payload(obj)`。
- `runtime.json`: `status, worker_pid, child_pid, child_pgid, started_at,
  heartbeat_at(num), updated_at(num), finished_at(num), exit_code, interrupted,
  timed_out, failure_reason`。
- `control.json`、`consumer.json`、`output.log` —— 控制/纯文本。

### 13e. Notification files (NOT parsed)
- `event.json`: `version, id, category, type, source_kind, source_id, title,
  body, severity, created_at(num), payload(obj), targets(arr), dedupe_key`。
- `delivery.json`: `sinks(obj)`。

### 13f. `config.toml` (NOT parsed) — 但保存着 model
```toml
default_model = "kimi-code/kimi-for-coding"
[models."kimi-code/kimi-for-coding"]
provider = "managed:kimi-code"
model = "kimi-for-coding"
display_name = "Kimi-k2.6"
[providers."managed:kimi-code"]
type = "kimi"
base_url = "https://api.kimi.com/coding/v1"
```
尽管这是可用的，Engram 仍把 Kimi 的 `model` 留为 `nil`（见 §15）。

> **Confirmed（官方，web-checked 2026-06-21）：** 官方 Config/Providers
> 文档显示 `default_model = "kimi-code/kimi-for-coding"`，provider
> `managed:kimi-code`（`type='kimi'`，`base_url='https://api.kimi.com/coding/v1'`），
> 源码 `config.py` 确认 `compaction_trigger_ratio` 默认 0.85、
> reserved context size 默认 50000，以及 `default_thinking` + `show_thinking_stream`。
> `display_name = "Kimi-k2.6"` 字符串是一个 **依赖用户配置** 的人类可读
> 标签（通过 `config.py` `LLMModel.display_name` 由 provider 提供），而非固定
> 常量。
> [Providers docs](https://moonshotai.github.io/kimi-cli/en/configuration/providers.html),
> [config.py](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/config.py)

---

## 14. Engram mapping

`SessionInfo` 字段 → 真相来源 → 适配器 `file:line`（Swift 产品 + TS 参考）：

| Engram 字段 | 真相来源 | Swift `KimiAdapter.swift` | TS `kimi.ts` | 注意 / 陷阱 |
|---|---|---|---|---|
| `id` | 会话目录 UUID = `basename(dirname(context.jsonl))`；subagent 使用 subagent 目录 id | `:78,194-210` | `:86-91,307-325` | workspace 哈希被丢弃。TS 防护 `''`/`.`/`..`；Swift 无防护。 |
| `source` | 常量 `.kimi` | `:73` | `:146` | |
| `startTime` | `wire.jsonl` 中首个 `TurnBegin` ts | `:74,200-208,223` | `:88,138-141,316-317` | 回退：Swift = wireStart → `mtime-60s`；TS = wireStart → 首行 ts → `mtime-60s`。实时没有行 ts。 |
| `endTime` | 最后一回合的 `TurnEnd`（否则其 begin）；若 == start 则发出 nil | `:75,207,225` | `:89-92,142,318-321` | "首个 TurnEnd 胜出" —— 可能反映一个早期子回合。 |
| `cwd` | `kimi.json` `work_dirs[].path`，以 `last_session_id == id` 为键；subagent 通过父 session id 解析 | `:82,168-180` | `:93,356-378` | 无匹配则为 `""` → 只有每个 workspace 最近的父会话能解析。 |
| `project` | 始终 `nil` | `:77` | n/a | 下游从 cwd 派生。 |
| `model` | 始终 `nil` | `:78` | n/a | 在 `config.toml` 中可用（Kimi-k2.6），但从不解析。 |
| `messageCount` | `userCount + assistantCount` | `:79` | `:150` | **排除 `tool`** → 计数偏低。 |
| `userMessageCount` | 计数 `role=="user"` | `:59,80` | `:122-126,151` | |
| `assistantMessageCount` | 计数 `role=="assistant"` | `:60,81` | `:127-129,152` | |
| `toolMessageCount` | 硬编码 `0` | `:82` | `:153` | 尽管有许多实时 `tool` 记录。 |
| `systemMessageCount` | 硬编码 `0` | `:83` | `:154` | `_system_prompt` 存在但从不计数。 |
| `summary` | 首条用户消息文本，`prefix(200)` | `:67,84` | `:124,155` | **`state.json.custom_title` 被忽略。** |
| `sizeBytes` | 该 locator 的 `context.jsonl` + 所有 `context_<N>.jsonl` / `context_sub_<N>.jsonl` 之和 | `:54-62,92,212-238` | `:106-114,163,253-273,328-331` | `wire.jsonl`/`state.json` 被排除。 |
| `filePath` | 到 `context.jsonl` 的绝对路径 | `:85` | `:156` | 定位符。 |
| per-msg `role` | `user→.user`，`assistant→.assistant` | `:257` | `:225` | 只会产生 2 种角色。 |
| per-msg `content` | `obj.content` 作为字符串 | `:258` | `:226` | **数组内容（think/text）→ 空字符串。** |
| per-msg `timestamp` | 通过状态机的 wire 回合 ts；否则行 ts（实时缺失） | `:137-149,300-308` | `:203-228,237-243` | 见 §15 #1。 |
| per-msg `usage` | wire `StatusUpdate.token_usage`（仅助手） | `:145,261,265-281` | **未实现** | **仅 Swift。** |
| per-msg `toolCalls` | 始终 `nil` | `:260` | 省略 | tool 调用从不浮现。 |
| `agentRole` / `parentSessionId` | 对 `subagents/<id>/context.jsonl` 从路径推导 | `:94,100,194-210` | `:164-165,307-325` | 主会话两者均为 nil；subagent 使用 `agentRole="subagent"` 和父会话 id。 |
| `originator`/`origin`/`suggestedParentId`/`tier`/`qualityScore` | 全为 `nil` | `:95-101` | n/a | Kimi 没有 originator/tier 特例。 |

**发现遍历**（两个适配器）：
1. `detect()` —— 当且仅当 `~/.kimi/sessions/` 是一个目录时为真（`KimiAdapter.swift:25-27`，`kimi.ts:42-49`）。
2. 枚举 `sessions/<workspace>/<session>/context.jsonl` 以及直接子目录
   `sessions/<workspace>/<session>/subagents/<id>/context.jsonl`；定位符 =
   到 `context.jsonl` 的绝对路径；会话 id = 父目录名
   （`listSessionLocators` `:34-50`；`listSessionFiles` `:51-81`）。Swift 对结果排序。
3. `parseSessionInfo(locator)` 读取主文件 + `context_<N>` / `context_sub_<N>`
   分片（拼接），计数 user/assistant，summary = 首条用户文本，ts 来自
   `wire.jsonl`，cwd 来自 `kimi.json`（subagent 使用父 id）。

---

## 15. Lineage, gotchas, version drift & edge cases

**格式血统 —— BESPOKE（自定义）。** Kimi/Moonshot CLI 有它 **自己的** 格式。
`context.jsonl` / `wire.jsonl` / `state.json` 三件套以及 `wire.jsonl` 的
`protocol_version` 是 Kimi 独有的。它不属于任何已记录的同类家族：既不是
Gemini-CLI ↔ Qwen ↔ iFlow（chat-JSON 血统），也不是
Cursor ↔ VS Code ↔ Copilot ↔ Cline（`.vscdb`/leveldb）。可交叉参考那些
文档作对比，但没有任何共享。Kimi 是一个纯 JSONL 适配器（无 gRPC），
所以它不在 `enableLiveSync:false` 仅缓存集合
（Windsurf/Antigravity）中。**Confirmed（官方）：** 三件套和带
`protocol_version` 的 wire 信封是定义在 MoonshotAI/kimi-cli 自家源码
（`wire/protocol.py`、`metadata.py`、`soul/context.py`）中的 Kimi 特有构造；
没有任何 schema 与 Gemini-CLI 或 OpenAI/Codex 共享。
[wire/protocol.py](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/wire/protocol.py),
[metadata.py](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/metadata.py)

> **CONTEXT —— 新的 `kimi-code` 存储（web-checked 2026-06-21，D3）。** 本文档
> 限定于 `~/.kimi/` 下的 **遗留 Python `kimi-cli`** 存储。Moonshot 此后
> 已发布一个 **新的 TypeScript `kimi-code` CLI**，其默认存储为
> `~/.kimi-code/`（`KIMI_CODE_HOME`），布局不同：
> `sessions/<workDirKey>/<sessionId>/{state.json, agents/main/wire.jsonl,
> agents/<subagentId>/wire.jsonl}`，一个顶层 `session_index.jsonl`，以及
> `workDirKey = 'wd_<slug>_<first-12-of-sha256>'`（**不是裸 md5**）。如果用户
> 已迁移（`.migrated-to-kimi-code` 标记），新会话会以新布局落到
> `~/.kimi-code/`，而 Engram 仅限 `~/.kimi` 的适配器将 **看不到** 它们。
> [Data locations](https://www.kimi.com/code/docs/en/kimi-code-cli/configuration/data-locations.html),
> [Sessions](https://www.kimi.com/code/docs/en/kimi-code-cli/guides/sessions.html)

**陷阱 / 边界情况：**
1. **agentic 会话上的回合状态机错位（HIGH）。** 两个适配器
   假设每个 wire 回合 ≤1 个 user + ≤1 个 assistant（`KimiAdapter.swift:128-143`，
   `kimi.ts:203-216`）。实时的多步会话严重违反这一点（助手
   记录 ≫ `TurnBegin` 计数）。当助手 ≫ 回合时，索引会走出
   `turns[]` 的末尾（`turnIndex < turns.count` 防护 → nil），大多数助手
   消息得不到 **时间戳**。对干净交替的 fixture 测试良好；
   不能代表真实的使用 tool 的会话。
2. **`TurnBegin` 计数 ≫ `TurnEnd` 计数是正常的。** 实时 wire 日志通常
   有约 2 倍多的 `TurnBegin`（子回合/中断）。"首个 TurnEnd 胜出"
   （`:225`）意味着 `endTime` 可能反映一个早期子回合，而非真正的最后
   活动。
3. **`tool` 角色被丢弃 → 消息计数偏低 + 丢失 tool I/O（MEDIUM）。** 许多
   实时 `tool` 记录（重度会话中约占对话记录的 ≈24%）被
   排除在计数和 transcript 之外。任何使用 `messageCount` 的功能
   （tiering、sparklines）都会低报 Kimi。
4. **数组内容被静默清空（MEDIUM/HIGH）。** Kimi 占主导的助手
   格式是数组块（`think`/`text`）；仅字符串的访问器把可见答案 AND
   reasoning 都丢弃为 `""`，影响大多数助手回合。对 Kimi 会话的
   FTS/搜索很大程度上会是空的。fixture（仅字符串）掩盖了它。
5. **`custom_title` 被忽略（LOW-MED）。** 约 199/200 个实时会话携带一个
   `state.json.custom_title`，但 Engram 使用截断到 200 字符的原始首条用户文本。
6. **实时没有行级时间戳 → `wire.jsonl` 是强制的。** 零个实时
   `context.jsonl` 记录拥有 `timestamp`。如果 `wire.jsonl` 缺失，Swift
   只回退到 `mtime-60s`（TS 额外尝试行 ts，但同样缺失）。
   行级 ts 只出现在 `schema_drift.jsonl` fixture 中。
7. **`protocol_version` 漂移未受防护。** 实时 wire 头部（全部 452 个
   会话级 `wire.jsonl` 的首行）：**1.3、1.5、1.9（占主导）、1.10** ——
   `Counter{1.9: 436, 1.10: 12, 1.3: 2, 1.5: 2}`。（四个都出现在实时数据中；
   1.3 不只是 fixture 才有。）任何一个适配器都不读取它或基于它做版本门控，所以
   未来的 wire schema 变更（重命名消息类型、新的 `token_usage` 键）
   会在没有错误的情况下静默降级时间戳/token。
   **Confirmed（官方）：** 源码 `wire/protocol.py` 定义了
   `WIRE_PROTOCOL_VERSION = "1.10"`（当前）和 `WIRE_PROTOCOL_LEGACY_VERSION =
   "1.1"`；官方 Wire Protocol 文档声明 "当前协议版本是
   1.10"。该值是一个自由字符串，所以较旧的 `1.3`/`1.5`/`1.9` 头部仍持续存在，
   "漂移未受防护" 的论断成立。注意源码 LEGACY 常量是
   `1.1` —— 比任何实时观察到的值都更旧。
   [wire/protocol.py](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/wire/protocol.py),
   [Wire Protocol docs](https://www.kimi.com/code/docs/en/kimi-code-cli/customization/wire-protocol.html)
8. **cwd 解析有损。** 只有 workspace 最近的会话
   （`last_session_id`）能解析出 cwd；所有共享该 workspace
   哈希的之前的会话都得到 `cwd == ""`。32 位十六进制目录名是 **`md5(cwd)`**，
   且从不被反向映射 —— 但它 *可以* 正向计算，所以一个未被利用的修复是
   构建一个 `md5(work_dirs[].path) → path` 映射，覆盖每个 workspace，而不只是
   最后一个会话。**Confirmed（官方）：** `md5(cwd)` 可从
   `kimi.json` `work_dirs[].path` 正向计算；源码 `metadata.py` 正是以此方式构建目录名
   （对于本地 kaos）。
   [metadata.py](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/metadata.py)
9. **Swift vs TS 分歧：**（a）token 用量 —— Swift 读取 `StatusUpdate`，TS
   不读；（b）startTime 回退 —— TS 有一个 Swift 缺少的行 ts 层级；
   （c）session-id 合理性防护 —— 仅 TS；（d）`_checkpoint` —— TS 显式
   `continue`，Swift 通过 `isConversation` 过滤（净效果相同）。
10. **`context_<N>.jsonl` 轮转分片支持已修正（web-checked
    2026-06-21；adapter-fixed 2026-06-30）。** 当前 kimi-cli 源码通过
    `utils/path.next_available_rotation` 把轮转分片命名为
    `context_<N>.jsonl`（`context_1.jsonl`、`context_2.jsonl` 等）；较旧的
    本地存储仍可能包含 `context_sub_<N>.jsonl`。当前适配器两类都匹配，
    因此这在当前 worktree 中不再是活跃适配器缺口。
    [next_available_rotation](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/utils/path.py)
11. **`state.json` schema 漂移。** 一个较新变体携带 `dynamic_subagents`
    并省略 title/archive/todo 块（实时 1/200）。Dim 2 声称的
    `_system_prompt.id:null` 在实时未被复现（根本没有 `id` 键）。

**OPEN 问题 / 未验证**（继续传递）。下列每一项都是一个
**Engram 内部的适配器设计决策，而非一个可经 web 验证的工具格式
事实**；它们所依赖的底层磁盘事实在上文都已源码确认（web-checked 2026-06-21）：

- 把数组 `think`/`text` 块提取进 transcript 内容？*（Engram 内部
  设计 —— 不可经 web 验证；数组内容块已确认存在，§6b。）*
- 计数/浮现 `tool` 记录？*（Engram 内部设计 —— 不可经 web 验证；
  `tool` 记录已确认存在，§6c。）*
- 把 `state.json.custom_title` 用作标题？*（Engram 内部设计 —— 不可
  经 web 验证；`custom_title` 已确认存在于 `state.json` 中，
  [session_state.py](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/session_state.py)。）*
- 用基于事件的对齐（`ContentPart`/`StepBegin`/`ToolResult`）替换
  wire 回合状态机？*（Engram 内部设计 —— 不可
  经 web 验证；那些 wire 类型已确认，§16。）*
- 让 TS 在 `token_usage` 上达到 parity？*（Engram 内部设计 —— 不可
  经 web 验证。）*
- 把 `config.toml` model 解析进 `model`？*（Engram 内部设计 —— 不可
  经 web 验证；`config.toml` 已确认携带 model，
  [config.py](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/config.py)。）*
- 为较旧会话反向映射 / 正向映射 `md5(cwd)`？*（Engram 内部
  设计 —— 不可经 web 验证；`md5(cwd)` 已确认可从
  `kimi.json` `work_dirs[].path` 正向计算，
  [metadata.py](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/metadata.py)。）*
- 在当前路径推导的 `parentSessionId` 链接之外，给 Kimi subagents 添加更丰富的
  UI 分组？*（Engram 内部设计 —— 不可经 web 验证；subagents 在磁盘上是一等公民，
  [subagents/store.py](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/subagents/store.py)。）*

**对照官方来源确认的格式事实（web-checked 2026-06-21）：**
下列各项之前被框定为 "待验证"，现已被源码确认
并折入上文正文：

- Confirmed（官方）：`wire.jsonl` 信封是 `{timestamp:float（epoch
  秒）, message:{type,payload}}`，带首行头部
  `{type:"metadata", protocol_version:str}`。
  [wire/file.py](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/wire/file.py)
- Confirmed（官方）：wire `message.type` 集合（TurnBegin/TurnEnd、StatusUpdate、
  ToolCall/ToolCallPart、ToolResult、ContentPart、StepBegin/StepInterrupted、
  SubagentEvent、CompactionBegin/CompactionEnd、SteerInput、ApprovalRequest/
  Response、Notification）是真实的；spec 还添加了实时扫描未浮现的
  StepRetry、PlanDisplay、HookTriggered/HookResolved。
  [Wire Protocol docs](https://www.kimi.com/code/docs/en/kimi-code-cli/customization/wire-protocol.html)
- Confirmed（官方）：`StatusUpdate.token_usage` 键恰好是
  `input_other`、`output`、`input_cache_read`、`input_cache_creation`。
  [Wire Protocol docs](https://www.kimi.com/code/docs/en/kimi-code-cli/customization/wire-protocol.html)
- Confirmed（官方）：存储根是 `~/.kimi/`（`KIMI_SHARE_DIR` 可覆盖）；
  `kimi.json` 是 workspace 注册表，含 `work_dirs[]`，元素为
  `{path, kaos, last_session_id}`。
  [share.py](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/share.py),
  [metadata.py](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/metadata.py)
- Confirmed（官方）：每个会话是一个目录，含 `context.jsonl` +
  `wire.jsonl` + `state.json`。
  [session.py](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/session.py),
  [session_state.py](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/session_state.py)
- Confirmed（官方）：marker 记录形态 —— `_system_prompt` 没有 `id`
  （`{role,content}`），`_checkpoint = {role, id:int}`，`_usage = {role,
  token_count:int}`（这解决了旧的 "Dim 2" `id:null` 说法）。
  [soul/context.py](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/soul/context.py)
- Confirmed（官方）：subagent 布局 `subagents/<id>/{context.jsonl,
  wire.jsonl, meta.json, prompt.txt, output}`，`meta.json` 键为
  `agent_id/subagent_type/status/description/created_at/updated_at/last_task_id/
  launch_spec`；新的 kimi-code 改用 `agents/main/` + `agents/<id>/`。
  [subagents/store.py](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/subagents/store.py)
- Confirmed（官方）：notification 文件是 `notifications/<id>/event.json` +
  `delivery.json`。
  [notifications/store.py](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/notifications/store.py)
- Confirmed（官方）：`config.toml` 结构 & 默认值 —— `default_model =
  "kimi-code/kimi-for-coding"`，provider `managed:kimi-code`（`type='kimi'`，
  `base_url='https://api.kimi.com/coding/v1'`），`compaction_trigger_ratio` 0.85，
  reserved context size 50000，`default_thinking` true。`display_name "Kimi-k2.6"`
  是一个依赖用户配置的人类可读标签（由 provider 提供），而非固定
  常量。
  [Providers docs](https://moonshotai.github.io/kimi-cli/en/configuration/providers.html),
  [config.py](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/config.py)
- Confirmed（官方）：无数据库 —— 会话持久化是扁平 JSONL + JSON
  旁车文件，通过普通文件写入完成；没有 SQLite/leveldb/gRPC。（新的 kimi-code 添加了一个
  `session_index.jsonl` 索引文件，仍是 JSONL，而非 DB。）
  [session.py](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/session.py)
- Confirmed（部分，官方）：轮转分片在当前源码中是 `context_<N>.jsonl`，
  而非 `context_sub_<N>.jsonl`；`context_1.jsonl` 是
  合法的当前分片（见陷阱 #10，D1）。
  [next_available_rotation](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/utils/path.py)

---

## 16. Appendix: real anonymized samples

**`context.jsonl` — `user` record：**
```json
{"role": "user", "content": "<user prompt text>"}
```

**`context.jsonl` — `assistant` record（数组内容 + tool_calls）：**
```json
{"role": "assistant",
 "content": [
   {"type": "think", "think": "<reasoning text>", "encrypted": null},
   {"type": "text",  "text":  "<visible answer text>"}],
 "tool_calls": [
   {"id": "tool_<rand>", "type": "function",
    "function": {"name": "<ToolName>", "arguments": "{\"<arg>\":\"<val>\"}"}}]}
```

**`context.jsonl` — `assistant` record（字符串内容，罕见）：**
```json
{"role": "assistant", "content": "<visible answer text>"}
```

**`context.jsonl` — `tool` record：**
```json
{"role": "tool", "tool_call_id": "tool_<rand>",
 "content": [{"type": "text", "text": "<tool output>"}]}
```

**`context.jsonl` — marker records：**
```json
{"role": "_system_prompt", "content": "<system text>"}
{"role": "_checkpoint", "id": 0}
{"role": "_usage", "token_count": 10863}
```

**`wire.jsonl` — header line（第 1 行）：**
```json
{"type": "metadata", "protocol_version": "1.9"}
```

**`wire.jsonl` — event lines：**
```json
{"timestamp": 1770000000.0, "message": {"type": "TurnBegin", "payload": {"user_input": "<str or [{type:text,text}]>"}}}
{"timestamp": 1770000060.0, "message": {"type": "StatusUpdate", "payload": {
  "context_usage": <float>, "context_tokens": <int>, "max_context_tokens": <int>,
  "token_usage": {"input_other": <int>, "output": <int>,
                  "input_cache_read": <int>, "input_cache_creation": <int>},
  "message_id": "<id>", "plan_mode": false, "mcp_status": null}}}
{"timestamp": 1770000090.0, "message": {"type": "ToolCall", "payload": {
  "type": "function", "id": "tool_<rand>",
  "function": {"name": "<ToolName>", "arguments": "<json-string>"}, "extras": {}}}
{"timestamp": 1770000091.0, "message": {"type": "ToolResult", "payload": {
  "tool_call_id": "tool_<rand>",
  "return_value": {"is_error": false, "output": "<str>", "message": "<str>", "display": [], "extras": {}}}}
{"timestamp": 1770000120.0, "message": {"type": "TurnEnd", "payload": {}}}
```

**`wire.jsonl` — 实时观察到的完整 `message.type` 集合（16）：**
对全部 452 个非空会话级 `wire.jsonl` 文件的 `message.type` 进行
确凿扫描，得到 **16 种不同的顶层类型**（全为驼峰式单
token，含 Compaction 这一对）：
`SubagentEvent, ToolCall, ToolResult, ContentPart, StepBegin, StatusUpdate,
ToolCallPart, TurnBegin, TurnEnd, Notification, StepInterrupted, SteerInput,
ApprovalRequest, ApprovalResponse, CompactionBegin, CompactionEnd`
（加上头部 `type: metadata`）。每类型计数（本次扫描）：`SubagentEvent`
6562，`ToolCall` 2028，`ToolResult` 2023，`ContentPart` 1999，`StepBegin` 1551,
`StatusUpdate` 1499，`ToolCallPart` 1450，`TurnBegin` 556，`TurnEnd` 527,
`Notification` 55，`StepInterrupted` 27，`SteerInput` 5，`ApprovalRequest` 4,
`ApprovalResponse` 4，`CompactionBegin` 2，`CompactionEnd` 2。Engram 只读取
`TurnBegin`、`TurnEnd`、`StatusUpdate`。

**`~/.kimi/kimi.json`：**
```json
{"work_dirs": [{"path": "<absolute cwd>", "kaos": "local", "last_session_id": "<session-uuid>"}]}
```

**`state.json`（NOT parsed）：**
```json
{"version": <int>, "approval": {"yolo": false, "afk": false, "auto_approve_actions": []},
 "additional_dirs": [], "custom_title": "<str?>", "title_generated": false,
 "title_generate_attempts": 0, "plan_mode": false, "plan_session_id": "<str>",
 "plan_slug": "<str>", "wire_mtime": null, "archived": false, "archived_at": null,
 "auto_archive_exempt": false, "todos": []}
```

**Subagent `meta.json`（NOT parsed）：**
```json
{"agent_id": "<9hex>", "subagent_type": "<str>", "status": "<str>",
 "description": "<str>", "created_at": <num>, "updated_at": <num>,
 "last_task_id": null, "launch_spec": {}}
```

**Task `spec.json` / `runtime.json`（NOT parsed）：**
```json
{"version": <int>, "id": "<str>", "kind": "<str>", "session_id": "<uuid>",
 "description": "<str>", "tool_call_id": "tool_<rand>", "owner_role": "<str>",
 "created_at": <num>, "command": "<str?>", "shell_name": "<str?>",
 "shell_path": "<str?>", "cwd": "<str?>", "timeout_s": <num>, "kind_payload": {}}
{"status": "<str>", "worker_pid": <int?>, "child_pid": <int?>, "child_pgid": <int?>,
 "started_at": <num?>, "heartbeat_at": <num>, "updated_at": <num>, "finished_at": <num>,
 "exit_code": <int?>, "interrupted": false, "timed_out": false, "failure_reason": null}
```

**Engram 规范化输出（parity fixture `success.expected.json`，真实）。**
下面的片段 **只是 `sessionInfo` 节选**。实际 fixture 携带
**16 个顶层键**：`failure, fileToolCounts, generatedAtCommit, inputPath,
insightFields{firstUserSummary,messageCount,toolCallCount}, locator, messages[],
nodeVersion, projectFields{cwd,project,source}, schemaVersion,
searchIndexFields{contentPreview,contentSha256InputBytes,roles[]}, sessionInfo,
source, statsFields, toolCalls, usageTotals`。

```json
{"sessionInfo": {"id": "sess-001", "source": "kimi",
  "startTime": "2026-02-02T02:40:01.000Z", "endTime": "2026-02-02T02:41:00.000Z",
  "cwd": "/Users/test/my-project", "messageCount": 3,
  "userMessageCount": 2, "assistantMessageCount": 1,
  "toolMessageCount": 0, "systemMessageCount": 0,
  "summary": "<first user text ≤200>", "sizeBytes": 248},
 "toolCalls": [],
 "usageTotals": {"inputTokens": 0, "outputTokens": 0, "cacheReadTokens": 0, "cacheCreationTokens": 0}}
```

fixture 的 `messages[]` 数组具体演示了陷阱 #1 的
时间戳丢失 bug：**第 3 条消息（第 2 个 user）没有 `timestamp` 字段** ——
回合状态机用尽了 `turns[]` 条目，所以没有 wire 时间戳被
分配。（已匿名化为结构；fixture 文本是真实的，但此处略去。）

```json
"messages": [
  {"role": "user",      "content": "<u1>", "timestamp": "2026-02-02T02:40:01.000Z"},
  {"role": "assistant", "content": "<a1>", "timestamp": "2026-02-02T02:41:00.000Z"},
  {"role": "user",      "content": "<u2>"}
]
```

---

## References (official sources)

**官方仓库源码 —— MoonshotAI/kimi-cli（`src/kimi_cli/`）：**
- [config.py — config.toml structure, defaults, LLMModel.display_name](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/config.py)
- [metadata.py — WorkDirMeta.sessions_dir, md5(cwd)/kaos dir naming, kimi.json work_dirs](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/metadata.py)
- [session.py — session = directory of context/wire/state, flat-file persistence (no DB)](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/session.py)
- [session_state.py — state.json schema, custom_title](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/session_state.py)
- [share.py — store root ~/.kimi/ (KIMI_SHARE_DIR)](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/share.py)
- [soul/context.py — context.jsonl rotation, marker record shapes (_system_prompt/_checkpoint/_usage)](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/soul/context.py)
- [utils/path.py — next_available_rotation → context_<N>.jsonl shard naming](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/utils/path.py)
- [wire/protocol.py — WIRE_PROTOCOL_VERSION = 1.10, LEGACY = 1.1, message types](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/wire/protocol.py)
- [wire/file.py — wire.jsonl envelope + metadata header line](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/wire/file.py)
- [subagents/store.py — subagents/<id>/ layout + meta.json keys](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/subagents/store.py)
- [notifications/store.py — notifications/<id>/event.json + delivery.json](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/notifications/store.py)

**官方文档 —— Moonshot AI：**
- [Configuration / Providers (kimi-cli)](https://moonshotai.github.io/kimi-cli/en/configuration/providers.html)
- [Wire Protocol (kimi-code CLI)](https://www.kimi.com/code/docs/en/kimi-code-cli/customization/wire-protocol.html)
- [Data locations (kimi-code CLI)](https://www.kimi.com/code/docs/en/kimi-code-cli/configuration/data-locations.html)
- [Sessions (kimi-code CLI)](https://www.kimi.com/code/docs/en/kimi-code-cli/guides/sessions.html)

> Web confirmation pass applied 2026-06-21; all sources above are also cited inline in the relevant sections.
