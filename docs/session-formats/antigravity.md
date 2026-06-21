# Antigravity Session Format — Definitive Reference

Last researched: 2026-06-21 (Engram session-format research workflow)

> **Evidence basis (this doc):** LIVE on-disk store on this machine **+** both Engram adapters
> (Swift product `AntigravityAdapter.swift`, TS reference `src/adapters/antigravity.ts`) **+** repo
> fixtures. Files actually sampled:
> - IDE cache: **58** `~/.engram/cache/antigravity/*.jsonl`
> - IDE source protobufs: **61** `~/.gemini/antigravity/conversations/*.pb`
> - CLI brain: **151** session dirs, of which **143** have `transcript.jsonl` and **128** have `transcript_full.jsonl`
> - Aggregate CLI records scanned: **8 673** lines across all 143 transcripts
> - Aggregate cache message lines scanned: **2 303**
> - Fixtures: `tests/fixtures/antigravity/cache/conv-001.jsonl` (3 lines), `tests/fixtures/antigravity-cli/transcript.jsonl` (4 lines)
> - Schema: `macos/Shared/EngramCore/Adapters/Cascade/cascade.proto`, gRPC client `CascadeClient.swift`
>
> On conflict, **REAL data wins**; discrepancies are flagged inline. Cross-checked against three
> dimension reports (storage-lifecycle, record-schema, engram-mapping); their conflicting claims were
> re-verified against live data and the actual repo files (notably the proto, the tool list, and the
> `status` enum), and corrected where they diverged.

---

## 1. Overview & TL;DR

**Antigravity is TWO unrelated products that share the `~/.gemini/` home and one Engram adapter.** The
single `AntigravityAdapter` reads two completely different on-disk shapes:

> **Version drift (web-confirmed 2026-06-21):** the two-branch model below is accurate for what Engram
> reads, but the live `~/.gemini/` layout has grown more than two brain roots. Antigravity 2.0 introduced
> an Agent Manager brain at `~/.gemini/antigravity/brain` and an IDE brain at
> `~/.gemini/antigravity-ide/brain`, alongside the CLI's `~/.gemini/antigravity-cli/brain` — up to **three
> sibling brain roots** (Agent Manager, IDE, CLI) sharing the JSONL transcript format, not a single
> IDE-vs-CLI split
> ([Antigravity 2.0 shared-brain thread](https://discuss.ai.google.dev/t/antigravity-2-0-and-ide-cli-too-shared-brain/167445)).

| Branch | Product | On-disk root | Storage tech | Who writes it | Engram reads |
|---|---|---|---|---|---|
| **A. Cascade IDE** | Antigravity IDE (VS Code fork on Codeium's "Cascade" engine) | source `~/.gemini/antigravity/conversations/<uuid>.pb`; Engram cache `~/.engram/cache/antigravity/<uuid>.jsonl` | IDE writes the encrypted `.pb`; **Engram's own sync** writes the `.jsonl` cache by talking to the IDE over gRPC | meta line + `{role,content}` message lines from the **cache** (never the `.pb`) |
| **B. Antigravity CLI** | `antigravity-cli` (the agentic "brain") | `~/.gemini/antigravity-cli/brain/<uuid>/.system_generated/logs/transcript.jsonl` | the CLI agent, directly | `type`-tagged append-only JSONL event log, read **directly** |

**Mental model.** Branch A is an *Engram-derived text projection* of an opaque encrypted IDE store
(Engram fetches conversations over gRPC and writes a lossy `{role,content}` JSONL cache; the `.pb` is
never decoded). Branch B is a *native rich agentic event log* (steps, tools, reasoning, timestamps)
that Engram reads as-is but then heavily filters.

**The single most important lineage fact:** in the shipped Swift product, `AntigravityAdapter` is
constructed with **`enableLiveSync: false`** at **all three** product construction sites
(`SessionAdapterFactory.swift:26`, `:71`, and `MessageParser.swift:129`). So the product
**never runs gRPC sync** and **never decodes the `.pb` files**. Branch A surfaces *only* cache JSONL
written earlier (by a legacy TS run); Branch B is read live (it is already JSONL on disk). On a fresh
Swift-only machine with no prior TS sync, Branch A yields **nothing** and only CLI brain transcripts
appear.

```
                          ANTIGRAVITY  (two products, one adapter)
  ┌─────────────────────────────────────────────┐   ┌──────────────────────────────────────────┐
  │ BRANCH A — Cascade IDE                       │   │ BRANCH B — Antigravity CLI ("brain")       │
  │                                              │   │                                            │
  │  ~/.gemini/antigravity/conversations/        │   │  ~/.gemini/antigravity-cli/brain/          │
  │     <uuid>.pb   (ENCRYPTED protobuf, opaque) │   │     <uuid>/                                │
  │            │  IDE writes                      │   │       ├─ implementation_plan.md (artifact) │
  │            ▼                                  │   │       ├─ review_report.md       (artifact) │
  │  [ local gRPC language server ]              │   │       ├─ *.md.metadata.json     (sidecar)  │
  │            │  Engram sync (DISABLED in        │   │       └─ .system_generated/                │
  │            │  product: enableLiveSync=false)  │   │            ├─ logs/transcript.jsonl  ◄──────┼── Engram reads (direct)
  │            ▼                                  │   │            │   transcript_full.jsonl (IGN.)│
  │  ~/.engram/cache/antigravity/<uuid>.jsonl ◄──┼── │            ├─ messages/<uuid>.json (IGNORED)│
  │     line1 = meta ; line2..N = {role,content} │   │            └─ tasks/task-<n>.log   (IGNORED)│
  └─────────────────────────────────────────────┘   └────────────────────────────────────────────┘
        Engram reads the CACHE (only its byte-size                 step records: USER_INPUT,
        from the .pb is reused via pbSizeBytes)                    PLANNER_RESPONSE, VIEW_FILE, …
```

---

## 2. On-disk layout & file naming

### 2.1 Tree (live)

```
~/.gemini/
├── antigravity/                         # IDE product root
│   ├── daemon/                          # language-server discovery + logs
│   │   └── ls_<16hex>.log               #   e.g. ls_86f3b7e9cbf5f2e3.log  (Go LS log; NO .json present)
│   ├── conversations/                   # SOURCE OF TRUTH for IDE convos
│   │   └── <uuid>.pb                     #   ENCRYPTED protobuf, 1 per conversation
│   ├── agyhub_summaries_proto.pb        # aggregate/state blobs (not per-session)
│   ├── antigravity_state.pbtxt
│   ├── user_settings.pb
│   ├── installation_id
│   ├── browserAllowlist.txt
│   └── (annotations/ brain/ browser_recordings/ code_tracker/ context_state/
│        html_artifacts/ implicit/ knowledge/ playground/ … other engine dirs)
│
└── antigravity-cli/
    └── brain/                           # CLI product root
        └── <uuid>/                      # 1 dir per CLI session (named by session UUID)
            ├── implementation_plan.md            # user-visible artifacts (variable set)
            ├── implementation_plan.md.metadata.json
            ├── review_report.md
            ├── review_report.md.metadata.json
            └── .system_generated/
                ├── logs/
                │   ├── transcript.jsonl          # <-- THE file Engram reads
                │   └── transcript_full.jsonl     # superset variant, IGNORED by Engram (128 dirs)
                ├── messages/
                │   └── <uuid>.json               # per-message inter-agent bus blobs (IGNORED)
                └── tasks/
                    └── task-<n>.log              # task logs (IGNORED)

~/.engram/
└── cache/
    └── antigravity/                     # Engram-OWNED derived cache (NOT Antigravity's)
        └── <uuid>.jsonl                 # 1 per IDE conversation; meta line + message lines
```

> **Version drift (web-confirmed 2026-06-21):** the per-conversation `<uuid>.pb` files are correct for the
> `.pb` generation, but newer Antigravity IDE versions have begun storing conversations as **SQLite `.db`**
> files instead of `.pb` (community recovery tooling reports both). Additionally, the IDE's conversation
> **index** (UUID→conversation mapping, the `trajectorySummaries`) lives in a SQLite state DB at
> `~/Library/Application Support/Antigravity[ IDE]/User/globalStorage/state.vscdb` under keys
> `chat.ChatSessionStore.index` and `antigravityUnifiedStateSync.trajectorySummaries` (Base64 protobuf) —
> not only the per-conversation `.pb` files. Engram still treats the cache (Branch A) as its read surface
> and never reads either the `.db` files or `state.vscdb`
> ([decryptor](https://github.com/arashz/antigravity_decryptor)).

### 2.2 Naming grammar

- **IDE conversation id** = lowercase UUIDv4. File: `<uuid>.pb` (source) ↔ `<uuid>.jsonl` (cache).
  The basename *is* the conversation id; cache and `.pb` share it 1:1 (`AntigravityAdapter.swift:147-148`).
- **CLI session id** = lowercase UUIDv4 = the `brain/<uuid>/` directory name. The transcript path is
  fixed: `<uuid>/.system_generated/logs/transcript.jsonl`.
- **Daemon log:** `ls_<16-hex>.log` (a Go language-server log). The JSON discovery file (`httpPort` +
  `csrfToken`) that `fromDaemonDir` *would* read is **absent on this machine** (`ls .../daemon/*.json`
  → 0). Current Antigravity uses **process-based discovery** instead (see §3).
- **CLI artifacts:** `<name>.md` + `<name>.md.metadata.json` sidecar; task logs `task-<n>.log`;
  per-message blobs `<msg-uuid>.json`.

---

## 3. File lifecycle & generation

### Branch A — IDE cache: derived, whole-file rewrite-per-conversation (live-sync DISABLED in product)

- **Source of truth** = the encrypted `<uuid>.pb`, owned by the IDE; it grows/rewrites as the user chats.
- **Engram `sync()`** (`AntigravityAdapter.swift:130-211`) is *intended* to: discover the running language
  server → `listConversations()` → for each, **whole-file rewrite** the cache JSONL (`CascadeCacheSupport.writeCache`
  writes meta + all messages atomically, `WindsurfAdapter.swift:62-80` — it is **not** append).
  - **Freshness gate** (`isFresh`, `:213-231`): skip when `cache.mtime >= pb.mtime` **AND** `cache.size > 200`
    (size ≤ 200 = "meta-only / no content").
  - **`.pb`-scan backfill** (`syncFromPbFiles`, `:179-211`): the gRPC list returns only ~10 recent
    conversations, so a second pass scans `conversations/*.pb` for ids the API didn't return and writes
    cache entries with file-mtime-derived `createdAt`/`updatedAt` and `title:""`.
- ⚠ **In the shipped product, sync is OFF** (`AntigravityAdapter(enableLiveSync: false)` at all three
  product construction sites — `SessionAdapterFactory.swift:26,71` **and** `MessageParser.swift:129`;
  any edit to the live-sync flag must touch all three). `sync()` early-returns (`:131`), so Engram reads only the
  **pre-existing** `~/.engram/cache/antigravity/*.jsonl`. New IDE conversations after the last legacy
  sync are **not** picked up. The TS reference adapter (`antigravity.ts`) has no such gate and *would*
  sync live.
- **Discovery (when enabled):** process-based first (`CascadeGrpcClient.fromProcess()` / Swift
  `CascadeDiscovery`) — find `language_server` process, extract `--csrf_token`, `lsof` the LISTEN port;
  fallback to a `<name>.json` in `daemon/` with `httpPort`+`csrfToken`. No daemon `.json` exists here,
  confirming process-based discovery is the live mechanism.
- **Resume / rollover:** none at the cache layer — flat 1-file-per-conversation rewrite. Conversation
  continuation just grows the same `.pb`/`.jsonl`. No archive/rotation; stale cache entries persist
  until overwritten.

### Branch B — CLI transcript: append-only, read directly

- Each CLI session = one `brain/<uuid>/` dir. The CLI **appends** step records to
  `.system_generated/logs/transcript.jsonl` as the agent runs (append, never rewrite — `step_index` is
  monotonic). `status:"RUNNING"` records are written mid-step and finalized to `DONE` (or `ERROR`).
- No rollover/archive — one file grows for the session's life.
- Empty/aborted sessions leave a `brain/<uuid>/` dir with **no** transcript (151 dirs, 143 transcripts
  → 8 dirs have none). Engram skips dirs lacking the transcript.
- Engram reads the transcript **directly, on demand**; there is **no** Engram-side cache for Branch B.
- `transcript_full.jsonl` (128 dirs) is a parallel superset transcript (same schema). Engram never
  enumerates it.

---

## 4. Record / line taxonomy

### 4.1 Branch A cache `<uuid>.jsonl`
JSONL: **line 1 = metadata object**, **lines 2..N = message objects**. Two line kinds only:

| Line kind | Shape | Count seen |
|---|---|---|
| metadata (line 1) | `CacheMetaLine` (see §5) | 58/58 files |
| message (lines 2..N) | `{role, content}` — `role ∈ {user, assistant}` only | 2 303 lines, 100% `{content,role}` |

### 4.2 Branch B transcript `transcript.jsonl`
Plain JSONL, **one object per agent "step"**, NO leading metadata line (the whole file is records).
All 16 `type` values found across 8 673 live records, with the producer (`source`) and the role the
adapter assigns:

| `type` | n (live, all transcripts) | Purpose | Adapter role | Note |
|---|---:|---|---|---|
| `PLANNER_RESPONSE` | 3 884 | model turn: text and/or `thinking` and/or `tool_calls` | **assistant** | carries `thinking`, `tool_calls` |
| `VIEW_FILE` | 1 694 | file-read tool **result** | **tool** | only tool result the Swift adapter keeps |
| `GREP_SEARCH` | 1 239 | grep tool **result** | DROPPED (Swift) / tool (TS) | see §7 |
| `SYSTEM_MESSAGE` | 353 | system/control text | DROPPED | |
| `EPHEMERAL_MESSAGE` | 334 | transient UI text | DROPPED | |
| `LIST_DIRECTORY` | 263 | dir-list **result** | DROPPED (Swift) / tool (TS) | |
| `GENERIC` | 197 | misc event | DROPPED (Swift) / tool (TS) | |
| `USER_INPUT` | 155 | the human prompt | **user** | |
| `RUN_COMMAND` | 143 | shell command **result** | DROPPED (Swift) / tool (TS) | |
| `FIND` | 102 | file-find **result** | DROPPED (Swift) / tool (TS) | |
| `SEARCH_WEB` | 91 | web-search **result** | DROPPED (Swift) / tool (TS) | |
| `CODE_ACTION` | 78 | code edit/patch action | DROPPED (Swift) / tool (TS) | |
| `CONVERSATION_HISTORY` | 74 | history boundary marker | DROPPED | **no `content`** |
| `ERROR_MESSAGE` | 37 | error event | DROPPED | extra `error` key; `content` absent (12) or string (25), never null |
| `INVOKE_SUBAGENT` | 24 | subagent dispatch marker | DROPPED | see §10 |
| `CHECKPOINT` | 5 | checkpoint marker | DROPPED | |

> **Adapter mapping** (`cliMessage`, Swift `:345-368` / TS `:483-500`): `USER_INPUT`→user;
> `PLANNER_RESPONSE`→assistant (uses `content`, falls back to `thinking`, attaches `toolCalls`); a
> fixed tool-result allowlist → tool. The whitelists DIFFER between Swift and TS — see §7.

---

## 5. Shared envelope / metadata fields

### 5.1 Branch A — `CacheMetaLine` (line 1) — `antigravity.ts:18-26`

| Field | Type | Meaning | Optionality | Live presence | Example (anonymized) |
|---|---|---|---|---|---|
| `id` | string (UUID) | conversation id (= `.pb` basename = cache filename stem) | **required** | 58/58 | `"19d120fb-71a5-49c8-9d0b-3096ab367f50"` |
| `title` | string | conversation title; `""` when synced from `.pb` scan | required key, may be `""` | 58/58 | `"<str len=23>"` |
| `summary` | string | AI summary from `GetAllCascadeTrajectories`; emitted only when non-empty | optional | **18/58** | `"<str len=23>"` |
| `createdAt` | string (ISO-8601 UTC, ms) | conversation start | **required** | 58/58 | `"2026-02-24T05:00:52.882699Z"` |
| `updatedAt` | string (ISO-8601 UTC, ms) | last activity | **required** | 58/58 | `"2026-02-24T05:01:09.968924Z"` |
| `cwd` | string (abs path) | workspace folder (`workspaces[0].workspaceFolderAbsoluteUri`, `file://` stripped/decoded) | optional | **18/58** | `"/Users/<user>/-Code-/<project>"` |
| `pbSizeBytes` | number | byte size of the real `.pb` (size reporting + dedup) | optional in type | **58/58** | `158073` (one live file: `27175276` ≈ 25.9 MB) |

**Two observed key-sets** (verified across all 58):
- **40 files** = `{createdAt, id, pbSizeBytes, title, updatedAt}` — synced from `.pb` scan (no `summary`/`cwd`, empty `title`).
- **18 files** = `{createdAt, cwd, id, pbSizeBytes, summary, title, updatedAt}` — synced from the gRPC trajectory list.

> Fixtures use an older shape (`tests/fixtures/antigravity/cache/conv-001.jsonl`): only
> `{id,title,createdAt,updatedAt}`, no `pbSizeBytes`. Both adapters tolerate missing optional keys.

### 5.2 Branch B — common record envelope (every transcript record)

| Field | Type | Meaning | Optionality | Example / domain |
|---|---|---|---|---|
| `type` | string enum | step/record kind (16 values, §4.2) | **required** | `"PLANNER_RESPONSE"` |
| `step_index` | int | monotonic step ordinal (resume/ordering) | **required** | `0 … 931` |
| `source` | string enum | producer: `MODEL` (7 715) / `SYSTEM` (803) / `USER_EXPLICIT` (155) | **required** | `"MODEL"` |
| `status` | string enum | lifecycle: `DONE` (8 511) / `RUNNING` (77) / **`ERROR` (85)** | **required** | `"DONE"` |
| `created_at` | string (ISO-8601 UTC, **second precision, NO ms**) | step timestamp | **required** | `"2026-05-19T23:58:09Z"` |
| `content` | string | text body / tool output / user input | type-dependent — either a non-empty string or the **key is absent** (omitted on `CONVERSATION_HISTORY` and on tool-only planner steps). **Never JSON `null`, never `""`** in live data. | `"<str len=423>"` |
| `thinking` | string | model reasoning (on `PLANNER_RESPONSE`) | optional | `"<str len=365>"` |
| `tool_calls` | array of `{name, args}` | tool invocations (on `PLANNER_RESPONSE`) | optional | `[{"name":"view_file","args":{…}}]` |
| `error` | string | error text (on `ERROR_MESSAGE`) | optional | `"<str len=109>"` |
| `truncated_fields` | array of string (field names) | names of fields (subset of `content` / `thinking` / `tool_calls`) the CLI truncated when the record was written | optional | `["content"]`, `["content","thinking"]` |

> **Correction vs. dimension reports:** `status` has **three** live values — DONE, RUNNING, **and ERROR**
> (85 records). DIM 1 and DIM 2 listed only DONE/RUNNING. The full key-union across all transcripts is
> exactly `['content','created_at','error','source','status','step_index','thinking','tool_calls','truncated_fields','type']`.

---

## 6. Message & content schema

### 6.1 Branch A messages (lines 2..N)

| Field | Type | Meaning | Optionality | Example |
|---|---|---|---|---|
| `role` | string | `"user"` or `"assistant"` only | **required** | `"assistant"` |
| `content` | string | flattened message text | **required** | `"<text>"` |
| `timestamp` | string | per-message time | **NEVER present in live cache** — fixture only | — |

**Verified:** all 2 303 live message lines have **exactly** `{content, role}`. The Swift writer
(`CascadeCacheSupport.writeCache`, `WindsurfAdapter.swift:73-77`) emits only `role`+`content` with sorted
keys, so cache timestamps are structurally impossible. The reader (`normalizedMessages`, `:19-35`) and TS
`streamMessages` (`:368-396`) *tolerate* an optional `timestamp`, but the writer never produces one →
Branch-A per-message timestamps are always `nil`.

```json
{"id":"<uuid>","title":"","createdAt":"2026-02-19T15:47:16.862Z","updatedAt":"2026-02-19T15:47:16.862Z","pbSizeBytes":1113514}
{"role":"user","content":"<text>"}
{"role":"assistant","content":"<text>"}
```

### 6.2 Branch B content variants

- **`USER_INPUT`** → `content` = the human prompt (verbatim).
- **`PLANNER_RESPONSE`** → assistant turn. `content` is either a non-empty string or the key is
  **absent** (never JSON `null` or `""` in live data — 3 217 records omit it, 667 have a string). The
  adapter coalesces a missing/non-string `content` to `""` via `typeof obj.content === 'string' ? … : ''`
  (`antigravity.ts:486`) and then falls back to `thinking`. May carry `tool_calls`.
- **Tool-result records** (`VIEW_FILE`, `GREP_SEARCH`, `RUN_COMMAND`, `LIST_DIRECTORY`, `FIND`,
  `SEARCH_WEB`, `CODE_ACTION`) → `content` = tool output text (always a non-empty string).
- **`CONVERSATION_HISTORY`** → no `content` key (history boundary marker).
- **`ERROR_MESSAGE`** → `error` string; `content` is either a non-empty string (25 records) or the key is
  **absent** (12 records) — never `null`.

```json
{"type":"USER_INPUT","source":"USER_EXPLICIT","status":"DONE","created_at":"2026-05-20T03:00:00Z","step_index":0,"content":"<prompt>"}
{"type":"PLANNER_RESPONSE","source":"MODEL","status":"DONE","created_at":"2026-05-20T03:00:01Z","step_index":1,"thinking":"<reasoning>","tool_calls":[{"name":"view_file","args":{"AbsolutePath":"/abs/file.swift","StartLine":1,"EndLine":80,"toolAction":"<ui label>","toolSummary":"<ui summary>"}}]}
{"type":"VIEW_FILE","source":"MODEL","status":"DONE","created_at":"2026-05-20T03:00:02Z","step_index":2,"content":"<file contents>"}
```

---

## 7. Tool calls & results

### Branch A — N/A
The cache contains **no tool calls and no tool results** (flattened away during sync). `toolMessageCount`
is hard-coded `0` for Branch A (`AntigravityAdapter.swift:84`; TS `:324`).

### Branch B — calls and results are SEPARATE records, linked only by ordering

- **Call** = a `tool_calls[]` entry inside a `PLANNER_RESPONSE`.
  - Observed object key-set is **always** `{args, name}` (3 865/3 865).
  - `name` (string): the tool. `args` (object): tool-specific params; **every** tool also carries two UI
    strings `toolAction` + `toolSummary`.
- **Result** = a *later, separate* record (`VIEW_FILE`, `RUN_COMMAND`, etc.) whose `content` is the output.
- **Linkage:** **only implicit via `step_index` ordering.** There is **no** explicit call↔result id field.
  The adapter does NOT reconstruct it — `cliToolCalls` (`:370-382`) keeps `{name, input=truncateJSON(args,500)}`
  with **`output: nil` always**.

**19 distinct tool names observed live** (counts) with their `args` keys (every tool also has
`toolAction`, `toolSummary` — omitted below for brevity except where they are the only keys):

| tool | n | `args` keys (besides `toolAction`,`toolSummary`) |
|---|---:|---|
| `view_file` | 1721 | `AbsolutePath, StartLine, EndLine, ContentOffset, IsSkillFile` |
| `grep_search` | 1239 | `Query, SearchPath, Includes, IsRegex, CaseInsensitive, MatchPerLine` |
| `list_dir` | 263 | `DirectoryPath` |
| `run_command` | 144 | `CommandLine, Cwd, WaitMsBeforeAsync` |
| `find_by_name` | 102 | `Pattern, SearchDirectory, Excludes, Extensions, MaxDepth, Type` |
| `send_message` | 91 | `Message, Recipient` |
| `search_web` | 91 | `query` |
| `schedule` | 59 | `Prompt, CronExpression, DurationSeconds, TimerCondition` |
| `replace_file_content` | 50 | `TargetFile, TargetContent, ReplacementContent, Instruction, StartLine, EndLine, AllowMultiple, Description` |
| `write_to_file` | 29 | `TargetFile, CodeContent, Description, Overwrite, IsArtifact, ArtifactMetadata` |
| `invoke_subagent` | 24 | `Subagents` |
| `manage_task` | 21 | `Action, TaskId` |
| `define_subagent` | 18 | `name, description, system_prompt, enable_mcp_tools, enable_subagent_tools, enable_write_tools` |
| `list_permissions` | 4 | (only the two UI strings) |
| `call_mcp_tool` | 2 | `ServerName, ToolName, Arguments` |
| `ask_permission` | 2 | `Action, Reason, Target` |
| `manage_subagents` | 2 | `Action` |
| `Running_command` | 2 | (only the two UI strings) |
| `multi_replace_file_content` | 1 | `TargetFile, Description, Instruction, ReplacementChunks` |

> **Correction vs. dimension reports:** DIM 2 listed ~11 tools; live data has **19** (adds 8:
> `find_by_name`, `send_message`, `define_subagent`, `call_mcp_tool`, `ask_permission`,
> `multi_replace_file_content`, `manage_subagents`, and a stray `Running_command`).

### ⚠ Swift↔TS divergence on tool-result mapping (live-affecting)

The Swift adapter's tool-result allowlist (`AntigravityAdapter.swift:362`) matches:
`VIEW_FILE`, `TOOL_OUTPUT`, `COMMAND_OUTPUT`, `SHELL_OUTPUT`, `APPLY_PATCH`.

But of those, **only `VIEW_FILE` actually occurs** in 143 live transcripts. `TOOL_OUTPUT` /
`COMMAND_OUTPUT` / `SHELL_OUTPUT` / `APPLY_PATCH` match **zero** live records (dead cases — an older or
speculative schema vocabulary). Meanwhile the real result types (`RUN_COMMAND`, `GREP_SEARCH`,
`LIST_DIRECTORY`, `FIND`, `SEARCH_WEB`, `CODE_ACTION` — ~1 900 records) hit the Swift `default: return nil`
→ **dropped**.

The TS reference behaves differently: after `USER_INPUT`/`PLANNER_RESPONSE`, **any** record with
non-empty `content` becomes `role:'tool'` (`antigravity.ts:498-499`). So TS counts `RUN_COMMAND`,
`GREP_SEARCH`, `GENERIC`, `SYSTEM_MESSAGE`, etc. as tool messages; Swift does not.

**Consequence:** for the same file, `toolMessageCount`, `messageCount`, and the streamed transcript
**differ** between the shipped Swift product (≈ `VIEW_FILE` count only) and the TS reference (much higher).
The parity fixture (`tests/fixtures/antigravity-cli/transcript.jsonl`) contains only
`USER_INPUT`/`PLANNER_RESPONSE`/`VIEW_FILE`, so **CI does not exercise this divergence**.

---

## 8. Reasoning / thinking

- **Branch A:** N/A — no reasoning in the cache.
- **Branch B:** stored as the `thinking` string on `PLANNER_RESPONSE`. The adapter uses it **only as a
  fallback** for assistant `content` when `content` is missing — live, the `content` key is simply absent
  on tool-only planner steps (3 217 records), which the adapter coalesces to `""` and then replaces with
  `thinking` (`:354`, TS `:489`). When a planner step has *both* `content` and `thinking`, the `thinking`
  is **discarded**.

---

## 9. Token usage & cost

**N/A for Antigravity — no token/usage/cost/model fields exist in any layer.**

- Branch A cache: none. Branch B transcript: none (no `usage`, no token counts, no cost, no model id).
- `NormalizedMessage.usage` is hard-coded `nil` (`AntigravityAdapter.swift:360`); `model` is `nil` in
  every parse path (`:80`, `:317`). The `cascade.proto` exposes no usage fields.
- The `source:"MODEL"` tag in Branch B is a generic role marker, **not** a model id.
- → Antigravity sessions contribute **zero** to `get_costs` / token analytics regardless of real usage.

---

## 10. Subagent / parent-child / dispatch

**N/A for Engram linkage — Antigravity's internal subagent structure is NOT used for Engram parent/child grouping.**

- Branch B emits subagent records: `INVOKE_SUBAGENT` (24), and tool calls `invoke_subagent` (24),
  `define_subagent` (18), `manage_subagents` (2). These mark Antigravity-internal subagent dispatch.
- All of these are **dropped** by the adapter (`INVOKE_SUBAGENT` is not in any role allowlist;
  `invoke_subagent`/`define_subagent` survive only as `tool_calls` text on the planner step that emits
  them). Engram does **not** build `parent_session_id`/`suggested_parent_id` links from them.
- Unlike Claude Code (path-based subagent linking) or Gemini CLI (`.engram.json` sidecar), Antigravity
  has **no sidecar and no path-based parent encoding** that Engram consumes. Both branches leave
  `parentSessionId`/`suggestedParentId` = `nil` at parse time (`:96-97`, `:334-335`); any grouping is
  left entirely to Engram's downstream parent-detection/tiering pipeline.

---

## 11. Summary / compaction

- **Branch A:** `summary` field in the meta line (AI-generated, from gRPC; present on 18/58 files). The
  adapter's session `summary` = first non-empty of `title` / `summary` / first-user-text, capped 200 chars
  (`:71,86`; TS `:326-328`).
- **Branch B:** no explicit summary field. The CLI emits `CONVERSATION_HISTORY` boundary markers (74) and
  `CHECKPOINT` markers (5) which *resemble* compaction boundaries, but they are **dropped** by the adapter.
  Session `summary` = first-user-text capped 200 chars (`:324`; TS `:474`).
- No true transcript compaction/rollover is performed by Engram for either branch.

---

## 12. SQLite / DB internals

**N/A for Antigravity** — neither product uses SQLite for sessions. Branch A is encrypted protobuf
(`.pb`) fronted by a gRPC server; Branch B is plain append-only JSONL. (Engram's own `~/.engram/index.sqlite`
is the aggregator DB, out of scope for this source-format doc.)

### gRPC / protobuf surface (Branch A, the only "schema")

The IDE `.pb` files are **NOT plain protobuf on disk** — they are encrypted/opaque. A live `.pb` shows
high-entropy bytes with no protobuf field tags:

```
00000000: 775b be96 92da 43c2 ddba 2ca6 974f 080f  w[....C...,..O..
00000010: a1c4 37bc 1dc1 a712 776b f8b3 23f4 e810  ..7.....wk..#...
```

> **Encryption is now characterized (web-confirmed 2026-06-21):** the `.pb` encryption is no longer a
> black box. It is Electron `safeStorage` keyed via the macOS Keychain (service `Antigravity Safe
> Storage`), concretely **AES-128-CTR** with a 16-byte key and IV = first 16 bytes of the file; after
> decryption the payload is standard protobuf wire format (0–4 header bytes may need skipping). The "opaque
> / undocumented `.pb` byte layout" open question is downgraded from *undocumented* to *documented by
> community decryptors* — Engram simply chooses not to decode it. Newer IDE versions may also store
> conversations as SQLite `.db` files, and the UUID→conversation index lives in
> `state.vscdb` (see §2.1)
> ([decryptor](https://github.com/arashz/antigravity_decryptor)).

Engram never decodes them; it only reads the **byte size** (→ `pbSizeBytes`) and otherwise talks to the
running language server over gRPC. The actual `cascade.proto`
(`macos/Shared/EngramCore/Adapters/Cascade/cascade.proto`) is **minimal** — it declares only:

```protobuf
service LanguageServerService {
  rpc GetAllCascadeTrajectories(GetAllCascadeTrajectoriesRequest) returns (GetAllCascadeTrajectoriesResponse);
  rpc ConvertTrajectoryToMarkdown(ConvertTrajectoryToMarkdownRequest) returns (ConvertTrajectoryToMarkdownResponse);
}
message CascadeTrajectorySummary {
  string summary = 1; string trajectory_id = 4;
  Timestamp created_time = 7; Timestamp last_modified_time = 3;
  ConversationAnnotations annotations = 15;   // .title
}
message GetAllCascadeTrajectoriesResponse { map<string, CascadeTrajectorySummary> trajectory_summaries = 1; }
```

> **Correction vs. dimension reports:** DIM 1 and DIM 2 attributed `GetCascadeTrajectory`,
> `Trajectory.steps[]`, `userInput`/`plannerResponse`/`notifyUser` step types, `workspaces[]`/`cwd`, and
> `pbSizeBytes` to `cascade.proto`. The **proto does not contain those**. They live in the Swift gRPC
> client `CascadeClient.swift`, which issues `GetCascadeTrajectory` over HTTP/JSON (not declared in the
> trimmed proto) and maps the JSON response:
> - `getTrajectoryMessages` (`CascadeClient.swift:55-90`) reads `trajectory.steps[]`, matching step
>   `type` via `.contains("USER_INPUT")` → user, `.contains("PLANNER_RESPONSE")` → assistant,
>   `.contains("NOTIFY_USER")` → assistant. **Only those three** step types become messages; all
>   tool/file steps inside the trajectory are dropped at the gRPC boundary.
> - `cwd` is read from `workspaces[].workspaceFolderAbsoluteUri` (`:128-136`), `createdAt` from
>   `createdTime`, etc. So even the (now non-product) live-sync path loses Branch-A tool calls.

---

## 13. Auxiliary files

| Path | Content | Engram reads? |
|---|---|---|
| `~/.gemini/antigravity/daemon/ls_<hex>.log` | Go language-server log | No (discovery only, when live) |
| `~/.gemini/antigravity/agyhub_summaries_proto.pb`, `antigravity_state.pbtxt`, `user_settings.pb`, `installation_id`, `browserAllowlist.txt` | aggregate engine state | No |
| `~/.gemini/antigravity-cli/brain/<uuid>/transcript_full.jsonl` | superset transcript (same schema), 128 dirs | **No** (never enumerated) |
| `.../.system_generated/messages/<uuid>.json` | inter-agent message-bus blob. **Structurally varied.** Most files are a single message object — base keys `{id, sender, recipient, content, priority, renderDetails, timestamp}` plus optional `hideFromUser` (bool) and `sourceMetadata` (object); `renderDetails` is sometimes omitted. **But some files are a UUID-keyed MAP** of such message objects (top-level keys are bare message UUIDs, not field names), and a few are a tiny `{last_read_unix_nano}` cursor file. | **No** (richer than the JSONL, but ignored) |
| `.../.system_generated/tasks/task-<n>.log` | task execution logs | No |
| `<uuid>/implementation_plan.md`, `review_report.md` | user-visible artifacts | No |
| `<uuid>/<name>.md.metadata.json` | artifact sidecar — **variant-dependent keys.** Always `{summary, updatedAt}`; then optionally `artifactType` (str), `requestFeedback` (bool), `userFacing` (bool). Live variants: `{artifactType, summary, updatedAt}` (7), `{summary, updatedAt, userFacing}` (3), `{artifactType, requestFeedback, summary, updatedAt}` (1) — no single canonical full set. **Web-confirmed 2026-06-21:** community CLI docs additionally show `version` (incremental) and `sourceFile` keys in newer/other variants, paired with `task.md` / `implementation_plan.md` / `walkthrough.md` ([unofficial CLI](https://github.com/michaelw9999/antigravity-cli)). | No |

---

## 14. Engram mapping

`NormalizedSessionInfo` field ← source. **A** = Branch A (cache), **B** = Branch B (CLI transcript).

| Engram field | Branch | Swift (`AntigravityAdapter.swift`) | TS (`antigravity.ts`) | Derivation |
|---|---|---|---|---|
| `id` | A | `:55,73` | `:250,316` | `meta.id` (UUID); fail if empty |
| `id` | B | `:305` `cliSessionId` `:384-414` | `:461,520-544` | brain `<uuid>` dir name parsed from path; fallback = filename stem |
| `source` | both | `:75` (`.antigravity`) | `:317` (`"antigravity"`) | constant |
| `startTime` | A | `:76` | `:318` | `meta.createdAt` |
| `startTime` | B | `:286-288,314` | `:452,464` | first record's `created_at` |
| `endTime` | A | `:77` | `:319` | `meta.updatedAt` **only if ≠ createdAt**, else `nil` |
| `endTime` | B | `:289-291,315` | `:453,467` | last record's `created_at`, only if ≠ start |
| `cwd` | A | `:69,416-424` | `:295-313` | `meta.cwd` if present; else inferred from abs paths in first 50 KB |
| `cwd` | B | `:316,416-424` | `:468,546-564` | always inferred (no cwd in transcript) |
| `project` | both | `:79` (`nil`) | (absent) | never set — left to indexer |
| `model` | both | `:80` (`nil`) | (absent) | never set (§9) |
| `messageCount` | A | `:81` | `:321` | `userCount + assistantCount` |
| `messageCount` | B | `:319` | `:469` | `user + assistant + tool` |
| `userMessageCount` | A | `:63,82` | `:283-285,322` | `role=="user"` cache lines |
| `userMessageCount` | B | `:293-295,321` | `:454-456,471` | `USER_INPUT` count |
| `assistantMessageCount` | A | `:64,83` | `:286,323` | `role=="assistant"` count |
| `assistantMessageCount` | B | `:296-297,322` | `:457,472` | `PLANNER_RESPONSE` count |
| `toolMessageCount` | A | `:84` (`=0`) | `:324` (`=0`) | always 0 |
| `toolMessageCount` | B | `:298-299,323` | `:458,473` | mapped tool records (**Swift: ≈VIEW_FILE only; TS: all content-bearing other types** — §7) |
| `systemMessageCount` | both | `:85,323` (`=0`) | `:325,473` (`=0`) | always 0 |
| `summary` | A | `:71,86` | `:326-328` | `title` ?? `summary` ?? firstUserText, trunc 200 |
| `summary` | B | `:324` | `:474` | firstUserText, trunc 200 |
| `filePath` | both | `:87,326` | `:329,475` | the `.jsonl` locator path |
| `sizeBytes` | A | `:88,233-245` | `:259-268,330` | `meta.pbSizeBytes` if >0; else stat `.pb`; else stat cache file |
| `sizeBytes` | B | `:326` | `:439,476` | stat of the transcript file |
| `NormalizedMessage.usage` | both | `:360` (`nil`) | not set | never set (§9) |
| `NormalizedToolCall` | B | `cliToolCalls` `:370-382` `{name, input=jsonString(args,500), output:nil}` | `:502-518` `{name, input=truncateJSON(args,500)}` | call only; **no output linkage** |
| `agentRole`/`originator`/`origin`/`parentSessionId`/`suggestedParentId`/`tier`/`qualityScore`/`indexedAt`/`summaryMessageCount` | both | `:89-97,327-335` all `nil` | (absent) | left to indexer / parent-detection / tiering |

**Discovery & routing helpers:**
- `detect()` (`:36-40`; TS `:51-68`): true if any of `daemonDir`, `cacheDir`, `cliBrainDir` exists.
- `listSessionLocators()` (`:42-45`): `sync()` then sorted union of cache `.jsonl` locators
  (`CascadeCacheSupport.jsonlLocators`, `WindsurfAdapter.swift:6-11`) + CLI transcript locators
  (`cliTranscriptLocators`, `:247-260`).
- `isCLITranscript()` (`:262-270`; TS `:424-433`): path under `brain/` root, OR matches
  `…/.gemini/antigravity-cli/brain/…/.system_generated/logs/transcript.jsonl`.

---

## 15. Lineage, gotchas, version drift & edge cases

### 15.1 Shared format lineage

**Branch A ↔ Windsurf — the Cascade/Codeium twins (strongest lineage).** Both Antigravity Branch A and
**Windsurf** are built on Codeium's **Cascade** engine and share:
- The **same gRPC service** `exa.language_server_pb.LanguageServerService` (`cascade.proto`,
  `CascadeClient.swift`), same RPCs `GetAllCascadeTrajectories` / `ConvertTrajectoryToMarkdown` (+ the
  client's `GetCascadeTrajectory`).
- The **identical cache JSONL format** (meta line + `{role,content}` lines), produced/read by the
  **shared** `CascadeCacheSupport` enum (`WindsurfAdapter.swift:3-95`, used by both `AntigravityAdapter`
  and `WindsurfAdapter`) and the shared markdown parser (`## User` / `## Cascade` headers,
  `parseMarkdownToMessages`).
- The same `.pb`-in-`conversations/` + `.jsonl`-in-`~/.engram/cache/` mirror pattern and the "Cascade"
  assistant label.
- **Differences:** Antigravity lives under `~/.gemini/antigravity/`, Windsurf under `~/.codeium/windsurf/`.
  Antigravity adds the `getTrajectoryMessages`/`GetCascadeTrajectory` primary path, the `pbSizeBytes`
  field, and the `.pb`-scan backfill (`syncFromPbFiles`); Windsurf is markdown-only. Both are
  `enableLiveSync:false` and cache-only in the product. **Any fix to the cache format / Cascade RPC must
  be mirrored across both adapters.**

**Branch B ↔ Gemini-CLI family (home-dir lineage only).** Branch B lives under `~/.gemini/antigravity-cli/`,
sharing the `~/.gemini/` home with Gemini CLI (and its forks Qwen Code, iFlow, Kimi, MiniMax). But the
**transcript format is NOT shared** — Gemini CLI uses its own session JSON; Antigravity CLI's brain
transcript is a distinct `type`/`source`/`step_index` agentic event log. The lineage here is
**organizational** (Google "Antigravity" brand + `.gemini/` home), not structural. The
`tool_calls`-with-`{name,args}` + `.system_generated/` shape is closer to an agentic step log than to a
chat history.

**Source-ID lineage inside Engram.** The product `SourceName` enum case `antigravity` is defined at
`Shared/EngramCore/Adapters/SessionAdapter.swift:19` (verified: that line is literally `case antigravity`).
It is the single product source for **both** branches. The **`antigravityLegacy = "antigravity-legacy"`**
case does **not** live in `SessionAdapter.swift` — it is a separate enum in the project-move layer
(`EngramCoreWrite/ProjectMove/Sources.swift:43` `case antigravity`, `:44`
`case antigravityLegacy = "antigravity-legacy"`), used for path-rewriting the old IDE conversations dir
(`:415` doc comment, `:462-468` path mapping — `:462-463` map `.antigravity` → `.gemini/antigravity-cli/brain`,
`:467-468` map `.antigravityLegacy` → `.gemini/antigravity`). At read time `"antigravity-legacy"` collapses
back to `.antigravity` (`EngramServiceReadProvider.swift:1017`; also `TranscriptExportService.swift:415`,
`SystemMessageClassifier.swift:13`).

### 15.2 Gotchas, drift, edge cases

1. **Product = cache-only (Branch A) / live (Branch B).** With `enableLiveSync:false`, Branch A surfaces
   only cache files written earlier by the non-product TS path. A clean Swift-only install with no prior
   TS run → **no IDE Cascade sessions**, only CLI brain transcripts; the `.pb` files sit untouched.
2. **Swift↔TS Branch-B divergence (live, uncovered by CI).** §7 — TS counts every content-bearing
   non-USER/non-PLANNER record as a tool message; Swift maps only `VIEW_FILE` (plus 3 dead types). Tool
   counts and streamed content differ for the same file; the parity fixture contains none of the
   divergent types.
3. **Dead Swift switch cases = version drift.** `TOOL_OUTPUT` / `COMMAND_OUTPUT` / `SHELL_OUTPUT` /
   `APPLY_PATCH` (`:362`) match **zero** live records. Real tool outputs (`RUN_COMMAND`, `GREP_SEARCH`,
   `CODE_ACTION`, …) are unhandled — the adapter parses an outdated record-type vocabulary.
4. **`cwd` inference differs Swift vs TS.** TS uses a **hard-coded `/Users/<user>/-Code-/<project>` regex**
   (`antigravity.ts:299,311,550,559`) tied to this user's directory layout — wrong on any non-`-Code-`
   layout. Swift replaced it with a **generic most-frequent-directory heuristic**
   (`inferCWDFromAbsolutePaths`, `:430-455`) that makes no assumption about the user. Inferred cwd will
   differ for the same file; the Swift one is the portable/correct one.
5. **`createdAt === updatedAt` → no `endTime`.** Common for short conversations; Engram then has only a
   start time (`:77`, `:319`).
6. **`pbSizeBytes` vs cache size mismatch.** `sizeBytes` reports the `.pb` size (KB → tens of MB, one
   live file 25.9 MB) while the cache `.jsonl` is a few KB. Size-based UI/sorting reflects the full
   conversation, not the stored text. Cache files ≤ 200 bytes are treated as "no content" by the freshness
   gate (`:188,220-223`; TS `:95,174`).
7. **gRPC list returns only ~10 recent** (TS comment `:140,148`); `syncFromPbFiles` backfills the rest —
   but only in the live-sync (non-product) path.
8. **`getTrajectoryMessages` flattens to user/assistant text only** (`CascadeClient.swift:55-90`): only
   `USER_INPUT`/`PLANNER_RESPONSE`/`NOTIFY_USER` steps → messages; all tool/file steps in the trajectory
   are dropped at the gRPC boundary. So even live sync loses Branch-A tool calls.
9. **Three-tier content fallback (Branch A sync):** trajectory messages → markdown (`## User`/`## Cascade`)
   → conversation summary as a single assistant message (Swift `:153-161`; TS `:103-112`). A cache file
   may therefore contain only one synthetic assistant line.
10. **Zero token/cost contribution** (§9) — Antigravity sessions show as zero-cost in any cost dashboard.
11. **Richer per-message JSON ignored.** `.system_generated/messages/*.json` (base keys
    `{id, sender, recipient, content, priority, renderDetails, timestamp}` plus optional `hideFromUser`
    and `sourceMetadata`; some files are instead a UUID-keyed MAP of such objects — see §13/§16.9) hold
    more structure than the flattened `transcript.jsonl`, but the adapter reads only the JSONL. Future
    fidelity work should target these (and may close the timestamp gap).
12. **`status:"ERROR"` exists** (85 live records) beyond DONE/RUNNING — the adapter does not branch on
    `status` at all, so error/running steps are parsed by `type` like any other.

### 15.3 Open questions / resolved (web-confirmed 2026-06-21)

- **`.pb` byte layout / encryption** — **Confirmed (official/community):** no longer "undocumented." The
  IDE conversation `.pb` files in `~/.gemini/antigravity/conversations/` are encrypted with Electron's
  `safeStorage` API, keyed via the macOS Keychain (service name `Antigravity Safe Storage`); the key is
  hardware-bound, so the raw bytes are effectively random noise without it (matching the high-entropy /
  opaque observation in §12). The concrete scheme is **AES-128-CTR**, 16-byte key, IV = first 16 bytes of
  the file; after decryption the payload **is** protocol-buffer wire format (0–4 header bytes may need
  skipping). So decoding is possible *with the Keychain key* — Engram simply chooses never to decode it,
  which remains true ([decryptor](https://github.com/arashz/antigravity_decryptor),
  [reverse-engineering writeup](https://ericxliu.me/posts/reverse-engineering-antigravity-ide/),
  [DB recovery tool](https://github.com/ag-donald/Antigravity-Database-Manager)).
- **Full step-level field semantics** (model, tokens, tool I/O inside the binary trajectory) — **Confirmed
  partial (community):** the gRPC trajectory surface is real — the live RPC is
  `exa.language_server_pb.LanguageServerService/ConvertTrajectoryToMarkdown` (matches `cascade.proto` and
  the `CascadeClient` claims). The decrypted `.pb` is protobuf, but no public source publishes a complete
  field-level schema with model/token semantics; reverse-engineers extracted only message
  content/length/metadata via wire-walking. Inner per-step semantics remain largely un-enumerated
  publicly, consistent with "cannot be enumerated from this repo alone"
  ([reverse-engineering writeup](https://ericxliu.me/posts/reverse-engineering-antigravity-ide/),
  [decryptor](https://github.com/arashz/antigravity_decryptor)).
- **Dead Swift tool-result types** (`TOOL_OUTPUT`/`COMMAND_OUTPUT`/`SHELL_OUTPUT`/`APPLY_PATCH`) — whether
  any Antigravity-CLI version ever emitted them, or they were a speculative guess, is unconfirmed (no live
  evidence). **(web-checked 2026-06-21: no authoritative source found — the official tutorial, the
  official CLI repo, the codelab, and the leaked CLI system prompt all enumerate `USER_INPUT`,
  `PLANNER_RESPONSE`, `CONVERSATION_HISTORY`, `SEARCH_WEB`, `VIEW_FILE`, … but none of these four; absence
  is not proof they never existed.)**
- **Intended Swift↔TS Branch-B behavior** — should Swift adopt TS's generic tool fallback, or is dropping
  correct? Ambiguous; not exercised by the parity fixture. **(Engram-internal design — not
  web-verifiable.)**
- **Fixture `timestamp`** on cache message lines (`conv-001.jsonl`) — no live cache file has it and
  `writeCache` cannot produce it; whether the fixture is stale/aspirational or reflects an older cache
  format is unconfirmed. **(Engram-internal design — not web-verifiable: this is an Engram-owned cache file
  produced by Engram's own `CascadeCacheSupport` writer, not by Antigravity, so no official Antigravity
  source applies.)**
- **`transcript_full.jsonl` vs `transcript.jsonl`** — **Confirmed (official):** same record schema; the
  precise superset difference is **large-output truncation**. `transcript.jsonl` is a token-efficient log
  that *truncates* large text / tool outputs to save space, while `transcript_full.jsonl` is the full,
  untruncated log containing the exact tool results and text. It is not extra record *types* — only
  truncation. Engram ignores `_full` entirely
  ([conversations tutorial](https://medium.com/google-cloud/antigravity-cli-tutorial-series-part-2-conversations-conversations-conversations-76f61756d5bb),
  [hands-on codelab](https://codelabs.developers.google.com/antigravity-cli-hands-on)).
- **`truncated_fields` semantics** — **Confirmed (official):** it is an **array of field-name strings**
  naming which of `content` / `thinking` / `tool_calls` the CLI truncated when writing the record — the
  per-record marker of the same truncation mechanism that distinguishes the truncated `transcript.jsonl`
  from the untruncated `transcript_full.jsonl`. Live distinct values: `["content"]` (958),
  `["tool_calls"]` (89), `["thinking"]` (27), `["thinking","tool_calls"]` (14), `["content","thinking"]`
  (9)
  ([conversations tutorial](https://medium.com/google-cloud/antigravity-cli-tutorial-series-part-2-conversations-conversations-conversations-76f61756d5bb)).
- **Branch-B transcript record schema** (type, step_index, source, status, created_at, content,
  tool_calls, …) — **Confirmed (official):** each `transcript.jsonl` line is one JSON object representing a
  step, with fields `step_index`, `source` (`USER_EXPLICIT` / `MODEL` / `SYSTEM`), `type` (`USER_INPUT`,
  `PLANNER_RESPONSE`, `VIEW_FILE`, `SEARCH_WEB`, `CONVERSATION_HISTORY`, …), `status` (`DONE`, with `ERROR`
  shown), `content`, `created_at`, and `tool_calls` (array including `arguments`). This matches §4.2 / §5.2
  exactly, including the `source` enum values and the DONE/ERROR `status` values (validating §5.2's "status
  has three values incl. ERROR" correction)
  ([conversations tutorial](https://medium.com/google-cloud/antigravity-cli-tutorial-series-part-2-conversations-conversations-conversations-76f61756d5bb),
  [leaked CLI system prompt](https://github.com/asgeirtj/system_prompts_leaks/blob/main/Google/antigravity-cli.md)).
- **Subagent records / tools** (`INVOKE_SUBAGENT`, `invoke_subagent`, `define_subagent`, `send_message`) —
  **Confirmed (official):** the official CLI repo describes orchestration that can "spawn focused subagents
  for parallel work," and the leaked system prompt explicitly names `invoke_subagent`, `define_subagent`,
  and `send_message` ("ONLY for communicating with other agents"), plus a reactive wakeup/inbox model.
  This validates §7's tool-list additions and §10's subagent-dispatch description as real Antigravity
  behavior
  ([leaked CLI system prompt](https://github.com/asgeirtj/system_prompts_leaks/blob/main/Google/antigravity-cli.md),
  [official CLI repo](https://github.com/google-antigravity/antigravity-cli)).
- **Artifact sidecar `<name>.md.metadata.json` keys** — **Confirmed (community):** an unofficial CLI tool
  documents the brain layout with `task.md` / `implementation_plan.md` / `walkthrough.md` each paired with
  a `.md.metadata.json` sidecar whose fields include `artifactType`, `summary`, `updatedAt` (ISO-8601),
  plus `version` (incremental) and `sourceFile`. §13 / §16.10's observed always-present `{summary,
  updatedAt}` plus optional `artifactType` is consistent; `version` / `sourceFile` appear in newer/other
  variants (see §13 update)
  ([unofficial CLI](https://github.com/michaelw9999/antigravity-cli),
  [hands-on codelab](https://codelabs.developers.google.com/antigravity-cli-hands-on)).
- **`cascade.proto` / gRPC RPC names** (`GetAllCascadeTrajectories`, `ConvertTrajectoryToMarkdown`) —
  **Confirmed (community):** independent reverse-engineering identified the live endpoint
  `exa.language_server_pb.LanguageServerService/ConvertTrajectoryToMarkdown` (a gRPC-over-HTTP service
  returning markdown of a coding session), exactly matching the service/RPC names in §12's `cascade.proto`
  and the Windsurf/Cascade lineage claim in §15.1
  ([reverse-engineering writeup](https://ericxliu.me/posts/reverse-engineering-antigravity-ide/)).

---

## 16. Appendix: real anonymized samples

> Structure verbatim; message text / paths / secrets replaced.

### 16.1 Branch A — cache meta line (minimal key-set, 40/58 files)
```json
{"id":"<uuid>","title":"","createdAt":"2026-02-19T15:47:16.862Z","updatedAt":"2026-02-19T15:47:16.862Z","pbSizeBytes":1113514}
```

### 16.2 Branch A — cache meta line (full key-set, 18/58 files)
```json
{"id":"<uuid>","title":"<str len=23>","summary":"<str len=23>","createdAt":"2026-02-24T05:00:52.882699Z","updatedAt":"2026-02-24T05:01:09.968924Z","cwd":"/Users/<user>/-Code-/<project>","pbSizeBytes":158073}
```

### 16.3 Branch A — cache message lines
```json
{"role":"user","content":"<text>"}
{"role":"assistant","content":"<text>"}
```

### 16.4 Branch B — `USER_INPUT`
```json
{"type":"USER_INPUT","step_index":3,"source":"USER_EXPLICIT","status":"DONE","created_at":"2026-05-19T23:58:09Z","content":"<user text>"}
```

### 16.5 Branch B — `PLANNER_RESPONSE` with thinking + tool_calls
```json
{"type":"PLANNER_RESPONSE","step_index":42,"source":"MODEL","status":"DONE","created_at":"2026-05-19T23:59:01Z","thinking":"<reasoning text>","tool_calls":[{"name":"view_file","args":{"AbsolutePath":"/abs/path/file.swift","StartLine":1,"EndLine":80,"toolAction":"<ui action label>","toolSummary":"<ui summary>"}}]}
```

### 16.6 Branch B — tool-result record (`VIEW_FILE`)
```json
{"type":"VIEW_FILE","step_index":43,"source":"SYSTEM","status":"DONE","created_at":"2026-05-19T23:59:02Z","content":"<file contents>"}
```

### 16.7 Branch B — `ERROR_MESSAGE` (and `status:"ERROR"` variant)
On live `ERROR_MESSAGE` records the `content` **key is absent** (or a non-empty string) — it is never
JSON `null`. (The adapter would tolerate `null`, but the CLI never emits it.)
```json
{"type":"ERROR_MESSAGE","step_index":120,"source":"SYSTEM","status":"DONE","created_at":"2026-05-20T00:10:00Z","error":"<error string len=109>"}
{"type":"GREP_SEARCH","step_index":121,"source":"MODEL","status":"ERROR","created_at":"2026-05-20T00:10:05Z","content":"<partial output>"}
```

### 16.8 Branch B — `CONVERSATION_HISTORY` (no `content` key)
```json
{"type":"CONVERSATION_HISTORY","step_index":9,"source":"SYSTEM","status":"DONE","created_at":"2026-05-20T00:00:00Z"}
```

### 16.9 Auxiliary — `.system_generated/messages/<uuid>.json` (ignored by Engram, structurally varied)
Single-message-object variant (most common; optional `hideFromUser` / `sourceMetadata` shown):
```json
{"id":"<uuid>","sender":"<agent>","recipient":"<agent>","priority":"<str>","timestamp":"<iso>","renderDetails":{},"content":"<text>","hideFromUser":false,"sourceMetadata":{}}
```
UUID-keyed MAP variant (some files — top-level keys are message UUIDs, values are the message objects above):
```json
{"<msg-uuid-1>":{"id":"<msg-uuid-1>","sender":"<agent>","recipient":"<agent>","content":"<text>", "...":"..."},"<msg-uuid-2>":{"...":"..."}}
```

### 16.10 Auxiliary — artifact sidecar `<name>.md.metadata.json` (ignored by Engram, variant keys)
`{summary, updatedAt}` are always present; the rest is variant-dependent.
```json
{"artifactType":"<str>","summary":"<str>","updatedAt":"<iso>","requestFeedback":false}
{"summary":"<str>","updatedAt":"<iso>","userFacing":true}
{"artifactType":"<str>","summary":"<str>","updatedAt":"<iso>"}
```

### 16.11 `cascade.proto` (Branch A gRPC wire surface — actual repo file)
```protobuf
service LanguageServerService {
  rpc GetAllCascadeTrajectories(GetAllCascadeTrajectoriesRequest) returns (GetAllCascadeTrajectoriesResponse);
  rpc ConvertTrajectoryToMarkdown(ConvertTrajectoryToMarkdownRequest) returns (ConvertTrajectoryToMarkdownResponse);
}
message CascadeTrajectorySummary {
  string summary = 1;
  string trajectory_id = 4;
  Timestamp created_time = 7;
  Timestamp last_modified_time = 3;
  ConversationAnnotations annotations = 15;  // .title
}
message GetAllCascadeTrajectoriesResponse {
  map<string, CascadeTrajectorySummary> trajectory_summaries = 1;
}
```

---

## References (official sources)

Web confirmation pass, 2026-06-21 (`web_access_ok=true`). Sources used to resolve §15.3 and apply the
§1 / §2.1 / §12 / §13 corrections:

- [Romin Irani — Antigravity CLI Tutorial Series Part 2: Conversations (Google Cloud Community)](https://medium.com/google-cloud/antigravity-cli-tutorial-series-part-2-conversations-conversations-conversations-76f61756d5bb) — community
- [google-antigravity/antigravity-cli (official Google Antigravity CLI repo)](https://github.com/google-antigravity/antigravity-cli) — repo
- [Hands-on with Antigravity CLI (Google Codelabs)](https://codelabs.developers.google.com/antigravity-cli-hands-on) — docs
- [Eric X. Liu — Reverse Engineering the Antigravity IDE](https://ericxliu.me/posts/reverse-engineering-antigravity-ide/) — community
- [arashz/antigravity_decryptor (decrypts IDE .pb conversation files)](https://github.com/arashz/antigravity_decryptor) — repo
- [ag-donald/Antigravity-Database-Manager (recovers IDE conversation history from .pb files)](https://github.com/ag-donald/Antigravity-Database-Manager) — repo
- [michaelw9999/antigravity-cli (unofficial CLI for tasks/artifacts)](https://github.com/michaelw9999/antigravity-cli) — repo
- [asgeirtj/system_prompts_leaks — Google/antigravity-cli.md (leaked CLI system prompt)](https://github.com/asgeirtj/system_prompts_leaks/blob/main/Google/antigravity-cli.md) — community
- [Antigravity 2.0 and IDE (CLI too) — Shared Brain (Google AI Developers Forum)](https://discuss.ai.google.dev/t/antigravity-2-0-and-ide-cli-too-shared-brain/167445) — community
