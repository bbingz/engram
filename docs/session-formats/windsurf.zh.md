# Windsurf (Cascade) — 会话格式参考

> 本文档为英文权威版 windsurf.md 的中文阅读副本;若有出入以英文版为准。

Last researched: 2026-06-21 (Engram session-format research workflow)

> **姊妹工具:** Windsurf 与 **Antigravity** 共享 Swift 缓存解析器(同属
> "Cascade 家族"——两者都派生自 Codeium/Cascade)。Swift 产品已不再包含
> Cascade RPC 客户端/发现脚手架;它只读取既有的 Engram 自有 JSONL 缓存。
> TypeScript 参考适配器仍保留并记录可生产这些缓存文件的上游 RPC 路径。

---

## 1. 概览与 TL;DR

**保存内容/位置/方式。** Windsurf(Codeium Cascade)是 Engram 各来源中的**异类**:
Engram **不**解析 Windsurf 的原生磁盘存储。Windsurf 把每段对话("trajectory",轨迹)
持久化为一个位于 `~/.codeium/windsurf/cascade/<cascadeId>.pb` 的
**不透明、高熵二进制 `.pb` blob**,**只能**通过运行中的 Cascade *语言服务器*
经由本地 HTTP/Connect-RPC 端点(`exa.language_server_pb.LanguageServerService`)读取。
其底层逻辑格式**确实**是 protobuf——官方 Exafunction/codeium 仓库把该 `.pb` 描述为一份
protobuf "base index"(基础索引,约 40 MB),并伴随 `.tmp` "incremental snapshots"
(增量快照,作为 delta 合并进基础文件)
([issue #286](https://github.com/Exafunction/codeium/issues/286))。但磁盘上的字节流并非
*可直接*解码:`file(1)` 报告为 `data`,且开头字节高熵、无 protobuf 字段标签结构
(`14f4 2934 face 359b …`)——这最符合一个 protobuf 基础 + delta-merge 布局且**很可能被
压缩**(Windsurf 会对其 Connect-RPC 主体做 gzip 包裹)的情形。没有任何官方来源支持
"已加密"。无论哪种情况,Engram 都无法离线解析它;它需要运行中的语言服务器。

因此 Engram 采用**缓存优先模型**:

1. **参考/开发同步(Connect-RPC → JSONL 缓存)。** TypeScript 参考适配器可以发现运行中的
   语言服务器,调用 Cascade RPC,把返回的 Markdown 拆分为 user/assistant 轮次,并写入
   `~/.engram/cache/windsurf/<cascadeId>.jsonl` 这份 **Engram 自有 JSONL 缓存**。
2. **Swift 产品索引。** 已发布的 Swift 索引器只读取缓存;它从不打开 `.pb`,也不再包含
   实时 Cascade RPC 同步路径。

**关键:已发布 Swift 产品中不存在实时同步。** 产品是**严格仅缓存**的:它索引
`~/.engram/cache/windsurf/` 中已存在的任何 `*.jsonl`,不写入任何新内容。当缓存为空且
此前从未有参考/开发同步时,产品目前在本机上呈现的 Windsurf 会话为**零**。TS 参考适配器
(`src/adapters/windsurf.ts`)是保留的缓存生产路径。

**心智模型(分层 / ASCII)。**

```
 LAYER 0  Windsurf-owned, OPAQUE (Engram reads mtime only, never content)
 ┌──────────────────────────────────────────────────────────────────────┐
 │ ~/.codeium/windsurf/cascade/<cascadeId>.pb   (protobuf base + .tmp     │
 │                                               deltas; likely gzipped)  │
 │ ~/.codeium/windsurf/daemon/*.json            (httpPort + csrfToken)    │
 └───────────────┬──────────────────────────────────────────────────────┘
                 │  (only via running language server)
 LAYER 1  Reference/dev Connect-RPC wire schema (not in Swift product)
 ┌───────────────▼──────────────────────────────────────────────────────┐
 │ POST http://localhost:<port>/exa.language_server_pb.LanguageServer…    │
 │   GetAllCascadeTrajectories   → trajectorySummaries{cascadeId→summary} │
 │   ConvertTrajectoryToMarkdown → { markdown: "## user…\n…## assistant…"}│
 └───────────────┬──────────────────────────────────────────────────────┘
                │  TS sync: parse markdown, flatten to {role,content}
 LAYER 2  Engram-owned cache — THE ONLY THING THE PRODUCT READS
 ┌───────────────▼──────────────────────────────────────────────────────┐
 │ ~/.engram/cache/windsurf/<cascadeId>.jsonl                            │
 │   line 1   = metadata  {id,title,createdAt,updatedAt,cwd?}            │
 │   lines 2+ = messages  {role,content[,timestamp]}                    │
 └──────────────────────────────────────────────────────────────────────┘
                 │  listSessionLocators → parseSessionInfo → streamMessages
                 ▼  NormalizedSessionInfo → DB Session row
```

**证据依据。** 在本机交叉核对了**四个**来源:

| 来源 | 详情 |
|---|---|
| **实时上游存储** | `~/.codeium/windsurf/cascade/` → **2** 个真实 `.pb` 文件(42.3 KB 的 `3943ee14-…` + 2.1 MB 的 `7da9e8cd-…`)。`~/.codeium/windsurf/daemon/` **不存在**。 |
| **实时 Engram 缓存** | `~/.engram/cache/windsurf/` 存在但**为空(0 文件)**——与 Swift 仅缓存行为一致。 |
| **仓库 fixtures** | `tests/fixtures/windsurf/cache/conv-w01.jsonl`(3 行,323 B)+ 平价对 `tests/fixtures/adapter-parity/windsurf/{input/cache/conv-w01.jsonl, success.expected.json}`。合成黄金样本,非用户数据。 |
| **适配器(已编码)** | Swift `Adapters/Sources/WindsurfAdapter.swift` 只读取缓存;TS `src/adapters/windsurf.ts`(+ `src/adapters/grpc/cascade-client.ts`)保留参考/开发 RPC 缓存生产路径。 |

**冲突解决。** 真实数据优先。实时存储*有*数据(`.pb`),但产品什么也不产出,因为 Swift
产品不含实时同步且缓存为空。所以*可索引的* schema 是 Layer-2 的 JSONL 缓存 schema;Layer-1 的线缆
schema 仅作为缓存所派生自的上游来源记录在案。唯一的写入方/读取方漂移(逐消息的
`timestamp`,见 §6/§15)是由源代码确认的,而非由一份实时生成的产物确认(本机没有这种产物)。

---

## 2. 磁盘布局与文件命名

### 权威根路径与存储技术

| 角色 | 路径(默认) | 存储技术 | 拥有者 | 产品是否读取? |
|---|---|---|---|---|
| 上游守护进程发现目录 | `~/.codeium/windsurf/daemon/` | 每实例 JSON 文件(`httpPort`、`csrfToken`) | Codeium/Windsurf | 仅供 TS 参考/开发同步 |
| 上游对话存储 | `~/.codeium/windsurf/cascade/` | 每对话一个不透明二进制 `.pb`,`<cascadeId>.pb` | Codeium/Windsurf | 仅供 TS 参考/开发同步;Swift 产品从不解析 |
| **Engram 缓存(已解析的事实来源)** | `~/.engram/cache/windsurf/` | **JSONL**,每对话一个文件 `<cascadeId>.jsonl` | **Engram** | **是——产品唯一读取的东西** |

默认值在两个适配器中均有接线:`WindsurfAdapter.init`
与 TS 构造函数(`windsurf.ts:38-42`)。`SourceCatalog` 把 Swift 产品路径列为
`~/.engram/cache/windsurf`,与 cache-only 适配器一致。

### 命名语法

| 产物 | 语法 | 示例 | 备注 |
|---|---|---|---|
| 上游 blob | `<cascadeId>.pb` | `7da9e8cd-17ea-4f40-99af-411f6386a59b.pb` | `cascadeId` = 小写 UUIDv4(Cascade *trajectory id*) |
| Engram 缓存文件 | `<cascadeId>.jsonl` | `7da9e8cd-….jsonl` | 相同 `cascadeId`,`.jsonl`;由保留的参考/开发工具写入 |
| Fixture 文件 | 任意 `<name>.jsonl` | `conv-w01.jsonl` | 文件名**不**用于解析身份;会话 `id` 来自 JSONL 元数据行,所以缓存文件名与元数据 `id` *可以*不同 |
| 守护进程发现文件 | `daemon/` 中的 `*.json` | (不定) | 供参考/开发同步发现 RPC 端点 |

**会话身份 = JSONL 元数据行内的 `id` 字段,而非文件名**
(`parseSessionInfo` 读取 `metadata["id"]`)。参考/开发同步期间该文件
按 `conversation.cascadeId` 命名,所以实际中两者一致。

### 真实目录树(本机)

```
~/.codeium/windsurf/                         # Codeium/Windsurf upstream data dir
├── cascade/                                 # <-- per-conversation transcript blobs
│   ├── 3943ee14-bc8c-4529-adc4-07b7fb2c1f5c.pb   # opaque binary, 42.3 KB
│   └── 7da9e8cd-17ea-4f40-99af-411f6386a59b.pb   # opaque binary, 2.1 MB
├── daemon/                                  # (ABSENT here) language-server discovery JSON
├── database/                                # internal Codeium DB (not session data; ignored)
├── memories/{global_memories.md,global_rules.md}  # not parsed by Engram
├── brain/  code_tracker/  context_state/  implicit/  recipes/  skills/
├── bin/  windsurf/  ws-browser/  ws-browser-profile/
├── installation_id        (36 B)
├── mcp_config.json        (155 B)
└── user_settings.pb       (4 KB)

~/.engram/cache/windsurf/                    # Engram-owned cache — EMPTY (live sync off)

tests/fixtures/windsurf/cache/
└── conv-w01.jsonl         (323 B)           # canonical cache example
```

Swift Engram 只触碰 `~/.engram/cache/windsurf/*.jsonl`。保留的参考/开发同步仍会使用
`daemon/*.json` 或运行中的语言服务器来生产缓存。`~/.codeium/windsurf/` 下的其他一切——
`database/`、`memories/`、`brain/` 等——都被忽略。

---

## 3. 文件生命周期与生成

| 问题 | 回答 |
|---|---|
| **追加还是重写?** | Engram 缓存 `.jsonl` 由保留的参考/开发缓存生产路径**完整重写**(TS `writeFile`,`windsurf.ts:97`)。Swift 产品不写 Windsurf 缓存文件。上游 `.pb` 由 Windsurf 自身重写/增长(2.1 MB 的 blob 呈现就地增长,而非滚动切换)。 |
| **DB 还是文件?** | Engram 触碰的两端都基于文件:上游不透明 `.pb` 文件,Engram 缓存中的 JSONL 文件。(Windsurf 保留一个内部 `database/` 目录,但 Engram 从不读取它。) |
| **恢复 / 续接** | 相同 `cascadeId` ⇒ 相同 `.pb` ⇒ 相同缓存文件。被恢复的 Windsurf 对话会增长其现有 blob,并在下次同步时覆盖现有的 `<cascadeId>.jsonl`。每次恢复不产生新文件——*直到*该对话因约 20 段对话的保留上限被驱逐(见滚动切换行),此后其上游 `.pb` 已不存在,无法再恢复。 |
| **滚动切换** | 单段对话没有基于大小/时间的*拆分*。但对话**并非**终其一生保留:Windsurf 在 Cascade 中强制约 20 段对话的保留上限——创建第 21 段会永久删除最旧的一段("your first conversation is gone forever")([issue #136](https://github.com/Exafunction/codeium/issues/136))。所以被驱逐对话的上游 `.pb` 会被 Windsurf 删除。Engram 自有的 JSONL 缓存从不清除(见归档/删除行),所以被驱逐对话的陈旧 `.jsonl` 会在其 `.pb` 消失后仍残留于缓存中。 |
| **新鲜度门控** | 参考/开发同步仅当**陈旧**时重新生成缓存:缓存缺失,或 `cache.mtime < pb.mtime`(TS `windsurf.ts:73-77`)。Swift 产品不执行新鲜度检查,因为它不写缓存文件。 |
| **归档 / 删除** | Engram 从不删除缓存文件。如果某段 Windsurf 对话在上游被删除,其 `.jsonl` 只是再也不会刷新而残留;同步只*创建/覆盖*,从不清除。 |
| **产品中的实时同步状态** | **不存在。** Swift 产品严格仅缓存。仅缓存状态在 `LiveSyncDisabledSources.ids = ["windsurf", "antigravity"]` 中被**规范化**,并在应用 UI 中作为 **"Cache only" 徽章**呈现给用户,因此无实时同步的状态被诚实展示,而不是被暗示为损坏/活跃的同步。 |

### 发现 / 枚举流程

`listSessionLocators()`(Swift `WindsurfAdapter.swift:129-132`)/ `listSessionFiles()`
(TS `:107-119`):

1. **枚举缓存**——`CascadeCacheSupport.jsonlLocators(cacheDir:)` 列出
   `~/.engram/cache/windsurf/` 中扩展名为 `.jsonl` 的**直接子项**(非递归),已排序;
   返回绝对路径作为 locator(`WindsurfAdapter.swift:6-11`)。
2. **逐会话解析**——`parseSessionInfo(locator:)` 流式读取 JSONL:第 1 行 → 元数据
   (要求非空 `id` + `createdAt`,否则 `.malformedJSON`);第 2..N 行 → 统计
   `user`/`assistant` 消息数 + 首条 user 文本;构建 `summary`。
3. **`detect()`** 仅在 `~/.engram/cache/windsurf/` 为目录时返回 true。守护进程目录本身
   不再让 Swift 产品把 Windsurf 标记为 detected。

---

## 4. 记录 / 行分类

跨各层共存在三种逻辑记录类型;只有 JSONL 缓存类型会被解析。

| 记录类型 | 位置 | 是否被 Engram 解析? | 用途 |
|---|---|---|---|
| **`.pb` 轨迹 blob** | `cascade/<cascadeId>.pb` | **否**(仅 mtime) | 原生 Windsurf 转写;不透明二进制 |
| **守护进程发现 JSON** | `daemon/*.json` | 仅实时同步期间 | 为 RPC 提供 `httpPort` + `csrfToken` |
| **RPC 载荷** | 瞬态(HTTP) | 内存中消费,从不存储 | 缓存内容的来源(Layer 1) |
| **JSONL 元数据记录** | 缓存 `.jsonl` 第 1 行 | **是** | 会话信封(id、title、时间、cwd) |
| **JSONL 消息记录** | 缓存 `.jsonl` 第 2..N 行 | **是** | 一个 user/assistant 轮次 |

**缓存中不同的嵌套层:** JSONL 只有两个扁平层——(1) *记录*(每行一个 JSON 对象)与
(2) 元数据-与-消息的*类型*,由行索引判别(`objects.first` = 元数据,
`objects.dropFirst()` = 消息,`WindsurfAdapter.swift:13-17`)。**没有内容块**;工具
调用被扁平化抹去(`toolMessageCount`/`systemMessageCount` 硬编码为 `0`,
`WindsurfAdapter.swift:166-167`)。

---

## 5. 共享信封 / 元数据字段

元数据记录是 JSONL 的第 1 行(每个文件恰好一条)。由保留的 TS 参考/开发缓存生产路径
(`windsurf.ts:86-97`)写入;由 Swift 产品解析器读取。

| 字段 | 类型 | 必需? | 含义 | 可选 | 示例(已匿名化) |
|---|---|---|---|---|---|
| `id` | string | **必需** | 会话 id = `cascadeId` = `.pb` 文件基名。空/缺失 → 整个文件被拒(`.malformedJSON`,`WindsurfAdapter.swift:138-144`) | no | `"conv-w01"`(实时:UUID,如 `3943ee14-…`) |
| `title` | string | 可选 | 对话标题;来自 `CascadeTrajectorySummary.summary`(summary 即标题——见 §15) | 始终写入(可能为 `""`) | `"Refactor the API"` |
| `createdAt` | string(ISO-8601 `…Z`) | **必需** | 会话开始 → `startTime`。缺失 → 文件被拒(`:141`) | no | `"2026-02-18T09:00:00.000Z"` |
| `updatedAt` | string(ISO-8601 `…Z`) | 可选 | 最后修改 → 当 `≠ createdAt` 时为 `endTime`,否则 `nil`(`:159`);缺失时回退为 `createdAt`(`:151`) | 回退为 `createdAt` | `"2026-02-18T09:20:00.000Z"` |
| `cwd` | string(绝对路径) | 可选 | 工作区文件夹;来自 `workspaces[0].workspaceFolderAbsoluteUri`(剥除 `file://`、URL 解码)→ `info.cwd`。**后期新增**——在此字段之前写入的缓存缺少它;保留的参考/开发缓存再生成可补上 | yes | `"/Users/<user>/proj"`(fixture 中缺失) |

```json
{"id":"conv-w01","title":"Refactor the API","createdAt":"2026-02-18T09:00:00.000Z","updatedAt":"2026-02-18T09:20:00.000Z"}
```
带 `cwd`(较新格式):
```json
{"id":"conv-1","title":"T","createdAt":"2026-02-18T09:00:00.000Z","updatedAt":"2026-02-18T09:20:00.000Z","cwd":"/Users/test/ws-project"}
```

> 遗留 Swift 缓存写入器曾发出排序后的元数据键。TS 发出插入顺序。当前 Swift 产品
> 不再写 Windsurf 缓存文件,读取方两者皆容忍。

---

## 6. 消息与内容 schema

消息记录是第 2..N 行(零条或多条)。Schema **刻意保持极简**:`role`、`content`,
外加第三个(`timestamp`)在读取时被容忍,但当前 Swift 产品不再写 Windsurf 缓存文件。

| 字段 | 类型 | 同步是否写入? | 解析器是否读取? | 含义 | 示例 |
|---|---|---|---|---|---|
| `role` | 枚举字符串 | yes | yes | 仅 `"user"` 或 `"assistant"`。任何其他值 → 消息被丢弃(`normalizedMessages`,`WindsurfAdapter.swift:19-35`;TS `:201`) | `"user"` |
| `content` | string | yes | yes | 扁平化的轮次正文(一个 Markdown 章节正文)。缺失 → `""`(`:29`) | `"Refactor the API to use REST"` |
| `timestamp` | string(ISO-8601) | optional legacy/reference data only | partial | 逐消息时间。被 TS `streamMessages` 与 Swift `normalizedMessages` 读取;出现在手写 fixtures 或遗留缓存中。 | `"2026-02-18T09:00:20.000Z"` |

```json
{"role":"user","content":"Refactor the API to use REST","timestamp":"2026-02-18T09:00:00.000Z"}
{"role":"assistant","content":"I'll restructure the endpoints.","timestamp":"2026-02-18T09:00:20.000Z"}
```

> **内容变体:** 恰好只有一种——一个纯 UTF-8 字符串。没有内容块,没有结构化数组,
> 没有图像,没有工具结果对象。原始轨迹的工具/推理结构在 Markdown 同步步骤中被坍缩
> 成散文(见 §7/§8)。

> **写入方/读取方漂移(仅由源代码确认):** fixture 在消息行上带有 `timestamp`,但
> 当前 Swift 产品不再写 Windsurf/Antigravity 缓存文件。`timestamp` 键只会出现在手写
> fixtures、遗留缓存或参考/开发工具生成的兼容数据中。本机无法凭经验验证,因为实时缓存为空。

---

## 7. 工具调用与结果

**对 Windsurf 不适用(缓存层面)。** 工具调用、工具结果以及调用↔结果的链接在
Engram 能索引到的任何地方都**不**存在。

- 当前 Swift parser 只看已经坍缩为 plain `{role,content}` 的缓存记录。
- 参考/开发 Markdown 同步(`ConvertTrajectoryToMarkdown`)把一切坍缩为按 `^##\s+` 表头拆分的
  散文,所以语言服务器渲染进 Markdown 的工具输出变成了不透明的 `content`。
- `NormalizedMessage.toolCalls` 被设为 `nil`;`toolMessageCount` 硬编码为
  `0`;平价黄金样本 `toolCalls: []`、`fileToolCounts: {}`、
  `insightFields.toolCallCount: 0`(`success.expected.json`)。

---

## 8. 推理 / 思考

**对 Windsurf 不适用。** 缓存 schema 中不存在专门的推理/思考字段。语言服务器渲染进
Markdown 的任何思维链都会被折叠进某条 assistant 消息的 `content` 字符串(如果有的话)。
不存在独立的 `thinking`/`reasoning` 记录、块或计数。

---

## 9. Token 用量与成本

**对 Windsurf 不适用——不存在 token 或成本数据。**

- Cascade 在被同步的 Markdown 路径中不暴露任何用量;`NormalizedMessage.usage` 为 `nil`。
- 缓存中任何地方都没有 `inputTokens`/`outputTokens`/cache-read/cache-creation 字段。
- 平价黄金样本 `usageTotals` **全为零**:
  `{inputTokens:0, outputTokens:0, cacheReadTokens:0, cacheCreationTokens:0}`
  (`success.expected.json`)。
- `model` 为 **`nil`**——Windsurf 从不在 Engram 读取到的
  任何东西里记录模型名。

---

## 10. 子代理 / 父子关系 / 派发

**对 Windsurf 不适用。** Windsurf 从不参与父级链接。适配器把 `agentRole`、
`originator`、`origin`、`parentSessionId` 与 `suggestedParentId` 全部设为 `nil`
。没有 sidecar(不像 Gemini 的 `.engram.json`)、没有
基于路径的子代理检测、也没有派发元数据。父/子链接仍可能在之后由 Engram 的启发式
Layer-2 流水线赋予,但适配器本身不贡献任何内容。

---

## 11. 摘要 / 压实

**对 Windsurf 不适用(无原生压实记录)。** 缓存中没有压实/摘要事件。*会话摘要*在解析时
派生,而非作为记录存储:

```
summary = (title.isEmpty ? firstUserText : title).prefix(200)
```

即:若存在则取元数据 `title`(Cascade `summary`),否则取首条 user 消息文本,截断为
200 字符。空 → `nil`。

---

## 12. SQLite / DB 内部

**对 Windsurf 不适用。** 从 Engram 的视角看,Windsurf **不**以 DB 支撑。上游数据是
不透明 `.pb` blob(非 SQLite);Engram 自己的存储是纯 JSONL 文件。(Windsurf 自身保留
一个内部 `~/.codeium/windsurf/database/` 目录,但 Engram 从不打开它。)

> 对比:VS Code 家族工具(Cursor、VS Code、Copilot、Cline)*确实*由 DB/state 支撑
> (`state.vscdb`、`chatSessions/*.jsonl`、每任务 JSON)。Windsurf 与它们**不共享**任何
> 磁盘 schema——见 §15。

---

## 13. 辅助文件

| 文件 / 目录 | 角色 | 是否被 Engram 使用? |
|---|---|---|
| `~/.codeium/windsurf/daemon/*.json` | 语言服务器发现(`httpPort`、`csrfToken`) | 仅 TS 参考/开发同步期间 |
| `~/.codeium/windsurf/cascade/<id>.pb` | 原生轨迹 blob | 仅 mtime(新鲜度门控) |
| `~/.codeium/windsurf/database/` | 内部 Codeium DB | 否 |
| `~/.codeium/windsurf/memories/{global_memories.md,global_rules.md}` | Codeium 记忆/规则 | 否 |
| `~/.codeium/windsurf/{brain,code_tracker,context_state,implicit,recipes,skills}/` | Codeium 内部 | 否 |
| `~/.codeium/windsurf/{mcp_config.json,user_settings.pb,installation_id}` | Codeium 配置/身份 | 否 |
| `~/.engram/cache/windsurf/<id>.jsonl` | **Engram 派生的已解析缓存** | **是——唯一被解析的输入** |

除 JSONL 缓存本身之外,Engram 不为 Windsurf 写入任何索引、日志或 sidecar 文件。

### 守护进程发现 JSON 字段(仅参考/开发同步期间读取)

| 字段 | 类型 | 含义 |
|---|---|---|
| `httpPort` | int 或数字字符串 | Cascade 语言服务器的本地端口(供 TS 参考/开发 sync 使用) |
| `csrfToken` | string(非空) | 在参考/开发 RPC 请求上作为 CSRF token 使用 |

> **版本脆弱性警告。** `daemon/*.json` 的 `{httpPort, csrfToken}` 发现文件,以及确切的
> `x-codeium-csrf-token` 头拼写,都是 Engram 自己逆向工程出来的细节——它们**未**被任何
> 官方/公开来源确认。CSRF-token 认证路径是版本相关的:Windsurf 1.9577+ **移除**了语言
> 服务器的 `--csrf_token` 参数,改用 `--stdin_initial_metadata`
> ([opencode-windsurf-auth #8](https://github.com/rsvedant/opencode-windsurf-auth/issues/8)),
> 所以在当前的 Windsurf 构建上,基于 `csrfToken` 的发现可能已不再适用。Windsurf *确实*会
> 通过 Connect-RPC 运行一个本地语言服务器,且默认本地 LS 端口与社区记录的 `LS_PORT=42100`
> 一致([WindsurfAPI](https://github.com/dwgx/WindsurfAPI/blob/master/README.en.md)),但请把
> 这里的具体发现/认证机制视为可能已过时,而非权威。

---

## 14. Engram 映射

两个阶段:(A) 缓存 → `NormalizedSessionInfo`(适配器);(B) `NormalizedSessionInfo` → DB
`Session` 行(`SwiftIndexer.buildSnapshot`)。下面使用符号级引用,因为 cache-only 适配器变形时
精确行号很容易漂移。

| Engram 字段 | 事实来源 | Swift code | TS 平价 code | 备注 |
|---|---|---|---|---|
| **id** | 元数据 `id` | `parseSessionInfo` | `windsurf.ts` | 必需;空/缺失 → `malformedJSON`(Swift)/ `null`(TS) |
| **source** | 常量 `windsurf` | `WindsurfAdapter.source` / `parseSessionInfo` | `windsurf.ts` | `SourceName.windsurf` |
| **startTime** | 元数据 `createdAt` | `parseSessionInfo` | `windsurf.ts` | 必需 |
| **endTime** | 当 `≠ createdAt` 时取 `updatedAt`,否则 `nil` | `parseSessionInfo` | `windsurf.ts` | 相同时间坍缩为 `nil`/`undefined` |
| **cwd** | 元数据 `cwd`(默认 `""`) | `parseSessionInfo` | `windsurf.ts` | 在 Layer-1 从 `workspaces[0]` 派生 |
| **project** | 适配器处为 `nil`;下游派生 | `parseSessionInfo` | (TS `SessionInfo` 中缺失) | `SwiftIndexer.buildSnapshot`:若 cwd 非空则 `project = URL(cwd).lastPathComponent`;cwd 为空 → 保持 `nil` |
| **model** | `nil`(未捕获) | `parseSessionInfo` | (缺失) | Windsurf 从不记录模型 |
| **messageCount** | user+assistant 计数 | `parseSessionInfo` | `windsurf.ts` | tool/system 始终为 0 |
| **userMessageCount** | 计数 `role==user` | `parseSessionInfo` | `windsurf.ts` | |
| **assistantMessageCount** | 计数 `role==assistant` | `parseSessionInfo` | `windsurf.ts` | |
| **toolMessageCount** | 硬编码 `0` | `parseSessionInfo` | `windsurf.ts` | Cascade 工具步骤未在缓存中建模 |
| **systemMessageCount** | 硬编码 `0` | `parseSessionInfo` | `windsurf.ts` | |
| **summary** | `(title ?: firstUserText).prefix(200)` | `parseSessionInfo` | `windsurf.ts` | 空 → `nil`/`undefined` |
| **filePath / locator** | 缓存 `.jsonl` 路径 | `parseSessionInfo` | `windsurf.ts` | |
| **sizeBytes** | 缓存文件大小 | `parseSessionInfo` | `windsurf.ts` | 平价 fixture = `323` 字节 |
| **usage (tokens)** | 无——每条消息 `usage:nil` | `CascadeCacheSupport.normalizedMessages`;totals `success.expected.json` 全 `0` | `windsurf.ts`(无 usage) | `usageTotals = {input:0,output:0,cacheRead:0,cacheCreation:0}` |
| **role (per message)** | 仅 `user`/`assistant` | `CascadeCacheSupport.normalizedMessages` | `windsurf.ts` | 非 {user,assistant} 被丢弃 |
| **timestamp (per message)** | 元数据 `timestamp`(只读) | `CascadeCacheSupport.normalizedMessages` | `windsurf.ts` | 当前 Swift 产品不写缓存;可能存在于遗留/参考缓存 |
| **toolCalls (per message)** | `nil` | `CascadeCacheSupport.normalizedMessages` | (缺失) | |
| **agentRole / originator / origin / parent / suggested** | `nil` | `parseSessionInfo` | (缺失) | Windsurf 从不参与父级链接 |
| **tier** | 下游计算(非适配器) | `SwiftIndexer.swift:342`(`SessionTier.compute`) | n/a | 来自 messageCount/source/preamble/assistant/tool 计数 |
| **summaryMessageCount** | `stats.indexedMessageCount` | `SwiftIndexer` | n/a | 适配器传 `nil`;索引器填充 |
| **snapshotHash / indexedAt / syncVersion / authoritativeNode** | 索引器簿记 | `SwiftIndexer.swift:363-365` | n/a | snapshot hash 包含 `cwd`、`summaryMessageCount`(`:388-400`) |

### Layer-1 线缆 → 缓存字段映射(仅 TS 参考/开发同步路径)

| Proto / Connect-JSON 字段 | 类型 | 映射到缓存字段 | 代码 |
|---|---|---|---|
| `trajectory_summaries` map key(`trajectory_id`) | string | `id` | `src/adapters/grpc/cascade-client.ts` |
| `CascadeTrajectorySummary.summary`(#1) | string | `title` **与** `summary` | TS Connect-JSON 主路径 |
| `created_time`(#7,`Timestamp{seconds,nanos}` 或 ISO) | ts | `createdAt` | TS Connect-JSON 主路径 |
| `last_modified_time`(#3) | ts | `updatedAt` | TS Connect-JSON 主路径 |
| `annotations.title`(#15→1) | string | **仅由 TS gRPC 回退路径读取**(`listConversationsGrpc` 映射为 `title`)。TS Connect-JSON 主路径忽略它并用 `summary` 作标题;Swift 产品没有 RPC 路径。见 gotcha #6/#7 §15 | `cascade-client.ts` |
| `workspaces[0].workspaceFolderAbsoluteUri`(仅 Connect-JSON) | `file://…` 字符串 | `cwd`(剥除 `file://`、URL 解码) | TS Connect-JSON 主路径 |
| `ConvertTrajectoryToMarkdown.markdown` | string | 解析为 `{role,content}` 消息 | TS 参考/开发同步 |

Markdown → 消息:按 `^##\s+` 拆分;以 `user` 开头的表头 → user;以 `assistant`
**或 `cascade`** 开头的表头 → assistant;空内容章节被丢弃
(TS `windsurf.ts`)。

---

## 15. 谱系、坑、版本漂移与边界情况

### 共享格式谱系

**Windsurf ↔ Antigravity(Cascade 家族)。** 同一引擎家族,同一 Swift 缓存读取形态。
两者都派生自 Codeium/"Cascade"。Swift 产品共享 `CascadeCacheSupport` 缓存 helper,
并读取相同的 JSONL 缓存形态(meta 行 + `{role,content}` 行)。上游 RPC 服务与
`GetAllCascadeTrajectories` / `ConvertTrajectoryToMarkdown` 名称仍保留在 TS 参考/开发工具中,
但 Swift 产品已不再包含 Cascade RPC client/discovery 路径。

**与 Antigravity 的差异:**
- Windsurf Swift 产品只读 `~/.engram/cache/windsurf/*.jsonl`;SourceCatalog 默认路径也指向
  这个缓存目录。
- Antigravity Swift 产品读取 `~/.engram/cache/antigravity/*.jsonl`,并另外直接读取
  `~/.gemini/antigravity-cli/brain` 下的 CLI brain transcripts。
- TS 参考/开发路径仍知道 Windsurf/Antigravity 的 daemon 与 conversations 根。

**不与 Cursor/VS Code/Copilot/Cline 共享。** 那些持久化到 SQLite `state.vscdb`、
`workspace.json`+`chatSessions/*.jsonl`,或每任务 JSON。Windsurf 是异类:它需要一个
*实时的语言服务器 RPC 桥*,并产生一份私有的派生 JSONL 缓存——与 VS Code-state 家族
不共享任何磁盘 schema。与 Gemini-CLI 集群唯一的偶然重叠是 **Antigravity** 使用的
`.gemini` 路径前缀(重命名,而非格式共享)。

### 坑与版本漂移

1. **产品中没有实时同步(最大的坑)。** Swift 已不再包含 Cascade RPC client/discovery 缓存
   生产路径。缓存从不被自动填充。干净机器 = **零 Windsurf 会话**,即便 `.pb` 文件存在。
2. **源存在但缓存为空。** 在此确认:2 个实时 `.pb` 文件,但 `~/.engram/cache/windsurf/`
   为空且 `~/.codeium/windsurf/daemon/` **缺失**。只有参考/开发工具能重新生产缓存。
3. **不透明 `.pb` 源(protobuf 基础 + `.tmp` delta,很可能被压缩——并非"已加密")。**
   其逻辑格式是 protobuf:官方仓库把该 `.pb` 称为 protobuf "base index"(约 40 MB),
   并伴随 `.tmp` "incremental snapshots"(delta)
   ([issue #286](https://github.com/Exafunction/codeium/issues/286))。Engram 在本机观测到的
   高熵字节(开头字节 `14f4 2934 face 359b …`;`file(1)` = `data`;无明文 protobuf 标签)
   最符合一个被压缩(gzip 包裹)且/或 delta-merge 布局的情形,**而非**加密——没有任何官方
   来源支持"已加密"。无论哪种情况,都没有离线路径可在不运行语言服务器的情况下恢复
   Windsurf 历史;卸载 Windsurf,这些轨迹就变得无法被 Engram 读取。
4. **`cwd` 比缓存格式更新。** 在 `cwd` 字段存在之前写入的缓存不携带工作区路径;没有
   参考/开发缓存再生成时,旧缓存会保持 `cwd == ""`,下游 `project` 派生为 `nil`。
5. **`timestamp` 读兼容但不由当前 Swift 产品写入。** 解析器/fixtures 仍会读取
   `timestamp`,所以该键只出现在手写 fixtures、遗留缓存或参考/开发缓存中。
6. **标题来源漂移(有范围限定)。** TS Connect-JSON 主路径用轨迹 `summary` 作标题;TS gRPC
   回退路径读取 `annotations.title`。Swift 产品没有 RPC 路径,只读缓存中的 `title`。
7. **Connect-JSON 与 gRPC 回退(运行时分歧——有两个字段不同)。** TS 偏好 Connect-JSON
   并回退到原始 gRPC(`listConversationsGrpc`)。该回退与主路径有**两处**不同,不止一处:
   (1) **`cwd` 丢失**——Connect-JSON 从 `workspaces[0]` 派生 `cwd`,gRPC 回退硬编码
       `cwd: ''`(`cascade-client.ts:332`);
   (2) **标题来源翻转**——Connect-JSON 用轨迹 `summary` 作标题
       (`:300`),gRPC 回退用 `annotations.title`(`:328`)。(见 gotcha #6。)
   Swift 产品不参与这个分歧,因为它没有 RPC client。
8. **单工作区假设。** TS reference Connect-JSON path 只读取 `workspaces[0]`;多根工作区会丢失其他文件夹。
9. **结构化 trajectory 解析是 TS-reference-only。** Swift 产品不再包含共享结构化步骤解析器
   或 Antigravity/Windsurf live cache writer。
10. **时间戳编码分叉。** TS reference client 将 `Timestamp{seconds,nanos}` 转换为 ISO-8601;
    Connect-JSON 可能已经返回 ISO 字符串。跨 Cascade 版本的混合编码被容忍。
11. **`sizeBytes` 内容精确(`323`)并喂入 snapshot hash。** 对缓存的任何
    空白/行尾变化都会改变 `sizeBytes`
    (`success.expected.json`),而 `cwd`/`summaryMessageCount` 喂入 snapshot hash
    (`SwiftIndexer.swift:388-400`)。
12. **`detect()` 只看缓存目录。** 守护进程目录本身不再让 Swift 产品把 Windsurf 标记为 detected。

### 否定清单(详尽——Windsurf schema 中缺失的内容)

| 概念 | 状态 |
|---|---|
| 工具调用 / 结果 / 链接 | **缺失。** `toolCalls:nil`,`toolMessageCount:0` |
| 推理 / 思考块 | **缺失。** 若渲染进 Markdown 则折叠进 `content` |
| Token / 用量 / 成本 | **缺失。** `usage:nil`;所有 `usageTotals` = 0 |
| 模型名 | **缺失。** `model:nil` |
| 系统消息 | **缺失。** `systemMessageCount:0`;角色过滤只接纳 user/assistant |
| 父/子/派发/originator | 适配器处**缺失 / nil** |
| `annotations.title` | **proto 中存在。仅由 TS gRPC 回退读取**(`cascade-client.ts`)。TS Connect-JSON 路径忽略它;Swift 产品没有 RPC 路径 |
| 多工作区 cwd | **被丢弃**——仅 `workspaces[0]` |
| 当前 Swift 生成缓存中的逐消息时间戳 | **不适用**——Swift 产品不再写 Windsurf 缓存 |

---

## 16. 附录:真实的匿名化样本

### A. Engram 缓存 JSONL —— 元数据记录(第 1 行)
来自 `tests/fixtures/windsurf/cache/conv-w01.jsonl`(结构逐字;内容为合成):
```json
{"id":"conv-w01","title":"Refactor the API","createdAt":"2026-02-18T09:00:00.000Z","updatedAt":"2026-02-18T09:20:00.000Z"}
```
带 `cwd` 的较新格式(来自 `Round5RemediationTests`):
```json
{"id":"conv-1","title":"T","createdAt":"2026-02-18T09:00:00.000Z","updatedAt":"2026-02-18T09:20:00.000Z","cwd":"/Users/test/ws-project"}
```

### B. Engram 缓存 JSONL —— 消息记录(第 2..N 行)
```json
{"role":"user","content":"Refactor the API to use REST","timestamp":"2026-02-18T09:00:00.000Z"}
{"role":"assistant","content":"I'll restructure the endpoints.","timestamp":"2026-02-18T09:00:20.000Z"}
```
无 `timestamp` 的缓存变体:
```json
{"role":"user","content":"Refactor the API to use REST"}
{"role":"assistant","content":"I'll restructure the endpoints."}
```

### C. 守护进程发现 JSON(仅参考/开发同步)
```json
{"httpPort":42100,"csrfToken":"REDACTED-csrf-token"}
```

### D. Layer-1 RPC —— `GetAllCascadeTrajectories` 响应(Connect-JSON,已匿名化)
```json
{
  "trajectorySummaries": {
    "3943ee14-bc8c-4529-adc4-07b7fb2c1f5c": {
      "summary": "Refactor the API",
      "createdTime": {"seconds": "1771405200", "nanos": 0},
      "lastModifiedTime": {"seconds": "1771406400"},
      "workspaces": [{"workspaceFolderAbsoluteUri": "file:///Users/u/proj"}]
    }
  }
}
```

### E. Layer-1 RPC —— `ConvertTrajectoryToMarkdown` 响应(已匿名化)
```json
{"markdown": "## User\nRefactor the API to use REST\n\n## Assistant\nI'll restructure the endpoints.\n"}
```

### F. 原生 `.pb` blob(不透明——不解析;前 32 字节,本机)
```
00000000: 14f4 2934 face 359b 4377 7d07 6f6f 4011  ..)4..5.Cw}.oo@.
00000010: e7dc 7975 fa10 681b 8688 6a73 ca27 4391  ..yu..h...js.'C.
file(1): data    # high-entropy; no plaintext protobuf field tags → protobuf base, likely compressed
```
> 逻辑格式是 protobuf(据 [issue #286](https://github.com/Exafunction/codeium/issues/286):
> protobuf "base index" + `.tmp` delta);高熵反映的是压缩 / delta-merge 布局,而非加密。

### G. 平价黄金样本(`tests/fixtures/adapter-parity/windsurf/success.expected.json`)

这是 Windsurf 拥有的**唯一具体黄金样本**。它有 **16 个顶层键**——下面的
`sessionInfo` 子对象只是其中**一个**。此前的"11 字段对象"是手工裁剪的摘录;完整顶层
记录在其后列举。

**G.1 —— 仅 `sessionInfo` 子对象(一个键的摘录):**
```json
{
  "id": "conv-w01", "source": "windsurf",
  "startTime": "2026-02-18T09:00:00.000Z", "endTime": "2026-02-18T09:20:00.000Z",
  "cwd": "", "project": null, "model": null,
  "messageCount": 2, "userMessageCount": 1, "assistantMessageCount": 1,
  "toolMessageCount": 0, "systemMessageCount": 0,
  "summary": "Refactor the API",
  "filePath": "<fixtureRoot>/windsurf/input/cache/conv-w01.jsonl", "sizeBytes": 323
}
```

**G.2 —— 完整顶层平价记录字段(全部 16 个键,逐字取自黄金样本):**

| 顶层键 | 类型 | 含义 | 此黄金样本中的值 |
|---|---|---|---|
| `source` | string | 适配器来源 id | `"windsurf"` |
| `sessionInfo` | object | `NormalizedSessionInfo`(见 G.1) | 上面的对象 |
| `messages` | `{role,content,timestamp}` 数组 | 完整流式消息,含 `timestamp`(仅 fixture——产品缓存缺少它,§6) | `[{role:"user",content:"…",timestamp:"…"},{role:"assistant",…}]` |
| `toolCalls` | array | 扁平化的工具调用(Windsurf 始终为空) | `[]` |
| `usageTotals` | object | Token 总计——Windsurf 全为零 | `{inputTokens:0, outputTokens:0, cacheReadTokens:0, cacheCreationTokens:0}` |
| `fileToolCounts` | object | 每文件工具使用计数(空——无工具) | `{}` |
| `insightFields` | object | Insight 提取输入 | `{firstUserSummary:"Refactor the API", messageCount:2, toolCallCount:0}` |
| `searchIndexFields` | object | 搜索索引输入 | `{contentPreview:"Refactor the API to use REST\nI'll restructure the endpoints.", contentSha256InputBytes:60, roles:["user","assistant"]}` |
| `statsFields` | object | 每角色消息计数 | `{messageCount:2, userMessageCount:1, assistantMessageCount:1, toolMessageCount:0, systemMessageCount:0}` |
| `projectFields` | object | 项目/cwd 解析 | `{cwd:"", project:null, source:"windsurf"}` |
| `locator` | string | fixture 根下的相对 locator | `"windsurf/input/cache/conv-w01.jsonl"` |
| `inputPath` | string | 相同的相对输入路径 | `"windsurf/input/cache/conv-w01.jsonl"` |
| `failure` | null \| object | 解析失败(此处无) | `null` |
| `schemaVersion` | int | 平价记录 schema 版本 | `1` |
| `generatedAtCommit` | string | 生成黄金样本时的 Git 短 SHA | `"88f86631"` |
| `nodeVersion` | string | 生成黄金样本的 Node 版本 | `"v26.0.0"` |

注意散文在别处从不浮现的搜索/insight 字段:
`searchIndexFields.contentSha256InputBytes = 60`(为搜索索引哈希的字节长度)、
`searchIndexFields.roles = ["user","assistant"]`,以及
`insightFields.firstUserSummary = "Refactor the API"`。

---

## 17. 开放问题 / 未验证(已于 2026-06-21 做 web 确认)

§1–§16 中的逆向工程结论已于 2026-06-21 对照外部来源交叉核对。各问题结论如下:

- **Q1 —— 对话存储于 `~/.codeium/windsurf/cascade/<id>.pb`(§1/§2)。**
  **已确认(官方):** Exafunction/codeium 仓库把 `~/.codeium/windsurf/cascade/` 记录为持有
  `.pb` 与 `.tmp` 文件的磁盘对话历史存储
  ([issue #286](https://github.com/Exafunction/codeium/issues/286)、
  [issue #127](https://github.com/Exafunction/codeium/issues/127))。
- **Q2 —— 该 `.pb` "不是普通 protobuf……已加密或已压缩"(§1,gotcha #3)。**
  **已确认(官方)——已更正,见上文 D2:** 官方仓库把该 `.pb` 描述为 protobuf "base index" +
  `.tmp` delta 快照;磁盘上的字节流很可能是*被压缩*的(gzip 包裹的 Connect-RPC 主体),
  **而非加密**。文档正文已据此弱化措辞
  ([issue #286](https://github.com/Exafunction/codeium/issues/286))。操作性结论(无法离线
  解码;需要语言服务器)依然成立。
- **Q3 —— 滚动切换为"一段对话 = 一个文件终其一生"(§3)。**
  **已驳斥(官方)——已更正,见上文 D1:** Windsurf 强制约 20 段对话的保留上限;第 21 段对话
  会永久删除最旧的一段,所以上游轨迹*确实*会被清除
  ([issue #136](https://github.com/Exafunction/codeium/issues/136))。较窄的子结论(Engram
  自有的 JSONL 缓存从不清除)仍然成立。
- **Q4 —— 记忆/规则位于 `~/.codeium/windsurf/memories/{global_memories.md,global_rules.md}`
  (§2/§13)。** **已确认(官方):** 自动生成的记忆位于 `~/.codeium/windsurf/memories/`,
  全局规则文件为 `~/.codeium/windsurf/memories/global_rules.md`
  ([Cascade Memories docs](https://docs.devin.ai/desktop/cascade/memories))。Engram 正确地
  将这些视为不解析的 Codeium 文件。
- **Q5 —— 通过 HTTP/Connect-RPC 访问的本地语言服务器,带端口发现 +
  `x-codeium-csrf-token` 头(§1/§2/§13)。** **已确认(官方)——部分,已更正,见上文 D3:**
  Windsurf 确实使用 Connect-RPC 运行一个本地语言服务器,且 CSRF-token 机制是真实存在的,
  但它是版本相关的——Windsurf 1.9577+ 用 `--stdin_initial_metadata` 取代了 `--csrf_token`
  ([opencode-windsurf-auth #8](https://github.com/rsvedant/opencode-windsurf-auth/issues/8)、
  [Windsurf Internals](https://medium.com/@GenerationAI/windsurf-internals-ac4b452807a0))。
  确切的 `x-codeium-csrf-token` 拼写与 `daemon/*.json` 的 `{httpPort,csrfToken}` 发现文件是
  Engram 逆向工程的产物,未被官方来源确认;默认本地 LS 端口与社区记录的 `LS_PORT=42100`
  一致([WindsurfAPI](https://github.com/dwgx/WindsurfAPI/blob/master/README.en.md))。
- **Q6 —— RPC 方法/服务名(`exa.language_server_pb.LanguageServerService`、
  `GetAllCascadeTrajectories`、`ConvertTrajectoryToMarkdown`、`getTrajectoryMessages`)
  (§1/§14)。** `exa.*_pb` 服务家族与 `exa.language_server_pb.LanguageServerService` 由逆向
  工程的流量与用户日志佐证
  ([Windsurf Internals](https://medium.com/@GenerationAI/windsurf-internals-ac4b452807a0)),
  但具体的 Cascade 轨迹 RPC 方法名是 Engram 自己的逆向工程结果(web-checked 2026-06-21: no
  authoritative source found)。
- **Q7 —— `cascadeId` 是用作 `.pb` 文件基名的小写 UUIDv4(§2 命名语法)。**
  与本机观测到的文件以及 Windsurf 的 UUID 遥测惯例一致,但 `.pb` 文件基名语法未被任何公开
  来源记录(web-checked 2026-06-21: no authoritative source found)。
- **Q8 —— Engram 内部结论(Swift cache-only 产品路径、JSONL 缓存 schema、timestamp
  读取兼容、Antigravity 缓存解析共享)(§1,§3,§6,§15)。**
  (Engram-internal design —— not web-verifiable。)请对照仓库中的 Swift/TS 源代码核验这些,
  而非对照 web。

---

## 18. References (official sources)

- [Exafunction/codeium issue #286 — language_server memory leak (cascade `.pb`/`.tmp` disk usage)](https://github.com/Exafunction/codeium/issues/286)
- [Exafunction/codeium issue #136 — Remove or increase limit of past conversations in Cascade](https://github.com/Exafunction/codeium/issues/136)
- [Exafunction/codeium issue #127 — Windsurf Chat history Export and Search](https://github.com/Exafunction/codeium/issues/127)
- [Windsurf/Devin Cascade Memories docs (memories + rules on-disk locations)](https://docs.devin.ai/desktop/cascade/memories)
- [opencode-windsurf-auth issue #8 — Windsurf 1.9577+ uses `--stdin_initial_metadata` instead of `--csrf_token`](https://github.com/rsvedant/opencode-windsurf-auth/issues/8)
- [Wei Lu — Windsurf Internals (reverse-engineering of Connect-RPC/proto wire traffic)](https://medium.com/@GenerationAI/windsurf-internals-ac4b452807a0)
- [dwgx/WindsurfAPI README (`LS_PORT=42100` default gRPC port; `LS_DATA_DIR`)](https://github.com/dwgx/WindsurfAPI/blob/master/README.en.md)
