# Kimi CLI — Session Format Reference

Last researched: 2026-06-21 (Engram session-format research workflow)

> Definitive English reference for how **Kimi CLI** (Moonshot AI's "kimi-code"
> coding CLI) persists sessions on disk, and how Engram's adapters consume them.
> Parallel in structure to the Claude Code and Codex format docs. Sections that
> do not apply to Kimi are marked **"N/A for Kimi"** rather than dropped.

**Evidence basis (this doc):**
- **LIVE on-disk store** at `~/.kimi/` on this machine — **49 workspace dirs**
  (`/bin/ls -1 ~/.kimi/sessions` = 49; `find -mindepth1 -maxdepth1 -type d` = 49;
  matches `kimi.json` `work_dirs` = 49),
  **573 `context.jsonl`** *(= 459 at the Engram-parsed 2-level depth*
  `sessions/<ws>/<sess>/` *+ 114 deeper `subagents/<id>/context.jsonl` that are
  never enumerated)*, **566 `wire.jsonl`** *(= 452 session-level + 114
  subagent)*, **393 `state.json`**, **42
  `context_sub_*.jsonl`**, **2 `context_1.jsonl`**, **6 `subagents/`** dirs, **1
  `tasks/`** dir, **1 `notifications/`** dir. Roles, key-sets, block types,
  wire message types, token-usage shape, `md5(cwd)` workspace hashing, and
  `config.toml` model were all probed directly (≥40–80 files per probe; the
  definitive `message.type` and compaction scans cover all 452 session-level
  `wire.jsonl`).
- **Repo fixtures** — `tests/fixtures/kimi/` (1 synthetic session +
  `schema_drift.jsonl` + `kimi.json`) and `tests/fixtures/adapter-parity/kimi/`
  (`success.expected.json`).
- **Both Engram adapters** — Swift product parser
  `macos/Shared/EngramCore/Adapters/Sources/KimiAdapter.swift` and TS reference
  `src/adapters/kimi.ts` (read in full).

On conflict, **REAL on-disk data wins** and the discrepancy is flagged inline.
All quoted samples are **anonymized to structure (keys + value types)**; no
message text, code, paths, tokens, or secrets are reproduced.

---

## 1. Overview & TL;DR

**What / where / how:**
- **What:** Kimi CLI is Moonshot AI's own coding-CLI ("kimi-code" lineage; the
  `~/.kimi/.migrated-to-kimi-code` marker + `config.toml` provider
  `type = "kimi"` confirm it). It is a **bespoke per-tool JSONL format** — NOT
  Gemini-CLI-family, NOT OpenAI/Codex.
- **Where:** under `~/.kimi/sessions/<md5(cwd)>/<session-uuid>/`.
- **How:** each session is a **directory** of flat **JSONL** files +
  single-object JSON sidecars. There is **no database** (no SQLite, no leveldb,
  no gRPC cache) anywhere in the Kimi store.

**Mental model:** a session = one directory. Two parallel logs describe it:
`context.jsonl` (the *model-context* conversation: role-discriminated message
records) and `wire.jsonl` (the *agent-protocol* event stream: the **only**
source of wall-clock timestamps and token usage). Sidecars (`state.json`,
`kimi.json`, `meta.json`, `spec.json`, …) hold lifecycle/registry metadata.
Engram parses `context.jsonl` (+ rollover shards) for counts/text and
`wire.jsonl` for timestamps/usage, resolves `cwd` via `~/.kimi/kimi.json`, and
ignores everything else.

```
~/.kimi/
 ├─ kimi.json                     ← workspace→cwd registry (last_session_id ⇒ path)   [PARSED for cwd]
 ├─ config.toml                   ← model/provider config (default_model=Kimi-k2.6)   [NOT parsed]
 └─ sessions/
     └─ <md5(cwd)>/               ← workspace hash dir (32 hex)                        [grouping key, not decoded]
         └─ <session-uuid>/       ← session dir; dir name = Engram session id
             ├─ context.jsonl     ← conversation records (role-discriminated)         [PARSED]
             ├─ context_<N>.jsonl ← rotation shards in CURRENT kimi-cli source        [NOT in glob → dropped]
             ├─ context_sub_N.jsonl ← rotation shards in OLDER kimi-cli (on disk)     [PARSED]
             ├─ context_1.jsonl   ← legitimate current rotation shard (2 dirs)        [NOT in glob → dropped]
             ├─ wire.jsonl        ← agent-protocol events (ts + token usage)          [PARSED: 3 of 16 types]
             ├─ state.json        ← lifecycle/title/todos/plan/archive               [NOT parsed]
             ├─ subagents/<id>/   ← nested child agents (own context+wire+meta)        [NOT enumerated]
             ├─ tasks/agent-<id>/ ← async shell/tool tasks (spec/runtime/output)       [NOT parsed]
             └─ notifications/n*/ ← per-session notifications (event+delivery)          [NOT parsed]
```

**Layering (record vs content-block vs event):**
```
context.jsonl line            wire.jsonl line
   = {role, ...}                 = {timestamp, message:{type,payload}}
        │                                  │
   content (string OR array)        message.payload
        │                                  │
   content-block {type:think|text}   token_usage{input_other,output,...}
```

**TL;DR for Engram:** `id` = session-dir UUID; `cwd` from `kimi.json`;
`summary` = first user message (≤200 chars); timestamps from `wire.jsonl`
`TurnBegin`/`TurnEnd`; token usage from `wire.jsonl` `StatusUpdate` (**Swift
only**); only `user`+`assistant` records counted; **`tool` records, array
content blocks, tool calls, reasoning, and `state.json.custom_title` are all
dropped.**

---

## 2. On-disk layout & file naming

**Root:** `~/.kimi/` (both adapters, `KimiAdapter.swift:12-17`, `kimi.ts:38-39`).
**Sessions root:** `~/.kimi/sessions/`.

```
~/.kimi/
├── kimi.json                 # workspace registry → cwd resolution (work_dirs[])
├── kimi.json.bak-*           # timestamped backup copies of kimi.json (rotation; not read)
├── config.toml              # CLI config: default_model, providers, loop_control, ...
├── device_id                 # 32-char device id
├── .migrated-to-kimi-code    # migration marker (kimi → kimi-code lineage)
├── latest_version.txt
├── credentials/  logs/  plans/  plugin-cc/  telemetry/  user-history/
└── sessions/
    └── <workspace-hash>/                  # = md5(absolute_cwd)  [32 lowercase hex]
        └── <session-uuid>/                # RFC-4122 UUID v4  ← Engram session id
            ├── context.jsonl              # PRIMARY conversation log (always present)
            ├── context_<N>.jsonl          # CURRENT kimi-cli rotation output (context_1.jsonl, context_2.jsonl…)
            ├── context_1.jsonl            # legitimate current rotation shard (2 dirs); NOT a rare snapshot
            ├── context_sub_1.jsonl …      # OLDER kimi-cli rotation naming, still on disk (up to _42 seen)
            ├── wire.jsonl                 # agent-protocol event log (ts + usage)
            ├── state.json                 # session lifecycle/title/todos/plan/archive
            ├── notifications/             # optional, per session
            │   └── n<8-hex>/
            │       ├── event.json         # notification record
            │       └── delivery.json      # delivery sink status
            ├── subagents/                 # optional — nested child agents
            │   └── <9-hex agent id>/
            │       ├── context.jsonl      # subagent conversation
            │       ├── wire.jsonl
            │       ├── prompt.txt         # subagent launch prompt (plaintext)
            │       ├── output             # subagent final output (plaintext)
            │       └── meta.json          # subagent metadata
            └── tasks/                     # optional — async tool/shell tasks
                └── agent-<8-alnum>/
                    ├── spec.json          # task spec
                    ├── runtime.json       # task runtime/exit state
                    ├── control.json       # control channel
                    ├── consumer.json      # consumer binding
                    └── output.log         # task stdout/stderr log
```

