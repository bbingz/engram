# OpenCode 会话格式

> 本文档为英文权威版 opencode.md 的中文阅读副本;若有出入以英文版为准。

Last researched: 2026-06-21 (Engram session-format research workflow)

> **证据基础。** 三个来源交叉核对;冲突时以真实数据为准(差异已就地标注)。
> 1. **本机磁盘实存(LIVE on-disk store)** — `~/.local/share/opencode/opencode.db`(224.1 MB,WAL 模式;`-shm` 32 KB,`-wal` 0 B = 已 checkpoint)。22 张表,OpenCode 版本 `1.2.6`–`1.17.8`。计数:**21 个 project、386 个 session(全部 active,0 个 archived;165 个 root + 221 个 child)、7,445 行 `message`、36,331 行 `part`、190 行 `todo`、26 行 `session_message`、251 行 `event`**。已应用 21 个 Drizzle 迁移。
> 2. **仓库 parity fixture** — `tests/fixtures/adapter-parity/opencode/input/sample.db`(1 session / 2 messages / 2 parts,`schemaVersion: 1`)+ `success.expected.json`。反映 adapter 编写时所针对的**较旧、更窄的 18 列 schema**。`tests/fixtures/opencode/` 存在但为**空目录**(0 个文件);`tests/adapters/opencode.test.ts` 在运行时构建一个合成的 `sample.db` 并随后删除。
> 3. **Engram adapter(已编码)** — Swift 产品解析器 `macos/Shared/EngramCore/Adapters/Sources/OpenCodeAdapter.swift`(417 行,权威);TS 参考 `src/adapters/opencode.ts`(314 行,parity 镜像)。

---

## 1. 概览与 TL;DR

**是什么/在哪里/怎么存。** OpenCode(即 `sst/opencode` CLI/agent)将其**全部**对话语料——每个 project、session、message、内容块、todo 和 event——存放在**一个共享的 SQLite 数据库**中,位于 `~/.local/share/opencode/opencode.db`。这里**没有按会话拆分的 JSONL 文件,也没有按消息拆分的 JSON 文件**(与 Claude Code、Codex 或 Gemini CLI 不同)。schema 由 **Drizzle ORM** 管理(`__drizzle_migrations` + `migration` 表均存在;该存储已应用 21 个迁移)。

**心智模型。** 三个嵌套层级,Engram 都只读取其中一部分:

```
┌─ project (21 rows) ──────────────────────────────────────────────┐
│  worktree, vcs, name, icon, …            (Engram: NOT read)       │
│                                                                   │
│  ┌─ session (386 rows) ───────────────────────────────────────┐  │
│  │  id=ses_…, directory(cwd), title(summary), parent_id,       │  │
│  │  time_created/updated/archived, model, cost, tokens_* …     │  │
│  │  Engram reads: id, directory, title, time_*; filters archived│ │
│  │                                                             │  │
│  │  ┌─ message (7,445 rows) ── LAYER 2: envelope ───────────┐  │  │
│  │  │  id=msg_…, session_id, time_created/updated,           │  │  │
│  │  │  data = JSON {role, time, tokens, cost, finish, …}     │  │  │
│  │  │  Engram reads: role + (assistant) tokens               │  │  │
│  │  │                                                        │  │  │
│  │  │  ┌─ part (36,331 rows) ── LAYER 3: content block ───┐  │  │  │
│  │  │  │  id=prt_…, message_id, session_id, time_created,  │  │  │  │
│  │  │  │  data = JSON discriminated by `type`:             │  │  │  │
│  │  │  │    text(3,509) reasoning(6,090) tool(12,147)      │  │  │  │
│  │  │  │    step-start(6,775) step-finish(6,738)           │  │  │  │
│  │  │  │    patch(1,032) file(25) compaction(14) subtask(1)│  │  │  │
│  │  │  │  Engram reads: ONLY type=="text"  ◄── scope limit │  │  │  │
│  │  │  └──────────────────────────────────────────────────┘  │  │  │
│  │  └────────────────────────────────────────────────────────┘  │  │
│  └────────────────────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────────────────────┘
```

**面向 Engram 的 TL;DR。** Engram 以**只读**方式打开该 DB,通过一条 `SELECT … WHERE time_archived IS NULL` 列出 active 会话,为每个会话伪造一个虚拟定位符 `"{dbPath}::{sessionId}"`(不存在真实文件路径),再通过 JOIN `message ⋈ part` 重建 transcript,并**只保留 `type=="text"` 的 part**。工具调用、推理轨迹、补丁、文件以及子任务派发(约占所有 part 的 90%)虽在磁盘上,但**从不进入 Engram 的 transcript 或搜索索引**——这是有意的范围限制。每个会话的体积通过 `SUM(length(data))` 计算(**不是**对共享的 224 MB 文件做 `statSync`)。

---

## 2. 磁盘布局与文件命名

### 根目录 + 完整树(实存,已脱敏)

```
~/.local/share/opencode/
├── opencode.db            ← AUTHORITATIVE: all sessions/messages/parts (224.1 MB, WAL)
├── opencode.db-shm        ← shared-memory index (32 KB)
├── opencode.db-wal        ← write-ahead log (0 B here = checkpointed)
├── auth.json              ← provider OAuth/API credentials (0600)         (Engram: ignored)
├── account.json           ← logged-in account (0600)                      (Engram: ignored)
├── bin/                   ← downloaded provider/tool binaries              (Engram: ignored)
├── log/
│   └── opencode.log       ← runtime log, NOT session content              (Engram: ignored)
├── repos/                 ← (empty here) cloned repo working copies        (Engram: ignored)
├── snapshot/              ← per-project GIT object stores for file snapshots(Engram: ignored)
│   └── <project_id>/
│       └── <worktree_hash>/   ← a REAL bare-ish git repo:
│           ├── HEAD  config  description  index
│           ├── hooks/  info/  objects/  refs/
├── tool-output/           ← (empty here) overflow capture for large tool stdout (Engram: ignored)
└── storage/
    ├── migration/         ← migration markers                             (Engram: ignored)
    └── session_diff/      ← one JSON-array file PER SESSION (file-diff cache)
        ├── ses_2af53771bffeFqw1WrVD2KkPwT.json
        ├── ses_16ff4b89cffeYSrqS9o69S4jwK.json   (often `[]`)
        └── … (one per session)
```

Engram **只读取 `opencode.db`**。其余一切(`snapshot/`、`session_diff/`、`tool-output/`、`repos/`、`bin/`、`log/`、`auth.json`、`account.json`)都被 adapter 忽略。

