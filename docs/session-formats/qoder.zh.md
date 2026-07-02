# Qoder 会话格式

> 本文档为英文权威版 qoder.md 的中文阅读副本;若有出入以英文版为准。

Last researched: 2026-06-21 (Engram session-format research workflow)
Engram adapter status refreshed: 2026-07-02 (local source/live DB audit)

> **证据基础:** 兼有 (1) **磁盘实时存储**,位于 `~/.qoder/projects/` —
> **7** 个项目目录、**13** 个顶层会话 `.jsonl` 文件、**44** 个
> subagent `.jsonl` 文件(共 **57** 个 `.jsonl`,**5021** 条记录),外加
> 每会话的 `state.json` / `compression-v2/state.json`,以及 subagent
> `*.meta.json` / `task-*.json` 旁车文件(**51** 个 meta.json + **51** 个 task-*.json
> 对 **44** 个 agent-*.jsonl 转录);以及 (2) 仓库 fixtures
> `tests/fixtures/qoder/sample.jsonl`(4 条记录)和
> `tests/fixtures/adapter-parity/qoder/{input/.../qoder-session.jsonl,
> success.expected.json}`(黄金一致性输出)。已与两个适配器交叉核对:
> Swift 产品适配器 `macos/Shared/EngramCore/Adapters/Sources/QoderAdapter.swift`
>(247 行)与 TS 参考适配器 `src/adapters/qoder.ts`(283 行)。
>
> 记录分类法(§4)是对**整个存储**(57 个文件,5021 条记录)做剖析,
> 而非单个会话 —— 早期草稿仅剖析了一个 52 行的会话
>(`4789761a`),恰好既不含全存储范围的 `token-stats`(215)也不含
> `system`(103)记录类型。
>
> **未发现冲突** —— 实时数据与适配器行为之间一致。两者在*覆盖范围*上
> 有差异之处,适配器读取的是 Qoder 写入内容的一个严格子集(已就地标注)。
> 所有引用的样本均已脱敏:消息文本 / 思考 /
> 代码 / 工具 I/O / 备份文件名 / 密钥 / 个人路径已被清洗,但
> **每一个键、类型和结构都逐字保留** —— 保留格式,不保留内容。

**当前 Engram 状态（2026-07-02）：** live store 和 DB 仍与 adapter 完全匹配：
57 个 JSONL 文件被列出并解析，44 个 subagent 行带 44 个 parent link，0 个 nested
workflow JSONL 文件，4,637 条 streamed message，0 个 parser/stream mismatch，57 个
DB 行，57 个 `file_index_state ok` 行，并且当前 id 中 0 missing、0 DB-only、0
field-stale。