**Naming grammar (verified live):**

| Token | Grammar | Derivation | Verified |
|---|---|---|---|
| `<workspace-hash>` | `^[0-9a-f]{32}$` (local kaos) / `<kaos>_<md5>` (non-local) | **`md5(absolute_cwd_path)`** when `kaos == local` (default); `f'{kaos}_{md5}'` otherwise | **YES** — 10/10 sampled `work_dirs[].path` had `md5(path)` equal to a real workspace dir. Source-confirmed: `metadata.py` `WorkDirMeta.sessions_dir` |
| `<session-uuid>` | RFC-4122 UUID v4 | random per session | live (`64892815-2590-475c-8112-9c82df9b16f2`) |
| `context_<N>.jsonl` | `N` = base-10 int | rotation index in CURRENT kimi-cli source (`utils/path.next_available_rotation` → `f'{stem}_{N}{suffix}'`) | source-confirmed; NOT matched by adapter glob |
| `context_sub_<N>.jsonl` | `N` = base-10 int | rotation index in OLDER kimi-cli (1..42 observed on disk) | live + `KimiAdapter.swift:183`, `kimi.ts:255`; string absent from current source |
| subagent id | `^[0-9a-f]{9}$` | per subagent | live (`a616a2fc4`) |
| task id | `agent-<8 lowercase alnum>` | per task | live (`agent-oiyhtezo`) |
| notification id | `n<8 hex>` | per notification | live (`n0838353a`) |

> **DISCREPANCY (adapter doc-comment vs reality):** both adapters comment the
> layout as `sessionsRoot/<workspace-id>/<session-id>/context.jsonl` and treat
> the first level as an opaque "workspace id". In reality that level is
> **`md5(cwd)`** — verified 10/10. The adapters never decode the hash; they rely
> solely on `kimi.json` to recover the cwd. Functionally correct, but the layout
> comment understates that the workspace dir name is a *computable forward* hash
> of cwd (an unexploited resolution path — see §15).
>
> **CORRECTED (web-checked 2026-06-21):** the dir name is `md5(path)` **only when
> `kaos == local`** (the default). Source `metadata.py` `WorkDirMeta.sessions_dir`
> builds `dir_basename = path_md5 if kaos == local else f'{kaos}_{path_md5}'`, so
> for a non-local kaos the basename is `<kaos>_<md5>`, not a bare 32-hex string.
> The `^[0-9a-f]{32}$` grammar is therefore the common-case form, not universal.
> [metadata.py](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/metadata.py)

---

## 3. File lifecycle & generation

| Aspect | Behavior | Evidence |
|---|---|---|
| Storage tech | Plain **JSONL** (one JSON object per line) + single-object JSON sidecars | live |
| Database? | **None** — no SQLite/leveldb/gRPC cache | live `find` |
| Append vs rewrite | `context.jsonl` and `wire.jsonl` are **append-only** within a session; never rewritten in place | live |
| Rollover (a.k.a. rotation) | When context grows, Kimi spills into rotation shards that **coexist** with the main file. **CURRENT kimi-cli source names them `context_<N>.jsonl`** (`context_1.jsonl`, `context_2.jsonl`…) via `soul/context.py` → `utils/path.next_available_rotation` (`f'{stem}_{N}{suffix}'`); the on-disk **`context_sub_<N>.jsonl`** (up to `_sub_42` observed) is an **OLDER kimi-cli** naming. The adapters glob only the `context_sub_` prefix, so under current kimi-cli they would MISS the real `context_<N>.jsonl` shards. Reconstruction = main first + `context_sub_*` numerically sorted | `contextFiles()` `KimiAdapter.swift:177-191`; `getAllContextFiles()` `kimi.ts:249-274` |
| Resume / "last session" | `kimi.json.work_dirs[].last_session_id` records the latest session uuid per cwd (used for resume + cwd backfill). A new run mints a new `<session-uuid>` dir under the same `md5(cwd)` workspace | `kimi.json` |
| Subagents | A session spawns nested `subagents/<id>/` — full sub-conversations with their own `context.jsonl`/`wire.jsonl`/`meta.json` | live |
| Tasks | Async `tasks/agent-<id>/` (shell/tool tasks with `runtime.json` exit state); `[background]` in `config.toml` governs them (`max_running_tasks=4`, `agent_task_timeout_s=900`) | live |
| Archive | `state.json.archived`/`archived_at`/`auto_archive_exempt` model an archive lifecycle; **0/200 sampled were archived**. Engram ignores this entirely | live |
| Compaction | Context-window compaction is marked by `_checkpoint` records in `context.jsonl` and `CompactionBegin`/`CompactionEnd` events in `wire.jsonl` (camelCase, no space — verbatim wire type) ; `config.toml` `compaction_trigger_ratio=0.85` | live + config |
| Notifications | `notifications/n*/` accumulate as immutable `event.json`+`delivery.json` pairs | live |

> **`context_1.jsonl` is NOT in either adapter's glob** (the glob matches the
> `context_sub_` prefix only). Both adapters ignore `context_1.jsonl`, so any
> conversation lines that landed only there are not parsed. Only **2 dirs** have
> it; live inspection shows it carries real `user`/`assistant`/`tool`/`_usage`/
> `_checkpoint`/`_system_prompt` records.
>
> **CORRECTED (web-checked 2026-06-21):** `context_1.jsonl` is the **legitimate
> current rotation output**, NOT a "rare pre-rollover/legacy snapshot." Current
> published kimi-cli source rotates to `context_<N>.jsonl` (`context_1.jsonl`,
> `context_2.jsonl`…) via `soul/context.py` → `utils/path.next_available_rotation`;
> the string `context_sub` does not appear in current source at all. So the
> observed `context_sub_*` files reflect an *older* kimi-cli version, and dropping
> `context_<N>.jsonl` is a **real shard-loss bug** under current kimi-cli, not an
> intentional skip of a legacy artifact.
> [next_available_rotation](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/utils/path.py),
> [soul/context.py](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/soul/context.py)

---

## 4. Record / line taxonomy (`context.jsonl`)

One JSON object per line, discriminated by **`role`**. **No top-level
`timestamp`** on any live `context.jsonl` line (confirmed across 60 files) — so
the adapters' per-line timestamp path is effectively dead for live data and
always falls back to `wire.jsonl`.

Live record distribution (representative sample of 50 files) and exact
top-level key-sets:

| `role` | Exact key-set (live) | Live count (sample) | Purpose | Engram handles? |
|---|---|---|---|---|
| `_usage` | `role, token_count` | 182 | Per-snapshot cumulative token watermark (int) | **No** — Engram reads tokens from `wire.jsonl` instead |
| `tool` | `content, role, tool_call_id` | 167 | Tool result fed back to model; `content` is an **array** of result blocks | **No** — `isConversation` rejects it; `toolMessageCount` hardcoded `0` |
| `_checkpoint` | `id, role` | 158 | Compaction/rollback marker; `id` is an int (0,1,2…) | **No** — TS explicitly `continue`s (`kimi.ts:119`); Swift filtered via `isConversation` |
| `user` | `content, role` | 93 | User turn; `content` usually a **string** (rarely an array) | **Yes** → user message |
| `assistant` | `content, role, tool_calls` / `content, role` | 62 + 29 | Model turn; `content` **string OR array of blocks**; optional `tool_calls[]` | **Yes** → assistant message |
| `_system_prompt` | `content, role` | 50 | Full system prompt snapshot (`content` string, ~43 KB live) | **No** — skipped; `systemMessageCount` hardcoded `0` |

> **DISCREPANCY (Dim-2 report vs live):** Dim 2 claimed `_system_prompt` is
> `{role, id:null, content}`. Live data shows **only `content, role`** (79/79
> sampled have no `id` key). **Live wins: no `id` field on `_system_prompt`.**

> **Tool-call ↔ result linkage exists on disk** (`assistant.tool_calls[].id` →
> `tool.tool_call_id`) but **Engram captures none of it** (see §7).

---

## 5. Shared envelope / metadata fields

`context.jsonl` records share a thin envelope: **`role`** (the discriminator)
plus role-specific payload keys. There is no shared id/timestamp/uuid envelope
across record types (unlike Claude Code / Codex). The envelope is per §4.

`wire.jsonl` event lines share a uniform envelope:

| Field | Type | Meaning | Optionality | Example |
|---|---|---|---|---|
| `timestamp` | number (epoch **seconds**, float) | Event wall-clock | every event line (absent on header line) | `1770000060.0` |
| `message` | object `{type, payload?}` | Typed event payload | every event line | `{"type":"TurnBegin","payload":{...}}` |
| `type` | string | Header marker (`"metadata"`) | **header line only** | `"metadata"` |
| `protocol_version` | string | Wire protocol version | **header line only** | `"1.9"` |

`kimi.json` (workspace registry) envelope: single top-level key `work_dirs[]`
of `{path, kaos, last_session_id}` — see §13.

---

## 6. Message & content schema

### 6a. `user` record
`content` is a plain **string** (112/112 string in live sample; 2 array cases
exist repo-wide). No block wrapping.

```json
{"role": "user", "content": "<user prompt text>"}
```

| Field | Type | Opt | Meaning |
|---|---|---|---|
| `role` | string | req | `"user"` |
| `content` | string (rarely array of `{type:"text",text}`) | req | Raw user text |

### 6b. `assistant` record
`content` is **polymorphic** — an **array of content blocks** in the common live
case, or a plain **string** (rare). `tool_calls[]` is optional. Live content-type
ratio in sample: array ≫ string (74 array vs 9 string assistant turns; block
types `think`=69, `text`=38).

```json
{
  "role": "assistant",
  "content": [
    {"type": "think", "think": "<reasoning text>", "encrypted": null},
    {"type": "text",  "text":  "<visible answer text>"}
  ],
  "tool_calls": [
    {"id": "tool_<rand>", "type": "function",
     "function": {"name": "<ToolName>", "arguments": "{\"<arg>\":\"<val>\"}"}}
  ]
}
```

| Field | Type | Opt | Meaning |
|---|---|---|---|
| `role` | string | req | `"assistant"` |
| `content` | string \| array of blocks | req | Plain text OR list of content blocks |
| `tool_calls` | array | opt | OpenAI-style function calls this turn |

**Nested layer — assistant `content` blocks** (block `type` discriminator):

| Block `type` | Fields | Types | Meaning |
|---|---|---|---|
| `think` | `type`, `think`, `encrypted` | str, **string (reasoning text)**, null | Chain-of-thought; `encrypted` null in all live data |
| `text` | `type`, `text` | str, string | Visible assistant prose |

**Nested layer — assistant `tool_calls[]`** (live key-set `function,id,type`):

| Field | Type | Meaning | Example |
|---|---|---|---|
| `id` | string | Tool-call id; links to `tool.tool_call_id` + wire `ToolCall.payload.id` | `"tool_<rand>"` |
| `type` | string | Always `"function"` | `"function"` |
| `function.name` | string | Tool name | `"<ToolName>"` |
| `function.arguments` | **string** | JSON-encoded args (stringified, not an object) | `"{\"<arg>\":\"<val>\"}"` |

> **DISCREPANCY (live vs adapter — assistant body loss, HIGH impact):** both
> adapters read the body with a **string-only** accessor:
> - Swift `KimiAdapter.swift:258` → `JSONLAdapterSupport.string(object["content"]) ?? ""`
> - TS `kimi.ts:226` → `typeof obj.content === 'string' ? obj.content : ''`
>
> When `content` is an **array** (the dominant live case), both return `""`. So
> **assistant text AND reasoning are dropped** for array-form sessions; the
> message is still *counted* (so `assistantMessageCount` is right) but its
> transcript/search body is **empty**. The fixtures only exercise the **string**
> form, so parity tests never catch this. **Live wins: assistant content is
> array-shaped in the field; the indexed body is empty.**

### 6c. `tool` record
`content` is **usually an array** of result blocks, but is **occasionally a
plain string** (live: array ≫ string — e.g. 77 array vs 11 string `tool`
records in an 80-file sample); `tool_call_id` links back to the assistant call.
**Not indexed** by Engram.

```json
{"role": "tool", "tool_call_id": "tool_<rand>",
 "content": [{"type": "text", "text": "<tool output>"}]}
```

| Field | Type | Meaning |
|---|---|---|
| `role` | string | `"tool"` |
| `tool_call_id` | string | Links to `assistant.tool_calls[].id` |
| `content` | array of blocks (usually) \| plain string (occasionally) | Result blocks, or a raw string result |

**Nested layer — tool `content` blocks:**

| Block `type` | Fields | Meaning |
|---|---|---|
| `text` | `type`, `text` | Tool stdout / textual result (dominant) |
| `image_url` | `type`, `image_url{id,url}` | Image result (`image_url` is an object) |

### 6d. Marker records (not message-bearing)
- `_system_prompt`: `{"role":"_system_prompt","content":"<system text>"}`
- `_checkpoint`: `{"role":"_checkpoint","id":0}` (id is int)
- `_usage`: `{"role":"_usage","token_count":10863}` (running context-size watermark)

---

## 7. Tool calls & results

**On disk (rich):** call↔result linkage is fully present —
`assistant.tool_calls[].id` (string `tool_<rand>`) joins to `tool.tool_call_id`;
the same id also appears in `wire.jsonl` as `ToolCall.payload.id` and
`ToolResult.payload.tool_call_id`. Errors are carried in
`wire.jsonl` `ToolResult.payload.return_value.is_error` + `.output`/`.message`.

