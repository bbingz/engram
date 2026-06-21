# Claude Code — On-Disk Session Format (Definitive Reference)

Last researched: 2026-06-21 (Engram session-format research workflow)

This is the canonical reference for **how Claude Code persists its interactive
sessions on disk**, plus **how Engram's adapters consume that format**. It
unions five independent research passes against the user's real store
(`~/.claude/projects/`, Claude Code versions `2.1.146` → `2.1.185`) cross-checked
against Engram's TypeScript and Swift adapters.

> **Two sources of truth.** (1) The real on-disk files are the authoritative
> format. (2) Engram's adapters are codified parsing knowledge. **Where they
> disagree, on-disk reality wins** and the discrepancy is flagged explicitly.
>
> All quoted JSON is **anonymized**: message text, code, secrets, and personal
> paths are replaced with placeholders, but **every key is preserved verbatim**.
> This document is about FORMAT, not content.

---

## 1. Overview & TL;DR

Claude Code persists **every interactive session as one append-only JSONL file**
under a per-project directory tree rooted at `~/.claude/projects/`. One JSON
object per line, one record per line, written in event order, never rewritten in
place. The file's basename (a UUID) equals the `sessionId` carried inside each
record. A companion sidecar directory (same UUID, no `.jsonl` extension) may hold
subagent transcripts, spilled tool outputs, and workflow artifacts. Several
global files outside `projects/` (`history.jsonl`, `sessions/<pid>.json`,
`file-history/`) round out the picture.

**Mental model:** a session file is a **flat event log of typed records**. Most
records are bookkeeping ("side-channel") state snapshots; only `user`,
`assistant`, `attachment`, and (most) `system` records participate in the
conversation tree via `uuid`/`parentUuid`. Of those, **only `user` and
`assistant` carry actual chat content** — and that content is itself a nested
array of content blocks. Engram indexes only `user`/`assistant`; everything else
is metadata it deliberately skips.

The single most important thing to internalize is the **three-layer `type`
namespace** (readers conflate these constantly):

```
LAYER 1 — top-level record .type        (one JSONL line = one record)
          user · assistant · attachment · system · last-prompt · ai-title ·
          mode · permission-mode · file-history-snapshot · queue-operation ·
          pr-link · bridge-session · agent-name   (legacy: summary)
   │
   ├─ LAYER 2 — message.content[].type  (only on user/assistant records)
   │            text · thinking · redacted_thinking · tool_use · tool_result · image
   │               └─ tool_reference (doubly-nested inside a tool_result.content[] array)
   │
   └─ LAYER 3 — attachment.type         (only when record .type == "attachment")
                hook_success · skill_listing · task_reminder · deferred_tools_delta ·
                mcp_instructions_delta · queued_command · … (24 distinct subtypes)

   (plus system records carry a 4th discriminator: .subtype —
    compact_boundary · turn_duration · stop_hook_summary · api_error · …)
```

ASCII layering / storage diagram:

```
~/.claude/
├── projects/
│   └── <encoded-cwd>/                       # cwd with '/' AND '.' → '-' (lossy)
│       ├── <session-uuid>.jsonl             # THE session — append-only JSONL
│       │     └── line = top-level record (Layer 1)
│       │           └── message.content[] = content blocks (Layer 2)   [user/assistant only]
│       │           └── attachment.type    = attachment subtype (Layer 3) [attachment only]
│       ├── <session-uuid>/                  # OPTIONAL sidecar dir, same UUID stem
│       │   ├── subagents/
│       │   │   ├── agent-<agentId>.jsonl    # subagent transcript (isSidechain:true)
│       │   │   ├── agent-<agentId>.meta.json# {agentType, description, toolUseId}
│       │   │   └── workflows/wf_<id>/agent-*.{jsonl,meta.json,journal.jsonl}
│       │   ├── workflows/wf_<id>{.json,/…}  # workflow run definitions/agents
│       │   ├── tool-results/<id>.txt        # spilled large tool outputs
│       │   └── session-memory/summary.md    # compaction markdown (rare)
│       ├── sessions-index.json              # OPTIONAL per-project catalog (rare/stale)
│       └── memory/, MEMORY.md, memory.bak.* # THIRD-PARTY plugin artifacts (not CC core)
├── history.jsonl                            # global cross-project prompt history
├── sessions/<pid>.json                      # live process registry (rewritten in place)
└── file-history/<session-uuid>/<hash>@v<N>  # checkpoint backups of edited files
```

**TL;DR field cheat-sheet:** every conversation record carries `type`, `uuid`,
`parentUuid`, `sessionId`, `timestamp`, `cwd`, `gitBranch`, `version`,
`userType`, `entrypoint`, `isSidechain`. `assistant` adds `message.usage` (token
accounting) and `requestId`. `user` adds `promptId` and, for tool returns,
`toolUseResult` + `sourceToolAssistantUUID`. Subagent files add `agentId` and set
`isSidechain:true`.

---

## 2. On-disk layout & file naming

### 2.1 Store root

Both adapters hardcode the root as `homedir()/.claude/projects`:
- TS: `ClaudeCodeAdapter` constructor (`claude-code.ts:29`).
- Swift: `init(projectsRoot:)` default (`ClaudeCodeAdapter.swift:14-15`).

Permissions observed: project dirs `0700`/`0755`; `.jsonl` files `0600`;
`.meta.json` files `0644`.

### 2.2 The cwd → directory-encoding scheme (exact)

The project directory name is derived from the session's **working directory**
(`cwd`) by character substitution. Verified against real in-record `cwd` values:

| Real cwd | Encoded dir name |
|---|---|
| `/Users/bing/-Code-/engram` | `-Users-bing--Code--engram` |
| `/Users/bing/-Code-` | `-Users-bing--Code-` |
| `/Users/bing/-Automations-/glm-coding` | `-Users-bing--Automations--glm-coding` |
| `/Users/bing/-Code-/mediahub/.claude/worktrees/stupefied-ardinghelli-0b23ef` | `-Users-bing--Code--mediahub--claude-worktrees-stupefied-ardinghelli-0b23ef` |
| `/` (filesystem root) | `-` |

**Encoding rules (forward, cwd → dir):**
1. Every `/` (path separator) → `-`.
2. Every `.` (literal dot in a segment, e.g. `.claude`) → `-`.
3. A literal `-` already in the path is kept verbatim.

This is why a leading `/` always yields a **leading `-`**, and why `/.claude/`
collapses to `--claude-` (the `/` before `.claude` → `-`, the `.` → `-`). Root
`/` encodes to the single special dir `-`.

**The encoding is lossy and not uniquely reversible.** A run of dashes could come
from `/`, `.`, a literal `-`, or any combination; the segment boundary inside the
run is unrecoverable.

> **Discrepancy (on-disk reality wins).** Both adapters' `decodeCwd` use the rule
> `"--" → literal "-"`, then `"-" → "/"`, then restore (TS `claude-code.ts:302-307`;
> Swift `ClaudeCodeAdapter.swift:340-345`). They do **not** model the `.` → `-`
> rule and collapse `--` to a literal `-`, so for paths like this user's
> literally-named `-Code-`/`-Automations-` dirs the decode diverges:
>
> ```text
> decodeCwd("-Users-bing--Code--engram")  -> "/Users/bing-Code-engram"   (WRONG)
> real in-record cwd                       -> "/Users/bing/-Code-/engram"
> ```
>
> **Engram never relies on `decodeCwd` for correctness.** Both `parseSessionInfo`
> implementations read the authoritative `cwd` field straight out of each record
> and derive `project` from `basename(cwd)`. `decodeCwd` is a display/fallback
> helper only. The dir name is a lossy convenience key; the in-record `cwd` is
> the source of truth.

### 2.3 Session file naming grammar

```
<session-uuid>.jsonl          session-uuid = canonical lowercase UUIDv4
                              e.g. 8f06ae86-7a5b-487a-a348-7d276e729f30.jsonl
```

- The basename (minus `.jsonl`) equals the `sessionId` field inside every record
  (verified 30/30, zero mismatches).
- Files range from a few KB (2 records) to >12 MB.
- A directory of the **same UUID without `.jsonl`** may sit beside the file: the
  companion sidecar dir. Not all sessions have one.

### 2.4 The special `-` project dir

`~/.claude/projects/-/` encodes cwd `/` (sessions started at filesystem root or
without project context). In this store it held only a stale `sessions-index.json`
and no live `.jsonl` files. Engram handles it transparently — it's just another
`projects/*` dir; `project`/`cwd` resolve from each record's `cwd` field.

### 2.5 Subagent subdirectory

```
<session-uuid>/subagents/
  agent-<agentId>.jsonl                 # subagent transcript
  agent-<agentId>.meta.json             # {agentType, description, toolUseId}
  workflows/wf_<id>/agent-<agentId>.{jsonl,meta.json,journal.jsonl}  # nested
```

- `agentId` is **usually a 17-char hex id** (e.g. `a784b50f9fbfb258b`,
  `a4e5796f79594d4d0`), prefixed `agent-` in the filename. It is **not** a UUID.
  But **do not assume fixed length or pure hex**: workflow/provider review
  subagents instead use a `<label>-<hex>` form, e.g. `akimi-review-699cb045f0e92446`
  (len 29) and `aagy-review-085940ff88969949` (len 28). Treat `agentId` as an
  **opaque token** — match on it, never parse it.
- The subagent JSONL shares the **parent's `sessionId`** on every line; only
  `agentId` makes it unique. Engram keys subagent DB rows by `agentId`
  (TS `claude-code.ts:145`, Swift `ClaudeCodeAdapter.swift:150`).
- See §10 for the full dispatch/linkage model.

### 2.6 Exhaustive enumeration of every file kind in a project dir

| Path (relative to project dir) | Kind | Owner | Indexed by Engram? |
|---|---|---|---|
| `<uuid>.jsonl` | Session transcript (JSONL) | Claude Code | **Yes** (primary) |
| `<uuid>/subagents/agent-<hex>.jsonl` | Subagent transcript | Claude Code | **Yes** |
| `<uuid>/subagents/agent-<hex>.meta.json` | Subagent metadata sidecar | Claude Code | No |
| `<uuid>/subagents/workflows/wf_*/agent-*.{jsonl,meta.json}` | Nested workflow subagents | Claude Code / polycli | **No** (coverage gap, see §15) |
| `<uuid>/subagents/workflows/wf_*/journal.jsonl` | Workflow memoization journal | Claude Code / polycli | No |
| `<uuid>/workflows/wf_<id>.json` | Workflow run definition (script/phases) | Claude Code / polycli | No |
| `<uuid>/workflows/wf_<id>/agent-*.{jsonl,meta.json}` | Workflow agent runs | Claude Code / polycli | No |
| `<uuid>/tool-results/<9-char-id>.txt` | Spilled large tool output | Claude Code | No |
| `<uuid>/session-memory/summary.md` | Compaction/auto-summary markdown | Claude Code | No |
| `sessions-index.json` | Per-project session index sidecar | Claude Code | No |
| `memory/`, `MEMORY.md`, `memory.bak.<ts>/` | Project memory notes/backups | **Third-party plugin** | No |

`workflows/wf_<id>.json` shape (anonymized):

```json
{"runId":"wf_1f5d71cb-5a0","timestamp":"2026-05-31T07:14:13.157Z","taskId":"<9char>",
 "script":"export const meta = { name: '...', description: '...', phases: [ ... ] } ..."}
```

`tool-results/<id>.txt` is the raw text/JSON of a tool output too large to inline;
the transcript references it. `<id>` is a 9-char base36-ish token (e.g. `bcvrd4r54`).

