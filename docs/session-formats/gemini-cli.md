# Gemini CLI — Session Format Reference

Last researched: 2026-06-21 (Engram session-format research workflow)
Engram adapter status refreshed: 2026-07-02 (local source/live DB audit)

> Definitive English reference for how **Google Gemini CLI** persists its
> sessions on disk, and how Engram's `GeminiCliAdapter` consumes them. Parallel
> to the Claude Code / Codex session-format docs. Self-contained; cross-references
> the shared Google-ecosystem family (Qwen Code, iFlow) where relevant.

**Evidence basis (this doc).** Three sources cross-checked; on conflict REAL data wins, discrepancy flagged.

1. **LIVE on-disk store** — `~/.gemini/` on this machine. **3 session transcripts** across 2 non-empty project dirs:
   - `2 × .json` (legacy single-object) in `~/.gemini/tmp/surge/chats/` (201.8 KB rich + 468 B `info`-only).
   - `1 × .jsonl` (newer append-delta) in `~/.gemini/tmp/safeline/chats/` (19.1 KB).
   - Plus live `~/.gemini/projects.json` (258 entries), 4 per-project `.project_root` files, and several empty `chats/` dirs.
   - **0 live `*.engram.json` sidecars** (`find ~/.gemini -name '*.engram.json'` → empty).
2. **Repo fixtures** — `tests/fixtures/gemini/{session-sample.json,projects.json}` (2 files) and `tests/fixtures/adapter-parity/gemini-cli/{success.expected.json,projects.json,input/tmp/my-project/chats/session-sample.json}`.
3. **Engram adapters (codified knowledge)** — Swift product parser `macos/Shared/EngramCore/Adapters/Sources/GeminiCliAdapter.swift`; TS reference parser `src/adapters/gemini-cli.ts`.

