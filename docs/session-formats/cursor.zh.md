# Cursor 会话格式 — Engram 权威参考

> 本文档为英文权威版 cursor.md 的中文阅读副本;若有出入以英文版为准。

Last researched: 2026-06-21 (Engram session-format research workflow)

> **证据基础。** PRIMARY = 本机上的**实时磁盘存储**(用户的真实 Cursor 数据):
> `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`
> (28.2 MB SQLite)。与仓库固件
> `tests/fixtures/cursor/state.vscdb` (3 行) 以及
> `tests/fixtures/adapter-parity/cursor/{input/state.vscdb, success.expected.json}`
> 进行交叉核对,并对照两个 Engram 适配器:Swift 产品解析器
> `macos/Shared/EngramCore/Adapters/Sources/CursorAdapter.swift` 和
> TypeScript 参考实现 `src/adapters/cursor.ts`。**冲突时以真实数据为准;**
> 差异在文中就地标注。所有引用的值都已匿名化为仅保留结构(键/类型逐字保留,
> 消息文本/代码/密钥/路径已涂黑)。
>
> 为本文档实际执行的实时存储普查(对全局 DB 运行 `sqlite3`):
> `cursorDiskKV` 键前缀 —— `bubbleId` 524、`checkpointId` 369、
> `codeBlockDiff` 174、`composerData` 64、`agentKv` 46、`messageRequestContext` 24、
> (空前缀) 9、`composerVirtualRowHeights` 1。64 个 composer 中:
> **5 个值为 NULL / 51 个空 / 4 个仅头部 / 4 个内联**。在 6 个带摘要的 composer 中,
> **全部 6 个**都将 `latestConversationSummary.summary` 存为**对象**
> (0 个字符串)。Bubble `type` 分布:**71 user / 444 assistant**。

---

## 1. 概述与 TL;DR

**是什么。** Cursor 是 **VS Code 的分叉**,继承了 VS Code 的持久化模型:
一个名为 `state.vscdb` 的 SQLite 键/值数据库。但它**不会**把聊天存到
VS Code 的表里 —— 它在*全局*存储 DB 内新增了一张 Cursor 专用表 **`cursorDiskKV`**,
并把所有会话数据写入其中。

**在哪里。** `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`
(macOS)。**一个共享文件保存了所有时间段的每一个会话** —— 既没有按会话也没有
按天分文件。

**如何保存。** 每个 AI 会话是一个 **"composer"**,作为 `cursorDiskKV` 中的一行
`composerData:<composerId>` 存储。每条消息是一个 **"bubble"**。
消息以两种互斥的布局之一存在:**内联**(嵌入
`composerData.conversation[]`)或**仅头部 / 分离**(composer 中有一份清单
`fullConversationHeadersOnly[]` + 每条消息一行 `bubbleId:<composerId>:<bubbleId>`)。
写入是**原地 upsert**(`UNIQUE ON CONFLICT REPLACE`),从不追加。

**心智模型。**
- Composer = Engram **session**(一个 composer → 一个 Engram session)。
- Bubble = Engram **message**(`type` 1 = user,2 = assistant;没有 system/tool 角色)。
- 工具调用 + 其结果**嵌套在发起它的 bubble 内部**
  (`toolFormerData`),而非独立记录。通常是 assistant bubble,但
  **实时数据中 291 个 `toolFormerData` 负载里有 13 个位于 USER(type-1)bubble 上**,
  所以这种嵌套并非严格只在 assistant 上(278 assistant + 13 user)。
- Cursor 不会把 composer 绑定到某个 workspace;cwd 只能尽力推断。

```
                ┌──────────────────────────────────────────────────────────────┐
                │  globalStorage/state.vscdb   (SQLite, ONE file, 28.2 MB)        │
                │                                                                │
   Engram reads │  ┌── ItemTable ───────────────────────────────┐  (IGNORED)    │
   ONLY this DB │  │  composer.composerHeaders  (global catalog) │               │
   read-only    │  │  workbench.panel.*chat*    (UI state)       │               │
                │  └────────────────────────────────────────────┘               │
                │  ┌── cursorDiskKV ─────────────────────────────────────────┐   │
                │  │  composerData:<cid>          (64)  SESSION   <-- enumerate│   │
                │  │     ├─ conversation[]            inline bubbles (4)       │   │
                │  │     └─ fullConversationHeadersOnly[] -> points to:        │   │
                │  │  bubbleId:<cid>:<bid>        (524) MESSAGE  (separate, 4) │   │
                │  │       └─ toolFormerData          tool call + result       │   │
                │  │  checkpointId:<uuid>        (369)  FS snapshot  (IGNORED) │   │
                │  │  codeBlockDiff:<uuid>       (174)  edit diff    (IGNORED) │   │
                │  │  agentKv:blob:<sha256>      (46)   raw API msg  (IGNORED) │   │
                │  │  messageRequestContext:..   (24)   req context  (IGNORED) │   │
                │  │  composerVirtualRowHeights  (1)    UI cache     (IGNORED) │   │
                │  └─────────────────────────────────────────────────────────┘   │
                └──────────────────────────────────────────────────────────────┘

   workspaceStorage/<32-hex>/state.vscdb   (per-workspace pointer index, IGNORED by CursorAdapter)
```

**分层(4 个嵌套层,不要混为一谈):**
1. **DB 文件** —— `state.vscdb`(一个共享文件)。
2. **表 / 命名空间** —— `cursorDiskKV` 中按 `prefix:id[:id]` 作键的行。
3. **记录** —— composer(session)行、bubble(message)行等。
4. **内容子对象** —— 嵌套在记录内部的 `timingInfo`、`tokenCount`、`toolFormerData`、
   `context`、`codeBlocks`。

---

## 2. 磁盘布局与文件命名

**根路径(两个适配器都硬编码此路径并以只读方式打开):**

| 适配器 | 默认路径 | file:line |
|---|---|---|
| Swift (product) | `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` | `CursorAdapter.swift:9-11` |
| TypeScript (reference) | `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` | `cursor.ts:36-47` |

**目录树(实时验证):**

```
~/Library/Application Support/Cursor/User/
├── globalStorage/
│   └── state.vscdb                # <-- AUTHORITATIVE: all chat data (cursorDiskKV) + catalogs (ItemTable)
├── workspaceStorage/
│   ├── 02822dc51e1c79be6b4f8feb18737291/   # 32-hex workspace hash
│   │   ├── workspace.json         # { "folder": "file:///path/to/project" }  -> hash -> repo
│   │   ├── state.vscdb            # per-workspace UI state + composer.composerData pointer index
│   │   ├── state.vscdb.backup     # SQLite backup copy of the above
│   │   └── anysphere.cursor-retrieval/   # Cursor codebase-index extension state
│   ├── 04949500e42cbeac22dbcc972e071646/
│   └── … (28 workspace dirs)
├── History/                       # VS Code per-FILE edit history (NOT chat) — dirs like "-12d18da6"
├── snippets/
├── settings.json
└── keybindings.json
```

| 文件 / DB 类型 | 位置 | 角色 | Engram 是否读取? |
|---|---|---|---|
| `globalStorage/state.vscdb` | 全局 | 会话数据(`cursorDiskKV`)+ 全局目录(`ItemTable`)的**唯一来源** | YES(仅此一项) |
| `workspaceStorage/<hash>/state.vscdb` | 按 workspace | UI 面板状态 + `composer.composerData` 指针列表(仅 composerId,无内容) | NO |
| `workspaceStorage/<hash>/state.vscdb.backup` | 按 workspace | workspace DB 的备份快照 | NO |
| `workspaceStorage/<hash>/workspace.json` | 按 workspace | 把 32-hex hash 映射到项目文件夹 URI(唯一可靠的 composer→folder 映射) | NO |
| `History/` | 全局 | VS Code 按文件的编辑历史(时间戳 + 内容快照)—— 与聊天无关 | NO |

**命名语法 —— `cursorDiskKV` 键命名空间**(`prefix:id[:id]`),实时计数:

| 键模式 | 计数 | 含义 | 是否消费 |
|---|---|---|---|
| `composerData:<composerId>` | 64 | 一个 AI 会话("composer")。`composerId` = UUIDv4。**Engram 枚举的会话记录。** | YES |
| `bubbleId:<composerId>:<bubbleId>` | 524 | 分离/仅头部格式中的一条消息("bubble")。两个 id 均为 UUIDv4。 | YES |
| `checkpointId:<composerId>:<checkpointId>` | 369 | 按消息的文件状态检查点(agent 编辑的撤销/恢复) | no |
| `codeBlockDiff:<id>:<id>` | 174 | 生成的代码块相对基础版本的 diff | no |
| `agentKv:blob:<sha256>` | 46 | 内容寻址的原始 API `{role,content}` 消息 blob | no |
| `messageRequestContext:<composerId>:<bubbleId>` | 24 | 按请求的上下文(规则、目录结果、已摘要的 composer、终端) | no |
| (空前缀) | 9 | 杂项 / 内联 diff 编辑器状态(`inlineDiffsData`、`inlineDiffs-<id>`) | no |
| `composerVirtualRowHeights:<composerId>:_recentIds` | 1 | UI 渲染缓存(虚拟列表行高) | no |

