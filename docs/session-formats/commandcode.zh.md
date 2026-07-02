# CommandCode 会话格式

> 本文档为英文权威版 commandcode.md 的中文阅读副本;若有出入以英文版为准。

Last researched: 2026-07-02 (Engram provider audit recheck; npm latest checked 0.40.17)

> **证据基础。** 本文档基于两个事实来源汇编而成,经交叉核对,冲突时以真实数据为准:
> 1. **磁盘上的实时存储** `~/.commandcode/` —— **14 个项目目录**、**39 个会话 `.jsonl` 文件**(不含检查点)、**27 个 `.checkpoints.jsonl` 文件**、**23 个 `.meta.json` 文件**、**1,541 条消息记录**(全部为 `metadata.version: 2`),外加 CLI 全局文件(`config.json`、`auth.json`、`history.jsonl`、`updates.json`、`trusted-hooks.json`、`plans/`、`file-history/`)。
> 2. **仓库 fixture** `/Users/bing/-Code-/engram/tests/fixtures/commandcode/sample.jsonl`(1 个文件,3 条记录)。
> 3. **Engram 适配器**(已编码的知识):Swift 产品解析器 `macos/Shared/EngramCore/Adapters/Sources/CommandCodeAdapter.swift`;TS 参考解析器 `src/adapters/commandcode.ts`。
>
> 下文中的每一项实时 schema/字段断言都已在 2026-07-02 针对实时存储重新核验(顶层键集、metadata 键集、内容块类型计数、工具输入/输出类型、角色分布)。官方源码说明最初来自 npm bundle 深度核验,且已在 2026-07-02 重新确认最新 npm 版本为 `command-code@0.40.17`。实时数据、fixture 与适配器之间的差异在文中就地标注。

## Current Local Audit

2026-07-02 native `~/.commandcode/projects` smoke 列出并解析 14 个项目目录下
39/39 个 session JSONL 文件,排除了 27 个 `.checkpoints.jsonl` sidecar 和
23 个 `.meta.json` 文件。原始扫描发现 1,541 条 transcript 记录、0 条畸形行、
92 条 `user`、1,016 条 `assistant` 和 433 条 `tool`;其中 1 条 user 记录是
Claude-style system injection,因此 adapter stream 为 1,540 条消息(91 user +
1,016 assistant + 433 tool),parser/stream count mismatch 为 0。当前 content-block
直方图仍为 `text` x857、`reasoning` x243、`tool-call` x705、`tool-result` x705
和 `image` x4;当前 tool-call input 为 703 object + 2 string + 0 `args`,全部
705 个 tool-result output 都是 object。

当前 `~/.engram/index.sqlite` 仍然 locator/index 闭合:39 个 `commandcode` 行、
39 个 `file_index_state` 行、全部 schema v1 `ok`,0 missing locator,0 DB-only
row;最新 `indexed_at` 仍是 `2026-07-01T04:54:19Z`。字段比较范围比旧的
count-only 表述更广:全部 39 行都保留了解码后的 `project` 快照,但当前 adapter
返回 `project: nil`;此前 3 个 append 后增长的 session row 仍然在 `end_time`、
`message_count`、`assistant_message_count`、`tool_message_count` 和 `size_bytes`
上 stale。需要重新索引才能刷新 39 个 project 快照和 3 个 count/end/size 快照。

---

## 1. 概述与 TL;DR

**CommandCode**(provider 字符串 `command-code`)是一个**多提供方的 CLI AI 编码 agent** —— agent 外壳是"提供方",而底层 LLM 是可配置的(实时 `config.json` 中携带 `deepseek/deepseek-v4-pro`;按会话的 `.meta.json` 文件携带 `Qwen/Qwen3.7-Max`、`deepseek/deepseek-v4-pro`)。Engram 将其视为名为 `commandcode` 的单一来源。2026-07-02 核验到的最新 npm 版本为 `0.40.17`。

**保存什么/在哪里/如何保存:**
- **什么:** 每个会话一份 JSONL 转录,每行一条 JSON 记录,每条记录对应一个消息回合(`user` / `assistant` / `tool`)。
- **哪里:** `~/.commandcode/projects/<projectSlug>/<sessionId>.jsonl`,每个工作目录(cwd)一个目录,每个会话一个以 UUID 命名的文件。
- **如何:** 行分隔 JSON(JSONL);在当前的 CommandCode(最新核验 v0.40.17)中,每次保存都是整文件原子重写(整个数组重新序列化、id 重新生成),而非追加 —— 见 §3。无滚动切分。按会话的边车文件(`.meta.json` 标题/模型、`.checkpoints.jsonl` 文件历史快照)以及独立的 `file-history/<sessionId>/` blob 存储保存 UX/恢复状态。

**心智模型:** CommandCode 在**磁盘布局层面是一个 Claude-Code 克隆**(`~/.<tool>/projects/<path-encoded-cwd>/<uuid>.jsonl` + 兄弟级 `.checkpoints.jsonl` + 完全相同的 Claude 风格系统注入标记),但在**内容块层面是 Vercel-AI-SDK 风格的方言**(`type: "tool-call"` 带 `toolName`+`input`、`type: "tool-result"` 带 `output`、`type: "reasoning"`)。参见 §15 的谱系部分。

**Engram 只读取** `projects/*/<sessionId>.jsonl`。会话 id 取自磁盘上的 `sessionId` 字段(对于文件中的第一个会话,它等于文件名主干),而非文件名本身。

### ASCII 布局 / 分层图

```
~/.commandcode/                          (CLI-global state — NONE read by Engram)
├── config.json        provider/model/reasoningEffort
├── auth.json          credentials (0600)
├── history.jsonl      cross-session prompt history {p,t}
├── updates.json       updater state
├── trusted-hooks.json hook trust
├── plans/*.md         saved plan-mode docs
├── file-history/<sessionId>/<hash>-<NN>@v<N>   versioned file backups (checkpoint restore)
└── projects/                            <-- Engram enumerates ONLY here
    └── <projectSlug>/                   one dir per cwd (path-encoded)
        ├── <sessionId>.jsonl            <== THE SESSION (Engram parses this)
        │     │
        │     └── record layer (1 line = 1 message)
        │           { id, sessionId, parentId, role, timestamp, gitBranch, metadata, content }
        │             └── content-block layer (content[] = typed blocks)
        │                   text | reasoning | tool-call | tool-result | image
        ├── <sessionId>.checkpoints.jsonl   file-history snapshots  (EXCLUDED by suffix)
        ├── <sessionId>.meta.json           {title, model?}          (NOT read)
        └── settings.json                   per-project UX state     (NOT read)
```

本文档自始至终都有两个不同的嵌套层级需要区分:
- **record layer(记录层)** —— 每行外层的 JSON 对象(消息信封)。
- **content-block layer(内容块层)** —— `content[]` 内部的类型化对象(消息负载)。

---

## 2. 磁盘布局与文件命名

### 根目录与目录结构

| 路径 | 类型 | Engram 是否读取? | 用途 |
|---|---|---|---|
| `~/.commandcode/` | dir | 否 | CLI 全局根目录 |
| `~/.commandcode/projects/` | dir | **是 —— 枚举** | 会话根目录;当且仅当此处为目录时 `detect()` 返回 true |
| `~/.commandcode/projects/<projectSlug>/` | dir | 是(枚举) | 每个工作目录(cwd)一个目录 |
| `<projectSlug>/<sessionId>.jsonl` | **JSONL transcript** | **是 —— 会话本体** | 每会话一份转录;当前写入器会整文件原子重写 |
| `<projectSlug>/<sessionId>.checkpoints.jsonl` | JSONL | **否 —— 显式排除** | 文件历史快照(撤销/恢复) |
| `<projectSlug>/<sessionId>.meta.json` | JSON | 否 | 会话 `title`(+ 可选 `model`) |
| `<projectSlug>/settings.json` | JSON | 否 | 按项目的 UX 标志(如 `tasteOnboarding`) |
| `~/.commandcode/file-history/<sessionId>/<hash>-<NN>@v<N>` | text blobs | 否 | 被检查点引用的带版本文件备份 |
| `~/.commandcode/plans/*.md` | markdown | 否 | 已保存的 plan-mode 文档 |
| `~/.commandcode/history.jsonl` | JSONL | 否 | 全局提示历史(`{p,t}` 记录) |
| `~/.commandcode/config.json` | JSON | 否 | 全局 `provider`、`model`、`reasoningEffort` |
| `~/.commandcode/auth.json` | JSON (0600) | 否 | API 凭据 |
| `~/.commandcode/updates.json`、`trusted-hooks.json` | JSON | 否 | 更新器 / hook 信任状态 |

