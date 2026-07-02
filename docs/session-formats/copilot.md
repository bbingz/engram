# GitHub Copilot CLI — Session Format Reference

Last researched: 2026-07-02 (Engram provider audit recheck)
Current-state verification: 2026-07-02 (live store + adapter/DB diff)

> **Scope.** This documents the **GitHub Copilot CLI / coding agent**
> (`producer: "copilot-agent"`, `client_name: github/cli`, binary `copilot-agent`),
> which writes one directory per session under `~/.copilot/session-state/`. This is
> **NOT** the VS Code Copilot Chat extension (that stores chat in VS Code's SQLite
> `state.vscdb`, parsed by Engram's `VSCodeAdapter`). Engram's `CopilotAdapter`
> targets **only** the CLI agent. See [§15 Lineage](#15-lineage-gotchas-version-drift--edge-cases)
> for why the brand name is misleading.

---

## Evidence basis

| Basis | Detail |
|---|---|
| **Live on-disk store** | `~/.copilot/session-state/` — **470 session directories** on this machine. **227** carry an `events.jsonl`; all 470 carry `workspace.yaml` + `checkpoints/`. Plus the store-wide `~/.copilot/session-store.db` (5.1 MB SQLite, `schema_version = 4`). Event-type census aggregated over multiple large `events.jsonl` files; one 8643-event session and one 1990-event session (`67b3717b-…`) sampled in depth. |
| **Repo fixtures** | `/Users/bing/-Code-/engram/tests/fixtures/copilot/session-1/` (synthetic, 3-line `events.jsonl` + 4-key `workspace.yaml`); `/Users/bing/-Code-/engram/tests/fixtures/adapter-parity/copilot/success.expected.json` (golden parity). |
| **Adapters (codified knowledge)** | Swift product: `macos/Shared/EngramCore/Adapters/Sources/CopilotAdapter.swift`. TS reference: `src/adapters/copilot.ts`. Tests: `tests/adapters/copilot.test.ts`. |

**Method:** I first read both adapters to learn the authoritative root and storage
tech, then sampled the live store and cross-checked the fixtures. **On conflict,
REAL data wins.** The headline conflict: the live store is vastly richer (~28 event
types, per-message tokens/model/reasoning, rich `workspace.yaml`, a fully-structured
parallel SQLite mirror) than what either adapter consumes (4 event types + a 4-field
token subset). Both adapters parse a strict, lossy subset. No format-level
contradictions found; all discrepancies are coverage gaps, flagged inline.

**Current Engram status:** The 2026-07-02 read-only smoke listed and parsed 227/227
event locators, streamed 20,868 messages (946 user + 19,922 assistant), attached
shutdown usage to 208 assistant messages, and found 0 parser/stream count
mismatches. The live Engram DB has 227 `copilot` rows and 227 `file_index_state`
rows (`ok`, schema v1), with 0 missing current ids and 0 DB-only ids. Field
freshness still lags in 8 rows: 6 summary-only rows retain old YAML quote pairs,
and 2 rows retain older count/end-time snapshots.

---

## 1. Overview & TL;DR

**What.** Each Copilot CLI session is a **directory named by a UUID** containing an
**append-only JSONL event log** (`events.jsonl`), a flat **`workspace.yaml`** metadata
file, and a **Markdown checkpoint store** (`checkpoints/`). Copilot CLI *also*
maintains a parallel store-wide **SQLite mirror** (`~/.copilot/session-store.db`)
with paired turns + structured checkpoints + git refs + FTS5 — but **Engram ignores
the DB entirely** and reads the per-session files.

**Where.** `~/.copilot/session-state/<uuid>/` (default; configurable via adapter
constructor). The SQLite mirror sits one level up at `~/.copilot/session-store.db`.

**How saved.** `events.jsonl` is written **live, append-only** (one JSON object per
line, never rewritten). `workspace.yaml` is a small metadata file that is **rewritten**
as `updated_at` advances. Checkpoints append a new numbered `.md` body + a new
`index.md` table row per checkpoint.

**Mental model.** Copilot CLI is a **JSONL agent-CLI** in the same on-disk *family*
as **OpenAI Codex CLI** (typed `type`+`data`+`timestamp` events, `session.start` /
`session.shutdown` envelope) — NOT the VS Code/Cursor SQLite-`.vscdb` family despite
the shared "Copilot" brand. See [§15](#15-lineage-gotchas-version-drift--edge-cases).

**Engram's view (lossy).** Engram surfaces only `session.start`, `user.message`,
`assistant.message`, and `session.shutdown` (for token totals). All tool I/O, hooks,
subagents, skills, reasoning, compaction, per-message tokens/model, and the SQLite
mirror are **dropped**. On the current 470-dir store Engram surfaces **227 sessions**
(those with a real event log); the 243 events-less dirs (empty checkpoint templates) are
silently skipped.

```
                          ~/.copilot/
                          ├── session-store.db  ← parallel SQLite mirror (Engram IGNORES)
                          │     sessions / turns / checkpoints / session_refs / FTS5
                          └── session-state/
                                └── <uuid>/          ← ONE DIR PER SESSION
   Engram reads ───────────────►  events.jsonl       (PRIMARY: append-only JSONL log)
   Engram reads (metadata) ─────► workspace.yaml      (flat key: value metadata)
   Engram fallback (no events) ─► checkpoints/index.md + NNN-<slug>.md
   Engram IGNORES ──────────────► session.db  files/  research/  rewind-snapshots/  plan.md  inuse.<pid>.lock

   Engram parse priority (per dir):
     1. events.jsonl present?          → parse as JSONL events session   (227/470)
     2. else checkpoints/index.md has  → parse as checkpoint-only session  (0/470 live)
        ≥1 valid table row?
     3. else                           → skip silently                    (243/470)
```

**Evidence basis used:** LIVE store (470 dirs, 227 with events) + repo fixtures
(1 synthetic session + golden parity JSON) + both adapters. Live data is authoritative.

---

## 2. On-disk layout & file naming

| Property | Value | Source |
|---|---|---|
| Root (default) | `~/.copilot/session-state/` | `CopilotAdapter.swift:11`, `copilot.ts:25` |
| Storage tech (what Engram reads) | One **directory per session**, each with append-only **JSONL** (`events.jsonl`) + flat **YAML** (`workspace.yaml`) + **Markdown** checkpoints. **No SQLite/leveldb** in the read path. | adapters |
| Session dir naming | Lowercase **UUID v4** (`8-4-4-4-12` hex), e.g. `00f0af74-c7a0-440c-812a-29bad956c597` | `ls ~/.copilot/session-state/` |
| Permissions | Session dirs `0700`; `events.jsonl`/`workspace.yaml` `0600` (private) | `ls -la` |
| Timestamps | ISO-8601 UTC, ms precision + `Z`, e.g. `2026-06-20T04:00:26.804Z` | `events.jsonl` |
| Session id identity | dir name == `workspace.yaml id:` == `session.start.data.sessionId` | live |

**Naming grammar.**
- Session dir: `<uuid-v4>/`
- Event log: `events.jsonl` (fixed name)
- Metadata: `workspace.yaml` (fixed name)
- Checkpoint index: `checkpoints/index.md` (fixed name)
- Checkpoint body: `checkpoints/NNN-<kebab-slug-of-title>.md` (3-digit zero-padded number + slug, e.g. `001-designing-nvr-playback-feature.md`)
- Pasted files: `files/paste-<epoch-ms>.txt`
- Rewind backups: `rewind-snapshots/backups/<16-hex-hash>-<epoch-ms>`
- Liveness lock: `inuse.<pid>.lock` (content = bare owning PID)

**Per-session child-name frequency** (aggregated across all 470 dirs, verified live):

| Child | Kind | Count / 470 | Engram uses? | Meaning |
|---|---|---|---|---|
| `workspace.yaml` | file | 470 | **Yes** (metadata) | Session metadata: id, cwd, repo, branch, timestamps, summary |
| `checkpoints/` | dir | 470 | **Yes** (fallback + index) | Checkpoint history (`index.md` + numbered `.md` bodies) |
| `files/` | dir | 470 (mostly empty) | No | User-pasted/attached payloads (`paste-<epochms>.txt`) |
| `research/` | dir | 470 (empty observed) | No | Web/research artifacts (empty in this store) |
| `events.jsonl` | file | **227** | **Yes** (primary log) | Append-only event stream — the transcript |
| `session.db` | file | 155 | No | Per-session SQLite: `todos`, `todo_deps`, `inbox_entries` |
| `rewind-snapshots/` | dir | 32 | No | File-edit backups for the "rewind/undo" feature |
| `plan.md` | file | 15 | No | Agent's free-form working plan |
| `inuse.<pid>.lock` | file | transient (4 live) | No | Liveness lock; content = owning PID |
| `.DS_Store` | file | 1 | No | macOS Finder cruft |

**Key fact:** of 470 dirs, only **227 carry `events.jsonl`**. The other **243** have only
an empty `checkpoints/index.md` template (zero data rows) and are **silently skipped**
by Engram (see [§9 discovery](#9-how-engram-discovers--enumerates-sessions)).

**Sibling top-level state under `~/.copilot/` that Engram ignores** (verified live):
`session-store.db` (+`-shm`/`-wal`), `config.json`, `settings.json`, `mcp-config.json`,
`command-history-state.json`, `copilot-instructions.md`, and dirs `ide/`,
`installed-plugins/`, `logs/`, `marketplace-cache/`, `pkg/`, `plugin-data/`.

**Tree example** (anonymized; three real session shapes):

```
~/.copilot/session-state/
├── 00f0af74-...-29bad956c597/        # full events session
│   ├── events.jsonl                  # append-only event log (up to ~38 MB)
│   ├── workspace.yaml                # metadata
│   ├── session.db                    # todos / inbox (SQLite, ~36 KB)
│   ├── checkpoints/
│   │   └── index.md                  # checkpoint table (may be empty)
│   ├── files/                        # (empty here)
│   ├── research/                     # (empty)
│   └── rewind-snapshots/
│       ├── index.json                # {version, snapshots, filePathMap}
│       └── backups/
│           └── 67cc2383df63f241-1780277667725   # <hash>-<epochms> file copy
├── 6b25f406-...-25c61ff0817c/        # checkpoint-rich session
│   ├── events.jsonl
│   ├── workspace.yaml
│   ├── checkpoints/
│   │   ├── index.md                  # 6 numbered rows
│   │   ├── 001-designing-nvr-playback-feature.md
│   │   ├── 002-implementing-nvr-playback-feat.md
│   │   └── ... 006-...
│   └── files/
│       └── paste-1772580434059.txt   # paste-<epochms>.txt
└── 00c41951-...-796ccbb46351/        # SKIPPED: no events.jsonl, empty index.md template
    ├── workspace.yaml                # cwd: /, created_at == updated_at
    ├── checkpoints/index.md          # header only → 0 rows → not enumerated
    ├── files/
    └── research/
```

---

## 3. File lifecycle & generation

| Aspect | Behavior | Evidence |
|---|---|---|
| Per-session | One UUID dir created at session start | dir name == `workspace.yaml id:` |
| Event log | **Append-only JSONL**, written live; never rewritten in place | monotonically increasing timestamps; `eventsFileSizeBytes` in shutdown; multi-MB files |
| `workspace.yaml` | **Rewritten** (small metadata file); `updated_at` advances | `created_at` vs `updated_at` differ |
| Checkpoints | New numbered body `.md` + new `index.md` table row appended per checkpoint; index header constant | `001..006-*.md` increasing |
| Resume | Existing dir reopened; new events appended; `alreadyInUse` / `inuse.<pid>.lock` guard concurrency. A dedicated `session.resume` event records the reopen | `session.resume.data.{resumeTime,eventCount,...}`, lock files |
| Token usage | Finalized only at `session.shutdown` (per-model `modelMetrics`); a running session has no totals | one `session.shutdown` record at EOF |
| Rollover | **None** — no size-based file rotation; `events.jsonl` grows unbounded (38 MB seen) | single file per session |
| Compaction | In-stream `session.compaction_start` / `session.compaction_complete`; compaction ties to a checkpoint (`checkpointNumber`, `checkpointPath`, `summaryContent`) | live events |
| Model switch | Captured in-stream via `session.model_change`; multiple model ids appear in `modelMetrics` | one session had `claude-haiku-4.5`+`claude-opus-4.6`+`claude-sonnet-4.6` |
| Archive / GC | No archival observed; dirs persist (oldest from March). **No *automatic* TTL/cleanup**, but Copilot provides explicit user-invoked retention commands: `/session prune --older-than DAYS`, `/session delete [ID]`, `/session delete-all [--yes]`, `/session cleanup` (local sessions only; synced copies on GitHub.com are separate) ([CLI reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference)) | mtimes span Mar–Jun |
| Storage tech | JSONL + flat YAML + Markdown (read path). SQLite (`session.db`, `session-store.db`) exists but is **not** the read path | live |

**DB vs file.** Two SQLite stores exist (`session.db` per-session, `session-store.db`
store-wide) — see [§12](#12-sqlite--db-internals). Neither is read by Engram; the
filesystem JSONL/YAML/Markdown is the source of truth for the adapter.

---

## 4. Record / line taxonomy (`events.jsonl` event types)

Every line is one JSON object. Current live data has two envelope keysets: the
base 5 keys (`type`, `id`, `parentId`, `timestamp`, `data`) on 111,216 events,
and the same keys plus `agentId` on 14,629 events. The `agentId` envelope appears
on subagent-scoped assistant/tool/hook/skill/error events; Engram ignores it, so
it does not change parsed message counts. Below is the **full event-type
vocabulary** observed live (~28 distinct types; counts from sampled large sessions
to convey relative volume). The **Engram** column marks the 4 types the adapters parse.

| `type` | Engram | `data` layer carries / meaning |
|---|---|---|
| `session.start` | **Yes** (cwd/startTime fallback) | Session boot record: sessionId, version, producer, copilotVersion, startTime, context{cwd[,branch,gitRoot,repository]}, alreadyInUse?, remoteSteerable?, contextTier?, selectedModel?, reasoningEffort? (trailing keys version-variable) |
| `session.shutdown` | **Yes** (token totals) | Final record: modelMetrics (per-model usage), conversation/system/tool token breakdowns, codeChanges, totals |
| `user.message` | **Yes** (`role:user`) | User prompt: content, transformedContent, interactionId, attachments |
| `assistant.message` | **Yes** (`role:assistant`) | Assistant reply chunk: content, messageId, model, outputTokens, toolRequests[], turnId, interactionId, reasoningText?, reasoningOpaque?, encryptedContent?, phase?, parentToolCallId? (subagent-nested) |
| `assistant.turn_start` / `assistant.turn_end` | No | Turn boundaries: turnId, interactionId |
| `tool.execution_start` / `tool.execution_complete` | No | Tool calls: toolCallId, toolName, arguments, result/error, success, model, toolTelemetry, parentToolCallId? |
| `hook.start` / `hook.end` | No | Hook lifecycle: hookInvocationId, hookType, input/success |
| `skill.invoked` | No | Skill invocation: name, path, content (full SKILL.md), description, source, trigger |
| `subagent.started` / `subagent.completed` | No | Dispatched subagent lifecycle: agentName, agentDisplayName, agentDescription, model, durationMs, totalTokens, totalToolCalls, toolCallId |
| `session.model_change` | No | Model switch mid-session: newModel (e.g. `"auto"`) |
| `session.compaction_start` / `session.compaction_complete` | No | Context compaction; complete carries checkpointNumber, checkpointPath, summaryContent, preCompactionTokens, compactionTokensUsed |
| `session.context_changed` | No | Full git context: repository, branch, gitRoot, cwd, baseCommit, headCommit, hostType |
| `session.resume` | No | Reopen: resumeTime, eventCount, selectedModel, reasoningEffort, context, alreadyInUse |
| `session.info` | No | Informational: infoType, message |
| `session.task_complete` | No | success, summary |
| `session.plan_changed` | No | operation |
| `session.mode_changed` | No | newMode, previousMode |
| `session.workspace_file_changed` | No | operation, path |
| `session.error` | No | errorType, message, statusCode, providerCallId, stack |
| `session.warning` | No | warningType, message |
| `system.message` | No | role, content |
| `system.notification` | No | kind{type,...} (discriminated object), content |
| `abort` | No | reason |

> **Coverage gap (flag).** Engram parses **4 of ~28** types. ~85% of events (all tool
> I/O, reasoning, subagents, skills, compaction, hooks, code-change stats, per-message
> tokens) are discarded. Tool calls, results, and reasoning are **NOT** surfaced in
> Engram transcripts for Copilot. See [§14](#14-engram-mapping) data-loss inventory.

---

## 5. Shared envelope / metadata fields

### 5.1 `events.jsonl` line envelope (layer 1)

Verified: 100% of sampled lines carry exactly these 5 keys.

| Field | Type | Meaning | Optional | Example |
|---|---|---|---|---|
| `type` | string | Event discriminator (see [§4](#4-record--line-taxonomy-eventsjsonl-event-types)) | no | `"assistant.message"` |
| `id` | string (uuid) | This event's unique id | no | `"c72d6d32-7036-473a-9bab-662a973560db"` |
| `parentId` | string\|null | Id of the **immediately preceding** event (linear emission chain, NOT a semantic reply pointer); `null` on `session.start` | no (nullable) | `"0ad3552e-06e1-4db5-b613-17396bd709b8"` |
| `timestamp` | string (ISO-8601) | Event time, ms precision, `Z` | no | `"2026-04-05T13:47:43.481Z"` |
| `data` | object | Type-specific payload (layer 2, [§6](#6-message--content-schema)) | no | `{...}` |

**`parentId` semantics (verified).** It forms a *singly-linked list over emission
order* — each event points to the previous event's `id` regardless of type
(`assistant.message` → `assistant.turn_start` → `hook.end` → `hook.start` →
`user.message` → `session.start`). It is **not** a user↔assistant reply pointer. Both
adapters ignore `id` and `parentId` entirely.

### 5.2 `workspace.yaml` metadata (full superset, verified live)

Flat YAML (`key: value`). Both adapters use a **naive line parser** (not a real YAML
parser): Swift `readWorkspace` splits each line on the first `:`, requires the key to
match `^\w+$`, and strips matched outer quotes
(`CopilotAdapter.swift:363-389`); TS `readWorkspace` uses `/^(\w+):\s*(.+)$/` and
also strips matched outer quotes (`copilot.ts:364-378`, `stripYamlQuotes:438-446`).
Both survive colons in ISO timestamps; nested/multi-line YAML would silently drop.
Frequencies are exact counts across all 470 files.

| Key | Freq /470 | Type | Meaning | Engram uses |
|---|---:|---|---|---|
| `id` | 470 | string(uuid) | Session UUID (overrides dir name) | **Yes** → `Session.id` |
| `cwd` | 470 | string(path) | Working dir | **Yes** → `cwd` (fallback: `session.start.context.cwd`) |
| `created_at` | 470 | ISO-8601 | Session start | **Yes** → `startTime` |
| `updated_at` | 470 | ISO-8601 | Last activity | **Yes** → `endTime` seed |
| `summary_count` | 470 | int | # of summaries/compactions | No |
| `git_root` | 224 | string(path) | Repo root | No |
| `branch` | 224 | string | Git branch | No |
| `repository` | 171 | string | `owner/repo` | No |
| `summary` | 159 | string | Pre-baked session summary | **Yes** → `summary` (1st priority) |
| `host_type` | 153 | string | Forge type (e.g. `github`) | No |
| `user_named` | 146 | bool | Was `name` user-set? | No |
| `name` | 138 | string | Display **title** (often AI-generated) | **No** — see [§14](#14-engram-mapping) data loss |
| `client_name` | 19 | string | Client (`github/cli`) | No |
| `remote_steerable` | 3 | bool | Remote-control flag | No |
| `mc_task_id` | 3 | string(uuid) | Mission-control task linkage | No |
| `mc_session_id` | 3 | string(uuid) | Mission-control session linkage | No |
| `mc_last_event_id` | 3 | string(uuid) | Mission-control last-event linkage | No |

> **Correction vs Dim reports.** `summary` is **not** "rare/absent" — it appears in
> **159/470** live files, and Engram prefers it over the first-user-text fallback. In
> the sampled in-depth session, `summary` + `summary_count` were both present.

---

## 6. Message & content schema

`data` is layer 2; nested arrays/objects (e.g. `toolRequests[]`) are layer 3. Below
are the payloads with verified live key sets (anonymized — keys verbatim, values
redacted).

### 6.1 `session.start.data`

| Field | Type | Meaning | Example |
|---|---|---|---|
| `sessionId` | string(uuid) | Session id (mirrors dir name) | `"00f0af74-…"` |
| `version` | int | Event-schema version | `1` |
| `producer` | string | Emitter id | `"copilot-agent"` |
| `copilotVersion` | string | CLI version | `"1.0.65"` |
| `startTime` | string(ISO) | Start time (Engram fallback start) | `"2026-06-20T04:00:25.530Z"` |
| `contextTier` | string\|null | Context window tier. **Optional/version-variable — rare live (4/60 files)** | `null` |
| `alreadyInUse` | bool | Resumed/locked already. **Optional/version-variable (51/60 files; absent in the largest live session)** | `false` |
| `remoteSteerable` | bool | Remote-control enabled. **Optional/version-variable (42/60 files; absent in the largest live session)** | `false` |
| `selectedModel` | string | (newer versions) user-selected model id for the session. **Optional/some-versions (5/60 files)** | `"<model-id>"` |
| `reasoningEffort` | string | (newer versions) reasoning-effort setting. **Optional/some-versions (4/60 files)** | `"<effort>"` |
| `context` | object | Repo context. **Live: shape is version-variable** — current Copilot versions routinely carry the **rich git context inline** (largest live session: `["branch","cwd","gitRoot","repository"]`), while older/minimal versions carry only `{cwd}`. The fuller set (`gitRoot, branch, headCommit, repository, hostType, repositoryHost, baseCommit`) may also arrive via `session.context_changed`. Engram reads only `context.cwd`. | `{"branch":"…","cwd":"<path>","gitRoot":"<path>","repository":"<owner>/<repo>"}` |

```json
// Common current shape (largest live session): rich git context inline,
// NO contextTier/alreadyInUse/remoteSteerable keys
{"type":"session.start","timestamp":"2026-06-20T04:00:25.530Z","id":"<uuid>","parentId":null,
 "data":{"sessionId":"<uuid>","producer":"copilot-agent","version":1,"copilotVersion":"1.0.63",
         "startTime":"2026-06-20T04:00:25.530Z",
         "context":{"branch":"<branch>","cwd":"<path>","gitRoot":"<path>","repository":"<owner>/<repo>"}}}

// Minimal/older shape: only {cwd}, plus the version-variable flags
{"type":"session.start","timestamp":"2026-06-20T04:00:25.530Z","id":"<uuid>","parentId":null,
 "data":{"sessionId":"<uuid>","producer":"copilot-agent","version":1,"copilotVersion":"1.0.63",
         "startTime":"2026-06-20T04:00:25.530Z","contextTier":null,"alreadyInUse":false,
         "remoteSteerable":false,"context":{"cwd":"<path>"}}}
```

### 6.2 `user.message.data`

| Field | Type | Meaning | Optional |
|---|---|---|---|
| `content` | string | User text (**Engram reads this**) | no |
| `transformedContent` | string\|null | Actually-sent prompt with injected `<current_datetime>` / `<system_reminder>` blocks | nullable |
| `interactionId` | string(uuid) | Groups one user→assistant exchange | no |
| `attachments` | array | Attached refs; element = `{displayName, path, type}` | usually `[]` |
| `supportedNativeDocumentMimeTypes` | array | (some versions) supported attachment MIME types | optional |
| `parentAgentTaskId` | string\|null | (some versions) parent agent-task id | optional |

```json
{"type":"user.message","timestamp":"…","id":"<uuid>","parentId":"<uuid>",
 "data":{"content":"<REDACTED>","transformedContent":null,"attachments":[],
         "interactionId":"<uuid>"}}
```

### 6.3 `assistant.message.data` (also the tool-call SOURCE + reasoning carrier)

| Field | Type | Meaning | Optional |
|---|---|---|---|
| `content` | string | Assistant text (**Engram reads this**) | no (often **empty** on tool-only turns) |
| `messageId` | string | Provider message id | no |
| `model` | string | Model for this message (e.g. `gpt-5.5`, `claude-sonnet-4.6`) | present on some versions |
| `interactionId` | string(uuid) | Matches the triggering user.message | no |
| `outputTokens` | int | **Per-message** output token count | no |
| `toolRequests` | array | Tool calls this message issues (layer 3, [§7](#7-tool-calls--results)) | no (may be `[]`) |
| `reasoningText` | string | Chain-of-thought text | **optional** (≈⅓ of messages live: 59/261 sampled) |
| `reasoningOpaque` | string | Opaque/encrypted reasoning blob | optional (co-occurs with `reasoningText`) |
| `requestId` / `serviceRequestId` / `apiCallId` | string | Provider request correlation ids | optional |
| `turnId` | string(uuid) | Links this message to its `assistant.turn_start` (whose `data` = `{interactionId, turnId}`) — groups all chunks of one assistant turn | optional/version-dependent (100% of 1247 assistant.message in live session 00f0af74) |
| `encryptedContent` | string | Opaque encrypted message body; **co-occurs with** plaintext `content` (not a replacement) | optional/version-dependent (874/1247 in 00f0af74) |
| `phase` | string | Streaming phase marker for the turn | optional/version-dependent (134/1247 in 00f0af74) |
| `parentToolCallId` | string | Present when the assistant message is emitted **inside a subagent / nested tool context**; links to the launching tool call | optional/version-dependent (1839/2827 in live subagent-heavy session 51835c08) |

> **All four** (`turnId`, `encryptedContent`, `phase`, `parentToolCallId`) are **dropped by Engram** — the parser reads only `data.content` (`MessageParser.swift:235`, `CopilotAdapter.swift:210-224`). This row set is on-disk completeness only; mapping is unaffected.

```json
{"type":"assistant.message","timestamp":"…","id":"<uuid>","parentId":"<uuid>",
 "data":{"messageId":"<uuid>","model":"claude-sonnet-4.6","content":"<REDACTED>",
         "interactionId":"<uuid>","turnId":"<uuid>","outputTokens":643,"phase":"<REDACTED>",
         "requestId":"<uuid>","serviceRequestId":"<uuid>","apiCallId":"<uuid>",
         "reasoningText":"<REDACTED>","reasoningOpaque":"<REDACTED>","encryptedContent":"<REDACTED>",
         "parentToolCallId":"toolu_…",
         "toolRequests":[{"toolCallId":"toolu_…","name":"…","arguments":{…},"type":"function"}]}}
```

> **Empty-content assistant messages (verified live).** A large fraction — **⅓ to ~½
> depending on session** — of `assistant.message` events have empty `content`
> (tool-call-only turns). One sampled session: of 261 events only 175 had non-empty
> content (86 empty ≈ ⅓). A bigger live session (51835c08) was worse: **1445 empty /
> 2827 total ≈ 51%**. Engram counts **all** as assistant messages → `assistantMessageCount`
> is inflated and the transcript shows blank assistant rows. See [§15](#15-lineage-gotchas-version-drift--edge-cases).

### 6.4 Checkpoint body content (`NNN-<slug>.md`)

Sectioned XML-tagged Markdown with 6 sections (verified live), 1:1 with the SQLite
`checkpoints` columns ([§12](#12-sqlite--db-internals)):

```
<overview> … </overview>
<history> … </history>
<work_done> … </work_done>
<technical_details> … </technical_details>
<important_files> … </important_files>
<next_steps> … </next_steps>
```

When Engram takes the checkpoint fallback, each entry becomes a `role: system` message:
`"Checkpoint N: <title>\n\n<body>"`, body truncated to **4000 chars**
(`CopilotAdapter.swift:5,358`; `copilot.ts:20,353`).

---

## 7. Tool calls & results

> **N/A for Engram's transcript output** — Copilot tool calls are present on disk but
> the adapters **drop them entirely** (`toolMessageCount` hardcoded `0`). Documented
> here for completeness because the on-disk linkage is rich.

The join key is **`toolCallId`** (NOT the envelope `id`). Chain:
`assistant.message.data.toolRequests[].toolCallId` → `tool.execution_start.data.toolCallId`
→ `tool.execution_complete.data.toolCallId`.

### 7.1 `assistant.message.data.toolRequests[]` (layer 3)

| Field | Type | Meaning | Optional |
|---|---|---|---|
| `toolCallId` | string | **Linkage key** (`toolu_…` Anthropic-style or `call_…` OpenAI-style) | no |
| `name` | string | Tool name | no |
| `arguments` | object | Tool args (shape varies by tool) | no |
| `type` | string | Request type (e.g. `"function"`) | no |
| `intentionSummary` | string | Human-readable intent | optional |
| `mcpServerName` | string | MCP server (MCP tools only) | optional |
| `toolTitle` | string | Display title | optional |

### 7.2 `tool.execution_start.data`

| Field | Type | Meaning |
|---|---|---|
| `toolCallId` | string | Links to request |
| `toolName` | string | Tool name |
| `arguments` | object | Resolved args |
| `parentToolCallId` | string | Present for nested/subagent-issued tool calls (verified live) |
| `mcpServerName` / `mcpToolName` | string | MCP tools only |

### 7.3 `tool.execution_complete.data`

| Field | Type | Meaning |
|---|---|---|
| `toolCallId` | string | Links to start/request |
| `success` | bool | Outcome |
| `model` | string | Model that issued it (e.g. `"claude-opus-4.6"`) |
| `interactionId` | string | Exchange id |
| `result` | object\|null | `{content, detailedContent}` (both strings) on success |
| `error` | object | `{code, message}` when `success=false` (replaces `result`) |
| `parentToolCallId` | string | Present for nested tool calls (verified live) |
| `toolTelemetry` | object | `{metrics{responseTokenLimit,resultForLlmLength,resultLength}, properties{command,fileExtension,inputs,options,resolvedPathAgainstCwd,viewType}, restrictedProperties?}` or `{}` |

```json
{"type":"tool.execution_complete","data":{"toolCallId":"toolu_0142…","success":true,
  "model":"claude-opus-4.6","interactionId":"<uuid>",
  "result":{"content":"<REDACTED>","detailedContent":"<REDACTED>"},
  "toolTelemetry":{"metrics":{"responseTokenLimit":0,"resultForLlmLength":0,"resultLength":0},
                   "properties":{"command":"<REDACTED>","viewType":"…"}}}}
```

---

## 8. Reasoning / thinking

**Stored on disk; dropped by Engram.** `assistant.message.data` carries two reasoning
fields (verified live, ≈⅓ of messages):

| Field | Type | Meaning |
|---|---|---|
| `reasoningText` | string | Human-readable chain-of-thought text |
| `reasoningOpaque` | string | Opaque/encrypted reasoning blob (format not decoded; confirmed to be a string co-occurring with `reasoningText`) |

Additionally, `session.shutdown.data.modelMetrics[<model>].usage.reasoningTokens`
records reasoning-token counts per model (live `gpt-5.5`: 179832).

Engram surfaces **neither** the reasoning text nor `reasoningTokens` — `message(from:)`
reads only `data.content` (`CopilotAdapter.swift:210-224`), and the usage mapping has
no `reasoningTokens` slot ([§9 token usage](#9-token-usage--cost)).

---

## 9. Token usage & cost

Token totals are finalized only at `session.shutdown`. Engram sums the per-model
`usage` blocks and bolts the aggregate onto the **last assistant message**.

### 9.1 `session.shutdown.data` (full, verified live)

| Field | Type | Meaning |
|---|---|---|
| `shutdownType` | string | How it ended (e.g. `"routine"`) |
| `sessionStartTime` | int (epoch ms) | Start |
| `currentModel` | string | Last model used |
| `currentTokens` | int | Current context token count |
| `conversationTokens` | int | Conversation token count |
| `systemTokens` | int | System-prompt token count |
| `toolDefinitionsTokens` | int | Tool-definition token count |
| `totalApiDurationMs` | int | Cumulative API time |
| `totalPremiumRequests` | int | Premium request count |
| `totalNanoAiu` | number | (some versions) AIU usage metric |
| `tokenDetails` | object | (some versions) `{input,cache_read,output,cache_write}` each `{tokenCount}` |
| `codeChanges` | object | `{linesAdded:int, linesRemoved:int, filesModified:[paths]}` |
| `modelMetrics` | object | Keyed by **model id** → `{requests:{count,cost}, usage:{…}, totalNanoAiu?, tokenDetails?}` |
| `eventsFileSizeBytes` | int | (some versions) final size of `events.jsonl` |

### 9.2 `modelMetrics[<model>].usage` (the block Engram sums)

| Field | Type | Engram maps to | Swift | TS |
|---|---|---|---|---|
| `inputTokens` | int | `inputTokens` | `CopilotAdapter.swift:254` | `copilot.ts:391` |
| `outputTokens` | int | `outputTokens` | `:255` | `:392` |
| `cacheReadTokens` | int | `cacheReadTokens` | `:256` | `:393` |
| `cacheWriteTokens` | int | `cacheCreationTokens` (**renamed**) | `:257` | `:394-396` |
| `reasoningTokens` | int | **DROPPED** (no field in `TokenUsage`) | — | — |

**Derivation.** Both adapters iterate **all** models in `modelMetrics`, sum the 4
mapped fields, and `mergeUsage`/`shutdownUsage` no-op when all zero
(`CopilotAdapter.swift:261-267`; `copilot.ts:414-422`). The total is attached to the
**last assistant message** (`CopilotAdapter.swift:228-234`; `copilot.ts:184-191`).
Per-message `outputTokens` and per-model splits are **not** preserved — granularity is
one aggregate on the final assistant turn. Verified by `tests/adapters/copilot.test.ts:53-95`.

```json
{"type":"session.shutdown","data":{"shutdownType":"routine","currentModel":"claude-opus-4.6",
  "conversationTokens":60168,"systemTokens":7640,"toolDefinitionsTokens":19409,
  "totalApiDurationMs":560974,"totalPremiumRequests":27,
  "codeChanges":{"linesAdded":67,"linesRemoved":4,"filesModified":["<path1>","<path2>"]},
  "modelMetrics":{
    "claude-opus-4.6":{"requests":{"count":62,"cost":27},
      "usage":{"inputTokens":3749137,"outputTokens":27465,
               "cacheReadTokens":3433631,"cacheWriteTokens":0,"reasoningTokens":179832}},
    "claude-haiku-4.5":{"requests":{…},"usage":{…}},
    "claude-sonnet-4.6":{"requests":{…},"usage":{…}}}}}
```

---

## 10. Subagent / parent-child / dispatch

> **N/A for Engram parent-child detection** — on disk Copilot CLI **does** dispatch
> subagents (`subagent.started` / `subagent.completed` events), but **none** of this
> feeds Engram's agent-grouping. The adapters hardcode `parentSessionId = nil` and
> `suggestedParentId = nil` (`CopilotAdapter.swift:120-121`; TS emits neither). Every
> Copilot CLI session is therefore **top-level** in Engram. There is **no** Gemini-style
> `.engram.json` sidecar and **no** path/originator linkage for Copilot.

On-disk subagent linkage (informational, dropped):

| Event | `data` fields |
|---|---|
| `subagent.started` | `{agentName, agentDisplayName, agentDescription, toolCallId}` |
| `subagent.completed` | `{agentName, agentDisplayName, model, durationMs, totalTokens, totalToolCalls, toolCallId}` |

The `toolCallId` links the subagent to its launching tool call; nested tool calls
inside a subagent carry `parentToolCallId`. The per-session `session.db`
`inbox_entries` table ([§12](#12-sqlite--db-internals)) is the inter-agent message inbox
(`recipient_session_id`, `sender_id`, `sender_type`) — also unused by Engram.

---

## 11. Summary / compaction

Two summary mechanisms exist on disk:

1. **`workspace.yaml summary:`** — a pre-baked session summary (159/470 live). **Engram
   uses this** as the first-priority `summary` (`CopilotAdapter.swift:110`; `copilot.ts:129`),
   falling back to the first 200 chars of the first user message.
2. **In-stream compaction** — `session.compaction_start` / `session.compaction_complete`
   events. `complete.data` = `{checkpointNumber, checkpointPath, summaryContent,
   preCompactionTokens, compactionTokensUsed, preCompactionMessagesLength, requestId,
   success}`, tying a compaction to a checkpoint file. **Engram ignores both events.**
3. **Checkpoints** ([§5/§6.4](#64-checkpoint-body-content-nnn-slugmd)) are structured
   summaries of session state; Engram uses them only as a **fallback** when
   `events.jsonl` is absent (never triggered live — see [§9 discovery](#9-how-engram-discovers--enumerates-sessions)).

`workspace.yaml summary_count` records the number of summaries/compactions (all 470 live
had a value; all sampled were `0`).

---

## 12. SQLite / DB internals

Copilot CLI maintains **two** SQLite stores. **Engram reads neither** — documented for
completeness because they are fully-structured mirrors of the JSONL/Markdown data.

### 12.1 `~/.copilot/session-store.db` — store-wide mirror (`schema_version = 4`)

WAL-mode SQLite (+`-shm`/`-wal`). Live row counts: sessions=140, turns=241,
checkpoints=9, session_refs=27, session_files=0, forge_trajectory_events=0,
dynamic_context_items=0. **Row counts lag the filesystem** (140 sessions vs 470 dirs) —
it is a derived/recent-activity cache, NOT the source of truth.

```sql
CREATE TABLE schema_version (version INTEGER NOT NULL);          -- value = 4

CREATE TABLE sessions (
  id TEXT PRIMARY KEY, cwd TEXT, repository TEXT, host_type TEXT,
  branch TEXT, summary TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now')));

CREATE TABLE turns (                          -- ALREADY-PAIRED user↔assistant transcript
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL REFERENCES sessions(id),
  turn_index INTEGER NOT NULL,
  user_message TEXT, assistant_response TEXT,
  timestamp TEXT DEFAULT (datetime('now')),
  UNIQUE(session_id, turn_index));

CREATE TABLE checkpoints (                     -- structured form of the NNN-<slug>.md section tags
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL REFERENCES sessions(id),
  checkpoint_number INTEGER NOT NULL,
  title TEXT, overview TEXT, history TEXT, work_done TEXT,
  technical_details TEXT, important_files TEXT, next_steps TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  UNIQUE(session_id, checkpoint_number));

CREATE TABLE session_files (                    -- file touched per session/tool (0 rows live)
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL REFERENCES sessions(id),
  file_path TEXT NOT NULL, tool_name TEXT, turn_index INTEGER,
  first_seen_at TEXT DEFAULT (datetime('now')),
  UNIQUE(session_id, file_path));

CREATE TABLE session_refs (                     -- git refs: ref_type observed ∈ {commit, pr}; format also supports 'issue'
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL REFERENCES sessions(id),
  ref_type TEXT NOT NULL, ref_value TEXT NOT NULL, turn_index INTEGER,
  created_at TEXT DEFAULT (datetime('now')),
  UNIQUE(session_id, ref_type, ref_value));

CREATE TABLE forge_trajectory_events (          -- tool trajectory (0 rows live)
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL REFERENCES sessions(id),
  tool_call_id TEXT, turn_index INTEGER, event_type TEXT NOT NULL,
  command TEXT, output TEXT, exit_code INTEGER,
  event_key TEXT, event_value TEXT,
  created_at TEXT DEFAULT (datetime('now')));

CREATE TABLE dynamic_context_items (
  repository TEXT NOT NULL, branch TEXT NOT NULL, src TEXT NOT NULL,
  name TEXT NOT NULL, description TEXT NOT NULL DEFAULT '',
  content TEXT NOT NULL DEFAULT '',
  read_count INTEGER NOT NULL DEFAULT 0, count INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (repository, branch, src, name));

CREATE VIRTUAL TABLE search_index USING fts5(   -- FTS5 over content
  content, session_id UNINDEXED, source_type UNINDEXED, source_id UNINDEXED);
-- + shadow tables search_index_{data,idx,content,docsize,config}
-- Indexes: idx_sessions_repo, idx_sessions_cwd, idx_session_files_path,
--          idx_session_refs_type_value, idx_turns_session, idx_checkpoints_session
```

> The `turns` table is a **cleaner** user↔assistant transcript than `events.jsonl`
> (already paired, no empty tool-only rows), and `checkpoints` columns are the
> structured form of the `.md` section tags. Engram could index this instead of the
> degraded checkpoint-markdown fallback, but currently does not — see
> [§15](#15-lineage-gotchas-version-drift--edge-cases).
>
> **`session_refs.ref_type` domain.** `{commit, pr}` is only what appeared in *this*
> store; the schema also supports an `issue` ref (two independent reverse-engineering
> sources describe `session_refs` as holding commits, PRs, **and** issues linked to the
> session)
> ([jonmagic](https://jonmagic.com/posts/github-copilot-session-search-and-resume-cli/),
> [dfberry](https://dfberry.github.io/2026-04-16-session-storage-decision-guide)).

### 12.2 `~/.copilot/session-state/<uuid>/session.db` — per-session (155 dirs)

The agent's TODO list + inter-agent inbox (verified live schema):

```sql
CREATE TABLE todos (
  id TEXT PRIMARY KEY, title TEXT NOT NULL, description TEXT,
  status TEXT DEFAULT 'pending' CHECK(status IN ('pending','in_progress','done','blocked')),
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now')));

CREATE TABLE todo_deps (
  todo_id TEXT NOT NULL, depends_on TEXT NOT NULL,
  PRIMARY KEY (todo_id, depends_on),
  FOREIGN KEY (todo_id) REFERENCES todos(id),
  FOREIGN KEY (depends_on) REFERENCES todos(id));

CREATE TABLE inbox_entries (                     -- inter-agent message inbox
  id TEXT PRIMARY KEY, recipient_session_id TEXT NOT NULL,
  sender_id TEXT NOT NULL, sender_name TEXT NOT NULL, sender_type TEXT NOT NULL,
  interaction_id TEXT NOT NULL, sequence INTEGER NOT NULL DEFAULT 0,
  summary TEXT NOT NULL, content TEXT NOT NULL,
  unread INTEGER NOT NULL DEFAULT 1,
  sent_at INTEGER NOT NULL, read_at INTEGER, notified_at INTEGER);
```

---

## 13. Auxiliary files

| Artifact | Location | Kind | Engram | Meaning |
|---|---|---|---|---|
| `session.db` | `<uuid>/session.db` | SQLite | No | TODOs + inter-agent inbox ([§12.2](#122-copilotsession-stateuuidsessiondb--per-session-155-dirs)) |
| `rewind-snapshots/` | `<uuid>/rewind-snapshots/` | dir | No | `index.json` = `{version, snapshots, filePathMap}`; `backups/<16-hex-hash>-<epoch-ms>` = verbatim pre-edit file copies for "rewind/undo" |
| `files/` | `<uuid>/files/` | dir | No | User-pasted payloads: `paste-<epoch-ms>.txt` |
| `research/` | `<uuid>/research/` | dir | No | Web/research artifacts (empty in this store) |
| `plan.md` | `<uuid>/plan.md` | Markdown | No | Agent's free-form working plan (15 dirs) |
| `inuse.<pid>.lock` | `<uuid>/inuse.<pid>.lock` | file | No | Liveness lock; content = bare owning PID |
| `session-store.db` | `~/.copilot/session-store.db` | SQLite | No | Store-wide mirror + FTS5 ([§12.1](#121-copilotsession-storedb--store-wide-mirror-schema_version--4)) |
| `config.json` / `settings.json` / `mcp-config.json` | `~/.copilot/` | JSON | No | CLI config |
| `command-history-state.json` | `~/.copilot/` | JSON | No | Shell command history |
| `copilot-instructions.md` | `~/.copilot/` | Markdown | No | Global instructions |
| `ide/` `installed-plugins/` `logs/` `marketplace-cache/` `pkg/` `plugin-data/` | `~/.copilot/` | dirs | No | CLI runtime state |

---

## 14. Engram mapping

Source field/record → Engram `Session`/`Message` field → adapter `file:line` (Swift + TS).

| Engram field | Source of truth | Swift `CopilotAdapter.swift` | TS `copilot.ts` | Notes |
|---|---|---|---|---|
| **id** | `workspace.id` → else dir name | `:54` (events) / `:179` (checkpoint) | `:77` / `:278` | UUID |
| **source** | constant `copilot` | `:4`,`:99` | `:19`,`:120` | |
| **summary** | `workspace.summary` → else first 200 chars of first `user.message.content` → else (checkpoint) first entry title | `:110` / `:194` | `:129` / `:291` | ⚠️ `workspace.name` (often a better AI title) **ignored** |
| **cwd** | `workspace.cwd` → else `session.start.context.cwd` | `:57`,`:72`; project=`nil` `:103` | `:80`,`:97` | `project` always null; derived later by indexer from cwd |
| **startTime** | `workspace.created_at` → else `session.start.startTime` → else min(`user.message.ts`) | `:55`,`:69`,`:81` / `:184` | `:78`,`:95-96`,`:105` / `:283` | |
| **endTime** | `workspace.updated_at` → else max(message ts); `nil`/`undefined` if == startTime | `:56`,`:82`,`:86`,`:101` / `:185` | `:79`,`:106`,`:111`,`:122` / `:284` | Single-instant sessions get null endTime |
| **model** | **not mapped** (per-msg `model` + `currentModel` dropped) | `:102` (`model: nil`) | — | ⚠️ multi-model sessions lose model attribution |
| **messageCount** | `userCount + assistantCount` (checkpoint: entry count) | `:105` / `:189` | `:124` / `:286` | ⚠️ excludes tool/system/turn events |
| **userMessageCount** | count of `user.message` (checkpoint: 0) | `:76`,`:106` / `:190` | `:101`,`:125` / `:287` | |
| **assistantMessageCount** | count of `assistant.message` (checkpoint: 0) | `:85`,`:107` / `:191` | `:110`,`:126` / `:288` | ⚠️ counts empty tool-only turns too |
| **toolMessageCount** | hardcoded `0` | `:108` / `:192` | `:127` / `:289` | Copilot tool events never surfaced |
| **systemMessageCount** | `0` for events; checkpoint entry count for checkpoint sessions | `:109` / `:193` | `:128` / `:290` | |
| **role (per msg)** | `user.message`→user, `assistant.message`→assistant, checkpoint entry→system | `:218` / `:139` | `:231` / `:150` | Tool/system/skill events never become messages |
| **content (per msg)** | `data.content` only | `:219` | `:232` | reasoning/toolRequests dropped |
| **usage (tokens)** | sum of `session.shutdown.data.modelMetrics[*].usage` → attached to **last** assistant message | `:228-269` | `:177-191`,`:380-400` | inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens←`cacheWriteTokens`; `reasoningTokens` dropped |
| **filePath / locator** | path to `events.jsonl` or `checkpoints/index.md` | `:111` / `:196` | `:130` / `:292` | |
| **sizeBytes** | file size of the locator file only | `:112` / `:196` | `:131` / `:293` | ⚠️ only the events/index file, not whole dir |
| **agentRole / originator / origin** | hardcoded `nil` | `:114-116` | — (not emitted) | No dispatch detection |
| **parentSessionId / suggestedParentId** | hardcoded `nil` | `:120-121` | — (not emitted) | Subagents never grouped — [§10](#10-subagent--parent-child--dispatch) |
| **tier / qualityScore / indexedAt / summaryMessageCount** | `nil` | `:113`,`:117-119` | — | Set downstream |

### Data-loss inventory (what Engram does NOT consume)

1. **`workspace.name`** — a real, often AI-generated **title** (138/470 live). Engram
   instead uses first 200 chars of the first user prompt. Biggest UX miss.
2. **Tool activity** — `tool.execution_start/complete` and `assistant.message.toolRequests`
   entirely dropped; `toolMessageCount` hardcoded 0 → zero Copilot tool/file analytics.
3. **Subagent lineage** — `subagent.started/completed` never feed parent-child
   detection ([§10](#10-subagent--parent-child--dispatch)).
4. **Per-message model + tokens** — `assistant.message.model` / `.outputTokens` dropped;
   only the shutdown aggregate survives.
5. **Reasoning** — `reasoningText` / `reasoningOpaque` / `reasoningTokens` dropped ([§8](#8-reasoning--thinking)).
6. **`transformedContent`** (real injected prompt) and `attachments` on user messages.
7. **Hooks, skills, turn frames, compaction, system/notification, mode/plan changes** — all dropped.
8. **Rich shutdown stats** — `conversationTokens`, `currentTokens`, `totalPremiumRequests`,
   `codeChanges`, `tokenDetails` dropped (only `modelMetrics.*.usage` 4-field subset kept).
9. **Git/host context** — `git_root`, `repository`, `branch`, `headCommit` dropped;
   `project` derived from `cwd` alone downstream.
10. **Both SQLite stores** — `session.db` and `session-store.db` (incl. cleaner `turns`
    table) entirely ignored.

---

## 15. Lineage, gotchas, version drift & edge cases

### Shared format lineage (sibling tools)

| Tool | Engram adapter | Store | Format family |
|---|---|---|---|
| **GitHub Copilot CLI** | `CopilotAdapter` | `~/.copilot/session-state/<uuid>/events.jsonl` + `workspace.yaml` | **JSONL event-stream** |
| **OpenAI Codex CLI** | `CodexAdapter` | `~/.codex/sessions/.../*.jsonl` | **JSONL event-stream** (closest sibling) |
| **Cursor** | `CursorAdapter` | `…/Cursor/User/globalStorage/…` | **SQLite `.vscdb`** |
| **VS Code Copilot Chat** | `VSCodeAdapter` | `…/Code/User/workspaceStorage/…` | **SQLite `.vscdb`** |
| **Cline** | `ClineAdapter` | `~/.cline/data/tasks/` | per-task JSON |
| **Gemini CLI / Qwen / iFlow** | `Gemini/Qwen/IFlowAdapter` | `~/.gemini/`, `~/.qwen/`, `~/.iflow/` | shared Gemini-CLI JSON lineage |

**Key lineage correction.** The name "Copilot" invites grouping with the VS Code
Copilot / Cursor (editor extension, SQLite `.vscdb`) family — but on disk Copilot **CLI**
belongs to the **JSONL agent-CLI family alongside Codex CLI**, not the VS Code SQLite
family. Both Copilot CLI and Codex CLI use newline-delimited typed events
(`type` + `data` + `timestamp`) with a `session.start`/`session.shutdown` envelope. The
Gemini↔Qwen↔iFlow trio share a *different* (Gemini-CLI-derived) JSON layout. **Three
distinct format lineages despite overlapping brand names.** See the Codex CLI doc in
this directory for the closest sibling.

### Gotchas / version drift / edge cases

- **YAML quote handling is aligned.** Both Swift and TS strip one matched outer quote
  pair from `workspace.yaml` values (`CopilotAdapter.swift:363-389`,
  `copilot.ts:364-378`, `stripYamlQuotes:438-446`). Live: 6 quoted `name:` values
  (ignored by Engram), 0 quoted `cwd`/`id` today. Covered by TS
  `tests/adapters/copilot.test.ts` and Swift
  `AdapterMessageCountTests.testCopilotStripsMatchedYamlQuotePairs`.
- **Empty-but-non-zero assistant messages.** Live: a large fraction — **⅓ to ~½
  depending on session** (one session 86/261 ≈ ⅓; another, 51835c08, 1445/2827 ≈ 51%) —
  of `assistant.message` events have empty `content` (tool-call-only turns). Engram
  counts all as assistant messages → `assistantMessageCount` inflated vs human-readable
  turns; transcript shows blank rows. Magnitude generalizes worse than the one cited ⅓ sample.
- **Live DB field freshness still lags parser fixes.** The 2026-07-02
  adapter-vs-DB id diff is clean (227 adapter locators, 227 DB rows, 227
  `file_index_state ok/v1` rows), but 8 existing DB rows retain older parser
  snapshots. Six are summary-only quote-stripping debt from before the Swift/TS
  YAML quote fix, e.g. DB `"Reply with only: OK"` vs current
  `Reply with only: OK`. The remaining two rows are the older count/end-time
  snapshots: `51835c08-bea0-4594-83e7-9fe69b71808a` is DB 1,952 vs current
  2,863 messages, and `ad05ab2d-ddcb-419f-8452-57ec21d4b96f` is DB 2,009 vs
  current 2,103. File size and file-index state are aligned; reindex/cleanup is
  needed to refresh these 8 historical rows.
- **`messageCount` two opposite distortions.** It excludes tool/hook traffic
  (understates real activity for tool-heavy sessions) AND counts empty assistant rows
  (overstates conversational turns).
- **Both-present directories.** A dir with `events.jsonl` **and** populated `checkpoints/`
  is parsed as events; checkpoint summaries are never surfaced.
- **Header-only `index.md`** (243/470 live) → 0 entries → directory **silently skipped**
  (no error, session disappears from Engram).
- **`cwd: /` checkpoint sessions** become root-scoped, near-empty Session rows
  (often `created_at == updated_at`).
- **Checkpoint fallback unverified live.** The events-absent → checkpoint-index path is
  implemented in both adapters but **never exercised** on this live store: 26 checkpoint
  indexes have parseable entries, but every one also has `events.jsonl`; the 243
  events-less dirs have empty templates. Behavior against real fallback data is
  unproven from disk alone.
- **`copilotVersion` drift / unversioned schema.** Current live data includes
  `0.0.420`/`0.0.421`/`0.0.422` plus sparse `1.0.x` versions from `1.0.2` up
  to `1.0.65`; `1.0.63` remains present but is not the newest observed version.
  The adapter is forgiving — it ignores unknown `type` values, so new types
  (`skill.invoked`, `subagent.*`, `session.model_change`, absent from the synthetic fixture)
  are tolerated. A breaking rename of
  `user.message`/`assistant.message`/`session.shutdown` would **silently zero out** a
  session.
- **Fixtures lag reality badly.** The synthetic fixture is 3 events (no shutdown,
  checkpoints, subagents, tokens); the parity golden reflects that minimal shape. Green
  parity tests prove the adapter ignores live richness *consistently*, NOT that it
  handles it.
- **Token total correct, splits lost.** `modelMetrics` is summed across all models
  (live: 3-4 models in one session) → correct session total but no per-model/per-turn split.
- **No agent-role / parent linking.** Every Copilot session is top-level in Engram
  ([§10](#10-subagent--parent-child--dispatch)).
- **SQLite mirror lag.** `session-store.db` (140 sessions / 241 turns / 9 checkpoints)
  lags the filesystem (470 dirs). It is derived/recent-activity; Engram does not read it.

### Open questions

- **Why ignore `session-store.db`?** Its `turns` table is a cleaner paired transcript and
  `checkpoints` are structured — is the events.jsonl/Markdown choice deliberate or an
  indexing gap worth closing? **(Engram-internal design — not web-verifiable.)** Two
  format facts bear on it, though: GitHub's official docs state the session store holds
  "a subset of the full data stored in the session files" (so `events.jsonl` is the
  fuller/lossless record), and the DB is a *derived* store the user rebuilds from the
  files via `/chronicle reindex` — it can lag and diverge (records persist after dirs are
  cleaned; returns 0 rows when sync is local-only). The events.jsonl-as-source-of-truth
  choice is consistent with how GitHub describes the store
  ([docs](https://docs.github.com/en/copilot/concepts/agents/copilot-cli/chronicle),
  [issue #2654](https://github.com/github/copilot-cli/issues/2654)).
- **`forge_trajectory_events` / `session_files`** exist with tool/file columns but are
  **0 rows** in this store. **Confirmed (official, partial):** `session_files` is a real,
  documented table whose purpose is to record "every file touched during the session"
  (corroborated by two independent reverse-engineering write-ups), so it IS designed to be
  populated; the 0-row observation is store-specific, not a dead column. No public source
  mentions `forge_trajectory_events` or `dynamic_context_items` at all (Copilot CLI is
  closed-source; public reverse-engineering enumerates only 6 tables), so whether newer
  versions populate `forge_trajectory_events` **cannot be confirmed from public sources**
  ([jonmagic](https://jonmagic.com/posts/github-copilot-session-search-and-resume-cli/),
  [dfberry](https://dfberry.github.io/2026-04-16-session-storage-decision-guide)).
- **243/470 events-less dirs** (~52%). **Confirmed (official):** these are
  aborted/never-prompted launches, not a cleanup artifact. GitHub
  [issue #1451](https://github.com/github/copilot-cli/issues/1451) documents that empty
  session directories accumulate from sessions "opened but never interacted with" / that
  received no responses, and defines "Empty" as "No events.jsonl file, or no user
  messages at all". There is no automatic GC — the issue requests a manual `/cleanup`
  precisely because they pile up.
- **`reasoningOpaque`** format not decoded (confirmed string co-occurring with
  `reasoningText`). **(web-checked 2026-06-21: no authoritative source found.)** Official
  docs confirm extended-thinking/reasoning is tracked and preserved through compaction,
  but Copilot CLI is closed-source and no public source documents the internal encoding of
  the `reasoningOpaque` blob
  ([DeepWiki](https://deepwiki.com/github/copilot-cli/3.7-context-and-token-management)).
- **`mc_*` / `remote_steerable` / `client_name`** (mission-control / remote-steering).
  **Confirmed (official, partial):** `remote_steerable` maps to a real, documented feature
  — "remote control" of CLI sessions (GitHub Mobile / github.com / VS Code), gated by the
  org/enterprise "Store local sessions in the Cloud" policy. The `mc_*` fields plausibly
  link to GitHub's "Mission Control" (Agent HQ), which assigns/steers/tracks Copilot
  coding-agent tasks across sessions. However, no official source names the literal
  `workspace.yaml` keys (`mc_task_id` / `mc_session_id` / `mc_last_event_id` /
  `remote_steerable` / `client_name`), so the precise field-to-feature mapping is
  inferential; whether they should drive Engram parent-child grouping remains an
  Engram design question
  ([remote-control docs](https://docs.github.com/en/copilot/concepts/agents/copilot-cli/about-remote-control),
  [Mission Control changelog](https://github.blog/changelog/2025-10-28-a-mission-control-to-assign-steer-and-track-copilot-coding-agent-tasks/)).
- **No automatic file rollover/TTL** (events.jsonl up to 38 MB, dirs back to March).
  **Confirmed (official):** there is no automatic size-based rotation or TTL of
  `events.jsonl` (append-only streaming log; in-stream auto-compaction at 95% token
  capacity creates checkpoints but does not rotate/shrink the on-disk log). Retention is
  user-invoked, not automatic: `/session prune --older-than DAYS`, `/session delete [ID]`,
  `/session delete-all [--yes]`, and `/session cleanup` exist (local sessions only; skip
  sessions in use; synced copies on GitHub.com must be removed separately)
  ([docs](https://docs.github.com/en/copilot/concepts/agents/copilot-cli/chronicle),
  [CLI reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference)).

---

## 16. Appendix: real anonymized samples

### `events.jsonl` — `session.start` (current rich-context shape; trailing flags version-variable)
```json
{"type":"session.start","timestamp":"2026-06-20T04:00:25.530Z","id":"<uuid>","parentId":null,
 "data":{"sessionId":"<uuid>","producer":"copilot-agent","version":1,"copilotVersion":"1.0.63",
         "startTime":"2026-06-20T04:00:25.530Z",
         "context":{"branch":"<branch>","cwd":"<path>","gitRoot":"<path>","repository":"<owner>/<repo>"}}}
```

### `events.jsonl` — `user.message`
```json
{"type":"user.message","timestamp":"…","id":"<uuid>","parentId":"<uuid>",
 "data":{"content":"<REDACTED>","transformedContent":null,"attachments":[],"interactionId":"<uuid>"}}
```

### `events.jsonl` — `assistant.message` (with reasoning + tool request + turn/correlation ids)
```json
{"type":"assistant.message","timestamp":"…","id":"<uuid>","parentId":"<uuid>",
 "data":{"messageId":"<uuid>","model":"claude-sonnet-4.6","content":"<REDACTED>",
         "interactionId":"<uuid>","turnId":"<uuid>","outputTokens":643,"phase":"<REDACTED>",
         "requestId":"<uuid>","serviceRequestId":"<uuid>","apiCallId":"<uuid>",
         "reasoningText":"<REDACTED>","reasoningOpaque":"<REDACTED>","encryptedContent":"<REDACTED>",
         "parentToolCallId":"toolu_…",
         "toolRequests":[{"toolCallId":"toolu_…","name":"<tool>","arguments":{…},
                          "type":"function","intentionSummary":"<REDACTED>"}]}}
```

### `events.jsonl` — `tool.execution_complete`
```json
{"type":"tool.execution_complete","timestamp":"…","id":"<uuid>","parentId":"<uuid>",
 "data":{"toolCallId":"toolu_…","success":true,"model":"claude-opus-4.6","interactionId":"<uuid>",
         "result":{"content":"<REDACTED>","detailedContent":"<REDACTED>"},
         "toolTelemetry":{"metrics":{"responseTokenLimit":0,"resultForLlmLength":0,"resultLength":0},
                          "properties":{"command":"<REDACTED>","viewType":"…"}}}}
```

### `events.jsonl` — `subagent.completed`
```json
{"type":"subagent.completed","timestamp":"…","id":"<uuid>","parentId":"<uuid>",
 "data":{"agentName":"<REDACTED>","agentDisplayName":"<REDACTED>","model":"claude-sonnet-4.6",
         "durationMs":12345,"totalTokens":6789,"totalToolCalls":4,"toolCallId":"toolu_…"}}
```

### `events.jsonl` — `session.shutdown`
```json
{"type":"session.shutdown","timestamp":"…","id":"<uuid>","parentId":"<uuid>",
 "data":{"shutdownType":"routine","currentModel":"claude-opus-4.6",
         "conversationTokens":60168,"systemTokens":7640,"toolDefinitionsTokens":19409,
         "totalApiDurationMs":560974,"totalPremiumRequests":27,
         "codeChanges":{"linesAdded":67,"linesRemoved":4,"filesModified":["<path>"]},
         "modelMetrics":{"claude-opus-4.6":{"requests":{"count":62,"cost":27},
           "usage":{"inputTokens":3749137,"outputTokens":27465,
                    "cacheReadTokens":3433631,"cacheWriteTokens":0,"reasoningTokens":179832}}}}}
```

### `workspace.yaml` (full superset)
```yaml
id: 00f0af74-c7a0-440c-812a-29bad956c597
cwd: /Users/<user>/<project>
git_root: /Users/<user>/<project>
repository: <owner>/<repo>
host_type: github
branch: feat/<branch>
client_name: github/cli
name: <REDACTED title>
user_named: false
summary: <REDACTED>
summary_count: 0
created_at: 2026-06-20T04:00:25.530Z
updated_at: 2026-06-20T04:02:29.076Z
remote_steerable: false
mc_task_id: <uuid>
mc_session_id: <uuid>
mc_last_event_id: <uuid>
```

### `checkpoints/index.md`
```markdown
# Checkpoint History

Checkpoints are listed in chronological order. Checkpoint 1 is the oldest, higher numbers are more recent.

| # | Title | File |
|---|-------|------|
| 1 | <Title text> | 001-<slug>.md |
| 2 | <Title text> | 002-<slug>.md |
```

### `checkpoints/NNN-<slug>.md` (body)
```markdown
<overview>
<REDACTED>
</overview>
<history>
<REDACTED>
</history>
<work_done>
<REDACTED>
</work_done>
<technical_details>
<REDACTED>
</technical_details>
<important_files>
<REDACTED>
</important_files>
<next_steps>
<REDACTED>
</next_steps>
```

### `session-store.db` rows (structure verbatim, content redacted)
```json
// sessions
{"id":"4bb3e088-…","cwd":"<path>","repository":"<owner>/<repo>","host_type":"github",
 "branch":"main","summary":"<REDACTED>","created_at":"2026-05-02T05:24:29.274Z","updated_at":"2026-05-02T05:24:36.193Z"}
// turns  (already-paired transcript)
{"id":1,"session_id":"4bb3e088-…","turn_index":0,"user_message":"<REDACTED>","assistant_response":"<REDACTED>","timestamp":"2026-05-02T05:24:39.126Z"}
// checkpoints  (structured form of .md section tags)
{"id":1,"session_id":"6e89dd68-…","checkpoint_number":1,"title":"<REDACTED>","overview":"<REDACTED>","work_done":"<REDACTED>","created_at":"2026-05-04T12:58:16.128Z"}
// session_refs  (ref_type observed ∈ {commit, pr}; format also supports 'issue')
{"ref_type":"commit","ref_value":"<sha REDACTED>","turn_index":5}
{"ref_type":"pr","ref_value":"<REDACTED>","turn_index":3}
```

### `session.db` (per-session) rows (structure verbatim, content redacted)
```json
// todos  (status ∈ pending|in_progress|done|blocked)
{"id":"<uuid>","title":"<REDACTED>","description":"<REDACTED>","status":"in_progress","created_at":"…","updated_at":"…"}
// inbox_entries  (inter-agent inbox)
{"id":"<uuid>","recipient_session_id":"<uuid>","sender_id":"<uuid>","sender_name":"<REDACTED>","sender_type":"agent","interaction_id":"<uuid>","sequence":0,"summary":"<REDACTED>","content":"<REDACTED>","unread":1,"sent_at":1780000000000,"read_at":null,"notified_at":null}
```

### Fixture `events.jsonl` (synthetic, for reference)
```json
{"type":"session.start","timestamp":"2026-01-01T00:00:00Z","data":{"startTime":"2026-01-01T00:00:00Z","context":{"cwd":"/tmp/test-project"}}}
{"type":"user.message","timestamp":"2026-01-01T00:01:00Z","data":{"content":"Help me fix the bug"}}
{"type":"assistant.message","timestamp":"2026-01-01T00:02:00Z","data":{"content":"I'll look into that."}}
```

---

## References (official sources)

Web confirmation pass (2026-06-21) used these sources. Official GitHub docs and the
`github/copilot-cli` repo are authoritative; community reverse-engineering is corroborating
only (Copilot CLI is closed-source).

**Official (GitHub Docs / Changelog / repo):**
- [About GitHub Copilot CLI session data (chronicle) — GitHub Docs](https://docs.github.com/en/copilot/concepts/agents/copilot-cli/chronicle)
- [Using GitHub Copilot CLI session data — GitHub Docs](https://docs.github.com/en/copilot/how-tos/copilot-cli/use-copilot-cli/chronicle)
- [GitHub Copilot CLI command reference — GitHub Docs](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference)
- [About remote control of GitHub Copilot CLI sessions — GitHub Docs](https://docs.github.com/en/copilot/concepts/agents/copilot-cli/about-remote-control)
- [A mission control to assign, steer, and track Copilot coding agent tasks — GitHub Changelog](https://github.blog/changelog/2025-10-28-a-mission-control-to-assign-steer-and-track-copilot-coding-agent-tasks/)
- [Remote control for Copilot CLI sessions GA on Mobile, Web, and VS Code — GitHub Changelog](https://github.blog/changelog/2026-05-18-remote-control-for-copilot-cli-sessions-now-generally-available-on-mobile-web-and-vs-code/)
- [github/copilot-cli repository](https://github.com/github/copilot-cli)
- [Issue #3551: Formalize events.jsonl as an official hook/integration API](https://github.com/github/copilot-cli/issues/3551)
- [Issue #1451: /cleanup command to remove empty/abandoned sessions](https://github.com/github/copilot-cli/issues/1451)
- [Issue #3046: session-store.db not created on Windows WSL2](https://github.com/github/copilot-cli/issues/3046)
- [Issue #2654: session_store_sql silently returns empty when session sync is local](https://github.com/github/copilot-cli/issues/2654)
- [Issue #2012: Session file corrupted — raw U+2028/U+2029 in events.jsonl](https://github.com/github/copilot-cli/issues/2012)

**Community (reverse-engineering, corroborating):**
- [jonmagic: GitHub Copilot Session Search and Resume CLI](https://jonmagic.com/posts/github-copilot-session-search-and-resume-cli/)
- [dfberry: Exploring Copilot CLI Session Management](https://dfberry.github.io/2026-04-16-session-storage-decision-guide)
- [DeepWiki: github/copilot-cli — Session State & Lifecycle Management](https://deepwiki.com/github/copilot-cli/6.2-session-state-and-lifecycle-management)
- [DeepWiki: github/copilot-cli — Context and Token Management](https://deepwiki.com/github/copilot-cli/3.7-context-and-token-management)