### 2.7 Discovery / enumeration (per adapter)

Both adapters walk `projects/*` (one level), then for each entry:
- ends in `.jsonl` → yield it as a session locator;
- is a directory → look for a `subagents/` child and yield every `*.jsonl` inside.

Swift `listSessionLocators()` (`ClaudeCodeAdapter.swift:27-48`) returns a
**sorted** list; TS `listSessionFiles()` (`claude-code.ts:41-73`) is an unsorted
async generator. **Neither descends into `subagents/workflows/`**, nor reads
`workflows/`, `tool-results/`, `session-memory/`, `memory/`, or `*.meta.json`.

---

## 3. File lifecycle & generation

### 3.1 Write model — strictly append-only

Each line is one record, written as the event happens. Claude Code **never
rewrites earlier lines in place**. Evidence:

- **Filename UUID == internal `sessionId`** for every sampled file. New
  conversations get a fresh UUID file; existing files are only appended to.
- **Mutable state is re-snapshotted, not edited.** `last-prompt`, `mode`,
  `permission-mode`, and `ai-title` appear in **repeating clusters** throughout
  one file. When the value changes, Claude Code **appends a new record** rather
  than mutating the old one — **last occurrence wins**. (A 933-line file can hold
  107 `mode` and 107 `last-prompt` records.)
- **Message records are append-order authoritative.** Timestamps are
  monotonic-ish but can tie sub-second on near-simultaneous emission. Consumers
  should treat byte/append order — not timestamp sort — as canonical, and use the
  `uuid`/`parentUuid` linked list for the true tree.

### 3.2 Ordering & the parentUuid DAG

File byte order = causal/append order. Conversation-tree records carry `uuid`
(self) and `parentUuid` (predecessor), forming an explicit linked list/DAG, so
the tree is recoverable even when append order and timestamps disagree. See §5.6
for the full linkage model.

### 3.3 Crash / partial-line behavior

Because writes are append-only line-at-a-time, a truncated final line is
**possible in principle** (a crash mid-write could leave a non-`}`-terminated
tail), and both adapters tolerate it: each line is parsed in isolation; a parse
failure returns `null`/skip (TS `parseLine` `claude-code.ts:325-331`; Swift via
`JSONLAdapterSupport.readObjects`). One bad tail line never corrupts the rest.
The TS reader also skips blank lines (`if (line.trim())`, `claude-code.ts:317`).

> **Framing correction (on-disk reality).** Torn/truncated tail lines, while the
> robustness guarantee is real, were **not actually observed**: a per-file scan
> of the whole store (`jq -R 'fromjson? // "BAD"'` over every non-subagent
> `.jsonl`) found **0 unparseable lines** and **0 concatenated/interleaved
> records** anywhere. The garbled tokens that show up in a naive cross-file
> `cat | jq` census (e.g. `last-prlast-prompt`) are **not** real torn writes —
> they are an artifact of files that lack a trailing newline being merged at
> their boundary when many files are `cat`'d together. **A missing trailing
> newline on the last line is common**, so readers must split **per file**
> rather than concatenate, or they will mis-merge file boundaries.

### 3.4 `/compact` — same file, in-place continuation

**`/compact` does NOT start a new file.** Compaction happens mid-file and the
conversation keeps appending to the same `<session-uuid>.jsonl`. Verified: in one
933-line file the compact records sit at lines 869–870 and **63 more records are
appended after the compact point in the same file**. See §11 for the records.

### 3.5 `/clear` and resume (`--continue` / `--resume`)

- **`/clear`** ends the current session's appends (no terminating record). The
  next prompt opens a **brand-new** `<new-uuid>.jsonl`. No back-pointer links the
  new file to the cleared one — they are independent.
- **Resume (`--continue` / `--resume`)** **reopens the existing
  `<sessionId>.jsonl` and appends** — it is not "new file pointing back."
  Confirmed structurally: every sampled file's internal `sessionId` matches its
  filename, and a scan of 120 files found **zero** cross-file dangling
  `parentUuid` references. On-disk resume signals:
  - **`last-prompt`** `{type, leafUuid, sessionId}` — points to the **leaf**
    (most recent) message UUID so new turns attach with the correct `parentUuid`.
    Re-appended each turn; last = current leaf.
  - **`summary`** (legacy) `{type, summary, leafUuid}` — older resume marker;
    **absent in this store** (CC 2.1.x writes `last-prompt` + `ai-title`
    instead). Kept in both adapters' skip comments for backward compatibility.

### 3.6 Crash/version robustness summary

`version` is stamped on every conversation/attachment/system record (e.g.
`"2.1.156"`, `"2.1.183"`). Lifecycle-record *shapes* evolve across versions, but
the adapters gate purely on the `MESSAGE_TYPES = {user, assistant}` allowlist
(TS `claude-code.ts:26`; Swift inline at `:101`), so new record/subtypes are
forward-safely skipped without a code change.

---

## 4. Record / line taxonomy (top-level Layer-1 record types)

One JSONL line = one top-level record discriminated by `.type`. Full-store census
(unioned across research passes — counts are order-of-magnitude indicative, not
exact, and grow with the store):

| Record `type` | In conversation tree? | Carries `message`? | Purpose | Engram |
|---|:---:|:---:|---|---|
| `assistant` | **yes** (`uuid`/`parentUuid`) | yes | One model response turn (text/thinking/tool_use blocks + `usage`) | **indexed** |
| `user` | **yes** | yes | Human prompt OR tool_result return OR injected system text | **indexed** |
| `attachment` | **yes** | no (has `attachment`) | Injected context/hook/reminder; subtype in `.attachment.type` (Layer 3) | skipped |
| `system` | **yes** (most) | no | System/meta events; discriminated by `.subtype` | skipped |
| `last-prompt` | no | no | Resume leaf pointer `{leafUuid, sessionId, lastPrompt?}` | skipped |
| `ai-title` | no | no | Auto-generated session title `{aiTitle, sessionId}` | skipped |
| `permission-mode` | no | no | Permission mode snapshot `{permissionMode, sessionId}` | skipped |
| `mode` | no | no | UI/interaction mode snapshot `{mode, sessionId}` | skipped |
| `queue-operation` | no | no | Prompt-queue enqueue/dequeue/remove `{operation, content?, sessionId, timestamp}` | skipped |
| `file-history-snapshot` | no | no | Tracked-file backup index per message; keys `{type, messageId, isSnapshotUpdate, snapshot}` — **carries NO `sessionId`** (associated to its session only by file membership) | skipped |
| `pr-link` | no | no | Links a created PR `{prNumber, prRepository, prUrl, …}` | skipped |
| `bridge-session` | no | no | Links to a bridged (desktop↔cli/cloud) session | skipped |
| `agent-name` | no | no | Human-readable agent label `{agentName, sessionId}` | skipped |
| `summary` *(legacy)* | n/a | n/a | Old compaction/resume marker `{summary, leafUuid}` — **0 occurrences** in this store | skipped |

**Workflow-journal records (`subagents/workflows/wf_*/journal.jsonl` only — NOT
session transcript):** `started` and `result`, a memoization cache, no envelope:

```json
{"type":"started","key":"v2:<sha256>","agentId":"<agentId>"}
{"type":"result","key":"v2:<sha256>","agentId":"<agentId>","result":{ … }}
```

**Key structural fact:** only `user`, `assistant`, `attachment`, and (most)
`system` records carry `uuid`/`parentUuid` and participate in the tree. The
other 9 record types have **no `uuid` and no `parentUuid`** — they are flat
"side-channel" state records appended into the same file. Do not treat their
absent `parentUuid` as a tree root.

> **Pointer-list correction.** The KNOWN-POINTERS list mixed layers. `message`
> (always literal `"message"` on `message.type`), `direct`
> (`tool_use.caller.type`), `text`/`thinking`/`tool_use`/`tool_result`
> (Layer-2 content blocks), `create` (`toolUseResult.type`), and
> `task_reminder`/`skill_listing`/`hook_success`/`mcp_instructions_delta`/`deferred_tools_delta`
> (Layer-3 `attachment.type`) are **NOT top-level record types**. Only
> `permission-mode`, `file-history-snapshot`, `ai-title`, `system`, `last-prompt`
> from that list are genuine Layer-1 types.

---

## 5. Shared envelope / metadata fields

Present on the **conversation-tree records** (`user`/`assistant`/`attachment`/
`system` — the ones with `uuid`). **Most** side-channel records carry `type` +
`sessionId` (+ their own payload) — `last-prompt`, `ai-title`, `mode`,
`permission-mode`, `queue-operation`, `pr-link`, `bridge-session`, and
`agent-name` all do. **The exception is `file-history-snapshot`, which carries
NO `sessionId` at all** — its only keys are `{type, messageId, isSnapshotUpdate,
snapshot}`, and it is associated to its session **only by file membership**
(which `.jsonl` it sits in), never by an in-record field (verified: 1242/1242
`file-history-snapshot` records lack `sessionId`; see §4, §13.4).

| Field | Type | Meaning | Optional? | Example |
|---|---|---|---|---|
| `type` | string | Layer-1 record type | required | `"assistant"` |
| `uuid` | string (uuid) | This record's unique id; node id in the tree | tree records | `"42245a7c-…"` |
| `parentUuid` | string\|null | `uuid` of preceding record; `null` = chain root | tree records | `"8375e1cd-…"` / `null` |
| `sessionId` | string (uuid) | Owning session = filename stem; subagents reuse parent's | **all** records | `"18c2384d-…"` |
| `timestamp` | string (ISO-8601 ms, `Z`) | Event time | tree records | `"2026-06-19T04:59:17.179Z"` |
| `cwd` | string (abs path) | **Authoritative** working dir at write time | tree records | `"/Users/bing/-Code-/polycli"` |
| `gitBranch` | string | Active git branch (`""` if none) | tree records | `"main"` |
| `version` | string (semver) | Claude Code version that wrote the line | tree records | `"2.1.183"` |
| `userType` | string | `"external"` (normal) or `"ant"` (internal Anthropic build) | tree records | `"external"` |
| `entrypoint` | string | Launch surface: `"cli"`, `"sdk-cli"`, `"claude-desktop"` | tree records | `"cli"` |
| `isSidechain` | bool | `true` inside subagent/sidechain files; else `false` | tree records | `false` |
| `message` | object | The chat message (user/assistant only) | user/assistant | see §6 |
| `requestId` | string (`req_…`) | Anthropic API request id for the turn | assistant only | `"req_011C…"` |
| `promptId` | string (`prompt_…`) | Groups records belonging to one user prompt | user only | `"prompt_01…"` |
| `agentId` | string (opaque; usually 17-hex) | Subagent unique key; on subagent records (+ parents that spawned one). Usually 17-char hex but `<label>-<hex>` forms exist (e.g. `akimi-review-…`) — treat as opaque | subagent files | `"a686211783283b2cb"` |
| `slug` | string | Short kebab session/topic title (newer 2.1.x) | optional | `"lively-rolling-ripple"` |
| `isMeta` | bool | Marks injected/non-conversational records | optional | `true` |
| `origin` | object `{kind}` | Prompt origin: `{"kind":"human"\|"task-notification"\|"coordinator"}` | user, optional | `{"kind":"human"}` |
| `promptSource` | string | `"typed"`/`"system"`/`"queued"`/`"sdk"` | user, optional | `"typed"` |
| `permissionMode` | string | Permission mode in force for the turn | user, optional | `"bypassPermissions"` |
| `sourceToolAssistantUUID` | string (uuid) | On tool_result user records: `uuid` of the assistant record whose `tool_use` this answers | user/tool_result | `"<uuid>"` |
| `toolUseResult` | object\|string | Structured/raw tool-output mirror at the envelope level (shape varies by tool) | user/tool_result | `{…}` |
| `attributionAgent` | string | Which agent persona produced the turn (subagents) | assistant, optional | `"i18n"` |
| `attributionSkill` / `attributionPlugin` | string | Skill/plugin attributed to the turn | assistant, optional | `"<skill>"` |
| `attributionMcpServer` / `attributionMcpTool` | string | MCP server/tool attributed | assistant, MCP only | `"codegraph"` / `"codegraph_status"` |
| `isApiErrorMessage` | bool | This assistant record is a synthesized API-error notice | assistant, error | `true` |
| `error` | string | Error class for the above | assistant, error | `"rate_limit"` |
| `apiErrorStatus` | int\|null | HTTP status of the API error | assistant, error | `429` |
| `isCompactSummary` | bool | Marks the synthetic summary user message after a compaction | optional | `true` |
| `isVisibleInTranscriptOnly` | bool | Display-only; excluded from API context | optional | `true` |
| `container` / `context_management` | object | Container/exec & server context-window metadata | assistant, very rare | `{…}` |
| `teamName` | string | Team/workspace name (org installs only) | **unverified in this store** (0 records — org installs only) | `"<team>"` |

