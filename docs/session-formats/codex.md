# Codex Session Format — Definitive Reference

Last researched: 2026-06-21 (Engram session-format research workflow);
native current-state verification updated: 2026-07-02; `cc-codex`
provider-root verification updated: 2026-07-02.

This is the permanent, exhaustive reference for how the **Codex CLI** (OpenAI's coding
agent) persists sessions on disk, and how Engram's `CodexAdapter` consumes them. It is
cross-checked against two sources of truth:

1. **The real on-disk files** under `~/.codex/` on this machine (2,659 active rollout
   `.jsonl` files + 5 archived as of 2026-07-02; earlier corpus statistics in this
   document were sampled from the 2026-06-21 2,505 + 5 corpus). When the format and the adapters disagree, **on-disk reality wins** and the
   discrepancy is flagged.
2. **Engram's adapters** that already parse the format:
   - `/Users/bing/-Code-/engram/macos/Shared/EngramCore/Adapters/Sources/CodexAdapter.swift` (the shipped product parser)
   - `/Users/bing/-Code-/engram/src/adapters/codex.ts` (TypeScript reference/parity mirror)
   - `/Users/bing/-Code-/engram/macos/Shared/EngramCore/Adapters/SessionAdapter.swift` (`OriginatorClassifier`)
   - `/Users/bing/-Code-/engram/macos/Shared/EngramCore/Adapters/SessionAdapterFactory.swift` (discovery)
   - `/Users/bing/-Code-/engram/src/adapters/codex-usage-probe.ts` (quota scraping — NOT a rollout parser)

---

## Overview & TL;DR

**What gets saved, where, by what process.** Every Codex session is written to disk by the
Codex CLI/desktop runtime as **two complementary layers**:

- **Rollout JSONL transcript** (the authoritative content) — one append-only line-delimited
  JSON file per session at `~/.codex/sessions/YYYY/MM/DD/rollout-<localtime>-<uuidv7>.jsonl`.
  Every user turn, model output, reasoning block, tool call/result, runtime event, and token
  count is one JSON line.
- **SQLite catalog/index DBs** (`~/.codex/state_5.sqlite` etc.) — a fast, queryable
  *denormalized index* over the rollouts (thread catalog, parent→child spawn graph, memory
  pipeline, goals, logs). These hold **state, relationships, and derived data**, not the
  transcript. The DB is rebuildable from the files.

The link between the two layers is a single universal join key: the **UUIDv7** that is
simultaneously the filename UUID, `session_meta.payload.id`, `threads.id`,
`session_index.jsonl.id`, and `history.jsonl.session_id`.

**One-paragraph mental model.** Open a rollout file: line 1 is always a `session_meta`
header (identity, cwd, originator, git, agent role). Every subsequent line has the same
three-key envelope `{timestamp, type, payload}` where the top-level `type` is the *record
class* (`response_item` / `event_msg` / `turn_context` / `compacted`) and `payload.type` is
the *content variant inside* (`message` / `reasoning` / `function_call` / `token_count` /
…). The model conversation lives in `response_item` lines; token usage lives in
`event_msg`/`token_count` lines; per-turn config lives in `turn_context`; context
compaction rewrites lives in top-level `compacted` records. Engram streams the JSONL,
re-derives everything (id, times, cwd, model, counts, usage, summary) and **never reads the
SQLite layer**.

## Claude Code Provider-Root Variant (`cc-codex`)

This document's main body describes native Codex CLI rollout files under
`~/.codex/`. Local `cc-codex` sessions are different: they are Claude Code JSONL
files under `~/.claude-openai/projects`, created by the user's `cc-codex`
wrapper (`_cc_with openai`), and Engram maps them to source `codex` by
provider-root path.

2026-07-02 local smoke over `~/.claude-openai/projects`:

| Listed JSONL | Parsed conversations | Subagents | Parent links | Source |
|---:|---:|---:|---:|---|
| 2,823 | 2,693 | 2,659 | 2,659 | `codex` |

Model metadata is backend metadata and is not used for source ownership; the
provider root path owns the `codex` source. The skipped files are workflow
`journal.jsonl` status logs plus local-command/system-injection side-channel
sessions with no displayable conversation turns.

Fresh field-level smoke found 192,351 raw records and 0 malformed lines. The
retained TS parser listed 2,823 locators, parsed 2,693 conversations, and found
0 parser/stream count mismatches after visible-tool-result alignment with
Swift.

DB/runtime check from the same pass:

- Installed `/Applications/Engram.app` build `20260701074505` has 2,526
  `codex` rows under `/Users/bing/.claude-openai/%` and 2,654
  `file_index_state` rows for the root (2,526 `ok`, 128 `retry`), all still
  schema version 1.
- Fresh parser evidence sees 167 parseable `cc-codex` locators outside
  `sessions`: 166 have no `file_index_state`, and 1 is already represented in
  `file_index_state` as `retry/malformedJSON`. The current delta is an
  active-write/retry frontier, not missing provider-root support.
- The corrected visible-tool-result parser reports 0 field-stale current
  provider-root rows. The earlier 2,433-row stale-count note was a retained-TS
  audit-tooling false positive: TS was counting non-visible Claude
  `tool_result` rows that the Swift product already drops. This audit did not
  mutate `/Users/bing/.engram/index.sqlite`.

Do not use native `codex` row counts as proof that `cc-codex` is indexed. They
share the Engram source id but have different on-disk formats and roots.

**ASCII layering diagram:**

```
~/.codex/                                          ← Codex home
│
├── sessions/2026/06/21/rollout-<localTS>-<uuid>.jsonl   ← AUTHORITATIVE transcript (append-only)
│     │
│     │   L0  one line = {timestamp, type, payload}      ← envelope
│     │        │
│     │        ├─ L1  type = session_meta | response_item | event_msg | turn_context | compacted
│     │        │         │
│     │        │         └─ L2  payload.type = message | reasoning | function_call |
│     │        │                  function_call_output | token_count | agent_message | ...
│     │        │                    │
│     │        │                    └─ L3  content[].type = input_text | output_text | input_image
│     │        │                            summary[].type = summary_text
│     │
├── archived_sessions/rollout-...jsonl              ← FLAT (no Y/M/D); moved here on archive
├── history.jsonl  session_index.jsonl              ← global append-log mirrors (user input / titles)
│
└── state_5.sqlite  memories_1.sqlite  goals_1.sqlite  logs_2.sqlite   ← INDEX/STATE layer
      │   threads (1 row/session) ── rollout_path ──► points back at the .jsonl
      │   thread_spawn_edges (parent→child subagent graph)
      └── sqlite/ {codex-dev.db + stale duplicate state/goals/logs}  ← LEGACY generation
```

---

## On-disk layout & file naming

### Top-level layout of `~/.codex/`

```
~/.codex/
  sessions/YYYY/MM/DD/rollout-<localtime>-<uuidv7>.jsonl   # per-session transcripts (AUTHORITATIVE)
  archived_sessions/rollout-<localtime>-<uuidv7>.jsonl     # FLAT — no YYYY/MM/DD; archived transcripts
  attachments/                                             # pasted/attached blobs
  generated_images/                                        # generated image blobs
  history.jsonl                                            # cross-session USER-INPUT history (append log, 3.9 MB)
  session_index.jsonl                                      # id → thread_name (human title) append log (100 KB)
  state_5.sqlite   (+ -wal, -shm)                          # 16 MB — THREADS catalog (DB index of truth)
  memories_1.sqlite (+wal/shm)                             # background memory-extraction job queue (940 KB)
  goals_1.sqlite    (+wal/shm)                             # per-thread goal/budget tracking (60 KB)
  logs_2.sqlite     (+wal/shm)                             # 1.3 GB — internal Rust tracing log sink
  config.toml  auth.json  AGENTS.md  installation_id       # config/identity (out of scope)
  sqlite/                                                  # SECONDARY dir: codex-dev.db + LEGACY copies
    codex-dev.db                                           # local app-server (automations/inbox) — dev-only
    state_5.sqlite, goals_1.sqlite, logs_2.sqlite,         # STALE earlier generation (mtime 2026-06-14/19)
    memories_1.sqlite (+wal/shm)
```

The `_N` suffix (`state_5`, `memories_1`, `goals_1`, `logs_2`) is a **migration generation**:
when Codex needs a hard, non-`sqlx` reset of a DB's schema family, it abandons the old file
and starts a new numbered one rather than migrating in place. Inside each file an
`_sqlx_migrations` table (Rust `sqlx` ledger) tracks incremental migrations. The copies under
`~/.codex/sqlite/` are an **older location/generation** (Codex relocated the DB root up from
`~/.codex/sqlite/` to `~/.codex/` directly) — classified as legacy by stale mtime AND lower
migration version (legacy `state_5` is at migration **35** / **2267 threads**; live is at
**40** / **2664 threads**). Only `codex-dev.db` is unique to the `sqlite/` subdir.

### Rollout transcript: file path & naming grammar

Path template: `~/.codex/sessions/YYYY/MM/DD/rollout-<TS>-<UUID>.jsonl`

| Component | Format | Verified behavior |
|---|---|---|
| `YYYY/MM/DD` | zero-padded date dirs | Bucketing by **LOCAL-time** date (matches the filename TS, not the inner UTC). Days created lazily. Empty month dirs (`2025/09`, `2025/10`) exist with **zero** rollout files — the earliest readable rollout is `2025/11/20` (cli `0.60.1`). |
| `rollout-` | literal prefix | Engram keys discovery on this prefix + `.jsonl` extension. |
| `<TS>` | `YYYY-MM-DDTHH-MM-SS` | **LOCAL TIME**, `:` replaced by `-`, no fractional seconds, no zone. VERIFIED: file `rollout-2025-11-20T11-08-12-...` has inner `session_meta.timestamp = 2025-11-20T03:08:12.198Z` (UTC) on a UTC+8 host → filename TS = UTC+8. **The filename timestamp is NOT UTC.** |
| `<UUID>` | UUIDv7 (`019x...`) | **Equals `session_meta.payload.id` exactly**, and equals `threads.id`, `session_index.jsonl.id`, `history.jsonl.session_id`. UUIDv7 is time-ordered, so its leading bytes encode the same creation instant as the filename. |

**`archived_sessions/` semantics.** Archiving **moves** the rollout file out of the
`YYYY/MM/DD` tree into a **flat** `archived_sessions/` dir (filename unchanged), sets
`threads.archived=1` + `threads.archived_at`, and rewrites `threads.rollout_path` to the new
location. VERIFIED: all 5 `archived=1` rows have `rollout_path` =
`~/.codex/archived_sessions/rollout-...jsonl`; all 2659 `archived=0` rows point into the
`sessions/YYYY/MM/DD` tree as of 2026-07-02. Disk count (2659 tree + 5 archived) ==
Codex `state_5.sqlite` thread count (2664) exactly. Engram's own `~/.engram/index.sqlite`
currently has 2662 native `codex` rows under `/Users/bing/.codex/%`, with 2 parseable
rollout files absent and 0 stale session extras; latest native `codex` indexed_at is
`2026-07-01T04:11:11Z`. Existing Engram DB model values are also stale (`openai` provider
name in 1808 rows, NULL/empty in 838, `gpt-5.5` in 15, and `custom` in 1); current source
parses concrete models from JSONL for 2610/2664 sessions after the
2026-07-01 `turn_context.payload.model` fix.

### Tree example

```
~/.codex/
├── sessions/
│   ├── 2025/11/20/rollout-2025-11-20T11-08-12-019a9f3b-de26-71f0-991d-b722717131eb.jsonl
│   └── 2026/06/21/
│       ├── rollout-2026-06-21T00-23-04-019ee5d7-c66e-7852-b0e0-9a09a0f4adf8.jsonl
│       ├── rollout-2026-06-21T03-58-01-019ee69c-91fe-7682-a524-a58015c593b6.jsonl
│       └── rollout-2026-06-21T01-39-16-019ee61d-8aa4-7883-bdc0-65be85460940.jsonl
├── archived_sessions/
│   └── rollout-2026-02-17T09-08-34-019c6924-53b5-7a42-9d67-18f8288bbc08.jsonl   (archived=1)
├── history.jsonl
├── session_index.jsonl
├── state_5.sqlite (+ -wal, -shm)
├── memories_1.sqlite  goals_1.sqlite  logs_2.sqlite
└── sqlite/  (legacy)  codex-dev.db  state_5.sqlite  goals_1.sqlite  logs_2.sqlite  memories_1.sqlite
```

---

## File lifecycle & generation

- **Append-only, never rewritten.** The rollout `.jsonl` is written line-by-line as the
  session progresses. Each line is a complete JSON object terminated by `\n`. A crash leaves
  a valid-up-to-last-complete-line file; a partial final line is simply unparseable JSON and
  is skipped by both adapters (`parseLine` returns `null` / `parseObject` returns `nil`).
- **Header first.** Line 1 is always `session_meta` (the authoritative header). In rare
  forked/resumed files an extra `session_meta` line can appear later; **the first one wins**
  (both adapters take the first `session_meta` and ignore subsequent ones).
- **Resume / continue.** A resumed or forked session continues writing into the *same*
  rollout file (same UUID). `session_meta.forked_from_id` records the session it was branched
  from; `parent_thread_id` records a subagent's spawning thread. Compaction also continues in
  the same file (see Summary / compaction).
- **Rollover.** There is no size-based rollover of a single rollout — one session = one file.
  The date *directory* rolls at local midnight (a new session that day lands in a new
  `YYYY/MM/DD` dir, created lazily).
- **DB materialization.** The SQLite `threads` row is materialized from the rollout's first
  line (`session_meta`) by a backfill scanner. `backfill_state` (single row, CHECK id=1)
  holds the cursor: `status='complete'`, `last_watermark='sessions/2026/02/25/rollout-...'`,
  `last_success_at`. The DB lags or leads the files only transiently; in this store they are
  exactly consistent.
- **Crash/partial robustness in Engram.** Engram's Swift reader validates file identity
  (size/mtime) before and after a full parse and fails with `.fileModifiedDuringParse` if the
  file changed mid-read; for windowed reads it skips that check. Lines exceeding
  `maxLineBytes` or files exceeding `maxMessages` are capped, not crashed.

---

## Record / line taxonomy

**The layering rule (readers confuse this constantly).** There are up to four nesting layers.
Do **not** conflate the top-level record `type` with the nested `payload.type`:

| Layer | What it is | Field | Examples |
|---|---|---|---|
| **L0 envelope** | one JSONL line = one record | `{timestamp, type, payload}` | — |
| **L1 record type** | the kind of envelope | `.type` | `session_meta`, `response_item`, `event_msg`, `turn_context`, `compacted`, `world_state` |
| **L2 payload type** | the variant inside | `.payload.type` | `message`, `reasoning`, `function_call`, `token_count`, `agent_message` … |
| **L3 content block** | nested array element | `.payload.content[].type` / `.payload.summary[].type` | `input_text`, `output_text`, `input_image`, `summary_text` |

> Critical name traps:
> - `compacted` is an **L1 record type**; `context_compacted` is an **L2** `event_msg`
>   variant — different things at different layers. There is **no** record literally named
>   `compaction` (it appears only as a substring inside summary text).
> - `message` / `reasoning` / `function_call` / `token_count` are **L2**, never L1.
> - `input_text` / `output_text` / `summary_text` are **L3**, never L2.
> - `search` / `read` / `list_files` from the original pointer are **tool NAMES** carried
>   inside `function_call.name` or `mcp_tool_call_end.invocation.tool`, not record/payload
>   types.

### L1 (top-level) record types

VERIFIED histogram in one real recent file: 65 `response_item`, 37 `event_msg`,
1 `session_meta`, 1 `turn_context`. These dominate on disk, but the on-disk set is NOT
closed. Confirmed (official, 2026-06-21): the authoritative `RolloutItem` enum
([protocol.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs))
has **SIX** variants (`serde(tag="type", content="payload", rename_all="snake_case")`):
`SessionMeta`, `ResponseItem`, `InterAgentCommunication`, `Compacted`, `TurnContext`,
`EventMsg`. Earlier drafts omitted **`inter_agent_communication`** — a real top-level rollout
record (durable inter-agent delivery metadata reconstructed as a model-visible
`agent_message`). Local corpus verification on 2026-07-02 also found 200 top-level
`world_state` records in current desktop/Responses sessions; treat those as environment-state
snapshots and do not assume the L1 set is exhausted by the older official enum check.

| L1 `type` | Role | Purpose | When emitted | Engram consumes? |
|---|---|---|---|---|
| `session_meta` | **first line** of every rollout (header) | session identity + environment | exactly 1 per file (first wins) | **Yes** — identity |
| `turn_context` | per-turn runtime config snapshot | model/sandbox/approval/effort/mode for the turn | ≥1 per turn (newer CLI only; absent in 0.60.1) | **Yes** — model fallback |
| `response_item` | model-API conversation item | the actual transcript (msgs, reasoning, tool calls/results) | the bulk of lines | **Yes** — messages |
| `event_msg` | runtime/UI event (not a model item) | token accounting, task lifecycle, tool telemetry, compaction marker | interleaved throughout | **Only `token_count`** |
| `compacted` | context-compaction checkpoint | rewrites/compacts the conversation history | only when context is compacted | **No** (ignored) |
| `inter_agent_communication` | durable inter-agent delivery record | inter-agent delivery metadata, reconstructed as a model-visible `agent_message` | multi-agent sessions only | **No** (ignored) |
| `world_state` | environment/context snapshot | full world-state/context packet for desktop/runtime resumes | rare/current desktop sessions | **No** (ignored) |

> Engram branches on `session_meta`, `turn_context`, `response_item`, and `event_msg`. It uses
> `turn_context.payload.model` only as a session model fallback; it ignores `compacted`,
> `inter_agent_communication`, `world_state`, and all non-`token_count` `event_msg` records.

### L2 (nested) types separated by record

- **inside `response_item.payload.type`:** `message`, `reasoning`, `function_call`,
  `function_call_output`, `custom_tool_call`, `custom_tool_call_output`, `web_search_call`,
  `tool_search_call`, `tool_search_output`. (Counts in one file: `function_call` 20,
  `function_call_output` 20, `reasoning` 17, `message` 7, `web_search_call` 1.)
- **inside `event_msg.payload.type`:** `token_count`, `agent_message`, `agent_reasoning`
  (legacy), `user_message`, `task_started`, `task_complete`, `turn_aborted`,
  `context_compacted`, `exec_command_end` (legacy), `patch_apply_end`, `mcp_tool_call_end`,
  `web_search_end`, `entered_review_mode`, `exited_review_mode`, `thread_rolled_back`,
  `thread_goal_updated`, `error`, **plus the native-multi-agent / image / dynamic-tool
  family** `thread_name_updated`, `collab_agent_spawn_end`, `collab_waiting_end`,
  `collab_close_end`, `collab_agent_interaction_end`, `collab_resume_end`,
  `view_image_tool_call`, `image_generation_end`, `item_completed`,
  `dynamic_tool_call_request`, `dynamic_tool_call_response`. (Counts in one file:
  `token_count` 18, `mcp_tool_call_end` 11, `agent_message` 4, `task_started` 1,
  `user_message` 1, `web_search_end` 1, `task_complete` 1.)

> **The `event_msg` enumeration is NOT a finite, closed set.** A full-corpus histogram of
> all 2,505 rollout files (`/tmp/codex_all_types.txt`) found 11 additional `event_msg`
> `payload.type` values beyond the original list, several in the hundreds:
> `thread_name_updated` (372), `collab_waiting_end` (474), `collab_agent_spawn_end` (441),
> `collab_close_end` (289), `collab_agent_interaction_end` (71), `collab_resume_end` (1),
> `view_image_tool_call` (403), `image_generation_end` (244), `item_completed` (14),
> `dynamic_tool_call_request` (3), `dynamic_tool_call_response` (3). Treat the taxonomy as
> growing across CLI versions, not enumerable-and-done. Field tables + anonymized examples
> for all 11 are in the Appendix (and the `collab_*` family is cross-referenced in the
> Subagent section). **Engram drops every one of them** (none match the
> `message`/`function_call`/`function_call_output`/`token_count` branches).
>
> Note (web-checked 2026-06-21): `thread_name_updated` is a real Codex notification type but
> is **NOT** a variant of the core rollout `EventMsg` enum in `protocol.rs` — in source it is
> an app-server/TUI notification (`ThreadNameUpdatedNotification`). On-disk `event_msg` lines
> tagged `thread_name_updated` therefore most likely come from the desktop/app-server write
> path, not the core rollout recorder.
> ([common.rs](https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/src/protocol/common.rs))

---

## Shared envelope / metadata fields

### L0 envelope (every line)

| Field | Type | Meaning | Optional? | Example |
|---|---|---|---|---|
| `timestamp` | string (ISO-8601, ms, `Z` = **UTC**) | wall-clock when the line was appended to the file. Engram uses the **last** line carrying a `timestamp` as `endTime`. | present on virtually all lines | `"2026-06-21T06:06:38.238Z"` |
| `type` | string (enum) | L1 record type | always | `"response_item"` |
| `payload` | object | type-specific body (L2) | always | `{ ... }` |

> The envelope `timestamp` differs slightly from `payload.timestamp` inside `session_meta`
> (envelope = line-write time; payload = session-create time, a few seconds earlier).

### `session_meta.payload` — the session header (KEY for identity)

The field set **grew across CLI versions** (union below). Always line 1; rejected by Engram
if `id` is missing/empty.

| Field | Type | Meaning | Present? | Example (anonymized) |
|---|---|---|---|---|
| `id` | string (UUIDv7) | **session id** = filename UUID = `threads.id` | always | `"019ee8c9-c5b3-78f0-bdc2-ab4c8e024293"` |
| `timestamp` | string (ISO UTC) | session start → Engram `startTime` | always | `"2026-06-21T06:06:38.051Z"` |
| `cwd` | string (abs path) | working dir at session start → Engram `cwd` | always | `"/Users/<user>/<project>"` |
| `originator` | string enum | **THE dispatch signal** — launching client/host | always | `"codex-tui"`, `"Claude Code"` |
| `cli_version` | string semver | Codex CLI version that wrote the file (field is `cli_version`; **no `version` alias**) | always (newer) | `"0.142.0-alpha.6"` / `"0.60.1"` |
| `model_provider` | string | provider name only — **NOT the model id** | always | `"openai"` |
| `source` | **string OR object** | launch surface; **polymorphic** (see Subagent section) | always | `"cli"` / `"vscode"` / `{"subagent":{...}}` |
| `instructions` | string \| null | **LEGACY** (≤~0.6x): stored `user_instructions`, gone from modern `session_meta`. Confirmed (official): per the `SessionMeta` source comment, this field's `user_instructions` were **moved to `TurnContext`** — not renamed to `base_instructions`. ([protocol.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs)) | old files only | `null` |
| `base_instructions` | object `{text}` | **A DISTINCT field, not a rename of `instructions`**: it holds the **base/system** instructions for the session; `.text` is multi-KB. (`instructions`/user_instructions migrated to `turn_context`; `base_instructions` is the separate base-prompt slot.) | newer files | `{"text":"You are Codex..."}` |
| `agent_path` | string \| null | canonical agent path for AgentControl-spawned sub-agents. Confirmed (official): present on `SessionMeta`. ([protocol.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs)) | subagent files | `"<path>"` |
| `git` | object \| null | repo context `{commit_hash, branch, repository_url}`; `{}` when not a repo | most files (≈2242/2505) | `{"commit_hash":"d941...","branch":"main","repository_url":"..."}` |
| `thread_source` | string enum | dominant on-disk values `"user"` \| `"subagent"`. Confirmed (official): the `ThreadSource` enum actually has **four** variants — `User`, `Subagent`, `Feature(String)`, `MemoryConsolidation` — so the on-disk set can be wider than user/subagent. ([protocol.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs)) | newer | `"subagent"` |
| `agent_role` | string \| null | subagent role → Engram `agentRole` (takes precedence over originator). Confirmed (official): carries a serde alias **`agent_type`** (older payloads used `agent_type`), so both keys map to the same field. ([protocol.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs)) | subagent files | `"explorer"` / `"review"` / `null` |
| `agent_nickname` | string \| null | subagent display name (rotating scientist/plant names, `the Nth` on reuse) | subagent files | `"Euclid"`, `"Explorer the 12th"` |
| `forked_from_id` | string (UUIDv7) \| null | session this was forked/resumed from | ≈276 files | `"019e8df9-551f-7e01-..."` |
| `parent_thread_id` | string (UUIDv7) | parent thread for spawned subagents (also nested in `source`) | ≈239 files | `"019ee02d-c140-7813-8897-56f02fb68e88"` |
| `multi_agent_version` | string | multi-agent protocol version | ≈239 files | `"v1"` |
| `dynamic_tools` | object/array | runtime-registered tools | rare (≈42 files) | `{...}` |
| `model` | string | rarely present in meta; Engram uses it only if no `response_item.payload.model` or `turn_context.payload.model` was seen | rare/absent in current corpus | `"gpt-5.5"` |

**`originator` distinct values** (DB + disk sampling; counts approximate across ~2500 sessions):

| `originator` | Count | Meaning |
|---|---|---|
| `codex-tui` | ~1238–1271 | modern interactive Codex terminal UI (current default) |
| `codex_cli_rs` | ~514–545 | legacy Rust CLI originator string (pre-`codex-tui`) |
| `Claude Code` | **~394** | session launched **by Claude Code dispatching Codex as a sub-agent** → Engram Layer-1b |
| `Codex Desktop` | ~286–335 | Codex VS Code / desktop app (usually `source:"vscode"`) |
| `codex_exec` | ~69 | headless non-interactive `codex exec` (usually `source:"exec"`) |
| `codex_sdk_ts` | ~4 | programmatic TypeScript SDK driver |

---

## Message & content-block schema

`response_item` carries the model-facing transcript. Each variant below is an `L2`
`payload.type`. **L3 content blocks** nest inside `message.content[]` and
`reasoning.summary[]`.

### `message` (user / assistant / developer)

`payload` keys: `type`, `role`, `content` (+ optional `id`, `status`, `phase`, `metadata`,
`usage`).

| Field | Type | Meaning | Optional? |
|---|---|---|---|
| `role` | `"user"` \| `"assistant"` \| `"developer"` | speaker. `developer` carries injected system/permission text (seen mostly inside `compacted.replacement_history`). | required |
| `content` | array of L3 blocks | the text/image content | required |
| `id` | string \| null | provider message id (newer; `null` in modern data) | optional |
| `status` | string \| null | message status (`null` in modern data) | optional |
| `phase` | string | **legacy** assistant field: `"commentary"` \| `"final_answer"` | legacy (Feb 2026), dropped later then reappears as `metadata.phase` |
| `metadata` | object | newer telemetry, e.g. `{turn_id}` | newer |
| `usage` | object | **DOES NOT EXIST on modern disk** — see discrepancy below | legacy/Responses-API only |

**L3 content-block types inside `message.content[]`:**

| `block.type` | role context | fields | notes |
|---|---|---|---|
| `input_text` | user / developer | `{type, text}` | the text is under `text`, **not** under a key named `input_text` |
| `output_text` | assistant | `{type, text}` | the text is under `text`, **not** under `output_text` |
| `input_image` | user | `{type, image_url, detail}` | `image_url` is a `data:image/...;base64,...` URL; `detail` e.g. `"auto"` |
| `text` | older | `{type, text}` | legacy plain block; still accepted by `extractText` |

```json
// response_item / message (user) — two text blocks
{
  "timestamp": "2026-06-21T06:06:38.500Z",
  "type": "response_item",
  "payload": {
    "type": "message",
    "role": "user",
    "id": null,
    "status": null,
    "content": [
      { "type": "input_text", "text": "<USER PROMPT — redacted>" },
      { "type": "input_text", "text": "<ENVIRONMENT/SKILLS INJECTION — redacted>" }
    ]
  }
}
```

```json
// response_item / message (assistant)
{
  "timestamp": "2026-06-21T06:06:40.100Z",
  "type": "response_item",
  "payload": {
    "type": "message",
    "role": "assistant",
    "content": [ { "type": "output_text", "text": "<ASSISTANT REPLY — redacted>" } ]
  }
}
```

```json
// response_item / message (user, image attachment)
{
  "type": "response_item",
  "payload": {
    "type": "message",
    "role": "user",
    "content": [ { "type": "input_image", "image_url": "data:image/jpeg;base64,<BASE64…>", "detail": "auto" } ]
  }
}
```

**KEY DISCREPANCIES (on-disk reality vs adapters):**

- *Text key:* the block discriminator is `type:"input_text"`/`"output_text"`, but the actual
  string is **always** under the key `text`. Both adapters defensively also try
  `object["input_text"]` / `object["output_text"]` keys; those fallbacks **never match
  modern Codex data**.
