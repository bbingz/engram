# Gemini CLI — 会话格式参考

Last researched: 2026-06-21 (Engram session-format research workflow)
Engram adapter status refreshed: 2026-07-02 (local source/live DB audit)

> 本文档为英文权威版 gemini-cli.md 的中文阅读副本；若有出入以英文版为准。

**证据基础（本文档）。** 三类来源交叉核对；冲突时以真实数据（REAL）为准，并标注差异。

1. **本机磁盘上的实时存储** — 本机 `~/.gemini/`。在 2 个非空项目目录中共有 **3 份会话转录**：
   - `~/.gemini/tmp/surge/chats/` 中有 `2 × .json`（旧版单对象）（201.8 KB 富内容 + 468 B 仅 `info`）。
   - `~/.gemini/tmp/safeline/chats/` 中有 `1 × .jsonl`（新版追加增量）（19.1 KB）。
   - 此外还有实时的 `~/.gemini/projects.json`（258 条目）、4 个项目的 `.project_root`，以及若干空的 `chats/` 目录。
   - **0 份实时 `*.engram.json` sidecar**（`find ~/.gemini -name '*.engram.json'` → 空）。
2. **仓库 fixtures** — `tests/fixtures/gemini/{session-sample.json,projects.json}`（2 个文件）以及 `tests/fixtures/adapter-parity/gemini-cli/{success.expected.json,projects.json,input/tmp/my-project/chats/session-sample.json}`。
3. **Engram 适配器（已固化的知识）** — Swift 产品解析器 `macos/Shared/EngramCore/Adapters/Sources/GeminiCliAdapter.swift`；TS 参考解析器 `src/adapters/gemini-cli.ts`。

**当前 Engram 状态（2026-07-02）：** 实时存储仍混合了两种转录格式 —— 旧版单对象 `.json`（2026 年 4 月）与新版 `.jsonl`（2026 年 6 月）。已确认（官方）：`.jsonl` 形式现在是新建会话的 **默认且唯一** 格式（PR #23749，随 v0.39.0 发布）；单对象 `.json` 是只读的遗留格式，CLI 在恢复（resume）时会将其迁移为 `.jsonl` —— [PR #23749](https://github.com/google-gemini/gemini-cli/pull/23749)、[Issue #15292](https://github.com/google-gemini/gemini-cli/issues/15292)。当前 Engram Swift 和 TS 源码已经能发现直接 main 会话以及 `chats/<parentSessionId>/` 下的原生嵌套 subagent JSONL，逐行重放 JSONL 事件日志，从路径推导原生 subagent `parentSessionId`，并优先用 `.project_root` 解析 cwd。2026-07-01T20:09:16Z 的本机 smoke 列出/解析全部 3 个 current 文件，发现本机当前 0 个嵌套 subagent 文件，stream 出 4 条转录消息，且 stream/count mismatch 为 0。live DB 已包含全部 3 个当前 live 文件，包括 2026-06-29 的 Safeline `.jsonl`，且这 3 个文件都有 `file_index_state ok`；剩余 DB drift 仅是清理类问题：383 条历史 DB-only `~/.gemini/tmp` 行、4 条 stale `file_index_state` locator，以及 1 条当前旧 `.json` 行(`75cb965e...`)仍保留历史计数(`message_count` 4 -> 当前 3，`assistant_message_count` 3 -> 当前 2)。同一行还保留 `cwd="surge"`，而当前 parser 会从 `.project_root` 解析出 `/Users/bing/-NetWork-/Surge`。

---

## 1. Overview & TL;DR

**是什么 / 在哪里 / 怎么做。** Gemini CLI 将每个聊天存储于 `~/.gemini/tmp/<projectDir>/chats/` 下。这里 **没有 SQLite、没有 leveldb、没有 gRPC 缓存** —— 只有磁盘上的文件。当前 Gemini CLI 为每个会话写入 **仅追加的 `.jsonl`**（PR #23749，v0.39.0）；单对象 `.json` 形式是遗留格式，仅通过回退路径被 READ，然后在恢复时迁移为 `.jsonl`。每个项目目录的名称 **始终** 是项目根路径的 64 位十六进制 SHA-256（`getProjectHash`）。Gemini CLI 核心 **没有** `~/.gemini/projects.json` 注册表，也 **不** 提供 hash→cwd 的反向映射；它为每个项目写入磁盘的唯一 cwd 记录是 `tmp/<hash>/.project_root`。实时观察到的 `projects.json` 是外部启动器/Engram 的产物，并非 Gemini CLI 格式的一部分。Engram 的父链接 sidecar（`<sessionId>.engram.json`）同样是由外部插件写入的 *Engram* 约定，并非 Gemini CLI 自身的一部分。已确认（官方）：[paths.ts（`getProjectHash` = sha256 十六进制）](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/utils/paths.ts)；[PR #23749（JSONL 迁移）](https://github.com/google-gemini/gemini-cli/pull/23749)。

**心智模型。** `session = file`（会话即文件）。旧版 `.json` 形式将整个对话保存在单个重新序列化的对象中（每个回合整文件重写）。新版 `.jsonl` 形式是一种 **事件溯源追加日志**（并非每回合一次全量快照的日志）：先是一个初始元数据记录，随后每个回合发生时按行追加完整的 `MessageRecord` 对象，外加 `MetadataUpdateRecord` `{"$set": Partial<ConversationRecord>}`（仅元数据增量）和 `RewindRecord` `{"$rewindTo": "<messageId>"}`（历史截断）。权威状态须通过 **重放所有行**（追加 + `$set` + rewind）获得，而非只读取最后一行。已确认（官方）：[chatRecordingService.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatRecordingService.ts)、[chatRecordingTypes.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatRecordingTypes.ts)。

**ASCII 布局 / 分层图。**

```
~/.gemini/                                         storage tech: plain JSON/JSONL files
├── projects.json            ── global { "projects": { "<absCwd>": "<projectName>" } }
├── settings.json, state.json ── CLI config (NOT session data; ignored by adapter)
└── tmp/                      ── transcript root  (adapter `tmpRoot`)
    └── <projectDir>/         ── ALWAYS 64-hex SHA-256 of project root (human aliases seen live come from a launcher, not Gemini CLI)
        ├── .project_root     ── 1 line: absolute cwd  (authoritative cwd source; adapter prefers it)
        ├── logs.json         ── lightweight per-message telemetry rows (ignored)
        └── chats/
            ├── session-<YYYY-MM-DDTHH-mm>-<8hex>.jsonl  ── MAIN session, event-sourced log  ← Engram parses by replay
            ├── session-<YYYY-MM-DDTHH-mm>-<8hex>.json   ── LEGACY single-object (read-only fallback in CLI)  ← Engram parses
            ├── <parentSessionId>/                       ── native subagent subdir
            │   └── <sanitizedSessionId>.jsonl           ── kind=="subagent" session  ← Engram parses and links
            └── <sessionId>.engram.json                  ── Engram parent-link sidecar (Layer 1c)

  layer 1  session document   { sessionId, projectHash, startTime, lastUpdated, kind, summary?, memoryScratchpad?, directories?, messages[] }
  layer 2    └─ messages[]    { id, timestamp, type, content, model?, thoughts?, tokens?, toolCalls?, displayContent? }
  layer 3        ├─ content[] { text }                              (user content blocks)
  layer 3        ├─ tokens    { input, output, cached, thoughts, tool, total }
  layer 3        ├─ thoughts[]{ subject, description, timestamp }   (reasoning)
  layer 3        └─ toolCalls[]{ id, name, args, status, result[], ... }
  layer 4              └─ result[].functionResponse { id, name, response{ output } }
```

**给 Engram 工程师的 TL;DR。** Engram 同时解析旧 `.json` 与当前 `.jsonl`，保留 `sessionId / startTime / lastUpdated`，把对话文本扁平化（`user` + `gemini|model`，丢弃 `info` 及空内容回合），从 `chats/<parentSessionId>/...` 路径推导原生 subagent 的 `parentSessionId` / `agentRole=subagent`，并（仅 Swift）推导 token 用量。它 **丢弃** `model`、`thoughts`、`toolCalls`、`displayContent`、消息 `id`、顶层 `projectHash`/`kind`/`summary`/`memoryScratchpad`/`directories`。TS 参考路径还会额外丢弃 **所有** token 用量。

---

## 2. On-disk layout & file naming