Qoder 是一个 **Claude-Code-JSONL-家族** 存储。如果你读过 Claude Code
会话格式文档,这里的信封和内容块模型会很熟悉;
不过本文档仍是自包含的。关于精确的关系
请参见 [§15 谱系](#15-lineage-gotchas-version-drift--edge-cases) 以及 Qoder 的偏差。

---

## 1. 概览与速览

**是什么:** Qoder(一款 AI 编码 IDE/CLI)将每段对话记录为一份
**仅追加(append-only)的 JSONL 转录** —— 每行一个 JSON 对象,UTF-8。其模式
几乎是 Anthropic Claude Code 转录的克隆(相同的 `type`/`message`/
内容块模型,相同的 `toolu_*`/`call_*` 各后端不透明工具 ID,相同的
Anthropic 形态的 `usage`,相同的 `~/.<tool>/projects/<encoded-cwd>/<uuid>.jsonl`
布局)。工具调用 ID **带后端标签且多后端** —— `toolu_vrtx_*`
(Vertex/Google,占多数)、`toolu_bdrk_*`(Bedrock)、`call_*` /
`chatcmpl-tool-*`(OpenAI 兼容)以及裸 UUID —— 因此前缀揭示了
哪个后端服务了某一轮,但不透明的 `model` 别名隐藏了它(§5、§15)。

**在哪里:** `~/.qoder/projects/<encoded-cwd>/<session-uuid>.jsonl`。

**如何保存:** 每一轮追加一行;文件从不被就地重写。
在每份转录旁,Qoder 维护一个**同名的兄弟目录**
(`<session-uuid>/`,无扩展名),其中存放会话状态、上下文压缩
缓存以及派发出去的 subagent 产物。**没有 SQLite / leveldb / gRPC** —— 纯粹的
每会话一文件。

**心智模型:** 主转录 = Engram 解析的对话;兄弟目录
= Qoder 的内部簿记(状态、压缩、subagent),Engram 大多
忽略它,但 subagent `*.jsonl` 转录会成为子会话除外。

**所用证据基础:** 实时存储(横跨 7 个项目目录的 57 个 `.jsonl` 文件 / 5021 条记录)
+ fixtures(共 5 条 `.jsonl` 记录)+ 两个适配器。冲突时实时数据
为准。发现并相对早期草稿修正了一处冲突:
分类法是从单个会话剖析的,漏掉了两个全存储范围的
记录类型(`token-stats`、`system`);工具 ID 前缀曾被认为是
Bedrock 专属,但其实是多后端的(Vertex 占多数)。

### ASCII 布局 / 分层图

```
RECORD LAYER (one JSON object per line in the .jsonl)
  ┌──────────────────────────────────────────────────────────┐
  │ {type:"user"|"assistant", uuid, parentUuid, sessionId,    │  ← Engram parses
  │  timestamp, cwd, version, userType, entrypoint,           │     these two only
  │  isSidechain, isMeta?, promptId?, permissionMode?,        │
  │  sourceToolAssistantUUID?, toolUseResult?,                │
  │  message:{ ... } }                                        │
  ├──────────────────────────────────────────────────────────┤
  │ {type:"ai-title"|"last-prompt"|"file-history-snapshot"    │  ← Engram SKIPS
  │       |"token-stats"|"system"}                            │     (5 sidecar types)
  └──────────────────────────────────────────────────────────┘
        │ message
        ▼
  MESSAGE LAYER (Anthropic message object)
  ┌──────────────────────────────────────────────────────────┐
  │ {role, model?, id?, stop_reason?, stop_sequence?, usage?, │
  │  content: string | block[] }                             │
  └──────────────────────────────────────────────────────────┘
        │ content[]
        ▼
  CONTENT-BLOCK LAYER
  ┌──────────────────────────────────────────────────────────┐
  │ text · thinking · redacted_thinking · tool_use ·         │
  │ tool_result                                              │
  └──────────────────────────────────────────────────────────┘

ON-DISK LAYERING (per workspace)
  ~/.qoder/projects/<encoded-cwd>/
    ├── <uuid>.jsonl              ← MAIN transcript        (append-only) ✅ parsed
    └── <uuid>/                   ← sibling state dir      (same uuid, no ext)
        ├── state.json            ← session item/revision store (rewritten) ❌
        ├── compression-v2/state.json  ← compaction cache  (rewritten) ❌
        └── subagents/
            ├── agent-<id>.jsonl  ← SUBAGENT transcript    (append-only) ✅ child session
            ├── agent-<id>.meta.json  ← display metadata   (write-once) ❌
            └── task-<id>.json    ← dispatch/result record (rewritten) ❌
```

---

## 2. 磁盘布局与文件命名

| 属性 | 值 | 来源 |
|---|---|---|
| 磁盘根目录 | `~/.qoder/projects/` | `QoderAdapter.swift:9-11`, `qoder.ts:22` |
| 存储技术 | 仅追加 JSONL(每行一个 JSON 对象,UTF-8) | live store |
| 检测信号 | 根目录存在且为目录 | `QoderAdapter.swift:18-20`, `qoder.ts:25-32` |
| 产品 | Qoder IDE/CLI(`entrypoint:"cli"`、`userType:"external"`、Anthropic 形态 `usage`、多后端工具 ID `toolu_vrtx_*`/`toolu_bdrk_*`/`call_*`/`chatcmpl-tool-*`/裸 UUID) | live records |

### 目录结构

```
~/.qoder/projects/                                   # ROOT
└── <ENCODED_CWD>/                                   # one dir per workspace cwd
    ├── <SESSION_UUID>.jsonl                          # MAIN transcript (append-only)
    ├── <SESSION_UUID>/                               # sibling state dir (same UUID, no ext)
    │   ├── state.json                                # session item/revision state (rewritten)
    │   ├── compression-v2/
    │   │   └── state.json                            # context-compaction cache (rewritten)
    │   └── subagents/                                # dispatched sub-agent artifacts
    │       ├── agent-<AGENT_ID>.jsonl                # subagent transcript (append-only)
    │       ├── agent-<AGENT_ID>.meta.json            # subagent display metadata (write-once)
    │       └── task-<AGENT_ID>.json                  # subagent task record (rewritten)
    └── subagents/                                    # ALT location — see note below
```

### 命名文法

| 元素 | 文法 | 真实(已脱敏)示例 |
|---|---|---|
| `<ENCODED_CWD>` | 绝对 cwd,每个 `/` → `-`(原有的 `-` 保留,**不折叠**) | cwd `/Users/bing/-Code-/engram` → 目录 `-Users-bing--Code--engram`;cwd `/Users/bing/-Tools-` → `-Users-bing--Tools-` |
| `<SESSION_UUID>` | RFC-4122 v4 UUID | `4789761a-0873-4183-835c-1ff089b7dad2` |
| `<AGENT_ID>` | `<a><AgentType>-<16hex>` 风格的 id;`<AgentType>` ∈ {`general-purpose`(实时数据中最常见)、`Explore`、`Plan`、…} | `ageneral-purpose-646b2bc0030e4762`、`aExplore-604c32607f3e8031` |
| Subagent 转录 | `agent-<AGENT_ID>.jsonl` | `agent-aExplore-604c32607f3e8031.jsonl` |
| Subagent meta | `agent-<AGENT_ID>.meta.json` | `agent-aExplore-604c32607f3e8031.meta.json` |
| Subagent task | `task-<AGENT_ID>.json` | `task-aExplore-604c32607f3e8031.json` |

> ⚠️ 反编码 `-`→`/` 是**有损的** —— 它无法区分路径中原本的 `-`
> 和路径分隔符。Engram 从不反编码目录名;它转而
> 从每条记录内部读取 `cwd`(`QoderAdapter.swift:67-69`)。

> 底部的 `subagents/`(直接位于项目目录下,而不在某个
> `<uuid>/` 下)是两个适配器都会扫描的**备用放置位置**
>(`QoderAdapter.swift:34`、`qoder.ts:50`)。本机仅实时观察到
> `<uuid>/subagents/` 形式;项目目录层级的扫描路径
> 尚未对真实数据确认。

> ⚠️ **官方文档布局不同:多了一层 `transcript/` 子目录。** 上面的 Engram
> 布局(主转录直接位于项目目录下,无中间子目录)与本机的实时存储一致。
> 但官方
> [Qoder Hooks 文档](https://docs.qoder.com/extensions/hooks) 给出的
> `transcript_path` 示例为
> `~/.qoder/projects/<project>/transcript/<session-id>.jsonl` —— 即多了一层
> `transcript/` 子目录。这很可能是文档简化,或是 CLI/版本差异(实时文件
> 看起来是 qoder-cli 会话)。对 Engram 解析的版本应以实时存储为准,但需
> 注意适配器基于路径的父级逻辑(§10)在官方文档的 `transcript/` 布局下
> 可能失效。

### 目录树示例(实时,engram 工作区 —— 已脱敏)

```
~/.qoder/projects/-Users-bing--Code--engram/
├── 4789761a-0873-4183-835c-1ff089b7dad2.jsonl        (52 lines, ~310 KB)
├── 4789761a-0873-4183-835c-1ff089b7dad2/
│   ├── state.json
│   ├── compression-v2/state.json
│   └── subagents/
│       ├── agent-aExplore-604c32607f3e8031.jsonl
│       ├── agent-aExplore-604c32607f3e8031.meta.json
│       ├── task-aExplore-604c32607f3e8031.json
│       ├── agent-aExplore-99f9d2df5bfceba4.jsonl
│       ├── ... (subagent transcripts; NOT 1:1 with task specs — see note)
├── 7e6d3cb3-6200-49f1-b4b7-0b5e8fa32032.jsonl        (5 lines, 2575 B — user-only)
└── 7e6d3cb3-6200-49f1-b4b7-0b5e8fa32032/
    └── state.json
```

> ⚠️ **旁车文件数量多于转录 —— 一份 task spec 不保证对应一个子
> 会话。** 实时存储:**51** 个 `task-*.json` + **51** 个 `*.meta.json`,但仅有
> **44** 个 `agent-*.jsonl` 转录。状态为
> `failed`(11)或 `cancelled`(4)的派发任务 —— 甚至并非所有 `completed`(36)—— 都可能留下
> 一个 `task-*.json` + `meta.json` 而**没有** `agent-*.jsonl`。于是有 7 个派发的
> subagent 有派发记录但无转录,而 Engram 只摄入
> 那 44 个确有转录的。§2 目录树中的"each + .meta.json +
> task-*.json"是常见情形,而非不变式。

---

## 3. 文件生命周期与生成

- **存储技术:** 纯粹的每会话一文件 JSONL。无数据库。Engram 通过
  流式读取文件来推导计数 / 起始 / 结束,而非查询 DB。
- **追加 vs 重写:** 两类**转录**(`<uuid>.jsonl`、
  `agent-<id>.jsonl`)是**仅追加** —— 每一轮添加一行;不会
  就地重写任何内容。而 **JSON 旁车**(`state.json`、
  `compression-v2/state.json`、`task-*.json`)是**整文件重写**
  (修订计数器 / 状态迁移)。`meta.json` 一次性写入。
- **恢复(Resume):** 向同一份 `<uuid>.jsonl` 追加即恢复会话;
  `last-prompt` 记录缓存恢复提示,且 `state.json.revision`
  递增。会话 id 是稳定的(即文件名 UUID),因此 Engram 重新读取
  已增长的文件并据最后一个 `timestamp` 重新计算 `endTime`。
- **滚动(Rollover):** 未观察到 —— 一个 UUID = 一个文件,贯穿会话整个生命周期;
  新对话获得新 UUID,而不是被滚动的文件。
- **归档:** 无 —— 旧会话原地保留。`file-history-snapshot`
  记录提供逐消息的文件编辑撤销状态,但 Qoder 不会
  移动/压缩旧的转录。
- **会话内 mtime 排序**(实时观察):
  `compression-v2/state.json` → `state.json` → 主 `<uuid>.jsonl`,即
  转录最后被刷写。
- **`~/.qoder` 之外的临时输出:** subagent `task-*.json.outputPath`
  和 `toolUseResult.outputPath` 指向 `/private/tmp/qoder-cli-<uid>/<encoded-cwd>/<uuid>/tasks/<id>.output`。
  该临时区域未被检查(超出范围);它可能持有 Engram 未捕获的
  额外临时输出。

---

## 4. 记录 / 行分类法(顶层 JSONL 对象)

记录由顶层 `type` 字段区分。**整个实时存储**(57 个文件,5021 条记录 —— 不是单个会话;
早期草稿仅剖析了会话 `4789761a`,它碰巧既不含 `token-stats` 也不含 `system`)中观察到
**七种**类型:

| `type` | 计数(整存储,57 文件) | 是否被 Engram 解析? | 含义 |
|---|---|---|---|
| `assistant` | 2923 | ✅(→ `assistant`) | 模型回合(text / thinking / tool_use 块) |
| `user` | 1714 | ✅(→ `user` 或 `tool` 角色) | 用户回合**或**一个 `tool_result` 反馈回合 |
| `token-stats` | 215 | ❌ 跳过 | 周期性的 prompt-token 计数检查点;EPOCH-MS 时间戳(下文 §2 样本);除 `message.usage` 外的第二个 token 计量面 |
| `system` | 103 | ❌ 跳过 | agent/task 生命周期 + 错误事件(`subtype`/`level`/`task_type` 信封;subagent 派发信号) |
| `last-prompt` | 37 | ❌ 跳过 | 最后一条用户提示文本的快照(恢复上下文) |
| `file-history-snapshot` | 21 | ❌ 跳过 | 与某条消息绑定的文件备份检查点(撤销/还原) |
| `ai-title` | 8 | ❌ 跳过 | AI 生成的会话标题旁车记录 |

作为对比,**单个**会话 `4789761a` = user 19 / assistant 30 /
ai-title 1 / last-prompt 1 / file-history-snapshot 1(52 行,无
token-stats/system)—— 这正是单会话剖析会低估
分类法的原因。

> ⚠️ **这套七类型分类法是按本存储剖析的画像,并非 Qoder 完整的记录全集。**
> 官方
> [Qoder Hooks 文档](https://docs.qoder.com/extensions/hooks) 还记录了两种
> 本实时存储(以 qoder-cli 0.2.x–1.0.x 文件为主)中未出现的顶层记录类型:
> **`session_meta`**(含 `data.content.mode ∈ {agent, plan, ask, debug}` 与
> `data.content.session_type ∈ {assistant, inline_chat, …}`)和 **`progress`**。
> 较新 / 由 IDE 启动的会话可能产出 `session_meta` 与 `progress` 记录,因此
> 上面这七种类型对所观察的数据是准确的,但对整个 Qoder 并不穷尽。适配器的
> `type ∈ {user, assistant}` 过滤器同样会跳过这些类型。

适配器**仅**解析 `type ∈ {user, assistant}`(`QoderAdapter.swift:57-59,154-156`;
`qoder.ts:76,142`);其余**五种**旁车记录类型被完全忽略。一致性
fixtures 仅含 `user`/`assistant` 记录,因此那五种旁车
类型**仅出现在实时数据中**。

> ⚠️ **适配器盲点:** `ai-title` 携带一份经过整理、可读性强的标题,
> 而 `last-prompt` 携带恢复上下文,但两个适配器都不读取它们。该
> 循环对任何非 `user`/`assistant` 的 `type` 都 `continue`,因此 Engram
> 退回到取首条用户消息切片作为摘要,**忽略了 Qoder 自己的
> AI 生成标题**。开放问题:是有意为之,还是一处缺口?

> ⚠️ **`systemMessageCount` 并不统计 `type:system` 记录。**
> `systemMessageCount` 是一个**用户文本启发式**(§14),以
> `# AGENTS.md instructions for ` / `<INSTRUCTIONS>` 为键;在真实存储上它
> 命中了 **0 次**,而**103 条真正的 `type:system` 记录**则被
> `type ∈ {user, assistant}` 过滤器丢弃、不计入。读者切不可假定
> system 类型记录会喂给 `systemMessageCount` —— 它们不会;对真实 Qoder
> 数据而言 `systemMessageCount` 实际上恒为 0(§5、§14、§15)。

---

## 5. 共享信封 / 元数据字段

`user` / `assistant` 记录上的字段。

| 字段 | 类型 | 含义 | 可选 | 是否消费 | 示例 |
|---|---|---|---|---|---|
| `type` | string | 记录鉴别符(`"user"`/`"assistant"`) | no | ✅ filter | `"assistant"` |
| `uuid` | string | 本记录的唯一 id(或合成的 `user:<sid>########N`) | no | ❌ | `"5d3726e1-9e40-4bd8-a96d-3d9507a8ce01"` |
| `parentUuid` | string \| null | DAG 中的前一条记录;首条为 `null`;assistant 可能使用合成的 `user:<sid>########<n>` | no(根为 null) | ❌ | `"a8d327a1-e562-4509-b8d5-701179a51be5"` |
| `timestamp` | string(ISO-8601 UTC `…Z`) | 记录时间 → start(首条)/ end(末条) | no | ✅ | `"2026-05-25T05:28:12.644Z"` |
| `sessionId` | string(UUID) | 会话 id(与文件名匹配;即便在 subagent 文件内仍是**父级**的 UUID) | no | ✅ | `"4789761a-0873-4183-835c-1ff089b7dad2"` |
| `cwd` | string(绝对路径) | 工作目录 | no | ✅ | `/Users/bing/-Code-/engram` |
| `version` | string | Qoder 客户端/模式版本(并非模型 id) | no | ❌ | `1.0.13`, `1.0.10`, `1.0.4`, `0.2.13`, `0.2.7` |
| `userType` | string | 账户类型;实时数据:恒为 `"external"` | no | ❌ | `"external"` |
| `entrypoint` | string | 启动入口;实时数据:恒为 `"cli"` | no | ❌ | `"cli"` |
| `isSidechain` | bool | subagent 记录上为 `true`;主记录上为 `false` | no | ❌(Engram 用路径,不用此标志) | `false` |
| `isMeta` | bool \| null/缺省 | 标记一个被注入/meta 的用户回合(例如首条记录) | yes(仅 user) | ❌ | `true` |
| `promptId` | string(UUID) | 将属于同一用户提示/回合的记录分组 | yes | ❌ | `"9339cc26-4a75-4ee9-90ca-ebd752e56a98"` |
| `permissionMode` | string | 本回合的权限策略 | yes(仅 user) | ❌ | `default`, `auto`, `acceptEdits`, `bypassPermissions` |
| `sourceToolAssistantUUID` | string | 在 `tool_result` user 记录上:发起 `tool_use` 的那条 assistant 的 `uuid`(信封级 call↔result 链接) | yes(工具回合) | ❌ | `"a8d327a1-e562-4509-b8d5-701179a51be5"` |
| `toolUseResult` | object | 工具特定的结构化结果载荷(见 §7) | yes(工具回合) | ❌ | — |
| `message` | object | 内容信封(见 §6) | no | ✅ | — |

**仅 subagent 特有的额外信封键**(出现在 `agent-*.jsonl` 中,顶层文件中无):

| 字段 | 类型 | 含义 | 是否消费 | 示例 |
|---|---|---|---|---|
| `agentId` | string | subagent 自身的 id → **subagent 的 Engram id** | ✅(当路径含 `/subagents/` 时) | `"aExplore-604c32607f3e8031"` |
| `parent_tool_use_id` | string | 将该 subagent 回合链接到派发它的 `tool_use`(任意后端前缀:`toolu_vrtx_*`/`toolu_bdrk_*`/`call_*`/…) | ❌ | `"toolu_vrtx_01PW3LBksPmMHrjTtH9qL4Fh"` |
| `session_id` | string | `sessionId` 的 **snake_case 重复版**(父级 UUID),在 assistant subagent 记录上与驼峰式 `sessionId` 并存 | ❌ | `"4789761a-0873-4183-835c-1ff089b7dad2"` |

> 在 subagent 记录上 `isSidechain` 为 `true`,且 `sessionId`/`session_id` 都
> 持有**父级** UUID —— subagent 自身的 id 仅存于 `agentId`。

---

## 6. 消息与内容模式

`message` 字段是一个 Anthropic 风格的消息对象,其形态随
角色而变。

### 6a. user `message`

| 字段 | 类型 | 含义 | 示例 |
|---|---|---|---|
| `role` | string | 恒为 `"user"` | `"user"` |
| `content` | string \| array | 纯提示(字符串)**或** `tool_result` 块的数组 | `"<prompt text>"` / `[{tool_result…}]` |

当且仅当 `content` 是包含
`tool_result` 块的数组时,Engram 将一条 `user` 记录归类为 **`tool` 角色**,否则归为 **`user`**
(`QoderAdapter.swift:159,173-178`;`qoder.ts:150-155,197-202`)。它还会
将以 `"# AGENTS.md instructions for "` 开头或
含有 `"<INSTRUCTIONS>"` 的用户提示重新归类为**系统注入**,并从
`userMessageCount` 中排除(`QoderAdapter.swift:169-171`;`qoder.ts:190-194`)。

### 6b. assistant `message`(Anthropic 消息对象)

| 字段 | 类型 | 含义 | 可选 | 示例 |
|---|---|---|---|---|
| `id` | string | 提供方消息 id | no | `"ae6e4cd3-3e73-4757-acd7-7b43e670d196"` |
| `type` | string | 恒为 `"message"` | no | `"message"` |
| `role` | string | 恒为 `"assistant"` | no | `"assistant"` |
| `model` | string | Qoder 模型**别名**,而非真实模型 id | no | `ultimate`, `efficient`, `auto`, `<synthetic>`, `""` |
| `stop_reason` | string \| null | `"tool_use"`、`"end_turn"` 或 null(流式/中间态) | no | `"tool_use"` |
| `stop_sequence` | string \| null | 匹配到的停止序列 | no | `null` |
| `content` | array | 内容块(见 §6c) | no | — |
| `usage` | object | token 计量;仅出现在**少数** assistant 记录上(回合的最后片段 —— 采样会话中 30 条里有 9 条) | yes | — |

### 6c. 内容块(位于 `message.content[]` 内)

| 块 `type` | 字段 | 含义 | 适配器处理 |
|---|---|---|---|
| `text` | `type`、`text`(string)、`citations`(所有样本中为 null) | assistant 散文 | 追加到内容 |
| `thinking` | `type`、`thinking`(string)、`signature`(string) | 扩展推理 | **仅作回退** —— 当且仅当该块没有 `text`/`tool_use`/`tool_result` 部分时才作为内容输出(`QoderAdapter.swift:191-193`、`205`) |
| `redacted_thinking` | `type`、`data`(不透明加密 blob) | 服务端涂抹的推理 | **忽略**(extractContent 只处理 text/thinking/tool_use/tool_result) |
| `tool_use` | `type`、`id`(带后端标签:`toolu_vrtx_*` 占多数 / `toolu_bdrk_*` / `call_*` / `chatcmpl-tool-*` / 裸 UUID)、`name`、`input`(object) | 工具调用 | 在文本中渲染为 `` `name` ``;输出为 `NormalizedToolCall{name, input}`(`:194,208-221`) |
| `tool_result` | `type`、`tool_use_id`、`content`(string \| array)、`is_error`(bool) | 回灌的工具输出(位于 **user** 记录上) | 提取内容;存在即 → `tool` 角色 |

横跨全部 57 个文件的实时内容块分布:`tool_use` 1586、
`tool_result` 1586、`thinking` 524、`text` 463、`redacted_thinking` 358。

**`tool_use.id` 带后端标签且多后端**(对全部 57 文件中
所有 assistant `tool_use` 块 id 的前缀普查):`toolu_vrtx_*` **748**(多数,
Vertex/Google)、`call_*` **492**(OpenAI 兼容)、`toolu_bdrk_*` **237**
(Bedrock)、裸 UUID **48**、`chatcmpl-tool-*` 约 **60**(OpenAI 兼容)。因此
Qoder 将回合路由到**多个后端**(Vertex / Bedrock /
OpenAI 兼容),而非仅 Bedrock;该前缀是唯一的后端信号 ——
`model` 别名隐藏了它(§15)。

观察到的 `tool_use.input` 键形态(tool → input 键,实时):
`Bash:[command,description(,timeout)]`、`Read:[file_path]`、
`Write:[content,file_path]`、`Edit:[file_path,instruction,new_string,old_string]`、
`Glob:[pattern]` / `[path,pattern]`、`Grep:[pattern,output_mode,…flags]`、
`TodoWrite:[todos]`、`Agent:[description,prompt,subagent_type(,isolation)]`、
`AskUserQuestion:[questions]`、`CreateGoal:[objective]`、`GetGoal:[]`、
`EnterPlanMode:[reason]`。

#### 示例(已脱敏 —— 键逐字保留,值已清洗)

```jsonc
// type=user, tool_result turn — envelope + nested tool_result block
{
  "type": "user",
  "uuid": "1b20e8de-e656-4966-9e02-8055d6fc497a",
  "timestamp": "2026-05-25T05:28:13.601Z",
  "message": {
    "role": "user",
    "content": [
      { "type": "tool_result",
        "tool_use_id": "toolu_vrtx_013V8oMB2WQkkJnJ8jqvh2Wo",
        "content": "REDACTED",
        "is_error": false }
    ]
  },
  "sourceToolAssistantUUID": "a8d327a1-e562-4509-b8d5-701179a51be5",
  "promptId": "9339cc26-4a75-4ee9-90ca-ebd752e56a98",
  "toolUseResult": "REDACTED_OBJ",
  "parentUuid": "a8d327a1-e562-4509-b8d5-701179a51be5",
  "isSidechain": false,
  "cwd": "/Users/bing/-Code-/engram",
  "sessionId": "4789761a-0873-4183-835c-1ff089b7dad2",
  "userType": "external",
  "entrypoint": "cli",
  "version": "1.0.4"
}
```

```jsonc
// content-block variants — one of each (anonymized)
{ "type": "text", "text": "REDACTED", "citations": null }
{ "type": "thinking", "thinking": "REDACTED", "signature": "REDACTED_SIG" }
{ "type": "redacted_thinking", "data": "REDACTED_DATA" }
{ "type": "tool_use", "id": "toolu_vrtx_01H3k5cF1KYMiTKqJM3fvZaV", "name": "Glob", "input": {"pattern":"REDACTED"} }   // Vertex (majority)
{ "type": "tool_use", "id": "call_6d5190e9b79e4996801d6c", "name": "Read", "input": {"file_path":"REDACTED"} }       // OpenAI-compatible
{ "type": "tool_result", "tool_use_id": "toolu_bdrk_013V8oMB2WQkkJnJ8jqvh2Wo", "content": "REDACTED", "is_error": false }  // Bedrock
```

---

## 7. 工具调用与结果

两套并行的 call↔result 链接机制 —— 均已核实,ID 一一对应:

1. **内容块层级(规范):** assistant `tool_use.id`(任意后端
   前缀 —— `toolu_vrtx_…`/`toolu_bdrk_…`/`call_…`/`chatcmpl-tool-…`/裸 UUID)
   == 紧随其后的 user `tool_result.tool_use_id`。
2. **信封层级:** `tool_result` user 记录的 `parentUuid` 和
   `sourceToolAssistantUUID` 都等于发起方**assistant 记录的
   `uuid`**(所有样本中 `parentUuid == sourceToolAssistantUUID`)。

**Engram 只暴露 call 一侧。** `NormalizedToolCall{name, input}` 以
`output: nil` 输出(`QoderAdapter.swift:215-219`;`qoder.ts:242-248`);
适配器**不**将结果缝合回 call 对象 —— 结果以独立的
`tool` 角色消息出现。`input` 经 JSON 编码并截断
(Swift 500 字符,TS 500 字符)。错误由
`tool_result.is_error`(bool)承载,而 Engram 不读取它。

### `toolUseResult`(多态结构化结果,信封级 —— 未解析)

出现在 `tool_result` user 记录上;形态随工具而变。实时观察到的
变体(横跨全部 57 文件的计数):

| 变体 | 鉴别键 | 计数 | 备注 |
|---|---|---|---|
| **Agent/Task** | `kind:"agent-result"`、`agentId`、`agentType`、`content`、`state`、`terminateReason`、`outputPath`、`transcriptPath` | 47 | 经 `transcriptPath` 链接到 subagent JSONL |
| **Glob/Grep-like** | `durationMs`、`filenames[]`、`numFiles`、`truncated` | 172 | |
| **Read** | `content`、`filenames`、`mode`、`numFiles`、`numLines`(旧形态中为 `type:"text"`、`file:{…}`) | 114 | |
| **Edit/Write** | `type`(`create`/`update`)、`content`、`filePath`、`originalFile`、`structuredPatch[]` | 32 | patch 元素 `{oldStart,oldLines,newStart,newLines,lines[]}` |
| **with limits** | `appliedLimit`、`content`、`filenames`、`mode`、`numFiles`、`numLines` | 8 | |
| **AskUserQuestion** | `answers`、`questions` | 2 | |
| **Bash (bg)** | `backgroundReason`、`command`、`initialOutput`、`pid`、`totalBytes`、`totalLines` | 1 | |
| **WebFetch** | `bytes`、`code`、`codeText`、`durationMs`、`result`、`url` | 1 | |
| **error** | `errorType` | 9 | |
| **Bash (fg)** | `stdout`、`stderr`、`interrupted`、`isImage`、`noOutputExpected` | — | (按维度报告) |
| **TodoWrite** | `oldTodos[]`、`newTodos[]`(各为 `{description,status}`) | — | (按维度报告) |

```jsonc
// toolUseResult — Agent/Task variant (anonymized)
{ "kind": "agent-result", "agentId": "aExplore-c6740a171e935c6d", "agentType": "Explore",
  "content": "REDACTED", "state": "completed", "terminateReason": "GOAL",
  "outputPath": "/private/tmp/qoder-cli-501/-Users-bing--Code--engram/4789761a-…/tasks/aExplore-c6740a171e935c6d.output",
  "transcriptPath": "/Users/bing/.qoder/projects/-Users-bing--Code--engram/4789761a-…/subagents/agent-aExplore-c6740a171e935c6d.jsonl" }
```

适配器在内容方面完全忽略 `toolUseResult` —— 它从**内容块**读取
`tool_result.content` / `.output`,而非这个
信封字段。

---

## 8. 推理 / 思考

存储为内容块(§6c):

- **`thinking`** = `{type, thinking, signature}` —— 扩展推理。Engram
  仅将其用作**回退**:当且仅当
  块数组没有产出任何 `text`/`tool_use`/`tool_result` 部分时,`extractContent` 才输出该思考文本
  (`QoderAdapter.swift:184,191-193,205`;`qoder.ts:208,213-218,231`)。因此在
  多数回合中推理**不会**被索引。
- **`redacted_thinking`** = `{type, data}` —— 服务端涂抹的推理
  (不透明 blob)。两个适配器都**从不提取**。实时存储中存在 358 个
  这样的块 —— 对 Engram 不可见。

---

## 9. Token 用量与成本

assistant `message` 上的 Anthropic 形态 `usage` 对象。仅出现在少数
assistant 记录上(流式回合的最后片段 —— 采样会话中 30 条里有 9 条;
**全存储 2923 条 assistant 记录中有 256 条,约 9%**)。

| 原始字段 | 类型 | 含义 | Engram 映射 |
|---|---|---|---|
| `input_tokens` | int | 提示 token | → `inputTokens` |
| `output_tokens` | int | 补全 token | → `outputTokens` |
| `cache_read_input_tokens` | int | 从提示缓存命中的 token | → `cacheReadTokens` |
| `cache_creation_input_tokens` | int | 写入缓存的 token | → `cacheCreationTokens` |
| `cache_creation` | object | `{ephemeral_1h_input_tokens, ephemeral_5m_input_tokens}` | **丢弃** |
| `server_tool_use` | object | `{web_search_requests, web_fetch_requests}` | **丢弃** |
| `service_tier` | string | `"standard"`(仅见此值) | **丢弃** |
| `speed` | string | `"standard"`(仅见此值) | **丢弃** |
| `inference_geo` | string | 推理区域(所有样本中为空) | **丢弃** |
| `iterations` | array | 逐迭代细分(所有样本中为空) | **丢弃** |
| `request_id` | string | 提供方请求 id(此处 == `message.id`) | **丢弃** |

映射:`qoder.ts:252-263`;Swift 经共享的 `JSONLAdapterSupport.usage(from:)`
(`QoderAdapter.swift:165` → 定义于 `CodexAdapter.swift:220`,即共享的
`JSONLAdapterSupport` 枚举)。一致性 fixture 确认了精确的 4 字段
映射(`usageTotals: {inputTokens:12, outputTokens:8, cacheReadTokens:3,
cacheCreationTokens:2}`)。

> **不存储逐回合美元成本** —— 仅有 token 计数。另见 §15 陷阱:
> `model` 是 Qoder 的营销别名,而非真实提供方模型 id,因此按模型做
> 成本归因不可靠。

```json
{"input_tokens":18867,"cache_creation_input_tokens":0,"cache_read_input_tokens":13628,
 "output_tokens":469,"server_tool_use":{"web_search_requests":0,"web_fetch_requests":0},
 "service_tier":"standard","cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":0},
 "inference_geo":"","iterations":[],"speed":"standard","request_id":"..."}
```

---

## 10. Subagent / 父子关系 / 派发

Qoder 派发的子 agent,其转录位于
`<uuid>/subagents/agent-<id>.jsonl`。Engram 将它们摄入为**子会话**。
`agentType` 是 **{`general-purpose`(最常见 —— 51 个 task spec 中有 35 个)、
`Explore`(14)、`Plan`(2)}**,而不止 `Explore`;agent 文件前缀为
`ageneral-purpose`(29)、`aExplore`(14)、`aPlan`(1)。

> ⚠️ **一个备用的、基于字段的派发信号存在于主转录中,
> 而 Engram 忽略它。** 带有
> `subtype ∈ {task_started, task_progress}` 的 `type:system` 记录(8 + 72 次)携带
> `task_id` / `tool_use_id` / `task_type:"local_agent"` / `description` /
> `prompt` —— 这是父会话自身 JSONL 中显式的 subagent 派发记录
>(`task-*.json` 旁车在转录内的对应物)。Engram 转而
> 从**目录路径**推导父级链接,并将这些 `system`
> 记录完全丢弃(§3、§14)。

**发现**(`listSessionLocators()` Swift `QoderAdapter.swift:22-37` /
`listSessionFiles()` TS `qoder.ts:34-55`):

1. 遍历 `~/.qoder/projects/` 中是目录的直接子项(每个 = 一个
   项目)。
2. 在每个项目目录内:`*.jsonl` → 作为**顶层会话定位符**输出;
   子目录 → 递归进入其 `subagents/` 并输出每个
   `agent-*.jsonl`。
3. 还扫描项目目录自身的 `subagents/` 文件夹(备用放置位置,
   §2)。Swift 对最终列表排序;TS 惰性产出。

**Subagent 身份与链接:**

| 方面 | 方式 | file:line |
|---|---|---|
| `id`(subagent) | 若定位符含 `/subagents/` 且 `agentId` 存在 → 用 `agentId`,否则 `sessionId` | `QoderAdapter.swift:98-99`;`qoder.ts:102-103` |
| `agentRole` | 若路径含 `/subagents/` 则 `"subagent"`,否则 `nil` | `QoderAdapter.swift:98,119`;`qoder.ts:102,119` |
| `parentSessionId` | **从路径推导** —— 取定位符相对根目录路径中、紧位于 `subagents` **之前**的那个组件(深度 ≥ 2):`…/<uuid>/subagents/agent-<id>.jsonl` → 父级 `<uuid>` | `QoderAdapter.swift:125,228-237`;`qoder.ts:120-122,265-270` |

> 父级链接是**从路径推导,而非从字段推导**。权威的
> `task-*.json` 携带显式的 `parentToolUseId`/`sessionId`,但 Engram
> 忽略它,改从目录名重新推导父级。两者在
> 实时数据中一致;但被重命名的父目录会悄然产生错误/悬空的
> 父级 id。

> **并非 Gemini 的 `.engram.json` 旁车机制。** Qoder 的父子
> 链接是基于路径的(目录布局),不像 Gemini CLI 那样写入一个
> `{sessionId}.engram.json` 旁车。

---

## 11. 摘要 / 压缩(Compaction)

- **Engram 侧摘要:** 不作为存储字段存在 —— Engram 从
  首条非系统用户消息文本推导 `summary`(`prefix(200)`),**而非**取自 Qoder
  自己的 `ai-title` 记录(§4、§15)。
- **Qoder 侧压缩(未解析):** `<uuid>/compression-v2/state.json`
  存放上下文窗口压缩簿记:
  `{version:int, state:{replacementDecisions, seenFunctionResponseIds,
  sessionMemoryState, autoCompactTracking, snippedMessageIds}}`。Engram 忽略
  它。不存在某些工具会输出的那种转录内"compact summary"记录;
  压缩是在这个旁车中带外(out-of-band)追踪的。
  **注意 v2 目录 / v1 字段的不一致:** 目录名为
  `compression-v2`,但文件内部的 `version` 字段在全部 7 个
  实时文件中都是 **`1`** —— 此处 `version` 是状态模式的版本,而非目录版本。

---

## 12. SQLite / DB 内部

**Qoder 不适用。** Qoder 不使用任何数据库 —— 它是纯粹的每会话一文件 JSONL
加 JSON 旁车。没有任何 `.vscdb`、leveldb 或 SQLite。

---

## 13. 辅助文件

下列所有 JSON 旁车都**被 Engram 忽略**(它只读取 `.jsonl`,
`QoderAdapter.swift:28`、`qoder.ts:44`)。

| 文件 | 键 | 写入模型 | 用途 |
|---|---|---|---|
| `<uuid>/state.json` | `sessionId, revision(int), createdAt, updatedAt, workspaceDirectories[], data{}, items{}` | 重写(revision 递增) | 会话元数据 + **加密**的 item 存储 |
| `<uuid>/compression-v2/state.json` | `version(int —— 尽管目录名为 `v2`,在全部 7 个实时文件中 **=1**)、state{replacementDecisions, seenFunctionResponseIds, sessionMemoryState, autoCompactTracking, snippedMessageIds}` | 重写 | 上下文窗口压缩缓存 |
| `subagents/agent-<id>.meta.json` | `agentType, displayName, description, color` | 一次性写入 | subagent 显示元数据 |
| `subagents/task-<id>.json` | `taskId, sessionId, executionId(num), agentId, agentType, description, parentToolUseId, outputPath, transcriptPath, completionBehavior, status(实时 ∈ {completed:36, failed:11, cancelled:4})、summary, createdAt(epoch-ms), updatedAt(epoch-ms), result, completedAt(epoch-ms)` | 重写(状态迁移) | subagent 派发 + 结果记录 |

**`state.json.items{}`** 是一个加密的键值存储:每个 item 携带
五个键 `{c, n, p, t, u}` = created/nonce/payload/tag/updated(AES 风格;
`n`=nonce,`p`=payload,`t`=tag,皆 base64)。**不可读;没有 Qoder 密钥
便无法恢复。** `state.json.revision` 是单调
递增的 int(实时观察到高达 **83**)—— §16 的 `revision:42` 是
示意值,而非固定值。

**`task-*.json` 的时间戳是 epoch-ms 整数**(例如 `createdAt:1779686940809`),
不同于 JSONL 转录中的 ISO-8601 字符串。`task.transcriptPath`
指回 Engram 解析的 `agent-*.jsonl`;`task.outputPath` 引用
`/private/tmp/qoder-cli-<uid>/…` 下的一个独立临时区域。

---

## 14. Engram 映射

Engram 只读取顶层 `type ∈ {user, assistant}` 的记录;其余所有
记录被跳过(`QoderAdapter.swift:57-59`;`qoder.ts:76`)。

### 会话信息映射

| Engram Session 字段 | 来源(Qoder JSONL) | 如何推导 | file:line(Swift / TS) |
|---|---|---|---|
| `id`(顶层会话) | 记录 `.sessionId`(首个非空) | 首条 user/assistant 记录 | `QoderAdapter.swift:61-63,99` / `qoder.ts:78,103` |
| `id`(subagent) | 记录 `.agentId` | 若路径含 `/subagents/` 且 `agentId` 存在 → `agentId`,否则 `sessionId` | `QoderAdapter.swift:98-99` / `qoder.ts:102-103` |
| `source` | 常量 | `.qoder` | `QoderAdapter.swift:4,104` / `qoder.ts:18,106` |
| `summary` | 首条 user `message.content` 文本 | 对首条非系统用户消息做 `extractContent()`,`prefix(200)` | `QoderAdapter.swift:92,115` / `qoder.ts:96,116` |
| `cwd` | 记录 `.cwd`(首个非空) | 首条 user/assistant 记录 | `QoderAdapter.swift:67-69,108` / `qoder.ts:80,109` |
| `project` | — | **恒为 `nil`**(下游据 cwd 推导) | `QoderAdapter.swift:108` / `qoder.ts`(省略) |
| `startTime` | 记录 `.timestamp`(首条) | 首条 user/assistant 记录 | `QoderAdapter.swift:70-72,105` / `qoder.ts:81,107` |
| `endTime` | 记录 `.timestamp`(末条) | 末条 user/assistant 记录;**若等于 startTime 则为 `nil`** | `QoderAdapter.swift:73-75,106` / `qoder.ts:82,108` |
| `model` | `message.model`(首个非 null) | 首条携带 `model` 的 assistant 消息 | `QoderAdapter.swift:78-80,109` / `qoder.ts:85,110` |
| `messageCount` | 推导 | `userCount + assistantCount + toolCount` | `QoderAdapter.swift:110` / `qoder.ts:111` |
| `userMessageCount` | type=`user`、content 非 tool_result、非 system-injection | 计数器 | `QoderAdapter.swift:90-92,111` / `qoder.ts:94-96,113` |
| `assistantMessageCount` | type=`assistant` | 计数器 | `QoderAdapter.swift:82-83,112` / `qoder.ts:87-88,114` |
| `toolMessageCount` | type=`user` 且其 `content[]` 含 `tool_result` 块 | 计数器 | `QoderAdapter.swift:84-85,113` / `qoder.ts:89,115` |
| `systemMessageCount` | type=`user` 且文本以 `# AGENTS.md instructions for ` 开头 或含 `<INSTRUCTIONS>` | 计数器 | `QoderAdapter.swift:88-89,114` / `qoder.ts:93,116` |
| `filePath` | 定位符(绝对路径) | 透传 | `QoderAdapter.swift:116` / `qoder.ts:117` |
| `sizeBytes` | 文件 `st_size` | stat | `QoderAdapter.swift:117` / `qoder.ts:118` |
| `agentRole` | 路径测试 | 若路径含 `/subagents/` 则 `"subagent"`,否则 `nil` | `QoderAdapter.swift:98,119` / `qoder.ts:102,119` |
| `parentSessionId` | **从路径推导**(非字段) | `parts[subagentsIndex-1]`(父会话目录名) | `QoderAdapter.swift:125,228-237` / `qoder.ts:120-122,265-270` |
| `suggestedParentId` | — | 恒为 `nil`(Layer-2 启发式稍后运行) | `QoderAdapter.swift:126` |

### 逐消息流映射(`streamMessages`)

| Engram 消息字段 | 来源 | 如何 | file:line(Swift / TS) |
|---|---|---|---|
| `role` | `type` + content 形态 | `assistant`→assistant;`user`+tool_result→`tool`;否则 `user` | `QoderAdapter.swift:159` / `qoder.ts:150-155` |
| `content` | `message.content` | `extractContent()`:字符串透传;数组 → 连接 `text` 块、tool_use 渲染为 `` `toolName` ``、tool_result content/output、`thinking` 作回退 | `QoderAdapter.swift:180-206` / `qoder.ts:204-232` |
| `timestamp` | 记录 `.timestamp` | 透传 | `QoderAdapter.swift:163` / `qoder.ts:159` |
| `toolCalls[]` | `message.content[]` type=`tool_use` | `{name, input}`(input JSON ≤500 字符)、`output:nil` | `QoderAdapter.swift:208-226` / `qoder.ts:234-250` |
| `usage` | `message.usage` | 共享 `JSONLAdapterSupport.usage(from:)` —— 4 个 token 字段 | `QoderAdapter.swift:165`(→ `CodexAdapter.swift:220`)/ `qoder.ts:161,252-263` |

### Engram 不消费的内容

1. **5 个完整的记录类型**(`type ∈ {user, assistant}` 过滤器全部丢弃):
   `ai-title`(8 —— 服务端生成的标题!)、`last-prompt`(37 —— 恢复提示)、
   `file-history-snapshot`(21 —— 文件编辑撤销状态)、`token-stats`(215 ——
   第二个 token 计量面,epoch-ms)、`system`(103 —— agent/task
   生命周期 + 错误;见第 11 项)。
2. **DAG 线程关系:** `parentUuid`、`promptId`、`sourceToolAssistantUUID` ——
   Engram 扁平化为线性列表,丢失了消息树。
3. **`toolUseResult`** 结构化元数据(时长、文件列表、
   stdout/stderr 分离、截断标志、`terminateReason`)。
4. **`tool_result` 上的 `is_error`** —— 错误状态丢失。
5. **`isSidechain`** 标志 —— subagent 纯靠路径检测;一个被
   移出 `subagents/` 的 subagent 文件,即便 `isSidechain:true` 也会被误分类。
6. **所有 subagent 旁车**(`*.meta.json`、`task-*.json`),包括
   权威的 `parentToolUseId`/`result`/`summary`/`status`。
7. **Usage 额外项:** `server_tool_use`、`service_tier`、`speed`、嵌套的
   `cache_creation`、`request_id`、`iterations`、`inference_geo`。
8. **来源字段:** `version`、`entrypoint`、`userType`、`permissionMode`。
9. **`redacted_thinking`** 内容块;`thinking` 仅作回退;
   `citations`。
10. **状态旁车:** `state.json`、`compression-v2/state.json`。
11. **那 103 条 `type:system` 记录**(agent/task 生命周期 + 错误)—— 被
    `type ∈ {user, assistant}` 过滤器丢弃,**且不**计入
    `systemMessageCount`。`systemMessageCount` 反而是一个用户文本启发式
    (下一段),在真实存储上命中了 **0** 条记录。
12. **`token-stats` 记录**(215)—— 第二个 token 计量面
    (`promptTokenCount`、epoch-ms `timestamp`),Engram 既不捕获也不
    将其与 `message.usage` 对账。

> ⚠️ **`systemMessageCount` 是用户文本启发式,而非 system 记录
> 计数器。** 它仅在 `user` 文本以
> `# AGENTS.md instructions for ` 开头或含 `<INSTRUCTIONS>` 时
>(`QoderAdapter.swift:88-89,169-171`)递增。在实时存储上该启发式命中了
> **0 次**,而 103 条真正的 `type:system` 记录被丢弃 —— 因此对
> 真实 Qoder 数据而言,即使存储中充斥着 system 事件,
> `systemMessageCount` 实际上仍**恒为 0**。

---

## 15. 谱系、陷阱、版本漂移与边缘情况

### 共享格式谱系

Qoder 是一个 **Claude-Code-JSONL-家族** 存储。其模式与
原生 Claude Code(`~/.claude/projects/<slug>/<sessionId>.jsonl`)几乎一致:相同的
`type`/`uuid`/`parentUuid`/`isSidechain`/`cwd`/`sessionId`/`userType`/`version`
信封,相同的 Anthropic `message.{role, content[], usage}` 载荷,相同的
`tool_use`/`tool_result`/`thinking` 内容块,相同的
`~/.<tool>/projects/<path-slug>/` 根目录约定,以及相同的、用于派发 agent 的 `subagents/`
子目录。这正是 `QoderAdapter` 在结构上是 Claude Code 适配器克隆的原因
(记录类型过滤、内容块提取、
基于路径的父级推导都是相同的模式)。

**共享 `JSONLAdapterSupport.usage(from:)` 的 Engram 同族群**
(`CodexAdapter.swift:220`)以及 Anthropic 风格的 usage 键
(`input_tokens`/`output_tokens`/`cache_read_input_tokens`/
`cache_creation_input_tokens`):**Codex、Cursor、Gemini CLI、Qwen、iFlow、Kimi、
OpenCode**。按已知谱系,**Gemini CLI ↔ Qwen ↔ iFlow** 是一个分叉家族,
**Cursor ↔ VS Code ↔ Copilot ↔ Cline** 是另一个;**Qoder 位于 Claude
Code JSONL 谱系中,与原生 Claude Code 并列。**

**Qoder 相对上游 Claude Code 的区别性偏差:**
(a) 兄弟 `<sessionId>/` 目录,内含 `state.json`、`compression-v2/`
以及 `task-*.json` task spec;(b) `ai-title`/`last-prompt`/`token-stats`/
`system` 服务端记录(5 种旁车记录类型 vs Claude Code 的集合);
(c) 不透明的模型**别名**(`ultimate`/`efficient`/`auto`/`<synthetic>`)
而非真实的 `claude-*` 模型 ID;(d) **不透明的各后端 tool-use ID
前缀** —— `toolu_vrtx_*`(Vertex,多数)、`toolu_bdrk_*`(Bedrock)、
`call_*`/`chatcmpl-tool-*`(OpenAI 兼容)、裸 UUID —— 即 Qoder 是
**多后端**的;前缀是唯一的后端信号,而 `model` 别名
隐藏了哪个后端服务了某一轮(切勿把 `bdrk` 读作"仅 Bedrock
路由");(e) `AGENTS.md`(而非 `CLAUDE.md`)系统注入。

### 陷阱、版本漂移、边缘情况

1. **model 是别名,而非真实 ID。** 横跨实时存储:`ultimate`
   (2026 条记录)、`efficient`(659)、`auto`(214)、`<synthetic>`(8)、
   空 `""`(16)。一致性 fixture 使用 `"qoder-agent"`。**对 Qoder 而言,
   按模型做 token 成本归因不可靠** —— 这些是营销层级,
   而非 `claude-3-5-sonnet` 等。
2. **严重的版本漂移**(计数截至 2026-06-21;会随新会话漂移)。
   磁盘上有五个并存的 `version` 字符串:`0.2.7`(304)、`0.2.13`(371)、
   `1.0.4`(540)、`1.0.10`(743)、`1.0.13`(2782);外加 **281 条完全没有
   `version` 字段的记录** —— 它们是那些旁车记录类型
   (`token-stats` 215、`last-prompt` 37、`file-history-snapshot` 21、`ai-title`
   8)。(`user`/`assistant`/`system` 记录都携带 `version`。)
   0.2.x → 1.0.x 的跨越跨越了一次重大重写;较旧文件可能缺少
   `promptId`/`permissionMode`/嵌套的 usage 字段。适配器具有
   韧性(忽略多余字段),但跨版本不能假定字段一定存在。
3. **存在仅 user 的会话。** 实时文件 `7e6d3cb3-….jsonl`(2575 B)有
   **5 条 `user` 记录、0 条 `assistant`** → `messageCount`=5、
   `assistantMessageCount`=0、`model`=nil。合法但非典型;任何断言
   model/assistant 一定存在的代码都会绊倒。
4. **endTime 等于 start 时被置空。** 单回合 / 单时间戳
   会话上报 `endTime:nil`(`startTime != endTime` 守卫),因此时长
   逻辑必须把 `nil` 当作"瞬时/未知"处理。
5. **subagent 的 `sessionId` ≠ 会话 id。** subagent 文件将 `sessionId` 设为
   父级 id;subagent 自身的 id 是 `agentId`。适配器**仅在
   路径含 `/subagents/` 时**才切换到 `agentId` —— 依赖路径,而非
   依赖字段。把 subagent 文件移出/复制出 `subagents/` 会
   (a) 把它重新键到 `sessionId`(父级 id → 冲突),以及 (b) 丢失
   `subagent` 角色和父级链接。
6. **父级链接由路径推导,忽略显式的 task spec。** Engram
   从父会话目录名推导 `parentSessionId`,而非取自
   `task-*.json` 的 `parentToolUseId`/`sessionId`。两者在实时数据中一致;
   被重命名的父目录会悄然产生错误/悬空的父级 id。
7. **system-injection 启发式既脆弱,在实时数据中又命中 0 次。**
   `systemMessageCount` 以字面前缀
   `"# AGENTS.md instructions for "` 或子串 `"<INSTRUCTIONS>"` 为键。Qoder 使用
   `AGENTS.md`(而非 `CLAUDE.md`);任何措辞变化都会把这些落入
   `userMessageCount` 并可能污染首条用户 `summary`。在真实
   存储上该启发式命中了 **0** 条记录,因此 `systemMessageCount` 对
   Qoder 实际上**恒为 0** —— 而且关键在于它**不**统计那
   103 条真正的 `type:system` 记录,后者被 `type ∈ {user, assistant}`
   过滤器完全丢弃(§4、§14)。
8. **`thinking` 仅作回退;`redacted_thinking` 不可见。**
   `extractContent` 仅在某块没有
   `text`/`tool_use`/`tool_result` 部分时才输出 `thinking`。那 358 个 `redacted_thinking` 块
   从不被提取 —— 推理内容在 Engram 索引中大体缺失。
9. **截断不对称,Swift vs TS(真实的一致性缺口)。** Swift 将
   tool_result `output` JSON 截断到 2000 字符,但对字符串 `content`
   **不截断透传**(`QoderAdapter.swift:197-201`);TS 将字符串
   和 JSON 两条路径**都**截断到 2000(`qoder.ts:222-228`)。被索引的
   工具输出长度在产品与参考之间可能不同(针对长字符串结果)。
   (是否有一致性测试当前覆盖了 >2000 字符的字符串
   `tool_result` 尚未确认。)
10. **`tool_result.content` vs `.output`。** 实时数据使用字符串 `content`;
    适配器仅在 `content` 为空时才回退到 `output`。把载荷
    放在 `output` 的较旧版本记录依赖此回退。
11. **不保留 `parentUuid` 线程关系。** Engram 扁平化消息 DAG;
    分支/被编辑的对话树坍缩为文档顺序,丢失哪个
    assistant 回合回答了哪个 user 回合。
12. **`ai-title` 被丢弃。** Qoder 整理的 AI 标题(用于其自己的侧栏)是
    严格优于 Engram 所用首条用户文本切片的摘要 —— 但
    两个适配器都不读取它。

### 开放 / 未核实项

- `usage.iterations[]` 在所有实时样本中为空 —— 其元素模式
  未知(很可能是逐流式迭代的 token 增量)。(web-checked 2026-06-21:未找到
  权威来源 —— 没有任何官方 Qoder 来源记录 `message.usage`;
  [Hooks 文档](https://docs.qoder.com/extensions/hooks) 列出了转录字段但省略了
  `message.usage`,而 Anthropic 的公开 API 在 `usage` 上未定义 `iterations`
  字段,因此这是一个未被记录的 Qoder/后端扩展。)
- **Confirmed (official):** 模型别名(`ultimate`/`efficient`/`auto`)映射到未披露的
  真实提供方模型 —— 该别名刻意隐藏了哪个后端服务了某一轮。
  [Model Tier Selector 文档](https://docs.qoder.com/user-guide/chat/model-tier-selector)
  逐字声明:"The Model Tier Selector intelligently matches the most suitable
  model based on the selected tier—you don't need to know which specific model
  is being used.",并指出 Qoder 可能 "retire or replace older models"。其多后端
  特性也得到独立佐证(Qoder 在 Claude/GPT/Gemini 之间自动选择,并暴露
  Qwen/DeepSeek/GLM/Kimi),与磁盘上多前缀的 tool-use ID
  (`toolu_vrtx_*`/`toolu_bdrk_*`/`call_*`)一致。tool-use ID 前缀是唯一的后端
  信号,且显示**多个后端**(`toolu_vrtx_*` Vertex 多数、`toolu_bdrk_*` Bedrock、
  `call_*`/`chatcmpl-tool-*` OpenAI 兼容);每个别名逐回合解析到哪个具体模型
  不存储在转录中。
- `state.json.items{}` 载荷是 AES 风格加密的(`n`=nonce、`p`=payload、
  `t`=tag)—— 没有 Qoder 密钥便无法恢复其内容。(Engram 内部设计 —— 不可经
  web 核实:Qoder 为闭源,且无任何官方来源记录该 item 加密方案;`{c,n,p,t,u}`
  形态及 AES/AEAD 解读均为对实时存储的逆向工程,而该存储是唯一的证据基础。)
- **Confirmed (official):** 仅观察到 `entrypoint:cli` / `userType:external`;一个
  IDE-GUI 入口值(若有)未在此样本集中呈现。Qoder 提供多个启动面 ——
  Desktop IDE、JetBrains 插件和一个 CLI([Community Edition 博客](https://qoder.com/blog/qoder-community))——
  因此对于由 IDE 启动的会话,出现非 `cli` 的 `entrypoint` 值是合理的,但
  [Hooks 文档](https://docs.qoder.com/extensions/hooks) 根本未记录 `entrypoint`
  字段,所以 IDE-GUI 的字面值仍未被记录。这些具体文件看起来来自 Qoder CLI,
  而非 IDE GUI。
- 项目目录层级的 `subagents/` 扫描路径(备用放置位置)
  尚未对真实数据确认(实时仅观察到 `<uuid>/subagents/`)。(Engram 内部设计 ——
  不可经 web 核实:这是 QoderAdapter 的扫描路径问题,而非有文档记录的 Qoder
  格式事实;没有任何官方来源记录磁盘上的 subagents 目录布局。)
- `task-*.json.outputPath` → `/private/tmp/qoder-cli-<uid>/…` 未被检查
  (在 `~/.qoder` 之外);它可能持有 Engram 未捕获的额外临时输出。
  (Engram 内部设计 —— 不可经 web 核实:涉及 Qoder 的临时输出区域以及 Engram
  捕获了什么;没有任何官方来源记录此临时路径或其内容。)
- 较旧的 0.2.x 文件在结构上是否不同(缺少 usage/promptId)是
  从版本分布推断的,而非通过抽样某个具体 0.2.x 文件核实的。
  (web-checked 2026-06-21:未找到权威来源 —— 没有公开的 Qoder 更新日志或格式
  版本化文档描述逐版本的转录模式差异;[Hooks 文档](https://docs.qoder.com/extensions/hooks)
  只记录了当前模式。)

---

## 16. 附录:真实脱敏样本

每个记录/文件类型一个围栏块。键/类型/结构逐字保留;文本、
代码、密钥和个人路径已被清洗。

### `assistant` 记录(含 usage + thinking 块)

```json
{"type":"assistant","uuid":"5d3726e1-9e40-4bd8-a96d-3d9507a8ce01",
 "parentUuid":"user:4789761a-0873-4183-835c-1ff089b7dad2########2",
 "sessionId":"4789761a-0873-4183-835c-1ff089b7dad2","timestamp":"2026-05-25T05:28:12.644Z",
 "version":"1.0.4","cwd":"/Users/bing/-Code-/engram","userType":"external","entrypoint":"cli",
 "isSidechain":false,
 "message":{"role":"assistant","model":"ultimate","id":"ae6e4cd3-3e73-4757-acd7-7b43e670d196",
   "type":"message","stop_reason":null,"stop_sequence":null,
   "usage":{"input_tokens":18867,"cache_creation_input_tokens":0,"cache_read_input_tokens":13628,
     "output_tokens":469,"server_tool_use":{"web_search_requests":0,"web_fetch_requests":0},
     "service_tier":"standard","cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":0},
     "inference_geo":"","iterations":[],"speed":"standard","request_id":"REDACTED"},
   "content":[{"type":"thinking","thinking":"REDACTED","signature":"REDACTED"}]}}
```

### `user` 记录(纯提示)

```json
{"type":"user","uuid":"REDACTED-UUID","parentUuid":null,"isMeta":true,
 "sessionId":"4789761a-0873-4183-835c-1ff089b7dad2","timestamp":"2026-05-25T05:26:43.210Z",
 "cwd":"/Users/bing/-Code-/engram","version":"1.0.4","userType":"external","entrypoint":"cli",
 "isSidechain":false,"message":{"role":"user","content":"REDACTED"}}
```

### `user` 记录(tool_result 回合)

```json
{"type":"user","uuid":"1b20e8de-e656-4966-9e02-8055d6fc497a",
 "parentUuid":"a8d327a1-e562-4509-b8d5-701179a51be5",
 "sourceToolAssistantUUID":"a8d327a1-e562-4509-b8d5-701179a51be5",
 "promptId":"9339cc26-4a75-4ee9-90ca-ebd752e56a98","toolUseResult":"REDACTED_OBJ",
 "sessionId":"4789761a-0873-4183-835c-1ff089b7dad2","timestamp":"2026-05-25T05:28:13.601Z",
 "cwd":"/Users/bing/-Code-/engram","version":"1.0.4","userType":"external","entrypoint":"cli",
 "isSidechain":false,
 "message":{"role":"user","content":[
   {"type":"tool_result","tool_use_id":"toolu_vrtx_013V8oMB2WQkkJnJ8jqvh2Wo","content":"REDACTED","is_error":false}]}}
```

### Subagent `assistant` 记录(额外键:agentId、parent_tool_use_id、session_id)

```json
{"type":"assistant","uuid":"REDACTED-UUID","parentUuid":"REDACTED-UUID",
 "agentId":"ageneral-purpose-646b2bc0030e4762","parent_tool_use_id":"toolu_vrtx_01PW3LBksPmMHrjTtH9qL4Fh",
 "sessionId":"4789761a-0873-4183-835c-1ff089b7dad2","session_id":"4789761a-0873-4183-835c-1ff089b7dad2",
 "timestamp":"2026-05-25T…Z","cwd":"/Users/bing/-Code-/engram","version":"1.0.13",
 "userType":"external","entrypoint":"cli","isSidechain":true,
 "message":{"role":"assistant","model":"efficient","content":[{"type":"text","text":"REDACTED","citations":null}]}}
```

### `token-stats` 记录(未解析 —— EPOCH-MS 时间戳,4 个键)

```json
{"type":"token-stats","sessionId":"5c444401-db67-4cab-8152-9cf3266cc4f5",
 "promptTokenCount":16462,"timestamp":1778650653301}
```

> 此处 `timestamp` 是一个**整数 epoch-ms**(`1778650653301`),不同于
> `user`/`assistant`/`system` 记录中的 ISO-8601 `…Z` 字符串 —— 与
> `task-*.json` 的 epoch-ms 约定一致。键恒为
> `[promptTokenCount, sessionId, timestamp, type]`。这是除 `message.usage` 外的
> **第二个 token 计量面**;Engram 两者都不捕获。

### `system` 记录 —— `task_started` 变体(未解析 —— 主转录中的 subagent 派发)

```json
{"type":"system","subtype":"task_started","level":"info","task_type":"local_agent",
 "task_id":"ageneral-purpose-646b2bc0030e4762","tool_use_id":"call_6d5190e9b79e4996801d6c",
 "uuid":"REDACTED-UUID","parentUuid":"REDACTED-UUID",
 "sessionId":"4789761a-0873-4183-835c-1ff089b7dad2","timestamp":"2026-05-25T…Z",
 "cwd":"/Users/bing/-Code-/engram","version":"0.2.7","userType":"external","entrypoint":"cli",
 "isSidechain":false,"content":"REDACTED","description":"REDACTED","prompt":"REDACTED"}
```

> `system` 携带 `subtype ∈ {task_progress(72), task_notification(9),
> task_started(8), informational(8), error(5), api_retry(1)}` 和
> `level ∈ {info, error}`。`task_type` 为 `"local_agent"`(仅在
> `task_started` 上)或缺省。随 subtype 而定的可选字段:`task_id`、
> `tool_use_id`(此处为 `call_*`)、`prompt`、`description`、`usage`、`status`、
> `output_file`、`summary`。`task_started`/`task_progress` 是主转录中
> 一个**备用的、基于字段的 subagent 派发信号**,而 Engram
> 选择路径推导、忽略它(§10)。

### `system` 记录 —— `error` 变体(未解析 —— 键集更小,无 task 字段)

```json
{"type":"system","subtype":"error","level":"error",
 "uuid":"REDACTED-UUID","parentUuid":"REDACTED-UUID",
 "sessionId":"4789761a-0873-4183-835c-1ff089b7dad2","timestamp":"2026-05-25T…Z",
 "cwd":"/Users/bing/-Code-/engram","version":"1.0.13","userType":"external","entrypoint":"cli",
 "isSidechain":false,"content":"REDACTED"}
```

### `ai-title` 记录(未解析)

```json
{"type":"ai-title","sessionId":"4789761a-0873-4183-835c-1ff089b7dad2","aiTitle":"REDACTED"}
```

### `last-prompt` 记录(未解析)

```json
{"type":"last-prompt","sessionId":"4789761a-0873-4183-835c-1ff089b7dad2","lastPrompt":"REDACTED"}
```

### `file-history-snapshot` 记录(未解析)

```json
{"type":"file-history-snapshot","isSnapshotUpdate":false,
 "messageId":"user:4789761a-0873-4183-835c-1ff089b7dad2########2",
 "snapshot":{"messageId":"user:4789761a-0873-4183-835c-1ff089b7dad2########2",
   "timestamp":"2026-05-25T05:27:59.933Z",
   "trackedFileBackups":{"<abs/path>":{"backupFileName":"REDACTED","version":1,"backupTime":"2026-05-25T05:34:08.872Z"}}}}
```

### `subagents/agent-<id>.meta.json`(未解析)

```json
{"agentType":"Explore","displayName":"Explorer","description":"REDACTED","color":"cyan"}
```

### `subagents/task-<id>.json`(未解析 —— epoch-ms 时间戳)

```json
{"taskId":"aExplore-604c32607f3e8031","sessionId":"4789761a-0873-4183-835c-1ff089b7dad2",
 "executionId":2000000004,"agentId":"aExplore-604c32607f3e8031","agentType":"Explore",
 "description":"REDACTED","parentToolUseId":"toolu_vrtx_01PW3LBksPmMHrjTtH9qL4Fh",
 "outputPath":"/private/tmp/qoder-cli-501/-Users-bing--Code--engram/4789761a-…/tasks/aExplore-604c32607f3e8031.output",
 "transcriptPath":"/Users/bing/.qoder/projects/-Users-bing--Code--engram/4789761a-…/subagents/agent-aExplore-604c32607f3e8031.jsonl",
 "completionBehavior":"notify","status":"completed","summary":"REDACTED",
 "createdAt":1779686940809,"updatedAt":1779687015740,"result":"REDACTED","completedAt":1779687015733}
```

> 实时数据中 `status` ∈ {`completed`(36)、`failed`(11)、`cancelled`(4)} —— 一份
> `task-*.json` **不**保证有匹配的 `agent-*.jsonl` 转录
>(51 个 task spec vs 44 个转录;failed/cancelled 任务可能缺少 —— §2)。

### `<uuid>/state.json`(未解析 —— 加密的 items{})

```json
{"sessionId":"4789761a-0873-4183-835c-1ff089b7dad2","revision":42,
 "createdAt":"REDACTED","updatedAt":"REDACTED","workspaceDirectories":["/Users/bing/-Code-/engram"],
 "data":{},"items":{"<key>":{"c":"REDACTED","n":"BASE64_NONCE","p":"BASE64_PAYLOAD","t":"BASE64_TAG","u":"REDACTED"}}}
```

> `revision` 是示意值 —— 它是一个单调递增的 int(实时观察到高达
> **83**)。无论序列化顺序如何,item 键集合都相同:
> `{c, n, p, t, u}` = created/nonce/payload/tag/updated。

### `<uuid>/compression-v2/state.json`(未解析 —— 尽管目录为 v2,内部 version=1)

```json
{"version":1,"state":{"replacementDecisions":"REDACTED","seenFunctionResponseIds":"REDACTED",
 "sessionMemoryState":"REDACTED","autoCompactTracking":"REDACTED","snippedMessageIds":"REDACTED"}}
```

> 目录名为 `compression-v2`,但文件内部的 `version`
> 字段在全部 7 个实时文件中都是 **`1`**(v2 目录 / v1 字段的区别)。

---

## References (official sources)

Web 确认于 2026-06-21 进行。用于确认 / 印证上述格式断言的官方 Qoder 来源:

- [Qoder Docs — Model Tier Selector](https://docs.qoder.com/user-guide/chat/model-tier-selector) —— 确认模型别名(Auto/Ultimate/Performance/Efficient/Lite)刻意隐藏具体后端模型(§9、§15、开放问题)。
- [Qoder Docs — Hooks (`transcript_path` + JSONL record schema)](https://docs.qoder.com/extensions/hooks) —— 记录了 `transcript/` 子目录布局(§2)、额外的 `session_meta` / `progress` 记录类型(§4),并完全省略了 `message.usage` / `entrypoint`(§9、开放问题)。
- [Qoder Docs — Using CLI (AGENTS.md, /resume, /agents subagents)](https://docs.qoder.com/en/cli/using-cli) —— CLI 启动面与 subagent 管理的背景。
- [Qoder Blog — Introducing Qoder Community Edition](https://qoder.com/blog/qoder-community) —— 确认多个启动面(Desktop IDE / JetBrains 插件 / CLI / Mobile / Cloud),是 IDE-GUI `entrypoint` 可能性的依据(§5、开放问题)。
- [Qoder homepage](https://qoder.com/en) —— 阿里巴巴 agentic AI 编码 IDE;多后端(Claude / GPT / Gemini + Qwen / DeepSeek / GLM / Kimi)佐证(§15)。
- [Qoder-AI/qoder-community](https://github.com/Qoder-AI/qoder-community) —— MIT 许可的社区文档/技能(并非 IDE 源码);"闭源、加密方案未被记录"的依据(§13、开放问题)。