> **No top-level `diagnostics` field.** `diagnostics` exists **only** at
> `message.diagnostics` (cache-miss info, see §6.1). A full-store scan found **0
> records** with a top-level `diagnostics` key — there is no top-level mirror.

> **Engram coverage gap.** Both adapters read **only** `type`, `sessionId`,
> `agentId`, `cwd`, `timestamp`, and `message.{model,content,usage}`. Everything
> else — `uuid`, `parentUuid`, `requestId`, `promptId`, `isSidechain`, `slug`,
> `origin`, `attribution*`, `toolUseResult`, `isCompactSummary` — is **discarded**.
> Parent linkage is reconstructed from the **filesystem path** (`/subagents/`),
> never from the in-file `parentUuid`.

### 5.6 parentUuid linkage model (the conversation tree)

- Each tree record has `uuid` (self) and `parentUuid` (predecessor). Following
  `parentUuid` from any leaf to a `null` reaches the chain root. This forms a
  **tree** (branching possible after edits/retries/compaction); most sessions are
  a single linear chain.
- **`parentUuid: null` = a root.** A session usually opens with an `attachment`
  (or `user`) root; per-file there is normally exactly one tree root among the
  tree records.
- **Cross-tree pointers** (logical edges orthogonal to `parentUuid`):
  - `system/compact_boundary` carries **`logicalParentUuid`** — the
    pre-compaction logical parent, stitching the post-compaction chain across the
    boundary.
  - `last-prompt` carries **`leafUuid`** — current transcript leaf (resume).
  - `file-history-snapshot` carries **`messageId`** — the message `uuid` the
    snapshot attaches to.
  - tool_result `user` records carry **`sourceToolAssistantUUID`** — links a
    result back to the assistant record that emitted the matching `tool_use`.

Verified opening sequence (anonymized to 8-char ids; side-channel records emitted
before the tree starts):

```jsonc
{"type":"last-prompt",         "uuid":null,       "parentUuid":null}        // side-channel (no uuid field)
{"type":"mode",                "uuid":null,       "parentUuid":null}        // side-channel
{"type":"permission-mode",     "uuid":null,       "parentUuid":null}        // side-channel
{"type":"attachment",          "uuid":"3c40afb6", "parentUuid":null}        // TREE ROOT
{"type":"attachment",          "uuid":"8375e1cd", "parentUuid":"3c40afb6"}  // → root
{"type":"file-history-snapshot","uuid":null,      "parentUuid":null}        // side-channel
{"type":"user","isMeta":true,  "uuid":"4efc3f20", "parentUuid":"8375e1cd"}  // injected user
{"type":"user",                "uuid":"42245a7c", "parentUuid":"4efc3f20"}  // real prompt
```

---

## 6. Message & content-block schema

### 6.1 The assistant `message` object

Keys (1335/1340 records): `id, type, role, model, content, stop_reason,
stop_sequence, stop_details, usage` (+ optional `diagnostics`; 5 records also
carry `container` + `context_management`).

| Field | Type | Meaning | Present | Example |
|---|---|---|---|---|
| `id` | string (`msg_…`) | Anthropic message id | always | `"msg_01KbYMB1YS5…"` |
| `type` | string | always literal `"message"` | always | `"message"` |
| `role` | string | always `"assistant"` | always | `"assistant"` |
| `model` | string | model that produced it; `"<synthetic>"` for client-generated/error turns | always | `"claude-opus-4-8"` |
| `content` | array | content blocks (§6.3) — assistant content is **always an array** | always | `[ {…} ]` |
| `stop_reason` | string\|null | **`tool_use`** (most common — model wants to call a tool), `end_turn`, `null` (in-progress / streaming), `max_tokens`, `stop_sequence`, `refusal` | always (nullable) | `"tool_use"` |
| `stop_sequence` | string\|null | which stop sequence fired | always (nullable) | `null` |
| `stop_details` | object\|null | extended stop info; `null` across the corpus | always (nullable) | `null` |
| `usage` | object | token accounting (§9) | always | `{…}` |
| `diagnostics` | object\|null | cache-miss info, e.g. `{"cache_miss_reason":{"type":"messages_changed","cache_missed_input_tokens":26074}}` (also `previous_message_not_found`, `tools_changed`, `unavailable`) | always (nullable) | `null` |

> **`stop_reason` distribution (real census, ~23k assistant records across the
> `engram`/`polycli`/`mediahub` stores):** `tool_use`=16401, `end_turn`=5582,
> `max_tokens`=897, `null`=80, `stop_sequence`=40, `refusal`=24. **`tool_use`
> dominates** because most turns emit a `tool_use` block — do **not** treat
> `end_turn` as the default. `refusal` is the model declining to answer.
> (`null` = in-progress / streaming record not yet finalized.)

> **`cache_miss_reason.type` values (real census, `message.diagnostics`
> non-null):** the **dominant** value is `messages_changed`; also
> `previous_message_not_found`, `tools_changed`, and `unavailable`. The
> `cache_miss_reason` object carries `{type, cache_missed_input_tokens?}` and
> explains why a cache read missed for that turn.
| `container` / `context_management` | object | container/exec & server context metadata | rare | — |

### 6.2 The user `message` object

Minimal keys: `role`, `content`.

| Field | Type | Meaning | Present | Example |
|---|---|---|---|---|
| `role` | string | always `"user"` | always | `"user"` |
| `content` | **string OR array** | typed prompt (string) vs. tool results/images/mixed (array) | always | `"<prompt>"` or `[ {…} ]` |

`message.content` polymorphism (primary 3112-line file): string → 57 (typed
prompts / injected meta text); array of `tool_result` → 786; array with `text`
→ 2; array with `image` → 1. **Practical rule (both adapters):** a `user` record
whose content array contains a `tool_result` block is a **tool message**, not a
human turn.

### 6.3 Assistant content blocks (Layer 2)

#### `text` — keys `["text","type"]`
```json
{ "type": "text", "text": "<assistant prose, redacted>" }
```

#### `thinking` — keys `["signature","thinking","type"]`
| Field | Type | Meaning |
|---|---|---|
| `type` | string | `"thinking"` |
| `thinking` | string | the chain-of-thought text |
| `signature` | string (base64, hundreds of chars) | cryptographic signature authenticating the block to the API |
```json
{ "type": "thinking", "thinking": "<reasoning text, redacted>", "signature": "<base64 sig, redacted>" }
```

#### `redacted_thinking` — **not observed on disk** (CC 2.1.x); Anthropic-API spec shape
| Field | Type | Meaning |
|---|---|---|
| `type` | string | `"redacted_thinking"` |
| `data` | string (encrypted blob) | opaque encrypted reasoning the client can't read |
```json
{ "type": "redacted_thinking", "data": "<encrypted blob>" }
```

#### `tool_use` — keys `["caller","id","input","name","type"]`
| Field | Type | Meaning | Present |
|---|---|---|---|
| `type` | string | `"tool_use"` | always |
| `id` | string (`toolu_…`) | tool-call id — **join key** to a later `tool_result.tool_use_id` | always |
| `name` | string | tool name (`Bash`, `Read`, `Edit`, `Write`, `Glob`, `Grep`, `Agent`, `AskUserQuestion`, `mcp__<server>__<tool>`, …) | always |
| `input` | object | tool arguments (shape depends on tool) | always |
| `caller` | object | who invoked the tool; `{"type":"direct"}` is the only value observed (100%) | v2.1.x |
```json
{ "type": "tool_use", "id": "toolu_01PnRi…", "name": "Bash",
  "input": { "command": "<redacted>", "description": "<redacted>" },
  "caller": { "type": "direct" } }
```

### 6.4 User content blocks (Layer 2)

#### `tool_result` — keys `["content","is_error","tool_use_id","type"]` or (success) `["content","tool_use_id","type"]`
| Field | Type | Meaning | Present |
|---|---|---|---|
| `type` | string | `"tool_result"` | always |
| `tool_use_id` | string (`toolu_…`) | **join key** back to the originating `tool_use.id` | always |
| `content` | **string OR array** | result payload. String (~99%) for plain text; array when blocks needed (`text`, `image`, `tool_reference`) | always |
| `is_error` | bool | present & `true` when the tool errored; omitted on success | optional |
```json
{ "type": "tool_result", "tool_use_id": "toolu_01RmBz…", "content": "<plain text output, redacted>" }
```
```json
{ "type": "tool_result", "content": "<error output, redacted>", "is_error": true, "tool_use_id": "toolu_01RmBz…" }
```
Array content with **`tool_reference`** blocks (deferred-tool / "Tool loaded"
listings — each `{type:"tool_reference", tool_name}`):
```json
{ "type": "tool_result", "tool_use_id": "toolu_01XXXX",
  "content": [
    { "type": "tool_reference", "tool_name": "mcp__codegraph__codegraph_search" },
    { "type": "tool_reference", "tool_name": "mcp__codegraph__codegraph_explore" } ] }
```
Array content with an **`image`** block (e.g. screenshot tools; store-wide inside
tool_results: 11 image, 233 text, 127 tool_reference):
```json
{ "tool_use_id": "toolu_01XXXX", "type": "tool_result",
  "content": [ { "type": "image", "source": { "type": "base64", "data": "<base64, redacted>", "media_type": "image/png" } } ] }
```

#### `image` — keys `["source","type"]` (pasted image, or inside a tool_result array)
| Field | Type | Meaning |
|---|---|---|
| `type` | string | `"image"` |
| `source` | object | the image payload |
| `source.type` | string | `"base64"` (only value observed) |
| `source.media_type` | string | `"image/jpeg"`, `"image/png"`, … |
| `source.data` | string | base64-encoded bytes |
```json
{ "type": "image", "source": { "type": "base64", "media_type": "image/jpeg", "data": "<base64-image-bytes, redacted>" } }
```

#### `text` (in user array) — same shape as assistant `text` (`{type:"text", text}`), when a user turn mixes text with other blocks.

### 6.5 Attachment subtypes (Layer 3) — full census

Envelope = standard tree envelope; payload entirely inside `.attachment` (which
always has its own `.type`). Full observed enumeration with key-sets:

