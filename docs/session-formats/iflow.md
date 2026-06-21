# iFlow — Session Format Reference

Last researched: 2026-06-21 (Engram session-format research workflow)

> Definitive English reference for how **iFlow CLI** persists its AI-coding
> sessions on disk, and how Engram's `IflowAdapter` (Swift product parser + TS
> reference parser) discovers and consumes them. Sibling to
> [`gemini-cli.md`](./gemini-cli.md), [`qwen` fixtures](../../tests/fixtures/qwen),
> [`claude-code.md`](./claude-code.md), and [`codex.md`](./codex.md). This doc is
> self-contained; cross-references to `gemini-cli.md` are only for shared lineage.
>
> **Headline finding.** iFlow is a **three-way hybrid**: it lives in a
> Qwen-shaped *directory layout* (`~/.iflow/projects/<encoded-cwd>/…jsonl`), but
> its *transcript record schema is the Anthropic / Claude Code JSONL wire format*
> (`uuid`/`parentUuid`/`sessionId`/`type`/`message` envelope, Anthropic
> `content[]` blocks, `usage.{input_tokens,output_tokens}`, Claude-flavored
> system-injection markers) — NOT Gemini's `{text}`/`parts[]` schema. Its inner
> `tool_result` payload, however, is pure Gemini-CLI
> (`callId`/`responseParts`/`functionResponse`). It is a **Gemini CLI fork**
> (the bundled `bundle/iflow.js` carries `Copyright 2025/2026 Google LLC` SPDX
> headers and a `google.gemini-cli` reference) running a **multi-model** lineup
> over the iFlow open platform — default models are `glm-4.7` and
> `Qwen3-Coder-Plus`, with Kimi K2, DeepSeek v3.2, GLM-4.6 and any
> OpenAI-compatible endpoint also selectable. The captured live session happens
> to run `glm-5`, but iFlow is **not** GLM-only and is **not** Claude-Code-derived
> at the codebase level — the Anthropic-shaped transcript schema is a design
> choice layered onto a Gemini-CLI codebase
> ([source](https://www.npmjs.com/package/@iflow-ai/iflow-cli)).

---

## Evidence basis

Two sources of truth cross-checked; **on conflict REAL data wins, discrepancy flagged.**

1. **LIVE on-disk store** — `~/.iflow/` on this machine. **2 session transcripts**, one per project dir under `~/.iflow/projects/`, both `.jsonl`:
   - `~/.iflow/projects/-Users-bing-Code-WebSite_GLM/session-b5785972-6711-443a-9bb4-e361146f8e79.jsonl` — 238.2 KB, **41 lines** (16 user + 25 assistant).
   - `~/.iflow/projects/-Users-bing-Code-engram/session-041101e6-2a7f-4dfd-90b0-57888a353f6a.jsonl` — 3.7 KB, **4 lines** (2 user + 2 assistant).
   - Totals across both: **45 lines = 18 `user` + 27 `assistant`**.
   - Other live state (none session data, none read by Engram): `~/.iflow/config/projects.json` (1 entry), `~/.iflow/tmp/<64hex>/logs.json`, `~/.iflow/log/console-*.log`, `~/.iflow/settings.json`, `oauth_creds.json`, `iflow_accounts.json`, `installation_id`, and dirs `cache/ config/ log/ skills/ tmp/`.
   - **`find ~/.iflow -name '*.engram.json'` → 0** sidecars. **No SQLite / leveldb / gRPC cache** anywhere under `~/.iflow`.
2. **Repo fixtures** —
   - `tests/fixtures/iflow/{sample.jsonl, schema_drift.jsonl}` (2 standalone fixtures — `sample.jsonl` = user/assistant/user; `schema_drift.jsonl` = 2 forward-tolerance lines).
   - `tests/fixtures/adapter-parity/iflow/{success.expected.json, input/-Users-test-my-project/session-sample.jsonl}` (1 input of 3 lines + 1 expected output).
3. **Engram adapters (codified knowledge)** —
   - Swift product parser: `macos/Shared/EngramCore/Adapters/Sources/IflowAdapter.swift` (207 lines).
   - TS reference parser: `src/adapters/iflow.ts` (213 lines).
   - Shared JSONL helper: `enum JSONLAdapterSupport` (defined inside `macos/Shared/EngramCore/Adapters/Sources/CodexAdapter.swift:4`), plus `macos/Shared/EngramCore/Adapters/ParserLimits.swift` (one dir **above** `Adapters/Sources/`, not a sibling of the parsers) and `StreamingLineReader`.
   - Project-move encoder: `EngramCoreWrite/ProjectMove/Sources.swift` (`encodeIflow`, `:489-499`).

**Discrepancies found & resolved (REAL wins):**
- The project registry is at **`~/.iflow/config/projects.json`** (it exists), **not** `~/.iflow/projects.json` (that path does not exist). Both are sub-claims of the dimension reports; the `config/` path is correct.
- **`tests/fixtures/iflow/` DOES exist** (2 files). One dimension report claimed it was absent — that claim is **wrong**; both `sample.jsonl` and `schema_drift.jsonl` are present.
- No discrepancy that **drops data**: both live `.jsonl` files match the discovery filter, parse cleanly, and surface correctly (contrast Gemini, whose live `.jsonl` sessions are silently dropped). All notable findings are *lineage* and *behavioral edge cases* (see §15).

---

## 1. Overview & TL;DR

**What / where / how.** iFlow CLI stores each chat as **one JSONL file per session** under `~/.iflow/projects/<encodedProjectDir>/session-<UUID>.jsonl`. Each line is one self-contained conversation/tool record. There is **no SQLite, no leveldb, no gRPC cache** — just append-per-line line-delimited JSON. Auxiliary global state (`config/projects.json`, `tmp/<hex>/logs.json`, settings/auth) is **never read by Engram**.

**Mental model.** `session = file`; `record = line`. New turns are **truly appended** as new lines (unlike Gemini's whole-file rewrite or `$set`-snapshot mutation log); earlier lines are immutable. `sessionId` (a string that **carries the `session-` prefix**) is constant across the file and equals the filename stem verbatim.

**Storage tech / authoritative root** (both adapters): `~/.iflow/projects` — `IflowAdapter.swift:9-11` (`.iflow/projects`), `iflow.ts:20` (`join(homedir(),'.iflow','projects')`). **FLAT** layout: session files sit **directly** in each project dir — there is **no `chats/` subdirectory** (iFlow's divergence from Qwen/Gemini, which nest under `chats/`).

**ASCII layout / layering diagram.**

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

**TL;DR for Engram engineers.** Engram reads only `user`/`assistant` records and keeps `sessionId` (with `session-` prefix → `id`), `cwd` (in-file, first non-empty), `timestamp` (first=start, last=end), per-message `model` (first seen), flattened **`text`-block** content, and (Swift only) per-message `usage`. It sets `project: nil` (never reads `config/projects.json`; `decodeCwd` is dead code), and **drops** `uuid`/`parentUuid`/`isSidechain`/`userType`/`gitBranch`/`version`/`toolUseResult`/`stop_reason`/`stop_sequence`/inner `message.id`/`message.type`; all `tool_use` and `tool_result` blocks; and (TS path) **all** token usage.

---

## 2. On-disk layout & file naming

| Path | Role | Storage tech | Read by Engram? |
|---|---|---|---|
| `~/.iflow/projects/` | session transcript root (adapter `projectsRoot`) | dir of per-project dirs | ✅ enumerated |
| `~/.iflow/projects/<encodedProjectDir>/` | one dir per project (= "-"-encoded absolute cwd) | dir | ✅ direct children |
| `~/.iflow/projects/<encodedProjectDir>/session-<UUID>.jsonl` | **one session = one file** | **append-per-line JSONL** | ✅ parsed |
| `~/.iflow/config/projects.json` | project registry (`encodedDir → {name,path,sessions[],…}`) | single JSON object | ❌ never read |
| `~/.iflow/tmp/<64hex>/logs.json` | per-session message telemetry | JSON array | ❌ never read |
| `~/.iflow/log/console-*.log` | CLI console log | text | ❌ |
| `~/.iflow/{settings,oauth_creds,iflow_accounts}.json`, `installation_id`, `cache/`, `skills/` | CLI config/auth/cache | mixed | ❌ |

> **No `~/.iflow/projects.json`** — verified absent live. The registry lives at `config/projects.json`. Unlike Gemini CLI (which keys cwd→name in a top-level `projects.json` and uses it for reverse lookup), iFlow's adapter never consults any project-name map.

### Naming grammar

| Token | Grammar | Live examples | Notes |
|---|---|---|---|
| `<encodedProjectDir>` | absolute cwd with `/` → `-` (leading `/` becomes leading `-`) | `-Users-bing-Code-WebSite_GLM`, `-Users-bing-Code-engram` | Claude-Code-style path encoding. Engram does **not** decode it (`project: nil`); it reads `cwd` from inside the file instead. The project-move encoder (`Sources.swift encodeIflow :489-499`) is **lossy** — it strips per-segment leading/trailing dashes, so `-Code-` → `Code`. The adapter's own `decodeCwd` uses a *different* (`--`→sentinel) scheme and is **dead code**; the two are not inverses (see §15 #2). |
| session file | `session-<UUID>.jsonl` | `session-b5785972-6711-443a-9bb4-e361146f8e79.jsonl`, `session-041101e6-2a7f-4dfd-90b0-57888a353f6a.jsonl` | `<UUID>` = standard 36-char lowercase UUID. **No** timestamp prefix, **no** 8-hex suffix (unlike Gemini's `session-<ts>-<8hex>`). **Discovery filter:** name `hasPrefix("session-")` AND `pathExtension == "jsonl"` (Swift:28 / TS:40). |
| in-file `sessionId` | `session-<UUID>` — **includes the `session-` prefix** | `"session-041101e6-2a7f-4dfd-90b0-57888a353f6a"` | **CONFIRMED across both live files:** `sessionId` == filename stem (`.jsonl` removed) exactly. Engram's stored `id` is therefore `session-<UUID>`, **NOT** a bare UUID. Differs from Gemini/Qwen, where the filename suffix is only `sessionId[0:8]`. |

> **Conflict / nuance (REAL wins).** The `<encodedProjectDir>` name does **not** reliably decode to the in-file `cwd`. Live file 2 sits in dir `-Users-bing-Code-engram` but its in-file `cwd` is `/Users/bing/-Code-/coding-memory` (project renamed/moved on disk). Engram sidesteps this by trusting the in-file `cwd` and setting `project: nil`; the encoder/decoder cannot round-trip (§15 #2).

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

> **Key layout divergence from siblings:** iFlow is **flat** — `projects/<dir>/session-*.jsonl` with **NO `chats/` subdirectory**. Qwen requires `projects/<dir>/chats/*.jsonl` (`QwenAdapter.swift:27-28` guards on a `chats/` dir); Gemini requires `tmp/<dir>/chats/session-*.json`. (See §15 lineage.)

---

## 3. File lifecycle & generation

| Aspect | Behavior | Evidence |
|---|---|---|
| **Storage tech** | File-per-session, append-per-line JSONL. No DB/leveldb/gRPC. | live store; `StreamingLineReader` reads line-by-line |
| **DB vs file** | File. One file = one `sessionId`; filename = `session-<UUID>.jsonl` == in-file `sessionId`. | filename == `sessionId` |
| **Append vs rewrite** | **True append**: each new turn (user/assistant/tool turn) = one new JSON line appended; earlier lines are immutable. `sessionId` constant across the file. (Contrast Gemini legacy `.json` whole-file rewrite and Gemini `.jsonl` `$set` snapshot.) | 41 lines, monotonic `timestamp`; ordered `parentUuid` chain |
| **Per-record linkage** | Each record has its own `uuid`; `parentUuid` points to the prior record's `uuid` (first user record has `parentUuid:null`). Single linear DAG. | live: line 1 `parentUuid:null`; subsequent lines chain |
| **Resume** | Same file/`sessionId` continues to grow; `startTime` (first timestamp) fixed, `endTime` (last timestamp) advances. | append model |
| **Rollover** | New session = new `session-<UUID>.jsonl` in the same project dir. No rotation/segmenting of an existing transcript. | one file per UUID |
| **Archive / cleanup** | No archive dir observed under `projects/`. Registry in `config/projects.json` can lag (live: WebSite_GLM session on disk but absent from registry). | live registry has 1 of 2 projects |
| **Discovery** | `detect()` true iff `~/.iflow/projects` is a directory (Swift:18-20 `isDirectory`; TS:23-30 `stat`). | adapter |
| **Enumeration** | For each **direct child dir** of `projects/`, emit files whose name **starts with `session-` AND extension is `.jsonl`** (Swift:22-34 `hasPrefix("session-") && pathExtension == "jsonl"`; TS:32-51 `startsWith('session-') && endsWith('.jsonl')`). **No `chats/` traversal** (unlike Qwen). Swift returns the list **sorted** (`locators.sorted()` :33); TS yields lazily per-dir in `readdir` order and swallows unreadable dirs (`catch {}` :44-46). | adapter |
| **Size cap (Swift)** | File > **100 MB** → `.fileTooLarge` (`ParserLimits.maxFileBytes = 100*1024*1024`, `Adapters/ParserLimits.swift:17`, via `validateFileSize :47-49`); per-line > **8 MB** → handled by `StreamingLineReader(maxLineBytes:8*1024*1024)`; > **10,000** parsed objects → `.messageLimitExceeded` (`CodexAdapter.swift:71,86`). | `Adapters/ParserLimits.swift:17-19`; `CodexAdapter.swift` |
| **Size cap (TS)** | **NONE.** Unlike `gemini-cli.ts` (10 MB `MAX_SESSION_JSON_BYTES`), `iflow.ts` has no size/line/count cap — whole file streamed line by line. Swift-vs-TS divergence. | `iflow.ts:170-184` |
| **Atomicity guard (Swift only)** | `JSONLAdapterSupport.readObjects` re-checks file identity (size/mtime/resource-id) before+after read; mismatch → `.fileModifiedDuringParse` (an actively-appended live session is rejected, retried later). More likely for iFlow than Gemini since iFlow truly appends per turn. | `CodexAdapter.swift:78-81` |
| **FD-leak guard (TS only)** | `readLines` uses `try/finally` to close the readline interface + stream even on early break (limit/offset), preventing `EMFILE`. | `iflow.ts:170-184` |

---

## 4. Record / line taxonomy (layer 1)

One file = N lines; each line is one JSON object. The discriminator is the top-level **`type`** field. **Observed live + fixtures:** only `user` and `assistant`. Both adapters accept **only** these two; any other `type` is `continue`-skipped (Swift:52-54 / TS:71). `guard !sessionId.isEmpty` else `.malformedJSON` (Swift:89) / `return null` (TS:98).

| `type` | live count | `message.role` | content shape(s) | carries `toolUseResult`? | Engram role | Counted? |
|---|---|---|---|---|---|---|
| `user` | 18 | `"user"` | `string` (real prompt) **or** `array[{tool_result}]` (tool-output turn) | only when content is `tool_result` | `role: user` | yes (user count), **unless** classified as system-injection |
| `assistant` | 27 | `"assistant"` | `array[ {text} \| {tool_use} ]` | never | `role: assistant` | yes (assistant count) |
| _(any other)_ | 0 | — | — | — | skipped | no |

**At the top-level `type` discriminator, there is no standalone `system`, `summary`, `info`, `tool`, or `meta` line type** (unlike Gemini's `info` or Qwen's `system`/`ui_telemetry`). "System" is a *derived* sub-classification of a `user` line, not a line type (see §5 and §7). iFlow has no `ui_telemetry` token row — usage is inline on the assistant message.

> **Confirmed (official): meta/compaction records DO exist on disk — disguised as `type:"user"`.** The official bundle's message creators (`createUserMessage`, `createAssistantMessage`, `createToolResultMessage`, `createCompressionMessage`, `createMetaMessage`) write tool-result, compaction (context-summary), AND meta records all with **top-level `type:"user"`** inside `message:{role:"user",…}` — compaction carries an internal compression marker, meta carries `isMeta:true`. So the discriminator stays `user`/`assistant` only (the statement above holds at that level), but compaction and meta records are persisted disguised as `user` records and are silently counted as user messages by Engram, which does not special-case the `isMeta`/compression flag. There is no `type:"system"` / `type:"summary"` / `type:"info"` anywhere in the writer ([source](https://www.npmjs.com/package/@iflow-ai/iflow-cli)).

> **`messageCount` semantics gotcha (REAL).** A `user` record is counted as a user message **unless** its flattened text matches `isSystemInjection` (Swift:79-85 / TS:86-93). It does **NOT** skip empty-content records. In the live 238 KB session, **12 of 16 user records are `tool_result`-only** (array of `{type:"tool_result"}`, no `text` block) → `extractContent` returns `""`, `isSystemInjection("")` is false → each is **counted as a user message** with empty text. So live `userMessageCount` = 16 (not 4 "real" prompts), and `messageCount` = 16 + 25 = 41 = raw line count. iFlow's `messageCount` therefore inflates with tool turns — contrast Gemini Swift, which pre-filters empty content. See §15 #4.

---

## 5. Shared envelope / metadata fields (layer 1 — per line)

Field presence **differs by `type`**. **Verified key-sets (live):**
- **`user` line:** `cwd, gitBranch, isSidechain, message, parentUuid, sessionId, timestamp, type, userType, uuid, version` (+ `toolUseResult` when it carries a `tool_result`).
- **`assistant` line:** `isSidechain, message, parentUuid, sessionId, timestamp, type, userType, uuid` — **NO `cwd`, `gitBranch`, or `version`** (confirmed: 25/25 assistant lines in the large session have `has_cwd:false, has_version:false, has_git:false`).

| Field | Type | Meaning | Optional | Present on | Consumed? | Example (anonymized) |
|---|---|---|---|---|---|---|
| `sessionId` | string (`session-<UUID>`) | Stable session identity (carries `session-` prefix); Engram primary key | **required** (else `.malformedJSON`/null) | both | ✅ → `id` | `"session-041101e6-2a7f-4dfd-90b0-57888a353f6a"` |
| `type` | string | Record discriminator: `"user"` / `"assistant"` | required | both | ✅ (role + counts) | `"assistant"` |
| `message` | object | The conversation payload (layer 2) | required | both | ✅ | `{ role, content, ... }` |
| `timestamp` | string (ISO-8601 ms, UTC `Z`) | When the record was produced; first→start, last→end | required | both | ✅ → start/end + per-msg ts | `"2026-02-27T09:11:31.532Z"` |
| `cwd` | string (abs path) | Working directory at this turn | optional | **user only (live)** | ✅ → `cwd` (first non-empty wins) | `"/Users/<u>/-Code-/coding-memory"` |
| `uuid` | string (UUID) | Per-record id | required | both | ❌ | `"61c24f2a-a626-4d0b-9441-cdb753a2ec76"` |
| `parentUuid` | string \| null | Prior record's `uuid` (intra-session DAG); `null` on first | required | both | ❌ | `null` / `"aa-001"` |
| `isSidechain` | bool | Sub-agent sidechain flag; **always `false`** live (41/41) | required | both | ❌ | `false` |
| `userType` | string | Origin classification; **always `"external"`** live (41/41) | required | both | ❌ | `"external"` |
| `gitBranch` | string \| null | Git branch at turn time (live: `null`; fixture: `"main"`) | optional | **user only (live)** | ❌ | `null` / `"main"` |
| `version` | string \| null | iFlow CLI/schema version; live `"1.0.0"`, drift fixture `"2.0.0"` | optional | **user only (live)** | ❌ | `"1.0.0"` |
| `toolUseResult` | object | **Line-level** tool-execution metadata sidecar (layer 4; distinct from the `tool_result` content block) | optional | user (tool turns only) | ❌ | `{ status, timestamp, toolName }` |

> **No on-disk envelope-level `messageCount`, `startTime`, `endTime`, or `model`.** `startTime`/`endTime` are derived from first/last `timestamp`; `messageCount` is recomputed; `model` lives inside `message` (layer 2). `cwd`/`model` capture relies on iterating until a record that carries each — the adapter's "first non-empty" loop (Swift:58-74) handles the interleaving (user records carry `cwd`, assistant records carry `message.model`).

### 5a. `toolUseResult` envelope (layer-4 nested object)

Present only on `user` lines whose content block is a `tool_result`. **Live key set (all 12 occurrences identical):** `[status, timestamp, toolName]`.

| Field | Type | Meaning | Live value |
|---|---|---|---|
| `toolName` | string | name of the executed tool | `"read_file"` |
| `status` | string | execution status; **always `"success"`** live (12/12) | `"success"` |
| `timestamp` | number (epoch ms) | tool completion time | `1772183500685` |

This is metadata only; the actual result payload lives in the `message.content[].tool_result` block (§7). Engram ignores it entirely.

---

## 6. Message & content schema (layer 2-3, anonymized examples)

The `message` shape depends on the parent line `type`.

### 6.1 `type: "user"` — `message` object (keys: `role, content`)

| Field | Type | Meaning | Optional | Consumed? | Example |
|---|---|---|---|---|---|
| `role` | string `"user"` | role | required | ❌ (line `type` drives role) | `"user"` |
| `content` | **string** OR array of content blocks | The user prompt (string) or a tool-result delivery (array) | required | ✅ (only `text` blocks flattened; bare string verbatim) | `"<prompt>"` or `[{type:"tool_result",…}]` |

Live: a plain prompt user turn has `content` as a **string**; a tool-result-carrying user turn has `content` as an **array** with one or more `tool_result` blocks (§7). Large session: user content = **12 array + 4 string**; small session = 1 array + 1 string.

### 6.2 `type: "assistant"` — `message` object (Anthropic shape, richest record)

**Live key set (all 25 assistant lines identical):** `content, id, model, role, stop_reason, stop_sequence, type, usage`.

| Field | Type | Meaning | Optional | Consumed? | Example |
|---|---|---|---|---|---|
| `role` | string `"assistant"` | role | required | ❌ | `"assistant"` |
| `content` | array of content blocks | Assistant output (text + tool_use) | required | ✅ (only `text` flattened) | `[{type:"text",text:"…"},{type:"tool_use",…}]` |
| `model` | string | Model id that produced the turn | live: always | ✅ → session `model` (first seen) | `"glm-5"` (all 25) |
| `usage` | object `{input_tokens, output_tokens}` | Per-turn token usage (Anthropic naming) | live: always (may be all-zero) | ✅ **Swift only** | `{input_tokens:16472, output_tokens:224}` |
| `id` | string | Anthropic message id | live: always | ❌ | `"r1"` (fixture) / `msg_…` |
| `type` | string `"message"` | inner message-kind | live: always | ❌ | `"message"` |
| `stop_reason` | string \| null | Anthropic stop reason; **always `null`** live | optional | ❌ | `null` |
| `stop_sequence` | string \| null | Anthropic stop sequence; **always `null`** live | optional | ❌ | `null` |

### 6.3 Content blocks (layer 3 — `message.content[]`)

Block discriminator = inner `type`. **Live histogram across both files:** `text` ×10, `tool_use` ×30, `tool_result` ×12 (large session) + the small session's blocks. **No `thinking`/`reasoning`/`redacted_thinking` block exists** — verified: the content-type histogram contains only the three below; iFlow records no chain-of-thought to disk.

| Block `type` | Keys | Consumed? | Notes |
|---|---|---|---|
| `text` | `{type:"text", text}` | ✅ | non-empty `.text` joined: **`"\n\n"` (Swift, `IflowAdapter.swift:185`)** vs **`"\n"` (TS, `iflow.ts:204`)** — separator divergence |
| `tool_use` | `{type:"tool_use", id, name, input}` | ❌ | assistant's request to run a tool; dropped (`toolCalls:nil` Swift:161) |
| `tool_result` | `{type:"tool_result", tool_use_id, content}` | ❌ | inside a `user` record; dropped (only `text` kept) |

`extractContent` (`IflowAdapter.swift:172-186`, `iflow.ts:194-207`): bare string → used verbatim; array → join non-empty `.text` from `type=="text"` blocks; else → `""`. **`tool_result` blocks contribute no text** → flattened to `""` (see §4 count gotcha).

#### `text` block
```json
{ "type": "text", "text": "<assistant prose>" }
```

#### `tool_use` block (assistant side of a call)
```json
{ "type": "tool_use", "id": "call_-7848967933605705235", "name": "list_directory", "input": { "path": "<abs path>" } }
```
- `id` — call id; **links to the matching `tool_result.tool_use_id`**.
- `name` — live set: `read_file`(16), `task`(6), `list_directory`(4), `replace`(2), `write_file`(2).
- `input` — args; shape varies by tool. **`task` = subagent dispatch** — its `input` keys are `description, prompt, subagent_type` (6 live), iFlow's native multi-agent mechanism. Engram does **not** parse it (see §7, §10).

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

`isSystemInjection` (Swift:166-170 / TS:154-160) re-classifies a `user` line as **system** (→ `systemMessageCount++`, excluded from user count and from the summary) when its flattened text:
- `hasPrefix("# AGENTS.md instructions for ")`, OR
- `contains("<INSTRUCTIONS>")`, OR
- `hasPrefix("<local-command-caveat>")`.

These three marker strings (`# AGENTS.md instructions for `, `<INSTRUCTIONS>`, `<local-command-caveat>`) live **only in Engram's own `isSystemInjection` heuristic**, NOT in iFlow's bundle — grepping the official source for them returns nothing ([source](https://www.npmjs.com/package/@iflow-ai/iflow-cli)). They are Engram's cross-tool injection-detection heuristics borrowed from the Claude/Codex adapters, **different** from Qwen's (`"You are Qwen Code"`, `QwenAdapter.swift:223-224`); treating their presence as an iFlow-specific lineage signal would overstate it (the real lineage signal is the Google LLC / Gemini-CLI license headers in the bundle). **0** such records in the live store (`/init`, real prompts, etc. are real user turns).

---

## 7. Tool calls & results

Tool calls live as `tool_use` content blocks inside an **assistant** record; the paired result comes back as a `tool_result` block inside the **next user** record's `content[]`, with the same `tool_use_id` (Anthropic two-turn split — NOT Gemini's co-located `toolCalls[].result[]` and NOT Qwen's `parts`). A redundant `toolUseResult` object (`{status, timestamp, toolName}`) also sits at the **top level** of that user record (§5a).

### 7.1 `tool_result` block (on user lines)
```json
{ "type": "tool_result", "tool_use_id": "call_-7848967933605705235", "content": { /* nested object — layer 4 */ } }
```
- `tool_use_id` — back-reference to the producing `tool_use.id`.
- `content` — an **object** (not string/array), a nested Gemini-style result envelope. **Live key set (all 12): `[callId, responseParts, resultDisplay]`.**
- `is_error` — **absent in all live data**; would flag a failed tool call.

### 7.2 `tool_result.content` — nested result envelope (layer 4, Gemini-CLI lineage)
```json
{ "callId": "call_-7848967933605705235",
  "responseParts": { "functionResponse": { "id":"call_…","name":"list_directory","response":{ "output":"<result>" } } },
  "resultDisplay": "<human-readable result>" }
```
- `callId` — == `tool_use_id` == `tool_use.id` (triple-confirmed equal across all 12 results).
- `responseParts` — always `{ functionResponse: {…} }` — the **Gemini `functionResponse` shape** (layer 5).
- `resultDisplay` — **string OR object**. Live: **10/12 string** (e.g. `"Listed 7 item(s)."`); **2/12 object** with keys `[fileDiff, fileName, newContent, originalContent]` (for `write_file`/`replace` edit diffs).

### 7.3 `functionResponse` (layer 5, deepest)
```json
{ "id":"call_…","name":"read_file","response":{ "output":"<file contents>" } }
```
Keys: `id, name, response`. `response` = `{output: <string>}` (all 12 live `output` are strings).

### Tool-call ↔ result linkage chain (5 layers)
```
assistant.message.content[].tool_use.id
   ═══ equals ═══  user.message.content[].tool_result.tool_use_id
   ═══ equals ═══  tool_result.content.callId
   ═══ equals ═══  tool_result.content.responseParts.functionResponse.id
```

**Engram imports NONE of this.** Swift sets `toolCalls:nil` (`IflowAdapter.swift:161`); TS `streamMessages` never emits tool blocks (`iflow.ts:144-150` yields only role/content/timestamp). `toolMessageCount: 0` (Swift:103 / TS:110). Tool-result text is dropped by `extractContent`. Parity `success.expected.json` encodes zero tool import via `toolCalls: []` and `fileToolCounts: {}` (there is **no** `toolCallCount` key in the expected file — its 16 top-level keys do not include one). Tool calls are fully on disk but invisible in Engram.

---

## 8. Reasoning / thinking

**N/A for iFlow.** No `thoughts`/`thinking`/`reasoning`/`redacted_thinking` record or content block observed in live data or fixtures (assistant content blocks are only `text` + `tool_use`). iFlow records no chain-of-thought to disk. If iFlow ever emitted Anthropic `thinking` blocks, the adapter would drop them (`extractContent` keeps only `type=="text"`).

---

## 9. Token usage & cost

Per-turn usage lives in `message.usage` on **assistant** records (layer 3). **Anthropic field names**: `input_tokens`, `output_tokens` only — **no** `cache_read_input_tokens` / `cache_creation_input_tokens` / `total` (live key union across all assistant turns = `["input_tokens","output_tokens"]`).

```json
"usage": { "input_tokens": 16472, "output_tokens": 224 }
```

| Field | Type | Meaning | Engram (Swift) mapping |
|---|---|---|---|
| `input_tokens` | int | Prompt/input tokens | `TokenUsage.inputTokens` |
| `output_tokens` | int | Completion tokens | `TokenUsage.outputTokens` |
| `cache_read_input_tokens` | int | (Anthropic-style) — **absent** in iFlow | — |
| `cache_creation_input_tokens` | int | (Anthropic-style) — **absent** in iFlow | — |

**Derivation** (Swift `usage()` `IflowAdapter.swift:188-198`):
- `inputTokens = input_tokens`, `outputTokens = output_tokens` (no cache fields read — note iFlow does **not** use the shared `JSONLAdapterSupport.usage` that also parses cache tokens, so even if iFlow emitted cache fields they'd be ignored).
- Returns `nil` if **both** are 0 (`:194-196`). Usage attached **only to assistant** turns (`:162`); user turns carry `usage:nil`.

> **Discrepancy flags.**
> 1. **TS reference adapter drops ALL token usage** — no `usage`/`tokens` handling anywhere in `iflow.ts` (`streamMessages` yields only `{role,content,timestamp}`, `:144-150`). Swift is the **only** path that produces iFlow cost/usage. (Same TS-vs-Swift split as Gemini and Qwen.)
> 2. **Live usage is overwhelmingly zero.** All 25 assistant turns in the 238 KB GLM session report `{input_tokens:0, output_tokens:0}` → the `>0` guard makes Swift usage `nil` for those turns. The GLM proxy reports zero counts there. **Non-zero IS possible**: the small session's final assistant turn had `{input_tokens:16472, output_tokens:224}`. The parity fixture's `usage:{}` is empty, yielding all-zero `usageTotals` — it **masks** the divergence rather than testing extraction.

No price/cost stored; Engram computes cost downstream.

---

## 10. Subagent / parent-child / dispatch

**Within-file linkage exists but is ignored.** Each record has `parentUuid`/`uuid` forming an intra-session DAG, and `isSidechain:bool` marks sub-agent sidechains — both **Anthropic-style**. Neither adapter reads them. iFlow's native multi-agent mechanism is the `task` tool (`tool_use` with `input.{description,prompt,subagent_type}`, 6 live occurrences) — but it is dropped along with all other tool data (`toolCalls:nil`, `toolMessageCount:0`).

**Cross-session parent linking: none built-in, NO sidecar.** Unlike Gemini (Layer 1c `<sessionId>.engram.json` sidecar) and Codex (`originator`), the iFlow adapter sets `parentSessionId:nil`, `suggestedParentId:nil`, `originator:nil`, `agentRole:nil`, `origin:nil` (`IflowAdapter.swift:109-116`). There is **no `readSidecar`** for iFlow and **0** `*.engram.json` files live. iFlow sessions rely entirely on Engram's **Layer 2 heuristic** (temporal/cwd scoring) for any parent attribution — there is no deterministic link path for iFlow.

---

## 11. Summary / compaction

**N/A on disk** — no summary/compaction record type observed (no `system`/`summary`/`info` line type in 2 live sessions, neither compacted). Engram synthesizes a session **summary** itself: the first non-system `user` message's flattened text, capped at 200 chars (`summary: firstUserText.isEmpty ? nil : String(firstUserText.prefix(200))` `IflowAdapter.swift:105`; `firstUserText.slice(0,200) || undefined` `iflow.ts:112`). Derived, not stored.

Edge case: if the first user turn is a tool-result-only message (empty text), `firstUserText` stays `""` until a later text-bearing user turn (see §15 #4).

---

## 12. SQLite / DB internals

**N/A for iFlow.** Sessions are plain append-per-line JSONL files; no SQLite, leveldb, or gRPC cache anywhere under `~/.iflow` (distinct from the VS Code `.vscdb`/leveldb family). `find ~/.iflow` returns only JSON/JSONL/log/text files.

---

## 13. Auxiliary files

Present live but **NOT consumed**:

| File | Shape | Example (anonymized) | Notes |
|---|---|---|---|
| `~/.iflow/config/projects.json` | `{ "<encodedDir>": { name, path, sessions[], createdAt, lastActivity } }` | `{ "-Users-<u>-Code-coding-memory": { "name":"…","path":"…","sessions":["session-041101e6-…"],"createdAt":"…Z","lastActivity":"…Z" } }` | iFlow project registry. **Adapter never reads it** (`project:nil`). Keyed/valued by the **encoded** dir name (not absolute cwd). `sessions[]` holds bare `session-<UUID>` ids. **Live registry is INCOMPLETE** — lists only 1 of 2 on-disk projects, and its key (`-Users-bing-Code-coding-memory`) matches neither on-disk dir name. |
| `~/.iflow/tmp/<64hex>/logs.json` | array of `{ sessionId, messageId:int, type, message, timestamp }` | `{ "sessionId":"session-b5785972-…","messageId":0,"type":"user","message":"<preview>","timestamp":"…Z" }` | Lightweight per-message telemetry; `messageId` = 0-based int sequence within a session; only stores user-message previews. Ignored. The `<64hex>` dir name is opaque (not the session UUID nor a recognizable cwd hash). |
| `~/.iflow/log/console-*.log` | text | — | CLI console log. Ignored. |
| `~/.iflow/settings.json` | `{ apiKey, baseUrl, bootAnimationShown, cna, modelName, searchApiKey, selectedAuthType }` | — | CLI config + the GLM `baseUrl`/`apiKey`/`modelName`. **Contains secrets** — not session data. Never read. |
| `~/.iflow/{oauth_creds,iflow_accounts}.json`, `installation_id`, `cache/`, `skills/` | auth/identity/runtime | — | Never read. |
| **(absent)** `~/.iflow/projects.json` | — | — | **Does not exist** for iFlow (Gemini has a top-level one; iFlow's registry is at `config/projects.json`). The adapter never looks for either. |

---

## 14. Engram mapping

`source field/record → Engram Session field → adapter file:line`. (Swift = `IflowAdapter.swift`; TS = `iflow.ts`.)

| Engram field | Source field/record | Swift file:line | TS file:line | Notes |
|---|---|---|---|---|
| `id` | first `sessionId` (verbatim, incl. `session-` prefix) | `:58-60, 93` | `:73, 101` | required (else `.malformedJSON` :89 / `null` :98) |
| `source` | constant | `:4, 94` | `:16, 102` | `.iflow` / `'iflow'` |
| `startTime` | first record `timestamp` | `:64-66, 95` | `:75, 103` | required |
| `endTime` | last record `timestamp` (nil if == start) | `:67-69, 96` | `:76, 104` | optional |
| `cwd` | first non-empty in-file `cwd` field | `:61-63, 97` | `:74, 105` | from **user records only** live; NOT decoded from dir name |
| `project` | **`nil`** (never derived) | `:98` | (omitted) | encoded dir name NOT decoded; `decodeCwd` is dead code |
| `model` | first `message.model` | `:71-74, 99` | `:79-81, 106` | **surfaced** (live `glm-5`) — unlike Gemini (always nil) |
| `messageCount` | `userCount + assistantCount` | `:100` | `:107` | **includes tool-result user turns**; excludes system-injection; tool blocks not counted |
| `userMessageCount` | `type=="user"` & not system-injection | `:82-84, 101` | `:88-92, 108` | empty/tool-result content still counted |
| `assistantMessageCount` | `type=="assistant"` | `:76-77, 102` | `:83-84, 109` | |
| `toolMessageCount` | constant `0` | `:103` | `:110` | tool blocks never counted as messages |
| `systemMessageCount` | system-injection user records | `:80-81, 104` | `:87-89, 111` | AGENTS.md / `<INSTRUCTIONS>` / `<local-command-caveat>` |
| `summary` / title | first non-system user text, `prefix(200)` | `:84, 105` | `:91-93, 112` | empty → nil |
| `filePath` | locator | `:106` | `:113` | |
| `sizeBytes` | file size | `:107` | `:114` | Swift `JSONLAdapterSupport.fileSize`; TS `stat.size` |
| `agentRole` / `originator` / `origin` | `nil` | `:109-111` | (omitted) | no dispatch detection for iFlow |
| `parentSessionId` / `suggestedParentId` | `nil` | `:115-116` | (omitted) | no sidecar; Layer 2 heuristic only |
| `summaryMessageCount` / `tier` / `qualityScore` / `indexedAt` | `nil` | `:108, 112-114` | (omitted) | set downstream, not by adapter |
| **per-msg** `role` | `type=="user"`→`.user`, else `.assistant` | `:158` | `:145-149` | |
| **per-msg** `content` | `extractContent(message.content)` (join `text` blocks; bare string verbatim) | `:159, 172-186` | `:147, 194-207` | tool_result/tool_use yield no text; separator **`\n\n` Swift vs `\n` TS** |
| **per-msg** `timestamp` | record `timestamp` | `:160` | `:148` | |
| **per-msg** `usage` | assistant `message.usage` → `TokenUsage{input_tokens,output_tokens}` | `:162, 188-198` | **none** | **Swift only**; nil if both 0 |
| **per-msg** `toolCalls` | `nil` (dropped) | `:161` | (none) | tool data not surfaced |

**What Engram does NOT consume:** `config/projects.json` (entire registry), `tmp/.../logs.json`, the encoded dir name (`project:nil`, `decodeCwd` dead code); per-record `uuid`/`parentUuid`/`isSidechain`/`userType`/`gitBranch`/`version`/`toolUseResult`; assistant `message.id`/`message.type`/`stop_reason`/`stop_sequence`; all `tool_use` & `tool_result` blocks (and the 5-layer linkage chain); and (TS path) all token usage. There is no on-disk envelope `messageCount`/`model` to consume — `messageCount` is recomputed and `model` is read from inside `message`.

---

## 15. Lineage, gotchas, version drift & edge cases

### Shared-format lineage — iFlow is a THREE-WAY HYBRID

iFlow sits between the Anthropic family and the Gemini/Qwen family:

| Dimension | iFlow | Gemini CLI ([`gemini-cli.md`](./gemini-cli.md)) | Qwen Code | Lineage verdict |
|---|---|---|---|---|
| Root | `~/.iflow/projects/` | `~/.gemini/tmp/` | `~/.qwen/projects/` | Qwen-shaped (`projects/`) |
| Layer below project dir | **flat** `session-*.jsonl` | `chats/session-*.json` | `chats/*.jsonl` | **unique** (no `chats/`) |
| File format | **JSONL append-per-line** | single-object `.json` (legacy) / `$set` `.jsonl` (new) | JSONL append-per-line | Qwen-shaped |
| Filename | `session-<UUID>.jsonl` | `session-<ts>-<8hex>.json` | any `*.jsonl` | **unique** (full UUID, `session-` required) |
| in-file `sessionId` | `session-<full-UUID>` (== stem) | `sessionId[0:8]` in name | varies | **unique** (full id, with prefix) |
| Record types | `user`/`assistant` | `user`/`gemini`/`model`/`info` | `user`/`assistant` (`model` role) | Qwen-ish |
| Content shape | `message.content` string OR `[{type:"text"\|"tool_use"\|"tool_result"}]` **Anthropic blocks** | `content` string OR `[{text}]` / `messages[].parts[]` | `message.parts[].text` | **Anthropic** (NOT Gemini/Qwen) |
| Tool model | `tool_use`/`tool_result` blocks (Anthropic split) | `toolCalls[].result[]` co-located | (in parts) | **Anthropic split** |
| Tool-result inner payload | `{callId, responseParts:{functionResponse}, resultDisplay}` | `functionResponse{id,name,response{output}}` | (Gemini parts) | **Gemini-CLI** |
| Reasoning on disk | **none** (no thinking block) | `thoughts` (dropped by Engram) | parts may carry thought | — |
| Token usage | `message.usage.{input_tokens,output_tokens}` **Anthropic** | `tokens.{input,output,cached,…}` | `usageMetadata.{promptTokenCount,…}` / `ui_telemetry` | **Anthropic** |
| System-injection markers | `AGENTS.md` / `<INSTRUCTIONS>` / `<local-command-caveat>` **Claude-flavored** | (none) | `You are Qwen Code` | **Claude/Anthropic** |
| `projects.json` map | **none** (registry at `config/projects.json`, ignored) | yes (top-level) | none (uses dir) | unique |
| Codebase lineage | **Gemini CLI fork** (`Copyright … Google LLC` SPDX headers, `google.gemini-cli` reference in `bundle/iflow.js`) | Gemini CLI (origin) | Gemini CLI fork | **Gemini-CLI fork** |
| Models run | **multi-model**: default `glm-4.7` + `Qwen3-Coder-Plus`; also Kimi K2, DeepSeek v3.2, GLM-4.6, any OpenAI-compatible endpoint (live sample happened to use `glm-5`) | Gemini | Qwen | — |

**Verdict:** iFlow is, at the **codebase** level, a **Gemini CLI fork** — confirmed by the `Copyright 2025/2026 Google LLC` SPDX headers and the `google.gemini-cli` reference in the official `bundle/iflow.js` ([source](https://www.npmjs.com/package/@iflow-ai/iflow-cli)). It is NOT Claude-Code-derived. On top of that Gemini-CLI codebase it layers, by design, an **Anthropic / Claude-Code transcript envelope** (content blocks, usage naming, `parentUuid`/`isSidechain` DAG; the injection markers are Engram's heuristic, not iFlow's — see §6.4), wears a **Qwen-style directory skin** (`~/.tool/projects/<encoded-dir>/`), and keeps **Gemini-CLI tool-result internals** (`callId`/`responseParts`/`functionResponse`). It is NOT a Gemini fork at the *transcript-schema* level even though it is a Gemini fork at the *codebase* level. iFlow is **multi-model** (default `glm-4.7` + `Qwen3-Coder-Plus`, plus Kimi K2 / DeepSeek v3.2 / GLM-4.6 / any OpenAI-compatible endpoint), not GLM-only; the live sample merely ran `glm-5`. The `IflowAdapter` code structure is copied from the Qwen/Gemini sibling template (same `JSONLAdapterSupport`, same `parseSessionInfo` skeleton), which is why the dead `decodeCwd` helper survives. Engram handles iFlow correctly because it treats it as its own adapter with Anthropic-shaped `content`/`usage` extraction — the lineage trap (parsing it as Gemini `{text}`/`tokens`) was avoided. **Note:** iFlow CLI is officially shutting down on 2026-04-17 (Beijing time); users are told to migrate to Qoder ([source](https://platform.iflow.cn/en/cli/changelog)).

### Gotchas / version drift / edge cases

1. **`messageCount` inflates with tool turns.** Tool-result-only `user` records (no `text`) are counted as user messages (no empty-content skip). Live: 12 of 16 "user" records are tool results → `userMessageCount`=16, `messageCount`=41 (= line count). Engram's count ≠ count of real human prompts.
2. **Encoded dir name is LOSSY and never used for cwd.** `Sources.swift encodeIflow` (`:489-499`) strips per-segment leading/trailing dashes, so `/Users/u/-Code-/engram` → `-Users-u-Code-engram` (the `-Code-` dashes vanish). The adapter's own `decodeCwd` (`:143-148`, TS `:163-168`) uses a *different* scheme (`--`→sentinel, `-`→`/`) and is **dead code** (never called). The encoder/decoder are not inverses; the dir name cannot round-trip to cwd. Engram sidesteps this by trusting the in-file `cwd`. The project-move docstring (`Sources.swift:484-488`) flags the lossiness and notes a pre-flight cwd probe catches collisions.
3. **`id` includes the `session-` prefix.** Stored `id` = `session-<UUID>`, not a bare UUID. Cross-tool joins / parent-detection by raw UUID must account for the prefix.
4. **tool_result-only user turns are counted as empty-content user messages.** A `user` record whose `content` is `[{type:"tool_result",…}]` flattens to `""` (only `text` blocks kept). `isSystemInjection("")` is false → it increments `userCount` with empty content, and contributes an empty-content message in `streamMessages` (Swift does NOT pre-filter empty content here, unlike Gemini). If the first user turn is tool-result-only, the synthesized `summary` stays empty until a later text-bearing user turn.
5. **`cwd` only on `user` records.** Live: `cwd`/`gitBranch`/`version` appear on 16/16 user records and 0/25 assistant records. A session with no user record (all assistant) or where iFlow stops emitting `cwd` would yield `cwd=""` (the adapter reads `cwd` only from the first record that carries it). Hypothetical given current data; flagged.
6. **`model` IS surfaced (good) — but only the first one.** Unlike Gemini (always nil), iFlow reports `model` (live `glm-5`). Only the **first** assistant `model` is kept; a session that switches models mid-stream reports only the first.
7. **Token usage is Swift-only and frequently zero.** TS drops all usage. Swift reads `input_tokens`/`output_tokens`, returns nil if both 0 — and the live GLM proxy reports 0 for the 238 KB session's 25 turns, so usage is often absent in practice even on the Swift path. Non-zero is possible (small session line 4: 16472/224).
8. **Text-join separator drift Swift vs TS.** Swift joins multi-text-block content with `"\n\n"` (`:185`); TS with `"\n"` (`:204`). The same multi-part assistant turn renders differently across the two parsers.
9. **TS has no size/line/message caps; Swift caps at 100 MB / 8 MB / 10,000.** A pathological large iFlow file is skipped by Swift (`.fileTooLarge` > 100 MB) but fully streamed by TS. (TS iFlow also lacks Gemini-TS's 10 MB cap.)
10. **File-identity guard (Swift only).** Swift throws `.fileModifiedDuringParse` if the file changes mid-read — an actively-appended live session can fail and be retried later. More likely for iFlow than Gemini since iFlow truly appends per turn.
11. **`config/projects.json` is unreliable & ignored.** Live registry lists only 1 of 2 on-disk projects and uses a key that matches neither on-disk dir name; Engram never reads it anyway.
12. **No deterministic parent linking.** No `*.engram.json` sidecar, no `originator`. `isSidechain`/`parentUuid` are on disk but ignored; cross-session attribution depends entirely on Engram's Layer 2 heuristic.
13. **Schema-drift tolerance.** `schema_drift.jsonl` fixture confirms unknown top-level (`newTopField`) and unknown nested (`futureUserField`, `newAssistantProp`, `responseQuality`) keys are ignored gracefully; a future `model:"iflow-v2"` and `version:"2.0.0"` parse fine. The adapter is forward-tolerant.

---

## 16. Appendix: real anonymized samples

> Keys verbatim; message text, code, secrets, personal paths stripped.

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

Most of these were resolved against the official iFlow CLI bundle (`@iflow-ai/iflow-cli` v0.5.19, `bundle/iflow.js`) and the official docs on 2026-06-21.

- **Does iFlow ever write `system`/`summary`/`info` line types** (e.g. on compaction or context-init)? **Confirmed (official):** NO new top-level type. The writer's `createCompressionMessage` (compaction/context-summary) and `createMetaMessage` both emit records with **top-level `type:"user"`** (meta carries `isMeta:true`, compaction a compression marker); there is no `type:"system"` / `summary` / `info` anywhere in the writer. So compaction/meta records exist on disk disguised as `user` records and are counted as user messages — see §4 ([source](https://www.npmjs.com/package/@iflow-ai/iflow-cli)).
- **What keys `~/.iflow/tmp/<64hex>/`?** **Confirmed (official):** it is `tmp/<project_hash>/`, where `project_hash` is a deterministic hash of the project-root path (not the session UUID, not a cwd-readable string). The same hash keys `tmp/<hash>/shell_history`, the checkpoint stores `snapshots/<project_hash>`, and `cache/<project_hash>/checkpoints`; the bundle also confirms a `logs.json` telemetry logger (`sessionId`/`messageId` fields). The exact hash algorithm is not documented, but it is deterministic from the project root, not opaque-random ([docs](https://platform.iflow.cn/en/cli/configuration/settings), [checkpointing](https://platform.iflow.cn/en/cli/features/checkpointing), [bundle](https://www.npmjs.com/package/@iflow-ai/iflow-cli)).
- **Can assistant `message.content` ever be a bare string** (vs an array of blocks)? (web-checked 2026-06-21: no authoritative source found) — `createAssistantMessage` sets `content` from the model turn but the bundle does not guarantee it is always an array on disk; live + parity fixtures always show an array, the drift fixture uses a string. Both adapters handle string defensively, so behavior is safe regardless.
- **Full enum of `toolUseResult.status`** — **Confirmed (official, partial):** `toolUseResult` is a real envelope field carrying `toolName` (and `status`) on tool-result `user` records, and the Gemini-lineage content envelope is `{callId, responseParts:{functionResponse:{id,name,response}}, resultDisplay}`. On error, `functionResponse.response` carries an `{error:…}` object, `resultDisplay` carries the error message, and there is an `errorType` field. The exact string set for `status` beyond observed `"success"`, and whether `is_error` is ever set on the `tool_result` block, were not pinned down. Either way Engram ignores all of it ([source](https://www.npmjs.com/package/@iflow-ai/iflow-cli)).
- **Is `isSidechain:true` ever emitted** (subagent turns)? **Confirmed (official):** `isSidechain` is a real, settable field — every message creator writes `isSidechain: opts?.isSidechain ?? false`, i.e. defaults to `false` but is set to the caller value. iFlow has a native subagent mechanism (it generates ids like `subagent-${instanceId}-…` and `session-${d}` for subagent sessions), so `isSidechain:true` is emittable; "always false live" is just a sample artifact ([source](https://www.npmjs.com/package/@iflow-ai/iflow-cli)). Whether Engram should consume `parentUuid`/`isSidechain` is (Engram-internal design — not web-verifiable).
- **Meaning/gating of `version`** (live `"1.0.0"` on user records, drift fixture `"2.0.0"`) — **Confirmed (official, partial):** `version` is captured per-record via `collectContext()` as `this.getVersion()` (the iFlow CLI version string), written alongside `cwd`/`gitBranch`/`timestamp`. It is the CLI version that wrote the record, **not** a schema-format version or evolution gate; Engram ignoring it is correct ([source](https://www.npmjs.com/package/@iflow-ai/iflow-cli)).
- **Does iFlow ever populate cache token fields or `thinking` blocks** in any version? **Confirmed (official, partial):** the bundle references `cache_creation_input_tokens` / `cache_read_input_tokens` in internal usage aggregation, but `createAssistantMessage` persists `usage` as `(e.usage || {input_tokens:0, output_tokens:0})` — so the default/skeleton is the two-field Anthropic form; cache counts could appear only if the provider returns them. iFlow supports "thinking mode" models (docs cite glm-4.6 / deepseek-3.2), so reasoning could be produced, but no `thinking`/`reasoning` content-block type was confirmed in the persisted-record writer. Engram would drop either if present ([source](https://www.npmjs.com/package/@iflow-ai/iflow-cli), [docs](https://platform.iflow.cn/en/cli/configuration/settings)).
- **Is all-zero usage a GLM-proxy artifact or does iFlow ever report real counts at scale?** **Confirmed (official, partial):** assistant `usage` defaults to `{input_tokens:0,output_tokens:0}` and is overwritten with `e.usage` from the provider response when present. Zeros mean the provider/turn returned no usage; non-zero is populated straight from the model response (consistent with the small session's 16472/224). Whether a given provider/endpoint returns usage is provider-dependent, not an iFlow format guarantee — "non-zero possible, coverage unverified" stays the right framing ([source](https://www.npmjs.com/package/@iflow-ai/iflow-cli)).
- **Will future iFlow versions add a top-level `projects.json` or a `chats/` subdir** (converging toward Qwen/Gemini)? **Refuted / moot.** iFlow CLI is officially shutting down on 2026-04-17 (migrate to Qoder), so no future convergence is expected. As of the final-era v0.5.x source the layout is flat `projects/<encoded>/session-*.jsonl` with the registry at `config/projects.json` and NO top-level `projects.json` and NO `chats/` subdir — matching this doc; no evidence of any planned `chats/` move ([changelog](https://platform.iflow.cn/en/cli/changelog), [bundle](https://www.npmjs.com/package/@iflow-ai/iflow-cli)).
- **Is the project registry at `config/projects.json` (not top-level `projects.json`)?** **Confirmed (official):** the bundle builds the registry path as `join(getIflowDir(),'config','projects.json')`; the top-level `~/.iflow/projects.json` does not exist ([source](https://www.npmjs.com/package/@iflow-ai/iflow-cli)).
- **Is the encoded project-dir name lossy?** **Confirmed (official):** `getProjectName()` → `fromPath(projectRoot)` runs a chain of `.replace()` calls ending in `.replace(/-+/g,'-')`, which **collapses consecutive dashes**, so `-Code-` is unrecoverable — exactly the round-trip failure observed in §2/§15 #2; trusting in-file `cwd` (`project:nil`) is correct ([source](https://www.npmjs.com/package/@iflow-ai/iflow-cli)).
- **Is the on-disk layout flat `projects/<encoded>/session-<UUID>.jsonl` and is `sessionId` prefixed?** **Confirmed (official):** `findSessionJsonlFile` builds `join(iflowDir,'projects',projectName,'session-${id}.jsonl')` with a bare `${id}.jsonl` fallback and no `chats/` join; `generateSessionId()` returns `` `session-${uuid()}` `` and writes it into every record's `sessionId`, so `sessionId` == filename stem with the `session-` prefix. The undocumented `projects/` store is real per source + live disk (official docs only mention `settings.json`, `tmp/<project_hash>`, `snapshots/<project_hash>`, `cache/<project_hash>/checkpoints`) ([source](https://www.npmjs.com/package/@iflow-ai/iflow-cli)).
- **Is iFlow's transcript schema the Anthropic/Claude-Code JSONL wire format with Gemini-CLI tool-result internals?** **Confirmed (official):** records are `{uuid, parentUuid, sessionId, timestamp, type:'user'|'assistant', isSidechain, userType:'external', message, cwd, gitBranch, version, toolUseResult?}` (Anthropic envelope); assistant `message` is `{id, type:'message', role:'assistant', content:[…], usage:{input_tokens,output_tokens}}`; tool results use the Gemini-CLI `{callId, responseParts:{functionResponse:{id,name,response}}, resultDisplay}` shape; and the codebase carries Google LLC license headers — the "three-way hybrid" characterization is accurate ([source](https://www.npmjs.com/package/@iflow-ai/iflow-cli), [community](https://github.com/QwenLM/qwen-code/discussions/825)).

---

## References (official sources)

- [iflow-ai/iflow-cli (GitHub — distribution/installer repo; Shell + Homebrew formula, install.sh; NOT the JS source)](https://github.com/iflow-ai/iflow-cli)
- [@iflow-ai/iflow-cli on npm (v0.5.19 — bundled `bundle/iflow.js`, the definitive on-disk-format source)](https://www.npmjs.com/package/@iflow-ai/iflow-cli)
- [jsDelivr CDN file listing for @iflow-ai/iflow-cli@0.5.19 (`bundle/iflow.js`, ~13.5 MB)](https://data.jsdelivr.com/v1/packages/npm/@iflow-ai/iflow-cli@0.5.19)
- [iFlow CLI docs — CLI Configuration / settings (`~/.iflow` layout, `tmp/<project_hash>`)](https://platform.iflow.cn/en/cli/configuration/settings)
- [iFlow CLI docs — Checkpointing (`snapshots/<project_hash>`, `cache/<project_hash>/checkpoints`, shutdown notice)](https://platform.iflow.cn/en/cli/features/checkpointing)
- [iFlow CLI docs — Changelog (v0.2.0 conversation persistence; shutdown 2026-04-17, migrate to Qoder)](https://platform.iflow.cn/en/cli/changelog)
- [DeepWiki: iflow-ai/iflow-cli (community reverse-engineered wiki)](https://deepwiki.com/iflow-ai/iflow-cli)
- [QwenLM/qwen-code Discussion #825 (iFlow CLI and Qwen Code both Gemini CLI forks)](https://github.com/QwenLM/qwen-code/discussions/825)
