# Antigravity 会话格式 — 权威参考

Last researched: 2026-06-21 (Engram session-format research workflow)

> 本文档为英文权威版 antigravity.md 的中文阅读副本;若有出入以英文版为准。

> **证据基础(本文档):** 本机上的实时磁盘存储 **+** 两个 Engram 适配器
> (Swift 产品 `AntigravityAdapter.swift`、TS 参考 `src/adapters/antigravity.ts`) **+** 仓库
> fixtures。实际采样的文件:
> - IDE 缓存:**58** 个 `~/.engram/cache/antigravity/*.jsonl`
> - IDE 源 protobuf:**61** 个 `~/.gemini/antigravity/conversations/*.pb`
> - CLI brain:**151** 个会话目录,其中 **143** 个有 `transcript.jsonl`、**128** 个有 `transcript_full.jsonl`
> - 扫描的 CLI 记录总量:跨全部 143 个 transcript 共 **8 673** 行
> - 扫描的缓存消息行总量:**2 303**
> - Fixtures:`tests/fixtures/antigravity/cache/conv-001.jsonl`(3 行)、`tests/fixtures/antigravity-cli/transcript.jsonl`(4 行)
> - Schema:`macos/Shared/EngramCore/Adapters/Cascade/cascade.proto`、gRPC 客户端 `CascadeClient.swift`
>
> 发生冲突时,**以真实数据为准**;不一致之处在文内就地标注。已与三份维度报告
> (storage-lifecycle、record-schema、engram-mapping)交叉核对;它们相互矛盾的断言已
> 重新对照实时数据和实际仓库文件(尤其是 proto、工具列表和 `status` 枚举)进行复核,
> 并在它们出现分歧处加以更正。

---

## 1. 概述与 TL;DR

**Antigravity 是两个互不相关的产品,它们共用 `~/.gemini/` home 以及同一个 Engram 适配器。**
单一的 `AntigravityAdapter` 读取两种完全不同的磁盘形态:

> **版本漂移(web 已确认 2026-06-21):** 下面的两分支模型对 Engram 实际读取的内容是准确的,但
> 实时的 `~/.gemini/` 布局已增长到不止两个 brain 根。Antigravity 2.0 引入了位于
> `~/.gemini/antigravity/brain` 的 Agent Manager brain,以及位于 `~/.gemini/antigravity-ide/brain`
> 的 IDE brain,与 CLI 的 `~/.gemini/antigravity-cli/brain` 并列 — 共有多达**三个并列的 brain 根**
>(Agent Manager、IDE、CLI)共享 JSONL transcript 格式,而非单一的 IDE-vs-CLI 划分
> ([Antigravity 2.0 shared-brain thread](https://discuss.ai.google.dev/t/antigravity-2-0-and-ide-cli-too-shared-brain/167445))。

| Branch | Product | On-disk root | Storage tech | Who writes it | Engram reads |
|---|---|---|---|---|---|
| **A. Cascade IDE** | Antigravity IDE(基于 Codeium "Cascade" 引擎的 VS Code 分支) | 源 `~/.gemini/antigravity/conversations/<uuid>.pb`;Engram 缓存 `~/.engram/cache/antigravity/<uuid>.jsonl` | IDE 写入加密的 `.pb`;**Engram 自身的 sync** 通过 gRPC 与 IDE 通信写入 `.jsonl` 缓存 | 来自**缓存**的 meta 行 + `{role,content}` 消息行(从不读 `.pb`) |
| **B. Antigravity CLI** | `antigravity-cli`(智能体 "brain") | `~/.gemini/antigravity-cli/brain/<uuid>/.system_generated/logs/transcript.jsonl` | CLI 智能体直接写入 | 带 `type` 标签的仅追加 JSONL 事件日志,**直接**读取 |

**心智模型。** Branch A 是一个不透明加密 IDE 存储的 *Engram 衍生文本投影*
(Engram 通过 gRPC 拉取对话并写入有损的 `{role,content}` JSONL 缓存;`.pb` 永远不会被解码)。
Branch B 是一个 *原生丰富的智能体事件日志*(步骤、工具、推理、时间戳),Engram 原样读取
但随后会进行大量过滤。

**最重要的血统事实:** 在已发布的 Swift 产品中,`AntigravityAdapter` 在**全部三个**产品构造点
都以 **`enableLiveSync: false`** 构造
(`SessionAdapterFactory.swift:26`、`:71` 以及 `MessageParser.swift:129`)。因此该产品
**从不运行 gRPC sync**、**从不解码 `.pb` 文件**。Branch A 只暴露 *早先*(由遗留 TS 运行)写入的
缓存 JSONL;Branch B 是实时读取的(它在磁盘上本就是 JSONL)。在一台没有任何先前 TS sync 的
全新纯 Swift 机器上,Branch A 产出 **空**,只有 CLI brain transcript 会出现。

```
                          ANTIGRAVITY  (two products, one adapter)
  ┌─────────────────────────────────────────────┐   ┌──────────────────────────────────────────┐
  │ BRANCH A — Cascade IDE                       │   │ BRANCH B — Antigravity CLI ("brain")       │
  │                                              │   │                                            │
  │  ~/.gemini/antigravity/conversations/        │   │  ~/.gemini/antigravity-cli/brain/          │
  │     <uuid>.pb   (ENCRYPTED protobuf, opaque) │   │     <uuid>/                                │
  │            │  IDE writes                      │   │       ├─ implementation_plan.md (artifact) │
  │            ▼                                  │   │       ├─ review_report.md       (artifact) │
  │  [ local gRPC language server ]              │   │       ├─ *.md.metadata.json     (sidecar)  │
  │            │  Engram sync (DISABLED in        │   │       └─ .system_generated/                │
  │            │  product: enableLiveSync=false)  │   │            ├─ logs/transcript.jsonl  ◄──────┼── Engram reads (direct)
  │            ▼                                  │   │            │   transcript_full.jsonl (IGN.)│
  │  ~/.engram/cache/antigravity/<uuid>.jsonl ◄──┼── │            ├─ messages/<uuid>.json (IGNORED)│
  │     line1 = meta ; line2..N = {role,content} │   │            └─ tasks/task-<n>.log   (IGNORED)│
  └─────────────────────────────────────────────┘   └────────────────────────────────────────────┘
        Engram reads the CACHE (only its byte-size                 step records: USER_INPUT,
        from the .pb is reused via pbSizeBytes)                    PLANNER_RESPONSE, VIEW_FILE, …
```

---

## 2. 磁盘布局与文件命名

### 2.1 目录树(实时)

```
~/.gemini/
├── antigravity/                         # IDE product root
│   ├── daemon/                          # language-server discovery + logs
│   │   └── ls_<16hex>.log               #   e.g. ls_86f3b7e9cbf5f2e3.log  (Go LS log; NO .json present)
│   ├── conversations/                   # SOURCE OF TRUTH for IDE convos
│   │   └── <uuid>.pb                     #   ENCRYPTED protobuf, 1 per conversation
│   ├── agyhub_summaries_proto.pb        # aggregate/state blobs (not per-session)
│   ├── antigravity_state.pbtxt
│   ├── user_settings.pb
│   ├── installation_id
│   ├── browserAllowlist.txt
│   └── (annotations/ brain/ browser_recordings/ code_tracker/ context_state/
│        html_artifacts/ implicit/ knowledge/ playground/ … other engine dirs)
│
└── antigravity-cli/
    └── brain/                           # CLI product root
        └── <uuid>/                      # 1 dir per CLI session (named by session UUID)
            ├── implementation_plan.md            # user-visible artifacts (variable set)
            ├── implementation_plan.md.metadata.json
            ├── review_report.md
            ├── review_report.md.metadata.json
            └── .system_generated/
                ├── logs/
                │   ├── transcript.jsonl          # <-- THE file Engram reads
                │   └── transcript_full.jsonl     # superset variant, IGNORED by Engram (128 dirs)
                ├── messages/
                │   └── <uuid>.json               # per-message inter-agent bus blobs (IGNORED)
                └── tasks/
                    └── task-<n>.log              # task logs (IGNORED)

~/.engram/
└── cache/
    └── antigravity/                     # Engram-OWNED derived cache (NOT Antigravity's)
        └── <uuid>.jsonl                 # 1 per IDE conversation; meta line + message lines
```

> **版本漂移(web 已确认 2026-06-21):** 每对话一个的 `<uuid>.pb` 文件对 `.pb` 代次是正确的,但
> 较新的 Antigravity IDE 版本已开始将对话存储为 **SQLite `.db`** 文件而非 `.pb`(社区恢复工具
> 两种都有报告)。此外,IDE 的对话**索引**(UUID→对话映射,即 `trajectorySummaries`)位于
> `~/Library/Application Support/Antigravity[ IDE]/User/globalStorage/state.vscdb` 中的
> `chat.ChatSessionStore.index` 和 `antigravityUnifiedStateSync.trajectorySummaries`(Base64 protobuf)
> 键下 — 不止是每对话的 `.pb` 文件。Engram 仍以缓存(Branch A)作为其读取面,从不读取 `.db`
> 文件或 `state.vscdb`
> ([decryptor](https://github.com/arashz/antigravity_decryptor))。

### 2.2 命名规则

- **IDE 对话 id** = 小写 UUIDv4。文件:`<uuid>.pb`(源)↔ `<uuid>.jsonl`(缓存)。
  basename *就是* 对话 id;缓存与 `.pb` 1:1 共享它(`AntigravityAdapter.swift:147-148`)。
- **CLI 会话 id** = 小写 UUIDv4 = `brain/<uuid>/` 目录名。transcript 路径固定为
  `<uuid>/.system_generated/logs/transcript.jsonl`。
- **Daemon 日志:** `ls_<16-hex>.log`(一个 Go language-server 日志)。`fromDaemonDir` *本应* 读取的
  JSON 发现文件(`httpPort` + `csrfToken`)在本机上**不存在**(`ls .../daemon/*.json` → 0)。
  当前的 Antigravity 改用**基于进程的发现**(见 §3)。
- **CLI artifacts:** `<name>.md` + `<name>.md.metadata.json` sidecar;任务日志 `task-<n>.log`;
  每条消息的 blob `<msg-uuid>.json`。

---

## 3. 文件生命周期与生成

### Branch A — IDE 缓存:衍生的、按对话整文件重写(产品中实时同步被 DISABLED)

- **唯一真相源** = 加密的 `<uuid>.pb`,由 IDE 拥有;它随用户聊天而增长/重写。
- **Engram `sync()`**(`AntigravityAdapter.swift:130-211`)*意图*是:发现正在运行的 language
  server → `listConversations()` → 对每个对话**整文件重写**缓存 JSONL(`CascadeCacheSupport.writeCache`
  原子地写入 meta + 所有消息,`WindsurfAdapter.swift:62-80` — 这**不是** append)。
  - **新鲜度闸门**(`isFresh`,`:213-231`):当 `cache.mtime >= pb.mtime` **且** `cache.size > 200`
    时跳过(size ≤ 200 = "仅 meta / 无内容")。
  - **`.pb` 扫描回填**(`syncFromPbFiles`,`:179-211`):gRPC 列表只返回约 10 个最近的
    对话,因此第二轮扫描 `conversations/*.pb` 找出 API 未返回的 id,并以文件 mtime 衍生的
    `createdAt`/`updatedAt` 和 `title:""` 写入缓存条目。
- ⚠ **在已发布产品中,sync 是关闭的**(在全部三个产品构造点 `AntigravityAdapter(enableLiveSync: false)`
  — `SessionAdapterFactory.swift:26,71` **以及** `MessageParser.swift:129`;
  对 live-sync 标志的任何修改都必须同时改动这三处)。`sync()` 提前返回(`:131`),因此 Engram 只读取
  **既有的** `~/.engram/cache/antigravity/*.jsonl`。上次遗留 sync 之后产生的新 IDE 对话**不会**被
  拾取。TS 参考适配器(`antigravity.ts`)没有这样的闸门,*会*实时 sync。
- **发现(启用时):** 先基于进程(`CascadeGrpcClient.fromProcess()` / Swift
  `CascadeDiscovery`)— 找到 `language_server` 进程、提取 `--csrf_token`、对 LISTEN 端口 `lsof`;
  回退到 `daemon/` 中带 `httpPort`+`csrfToken` 的 `<name>.json`。这里不存在 daemon `.json`,
  证实了基于进程的发现是实时机制。
- **Resume / rollover:** 缓存层没有 — 扁平的每对话一文件重写。对话续写只是让同一个
  `.pb`/`.jsonl` 增长。无归档/轮转;过期缓存条目会一直保留直到被覆盖。

### Branch B — CLI transcript:仅追加,直接读取

- 每个 CLI 会话 = 一个 `brain/<uuid>/` 目录。CLI 在智能体运行时**追加**步骤记录到
  `.system_generated/logs/transcript.jsonl`(只追加,从不重写 — `step_index` 是单调的)。
  `status:"RUNNING"` 记录在步骤进行中写入,并在完成时定稿为 `DONE`(或 `ERROR`)。
- 无 rollover/archive — 一个文件在会话生命周期内持续增长。
- 空/中止的会话会留下一个**没有** transcript 的 `brain/<uuid>/` 目录(151 个目录、143 个 transcript
  → 8 个目录没有)。Engram 跳过缺少 transcript 的目录。
- Engram **按需直接**读取 transcript;Branch B **没有** Engram 侧缓存。
- `transcript_full.jsonl`(128 个目录)是一个并行的超集 transcript(同 schema)。Engram 从不
  枚举它。

---

## 4. 记录 / 行分类

### 4.1 Branch A 缓存 `<uuid>.jsonl`
JSONL:**第 1 行 = 元数据对象**、**第 2..N 行 = 消息对象**。只有两种行类型:

| Line kind | Shape | Count seen |
|---|---|---|
| metadata(第 1 行) | `CacheMetaLine`(见 §5) | 58/58 文件 |
| message(第 2..N 行) | `{role, content}` — `role ∈ {user, assistant}` 仅此两种 | 2 303 行,100% 为 `{content,role}` |

### 4.2 Branch B transcript `transcript.jsonl`
纯 JSONL,**每个智能体 "step" 一个对象**,无前导元数据行(整个文件都是记录)。
跨 8 673 条实时记录发现的全部 16 个 `type` 值,以及生产者(`source`)和适配器分配的角色:

| `type` | n (live, all transcripts) | Purpose | Adapter role | Note |
|---|---:|---|---|---|
| `PLANNER_RESPONSE` | 3 884 | 模型回合:文本和/或 `thinking` 和/或 `tool_calls` | **assistant** | 携带 `thinking`、`tool_calls` |
| `VIEW_FILE` | 1 694 | 文件读取工具**结果** | **tool** | Swift 适配器唯一保留的工具结果 |
| `GREP_SEARCH` | 1 239 | grep 工具**结果** | DROPPED (Swift) / tool (TS) | 见 §7 |
| `SYSTEM_MESSAGE` | 353 | 系统/控制文本 | DROPPED | |
| `EPHEMERAL_MESSAGE` | 334 | 瞬态 UI 文本 | DROPPED | |
| `LIST_DIRECTORY` | 263 | 目录列表**结果** | DROPPED (Swift) / tool (TS) | |
| `GENERIC` | 197 | 杂项事件 | DROPPED (Swift) / tool (TS) | |
| `USER_INPUT` | 155 | 人类提示词 | **user** | |
| `RUN_COMMAND` | 143 | shell 命令**结果** | DROPPED (Swift) / tool (TS) | |
| `FIND` | 102 | 文件查找**结果** | DROPPED (Swift) / tool (TS) | |
| `SEARCH_WEB` | 91 | 网页搜索**结果** | DROPPED (Swift) / tool (TS) | |
| `CODE_ACTION` | 78 | 代码编辑/补丁动作 | DROPPED (Swift) / tool (TS) | |
| `CONVERSATION_HISTORY` | 74 | 历史边界标记 | DROPPED | **无 `content`** |
| `ERROR_MESSAGE` | 37 | 错误事件 | DROPPED | 额外 `error` 键;`content` 缺失(12)或为字符串(25),从不为 null |
| `INVOKE_SUBAGENT` | 24 | 子智能体派发标记 | DROPPED | 见 §10 |
| `CHECKPOINT` | 5 | 检查点标记 | DROPPED | |

> **适配器映射**(`cliMessage`,Swift `:345-368` / TS `:483-500`):`USER_INPUT`→user;
> `PLANNER_RESPONSE`→assistant(使用 `content`,回退到 `thinking`,附加 `toolCalls`);一个
> 固定的工具结果白名单 → tool。Swift 与 TS 的白名单 **不同** — 见 §7。

---

## 5. 共享外壳 / 元数据字段

### 5.1 Branch A — `CacheMetaLine`(第 1 行)— `antigravity.ts:18-26`

| Field | Type | Meaning | Optionality | Live presence | Example (anonymized) |
|---|---|---|---|---|---|
| `id` | string (UUID) | 对话 id(= `.pb` basename = 缓存文件名主干) | **required** | 58/58 | `"19d120fb-71a5-49c8-9d0b-3096ab367f50"` |
| `title` | string | 对话标题;从 `.pb` 扫描同步时为 `""` | required key, may be `""` | 58/58 | `"<str len=23>"` |
| `summary` | string | 来自 `GetAllCascadeTrajectories` 的 AI 摘要;仅在非空时输出 | optional | **18/58** | `"<str len=23>"` |
| `createdAt` | string (ISO-8601 UTC, ms) | 对话开始 | **required** | 58/58 | `"2026-02-24T05:00:52.882699Z"` |
| `updatedAt` | string (ISO-8601 UTC, ms) | 最后活动 | **required** | 58/58 | `"2026-02-24T05:01:09.968924Z"` |
| `cwd` | string (abs path) | 工作区文件夹(`workspaces[0].workspaceFolderAbsoluteUri`,去除/解码 `file://`) | optional | **18/58** | `"/Users/<user>/-Code-/<project>"` |
| `pbSizeBytes` | number | 真实 `.pb` 的字节大小(用于大小报告 + 去重) | optional in type | **58/58** | `158073`(一个实时文件:`27175276` ≈ 25.9 MB) |

**观察到的两种 key 集合**(在全部 58 个文件中验证):
- **40 个文件** = `{createdAt, id, pbSizeBytes, title, updatedAt}` — 从 `.pb` 扫描同步(无 `summary`/`cwd`,`title` 为空)。
- **18 个文件** = `{createdAt, cwd, id, pbSizeBytes, summary, title, updatedAt}` — 从 gRPC trajectory 列表同步。

> Fixtures 使用一种较旧的形态(`tests/fixtures/antigravity/cache/conv-001.jsonl`):只有
> `{id,title,createdAt,updatedAt}`,无 `pbSizeBytes`。两个适配器都能容忍缺失的可选键。

### 5.2 Branch B — 通用记录外壳(每条 transcript 记录)

| Field | Type | Meaning | Optionality | Example / domain |
|---|---|---|---|---|
| `type` | string enum | 步骤/记录类型(16 个值,§4.2) | **required** | `"PLANNER_RESPONSE"` |
| `step_index` | int | 单调步骤序号(resume/排序) | **required** | `0 … 931` |
| `source` | string enum | 生产者:`MODEL`(7 715)/ `SYSTEM`(803)/ `USER_EXPLICIT`(155) | **required** | `"MODEL"` |
| `status` | string enum | 生命周期:`DONE`(8 511)/ `RUNNING`(77)/ **`ERROR`(85)** | **required** | `"DONE"` |
| `created_at` | string (ISO-8601 UTC, **秒级精度,无 ms**) | 步骤时间戳 | **required** | `"2026-05-19T23:58:09Z"` |
| `content` | string | 文本正文 / 工具输出 / 用户输入 | 视类型而定 — 要么是非空字符串,要么**键缺失**(在 `CONVERSATION_HISTORY` 和仅含工具的 planner 步骤上省略)。在实时数据中**从不为 JSON `null`、从不为 `""`**。 | `"<str len=423>"` |
| `thinking` | string | 模型推理(在 `PLANNER_RESPONSE` 上) | optional | `"<str len=365>"` |
| `tool_calls` | array of `{name, args}` | 工具调用(在 `PLANNER_RESPONSE` 上) | optional | `[{"name":"view_file","args":{…}}]` |
| `error` | string | 错误文本(在 `ERROR_MESSAGE` 上) | optional | `"<str len=109>"` |
| `truncated_fields` | array of string (字段名) | 写入记录时被 CLI 截断的字段名(`content` / `thinking` / `tool_calls` 的子集) | optional | `["content"]`、`["content","thinking"]` |

> **对维度报告的更正:** `status` 有**三个**实时值 — DONE、RUNNING、**以及 ERROR**
>（85 条记录）。DIM 1 和 DIM 2 只列出了 DONE/RUNNING。跨全部 transcript 的完整键并集
> 恰好是 `['content','created_at','error','source','status','step_index','thinking','tool_calls','truncated_fields','type']`。

---

## 6. 消息与内容 schema

### 6.1 Branch A 消息(第 2..N 行)

| Field | Type | Meaning | Optionality | Example |
|---|---|---|---|---|
| `role` | string | 仅 `"user"` 或 `"assistant"` | **required** | `"assistant"` |
| `content` | string | 扁平化的消息文本 | **required** | `"<text>"` |
| `timestamp` | string | 每条消息的时间 | **实时缓存中从不出现** — 仅 fixture | — |

**已验证:** 全部 2 303 条实时消息行**恰好**为 `{content, role}`。Swift 写入器
(`CascadeCacheSupport.writeCache`,`WindsurfAdapter.swift:73-77`)只输出排序后的 `role`+`content` 键,
因此缓存时间戳在结构上不可能存在。读取器(`normalizedMessages`,`:19-35`)和 TS
`streamMessages`(`:368-396`)*能容忍* 可选的 `timestamp`,但写入器从不产生它 →
Branch A 的每条消息时间戳始终为 `nil`。

```json
{"id":"<uuid>","title":"","createdAt":"2026-02-19T15:47:16.862Z","updatedAt":"2026-02-19T15:47:16.862Z","pbSizeBytes":1113514}
{"role":"user","content":"<text>"}
{"role":"assistant","content":"<text>"}
```

### 6.2 Branch B 内容变体

- **`USER_INPUT`** → `content` = 人类提示词(逐字)。
- **`PLANNER_RESPONSE`** → assistant 回合。`content` 要么是非空字符串,要么键**缺失**
  (在实时数据中从不为 JSON `null` 或 `""` — 3 217 条记录省略它,667 条有字符串)。适配器
  通过 `typeof obj.content === 'string' ? … : ''` 将缺失/非字符串的 `content` 归并为 `""`
  (`antigravity.ts:486`),然后回退到 `thinking`。可能携带 `tool_calls`。
- **工具结果记录**(`VIEW_FILE`、`GREP_SEARCH`、`RUN_COMMAND`、`LIST_DIRECTORY`、`FIND`、
  `SEARCH_WEB`、`CODE_ACTION`)→ `content` = 工具输出文本(始终为非空字符串)。
- **`CONVERSATION_HISTORY`** → 无 `content` 键(历史边界标记)。
- **`ERROR_MESSAGE`** → `error` 字符串;`content` 要么是非空字符串(25 条记录),要么键
  **缺失**(12 条记录)— 从不为 `null`。

```json
{"type":"USER_INPUT","source":"USER_EXPLICIT","status":"DONE","created_at":"2026-05-20T03:00:00Z","step_index":0,"content":"<prompt>"}
{"type":"PLANNER_RESPONSE","source":"MODEL","status":"DONE","created_at":"2026-05-20T03:00:01Z","step_index":1,"thinking":"<reasoning>","tool_calls":[{"name":"view_file","args":{"AbsolutePath":"/abs/file.swift","StartLine":1,"EndLine":80,"toolAction":"<ui label>","toolSummary":"<ui summary>"}}]}
{"type":"VIEW_FILE","source":"MODEL","status":"DONE","created_at":"2026-05-20T03:00:02Z","step_index":2,"content":"<file contents>"}
```

---

## 7. 工具调用与结果

### Branch A — 不适用
缓存中**没有工具调用,也没有工具结果**(在 sync 过程中被扁平化掉)。Branch A 的 `toolMessageCount`
被硬编码为 `0`(`AntigravityAdapter.swift:84`;TS `:324`)。

### Branch B — 调用和结果是 SEPARATE 记录,仅由顺序关联

- **调用** = `PLANNER_RESPONSE` 内的一个 `tool_calls[]` 条目。
  - 观察到的对象 key 集合**始终**为 `{args, name}`(3 865/3 865)。
  - `name`(string):工具名。`args`(object):工具特定参数;**每个**工具还携带两个 UI
    字符串 `toolAction` + `toolSummary`。
- **结果** = 一个 *稍后的、单独的* 记录(`VIEW_FILE`、`RUN_COMMAND` 等),其 `content` 是输出。
- **关联:** **仅通过 `step_index` 顺序隐式关联。** **没有**显式的 call↔result id 字段。
  适配器不重建它 — `cliToolCalls`(`:370-382`)保留 `{name, input=truncateJSON(args,500)}`
  且 **`output` 始终为 nil**。

**实时观察到 19 个不同的工具名**(计数)及其 `args` 键(每个工具还有
`toolAction`、`toolSummary` — 下表为简洁省略,除非它们是唯一的键):

| tool | n | `args` keys (besides `toolAction`,`toolSummary`) |
|---|---:|---|
| `view_file` | 1721 | `AbsolutePath, StartLine, EndLine, ContentOffset, IsSkillFile` |
| `grep_search` | 1239 | `Query, SearchPath, Includes, IsRegex, CaseInsensitive, MatchPerLine` |
| `list_dir` | 263 | `DirectoryPath` |
| `run_command` | 144 | `CommandLine, Cwd, WaitMsBeforeAsync` |
| `find_by_name` | 102 | `Pattern, SearchDirectory, Excludes, Extensions, MaxDepth, Type` |
| `send_message` | 91 | `Message, Recipient` |
| `search_web` | 91 | `query` |
| `schedule` | 59 | `Prompt, CronExpression, DurationSeconds, TimerCondition` |
| `replace_file_content` | 50 | `TargetFile, TargetContent, ReplacementContent, Instruction, StartLine, EndLine, AllowMultiple, Description` |
| `write_to_file` | 29 | `TargetFile, CodeContent, Description, Overwrite, IsArtifact, ArtifactMetadata` |
| `invoke_subagent` | 24 | `Subagents` |
| `manage_task` | 21 | `Action, TaskId` |
| `define_subagent` | 18 | `name, description, system_prompt, enable_mcp_tools, enable_subagent_tools, enable_write_tools` |
| `list_permissions` | 4 | (仅两个 UI 字符串) |
| `call_mcp_tool` | 2 | `ServerName, ToolName, Arguments` |
| `ask_permission` | 2 | `Action, Reason, Target` |
| `manage_subagents` | 2 | `Action` |
| `Running_command` | 2 | (仅两个 UI 字符串) |
| `multi_replace_file_content` | 1 | `TargetFile, Description, Instruction, ReplacementChunks` |

> **对维度报告的更正:** DIM 2 列出了约 11 个工具;实时数据有 **19** 个(新增 8 个:
> `find_by_name`、`send_message`、`define_subagent`、`call_mcp_tool`、`ask_permission`、
> `multi_replace_file_content`、`manage_subagents`,以及一个杂散的 `Running_command`)。

### ⚠ Swift↔TS 在工具结果映射上的分歧(影响实时行为)

Swift 适配器的工具结果白名单(`AntigravityAdapter.swift:362`)匹配:
`VIEW_FILE`、`TOOL_OUTPUT`、`COMMAND_OUTPUT`、`SHELL_OUTPUT`、`APPLY_PATCH`。

但其中**只有 `VIEW_FILE` 实际出现**在 143 个实时 transcript 中。`TOOL_OUTPUT` /
`COMMAND_OUTPUT` / `SHELL_OUTPUT` / `APPLY_PATCH` 匹配**零**条实时记录(死分支 — 一个较旧或
推测性的 schema 词汇表)。与此同时,真实的结果类型(`RUN_COMMAND`、`GREP_SEARCH`、
`LIST_DIRECTORY`、`FIND`、`SEARCH_WEB`、`CODE_ACTION` — 约 1 900 条记录)命中 Swift `default: return nil`
→ **被丢弃**。

TS 参考的行为不同:在 `USER_INPUT`/`PLANNER_RESPONSE` 之后,**任何**带非空 `content` 的记录
都变成 `role:'tool'`(`antigravity.ts:498-499`)。因此 TS 将 `RUN_COMMAND`、
`GREP_SEARCH`、`GENERIC`、`SYSTEM_MESSAGE` 等计为工具消息;Swift 不会。

**后果:** 对于同一个文件,`toolMessageCount`、`messageCount` 和流式 transcript
在已发布的 Swift 产品(≈ 仅 `VIEW_FILE` 计数)与 TS 参考(高得多)之间**不同**。
parity fixture(`tests/fixtures/antigravity-cli/transcript.jsonl`)只包含
`USER_INPUT`/`PLANNER_RESPONSE`/`VIEW_FILE`,因此 **CI 不会触发这一分歧**。

---

## 8. 推理 / thinking

- **Branch A:** 不适用 — 缓存中没有推理。
- **Branch B:** 作为 `PLANNER_RESPONSE` 上的 `thinking` 字符串存储。适配器**仅在 `content` 缺失时
  将其用作 assistant `content` 的回退** — 实时数据中,在仅含工具的 planner 步骤上 `content` 键直接缺失
  (3 217 条记录),适配器将其归并为 `""` 然后替换为 `thinking`(`:354`,TS `:489`)。当 planner 步骤
  *同时* 有 `content` 和 `thinking` 时,`thinking` 被**丢弃**。

---

## 9. Token 用量与成本

**对 Antigravity 不适用 — 任何层都不存在 token/usage/cost/model 字段。**

- Branch A 缓存:无。Branch B transcript:无(无 `usage`、无 token 计数、无成本、无 model id)。
- `NormalizedMessage.usage` 被硬编码为 `nil`(`AntigravityAdapter.swift:360`);`model` 在
  每条解析路径中都为 `nil`(`:80`、`:317`)。`cascade.proto` 不暴露任何 usage 字段。
- Branch B 中的 `source:"MODEL"` 标签是一个通用角色标记,**不是** model id。
- → 无论真实用量如何,Antigravity 会话对 `get_costs` / token 分析的贡献为**零**。

---

## 10. 子智能体 / 父子关系 / 派发

**对 Engram 链接不适用 — Antigravity 内部的子智能体结构不用于 Engram 父/子分组。**

- Branch B 发出子智能体记录:`INVOKE_SUBAGENT`(24),以及工具调用 `invoke_subagent`(24)、
  `define_subagent`(18)、`manage_subagents`(2)。这些标记 Antigravity 内部的子智能体派发。
- 所有这些都被适配器**丢弃**(`INVOKE_SUBAGENT` 不在任何角色白名单中;
  `invoke_subagent`/`define_subagent` 仅作为发出它们的 planner 步骤上的 `tool_calls` 文本存活)。
  Engram **不**从中构建 `parent_session_id`/`suggested_parent_id` 链接。
- 与 Claude Code(基于路径的子智能体链接)或 Gemini CLI(`.engram.json` sidecar)不同,Antigravity
  **没有 sidecar、也没有 Engram 会消费的基于路径的父级编码**。两个分支在解析时都将
  `parentSessionId`/`suggestedParentId` 置为 `nil`(`:96-97`、`:334-335`);任何分组完全
  交给 Engram 下游的 parent-detection/tiering 流水线。

---

## 11. 摘要 / 压缩

- **Branch A:** meta 行中的 `summary` 字段(AI 生成,来自 gRPC;存在于 58 个文件中的 18 个)。
  适配器的会话 `summary` = `title` / `summary` / 首条用户文本中第一个非空者,截断至 200 字符
  (`:71,86`;TS `:326-328`)。
- **Branch B:** 无显式摘要字段。CLI 发出 `CONVERSATION_HISTORY` 边界标记(74)和
  `CHECKPOINT` 标记(5),它们 *形似* 压缩边界,但被适配器**丢弃**。
  会话 `summary` = 首条用户文本截断至 200 字符(`:324`;TS `:474`)。
- Engram 对任一分支都不执行真正的 transcript 压缩/轮转。

---

## 12. SQLite / DB 内部

**对 Antigravity 不适用** — 两个产品都不使用 SQLite 存储会话。Branch A 是加密的 protobuf
(`.pb`),前面有 gRPC 服务器;Branch B 是纯仅追加 JSONL。(Engram 自身的 `~/.engram/index.sqlite`
是聚合器 DB,不在本源格式文档范围内。)

### gRPC / protobuf 表面(Branch A,唯一的 "schema")

IDE 的 `.pb` 文件**在磁盘上不是普通 protobuf** — 它们是加密/不透明的。一个实时 `.pb` 显示
高熵字节,没有 protobuf 字段标签:

```
00000000: 775b be96 92da 43c2 ddba 2ca6 974f 080f  w[....C...,..O..
00000010: a1c4 37bc 1dc1 a712 776b f8b3 23f4 e810  ..7.....wk..#...
```

> **加密现已被刻画(web 已确认 2026-06-21):** `.pb` 加密不再是黑盒。它是经 macOS Keychain
>(service `Antigravity Safe Storage`)加密的 Electron `safeStorage`,具体为 **AES-128-CTR**,
> 16 字节密钥,IV = 文件前 16 字节;解密后载荷是标准 protobuf wire 格式(可能需跳过 0–4 个 header
> 字节)。"不透明 / 无文档的 `.pb` 字节布局" 这一待解问题从 *无文档* 降级为 *已被社区解密器记录*
> — Engram 只是选择不去解码它。较新的 IDE 版本也可能将对话存储为 SQLite `.db` 文件,而
> UUID→对话索引位于 `state.vscdb`(见 §2.1)
> ([decryptor](https://github.com/arashz/antigravity_decryptor))。

Engram 从不解码它们;它只读取**字节大小**(→ `pbSizeBytes`),其余则通过 gRPC 与
正在运行的 language server 通信。实际的 `cascade.proto`
(`macos/Shared/EngramCore/Adapters/Cascade/cascade.proto`)**极简** — 它只声明:

```protobuf
service LanguageServerService {
  rpc GetAllCascadeTrajectories(GetAllCascadeTrajectoriesRequest) returns (GetAllCascadeTrajectoriesResponse);
  rpc ConvertTrajectoryToMarkdown(ConvertTrajectoryToMarkdownRequest) returns (ConvertTrajectoryToMarkdownResponse);
}
message CascadeTrajectorySummary {
  string summary = 1; string trajectory_id = 4;
  Timestamp created_time = 7; Timestamp last_modified_time = 3;
  ConversationAnnotations annotations = 15;   // .title
}
message GetAllCascadeTrajectoriesResponse { map<string, CascadeTrajectorySummary> trajectory_summaries = 1; }
```

> **对维度报告的更正:** DIM 1 和 DIM 2 将 `GetCascadeTrajectory`、
> `Trajectory.steps[]`、`userInput`/`plannerResponse`/`notifyUser` 步骤类型、`workspaces[]`/`cwd` 以及
> `pbSizeBytes` 归因于 `cascade.proto`。**proto 不包含这些**。它们存在于 Swift gRPC
> 客户端 `CascadeClient.swift` 中,后者通过 HTTP/JSON 发起 `GetCascadeTrajectory`(未在
> 精简的 proto 中声明)并映射 JSON 响应:
> - `getTrajectoryMessages`(`CascadeClient.swift:55-90`)读取 `trajectory.steps[]`,通过
>   `.contains("USER_INPUT")` → user、`.contains("PLANNER_RESPONSE")` → assistant、
>   `.contains("NOTIFY_USER")` → assistant 匹配步骤 `type`。**只有这三个**步骤类型变成消息;
>   trajectory 内的所有工具/文件步骤都在 gRPC 边界被丢弃。
> - `cwd` 从 `workspaces[].workspaceFolderAbsoluteUri`(`:128-136`)读取,`createdAt` 从
>   `createdTime` 读取,等等。因此即使是(现已非产品的)实时 sync 路径也会丢失 Branch A 工具调用。

---

## 13. 辅助文件

| Path | Content | Engram reads? |
|---|---|---|
| `~/.gemini/antigravity/daemon/ls_<hex>.log` | Go language-server 日志 | No(仅发现,实时时) |
| `~/.gemini/antigravity/agyhub_summaries_proto.pb`、`antigravity_state.pbtxt`、`user_settings.pb`、`installation_id`、`browserAllowlist.txt` | 聚合引擎状态 | No |
| `~/.gemini/antigravity-cli/brain/<uuid>/transcript_full.jsonl` | 超集 transcript(同 schema),128 个目录 | **No**(从不枚举) |
| `.../.system_generated/messages/<uuid>.json` | 智能体间消息总线 blob。**结构多变。** 大多数文件是单个消息对象 — 基础键 `{id, sender, recipient, content, priority, renderDetails, timestamp}` 加上可选的 `hideFromUser`(bool)和 `sourceMetadata`(object);`renderDetails` 有时省略。**但部分文件是以 UUID 为键的 MAP**(顶层键是裸消息 UUID,而非字段名),少数文件是一个微小的 `{last_read_unix_nano}` 游标文件。 | **No**(比 JSONL 更丰富,但被忽略) |
| `.../.system_generated/tasks/task-<n>.log` | 任务执行日志 | No |
| `<uuid>/implementation_plan.md`、`review_report.md` | 用户可见的 artifact | No |
| `<uuid>/<name>.md.metadata.json` | artifact sidecar — **键随变体而定。** 始终有 `{summary, updatedAt}`;然后可选 `artifactType`(str)、`requestFeedback`(bool)、`userFacing`(bool)。实时变体:`{artifactType, summary, updatedAt}`(7)、`{summary, updatedAt, userFacing}`(3)、`{artifactType, requestFeedback, summary, updatedAt}`(1)— 没有单一规范的完整集合。**Web 已确认 2026-06-21:** 社区 CLI 文档另外显示新/其他变体中有 `version`(递增)和 `sourceFile` 键,与 `task.md` / `implementation_plan.md` / `walkthrough.md` 配对([unofficial CLI](https://github.com/michaelw9999/antigravity-cli))。 | No |

---

## 14. Engram 映射

`NormalizedSessionInfo` 字段 ← 来源。**A** = Branch A(缓存),**B** = Branch B(CLI transcript)。

| Engram field | Branch | Swift (`AntigravityAdapter.swift`) | TS (`antigravity.ts`) | Derivation |
|---|---|---|---|---|
| `id` | A | `:55,73` | `:250,316` | `meta.id`(UUID);为空则失败 |
| `id` | B | `:305` `cliSessionId` `:384-414` | `:461,520-544` | 从路径解析的 brain `<uuid>` 目录名;回退 = 文件名主干 |
| `source` | both | `:75`(`.antigravity`) | `:317`(`"antigravity"`) | 常量 |
| `startTime` | A | `:76` | `:318` | `meta.createdAt` |
| `startTime` | B | `:286-288,314` | `:452,464` | 首条记录的 `created_at` |
| `endTime` | A | `:77` | `:319` | `meta.updatedAt`,**仅当 ≠ createdAt**,否则 `nil` |
| `endTime` | B | `:289-291,315` | `:453,467` | 末条记录的 `created_at`,仅当 ≠ start |
| `cwd` | A | `:69,416-424` | `:295-313` | 存在则用 `meta.cwd`;否则从前 50 KB 中的绝对路径推断 |
| `cwd` | B | `:316,416-424` | `:468,546-564` | 始终推断(transcript 中无 cwd) |
| `project` | both | `:79`(`nil`) | (absent) | 从不设置 — 留给 indexer |
| `model` | both | `:80`(`nil`) | (absent) | 从不设置(§9) |
| `messageCount` | A | `:81` | `:321` | `userCount + assistantCount` |
| `messageCount` | B | `:319` | `:469` | `user + assistant + tool` |
| `userMessageCount` | A | `:63,82` | `:283-285,322` | `role=="user"` 缓存行 |
| `userMessageCount` | B | `:293-295,321` | `:454-456,471` | `USER_INPUT` 计数 |
| `assistantMessageCount` | A | `:64,83` | `:286,323` | `role=="assistant"` 计数 |
| `assistantMessageCount` | B | `:296-297,322` | `:457,472` | `PLANNER_RESPONSE` 计数 |
| `toolMessageCount` | A | `:84`(`=0`) | `:324`(`=0`) | 始终 0 |
| `toolMessageCount` | B | `:298-299,323` | `:458,473` | 已映射的工具记录(**Swift:≈仅 VIEW_FILE;TS:所有带内容的其他类型** — §7) |
| `systemMessageCount` | both | `:85,323`(`=0`) | `:325,473`(`=0`) | 始终 0 |
| `summary` | A | `:71,86` | `:326-328` | `title` ?? `summary` ?? firstUserText,截断 200 |
| `summary` | B | `:324` | `:474` | firstUserText,截断 200 |
| `filePath` | both | `:87,326` | `:329,475` | `.jsonl` 定位路径 |
| `sizeBytes` | A | `:88,233-245` | `:259-268,330` | `meta.pbSizeBytes` 若 >0;否则 stat `.pb`;否则 stat 缓存文件 |
| `sizeBytes` | B | `:326` | `:439,476` | transcript 文件的 stat |
| `NormalizedMessage.usage` | both | `:360`(`nil`) | not set | 从不设置(§9) |
| `NormalizedToolCall` | B | `cliToolCalls` `:370-382` `{name, input=jsonString(args,500), output:nil}` | `:502-518` `{name, input=truncateJSON(args,500)}` | 仅调用;**无 output 关联** |
| `agentRole`/`originator`/`origin`/`parentSessionId`/`suggestedParentId`/`tier`/`qualityScore`/`indexedAt`/`summaryMessageCount` | both | `:89-97,327-335` 全为 `nil` | (absent) | 留给 indexer / parent-detection / tiering |

**发现与路由辅助:**
- `detect()`(`:36-40`;TS `:51-68`):若 `daemonDir`、`cacheDir`、`cliBrainDir` 任一存在则为 true。
- `listSessionLocators()`(`:42-45`):先 `sync()`,然后将缓存 `.jsonl` 定位符
  (`CascadeCacheSupport.jsonlLocators`,`WindsurfAdapter.swift:6-11`)与 CLI transcript 定位符
  (`cliTranscriptLocators`,`:247-260`)的排序并集返回。
- `isCLITranscript()`(`:262-270`;TS `:424-433`):路径位于 `brain/` 根之下,或匹配
  `…/.gemini/antigravity-cli/brain/…/.system_generated/logs/transcript.jsonl`。

---

## 15. 血统、坑、版本漂移与边界情况

### 15.1 共享格式血统

**Branch A ↔ Windsurf — Cascade/Codeium 双胞胎(最强血统)。** Antigravity Branch A 和
**Windsurf** 都构建在 Codeium 的 **Cascade** 引擎上,共享:
- **相同的 gRPC 服务** `exa.language_server_pb.LanguageServerService`(`cascade.proto`、
  `CascadeClient.swift`),相同的 RPC `GetAllCascadeTrajectories` / `ConvertTrajectoryToMarkdown`(+ 客户端的
  `GetCascadeTrajectory`)。
- **完全相同的缓存 JSONL 格式**(meta 行 + `{role,content}` 行),由 **共享的**
  `CascadeCacheSupport` enum(`WindsurfAdapter.swift:3-95`,被 `AntigravityAdapter` 和
  `WindsurfAdapter` 同时使用)生产/读取,以及共享的 markdown 解析器(`## User` / `## Cascade` 头,
  `parseMarkdownToMessages`)。
- 相同的 `.pb`-在-`conversations/` + `.jsonl`-在-`~/.engram/cache/` 镜像模式,以及 "Cascade"
  assistant 标签。
- **差异:** Antigravity 位于 `~/.gemini/antigravity/`,Windsurf 位于 `~/.codeium/windsurf/`。
  Antigravity 增加了 `getTrajectoryMessages`/`GetCascadeTrajectory` 主路径、`pbSizeBytes`
  字段,以及 `.pb` 扫描回填(`syncFromPbFiles`);Windsurf 仅 markdown。两者在产品中均为
  `enableLiveSync:false` 且仅缓存。**对缓存格式 / Cascade RPC 的任何修复都必须
  在两个适配器之间镜像。**

**Branch B ↔ Gemini-CLI 家族(仅 home 目录血统)。** Branch B 位于 `~/.gemini/antigravity-cli/`,
与 Gemini CLI(及其分支 Qwen Code、iFlow、Kimi、MiniMax)共享 `~/.gemini/` home。但
**transcript 格式不共享** — Gemini CLI 使用它自己的会话 JSON;Antigravity CLI 的 brain
transcript 是一个独特的 `type`/`source`/`step_index` 智能体事件日志。这里的血统是
**组织性的**(Google "Antigravity" 品牌 + `.gemini/` home),而非结构性的。
`tool_calls`-带-`{name,args}` + `.system_generated/` 形态更接近智能体步骤日志,而非
聊天历史。

**Engram 内部的 Source-ID 血统。** 产品 `SourceName` 枚举 case `antigravity` 定义在
`Shared/EngramCore/Adapters/SessionAdapter.swift:19`(已验证:该行字面就是 `case antigravity`)。
它是**两个**分支共用的单一产品来源。**`antigravityLegacy = "antigravity-legacy"`**
case **不**位于 `SessionAdapter.swift` — 它是 project-move 层中的一个独立枚举
(`EngramCoreWrite/ProjectMove/Sources.swift:43` `case antigravity`、`:44`
`case antigravityLegacy = "antigravity-legacy"`),用于对旧 IDE conversations 目录进行路径重写
(`:415` doc comment、`:462-468` 路径映射 — `:462-463` 将 `.antigravity` → `.gemini/antigravity-cli/brain`,
`:467-468` 将 `.antigravityLegacy` → `.gemini/antigravity`)。读取时 `"antigravity-legacy"` 会
塌缩回 `.antigravity`(`EngramServiceReadProvider.swift:1017`;另见 `TranscriptExportService.swift:415`、
`SystemMessageClassifier.swift:13`)。

### 15.2 坑、漂移、边界情况

1. **产品 = 仅缓存(Branch A)/ 实时(Branch B)。** 在 `enableLiveSync:false` 下,Branch A 只暴露
   早先由非产品 TS 路径写入的缓存文件。一台没有任何先前 TS 运行的纯 Swift 全新安装 →
   **没有 IDE Cascade 会话**,只有 CLI brain transcript;`.pb` 文件原封不动。
2. **Swift↔TS Branch B 分歧(实时,CI 未覆盖)。** §7 — TS 将每条带内容的
   非 USER/非 PLANNER 记录计为工具消息;Swift 只映射 `VIEW_FILE`(加 3 个死类型)。同一文件的工具
   计数和流式内容不同;parity fixture 不含任何分歧类型。
3. **死的 Swift switch case = 版本漂移。** `TOOL_OUTPUT` / `COMMAND_OUTPUT` / `SHELL_OUTPUT` /
   `APPLY_PATCH`(`:362`)匹配**零**条实时记录。真实工具输出(`RUN_COMMAND`、`GREP_SEARCH`、
   `CODE_ACTION`、…)未被处理 — 适配器解析的是过时的记录类型词汇表。
4. **`cwd` 推断 Swift 与 TS 不同。** TS 使用一个绑定到该用户目录布局的
   **硬编码 `/Users/<user>/-Code-/<project>` 正则**(`antigravity.ts:299,311,550,559`)— 在任何非
   `-Code-` 布局上都是错的。Swift 将其替换为一个**通用的最频繁目录启发式**
   (`inferCWDFromAbsolutePaths`,`:430-455`),不对用户做任何假设。同一文件推断出的 cwd 会
   不同;Swift 的那个是可移植/正确的。
5. **`createdAt === updatedAt` → 无 `endTime`。** 对短对话很常见;此时 Engram 只有一个
   开始时间(`:77`、`:319`)。
6. **`pbSizeBytes` 与缓存大小不匹配。** `sizeBytes` 报告的是 `.pb` 大小(KB → 数十 MB,一个
   实时文件 25.9 MB),而缓存 `.jsonl` 只有几 KB。基于大小的 UI/排序反映的是完整
   对话,而非存储的文本。≤ 200 字节的缓存文件被新鲜度闸门视为 "无内容"
   (`:188,220-223`;TS `:95,174`)。
7. **gRPC 列表只返回约 10 个最近的**(TS 注释 `:140,148`);`syncFromPbFiles` 回填其余 —
   但仅在 live-sync(非产品)路径中。
8. **`getTrajectoryMessages` 扁平化为仅 user/assistant 文本**(`CascadeClient.swift:55-90`):只有
   `USER_INPUT`/`PLANNER_RESPONSE`/`NOTIFY_USER` 步骤 → 消息;trajectory 中所有工具/文件步骤
   都在 gRPC 边界被丢弃。因此即使实时 sync 也会丢失 Branch A 工具调用。
9. **三级内容回退(Branch A sync):** trajectory 消息 → markdown(`## User`/`## Cascade`)
   → 对话摘要作为单条 assistant 消息(Swift `:153-161`;TS `:103-112`)。因此一个缓存文件
   可能只包含一条合成的 assistant 行。
10. **零 token/成本贡献**(§9)— Antigravity 会话在任何成本仪表板中显示为零成本。
11. **更丰富的每条消息 JSON 被忽略。** `.system_generated/messages/*.json`(基础键
    `{id, sender, recipient, content, priority, renderDetails, timestamp}` 加上可选的 `hideFromUser`
    和 `sourceMetadata`;部分文件转而是以 UUID 为键的此类对象 MAP — 见 §13/§16.9)比
    扁平化的 `transcript.jsonl` 含有更多结构,但适配器只读 JSONL。未来的
    保真度工作应针对这些(并可能弥补时间戳缺口)。
12. **`status:"ERROR"` 存在**(85 条实时记录),超出 DONE/RUNNING — 适配器完全不在
    `status` 上分支,因此 error/running 步骤像其他记录一样按 `type` 解析。

### 15.3 待解问题 / 已解决(web 已确认 2026-06-21)

- **`.pb` 字节布局 / 加密** — **已确认(官方/社区):** 不再 "无文档"。
  `~/.gemini/antigravity/conversations/` 中的 IDE 对话 `.pb` 文件使用 Electron 的 `safeStorage` API 加密,
  经 macOS Keychain(service 名 `Antigravity Safe Storage`)派生密钥;密钥与硬件绑定,因此没有它原始
  字节实际上是随机噪声(与 §12 中高熵 / 不透明的观察一致)。具体方案是 **AES-128-CTR**,16 字节密钥,
  IV = 文件前 16 字节;解密后载荷**就是** protocol-buffer wire 格式(可能需跳过 0–4 个 header 字节)。
  因此 *用 Keychain 密钥* 是可以解码的 — Engram 只是选择从不解码它,这一点仍然成立
  ([decryptor](https://github.com/arashz/antigravity_decryptor)、
  [reverse-engineering writeup](https://ericxliu.me/posts/reverse-engineering-antigravity-ide/)、
  [DB recovery tool](https://github.com/ag-donald/Antigravity-Database-Manager))。
- **完整的步骤级字段语义**(model、tokens、二进制 trajectory 内的工具 I/O)— **部分确认(社区):**
  gRPC trajectory 表面是真实的 — 实时 RPC 是
  `exa.language_server_pb.LanguageServerService/ConvertTrajectoryToMarkdown`(与 `cascade.proto` 及
  `CascadeClient` 的断言相符)。解密后的 `.pb` 是 protobuf,但没有任何公开来源发布带 model/token 语义的
  完整字段级 schema;逆向工程者只通过 wire-walking 提取了消息内容/长度/元数据。内部的每步语义在公开
  范围内仍大体未被枚举,与 "无法仅从本仓库枚举出来" 一致
  ([reverse-engineering writeup](https://ericxliu.me/posts/reverse-engineering-antigravity-ide/)、
  [decryptor](https://github.com/arashz/antigravity_decryptor))。
- **死的 Swift 工具结果类型**(`TOOL_OUTPUT`/`COMMAND_OUTPUT`/`SHELL_OUTPUT`/`APPLY_PATCH`)— 是否
  有任何 Antigravity-CLI 版本曾发出过它们,还是它们是推测性的猜测,未经确认(无实时
  证据)。**(web-checked 2026-06-21: no authoritative source found — 官方教程、官方 CLI 仓库、
  codelab 以及泄露的 CLI system prompt 都列举了 `USER_INPUT`、`PLANNER_RESPONSE`、
  `CONVERSATION_HISTORY`、`SEARCH_WEB`、`VIEW_FILE` 等,但都没有这四个;不存在并不能证明它们从未
  存在过。)**
- **Swift↔TS Branch B 的预期行为** — Swift 应该采用 TS 的通用工具回退,还是丢弃才
  正确?含糊;parity fixture 未触发。**(Engram-internal design — not web-verifiable。)**
- **Fixture `timestamp`** 在缓存消息行上(`conv-001.jsonl`)— 没有任何实时缓存文件有它,且
  `writeCache` 无法产生它;该 fixture 是过期/愿景式的,还是反映了某种较旧的缓存
  格式,未经确认。**(Engram-internal design — not web-verifiable:这是由 Engram 自身的
  `CascadeCacheSupport` 写入器产生的 Engram 自有缓存文件,而非 Antigravity 写入,因此没有官方
  Antigravity 来源适用。)**
- **`transcript_full.jsonl` vs `transcript.jsonl`** — **已确认(官方):** 记录 schema 相同;精确的
  超集差异是**大输出截断**。`transcript.jsonl` 是一个 token 高效的日志,*截断* 大文本 / 工具输出以
  节省空间,而 `transcript_full.jsonl` 是包含确切工具结果和文本的完整、未截断日志。它不是额外的
  记录*类型* — 只是截断。Engram 完全忽略 `_full`
  ([conversations tutorial](https://medium.com/google-cloud/antigravity-cli-tutorial-series-part-2-conversations-conversations-conversations-76f61756d5bb)、
  [hands-on codelab](https://codelabs.developers.google.com/antigravity-cli-hands-on))。
- **`truncated_fields` 语义** — **已确认(官方):** 它是一个**字段名字符串数组**,指明
  `content` / `thinking` / `tool_calls` 中哪些被 CLI 在写记录时截断了 — 它是区分被截断的
  `transcript.jsonl` 与未截断的 `transcript_full.jsonl` 的同一截断机制的每记录标记。实时不同值:
  `["content"]`(958)、`["tool_calls"]`(89)、`["thinking"]`(27)、`["thinking","tool_calls"]`(14)、
  `["content","thinking"]`(9)
  ([conversations tutorial](https://medium.com/google-cloud/antigravity-cli-tutorial-series-part-2-conversations-conversations-conversations-76f61756d5bb))。
- **Branch B transcript 记录 schema**(type、step_index、source、status、created_at、content、
  tool_calls 等)— **已确认(官方):** 每个 `transcript.jsonl` 行是一个表示步骤的 JSON 对象,字段有
  `step_index`、`source`(`USER_EXPLICIT` / `MODEL` / `SYSTEM`)、`type`(`USER_INPUT`、
  `PLANNER_RESPONSE`、`VIEW_FILE`、`SEARCH_WEB`、`CONVERSATION_HISTORY` 等)、`status`(`DONE`,并显示
  `ERROR`)、`content`、`created_at` 以及 `tool_calls`(含 `arguments` 的数组)。这与 §4.2 / §5.2 完全
  吻合,包括 `source` 枚举值和 DONE/ERROR 的 `status` 值(验证了 §5.2 "status 有三个值含 ERROR" 的
  更正)
  ([conversations tutorial](https://medium.com/google-cloud/antigravity-cli-tutorial-series-part-2-conversations-conversations-conversations-76f61756d5bb)、
  [leaked CLI system prompt](https://github.com/asgeirtj/system_prompts_leaks/blob/main/Google/antigravity-cli.md))。
- **子智能体记录 / 工具**(`INVOKE_SUBAGENT`、`invoke_subagent`、`define_subagent`、`send_message`)—
  **已确认(官方):** 官方 CLI 仓库描述了可以 "spawn focused subagents for parallel work" 的编排,泄露的
  system prompt 明确命名了 `invoke_subagent`、`define_subagent` 和 `send_message`("ONLY for
  communicating with other agents"),外加一个反应式的 wakeup/inbox 模型。这验证了 §7 的工具列表新增项和
  §10 的子智能体派发描述是真实的 Antigravity 行为
  ([leaked CLI system prompt](https://github.com/asgeirtj/system_prompts_leaks/blob/main/Google/antigravity-cli.md)、
  [official CLI repo](https://github.com/google-antigravity/antigravity-cli))。
- **Artifact sidecar `<name>.md.metadata.json` 键** — **已确认(社区):** 一个非官方 CLI 工具记录了
  brain 布局,`task.md` / `implementation_plan.md` / `walkthrough.md` 各配一个 `.md.metadata.json`
  sidecar,其字段包括 `artifactType`、`summary`、`updatedAt`(ISO-8601),加上 `version`(递增)和
  `sourceFile`。§13 / §16.10 观察到的始终存在的 `{summary, updatedAt}` 加可选 `artifactType` 与之一致;
  `version` / `sourceFile` 出现在新/其他变体中(见 §13 更新)
  ([unofficial CLI](https://github.com/michaelw9999/antigravity-cli)、
  [hands-on codelab](https://codelabs.developers.google.com/antigravity-cli-hands-on))。
- **`cascade.proto` / gRPC RPC 名**(`GetAllCascadeTrajectories`、`ConvertTrajectoryToMarkdown`)—
  **已确认(社区):** 独立的逆向工程识别出实时端点
  `exa.language_server_pb.LanguageServerService/ConvertTrajectoryToMarkdown`(一个返回编码会话 markdown 的
  gRPC-over-HTTP 服务),与 §12 `cascade.proto` 中的 service/RPC 名以及 §15.1 的 Windsurf/Cascade 血统
  断言完全吻合
  ([reverse-engineering writeup](https://ericxliu.me/posts/reverse-engineering-antigravity-ide/))。

---

## 16. 附录:真实的匿名样本

> 结构逐字保留;消息文本 / 路径 / 密钥已替换。

### 16.1 Branch A — 缓存 meta 行(最小 key 集,40/58 文件)
```json
{"id":"<uuid>","title":"","createdAt":"2026-02-19T15:47:16.862Z","updatedAt":"2026-02-19T15:47:16.862Z","pbSizeBytes":1113514}
```

### 16.2 Branch A — 缓存 meta 行(完整 key 集,18/58 文件)
```json
{"id":"<uuid>","title":"<str len=23>","summary":"<str len=23>","createdAt":"2026-02-24T05:00:52.882699Z","updatedAt":"2026-02-24T05:01:09.968924Z","cwd":"/Users/<user>/-Code-/<project>","pbSizeBytes":158073}
```

### 16.3 Branch A — 缓存消息行
```json
{"role":"user","content":"<text>"}
{"role":"assistant","content":"<text>"}
```

### 16.4 Branch B — `USER_INPUT`
```json
{"type":"USER_INPUT","step_index":3,"source":"USER_EXPLICIT","status":"DONE","created_at":"2026-05-19T23:58:09Z","content":"<user text>"}
```

### 16.5 Branch B — `PLANNER_RESPONSE`,带 thinking + tool_calls
```json
{"type":"PLANNER_RESPONSE","step_index":42,"source":"MODEL","status":"DONE","created_at":"2026-05-19T23:59:01Z","thinking":"<reasoning text>","tool_calls":[{"name":"view_file","args":{"AbsolutePath":"/abs/path/file.swift","StartLine":1,"EndLine":80,"toolAction":"<ui action label>","toolSummary":"<ui summary>"}}]}
```

### 16.6 Branch B — 工具结果记录(`VIEW_FILE`)
```json
{"type":"VIEW_FILE","step_index":43,"source":"SYSTEM","status":"DONE","created_at":"2026-05-19T23:59:02Z","content":"<file contents>"}
```

### 16.7 Branch B — `ERROR_MESSAGE`(以及 `status:"ERROR"` 变体)
在实时 `ERROR_MESSAGE` 记录上,`content` **键缺失**(或是非空字符串)— 它从不是
JSON `null`。(适配器能容忍 `null`,但 CLI 从不发出它。)
```json
{"type":"ERROR_MESSAGE","step_index":120,"source":"SYSTEM","status":"DONE","created_at":"2026-05-20T00:10:00Z","error":"<error string len=109>"}
{"type":"GREP_SEARCH","step_index":121,"source":"MODEL","status":"ERROR","created_at":"2026-05-20T00:10:05Z","content":"<partial output>"}
```

### 16.8 Branch B — `CONVERSATION_HISTORY`(无 `content` 键)
```json
{"type":"CONVERSATION_HISTORY","step_index":9,"source":"SYSTEM","status":"DONE","created_at":"2026-05-20T00:00:00Z"}
```

### 16.9 辅助 — `.system_generated/messages/<uuid>.json`(被 Engram 忽略,结构多变)
单消息对象变体(最常见;显示可选的 `hideFromUser` / `sourceMetadata`):
```json
{"id":"<uuid>","sender":"<agent>","recipient":"<agent>","priority":"<str>","timestamp":"<iso>","renderDetails":{},"content":"<text>","hideFromUser":false,"sourceMetadata":{}}
```
以 UUID 为键的 MAP 变体(部分文件 — 顶层键是消息 UUID,值是上面的消息对象):
```json
{"<msg-uuid-1>":{"id":"<msg-uuid-1>","sender":"<agent>","recipient":"<agent>","content":"<text>", "...":"..."},"<msg-uuid-2>":{"...":"..."}}
```

### 16.10 辅助 — artifact sidecar `<name>.md.metadata.json`(被 Engram 忽略,键多变)
`{summary, updatedAt}` 始终存在;其余视变体而定。
```json
{"artifactType":"<str>","summary":"<str>","updatedAt":"<iso>","requestFeedback":false}
{"summary":"<str>","updatedAt":"<iso>","userFacing":true}
{"artifactType":"<str>","summary":"<str>","updatedAt":"<iso>"}
```

### 16.11 `cascade.proto`(Branch A gRPC wire 表面 — 实际仓库文件)
```protobuf
service LanguageServerService {
  rpc GetAllCascadeTrajectories(GetAllCascadeTrajectoriesRequest) returns (GetAllCascadeTrajectoriesResponse);
  rpc ConvertTrajectoryToMarkdown(ConvertTrajectoryToMarkdownRequest) returns (ConvertTrajectoryToMarkdownResponse);
}
message CascadeTrajectorySummary {
  string summary = 1;
  string trajectory_id = 4;
  Timestamp created_time = 7;
  Timestamp last_modified_time = 3;
  ConversationAnnotations annotations = 15;  // .title
}
message GetAllCascadeTrajectoriesResponse {
  map<string, CascadeTrajectorySummary> trajectory_summaries = 1;
}
```

---

## References (official sources)

Web 确认轮次,2026-06-21(`web_access_ok=true`)。用于解决 §15.3 并应用 §1 / §2.1 / §12 / §13 更正的
来源:

- [Romin Irani — Antigravity CLI Tutorial Series Part 2: Conversations (Google Cloud Community)](https://medium.com/google-cloud/antigravity-cli-tutorial-series-part-2-conversations-conversations-conversations-76f61756d5bb) — community
- [google-antigravity/antigravity-cli (official Google Antigravity CLI repo)](https://github.com/google-antigravity/antigravity-cli) — repo
- [Hands-on with Antigravity CLI (Google Codelabs)](https://codelabs.developers.google.com/antigravity-cli-hands-on) — docs
- [Eric X. Liu — Reverse Engineering the Antigravity IDE](https://ericxliu.me/posts/reverse-engineering-antigravity-ide/) — community
- [arashz/antigravity_decryptor (decrypts IDE .pb conversation files)](https://github.com/arashz/antigravity_decryptor) — repo
- [ag-donald/Antigravity-Database-Manager (recovers IDE conversation history from .pb files)](https://github.com/ag-donald/Antigravity-Database-Manager) — repo
- [michaelw9999/antigravity-cli (unofficial CLI for tasks/artifacts)](https://github.com/michaelw9999/antigravity-cli) — repo
- [asgeirtj/system_prompts_leaks — Google/antigravity-cli.md (leaked CLI system prompt)](https://github.com/asgeirtj/system_prompts_leaks/blob/main/Google/antigravity-cli.md) — community
- [Antigravity 2.0 and IDE (CLI too) — Shared Brain (Google AI Developers Forum)](https://discuss.ai.google.dev/t/antigravity-2-0-and-ide-cli-too-shared-brain/167445) — community
