# Claude Code — 磁盘会话格式(权威参考)

> 本文档为英文权威版 claude-code.md 的中文阅读副本;若有出入以英文版为准。

Last researched: 2026-07-24

这是关于 **Claude Code 如何在磁盘上持久化其交互式会话** 以及 **Engram 的适配器如何
消费该格式** 的权威参考。它合并了针对用户真实存储库(`~/.claude/projects/`,Claude Code
版本 `2.1.146` → `2.1.185`)的五次独立研究,并与 Engram 的 TypeScript 和 Swift 适配器
进行了交叉核对。

> **两个真相来源。** (1) 真实的磁盘文件是权威格式。(2) Engram 的适配器是被编码固化的
> 解析知识。**两者冲突时,以磁盘上的真实情况为准**,并明确标注差异。
>
> 所有引用的 JSON 都经过 **匿名化**:消息文本、代码、密钥和个人路径都被占位符替换,
> 但 **每个 key 都被逐字保留**。本文档关注的是格式,而非内容。

---

## 1. Overview & TL;DR

Claude Code 把 **每个交互式会话持久化为一个只追加(append-only)的 JSONL 文件**,
存放在以 `~/.claude/projects/` 为根、按项目划分的目录树下。每行一个 JSON 对象,每行
一条记录,按事件顺序写入,绝不在原地重写。文件的基础名(一个 UUID)等于每条记录内部
携带的 `sessionId`。一个伴生的 sidecar 目录(相同 UUID,无 `.jsonl` 扩展名)可能保存
subagent 转录、溢出的工具输出和工作流产物。`projects/` 之外的若干全局文件
(`history.jsonl`、`sessions/<pid>.json`、`file-history/`)补全了整个图景。

**心智模型:** 一个会话文件就是一份 **由带类型记录组成的扁平事件日志**。大多数记录是
记账用的(“侧信道”)状态快照;只有 `user`、`assistant`、`attachment` 以及(大部分)
`system` 记录通过 `uuid`/`parentUuid` 参与对话树。在这些之中,**只有 `user` 和
`assistant` 携带真正的聊天内容** —— 而该内容本身又是一个嵌套的内容块数组。Engram
只索引 `user`/`assistant`;其余一切都是它刻意跳过的元数据。

需要内化的最重要的一点是 **三层 `type` 命名空间**(读者经常把它们混为一谈):

```
LAYER 1 — top-level record .type        (one JSONL line = one record)
          user · assistant · attachment · system · last-prompt · ai-title ·
          mode · permission-mode · file-history-snapshot · queue-operation ·
          pr-link · bridge-session · agent-name   (legacy: summary)
   │
   ├─ LAYER 2 — message.content[].type  (only on user/assistant records)
   │            text · thinking · redacted_thinking · tool_use · tool_result · image
   │               └─ tool_reference (doubly-nested inside a tool_result.content[] array)
   │
   └─ LAYER 3 — attachment.type         (only when record .type == "attachment")
                hook_success · skill_listing · task_reminder · deferred_tools_delta ·
                mcp_instructions_delta · queued_command · … (24 distinct subtypes)

   (plus system records carry a 4th discriminator: .subtype —
    compact_boundary · turn_duration · stop_hook_summary · api_error · …)
```

ASCII 分层 / 存储示意图:

```
~/.claude/
├── projects/
│   └── <encoded-cwd>/                       # cwd with '/' AND '.' → '-' (lossy)
│       ├── <session-uuid>.jsonl             # THE session — append-only JSONL
│       │     └── line = top-level record (Layer 1)
│       │           └── message.content[] = content blocks (Layer 2)   [user/assistant only]
│       │           └── attachment.type    = attachment subtype (Layer 3) [attachment only]
│       ├── <session-uuid>/                  # OPTIONAL sidecar dir, same UUID stem
│       │   ├── subagents/
│       │   │   ├── agent-<agentId>.jsonl    # subagent transcript (isSidechain:true)
│       │   │   ├── agent-<agentId>.meta.json# {agentType, description, toolUseId}
│       │   │   └── workflows/wf_<id>/agent-*.{jsonl,meta.json,journal.jsonl}
│       │   ├── workflows/wf_<id>{.json,/…}  # workflow run definitions/agents
│       │   ├── tool-results/<id>.txt        # spilled large tool outputs
│       │   └── session-memory/summary.md    # compaction markdown (rare)
│       ├── sessions-index.json              # OPTIONAL per-project catalog (rare/stale)
│       └── memory/, MEMORY.md, memory.bak.* # THIRD-PARTY plugin artifacts (not CC core)
├── history.jsonl                            # global cross-project prompt history
├── sessions/<pid>.json                      # live process registry (rewritten in place)
└── file-history/<session-uuid>/<hash>@v<N>  # checkpoint backups of edited files
```

**TL;DR 字段速查表:** 每条对话记录都携带 `type`、`uuid`、`parentUuid`、`sessionId`、
`timestamp`、`cwd`、`gitBranch`、`version`、`userType`、`entrypoint`、`isSidechain`。
`assistant` 额外加上 `message.usage`(token 记账)和 `requestId`。`user` 额外加上
`promptId`,对于工具返回还加上 `toolUseResult` + `sourceToolAssistantUUID`。Subagent
文件加上 `agentId` 并设置 `isSidechain:true`。

---

## 2. On-disk layout & file naming

### 2.1 Store root

两个适配器都把根硬编码为 `homedir()/.claude/projects`:
- TS: `ClaudeCodeAdapter` 构造函数(`claude-code.ts:29`)。
- Swift: `init(projectsRoot:)` 默认值(`ClaudeCodeAdapter.swift:14-15`)。

观察到的权限:项目目录 `0700`/`0755`;`.jsonl` 文件 `0600`;`.meta.json` 文件 `0644`。

### 2.2 The cwd → directory-encoding scheme (exact)

项目目录名通过字符替换从会话的 **工作目录**(`cwd`)派生而来。已对照真实的记录内
`cwd` 值进行验证:

| Real cwd | Encoded dir name |
|---|---|
| `/Users/bing/-Code-/engram` | `-Users-bing--Code--engram` |
| `/Users/bing/-Code-` | `-Users-bing--Code-` |
| `/Users/bing/-Automations-/glm-coding` | `-Users-bing--Automations--glm-coding` |
| `/Users/bing/-Code-/mediahub/.claude/worktrees/stupefied-ardinghelli-0b23ef` | `-Users-bing--Code--mediahub--claude-worktrees-stupefied-ardinghelli-0b23ef` |
| `/` (filesystem root) | `-` |

**编码规则(正向,cwd → 目录):**
1. 每个 `/`(路径分隔符)→ `-`。
2. 每个 `.`(段内的字面点号,例如 `.claude`)→ `-`。
3. 路径中已有的字面 `-` 原样保留。

这就是为什么开头的 `/` 总会产生一个 **开头的 `-`**,以及为什么 `/.claude/` 会塌缩为
`--claude-`(`.claude` 之前的 `/` → `-`,`.` → `-`)。根 `/` 编码为单一的特殊目录 `-`。

**该编码是有损的,且不可唯一逆向。** 一连串的连字符可能来自 `/`、`.`、字面的 `-`,或
任意组合;连字符串内部的段边界是无法恢复的。

> **差异(以磁盘真实情况为准)。** 两个适配器的 `decodeCwd` 都使用规则
> `"--" → 字面 "-"`,然后 `"-" → "/"`,再恢复(TS `claude-code.ts:302-307`;
> Swift `ClaudeCodeAdapter.swift:340-345`)。它们 **没有** 建模 `.` → `-` 规则,
> 并把 `--` 塌缩为字面 `-`,因此对于像该用户那样字面命名的 `-Code-`/`-Automations-`
> 目录,解码会出现偏差:
>
> ```text
> decodeCwd("-Users-bing--Code--engram")  -> "/Users/bing-Code-engram"   (WRONG)
> real in-record cwd                       -> "/Users/bing/-Code-/engram"
> ```
>
> **Engram 从不依赖 `decodeCwd` 来保证正确性。** 两个 `parseSessionInfo` 实现都直接从
> 每条记录读取权威的 `cwd` 字段,并由 `basename(cwd)` 派生 `project`。`decodeCwd`
> 只是一个用于显示/兜底的辅助函数。目录名是一个有损的便捷 key;记录内的 `cwd` 才是
> 真相来源。

### 2.3 Session file naming grammar

```
<session-uuid>.jsonl          session-uuid = canonical lowercase UUIDv4
                              e.g. 8f06ae86-7a5b-487a-a348-7d276e729f30.jsonl
```

- 基础名(去掉 `.jsonl`)等于每条记录内部的 `sessionId` 字段(验证 30/30,零不匹配)。
- 文件大小从几 KB(2 条记录)到 >12 MB 不等。
- 一个 **相同 UUID 但无 `.jsonl`** 的目录可能与文件并存:即伴生的 sidecar 目录。并非
  所有会话都有它。

### 2.4 The special `-` project dir

`~/.claude/projects/-/` 编码 cwd `/`(在文件系统根目录或无项目上下文下启动的会话)。
在该存储库中它只包含一个陈旧的 `sessions-index.json`,没有活跃的 `.jsonl` 文件。
Engram 对它透明处理 —— 它只是另一个 `projects/*` 目录;`project`/`cwd` 从每条记录的
`cwd` 字段解析。

### 2.5 Subagent subdirectory

```
<session-uuid>/subagents/
  agent-<agentId>.jsonl                 # subagent transcript
  agent-<agentId>.meta.json             # {agentType, description, toolUseId}
  workflows/wf_<id>/agent-<agentId>.{jsonl,meta.json,journal.jsonl}  # nested
```

- `agentId` **通常是一个 17 字符的十六进制 id**(例如 `a784b50f9fbfb258b`、
  `a4e5796f79594d4d0`),在文件名中以 `agent-` 为前缀。它 **不是** UUID。
  但 **不要假设固定长度或纯十六进制**:工作流/provider review subagent 使用
  `<label>-<hex>` 形式,例如 `akimi-review-699cb045f0e92446`(长度 29)和
  `aagy-review-085940ff88969949`(长度 28)。把 `agentId` 当作 **不透明 token** ——
  对它做匹配,绝不解析它。
- subagent 的 JSONL 每行都共享 **父级的 `sessionId`**;只有 `agentId` 使其唯一。
  Engram 以 `agentId` 作为 subagent 数据库行的 key(TS `claude-code.ts:145`,
  Swift `ClaudeCodeAdapter.swift:150`)。
- 完整的 dispatch/linkage 模型见 §10。

### 2.6 Exhaustive enumeration of every file kind in a project dir

| Path (relative to project dir) | Kind | Owner | Indexed by Engram? |
|---|---|---|---|
| `<uuid>.jsonl` | 会话转录(JSONL) | Claude Code | **Yes**(主) |
| `<uuid>/subagents/agent-<hex>.jsonl` | subagent 转录 | Claude Code | **Yes** |
| `<uuid>/subagents/agent-<hex>.meta.json` | subagent 元数据 sidecar | Claude Code | No |
| `<uuid>/subagents/workflows/wf_*/agent-*.{jsonl,meta.json}` | 嵌套工作流 subagent | Claude Code / polycli | **No**(覆盖缺口,见 §15) |
| `<uuid>/subagents/workflows/wf_*/journal.jsonl` | 工作流记忆化日志 | Claude Code / polycli | No |
| `<uuid>/workflows/wf_<id>.json` | 工作流运行定义(脚本/阶段) | Claude Code / polycli | No |
| `<uuid>/workflows/wf_<id>/agent-*.{jsonl,meta.json}` | 工作流 agent 运行 | Claude Code / polycli | No |
| `<uuid>/tool-results/<9-char-id>.txt` | 溢出的大工具输出 | Claude Code | No |
| `<uuid>/session-memory/summary.md` | compaction/自动摘要 markdown | Claude Code | No |
| `sessions-index.json` | 按项目的会话索引 sidecar | Claude Code | No |
| `memory/`, `MEMORY.md`, `memory.bak.<ts>/` | 项目记忆笔记/备份 | **第三方插件** | No |

`workflows/wf_<id>.json` 形状(匿名化):

```json
{"runId":"wf_1f5d71cb-5a0","timestamp":"2026-05-31T07:14:13.157Z","taskId":"<9char>",
 "script":"export const meta = { name: '...', description: '...', phases: [ ... ] } ..."}
```

`tool-results/<id>.txt` 是无法内联的过大工具输出的原始文本/JSON;转录会引用它。
`<id>` 是一个 9 字符的类 base36 token(例如 `bcvrd4r54`)。

### 2.7 Discovery / enumeration (per adapter)

两个适配器都遍历 `projects/*`(一层),然后对每个条目:
- 以 `.jsonl` 结尾 → 作为会话定位器产出;
- 是目录 → 查找其 `subagents/` 子目录,并产出其中的每个 `*.jsonl`。

Swift `listSessionLocators()`(`ClaudeCodeAdapter.swift:27-48`)返回 **已排序** 的
列表;TS `listSessionFiles()`(`claude-code.ts:41-73`)是一个未排序的异步生成器。
**两者都不下钻进 `subagents/workflows/`**,也不读取 `workflows/`、`tool-results/`、
`session-memory/`、`memory/` 或 `*.meta.json`。

---

## 3. File lifecycle & generation

### 3.1 Write model — strictly append-only

每一行是一条记录,在事件发生时写入。Claude Code **绝不在原地重写较早的行**。证据:

- **文件名 UUID == 内部 `sessionId`**,对所有采样文件都成立。新对话获得一个全新的
  UUID 文件;已有文件只被追加。