**In Engram (none):** the Kimi adapter **never extracts tool calls**.
`KimiAdapter.message(...)` always passes **`toolCalls: nil`**
(`KimiAdapter.swift:260`); TS omits the field. Parity fixture confirms
`"toolCalls": []`, `toolCallCount: 0`. The `tool` role records (167 in sample;
~24% of conversation records in heavy sessions) are dropped entirely:
`toolMessageCount` is hardcoded `0` (`KimiAdapter.swift:82`, `kimi.ts:153`).

```json
// assistant tool_calls[i] (live, anonymized)
{"id": "tool_<rand>", "type": "function",
 "function": {"name": "<ToolName>", "arguments": "{\"<arg>\":\"<val>\"}"}}
// matching tool result record
{"role": "tool", "tool_call_id": "tool_<rand>",
 "content": [{"type": "text", "text": "<tool output>"}]}
```

---

## 8. Reasoning / thinking

**Stored on disk:** YES. Assistant reasoning lives in `content` blocks of
`type: "think"` (field `think` = plaintext reasoning string; `encrypted` null in
all live data). Also streamed in `wire.jsonl` as `ContentPart` events with
`{type:"think",think,encrypted}`. `config.toml` `default_thinking=true` +
`show_thinking_stream=true` confirm reasoning is first-class in Kimi.

**Captured by Engram:** NO. Because `think` is an array block and the adapters
use a string-only content accessor (§6b), reasoning is dropped to `""`. Engram
has no separate reasoning/thinking field for Kimi.

---

## 9. Token usage & cost

**Source:** `wire.jsonl` `StatusUpdate.payload.token_usage` (the `_usage`
records inside `context.jsonl` are **ignored**). Live `token_usage` key-set
(30/30 sampled): `input_cache_creation, input_cache_read, input_other, output`.

```json
{"timestamp": 1770000060.0, "message": {"type": "StatusUpdate", "payload": {
  "context_usage": <float>, "context_tokens": <int>, "max_context_tokens": <int>,
  "token_usage": {"input_other": <int>, "output": <int>,
                  "input_cache_read": <int>, "input_cache_creation": <int>},
  "message_id": "<id>", "plan_mode": <bool>, "mcp_status": null}}}
```

Mapping (`usage(from:)` `KimiAdapter.swift:265-281`):

| Source field | Engram `TokenUsage` |
|---|---|
| `input_other` | `inputTokens` |
| `output` | `outputTokens` |
| `input_cache_read` | `cacheReadTokens` |
| `input_cache_creation` | `cacheCreationTokens` |

Per-turn usage is **accumulated** across all `StatusUpdate`s between a
`TurnBegin`/`TurnEnd` pair and attached to the turn's assistant message
(`accumulatedUsage`, `KimiAdapter.swift:283-291`). All-zero usage is dropped to
`nil` (`KimiAdapter.swift:273-279`). **Cost is not computed** (model price not
parsed).

> **Swift/TS PARITY GAP (real divergence):** TS `readTurnTimestamps`
> (`kimi.ts:303-327`) reads `TurnBegin`/`TurnEnd` **only** and never reads
> `StatusUpdate`/`token_usage`. **Only the Swift product parser populates
> usage; the TS reference adapter emits NO token data.** Parity fixture has
> all-zero `usageTotals`, so this gap is uncovered.

---

## 10. Subagent / parent-child / dispatch

**On disk:** Kimi has a **first-class subagent model**:
- `subagents/<9-hex id>/` per session: full child conversation with its own
  `context.jsonl`/`wire.jsonl`/`meta.json`/`prompt.txt`/`output`.
- `meta.json` keys (live): `agent_id, subagent_type, status, description,
  created_at, updated_at, last_task_id, launch_spec`.
- `wire.jsonl` `SubagentEvent` (131 in sample) wraps a full child event stream:
  `{parent_tool_call_id, agent_id, subagent_type, event{type,payload}}` (the
  inner `event.payload` mirrors ToolCall/ToolResult/StatusUpdate/TurnBegin/
  StepBegin shapes).

**In Engram:** **NO Kimi parent-child linkage.** The discovery walk is a fixed
**2-level** scan (`sessions/<workspace>/<session>/context.jsonl`); subagent
`context.jsonl` files live one level deeper
(`…/<session>/subagents/<id>/context.jsonl`) and are **never enumerated** as
independent sessions, nor linked to the parent. No `.engram.json` sidecar (that
is a Gemini-CLI mechanism). Engram emits `parentSessionId: nil` /
`suggestedParentId: nil` for all Kimi sessions. Whether Kimi subagents *should*
be grouped like Claude Code subagents is **OPEN**.

---

## 11. Summary / compaction

- **Summary:** Engram's session `summary` = **first user message text**,
  `prefix(200)` (`KimiAdapter.swift:67,84`, `kimi.ts:124,155`). Kimi's own
  generated title (`state.json.custom_title`) is **ignored** (see §15).
- **Compaction:** present on disk as `_checkpoint` records (`context.jsonl`) and
  `CompactionBegin`/`CompactionEnd` events (`wire.jsonl`; camelCase single token,
  no space — like every other wire `message.type`), driven by
  `config.toml` `compaction_trigger_ratio=0.85` / `reserved_context_size=50000`.
  Engram skips `_checkpoint` and does not interpret compaction. The
  `context_sub_<N>.jsonl` rollover shards are the on-disk consequence of growth
  past the window.

---

## 12. SQLite / DB internals

**N/A for Kimi.** Kimi uses **no database** — pure flat JSONL + JSON sidecars.
(`find ~/.kimi` shows no `.sqlite`/`.vscdb`/leveldb.) This contrasts with
DB-backed tools documented elsewhere (Cursor / VS Code / Copilot / Cline use
`.vscdb`/leveldb).

---

## 13. Auxiliary files

### 13a. `~/.kimi/kimi.json` — workspace registry (PARSED for cwd)
Single object, sole top-level key `work_dirs[]`. **49 entries live** (one per
workspace, keyed on the *last* session).

```json
{"work_dirs": [{"path": "<absolute cwd>", "kaos": "local", "last_session_id": "<uuid>"}]}
```

| Field | Type | Meaning | Engram use |
|---|---|---|---|
| `path` | string | Absolute working directory | → session `cwd` |
| `kaos` | string | Storage class tag (`"local"`) | unused |
| `last_session_id` | string | Most-recent session uuid for that cwd | match key for cwd lookup |

> **LIMITATION:** only **49** work_dirs vs **573** session dirs → only the
> most-recent session per workspace resolves a cwd; the rest get `cwd = ""`.
> Backups `kimi.json.bak-*` are rotated copies, not read.

### 13b. `state.json` — session lifecycle (NOT parsed)
Union of keys across 200 live sessions (most common first; 199/200 carry the
title/archive/todo set, 1 newer-schema variant carried `dynamic_subagents`
instead):