| `attachment.type` | Key fields |
|---|---|
| `hook_success` | `command, content, durationMs, exitCode, hookEvent, hookName, stderr, stdout, toolUseID, type` |
| `deferred_tools_delta` | `addedNames, addedLines, removedNames, readdedNames, pendingMcpServers*, type` (`pendingMcpServers` dropped in later versions) |
| `skill_listing` | `content, isInitial, names, skillCount, type` |
| `task_reminder` | `content, itemCount, type` |
| `queued_command` | `commandMode, prompt, type` |
| `edited_text_file` | `filename, snippet, type` |
| `mcp_instructions_delta` | `addedBlocks, addedNames, removedNames, type` |
| `hook_additional_context` | `content, hookEvent, hookName, toolUseID, type` |
| `ultra_effort_enter` | `reminderType, type` |
| `goal_status` | `condition, met, sentinel, type` |
| `file` | `content, displayPath, filename, type` |
| `compact_file_reference` | `filename, displayPath, type` |
| `hook_system_message` | `content, hookEvent, hookName, toolUseID, type` |
| `command_permissions` | `allowedTools, type` |
| `agent_listing_delta` | `addedLines, addedTypes, isInitial, removedTypes, showConcurrencyNote, type` |
| `date_change` | `newDate, type` |
| `plan_mode` | `isSubAgent, planExists, planFilePath, reminderType, type` |
| `nested_memory` | `content, displayPath, path, type` |
| `workflow_keyword_request` | `type` (only) |
| `invoked_skills` | `skills, type` |
| `plan_mode_exit` | `planExists, planFilePath, type` |
| `plan_file_reference` | `planFilePath, planContent, type` |
| `auto_mode` | `type` (only) |

```jsonc
// task_reminder (empty) — note nested .attachment.type vs top-level .type=="attachment"
{"type":"attachment","uuid":"<uuid>","parentUuid":"<uuid>","sessionId":"<uuid>",
 "timestamp":"…","cwd":"<abs>","gitBranch":"main","version":"2.1.183","userType":"external",
 "entrypoint":"cli","isSidechain":false,
 "attachment":{"type":"task_reminder","content":[],"itemCount":0}}
```
```jsonc
// hook_success
{"type":"attachment", …envelope…,
 "attachment":{"type":"hook_success","hookName":"<hook>","hookEvent":"PostToolUse",
   "command":"<cmd>","stdout":"<…>","stderr":"","exitCode":0,"durationMs":123,"toolUseID":"toolu_…"}}
```

> Both adapters skip `attachment` entirely (comment in `claude-code.ts:22-25`),
> so **none of these 24 subtypes are surfaced by Engram**.

### 6.6 `system` records (discriminated by `.subtype`)

All carry the standard envelope (most carry `uuid`/`parentUuid`/`isMeta`).

| `subtype` | Distinctive keys | Meaning |
|---|---|---|
| `turn_duration` | `durationMs, messageCount, pendingWorkflowCount` | Wall-clock for a completed turn |
| `stop_hook_summary` | `hookCount, hookErrors, hookInfos, hookAdditionalContext, hasOutput, preventedContinuation, stopReason, toolUseID, level` | Summary of Stop-hook execution |
| `away_summary` | `content` | Summary written when the user is "away" |
| `api_error` | `error, cause, maxRetries, retryAttempt, retryInMs, level` | API failure + retry state |
| `scheduled_task_fire` | `content` | A scheduled task fired |
| `local_command` | `content, level` | Local slash-command invocation echo |
| `compact_boundary` | `compactMetadata, logicalParentUuid, content, level` | Marks a context compaction (see §11) |
| `bridge_status` | `content, url` | Bridge (desktop↔cli) status |
| `informational` | `content, level, slug` | Generic info notice |
| `model_refusal_fallback` | `apiRefusalCategory, apiRefusalExplanation, originalModel, fallbackModel, trigger, direction, requestId, content, level` | Model refused → fell back to another model |

`.level` values observed: `error`, `warning`, `suggestion`, `info` (often absent).

---

## 7. Tool calls & results

### 7.1 The call ↔ result linkage model

The link is **`tool_use.id` (assistant content block) ⇒ `tool_result.tool_use_id`
(user content block)**. Verified in the primary file: 786 unique `tool_use.id`,
786 unique `tool_use_id` references, **786 matched (100%)**. Additionally, the
user `tool_result` record carries `sourceToolAssistantUUID` at the envelope level
pointing back to the assistant **record** `uuid` that emitted the call.

The matching `tool_result` block lives inside a **`type:"user"` record** (the
tool's output folded back into the conversation as a user turn).

### 7.2 Id namespaces (distinct prefixes)

| Id | Prefix | Where |
|---|---|---|
| assistant message id | `msg_…` | `message.id` |
| tool call | `toolu_…` | `tool_use.id` ⇒ `tool_result.tool_use_id` |
| API request | `req_…` | `requestId` |
| record identity | bare UUID | `uuid` / `parentUuid` / `sessionId` |
| user prompt grouping | `prompt_…` | `promptId` |
| subagent | opaque (usually 17-hex; sometimes `<label>-<hex>`) | `agentId` |
| cloud bridge | `cse_…` | `bridge-session.bridgeSessionId` |

### 7.3 The `toolUseResult` envelope mirror (raw exec result)

On tool_result user records, `toolUseResult` mirrors the structured raw result.
Shape **varies by tool**. Observed key-sets:

| Tool | `toolUseResult` shape |
|---|---|
| Bash | `{stdout, stderr, interrupted, isImage, noOutputExpected}` (base); **variant keys** added per call: `backgroundTaskId`, `dangerouslyDisableSandbox`, `gitOperation`, `returnCodeInterpretation`, `assistantAutoBackgrounded`, `staleReadFileStateHint`, `persistedOutputPath`/`persistedOutputSize` |
| Edit | `{filePath, oldString, newString, originalFile, replaceAll, structuredPatch, userModified}` |
| Write | `{type:"create"\|"update", content, filePath, originalFile, structuredPatch, userModified}` |
| Read | `{type, file}` |
| AskUserQuestion | `{questions, answers, annotations}` (also a 2-key `{questions, answers}` variant) |
| **Agent** (subagent result) | `{agentId, agentType, status, content, prompt, totalTokens, totalToolUseCount, totalDurationMs, toolStats, usage{…full usage…}}` (+ optional `resolvedModel`) — **carries the subagent's full token/cost totals** |
| TaskUpdate | `{statusChange, success, taskId, updatedFields}` (also `{success, taskId, updatedFields}` / `{error, success, taskId, updatedFields}`) |
| TaskGet | `{task}` (also `{retrieval_status, task}`) |
| ToolSearch | `{matches, query, total_deferred_tools}` |
| workflow | `{runId, scriptPath, status, summary, taskId, transcriptDir, workflowName}` (+ optional `taskType`) |

(`type:"create"\|"update"` is where the pointer-list's `create` actually lives —
it is `toolUseResult.type`, not a record/block type.)

> **⚠️ Subagent token totals are mirrored into the PARENT transcript.** The
> `Agent` tool's `toolUseResult` carries a **full nested `usage` object** (the
> same 10 keys as `message.usage`, including `iterations` and `cache_creation`)
> plus `totalTokens`, `totalToolUseCount`, and `totalDurationMs`. This means a
> subagent's token/cost totals are **recoverable from the parent `.jsonl`
> alone** — you do not have to open the subagent's own `subagents/agent-*.jsonl`
> to attribute its cost. Engram discards `toolUseResult` entirely (see §5
> coverage gap), so neither the parent-side nor the file-side subagent totals
> are currently captured. Real sample (anonymized): `agentType:"codex:codex-rescue"`,
> `status:"completed"`, `totalTokens:19756`; `usage` keys =
> `[cache_creation, cache_creation_input_tokens, cache_read_input_tokens,
> inference_geo, input_tokens, iterations, output_tokens, server_tool_use,
> service_tier, speed]`.

```json
{ "agentId": "a4e5796f79594d4d0", "agentType": "general-purpose", "status": "completed",
  "prompt": "<dispatched task prompt, redacted>", "content": "<subagent final report, redacted>",
  "totalDurationMs": 412380, "totalTokens": 139887, "totalToolUseCount": 37,
  "toolStats": { "Bash": 12, "Read": 18, "Edit": 7 },
  "resolvedModel": "claude-sonnet-4-6",
  "usage": { "input_tokens": 8849, "output_tokens": 3458, "cache_read_input_tokens": 0,
    "cache_creation_input_tokens": 28933,
    "cache_creation": { "ephemeral_1h_input_tokens": 28933, "ephemeral_5m_input_tokens": 0 },
    "server_tool_use": { "web_search_requests": 0, "web_fetch_requests": 0 },
    "service_tier": "standard", "inference_geo": "not_available",
    "iterations": [ { "input_tokens": 8849, "output_tokens": 3458, "type": "message" } ], "speed": "standard" } }
```

### 7.4 MCP and shell tool shapes

- **MCP tools** appear as `tool_use.name == "mcp__<server>__<tool>"` (e.g.
  `mcp__codegraph__codegraph_search`). Assistant records may also carry
  `attributionMcpServer`/`attributionMcpTool`.
- **Shell** tools are `name == "Bash"` with `input.command` + `input.description`;
  the Bash `toolUseResult` carries `stdout`/`stderr`/`interrupted`.
- **Large tool outputs** spill to `<uuid>/tool-results/<id>.txt` (see §2.6),
  referenced from the transcript rather than inlined.

### 7.5 Engram tool handling

`streamMessages` reclassifies a `user` record whose content has a `tool_result`
to `role:"tool"` (TS `claude-code.ts:232-235`; Swift
`ClaudeCodeAdapter.swift:361-365`). `tool_use` blocks are summarized
(`` `name`: summary ``); the **noise toolset** is dropped entirely:
`ToolSearch, ExitPlanMode, EnterPlanMode, Skill, TodoWrite, TodoRead, TaskCreate,
TaskUpdate, TaskGet, TaskList` (TS `:376-387`; Swift `:434-445`). `tool_result`
content is mostly dropped (kept only when it starts with `"User has answered"`).
`tool_reference` blocks and `text === "Tool loaded."` are filtered as noise.

---

## 8. Reasoning / thinking

Reasoning is stored as a **`thinking` content block** inside assistant
`message.content[]` (§6.3):

| Field | Type | Meaning |
|---|---|---|
| `thinking` | string | the chain-of-thought text (plaintext on disk) |
| `signature` | string (base64) | cryptographic signature authenticating the block to the Anthropic API on replay |

- **`redacted_thinking`** (encrypted thinking, field `data`) is the Anthropic-API
  shape for content the client can't read. It was **not observed as a live block**
  anywhere in this CC 2.1.x corpus.
- There is **no separate "reasoning summary" record** in Claude Code's format —
  the legacy `type:"summary"` record (which would have held a compaction summary
  with `leafUuid`) does not exist in this store; modern compaction uses
  `system/compact_boundary` + an `isCompactSummary` user message (§11).
- **Engram handling:** `thinking` is used only as a **fallback** when a record
  has no `text`/`tool_use`/`tool_result` blocks (TS `extractContent`
  `claude-code.ts:350-370`; Swift `:411-431`). The `signature` is read but
  **discarded**.

---

## 9. Token usage & cost

### 9.1 Where usage lives

Per-`assistant`-record under `message.usage`. Two shapes: a **full** shape and a
**legacy/lean** shape (missing `iterations`, `server_tool_use`, `speed`).