- **可变状态是被重新快照,而非编辑。** `last-prompt`、`mode`、`permission-mode` 和
  `ai-title` 在一个文件中以 **重复簇** 形式出现。当值发生变化时,Claude Code **追加一条
  新记录**,而非修改旧记录 —— **最后一次出现胜出**。(一个 933 行的文件可以包含 107 条
  `mode` 和 107 条 `last-prompt` 记录。)
- **消息记录以追加顺序为权威。** 时间戳大致单调,但在近乎同时发出时可能在亚秒级并列。
  消费者应将字节/追加顺序(而非按时间戳排序)视为规范,并使用 `uuid`/`parentUuid`
  链表来恢复真正的树结构。

### 3.2 Ordering & the parentUuid DAG

文件字节顺序 = 因果/追加顺序。对话树记录携带 `uuid`(自身)和 `parentUuid`(前驱),
构成一个显式的链表/DAG,因此即使追加顺序与时间戳不一致,树结构仍可恢复。完整的链接
模型见 §5.6。

### 3.3 Crash / partial-line behavior

由于写入是逐行只追加的,被截断的最后一行 **原则上可能存在**(崩溃在写入中途可能留下
一个非 `}` 结尾的尾部),两个适配器都能容忍:每行独立解析;解析失败返回 `null`/跳过
(TS `parseLine` `claude-code.ts:325-331`;Swift 通过 `JSONLAdapterSupport.readObjects`)。
一个坏的尾行绝不会破坏其余部分。TS 读取器还会跳过空行
(`if (line.trim())`,`claude-code.ts:317`)。

> **框架修正(磁盘真实情况)。** 撕裂/截断的尾行 —— 尽管其健壮性保证是真实的 ——
> **实际上并未被观察到**:对整个存储库逐文件扫描
> (`jq -R 'fromjson? // "BAD"'` 遍历每个非 subagent 的 `.jsonl`)发现
> **0 个无法解析的行** 且任何地方都 **0 个被拼接/交错的记录**。在朴素的跨文件
> `cat | jq` 普查中出现的乱码 token(例如 `last-prlast-prompt`)**不是** 真正的撕裂
> 写入 —— 它们是缺少结尾换行符的文件在被许多文件 `cat` 在一起时,在其边界处被合并
> 所产生的假象。**最后一行缺少结尾换行符很常见**,所以读取器必须 **逐文件** 切分,
> 而非拼接,否则会错误地合并文件边界。

### 3.4 `/compact` — same file, in-place continuation

**`/compact` 不会开始一个新文件。** compaction 在文件中途发生,对话继续追加到同一个
`<session-uuid>.jsonl`。已验证:在一个 933 行的文件中,compact 记录位于第 869–870 行,
并且 **在同一文件中,在 compact 点之后又追加了 63 条记录**。这些记录见 §11。

### 3.5 `/clear` and resume (`--continue` / `--resume`)

- **`/clear`** 结束当前会话的追加(无终止记录)。下一个 prompt 会打开一个 **全新的**
  `<new-uuid>.jsonl`。没有任何反向指针把新文件链接到被清除的那个 —— 它们相互独立。
- **Resume(`--continue` / `--resume`)** **重新打开已有的 `<sessionId>.jsonl` 并追加** ——
  它不是“指回旧文件的新文件”。结构上已确认:每个采样文件的内部 `sessionId` 都与其
  文件名匹配,并且对 120 个文件的扫描发现 **零** 个跨文件悬空的 `parentUuid` 引用。
  磁盘上的 resume 信号:
  - **`last-prompt`** `{type, leafUuid, sessionId}` —— 指向 **叶子**(最近)消息的
    UUID,以便新轮次以正确的 `parentUuid` 挂接。每轮重新追加;最后一条 = 当前叶子。
  - **`summary`**(legacy)`{type, summary, leafUuid}` —— 更旧的 resume 标记;
    **在该存储库中不存在**(CC 2.1.x 改写 `last-prompt` + `ai-title`)。出于向后
    兼容保留在两个适配器的跳过注释中。

