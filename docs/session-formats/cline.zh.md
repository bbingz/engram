# Cline — 会话格式参考

> 本文档为英文权威版 cline.md 的中文阅读副本;若有出入以英文版为准。

Last researched: 2026-07-02 (Engram provider audit recheck)

> **同类文档:** Cline **不**属于 VS Code / Cursor / Copilot 的 `state.vscdb` 存储家族(见 [§15](#15-lineage-gotchas-version-drift--edge-cases))。它有自己的"每个任务一个 JSON 数组"格式。它真正的同类是下游分支 **Roo Code** 和 **Kilo Code**,二者复用完全相同的 schema,但没有对应的 Engram 适配器。本文档自成体系。

---

## 1. Overview & TL;DR

**是什么:** Cline(一个自主编码 agent)把每个*任务*(一次对话/会话)持久化为**一个目录的纯 JSON 文件**。没有数据库、没有 JSONL、没有 leveldb、没有 gRPC 缓存。

**在哪里:** 本机上的实时存储采用 **Cline 独立 CLI** 布局,根目录为 `~/.cline/data/tasks/`。每个任务是一个子目录,以任务创建时间(自 epoch 起的毫秒数)命名(例如 `1771763997801`)。

**如何保存:** 每个任务目录包含 4–5 个文件。其中两个大文件(`ui_messages.json` + `api_conversation_history.json`)在**每一轮都被完整重写**(对整个数组做读-改-写——不是追加)。会话 ID 就是目录名,它等于第一条记录的 `ts`。

**Engram 的心智模型:** Engram 优先解析 `ui_messages.json`(UI 渲染日志),仅在它不存在时回退到遗留 `claude_messages.json`。它忽略内容更丰富的 Anthropic 格式 `api_conversation_history.json` 以及所有其他同级文件。在选中的 UI-message 数组中,它只把 3 种记录子类型保留为消息(`task`/`user_feedback` → user,非 partial 的 `text` → assistant)——这是从实时观察到的约 17 种里取的(完整的 `ClineSay`/`ClineAsk` 词汇表更大——约 35 + 18 个成员;见 [§4](#4-record--line-taxonomy)),只为了 token 用量而读取 `api_req_started` 记录,并用正则从请求提示词中抽取 `cwd`。

```
                  Cline CLI process
                         │ read-modify-write whole arrays every turn
                         ▼
~/.cline/data/tasks/<taskIdMs>/         ← task dir name == session id == first ts
   ├── ui_messages.json            ── ARRAY of UI events  ◀── ENGRAM PREFERS THIS (locator)
   ├── claude_messages.json        ── legacy UI-event filename (fallback if ui_messages is absent)
   ├── api_conversation_history.json ─ ARRAY of Anthropic msgs (thinking/tool_use)  ✗ ignored
   ├── task_metadata.json          ── OBJECT: files/model/env ledgers              ✗ ignored
   ├── context_history.json        ── nested ARRAY: context-truncation log (optional) ✗ ignored
   └── focus_chain_taskid_<id>.md  ── markdown TODO checklist                       ✗ ignored

~/.cline/data/state/taskHistory.json  ── Cline's OWN task index (id/ulid/tokens/cwd)  ✗ ignored

ENGRAM LAYERING (what it reads):
  record (envelope: ts/type/say/ask/text/partial/modelInfo/...)
     └── nested payload (say=api_req_started: text is a JSON string → request/tokensIn/tokensOut/...)
     └── nested payload (say=tool: text is a JSON string → tool/path/content/...)   ← skipped
```

**证据基础:** 实时磁盘存储**以及**仓库 fixtures,并与两个适配器交叉核对。
- **实时存储:** `~/.cline/data/tasks/` —— **3 个任务目录**(`1771763997801`、`1771764735752`、`1771767068013`)。对 `ui_messages.json` 做了深度采样(分别为 **283 / 509 / 56 条原始记录**;最大约 953 KB),外加每个目录内的所有同级文件。⚠️ *不要把原始记录数与 Engram 推导出的 `messageCount` 混为一谈*(每个任务 30 / 40 / 10 条——见 [§14](#14-engram-mapping)),也不要与**全局** `partial:false` 计数(三个任务合计 216)混淆。早先的 "283/216/40" 一行把这三个不同的数字混在了一起。
- **仓库 fixture:** `tests/fixtures/cline/tasks/1770000000000/ui_messages.json`(4 条记录,835 B)。
- **Parity golden:** `tests/fixtures/adapter-parity/cline/success.expected.json` + 配套的 `input/tasks/1770000000000/ui_messages.json`(schemaVersion 1,在 commit `88f86631` 生成)。
- **适配器:** `macos/Shared/EngramCore/Adapters/Sources/ClineAdapter.swift`(产品)和 `src/adapters/cline.ts`(TS 参考/parity)。

**当前 Engram 状态:** 2026-07-02 只读 smoke 列出并解析了 3/3 个 Cline locator,stream 出 80 条消息(17 user + 63 assistant),并把 usage 挂到了全部 63 条 assistant 消息上;parser/stream count mismatch 为 0。实时 Engram DB 正好有 3 条 `cline` 行和 3 条 `file_index_state` 行(`ok`,schema v1),当前 locator 缺失 0、DB-only 行 0、parser-owned 字段陈旧 0、index-only locator 0。

**冲突/差异:** 当前实时数据与 DB locator 覆盖仍符合适配器假设。2026-07-01 复核发现并修复了一处仅存在于保留 TS 工具链的漂移:连续 `api_req_started` token ledger 在下一条 assistant 消息前被覆盖而不是累加;Swift 已经是累加行为;2026-07-02 smoke 确认当前 TS stream 已在全部 63 条 assistant 消息上暴露 usage。**与任务提示存在一处差异**(在 [§15](#15-lineage-gotchas-version-drift--edge-cases) 中标注):提示猜测的是一种 VS Code 扩展布局(`globalStorage/<ext-id>/tasks/...`)。已确认(官方):提示(VS Code `globalStorage/saoudrizwan.claude-dev/tasks/`)与本文档(CLI `~/.cline/data/tasks/`)是**同一条代码路径**——`getGlobalStorageDir("tasks", taskId) = path.resolve(HostProvider.globalStorageFsPath, "tasks", taskId)`——只是宿主基目录(`HostProvider.globalStorageFsPath`)不同([disk.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/core/storage/disk.ts)、[issue #7929](https://github.com/cline/cline/issues/7929))。本机实际使用的根目录是 `~/.cline/data/tasks/`(Cline CLI,`cline_version 3.66.0`,`host_name "Cline CLI - Node.js"`);本机不存在 VS Code 的 `globalStorage` Cline 目录。**Engram 适配器把 `~/.cline/data/tasks/` 硬编码为唯一扫描根**——这处硬编码是 Engram 侧的局限,不是 Cline 的属性(Cline 的路径由宿主派生,且可经 `CLINE_DIR` / `--data-dir` / `--config` 覆盖)。

---

## 2. On-disk layout & file naming

| 方面 | 值 | 来源 |
|---|---|---|
| Root (default) | `~/.cline/data/tasks/`(Engram 硬编码)。Cline 自身派生 `<HostProvider.globalStorageFsPath>/tasks/`:VS Code → `globalStorage/saoudrizwan.claude-dev/tasks/`,CLI → `~/.cline/data/tasks/`(可经 `CLINE_DIR`/`--data-dir`/`--config` 覆盖) | `ClineAdapter.swift:9-11`; `cline.ts:29`; [disk.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/core/storage/disk.ts) |
| Storage tech | 每个任务一个纯 JSON 文件目录(整数组 JSON;**不是** JSONL/SQLite/leveldb/gRPC) | live store; `Phase4AdapterSupport.readJSONArray` |
| Locator / index anchor | 每个任务目录内优先 `ui_messages.json`;若不存在则回退到遗留 `claude_messages.json` | `ClineAdapter.swift:27-35`; `cline.ts:45-57` |
| Session ID | 任务目录名(毫秒级 epoch 字符串) | `ClineAdapter.swift:49`; `cline.ts:69` |
| Detection | `~/.cline/data/tasks` 存在且是目录 | `ClineAdapter.swift:18-20`; `cline.ts:32-39` |

**命名规则。** 每个任务目录为 `<taskId>`,其中 `taskId` = 任务创建时间(**自 epoch 起的毫秒数**,例如 `1771763997801` ≈ 2026-02-22)。它也是第一条记录的 `ts`(`messages.first.ts === taskId`,实测验证:首条记录 `ts: 1771763997805` vs 目录 `1771763997801`——相差约 4 ms)。focus-chain 文件把 id 内嵌在文件名中:`focus_chain_taskid_<taskId>.md`。**没有按会话滚动:** 一个任务 = 一个目录,终其一生不变;恢复任务会重新打开同一目录。

**每个任务目录中的文件种类:**

| 文件 | 命名 | 顶层类型 | 可选性 |
|---|---|---|---|
| `ui_messages.json` | 固定 | UI 事件的 JSON **数组** | 现代 locator;当前 3 个实时任务均存在 |
| `claude_messages.json` | 固定遗留名 | UI 事件的 JSON **数组** | 仅 legacy fallback;当前实时任务为 0 |
| `api_conversation_history.json` | 固定 | LLM 消息的 JSON **数组** | 始终存在 |
| `task_metadata.json` | 固定 | JSON **对象**(3 个数组) | 始终存在 |
| `context_history.json` | 固定 | 嵌套 JSON **数组** | **可选** —— 仅在上下文截断后写入(3 个实时任务中有 1 个存在) |
| `focus_chain_taskid_<id>.md` | id 内嵌 | Markdown 清单 | 3 个实时任务中均存在 |

**目录示例(匿名化,真实形态):**

```text
~/.cline/
├── data/
│   ├── globalState.json                  # app-global state (~1.1 KB)
│   ├── secrets.json                      # 0600 (api keys etc.)
│   ├── settings/
│   │   ├── cline_mcp_settings.json
│   │   └── providers.json
│   ├── state/
│   │   └── taskHistory.json              # Cline's OWN task index (§13) — array of summaries
│   ├── workspaces/
│   │   └── <hash>/workspaceState.json    # per-workspace state, dir name = workspace hash
│   ├── cache/                            # (empty here)
│   ├── logs/
│   │   └── cline-cli.1.log               # rolling CLI log (large)
│   └── tasks/                            # <-- ADAPTER ROOT
│       ├── 1771763997801/                # taskId = ms-epoch; dir name == session id
│       │   ├── ui_messages.json          # *** LOCATOR ***  UI event stream (array)
│       │   ├── api_conversation_history.json   # raw Anthropic-style messages array
│       │   ├── task_metadata.json        # files-in-context + model + env history
│       │   ├── context_history.json      # context-truncation bookkeeping (nested arrays)
│       │   └── focus_chain_taskid_1771763997801.md   # editable to-do / focus list
│       ├── 1771764735752/                # 4 files — LACKS context_history.json
│       │   └── ...
│       └── 1771767068013/                # 4 files — LACKS context_history.json (only 1771763997801 has 5)
│           └── ...
└── kanban/
    └── config.json
```

> 三个实时任务中只有**一个**有 **5** 个文件 —— `1771763997801`(携带 `context_history.json` 的那个)。另外**两个**(`1771764735752` **和** `1771767068013`)各有 **4** 个文件。`context_history.json` 是可选的(仅在发生上下文窗口截断时才写入一次);它恰好存在于 **3 个实时任务中的 1 个**,与上面 §2 文件种类表一致。

---

## 3. File lifecycle & generation

- **存储技术:** 纯 JSON。`ui_messages.json` 是单个 JSON **数组**(不是按行分隔)。整个文件被 `JSON.parse` 读入内存。
- **整文件重写,不是追加。** 所有 JSON 文件每一轮都对完整的数组/对象做读-改-写。证据:适配器通过 `JSONSerialization`/`JSON.parse` 读取整个数组,没有换行分帧;且文件身份保护机制会在读取过程中 `(mtime, size)` 变化时拒绝解析(`Phase4AdapterSupport.readJSONArray` 的 `before`/`after`)——这只有对原子性的整文件重写才有意义。已确认(官方):`saveClineMessages` = `atomicWriteFile(filePath, JSON.stringify(uiMessages))`,`saveApiConversationHistory` = `atomicWriteFile(filePath, JSON.stringify(apiConversationHistory))`,`saveTaskMetadata` = `fs.writeFile(filePath, JSON.stringify(metadata, null, 2))`——均不追加;全是整文件重写,且 `getSavedClineMessages` 会 `JSON.parse` 整个文件([disk.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/core/storage/disk.ts))。(细节:`api`/`ui` 经 `atomicWriteFile` 用紧凑 JSON;`task_metadata` 用 2 空格缩进美化打印。)
- **DB 与文件:** 基于文件,无 DB。Cline 在 `~/.cline/data/state/taskHistory.json` 保存一个扁平的摘要索引,但它同样是纯 JSON 文件(Engram 不读取它)。
- **恢复 = 重新打开同一目录;各文件的 mtime 会分化。** 任务 `1771767068013` 的实时证据:`api_conversation_history.json` 和 `task_metadata.json` 的最后修改时间为 **Feb 22 21:50**,但 `ui_messages.json` 的修改时间为 **Feb 27 17:08**,且该文件的 `ts` 范围是 `1771767068017 → 1772182620086`(Feb 22 → Feb 27)。`ask:"resume_task"` 记录 + `conversationHistoryDeletedRange` 标记了恢复边界。一个任务可以暂停后在数天之后在**同一**目录里恢复——目录名(taskId)永不改变。
- **无滚动 / 无按天拆分。** 一个任务 = 一个目录 = 一个不断增长的 `ui_messages.json`。上下文溢出通过就地截断 `api_conversation_history` 处理(由 `conversationHistoryDeletedRange` + `context_history.json` 记录),而不是创建新文件。
- **`endTime`** = 最后一条记录的 `ts`,**仅当**它与第一条不同时才发出(`ClineAdapter.swift:66`);单条记录的任务 `endTime = nil`。
- **无归档/压实格式。** 旧任务以纯目录形式保留在 `tasks/` 下。

---

## 4. Record / line taxonomy

`ui_messages.json` 是一个扁平的 JSON **"UI message" 记录数组**。由 `type` 区分两个宏观种类:`"say"`(Cline → 用户输出)和 `"ask"`(Cline 向用户提问并等待输入)。实时分布:

> 已确认(官方):下面的表格是**实时观察到的子集**(跨 3 个任务的并集),**而非** Cline 的完整分类法。真正的 `ClineSay` 枚举有**约 35 个成员**,`ClineAsk` 约 **18 个**([ExtensionMessage.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/shared/ExtensionMessage.ts))。实时样本遗漏了真实存在的子类型,包括 `act_mode_respond`、`api_req_finished`、`condense`、`summarize_task` 以及 subagent 相关的 say(`subagent` / `use_subagents` / `subagent_usage`)。Engram 的 3 子类型摄取不受影响。

**`say` 子类型**(实时观察到的子集——跨 3 个实时任务的并集;完整 `ClineSay` 枚举更大):

| `say` value | `text` format | 含义 | Engram |
|---|---|---|---|
| `task` | plain | 初始用户任务提示。携带 `modelInfo`。 | → `role=user`;同时作为会话 `summary`(前 200 字符) |
| `text` | plain (markdown) | 助手散文。`partial:false` = 最终版。 | → `role=assistant`(仅当 `!partial`) |
| `api_req_started` | **JSON string** | API 请求标记:token/成本账本 + 完整请求提示词。 | 只用于 token 用量 + cwd(不是消息) |
| `reasoning` | plain | UI 中展示的助手思维链。 | **忽略** |
| `task_progress` | markdown checklist | 实时 focus-chain 快照(`- [ ] / - [x]`)。 | **忽略** |
| `tool` | **JSON string** | 文件/工具操作记录。 | **忽略** |
| `command` | plain | Cline 执行的 shell 命令。可能携带 `commandCompleted`。 | **忽略** |
| `command_output` | plain | 流式 shell stdout/stderr。 | **忽略** |
| `completion_result` | plain (markdown) | 最终助手完成摘要。 | **忽略** |
| `user_feedback` | plain | 用户在任务中途发出的消息。 | → `role=user` |
| `error_retry` | **JSON string** | 重试通知(实时形态 `{attempt,maxAttempts,delaySeconds,errorMessage}`;规范结构体用 `delaySec`/`errorSnippet`——见 [§6.4](#64-other-json-string-text-payloads-skipped))。 | **忽略** |
| `api_req_retried` | null | 裸重试标记(无负载)。 | **忽略** |

**`ask` 子类型**(实时观察到的子集;完整 `ClineAsk` 枚举更大):

| `ask` value | `text` format | 含义 | Engram |
|---|---|---|---|
| `command_output` | plain | 为审批/继续而呈现的命令输出。 | **忽略** |
| `completion_result` | empty string | 请用户接受完成(与 `say=completion_result` 配对)。 | **忽略** |
| `resume_task` | null | 恢复被中断任务的提示。 | **忽略**(但其 `ts` 可成为 `endTime`) |
| `followup` | **JSON string** | `{question, options}` 追问。 | **忽略** |
| `plan_mode_respond` | **JSON string** | `{response, options}` Plan 模式回复。 | **忽略** |

> **Engram 只把其中 3 种子类型摄取为消息:** `task`/`user_feedback`(→ user)和 `text & !partial`(→ assistant)。其余一切在 `ClineAdapter.swift:138` / `cline.ts:117-122` 处被跳过。`api_req_started` 只被用于 token 用量,而非消息。`messageCount` ≠ 原始记录数。("约 17 种子类型"是实时样本计数,而非 Cline 的完整分类法——见表格上方的注解。)

> `task_metadata.json` 是一个对象,而非记录流;它的数组在 [§13](#13-auxiliary-files) 中说明。对于本节通常会枚举的 DB 表分类法,Cline 是基于文件的 → **见 [§12](#12-sqlite--db-internals)(N/A)**。

---

## 5. Shared envelope / metadata fields

`ui_messages.json` 的记录级字段(跨实时记录的所有键的并集):

> 已确认(官方):这些与 `ClineMessage` 接口一致——`{ ts: number; type: "ask"|"say"; ask?: ClineAsk; say?: ClineSay; text?: string; reasoning?: string; images?: string[]; files?: string[]; partial?: boolean; commandCompleted?: boolean; lastCheckpointHash?; isCheckpointCheckedOut?; isOperationOutsideWorkspace?; conversationHistoryIndex?: number; conversationHistoryDeletedRange?: [number, number]; modelInfo?: ClineMessageModelInfo }`。`conversationHistoryDeletedRange` 类型为 `[number, number]`,注释为 "for when conversation history is truncated for API requests"——印证了 [§5](#5-shared-envelope--metadata-fields)/[§11](#11-summary--compaction) 的截断语义([ExtensionMessage.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/shared/ExtensionMessage.ts))。本文档省略了 Engram 忽略的信封键(`reasoning`、`images`、`files`、`lastCheckpointHash`、`isCheckpointCheckedOut`、`isOperationOutsideWorkspace`)。

| 字段 | 类型 | 含义 | 可选 | 示例(匿名化) |
|---|---|---|---|---|
| `ts` | number (epoch ms) | 事件时间;**第一条记录的 `ts` == taskId == startTime** | 必需(若首条记录缺它,解析失败) | `1771763997805` |
| `type` | string enum | `"say"` 或 `"ask"` | 必需 | `"say"` |
| `say` | string enum | say 子类型(见 [§4](#4-record--line-taxonomy)) | 当 `type=="say"` 时存在 | `"api_req_started"` |
| `ask` | string enum | ask 子类型(见 [§4](#4-record--line-taxonomy)) | 当 `type=="ask"` 时存在 | `"command_output"` |
| `text` | string | 显示负载;对 `api_req_started`/`tool`/`followup`/`plan_mode_respond`/`error_retry` 而言它是一个 **JSON 编码的字符串**(需解析两次) | 可选(某些 `ask` 上为空 `""` 或 null) | `"<REDACTED>"` |
| `partial` | bool \| null | `true` = 尚未最终化的流式分片;助手 `text` **仅当 `partial != true`** 时被采用 | 可选。**在支持流式的 say 上存在(多为 `false`)** —— 实时上为:`reasoning`、`text`、`tool`(+ 2 条非 say 记录)。值 `true` 仅出现在 `say="text"` 上 | `false` |
| `modelInfo` | object `{providerId, modelId, mode}` | 本轮使用的模型;会话 `model` = 第一条带 `modelId` 的记录。**单个任务可混用多个模型**(见 gotcha #8) | 可选(多在 `task`/`api_req_started` 上) | `{"providerId":"cline","modelId":"z-ai/glm-5","mode":"act"}` |
| `conversationHistoryIndex` | number | 进入 `api_conversation_history.json` 的索引(`-1` = 历史之前的种子) | 可选 | `-1`, `0`, `8`, … |
| `conversationHistoryDeletedRange` | `[number,number]` \| null | 为上下文窗口而截断的 API 历史的闭区间 `[start,end]` 切片 | 可选(6/283 条记录) | `[2, 59]` |
| `commandCompleted` | bool \| null | 终端命令已完成 | 可选(仅在 `say=="command"` 上) | `true` |

**3 个任务上 `partial` 值的分布:** 216×`false`,19×`true`,613×`null` 或缺失(jq `.partial` 对 null 值和缺失键都产生 `null`)。全部 19 个 `true` 都在 `say="text"` 上。

**`partial` *存在性*(键实际被发出)比 `true` 值范围更广。** 跨 3 个任务有 235 条记录携带该键(多于 216 个 `false`,因为 `null` 值的 `partial` 键也算存在)。按 `say` 划分:

| 携带 `partial` 的 `say` | 存在总数 | `true` | `false` |
|---|---|---|---|
| `reasoning` | 86 | 0 | 86 |
| `text` | 82 | 19 | 63 |
| `tool` | 65 | 0 | 65 |
| (非 say / `ask` 记录) | 2 | 0 | 2 |

因此 `partial:false` 出现在每一条实时 `say="reasoning"` 记录上(任务 `1771764735752` 中 86/86),不仅仅在 `say="text"` 上。早先的"仅在 `say=text` 上为 true"那条注解对于 **`true` 值**是正确的,但低估了该字段的**存在性**。

---

## 6. Message & content schema

### 6.1 Plain-text record bodies (what becomes a message)

对于 `say ∈ {task, text, user_feedback, completion_result, reasoning, command, ...}`,`text` 是一个纯字符串(散文为 markdown)。Engram 只把 `task`/`user_feedback` → user 内容、非 partial 的 `text` → assistant 内容做映射(`ClineAdapter.swift:142-149`)。

```json
{ "ts": 1771763997805, "type": "say", "say": "task",
  "text": "<task prompt text — anonymized>",
  "modelInfo": { "providerId": "cline", "modelId": "z-ai/glm-5", "mode": "act" },
  "conversationHistoryIndex": -1 }
```

```json
{ "ts": 1770000005000, "type": "say", "say": "text",
  "text": "<assistant prose — anonymized>",
  "partial": false, "conversationHistoryIndex": 1 }
```

### 6.2 Nested payload — `say == "api_req_started"`

`.text` 是一个 JSON 字符串,适配器为 token 用量和 cwd 重新解析它。内层键(实时验证,按顺序):`cacheReads, cacheWrites, cost, request, tokensIn, tokensOut`。

> 已确认(官方):`task/index.ts` 通过 `text: JSON.stringify({ request: … } satisfies ClineApiReqInfo)` 写入,因此 `.text` 确实是嵌套 JSON 字符串(需解析两次)。`ClineApiReqInfo` schema 为 `{ request?, tokensIn?, tokensOut?, cacheWrites?, cacheReads?, cost?, cancelReason?, streamingFailedMessage?, retryStatus? }`——表中枚举的六个内层键正是被填充的子集([task/index.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/core/task/index.ts)、[ExtensionMessage.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/shared/ExtensionMessage.ts))。

```json
{
  "ts": 1771763998182,
  "type": "say",
  "say": "api_req_started",
  "text": "{\"request\":\"<task>\\n…\\n# Current Working Directory (/Users/<user>/<project>) Files\\nNo files found.\\n…\",\"tokensIn\":4546,\"tokensOut\":216,\"cacheWrites\":0,\"cacheReads\":192,\"cost\":0}",
  "modelInfo": {"providerId":"cline","modelId":"z-ai/glm-5","mode":"act"},
  "conversationHistoryIndex": -1,
  "conversationHistoryDeletedRange": null
}
```

| 内层字段(在已解析的 `.text` 中) | 类型 | 含义 | Engram 用途 |
|---|---|---|---|
| `request` | string | 完整提示词,含 `Current Working Directory (<path>) Files …` 块 | `extractCwd` 正则的来源(`ClineAdapter.swift:171-194`) |
| `tokensIn` | number | 本次请求的输入 token | 累加 → `usage.inputTokens`(附加到**下一条**助手消息) |
| `tokensOut` | number | 输出 token | 累加 → `usage.outputTokens` |
| `cacheReads` | number | 缓存读取 token | **忽略**(Swift 强制为 0) |
| `cacheWrites` | number | 缓存创建 token | **忽略**(Swift 强制为 0) |
| `cost` | number | 计算出的美元成本(免费/本地档位常为 `0`) | **忽略** |

### 6.3 Nested payload — `say == "tool"` (skipped by Engram)

`.text` 是一个由 `.tool` 区分的 JSON 字符串。实时判别值:`newFileCreated`、`editedExistingFile`、`readFile`、`listFilesTopLevel`、`webFetch`。

> 已确认(官方):实时判别值是 `ClineSayTool` 联合类型的准确子集,其完整判别集为 `editedExistingFile, newFileCreated, fileDeleted, readFile, listFilesTopLevel, listFilesRecursive, listCodeDefinitionNames, searchFiles, webFetch, webSearch, summarizeTask, useSkill`,字段为 `path?, diff?, content?, regex?, filePattern?, operationIsLocatedInWorkspace?, startLineNumbers?, readLineStart?, readLineEnd?`([ExtensionMessage.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/shared/ExtensionMessage.ts))。3 任务的实时样本只呈现了其中 5 个判别值 / 5 个键。

| `tool` value | Keys | Notes |
|---|---|---|
| `newFileCreated` | `tool, path, content, startLineNumbers, operationIsLocatedInWorkspace` | `content` = 完整的新文件正文 |
| `editedExistingFile` | `tool, path, content, startLineNumbers, operationIsLocatedInWorkspace` | 观察到 `diff:null`;`content` 携带结果 |
| `readFile` | `tool, path, content, operationIsLocatedInWorkspace` | `content` = 读取的绝对路径 |
| `listFilesTopLevel` | `tool, path, content, operationIsLocatedInWorkspace` | `content` = 目录列表 |
| `webFetch` | `tool, path, content, operationIsLocatedInWorkspace` | `path` = URL |

```json
{ "tool": "newFileCreated", "path": "<file>",
  "content": "<full file body — anonymized>",
  "startLineNumbers": [ ... ],
  "operationIsLocatedInWorkspace": true }
```

### 6.4 Other JSON-string `.text` payloads (skipped)

```text
ask="followup"          → { "question": string, "options": string[] }
ask="plan_mode_respond" → { "response": string, "options": string[] }
say="error_retry"       → { "attempt": number, "maxAttempts": number,
                            "delaySeconds": number, "errorMessage": string }   // errorMessage itself JSON-encoded
                            // observed live shape above; the canonical retry struct
                            // (ClineApiReqInfo.retryStatus) uses delaySec + errorSnippet
```

> 已确认(官方):规范的重试结构体 `ClineApiReqInfo.retryStatus` 为 `{ attempt, maxAttempts, delaySec, errorSnippet }`——字段是 `delaySec` 和 `errorSnippet`,**而非** `delaySeconds`/`errorMessage`([ExtensionMessage.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/shared/ExtensionMessage.ts))。`say="error_retry"` 记录的序列化可能略有不同;若确切字段名重要,请对照实时 `error_retry` 记录核对。无论如何 Engram 都跳过该负载。

### 6.5 cwd extraction algorithm

`ClineAdapter.swift:176-198` / `cline.ts:173-193`:扫描每个 `api_req_started`,`JSON.parse` 其 `.text`,然后用正则 `Current Working Directory \((.+?)\) Files`(惰性,锚定在 `) Files` 上,使含 `)` 的路径得以保留)匹配 `request`,失败则回退到 `Current Working Directory \(([^)]+)\)`。如未找到则返回 `""`。两个适配器都使用 dot-matches-newline(Swift `.dotMatchesLineSeparators`,TS `/s`)。

> 已确认(官方)+ 多根失败模式:对单根工作区,`getEnvironmentDetails` 发出字面脚手架 `\n\n# Current Working Directory (${this.cwd.toPosix()}) Files\n`([task/index.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/core/task/index.ts)),正则可匹配。**但对多根工作区,源代码改为发出 `# Current Working Directory (Primary: ${primaryName}) Files`**——于是捕获组得到的是字符串 `Primary: <name>` 而非绝对路径,Engram 的 `cwd` 会变成非路径字符串,破坏项目归属。见 gotcha #4。

---

## 7. Tool calls & results

**在 `ui_messages.json` 中(Engram 所见):没有显式 ID 关联。** 关联是位置性 + 文本性的:一个 `say="command"` 信封后面跟着 `ask/say="command_output"`;一个 `say="tool"`(例如 `newFileCreated`)独立存在,操作结果内嵌在它自己的 `content` 中。`commandCompleted:true` 标志标记一条命令已完成。**Engram 丢弃所有这些** —— `toolMessageCount` 硬编码为 `0`。

**在 `api_conversation_history.json` 中(Engram 不解析):真正的基于 ID 的关联。** `tool_use` 块携带 `id`/`call_id`;结果在随后的 `user` 消息里作为一个以 `[<name> for '<args>'] Result:\n…` 为前缀的 `text` 块返回(**没有** `tool_result` 块类型——在所有 3 个实时任务中均已验证;只存在 `text`/`thinking`/`tool_use` 块)。完整的 `api_conversation_history.json` schema 见上面 [§6](#6-message--content-schema) 与 [§13](#13-auxiliary-files)。

`tool_use.name` 分布 + `input` schema(实时任务 `1771764735752`):

| `name` | `input` keys |
|---|---|
| `execute_command` | `command`, `requires_approval` |
| `write_to_file` | `absolutePath`, `content`, `task_progress` (`task_progress` optional) |
| `attempt_completion` | `result`, `command?`, `task_progress?` |
| `read_file` | `path` |
| `replace_in_file` | `absolutePath`, `diff` |
| `web_fetch` | `prompt`, `url` |
| `list_files` | `path`, `recursive`, `task_progress` |
| `ask_followup_question` | `options`, `question`, `task_progress` |
| `plan_mode_respond` | `response`, `task_progress` |

---

## 8. Reasoning / thinking

**有存储,但不被 Engram 消费。** 有两处保存推理:

1. `ui_messages.json` 的 `say:"reasoning"` 记录(UI 中展示的纯文本思维链;实时任务 `1771764735752` 中有 86 条)。不在 Engram 的 `say` 白名单中 → 被丢弃。
2. `api_conversation_history.json` 的 `thinking` 内容块 —— 更丰富的来源。块键:`type, thinking, signature, summary`。

| 字段 | 类型 | 含义 |
|---|---|---|
| `thinking` | string | 推理文本(截断的开头部分) |
| `signature` | string | 提供方签名(观察到为空 `""`) |
| `summary` | object[] | 完整推理,分块:`{type:"reasoning.text", text, index, format}`(观察到 `format` 为 `null`) |

```json
{ "type": "thinking", "thinking": "<reasoning — anonymized>", "signature": "",
  "summary": [ { "type": "reasoning.text", "text": "<…>", "index": 0, "format": null } ] }
```

对于 Cline 会话,Engram **不发出任何 reasoning**。

---

## 9. Token usage & cost

Token 用量存在于 `say:"api_req_started"` 记录(逐请求),并冗余地存在于 `api_conversation_history.json` 的助手 `metrics` 与 `taskHistory.json` 聚合值中。Engram **只**读取 `api_req_started` 这条路径。

| 来源字段 | 类型 | Engram 字段 | 推导 |
|---|---|---|---|
| `api_req_started.text.tokensIn` | number | `usage.inputTokens` | 跨连续的 `api_req_started` 累加,刷新到下一条助手消息上 |
| `api_req_started.text.tokensOut` | number | `usage.outputTokens` | 同上 |
| `api_req_started.text.cacheReads` | number | `usage.cacheReadTokens` = **0** | **丢弃**(Swift `:166`,TS `:182`) |
| `api_req_started.text.cacheWrites` | number | `usage.cacheCreationTokens` = **0** | **丢弃**(Swift `:167`,TS `:183`) |
| `api_req_started.text.cost` | number | — | 完全**丢弃** |

**聚合机制(微妙):** `api_req_started` 本身不是消息。适配器在连续的 `api_req_started` 记录之间累积 `pendingUsage`,然后把累积总量附加到紧随其后的第一条 `assistant` 消息上并重置(`ClineAdapter.swift:114-131`;`cline.ts:119-147`)。一条同时 `tokensIn==0` 且 `tokensOut==0` 的记录会被忽略(`ClineAdapter.swift:166`,`cline.ts:209`)。由 parity golden 验证:那条唯一的助手消息得到 `{inputTokens:100, outputTokens:0, cacheReadTokens:0, cacheCreationTokens:0}`。2026-07-01 保留 TS 回归测试也验证了连续两条 ledger 会聚合为 `10+7` input 和 `5+3` output。

**影响:** 缓存与成本在结构上被低报。实时任务 `1771763997801` 的 `taskHistory` 聚合 `cacheReads` 达到约 168 万 token —— 全部被 Engram 丢弃。(由于使用免费/本地模型档位,所有采样任务的成本都是 `0`,因此成本损失在*这里*没有美元影响,但在付费档位上会有。)

---

## 10. Subagent / parent-child / dispatch

**对 Cline 而言 N/A(在会话层面)。** Cline 的磁盘格式中没有任何跨**会话**的 parent/agent 关联信号。适配器把每个谱系字段都设为 `nil`:`agentRole`、`originator`、`origin`、`parentSessionId`、`suggestedParentId`、`summaryMessageCount`(`ClineAdapter.swift:79-86`;TS 中不存在)。没有 `.engram.json` sidecar(那是 Gemini 机制),没有基于路径的 subagent 检测,没有 originator 标记。Cline 会话始终以独立的顶层会话呈现,从不被自动归类为 dispatched。

> 已确认(官方):任何每任务文件或 `HistoryItem` 中都**没有 `parentTaskId`**(仓库搜索无匹配;`HistoryItem` 无 parent 字段——[HistoryItem.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/shared/HistoryItem.ts)),因此"磁盘上无会话级关联"的结论成立。**但当前 Cline 确实有 subagent 功能**——`ClineSay` 包含 `subagent` / `use_subagents` / `subagent_usage`,`ClineAsk` 包含 `use_subagents`([ExtensionMessage.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/shared/ExtensionMessage.ts))。这些 subagent 运行在**单个父任务的 `ui_messages.json` 内部**,而不是带回指的独立子任务目录,因此不会产生供 Engram 关联的跨会话父/子图。准确表述应是"subagent 存在,但活在一个任务文件之内",而非"Cline 没有 subagent"。

---

## 11. Summary / compaction

- **Engram 的 "summary":** 第一条 `say:"task"` 记录的 `text`,截断到 200 字符(`ClineAdapter.swift:53-55,75`;`cline.ts:67-68,92`)。它同时充当标题替身(没有单独的标题字段)。不是模型生成的摘要。
- **Cline 侧的压实:** 上下文窗口溢出就地处理。当 API 历史被截断时,Cline 在相关的 `ui_messages.json` 记录上写入 `conversationHistoryDeletedRange`,并向 `context_history.json` 追加一条注记(例如 *"Some previous conversation history … has been removed"*)。**Engram 两者皆忽略** —— 它不检测压实、也不按压实拆分,并且不使用单独的压实摘要记录。Cline 中没有 Claude-Code 风格的 `summary` 记录类型。

---

## 12. SQLite / DB internals

**对 Cline 而言 N/A。** Cline 基于文件(每个任务一个由纯 JSON 数组/对象构成的目录)。没有 SQLite `.vscdb`,没有 leveldb,没有 DB 表/列/键。这是与 `cursor`/`vscode` 适配器的关键区别——后者确实读取 `state.vscdb`(见 [§15](#15-lineage-gotchas-version-drift--edge-cases))。

---

## 13. Auxiliary files

下面所有同级文件都**不被 Engram 解析**,但为完整性而记录。

### `api_conversation_history.json` — Anthropic-format message log

API 消息的扁平数组。信封键(并集):`role, content, metrics, modelInfo`。角色:`user`、`assistant`。`content` **始终是一个带类型的块数组**。

| 信封字段 | 类型 | 含义 | 示例 |
|---|---|---|---|
| `role` | `"user"` \| `"assistant"` | 说话者 | `"assistant"` |
| `content` | block[] | 带类型的内容块(见下) | — |
| `metrics` | object (assistant msgs) | `{tokens:{prompt,completion,cached}, cost}` | `{"tokens":{"prompt":4546,"completion":216,"cached":192},"cost":0}` |
| `modelInfo` | object | `{modelId, providerId, mode}` | `{"modelId":"z-ai/glm-5","providerId":"cline","mode":"act"}` |

**内容块类型**(实时计数因任务而异;一个任务只有 `text`,另一个有 `text`/`thinking`/`tool_use`)。不存在 `tool_result` 块——结果会折叠进下一条 `user` 消息的 `text` 中。

**块键的可选性(实时任务 `1771764735752`)。** 只有 `type`(以及该类型的负载键)是通用的;辅助键只在**部分**块上发出:

| Block | Key | Present | Optionality |
|---|---|---|---|
| `text` | `type` | 239/239 | required |
| `text` | `text` | 239/239 | required |
| `text` | `call_id` | 28/239 | **optional**(存在时为 `""`) |
| `text` | `reasoning_details` | 28/239 | **optional**(数组或 `null`) |
| `tool_use` | `type` / `id` / `call_id` / `name` / `input` | 各 86/86 | required(`call_id` 与 `id` 重复) |
| `tool_use` | `reasoning_details` | 58/86 | **optional**(数组或 `null`) |
| `thinking` | `type, thinking, signature, summary` | — | 见 [§8](#8-reasoning--thinking) |

因此下面的扁平键列表是键的**并集**,并非逐块保证:
- `text` block keys:`type, text`(总是)+ `call_id, reasoning_details`(**可选** —— 仅出现在 239 个实时 text 块中的 28 个;`call_id` 存在时为 `""`,`reasoning_details` 为数组或 `null`)。
- `thinking` block keys:`type, thinking, signature, summary`(见 [§8](#8-reasoning--thinking))。
- `tool_use` block keys:`type, id, call_id, name, input`(总是)+ `reasoning_details`(**可选** —— 出现在 86 个实时 tool_use 块中的 58 个;`call_id` 与 `id` 重复;见 [§7](#7-tool-calls--results))。

```json
{
  "role": "assistant",
  "content": [
    {"type": "thinking", "thinking": "<…>", "signature": "", "summary": [ ... ]},
    {"type": "text", "text": "<…>", "call_id": "", "reasoning_details": null},
    {"type": "tool_use", "id": "call_function_vc", "call_id": "call_function_vc",
     "name": "web_fetch", "input": {"url": "http://<host>:<port>/", "prompt": "<…>"},
     "reasoning_details": null}
  ],
  "metrics": {"tokens": {"prompt": 6805, "completion": 272, "cached": 0}, "cost": 0},
  "modelInfo": {"modelId": "minimax/minimax-m2.5", "providerId": "cline", "mode": "plan"}
}
```

### `task_metadata.json` — object with three arrays

| Key | Element shape | 含义 |
|---|---|---|
| `files_in_context` | `{path, record_state ("active"\|"stale"), record_source ("cline_edited"\|"read_tool"\|"user_edited"), cline_read_date, cline_edit_date, user_edit_date}`(日期为 ms\|null) | Cline 触碰过的文件,带陈旧度追踪 |
| `model_usage` | `{ts, model_id, model_provider_id, mode}` | 模型切换时间线 |
| `environment_history` | `{ts, os_name, os_version, os_arch, host_name, host_version, cline_version}` | 运行时指纹 —— **Cline 版本字符串唯一存放的地方**(实时:`host_name:"Cline CLI - Node.js"`、`host_version:"2.4.2"`、`cline_version:"3.66.0"`) |

> 已确认(官方):`getTaskMetadata` 默认值 = `{ files_in_context: [], model_usage: [], environment_history: [] }`,且 `collectEnvironmentMetadata` 返回 `{ os_name: os.platform(), os_version: os.release(), os_arch: os.arch(), host_name: hostVersion.platform, host_version: hostVersion.version, cline_version: ExtensionRegistryInfo.version }`——正是 `environment_history` 元素的形态,其中 `cline_version` 来源于扩展注册表版本([disk.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/core/storage/disk.ts))。

### `context_history.json` — nested context-truncation log (optional)

深度嵌套的位置元组(无字段名):外层 `[updateType, [...]]`,内层叶子 `[ts, "text", [strings], []]`。仅在发生截断时写入。

### `focus_chain_taskid_<id>.md` — editable Markdown checklist

头部注释 + `- [ ]` / `- [x]` 条目,标题为 `# Focus Chain List for Task <id>`;镜像 `say="task_progress"` 快照。已确认(官方):`getFocusChainFilePath` 返回 `path.join(taskDir, "focus_chain_taskid_${taskId}.md")`,文件以头部 `# Focus Chain List for Task <id>` 和 `- [ ] / - [x]` 条目创建([focus-chain/file-utils.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/core/task/focus-chain/file-utils.ts))。

### `~/.cline/data/state/taskHistory.json` — Cline's own task index (sibling, top-level)

每任务摘要记录的数组(CLI 的最近列表)。**Engram 不读取它** —— 它直接遍历 `tasks/*/ui_messages.json`。注意 `ulid` 和 `isFavorited` 存在于此处,但**不在**每任务文件中。

> 已确认(官方):`getTaskHistoryStateFilePath = path.join(ensureStateDirectoryExists(), "taskHistory.json")`,其中 `ensureStateDirectoryExists = getGlobalStorageDir("state")` → 对 CLI 解析为 `~/.cline/data/state/taskHistory.json`。`HistoryItem` 类型为 `{ id, ulid?, ts, task, tokensIn, tokensOut, cacheWrites?, cacheReads?, totalCost, size?, shadowGitConfigWorkTree?, cwdOnTaskInitialization?, conversationHistoryDeletedRange?, isFavorited?, checkpointManagerErrorMessage?, modelId? }`——下表每个字段均存在(Engram 忽略的额外字段 `shadowGitConfigWorkTree` 和 `checkpointManagerErrorMessage` 也存在)([disk.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/core/storage/disk.ts)、[HistoryItem.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/shared/HistoryItem.ts))。

| Field | Type | 含义 | Example |
|---|---|---|---|
| `id` | string | 任务 id(= 目录名) | `"1771763997801"` |
| `ulid` | string | ULID 次级 id | `"01J…"` |
| `ts` | number | 最后活动毫秒 | `1771766262024` |
| `task` | string | 第一条用户提示 | `"<task text>"` |
| `tokensIn` / `tokensOut` | number | 聚合 token | `1789807` / `55124` |
| `cacheWrites` / `cacheReads` | number | 聚合缓存 token | `0` / `1680512` |
| `totalCost` | number | 聚合美元 | `0` |
| `size` | number | 任务在磁盘上的字节数 | `1788250` |
| `cwdOnTaskInitialization` | string | 工作区根目录 | `/Users/<user>/<project>` |
| `conversationHistoryDeletedRange` | `[n,n]` | 截断范围 | `[2,59]` |
| `isFavorited` | bool | 已置顶 | `false` |
| `modelId` | string | 模型 | `"z-ai/glm-5"` |

> 因此 Cline 在此处的权威 cwd/token 聚合值,被 Engram 从 `ui_messages.json` 独立重新推导(cwd 经由 `api_req_started.request` 正则;token 经由累加 `tokensIn/Out`)。

其他顶层 Cline 状态(非每任务、不解析):`~/.cline/data/globalState.json`、`~/.cline/data/secrets.json`(0600)、`~/.cline/data/settings/{cline_mcp_settings.json,providers.json}`、`~/.cline/data/workspaces/<hash>/workspaceState.json`、`~/.cline/data/logs/cline-cli.*.log`、`~/.cline/kanban/config.json`。

---

## 14. Engram mapping

`parseSessionInfo` 返回 `NormalizedSessionInfo`(Swift)/ `SessionInfo`(TS)。`streamMessages` 发出 `NormalizedMessage`。Swift 与 TS 逐行等价。

| 来源字段 / 记录 | Engram `Session` 字段 | Swift `file:line` | TS `file:line` | 备注 / 示例 |
|---|---|---|---|---|
| task **目录名**(`epochMillis`) | `id` | `ClineAdapter.swift:49,68` | `cline.ts:69,86` | `"1771763997801"` |
| 常量 `cline` | `source` | `ClineAdapter.swift:4,69` | `cline.ts:25,87` | `"cline"` |
| 第一条 `say:"task"` 的 `text`,前 200 字符 | `summary`(标题替身) | `ClineAdapter.swift:58-60,80` | `cline.ts:75-76,100` | 无单独标题字段 |
| 对第一条 `api_req_started.request` 的正则:`Current Working Directory \((.+?)\) Files` 然后 `\(([^)]+)\)` | `cwd` | `ClineAdapter.swift:72,176-199` | `cline.ts:77,173-194` | `/Users/<user>/<project>`;无匹配则 `""` |
| (无) | `project` | `ClineAdapter.swift:73`(`nil`) | `cline.ts`(省略) | parity golden 确认 `"project": null`;由索引器在下游从 `cwd` 推导 |
| **第一条**记录的 `ts`(ms → ISO) | `startTime` | `ClineAdapter.swift:43-44,70` | `cline.ts:73,88` | `2026-02-02T02:40:00.000Z` |
| **最后一条**记录的 `ts`;若 == 首条则 `nil` | `endTime` | `ClineAdapter.swift:50,71` | `cline.ts:74,89-92` | 最后的 `ts` 覆盖所有记录,含 ask/tool/partial |
| `userMessageCount + assistantMessageCount` | `messageCount` | `ClineAdapter.swift:75` | `cline.ts:95` | 不是原始记录数 |
| `say == "task"` 或 `"user_feedback"` 计数 | `userMessageCount` | `ClineAdapter.swift:51-54,76` | `cline.ts:80-82,96` | — |
| `say == "text"` 且 `partial != true` 计数 | `assistantMessageCount` | `ClineAdapter.swift:55-57,77` | `cline.ts:83,97` | partial 分片被排除 |
| 硬编码 `0` | `toolMessageCount` | `ClineAdapter.swift:78` | `cline.ts:98` | `say:"tool"` 记录不计入 |
| 硬编码 `0` | `systemMessageCount` | `ClineAdapter.swift:79` | `cline.ts:99` | — |
| 第一条带 `modelInfo.modelId` 的记录 | `model` | `ClineAdapter.swift:61-64,74` | `cline.ts:78,94` | `"z-ai/glm-5"`(provider 前缀逐字保留) |
| 选中的 locator 路径(`ui_messages.json` 或 legacy `claude_messages.json`) | `filePath` / locator | `ClineAdapter.swift:81` | `cline.ts:101` | 当前 live corpus 使用 `ui_messages.json` |
| 仅选中 locator 的 `stat().size` | `sizeBytes` | `ClineAdapter.swift:82` | `cline.ts:68,102` | 排除同级文件(低估占用) |
| `task`/`user_feedback` → `user`;非 partial 的 `text` → `assistant` | message `role` | `ClineAdapter.swift:141-149` | `cline.ts:138-155` | 只发出 2 种角色 |
| 记录 `text`(纯文本) | message `content` | `ClineAdapter.swift:149` | `cline.ts:155` | tool/command/progress 文本永不成为消息 |
| `api_req_started.tokensIn/tokensOut` 的滚动累加,刷新到下一条助手消息 | message `usage` | `ClineAdapter.swift:114-174` | `cline.ts:116-147,196-214` | `cacheReadTokens`/`cacheCreationTokens` 硬编码 `0` |
| (无) | `agentRole`/`originator`/`origin`/`parentSessionId`/`suggestedParentId`/`tier`/`qualityScore`/`summaryMessageCount` | `ClineAdapter.swift:84-91`(`nil`) | (TS 中无) | Cline 无 parent/agent 关联信号 |

**注册:** `SessionAdapterFactory.swift` 以 `SourceName.cline` 注册 `ClineAdapter()`。枚举使用 `JSONLAdapterSupport.directChildren`(非递归,跳过隐藏文件,排除符号链接,按路径排序——helper 位于 `CodexAdapter.swift:15`)。

---

## 15. Lineage, gotchas, version drift & edge cases

### Shared format lineage

- **不属于 VS Code / Cursor / Copilot 家族。** `cursor`/`vscode` 适配器读取 `globalStorage`/`workspaceStorage`/`state.vscdb`(leveldb 支撑的 SQLite)。Cline 读取它自己的 `~/.cline/data/tasks/` JSON 数组格式。即便 Cline 以 VS Code 扩展形式发布,Engram 消费的是它的**核心/CLI 数据目录**,而不是 IDE 的 `state.vscdb`。简报里"Cursor ↔ VS Code ↔ Copilot ↔ Cline"的分组**就存储而言是错误的**。
- **真正的同类是分支:Roo Code 与 Kilo Code。** 两者都是 Cline 的下游分支,复用**完全相同**的 `tasks/<id>/{ui_messages.json, api_conversation_history.json, task_metadata.json}` schema,以及 `api_req_started`/`say`/`ask` 词汇表。已确认(官方):Roo-Code 的 `globalFileNames.ts` 定义了相同的三件套,`taskMessages.ts` 用相同的整数组策略写 `ui_messages.json`;Kilo Code 是导入同一任务存储的 Roo/Cline 谱系分支([globalFileNames.ts](https://github.com/RooCodeInc/Roo-Code/blob/main/src/shared/globalFileNames.ts)、[taskMessages.ts](https://github.com/RooCodeInc/Roo-Code/blob/main/src/core/task-persistence/taskMessages.ts)、[kilocode](https://github.com/Kilo-Org/kilocode))。**细微差异:** Roo 还会在每任务目录内额外写 `history_item.json` + `_index.json`(Cline 两者皆无);Engram 解析的那三个文件是相同的。Engram **没有 Roo/Kilo 适配器**(对 `ui_messages|api_req_started` 做 `grep` 只匹配到 `cline.ts`/`ClineAdapter.swift`)。如果把 Cline 适配器指向一个 Roo/Kilo `ui_messages.json`,它能正确解析,但它们写入自己的根目录,而硬编码的 `~/.cline/data/tasks` 覆盖不到 → **覆盖缺口 / 未来机会。**
- "Gemini CLI ↔ Qwen ↔ iFlow" 集群是*另一个*家族,与 Cline 无任何共享。
- **`modelInfo` 谱系:** `providerId:"cline"` + `modelId:"z-ai/glm-5"` 表明 Cline 通过自己的 provider 网关路由,并把模型 id 命名为 `<vendor>/<model>`。Engram 逐字存储带前缀的 id —— 不做跨工具的模型归一化。

### Gotchas & version drift

1. **Engram 把 `~/.cline/data/tasks` 硬编码为唯一扫描根**——但 Cline 的路径并非硬编码。已确认(官方):Cline 把每个任务路径构造为 `path.resolve(HostProvider.globalStorageFsPath, "tasks", taskId)`([disk.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/core/storage/disk.ts)),因此基目录随宿主而变——VS Code 扩展 → `globalStorage/saoudrizwan.claude-dev`([issue #7929](https://github.com/cline/cline/issues/7929)),CLI → `~/.cline/data`(可经 `CLINE_DIR` 环境变量或 `--data-dir`/`--config` 标志覆盖,见 [Cline CLI configuration docs](https://docs.cline.bot/cline-cli/configuration))。每任务文件 schema 在各宿主间完全相同;只有父根目录不同。由于 Engram 始终只扫描 `~/.cline/data/tasks`,任何位于 VS Code `globalStorage` 根或 `CLINE_DIR` 覆盖目录下的 Cline 数据都会导致 `detect()`/索引漏检——该覆盖缺口是 Engram 的局限,而非 Cline 的。(这就是与任务提示的那处差异。)
2. **是 JSON 数组,不是 JSONL。** 尽管使用了 `JSONLAdapterSupport`/`readJSONArray`,一个数 MB 的 `ui_messages.json`(实时 953 KB)被整个读入内存;超大任务有经由 `ParserLimits` 截断的风险。
3. **`messageCount` ≠ 记录数。** 283 条原始记录 → 实时任务 1 中约 30 条计入的消息。任何拿 Engram 的计数去对照文件长度的人都会困惑。
4. **cwd 抽取依赖正则且取决于提示词版本。** 它仅在至少一条 `api_req_started.request` 包含字面 `Current Working Directory (…) Files` 脚手架时才生效。若 Cline 更改该系统提示词措辞,`cwd` 变为 `""`,项目归属随之失效。两级正则的存在是因为路径可能含 `)`(见 `cline.test.ts:59-88` 中的测试 R5-32)。**多根失败模式(已确认官方):** 对多根工作区,源代码发出 `Current Working Directory (Primary: <primaryName>) Files`([task/index.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/core/task/index.ts)),于是捕获组得到 `Primary: <name>`(并非文件系统路径)——`cwd` 变成非路径字符串,项目归属被静默错配。
5. **`endTime` 使用绝对意义上最后一条记录的 `ts`** —— 它常常是一条 `ask`/`resume_task`/`command_output`,而非模型消息。因此"会话时长"包含空闲/恢复时间;数天后恢复的任务会显示很长的跨度(实时任务 3:Feb 22 → Feb 27)。
6. **`resume_task` 记录意味着一个任务目录可横跨多次坐席。** Engram 把它当作单一会话处理(不拆分);恢复记录上的 `conversationHistoryDeletedRange` 表示先前上下文被压实——被忽略。
7. **缓存与成本被清零(影响最大的漂移)。** Engram 对 Cline 的 token 总量 = 仅 `tokensIn`+`tokensOut`。真实的缓存读取量(某个实时任务约 168 万 token)和 `cost` 被丢弃 → 成本仪表盘低估 Cline。
8. **模型 id 保留 provider 前缀**(实时为 `z-ai/glm-5`,fixture 中为 `glm-5`)。按模型做报表/分组时必须预期 Cline 各版本/provider 既有带前缀也有裸形式。**实时样本实际横跨两个 provider/模型** —— `z-ai/glm-5`(234 条记录)**和** `minimax/minimax-m2.5`(402 条记录)—— 单个任务可混用它们。由于会话 `model` = **第一条**携带 `modelId` 的记录,逐任务解析结果为:任务 `1771763997801` → `z-ai/glm-5`,任务 `1771764735752` → **`minimax/minimax-m2.5`**,任务 `1771767068013` → `z-ai/glm-5`。(本文档在其他处用 `z-ai/glm-5` 作为贯穿示例,但任务 2 的 Engram `model` 是 minimax。)
9. **无跨会话 parent/agent 关联** —— 所有谱系字段为 `nil`;Cline 会话始终以独立的顶层会话呈现。已确认(官方):任何每任务文件或 `HistoryItem` 中都没有 `parentTaskId`([HistoryItem.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/shared/HistoryItem.ts))。注意:Cline 确实有任务内 subagent 功能(`ClineSay` 的 `subagent`/`use_subagents`/`subagent_usage`,[ExtensionMessage.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/shared/ExtensionMessage.ts)),其事件活在单个任务的 `ui_messages.json` 内——不创建独立子会话目录,因此仍无可供 Engram 关联之物(见 [§10](#10-subagent--parent-child--dispatch))。
10. **`sizeBytes` 只测量 `ui_messages.json`** —— 忽略(常常合计更大的)同级文件,低报任务占用。
11. **存在 parity 漂移护栏。** `tests/fixtures/adapter-parity/cline/success.expected.json`(commit `88f86631`,schemaVersion 1)强制 Swift↔TS 等价;实时数据确认了已编码的计数/用量逻辑与真实文件匹配。

### Open / unverified items(2026-06-21 web 已确认)

- **Roo Code / Kilo Code**(相同 schema,无适配器,不同根目录)。已确认(官方):Roo-Code 的 `src/shared/globalFileNames.ts` 定义了相同的核心三件套——`apiConversationHistory: "api_conversation_history.json"`、`uiMessages: "ui_messages.json"`、`taskMetadata: "task_metadata.json"`——且 `task-persistence/taskMessages.ts` 用相同的整数组 `safeWriteJson` 策略写 `ui_messages.json`([globalFileNames.ts](https://github.com/RooCodeInc/Roo-Code/blob/main/src/shared/globalFileNames.ts)、[taskMessages.ts](https://github.com/RooCodeInc/Roo-Code/blob/main/src/core/task-persistence/taskMessages.ts))。Kilo Code 自带 `legacy-migration/task-store.ts` + `roo-import.test.ts`,证实它是导入同一任务存储的 Roo/Cline 谱系下游分支([kilocode](https://github.com/Kilo-Org/kilocode))。**细微差异:** "完全相同"对 Engram 记录的三个文件成立,但 Roo 还会在每任务目录内额外写 `history_item.json` + `_index.json`(Cline 两者皆无)。根目录不同,故"相同 schema、不同根、覆盖缺口"的论断成立。增加适配器可能在范围内,也可能是有意排除;尚未决定。
- **VS Code `globalStorage/<ext-id>/tasks/` 遗留布局。** 已确认(官方):确切的扩展 id 为 **`saoudrizwan.claude-dev`**,故 VS Code 路径为 `~/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/tasks/`(macOS)/ `%APPDATA%\Code\User\globalStorage\saoudrizwan.claude-dev\tasks\`(Windows)([disk.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/core/storage/disk.ts)、[issue #7929](https://github.com/cline/cline/issues/7929))。每任务文件源自**相同**的 `GlobalFileNames` 常量,与宿主无关,因此每任务 schema 相同——VS Code 扩展与 CLI(`~/.cline/data`)之间只有 `HostProvider.globalStorageFsPath` 不同。早先"从提示推断"的保留措辞升级为已验证。
- `context_history.json` 的嵌套数组 schema 仅部分解码;开头整数索引的完整语义未做逆向(Engram 不解析它)。文件名已确认(`GlobalFileNames.contextHistory = "context_history.json"`,由 `context-management/ContextManager.ts` 写入——[disk.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/core/storage/disk.ts)、[ContextManager.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/core/context/context-management/ContextManager.ts)),但开头位置整数的含义(web-checked 2026-06-21: no authoritative source found——需追踪 `ContextManager.ts` 序列化,超出本文档需求)。
- `cacheReads`/`cacheWrites`/`cost`/`cline_version` 的捕获被有意丢弃;是否填充它们是一个待定的产品决策(Engram-internal design - not web-verifiable)。格式侧已确认可供填充:`ClineApiReqInfo.cacheReads/cacheWrites/cost`、`HistoryItem.cacheReads/cacheWrites/totalCost`,以及 `task_metadata` 的 `environment_history.cline_version`(经 `collectEnvironmentMetadata` → `ExtensionRegistryInfo.version`)在源代码中均存在并被填充([ExtensionMessage.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/shared/ExtensionMessage.ts)、[disk.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/core/storage/disk.ts))。
- **遗留 `claude_messages.json` 文件名(版本漂移已覆盖)。** 已确认(官方):`getSavedClineMessages` 先读 `ui_messages.json`;若不存在则回退到遗留 `claude_messages.json`,迁移它,再删除旧文件([disk.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/core/storage/disk.ts))。非常老的 Cline 任务早于 `ui_messages.json` 改名。Engram 现在也镜像此 locator fallback:`ui_messages.json` 优先,只有现代文件不存在时才使用 `claude_messages.json`。当前实时存储有 0 个 legacy 文件;TS 与 Swift focused tests 覆盖该 fallback。

---

## 16. Appendix: real anonymized samples

**`ui_messages.json` — `say:"task"`(第一条记录):**
```json
{ "ts": 1771763997805, "type": "say", "say": "task",
  "text": "<task prompt — anonymized>",
  "modelInfo": { "providerId": "cline", "modelId": "z-ai/glm-5", "mode": "act" },
  "conversationHistoryIndex": -1 }
```

**`ui_messages.json` — `say:"api_req_started"`:**
```json
{ "ts": 1771763998182, "type": "say", "say": "api_req_started",
  "text": "{\"request\":\"<task>\\n…\\n# Current Working Directory (/Users/<user>/<project>) Files\\nNo files found.\\n…\",\"tokensIn\":4546,\"tokensOut\":216,\"cacheWrites\":0,\"cacheReads\":192,\"cost\":0}",
  "modelInfo": {"providerId":"cline","modelId":"z-ai/glm-5","mode":"act"},
  "conversationHistoryIndex": -1, "conversationHistoryDeletedRange": null }
```

**`ui_messages.json` — `say:"text"`(助手,最终):**
```json
{ "ts": 1770000005000, "type": "say", "say": "text",
  "text": "<assistant prose — anonymized>", "partial": false,
  "conversationHistoryIndex": 1 }
```

**`ui_messages.json` — `say:"user_feedback"`:**
```json
{ "ts": 1770000060000, "type": "say", "say": "user_feedback",
  "text": "<user message — anonymized>", "conversationHistoryIndex": 5 }
```

**`ui_messages.json` — `say:"tool"`(被 Engram 跳过):**
```json
{ "ts": 1771764225161, "type": "say", "say": "tool",
  "text": "{\"tool\":\"newFileCreated\",\"path\":\"<file>\",\"content\":\"<body — anonymized>\",\"startLineNumbers\":[ ... ],\"operationIsLocatedInWorkspace\":true}" }
```

**`ui_messages.json` — `ask:"resume_task"`(被跳过;可设置 endTime):**
```json
{ "ts": 1772182620086, "type": "ask", "ask": "resume_task",
  "conversationHistoryDeletedRange": [2, 59] }
```

**`api_conversation_history.json` — 助手消息(不被解析):**
```json
{ "role": "assistant",
  "content": [
    {"type": "thinking", "thinking": "<…>", "signature": "", "summary": [{"type":"reasoning.text","text":"<…>","index":0,"format":null}]},
    {"type": "text", "text": "<…>", "call_id": "", "reasoning_details": null},
    {"type": "tool_use", "id": "call_function_mb", "call_id": "call_function_mb",
     "name": "execute_command", "input": {"command": "<cmd — anonymized>", "requires_approval": false}, "reasoning_details": null}
  ],
  "metrics": {"tokens": {"prompt": 4546, "completion": 216, "cached": 192}, "cost": 0},
  "modelInfo": {"modelId": "z-ai/glm-5", "providerId": "cline", "mode": "act"} }
```

**`task_metadata.json`(不被解析):**
```json
{
  "files_in_context": [
    {"path": "<file>", "record_state": "stale", "record_source": "cline_edited",
     "cline_read_date": 1771764225161, "cline_edit_date": 1771764225161, "user_edit_date": null}
  ],
  "model_usage": [
    {"ts": 1771763997839, "model_id": "z-ai/glm-5", "model_provider_id": "cline", "mode": "act"}
  ],
  "environment_history": [
    {"ts": 1771763997838, "os_name": "darwin", "os_version": "25.4.0", "os_arch": "arm64",
     "host_name": "Cline CLI - Node.js", "host_version": "2.4.2", "cline_version": "3.66.0"}
  ]
}
```

**`context_history.json`(不被解析;逐字嵌套形态):**
```json
[[1,[0,[[0,[[1771766242240,"text",["[NOTE] Some previous conversation history … has been removed …"],[]]]]]]],
 [0,[0,[[0,[[1771766242240,"text",["[Continue assisting the user!]"],[]]]]]]]]
```

**`focus_chain_taskid_<id>.md`(不被解析):**
```markdown
# Focus Chain List for Task 1771763997801

<!-- Edit this markdown file to update your focus chain list -->
<!-- Use the format: - [ ] for incomplete items and - [x] for completed items -->

- [x] <item 1 — anonymized>
- [ ] <item 2 — anonymized>
```

**`~/.cline/data/state/taskHistory.json` 条目(不被解析):**
```json
{ "id": "1771763997801", "ulid": "01J…", "ts": 1771766262024,
  "task": "<first prompt — anonymized>",
  "tokensIn": 1789807, "tokensOut": 55124, "cacheWrites": 0, "cacheReads": 1680512,
  "totalCost": 0, "size": 1788250, "cwdOnTaskInitialization": "/Users/<user>/<project>",
  "conversationHistoryDeletedRange": [2, 59], "isFavorited": false, "modelId": "z-ai/glm-5" }
```

---

## References (official sources)

2026-06-21 web 确认轮次(`web_access_ok=true`)。核对来源:

- [cline/cline — apps/vscode/src/core/storage/disk.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/core/storage/disk.ts) — `GlobalFileNames`、save/get 函数、`getGlobalStorageDir`、`getTaskHistoryStateFilePath`、遗留 `claude_messages.json` 回退、`collectEnvironmentMetadata`
- [cline/cline — apps/vscode/src/shared/ExtensionMessage.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/shared/ExtensionMessage.ts) — `ClineMessage`、`ClineSay`、`ClineAsk`、`ClineSayTool`、`ClineApiReqInfo`(含 `retryStatus` 的 `delaySec`/`errorSnippet`)
- [cline/cline — apps/vscode/src/shared/HistoryItem.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/shared/HistoryItem.ts) — `taskHistory.json` item schema(无 `parentTaskId`)
- [cline/cline — apps/vscode/src/core/task/index.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/core/task/index.ts) — `api_req_started.text` 的 `JSON.stringify`、单根 vs 多根 `Current Working Directory (…) Files` 脚手架
- [cline/cline — apps/vscode/src/core/task/focus-chain/file-utils.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/core/task/focus-chain/file-utils.ts) — `focus_chain_taskid_<id>.md` 命名
- [cline/cline — apps/vscode/src/core/context/context-management/ContextManager.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/core/context/context-management/ContextManager.ts) — `context_history.json` 生产者
- [RooCodeInc/Roo-Code — src/shared/globalFileNames.ts](https://github.com/RooCodeInc/Roo-Code/blob/main/src/shared/globalFileNames.ts) + [src/core/task-persistence/taskMessages.ts](https://github.com/RooCodeInc/Roo-Code/blob/main/src/core/task-persistence/taskMessages.ts) — 同类分支相同 schema(+ `history_item.json`/`_index.json`)
- [Kilo-Org/kilocode](https://github.com/Kilo-Org/kilocode) — Roo/Cline 谱系导入(`legacy-migration/task-store.ts`、`roo-import.test.ts`)
- [Cline CLI configuration docs](https://docs.cline.bot/cline-cli/configuration) — `CLINE_DIR` / `--data-dir` / `~/.cline`
- [cline/cline issue #7929](https://github.com/cline/cline/issues/7929) — VS Code `globalStorage` 路径 + 扩展 id `saoudrizwan.claude-dev`
- [DeepWiki cline/cline — CLI commands & storage](https://deepwiki.com/cline/cline/12.2-cli-commands-and-options) — `~/.cline/data`、`ensureTaskDirectoryExists`