| `usage` field | Type | Meaning | Summed by Engram? | Example |
|---|---|---|:---:|---|
| `input_tokens` | int | uncached prompt tokens | ✅ | `8849` |
| `output_tokens` | int | generated tokens | ✅ | `3458` |
| `cache_read_input_tokens` | int | tokens served from prompt cache | ✅ | `0` |
| `cache_creation_input_tokens` | int | tokens written into the cache this turn | ✅ | `28933` |
| `cache_creation` | object | cache-write split by TTL: `{ephemeral_5m_input_tokens, ephemeral_1h_input_tokens}` | ❌ | `{"ephemeral_1h_input_tokens":28933,"ephemeral_5m_input_tokens":0}` |
| `server_tool_use` | object | `{web_search_requests, web_fetch_requests}` | ❌ | `{"web_search_requests":0,"web_fetch_requests":0}` |
| `service_tier` | string\|null | `"standard"` / `"batch"` / null | ❌ | `"standard"` |
| `inference_geo` | string\|null | inference region marker; on disk takes `"not_available"`, `""` (empty string), `null`, or is **absent** in the lean shape — parsers that branch on it must handle all four | ❌ | `"not_available"` |
| `speed` | string\|null | latency/speed tier | ❌ | `"standard"` |
| `iterations` | array\|null | per-iteration usage breakdown of one agentic request; each element mirrors the top-level token fields + `cache_creation` + `type:"message"` | ❌ | `[{input_tokens, output_tokens, cache_read_input_tokens, cache_creation_input_tokens, cache_creation, type:"message"}]` |

```json
{
  "input_tokens": 8849,
  "cache_creation_input_tokens": 28933,
  "cache_read_input_tokens": 0,
  "output_tokens": 3458,
  "server_tool_use": { "web_search_requests": 0, "web_fetch_requests": 0 },
  "service_tier": "standard",
  "cache_creation": { "ephemeral_1h_input_tokens": 28933, "ephemeral_5m_input_tokens": 0 },
  "inference_geo": "not_available",
  "iterations": [ { "input_tokens": 8849, "output_tokens": 3458, "cache_read_input_tokens": 0,
                    "cache_creation_input_tokens": 28933,
                    "cache_creation": { "ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": 28933 },
                    "type": "message" } ],
  "speed": "standard"
}
```

### 9.2 Accounting rules

- **`<synthetic>` model:** system-injected assistant messages carry
  `model:"<synthetic>"` with an all-zero usage object → 0 cost (no matching
  price).
- **`iterations` double-count risk:** the array repeats the top-level numbers per
  API iteration. Engram sums only the **top-level** fields, so no double count —
  but a future change reading `iterations` would over-count.
- **Per-record model:** subagents frequently run a **different model** than the
  parent (observed parent `claude-opus-4-8`, subagents `claude-sonnet-4-6` /
  `claude-haiku-4-5`). **Cost must be computed per-record from `message.model`**,
  never inherited from the parent session's model.

### 9.3 How Engram sums & prices

**Extraction** — Engram's `TokenUsage` consumes only 4 of the ~10 usage fields:
- TS `streamMessages` (`claude-code.ts:247-256`): `input_tokens`,
  `output_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens`.
- Swift `JSONLAdapterSupport.usage(from:)`, defined at `CodexAdapter.swift:220-228`
  and shared by `ClaudeCodeAdapter` (called at `:371`): same 4 fields. It **drops**
  `cache_creation{}`, `server_tool_use{}`, `service_tier`, `inference_geo`,
  `iterations`, `speed`, plus `stop_details`/`diagnostics`.

**Accumulation** (TS `src/core/indexer.ts`) — per session (or per subagent, keyed
by `agentId`):
```
acc.inputTokens         += usage.inputTokens
acc.outputTokens        += usage.outputTokens
acc.cacheReadTokens     += usage.cacheReadTokens ?? 0
acc.cacheCreationTokens += usage.cacheCreationTokens ?? 0
```
A `session_costs` row is written even at zero tokens; `cost = computeCost(model, …)`.

**Pricing** (`src/core/pricing.ts`): `ModelPrice = {input, output, cacheRead,
cacheWrite}` in USD-per-1M tokens. `getModelPrice` (`pricing.ts:56`) resolves by
(1) custom exact, (2) built-in exact, (3) **longest-prefix** match
(`pricing.ts:66-67`, so `claude-sonnet-4-5-20250929 → claude-sonnet-4-5`), (4)
custom prefix. Unknown model → `undefined` → cost `0`.
```
cost = input/1e6 * price.input
     + output/1e6 * price.output
     + cacheRead/1e6 * price.cacheRead
     + cacheCreation/1e6 * price.cacheWrite   // cacheWrite == cache_creation price
```

| model | input | output | cacheRead | cacheWrite | pricing.ts line |
|---|---|---|---|---|---|
| claude-opus-4-6 | 15 | 75 | 1.5 | 18.75 | `:9` |
| claude-sonnet-4-6 | 3 | 15 | 0.3 | 3.75 | `:15` |
| claude-sonnet-4-5 | 3 | 15 | 0.3 | 3.75 | `:21` |
| claude-haiku-4-5 | 0.8 | 4 | 0.08 | 1 | `:27` |

> **⚠️ Pricing staleness (verified — affects THREE current models, not one).**
> `getModelPrice` resolves by exact key then **longest-prefix** match; any model
> whose exact-or-longest-prefix key is **absent** from `pricing.ts` falls through
> to `undefined` → **cost `0`**. `pricing.ts` currently has only
> `claude-opus-4-6`, `claude-sonnet-4-6`, `claude-sonnet-4-5`,
> `claude-haiku-4-5`. The user's **actual on-disk model set** (census across the
> `engram`/`glm-coding`/`polycli`/`mediahub` stores) is:
>
> | model on disk | records | in pricing.ts? | prices at |
> |---|---:|---|---|
> | `claude-opus-4-8` | 21541 | **no** (no prefix match — `opus-4-6` ≠ `opus-4-8`) | **$0** |
> | `claude-opus-4-7` | 2070 | **no** (no prefix match) | **$0** |
> | `claude-fable-5` | 156 | **no** (no prefix match) | **$0** |
> | `<synthetic>` | 52 | n/a (all-zero usage) | $0 (correct) |
>
> So **`claude-opus-4-8`, `claude-opus-4-7`, AND `claude-fable-5` all price at
> $0** under the current table — a real cost-undercount across the user's three
> active production models, not just the primary one. Note the historical
> `claude-sonnet-4-6` / `claude-haiku-4-5` (used by some subagents) **do**
> resolve and are priced correctly; the gap is specifically the `opus-4-7`,
> `opus-4-8`, and `fable-5` generations.

> **Note on `claude-usage-probe.ts`.** This file is **NOT** the per-message token
> extractor — it is a live quota probe (`ClaudeUsageProbe`) that reads
> `~/.claude/usage.json` if present, else runs `claude /usage` in a headless tmux
> and scrapes `… : NN%` lines into `UsageSnapshot` metrics
> (`claude-usage-probe.ts:18-157`). In this store `~/.claude/usage.json` does not
> exist, so it would fall through to the tmux probe. Per-message token math lives
> in the adapters + `indexer.ts` + `pricing.ts`.

---

## 10. Subagent / parent-child / dispatch

### 10.1 The dispatch record (parent transcript)

A subagent is spawned by an `assistant` record containing a `tool_use` content
block named **`Agent`** (current 2.1.x; legacy name `Task`).

> **Naming correction.** The dispatch tool is **`Agent`**, not `Task`. The
> `Task*` strings (`TaskCreate`, `TaskList`, `TaskGet`, `TaskUpdate`, `TaskStop`,
> `TaskOutput`) are the **background-task/todo MCP toolset**, unrelated to
> subagents. (Both adapters' `summarizeToolInput` handle `name == "Agent"` →
> `input.description`: TS `claude-code.ts:458`; Swift `:521-522`.)

| `tool_use` field | Type | Meaning | Example |
|---|---|---|---|
| `type` | string | always `"tool_use"` | `"tool_use"` |
| `id` | string (`toolu_…`) | tool-use id; equals the subagent's `meta.json` `toolUseId` | `"toolu_014RWAea4dPmkLdEossEV1ez"` |
| `name` | string | dispatch tool name | `"Agent"` (legacy `"Task"`) |
| `input.description` | string | short task label | `"Privacy data flow audit"` |
| `input.prompt` | string | full task prompt handed to subagent | `"<task instructions…>"` |
| `input.subagent_type` | string | which agent persona to run | `"privacy"`, `"general-purpose"`, `"hallucination"` |
| `input.run_in_background` | bool? | present only for backgrounded subagents | `true` |

```json
{ "type": "assistant",
  "message": { "role": "assistant", "model": "claude-opus-4-8",
    "content": [
      { "type": "text", "text": "<assistant reasoning>" },
      { "type": "tool_use", "id": "toolu_014RWAea4dPmkLdEossEV1ez", "name": "Agent",
        "input": { "description": "Privacy data flow audit", "prompt": "<full subagent prompt — anonymized>",
                   "subagent_type": "privacy" } } ] } }
```

The subagent's final report returns later as a `type:"user"` record whose
`message.content[]` holds a `tool_result` block with the matching `tool_use_id`.

### 10.2 The subagent sidecar metadata (`agent-<id>.meta.json`)

| Field | Type | Meaning | Example |
|---|---|---|---|
| `agentType` | string | the subagent type (mirrors `subagent_type`) | `"i18n"`, `"general-purpose"`, `"codex:codex-rescue"`, `"workflow-subagent"` |
| `description` | string | short human label (mirrors the `Agent` tool `description`) | `"i18n localization audit"` |
| `toolUseId` | string (`toolu_…`) | the spawning `Agent`/`Task` `tool_use.id` in the **parent** transcript | `"toolu_012oNrmxfmS4FUXjp7fefEKN"` |

> **`meta.json` has two shapes.** (1) The **full** `{agentType, description,
> toolUseId}` for direct subagents (some also add `name`, and rarely `worktreePath`
> / `color`/`model`/`permissionMode`/`planModeRequired`/`taskKind`/`teamName`).
> (2) A **minimal `{agentType}`-only** shape for **workflow-nested** subagents
> (`agentType:"workflow-subagent"`), which live under
> `subagents/workflows/wf_*/`. The minimal shape has no `toolUseId`, so the
> dispatch join key below does not apply to workflow-nested subagents.

```json
{"agentType":"i18n","description":"i18n localization audit","toolUseId":"toolu_012oNrmxfmS4FUXjp7fefEKN"}
```
```json
{"agentType":"workflow-subagent"}
```

For the full shape this is the **dispatch ↔ subagent join key**: parent
`tool_use.id` == meta `toolUseId`, and meta lives next to
`agent-<agentId>.jsonl`. Verified chain:
parent `Agent` block `id=toolu_…` → `subagents/agent-<id>.meta.json` (`toolUseId`
matches, `agentType:"privacy"`) → `subagents/agent-<id>.jsonl`.

### 10.3 The subagent transcript (`agent-<id>.jsonl`)

A normal append-only JSONL of `user`/`assistant` records — same shapes as a
top-level session — but every line carries `isSidechain:true` and an `agentId`.

| Subagent-distinguishing field | Type | Meaning |
|---|---|---|
| `agentId` | string (opaque) | equals the filename `agentId`; Engram's **unique DB id** for the subagent. **Usually** 17-char hex (`a784b50f9fbfb258b`), but workflow/provider review subagents use a `<label>-<hex>` form (`akimi-review-…` len 29, `aagy-review-…` len 28) — never assume fixed length or pure hex |
| `isSidechain` | bool | **always `true`** inside subagent files |
| `sessionId` | string | the **parent's** sessionId (shared) |
| `attributionAgent` | string | (assistant records) which persona produced the turn (mirrors `agentType`) |
| `parentUuid` | string\|null | `null` on the first line (a fresh sidechain chain root) |