**Current Engram status (2026-07-02):** The live store still mixes legacy single-object `.json` (Apr 2026) and newer `.jsonl` (Jun 2026). Confirmed (official): `.jsonl` is now the **default and only** format for new sessions (PR #23749, ships in v0.39.0); single-object `.json` is read-only legacy that the CLI migrates to `.jsonl` on resume — [PR #23749](https://github.com/google-gemini/gemini-cli/pull/23749), [Issue #15292](https://github.com/google-gemini/gemini-cli/issues/15292). Current Engram Swift and TS source discover both direct main sessions and native nested subagent JSONL under `chats/<parentSessionId>/`, replay JSONL event logs line-by-line, derive native subagent `parentSessionId` from the path, and prefer `.project_root` for cwd resolution. Fresh local smoke at `2026-07-01T20:09:16Z` listed/parsed all 3 current files, found 0 nested subagent files on this machine, streamed 4 transcript messages, and found 0 stream/count mismatches. The live DB has all 3 current live files, including the 2026-06-29 Safeline `.jsonl`, and all 3 have `file_index_state ok`; remaining DB drift is cleanup-only: 383 historical DB-only `~/.gemini/tmp` rows, 4 stale `file_index_state` locators, and one current legacy `.json` row (`75cb965e...`) whose stored counts are still historical (`message_count` 4 -> current 3, `assistant_message_count` 3 -> current 2). That same row also still stores `cwd="surge"` while the current parser resolves `/Users/bing/-NetWork-/Surge` from `.project_root`.

---

## 1. Overview & TL;DR

**What / where / how.** Gemini CLI stores each chat under `~/.gemini/tmp/<projectDir>/chats/`. There is **no SQLite, no leveldb, no gRPC cache** — just files on disk. Current Gemini CLI writes **append-only `.jsonl`** per session (PR #23749, v0.39.0); the single-object `.json` form is legacy and only READ via a fallback, then migrated to `.jsonl` on resume. The per-project dir name is **always** the 64-hex SHA-256 of the project root path (`getProjectHash`). Gemini CLI core has **no** `~/.gemini/projects.json` registry and provides **no** hash→cwd reverse mapping; the only on-disk cwd record it writes per project is `tmp/<hash>/.project_root`. The `projects.json` observed live is an external launcher/Engram artifact, not part of the Gemini CLI format. Engram's parent-link sidecar (`<sessionId>.engram.json`) is likewise an *Engram* convention written by an external plugin, not part of Gemini CLI itself. Confirmed (official): [paths.ts (`getProjectHash` = sha256 hex)](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/utils/paths.ts); [PR #23749 (JSONL migration)](https://github.com/google-gemini/gemini-cli/pull/23749).

**Mental model.** `session = file`. The legacy `.json` form holds the entire conversation in a single re-serialized object (whole-file rewrite on each turn). The newer `.jsonl` form is an **event-sourced append log** (NOT a per-turn full-snapshot log): an initial metadata record, then full `MessageRecord` objects appended one per line as turns occur, plus `MetadataUpdateRecord` `{"$set": Partial<ConversationRecord>}` (metadata-only deltas) and `RewindRecord` `{"$rewindTo": "<messageId>"}` (history truncation). The authoritative state is obtained by **replaying all lines** (appends + `$set` + rewinds), not by reading only the last line. Confirmed (official): [chatRecordingService.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatRecordingService.ts), [chatRecordingTypes.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatRecordingTypes.ts).

**ASCII layout / layering diagram.**

```
~/.gemini/                                         storage tech: plain JSON/JSONL files
├── projects.json            ── global { "projects": { "<absCwd>": "<projectName>" } }
├── settings.json, state.json ── CLI config (NOT session data; ignored by adapter)
└── tmp/                      ── transcript root  (adapter `tmpRoot`)
    └── <projectDir>/         ── ALWAYS 64-hex SHA-256 of project root (human aliases seen live come from a launcher, not Gemini CLI)
        ├── .project_root     ── 1 line: absolute cwd  (authoritative cwd source; adapter prefers it)
        ├── logs.json         ── lightweight per-message telemetry rows (ignored)
        └── chats/
            ├── session-<YYYY-MM-DDTHH-mm>-<8hex>.jsonl  ── MAIN session, event-sourced log  ← Engram parses by replay
            ├── session-<YYYY-MM-DDTHH-mm>-<8hex>.json   ── LEGACY single-object (read-only fallback in CLI)  ← Engram parses
            ├── <parentSessionId>/                       ── native subagent subdir
            │   └── <sanitizedSessionId>.jsonl           ── kind=="subagent" session  ← Engram parses and links
            └── <sessionId>.engram.json                  ── Engram parent-link sidecar (Layer 1c)

  layer 1  session document   { sessionId, projectHash, startTime, lastUpdated, kind, summary?, memoryScratchpad?, directories?, messages[] }
  layer 2    └─ messages[]    { id, timestamp, type, content, model?, thoughts?, tokens?, toolCalls?, displayContent? }
  layer 3        ├─ content[] { text }                              (user content blocks)
  layer 3        ├─ tokens    { input, output, cached, thoughts, tool, total }
  layer 3        ├─ thoughts[]{ subject, description, timestamp }   (reasoning)
  layer 3        └─ toolCalls[]{ id, name, args, status, result[], ... }
  layer 4              └─ result[].functionResponse { id, name, response{ output } }
```

**TL;DR for Engram engineers.** Engram parses both legacy `.json` and current `.jsonl`, keeps `sessionId / startTime / lastUpdated`, flattens conversation text (`user` + `gemini|model`, dropping `info` and empty-content turns), derives native subagent `parentSessionId`/`agentRole=subagent` from `chats/<parentSessionId>/...`, and (Swift only) derives token usage. It **drops** `model`, `thoughts`, `toolCalls`, `displayContent`, message `id`, and top-level `projectHash`/`kind`/`summary`/`memoryScratchpad`/`directories`. The TS reference path additionally drops **all** token usage.

---

## 2. On-disk layout & file naming

**Authoritative root** (both adapters): `~/.gemini/tmp/` (`GeminiCliAdapter.swift:72-74`, `gemini-cli.ts:77`). Projects file: `~/.gemini/projects.json` (`GeminiCliAdapter.swift:75-77`, `gemini-cli.ts:78-79`).

| Path | Role | Storage tech |
|---|---|---|
| `~/.gemini/tmp/` | session transcript root (adapter `tmpRoot`) | dir of per-project dirs |
| `~/.gemini/tmp/<projectDir>/chats/session-*.json` | one session = one file | **single JSON object** (legacy) |
| `~/.gemini/tmp/<projectDir>/chats/*.jsonl` | one session = one file | **append-delta JSONL mutation log** (newer; parsed by Engram replay) |
| `~/.gemini/tmp/<projectDir>/chats/<sessionId>.engram.json` | Engram parent-link sidecar (Layer 1c) | single JSON object (external plugin writes it) |
| `~/.gemini/projects.json` | global `cwd → projectName` map (adapter `projectsFile`) | single JSON object |
| `~/.gemini/tmp/<projectDir>/.project_root` | 1-line absolute cwd | plain text (preferred by adapter) |
| `~/.gemini/tmp/<projectDir>/logs.json` | lightweight per-message telemetry | JSON array (ignored by adapter) |

### Naming grammar

| Token | Grammar | Live examples | Notes |
|---|---|---|---|
| `<projectDir>` | **ALWAYS a 64-char lowercase hex (SHA-256 of the project root path)** | `8a5edab2…fea0f1` | Confirmed (official): `getProjectHash(projectRoot) = sha256(projectRoot).digest('hex')` — there is **no** alias code path in Gemini CLI core. The human-readable dir names seen live (`surge`, `network`, `polycli-gemini-mcp-empty-bvalwx`) come from a launcher (polycli/Engram) passing a non-path string as the project root, **not** from Gemini CLI. Engram treats whichever it is as the literal `projectName`. [paths.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/utils/paths.ts) |
| main session file | `session-<YYYY-MM-DDTHH-mm>-<8hex>.<json\|jsonl>` | `session-2026-04-08T03-22-75cb965e.json`, `session-2026-06-29T05-57-fe81c4b4.jsonl` | Timestamp = session **start** (minute resolution, `:`→`-`); the 8-hex suffix = `sessionId[0:8]`. **CONFIRMED across the current 3-file live sample** (2 `.json` + 1 `.jsonl`): each filename suffix equals its file's `sessionId[0:8]` exactly — for `.jsonl` the id is read from the header line. Applies to **main** sessions only. |
| subagent session file | `<sanitizedSessionId>.jsonl` inside `tmp/<projectDir>/chats/<parentSessionId>/` | — | Confirmed (official): subagent sessions (`kind === 'subagent'`) are NOT named with the `session-<ts>-<8hex>` form; they live in a subdirectory named after the `parentSessionId`, with filename `<sanitizedSessionId>.jsonl`. This is native Gemini CLI parent→child linkage (see [§10](#10-subagent--parent-child--dispatch)). [chatRecordingService.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatRecordingService.ts) |
| sidecar | `<sessionId>.engram.json` | (none live) | Full UUID `sessionId` + `.engram.json`. Sibling of the session file. |

> **Conflict / nuance (REAL wins).** The adapter derives `projectName` as the path component *before* `chats` (`projectName(from:)` Swift:208-214; TS path split around `chats`:125-132) — i.e. the **directory name**, NOT the in-file `projectHash`. Live evidence shows directory name (`surge`) ≠ in-file `projectHash` (`cf46ca80…16206b`). So `project` is the directory alias; the file's own `projectHash` field is **never read**.

### Tree example (live, anonymized)

```
~/.gemini/
├── projects.json                      # { "projects": { "<absCwd>": "<projectName>", ... } } (258 entries live)
└── tmp/
    ├── surge/                         # <projectDir> = human alias (== projects.json value)
    │   ├── .project_root              # /Users/<user>/-NetWork-/Surge   (27 B)
    │   ├── logs.json                  # [ { sessionId, messageId, type, message, timestamp }, … ]  (3 rows)
    │   └── chats/
    │       ├── session-2026-04-08T03-22-75cb965e.json   # 201.8 KB  rich: user+gemini+toolCalls+tokens+thoughts
    │       └── session-2026-04-13T07-47-bcf966c3.json   # 468 B     info-only (→ messageCount 0)
    ├── network/
    │   └── chats/                                        # empty (dir created without transcript)
    ├── safeline/
    │   ├── .project_root
    │   ├── logs/
    │   └── chats/
    │       └── session-2026-06-29T05-57-fe81c4b4.jsonl  # 19.1 KB  NEWER mutation-log (adapter parses)
    └── 8a5edab282632443219e051e4ade2d1d5bbc671c781051bf1437897cbdfea0f1/   # <projectDir> as 64-hex SHA-256
        └── chats/                                                          # empty here
```

---

## 3. File lifecycle & generation

| Aspect | Behavior | Evidence |
|---|---|---|
| **Storage tech** | File-per-session. No database/leveldb/gRPC cache. | live store; adapter reads whole file via `Data(contentsOf:)` / `readFile` |
| **DB vs file** | File. One file = one `sessionId`; filename encodes start-minute + first-8-of-UUID. | filename grammar |
| **Append vs rewrite (legacy `.json`)** | Whole-file **rewrite**: the single JSON object is re-serialized each turn; `lastUpdated` advances, `messages` grows. | top-level `lastUpdated` updated in place |
| **Append vs rewrite (newer `.jsonl`)** | **Event-sourced append log.** An initial metadata record, then full `MessageRecord` objects appended one per line as turns occur, plus `MetadataUpdateRecord` `{"$set": Partial<ConversationRecord>}` (metadata-only deltas; CAN carry `messages` but is not the per-turn carrier) and `RewindRecord` `{"$rewindTo": "<messageId>"}` (truncation). State = **replay all lines**, NOT "last line wins". Confirmed (official): [chatRecordingService.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatRecordingService.ts), [chatRecordingTypes.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatRecordingTypes.ts) |
| **Resume** | A resumed session keeps the same `sessionId`/file and continues to grow (legacy) or appends more records (jsonl); `startTime` fixed, `lastUpdated` moves. A resumed legacy `.json` is migrated to `.jsonl` (filename gains a trailing `l`: `session-foo.json` → `session-foo.jsonl`). | format; [PR #23749](https://github.com/google-gemini/gemini-cli/pull/23749) |
| **Rollover** | New session = new file in the same `chats/`; no rotation/segmenting of an existing transcript. | one file per UUID |
| **Archive / cleanup** | Confirmed (official): Gemini CLI has an explicit retention/GC path. `cleanupExpiredSessions` runs during CLI startup and deletes sessions exceeding `general.sessionRetention` (`enabled`, `maxAge`, `maxCount`, `minRetention`; default retention is 30 days), removing session files AND associated artifacts such as implementation plans, task trackers, tool outputs, and activity logs. Expired transcripts are **deleted, not archived** — that is why there is no archive dir. Empty `chats/` dirs and empty hash-named project dirs persist — Gemini creates the dir tree before/without writing transcripts. | [session-management.md](https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/session-management.md), [gemini.tsx](https://github.com/google-gemini/gemini-cli/blob/main/packages/cli/src/gemini.tsx), [sessionCleanup.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/cli/src/utils/sessionCleanup.ts); live empty dirs (`network/chats`, `8a5e…/chats`) |
| **Atomicity guard (Engram)** | Swift re-checks file identity (size/mtime/inode) before+after read; mismatch → `fileModifiedDuringParse` (a live session being written is rejected, retried later). | `Phase4AdapterSupport.readJSONObject` Swift:6-17 |
| **Size cap (Engram)** | **Two divergent caps.** TS skips files > **10 MB** (`MAX_SESSION_JSON_BYTES`, `gemini-cli.ts:33`). Swift skips files > **100 MB** (`ParserLimits.default.maxFileBytes`, `ParserLimits.swift:17`) — a 10× larger cap. | adapter (see gotcha #8) |
| **Other parse caps (Swift only)** | Swift `ParserLimits` also bounds per-line bytes at **8 MB** (`maxLineBytes`, `ParserLimits.swift:18`) and message count at **10,000** (`maxMessages`, `ParserLimits.swift:19`). TS has neither. `maxLineBytes` is enforced by the current line-by-line `.jsonl` parser. | `ParserLimits.swift:17-19`; `GeminiCliAdapter.swift:233-264` |

**Engram discovery / enumeration** (`listSessionLocators()` Swift:89-102 / `listSessionFiles()` TS:92-108):
1. `detect()` — true iff `~/.gemini/tmp` is a directory (Swift:85-87, TS:82-89).
2. Enumerate direct children of `tmp/` that are directories (each = a `<projectDir>`).
3. For each, require a `chats/` subdirectory; skip projects without one.
4. Recursively walk within `chats/`, emitting files ending in `.json` or `.jsonl` and excluding `*.engram.json` sidecars (Swift:96-99; TS:98-99 plus `sessionFilesUnder()` at TS:255-270). The current adapter no longer requires the `session-` prefix, so it covers native `chats/<parentSessionId>/<sanitizedSessionId>.jsonl` subagent files.
5. Swift returns the list **sorted** (`locators.sorted()`); TS yields lazily in `readdir` order.

---

## 4. Record / line taxonomy

### 4a. Legacy `.json` (single object) — the format Engram parses

One file = one JSON object with a top-level envelope ([§5](#5-shared-envelope--metadata-fields)) and an ordered `messages[]` array of records.

### 4b. `messages[]` record types

Each element is one record; `type` discriminates. Confirmed (official): the on-disk type union is `'user' | 'gemini' | 'info' | 'error' | 'warning'` — there is **no `model` type** ([chatRecordingTypes.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatRecordingTypes.ts)). The assistant turn is `gemini` only; `error` and `warning` are real persisted message types. The Engram TS adapter additionally tolerates a `model` alias and Swift treats `gemini` and `model` identically (Swift:122-123, TS:50), but `model` will never appear from Gemini CLI itself (harmless dead branch). Only `user`/`gemini`/`model` are treated as "conversation" records by Engram; `error`/`warning` are not enumerated by either Engram adapter and fall through to the dropped path.

| `type` | Purpose | Role in Engram | Counted? |
|---|---|---|---|
| `user` | User turn | `role: user` | yes (user count) |
| `gemini` | Assistant turn (richest: model/thoughts/tokens/toolCalls) | `role: assistant` | yes (assistant count) |
| `model` | NOT a Gemini CLI type (Engram TS-adapter alias only; never emitted by Gemini CLI) | `role: assistant` | yes (assistant count) |
| `info` | System/status notice (e.g. `"MCP issues detected. Run /mcp list for status."`) | dropped | **no** (excluded from all counts) |
| `error` | Real Gemini CLI message type (official); not enumerated by Engram adapters | dropped | **no** |
| `warning` | Real Gemini CLI message type (official); not enumerated by Engram adapters | dropped | **no** |

`info` and empty-content messages are dropped: Engram's message mapper only accepts `user`/`gemini`/`model` (Swift:267-273; TS `isConversation` TS:50-51), and both adapters filter empty content before parse counts (Swift:116-117; TS:123-125) while stream output also skips empty text (Swift:272-273; TS:212-214). A purely-`info` session (live `surge/…/bcf966c3.json`) yields `messageCount = 0`.

### 4c. Newer `.jsonl` (event-sourced append log) — four record kinds

Confirmed (official) record taxonomy from [chatRecordingService.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatRecordingService.ts) / [chatRecordingTypes.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatRecordingTypes.ts):

| Line | Shape | Meaning |
|---|---|---|
| initial metadata (line 1) | `Partial<ConversationRecord>`: `sessionId`, `projectHash`, `startTime`, `lastUpdated`, `kind`, `summary`, `memoryScratchpad`, `directories`, optionally `messages` | session metadata header |
| message append (per turn) | a full `MessageRecord` object (`type` ∈ `user`/`gemini`/`info`/`error`/`warning`) | **one actual message object per line**, NOT a snapshot wrapper |
| metadata update | `MetadataUpdateRecord` `{"$set": Partial<ConversationRecord>}` | metadata-only delta (`lastUpdated`, `summary`, `memoryScratchpad`, `directories`); CAN include `messages`, but `$set` is the **metadata-update mechanism, not the per-turn carrier** |
| rewind | `RewindRecord` `{"$rewindTo": "<messageId>"}` | truncates history back to the named message |

This is an **event-sourced** log: the authoritative state is obtained by **replaying all lines** (appends + `$set` deltas + `$rewindTo` truncations), NOT by taking the last line. Current Engram Swift and TS adapters implement this replay (`GeminiCliAdapter.swift:226-264`; `gemini-cli.ts:247-335`).

### 4d. SQLite tables — **N/A for Gemini CLI.** No database backing. (See [§12](#12-sqlite--db-internals).)

---

## 5. Shared envelope / metadata fields

Top-level keys of a legacy `.json` session document and replayed `.jsonl` session state (layer 1). Verified live legacy `.json` keys: `kind, lastUpdated, messages, projectHash, sessionId, startTime`.

| Field | Type | Meaning | Optional | Consumed? | Example (anonymized) |
|---|---|---|---|---|---|
| `sessionId` | string (UUID) | Stable session identity; Engram primary key | **required** (else `malformedJSON`) | ✅ | `"bcf966c3-0612-41b8-aa4a-e95da1e86144"` |
| `startTime` | string (ISO-8601 ms, UTC `Z`) | Session start | **required** | ✅ → `startTime` | `"2026-04-13T07:47:26.014Z"` |
| `lastUpdated` | string (ISO-8601 ms, UTC `Z`) | Last write | optional | ✅ → `endTime` | `"2026-04-13T07:47:26.238Z"` |
| `projectHash` | string (64-hex SHA-256) | Hash of project (in-file); may differ from launcher alias dirs | present live | ❌ (never read; cwd is derived from `.project_root` first) | `"cf46ca80ac87adfa…16206b"` |
| `kind` | string | Session-kind discriminator; observed value `"main"` | present live, **absent in fixtures** | ❌ (not declared by either adapter) | `"main"` |
| `messages` | array<object> | Ordered conversation/event records ([§6](#6-message--content-schema)) | **required** | ✅ | `[ {…}, … ]` |
| `summary` | string | Native Gemini resume/list summary metadata | optional (official; not in current legacy live keys) | ❌ (Engram synthesizes its own summary from the first user turn) | `"Implement cache cleanup"` |
| `memoryScratchpad` | object | Lightweight workflow metadata for memory extraction | optional (official) | ❌ | `{ "version": 1, "workflowSummary": "..." }` |
| `directories` | array<string> | Workspace directories added during the session via `/dir add` | optional (official) | ❌ | `["/Users/<u>/repo"]` |

> **No on-disk `messageCount`.** There is **no** top-level `messageCount` field in any sample — it is absent from live data (`surge/…/75cb965e.json` topkeys = `[kind,lastUpdated,messages,projectHash,sessionId,startTime]`) **and** from both fixtures (`tests/fixtures/gemini/session-sample.json` and `adapter-parity/gemini-cli/input/.../session-sample.json` topkeys = `[lastUpdated,messages,projectHash,sessionId,startTime]`; `grep -l messageCount` over both → no match). `messageCount` exists only as Engram's **recomputed** value in parity *expected* output (`insightFields.messageCount: 3`), never as a source field on disk.

> **Discrepancy flag.** `kind` exists in BOTH live `.json` files but is absent from fixtures and not declared/read by either adapter. Official current Gemini CLI types also include optional `summary`, `memoryScratchpad`, and `directories`; current Engram replays those keys if present but does not map them to session fields. The TS `GeminiSession` interface declares `projectHash` and `summary` (TS:14-19), but the Swift adapter never reads either for metadata mapping. These omissions do not affect current transcript parsing.

---

## 6. Message & content schema

### 6.1 Common envelope fields (all `messages[]` records — layer 2)

| Field | Type | Meaning | Optional | Consumed? | Example |
|---|---|---|---|---|---|
| `id` | string | Per-message id — official code path is `id || randomUUID()` (hyphenated UUID); live `.jsonl` showed **32-hex** ids that the official `randomUUID()` path does not produce (likely a launcher/transformed id; see [§15 remaining unknowns](#resolved-confirmations--remaining-unknowns)); short `mNNN` in fixtures | required | ❌ | `"6e0f533f-996a-4479-a907-b1983e7e7d38"` |
| `timestamp` | string (ISO-8601 ms, UTC) | When the record was produced | required | ✅ (streamMessages) | `"2026-04-08T03:26:59.220Z"` |
| `type` | string | Record discriminator: `user`/`gemini`/`info`/`error`/`warning` (official; `model` is an Engram-only alias) | required | ✅ (drives role + counts) | `"gemini"` |
| `content` | `PartListUnion` (`string \| Part \| Part[]`) | Payload (multiple shapes!) | required | ✅ (flattened) | `[{"text":"…"}]` or `"…"` |

**Content-block (layer 3).** Confirmed (official): `content` is typed as `PartListUnion` for **all** message records (`BaseMessageRecord.content: PartListUnion`), i.e. the full Gemini SDK union `string | Part | Part[]`, not restricted by `type` ([chatRecordingTypes.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatRecordingTypes.ts)). So content can be richer than `[{text}]` — it may carry `functionCall`/`functionResponse`/`inlineData` parts. When `content` is an array of `{text}`, `extractText` joins all non-empty `.text` with `\n` (Swift `extractText` 307-315, TS 54-62); non-text parts are not extracted. A bare-string `content` is used verbatim.

> **Live observation:** `user` content is array-of-`{text}`; `gemini` and `info` content were plain strings live. Confirmed (official): array/`Part[]` content can occur on **any** message type (`gemini`/`info`/`error`/`warning`), not just `user` — `content` is `PartListUnion` for every record. [chatRecordingTypes.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatRecordingTypes.ts)

### 6.2 `type: "user"` record

| Field | Type | Meaning | Optional | Consumed? | Example |
|---|---|---|---|---|---|
| `content` | array of `{text}` | The user's turn | required | ✅ (joined) | `[{"text":"<user prompt>"}]` |
| `displayContent` | array of `{text}` | UI-render version (may differ; e.g. expanded slash-commands) | live (user msgs) | ❌ (ignored) | `[{"text":"<rendered prompt>"}]` |
| `id`,`timestamp`,`type` | — | common envelope | required | — | — |

```json
{
  "id": "6e0f533f-996a-4479-a907-b1983e7e7d38",
  "timestamp": "2026-04-08T03:26:59.220Z",
  "type": "user",
  "content": [ { "text": "<user prompt text>" } ],
  "displayContent": [ { "text": "<rendered prompt text>" } ]
}
```

### 6.3 `type: "gemini"` (assistant) record — richest record

| Field | Type | Meaning | Optional | Consumed? | Example |
|---|---|---|---|---|---|
| `content` | string | Assistant final text (live: always plain string) | required | ✅ | `"<assistant reply text>"` |
| `model` | string | Model id that produced the turn | optional (live: always present on gemini) | ❌ (`model:nil` always) | `"gemini-3.1-pro-preview"` |
| `thoughts` | array of `{subject,description,timestamp}` | Reasoning trace ([§8](#8-reasoning--thinking)) | optional | ❌ (text dropped; token count folded) | `[ {…} ]` |
| `tokens` | object | Per-turn token usage ([§9](#9-token-usage--cost)) | optional | ✅ (Swift only) | `{ … }` |
| `toolCalls` | array | Tool calls + inline results ([§7](#7-tool-calls--results)) | optional (absent when no tools used) | ❌ (`toolCalls:nil`) | `[ {…} ]` |
| `displayContent` | null/absent | Not used on gemini records (observed `null`) | optional | ❌ | `null` |
| `id`,`timestamp`,`type` | — | common envelope | required | — | — |

> **Coverage flag.** `model`, `thoughts`, `toolCalls`, and `displayContent` are real on-disk fields the Swift product adapter does NOT surface — it reads only `content`, `timestamp`, and `tokens` for assistant records (Swift:211-226), sets session-level `model:nil` (Swift:138) and per-message `toolCalls:nil` (Swift:223). Reasoning, model id, and tool calls are on disk but **dropped** by normalization.

```json
{
  "id": "<uuid>",
  "timestamp": "2026-04-08T03:27:10.000Z",
  "type": "gemini",
  "model": "gemini-3.1-pro-preview",
  "content": "<assistant final answer>",
  "thoughts": [ /* §8 */ ],
  "tokens":   { /* §9 */ },
  "toolCalls":[ /* §7 */ ]
}
```

### 6.4 `type: "info"` record (system event)

| Field | Type | Meaning | Optional | Consumed? | Example |
|---|---|---|---|---|---|
| `content` | string | System/info notice | required | ❌ (excluded from counts) | `"<info / system notice text>"` |
| `id`,`timestamp`,`type` | — | common envelope | required | — | — |

In the parity fixture, the 4 raw messages (1 of them `info`) normalize to `messageCount: 3`.

---

## 7. Tool calls & results

Tool calls appear **only** inside a `gemini` record's `toolCalls[]` array. **Request and result are co-located in one element** — there is no separate "tool result" record. Live `name` values seen: `activate_skill`, `read_file`. Engram does **not** import these into messages (`toolCalls:nil` Swift:223; TS `streamMessages` never emits tool data TS:201-209).

### 7.1 `toolCalls[]` element (layer 3)

| Field | Type | Meaning | Optional | Example |
|---|---|---|---|---|
| `id` | string | Tool-call id; **equals the inner `result[].functionResponse.id`** (linkage key) | required | `"read_file-…"` |
| `name` | string | Tool name (snake_case) | required | `"read_file"` |
| `displayName` | string | UI label for the tool | optional | `"ReadFile"` |
| `description` | string | Human description of the call | optional | `"<call description>"` |
| `args` | object | Tool arguments; keys depend on tool (e.g. `file_path`, `name`) | required | `{ "file_path": "<path>" }` |
| `status` | enum string | Execution status. Only `"success"` observed live, but the full set is larger. Confirmed (official): the persisted `ToolCallRecord.status` is the scheduler `Status` from `packages/core/src/scheduler/types.ts` (lifecycle states: `validating`/`scheduled`/`executing`/`success`/`error`/`cancelled`/`awaiting_approval`), NOT the CLI UI `ToolCallStatus` enum (`pending`/`canceled`/`confirming`/`executing`/`success`/`error`). `error` and `cancelled` are real stored values. [chatRecordingTypes.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatRecordingTypes.ts), [cli ui/types.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/cli/src/ui/types.ts) | required | `"success"` |
| `timestamp` | string (ISO-8601) | When the call ran | required | `"2026-04-08T03:27:12.986Z"` |
| `renderOutputAsMarkdown` | boolean | UI hint: render result as markdown | optional | `true` |
| `result` | array of `{functionResponse}` | The tool's return payload (§7.2) | required | `[ {…} ]` |
| `resultDisplay` | string | Human-render version of the result | optional | `"<rendered result>"` |

### 7.2 `result[].functionResponse` — tool-result envelope (layer 4, deepest)

| Field | Type | Meaning | Optional | Example |
|---|---|---|---|---|
| `id` | string | **Matches parent `toolCall.id`** → call↔result linkage | required | `"read_file-…"` |
| `name` | string | Tool name (matches `toolCall.name`) | required | `"read_file"` |
| `response` | object `{output:string}` | Actual return value; `output` holds result text | required | `{ "output": "<result text>" }` |

**Linkage (verified on live data):** for every live tool call, `toolCall.id === toolCall.result[0].functionResponse.id` and `toolCall.name === functionResponse.name`. No cross-record linkage to manage; the result is embedded in the same array element as the call.

```json
"toolCalls": [
  {
    "id": "read_file-1712547432000-abcd",
    "name": "read_file",
    "displayName": "ReadFile",
    "description": "<call description>",
    "args": { "file_path": "<path>" },
    "status": "success",
    "timestamp": "2026-04-08T03:27:12.986Z",
    "renderOutputAsMarkdown": true,
    "resultDisplay": "<rendered result>",
    "result": [
      { "functionResponse": {
          "id": "read_file-1712547432000-abcd",
          "name": "read_file",
          "response": { "output": "<tool output text>" }
      } }
    ]
  }
]
```

> **Coverage flag.** Engram discards `toolCalls` entirely; the parity `success.expected.json` confirms `toolCallCount: 0`. Tool calls are fully on-disk but invisible in Engram's product.

---

## 8. Reasoning / thinking

Stored as `thoughts[]` inside a `gemini` record (layer 3). Live examples had 5 and 15 elements. Each element:

| Field | Type | Meaning | Optional | Example |
|---|---|---|---|---|
| `subject` | string | Short heading of the reasoning step | required | `"<thought heading>"` |
| `description` | string | The reasoning body text | required | `"<reasoning text>"` |
| `timestamp` | string (ISO-8601) | When the thought was emitted | required | `"2026-04-08T03:27:05.000Z"` |

```json
"thoughts": [
  { "subject": "<step heading>", "description": "<reasoning text>", "timestamp": "2026-04-08T03:27:05.000Z" }
]
```

Engram **discards the reasoning text** (not read by either adapter), but the `thoughts` **token count** IS folded into output tokens ([§9](#9-token-usage--cost)).

---

## 9. Token usage & cost

Per-turn usage lives in `tokens` inside a `gemini` record (layer 3). Live values (kept verbatim — non-sensitive):

```json
{ "input": 60823,  "output": 10,  "cached": 0,     "thoughts": 1664, "tool": 0, "total": 62497 }
{ "input": 61350,  "output": 100, "cached": 54434, "thoughts": 0,    "tool": 0, "total": 61450 }
{ "input": 104207, "output": 983, "cached": 67764, "thoughts": 4809, "tool": 0, "total": 109999 }
```

| Field | Type | Meaning | Engram (Swift) mapping |
|---|---|---|---|
| `input` | int | Prompt/input tokens (**includes** cached) | `inputTokens = max(input − cached, 0)` |
| `cached` | int | Cache-read tokens (subset of `input`) | `cacheReadTokens = cached` |
| `output` | int | Completion/answer tokens | summed into `outputTokens` |
| `thoughts` | int | Reasoning-trace tokens | summed into `outputTokens` |
| `tool` | int | Tool-call tokens | summed into `outputTokens` |
| `total` | int | Grand total reported by Gemini | ❌ unused |

**Derivation** (Swift `usage()` 228-246):
- `inputTokens = max(input − cached, 0)` (uncached input only)
- `outputTokens = output + thoughts + tool` (final + reasoning + tool combined)
- `cacheReadTokens = cached`
- `cacheCreationTokens = 0` (Gemini reports no separate cache-creation count)
- Returns `nil` if all three derived values are 0; `user` records carry no usage (Swift:224).

> **Discrepancy flags.**
> 1. The **TS reference adapter drops ALL token usage** — there is no `tokens` handling anywhere in `gemini-cli.ts`. Swift is the **only** path that produces cost/usage data for Gemini CLI.
> 2. The parity fixture's `usageTotals` is all-zero because its synthetic input has no `tokens` blocks. The fixture therefore **masks** the TS-vs-Swift divergence rather than testing token extraction. Real sessions DO populate usage.

No per-token **price/cost** is stored by Gemini CLI; Engram computes cost downstream from these counts (out of scope of the adapter).

---

## 10. Subagent / parent-child / dispatch

**Correction (web-confirmed 2026-06-21; Engram status refreshed 2026-07-02).** Gemini CLI's native files **do** record subagent lineage on disk. Confirmed (official): a session record carries `kind?: 'main' | 'subagent'`, and when `kind === 'subagent'` the session file is stored in a **subdirectory named after the `parentSessionId`** (filename `<sanitizedSessionId>.jsonl`). So native parent→child linkage exists independently of Engram's sidecar — [chatRecordingService.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatRecordingService.ts), [chatRecordingTypes.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatRecordingTypes.ts). Current Engram now discovers and replays those nested JSONL files and maps `chats/<parentSessionId>/<sanitizedSessionId>.jsonl` to `agentRole=subagent` plus `parentSessionId=<parentSessionId>`. The sibling sidecar `<chatsDir>/<sessionId>.engram.json`, written by the external `gemini-plugin-cc` (not by Gemini CLI), remains supported for plugin-created parent links and originator metadata. **No native nested subagent file or sidecar exists on this machine** in the latest smoke, so this path is covered by regression tests rather than live local rows.

`readSidecar` (Swift:215-224) / TS:147-163 reads exactly two fields:

| Field | Type | Meaning | Engram use |
|---|---|---|---|
| `parentSessionId` | string | Deterministic parent (dispatcher) session id | → `parentSessionId` (Layer 1c, confirmed link) |
| `originator` | string | Who launched it (`"Claude Code"` / `"claude-code"`) | → `originator`; if normalizes to `claudecode` → `agentRole:"dispatched"` |

Originator matching is normalization-tolerant. **Drift note:** TS `isClaudeCodeOriginator` (TS:44-47) lowercases + strips all spaces/dashes, requires `claudecode`. Swift `OriginatorClassifier.isClaudeCode` requires exactly `claude-code` after normalizing `_`/space→`-` (per `SessionAdapter.swift`). Both accept `"Claude Code"` and `"claude-code"`; edge forms with internal punctuation could diverge.

A Gemini session tagged `agentRole='dispatched'` is tiered `skip` (accessed via parent), consistent with the cross-adapter originator convention shared with Codex (`CodexAdapter` uses the same `OriginatorClassifier.isClaudeCode`).

```json
{ "parentSessionId": "<claude-code-session-uuid>", "originator": "claude-code" }
```

---

## 11. Summary / compaction

Gemini CLI has optional native top-level `summary` metadata in `ConversationRecord` / JSONL `$set` updates, but no separate compaction transcript record analogous to other providers. Engram does **not** consume Gemini's top-level `summary`; it synthesizes its own session **summary** from the first `user` message's flattened text, capped at 200 chars (`summary` Swift:147 `String(firstUserText.prefix(200))`, TS:179 `firstUserText?.slice(0, 200)`). The Engram summary is therefore derived from transcript text, not from Gemini's native metadata field.

---

## 12. SQLite / DB internals

**N/A for Gemini CLI.** Sessions are plain JSON/JSONL files; there is no SQLite, leveldb, or gRPC cache. (Contrast the VS Code `.vscdb`/leveldb family — Cursor / VS Code / Copilot / Cline — which is documented separately and shares no lineage with Gemini.)

---

## 13. Auxiliary files

Auxiliary files present live and their current adapter use:

| File | Shape | Example (anonymized) | Notes |
|---|---|---|---|
| `~/.gemini/projects.json` | `{ "projects": { "<absCwd>": "<projectName>" } }` (or bare map) | `{ "projects": { "/Users/<u>/-NetWork-/Surge": "surge" } }` | **NOT a Gemini CLI file.** Confirmed (official): Gemini CLI core neither creates nor reads `~/.gemini/projects.json`; `getProjectHash` is a one-way SHA-256 with no inverse. The observed file is an external launcher/Engram artifact. Engram uses it only as cwd reverse-lookup fallback when `.project_root` is absent ([§14](#14-engram-mapping)). 258 live entries. [paths.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/utils/paths.ts) |
| `<projectDir>/.project_root` | 1-line absolute cwd | `/Users/<u>/-NetWork-/Surge` | Confirmed (official): the **only** per-project cwd record Gemini CLI writes — the authoritative cwd source. Current Engram prefers it; this machine has 4 `.project_root` files. |
| `<projectDir>/logs.json` | array of `{ sessionId, messageId:int, type, message, timestamp }` | `{ "sessionId":"75cb965e…", "messageId":0, "type":"user", "message":"…", "timestamp":"…Z" }` | Lightweight per-message telemetry; ignored. `messageId` is a **0-based integer sequence within each session** (live `logs.json` `messageId` values `[0,1,0]` — restarts at 0 for a new session). |
| `<projectDir>/logs/` | directory (present in polycli project) | — | Newer per-project log dir; ignored. |
| `<sessionId>.engram.json` | `{ parentSessionId, originator }` | (none live) | Engram parent-link sidecar ([§10](#10-subagent--parent-child--dispatch)). |
| `~/.gemini/settings.json`, `state.json` | CLI config | — | NOT session data; never read. |

`projects.json` is keyed by absolute cwd with short-name values; both adapters accept either a `{"projects":{…}}` wrapper or a bare top-level map, and use it only after `.project_root` fallback misses (Swift:183-205, TS:223-245).

---

## 14. Engram mapping

`source field/record → Engram Session field → adapter file:line`.

| Engram field | Source field/record | Swift file:line | TS file:line | Notes |
|---|---|---|---|---|
| `id` | `sessionId` | `:108-110,135` | `:120,168` | UUID, required (else `malformedJSON` / null) |
| `source` | constant | `:66,136` | `:71-72,169` | `.geminiCli` / `'gemini-cli'` |
| `summary` / title | first `user` message text, `prefix(200)` | `:129,147` | `:143-145,179` | empty → nil; flattened content; native top-level `summary` ignored |
| `project` | dir name above `chats/` (path component before `chats`) | `:125,140,207-213` | `:131-134,173` | the `<projectDir>` (alias or hex), NOT in-file `projectHash` |
| `cwd` | `.project_root` preferred; `projects.json` **reverse** lookup (value==project) fallback; final fallback = project | `:126-128,183-205` | `:138-141,223-245` | current live `.jsonl` resolves `safeline` → `/Users/bing/-NetWork-/Safeline` |
| `startTime` | `startTime` | `:109-110,137` | `:120,170` | required |
| `endTime` | `lastUpdated` | `:138` | `:171` | optional |
| `messageCount` | `userMessages.count + assistantMessages.count` | `:116-124,142` | `:123-129,174` | excludes `info`/tool/system and empty-content turns |
| `userMessageCount` | `type=="user"` after empty-content filtering | `:116-119,143` | `:123-126,175` | Swift and TS both filter empty content before counts |
| `assistantMessageCount` | `type=="gemini" \|\| "model"` after empty-content filtering | `:116-124,144` | `:123-129,176` | both names counted |
| `toolMessageCount` | constant `0` | `:145` | `:177` | `info`/`toolCalls` never counted |
| `systemMessageCount` | constant `0` | `:146` | `:178` | |
| `model` | **`nil`** (never read) | `:141` | (omitted) | per-message `model` ignored |
| `filePath` | locator | `:148` | `:180` | |
| `sizeBytes` | file size | `:149` | `:118,181` | Swift `Phase4AdapterSupport.fileSize`; TS `stat.size` |
| `parentSessionId` | sidecar `parentSessionId`, else native nested path `chats/<parentSessionId>/<file>.jsonl` (positional) | `:158,215-224` | `:147-158,182` | Layer 1c sidecar **or** Layer 1 native subagent path |
| `originator` | sidecar `originator` | `:131,153,215-224` | `:149-161,183` | |
| `agentRole` | native subagent → `"subagent"`; else `isClaudeCode(originator) ? "dispatched" : nil` | `:150-152` | `:184-186` | native nested-path → subagent |
| `suggestedParentId` | `nil` | `:158` | (omitted) | Layer 2 set later by detection |
| **per-message** `role` | `type=="user"`→`.user`, else `.assistant` | `:267-275` | `:212-217` | |
| **per-message** `content` | `extractText(content)` (join `.text` w/ `\n`) | `:272-273,307-315` | `:212-218,54-62` | empty-content msgs skipped |
| **per-message** `timestamp` | `timestamp` | `:277` | `:218` | |
| **per-message** `usage` | per-msg `tokens` → `TokenUsage` | `:279,283-300` | **none** | **Swift-only**; TS drops all token usage |
| **per-message** `toolCalls` | `nil` (dropped) | `:278` | (none) | tool data not surfaced |

**What Engram does NOT consume:** `info`-type messages; empty-content messages; per-message `model`; `thoughts` text; `displayContent`; `toolCalls` (args/results/status); message `id`; top-level `projectHash`, `kind`, `summary`, `memoryScratchpad`, and `directories`; `tokens.total`; and (TS path) all token usage. Native subagent parent linkage is consumed from the JSONL path, not from a top-level field. (There is no on-disk top-level `messageCount` to consume — Engram recomputes it; see §5.)

---

## 15. Lineage, gotchas, version drift & edge cases

### Shared-format lineage with sibling tools

Gemini CLI's `~/.gemini/tmp/<projectDir>/chats/session-*.json` + `projects.json` `cwd→name` map is a **Google-ecosystem family schema** shared by forks:

- **Qwen Code** (`src/adapters/qwen.ts` / `QwenAdapter.swift`, root `~/.qwen/`) and **iFlow** (`~/.iflow/`) are Gemini-CLI forks reusing the same `tmp/<dir>/chats/` + `projects.json` layout, the `user`/`gemini|model`/`info` taxonomy, and `[{text}]` content blocks. The Gemini adapter is effectively the template for those siblings.
- **Originator-based dispatch detection** is a cross-adapter convention shared with **Codex** (`CodexAdapter` reuses `OriginatorClassifier.isClaudeCode`), so a Gemini/Qwen/Codex session launched *by* Claude Code is uniformly tagged `agentRole='dispatched'` and tiered `skip`.
- The **`<sessionId>.engram.json` sidecar** (parent-link Layer 1c) is Engram's *own* deterministic convention written by `gemini-plugin-cc`, layered on top of Gemini's native files — not part of Gemini CLI's format.
- This family is **distinct** from the **VS Code `.vscdb`/leveldb family** (Cursor ↔ VS Code ↔ Copilot ↔ Cline) — different storage tech entirely; no lineage overlap.

### Gotchas / version drift / edge cases

1. **Format drift `.json` → `.jsonl` (source fixed; cleanup remains).** Confirmed (official): current Gemini CLI writes `.jsonl` for **all** new sessions (PR #23749, v0.39.0); single-object `.json` is read-only legacy migrated to `.jsonl` on resume. The `.jsonl` is an **event-sourced append log** (metadata record + per-turn `MessageRecord` appends + `$set` metadata deltas + `$rewindTo` truncations), NOT a full-snapshot `$set` log — it must be replayed line-by-line. Current Engram source does this, and the live DB now includes the Safeline `.jsonl`; the remaining DB work is historical row/file-index cleanup plus one stale count snapshot on the rich legacy Surge `.json`. [PR #23749](https://github.com/google-gemini/gemini-cli/pull/23749), [chatRecordingService.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatRecordingService.ts)
2. **`cwd` resolution must prefer `.project_root`.** Confirmed (official): Gemini CLI does not write or read `~/.gemini/projects.json`; the per-project dir is **always** the 64-hex SHA-256 of the project root path (`getProjectHash`), and the only on-disk cwd record is `tmp/<hash>/.project_root`. Current Engram source now reads `.project_root` first and only falls back to a plugin/launcher-created `projects.json` reverse lookup, then to the raw project dir. [paths.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/utils/paths.ts)
3. **`messageCount` semantics.** Engram's count = user+assistant non-empty only; it does NOT equal raw `messages.length` (which includes `info`/empty turns). Gemini stores **no** top-level `messageCount` on disk (§5); Engram recomputes it. `info`-only sessions report `0`.
4. **Historical DB count drift.** Current Swift and TS source both filter empty-content messages before counting, and stream output also skips empty text. Existing DB rows can still show older counts until rescanned; the live `surge` rich `.json` has 4 raw messages but current parser returns 3 countable turns.
5. **Originator normalization drift.** Swift requires `claude-code` (normalizes `_`/space→`-`); TS requires `claudecode` (strips all spaces/dashes). Both accept `"Claude Code"` / `"claude-code"`; punctuation-laden edge forms could diverge.
6. **Tokens only in the Swift product path.** Gemini token usage/cost is unavailable through the TS reference adapter; the parity fixture (all-zero `usageTotals`) masks this.
7. **`model` always nil.** Engram cannot report which Gemini model (e.g. `gemini-3.1-pro-preview`) produced a session even though it's on every assistant message.
8. **Size cap differs Swift vs TS (10 MB vs 100 MB).** The TS reference adapter skips files > **10 MB** (`MAX_SESSION_JSON_BYTES`, `gemini-cli.ts:33`); the Swift product adapter skips files > **100 MB** (`ParserLimits.default.maxFileBytes = 100*1024*1024`, `ParserLimits.swift:17`) — a 10× larger cap, enforced via `GeminiCliAdapter.readJSONObject` → `JSONLAdapterSupport.prepareFile` → `limits.validateFileSize` → `ParserLimits.swift:48` (`sizeBytes > maxFileBytes ? .fileTooLarge`). The live 201.8 KB session is far under both; a 10–100 MB session is dropped by TS but kept by Swift, and only > 100 MB is dropped by both. Swift additionally caps per-line bytes (8 MB, `maxLineBytes`) and message count (10,000, `maxMessages`); TS has neither. This is another Swift-vs-TS divergence (cf. tokens #6, originator #5).
9. **Native subagent lineage is path-based and now consumed by Engram.** Confirmed (official): Gemini CLI records `kind: 'main' | 'subagent'` and stores subagent sessions in a subdirectory named after the `parentSessionId` (filename `<sanitizedSessionId>.jsonl`), so native parent→child linkage IS on disk. Current Engram recursively discovers JSONL files under `chats/` and maps `chats/<parentSessionId>/<sanitizedSessionId>.jsonl` to `agentRole=subagent` plus `parentSessionId`. No native nested subagent file or `*.engram.json` sidecar exists on this machine in the latest smoke, so live DB has no current Gemini subagent rows yet. [chatRecordingService.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatRecordingService.ts), [chatRecordingTypes.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatRecordingTypes.ts)
10. **File-identity guard (Swift only).** Swift readers throw `fileModifiedDuringParse` if the file changes mid-read; an actively-appended session (common for live `.jsonl` deltas) can fail this and be retried later.
11. **`projectHash` = dir name; both are SHA-256 of the project root path.** Confirmed (official): the per-project dir name IS `getProjectHash(projectRoot) = sha256(projectRoot).digest('hex')`, so for a genuine Gemini CLI dir the dir name equals the in-file `projectHash` (the live `surge`/`cf46ca80…` mismatch is because `surge` is a launcher-supplied non-hash alias, not a Gemini CLI dir name). The hash is over the project root **path string** and is one-way (no inverse); cwd recovery must read `.project_root`. Engram sidesteps all of this by using the dir-name path component. [paths.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/utils/paths.ts)

### Resolved confirmations / remaining unknowns

- ~~Add `.jsonl` discovery and event-replay parsing to Engram~~ **RESOLVED in current source** — Swift and TS now discover `.jsonl`, replay `$set` and `$rewindTo`, and have focused tests. Remaining issue is installed/runtime rescan state, not parser shape. [PR #23749](https://github.com/google-gemini/gemini-cli/pull/23749), [Issue #15292](https://github.com/google-gemini/gemini-cli/issues/15292)
- **Confirmed (official):** there is no alias-vs-hash rule — `tmp/<projectDir>` is **always** `getProjectHash(projectRoot) = sha256(projectRoot).digest('hex')`, computed over the project root **path string** (not a git root). Human-readable dir names are launcher artifacts, not Gemini CLI behavior. [paths.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/utils/paths.ts)
- **Confirmed (official):** hashed-dir → cwd is intentionally **one-way** in Gemini CLI (`getProjectHash` has no inverse, and there is no `projects.json` registry). The hash→path mapping does not exist; the correct reverse source is `tmp/<dir>/.project_root`. [paths.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/utils/paths.ts)
- **Confirmed (official):** Gemini CLI **does** garbage-collect old transcripts. `cleanupExpiredSessions` runs at CLI startup and deletes sessions exceeding configurable `general.sessionRetention` (`enabled`, `maxAge`, `maxCount`, `minRetention`; default `maxAge` is `"30d"`), removing session files and associated artifacts. No archive dir because expired transcripts are deleted, not archived. [session-management.md](https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/session-management.md), [gemini.tsx](https://github.com/google-gemini/gemini-cli/blob/main/packages/cli/src/gemini.tsx), [sessionCleanup.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/cli/src/utils/sessionCleanup.ts)
- ~~Confirm the 8-hex filename suffix is `sessionId[0:8]`~~ **RESOLVED** — confirmed across all 3 current live files (2 `.json` + 1 `.jsonl`; see §2 naming grammar). Still open: whether 32-hex message ids (`.jsonl`) vs UUID (`.json`) is a deliberate format change (web-checked again 2026-07-02: no authoritative source found — the official code path is `id || randomUUID()`, which yields hyphenated UUIDs, so the live 32-hex ids are likely a launcher/transformed id, not a Gemini CLI design change). [chatRecordingService.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatRecordingService.ts)
- **Confirmed (official):** `gemini`/`info` (and `error`/`warning`) `content` **can** be an array — `content` is `PartListUnion` (`string | Part | Part[]`) for every record, not just `user`, and may carry non-`text` parts. [chatRecordingTypes.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatRecordingTypes.ts)
- **Confirmed (official):** `toolCalls[].status` is the scheduler `Status` union (`validating`/`scheduled`/`executing`/`success`/`error`/`cancelled`/`awaiting_approval`), not the UI `ToolCallStatus` enum; `error`/`cancelled` are real stored values. The exact union was fetched from `packages/core/src/scheduler/types.ts` on 2026-07-02. [chatRecordingTypes.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatRecordingTypes.ts), [scheduler/types.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/scheduler/types.ts), [cli ui/types.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/cli/src/ui/types.ts)
- Complete sidecar (`*.engram.json`) field set is unverified from real data (only `parentSessionId`/`originator` read by Engram; the plugin writer may emit more). *(Engram-internal design — not web-verifiable.)*
- **Confirmed (official):** other `kind` values exist — `kind?: 'main' | 'subagent'`. `subagent` sessions are stored in a `parentSessionId`-named subdirectory as `<sanitizedSessionId>.jsonl` (native parent/child lineage; see [§10](#10-subagent--parent-child--dispatch)). [chatRecordingTypes.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatRecordingTypes.ts), [chatRecordingService.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatRecordingService.ts)

---

## 16. Appendix: real anonymized samples

> Structure/keys verbatim; message text, code, secrets, and personal paths stripped.

### 16.1 Legacy `.json` session document (top-level envelope + messages)

```json
{
  "kind": "main",
  "sessionId": "75cb965e-3678-4982-8cdb-e2ea8d31fd90",
  "projectHash": "cf46ca80ac87adfa400209bdfbe4e330881b8f6c1fd032bbbe5959167a16206b",
  "startTime": "2026-04-08T03:22:00.000Z",
  "lastUpdated": "2026-04-08T03:40:00.000Z",
  "messages": [
    { "id": "<uuid>", "timestamp": "2026-04-08T03:26:59.220Z", "type": "user",
      "content": [ { "text": "<user prompt>" } ],
      "displayContent": [ { "text": "<rendered prompt>" } ] },
    { "id": "<uuid>", "timestamp": "2026-04-08T03:27:10.000Z", "type": "gemini",
      "model": "gemini-3.1-pro-preview",
      "content": "<assistant final answer>",
      "thoughts": [ { "subject": "<heading>", "description": "<reasoning>", "timestamp": "2026-04-08T03:27:05.000Z" } ],
      "tokens": { "input": 60823, "output": 10, "cached": 0, "thoughts": 1664, "tool": 0, "total": 62497 },
      "toolCalls": [ /* see 16.3 */ ] }
  ]
}
```

### 16.2 `info`-only session (yields messageCount 0)

```json
{
  "kind": "main",
  "sessionId": "bcf966c3-0612-41b8-aa4a-e95da1e86144",
  "projectHash": "cf46ca80ac87adfa400209bdfbe4e330881b8f6c1fd032bbbe5959167a16206b",
  "startTime": "2026-04-13T07:47:26.014Z",
  "lastUpdated": "2026-04-13T07:47:26.238Z",
  "messages": [
    { "id": "ad874a74-35b8-...-76fb", "timestamp": "2026-04-13T07:47:26.238Z",
      "type": "info", "content": "<info / system notice text>" }
  ]
}
```

### 16.3 `toolCalls[]` element with inline result (layer 3 → 4)

```json
{
  "id": "read_file-1712547432000-abcd",
  "name": "read_file",
  "displayName": "ReadFile",
  "description": "<call description>",
  "args": { "file_path": "<path>" },
  "status": "success",
  "timestamp": "2026-04-08T03:27:12.986Z",
  "renderOutputAsMarkdown": true,
  "resultDisplay": "<rendered result>",
  "result": [
    { "functionResponse": {
        "id": "read_file-1712547432000-abcd",
        "name": "read_file",
        "response": { "output": "<tool output text>" }
    } }
  ]
}
```

### 16.4 Newer `.jsonl` session (event-sourced append log)

Line 1 = initial metadata record; subsequent lines = full `MessageRecord` appends (one per turn), `{"$set": …}` metadata deltas, and `{"$rewindTo": …}` truncations. State = replay all lines (NOT last-line-wins).

```jsonl
{"kind":"main","sessionId":"b6a60539-...","projectHash":"<64hex>","startTime":"2026-06-21T01:33:00.000Z","lastUpdated":"2026-06-21T01:33:00.000Z"}
{"id":"<32hex>","timestamp":"2026-06-21T01:33:05.000Z","type":"user","content":[{"text":"<user prompt>"}]}
{"id":"<32hex>","timestamp":"2026-06-21T01:33:09.000Z","type":"gemini","content":"<assistant reply>","tokens":{"input":100,"output":20,"cached":0,"thoughts":0,"tool":0,"total":120}}
{"$set":{"lastUpdated":"2026-06-21T01:33:09.000Z","summary":"<derived summary>"}}
{"$rewindTo":"<messageId>"}
```

### 16.5 `projects.json` (global cwd → name map)

```json
{ "projects": { "/Users/test/my-project": "my-project", "/Users/test/other": "other-project" } }
```

### 16.6 `<projectDir>/logs.json` row (auxiliary telemetry; ignored)

```json
{ "sessionId": "75cb965e-3678-4982-8cdb-e2ea8d31fd90", "messageId": 0, "type": "user", "message": "<message text>", "timestamp": "2026-04-08T03:26:59.220Z" }
```

### 16.7 `<sessionId>.engram.json` sidecar (Layer 1c parent link; adapter-only, none live)

```json
{ "parentSessionId": "<claude-code-session-uuid>", "originator": "claude-code" }
```

### 16.8 `<projectDir>/.project_root` (auxiliary; consumed for cwd)

```
/Users/<user>/-NetWork-/Surge
```

---

## 17. References (official sources)

Web confirmation refreshed 2026-07-02. Sources cross-checked against the official Gemini CLI repo and the project docs.

- [google-gemini/gemini-cli — chatRecordingService.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatRecordingService.ts) — session store reader/writer (record taxonomy, subagent dir nesting, `id || randomUUID()`).
- [google-gemini/gemini-cli — chatRecordingTypes.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatRecordingTypes.ts) — record/field type defs (`type` union, `content: PartListUnion`, `summary`, `memoryScratchpad`, `directories`, `kind: 'main' | 'subagent'`, `$set`/`$rewindTo`, `ToolCallRecord.status`).
- [google-gemini/gemini-cli — scheduler/types.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/scheduler/types.ts) — persisted scheduler `Status` union for tool calls.
- [google-gemini/gemini-cli — paths.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/utils/paths.ts) — `getProjectHash` = `sha256(projectRoot).digest('hex')` (one-way; no `projects.json`).
- [google-gemini/gemini-cli — cli ui/types.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/cli/src/ui/types.ts) — UI-layer `ToolCallStatus` enum (distinct from the persisted scheduler `Status`).
- [google-gemini/gemini-cli — Session management docs](https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/session-management.md) — default 30-day `sessionRetention` policy and `enabled`/`maxAge`/`maxCount`/`minRetention` config.
- [google-gemini/gemini-cli — gemini.tsx](https://github.com/google-gemini/gemini-cli/blob/main/packages/cli/src/gemini.tsx) and [sessionCleanup.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/cli/src/utils/sessionCleanup.ts) — startup cleanup invocation and session/artifact deletion path.
- [PR #23749 — feat(core): migrate chat recording to JSONL streaming](https://github.com/google-gemini/gemini-cli/pull/23749) — `.json` → append-only `.jsonl` migration (v0.39.0).
- [Issue #15292 — Switch to JSONL for chat session storage](https://github.com/google-gemini/gemini-cli/issues/15292) — motivation for the JSONL switch.
- [Gemini CLI docs — Checkpointing](https://google-gemini.github.io/gemini-cli/docs/cli/checkpointing.html) — `tmp/<project_hash>/` layout.