- *Multi-block text:* both Swift and retained TS now join all retained text blocks with
  `\n\n` after skipping non-text blocks, so multi-part user/assistant content is no longer
  truncated to the first block.
- *Per-item usage absent:* both adapters read assistant `payload.usage` as a per-message
  usage source, but a scan of modern files found
  **zero** `response_item.payload.usage`. Per-turn usage comes exclusively from
  `event_msg/token_count`. This is a latent code path that would silently take precedence if
  a future Codex re-adds inline usage.
- *Model absent on item:* modern files do not carry `response_item.payload.model`
  (0 occurrences in the 2026-07-01 local corpus); concrete model names are carried by
  `turn_context.payload.model` (48,834 records). The 2026-07-01 adapter fix makes both TS and
  Swift read `turn_context.payload.model` after preserving the old `response_item` fallback.
  Current source parses concrete models for 2610/2664 local Codex sessions; the remaining 54
  older/sparse sessions have no available model field.

---

## Tool calls & results

Codex tool execution appears as a **paired** `function_call` (request) + `function_call_output`
(result), joined 1:1 by `call_id`. There is also a parallel `custom_tool_call` /
`custom_tool_call_output` pair for freeform tools (`apply_patch`, `js_repl`, …), plus dynamic
tool-search, web-search, and image (`ig_*`) calls. Rich execution telemetry is mirrored
separately under `event_msg` (`exec_command_end`, `patch_apply_end`, `mcp_tool_call_end`).

### `function_call`

| Field | Type | Meaning | Example |
|---|---|---|---|
| `type` | `"function_call"` | discriminator | `"function_call"` |
| `name` | string | tool name | `"exec_command"`, `"write_stdin"`, `"spawn_agent"`, `"codegraph_explore"` |
| `arguments` | **string (JSON-encoded)** | stringified JSON args — must be `JSON.parse`d | `"{\"cmd\":[\"/bin/zsh\",\"-lc\",\"…\"],\"workdir\":\"…\"}"` |
| `call_id` | string (`call_<rand>`) | unique id linking to the matching output | `"call_TMg3Szj…"` |
| `id` | string | provider call id (newer) | `"<id>"` |
| `namespace` | string | tool namespace for MCP / built-in groups | `"mcp__codegraph"`, `"multi_agent_v1"`, `"mcp__engram"` |
| `metadata` | object | newer, e.g. `{turn_id}` | `{}` |

### `function_call_output`

| Field | Type | Meaning |
|---|---|---|
| `type` | `"function_call_output"` | discriminator |
| `call_id` | string | **matches the originating `function_call.call_id`** (does NOT repeat `name`) |
| `output` | string (100% of sampled files) \| structured | tool result. Confirmed (official): the wire form is `FunctionCallOutputPayload`, which is **either** a plain string (`content`) **or** an array of structured content items (`content_items`) — NOT the `{output, metadata}` object earlier drafts described. `custom_tool_call_output` uses the same encoding. The "output may be non-string" premise holds; the specific `{output, metadata}` shape was wrong. ([models.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/models.rs)) |

### `custom_tool_call` / `custom_tool_call_output` (freeform tools — `apply_patch`, `js_repl`, …)

`custom_tool_call` keys: `type`, `name`, `input` (**not** `arguments` — a freeform string,
e.g. a patch body), `call_id`, `status`. `custom_tool_call_output` keys: `type`, `call_id`,
`output` (string).

> **`custom_tool_call.name` is NOT limited to `apply_patch`.** A full-corpus name
> distribution found two freeform tools: `apply_patch` (37,621) **and `js_repl` (139)** — a
> JS evaluation tool whose `input` is a JS snippet rather than a patch body. So this is the
> generic *freeform-tool* channel, not the apply-patch channel. **Engram does NOT handle any
> `custom_tool_call*`** — all freeform-tool calls (`apply_patch`, `js_repl`, and any future
> name) are dropped from the normalized transcript and excluded from `toolCount`. (evidence:
> jq `custom_tool_call` name histogram across the 2025–2026 corpus.)

### Image tools — `image_generation_call` / `image_generation_end` / `view_image_tool_call`

A **third tool-output mechanism** (image generation + image viewing) the prior taxonomy
omitted. It uses a distinct id namespace: the id is `ig_<hex>` (e.g. `ig_0a0…`, ~53 chars),
**NOT** the `call_<rand>` id of function calls. The `ig_` id minted on the `response_item`
side (`image_generation_call.id`) is reused as `call_id` on the `event_msg` side
(`image_generation_end.call_id`) — that is the join key.

| Record / payload.type | Layer | Keys | Meaning |
|---|---|---|---|
| `image_generation_call` | L2 `response_item` | `{type, id:ig_<hex>, status, revised_prompt, result}` | the model's image-generation request; `status` e.g. `generating`/`completed`; `revised_prompt` is the model-rewritten image prompt; `result` is the (base64/blob) output container |
| `image_generation_end` | L2 `event_msg` | `{type, call_id:ig_<hex>, status, revised_prompt, result, saved_path}` | runtime completion telemetry; adds `saved_path` (where the blob landed under `generated_images/`) |
| `view_image_tool_call` | L2 `event_msg` | `{type, call_id, path}` | the *image-view* tool — the agent reading an on-disk image at `path` |

> **Engram handles none of these** — image generation/viewing is invisible to the normalized
> transcript and `toolCount`. (evidence: jq payload inspection of
> `image_generation_call`/`image_generation_end`/`view_image_tool_call`; id-prefix check
> confirms `ig_` ≠ `call_`.)

### `web_search_call` / `tool_search_call` / `tool_search_output`

- `web_search_call`: `{type, status}` minimal, or richer `{type, status, action}` where
  `action.type ∈ {search, open_page, find_in_page}` with `{query, queries, url}`.
- `tool_search_call`: `{type, call_id, status, execution, arguments}` — here `arguments` is an
  **object** `{query, limit}` (contrast `function_call.arguments` which is a JSON string).
- `tool_search_output`: `{type, call_id, status, execution, tools[]}` with tool descriptors.

### The call↔result linkage model

VERIFIED in the largest sampled session: exactly **3,565 distinct `call_id`s** in
`function_call` and **3,565** in `function_call_output` — a perfect 1:1 join. Pairing is
simple `call_id` equality. The tool **name** is only on the call; to label a result you must
join back on `call_id`.

```json
{ "type":"response_item","payload":{ "type":"function_call",
    "name":"exec_command",
    "arguments":"{\"cmd\":[\"/bin/zsh\",\"-lc\",\"<CMD>\"],\"workdir\":\"<PATH>\",\"max_output_tokens\":10000,\"yield_time_ms\":250}",
    "call_id":"call_TMg3Szj<…>" } }
{ "type":"response_item","payload":{ "type":"function_call_output",
    "call_id":"call_TMg3Szj<…>","output":"<STDOUT/RESULT — redacted>" } }
```

```json
// MCP-namespaced function_call
{ "type":"response_item","payload":{ "type":"function_call",
    "name":"codegraph_explore","namespace":"mcp__codegraph",
    "arguments":"{\"query\":\"<QUERY>\"}","call_id":"call_Xja1jnx<…>" } }
```

```json
// custom_tool_call (apply_patch) — uses `input`, not `arguments`
{ "type":"response_item","payload":{ "type":"custom_tool_call",
    "name":"apply_patch",
    "input":"*** Begin Patch\n*** Update File: <PATH>\n<DIFF>\n*** End Patch",
    "call_id":"call_<…>","status":"completed" } }
```

**Error flags & telemetry.** Built-in tool errors surface as non-zero `exec_command_end.exit_code`
or `patch_apply_end.success=false`; MCP errors surface in `mcp_tool_call_end.result` which is a
Rust-`Result` tagged union: `{"Ok":{"content":[{"type":"text",…}],"is_error":null}}` **or**
`{"Err":"<error string>"}`.

### Review mode — `entered_review_mode` / `exited_review_mode`

Codex's built-in code-review feature brackets a review pass with two `event_msg` records.
`entered_review_mode.target` is **polymorphic** by `target.type`, and
`exited_review_mode.review_output` carries a **structured code-review payload** (a findings
array), not free text.

| Record / payload.type | Keys | Notes |
|---|---|---|
| `entered_review_mode` | `{type, target, user_facing_hint}` | `target` polymorphic: `{type:"uncommittedChanges"}` \| `{type:"custom", instructions}` \| `{type:"baseBranch", branch}` \| `{type:"commit", sha, title}` (observed counts: 9 / 8 / 3 / 6). |
| `exited_review_mode` | `{type, review_output}` | `review_output` = `{overall_correctness, overall_confidence_score, overall_explanation, findings[]}`. |
| `review_output.findings[]` | `{title, body, priority, confidence_score, code_location}` | **structured per-finding review data** — `priority` int, `confidence_score` float, `code_location` a `file:line` ref. |

> **Engram drops both review-mode events** — the structured `findings[]` (which is arguably
> the richest derived artifact in the whole rollout) is invisible to Engram. (evidence: jq
> payload inspection — `entered_review_mode` keys `[target, type, user_facing_hint]` with 4
> distinct `target.type` shapes; `exited_review_mode.review_output.findings[]` keys
> `[body, code_location, confidence_score, priority, title]`.)

**Engram tool handling.** `function_call` → one `tool`-role message `"<name> <args(truncated
500)>"`, counted **once** in `toolCount`. `function_call_output` → a `tool`-role message
(output truncated 2000), **not re-counted** (avoids doubling). Adapters do **not** join
call↔output; they emit each as a separate message for transcript display. This means
full-stream transcript length can legitimately exceed `SessionInfo.messageCount`: the
2026-07-02 retained-TS smoke parsed 701,043 session-counted messages but streamed 1,195,657
display messages, with 2,564 sessions differing because `function_call_output` is displayable
but not counted as an additional tool use. `custom_tool_call*`, `web_search_call`,
`tool_search_*`, and all `event_msg` tool telemetry are dropped.

---

## Reasoning / thinking

Reasoning (chain-of-thought) is stored as `response_item.payload.type == "reasoning"`. The
real CoT is normally **encrypted**; a plaintext summary appears only when reasoning-summary
is enabled.

| Field | Type | Meaning | When present |
|---|---|---|---|
| `type` | `"reasoning"` | discriminator | always |
| `encrypted_content` | string (opaque encrypted blob, observed `gAAAAAB…` prefix) | opaque encrypted CoT blob. Confirmed (official): source types this only as `Option<String>` and does NOT state any encryption scheme — the "Fernet-style" label and `gAAAAAB` prefix are observational, not source-stated. ([models.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/models.rs)) | almost always |
| `summary` | array of `{type:"summary_text", text}` (L3) | plaintext reasoning summary | always present, often empty `[]` |
| `content` | array | legacy raw reasoning blocks (empty in practice) | legacy key-combo only |
| `metadata` | object `{turn_id}` | links reasoning to its turn | newer |
| `id` | string (`rs_…`) | server reasoning id | newest (Jun 2026) |

Observed key-combos (frequency order): `[encrypted_content, summary, type]` (most common),
`[encrypted_content, metadata, summary, type]`, `[content, encrypted_content, summary, type]`
(legacy), `[encrypted_content, id, metadata, summary, type]` (newest).

```json
// reasoning, encrypted only (most common)
{ "type":"response_item","payload":{
    "type":"reasoning","summary":[],"encrypted_content":"gAAAAABqIEApny6G7M8X<…>" } }
```
```json
// reasoning with plaintext summary + metadata (newer)
{ "type":"response_item","payload":{
    "type":"reasoning",
    "summary":[ { "type":"summary_text","text":"<REASONING SUMMARY — redacted>" } ],
    "encrypted_content":"gAAAAAB<…>",
    "metadata":{ "turn_id":"019ee4ad-7753-7311-b6cb-12d0aeabce2a" } } }
```
```json
// newest (Jun 2026) — adds id
{ "type":"response_item","payload":{
    "type":"reasoning","id":"rs_02a<…>","summary":[],
    "encrypted_content":"gAAAAAB<…>","metadata":{ "turn_id":"<uuid>" } } }
```

A **legacy** plaintext path also exists at `event_msg.payload.type == "agent_reasoning"`
(`{type, text}`); modern Codex encrypts reasoning inside `response_item` instead.

> **Engram drops all reasoning.** Neither adapter handles `reasoning` or `agent_reasoning` —
> the `message(from:)` switch only matches `message`/`function_call`/`function_call_output`,
> so reasoning is invisible to Engram's transcript, search, and counts.

---

## Token usage & cost

### The `token_count` event (authoritative usage source)

`event_msg.payload.type == "token_count"`. VERIFIED `info` keys:
`[total_token_usage, last_token_usage, model_context_window]`; both `*_token_usage` objects
share `[input_tokens, cached_input_tokens, output_tokens, reasoning_output_tokens, total_tokens]`.

| Field | Type | Meaning |
|---|---|---|
| `info` | object \| **null** | usage container; **null** when the API returned no usage (interrupted / credits exhausted) — adapters skip these |
| `info.total_token_usage` | object | **Cumulative running total** for the whole session. `input_tokens` grows to millions (each turn re-sends full context). **Do NOT sum these.** |
| `info.last_token_usage` | object | **Per-turn (last API call) usage** — this is what Engram sums |
| `info.model_context_window` | int | model max context (e.g. `258400`, `400000`) |
| `rate_limits` | object | plan & quota windows (see below) |

`*_token_usage` sub-fields:

| Sub-field | Type | Meaning | Engram use |
|---|---|---|---|
| `input_tokens` | int | total prompt tokens (**includes** cached) | `inputTokens = max(input_tokens − cached_input_tokens, 0)` (uncached only) |
| `cached_input_tokens` | int | prompt tokens served from cache | → `cacheReadTokens` |
| `output_tokens` | int | completion tokens (**includes** reasoning) | → `outputTokens` |
| `reasoning_output_tokens` | int | subset of output that is reasoning/CoT | **observed but NOT split out** — folded into `output_tokens` |
| `total_tokens` | int | `input + output` convenience sum | not used |

`rate_limits` keys: `[limit_id, limit_name, primary, secondary, credits, individual_limit,
plan_type, rate_limit_reached_type]`. `primary`/`secondary` are `{used_percent,
window_minutes, resets_at(epoch s)}`; `credits` is `{has_credits, unlimited, balance}` or
`null`; `plan_type` ∈ `{pro, premium, null}`. **None of `rate_limits` is consumed by the
rollout adapters.**