### 命名文法

| 组成部分 | 文法 | 实时示例 | 说明 |
|---|---|---|---|
| 项目目录(`projectSlug`) | cwd 转小写,非字母数字字符 → `-`,字面 `-` → `--` | `users-bing-code-engram`(≈ `/Users/bing/Code/engram`) | 单向 slug;解码是**有损的**(见 §15 gotcha 3) |
| 会话 id | UUID v4 | `400d4036-a1e4-4a22-b24a-9ebc7db0871c` | 文件名主干;同时也是每条记录中的 `sessionId` 字段 |
| 转录文件 | `<uuid>.jsonl` | 同上 | 被适配器枚举 |
| 检查点文件 | `<uuid>.checkpoints.jsonl` | 同上 | 被适配器按后缀排除 |
| Meta 文件 | `<uuid>.meta.json` | 同上 | 不读取 |
| 文件历史 blob | `<contentHash>-<seq>@v<N>` | `a0aed1deec1d862c-53@v2` | `@vN` 每次编辑递增 |

**cwd 解码**(`decodeCwd`,Swift `:226-233` / `decodeCwdFromLocator`,TS `:183-190`):将 `--`→`\0`、`-`→`/`、`\0`→`-`。**仅在**没有记录携带 `cwd` 时作为回退使用。在实时数据中,记录上从不存在 `cwd`(0/1,541),因此解码出的 slug 永远是 cwd 来源 —— 而它是近似的,并非忠实的路径(例如 `users-bing-net-work-safeline` → `users/bing/net/work/safeline`,丢失了前导斜杠以及任何字面连字符)。没有任何实时项目目录包含 `--`,因此双连字符转义路径只在合成测试中被覆盖。

### 实时目录树示例(已脱敏)

```text
~/.commandcode/
├── config.json                 # {provider:"command-code", model:"deepseek/deepseek-v4-pro", ...}
├── auth.json                   # {apiKey, userId, userName, keyName, authenticatedAt} (0600)
├── history.jsonl               # lines of {"p":<prompt>,"t":<epoch-ms>}
├── updates.json
├── trusted-hooks.json
├── plans/
│   ├── <plan-name>.md
│   └── <plan-name>.md
├── file-history/
│   └── <sessionId>/                       # e.g. 400d4036-…-0871c/
│       ├── <hash>-53@v1                    # backup version 1 of one file
│       └── <hash>-53@v2                    # backup version 2 (monotonic @vN)
└── projects/
    ├── users-bing-code-engram/                                   # projectSlug
    │   ├── 400d4036-a1e4-4a22-b24a-9ebc7db0871c.jsonl            # ← THE SESSION
    │   ├── 400d4036-a1e4-4a22-b24a-9ebc7db0871c.checkpoints.jsonl # excluded
    │   ├── 400d4036-a1e4-4a22-b24a-9ebc7db0871c.meta.json         # {title, model?}
    │   └── settings.json                                          # per-project
    ├── users-bing-net-work-safeline/
    │   └── …
    └── private-var-folders-9f-…-t-polycli-ledger-contract-q1-ah-rw/   # temp-dir cwd session
        └── …
```

(实时记录:有一个项目目录根植于 macOS 临时目录 `/private/var/folders/.../T/` —— 证实临时目录会话会被捕获,并解码为 `private/var/...` 形式的 cwd。)

---

## 3. 文件生命周期与生成