> **历史注记。** 较旧的 OpenCode 版本曾使用 `storage/` 下的 JSON 树存放 transcript 内容;在现代 `sst/opencode` 布局上,只残留了一些退化的 sidecar(`migration/`、`session_diff/`)。transcript 内容现在专属于 DB。
> **已确认(官方):** [database.ts](https://github.com/sst/opencode/blob/dev/packages/core/src/database/database.ts) 把 `Global.Path.data` 与 `opencode.db` 拼接,并设置 `PRAGMA journal_mode=WAL`、`synchronous=NORMAL`、`busy_timeout=5000`、`foreign_keys=ON`。[DeepWiki Storage and Database](https://deepwiki.com/sst/opencode/2.9-storage-and-database) 确认 DB 位于 `Global.Path.data/opencode.db`,且有一个迁移引擎"遍历 legacy JSON 文件并批量插入 SQLite"(确认 `storage/` JSON 树是历史性的),以及 VCS 快照位于 `Global.Path.data/snapshot/[projectID]/[hash]` 用于文件级 undo/revert。注意:OpenCode 自己的写入器使用 5000 ms 的 busy-timeout;Engram 的只读打开器使用 30 s——这是一个独立的消费者,并非冲突。

### 命名语法

| 实体 | 列 / 文件 | 语法 | 实存示例 |
|---|---|---|---|
| Session id | `session.id` | `ses_` + 26 字符后缀(共 30)= **12 hex + 14 base62**(以时间戳为前缀 → 字典序 ≈ 时间序) | `ses_1182c0fb9ffegNnxixt6yu9qyO` |
| Message id | `message.id` | `msg_` + 26 字符后缀(12 hex + 14 base62) | `msg_c74a763870014VGxpaTjyvK3Sy` |
| Part id | `part.id` | `prt_` + 26 字符后缀(12 hex + 14 base62) | `prt_c74a76387002rncIB8Tc2txSAX` |
| Project id | `project.id` | 40 字符 hex(很可能是 worktree 路径的 SHA-1——派生方式为**推断**,未经源码确认) | `e8784f46a14602aaf5b98a02b9096ae8fc9ba30d` |
| `session_diff` 文件 | 文件名 | `<session_id>.json` | `ses_16ff4b89cffeYSrqS9o69S4jwK.json` |
| Snapshot 存储 | 目录 | `snapshot/<project_id>/<worktree_hash>/` | `snapshot/e8784f…/332bbe4f…/` |

> **已确认(官方):** ID 语法已从源码解码([id.ts](https://github.com/sst/opencode/blob/dev/packages/opencode/src/id/id.ts))。前缀恰为 `ses`/`msg`/`prt`(还有 event 的 `evt`、workspace 的 `wrk` 等)。`create()` 构造 `prefix + '_' + 12 hex chars + randomBase62(LENGTH-12)`,其中 `LENGTH=26` → 12 hex + 14 base62 = 26 字符后缀 → 共 30。前导 12 个 hex 字符把 `BigInt(timestamp_ms) * 0x1000 + counter` 编码为 6 字节(毫秒纪元 + 每毫秒 12 位计数器),所以升序 ID 在字典序/时间序上可排序;`timestamp(id)` 通过 `BigInt('0x'+hex) / 0x1000` 反解。先前的推断(base62 + 毫秒纪元 + 计数器)基本正确——此处修正:只有末尾 14 个字符是 base62,前导 12 个是 hex([id.ts](https://github.com/sst/opencode/blob/dev/packages/opencode/src/id/id.ts)、[session/schema.ts](https://github.com/sst/opencode/blob/dev/packages/opencode/src/session/schema.ts))。
> **Project id 派生(D2):** `project.id` 是一个 text PK(`ProjectV2.ID`),被 `session.project_id` 以 FK 引用——该列/关系已经源码确认,但"worktree 路径的 SHA-1"这一派生方式在本次审阅中**未**获源码确认。40 个 hex 字符与 SHA-1 一致,但应将该机制视为推断([sql.ts](https://github.com/sst/opencode/blob/dev/packages/core/src/session/sql.ts))。

### Engram 虚拟定位符

由于**每个会话没有文件路径**,Engram 合成一个虚拟定位符 `"{dbPath}::{sessionId}"`,例如:

```
/Users/<user>/.local/share/opencode/opencode.db::ses_1182c0fb9ffegNnxixt6yu9qyO
```

它从**右侧**拆分(`lastIndexOf("::")` / Swift `.backwards`),因此 db 路径中可能出现的 `::`(古怪的挂载点)不会破坏 session id。见 `OpenCodeAdapter.swift:116` / `:261-267`;`opencode.ts:75` / `:84-96`。

---

## 3. 文件生命周期与生成

- **存储技术:DB 而非文件,但 `message` 行会被例行性地反复触碰。** 内容在一个回合内作为新的 `message` + `part` 行追加写入,随后随着该回合/part 流定型,message 行的 `time_updated` 推进。实存证据:**7,439 / 7,445** 条 message 的 `time_updated > time_created`;只有 **6** 条 `time_updated == time_created`(且 0 条更早)。所以 `time_updated` 几乎在**每条** message 上都会推进——它跟踪的是回合/part 流的完成,**而非**罕见的重写。这些差值大多很小(6 个相等、31 个 <1s、6,348 个 <1min、1,060 个 ≥1min),符合定型而非后续编辑的特征。这里没有 JSONL 追加;持久性来自 SQLite WAL(`opencode.db-wal`)。
- **恢复(Resume)。** 恢复一个会话会在**同一个 `session.id`** 下追加更多 `message`/`part` 行;`session.time_updated` 推进。不会创建新文件(与 JSONL 工具相反,后者可能开启一份全新 transcript)。子 agent / 续接会话会获得一个非 NULL 的 `parent_id`(此处 386 中有 221 个)以及一个 `slug`。
- **无轮转(No rollover)。** 一切都在一个 DB 中 → 没有按对话拆分的文件轮转。唯一的增长控制是**上下文压实(context compaction)**(`time_compacting`、`compaction` part、`session_context_epoch` 表),它会就地汇总旧回合。
- **Archive = 软删除墓碑。** 会话通过设置 `session.time_archived` 来归档(**不是**通过移动/删除文件)。Engram 的 `WHERE time_archived IS NULL`(枚举 + `parseSessionInfo` + 可访问性)使归档对 Engram 不可见。实存:0 个 archived。硬删除通过 FK `ON DELETE CASCADE` 级联(删除一个会话会移除其 message/part/todo 行)。**已确认(官方):** `time_archived` 是一个可空的软删除列,会保留该行;FK 级联链(project←session←message←part,以及从 session 级联的 todo/session_message/session_context_epoch)是显式的([sql.ts](https://github.com/sst/opencode/blob/dev/packages/core/src/session/sql.ts)、[DeepWiki Session Management](https://deepwiki.com/sst/opencode/2.1-session-management))。
- **WAL 注意事项。** Engram 以只读方式打开(`SQLITE_OPEN_READONLY | SQLITE_OPEN_URI`,30 秒 busy-timeout)。以只读方式读取一个活跃的 WAL DB 可能在 checkpoint 前漏掉最新的未提交写入,但不会损坏;在下一次扫描时最终完成索引被视为足够(未观察到索引端的 `wal_checkpoint`/重试)。
- **副作用产物**(在 DB 之外,**不在** Engram 模型中):提交进每个 project git object 存储下的文件快照,位于 `snapshot/<project_id>/<hash>/`(真实 git:`HEAD`、`objects/`、`refs/`、`index`),以及位于 `storage/session_diff/<session_id>.json` 的按会话文件 diff 缓存(常为 `[]`)。

### Engram 如何发现 / 枚举会话

1. `detect()` → `fileExists(~/.local/share/opencode/opencode.db)`(`OpenCodeAdapter.swift:100-102`;`opencode.ts:58-60`)。
2. `listSessionLocators()`(Swift)/ `listSessionFiles()`(TS)以只读方式打开并运行 `SELECT id, directory, title, time_created, time_updated FROM session WHERE time_archived IS NULL ORDER BY time_updated DESC`,为每个 active 会话产出一个虚拟定位符(`swift:108-114`;`ts:68-76`)。
3. `parseSessionInfo(locator)` 重新打开,取回那一行 session 及其 messages,从首/末 message 的 `time_created` 推导 start/end(回退到 `session.time_created`),统计有内容的 user/assistant message,并计算按会话的 `sizeBytes`。
4. `streamMessages` 与 `isAccessible` 每次调用都重新打开。Swift 的 `isAccessible` 由一个 actor 隔离的 `Phase4SQLiteAccessibilityCache`(`swift:61-85`)支撑,它保留打开的句柄并重新检查 `SELECT 1 FROM session WHERE id=? LIMIT 1`——快速重新校验存在性而无需重开 224 MB 文件。TS 每次调用都重新打开(`ts:264-280`)——行为一致,仅有性能差异。

这里**没有文件系统遍历**——发现是一条 SQL `SELECT`,而"会话计数"是行数,绝非文件数。

---

## 4. 记录 / 表分类

该 DB 有 **22 张表**。Engram 恰好触碰 **3** 张(`session`、`message`、`part`)。其余都存在但不被读取。

| 表 | 实存行数 | Engram 读取? | 用途 / 关键列 |
|---|---:|---|---|
| `session` | 386 | ✅(5 列) | 每个对话一行;元数据、cwd、title、parent_id、time_*、model/cost/tokens 汇总 |
| `message` | 7,445 | ✅(envelope) | 每个回合一行;`data` JSON = role + 元数据;FK → session |
| `part` | 36,331 | ✅(仅 text) | 每个内容块一行;`data` JSON 按 `type` 区分;FK → message 与 session |
| `project` | 21 | ❌ | PK `id`;`worktree, vcs, name, icon_url, icon_color, time_* {created, updated, initialized}, sandboxes, commands, icon_url_override`(`time_initialized` 是一个独立的可空列) |
| `todo` | 190 | ❌ | 按会话的 todo 列表;PK `(session_id, position)`;`content, status, priority, time_*` |
| `session_message` | 26 | ❌ | **更新的**事件式表;`id, session_id, type, time_*, data, seq`;实存中确认只有 2 种 type:`agent-switched`(13)/ `model-switched`(13) |
| `event` | 251 | ❌ | 通用事件溯源日志;`id, aggregate_id, seq, type, data`;实存 `type` 枚举完全可观测——6 种 type:`message.part.updated.1`、`message.updated.1`、`session.created.1`、`session.next.agent.switched.1`、`session.next.model.switched.1`、`session.updated.1` |
| `event_sequence` | — | ❌ | `event` 的 aggregate seq 簿记 |
| `session_input` | 0 | ❌ | prompt 收件箱;`prompt, delivery, admitted_seq, promoted_seq` |
| `session_context_epoch` | 0 | ❌ | 压实基线;`baseline, snapshot, baseline_seq, replacement_seq, revision, agent` |
| `session_share` | 0 | ❌ | `id, secret, url` |
| `workspace` | 0 | ❌ | `type, name, branch, directory, extra, project_id, time_used` |
| `project_directory` | — | ❌ | `project_id, directory, type, strategy` |
| `permission` | — | ❌ | `project_id, action, resource`(与 `session.permission` JSON 不同) |
| `account` / `account_state` / `control_account` / `credential` | — | ❌ | 认证/密钥(**不是**会话数据) |
| `migration` / `data_migration` / `__drizzle_migrations` / `sqlite_sequence` | — | ❌ | Drizzle 簿记 |

> **schema 处于迁移中的信号。** 已被完全填充的 `message`/`part`(7,445/36,331)与稀疏、较新的 `session_message`(26)共存,表明在较新的 OpenCode 构建中存在一项进行中的事件溯源迁移。Engram 正确地停留在被填充的传统 `message`/`part` 路径上。如果未来某个 OpenCode 版本把 transcript 文本移入 `session_message`,adapter 的 `message ⋈ part` JOIN 将需要更新——目前还不是问题。

---

## 5. 共享 envelope / 元数据字段

`session` 行是记录级 envelope;`message.data` 是每回合 envelope。完整 session 列清单(实存 schema,29 列):

```sql
CREATE TABLE `session` (
  `id` text PRIMARY KEY, `project_id` text NOT NULL, `parent_id` text,
  `slug` text NOT NULL, `directory` text NOT NULL, `title` text NOT NULL,
  `version` text NOT NULL, `share_url` text,
  `summary_additions` integer, `summary_deletions` integer, `summary_files` integer,
  `summary_diffs` text, `revert` text, `permission` text,
  `time_created` integer NOT NULL, `time_updated` integer NOT NULL,
  `time_compacting` integer, `time_archived` integer,
  -- appended by later migrations (absent from v1 parity fixture):
  `workspace_id` text, `path` text, `agent` text, `model` text,
  `cost` real DEFAULT 0 NOT NULL,
  `tokens_input` integer DEFAULT 0 NOT NULL, `tokens_output` integer DEFAULT 0 NOT NULL,
  `tokens_reasoning` integer DEFAULT 0 NOT NULL,
  `tokens_cache_read` integer DEFAULT 0 NOT NULL, `tokens_cache_write` integer DEFAULT 0 NOT NULL,
  `metadata` text,
  CONSTRAINT fk_session_project_id_project_id_fk FOREIGN KEY (project_id)
    REFERENCES project(id) ON DELETE CASCADE);
-- indexes: session_project_idx, session_parent_idx, session_workspace_idx
```

> **已确认(官方):** 上述每一列与索引都与 [sql.ts](https://github.com/sst/opencode/blob/dev/packages/core/src/session/sql.ts) 中的 `SessionTable` 完全一致(id PK、project_id NN FK→project ON DELETE CASCADE、workspace_id、parent_id、slug NN、directory NN、path、title NN、version NN、share_url、summary_additions/_deletions/_files、summary_diffs(json)、metadata(json)、cost real NN default 0、tokens_input/output/reasoning/cache_read/cache_write integer NN default 0、revert(json)、permission(json Ruleset)、agent、model(json `{id, providerID, variant?}`)、time_created/time_updated、time_compacting、time_archived)。索引:`session_project_idx`、`session_workspace_idx`、`session_parent_idx`。重建的 DDL 准确。**源码位置注记(D3):** 权威的 Drizzle 表定义位于 `packages/core/src/session/sql.ts`(经 `packages/opencode/src/storage/schema.ts` 再导出);`packages/opencode/src/session/schema.ts` 只持有 ID brand 类型(MessageID/PartID),而非表 DDL。

| 列 | 类型 | 含义 | 可选 | Engram | 示例(脱敏) |
|---|---|---|---|---|---|
| `id` | text PK | `ses_` 前缀 id | 否 | **读取** → `id` + 定位符 | `ses_1182c0fb9ffegNnxixt6yu9qyO` |
| `project_id` | text NN FK→project | 所属 project | 否 | 忽略 | `e8784f46a14602aaf5b98a02b9096ae8fc9ba30d` |
| `parent_id` | text? FK | 父会话(子 agent 链接;索引 `session_parent_idx`) | 是 | **忽略**(未映射——见 §10) | `null`(root)/ `ses_…`(221/386) |
| `slug` | text NN | 人类可读 slug(**不是** title) | 否 | 忽略 | `nimble-nebula` |
| `directory` | text NN | 会话 cwd | 否 | **读取** → `cwd`(NULL 则 `""`) | `/Users/<user>/-Code-/<proj>` |
| `title` | text NN | 摘要行 | 否 | **读取** → `summary`(空 → nil) | `Ping` |
| `version` | text NN | 写入它的 OpenCode 版本 | 否 | 忽略 | `1.17.8`(实存跨 `1.2.6`–`1.17.8`) |
| `share_url` | text? | 分享 URL | 是 | 忽略 | `null` |
| `summary_additions` / `_deletions` / `_files` | int? | 会话 diff 汇总 | 是 | 忽略 | `0/0/0` |
| `summary_diffs` | text? | 序列化的 diff | 是 | 忽略 | `null` |
| `revert` | text? | revert/checkpoint JSON | 是 | 忽略 | `null` |
| `permission` | text?(JSON) | 权限规则数组 | 是 | 忽略 | `[{"permission":"todowrite","pattern":"*","action":"deny"}]` |
| `time_created` | int NN(epoch ms) | 创建;**回退**起始时间 | 否 | **读取**(回退) | `1782005887047` |
| `time_updated` | int NN(epoch ms) | 最近触碰;**列表 `ORDER BY` 键** | 否 | **读取**(仅排序) | `1782005893936` |
| `time_compacting` | int? | 上下文压实标记 | 是 | 忽略 | `null` |
| `time_archived` | int? | 软删除墓碑 | 是 | **过滤**(`WHERE … IS NULL`) | `null` |
| `workspace_id` | text? FK | workspace | 是 | 忽略 | `null` |
| `path` | text? | (较新)path | 是 | 忽略 | `null` |
| `agent` | text? | 活动 agent 模式 | 是 | 忽略 | `build`(106/386 设置) |
| `model` | text?(JSON) | model id blob | 是 | **忽略**(Engram model=nil) | `{"id":"deepseek-v4-pro","providerID":"opencode-go","variant":"default"}`(106/386) |
| `cost` | real NN(默认 0) | 汇总会话成本(USD) | 否 | **忽略**(按 message 重新推导) | `0.03949974`(227/386 > 0) |
| `tokens_input` / `_output` / `_reasoning` / `_cache_read` / `_cache_write` | int NN(默认 0) | 汇总会话用量 | 否 | **忽略**(重新推导) | `22625 / 3 / 35 / 0 / 0` |
| `metadata` | text?(JSON) | 最新元数据 blob | 是 | 忽略 | `null` |

> **差异(实存领先 fixture/adapter)。** `workspace_id, path, agent, model, cost, tokens_*, metadata`(13 列)由迁移 `20260510033149_session_usage` / `20260511173437_session-metadata` 添加,在 v1 parity fixture 中**缺失**。adapter 只 `SELECT` 原始 5 列(`id, directory, title, time_created, time_updated`),因此行为不受影响——但 Engram 从不呈现 OpenCode 的原生 model 或 cost。

---

## 6. Message 与内容 schema

### Layer 2 — `message` 表(envelope)

```sql
CREATE TABLE `message` (
  `id` text PRIMARY KEY, `session_id` text NOT NULL,
  `time_created` integer NOT NULL, `time_updated` integer NOT NULL, `data` text NOT NULL,
  CONSTRAINT fk_message_session_id_session_id_fk FOREIGN KEY (session_id)
    REFERENCES session(id) ON DELETE CASCADE);
-- index: message_session_time_created_id_idx (session_id, time_created, id)
```

| 列 | 类型 | 含义 | Engram | 示例 |
|---|---|---|---|---|
| `id` | text PK | `msg_` id | JOIN 到 `part.message_id`;合并键 | `msg_ee7d3f378001HIAuJOPQd0Yd1F` |
| `session_id` | text NN FK | 父会话 | **读取**(WHERE) | `ses_1182…` |
| `time_created` | int NN(ms) | message 时间戳;首/末驱动 start/end | **读取** → `timestamp` / `startTime` / `endTime` | `1782005887864` |
| `time_updated` | int NN(ms) | 定型标记——随回合/part 流完成而推进(7,439/7,445 > created;只有 6 == created) | 忽略 | 通常 > created |
| `data` | text NN(JSON) | envelope(role + 元数据) | **读取** → `role`、(assistant)`tokens` | 见下文 |

`data` blob **不**重复 `id`/`session_id`——它们只存在于列中。

> **已确认(官方):** 在 [sql.ts](https://github.com/sst/opencode/blob/dev/packages/core/src/session/sql.ts) 中,`message` 与 `part` 上的 JSON 列名为 **`data`**(`data: text({ mode: 'json' }).notNull()`),**不是** `info`。TS 类型为 `V1MessageData = Omit<SessionV1.Info, 'id'|'sessionID'>` 与 `V1PartData = Omit<SessionV1.Part, 'id'|'sessionID'|'messageID'>`——id/session_id/message_id 被显式从 blob 中省略,只存在于列中,与文档所述完全一致。(DeepWiki 的散文把该列称作 `info`;源码名 `data` 为权威。)

#### `message.data` — USER envelope

实存 key:`['role','time','agent','model','summary','tools','variant']`(最小变体:`['role','time','summary','agent','model']`)。

```json
{
  "role": "user",
  "time": { "created": 1782005887864 },
  "agent": "build",
  "model": { "providerID": "opencode-go", "modelID": "deepseek-v4-pro" },
  "summary": { "diffs": [] },
  "tools": { "todowrite": false, "todoread": false, "task": false },
  "variant": null
}
```

| 字段 | 类型 | 含义 | 可选 | Engram |
|---|---|---|---|---|
| `role` | `"user"` | 判别字段 | 否 | **读取** |
| `time.created` | int ms | 创建 | 否 | 忽略(用 DB 列) |
| `agent` | string | 派发 agent | 是 | 忽略 |
| `model` | `{providerID, modelID}` | 目标 model | 是 | 忽略 |
| `summary.diffs` | array | 每回合 diff 汇总 | 是 | 忽略 |
| `tools` | obj `<name,bool>` | 工具启用映射 | 是 | 忽略 |
| `variant` | string\|null | variant | 是 | 忽略 |

#### `message.data` — ASSISTANT envelope

实存 key:`['role','time','parentID','modelID','providerID','mode','agent','path','cost','tokens','finish']`(完整变体增加 `'error','summary','variant'`)。

```json
{
  "role": "assistant",
  "time": { "created": 1771483653013, "completed": 1771483657730 },
  "parentID": "msg_c74a763870014VGxpaTjyvK3Sy",
  "modelID": "deepseek-v4-pro",
  "providerID": "opencode-go",
  "mode": "build",
  "agent": "build",
  "path": { "cwd": "/Users/.../mediahub", "root": "/Users/.../mediahub" },
  "cost": 0.03949974,
  "tokens": {
    "total": 22663, "input": 22625, "output": 3, "reasoning": 35,
    "cache": { "read": 0, "write": 0 }
  },
  "finish": "stop"
}
```

| 字段 | 类型 | 含义 | 可选 | Engram |
|---|---|---|---|---|
| `role` | `"assistant"` | 判别字段 | 否 | **读取** |
| `parentID` | text | 被回答的 user `msg_`(回合链接) | 是 | 忽略 |
| `mode` / `agent` | string | mode / agent | 是 | 忽略 |
| `path` | `{cwd, root}` | 执行目录 | 是 | 忽略 |
| `cost` | float | message 成本(USD) | 是 | 忽略 |
| `tokens.total` | int | 总和 | 是 | **忽略**(重新计算) |
| `tokens.input` | int | prompt tokens | 是 | **读取** → inputTokens |
| `tokens.output` | int | completion tokens | 是 | **读取** → outputTokens(含 reasoning) |
| `tokens.reasoning` | int | reasoning tokens | 是 | **读取** → 折入 outputTokens |
| `tokens.cache.read` | int | cache-read | 是 | **读取** → cacheReadTokens |
| `tokens.cache.write` | int | cache-create | 是 | **读取** → cacheCreationTokens |
| `modelID` / `providerID` | string | model + provider | 是 | 忽略 |
| `time.created` / `time.completed` | int ms | 生成窗口 | 是 | 忽略 |
| `finish` | string | 完成原因(`stop`、`tool-calls`、…) | 是 | 忽略 |
| `error` | obj | provider 错误 | 是 | 忽略 |
| `summary` | bool/obj | 摘要标记 | 是 | 忽略 |
| `variant` | string | variant | 是 | 忽略 |

Assistant **error** 形状(降级回合):

```json
{
  "name": "APIError",
  "data": {
    "message": "Invalid Authentication",
    "statusCode": 401,
    "isRetryable": false,
    "responseHeaders": { "...": "..." }
  }
}
```

Engram 只读取 `role`(必须是 `user`/`assistant`;其他一律跳过),并对 assistant 将 `tokens` → `TokenUsage`。它忽略 `time`、`modelID`/`providerID`/`model`、`agent`、`mode`、`path`、`cost`、`finish`、`parentID`、`summary`、`error`。

> **已确认(官方):** message envelope 字段与 [v1/session.ts](https://github.com/sst/opencode/blob/dev/packages/core/src/v1/session.ts) 一致。`AssistantMessage` 有 `role:'assistant'`、`parentID`(MessageID)、`modelID`、`providerID`、`cost`、`tokens{input/output/reasoning/cache{read,write}}`、可选的 `finish`(String)。`UserMessage` 有 `role:'user'`,带 `providerID`/`modelID`。token 嵌套(input/output/reasoning + cache.read/cache.write)与 §9 的映射一致。

### Layer 3 — `part` 表(内容块——真正的 transcript 文本)

```sql
CREATE TABLE `part` (
  `id` text PRIMARY KEY, `message_id` text NOT NULL, `session_id` text NOT NULL,
  `time_created` integer NOT NULL, `time_updated` integer NOT NULL, `data` text NOT NULL,
  CONSTRAINT fk_part_message_id_message_id_fk FOREIGN KEY (message_id)
    REFERENCES message(id) ON DELETE CASCADE);
-- indexes: part_session_idx (session_id); part_message_id_id_idx (message_id, id)
```

| 列 | 类型 | 含义 | Engram | 示例 |
|---|---|---|---|---|
| `id` | text PK | `prt_` id | 忽略 | `prt_c74a76387002rncIB8Tc2txSAX` |
| `message_id` | text NN FK→message | **JOIN 键** | **读取**(JOIN + 按 msg 合并) | `msg_c74a763870014VGxpaTjyvK3Sy` |
| `session_id` | text NN FK | 父会话(反规范化;已索引) | 忽略(用 JOIN) | `ses_38b589c7…` |
| `time_created` | int NN(ms) | message 内排序的次级判别 | 次级 `ORDER BY` | `1771483653006` |
| `time_updated` | int NN(ms) | 重写标记 | 忽略 | `1771483653006` |
| `data` | text NN(JSON) | 内容块,**按 `type` 区分** | **读取**(仅 `type=="text"`) | 见下文 |

**Part `type` 分布(实存,36,331 个 part):**

| `type` | 计数 | data key(实存) | Engram 使用? |
|---|---:|---|---|
| `tool` | 12,147 | `type, callID, tool, state{status,input,output,title,metadata,time}` | ❌ |
| `step-start` | 6,775 | `type`(其中 5,530 个有 `snapshot`) | ❌ |
| `step-finish` | 6,738 | `type, reason, cost, tokens`(其中 5,499 个有 `snapshot`) | ❌ |
| `reasoning` | 6,090 | `type, text, time` | ❌ |
| **`text`** | **3,509** | **`type, text`**(+ 可选 `time`、`synthetic`) | ✅ **仅此** |
| `patch` | 1,032 | `type, hash, files` | ❌ |
| `file` | 25 | `type, mime, filename, url, source` | ❌ |
| `compaction` | 14 | `type, auto`(其中 12 个有 `overflow`) | ❌ |
| `subtask` | 1 | `type, agent, command, description, model, prompt` | ❌ |

所有顶层 part key 的并集(实存):`['type','text','time','callID','tool','state','reason','cost','tokens','hash','files','mime','filename','url','source','auto','overflow','snapshot','synthetic','metadata']`。

> **已确认(官方):** part 的 `type` 判别联合与 [v1/session.ts](https://github.com/sst/opencode/blob/dev/packages/core/src/v1/session.ts) 一致——`text`(可选 `synthetic`)、`reasoning`、`tool`(`callID`)、`step-start`、`step-finish`(`cost` + `tokens{input/output/reasoning/cache{read,write}}`)、`file`、`patch`、`compaction`、`subtask`(`model{providerID,modelID}`)。文档记录的全部 9 种 type 都存在。源码还额外把 `snapshot`、`agent`、`retry` 定义为各自的 part literal(`snapshot` 同时也作为 step part 上的顶层字段出现)——这不与任何文档主张冲突。

#### 6a. `type:"text"`(已解析——Engram 读取的唯一 type)

```json
{
  "type": "text",
  "text": "<str len=834>",
  "time": { "start": 1771483678610, "end": 1771483678610 }
}
```

| 字段 | 类型 | 含义 | 可选 | Engram |
|---|---|---|---|---|
| `type` | `"text"` | 判别字段 | 否 | **读取**(trim、lowercase == `text`) |
| `text` | string | 可见内容 | 否 | **读取** → `content`(回退 `value`) |
| `time.start` / `.end` | int ms | 渲染窗口 | 是 | 忽略 |
| `synthetic` | bool | 注入(非用户)文本——21 行 | 是 | 忽略 |

Engram 接受 `text` 或 `value`(`opencode.ts:239`;`swift:322-323,368-369`),丢弃空/仅空白内容。**空 text → message 从计数中排除**(Swift `contentfulRole`)。

#### 6b. `type:"reasoning"`(忽略——在磁盘上,但从不索引)

```json
{ "type": "reasoning", "text": "<str len=…>", "time": { "start": …, "end": … } }
```

形状与 `text` 相同但 `type=="reasoning"` → 被排除。**推理轨迹(6,090)虽被存储,但从不进入 Engram 的 transcript 或搜索索引。**

#### 6c. `type:"step-start"` / `"step-finish"`(LLM step 边界——忽略)

```json
{ "type": "step-start" }
```
```json
{
  "type": "step-finish", "reason": "tool-calls", "cost": 0,
  "tokens": { "total": 11660, "input": 9536, "output": 63, "reasoning": 23,
              "cache": { "read": 2061, "write": 0 } }
}
```

`step-finish` 携带每个 step 的 `reason` / `cost` / `tokens`(token 形状与 message envelope 相同)。许多 step 行还携带一个顶层 `snapshot`(git ref)。全部忽略。

#### 6d. `type:"patch"` / `type:"file"` / `type:"compaction"`(忽略)

```json
{ "type": "patch", "hash": "9fcfa4ef9a95a4b8ccdd1910f1f0e07388c5c026",
  "files": ["/Users/.../inference.js"] }
```
```json
{ "type": "file", "mime": "image/jpeg", "filename": "Bing_…jpg",
  "url": "<str len=198235>",
  "source": { "text": {"value":"[Image 1]","start":18,"end":27},
              "type": "file", "path": "Bing_…jpg" } }
```
```json
{ "type": "compaction", "auto": true }
```

`file.url` 是 base64 **data URL**(约 200 KB;一个真实的按会话体积推手)。`source` 把附件关联到 prompt 中的一个 span。`compaction.auto` = 自动 vs 手动。

#### 6e. `type:"subtask"`(子 agent 派发——忽略;见 §10)

```json
{
  "type": "subtask", "agent": "build",
  "description": "review changes [...]", "command": "review",
  "model": { "providerID": "kimi-for-coding", "modelID": "k2p5" },
  "prompt": "<str len=4657>"
}
```

### 重建 / 合并模型

Engram JOIN `message m JOIN part p ON p.message_id = m.id WHERE m.session_id=? ORDER BY m.time_created ASC, p.time_created ASC`(`swift:230-239`;`ts:208-215`)。它只保留有非空内容的 `type=="text"` part,然后将**一条 message 的所有 text part** 用 `\n` **拼接**为单个 `NormalizedMessage`(`messages(from:)` `swift:330-353`;`ts:225-256`)。发出的 `timestamp` = **message** 的 `time_created`,**不是** part 的 `time.start`。

---

## 7. 工具调用与结果

OpenCode 对工具调用的存储很丰富——但 **Engram 不消费其中任何一项**(`toolCalls` 永远为 `nil`,`toolMessageCount` 硬编码为 `0`)。此处仅为完整性而记录;所有 `type:"tool"` part 都被丢弃。

**链接模型(独特)。** 与 Claude Code / Codex 把工具请求和其结果拆分到不同记录不同,OpenCode 把**调用和结果存在同一个 `part`** 中:`state.input` = 请求,`state.output`/`state.error` = 结果,由 `state` 生命周期串联。`callID` 与 provider 的 tool-call id 相关。

实存 state 状态:`completed`(11,674)、`error`(472)、`running`(1)。所见工具:`read, bash, grep, edit, glob, write, task, todowrite`、MCP 命名空间(`chrome-devtools_*`、`codegraph_codegraph_*`、`MiniMax_*`)、`webfetch/websearch`、`skill`、`question`、`invalid`。

```json
{
  "type": "tool", "callID": "call_function_4cgbasugl504_1", "tool": "bash",
  "state": {
    "status": "completed",
    "input":  { "command": "...", "description": "..." },
    "output": "<...len=37116>",
    "title":  "...",
    "metadata": { "output": "<...>", "exit": 0, "description": "...", "truncated": false },
    "time": { "start": 1771483657599, "end": 1771483657647 }
  }
}
```

| 字段 | 类型 | 含义 | 可选 |
|---|---|---|---|
| `type` | `"tool"` | 判别字段 | 否 |
| `callID` | string | **tool-call id**——链接请求↔结果 | 否 |
| `tool` | string | 工具名 | 否 |
| `state.status` | `pending\|running\|completed\|error` | 生命周期 | 否 |
| `state.input` | obj | 工具参数(按工具形状) | 启动时 |
| `state.output` | string | 结果文本 | completed |
| `state.title` | string | 标签 | 是 |
| `state.metadata` | obj | 按工具的额外项(`exit`、`truncated`、`diff`、`filediff`、`diagnostics`、`sessionId`、`model`) | 是 |
| `state.error` | string | 错误文本 | 仅 error |
| `state.time.start` / `.end` | int ms | 执行窗口 | 是 |

`error` 状态:
```json
{ "type":"tool","callID":"call_cb609c3a04814448b5b5f5bf","tool":"read",
  "state":{ "status":"error","input":{"filePath":"..."},
            "error":"Error: File not found: ...","time":{"start":…,"end":…}}}
```

`running` 的 `task` 增加 `state.metadata.sessionId`(子会话 id)+ `state.metadata.model`。`edit` 的 `state.metadata`:`{ "diagnostics":{}, "diff":"<…>", "filediff":{"file":"…","before":"<…>","after":"<…>","additions":4,"deletions":4}, "truncated":false }`。

---

## 8. 推理 / thinking

**已存储但不索引。** OpenCode 把模型的思维链持久化为 `type:"reasoning"` part(本存储中有 6,090 个)——形状与 `text` 相同 `{type, text, time}`。Engram 丢弃它们(只有 `type=="text"` 存活)。推理也以数值形式被记录在 `message.data.tokens.reasoning` 中,这一项 Engram **确实**会读取(折入 `outputTokens`)。所以 Engram 捕获推理 token 的*数量*,却从不捕获推理轨迹的*内容*。

---

## 9. Token 用量与成本

OpenCode 在**三个**层级记录用量;Engram 只从其中一个(按 message 的 envelope)推导:

1. **会话汇总**(`session.cost`、`session.tokens_input/output/reasoning/cache_read/cache_write`)——由 2026-05 迁移添加的权威聚合值。**Engram 忽略它们。**
2. **按 message**(`message.data.tokens`,仅 assistant)——**Engram 使用的来源。**
3. **按 step**(`step-finish.tokens`)——忽略。

### 按 message 的 token 映射(仅 assistant)

| Engram `TokenUsage` | OpenCode `message.data.tokens` | 变换 | Swift 行(TS) |
|---|---|---|---|
| `inputTokens` | `tokens.input` | 直传 | `:390`(`:284`) |
| `outputTokens` | `tokens.output + tokens.reasoning` | **求和** | `:391`(`:285`) |
| `cacheReadTokens` | `tokens.cache.read` | 直传 | `:392`(`:286`) |
| `cacheCreationTokens` | `tokens.cache.write` | 直传 | `:393`(`:287`) |

规则:`tokens.total` 被**忽略**(重新计算)。若四个计数器全为 0,则 Usage 返回 `nil`(`swift:394-401`;`ts:289-295`)。Usage 只附着到 **assistant** message(`swift:381`;`ts:253`)。Engram **不呈现任何 OpenCode 成本**(`cost` 列不被读取)。

> **由 parity fixture 验证:** `outputTokens=50` = `output 45 + reasoning 5`;`inputTokens=123`、`cacheReadTokens=67`、`cacheCreationTokens=8`。
> **已确认(官方):** OpenCode 确实维护权威的会话级汇总(`session.cost`、`tokens_input/output/reasoning/cache_read/cache_write`),作为存储/更新的计数器列([sql.ts](https://github.com/sst/opencode/blob/dev/packages/core/src/session/sql.ts))。Engram 是否呈现它们而非按 message 重新推导,属于 Engram 内部设计选择(无法通过 web 验证)。
> **未决(OPEN):** DB 的会话级汇总是否始终等于按 message envelope 之和,未做相等性验证。这些列被定义为存储计数器,而非保证 `= SUM(per-message)` 的不变量;它们可能在压实/摘要回合或非 message 的 token 计费上发生偏离。(web-checked 2026-06-21: no authoritative source found asserting strict equality)

---

## 10. 子 agent / 父子 / 派发

OpenCode **在三处原生记录**父/子谱系——但 adapter **一处都不消费**(`parentSessionId: nil`,`swift:209`):

1. `session.parent_id` — 已确认的父链接(FK,索引 `session_parent_idx`)。本存储中 **386 个会话里有 221 个是 child**。
2. `message.data.parentID` — 每回合链接(assistant `msg_` → user `msg_`)。
3. `subtask` part + 带 `state.metadata.sessionId` 的 `tool` part(`task` 工具)——在派发时携带被派发的子会话 id。

由于 adapter 硬编码 `parentSessionId: nil`,OpenCode 的子 agent 谱系对 Engram 的确定性父检测(Layer 1)**不可见**。它只能由启发式 Layer 2 回填推断。这是一个明显的确定性谱系缺口。

> **已确认(官方):** `session.parent_id` 原生记录子/子 agent 谱系——[DeepWiki Session Management](https://deepwiki.com/sst/opencode/2.1-session-management) 指出它"用于从主对话派生的子 agent 或任务",[sql.ts](https://github.com/sst/opencode/blob/dev/packages/core/src/session/sql.ts) 将其显示为可空、已索引(`session_parent_idx`)的 FK。FK 级联链是显式的:project←session(ON DELETE CASCADE)、session←message(CASCADE)、message←part(CASCADE)、session←todo/session_message/session_context_epoch(CASCADE)。
> **Engram 内部设计——无法通过 web 验证:** 未来某个 Engram 层是否应将 `session.parent_id` → `NormalizedSessionInfo.parentSessionId` 接通,以实现 Layer-1 式的确定性 OpenCode 子 agent 分组;以及 Engram 的启发式检测是否与原生 `parent_id` 一致。OpenCode 一侧已尘埃落定(见上);消费决策是 Engram 的产品选择。

---

## 11. 摘要 / 压实

OpenCode 有**就地上下文压实**(无文件轮转):
- `session.time_compacting` — 压实进行中标记。
- `type:"compaction"` part(此处 14 个;`{type, auto, overflow?}`)——在 transcript 中标记一次压实事件。
- `session_context_epoch` 表(此处 0 行)——压实基线/快照。
- `user` 的 `message.data.summary.diffs` 与 `summary_additions/_deletions/_files` 列——每回合 diff 汇总。

Engram **一项都不消费**。`session.title`(映射到 Engram `summary`)是生成的标题,不是压实摘要。

> **已确认(官方):** [sql.ts](https://github.com/sst/opencode/blob/dev/packages/core/src/session/sql.ts) 显示 `session.time_compacting`(可空整数,压实进行中标记)以及 `SessionContextEpochTable`,后者带 `session_id` PK FK→session ON DELETE CASCADE、`baseline`、`agent`、`snapshot`(json SystemContext.Snapshot)、`baseline_seq`、`replacement_seq`、`revision`——与上面的压实描述一致。

---

## 12. SQLite / DB 内部

OpenCode **本身就是**一个 DB 支撑的工具——这是该格式的核心。22 表 schema 由 Drizzle 管理(`__drizzle_migrations`,已应用 21 个迁移;观察到的最新为 `20260612174303_project_dir_strategy`)。Engram 只读 `session` / `message` / `part`;它们的完整 DDL 见 §5/§6。关键关系事实:

- **FK 级联链:** `project ← session ← message ← part`(全部 `ON DELETE CASCADE`);`todo`、`session_message` 等从 `session` 级联。
- **Engram 受益的索引:** `message_session_time_created_id_idx (session_id, time_created, id)`(驱动有序的 message 扫描);`part_message_id_id_idx (message_id, id)` 和 `part_session_idx (session_id)`(驱动 JOIN)。
- **通过 SQL 计算按会话体积**(**不是** file stat)——见 §15 注意点 #7。
- **只读访问:** `SQLITE_OPEN_READONLY | SQLITE_OPEN_URI`,30 秒 busy-timeout(`swift:8,14`);TS 通过 `better-sqlite3` 使用 `{ readonly: true }`(`ts:67`)。

按表清单(哪些表存在、行数、用途、读取状态)见 §4。

---

## 13. 辅助文件

| 产物 | 位置 | Engram | 用途 |
|---|---|---|---|
| WAL/SHM | `opencode.db-wal`、`opencode.db-shm` | 通过主 DB 以只读方式打开 | SQLite 持久性/索引 |
| Auth | `auth.json`、`account.json`(0600) | 忽略 | provider OAuth/API 凭证、已登录账户 |
| Provider 二进制 | `bin/` | 忽略 | 下载的工具/provider 二进制 |
| 运行时日志 | `log/opencode.log` | 忽略 | 运行时日志(**不是**会话内容) |
| 文件快照 | `snapshot/<project_id>/<hash>/` | 忽略 | 真实的按 project git object 存储(`HEAD`、`objects/`、`refs/`、`index`) |
| 文件 diff 缓存 | `storage/session_diff/<session_id>.json` | 忽略 | 按会话 diff 缓存(常为 `[]`) |
| 工具输出溢出 | `tool-output/`(此处为空) | 忽略 | 大型工具 stdout 的溢出捕获 |
| 迁移标记 | `storage/migration/` | 忽略 | 迁移簿记 |

除 DB 本身外,OpenCode **没有**任何 Engram 可读的索引、sidecar 或缓存。

---

## 14. Engram 映射

`file:line` 指的是 **Swift 产品解析器**(`OpenCodeAdapter.swift`);括号内为 TS 参考(`opencode.ts`)的行号。

### Session → `NormalizedSessionInfo`

| Engram 字段 | OpenCode 来源 | 变换 | Swift:line(TS) |
|---|---|---|---|
| `id` | `session.id` | 直传;回退到定位符的 sessionId | `:182`(`:172`) |
| `source` | 常量 | `.opencode` | `:88,:183`(`:50,:173`) |
| `summary` | `session.title` | 空 → `nil` | `:196-199`(`:182`) |
| `cwd` | `session.directory` | 直传;NULL 则 `""` | `:188`(`:176`) |
| `project` | — | **永远 `nil`**(不从 `project.worktree`/`name` 推导) | `:189`(TS 省略该字段) |
| `model` | — | **永远 `nil`**(尽管 `session.model` 存在) | `:190`(TS 省略) |
| `startTime` | 首个 `message.time_created`,否则 `session.time_created` | epoch ms → ISO8601(÷1000) | `:175-178`(`:130,:134`) |
| `endTime` | 末个 `message.time_created` | **仅当 `messages.count > 1`**,否则 `nil` | `:185-187`(`:131-138`) |
| `messageCount` | 派生 | `userCount + assistantCount`(仅 text-part——见 §15) | `:191`(`:177`) |
| `userMessageCount` | 派生 | role=user 且有 ≥1 个非空 text part 的不同 `msg.id` | `:172,:192`(`:140-145,:177`) |
| `assistantMessageCount` | 派生 | role=assistant 且有 ≥1 个非空 text part 的不同 `msg.id` | `:173,:193`(`:146,:179`) |
| `toolMessageCount` | — | 硬编码 `0` | `:194`(`:180`) |
| `systemMessageCount` | — | 硬编码 `0` | `:195`(`:181`) |
| `sizeBytes` | 本会话的 `Σ length(message.data) + Σ length(part.data)` | 按会话的 SQL 字节求和 | `:201,:269-298`(`:156-169`) |
| `filePath` | 虚拟定位符 | `"{dbPath}::{id}"` | `:200`(`:183`) |
| `parentSessionId` | — | **永远 `nil`**——`session.parent_id` 不读(§10) | `:209`(TS 省略) |
| `suggestedParentId` / `agentRole` / `originator` / `origin` / `summaryMessageCount` / `tier` / `qualityScore` / `indexedAt` | — | 全部 `nil`(稍后由 indexer/回填设置) | `:202-210`(不适用) |

### 按 message → `NormalizedMessage`

| Engram 字段 | OpenCode 来源 | 备注 | Swift:line(TS) |
|---|---|---|---|
| `role` | `message.data.role` | 只有 `user`/`assistant` 存活 → `.user`/`.assistant` | `:361-362,:378`(`:237,:249`) |
| `content` | `part.data.text`(回退 `part.data.value`) | **仅 `type=="text"` part**;空的丢弃;多个 part 用 `\n` 拼接 | `:322-323,:337,:368-370`(`:238-240`) |
| `timestamp` | `message.time_created` | epoch ms → ISO8601 | `:374-375`(`:251`) |
| `toolCalls` | — | 永远 `nil`(tool part 被丢弃) | `:345`(`:248` 省略) |
| `usage` | `message.data.tokens`(仅 assistant) | 见 §9 token 映射 | `:381`(`:253`) |

### 定位符辅助

| 关注点 | Swift:line | TS:line |
|---|---|---|
| 默认 db 路径 | `:93-95` | `:53-55` |
| `detect()` = fileExists | `:100-102` | `:58-60` |
| 列表查询 | `:108-114` | `:68-76` |
| 虚拟定位符构建 `"{dbPath}::{id}"` | `:116` | `:75` |
| 从右拆分(`lastIndexOf`/`.backwards`) | `:261-267` | `:84-96` |
| 只读打开 | `:8,14` | `:67` |
| `isAccessible`(缓存 actor / 重开) | `:61-85,:249-259` | `:264-280` |
| 按会话字节求和 | `:269-298` | `:156-169` |

---

## 15. 谱系、注意点、版本漂移与边界情况

### 共享格式谱系

OpenCode 在**架构上不同于**每一个其他 Engram 来源,是"共享 SQLite 关系型、三表(session/message/part)、列内 JSON-blob、虚拟 `db::id` 定位符"模式的**唯一成员**:

- **不属于 JSONL 家族。** Gemini-CLI ↔ Qwen ↔ iFlow 谱系使用按 project 的 JSONL transcript 以及共享的 `Phase4AdapterSupport` JSON 辅助函数(`isoFromMilliseconds`、`double`、`jsonObject`,定义于 `GeminiCliAdapter.swift:3-58`)。OpenCode **复用了这些辅助函数**,但在其上叠加了自己的 `Phase4SQLiteDatabase` 读取器(`OpenCodeAdapter.swift:4-59`)——它共享辅助函数,而非磁盘格式。
- **不属于 `.vscdb` 家族。** Cursor / VS Code / Copilot / Cline 使用带 VS Code 键值 `ItemTable`(leveldb 风格 blob 存储)的 SQLite `.vscdb`。OpenCode **只共享 SQLite 容器**,而非 schema——OpenCode 是规范化的 Drizzle 关系型 schema。最近的表亲是 Cursor,但仅在"碰巧用 SQLite"这一层面。
- **显示分组。** 一等的独立来源:`SourceCatalog.swift:29`(`opencode` → `~/.local/share/opencode/opencode.db`)、`SourceColors.swift:19`(颜色 `Color.primary`)、`:49`、`:63`(显示 "OpenCode")。在 `SessionAdapterFactory.swift` 中注册(default + alt 集),且**启用了 live sync**(与 Windsurf/Antigravity 的 `enableLiveSync:false` 不同)。无家族/父级分组。

### 注意点与边界情况

1. **消息计数大幅低估实际值(text-only 谓词)。** 只有当一条 message 拥有 ≥1 个非空 `text` part 时才计入(Swift `contentfulRole` `:311-328`,注释 `:147-148`)。纯工具的 assistant 回合消失。真实影响:assistant 总数 ≈ 6,788,但有 text 的 assistant ≈ 2,501 → Engram 报告约 37% 的实际 assistant 回合。这是有意的(计数必须等于流式 transcript),但 Engram 的 OpenCode `messageCount` 是"可见文本回合"计数,而非回合计数。

2. **TS ↔ Swift 计数分歧。** Swift 只计有 text 内容的 message(`contentfulRole`);**TS `parseSessionInfo` 按原始 `message.role` 计数**(`ts:142-146`)——因此对于纯工具回合,TS 参考报告的 `messageCount` 高于 Swift 产品。以 Swift 产品路径为权威。

3. **单消息会话获得 `endTime = nil`。** 守卫 `messages.count > 1`(Swift `:185`;TS 在 `messages.length > 0` 时即设置 `endTime`,这是一处轻微的 TS↔Swift 分歧)。此外 `startTime`/`endTime` 派生自 `message` 表,**而非** `session.time_created/updated`——一个唯一活动都是非 message 行的会话,start 回退到 `session.time_created`,end 为 `nil`。

4. **`value` 回退如今是死代码。** Adapter 读取 `part.data.text ?? part.data.value`。**实存:`value` 出现在 0 个 part 中**(已验证)。`value` 路径是遗留的(较旧的 OpenCode part schema),从不触发。

5. **TS 接口 `MessageData.content[]` 是虚构/遗留的。** `opencode.ts:37` 在 message blob 上声明了 `content?: Array<{type, value?, text?}>`,但**实存:0 条 message 拥有 `data.content`**(已验证)——文本始终在 `part` 表中。陈旧类型;无害(流式代码正确读取 part)但具误导性。

6. **测试 fixture schema ≠ 实存 schema(漂移)。** parity fixture 的 `session` 表只有原始 18 列(`schemaVersion: 1`;无 `workspace_id`、`agent`、`model`、`cost`、`tokens_*`、`metadata`)。parity 测试从不运用较新的列——但 adapter 只 `SELECT` 原始 5 列,故行为不受影响。fixture 被钉在一个旧的 OpenCode schema 上。`tests/fixtures/opencode/` 为空(运行时生成)。

7. **按会话体积,而非整文件体积(CLAUDE.md 注记)。** 全部 386 个会话共享同一个 224 MB 文件;`statSync(dbPath)` 会把 224 MB 归到**每个**会话(386× 过计,约 86 GB 幻影总量)。修复方案是对范围限定在 `session_id` 的 `length(message.data) + length(part.data)` 求和(Swift `sessionPayloadSize:269-298`;TS `:156-169`,注释 `:152-155`)。两种实现按构造逐字节相同。由 fixture 验证:`sizeBytes: 276` = message + part 字节之和。

8. **单个 DB 内版本跨度大,但 message JSON 稳定。** 会话跨越 OpenCode **1.2.6 → 1.17.8**(头部:`1.3.13`×70、`1.15.13`×61)。`message.data`/`part.data` JSON 形状(role/time/tokens/parts)在此范围内**稳定**——v1.2.6 的 assistant message 与 v1.17.8 拥有相同的 `tokens.{input,output,reasoning,cache.{read,write}}` 嵌套。迁移只改了 `session`/`project` 列。adapter 在实践中对版本漂移健壮。

9. **以只读方式对活跃 WAL DB。** 可能在 checkpoint 前漏掉未提交写入(不会损坏)。未观察到索引端的 `wal_checkpoint`/重试;下一次扫描时的最终索引是事实上的处理方式。

10. **时间戳是 epoch 毫秒(13 位),ISO 前 ÷1000**(Swift `isoFromMilliseconds`;TS `new Date(ms)`)。`1782005887047` → `2026-06-21T01:38:07.047Z`。两个 adapter 都正确处理 ms。

### Engram 不消费的数据(明确的数据丢失清单)

1. **`session.parent_id`**(221/386 已填充)→ 原生子 agent 谱系不可见(§10)。
2. **会话级 `cost` + `tokens_*` 汇总** → 忽略;用量按 assistant message 重新推导。
3. **`session.model` / `message.data.modelID`**(106/386 + 按 message)→ `model` 永远 `nil`;Engram 不记录任何 OpenCode model。
4. **`session.agent`、`mode`、`slug`、`version`、`workspace_id`、`share_url`、summary/diff 统计、`revert`、`permission`、`metadata`。**
5. **所有非 text part** — tool(12,147)、reasoning(6,090)、patch(1,032)、file(25)、compaction(14)、step-start/finish(13,513)、subtask(1):36k 个 part 中约 33k 被丢弃。
6. **`project`/`project_directory`/`workspace` 表** → `project` 永远 `nil`;cwd 仅来自 `session.directory`。
7. **`tokens.total`**(改用 input/output/reasoning/cache 的拆分)。
8. **`todo`、`session_message`、`event`、`event_sequence`** 表整体。

> **未决问题(OPEN)**(从研究中带出):
> - (a) **Engram 内部设计——无法通过 web 验证:** text-only 范围是否应扩宽以索引 tool/reasoning 内容用于搜索?该格式确实存储 tool/reasoning 内容(已确认),但 Engram 是否索引它属于 Engram 产品选择。
> - (b) **Engram 内部设计——无法通过 web 验证:** `session.parent_id` 是否应接入确定性 Layer-1 谱系?OpenCode 一侧已尘埃落定(`session.parent_id` 原生记录子/子 agent 谱系——见 §10);消费决策是 Engram 的选择。[sql.ts](https://github.com/sst/opencode/blob/dev/packages/core/src/session/sql.ts)
> - (c) **Engram 内部设计——无法通过 web 验证:** 会话级 cost/token 汇总是否应被呈现而非重新推导?OpenCode 维护权威汇总(已确认 §9);呈现它们是 Engram 的选择。[sql.ts](https://github.com/sst/opencode/blob/dev/packages/core/src/session/sql.ts)
> - (d) DB 汇总是否始终等于按 message 之和?(web-checked 2026-06-21: no authoritative source found asserting strict equality——这些列是存储计数器,而非有文档的不变量;见 §9)
> - (e) **已确认(官方):** 按 type 的 `event.data` / `session_message.data` 载荷 schema 可从 [event.ts](https://github.com/sst/opencode/blob/dev/packages/core/src/session/event.ts) 解码——每种 type 的 data 形状就是其 `EventV2.define` schema。例如 `session.next.agent.switched` 的 payload = `{Base, messageID, agent:String}`;`session.next.model.switched` 的 payload = `{Base, messageID, model: ModelV2.Ref}`。源码定义了远比实存中观测到的 6 种 event / 2 种 session_message 更大的事件宇宙(`session.next.step.started/ended/failed`、`tool.input.started/delta/ended`、`tool.called/progress/success/failed`、`text.started/delta/ended`、`reasoning.*`、`compaction.started/delta/ended`、`prompt.admitted/promoted` 等);"观测到 6 种 / 2 种"是实存快照的经验计数,而非完整的源码枚举。

---

## 16. 附录:真实脱敏样本

> 已脱敏:message/代码文本、密钥、路径以及图片 data URL 被替换为 `<str len=N>`;所有 key/结构逐字取自实存。

### `session` 行(实存,29 列)

```
id                : ses_1182c0fb9ffegNnxixt6yu9qyO
project_id        : e8784f46a14602aaf5b98a02b9096ae8fc9ba30d
parent_id         : (NULL)                                      [221/386 non-NULL]
slug              : nimble-nebula
directory         : <cwd path>
title             : <generated title>
version           : 1.17.8
share_url         : (NULL)
summary_additions : 0    summary_deletions : 0    summary_files : 0
summary_diffs     : (NULL)    revert : (NULL)    permission : (NULL)
time_created      : 1782005887047
time_updated      : 1782005893936
time_compacting   : (NULL)
time_archived     : (NULL)                                      [0/386 archived]
workspace_id      : (NULL)    path : (NULL)
agent             : build                                       [106/386 set]
model             : {"id":"deepseek-v4-pro","providerID":"opencode-go","variant":"default"}
cost              : 0.03949974                                  [227/386 > 0]
tokens_input      : 22625    tokens_output : 3    tokens_reasoning : 35
tokens_cache_read : 0        tokens_cache_write : 0
metadata          : (NULL)
```

### `message.data` — user

```json
{
  "role": "user",
  "time": { "created": 1771483653004 },
  "summary": { "diffs": [] },
  "agent": "build",
  "model": { "providerID": "opencode", "modelID": "minimax-m2.5-free" }
}
```

### `message.data` — assistant

```json
{
  "role": "assistant",
  "time": { "created": 1771483653013, "completed": 1771483657730 },
  "parentID": "msg_c74a763870014VGxpaTjyvK3Sy",
  "modelID": "minimax-m2.5-free",
  "providerID": "opencode",
  "mode": "build",
  "agent": "build",
  "path": { "cwd": "/Users/.../Downloads", "root": "/" },
  "cost": 0,
  "tokens": { "total": 11660, "input": 9536, "output": 63, "reasoning": 23,
              "cache": { "read": 2061, "write": 0 } },
  "finish": "tool-calls"
}
```

### `part.data` — text(Engram 唯一解析的 type)

```json
{ "type": "text", "text": "<str len=834>",
  "time": { "start": 1771483678610, "end": 1771483678610 } }
```

### `part.data` — reasoning

```json
{ "type": "reasoning", "text": "<str len=…>",
  "time": { "start": 1771483655000, "end": 1771483657000 } }
```

### `part.data` — tool(completed)

```json
{ "type": "tool", "callID": "call_function_4cgbasugl504_1", "tool": "bash",
  "state": {
    "status": "completed",
    "input":  { "command": "<str>", "description": "<str>" },
    "output": "<str len=37116>",
    "title":  "<str>",
    "metadata": { "output": "<str>", "exit": 0, "description": "<str>", "truncated": false },
    "time": { "start": 1771483657599, "end": 1771483657647 } } }
```

### `part.data` — tool(error)

```json
{ "type": "tool", "callID": "call_cb609c3a04814448b5b5f5bf", "tool": "read",
  "state": { "status": "error", "input": { "filePath": "<str>" },
             "error": "Error: File not found: <str>",
             "time": { "start": 1771483657599, "end": 1771483657647 } } }
```

### `part.data` — step-start / step-finish

```json
{ "type": "step-start" }
```
```json
{ "type": "step-finish", "reason": "tool-calls", "cost": 0,
  "tokens": { "total": 11660, "input": 9536, "output": 63, "reasoning": 23,
              "cache": { "read": 2061, "write": 0 } } }
```

### `part.data` — patch / file / compaction / subtask

```json
{ "type": "patch", "hash": "9fcfa4ef9a95a4b8ccdd1910f1f0e07388c5c026",
  "files": ["/Users/.../inference.js"] }
```
```json
{ "type": "file", "mime": "image/jpeg", "filename": "<str>.jpg",
  "url": "<str len=198235>",
  "source": { "text": {"value":"[Image 1]","start":18,"end":27},
              "type": "file", "path": "<str>.jpg" } }
```
```json
{ "type": "compaction", "auto": true }
```
```json
{ "type": "subtask", "agent": "build",
  "description": "<str>", "command": "review",
  "model": { "providerID": "kimi-for-coding", "modelID": "k2p5" },
  "prompt": "<str len=4657>" }
```

### `session_message` 行(较新的 event 表——Engram 忽略)

```
id           : <str>      session_id : ses_…    seq : 3
type         : model-switched          (or: agent-switched)
time_created : 1782005887047
data         : <json blob>
```

### `todo` 行(Engram 忽略)

```
session_id : ses_…    position : 0    status : completed    priority : high
content    : <str>    time_created/updated : <epoch ms>
```

### Parity fixture 预期输出(`success.expected.json`,schemaVersion 1)

```json
{
  "sessionInfo": {
    "id": "ses_test001", "source": "opencode",
    "startTime": "2026-02-02T02:40:01.000Z", "endTime": "2026-02-02T02:40:10.000Z",
    "cwd": "/Users/test/my-project", "summary": "<title>",
    "messageCount": 2, "userMessageCount": 1, "assistantMessageCount": 1,
    "toolMessageCount": 0, "systemMessageCount": 0,
    "sizeBytes": 276, "filePath": "<fixtureRoot>/opencode/input/sample.db::ses_test001"
  },
  "messages": [
    { "role": "user", "content": "<str>", "timestamp": "2026-02-02T02:40:01.000Z" },
    { "role": "assistant", "content": "<str>", "timestamp": "2026-02-02T02:40:10.000Z",
      "usage": { "inputTokens": 123, "outputTokens": 50,
                 "cacheReadTokens": 67, "cacheCreationTokens": 8 } }
  ]
}
```
(`outputTokens: 50` = output 45 + reasoning 5;`sizeBytes: 276` = message + part 字节之和。)

---

## References (official sources)

Web 确认执行于 2026-06-21(`web_access_ok=true`)。

- [sst/opencode — session SQL table definitions (`packages/core/src/session/sql.ts`)](https://github.com/sst/opencode/blob/dev/packages/core/src/session/sql.ts)
- [sst/opencode — Identifier module / ID encoding (`packages/opencode/src/id/id.ts`)](https://github.com/sst/opencode/blob/dev/packages/opencode/src/id/id.ts)
- [sst/opencode — v1 session schema, part/message discriminated unions (`packages/core/src/v1/session.ts`)](https://github.com/sst/opencode/blob/dev/packages/core/src/v1/session.ts)
- [sst/opencode — session event payload schemas (`packages/core/src/session/event.ts`)](https://github.com/sst/opencode/blob/dev/packages/core/src/session/event.ts)
- [sst/opencode — database open + PRAGMAs + db filename (`packages/core/src/database/database.ts`)](https://github.com/sst/opencode/blob/dev/packages/core/src/database/database.ts)
- [sst/opencode — storage schema re-exports (`packages/opencode/src/storage/schema.ts`)](https://github.com/sst/opencode/blob/dev/packages/opencode/src/storage/schema.ts)
- [sst/opencode — session ID brands (msg/prt prefixes) (`packages/opencode/src/session/schema.ts`)](https://github.com/sst/opencode/blob/dev/packages/opencode/src/session/schema.ts)
- [DeepWiki — OpenCode Storage and Database](https://deepwiki.com/sst/opencode/2.9-storage-and-database)
- [DeepWiki — OpenCode Session Management](https://deepwiki.com/sst/opencode/2.1-session-management)
- [DeepWiki — OpenCode Message and Part Structure](https://deepwiki.com/sst/opencode/2.2-message-and-prompt-system)