| Field | Type | Meaning |
|---|---|---|
| `version` | int | state schema version |
| `approval` | object | `{yolo, afk, auto_approve_actions[]}` permission state |
| `additional_dirs` | array | extra allowed workspace dirs |
| `custom_title` / `title_generated` / `title_generate_attempts` | str? / bool / int | session title generation state |
| `plan_mode` / `plan_session_id` / `plan_slug` | bool / str / str | plan-mode linkage |
| `wire_mtime` | null | cached wire mtime |
| `archived` / `archived_at` / `auto_archive_exempt` | bool / null·num / bool | archive lifecycle |
| `todos` | array | session todo list |
| `dynamic_subagents` | array/object | (newer schema variant) dynamically registered subagents |

### 13c. Subagent `meta.json` (NOT parsed)
`agent_id, subagent_type, status, description, created_at(num), updated_at(num),
last_task_id, launch_spec(obj)`.

### 13d. Task files (NOT parsed)
- `spec.json`: `version, id, kind, session_id, description, tool_call_id,
  owner_role, created_at(num), command, shell_name, shell_path, cwd, timeout_s,
  kind_payload(obj)`.
- `runtime.json`: `status, worker_pid, child_pid, child_pgid, started_at,
  heartbeat_at(num), updated_at(num), finished_at(num), exit_code, interrupted,
  timed_out, failure_reason`.
- `control.json`, `consumer.json`, `output.log` — control/plaintext.

### 13e. Notification files (NOT parsed)
- `event.json`: `version, id, category, type, source_kind, source_id, title,
  body, severity, created_at(num), payload(obj), targets(arr), dedupe_key`.
- `delivery.json`: `sinks(obj)`.

### 13f. `config.toml` (NOT parsed) — but holds the model
```toml
default_model = "kimi-code/kimi-for-coding"
[models."kimi-code/kimi-for-coding"]
provider = "managed:kimi-code"
model = "kimi-for-coding"
display_name = "Kimi-k2.6"
[providers."managed:kimi-code"]
type = "kimi"
base_url = "https://api.kimi.com/coding/v1"
```
Engram leaves `model = nil` for Kimi despite this being available (see §15).

> **Confirmed (official, web-checked 2026-06-21):** the official Config/Providers
> docs show `default_model = "kimi-code/kimi-for-coding"`, provider
> `managed:kimi-code` (`type='kimi'`, `base_url='https://api.kimi.com/coding/v1'`),
> and source `config.py` confirms `compaction_trigger_ratio` default 0.85,
> reserved context size default 50000, and `default_thinking` + `show_thinking_stream`.
> The `display_name = "Kimi-k2.6"` string is a **user-config-dependent** human
> label (provider-sourced via `config.py` `LLMModel.display_name`), not a fixed
> constant.
> [Providers docs](https://moonshotai.github.io/kimi-cli/en/configuration/providers.html),
> [config.py](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/config.py)

---

## 14. Engram mapping

`SessionInfo` field → source of truth → adapter `file:line` (Swift product + TS reference):

| Engram field | Source of truth | Swift `KimiAdapter.swift` | TS `kimi.ts` | Notes / gotcha |
|---|---|---|---|---|
| `id` | session-dir UUID = `basename(dirname(context.jsonl))` | `:68` | `:80,84` | Workspace hash discarded. TS guards against `''`/`.`/`..` (`:84`); Swift has no guard. |
| `source` | constant `.kimi` | `:73` | `:146` | |
| `startTime` | first `TurnBegin` ts in `wire.jsonl` | `:74,200-208,223` | `:88,138-141,316-317` | Fallback: Swift = wireStart → `mtime-60s`; TS = wireStart → first line ts → `mtime-60s`. Live has no line ts. |
| `endTime` | last turn `TurnEnd` (else its begin); emitted nil if == start | `:75,207,225` | `:89-92,142,318-321` | "first TurnEnd wins" — may reflect an early sub-turn. |
| `cwd` | `kimi.json` `work_dirs[].path` keyed by `last_session_id == id` | `:76,162-175` | `:86,276-298` | `""` if no match → only most-recent session per workspace resolves. |
| `project` | always `nil` | `:77` | n/a | Derived downstream from cwd. |
| `model` | always `nil` | `:78` | n/a | Available in `config.toml` (Kimi-k2.6) but never parsed. |
| `messageCount` | `userCount + assistantCount` | `:79` | `:150` | **Excludes `tool`** → undercount. |
| `userMessageCount` | count `role=="user"` | `:59,80` | `:122-126,151` | |
| `assistantMessageCount` | count `role=="assistant"` | `:60,81` | `:127-129,152` | |
| `toolMessageCount` | hardcoded `0` | `:82` | `:153` | Despite many live `tool` records. |
| `systemMessageCount` | hardcoded `0` | `:83` | `:154` | `_system_prompt` exists but never counted. |
| `summary` | first user message text, `prefix(200)` | `:67,84` | `:124,155` | **`state.json.custom_title` IGNORED.** |
| `sizeBytes` | sum of `context.jsonl` + all `context_sub_*.jsonl` | `:51-56,86` | `:99-107,157` | `wire.jsonl`/`state.json`/`context_1.jsonl` excluded. |
| `filePath` | absolute path to `context.jsonl` | `:85` | `:156` | The locator. |
| per-msg `role` | `user→.user`, `assistant→.assistant` | `:257` | `:225` | Only 2 roles ever produced. |
| per-msg `content` | `obj.content` as string | `:258` | `:226` | **Array content (think/text) → empty string.** |
| per-msg `timestamp` | wire turn ts via state machine; else line ts (absent live) | `:137-149,300-308` | `:203-228,237-243` | See §15 #1. |
| per-msg `usage` | wire `StatusUpdate.token_usage` (assistant only) | `:145,261,265-281` | **not implemented** | **Swift-only.** |
| per-msg `toolCalls` | always `nil` | `:260` | omitted | Tool calls never surfaced. |
| `agentRole`/`originator`/`origin`/`parentSessionId`/`suggestedParentId`/`tier`/`qualityScore` | all `nil` | `:88-95` | n/a | No Kimi subagent linkage. |

**Discovery walk** (both adapters, fixed 2-level, no recursion):
1. `detect()` — true iff `~/.kimi/sessions/` is a directory (`KimiAdapter.swift:25-27`, `kimi.ts:42-49`).
2. Enumerate `sessions/<workspace>/<session>/context.jsonl`; locator = absolute path to `context.jsonl`; session id = parent dir name (`listSessionLocators` `:29-44`; `listSessionFiles` `:51-75`). Swift sorts results.
3. `parseSessionInfo(locator)` reads main + `context_sub_*` (concatenated), counts user/assistant, summary = first user text, ts from `wire.jsonl`, cwd from `kimi.json`.

---

## 15. Lineage, gotchas, version drift & edge cases

**Format lineage — BESPOKE.** Kimi/Moonshot CLI has its **own** format. The
`context.jsonl` / `wire.jsonl` / `state.json` triad and the `wire.jsonl`
`protocol_version` are unique to Kimi. It belongs to **none** of the documented
sibling families: NOT Gemini-CLI ↔ Qwen ↔ iFlow (chat-JSON lineage), NOT
Cursor ↔ VS Code ↔ Copilot ↔ Cline (`.vscdb`/leveldb). Cross-reference those
docs for contrast, but nothing is shared. Kimi is a plain JSONL adapter (no
gRPC), so it is NOT in the cache-only Windsurf/Antigravity set. **Confirmed (official):** the triad and the
`protocol_version`'d wire envelope are Kimi-specific constructs defined in
MoonshotAI/kimi-cli's own source (`wire/protocol.py`, `metadata.py`,
`soul/context.py`); no schema is shared with Gemini-CLI or OpenAI/Codex.
[wire/protocol.py](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/wire/protocol.py),
[metadata.py](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/metadata.py)