**权威根目录**（两个适配器）：`~/.gemini/tmp/`（`GeminiCliAdapter.swift:72-74`、`gemini-cli.ts:77`）。Projects 文件：`~/.gemini/projects.json`（`GeminiCliAdapter.swift:75-77`、`gemini-cli.ts:78-79`）。

| 路径 | 角色 | 存储技术 |
|---|---|---|
| `~/.gemini/tmp/` | 会话转录根目录（adapter `tmpRoot`） | 由各项目子目录组成的目录 |
| `~/.gemini/tmp/<projectDir>/chats/session-*.json` | 一个会话 = 一个文件 | **single JSON object**（遗留） |
| `~/.gemini/tmp/<projectDir>/chats/*.jsonl` | 一个会话 = 一个文件 | **append-delta JSONL mutation log**（新版；Engram 通过 replay 解析） |
| `~/.gemini/tmp/<projectDir>/chats/<sessionId>.engram.json` | Engram 父链接 sidecar（Layer 1c） | single JSON object（由外部插件写入） |
| `~/.gemini/projects.json` | 全局 `cwd → projectName` 映射（adapter `projectsFile`） | single JSON object |
| `~/.gemini/tmp/<projectDir>/.project_root` | 单行绝对 cwd | plain text（适配器优先读取） |
| `~/.gemini/tmp/<projectDir>/logs.json` | 轻量级的每消息遥测 | JSON array（适配器忽略） |

### 命名语法

