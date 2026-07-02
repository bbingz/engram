# Cline — Session Format Reference

Last researched: 2026-07-02 (Engram provider audit recheck)

> **Sibling docs:** Cline is **NOT** in the VS Code / Cursor / Copilot `state.vscdb` storage family (see [§15](#15-lineage-gotchas-version-drift--edge-cases)). It is its own JSON-array-per-task format. Its true siblings are the downstream forks **Roo Code** and **Kilo Code**, which reuse the identical schema but have no Engram adapter. This doc is self-contained.

---

## 1. Overview & TL;DR

**What:** Cline (an autonomous coding agent) persists each *task* (one conversation/session) as a **directory of plain JSON files**. There is no database, no JSONL, no leveldb, no gRPC cache.

**Where:** The live store on this machine is the **Cline standalone CLI** layout, rooted at `~/.cline/data/tasks/`. Each task is a subdirectory named with the task-creation time in milliseconds-since-epoch (e.g. `1771763997801`).

**How saved:** Every task directory holds 4–5 files. The two large ones (`ui_messages.json` + `api_conversation_history.json`) are **rewritten in full** on every turn (read-modify-write of the whole array — not append). The session ID is simply the directory name, which equals the first record's `ts`.

**Engram mental model:** Engram prefers `ui_messages.json` (the UI render log) and falls back to legacy `claude_messages.json` only when `ui_messages.json` is absent. It ignores the richer Anthropic-format `api_conversation_history.json` and all other sibling files. From the selected UI-message array it keeps only 3 record subtypes as messages (`task`/`user_feedback` → user, non-partial `text` → assistant) out of the ~17 seen live (the full `ClineSay`/`ClineAsk` vocabulary is larger — ~35 + ~18 members; see [§4](#4-record--line-taxonomy)), reads `api_req_started` records solely for token usage, and regex-extracts `cwd` from the request prompt.

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

**Evidence basis:** LIVE on-disk store **and** repo fixtures, cross-checked against both adapters.
- **Live store:** `~/.cline/data/tasks/` — **3 task directories** (`1771763997801`, `1771764735752`, `1771767068013`). Deep-sampled `ui_messages.json` (**283 / 509 / 56 raw records** respectively; up to ~953 KB) plus all sibling files in each. ⚠️ *Do not confuse raw record counts with Engram's derived `messageCount`* (30 / 40 / 10 per task — see [§14](#14-engram-mapping)) or with the **global** `partial:false` count (216 across all three tasks). The earlier "283/216/40" line conflated these three different numbers.
- **Repo fixture:** `tests/fixtures/cline/tasks/1770000000000/ui_messages.json` (4 records, 835 B).
- **Parity golden:** `tests/fixtures/adapter-parity/cline/success.expected.json` + matching `input/tasks/1770000000000/ui_messages.json` (schemaVersion 1, generated at commit `88f86631`).
- **Adapters:** `macos/Shared/EngramCore/Adapters/Sources/ClineAdapter.swift` (product) and `src/adapters/cline.ts` (TS reference/parity).

**Current Engram status:** The 2026-07-02 read-only smoke listed and parsed 3/3 Cline locators, streamed 80 messages (17 user + 63 assistant), attached usage to all 63 assistant messages, and found 0 parser/stream count mismatches. The live Engram DB has exactly 3 `cline` rows plus 3 `file_index_state` rows (`ok`, schema v1) with 0 missing current locators, 0 DB-only rows, 0 stale parser-owned fields, and 0 index-only locators.

**Conflicts/discrepancies:** Current live data and DB locator coverage still match adapter assumptions. 2026-07-01 recheck found and fixed one retained TypeScript-only drift: consecutive `api_req_started` token ledgers were overwritten instead of accumulated before the next assistant message, while Swift already accumulated them; the 2026-07-02 smoke confirms the current TS stream now exposes usage on all 63 assistant messages. **One discrepancy vs. the task hint** (flagged in [§15](#15-lineage-gotchas-version-drift--edge-cases)): the hint guessed a VS Code extension layout (`globalStorage/<ext-id>/tasks/...`). Confirmed (official): both the hint (VS Code `globalStorage/saoudrizwan.claude-dev/tasks/`) and the doc (CLI `~/.cline/data/tasks/`) are the **same code path** — `getGlobalStorageDir("tasks", taskId) = path.resolve(HostProvider.globalStorageFsPath, "tasks", taskId)` — only the host base dir (`HostProvider.globalStorageFsPath`) differs ([disk.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/core/storage/disk.ts), [issue #7929](https://github.com/cline/cline/issues/7929)). The root the live machine uses is `~/.cline/data/tasks/` (Cline CLI, `cline_version 3.66.0`, `host_name "Cline CLI - Node.js"`); no VS Code `globalStorage` Cline directory exists here. **The Engram adapter hardcodes `~/.cline/data/tasks/` as its only scan root** — that hardcoding is an Engram-side limitation, not a Cline property (Cline's path is host-derived and overridable via `CLINE_DIR` / `--data-dir` / `--config`).

---

## 2. On-disk layout & file naming

| Aspect | Value | Source |
|---|---|---|
| Root (default) | `~/.cline/data/tasks/` (Engram-hardcoded). Cline itself derives `<HostProvider.globalStorageFsPath>/tasks/`: VS Code → `globalStorage/saoudrizwan.claude-dev/tasks/`, CLI → `~/.cline/data/tasks/` (overridable `CLINE_DIR`/`--data-dir`/`--config`) | `ClineAdapter.swift:9-11`; `cline.ts:29`; [disk.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/core/storage/disk.ts) |
| Storage tech | Per-task directory of plain JSON files (whole-array JSON; **not** JSONL/SQLite/leveldb/gRPC) | live store; `Phase4AdapterSupport.readJSONArray` |
| Locator / index anchor | `ui_messages.json` inside each task dir, falling back to legacy `claude_messages.json` if the modern file is absent | `ClineAdapter.swift:27-35`; `cline.ts:45-57` |
| Session ID | the task directory name (millisecond epoch string) | `ClineAdapter.swift:49`; `cline.ts:69` |
| Detection | `~/.cline/data/tasks` exists and is a directory | `ClineAdapter.swift:18-20`; `cline.ts:32-39` |

**Naming grammar.** Each task dir is `<taskId>` where `taskId` = task-creation time in **milliseconds since epoch** (e.g. `1771763997801` ≈ 2026-02-22). It is also the first record's `ts` (`messages.first.ts === taskId`, verified live: first record `ts: 1771763997805` vs dir `1771763997801` — within ~4 ms). The focus-chain file embeds the id: `focus_chain_taskid_<taskId>.md`. **No per-session rollover:** one task = one directory for life; resuming reopens the same dir.

**File kinds per task dir:**

| File | Naming | Top type | Optionality |
|---|---|---|---|
| `ui_messages.json` | fixed | JSON **array** of UI events | modern locator; present in all current live tasks |
| `claude_messages.json` | fixed legacy name | JSON **array** of UI events | legacy fallback only; 0 current live tasks |
| `api_conversation_history.json` | fixed | JSON **array** of LLM messages | always present |
| `task_metadata.json` | fixed | JSON **object** (3 arrays) | always present |
| `context_history.json` | fixed | nested JSON **array** | **optional** — written only after context truncation (present on 1 of 3 live tasks) |
| `focus_chain_taskid_<id>.md` | id-embedded | Markdown checklist | present in all 3 live tasks |

**Tree example (anonymized, real shape):**

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

> Only **one** of three live tasks has **5** files — `1771763997801` (the one that carried `context_history.json`). The other **two** (`1771764735752` **and** `1771767068013`) each have **4** files. `context_history.json` is optional (written only once context-window truncation occurs); it is present on exactly **1 of 3** live tasks, consistent with the §2 file-kinds table above.

---

## 3. File lifecycle & generation

- **Storage tech:** plain JSON. `ui_messages.json` is a single JSON **array** (not line-delimited). The whole file is `JSON.parse`d into memory.
- **Whole-file rewrite, not append.** All JSON files are read-modify-write of the complete array/object every turn. Evidence: the adapter reads the entire array via `JSONSerialization`/`JSON.parse` with no newline framing, and the file-identity guard rejects parses if `(mtime, size)` changes mid-read (`Phase4AdapterSupport.readJSONArray` `before`/`after`) — only meaningful for atomic full rewrites. Confirmed (official): `saveClineMessages` = `atomicWriteFile(filePath, JSON.stringify(uiMessages))`, `saveApiConversationHistory` = `atomicWriteFile(filePath, JSON.stringify(apiConversationHistory))`, `saveTaskMetadata` = `fs.writeFile(filePath, JSON.stringify(metadata, null, 2))` — none append; all are full-file rewrites and `getSavedClineMessages` `JSON.parse`s the whole file ([disk.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/core/storage/disk.ts)). (Detail: `api`/`ui` use compact JSON via `atomicWriteFile`; `task_metadata` is pretty-printed with 2-space indent.)
- **DB vs file:** file-based, no DB. Cline keeps a flat summary index at `~/.cline/data/state/taskHistory.json`, but it is also a plain JSON file (and Engram does not read it).
- **Resume = reopen same dir; mtimes diverge per file.** Live proof in task `1771767068013`: `api_conversation_history.json` and `task_metadata.json` last modified **Feb 22 21:50**, but `ui_messages.json` modified **Feb 27 17:08**, and that file's `ts` range is `1771767068017 → 1772182620086` (Feb 22 → Feb 27). The `ask:"resume_task"` record + `conversationHistoryDeletedRange` mark the resume boundary. A single task can be paused and resumed days later in the **same** directory — the directory name (taskId) never changes.
- **No rollover / no per-day split.** One task = one dir = one growing `ui_messages.json`. Context overflow is handled in-place by truncating `api_conversation_history` (recorded via `conversationHistoryDeletedRange` + `context_history.json`), not by creating a new file.
- **`endTime`** = last record's `ts`, emitted **only if** it differs from the first (`ClineAdapter.swift:66`); single-record tasks have `endTime = nil`.
- **No archive/compaction format.** Old tasks remain as plain dirs under `tasks/`.

---

## 4. Record / line taxonomy

`ui_messages.json` is a flat JSON **array of "UI message" records**. Two macro-kinds discriminated by `type`: `"say"` (Cline → user output) and `"ask"` (Cline prompts the user and awaits input). Live distributions:

> Confirmed (official): the tables below are the **observed live subset** (union across 3 tasks), **not** Cline's full taxonomy. The real `ClineSay` enum has **~35 members** and `ClineAsk` **~18** ([ExtensionMessage.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/shared/ExtensionMessage.ts)). The live sample omits real subtypes including `act_mode_respond`, `api_req_finished`, `condense`, `summarize_task`, and the subagent says (`subagent` / `use_subagents` / `subagent_usage`). Engram's 3-subtype ingest is unaffected.

**`say` subtypes** (observed live subset — union across all 3 live tasks; full `ClineSay` enum is larger):

| `say` value | `text` format | Meaning | Engram |
|---|---|---|---|
| `task` | plain | Initial user task prompt. Carries `modelInfo`. | → `role=user`; also session `summary` (first 200 chars) |
| `text` | plain (markdown) | Assistant prose. `partial:false` = final. | → `role=assistant` (only when `!partial`) |
| `api_req_started` | **JSON string** | API request marker: token/cost ledger + full request prompt. | consumed for token usage + cwd only (not a message) |
| `reasoning` | plain | Assistant chain-of-thought shown in UI. | **ignored** |
| `task_progress` | markdown checklist | Live focus-chain snapshot (`- [ ] / - [x]`). | **ignored** |
| `tool` | **JSON string** | File/tool operation record. | **ignored** |
| `command` | plain | Shell command Cline ran. May carry `commandCompleted`. | **ignored** |
| `command_output` | plain | Streamed shell stdout/stderr. | **ignored** |
| `completion_result` | plain (markdown) | Final assistant completion summary. | **ignored** |
| `user_feedback` | plain | User's mid-task message. | → `role=user` |
| `error_retry` | **JSON string** | Retry notice (live shape `{attempt,maxAttempts,delaySeconds,errorMessage}`; canonical struct uses `delaySec`/`errorSnippet` — see [§6.4](#64-other-json-string-text-payloads-skipped)). | **ignored** |
| `api_req_retried` | null | Bare retry marker (no payload). | **ignored** |

**`ask` subtypes** (observed live subset; full `ClineAsk` enum is larger):

| `ask` value | `text` format | Meaning | Engram |
|---|---|---|---|
| `command_output` | plain | Command output surfaced for approval/continuation. | **ignored** |
| `completion_result` | empty string | Asks user to accept the completion (pairs with `say=completion_result`). | **ignored** |
| `resume_task` | null | Resume-an-interrupted-task prompt. | **ignored** (but its `ts` can become `endTime`) |
| `followup` | **JSON string** | `{question, options}` follow-up question. | **ignored** |
| `plan_mode_respond` | **JSON string** | `{response, options}` Plan-mode reply. | **ignored** |

> **Engram ingests only 3 of these subtypes as messages:** `task`/`user_feedback` (→ user) and `text & !partial` (→ assistant). Everything else is skipped at `ClineAdapter.swift:138` / `cline.ts:117-122`. `api_req_started` is consumed only for token usage, not as a message. `messageCount` ≠ raw record count. (The "~17 subtypes" figure was the live-sample count, not Cline's full taxonomy — see the note above the tables.)

> `task_metadata.json` is an object, not a record stream; its arrays are documented in [§13](#13-auxiliary-files). For the DB-table taxonomy this would normally enumerate, Cline is file-based → **see [§12](#12-sqlite--db-internals) (N/A)**.

---

## 5. Shared envelope / metadata fields

Record-level fields of `ui_messages.json` (union of all keys across live records):

> Confirmed (official): these match the `ClineMessage` interface — `{ ts: number; type: "ask"|"say"; ask?: ClineAsk; say?: ClineSay; text?: string; reasoning?: string; images?: string[]; files?: string[]; partial?: boolean; commandCompleted?: boolean; lastCheckpointHash?; isCheckpointCheckedOut?; isOperationOutsideWorkspace?; conversationHistoryIndex?: number; conversationHistoryDeletedRange?: [number, number]; modelInfo?: ClineMessageModelInfo }`. `conversationHistoryDeletedRange` is typed `[number, number]` with the comment "for when conversation history is truncated for API requests" — confirming the truncation semantics in [§5](#5-shared-envelope--metadata-fields)/[§11](#11-summary--compaction) ([ExtensionMessage.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/shared/ExtensionMessage.ts)). The doc omits envelope keys Engram ignores (`reasoning`, `images`, `files`, `lastCheckpointHash`, `isCheckpointCheckedOut`, `isOperationOutsideWorkspace`).

| Field | Type | Meaning | Optional | Example (anonymized) |
|---|---|---|---|---|
| `ts` | number (epoch ms) | event time; **first record's `ts` == taskId == startTime** | required (parse fails if first record lacks it) | `1771763997805` |
| `type` | string enum | `"say"` or `"ask"` | required | `"say"` |
| `say` | string enum | say-subtype (see [§4](#4-record--line-taxonomy)) | present when `type=="say"` | `"api_req_started"` |
| `ask` | string enum | ask-subtype (see [§4](#4-record--line-taxonomy)) | present when `type=="ask"` | `"command_output"` |
| `text` | string | display payload; for `api_req_started`/`tool`/`followup`/`plan_mode_respond`/`error_retry` it is a **JSON-encoded string** (parse twice) | optional (empty `""` or null on some `ask`) | `"<REDACTED>"` |
| `partial` | bool \| null | `true` = streaming chunk not yet final; assistant `text` taken **only when `partial != true`** | optional. **Present (mostly `false`) on streaming-capable says** — live: `reasoning`, `text`, `tool` (+ 2 non-say records). The value `true` only ever occurs on `say="text"` | `false` |
| `modelInfo` | object `{providerId, modelId, mode}` | model used for this turn; session `model` = first record with a `modelId`. **A single task can mix models** (see gotcha #8) | optional (mostly on `task`/`api_req_started`) | `{"providerId":"cline","modelId":"z-ai/glm-5","mode":"act"}` |
| `conversationHistoryIndex` | number | index into `api_conversation_history.json` (`-1` = pre-history seed) | optional | `-1`, `0`, `8`, … |
| `conversationHistoryDeletedRange` | `[number,number]` \| null | inclusive `[start,end]` slice of API history truncated for the context window | optional (6/283 records) | `[2, 59]` |
| `commandCompleted` | bool \| null | terminal command finished | optional (only on `say=="command"`) | `true` |

**`partial` value distribution across the 3 tasks:** 216×`false`, 19×`true`, 613×`null`-or-absent (jq `.partial` yields `null` for both null-valued and missing keys). All 19 `true` are on `say="text"`.

**`partial` *presence* (key actually emitted) is broader than the `true` value.** 235 records carry the key across the 3 tasks (more than the 216 `false`, because `null`-valued `partial` keys also count as present). By `say`:

| `say` carrying `partial` | total present | `true` | `false` |
|---|---|---|---|
| `reasoning` | 86 | 0 | 86 |
| `text` | 82 | 19 | 63 |
| `tool` | 65 | 0 | 65 |
| (non-say / `ask` records) | 2 | 0 | 2 |

So `partial:false` appears on every live `say="reasoning"` record (86/86 in task `1771764735752`), not only on `say="text"`. The earlier "only ever true on `say=text`" note was correct about the **`true` value** but understated the field's **presence**.

---

## 6. Message & content schema

### 6.1 Plain-text record bodies (what becomes a message)

For `say ∈ {task, text, user_feedback, completion_result, reasoning, command, ...}`, `text` is a plain string (markdown for prose). Engram maps only `task`/`user_feedback` → user content and non-partial `text` → assistant content (`ClineAdapter.swift:142-149`).

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

`.text` is a JSON string the adapter re-parses for token usage AND cwd. Inner keys (verified live, in order): `cacheReads, cacheWrites, cost, request, tokensIn, tokensOut`.

> Confirmed (official): `task/index.ts` writes this via `text: JSON.stringify({ request: … } satisfies ClineApiReqInfo)`, so `.text` is genuinely a nested JSON string (parse twice). The `ClineApiReqInfo` schema is `{ request?, tokensIn?, tokensOut?, cacheWrites?, cacheReads?, cost?, cancelReason?, streamingFailedMessage?, retryStatus? }` — the six inner keys the table enumerates are exactly the populated subset ([task/index.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/core/task/index.ts), [ExtensionMessage.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/shared/ExtensionMessage.ts)).

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

| Inner field (in parsed `.text`) | Type | Meaning | Engram use |
|---|---|---|---|
| `request` | string | full prompt incl. `Current Working Directory (<path>) Files …` block | `extractCwd` regex source (`ClineAdapter.swift:171-194`) |
| `tokensIn` | number | input tokens for this request | summed → `usage.inputTokens` (attached to **next** assistant msg) |
| `tokensOut` | number | output tokens | summed → `usage.outputTokens` |
| `cacheReads` | number | cache-read tokens | **ignored** (Swift forces 0) |
| `cacheWrites` | number | cache-creation tokens | **ignored** (Swift forces 0) |
| `cost` | number | computed USD cost (often `0` for free/local tiers) | **ignored** |

### 6.3 Nested payload — `say == "tool"` (skipped by Engram)

`.text` is a JSON string discriminated by `.tool`. Live discriminators: `newFileCreated`, `editedExistingFile`, `readFile`, `listFilesTopLevel`, `webFetch`.

> Confirmed (official): the live discriminators are an accurate subset of the `ClineSayTool` union, whose full discriminator set is `editedExistingFile, newFileCreated, fileDeleted, readFile, listFilesTopLevel, listFilesRecursive, listCodeDefinitionNames, searchFiles, webFetch, webSearch, summarizeTask, useSkill`, with fields `path?, diff?, content?, regex?, filePattern?, operationIsLocatedInWorkspace?, startLineNumbers?, readLineStart?, readLineEnd?` ([ExtensionMessage.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/shared/ExtensionMessage.ts)). The 3-task live sample only surfaced 5 discriminators / 5 keys.

| `tool` value | Keys | Notes |
|---|---|---|
| `newFileCreated` | `tool, path, content, startLineNumbers, operationIsLocatedInWorkspace` | `content` = full new file body |
| `editedExistingFile` | `tool, path, content, startLineNumbers, operationIsLocatedInWorkspace` | observed `diff:null`; `content` carries the result |
| `readFile` | `tool, path, content, operationIsLocatedInWorkspace` | `content` = absolute path read |
| `listFilesTopLevel` | `tool, path, content, operationIsLocatedInWorkspace` | `content` = dir listing |
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

> Confirmed (official): the canonical retry struct `ClineApiReqInfo.retryStatus` is `{ attempt, maxAttempts, delaySec, errorSnippet }` — fields are `delaySec` and `errorSnippet`, **not** `delaySeconds`/`errorMessage` ([ExtensionMessage.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/shared/ExtensionMessage.ts)). The `say="error_retry"` record may serialize slightly differently; verify against a live `error_retry` record if the exact field names matter. Engram skips this payload either way.

### 6.5 cwd extraction algorithm

`ClineAdapter.swift:176-198` / `cline.ts:173-193`: scan every `api_req_started`, `JSON.parse` `.text`, then match `request` with regex `Current Working Directory \((.+?)\) Files` (lazy, anchored on `) Files` so paths containing `)` survive), falling back to `Current Working Directory \(([^)]+)\)`. Returns `""` if none found. Both adapters use dot-matches-newline (Swift `.dotMatchesLineSeparators`, TS `/s`).

> Confirmed (official) + multi-root failure mode: `getEnvironmentDetails` emits the literal scaffold `\n\n# Current Working Directory (${this.cwd.toPosix()}) Files\n` for single-root workspaces ([task/index.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/core/task/index.ts)), which the regex matches. **For MULTI-ROOT workspaces the source emits `# Current Working Directory (Primary: ${primaryName}) Files` instead** — so the capture group yields the string `Primary: <name>` rather than an absolute path, and Engram's `cwd` becomes a non-path string, breaking project attribution. See gotcha #4.

---

## 7. Tool calls & results

**In `ui_messages.json` (what Engram sees): no explicit ID linkage.** Linkage is positional + textual: a `say="command"` envelope is followed by `ask/say="command_output"`; a `say="tool"` (e.g. `newFileCreated`) stands alone with the operation result embedded in its own `content`. The `commandCompleted:true` flag marks a finished command. **Engram drops all of these** — `toolMessageCount` is hardcoded `0`.

**In `api_conversation_history.json` (NOT parsed by Engram): real ID-based linkage.** `tool_use` blocks carry `id`/`call_id`; the result returns in the subsequent `user` message as a `text` block prefixed `[<name> for '<args>'] Result:\n…` (there is **no** `tool_result` block type — verified across all 3 live tasks; only `text`/`thinking`/`tool_use` blocks exist). See [§6](#6-message--content-schema) above and [§13](#13-auxiliary-files) for the full `api_conversation_history.json` schema.

`tool_use.name` distribution + `input` schema (live task `1771764735752`):

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

**Stored, but NOT consumed by Engram.** Two places hold reasoning:

1. `ui_messages.json` `say:"reasoning"` records (plain-text chain-of-thought shown in the UI; 86 in live task `1771764735752`). Not in Engram's `say` allow-list → dropped.
2. `api_conversation_history.json` `thinking` content blocks — the richer source. Block keys: `type, thinking, signature, summary`.

| Field | Type | Meaning |
|---|---|---|
| `thinking` | string | reasoning text (truncated head) |
| `signature` | string | provider signature (observed empty `""`) |
| `summary` | object[] | full reasoning, chunked: `{type:"reasoning.text", text, index, format}` (`format` observed `null`) |

```json
{ "type": "thinking", "thinking": "<reasoning — anonymized>", "signature": "",
  "summary": [ { "type": "reasoning.text", "text": "<…>", "index": 0, "format": null } ] }
```

Engram emits **no reasoning** for Cline sessions.

---

## 9. Token usage & cost

Token usage lives in `say:"api_req_started"` records (per-request) and, redundantly, in `api_conversation_history.json` assistant `metrics` and `taskHistory.json` aggregates. Engram reads **only** the `api_req_started` path.

| Source field | Type | Engram field | Derivation |
|---|---|---|---|
| `api_req_started.text.tokensIn` | number | `usage.inputTokens` | summed across consecutive `api_req_started`, flushed onto next assistant message |
| `api_req_started.text.tokensOut` | number | `usage.outputTokens` | same |
| `api_req_started.text.cacheReads` | number | `usage.cacheReadTokens` = **0** | **dropped** (Swift `:166`, TS `:182`) |
| `api_req_started.text.cacheWrites` | number | `usage.cacheCreationTokens` = **0** | **dropped** (Swift `:167`, TS `:183`) |
| `api_req_started.text.cost` | number | — | **dropped** entirely |

**Aggregation mechanism (subtle):** `api_req_started` is NOT itself a message. The adapter accumulates `pendingUsage` across consecutive `api_req_started` records, then attaches the accumulated total to the first following `assistant` message and resets (`ClineAdapter.swift:114-131`; `cline.ts:119-147`). A record with both `tokensIn==0` and `tokensOut==0` is ignored (`ClineAdapter.swift:166`, `cline.ts:209`). Verified by parity golden: the single assistant message gets `{inputTokens:100, outputTokens:0, cacheReadTokens:0, cacheCreationTokens:0}`. 2026-07-01 retained TS regression coverage also verifies two consecutive ledgers aggregate as `10+7` input and `5+3` output.

**Impact:** cache and cost are structurally under-reported. Live task `1771763997801` `taskHistory` aggregate `cacheReads` reached ~1.68M tokens — all dropped by Engram. (Cost was `0` across all sampled tasks due to free/local model tier, so cost loss had no $ impact *here* but would on paid tiers.)

---

## 10. Subagent / parent-child / dispatch

**N/A for Cline (at the session level).** Cline has no cross-**session** parent/agent-linking signal in its on-disk format. The adapter sets every lineage field to `nil`: `agentRole`, `originator`, `origin`, `parentSessionId`, `suggestedParentId`, `summaryMessageCount` (`ClineAdapter.swift:79-86`; not present in TS). There is no `.engram.json` sidecar (that is the Gemini mechanism), no path-based subagent detection, no originator marker. Cline sessions always surface as independent top-level sessions and are never auto-classified as dispatched.

> Confirmed (official): there is **no `parentTaskId`** persisted in any per-task file or in `HistoryItem` (repo search returned no matches; `HistoryItem` has no parent field — [HistoryItem.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/shared/HistoryItem.ts)), so the no-on-disk-session-link conclusion stands. **However, current Cline DOES have a subagent feature** — `ClineSay` includes `subagent` / `use_subagents` / `subagent_usage` and `ClineAsk` includes `use_subagents` ([ExtensionMessage.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/shared/ExtensionMessage.ts)). Those subagents run **inside the single parent task's `ui_messages.json`**, not as separate child task dirs with a back-pointer, so they produce no cross-session parent/child graph for Engram to link. Accurate statement: "subagents exist but live within one task file," not "Cline has no subagents."

---

## 11. Summary / compaction

- **Engram "summary":** the first `say:"task"` record's `text`, truncated to 200 chars (`ClineAdapter.swift:53-55,75`; `cline.ts:67-68,92`). It doubles as the title surrogate (no separate title field). Not a model-generated summary.
- **Cline-side compaction:** context-window overflow is handled in-place. When the API history is truncated, Cline writes `conversationHistoryDeletedRange` on the relevant `ui_messages.json` records and appends a note to `context_history.json` (e.g. *"Some previous conversation history … has been removed"*). **Engram ignores both** — it does not detect or split on compaction, and does not use a separate compacted-summary record. There is no Claude-Code-style `summary` record type in Cline.

---

## 12. SQLite / DB internals

**N/A for Cline.** Cline is file-based (per-task directory of plain JSON arrays/objects). There is no SQLite `.vscdb`, no leveldb, no DB tables/columns/keys. This is the key distinction from the `cursor`/`vscode` adapters, which DO read `state.vscdb` (see [§15](#15-lineage-gotchas-version-drift--edge-cases)).

---

## 13. Auxiliary files

All sibling files below are **NOT parsed by Engram** but are documented for completeness.

### `api_conversation_history.json` — Anthropic-format message log

Flat array of API messages. Envelope keys (union): `role, content, metrics, modelInfo`. Roles: `user`, `assistant`. `content` is **always an array of typed blocks**.

| Envelope field | Type | Meaning | Example |
|---|---|---|---|
| `role` | `"user"` \| `"assistant"` | speaker | `"assistant"` |
| `content` | block[] | typed content blocks (below) | — |
| `metrics` | object (assistant msgs) | `{tokens:{prompt,completion,cached}, cost}` | `{"tokens":{"prompt":4546,"completion":216,"cached":192},"cost":0}` |
| `modelInfo` | object | `{modelId, providerId, mode}` | `{"modelId":"z-ai/glm-5","providerId":"cline","mode":"act"}` |

**Content block types** (live counts vary by task; one task had only `text`, another had `text`/`thinking`/`tool_use`). No `tool_result` block exists — results fold into the next `user` message's `text`.

**Block-key optionality (live task `1771764735752`).** Only `type` (and the type's payload key) is universal; the auxiliary keys are emitted on a **subset** of blocks:

| Block | Key | Present | Optionality |
|---|---|---|---|
| `text` | `type` | 239/239 | required |
| `text` | `text` | 239/239 | required |
| `text` | `call_id` | 28/239 | **optional** (`""` when present) |
| `text` | `reasoning_details` | 28/239 | **optional** (array or `null`) |
| `tool_use` | `type` / `id` / `call_id` / `name` / `input` | 86/86 each | required (`call_id` duplicates `id`) |
| `tool_use` | `reasoning_details` | 58/86 | **optional** (array or `null`) |
| `thinking` | `type, thinking, signature, summary` | — | see [§8](#8-reasoning--thinking) |

So the flat key lists below are the **union** of keys, not a per-block guarantee:
- `text` block keys: `type, text` (always) + `call_id, reasoning_details` (**optional** — present on only 28/239 live text blocks; `call_id` is `""` when present, `reasoning_details` array or `null`).
- `thinking` block keys: `type, thinking, signature, summary` (see [§8](#8-reasoning--thinking)).
- `tool_use` block keys: `type, id, call_id, name, input` (always) + `reasoning_details` (**optional** — present on 58/86 live tool_use blocks; `call_id` duplicates `id`; see [§7](#7-tool-calls--results)).

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

| Key | Element shape | Meaning |
|---|---|---|
| `files_in_context` | `{path, record_state ("active"\|"stale"), record_source ("cline_edited"\|"read_tool"\|"user_edited"), cline_read_date, cline_edit_date, user_edit_date}` (dates are ms\|null) | files Cline touched, with staleness tracking |
| `model_usage` | `{ts, model_id, model_provider_id, mode}` | model-switch timeline |
| `environment_history` | `{ts, os_name, os_version, os_arch, host_name, host_version, cline_version}` | runtime fingerprint — **the only place the Cline version string lives** (live: `host_name:"Cline CLI - Node.js"`, `host_version:"2.4.2"`, `cline_version:"3.66.0"`) |

> Confirmed (official): `getTaskMetadata` default = `{ files_in_context: [], model_usage: [], environment_history: [] }`, and `collectEnvironmentMetadata` returns `{ os_name: os.platform(), os_version: os.release(), os_arch: os.arch(), host_name: hostVersion.platform, host_version: hostVersion.version, cline_version: ExtensionRegistryInfo.version }` — exactly the `environment_history` element shape, with `cline_version` sourced from the extension registry version ([disk.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/core/storage/disk.ts)).

### `context_history.json` — nested context-truncation log (optional)

Deeply nested positional tuples (no field names): outer `[updateType, [...]]`, inner leaves `[ts, "text", [strings], []]`. Written only when truncation happens.

### `focus_chain_taskid_<id>.md` — editable Markdown checklist

Header comments + `- [ ]` / `- [x]` items, titled `# Focus Chain List for Task <id>`; mirrors `say="task_progress"` snapshots. Confirmed (official): `getFocusChainFilePath` returns `path.join(taskDir, "focus_chain_taskid_${taskId}.md")`, created with header `# Focus Chain List for Task <id>` and `- [ ] / - [x]` items ([focus-chain/file-utils.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/core/task/focus-chain/file-utils.ts)).

### `~/.cline/data/state/taskHistory.json` — Cline's own task index (sibling, top-level)

Array of per-task summary records (the CLI's recents list). **Engram does NOT read this** — it walks `tasks/*/ui_messages.json` directly. Note `ulid` and `isFavorited` exist here but NOT in the per-task files.

> Confirmed (official): `getTaskHistoryStateFilePath = path.join(ensureStateDirectoryExists(), "taskHistory.json")`, where `ensureStateDirectoryExists = getGlobalStorageDir("state")` → for the CLI that resolves to `~/.cline/data/state/taskHistory.json`. The `HistoryItem` type is `{ id, ulid?, ts, task, tokensIn, tokensOut, cacheWrites?, cacheReads?, totalCost, size?, shadowGitConfigWorkTree?, cwdOnTaskInitialization?, conversationHistoryDeletedRange?, isFavorited?, checkpointManagerErrorMessage?, modelId? }` — every field below is present (Engram-ignored extras `shadowGitConfigWorkTree` and `checkpointManagerErrorMessage` also exist) ([disk.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/core/storage/disk.ts), [HistoryItem.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/shared/HistoryItem.ts)).

| Field | Type | Meaning | Example |
|---|---|---|---|
| `id` | string | task id (= dir name) | `"1771763997801"` |
| `ulid` | string | ULID secondary id | `"01J…"` |
| `ts` | number | last-activity ms | `1771766262024` |
| `task` | string | first user prompt | `"<task text>"` |
| `tokensIn` / `tokensOut` | number | aggregate tokens | `1789807` / `55124` |
| `cacheWrites` / `cacheReads` | number | aggregate cache tokens | `0` / `1680512` |
| `totalCost` | number | aggregate USD | `0` |
| `size` | number | task bytes on disk | `1788250` |
| `cwdOnTaskInitialization` | string | workspace root | `/Users/<user>/<project>` |
| `conversationHistoryDeletedRange` | `[n,n]` | truncation range | `[2,59]` |
| `isFavorited` | bool | pinned | `false` |
| `modelId` | string | model | `"z-ai/glm-5"` |

> So Cline's authoritative cwd/token aggregates here are independently re-derived by Engram from `ui_messages.json` (cwd via the `api_req_started.request` regex; tokens by summing `tokensIn/Out`).

Other top-level Cline state (not per-task, not parsed): `~/.cline/data/globalState.json`, `~/.cline/data/secrets.json` (0600), `~/.cline/data/settings/{cline_mcp_settings.json,providers.json}`, `~/.cline/data/workspaces/<hash>/workspaceState.json`, `~/.cline/data/logs/cline-cli.*.log`, `~/.cline/kanban/config.json`.

---

## 14. Engram mapping

`parseSessionInfo` returns `NormalizedSessionInfo` (Swift) / `SessionInfo` (TS). `streamMessages` emits `NormalizedMessage`. Swift and TS are line-for-line equivalent.

| Source field / record | Engram `Session` field | Swift `file:line` | TS `file:line` | Notes / example |
|---|---|---|---|---|
| task **directory name** (`epochMillis`) | `id` | `ClineAdapter.swift:49,68` | `cline.ts:69,86` | `"1771763997801"` |
| constant `cline` | `source` | `ClineAdapter.swift:4,69` | `cline.ts:25,87` | `"cline"` |
| first `say:"task"` `text`, first 200 chars | `summary` (title surrogate) | `ClineAdapter.swift:58-60,80` | `cline.ts:75-76,100` | no separate title field |
| regex on first `api_req_started.request`: `Current Working Directory \((.+?)\) Files` then `\(([^)]+)\)` | `cwd` | `ClineAdapter.swift:72,176-199` | `cline.ts:77,173-194` | `/Users/<user>/<project>`; `""` if no match |
| (none) | `project` | `ClineAdapter.swift:73` (`nil`) | `cline.ts` (omitted) | parity golden confirms `"project": null`; derived downstream from `cwd` by the indexer |
| **first** record `ts` (ms → ISO) | `startTime` | `ClineAdapter.swift:43-44,70` | `cline.ts:73,88` | `2026-02-02T02:40:00.000Z` |
| **last** record `ts`; `nil` if == first | `endTime` | `ClineAdapter.swift:50,71` | `cline.ts:74,89-92` | last `ts` is over ALL records incl. ask/tool/partial |
| `userMessageCount + assistantMessageCount` | `messageCount` | `ClineAdapter.swift:75` | `cline.ts:95` | NOT the raw record count |
| `say == "task"` OR `"user_feedback"` count | `userMessageCount` | `ClineAdapter.swift:51-54,76` | `cline.ts:80-82,96` | — |
| `say == "text"` AND `partial != true` count | `assistantMessageCount` | `ClineAdapter.swift:55-57,77` | `cline.ts:83,97` | partial chunks excluded |
| hardcoded `0` | `toolMessageCount` | `ClineAdapter.swift:78` | `cline.ts:98` | `say:"tool"` records NOT counted |
| hardcoded `0` | `systemMessageCount` | `ClineAdapter.swift:79` | `cline.ts:99` | — |
| first record with `modelInfo.modelId` | `model` | `ClineAdapter.swift:61-64,74` | `cline.ts:78,94` | `"z-ai/glm-5"` (provider prefix kept verbatim) |
| selected locator path (`ui_messages.json` or legacy `claude_messages.json`) | `filePath` / locator | `ClineAdapter.swift:81` | `cline.ts:101` | live corpus uses `ui_messages.json` |
| `stat().size` of selected locator only | `sizeBytes` | `ClineAdapter.swift:82` | `cline.ts:68,102` | excludes sibling files (under-counts footprint) |
| `task`/`user_feedback` → `user`; non-partial `text` → `assistant` | message `role` | `ClineAdapter.swift:141-149` | `cline.ts:138-155` | only 2 roles emitted |
| record `text` (plain) | message `content` | `ClineAdapter.swift:149` | `cline.ts:155` | tool/command/progress text never becomes a message |
| running sum of `api_req_started.tokensIn/tokensOut`, flushed onto next assistant message | message `usage` | `ClineAdapter.swift:114-174` | `cline.ts:116-147,196-214` | `cacheReadTokens`/`cacheCreationTokens` hardcoded `0` |
| (none) | `agentRole`/`originator`/`origin`/`parentSessionId`/`suggestedParentId`/`tier`/`qualityScore`/`summaryMessageCount` | `ClineAdapter.swift:84-91` (`nil`) | (not in TS) | Cline has no parent/agent-linking signal |

**Registration:** `SessionAdapterFactory.swift` registers `ClineAdapter()` with `SourceName.cline`. Enumeration uses `JSONLAdapterSupport.directChildren` (non-recursive, hidden files skipped, symlinks excluded, sorted by path — helper at `CodexAdapter.swift:15`).

---

## 15. Lineage, gotchas, version drift & edge cases

### Shared format lineage

- **NOT in the VS Code / Cursor / Copilot family.** The `cursor`/`vscode` adapters read `globalStorage`/`workspaceStorage`/`state.vscdb` (leveldb-backed SQLite). Cline reads its own `~/.cline/data/tasks/` JSON-array format. Even though Cline ships as a VS Code extension, Engram consumes its **core/CLI data dir**, not the IDE's `state.vscdb`. The brief's grouping "Cursor ↔ VS Code ↔ Copilot ↔ Cline" is **false for storage**.
- **True siblings are forks: Roo Code and Kilo Code.** Both are downstream forks of Cline reusing the **identical** `tasks/<id>/{ui_messages.json, api_conversation_history.json, task_metadata.json}` schema and the `api_req_started`/`say`/`ask` vocabulary. Confirmed (official): Roo-Code's `globalFileNames.ts` defines the same trio and `taskMessages.ts` writes `ui_messages.json` with the same whole-array strategy; Kilo Code is a Roo/Cline-lineage fork importing the same task store ([globalFileNames.ts](https://github.com/RooCodeInc/Roo-Code/blob/main/src/shared/globalFileNames.ts), [taskMessages.ts](https://github.com/RooCodeInc/Roo-Code/blob/main/src/core/task-persistence/taskMessages.ts), [kilocode](https://github.com/Kilo-Org/kilocode)). **Nuance:** Roo additionally writes per-task `history_item.json` + `_index.json` (Cline lacks both); the three files Engram parses are identical. Engram has **no Roo/Kilo adapter** (`grep` for `ui_messages|api_req_started` matches ONLY `cline.ts`/`ClineAdapter.swift`). The Cline adapter would parse a Roo/Kilo `ui_messages.json` correctly if pointed at it, but they write to their own roots that the hardcoded `~/.cline/data/tasks` does not cover → **coverage gap / future opportunity.**
- The "Gemini CLI ↔ Qwen ↔ iFlow" cluster is a *different* family and shares nothing with Cline.
- **`modelInfo` lineage:** `providerId:"cline"` + `modelId:"z-ai/glm-5"` shows Cline routes through its own provider gateway and namespaces model ids as `<vendor>/<model>`. Engram stores the prefixed id verbatim — no cross-tool model normalization.

### Gotchas & version drift

1. **Engram hardcodes `~/.cline/data/tasks` as its only scan root** — but Cline's path is NOT hardcoded. Confirmed (official): Cline builds every task path as `path.resolve(HostProvider.globalStorageFsPath, "tasks", taskId)` ([disk.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/core/storage/disk.ts)), so the base varies by host — VS Code extension → `globalStorage/saoudrizwan.claude-dev` ([issue #7929](https://github.com/cline/cline/issues/7929)), CLI → `~/.cline/data` (overridable via `CLINE_DIR` env or `--data-dir`/`--config` flags, per [Cline CLI configuration docs](https://docs.cline.bot/cline-cli/configuration)). The per-task file schema is identical across hosts; only the parent root differs. Because Engram only ever scans `~/.cline/data/tasks`, any Cline data under a VS Code `globalStorage` root or a `CLINE_DIR` override produces `detect()`/index misses — that coverage gap is an Engram limitation, not a Cline one. (This is the discrepancy vs. the task hint.)
2. **JSON array, not JSONL.** Despite using `JSONLAdapterSupport`/`readJSONArray`, a multi-MB `ui_messages.json` (953 KB live) is loaded whole into memory; truncation risk on very large tasks via `ParserLimits`.
3. **`messageCount` ≠ record count.** 283 raw records → ~30 counted messages in live task 1. Anyone reconciling Engram's count against file length will be confused.
4. **cwd extraction is regex-fragile and prompt-version-dependent.** It only works if at least one `api_req_started.request` contains the literal `Current Working Directory (…) Files` scaffold. If Cline changes that system-prompt wording, `cwd` becomes `""` and project attribution breaks. The two-tier regex exists because paths can contain `)` (see test R5-32 in `cline.test.ts:59-88`). **Multi-root failure mode (confirmed official):** for multi-root workspaces the source emits `Current Working Directory (Primary: <primaryName>) Files` ([task/index.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/core/task/index.ts)), so the capture group yields `Primary: <name>` (not a filesystem path) — `cwd` becomes a non-path string and project attribution silently mis-attributes.
5. **`endTime` uses the absolute last record's `ts`** — frequently an `ask`/`resume_task`/`command_output`, not a model message. "Session duration" therefore includes idle/resume time; a task resumed days later shows a long span (live task 3: Feb 22 → Feb 27).
6. **`resume_task` records mean one task dir can span multiple sittings.** Engram treats it as a single session (no split); `conversationHistoryDeletedRange` on the resume record signals prior context was compacted — ignored.
7. **Cache & cost are zeroed (most impactful drift).** Engram's token totals for Cline = `tokensIn`+`tokensOut` only. Real cache-read volume (~1.68M tokens on one live task) and `cost` are discarded → cost dashboards understate Cline.
8. **Model id keeps provider prefix** (`z-ai/glm-5` live vs `glm-5` in the fixture). Reporting/grouping by model must expect both prefixed and bare forms across Cline versions/providers. **The live sample actually spans two providers/models** — `z-ai/glm-5` (234 records) **and** `minimax/minimax-m2.5` (402 records) — and a single task can mix them. Because session `model` = the **first** record carrying a `modelId`, the per-task resolution is: task `1771763997801` → `z-ai/glm-5`, task `1771764735752` → **`minimax/minimax-m2.5`**, task `1771767068013` → `z-ai/glm-5`. (The doc otherwise uses `z-ai/glm-5` as the running example, but task 2's Engram `model` is minimax.)
9. **No cross-session parent/agent linkage** — all lineage fields `nil`; Cline sessions always surface as independent top-level sessions. Confirmed (official): no `parentTaskId` in any per-task file or `HistoryItem` ([HistoryItem.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/shared/HistoryItem.ts)). Caveat: Cline DOES have an in-task subagent feature (`ClineSay` `subagent`/`use_subagents`/`subagent_usage`, [ExtensionMessage.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/shared/ExtensionMessage.ts)) whose events live inside one task's `ui_messages.json` — it creates no separate child-session dir, so there is still nothing for Engram to link (see [§10](#10-subagent--parent-child--dispatch)).
10. **`sizeBytes` measures only `ui_messages.json`** — ignores the (often larger combined) sibling files, under-reporting task footprint.
11. **Parity drift guard exists.** `tests/fixtures/adapter-parity/cline/success.expected.json` (commit `88f86631`, schemaVersion 1) enforces Swift↔TS equivalence; live data confirms the codified counts/usage logic match real files.

### Open / unverified items (web-confirmed 2026-06-21)

- **Roo Code / Kilo Code** (identical schema, no adapter, different roots). Confirmed (official): Roo-Code's `src/shared/globalFileNames.ts` defines the identical core trio — `apiConversationHistory: "api_conversation_history.json"`, `uiMessages: "ui_messages.json"`, `taskMetadata: "task_metadata.json"` — and `task-persistence/taskMessages.ts` writes `ui_messages.json` with the same whole-array `safeWriteJson` strategy ([globalFileNames.ts](https://github.com/RooCodeInc/Roo-Code/blob/main/src/shared/globalFileNames.ts), [taskMessages.ts](https://github.com/RooCodeInc/Roo-Code/blob/main/src/core/task-persistence/taskMessages.ts)). Kilo Code ships a `legacy-migration/task-store.ts` + `roo-import.test.ts` confirming it is a downstream Roo/Cline-lineage fork that imports the same task store ([kilocode](https://github.com/Kilo-Org/kilocode)). **Nuance:** "identical" holds for the three files Engram documents, but Roo additionally writes `history_item.json` + `_index.json` inside each task dir (Cline lacks both). Roots differ, so the "identical schema, different root, coverage gap" framing stands. Adding adapters may be in scope or intentionally excluded; not decided.
- **VS Code `globalStorage/<ext-id>/tasks/` legacy layout.** Confirmed (official): the exact extension id is **`saoudrizwan.claude-dev`**, so the VS Code path is `~/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/tasks/` (macOS) / `%APPDATA%\Code\User\globalStorage\saoudrizwan.claude-dev\tasks\` (Windows) ([disk.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/core/storage/disk.ts), [issue #7929](https://github.com/cline/cline/issues/7929)). The per-task files come from the **same** `GlobalFileNames` constants regardless of host, so the per-task schema is identical — only `HostProvider.globalStorageFsPath` differs between the VS Code extension and the CLI (`~/.cline/data`). The earlier "inferred from the hint" hedge is upgraded to verified.
- `context_history.json`'s nested-array schema is only partially decoded; full semantics of the leading integer indices were not reverse-engineered (Engram does not parse it). The filename is confirmed (`GlobalFileNames.contextHistory = "context_history.json"`, written by `context-management/ContextManager.ts` — [disk.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/core/storage/disk.ts), [ContextManager.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/core/context/context-management/ContextManager.ts)), but the meaning of the leading positional integers (web-checked 2026-06-21: no authoritative source found — would require tracing `ContextManager.ts` serialization, beyond the doc's needs).
- `cacheReads`/`cacheWrites`/`cost`/`cline_version` capture is deliberately dropped; whether to populate them is an open product decision (Engram-internal design — not web-verifiable). The format side is confirmed available to populate: `ClineApiReqInfo.cacheReads/cacheWrites/cost`, `HistoryItem.cacheReads/cacheWrites/totalCost`, and `task_metadata` `environment_history.cline_version` (via `collectEnvironmentMetadata` → `ExtensionRegistryInfo.version`) all exist and are populated in source ([ExtensionMessage.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/shared/ExtensionMessage.ts), [disk.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/core/storage/disk.ts)).
- **Legacy `claude_messages.json` filename (version drift now covered).** Confirmed (official): `getSavedClineMessages` first reads `ui_messages.json`; if absent it falls back to a legacy `claude_messages.json`, migrates it, then deletes the old file ([disk.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/core/storage/disk.ts)). Very old Cline tasks predate the `ui_messages.json` rename. Engram now mirrors that fallback for locator discovery: `ui_messages.json` is preferred, `claude_messages.json` is used only when the modern file is absent. The current live store has 0 legacy files; TS and Swift focused tests cover the fallback.

---

## 16. Appendix: real anonymized samples

**`ui_messages.json` — `say:"task"` (first record):**
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

**`ui_messages.json` — `say:"text"` (assistant, final):**
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

**`ui_messages.json` — `say:"tool"` (skipped by Engram):**
```json
{ "ts": 1771764225161, "type": "say", "say": "tool",
  "text": "{\"tool\":\"newFileCreated\",\"path\":\"<file>\",\"content\":\"<body — anonymized>\",\"startLineNumbers\":[ ... ],\"operationIsLocatedInWorkspace\":true}" }
```

**`ui_messages.json` — `ask:"resume_task"` (skipped; can set endTime):**
```json
{ "ts": 1772182620086, "type": "ask", "ask": "resume_task",
  "conversationHistoryDeletedRange": [2, 59] }
```

**`api_conversation_history.json` — assistant message (NOT parsed):**
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

**`task_metadata.json` (NOT parsed):**
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

**`context_history.json` (NOT parsed; verbatim nesting shape):**
```json
[[1,[0,[[0,[[1771766242240,"text",["[NOTE] Some previous conversation history … has been removed …"],[]]]]]]],
 [0,[0,[[0,[[1771766242240,"text",["[Continue assisting the user!]"],[]]]]]]]]
```

**`focus_chain_taskid_<id>.md` (NOT parsed):**
```markdown
# Focus Chain List for Task 1771763997801

<!-- Edit this markdown file to update your focus chain list -->
<!-- Use the format: - [ ] for incomplete items and - [x] for completed items -->

- [x] <item 1 — anonymized>
- [ ] <item 2 — anonymized>
```

**`~/.cline/data/state/taskHistory.json` entry (NOT parsed):**
```json
{ "id": "1771763997801", "ulid": "01J…", "ts": 1771766262024,
  "task": "<first prompt — anonymized>",
  "tokensIn": 1789807, "tokensOut": 55124, "cacheWrites": 0, "cacheReads": 1680512,
  "totalCost": 0, "size": 1788250, "cwdOnTaskInitialization": "/Users/<user>/<project>",
  "conversationHistoryDeletedRange": [2, 59], "isFavorited": false, "modelId": "z-ai/glm-5" }
```

---

## References (official sources)

Web confirmation pass 2026-06-21 (`web_access_ok=true`). Verified against:

- [cline/cline — apps/vscode/src/core/storage/disk.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/core/storage/disk.ts) — `GlobalFileNames`, save/get functions, `getGlobalStorageDir`, `getTaskHistoryStateFilePath`, legacy `claude_messages.json` fallback, `collectEnvironmentMetadata`
- [cline/cline — apps/vscode/src/shared/ExtensionMessage.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/shared/ExtensionMessage.ts) — `ClineMessage`, `ClineSay`, `ClineAsk`, `ClineSayTool`, `ClineApiReqInfo` (incl. `retryStatus` `delaySec`/`errorSnippet`)
- [cline/cline — apps/vscode/src/shared/HistoryItem.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/shared/HistoryItem.ts) — `taskHistory.json` item schema (no `parentTaskId`)
- [cline/cline — apps/vscode/src/core/task/index.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/core/task/index.ts) — `api_req_started.text` `JSON.stringify`, single-root vs multi-root `Current Working Directory (…) Files` scaffold
- [cline/cline — apps/vscode/src/core/task/focus-chain/file-utils.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/core/task/focus-chain/file-utils.ts) — `focus_chain_taskid_<id>.md` naming
- [cline/cline — apps/vscode/src/core/context/context-management/ContextManager.ts](https://github.com/cline/cline/blob/main/apps/vscode/src/core/context/context-management/ContextManager.ts) — `context_history.json` producer
- [RooCodeInc/Roo-Code — src/shared/globalFileNames.ts](https://github.com/RooCodeInc/Roo-Code/blob/main/src/shared/globalFileNames.ts) + [src/core/task-persistence/taskMessages.ts](https://github.com/RooCodeInc/Roo-Code/blob/main/src/core/task-persistence/taskMessages.ts) — sibling-fork identical schema (+ `history_item.json`/`_index.json`)
- [Kilo-Org/kilocode](https://github.com/Kilo-Org/kilocode) — Roo/Cline-lineage import (`legacy-migration/task-store.ts`, `roo-import.test.ts`)
- [Cline CLI configuration docs](https://docs.cline.bot/cline-cli/configuration) — `CLINE_DIR` / `--data-dir` / `~/.cline`
- [cline/cline issue #7929](https://github.com/cline/cline/issues/7929) — VS Code `globalStorage` path + extension id `saoudrizwan.claude-dev`
- [DeepWiki cline/cline — CLI commands & storage](https://deepwiki.com/cline/cline/12.2-cli-commands-and-options) — `~/.cline/data`, `ensureTaskDirectoryExists`