> **Confirmed (official):** 转录以 JSONL 形式存储于
> `~/.claude/projects/<project>/<session-id>.jsonl`(其中 `<project>` 由工作目录路径
> 派生),每行一个 JSON 对象,对应一条消息、工具调用或元数据条目;会话被持续保存,并在
> `/clear` 后可 resume。`CLAUDE_CONFIG_DIR` 可重定位存储;文件在 30 天后被移除
> (`cleanupPeriodDays`);`CLAUDE_CODE_SKIP_PROMPT_HISTORY` / `--no-session-persistence`
> 抑制写入。**分支**(`/branch`、`/rewind`、`--fork-session`)创建一个归入根会话的
> 分叉副本 —— 与 §3.2 和 §5.6 的树/分支模型一致。官方文档明确 **不** 记载逐记录的字段
> schema,因此本文档其余部分仍以磁盘真实情况为真相来源
> ([Manage sessions docs](https://code.claude.com/docs/en/sessions))。

### 3.6 Crash/version robustness summary

`version` 被打在每条对话/attachment/system 记录上(例如 `"2.1.156"`、`"2.1.183"`)。
生命周期记录的 *形状* 跨版本演进,但适配器纯粹基于 `MESSAGE_TYPES = {user, assistant}`
白名单进行门控(TS `claude-code.ts:26`;Swift 内联于 `:101`),因此新的记录/子类型会被
前向安全地跳过,无需代码改动。

---

## 4. Record / line taxonomy (top-level Layer-1 record types)

一个 JSONL 行 = 一条由 `.type` 区分的顶层记录。全库普查(跨研究轮次合并 —— 计数为数量级
指示性,非精确值,且随存储库增长):

| Record `type` | In conversation tree? | Carries `message`? | Purpose | Engram |
|---|:---:|:---:|---|---|
| `assistant` | **yes**(`uuid`/`parentUuid`) | yes | 一次模型响应轮次(text/thinking/tool_use 块 + `usage`) | **indexed** |
| `user` | **yes** | yes | 人类 prompt 或 tool_result 返回或注入的系统文本 | **indexed** |
| `attachment` | **yes** | no(有 `attachment`) | 注入的上下文/hook/提醒;子类型在 `.attachment.type`(Layer 3) | skipped |
| `system` | **yes**(大多数) | no | 系统/元事件;由 `.subtype` 区分 | skipped |
| `last-prompt` | no | no | resume 叶子指针 `{leafUuid, sessionId, lastPrompt?}` | skipped |
| `ai-title` | no | no | 自动生成的会话标题 `{aiTitle, sessionId}` | skipped |
| `permission-mode` | no | no | 权限模式快照 `{permissionMode, sessionId}` | skipped |
| `mode` | no | no | UI/交互模式快照 `{mode, sessionId}` | skipped |
| `queue-operation` | no | no | prompt 队列的 enqueue/dequeue/remove `{operation, content?, sessionId, timestamp}` | skipped |
| `file-history-snapshot` | no | no | 每条消息的被跟踪文件备份索引;keys `{type, messageId, isSnapshotUpdate, snapshot}` —— **不携带任何 `sessionId`**(仅凭文件归属关联到其会话) | skipped |
| `pr-link` | no | no | 链接一个已创建的 PR `{prNumber, prRepository, prUrl, …}` | skipped |
| `bridge-session` | no | no | 链接到一个桥接的(desktop↔cli/cloud)会话 | skipped |
| `agent-name` | no | no | 人类可读的 agent 标签 `{agentName, sessionId}` | skipped |
| `summary` *(legacy)* | n/a | n/a | 旧的 compaction/resume 标记 `{summary, leafUuid}` —— 在该存储库中 **0 次出现** | skipped |

**工作流日志记录(仅 `subagents/workflows/wf_*/journal.jsonl` —— 非会话转录):**
`started` 和 `result`,一个记忆化缓存,无信封:

```json
{"type":"started","key":"v2:<sha256>","agentId":"<agentId>"}
{"type":"result","key":"v2:<sha256>","agentId":"<agentId>","result":{ … }}
```

**关键结构性事实:** 只有 `user`、`assistant`、`attachment` 以及(大多数)`system`
记录携带 `uuid`/`parentUuid` 并参与树结构。其余 9 种记录类型 **既无 `uuid` 也无
`parentUuid`** —— 它们是被追加进同一文件的扁平“侧信道”状态记录。不要把它们缺失的
`parentUuid` 当作树根。

> **指针列表修正。** KNOWN-POINTERS 列表混淆了层次。`message`(在 `message.type` 上
> 总为字面 `"message"`)、`direct`(`tool_use.caller.type`)、
> `text`/`thinking`/`tool_use`/`tool_result`(Layer-2 内容块)、`create`
> (`toolUseResult.type`)以及
> `task_reminder`/`skill_listing`/`hook_success`/`mcp_instructions_delta`/`deferred_tools_delta`
> (Layer-3 `attachment.type`)**都不是顶层记录类型**。该列表中只有
> `permission-mode`、`file-history-snapshot`、`ai-title`、`system`、`last-prompt`
> 是真正的 Layer-1 类型。

---

## 5. Shared envelope / metadata fields

存在于 **对话树记录** 上(`user`/`assistant`/`attachment`/`system` —— 即带 `uuid`
的那些)。**大多数** 侧信道记录携带 `type` + `sessionId`(+ 其自身负载)——
`last-prompt`、`ai-title`、`mode`、`permission-mode`、`queue-operation`、`pr-link`、
`bridge-session` 和 `agent-name` 都如此。**例外是 `file-history-snapshot`,它根本不
携带 `sessionId`** —— 其唯一的 keys 是 `{type, messageId, isSnapshotUpdate, snapshot}`,
并且 **仅凭文件归属**(它位于哪个 `.jsonl` 中)关联到其会话,从不通过记录内字段
(已验证:1242/1242 条 `file-history-snapshot` 记录缺少 `sessionId`;见 §4、§13.4)。

| 字段 | 类型 | 含义 | 是否可选? | 示例 |
|---|---|---|---|---|
| `type` | string | Layer-1 记录类型 | required | `"assistant"` |
| `uuid` | string (uuid) | 本记录的唯一 id;树中的节点 id | tree records | `"42245a7c-…"` |
| `parentUuid` | string\|null | 前一条记录的 `uuid`;`null` = 链根 | tree records | `"8375e1cd-…"` / `null` |
| `sessionId` | string (uuid) | 所属会话 = 文件名词干;subagent 复用父级的 | **all** records | `"18c2384d-…"` |
| `timestamp` | string (ISO-8601 ms, `Z`) | 事件时间 | tree records | `"2026-06-19T04:59:17.179Z"` |
| `cwd` | string (abs path) | 写入时的 **权威** 工作目录 | tree records | `"/Users/bing/-Code-/polycli"` |
| `gitBranch` | string | 活动的 git 分支(无则 `""`) | tree records | `"main"` |
| `version` | string (semver) | 写入该行的 Claude Code 版本 | tree records | `"2.1.183"` |
| `userType` | string | `"external"`(普通)或 `"ant"`(Anthropic 内部构建) | tree records | `"external"` |
| `entrypoint` | string | 启动入口:`"cli"`、`"sdk-cli"`、`"claude-desktop"` | tree records | `"cli"` |
| `isSidechain` | bool | 在 subagent/sidechain 文件内为 `true`;否则 `false` | tree records | `false` |
| `message` | object | 聊天消息(仅 user/assistant) | user/assistant | 见 §6 |
| `requestId` | string (`req_…`) | 该轮次的 Anthropic API request id | assistant only | `"req_011C…"` |
| `promptId` | string (`prompt_…`) | 把属于同一用户 prompt 的记录分组 | user only | `"prompt_01…"` |
| `agentId` | string(不透明;通常 17-hex) | subagent 唯一 key;出现在 subagent 记录上(+ 派生它的父级)。通常 17 字符十六进制,但存在 `<label>-<hex>` 形式(如 `akimi-review-…`)—— 当作不透明 | subagent files | `"a686211783283b2cb"` |
| `slug` | string | 短的 kebab 会话/主题标题(较新的 2.1.x) | optional | `"lively-rolling-ripple"` |
| `isMeta` | bool | 标记注入的/非对话性记录 | optional | `true` |
| `origin` | object `{kind}` | prompt 来源:`{"kind":"human"\|"task-notification"\|"coordinator"}` | user, optional | `{"kind":"human"}` |
| `promptSource` | string | `"typed"`/`"system"`/`"queued"`/`"sdk"` | user, optional | `"typed"` |
| `permissionMode` | string | 该轮次生效的权限模式 | user, optional | `"bypassPermissions"` |
| `sourceToolAssistantUUID` | string (uuid) | 在 tool_result user 记录上:其 `tool_use` 被本记录回应的那条 assistant 记录的 `uuid` | user/tool_result | `"<uuid>"` |
| `toolUseResult` | object\|string | 信封层面的结构化/原始工具输出镜像(形状随工具而变) | user/tool_result | `{…}` |
| `attributionAgent` | string | 哪个 agent persona 产生了该轮次(subagent) | assistant, optional | `"i18n"` |
| `attributionSkill` / `attributionPlugin` | string | 归因到该轮次的 skill/plugin | assistant, optional | `"<skill>"` |
| `attributionMcpServer` / `attributionMcpTool` | string | 归因的 MCP server/tool | assistant, MCP only | `"codegraph"` / `"codegraph_status"` |
| `isApiErrorMessage` | bool | 本 assistant 记录是一条合成的 API 错误通知 | assistant, error | `true` |
| `error` | string | 上述错误的错误类别 | assistant, error | `"rate_limit"` |
| `apiErrorStatus` | int\|null | API 错误的 HTTP 状态码 | assistant, error | `429` |
| `isCompactSummary` | bool | 标记一次 compaction 之后的合成摘要 user 消息 | optional | `true` |
| `isVisibleInTranscriptOnly` | bool | 仅用于显示;从 API 上下文中排除 | optional | `true` |
| `container` / `context_management` | object | 容器/exec 与服务端上下文窗口元数据 | assistant, 极罕见 | `{…}` |
| `teamName` | string | 团队/工作区名称(仅组织安装) | **在该存储库中未验证**(0 条记录 —— 仅组织安装) | `"<team>"` |

> **没有顶层 `diagnostics` 字段。** `diagnostics` **仅** 存在于 `message.diagnostics`
> (cache-miss 信息,见 §6.1)。全库扫描发现 **0 条记录** 带有顶层 `diagnostics`
> key —— 不存在顶层镜像。

> **Engram 覆盖缺口。** 两个适配器 **只** 读取 `type`、`sessionId`、`agentId`、`cwd`、
> `timestamp` 和 `message.{model,content,usage}`。其余一切 —— `uuid`、`parentUuid`、
> `requestId`、`promptId`、`isSidechain`、`slug`、`origin`、`attribution*`、
> `toolUseResult`、`isCompactSummary` —— 都被 **丢弃**。父级链接是从 **文件系统路径**
> (`/subagents/`)重建的,绝非来自文件内的 `parentUuid`。

### 5.6 parentUuid linkage model (the conversation tree)

- 每条树记录都有 `uuid`(自身)和 `parentUuid`(前驱)。从任一叶子沿 `parentUuid`
  跟踪到 `null` 即到达链根。这构成一棵 **树**(编辑/重试/compaction 之后可能分叉);
  大多数会话是单条线性链。
- **`parentUuid: null` = 一个根。** 会话通常以一个 `attachment`(或 `user`)根开始;
  按文件计,树记录中通常恰好有一个树根。
- **跨树指针**(与 `parentUuid` 正交的逻辑边):
  - `system/compact_boundary` 携带 **`logicalParentUuid`** —— compaction 前的逻辑父级,
    把 compaction 后的链跨越边界缝合起来。
  - `last-prompt` 携带 **`leafUuid`** —— 当前转录叶子(resume)。
  - `file-history-snapshot` 携带 **`messageId`** —— 快照所附着的消息 `uuid`。
  - tool_result `user` 记录携带 **`sourceToolAssistantUUID`** —— 把一个结果链接回
    发出对应 `tool_use` 的那条 assistant 记录。

已验证的开场序列(匿名化为 8 字符 id;侧信道记录在树开始之前发出):

```jsonc
{"type":"last-prompt",         "uuid":null,       "parentUuid":null}        // side-channel (no uuid field)
{"type":"mode",                "uuid":null,       "parentUuid":null}        // side-channel
{"type":"permission-mode",     "uuid":null,       "parentUuid":null}        // side-channel
{"type":"attachment",          "uuid":"3c40afb6", "parentUuid":null}        // TREE ROOT
{"type":"attachment",          "uuid":"8375e1cd", "parentUuid":"3c40afb6"}  // → root
{"type":"file-history-snapshot","uuid":null,      "parentUuid":null}        // side-channel
{"type":"user","isMeta":true,  "uuid":"4efc3f20", "parentUuid":"8375e1cd"}  // injected user
{"type":"user",                "uuid":"42245a7c", "parentUuid":"4efc3f20"}  // real prompt
```

---

## 6. Message & content-block schema

### 6.1 The assistant `message` object

Keys(1335/1340 条记录):`id, type, role, model, content, stop_reason,
stop_sequence, stop_details, usage`(+ 可选 `diagnostics`;另有 5 条记录携带
`container` + `context_management`)。

| 字段 | 类型 | 含义 | 是否存在 | 示例 |
|---|---|---|---|---|
| `id` | string (`msg_…`) | Anthropic 消息 id | always | `"msg_01KbYMB1YS5…"` |
| `type` | string | 总是字面 `"message"` | always | `"message"` |
| `role` | string | 总是 `"assistant"` | always | `"assistant"` |
| `model` | string | 产生它的模型;客户端生成/错误轮次为 `"<synthetic>"` | always | `"claude-opus-4-8"` |
| `content` | array | 内容块(§6.3)—— assistant content **总是数组** | always | `[ {…} ]` |
| `stop_reason` | string\|null | **`tool_use`**(最常见 —— 模型想调用工具)、`end_turn`、`null`(进行中 / 流式)、`max_tokens`、`stop_sequence`、`refusal` | always(nullable) | `"tool_use"` |
| `stop_sequence` | string\|null | 触发的是哪个停止序列 | always(nullable) | `null` |
| `stop_details` | object\|null | 扩展停止信息;全语料中为 `null` | always(nullable) | `null` |
| `usage` | object | token 记账(§9) | always | `{…}` |
| `diagnostics` | object\|null | cache-miss 信息,例如 `{"cache_miss_reason":{"type":"messages_changed","cache_missed_input_tokens":26074}}`(还有 `previous_message_not_found`、`tools_changed`、`unavailable`) | always(nullable) | `null` |

> **`stop_reason` 分布(真实普查,跨 `engram`/`polycli`/`mediahub` 存储库约 23k 条
> assistant 记录):** `tool_use`=16401、`end_turn`=5582、`max_tokens`=897、`null`=80、
> `stop_sequence`=40、`refusal`=24。**`tool_use` 占主导**,因为大多数轮次发出一个
> `tool_use` 块 —— 不要把 `end_turn` 当作默认值。`refusal` 是模型拒绝回答。
> (`null` = 进行中 / 尚未定型的流式记录。)

> **`cache_miss_reason.type` 取值(真实普查,`message.diagnostics` 非空):** **主导**
> 取值是 `messages_changed`;还有 `previous_message_not_found`、`tools_changed` 和
> `unavailable`。`cache_miss_reason` 对象携带 `{type, cache_missed_input_tokens?}`,
> 解释该轮次缓存读取为何未命中。
| `container` / `context_management` | object | 容器/exec 与服务端上下文元数据 | rare | — |

### 6.2 The user `message` object

最小 keys:`role`、`content`。

| 字段 | 类型 | 含义 | 是否存在 | 示例 |
|---|---|---|---|---|
| `role` | string | 总是 `"user"` | always | `"user"` |
| `content` | **string OR array** | 键入的 prompt(string)vs. 工具结果/图片/混合(array) | always | `"<prompt>"` 或 `[ {…} ]` |

`message.content` 多态(主 3112 行文件):string → 57(键入的 prompt / 注入的元文本);
含 `tool_result` 的数组 → 786;含 `text` 的数组 → 2;含 `image` 的数组 → 1。
**实用规则(两个适配器):** content 数组中包含 `tool_result` 块的 `user` 记录是一条
**工具消息**,而非人类轮次。

### 6.3 Assistant content blocks (Layer 2)

#### `text` — keys `["text","type"]`
```json
{ "type": "text", "text": "<assistant prose, redacted>" }
```

#### `thinking` — keys `["signature","thinking","type"]`
| 字段 | 类型 | 含义 |
|---|---|---|
| `type` | string | `"thinking"` |
| `thinking` | string | 思维链文本 —— **取决于模型**:仅当模型发出可见/摘要化的 thinking 块时为完整明文;**当 `display:"omitted"` 时为空**(见下注) |
| `signature` | string(base64,数百字符) | 向 API 认证该块的密码学签名 |
```json
{ "type": "thinking", "thinking": "<reasoning text, redacted>", "signature": "<base64 sig, redacted>" }
```

> **Confirmed (official) —— `thinking` 并非总是明文。** 据 Anthropic 的扩展思考文档,
> `display` 参数决定块内落盘的内容:`display:"omitted"` 是 **Opus 4.8/4.7、Fable 5
> 和 Mythos 5 的默认值** —— 对这些模型,`thinking` 字段为 **空(omitted),仅保留
> `signature`**,而 Claude 4 默认 `display:"summarized"`。由于该存储库以
> `claude-opus-4-8` 为主,许多磁盘上的 `thinking` 块可能是 空文本 + signature,而非
> 完整可读的推理
> ([extended-thinking docs](https://platform.claude.com/docs/en/build-with-claude/extended-thinking))。

#### `redacted_thinking` — **磁盘上未观察到**(CC 2.1.x);Anthropic-API 规范形状
| 字段 | 类型 | 含义 |
|---|---|---|
| `type` | string | `"redacted_thinking"` |
| `data` | string(加密 blob) | 客户端无法读取的不透明加密推理 |
```json
{ "type": "redacted_thinking", "data": "<encrypted blob>" }
```

> **Confirmed (official):** `redacted_thinking` 是一个真实的 Anthropic API 内容块。
> 当 Claude 的内部推理被安全系统标记时,thinking 块会被加密并作为 `redacted_thinking`
> 块返回,其 `data` 字段是一个不透明加密 blob,在多轮延续中必须 **原样** 回传。它由
> 安全触发因而罕见,这与它在该 CC 2.1.x 语料中缺失相一致
> ([Bedrock: Claude thinking encryption](https://docs.aws.amazon.com/bedrock/latest/userguide/claude-messages-thinking-encryption.html),
> [extended-thinking docs](https://platform.claude.com/docs/en/build-with-claude/extended-thinking))。

#### `tool_use` — keys `["caller","id","input","name","type"]`
| 字段 | 类型 | 含义 | 是否存在 |
|---|---|---|---|
| `type` | string | `"tool_use"` | always |
| `id` | string (`toolu_…`) | 工具调用 id —— 与之后的 `tool_result.tool_use_id` 的 **连接 key** | always |
| `name` | string | 工具名(`Bash`、`Read`、`Edit`、`Write`、`Glob`、`Grep`、`Agent`、`AskUserQuestion`、`mcp__<server>__<tool>` 等) | always |
| `input` | object | 工具参数(形状取决于工具) | always |
| `caller` | object | 谁调用了工具;`{"type":"direct"}` 是唯一观察到的值(100%) | v2.1.x |
```json
{ "type": "tool_use", "id": "toolu_01PnRi…", "name": "Bash",
  "input": { "command": "<redacted>", "description": "<redacted>" },
  "caller": { "type": "direct" } }
```

### 6.4 User content blocks (Layer 2)

#### `tool_result` — keys `["content","is_error","tool_use_id","type"]` 或(成功)`["content","tool_use_id","type"]`
| 字段 | 类型 | 含义 | 是否存在 |
|---|---|---|---|
| `type` | string | `"tool_result"` | always |
| `tool_use_id` | string (`toolu_…`) | 回连到来源 `tool_use.id` 的 **连接 key** | always |
| `content` | **string OR array** | 结果负载。纯文本时为 String(~99%);需要块时为 array(`text`、`image`、`tool_reference`) | always |
| `is_error` | bool | 工具出错时存在且为 `true`;成功时省略 | optional |
```json
{ "type": "tool_result", "tool_use_id": "toolu_01RmBz…", "content": "<plain text output, redacted>" }
```
```json
{ "type": "tool_result", "content": "<error output, redacted>", "is_error": true, "tool_use_id": "toolu_01RmBz…" }
```
含 **`tool_reference`** 块的数组 content(deferred-tool / “Tool loaded” 列表 ——
每个 `{type:"tool_reference", tool_name}`):
```json
{ "type": "tool_result", "tool_use_id": "toolu_01XXXX",
  "content": [
    { "type": "tool_reference", "tool_name": "mcp__codegraph__codegraph_search" },
    { "type": "tool_reference", "tool_name": "mcp__codegraph__codegraph_explore" } ] }
```
含 **`image`** 块的数组 content(例如截图工具;全库范围在 tool_results 内:11 image、
233 text、127 tool_reference):
```json
{ "tool_use_id": "toolu_01XXXX", "type": "tool_result",
  "content": [ { "type": "image", "source": { "type": "base64", "data": "<base64, redacted>", "media_type": "image/png" } } ] }
```

#### `image` — keys `["source","type"]`(粘贴的图片,或在 tool_result 数组内)
| 字段 | 类型 | 含义 |
|---|---|---|
| `type` | string | `"image"` |
| `source` | object | 图片负载 |
| `source.type` | string | `"base64"`(唯一观察到的值) |
| `source.media_type` | string | `"image/jpeg"`、`"image/png"`、… |
| `source.data` | string | base64 编码的字节 |
```json
{ "type": "image", "source": { "type": "base64", "media_type": "image/jpeg", "data": "<base64-image-bytes, redacted>" } }
```

#### `text`(在 user 数组中)—— 与 assistant `text` 形状相同(`{type:"text", text}`),当一次 user 轮次把文本与其他块混合时。

### 6.5 Attachment subtypes (Layer 3) — full census

信封 = 标准树信封;负载完全在 `.attachment` 内(它总有自己的 `.type`)。带 key-set 的
完整观察枚举:

| `attachment.type` | Key fields |
|---|---|
| `hook_success` | `command, content, durationMs, exitCode, hookEvent, hookName, stderr, stdout, toolUseID, type` |
| `deferred_tools_delta` | `addedNames, addedLines, removedNames, readdedNames, pendingMcpServers*, type`(`pendingMcpServers` 在较新版本中被移除) |
| `skill_listing` | `content, isInitial, names, skillCount, type` |
| `task_reminder` | `content, itemCount, type` |
| `queued_command` | `commandMode, prompt, type` |
| `edited_text_file` | `filename, snippet, type` |
| `mcp_instructions_delta` | `addedBlocks, addedNames, removedNames, type` |
| `hook_additional_context` | `content, hookEvent, hookName, toolUseID, type` |
| `ultra_effort_enter` | `reminderType, type` |
| `goal_status` | `condition, met, sentinel, type` |
| `file` | `content, displayPath, filename, type` |
| `compact_file_reference` | `filename, displayPath, type` |
| `hook_system_message` | `content, hookEvent, hookName, toolUseID, type` |
| `command_permissions` | `allowedTools, type` |
| `agent_listing_delta` | `addedLines, addedTypes, isInitial, removedTypes, showConcurrencyNote, type` |
| `date_change` | `newDate, type` |
| `plan_mode` | `isSubAgent, planExists, planFilePath, reminderType, type` |
| `nested_memory` | `content, displayPath, path, type` |
| `workflow_keyword_request` | `type`(仅此) |
| `invoked_skills` | `skills, type` |
| `plan_mode_exit` | `planExists, planFilePath, type` |
| `plan_file_reference` | `planFilePath, planContent, type` |
| `auto_mode` | `type`(仅此) |

```jsonc
// task_reminder (empty) — note nested .attachment.type vs top-level .type=="attachment"
{"type":"attachment","uuid":"<uuid>","parentUuid":"<uuid>","sessionId":"<uuid>",
 "timestamp":"…","cwd":"<abs>","gitBranch":"main","version":"2.1.183","userType":"external",
 "entrypoint":"cli","isSidechain":false,
 "attachment":{"type":"task_reminder","content":[],"itemCount":0}}
```
```jsonc
// hook_success
{"type":"attachment", …envelope…,
 "attachment":{"type":"hook_success","hookName":"<hook>","hookEvent":"PostToolUse",
   "command":"<cmd>","stdout":"<…>","stderr":"","exitCode":0,"durationMs":123,"toolUseID":"toolu_…"}}
```

> 两个适配器都完全跳过 `attachment`(注释见 `claude-code.ts:22-25`),因此这 24 个子类型
> **没有一个被 Engram 浮现**。

### 6.6 `system` records (discriminated by `.subtype`)

全部携带标准信封(大多数携带 `uuid`/`parentUuid`/`isMeta`)。

| `subtype` | Distinctive keys | Meaning |
|---|---|---|
| `turn_duration` | `durationMs, messageCount, pendingWorkflowCount` | 一个已完成轮次的挂钟时间 |
| `stop_hook_summary` | `hookCount, hookErrors, hookInfos, hookAdditionalContext, hasOutput, preventedContinuation, stopReason, toolUseID, level` | Stop-hook 执行的摘要 |
| `away_summary` | `content` | 用户“离开”时写入的摘要 |
| `api_error` | `error, cause, maxRetries, retryAttempt, retryInMs, level` | API 失败 + 重试状态 |
| `scheduled_task_fire` | `content` | 一个计划任务触发了 |
| `local_command` | `content, level` | 本地斜杠命令调用回显 |
| `compact_boundary` | `compactMetadata, logicalParentUuid, content, level` | 标记一次上下文 compaction(见 §11) |
| `bridge_status` | `content, url` | 桥接(desktop↔cli)状态 |
| `informational` | `content, level, slug` | 通用信息通知 |
| `model_refusal_fallback` | `apiRefusalCategory, apiRefusalExplanation, originalModel, fallbackModel, trigger, direction, requestId, content, level` | 模型拒绝 → 回退到另一个模型 |

观察到的 `.level` 取值:`error`、`warning`、`suggestion`、`info`(常缺失)。

---

## 7. Tool calls & results

### 7.1 The call ↔ result linkage model

链接是 **`tool_use.id`(assistant content 块)⇒ `tool_result.tool_use_id`(user content
块)**。在主文件中已验证:786 个唯一 `tool_use.id`、786 个唯一 `tool_use_id` 引用、
**786 个匹配(100%)**。此外,user `tool_result` 记录在信封层面携带
`sourceToolAssistantUUID`,回指发出该调用的 assistant **记录** `uuid`。

匹配的 `tool_result` 块位于一条 **`type:"user"` 记录** 内(工具的输出作为一次 user
轮次折叠回对话中)。

### 7.2 Id namespaces (distinct prefixes)

| Id | Prefix | Where |
|---|---|---|
| assistant message id | `msg_…` | `message.id` |
| tool call | `toolu_…` | `tool_use.id` ⇒ `tool_result.tool_use_id` |
| API request | `req_…` | `requestId` |
| record identity | bare UUID | `uuid` / `parentUuid` / `sessionId` |
| user prompt grouping | `prompt_…` | `promptId` |
| subagent | 不透明(通常 17-hex;有时 `<label>-<hex>`) | `agentId` |
| cloud bridge | `cse_…` | `bridge-session.bridgeSessionId` |

### 7.3 The `toolUseResult` envelope mirror (raw exec result)

在 tool_result user 记录上,`toolUseResult` 镜像了结构化的原始结果。形状 **随工具而变**。
观察到的 key-set:

| Tool | `toolUseResult` shape |
|---|---|
| Bash | `{stdout, stderr, interrupted, isImage, noOutputExpected}`(基础);按调用追加的 **变体 keys**:`backgroundTaskId`、`dangerouslyDisableSandbox`、`gitOperation`、`returnCodeInterpretation`、`assistantAutoBackgrounded`、`staleReadFileStateHint`、`persistedOutputPath`/`persistedOutputSize` |
| Edit | `{filePath, oldString, newString, originalFile, replaceAll, structuredPatch, userModified}` |
| Write | `{type:"create"\|"update", content, filePath, originalFile, structuredPatch, userModified}` |
| Read | `{type, file}` |
| AskUserQuestion | `{questions, answers, annotations}`(也有 2-key 的 `{questions, answers}` 变体) |
| **Agent**(subagent 结果) | `{agentId, agentType, status, content, prompt, totalTokens, totalToolUseCount, totalDurationMs, toolStats, usage{…full usage…}}`(+ 可选 `resolvedModel`)—— **携带 subagent 的完整 token/cost 总计** |
| TaskUpdate | `{statusChange, success, taskId, updatedFields}`(也有 `{success, taskId, updatedFields}` / `{error, success, taskId, updatedFields}`) |
| TaskGet | `{task}`(也有 `{retrieval_status, task}`) |
| ToolSearch | `{matches, query, total_deferred_tools}` |
| workflow | `{runId, scriptPath, status, summary, taskId, transcriptDir, workflowName}`(+ 可选 `taskType`) |

(`type:"create"\|"update"` 正是指针列表中的 `create` 实际所在之处 —— 它是
`toolUseResult.type`,而非记录/块类型。)

> **⚠️ Subagent token 总计被镜像进 PARENT 转录。** `Agent` 工具的 `toolUseResult`
> 携带一个 **完整的嵌套 `usage` 对象**(与 `message.usage` 相同的 10 个 keys,
> 包括 `iterations` 和 `cache_creation`),外加 `totalTokens`、`totalToolUseCount`
> 和 `totalDurationMs`。这意味着一个 subagent 的 token/cost 总计 **仅凭父级 `.jsonl`
> 即可恢复** —— 你不必打开 subagent 自己的 `subagents/agent-*.jsonl` 来归因其成本。
> Engram 完全丢弃 `toolUseResult`(见 §5 覆盖缺口),因此父级侧和文件侧的 subagent
> 总计目前都未被捕获。真实样本(匿名化):`agentType:"codex:codex-rescue"`、
> `status:"completed"`、`totalTokens:19756`;`usage` keys =
> `[cache_creation, cache_creation_input_tokens, cache_read_input_tokens,
> inference_geo, input_tokens, iterations, output_tokens, server_tool_use,
> service_tier, speed]`。

```json
{ "agentId": "a4e5796f79594d4d0", "agentType": "general-purpose", "status": "completed",
  "prompt": "<dispatched task prompt, redacted>", "content": "<subagent final report, redacted>",
  "totalDurationMs": 412380, "totalTokens": 139887, "totalToolUseCount": 37,
  "toolStats": { "Bash": 12, "Read": 18, "Edit": 7 },
  "resolvedModel": "claude-sonnet-4-6",
  "usage": { "input_tokens": 8849, "output_tokens": 3458, "cache_read_input_tokens": 0,
    "cache_creation_input_tokens": 28933,
    "cache_creation": { "ephemeral_1h_input_tokens": 28933, "ephemeral_5m_input_tokens": 0 },
    "server_tool_use": { "web_search_requests": 0, "web_fetch_requests": 0 },
    "service_tier": "standard", "inference_geo": "not_available",
    "iterations": [ { "input_tokens": 8849, "output_tokens": 3458, "type": "message" } ], "speed": "standard" } }
```

### 7.4 MCP and shell tool shapes

- **MCP 工具** 表现为 `tool_use.name == "mcp__<server>__<tool>"`(例如
  `mcp__codegraph__codegraph_search`)。assistant 记录还可能携带
  `attributionMcpServer`/`attributionMcpTool`。
- **Shell** 工具是 `name == "Bash"`,带 `input.command` + `input.description`;
  Bash 的 `toolUseResult` 携带 `stdout`/`stderr`/`interrupted`。
- **大工具输出** 溢出到 `<uuid>/tool-results/<id>.txt`(见 §2.6),从转录中引用而非内联。

### 7.5 Engram tool handling

`streamMessages` 把 content 含 `tool_result` 的 `user` 记录重分类为 `role:"tool"`
(TS `claude-code.ts:232-235`;Swift `ClaudeCodeAdapter.swift:361-365`)。`tool_use`
块被摘要化(`` `name`: summary ``);**噪声工具集** 被整体丢弃:`ToolSearch,
ExitPlanMode, EnterPlanMode, Skill, TodoWrite, TodoRead, TaskCreate, TaskUpdate,
TaskGet, TaskList`(TS `:376-387`;Swift `:434-445`)。`tool_result` content 大多被
丢弃(仅当以 `"User has answered"` 开头时保留)。`tool_reference` 块和
`text === "Tool loaded."` 作为噪声被过滤。

---

## 8. Reasoning / thinking

推理被存储为 assistant `message.content[]` 内的一个 **`thinking` 内容块**(§6.3):

| 字段 | 类型 | 含义 |
|---|---|---|
| `thinking` | string | 思维链文本 —— **仅当块为可见/摘要化时磁盘上为明文;当 `display:"omitted"` 时为空**(取决于模型,见下) |
| `signature` | string(base64) | 在重放时向 Anthropic API 认证该块的密码学签名 |

> **Confirmed (official) —— thinking 文本取决于模型,并非总是明文。**
> `display:"omitted"` 是 Opus 4.8/4.7、Fable 5 和 Mythos 5 的默认值,因此对这些模型
> `thinking` 字段为空(只保留 `signature`);Claude 4 默认 `display:"summarized"`。
> `signature` 是“完整思考过程的加密签名”,用于在块被回传以支持多轮延续与工具调用循环
> 时验证/重建 thinking。由于该存储库以 `claude-opus-4-8` 为主,预期许多 `thinking`
> 块为 空文本 + signature,而非完整推理
> ([extended-thinking docs](https://platform.claude.com/docs/en/build-with-claude/extended-thinking))。

- **`redacted_thinking`**(加密的 thinking,字段 `data`)是客户端无法读取的内容的
  Anthropic-API 形状。它是一个 **真实的、由安全触发的 API 块**(已确认 —— 见 §6.3),
  但在这份 CC 2.1.x 语料中任何地方 **都未观察到它作为活跃块**。
- Claude Code 的格式中 **没有单独的“推理摘要”记录** —— legacy 的 `type:"summary"`
  记录(本应持有带 `leafUuid` 的 compaction 摘要)在该存储库中不存在;现代 compaction
  使用 `system/compact_boundary` + 一条 `isCompactSummary` user 消息(§11)。
- **Engram 处理:** `thinking` 仅在记录没有 `text`/`tool_use`/`tool_result` 块时作为
  **兜底** 使用(TS `extractContent` `claude-code.ts:350-370`;Swift `:411-431`)。
  `signature` 被读取但 **丢弃**。

---

## 9. Token usage & cost

### 9.1 Where usage lives

每条 `assistant` 记录下的 `message.usage`。两种形状:一种 **完整** 形状和一种
**legacy/精简** 形状(缺少 `iterations`、`server_tool_use`、`speed`)。

| `usage` 字段 | 类型 | 含义 | 被 Engram 求和? | 示例 |
|---|---|---|:---:|---|
| `input_tokens` | int | 未缓存的 prompt tokens | ✅ | `8849` |
| `output_tokens` | int | 生成的 tokens | ✅ | `3458` |
| `cache_read_input_tokens` | int | 从 prompt 缓存服务的 tokens | ✅ | `0` |
| `cache_creation_input_tokens` | int | 本轮写入缓存的 tokens | ✅ | `28933` |
| `cache_creation` | object | 按 TTL 拆分的缓存写入:`{ephemeral_5m_input_tokens, ephemeral_1h_input_tokens}` | ❌ | `{"ephemeral_1h_input_tokens":28933,"ephemeral_5m_input_tokens":0}` |
| `server_tool_use` | object | `{web_search_requests, web_fetch_requests}` | ❌ | `{"web_search_requests":0,"web_fetch_requests":0}` |
| `service_tier` | string\|null | `"standard"` / `"batch"` / null | ❌ | `"standard"` |
| `inference_geo` | string\|null | 推理区域标记;磁盘上取 `"not_available"`、`""`(空字符串)、`null`,或在精简形状中 **缺失** —— 在其上分支的解析器必须处理全部四种 | ❌ | `"not_available"` |
| `speed` | string\|null | 延迟/速度档位 | ❌ | `"standard"` |
| `iterations` | array\|null | 一次 agentic 请求的逐迭代 usage 拆分;每个元素镜像顶层 token 字段 + `cache_creation` + `type:"message"` | ❌ | `[{input_tokens, output_tokens, cache_read_input_tokens, cache_creation_input_tokens, cache_creation, type:"message"}]` |

```json
{
  "input_tokens": 8849,
  "cache_creation_input_tokens": 28933,
  "cache_read_input_tokens": 0,
  "output_tokens": 3458,
  "server_tool_use": { "web_search_requests": 0, "web_fetch_requests": 0 },
  "service_tier": "standard",
  "cache_creation": { "ephemeral_1h_input_tokens": 28933, "ephemeral_5m_input_tokens": 0 },
  "inference_geo": "not_available",
  "iterations": [ { "input_tokens": 8849, "output_tokens": 3458, "cache_read_input_tokens": 0,
                    "cache_creation_input_tokens": 28933,
                    "cache_creation": { "ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": 28933 },
                    "type": "message" } ],
  "speed": "standard"
}
```

### 9.2 Accounting rules

- **`<synthetic>` 模型:** 系统注入的 assistant 消息携带 `model:"<synthetic>"` 和一个
  全零 usage 对象 → 0 成本(无匹配价格)。
- **`iterations` 双计风险:** 该数组按 API 迭代重复了顶层数字。Engram 只对 **顶层**
  字段求和,因此不会双计 —— 但未来若有改动去读 `iterations` 则会高估。
- **逐记录模型:** subagent 经常运行与父级 **不同的模型**(观察到父级
  `claude-opus-4-8`,subagent `claude-sonnet-4-6` / `claude-haiku-4-5`)。
  **成本必须按记录从 `message.model` 计算**,绝不能从父会话的模型继承。

### 9.3 How Engram sums & prices

**提取** —— Engram 的 `TokenUsage` 仅消费约 10 个 usage 字段中的 4 个:
- TS `streamMessages`(`claude-code.ts:247-256`):`input_tokens`、`output_tokens`、
  `cache_read_input_tokens`、`cache_creation_input_tokens`。
- Swift `JSONLAdapterSupport.usage(from:)`,定义于 `CodexAdapter.swift:220-228`,
  由 `ClaudeCodeAdapter` 共享(在 `:371` 调用):相同的 4 个字段。它 **丢弃**
  `cache_creation{}`、`server_tool_use{}`、`service_tier`、`inference_geo`、
  `iterations`、`speed`,以及 `stop_details`/`diagnostics`。

**累加**(TS `src/core/indexer.ts`)—— 按会话(或按 subagent,以 `agentId` 为 key):
```
acc.inputTokens         += usage.inputTokens
acc.outputTokens        += usage.outputTokens
acc.cacheReadTokens     += usage.cacheReadTokens ?? 0
acc.cacheCreationTokens += usage.cacheCreationTokens ?? 0
```
即便 token 为零也会写入一行 `session_costs`;`cost = computeCost(model, …)`。

**定价**(`src/core/pricing.ts`):`ModelPrice = {input, output, cacheRead,
cacheWrite}`,以 USD-per-1M tokens 计。`getModelPrice`(`pricing.ts:56`)按以下顺序
解析:(1) 自定义精确、(2) 内置精确、(3) **最长前缀** 匹配(`pricing.ts:66-67`,
所以 `claude-sonnet-4-5-20250929 → claude-sonnet-4-5`)、(4) 自定义前缀。未知模型 →
`undefined` → 成本 `0`。
```
cost = input/1e6 * price.input
     + output/1e6 * price.output
     + cacheRead/1e6 * price.cacheRead
     + cacheCreation/1e6 * price.cacheWrite   // cacheWrite == cache_creation price
```

| model | input | output | cacheRead | cacheWrite | pricing.ts line |
|---|---|---|---|---|---|
| claude-opus-4-6 | 15 | 75 | 1.5 | 18.75 | `:9` |
| claude-sonnet-4-6 | 3 | 15 | 0.3 | 3.75 | `:15` |
| claude-sonnet-4-5 | 3 | 15 | 0.3 | 3.75 | `:21` |
| claude-haiku-4-5 | 0.8 | 4 | 0.08 | 1 | `:27` |

> **⚠️ 定价陈旧(已验证 —— 影响三个当前模型,而非一个)。** `getModelPrice` 先按精确
> key 再按 **最长前缀** 匹配;任何其精确或最长前缀 key 在 `pricing.ts` 中 **缺失** 的
> 模型都会落到 `undefined` → **成本 `0`**。`pricing.ts` 当前只有
> `claude-opus-4-6`、`claude-sonnet-4-6`、`claude-sonnet-4-5`、`claude-haiku-4-5`。
> 该用户 **实际的磁盘模型集合**(跨 `engram`/`glm-coding`/`polycli`/`mediahub`
> 存储库的普查)是:
>
> | model on disk | records | in pricing.ts? | prices at |
> |---|---:|---|---|
> | `claude-opus-4-8` | 21541 | **no**(无前缀匹配 —— `opus-4-6` ≠ `opus-4-8`) | **$0** |
> | `claude-opus-4-7` | 2070 | **no**(无前缀匹配) | **$0** |
> | `claude-fable-5` | 156 | **no**(无前缀匹配) | **$0** |
> | `<synthetic>` | 52 | n/a(全零 usage) | $0(正确) |
>
> 所以 **`claude-opus-4-8`、`claude-opus-4-7`、以及 `claude-fable-5` 在当前表格下
> 全部计价为 $0** —— 这是横跨该用户三个活跃生产模型的真实成本低估,而不仅仅是主模型。
> 注意历史上的 `claude-sonnet-4-6` / `claude-haiku-4-5`(被某些 subagent 使用)**确实**
> 能解析并被正确计价;缺口具体在于 `opus-4-7`、`opus-4-8` 和 `fable-5` 这几代。

> **关于 `claude-usage-probe.ts` 的说明。** 这个文件 **不是** 逐消息 token 提取器 ——
> 它是一个实时配额探针(`ClaudeUsageProbe`),在 `~/.claude/usage.json` 存在时读取它,
> 否则在 headless tmux 中运行 `claude /usage` 并把 `… : NN%` 行抓取进 `UsageSnapshot`
> 指标(`claude-usage-probe.ts:18-157`)。在该存储库中 `~/.claude/usage.json` 不存在,
> 因此它会回退到 tmux 探针。逐消息 token 计算位于适配器 + `indexer.ts` + `pricing.ts`。

---

## 10. Subagent / parent-child / dispatch

### 10.1 The dispatch record (parent transcript)

一个 subagent 由一条含名为 **`Agent`** 的 `tool_use` 内容块的 `assistant` 记录派生
(当前 2.1.x;legacy 名称 `Task`,于 v2.1.63 重命名 —— 据官方文档,`Task(...)`
引用仍作为别名有效)。

> **命名修正。** dispatch 工具是 **`Agent`**,不是 `Task`。`Task*` 字符串
> (`TaskCreate`、`TaskList`、`TaskGet`、`TaskUpdate`、`TaskStop`、`TaskOutput`)是
> **后台任务/todo MCP 工具集**,与 subagent 无关。(两个适配器的 `summarizeToolInput`
> 处理 `name == "Agent"` → `input.description`:TS `claude-code.ts:458`;Swift `:521-522`。)
>
> **Confirmed (official):** Task 工具在 **Claude Code v2.1.63** 重命名为 `Agent`;
> 设置和 agent 定义中现有的 `Task(...)` 引用仍作为别名有效,且该工具名支持嵌套
> subagent(一个 subagent 可派生它自己的 subagent)
> ([sub-agents docs](https://code.claude.com/docs/en/sub-agents))。

| `tool_use` 字段 | 类型 | 含义 | 示例 |
|---|---|---|---|
| `type` | string | 总是 `"tool_use"` | `"tool_use"` |
| `id` | string (`toolu_…`) | tool-use id;等于 subagent 的 `meta.json` `toolUseId` | `"toolu_014RWAea4dPmkLdEossEV1ez"` |
| `name` | string | dispatch 工具名 | `"Agent"`(legacy `"Task"`,v2.1.63 重命名) |
| `input.description` | string | 简短任务标签 | `"Privacy data flow audit"` |
| `input.prompt` | string | 交给 subagent 的完整任务 prompt | `"<task instructions…>"` |
| `input.subagent_type` | string | 要运行哪个 agent persona | `"privacy"`, `"general-purpose"`, `"hallucination"` |
| `input.run_in_background` | bool? | 仅在后台运行的 subagent 上存在 | `true` |

```json
{ "type": "assistant",
  "message": { "role": "assistant", "model": "claude-opus-4-8",
    "content": [
      { "type": "text", "text": "<assistant reasoning>" },
      { "type": "tool_use", "id": "toolu_014RWAea4dPmkLdEossEV1ez", "name": "Agent",
        "input": { "description": "Privacy data flow audit", "prompt": "<full subagent prompt — anonymized>",
                   "subagent_type": "privacy" } } ] } }
```

subagent 的最终报告稍后作为一条 `type:"user"` 记录返回,其 `message.content[]` 持有一个
带匹配 `tool_use_id` 的 `tool_result` 块。

### 10.2 The subagent sidecar metadata (`agent-<id>.meta.json`)

| 字段 | 类型 | 含义 | 示例 |
|---|---|---|---|
| `agentType` | string | subagent 类型(镜像 `subagent_type`) | `"i18n"`, `"general-purpose"`, `"codex:codex-rescue"`, `"workflow-subagent"` |
| `description` | string | 简短人类标签(镜像 `Agent` 工具的 `description`) | `"i18n localization audit"` |
| `toolUseId` | string (`toolu_…`) | **父级** 转录中派生它的 `Agent`/`Task` `tool_use.id` | `"toolu_012oNrmxfmS4FUXjp7fefEKN"` |

> **`meta.json` 有两种形状。** (1) 直接 subagent 的 **完整** `{agentType, description,
> toolUseId}`(有些还加 `name`,极少加 `worktreePath` /
> `color`/`model`/`permissionMode`/`planModeRequired`/`taskKind`/`teamName`)。
> (2) **工作流嵌套** subagent 的 **仅 `{agentType}`** 最小形状
> (`agentType:"workflow-subagent"`),它们位于 `subagents/workflows/wf_*/` 下。
> 最小形状没有 `toolUseId`,因此下面的 dispatch 连接 key 不适用于工作流嵌套 subagent。

```json
{"agentType":"i18n","description":"i18n localization audit","toolUseId":"toolu_012oNrmxfmS4FUXjp7fefEKN"}
```
```json
{"agentType":"workflow-subagent"}
```

对于完整形状,这就是 **dispatch ↔ subagent 连接 key**:父级 `tool_use.id` == meta
`toolUseId`,且 meta 紧邻 `agent-<agentId>.jsonl`。已验证的链条:
父级 `Agent` 块 `id=toolu_…` → `subagents/agent-<id>.meta.json`(`toolUseId` 匹配,
`agentType:"privacy"`)→ `subagents/agent-<id>.jsonl`。

### 10.3 The subagent transcript (`agent-<id>.jsonl`)

一个由 `user`/`assistant` 记录组成的普通只追加 JSONL —— 形状与顶层会话相同 —— 但每行
都携带 `isSidechain:true` 和一个 `agentId`。

| 区分 subagent 的字段 | 类型 | 含义 |
|---|---|---|
| `agentId` | string(不透明) | 等于文件名 `agentId`;Engram 对该 subagent 的 **唯一 DB id**。**通常** 17 字符十六进制(`a784b50f9fbfb258b`),但工作流/provider review subagent 使用 `<label>-<hex>` 形式(`akimi-review-…` 长 29、`aagy-review-…` 长 28)—— 绝不假设固定长度或纯十六进制 |
| `isSidechain` | bool | subagent 文件内 **总是 `true`** |
| `sessionId` | string | **父级的** sessionId(共享) |
| `attributionAgent` | string | (assistant 记录)哪个 persona 产生了该轮次(镜像 `agentType`) |
| `parentUuid` | string\|null | 第一行为 `null`(一个全新的 sidechain 链根) |

```json
{"parentUuid":null,"isSidechain":true,"promptId":"d7d35fa2-…","agentId":"a784b50f9fbfb258b","type":"user",
 "message":{"role":"user","content":"<dispatched task prompt — anonymized>"},"sessionId":"477f5790-…",
 "cwd":"<cwd>","gitBranch":"<branch>","version":"2.1.156","userType":"external","entrypoint":"cli",
 "uuid":"<uuid>","timestamp":"<iso8601>"}
```

### 10.4 `isSidechain` semantics

| value | where | meaning |
|---|---|---|
| `false` | 顶层会话记录(含 `isCompactSummary` user 消息) | 主对话线程 |
| `true` | `subagents/agent-*.jsonl` 内的每条记录 | subagent/sidechain 线程;不属于主可见转录 |

`isSidechain` 是 **运行时** 标记,但 **Engram 不读取它** —— 它纯粹从 **包含
`/subagents/` 的文件路径** 推断“subagent”(TS `claude-code.ts:143`;Swift
`ClaudeCodeAdapter.swift:149`)。

### 10.5 Parent linkage derivation (Engram "Layer 1")

两个适配器都从 `subagents/` **紧前** 的路径段(以父会话命名的目录)提取父 UUID。
确定性,无启发式:
- **TS**(`claude-code.ts:151`):正则 `/\/([^/]+)\/subagents\/[^/]+\.jsonl$/`。
- **Swift**(`ClaudeCodeAdapter.swift:528-536`,`parentSessionId(from:)`):按 `/`
  切分,找到 `subagents` 索引,返回 `parts[subagentsIndex - 1]`。

两者都设置 `agentRole:"subagent"` 和 `parentSessionId = <parent-uuid>`。

> **⚠️ 已验证的发现缺口(以磁盘真实情况为准)。** 两个适配器只枚举 `subagents/` 的
> **直接** 子项(TS 正则要求 `subagents/<file>.jsonl`;Swift 在 `:40-43` 遍历
> `directChildren(of: subagents)`)。真实存储库还包含
> **`subagents/workflows/wf_<id>/agent-*.jsonl`**。在一个采样会话中:
> **1 个直接** vs **14 个工作流嵌套** subagent 文件 —— 该会话约 93% 的 subagent
> **从未被索引**。(Swift 的 `parentSessionId(from:)` 算法 *本可* 处理嵌套路径,
> 但文件从未被发现。)`workflows/<wf>/journal.jsonl` 同样未被索引。

### 10.6 Subagent tier (always skip)

Engram 把每个 subagent(`agentRole != nil`,或路径含 `/subagents/`)分层为 **`skip`**
(`SessionTier.swift`):从列表中隐藏、从关键词搜索中排除、不具备 embedding 资格。
subagent 内容通过父级访问。这与项目规则“不要提升 subagent 层级”一致。

---

## 11. Summary / compaction

### 11.1 Modern form (what actually exists, CC 2.1.x)

> **Confirmed (community reverse-engineering):** 一次 compaction 恰好是两条相邻的
> JSONL 行 —— 一条 `subtype:"compact_boundary"` 的 `system` 记录,携带
> `compactMetadata`(其中 `trigger` = `manual` 对应 `/compact`,`auto` 对应上下文
> 上限,外加 compaction 前的 token 计数与时长/保留细节),紧随其后是一条
> `isCompactSummary:true` 的 `user` 记录,持有成为新上下文头部的结构化摘要。完整的
> compact 前记录保留在文件中
> ([claude-compaction-viewer](https://github.com/swyxio/claude-compaction-viewer),
> [ClaudeWorld session-storage](https://claude-world.com/tutorials/s16-session-storage/),
> [trajectory-compression](https://kenhuangus.substack.com/p/chapter-5-trajectory-compression))。

两条记录夹住一次 compaction:

**(a) `type:"system"`, `subtype:"compact_boundary"`** —— 携带 `compactMetadata` 的
边界标记:

| top-level field | Type | Meaning | Example |
|---|---|---|---|
| `type` | string | `"system"` | `"system"` |
| `subtype` | string | `"compact_boundary"` | `"compact_boundary"` |
| `level` | string | 日志级别 | `"info"` |
| `content` | string | 固定横幅文本 | `"Conversation compacted"` |
| `logicalParentUuid` | string | 跨边界的链修复指针 | `"<uuid>"` |
| `compactMetadata` | object | compaction 遥测(见下) | — |

**`compactMetadata` 嵌套对象:**

| 字段 | 类型 | 含义 | 示例 |
|---|---|---|---|
| `trigger` | string | `"manual"`(用户 `/compact`)或 `"auto"`(上下文上限) | `"manual"` |
| `preTokens` | int | compaction **之前** 的总 token | `541747` |
| `postTokens` | int | compaction **之后** 的总 token | `7961` |
| `durationMs` | int | compaction 操作的挂钟时间 | `118348` |
| `preCompactDiscoveredTools` | string[] | compact 前可用的工具(为连续性而保留) | `["Monitor","TaskList","mcp__codegraph__codegraph_search"]` |
| `preservedSegment` | object | `{headUuid, anchorUuid, tailUuid}` —— 逐字保留的活跃尾部 | — |
| `preservedMessages` | object | `{anchorUuid, uuids:[…], allUuids:[…]}` —— 保留可见的子集(`uuids`)vs 含中间工具轮次的完整段(`allUuids`) | — |

```json
{
  "type": "system", "subtype": "compact_boundary", "level": "info",
  "content": "Conversation compacted", "logicalParentUuid": "<uuid>",
  "compactMetadata": {
    "trigger": "manual", "preTokens": 541747, "postTokens": 7961, "durationMs": 118348,
    "preCompactDiscoveredTools": ["Monitor","TaskList","mcp__codegraph__codegraph_search"],
    "preservedSegment": {"headUuid":"<u1>","anchorUuid":"<u2>","tailUuid":"<u3>"},
    "preservedMessages": {"anchorUuid":"<u2>","uuids":["<u1>","<u2>","<u3>"],"allUuids":["<u1>","…","<u3>"]}
  },
  "sessionId": "<uuid>", "version": "2.1.156", "uuid": "<uuid>", "timestamp": "<iso8601>"
}
```

**(b) `type:"user"`, `isCompactSummary:true`** —— 成为新对话头部的合成摘要:

| 字段 | 类型 | 含义 |
|---|---|---|
| `type` | `"user"` | 伪装成一次 user 轮次 |
| `isCompactSummary` | bool `true` | 标记该 user 轮次为合成摘要 |
| `isVisibleInTranscriptOnly` | bool | 在转录中显示,从 API 上下文排除 |
| `uuid` | uuid | 等于 `compactMetadata.preservedSegment.anchorUuid` |
| `parentUuid` | uuid | 指回 **compact 前** 的历史(链保持完整) |
| `message.content` | string | LLM 生成的摘要文本(观察到约 13 KB) |
| `compactMetadata` | null | **本记录上为 null**(位于 system 记录上) |

```json
{ "type": "user", "uuid": "659dea2b-…", "parentUuid": "2cdf8b72-…",
  "isCompactSummary": true, "isVisibleInTranscriptOnly": true,
  "message": { "role": "user", "content": "…generated summary…" } }
```

### 11.2 How sessions continue across compaction

compaction **修剪的是模型的上下文窗口,而非磁盘上的记录流**。compact 前的记录仍留在
同一文件中、位于摘要 *之上*;`parentUuid` 连续性(以及 system 记录上的
`logicalParentUuid`)使链保持可追踪。对话继续追加到同一个 `<session-uuid>.jsonl`。

存储库统计(146 个文件):`isCompactSummary` 出现在 28 个文件中,`compactMetadata`
出现在 27 个中,触发器为 33 manual / 1 auto。

### 11.3 Legacy form (documented, absent here)

指针描述的记录 `{"type":"summary","summary":"…","leafUuid":"<uuid>"}` 是更旧的
Claude Code compaction 产物(`leafUuid` = 该摘要所替代的最后一条真实消息)。在该存储库中
**零次出现**。列在两个适配器的跳过注释中(`claude-code.ts:23`)但从未被解析。

> **Confirmed (community reverse-engineering) —— 确切的 legacy schema。** 多个独立
> 写作确认了本文档所述的形状:`{"type":"summary","summary":"<title/text>","leafUuid":"<uuid>"}`。
> 该 `summary` 记录是一个 **compaction 检查点**;`leafUuid` 指向被压缩段的叶子(最近)
> 消息,以便重放能向后遍历链并跨越边界拼接。它在 CC 2.1.x 存储库中仍然缺失(现代
> compaction 使用 `compact_boundary` + `isCompactSummary`),因此该 schema 由社区来源
> 确认,而非此处的新鲜磁盘观察
> ([ClaudeWorld session-storage](https://claude-world.com/tutorials/s16-session-storage/),
> [Inside Claude Code](https://databunny.medium.com/inside-claude-code-the-session-file-format-and-how-to-inspect-it-b9998e66d56b),
> [Parsing JSONL session logs](https://medium.com/@ywian/what-i-learned-parsing-claude-codes-jsonl-session-logs-268248be0a2c),
> [trajectory-compression](https://kenhuangus.substack.com/p/chapter-5-trajectory-compression))。

### 11.4 Engram blind spot

`MESSAGE_TYPES = {user, assistant}` 在层级逻辑中跳过两条 compaction 记录,**但**
`isCompactSummary` 记录是 `type:"user"`,因此它 **会** 被计为一条 user 消息 —— 而且
若它是第一条 user 行,其约 13 KB 的内容可能成为 `firstUserText`/`summary`。
`system/compact_boundary` 记录(及其丰富的 `preTokens`/`postTokens` 遥测)**从未被
索引** —— Engram 没有 compaction 事件或 token 节省的概念。

---

## 12. SQLite stores — N/A for Claude Code

**Claude Code 没有 SQLite 会话存储。** 它的整个磁盘格式就是只追加 JSONL 文件 + JSON
sidecar(本整篇文档)。没有按会话、rollout-vs-DB、或活跃/legacy DB 架构可供描述。

(本节存在是因为文档大纲为 Codex 格式保留了它,而 Codex *确实* 使用 SQLite。对于
Claude Code 它明确不适用。)

---

## 13. Auxiliary files

会话转录之外的文件,有的在 `projects/` 内,有的是全局的。

### 13.1 `sessions-index.json` (per-project sidecar)

为 `/resume` 选择器预计算的目录。**罕见**(在约 80 个项目目录中仅 2 个找到)且
**不会被垃圾回收**(在 `.jsonl` 被删后,陈旧的 `fullPath` 条目仍持续存在)。
**两个适配器都不读取它** —— 它们遍历目录并直接读取每条记录的权威字段。

顶层:`{version:int, entries:[…]}`。逐条:

| 字段 | 类型 | 含义 | 示例 |
|---|---|---|---|
| `sessionId` | string (uuid) | 会话 UUID | `6d45d1e7-…` |
| `fullPath` | string | `.jsonl` 的绝对路径 | `/Users/…/projects/-/6d45d1e7-….jsonl` |
| `fileMtime` | int(epoch ms) | 索引时的文件 mtime | `1771494977955` |
| `firstPrompt` | string | 第一条 user prompt,截断(约 200 字符) | `"<first prompt>"` |
| `messageCount` | int | 消息数快照 | `2` |
| `created` | string (ISO 8601) | 会话创建时间 | `2026-02-19T09:53:20.037Z` |
| `modified` | string (ISO 8601) | 最后修改时间 | `2026-02-19T09:56:17.931Z` |
| `gitBranch` | string | Git 分支(可能为 `""`) | `""` |
| `projectPath` | string | 真实的 cwd / 项目路径 | `/Users/bing/lobsterai/project` |
| `isSidechain` | bool | 该会话是否为 sidechain | `false` |

```json
{ "version": 1, "entries": [
  { "sessionId": "<uuid>", "fullPath": "/Users/.../projects/-/<uuid>.jsonl",
    "fileMtime": 1771494977955, "firstPrompt": "<first user prompt, truncated>",
    "messageCount": 2, "created": "2026-02-19T09:53:20.037Z", "modified": "2026-02-19T09:56:17.931Z",
    "gitBranch": "", "projectPath": "/", "isSidechain": false } ] }
```

### 13.2 `~/.claude/history.jsonl` (global cross-project prompt history)

每行一个 JSON 对象,只追加,**不是** 按会话 —— 它支撑 prompt 历史/回溯。**已验证形状**
(修正了较早研究轮次的一个猜测):

| 字段 | 类型 | 含义 | 示例 |
|---|---|---|---|
| `display` | string | 键入的 prompt 文本(含斜杠命令) | `"/ljg-explain-words Serendipity"` |
| `pastedContents` | object | 该 prompt 粘贴附件的映射(通常 `{}`) | `{}` |
| `timestamp` | int(epoch ms) | prompt 输入的时间 | `1765606729001` |
| `project` | string | 真实的项目 cwd | `/Users/bing/-Code-/TSLin` |
| `sessionId` | string (uuid) | prompt 所属的会话 | `118235ea-…` |

```json
{"display":"<prompt text>","pastedContents":{},"timestamp":1765606729001,
 "project":"/Users/bing/-Code-/TSLin","sessionId":"118235ea-9fd6-459a-a3af-4584f16ec4de"}
```

Engram 不消费它。

### 13.3 `~/.claude/sessions/<pid>.json` (live process registry)

每个运行中的 CLI 进程一个文件,随状态变化 **在原地重写**(不同于只追加的转录)。
把运行中的 pid → 其活动 `sessionId` 映射起来。

| 字段 | 类型 | 示例 |
|---|---|---|
| `pid` | int | `11844` |
| `sessionId` | string (uuid) | `45031c3c-…` |
| `cwd` | string | `/Users/bing/-Code-/AI-Panel` |
| `startedAt` | int(epoch ms) | `1781927597951` |
| `procStart` | string | `"Sat Jun 20 03:53:16 2026"` |
| `version` | string | `"2.1.183"` |
| `peerProtocol` | int | `1` |
| `kind` | string | `"interactive"` |
| `entrypoint` | string | `"cli"` |
| `status` | string | `"busy"` / `"idle"` |
| `updatedAt` / `statusUpdatedAt` | int(epoch ms) | `1782032951209` |

```json
{"pid":11844,"sessionId":"45031c3c-…","cwd":"/Users/bing/-Code-/AI-Panel",
 "startedAt":1781927597951,"procStart":"Sat Jun 20 03:53:16 2026","version":"2.1.183",
 "peerProtocol":1,"kind":"interactive","entrypoint":"cli","status":"busy",
 "updatedAt":1782032951209,"statusUpdatedAt":1782032951209}
```

### 13.4 `~/.claude/file-history/<session-uuid>/<hash>@v<N>` (edit checkpoints)

由 `file-history-snapshot` 记录引用的磁盘备份 blob。每个是一个被编辑文件内容的保存副本;
版本累积(`…@v1`、`…@v2`、…),以便 `/rewind` 到选定的 `messageId` 可以恢复精确的先前
内容。已验证:`~/.claude/file-history/<uuid>/0de06013ce58c98e@v1`、
`632a9a22ce19124f@v1`、`632a9a22ce19124f@v2`。`file-history-snapshot` 记录携带:

`file-history-snapshot` 记录的 **唯一** keys 是 `{type, messageId, isSnapshotUpdate,
snapshot}` —— 注意 **没有 `sessionId`**(不同于其他每一种侧信道记录)。它纯粹凭它位于
哪个 `.jsonl` 文件中而关联到其会话,并凭 `messageId` 关联到一条具体消息(见 §5)。

| 字段 | 类型 | 含义 |
|---|---|---|
| `type` | string | `"file-history-snapshot"` |
| `messageId` | uuid | 该快照锚定到的消息 |
| `isSnapshotUpdate` | bool | `false`=初始,`true`=增量 |
| `snapshot.messageId` | uuid | `messageId` 的镜像 |
| `snapshot.timestamp` | ISO8601 | 拍摄时间 |
| `snapshot.trackedFileBackups` | object | 映射 `<abs file path>` → `{backupFileName, version, backupTime}`;**该边界处无文件被编辑时为 `{}`** |

```json
{ "type": "file-history-snapshot", "isSnapshotUpdate": false, "messageId": "<uuid>",
  "snapshot": { "messageId": "<uuid>", "timestamp": "…",
    "trackedFileBackups": { "<abs file>": { "backupFileName": "e584466a73198722@v1",
                                            "version": 1, "backupTime": "2026-06-19T05:39:03.729Z" } } } }
```

### 13.5 `~/.claude/usage.json` (quota snapshot — optional)

存在时由 `ClaudeUsageProbe` 读取(形状可变:数字或 `{percent, resetAt}` 对象)。
**在该存储库中不存在** —— 探针会回退到 `claude /usage` 的 tmux 抓取(§9.3)。

---

## 14. Engram mapping

Engram 的适配器实际如何消费该格式。两个适配器刻意保持逐字节对等;行号引用行为所在的文件。

| Source record / field | Engram Session field / behavior | TS (`src/adapters/claude-code.ts`) | Swift (`…/ClaudeCodeAdapter.swift`) |
|---|---|---|---|
| `projects/<dir>/*.jsonl` | 会话定位器(文件路径) | `listSessionFiles` `:41-73` | `listSessionLocators` `:27-48` |
| `<uuid>/subagents/*.jsonl` | 会话定位器(subagent) | `:51-63` | `:38-44` |
| `type ∈ {user, assistant}` | 承载消息的门控;其余全部跳过 | `MESSAGE_TYPES` `:26,:98` | inline `:100-104` |
| `sessionId` field | `SessionInfo.id`(父级);在类型过滤前捕获 | `:97` | `:106-108` |
| `agentId` field (subagent) | `SessionInfo.id`(对 subagent 覆盖 sessionId) | `:100,:145` | `:109-111,:150` |
| segment before `/subagents/` | `parentSessionId` | regex `:151` | `parentSessionId(from:)` `:528-536` |
| path contains `/subagents/` | `agentRole = "subagent"` | `:143,:171` | `:149,:172` |
| `cwd` field(非目录名) | `SessionInfo.cwd`;`project = basename(cwd)` | `:101,:161,:193-197` | `:112-114,:161,:206-210` |
| `message.model` | `SessionInfo.model` → `detectSource`(`claude-code`/`minimax`/`lobsterai`) | `:106-108,:180-191` | `:123-125,:212-223` |
| `message.usage.input_tokens` | `TokenUsage.inputTokens` | `:248` | `usage()` `CodexAdapter.swift:223` |
| `message.usage.output_tokens` | `TokenUsage.outputTokens` | `:249` | `CodexAdapter.swift:224` |
| `message.usage.cache_read_input_tokens` | `TokenUsage.cacheReadTokens` | `:250-252` | `CodexAdapter.swift:225` |
| `message.usage.cache_creation_input_tokens` | `TokenUsage.cacheCreationTokens` | `:253-255` | `CodexAdapter.swift:226` |
| `message.content[]` `text` | 主消息内容 | `extractContent` `:347-349` | `:407-410` |
| `message.content[]` `thinking` | 仅兜底内容;`signature` 丢弃 | `:350-351,:370` | `:411-413,:431` |
| `message.content[]` `tool_use` | 摘要为 `` `name`: summary ``;噪声工具丢弃 | `formatToolUse` `:389-403` | `:461-472` |
| `tool_use.input` (Read/Write/Edit/Bash/Glob/Grep/Agent) | 逐工具摘要 | `summarizeToolInput` `:448-460` | `:513-526` |
| `tool_use.name == "AskUserQuestion"` | 格式化的 Q/A 块 | `formatAskUserQuestion` `:405-425` | `:474-493` |
| `message.content[]` `tool_result` | 大多丢弃;仅当 `"User has answered…"` 时保留 | `formatToolResult` `:427-446` | `:495-511` |
| `user` record w/ `tool_result` content | 重分类 `role = "tool"`,计为 `toolMessageCount` | `isToolResult` `:333-338`, `:232-235` | `:387-392`, `:361-365` |
| `message.content[]` `image` | 渲染为 `[Image: <media_type>, ~N KB]` | `:357-365` | `:420-425` |
| `message.content` as string | 逐字透传 | `:341` | `:395` |
| first non-injection user text | `summary = firstUserText.slice(0,200)` | `:121-123,:168` | `:142,:168` |
| `isSystemInjection(text)` user records | 计为 `systemMessageCount`,而非 user | `:279-291` | `isSystemInjection` `:375-385` |
| `timestamp` field | `startTime`(首)/ `endTime`(末);回退到文件 mtime | `:102-103,:139-141` | `:115-120,:159` |
| file size / mtime | `sizeBytes`;mtime = start-time 回退 | `:170` | `:170` |
| `NOISE_TOOLS` (ToolSearch/Skill/Todo*/Task*/…) | 从渲染内容中丢弃 | `:376-387` | `noiseTools` `:434-445` |
| dir-name `decodeCwd` | 仅显示/兜底 —— 对 cwd/project **从不信任** | `:302-307` | `:340-345` |

**Engram 不消费的字段/记录**(完整跳过列表,为完整起见):`uuid`、`parentUuid`、
`requestId`、`promptId`、`slug`、`origin`、`promptSource`、`permissionMode`、
`sourceToolAssistantUUID`、`toolUseResult`、`attribution*`、`isCompactSummary`、
`isVisibleInTranscriptOnly`、`diagnostics`、`stop_*`、`tool_use.caller`、thinking
`signature`、全部 24 个 `attachment.type` 子类型、全部 10 个 `system.subtype` 变体、
全部 9 种侧信道记录类型(`last-prompt`/`ai-title`/`mode`/`permission-mode`/
`queue-operation`/`file-history-snapshot`/`pr-link`/`bridge-session`/`agent-name`),
以及 usage 字段 `cache_creation{}`/`server_tool_use{}`/`service_tier`/`inference_geo`/
`iterations`/`speed`。`.meta.json`、`journal.jsonl`、`sessions-index.json`、
`history.jsonl`、`sessions/` 和 `file-history/` 辅助文件也都未被读取。

> `claude-usage-probe.ts` 是一个独立的配额探针(`UsageProbe`),不是会话适配器 ——
> 见 §9.3 / §13.5。

---

## 15. Gotchas, version drift & edge cases

1. **三层 `type`。** 顶层记录 `type` ≠ `message.content[].type` ≠ `attachment.type`
   ≠ `system.subtype`。指针列表混淆了它们;见 §1/§4。`direct` = `tool_use.caller.type`;
   `create` = `toolUseResult.type`;`message` = `message.type`(总是字面 `"message"`)。
2. **顶层 `summary` 类型在该存储库中不存在**(0 个文件)。现代 compaction 使用
   `system/compact_boundary` + `isCompactSummary` user 记录。legacy 的
   `{type:summary, summary, leafUuid}` 形状现已 **Confirmed (community reverse-engineering)**
   为恰好 `{"type":"summary","summary":"…","leafUuid":"<uuid>"}` —— 一个 compaction
   检查点,其 `leafUuid` 指向叶子消息以便重放跨越边界拼接(见 §11.3)—— 但此处磁盘上
   仍然缺失([ClaudeWorld](https://claude-world.com/tutorials/s16-session-storage/))。
3. **是 `Agent` 不是 `Task`。** subagent dispatch 工具是 `Agent`。`Task*` 是后台任务
   MCP 工具集。**Confirmed (official):** 重命名边界为 **v2.1.63** —— Task 工具在此时
   重命名为 `Agent`,且 `Task(...)` 引用仍作为别名有效
   ([sub-agents docs](https://code.claude.com/docs/en/sub-agents))。
4. **工作流嵌套 subagent 未被索引。** `subagents/workflows/wf_*/agent-*.jsonl`
   (及其 `journal.jsonl`)从未被任一适配器发现 —— 观察到某会话约 93% 的 subagent
   被遗漏。是有意的范围限制还是潜在 bug 尚未解决。
5. **三个当前模型计价为 $0。** 任何在 `pricing.ts` 中无精确或最长前缀 key 的模型都解析
   为 `undefined` → 成本 `0`。磁盘上即 **`claude-opus-4-8`(21541 条记录)、
   `claude-opus-4-7`(2070)、以及 `claude-fable-5`(156)** —— 均不与现有的
   `opus-4-6`/`sonnet-4-6`/`sonnet-4-5`/`haiku-4-5` 条目前缀匹配。横跨全部三个活跃
   生产模型的真实成本低估,而不仅仅是主模型(见 §9.3)。Swift 产品侧成本计算路径本轮
   未完全追踪。
6. **`decodeCwd` 对含 `-`/`.` 的路径有损且错误。** 它既不建模 `.` → `-` 也不建模段
   边界。Engram 通过读取记录内 `cwd` 来绕开它。不要把 `decodeCwd` 输出当作真实路径。
7. **`tool_result.content` 是多态的**(string ~99%,array 用于 image/tool_reference/text)。
   期待纯字符串的消费者会在 array 情况下出错;两个适配器都处理两种情况。
8. **`usage` 有两种形状。** 精简(较旧)缺少 `iterations`/`server_tool_use`/`speed`。
   `iterations` 重复了顶层数字 —— 只对顶层求和。
9. **`<synthetic>` 模型** → 全零 usage → 0 成本;这些是客户端生成 / 错误 / 注入的
   assistant 轮次。
10. **`userType:"ant"`** 标记 Anthropic 内部构建;`"external"` 为普通。
    **Confirmed (community):** `"ant"` 标识正在 dogfooding(“antfooding”)Claude Code
    的 Anthropic 员工(“ants”),与 Undercover Mode 等内部功能挂钩;`"external"`
    是普通用户
    ([Claude Code source write-up](https://linas.substack.com/p/claudecodesource))。
11. **侧信道记录每轮重新追加。** `mode`/`last-prompt`/`permission-mode`/`ai-title`
    反复成簇;**最后一次出现胜出**。仅含侧信道记录(无 `user`/`assistant`)的文件产出
    `null`/`.malformedJSON`(Engram 跳过它)。
12. **`sessions-index.json` 罕见且陈旧。** 不被 GC;信任前对每个 `fullPath` 重新
    stat。Engram 完全忽略它。
13. **`history.jsonl` 形状** 是 `{display, pastedContents, timestamp, project,
    sessionId}` —— 一个以 epoch-ms `timestamp` 为 key 的 prompt 回溯日志,**不是** 某次
    研究轮次猜测的 `{firstPrompt,…}` 形状(此处已修正)。
14. **较新版本字段**(逐记录的 `slug`、`turn_duration` 上的 `pendingWorkflowCount`、
    `attributionPlugin`、`origin.kind:"coordinator"`)仅出现在较新的 2.1.x;
    `deferred_tools_delta.pendingMcpServers` 在较新构建中被移除。适配器是前向安全的,
    因为它们门控于 `{user,assistant}` 白名单,而非封闭类型列表。
15. **`bridge-session.lastSequenceNum`** 在样本中为 `0`(或小整数);它是真正的高水位
    同步计数器还是占位符尚未确认(web-checked 2026-06-21: no authoritative source
    found —— `bridge-session` 记录与 `lastSequenceNum` 在公开渠道无文档,尽管跨
    desktop/CLI/web 的桥接会话在
    [官方文档](https://code.claude.com/docs/en/sessions) 中有所提及)。
16. **`compactMetadata.preservedMessages.uuids` vs `allUuids`**(可见保留子集 vs 含
    中间工具轮次的完整段)是从集合成员关系推断的,未对照 CC 源码确认(web-checked
    2026-06-21: no authoritative source found —— CC 闭源,这些子字段在该层级无文档;
    该推断作为合理但未经确认的解释保留)。

### Still uncertain (open questions)
- **Confirmed (community):** 确切的 `{type:"summary", summary, leafUuid}` 字段
  schema —— `summary` 是 compaction 检查点,`leafUuid` 指向叶子消息以供重放/拼接
  (见 §11.3)。此处磁盘上仍然缺失;由社区逆向工程确认,而非新鲜磁盘观察
  ([ClaudeWorld](https://claude-world.com/tutorials/s16-session-storage/),
  [Inside Claude Code](https://databunny.medium.com/inside-claude-code-the-session-file-format-and-how-to-inspect-it-b9998e66d56b))。
- 自动 compaction(`trigger:"auto"`)是否在 trigger 值之外的任何字段上有所不同(只见到
  1 个 auto 样本)(web-checked 2026-06-21: no authoritative source found —— 来源确认
  `trigger` 字段区分 auto 与 manual,但无一枚举逐字段差异;仍属经验问题)。
- **Confirmed (official):** `Task` → `Agent` 重命名边界为 **v2.1.63**;`Task(...)`
  引用仍作为别名有效
  ([sub-agents docs](https://code.claude.com/docs/en/sub-agents))。
- 工作流嵌套 subagent 的跳过是有意的范围还是 bug(Engram-internal design —— not
  web-verifiable)。官方文档确认 **嵌套 subagent 是真实的 CC 功能**(一个 subagent 可
  派生它自己的 subagent),这支持了嵌套工作流 subagent 转录的存在
  ([sub-agents docs](https://code.claude.com/docs/en/sub-agents));
  `workflows/<wf>/journal.jsonl` 在 `{started,result,key,agentId}` 之外的 schema
  无公开文档(web-checked 2026-06-21: no authoritative source found)。
- Swift 产品侧成本计算的位置,以及是否有自定义定价覆盖 `claude-opus-4-8`
  (Engram-internal design —— not web-verifiable)。
- 拥有 `memory/`/`MEMORY.md`/`memory.bak.*` 的第三方插件身份(Engram-internal /
  local-environment —— not web-verifiable)。
- `stop_details`、`container`、`context_management` 的有内容形状(此处总为
  null/近乎缺失)(web-checked 2026-06-21: no authoritative source found —— 它们在
  Claude Code 磁盘上的填充形态在任何公开规范中均无描述)。
- `caller.type` 是否曾取 `direct` 以外的值(语料中 100%)(web-checked 2026-06-21:
  no authoritative source found —— `tool_use` 块上的 `caller` 字段在公开渠道无文档;
  对 subagent/coordinator 调用的工具,非 `"direct"` 值貌似可能,但无法从公开来源验证)。

---

## 16. Appendix: real anonymized line samples

每个记录/负载类型一个 fenced 块。每个 key 都保留;值已隐去。

### 16.1 `assistant` record (full envelope + message + usage + thinking)
```json
{
  "parentUuid": "22222222-2222-2222-2222-222222222222",
  "isSidechain": false,
  "message": {
    "model": "claude-opus-4-8", "id": "msg_018…", "type": "message", "role": "assistant",
    "content": [ { "type": "thinking", "thinking": "<reasoning text, redacted>", "signature": "<base64 sig, redacted>" } ],
    "stop_reason": "tool_use", "stop_sequence": null, "stop_details": null,
    "usage": {
      "input_tokens": 11691, "cache_creation_input_tokens": 11417, "cache_read_input_tokens": 15964,
      "output_tokens": 3717, "server_tool_use": { "web_search_requests": 0, "web_fetch_requests": 0 },
      "service_tier": "standard",
      "cache_creation": { "ephemeral_1h_input_tokens": 11417, "ephemeral_5m_input_tokens": 0 },
      "inference_geo": "not_available",
      "iterations": [ { "input_tokens": 11691, "output_tokens": 3717, "type": "message" } ],
      "speed": "standard"
    },
    "diagnostics": null
  },
  "requestId": "req_011C…", "type": "assistant", "uuid": "11111111-1111-1111-1111-111111111111",
  "timestamp": "2026-06-19T04:58:18.524Z", "userType": "external", "entrypoint": "cli",
  "cwd": "/Users/bing/-Code-/polycli", "sessionId": "00000000-0000-0000-0000-000000000000",
  "version": "2.1.183", "gitBranch": "main"
}
```

### 16.2 `user` record — human-typed prompt (string content)
```json
{
  "parentUuid": "22222222-2222-2222-2222-222222222222", "isSidechain": false, "promptId": "prompt_<uuid>",
  "type": "user", "message": { "role": "user", "content": "<user typed prompt, redacted>" },
  "origin": { "kind": "human" }, "promptSource": "typed",
  "uuid": "44444444-4444-4444-4444-444444444444", "timestamp": "2026-06-21T00:00:00.000Z",
  "userType": "external", "entrypoint": "cli", "cwd": "/Users/bing/-Code-/polycli",
  "sessionId": "00000000-0000-0000-0000-000000000000", "version": "2.1.183", "gitBranch": "main"
}
```

### 16.3 `user` record — tool_result (the tool-message pattern)
```json
{
  "parentUuid": "11111111-1111-1111-1111-111111111111", "isSidechain": false, "promptId": "prompt_<uuid>",
  "type": "user",
  "message": { "role": "user", "content": [ { "tool_use_id": "toolu_01…", "type": "tool_result", "content": "<str>", "is_error": false } ] },
  "uuid": "33333333-3333-3333-3333-333333333333", "timestamp": "2026-06-19T04:58:24.384Z",
  "toolUseResult": { "stdout": "<str>", "stderr": "", "interrupted": false, "isImage": false, "noOutputExpected": false },
  "sourceToolAssistantUUID": "11111111-1111-1111-1111-111111111111",
  "userType": "external", "entrypoint": "cli", "cwd": "/Users/bing/-Code-/polycli",
  "sessionId": "00000000-0000-0000-0000-000000000000", "version": "2.1.183", "gitBranch": "main"
}
```

### 16.4 `attachment` record — `hook_success`
```json
{
  "parentUuid": null, "isSidechain": false,
  "attachment": { "type": "hook_success", "hookName": "SessionStart:startup", "hookEvent": "SessionStart",
    "toolUseID": "<str>", "command": "<str>", "content": "", "stdout": "<str>", "stderr": "", "exitCode": 0, "durationMs": 149 },
  "type": "attachment", "uuid": "<str>", "timestamp": "2026-06-19T04:57:04.019Z",
  "userType": "external", "entrypoint": "cli", "cwd": "/Users/bing/-Code-/polycli",
  "sessionId": "<str>", "version": "2.1.183", "gitBranch": "main"
}
```

### 16.5 `attachment` record — `task_reminder` (empty)
```json
{ "type": "attachment", "uuid": "<uuid>", "parentUuid": "<uuid>", "sessionId": "<uuid>",
  "timestamp": "…", "cwd": "<abs>", "gitBranch": "main", "version": "2.1.183", "userType": "external",
  "entrypoint": "cli", "isSidechain": false, "attachment": { "type": "task_reminder", "content": [], "itemCount": 0 } }
```

### 16.6 `system` record — `compact_boundary`
```json
{ "type": "system", "subtype": "compact_boundary", "uuid": "<uuid>", "parentUuid": "<uuid>",
  "logicalParentUuid": "<uuid>", "sessionId": "<uuid>", "timestamp": "…", "cwd": "<abs>",
  "gitBranch": "main", "version": "…", "userType": "external", "entrypoint": "cli",
  "isSidechain": false, "isMeta": true, "level": "info", "content": "Conversation compacted",
  "compactMetadata": { "trigger": "manual", "preTokens": 641256, "postTokens": 13530, "durationMs": 101238,
    "preCompactDiscoveredTools": ["WebFetch","WebSearch"],
    "preservedSegment": { "headUuid": "<uuid>", "anchorUuid": "<uuid>", "tailUuid": "<uuid>" },
    "preservedMessages": { "anchorUuid": "<uuid>", "uuids": ["<uuid>"], "allUuids": ["<uuid>"] } } }
```

### 16.7 `user` record — `isCompactSummary`
```json
{ "type": "user", "uuid": "659dea2b-9e92-4f43-9547-f0c9a9867bc8", "parentUuid": "2cdf8b72-6a75-4a4d-b522-4c57eae69ea4",
  "isCompactSummary": true, "isVisibleInTranscriptOnly": true,
  "message": { "role": "user", "content": "…generated summary…" } }
```

### 16.8 `assistant` record — `Agent` dispatch (subagent spawn)
```json
{ "type": "assistant",
  "message": { "role": "assistant", "model": "claude-opus-4-8",
    "content": [ { "type": "text", "text": "<assistant reasoning>" },
      { "type": "tool_use", "id": "toolu_014RWAea4dPmkLdEossEV1ez", "name": "Agent",
        "input": { "description": "Privacy data flow audit", "prompt": "<full subagent prompt — anonymized>", "subagent_type": "privacy" },
        "caller": { "type": "direct" } } ] } }
```

### 16.9 Subagent transcript first line (`subagents/agent-<id>.jsonl`)
```json
{ "parentUuid": null, "isSidechain": true, "promptId": "d7d35fa2-…", "agentId": "a784b50f9fbfb258b",
  "type": "user", "message": { "role": "user", "content": "<dispatched task prompt — anonymized>" },
  "sessionId": "477f5790-…", "cwd": "<cwd>", "gitBranch": "<branch>", "version": "2.1.156",
  "userType": "external", "entrypoint": "cli", "uuid": "<uuid>", "timestamp": "<iso8601>" }
```

### 16.10 Subagent sidecar (`subagents/agent-<id>.meta.json`)
```json
{ "agentType": "i18n", "description": "i18n localization audit", "toolUseId": "toolu_012oNrmxfmS4FUXjp7fefEKN" }
```
最小形状 —— `subagents/workflows/wf_*/` 下的工作流嵌套 subagent
(无 `description`,无 `toolUseId`):
```json
{ "agentType": "workflow-subagent" }
```

### 16.11 `file-history-snapshot` record
```json
{ "type": "file-history-snapshot", "messageId": "ce6eaa53-88fa-4444-81dc-ab9fae319eb9", "isSnapshotUpdate": false,
  "snapshot": { "messageId": "ce6eaa53-88fa-4444-81dc-ab9fae319eb9", "timestamp": "2026-05-29T06:29:52.946Z",
    "trackedFileBackups": { "/redacted/abs/path/edited-file.swift": { "backupFileName": "e584466a73198722@v1", "version": 1, "backupTime": "2026-06-19T05:39:03.729Z" } } } }
```

### 16.12 Side-channel records (flat; no uuid/parentUuid)
```json
{"type":"last-prompt","sessionId":"<uuid>","leafUuid":"<uuid>","lastPrompt":"<text|null>"}
{"type":"ai-title","sessionId":"<uuid>","aiTitle":"<title>"}
{"type":"permission-mode","sessionId":"<uuid>","permissionMode":"bypassPermissions"}
{"type":"mode","sessionId":"<uuid>","mode":"normal"}
{"type":"agent-name","sessionId":"<uuid>","agentName":"<name>"}
{"type":"pr-link","sessionId":"<uuid>","timestamp":"…","prNumber":42,"prRepository":"owner/repo","prUrl":"<url>"}
{"type":"bridge-session","sessionId":"<uuid>","bridgeSessionId":"cse_01W9MQGReWS44CBjcm2YqFrL","lastSequenceNum":0}
{"type":"queue-operation","sessionId":"<uuid>","timestamp":"…","operation":"enqueue","content":"<text>"}
{"type":"queue-operation","sessionId":"<uuid>","timestamp":"…","operation":"dequeue"}
```

### 16.13 Workflow journal records (`subagents/workflows/wf_*/journal.jsonl`)
```json
{"type":"started","key":"v2:<sha256>","agentId":"<agentId>"}
{"type":"result","key":"v2:<sha256>","agentId":"<agentId>","result":{ … }}
```

### 16.14 Global `history.jsonl` line
```json
{"display":"<prompt text>","pastedContents":{},"timestamp":1765606729001,"project":"/Users/bing/-Code-/TSLin","sessionId":"118235ea-9fd6-459a-a3af-4584f16ec4de"}
```

### 16.15 Process registry (`~/.claude/sessions/<pid>.json`)
```json
{"pid":11844,"sessionId":"45031c3c-…","cwd":"/Users/bing/-Code-/AI-Panel","startedAt":1781927597951,"procStart":"Sat Jun 20 03:53:16 2026","version":"2.1.183","peerProtocol":1,"kind":"interactive","entrypoint":"cli","status":"busy","updatedAt":1782032951209,"statusUpdatedAt":1782032951209}
```

### 16.16 `sessions-index.json` (per-project sidecar)
```json
{ "version": 1, "entries": [ { "sessionId": "<uuid>", "fullPath": "/Users/.../projects/-/<uuid>.jsonl",
  "fileMtime": 1771494977955, "firstPrompt": "<first user prompt, truncated>", "messageCount": 2,
  "created": "2026-02-19T09:53:20.037Z", "modified": "2026-02-19T09:56:17.931Z",
  "gitBranch": "", "projectPath": "/", "isSidechain": false } ] }
```

---

## References (official sources)

Web 确认轮次 2026-06-21(`web_access_ok=true`)。官方 Anthropic / Claude Code
文档:

- [Claude Code Docs — Manage sessions](https://code.claude.com/docs/en/sessions) —— 转录存储路径、JSONL 只追加模型、`/compact`、`/branch`、`--fork-session`、`cleanupPeriodDays`、`CLAUDE_CONFIG_DIR`。
- [Claude Code Docs — Create custom subagents](https://code.claude.com/docs/en/sub-agents) —— Task→Agent 于 v2.1.63 重命名、`Agent` 工具、`subagent_type`/后台、嵌套 subagent。
- [Anthropic — Building with extended thinking](https://platform.claude.com/docs/en/build-with-claude/extended-thinking) —— thinking 块字段(`thinking`/`signature`);`display` = summarized/omitted;`omitted` 为 Opus 4.8/4.7、Fable 5、Mythos 5 的默认值。
- [Amazon Bedrock Docs — Claude thinking encryption / `redacted_thinking`](https://docs.aws.amazon.com/bedrock/latest/userguide/claude-messages-thinking-encryption.html) —— 加密 `data` 字段、由安全触发的脱敏。

社区逆向工程(佐证官方文档未规定的磁盘形状):

- [swyxio/claude-compaction-viewer](https://github.com/swyxio/claude-compaction-viewer) —— `compact_boundary` subtype + `compactMetadata` trigger(auto/manual)+ `isCompactSummary` user 消息。
- [ClaudeWorld — Session Storage tutorial](https://claude-world.com/tutorials/s16-session-storage/) —— `{type,summary,leafUuid}` summary 条目;两记录 compaction 结构。
- [Kenneth Huang — Trajectory Compression and Replay](https://kenhuangus.substack.com/p/chapter-5-trajectory-compression) —— `leafUuid` 重放、跨 compaction 边界拼接。
- [Yi Huang — Inside Claude Code: The Session File Format](https://databunny.medium.com/inside-claude-code-the-session-file-format-and-how-to-inspect-it-b9998e66d56b) —— summary = compaction 检查点;信封字段。
- [Yang Liu — What I Learned Parsing Claude Code's JSONL Session Logs](https://medium.com/@ywian/what-i-learned-parsing-claude-codes-jsonl-session-logs-268248be0a2c) —— 字段清单(含 `leafUuid`、`teamName`、`summary`);“no spec exists”。
- [Claude Code source write-up](https://linas.substack.com/p/claudecodesource) —— `userType:"ant"` = 正在 dogfooding(“antfooding”)的 Anthropic 员工。
- [KyleAMathews/claude-code-ui spec.md](https://github.com/KyleAMathews/claude-code-ui/blob/main/spec.md) —— 条目类型:user/assistant/system/queue-operation/file-history-snapshot。
