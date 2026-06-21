# CommandCode Session Format

Last researched: 2026-06-21 (Engram session-format research workflow)

> **Evidence basis.** This doc was assembled from TWO sources of truth, cross-checked, with REAL data winning on conflict:
> 1. **LIVE on-disk store** at `~/.commandcode/` — **11 project directories**, **29 session `.jsonl` files** (excluding checkpoints), **21 `.checkpoints.jsonl` files**, **18 `.meta.json` files**, **1,385 message records** (all `metadata.version: 2`), plus CLI-global files (`config.json`, `auth.json`, `history.jsonl`, `updates.json`, `trusted-hooks.json`, `plans/`, `file-history/`).
> 2. **Repo fixture** `/Users/bing/-Code-/engram/tests/fixtures/commandcode/sample.jsonl` (1 file, 3 records).
> 3. **Engram adapters** (codified knowledge): Swift product parser `macos/Shared/EngramCore/Adapters/Sources/CommandCodeAdapter.swift`; TS reference parser `src/adapters/commandcode.ts`.
>
> Every schema/field claim below was re-verified against the live store on 2026-06-21 (top-level keysets, metadata keysets, content-block type counts, tool input/output types, role distribution). Discrepancies between live data, the fixture, and the adapters are flagged inline.

---

## 1. Overview & TL;DR

**CommandCode** (provider string `command-code`) is a **multi-provider CLI AI coding agent** — the agent shell is the "provider", and the underlying LLM is configurable (live `config.json` carries `deepseek/deepseek-v4-pro`; per-session `.meta.json` files carry `Qwen/Qwen3.7-Max`, `deepseek/deepseek-v4-pro`). Engram treats it as a single source named `commandcode`.

**What/where/how saved:**
- **What:** one JSONL transcript per session, one JSON record per line, one record per message turn (`user` / `assistant` / `tool`).
- **Where:** `~/.commandcode/projects/<projectSlug>/<sessionId>.jsonl`, one directory per working directory (cwd), one UUID-named file per session.
- **How:** line-delimited JSON (JSONL); in current CommandCode (v0.40.0) each save is a full atomic file rewrite (whole array re-serialized, ids regenerated), not an append — see §3. No rollover. Per-session sidecars (`.meta.json` title/model, `.checkpoints.jsonl` file-history snapshots) and a separate `file-history/<sessionId>/` blob store hold UX/restore state.

**Mental model:** CommandCode is a **Claude-Code clone at the on-disk layout layer** (`~/.<tool>/projects/<path-encoded-cwd>/<uuid>.jsonl` + sibling `.checkpoints.jsonl` + identical Claude-style system-injection markers) but a **Vercel-AI-SDK-style dialect at the content-block layer** (`type: "tool-call"` with `toolName`+`input`, `type: "tool-result"` with `output`, `type: "reasoning"`). See §15 lineage.

**Engram reads ONLY** `projects/*/<sessionId>.jsonl`. The session id is the on-disk `sessionId` field (which equals the filename stem for the first session in a file), NOT the filename per se.

### ASCII layout / layering diagram

```
~/.commandcode/                          (CLI-global state — NONE read by Engram)
├── config.json        provider/model/reasoningEffort
├── auth.json          credentials (0600)
├── history.jsonl      cross-session prompt history {p,t}
├── updates.json       updater state
├── trusted-hooks.json hook trust
├── plans/*.md         saved plan-mode docs
├── file-history/<sessionId>/<hash>-<NN>@v<N>   versioned file backups (checkpoint restore)
└── projects/                            <-- Engram enumerates ONLY here
    └── <projectSlug>/                   one dir per cwd (path-encoded)
        ├── <sessionId>.jsonl            <== THE SESSION (Engram parses this)
        │     │
        │     └── record layer (1 line = 1 message)
        │           { id, sessionId, parentId, role, timestamp, gitBranch, metadata, content }
        │             └── content-block layer (content[] = typed blocks)
        │                   text | reasoning | tool-call | tool-result | image
        ├── <sessionId>.checkpoints.jsonl   file-history snapshots  (EXCLUDED by suffix)
        ├── <sessionId>.meta.json           {title, model?}          (NOT read)
        └── settings.json                   per-project UX state     (NOT read)
```

Two distinct nesting layers matter throughout this doc:
- **record layer** — the outer JSON object on each line (the message envelope).
- **content-block layer** — the typed objects inside `content[]` (the message payload).

---

## 2. On-disk layout & file naming

### Root & directory structure

| Path | Kind | Read by Engram? | Purpose |
|---|---|---|---|
| `~/.commandcode/` | dir | no | CLI-global root |
| `~/.commandcode/projects/` | dir | **yes — enumerated** | sessions root; `detect()` is true iff this is a directory |
| `~/.commandcode/projects/<projectSlug>/` | dir | yes (enumerated) | one dir per working directory (cwd) |
| `<projectSlug>/<sessionId>.jsonl` | **JSONL transcript** | **YES — the session** | append-only message log |
| `<projectSlug>/<sessionId>.checkpoints.jsonl` | JSONL | **NO — explicitly excluded** | file-history snapshots (undo/restore) |
| `<projectSlug>/<sessionId>.meta.json` | JSON | NO | session `title` (+ optional `model`) |
| `<projectSlug>/settings.json` | JSON | NO | per-project UX flags (e.g. `tasteOnboarding`) |
| `~/.commandcode/file-history/<sessionId>/<hash>-<NN>@v<N>` | text blobs | NO | versioned file backups referenced by checkpoints |
| `~/.commandcode/plans/*.md` | markdown | NO | saved plan-mode documents |
| `~/.commandcode/history.jsonl` | JSONL | NO | global prompt history (`{p,t}` records) |
| `~/.commandcode/config.json` | JSON | NO | global `provider`, `model`, `reasoningEffort` |
| `~/.commandcode/auth.json` | JSON (0600) | NO | API credentials |
| `~/.commandcode/updates.json`, `trusted-hooks.json` | JSON | NO | updater / hook trust state |

### Naming grammar

| Component | Grammar | Live example | Notes |
|---|---|---|---|
| Project dir (`projectSlug`) | cwd, lowercased, non-alphanumerics → `-`, literal `-` → `--` | `users-bing-code-engram` (≈ `/Users/bing/Code/engram`) | one-way slug; decode is **lossy** (see §15 gotcha 3) |
| Session id | UUID v4 | `400d4036-a1e4-4a22-b24a-9ebc7db0871c` | filename stem; also the `sessionId` field in every record |
| Transcript file | `<uuid>.jsonl` | as above | enumerated by adapter |
| Checkpoint file | `<uuid>.checkpoints.jsonl` | as above | suffix-excluded by adapter |
| Meta file | `<uuid>.meta.json` | as above | not read |
| File-history blob | `<contentHash>-<seq>@v<N>` | `a0aed1deec1d862c-53@v2` | `@vN` increments per edit |

**cwd decode** (`decodeCwd`, Swift `:226-233` / `decodeCwdFromLocator`, TS `:183-190`): replace `--`→`\0`, `-`→`/`, `\0`→`-`. Used **only as a fallback** when no record carries `cwd`. In live data `cwd` is never on a record (0/1,385), so the decoded slug is ALWAYS the cwd source — and it is approximate, not a faithful path (e.g. `users-bing-net-work-safeline` → `users/bing/net/work/safeline`, losing the leading slash and any literal hyphens). No live project dir contains `--`, so the double-dash escape path is exercised only by synthetic tests.

### Live tree example (anonymized)

