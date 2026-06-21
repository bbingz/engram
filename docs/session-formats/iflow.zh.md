# iFlow — 会话格式参考

> 本文档为英文权威版 iflow.md 的中文阅读副本;若有出入以英文版为准。

Last researched: 2026-06-21 (Engram session-format research workflow)

> 关于 **iFlow CLI** 如何在磁盘上持久化其 AI 编码会话,以及 Engram 的 `IflowAdapter`
> (Swift 产品解析器 + TS 参考解析器)如何发现并消费这些会话的权威英文参考。与
> [`gemini-cli.md`](./gemini-cli.md)、[`qwen` fixtures](../../tests/fixtures/qwen)、
> [`claude-code.md`](./claude-code.md) 和 [`codex.md`](./codex.md) 为同级文档。本文档
> 自包含;对 `gemini-cli.md` 的交叉引用仅用于说明共同的血统渊源。
>
> **核心发现。** iFlow 是一个**三方混血体**:它生活在一个 Qwen 形态的*目录布局*中
> (`~/.iflow/projects/<encoded-cwd>/…jsonl`),但其*转录记录 schema 采用 Anthropic /
> Claude Code JSONL 线格式*(`uuid`/`parentUuid`/`sessionId`/`type`/`message` 信封、
> Anthropic `content[]` 块、`usage.{input_tokens,output_tokens}`、Claude 风格的
> system-injection 标记)——而**不是** Gemini 的 `{text}`/`parts[]` schema。然而,其内层
> `tool_result` 载荷却是纯 Gemini-CLI 风格
> (`callId`/`responseParts`/`functionResponse`)。它是一个 **Gemini CLI fork**
> (打包后的 `bundle/iflow.js` 带有 `Copyright 2025/2026 Google LLC` SPDX 头部
> 以及 `google.gemini-cli` 引用),通过 iFlow 开放平台运行**多模型**阵容 ——
> 默认模型是 `glm-4.7` 与 `Qwen3-Coder-Plus`,另外还可选 Kimi K2、DeepSeek v3.2、
> GLM-4.6 以及任何 OpenAI 兼容端点。被抓取的真实会话恰好运行 `glm-5`,但 iFlow
> **并非** GLM-only,在代码库层面也**不是** Claude-Code 衍生的 —— Anthropic 形态的
> 转录 schema 是叠加在 Gemini-CLI 代码库之上的设计选择
> ([source](https://www.npmjs.com/package/@iflow-ai/iflow-cli))。

---

## Evidence basis

交叉核对了两个真实来源;**冲突时以真实数据为准,并标注差异。**

1. **LIVE on-disk store** —— 本机上的 `~/.iflow/`。**2 个会话转录**,`~/.iflow/projects/` 下每个项目目录一个,均为 `.jsonl`:
   - `~/.iflow/projects/-Users-bing-Code-WebSite_GLM/session-b5785972-6711-443a-9bb4-e361146f8e79.jsonl` —— 238.2 KB,**41 行**(16 user + 25 assistant)。
   - `~/.iflow/projects/-Users-bing-Code-engram/session-041101e6-2a7f-4dfd-90b0-57888a353f6a.jsonl` —— 3.7 KB,**4 行**(2 user + 2 assistant)。
   - 两者合计:**45 行 = 18 个 `user` + 27 个 `assistant`**。
   - 其他真实状态(均非会话数据,Engram 均不读取):`~/.iflow/config/projects.json`(1 条目)、`~/.iflow/tmp/<64hex>/logs.json`、`~/.iflow/log/console-*.log`、`~/.iflow/settings.json`、`oauth_creds.json`、`iflow_accounts.json`、`installation_id`,以及目录 `cache/ config/ log/ skills/ tmp/`。
   - **`find ~/.iflow -name '*.engram.json'` → 0** 个 sidecar。`~/.iflow` 下**任何位置都没有 SQLite / leveldb / gRPC 缓存**。
2. **Repo fixtures** ——
   - `tests/fixtures/iflow/{sample.jsonl, schema_drift.jsonl}`(2 个独立 fixture —— `sample.jsonl` = user/assistant/user;`schema_drift.jsonl` = 2 行前向容忍数据)。
   - `tests/fixtures/adapter-parity/iflow/{success.expected.json, input/-Users-test-my-project/session-sample.jsonl}`(1 个 3 行的输入 + 1 个期望输出)。
3. **Engram adapters (codified knowledge)** ——
   - Swift 产品解析器:`macos/Shared/EngramCore/Adapters/Sources/IflowAdapter.swift`(207 行)。
   - TS 参考解析器:`src/adapters/iflow.ts`(213 行)。
   - 共享 JSONL 辅助器:`enum JSONLAdapterSupport`(定义于 `macos/Shared/EngramCore/Adapters/Sources/CodexAdapter.swift:4` 内部),外加 `macos/Shared/EngramCore/Adapters/ParserLimits.swift`(位于 `Adapters/Sources/` 的**上一级**目录,不是解析器的同级)以及 `StreamingLineReader`。
   - 项目迁移编码器:`EngramCoreWrite/ProjectMove/Sources.swift`(`encodeIflow`,`:489-499`)。

**发现并解决的差异(以真实数据为准):**
- 项目注册表位于 **`~/.iflow/config/projects.json`**(它确实存在),**而非** `~/.iflow/projects.json`(该路径不存在)。两者都是维度报告的子论断;`config/` 路径是正确的。
- **`tests/fixtures/iflow/` 确实存在**(2 个文件)。某份维度报告声称它不存在 —— 该论断是**错误的**;`sample.jsonl` 和 `schema_drift.jsonl` 都在。
- 没有**丢失数据**的差异:两个真实 `.jsonl` 文件都匹配发现过滤器、干净解析并正确呈现(与 Gemini 形成对比,后者的真实 `.jsonl` 会话会被静默丢弃)。所有值得注意的发现都属于*血统*与*行为边界情况*(见 §15)。

---

## 1. Overview & TL;DR

**是什么 / 在哪里 / 怎么存。** iFlow CLI 将每段对话存为 **每会话一个 JSONL 文件**,位于 `~/.iflow/projects/<encodedProjectDir>/session-<UUID>.jsonl`。每行是一条自包含的对话/工具记录。**没有 SQLite、没有 leveldb、没有 gRPC 缓存** —— 只是逐行追加的行分隔 JSON。辅助性的全局状态(`config/projects.json`、`tmp/<hex>/logs.json`、settings/auth)**Engram 一概不读取**。

**心智模型。** `session = file`;`record = line`。新轮次以新行**真正追加**(不同于 Gemini 的整文件重写或 `$set` 快照式变更日志);更早的行不可变。`sessionId`(一个**携带 `session-` 前缀**的字符串)在整个文件中保持不变,且逐字等于文件名主干。

**存储技术 / 权威根目录**(两个适配器):`~/.iflow/projects` —— `IflowAdapter.swift:9-11`(`.iflow/projects`)、`iflow.ts:20`(`join(homedir(),'.iflow','projects')`)。**FLAT(扁平)**布局:会话文件**直接**位于各项目目录中 —— **没有 `chats/` 子目录**(这是 iFlow 与 Qwen/Gemini 的分歧,后两者嵌套于 `chats/` 之下)。

**ASCII 布局 / 分层图。**

```
~/.iflow/                                          storage tech: append-per-line JSONL files
├── config/projects.json     ── project registry { "<encodedDir>": { name,path,sessions[],createdAt,lastActivity } }   (IGNORED)
├── settings.json, oauth_creds.json, iflow_accounts.json, installation_id ── CLI config/auth (IGNORED; contain secrets)
├── log/console-*.log        ── CLI console log (IGNORED)
├── tmp/<64hex>/logs.json    ── per-session message telemetry [ {sessionId,messageId,type,message,timestamp} ]   (IGNORED)
├── cache/ config/ skills/   ── runtime dirs (IGNORED)
└── projects/                ── transcript root  (adapter `projectsRoot`)
    └── <encodedProjectDir>/ ── one dir per project; name = "-"-encoded absolute cwd (e.g. -Users-bing-Code-engram)
        └── session-<UUID>.jsonl   ── one session = one file (FLAT; NO chats/ subdir)   ← Engram parses

  layer 1  line record   { uuid, parentUuid, sessionId, timestamp, type, isSidechain, userType,
                           cwd?, gitBranch?, version?, message, toolUseResult? }
  layer 2    └─ message  user:      { role, content }
             └─ message  assistant: { id, type, role, content[], model, stop_reason, stop_sequence, usage }
  layer 3        ├─ content (string)                              ← used verbatim
  layer 3        ├─ content[] { type:"text", text }               ← joined: "\n\n" (Swift) / "\n" (TS)
  layer 3        ├─ content[] { type:"tool_use", id, name, input } ← IGNORED
  layer 3        ├─ content[] { type:"tool_result", tool_use_id, content } ← IGNORED (user records)
  layer 3        └─ usage { input_tokens, output_tokens }         ← Swift only; TS drops it
  layer 4              ├─ toolUseResult { status, timestamp, toolName }   (top-level on user record; IGNORED)
  layer 4              └─ tool_result.content { callId, responseParts, resultDisplay }   (Gemini lineage; IGNORED)
  layer 5                    └─ responseParts.functionResponse { id, name, response{output} }   (IGNORED)
```

**给 Engram 工程师的 TL;DR。** Engram 只读取 `user`/`assistant` 记录,并保留 `sessionId`(含 `session-` 前缀 → `id`)、`cwd`(取文件内首个非空值)、`timestamp`(首=开始,末=结束)、每条消息的 `model`(首次出现的值)、扁平化后的 **`text` 块**内容,以及(仅 Swift)每条消息的 `usage`。它将 `project` 设为 `nil`(从不读取 `config/projects.json`;`decodeCwd` 是死代码),并**丢弃** `uuid`/`parentUuid`/`isSidechain`/`userType`/`gitBranch`/`version`/`toolUseResult`/`stop_reason`/`stop_sequence`/内层 `message.id`/`message.type`;所有 `tool_use` 和 `tool_result` 块;以及(TS 路径)**全部** token 用量。

---

## 2. On-disk layout & file naming

| Path | Role | Storage tech | Read by Engram? |
|---|---|---|---|
| `~/.iflow/projects/` | 会话转录根目录(适配器 `projectsRoot`) | dir of per-project dirs | ✅ enumerated |
| `~/.iflow/projects/<encodedProjectDir>/` | 每个项目一个目录(= "-"-编码后的绝对 cwd) | dir | ✅ direct children |
| `~/.iflow/projects/<encodedProjectDir>/session-<UUID>.jsonl` | **一个会话 = 一个文件** | **append-per-line JSONL** | ✅ parsed |
| `~/.iflow/config/projects.json` | 项目注册表(`encodedDir → {name,path,sessions[],…}`) | single JSON object | ❌ never read |
| `~/.iflow/tmp/<64hex>/logs.json` | 每会话的消息遥测 | JSON array | ❌ never read |
| `~/.iflow/log/console-*.log` | CLI 控制台日志 | text | ❌ |
| `~/.iflow/{settings,oauth_creds,iflow_accounts}.json`、`installation_id`、`cache/`、`skills/` | CLI 配置/认证/缓存 | mixed | ❌ |

> **不存在 `~/.iflow/projects.json`** —— 已在线验证缺失。注册表位于 `config/projects.json`。不同于 Gemini CLI(它在顶层 `projects.json` 中以 cwd→name 建立键值并用于反查),iFlow 的适配器从不查询任何项目名映射。

### Naming grammar

| Token | Grammar | Live examples | Notes |
|---|---|---|---|
| `<encodedProjectDir>` | 绝对 cwd,`/` → `-`(前导 `/` 变为前导 `-`) | `-Users-bing-Code-WebSite_GLM`、`-Users-bing-Code-engram` | Claude-Code 风格的路径编码。Engram **不**对其解码(`project: nil`);它转而从文件内部读取 `cwd`。项目迁移编码器(`Sources.swift encodeIflow :489-499`)是**有损的** —— 它会剥除每段前导/尾随的破折号,因此 `-Code-` → `Code`。适配器自带的 `decodeCwd` 使用一套*不同的*(`--`→哨兵)方案,且是**死代码**;两者并非互逆(见 §15 #2)。 |
| session file | `session-<UUID>.jsonl` | `session-b5785972-6711-443a-9bb4-e361146f8e79.jsonl`、`session-041101e6-2a7f-4dfd-90b0-57888a353f6a.jsonl` | `<UUID>` = 标准 36 字符小写 UUID。**没有**时间戳前缀,**没有** 8 位十六进制后缀(不同于 Gemini 的 `session-<ts>-<8hex>`)。**发现过滤器:** 名称 `hasPrefix("session-")` 且 `pathExtension == "jsonl"`(Swift:28 / TS:40)。 |
| in-file `sessionId` | `session-<UUID>` —— **包含 `session-` 前缀** | `"session-041101e6-2a7f-4dfd-90b0-57888a353f6a"` | **两个真实文件均确认:** `sessionId` == 文件名主干(去掉 `.jsonl`)完全相等。因此 Engram 存储的 `id` 是 `session-<UUID>`,**而非**裸 UUID。与 Gemini/Qwen 不同,后两者文件名后缀仅为 `sessionId[0:8]`。 |

> **冲突 / 细微差别(以真实数据为准)。** `<encodedProjectDir>` 名称**无法**可靠地解码回文件内的 `cwd`。真实文件 2 位于目录 `-Users-bing-Code-engram`,但其文件内 `cwd` 却是 `/Users/bing/-Code-/coding-memory`(项目在磁盘上被重命名/移动过)。Engram 通过信任文件内的 `cwd` 并将 `project` 设为 `nil` 来规避此问题;编码器/解码器无法往返还原(§15 #2)。

### Tree example (live, anonymized)

```
~/.iflow/
├── config/
│   └── projects.json          # { "-Users-<u>-Code-coding-memory": { name, path, sessions:["session-041101e6-…"], createdAt, lastActivity } }
│                              #   (1 entry; registry is INCOMPLETE — lists neither on-disk dir name, and omits the WebSite_GLM project)
├── tmp/
│   └── f16dd15d…c562b352/      # 64-hex dir (opaque key)
│       └── logs.json          # [ { sessionId:"session-b5785972-…", messageId:0, type:"user", message:"<preview>", timestamp:"…Z" }, … ]
├── log/console-2026-02-27T09-08-44-062Z-58523.log
├── settings.json              # { apiKey, baseUrl, bootAnimationShown, cna, modelName, searchApiKey, selectedAuthType }
└── projects/                  # adapter projectsRoot
    ├── -Users-<u>-Code-WebSite_GLM/
    │   └── session-b5785972-6711-443a-9bb4-e361146f8e79.jsonl   # 238.2 KB, 41 lines (16 user + 25 assistant)  ← parsed
    └── -Users-<u>-Code-engram/
        └── session-041101e6-2a7f-4dfd-90b0-57888a353f6a.jsonl   # 3.7 KB, 4 lines (2 user + 2 assistant)  ← parsed
```

> **与同级格式的关键布局分歧:** iFlow 是**扁平的** —— `projects/<dir>/session-*.jsonl`,**没有 `chats/` 子目录**。Qwen 要求 `projects/<dir>/chats/*.jsonl`(`QwenAdapter.swift:27-28` 守卫一个 `chats/` 目录);Gemini 要求 `tmp/<dir>/chats/session-*.json`。(见 §15 血统。)

---

## 3. File lifecycle & generation

| Aspect | Behavior | Evidence |
|---|---|---|
| **Storage tech** | 每会话一文件,逐行追加 JSONL。无 DB/leveldb/gRPC。 | live store; `StreamingLineReader` reads line-by-line |
| **DB vs file** | 文件。一个文件 = 一个 `sessionId`;文件名 = `session-<UUID>.jsonl` == 文件内 `sessionId`。 | filename == `sessionId` |
| **Append vs rewrite** | **真追加**:每个新轮次(user/assistant/tool 轮)= 追加一行新 JSON;更早的行不可变。`sessionId` 在整个文件中不变。(对比 Gemini 旧版 `.json` 整文件重写,以及 Gemini `.jsonl` 的 `$set` 快照。) | 41 lines, monotonic `timestamp`; ordered `parentUuid` chain |
| **Per-record linkage** | 每条记录有自己的 `uuid`;`parentUuid` 指向前一条记录的 `uuid`(首个 user 记录 `parentUuid:null`)。单一线性 DAG。 | live: line 1 `parentUuid:null`; subsequent lines chain |
| **Resume** | 同一文件/`sessionId` 继续增长;`startTime`(首个时间戳)固定,`endTime`(末个时间戳)向前推进。 | append model |
| **Rollover** | 新会话 = 同一项目目录下的新 `session-<UUID>.jsonl`。对既有转录不做轮转/分段。 | one file per UUID |
| **Archive / cleanup** | `projects/` 下未观察到归档目录。`config/projects.json` 中的注册表可能滞后(实测:WebSite_GLM 会话在磁盘上存在,却不在注册表中)。 | live registry has 1 of 2 projects |
| **Discovery** | `detect()` 当且仅当 `~/.iflow/projects` 是目录时为 true(Swift:18-20 `isDirectory`;TS:23-30 `stat`)。 | adapter |
| **Enumeration** | 对 `projects/` 的**每个直接子目录**,产出名称**以 `session-` 开头且扩展名为 `.jsonl`** 的文件(Swift:22-34 `hasPrefix("session-") && pathExtension == "jsonl"`;TS:32-51 `startsWith('session-') && endsWith('.jsonl')`)。**不遍历 `chats/`**(不同于 Qwen)。Swift 返回**已排序**列表(`locators.sorted()` :33);TS 按 `readdir` 顺序逐目录惰性产出,并吞掉不可读目录(`catch {}` :44-46)。 | adapter |
| **Size cap (Swift)** | 文件 > **100 MB** → `.fileTooLarge`(`ParserLimits.maxFileBytes = 100*1024*1024`,`Adapters/ParserLimits.swift:17`,经由 `validateFileSize :47-49`);单行 > **8 MB** → 由 `StreamingLineReader(maxLineBytes:8*1024*1024)` 处理;解析对象 > **10,000** → `.messageLimitExceeded`(`CodexAdapter.swift:71,86`)。 | `Adapters/ParserLimits.swift:17-19`; `CodexAdapter.swift` |
| **Size cap (TS)** | **无。** 不同于 `gemini-cli.ts`(10 MB `MAX_SESSION_JSON_BYTES`),`iflow.ts` 没有任何大小/行数/计数上限 —— 整文件逐行流式读取。Swift 与 TS 的分歧。 | `iflow.ts:170-184` |
| **Atomicity guard (Swift only)** | `JSONLAdapterSupport.readObjects` 在读取前后重新校验文件身份(size/mtime/resource-id);不匹配 → `.fileModifiedDuringParse`(一个正在被追加的真实会话会被拒绝,稍后重试)。相比 Gemini,iFlow 更易触发,因为 iFlow 每轮都真正追加。 | `CodexAdapter.swift:78-81` |
| **FD-leak guard (TS only)** | `readLines` 使用 `try/finally` 在提前 break(limit/offset)时也关闭 readline 接口 + 流,防止 `EMFILE`。 | `iflow.ts:170-184` |

---

## 4. Record / line taxonomy (layer 1)

一个文件 = N 行;每行是一个 JSON 对象。判别字段是顶层 **`type`**。**真实数据 + fixtures 中观察到:** 只有 `user` 和 `assistant`。两个适配器**只**接受这两种;任何其他 `type` 都被 `continue`-跳过(Swift:52-54 / TS:71)。`guard !sessionId.isEmpty` 否则 `.malformedJSON`(Swift:89)/ `return null`(TS:98)。

| `type` | live count | `message.role` | content shape(s) | carries `toolUseResult`? | Engram role | Counted? |
|---|---|---|---|---|---|---|
| `user` | 18 | `"user"` | `string`(真实 prompt)**或** `array[{tool_result}]`(工具输出轮) | only when content is `tool_result` | `role: user` | yes(user 计数),**除非**被归类为 system-injection |
| `assistant` | 27 | `"assistant"` | `array[ {text} \| {tool_use} ]` | never | `role: assistant` | yes(assistant 计数) |
| _(any other)_ | 0 | — | — | — | skipped | no |

**在顶层 `type` 判别字段层面,不存在独立的 `system`、`summary`、`info`、`tool` 或 `meta` 行类型**(不同于 Gemini 的 `info` 或 Qwen 的 `system`/`ui_telemetry`)。"System" 是 `user` 行的一个*派生*子分类,而非一种行类型(见 §5 与 §7)。iFlow 没有 `ui_telemetry` 的 token 行 —— 用量是内联在 assistant 消息上的。

> **Confirmed (official):meta/压缩记录确实存在于磁盘上 —— 伪装成 `type:"user"`。** 官方 bundle 的消息创建器(`createUserMessage`、`createAssistantMessage`、`createToolResultMessage`、`createCompressionMessage`、`createMetaMessage`)将工具结果、压缩(上下文摘要)以及 meta 记录全部以**顶层 `type:"user"`** 写入 `message:{role:"user",…}` 内 —— 压缩记录携带内部压缩标记,meta 记录携带 `isMeta:true`。因此判别字段仍只有 `user`/`assistant`(上面的陈述在该层面成立),但压缩与 meta 记录伪装成 `user` 记录持久化在磁盘上,并被 Engram 静默计为 user 消息(Engram 不对 `isMeta`/压缩标记做特殊处理)。writer 中任何位置都没有 `type:"system"` / `type:"summary"` / `type:"info"`([source](https://www.npmjs.com/package/@iflow-ai/iflow-cli))。

> **`messageCount` 语义陷阱(REAL)。** 一条 `user` 记录会被计为 user 消息,**除非**其扁平化文本匹配 `isSystemInjection`(Swift:79-85 / TS:86-93)。它**不会**跳过空内容记录。在真实的 238 KB 会话中,**16 条 user 记录里有 12 条仅含 `tool_result`**(`{type:"tool_result"}` 数组,没有 `text` 块)→ `extractContent` 返回 `""`,`isSystemInjection("")` 为 false → 每条都被**计为一条 user 消息**且文本为空。因此实测 `userMessageCount` = 16(而非 4 条 "真实" prompt),`messageCount` = 16 + 25 = 41 = 原始行数。iFlow 的 `messageCount` 因此会随工具轮次膨胀 —— 对比 Gemini Swift,后者会预先过滤空内容。见 §15 #4。

---

## 5. Shared envelope / metadata fields (layer 1 — per line)

字段是否存在**因 `type` 而异**。**已验证的键集(实测):**
- **`user` 行:** `cwd, gitBranch, isSidechain, message, parentUuid, sessionId, timestamp, type, userType, uuid, version`(当携带 `tool_result` 时另有 `toolUseResult`)。
- **`assistant` 行:** `isSidechain, message, parentUuid, sessionId, timestamp, type, userType, uuid` —— **没有 `cwd`、`gitBranch` 或 `version`**(已确认:大会话中 25/25 条 assistant 行均为 `has_cwd:false, has_version:false, has_git:false`)。

| Field | Type | Meaning | Optional | Present on | Consumed? | Example (anonymized) |
|---|---|---|---|---|---|---|
| `sessionId` | string (`session-<UUID>`) | 稳定的会话标识(携带 `session-` 前缀);Engram 主键 | **required**(否则 `.malformedJSON`/null) | both | ✅ → `id` | `"session-041101e6-2a7f-4dfd-90b0-57888a353f6a"` |
| `type` | string | 记录判别字段:`"user"` / `"assistant"` | required | both | ✅(role + counts) | `"assistant"` |
| `message` | object | 对话载荷(layer 2) | required | both | ✅ | `{ role, content, ... }` |
| `timestamp` | string (ISO-8601 ms, UTC `Z`) | 记录产生时间;首→start,末→end | required | both | ✅ → start/end + per-msg ts | `"2026-02-27T09:11:31.532Z"` |
| `cwd` | string (abs path) | 本轮的工作目录 | optional | **user only (live)** | ✅ → `cwd`(首个非空者胜) | `"/Users/<u>/-Code-/coding-memory"` |
| `uuid` | string (UUID) | 每条记录的 id | required | both | ❌ | `"61c24f2a-a626-4d0b-9441-cdb753a2ec76"` |
| `parentUuid` | string \| null | 前一条记录的 `uuid`(会话内 DAG);首条为 `null` | required | both | ❌ | `null` / `"aa-001"` |
| `isSidechain` | bool | 子代理 sidechain 标记;实测**始终 `false`**(41/41) | required | both | ❌ | `false` |
| `userType` | string | 来源分类;实测**始终 `"external"`**(41/41) | required | both | ❌ | `"external"` |
| `gitBranch` | string \| null | 本轮的 Git 分支(实测 `null`;fixture `"main"`) | optional | **user only (live)** | ❌ | `null` / `"main"` |
| `version` | string \| null | iFlow CLI/schema 版本;实测 `"1.0.0"`,drift fixture `"2.0.0"` | optional | **user only (live)** | ❌ | `"1.0.0"` |
| `toolUseResult` | object | **行级**工具执行元数据 sidecar(layer 4;区别于 `tool_result` 内容块) | optional | user(仅工具轮) | ❌ | `{ status, timestamp, toolName }` |

> **磁盘上没有信封级的 `messageCount`、`startTime`、`endTime` 或 `model`。** `startTime`/`endTime` 由首/末 `timestamp` 派生;`messageCount` 重新计算;`model` 位于 `message` 内部(layer 2)。`cwd`/`model` 的捕获依赖于迭代直到遇到携带各自字段的记录 —— 适配器的"首个非空"循环(Swift:58-74)处理这种交错(user 记录携带 `cwd`,assistant 记录携带 `message.model`)。

### 5a. `toolUseResult` envelope (layer-4 nested object)

仅出现在内容块为 `tool_result` 的 `user` 行上。**实测键集(12 次出现完全一致):** `[status, timestamp, toolName]`。

| Field | Type | Meaning | Live value |
|---|---|---|---|
| `toolName` | string | 已执行工具的名称 | `"read_file"` |
| `status` | string | 执行状态;实测**始终 `"success"`**(12/12) | `"success"` |
| `timestamp` | number (epoch ms) | 工具完成时间 | `1772183500685` |

这只是元数据;实际结果载荷位于 `message.content[].tool_result` 块中(§7)。Engram 完全忽略它。

---

## 6. Message & content schema (layer 2-3, anonymized examples)

`message` 的形态取决于父行的 `type`。

### 6.1 `type: "user"` — `message` object (keys: `role, content`)

| Field | Type | Meaning | Optional | Consumed? | Example |
|---|---|---|---|---|---|
| `role` | string `"user"` | role | required | ❌(由行级 `type` 决定 role) | `"user"` |
| `content` | **string** OR array of content blocks | 用户 prompt(字符串)或工具结果投递(数组) | required | ✅(只扁平化 `text` 块;裸字符串逐字保留) | `"<prompt>"` 或 `[{type:"tool_result",…}]` |

实测:普通 prompt 的 user 轮其 `content` 为**字符串**;携带工具结果的 user 轮其 `content` 为**数组**,含一个或多个 `tool_result` 块(§7)。大会话:user 内容 = **12 数组 + 4 字符串**;小会话 = 1 数组 + 1 字符串。

### 6.2 `type: "assistant"` — `message` object (Anthropic shape, richest record)

**实测键集(全部 25 条 assistant 行一致):** `content, id, model, role, stop_reason, stop_sequence, type, usage`。

| Field | Type | Meaning | Optional | Consumed? | Example |
|---|---|---|---|---|---|
| `role` | string `"assistant"` | role | required | ❌ | `"assistant"` |
| `content` | array of content blocks | assistant 输出(text + tool_use) | required | ✅(只扁平化 `text`) | `[{type:"text",text:"…"},{type:"tool_use",…}]` |
| `model` | string | 产生该轮的模型 id | live: always | ✅ → 会话 `model`(首次出现) | `"glm-5"`(全部 25) |
| `usage` | object `{input_tokens, output_tokens}` | 每轮 token 用量(Anthropic 命名) | live: always(可能全为零) | ✅ **仅 Swift** | `{input_tokens:16472, output_tokens:224}` |
| `id` | string | Anthropic 消息 id | live: always | ❌ | `"r1"`(fixture)/ `msg_…` |
| `type` | string `"message"` | 内层消息种类 | live: always | ❌ | `"message"` |
| `stop_reason` | string \| null | Anthropic stop reason;实测**始终 `null`** | optional | ❌ | `null` |
| `stop_sequence` | string \| null | Anthropic stop sequence;实测**始终 `null`** | optional | ❌ | `null` |

### 6.3 Content blocks (layer 3 — `message.content[]`)

块判别字段 = 内层 `type`。**两文件实测直方图:** `text` ×10、`tool_use` ×30、`tool_result` ×12(大会话)+ 小会话的块。**不存在 `thinking`/`reasoning`/`redacted_thinking` 块** —— 已验证:内容类型直方图只含下列三种;iFlow 不向磁盘记录任何思维链。

| Block `type` | Keys | Consumed? | Notes |
|---|---|---|---|
| `text` | `{type:"text", text}` | ✅ | 非空 `.text` 连接:**`"\n\n"`(Swift,`IflowAdapter.swift:185`)** vs **`"\n"`(TS,`iflow.ts:204`)** —— 分隔符分歧 |
| `tool_use` | `{type:"tool_use", id, name, input}` | ❌ | assistant 发起工具运行的请求;丢弃(`toolCalls:nil` Swift:161) |
| `tool_result` | `{type:"tool_result", tool_use_id, content}` | ❌ | 位于 `user` 记录内;丢弃(只保留 `text`) |

`extractContent`(`IflowAdapter.swift:172-186`、`iflow.ts:194-207`):裸字符串 → 逐字使用;数组 → 连接 `type=="text"` 块中非空的 `.text`;否则 → `""`。**`tool_result` 块不贡献任何文本** → 扁平化为 `""`(见 §4 计数陷阱)。

#### `text` block
```json
{ "type": "text", "text": "<assistant prose>" }
```

#### `tool_use` block (assistant side of a call)
```json
{ "type": "tool_use", "id": "call_-7848967933605705235", "name": "list_directory", "input": { "path": "<abs path>" } }
```
- `id` —— call id;**链接到匹配的 `tool_result.tool_use_id`**。
- `name` —— 实测集合:`read_file`(16)、`task`(6)、`list_directory`(4)、`replace`(2)、`write_file`(2)。
- `input` —— 参数;形态因工具而异。**`task` = 子代理派发** —— 其 `input` 键为 `description, prompt, subagent_type`(实测 6 次),是 iFlow 原生的多代理机制。Engram **不**解析它(见 §7、§10)。

#### Layer 2/3 examples (anonymized; keys verbatim)
```json
// user turn (plain string content)
{ "uuid":"<uuid>","parentUuid":null,"sessionId":"session-041101e6-…",
  "timestamp":"2026-02-27T09:11:31.532Z","type":"user","isSidechain":false,"userType":"external",
  "message":{ "role":"user","content":"<short user prompt>" },
  "cwd":"/Users/<u>/-Code-/<project>","gitBranch":null,"version":"1.0.0" }

// assistant turn (content blocks + model + usage)
{ "isSidechain":false,"parentUuid":"<uuid>","sessionId":"session-041101e6-…",
  "timestamp":"2026-02-27T09:11:40.657Z","type":"assistant","userType":"external","uuid":"<uuid>",
  "message":{ "id":"<id>","type":"message","role":"assistant",
    "content":[ {"type":"text","text":"<reply>"},
                {"type":"tool_use","id":"<tuid>","name":"read_file","input":{"<args>"}} ],
    "model":"glm-5","stop_reason":null,"stop_sequence":null,
    "usage":{ "input_tokens":16472,"output_tokens":224 } } }
```

### 6.4 System-message detection (derived, not a line type)

`isSystemInjection`(Swift:166-170 / TS:154-160)在某 `user` 行的扁平化文本满足以下条件时将其重新归类为 **system**(→ `systemMessageCount++`,从 user 计数和摘要中排除):
- `hasPrefix("# AGENTS.md instructions for ")`,或
- `contains("<INSTRUCTIONS>")`,或
- `hasPrefix("<local-command-caveat>")`。

这三个标记字符串(`# AGENTS.md instructions for `、`<INSTRUCTIONS>`、`<local-command-caveat>`)**只存在于 Engram 自己的 `isSystemInjection` 启发式中**,而**不在** iFlow 的 bundle 里 —— 在官方源码中 grep 它们一无所获([source](https://www.npmjs.com/package/@iflow-ai/iflow-cli))。它们是 Engram 从 Claude/Codex 适配器借来的跨工具注入检测启发式,**不同于** Qwen 的(`"You are Qwen Code"`,`QwenAdapter.swift:223-224`);把它们的出现当作 iFlow 特有的血统信号会言过其实(真正的血统信号是 bundle 中的 Google LLC / Gemini-CLI 许可证头部)。真实库中有 **0** 条此类记录(`/init`、真实 prompt 等都是真正的 user 轮)。

---

## 7. Tool calls & results

工具调用以 `tool_use` 内容块形式存在于 **assistant** 记录中;配对的结果以 `tool_result` 块形式返回到**下一条 user** 记录的 `content[]` 里,带有相同的 `tool_use_id`(Anthropic 双轮拆分 —— **不是** Gemini 同址的 `toolCalls[].result[]`,也**不是** Qwen 的 `parts`)。该 user 记录的**顶层**还有一个冗余的 `toolUseResult` 对象(`{status, timestamp, toolName}`,§5a)。

### 7.1 `tool_result` block (on user lines)
```json
{ "type": "tool_result", "tool_use_id": "call_-7848967933605705235", "content": { /* nested object — layer 4 */ } }
```
- `tool_use_id` —— 回指产生它的 `tool_use.id`。
- `content` —— 一个**对象**(非 string/array),是嵌套的 Gemini 风格结果信封。**实测键集(全部 12):`[callId, responseParts, resultDisplay]`。**
- `is_error` —— **所有真实数据中均缺失**;若存在则标记一次失败的工具调用。

### 7.2 `tool_result.content` — nested result envelope (layer 4, Gemini-CLI lineage)
```json
{ "callId": "call_-7848967933605705235",
  "responseParts": { "functionResponse": { "id":"call_…","name":"list_directory","response":{ "output":"<result>" } } },
  "resultDisplay": "<human-readable result>" }
```
- `callId` —— == `tool_use_id` == `tool_use.id`(全部 12 个结果三方确认相等)。
- `responseParts` —— 始终为 `{ functionResponse: {…} }` —— 即 **Gemini `functionResponse` 形态**(layer 5)。
- `resultDisplay` —— **字符串或对象**。实测:**10/12 为字符串**(如 `"Listed 7 item(s)."`);**2/12 为对象**,键为 `[fileDiff, fileName, newContent, originalContent]`(用于 `write_file`/`replace` 的编辑 diff)。

### 7.3 `functionResponse` (layer 5, deepest)
```json
{ "id":"call_…","name":"read_file","response":{ "output":"<file contents>" } }
```
键:`id, name, response`。`response` = `{output: <string>}`(全部 12 个实测 `output` 均为字符串)。

### Tool-call ↔ result linkage chain (5 layers)
```
assistant.message.content[].tool_use.id
   ═══ equals ═══  user.message.content[].tool_result.tool_use_id
   ═══ equals ═══  tool_result.content.callId
   ═══ equals ═══  tool_result.content.responseParts.functionResponse.id
```

**Engram 不导入其中任何内容。** Swift 设 `toolCalls:nil`(`IflowAdapter.swift:161`);TS `streamMessages` 从不产出工具块(`iflow.ts:144-150` 只产出 role/content/timestamp)。`toolMessageCount: 0`(Swift:103 / TS:110)。工具结果文本被 `extractContent` 丢弃。Parity `success.expected.json` 通过 `toolCalls: []` 和 `fileToolCounts: {}` 编码零工具导入(期望文件中**没有** `toolCallCount` 键 —— 其 16 个顶层键不包含它)。工具调用完整地存在于磁盘上,但在 Engram 中不可见。

---

## 8. Reasoning / thinking

**iFlow 不适用。** 真实数据或 fixtures 中均未观察到 `thoughts`/`thinking`/`reasoning`/`redacted_thinking` 记录或内容块(assistant 内容块只有 `text` + `tool_use`)。iFlow 不向磁盘记录任何思维链。即便 iFlow 某天发出 Anthropic `thinking` 块,适配器也会丢弃它们(`extractContent` 只保留 `type=="text"`)。

---

## 9. Token usage & cost

每轮用量位于 **assistant** 记录的 `message.usage` 中(layer 3)。**Anthropic 字段命名**:仅 `input_tokens`、`output_tokens` —— **没有** `cache_read_input_tokens` / `cache_creation_input_tokens` / `total`(所有 assistant 轮的实测键并集 = `["input_tokens","output_tokens"]`)。

```json
"usage": { "input_tokens": 16472, "output_tokens": 224 }
```

| Field | Type | Meaning | Engram (Swift) mapping |
|---|---|---|---|
| `input_tokens` | int | Prompt/输入 token | `TokenUsage.inputTokens` |
| `output_tokens` | int | Completion token | `TokenUsage.outputTokens` |
| `cache_read_input_tokens` | int | (Anthropic 风格)—— iFlow 中**缺失** | — |
| `cache_creation_input_tokens` | int | (Anthropic 风格)—— iFlow 中**缺失** | — |

**推导**(Swift `usage()` `IflowAdapter.swift:188-198`):
- `inputTokens = input_tokens`,`outputTokens = output_tokens`(不读取缓存字段 —— 注意 iFlow **不**使用同时解析缓存 token 的共享 `JSONLAdapterSupport.usage`,因此即便 iFlow 发出缓存字段也会被忽略)。
- 若**两者**都为 0 则返回 `nil`(`:194-196`)。用量**仅附加于 assistant** 轮(`:162`);user 轮携带 `usage:nil`。

> **差异标注。**
> 1. **TS 参考适配器丢弃全部 token 用量** —— `iflow.ts` 中任何位置都没有 `usage`/`tokens` 处理(`streamMessages` 只产出 `{role,content,timestamp}`,`:144-150`)。Swift 是**唯一**产出 iFlow cost/usage 的路径。(与 Gemini、Qwen 相同的 TS-vs-Swift 分裂。)
> 2. **实测用量绝大多数为零。** 238 KB GLM 会话中全部 25 个 assistant 轮都报告 `{input_tokens:0, output_tokens:0}` → `>0` 守卫使 Swift 在这些轮上的用量为 `nil`。GLM 代理在那里报告零计数。**非零是可能的**:小会话最后一个 assistant 轮为 `{input_tokens:16472, output_tokens:224}`。parity fixture 的 `usage:{}` 为空,产生全零 `usageTotals` —— 它**掩盖**了该分歧而非测试提取逻辑。

不存储任何 price/cost;Engram 在下游计算成本。

---

## 10. Subagent / parent-child / dispatch

**文件内链接存在但被忽略。** 每条记录有 `parentUuid`/`uuid` 构成会话内 DAG,`isSidechain:bool` 标记子代理 sidechain —— 两者都是 **Anthropic 风格**。两个适配器都不读取它们。iFlow 原生的多代理机制是 `task` 工具(`tool_use`,带 `input.{description,prompt,subagent_type}`,实测 6 次)—— 但它与所有其他工具数据一同被丢弃(`toolCalls:nil`,`toolMessageCount:0`)。

**跨会话父级链接:无内建机制,无 sidecar。** 不同于 Gemini(Layer 1c `<sessionId>.engram.json` sidecar)和 Codex(`originator`),iFlow 适配器将 `parentSessionId:nil`、`suggestedParentId:nil`、`originator:nil`、`agentRole:nil`、`origin:nil`(`IflowAdapter.swift:109-116`)。iFlow **没有 `readSidecar`**,真实环境中也有 **0** 个 `*.engram.json` 文件。iFlow 会话的任何父级归属完全依赖 Engram 的 **Layer 2 启发式**(时间/cwd 评分)—— iFlow 不存在确定性的链接路径。

---

## 11. Summary / compaction

**磁盘上不适用** —— 未观察到 summary/compaction 记录类型(2 个真实会话中均无 `system`/`summary`/`info` 行类型,二者均未被压缩)。Engram 自行合成会话**摘要**:取首个非 system 的 `user` 消息的扁平化文本,截断至 200 字符(`summary: firstUserText.isEmpty ? nil : String(firstUserText.prefix(200))` `IflowAdapter.swift:105`;`firstUserText.slice(0,200) || undefined` `iflow.ts:112`)。派生而来,非存储。

边界情况:若首个 user 轮是仅含工具结果的消息(空文本),`firstUserText` 会保持 `""` 直到后续出现带文本的 user 轮(见 §15 #4)。

---

## 12. SQLite / DB internals

**iFlow 不适用。** 会话是纯粹的逐行追加 JSONL 文件;`~/.iflow` 下任何位置都没有 SQLite、leveldb 或 gRPC 缓存(区别于 VS Code 的 `.vscdb`/leveldb 系列)。`find ~/.iflow` 只返回 JSON/JSONL/log/text 文件。

---

## 13. Auxiliary files

真实存在但**不被消费**:

| File | Shape | Example (anonymized) | Notes |
|---|---|---|---|
| `~/.iflow/config/projects.json` | `{ "<encodedDir>": { name, path, sessions[], createdAt, lastActivity } }` | `{ "-Users-<u>-Code-coding-memory": { "name":"…","path":"…","sessions":["session-041101e6-…"],"createdAt":"…Z","lastActivity":"…Z" } }` | iFlow 项目注册表。**适配器从不读取**(`project:nil`)。以**编码后**的目录名(非绝对 cwd)作为键/值。`sessions[]` 持有裸 `session-<UUID>` id。**实测注册表不完整** —— 只列出 2 个磁盘项目中的 1 个,且其键(`-Users-bing-Code-coding-memory`)与任何磁盘目录名都不匹配。 |
| `~/.iflow/tmp/<64hex>/logs.json` | array of `{ sessionId, messageId:int, type, message, timestamp }` | `{ "sessionId":"session-b5785972-…","messageId":0,"type":"user","message":"<preview>","timestamp":"…Z" }` | 轻量级每消息遥测;`messageId` = 会话内基于 0 的整数序列;只存储 user 消息预览。被忽略。`<64hex>` 目录名是不透明的(既非会话 UUID,也非可识别的 cwd 哈希)。 |
| `~/.iflow/log/console-*.log` | text | — | CLI 控制台日志。被忽略。 |
| `~/.iflow/settings.json` | `{ apiKey, baseUrl, bootAnimationShown, cna, modelName, searchApiKey, selectedAuthType }` | — | CLI 配置 + GLM 的 `baseUrl`/`apiKey`/`modelName`。**含密钥** —— 非会话数据。从不读取。 |
| `~/.iflow/{oauth_creds,iflow_accounts}.json`、`installation_id`、`cache/`、`skills/` | auth/identity/runtime | — | 从不读取。 |
| **(absent)** `~/.iflow/projects.json` | — | — | iFlow **不存在**该文件(Gemini 有一个顶层的;iFlow 的注册表在 `config/projects.json`)。适配器对两者都不查找。 |

---

## 14. Engram mapping

`source field/record → Engram Session field → adapter file:line`。(Swift = `IflowAdapter.swift`;TS = `iflow.ts`。)

| Engram field | Source field/record | Swift file:line | TS file:line | Notes |
|---|---|---|---|---|
| `id` | 首个 `sessionId`(逐字,含 `session-` 前缀) | `:58-60, 93` | `:73, 101` | 必需(否则 `.malformedJSON` :89 / `null` :98) |
| `source` | constant | `:4, 94` | `:16, 102` | `.iflow` / `'iflow'` |
| `startTime` | 首条记录 `timestamp` | `:64-66, 95` | `:75, 103` | required |
| `endTime` | 末条记录 `timestamp`(若 == start 则为 nil) | `:67-69, 96` | `:76, 104` | optional |
| `cwd` | 文件内首个非空 `cwd` 字段 | `:61-63, 97` | `:74, 105` | 实测仅来自 **user 记录**;不从目录名解码 |
| `project` | **`nil`**(从不派生) | `:98` | (omitted) | 编码目录名不解码;`decodeCwd` 是死代码 |
| `model` | 首个 `message.model` | `:71-74, 99` | `:79-81, 106` | **被呈现**(实测 `glm-5`)—— 不同于 Gemini(始终 nil) |
| `messageCount` | `userCount + assistantCount` | `:100` | `:107` | **包含工具结果 user 轮**;排除 system-injection;工具块不计数 |
| `userMessageCount` | `type=="user"` 且非 system-injection | `:82-84, 101` | `:88-92, 108` | 空/工具结果内容仍计数 |
| `assistantMessageCount` | `type=="assistant"` | `:76-77, 102` | `:83-84, 109` | |
| `toolMessageCount` | constant `0` | `:103` | `:110` | 工具块从不计为消息 |
| `systemMessageCount` | system-injection user 记录 | `:80-81, 104` | `:87-89, 111` | AGENTS.md / `<INSTRUCTIONS>` / `<local-command-caveat>` |
| `summary` / title | 首个非 system user 文本,`prefix(200)` | `:84, 105` | `:91-93, 112` | 空 → nil |
| `filePath` | locator | `:106` | `:113` | |
| `sizeBytes` | 文件大小 | `:107` | `:114` | Swift `JSONLAdapterSupport.fileSize`;TS `stat.size` |
| `agentRole` / `originator` / `origin` | `nil` | `:109-111` | (omitted) | iFlow 无派发检测 |
| `parentSessionId` / `suggestedParentId` | `nil` | `:115-116` | (omitted) | 无 sidecar;仅 Layer 2 启发式 |
| `summaryMessageCount` / `tier` / `qualityScore` / `indexedAt` | `nil` | `:108, 112-114` | (omitted) | 下游设置,非适配器设置 |
| **per-msg** `role` | `type=="user"`→`.user`,否则 `.assistant` | `:158` | `:145-149` | |
| **per-msg** `content` | `extractContent(message.content)`(连接 `text` 块;裸字符串逐字) | `:159, 172-186` | `:147, 194-207` | tool_result/tool_use 不产出文本;分隔符 **`\n\n` Swift vs `\n` TS** |
| **per-msg** `timestamp` | 记录 `timestamp` | `:160` | `:148` | |
| **per-msg** `usage` | assistant `message.usage` → `TokenUsage{input_tokens,output_tokens}` | `:162, 188-198` | **none** | **仅 Swift**;两者都为 0 则 nil |
| **per-msg** `toolCalls` | `nil`(丢弃) | `:161` | (none) | 工具数据不呈现 |

**Engram 不消费的内容:** `config/projects.json`(整个注册表)、`tmp/.../logs.json`、编码目录名(`project:nil`,`decodeCwd` 死代码);每条记录的 `uuid`/`parentUuid`/`isSidechain`/`userType`/`gitBranch`/`version`/`toolUseResult`;assistant 的 `message.id`/`message.type`/`stop_reason`/`stop_sequence`;所有 `tool_use` & `tool_result` 块(及 5 层链接链);以及(TS 路径)全部 token 用量。磁盘上没有信封级 `messageCount`/`model` 可消费 —— `messageCount` 重新计算,`model` 从 `message` 内部读取。

---

## 15. Lineage, gotchas, version drift & edge cases

### Shared-format lineage — iFlow is a THREE-WAY HYBRID

iFlow 介于 Anthropic 家族与 Gemini/Qwen 家族之间:

| Dimension | iFlow | Gemini CLI ([`gemini-cli.md`](./gemini-cli.md)) | Qwen Code | Lineage verdict |
|---|---|---|---|---|
| Root | `~/.iflow/projects/` | `~/.gemini/tmp/` | `~/.qwen/projects/` | Qwen-shaped (`projects/`) |
| Layer below project dir | **flat** `session-*.jsonl` | `chats/session-*.json` | `chats/*.jsonl` | **unique**(无 `chats/`) |
| File format | **JSONL append-per-line** | single-object `.json`(legacy)/ `$set` `.jsonl`(new) | JSONL append-per-line | Qwen-shaped |
| Filename | `session-<UUID>.jsonl` | `session-<ts>-<8hex>.json` | any `*.jsonl` | **unique**(完整 UUID,要求 `session-`) |
| in-file `sessionId` | `session-<full-UUID>`(== stem) | name 中为 `sessionId[0:8]` | varies | **unique**(完整 id,带前缀) |
| Record types | `user`/`assistant` | `user`/`gemini`/`model`/`info` | `user`/`assistant`(`model` role) | Qwen-ish |
| Content shape | `message.content` string OR `[{type:"text"\|"tool_use"\|"tool_result"}]` **Anthropic blocks** | `content` string OR `[{text}]` / `messages[].parts[]` | `message.parts[].text` | **Anthropic**(非 Gemini/Qwen) |
| Tool model | `tool_use`/`tool_result` blocks(Anthropic split) | `toolCalls[].result[]` co-located | (in parts) | **Anthropic split** |
| Tool-result inner payload | `{callId, responseParts:{functionResponse}, resultDisplay}` | `functionResponse{id,name,response{output}}` | (Gemini parts) | **Gemini-CLI** |
| Reasoning on disk | **none**(无 thinking 块) | `thoughts`(被 Engram 丢弃) | parts may carry thought | — |
| Token usage | `message.usage.{input_tokens,output_tokens}` **Anthropic** | `tokens.{input,output,cached,…}` | `usageMetadata.{promptTokenCount,…}` / `ui_telemetry` | **Anthropic** |
| System-injection markers | `AGENTS.md` / `<INSTRUCTIONS>` / `<local-command-caveat>` **Claude-flavored** | (none) | `You are Qwen Code` | **Claude/Anthropic** |
| `projects.json` map | **none**(注册表在 `config/projects.json`,被忽略) | yes(top-level) | none(uses dir) | unique |
| Codebase lineage | **Gemini CLI fork**(`bundle/iflow.js` 中有 `Copyright … Google LLC` SPDX 头部、`google.gemini-cli` 引用) | Gemini CLI(原始) | Gemini CLI fork | **Gemini-CLI fork** |
| Models run | **多模型**:默认 `glm-4.7` + `Qwen3-Coder-Plus`;另有 Kimi K2、DeepSeek v3.2、GLM-4.6、任意 OpenAI 兼容端点(真实样本恰好用了 `glm-5`) | Gemini | Qwen | — |

**结论:** 在**代码库**层面,iFlow 是一个 **Gemini CLI fork** —— 由官方 `bundle/iflow.js` 中的 `Copyright 2025/2026 Google LLC` SPDX 头部及 `google.gemini-cli` 引用确认([source](https://www.npmjs.com/package/@iflow-ai/iflow-cli))。它**不是** Claude-Code 衍生的。在该 Gemini-CLI 代码库之上,它有意叠加了一层 **Anthropic / Claude-Code 转录信封**(内容块、用量命名、`parentUuid`/`isSidechain` DAG;注入标记是 Engram 的启发式,而非 iFlow 自身的 —— 见 §6.4),披着 **Qwen 风格目录外皮**(`~/.tool/projects/<encoded-dir>/`),并保留 **Gemini-CLI 工具结果内核**(`callId`/`responseParts`/`functionResponse`)。它在*转录 schema* 层面**不是** Gemini 的分支,尽管在*代码库*层面它确实是 Gemini 的分支。iFlow 是**多模型**的(默认 `glm-4.7` + `Qwen3-Coder-Plus`,外加 Kimi K2 / DeepSeek v3.2 / GLM-4.6 / 任意 OpenAI 兼容端点),并非 GLM-only;真实样本只是恰好运行了 `glm-5`。`IflowAdapter` 的代码结构是从 Qwen/Gemini 同级模板复制而来(相同的 `JSONLAdapterSupport`、相同的 `parseSessionInfo` 骨架),这也是死代码 `decodeCwd` 辅助器残留的原因。Engram 之所以能正确处理 iFlow,是因为它把它当作拥有 Anthropic 形态 `content`/`usage` 提取逻辑的独立适配器来对待 —— 规避了血统陷阱(把它当作 Gemini `{text}`/`tokens` 来解析)。**注意:** iFlow CLI 官方将于 2026-04-17(北京时间)关停;官方建议用户迁移至 Qoder([source](https://platform.iflow.cn/en/cli/changelog))。

### Gotchas / version drift / edge cases

1. **`messageCount` 随工具轮次膨胀。** 仅含工具结果的 `user` 记录(无 `text`)被计为 user 消息(无空内容跳过)。实测:16 条 "user" 记录中有 12 条是工具结果 → `userMessageCount`=16,`messageCount`=41(= 行数)。Engram 的计数 ≠ 真实人类 prompt 的数量。
2. **编码目录名是有损的,且从不用于 cwd。** `Sources.swift encodeIflow`(`:489-499`)剥除每段前导/尾随破折号,故 `/Users/u/-Code-/engram` → `-Users-u-Code-engram`(`-Code-` 的破折号消失)。适配器自带的 `decodeCwd`(`:143-148`,TS `:163-168`)使用*不同的*方案(`--`→哨兵,`-`→`/`)且是**死代码**(从未被调用)。编码器/解码器并非互逆;目录名无法往返还原为 cwd。Engram 通过信任文件内 `cwd` 来规避。项目迁移 docstring(`Sources.swift:484-488`)标注了这种有损性,并指出一次预检 cwd 探测会捕获冲突。
3. **`id` 包含 `session-` 前缀。** 存储的 `id` = `session-<UUID>`,而非裸 UUID。按原始 UUID 进行的跨工具联结 / 父级检测必须考虑该前缀。
4. **仅含工具结果的 user 轮被计为空内容 user 消息。** 一条 `content` 为 `[{type:"tool_result",…}]` 的 `user` 记录扁平化为 `""`(只保留 `text` 块)。`isSystemInjection("")` 为 false → 它以空内容递增 `userCount`,并在 `streamMessages` 中贡献一条空内容消息(Swift 在此**不**预过滤空内容,不同于 Gemini)。若首个 user 轮仅含工具结果,合成的 `summary` 会保持空白直到后续出现带文本的 user 轮。
5. **`cwd` 只出现在 `user` 记录上。** 实测:`cwd`/`gitBranch`/`version` 出现在 16/16 条 user 记录上,0/25 条 assistant 记录上。一个没有 user 记录(全为 assistant)、或 iFlow 停止发出 `cwd` 的会话会产出 `cwd=""`(适配器只从首个携带 `cwd` 的记录读取它)。在当前数据下属假设情况;特此标注。
6. **`model` 被呈现(好事)—— 但只取第一个。** 不同于 Gemini(始终 nil),iFlow 报告 `model`(实测 `glm-5`)。只保留**第一个** assistant `model`;中途切换模型的会话只报告第一个。
7. **Token 用量仅 Swift 有,且常为零。** TS 丢弃全部用量。Swift 读取 `input_tokens`/`output_tokens`,两者都为 0 时返回 nil —— 而实测 GLM 代理在 238 KB 会话的 25 轮上均报告 0,因此即便在 Swift 路径上,实践中用量也常常缺失。非零是可能的(小会话第 4 行:16472/224)。
8. **文本连接分隔符在 Swift 与 TS 间漂移。** Swift 用 `"\n\n"` 连接多文本块内容(`:185`);TS 用 `"\n"`(`:204`)。同一个多段 assistant 轮在两个解析器下渲染不同。
9. **TS 无大小/行数/消息上限;Swift 上限 100 MB / 8 MB / 10,000。** 一个病态的大 iFlow 文件会被 Swift 跳过(`.fileTooLarge` > 100 MB),但被 TS 完整流式读取。(TS 版 iFlow 也缺少 Gemini-TS 的 10 MB 上限。)
10. **文件身份守卫(仅 Swift)。** 若文件在读取中途变化,Swift 抛出 `.fileModifiedDuringParse` —— 一个正在被追加的真实会话可能失败并稍后重试。相比 Gemini,iFlow 更易触发,因为 iFlow 每轮都真正追加。
11. **`config/projects.json` 不可靠且被忽略。** 实测注册表只列出 2 个磁盘项目中的 1 个,且使用的键与任何磁盘目录名都不匹配;Engram 无论如何都不读取它。
12. **无确定性父级链接。** 没有 `*.engram.json` sidecar,没有 `originator`。`isSidechain`/`parentUuid` 在磁盘上但被忽略;跨会话归属完全依赖 Engram 的 Layer 2 启发式。
13. **Schema 漂移容忍。** `schema_drift.jsonl` fixture 确认未知顶层键(`newTopField`)和未知嵌套键(`futureUserField`、`newAssistantProp`、`responseQuality`)会被优雅忽略;未来的 `model:"iflow-v2"` 和 `version:"2.0.0"` 都能正常解析。适配器是前向容忍的。

---

## 16. Appendix: real anonymized samples

> 键逐字保留;消息文本、代码、密钥、个人路径已剥除。

### 16.1 Live `.jsonl` session — user (string) + assistant (blocks + usage) + tool-result user

```jsonl
{"uuid":"<uuid>","parentUuid":null,"sessionId":"session-041101e6-2a7f-4dfd-90b0-57888a353f6a","timestamp":"2026-02-27T09:11:31.532Z","type":"user","isSidechain":false,"userType":"external","message":{"role":"user","content":"<short user prompt>"},"cwd":"/Users/<u>/-Code-/<project>","gitBranch":null,"version":"1.0.0"}
{"isSidechain":false,"parentUuid":"<uuid>","sessionId":"session-041101e6-…","timestamp":"2026-02-27T09:11:40.657Z","type":"assistant","userType":"external","uuid":"<uuid>","message":{"id":"<id>","type":"message","role":"assistant","content":[{"type":"text","text":"<reply>"},{"type":"tool_use","id":"<tuid>","name":"<tool>","input":{}}],"model":"glm-5","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":0,"output_tokens":0}}}
{"uuid":"<uuid>","parentUuid":"<uuid>","sessionId":"session-041101e6-…","timestamp":"2026-02-27T09:11:40.712Z","type":"user","isSidechain":false,"userType":"external","message":{"role":"user","content":[{"tool_use_id":"<tuid>","type":"tool_result","content":{}}]},"cwd":"/Users/<u>/-Code-/<project>","gitBranch":null,"version":"1.0.0","toolUseResult":{}}
{"isSidechain":false,"parentUuid":"<uuid>","sessionId":"session-041101e6-…","timestamp":"2026-02-27T09:11:51.232Z","type":"assistant","userType":"external","uuid":"<uuid>","message":{"id":"<id>","type":"message","role":"assistant","content":[{"type":"text","text":"<reply>"}],"model":"glm-5","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":16472,"output_tokens":224}}}
```

### 16.2 Live tool_result block — full 5-layer nesting (large session)

```json
{ "type":"user","sessionId":"session-b5785972-…","timestamp":"…Z","uuid":"<uuid>","parentUuid":"<uuid>",
  "isSidechain":false,"userType":"external","cwd":"/Users/<u>/-Code-/<project>","gitBranch":null,"version":"1.0.0",
  "message":{ "role":"user","content":[
    { "type":"tool_result","tool_use_id":"call_-7848967933605705235","content":{
        "callId":"call_-7848967933605705235",
        "responseParts":{ "functionResponse":{ "id":"call_-7848967933605705235","name":"list_directory","response":{ "output":"Listed N item(s)." } } },
        "resultDisplay":"Listed N item(s)." } } ] },
  "toolUseResult":{ "toolName":"list_directory","status":"success","timestamp":1772183500685 } }
```

### 16.3 `config/projects.json` (registry; ignored)

```json
{ "-Users-<u>-Code-coding-memory": {
    "name":"-Users-<u>-Code-coding-memory","path":"-Users-<u>-Code-coding-memory",
    "sessions":["session-041101e6-2a7f-4dfd-90b0-57888a353f6a"],
    "createdAt":"2026-02-27T09:11:31.503Z","lastActivity":"2026-02-27T09:11:31.503Z" } }
```

### 16.4 `tmp/<64hex>/logs.json` row (telemetry; ignored)

```json
{ "sessionId":"session-b5785972-…-e361146f8e79","messageId":0,"type":"user","message":"<preview>","timestamp":"…Z" }
```

### 16.5 Parity fixture input (`adapter-parity/iflow/input/-Users-test-my-project/session-sample.jsonl`)

```jsonl
{"uuid":"aa-001","parentUuid":null,"sessionId":"session-iflow-001","timestamp":"2026-01-20T09:00:00.000Z","type":"user","isSidechain":false,"userType":"external","message":{"role":"user","content":"<user prompt>"},"cwd":"/Users/test/my-project","gitBranch":"main","version":"1.0.0"}
{"uuid":"aa-002","parentUuid":"aa-001","sessionId":"session-iflow-001","timestamp":"2026-01-20T09:00:05.000Z","type":"assistant","isSidechain":false,"userType":"external","message":{"id":"r1","type":"message","role":"assistant","content":[{"type":"text","text":"<reply>"}],"model":"glm-5","stop_reason":null,"stop_sequence":null,"usage":{}},"cwd":"/Users/test/my-project","gitBranch":"main","version":"1.0.0"}
{"uuid":"aa-003","parentUuid":"aa-002","sessionId":"session-iflow-001","timestamp":"2026-01-20T09:01:00.000Z","type":"user","isSidechain":false,"userType":"external","message":{"role":"user","content":"<user reply>"},"cwd":"/Users/test/my-project","gitBranch":"main","version":"1.0.0"}
```

### 16.6 Parity expected (`success.expected.json`, key fields)

```json
{
  "sessionInfo": {
    "id": "session-iflow-001", "source": "iflow",
    "cwd": "/Users/test/my-project",
    "startTime": "2026-01-20T09:00:00.000Z", "endTime": "2026-01-20T09:01:00.000Z",
    "model": "glm-5",
    "messageCount": 3, "userMessageCount": 2, "assistantMessageCount": 1,
    "toolMessageCount": 0, "systemMessageCount": 0,
    "summary": "<first user prompt>", "sizeBytes": 1031
  },
  "projectFields": { "cwd": "/Users/test/my-project", "project": null, "source": "iflow" },
  "toolCalls": [], "fileToolCounts": {},
  "usageTotals": { "inputTokens": 0, "outputTokens": 0, "cacheReadTokens": 0, "cacheCreationTokens": 0 }
}
```

### 16.7 Schema-drift fixture (`tests/fixtures/iflow/schema_drift.jsonl`, forward-tolerance)

```jsonl
{"type":"user","message":{"role":"user","content":"Hello","futureUserField":"ignored"},"timestamp":"2026-03-22T10:00:00.000Z","sessionId":"drift-iflow","cwd":"/test","version":"2.0.0","uuid":"uuid-1","newTopField":"data"}
{"type":"assistant","message":{"role":"assistant","content":"Hi there!","model":"iflow-v2","newAssistantProp":"ignored"},"timestamp":"2026-03-22T10:00:01.000Z","sessionId":"drift-iflow","cwd":"/test","version":"2.0.0","uuid":"uuid-2","responseQuality":{"score":95}}
```

---

## Open questions / unverified

以下大多数已于 2026-06-21 对照官方 iFlow CLI bundle(`@iflow-ai/iflow-cli` v0.5.19,`bundle/iflow.js`)及官方文档核实。

- **iFlow 是否曾写入 `system`/`summary`/`info` 行类型**(例如在压缩或上下文初始化时)?**Confirmed (official):** 没有新的顶层类型。writer 的 `createCompressionMessage`(压缩/上下文摘要)与 `createMetaMessage` 都以**顶层 `type:"user"`** 发出记录(meta 携带 `isMeta:true`,压缩携带压缩标记);writer 中任何位置都没有 `type:"system"` / `summary` / `info`。因此压缩/meta 记录伪装成 `user` 记录存在于磁盘上并被计为 user 消息 —— 见 §4([source](https://www.npmjs.com/package/@iflow-ai/iflow-cli))。
- **`~/.iflow/tmp/<64hex>/` 的键是什么?** **Confirmed (official):** 它是 `tmp/<project_hash>/`,其中 `project_hash` 是项目根路径的确定性哈希(不是会话 UUID,也不是可读出 cwd 的字符串)。同一哈希也作为 `tmp/<hash>/shell_history` 的键,检查点存储于 `snapshots/<project_hash>` 和 `cache/<project_hash>/checkpoints`;bundle 还确认了一个 `logs.json` 遥测 logger(`sessionId`/`messageId` 字段)。具体哈希算法未文档化,但它是从项目根确定性派生的,而非不透明随机值([docs](https://platform.iflow.cn/en/cli/configuration/settings)、[checkpointing](https://platform.iflow.cn/en/cli/features/checkpointing)、[bundle](https://www.npmjs.com/package/@iflow-ai/iflow-cli))。
- **assistant 的 `message.content` 是否可能是裸字符串**(而非块数组)?(web-checked 2026-06-21: no authoritative source found)—— `createAssistantMessage` 从模型轮设置 `content`,但 bundle 并不保证它在磁盘上始终是数组;实测 + parity fixture 始终是数组,drift fixture 使用字符串。两个适配器都做了防御性处理,因此无论如何行为都是安全的。
- **`toolUseResult.status` 的完整枚举** —— **Confirmed (official, partial):** `toolUseResult` 是一个真实的信封字段,在工具结果 `user` 记录上携带 `toolName`(及 `status`),Gemini 血统的内容信封为 `{callId, responseParts:{functionResponse:{id,name,response}}, resultDisplay}`。出错时 `functionResponse.response` 携带一个 `{error:…}` 对象,`resultDisplay` 携带错误消息,还有一个 `errorType` 字段。除已观察到的 `"success"` 之外 `status` 的完整字符串集,以及 `tool_result` 块上是否会设置 `is_error`,均未能确定。无论如何 Engram 都忽略这一切([source](https://www.npmjs.com/package/@iflow-ai/iflow-cli))。
- **是否曾发出 `isSidechain:true`**(子代理轮)?**Confirmed (official):** `isSidechain` 是一个真实、可设置的字段 —— 每个消息创建器都写 `isSidechain: opts?.isSidechain ?? false`,即默认 `false` 但会被设为调用方的值。iFlow 有原生子代理机制(它为子代理会话生成 `subagent-${instanceId}-…` 和 `session-${d}` 形式的 id),因此 `isSidechain:true` 是可发出的;"实测始终 false" 只是样本产物([source](https://www.npmjs.com/package/@iflow-ai/iflow-cli))。Engram 是否应消费 `parentUuid`/`isSidechain` 属于 (Engram-internal design — not web-verifiable)。
- **`version` 的含义/作用**(实测 user 记录上为 `"1.0.0"`,drift fixture 为 `"2.0.0"`)—— **Confirmed (official, partial):** `version` 由 `collectContext()` 以 `this.getVersion()`(iFlow CLI 版本字符串)逐记录捕获,与 `cwd`/`gitBranch`/`timestamp` 一同写入。它是写入该记录的 CLI 版本,**而非** schema 格式版本或演进门控;Engram 忽略它是正确的([source](https://www.npmjs.com/package/@iflow-ai/iflow-cli))。
- **iFlow 是否会在任何版本中填充缓存 token 字段或 `thinking` 块?** **Confirmed (official, partial):** bundle 在内部用量聚合中引用了 `cache_creation_input_tokens` / `cache_read_input_tokens`,但 `createAssistantMessage` 将 `usage` 持久化为 `(e.usage || {input_tokens:0, output_tokens:0})` —— 因此默认/骨架是两字段的 Anthropic 形态;只有当 provider 返回时缓存计数才会出现。iFlow 支持"思考模式"模型(文档提及 glm-4.6 / deepseek-3.2),故可能产生推理,但在持久化记录 writer 中未确认存在 `thinking`/`reasoning` 内容块类型。若它们出现,Engram 都会丢弃([source](https://www.npmjs.com/package/@iflow-ai/iflow-cli)、[docs](https://platform.iflow.cn/en/cli/configuration/settings))。
- **全零用量是 GLM 代理的产物,还是 iFlow 在大规模下确实报告真实计数?** **Confirmed (official, partial):** assistant `usage` 默认为 `{input_tokens:0,output_tokens:0}`,当 provider 响应中存在 `e.usage` 时被覆盖。零意味着该 provider/轮次未返回用量;非零直接来自模型响应(与小会话的 16472/224 一致)。某个 provider/端点是否返回用量取决于 provider,而非 iFlow 格式的保证 —— "非零可能,覆盖未验证" 仍是正确的框定([source](https://www.npmjs.com/package/@iflow-ai/iflow-cli))。
- **未来的 iFlow 版本是否会添加顶层 `projects.json` 或 `chats/` 子目录**(向 Qwen/Gemini 收敛)?**Refuted / moot。** iFlow CLI 官方将于 2026-04-17 关停(迁移至 Qoder),因此预期没有未来收敛。截至最终阶段的 v0.5.x 源码,布局是扁平的 `projects/<encoded>/session-*.jsonl`,注册表位于 `config/projects.json`,没有顶层 `projects.json`,也没有 `chats/` 子目录 —— 与本文相符;没有任何计划中 `chats/` 迁移的证据([changelog](https://platform.iflow.cn/en/cli/changelog)、[bundle](https://www.npmjs.com/package/@iflow-ai/iflow-cli))。
- **项目注册表是否在 `config/projects.json`(而非顶层 `projects.json`)?** **Confirmed (official):** bundle 将注册表路径构造为 `join(getIflowDir(),'config','projects.json')`;顶层 `~/.iflow/projects.json` 不存在([source](https://www.npmjs.com/package/@iflow-ai/iflow-cli))。
- **编码后的项目目录名是否有损?** **Confirmed (official):** `getProjectName()` → `fromPath(projectRoot)` 运行一串 `.replace()` 调用,最后以 `.replace(/-+/g,'-')` 结尾,它**折叠连续的破折号**,因此 `-Code-` 不可恢复 —— 正是 §2/§15 #2 中观察到的往返失败;信任文件内 `cwd`(`project:nil`)是正确的([source](https://www.npmjs.com/package/@iflow-ai/iflow-cli))。
- **磁盘布局是否为扁平的 `projects/<encoded>/session-<UUID>.jsonl`,且 `sessionId` 带前缀?** **Confirmed (official):** `findSessionJsonlFile` 构造 `join(iflowDir,'projects',projectName,'session-${id}.jsonl')`,带一个裸 `${id}.jsonl` 回退且没有 `chats/` 拼接;`generateSessionId()` 返回 `` `session-${uuid()}` `` 并写入每条记录的 `sessionId`,故 `sessionId` == 文件名主干且带 `session-` 前缀。未文档化的 `projects/` 存储经源码 + 真实磁盘确认为真实(官方文档只提及 `settings.json`、`tmp/<project_hash>`、`snapshots/<project_hash>`、`cache/<project_hash>/checkpoints`)([source](https://www.npmjs.com/package/@iflow-ai/iflow-cli))。
- **iFlow 的转录 schema 是否为 Anthropic/Claude-Code JSONL 线格式,带 Gemini-CLI 工具结果内核?** **Confirmed (official):** 记录为 `{uuid, parentUuid, sessionId, timestamp, type:'user'|'assistant', isSidechain, userType:'external', message, cwd, gitBranch, version, toolUseResult?}`(Anthropic 信封);assistant `message` 为 `{id, type:'message', role:'assistant', content:[…], usage:{input_tokens,output_tokens}}`;工具结果使用 Gemini-CLI 的 `{callId, responseParts:{functionResponse:{id,name,response}}, resultDisplay}` 形态;且代码库带有 Google LLC 许可证头部 —— "三方混血体" 的定性是准确的([source](https://www.npmjs.com/package/@iflow-ai/iflow-cli)、[community](https://github.com/QwenLM/qwen-code/discussions/825))。

---

## References (official sources)

- [iflow-ai/iflow-cli (GitHub —— 分发/安装器仓库;Shell + Homebrew formula、install.sh;并非 JS 源码)](https://github.com/iflow-ai/iflow-cli)
- [@iflow-ai/iflow-cli on npm (v0.5.19 —— 打包的 `bundle/iflow.js`,磁盘格式的权威来源)](https://www.npmjs.com/package/@iflow-ai/iflow-cli)
- [jsDelivr CDN file listing for @iflow-ai/iflow-cli@0.5.19 (`bundle/iflow.js`, ~13.5 MB)](https://data.jsdelivr.com/v1/packages/npm/@iflow-ai/iflow-cli@0.5.19)
- [iFlow CLI docs —— CLI Configuration / settings (`~/.iflow` 布局、`tmp/<project_hash>`)](https://platform.iflow.cn/en/cli/configuration/settings)
- [iFlow CLI docs —— Checkpointing (`snapshots/<project_hash>`、`cache/<project_hash>/checkpoints`、关停通知)](https://platform.iflow.cn/en/cli/features/checkpointing)
- [iFlow CLI docs —— Changelog (v0.2.0 对话持久化;2026-04-17 关停,迁移至 Qoder)](https://platform.iflow.cn/en/cli/changelog)
- [DeepWiki: iflow-ai/iflow-cli (社区逆向 wiki)](https://deepwiki.com/iflow-ai/iflow-cli)
- [QwenLM/qwen-code Discussion #825 (iFlow CLI 与 Qwen Code 均为 Gemini CLI fork)](https://github.com/QwenLM/qwen-code/discussions/825)