```json
{
  "timestamp": "2026-06-21T07:37:41.090Z",
  "type": "event_msg",
  "payload": {
    "type": "token_count",
    "info": {
      "total_token_usage": { "input_tokens": 33804, "cached_input_tokens": 2432, "output_tokens": 815, "reasoning_output_tokens": 516, "total_tokens": 34619 },
      "last_token_usage":  { "input_tokens": 33804, "cached_input_tokens": 2432, "output_tokens": 815, "reasoning_output_tokens": 516, "total_tokens": 34619 },
      "model_context_window": 258400
    },
    "rate_limits": {
      "limit_id": "codex", "limit_name": null,
      "primary":   { "used_percent": 1.0, "window_minutes": 300,   "resets_at": 1782044976 },
      "secondary": { "used_percent": 6.0, "window_minutes": 10080, "resets_at": 1782613776 },
      "credits": null, "individual_limit": null, "plan_type": "pro", "rate_limit_reached_type": null
    }
  }
}
```

```json
// info:null variant (no usage returned) — tokenCountUsage returns nil, event skipped
{ "type":"event_msg","payload":{ "type":"token_count","info":null,
    "rate_limits":{ "limit_id":"premium","limit_name":null,"primary":null,"secondary":null,
      "credits":{"has_credits":false,"unlimited":false,"balance":"0"},
      "individual_limit":null,"plan_type":null,"rate_limit_reached_type":null } } }
```

### Engram token extraction (identical TS + Swift)

`tokenCountUsage()` (`codex.ts` L297-328; `CodexAdapter.swift` L518-545):
1. Match `event_msg` → `token_count` → `info.last_token_usage` (NOT `total_token_usage`).
2. `inputTokens = max(input_tokens − cached_input_tokens, 0)`, `outputTokens = output_tokens`,
   `cacheReadTokens = cached_input_tokens`, `cacheCreationTokens = 0` (Codex has no
   cache-write metric).
3. Drop the event if all four are zero.

Attribution (`streamMessages`, `codex.ts` L184-265; `CodexAdapter.swift` L419-449): each
`token_count` usage is attached to the **pending non-user (assistant/tool) message**.
Multiple `token_count` events before a message are `mergeUsage`-summed.
`pendingUsageCameFromTokenCount` guards against overwriting a real assistant `payload.usage`
with token-count data. Net effect: **per-turn usages are summed across the session** → a
correct total without the `total_token_usage` double-count.

### How cost is derived

Cost is a **TypeScript reference-only** path: `src/core/pricing.ts` `MODEL_PRICING` (USD per
1M tokens, fields `input/output/cacheRead/cacheWrite`), with `getModelPrice()` doing exact →
longest-prefix match. The indexer accumulates `inputTokens/outputTokens/cacheReadTokens/
cacheCreationTokens` and persists to `session_costs`; `get_costs` SUMs `cost_usd` grouped by
model/source/project/day.

> **Cost blind spot (real).** `MODEL_PRICING` has **no entry** for the Codex models actually
> in these rollouts (`gpt-5.5`, `gpt-5.4`, `gpt-5.3-codex`, `gpt-5.4-mini`,
> `gpt-5.3-codex-spark`, `gpt-5.1-codex-mini`). The prefix matcher will NOT map `gpt-5.*` to
> any `gpt-4*`/`o*` entry → **current Codex sessions get zero cost**. `reasoning_output_tokens`
> is also never priced separately. Per CLAUDE.md the TS pricing is reference-only; whether the
> Swift product has its own pricing path is unverified.

---

## Subagent / parent-child / dispatch

Codex has **two unrelated "subagent" concepts**. Engram currently consumes only the first.

### (A) External dispatch by Claude Code (Engram Layer-1b) — the only one Engram uses

When Claude Code dispatches Codex as a child agent, the **only on-disk signal** is
`session_meta.originator == "Claude Code"`. This session is **absent** from
`thread_spawn_edges` (verified). Engram's rule (both adapters):

```
effectiveRole = explicit agent_role ?? (originator is Claude Code ? "dispatched" : nil)
```

- TS (`codex.ts` L121-126): strict exact compare `originator === 'Claude Code'`.
- Swift (`CodexAdapter.swift` L322-324 → `OriginatorClassifier.isClaudeCode`,
  `SessionAdapter.swift` L23-32): **normalizes** before comparing — trim → lowercase →
  `_`→`-` → space→`-`, then `== "claude-code"`. So `"Claude Code"`, `"claude_code"`,
  `"CLAUDE-CODE"` all match.

> **TS vs Swift discrepancy:** a session with `originator: "claude_code"` or `"claude-code"`
> is dispatched by **Swift** (the product) but NOT by **TS** (reference). This can cause
> indexed-by-Swift vs reference-TS test mismatches. The Swift product is the source of truth.

Downstream (`src/core/db/maintenance.ts` `backfillCodexOriginator` L365-410): a dispatched
Codex session gets `agent_role='dispatched'`, **`tier='skip'`**, and `link_checked_at=NULL`
so it re-enters parent scoring. `readCodexOriginator()` reads only the first JSONL line. Net:
a Claude-Code-dispatched Codex rollout is hidden (tier skip), accessed through its Claude Code
parent, and excluded from independent display.

### (B) Codex's NATIVE subagent spawn tree (`multi_agent_version: "v1"`) — NOT consumed by Engram

Codex's own multi-agent feature spawns child threads (roles `explorer`/`worker`/`awaiter`/
`default`, plus third-party `lazycodex-*`/`metis`). This is recorded in **three redundant
places** in the rollout + DB:

1. `session_meta.parent_thread_id` (top-level of payload).
2. `session_meta.source` as a JSON object (the polymorphic source):
   `{"subagent":{"thread_spawn":{"parent_thread_id","depth","agent_path","agent_nickname","agent_role"}}}`.
   A simpler form `{"subagent":"review"}` tags review subagents.
3. `state_5.sqlite.thread_spawn_edges` — the authoritative parent→child graph.

The `parent_thread_id` appears **twice** (top-level AND nested in `source.subagent.thread_spawn`),
both equal, both feed `thread_spawn_edges`.

#### (B-4) The `collab_*` event family — the PARENT-side rollout record of native spawning

There is a **fourth** on-disk recording of the native spawn graph that the "three redundant
places" list above misses, and it is the most directly actionable one: the
**`collab_*` `event_msg` family written into the PARENT's own rollout file.** Where
`parent_thread_id` / `source.subagent` / `thread_spawn_edges` are all *child-side* (a child
records who its parent was, or the DB records it after the fact), `collab_agent_spawn_end`
records the relationship **inline in the parent's JSONL** the moment the parent spawns a
child — sender→child, with role/nickname/prompt/model — so the full edge is readable from the
parent file alone, **without** touching the SQLite `thread_spawn_edges` table.

These events are emitted by the native multi-agent **tool calls** the parent issues:
`spawn_agent` (function_call) → `collab_agent_spawn_end`; `wait_agent` → `collab_waiting_end`;
`close_agent` → `collab_close_end`; an agent-to-agent message → `collab_agent_interaction_end`;
`resume_agent` → `collab_resume_end`. Full-corpus function_call name counts: `spawn_agent`
2085, `close_agent` 1348, `wait_agent` 1269, `resume_agent` 3.

| `event_msg` payload.type | Keys | Direction & meaning |
|---|---|---|
| `collab_agent_spawn_end` | `{type, call_id, sender_thread_id, new_thread_id, new_agent_nickname, new_agent_role, prompt, model, reasoning_effort, status}` | **parent→new child edge** (`sender_thread_id`→`new_thread_id`). Carries the spawned child's role/nickname/prompt/model inline. `status` e.g. `pending_init`. This is the deterministic Layer-1 parent→child signal. |
| `collab_waiting_end` | `{type, call_id, sender_thread_id, agent_statuses, statuses}` | parent waited on its children; `statuses` is a map `{child_thread_id: {completed: "<child result text>"}}` (and a parallel `agent_statuses`). Surfaces child completion results back into the parent transcript. |
| `collab_close_end` | `{type, call_id, sender_thread_id, receiver_thread_id, receiver_agent_nickname, receiver_agent_role, status}` | parent closed a child (`sender`→`receiver`); `status` is an object `{completed: "<final child summary>"}`. |
| `collab_agent_interaction_end` | `{type, call_id, sender_thread_id, receiver_thread_id, receiver_agent_nickname, receiver_agent_role, prompt, status}` | sender↔receiver message exchange; `prompt` = what was asked, `status.completed` = the receiver's reply. |
| `collab_resume_end` | `{type, call_id, sender_thread_id, receiver_thread_id, receiver_agent_nickname, receiver_agent_role, status}` | parent resumed a paused child; `status.completed` = the resumed child's output. (rare — 1 in corpus) |

> **This is a deterministic Layer-1 parent→child signal that Engram does not mine.** A single
> pass over a parent's JSONL yields the complete set of children it spawned (sender→child
> edges, with role and nickname) directly from `collab_agent_spawn_end`, with no SQLite read
> required — strictly more available than the child-side `parent_thread_id`, and not subject
> to the `thread_spawn_edges` table even existing. Engram reads none of the `collab_*` events
> (they hit the adapter's default drop branch). (evidence: per-type payload key inspection of
> `collab_agent_spawn_end`/`collab_waiting_end`/`collab_close_end`/`collab_agent_interaction_end`/
> `collab_resume_end`; function_call name histogram `spawn_agent`/`wait_agent`/`close_agent`/`resume_agent`.)

**`session_meta.source` polymorphism** (string in old/normal CLI, object for subagents).
DB `threads.source` distribution (verbatim copy of the meta source), grouped by the
`{"subagent":{"thread_spawn":{...}}}` prefix:

| `source` | Count | Note |
|---|---|---|
| `{"subagent":{"thread_spawn":{...}}}` | **1623** | **LARGEST single category** — native spawned subagents; each blob differs only in the nested parent/depth/role, but they all share this prefix. **61% of all 2664 threads.** Exactly equals `thread_spawn_edges` row count (1623). |
| `cli` | 481 | interactive terminal |
| `vscode` | 471 | Codex VS Code / desktop app |
| `exec` | 65 | headless `codex exec` |
| `{"subagent":"review"}` | 18 | review subagents (simple string form; NOT in `thread_spawn_edges`) |
| `unknown` | 6 | unclassified |

> This store is **majority-subagent**: the `{subagent:{thread_spawn}}` form is the dominant
> single category (1623), not a scattered long tail. Any naive consumer that treats `source`
> as a small enum of strings will misclassify the majority of rows. (evidence:
> `sqlite3 state_5.sqlite` GROUP BY on the `source` prefix; `thread_spawn_edges` COUNT = 1623.)

> **Neither Engram adapter reads `meta.source`.** The rich `{subagent:{thread_spawn:{...}}}`
> parent/depth/role graph is currently **un-mined** — a deterministic Layer-1 signal beyond
> `parent_thread_id` that Engram could consume.

```json
// session_meta — subagent (NEW format) — key structure intact, content redacted
{
  "timestamp": "2026-06-21T06:06:38.238Z",
  "type": "session_meta",
  "payload": {
    "id": "019ee8c9-c5b3-78f0-bdc2-ab4c8e024293",
    "parent_thread_id": "019ee02d-c140-7813-8897-56f02fb68e88",
    "timestamp": "2026-06-21T06:06:38.051Z",
    "cwd": "/Users/<user>/<project>",
    "originator": "Codex Desktop",
    "cli_version": "0.142.0-alpha.6",
    "source": { "subagent": { "thread_spawn": {
        "parent_thread_id": "019ee02d-c140-7813-8897-56f02fb68e88",
        "depth": 1, "agent_path": null, "agent_nickname": "<name>", "agent_role": "explorer" } } },
    "thread_source": "subagent",
    "agent_nickname": "<name>", "agent_role": "explorer",
    "model_provider": "openai",
    "base_instructions": { "text": "<system prompt — redacted>" },
    "multi_agent_version": "v1",
    "git": { "commit_hash": "<sha>", "branch": "main" }
  }
}
```

> **Distinction the synthesizer must keep:** `thread_spawn_edges` records ONLY concept (B)
> (Codex internal spawning), never concept (A) (Claude Code dispatch). Engram consumes ONLY
> (A). Codex native subagents (explorer/worker/awaiter) are therefore likely surfaced by
> Engram as independent sessions today.

---

## Summary / compaction

When the context window fills, Codex compacts. This produces **two paired records at two
layers** (verified 1:1 in scans):

### `compacted` — TOP-LEVEL (L1) record (the persistence record)

`payload` keys: `message`, `replacement_history`, and (newer) `window_id`, then (newest)
`window_number`. A full-corpus scan of every `compacted` record found **three key-set
generations**: `[message, replacement_history]` × **2050**, `+ window_id` × **113**, and
`+ window_id + window_number` × **55** — i.e. the newest CLI emits BOTH `window_id` and
`window_number`. (evidence: jq full-corpus `compacted` key-set histogram: 2050 / 113 / 55.)

Confirmed (official) — and a correction: the authoritative `CompactedItem` struct
([protocol.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs))
is `{ message: String, replacement_history: Option<Vec<ResponseItem>>, window_number:
Option<u64>, first_window_id: Option<String>, previous_window_id: Option<String>, window_id:
Option<String> }`. The window-field **types in older drafts of this doc were inverted**:
`window_number` is the integer (`u64`) monotonic counter; `window_id` is a **UUIDv7 string**
(the identity of this context window), NOT an int counter. There are also two fields beyond
the key-set histogram: `first_window_id` and `previous_window_id` (both UUIDv7 strings,
forming the window chain). The on-disk `"window_id": 1` examples below reflect an OLDER CLI
generation; current source makes `window_id` a UUID string and `window_number` the integer.

| Field | Type | Meaning | Optional? |
|---|---|---|---|
| `message` | string | compaction/summary text (often `""`; the summary often lives inside `replacement_history` developer turns) | required |
| `replacement_history` | array of message objects (`Option<Vec<ResponseItem>>`) | **the rebuilt context** that replaces prior turns. Each entry is `{type:"message", role, content:[{type:"input_text", text}]}`. Roles include `user`, `developer`, `assistant`. | optional in source |
| `window_number` | int (`u64`) | **the integer monotonic compaction counter** (1, 2, …) — the actual generation counter | newest only (55 records) |
| `window_id` | string (UUIDv7) | **UUIDv7 identity of this context window** — a string id, NOT an int counter (older on-disk samples show `1`, an earlier CLI generation) | newer (2026-06+); absent earlier |
| `first_window_id` | string (UUIDv7) \| null | first window in the compaction chain (source-confirmed; not in the corpus key-set histogram) | source field |
| `previous_window_id` | string (UUIDv7) \| null | previous window in the compaction chain (source-confirmed) | source field |