```text
~/.commandcode/
├── config.json                 # {provider:"command-code", model:"deepseek/deepseek-v4-pro", ...}
├── auth.json                   # {apiKey, userId, userName, keyName, authenticatedAt} (0600)
├── history.jsonl               # lines of {"p":<prompt>,"t":<epoch-ms>}
├── updates.json
├── trusted-hooks.json
├── plans/
│   ├── <plan-name>.md
│   └── <plan-name>.md
├── file-history/
│   └── <sessionId>/                       # e.g. 400d4036-…-0871c/
│       ├── <hash>-53@v1                    # backup version 1 of one file
│       └── <hash>-53@v2                    # backup version 2 (monotonic @vN)
└── projects/
    ├── users-bing-code-engram/                                   # projectSlug
    │   ├── 400d4036-a1e4-4a22-b24a-9ebc7db0871c.jsonl            # ← THE SESSION
    │   ├── 400d4036-a1e4-4a22-b24a-9ebc7db0871c.checkpoints.jsonl # excluded
    │   ├── 400d4036-a1e4-4a22-b24a-9ebc7db0871c.meta.json         # {title, model?}
    │   └── settings.json                                          # per-project
    ├── users-bing-net-work-safeline/
    │   └── …
    └── private-var-folders-9f-…-t-polycli-ledger-contract-q1-ah-rw/   # temp-dir cwd session
        └── …
```

(Live note: one project dir is rooted under macOS temp `/private/var/folders/.../T/` — confirming temp-dir sessions are captured and decode to a `private/var/...` cwd.)

---

## 3. File lifecycle & generation

- **Storage tech: line-delimited JSON (JSONL).** One record per line; this is a file store, not a DB. (`JSONLAdapterSupport.readObjects` Swift `:38`; `readLines` TS `:156`.)
- **Write model: full atomic rewrite, NOT append.** Corrected (official): current CommandCode (v0.40.0) re-serializes the **entire** in-memory message array on every save, writes `<file>.<pid>.tmp`, and renames over the session `.jsonl` (full atomic file rewrite). Each save regenerates **all** record `id`s (fresh `crypto.randomUUID()`) and recomputes `parentId` from `this.lastMessageId`, which starts `null` and is never seeded from resumed data — so record `id`s/`parentId`s are NOT stable across saves, and the first record's `parentId` is `null`. `appendFile` is used only for logs, hook audit, and the global `history.jsonl` — never for the session transcript. The append-only + monotonic-id + non-null-first-`parentId` behavior the live store shows reflects an OLDER CommandCode build; the on-disk RESULT is unchanged (one JSONL file per session, same 8-key envelope), so downstream parsing is unaffected. ([source](https://registry.npmjs.org/command-code/-/command-code-0.40.0.tgz))
- **DB vs file:** **file** — no SQLite, leveldb, or gRPC cache for transcripts. (Contrast with Cursor/VS Code/Copilot/Cline — see §12.)
- **File per session, dir per cwd:** one UUID-named `.jsonl` per session; sessions for the same cwd cluster under one `projectSlug` directory. The writer guarantees the filename stem always equals the file's own `sessionId`.
- **Resume / linked-list continuation:** records form a `parentId` chain (linked DAG) WITHIN a file. The live store's **first record's `parentId` being non-null and pointing to an id NOT present in that file** reflects the older appending build; in current source `parentId` is an intra-file chain only and the first record's `parentId` is `null` (as the **fixture** root shows). CommandCode does NOT thread `parentId` across resumed files. (See §15, resolved.)
- **No rollover:** files are not size- or time-rotated; a session is one file start to finish (largest live transcript ≈ 462 KB / 473,116 bytes).
- **Sidecar lifecycle:** `.meta.json` (title/model) and `.checkpoints.jsonl` (file-history) are written alongside each session; `file-history/<sessionId>/` accumulates versioned blobs (`@v1, @v2, …`) as files are edited during the session.
- **No archive tier on disk:** no separate archived/compacted location; old sessions simply remain in `projects/`.

---

## 4. Record / line taxonomy

CommandCode is JSONL-backed (not DB-backed), so the taxonomy is **record/line types**, not SQLite tables.

### Transcript `.jsonl` records (the only files Engram parses)

| Record kind | Discriminator | Count (live) | Purpose | Engram handling |
|---|---|---|---|---|
| user message | `role: "user"` | 80 | human prompt OR injected system wrapper | counted as user, or reclassified as system if `isSystemInjection` matches |
| assistant message | `role: "assistant"` | 940 | model reply (text / reasoning / tool-call) | counted as assistant |
| tool message | `role: "tool"` | 365 | tool execution results | counted as tool |
| (any other role) | — | 0 | — | **dropped** (Swift `:53-55`, TS `:72-73`) |

There is **no `system` role on disk.** Engram derives `systemMessageCount` by reclassifying `user` records whose extracted text matches Claude-style injected wrappers (`isSystemInjection`, Swift `:168-178` / TS `:230-242`).

### Sidecar record kinds (NOT parsed by Engram)

| File | Record kind | Discriminator | Purpose |
|---|---|---|---|
| `.checkpoints.jsonl` | file-history snapshot | `type: "file-history-snapshot"` (only value seen, 65/65) | undo/restore anchor → backup blobs in `file-history/` |
| `history.jsonl` | global prompt entry | `{p, t}` | cross-session prompt history |
| `.meta.json` | session metadata | `{title, model?}` (single object, not JSONL) | human title + optional model |

---

## 5. Shared envelope / metadata fields

Every transcript record has **exactly 8 top-level keys** — verified uniform across all 1,385 live records (`["content","gitBranch","id","metadata","parentId","role","sessionId","timestamp"]`). The envelope is identical for all three roles. There are **no optional top-level keys in live data**.

### Record envelope (outer / record layer)

| Field | Type | Meaning | Optional | Example (anonymized) |
|---|---|---|---|---|
| `id` | string (UUID) | per-message id; target of the next record's `parentId` | no | `"d6d46e72-aa15-4049-8c26-84c15207258c"` |
| `sessionId` | string (UUID) | owning session; first non-empty seeds `SessionInfo.id` | no | `"400d4036-a1e4-4a22-b24a-9ebc7db0871c"` |
| `parentId` | string \| null | id of the preceding message in the same file (intra-file chain); tool record's `parentId` = the assistant record's `id`. Corrected (official): in v0.40.0 the writer recomputes this from `lastMessageId` (starts `null`, never seeded from resume), so the first record's `parentId` is `null` ([source](https://registry.npmjs.org/command-code/-/command-code-0.40.0.tgz)) | no | current/fixture root: `null`; older-build live store: `"410a7034-…"` (non-null) |
| `role` | enum `user`\|`assistant`\|`tool` | message author (no `system` role on disk) | no | `"assistant"` |
| `timestamp` | string (ISO-8601 UTC) | record wall-clock time; monotonic within file; duplicated in `metadata.timestamp` (always equal) | no | `"2026-05-25T01:56:44.064Z"` |
| `gitBranch` | string | git branch at capture time; `"-"` when not in a repo | no | `"main"` |
| `content` | array \| string | message payload (see §6); array in 1,371/1,385, bare string in 14 (user only) | no | `[ {type:"text",…} ]` |
| `metadata` | object | per-record provenance envelope (see below) | no | `{source,timestamp,version,…}` |
| `cwd` | string | working dir | **YES — absent in all live records (0/1,385)**; present in fixture | (live: never) |
| `model` | string | model id | **YES — absent in all live records (0/1,385)**; present in fixture (assistant only) | (live: never) |

> The adapter timestamp resolver reads top-level `timestamp` first, then `metadata.timestamp` (Swift `:159-164` / TS `:175-181`). The model resolver reads top-level `model`, then `metadata.model` (Swift `:62-67` / TS `:76-79`) — **neither path exists in live v2 data**, so `model` resolves to `nil` for live CommandCode sessions.

