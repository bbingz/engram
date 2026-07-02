# Qwen Code — 会话格式参考

> 本文档为英文权威版 qwen.md 的中文阅读副本;若有出入以英文版为准。

Last researched: 2026-07-01.

> 关于 **Qwen Code**(阿里巴巴的 Gemini-CLI 分支)如何在磁盘上持久化其会话,
> 以及 Engram 的 `QwenAdapter`(Swift 产品版 +
> TypeScript 参考版)如何消费这些数据的权威英文参考。Qwen Code 是 **Google Gemini
> CLI 的一个分支**,但其磁盘上的转录格式是一种 **混合体**:它保留了 Gemini 的
> `message.parts[].text` 内容主体,却把每条记录都包裹在一层
> **Claude-Code 风格的逐行 JSONL 信封**(`uuid`/`parentUuid`/`cwd`/
> `gitBranch`/`version`/`sessionId`/`timestamp`/`type`)中,每行一条记录 ——
> *而不是* Gemini 的单对象 `.json` 或 `$set` 变更式 `.jsonl`。本文档自成体系;
> 关于共同血统以及 Qwen 在哪些方面发生分歧,可交叉参考
> [`docs/session-formats/gemini-cli.md`](./gemini-cli.md)(兄弟文档)和
> [`docs/session-formats/codex.md`](./codex.md)(信封同源)。

**证据基础(本文档)。** 三个来源交叉核验;冲突时以真实数据为准,并标注差异。