```json
{
  "timestamp": "2026-06-21T02:37:49.013Z",
  "type": "compacted",
  "payload": {
    "message": "",
    "window_id": 1,
    "replacement_history": [
      { "type": "message", "role": "user",
        "content": [ { "type": "input_text", "text": "<earlier user msg — redacted>" } ] },
      { "type": "message", "role": "developer",
        "content": [ { "type": "input_text", "text": "<permissions block — redacted>" },
                     { "type": "input_text", "text": "<more — redacted>" } ] }
    ]
  }
}
```

### `context_compacted` — NESTED (L2) inside `event_msg` (the marker)

A pure marker — `payload` is just the type tag. VERIFIED: `{'type': 'context_compacted'}`,
no body.

```json
{ "timestamp":"2026-03-03T08:02:58.056Z","type":"event_msg","payload":{ "type":"context_compacted" } }
```

### How the session continues across compaction

Compaction is visible in the token stream: immediately after a compaction, the next turn's
`last_token_usage.input_tokens` drops to **0** then climbs from a small base, while
`total_token_usage.input_tokens` keeps its lifetime cumulative climb. The session continues
**in the same rollout file** (same UUID); the live model context was reset but the file is
appended to.

> **Engram gap.** Neither adapter handles `compacted` or `context_compacted`. The
> `replacement_history` turns (which may include user/assistant content that predates
> compaction) are **invisible** to Engram's transcript, search, and `messageCount`. A
> heavily-compacted long session shows only its post-compaction live messages. Skipping the
> *duplicate* compacted context is arguably correct, but pre-compaction turns that survive
> only in `replacement_history` are data-loss for Engram.

---

## (Codex only) SQLite stores

> Claude Code has no SQLite session store; **Codex does.** This section documents it. The
> rollout JSONL is authoritative for *content*; SQLite is authoritative for *state / index /
> relationships / derived data*. Link: `threads.id == rollout filename UUID ==
> session_meta.payload.id`, and `threads.rollout_path` points at the on-disk `.jsonl`.

### Database inventory (active vs legacy)

| Path | Size | Status | Role |
|---|---|---|---|
| `~/.codex/state_5.sqlite` | 16 MB | **ACTIVE** | thread catalog + agent-job + spawn graph (migration **40**, 2664 threads) |
| `~/.codex/memories_1.sqlite` | 940 KB | **ACTIVE** | memory-extraction pipeline |
| `~/.codex/goals_1.sqlite` | 60 KB | **ACTIVE** | long-running thread goals |
| `~/.codex/logs_2.sqlite` | **1.3 GB** | **ACTIVE** | structured Rust app/trace logs |
| `~/.codex/sqlite/state_5.sqlite` | 15 MB | **LEGACY** | older generation (migration **35**, 2267 threads, no `recency_at`) |
| `~/.codex/sqlite/memories_1.sqlite` | 40 KB | **LEGACY** | migration 1 |
| `~/.codex/sqlite/goals_1.sqlite` | 24 KB | **LEGACY** | migration 1 |
| `~/.codex/sqlite/logs_2.sqlite` | 29 MB | **LEGACY** | migration 2 |
| `~/.codex/sqlite/codex-dev.db` | 36 KB | **LEGACY / dev** | desktop app-server (inbox, automations) — not a session store |

**Generation suffix vs migration count.** The `_N` filename suffix is a **schema-family
generation** (hard reset → new file). Inside each file the `_sqlx_migrations` table
(`version, description, installed_on, success, checksum, execution_time`) is the incremental
ledger. The `state_5` ledger is a changelog of the mechanism's evolution — tell-tale entries:
`1 threads`, `2 logs` → `23 drop logs` (logs split to `logs_N`), `6/16 memories` →
`35 drop memory tables` (split to `memories_1`), `29 thread goals` → `34 drop thread goals`
(split to `goals_1`), `21 thread spawn edges`, `24 remote control enrollments`,
`38 external agent config imports`, `39 threads recency at`, `40 threads history mode`
(newest; legacy DB lacks the `recency_at`/`recency_at_ms` columns and migration 40's
thread-history-mode additions). This is *why* there
are four DB files: tables that grow huge (logs) or are independently versioned (memories,
goals) were carved out of `state_5` into their own generation-suffixed files.

### `state_5.sqlite` (the heart)

Tables: `threads`, `thread_dynamic_tools`, `thread_spawn_edges`, `agent_jobs`,
`agent_job_items`, `backfill_state`, `remote_control_enrollments`,
`external_agent_config_imports`, `_sqlx_migrations`.

#### `threads` — the rollout session index (2,664 rows; one per rollout)

| Column | Type | Meaning | Example |
|---|---|---|---|
| `id` | TEXT PK | thread UUID = rollout filename UUID = `session_meta.id` | `019ee91c-8298-7c32-...` |
| `rollout_path` | TEXT NOT NULL | abs path to the rollout `.jsonl` (the disk↔DB join) | `~/.codex/sessions/2026/06/21/rollout-...jsonl` (or `archived_sessions/...`) |
| `created_at` / `updated_at` | INTEGER (unix s) | start / last-activity | `1782027420` |
| `created_at_ms` / `updated_at_ms` | INTEGER | ms-precision mirrors (auto-filled by triggers, migration 25) | `1782027420000` |
| `recency_at` / `recency_at_ms` | INTEGER (default 0) | "recent" sort key seeded from `updated_at` via trigger (migration 39; absent in legacy DB) | `1782027438` |
| `source` | TEXT NOT NULL | **polymorphic**: plain string (`vscode`/`cli`/`exec`/`unknown`) OR JSON subagent object — verbatim copy of `session_meta.source` | `"vscode"` / `{"subagent":{"thread_spawn":{...}}}` |
| `model_provider` | TEXT NOT NULL | provider (2509 `openai`, 1 `custom`) | `"openai"` |
| `model` | TEXT (nullable) | concrete model | `gpt-5.5`(1302), `gpt-5.4`(522), `gpt-5.3-codex`(409), `gpt-5.4-mini`(199), `gpt-5.3-codex-spark`(23), `gpt-5.1-codex-mini`(4), NULL(51) |
| `reasoning_effort` | TEXT (nullable) | `high`/`xhigh`/`low`/`medium`/NULL | `xhigh` |
| `cwd` | TEXT NOT NULL | working dir | `/Users/<user>/<repo>` |
| `title` | TEXT NOT NULL | auto-generated title (mirrors `session_index.thread_name`) | `<title>` |
| `preview` | TEXT NOT NULL (default '') | short preview; partial indexes filter `preview <> ''` (visible rows) | `<preview>` |
| `first_user_message` | TEXT NOT NULL (default '') | cached first user prompt | `<prompt>` |
| `sandbox_policy` | TEXT NOT NULL | JSON: `{"type":"workspace-write",...}` / `managed` / `disabled` / `read-only` / `danger-full-access` | `{"type":"disabled"}` |
| `approval_mode` | TEXT NOT NULL | `never`(2422)/`on-request`(88) | `never` |
| `tokens_used` | INTEGER (default 0) | cumulative tokens for the thread | `679270` |
| `has_user_event` | INTEGER (default 0) | bool: did a real user interact | `0` / `1` |
| `archived` / `archived_at` | INTEGER / INTEGER | archive flag (5 rows =1) + time | `0` / null |
| `git_sha` / `git_branch` / `git_origin_url` | TEXT (nullable) | repo context | `main` |
| `cli_version` | TEXT NOT NULL (default '') | Codex version that wrote it | `0.141.0` |
| `agent_nickname` / `agent_role` | TEXT (nullable) | subagent identity (`explorer`871/`worker`293/`awaiter`214/`default`103/`lazycodex-*`/`metis`/empty 1006) | `Epicurus` / `explorer` |
| `agent_path` | TEXT (nullable) | agent definition path | null |
| `thread_source` | TEXT (nullable) | `user`(238)/`subagent`(611)/NULL(1661) | `subagent` |
| `memory_mode` | TEXT NOT NULL (default 'enabled') | memory eligibility: `enabled`(2092)/`polluted`(418) | `enabled` |

**Indexes** (heavily optimized for list views): `created_at`, `updated_at`,
`created_at_ms`, `updated_at_ms`, `recency_at_ms`, `archived`, `source`, `model_provider`,
composites `(archived, cwd, *_ms DESC, id DESC)` for per-project recency, and **partial
indexes** `WHERE preview <> ''` for "visible threads only". **Triggers** auto-populate `*_ms`
and `recency_at` on insert/update.

```json
// threads row (subagent), anonymized
{
  "id": "019ee8db-ef59-7cc0-8911-e47edb28f2c9",
  "rollout_path": "/Users/<user>/.codex/sessions/2026/06/21/rollout-2026-06-21T14-26-28-019ee8db-...jsonl",
  "created_at": 1782023188, "updated_at": 1782023395,
  "source": "{\"subagent\":{\"thread_spawn\":{\"parent_thread_id\":\"019ee02d-...\",\"depth\":1,\"agent_path\":null,\"agent_nickname\":\"Epicurus\",\"agent_role\":\"default\"}}}",
  "model_provider": "openai", "model": "gpt-5.5", "reasoning_effort": "medium",
  "cwd": "/Users/<user>/<repo>", "title": "<title>",
  "sandbox_policy": "{\"type\":\"disabled\"}", "approval_mode": "never",
  "tokens_used": 1450054, "has_user_event": 0, "archived": 0,
  "git_sha": "f2fb1d69...", "git_branch": "main", "cli_version": "0.142.0-alpha.6",
  "agent_nickname": "Epicurus", "agent_role": "default",
  "memory_mode": "enabled", "thread_source": "subagent", "recency_at": 1782023188
}
```

#### `thread_spawn_edges` — the subagent parent→child graph (1,623 rows)

```sql
CREATE TABLE thread_spawn_edges (
    parent_thread_id TEXT NOT NULL,
    child_thread_id  TEXT NOT NULL PRIMARY KEY,   -- a child has exactly one parent
    status           TEXT NOT NULL                 -- closed(834) / open(727)
);
CREATE INDEX idx_thread_spawn_edges_parent_status ON thread_spawn_edges(parent_thread_id, status);
```

| Column | Type | Meaning |
|---|---|---|
| `parent_thread_id` | TEXT NOT NULL | spawning (parent) thread `id` |
| `child_thread_id` | TEXT PK | spawned (child) subagent thread `id` |
| `status` | TEXT | `closed`(884) / `open`(739) — inferred live-vs-finished spawn relationship |

**Referential integrity verified:** all 1623 edges have both endpoints in `threads`. Top
parents fan out widely (one parent → 129 children) — orchestrators dispatching subagent
swarms. The `parent_thread_id` inside `threads.source` JSON equals
`thread_spawn_edges.parent_thread_id` for the same child (redundant encodings). **`review`
subagents (`{"subagent":"review"}`, 18) are NOT in `thread_spawn_edges`** — their provenance
is only the `source` string tag. So a complete subagent topology requires reading
`thread_spawn_edges` + the `source` tag, not just `thread_source`.

#### `agent_jobs` / `agent_job_items` — async batch-agent execution (0 rows here)

The "run an agent over a CSV of inputs" feature; each row → one agent run on a spawned thread.

`agent_jobs`: `id` PK, `name`, `status`, `instruction`, `output_schema_json`,
`input_headers_json`, `input_csv_path`, `output_csv_path`, `auto_export` (default 1),
`created_at`/`updated_at`/`started_at`/`completed_at`, `last_error`, `max_runtime_seconds`.

`agent_job_items`: PK `(job_id, item_id)` (FK → `agent_jobs(id)` CASCADE), `row_index`,
`source_id`, `row_json`, `status`, `assigned_thread_id` (the spawned thread processing this
row → links to `threads`), `attempt_count`, `result_json`, `last_error`, timestamps.

#### `thread_dynamic_tools` — per-thread tool registry (106 rows)

PK `(thread_id, position)` (FK → `threads` CASCADE), `name`, `description`, `input_schema`
(JSON), `defer_loading` (default 0, migration 19), `namespace` (nullable, migration 26).
Examples: `read_thread_terminal`, `automation_update`.

#### Singleton / control tables

- `backfill_state` (CHECK id=1, single row): rollout→DB backfill cursor —
  `status, last_watermark, last_success_at, updated_at`. Observed `status='complete'`,
  `last_watermark='sessions/2026/02/25/rollout-...'`.
- `remote_control_enrollments` (1 row): web/desktop pairing —
  `websocket_url, account_id, app_server_client_name` (PK), `server_id, environment_id,
  server_name, updated_at, remote_control_enabled` (migration 37).
- `external_agent_config_imports` (0 rows, migration 38): `import_id` PK, `completed_at_ms`,
  `successes` TEXT, `failures` TEXT (likely JSON arrays — unsampled).

### `memories_1.sqlite` — memory-extraction pipeline

Two tables. A **two-stage pipeline**: stage1 extracts per-thread memory → selected → global
consolidation.

`stage1_outputs` (83 rows): `thread_id` PK, `source_updated_at` (staleness check),
`raw_memory`, `rollout_summary`, `rollout_slug` (nullable, migration 9), `generated_at`,
`usage_count`, `last_usage`, `selected_for_phase2` (default 0, migration 17),
`selected_for_phase2_source_updated_at`.

`jobs` (97 rows): a leased work-queue — PK `(kind, job_key)` (`job_key` = thread_id),
`status` (`done`86/`error`10), `worker_id`, `ownership_token`,
`started_at/finished_at/lease_until/retry_at`, `retry_remaining`, `last_error`,
`input_watermark/last_success_watermark`. `kind` ∈ `{memory_stage1, memory_consolidate_global}`.

### `goals_1.sqlite` — long-running thread goals (`thread_goals`, 57 rows)

`thread_id` PK, `goal_id`, `objective`, `status` CHECK ∈
`{active, paused, blocked, usage_limited, budget_limited, complete}`, `token_budget`,
`tokens_used` (default 0; up to 34M observed), `time_used_seconds` (up to ~107k s ≈ 30 h),
`created_at_ms`/`updated_at_ms`. These are multi-day autonomous "keep working toward X" goals.

### `logs_2.sqlite` — structured app/trace logs (1.3 GB; schema + COUNT only)

