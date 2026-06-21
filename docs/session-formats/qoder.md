# Qoder Session Format

Last researched: 2026-06-21 (Engram session-format research workflow)

> **Evidence basis:** BOTH (1) **LIVE on-disk store** at `~/.qoder/projects/` —
> **7** project directories, **13** top-level session `.jsonl` files, **44**
> subagent `.jsonl` files (**57** `.jsonl` total, **5021** records), plus
> per-session `state.json` / `compression-v2/state.json` and subagent
> `*.meta.json` / `task-*.json` sidecars (**51** meta.json + **51** task-*.json
> vs **44** agent-*.jsonl transcripts); AND (2) repo fixtures
> `tests/fixtures/qoder/sample.jsonl` (4 records) and
> `tests/fixtures/adapter-parity/qoder/{input/.../qoder-session.jsonl,
> success.expected.json}` (golden parity output). Cross-checked against both
> adapters: Swift product `macos/Shared/EngramCore/Adapters/Sources/QoderAdapter.swift`
> (247 lines) and TS reference `src/adapters/qoder.ts` (283 lines).
>
> The record taxonomy (§4) is profiled over the **whole store** (57 files,
> 5021 records), not a single session — an earlier draft profiled only one
> 52-line session (`4789761a`), which happens to contain neither of the
> store-wide `token-stats` (215) nor `system` (103) record types.
>
> **No conflicts found** between live data and adapter behavior. Where they
> differ in *coverage*, the adapter reads a strict subset of what Qoder writes
> (flagged inline). All quoted samples are anonymized: message text / thinking /
> code / tool I/O / backup filenames / secrets / personal paths scrubbed, but
> **every key, type, and structure is verbatim** — format, not content.