### `metadata` sub-object

`metadata` is always present. 5 observed key-set variants (live); union of all keys:

| Field | Type | Meaning | Optional (freq of 1,385) | Example |
|---|---|---|---|---|
| `source` | string | origin channel; constant `"cli"` | always (1385) | `"cli"` |
| `timestamp` | string (ISO) | mirror of top-level `timestamp` (always equal); adapter fallback | always (1385) | `"2026-05-25T01:56:44.064Z"` |
| `version` | int | record schema version; constant `2` | always (1385) | `2` |
| `messageId` | string (UUID) | provider/UI message id (the schema field carried through); checkpoints anchor to it via `snapshot.messageId`. **always differs from top-level `id`** (66/66) | optional (66) | `"685c1246-b555-4593-b068-4be3f4d72303"` |
| `entrypoint` | string | invocation mode; the **only** value the source defines is `"print"` (constant `Oh="print"`), assigned solely by `resolvePrintSession()` for headless one-shot `--print`/`-p`. Interactive sessions write NO `entrypoint` key. Corrected (official) ([source](https://registry.npmjs.org/command-code/-/command-code-0.40.0.tgz)) | optional (16) | `"print"` |
| `isAutomated` | bool | machine-generated / injected turn; the CLI sets it on automated slash-command prompts (`isAutomatedSlashCommandPrompt`) and similar non-human turns. Confirmed (official) ([source](https://registry.npmjs.org/command-code/-/command-code-0.40.0.tgz)) | rare (2) | `true` |
| `isMeta` | bool | meta turn (`createMessageWithMeta`/`sanitizeMessage` paths, e.g. empty-content meta turns). Confirmed (official) ([source](https://registry.npmjs.org/command-code/-/command-code-0.40.0.tgz)) | rare (1) | `true` |

Observed metadata key-set frequencies (live):
```
1302  ["source","timestamp","version"]
  65  ["messageId","source","timestamp","version"]
  16  ["entrypoint","source","timestamp","version"]
   1  ["isAutomated","isMeta","messageId","source","timestamp","version"]
   1  ["isAutomated","source","timestamp","version"]
```

> **Schema-supported-but-unobserved keys.** Corrected (official): the full v2 `metadata` zod schema additionally allows keys the live store never carried: `model`, `duration`, `usage:{inputTokens, outputTokens, totalTokens, cacheReadTokens?, cacheWriteTokens?, estimatedCost?}`, `context:{sessionId?, threadId?, userId?}`, `highlight:bool`, `isSummary:bool`, and `hookContexts:record<string,{preToolUse?, postToolUse?}>`. These are optional and simply unpopulated in this machine's data — a future capture carrying them is expected schema, not drift. ([source](https://registry.npmjs.org/command-code/-/command-code-0.40.0.tgz))
`entrypoint:"print"` records occur in matched pairs: a `user` record whose `content` is a **bare string** (the one-shot prompt) followed by an `assistant` record with `["reasoning","text"]` — i.e. headless one-shot queries. **There is NO empty-array-content user record anywhere in the live store (0/80 user records).** All 8 live `entrypoint:"print"` user records carry bare-string content (lengths: 5× ≈34 bytes + 3 long: 40,111 / 41,768 / 70,358 bytes); these 8 are a subset of the 14 string-content user records (8 `print` + 6 with no `entrypoint`).

---

## 6. Message & content schema

`content` is the **content-block layer**, nested under a record. It is an **array of typed blocks** (1,371 records) or a **bare string** (14 records, user-only). Blocks are discriminated by `.type`.

Live block-type counts and role segregation:

```
assistant:text       748    assistant:reasoning  170    assistant:tool-call  584
tool:tool-result     584    user:text             66    user:image             4
```

Block types are role-segregated: `reasoning` and `tool-call` are assistant-only; `tool-result` is tool-only; `image` is user-only; `text` appears on user and assistant.

| Block `type` | Keys | Meaning | Count | Engram handling |
|---|---|---|---|---|
| `text` | `type`, `text` | natural-language prose | 814 | extracted verbatim (Swift `:189-190` / TS `:198`) |
| `reasoning` | `type`, `text` | model chain-of-thought | 170 | **DROPPED** — no case in `extractContent` switch (Swift `:188-201` default → nil / TS `:196-208`) |
| `tool-call` | `type`, `toolName`, `toolCallId`, `input` | tool invocation | 584 | rendered as `` `<toolName>` `` in content; emitted as `NormalizedToolCall` (name + truncated input JSON) |
| `tool-result` | `type`, `toolName`, `toolCallId`, `output` | tool output (typed wrapper) | 584 | `output` folded into content (string verbatim, else JSON-stringified cap 2000) |
| `image` | `type`, `image` | inline base64 data-URI image | 4 | **DROPPED** — no `image` case in either adapter |

### 6a. `text` block (user + assistant)
| Field | Type | Opt | Meaning |
|---|---|---|---|
| `type` | `"text"` | req | discriminator |
| `text` | string | req | message prose |
```json
{ "type": "text", "text": "<PROSE REDACTED>" }
```

### 6b. `reasoning` block (assistant only) — model thinking trace
| Field | Type | Opt | Meaning |
|---|---|---|---|
| `type` | `"reasoning"` | req | discriminator |
| `text` | string | req | chain-of-thought text (non-empty in all 170 live) |
```json
{ "type": "reasoning", "text": "<THINKING REDACTED>" }
```
**Engram drops this** — `reasoning` falls into `default` and is excluded from the extracted summary text (no thinking captured). See §8.

### 6c. `tool-call` block (assistant only)
| Field | Type | Opt | Meaning | Example |
|---|---|---|---|---|
| `type` | `"tool-call"` | req | discriminator | `"tool-call"` |
| `toolName` | string | req | tool name (13 distinct, see §7) | `"shell_command"` |
| `toolCallId` | string | req | **linkage key** to the matching `tool-result` | `"call_00_MAKdS9FclHpX38eDWrpj6245"` |
| `input` | object (582) \| string (2) | req | tool arguments; shape per-tool | `{ "command": "<CMD>" }` |
```json
{ "type": "tool-call", "toolName": "shell_command",
  "toolCallId": "call_00_MAKdS9FclHpX38eDWrpj6245",
  "input": { "command": "<CMD REDACTED>" } }
```

### 6d. `tool-result` block (tool role only)
| Field | Type | Opt | Meaning | Example |
|---|---|---|---|---|
| `type` | `"tool-result"` | req | discriminator | `"tool-result"` |
| `toolName` | string | req | tool name (mirrors the call) | `"shell_command"` |
| `toolCallId` | string | req | **linkage key** = originating `tool-call`'s `toolCallId` | `"call_00_MAKdS9FclHpX38eDWrpj6245"` |
| `output` | object | req | typed result wrapper `{type, value}` (live: always object, never bare string) | `{ "type": "text", "value": "…" }` |

Nested `output` sub-fields:
| Sub-field | Type | Meaning | Example |
|---|---|---|---|
| `output.type` | enum | `"text"` (582) \| `"error-text"` (2) | `"text"` |
| `output.value` | string | the result/error payload | `"<TOOL OUTPUT REDACTED>"` |
```json
{ "type": "tool-result", "toolName": "shell_command",
  "toolCallId": "call_00_MAKdS9FclHpX38eDWrpj6245",
  "output": { "type": "text", "value": "<OUTPUT REDACTED>" } }
```
Because live `output` is always the `{type,value}` object (never a bare string), Engram's string-output path never runs in production; it JSON-stringifies the whole wrapper, capped at 2000B (Swift `:194-198` / TS `:200-206`).

### 6e. `image` block (user only)
| Field | Type | Opt | Meaning | Example |
|---|---|---|---|---|
| `type` | `"image"` | req | discriminator | `"image"` |
| `image` | string | req | base64 **data-URI** (e.g. `data:image/jpeg;base64,…`, ~114 KB) | `"data:image/jpeg;base64,/9j/2wB…"` |
```json
{ "type": "image", "image": "data:image/jpeg;base64,<BASE64 REDACTED>" }
```
**Engram drops this** — no `image` case in the extract switch (no placeholder).

### 6f. raw-string content (user only, 14 records)
When `content` is a plain string instead of an array. Lengths range 7–70,358 bytes; the long ones are injected system wrappers (AGENTS.md / `<INSTRUCTIONS>` / local-command blocks). Both adapters' `isSystemInjection` reclassify such user turns into `systemMessageCount` (the on-disk `role` is still `"user"`; there is **no** `system` role on disk). Both adapters handle bare-string content verbatim (Swift `:181-183` / TS `:193-194`).

### Common assistant block orderings (live, top)
`text` (553); `text,tool-call` (92); `tool-call` (89); `reasoning,tool-call` (59); `reasoning,text,tool-call` (22); `reasoning,text` (21). When present, `reasoning` leads the block array.

### Full assistant record example (record + content-block layers; verbatim keys, text stripped)
```json
{
  "id": "679dd8d8-...",
  "sessionId": "400d4036-a1e4-4a22-b24a-9ebc7db0871c",
  "parentId": "d6d46e72-aa15-4049-8c26-84c15207258c",
  "role": "assistant",
  "gitBranch": "main",
  "content": [
    { "type": "reasoning", "text": "<STRIPPED>" },
    { "type": "text", "text": "<STRIPPED>" },
    { "type": "tool-call", "toolName": "<tool>", "toolCallId": "call_00_...", "input": { } }
  ],
  "metadata": { "source": "cli", "version": 2, "timestamp": "2026-05-25T01:56:51.228Z" },
  "timestamp": "2026-05-25T01:56:51.228Z"
}
```

---

## 7. Tool calls & results

**Linkage is by `toolCallId`** (NOT by `parentId` or array position). Verified: within a session the set of `tool-call` ids equals the set of `tool-result` ids exactly (1:1). Structurally, an `assistant` record emits N `tool-call` blocks; the immediately-following `tool` record (whose `parentId` = the assistant's `id`) emits the N matching `tool-result` blocks in order.

| Linkage element | Field | Notes |
|---|---|---|
| Call id | `tool-call.toolCallId` | e.g. `call_00_MAKdS9FclHpX38eDWrpj6245` |
| Result id | `tool-result.toolCallId` | identical to the originating call's id |
| Tool name (both sides) | `toolName` | mirrored on call and result |
| Errors | `tool-result.output.type == "error-text"` | 2/584 live; otherwise `"text"` |

**Distinct `toolName` values + counts (live):** `shell_command` 184, `read_file` 123, `explore` 99, `grep` 59, `read_directory` 29, `edit_file` 23, `glob` 22, `todo_write` 20, `read_multiple_files` 9, `write_file` 9, `enter_plan_mode` 5, `exit_plan_mode` 1, `think` 1.

**Per-tool `input` shapes (top):** `shell_command`→`{command[,timeout]}`; `read_file`→`{absolutePath[,limit,offset]}`; `explore`→`{messages}`; `grep`→`{path,pattern}` or `{directory,pattern}` (the 2 string-input cases are `grep`); `edit_file`→`{filePath,newValue,oldValue}`; `write_file`→`{content,filePath}`; `todo_write`→`{todos}`; `think`→`{thought}`; `glob`→`{directory,include,pattern}`.

**Engram handling.** Neither adapter actually joins call↔result. The Swift `toolCalls` (`:206-219`) / TS `toolCalls` (`:213-228`) extract only `tool-call` blocks into `NormalizedToolCall{name, input(JSON, capped 500B), output: nil}` — `output` is always nil (Swift `:217`). The result text is only folded into the flat content summary via `extractContent`. Swift accepts `input ?? args` (`:215`); TS reads only `input` (`:224`) — a parity gap (see §15 divergence 6). Live data uses object `input`, so the object-JSON-stringify path runs in production.

---

## 8. Reasoning / thinking

**Stored on disk: YES.** `reasoning` blocks (170 live, assistant-only) carry the model's chain-of-thought as plain text (`{type:"reasoning", text:"…"}`), and lead the block array when present.

**Captured by Engram: NO.** Neither adapter's `extractContent` switch matches `reasoning` — it falls into `default` and is silently dropped from the extracted summary/transcript text. No thinking surfaces in Engram search or transcript for CommandCode.

---

## 9. Token usage & cost

**Absent in the observed data; the schema supports it but it was not populated.** The user's live store carries no usage data (verified: 0/1,385 records carry `usage`; `jq paths | grep -iE 'usage|token|cost'` → empty), so Engram cannot read it. Both adapters reflect this: Swift `message()` sets `usage: nil` (`:155`); TS omits usage entirely.

Corrected (official): the FORMAT does define usage. The v2 `metadata` zod schema includes an optional `usage:{inputTokens, outputTokens, totalTokens, cacheReadTokens?, cacheWriteTokens?, estimatedCost?}` object plus a `metadata.duration` field, so token/cost CAN be persisted by CommandCode — it was simply absent/unpopulated in the captured sessions (likely an older CLI build or a build that did not persist it). The earlier "no usage field anywhere in CommandCode files" claim was true for the observed data but overstated as a format claim. ([source](https://registry.npmjs.org/command-code/-/command-code-0.40.0.tgz))

---

## 10. Subagent / parent-child / dispatch

**N/A at the adapter layer.** CommandCode has no Gemini-style `.engram.json` sidecar, no Codex-style `originator`, and no Claude-Code-style `/subagents/` path linkage. The adapters hard-code `agentRole: nil`, `originator: nil`, `parentSessionId: nil`, `suggestedParentId: nil` (Swift `:112-119`).

The record-level `parentId` field threads messages **within a single session file** as a linked DAG — but Engram does NOT model it (the transcript is flattened to linear order). It is unrelated to Engram's session-level parent/child grouping. Confirmed (official): the actual cross-session link CommandCode uses is `.meta.json#parentSessionId` (written for forked sessions via `--fork-session`), NOT the record-level `parentId` — neither adapter reads the sidecar, so Engram's `parentSessionId` stays nil. Any agent-session grouping for CommandCode would be applied downstream by the indexer's Layer-2 heuristic (temporal/cwd scoring), not by this adapter. ([source](https://registry.npmjs.org/command-code/-/command-code-0.40.0.tgz))

(Note: `metadata.entrypoint:"print"` and `metadata.isAutomated`/`isMeta` flag headless/automated turns that could in principle feed dispatch classification, but the adapter ignores them — see §15 Resolved questions.)

---

## 11. Summary / compaction

**N/A on disk.** There is no compaction/summary record type in the transcript and no separate compacted/archived store. The closest artifact is `.meta.json#title` — a curated human-readable session title — but it is a sidecar, not an in-transcript summary, and Engram does not read it (see §5/§14).

Engram synthesizes its own `summary` from the **first non-system user message text, truncated to 200 chars** (Swift `:108` / TS `:114`). This effectively serves as Engram's title surrogate, since the real `.meta.json#title` is unused.

---

## 12. SQLite / DB internals

**N/A for CommandCode.** CommandCode is a JSONL file store, not a DB-backed tool. There is no SQLite `.vscdb`, leveldb, or gRPC cache for transcripts. (Contrast: Cursor / VS Code / Copilot / Cline use SQLite/leveldb — see those docs.)

---

## 13. Auxiliary files

All present on disk; **none are parsed by Engram.**

### `<sessionId>.meta.json` (per-session)
Corrected (official): the sidecar is NOT limited to `{title, model?}`. `saveSessionMeta` merges arbitrary keys; `saveSessionTitle` writes `{title}`; rename sets `userRenamed`; and the fork path (`copyForkSessionFiles`, invoked by `--fork-session`) writes additional keys. Full possible schema below ([source](https://registry.npmjs.org/command-code/-/command-code-0.40.0.tgz)).
| Field | Type | Opt | Meaning | Example |
|---|---|---|---|---|
| `title` | string | req (18/18) | human-readable session title (auto-generated summary) | `"Review recent commits with sub-agents"` |
| `model` | string | optional (3/18) | model used; **the only per-session model record** | `"deepseek/deepseek-v4-pro"`, `"Qwen/Qwen3.7-Max"` |
| `userRenamed` | bool | optional (schema; unobserved here) | set when the user manually renames the session | `true` |
| `parentSessionId` | string | optional (fork only) | **the REAL cross-session (fork) link** CommandCode uses — distinct from record-level `parentId`; relevant to Engram's currently-nil `parentSessionId` mapping | `"<uuid>"` |
| `forkedAt` | string (ISO) | optional (fork only) | fork timestamp | `"2026-05-25T01:56:44.064Z"` |
| `branchPoint` | (varies) | optional (fork only) | fork branch point | — |

### `<sessionId>.checkpoints.jsonl` (per-session, file-restore snapshots)
Top-level record (always 4 keys): `["isSnapshotUpdate","messageId","snapshot","type"]`.
| Field | Type | Meaning | Example |
|---|---|---|---|
| `type` | string | constant `"file-history-snapshot"` (65/65) | `"file-history-snapshot"` |
| `isSnapshotUpdate` | bool | full snapshot vs incremental update | `false` |
| `messageId` | string (UUID) | message this snapshot is anchored to | `"f7984133-…"` |
| `snapshot` | object | `{messageId, timestamp, trackedFileBackups}` | — |

`snapshot.trackedFileBackups` = map of file-path → backup descriptor (empty `{}` when no edits). Confirmed (official) against the source zod schema: the checkpoint record is `{type: literal("file-history-snapshot"), messageId: uuid, snapshot: {messageId: uuid, trackedFileBackups: record(string, BACKUP), timestamp: string.datetime()}, isSnapshotUpdate: boolean}`, and the per-file `BACKUP` descriptor is `{backupFileName: string.nullable(), version: number.int().positive(), backupTime: string.datetime()}` ([source](https://registry.npmjs.org/command-code/-/command-code-0.40.0.tgz)):
| Sub-field | Type | Meaning |
|---|---|---|
| `backupFileName` | string \| null | name of the backup blob under `~/.commandcode/file-history/<sessionId>/`. Corrected (official): the schema types this `string.nullable()` (can be `null`), not a plain string |
| `backupTime` | string (ISO datetime) | when the backup was taken — Confirmed (official): typed `string.datetime()`, so it **cannot be a number** by schema (58/58 non-empty entries; `number` not observed) |
| `version` | number | backup version — Confirmed (official): always a positive integer (`number.int().positive()`, 58/58) |

These power undo/restore; the backed-up file contents live in `file-history/<sessionId>/<hash>@vN`. Engram excludes them via the `.checkpoints.jsonl` suffix filter (Swift `:28` / TS `:44`).

### `settings.json` (per-project)
Per-project UI/onboarding state (e.g. `tasteOnboarding`). Never read.

### CLI-global `~/.commandcode/config.json`
Keys (live): `provider` (`"command-code"`), `model` (e.g. `"deepseek/deepseek-v4-pro"`), `installed` (bool), `firstMessageSent` (bool), `reasoningEffort` (map `{"<model>": "high"}`).

### CLI-global `~/.commandcode/history.jsonl`
Cross-session prompt history; each line `{ "p": <prompt string>, "t": <epoch-ms number> }`.

### CLI-global `~/.commandcode/auth.json` (0600, secret)
Keys only (values not read): `apiKey`, `authenticatedAt`, `keyName`, `userId`, `userName`.

### CLI-global `~/.commandcode/{updates.json, trusted-hooks.json}` and `plans/*.md`, `file-history/`
Updater state, hook trust state, saved plan-mode markdown, and versioned file-backup blobs. None read.

---

## 14. Engram mapping

Output struct: `NormalizedSessionInfo` (Swift) / `SessionInfo` (TS). Both adapters iterate records once, counting only `role ∈ {user, assistant, tool}`.

**Identity & registration:**

| Concept | Value | Swift evidence | TS evidence |
|---|---|---|---|
| Source id (enum) | `commandcode` | `Adapters/SessionAdapter.swift:15` (`case commandcode`); also `EngramCoreWrite/ProjectMove/Sources.swift:45` | `src/adapters/commandcode.ts:17`; `src/adapters/types.ts:15` |
| On-disk root | `~/.commandcode/projects` | `CommandCodeAdapter.swift:9-11` | `commandcode.ts:21-22` |
| Adapter class | `CommandCodeAdapter` | `CommandCodeAdapter.swift:3` | `commandcode.ts:16` |
| Factory registration | registered twice | `SessionAdapterFactory.swift:21,66`; app path `Engram/Core/MessageParser.swift:130` | (TS registered in factory) |
| `detect()` | true iff projects dir exists | `CommandCodeAdapter.swift:18-20` | `commandcode.ts:25-32` |
| Enumeration | direct project dirs → `*.jsonl` minus `*.checkpoints.jsonl`; Swift sorts, TS lazy | `CommandCodeAdapter.swift:22-34` | `commandcode.ts:34-52` |

**Field mapping (source field/record → Engram Session field → adapter file:line):**

| Engram field | Derived from | Swift:line | TS:line | Live-data behavior / gotcha |
|---|---|---|---|---|
| **id** | first record's `sessionId` | `:56-58`, `:96` | `:74`, `:103` | UUID == filename; fails (`malformedJSON`/null) if no record carries `sessionId` (Swift `:93` / TS `:95`) |
| **source** | constant `.commandcode` | `:97` | `:104` | — |
| **startTime** | first record with a timestamp | `:68-69`, `:98` | `:80-81`, `:104-105` | top-level `timestamp` present 100% in live → reliable. **TS adds mtime fallback (`:99-101`) when no timestamp; Swift does NOT** → divergence on timestamp-less files (Swift leaves `startTime=""`) |
| **endTime** | last record's timestamp, else nil if == start | `:70`, `:99` | `:82`, `:106` | nil for single-message sessions |
| **cwd** | first record's `cwd` else **dir-name decode** | `:59-61`, `:100`, decode `:226-233` | `:75`, `:107`, decode `:183-190` | **live `cwd` always absent → ALWAYS hits `decodeCwd`** (lossy, see §15 gotcha 3) |
| **project** | — | `:101` (`nil`) | (omitted) | hard-coded nil |
| **model** | first record `model` else `metadata.model` | `:62-67`, `:102` | `:76-79`, `:105` | **live `model` always absent in JSONL → `model` is ALWAYS nil for real sessions.** Real model lives in `.meta.json` (never read) |
| **messageCount** | user+assistant+tool | `:103` | `:109` | excludes system-reclassified records |
| **userMessageCount** | `user` records minus system-injections | `:73-83`, `:104` | `:83-90`, `:110` | injected Claude-style wrappers reclassified as system (`:168-178` / `:230-242`) |
| **assistantMessageCount** | `assistant` records | `:84-85`, `:105` | `:91`, `:111` | — |
| **toolMessageCount** | `tool` records | `:86-87`, `:106` | `:92`, `:112` | — |
| **systemMessageCount** | user records matching `isSystemInjection` | `:78-79`, `:107` | `:85-86`, `:113` | heuristic on text prefixes/markers |
| **summary** | first non-system user text, `prefix(200)` | `:82`, `:108` | `:89`, `:114` | Engram's effective "title" surrogate (real `.meta.json#title` unused) |
| **filePath** | locator (absolute) | `:109` | `:115` | — |
| **sizeBytes** | file size | `:110` | `:116` | per-file bytes |
| **indexedAt / agentRole / originator / origin / summaryMessageCount / tier / qualityScore / parentSessionId / suggestedParentId** | — | `:111-119` (all nil) | (absent in TS struct) | set downstream by the indexer, not the adapter |
| **usage / tokens / cost** | — | `usage: nil` `:155` | (omitted) | not in source — does not exist in live data |

**Per-message stream mapping** (`streamMessages` Swift `:129-140` → `message(from:)` `:146-157` / TS `:123-150`) → `NormalizedMessage`/`Message`:

| Message field | Derived from | Swift:line | TS:line |
|---|---|---|---|
| `role` | record `role` | `:147-148` | `:135` |
| `content` | flattened block text via `extractContent` | `:152`, `:180-204` | `:144`, `:192-211` |
| `timestamp` | top-level `timestamp` else `metadata.timestamp` | `:153`, `:159-164` | `:145`, `:175-181` |
| `toolCalls` | `tool-call` blocks → `NormalizedToolCall{name, input(cap 500B), output:nil}` | `:154`, `:206-224` | `:146`, `:213-228` |
| `usage` | — | `:155` (nil) | (omitted) |

### What Engram does NOT consume
1. `.meta.json` entirely — both `title` and `model` dropped (model exists on disk but is never read → `model = nil`).
2. `reasoning` content blocks (170 live) — chain-of-thought dropped.
3. `image` content blocks (4 live) — inline base64 images dropped.
4. `.checkpoints.jsonl` — excluded from listing.
5. `settings.json` — per-project UI state.
6. `gitBranch` — present on 100% of records, never mapped into the session struct.
7. `metadata.entrypoint` / `isAutomated` / `isMeta` / `messageId` / `version` / `source` — none mapped.
8. `parentId` (intra-session DAG) — message threading not modeled; transcript flattened to linear order.
9. token/usage/cost — not in source.

---

## 15. Lineage, gotchas, version drift & edge cases

### Shared format lineage

CommandCode's record shape `{role, content[], sessionId, parentId, timestamp, metadata}` is a member of the **Claude-Code-derived JSONL family** with its own dialect:

| Trait | CommandCode | Claude Code | Codex | Gemini/Qwen/iFlow | Cursor/VSCode/Copilot/Cline |
|---|---|---|---|---|---|
| Storage | per-session JSONL under `~/.commandcode/projects/<encoded-cwd>/` | per-session JSONL under `~/.claude/projects/<encoded-cwd>/` | JSONL under `~/.codex/sessions/` | dir trees / sidecars | SQLite `.vscdb` / leveldb |
| cwd encoding | `/`→`-`, `--` escape (Swift `:226-233`) | **same** dir-encoding scheme | n/a | n/a | n/a |
| `.checkpoints.jsonl` sibling | yes (filtered out) | yes | no | no | no |
| Claude-style system-injection heuristic | **identical regex/prefix set** (Swift `:168-178`) | origin of those markers | — | — | — |
| content block tagging | `tool-call`/`tool-result`/`text`/`reasoning`/`image` (Vercel AI-SDK-ish: `toolName`+`input`/`output`) | `tool_use`/`tool_result` (Anthropic block shape) | function-call/output | varies | varies |

**Lineage conclusion:** CommandCode is a **Claude-Code clone at the on-disk layout layer** (same `~/.<tool>/projects/<path-encoded-cwd>/<uuid>.jsonl` + `.checkpoints.jsonl` + system-injection markers — the Swift adapter comments explicitly say it "mirrors the TS commandcode adapter" and parity with claude-code behavior, Swift `:75-77`, `:166-167`) but a **Vercel-AI-SDK-style dialect at the content-block layer**. It is a **provider-agnostic agent shell** (DeepSeek/Qwen models in `.meta.json`), distinguishing it from single-vendor CLIs. It is NOT in the Gemini↔Qwen↔iFlow layout lineage nor the Cursor↔VSCode↔Copilot↔Cline SQLite lineage. This doc is self-contained; cross-reference the Claude Code doc for the shared layout/system-injection heritage.

### Gotchas

1. **GOTCHA (model lost):** the real model is in `.meta.json#model` (e.g. `deepseek/deepseek-v4-pro`), which neither adapter reads, and is absent from all live JSONL records. Production `model` is **always nil** despite the data existing on disk. Quick win: read the sidecar.
2. **GOTCHA (title lost):** `.meta.json#title` (a curated human title) is ignored; Engram uses a 200-char first-user-message slice as `summary`.
3. **GOTCHA (lossy cwd decode):** since live `cwd` is always absent, every session falls back to dir-name decoding, which is **irreversibly lossy for paths with hyphens** — e.g. project `my-project` decodes to `my/project`; the real path `/Users/bing/-Code-/engram` is captured as dir `users-bing-code-engram` → decodes to `users/bing/code/engram` (lost leading slash, lost `-Code-` hyphens/casing). The `--`→`-` escape only protects double-hyphens; single literal hyphens are unrecoverable.
4. **GOTCHA (dropped reasoning/images):** 170 reasoning + 4 image blocks in live data are silently dropped from transcript and search text.
5. **GOTCHA (title surrogate):** Engram's `summary` is the first non-injected user message, which may itself be noise if the first turn is short or a probe.

### Divergences (Swift vs TS)

6. **DIVERGENCE (timestamp fallback):** TS falls back to file mtime when no record has a timestamp (`:99-101`); Swift does not (leaves `startTime=""` → sorts to epoch). Low impact on live data (top-level timestamp is 100% present), but a real parity gap.
7. **DIVERGENCE (`args` fallback):** Swift reads `input ?? args` for tool-call input (`:215`); TS reads only `input` (`:224`). The Swift parity test `testCommandCodeAdapterAcceptsArgsForToolCallInput` (`macos/EngramTests/AdapterParityTests.swift:382`) exercises the `args` path, but live data uses object `input` (582/584) — neither `args` nor string-input is the common case.

### Edge cases & version drift

8. **EDGE (string content):** 14/1,371 live records have `content` as a bare string (not array); both adapters return it verbatim (Swift `:181-183` / TS `:193-194`).
9. **EDGE (object output forces JSON-stringify):** `tool-result.output` is an object 584/584 in live data, so the verbatim-string path never runs; output is always JSON-serialized and capped at 2000 chars — large tool outputs are truncated in the indexed transcript.
10. **EDGE (string tool-call input):** 2/584 live `tool-call` blocks carry a bare-string `input` (both are `grep`); `jsonString`/`truncateJSON` handle these.
11. **EDGE (temp-dir cwd):** one live project dir is under `/private/var/folders/.../T/`, confirming temp-dir sessions are captured.
12. **EDGE (parse-fail = drop):** any line failing `JSON.parse` is skipped; a session with zero records carrying `sessionId` is rejected entirely (Swift `:93` `.malformedJSON` / TS `:95` null).
13. **VERSION marker:** `metadata.version: 2` on 100% of live records — a forward-compat hook neither adapter inspects. A future `version: 3` schema would parse silently with no guard.
14. **FIXTURE vs LIVE divergence:** the fixture `sample.jsonl` (3 records) was crafted to exercise defensive paths absent from this machine's live data — it carries top-level `cwd`/`model` and a `parentId: null` root spread across two distinct record variants: the **user/root** record is a **9-key** variant `["content","cwd","gitBranch","id","metadata","parentId","role","sessionId","timestamp"]` (has top-level `cwd`, **no** `model`) with `parentId: null`; the **assistant** record is a **10-key** variant that adds `model` (top-level `cwd` AND `model`), with `parentId: "msg-001"` (the tool record is a 9-key variant, `parentId: "msg-002"`). The live store has neither the top-level `cwd`/`model` nor a null first `parentId` (every live record is the 8-key envelope with a non-null first `parentId`). NOTE (web-confirmed 2026-06-21): the fixture's `parentId: null` root actually MATCHES current CommandCode (v0.40.0), whose writer always sets the first record's `parentId = null`; the live store's non-null first `parentId` reflects an OLDER appending build, so it is the LIVE data — not the fixture — that diverges from current source on this point ([source](https://registry.npmjs.org/command-code/-/command-code-0.40.0.tgz)). The fixture's `tool-call` input is an object (`{path: …}`), matching live; its `tool-result` output is a bare string (`"file contents omitted"`), which does NOT match live (live is always the `{type,value}` object). So parity tests pass while live behavior drops the model, the cwd, and JSON-stringifies every tool-result.

### Resolved questions (web-confirmed 2026-06-21)
- **v1 schema.** Confirmed (official): the CLI defines `isLegacyFormat(e) = (!e.metadata || e.metadata.version !== 2)` — any record without `metadata.version === 2` is treated as v1/legacy. On `loadMessages()`, if any line `isLegacyFormat`, the CLI runs `legacyAnthropicToSession(...)` (via `convertUserMessage`/`convertAssistantMessage`/`buildToolNameMap`) to convert a **legacy Anthropic message format** (records shaped `{role, content}` with Anthropic-style content blocks) into v2, logs `[Session] Migrating v1 session to v2: <file> (<n> messages)`, then rewrites the file with `parentId: null` and `metadata.version: 2`. So v1 was an Anthropic-message-shaped transcript; v2 (the current on-disk format) is the `{id, timestamp, sessionId, parentId, role, content, gitBranch, metadata}` envelope. NOTE: the source's only documented legacy path is the Anthropic `{role,content}` format — the top-level `cwd`/`model` and `metadata.model` fields the Engram adapter probes are NOT present in either the v1-migration code or the v2 writer; in current code `model` lives only in `.meta.json` and `cwd` only in the project dir name, so those probes are adapter-defensive against an even-older inline layout not represented in current source. ([source](https://registry.npmjs.org/command-code/-/command-code-0.40.0.tgz))
- **Cross-session `parentId`.** Confirmed (official): in v0.40.0 the writer (`SessionManager.writeMessages`) does NOT append — it rebuilds the entire message list from the in-memory array on each save, generates a fresh `crypto.randomUUID()` for every record `id`, and sets `parentId = this.lastMessageId`, where `lastMessageId` starts `null` at construction and is only updated inside the rewrite loop (never seeded from a loaded/resumed session). So the first record's `parentId` is `null` and the chain is purely intra-file. Resume/continue (`loadMessages` → `resolvePrintSession`/`loadResumed`) reloads prior messages into memory but the next save still rewrites the whole file from `parentId: null`. CommandCode does NOT thread `parentId` across resumed files; no preamble/system record is written to a separate file; and the filename always equals the file's own `sessionId` (writer sets `sessionFilePath = <sessionId>.jsonl` and stamps each record's `sessionId = this.sessionId`). The live store's observed non-null first-record `parentId`/stable ids is most consistent with an OLDER appending build (predates v0.40). ([source](https://registry.npmjs.org/command-code/-/command-code-0.40.0.tgz))
- **`metadata.messageId` / `isAutomated` / `isMeta` semantics.** Confirmed (official) via the source zod schema for `metadata`: `messageId` is the provider/UI message id (checkpoints anchor to it via `snapshot.messageId`); `isAutomated:boolean` marks a machine-generated/injected turn (the CLI sets it on automated slash-command prompts via `isAutomatedSlashCommandPrompt` and similar non-human turns); `isMeta:boolean` marks a meta turn (`createMessageWithMeta`/`sanitizeMessage` paths, e.g. empty-content meta turns). The inferred semantics were correct. ([source](https://registry.npmjs.org/command-code/-/command-code-0.40.0.tgz))
- **`entrypoint:"print"` / `isAutomated` dispatch potential.** Confirmed (official): the source defines a single `entrypoint` constant `Oh="print"`, assigned only by `resolvePrintSession()` when the CLI runs in headless one-shot mode via the documented `--print`/`-p` flag ([CLI reference](https://commandcode.ai/docs/reference/cli): `cmd --print "message"` runs headless, outputs the response, and exits). The writer stamps `entrypoint` into metadata only when `this.entrypoint` is set, so interactive sessions write NO `entrypoint` key — explaining why `"print"` is the only value seen on disk and why most records omit it. Whether CommandCode itself uses `entrypoint`/`isAutomated` for dispatch classification: not present in source — that is an Engram-internal design choice, out of scope for the tool format. ([source](https://registry.npmjs.org/command-code/-/command-code-0.40.0.tgz))
- **`--` escape unexercised by live data.** (Engram-internal design — not web-verifiable.) Whether the Engram adapter's `--`/`-` decode branch is exercised by the user's data is an Engram coverage observation, not a web-answerable CommandCode-format fact. On the underlying format: the CLI's `getCurrentProjectDirName` encodes `process.cwd()` via a minified helper that could not be deobfuscated to a literal regex in the bundle, so the exact escaping rule (single `-` vs `--`) was NOT independently confirmed from source. The described scheme (lowercase, non-alnum → `-`, literal `-` → `--`) comes from the Engram adapter and should be treated as adapter-asserted, not source-confirmed. ([source](https://registry.npmjs.org/command-code/-/command-code-0.40.0.tgz))

### Source availability
Confirmed (official): CommandCode's CLI source is only partially open. The GitHub repo [CommandCodeAI/command-code](https://github.com/CommandCodeAI/command-code) is effectively a landing/readme repo (only `readme.md` + `.github`, ~3.4k stars); the [CommandCodeAI org](https://github.com/orgs/CommandCodeAI/repositories) also has an archived `cmd-old-public`. The actual shipped CLI source is published to npm as [`command-code`](https://www.npmjs.com/package/command-code) (current `0.40.0`) as a single bundled `dist/index.mjs` (~1.3 MB, minified but readable, includes the zod schemas and full `SessionManager` logic); `package.json` has no `repository`/`homepage` field. So the authoritative on-disk-format source is the npm bundle, not a browsable GitHub tree. Install: `npm i -g command-code`; bins: `cmd`, `cmdc`, `command-code`, `commandcode`. ([source](https://registry.npmjs.org/command-code/-/command-code-0.40.0.tgz))

---

## 16. Appendix: real anonymized samples

> Keys verbatim; message text, code, commands, paths, and secrets redacted. Structure preserved.

### 16a. `user` record (record + content-block layers)
```json
{
  "id": "d6d46e72-aa15-4049-8c26-84c15207258c",
  "timestamp": "2026-05-25T01:56:44.064Z",
  "sessionId": "400d4036-a1e4-4a22-b24a-9ebc7db0871c",
  "parentId": "410a7034-0a58-4085-8875-4f471fbde326",
  "role": "user",
  "gitBranch": "main",
  "metadata": { "timestamp": "2026-05-25T01:56:44.064Z", "source": "cli", "messageId": "685c1246-b555-4593-b068-4be3f4d72303", "version": 2 },
  "content": [ { "type": "text", "text": "<USER PROMPT REDACTED>" } ]
}
```

### 16b. `assistant` record with reasoning + text + tool-call
```json
{
  "id": "679dd8d8-...",
  "timestamp": "2026-05-25T01:56:51.228Z",
  "sessionId": "400d4036-a1e4-4a22-b24a-9ebc7db0871c",
  "parentId": "d6d46e72-aa15-4049-8c26-84c15207258c",
  "role": "assistant",
  "gitBranch": "main",
  "metadata": { "source": "cli", "version": 2, "timestamp": "2026-05-25T01:56:51.228Z" },
  "content": [
    { "type": "reasoning", "text": "<THINKING REDACTED>" },
    { "type": "text", "text": "<PROSE REDACTED>" },
    { "type": "tool-call", "toolName": "shell_command", "toolCallId": "call_00_MAKdS9FclHpX38eDWrpj6245", "input": { "command": "<CMD REDACTED>" } }
  ]
}
```

### 16c. `tool` record (tool-result, success)
```json
{
  "id": "<uuid>",
  "timestamp": "2026-05-25T01:56:52.110Z",
  "sessionId": "400d4036-a1e4-4a22-b24a-9ebc7db0871c",
  "parentId": "679dd8d8-...",
  "role": "tool",
  "gitBranch": "main",
  "metadata": { "source": "cli", "version": 2, "timestamp": "2026-05-25T01:56:52.110Z" },
  "content": [
    { "type": "tool-result", "toolName": "shell_command", "toolCallId": "call_00_MAKdS9FclHpX38eDWrpj6245", "output": { "type": "text", "value": "<OUTPUT REDACTED>" } }
  ]
}
```

### 16d. `tool` record (tool-result, error)
```json
{
  "id": "<uuid>", "timestamp": "<iso>", "sessionId": "<uuid>", "parentId": "<uuid>",
  "role": "tool", "gitBranch": "main",
  "metadata": { "source": "cli", "version": 2, "timestamp": "<iso>" },
  "content": [
    { "type": "tool-result", "toolName": "grep", "toolCallId": "call_00_...", "output": { "type": "error-text", "value": "<ERROR REDACTED>" } }
  ]
}
```

### 16e. `user` record with image
```json
{
  "id": "<uuid>", "timestamp": "<iso>", "sessionId": "<uuid>", "parentId": "<uuid>",
  "role": "user", "gitBranch": "main",
  "metadata": { "source": "cli", "version": 2, "timestamp": "<iso>" },
  "content": [ { "type": "image", "image": "data:image/jpeg;base64,<BASE64 REDACTED>" } ]
}
```

### 16f. `user` record with bare-string content (system injection)
```json
{
  "id": "<uuid>", "timestamp": "<iso>", "sessionId": "<uuid>", "parentId": "<uuid>",
  "role": "user", "gitBranch": "main",
  "metadata": { "source": "cli", "version": 2, "timestamp": "<iso>", "isAutomated": true },
  "content": "# AGENTS.md instructions for <PATH REDACTED>\n<INSTRUCTIONS> ... </INSTRUCTIONS>"
}
```

### 16g. headless one-shot pair (`entrypoint:"print"`)
The `user` record's `content` is a **bare string** (the one-shot prompt), NOT an empty array — verified across all 8 live `print` user records (lengths 5× ≈34 bytes + 3 long: 40,111 / 41,768 / 70,358 bytes); zero empty-array user-content records exist on disk.
```json
{ "id": "<uuid>", "timestamp": "<iso>", "sessionId": "<uuid>", "parentId": "<uuid>", "role": "user", "gitBranch": "-",
  "metadata": { "source": "cli", "version": 2, "timestamp": "<iso>", "entrypoint": "print" }, "content": "<ONE-SHOT PROMPT REDACTED>" }
{ "id": "<uuid>", "timestamp": "<iso>", "sessionId": "<uuid>", "parentId": "<uuid>", "role": "assistant", "gitBranch": "-",
  "metadata": { "source": "cli", "version": 2, "timestamp": "<iso>", "entrypoint": "print" },
  "content": [ { "type": "reasoning", "text": "<REDACTED>" }, { "type": "text", "text": "<REDACTED>" } ] }
```

### 16h. `.meta.json` sidecar (NOT read by Engram)
```json
{ "title": "Review recent commits with sub-agents", "model": "deepseek/deepseek-v4-pro" }
```
```json
{ "title": "<TITLE REDACTED>" }
```
Fork-session variant (written by `--fork-session` via `copyForkSessionFiles`; schema-confirmed, not observed in this store):
```json
{ "title": "<TITLE REDACTED>", "userRenamed": false, "model": "deepseek/deepseek-v4-pro", "parentSessionId": "<uuid>", "forkedAt": "<iso>", "branchPoint": "<branch-point>" }
```

### 16i. `.checkpoints.jsonl` record (NOT read by Engram)
```json
{
  "type": "file-history-snapshot",
  "isSnapshotUpdate": false,
  "messageId": "f7984133-...",
  "snapshot": {
    "messageId": "685c1246-...",
    "timestamp": "2026-05-25T01:56:44.065Z",
    "trackedFileBackups": { "<PATH REDACTED>": { "backupFileName": "<hash>-53@v1", "backupTime": "<ts>", "version": 1 } }
  }
}
```

### 16j. CLI-global `config.json` (NOT read by Engram)
```json
{ "provider": "command-code", "model": "deepseek/deepseek-v4-pro", "installed": true, "firstMessageSent": true, "reasoningEffort": { "deepseek/deepseek-v4-pro": "high" } }
```

### 16k. CLI-global `history.jsonl` line (NOT read by Engram)
```json
{ "p": "<PROMPT REDACTED>", "t": 1748137004064 }
```

### 16l. CLI-global `auth.json` (NOT read by Engram; keys only)
```json
{ "apiKey": "<REDACTED>", "userId": "<REDACTED>", "userName": "<REDACTED>", "keyName": "<REDACTED>", "authenticatedAt": "<REDACTED>" }
```

---

## References (official sources)

Web confirmation performed 2026-06-21 (`web_access_ok=true`). The npm bundle `dist/index.mjs` is the definitive on-disk-format source.

- [command-code npm package (v0.40.0) tarball](https://registry.npmjs.org/command-code/-/command-code-0.40.0.tgz) — shipped CLI bundle (`dist/index.mjs`) that reads/writes the session store; the definitive on-disk-format source (zod schemas + `SessionManager`).
- [command-code on npm](https://www.npmjs.com/package/command-code) — package page (install `npm i -g command-code`; bins `cmd`/`cmdc`/`command-code`/`commandcode`).
- [CommandCodeAI/command-code (GitHub)](https://github.com/CommandCodeAI/command-code) — official repo; landing/readme only (actual CLI source is published to npm).
- [CommandCodeAI org repositories](https://github.com/orgs/CommandCodeAI/repositories) — org repo list (includes archived `cmd-old-public`).
- [Command Code Docs — CLI Reference](https://commandcode.ai/docs/reference/cli) — confirms `--print`/`-p` headless one-shot mode.
- [Command Code official site](https://commandcode.ai/) — product landing.