Single big `logs` table (~419k rows, AUTOINCREMENT): `id` PK, `ts` (unix s), `ts_nanos`,
`level` (`INFO`/`TRACE`/`DEBUG`/`WARN`/`ERROR`), `target`, `feedback_log_body` (message body,
nullable), `module_path`/`file`/`line` (nullable), `thread_id` (nullable; joins to `threads`),
`process_uuid` (`pid:<pid>:<uuid>`, migration 10), `estimated_bytes` (retention/pruning,
migration 12). Indexes: `idx_logs_ts`, `idx_logs_thread_id`, `idx_logs_thread_id_ts`, and a
**partial** `idx_logs_process_uuid_threadless_ts WHERE thread_id IS NULL`. This is
observability/diagnostics, not session content — least useful for reconstruction, hence the
size warning. **Never dump it; only `.schema` and `LIMIT`/`COUNT`.**

### `sqlite/codex-dev.db` — desktop dev DB (out of scope)

Different schema: `automation_runs`, `automations`, `inbox_items`,
`local_app_server_feature_enablement`. Not part of the session/rollout mechanism.

### Rollout JSONL ↔ SQLite mapping (the link layer)

The `threads` row is materialized from `session_meta`:

| `session_meta.payload` field | → `threads` column | notes |
|---|---|---|
| `id` | `id` (PK) | == filename UUID |
| `cwd` | `cwd` | |
| `cli_version` | `cli_version` | |
| `model_provider` | `model_provider` | |
| `source` | `source` | copied verbatim (string or JSON) |
| `thread_source` | `thread_source` | `user`/`subagent` |
| `agent_nickname` / `agent_role` | `agent_nickname` / `agent_role` | subagent only |
| `parent_thread_id` | → `thread_spawn_edges.parent_thread_id` | drives the spawn graph |
| `git.commit_hash` / `git.branch` | `git_sha` / `git_branch` | nested `git` object |
| `originator` | (not a column; JSONL only) | e.g. `Codex Desktop`, `Claude Code` — Engram uses this |
| `multi_agent_version`, `base_instructions` | (not stored) | JSONL only |

> Edge case: JSONL `session_meta` may omit `timestamp` (TS falls back to `lastTimestamp`/
> mtime; Swift requires it and fails parse if absent), but DB `created_at` is always populated
> — so the DB is a more reliable start-time source in edge cases.

---

## Auxiliary files

### `history.jsonl` — cross-session user-input history (3.9 MB; flat shape, NOT the envelope)

| Field | Type | Meaning | Example |
|---|---|---|---|
| `session_id` | string (UUID) | owning session; joins to rollout/`threads` | `"019ee858-92b6-7853-ba71-074b9c042711"` |
| `ts` | int (Unix **seconds**) | when the input was submitted | `1757248180` |
| `text` | string | the user's raw prompt text (full, not truncated) | `"<prompt — redacted>"` |

```json
{ "session_id":"019ee858-92b6-7853-ba71-074b9c042711", "ts":1757248180, "text":"<user prompt>" }
```

> Caveat: a minority of lines use legacy **UUIDv4** `session_id`s (pre-v7 sessions whose
> rollout files may not exist in the v7 tree). **Engram does not read `history.jsonl`** — it
> is the Codex TUI up-arrow recall log.

### `session_index.jsonl` — id → human title (100 KB)

| Field | Type | Meaning | Example |
|---|---|---|---|
| `id` | string (UUIDv7) | session id (joins to rollout/`threads`) | `"019ca318-d9f3-7a12-a4f1-0352b065e5b6"` |
| `thread_name` | string | human/auto title (CJK ok; can be garbled) | `"CIP_Pro_Rebuild"` |
| `updated_at` | string (ISO UTC, µs) | last title update | `"2026-03-01T03:06:53.593906Z"` |

```json
{ "id":"019ca318-d9f3-7a12-a4f1-0352b065e5b6", "thread_name":"<title>", "updated_at":"2026-03-01T03:06:53.593906Z" }
```

> Append-only title index mirroring `threads.title`. **Engram does not read it** — Engram
> derives its summary from the first user message (`firstUserText`, capped 200 chars), so
> Engram titles differ from Codex's own.

### Other auxiliary dirs (not session content)

`attachments/`, `generated_images/` (blobs referenced by image messages), plus config/identity
files (`config.toml`, `auth.json`, `AGENTS.md`, `installation_id`). Sidecars like the Gemini
`{sessionId}.engram.json` do **not** exist for Codex — Codex dispatch is detected purely from
`session_meta.originator`.

---

## Engram mapping

Concrete table: source record/field → Engram `Session`/`Message` field → adapter file:line.

| On-disk source (record.field) | Engram field / behavior | TS `codex.ts` | Swift `CodexAdapter.swift` |
|---|---|---|---|
| `session_meta.payload.id` | `SessionInfo.id` — **rejected if missing/empty** | L119-120 | L316 |
| `session_meta.payload.timestamp` | `startTime` (TS falls back: lastTimestamp → file mtime; Swift requires it) | L129-134 | L317, L330 |
| last line `.timestamp` | `endTime` (last line carrying a timestamp) | L74-76, L139 | L275-277, L330 |
| `session_meta.payload.cwd` | `cwd` | L140 | L331 |
| `session_meta.payload.originator` | `originator`; drives dispatch | L122, L151 | L323, L344 |
| `session_meta.payload.agent_role` | `agentRole` (precedence over originator) | L121, L125 | L322, L324 |
| `originator == "Claude Code"` (no role) | `agentRole = "dispatched"` (Layer-1b) | L125-126 (exact match) | L324 via `OriginatorClassifier.isClaudeCode` (normalized) |
| (classifier) | normalize trim/lower/`_`→`-`/space→`-` then `== "claude-code"` | — | `SessionAdapter.swift` L23-32 |
| `response_item.payload.model` | `model` (old/legacy item model; first occurrence, highest priority) | L92-96 | L311-313 |
| `turn_context.payload.model` | `model` fallback for modern rollouts | L83-88, L149-152 | L298-303, L355 |
| `session_meta.payload.model` | final `model` fallback if no item or turn-context model | L152 | L355 |
| `response_item`/`message`/`user` (text via `extractText`) | user message; `summary` = first user text (200) | L89-100, L360-382 | L294-305, L478-485, L604-618 |
| user-text system-injection strip | `<INSTRUCTIONS>`, `<environment_context>`, `<local-command-caveat>`, AGENTS.md, skills/plugins → `systemCount` | L93, L345-358 | L296-305, L563-602 |
| `response_item`/`message`/`assistant` | assistant message; `assistantCount` | L101-103, L207-230 | L306-307, L473-492 |
| `response_item`/`function_call` (`name`, `arguments` 500-trunc) | `tool` message; `toolCount` +1; `toolCalls:[{name,input}]` | L104-108, L231-239 | L308-312, L493-501 |
| `response_item`/`function_call_output` (`output` 2000-trunc) | `tool` message; **not** re-counted | L240-249 | L502-512 |
| `response_item`/`message`/assistant `.usage` | per-message `TokenUsage` (legacy/absent on modern disk) | L216-228 | L491, L220-228 (`JSONLAdapterSupport.usage`) |
| `event_msg`/`token_count`/`info.last_token_usage` | per-message `TokenUsage`; `inputTokens=max(in−cached,0)`, `cacheReadTokens=cached` | L297-328 | L518-545 |
| token usage attribution | attached to pending non-user message; multiple merged | L184-265 | L419-449 |
| discovery roots | `sessions/` + sibling `archived_sessions/` | L51-54 | L376-382 |
| enumeration | TS glob `**/rollout-*.jsonl`; Swift recursive `rollout-` prefix + `.jsonl`, no symlinks | L38-49 | L250-258 |
| incremental fast path | per-day roots `~/.codex/sessions/YYYY/MM/DD` for last N (local) days (sessions/ only; excludes archived) | — | `SessionAdapterFactory.swift` `recentCodexAdapters` L31-51 |
| registration | `CodexAdapter()` in `defaultAdapters()` / `recentActiveAdapters()` | — | `SessionAdapterFactory.swift` L8-11, L53-74 |
| `reasoning`, `custom_tool_call*`, `web_search_call`, `tool_search_*`, `compacted`, `world_state`, all non-`token_count` `event_msg` | **dropped** (default branch) | (gap) | `message(from:)` `default` L535-536 |
| `session_meta.source`, `parent_thread_id`, `forked_from_id`, `thread_source`, `git`, `base_instructions` | **not read** | (gap) | (gap) |
| any SQLite DB (`state_5`/`threads`/`thread_spawn_edges`/…) | **never read** — Engram re-derives from JSONL only | (gap) | (gap) |

> Verified: a grep for `state_5` / `.sqlite` / `thread_spawn` / `stage1` across all Codex
> adapter files returns nothing (the only `state_5` hits are unrelated vendored swift-nio C
> code). Engram's Codex ingestion is **JSONL-only**, so Engram's session count/title/archive
> view can diverge from Codex's DB-driven view.
>
> `codex-usage-probe.ts` despite its name does **not** parse rollouts — it scrapes
> `codex /status` via a headless tmux for quota % (`Usage: NN%` / `NN/MM`). It contributes
> nothing to format parsing. There is no confirmed Swift product equivalent;
> `rate_limits` data sits unused in every `token_count` event.

---

## Gotchas, version drift & edge cases

1. **Filename timestamp is LOCAL time, not UTC.** `rollout-2025-11-20T11-08-12-...` ↔ inner
   `2025-11-20T03:08:12.198Z` (UTC+8 host). Date-dir bucketing is also local. Engram's
   incremental day-roots use the **local** calendar to match.
2. **Layer confusion.** `compacted` (L1) ≠ `context_compacted` (L2). `message`/`reasoning`/
   `token_count` are L2, never L1. `input_text`/`output_text`/`summary_text` are L3.
3. **`source` is polymorphic** (string vs nested subagent object), in both `session_meta` and
   `threads.source`. Naive string consumers must handle the object form.
4. **`instructions` and `base_instructions` are two different fields, not a rename.**
   Confirmed (official): the legacy `instructions` held `user_instructions`, which was **moved
   to `TurnContext`**; `base_instructions` is the separate base/system-prompt slot. Both shift
   between v0.60 and v0.14x (exact boundary unpinned). `git`, `agent_nickname`,
   `thread_source`, `parent_thread_id`, `multi_agent_version`, `agent_path` are all later
   additions absent in 0.60.1.
   ([protocol.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs))
5. **Text key trap:** value is always under `text`, never `input_text`/`output_text`. Adapter
   fallbacks on those keys are dead branches for modern data.
6. **TS multi-block under-capture:** TS `extractText` returns only the first block; Swift joins
   all with `\n\n`. Multi-block user messages exist.
7. **Modern files carry no `response_item.payload.model` / `.usage`:** model now comes from
   `turn_context.payload.model` (fixed in TS + Swift on 2026-07-01); usage comes only from
   `event_msg.token_count`. Latent: if Codex re-adds inline usage, adapters silently prefer
   it.
8. **TS vs Swift originator matching diverges** (exact vs normalized) — a `claude_code`/
   `claude-code` originator dispatches on Swift but not TS.
9. **Cost blind spot:** `gpt-5.*`/`*-codex` models have no `MODEL_PRICING` entry and won't
   prefix-match a `gpt-4*` entry → zero cost for current Codex sessions.
   `reasoning_output_tokens` is never priced separately.
10. **Compaction invisibility:** Engram skips `compacted`/`context_compacted`, so
    pre-compaction turns surviving only in `replacement_history` are absent from Engram's
    transcript/search/`messageCount`.
11. **Native subagent graph un-mined:** `thread_spawn_edges` + `meta.source` give a
    deterministic parent→child graph (explorer/worker/awaiter), but Engram reads none of it —
    Codex native subagents are likely surfaced as independent sessions.
12. **`token_count.info` can be `null`** (interrupted/credits-exhausted turns) — both adapters
    null-guard and skip.
13. **`function_call_output.output` non-string form is `content_items`, not `{output,
    metadata}`.** Confirmed (official): the wire payload (`FunctionCallOutputPayload`) is
    **either** a plain string (`content`) **or** an array of structured content items
    (`content_items`); `custom_tool_call_output` uses the same encoding. The 100%-string
    observation in this 2025–2026 store still holds, but the earlier `{output, metadata}`
    object shape was wrong.
    ([models.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/models.rs))
14. **Two DB locations:** any future SQLite reader must target `~/.codex/*.sqlite` (current)
    and ignore `~/.codex/sqlite/` (legacy), distinguished by mtime and `_sqlx_migrations`
    `MAX(version)` (39 vs 35).
15. **Empty early date dirs:** `2025/09` and `2025/10` exist with zero rollout files; the
    earliest readable rollout is `2025/11/20` (cli 0.60.1) — the very earliest schema variant
    is uncaptured.
16. **`thread_goal_updated` uses camelCase** — full keys are `{type, goal, threadId, turnId}`
    (`goal`, `threadId`, `turnId` all camelCase; only `type` is plain) while the rest of the
    schema is snake_case — a likely different emitting subsystem. `turnId` is present and was
    previously undocumented. (evidence: jq `thread_goal_updated` key histogram → every record
    has exactly `[goal, threadId, turnId, type]`.) (web-checked 2026-06-21: no authoritative
    source found — `thread_goal_updated` is confirmed an `EventMsg` variant in `protocol.rs`,
    but the inner `goal`/`threadId`/`turnId` field casing could not be confirmed against
    source; treat the camelCase claim as on-disk observation.)

---

## Appendix: real anonymized line samples

One fenced JSON block per record / payload type. All content redacted; full key structure
intact.

```json
// L1 session_meta — NEW format (cli 0.141.0, normal user session)
{ "timestamp":"2026-06-21T07:37:18.453Z","type":"session_meta","payload":{
    "id":"019ee91c-8298-7c32-a***","timestamp":"2026-06-21T07:37:00.471Z",
    "cwd":"/Users/<user>/<repo>","originator":"codex-tui","cli_version":"0.141.0",
    "source":"cli","thread_source":"user","model_provider":"openai",
    "base_instructions":{"text":"You are Codex, a coding agent... <~12KB redacted>"},
    "git":{"commit_hash":"d941bde***","branch":"main"} } }
```

```json
// L1 session_meta — LEGACY format (cli 0.60.1)
{ "timestamp":"2025-11-20T03:08:12.225Z","type":"session_meta","payload":{
    "id":"019a9f3b-de26-71f0-***","timestamp":"2025-11-20T03:08:12.198Z",
    "cwd":"/Users/<user>","originator":"codex_cli_rs","cli_version":"0.60.1",
    "instructions":null,"source":"cli","model_provider":"openai" } }
```