> **CONTEXT — NEW `kimi-code` store (web-checked 2026-06-21, D3).** This doc
> scopes the **legacy Python `kimi-cli`** store at `~/.kimi/`. Moonshot has since
> shipped a **new TypeScript `kimi-code` CLI** whose default store is
> `~/.kimi-code/` (`KIMI_CODE_HOME`), with a different layout:
> `sessions/<workDirKey>/<sessionId>/{state.json, agents/main/wire.jsonl,
> agents/<subagentId>/wire.jsonl}`, a top-level `session_index.jsonl`, and
> `workDirKey = 'wd_<slug>_<first-12-of-sha256>'` (**NOT bare md5**). If a user
> has migrated (the `.migrated-to-kimi-code` marker), new sessions land under
> `~/.kimi-code/` in the new layout, and Engram's `~/.kimi`-only adapter will
> **not** see them.
> [Data locations](https://www.kimi.com/code/docs/en/kimi-code-cli/configuration/data-locations.html),
> [Sessions](https://www.kimi.com/code/docs/en/kimi-code-cli/guides/sessions.html)

**Gotchas / edge cases:**
1. **Turn state-machine misalignment on agentic sessions (HIGH).** Both adapters
   assume ≤1 user + ≤1 assistant per wire turn (`KimiAdapter.swift:128-143`,
   `kimi.ts:203-216`). Live multi-step sessions violate this badly (assistant
   records ≫ `TurnBegin` count). When assistant ≫ turns, the index walks off the
   end of `turns[]` (`turnIndex < turns.count` guard → nil) and most assistant
   messages get **no timestamp**. Well-tested for the clean-alternation fixture;
   not representative of real tool-using sessions.
2. **`TurnBegin` count ≫ `TurnEnd` count is normal.** Live wire logs routinely
   have ~2× more `TurnBegin` (sub-turns/interruptions). "first TurnEnd wins"
   (`:225`) means `endTime` may reflect an early sub-turn, not the true last
   activity.
3. **`tool` role dropped → message undercount + lost tool I/O (MEDIUM).** Many
   live `tool` records (≈24% of conversation records in heavy sessions) are
   excluded from counts and transcript. Any feature using `messageCount`
   (tiering, sparklines) under-reports Kimi.
4. **Array content silently emptied (MEDIUM/HIGH).** Kimi's dominant assistant
   format is array blocks (`think`/`text`); the string-only accessor drops both
   visible answer AND reasoning to `""` for most assistant turns. FTS/search over
   Kimi sessions will be largely empty for these. The fixture (string-only)
   hides it.
5. **`custom_title` ignored (LOW-MED).** ~199/200 live sessions carry a
   `state.json.custom_title`, but Engram uses raw first-user-text truncated to
   200 chars.
6. **No line-level timestamps live → `wire.jsonl` is mandatory.** Zero live
   `context.jsonl` records have a `timestamp`. If `wire.jsonl` is missing, Swift
   falls back only to `mtime-60s` (TS additionally tries line ts, also absent).
   Line-level ts appears only in the `schema_drift.jsonl` fixture.
7. **`protocol_version` drift unguarded.** Live wire headers (first line of all
   452 session-level `wire.jsonl`): **1.3, 1.5, 1.9 (dominant), 1.10** —
   `Counter{1.9: 436, 1.10: 12, 1.3: 2, 1.5: 2}`. (All four occur in live data;
   1.3 is not fixture-only.) Neither adapter reads or version-gates on it, so a
   future wire schema change (renamed message types, new `token_usage` keys)
   would silently degrade timestamps/tokens with no error.
   **Confirmed (official):** source `wire/protocol.py` defines
   `WIRE_PROTOCOL_VERSION = "1.10"` (current) and `WIRE_PROTOCOL_LEGACY_VERSION =
   "1.1"`; the official Wire Protocol doc states "the current protocol version is
   1.10". The value is a free string, so older `1.3`/`1.5`/`1.9` headers persist
   and the "drift unguarded" framing holds. Note the source LEGACY constant is
   `1.1` — older than any value observed live.
   [wire/protocol.py](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/wire/protocol.py),
   [Wire Protocol docs](https://www.kimi.com/code/docs/en/kimi-code-cli/customization/wire-protocol.html)
8. **cwd resolution lossy.** Only the workspace's most-recent session
   (`last_session_id`) resolves a cwd; all prior sessions sharing that workspace
   hash get `cwd == ""`. The 32-hex dir name is **`md5(cwd)`** and is never
   reverse-mapped — but it IS computable *forward*, so an unexploited fix is to
   build a `md5(work_dirs[].path) → path` map covering every workspace, not just
   the last session. **Confirmed (official):** `md5(cwd)` is forward-computable
   from `kimi.json` `work_dirs[].path`; source `metadata.py` builds the dir name
   exactly that way (for local kaos).
   [metadata.py](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/metadata.py)
9. **Swift vs TS divergences:** (a) token usage — Swift reads `StatusUpdate`, TS
   does not; (b) startTime fallback — TS has a line-ts tier Swift lacks;
   (c) session-id sanity guard — TS only; (d) `_checkpoint` — TS explicitly
   `continue`s, Swift filters via `isConversation` (same net effect).
10. **`context_<N>.jsonl` rotation shards dropped (CORRECTED, web-checked
    2026-06-21).** The adapters glob only the `context_sub_` prefix. Current
    kimi-cli source names rotation shards `context_<N>.jsonl` (`context_1.jsonl`,
    `context_2.jsonl`…) via `utils/path.next_available_rotation`, and the string
    `context_sub` does not appear in current source. So `context_1.jsonl` (2 dirs)
    is the **legitimate current rotation output**, not a "rare legacy snapshot,"
    and under current kimi-cli the adapters would miss ALL `context_<N>.jsonl`
    shards. This is a real shard-loss bug, not an intentional skip. The older
    `context_sub_*` naming is what the glob still matches on this disk.
    [next_available_rotation](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/utils/path.py)
11. **`state.json` schema drift.** A newer variant carries `dynamic_subagents`
    and omits the title/archive/todo block (1/200 live). Dim 2's claimed
    `_system_prompt.id:null` was not reproduced live (no `id` key at all).

**OPEN questions / unverified** (carry forward). Each item below is an
**Engram-internal adapter design decision, not a web-verifiable tool-format
fact**; the underlying on-disk facts they depend on are all source-confirmed
above (web-checked 2026-06-21):

- Extract array `think`/`text` blocks into transcript content? *(Engram-internal
  design — not web-verifiable; array content blocks confirmed to exist, §6b.)*
- Count/surface `tool` records? *(Engram-internal design — not web-verifiable;
  `tool` records confirmed to exist, §6c.)*
- Use `state.json.custom_title` as title? *(Engram-internal design — not
  web-verifiable; `custom_title` confirmed present in `state.json`,
  [session_state.py](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/session_state.py).)*
- Replace the wire turn state-machine with event-based alignment
  (`ContentPart`/`StepBegin`/`ToolResult`)? *(Engram-internal design — not
  web-verifiable; those wire types confirmed, §16.)*
- Bring TS to parity on `token_usage`? *(Engram-internal design — not
  web-verifiable.)*
- Parse `config.toml` model into `model`? *(Engram-internal design — not
  web-verifiable; `config.toml` confirmed to carry the model,
  [config.py](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/config.py).)*
- Reverse-map / forward-map `md5(cwd)` for older sessions? *(Engram-internal
  design — not web-verifiable; `md5(cwd)` confirmed forward-computable from
  `kimi.json` `work_dirs[].path`,
  [metadata.py](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/metadata.py).)*
- Link Kimi subagents like Claude Code subagents? *(Engram-internal design — not
  web-verifiable; subagents are first-class on disk,
  [subagents/store.py](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/subagents/store.py).)*
- Glob fix: also match the CURRENT `context_<N>.jsonl` rotation shards, not only
  the older `context_sub_` prefix? *(Engram-internal design — the format fact is
  resolved: current source rotates to `context_<N>.jsonl`, see gotcha #10.)*

**Format facts confirmed against official sources (web-checked 2026-06-21):**
the following items, previously framed as "to verify," are now source-confirmed
and folded into the body above:

- Confirmed (official): `wire.jsonl` envelope is `{timestamp:float (epoch
  seconds), message:{type,payload}}` with a first-line header
  `{type:"metadata", protocol_version:str}`.
  [wire/file.py](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/wire/file.py)
- Confirmed (official): wire `message.type` set (TurnBegin/TurnEnd, StatusUpdate,
  ToolCall/ToolCallPart, ToolResult, ContentPart, StepBegin/StepInterrupted,
  SubagentEvent, CompactionBegin/CompactionEnd, SteerInput, ApprovalRequest/
  Response, Notification) is real; spec adds StepRetry, PlanDisplay,
  HookTriggered/HookResolved the live scan did not surface.
  [Wire Protocol docs](https://www.kimi.com/code/docs/en/kimi-code-cli/customization/wire-protocol.html)
- Confirmed (official): `StatusUpdate.token_usage` keys are exactly
  `input_other`, `output`, `input_cache_read`, `input_cache_creation`.
  [Wire Protocol docs](https://www.kimi.com/code/docs/en/kimi-code-cli/customization/wire-protocol.html)
- Confirmed (official): store root is `~/.kimi/` (`KIMI_SHARE_DIR` overridable);
  `kimi.json` is the workspace registry with `work_dirs[]` of
  `{path, kaos, last_session_id}`.
  [share.py](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/share.py),
  [metadata.py](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/metadata.py)
- Confirmed (official): each session is a directory of `context.jsonl` +
  `wire.jsonl` + `state.json`.
  [session.py](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/session.py),
  [session_state.py](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/session_state.py)
- Confirmed (official): marker record shapes — `_system_prompt` has NO `id`
  (`{role,content}`), `_checkpoint = {role, id:int}`, `_usage = {role,
  token_count:int}` (this resolves the old "Dim 2" `id:null` claim).
  [soul/context.py](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/soul/context.py)
- Confirmed (official): subagent layout `subagents/<id>/{context.jsonl,
  wire.jsonl, meta.json, prompt.txt, output}` with `meta.json` keys
  `agent_id/subagent_type/status/description/created_at/updated_at/last_task_id/
  launch_spec`; new kimi-code uses `agents/main/` + `agents/<id>/` instead.
  [subagents/store.py](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/subagents/store.py)
- Confirmed (official): notification files are `notifications/<id>/event.json` +
  `delivery.json`.
  [notifications/store.py](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/notifications/store.py)
- Confirmed (official): `config.toml` structure & defaults — `default_model =
  "kimi-code/kimi-for-coding"`, provider `managed:kimi-code` (`type='kimi'`,
  `base_url='https://api.kimi.com/coding/v1'`), `compaction_trigger_ratio` 0.85,
  reserved context size 50000, `default_thinking` true. `display_name "Kimi-k2.6"`
  is a user-config-dependent human label (provider-sourced), not a fixed
  constant.
  [Providers docs](https://moonshotai.github.io/kimi-cli/en/configuration/providers.html),
  [config.py](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/config.py)
- Confirmed (official): no database — session persistence is flat JSONL + JSON
  sidecars via plain file writes; no SQLite/leveldb/gRPC. (New kimi-code adds a
  `session_index.jsonl` index file, still JSONL, not a DB.)
  [session.py](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/session.py)
- Confirmed (partial, official): the rotation shard is `context_<N>.jsonl` in
  current source, NOT `context_sub_<N>.jsonl`; `context_1.jsonl` is the
  legitimate current shard (see gotcha #10, D1).
  [next_available_rotation](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/utils/path.py)

---

## 16. Appendix: real anonymized samples

**`context.jsonl` — `user` record:**
```json
{"role": "user", "content": "<user prompt text>"}
```

**`context.jsonl` — `assistant` record (array content + tool_calls):**
```json
{"role": "assistant",
 "content": [
   {"type": "think", "think": "<reasoning text>", "encrypted": null},
   {"type": "text",  "text":  "<visible answer text>"}],
 "tool_calls": [
   {"id": "tool_<rand>", "type": "function",
    "function": {"name": "<ToolName>", "arguments": "{\"<arg>\":\"<val>\"}"}}]}
```

**`context.jsonl` — `assistant` record (string content, rare):**
```json
{"role": "assistant", "content": "<visible answer text>"}
```

**`context.jsonl` — `tool` record:**
```json
{"role": "tool", "tool_call_id": "tool_<rand>",
 "content": [{"type": "text", "text": "<tool output>"}]}
```

**`context.jsonl` — marker records:**
```json
{"role": "_system_prompt", "content": "<system text>"}
{"role": "_checkpoint", "id": 0}
{"role": "_usage", "token_count": 10863}
```

**`wire.jsonl` — header line (line 1):**
```json
{"type": "metadata", "protocol_version": "1.9"}
```

**`wire.jsonl` — event lines:**
```json
{"timestamp": 1770000000.0, "message": {"type": "TurnBegin", "payload": {"user_input": "<str or [{type:text,text}]>"}}}
{"timestamp": 1770000060.0, "message": {"type": "StatusUpdate", "payload": {
  "context_usage": <float>, "context_tokens": <int>, "max_context_tokens": <int>,
  "token_usage": {"input_other": <int>, "output": <int>,
                  "input_cache_read": <int>, "input_cache_creation": <int>},
  "message_id": "<id>", "plan_mode": false, "mcp_status": null}}}
{"timestamp": 1770000090.0, "message": {"type": "ToolCall", "payload": {
  "type": "function", "id": "tool_<rand>",
  "function": {"name": "<ToolName>", "arguments": "<json-string>"}, "extras": {}}}
{"timestamp": 1770000091.0, "message": {"type": "ToolResult", "payload": {
  "tool_call_id": "tool_<rand>",
  "return_value": {"is_error": false, "output": "<str>", "message": "<str>", "display": [], "extras": {}}}}
{"timestamp": 1770000120.0, "message": {"type": "TurnEnd", "payload": {}}}
```

**`wire.jsonl` — full `message.type` set observed live (16):**
definitive scan of `message.type` across all 452 non-empty session-level
`wire.jsonl` files yields **16 distinct top-level types** (all camelCase single
tokens, incl. the Compaction pair):
`SubagentEvent, ToolCall, ToolResult, ContentPart, StepBegin, StatusUpdate,
ToolCallPart, TurnBegin, TurnEnd, Notification, StepInterrupted, SteerInput,
ApprovalRequest, ApprovalResponse, CompactionBegin, CompactionEnd`
(plus header `type: metadata`). Per-type counts (this scan): `SubagentEvent`
6562, `ToolCall` 2028, `ToolResult` 2023, `ContentPart` 1999, `StepBegin` 1551,
`StatusUpdate` 1499, `ToolCallPart` 1450, `TurnBegin` 556, `TurnEnd` 527,
`Notification` 55, `StepInterrupted` 27, `SteerInput` 5, `ApprovalRequest` 4,
`ApprovalResponse` 4, `CompactionBegin` 2, `CompactionEnd` 2. Engram reads only
`TurnBegin`, `TurnEnd`, `StatusUpdate`.

**`~/.kimi/kimi.json`:**
```json
{"work_dirs": [{"path": "<absolute cwd>", "kaos": "local", "last_session_id": "<session-uuid>"}]}
```

**`state.json` (NOT parsed):**
```json
{"version": <int>, "approval": {"yolo": false, "afk": false, "auto_approve_actions": []},
 "additional_dirs": [], "custom_title": "<str?>", "title_generated": false,
 "title_generate_attempts": 0, "plan_mode": false, "plan_session_id": "<str>",
 "plan_slug": "<str>", "wire_mtime": null, "archived": false, "archived_at": null,
 "auto_archive_exempt": false, "todos": []}
```

**Subagent `meta.json` (NOT parsed):**
```json
{"agent_id": "<9hex>", "subagent_type": "<str>", "status": "<str>",
 "description": "<str>", "created_at": <num>, "updated_at": <num>,
 "last_task_id": null, "launch_spec": {}}
```

**Task `spec.json` / `runtime.json` (NOT parsed):**
```json
{"version": <int>, "id": "<str>", "kind": "<str>", "session_id": "<uuid>",
 "description": "<str>", "tool_call_id": "tool_<rand>", "owner_role": "<str>",
 "created_at": <num>, "command": "<str?>", "shell_name": "<str?>",
 "shell_path": "<str?>", "cwd": "<str?>", "timeout_s": <num>, "kind_payload": {}}
{"status": "<str>", "worker_pid": <int?>, "child_pid": <int?>, "child_pgid": <int?>,
 "started_at": <num?>, "heartbeat_at": <num>, "updated_at": <num>, "finished_at": <num>,
 "exit_code": <int?>, "interrupted": false, "timed_out": false, "failure_reason": null}
```

**Engram normalized output (parity fixture `success.expected.json`, real).**
The snippet below is a **`sessionInfo` excerpt only**. The actual fixture carries
**16 top-level keys**: `failure, fileToolCounts, generatedAtCommit, inputPath,
insightFields{firstUserSummary,messageCount,toolCallCount}, locator, messages[],
nodeVersion, projectFields{cwd,project,source}, schemaVersion,
searchIndexFields{contentPreview,contentSha256InputBytes,roles[]}, sessionInfo,
source, statsFields, toolCalls, usageTotals`.

```json
{"sessionInfo": {"id": "sess-001", "source": "kimi",
  "startTime": "2026-02-02T02:40:01.000Z", "endTime": "2026-02-02T02:41:00.000Z",
  "cwd": "/Users/test/my-project", "messageCount": 3,
  "userMessageCount": 2, "assistantMessageCount": 1,
  "toolMessageCount": 0, "systemMessageCount": 0,
  "summary": "<first user text ≤200>", "sizeBytes": 248},
 "toolCalls": [],
 "usageTotals": {"inputTokens": 0, "outputTokens": 0, "cacheReadTokens": 0, "cacheCreationTokens": 0}}
```

The fixture's `messages[]` array concretely demonstrates the gotcha-#1
timestamp-drop bug: the **3rd message (2nd user) has NO `timestamp` field** —
the turn state-machine ran out of `turns[]` entries, so no wire timestamp was
assigned. (Anonymized to structure; the fixture text is real but elided here.)

```json
"messages": [
  {"role": "user",      "content": "<u1>", "timestamp": "2026-02-02T02:40:01.000Z"},
  {"role": "assistant", "content": "<a1>", "timestamp": "2026-02-02T02:41:00.000Z"},
  {"role": "user",      "content": "<u2>"}
]
```

---

## References (official sources)

**Official repo source — MoonshotAI/kimi-cli (`src/kimi_cli/`):**
- [config.py — config.toml structure, defaults, LLMModel.display_name](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/config.py)
- [metadata.py — WorkDirMeta.sessions_dir, md5(cwd)/kaos dir naming, kimi.json work_dirs](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/metadata.py)
- [session.py — session = directory of context/wire/state, flat-file persistence (no DB)](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/session.py)
- [session_state.py — state.json schema, custom_title](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/session_state.py)
- [share.py — store root ~/.kimi/ (KIMI_SHARE_DIR)](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/share.py)
- [soul/context.py — context.jsonl rotation, marker record shapes (_system_prompt/_checkpoint/_usage)](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/soul/context.py)
- [utils/path.py — next_available_rotation → context_<N>.jsonl shard naming](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/utils/path.py)
- [wire/protocol.py — WIRE_PROTOCOL_VERSION = 1.10, LEGACY = 1.1, message types](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/wire/protocol.py)
- [wire/file.py — wire.jsonl envelope + metadata header line](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/wire/file.py)
- [subagents/store.py — subagents/<id>/ layout + meta.json keys](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/subagents/store.py)
- [notifications/store.py — notifications/<id>/event.json + delivery.json](https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/notifications/store.py)

**Official docs — Moonshot AI:**
- [Configuration / Providers (kimi-cli)](https://moonshotai.github.io/kimi-cli/en/configuration/providers.html)
- [Wire Protocol (kimi-code CLI)](https://www.kimi.com/code/docs/en/kimi-code-cli/customization/wire-protocol.html)
- [Data locations (kimi-code CLI)](https://www.kimi.com/code/docs/en/kimi-code-cli/configuration/data-locations.html)
- [Sessions (kimi-code CLI)](https://www.kimi.com/code/docs/en/kimi-code-cli/guides/sessions.html)

> Web confirmation pass applied 2026-06-21; all sources above are also cited inline in the relevant sections.