- **存储技术:行分隔 JSON(JSONL)。** 每行一条记录;这是文件存储,不是数据库。(`JSONLAdapterSupport.readObjects` Swift `:38`;`readLines` TS `:156`。)
- **写入模型:整文件原子重写,而非追加。** 已订正(官方):当前 CommandCode(最新核验 v0.40.17)在每次保存时都会重新序列化内存中**整个**消息数组,写入 `<file>.<pid>.tmp`,再 rename 覆盖会话 `.jsonl`(整文件原子重写)。每次保存都会重新生成**所有**记录 `id`(全新 `crypto.randomUUID()`),并从 `this.lastMessageId` 重新计算 `parentId`,而 `lastMessageId` 初始为 `null` 且从不从被恢复的数据中播种 —— 因此记录 `id`/`parentId` 在多次保存间**不**稳定,且第一条记录的 `parentId` 为 `null`。`appendFile` 仅用于日志、hook 审计与全局 `history.jsonl` —— 从不用于会话转录。实时存储中大多数仅追加 + 单调 id + 首条非空 `parentId` 行为反映的是**更早的** CommandCode 版本;磁盘上的**结果**不变(每会话一个 JSONL 文件、相同的 8 键信封),因此下游解析不受影响。([source](https://registry.npmjs.org/command-code/-/command-code-0.40.17.tgz))
- **数据库 vs 文件:** **文件** —— 转录没有使用 SQLite、leveldb 或 gRPC 缓存。(与 Cursor/VS Code/Copilot/Cline 对比 —— 见 §12。)
- **每会话一文件,每 cwd 一目录:** 每个会话一个以 UUID 命名的 `.jsonl`;同一 cwd 的会话聚集在一个 `projectSlug` 目录下。写入器保证文件名主干始终等于该文件自身的 `sessionId`。
- **恢复 / 链表式续接:** 记录通过 `parentId` 链构成(链式 DAG),且**仅在文件内部**。实时存储中仍有 **38/39 个文件的第一条记录 `parentId` 非空且指向该文件中不存在的 id**,反映的是更早的追加式版本;1/39 文件现在首条 `parentId` 为 `null`,与当前源码和 fixture 一致。CommandCode **不**跨被恢复的文件串接 `parentId`。(见 §15,已解决。)
- **无滚动切分:** 文件不按大小或时间轮转;一个会话从头到尾就是一个文件(最大的实时转录约 462 KB / 473,116 字节)。
- **边车生命周期:** `.meta.json`(标题/模型)与 `.checkpoints.jsonl`(文件历史)随每个会话一并写出;随着会话期间文件被编辑,`file-history/<sessionId>/` 会累积带版本的 blob(`@v1, @v2, …`)。
- **磁盘上无归档层:** 没有单独的已归档/已压缩位置;旧会话只是继续留在 `projects/` 中。

---

## 4. 记录 / 行分类

CommandCode 由 JSONL 支撑(非数据库支撑),因此其分类是**记录/行类型**,而非 SQLite 表。

### 转录 `.jsonl` 记录(Engram 唯一解析的文件)

| 记录种类 | 判别符 | 计数(实时) | 用途 | Engram 处理 |
|---|---|---|---|---|
| user message | `role: "user"` | 92 | 人类提示,或注入的系统包装 | 计为 user,若匹配 `isSystemInjection` 则重分类为 system |
| assistant message | `role: "assistant"` | 1,016 | 模型回复(text / reasoning / tool-call) | 计为 assistant |
| tool message | `role: "tool"` | 433 | 工具执行结果 | 计为 tool |
| (任何其他 role) | — | 0 | — | **丢弃**(Swift `:53-55`,TS `:72-73`) |

磁盘上**没有 `system` 角色。** Engram 通过将其提取文本匹配 Claude 风格注入包装的 `user` 记录重分类来推导 `systemMessageCount`(`isSystemInjection`,Swift `:168-178` / TS `:230-242`)。

### 边车记录种类(Engram 不解析)

| 文件 | 记录种类 | 判别符 | 用途 |
|---|---|---|---|
| `.checkpoints.jsonl` | 文件历史快照 | `type: "file-history-snapshot"`(仅见此值,73/73) | 撤销/恢复锚点 → `file-history/` 中的备份 blob |
| `history.jsonl` | 全局提示条目 | `{p, t}` | 跨会话提示历史 |
| `.meta.json` | 会话元数据 | `{title, model?}`(单个对象,非 JSONL) | 人类标题 + 可选模型 |

---

## 5. 共享信封 / 元数据字段

每条转录记录都恰好有 **8 个顶层键** —— 在全部 1,541 条实时记录中验证为一致(`["content","gitBranch","id","metadata","parentId","role","sessionId","timestamp"]`)。该信封对三种角色完全相同。实时数据中**没有可选的顶层键**。

### 记录信封(外层 / 记录层)

| 字段 | 类型 | 含义 | 可选 | 示例(已脱敏) |
|---|---|---|---|---|
| `id` | string (UUID) | 每条消息的 id;下一条记录 `parentId` 的目标 | 否 | `"d6d46e72-aa15-4049-8c26-84c15207258c"` |
| `sessionId` | string (UUID) | 所属会话;第一个非空者作为 `SessionInfo.id` 的种子 | 否 | `"400d4036-a1e4-4a22-b24a-9ebc7db0871c"` |
| `parentId` | string \| null | 同一文件内前一条消息的 id(文件内链);tool 记录的 `parentId` = assistant 记录的 `id`。已订正(官方):在最新核验的 v0.40.17 中写入器从 `lastMessageId` 重新计算它(初始 `null`,从不从恢复中播种),因此第一条记录的 `parentId` 为 `null` ([source](https://registry.npmjs.org/command-code/-/command-code-0.40.17.tgz)) | 否 | 当前/fixture root: `null`;更早版本的实时存储: `"410a7034-…"`(非空) |
| `role` | enum `user`\|`assistant`\|`tool` | 消息作者(磁盘上无 `system` 角色) | 否 | `"assistant"` |
| `timestamp` | string (ISO-8601 UTC) | 记录的挂钟时间;文件内单调递增;在 `metadata.timestamp` 中重复(始终相等) | 否 | `"2026-05-25T01:56:44.064Z"` |
| `gitBranch` | string | 捕获时的 git 分支;不在仓库时为 `"-"` | 否 | `"main"` |
| `content` | array \| string | 消息负载(见 §6);1,521/1,541 为数组,20 条为裸字符串(仅 user) | 否 | `[ {type:"text",…} ]` |
| `metadata` | object | 每条记录的来源信封(见下) | 否 | `{source,timestamp,version,…}` |
| `cwd` | string | 工作目录 | **是 —— 在所有实时记录中缺失(0/1,541)**;在 fixture 中存在 | (live: never) |
| `model` | string | 模型 id | **是 —— 在所有实时记录中缺失(0/1,541)**;在 fixture 中存在(仅 assistant) | (live: never) |

> 适配器的时间戳解析器先读顶层 `timestamp`,再读 `metadata.timestamp`(Swift `:159-164` / TS `:175-181`)。模型解析器先读顶层 `model`,再读 `metadata.model`(Swift `:62-67` / TS `:76-79`)—— **这两条路径在实时 v2 数据中都不存在**,因此对实时 CommandCode 会话而言 `model` 解析为 `nil`。

### `metadata` 子对象

`metadata` 始终存在。观察到 6 种键集变体(实时);所有键的并集:

| 字段 | 类型 | 含义 | 可选(在 1,541 中的频次) | 示例 |
|---|---|---|---|---|
| `source` | string | 来源通道;常量 `"cli"` | 始终(1,541) | `"cli"` |
| `timestamp` | string (ISO) | 顶层 `timestamp` 的镜像(始终相等);适配器回退 | 始终(1,541) | `"2026-05-25T01:56:44.064Z"` |
| `version` | int | 记录 schema 版本;常量 `2` | 始终(1,541) | `2` |
| `messageId` | string (UUID) | 提供方 / UI 消息 id(该 schema 字段一路传递);检查点通过 `snapshot.messageId` 锚定到它。**始终不同于顶层 `id`**(73/73) | 可选(73) | `"685c1246-b555-4593-b068-4be3f4d72303"` |
| `entrypoint` | string | 调用模式;源码定义的**唯一**值是 `"print"`(常量 `Oh="print"`),仅由 `resolvePrintSession()` 在无头一次性 `--print`/`-p` 时赋值。交互式会话**不**写入 `entrypoint` 键。已订正(官方)([source](https://registry.npmjs.org/command-code/-/command-code-0.40.17.tgz)) | 可选(24) | `"print"` |
| `isAutomated` | bool | 机器生成 / 注入的回合;CLI 在自动化斜杠命令提示(`isAutomatedSlashCommandPrompt`)及类似非人类回合上设置它。已确认(官方)([source](https://registry.npmjs.org/command-code/-/command-code-0.40.17.tgz)) | 罕见(4) | `true` |
| `isMeta` | bool | meta 回合(`createMessageWithMeta`/`sanitizeMessage` 路径,如内容为空的 meta 回合)。已确认(官方)([source](https://registry.npmjs.org/command-code/-/command-code-0.40.17.tgz)) | 罕见(2) | `true` |

观察到的 metadata 键集频次(实时):
```
1443  ["source","timestamp","version"]
  70  ["messageId","source","timestamp","version"]
  24  ["entrypoint","source","timestamp","version"]
   2  ["isAutomated","isMeta","messageId","source","timestamp","version"]
   1  ["isAutomated","messageId","source","timestamp","version"]
   1  ["isAutomated","source","timestamp","version"]
```

> **schema 支持但未观察到的键。** 已订正(官方):完整的 v2 `metadata` zod schema 还允许实时存储从未携带的键:`model`、`duration`、`usage:{inputTokens, outputTokens, totalTokens, cacheReadTokens?, cacheWriteTokens?, estimatedCost?}`、`context:{sessionId?, threadId?, userId?}`、`highlight:bool`、`isSummary:bool` 以及 `hookContexts:record<string,{preToolUse?, postToolUse?}>`。它们都是可选的,只是在本机数据中未被填充 —— 未来携带它们的捕获属于预期 schema,而非漂移。([source](https://registry.npmjs.org/command-code/-/command-code-0.40.17.tgz))
`entrypoint:"print"` 记录成对出现:一条 `content` 为**裸字符串**(一次性提示)的 `user` 记录,后跟一条带 `["reasoning","text"]` 的 `assistant` 记录 —— 即无头一次性查询。**整个实时存储中不存在任何 content 为空数组的 user 记录(0/92 user 记录)。** 全部 12 条实时 `entrypoint:"print"` user 记录都携带裸字符串内容(长度:9×34 字节 + 3 条长内容:40,111 / 41,768 / 70,358 字节);这 12 条是 20 条字符串内容 user 记录的子集(12 条 `print` + 8 条无 `entrypoint`)。

---

## 6. 消息与内容 schema

`content` 是**内容块层**,嵌套在一条记录之下。它要么是**类型化块的数组**(1,521 条记录),要么是**裸字符串**(20 条记录,仅 user)。块由 `.type` 判别。

实时块类型计数与角色隔离:

```
assistant:text       785    assistant:reasoning  243    assistant:tool-call  705
tool:tool-result     705    user:text             72    user:image             4
```

块类型按角色隔离:`reasoning` 与 `tool-call` 仅 assistant;`tool-result` 仅 tool;`image` 仅 user;`text` 出现在 user 与 assistant 上。

| 块 `type` | 键 | 含义 | 计数 | Engram 处理 |
|---|---|---|---|---|
| `text` | `type`、`text` | 自然语言正文 | 857 | 逐字提取(Swift `:189-190` / TS `:198`) |
| `reasoning` | `type`、`text` | 模型思维链 | 243 | **丢弃** —— `extractContent` switch 中无对应分支(Swift `:188-201` default → nil / TS `:196-208`) |
| `tool-call` | `type`、`toolName`、`toolCallId`、`input` | 工具调用 | 705 | 在内容中渲染为 `` `<toolName>` ``;以 `NormalizedToolCall` 形式发出(名称 + 截断后的 input JSON) |
| `tool-result` | `type`、`toolName`、`toolCallId`、`output` | 工具输出(类型化包装) | 705 | `output` 折叠进内容(字符串逐字保留,否则 JSON 序列化并截断至 2000) |
| `image` | `type`、`image` | 内联 base64 data-URI 图像 | 4 | **丢弃** —— 两个适配器都无 `image` 分支 |

### 6a. `text` 块(user + assistant)
| 字段 | 类型 | 可选 | 含义 |
|---|---|---|---|
| `type` | `"text"` | req | 判别符 |
| `text` | string | req | 消息正文 |
```json
{ "type": "text", "text": "<PROSE REDACTED>" }
```

### 6b. `reasoning` 块(仅 assistant)—— 模型思考轨迹
| 字段 | 类型 | 可选 | 含义 |
|---|---|---|---|
| `type` | `"reasoning"` | req | 判别符 |
| `text` | string | req | 思维链文本(243 条实时记录中全部非空) |
```json
{ "type": "reasoning", "text": "<THINKING REDACTED>" }
```
**Engram 丢弃此块** —— `reasoning` 落入 `default`,从提取的摘要文本中被排除(不捕获任何思考)。见 §8。

### 6c. `tool-call` 块(仅 assistant)
| 字段 | 类型 | 可选 | 含义 | 示例 |
|---|---|---|---|---|
| `type` | `"tool-call"` | req | 判别符 | `"tool-call"` |
| `toolName` | string | req | 工具名(13 个不同值,见 §7) | `"shell_command"` |
| `toolCallId` | string | req | 与匹配 `tool-result` 的**关联键** | `"call_00_MAKdS9FclHpX38eDWrpj6245"` |
| `input` | object (703) \| string (2) | req | 工具参数;形状因工具而异 | `{ "command": "<CMD>" }` |
```json
{ "type": "tool-call", "toolName": "shell_command",
  "toolCallId": "call_00_MAKdS9FclHpX38eDWrpj6245",
  "input": { "command": "<CMD REDACTED>" } }
```

### 6d. `tool-result` 块(仅 tool 角色)
| 字段 | 类型 | 可选 | 含义 | 示例 |
|---|---|---|---|---|
| `type` | `"tool-result"` | req | 判别符 | `"tool-result"` |
| `toolName` | string | req | 工具名(镜像调用方) | `"shell_command"` |
| `toolCallId` | string | req | **关联键** = 发起 `tool-call` 的 `toolCallId` | `"call_00_MAKdS9FclHpX38eDWrpj6245"` |
| `output` | object | req | 类型化结果包装 `{type, value}`(实时:始终是对象,从不是裸字符串) | `{ "type": "text", "value": "…" }` |

嵌套的 `output` 子字段:
| 子字段 | 类型 | 含义 | 示例 |
|---|---|---|---|
| `output.type` | enum | `"text"`(703) \| `"error-text"`(2) | `"text"` |
| `output.value` | string | 结果/错误负载 | `"<TOOL OUTPUT REDACTED>"` |
```json
{ "type": "tool-result", "toolName": "shell_command",
  "toolCallId": "call_00_MAKdS9FclHpX38eDWrpj6245",
  "output": { "type": "text", "value": "<OUTPUT REDACTED>" } }
```
由于实时 `output` 始终是 `{type,value}` 对象(从不是裸字符串),Engram 的字符串输出路径在生产中从不运行;它将整个包装做 JSON 序列化,截断至 2000B(Swift `:194-198` / TS `:200-206`)。

### 6e. `image` 块(仅 user)
| 字段 | 类型 | 可选 | 含义 | 示例 |
|---|---|---|---|---|
| `type` | `"image"` | req | 判别符 | `"image"` |
| `image` | string | req | base64 **data-URI**(例如 `data:image/jpeg;base64,…`,约 114 KB) | `"data:image/jpeg;base64,/9j/2wB…"` |
```json
{ "type": "image", "image": "data:image/jpeg;base64,<BASE64 REDACTED>" }
```
**Engram 丢弃此块** —— 提取 switch 中无 `image` 分支(无占位符)。

### 6f. 裸字符串内容(仅 user,20 条记录)
当 `content` 是普通字符串而非数组时。长度范围 7–70,358 字节;长的那些是注入的系统包装(AGENTS.md / `<INSTRUCTIONS>` / 本地命令块)。两个适配器的 `isSystemInjection` 都会将这类 user 回合重分类进 `systemMessageCount`(磁盘上的 `role` 仍为 `"user"`;磁盘上**没有** `system` 角色)。两个适配器都逐字处理裸字符串内容(Swift `:181-183` / TS `:193-194`)。

### 常见 assistant 块排序(实时,头部)
`text`(553);`text,tool-call`(92);`tool-call`(89);`reasoning,tool-call`(59);`reasoning,text,tool-call`(22);`reasoning,text`(21)。存在时,`reasoning` 位于块数组之首。

### 完整 assistant 记录示例(记录层 + 内容块层;键逐字保留,文本剥除)
```json
{
  "id": "679dd8d8-...",
  "sessionId": "400d4036-a1e4-4a22-b24a-9ebc7db0871c",
  "parentId": "d6d46e72-aa15-4049-8c26-84c15207258c",
  "role": "assistant",
  "gitBranch": "main",
  "content": [
    { "type": "reasoning", "text": "<STRIPPED>" },
    { "type": "text", "text": "<STRIPPED>" },
    { "type": "tool-call", "toolName": "<tool>", "toolCallId": "call_00_...", "input": { } }
  ],
  "metadata": { "source": "cli", "version": 2, "timestamp": "2026-05-25T01:56:51.228Z" },
  "timestamp": "2026-05-25T01:56:51.228Z"
}
```

---

## 7. 工具调用与结果

**关联通过 `toolCallId`**(而非通过 `parentId` 或数组位置)。已验证:在一个会话内,`tool-call` id 的集合与 `tool-result` id 的集合完全相等(1:1)。结构上,一条 `assistant` 记录发出 N 个 `tool-call` 块;紧随其后的 `tool` 记录(其 `parentId` = 该 assistant 的 `id`)按顺序发出 N 个匹配的 `tool-result` 块。

| 关联元素 | 字段 | 说明 |
|---|---|---|
| 调用 id | `tool-call.toolCallId` | 例如 `call_00_MAKdS9FclHpX38eDWrpj6245` |
| 结果 id | `tool-result.toolCallId` | 与发起调用的 id 相同 |
| 工具名(两侧) | `toolName` | 在调用与结果上镜像 |
| 错误 | `tool-result.output.type == "error-text"` | 实时 2/705;否则为 `"text"` |

**不同 `toolName` 值 + 计数(实时):** `shell_command` 216、`read_file` 154、`explore` 127、`grep` 65、`todo_write` 33、`read_directory` 29、`glob` 26、`edit_file` 25、`write_file` 13、`read_multiple_files` 9、`enter_plan_mode` 6、`exit_plan_mode` 1、`think` 1。

**各工具 `input` 形状(头部):** `shell_command`→`{command[,timeout]}`;`read_file`→`{absolutePath[,limit,offset]}`;`explore`→`{messages}`;`grep`→`{path,pattern}` 或 `{directory,pattern}`(2 个字符串输入的案例都是 `grep`);`edit_file`→`{filePath,newValue,oldValue}`;`write_file`→`{content,filePath}`;`todo_write`→`{todos}`;`think`→`{thought}`;`glob`→`{directory,include,pattern}`。

**Engram 处理。** 两个适配器实际上都不做调用↔结果的连接。Swift `toolCalls`(`:210-223`) / TS `toolCalls`(`:215-230`)只把 `tool-call` 块提取为 `NormalizedToolCall{name, input(JSON, 截断 500B), output: nil}` —— `output` 始终为 nil。结果文本仅通过 `extractContent` 折叠进扁平的内容摘要。当前 Swift 与 TS 都接受 `input ?? args`;实时数据没有 `args` 块,`input` 形态为 object 703/705、string 2/705,因此对象 JSON 序列化路径是生产路径。

---

## 8. 推理 / 思考

**磁盘上存储:是。** `reasoning` 块(实时 243 条,仅 assistant)以纯文本携带模型的思维链(`{type:"reasoning", text:"…"}`),存在时位于块数组之首。

**Engram 是否捕获:否。** 两个适配器的 `extractContent` switch 都不匹配 `reasoning` —— 它落入 `default` 并被静默地从提取的摘要/转录文本中丢弃。CommandCode 在 Engram 搜索或转录中不会浮现任何思考内容。

---

## 9. Token 用量与成本

**在观察到的数据中缺失;schema 支持它,但未被填充。** 用户的实时存储不携带任何用量数据(已验证:0/1,541 条记录携带 `usage`;路径扫描中未发现 `usage`/token/cost 字段),因此 Engram 无法读取。两个适配器都反映这一点:Swift `message()` 设 `usage: nil`(`:155`);TS 完全省略 usage。

已订正(官方):**格式本身**确实定义了 usage。v2 `metadata` zod schema 包含可选的 `usage:{inputTokens, outputTokens, totalTokens, cacheReadTokens?, cacheWriteTokens?, estimatedCost?}` 对象以及 `metadata.duration` 字段,所以 token/成本**能够**被 CommandCode 持久化 —— 只是在捕获的会话中缺失/未填充(很可能是更早的 CLI 版本,或某个不持久化它的构建)。先前"CommandCode 文件中任何位置都没有 usage 字段"的说法对观察到的数据成立,但作为格式断言则言过其实。([source](https://registry.npmjs.org/command-code/-/command-code-0.40.17.tgz))

---

## 10. 子 agent / 父子关系 / 派发

**在适配器层 N/A。** CommandCode 没有 Gemini 风格的 `.engram.json` 边车,没有 Codex 风格的 `originator`,也没有 Claude-Code 风格的 `/subagents/` 路径关联。适配器硬编码 `agentRole: nil`、`originator: nil`、`parentSessionId: nil`、`suggestedParentId: nil`(Swift `:112-119`)。

记录层级的 `parentId` 字段将消息**在单个会话文件内**串成链式 DAG —— 但 Engram 不对其建模(转录被扁平化为线性顺序)。它与 Engram 的会话级父/子分组无关。已确认(官方):CommandCode 实际使用的跨会话链接是 `.meta.json#parentSessionId`(由 `--fork-session` 为 fork 的会话写入),而**非**记录层级的 `parentId` —— 两个适配器都不读取该边车,因此 Engram 的 `parentSessionId` 保持为 nil。CommandCode 的任何 agent 会话分组都会由索引器的 Layer-2 启发式(时间/cwd 评分)在下游应用,而非由本适配器。([source](https://registry.npmjs.org/command-code/-/command-code-0.40.17.tgz))

(注:`metadata.entrypoint:"print"` 以及 `metadata.isAutomated`/`isMeta` 标记无头/自动化回合,原则上可以喂给派发分类,但适配器忽略它们 —— 见 §15 已解决问题。)

---

## 11. 摘要 / 压缩

**磁盘上 N/A。** 转录中没有压缩/摘要记录类型,也没有单独的已压缩/已归档存储。最接近的产物是 `.meta.json#title` —— 一个经过策划的人类可读会话标题 —— 但它是边车,而非转录内摘要,且 Engram 不读取它(见 §5/§14)。

Engram 合成自己的 `summary`,取**第一条非系统 user 消息文本,截断至 200 字符**(Swift `:108` / TS `:114`)。由于真实的 `.meta.json#title` 未被使用,这实际上充当了 Engram 的标题替代物。

---

## 12. SQLite / 数据库内部

**对 CommandCode 而言 N/A。** CommandCode 是 JSONL 文件存储,不是数据库支撑的工具。转录没有 SQLite `.vscdb`、leveldb 或 gRPC 缓存。(对比:Cursor / VS Code / Copilot / Cline 使用 SQLite/leveldb —— 见那些文档。)

---

## 13. 辅助文件

全部存在于磁盘;**Engram 都不解析。**

### `<sessionId>.meta.json`(按会话)
已订正(官方):该边车并不限于 `{title, model?}`。`saveSessionMeta` 合并任意键;`saveSessionTitle` 写 `{title}`;重命名设置 `userRenamed`;fork 路径(`copyForkSessionFiles`,由 `--fork-session` 触发)写入额外的键。完整可能 schema 见下 ([source](https://registry.npmjs.org/command-code/-/command-code-0.40.17.tgz))。
| 字段 | 类型 | 可选 | 含义 | 示例 |
|---|---|---|---|---|
| `title` | string | req(22/23 populated) | 人类可读会话标题(自动生成的摘要) | `"Review recent commits with sub-agents"` |
| `model` | string | optional(3/23) | 所用模型;**唯一的按会话模型记录** | `"deepseek/deepseek-v4-pro"`、`"Qwen/Qwen3.7-Max"` |
| `userRenamed` | bool | optional(schema;本机未观察到) | 用户手动重命名会话时设置 | `true` |
| `parentSessionId` | string | optional(仅 fork) | **CommandCode 实际使用的跨会话(fork)链接** —— 区别于记录层级的 `parentId`;与 Engram 当前为 nil 的 `parentSessionId` 映射相关 | `"<uuid>"` |
| `forkedAt` | string (ISO) | optional(仅 fork) | fork 时间戳 | `"2026-05-25T01:56:44.064Z"` |
| `branchPoint` | (varies) | optional(仅 fork) | fork 分支点 | — |

### `<sessionId>.checkpoints.jsonl`(按会话,文件恢复快照)
顶层记录(始终 4 个键):`["isSnapshotUpdate","messageId","snapshot","type"]`。
| 字段 | 类型 | 含义 | 示例 |
|---|---|---|---|
| `type` | string | 常量 `"file-history-snapshot"`(73/73) | `"file-history-snapshot"` |
| `isSnapshotUpdate` | bool | 完整快照 vs 增量更新 | `false` |
| `messageId` | string (UUID) | 此快照锚定的消息 | `"f7984133-…"` |
| `snapshot` | object | `{messageId, timestamp, trackedFileBackups}` | — |

`snapshot.trackedFileBackups` = 文件路径 → 备份描述符 的映射(无编辑时为空 `{}`)。已确认(官方)对照源码 zod schema:检查点记录为 `{type: literal("file-history-snapshot"), messageId: uuid, snapshot: {messageId: uuid, trackedFileBackups: record(string, BACKUP), timestamp: string.datetime()}, isSnapshotUpdate: boolean}`,而每文件的 `BACKUP` 描述符为 `{backupFileName: string.nullable(), version: number.int().positive(), backupTime: string.datetime()}` ([source](https://registry.npmjs.org/command-code/-/command-code-0.40.17.tgz)):
| 子字段 | 类型 | 含义 |
|---|---|---|
| `backupFileName` | string \| null | `~/.commandcode/file-history/<sessionId>/` 下备份 blob 的名称。已订正(官方):schema 将其类型化为 `string.nullable()`(可为 `null`),而非纯字符串 |
| `backupTime` | string (ISO datetime) | 备份采集时间 —— 已确认(官方):类型化为 `string.datetime()`,故按 schema **不可能是数字**(68/68 非空条目;未观察到 `number`) |
| `version` | number | 备份版本 —— 已确认(官方):始终为正整数(`number.int().positive()`,68/68) |

这些为撤销/恢复提供支持;被备份的文件内容存放于 `file-history/<sessionId>/<hash>@vN`。Engram 通过 `.checkpoints.jsonl` 后缀过滤排除它们(Swift `:28` / TS `:44`)。

### `settings.json`(按项目)
按项目的 UI/引导状态(如 `tasteOnboarding`)。从不读取。

### CLI 全局 `~/.commandcode/config.json`
键(实时):`provider`(`"command-code"`)、`model`(如 `"deepseek/deepseek-v4-pro"`)、`installed`(bool)、`firstMessageSent`(bool)、`reasoningEffort`(映射 `{"<model>": "high"}`)。

### CLI 全局 `~/.commandcode/history.jsonl`
跨会话提示历史;每行 `{ "p": <prompt string>, "t": <epoch-ms number> }`。

### CLI 全局 `~/.commandcode/auth.json`(0600,机密)
仅键(不读取值):`apiKey`、`authenticatedAt`、`keyName`、`userId`、`userName`。

### CLI 全局 `~/.commandcode/{updates.json, trusted-hooks.json}` 以及 `plans/*.md`、`file-history/`
更新器状态、hook 信任状态、已保存的 plan-mode markdown,以及带版本的文件备份 blob。都不读取。

---

## 14. Engram 映射

输出结构体:`NormalizedSessionInfo`(Swift) / `SessionInfo`(TS)。两个适配器各遍历记录一次,只计 `role ∈ {user, assistant, tool}`。

**身份与注册:**

| 概念 | 值 | Swift 证据 | TS 证据 |
|---|---|---|---|
| 来源 id(enum) | `commandcode` | `Adapters/SessionAdapter.swift:15`(`case commandcode`);亦见 `EngramCoreWrite/ProjectMove/Sources.swift:45` | `src/adapters/commandcode.ts:17`;`src/adapters/types.ts:15` |
| 磁盘根目录 | `~/.commandcode/projects` | `CommandCodeAdapter.swift:9-11` | `commandcode.ts:21-22` |
| 适配器类 | `CommandCodeAdapter` | `CommandCodeAdapter.swift:3` | `commandcode.ts:16` |
| 工厂注册 | 注册两次 | `SessionAdapterFactory.swift:21,66`;app 路径 `Engram/Core/MessageParser.swift:130` | (TS 在工厂中注册) |
| `detect()` | 当且仅当 projects 目录存在时为 true | `CommandCodeAdapter.swift:18-20` | `commandcode.ts:25-32` |
| 枚举 | 直接 project 目录 → `*.jsonl` 减去 `*.checkpoints.jsonl`;Swift 排序,TS 惰性 | `CommandCodeAdapter.swift:22-34` | `commandcode.ts:34-52` |

**字段映射(源字段/记录 → Engram Session 字段 → 适配器 file:line):**

| Engram 字段 | 来源 | Swift:line | TS:line | 实时数据行为 / 注意点 |
|---|---|---|---|---|
| **id** | 第一条记录的 `sessionId` | `:56-58`、`:96` | `:74`、`:103` | UUID == 文件名;若无记录携带 `sessionId` 则失败(`malformedJSON`/null)(Swift `:93` / TS `:95`) |
| **source** | 常量 `.commandcode` | `:97` | `:104` | — |
| **startTime** | 第一条带时间戳的记录 | `:68-69`、`:98` | `:80-81`、`:104-105` | 顶层 `timestamp` 在实时数据中 100% 存在 → 可靠。**TS 在无时间戳时加入 mtime 回退(`:99-101`);Swift 不会** → 在无时间戳文件上产生差异(Swift 留 `startTime=""`) |
| **endTime** | 最后一条记录的时间戳,若 == start 则为 nil | `:70`、`:99` | `:82`、`:106` | 单消息会话为 nil |
| **cwd** | 第一条记录的 `cwd`,否则**目录名解码** | `:59-61`、`:100`,解码 `:226-233` | `:75`、`:107`,解码 `:183-190` | **实时 `cwd` 始终缺失 → 永远命中 `decodeCwd`**(有损,见 §15 gotcha 3) |
| **project** | — | `:101`(`nil`) | (省略) | 硬编码 nil |
| **model** | 第一条记录 `model`,否则 `metadata.model` | `:62-67`、`:102` | `:76-79`、`:105` | **实时 `model` 在 JSONL 中始终缺失 → 真实会话的 `model` 永远为 nil。** 真实模型存在于 `.meta.json`(从不读取) |
| **messageCount** | user+assistant+tool | `:103` | `:109` | 排除被系统重分类的记录 |
| **userMessageCount** | `user` 记录减去系统注入 | `:73-83`、`:104` | `:83-90`、`:110` | 注入的 Claude 风格包装被重分类为 system(`:168-178` / `:230-242`) |
| **assistantMessageCount** | `assistant` 记录 | `:84-85`、`:105` | `:91`、`:111` | — |
| **toolMessageCount** | `tool` 记录 | `:86-87`、`:106` | `:92`、`:112` | — |
| **systemMessageCount** | 匹配 `isSystemInjection` 的 user 记录 | `:78-79`、`:107` | `:85-86`、`:113` | 基于文本前缀/标记的启发式 |
| **summary** | 第一条非系统 user 文本,`prefix(200)` | `:82`、`:108` | `:89`、`:114` | Engram 的有效"标题"替代物(真实 `.meta.json#title` 未用) |
| **filePath** | locator(绝对路径) | `:109` | `:115` | — |
| **sizeBytes** | 文件大小 | `:110` | `:116` | 按文件字节 |
| **indexedAt / agentRole / originator / origin / summaryMessageCount / tier / qualityScore / parentSessionId / suggestedParentId** | — | `:111-119`(全部 nil) | (TS 结构体中缺失) | 由索引器在下游设置,而非适配器 |
| **usage / tokens / cost** | — | `usage: nil` `:155` | (省略) | 不在来源中 —— 实时数据不存在 |

**逐消息流映射**(`streamMessages` Swift `:129-140` → `message(from:)` `:146-157` / TS `:123-150`)→ `NormalizedMessage`/`Message`:

| 消息字段 | 来源 | Swift:line | TS:line |
|---|---|---|---|
| `role` | 记录 `role` | `:147-148` | `:135` |
| `content` | 通过 `extractContent` 扁平化的块文本 | `:152`、`:180-204` | `:144`、`:192-211` |
| `timestamp` | 顶层 `timestamp`,否则 `metadata.timestamp` | `:153`、`:159-164` | `:145`、`:175-181` |
| `toolCalls` | `tool-call` 块 → `NormalizedToolCall{name, input(截断 500B), output:nil}` | `:154`、`:206-224` | `:146`、`:213-228` |
| `usage` | — | `:155`(nil) | (省略) |

### Engram 不消费的内容
1. 整个 `.meta.json` —— `title` 与 `model` 均被丢弃(`model` 在磁盘上存在但从不读取 → `model = nil`)。
2. `reasoning` 内容块(实时 243 条)—— 思维链被丢弃。
3. `image` 内容块(实时 4 条)—— 内联 base64 图像被丢弃。
4. `.checkpoints.jsonl` —— 从列举中排除。
5. `settings.json` —— 按项目 UI 状态。
6. `gitBranch` —— 在 100% 的记录上存在,从不映射进会话结构体。
7. `metadata.entrypoint` / `isAutomated` / `isMeta` / `messageId` / `version` / `source` —— 都不映射。
8. `parentId`(会话内 DAG)—— 不对消息线程建模;转录被扁平化为线性顺序。
9. token/usage/cost —— 不在来源中。

---

## 15. 谱系、注意点、版本漂移与边界情况

### 共享格式谱系

CommandCode 的记录形状 `{role, content[], sessionId, parentId, timestamp, metadata}` 属于 **Claude-Code 衍生的 JSONL 家族**,但有自己的方言:

| 特征 | CommandCode | Claude Code | Codex | Gemini/Qwen/iFlow | Cursor/VSCode/Copilot/Cline |
|---|---|---|---|---|---|
| 存储 | `~/.commandcode/projects/<encoded-cwd>/` 下的按会话 JSONL | `~/.claude/projects/<encoded-cwd>/` 下的按会话 JSONL | `~/.codex/sessions/` 下的 JSONL | 目录树 / 边车 | SQLite `.vscdb` / leveldb |
| cwd 编码 | `/`→`-`、`--` 转义(Swift `:226-233`) | **相同**目录编码方案 | n/a | n/a | n/a |
| `.checkpoints.jsonl` 兄弟文件 | 有(被过滤掉) | 有 | 无 | 无 | 无 |
| Claude 风格系统注入启发式 | **完全相同的正则/前缀集合**(Swift `:168-178`) | 这些标记的起源 | — | — | — |
| 内容块标记 | `tool-call`/`tool-result`/`text`/`reasoning`/`image`(Vercel AI-SDK 风:`toolName`+`input`/`output`) | `tool_use`/`tool_result`(Anthropic 块形状) | function-call/output | 各异 | 各异 |

**谱系结论:** CommandCode 在**磁盘布局层面是 Claude-Code 克隆**(相同的 `~/.<tool>/projects/<path-encoded-cwd>/<uuid>.jsonl` + `.checkpoints.jsonl` + 系统注入标记 —— Swift 适配器注释明确说它"镜像 TS commandcode 适配器"且与 claude-code 行为对齐,Swift `:75-77`、`:166-167`),但在**内容块层面是 Vercel-AI-SDK 风格的方言**。它是一个**提供方无关的 agent 外壳**(`.meta.json` 中是 DeepSeek/Qwen 模型),与单一厂商 CLI 区分开来。它既不属于 Gemini↔Qwen↔iFlow 布局谱系,也不属于 Cursor↔VSCode↔Copilot↔Cline 的 SQLite 谱系。本文档自成一体;关于共享的布局/系统注入血统,可交叉参考 Claude Code 文档。

### 注意点(Gotchas)

1. **GOTCHA(模型丢失):** 真实模型在 `.meta.json#model`(例如 `deepseek/deepseek-v4-pro`),两个适配器都不读取它,而它在所有实时 JSONL 记录中都缺失。尽管数据存在于磁盘,生产 `model` **始终为 nil**。速胜方案:读取该边车。
2. **GOTCHA(标题丢失):** `.meta.json#title`(经策划的人类标题)被忽略;Engram 用第一条 user 消息的 200 字符切片作为 `summary`。
3. **GOTCHA(有损 cwd 解码):** 由于实时 `cwd` 始终缺失,每个会话都回退到目录名解码,而这对**含连字符的路径是不可逆有损的** —— 例如项目 `my-project` 解码为 `my/project`;真实路径 `/Users/bing/-Code-/engram` 被捕获为目录 `users-bing-code-engram` → 解码为 `users/bing/code/engram`(丢失前导斜杠、丢失 `-Code-` 的连字符/大小写)。`--`→`-` 转义只保护双连字符;单个字面连字符无法恢复。
4. **GOTCHA(丢弃 reasoning/图像):** 实时数据中 243 个 reasoning + 4 个 image 块从转录与搜索文本中被静默丢弃。
5. **GOTCHA(标题替代物):** Engram 的 `summary` 是第一条未被注入的 user 消息,如果第一回合很短或是探针,它本身也可能是噪声。

### 差异(Swift vs TS)

6. **DIVERGENCE(时间戳回退):** TS 在没有记录带时间戳时回退到文件 mtime(`:99-101`);Swift 不会(留 `startTime=""` → 排序到 epoch)。对实时数据影响很小(顶层时间戳 100% 存在),但确是一处一致性差异。
7. **RESOLVED(`args` 回退):** Swift 与 TS 现在都读取 `input ?? args` 作为 tool-call input。Swift 一致性测试 `testCommandCodeAdapterAcceptsArgsForToolCallInput` 覆盖 `args` 路径,但实时数据只使用 `input`(703/705 object、2/705 string)—— `args` 与字符串输入都不是常见情形。

### 边界情况与版本漂移

8. **EDGE(字符串内容):** 20/1,541 条实时记录的 `content` 是裸字符串(非数组);两个适配器都逐字返回(Swift `:181-183` / TS `:193-194`)。
9. **EDGE(对象 output 强制 JSON 序列化):** 实时数据中 `tool-result.output` 为对象 705/705,因此逐字字符串路径从不运行;output 始终被 JSON 序列化并截断至 2000 字符 —— 大的工具输出在索引转录中被截断。
10. **EDGE(字符串 tool-call input):** 2/705 条实时 `tool-call` 块携带裸字符串 `input`(两个都是 `grep`);`jsonString`/`truncateJSON` 处理它们。
11. **EDGE(临时目录 cwd):** 有一个实时项目目录位于 `/private/var/folders/.../T/` 下,证实临时目录会话会被捕获。
12. **EDGE(解析失败 = 丢弃):** 任何 `JSON.parse` 失败的行都被跳过;没有任何记录携带 `sessionId` 的会话被整体拒绝(Swift `:93` `.malformedJSON` / TS `:95` null)。
13. **VERSION 标记:** `metadata.version: 2` 出现在 100% 的实时记录上 —— 这是一个两个适配器都不检查的前向兼容钩子。未来的 `version: 3` schema 会在无任何防护的情况下被静默解析。
14. **FIXTURE 与 LIVE 的差异:** fixture `sample.jsonl`(3 条记录)被精心制作以覆盖本机实时数据中大多不存在的防御性路径 —— 它携带顶层 `cwd`/`model` 以及 `parentId: null` 根,分布在两种不同的记录变体上:**user/root** 记录是 **9 键**变体 `["content","cwd","gitBranch","id","metadata","parentId","role","sessionId","timestamp"]`(有顶层 `cwd`、**无** `model`)且 `parentId: null`;**assistant** 记录是加上 `model` 的 **10 键**变体(同时有顶层 `cwd` 与 `model`),`parentId: "msg-001"`(tool 记录是 9 键变体,`parentId: "msg-002"`)。实时存储既无顶层 `cwd`,也无顶层 `model`;当前 live 首条 parent 分布为 1 个 null-root 文件和 38 个 non-null-root 文件。注(web 已确认 2026-06-21,npm 最新版本 2026-07-02 复核):fixture 的 `parentId: null` 根**与**当前 CommandCode 一致,其写入器从 `parentId = null` 开始每次重写;剩余 live 首条非空 `parentId` 文件反映的是更早的追加式版本。fixture 的 `tool-call` input 是对象(`{path: …}`),与实时一致;其 `tool-result` output 是裸字符串(`"file contents omitted"`),与实时**不**一致(实时始终是 `{type,value}` 对象)。因此一致性测试通过,而实时行为丢弃了 model、cwd,并对每个 tool-result 做 JSON 序列化。

### 已解决问题(web 已确认 2026-06-21;npm 最新版本 2026-07-02 复核)
- **v1 schema。** 已确认(官方):CLI 定义 `isLegacyFormat(e) = (!e.metadata || e.metadata.version !== 2)` —— 任何 `metadata.version !== 2` 的记录都被视为 v1/legacy。在 `loadMessages()` 时,若任一行 `isLegacyFormat`,CLI 会运行 `legacyAnthropicToSession(...)`(经由 `convertUserMessage`/`convertAssistantMessage`/`buildToolNameMap`)将一个**遗留 Anthropic 消息格式**(形如 `{role, content}`、带 Anthropic 风格内容块的记录)转换为 v2,记录日志 `[Session] Migrating v1 session to v2: <file> (<n> messages)`,然后以 `parentId: null` 和 `metadata.version: 2` 重写文件。因此 v1 曾是 Anthropic 消息形状的转录;v2(当前磁盘格式)是 `{id, timestamp, sessionId, parentId, role, content, gitBranch, metadata}` 信封。注意:源码中唯一有文档记载的遗留路径是 Anthropic `{role,content}` 格式 —— Engram 适配器探测的顶层 `cwd`/`model` 与 `metadata.model` 字段在 v1 迁移代码和 v2 写入器中都**不**存在;在当前代码中 `model` 仅存在于 `.meta.json`、`cwd` 仅存在于项目目录名,因此这些探测是针对一个当前源码未表征的更早内联布局的适配器防御性手段。([source](https://registry.npmjs.org/command-code/-/command-code-0.40.17.tgz))
- **跨会话 `parentId`。** 已确认(官方):在当前 npm(最新核验 0.40.17)中写入器(`SessionManager.writeMessages`)**不**追加 —— 它在每次保存时从内存数组重建整个消息列表,为每条记录 `id` 生成全新 `crypto.randomUUID()`,并设 `parentId = this.lastMessageId`,而 `lastMessageId` 在构造时为 `null` 且仅在重写循环内部更新(从不从加载/恢复的会话中播种)。因此第一条记录的 `parentId` 为 `null`,且链纯属文件内。恢复/续接(`loadMessages` → `resolvePrintSession`/`loadResumed`)会把先前消息重新加载进内存,但下一次保存仍从 `parentId: null` 重写整个文件。CommandCode **不**跨被恢复的文件串接 `parentId`;不会向单独文件写入前导/系统记录;文件名始终等于该文件自身的 `sessionId`(写入器设 `sessionFilePath = <sessionId>.jsonl` 并将每条记录的 `sessionId = this.sessionId`)。当前 live 的 38 个首条非空 `parentId` 文件最符合更早的追加式版本。([source](https://registry.npmjs.org/command-code/-/command-code-0.40.17.tgz))
- **`metadata.messageId` / `isAutomated` / `isMeta` 语义。** 已确认(官方)对照源码 `metadata` zod schema:`messageId` 是提供方/UI 消息 id(检查点通过 `snapshot.messageId` 锚定到它);`isAutomated:boolean` 标记机器生成/注入的回合(CLI 通过 `isAutomatedSlashCommandPrompt` 在自动化斜杠命令提示及类似非人类回合上设置);`isMeta:boolean` 标记 meta 回合(`createMessageWithMeta`/`sanitizeMessage` 路径,如内容为空的 meta 回合)。先前推断的语义是正确的。([source](https://registry.npmjs.org/command-code/-/command-code-0.40.17.tgz))
- **`entrypoint:"print"` / `isAutomated` 的派发潜力。** 已确认(官方):源码定义单一 `entrypoint` 常量 `Oh="print"`,仅由 `resolvePrintSession()` 在 CLI 以无头一次性模式经由文档记载的 `--print`/`-p` 标志运行时赋值([CLI reference](https://commandcode.ai/docs/reference/cli):`cmd --print "message"` 以无头方式运行、输出响应并退出)。写入器仅在设置了 `this.entrypoint` 时才将 `entrypoint` 写入 metadata,因此交互式会话**不**写入 `entrypoint` 键 —— 这解释了为何磁盘上只见 `"print"` 这一个值、为何大多数记录省略它。CommandCode 自身是否用 `entrypoint`/`isAutomated` 做派发分类:源码中不存在 —— 那是 Engram 内部的设计选择,超出工具格式范围。([source](https://registry.npmjs.org/command-code/-/command-code-0.40.17.tgz))
- **`--` 转义未被实时数据覆盖。** (Engram 内部设计 —— 无法 web 验证。)Engram 适配器的 `--`/`-` 解码分支是否被用户数据覆盖,是一项 Engram 覆盖率观察,而非可 web 回答的 CommandCode 格式事实。就底层格式而言:CLI 的 `getCurrentProjectDirName` 通过一个被压缩的辅助函数对 `process.cwd()` 编码,该函数在 bundle 中无法反混淆为字面正则,因此确切的转义规则(单 `-` vs `--`)**未能**从源码独立确认。所描述的方案(转小写、非字母数字 → `-`、字面 `-` → `--`)来自 Engram 适配器,应视为适配器断言,而非源码确认。([source](https://registry.npmjs.org/command-code/-/command-code-0.40.17.tgz))

### 源码可得性
已确认(官方):CommandCode 的 CLI 源码仅部分开放。GitHub 仓库 [CommandCodeAI/command-code](https://github.com/CommandCodeAI/command-code) 实质上是一个 landing/readme 仓库(仅 `readme.md` + `.github`,约 3.4k stars);[CommandCodeAI 组织](https://github.com/orgs/CommandCodeAI/repositories)还有一个已归档的 `cmd-old-public`。实际发布的 CLI 源码以 [`command-code`](https://www.npmjs.com/package/command-code)(最新核验 `0.40.17`)发布到 npm,为单个打包的 `dist/index.mjs`(约 1.3 MB,经压缩但可读,包含 zod schema 与完整 `SessionManager` 逻辑);`package.json` 没有 `repository`/`homepage` 字段。因此权威的磁盘格式来源是 npm bundle,而非可浏览的 GitHub 源码树。安装:`npm i -g command-code`;二进制:`cmd`、`cmdc`、`command-code`、`commandcode`。([source](https://registry.npmjs.org/command-code/-/command-code-0.40.17.tgz))

---

## 16. 附录:真实的已脱敏样本

> 键逐字保留;消息文本、代码、命令、路径与机密已脱敏。结构得以保留。

### 16a. `user` 记录(记录层 + 内容块层)
```json
{
  "id": "d6d46e72-aa15-4049-8c26-84c15207258c",
  "timestamp": "2026-05-25T01:56:44.064Z",
  "sessionId": "400d4036-a1e4-4a22-b24a-9ebc7db0871c",
  "parentId": "410a7034-0a58-4085-8875-4f471fbde326",
  "role": "user",
  "gitBranch": "main",
  "metadata": { "timestamp": "2026-05-25T01:56:44.064Z", "source": "cli", "messageId": "685c1246-b555-4593-b068-4be3f4d72303", "version": 2 },
  "content": [ { "type": "text", "text": "<USER PROMPT REDACTED>" } ]
}
```

### 16b. 带 reasoning + text + tool-call 的 `assistant` 记录
```json
{
  "id": "679dd8d8-...",
  "timestamp": "2026-05-25T01:56:51.228Z",
  "sessionId": "400d4036-a1e4-4a22-b24a-9ebc7db0871c",
  "parentId": "d6d46e72-aa15-4049-8c26-84c15207258c",
  "role": "assistant",
  "gitBranch": "main",
  "metadata": { "source": "cli", "version": 2, "timestamp": "2026-05-25T01:56:51.228Z" },
  "content": [
    { "type": "reasoning", "text": "<THINKING REDACTED>" },
    { "type": "text", "text": "<PROSE REDACTED>" },
    { "type": "tool-call", "toolName": "shell_command", "toolCallId": "call_00_MAKdS9FclHpX38eDWrpj6245", "input": { "command": "<CMD REDACTED>" } }
  ]
}
```

### 16c. `tool` 记录(tool-result,成功)
```json
{
  "id": "<uuid>",
  "timestamp": "2026-05-25T01:56:52.110Z",
  "sessionId": "400d4036-a1e4-4a22-b24a-9ebc7db0871c",
  "parentId": "679dd8d8-...",
  "role": "tool",
  "gitBranch": "main",
  "metadata": { "source": "cli", "version": 2, "timestamp": "2026-05-25T01:56:52.110Z" },
  "content": [
    { "type": "tool-result", "toolName": "shell_command", "toolCallId": "call_00_MAKdS9FclHpX38eDWrpj6245", "output": { "type": "text", "value": "<OUTPUT REDACTED>" } }
  ]
}
```

### 16d. `tool` 记录(tool-result,错误)
```json
{
  "id": "<uuid>", "timestamp": "<iso>", "sessionId": "<uuid>", "parentId": "<uuid>",
  "role": "tool", "gitBranch": "main",
  "metadata": { "source": "cli", "version": 2, "timestamp": "<iso>" },
  "content": [
    { "type": "tool-result", "toolName": "grep", "toolCallId": "call_00_...", "output": { "type": "error-text", "value": "<ERROR REDACTED>" } }
  ]
}
```

### 16e. 带 image 的 `user` 记录
```json
{
  "id": "<uuid>", "timestamp": "<iso>", "sessionId": "<uuid>", "parentId": "<uuid>",
  "role": "user", "gitBranch": "main",
  "metadata": { "source": "cli", "version": 2, "timestamp": "<iso>" },
  "content": [ { "type": "image", "image": "data:image/jpeg;base64,<BASE64 REDACTED>" } ]
}
```

### 16f. 带裸字符串内容(系统注入)的 `user` 记录
```json
{
  "id": "<uuid>", "timestamp": "<iso>", "sessionId": "<uuid>", "parentId": "<uuid>",
  "role": "user", "gitBranch": "main",
  "metadata": { "source": "cli", "version": 2, "timestamp": "<iso>", "isAutomated": true },
  "content": "# AGENTS.md instructions for <PATH REDACTED>\n<INSTRUCTIONS> ... </INSTRUCTIONS>"
}
```

### 16g. 无头一次性对(`entrypoint:"print"`)
该 `user` 记录的 `content` 是**裸字符串**(一次性提示),而非空数组 —— 在全部 12 条实时 `print` user 记录中验证(长度 9×34 字节 + 3 条长内容:40,111 / 41,768 / 70,358 字节);磁盘上不存在任何 content 为空数组的 user 记录。
```json
{ "id": "<uuid>", "timestamp": "<iso>", "sessionId": "<uuid>", "parentId": "<uuid>", "role": "user", "gitBranch": "-",
  "metadata": { "source": "cli", "version": 2, "timestamp": "<iso>", "entrypoint": "print" }, "content": "<ONE-SHOT PROMPT REDACTED>" }
{ "id": "<uuid>", "timestamp": "<iso>", "sessionId": "<uuid>", "parentId": "<uuid>", "role": "assistant", "gitBranch": "-",
  "metadata": { "source": "cli", "version": 2, "timestamp": "<iso>", "entrypoint": "print" },
  "content": [ { "type": "reasoning", "text": "<REDACTED>" }, { "type": "text", "text": "<REDACTED>" } ] }
```

### 16h. `.meta.json` 边车(Engram 不读取)
```json
{ "title": "Review recent commits with sub-agents", "model": "deepseek/deepseek-v4-pro" }
```
```json
{ "title": "<TITLE REDACTED>" }
```
fork-session 变体(由 `--fork-session` 经 `copyForkSessionFiles` 写入;已确认 schema,但本机存储未观察到):
```json
{ "title": "<TITLE REDACTED>", "userRenamed": false, "model": "deepseek/deepseek-v4-pro", "parentSessionId": "<uuid>", "forkedAt": "<iso>", "branchPoint": "<branch-point>" }
```

### 16i. `.checkpoints.jsonl` 记录(Engram 不读取)
```json
{
  "type": "file-history-snapshot",
  "isSnapshotUpdate": false,
  "messageId": "f7984133-...",
  "snapshot": {
    "messageId": "685c1246-...",
    "timestamp": "2026-05-25T01:56:44.065Z",
    "trackedFileBackups": { "<PATH REDACTED>": { "backupFileName": "<hash>-53@v1", "backupTime": "<ts>", "version": 1 } }
  }
}
```

### 16j. CLI 全局 `config.json`(Engram 不读取)
```json
{ "provider": "command-code", "model": "deepseek/deepseek-v4-pro", "installed": true, "firstMessageSent": true, "reasoningEffort": { "deepseek/deepseek-v4-pro": "high" } }
```

### 16k. CLI 全局 `history.jsonl` 行(Engram 不读取)
```json
{ "p": "<PROMPT REDACTED>", "t": 1748137004064 }
```

### 16l. CLI 全局 `auth.json`(Engram 不读取;仅键)
```json
{ "apiKey": "<REDACTED>", "userId": "<REDACTED>", "userName": "<REDACTED>", "keyName": "<REDACTED>", "authenticatedAt": "<REDACTED>" }
```

---

## References (official sources)

Web 确认于 2026-06-21 执行(`web_access_ok=true`),并在 2026-07-02 复核最新 npm 版本为 `command-code@0.40.17`。npm bundle `dist/index.mjs` 是磁盘格式的权威来源。

- [command-code npm package (v0.40.17) tarball](https://registry.npmjs.org/command-code/-/command-code-0.40.17.tgz) —— 发布的 CLI bundle(`dist/index.mjs`),读写会话存储;磁盘格式的权威来源(zod schema + `SessionManager`)。
- [command-code on npm](https://www.npmjs.com/package/command-code) —— 包页面(安装 `npm i -g command-code`;二进制 `cmd`/`cmdc`/`command-code`/`commandcode`)。
- [CommandCodeAI/command-code (GitHub)](https://github.com/CommandCodeAI/command-code) —— 官方仓库;仅 landing/readme(实际 CLI 源码发布到 npm)。
- [CommandCodeAI org repositories](https://github.com/orgs/CommandCodeAI/repositories) —— 组织仓库列表(含已归档的 `cmd-old-public`)。
- [Command Code Docs — CLI Reference](https://commandcode.ai/docs/reference/cli) —— 确认 `--print`/`-p` 无头一次性模式。
- [Command Code official site](https://commandcode.ai/) —— 产品 landing。