| Token | 语法 | 实时示例 | 说明 |
|---|---|---|---|
| `<projectDir>` | **始终为 64 字符小写十六进制（项目根路径的 SHA-256）** | `8a5edab2…fea0f1` | 已确认（官方）：`getProjectHash(projectRoot) = sha256(projectRoot).digest('hex')` —— Gemini CLI 核心中 **没有** alias 代码路径。实时观察到的可读目录名（`surge`、`network`、`polycli-gemini-mcp-empty-bvalwx`）来自将非路径字符串作为项目根传入的启动器（polycli/Engram），**而非** 来自 Gemini CLI。Engram 把无论是哪种值都当作字面量 `projectName` 处理。[paths.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/utils/paths.ts) |
| main session file | `session-<YYYY-MM-DDTHH-mm>-<8hex>.<json\|jsonl>` | `session-2026-04-08T03-22-75cb965e.json`、`session-2026-06-29T05-57-fe81c4b4.jsonl` | 时间戳 = 会话 **开始** 时间（分钟精度，`:`→`-`）；8 位十六进制后缀 = `sessionId[0:8]`。**在当前 3 文件实时样本上均已确认**（2 个 `.json` 和 1 个 `.jsonl`）：每个文件名后缀都精确等于该文件的 `sessionId[0:8]` —— 对于 `.jsonl`，该 id 从首行 header 读取。仅适用于 **main** 会话。 |
| subagent session file | `tmp/<projectDir>/chats/<parentSessionId>/` 中的 `<sanitizedSessionId>.jsonl` | — | 已确认（官方）：subagent 会话（`kind === 'subagent'`）**不** 使用 `session-<ts>-<8hex>` 形式命名；它们位于以 `parentSessionId` 命名的子目录中，文件名为 `<sanitizedSessionId>.jsonl`。这是 Gemini CLI 原生的 父→子 关系（见 [§10](#10-subagent--parent-child--dispatch)）。[chatRecordingService.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatRecordingService.ts) |
| sidecar | `<sessionId>.engram.json` | （实时无） | 完整 UUID 形式的 `sessionId` + `.engram.json`。与会话文件同级。 |

> **冲突 / 细节（以真实数据为准）。** 适配器把 `chats` *之前* 的那个路径组件推导为 `projectName`（`projectName(from:)` Swift:208-214；TS 在 `chats` 附近拆分路径：125-132）—— 即 **目录名**，而非文件内的 `projectHash`。实时证据显示目录名（`surge`）≠ 文件内 `projectHash`（`cf46ca80…16206b`）。因此 `project` 是目录别名；文件自身的 `projectHash` 字段 **从不被读取**。

### 目录树示例（实时，已脱敏）

```
~/.gemini/
├── projects.json                      # { "projects": { "<absCwd>": "<projectName>", ... } } (258 entries live)
└── tmp/
    ├── surge/                         # <projectDir> = human alias (== projects.json value)
    │   ├── .project_root              # /Users/<user>/-NetWork-/Surge   (27 B)
    │   ├── logs.json                  # [ { sessionId, messageId, type, message, timestamp }, … ]  (3 rows)
    │   └── chats/
    │       ├── session-2026-04-08T03-22-75cb965e.json   # 201.8 KB  rich: user+gemini+toolCalls+tokens+thoughts
    │       └── session-2026-04-13T07-47-bcf966c3.json   # 468 B     info-only (→ messageCount 0)
    ├── network/
    │   └── chats/                                        # empty (dir created without transcript)
    ├── safeline/
    │   ├── .project_root
    │   ├── logs/
    │   └── chats/
    │       └── session-2026-06-29T05-57-fe81c4b4.jsonl  # 19.1 KB  NEWER mutation-log (adapter parses)
    └── 8a5edab282632443219e051e4ade2d1d5bbc671c781051bf1437897cbdfea0f1/   # <projectDir> as 64-hex SHA-256
        └── chats/                                                          # empty here
```

---

## 3. File lifecycle & generation

| 方面 | 行为 | 证据 |
|---|---|---|
| **Storage tech** | 每会话一个文件。无 database/leveldb/gRPC 缓存。 | 实时存储；适配器通过 `Data(contentsOf:)` / `readFile` 读取整个文件 |
| **DB vs file** | 文件。一个文件 = 一个 `sessionId`；文件名编码了开始分钟 + UUID 前 8 位。 | 文件名语法 |
| **Append vs rewrite（遗留 `.json`）** | 整文件 **rewrite**：单个 JSON 对象在每回合被重新序列化；`lastUpdated` 前进，`messages` 增长。 | 顶层 `lastUpdated` 就地更新 |
| **Append vs rewrite（新版 `.jsonl`）** | **事件溯源追加日志。** 一个初始元数据记录，随后每个回合发生时按行追加完整的 `MessageRecord` 对象，外加 `MetadataUpdateRecord` `{"$set": Partial<ConversationRecord>}`（仅元数据增量；可以携带 `messages`，但它不是每回合的承载者）和 `RewindRecord` `{"$rewindTo": "<messageId>"}`（截断）。状态 = **重放所有行**，而非"最后一行胜出"。已确认（官方）：[chatRecordingService.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatRecordingService.ts)、[chatRecordingTypes.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatRecordingTypes.ts) |
| **Resume** | 恢复的会话保留相同的 `sessionId`/文件并继续增长（遗留）或追加更多记录（jsonl）；`startTime` 固定，`lastUpdated` 移动。恢复的遗留 `.json` 会迁移为 `.jsonl`（文件名末尾加一个 `l`：`session-foo.json` → `session-foo.jsonl`）。 | 格式；[PR #23749](https://github.com/google-gemini/gemini-cli/pull/23749) |
| **Rollover** | 新会话 = 同一 `chats/` 中的新文件；不会对已有转录进行轮转/分段。 | 每个 UUID 一个文件 |
| **Archive / cleanup** | 已确认（官方）：Gemini CLI 有显式的保留/GC 路径。`cleanupExpiredSessions` 在 CLI 启动时运行，并删除超出 `general.sessionRetention`（`enabled`、`maxAge`、`maxCount`、`minRetention`；默认保留 30 天）的会话，移除会话文件 **以及** 实施计划、任务 tracker、工具输出和 activity log 等关联产物。过期转录是 **被删除而非归档** —— 这正是没有归档目录的原因。空的 `chats/` 目录和空的 hash 命名项目目录会持续存在 —— Gemini 在写入转录之前/即使不写入转录也会创建目录树。 | [session-management.md](https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/session-management.md)、[gemini.tsx](https://github.com/google-gemini/gemini-cli/blob/main/packages/cli/src/gemini.tsx)、[sessionCleanup.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/cli/src/utils/sessionCleanup.ts)；实时空目录（`network/chats`、`8a5e…/chats`） |
| **Atomicity guard（Engram）** | Swift 在读取前后重新校验文件身份（size/mtime/inode）；不匹配 → `fileModifiedDuringParse`（正在被写入的实时会话会被拒绝，稍后重试）。 | `Phase4AdapterSupport.readJSONObject` Swift:6-17 |
| **Size cap（Engram）** | **两个不一致的上限。** TS 跳过 > **10 MB** 的文件（`MAX_SESSION_JSON_BYTES`，`gemini-cli.ts:33`）。Swift 跳过 > **100 MB** 的文件（`ParserLimits.default.maxFileBytes`，`ParserLimits.swift:17`）—— 上限大 10×。 | 适配器（见 gotcha #8） |
| **Other parse caps（仅 Swift）** | Swift `ParserLimits` 还把每行字节数限制为 **8 MB**（`maxLineBytes`，`ParserLimits.swift:18`），消息数限制为 **10,000**（`maxMessages`，`ParserLimits.swift:19`）。TS 两者皆无。`maxLineBytes` 会由当前逐行 `.jsonl` parser 执行。 | `ParserLimits.swift:17-19`；`GeminiCliAdapter.swift:233-264` |

**Engram 发现 / 枚举**（`listSessionLocators()` Swift:89-102 / `listSessionFiles()` TS:92-108）：
1. `detect()` —— 当且仅当 `~/.gemini/tmp` 是目录时为 true（Swift:85-87、TS:82-89）。
2. 枚举 `tmp/` 的直接子项中为目录的（每个 = 一个 `<projectDir>`）。
3. 对每个，要求存在 `chats/` 子目录；跳过没有该子目录的项目。
4. 在 `chats/` 内递归遍历，发出扩展名为 `.json` 或 `.jsonl` 的文件，并排除 `*.engram.json` sidecar（Swift:96-99；TS:98-99 以及 `sessionFilesUnder()` TS:255-270）。当前适配器不再要求 `session-` 前缀，因此覆盖原生 `chats/<parentSessionId>/<sanitizedSessionId>.jsonl` subagent 文件。
5. Swift 返回 **已排序** 的列表（`locators.sorted()`）；TS 以 `readdir` 顺序惰性产出。

---

## 4. Record / line taxonomy

### 4a. 遗留 `.json`（单对象）—— Engram 解析的格式

一个文件 = 一个 JSON 对象，包含顶层信封（[§5](#5-shared-envelope--metadata-fields)）和有序的 `messages[]` 记录数组。

### 4b. `messages[]` 记录类型

每个元素是一条记录；由 `type` 区分。已确认（官方）：磁盘上的类型联合为 `'user' | 'gemini' | 'info' | 'error' | 'warning'` —— **没有 `model` 类型**（[chatRecordingTypes.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatRecordingTypes.ts)）。助手回合仅为 `gemini`；`error` 和 `warning` 是真实持久化的消息类型。Engram TS 适配器额外容忍 `model` 别名，Swift 将 `gemini` 和 `model` 同等处理（Swift:122-123、TS:50），但 `model` 永远不会来自 Gemini CLI 自身（无害的死分支）。Engram 只把 `user`/`gemini`/`model` 当作"对话"记录处理；`error`/`warning` 不被任一 Engram 适配器枚举，落入被丢弃路径。

| `type` | 用途 | 在 Engram 中的角色 | 计入计数？ |
|---|---|---|---|
| `user` | 用户回合 | `role: user` | 是（用户计数） |
| `gemini` | 助手回合（最丰富：model/thoughts/tokens/toolCalls） | `role: assistant` | 是（助手计数） |
| `model` | 非 Gemini CLI 类型（仅 Engram TS 适配器别名；Gemini CLI 从不发出） | `role: assistant` | 是（助手计数） |
| `info` | 系统/状态通知（如 `"MCP issues detected. Run /mcp list for status."`） | 丢弃 | **否**（被排除于所有计数） |
| `error` | 真实的 Gemini CLI 消息类型（官方）；不被 Engram 适配器枚举 | 丢弃 | **否** |
| `warning` | 真实的 Gemini CLI 消息类型（官方）；不被 Engram 适配器枚举 | 丢弃 | **否** |

`info` 和空内容消息被丢弃：Engram 的消息映射只接受 `user`/`gemini`/`model`（Swift:267-273；TS `isConversation` TS:50-51），并且两个适配器都会在 parse 计数前过滤空内容（Swift:116-117；TS:123-125），stream 输出也会跳过空文本（Swift:272-273；TS:212-214）。纯 `info` 会话（实时 `surge/…/bcf966c3.json`）产出 `messageCount = 0`。

### 4c. 新版 `.jsonl`（事件溯源追加日志）—— 四种记录类型

来自 [chatRecordingService.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatRecordingService.ts) / [chatRecordingTypes.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatRecordingTypes.ts) 的已确认（官方）记录分类：

| Line | Shape | Meaning |
|---|---|---|
| initial metadata (line 1) | `Partial<ConversationRecord>`：`sessionId`、`projectHash`、`startTime`、`lastUpdated`、`kind`、`summary`、`memoryScratchpad`、`directories`，可选 `messages` | 会话元数据 header |
| message append (per turn) | 一个完整的 `MessageRecord` 对象（`type` ∈ `user`/`gemini`/`info`/`error`/`warning`） | **每行一个实际消息对象**，而非快照包装 |
| metadata update | `MetadataUpdateRecord` `{"$set": Partial<ConversationRecord>}` | 仅元数据的增量（`lastUpdated`、`summary`、`memoryScratchpad`、`directories`）；可以包含 `messages`，但 `$set` 是 **元数据更新机制，而非每回合承载者** |
| rewind | `RewindRecord` `{"$rewindTo": "<messageId>"}` | 将历史截断回指定消息 |

这是一种 **事件溯源** 日志：权威状态须通过 **重放所有行**（追加 + `$set` 增量 + `$rewindTo` 截断）获得，而非取最后一行。当前 Engram Swift 和 TS 适配器已经实现该 replay（`GeminiCliAdapter.swift:226-264`；`gemini-cli.ts:247-335`）。

### 4d. SQLite 表 —— **对 Gemini CLI 不适用（N/A）。** 无数据库支撑。（见 [§12](#12-sqlite--db-internals)。）

---

## 5. Shared envelope / metadata fields

遗留 `.json` 会话文档与 replay 后 `.jsonl` 会话状态的顶层键（layer 1）。已验证的实时遗留 `.json` 键：`kind, lastUpdated, messages, projectHash, sessionId, startTime`。

| 字段 | 类型 | 含义 | 可选 | 被消费？ | 示例（已脱敏） |
|---|---|---|---|---|---|
| `sessionId` | string (UUID) | 稳定的会话身份；Engram 主键 | **required**（否则 `malformedJSON`） | ✅ | `"bcf966c3-0612-41b8-aa4a-e95da1e86144"` |
| `startTime` | string (ISO-8601 ms, UTC `Z`) | 会话开始 | **required** | ✅ → `startTime` | `"2026-04-13T07:47:26.014Z"` |
| `lastUpdated` | string (ISO-8601 ms, UTC `Z`) | 最后写入 | optional | ✅ → `endTime` | `"2026-04-13T07:47:26.238Z"` |
| `projectHash` | string (64-hex SHA-256) | 项目哈希（文件内）；可能与启动器别名目录不同 | 实时存在 | ❌（从不读取；cwd 优先由 `.project_root` 推导） | `"cf46ca80ac87adfa…16206b"` |
| `kind` | string | 会话类别区分符；观察到的值为 `"main"` | 实时存在，**fixtures 中缺失** | ❌（两个适配器都未声明） | `"main"` |
| `messages` | array<object> | 有序的对话/事件记录（[§6](#6-message--content-schema)） | **required** | ✅ | `[ {…}, … ]` |
| `summary` | string | Gemini 原生 resume/list 摘要元数据 | optional（官方；当前 legacy live keys 中未见） | ❌（Engram 从第一条用户回合自行合成 summary） | `"Implement cache cleanup"` |
| `memoryScratchpad` | object | 用于 memory extraction 的轻量 workflow 元数据 | optional（官方） | ❌ | `{ "version": 1, "workflowSummary": "..." }` |
| `directories` | array<string> | 会话期间通过 `/dir add` 加入的 workspace 目录 | optional（官方） | ❌ | `["/Users/<u>/repo"]` |

> **磁盘上无 `messageCount`。** 任何样本中都 **没有** 顶层 `messageCount` 字段 —— 它在实时数据中缺失（`surge/…/75cb965e.json` topkeys = `[kind,lastUpdated,messages,projectHash,sessionId,startTime]`），**且** 在两个 fixtures 中也缺失（`tests/fixtures/gemini/session-sample.json` 和 `adapter-parity/gemini-cli/input/.../session-sample.json` 的 topkeys = `[lastUpdated,messages,projectHash,sessionId,startTime]`；对两者 `grep -l messageCount` → 无匹配）。`messageCount` 仅作为 Engram 的 **重新计算** 值出现在 parity *expected* 输出中（`insightFields.messageCount: 3`），磁盘上从不作为源字段存在。

> **差异标记。** `kind` 在两个实时 `.json` 文件中都存在，但在 fixtures 中缺失，且不被任一适配器声明/读取。官方当前 Gemini CLI 类型还包括可选的 `summary`、`memoryScratchpad` 和 `directories`；当前 Engram replay 时会保留这些键，但不会映射到 session 字段。TS 的 `GeminiSession` 接口声明了 `projectHash` 和 `summary`（TS:14-19），但 Swift 适配器从不把两者映射为元数据字段。这些遗漏不影响当前转录解析。

---

## 6. Message & content schema

### 6.1 通用信封字段（所有 `messages[]` 记录 —— layer 2）

| 字段 | 类型 | 含义 | 可选 | 被消费？ | 示例 |
|---|---|---|---|---|---|
| `id` | string | 每消息 id —— 官方代码路径是 `id || randomUUID()`（带连字符的 UUID）；实时 `.jsonl` 显示 **32 位十六进制** id，官方 `randomUUID()` 路径不会产生（很可能是启动器/转换过的 id；见 [§15 remaining unknowns](#resolved-confirmations--remaining-unknowns)）；fixtures 中是短的 `mNNN` | required | ❌ | `"6e0f533f-996a-4479-a907-b1983e7e7d38"` |
| `timestamp` | string (ISO-8601 ms, UTC) | 记录产生的时间 | required | ✅ (streamMessages) | `"2026-04-08T03:26:59.220Z"` |
| `type` | string | 记录区分符：`user`/`gemini`/`info`/`error`/`warning`（官方；`model` 仅为 Engram 别名） | required | ✅（驱动 role + 计数） | `"gemini"` |
| `content` | `PartListUnion` (`string \| Part \| Part[]`) | 载荷（多种形态！） | required | ✅（被扁平化） | `[{"text":"…"}]` 或 `"…"` |

**内容块（layer 3）。** 已确认（官方）：`content` 对 **所有** 消息记录都被类型化为 `PartListUnion`（`BaseMessageRecord.content: PartListUnion`），即完整的 Gemini SDK 联合 `string | Part | Part[]`，不受 `type` 限制（[chatRecordingTypes.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatRecordingTypes.ts)）。因此 content 可能比 `[{text}]` 更丰富 —— 它可能携带 `functionCall`/`functionResponse`/`inlineData` 部分。当 `content` 是 `{text}` 数组时，`extractText` 用 `\n` 连接所有非空 `.text`（Swift `extractText` 307-315、TS 54-62）；非文本部分不被提取。裸字符串 `content` 原样使用。

> **实时观察：** `user` content 是 `{text}` 数组；实时中 `gemini` 和 `info` content 为纯字符串。已确认（官方）：数组/`Part[]` content 可出现在 **任何** 消息类型上（`gemini`/`info`/`error`/`warning`），不仅是 `user` —— 每条记录的 `content` 都是 `PartListUnion`。[chatRecordingTypes.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatRecordingTypes.ts)

### 6.2 `type: "user"` 记录

| 字段 | 类型 | 含义 | 可选 | 被消费？ | 示例 |
|---|---|---|---|---|---|
| `content` | array of `{text}` | 用户回合 | required | ✅（连接） | `[{"text":"<user prompt>"}]` |
| `displayContent` | array of `{text}` | UI 渲染版本（可能不同；如展开的 slash 命令） | 实时（user 消息） | ❌（忽略） | `[{"text":"<rendered prompt>"}]` |
| `id`,`timestamp`,`type` | — | 通用信封 | required | — | — |

```json
{
  "id": "6e0f533f-996a-4479-a907-b1983e7e7d38",
  "timestamp": "2026-04-08T03:26:59.220Z",
  "type": "user",
  "content": [ { "text": "<user prompt text>" } ],
  "displayContent": [ { "text": "<rendered prompt text>" } ]
}
```

### 6.3 `type: "gemini"`（助手）记录 —— 最丰富的记录

| 字段 | 类型 | 含义 | 可选 | 被消费？ | 示例 |
|---|---|---|---|---|---|
| `content` | string | 助手最终文本（实时：始终为纯字符串） | required | ✅ | `"<assistant reply text>"` |
| `model` | string | 产生该回合的模型 id | optional（实时：gemini 上始终存在） | ❌（始终 `model:nil`） | `"gemini-3.1-pro-preview"` |
| `thoughts` | array of `{subject,description,timestamp}` | 推理轨迹（[§8](#8-reasoning--thinking)） | optional | ❌（文本被丢弃；token 计数被折算） | `[ {…} ]` |
| `tokens` | object | 每回合 token 用量（[§9](#9-token-usage--cost)） | optional | ✅（仅 Swift） | `{ … }` |
| `toolCalls` | array | 工具调用 + 内联结果（[§7](#7-tool-calls--results)） | optional（未用工具时缺失） | ❌（`toolCalls:nil`） | `[ {…} ]` |
| `displayContent` | null/absent | gemini 记录上不使用（观察为 `null`） | optional | ❌ | `null` |
| `id`,`timestamp`,`type` | — | 通用信封 | required | — | — |

> **覆盖标记。** `model`、`thoughts`、`toolCalls` 和 `displayContent` 是磁盘上真实存在但 Swift 产品适配器 **不** 暴露的字段 —— 对助手记录它只读取 `content`、`timestamp` 和 `tokens`（Swift:211-226），设置会话级 `model:nil`（Swift:138）和每消息 `toolCalls:nil`（Swift:223）。推理、模型 id 和工具调用都在磁盘上，但被规范化 **丢弃**。

```json
{
  "id": "<uuid>",
  "timestamp": "2026-04-08T03:27:10.000Z",
  "type": "gemini",
  "model": "gemini-3.1-pro-preview",
  "content": "<assistant final answer>",
  "thoughts": [ /* §8 */ ],
  "tokens":   { /* §9 */ },
  "toolCalls":[ /* §7 */ ]
}
```

### 6.4 `type: "info"` 记录（系统事件）

| 字段 | 类型 | 含义 | 可选 | 被消费？ | 示例 |
|---|---|---|---|---|---|
| `content` | string | 系统/info 通知 | required | ❌（被排除于计数） | `"<info / system notice text>"` |
| `id`,`timestamp`,`type` | — | 通用信封 | required | — | — |

在 parity fixture 中，4 条原始消息（其中 1 条为 `info`）规范化为 `messageCount: 3`。

---

## 7. Tool calls & results

工具调用 **仅** 出现在 `gemini` 记录的 `toolCalls[]` 数组内。**请求与结果共置于同一元素中** —— 没有单独的"工具结果"记录。实时看到的 `name` 值：`activate_skill`、`read_file`。Engram **不** 把它们导入消息（`toolCalls:nil` Swift:223；TS `streamMessages` 从不发出工具数据 TS:201-209）。

### 7.1 `toolCalls[]` 元素（layer 3）

| 字段 | 类型 | 含义 | 可选 | 示例 |
|---|---|---|---|---|
| `id` | string | 工具调用 id；**等于内层 `result[].functionResponse.id`**（关联键） | required | `"read_file-…"` |
| `name` | string | 工具名（snake_case） | required | `"read_file"` |
| `displayName` | string | 工具的 UI 标签 | optional | `"ReadFile"` |
| `description` | string | 调用的人类描述 | optional | `"<call description>"` |
| `args` | object | 工具参数；键取决于工具（如 `file_path`、`name`） | required | `{ "file_path": "<path>" }` |
| `status` | enum string | 执行状态。实时只观察到 `"success"`，但完整集合更大。已确认（官方）：持久化的 `ToolCallRecord.status` 是来自 `packages/core/src/scheduler/types.ts` 的调度器 `Status`（生命周期状态：`validating`/`scheduled`/`executing`/`success`/`error`/`cancelled`/`awaiting_approval`），而 **非** CLI UI 的 `ToolCallStatus` 枚举（`pending`/`canceled`/`confirming`/`executing`/`success`/`error`）。`error` 和 `cancelled` 是真实存储值。[chatRecordingTypes.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatRecordingTypes.ts)、[cli ui/types.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/cli/src/ui/types.ts) | required | `"success"` |
| `timestamp` | string (ISO-8601) | 调用运行的时间 | required | `"2026-04-08T03:27:12.986Z"` |
| `renderOutputAsMarkdown` | boolean | UI 提示：将结果渲染为 markdown | optional | `true` |
| `result` | array of `{functionResponse}` | 工具的返回载荷（§7.2） | required | `[ {…} ]` |
| `resultDisplay` | string | 结果的人类渲染版本 | optional | `"<rendered result>"` |

### 7.2 `result[].functionResponse` —— 工具结果信封（layer 4，最深）

| 字段 | 类型 | 含义 | 可选 | 示例 |
|---|---|---|---|---|
| `id` | string | **匹配父 `toolCall.id`** → 调用↔结果关联 | required | `"read_file-…"` |
| `name` | string | 工具名（匹配 `toolCall.name`） | required | `"read_file"` |
| `response` | object `{output:string}` | 实际返回值；`output` 保存结果文本 | required | `{ "output": "<result text>" }` |

**关联（实时数据上已验证）：** 对每个实时工具调用，`toolCall.id === toolCall.result[0].functionResponse.id` 且 `toolCall.name === functionResponse.name`。无需管理跨记录关联；结果嵌入在与调用相同的数组元素中。

```json
"toolCalls": [
  {
    "id": "read_file-1712547432000-abcd",
    "name": "read_file",
    "displayName": "ReadFile",
    "description": "<call description>",
    "args": { "file_path": "<path>" },
    "status": "success",
    "timestamp": "2026-04-08T03:27:12.986Z",
    "renderOutputAsMarkdown": true,
    "resultDisplay": "<rendered result>",
    "result": [
      { "functionResponse": {
          "id": "read_file-1712547432000-abcd",
          "name": "read_file",
          "response": { "output": "<tool output text>" }
      } }
    ]
  }
]
```

> **覆盖标记。** Engram 完全丢弃 `toolCalls`；parity `success.expected.json` 确认 `toolCallCount: 0`。工具调用完整存在于磁盘，但在 Engram 产品中不可见。

---

## 8. Reasoning / thinking

存储为 `gemini` 记录内的 `thoughts[]`（layer 3）。实时示例分别有 5 和 15 个元素。每个元素：

| 字段 | 类型 | 含义 | 可选 | 示例 |
|---|---|---|---|---|
| `subject` | string | 推理步骤的简短标题 | required | `"<thought heading>"` |
| `description` | string | 推理正文文本 | required | `"<reasoning text>"` |
| `timestamp` | string (ISO-8601) | 该 thought 发出的时间 | required | `"2026-04-08T03:27:05.000Z"` |

```json
"thoughts": [
  { "subject": "<step heading>", "description": "<reasoning text>", "timestamp": "2026-04-08T03:27:05.000Z" }
]
```

Engram **丢弃推理文本**（两个适配器都不读取），但 `thoughts` **token 计数** 会被折算进 output token（[§9](#9-token-usage--cost)）。

---

## 9. Token usage & cost

每回合用量位于 `gemini` 记录内的 `tokens`（layer 3）。实时值（原样保留 —— 非敏感）：

```json
{ "input": 60823,  "output": 10,  "cached": 0,     "thoughts": 1664, "tool": 0, "total": 62497 }
{ "input": 61350,  "output": 100, "cached": 54434, "thoughts": 0,    "tool": 0, "total": 61450 }
{ "input": 104207, "output": 983, "cached": 67764, "thoughts": 4809, "tool": 0, "total": 109999 }
```

| 字段 | 类型 | 含义 | Engram (Swift) 映射 |
|---|---|---|---|
| `input` | int | Prompt/输入 token（**包含** cached） | `inputTokens = max(input − cached, 0)` |
| `cached` | int | 缓存读取 token（`input` 的子集） | `cacheReadTokens = cached` |
| `output` | int | Completion/答案 token | 累加进 `outputTokens` |
| `thoughts` | int | 推理轨迹 token | 累加进 `outputTokens` |
| `tool` | int | 工具调用 token | 累加进 `outputTokens` |
| `total` | int | Gemini 报告的总计 | ❌ 未使用 |

**推导**（Swift `usage()` 228-246）：
- `inputTokens = max(input − cached, 0)`（仅未缓存的输入）
- `outputTokens = output + thoughts + tool`（最终 + 推理 + 工具合并）
- `cacheReadTokens = cached`
- `cacheCreationTokens = 0`（Gemini 不报告单独的缓存创建计数）
- 若三个推导值全为 0 则返回 `nil`；`user` 记录不携带用量（Swift:224）。

> **差异标记。**
> 1. **TS 参考适配器丢弃所有 token 用量** —— `gemini-cli.ts` 中任何地方都没有 `tokens` 处理。Swift 是 **唯一** 为 Gemini CLI 产出成本/用量数据的路径。
> 2. parity fixture 的 `usageTotals` 全为零，因为其合成输入没有 `tokens` 块。该 fixture 因而 **掩盖** 了 TS-vs-Swift 的分歧，而非测试 token 提取。真实会话 **会** 填充用量。

Gemini CLI 不存储每 token 的 **价格/成本**；Engram 在下游从这些计数计算成本（不在适配器范围内）。

---

## 10. Subagent / parent-child / dispatch

**更正（web 已确认 2026-06-21；Engram 状态 2026-07-02 刷新）。** Gemini CLI 的原生文件 **确实** 在磁盘上记录 subagent 谱系。已确认（官方）：一条会话记录携带 `kind?: 'main' | 'subagent'`，当 `kind === 'subagent'` 时会话文件存储在 **以 `parentSessionId` 命名的子目录** 中（文件名 `<sanitizedSessionId>.jsonl`）。因此原生的 父→子 关系独立于 Engram 的 sidecar 而存在 —— [chatRecordingService.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatRecordingService.ts)、[chatRecordingTypes.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatRecordingTypes.ts)。当前 Engram 已能发现并 replay 这些嵌套 JSONL 文件，并把 `chats/<parentSessionId>/<sanitizedSessionId>.jsonl` 映射为 `agentRole=subagent` 与 `parentSessionId=<parentSessionId>`。同级 sidecar `<chatsDir>/<sessionId>.engram.json` 仍被支持，用于外部 `gemini-plugin-cc`（而非 Gemini CLI）写入的 parent link 与 originator metadata。最新 smoke 中 **本机不存在任何原生嵌套 subagent 文件或 sidecar**，因此该路径由回归测试覆盖，而非 live rows 覆盖。

`readSidecar`（Swift:215-224）/ TS:147-163 恰好读取两个字段：

| 字段 | 类型 | 含义 | Engram 用途 |
|---|---|---|---|
| `parentSessionId` | string | 确定性父（dispatcher）会话 id | → `parentSessionId`（Layer 1c，已确认链接） |
| `originator` | string | 谁启动了它（`"Claude Code"` / `"claude-code"`） | → `originator`；若规范化为 `claudecode` → `agentRole:"dispatched"` |

Originator 匹配对规范化是容忍的。**漂移说明：** TS `isClaudeCodeOriginator`（TS:44-47）转小写 + 去除所有空格/破折号，要求 `claudecode`。Swift `OriginatorClassifier.isClaudeCode` 在把 `_`/space→`-` 规范化后要求恰好为 `claude-code`（见 `SessionAdapter.swift`）。两者都接受 `"Claude Code"` 和 `"claude-code"`；含内部标点的边缘形式可能分歧。

被标记为 `agentRole='dispatched'` 的 Gemini 会话会被分级为 `skip`（通过父访问），与 Codex 共享的跨适配器 originator 约定一致（`CodexAdapter` 使用相同的 `OriginatorClassifier.isClaudeCode`）。

```json
{ "parentSessionId": "<claude-code-session-uuid>", "originator": "claude-code" }
```

---

## 11. Summary / compaction

Gemini CLI 在 `ConversationRecord` / JSONL `$set` 中有可选的原生顶层 `summary` 元数据，但没有类似其他 provider 的独立 compaction transcript record。Engram **不消费** Gemini 的顶层 `summary`；它自己从第一条 `user` 消息的扁平化文本合成会话 **summary**，截断为 200 字符（`summary` Swift:147 `String(firstUserText.prefix(200))`、TS:179 `firstUserText?.slice(0, 200)`）。因此 Engram summary 来自转录文本，而非 Gemini 原生元数据字段。

---

## 12. SQLite / DB internals

**对 Gemini CLI 不适用（N/A）。** 会话是纯 JSON/JSONL 文件；没有 SQLite、leveldb 或 gRPC 缓存。（对比 VS Code 的 `.vscdb`/leveldb 家族 —— Cursor / VS Code / Copilot / Cline —— 它们另行记录，与 Gemini 无谱系关系。）

---

## 13. Auxiliary files

实时存在的辅助文件及当前适配器使用情况：

| 文件 | 形态 | 示例（已脱敏） | 说明 |
|---|---|---|---|
| `~/.gemini/projects.json` | `{ "projects": { "<absCwd>": "<projectName>" } }`（或裸 map） | `{ "projects": { "/Users/<u>/-NetWork-/Surge": "surge" } }` | **不是 Gemini CLI 文件。** 已确认（官方）：Gemini CLI 核心既不创建也不读取 `~/.gemini/projects.json`；`getProjectHash` 是无逆的单向 SHA-256。观察到的文件是外部启动器/Engram 产物。Engram 仅把它作为 `.project_root` 缺失时的 cwd 反向查找 fallback（[§14](#14-engram-mapping)）。258 条实时条目。[paths.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/utils/paths.ts) |
| `<projectDir>/.project_root` | 1-line absolute cwd | `/Users/<u>/-NetWork-/Surge` | 已确认（官方）：Gemini CLI 写入的 **唯一** 每项目 cwd 记录 —— 权威 cwd 源。当前 Engram 优先消费它；本机有 4 个 `.project_root`。 |
| `<projectDir>/logs.json` | array of `{ sessionId, messageId:int, type, message, timestamp }` | `{ "sessionId":"75cb965e…", "messageId":0, "type":"user", "message":"…", "timestamp":"…Z" }` | 轻量级每消息遥测；忽略。`messageId` 是 **每会话内 0 起始的整数序列**（实时 `logs.json` 的 `messageId` 值 `[0,1,0]` —— 新会话从 0 重新开始）。 |
| `<projectDir>/logs/` | directory（polycli 项目中存在） | — | 新版每项目日志目录；忽略。 |
| `<sessionId>.engram.json` | `{ parentSessionId, originator }` | （实时无） | Engram 父链接 sidecar（[§10](#10-subagent--parent-child--dispatch)）。 |
| `~/.gemini/settings.json`、`state.json` | CLI config | — | 非会话数据；从不读取。 |

`projects.json` 以绝对 cwd 为键、短名为值；两个适配器都接受 `{"projects":{…}}` 包装或裸顶层 map，并仅在 `.project_root` 不存在时作为 fallback（Swift:183-205、TS:223-245）。

---

## 14. Engram mapping

`source field/record → Engram Session field → adapter file:line`。

| Engram 字段 | 源字段/记录 | Swift file:line | TS file:line | 说明 |
|---|---|---|---|---|
| `id` | `sessionId` | `:108-110,135` | `:120,168` | UUID，required（否则 `malformedJSON` / null） |
| `source` | constant | `:66,136` | `:71-72,169` | `.geminiCli` / `'gemini-cli'` |
| `summary` / title | first `user` message text, `prefix(200)` | `:129,147` | `:143-145,179` | 空 → nil；扁平化内容；原生顶层 `summary` 被忽略 |
| `project` | dir name above `chats/`（path component before `chats`） | `:125,140,207-213` | `:131-134,173` | `<projectDir>`（alias 或 hex），而非文件内 `projectHash` |
| `cwd` | 优先 `.project_root`；再用 `projects.json` **反向** 查找（value==project）；最后 fallback = project | `:126-128,183-205` | `:138-141,223-245` | 当前 live `.jsonl` 解析 `safeline` → `/Users/bing/-NetWork-/Safeline` |
| `startTime` | `startTime` | `:109-110,137` | `:120,170` | required |
| `endTime` | `lastUpdated` | `:138` | `:171` | optional |
| `messageCount` | `userMessages.count + assistantMessages.count` | `:116-124,142` | `:123-129,174` | 排除 `info`/工具/系统和空内容回合 |
| `userMessageCount` | empty-content filtering 后的 `type=="user"` | `:116-119,143` | `:123-126,175` | Swift 和 TS 都在计数前过滤空内容 |
| `assistantMessageCount` | empty-content filtering 后的 `type=="gemini" \|\| "model"` | `:116-124,144` | `:123-129,176` | 两个名称都计入 |
| `toolMessageCount` | constant `0` | `:145` | `:177` | `info`/`toolCalls` 从不计入 |
| `systemMessageCount` | constant `0` | `:146` | `:178` | |
| `model` | **`nil`**（从不读取） | `:141` | (omitted) | 每消息 `model` 被忽略 |
| `filePath` | locator | `:148` | `:180` | |
| `sizeBytes` | file size | `:149` | `:118,181` | Swift `Phase4AdapterSupport.fileSize`；TS `stat.size` |
| `parentSessionId` | sidecar `parentSessionId` | `:130,157,215-224` | `:147-158,182` | Layer 1c 确定性链接 |
| `originator` | sidecar `originator` | `:131,151-152,215-224` | `:149-161,183` | |
| `agentRole` | `isClaudeCode(originator) ? "dispatched" : nil` | `:151` | `:184-186` | |
| `suggestedParentId` | `nil` | `:158` | (omitted) | Layer 2 稍后由检测设置 |
| **per-message** `role` | `type=="user"`→`.user`，否则 `.assistant` | `:267-275` | `:212-217` | |
| **per-message** `content` | `extractText(content)`（用 `\n` 连接 `.text`） | `:272-273,307-315` | `:212-218,54-62` | 空内容消息被跳过 |
| **per-message** `timestamp` | `timestamp` | `:277` | `:218` | |
| **per-message** `usage` | per-msg `tokens` → `TokenUsage` | `:279,283-300` | **none** | **仅 Swift**；TS 丢弃所有 token 用量 |
| **per-message** `toolCalls` | `nil`（丢弃） | `:278` | (none) | 工具数据不暴露 |

**Engram 不消费的内容：** `info` 类型消息；空内容消息；每消息 `model`；`thoughts` 文本；`displayContent`；`toolCalls`（args/results/status）；消息 `id`；顶层 `projectHash`、`kind`、`summary`、`memoryScratchpad`、`directories`；`tokens.total`；以及（TS 路径）所有 token 用量。原生 subagent 父链接从 JSONL 路径消费，而不是来自顶层字段。（磁盘上没有顶层 `messageCount` 可消费 —— Engram 重新计算它；见 §5。）

---

## 15. Lineage, gotchas, version drift & edge cases

### 与同源工具的共享格式谱系

Gemini CLI 的 `~/.gemini/tmp/<projectDir>/chats/session-*.json` + `projects.json` 的 `cwd→name` 映射是被分支（fork）共享的 **Google 生态家族 schema**：

- **Qwen Code**（`src/adapters/qwen.ts` / `QwenAdapter.swift`，根 `~/.qwen/`）和 **iFlow**（`~/.iflow/`）是 Gemini-CLI 分支，复用相同的 `tmp/<dir>/chats/` + `projects.json` 布局、`user`/`gemini|model`/`info` 分类和 `[{text}]` 内容块。Gemini 适配器实际上是这些同源工具的模板。
- **基于 originator 的 dispatch 检测** 是与 **Codex** 共享的跨适配器约定（`CodexAdapter` 复用 `OriginatorClassifier.isClaudeCode`），因此由 Claude Code *启动* 的 Gemini/Qwen/Codex 会话被统一标记为 `agentRole='dispatched'` 并分级为 `skip`。
- **`<sessionId>.engram.json` sidecar**（父链接 Layer 1c）是 Engram 由 `gemini-plugin-cc` 写入的 *自有* 确定性约定，叠加在 Gemini 原生文件之上 —— 不是 Gemini CLI 格式的一部分。
- 该家族 **不同于** **VS Code `.vscdb`/leveldb 家族**（Cursor ↔ VS Code ↔ Copilot ↔ Cline）—— 完全不同的存储技术；无谱系重叠。

### Gotchas / 版本漂移 / 边缘情况

1. **格式漂移 `.json` → `.jsonl`（源码已修，剩余清理）。** 已确认（官方）：当前 Gemini CLI 为 **所有** 新会话写入 `.jsonl`（PR #23749，v0.39.0）；单对象 `.json` 是只读遗留，在恢复时迁移为 `.jsonl`。`.jsonl` 是 **事件溯源追加日志**（元数据记录 + 每回合 `MessageRecord` 追加 + `$set` 元数据增量 + `$rewindTo` 截断），并非全量快照式的 `$set` 日志 —— 它必须逐行重放。当前 Engram 源码已经实现该解析，live DB 现在也包含 Safeline `.jsonl`；剩余 DB 工作是历史 row/file-index 清理，以及 rich legacy Surge `.json` 的一条 stale count snapshot。[PR #23749](https://github.com/google-gemini/gemini-cli/pull/23749)、[chatRecordingService.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatRecordingService.ts)
2. **`cwd` 解析必须优先 `.project_root`。** 已确认（官方）：Gemini CLI 不写也不读 `~/.gemini/projects.json`；每项目目录 **始终** 是项目根路径的 64 位十六进制 SHA-256（`getProjectHash`），唯一的磁盘 cwd 记录是 `tmp/<hash>/.project_root`。当前 Engram 源码已先读 `.project_root`，再 fallback 到插件/启动器创建的 `projects.json` 反向查找，最后才回退到原始 project dir。[paths.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/utils/paths.ts)
3. **`messageCount` 语义。** Engram 的计数 = 仅用户+助手的非空消息；它不等于原始 `messages.length`（后者包含 `info`/空回合）。Gemini 磁盘上 **不存储** 顶层 `messageCount`（§5）；Engram 重新计算它。纯 `info` 会话报告 `0`。
4. **历史 DB 计数漂移。** 当前 Swift 与 TS 源码都会在计数前过滤空内容消息，stream 输出也会跳过空文本。既有 DB 行在重扫前仍可能保留旧计数；live 的 `surge` 富 `.json` 有 4 条原始消息，但当前 parser 只返回 3 个可计数回合。
5. **Originator 规范化漂移。** Swift 要求 `claude-code`（把 `_`/space→`-` 规范化）；TS 要求 `claudecode`（去除所有空格/破折号）。两者都接受 `"Claude Code"` / `"claude-code"`；含标点的边缘形式可能分歧。
6. **Token 仅在 Swift 产品路径中。** Gemini token 用量/成本通过 TS 参考适配器不可用；parity fixture（全零 `usageTotals`）掩盖了这一点。
7. **`model` 始终为 nil。** 即使每条助手消息上都有，Engram 也无法报告是哪个 Gemini 模型（如 `gemini-3.1-pro-preview`）产生了会话。
8. **大小上限 Swift vs TS 不同（10 MB vs 100 MB）。** TS 参考适配器跳过 > **10 MB** 的文件（`MAX_SESSION_JSON_BYTES`，`gemini-cli.ts:33`）；Swift 产品适配器跳过 > **100 MB** 的文件（`ParserLimits.default.maxFileBytes = 100*1024*1024`，`ParserLimits.swift:17`）—— 上限大 10×，通过 `GeminiCliAdapter.readJSONObject` → `JSONLAdapterSupport.prepareFile` → `limits.validateFileSize` → `ParserLimits.swift:48`（`sizeBytes > maxFileBytes ? .fileTooLarge`）强制执行。实时 201.8 KB 会话远低于两者；一个 10–100 MB 会话会被 TS 丢弃但被 Swift 保留，只有 > 100 MB 才被两者都丢弃。Swift 还额外限制每行字节数（8 MB，`maxLineBytes`）和消息数（10,000，`maxMessages`）；TS 两者皆无。这是又一处 Swift-vs-TS 分歧（参见 tokens #6、originator #5）。
9. **原生 subagent 谱系是 path-based，当前已被 Engram 消费。** 已确认（官方）：Gemini CLI 记录 `kind: 'main' | 'subagent'`，并把 subagent 会话存储在以 `parentSessionId` 命名的子目录中（文件名 `<sanitizedSessionId>.jsonl`），因此原生的 父→子 关系 **确实** 在磁盘上。当前 Engram 会递归发现 `chats/` 下的 JSONL，并把 `chats/<parentSessionId>/<sanitizedSessionId>.jsonl` 映射为 `agentRole=subagent` 与 `parentSessionId`。最新 smoke 中本机没有原生嵌套 subagent 文件或 `*.engram.json` sidecar，因此 live DB 尚无当前 Gemini subagent rows。[chatRecordingService.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatRecordingService.ts)、[chatRecordingTypes.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatRecordingTypes.ts)
10. **文件身份保护（仅 Swift）。** 若文件在读取中途改变，Swift reader 抛出 `fileModifiedDuringParse`；一个正在被追加的会话（对实时 `.jsonl` 增量很常见）可能失败并等待后续重试。
11. **`projectHash` = 目录名；两者都是项目根路径的 SHA-256。** 已确认（官方）：每项目目录名就是 `getProjectHash(projectRoot) = sha256(projectRoot).digest('hex')`，因此对一个真正的 Gemini CLI 目录，目录名等于文件内 `projectHash`（实时 `surge`/`cf46ca80…` 的不匹配是因为 `surge` 是启动器提供的非 hash 别名，而非 Gemini CLI 目录名）。该哈希作用于项目根 **路径字符串** 且单向（无逆）；cwd 恢复必须读取 `.project_root`。Engram 通过使用目录名路径组件规避了所有这些。[paths.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/utils/paths.ts)

### Resolved confirmations / remaining unknowns

- ~~给 Engram 增加 `.jsonl` 发现与事件重放解析~~ **当前源码已解决** —— Swift 与 TS 现在都发现 `.jsonl`，重放 `$set` 与 `$rewindTo`，并有 focused tests。剩余问题是安装版/runtime 重扫状态，不是 parser 形状。[PR #23749](https://github.com/google-gemini/gemini-cli/pull/23749)、[Issue #15292](https://github.com/google-gemini/gemini-cli/issues/15292)
- **已确认（官方）：** 不存在 alias-vs-hash 规则 —— `tmp/<projectDir>` **始终** 是 `getProjectHash(projectRoot) = sha256(projectRoot).digest('hex')`，作用于项目根 **路径字符串**（而非 git 根）。可读目录名是启动器产物，而非 Gemini CLI 行为。[paths.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/utils/paths.ts)
- **已确认（官方）：** 在 Gemini CLI 中 hash 目录 → cwd 是有意 **单向** 的（`getProjectHash` 无逆，且没有 `projects.json` 注册表）。hash→path 映射不存在；正确的反向源是 `tmp/<dir>/.project_root`。[paths.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/utils/paths.ts)
- **已确认（官方）：** Gemini CLI **确实** 垃圾回收旧转录。`cleanupExpiredSessions` 在 CLI 启动时运行，并删除超出可配置 `general.sessionRetention`（`enabled`、`maxAge`、`maxCount`、`minRetention`；默认 `maxAge` 为 `"30d"`）的会话，移除会话文件及关联产物。没有归档目录是因为过期转录被删除而非归档。[session-management.md](https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/session-management.md)、[gemini.tsx](https://github.com/google-gemini/gemini-cli/blob/main/packages/cli/src/gemini.tsx)、[sessionCleanup.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/cli/src/utils/sessionCleanup.ts)
- ~~确认 8 位十六进制文件名后缀是 `sessionId[0:8]`~~ **RESOLVED** —— 在全部 3 个当前实时文件上已确认（2 个 `.json` + 1 个 `.jsonl`；见 §2 命名语法）。仍待解决：32 位十六进制消息 id（`.jsonl`）vs UUID（`.json`）是否为有意的格式变更（2026-07-02 再次网查：未找到权威来源 —— 官方代码路径是 `id || randomUUID()`，它产生带连字符的 UUID，因此实时 32 位十六进制 id 很可能是启动器/转换过的 id，而非 Gemini CLI 设计变更）。[chatRecordingService.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatRecordingService.ts)
- **已确认（官方）：** `gemini`/`info`（以及 `error`/`warning`）的 `content` **可以** 是数组 —— 每条记录的 `content` 都是 `PartListUnion`（`string | Part | Part[]`），不只是 `user`，并可携带非 `text` 部分。[chatRecordingTypes.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatRecordingTypes.ts)
- **已确认（官方）：** `toolCalls[].status` 是调度器 `Status` union（`validating`/`scheduled`/`executing`/`success`/`error`/`cancelled`/`awaiting_approval`），而非 UI `ToolCallStatus` 枚举；`error`/`cancelled` 是真实存储值。确切 union 已于 2026-07-02 从 `packages/core/src/scheduler/types.ts` 抓取确认。[chatRecordingTypes.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatRecordingTypes.ts)、[scheduler/types.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/scheduler/types.ts)、[cli ui/types.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/cli/src/ui/types.ts)
- 完整 sidecar（`*.engram.json`）字段集合尚未从真实数据验证（Engram 只读取 `parentSessionId`/`originator`；插件写入方可能发出更多）。*（Engram 内部设计 —— 不可通过 web 验证。）*
- **已确认（官方）：** 存在其他 `kind` 值 —— `kind?: 'main' | 'subagent'`。`subagent` 会话存储在以 `parentSessionId` 命名的子目录中，文件名为 `<sanitizedSessionId>.jsonl`（原生父/子谱系；见 [§10](#10-subagent--parent-child--dispatch)）。[chatRecordingTypes.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatRecordingTypes.ts)、[chatRecordingService.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatRecordingService.ts)

---

## 16. Appendix: real anonymized samples

> 结构/键原样保留；消息文本、代码、机密和个人路径已剥离。

### 16.1 遗留 `.json` 会话文档（顶层信封 + messages）

```json
{
  "kind": "main",
  "sessionId": "75cb965e-3678-4982-8cdb-e2ea8d31fd90",
  "projectHash": "cf46ca80ac87adfa400209bdfbe4e330881b8f6c1fd032bbbe5959167a16206b",
  "startTime": "2026-04-08T03:22:00.000Z",
  "lastUpdated": "2026-04-08T03:40:00.000Z",
  "messages": [
    { "id": "<uuid>", "timestamp": "2026-04-08T03:26:59.220Z", "type": "user",
      "content": [ { "text": "<user prompt>" } ],
      "displayContent": [ { "text": "<rendered prompt>" } ] },
    { "id": "<uuid>", "timestamp": "2026-04-08T03:27:10.000Z", "type": "gemini",
      "model": "gemini-3.1-pro-preview",
      "content": "<assistant final answer>",
      "thoughts": [ { "subject": "<heading>", "description": "<reasoning>", "timestamp": "2026-04-08T03:27:05.000Z" } ],
      "tokens": { "input": 60823, "output": 10, "cached": 0, "thoughts": 1664, "tool": 0, "total": 62497 },
      "toolCalls": [ /* see 16.3 */ ] }
  ]
}
```

### 16.2 仅 `info` 会话（yields messageCount 0）

```json
{
  "kind": "main",
  "sessionId": "bcf966c3-0612-41b8-aa4a-e95da1e86144",
  "projectHash": "cf46ca80ac87adfa400209bdfbe4e330881b8f6c1fd032bbbe5959167a16206b",
  "startTime": "2026-04-13T07:47:26.014Z",
  "lastUpdated": "2026-04-13T07:47:26.238Z",
  "messages": [
    { "id": "ad874a74-35b8-...-76fb", "timestamp": "2026-04-13T07:47:26.238Z",
      "type": "info", "content": "<info / system notice text>" }
  ]
}
```

### 16.3 带内联结果的 `toolCalls[]` 元素（layer 3 → 4）

```json
{
  "id": "read_file-1712547432000-abcd",
  "name": "read_file",
  "displayName": "ReadFile",
  "description": "<call description>",
  "args": { "file_path": "<path>" },
  "status": "success",
  "timestamp": "2026-04-08T03:27:12.986Z",
  "renderOutputAsMarkdown": true,
  "resultDisplay": "<rendered result>",
  "result": [
    { "functionResponse": {
        "id": "read_file-1712547432000-abcd",
        "name": "read_file",
        "response": { "output": "<tool output text>" }
    } }
  ]
}
```

### 16.4 新版 `.jsonl` 会话（event-sourced append log）

第 1 行 = 初始元数据记录；后续行 = 完整 `MessageRecord` 追加（每回合一个）、`{"$set": …}` 元数据增量，以及 `{"$rewindTo": …}` 截断。状态 = 重放所有行（不是最后一行胜出）。

```jsonl
{"kind":"main","sessionId":"b6a60539-...","projectHash":"<64hex>","startTime":"2026-06-21T01:33:00.000Z","lastUpdated":"2026-06-21T01:33:00.000Z"}
{"id":"<32hex>","timestamp":"2026-06-21T01:33:05.000Z","type":"user","content":[{"text":"<user prompt>"}]}
{"id":"<32hex>","timestamp":"2026-06-21T01:33:09.000Z","type":"gemini","content":"<assistant reply>","tokens":{"input":100,"output":20,"cached":0,"thoughts":0,"tool":0,"total":120}}
{"$set":{"lastUpdated":"2026-06-21T01:33:09.000Z","summary":"<derived summary>"}}
{"$rewindTo":"<messageId>"}
```

### 16.5 `projects.json`（global cwd → name map）

```json
{ "projects": { "/Users/test/my-project": "my-project", "/Users/test/other": "other-project" } }
```

### 16.6 `<projectDir>/logs.json` 行（辅助遥测；忽略）

```json
{ "sessionId": "75cb965e-3678-4982-8cdb-e2ea8d31fd90", "messageId": 0, "type": "user", "message": "<message text>", "timestamp": "2026-04-08T03:26:59.220Z" }
```

### 16.7 `<sessionId>.engram.json` sidecar（Layer 1c 父链接；仅适配器，实时无）

```json
{ "parentSessionId": "<claude-code-session-uuid>", "originator": "claude-code" }
```

### 16.8 `<projectDir>/.project_root`（辅助；用于 cwd）

```
/Users/<user>/-NetWork-/Surge
```

---

## 17. References (official sources)

Web 确认刷新于 2026-07-02。来源与官方 Gemini CLI 仓库和项目文档交叉核对。

- [google-gemini/gemini-cli — chatRecordingService.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatRecordingService.ts) — 会话存储读写器（记录分类、subagent 目录嵌套、`id || randomUUID()`）。
- [google-gemini/gemini-cli — chatRecordingTypes.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatRecordingTypes.ts) — 记录/字段类型定义（`type` 联合、`content: PartListUnion`、`summary`、`memoryScratchpad`、`directories`、`kind: 'main' | 'subagent'`、`$set`/`$rewindTo`、`ToolCallRecord.status`）。
- [google-gemini/gemini-cli — scheduler/types.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/scheduler/types.ts) — 持久化工具调用使用的调度器 `Status` union。
- [google-gemini/gemini-cli — paths.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/utils/paths.ts) — `getProjectHash` = `sha256(projectRoot).digest('hex')`（单向；无 `projects.json`）。
- [google-gemini/gemini-cli — cli ui/types.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/cli/src/ui/types.ts) — UI 层 `ToolCallStatus` 枚举（与持久化的调度器 `Status` 不同）。
- [google-gemini/gemini-cli — Session management docs](https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/session-management.md) — 默认 30 天 `sessionRetention` 策略，以及 `enabled`/`maxAge`/`maxCount`/`minRetention` 配置。
- [google-gemini/gemini-cli — gemini.tsx](https://github.com/google-gemini/gemini-cli/blob/main/packages/cli/src/gemini.tsx) 和 [sessionCleanup.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/cli/src/utils/sessionCleanup.ts) — 启动期 cleanup 调用与会话/关联产物删除路径。
- [PR #23749 — feat(core): migrate chat recording to JSONL streaming](https://github.com/google-gemini/gemini-cli/pull/23749) — `.json` → 仅追加 `.jsonl` 迁移（v0.39.0）。
- [Issue #15292 — Switch to JSONL for chat session storage](https://github.com/google-gemini/gemini-cli/issues/15292) — JSONL 切换的动机。
- [Gemini CLI docs — Checkpointing](https://google-gemini.github.io/gemini-cli/docs/cli/checkpointing.html) — `tmp/<project_hash>/` 布局。
