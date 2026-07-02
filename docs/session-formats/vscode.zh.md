# VS Code (Copilot Chat) — 会话存储格式

> 本文档为英文权威版 vscode.md 的中文阅读副本；若有出入以英文版为准。

Last researched: 2026-07-01 (official microsoft/vscode source recheck +
Engram session-format workflow); adapter replay and cwd fallback behavior
verified: 2026-07-01.

> **范围。** 本文档描述 **VS Code Copilot Chat / Agent
> 扩展**（稳定版 VS Code 编辑器*内部*的聊天面板）如何持久化聊天
> 会话，以及 Engram 的 `vscode` 适配器如何消费它们。这**不是**
> GitHub Copilot CLI（`~/.copilot/session-state`、`events.jsonl` +
> `workspace.yaml`）——那是一个独立的产品和独立的适配器
> (`tests/fixtures/copilot/`)。参见 [§15 谱系](#15-谱系陷阱版本漂移与边界情况)。

---

## 证据基础

| Basis | Detail |
|---|---|
| **Live store**（布局/生命周期的主要依据） | `~/Library/Application Support/Code/User/workspaceStorage/` ——**19 个 workspace 目录**（机器状态，非关键），其中**4 个**包含 `chatSessions/` 文件夹，共有**5 个 `*.jsonl` 聊天会话文件**。**全部 5 个 live 会话都是空桩**（`requests: []`；当前 `.jsonl` 快照没有顶层 `isEmpty`）。其中一个文件 (`cea0313a…`) 有**2 行**（一条 `kind:0` 快照 + 一条 `kind:1` 补丁）；其余 4 个为单行。每个 workspace 下均有 `state.vscdb`（SQLite）。 |
| **Repo fixtures**（已填充 `requests[]` 的主要依据） | `tests/fixtures/vscode/ws-abc123/` ——1 个会话 `sess-001.jsonl`，含**2 个已填充的 request** + `workspace.json`。`tests/fixtures/adapter-parity/vscode/input/` 下有相同副本，并带有 golden 输出 `success.expected.json`。这是本机上唯一可用的已填充轮次样本。 |
| **Adapters**（已编码的知识） | Swift 产品解析器 `macos/Shared/EngramCore/Adapters/Sources/VsCodeAdapter.swift`；TS 参考实现 `src/adapters/vscode.ts`。两者都会 replay 初始快照后的有效 ObjectMutationLog entries，并在 `workspace.json` 不能解析出本地路径时使用 session `workingDirectory` 作为 cwd fallback。测试：`tests/adapters/vscode.test.ts`、`AdapterMessageCountTests.testVsCodeReplaysAppendMutationLog`、`AdapterMessageCountTests.testVsCodeUsesSessionWorkingDirectoryWhenWorkspaceJsonMissing`。 |

**各层以哪种依据为准：**
- **目录/命名/生命周期/SQLite/补丁行层 → 以 live 数据为准**（已在磁盘上验证）。
- **已填充 request/response schema 层 → 以 fixture + 适配器类型定义为准**（没有任何 live 会话具有非空的 `requests[]`）。

**相对于维度报告发现的差异（以 live 数据为准，就地标注）：**
1. `state.vscdb` 的 schema 是 `CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)` ——**不是**某份报告声称的 `PRIMARY KEY`。
2. `kind:1` 补丁行的 `k` 字段是一个 **JSON 数组**（`["inputState"]`），**不是**某份报告推断的字符串 keypath。
3. Workspace 目录数量是机器状态，对该格式**不构成关键依据**。Live store 当前有**19**个 workspace 目录（已验证：`python3` glob `workspaceStorage/*` → 19 个目录，4 个 `chatSessions/` 目录中共 5 个 `*.jsonl`）。"19"这个读数是正确的；此前任何"21"的数字都是过时的。

---

## 1. 概述与 TL;DR

**是什么/在哪里/如何工作。** VS Code 的 Copilot Chat 扩展在每个
workspace 的存储目录下**为每个聊天会话写入一个文件**。每个文件是
一个独立完整的 JSON 对象（整个会话），位于**第 0 行**，带有装饰性的
`.jsonl` 扩展名。后续行（存在时）是 VS Code 重放以重建当前状态的
增量 `kind:1` 补丁。同级的 **`state.vscdb` SQLite** 文件为 UI 保存了
一份派生的会话*索引*（标题、时间、空标志）；同级的 **`workspace.json`**
将 workspace 映射到文件系统文件夹（Engram 获取 `cwd` 的主要来源；
session `workingDirectory` 是 fallback）。
编辑历史存放于并行的 `chatEditingSessions/` 树中。

**心智模型：** `.jsonl` 文件是**记录内容**；`state.vscdb`
是**派生目录**；`workspace.json` 是**身份附属文件**。Engram
读取并 replay 每个 `.jsonl` 中的有效 ObjectMutationLog entries，读取
`workspace.json`，并在 sidecar 无法产生本地 cwd 时回退到
`v.workingDirectory`；它从不打开 SQLite DB 或编辑树。

```
~/Library/Application Support/Code/User/workspaceStorage/
│
├── <workspace-id>/                      ┐ one dir per VS Code workspace
│   ├── workspace.json                   │  identity → cwd   [READ, primary]
│   ├── state.vscdb        (SQLite)      │  session index    [IGNORED]
│   ├── state.vscdb.backup (SQLite)      │  hot backup       [IGNORED]
│   ├── chatSessions/                    │  ← ADAPTER TARGET
│   │   └── <session-uuid>.jsonl         │    line0=kind:0 snapshot  [REPLAYED]
│   │                                    │    line1+=kind:1/2/3 mutations [REPLAYED]
│   └── chatEditingSessions/             │  edit snapshots   [IGNORED]
│       └── <session-uuid>/              │    (same UUID as the chat session)
│           ├── state.json (version 2)   ┘
│           └── contents/   (blob dir, often empty)
│
   Engram pipeline:  enumerate *.jsonl → replay mutation log from kind:0 state
                     → require requests non-empty & creationDate present
                     → climb 2 dirs up → read workspace.json → fallback to v.workingDirectory
                     → emit {user, assistant} text pairs
```

**Engram 的 TL;DR：** `id ← v.sessionId`、`startTime ← v.creationDate`、
`endTime ← last request timestamp`、`cwd ← workspace.json ∥ v.workingDirectory`，
messages = `{user text, first markdownContent block}` 对。**没有 model、没有 tokens、没有 tool 调用、
没有 system 消息。** 空会话（此处的 live 常态）会被拒绝。在本机上，
适配器尽管存在 5 个文件，但会索引到**0**个 VS Code 会话。

---

## 2. 磁盘布局与文件命名

**权威根目录**（Swift `VsCodeAdapter.swift:9-11`；TS `vscode.ts:41-48`）：

```
~/Library/Application Support/Code/User/workspaceStorage/
```

`Code - Insiders/User/workspaceStorage/` 使用**完全相同**的格式，但
默认适配器根目录只指向稳定版 `Code/` ——Insiders **未被覆盖**
（[§15](#15-谱系陷阱版本漂移与边界情况)）。2026-07-01 复查时，
`~/Library/Application Support/Code - Insiders/User/workspaceStorage`
在本机上不存在，所以这个 Insiders 覆盖缺口是格式层面的；当前没有本机
Insiders chat 文件被漏扫。

**目录结构：**

```
workspaceStorage/
  <workspace-id>/
    workspace.json              # workspace → folder mapping (primary cwd source) [READ]
    state.vscdb                 # SQLite UI/index state                     [NOT read]
    state.vscdb.backup          # SQLite hot backup                         [NOT read]
    chatSessions/               # ← adapter target
      <session-uuid>.jsonl      # one chat session, payload on line 0
      <session-uuid>.jsonl
    chatEditingSessions/        # paired edit history                       [NOT read]
      <session-uuid>/           # SAME UUID as the chat session (1:1)
        state.json              # edit timeline (version 2)
        contents/               # file-snapshot blobs (often empty)
```

**命名文法：**

| Token | Grammar | Live examples |
|---|---|---|
| `<workspace-id>` | 要么是 32 字符小写十六进制哈希（workspace URI 的 MD5），要么是数字毫秒时间戳字符串 | hex: `a869823f8fa74cc87f120cdcb5be6bb8`, `395a8c5152c24172f4854c792bd2b32f`; numeric: `1772874866399`, `1781946123322` |
| `<session-uuid>` | RFC-4122 v4 UUID，小写，`.jsonl` 扩展名 | `5e2c51cc-3e7a-42b9-a239-2d3bb4e30694.jsonl`, `cea0313a-2e97-477f-83aa-850a5f9faad1.jsonl` |
| `chatEditingSessions/<session-uuid>/` | 目录名使用与其聊天会话**相同的 UUID**（1:1 配对） | `chatEditingSessions/5e2c51cc-3e7a-42b9-a239-2d3bb4e30694/` |

`.jsonl` 扩展名在 chat-message 意义上是一种**误称**：第 0 行是初始会话对象，
后续行是 ObjectMutationLog entries，不是独立的聊天消息记录。两个适配器都会
replay 第 0 行之后的有效 mutation entries（Swift `readSession`/`replayMutationLog`
`:140-180`；TS `readSession`/`replayMutationLog` `:220-277`）。

**Live 树（已匿名化）：**

```
workspaceStorage/
├── a869823f8fa74cc87f120cdcb5be6bb8/
│   ├── workspace.json                  # {"folder":"file:///Users/<user>/<proj>"}
│   ├── state.vscdb                     # SQLite, 53 KB
│   ├── state.vscdb.backup              # SQLite, 53 KB
│   ├── chatSessions/
│   │   ├── 5e2c51cc-3e7a-42b9-a239-2d3bb4e30694.jsonl   # 524 B, 1 line (empty)
│   │   └── cea0313a-2e97-477f-83aa-850a5f9faad1.jsonl   # 545 B, 2 lines (kind:0 + kind:1)
│   └── chatEditingSessions/
│       ├── 5e2c51cc-3e7a-42b9-a239-2d3bb4e30694/
│       │   ├── state.json              # version 2
│       │   └── contents/               # (empty)
│       └── cea0313a-2e97-477f-83aa-850a5f9faad1/
│           ├── state.json
│           └── contents/
├── 1772874866399/                      # numeric workspace-id, no chatSessions/
└── 3011e0800a82af49da1596d7bbbf8a16/
    └── workspace.json                  # {"workspace":"file:///.../Code/Workspaces/.../workspace.json"}  ← legacy key
```

---

## 3. 文件生命周期与生成

- **存储技术：** 每个会话一个 JSON 文件（装饰性的 `.jsonl`），对话主体**不是** SQLite。SQLite (`state.vscdb`) 只保存派生索引。
- **每个会话一个文件，就地重写（在概念层面**不是**追加式）。** 第 0 行是 `v` 的完整快照；VS Code 在保存时重新序列化它。
  第 1..N 行是它追加、稍后再折叠回快照的 ObjectMutationLog entries
  （`kind:1` set、`kind:2` push/splice、`kind:3` delete）。两个适配器当前都会 replay 这些有效 mutation entries。
- **文件创建：** 当某个 workspace 中打开聊天面板时，会出现一个新的
  `chatSessions/<uuid>.jsonl`（加上配对的
  `chatEditingSessions/<uuid>/`）。空会话即使没有轮次也会持续存在；当前 `.jsonl`
  快照中的决定性标记是 `requests: []`，而 `isEmpty` 位于派生的
  `state.vscdb` 索引中——**全部 5 个 live 会话都按此标记为空**。
- **DB 与文件分工：** `.jsonl` = 记录内容；`state.vscdb`
  (`chat.ChatSessionStore.index`) = 派生索引（标题、时间、空标志）；
  `state.vscdb.backup` = SQLite 热备份。适配器有意绕过
  DB 直接读取文件——对 DB 损坏具有韧性，但无法使用
  DB 的 `title`/`isEmpty` 元数据。
- **续接：** 继续聊天会重新打开同一个 `<uuid>.jsonl`，向
  `v.requests` 添加一个 request，并重写第 0 行。`creationDate` 是稳定的；`endTime` 跟踪
  最后一个 request 的 `timestamp`。
- **滚动切分：** 无——没有基于大小的拆分。一次长对话会让单个文件不断增大。
- **编辑历史：** `chatEditingSessions/<uuid>/state.json`（`version: 2`，字段
  `version`、`initialFileContents`、`timeline`、`recentSnapshot`）加上一个
  `contents/` blob 目录跟踪 agent 的文件编辑。生命周期独立；适配器
  完全忽略它。
- **归档/删除：** 删除一个聊天会移除其 `.jsonl` 及其
  `chatEditingSessions/<uuid>/`，并从
  `chat.ChatSessionStore.index` 中删除对应条目。文件层没有墓碑标记。

**Engram 如何枚举**（纯文件系统，无 SQLite、无 manifest）：
1. **检测**（Swift `detect()` `:18-20`；TS `:51-58`）：`workspaceStorage/` 存在。
2. **枚举**（Swift `listSessionLocators()` `:22-36`；TS `listSessionFiles()`
   `:60-74`）：对每个直接子目录，检查 `<child>/chatSessions/`；收集
   每个带 `.jsonl` 扩展名的文件。TS 使用 glob `*/chatSessions/*.jsonl`；Swift
   遍历直接子目录并过滤 `pathExtension == "jsonl"`，然后排序。
3. **解析**（`parseSessionInfo`）：将 ObjectMutationLog replay 成当前状态；
   若 `requests` 为空或 `creationDate` 缺失则拒绝（Swift `:40-48`；TS `:76-115`）。
4. **cwd 解析：** 向上爬两级目录（`<uuid>.jsonl` → `chatSessions/` →
   `<id>/`），读取 `workspace.json`，解码 `folder`/`configuration` URI；如果
   sidecar 没有产生本地路径，则回退到 `v.workingDirectory`。
5. **消息流**（`streamMessages`）：遍历 `v.requests`；从
   `message.text`/`parts` 发出一条 `user` 消息，然后从首个
   `response[].value.kind === "markdownContent"` 块发出一条 `assistant` 消息。`toolMessageCount` /
   `systemMessageCount` 硬编码为 `0`。

---

## 4. 记录 / 行分类

`.jsonl` 文件是快照 + 变更日志。Engram 会 replay 初始快照之后的有效
mutation entries，因此后续行可以影响解析出的消息。

| Line `kind` | Record type | Top-level fields | Meaning | Engram use |
|---|---|---|---|---|
| `0` | **Initial snapshot** | `kind:0`, `v:{…}`（完整会话对象——见 [§5](#5-共享信封--元数据字段)/[§6](#6-消息与内容-schema)） | 初始的完整会话序列化 | **作为起始状态解析** |
| `1` | **Set** | `kind:1`, `k:[…keypath…]`, `v:<value>` | 在 JSON keypath 数组 `k` 处设置值（例如替换 `inputState`） | **Replayed** |
| `2` | **Push/splice** | `kind:2`, `k:[…keypath…]`, `v:[…values…]`, optional `i:<startIndex>` | 在 JSON keypath 处追加值；存在 `i` 时先截断到该位置 | **Replayed** |
| `3` | **Delete/unset** | `kind:3`, `k:[…keypath…]` | 移除/清空 JSON keypath 处的值 | **Replayed** |

> **相对于 DIM 报告的更正：** `k` 是一个由路径段组成的 **JSON 数组**
> （`["inputState"]`），已在 live 中验证——不是字符串。

TS adapter 对非法或未知尾部 entry 的容忍度有明确测试：
`tests/adapters/vscode.test.ts:58-104` 写入非法 JSON 行加未知 `kind:99` entry，
并断言初始快照仍会解析。Swift 在 JSONL reader 层更严格，遇到 malformed JSON
line 会返回 `.malformedJSON`；Swift 和 TS 都会 replay 有效的 `kind:1/2/3` entries。

---

## 5. 共享信封 / 元数据字段

### 5a. 记录层包装（第 0 行）

| Field | Type | Meaning | Optionality | Example |
|---|---|---|---|---|
| `kind` | int | 记录类型判别符；适配器要求为 `0` 才接受该文件 | required | `0` |
| `v` | object | 完整会话 payload | required | `{ "version": 3, … }` |

### 5b. `v` —— 会话 payload（live `version: 3`）

所有字段均在 5 个 live 桩上验证过；类型/可选性逐字记录。

| Field | Type | Meaning | Optionality | Engram reads? | Example (anon) |
|---|---|---|---|---|---|
| `version` | int | 聊天会话格式的 schema 版本。Live + fixture 均为 `3`。 | required | No（在 TS `VsSessionData` 中已类型化，但从不分支） | `3` |
| `sessionId` | string (UUID) | 稳定的会话 id；与文件名匹配 | required | **Yes → `id`**（回退：文件名主干） | `"5e2c51cc-3e7a-42b9-a239-2d3bb4e30694"` |
| `creationDate` | int (epoch **ms**) | 会话开始 | required（Swift 在缺失时硬失败） | **Yes → `startTime`** | `1771392503565` |
| `requests` | array<VsRequest> | 有序的轮次对 | required（可为 `[]`；空 → 拒绝） | **Yes → messages/counts** | `[]`（live）/ 2 条（fixture） |
| `initialLocation` | string enum | 聊天打开的位置：`"panel"`（也有 `"editor"`、`"terminal"`、`"notebook"`、`"editing-session"`） | present | No | `"panel"` |
| `responderUsername` | string | 助手显示名（`""`、`"GitHub Copilot"`、`"Gemini"`…） | present | No（来源信号丢失） | `""` |
| `requesterUsername` | string | 用户身份 | sometimes absent | No | `null` |
| `hasPendingEdits` | bool | 存在未应用的 agent 编辑 | present | No | `false` |
| `pendingRequests` | array | 尚未完成的进行中轮次 | present | No | `[]` |
| `inputState` | object | 持久化的编辑器/输入框草稿状态 | optional（当由后续 `kind:1` 补丁携带时，第 0 行可能缺失——已在 `cea0313a…` 上 live 验证，其第 0 行 `v` 省略它而第 1 行 `{"kind":1,"k":["inputState"]}` 携带它；另外 4 个 live 桩在第 0 行包含它） | No | 见下文 |
| `workingDirectory` | string URI | 当前官方 schema 会把模型 working directory 持久化为 URI 字符串；5 个本机空桩未出现 | optional | **Yes → `cwd` fallback** | `"file:///Users/<user>/<proj>"` |
| `repoData` | object | 当前官方 schema 持久化的仓库元数据；5 个本机空桩未出现 | optional | No | `null` |
| `customTitle` | string | 用户重命名的会话标题 | optional | No（标题取自首条 user 消息） | `null` |
| `isImported` | bool | 从其他工具导入 | optional | No | `null` |

`inputState` 子对象（已 live 验证）：

| Field | Type | Meaning | Example |
|---|---|---|---|
| `attachments` | array | 附加的上下文项（文件/选区） | `[]` |
| `mode` | object \| null | 当前聊天模式（一个 live 文件的 `mode: null`） | `{"id":"agent","kind":"agent"}` |
| `mode.id` / `mode.kind` | string | 模式 id/kind | `"agent"`（也观察到：`"ask"`、`"edit"`） |
| `inputText` | string | 编辑器中的草稿文本 | `""` |
| `selections` | array<object> | 编辑器选区范围（1-based 行/列）；字段 `startLineNumber`、`startColumn`、`endLineNumber`、`endColumn`、`selectionStartLineNumber`、`selectionStartColumn`、`positionLineNumber`、`positionColumn` | `[{"startLineNumber":1,…,"positionColumn":1}]` |
| `contrib` | object | 贡献的输入模型状态 | `{"chatDynamicVariableModel":[]}` |

当前官方 `inputState` schema 还包含 `selectedModel` 和 `permissionLevel`；
它们在 2026-07-01 复查的 5 个本机空桩中没有出现。

> Engram 从 `v` 读取 `sessionId`、`creationDate`、`requests`（外加隐式的 `version`）。
> 当 `workspace.json` 无法解析出本地路径时，它还会把 `workingDirectory`
> 作为 `cwd` fallback。它**不**读取 `initialLocation`、`inputState`、`mode`、
> `selectedModel`、`permissionLevel`、`responderUsername`、`requesterUsername`、
> `hasPendingEdits`、`repoData`、`pendingRequests`、`customTitle` 或
> `isImported`。Model 和 token/usage 在会话级别**完全缺失**。

---

## 6. 消息与内容 schema

### Layer A —— `requests[i]`（轮次对象）

每个元素是**一个 user→assistant 轮次**；用户提示与完整助手
响应共处一处（**不存在**独立的按角色顶层记录）。

| Field | Type | Meaning | Optionality | Engram reads? | Example |
|---|---|---|---|---|---|
| `requestId` | string | 轮次 id | required | No | `"req-1"` |
| `message` | object | **用户**提示（Layer B） | required | **Yes → user text** | `{"text":"…","parts":[…]}` |
| `response` | array<object> | 有序的**助手**响应部分（Layer C） | required | **Yes → first markdown only** | `[{"value":{…}}]` |
| `timestamp` | int (epoch **ms**) | 轮次时间 | optional | **Yes → per-msg ts; last → `endTime`** | `1771392005000` |
| `result` | object | 轮次结果（错误、元数据） | optional（真实 VS Code） | No | `{"errorDetails":{…},"metadata":{…}}` |
| `followups` | array | 建议的后续提示 | optional（真实 VS Code） | No | `[{"kind":"reply","message":"…"}]` |
| `isCanceled` | bool | 用户取消了该轮次 | optional（真实 VS Code） | No | `false` |
| `agent` / `slashCommand` | object | 调用的参与者/agent + `/command` | optional（真实 VS Code） | No | `{"id":"github.copilot.default",…}` |
| `variableData` | object | 已解析的 `#`/`@` 上下文变量 | optional（真实 VS Code） | No | `{"variables":[…]}` |
| `modelId` | string | 该轮次使用的模型 | optional（真实 VS Code） | No | `"gpt-4o"` |

> Engram 已知的四个字段（`requestId`、`message`、`response`、`timestamp`）
> 已从 fixture 验证。其余（`result`、`followups`、`isCanceled`、
> `agent`、`variableData`、`modelId`）是来自源码/网络 + 适配器注释的
> 真实 VS Code 超集——**在本机的空数据中不存在**。

### Layer B —— 用户内容块：`requests[i].message`

| Field | Type | Meaning | Optionality | Example |
|---|---|---|---|---|
| `text` | string | 扁平化的纯文本提示（首选的提取路径） | optional | `"How do I use async/await in TypeScript?"` |
| `parts` | array<{kind,value}> | 结构化的提示片段 | optional | 见下文 |
| `parts[].kind` | string | 片段类型：`"text"`（真实 VS Code 还有 `"reference"`、`"dynamic"`/`#file`、`"slash"`、`"image"`） | — | `"text"` |
| `parts[].value` | string | 片段文本（对于 `kind:"text"`） | — | `"How do I use async/await in TypeScript?"` |

**提取顺序**（`extractUserText`，Swift `:203-218`；TS `:236-244`）：优先取
非空的 `message.text`；否则取首个 `kind == "text"` 且 `value` 非空的 `parts[]`；
否则为 `""`（该轮次不贡献用户消息）。

### Layer C —— 助手响应块：`requests[i].response[]`

`response` 是流式部分的有序数组，每个都包裹为
`{ "value": { "kind": <part-type>, … } }`。一个轮次通常持有许多部分
（progress、tool 调用，然后是 markdown）。**Engram 只提取首个
`markdownContent` 部分的文本**，并忽略所有其他 kind（`extractAssistantText`，
Swift `:220-233`；TS `:246-253`）。

| `value.kind` | Part type | Key nested fields | In live data? | Engram |
|---|---|---|---|---|
| `markdownContent` | 渲染的助手散文/代码 | `content.value`（markdown 字符串） | **fixture** | **Parsed**（首个胜出） |
| `progressTask` / `progressMessage` | 流式进度 / "working…" | `content`、task state | adapter-only | Ignored |
| `toolInvocationSerialized`（亦称 `toolUse`） | **Tool 调用 + 结果，共处一处** | `toolId`、`toolCallId`、`invocationMessage`、`pastTenseMessage`、`isComplete`、`resultDetails` | adapter-only | Ignored |
| `inlineReference` / `reference` | 代码/文件引用 | `inlineReference`（uri+range） | adapter-only | Ignored |
| `codeblockUri` | 后续代码块的 URI 标记 | `uri`、`isEdit` | adapter-only | Ignored |
| `textEditGroup` | 已应用的文件编辑（agent 编辑） | `uri`、`edits[]`、`done` | adapter-only | Ignored |
| `command` / `confirmation` | 按钮 / 确认提示 | `command`、`title`、`data` | adapter-only | Ignored |
| `warning` / `error` | 内联警告/错误块 | `content` | adapter-only | Ignored |

**已匿名化的已填充 request（fixture `sess-001.jsonl`）：**

```json
{
  "requestId": "req-1",
  "message": {
    "text": "<user prompt text>",
    "parts": [{ "kind": "text", "value": "<user prompt text>" }]
  },
  "response": [
    { "value": { "kind": "markdownContent", "content": { "value": "<assistant markdown>" } } }
  ],
  "timestamp": 1771392005000
}
```

---

## 7. Tool 调用与结果

**对 Engram 提取而言 N/A ——格式中存在，读取时丢弃。** 在 VS
Code 内部，一次 tool 调用及其结果被**融合进单个
`toolInvocationSerialized` 部分**（它同时持有调用消息和
`resultDetails`/`isComplete`）。**不存在**像 Anthropic/OpenAI 日志中那样
按 id 索引的独立 `tool_result` 记录——调用↔结果的关联是这一部分
内在固有的。Engram 完全**不**捕获这些：`value.kind == "toolInvocationSerialized"|"toolUse"`
的响应部分被静默跳过，`toolCalls` 始终为 `nil`/`[]`，且 `toolMessageCount` 硬编码为 `0`（Swift
`:69,113,125`；TS `:107`）。响应完全是 tool 调用的轮次不产生任何
助手消息，并被从计数中排除（TS 注释 `:85-89`）。

> 未从 live 数据采样（所有 live 会话均为空）；依据 VS Code
> 源码/网络 + 适配器注释记录。

---

## 8. 推理 / thinking

**N/A。** 本机数据中未出现专门的 thinking/reasoning 部分，且
VS Code 历史上不会序列化独立的 reasoning 块——助手
散文存放在 `markdownContent` 中。即便存在 reasoning 部分，Engram 也会
忽略它（只提取 `markdownContent`）。

---

## 9. Token 用量与成本

**N/A —— VS Code 在适配器可触及的任何层级都不存储这些。** live 数据
或 fixture 中，在会话、request 或响应部分级别都没有
`usage`/token 字段。Engram 为每条消息发出 `usage: nil`（Swift `:114,125`），
parity golden 的 `usageTotals` 全为零（`inputTokens`/`outputTokens`/
`cacheCreationTokens`/`cacheReadTokens` = `0`）。无法推导成本。

---

## 10. 子 agent / 父子 / 派发

**N/A。** VS Code Copilot Chat 在此格式中没有父子会话关联
（没有 Gemini 风格的 `.engram.json` 附属文件，没有基于路径的子 agent 嵌套）。
适配器将 `parentSessionId`、`suggestedParentId`、`agentRole`、`originator`
和 `origin` 全部设为 `nil`（Swift `:74-82`）。父子检测层在 Engram core
的下游运作，而非在此适配器中。

> 注：单个 workspace 可承载*多个聊天后端*（live `state.vscdb`
> 同时显示 `workbench.panel.chat`（Copilot）和
> `workbench.view.extension.geminiChat.state`（Gemini）键），它们都写入
> 相同的 `chatSessions/*.jsonl` 格式。`responderUsername` 字段可以
> 区分它们，但 Engram 丢弃了它——见 [§15](#15-谱系陷阱版本漂移与边界情况)。

---

## 11. 摘要 / 压实

**格式内 N/A。** VS Code 不存储 Engram 会消费的压实/摘要轮次类型。
Engram 合成自己的 `summary` 字段 = 首条非空
用户文本截取到 200 字符（Swift `:71`；TS `:109`）。它**不**使用来自
`state.vscdb` 的 `chat.ChatSessionStore.index` 的现成 `title`（这是保真度
缺口，不是 schema 错误）。

---

## 12. SQLite / DB 内部 —— `state.vscdb`

VS Code 的*索引*是 DB 支撑的工具，但记录稿是文件支撑的。
按 workspace 的 `state.vscdb` 是一个通用的键/值存储。**Engram 不读取
它** ——它是权威的会话目录，在此记录仅为完整起见。

**Schema（已 live 验证）：**

```sql
CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);
```

> **相对于 DIM 2 的更正：** key 列是 `TEXT UNIQUE ON CONFLICT REPLACE`，
> **不是** `PRIMARY KEY`。`value` 是 `BLOB`（保存 JSON 文本）。

**Live 中发现的聊天相关键**（在 workspace `a869…` 中）：

| Key | Holds |
|---|---|
| `chat.ChatSessionStore.index` | **Session 索引** ——按会话的元数据映射（见下文） |
| `memento/interactive-session-view-copilot` | 最后活动的会话 id + 编辑器/输入状态 |
| `chat.untitledInputState` | 未命名（新）聊天的草稿输入 |
| `chat.customModes` | 用户定义的自定义聊天模式 |
| `workbench.panel.chat` | Copilot 聊天面板 UI 状态 |
| `workbench.panel.chat.numberOfVisibleViews` | 面板布局计数 |
| `workbench.view.extension.geminiChat.state` | Gemini 聊天扩展视图状态（共存后端） |
| `workbench.view.extension.geminiOutline.state` | Gemini outline 视图状态 |

**`chat.ChatSessionStore.index` 值** —— `{ version, entries: { <uuid>: {…} } }`：

| Entry field | Type | Meaning | Example (anon) |
|---|---|---|---|
| `sessionId` | string | 会话 UUID（= `.jsonl` 文件名） | `"cea0313a-2e97-477f-83aa-850a5f9faad1"` |
| `title` | string | VS Code 展示的人类可读标题（首次提示前为 `"New Chat"`） | `"<REDACTED>"` |
| `lastMessageDate` | int (ms) | 最后活动时间 | `1772112775137` |
| `timing` | object `{created:int}` | 创建时间 | `{"created":1772112775137}` |
| `initialLocation` | string enum | 打开位置 | `"panel"` |
| `hasPendingEdits` | bool | 待处理编辑标志 | `false` |
| `isEmpty` | bool | 当 `requests` 为空时为 true（匹配全部 5 个 live 会话） | `true` |
| `isExternal` | bool | 外部（remote/agent）来源 | `false` |
| `lastResponseState` | int enum | 最后响应状态码 | `1` |

---

## 13. 辅助文件

| File / dir | Tech | Purpose | Engram |
|---|---|---|---|
| `workspace.json` | JSON | Workspace 身份 → 主要 `cwd` 来源（Engram 读取的唯一附属文件） | **READ** |
| `state.vscdb` | SQLite | Session 索引、面板/草稿状态（[§12](#12-sqlite--db-内部--statevscdb)） | NOT read |
| `state.vscdb.backup` | SQLite | `state.vscdb` 的热备份 | NOT read |
| `chatEditingSessions/<uuid>/state.json` | JSON（`version: 2`；键 `version`、`initialFileContents`、`timeline`、`recentSnapshot`） | 该会话的 agent 文件编辑时间线 | NOT read |
| `chatEditingSessions/<uuid>/contents/` | 不透明 blob | 用于编辑撤销的文件快照 blob（常为空） | NOT read |

**cwd 解析**（Swift `readCwd` / `readWorkspaceCwd` `:55,260-289`；TS `:94-96,128-166`）：

| Key | Type | Meaning | Adapter handles? | Live example (anon) |
|---|---|---|---|---|
| `folder` | string（`file://` URI） | 单根 workspace 文件夹 → `cwd` | **YES**（Swift `:163-165`；TS `:134`） | `"file:///Users/<user>/<proj>"` |
| `configuration` | string（`file://` URI） | 指向 `.code-workspace` 的路径；适配器打开它并读取 `folders[0].uri`/`.path` | **YES**（Swift `:166-192`；TS `:135-165`） | `"file:///…/foo.code-workspace"` |
| `workspace` | string（`file://` URI） | **Legacy** 多根指针，指向全局 `Code/Workspaces/<id>/workspace.json` | **NO —— 已标注**（[§15](#15-谱系陷阱版本漂移与边界情况)） | `"file:///Users/<user>/Library/Application%20Support/Code/Workspaces/1616927850246/workspace.json"` |

解析规则：单根 `folder` → `decodeFileURI`（去掉 `file://`、
可选的 `localhost/`、百分号解码）；非 `file://` URI（`vscode-remote://`、
`vsls://`）→ `""`。多根：打开 `.code-workspace`，取 `folders[0].uri`
（解码后）或 `folders[0].path`（绝对路径按原样；相对路径相对于
`.code-workspace` 目录解析）。如果这个 sidecar 路径产生 `""`，Engram
会回退到 session payload 的 `v.workingDirectory`，同样只接受本地
`file://` URI。

Live 分布：**16** 个 workspace 使用 `folder`，**1** 个使用 legacy
`workspace` 键。

---

## 14. Engram 映射

源字段/记录 → Engram `Session` 字段 → 适配器 file:line（Swift + TS）。

| Engram field | Source of value | Swift file:line | TS file:line | Notes / gotcha |
|---|---|---|---|---|
| `id` | `v.sessionId` ∥ 文件名主干 | `VsCodeAdapter.swift:51-52` | `vscode.ts:96` | 若 `sessionId` 为空则回退到 `<uuid>.jsonl` basename |
| `source` | 常量 `"vscode"` | `VsCodeAdapter.swift:4,58` | `vscode.ts:35,97` | — |
| `summary` / title | 首条非空用户文本，截取到 200 字符 | `VsCodeAdapter.swift:71` | `vscode.ts:109` | 不使用专门的标题；`customTitle` + DB `title` 被忽略 |
| `cwd` | `workspace.json` `folder`/`configuration` → 解码的 `file://`；fallback 到 `v.workingDirectory` | `VsCodeAdapter.swift:55,260-289` | `vscode.ts:94-96,128-166` | 若两个来源都缺失/remote/格式错误/legacy-`workspace` 则为 `""` |
| `project` | 始终为 `nil` | `VsCodeAdapter.swift:64` | （省略） | 稍后由 Engram core 从 `cwd` 解析 |
| `model` | 始终为 `nil` | `VsCodeAdapter.swift:65` | （省略） | 即使存储中存在也不提取 |
| `startTime` | `v.creationDate` (ms) → ISO8601 | `VsCodeAdapter.swift:43,59` | `vscode.ts:98` | **若 `creationDate` 缺失，Swift 硬失败**（`:43-44`）；TS 由 try/catch null 守护（`:80,113`） |
| `endTime` | 最后 request 的 `timestamp` (ms) → ISO；若 `== creationDate` 则为 `nil` | `VsCodeAdapter.swift:50,60-62` | `vscode.ts:90,99-102` | 单轮次聊天为 `nil`/`undefined` |
| `messageCount` | `userTexts.count + assistantTexts.count` | `VsCodeAdapter.swift:66` | `vscode.ts:104` | 只统计产出非空文本的轮次 |
| `userMessageCount` | 非空用户文本计数 | `VsCodeAdapter.swift:67` | `vscode.ts:91,105` | — |
| `assistantMessageCount` | 非空 `markdownContent` 文本计数 | `VsCodeAdapter.swift:68` | `vscode.ts:92,106` | **仅含 toolUse/progressTask 的轮次不计数** |
| `toolMessageCount` | 常量 `0` | `VsCodeAdapter.swift:69` | `vscode.ts:107` | Tool 调用从不被提取（[§7](#7-tool-调用与结果)） |
| `systemMessageCount` | 常量 `0` | `VsCodeAdapter.swift:70` | `vscode.ts:108` | — |
| per-message `role` | 仅 `user` / `assistant` | `VsCodeAdapter.swift:110,121` | `vscode.ts:186,202` | 不发出 tool/system 角色 |
| per-message `content` | user/assistant 文本（Layer B/C） | `VsCodeAdapter.swift:106-129` | `vscode.ts:182-211` | — |
| per-message `timestamp` | request `timestamp` (ms) → ISO | `VsCodeAdapter.swift:104-105` | `vscode.ts:188-190,204-206` | 一个轮次的两条消息共享该轮次时间戳 |
| per-message `toolCalls` / `usage` | `nil` | `VsCodeAdapter.swift:113-114,124-125` | `vscode.ts`（省略） | 无 tool/token 数据 |
| `filePath` | `.jsonl` 定位 | `VsCodeAdapter.swift:72` | `vscode.ts:110` | — |
| `sizeBytes` | 磁盘上完整文件大小 | `VsCodeAdapter.swift:75` | `vscode.ts:78,111` | 整个 `.jsonl` log bytes，不只是 final-state payload |
| `agentRole`/`originator`/`origin`/`parentSessionId`/`suggestedParentId`/`tier`/`qualityScore`/`indexedAt`/`summaryMessageCount` | 全部 `nil` | `VsCodeAdapter.swift:74-82` | （n/a） | 由 Engram core 在下游设置 |

**发现 / 读取内部：** 检测 `VsCodeAdapter.swift:20-22` / `vscode.ts:51-58`；
枚举 `:24-38` / `:60-74`；通过 `readSession` + `replayMutationLog` replay session log
（`VsCodeAdapter.swift:140-180`；`vscode.ts:220-277`）；
`extractUserText` `:311-326` / `:229-237`；`extractAssistantText` `:328-341` /
`:239-246`；`decodeFileURI` `:302-309` / `decodeFileUri` `:313-326`。

**注册：** Swift `macos/Shared/EngramCore/Adapters/SessionAdapterFactory.swift:24,69`
（`VsCodeAdapter()`）——注意该 factory 直接位于 `Adapters/` 下，**而非**
位于 `VsCodeAdapter.swift` 自身所在的 `Adapters/Sources/` 下；source 枚举
`SourceName = .vscode`（`VsCodeAdapter.swift:4`）。TS 通过
`src/core/bootstrap.ts:63`（`new VsCodeAdapter()`）注册。

**时间戳辅助：** `creationDate`/`timestamp` 是 epoch **毫秒**，
通过 `isoFromMilliseconds`（UTC，带小数秒）转换。Parity 确认
`1771392005000` → `"2026-02-18T05:20:05.000Z"`。

**Swift/TS parity：** 在所有可观察输出（ids、计数、时间戳、
cwd、提取顺序）上完全一致，已对照
`tests/fixtures/adapter-parity/vscode/success.expected.json` 确认。产品解析器
与参考解析器之间无漂移。

---

## 15. 谱系、陷阱、版本漂移与边界情况

### 共享格式谱系（同源工具）

VS Code 是一个庞大家族的根：所有源自 Code 的编辑器都 fork 了相同的
`User/workspaceStorage/<id>/` 布局，但在聊天持久化上各有分化。

| Tool | Root | Chat storage tech | Engram reads | Same as VS Code? |
|---|---|---|---|---|
| **VS Code (Copilot/Gemini chat)** | `…/Code/User/workspaceStorage` | 每会话 `chatSessions/*.jsonl`（`kind:0`+`kind:1/2/3` mutation log） | replay `.jsonl` mutation log | **baseline** |
| **VS Code Insiders** | `…/Code - Insiders/User/workspaceStorage` | 相同 `.jsonl` 格式 | 未覆盖——只扫描稳定版 `Code` 路径 | 格式相同，**未覆盖**；2026-07-01 复查没有发现本机 Insiders `workspaceStorage` 目录，因此当前没有本机 chat 文件被漏扫 |
| **VSCodium** | `…/VSCodium/User/workspaceStorage` | 将匹配 VS Code `.jsonl` | 未覆盖（无适配器、无路径） | 格式相同，**未覆盖** |
| **Cursor** | `…/Cursor/User/globalStorage/state.vscdb` | **SQLite `cursorDiskKV`**，键 `composerData:<id>` + `bubbleId:<id>:%` | SQLite，而非 jsonl | **已分化** ——同源，不同持久化（`CursorAdapter.swift`；`cursor.ts`） |
| **Windsurf** | `~/.codeium/windsurf/...`（+ `~/.engram/cache/windsurf`） | 自有缓存（gRPC live-sync 已禁用） | cache，而非 vscdb | 已分化 |

**独立的 `copilot/` 谱系——不要混淆：** `tests/fixtures/copilot/` 是
**GitHub Copilot CLI**（`~/.copilot/session-state`、`workspace.yaml` +
带 `type:"session.start"|"user.message"|"assistant.message"` 记录的
`events.jsonl`）——一个不同的产品，使用不同的适配器。此处的 "Copilot Chat"
是编辑器*内部*的 Copilot 扩展，持久化在 VS Code 的
`chatSessions/*.jsonl` 中。

### 陷阱与边界情况

1. **多行追加日志会被 replay。** Live `.jsonl` 文件为 1..N 行
   （`kind:0` 快照 + `kind:1/2/3` mutations）。两个适配器都会 replay 初始快照后的有效 mutations。
   已 live 验证：`cea0313a…jsonl` 有 2 行（`kind:0`、`kind:1`）。
2. **空会话是 live 常态。** 全部 5 个 live 会话都有 `requests: []`。
   当 `requests` 为空或 `creationDate` 缺失时，Swift 返回
   `.failure(.malformedJSON)`，TS 返回 `null`（`:41-44` / `:80`）。本机上的
   净效果：尽管有 5 个文件，**索引到 0 个 VS Code 会话**。
3. **`k` 是数组。** `kind:1` 补丁 keypath 是 JSON 数组（`["inputState"]`），
   不是字符串。（相对于 DIM 报告已更正。）
4. **`state.vscdb` schema 是 `UNIQUE ON CONFLICT REPLACE`，不是 `PRIMARY KEY`。**
   （相对于 DIM 报告已更正。）
5. **Legacy `workspace` 键未处理。** Live `3011e0800a82af49da1596d7bbbf8a16/`
   使用 `{"workspace": "file://…/Code/Workspaces/<id>/workspace.json"}`。两个
   适配器只在 `folder`/`configuration` 上分支（Swift `:163-171`；TS
   `:134-139`），因此这样的 workspace 解析得 `cwd = ""`。该目录今日没有
   `chatSessions/`，所以影响是潜伏的。
6. **后端身份坍缩为 `vscode`。** Copilot、Gemini-for-VS-Code 以及任何
   其他聊天扩展都写入相同的 `chatSessions/*.jsonl`；
   `responderUsername`（区分符）被丢弃。来源信息丢失。
7. **仅 `version:3`，无版本门控。** Live + fixtures 均为 `version 3`；该
   字段已类型化但从不验证/分支。未来若出现具有不同
   `requests`/`response` 形状的 `version:4`，会静默误解析而非报错。
8. **仅首个 `markdownContent` 块。** 每个轮次只捕获首个 markdown 块；
   多块回答（或 tool 调用 + 摘要）会丢失首块之后的所有内容。
9. **仅含 tool/progress 的轮次消失。** 响应全部为
   `toolUse`/`progressTask` 的轮次不产出助手消息且被从计数中排除
   ——消息计数会低估真实的交互量。
10. **cwd 可能为空。** Remote（`vscode-remote://`、`vsls://`）或格式错误的
    `file://` URI 解码为 `""`；没有 `folders[0]` 的多根同样为 `""`。
11. **`sizeBytes` 统计 log 字节，而非 final-state payload 字节。** 报告的大小是整个 `.jsonl`，包含 mutation-log 行。
12. **每轮两个时间戳坍缩。** 一个 `request` 的 user 和 assistant 消息
    共享单一的轮次 `timestamp`（parity golden：req-1 两条
    消息都 = `…05.000Z`），因此轮次内排序无法按时间解析。
13. **单轮次聊天抑制 `endTime`。** 当最后 `timestamp == creationDate` 时，
    `endTime` 按设计为 `nil`/`undefined`（`:60-62`）。
14. **Swift/TS parity 完全一致。** 产品解析器与参考解析器之间无漂移。

### 待办 / 未验证

- **已填充 request/response 复杂负载。** 所有 live 会话均为空，所以
  `markdownContent` 之外的响应部分 kind（`toolInvocationSerialized`、
  `progressTaskSerialized`、`textEditGroup`、`thinking`、…）以及 tool/progress
  负载的确切嵌套，是依据 VS Code 源码 + 适配器注释记录的，**未**在本地采样。
  需在有活跃 Copilot Chat 使用的机器上重新采样，以验证真实
  `toolInvocationSerialized` 负载形状（`toolCallId`/`resultDetails` 及任何漂移）。
  `modelId` 和若干 usage-like 字段已不再未知：当前官方 schema 已包含它们，
  但 Engram 会忽略它们。
- **更复杂的 mutation payload。** 当前适配器会 replay `kind:1/2/3`，且 focused
  tests 已覆盖通过 `kind:2` 追加 request。本机 live 数据只有一个 `kind:1`
  metadata patch，没有已填充 request mutation；复杂 request/response mutation 仍需在有活跃 VS Code chat 使用的机器上重新采样。
- **`version:4`+ 漂移。** 本地只观察到 `version 3`，且当前官方
  `storageSchema` 仍发出 `version:3`；未来 schema 漂移仍是解析风险。
- **来源拆分。** Engram 是否打算（通过 `responderUsername`）将 Copilot 与
  Gemini-in-VS-Code 拆分为子来源，是一个设计
  问题，无法从代码中解决。

### Official source confirmation (2026-07-01)

- **官方已确认:** `ChatSessionStore` 将索引存于 `chat.ChatSessionStore.index`，
  常规 workspace 使用 `workspaceStorageHome/<workspaceId>/chatSessions`，空窗口使用
  profile 下的 `emptyWindowChatSessions` 根目录。
- **官方已确认:** 当前存储在 `chat.useLogSessionStorage !== false` 时默认写
  `.jsonl` append log，并保留 flat `.json` fallback。读取时优先读 `.jsonl` log，
  再回退到 flat JSON 文件。
- **官方已确认:** `ObjectMutationLog` entry 为 `kind:0` initial、`kind:1` set、
  `kind:2` push/splice、`kind:3` delete。任何 mutation entry 若出现在 initial
  entry 之前，都会抛出 `Log file is missing an initial entry`。
- **官方已确认:** `ChatSessionOperationLog.storageSchema` 发出 `version:3`、
  `creationDate`、`initialLocation`、`inputState`、`responderUsername`、`sessionId`、
  `requests`、`hasPendingEdits`、`repoData`、`pendingRequests`、`workingDirectory`。
  每个 request 的 schema 包含 `agent`、`modelId`、`variableData`、`response`、
  `result`、`followups`、`modelState`、`completionTokens`、`promptTokens`、
  `outputBuffer`、`promptTokenDetails`、`copilotCredits`；Engram 当前适配器仍丢弃这些
  更丰富的 model/usage 字段，只发出上文记录的 user/assistant 文本对。

---

## 16. 附录：真实匿名样本

### A. 空桩会话 —— `chatSessions/<uuid>.jsonl` 第 0 行（live，`version: 3`）

```json
{"kind":0,"v":{"version":3,"creationDate":1771392503565,"initialLocation":"panel","responderUsername":"","sessionId":"4aa52579-6e03-4031-915e-a6ed65da1d50","hasPendingEdits":false,"requests":[],"pendingRequests":[],"inputState":{"attachments":[],"mode":{"id":"agent","kind":"agent"},"inputText":"","selections":[{"startLineNumber":1,"startColumn":1,"endLineNumber":1,"endColumn":1,"selectionStartLineNumber":1,"selectionStartColumn":1,"positionLineNumber":1,"positionColumn":1}],"contrib":{"chatDynamicVariableModel":[]}}}}
```

### B. `kind:1` 补丁行（live，`cea0313a…jsonl` 的第二行）

```json
{"kind":1,"k":["inputState"],"v":{"attachments":[],"mode":{"id":"agent","kind":"agent"},"inputText":"","selections":[{"startLineNumber":1,"startColumn":1,"endLineNumber":1,"endColumn":1,"selectionStartLineNumber":1,"selectionStartColumn":1,"positionLineNumber":1,"positionColumn":1}],"contrib":{"chatDynamicVariableModel":[]}}}
```

### C. 含 2 轮次的已填充会话 —— `chatSessions/<uuid>.jsonl` 第 0 行（fixture，已匿名化）

```json
{"kind":0,"v":{"version":3,"sessionId":"sess-001","creationDate":1771392000000,"requests":[
  {"requestId":"req-1",
   "message":{"text":"<user prompt text>","parts":[{"kind":"text","value":"<user prompt text>"}]},
   "response":[{"value":{"kind":"markdownContent","content":{"value":"<assistant markdown>"}}}],
   "timestamp":1771392005000},
  {"requestId":"req-2",
   "message":{"text":"<user prompt 2>","parts":[{"kind":"text","value":"<user prompt 2>"}]},
   "response":[{"value":{"kind":"markdownContent","content":{"value":"<assistant markdown 2>"}}}],
   "timestamp":1771392015000}
]}}
```

### D. `workspace.json` 变体（live，已匿名化）

```json
{"folder":"file:///Users/<user>/<proj>"}
```
```json
{"workspace":"file:///Users/<user>/Library/Application%20Support/Code/Workspaces/1616927850246/workspace.json"}
```

### E. `state.vscdb` —— `chat.ChatSessionStore.index` 值（live，已匿名化）

```json
{
  "version": 1,
  "entries": {
    "cea0313a-2e97-477f-83aa-850a5f9faad1": {
      "sessionId": "cea0313a-2e97-477f-83aa-850a5f9faad1",
      "title": "<REDACTED>",
      "lastMessageDate": 1772112775137,
      "timing": { "created": 1772112775137 },
      "initialLocation": "panel",
      "hasPendingEdits": false,
      "isEmpty": true,
      "isExternal": false,
      "lastResponseState": 1
    }
  }
}
```

### F. `state.vscdb` schema（live）

```sql
CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);
```

### G. Engram parity golden —— 2 轮次 fixture 的 `sessionInfo` 输出

```json
{
  "id": "sess-001",
  "source": "vscode",
  "startTime": "2026-02-18T05:20:00.000Z",
  "endTime": "2026-02-18T05:20:15.000Z",
  "cwd": "/Users/test/my-project",
  "messageCount": 4,
  "userMessageCount": 2,
  "assistantMessageCount": 2,
  "toolMessageCount": 0,
  "systemMessageCount": 0,
  "summary": "<first user text, ≤200 chars>",
  "sizeBytes": 779
}
```

## References (official sources)

于 2026-07-01 对照 `microsoft/vscode` `main` 验证:

- [chatSessionStore.ts](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/contrib/chat/common/model/chatSessionStore.ts) — storage roots、`chat.ChatSessionStore.index`、`.jsonl` vs `.json` storage、read/write flow。
- [chatSessionOperationLog.ts](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/contrib/chat/common/model/chatSessionOperationLog.ts) — `storageSchema`、request schema、current `version:3`、model and usage-like fields。
- [objectMutationLog.ts](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/contrib/chat/common/model/objectMutationLog.ts) — append-log entry kinds、initial-entry requirement、diff/append behavior。