1. **LIVE 磁盘存储** — 本机的 `~/.qwen/`(已确认存在)。2026-07-01 本机审计在 **43 个项目目录** 下、
   `~/.qwen/projects/<encodedCwd>/chats/` 中共有 **787 个 `.jsonl` 会话转录文件**,
   外加 **17 个 `~/.qwen/tmp/<64-hex>/` 目录**,其中 **15 个含有一个 `logs.json`**
   (遥测数据,非转录)、**2 个不含任何文件**。**没有 `~/.qwen/projects.json`**
   (已确认缺失 —— 这是与 Gemini 的一个关键分歧)。LIVE `~/.qwen` 根目录还带有适配器忽略的
   **以 session 为键的非转录产物**:`debug/<sessionId>.txt`(**749 个** LIVE 的
   逐 session INFO/DEBUG 日志,文件名主干 == sessionId)和
   `todos/<sessionId>.json`(**4 个** LIVE,`{sessionId, todos:[{content,id,status}]}`),以及全局的
   `memories/MEMORY.md`、`skills/<name>/` 和 `settings.json.orig`(见
   [§14](#14-auxiliary-files-present-live-not-consumed))。磁盘上的 CLI 版本仍属于此前审计确认的
   `0.10.5` → `0.18.x` 家族。在采样的内容丰富的会话中,记录类型普查为:
   `system/ui_telemetry`、`tool_result`、`assistant`、`user`、`system/attribution_snapshot`、
   `system/slash_command` —— 六种类型全部存在。当前解析出的模型分布为:
   `qwen3.5-plus`(517)、`qwen3.6-plus`(147)、`qwen3.7-plus`(51)、`coder-model`(1)、无 model 字段(63)。
2. **仓库固件(fixtures)** — `tests/fixtures/qwen/{sample.jsonl (758 B, 3 lines), schema_drift.jsonl (511 B, 2 lines)}`
   以及 `tests/fixtures/adapter-parity/qwen/{success.expected.json, input/-Users-test-my-project/chats/sample.jsonl}`。
   还读取了 iFlow 兄弟固件(`tests/fixtures/iflow/{sample.jsonl, schema_drift.jsonl}`)用于血统对照。
3. **Engram 适配器(已编码的知识)** — Swift 产品解析器
   `macos/Shared/EngramCore/Adapters/Sources/QwenAdapter.swift`(253 行);TS 参考解析器
   `src/adapters/qwen.ts`(273 行)。共享 I/O 辅助 `JSONLAdapterSupport` 位于
   `macos/Shared/EngramCore/Adapters/Sources/CodexAdapter.swift` 内部;解析上限位于
   `macos/Shared/EngramCore/Adapters/ParserLimits.swift`。

**首要差异(真实数据 vs 固件/适配器)。** 仓库固件是一份 **陈旧的 `v0.10.5` schema** ——
扁平的 `user`/`assistant` 记录,带 `message.parts[].text` 与顶层 `model`,没有遥测、没有
`tool_result`、没有 `usageMetadata`、没有 `thought` parts。**LIVE `v0.14+` 数据要丰富得多**:
每个 assistant 回合都与 `system/ui_telemetry` 行交织
(`qwen-code.api_response`/`tool_call`/`api_error`)、`tool_result` 记录、
`system/attribution_snapshot` 和 `system/slash_command`;assistant 的 `message.parts[]`
携带 `thought:true` 和 `functionCall` 块;每回合的 token 用量位于 **顶层 `usageMetadata`**
对象中。Swift 与保留 TS 适配器会在结构上处理这些 LIVE 形态:按 `type` 过滤、只提取非 thought 的
`text` parts,并从 `usageMetadata` 或 `system/ui_telemetry` 绑定 assistant usage。
`tool_result`、attribution snapshot、slash command、function-call block 等非 transcript payload
仍属于 **被解析但被丢弃** 的丰富字段,而非被错误解析。见
[§15](#15-lineage-gotchas-version-drift--edge-cases)。

## 当前本机审计

2026-07-01 native `~/.qwen/projects` smoke 列出 787 个 JSONL 文件，并将
779 个 conversation 文件解析为 `qwen`。原始扫描发现 5,158 条记录、0 条畸形行、
799 条 `user`、1,143 条 `assistant`、795 条 `tool_result` 和 2,421 条 `system`
记录。8 个跳过文件只包含 28 条 `type:"system"` 记录，因此按当前
`QwenAdapter` contract 不属于可解析 conversation。当前 `~/.engram/index.sqlite`
的 native `~/.qwen/projects` 切片有 779 个 `qwen` 行，全部位于
`/Users/bing/.qwen/%`；native Qwen 的 DB 行覆盖正确。
更宽泛的 `source='qwen'` DB 总数是 1,425 行,因为还包含 646 条 `.claude-qwen`
provider-root 会话;这部分由单独的 `Qwen provider root (cc-qwen)` 审计行覆盖。
native `file_index_state` 仍为 779 个 `ok` 加 8 个 `retry/malformedJSON`。

同一 smoke 发现一个修复前的 stream/count 漂移：一条 user-form system injection
被计入 `systemMessageCount`，但仍由 `streamMessages` 产出，导致 streamed 为 1,942、
parsed `messageCount` 为 1,941。当前 worktree 的 TS 与 Swift 适配器现在会在 stream
输出中跳过同类 system injection；重跑 live smoke 后 `messageCount=1,941`、
`streamed=1,941`，逐文件 mismatch 为 0,且有 1,140 条 streamed assistant message
带 token usage。已安装 `/Applications/Engram.app` build
`20260701074505` 已包含该 stream 修复：安装版 MCP 现在对真实 native Qwen 行
`c159a22a-9399-49f0-9c17-7bd92dbaf7ce` 返回 49 条 page-1 messages,
`sessionMessageCount=175`,且不会泄漏 Qwen system prompt。

独立的 Claude Code provider-root 路线 `~/.claude-qwen/projects` 不是 native Qwen
存储；它使用 Claude Code JSONL，由 `ClaudeCodeAdapter` 以 `qwen` source 解析。2026-07-02 审计
列出 654 个 provider-root JSONL 文件、23,234 条记录、0 条畸形行，解析 646 个
conversation，发现 640 个带 parent link 的 subagent，且 stream/count mismatch 为 0。
已安装 `/Applications/Engram.app` build `20260701074505` 在
`/Users/bing/.claude-qwen/%` 下已有 646 个 DB 行，locator diff 已闭合。654 个
`.claude-qwen` `file_index_state` 行仍全是 schema version 1，但修正后的
visible-tool-result parser 报告 0 个字段陈旧的当前 provider-root 行。此前 483 行
stale-count 结论是 retained TS 审计工具误报：TS 当时会计入 Swift 产品已丢弃的非可见
Claude `tool_result` 行。

---

## 1. 概览 & TL;DR

**是什么 / 在哪里 / 怎么存。** Qwen Code 把每次聊天存为 `~/.qwen/projects/<encodedCwd>/chats/<sessionId>.jsonl`
下的 **每个 session 一个 JSONL 文件**。每一行都是一个独立的 JSON 对象,代表一个事件
(`user` / `assistant` / `tool_result` / `system`)。它是 **按事件追加** 的:新行按时间顺序追加;
已有的行从不被改写。**没有 SQLite、没有 leveldb、没有 gRPC 缓存。** 与 Gemini CLI 不同,
这里 **没有顶层 session 信封对象**,也 **没有全局 `projects.json` 的 cwd→name 映射**:
每条记录都通过 `cwd`/`sessionId`/`timestamp` 自描述,而 `<encodedCwd>` 目录名是经路径
slug 化后的绝对工作目录。

**心智模型。** `session = 文件`;`行 = 事件`。记录通过 `parentUuid → uuid` 串联成一个
session 内的链表(Claude-Code 血统),但 Engram 是线性读取它们的。`startTime` = 第一条记录的
`timestamp`;`endTime` = 最后一条记录的 `timestamp`。assistant 记录最丰富:它携带推理、最终答案、
内联在 `message.parts[]` 中的工具调用请求,以及顶层的 `model`/`usageMetadata`/`contextWindowSize`。

**血统一句话。** 信封 = **Claude Code**(`uuid`/`parentUuid`/`cwd`/`gitBranch`/`version`/`sessionId`/`timestamp`);
消息主体 = **Gemini CLI**(`message.parts[].text`、assistant `role:"model"`、
`usageMetadata.promptTokenCount`/`candidatesTokenCount`)。根目录和目录命名与 Gemini 有分歧:
`~/.qwen/projects/<slug(cwd)>/` 而非 `~/.gemini/tmp/<alias|hash>/`。

**ASCII 布局 / 分层图。**

```
~/.qwen/                                       storage tech: append-only line-delimited JSON (JSONL) files
├── settings.json, settings.json.orig, oauth_creds.json, QWEN.md  ── CLI config (NOT session data; never read)
├── output-language.md, tip_history.json, installation_id   ── CLI config (never read)
├── memories/MEMORY.md                          ── global memory file (often empty; NOT a transcript; never read)
├── skills/<name>/                              ── installed skills (e.g. superpowers, fireworks-tech-graph) (never read)
├── debug/<sessionId>.txt                       ── per-session INFO/DEBUG log; SESSION-KEYED (stem == sessionId); never read  (749 live)
├── todos/<sessionId>.json                      ── per-session todo list { sessionId, todos:[{content,id,status}] }; SESSION-KEYED; never read
├── usage_record.jsonl                          ── per-session aggregate usage ledger (NOT per-session transcript; never read)
├── usage/token-usage-YYYY-MM.jsonl             ── per-request token ledger (never read)
├── tmp/<64-hex>/logs.json                      ── Gemini-style UI telemetry rows (most tmp dirs; NOT transcripts; never read)
└── projects/                                   ── transcript root  (adapter `projectsRoot`)
    └── <encodedCwd>/                            ── dash-encoded absolute cwd (e.g. -Users-bing--Code--engram)
        ├── meta.json                            ── { version, createdAt, updatedAt }            (ignored)
        ├── extract-cursor.json                  ── { updatedAt } OR { sessionId, processedOffset, updatedAt } (ignored)
        ├── memory/                              ── per-project memory dir (often empty)         (ignored)
        └── chats/
            └── <sessionId>.jsonl                ── one session = one JSONL file  ← Engram parses

  line layer 1  event envelope  { uuid, parentUuid, sessionId, timestamp, type, cwd, gitBranch?, version, ... }
  line layer 2    ├─ message       { role, parts[] }                          (user / assistant / tool_result)
  line layer 2    ├─ usageMetadata { promptTokenCount, candidatesTokenCount, ... }   (assistant, TOP-LEVEL)
  line layer 2    ├─ model, contextWindowSize                                  (assistant, TOP-LEVEL)
  line layer 2    ├─ systemPayload { uiEvent | snapshot | phase,rawCommand }   (system)
  line layer 2    └─ toolCallResult{ callId, status, resultDisplay, error?, errorType? }  (tool_result)
  line layer 3        ├─ parts[]   { text } | { text, thought:true } | { functionCall } | { functionResponse }
  line layer 3        └─ uiEvent   { event.name, input_token_count, output_token_count, cached..., thoughts..., tool..., ... }
```

**给 Engram 工程师的 TL;DR。** Engram glob `*.jsonl`,保留 `sessionId / cwd / model / startTime / endTime`
(取自第一条符合条件的记录),**仅** 从 `user` + `assistant` 记录中非 thought 的 `message.parts[].text`
扁平化会话文本(Swift 与 TS 均用 `\n` 连接),统计 user 与 assistant
数量,把系统注入式 `user` 记录(文本以 `You are Qwen Code` 开头或含 `<INSTRUCTIONS>`)重新归类进
`systemMessageCount` 并从 streamed messages 中排除,同时从 `usageMetadata` 推导 token 用量,带一个 `system/ui_telemetry api_response`
兜底(Swift 与保留 TS 均支持)。它 **丢弃**:整个 `tool_result` 记录类型(`toolMessageCount` 硬编码为 `0`)、
除作为 token 旁路外的所有 `system` 行、`parts[].thought` 文本、
`parts[].functionCall`/`functionResponse`、`parentUuid`、`uuid`、`gitBranch`、`version`、
`contextWindowSize`、`usageMetadata.{thoughtsTokenCount,totalTokenCount}`、`<encodedCwd>` 目录名
(→ `project: nil`),以及每项目的 `meta.json`/`extract-cursor.json`/`memory/` 外加 `tmp/*/logs.json`
和 `usage/*` 账本。`parentSessionId`/`suggestedParentId`/`agentRole`/`originator` 全为 `nil`
(不读取 sidecar)。**TS 参考路径还额外丢弃所有 token 用量**。

---

## 2. 磁盘布局 & 文件命名

**权威根目录**(两个适配器):`~/.qwen/projects/` —— `QwenAdapter.swift:9-11`(`.qwen/projects`)、
`qwen.ts:20`(`join(homedir(), '.qwen', 'projects')`)。**已由 LIVE 存储确认**(`~/.qwen/projects/*/chats/`
下有 787 个 `.jsonl`,43 个项目目录,截至 2026-07-01)。在每个项目目录内,转录位于 `chats/` 下
(`QwenAdapter.swift:27`、`qwen.ts:36`)。**没有 `~/.qwen/tmp/` 转录路径**(Qwen 的 `tmp/<64-hex>/`
只含 `logs.json` 遥测),也 **没有 `~/.qwen/projects.json`**(Gemini 的 `cwd→name` 映射在此缺失 —— 已确认)。

| 路径 | 角色 | 存储技术 |
|---|---|---|
| `~/.qwen/projects/` | session 转录根目录(适配器 `projectsRoot`) | 每项目目录的目录 |
| `~/.qwen/projects/<encodedCwd>/chats/<sessionId>.jsonl` | 一个 session = 一个文件 | **append-only JSONL**(每行一个事件)—— Engram 解析 |
| `~/.qwen/projects/<encodedCwd>/meta.json` | `{version,createdAt,updatedAt}` 项目标记 | 单个 JSON 对象(忽略) |
| `~/.qwen/projects/<encodedCwd>/extract-cursor.json` | 跨工具抽取游标 | 单个 JSON 对象(忽略) |
| `~/.qwen/projects/<encodedCwd>/memory/` | 每项目 memory 目录(常为空) | 目录(忽略) |
| `~/.qwen/tmp/<64-hex>/logs.json` | Gemini 风格 UI 遥测行 | JSON 数组(**非转录;忽略**) |
| `~/.qwen/usage_record.jsonl` | 每 session 聚合用量账本 | JSONL(非每 session 转录;从不读取) |
| `~/.qwen/usage/token-usage-YYYY-MM.jsonl` | 每请求 token 账本 | JSONL(从不读取) |
| `~/.qwen/settings.json`、`oauth_creds.json`、`QWEN.md`、… | CLI 配置 | JSON / md(从不读取) |

### 命名文法

| 词法单元 | 文法 | LIVE 示例 | 备注 |
|---|---|---|---|
| `<encodedCwd>` | **已由 CLI 源码确认**([`paths.ts` `sanitizeCwd`](https://raw.githubusercontent.com/QwenLM/qwen-code/main/packages/core/src/utils/paths.ts)):`sanitizeCwd(cwd) = normalizedCwd.replace(/[^a-zA-Z0-9]/g, '-')`(Windows 上先小写)。每个非字母数字字符(`/`、`-`、`_`、`.`、…)→ 单个 `-`;开头的 `/` → 开头的 `-`;与既有连字符/下划线相邻的分隔符会产生一个 **双连字符**。`getProjectDir()` = `~/.qwen/projects/<sanitizeCwd(cwd)>`([`storage.ts`](https://raw.githubusercontent.com/QwenLM/qwen-code/main/packages/core/src/config/storage.ts))。 | `-Users-bing--Code--engram`(= `/Users/bing/-Code-/engram`)、`-Users-bing--Code--CCTV-Admin`(= `/Users/bing/-Code-/CCTV_Admin`)、`-Users-bing--Code--CCTV-Admin--worktrees-god-components-split`、`-private-tmp` | **有损**(无法区分原始的 `-`/`_`/`/`/`.`)。**与 Gemini 分歧**(alias-or-SHA256 + `projects.json` 映射)。适配器 **从不解码** 它 —— 它设 `project: nil`,改为从记录内的 `cwd` 字段读取 cwd,从而绕开歧义。 |
| session 文件 | `<sessionId>.jsonl`,其中 `sessionId` 是 UUIDv4 | `66040f20-b88b-43f2-98b9-724dfb49856e.jsonl`、`94f245ff-ccc0-47cf-901d-4c43a50f9121.jsonl` | **与 Gemini 的** `session-<YYYY-MM-DDTHH-mm>-<8hex>.json` **分歧**。Qwen 的文件名是 **裸的完整 session UUID** —— 没有时间戳,没有 `session-` 前缀。文件名主干 == 文件内 `sessionId`,完全一致(LIVE 已确认)。 |

> **冲突 / 细微差别(以真实数据为准)。** Gemini 兄弟文档和 Qwen *parity 固件* 的目录路径暗示存在
> `session-*`/alias 命名。LIVE Qwen 两者都不用:目录 = 编码后的 cwd,文件 = `<uuid>.jsonl`。适配器的枚举器
> 只是取 `chats/` 下的 **每个 `*.jsonl`**(没有 `session-` 前缀过滤 —— 与 Gemini/iFlow 适配器相反),
> 所以该分歧被妥善处理。`gemini-cli.md` §15(声称 Qwen「复用相同的 `tmp/<dir>/chats/` + `projects.json` 布局」)
> 是 **错误的**,应予更正:Qwen 共享 Gemini 的 *内容形态*,而非其 *文件布局*。

### 目录树示例(LIVE,已匿名化)

```
~/.qwen/
├── settings.json  settings.json.orig  oauth_creds.json  QWEN.md  usage_record.jsonl   # config + global ledger (ignored)
├── memories/MEMORY.md   skills/{superpowers,fireworks-tech-graph}/                  # global memory + skills (ignored)
├── debug/
│   └── 0061a40c-…-63e961b59159.txt                                # per-session INFO/DEBUG log; stem == sessionId  ← session-keyed, never read
├── todos/
│   └── 1e34a19c-…-2b9d34641eea.json                               # { sessionId, todos:[{content,id,status}] }  ← session-keyed, never read
├── usage/
│   └── token-usage-2026-06.jsonl                                  # per-request token ledger (ignored)
├── tmp/
│   └── 318082cf…d4e72/                                            # 64-hex project-hash dir (Gemini-fork remnant)
│       └── logs.json                                              # UI telemetry only (NOT a transcript; some tmp dirs lack it)  ← never visited
└── projects/
    ├── -Users-bing--Code--engram/                # <encodedCwd> = dash-encoded /Users/bing/-Code-/engram
    │   ├── meta.json                             # { "version":1, "createdAt":"…Z", "updatedAt":"…Z" }   (ignored)
    │   ├── extract-cursor.json                   # { "updatedAt":"…Z" }  (ignored)
    │   ├── memory/                               # per-project memory dir (often empty)   (ignored)
    │   └── chats/
    │       ├── 94f245ff-…-c6fb1c09d0e5.jsonl     # large: user+assistant+tool_result+telemetry
    │       └── 0fd5e56d-…-c1c09d0e5.jsonl        # small: user + system telemetry only (no assistant)
    ├── -Users-bing--Code--CCTV-Admin/
    │   └── chats/ …                              # 66040f20-… large rich session
    └── -private-tmp/
        ├── meta.json   memory/
        └── chats/ …
```

---

## 3. 文件生命周期 & 生成

| 方面 | 行为 | 证据 |
|---|---|---|
| **存储技术** | 每 session 一个 JSONL 文件,**append-only**(每行一个事件对象)。无数据库/leveldb/gRPC 缓存。 | LIVE 存储;两个适配器都通过 `JSONLAdapterSupport.readObjects`(Swift)/ `readLines`(TS)逐行读取 |
| **DB vs 文件** | 文件。一个文件 = 一个 `sessionId`;文件名 **就是** session UUID(主干 == 文件内 `sessionId`)。 | 文件名文法;LIVE 验证 |
| **追加 vs 改写** | **追加。** 每个事件是按时间顺序追加的一行新 JSON;已有的行从不被改写。(与 Gemini 的整对象改写或 `$set` 快照相反。) | 逐行 `timestamp` 单调;`parentUuid → uuid` 把行串成链表 |
| **链表** | 记录通过 `parentUuid → uuid` 串联;第一条记录的 `parentUuid:null`。Engram 忽略该链(线性读取)。 | LIVE:每个 `parentUuid` == 前一条记录的 `uuid` |
| **恢复(Resume)** | 恢复的 session 保持相同的文件/`sessionId` 并追加更多行;`cwd`/`gitBranch`/`version` 逐行重盖(因此 `version` 可在文件中途跨 CLI 升级而漂移)。`startTime` 固定不变;结束时间推进。 | 逐行 `version` 字段 |
| **滚动(Rollover)** | 新 session = 同一 `chats/` 中的新 `<uuid>.jsonl`;不会对既有转录做轮转/分段。 | 每 UUID 一个文件 |
| **归档 / 清理** | 未观察到归档目录。空的每项目 `memory/` 目录与 `meta.json`/`extract-cursor.json` 标记会持续存在。 | LIVE 存储 |
| **大小上限(Engram)** | **两个分歧的上限。** Swift 跳过 > **100 MB** 的文件(`maxFileBytes`,`ParserLimits.swift:17`)→ `.fileTooLarge`(`validateFileSize`,`ParserLimits.swift:47-49`)。**TS 没有大小上限** —— 它通过 `readline` 无界流式读取整个文件(`qwen.ts:165-179`)。 | `ParserLimits.swift:17,47-49`;`qwen.ts`(无上限) |
| **其他解析上限(仅 Swift)—— 对 Qwen 是静默的** | 每行字节上限 **8 MB**(`maxLineBytes`,`ParserLimits.swift:18`;由 `StreamingLineReader` 强制,`CodexAdapter.swift:65`)、消息数上限 **10,000**(`maxMessages`,`ParserLimits.swift:19`;`CodexAdapter.swift:71-74`)。**对 Qwen 这两者都不会浮现。** `readObjects` 只在以 `reportFailures: true` 调用时(`CodexAdapter.swift:82-87`,默认 `false`)才返回 `.messageLimitExceeded`/第一个行读取失败,而 **QwenAdapter 调用 `readObjects(locator:limits:)` 时不带 `reportFailures`**(`QwenAdapter.swift:40,131`)。因此一个 >10,000 条记录的 Qwen session 会被 **静默截断** 到前 10,000 个已解析对象(不抛出 `.messageLimitExceeded`),而一行 >8 MB 的行会被 **静默跳过**(其失败被吞掉)。TS 两个上限都没有。 | `ParserLimits.swift:18-19`;`CodexAdapter.swift:61,65,71-74,82-87`;`QwenAdapter.swift:40,131` |
| **原子性保护(仅 Swift)** | Swift 在读取 **前后** 都对文件身份(大小 + mtime + resource-id)做快照;不匹配 → `.fileModifiedDuringParse` → 稍后重试。**对 Qwen 这确实会浮现** —— `fileModifiedDuringParse` 在 `CodexAdapter.swift:79-80` 返回,且 **不受 `reportFailures` 门控**(不同于消息上限/行失败)。同理 `.fileTooLarge`(读前,`prepareFile`/`validateFileSize`)会浮现。一个正在索引期间被追加的 LIVE session 会被拒绝并重试 —— 这很常见,因为 Qwen 持续追加。 | `CodexAdapter.swift:79-80`;`ParserLimits.swift:26-45` |
| **FD 泄漏保护(仅 TS)** | `readLines` 用 try/finally 包裹 readline 循环,即使提前 `break`(上限/偏移)也关闭 fd,避免索引大量 session 时出现 EMFILE。 | `qwen.ts:165-179` |
| **整文件加载(两者)** | 即便 `streamMessages` 也会先把所有行加载进内存(Swift `readObjects` 然后 `applyWindow`,`QwenAdapter.swift:131-133`;TS `readLines` 每次调用都重读整个文件,`qwen.ts:131`)。Qwen **不** 使用 Codex 所用的 O(offset+limit) `windowedMessages` 流式辅助 → 对大 session 是每页 O(file)。 | `QwenAdapter.swift:131-133`;`qwen.ts:131-155` |

**Engram 发现 / 枚举**(`listSessionLocators()` Swift:22-36 / `listSessionFiles()` TS:32-51):
1. `detect()` —— 当且仅当 `~/.qwen/projects` 是目录时为真(Swift:18-20,TS:23-30)。
2. 枚举 `projects/` 的 **直接子项** 中是目录者(每个 = 一个 `<encodedCwd>`)—— `JSONLAdapterSupport.directChildren`(`CodexAdapter.swift:15-26`)跳过隐藏项和符号链接,并按路径排序返回。
3. 对每个,要求存在 `chats/` 子目录;跳过没有该子目录的项目(Swift:27-28,TS:36-44 —— TS 捕获 readdir 错误)。
4. 在 `chats/` 内,产出满足 **`pathExtension == "jsonl"`**(Swift:30)/ **`endsWith('.jsonl')`**(TS:40)的文件。**没有 `session-` 前缀过滤**(与 Gemini/iFlow 相反)。
5. Swift 返回 **已排序** 的列表(`locators.sorted()` Swift:35);TS 按 `readdir` 顺序惰性产出。

---

## 4. 记录 / 行分类法

一个文件 = 一个有序的 JSON 对象序列,每行一个。顶层 `type`(对 `system` 而言还有 `subtype`)用作判别。
**LIVE 中观察到:** `user`、`assistant`、`tool_result`、`system/ui_telemetry`、`system/attribution_snapshot`、
`system/slash_command`。陈旧固件只含 `user`/`assistant`;`schema_drift.jsonl` 额外加入了前向兼容垃圾
(`futureField`、一个未知 part `{type:"new_part",data}`、`responseMetadata`)以证明适配器会忽略未知键。

> **Confirmed (official):`system` 的 `subtype` 枚举远多于 LIVE 观察到的 3 种。** [`chatRecordingService.ts`](https://raw.githubusercontent.com/QwenLM/qwen-code/main/packages/core/src/services/chatRecordingService.ts) 中的 `ChatRecord` schema 定义了:`chat_compression`、`slash_command`、`ui_telemetry`、`at_command`、`attribution_snapshot`、`notification`、`cron`、`mid_turn_user_message`、`custom_title`、`rewind`、`agent_bootstrap`、`agent_launch_prompt`、`file_history_snapshot`。LIVE 观察到的 3 种只是子集。这不改变 Engram 的行为(除 `ui_telemetry/api_response` token 挖掘外,所有 `system` 行都被丢弃),但请注意 `chat_compression` 作为压缩记录存在(见 §12)。

| `type`(`subtype`) | `message.role` | 用途 | 在 Engram 中的角色 | 计入计数? |
|---|---|---|---|---|
| `user` | `user` | 用户回合(`message.parts[].text`)或一个 **系统注入** 提示词(`You are Qwen Code…` / `<INSTRUCTIONS>`)或一个 slash-command 回显 | `role:user` —— 除非检测到注入 → 重新归类为 `system` | 是(user 计数),除非注入 → system 计数 |
| `assistant` | `model` | assistant 回合 —— 最丰富:顶层 `model`/`usageMetadata`/`contextWindowSize`,`message.parts[]` 含 `text`/`thought`/`functionCall` | `role:assistant`;采集 token 用量 | 是(assistant 计数) |
| `tool_result` | `user` | 一个工具的执行结果(`toolCallResult` + `message.parts[].functionResponse`) | **整体丢弃** | **否**(`toolMessageCount` 硬编码 0) |
| `system` / `ui_telemetry` | (无) | `systemPayload.uiEvent` 中的遥测行;`event.name` ∈ {`qwen-code.api_response`, `qwen-code.tool_call`, `qwen-code.api_error`} | **仅 token 旁路**(Swift 挖掘 `api_response`;忽略 `tool_call`/`api_error`) | **否** |
| `system` / `attribution_snapshot` | (无) | Git/文件归因快照(`systemPayload.snapshot`) | 丢弃 | **否** |
| `system` / `slash_command` | (无) | Slash-command 标记(`systemPayload.{phase,rawCommand}`,如 `/init`、`/model`、`/exit`) | 丢弃 | **否** |

**过滤规则(两个适配器):** `parseSessionInfo` 扫描以及 `message()`/`streamMessages` 循环,**仅** 接受
`type == "user" || type == "assistant"` 作为会话内容(Swift:54-58, 159-163;TS:71, 137)。其余每个 `type`
(`tool_result`、所有 `system`、未知)在内容上都被跳过。`system/ui_telemetry` 行被单独检视,
**但仅用于 token 遥测**(Swift `telemetryUsage` :178-200;TS 根本不检视它们)。因此 `toolMessageCount`
始终为 `0`;`systemMessageCount` 只统计 **被注入重分类的 user 行**,而 **不是** 原始的 `type:"system"` 记录
(一个误导性的名字 —— 见 §15 第 7 条)。

> **系统注入子分类。** 一条 `user` 记录,若其扁平化文本以 `\nYou are Qwen Code` / `You are Qwen Code` 开头,
> 或含 `<INSTRUCTIONS>`,则被重新归类为 **system**(计入 `systemMessageCount`、排除出 `userMessageCount`
> 与 stream 输出,且不具备成为 summary 的资格)。—— `isSystemInjection` Swift:226-230 / TS:160-165;
> stream skip Swift:164-167 / TS:139-142。

> **`role` vs `type`。** `assistant` 记录的内层 `message.role` 是 `"model"`(Gemini 约定;LIVE 中绝不是
> `"assistant"`),而 `tool_result.message.role` 是 `"user"`。Engram 从 **顶层 `type`** 推导 role,忽略
> `message.role`。这一点很关键,因为 `tool_result` 记录携带 `message.role:"user"` —— 它们被 `type` 过滤排除,
> 而非被 role 排除,所以它们 **不会** 抬高 user 计数。(`schema_drift.jsonl` 固件用 `role:"assistant"` 仍能解析,
> 因为 role 不被读取。)

---

## 5. 共享信封 / 逐行元数据字段(行 layer 1)

每条记录的顶层键。**没有顶层 session 信封对象**(不同于 Gemini 的 `{sessionId, startTime, messages[]}`);
session 级别的事实由第一条符合条件的记录推导。在一条 assistant 行上 LIVE 验证到的键:
`contextWindowSize, cwd, gitBranch, message, model, parentUuid, sessionId, timestamp, type, usageMetadata, uuid, version`。
在一条 user 行上:`cwd, gitBranch, message, parentUuid, sessionId, timestamp, type, uuid, version`。

| 字段 | 类型 | 含义 | 可选 | 是否消费? | 示例(已匿名化) |
|---|---|---|---|---|---|
| `sessionId` | string (UUID) | 稳定的 session 身份;Engram 主键;等于文件名主干 | **必需**(否则 `malformedJSON`/null) | ✅ → `id` | `"94f245ff-ccc0-47cf-901d-4c43a50f9121"` |
| `timestamp` | string (ISO-8601 ms, UTC `Z`) | 此记录何时产生 | **必需** | ✅ → `startTime`(首条)/ `endTime`(末条)+ 逐消息 | `"2026-04-23T02:11:16.630Z"` |
| `type` | string | 记录判别符(§4) | **必需** | ✅(驱动 role + 计数) | `"assistant"` |
| `subtype` | string | `type:"system"` 的子判别符 | 可选(仅 system) | ✅(遥测门控,Swift) | `"ui_telemetry"` |
| `cwd` | string (abs path) | 记录时的工作目录 | LIVE 中存在 | ✅ → `cwd` | `"/Users/<u>/-Code-/engram"` |
| `uuid` | string (UUID) | 逐记录 id;下一条记录 `parentUuid` 的目标 | LIVE 中 **必需** | ❌ | `"343c57f5-c8b2-478b-ac7f-ebe2fe861adf"` |
| `parentUuid` | string\|null | 指向前一条记录 `uuid` 的回指针(链表;首条为 `null`) | LIVE 中 **必需** | ❌ | `"534fe31e-582b-473a-a444-d14bb943e807"` / `null` |
| `gitBranch` | string | 记录时活跃的 git 分支 | **可选**(在少数记录上省略 —— 全库普查约 4900 条中约 800 条) | ❌ | `"main"` |
| `version` | string (semver) | 写入该记录的 Qwen Code CLI 版本 | LIVE 中存在 | ❌ | `"0.15.0"`(LIVE 范围 `0.10.5`…`0.18.4`) |
| `model` | string | **仅 assistant:** 模型 id(顶层) | 仅 assistant | ✅ → session `model` | `"qwen3.6-plus"` |
| `usageMetadata` | object | **仅 assistant:** 逐回合 token 用量(顶层)(§9) | 仅 assistant(罕见缺失) | ✅(仅 Swift) | `{ promptTokenCount: 17297, … }` |
| `contextWindowSize` | int | **仅 assistant:** 模型上下文窗口 | 仅 assistant | ❌ | `1000000`(仅见此值) |
| `message` | object | `{role, parts[]}` 负载 | user/assistant/tool_result | ✅(仅 user/assistant) | `{ "role":"model", "parts":[…] }` |
| `systemPayload` | object | `system` 记录的负载(§10) | 仅 system | 部分(Swift,仅 `uiEvent` 遥测) | `{ "uiEvent": {…} }` |
| `toolCallResult` | object | 仅 `tool_result`(§7) | 仅 tool_result | ❌ | `{ callId, status, resultDisplay }` |

> **session 级别推导(Engram)。** `sessionId`、`cwd`、`model`、`startTime` 取自 **第一条** 含各字段的
> `user`/`assistant` 记录;`endTime` = 最后一条 `user`/`assistant` 记录的 `timestamp`(Swift:60-74,TS:73-82)。
> `model` 在 Swift 中 **仅读顶层**(`object["model"]`,:66);TS 还额外回退到 `message.model`
> (`qwen.ts:79-82`)—— 但 LIVE 的 `model` 在 assistant 记录上可靠地位于顶层,所以两者收敛,而 TS 的
> `msg.model` 分支 **对当前数据是死代码**(见 §15 第 6 条 + 开放问题)。

> **磁盘上没有 `messageCount`。** 不存在顶层计数字段;Engram **重新计算**
> `messageCount = userCount + assistantCount`。parity 固件的 `messageCount:3` 是重算输出,不是源字段。

> **相对 Gemini 的分歧标记。** Qwen 记录携带逐行 `uuid`/`parentUuid`/`gitBranch`/`version`/`cwd`
> (Claude-Code 风格信封),这是 Gemini 的单对象/`$set` 格式所没有的。Qwen **没有顶层信封** 对象
> (没有 `kind`/`projectHash`/`startTime`/`lastUpdated`);session 级别的 start/end 由首/末 `timestamp` 推导。
> 除 `cwd`/`timestamp`/`sessionId`/`model` 外,所有额外信封字段都不被消费。

---

## 6. 消息 & 内容 schema(行 layers 2–3)

### 6.1 `message` 对象(layer 2;在 user / assistant / tool_result 上)

| 字段 | 类型 | 含义 | 在哪些类型 | 是否消费? |
|---|---|---|---|---|
| `role` | string | `"user"`(user & tool_result)/ `"model"`(assistant;drift 固件也用 `"assistant"`) | 全部 | ❌(Engram 从顶层 `type` 推导 role,而非 `message.role`) |
| `parts` | array<object> | 有序内容块(§6.5) | 全部 | ✅(仅保留 `.text`) |

`extractContent` 读取 `message.parts[]`,保留每个元素的非空 `.text`,并在 Swift 与 TS 中都用
**`\n`** 连接。关于推理泄漏的注意事项见 §8。

### 6.2 `type:"user"` 记录

`message.parts[]` 在 **纯文本 session 中是单个 `[{text}]` part**(没有 `displayContent`,不同于 Gemini),
但 schema **允许多 part / 非 `text` part**:`recordUserMessage` 接受一个 `@google/genai` 的 `PartListUnion`
并经 `createUserContent` 包装,因此一条 user 记录的 `parts` 原则上可携带多个 part 和非文本种类
(尤其是用于图像/附件输入的 `inlineData`)—— [`chatRecordingService.ts`](https://raw.githubusercontent.com/QwenLM/qwen-code/main/packages/core/src/services/chatRecordingService.ts)。
`extractContent` 只保留 `.text`,因此会静默丢弃任何 `inlineData` part。三种用户文本风味,在磁盘上都以相同方式存储:

| 风味 | 检测 | Engram 处理 |
|---|---|---|
| 真实用户提示 | 默认 | 计为 user;第一个 → `summary`(`prefix(200)`) |
| 系统注入 | 文本以 `"You are Qwen Code"` 开头(可带前导 `\n`)或含 `"<INSTRUCTIONS>"` | 计为 **system**(`systemMessageCount`),非 user;不具 summary 资格 |
| Slash-command 回显 | 文本如 `/model`、`/exit`(也镜像为 `system/slash_command`) | 计为 user(无特殊处理) |

```json
{
  "uuid": "0b7d3ecc-…-dbc39a20e637", "parentUuid": null,
  "sessionId": "9ac9a7c3-…-2ce24fc677d6",
  "timestamp": "2026-04-23T00:39:48.359Z", "type": "user",
  "cwd": "/Users/<u>/-Code-/engram", "version": "0.15.0", "gitBranch": "main",
  "message": { "role": "user", "parts": [ { "text": "<user prompt>" } ] }
}
```

### 6.3 `type:"assistant"` 记录 —— 最丰富的记录

| 字段 | 类型 | 含义 | 可选 | 是否消费? |
|---|---|---|---|---|
| `model` | string | 产生该回合的模型(顶层) | 必需(assistant) | ✅(session `model`) |
| `message.parts` | array | 混合:推理(`thought:true`)、最终文本、工具调用(`functionCall`)(§6.5) | 必需 | ✅(连接非 thought 文本) |
| `usageMetadata` | object | 逐回合 token 用量(§9) | 可选 | ✅(Swift + TS) |
| `contextWindowSize` | int | 模型上下文窗口 | 可选 | ❌ |

```json
{
  "uuid": "343c57f5-…", "parentUuid": "534fe31e-…",
  "sessionId": "94f245ff-…", "timestamp": "2026-04-23T02:11:28.063Z",
  "type": "assistant", "cwd": "/Users/<u>/-Code-/engram",
  "version": "0.15.0", "gitBranch": "main", "model": "qwen3.6-plus",
  "contextWindowSize": 1000000,
  "usageMetadata": { "promptTokenCount": 17297, "candidatesTokenCount": 533,
    "thoughtsTokenCount": 20, "totalTokenCount": 17830, "cachedContentTokenCount": 0 },
  "message": { "role": "model", "parts": [
    { "text": "<reasoning>", "thought": true },
    { "text": "<assistant answer>" },
    { "functionCall": { "id": "call_44de…", "name": "read_file", "args": { "absolute_path": "<path>" } } }
  ] }
}
```

### 6.4 `type:"tool_result"` 记录

完整字段拆解以及成功/错误变体见 §7。`message.role` 是 `"user"`,所以排除它的是顶层 `type` 过滤(而非 role)。

### 6.5 `parts[]` 块种类(layer 3)

part 形态的全库普查(采样):assistant parts 分布于 `[text,thought]`、`[text]`、`[functionCall]`;
user parts 始终是 `[text]`;tool_result parts 是 `[functionResponse]`。单个 assistant 回合可批量包含
**许多** `functionCall` parts(LIVE 示例:一条 assistant 记录在一个 `[text,thought]` part 之后含 8 个
`functionCall` parts)。

| 块形态 | 在哪里 | 含义 | 是否消费? |
|---|---|---|---|
| `{ "text": "<string>" }` | user, assistant | 纯文本回合 / 答案 | ✅(用 `\n` 连接) |
| `{ "text": "<string>", "thought": true }` | assistant | 标记为 thought 的推理文本 | ❌ 跳过 —— 当前 Swift/TS `extractContent` 会忽略 `thought:true` 文本 part。 |
| `{ "functionCall": { id, name, args } }` | assistant | 工具调用请求 | ❌(无 `text` 键 → 被 `extractContent` 跳过) |
| `{ "functionResponse": { id, name, response } }` | tool_result | 工具返回负载 | ❌(整个 `tool_result` 记录被丢弃) |

**抽取**(`extractContent` Swift:228-241 / TS:194-206):遍历 `message.parts`,只在未设置 `thought:true` 时保留每个元素的非空 `.text`,连接。
没有 `text` 键的块(`functionCall`/`functionResponse`)不贡献任何内容。

> **覆盖标记。** 当前 Swift 和 TS parser 都会在归一化前剥离 assistant 的 `thought:true`
> parts，等价于 Gemini 独立 `thoughts[]` 数组的丢弃语义。反过来,一个 `parts` *只有*
> `functionCall` 的 assistant 回合会被扁平化为 **空内容**(仍计为一个 assistant 回合
> —— 按 `type` 计数,而非按内容)。

```json
// assistant message.parts[] (anonymized) — mixed text / thought / functionCall
{ "role": "model", "parts": [
  { "text": "<reasoning>", "thought": true },
  { "text": "<assistant answer>" },
  { "functionCall": { "id": "call_44de…", "name": "read_file", "args": { "absolute_path": "<path>" } } }
] }
```

---

## 7. 工具调用 & 结果

不同于 Gemini(工具调用 + 结果共置于一条 assistant 记录的 `toolCalls[]` 内),**Qwen 使用双记录模型**
(Claude-Code 风格拆分),且 Engram **两者都不导入**:

1. **请求** —— 一个 assistant `message.parts[]` 元素 `{ functionCall: { id, name, args } }`(§6.5)。单个 assistant 回合可批量多次调用。
2. **结果** —— 日志中稍后的一条 **独立 `tool_result` 记录**,每次调用一条,带 `message.parts[0].functionResponse` + 一个顶层 `toolCallResult` 信封。

**关联(LIVE 已验证):** `functionCall.id === toolCallResult.callId === functionResponse.id`,且
`functionCall.name === functionResponse.name`。按 `id`/`callId` 关联 —— **而非** 按 `parentUuid`
(后者只串联相邻关系)。LIVE 见到的工具名:`read_file`、`list_directory`、`edit` 等。

### 7.1 assistant `functionCall` part(layer 3)

| 字段 | 类型 | 含义 | 可选 | 示例 |
|---|---|---|---|---|
| `id` | string | 调用 id;= `tool_result.toolCallResult.callId` = `functionResponse.id`(关联键) | 必需 | `"call_44de19224c8b41328bbe5687"` |
| `name` | string | 工具名(snake_case) | 必需 | `"read_file"` |
| `args` | object | 工具参数;键随工具而定(如 `absolute_path` / `file_path`) | 必需 | `{ "file_path": "<path>" }` |

### 7.2 `tool_result` 记录 —— `toolCallResult` 信封(layer 2)+ `functionResponse`(layer 3)

LIVE 验证的 `tool_result` 键:`{cwd, gitBranch, message, parentUuid, sessionId, timestamp, toolCallResult, type, uuid, version}`。
`toolCallResult` 键(成功):`{callId, resultDisplay, status}`;出错时增加 `{error, errorType}`。

`toolCallResult`:

| 字段 | 类型 | 含义 | 可选 | 示例 |
|---|---|---|---|---|
| `callId` | string | 链接到请求的 `functionCall.id` | 必需 | `"call_44de19224c8b41328bbe5687"` |
| `status` | enum string | `"success"` \| `"error"`(两者 LIVE 均确认) | 必需 | `"success"` |
| `resultDisplay` | string | 人类渲染摘要(成功时为空;出错时为错误文本) | 必需 | `"Read lines 1-419 of 475 …"` / `""` / `"File not found: …"` |
| `error` | object | 出错时存在(观察到 `{}` 占位符) | 仅 error | `{}` |
| `errorType` | string | 错误分类 | 仅 error | `"file_not_found"`(LIVE 还有:`execution_denied`、`invalid_tool_params`、`unhandled_exception`、`edit_no_occurrence_found`) |

`message.parts[0].functionResponse`(最深,layer 3):

| 字段 | 类型 | 含义 | 可选 | 示例 |
|---|---|---|---|---|
| `id` | string | 匹配 `functionCall.id` / `callId`(关联) | 必需 | `"call_44de…"` |
| `name` | string | 工具名(匹配请求) | 必需 | `"read_file"` |
| `response.output` | string | 实际工具输出文本(成功时) | success | `"Showing lines 1-419 of 475 …"` |
| `response.error` | string | 错误文本(失败时) | error | `"File not found: <path>"` |

> **覆盖标记。** Engram **整体** 丢弃 `tool_result` —— `type` 过滤排除它,且 `toolMessageCount` 硬编码为
> `0`(Swift:104,TS:111)。parity 固件确认 `toolCallCount: 0`、`fileToolCounts: {}`。工具调用/结果完整地
> 存在于磁盘且可关联,但在 Engram 中不可见。不同于 Codex(把 `function_call` 计入 `toolMessageCount`),
> Qwen 的工具活动对 Engram 计数不可见。

```json
// separate tool_result record (success):
{ "type": "tool_result", "uuid": "<uuid>", "parentUuid": "<uuid>", "sessionId": "<uuid>",
  "timestamp": "2026-04-23T02:11:28.503Z", "cwd": "<path>", "gitBranch": "main", "version": "0.15.0",
  "toolCallResult": { "callId": "call_44de…", "status": "success", "resultDisplay": "<rendered result>" },
  "message": { "role": "user", "parts": [ { "functionResponse": {
      "id": "call_44de…", "name": "read_file", "response": { "output": "<tool output text>" } } } ] } }

// tool_result record (error variant):
{ "type": "tool_result", "...": "...",
  "toolCallResult": { "callId": "call_f511ad84…", "status": "error",
      "resultDisplay": "File not found: <path>", "error": {}, "errorType": "file_not_found" },
  "message": { "role": "user", "parts": [ { "functionResponse": {
      "id": "call_f511ad84…", "name": "read_file", "response": { "error": "File not found: <path>" } } } ] } }
```

---

## 8. 推理 / 思考

Qwen **没有独立的 `thoughts[]` 数组**(Gemini 有)。推理是 assistant 记录上的一个 **带内(in-band)**
`parts[]` 元素:`{ "text": "<reasoning>", "thought": true }`(§6.5),位于最终答案 part 之前。推理的
**token 计数** 单独报告为 `usageMetadata.thoughtsTokenCount` / `ui_telemetry.thoughts_token_count`(§9)。

**Engram 会剥离推理文本** —— `extractContent` 跳过 `thought` 标志为 `true` 的 part
(Swift:228-241,TS:194-206),因此一条 assistant 消息存储的 `content` 是用户可见文本,不是推理文本。

> **血统对照。** Gemini 把推理存于独立的顶层 `thoughts[]` 数组,Engram 丢弃它。
> Qwen 把推理内联进 `parts`,但 `thought:true` 标志给了 Engram 等价的丢弃信号。

```json
"parts": [
  { "text": "<chain-of-thought reasoning>", "thought": true },
  { "text": "<final user-visible answer>" }
]
```

---

## 9. Token 用量 & 成本

Qwen 在 **两处** 暴露逐回合用量。Swift 产品代码和保留 TS 适配器两者都读,优先用
`usageMetadata`;2026-07-02 native live smoke 为 1,140 条 streamed assistant
message 绑定了 usage。

### 9.1 主路径 —— assistant 记录上的顶层 `usageMetadata`

LIVE 验证的键:`{cachedContentTokenCount, candidatesTokenCount, promptTokenCount, thoughtsTokenCount, totalTokenCount}`。
由 `usage()` 读取(Swift:208-223;TS:223-231)。

```json
{ "promptTokenCount": 17297, "candidatesTokenCount": 533, "thoughtsTokenCount": 20, "totalTokenCount": 17830, "cachedContentTokenCount": 0 }
```

| 字段 | 类型 | 含义 | Engram 映射 |
|---|---|---|---|
| `promptTokenCount` | int | Prompt/输入 token | `inputTokens`(**原样** 使用,不减去缓存) |
| `candidatesTokenCount` | int | 完成 token | `outputTokens` |
| `cachedContentTokenCount` | int | 缓存读取 token | `cacheReadTokens` |
| `thoughtsTokenCount` | int | 推理 token | ❌(不累加;不同于 Gemini 把 thoughts 折入 output) |
| `totalTokenCount` | int | 总计 | ❌ 未使用 |

`cacheCreationTokens` 始终为 `0`(Qwen 不报告缓存创建计数)。**Confirmed (official):这是结构性永久的,而非仅仅未观察到。**
`usageMetadata` 原样存储自 Google GenAI 的 `GenerateContentResponseUsageMetadata` 类型
([`chatRecordingService.ts`](https://raw.githubusercontent.com/QwenLM/qwen-code/main/packages/core/src/services/chatRecordingService.ts);
[字段参考](https://v03.api.js.langchain.com/interfaces/_langchain_google_common.types.GenerateContentResponseUsageMetadata.html)),
其字段为 `promptTokenCount`、`candidatesTokenCount`、`cachedContentTokenCount`(缓存 **读取**)、`thoughtsTokenCount`、
`toolUsePromptTokenCount`、`totalTokenCount`(+ `*TokensDetails` 细分)—— schema 中 **没有缓存创建字段**,只有
`cachedContentTokenCount`(读取)。若 input+output+cacheRead 全为 0,`usage()` 返回 `nil`;`user` 记录不携带用量(Swift:170)。

### 9.2 兜底 —— `system/ui_telemetry` `api_response` 行

一行 `type:"system"`、`subtype:"ui_telemetry"`、其 `systemPayload.uiEvent["event.name"] == "qwen-code.api_response"`
的记录,**仅当其后的 assistant 记录缺少 `usageMetadata` 时**,才被挖掘 token
(`telemetryUsage` Swift:184-206;TS:209-221)。
LIVE 验证的 `api_response` uiEvent 键:`{auth_type, cached_content_token_count, duration_ms, event.name, event.timestamp, input_token_count, model, output_token_count, prompt_id, response_id, status_code, thoughts_token_count, total_token_count}`。

**机制(Swift `messages(from:)` :146-159;TS `streamMessages` :127-175):** 遥测行出现在它们所描述的
assistant 记录 **之前**。解析器缓冲 `pendingTelemetryUsage`;一行遥测设置它并把自身丢弃(不是消息);
下一条 assistant 消息取 `metadataUsage ?? telemetryUsage`(Swift:180;TS:161-164)并清空缓冲。

| uiEvent 字段 | → TokenUsage |
|---|---|
| `input_token_count` | `inputTokens` |
| `output_token_count` | `outputTokens` |
| `cached_content_token_count` | `cacheReadTokens` |

所有其他 uiEvent 字段(`thoughts_token_count`、`tool_token_count`、`total_token_count`、`duration_ms`、
`model`、`response_id`、`prompt_id`、`auth_type`、`status_code`)被忽略。`cacheCreationTokens` 始终为 `0`。
若三个派生计数全为 0,返回 `nil`。

> **LIVE 罕见性。** 在采样的 assistant 回合中,绝大多数都携带 `usageMetadata`;遥测兜底几乎从不触发
> (它存在是为了 `usageMetadata` 缺失的较旧/边缘 session)。

> **遥测 `event.name` 普查(LIVE,内容丰富的 session):** `qwen-code.tool_call`(最常见)、
> `qwen-code.api_response`、`qwen-code.api_error`(罕见)。适配器 **只匹配 `api_response`**(Swift:179)——
> `tool_call`/`api_error` 遥测被忽略,所以 `api_error` 回合的成本目前未被记录。

> **差异标记。**
> 1. **旧文档与固件曾掩盖 TS usage 抽取:** 陈旧 parity 固件没有 `usageMetadata`/遥测,所以如果不跑 focused test 或 live smoke,`usageTotals` 仍会全零。当前保留 TS 已与 Swift 对齐,支持 `usageMetadata` 与遥测兜底。
> 2. **live telemetry 兜底目前罕见:** 最新 full native smoke 在扫描语料中发现 0 条 `qwen-code.api_response` telemetry 行,但 1,140 条 assistant message 带顶层 `usageMetadata`。
> 3. **对 Qwen,`thoughtsTokenCount` 不折入 output**(Gemini 把 `thoughts`+`tool` 折入 output)。Qwen 的 `outputTokens` = 仅 `candidatesTokenCount`。
> 4. **不做缓存扣减**(vs Gemini)。Qwen Swift 把 `promptTokenCount → inputTokens` 直接映射(Swift:201);Gemini Swift 适配器做 `inputTokens = max(input − cached, 0)`。所以 Qwen 的 `inputTokens` **包含** 缓存 token;Gemini 的不含。跨源成本比较不一致(苹果对橘子)。

磁盘上不存储逐 token 价格/成本;Engram 在下游计算成本。

### 9.3 其他 `ui_telemetry` 事件形态(不消费)

- **`qwen-code.tool_call`** —— 逐工具执行遥测。LIVE 验证的键:`{content_length, decision, duration_ms, event.name, event.timestamp, function_args, function_name, prompt_id, response_id, status, success, tool_type}`(`decision`:见到 `auto_accept`;`tool_type`:见到 `native`)。
- **`qwen-code.api_error`** —— `{error_message, error_type, model, duration_ms, prompt_id, response_id, auth_type, status_code?}`(例如 `error_message: "Connection error. (cause: fetch failed)"`、`error_type: "APIConnectionError"`)。
- 某些 `api_response`/`tool_call` 事件上出现一个 `subagent_name` 字段(取值如 `general-purpose`、`managed-auto-memory-extractor`)—— 一个被派发子代理标记,Engram 忽略。

---

## 10. `system` 记录负载(辅助;大多丢弃)

| `subtype` | `systemPayload` 形态 | 含义 | Engram 用途 |
|---|---|---|---|
| `ui_telemetry` | `{ uiEvent: { "event.name", "event.timestamp", model, status_code, duration_ms, input_token_count, output_token_count, cached_content_token_count, thoughts_token_count, tool_token_count?, total_token_count, response_id, prompt_id, auth_type, … } }` | 逐 API 调用 / 逐工具调用 / 逐错误遥测 | 仅 `api_response` 的 token 旁路(§9.2) |
| `attribution_snapshot` | `{ snapshot: { type:"attribution-snapshot", version:1, surface:"cli", promptCount, promptCountAtLastCommit, fileStates:{} } }` | Git/文件归因检查点 | 丢弃 |
| `slash_command` | `{ phase:"invocation", rawCommand:"/init" } `(也有 `/model`、`/exit`) | Slash-command 标记 | 丢弃 |

`system` 记录被排除在所有消息计数之外(`type` 过滤只计 `user`/`assistant`)。

---

## 11. 子代理 / 父子 / 派发

- **文件内关联:** Qwen 的 `parentUuid` 把 **一个 session 内的记录** 串成链表。它是逐记录的回指针,**不是** 跨 session 父链接,Engram **不** 读取它。
- **跨 session 关联(`parentSessionId`):** Qwen 的原生文件 **不含** session 到 session 的父关联,而且 —— 不同于 Gemini 适配器 —— **Qwen 适配器不读取任何 `<sessionId>.engram.json` sidecar**。`parentSessionId`/`suggestedParentId`/`agentRole`/`originator` 硬编码为 `nil`(Swift:110-117)。Qwen 没有适配器级别的 originator/sidecar 信号(Gemini 的 Layer 1c 确定性 sidecar + `originator` 字段在此缺失)。
- **归因从何而来(在下游,而非适配器):**
  - **Layer 2 启发式**(派发模式 + 时间/cwd 评分)→ `suggested_parent_id`。
  - **`StartupBackfills.backfillPolycliProviderParents`**(按每项目 `CLAUDE.md` → Agent Session Grouping)把 Polycli 启动的 `qwen` 提供方 session 归类为 `dispatched` → tier `skip`,条件是第一条用户消息是健康 ping / 评审探针 / stage-fact 探针,或一个同 cwd 近并发的提供方子项。
  - **`SwiftIndexer.isSkippableFirstUserMessages`** 跳过已知的 Polycli 探针提示(`ping`、`POLYCLI_HEALTH_OK`、`No tools. Review...`、`No tools. Stage ... facts...`)。
- **派发上下文的 LIVE 证据:** `qwen-plugin-cc*` / Polycli 探针项目目录、`system/slash_command` 的 `/init` 探针,以及转录内的 `subagent_name` 遥测字段(§9.3,一个 Engram 不用于关联的提示)。所以一个由 Claude Code 经 Polycli 启动的 Qwen session 被分级为 `skip`,但该决定是在适配器 **之外** 做出的。

---

## 12. 摘要 / 压缩(compaction)

**Engram 不消费任何摘要记录。** Engram 自己合成一个 session **summary**:第一条 **非系统注入** 的
`user` 消息的扁平化文本,上限 200 字符(`String(firstUserText.prefix(200))` Swift:106;
`firstUserText.slice(0, 200)` TS:113)。派生而来,非存储。parity 确认 `summary == firstUserSummary == "<first user text>"`。

> **更正(official):该工具 *能* 发出压缩记录。** `ChatRecord` 的 `subtype` 枚举包含 `chat_compression`
> ([`chatRecordingService.ts`](https://raw.githubusercontent.com/QwenLM/qwen-code/main/packages/core/src/services/chatRecordingService.ts)),
> 一种 `type:"system"` 压缩记录。所以本节「没有压缩记录类型」的说法仅对 Engram *消费* 的部分成立 —— 磁盘上可以存在
> `system/chat_compression` 记录(在采样的 LIVE 存储中未观察到,且 `type` 过滤无论如何都会丢弃所有 `system` 行)。
> Engram 仍然合成自己的 summary。

---

## 13. SQLite / DB 内部

**对 Qwen Code N/A。** 会话是纯 append-only JSONL 文件;无 SQLite、leveldb 或 gRPC 缓存。(与 VS Code
`.vscdb`/leveldb 家族 —— Cursor/VS Code/Copilot/Cline —— 截然不同,后者与 Qwen 无血统关系。)

---

## 14. 辅助文件(LIVE 存在,不消费)

| 文件 | 形态 | 示例(已匿名化) | 备注 |
|---|---|---|---|
| `projects/<encodedCwd>/meta.json` | `{ version, createdAt, updatedAt }` | `{ "version":1, "createdAt":"2026-05-07T00:51:25.767Z", "updatedAt":"2026-05-07T00:51:25.767Z" }` | 项目元数据;忽略。(LIVE 中有些是 0 字节/空。) |
| `projects/<encodedCwd>/extract-cursor.json` | `{ updatedAt }` **或** `{ sessionId, processedOffset, updatedAt }`(两种形态都 LIVE) | `{ "updatedAt":"2026-05-07T00:54:20.137Z" }` / `{ "sessionId":"f16aad1d-…", "processedOffset":4, "updatedAt":"…Z" }` | 一个跨工具抽取游标/检查点;忽略。`processedOffset` 很可能是记录索引(小 session 上取值 `4`)。写入方/消费方未确认。 |
| `projects/<encodedCwd>/memory/` | 每项目 memory 目录(常为空) | — | 忽略。 |
| `tmp/<64-hex>/logs.json` | `{ sessionId, messageId:int, type, message, timestamp }` 的数组 | `{ "sessionId":"7f657511-…", "messageId":0, "type":"user", "message":"/model", "timestamp":"…Z" }` | Gemini 风格 UI 遥测行;`<64-hex>` 是项目哈希目录(Gemini-fork 残留)。`messageId` 是 0 基的逐 session 序号。**非转录。** 忽略。**16 个 LIVE `tmp/` 目录中有 15 个含此文件;1 个不含** —— 所以「tmp 目录含 logs.json」是 *大多数*,而非普遍。 |
| `debug/<sessionId>.txt` | 逐 session 的纯文本 **INFO/DEBUG 日志**(带时间戳的行,非 JSON) | `2026-04-22T06:34:26.771Z [INFO] Config initialization started` / `…[DEBUG] [HOOK_REGISTRY] …` | 像转录一样 **以 SESSION 为键**,但存储在 `projects/` **之外**:文件名 **主干 == `sessionId`**,与 `projects/<encodedCwd>/chats/<sameStem>.jsonl` 1:1 对应(已验证:`debug/0061a40c-…159.txt` ↔ `-Users-bing--Code--polycli/chats/0061a40c-…159.jsonl`)。**LIVE 750 个文件。** 非转录;**适配器从不读取**(适配器只枚举 `projects/`)。 |
| `todos/<sessionId>.json` | `{ sessionId, todos:[ { content, id, status } ] }` | `{ "sessionId":"1e34a19c-…", "todos":[ { "content":"<TEXT>", "id":"…", "status":"completed" } ] }` | **以 SESSION 为键**(顶层 `sessionId` == 文件名主干 == 一个真实转录主干;已验证 ↔ `-Users-bing--Code--qwen-plugin-cc/chats/1e34a19c-….jsonl`)。`todos[].status` 见到:`completed`。非转录;**从不读取。** |
| `memories/MEMORY.md` | 全局 memory markdown(常为空) | `(empty live)` | 全局(非逐 session)Qwen memory 文件。非 session 数据;从不读取。 |
| `skills/<name>/` | 已安装 skill 目录 | `superpowers/`、`fireworks-tech-graph/` | 已安装的 CLI skill。非 session 数据;从不读取。 |
| `settings.json.orig` | `settings.json` 的备份 | `(JSON config)` | 配置备份。非 session 数据;从不读取。 |
| `usage_record.jsonl` | 每 session 聚合 `{ version, sessionId, timestamp, startTime, project, durationMs, totalLatencyMs, files, tools, models{<model>:{requests,inputTokens,outputTokens,cachedTokens,thoughtsTokens,totalTokens,totalLatencyMs}} }` | `{ "version":1, "sessionId":"19b4e448-…", "project":"/Users/<u>/-Code-/polycli", "models":{"qwen3.7-plus":{"requests":2,"inputTokens":19179,…}} }` | 跨 session 用量账本;适配器忽略。 |
| `usage/token-usage-YYYY-MM.jsonl` | 每请求 `{ schemaVersion, id, timestamp, localDate, localMonth, sessionId, model, authType, source, inputTokens, outputTokens, cachedTokens, thoughtsTokens, totalTokens, apiDurationMs }` | `{ "schemaVersion":1, "id":"d7aae8bc-…", "sessionId":"7f640a35-…", "model":"qwen3.7-plus", "authType":"openai", "source":"main", "inputTokens":24564, "outputTokens":27 }` | 月度 token 账本;忽略。 |
| `~/.qwen/projects.json` | — | — | **不存在。** Qwen 没有全局 cwd→name 映射(Gemini 有)。 |
| `<sessionId>.engram.json` sidecar | — | — | **不存在,且 `QwenAdapter` 不读取**(Gemini 专有约定)。 |
| `settings.json`、`oauth_creds.json`、`QWEN.md`、`output-language.md`、`tip_history.json`、`installation_id` | CLI 配置 | — | 非 session 数据;从不读取。 |

---

## 15. Engram 映射

`source field/record → Engram Session field → adapter file:line`(Swift `QwenAdapter.swift` / TS `qwen.ts`)。

| Engram 字段 | 源字段/记录 | Swift | TS | 备注 |
|---|---|---|---|---|
| `id` | `sessionId`(首条 user/assistant 记录) | `:60-62,93` | `:73,102` | 必需(否则 `malformedJSON`/null) |
| `source` | 常量 | `:4,94` | `:16,103` | `.qwen` / `'qwen'` |
| `summary` / 标题 | 首条非注入 `user` 文本,`prefix(200)` | `:85,106` | `:92-94,113` | 空 → nil |
| `project` | **`nil`**(从不从 `<encodedCwd>` 解码) | `:99` | (省略) | 与 Gemini 分歧(后者设目录名);parity `project:null` |
| `cwd` | 逐记录 `cwd`(首次见到) | `:63-65,98` | `:74,107` | 来自记录内字段,而非目录名(无 `projects.json`) |
| `model` | 顶层 `model`(首条 assistant) | `:66-68,100` | `:79-82,108` | TS 还回退到 `message.model`(对 LIVE 数据为死代码;LIVE 仅顶层) |
| `startTime` | 首条记录 `timestamp` | `:69-71,95` | `:75,104` | 必需 |
| `endTime` | 末条记录 `timestamp`(若 == start 则 nil) | `:72-74,97` | `:76,105` | 可选 |
| `messageCount` | `userCount + assistantCount` | `:101` | `:108` | 排除 system/tool_result/注入归为 user 者 |
| `userMessageCount` | `type=="user"` 减去注入 | `:83-86,102` | `:86-95,109` | |
| `assistantMessageCount` | `type=="assistant"` | `:76-77,103` | `:84-85,110` | 即使内容为空也按 type 计 |
| `toolMessageCount` | 常量 `0` | `:104` | `:111` | `tool_result`/`functionCall` 从不计入 |
| `systemMessageCount` | 被注入重分类的 `user` 记录 | `:81-82,105` | `:88-90,112` | 不是原始的 `type:"system"` 记录 |
| `filePath` | locator | `:107` | `:114` | |
| `sizeBytes` | 文件大小 | `:108` | `:115` | Swift `JSONLAdapterSupport.fileSize`;TS `stat.size` |
| `parentSessionId` / `suggestedParentId` / `agentRole` / `originator` | **`nil`**(不读 sidecar) | `:110,116-117` | (省略) | 与 Gemini Layer 1c 分歧;由启发式/backfill 在后续设置 |
| **逐消息** `role` | `type=="assistant"`→assistant 否则 user | `:170` | `:146,149` | 来自顶层 `type`,而非 `message.role` |
| **逐消息** `content` | 非 thought 的 `extractContent(message.parts[].text)` 连接 | `:167,228-241` | `:150,194-206` | thought 文本跳过;`functionCall`/`functionResponse` 丢弃;Swift 与 TS 均用 `\n` 分隔 |
| **逐消息** `timestamp` | `timestamp` | `:168` | `:151` | |
| **逐消息** `usage` | assistant `usageMetadata` ?? pending `ui_telemetry` | `:174-180,184-223` | `:157-164,209-231` | Swift + TS |
| **逐消息** `toolCalls` | `nil` | `:169` | (无) | 丢弃 |

**Engram 不消费的内容:** 整个 `tool_result` 记录类型;除 `ui_telemetry/api_response` token 挖掘外的
所有 `system` 行;`parts[].thought` 文本;`parts[].functionCall`/`functionResponse`;`message.role`;
`parentUuid`;`uuid`;`gitBranch`;`version`;`contextWindowSize`;`usageMetadata.{thoughtsTokenCount,totalTokenCount}`;
整个 `uiEvent` 除 3 个 token 字段外;`<encodedCwd>` 目录名(→ `project:nil`);`meta.json`;`extract-cursor.json`;
`memory/`;`tmp/*/logs.json`;以及 `usage/*` 账本。磁盘上没有可消费的
`messageCount`/sidecar。

---

## 16. 血统、坑、版本漂移 & 边缘情况

### 共享 Gemini-CLI 血统 —— 以及 Qwen 在哪里分歧

Qwen Code 是 **Google Gemini CLI 的一个分支**,它 **分叉了内容模型却重写了持久化模型。** 它共享 Gemini 的
*内容主体*(`message.parts[].text`、assistant `role:"model"`、`usageMetadata` token 命名),但采用一层
**Claude-Code 风格的逐行 JSONL 信封**。所以 Qwen 是一个 **混合体:Claude-Code 框架上的 Gemini 主体。**

| 维度 | Gemini CLI | **Qwen Code** | 相同? |
|---|---|---|---|
| 根目录 | `~/.gemini/tmp/<alias\|hash>/chats/` | **`~/.qwen/projects/<encodedCwd>/chats/`** | ✗(`tmp` vs `projects`;alias/hash vs 编码 cwd) |
| 全局映射 | `~/.gemini/projects.json`(cwd→name) | **无** | ✗ |
| 文件形态 | 单对象 `.json`(legacy)/ `$set` `.jsonl`(new) | **按事件追加 JSONL**(Claude-CC 风格) | ✗ |
| 文件名 | `session-<ts>-<8hex>.<json\|jsonl>` | **`<sessionId>.jsonl`**(裸 UUID) | ✗ |
| 行信封 | 顶层 `{kind,projectHash,startTime,lastUpdated,messages[]}` | **逐行 `{uuid,parentUuid,sessionId,timestamp,cwd,gitBranch,version,type}`** | ✗(Qwen = Claude-CC 框架) |
| 内容形态 | `messages[].content` = string / `[{text}]` | **`message.parts[].text`、assistant `role:"model"`** | ✓(Gemini `parts`/`model` 遗产) |
| 记录类型 | `user`/`gemini`/`model`/`info` | **`user`/`assistant`/`tool_result`/`system{ui_telemetry,attribution_snapshot,slash_command}`** | ✗ |
| 工具调用 | 内联于 assistant `toolCalls[]`(+ 结果) | **拆分:assistant `functionCall` + 独立 `tool_result`** | ✗ |
| 推理 | 独立 `thoughts[]` 数组(文本被 Engram **丢弃**) | **带内 `{text,thought:true}` part(文本同样被 Engram 丢弃)** | ✓ 行为 / ✗ 存储 |
| Token 用量 | `tokens{input,output,cached,thoughts,tool,total}`;`inputTokens=max(input−cached,0)`,thoughts/tool 折入 output | **`usageMetadata{promptTokenCount,…}` + `ui_telemetry` 兜底**;`promptTokenCount` 未减缓存,thoughts 未用 | ✗ 命名 + 算术 |
| Engram `project` | 目录名 | **`nil`** | ✗ |
| Engram sidecar(Layer 1c) | 读取 `<sessionId>.engram.json` + `originator` | **不读取**(仅启发式 + Polycli backfill) | ✗ |

### Qwen 与 iFlow 在哪里分歧(兄弟工具)

**iFlow**(`~/.iflow/projects/<dir>/`,兄弟 `IflowAdapter`)在消息主体上是 **Claude Code** 的 *更近* 表亲,
而非 Qwen 的:它共享 Qwen 的根模式(`~/.<tool>/projects/<encodedCwd>/`)+ Claude-Code 逐行 JSONL 框架,
但使用 **`message.content`**(Claude/Anthropic 风格 string 或 `[{type:"text",text}]`)+ `isSidechain`/`userType`
+ 一个 Anthropic 风格 `message.usage{}`(`model:"glm-5"`),并且它的文件使用 **`session-` 前缀**。所以在
Google-fork 家族内:**Gemini `.json`/`$set` ≠ Qwen `parts`-JSONL ≠ iFlow `content`-JSONL** —— 三种不同的
持久化 schema。不要假设 Qwen 与 iFlow 字段相同:Qwen 需要 `parts[].text`,iFlow 需要 `message.content` 块。
(两个固件都归一化为相同的 3 消息形态,在 parity 层级掩盖了 schema 差异。)

整个家族与 VS Code `.vscdb`/leveldb 家族(Cursor/VS Code/Copilot/Cline)**截然不同** —— 没有血统重叠。

### 坑 / 版本漂移 / 边缘情况

1. **固件是陈旧的 `v0.10.5` schema(HIGH)。** `tests/fixtures/qwen/*` 与 parity 输入使用扁平 3 行 `user`/`assistant` 形态,带 `message.parts[].text`、顶层 `model`,**没有** 遥测/`tool_result`/`system`/`usageMetadata`/`thought` parts。LIVE `v0.14.5+` 要丰富得多。固件只验证了快乐文本路径,**不测试** token 抽取、遥测兜底、`tool_result` 跳过或注入过滤。聚焦 Swift/TS 测试现在覆盖 thought-part 跳过;`schema_drift.jsonl` 只证明对未知键的容忍。
2. **`gemini-cli.md` §15 夸大了共享布局(关键更正)。** 它声称 Qwen「复用相同的 `tmp/<dir>/chats/` + `projects.json` 布局」。**真实数据与此矛盾:** Qwen 使用 `~/.qwen/projects/<encodedCwd>/chats/<uuid>.jsonl`,**没有 `projects.json`**,其 `tmp/*/` 只含 `logs.json` 遥测。Qwen 共享 Gemini 的内容形态,而非其文件布局。请更正该文档。
3. **`tool_result` 被丢弃,`toolMessageCount` 始终为 0。** 工具 I/O 完整存在于磁盘(一个内容丰富的 session 可含数百条 `tool_result` 记录)但在 Engram 中不可见。关联是基于 `id`/`callId` 跨两条记录,而非像 Gemini 那样共置。
4. **工具调用不可见 + 内容可为空。** `parts` 只有 `functionCall` 的 assistant 回合计为 assistant 回合(按 `type` 计数)但扁平化为 **空内容**。
5. **推理文本会被剥离。** 当前 Swift/TS `extractContent` 跳过 `{text,thought:true}` parts,所以 Engram 的 Qwen assistant 内容保留答案文本,不保留推理 part。
6. **`thoughtsTokenCount` 不累加。** Qwen `outputTokens` = 仅 `candidatesTokenCount`(Gemini 把 thoughts+tool 折入 output)。跨工具的 output-token 总数不是同口径的。
7. **不做缓存扣减(vs Gemini)。** Qwen Swift 把 `promptTokenCount → inputTokens` 直接映射;Gemini 做 `max(input − cached, 0)`。所以 Qwen 的 `inputTokens` 包含缓存 token。跨源成本比较不一致。
8. **Token 用量由 Swift 和保留 TS 覆盖,但陈旧固件仍会掩盖它。** parity 固件的 `usageTotals` 全零;必须依靠 focused test 或 live smoke 才能证明 Qwen usage 抽取。
9. **`systemMessageCount` ≠ `type:"system"` 记录的计数。** Engram 的 `systemMessageCount` 统计 **系统注入用户消息**(以 `"You are Qwen Code"` 开头 / 含 `<INSTRUCTIONS>` 的提示),而非(为数众多的)真正 `type:"system"` 记录。这个名字有误导性。
10. **系统注入检测脆弱。** 硬编码英文前缀(`"You are Qwen Code"`);一个本地化或改写过的系统提示会被误计为真实用户消息,并可能成为 `summary`。
11. **`project` 始终 nil;`cwd` 来自文件内部。** 破折号编码的 cwd 目录名从不被解码;`cwd` 来自记录内字段。一个没有任何 `user`/`assistant` 记录携带 `cwd` 的 session 会得到空 `cwd`。
12. **没有 `user`/`assistant` 记录的 session 会失败。** 一个只记录了 `user` 行 + `system` 遥测的 session 仍有一条 `user` 记录,所以 `sessionId` 可找到;但一个假想的全 `system` 文件 → `sessionId` 为空 → `malformedJSON`/null(`sessionId`/`cwd`/`model`/`timestamp` 扫描只读 `user`/`assistant` 记录,Swift:53-58)。
13. **逐行 `version` 可在文件中途漂移**,跨 resume 上的 CLI 升级(LIVE 范围 `0.10.5`…`0.18.4`);两个适配器都不读它,所以任何 schema 漂移都是 **静默的**。「Session 版本」不是单值。
14. **大小/解析上限 Swift vs TS 不同 —— 且 Qwen 的截断是静默的。** TS 没有文件大小、行大小或消息数上限(流式读取一切)。Swift 限文件 100 MB / 行 8 MB / 消息 10,000 并加入读取中途的文件身份保护。**关键更正:** 因为 `QwenAdapter` 调用 `readObjects` 时不带 `reportFailures`(`QwenAdapter.swift:40,131`;`CodexAdapter.swift:61` 默认 `false`),对 Qwen 而言消息数和逐行字节上限是 **被吞掉而非浮现** —— 一个 >10,000 条记录的 session 被 **静默截断** 到前 10,000 个已解析对象(不抛出 `.messageLimitExceeded`,与 Codex 传 `reportFailures:true` 相反),一行 >8 MB 的行被静默跳过。TS 路径会完整读取这样的 session(无界)。只有 **`.fileTooLarge`**(读前 >100 MB,Swift 丢弃 / TS 保留)和 **`.fileModifiedDuringParse`**(`CodexAdapter.swift:79-80`,不受 `reportFailures` 门控)对 Qwen 实际浮现。
15. **文件身份保护(仅 Swift)。** 一个正在被追加的 LIVE session 可能触发 `.fileModifiedDuringParse` 并被重试 —— 这很常见,因为 Qwen 持续追加。
16. **内容连接分隔符已对齐。** Swift 与 TS 现在都用 `\n` 连接保留文本 part;当前 live 语料中有 0 条 assistant message 含多个非 thought 文本 part,所以这是面向未来 schema 的覆盖,不是当前 DB 计数变化。
17. **每次读取都整文件加载。** 两条路径都不使用流式 `windowedMessages` 辅助;分页读取每次都加载整个文件(对大 session 是每页 O(file))。
18. **文件名 ≠ Gemini 文法,无前缀过滤。** 裸 `<sessionId>.jsonl`,无 `session-` 前缀或时间戳 —— 且适配器 **不** 做前缀过滤(`chats/` 下任何 `.jsonl` 都被解析),不同于要求 `session-` 的 Gemini/iFlow。
19. **`tmp/<64-hex>/` 目录** 是 Gemini-fork 残留(项目哈希目录),与 `projects/` 下的人类 slug 目录平行。**已由源码确认**([`storage.ts`](https://raw.githubusercontent.com/QwenLM/qwen-code/main/packages/core/src/config/storage.ts)):`getProjectTempDir()` = `~/.qwen/tmp/<getProjectHash(cwd)>`,而 `getProjectHash(p)` = `crypto.createHash('sha256').update(normalizedPath).digest('hex')` —— 即(Windows 上先小写的)绝对 cwd 的 SHA-256 十六进制摘要(正好 64 个十六进制字符)。所以 `tmp/<64-hex>` 与 `projects/<encodedCwd>` 以两种方式命名 **同一个** 项目;只有 `projects/` 含 `chats/`。**大多数** tmp 目录含一个 `logs.json` 遥测文件(2026-07-01 live:17 个中 15 个;**2 个不含** —— 空/无日志),从无转录。Engram 只读 `projects/`。
20. **其他以 session 为键的产物存在于 `projects/` 之外。** `debug/<sessionId>.txt`(LIVE 749 个 INFO/DEBUG 日志,主干 == sessionId)和 `todos/<sessionId>.json`(4 个 LIVE,`{sessionId, todos:[{content,id,status}]}`)完全像转录一样以 `sessionId` 为键,却位于 `~/.qwen/` 顶层 —— 所以一个寻找「Qwen 写入的所有逐 session 数据」的读取者必须看 `projects/` 之外。两者都被忽略:适配器只枚举 `projects/<encodedCwd>/chats/*.jsonl`(`QwenAdapter.swift:22-36`)。根目录还有:全局 `memories/MEMORY.md`、`skills/<name>/`、`settings.json.orig`(均非 session 数据,均不读取)。

### 开放问题 / 已解决(web-confirmed 2026-06-21)

下列大部分条目已于 2026-06-21 对照 qwen-code 已发布源码核实。剩余的未知项和 Engram 内部设计选择已标注。

- **Confirmed (official):`system` 的 `subtype` 枚举远多于 LIVE 观察到的 3 种** —— `chat_compression`、`slash_command`、`ui_telemetry`、`at_command`、`attribution_snapshot`、`notification`、`cron`、`mid_turn_user_message`、`custom_title`、`rewind`、`agent_bootstrap`、`agent_launch_prompt`、`file_history_snapshot`。LIVE 观察到的 `{ui_telemetry, attribution_snapshot, slash_command}` 是子集;`chat_compression` 是一种压缩记录(见 §4、§12)。Engram 行为不受影响(除 `api_response` token 挖掘外所有 `system` 行都被丢弃)。 — [`chatRecordingService.ts`](https://raw.githubusercontent.com/QwenLM/qwen-code/main/packages/core/src/services/chatRecordingService.ts)
- **Confirmed (official):`<encodedCwd>` 编码规则来自 CLI 源码,而非推断。** `sanitizeCwd(cwd) = normalizedCwd.replace(/[^a-zA-Z0-9]/g, '-')`(Windows 先小写);`getProjectDir()` = `~/.qwen/projects/<sanitizeCwd(cwd)>`。每个非字母数字字符 → 单个 `-`,因此开头 `-` + 分隔符上的双破折号 + 有损 `_`/`.`→`-` 模式是精确的。 — [`paths.ts`](https://raw.githubusercontent.com/QwenLM/qwen-code/main/packages/core/src/utils/paths.ts)、[`storage.ts`](https://raw.githubusercontent.com/QwenLM/qwen-code/main/packages/core/src/config/storage.ts)(见 §2 命名文法)
- **Confirmed (official):`~/.qwen/tmp/<64-hex>/` 以 `getProjectHash(cwd)` 为键** = (Windows 先小写的)绝对 cwd 的 `crypto.createHash('sha256').update(normalizedPath).digest('hex')`(SHA-256 十六进制,64 字符),经 `getProjectTempDir()`。与 Gemini 分支相同的 `getProjectHash` 机制。`tmp/<64-hex>` 与 `projects/<encodedCwd>` 以两种方式命名同一项目;只有 `projects/` 含 `chats/`。 — [`storage.ts`](https://raw.githubusercontent.com/QwenLM/qwen-code/main/packages/core/src/config/storage.ts)、[`paths.ts`](https://raw.githubusercontent.com/QwenLM/qwen-code/main/packages/core/src/utils/paths.ts)、[Issue #2373](https://github.com/QwenLM/qwen-code/issues/2373)(见 §15 第 19 条)
- **Confirmed (official):不存在全局 `~/.qwen/projects.json` cwd→name 映射**(与 Gemini 的分歧属实)。Storage 层纯粹从 `sanitizeCwd(cwd)` 推导每项目目录;发现/恢复靠目录扫描。 — [`storage.ts`](https://raw.githubusercontent.com/QwenLM/qwen-code/main/packages/core/src/config/storage.ts)、[DeepWiki Insight pipeline](https://deepwiki.com/QwenLM/qwen-code/8.4-tool-development)
- **Confirmed (official):转录路径是 `~/.qwen/projects/<encodedCwd>/chats/<sessionId>.jsonl`**,文件名是裸 session UUID + `.jsonl`(无 `session-` 前缀,无时间戳)。`getTranscriptPath()` = `path.join(storage.getProjectDir(), 'chats', `${sessionId}.jsonl`)`。 — [`config.ts`](https://github.com/QwenLM/qwen-code/blob/main/packages/core/src/config/config.ts)、[`storage.ts`](https://raw.githubusercontent.com/QwenLM/qwen-code/main/packages/core/src/config/storage.ts)(见 §2)
- **Confirmed (official):Qwen 从不在 `user` 行写顶层 `model`,也没有 `message.model`。** `model` 仅由 `recordAssistantTurn` 设为顶层兄弟字段;`recordUserMessage`/`recordToolResult` 从不设它,而 `message` 是一个 `Content` 对象(role+parts),不含模型标识。因此 TS 适配器的 `message.model` 兜底(`qwen.ts:81`)**对所有当前及历史 qwen-code 输出都是死代码**。 — [`chatRecordingService.ts`](https://raw.githubusercontent.com/QwenLM/qwen-code/main/packages/core/src/services/chatRecordingService.ts)(见 §5、§15 映射)
- **Confirmed (official):对 Qwen 而言 `cacheCreationTokens:0` 是结构性永久的。** `usageMetadata` 是 Google GenAI 的 `GenerateContentResponseUsageMetadata` 类型,它有 `cachedContentTokenCount`(缓存 **读取**)但 **没有缓存创建字段**。 — [`chatRecordingService.ts`](https://raw.githubusercontent.com/QwenLM/qwen-code/main/packages/core/src/services/chatRecordingService.ts)、[字段参考](https://v03.api.js.langchain.com/interfaces/_langchain_google_common.types.GenerateContentResponseUsageMetadata.html)(见 §9.1)
- **Confirmed (official):仅 assistant 携带顶层 `model`/`usageMetadata`。** `createBaseRecord` 构建共享信封;`recordAssistantTurn` 添加顶层 `model` 与(存在时)`usageMetadata` + 可选 `contextWindowSize`。`recordUserMessage`/`recordToolResult` 两者都不设。 — [`chatRecordingService.ts`](https://raw.githubusercontent.com/QwenLM/qwen-code/main/packages/core/src/services/chatRecordingService.ts)
- **Confirmed (official):按行追加 JSONL 稳定;无 `$set`/整文件改写。** ChatRecordingService 为「Append-only writes (never rewrite the file)」;每次写入都是 `jsonl.writeLine(conversationFile, record)`。项目作用域 JSONL 系统明确替换了 OLD 单 JSON 格式,正是为了获得增量追加保存,所以回退到 `$set` 变更日志与既定设计方向相悖。 — [`chatRecordingService.ts`](https://raw.githubusercontent.com/QwenLM/qwen-code/main/packages/core/src/services/chatRecordingService.ts)、[Issue #2373](https://github.com/QwenLM/qwen-code/issues/2373)
- **Confirmed (partial, official):`user` 内容可携带多 part / 非 `text` parts。** `recordUserMessage` 接受经 `createUserContent` 包装的 `@google/genai` `PartListUnion`,因此一条 user 记录的 `parts` 可含多个 part 和非文本种类(尤其是 `inlineData`);`functionResponse` parts 出现在 `tool_result` 记录上,而非 user。从经验上所有采样的 LIVE session 都是单个 `[{text}]`,所以本文档此前的「始终单个 text part」对纯文本 session 准确,但格式允许多 part/`inlineData` —— `extractContent` 的「只保留 `.text`」会静默丢弃 `inlineData` part。 — [`chatRecordingService.ts`](https://raw.githubusercontent.com/QwenLM/qwen-code/main/packages/core/src/services/chatRecordingService.ts)(见 §6.2)
- `toolCallResult.errorType` 的完整枚举(LIVE 见到:`file_not_found`、`execution_denied`、`invalid_tool_params`、`unhandled_exception`、`edit_no_occurrence_found`)以及 `ui_telemetry.tool_call.decision`/`tool_type`(见到 `auto_accept`/`native`)(web-checked 2026-06-21: no authoritative source found —— 没有找到单一权威枚举文件;它们跨多个工具执行/遥测层发出,需要经认证的 GitHub 代码搜索作为下一步;低影响,因为整个 `tool_result` 类型都被丢弃)。
- `extract-cursor.json` 的作用(两种 LIVE 形态:`{updatedAt}` vs `{sessionId,processedOffset,updatedAt}`);`processedOffset` 是字节偏移还是记录索引未确认;写入方/消费方未确认(web-checked 2026-06-21: no authoritative source found —— `chatRecordingService.ts` 只写 `chats/<sessionId>.jsonl`,而 Insight pipeline 在 `~/.qwen/insights/facets/` 下以 session id 为键缓存,没有游标/检查点/`processedOffset` 文件;任何被检视的代码路径都不产生它)。
- `qwen-code.api_error` / `qwen-code.tool_call` 遥测是否也应喂入用量(Engram-internal design —— 不可由 web 验证)。格式事实(已确认):`api_error` 事件不携带 `usageMetadata`,且失败回合不产生 assistant `usageMetadata`,所以失败 API 调用的成本确实从逐回合用量字段中缺席;`tool_call` 遥测携带 `tool_token_count` 但没有 prompt/completion 拆分。 — [`chatRecordingService.ts`](https://raw.githubusercontent.com/QwenLM/qwen-code/main/packages/core/src/services/chatRecordingService.ts)
- **行为选择(Engram-internal design —— 不可由 web 验证):** 当前 Engram 会剥离推理(`thought:true`)文本,但仍将 `promptTokenCount` 直接映射为 inputTokens,不做缓存扣减(vs Gemini)。约束缓存扣减决定的格式事实(已确认):`promptTokenCount` 与 `cachedContentTokenCount` 是独立字段,所以如需可做缓存扣减。 — [`chatRecordingService.ts`](https://raw.githubusercontent.com/QwenLM/qwen-code/main/packages/core/src/services/chatRecordingService.ts)
- Engram 是否应为 Qwen 增加一条 `.engram.json` sidecar / originator 路径,用于确定性的 Claude-Code/Polycli 派发关联(Engram-internal design —— 不可由 web 验证)。格式事实(已确认):qwen-code 的 `ChatRecord` schema 没有跨 session 父字段也没有 originator 字段(`parentUuid` 仅 session 内),所以任何 sidecar/originator 路径都将是 Engram 增加的约定。 — [`chatRecordingService.ts`](https://raw.githubusercontent.com/QwenLM/qwen-code/main/packages/core/src/services/chatRecordingService.ts)

---

## 17. 附录:真实匿名样本

> 结构/键逐字保留;消息/推理/工具文本剥离为 `<TEXT>`/占位符;个人路径已缩减。

### 17.1 最小 LIVE session —— 3 条记录(user → ui_telemetry → assistant)

```jsonl
{"uuid":"0b7d3ecc-…-dbc39a20e637","parentUuid":null,"sessionId":"9ac9a7c3-…-2ce24fc677d6","timestamp":"2026-04-23T00:39:48.359Z","type":"user","cwd":"/Users/<u>/-Code-/engram","version":"0.15.0","gitBranch":"main","message":{"role":"user","parts":[{"text":"<TEXT>"}]}}
{"uuid":"ec79c67f-…","parentUuid":"0b7d3ecc-…","sessionId":"9ac9a7c3-…","timestamp":"2026-04-23T00:39:51.104Z","type":"system","subtype":"ui_telemetry","cwd":"/Users/<u>/-Code-/engram","version":"0.15.0","gitBranch":"main","systemPayload":{"uiEvent":{"event.name":"qwen-code.api_response","event.timestamp":"2026-04-23T00:39:51.103Z","response_id":"chatcmpl-…","model":"qwen3.5-plus","status_code":200,"duration_ms":2717,"input_token_count":16928,"output_token_count":40,"cached_content_token_count":0,"thoughts_token_count":21,"tool_token_count":0,"total_token_count":16968,"prompt_id":"db69c0b90dc7d","auth_type":"openai"}}}
{"uuid":"7171547f-…","parentUuid":"ec79c67f-…","sessionId":"9ac9a7c3-…","timestamp":"2026-04-23T00:39:51.130Z","type":"assistant","cwd":"/Users/<u>/-Code-/engram","version":"0.15.0","gitBranch":"main","model":"qwen3.5-plus","contextWindowSize":1000000,"usageMetadata":{"promptTokenCount":16928,"candidatesTokenCount":40,"thoughtsTokenCount":21,"totalTokenCount":16968,"cachedContentTokenCount":0},"message":{"role":"model","parts":[{"text":"<reasoning>","thought":true},{"text":"<final answer>"}]}}
```

### 17.2 批量多个工具调用的 assistant 记录(functionCall parts)

```json
{ "type": "assistant", "model": "qwen3.6-plus", "contextWindowSize": 1000000,
  "usageMetadata": { "promptTokenCount": 17297, "candidatesTokenCount": 533, "thoughtsTokenCount": 20, "totalTokenCount": 17830, "cachedContentTokenCount": 0 },
  "message": { "role": "model", "parts": [
    { "text": "<reasoning>", "thought": true },
    { "text": "<plan text>" },
    { "functionCall": { "id": "call_44de1922…", "name": "read_file", "args": { "file_path": "<path1>" } } },
    { "functionCall": { "id": "call_07ae16a2…", "name": "read_file", "args": { "file_path": "<path2>" } } }
  ] } }
```

### 17.3 `tool_result` 记录(成功 + 错误变体;被 Engram 丢弃)

```json
// success
{ "type":"tool_result", "uuid":"<uuid>", "parentUuid":"<uuid>", "sessionId":"<uuid>",
  "timestamp":"2026-04-23T02:11:28.503Z", "cwd":"<path>", "gitBranch":"main", "version":"0.15.0",
  "toolCallResult":{ "callId":"call_44de…", "status":"success", "resultDisplay":"<TEXT>" },
  "message":{ "role":"user", "parts":[ { "functionResponse":{
      "id":"call_44de…", "name":"read_file", "response":{ "output":"<TEXT>" } } } ] } }

// error
{ "type":"tool_result", "...":"...",
  "toolCallResult":{ "callId":"call_f511ad84…", "status":"error",
      "resultDisplay":"File not found: <path>", "error":{}, "errorType":"file_not_found" },
  "message":{ "role":"user", "parts":[ { "functionResponse":{
      "id":"call_f511ad84…", "name":"read_file", "response":{ "error":"File not found: <path>" } } } ] } }
```

### 17.4 `system/attribution_snapshot` 负载(辅助;丢弃)

```json
{ "type":"system", "subtype":"attribution_snapshot",
  "systemPayload": { "snapshot": {
    "type":"attribution-snapshot", "version":1, "surface":"cli",
    "fileStates":{}, "promptCount":1, "promptCountAtLastCommit":0 } } }
```

### 17.5 `system/slash_command` 负载(辅助;丢弃)

```json
{ "type":"system", "subtype":"slash_command", "systemPayload": { "phase":"invocation", "rawCommand":"/model" } }
```

### 17.6 `ui_telemetry` tool_call & api_error 事件(辅助;丢弃)

```json
{ "event.name":"qwen-code.tool_call", "event.timestamp":"…Z", "function_name":"read_file",
  "function_args":{ "file_path":"<path>" }, "duration_ms":755, "status":"success",
  "success":true, "decision":"auto_accept", "prompt_id":"0dbcd3638654a",
  "response_id":"chatcmpl-…", "tool_type":"native", "content_length":25062 }

{ "event.name":"qwen-code.api_error", "event.timestamp":"…Z", "response_id":"",
  "model":"qwen3.6-plus", "duration_ms":2769, "prompt_id":"84fb45f8bd654",
  "auth_type":"openai", "error_message":"Connection error. (cause: fetch failed)",
  "error_type":"APIConnectionError" }
```

### 17.7 辅助 / 账本文件(忽略)

```json
// projects/<encodedCwd>/meta.json
{ "version":1, "createdAt":"2026-05-07T00:51:25.767Z", "updatedAt":"2026-05-07T00:51:25.767Z" }

// projects/<encodedCwd>/extract-cursor.json  (two live shapes)
{ "updatedAt":"2026-05-07T00:54:20.137Z" }
{ "sessionId":"f16aad1d-…", "processedOffset":4, "updatedAt":"…Z" }

// tmp/<64-hex>/logs.json (row) — telemetry, NOT a transcript
{ "sessionId":"7f657511-…", "messageId":0, "type":"user", "message":"/model", "timestamp":"2026-02-22T12:30:57.941Z" }

// usage_record.jsonl (row)
{ "version":1, "sessionId":"19b4e448-…", "project":"/Users/<u>/-Code-/polycli", "durationMs":6033,
  "models":{ "qwen3.7-plus":{ "requests":2, "inputTokens":19179, "outputTokens":139, "cachedTokens":0, "thoughtsTokens":… } } }

// usage/token-usage-YYYY-MM.jsonl (row)
{ "schemaVersion":1, "id":"d7aae8bc-…", "sessionId":"7f640a35-…", "model":"qwen3.7-plus",
  "authType":"openai", "source":"main", "inputTokens":24564, "outputTokens":27 }
```

### 17.8 陈旧固件 session(`tests/fixtures/qwen/sample.jsonl`,v0.10.5 schema)

```jsonl
{"uuid":"q-001","parentUuid":null,"sessionId":"qwen-session-001","timestamp":"2026-01-20T09:00:00.000Z","type":"user","cwd":"/Users/test/my-project","version":"0.10.5","message":{"role":"user","parts":[{"text":"<TEXT>"}]}}
{"uuid":"q-002","parentUuid":"q-001","sessionId":"qwen-session-001","timestamp":"2026-01-20T09:00:08.000Z","type":"assistant","cwd":"/Users/test/my-project","version":"0.10.5","model":"qwen3.5-plus","message":{"role":"model","parts":[{"text":"<TEXT>"}]}}
{"uuid":"q-003","parentUuid":"q-002","sessionId":"qwen-session-001","timestamp":"2026-01-20T09:01:00.000Z","type":"user","cwd":"/Users/test/my-project","version":"0.10.5","message":{"role":"user","parts":[{"text":"<TEXT>"}]}}
```

### 17.9b `projects/` 之外的以 session 为键的产物(被适配器忽略)

```
// ~/.qwen/debug/<sessionId>.txt  (stem == sessionId; 1:1 with chats/<stem>.jsonl) — plaintext log, NOT JSON
2026-04-22T06:34:26.771Z [INFO] Config initialization started
2026-04-22T06:34:26.771Z [DEBUG] [HOOK_REGISTRY] Hook registry initialized with 0 hook entries
2026-04-22T06:34:26.771Z [DEBUG] MessageBus initialized with hook subscription
```

```json
// ~/.qwen/todos/<sessionId>.json  (sessionId == filename stem == a real transcript stem)
{ "sessionId": "1e34a19c-…-2b9d34641eea",
  "todos": [ { "content": "<TEXT>", "id": "…", "status": "completed" } ] }
```

### 17.9 血统对照 —— iFlow 行(共享家族根,不同消息主体)

```json
{"type":"user","sessionId":"session-iflow-001","message":{"role":"user","content":"<TEXT>"},"isSidechain":false,"userType":"external","cwd":"/Users/test/my-project","gitBranch":"main","version":"1.0.0"}
```
(iFlow = `message.content` 块,Claude/Anthropic 风格;Qwen = `message.parts[].text`,Gemini 风格。)

---

## 18. References (official sources)

于 2026-06-21 对照 QwenLM/qwen-code 仓库及相关类型参考核实。

- [QwenLM/qwen-code — `packages/core/src/utils/paths.ts`](https://raw.githubusercontent.com/QwenLM/qwen-code/main/packages/core/src/utils/paths.ts) — `sanitizeCwd`、`getProjectHash`。
- [QwenLM/qwen-code — `packages/core/src/config/storage.ts`](https://raw.githubusercontent.com/QwenLM/qwen-code/main/packages/core/src/config/storage.ts) — `getProjectDir`、`getProjectTempDir`。
- [QwenLM/qwen-code — `packages/core/src/services/chatRecordingService.ts`](https://raw.githubusercontent.com/QwenLM/qwen-code/main/packages/core/src/services/chatRecordingService.ts) — `ChatRecord` schema、append-only writes、`recordUserMessage`/`recordAssistantTurn`/`recordToolResult`。
- [QwenLM/qwen-code — `packages/core/src/config/config.ts`](https://github.com/QwenLM/qwen-code/blob/main/packages/core/src/config/config.ts) — `getTranscriptPath`。
- [QwenLM/qwen-code Issue #2373 — Portable Chat History](https://github.com/QwenLM/qwen-code/issues/2373) — `project_hash` / `getProjectHash`、tmp dir。
- [DeepWiki — QwenLM/qwen-code Insight Generation](https://deepwiki.com/QwenLM/qwen-code/8.4-tool-development) — `DataProcessor.scanChatFiles`、`insights/facets` 缓存。
- [Google GenAI `GenerateContentResponseUsageMetadata` field reference (LangChain.js types)](https://v03.api.js.langchain.com/interfaces/_langchain_google_common.types.GenerateContentResponseUsageMetadata.html) — `usageMetadata` 字段集(无缓存创建字段)。