```json
{"parentUuid":null,"isSidechain":true,"promptId":"d7d35fa2-…","agentId":"a784b50f9fbfb258b","type":"user",
 "message":{"role":"user","content":"<dispatched task prompt — anonymized>"},"sessionId":"477f5790-…",
 "cwd":"<cwd>","gitBranch":"<branch>","version":"2.1.156","userType":"external","entrypoint":"cli",
 "uuid":"<uuid>","timestamp":"<iso8601>"}
```

### 10.4 `isSidechain` semantics

| value | where | meaning |
|---|---|---|
| `false` | top-level session records (incl. `isCompactSummary` user msgs) | main conversation thread |
| `true` | every record inside `subagents/agent-*.jsonl` | subagent/sidechain thread; not part of the main visible transcript |

`isSidechain` is the **runtime** marker, but **Engram does not read it** — it
infers "subagent" purely from the **file path** containing `/subagents/`
(TS `claude-code.ts:143`; Swift `ClaudeCodeAdapter.swift:149`).

### 10.5 Parent linkage derivation (Engram "Layer 1")

Both adapters extract the parent UUID from the path segment **immediately before**
`subagents/` (the directory named after the parent's session). Deterministic, no
heuristics:
- **TS** (`claude-code.ts:151`): regex `/\/([^/]+)\/subagents\/[^/]+\.jsonl$/`.
- **Swift** (`ClaudeCodeAdapter.swift:528-536`, `parentSessionId(from:)`): splits
  on `/`, finds `subagents` index, returns `parts[subagentsIndex - 1]`.

Both set `agentRole:"subagent"` and `parentSessionId = <parent-uuid>`.

> **⚠️ Verified discovery gap (on-disk reality wins).** Both adapters enumerate
> only **direct** children of `subagents/` (TS regex requires
> `subagents/<file>.jsonl`; Swift walks `directChildren(of: subagents)` at
> `:40-43`). Real stores also contain **`subagents/workflows/wf_<id>/agent-*.jsonl`**.
> In one sampled session: **1 direct** vs **14 workflow-nested** subagent files —
> ~93% of that session's subagents **never indexed**. (Swift's
> `parentSessionId(from:)` math *would* handle the nested path, but the file is
> never discovered.) `workflows/<wf>/journal.jsonl` is likewise unindexed.

### 10.6 Subagent tier (always skip)

Engram tiers every subagent (`agentRole != nil`, or path contains `/subagents/`)
as **`skip`** (`SessionTier.swift`): hidden from lists, excluded from keyword
search, embedding-ineligible. Subagent content is accessed through the parent.
This matches the project rule "don't upgrade subagent tier."

---

## 11. Summary / compaction

### 11.1 Modern form (what actually exists, CC 2.1.x)

Two records bracket a compaction:

**(a) `type:"system"`, `subtype:"compact_boundary"`** — the boundary marker
carrying `compactMetadata`:

| top-level field | Type | Meaning | Example |
|---|---|---|---|
| `type` | string | `"system"` | `"system"` |
| `subtype` | string | `"compact_boundary"` | `"compact_boundary"` |
| `level` | string | log level | `"info"` |
| `content` | string | fixed banner text | `"Conversation compacted"` |
| `logicalParentUuid` | string | chain-repair pointer across the boundary | `"<uuid>"` |
| `compactMetadata` | object | compaction telemetry (below) | — |

**`compactMetadata` nested object:**

| Field | Type | Meaning | Example |
|---|---|---|---|
| `trigger` | string | `"manual"` (user `/compact`) or `"auto"` (context-limit) | `"manual"` |
| `preTokens` | int | total tokens **before** compaction | `541747` |
| `postTokens` | int | total tokens **after** compaction | `7961` |
| `durationMs` | int | wall-clock of the compaction op | `118348` |
| `preCompactDiscoveredTools` | string[] | tools available pre-compact (preserved for continuity) | `["Monitor","TaskList","mcp__codegraph__codegraph_search"]` |
| `preservedSegment` | object | `{headUuid, anchorUuid, tailUuid}` — the live tail kept verbatim | — |
| `preservedMessages` | object | `{anchorUuid, uuids:[…], allUuids:[…]}` — kept-visible subset (`uuids`) vs full segment incl. intermediate tool turns (`allUuids`) | — |

```json
{
  "type": "system", "subtype": "compact_boundary", "level": "info",
  "content": "Conversation compacted", "logicalParentUuid": "<uuid>",
  "compactMetadata": {
    "trigger": "manual", "preTokens": 541747, "postTokens": 7961, "durationMs": 118348,
    "preCompactDiscoveredTools": ["Monitor","TaskList","mcp__codegraph__codegraph_search"],
    "preservedSegment": {"headUuid":"<u1>","anchorUuid":"<u2>","tailUuid":"<u3>"},
    "preservedMessages": {"anchorUuid":"<u2>","uuids":["<u1>","<u2>","<u3>"],"allUuids":["<u1>","…","<u3>"]}
  },
  "sessionId": "<uuid>", "version": "2.1.156", "uuid": "<uuid>", "timestamp": "<iso8601>"
}
```

**(b) `type:"user"`, `isCompactSummary:true`** — the synthetic summary that
becomes the new conversation head:

| Field | Type | Meaning |
|---|---|---|
| `type` | `"user"` | masquerades as a user turn |
| `isCompactSummary` | bool `true` | flags this user turn as the synthesized summary |
| `isVisibleInTranscriptOnly` | bool | shown in transcript, excluded from API context |
| `uuid` | uuid | equals `compactMetadata.preservedSegment.anchorUuid` |
| `parentUuid` | uuid | points back into **pre-compact** history (chain stays intact) |
| `message.content` | string | the LLM-generated summary text (~13 KB observed) |
| `compactMetadata` | null | **null on this record** (lives on the system record) |

```json
{ "type": "user", "uuid": "659dea2b-…", "parentUuid": "2cdf8b72-…",
  "isCompactSummary": true, "isVisibleInTranscriptOnly": true,
  "message": { "role": "user", "content": "…generated summary…" } }
```

### 11.2 How sessions continue across compaction

Compaction **prunes the model's context window, not the on-disk record stream**.
The pre-compact records remain in the same file *above* the summary; `parentUuid`
continuity (and `logicalParentUuid` on the system record) keeps the chain
traceable. The conversation keeps appending to the same `<session-uuid>.jsonl`.

Store stats (146 files): `isCompactSummary` in 28 files, `compactMetadata` in 27,
triggers 33 manual / 1 auto.

### 11.3 Legacy form (documented, absent here)

The pointer-described record `{"type":"summary","summary":"…","leafUuid":"<uuid>"}`
is the older Claude Code compaction artifact (`leafUuid` = the last real message
the summary replaces). **Zero occurrences** in this store. Listed in both
adapters' skip comments (`claude-code.ts:23`) but never parsed.

### 11.4 Engram blind spot

`MESSAGE_TYPES = {user, assistant}` skips both compaction records for tier logic,
**but** the `isCompactSummary` record is `type:"user"`, so it **is** counted as a
user message — and if it's the first user line its ~13 KB content can become
`firstUserText`/`summary`. The `system/compact_boundary` record (and its rich
`preTokens`/`postTokens` telemetry) is **never indexed** — Engram has no notion of
compaction events or token-savings.

---

## 12. SQLite stores — N/A for Claude Code

**Claude Code has no SQLite session store.** Its entire on-disk format is
append-only JSONL files + JSON sidecars (this whole document). There is no
per-session, rollout-vs-DB, or active/legacy DB architecture to describe.

(This section exists because the doc outline reserves it for the Codex format,
which *does* use SQLite. For Claude Code it is explicitly not applicable.)

---

## 13. Auxiliary files

Files outside the per-session transcript, some inside `projects/`, some global.

### 13.1 `sessions-index.json` (per-project sidecar)

A pre-computed catalog for the `/resume` picker. **Rare** (found in only 2 of
~80 project dirs) and **not garbage-collected** (stale `fullPath` entries persist
after the `.jsonl` is deleted). **Neither adapter reads it** — they walk the
directory and read each record's authoritative fields directly.

Top-level: `{version:int, entries:[…]}`. Per-entry:

| Field | Type | Meaning | Example |
|---|---|---|---|
| `sessionId` | string (uuid) | Session UUID | `6d45d1e7-…` |
| `fullPath` | string | Absolute path to the `.jsonl` | `/Users/…/projects/-/6d45d1e7-….jsonl` |
| `fileMtime` | int (epoch ms) | File mtime at index time | `1771494977955` |
| `firstPrompt` | string | First user prompt, truncated (~200 chars) | `"<first prompt>"` |
| `messageCount` | int | Message count snapshot | `2` |
| `created` | string (ISO 8601) | Session create time | `2026-02-19T09:53:20.037Z` |
| `modified` | string (ISO 8601) | Last modified time | `2026-02-19T09:56:17.931Z` |
| `gitBranch` | string | Git branch (may be `""`) | `""` |
| `projectPath` | string | The real cwd / project path | `/Users/bing/lobsterai/project` |
| `isSidechain` | bool | Whether session is a sidechain | `false` |

```json
{ "version": 1, "entries": [
  { "sessionId": "<uuid>", "fullPath": "/Users/.../projects/-/<uuid>.jsonl",
    "fileMtime": 1771494977955, "firstPrompt": "<first user prompt, truncated>",
    "messageCount": 2, "created": "2026-02-19T09:53:20.037Z", "modified": "2026-02-19T09:56:17.931Z",
    "gitBranch": "", "projectPath": "/", "isSidechain": false } ] }
```

### 13.2 `~/.claude/history.jsonl` (global cross-project prompt history)

One JSON object per line, append-only, **NOT** per-session — it backs the prompt
history/recall. **Verified shape** (corrects an earlier research-pass guess):

| Field | Type | Meaning | Example |
|---|---|---|---|
| `display` | string | The prompt text as typed (incl. slash commands) | `"/ljg-explain-words Serendipity"` |
| `pastedContents` | object | Map of pasted attachments for that prompt (usually `{}`) | `{}` |
| `timestamp` | int (epoch ms) | When the prompt was entered | `1765606729001` |
| `project` | string | The real project cwd | `/Users/bing/-Code-/TSLin` |
| `sessionId` | string (uuid) | Session the prompt belonged to | `118235ea-…` |

```json
{"display":"<prompt text>","pastedContents":{},"timestamp":1765606729001,
 "project":"/Users/bing/-Code-/TSLin","sessionId":"118235ea-9fd6-459a-a3af-4584f16ec4de"}
```

Not consumed by Engram.

### 13.3 `~/.claude/sessions/<pid>.json` (live process registry)

One file per running CLI process, **rewritten in place** as status changes (unlike
the append-only transcripts). Maps a running pid → its active `sessionId`.

| Field | Type | Example |
|---|---|---|
| `pid` | int | `11844` |
| `sessionId` | string (uuid) | `45031c3c-…` |
| `cwd` | string | `/Users/bing/-Code-/AI-Panel` |
| `startedAt` | int (epoch ms) | `1781927597951` |
| `procStart` | string | `"Sat Jun 20 03:53:16 2026"` |
| `version` | string | `"2.1.183"` |
| `peerProtocol` | int | `1` |
| `kind` | string | `"interactive"` |
| `entrypoint` | string | `"cli"` |
| `status` | string | `"busy"` / `"idle"` |
| `updatedAt` / `statusUpdatedAt` | int (epoch ms) | `1782032951209` |