Qoder is a **Claude-Code-JSONL-family** store. If you have read the Claude Code
session-format doc, the envelope and content-block model here will be familiar;
this document is nonetheless self-contained. See
[§15 Lineage](#15-lineage-gotchas-version-drift--edge-cases) for the precise
relationship and Qoder's deviations.

---

## 1. Overview & TL;DR

**What:** Qoder (an AI coding IDE/CLI) records each conversation as an
**append-only JSONL transcript** — one JSON object per line, UTF-8. The schema
is a near-clone of Anthropic Claude Code transcripts (same `type`/`message`/
content-block model, same `toolu_*`/`call_*` opaque per-backend tool IDs, same
Anthropic-shaped `usage`, same `~/.<tool>/projects/<encoded-cwd>/<uuid>.jsonl`
layout). Tool-use IDs are **backend-tagged and multi-backend** — `toolu_vrtx_*`
(Vertex/Google, the majority), `toolu_bdrk_*` (Bedrock), `call_*` /
`chatcmpl-tool-*` (OpenAI-compatible), and bare UUIDs — so the prefix reveals
which backend served a turn but the opaque `model` alias hides it (§5, §15).

**Where:** `~/.qoder/projects/<encoded-cwd>/<session-uuid>.jsonl`.

**How saved:** Each turn appends a line; the file is never rewritten in place.
Alongside each transcript Qoder maintains a **same-named sibling directory**
(`<session-uuid>/`, no extension) holding session state, a context-compression
cache, and dispatched-subagent artifacts. **No SQLite / leveldb / gRPC** — pure
file-per-session.

**Mental model:** main transcript = the conversation Engram parses; sibling dir
= Qoder's internal bookkeeping (state, compaction, subagents) that Engram mostly
ignores, except subagent `*.jsonl` transcripts which become child sessions.

**Evidence basis used:** live store (57 `.jsonl` files / 5021 records across 7
project dirs) + fixtures (5 `.jsonl` records total) + both adapters. Live data
wins on conflict. One conflict found and corrected against an earlier draft:
the taxonomy was profiled from a single session and missed two store-wide
record types (`token-stats`, `system`); the tool-ID prefix was claimed as
Bedrock-only but is actually multi-backend (Vertex-majority).

### ASCII layout / layering diagram

```
RECORD LAYER (one JSON object per line in the .jsonl)
  ┌──────────────────────────────────────────────────────────┐
  │ {type:"user"|"assistant", uuid, parentUuid, sessionId,    │  ← Engram parses
  │  timestamp, cwd, version, userType, entrypoint,           │     these two only
  │  isSidechain, isMeta?, promptId?, permissionMode?,        │
  │  sourceToolAssistantUUID?, toolUseResult?,                │
  │  message:{ ... } }                                        │
  ├──────────────────────────────────────────────────────────┤
  │ {type:"ai-title"|"last-prompt"|"file-history-snapshot"    │  ← Engram SKIPS
  │       |"token-stats"|"system"}                            │     (5 sidecar types)
  └──────────────────────────────────────────────────────────┘
        │ message
        ▼
  MESSAGE LAYER (Anthropic message object)
  ┌──────────────────────────────────────────────────────────┐
  │ {role, model?, id?, stop_reason?, stop_sequence?, usage?, │
  │  content: string | block[] }                             │
  └──────────────────────────────────────────────────────────┘
        │ content[]
        ▼
  CONTENT-BLOCK LAYER
  ┌──────────────────────────────────────────────────────────┐
  │ text · thinking · redacted_thinking · tool_use ·         │
  │ tool_result                                              │
  └──────────────────────────────────────────────────────────┘

ON-DISK LAYERING (per workspace)
  ~/.qoder/projects/<encoded-cwd>/
    ├── <uuid>.jsonl              ← MAIN transcript        (append-only) ✅ parsed
    └── <uuid>/                   ← sibling state dir      (same uuid, no ext)
        ├── state.json            ← session item/revision store (rewritten) ❌
        ├── compression-v2/state.json  ← compaction cache  (rewritten) ❌
        └── subagents/
            ├── agent-<id>.jsonl  ← SUBAGENT transcript    (append-only) ✅ child session
            ├── agent-<id>.meta.json  ← display metadata   (write-once) ❌
            └── task-<id>.json    ← dispatch/result record (rewritten) ❌
```

---

## 2. On-disk layout & file naming

| Property | Value | Source |
|---|---|---|
| On-disk root | `~/.qoder/projects/` | `QoderAdapter.swift:9-11`, `qoder.ts:22` |
| Storage tech | Append-only JSONL (one JSON object per line, UTF-8) | live store |
| Detect signal | root dir exists and is a directory | `QoderAdapter.swift:18-20`, `qoder.ts:25-32` |
| Product | Qoder IDE/CLI (`entrypoint:"cli"`, `userType:"external"`, Anthropic-shaped `usage`, multi-backend tool IDs `toolu_vrtx_*`/`toolu_bdrk_*`/`call_*`/`chatcmpl-tool-*`/bare-UUID) | live records |

### Directory structure

```
~/.qoder/projects/                                   # ROOT
└── <ENCODED_CWD>/                                   # one dir per workspace cwd
    ├── <SESSION_UUID>.jsonl                          # MAIN transcript (append-only)
    ├── <SESSION_UUID>/                               # sibling state dir (same UUID, no ext)
    │   ├── state.json                                # session item/revision state (rewritten)
    │   ├── compression-v2/
    │   │   └── state.json                            # context-compaction cache (rewritten)
    │   └── subagents/                                # dispatched sub-agent artifacts
    │       ├── agent-<AGENT_ID>.jsonl                # subagent transcript (append-only)
    │       ├── agent-<AGENT_ID>.meta.json            # subagent display metadata (write-once)
    │       └── task-<AGENT_ID>.json                  # subagent task record (rewritten)
    └── subagents/                                    # ALT location — see note below
```

### Naming grammar

| Element | Grammar | Real (anonymized) example |
|---|---|---|
| `<ENCODED_CWD>` | absolute cwd with every `/` → `-` (literal `-` preserved, **no collapsing**) | cwd `/Users/bing/-Code-/engram` → dir `-Users-bing--Code--engram`; cwd `/Users/bing/-Tools-` → `-Users-bing--Tools-` |
| `<SESSION_UUID>` | RFC-4122 v4 UUID | `4789761a-0873-4183-835c-1ff089b7dad2` |
| `<AGENT_ID>` | `<a><AgentType>-<16hex>` style id; `<AgentType>` ∈ {`general-purpose` (most common live), `Explore`, `Plan`, …} | `ageneral-purpose-646b2bc0030e4762`, `aExplore-604c32607f3e8031` |
| Subagent transcript | `agent-<AGENT_ID>.jsonl` | `agent-aExplore-604c32607f3e8031.jsonl` |
| Subagent meta | `agent-<AGENT_ID>.meta.json` | `agent-aExplore-604c32607f3e8031.meta.json` |
| Subagent task | `task-<AGENT_ID>.json` | `task-aExplore-604c32607f3e8031.json` |

> ⚠️ The decode `-`→`/` is **lossy** — it cannot distinguish an original `-` in
> the path from a path separator. Engram never decodes the directory name; it
> reads `cwd` from inside each record instead (`QoderAdapter.swift:67-69`).

> The bottom `subagents/` (directly under the project dir, not under a
> `<uuid>/`) is an **alternate placement** both adapters scan
> (`QoderAdapter.swift:34`, `qoder.ts:50`). Only the `<uuid>/subagents/` form
> was observed live on this machine; the project-dir-level scan path is
> unconfirmed against real data.

> ⚠️ **Official-doc layout differs: a `transcript/` subdirectory.** The Engram
> layout above (main transcript directly under the project dir, no intermediate
> subdir) matches the live store on this machine. But the official
> [Qoder Hooks doc](https://docs.qoder.com/extensions/hooks) gives the
> `transcript_path` example as
> `~/.qoder/projects/<project>/transcript/<session-id>.jsonl` — i.e. with an
> intermediate `transcript/` subdir. This is likely a docs simplification or a
> CLI/version difference (the live files appear to be qoder-cli sessions). Treat
> the live store as authoritative for the version Engram parses, but note the
> adapter's path-derived parent logic (§10) could break under the documented
> `transcript/` layout.

### Tree example (live, engram workspace — anonymized)

```
~/.qoder/projects/-Users-bing--Code--engram/
├── 4789761a-0873-4183-835c-1ff089b7dad2.jsonl        (52 lines, ~310 KB)
├── 4789761a-0873-4183-835c-1ff089b7dad2/
│   ├── state.json
│   ├── compression-v2/state.json
│   └── subagents/
│       ├── agent-aExplore-604c32607f3e8031.jsonl
│       ├── agent-aExplore-604c32607f3e8031.meta.json
│       ├── task-aExplore-604c32607f3e8031.json
│       ├── agent-aExplore-99f9d2df5bfceba4.jsonl
│       ├── ... (subagent transcripts; NOT 1:1 with task specs — see note)
├── 7e6d3cb3-6200-49f1-b4b7-0b5e8fa32032.jsonl        (5 lines, 2575 B — user-only)
└── 7e6d3cb3-6200-49f1-b4b7-0b5e8fa32032/
    └── state.json
```

> ⚠️ **Sidecars outnumber transcripts — a task spec is NOT guaranteed a child
> session.** Live store: **51** `task-*.json` + **51** `*.meta.json` but only
> **44** `agent-*.jsonl` transcripts. Dispatched tasks with status
> `failed` (11) or `cancelled` (4) — and not all `completed` (36) — can leave a
> `task-*.json` + `meta.json` with **no** `agent-*.jsonl`. So 7 dispatched
> subagents have a dispatch record but no transcript, and Engram ingests only
> the 44 that do have a transcript. The §2 tree's "each + .meta.json +
> task-*.json" is the common case, not an invariant.

---

## 3. File lifecycle & generation

- **Storage tech:** pure file-per-session JSONL. No database. Engram derives
  counts / start / end by streaming the file, not querying a DB.
- **Append vs rewrite:** the two **transcript** kinds (`<uuid>.jsonl`,
  `agent-<id>.jsonl`) are **append-only** — each turn adds a line; nothing is
  rewritten in place. The **JSON sidecars** (`state.json`,
  `compression-v2/state.json`, `task-*.json`) are **whole-file rewrites**
  (revision counter / status transitions). `meta.json` is written once.
- **Resume:** appending to the same `<uuid>.jsonl` resumes a session; the
  `last-prompt` record caches the resume prompt and `state.json.revision`
  increments. The session id is stable (the filename UUID), so Engram re-reads
  the grown file and recomputes `endTime` from the last `timestamp`.
- **Rollover:** none observed — one UUID = one file for the session's life;
  new conversations get a new UUID, not a rolled file.
- **Archive:** none — old sessions persist in place. `file-history-snapshot`
  records provide per-message file-edit undo state, but Qoder does not
  move/compress old transcripts.
- **mtime ordering** within a session (observed live):
  `compression-v2/state.json` → `state.json` → main `<uuid>.jsonl`, i.e. the
  transcript is flushed last.
- **Ephemeral output outside `~/.qoder`:** subagent `task-*.json.outputPath`
  and `toolUseResult.outputPath` point at `/private/tmp/qoder-cli-<uid>/<encoded-cwd>/<uuid>/tasks/<id>.output`.
  This temp area was not inspected (outside scope); it may hold additional
  ephemeral output Engram does not capture.

---

## 4. Record / line taxonomy (top-level JSONL objects)

Records are discriminated by the top-level `type` field. **SEVEN** types observed
across the **whole live store** (57 files, 5021 records — NOT a single session;
an earlier draft profiled only session `4789761a`, which by chance contains
neither `token-stats` nor `system`):

| `type` | count (whole store, 57 files) | Parsed by Engram? | Meaning |
|---|---|---|---|
| `assistant` | 2923 | ✅ (→ `assistant`) | model turn (text / thinking / tool_use blocks) |
| `user` | 1714 | ✅ (→ `user` or `tool` role) | user turn **or** a `tool_result` feedback turn |
| `token-stats` | 215 | ❌ skipped | periodic prompt-token-count checkpoint; EPOCH-MS timestamp (§2 sample below); a second token-accounting surface besides `message.usage` |
| `system` | 103 | ❌ skipped | agent/task lifecycle + error events (`subtype`/`level`/`task_type` envelope; subagent-dispatch signal) |
| `last-prompt` | 37 | ❌ skipped | snapshot of the last user prompt text (resume context) |
| `file-history-snapshot` | 21 | ❌ skipped | file-backup checkpoint tied to a message (undo/restore) |
| `ai-title` | 8 | ❌ skipped | AI-generated session title sidecar record |

For comparison, session `4789761a` **alone** = user 19 / assistant 30 /
ai-title 1 / last-prompt 1 / file-history-snapshot 1 (52 lines, no
token-stats/system) — which is why a single-session profile undercounted the
taxonomy.

> ⚠️ **This seven-type taxonomy is a per-store profile, NOT the full Qoder
> record universe.** The official
> [Qoder Hooks doc](https://docs.qoder.com/extensions/hooks) documents two more
> top-level record types absent from this live store (dominated by qoder-cli
> 0.2.x–1.0.x files): **`session_meta`** (with `data.content.mode ∈ {agent,
> plan, ask, debug}` and `data.content.session_type ∈ {assistant, inline_chat,
> …}`) and **`progress`**. Newer / IDE-launched sessions may emit
> `session_meta` and `progress` records, so the seven types above are accurate
> for the observed data but not exhaustive for Qoder overall. The adapters'
> `type ∈ {user, assistant}` filter would skip these too.

The adapters parse **only** `type ∈ {user, assistant}` (`QoderAdapter.swift:57-59,154-156`;
`qoder.ts:76,142`); the **five** sidecar record types are ignored entirely. The
parity fixtures contain only `user`/`assistant` records, so the five sidecar
types appear **only in live data**.

> ⚠️ **Adapter blind spot:** `ai-title` carries a curated human-readable title
> and `last-prompt` carries resume context, but neither adapter reads them. The
> loop `continue`s on any `type` other than `user`/`assistant`, so Engram falls
> back to a first-user-message slice for its summary, **ignoring Qoder's own
> AI-generated title**. Open question: intentional, or a gap?

> ⚠️ **`systemMessageCount` does NOT count `type:system` records.**
> `systemMessageCount` is a **user-text heuristic** (§14) keyed on
> `# AGENTS.md instructions for ` / `<INSTRUCTIONS>`; it fired **0 times** on
> the real store, while the **103 genuine `type:system` records** are dropped
> uncounted by the `type ∈ {user, assistant}` filter. A reader must not assume
> system-type records feed `systemMessageCount` — they don't; for real Qoder
> data `systemMessageCount` is effectively always 0 (§5, §14, §15).

---

## 5. Shared envelope / metadata fields

Fields on `user` / `assistant` records.

| Field | Type | Meaning | Optional | Consumed | Example |
|---|---|---|---|---|---|
| `type` | string | record discriminator (`"user"`/`"assistant"`) | no | ✅ filter | `"assistant"` |
| `uuid` | string | this record's unique id (or synthetic `user:<sid>########N`) | no | ❌ | `"5d3726e1-9e40-4bd8-a96d-3d9507a8ce01"` |
| `parentUuid` | string \| null | prior record in the DAG; `null` on first; assistant may use synthetic `user:<sid>########<n>` | no (null on root) | ❌ | `"a8d327a1-e562-4509-b8d5-701179a51be5"` |
| `timestamp` | string (ISO-8601 UTC `…Z`) | record time → start (first) / end (last) | no | ✅ | `"2026-05-25T05:28:12.644Z"` |
| `sessionId` | string (UUID) | session id (matches filename; stays the **parent's** UUID even inside subagent files) | no | ✅ | `"4789761a-0873-4183-835c-1ff089b7dad2"` |
| `cwd` | string (abs path) | working directory | no | ✅ | `/Users/bing/-Code-/engram` |
| `version` | string | Qoder client/schema version (NOT a model id) | no | ❌ | `1.0.13`, `1.0.10`, `1.0.4`, `0.2.13`, `0.2.7` |
| `userType` | string | account type; live: always `"external"` | no | ❌ | `"external"` |
| `entrypoint` | string | launch surface; live: always `"cli"` | no | ❌ | `"cli"` |
| `isSidechain` | bool | `true` on subagent records; `false` on main | no | ❌ (Engram uses path, not this flag) | `false` |
| `isMeta` | bool \| null/absent | flags an injected/meta user turn (e.g. first record) | yes (user only) | ❌ | `true` |
| `promptId` | string (UUID) | groups records belonging to one user prompt/turn | yes | ❌ | `"9339cc26-4a75-4ee9-90ca-ebd752e56a98"` |
| `permissionMode` | string | permission policy for the turn | yes (user only) | ❌ | `default`, `auto`, `acceptEdits`, `bypassPermissions` |
| `sourceToolAssistantUUID` | string | on `tool_result` user records: `uuid` of the assistant that issued the `tool_use` (envelope-level call↔result link) | yes (tool turns) | ❌ | `"a8d327a1-e562-4509-b8d5-701179a51be5"` |
| `toolUseResult` | object | structured tool-specific result payload (see §7) | yes (tool turns) | ❌ | — |
| `message` | object | content envelope (see §6) | no | ✅ | — |

**Subagent-only extra envelope keys** (present in `agent-*.jsonl`, absent in
top-level files):

| Field | Type | Meaning | Consumed | Example |
|---|---|---|---|---|
| `agentId` | string | subagent's own id → **Engram id for subagents** | ✅ (when path contains `/subagents/`) | `"aExplore-604c32607f3e8031"` |
| `parent_tool_use_id` | string | links the subagent turn to the dispatching `tool_use` (any backend prefix: `toolu_vrtx_*`/`toolu_bdrk_*`/`call_*`/…) | ❌ | `"toolu_vrtx_01PW3LBksPmMHrjTtH9qL4Fh"` |
| `session_id` | string | **snake_case duplicate** of `sessionId` (the parent UUID), present on assistant subagent records alongside camelCase `sessionId` | ❌ | `"4789761a-0873-4183-835c-1ff089b7dad2"` |

> On subagent records `isSidechain` is `true`, and `sessionId`/`session_id` both
> hold the **parent** UUID — the subagent's own id lives only in `agentId`.

---

## 6. Message & content schema

The `message` field is an Anthropic-style message object whose shape varies by
role.

### 6a. user `message`

| Field | Type | Meaning | Example |
|---|---|---|---|
| `role` | string | always `"user"` | `"user"` |
| `content` | string \| array | plain prompt (string) **or** array of `tool_result` blocks | `"<prompt text>"` / `[{tool_result…}]` |

Engram classifies a `user` record as **`tool` role** iff `content` is an array
containing a `tool_result` block, otherwise **`user`**
(`QoderAdapter.swift:159,173-178`; `qoder.ts:150-155,197-202`). It also
reclassifies user prompts that start with `"# AGENTS.md instructions for "` or
contain `"<INSTRUCTIONS>"` as **system injections** excluded from
`userMessageCount` (`QoderAdapter.swift:169-171`; `qoder.ts:190-194`).

### 6b. assistant `message` (Anthropic message object)

| Field | Type | Meaning | Optional | Example |
|---|---|---|---|---|
| `id` | string | provider message id | no | `"ae6e4cd3-3e73-4757-acd7-7b43e670d196"` |
| `type` | string | always `"message"` | no | `"message"` |
| `role` | string | always `"assistant"` | no | `"assistant"` |
| `model` | string | Qoder model **alias**, not a real model id | no | `ultimate`, `efficient`, `auto`, `<synthetic>`, `""` |
| `stop_reason` | string \| null | `"tool_use"`, `"end_turn"`, or null (streaming/interim) | no | `"tool_use"` |
| `stop_sequence` | string \| null | matched stop sequence | no | `null` |
| `content` | array | content blocks (see §6c) | no | — |
| `usage` | object | token accounting; present on a **minority** of assistant records (final segment of a turn — 9 of 30 in the sampled session) | yes | — |

### 6c. Content blocks (inside `message.content[]`)

| block `type` | Fields | Meaning | Adapter handling |
|---|---|---|---|
| `text` | `type`, `text` (string), `citations` (null in all samples) | assistant prose | appended to content |
| `thinking` | `type`, `thinking` (string), `signature` (string) | extended reasoning | **fallback only** — emitted as content iff the block has no `text`/`tool_use`/`tool_result` parts (`QoderAdapter.swift:191-193`, `205`) |
| `redacted_thinking` | `type`, `data` (opaque encrypted blob) | server-side-redacted reasoning | **ignored** (extractContent handles only text/thinking/tool_use/tool_result) |
| `tool_use` | `type`, `id` (backend-tagged: `toolu_vrtx_*` majority / `toolu_bdrk_*` / `call_*` / `chatcmpl-tool-*` / bare-UUID), `name`, `input` (object) | tool invocation | rendered as `` `name` `` in text; emitted as `NormalizedToolCall{name, input}` (`:194,208-221`) |
| `tool_result` | `type`, `tool_use_id`, `content` (string \| array), `is_error` (bool) | tool output fed back (lives on **user** records) | content extracted; presence → `tool` role |

Live content-block distribution across all 57 files: `tool_use` 1586,
`tool_result` 1586, `thinking` 524, `text` 463, `redacted_thinking` 358.

**`tool_use.id` is backend-tagged and multi-backend** (prefix census over all
assistant `tool_use` block ids, 57 files): `toolu_vrtx_*` **748** (majority,
Vertex/Google), `call_*` **492** (OpenAI-compatible), `toolu_bdrk_*` **237**
(Bedrock), bare UUID **48**, `chatcmpl-tool-*` ~**60** (OpenAI-compatible). So
Qoder routes turns to **multiple backends** (Vertex / Bedrock /
OpenAI-compatible), not just Bedrock; the prefix is the only backend signal —
the `model` alias hides it (§15).

Observed `tool_use.input` key shapes (tool → input keys, live):
`Bash:[command,description(,timeout)]`, `Read:[file_path]`,
`Write:[content,file_path]`, `Edit:[file_path,instruction,new_string,old_string]`,
`Glob:[pattern]` / `[path,pattern]`, `Grep:[pattern,output_mode,…flags]`,
`TodoWrite:[todos]`, `Agent:[description,prompt,subagent_type(,isolation)]`,
`AskUserQuestion:[questions]`, `CreateGoal:[objective]`, `GetGoal:[]`,
`EnterPlanMode:[reason]`.

#### Examples (anonymized — keys verbatim, values scrubbed)

```jsonc
// type=user, tool_result turn — envelope + nested tool_result block
{
  "type": "user",
  "uuid": "1b20e8de-e656-4966-9e02-8055d6fc497a",
  "timestamp": "2026-05-25T05:28:13.601Z",
  "message": {
    "role": "user",
    "content": [
      { "type": "tool_result",
        "tool_use_id": "toolu_vrtx_013V8oMB2WQkkJnJ8jqvh2Wo",
        "content": "REDACTED",
        "is_error": false }
    ]
  },
  "sourceToolAssistantUUID": "a8d327a1-e562-4509-b8d5-701179a51be5",
  "promptId": "9339cc26-4a75-4ee9-90ca-ebd752e56a98",
  "toolUseResult": "REDACTED_OBJ",
  "parentUuid": "a8d327a1-e562-4509-b8d5-701179a51be5",
  "isSidechain": false,
  "cwd": "/Users/bing/-Code-/engram",
  "sessionId": "4789761a-0873-4183-835c-1ff089b7dad2",
  "userType": "external",
  "entrypoint": "cli",
  "version": "1.0.4"
}
```

```jsonc
// content-block variants — one of each (anonymized)
{ "type": "text", "text": "REDACTED", "citations": null }
{ "type": "thinking", "thinking": "REDACTED", "signature": "REDACTED_SIG" }
{ "type": "redacted_thinking", "data": "REDACTED_DATA" }
{ "type": "tool_use", "id": "toolu_vrtx_01H3k5cF1KYMiTKqJM3fvZaV", "name": "Glob", "input": {"pattern":"REDACTED"} }   // Vertex (majority)
{ "type": "tool_use", "id": "call_6d5190e9b79e4996801d6c", "name": "Read", "input": {"file_path":"REDACTED"} }       // OpenAI-compatible
{ "type": "tool_result", "tool_use_id": "toolu_bdrk_013V8oMB2WQkkJnJ8jqvh2Wo", "content": "REDACTED", "is_error": false }  // Bedrock
```

---

## 7. Tool calls & results

Two parallel call↔result linkage mechanisms — both verified, IDs match 1:1:

1. **Content-block level (canonical):** assistant `tool_use.id` (any backend
   prefix — `toolu_vrtx_…`/`toolu_bdrk_…`/`call_…`/`chatcmpl-tool-…`/bare-UUID)
   == the following user `tool_result.tool_use_id`.
2. **Envelope level:** the `tool_result` user record's `parentUuid` and
   `sourceToolAssistantUUID` both equal the issuing **assistant record's
   `uuid`** (`parentUuid == sourceToolAssistantUUID` in all samples).

**Engram exposes only the call side.** `NormalizedToolCall{name, input}` is
emitted with `output: nil` (`QoderAdapter.swift:215-219`; `qoder.ts:242-248`);
the adapter does **not** stitch results back onto the call object — results
surface as separate `tool`-role messages. `input` is JSON-encoded and truncated
(Swift 500 chars, TS 500 chars). Errors are carried by
`tool_result.is_error` (bool), which Engram does not read.

### `toolUseResult` (polymorphic structured result, envelope-level — NOT parsed)

Present on `tool_result` user records; shape varies by tool. Variants observed
live (counts across all 57 files):

| Variant | Discriminating keys | Count | Notes |
|---|---|---|---|
| **Agent/Task** | `kind:"agent-result"`, `agentId`, `agentType`, `content`, `state`, `terminateReason`, `outputPath`, `transcriptPath` | 47 | links to subagent JSONL via `transcriptPath` |
| **Glob/Grep-like** | `durationMs`, `filenames[]`, `numFiles`, `truncated` | 172 | |
| **Read** | `content`, `filenames`, `mode`, `numFiles`, `numLines` (`type:"text"`, `file:{…}` in older shape) | 114 | |
| **Edit/Write** | `type`(`create`/`update`), `content`, `filePath`, `originalFile`, `structuredPatch[]` | 32 | patch elements `{oldStart,oldLines,newStart,newLines,lines[]}` |
| **with limits** | `appliedLimit`, `content`, `filenames`, `mode`, `numFiles`, `numLines` | 8 | |
| **AskUserQuestion** | `answers`, `questions` | 2 | |
| **Bash (bg)** | `backgroundReason`, `command`, `initialOutput`, `pid`, `totalBytes`, `totalLines` | 1 | |
| **WebFetch** | `bytes`, `code`, `codeText`, `durationMs`, `result`, `url` | 1 | |
| **error** | `errorType` | 9 | |
| **Bash (fg)** | `stdout`, `stderr`, `interrupted`, `isImage`, `noOutputExpected` | — | (per dimension reports) |
| **TodoWrite** | `oldTodos[]`, `newTodos[]` (each `{description,status}`) | — | (per dimension reports) |

```jsonc
// toolUseResult — Agent/Task variant (anonymized)
{ "kind": "agent-result", "agentId": "aExplore-c6740a171e935c6d", "agentType": "Explore",
  "content": "REDACTED", "state": "completed", "terminateReason": "GOAL",
  "outputPath": "/private/tmp/qoder-cli-501/-Users-bing--Code--engram/4789761a-…/tasks/aExplore-c6740a171e935c6d.output",
  "transcriptPath": "/Users/bing/.qoder/projects/-Users-bing--Code--engram/4789761a-…/subagents/agent-aExplore-c6740a171e935c6d.jsonl" }
```

The adapter ignores `toolUseResult` entirely for content — it reads
`tool_result.content` / `.output` from the **content block**, not this
envelope field.

---

## 8. Reasoning / thinking

Stored as content blocks (§6c):

- **`thinking`** = `{type, thinking, signature}` — extended reasoning. Engram
  uses it as **fallback only**: `extractContent` emits the thinking text iff the
  block array yields no `text`/`tool_use`/`tool_result` parts
  (`QoderAdapter.swift:184,191-193,205`; `qoder.ts:208,213-218,231`). So in
  most turns reasoning is **not** indexed.
- **`redacted_thinking`** = `{type, data}` — server-side-redacted reasoning
  (opaque blob). **Never extracted** by either adapter. 358 such blocks exist in
  the live store — invisible to Engram.

---

## 9. Token usage & cost

Anthropic-shaped `usage` object on assistant `message`s. Present on a minority of
assistant records (the final segment of a streamed turn — 9 of 30 in the sampled
session; **store-wide 256 of 2923 assistant records, ~9%**).

| Raw field | Type | Meaning | Engram mapping |
|---|---|---|---|
| `input_tokens` | int | prompt tokens | → `inputTokens` |
| `output_tokens` | int | completion tokens | → `outputTokens` |
| `cache_read_input_tokens` | int | tokens served from prompt cache | → `cacheReadTokens` |
| `cache_creation_input_tokens` | int | tokens written to cache | → `cacheCreationTokens` |
| `cache_creation` | object | `{ephemeral_1h_input_tokens, ephemeral_5m_input_tokens}` | **dropped** |
| `server_tool_use` | object | `{web_search_requests, web_fetch_requests}` | **dropped** |
| `service_tier` | string | `"standard"` (only value seen) | **dropped** |
| `speed` | string | `"standard"` (only value seen) | **dropped** |
| `inference_geo` | string | inference region (empty in all samples) | **dropped** |
| `iterations` | array | per-iteration breakdown (empty in all samples) | **dropped** |
| `request_id` | string | provider request id (== `message.id` here) | **dropped** |

Mapping: `qoder.ts:252-263`; Swift via shared `JSONLAdapterSupport.usage(from:)`
(`QoderAdapter.swift:165` → defined at `CodexAdapter.swift:220`, the shared
`JSONLAdapterSupport` enum). The parity fixture confirms the exact 4-field
mapping (`usageTotals: {inputTokens:12, outputTokens:8, cacheReadTokens:3,
cacheCreationTokens:2}`).

> **No per-turn dollar cost is stored** — only token counts. And see §15 gotcha:
> `model` is a Qoder marketing alias, not a real provider model id, so cost
> attribution by model is unreliable.

```json
{"input_tokens":18867,"cache_creation_input_tokens":0,"cache_read_input_tokens":13628,
 "output_tokens":469,"server_tool_use":{"web_search_requests":0,"web_fetch_requests":0},
 "service_tier":"standard","cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":0},
 "inference_geo":"","iterations":[],"speed":"standard","request_id":"..."}
```

---

## 10. Subagent / parent-child / dispatch

Qoder dispatches sub-agents whose transcripts live under
`<uuid>/subagents/agent-<id>.jsonl`. Engram ingests these as **child sessions**.
`agentType` is **{`general-purpose` (most common — 35 of 51 task specs),
`Explore` (14), `Plan` (2)}**, not just `Explore`; agent-file prefixes are
`ageneral-purpose` (29), `aExplore` (14), `aPlan` (1).

> ⚠️ **An alternate, field-based dispatch signal lives in the MAIN transcript
> and Engram ignores it.** `type:system` records with
> `subtype ∈ {task_started, task_progress}` (8 + 72 occurrences) carry
> `task_id` / `tool_use_id` / `task_type:"local_agent"` / `description` /
> `prompt` — an explicit subagent-dispatch record in the parent's own JSONL
> (the in-transcript counterpart to the `task-*.json` sidecar). Engram derives
> the parent link from the **directory path** instead and drops these `system`
> records entirely (§3, §14).

**Discovery** (`listSessionLocators()` Swift `QoderAdapter.swift:22-37` /
`listSessionFiles()` TS `qoder.ts:34-55`):

1. Iterate direct children of `~/.qoder/projects/` that are directories (each = a
   project).
2. Within each project dir: `*.jsonl` → emit as a **top-level session locator**;
   a sub-directory → recurse into its `subagents/` and emit each
   `agent-*.jsonl`.
3. Also scan the project dir's own `subagents/` folder (the alternate placement,
   §2). Swift sorts the final list; TS yields lazily.

**Subagent identity & linkage:**

| Aspect | How | file:line |
|---|---|---|
| `id` (subagent) | if locator contains `/subagents/` AND `agentId` present → use `agentId`, else `sessionId` | `QoderAdapter.swift:98-99`; `qoder.ts:102-103` |
| `agentRole` | `"subagent"` if path contains `/subagents/`, else `nil` | `QoderAdapter.swift:98,119`; `qoder.ts:102,119` |
| `parentSessionId` | **path-derived** — from locator path relative to root, take the component immediately **before** `subagents` (depth ≥ 2): `…/<uuid>/subagents/agent-<id>.jsonl` → parent `<uuid>` | `QoderAdapter.swift:125,228-237`; `qoder.ts:120-122,265-270` |

> The parent link is **path-derived, not field-derived**. The authoritative
> `task-*.json` carries an explicit `parentToolUseId`/`sessionId`, but Engram
> ignores it and re-derives the parent from the directory name. Both agree in
> live data; a renamed parent dir would silently produce a wrong/dangling
> parent id.

**Not the Gemini `.engram.json` sidecar mechanism.** Qoder's parent-child
linkage is path-based (directory layout), unlike Gemini CLI which writes a
`{sessionId}.engram.json` sidecar.

---

## 11. Summary / compaction

- **Engram-side summary:** N/A as a stored field — Engram derives `summary` from
  the first non-system user message text (`prefix(200)`), **not** from Qoder's
  own `ai-title` record (§4, §15).
- **Qoder-side compaction (not parsed):** `<uuid>/compression-v2/state.json`
  holds context-window compaction bookkeeping:
  `{version:int, state:{replacementDecisions, seenFunctionResponseIds,
  sessionMemoryState, autoCompactTracking, snippedMessageIds}}`. Engram ignores
  it. There is no in-transcript "compact summary" record like some tools emit;
  compaction is tracked out-of-band in this sidecar.
  **Note the v2-dir / v1-field mismatch:** the directory is named
  `compression-v2`, but the file's internal `version` field is **`1`** in all 7
  live files — `version` here is the state-schema version, not the dir version.

---

## 12. SQLite / DB internals

**N/A for Qoder.** Qoder uses no database — it is pure file-per-session JSONL
plus JSON sidecars. No `.vscdb`, leveldb, or SQLite of any kind.

---

## 13. Auxiliary files

All JSON sidecars below are **ignored by Engram** (it reads only `.jsonl`,
`QoderAdapter.swift:28`, `qoder.ts:44`).

| File | Keys | Write model | Purpose |
|---|---|---|---|
| `<uuid>/state.json` | `sessionId, revision(int), createdAt, updatedAt, workspaceDirectories[], data{}, items{}` | rewritten (revision bump) | session metadata + **encrypted** item store |
| `<uuid>/compression-v2/state.json` | `version(int — **=1** in all 7 live files, despite the `v2` dir name), state{replacementDecisions, seenFunctionResponseIds, sessionMemoryState, autoCompactTracking, snippedMessageIds}` | rewritten | context-window compaction cache |
| `subagents/agent-<id>.meta.json` | `agentType, displayName, description, color` | write-once | subagent display metadata |
| `subagents/task-<id>.json` | `taskId, sessionId, executionId(num), agentId, agentType, description, parentToolUseId, outputPath, transcriptPath, completionBehavior, status (∈ {completed:36, failed:11, cancelled:4} live), summary, createdAt(epoch-ms), updatedAt(epoch-ms), result, completedAt(epoch-ms)` | rewritten (status transitions) | subagent dispatch + result record |

**`state.json.items{}`** is an encrypted key-value store: each item carries the
five keys `{c, n, p, t, u}` = created/nonce/payload/tag/updated (AES-style;
`n`=nonce, `p`=payload, `t`=tag, all base64). **Not human-readable; not
recoverable without the Qoder key.** `state.json.revision` is a monotonically
increasing int (observed up to **83** live) — §16's `revision:42` is an
illustrative value, not a fixed one.

**`task-*.json` timestamps are epoch-ms ints** (e.g. `createdAt:1779686940809`),
unlike the ISO-8601 strings in the JSONL transcripts. `task.transcriptPath`
points back at the `agent-*.jsonl` Engram parses; `task.outputPath` references a
separate temp area under `/private/tmp/qoder-cli-<uid>/…`.

---

## 14. Engram mapping

Engram reads only records where top-level `type ∈ {user, assistant}`; all other
records are skipped (`QoderAdapter.swift:57-59`; `qoder.ts:76`).

### Session-info mapping

| Engram Session field | Source (Qoder JSONL) | How derived | file:line (Swift / TS) |
|---|---|---|---|
| `id` (top session) | record `.sessionId` (first non-empty) | first user/assistant record | `QoderAdapter.swift:61-63,99` / `qoder.ts:78,103` |
| `id` (subagent) | record `.agentId` | if path contains `/subagents/` AND `agentId` present → `agentId`, else `sessionId` | `QoderAdapter.swift:98-99` / `qoder.ts:102-103` |
| `source` | constant | `.qoder` | `QoderAdapter.swift:4,104` / `qoder.ts:18,106` |
| `summary` | first user `message.content` text | `extractContent()` of first non-system user msg, `prefix(200)` | `QoderAdapter.swift:92,115` / `qoder.ts:96,116` |
| `cwd` | record `.cwd` (first non-empty) | first user/assistant record | `QoderAdapter.swift:67-69,108` / `qoder.ts:80,109` |
| `project` | — | **always `nil`** (derived from cwd downstream) | `QoderAdapter.swift:108` / `qoder.ts` (omitted) |
| `startTime` | record `.timestamp` (first) | first user/assistant record | `QoderAdapter.swift:70-72,105` / `qoder.ts:81,107` |
| `endTime` | record `.timestamp` (last) | last user/assistant record; **`nil` if equal to startTime** | `QoderAdapter.swift:73-75,106` / `qoder.ts:82,108` |
| `model` | `message.model` (first non-null) | first assistant message carrying `model` | `QoderAdapter.swift:78-80,109` / `qoder.ts:85,110` |
| `messageCount` | derived | `userCount + assistantCount + toolCount` | `QoderAdapter.swift:110` / `qoder.ts:111` |
| `userMessageCount` | type=`user`, content NOT tool_result, NOT system-injection | counter | `QoderAdapter.swift:90-92,111` / `qoder.ts:94-96,113` |
| `assistantMessageCount` | type=`assistant` | counter | `QoderAdapter.swift:82-83,112` / `qoder.ts:87-88,114` |
| `toolMessageCount` | type=`user` whose `content[]` contains a `tool_result` block | counter | `QoderAdapter.swift:84-85,113` / `qoder.ts:89,115` |
| `systemMessageCount` | type=`user` text starting `# AGENTS.md instructions for ` OR containing `<INSTRUCTIONS>` | counter | `QoderAdapter.swift:88-89,114` / `qoder.ts:93,116` |
| `filePath` | locator (absolute path) | passthrough | `QoderAdapter.swift:116` / `qoder.ts:117` |
| `sizeBytes` | file `st_size` | stat | `QoderAdapter.swift:117` / `qoder.ts:118` |
| `agentRole` | path test | `"subagent"` if path contains `/subagents/`, else `nil` | `QoderAdapter.swift:98,119` / `qoder.ts:102,119` |
| `parentSessionId` | **path-derived** (NOT a field) | `parts[subagentsIndex-1]` (parent session dir name) | `QoderAdapter.swift:125,228-237` / `qoder.ts:120-122,265-270` |
| `suggestedParentId` | — | always `nil` (Layer-2 heuristic runs later) | `QoderAdapter.swift:126` |

### Per-message stream mapping (`streamMessages`)

| Engram message field | Source | How | file:line (Swift / TS) |
|---|---|---|---|
| `role` | `type` + content shape | `assistant`→assistant; `user`+tool_result→`tool`; else `user` | `QoderAdapter.swift:159` / `qoder.ts:150-155` |
| `content` | `message.content` | `extractContent()`: string passthrough; array → join `text` blocks, `` `toolName` `` for tool_use, tool_result content/output, `thinking` as fallback | `QoderAdapter.swift:180-206` / `qoder.ts:204-232` |
| `timestamp` | record `.timestamp` | passthrough | `QoderAdapter.swift:163` / `qoder.ts:159` |
| `toolCalls[]` | `message.content[]` type=`tool_use` | `{name, input}` (input JSON ≤500 chars), `output:nil` | `QoderAdapter.swift:208-226` / `qoder.ts:234-250` |
| `usage` | `message.usage` | shared `JSONLAdapterSupport.usage(from:)` — 4 token fields | `QoderAdapter.swift:165` (→ `CodexAdapter.swift:220`) / `qoder.ts:161,252-263` |

### What Engram does NOT consume

1. **5 entire record types** (the `type ∈ {user, assistant}` filter drops all):
   `ai-title` (8 — server-generated title!), `last-prompt` (37 — resume prompt),
   `file-history-snapshot` (21 — file-edit undo state), `token-stats` (215 —
   second token-accounting surface, epoch-ms), `system` (103 — agent/task
   lifecycle + errors; see item 11).
2. **DAG threading:** `parentUuid`, `promptId`, `sourceToolAssistantUUID` —
   Engram flattens to a linear list, losing the message tree.
3. **`toolUseResult`** structured metadata (durations, file lists,
   stdout/stderr separation, truncation flags, `terminateReason`).
4. **`is_error`** on `tool_result` — error state is lost.
5. **`isSidechain`** flag — subagents detected purely by path; a subagent file
   moved out of `subagents/` would be misclassified despite `isSidechain:true`.
6. **All subagent sidecars** (`*.meta.json`, `task-*.json`) including the
   authoritative `parentToolUseId`/`result`/`summary`/`status`.
7. **Usage extras:** `server_tool_use`, `service_tier`, `speed`, nested
   `cache_creation`, `request_id`, `iterations`, `inference_geo`.
8. **Provenance fields:** `version`, `entrypoint`, `userType`, `permissionMode`.
9. **`redacted_thinking`** content blocks; `thinking` only as fallback;
   `citations`.
10. **State sidecars:** `state.json`, `compression-v2/state.json`.
11. **The 103 `type:system` records** (agent/task lifecycle + errors) — dropped
    by the `type ∈ {user, assistant}` filter, **NOT** counted toward
    `systemMessageCount`. `systemMessageCount` is instead a user-text heuristic
    (next paragraph) that matched **0** records on the real store.
12. **`token-stats` records** (215) — a second token-accounting surface
    (`promptTokenCount`, epoch-ms `timestamp`) that Engram neither captures nor
    reconciles against `message.usage`.

> ⚠️ **`systemMessageCount` is a user-text heuristic, not a system-record
> counter.** It increments only when a `user` text starts with
> `# AGENTS.md instructions for ` or contains `<INSTRUCTIONS>`
> (`QoderAdapter.swift:88-89,169-171`). On the live store that heuristic fired
> **0 times**, while 103 genuine `type:system` records were discarded — so for
> real Qoder data `systemMessageCount` is effectively **always 0** even when
> the store is full of system events.

---

## 15. Lineage, gotchas, version drift & edge cases

### Shared format lineage

Qoder is a **Claude-Code-JSONL-family** store. The schema is near-identical to
native Claude Code (`~/.claude/projects/<slug>/<sessionId>.jsonl`): same
`type`/`uuid`/`parentUuid`/`isSidechain`/`cwd`/`sessionId`/`userType`/`version`
envelope, same Anthropic `message.{role, content[], usage}` payload, same
`tool_use`/`tool_result`/`thinking` content blocks, same
`~/.<tool>/projects/<path-slug>/` root convention, and the same `subagents/`
subdir for dispatched agents. This is why `QoderAdapter` is structurally a clone
of the Claude Code adapter (record-type filter, content-block extraction,
path-based parent derivation are identical patterns).

**Engram sibling cohort** sharing `JSONLAdapterSupport.usage(from:)`
(`CodexAdapter.swift:220`) and the Anthropic-style usage keys
(`input_tokens`/`output_tokens`/`cache_read_input_tokens`/
`cache_creation_input_tokens`): **Codex, Cursor, Gemini CLI, Qwen, iFlow, Kimi,
OpenCode**. Per known lineage, **Gemini CLI ↔ Qwen ↔ iFlow** are one fork family
and **Cursor ↔ VS Code ↔ Copilot ↔ Cline** another; **Qoder sits in the Claude
Code JSONL lineage alongside native Claude Code.**

**Qoder's distinguishing deviations from upstream Claude Code:**
(a) the sibling `<sessionId>/` directory with `state.json`, `compression-v2/`,
and `task-*.json` task specs; (b) the `ai-title`/`last-prompt`/`token-stats`/
`system` server records (5 sidecar record types vs Claude Code's set);
(c) opaque model **aliases** (`ultimate`/`efficient`/`auto`/`<synthetic>`)
instead of real `claude-*` model IDs; (d) **opaque per-backend tool-use ID
prefixes** — `toolu_vrtx_*` (Vertex, majority), `toolu_bdrk_*` (Bedrock),
`call_*`/`chatcmpl-tool-*` (OpenAI-compatible), bare UUIDs — i.e. Qoder is
**multi-backend**; the prefix is the only backend signal and the `model` alias
hides which backend served a turn (do NOT read `bdrk` as "Bedrock-only
routing"); (e) `AGENTS.md` (not `CLAUDE.md`) system injections.

### Gotchas, version drift, edge cases

1. **Model is an alias, not a real ID.** Across the live store: `ultimate`
   (2026 records), `efficient` (659), `auto` (214), `<synthetic>` (8),
   empty `""` (16). The parity fixture uses `"qoder-agent"`. **Token-cost
   attribution by model is unreliable for Qoder** — these are marketing tiers,
   not `claude-3-5-sonnet` etc.
2. **Heavy version drift** (counts as of 2026-06-21; drift with new sessions).
   Five concurrent `version` strings on disk: `0.2.7` (304), `0.2.13` (371),
   `1.0.4` (540), `1.0.10` (743), `1.0.13` (2782); plus **281 records with NO
   `version` field at all** — these are the sidecar record types
   (`token-stats` 215, `last-prompt` 37, `file-history-snapshot` 21, `ai-title`
   8). (`user`/`assistant`/`system` records all carry `version`.) The
   0.2.x → 1.0.x jump spans a major rewrite; older files may lack
   `promptId`/`permissionMode`/nested usage fields. The adapter is resilient
   (extra fields ignored), but field presence cannot be assumed across versions.
3. **User-only sessions exist.** Live file `7e6d3cb3-….jsonl` (2575 B) has
   **5 `user` records, 0 `assistant`** → `messageCount`=5,
   `assistantMessageCount`=0, `model`=nil. Valid but atypical; any code asserting
   model/assistant presence will trip.
4. **`endTime` nulled when equal to start.** Single-turn / single-timestamp
   sessions report `endTime:nil` (the `startTime != endTime` guard), so duration
   logic must treat `nil` as "instantaneous/unknown."
5. **`sessionId` ≠ session id for subagents.** Subagent files set `sessionId` =
   the PARENT id; the subagent's own id is `agentId`. The adapter swaps to
   `agentId` **only when the path contains `/subagents/`** — path-dependent, not
   field-dependent. Moving/copying a subagent file out of `subagents/` would
   (a) re-key it under `sessionId` (the parent's id → collision) and (b) drop
   the `subagent` role and parent link.
6. **Parent link is path-derived, ignores the explicit task spec.** Engram
   derives `parentSessionId` from the parent-session dir name, not from
   `task-*.json`'s `parentToolUseId`/`sessionId`. Both agree in live data; a
   renamed parent dir silently produces a wrong/dangling parent id.
7. **System-injection heuristic is brittle AND fires 0 times live.**
   `systemMessageCount` keys on the literal prefix
   `"# AGENTS.md instructions for "` or substring `"<INSTRUCTIONS>"`. Qoder uses
   `AGENTS.md` (not `CLAUDE.md`); any wording change drops these into
   `userMessageCount` and can corrupt the first-user `summary`. On the real
   store the heuristic matched **0** records, so `systemMessageCount` is
   effectively **always 0** for Qoder — and crucially it does **NOT** count the
   103 genuine `type:system` records, which the `type ∈ {user, assistant}`
   filter discards entirely (§4, §14).
8. **`thinking` is fallback-only; `redacted_thinking` is invisible.**
   `extractContent` emits `thinking` only when a block has no
   `text`/`tool_use`/`tool_result` parts. The 358 `redacted_thinking` blocks are
   never extracted — reasoning content is largely absent from Engram's index.
9. **Truncation asymmetry, Swift vs TS (real parity gap).** Swift truncates
   tool_result `output` JSON to 2000 chars but passes string `content` through
   **un-truncated** (`QoderAdapter.swift:197-201`); TS truncates **both** the
   string and JSON paths to 2000 (`qoder.ts:222-228`). Indexed tool-output
   length can differ between product and reference for long string results.
   (Not confirmed whether a parity test currently exercises a >2000-char string
   `tool_result`.)
10. **`tool_result.content` vs `.output`.** Live data uses string `content`; the
    adapter falls back to `output` only when `content` is empty. Older-version
    records that put the payload in `output` rely on this fallback.
11. **No `parentUuid` threading preserved.** Engram flattens the message DAG;
    branched/edited conversation trees collapse to document order, losing which
    assistant turn answered which user turn.
12. **`ai-title` dropped.** Qoder's curated AI title (used in its own sidebar) is
    a strictly better summary than the first-user-text slice Engram uses — but
    neither adapter reads it.

### Open / unverified items

- `usage.iterations[]` was empty in all live samples — its element schema is
  unknown (likely per-streaming-iteration token deltas). (web-checked
  2026-06-21: no authoritative source found — no official Qoder source
  documents `message.usage` at all; the [Hooks doc](https://docs.qoder.com/extensions/hooks)
  lists transcript fields but omits `message.usage`, and Anthropic's public API
  defines no `iterations` field on `usage`, so this is an undocumented
  Qoder/backend extension.)
- **Confirmed (official):** Model aliases (`ultimate`/`efficient`/`auto`) map to
  undisclosed real provider models — the alias deliberately hides which backend
  served a turn. The [Model Tier Selector doc](https://docs.qoder.com/user-guide/chat/model-tier-selector)
  states verbatim: "The Model Tier Selector intelligently matches the most
  suitable model based on the selected tier—you don't need to know which
  specific model is being used," and notes Qoder may "retire or replace older
  models." The multi-backend nature is independently corroborated (Qoder
  auto-selects across Claude/GPT/Gemini and exposes Qwen/DeepSeek/GLM/Kimi),
  consistent with the multi-prefix tool-use IDs (`toolu_vrtx_*`/`toolu_bdrk_*`/
  `call_*`) on disk. The tool-use ID prefix is the only backend signal and shows
  **multiple backends** (`toolu_vrtx_*` Vertex-majority, `toolu_bdrk_*` Bedrock,
  `call_*`/`chatcmpl-tool-*` OpenAI-compatible); which concrete model each alias
  resolves to per turn is not stored in the transcript.
- `state.json.items{}` payloads are AES-style encrypted (`n`=nonce, `p`=payload,
  `t`=tag) — contents not recoverable without the Qoder key. (Engram-internal
  design — not web-verifiable: Qoder is closed-source and no official source
  documents the item encryption scheme; the `{c,n,p,t,u}` shape and AES/AEAD
  interpretation are reverse-engineered from the live store, which is the only
  evidence basis.)
- **Confirmed (official):** Only `entrypoint:cli` / `userType:external` was
  observed; an IDE-GUI entrypoint value (if any) is not represented in this
  sample set. Qoder ships multiple launch surfaces — Desktop IDE, JetBrains
  plugin, and a CLI ([Community Edition blog](https://qoder.com/blog/qoder-community)) —
  so a non-`cli` entrypoint value is plausible for IDE-launched sessions, but
  the [Hooks doc](https://docs.qoder.com/extensions/hooks) does NOT document an
  `entrypoint` field at all, so the literal IDE-GUI value remains undocumented.
  These specific files appear to come from the Qoder CLI, not the IDE GUI.
- The project-dir-level `subagents/` scan path (alternate placement) is
  unconfirmed against real data (only `<uuid>/subagents/` observed live).
  (Engram-internal design — not web-verifiable: this is a QoderAdapter scan-path
  question, not a documented Qoder format fact; no official source documents the
  on-disk subagents directory layout.)
- `task-*.json.outputPath` → `/private/tmp/qoder-cli-<uid>/…` was not inspected
  (outside `~/.qoder`); may hold additional ephemeral output not captured by
  Engram. (Engram-internal design — not web-verifiable: concerns Qoder's
  ephemeral temp output area and what Engram captures; no official source
  documents this temp path or its contents.)
- Whether older 0.2.x files differ structurally (missing usage/promptId) was
  inferred from the version spread, not verified by sampling a specific 0.2.x
  file. (web-checked 2026-06-21: no authoritative source found — no public Qoder
  changelog or format-versioning doc describes per-version transcript schema
  differences; the [Hooks doc](https://docs.qoder.com/extensions/hooks)
  documents only the current schema.)

---

## 16. Appendix: real anonymized samples

One fenced block per record/file type. Keys/types/structure verbatim; text,
code, secrets, and personal paths scrubbed.

### `assistant` record (with usage + thinking block)

```json
{"type":"assistant","uuid":"5d3726e1-9e40-4bd8-a96d-3d9507a8ce01",
 "parentUuid":"user:4789761a-0873-4183-835c-1ff089b7dad2########2",
 "sessionId":"4789761a-0873-4183-835c-1ff089b7dad2","timestamp":"2026-05-25T05:28:12.644Z",
 "version":"1.0.4","cwd":"/Users/bing/-Code-/engram","userType":"external","entrypoint":"cli",
 "isSidechain":false,
 "message":{"role":"assistant","model":"ultimate","id":"ae6e4cd3-3e73-4757-acd7-7b43e670d196",
   "type":"message","stop_reason":null,"stop_sequence":null,
   "usage":{"input_tokens":18867,"cache_creation_input_tokens":0,"cache_read_input_tokens":13628,
     "output_tokens":469,"server_tool_use":{"web_search_requests":0,"web_fetch_requests":0},
     "service_tier":"standard","cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":0},
     "inference_geo":"","iterations":[],"speed":"standard","request_id":"REDACTED"},
   "content":[{"type":"thinking","thinking":"REDACTED","signature":"REDACTED"}]}}
```

### `user` record (plain prompt)

```json
{"type":"user","uuid":"REDACTED-UUID","parentUuid":null,"isMeta":true,
 "sessionId":"4789761a-0873-4183-835c-1ff089b7dad2","timestamp":"2026-05-25T05:26:43.210Z",
 "cwd":"/Users/bing/-Code-/engram","version":"1.0.4","userType":"external","entrypoint":"cli",
 "isSidechain":false,"message":{"role":"user","content":"REDACTED"}}
```

### `user` record (tool_result turn)

```json
{"type":"user","uuid":"1b20e8de-e656-4966-9e02-8055d6fc497a",
 "parentUuid":"a8d327a1-e562-4509-b8d5-701179a51be5",
 "sourceToolAssistantUUID":"a8d327a1-e562-4509-b8d5-701179a51be5",
 "promptId":"9339cc26-4a75-4ee9-90ca-ebd752e56a98","toolUseResult":"REDACTED_OBJ",
 "sessionId":"4789761a-0873-4183-835c-1ff089b7dad2","timestamp":"2026-05-25T05:28:13.601Z",
 "cwd":"/Users/bing/-Code-/engram","version":"1.0.4","userType":"external","entrypoint":"cli",
 "isSidechain":false,
 "message":{"role":"user","content":[
   {"type":"tool_result","tool_use_id":"toolu_vrtx_013V8oMB2WQkkJnJ8jqvh2Wo","content":"REDACTED","is_error":false}]}}
```

### Subagent `assistant` record (extra keys: agentId, parent_tool_use_id, session_id)

```json
{"type":"assistant","uuid":"REDACTED-UUID","parentUuid":"REDACTED-UUID",
 "agentId":"ageneral-purpose-646b2bc0030e4762","parent_tool_use_id":"toolu_vrtx_01PW3LBksPmMHrjTtH9qL4Fh",
 "sessionId":"4789761a-0873-4183-835c-1ff089b7dad2","session_id":"4789761a-0873-4183-835c-1ff089b7dad2",
 "timestamp":"2026-05-25T…Z","cwd":"/Users/bing/-Code-/engram","version":"1.0.13",
 "userType":"external","entrypoint":"cli","isSidechain":true,
 "message":{"role":"assistant","model":"efficient","content":[{"type":"text","text":"REDACTED","citations":null}]}}
```

### `token-stats` record (NOT parsed — EPOCH-MS timestamp, 4 keys)

```json
{"type":"token-stats","sessionId":"5c444401-db67-4cab-8152-9cf3266cc4f5",
 "promptTokenCount":16462,"timestamp":1778650653301}
```

> `timestamp` here is an **int epoch-ms** (`1778650653301`), unlike the ISO-8601
> `…Z` strings in `user`/`assistant`/`system` records — matching the epoch-ms
> convention of `task-*.json`. Keys are always
> `[promptTokenCount, sessionId, timestamp, type]`. This is a **second
> token-accounting surface** besides `message.usage`; Engram captures neither.

### `system` record — `task_started` variant (NOT parsed — subagent dispatch in MAIN transcript)

```json
{"type":"system","subtype":"task_started","level":"info","task_type":"local_agent",
 "task_id":"ageneral-purpose-646b2bc0030e4762","tool_use_id":"call_6d5190e9b79e4996801d6c",
 "uuid":"REDACTED-UUID","parentUuid":"REDACTED-UUID",
 "sessionId":"4789761a-0873-4183-835c-1ff089b7dad2","timestamp":"2026-05-25T…Z",
 "cwd":"/Users/bing/-Code-/engram","version":"0.2.7","userType":"external","entrypoint":"cli",
 "isSidechain":false,"content":"REDACTED","description":"REDACTED","prompt":"REDACTED"}
```

> `system` carries `subtype ∈ {task_progress(72), task_notification(9),
> task_started(8), informational(8), error(5), api_retry(1)}` and
> `level ∈ {info, error}`. `task_type` is `"local_agent"` (only on
> `task_started`) or absent. Subtype-dependent optional fields: `task_id`,
> `tool_use_id` (`call_*` here), `prompt`, `description`, `usage`, `status`,
> `output_file`, `summary`. `task_started`/`task_progress` is an **alternate,
> field-based subagent-dispatch signal in the MAIN transcript** that Engram
> ignores in favor of path derivation (§10).

### `system` record — `error` variant (NOT parsed — smaller key set, no task fields)

```json
{"type":"system","subtype":"error","level":"error",
 "uuid":"REDACTED-UUID","parentUuid":"REDACTED-UUID",
 "sessionId":"4789761a-0873-4183-835c-1ff089b7dad2","timestamp":"2026-05-25T…Z",
 "cwd":"/Users/bing/-Code-/engram","version":"1.0.13","userType":"external","entrypoint":"cli",
 "isSidechain":false,"content":"REDACTED"}
```

### `ai-title` record (NOT parsed)

```json
{"type":"ai-title","sessionId":"4789761a-0873-4183-835c-1ff089b7dad2","aiTitle":"REDACTED"}
```

### `last-prompt` record (NOT parsed)

```json
{"type":"last-prompt","sessionId":"4789761a-0873-4183-835c-1ff089b7dad2","lastPrompt":"REDACTED"}
```

### `file-history-snapshot` record (NOT parsed)

```json
{"type":"file-history-snapshot","isSnapshotUpdate":false,
 "messageId":"user:4789761a-0873-4183-835c-1ff089b7dad2########2",
 "snapshot":{"messageId":"user:4789761a-0873-4183-835c-1ff089b7dad2########2",
   "timestamp":"2026-05-25T05:27:59.933Z",
   "trackedFileBackups":{"<abs/path>":{"backupFileName":"REDACTED","version":1,"backupTime":"2026-05-25T05:34:08.872Z"}}}}
```

### `subagents/agent-<id>.meta.json` (NOT parsed)

```json
{"agentType":"Explore","displayName":"Explorer","description":"REDACTED","color":"cyan"}
```

### `subagents/task-<id>.json` (NOT parsed — epoch-ms timestamps)

```json
{"taskId":"aExplore-604c32607f3e8031","sessionId":"4789761a-0873-4183-835c-1ff089b7dad2",
 "executionId":2000000004,"agentId":"aExplore-604c32607f3e8031","agentType":"Explore",
 "description":"REDACTED","parentToolUseId":"toolu_vrtx_01PW3LBksPmMHrjTtH9qL4Fh",
 "outputPath":"/private/tmp/qoder-cli-501/-Users-bing--Code--engram/4789761a-…/tasks/aExplore-604c32607f3e8031.output",
 "transcriptPath":"/Users/bing/.qoder/projects/-Users-bing--Code--engram/4789761a-…/subagents/agent-aExplore-604c32607f3e8031.jsonl",
 "completionBehavior":"notify","status":"completed","summary":"REDACTED",
 "createdAt":1779686940809,"updatedAt":1779687015740,"result":"REDACTED","completedAt":1779687015733}
```

> `status` ∈ {`completed` (36), `failed` (11), `cancelled` (4)} live — a
> `task-*.json` is **not** guaranteed a matching `agent-*.jsonl` transcript
> (51 task specs vs 44 transcripts; failed/cancelled tasks can lack one — §2).

### `<uuid>/state.json` (NOT parsed — encrypted items{})

```json
{"sessionId":"4789761a-0873-4183-835c-1ff089b7dad2","revision":42,
 "createdAt":"REDACTED","updatedAt":"REDACTED","workspaceDirectories":["/Users/bing/-Code-/engram"],
 "data":{},"items":{"<key>":{"c":"REDACTED","n":"BASE64_NONCE","p":"BASE64_PAYLOAD","t":"BASE64_TAG","u":"REDACTED"}}}
```

> `revision` is illustrative — it is a monotonically increasing int (observed up
> to **83** live). The item key SET is identical regardless of serialization
> order: `{c, n, p, t, u}` = created/nonce/payload/tag/updated.

### `<uuid>/compression-v2/state.json` (NOT parsed — internal version=1 despite v2 dir)

```json
{"version":1,"state":{"replacementDecisions":"REDACTED","seenFunctionResponseIds":"REDACTED",
 "sessionMemoryState":"REDACTED","autoCompactTracking":"REDACTED","snippedMessageIds":"REDACTED"}}
```

> The directory is named `compression-v2` but the file's internal `version`
> field is **`1`** in all 7 live files (v2-dir / v1-field distinction).

---

## References (official sources)

Web confirmation pass run 2026-06-21. Official Qoder sources used to confirm /
contextualize the format claims above:

- [Qoder Docs — Model Tier Selector](https://docs.qoder.com/user-guide/chat/model-tier-selector) — confirms model aliases (Auto/Ultimate/Performance/Efficient/Lite) deliberately hide the concrete backend model (§9, §15, Open questions).
- [Qoder Docs — Hooks (`transcript_path` + JSONL record schema)](https://docs.qoder.com/extensions/hooks) — documents the `transcript/` subdir layout (§2), the additional `session_meta` / `progress` record types (§4), and omits `message.usage` / `entrypoint` entirely (§9, Open questions).
- [Qoder Docs — Using CLI (AGENTS.md, /resume, /agents subagents)](https://docs.qoder.com/en/cli/using-cli) — context for CLI launch surface and subagent management.
- [Qoder Blog — Introducing Qoder Community Edition](https://qoder.com/blog/qoder-community) — confirms multiple launch surfaces (Desktop IDE / JetBrains plugin / CLI / Mobile / Cloud), basis for the IDE-GUI `entrypoint` possibility (§5, Open questions).
- [Qoder homepage](https://qoder.com/en) — Alibaba agentic AI coding IDE; multi-backend (Claude / GPT / Gemini + Qwen / DeepSeek / GLM / Kimi) corroboration (§15).
- [Qoder-AI/qoder-community](https://github.com/Qoder-AI/qoder-community) — MIT-licensed community docs/skills (NOT IDE source); basis for "closed-source, encryption scheme undocumented" (§13, Open questions).