**拓扑细节(已验证)。** 会话内容仅存在于**全局** DB 中。
按 workspace 的 `state.vscdb` 存储 `composer.composerData`,
其 `allComposers[]` 只是指向全局存储的指针列表(`composerId`、`createdAt`、
`unifiedMode`、`forceMode`)—— 没有消息正文。单个 composer 可被某个 workspace
索引引用,但其数据是全局的。Engram 有意忽略 `workspaceStorage/`,并从这一个
全局 DB 读取所有内容。(注意:单独的 `VsCodeAdapter` 才是抓取
`Code/User/workspaceStorage/` 的那个;`CursorAdapter` 从不这样做。)

**遗留警告(已修正)。** 此"仅全局"设计对 MODERN Cursor 是正确的。
然而,LEGACY 时代的 Cursor 把聊天存在按 workspace 的 `ItemTable` 键
`workbench.panel.aichat.view.aichat.chatdata`(`tabs[]`/`bubbles[]`)中。
这类遗留聊天可能仅存在于 `workspaceStorage/` 中,会被仅读全局 DB 的
适配器遗漏 —— 这是一个真实(但未量化)的缺口
([source](https://dasarpai.com/dsblog/cursor-chat-architecture-data-flow-storage/))。

示例键(实时,id 真实但不可识别身份):
```
composerData:0066a5aa-1757-44bf-a7c4-1a3d6ee3c790
bubbleId:191ae4eb-4c8f-4cb3-8531-b783611e03a6:02fcf474-adc1-42b7-8933-c3904ebfc5d8
checkpointId:191ae4eb-4c8f-4cb3-8531-b783611e03a6:<checkpointUuid>
```

---

## 3. 文件生命周期与生成

- **存储技术:SQLite,而非 JSONL / leveldb / 按消息分文件 / gRPC 缓存。**
  实时 schema(两张表完全相同):
  ```sql
  CREATE TABLE ItemTable    (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);
  CREATE TABLE cursorDiskKV (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);
  ```
  `value` 是一个 BLOB,在每个相关行中存储 **UTF-8 JSON 文本**
  (偶尔为 NULL,表示墓碑行 —— 64 个 `composerData` 行里有 5 个为 NULL;
  适配器对此做了防护)。

- **追加还是重写:原地 upsert(重写),从不追加。**
  `UNIQUE ... ON CONFLICT REPLACE` 子句是关键的生命周期信号 —— 每个新
  轮次都会 upsert composer 行(`lastUpdatedAt`、`status`、嵌入的
  `conversation`)并插入/更新 bubble 行。不存在仅追加的日志;
  实时 DB 就是当前状态。Engram 以只读方式打开,从不写入。

- **DB 还是文件:DB。** 不存在按消息的 JSON 文件。两种布局(§4)
  仅在消息是嵌入 composer 行还是在自己的 `bubbleId:` 行中这一点上有区别 ——
  两者都是 SQLite 行。

- **续接(Resume)。** 重新打开一个 composer 会在**相同的
  `composerId`** 下继续写入 —— `lastUpdatedAt` 前进,而 `createdAt` 保持不变。
  续接时不会创建新的文件/键。

- **滚动:无。** 没有按天 / 按大小的文件切分。所有时间段的所有 composer
  共享单一的 `globalStorage/state.vscdb`。增长在一个文件内是无界的(此处 28.2 MB)。
  因此两个适配器都把每个会话的大小计算为**仅该 composer 的 JSON 负载 +
  其分离的 bubble 行的原始字节数**,而非整个文件
  (`CursorAdapter.swift:72-77,95`、`cursor.ts:99-119,149`)。

- **归档 / 删除。** Cursor 通过 `composer.composerHeaders` 目录(ItemTable)中的
  `isArchived` / `isDraft` 标志来标记 composer。删除会移除
  `composerData:` 行(可能留下 NULL `value` 墓碑)。Engram
  不会按归档状态过滤;它枚举每一个 id 非空的 composer。

- **格式迁移。** 较旧的会话使用**内联** `conversation` 数组;
  较新的会话使用**分离** `bubbleId:` 行(`_v: 2`)。ItemTable 键
  `composer.planMigrationToHomeDirCompleted` 证实 Cursor 至少跑过一次
  存储位置迁移。Engram 的两路回退机制正是为了跨越这种演进而存在。

- **备份。** 每个 workspace 都保留一份 `state.vscdb.backup`;全局 DB 依赖
  SQLite WAL。Engram 既不显式读取备份,也不读取 WAL。

---

## 4. 记录 / 行 / 表分类法

恰好有 **2 张 SQLite 表**(`ItemTable`、`cursorDiskKV`),以及在
`cursorDiskKV` 内按键划分的以下**记录类型**(外加 `ItemTable` 中的单例键):

| 记录 | 键 | 层 | 用途 | 是否消费 |
|---|---|---|---|---|
| Composer | `composerData:<cid>` | session | 信封:时间戳、模式、摘要、上下文、可选的内联 `conversation[]` | YES |
| Header manifest | `composerData.fullConversationHeadersOnly[]` | sub-object | 指向分离 bubble 行的有序 `{bubbleId,type}` 指针 | indirectly (via LIKE) |
| Bubble | `bubbleId:<cid>:<bid>` | message | 一个 user/assistant 轮次;嵌套 `toolFormerData`、`codeBlocks`、`tokenCount`、`timingInfo` | YES |
| Checkpoint | `checkpointId:<cid>:<id>` | aux | 用于撤销/恢复 agent 编辑的文件系统快照 | no |
| Code-block diff | `codeBlockDiff:<id>:<id>` | aux | 建议编辑相对基础 v0 的行范围 diff | no |
| Agent KV blob | `agentKv:blob:<sha256>` | aux | 内容寻址的原始 provider `{role,content}` 消息 | no |
| Request context | `messageRequestContext:<cid>:<bid>` | aux | 按请求的规则 / 目录结果 / 已摘要 composer / 终端 | no |
| UI row-height cache | `composerVirtualRowHeights:<cid>:_recentIds` | aux | 虚拟列表渲染缓存 | no |
| Global catalog | `ItemTable['composer.composerHeaders']` | catalog | 跨会话列表(状态、行统计、归档标志) | no |
| Workspace index | `ItemTable['composer.composerData']` (per-workspace DB) | index | composer→folder 映射 | no |

### 两种会话存储格式(核心的生命周期分叉)

一个 composer 的消息以**两种**互斥方式之一存储。两个
适配器都用回退链来处理(`CursorAdapter.swift:191-219`、
`cursor.ts:106-120` / `188-202`):

1. **内联(legacy)** —— `composerData.conversation[]` 是一个非空数组,
   bubble 对象内联在 composer 行中。`rawBubbleBytes = 0`(没有任何
   分离内容)。**实时:4 / 64。**
2. **仅头部 / 分离(modern)** —— `composerData.conversation`
   为空/缺失;`composerData.fullConversationHeadersOnly[]` 是一份有序的
   `{bubbleId, type}` 清单,每条消息是自己的
   `bubbleId:<cid>:<bid>` 行。Engram 用
   `WHERE key LIKE 'bubbleId:<cid>:%' ORDER BY rowid ASC` 取出它们。**实时:4 / 64。**
3. **空 / 草稿** —— 既没有非空的 `conversation`,也没有匹配的
   `bubbleId:` 行 → 发出一个 0 消息会话。**实时:51 / 64 (~80%)。**
4. **NULL 值** —— `composerData:` 键存在,`value IS NULL` → 被防护逻辑
   跳过。**实时:5 / 64。**

两个适配器中的解析顺序:先尝试内联 `conversation`;只有为空时才
查询分离的 `bubbleId` 行。两种格式从不合并。注意:适配器**不会**直接读取
`fullConversationHeadersOnly` —— 它依赖 `bubbleId:` LIKE 前缀和
**rowid 顺序**(见 §15 陷阱 #1)。

---

## 5. 共享信封 / 元数据字段 —— `composerData:<composerId>`

composer 行是会话级记录(实时观察到约 35 个不同的顶层键;
某个内联 composer 上存在的 27 个键为:
`composerId, richText, hasLoaded, text, conversation, status, context,
gitGraphFileSuggestions, userResponsesToSuggestedCodeBlocks, generatingBubbleIds,
isReadingLongFile, codeBlockData, originalModelLines, newlyCreatedFiles,
newlyCreatedFolders, tabs, selectedTabIndex, lastUpdatedAt, createdAt,
hasChangedContext, capabilities, name, codebaseSearchSettings,
isFileListExpanded, unifiedMode, forceMode, isAgentic`)。

| 字段 | 类型 | 含义 | 可选 | 是否消费 | 示例(已匿名) |
|---|---|---|---|---|---|
| `_v` | int | 此记录的 schema 版本 | no | no | `3`(实时各异:`3`×43、缺失×11、`1`×3、`16`×2) |
| `composerId` | string (uuid) | 会话 id → Engram `id` | no | **yes** | `"191ae4eb-…-b783611e03a6"` |
| `name` | string | 用户/自动生成的**聊天标题** | yes (8/64) | **NO**(NormalizedSessionInfo 中没有标题字段) | `"<chat title>"` |
| `text` | string | 当前草稿输入框文本 | no(常为 `""`) | no | `""` |
| `richText` | string | 草稿输入的 Lexical/ProseMirror JSON | yes | no | `"<str len=176>"` |
| `status` | string | 会话运行状态 | yes | no | `"completed"`、`"aborted"` |
| `createdAt` | int (epoch **ms**) | 会话开始 → `startTime` | no* | **yes** | `1738226420089` |
| `lastUpdatedAt` | int (epoch ms) | 最后写入 → `endTime`(仅当 ≠ createdAt) | no* | **yes** | `1744430839587` |
| `conversation` | array<Bubble> | **内联**完整 bubble(legacy 变体) | yes(分离时为空) | **yes(存在时)** | `[{type:1,…}]` |
| `fullConversationHeadersOnly` | array<{bubbleId,type[,serverBubbleId]}> | 有序 bubble 清单(modern) | yes | no(改用 LIKE) | 见 §6.0 |
| `conversationMap` | object | 以 bubbleId 为键的映射(分离时通常为 `{}`) | yes | no | `{}` |
| `generatingBubbleIds` | array | 仍在流式生成的 bubble | yes | no | `[]` |
| `latestConversationSummary` | object | `{ summary, lastBubbleId }` → Engram `summary`(≤200 字符) | yes (6/64) | **部分(见漂移)** | 见下文 |
| `context` | object | 附加的文件/文件夹/终端/git/docs/规则 + `mentions` | no | 仅 TS(cwd) | 见下文 |
| `codeBlockData` | object (URI → [CodeBlock]) | 所有模型建议的编辑,按文件、带版本 | yes | no | 见下文 |
| `originalModelLines` | object (URI → lines) | 编辑前的文件行快照 | yes | no | `{}` |
| `usageData` | object (model → `{costInCents,amount}`) | **按会话的成本/用量** | yes(常为 `{}`) | no | `{ "claude-3.5-sonnet": { "costInCents":611, "amount":80 } }` |
| `tokenCount` | int | 会话 token 总数 | yes (9/64) | **NO**(改用按 bubble) | `9693` |
| `unifiedMode` | string | `"agent"` / `"chat"` / `"edit"` | yes | no | `"agent"` |
| `forceMode` | string | 强制子模式 | yes | no | `"edit"` |
| `isAgentic` | bool | Agent(多工具)vs 普通聊天 | yes | no | `true` |
| `capabilities` | array | 已启用的能力描述符 | yes | no | `[]` |
| `latestChatGenerationUUID` | string | 最后一次生成 id | yes | no | `"<uuid>"` |
| `tabs`, `selectedTabIndex` | array / int | 多标签 composer UI | yes | no | — |
| `newlyCreatedFiles`, `newlyCreatedFolders` | array | 本会话创建的 FS 对象 | yes | no | `[]` |
| `gitGraphFileSuggestions` | array | Git 建议 | yes | no | `[]` |
| `userResponsesToSuggestedCodeBlocks` | array | 对建议的接受/拒绝 | yes | no | `[]` |
| `allAttachedFileCodeChunksUris` | array | 附加代码块的 URI | yes | no | `[]` |
| `codebaseSearchSettings` | object | 搜索配置 | yes | no | `{}` |
| `hasLoaded`, `hasChangedContext`, `isFileListExpanded`, `isReadingLongFile` | bool | UI/加载标志 | yes | no | `false` |

\* `createdAt`/`lastUpdatedAt` 实践中是必需的,但 Swift 适配器
防御式地推导 `createdAt`:`composerData.createdAt` → 第一个可见
bubble 的 `timingInfo.clientStartTime` → `lastUpdatedAt` → `0`
(`CursorAdapter.swift:64-67`)。时间戳通过
`isoFromMilliseconds = isoFromSeconds(ms / 1000.0)` 转换
(`GeminiCliAdapter.swift:49-51`)。TS 适配器朴素地执行
`new Date(createdAt).toISOString()`(`cursor.ts:136`)。

**`latestConversationSummary` —— 版本漂移 BUG(REAL 与适配器冲突)。**
实时验证的内部键:外层 = `[summary, lastBubbleId]`;内层
`summary` 对象 = `[summary, truncationLastBubbleIdInclusive,
clientShouldStartSendingFromInclusiveBubbleId, previousConversationSummaryBubbleId,
includesToolResults]`。

```json
// FIXTURE (what the adapter expects): summary is a STRING
"latestConversationSummary": { "summary": "Fix the login bug" }

// LIVE STORE (modern Cursor): summary is a nested OBJECT
"latestConversationSummary": {
  "summary": {
    "summary": "<text>",
    "truncationLastBubbleIdInclusive": "<bid>",
    "clientShouldStartSendingFromInclusiveBubbleId": "<bid>",
    "previousConversationSummaryBubbleId": "<bid>",
    "includesToolResults": true
  },
  "lastBubbleId": "<bid>"
}
```
两个适配器都读取 `latestConversationSummary.summary` 并期望它是 String:
- Swift `CursorAdapter.swift:69-71` → `JSONLAdapterSupport.string(...)`,即
  `value as? String`(`CodexAdapter.swift:97-99`)→ **当值为 dict 时返回 `nil`** →
  `summary` 被丢弃。
- TS `cursor.ts:147` → `data.latestConversationSummary?.summary?.slice(0,200)` →
  对对象执行 `.slice` → `undefined`。

**在所有 6 个带摘要的实时 composer 中,`summary.summary` 都是 OBJECT
(0 个字符串)。** 现代 Cursor 摘要**从未**被当前适配器摄入。
字符串形式只出现在固件中。

**`context` 形态**(每个子数组都有一个并行的 `mentions.*` 对象)。Engram
(仅 TS)从 `context.folderSelections[0].uri.fsPath` 推断 cwd,否则用
`dirname(context.fileSelections[0].uri.fsPath)`:
```json
{
  "notepads": [], "composers": [], "quotes": [], "selectedCommits": [],
  "selectedPullRequests": [], "selectedImages": [], "folderSelections": [],
  "fileSelections": [], "selections": [], "terminalSelections": [],
  "selectedDocs": [], "externalLinks": [], "cursorRules": [],
  "mentions": {
    "gitDiff": [], "gitDiffFromBranchToMain": [], "usesCodebase": [],
    "useWeb": [], "useLinterErrors": [], "useDiffReview": [],
    "useContextPicking": [], "useRememberThis": [], "diffHistory": [],
    "folderSelections": {}, "fileSelections": {}, "cursorRules": {}
  }
}
```
实时存在情况:`folderSelections` 非空 **0/64**;`fileSelections` 非空
**8/64**。`fileSelections[i]` 携带键 `uri`(`{$mid, fsPath, external,
path, scheme}`)和 `isCurrentFile`。

**`codeBlockData[fileURI][i]`**(CodeBlock,`_v:2`):`uri`(对象)、`version`
(int)、`content`(string)、`languageId`(string)、`status`
(`accepted`/`completed`/`rejected`)、`isNoOp`(bool)、
`codeBlockDisplayPreference`(string)、`bubbleId`(string,所属 assistant
bubble)、`codeBlockIdx`(int)、`diffId`(string → `codeBlockDiff:<diffId>`)。

---

## 6. 消息与内容 schema

### 6.0 `fullConversationHeadersOnly[]`(有序 bubble 清单,modern 格式)

存在于 `composerData` 内部。一个指向分离 `bubbleId:`
行的**有序**列表 —— composer 内部 bubble 的权威**结构/插入**顺序。
注意:这并非墙钟时间顺序;此存储中根本不存在可靠的按消息时间戳
(社区逆向工程将日期过滤标注为 "⚠️ Limited - no reliable timestamps")
([source](https://github.com/vltansky/cursor-chat-history-mcp/blob/main/docs/research.md))。

| 字段 | 类型 | 含义 | 示例 |
|---|---|---|---|
| `bubbleId` | string (uuid) | 本地 bubble id(关联到 `bubbleId:<cid>:<bid>`) | `"e78092a4-…"` |
| `type` | int | `1`=user,`2`=assistant | `1` |
| `serverBubbleId` | string (uuid) | 服务端 bubble id(仅 assistant) | `"550179b1-…"` |

```json
[
  { "bubbleId": "e78092a4-…", "type": 1 },
  { "bubbleId": "088216a7-…", "type": 2, "serverBubbleId": "550179b1-…" }
]
```

### 6.1 `bubbleId:<composerId>:<bubbleId>` —— 消息记录

最丰富的记录(user bubble 约 75 个字段,assistant 约 90 个)。**角色
判别:`type` 1 = user,2 = assistant** —— 没有 system 或 tool 角色(工具
I/O 嵌套在 assistant bubble 内部)。Engram 只提取 `type`、`text`
(回退 `rawText`)、`timingInfo.clientStartTime`,以及(assistant)`tokenCount`
(`CursorAdapter.swift:221-263`)。

**6.1a 核心 / 共享字段(两种类型):**

| 字段 | 类型 | 含义 | 出现 | 是否消费 | 示例 |
|---|---|---|---|---|---|
| `_v` | int | Bubble schema 版本 | 全部可解析(`2`×515) | no | `2` |
| `bubbleId` | string (uuid) | 消息 id | all | no(仅在键中) | `"02fcf474-…"` |
| `type` | int | `1`=user,`2`=assistant;否则跳过 | all | **yes(角色)** | 实时:`{1:71, 2:444}` |
| `text` | string | 渲染后的消息文本 → Engram `content` | partial | **yes(主)** | `<redacted>` |
| `rawText` | string | 原始 markdown 源 → 回退内容 | rare | **yes(回退)** | `<redacted>` |
| `richText` | string | 消息的 Lexical JSON | most | no | — |
| `timingInfo` | object | 消息计时(子对象) | 71/515 bubbles,**全为 assistant(type 2);0 user** | **yes(时间戳)** | 见下文 |
| `tokenCount` | object | `{inputTokens, outputTokens}` | all | **yes(assistant 用量)** | `{"inputTokens":0,"outputTokens":0}` |
| `tokenCountUpUntilHere` | int | 到此轮次的累计 token 数 | some | no | `7309` |
| `tokenDetailsUpUntilHere` | array | `[{relativeWorkspacePath, count, lineCount}]` | some | no | `[]` |
| `context` / `contextPieces` | object/array | 按 bubble 附加的上下文 | most | no | — |
| `checkpointId` | string | → `checkpointId:` FS 快照 | some | no | `<uuid>` |
| `cursorRules` | array | 已应用的活跃 `.cursorrules` | most | no | `[]` |
| `supportedTools` | array | 本轮 agent 可用的工具 | some | no | `array[18]` |
| `attachedCodeChunks`, `attachedFileCodeChunksUris`, `codebaseContextChunks` | array | 附加的代码上下文 | most | no | `[]` |
| `attachedFolders`, `attachedFoldersListDirResults`, `attachedFoldersNew` | array | 文件夹上下文 + `list_dir` 结果 | most | no | `[]` |
| `gitDiffs`, `diffHistories`, `diffsSinceLastApply`, `diffsForCompressingFiles`, `fileDiffTrajectories` | array | 本轮的 diff 状态 | most | no | `[]` |
| `humanChanges`, `attachedHumanChanges` | array | 窗口内用户的手动编辑 | most | no | `[]` |
| `deletedFiles`, `recentlyViewedFiles`, `recentLocationsHistory`, `relevantFiles`, `currentFileLocationData` | array/obj | 编辑器/文件活动上下文 | mostly | no | — |
| `lints`, `multiFileLinterErrors`, `approximateLintErrors` | array | Linter 反馈 | most | no | `[]` |
| `consoleLogs`, `interpreterResults`, `toolResults` | array | 捕获的执行输出 | most | no | `[]` |
| `suggestedCodeBlocks`, `assistantSuggestedDiffs`, `userResponsesToSuggestedCodeBlocks` | array | 建议编辑 + 接受/拒绝 | most | no | `[]` |
| `images` | array | 粘贴的图片 | most | no | `[]` |
| `docsReferences`, `webReferences`, `externalLinks`, `aiWebSearchResults` | array | 文档/网页接地 | some | no | `[]` |
| `notepads`, `pullRequests`, `commits`, `knowledgeItems`, `summarizedComposers` | array | 更多上下文面 | most | no | `[]` |
| `capabilities`, `capabilitiesRan`, `capabilityStatuses`, `capabilityContexts` | array/obj | 能力可用性 + 运行状态 | most | no | — |
| `existedPreviousTerminalCommand`, `existedSubsequentTerminalCommand` | bool | 终端上下文标志 | some | no | `false` |
| `editTrailContexts` | array | 编辑轨迹上下文 | some | no | `[]` |
| `unifiedMode` | string | 本轮的模式 | most | no | `"agent"` |
| `isAgentic` | bool | 属于 agent 运行 | all | no | `true` |

**6.1b 仅 assistant(type 2)字段:**

| 字段 | 类型 | 含义 | 出现 | 示例 |
|---|---|---|---|---|
| `serverBubbleId` | string (uuid) | 服务端 bubble id | 244/444 | `<uuid>` |
| `usageUuid` | string (uuid) | 服务端用量/计费记录 id | 244/444 | `<uuid>` |
| `requestId` | string | 生成请求 id | 16/444 | `null`/`<uuid>` |
| `timingInfo` | object | 墙钟计时;`clientStartTime` → Engram `timestamp` | 71/444 | 见下文 |
| `toolFormerData` | object | **工具调用 + 结果**(§7) | 278/444 | 见 §7 |
| `capabilityType` | int | 能力种类(观察到全为 `15`) | 196/444 | `15` |
| `isThought` | bool | 推理/思考块标志。**出现于 196/444,但其值在全部上都是 `false` —— 实时数据中 0 个 bubble 的 `isThought:true`。** 这 196 个有该字段的恰好就是 `capabilityType:15` 的 agent 迭代 bubble。 | 出现 196/444,值为 `true` 0/444 | `false` |
| `allThinkingBlocks` | array | 本轮的推理块(此存储中为空) | all | `[]` |
| `isCapabilityIteration` | bool | 中间 agent 步骤 | 95/444 | `true` |
| `isChat` | bool | 普通聊天(非 agent)轮次 | 71/444 | `true` |
| `codeBlocks` | array | 发出的代码块(§6.1c) | most | 见下文 |
| `intermediateChunks` | array | 流式块 | 74/444 | — |
| `cachedConversationSummary`, `conversationSummary` | object | 附加到该轮的滚动摘要 | some | `{summary, lastBubbleId}` |
| `errorDetails` | object | 失败时的 `{generationUUID, message}` | 4/444 | `{"generationUUID":"<uuid>","message":"Premature close"}` |
| `afterCheckpointId` | string | 应用编辑后的 FS 检查点 | 115/444 | `<uuid>` |
| `fileLinks`, `symbolLinks` | array | 输出中的文件/符号引用 | some | `[]` |
| `isRefunded` | bool | 生成已退款(计费) | 220/444 | `false` |
| `mcpDescriptors` | array | 作用域内的 MCP 服务器/工具描述符 | 16/444 | `[]` |

**6.1c `codeBlocks[i]`(assistant 发出的代码):** `_v`(int)、`uri`(对象 ——
`scheme,path,_fsPath,_formatted,…`)、`version`(int)、`codeBlockIdx`(int)、
`content`(string)、`languageId`(string)、`unregistered`(bool)。

**`timingInfo`**(全为 epoch ms):
```json
{ "clientStartTime": 1744430797410, "clientRpcSendTime": 1744430797434,
  "clientSettleTime": 1744430839587, "clientEndTime": 1744430839587 }
```

**可见性规则(两个适配器)。** 一个 bubble 只有在 `type ∈ {1,2}`
且 `(text || rawText).trim()` 非空时才会发出(`CursorAdapter.swift:221-240`、
`cursor.ts:123-131,207-211`)。仅含工具的 assistant bubble(`text` 为空
但有 `toolFormerData` 负载)以及 `text` 为空的思考 bubble 会从计数和
transcript 中**完全丢弃**。

**示例(已匿名的分离 user bubble):**
```json
{
  "_v": 2,
  "type": 1,
  "bubbleId": "02fcf474-adc1-42b7-8933-c3904ebfc5d8",
  "text": "<redacted user message>",
  "richText": "<redacted lexical json>",
  "timingInfo": { "clientStartTime": 1744430797410, "clientRpcSendTime": 0, "clientSettleTime": 0, "clientEndTime": 0 },
  "tokenCount": { "inputTokens": 0, "outputTokens": 0 },
  "context": { "fileSelections": [], "folderSelections": [], "terminalFiles": [] },
  "checkpointId": "<uuid>",
  "supportedTools": [ /* 18 entries */ ],
  "toolResults": [], "lints": [], "gitDiffs": [], "images": []
}
```

---

## 7. 工具调用与结果 —— `toolFormerData`(嵌套在 assistant bubble 中)

Cursor 把**工具调用 AND 其结果存在同一个对象中**,位于发起它的
bubble 内部 —— 没有单独的 "tool result" 记录/角色。它
**通常位于 assistant bubble 上,但实时数据中 291 个负载里有 13 个位于 USER
(type-1)bubble 上**(278 assistant + 13 user),所以 "嵌套在 assistant
bubble 中" 并非严格成立。`toolCallId` 是连接键(也用于
`messageRequestContext`)。实时验证的键(11 个):
`[tool, toolCallId, status, rawArgs, name, additionalData, params, result,
userDecision, toolIndex, modelCallId]`。

| 字段 | 类型 | 含义 | 示例 |
|---|---|---|---|
| `tool` | int | 工具枚举 id | `6` (list_dir)、`5` (read_file)、`7` (edit_file)、`15` (run_terminal_cmd)、`9` (codebase_search)、`18` (web_search)、`19` (MCP) |
| `name` | string | 工具名 | `"edit_file"`、`"read_file"`、`"run_terminal_cmd"`、`"web_search"`、`"mcp_mcp-safeline_get_attack_events"` |
| `toolCallId` | string | 调用/结果对的**连接键** | `"<str 40>"` |
| `status` | string | `"completed"` / `"cancelled"`(从未执行时为 `null`) | `"completed"` |
| `params` | string (JSON) | 解析后的工具参数 | `"{\"directoryPath\":\".\"}"` |
| `rawArgs` | string | 模型给出的原始参数串 | `"<str 32>"` |
| `result` | string (JSON/text) | 与调用并置的**工具输出** | `"<str 626>"` |
| `additionalData` | object | 工具特定的额外数据 | `{}` |
| `userDecision` | string | 用户对工具动作的接受/拒绝 | 实时 171 个 | `"accepted"` |
| `toolIndex` | int | 本轮内的工具索引 | 实时 5 个 | `0` |
| `modelCallId` | string | 模型侧调用 id | 实时 5 个 | `"<id>"` |

**实时 `name` 分布**(291 个 toolFormerData 负载 = 278 assistant + 13 user):`edit_file` 115、
`(blank — MCP/unnamed)` 95、`run_terminal_cmd` 49、`read_file` 16、`list_dir` 7、
`mcp_mcp-safeline_get_attack_events` 3、`web_search` 2、
`mcp_mcp-safeline_create_blacklist_rule` 2、`codebase_search` 2。

```json
{
  "tool": 6, "toolCallId": "<id40>", "status": "completed",
  "name": "list_dir", "rawArgs": "<str 32>", "params": "{\"directoryPath\":\".\"}",
  "additionalData": {}, "result": "<str 626>"
}
```

**Engram 不解析 `toolFormerData`。** `toolCalls` 始终为 `nil`
(`CursorAdapter.swift:149`);`toolMessageCount` 硬编码为 `0`
(`CursorAdapter.swift:91`、`cursor.ts:145`)。仅含工具的 assistant 轮次
从 transcript 和计数中消失。

---

## 8. 推理 / 思考

**此存储中基本不存在推理。** `isThought` 标志
**出现于 196/444 个 assistant bubble,但其值在每一个上都是 `false`
—— 实时数据中 0 个 bubble 的 `isThought:true`**(这 196 个恰好就是
`capabilityType:15` 的 agent 迭代 bubble,该标志在那里被发出=false)。
`allThinkingBlocks` 在所有 444 个 assistant bubble 中都是**空 `[]`**。所以
思考标志和结构化推理数组在这里实际上都未被使用(较新的 Cursor 版本可能会
填充它们)。`intermediateChunks` 保存流式片段(74/444)。无论如何 Engram
都不消费其中任何内容;`text` 为空的思考 bubble 被丢弃,所以它们从不出现
在计数或 transcript 中。

---

## 9. Token 用量与成本

存在三个用量面;Engram 只消费按消息的那个(仅 Swift)。

| 面 | 位置 | 类型 | 是否消费 |
|---|---|---|---|
| 按消息 token | `bubble.tokenCount = {inputTokens, outputTokens}` | object | **仅 Swift** → message `usage` |
| 累计 token | `bubble.tokenCountUpUntilHere` (int) + `tokenDetailsUpUntilHere` ([{relativeWorkspacePath, count, lineCount}]) | int/array | no |
| 按会话成本 | `composerData.usageData = {model → {costInCents, amount}}` + `composerData.tokenCount` (int) | object/int | no |

- **Swift** 为 assistant 消息把按 bubble 的 `tokenCount → TokenUsage` 映射
  (`CursorAdapter.swift:150-152, 253-263`),其中 `cacheReadTokens=0`、
  `cacheCreationTokens=0`,并有一个**丢弃零 token 用量**的防护
  (`inputTokens>0 || outputTokens>0`)。实时样本 bubble 常为
  `{"inputTokens":0,"outputTokens":0}` → 不发出用量。
- **TS 完全不发出用量** —— 一处 Swift↔TS 行为分歧。
  对等固件恰好绕过了它,因为它的 assistant bubble 没有 `tokenCount`。
- **`composerData.usageData`** 在实时数据中常为 `{}`(无成本记录),并被两个
  适配器连同 `composerData.tokenCount` 一起**忽略**。

---

## 10. 子 agent / 父子 / 派发

**对 Cursor 不适用(适配器层面)。** Cursor 适配器把
`parentSessionId`、`suggestedParentId`、`agentRole`、`originator` 和 `origin`
全部设为 `nil`(`CursorAdapter.swift:97-104`)。Cursor 没有 Gemini 风格的
`.engram.json` sidecar,也没有基于路径的子 agent 关联。Cursor 自身的内部
扇出信号存在但不被消费:`composer.composerHeaders` 携带
`numSubComposers` / `isBestOfNSubcomposer`,`agentKv:blob:*` 保存原始 agent
transcript —— 都不被读取。任何父/子关联都会由 Engram 的启发式管线
(Layer 2)在下游应用,而非由本适配器处理。

---

## 11. 摘要 / 压缩

Cursor 在会话级维护一个滚动的 AI 生成摘要
(`composerData.latestConversationSummary`),以及按轮次的
(`bubble.cachedConversationSummary` / `conversationSummary`)。会话摘要
编码了自己的压缩边界:
`truncationLastBubbleIdInclusive`、
`clientShouldStartSendingFromInclusiveBubbleId`、
`previousConversationSummaryBubbleId` 和 `includesToolResults` —— 即 Cursor
在向模型重新发送上下文时,会截断较旧的 bubble 并用摘要替换它们。

**Engram 本想把 `latestConversationSummary.summary`(≤200 字符)摄入
`summary`,但现代嵌套对象形态使其失效** —— 见 §5 / §15
漂移 bug。实际上,摘要**从未**从实时现代存储中被摄入
(0/6 字符串);Engram 回退到第一条 user 消息作为任何预览/标题。

---

## 12. SQLite / DB 内部结构

**两张表,均为 `key`/`value` KV**(实时 DDL):
```sql
CREATE TABLE ItemTable    (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);
CREATE TABLE cursorDiskKV (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);
```
- **未声明 PRIMARY KEY**;唯一性 + upsert 通过 `key` 上的
  `UNIQUE ... ON CONFLICT REPLACE` 实现。连接通过**键前缀
  字符串匹配**(`LIKE 'composerData:%'`、`LIKE 'bubbleId:<cid>:%'`)模拟,而非 SQL
  外键。除隐式 `rowid` 外没有行排序列,两个适配器都依赖
  它来确定消息顺序(`ORDER BY rowid ASC`)。
- `value` 声明为 `BLOB` 但存储 UTF-8 JSON 文本(通过
  `JSON.parse` / `Phase4AdapterSupport.jsonObject(from:)` 解析)。
- **固件 DDL 不同**(`tests/fixtures/cursor/state.vscdb`):
  `CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value TEXT)` —— 使用
  `PRIMARY KEY` + `TEXT` 而非实时的 `UNIQUE ON CONFLICT REPLACE` +
  `BLOB`。对读取功能等价;对任何对 DDL 敏感的工具需留意。

**`ItemTable` 单例键(被 Engram 忽略):** `composer.composerHeaders`
(全局 composer 目录 —— 见下文)、`composer.composerData`(仅按 workspace
DB —— composer→folder 映射)、`composer.planMigrationToHomeDirCompleted`、
`workbench.panel.aichat.view.aichat.chatdata`、许多 `workbench.panel.*chat*` UI
标志、`chat.workspaceTransfer`。

**`composer.composerHeaders`(ItemTable)→ `{ allComposers: [Header] }`** ——
Engram 不使用的跨会话目录(它直接枚举 `composerData:%`)。
Header 字段:`composerId`、`type`(`"head"`)、`createdAt` /
`lastUpdatedAt`(ms)、`unifiedMode` / `forceMode`、`totalLinesAdded` /
`totalLinesRemoved`、`hasUnreadMessages`、`hasBlockingPendingActions`、
`hasPendingPlan`、`isArchived`、`isDraft`、`isSpec`、`isProject`、`isWorktree`、
`isBestOfNSubcomposer`、`numSubComposers`、`referencedPlans`、`trackedGitRepos`、
`workspaceIdentifier`(`{id}`)、`draftTarget`(`{type, environment}`)、
`worktreeStartedReadOnly`、`hasBeenInSidebar`。

**Workspace DB** `ItemTable['composer.composerData']` =
`{ allComposers:[{composerId,type,createdAt,unifiedMode,forceMode}],
selectedComposerId, selectedChatId, hasMigratedChatData, … }` —— 唯一的
composer→workspace-folder 映射。不被 `CursorAdapter` 抓取。

---

## 13. 辅助文件

这些 `cursorDiskKV` 命名空间和磁盘文件携带了丰富的 agent 状态,
Engram 完全忽略它们。

**`checkpointId:<cid>:<id>`**(369 行)—— 用于回滚的文件系统快照,
由 `bubble.checkpointId` / `afterCheckpointId` 引用:
```json
{ "files": [], "nonExistentFiles": [], "newlyCreatedFolders": [],
  "activeInlineDiffs": [], "inlineDiffNewlyCreatedResources": { "files": [], "folders": [] } }
```

**`codeBlockDiff:<id>:<id>`**(174 行)—— 相对基础 v0 的行范围 diff,由
`codeBlockData[…].diffId` 引用:
```json
{ "originalModelDiffWrtV0": [],
  "newModelDiffWrtV0": [ { "original": { "startLineNumber":778, "endLineNumberExclusive":821 }, "modified": ["<str 51>"] } ] }
```

**`agentKv:blob:<sha256>`**(46 行)—— 内容寻址的原始 provider 消息
(发给模型的字面 `{role,content}`;不同于作为 UI/渲染层的 bubble)。
社区逆向工程将 agentKv 描述为请求/溯源轴,承载 assistant 文本、工具流量和
推理块,值内部以 `providerOptions.cursor.requestId` 作键
([source](https://vibe-replay.com/blog/cursor-local-storage/))。
SHA-256 键**不**与 composerId 连接,因此仅凭键无法建立
blob→composer 映射;任何连接都得经过 blob 值内部的 `requestId` /
溯源字段(可行但没有任何公开来源端到端地演示过):
```json
{ "role": "user", "content": "<user_info>\nOS Version: …\nWorkspace Path: /…/.cursor\n…</user_info>" }
```

**`messageRequestContext:<cid>:<bid>`**(24 行)—— 绑定到某个 bubble 的
按请求上下文:`cursorRules`(array)、`attachedFoldersListDirResults`(array)、
`summarizedComposers`(array)、`terminalFiles`(array)。

**`composerVirtualRowHeights:<cid>:_recentIds`**(1 行)—— UI 虚拟列表渲染
缓存。

**磁盘辅助文件(全局 DB 之外):**
- `workspaceStorage/<hash>/state.vscdb` + `.backup` —— 按 workspace 的 UI 状态 /
  指针索引(composer→folder 映射;不被抓取)。
- `workspaceStorage/<hash>/workspace.json` —— hash→folder URI。
- `workspaceStorage/<hash>/anysphere.cursor-retrieval/` —— 代码库索引扩展状态。
- `History/` —— VS Code 按文件的编辑历史(与聊天无关)。

---

## 14. Engram 映射

**适配器注册。** 源枚举 `case cursor`
(`macos/Shared/EngramCore/Adapters/SessionAdapter.swift:17`);在默认工厂的
`SessionAdapterFactory.swift:23` 和 `:68` 处构造,以及在
`macos/Engram/Core/MessageParser.swift:126`(17 个默认适配器之一)。
TS 类 `CursorAdapter`(`src/adapters/cursor.ts:32`)。

### 会话级(`NormalizedSessionInfo`)

| Engram 字段 | Cursor 来源 | Swift file:line | TS file:line | 备注 / 差异 |
|---|---|---|---|---|
| `id` | `composerData.composerId`(回退:locator composerId) | `CursorAdapter.swift:81` | `cursor.ts:134` | UUID |
| `source` | 常量 `.cursor` / `'cursor'` | `:82` | `:135` | — |
| `startTime` | `createdAt` → 否则第一个可见 bubble 的 `timingInfo.clientStartTime` → 否则 `lastUpdatedAt` → 否则 0 | `:64-67, 83` | `:136` | **Swift 有更丰富的回退链;TS 只用 `createdAt`。** |
| `endTime` | `lastUpdatedAt`(仅当 ≠ createdAt,否则 `nil`) | `:68, 84` | `:137-140` | — |
| `cwd` | **Swift:硬编码 `""`**;TS:`inferCwd` = 第一个 folderSelection.fsPath,否则 `dirname(第一个 fileSelection.fsPath)`,否则 `""` | `:85` | `:141, 236-242` | **差异:Swift 从不推断 cwd。** 实时:folderSelections 0/64,fileSelections 8/64,所以 TS 为那 8 个发出目录;Swift 对全部发出 `""`。 |
| `project` | 始终 `nil` | `:86` | (TS 形态中无) | composer 不绑定到 workspace |
| `model` | 始终 `nil` | `:87` | (缺失) | 不提取 |
| `messageCount` | userCount + assistantCount(可见 bubble) | `:88` | `:142` | — |
| `userMessageCount` | 可见 `type==1` 的计数 | `:61, 89` | `:129, 143` | — |
| `assistantMessageCount` | 可见 `type==2` 的计数 | `:62, 90` | `:130, 144` | — |
| `toolMessageCount` | **硬编码 0** | `:91` | `:145` | `toolFormerData` 不计数 |
| `systemMessageCount` | **硬编码 0** | `:92` | `:146` | Cursor 没有 system bubble |
| `summary` | `latestConversationSummary.summary` 截断为 200 字符 | `:69-71, 93` | `:147` | **现代存储:嵌套对象 → 得到 `nil`(§5 bug)** |
| `filePath` | 虚拟 locator `<db>?composer=<id>` | `:94` | `:148` | — |
| `sizeBytes` | 按会话 = `len(composerValue)` + Σ `len(bubble rows)` | `:72-77, 95` | `:99-119, 149` | 不是整个 28 MB 文件(对等注释) |
| `indexedAt` | `nil` | `:96` | (缺失) | 下游设置 |
| `agentRole`/`originator`/`origin`/`parentSessionId`/`suggestedParentId`/`tier`/`qualityScore`/`summaryMessageCount` | 全部 `nil` | `:97-104` | (缺失) | 由下游管线设置 |

### 按消息(`NormalizedMessage`)

| Engram 字段 | Cursor 来源 | Swift file:line | TS file:line |
|---|---|---|---|
| `role` | `type` 1→user,2→assistant | `:224-232` | `:207-208` |
| `content` | `text` ‖ `rawText`(非空) | `:234-235` | `:210` |
| `timestamp` | `timingInfo.clientStartTime`(ms→ISO) | `:141-144` | `:217, 221` |
| `usage` | 仅 assistant:来自 `tokenCount` 的 `{inputTokens,outputTokens}`(cache=0;零用量被丢弃) | `:150-152, 253-263` | **TS 中不映射** |
| `toolCalls` | 始终 `nil` | `:149` | (缺失) |

**发现 / 枚举管线:**
1. `detect()` —— 当且仅当 `globalStorage/state.vscdb` 存在时为 true
   (`CursorAdapter.swift:16-18`、`cursor.ts:50-57`)。
2. `listSessionLocators()`(Swift)/ `listSessionFiles()`(TS)—— 以只读方式打开,
   `SELECT key, value FROM cursorDiskKV WHERE key LIKE 'composerData:%'`,解析
   每一项,取 `composerId`,跳过空的,发出虚拟 locator
   `<dbPath>?composer=<composerId>`(`CursorAdapter.swift:20-36`、
   `cursor.ts:59-84`)。
3. `parseSessionInfo(locator)` —— 在 `?composer=` 处分割(`parseVirtualLocator`,
   `CursorAdapter.swift:175-181`;`parsePath`,`cursor.ts:244-254`),取
   `composerData:<id>`,通过两格式回退解析 bubble,统计可见的
   user/assistant bubble,计算时间戳 + 按会话大小。
4. `streamMessages(locator, options)` —— 相同的取数 + 回退,把每个可见
   bubble 映射为 `NormalizedMessage`,应用 offset/limit 窗口。
5. `isAccessible(locator)` —— 廉价探测
   `SELECT 1 FROM cursorDiskKV WHERE key='composerData:<id>' LIMIT 1`,带缓存
   (`CursorAdapter.swift:163-173`、`cursor.ts:256-276`)。

**被 Engram 完全丢弃:** `name`(聊天标题)、现代
`latestConversationSummary.summary` 对象、`toolFormerData`(所有工具
调用/结果)、`codeBlocks`/`codeBlockData`/`codeBlockDiff`(所有编辑/diff)、
`isThought`/`allThinkingBlocks`(推理)、`usageData`/`tokenCountUpUntilHere`
(成本/累计 token)、`checkpointId`、`agentKv`、`messageRequestContext`、
`serverBubbleId`/`usageUuid`、`errorDetails`、`model`、子 composer/agent
结构、整个 `ItemTable`,以及 `workspaceStorage/` 的按 workspace DB。

---

## 15. 谱系、陷阱、版本漂移与边界情况

### 与同类工具的共享格式谱系

Cursor 是 **VS Code 的分叉**,因此可能会期望它与
VS Code / Copilot / Cline 家族共享存储。**它并不 —— Cursor 是谱系上的异类。**
在六个 VS Code 家族适配器中,**只有 `CursorAdapter` 读取
`state.vscdb`/`cursorDiskKV`**:

| 工具 | Engram 适配器 | 存储技术与根路径 | 与 Cursor 共享? |
|---|---|---|---|
| **Cursor** | `CursorAdapter` | SQLite `globalStorage/state.vscdb` → `cursorDiskKV`(`composerData:` / `bubbleId:`) | —(基线) |
| **VS Code**(Copilot Chat) | `VsCodeAdapter` | 抓取 `Code/User/workspaceStorage/<hash>/`(vscdb 家族,按 workspace) | **容器家族是(`.vscdb`),schema 否** |
| **GitHub Copilot CLI** | `CopilotAdapter` | `~/.copilot/session-state/<id>/events.jsonl` + `workspace.yaml` | **否** —— JSONL |
| **Cline** | `ClineAdapter` | `~/.cline/data/tasks/<id>/ui_messages.json` | **否** —— 按任务 JSON |
| **Windsurf**(Codeium Cascade) | `WindsurfAdapter` | `.codeium/windsurf/…` → `.engram/cache/windsurf/<cascadeId>.jsonl` | **否** —— Cascade JSONL 缓存 |
| **Antigravity**(Gemini) | `AntigravityAdapter` | `.gemini/antigravity/…` / `.gemini/antigravity-cli/brain` | **否** —— Cascade/CLI JSONL |

要点:
- 共享的产物是从 VS Code 继承的 **SQLite `state.vscdb` 容器**,但 Cursor
  发明了自己的表(`cursorDiskKV`)和
  `composerData:`/`bubbleId:` 键约定。VS Code / Copilot Chat 反而把聊天保存在
  标准的 `ItemTable`/`workspaceStorage` 中。"VS Code 分叉"的
  关系**只在容器层面,而非 schema 层面** —— 为 VS Code 聊天存储编写的
  适配器无法读取 Cursor 的,反之亦然。
- 这与 Gemini CLI ↔ Qwen ↔ iFlow 家族(真正的 JSONL schema
  复用)形成对比。Cursor 名义上的兄弟各自分化到不同的存储技术,所以
  Engram 需要为这一个编辑器家族提供六个独立适配器。

### 陷阱、版本漂移、边界情况

1. **消息顺序依赖 `rowid`,而非头部清单。** Engram 按 SQLite
   `rowid ASC` 对分离 bubble 排序(`CursorAdapter.swift:206`、
   `cursor.ts:192`),而非按 `fullConversationHeadersOnly[]`。该清单是
   composer 内部 bubble 的权威**结构/插入**顺序(并非墙钟顺序 —— 此存储
   "no reliable timestamps");社区指南仅在按近期性对整条**会话**排序时使用
   `ROWID`,因为 UUID 和时间戳都不是时间序的。没有公开来源确认 `rowid` 对
   单条 **bubble** 是安全顺序,所以为重新插入 / 编辑过的 bubble 依赖它
   (而非清单)是一个可行但未验证的风险
   ([source](https://github.com/vltansky/cursor-chat-history-mcp/blob/main/docs/research.md))。
2. **摘要嵌套漂移(高影响)。** 现代存储把 `summary` 嵌套为
   对象(`{summary, truncationLastBubbleIdInclusive, …}`);两个适配器期望
   字符串 → 对所有实时会话静默丢弃摘要(**0/6 字符串**)。
   固件仍编码旧的字符串形式,所以对象形式**没有回归
   防护**。
3. **标题(`name`)被忽略**,尽管它存在(8/64)且是摘要被丢弃后
   唯一可靠的标题信号。
4. **格式三分 + NULL。** 实时:4 内联 / 4 仅头部 / 51 空 /
   5 NULL(共 64)。**约 80% 是空草稿**,会发出 0 消息会话;
   适配器不过滤它们(依赖下游 `tier=skip`/`lite`)。
5. **shipped Swift 产品中 cwd 为 `""`**(仅 TS 推断)。即便是 TS
   也会对大多数情况发出 `""`:实时 folderSelections 为 0/64;只有那 8 个
   带 fileSelections 的 composer 才会得到 `dirname`。
6. **工具轮次被丢弃。** `toolFormerData` 携带真实的工具调用
   (摘要中 `includesToolResults:true`),但 `toolMessageCount`/`toolCalls`
   被清零;仅含工具的 assistant 轮次(`text` 为空)从 transcript 和
   计数中消失。
7. **稀疏时间戳。** 只有 assistant bubble 携带 `timingInfo`(恰好
   71/444,全为 type 2);user bubble 完全没有(0),所以 Engram 为它们发出
   `timestamp:nil`。Swift 为会话 `startTime` 回退到第一个 bubble 的时间戳再到 `createdAt`,
   但没有 `timingInfo` 的单条消息会得到 `nil`
   时间戳。
8. **Token 用量对等缺口。** Swift 从 `tokenCount` 发出按消息的 assistant 用量;
   TS 不发出 —— 一处未测试的 Swift↔TS 分歧。对等
   固件绕过了它(其 bubble 缺少 `tokenCount`)。实时 bubble 常为
   `{0,0}` → 无论如何都不发出用量(零用量防护)。
9. **NULL `composerData` 值(5/64)** 和格式错误的 JSON 被静默跳过
   (防护见 `CursorAdapter.swift:27`、TS 中的 `compactMap`)。
10. **Locator 耦合。** Locator 为 `<dbPath>?composer=<id>`;解析在
    字面 `?composer=` 处分割(`CursorAdapter.swift:175-181`、`cursor.ts:248`)。一个
    包含该子串的 composerId 会破坏解析(未观察到,
    未验证)。
11. **推理实际上不存在。** `allThinkingBlocks` 在所有 444 个
    assistant bubble 中都是 `[]`,而 `isThought` **出现于 196 个但每一个上
    都是 `false`(0 个为 `true`)** —— 本文档此前曾把"字段出现于 196"
    与"值为 true 于 196"混为一谈。结构化推理块 schema 无法
    从此存储中确认;较新的 Cursor 版本 DO 填充推理 —— 社区逆向工程记录了
    bubble 负载上的 `thinkingDurationMs`(样本值 21322)以及 agentKv 消息对象
    内部的推理块,所以为空的实时存储是一个版本快照
    ([source](https://vibe-replay.com/blog/cursor-local-storage/))。
12. **工具 / 能力枚举未映射。** `capabilityType` 在实时数据中始终为 `15`;
    观察到的 `tool` 整数为 `{1,5,6,7,9,15,18,19}` —— 完整名称映射
    无法从单个存储推导。

### 待解问题(web-checked 2026-06-21)

- **现代嵌套摘要形式。** Confirmed (official):对象嵌套是真实的产品行为,
  而非文档臆造。社区逆向工程类型把 `latestConversationSummary` 声明为
  `{ summary: { summary: string } }`,并在 `latestConversationSummary.summary.summary`
  处读取文本;读取 `latestConversationSummary.summary` 并期望 String 的适配器
  会得到对象并丢弃它 —— 恰好是实时发现。Cursor 把这种嵌套视为 bug 还是
  有意为之,没有任何来源说明(格式未文档化)
  ([source](https://github.com/vltansky/cursor-chat-history-mcp/blob/main/src/database/types.ts))。
- **`composerData.name` 作为标题。** Confirmed (official):在现代格式中
  `name` 就是会话标题(vltansky 类型:`name?: string; // Conversation title
  (Modern format only)`,以 `title?` 暴露;vibe-replay 把 `"name"` 列为聊天
  标题)。事实前提已验证;Engram 是否应该摄入它是 Engram 内部的设计决策
  ([source](https://github.com/vltansky/cursor-chat-history-mcp/blob/main/src/database/types.ts), [source](https://vibe-replay.com/blog/cursor-local-storage/))。
- **Swift `cwd=""` vs TS 推断。** (Engram-internal design - not
  web-verifiable.) 不过格式前提已验证:`context.fileSelections[].uri.fsPath/path`
  存在于 composer 和 bubble 上,所以从这些字段推断 cwd 在技术上可行 ——
  与 TS 做法一致
  ([source](https://github.com/vltansky/cursor-chat-history-mcp/blob/main/src/database/types.ts))。
- **会话级成本的预期来源。** Confirmed (official):token/用量经常缺失或为零
  (vibe-replay:"many sessions still have no usable token snapshots";codeburn
  #114:一个填充了 87k agentKv / 69k bubbleId 行的 `state.vscdb` 在 macOS 上
  仍产出 ZERO 用量)。但 NO 公开来源记录哪个字段是规范来源
  (`composerData.usageData` vs `composerData.tokenCount` vs 按 bubble 的
  `tokenCount` 求和);Cursor 没有文档化,所以规范来源仍未知
  ([source](https://vibe-replay.com/blog/cursor-local-storage/), [source](https://github.com/getagentseal/codeburn/issues/114))。
- **较旧的、作用于 workspace 的 composer 被仅读全局 DB 的适配器遗漏。**
  Confirmed (official):部分确认 —— 存在真实的仅遗留缺口,量级未知。
  现代 composer 仅在全局(内容在 `globalStorage` `cursorDiskKV`;workspace DB
  只持有元数据/指针),所以仅读全局对现代数据是安全的。但存在按 workspace
  `ItemTable` 键 `workbench.panel.aichat.view.aichat.chatdata` 下的遗留时代
  聊天,可能仅存在于 `workspaceStorage/` 中,会被遗漏
  ([source](https://github.com/S2thend/cursor-history/blob/main/CLAUDE.md), [source](https://dasarpai.com/dsblog/cursor-chat-architecture-data-flow-storage/))。
- **`agentKv:blob` → composer 映射。** Confirmed (official):agentKv blob 是
  请求/溯源作用域的原始 `{role,content}` 对象,不同于 bubble(UI/渲染)层,
  所以连接是经过值内部的 `requestId` / 溯源字段,而非 SHA-256 键 —— 与
  "仅凭键无法建立" 一致。值内部的 `requestId` 连接可行,但没有来源演示过
  完整的 blob→composer 重建
  ([source](https://vibe-replay.com/blog/cursor-local-storage/))。
- **`toolFormerData` 会出现在 user(type 1)bubble 上吗?**(web-checked
  2026-06-21: no authoritative source found。)社区来源通常在 assistant bubble
  上展示 `toolFormerData`(S2thend:"toolFormerData appears on assistant
  bubbles"),vibe-replay 说每个 `bubbleId:*` 行 CAN 携带它而不限定于
  assistant —— 二者都既不确认也不反驳实时存储中 13/291 的 user-bubble 观察;
  没有外部数据集可交叉核对。

---

## 16. 附录:真实匿名样本

### `cursorDiskKV` schema(实时)
```sql
CREATE TABLE ItemTable    (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);
CREATE TABLE cursorDiskKV (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);
```

### `composerData:<composerId>`(内联格式,顶层键)
```json
{
  "_v": 3,
  "composerId": "0066a5aa-1757-44bf-a7c4-1a3d6ee3c790",
  "name": "<chat title>",
  "text": "",
  "richText": "<lexical json>",
  "status": "completed",
  "createdAt": 1738226420089,
  "lastUpdatedAt": 1744430839587,
  "conversation": [ { "type": 1, "text": "<redacted>", "...": "..." } ],
  "context": { "folderSelections": [], "fileSelections": [ { "uri": { "fsPath": "<redacted/path>", "scheme": "file" }, "isCurrentFile": true } ], "mentions": { "...": "..." } },
  "codeBlockData": { "file:///<redacted>": [ { "_v": 2, "version": 0, "content": "<redacted>", "languageId": "json", "status": "accepted", "bubbleId": "<uuid>", "codeBlockIdx": 0, "diffId": "<uuid>" } ] },
  "originalModelLines": {},
  "usageData": {},
  "unifiedMode": "agent",
  "forceMode": "edit",
  "isAgentic": true
}
```

### `composerData.latestConversationSummary`(modern,嵌套对象 —— 漂移)
```json
{
  "summary": {
    "summary": "<redacted summary text>",
    "truncationLastBubbleIdInclusive": "<bid>",
    "clientShouldStartSendingFromInclusiveBubbleId": "<bid>",
    "previousConversationSummaryBubbleId": "<bid>",
    "includesToolResults": true
  },
  "lastBubbleId": "<bid>"
}
```

### `composerData.fullConversationHeadersOnly`(modern 清单)
```json
[
  { "bubbleId": "e78092a4-…", "type": 1 },
  { "bubbleId": "088216a7-…", "type": 2, "serverBubbleId": "550179b1-…" }
]
```

### `bubbleId:<cid>:<bid>`(user,type 1)
```json
{
  "_v": 2,
  "type": 1,
  "bubbleId": "02fcf474-adc1-42b7-8933-c3904ebfc5d8",
  "text": "<redacted user message>",
  "richText": "<redacted lexical json>",
  "timingInfo": { "clientStartTime": 1744430797410, "clientRpcSendTime": 0, "clientSettleTime": 0, "clientEndTime": 0 },
  "tokenCount": { "inputTokens": 0, "outputTokens": 0 },
  "context": { "fileSelections": [], "folderSelections": [], "terminalFiles": [] },
  "checkpointId": "<uuid>",
  "supportedTools": [ "...18 entries..." ],
  "toolResults": [], "lints": [], "gitDiffs": [], "images": []
}
```

### `bubbleId:<cid>:<bid>`(assistant,type 2,带工具调用)
```json
{
  "_v": 2,
  "type": 2,
  "bubbleId": "<uuid>",
  "serverBubbleId": "<uuid>",
  "usageUuid": "<uuid>",
  "text": "",
  "isAgentic": true,
  "isThought": false,
  "capabilityType": 15,
  "timingInfo": { "clientStartTime": 1744430797410, "clientRpcSendTime": 1744430797434, "clientSettleTime": 1744430839587, "clientEndTime": 1744430839587 },
  "tokenCount": { "inputTokens": 0, "outputTokens": 0 },
  "toolFormerData": {
    "tool": 6, "toolCallId": "<id40>", "status": "completed",
    "name": "list_dir", "rawArgs": "<str 32>", "params": "{\"directoryPath\":\".\"}",
    "additionalData": {}, "result": "<str 626>"
  },
  "codeBlocks": [], "allThinkingBlocks": [], "afterCheckpointId": "<uuid>", "isRefunded": false
}
```

### `checkpointId:<cid>:<id>`
```json
{ "files": [], "nonExistentFiles": [], "newlyCreatedFolders": [],
  "activeInlineDiffs": [], "inlineDiffNewlyCreatedResources": { "files": [], "folders": [] } }
```

### `codeBlockDiff:<id>:<id>`
```json
{ "originalModelDiffWrtV0": [],
  "newModelDiffWrtV0": [ { "original": { "startLineNumber": 778, "endLineNumberExclusive": 821 }, "modified": ["<str 51>"] } ] }
```

### `agentKv:blob:<sha256>`
```json
{ "role": "user", "content": "<user_info>\nOS Version: …\nWorkspace Path: /…/.cursor\n…</user_info>" }
```

### `messageRequestContext:<cid>:<bid>`
```json
{ "cursorRules": [], "attachedFoldersListDirResults": [], "summarizedComposers": [], "terminalFiles": [] }
```

### `ItemTable['composer.composerHeaders']`(目录头部元素)
```json
{
  "composerId": "<uuid>", "type": "head",
  "createdAt": 1778141144676, "lastUpdatedAt": 1778141200000,
  "unifiedMode": "agent", "forceMode": "edit",
  "totalLinesAdded": 0, "totalLinesRemoved": 0,
  "hasUnreadMessages": false, "isArchived": false, "isDraft": false,
  "isSpec": false, "isProject": false, "isWorktree": false, "isBestOfNSubcomposer": false,
  "numSubComposers": 0, "referencedPlans": [], "trackedGitRepos": [],
  "workspaceIdentifier": { "id": "empty-window" },
  "draftTarget": { "type": "existing", "environment": "<str>" }
}
```

### Engram 虚拟 locator
```
/Users/<user>/Library/Application Support/Cursor/User/globalStorage/state.vscdb?composer=0066a5aa-1757-44bf-a7c4-1a3d6ee3c790
```

---

## References (official sources)

Cursor 的磁盘格式 NOT 官方文档化 —— 唯一的官方导出面是 Shared Transcripts
(Teams/Enterprise)。下列框架性和字段级断言已于 2026-06-21 与社区逆向工程
交叉核对(web_access_ok=true):

- [Cursor Docs — Shared transcripts](https://cursor.com/docs/agent/chat/export) — 唯一官方导出面;磁盘格式未文档化。
- [vltansky/cursor-chat-history-mcp — src/database/types.ts](https://github.com/vltansky/cursor-chat-history-mcp/blob/main/src/database/types.ts) — ComposerData/Bubble 的 TypeScript 接口(权威社区逆向工程)。
- [vltansky/cursor-chat-history-mcp — docs/research.md](https://github.com/vltansky/cursor-chat-history-mcp/blob/main/docs/research.md) — cursorDiskKV 键模式、ROWID 排序、格式。
- [vibe-replay — What Does Cursor Store on Your Machine?](https://vibe-replay.com/blog/cursor-local-storage/) — 对 state.vscdb、agentKv、thinkingDurationMs、token 快照的深入分析。
- [dasarpai — Cursor Chat: Architecture, Data Flow & Storage](https://dasarpai.com/dsblog/cursor-chat-architecture-data-flow-storage/) — ItemTable 键、OS 路径、遗留 chatdata 键。
- [S2thend/cursor-history — CLAUDE.md](https://github.com/S2thend/cursor-history/blob/main/CLAUDE.md) — workspace 与全局 DB 切分、toolFormerData 字段。
- [getagentseal/codeburn Issue #114](https://github.com/getagentseal/codeburn/issues/114) — 在 macOS 上尽管 state.vscdb 已填充却零用量。