```json
{"pid":11844,"sessionId":"45031c3c-…","cwd":"/Users/bing/-Code-/AI-Panel",
 "startedAt":1781927597951,"procStart":"Sat Jun 20 03:53:16 2026","version":"2.1.183",
 "peerProtocol":1,"kind":"interactive","entrypoint":"cli","status":"busy",
 "updatedAt":1782032951209,"statusUpdatedAt":1782032951209}
```

### 13.4 `~/.claude/file-history/<session-uuid>/<hash>@v<N>` (edit checkpoints)

The on-disk backup blobs referenced by `file-history-snapshot` records. Each is a
saved copy of an edited file's contents; versions accumulate (`…@v1`, `…@v2`, …)
so `/rewind` to a chosen `messageId` can restore exact prior contents. Verified:
`~/.claude/file-history/<uuid>/0de06013ce58c98e@v1`, `632a9a22ce19124f@v1`,
`632a9a22ce19124f@v2`. The `file-history-snapshot` record carries:

The `file-history-snapshot` record's **only** keys are `{type, messageId,
isSnapshotUpdate, snapshot}` — note there is **no `sessionId`** (unlike every
other side-channel record). It is tied to its session purely by which `.jsonl`
file it lives in, and to a specific message by `messageId` (see §5).

| Field | Type | Meaning |
|---|---|---|
| `type` | string | `"file-history-snapshot"` |
| `messageId` | uuid | the message this snapshot anchors to |
| `isSnapshotUpdate` | bool | `false`=initial, `true`=incremental |
| `snapshot.messageId` | uuid | mirror of `messageId` |
| `snapshot.timestamp` | ISO8601 | when taken |
| `snapshot.trackedFileBackups` | object | map `<abs file path>` → `{backupFileName, version, backupTime}`; **`{}` when no files edited at this boundary** |

```json
{ "type": "file-history-snapshot", "isSnapshotUpdate": false, "messageId": "<uuid>",
  "snapshot": { "messageId": "<uuid>", "timestamp": "…",
    "trackedFileBackups": { "<abs file>": { "backupFileName": "e584466a73198722@v1",
                                            "version": 1, "backupTime": "2026-06-19T05:39:03.729Z" } } } }
```

### 13.5 `~/.claude/usage.json` (quota snapshot — optional)

Read by `ClaudeUsageProbe` when present (variable shape: numbers or
`{percent, resetAt}` objects). **Absent in this store** — the probe falls through
to a `claude /usage` tmux scrape (§9.3).

---

## 14. Engram mapping

How Engram's adapters actually consume the format. Both adapters are intentional
byte-for-byte parity; line numbers cite the file where the behavior lives.

| Source record / field | Engram Session field / behavior | TS (`src/adapters/claude-code.ts`) | Swift (`…/ClaudeCodeAdapter.swift`) |
|---|---|---|---|
| `projects/<dir>/*.jsonl` | session locator (file path) | `listSessionFiles` `:41-73` | `listSessionLocators` `:27-48` |
| `<uuid>/subagents/*.jsonl` | session locator (subagent) | `:51-63` | `:38-44` |
| `type ∈ {user, assistant}` | message-bearing gate; all else skipped | `MESSAGE_TYPES` `:26,:98` | inline `:100-104` |
| `sessionId` field | `SessionInfo.id` (parent); captured before type filter | `:97` | `:106-108` |
| `agentId` field (subagent) | `SessionInfo.id` (overrides sessionId for subagents) | `:100,:145` | `:109-111,:150` |
| segment before `/subagents/` | `parentSessionId` | regex `:151` | `parentSessionId(from:)` `:528-536` |
| path contains `/subagents/` | `agentRole = "subagent"` | `:143,:171` | `:149,:172` |
| `cwd` field (NOT the dir name) | `SessionInfo.cwd`; `project = basename(cwd)` | `:101,:161,:193-197` | `:112-114,:161,:206-210` |
| `message.model` | `SessionInfo.model` → `detectSource` (`claude-code`/`minimax`/`lobsterai`) | `:106-108,:180-191` | `:123-125,:212-223` |
| `message.usage.input_tokens` | `TokenUsage.inputTokens` | `:248` | `usage()` `CodexAdapter.swift:223` |
| `message.usage.output_tokens` | `TokenUsage.outputTokens` | `:249` | `CodexAdapter.swift:224` |
| `message.usage.cache_read_input_tokens` | `TokenUsage.cacheReadTokens` | `:250-252` | `CodexAdapter.swift:225` |
| `message.usage.cache_creation_input_tokens` | `TokenUsage.cacheCreationTokens` | `:253-255` | `CodexAdapter.swift:226` |
| `message.content[]` `text` | primary message content | `extractContent` `:347-349` | `:407-410` |
| `message.content[]` `thinking` | fallback content only; `signature` discarded | `:350-351,:370` | `:411-413,:431` |
| `message.content[]` `tool_use` | summarized `` `name`: summary ``; noise tools dropped | `formatToolUse` `:389-403` | `:461-472` |
| `tool_use.input` (Read/Write/Edit/Bash/Glob/Grep/Agent) | per-tool summary | `summarizeToolInput` `:448-460` | `:513-526` |
| `tool_use.name == "AskUserQuestion"` | formatted Q/A block | `formatAskUserQuestion` `:405-425` | `:474-493` |
| `message.content[]` `tool_result` | mostly dropped; kept only if `"User has answered…"` | `formatToolResult` `:427-446` | `:495-511` |
| `user` record w/ `tool_result` content | reclassified `role = "tool"`, counted as `toolMessageCount` | `isToolResult` `:333-338`, `:232-235` | `:387-392`, `:361-365` |
| `message.content[]` `image` | rendered `[Image: <media_type>, ~N KB]` | `:357-365` | `:420-425` |
| `message.content` as string | passed through verbatim | `:341` | `:395` |
| first non-injection user text | `summary = firstUserText.slice(0,200)` | `:121-123,:168` | `:142,:168` |
| `isSystemInjection(text)` user records | counted as `systemMessageCount`, not user | `:279-291` | `isSystemInjection` `:375-385` |
| `timestamp` field | `startTime` (first) / `endTime` (last); falls back to file mtime | `:102-103,:139-141` | `:115-120,:159` |
| file size / mtime | `sizeBytes`; mtime = start-time fallback | `:170` | `:170` |
| `NOISE_TOOLS` (ToolSearch/Skill/Todo*/Task*/…) | dropped from rendered content | `:376-387` | `noiseTools` `:434-445` |
| dir-name `decodeCwd` | display/fallback only — **never trusted** for cwd/project | `:302-307` | `:340-345` |

**Fields/records Engram does NOT consume** (full skip list, for completeness):
`uuid`, `parentUuid`, `requestId`, `promptId`, `slug`, `origin`, `promptSource`,
`permissionMode`, `sourceToolAssistantUUID`, `toolUseResult`, `attribution*`,
`isCompactSummary`, `isVisibleInTranscriptOnly`, `diagnostics`, `stop_*`,
`tool_use.caller`, thinking `signature`, all 24 `attachment.type` subtypes, all 10
`system.subtype` variants, all 9 side-channel record types
(`last-prompt`/`ai-title`/`mode`/`permission-mode`/`queue-operation`/
`file-history-snapshot`/`pr-link`/`bridge-session`/`agent-name`), and the usage
fields `cache_creation{}`/`server_tool_use{}`/`service_tier`/`inference_geo`/
`iterations`/`speed`. The `.meta.json`, `journal.jsonl`, `sessions-index.json`,
`history.jsonl`, `sessions/`, and `file-history/` aux files are also unread.

> `claude-usage-probe.ts` is a separate quota probe (`UsageProbe`), not a session
> adapter — see §9.3 / §13.5.

---

## 15. Gotchas, version drift & edge cases

1. **Three `type` layers.** Top-level record `type` ≠ `message.content[].type` ≠
   `attachment.type` ≠ `system.subtype`. The pointer list mixed them; see §1/§4.
   `direct` = `tool_use.caller.type`; `create` = `toolUseResult.type`; `message` =
   `message.type` (always literal `"message"`).
2. **`summary` top-level type does not exist** in this store (0 files). Modern
   compaction uses `system/compact_boundary` + `isCompactSummary` user record.
   The legacy `{type:summary, summary, leafUuid}` shape is documented from adapter
   comments only; capture from a pre-2.1 archive to confirm field schema.
3. **`Agent` not `Task`.** Subagent dispatch tool is `Agent`. `Task*` are the
   background-task MCP toolset. Rename boundary version not pinned (no `Task`
   dispatch observed on disk here).
4. **Workflow-nested subagents are unindexed.** `subagents/workflows/wf_*/agent-*.jsonl`
   (and their `journal.jsonl`) are never discovered by either adapter — observed
   ~93% of one session's subagents missed. Intentional scope vs latent bug
   unresolved.
5. **Three current models price at $0.** Any model with no exact-or-longest-prefix
   key in `pricing.ts` resolves to `undefined` → cost `0`. On disk that is
   **`claude-opus-4-8` (21541 records), `claude-opus-4-7` (2070), AND
   `claude-fable-5` (156)** — none prefix-match the existing
   `opus-4-6`/`sonnet-4-6`/`sonnet-4-5`/`haiku-4-5` entries. Real cost-undercount
   across all three active production models, not just the primary one (see §9.3).
   Swift product cost-computation path not fully traced this pass.
6. **`decodeCwd` is lossy and wrong for `-`/`.`-containing paths.** It models
   neither `.` → `-` nor the segment boundary. Engram sidesteps it by reading the
   in-record `cwd`. Do not use `decodeCwd` output as a real path.
7. **`tool_result.content` is polymorphic** (string ~99%, array for
   image/tool_reference/text). Consumers expecting pure strings will break on the
   array case; both adapters handle both.
8. **`usage` has two shapes.** Lean (older) lacks `iterations`/`server_tool_use`/
   `speed`. `iterations` duplicates top-level numbers — sum only top-level.
9. **`<synthetic>` model** → all-zero usage → 0 cost; these are client-generated /
   error / injected assistant turns.
10. **`userType:"ant"`** marks internal Anthropic builds; `"external"` is normal.
11. **Side-channel records re-appended every turn.** `mode`/`last-prompt`/
    `permission-mode`/`ai-title` cluster repeatedly; **last occurrence wins**.
    A file with only side-channel records (no `user`/`assistant`) yields
    `null`/`.malformedJSON` (Engram skips it).
12. **`sessions-index.json` is rare & stale.** Not GC'd; re-stat every `fullPath`
    before trusting it. Engram ignores it entirely.
13. **`history.jsonl` shape** is `{display, pastedContents, timestamp, project,
    sessionId}` — a prompt-recall log keyed by epoch-ms `timestamp`, NOT the
    `{firstPrompt,…}` shape one research pass guessed (corrected here).
14. **Newer-version fields** (`slug` per-record, `pendingWorkflowCount` on
    `turn_duration`, `attributionPlugin`, `origin.kind:"coordinator"`) appear only
    in later 2.1.x; `deferred_tools_delta.pendingMcpServers` was dropped in later
    builds. Adapters are forward-safe because they gate on the `{user,assistant}`
    allowlist, not a closed type list.
15. **`bridge-session.lastSequenceNum`** was `0` (resp. small ints) in samples;
    whether it is a true high-water sync counter vs placeholder is unconfirmed.