```json
// L1 session_meta — subagent (source is an OBJECT)
{ "timestamp":"2026-06-20T17:39:16.296Z","type":"session_meta","payload":{
    "id":"019ee61d-8aa4-7883-***","parent_thread_id":"019ee02d-***",
    "timestamp":"2026-06-20T17:39:16.296Z","cwd":"<redacted>",
    "originator":"Codex Desktop","cli_version":"0.142.0-alpha.6",
    "source":{"subagent":{"thread_spawn":{"parent_thread_id":"019ee02d-***",
        "depth":1,"agent_path":null,"agent_nickname":"Explorer the 12th","agent_role":"explorer"}}},
    "thread_source":"subagent","agent_nickname":"Explorer the 12th","agent_role":"explorer",
    "model_provider":"openai","base_instructions":{"text":"<redacted>"},
    "multi_agent_version":"v1","git":{"commit_hash":"1f29fa8f***","branch":"main"} } }
```

```json
// L1 turn_context — per-turn config (Engram consumes only payload.model)
{ "timestamp":"2026-06-21T07:37:18.935Z","type":"turn_context","payload":{
    "turn_id":"019ee91c-***","cwd":"/Users/<user>/p","workspace_roots":["/Users/<user>/p"],
    "current_date":"2026-06-21","timezone":"Asia/Shanghai","approval_policy":"never",
    "sandbox_policy":{"type":"danger-full-access"},"permission_profile":{"type":"disabled"},
    "model":"gpt-5.5","comp_hash":"2911","personality":"pragmatic",
    "collaboration_mode":{"mode":"default","settings":{"model":"gpt-5.5","reasoning_effort":"xhigh","developer_instructions":"<redacted>"}},
    "multi_agent_version":"v1","realtime_active":false,"effort":"xhigh","summary":"auto" } }
```

```json
// L2 response_item / message (user)
{ "timestamp":"2026-06-03T14:54:23.911Z","type":"response_item","payload":{
    "type":"message","role":"user","id":null,"status":null,
    "content":[ {"type":"input_text","text":"<USER PROMPT>"},
                {"type":"input_text","text":"<SECOND BLOCK>"} ] } }
```

```json
// L2 response_item / message (assistant)
{ "type":"response_item","payload":{
    "type":"message","role":"assistant","id":null,"status":null,
    "content":[ {"type":"output_text","text":"<ASSISTANT REPLY>"} ] } }
```

```json
// L2 response_item / message (user, image attachment)
{ "type":"response_item","payload":{
    "type":"message","role":"user",
    "content":[ {"type":"input_image","image_url":"data:image/jpeg;base64,<BASE64>","detail":"auto"} ] } }
```

```json
// L2 response_item / reasoning (encrypted, summary empty)
{ "type":"response_item","payload":{
    "type":"reasoning","id":"rs_02a<…>","summary":[],
    "encrypted_content":"gAAAAAB<…>","metadata":{"turn_id":"<uuid>"} } }
```

```json
// L2 response_item / function_call + paired function_call_output
{ "type":"response_item","payload":{
    "type":"function_call","name":"exec_command",
    "arguments":"{\"cmd\":[\"/bin/zsh\",\"-lc\",\"<CMD>\"],\"workdir\":\"<PATH>\"}",
    "call_id":"call_TMg3Szj<…>" } }
{ "type":"response_item","payload":{
    "type":"function_call_output","call_id":"call_TMg3Szj<…>","output":"<STDOUT>" } }
```

```json
// L2 response_item / custom_tool_call (apply_patch)
{ "type":"response_item","payload":{
    "type":"custom_tool_call","name":"apply_patch",
    "input":"*** Begin Patch\n*** Update File: <PATH>\n<DIFF>\n*** End Patch",
    "call_id":"call_<…>","status":"completed" } }
```

```json
// L2 response_item / web_search_call
{ "type":"response_item","payload":{
    "type":"web_search_call","status":"completed",
    "action":{"type":"search","query":"<QUERY>","queries":["<Q>"]} } }
```

```json
// L2 response_item / tool_search_call (arguments is an OBJECT here)
{ "type":"response_item","payload":{
    "type":"tool_search_call","call_id":"<id>","status":"completed",
    "execution":"client","arguments":{"query":"<QUERY>","limit":10} } }
```

```json
// L2 event_msg / token_count (authoritative usage)
{ "type":"event_msg","payload":{
    "type":"token_count",
    "info":{
      "total_token_usage":{"input_tokens":33804,"cached_input_tokens":2432,"output_tokens":815,"reasoning_output_tokens":516,"total_tokens":34619},
      "last_token_usage":{"input_tokens":33804,"cached_input_tokens":2432,"output_tokens":815,"reasoning_output_tokens":516,"total_tokens":34619},
      "model_context_window":258400 },
    "rate_limits":{"limit_id":"codex","limit_name":null,
      "primary":{"used_percent":1.0,"window_minutes":300,"resets_at":1782044976},
      "secondary":{"used_percent":6.0,"window_minutes":10080,"resets_at":1782613776},
      "credits":null,"individual_limit":null,"plan_type":"pro","rate_limit_reached_type":null} } }
```

```json
// L2 event_msg / agent_message (UI mirror of assistant text)
{ "type":"event_msg","payload":{
    "type":"agent_message","message":"<TEXT>","phase":"commentary","memory_citation":null } }
```

```json
// L2 event_msg / user_message (UI form with attachment metadata)
{ "type":"event_msg","payload":{
    "type":"user_message","message":"<TEXT>","images":[],"local_images":[],"text_elements":[] } }
```

```json
// L2 event_msg / task_started + task_complete (linked by turn_id)
{ "type":"event_msg","payload":{
    "type":"task_started","turn_id":"727cc762-***","started_at":1780498463,
    "model_context_window":258400,"collaboration_mode_kind":"default" } }
{ "type":"event_msg","payload":{
    "type":"task_complete","turn_id":"727cc762-***","last_agent_message":"<TEXT>",
    "completed_at":1780503250,"duration_ms":4786545,"time_to_first_token_ms":9140 } }
```

```json
// L2 event_msg / exec_command_end (verbose shell telemetry, legacy)
{ "type":"event_msg","payload":{
    "type":"exec_command_end","call_id":"call_<…>","process_id":"<PID>","turn_id":"<uuid>",
    "command":["/bin/zsh","-lc","<CMD>"],"cwd":"<PATH>",
    "parsed_cmd":[{"type":"unknown","cmd":"<CMD>"}],"source":"<src>",
    "stdout":"<STDOUT>","stderr":"<STDERR>","aggregated_output":"<OUT>","exit_code":0,
    "duration":{"secs":1,"nanos":165817834},"formatted_output":"<OUT>","status":"completed" } }
```

```json
// L2 event_msg / patch_apply_end (apply_patch telemetry)
{ "type":"event_msg","payload":{
    "type":"patch_apply_end","call_id":"call_<…>","turn_id":"<uuid>",
    "stdout":"<OUT>","stderr":"","success":true,
    "changes":{"<FILE_PATH>":{"type":"update","move_path":null,"unified_diff":"<DIFF>"}},
    "status":"completed" } }
```

```json
// L2 event_msg / mcp_tool_call_end (Rust-Result tagged union)
{ "type":"event_msg","payload":{
    "type":"mcp_tool_call_end","call_id":"call_bnQGN<…>","duration":{"secs":0,"nanos":446001833},
    "invocation":{"server":"codegraph","tool":"codegraph_explore","arguments":{"query":"<QUERY>"}},
    "result":{"Ok":{"content":[{"type":"text","text":"<RESULT>"}],"is_error":null}} } }
{ "type":"event_msg","payload":{
    "type":"mcp_tool_call_end","call_id":"call_<…>","duration":{"secs":0,"nanos":1},
    "invocation":{"server":"<srv>","tool":"<tool>","arguments":{}},"result":{"Err":"<ERROR STRING>"} } }
```

```json
// L2 event_msg / error
{ "type":"event_msg","payload":{
    "type":"error","message":"<MESSAGE>","codex_error_info":"context_window_exceeded" } }
```

```json
// L2 event_msg / smaller lifecycle variants
{ "type":"event_msg","payload":{"type":"context_compacted"} }
{ "type":"event_msg","payload":{"type":"agent_reasoning","text":"<REASONING TEXT — legacy>"} }
{ "type":"event_msg","payload":{"type":"turn_aborted","turn_id":"<uuid>","reason":"interrupted","completed_at":1780500000,"duration_ms":12000} }
{ "type":"event_msg","payload":{"type":"web_search_end","call_id":"<id>","query":"<QUERY>","action":{"type":"open_page","url":"https://example.com"}} }
{ "type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":3} }
{ "type":"event_msg","payload":{"type":"thread_goal_updated","goal":{},"threadId":"<uuid>","turnId":"<uuid>"} }
```

```json
// L2 event_msg / entered_review_mode + exited_review_mode (structured code-review payload)
// entered_review_mode.target is POLYMORPHIC by target.type:
//   uncommittedChanges -> {type}            custom    -> {type, instructions}
//   baseBranch         -> {type, branch}    commit    -> {type, sha, title}
{ "type":"event_msg","payload":{
    "type":"entered_review_mode",
    "target":{"type":"commit","sha":"<sha>","title":"<commit title>"},
    "user_facing_hint":"<HINT>" } }
{ "type":"event_msg","payload":{
    "type":"exited_review_mode",
    "review_output":{
      "overall_correctness":"<verdict>","overall_confidence_score":0.0,
      "overall_explanation":"<SUMMARY>",
      "findings":[
        {"title":"<FINDING TITLE>","body":"<DETAIL>","priority":0,
         "confidence_score":0.0,"code_location":"<file:line>"} ] } } }
```

### New native-multi-agent / image / dynamic-tool `event_msg` variants

These 11 `event_msg` payload types (see the L2 enumeration note above) were absent from the
original taxonomy. The `collab_*` family is documented structurally in the Subagent section
(B-4); image tools are in the Tool-calls "Image tools" subsection. Field tables + samples:

| payload.type | Keys | Meaning |
|---|---|---|
| `thread_name_updated` | `{type, thread_id, thread_name}` | the **title-update event** — DB-driven rename of the thread. Parallel to `session_index.jsonl.thread_name` and `threads.title`; this is the rollout-resident emission of the same title change. Confirmed (official): `ThreadNameUpdated` is **NOT** a variant of the core rollout `EventMsg` enum in `protocol.rs`; in source it lives in the app-server-protocol / app-server / TUI notification layer (`ThreadNameUpdatedNotification`). So on-disk `event_msg` lines with `payload.type=thread_name_updated` most likely originate from the desktop/app-server write path, not the core rollout recorder. ([common.rs](https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/src/protocol/common.rs)) |
| `collab_agent_spawn_end` | `{type, call_id, sender_thread_id, new_thread_id, new_agent_nickname, new_agent_role, prompt, model, reasoning_effort, status}` | parent→child spawn edge inline in the parent rollout (see B-4). |
| `collab_waiting_end` | `{type, call_id, sender_thread_id, agent_statuses, statuses}` | parent waited on children; `statuses`/`agent_statuses` map child id → result. |
| `collab_close_end` | `{type, call_id, sender_thread_id, receiver_thread_id, receiver_agent_nickname, receiver_agent_role, status}` | parent closed a child; `status` = `{completed:"<summary>"}`. |
| `collab_agent_interaction_end` | `{type, call_id, sender_thread_id, receiver_thread_id, receiver_agent_nickname, receiver_agent_role, prompt, status}` | agent↔agent message; `prompt` asked, `status.completed` replied. |
| `collab_resume_end` | `{type, call_id, sender_thread_id, receiver_thread_id, receiver_agent_nickname, receiver_agent_role, status}` | parent resumed a paused child. |
| `view_image_tool_call` | `{type, call_id, path}` | the agent viewed an on-disk image at `path`. |
| `image_generation_end` | `{type, call_id:ig_<hex>, status, revised_prompt, result, saved_path}` | image-gen completion telemetry; `call_id` is the `ig_` id, `saved_path` under `generated_images/`. |
| `item_completed` | `{type, thread_id, turn_id, item}` | a structured agent item finished; `item` e.g. `{type:"Plan", id:"<id>-plan", text:"<plan markdown>"}`. |
| `dynamic_tool_call_request` | `{type, callId, turnId, namespace, tool, arguments}` | runtime-registered dynamic tool **request** — **camelCase** `callId`/`turnId`. `namespace` may be `null`; `arguments` is an object. |
| `dynamic_tool_call_response` | `{type, call_id, turn_id, namespace, tool, arguments, content_items, success, error, duration}` | dynamic tool **response** — **snake_case** here (`call_id`/`turn_id`, mismatching the request's camelCase). `content_items[]` blocks use block type **`inputText`** (camelCase L3). |

```json
// L2 event_msg / thread_name_updated (rollout-resident title rename)
{ "type":"event_msg","payload":{
    "type":"thread_name_updated","thread_id":"<uuid>","thread_name":"<title>"} }
```

```json
// L2 event_msg / collab_agent_spawn_end (parent-side spawn edge: sender -> new child)
{ "type":"event_msg","payload":{
    "type":"collab_agent_spawn_end","call_id":"<id>",
    "sender_thread_id":"<parent uuid>","new_thread_id":"<child uuid>",
    "new_agent_nickname":"<name>","new_agent_role":"worker","prompt":"<SPAWN PROMPT>",
    "model":"gpt-5.5","reasoning_effort":"medium","status":"pending_init"} }
```

```json
// L2 event_msg / collab_waiting_end (children results map back to parent)
{ "type":"event_msg","payload":{
    "type":"collab_waiting_end","call_id":"<id>","sender_thread_id":"<parent uuid>",
    "agent_statuses":"<v>",
    "statuses":{ "<child uuid>":{"completed":"<CHILD RESULT TEXT>"} } } }
```

```json
// L2 event_msg / collab_close_end (status is an OBJECT, not a plain string)
{ "type":"event_msg","payload":{
    "type":"collab_close_end","call_id":"<id>",
    "sender_thread_id":"<parent uuid>","receiver_thread_id":"<child uuid>",
    "receiver_agent_nickname":"<name>","receiver_agent_role":"worker",
    "status":{"completed":"<FINAL CHILD SUMMARY>"} } }
```

```json
// L2 event_msg / collab_agent_interaction_end + collab_resume_end
{ "type":"event_msg","payload":{
    "type":"collab_agent_interaction_end","call_id":"<id>",
    "sender_thread_id":"<parent uuid>","receiver_thread_id":"<child uuid>",
    "receiver_agent_nickname":"<name>","receiver_agent_role":"explorer",
    "prompt":"<INTERACTION PROMPT>","status":{"completed":"<RECEIVER REPLY>"} } }
{ "type":"event_msg","payload":{
    "type":"collab_resume_end","call_id":"<id>",
    "sender_thread_id":"<parent uuid>","receiver_thread_id":"<child uuid>",
    "receiver_agent_nickname":"<name>","receiver_agent_role":"explorer",
    "status":{"completed":"<RESUMED CHILD OUTPUT>"} } }
```

```json
// L2 event_msg / view_image_tool_call
{ "type":"event_msg","payload":{
    "type":"view_image_tool_call","call_id":"<id>","path":"<image path>"} }
```

```json
// L2 response_item / image_generation_call (id is ig_<hex>, NOT call_<rand>)
// paired with L2 event_msg / image_generation_end (call_id == that ig_<hex>)
{ "type":"response_item","payload":{
    "type":"image_generation_call","id":"ig_<hex>","status":"generating",
    "revised_prompt":"<REWRITTEN IMAGE PROMPT>","result":"<blob/base64>"} }
{ "type":"event_msg","payload":{
    "type":"image_generation_end","call_id":"ig_<hex>","status":"completed",
    "revised_prompt":"<REWRITTEN IMAGE PROMPT>","result":"<blob/base64>",
    "saved_path":"<generated_images/...png>"} }
```

```json
// L2 event_msg / item_completed (structured agent item — e.g. a Plan)
{ "type":"event_msg","payload":{
    "type":"item_completed","thread_id":"<uuid>","turn_id":"<uuid>",
    "item":{"type":"Plan","id":"<id>-plan","text":"<plan markdown — redacted>"} } }
```

```json
// L2 event_msg / dynamic_tool_call_request (camelCase callId/turnId)
//          and dynamic_tool_call_response (snake_case call_id/turn_id; block type inputText)
{ "type":"event_msg","payload":{
    "type":"dynamic_tool_call_request","callId":"<id>","turnId":"<uuid>",
    "namespace":null,"tool":"load_workspace_dependencies","arguments":{} } }
{ "type":"event_msg","payload":{
    "type":"dynamic_tool_call_response","call_id":"<id>","turn_id":"<uuid>",
    "namespace":null,"tool":"load_workspace_dependencies","arguments":{},
    "content_items":[{"type":"inputText","text":"<TOOL OUTPUT — redacted>"}],
    "success":"<v>","error":"<v>","duration":"<v>"} }
```

```json
// L1 compacted — context-compaction checkpoint
// (3 observed generations: [message,replacement_history] ×2050;
//  +window_id ×113; +window_id+window_number ×55 — newest emits BOTH counters)
{ "timestamp":"2026-06-21T02:37:49.013Z","type":"compacted","payload":{
    "message":"","window_id":1,"window_number":1,
    "replacement_history":[
      {"type":"message","role":"user","content":[{"type":"input_text","text":"<earlier user msg>"}]},
      {"type":"message","role":"developer","content":[{"type":"input_text","text":"<permissions block>"}]} ] } }
```

```json
// Aux: history.jsonl line (flat shape — NOT the {timestamp,type,payload} envelope)
{ "session_id":"019ee858-92b6-7853-ba71-074b9c042711","ts":1757248180,"text":"<user prompt>" }
```

```json
// Aux: session_index.jsonl line
{ "id":"019ca318-d9f3-7a12-a4f1-0352b065e5b6","thread_name":"<title>","updated_at":"2026-03-01T03:06:53.593906Z" }
```

---

## Open questions / web-confirmation status (2026-06-21)

This doc's structural claims were cross-checked against the **official `openai/codex` Rust
source** on 2026-06-21 (`web_access_ok=true`). The corpus statistics (file counts, originator
distribution, model distribution, migration row counts) are this-machine measurements and are
not web-verifiable by design. Status of each previously-open question:

- **Confirmed (official):** L1 envelope shape is `RolloutLine = {timestamp, #[serde(flatten)]
  item}` with `RolloutItem` `serde(tag="type", content="payload")`, so each line is
  `{"timestamp", "type":"<snake_case>", "payload":{...}}`.
  ([protocol.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs))
- **Confirmed (official):** the L1 record set has **SIX** variants, not five —
  `inter_agent_communication` is the missing 6th (folded into the taxonomy above).
  ([protocol.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs))
- **Confirmed (official):** `session_meta.payload` carries `id`, `forked_from_id`,
  `parent_thread_id`, `timestamp`, `cwd`, `originator`, `cli_version`, `source`,
  `thread_source`, `agent_nickname`, `agent_role` (alias `agent_type`), `agent_path`,
  `model_provider`, `base_instructions`, `dynamic_tools`, `memory_mode`,
  `multi_agent_version`; `git` is on the wrapper `SessionMetaLine` via `#[serde(flatten)]`.
  `GitInfo = {commit_hash, branch, repository_url}`, all optional.
  ([protocol.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs))
- **Confirmed (official):** `originator` is a free-form `String` (open/extensible set, not a
  closed enum); `DEFAULT_ORIGINATOR = "codex_cli_rs"`, overridable via
  `CODEX_INTERNAL_ORIGINATOR_OVERRIDE`. `codex_cli_rs`/`codex_exec`/`codex_sdk_ts` are literal
  originator strings in source.
  ([default_client.rs](https://github.com/openai/codex/blob/main/codex-rs/login/src/auth/default_client.rs))
- **Confirmed (official):** `source` is polymorphic — `SessionSource` =
  `Cli | VSCode | Exec | Mcp | Custom(String) | Internal | SubAgent(SubAgentSource) |
  Unknown`; `SubAgentSource` = `Review | Compact | ThreadSpawn{parent_thread_id, depth,
  agent_path, agent_nickname, agent_role(alias agent_type)} | MemoryConsolidation |
  Other(String)`. Both the plain-string forms and the nested `{subagent:{thread_spawn:{…}}}` /
  `{subagent:"review"}` forms are confirmed (with more variants than the doc's six).
  ([protocol.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs))
- **Confirmed (official):** L3 content blocks — `ContentItem` = `InputText{text}` |
  `InputImage{image_url, detail:Option<ImageDetail>}` | `OutputText{text}`; the string is
  always under `text`. `ImageDetail` = `Auto/Low/High/Original` (default `High`). No standalone
  `text` block variant exists in the current enum (the legacy `text` block is removed/older).
  ([models.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/models.rs))
- **Confirmed (official):** `ResponseItem::Message` has only `{id, role, content, phase,
  metadata}` — **no `usage`, no `status`** field. Adapters reading assistant
  `payload.usage`/`payload.status` hit dead paths for modern Codex; per-turn usage comes only
  from `event_msg/token_count`. `phase` = `MessagePhase::{Commentary, FinalAnswer}`.
  ([models.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/models.rs))
- **Confirmed (official):** no `ResponseItem` variant has a `model` field; the model lives on
  `TurnContextItem.model` (required `String`). So a modern rollout carries no
  `response_item.payload.model` — model comes from `turn_context`. Engram now consumes this
  field for session model attribution.
  ([models.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/models.rs),
  [protocol.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs))
- **Confirmed (official):** `ResponseItem::Reasoning` = `{id, summary, content,
  encrypted_content, metadata}`; `ResponseItemMetadata = {turn_id, source_call_id}`.
  `encrypted_content` is an opaque `Option<String>` (no encryption scheme stated — see D8).
  ([models.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/models.rs))
- **Confirmed (official) — with correction:** `FunctionCall` = `{id, name, namespace,
  arguments:String (JSON-as-string), call_id, metadata}`. `function_call_output`'s structured
  form is `content_items` (array), NOT `{output, metadata}` (see D3).
  ([models.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/models.rs))
- **Confirmed (official):** `CustomToolCall` uses `input` (freeform `String`) and `name` is an
  arbitrary `String` — the generic freeform-tool channel.
  `ToolSearchCall.arguments` is `serde_json::Value` (a structured object), contrasting
  `FunctionCall.arguments: String`.
  ([models.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/models.rs))
- **Confirmed (official):** `TokenUsageInfo = {total_token_usage, last_token_usage,
  model_context_window:Option<i64>}`; `TokenUsage = {input_tokens, cached_input_tokens,
  output_tokens, reasoning_output_tokens, total_tokens}` (all `i64`). `TokenCountEvent.info`
  is `Option` (can be null).
  ([protocol.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs))
- **Confirmed (official):** the `EventMsg` enum is large and version-evolving (open/growing,
  not closed); `token_count`, `context_compacted`, `agent_reasoning`, the full `collab_*`
  begin/end family, `view_image_tool_call`, `image_generation_end`, `item_completed`,
  `dynamic_tool_call_request`/`response`, review-mode events, and the rest are all real
  variants. `task_started`/`task_complete` are serde aliases of `TurnStarted`/`TurnComplete`.
  ([protocol.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs))
- **Confirmed (official):** `context_compacted` is a pure marker `EventMsg` variant, distinct
  from the L1 `Compacted(CompactedItem)` record — confirming the L1-vs-L2 name trap.
  ([protocol.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs))
- **Confirmed (official):** `thread_spawn_edges` schema is `(parent_thread_id TEXT NOT NULL,
  child_thread_id TEXT NOT NULL PRIMARY KEY, status TEXT NOT NULL)` + index
  `idx_thread_spawn_edges_parent_status(parent_thread_id, status)` — one parent per child.
  ([0021_thread_spawn_edges.sql](https://github.com/openai/codex/blob/main/codex-rs/state/migrations/0021_thread_spawn_edges.sql))
- **Confirmed (official):** the `_N` migration-generation model and the `threads` schema —
  `0001_threads.sql` creates the base `threads` table; later columns (`model`, `cli_version`,
  `agent_role`, `agent_nickname`, `thread_source`, `memory_mode`, `recency_at`) arrive via
  later migrations; `0039_threads_recency_at.sql` is the newest (adds `recency_at`, so legacy
  DBs lack it).
  ([migrations/](https://github.com/openai/codex/tree/main/codex-rs/state/migrations))
- **Confirmed (official):** rollout filename grammar —
  `sessions/YYYY/MM/DD/rollout-{date}-{conversation_id}.jsonl`; filename TS format
  `[year]-[month]-[day]T[hour]-[minute]-[second]` (hyphens), JSON record TS
  `…T[hour]:[minute]:[second].[subsecond:3]Z`; first line must be a `SessionMeta`. (The
  filename=local / inner=UTC distinction is an on-disk observation, not encoded in the format
  constants.)
  ([recorder.rs](https://github.com/openai/codex/blob/main/codex-rs/rollout/src/recorder.rs))
- **Confirmed (official):** `TurnContextItem` carries per-turn config — `turn_id`, `cwd`,
  `workspace_roots`, `current_date`, `timezone`, `approval_policy`, `sandbox_policy`,
  `permission_profile`, `network`, `file_system_sandbox_policy`, `model:String`, `comp_hash`,
  `personality`, `collaboration_mode`, `multi_agent_version`, `multi_agent_mode`,
  `realtime_active`, `effort`, `summary` (compatibility-only). Whether Engram ignores it is an
  Engram-internal design fact.
  ([protocol.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs))
- **Refuted → fixed (official):** `compacted` window-field types were inverted —
  `window_number` is the `u64` integer counter, `window_id` is a UUIDv7 string; plus
  `first_window_id`/`previous_window_id` exist (fixed in the Summary / compaction section, D2).
  ([protocol.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs))
- **Unknown (web-checked 2026-06-21: no authoritative source found):**
  `thread_goal_updated` is a confirmed `EventMsg` variant, but its inner field casing
  (`goal`/`threadId`/`turnId` camelCase) could not be confirmed against source — treat as
  on-disk observation.
  ([protocol.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs))
- **Engram-internal design — not web-verifiable:** whether the Swift product has its own
  pricing path, and that `turn_context` is used only for model fallback while
  `compacted`/`inter_agent_communication`/`world_state` are ignored by Engram, are
  Engram-internal facts, out of web scope.
- **Out of scope — not web-verifiable by design:** `history.jsonl` / `session_index.jsonl`
  shapes and all per-machine corpus statistics (file counts, originator/model distributions,
  archived counts, migration row counts) are this-machine measurements, not tool-format facts.

---

## References (official sources)

Verified 2026-06-21 against the `openai/codex` repository (`main` branch):

- [codex-rs/protocol/src/protocol.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs) — `RolloutLine`/`RolloutItem`/`SessionMeta`/`SessionMetaLine`/`GitInfo`/`CompactedItem`/`TurnContextItem`/`TokenUsage`/`TokenUsageInfo`/`EventMsg`/`SessionSource`/`ThreadSource`/`SubAgentSource`
- [codex-rs/protocol/src/models.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/models.rs) — `ResponseItem`/`ContentItem`/`Reasoning`/`FunctionCall`/`FunctionCallOutputPayload`/`CustomToolCall`
- [codex-rs/rollout/src/recorder.rs](https://github.com/openai/codex/blob/main/codex-rs/rollout/src/recorder.rs) — rollout path + filename + timestamp format
- [codex-rs/login/src/auth/default_client.rs](https://github.com/openai/codex/blob/main/codex-rs/login/src/auth/default_client.rs) — `DEFAULT_ORIGINATOR = codex_cli_rs`, originator override env
- [codex-rs/state/migrations/0021_thread_spawn_edges.sql](https://github.com/openai/codex/blob/main/codex-rs/state/migrations/0021_thread_spawn_edges.sql) — thread spawn edges table
- [codex-rs/state/migrations/0001_threads.sql](https://github.com/openai/codex/blob/main/codex-rs/state/migrations/0001_threads.sql) — base `threads` table
- [codex-rs/state/migrations/0039_threads_recency_at.sql](https://github.com/openai/codex/blob/main/codex-rs/state/migrations/0039_threads_recency_at.sql) — newest migration (`recency_at`)
- [codex-rs/state/migrations/](https://github.com/openai/codex/tree/main/codex-rs/state/migrations) — full migration ledger
- [codex-rs/app-server-protocol/src/protocol/common.rs](https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/src/protocol/common.rs) — `ThreadNameUpdatedNotification` (app-server layer)
- [DeepWiki — Rollout Persistence and Replay (openai/codex)](https://deepwiki.com/openai/codex/3.5.2-rollout-persistence-and-replay) — community reference