16. **`compactMetadata.preservedMessages.uuids` vs `allUuids`** (visible-kept
    subset vs full segment incl. intermediate tool turns) is inferred from set
    membership, not confirmed against CC source.

### Still uncertain (open questions)
- Exact `{type:"summary", summary, leafUuid}` field schema (need pre-2.1 archive).
- Whether auto-compaction (`trigger:"auto"`) differs in any field beyond the
  trigger value (only 1 auto sample seen).
- The precise `Task` → `Agent` rename version boundary.
- Whether the workflow-nested-subagent skip is intentional scope or a bug; the
  `workflows/<wf>/journal.jsonl` full schema beyond `{started,result,key,agentId}`.
- Swift product-side cost computation location and whether a custom-pricing
  override covers `claude-opus-4-8`.
- Identity of the third-party plugin owning `memory/`/`MEMORY.md`/`memory.bak.*`.
- Populated shapes of `stop_details`, `container`, `context_management` (always
  null/near-absent here).
- Whether `caller.type` ever takes a value other than `direct` (100% in corpus).

---

## 16. Appendix: real anonymized line samples

One fenced block per record/payload type. Every key preserved; values redacted.

### 16.1 `assistant` record (full envelope + message + usage + thinking)
```json
{
  "parentUuid": "22222222-2222-2222-2222-222222222222",
  "isSidechain": false,
  "message": {
    "model": "claude-opus-4-8", "id": "msg_018…", "type": "message", "role": "assistant",
    "content": [ { "type": "thinking", "thinking": "<reasoning text, redacted>", "signature": "<base64 sig, redacted>" } ],
    "stop_reason": "tool_use", "stop_sequence": null, "stop_details": null,
    "usage": {
      "input_tokens": 11691, "cache_creation_input_tokens": 11417, "cache_read_input_tokens": 15964,
      "output_tokens": 3717, "server_tool_use": { "web_search_requests": 0, "web_fetch_requests": 0 },
      "service_tier": "standard",
      "cache_creation": { "ephemeral_1h_input_tokens": 11417, "ephemeral_5m_input_tokens": 0 },
      "inference_geo": "not_available",
      "iterations": [ { "input_tokens": 11691, "output_tokens": 3717, "type": "message" } ],
      "speed": "standard"
    },
    "diagnostics": null
  },
  "requestId": "req_011C…", "type": "assistant", "uuid": "11111111-1111-1111-1111-111111111111",
  "timestamp": "2026-06-19T04:58:18.524Z", "userType": "external", "entrypoint": "cli",
  "cwd": "/Users/bing/-Code-/polycli", "sessionId": "00000000-0000-0000-0000-000000000000",
  "version": "2.1.183", "gitBranch": "main"
}
```

### 16.2 `user` record — human-typed prompt (string content)
```json
{
  "parentUuid": "22222222-2222-2222-2222-222222222222", "isSidechain": false, "promptId": "prompt_<uuid>",
  "type": "user", "message": { "role": "user", "content": "<user typed prompt, redacted>" },
  "origin": { "kind": "human" }, "promptSource": "typed",
  "uuid": "44444444-4444-4444-4444-444444444444", "timestamp": "2026-06-21T00:00:00.000Z",
  "userType": "external", "entrypoint": "cli", "cwd": "/Users/bing/-Code-/polycli",
  "sessionId": "00000000-0000-0000-0000-000000000000", "version": "2.1.183", "gitBranch": "main"
}
```

### 16.3 `user` record — tool_result (the tool-message pattern)
```json
{
  "parentUuid": "11111111-1111-1111-1111-111111111111", "isSidechain": false, "promptId": "prompt_<uuid>",
  "type": "user",
  "message": { "role": "user", "content": [ { "tool_use_id": "toolu_01…", "type": "tool_result", "content": "<str>", "is_error": false } ] },
  "uuid": "33333333-3333-3333-3333-333333333333", "timestamp": "2026-06-19T04:58:24.384Z",
  "toolUseResult": { "stdout": "<str>", "stderr": "", "interrupted": false, "isImage": false, "noOutputExpected": false },
  "sourceToolAssistantUUID": "11111111-1111-1111-1111-111111111111",
  "userType": "external", "entrypoint": "cli", "cwd": "/Users/bing/-Code-/polycli",
  "sessionId": "00000000-0000-0000-0000-000000000000", "version": "2.1.183", "gitBranch": "main"
}
```

### 16.4 `attachment` record — `hook_success`
```json
{
  "parentUuid": null, "isSidechain": false,
  "attachment": { "type": "hook_success", "hookName": "SessionStart:startup", "hookEvent": "SessionStart",
    "toolUseID": "<str>", "command": "<str>", "content": "", "stdout": "<str>", "stderr": "", "exitCode": 0, "durationMs": 149 },
  "type": "attachment", "uuid": "<str>", "timestamp": "2026-06-19T04:57:04.019Z",
  "userType": "external", "entrypoint": "cli", "cwd": "/Users/bing/-Code-/polycli",
  "sessionId": "<str>", "version": "2.1.183", "gitBranch": "main"
}
```

### 16.5 `attachment` record — `task_reminder` (empty)
```json
{ "type": "attachment", "uuid": "<uuid>", "parentUuid": "<uuid>", "sessionId": "<uuid>",
  "timestamp": "…", "cwd": "<abs>", "gitBranch": "main", "version": "2.1.183", "userType": "external",
  "entrypoint": "cli", "isSidechain": false, "attachment": { "type": "task_reminder", "content": [], "itemCount": 0 } }
```

### 16.6 `system` record — `compact_boundary`
```json
{ "type": "system", "subtype": "compact_boundary", "uuid": "<uuid>", "parentUuid": "<uuid>",
  "logicalParentUuid": "<uuid>", "sessionId": "<uuid>", "timestamp": "…", "cwd": "<abs>",
  "gitBranch": "main", "version": "…", "userType": "external", "entrypoint": "cli",
  "isSidechain": false, "isMeta": true, "level": "info", "content": "Conversation compacted",
  "compactMetadata": { "trigger": "manual", "preTokens": 641256, "postTokens": 13530, "durationMs": 101238,
    "preCompactDiscoveredTools": ["WebFetch","WebSearch"],
    "preservedSegment": { "headUuid": "<uuid>", "anchorUuid": "<uuid>", "tailUuid": "<uuid>" },
    "preservedMessages": { "anchorUuid": "<uuid>", "uuids": ["<uuid>"], "allUuids": ["<uuid>"] } } }
```

### 16.7 `user` record — `isCompactSummary`
```json
{ "type": "user", "uuid": "659dea2b-9e92-4f43-9547-f0c9a9867bc8", "parentUuid": "2cdf8b72-6a75-4a4d-b522-4c57eae69ea4",
  "isCompactSummary": true, "isVisibleInTranscriptOnly": true,
  "message": { "role": "user", "content": "…generated summary…" } }
```

### 16.8 `assistant` record — `Agent` dispatch (subagent spawn)
```json
{ "type": "assistant",
  "message": { "role": "assistant", "model": "claude-opus-4-8",
    "content": [ { "type": "text", "text": "<assistant reasoning>" },
      { "type": "tool_use", "id": "toolu_014RWAea4dPmkLdEossEV1ez", "name": "Agent",
        "input": { "description": "Privacy data flow audit", "prompt": "<full subagent prompt — anonymized>", "subagent_type": "privacy" },
        "caller": { "type": "direct" } } ] } }
```

### 16.9 Subagent transcript first line (`subagents/agent-<id>.jsonl`)
```json
{ "parentUuid": null, "isSidechain": true, "promptId": "d7d35fa2-…", "agentId": "a784b50f9fbfb258b",
  "type": "user", "message": { "role": "user", "content": "<dispatched task prompt — anonymized>" },
  "sessionId": "477f5790-…", "cwd": "<cwd>", "gitBranch": "<branch>", "version": "2.1.156",
  "userType": "external", "entrypoint": "cli", "uuid": "<uuid>", "timestamp": "<iso8601>" }
```

### 16.10 Subagent sidecar (`subagents/agent-<id>.meta.json`)
```json
{ "agentType": "i18n", "description": "i18n localization audit", "toolUseId": "toolu_012oNrmxfmS4FUXjp7fefEKN" }
```
Minimal shape — workflow-nested subagents under `subagents/workflows/wf_*/`
(no `description`, no `toolUseId`):
```json
{ "agentType": "workflow-subagent" }
```

### 16.11 `file-history-snapshot` record
```json
{ "type": "file-history-snapshot", "messageId": "ce6eaa53-88fa-4444-81dc-ab9fae319eb9", "isSnapshotUpdate": false,
  "snapshot": { "messageId": "ce6eaa53-88fa-4444-81dc-ab9fae319eb9", "timestamp": "2026-05-29T06:29:52.946Z",
    "trackedFileBackups": { "/redacted/abs/path/edited-file.swift": { "backupFileName": "e584466a73198722@v1", "version": 1, "backupTime": "2026-06-19T05:39:03.729Z" } } } }
```

### 16.12 Side-channel records (flat; no uuid/parentUuid)
```json
{"type":"last-prompt","sessionId":"<uuid>","leafUuid":"<uuid>","lastPrompt":"<text|null>"}
{"type":"ai-title","sessionId":"<uuid>","aiTitle":"<title>"}
{"type":"permission-mode","sessionId":"<uuid>","permissionMode":"bypassPermissions"}
{"type":"mode","sessionId":"<uuid>","mode":"normal"}
{"type":"agent-name","sessionId":"<uuid>","agentName":"<name>"}
{"type":"pr-link","sessionId":"<uuid>","timestamp":"…","prNumber":42,"prRepository":"owner/repo","prUrl":"<url>"}
{"type":"bridge-session","sessionId":"<uuid>","bridgeSessionId":"cse_01W9MQGReWS44CBjcm2YqFrL","lastSequenceNum":0}
{"type":"queue-operation","sessionId":"<uuid>","timestamp":"…","operation":"enqueue","content":"<text>"}
{"type":"queue-operation","sessionId":"<uuid>","timestamp":"…","operation":"dequeue"}
```

### 16.13 Workflow journal records (`subagents/workflows/wf_*/journal.jsonl`)
```json
{"type":"started","key":"v2:<sha256>","agentId":"<agentId>"}
{"type":"result","key":"v2:<sha256>","agentId":"<agentId>","result":{ … }}
```

### 16.14 Global `history.jsonl` line
```json
{"display":"<prompt text>","pastedContents":{},"timestamp":1765606729001,"project":"/Users/bing/-Code-/TSLin","sessionId":"118235ea-9fd6-459a-a3af-4584f16ec4de"}
```

### 16.15 Process registry (`~/.claude/sessions/<pid>.json`)
```json
{"pid":11844,"sessionId":"45031c3c-…","cwd":"/Users/bing/-Code-/AI-Panel","startedAt":1781927597951,"procStart":"Sat Jun 20 03:53:16 2026","version":"2.1.183","peerProtocol":1,"kind":"interactive","entrypoint":"cli","status":"busy","updatedAt":1782032951209,"statusUpdatedAt":1782032951209}
```

### 16.16 `sessions-index.json` (per-project sidecar)
```json
{ "version": 1, "entries": [ { "sessionId": "<uuid>", "fullPath": "/Users/.../projects/-/<uuid>.jsonl",
  "fileMtime": 1771494977955, "firstPrompt": "<first user prompt, truncated>", "messageCount": 2,
  "created": "2026-02-19T09:53:20.037Z", "modified": "2026-02-19T09:56:17.931Z",
  "gitBranch": "", "projectPath": "/", "isSidechain": false } ] }
```
