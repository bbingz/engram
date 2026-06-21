# Qwen Code — Session Format Reference

Last researched: 2026-06-21 (Engram session-format research workflow)

> Definitive English reference for how **Qwen Code** (Alibaba's Gemini-CLI fork)
> persists its sessions on disk, and how Engram's `QwenAdapter` (Swift product +
> TypeScript reference) consumes them. Qwen Code is a **fork of Google's Gemini
> CLI**, but its on-disk transcript is a **hybrid**: it keeps Gemini's
> `message.parts[].text` content body, yet wraps every record in a
> **Claude-Code-style per-line JSONL envelope** (`uuid`/`parentUuid`/`cwd`/
> `gitBranch`/`version`/`sessionId`/`timestamp`/`type`), one record per line —
> *not* Gemini's single-object `.json` or `$set`-mutation `.jsonl`. This doc is
> self-contained; for the shared lineage and where Qwen diverges, cross-reference
> [`docs/session-formats/gemini-cli.md`](./gemini-cli.md) (sibling) and
> [`docs/session-formats/codex.md`](./codex.md) (envelope cousin).

**Evidence basis (this doc).** Three sources cross-checked; on conflict REAL data wins, discrepancy flagged.

1. **LIVE on-disk store** — `~/.qwen/` on this machine (CONFIRMED present). **744 `.jsonl` session transcripts** under `~/.qwen/projects/<encodedCwd>/chats/` across **42 project dirs**, plus **16 `~/.qwen/tmp/<64-hex>/` dirs** of which **15 hold a `logs.json`** (telemetry, no transcripts) and **1 holds none**. **No `~/.qwen/projects.json`** (CONFIRMED absent — a key divergence from Gemini). The live `~/.qwen` root also carries **session-keyed non-transcript artifacts** the adapter ignores: `debug/<sessionId>.txt` (**750 live** per-session INFO/DEBUG logs, filename stem == sessionId, 1:1 with a transcript) and `todos/<sessionId>.json` (`{sessionId, todos:[{content,id,status}]}`), plus global `memories/MEMORY.md`, `skills/<name>/`, and `settings.json.orig` (see [§14](#14-auxiliary-files-present-live-not-consumed)). *(Flag: a prior research note claimed 44 project dirs / 18 tmp dirs / 3 without logs.json; this live store shows **42 / 16 / 1** respectively — REAL data wins. The 744-transcript figure and absent `projects.json` are exact in both.)* CLI version spread on disk: `0.10.5` → `0.18.4` (sampled modal cluster `0.14.5`/`0.15.x`). Record-type census over sampled rich sessions: `system/ui_telemetry`, `tool_result`, `assistant`, `user`, `system/attribution_snapshot`, `system/slash_command` — all six types present. Model values seen: `qwen3.5-plus`, `qwen3.6-plus` (and `qwen3.7-plus` in usage ledgers).
2. **Repo fixtures** — `tests/fixtures/qwen/{sample.jsonl (758 B, 3 lines), schema_drift.jsonl (511 B, 2 lines)}` and `tests/fixtures/adapter-parity/qwen/{success.expected.json, input/-Users-test-my-project/chats/sample.jsonl}`. The iFlow sibling fixtures (`tests/fixtures/iflow/{sample.jsonl, schema_drift.jsonl}`) were also read for lineage contrast.
3. **Engram adapters (codified knowledge)** — Swift product parser `macos/Shared/EngramCore/Adapters/Sources/QwenAdapter.swift` (242 lines); TS reference parser `src/adapters/qwen.ts` (211 lines). Shared I/O helper `JSONLAdapterSupport` lives inside `macos/Shared/EngramCore/Adapters/Sources/CodexAdapter.swift`; parse caps in `macos/Shared/EngramCore/Adapters/ParserLimits.swift`.

**Headline discrepancy (REAL vs fixtures/adapter).** The repo fixtures are a **stale `v0.10.5` schema** — flat `user`/`assistant` records with `message.parts[].text` and a top-level `model`, no telemetry, no `tool_result`, no `usageMetadata`, no `thought` parts. **Live `v0.14+` data is far richer**: every assistant turn is interleaved with `system/ui_telemetry` rows (`qwen-code.api_response`/`tool_call`/`api_error`), `tool_result` records, `system/attribution_snapshot`, and `system/slash_command`; assistant `message.parts[]` carry `thought:true` and `functionCall` blocks; per-turn token usage lives in a **top-level `usageMetadata`** object. The adapter handles the live forms structurally (it filters by `type`, extracts only `text` parts, and mines telemetry), so most live richness is **parsed-but-dropped** rather than mis-parsed. See [§15](#15-lineage-gotchas-version-drift--edge-cases).

---

## 1. Overview & TL;DR

**What / where / how.** Qwen Code stores each chat as **one JSONL file per session** under `~/.qwen/projects/<encodedCwd>/chats/<sessionId>.jsonl`. Each line is one standalone JSON object representing one event (`user` / `assistant` / `tool_result` / `system`). It is **append-per-event**: new lines are added in chronological order; existing lines are never rewritten. There is **no SQLite, no leveldb, no gRPC cache**. Unlike Gemini CLI there is **no top-level session-envelope object** and **no global `projects.json` cwd→name map**: every record self-describes via `cwd`/`sessionId`/`timestamp`, and the `<encodedCwd>` directory name is the path-slugified absolute working directory.

**Mental model.** `session = file`; `line = event`. Records chain via `parentUuid → uuid` into an intra-session linked list (Claude-Code lineage), but Engram reads them linearly. `startTime` = first record's `timestamp`; `endTime` = last record's `timestamp`. The assistant record is the richest: it carries reasoning, the final answer, tool-call requests inline in `message.parts[]`, plus top-level `model`/`usageMetadata`/`contextWindowSize`.

**Lineage one-liner.** Envelope = **Claude Code** (`uuid`/`parentUuid`/`cwd`/`gitBranch`/`version`/`sessionId`/`timestamp`); message body = **Gemini CLI** (`message.parts[].text`, assistant `role:"model"`, `usageMetadata.promptTokenCount`/`candidatesTokenCount`). Root and directory naming diverge from Gemini: `~/.qwen/projects/<slug(cwd)>/` not `~/.gemini/tmp/<alias|hash>/`.

**ASCII layout / layering diagram.**

```
~/.qwen/                                       storage tech: append-only line-delimited JSON (JSONL) files
├── settings.json, settings.json.orig, oauth_creds.json, QWEN.md  ── CLI config (NOT session data; never read)
├── output-language.md, tip_history.json, installation_id   ── CLI config (never read)
├── memories/MEMORY.md                          ── global memory file (often empty; NOT a transcript; never read)
├── skills/<name>/                              ── installed skills (e.g. superpowers, fireworks-tech-graph) (never read)
├── debug/<sessionId>.txt                       ── per-session INFO/DEBUG log; SESSION-KEYED (stem == sessionId); never read  (750 live)
├── todos/<sessionId>.json                      ── per-session todo list { sessionId, todos:[{content,id,status}] }; SESSION-KEYED; never read
├── usage_record.jsonl                          ── per-session aggregate usage ledger (NOT per-session transcript; never read)
├── usage/token-usage-YYYY-MM.jsonl             ── per-request token ledger (never read)
├── tmp/<64-hex>/logs.json                      ── Gemini-style UI telemetry rows (most tmp dirs; NOT transcripts; never read)
└── projects/                                   ── transcript root  (adapter `projectsRoot`)
    └── <encodedCwd>/                            ── dash-encoded absolute cwd (e.g. -Users-bing--Code--engram)
        ├── meta.json                            ── { version, createdAt, updatedAt }            (ignored)
        ├── extract-cursor.json                  ── { updatedAt } OR { sessionId, processedOffset, updatedAt } (ignored)
        ├── memory/                              ── per-project memory dir (often empty)         (ignored)
        └── chats/
            └── <sessionId>.jsonl                ── one session = one JSONL file  ← Engram parses

  line layer 1  event envelope  { uuid, parentUuid, sessionId, timestamp, type, cwd, gitBranch?, version, ... }
  line layer 2    ├─ message       { role, parts[] }                          (user / assistant / tool_result)
  line layer 2    ├─ usageMetadata { promptTokenCount, candidatesTokenCount, ... }   (assistant, TOP-LEVEL)
  line layer 2    ├─ model, contextWindowSize                                  (assistant, TOP-LEVEL)
  line layer 2    ├─ systemPayload { uiEvent | snapshot | phase,rawCommand }   (system)
  line layer 2    └─ toolCallResult{ callId, status, resultDisplay, error?, errorType? }  (tool_result)
  line layer 3        ├─ parts[]   { text } | { text, thought:true } | { functionCall } | { functionResponse }
  line layer 3        └─ uiEvent   { event.name, input_token_count, output_token_count, cached..., thoughts..., tool..., ... }
```

**TL;DR for Engram engineers.** Engram globs `*.jsonl`, keeps `sessionId / cwd / model / startTime / endTime` (taken from the first qualifying record), flattens conversation text from **only** `user` + `assistant` records' `message.parts[].text` (joined with `\n\n` in Swift, `\n` in TS — a separator drift), counts user vs assistant, reclassifies system-injection `user` records (text starting `You are Qwen Code` or containing `<INSTRUCTIONS>`) into a `systemMessageCount`, and derives token usage from `usageMetadata` with a `system/ui_telemetry api_response` fallback (**Swift only**). It **drops**: the entire `tool_result` record type (`toolMessageCount` hard-coded `0`), all `system` rows except as a token side-channel, `parts[].thought`-flag (text leaks in), `parts[].functionCall`/`functionResponse`, `parentUuid`, `uuid`, `gitBranch`, `version`, `contextWindowSize`, `usageMetadata.{thoughtsTokenCount,totalTokenCount}`, the `<encodedCwd>` dir name (→ `project: nil`), and the per-project `meta.json`/`extract-cursor.json`/`memory/` plus the `tmp/*/logs.json` and `usage/*` ledgers. `parentSessionId`/`suggestedParentId`/`agentRole`/`originator` are all `nil` (no sidecar read). The **TS reference path additionally drops all token usage**.

---

## 2. On-disk layout & file naming

**Authoritative root** (both adapters): `~/.qwen/projects/` — `QwenAdapter.swift:9-11` (`.qwen/projects`), `qwen.ts:20` (`join(homedir(), '.qwen', 'projects')`). **CONFIRMED by live store** (744 `.jsonl` under `~/.qwen/projects/*/chats/`, 42 project dirs). Within each project dir, transcripts live under `chats/` (`QwenAdapter.swift:27`, `qwen.ts:36`). There is **no `~/.qwen/tmp/` transcript path** (Qwen's `tmp/<64-hex>/` holds only `logs.json` telemetry) and **no `~/.qwen/projects.json`** (Gemini's `cwd→name` map is absent — CONFIRMED).

| Path | Role | Storage tech |
|---|---|---|
| `~/.qwen/projects/` | session transcript root (adapter `projectsRoot`) | dir of per-project dirs |
| `~/.qwen/projects/<encodedCwd>/chats/<sessionId>.jsonl` | one session = one file | **append-only JSONL** (one event/line) — Engram parses |
| `~/.qwen/projects/<encodedCwd>/meta.json` | `{version,createdAt,updatedAt}` project marker | single JSON object (ignored) |
| `~/.qwen/projects/<encodedCwd>/extract-cursor.json` | cross-tool extraction cursor | single JSON object (ignored) |
| `~/.qwen/projects/<encodedCwd>/memory/` | per-project memory dir (often empty) | directory (ignored) |
| `~/.qwen/tmp/<64-hex>/logs.json` | Gemini-style UI telemetry rows | JSON array (**NOT a transcript; ignored**) |
| `~/.qwen/usage_record.jsonl` | per-session aggregate usage ledger | JSONL (NOT per-session transcript; never read) |
| `~/.qwen/usage/token-usage-YYYY-MM.jsonl` | per-request token ledger | JSONL (never read) |
| `~/.qwen/settings.json`, `oauth_creds.json`, `QWEN.md`, … | CLI config | JSON / md (never read) |

### Naming grammar

| Token | Grammar | Live examples | Notes |
|---|---|---|---|
| `<encodedCwd>` | **CONFIRMED from CLI source** ([`paths.ts` `sanitizeCwd`](https://raw.githubusercontent.com/QwenLM/qwen-code/main/packages/core/src/utils/paths.ts)): `sanitizeCwd(cwd) = normalizedCwd.replace(/[^a-zA-Z0-9]/g, '-')` (on Windows the path is lowercased first). EVERY non-alphanumeric char (`/`, `-`, `_`, `.`, …) → a single `-`; leading `/` → leading `-`; a separator adjacent to an existing dash/underscore yields a **doubled dash**. `getProjectDir()` = `~/.qwen/projects/<sanitizeCwd(cwd)>` ([`storage.ts`](https://raw.githubusercontent.com/QwenLM/qwen-code/main/packages/core/src/config/storage.ts)). | `-Users-bing--Code--engram` (= `/Users/bing/-Code-/engram`), `-Users-bing--Code--CCTV-Admin` (= `/Users/bing/-Code-/CCTV_Admin`), `-Users-bing--Code--CCTV-Admin--worktrees-god-components-split`, `-private-tmp` | **Lossy** (cannot distinguish original `-`/`_`/`/`/`.`). **Diverges from Gemini** (alias-or-SHA256 + `projects.json` map). The adapter **never decodes** it — it sets `project: nil` and reads `cwd` from the in-record `cwd` field instead, sidestepping the ambiguity. |
| session file | `<sessionId>.jsonl` where `sessionId` is a UUIDv4 | `66040f20-b88b-43f2-98b9-724dfb49856e.jsonl`, `94f245ff-ccc0-47cf-901d-4c43a50f9121.jsonl` | **Diverges from Gemini's** `session-<YYYY-MM-DDTHH-mm>-<8hex>.json`. Qwen's filename is the **bare full session UUID** — no timestamp, no `session-` prefix. Filename stem == in-file `sessionId` exactly (CONFIRMED live). |

> **Conflict / nuance (REAL wins).** The Gemini sibling doc and the Qwen *parity fixture* directory path imply a `session-*`/alias naming. Live Qwen uses neither: dir = encoded cwd, file = `<uuid>.jsonl`. The adapter's enumerator simply takes **every `*.jsonl`** under `chats/` (no `session-` prefix filter — contrast the Gemini/iFlow adapters), so the divergence is handled. `gemini-cli.md` §15 (which claims Qwen "reuses the same `tmp/<dir>/chats/` + `projects.json` layout") is **incorrect** and should be corrected: Qwen shares Gemini's *content shape*, not its *file layout*.

### Tree example (live, anonymized)

```
~/.qwen/
├── settings.json  settings.json.orig  oauth_creds.json  QWEN.md  usage_record.jsonl   # config + global ledger (ignored)
├── memories/MEMORY.md   skills/{superpowers,fireworks-tech-graph}/                  # global memory + skills (ignored)
├── debug/
│   └── 0061a40c-…-63e961b59159.txt                                # per-session INFO/DEBUG log; stem == sessionId  ← session-keyed, never read
├── todos/
│   └── 1e34a19c-…-2b9d34641eea.json                               # { sessionId, todos:[{content,id,status}] }  ← session-keyed, never read
├── usage/
│   └── token-usage-2026-06.jsonl                                  # per-request token ledger (ignored)
├── tmp/
│   └── 318082cf…d4e72/                                            # 64-hex project-hash dir (Gemini-fork remnant)
│       └── logs.json                                              # UI telemetry only (NOT a transcript; some tmp dirs lack it)  ← never visited
└── projects/
    ├── -Users-bing--Code--engram/                # <encodedCwd> = dash-encoded /Users/bing/-Code-/engram
    │   ├── meta.json                             # { "version":1, "createdAt":"…Z", "updatedAt":"…Z" }   (ignored)
    │   ├── extract-cursor.json                   # { "updatedAt":"…Z" }  (ignored)
    │   ├── memory/                               # per-project memory dir (often empty)   (ignored)
    │   └── chats/
    │       ├── 94f245ff-…-c6fb1c09d0e5.jsonl     # large: user+assistant+tool_result+telemetry
    │       └── 0fd5e56d-…-c1c09d0e5.jsonl        # small: user + system telemetry only (no assistant)
    ├── -Users-bing--Code--CCTV-Admin/
    │   └── chats/ …                              # 66040f20-… large rich session
    └── -private-tmp/
        ├── meta.json   memory/
        └── chats/ …
```

---

## 3. File lifecycle & generation

| Aspect | Behavior | Evidence |
|---|---|---|
| **Storage tech** | One JSONL file per session, **append-only** (one event object per line). No database/leveldb/gRPC cache. | live store; both adapters read line-by-line via `JSONLAdapterSupport.readObjects` (Swift) / `readLines` (TS) |
| **DB vs file** | File. One file = one `sessionId`; filename **is** the session UUID (stem == in-file `sessionId`). | filename grammar; live verification |
| **Append vs rewrite** | **Append.** Each event is one new JSON line appended in chronological order; existing lines are never rewritten. (Contrast Gemini's whole-object rewrite or `$set` snapshot.) | per-line `timestamp` monotonic; `parentUuid → uuid` chains lines into a linked list |
| **Linked list** | Records chain via `parentUuid → uuid`; first record has `parentUuid:null`. Engram ignores the chain (reads linearly). | live: each `parentUuid` == prior record's `uuid` |
| **Resume** | A resumed session keeps the same file/`sessionId` and appends further lines; `cwd`/`gitBranch`/`version` are re-stamped per line (so `version` can drift mid-file across CLI upgrades). `startTime` stays fixed; end advances. | per-line `version` field |
| **Rollover** | New session = new `<uuid>.jsonl` in the same `chats/`; no rotation/segmenting of an existing transcript. | one file per UUID |
| **Archive / cleanup** | No archive dir observed. Empty per-project `memory/` dirs and `meta.json`/`extract-cursor.json` markers persist. | live store |
| **Size cap (Engram)** | **Two divergent caps.** Swift skips files > **100 MB** (`maxFileBytes`, `ParserLimits.swift:17`) → `.fileTooLarge` (`validateFileSize`, `ParserLimits.swift:47-49`). **TS has no size cap** — it streams the whole file unbounded via `readline` (`qwen.ts:165-179`). | `ParserLimits.swift:17,47-49`; `qwen.ts` (no cap) |
| **Other parse caps (Swift only) — SILENT for Qwen** | Per-line bytes capped at **8 MB** (`maxLineBytes`, `ParserLimits.swift:18`; enforced by `StreamingLineReader`, `CodexAdapter.swift:65`) and message count at **10,000** (`maxMessages`, `ParserLimits.swift:19`; `CodexAdapter.swift:71-74`). **Neither surfaces for Qwen.** `readObjects` only returns `.messageLimitExceeded`/the first line-reader failure when called with `reportFailures: true` (`CodexAdapter.swift:82-87`, default `false`), and **QwenAdapter calls `readObjects(locator:limits:)` WITHOUT `reportFailures`** (`QwenAdapter.swift:40,131`). So a >10,000-record Qwen session is **silently truncated** to the first 10,000 parsed objects (no `.messageLimitExceeded` raised), and a per-line >8 MB line is **silently skipped** (its failure is swallowed). TS has neither cap. | `ParserLimits.swift:18-19`; `CodexAdapter.swift:61,65,71-74,82-87`; `QwenAdapter.swift:40,131` |
| **Atomicity guard (Swift only)** | Swift snapshots file identity (size + mtime + resource-id) **before and after** the read; mismatch → `.fileModifiedDuringParse` → retried later. **This DOES surface for Qwen** — `fileModifiedDuringParse` is returned at `CodexAdapter.swift:79-80` and is **NOT gated by `reportFailures`** (unlike the message-limit/line failures). Likewise `.fileTooLarge` (pre-read, `prepareFile`/`validateFileSize`) surfaces. A live session being appended to during indexing is rejected and retried — common because Qwen appends continuously. | `CodexAdapter.swift:79-80`; `ParserLimits.swift:26-45` |
| **FD-leak guard (TS only)** | `readLines` wraps the readline loop in try/finally to close the fd even on early `break` (limit/offset), avoiding EMFILE when indexing many sessions. | `qwen.ts:165-179` |
| **Whole-file load (both)** | Even `streamMessages` loads ALL lines into memory first (Swift `readObjects` then `applyWindow`, `QwenAdapter.swift:131-133`; TS `readLines` re-reads the whole file per call, `qwen.ts:131`). Qwen does **not** use the O(offset+limit) `windowedMessages` streaming helper that Codex uses → O(file) per page for large sessions. | `QwenAdapter.swift:131-133`; `qwen.ts:131-155` |

**Engram discovery / enumeration** (`listSessionLocators()` Swift:22-36 / `listSessionFiles()` TS:32-51):
1. `detect()` — true iff `~/.qwen/projects` is a directory (Swift:18-20, TS:23-30).
2. Enumerate **direct children** of `projects/` that are directories (each = a `<encodedCwd>`) — `JSONLAdapterSupport.directChildren` (`CodexAdapter.swift:15-26`) skips hidden entries and symlinks and returns them path-sorted.
3. For each, require a `chats/` subdirectory; skip projects without one (Swift:27-28, TS:36-44 — TS catches the readdir error).
4. Within `chats/`, emit files where **`pathExtension == "jsonl"`** (Swift:30) / **`endsWith('.jsonl')`** (TS:40). **No `session-` prefix filter** (contrast Gemini/iFlow).
5. Swift returns the list **sorted** (`locators.sorted()` Swift:35); TS yields lazily in `readdir` order.

---

## 4. Record / line taxonomy

One file = an ordered sequence of JSON objects, one per line. The top-level `type` (and, for `system`, `subtype`) discriminates. **Observed live:** `user`, `assistant`, `tool_result`, `system/ui_telemetry`, `system/attribution_snapshot`, `system/slash_command`. The stale fixtures contain only `user`/`assistant`; `schema_drift.jsonl` adds forward-compat junk (`futureField`, an unknown part `{type:"new_part",data}`, `responseMetadata`) to prove the adapter ignores unknown keys.

> **Confirmed (official): the `system` `subtype` enum is much larger than the 3 observed live.** The `ChatRecord` schema in [`chatRecordingService.ts`](https://raw.githubusercontent.com/QwenLM/qwen-code/main/packages/core/src/services/chatRecordingService.ts) defines: `chat_compression`, `slash_command`, `ui_telemetry`, `at_command`, `attribution_snapshot`, `notification`, `cron`, `mid_turn_user_message`, `custom_title`, `rewind`, `agent_bootstrap`, `agent_launch_prompt`, `file_history_snapshot`. The live-observed 3 are a subset. This does not change Engram's behavior (all `system` rows are dropped except `ui_telemetry/api_response` token mining), but note that `chat_compression` exists as a compaction record (see §12).

| `type` (`subtype`) | `message.role` | Purpose | Role in Engram | Counted? |
|---|---|---|---|---|
| `user` | `user` | User turn (`message.parts[].text`) OR a **system-injected** prompt (`You are Qwen Code…` / `<INSTRUCTIONS>`) OR a slash-command echo | `role:user` — UNLESS injection-detected → reclassified `system` | yes (user count), unless injection → system count |
| `assistant` | `model` | Assistant turn — richest: top-level `model`/`usageMetadata`/`contextWindowSize`, `message.parts[]` with `text`/`thought`/`functionCall` | `role:assistant`; token usage harvested | yes (assistant count) |
| `tool_result` | `user` | One tool's execution result (`toolCallResult` + `message.parts[].functionResponse`) | **dropped entirely** | **no** (`toolMessageCount` hard-coded 0) |
| `system` / `ui_telemetry` | (none) | Telemetry rows in `systemPayload.uiEvent`; `event.name` ∈ {`qwen-code.api_response`, `qwen-code.tool_call`, `qwen-code.api_error`} | **token side-channel only** (Swift mines `api_response`; ignores `tool_call`/`api_error`) | **no** |
| `system` / `attribution_snapshot` | (none) | Git/file-attribution snapshot (`systemPayload.snapshot`) | dropped | **no** |
| `system` / `slash_command` | (none) | Slash-command marker (`systemPayload.{phase,rawCommand}`, e.g. `/init`, `/model`, `/exit`) | dropped | **no** |

**Filtering rule (both adapters):** the `parseSessionInfo` scan and `message()`/`streamMessages` loops accept **only** `type == "user" || type == "assistant"` for conversation (Swift:54-58, 159-163; TS:71, 137). Every other `type` (`tool_result`, all `system`, unknown) is skipped for content. `system/ui_telemetry` rows are inspected separately, **but only for token telemetry** (Swift `telemetryUsage` :174-196; TS does not inspect them at all). `toolMessageCount` is therefore always `0`; `systemMessageCount` counts only **injection-reclassified user lines**, NOT the raw `type:"system"` records (a misleading name — see §15 gotcha 7).

> **System-injection sub-classification.** A `user` record whose flattened text starts with `\nYou are Qwen Code` / `You are Qwen Code`, or contains `<INSTRUCTIONS>`, is reclassified as **system** (counted in `systemMessageCount`, excluded from `userMessageCount`, and not eligible to become the summary). — `isSystemInjection` Swift:222-226 / TS:157-163.

> **`role` vs `type`.** The inner `message.role` for `assistant` records is `"model"` (Gemini convention; never `"assistant"` live), and `tool_result.message.role` is `"user"`. Engram derives role from the **top-level `type`**, ignoring `message.role`. This matters because `tool_result` records carry `message.role:"user"` — they are excluded by the `type` filter, not by role, so they do NOT inflate the user count. (The `schema_drift.jsonl` fixture uses `role:"assistant"` and still parses, since role is unread.)

---

## 5. Shared envelope / per-line metadata fields (line layer 1)

Top-level keys per record. There is **no top-level session-envelope object** (unlike Gemini's `{sessionId, startTime, messages[]}`); session-level facts are derived from the first qualifying record. Verified live keys on an assistant line: `contextWindowSize, cwd, gitBranch, message, model, parentUuid, sessionId, timestamp, type, usageMetadata, uuid, version`. On a user line: `cwd, gitBranch, message, parentUuid, sessionId, timestamp, type, uuid, version`.

| Field | Type | Meaning | Optional | Consumed? | Example (anonymized) |
|---|---|---|---|---|---|
| `sessionId` | string (UUID) | Stable session identity; Engram primary key; equals the filename stem | **required** (else `malformedJSON`/null) | ✅ → `id` | `"94f245ff-ccc0-47cf-901d-4c43a50f9121"` |
| `timestamp` | string (ISO-8601 ms, UTC `Z`) | When this record was produced | **required** | ✅ → `startTime` (first) / `endTime` (last) + per-msg | `"2026-04-23T02:11:16.630Z"` |
| `type` | string | Record discriminator (§4) | **required** | ✅ (drives role + counts) | `"assistant"` |
| `subtype` | string | Sub-discriminator for `type:"system"` | optional (system only) | ✅ (telemetry gate, Swift) | `"ui_telemetry"` |
| `cwd` | string (abs path) | Working directory at record time | present live | ✅ → `cwd` | `"/Users/<u>/-Code-/engram"` |
| `uuid` | string (UUID) | Per-record id; target of next record's `parentUuid` | **required** live | ❌ | `"343c57f5-c8b2-478b-ac7f-ebe2fe861adf"` |
| `parentUuid` | string\|null | Back-pointer to the previous record's `uuid` (linked list; `null` on first) | **required** live | ❌ | `"534fe31e-582b-473a-a444-d14bb943e807"` / `null` |
| `gitBranch` | string | Active git branch at record time | **optional** (omitted on a minority of records — ~800 of ~4900 in a whole-store census) | ❌ | `"main"` |
| `version` | string (semver) | Qwen Code CLI version that wrote the record | present live | ❌ | `"0.15.0"` (live range `0.10.5`…`0.18.4`) |
| `model` | string | **Assistant only:** model id (TOP-LEVEL) | assistant only | ✅ → session `model` | `"qwen3.6-plus"` |
| `usageMetadata` | object | **Assistant only:** per-turn token usage (TOP-LEVEL) (§9) | assistant only (rarely absent) | ✅ (Swift only) | `{ promptTokenCount: 17297, … }` |
| `contextWindowSize` | int | **Assistant only:** model context window | assistant only | ❌ | `1000000` (only value seen) |
| `message` | object | `{role, parts[]}` payload | user/assistant/tool_result | ✅ (user/assistant only) | `{ "role":"model", "parts":[…] }` |
| `systemPayload` | object | Payload for `system` records (§10) | system only | partial (Swift, `uiEvent` telemetry only) | `{ "uiEvent": {…} }` |
| `toolCallResult` | object | `tool_result` only (§7) | tool_result only | ❌ | `{ callId, status, resultDisplay }` |

> **Session-level derivation (Engram).** `sessionId`, `cwd`, `model`, `startTime` are taken from the **first** `user`/`assistant` record that has each field; `endTime` = last `user`/`assistant` record's `timestamp` (Swift:60-74, TS:73-82). `model` is read **top-level only** in Swift (`object["model"]`, :66); TS additionally falls back to `message.model` (`qwen.ts:79-82`) — but live `model` is reliably top-level on assistant records, so the two converge and TS's `msg.model` branch is **dead against current data** (see §15 gotcha + open question).

> **No on-disk `messageCount`.** No top-level count field exists; Engram **recomputes** `messageCount = userCount + assistantCount`. The parity fixture's `messageCount:3` is recomputed output, not a source field.

> **Divergence flags vs Gemini.** Qwen records carry per-line `uuid`/`parentUuid`/`gitBranch`/`version`/`cwd` (Claude-Code-style envelope) that Gemini's single-object/`$set` format lacks. Qwen has **no top-level envelope** object (no `kind`/`projectHash`/`startTime`/`lastUpdated`); session-level start/end are derived from first/last `timestamp`. None of the extra envelope fields except `cwd`/`timestamp`/`sessionId`/`model` are consumed.

---

## 6. Message & content schema (line layers 2–3)

### 6.1 `message` object (layer 2; on user / assistant / tool_result)

| Field | Type | Meaning | On types | Consumed? |
|---|---|---|---|---|
| `role` | string | `"user"` (user & tool_result) / `"model"` (assistant; drift fixture also uses `"assistant"`) | all | ❌ (Engram derives role from top-level `type`, not `message.role`) |
| `parts` | array<object> | Ordered content blocks (§6.5) | all | ✅ (only `.text` kept) |

`extractContent` reads `message.parts[]`, keeps each element's non-empty `.text`, joins them — **`\n\n`** (Swift:240) / **`\n`** (TS:203). See §8 for the reasoning-leak caveat.

### 6.2 `type:"user"` record

`message.parts[]` is a **single `[{text}]` part in text-only sessions** (no `displayContent`, unlike Gemini), but the schema **permits multipart / non-`text` parts**: `recordUserMessage` accepts a `@google/genai` `PartListUnion` and wraps it via `createUserContent`, so a user record's `parts` can in principle carry multiple parts and non-text kinds (notably `inlineData` for image/attachment input) — [`chatRecordingService.ts`](https://raw.githubusercontent.com/QwenLM/qwen-code/main/packages/core/src/services/chatRecordingService.ts). `extractContent` keeps only `.text`, so it would silently drop any `inlineData` part. Three flavors of user text, all stored identically on disk:

| Flavor | Detection | Engram handling |
|---|---|---|
| Real user prompt | default | counted as user; first one → `summary` (`prefix(200)`) |
| System injection | text starts with `"You are Qwen Code"` (±leading `\n`) OR contains `"<INSTRUCTIONS>"` | counted as **system** (`systemMessageCount`), not user; not eligible as summary |
| Slash-command echo | text is e.g. `/model`, `/exit` (also mirrored as `system/slash_command`) | counted as user (no special handling) |

```json
{
  "uuid": "0b7d3ecc-…-dbc39a20e637", "parentUuid": null,
  "sessionId": "9ac9a7c3-…-2ce24fc677d6",
  "timestamp": "2026-04-23T00:39:48.359Z", "type": "user",
  "cwd": "/Users/<u>/-Code-/engram", "version": "0.15.0", "gitBranch": "main",
  "message": { "role": "user", "parts": [ { "text": "<user prompt>" } ] }
}
```

### 6.3 `type:"assistant"` record — richest record

| Field | Type | Meaning | Optional | Consumed? |
|---|---|---|---|---|
| `model` | string | Model that produced the turn (top-level) | required (assistant) | ✅ (session `model`) |
| `message.parts` | array | Mixed: reasoning (`thought:true`), final text, tool calls (`functionCall`) (§6.5) | required | ✅ (text + thought-text joined) |
| `usageMetadata` | object | Per-turn token usage (§9) | optional | ✅ (Swift) |
| `contextWindowSize` | int | Model context window | optional | ❌ |

```json
{
  "uuid": "343c57f5-…", "parentUuid": "534fe31e-…",
  "sessionId": "94f245ff-…", "timestamp": "2026-04-23T02:11:28.063Z",
  "type": "assistant", "cwd": "/Users/<u>/-Code-/engram",
  "version": "0.15.0", "gitBranch": "main", "model": "qwen3.6-plus",
  "contextWindowSize": 1000000,
  "usageMetadata": { "promptTokenCount": 17297, "candidatesTokenCount": 533,
    "thoughtsTokenCount": 20, "totalTokenCount": 17830, "cachedContentTokenCount": 0 },
  "message": { "role": "model", "parts": [
    { "text": "<reasoning>", "thought": true },
    { "text": "<assistant answer>" },
    { "functionCall": { "id": "call_44de…", "name": "read_file", "args": { "absolute_path": "<path>" } } }
  ] }
}
```

### 6.4 `type:"tool_result"` record

See §7 for the full field breakdown and the success/error variants. `message.role` is `"user"`, so the top-level `type` filter (not role) is what excludes it.

### 6.5 `parts[]` block kinds (layer 3)

Whole-store census of part shapes (sampled): assistant parts split among `[text,thought]`, `[text]`, `[functionCall]`; user parts are always `[text]`; tool_result parts are `[functionResponse]`. A single assistant turn can batch **many** `functionCall` parts (live example: one assistant record with 8 `functionCall` parts after a `[text,thought]` part).

| Block shape | Where | Meaning | Consumed? |
|---|---|---|---|
| `{ "text": "<string>" }` | user, assistant | Plain text turn / answer | ✅ (joined; `\n\n` Swift, `\n` TS) |
| `{ "text": "<string>", "thought": true }` | assistant | Reasoning text flagged as a thought | ✅ **text is kept** — Swift/TS only check for a non-empty `text` key, so reasoning text is folded into the assistant content (the `thought:true` flag is ignored). |
| `{ "functionCall": { id, name, args } }` | assistant | Tool invocation request | ❌ (no `text` key → skipped by `extractContent`) |
| `{ "functionResponse": { id, name, response } }` | tool_result | Tool return payload | ❌ (whole `tool_result` record dropped) |

**Extraction** (`extractContent` Swift:228-241 / TS:194-206): iterate `message.parts`, keep each element's non-empty `.text`, join. Blocks without a `text` key (`functionCall`/`functionResponse`) contribute nothing.

> **Coverage flag.** Because the only filter is "has a non-empty `text`", an assistant `thought` part's reasoning text **leaks into the normalized content** — Qwen does **not** strip reasoning the way the Gemini adapter drops its separate `thoughts[]` array. Conversely, an assistant turn whose `parts` are *only* `functionCall` flattens to **empty content** (still counted as an assistant turn — counted by `type`, not content).

```json
// assistant message.parts[] (anonymized) — mixed text / thought / functionCall
{ "role": "model", "parts": [
  { "text": "<reasoning>", "thought": true },
  { "text": "<assistant answer>" },
  { "functionCall": { "id": "call_44de…", "name": "read_file", "args": { "absolute_path": "<path>" } } }
] }
```

---

## 7. Tool calls & results

Unlike Gemini (where tool calls + results are co-located inside one assistant record's `toolCalls[]`), **Qwen uses a two-record model** (Claude-Code-style split), and Engram imports **neither**:

1. **Request** — an assistant `message.parts[]` element `{ functionCall: { id, name, args } }` (§6.5). A single assistant turn can batch many calls.
2. **Result** — a **separate `tool_result` record** later in the log, one per call, with `message.parts[0].functionResponse` + a top-level `toolCallResult` envelope.

**Linkage (verified live):** `functionCall.id === toolCallResult.callId === functionResponse.id`, and `functionCall.name === functionResponse.name`. Correlate by `id`/`callId` — **NOT** by `parentUuid` (which only chains adjacency). Live tool names seen: `read_file`, `list_directory`, `edit`, etc.

### 7.1 Assistant `functionCall` part (layer 3)

| Field | Type | Meaning | Optional | Example |
|---|---|---|---|---|
| `id` | string | Call id; = `tool_result.toolCallResult.callId` = `functionResponse.id` (linkage key) | required | `"call_44de19224c8b41328bbe5687"` |
| `name` | string | Tool name (snake_case) | required | `"read_file"` |
| `args` | object | Tool arguments; keys per-tool (e.g. `absolute_path` / `file_path`) | required | `{ "file_path": "<path>" }` |

### 7.2 `tool_result` record — `toolCallResult` envelope (layer 2) + `functionResponse` (layer 3)

Verified live `tool_result` keys: `{cwd, gitBranch, message, parentUuid, sessionId, timestamp, toolCallResult, type, uuid, version}`. `toolCallResult` keys (success): `{callId, resultDisplay, status}`; on error, adds `{error, errorType}`.

`toolCallResult`:

| Field | Type | Meaning | Optional | Example |
|---|---|---|---|---|
| `callId` | string | Links to the request's `functionCall.id` | required | `"call_44de19224c8b41328bbe5687"` |
| `status` | enum string | `"success"` \| `"error"` (both confirmed live) | required | `"success"` |
| `resultDisplay` | string | Human-render summary (empty on success; error text on error) | required | `"Read lines 1-419 of 475 …"` / `""` / `"File not found: …"` |
| `error` | object | Present on error (observed `{}` placeholder) | error only | `{}` |
| `errorType` | string | Error classification | error only | `"file_not_found"` (live also: `execution_denied`, `invalid_tool_params`, `unhandled_exception`, `edit_no_occurrence_found`) |

`message.parts[0].functionResponse` (deepest, layer 3):

| Field | Type | Meaning | Optional | Example |
|---|---|---|---|---|
| `id` | string | Matches `functionCall.id` / `callId` (linkage) | required | `"call_44de…"` |
| `name` | string | Tool name (matches request) | required | `"read_file"` |
| `response.output` | string | Actual tool output text (on success) | success | `"Showing lines 1-419 of 475 …"` |
| `response.error` | string | Error text (on failure) | error | `"File not found: <path>"` |

> **Coverage flag.** Engram discards `tool_result` **entirely** — the `type` filter excludes it, and `toolMessageCount` is hard-coded `0` (Swift:104, TS:111). The parity fixture confirms `toolCallCount: 0`, `fileToolCounts: {}`. Tool calls/results are fully on disk and linkable but invisible in Engram. Unlike Codex (which counts `function_call` into `toolMessageCount`), Qwen tool activity is invisible to Engram counts.

```json
// separate tool_result record (success):
{ "type": "tool_result", "uuid": "<uuid>", "parentUuid": "<uuid>", "sessionId": "<uuid>",
  "timestamp": "2026-04-23T02:11:28.503Z", "cwd": "<path>", "gitBranch": "main", "version": "0.15.0",
  "toolCallResult": { "callId": "call_44de…", "status": "success", "resultDisplay": "<rendered result>" },
  "message": { "role": "user", "parts": [ { "functionResponse": {
      "id": "call_44de…", "name": "read_file", "response": { "output": "<tool output text>" } } } ] } }

// tool_result record (error variant):
{ "type": "tool_result", "...": "...",
  "toolCallResult": { "callId": "call_f511ad84…", "status": "error",
      "resultDisplay": "File not found: <path>", "error": {}, "errorType": "file_not_found" },
  "message": { "role": "user", "parts": [ { "functionResponse": {
      "id": "call_f511ad84…", "name": "read_file", "response": { "error": "File not found: <path>" } } } ] } }
```

---

## 8. Reasoning / thinking

Qwen has **no separate `thoughts[]` array** (Gemini does). Reasoning is an **in-band** `parts[]` element on the assistant record: `{ "text": "<reasoning>", "thought": true }` (§6.5), preceding the final answer part(s). The reasoning **token count** is reported separately as `usageMetadata.thoughtsTokenCount` / `ui_telemetry.thoughts_token_count` (§9).

**Engram keeps the reasoning text** — `extractContent` joins every part with a non-empty `.text` and does **not** check `thought` (Swift:228-241, TS:194-206), so an assistant message's stored `content` = **reasoning text concatenated with the final answer**.

> **Lineage contrast / behavioral asymmetry.** Gemini stores reasoning in a separate top-level `thoughts[]` array that Engram **drops**; Qwen inlines reasoning into `parts` and Engram **keeps it**. So Engram's Qwen assistant content is "thoughts + answer", not just the answer — a real behavioral difference created purely by the format difference (flag this with maintainers: intended or a bug? — see §15 open questions).

```json
"parts": [
  { "text": "<chain-of-thought reasoning>", "thought": true },
  { "text": "<final user-visible answer>" }
]
```

---

## 9. Token usage & cost

Qwen exposes per-turn usage in **two places** — the Swift adapter reads both, preferring `usageMetadata`. (The **TS adapter reads neither** — it drops all token usage.)

### 9.1 Primary — top-level `usageMetadata` on the assistant record

Verified live keys: `{cachedContentTokenCount, candidatesTokenCount, promptTokenCount, thoughtsTokenCount, totalTokenCount}`. Read by `usage()` (Swift:198-213).

```json
{ "promptTokenCount": 17297, "candidatesTokenCount": 533, "thoughtsTokenCount": 20, "totalTokenCount": 17830, "cachedContentTokenCount": 0 }
```

| Field | Type | Meaning | Engram (Swift) mapping |
|---|---|---|---|
| `promptTokenCount` | int | Prompt/input tokens | `inputTokens` (used **as-is**, NOT cache-subtracted) |
| `candidatesTokenCount` | int | Completion tokens | `outputTokens` |
| `cachedContentTokenCount` | int | Cache-read tokens | `cacheReadTokens` |
| `thoughtsTokenCount` | int | Reasoning tokens | ❌ (not summed; unlike Gemini which folds thoughts into output) |
| `totalTokenCount` | int | Grand total | ❌ unused |

`cacheCreationTokens` is always `0` (Qwen reports no cache-creation count). **Confirmed (official): this is structurally permanent, not just unobserved.** `usageMetadata` is stored as-is from the Google GenAI `GenerateContentResponseUsageMetadata` type ([`chatRecordingService.ts`](https://raw.githubusercontent.com/QwenLM/qwen-code/main/packages/core/src/services/chatRecordingService.ts); [field reference](https://v03.api.js.langchain.com/interfaces/_langchain_google_common.types.GenerateContentResponseUsageMetadata.html)) whose fields are `promptTokenCount`, `candidatesTokenCount`, `cachedContentTokenCount` (cache **read**), `thoughtsTokenCount`, `toolUsePromptTokenCount`, `totalTokenCount` (+ `*TokensDetails` breakdowns) — there is **no cache-creation field** in the schema, only `cachedContentTokenCount` (read). `usage()` returns `nil` if input+output+cacheRead are all 0; `user` records carry no usage (Swift:170).

### 9.2 Fallback — `system/ui_telemetry` `api_response` rows (Swift only)

A `type:"system"`, `subtype:"ui_telemetry"` row whose `systemPayload.uiEvent["event.name"] == "qwen-code.api_response"` is mined for tokens **only when the following assistant record lacks `usageMetadata`** (`telemetryUsage` Swift:174-196). Verified live `api_response` uiEvent keys: `{auth_type, cached_content_token_count, duration_ms, event.name, event.timestamp, input_token_count, model, output_token_count, prompt_id, response_id, status_code, thoughts_token_count, total_token_count}`.

**Mechanism (Swift `messages(from:)` :140-153):** telemetry rows appear **before** the assistant record they describe. The parser buffers `pendingTelemetryUsage`; a telemetry row sets it and is itself dropped (returns `nil` → not a message); the next assistant message takes `metadataUsage ?? telemetryUsage` (Swift:170) and clears the buffer (Swift:148-150).

| uiEvent field | → TokenUsage |
|---|---|
| `input_token_count` | `inputTokens` |
| `output_token_count` | `outputTokens` |
| `cached_content_token_count` | `cacheReadTokens` |

All other uiEvent fields (`thoughts_token_count`, `tool_token_count`, `total_token_count`, `duration_ms`, `model`, `response_id`, `prompt_id`, `auth_type`, `status_code`) are ignored. `cacheCreationTokens` is always `0`. Returns `nil` if all three derived counts are 0.

> **Live rarity.** Across sampled assistant turns, the overwhelming majority carry `usageMetadata`; the telemetry fallback almost never fires (it exists for older/edge sessions where `usageMetadata` is absent).

> **Telemetry `event.name` census (live, rich session):** `qwen-code.tool_call` (most common), `qwen-code.api_response`, `qwen-code.api_error` (rare). The adapter matches **only `api_response`** (Swift:179) — `tool_call`/`api_error` telemetry is ignored, so `api_error` turns' cost is currently unrecorded.

> **Discrepancy flags.**
> 1. **TS drops ALL token usage** — `qwen.ts` has no `usageMetadata`/telemetry handling. Swift is the only path producing Qwen cost/usage. (Same Swift-vs-TS split as Gemini.)
> 2. **Parity fixture masks it:** the stale fixture has no `usageMetadata`/telemetry, so `usageTotals` is all-zero and never exercises extraction. Real sessions DO populate usage.
> 3. **`thoughtsTokenCount` is NOT folded into output** for Qwen (Gemini folds `thoughts`+`tool` into output). Qwen's `outputTokens` = `candidatesTokenCount` only.
> 4. **No cache subtraction** (vs Gemini). Qwen Swift maps `promptTokenCount → inputTokens` directly (Swift:201); the Gemini Swift adapter does `inputTokens = max(input − cached, 0)`. So Qwen `inputTokens` **includes** cached tokens; Gemini's excludes them. Cross-source cost comparisons are inconsistent (apples-to-oranges).

No per-token price/cost is stored on disk; Engram computes cost downstream.

### 9.3 Other `ui_telemetry` event shapes (not consumed)

- **`qwen-code.tool_call`** — per-tool execution telemetry. Verified live keys: `{content_length, decision, duration_ms, event.name, event.timestamp, function_args, function_name, prompt_id, response_id, status, success, tool_type}` (`decision`: `auto_accept` seen; `tool_type`: `native` seen).
- **`qwen-code.api_error`** — `{error_message, error_type, model, duration_ms, prompt_id, response_id, auth_type, status_code?}` (e.g. `error_message: "Connection error. (cause: fetch failed)"`, `error_type: "APIConnectionError"`).
- A `subagent_name` field appears on some `api_response`/`tool_call` events (values like `general-purpose`, `managed-auto-memory-extractor`) — a dispatched-subagent marker Engram ignores.

---

## 10. `system` record payloads (auxiliary; mostly dropped)

| `subtype` | `systemPayload` shape | Meaning | Engram use |
|---|---|---|---|
| `ui_telemetry` | `{ uiEvent: { "event.name", "event.timestamp", model, status_code, duration_ms, input_token_count, output_token_count, cached_content_token_count, thoughts_token_count, tool_token_count?, total_token_count, response_id, prompt_id, auth_type, … } }` | Per-API-call / per-tool-call / per-error telemetry | token side-channel for `api_response` only (§9.2) |
| `attribution_snapshot` | `{ snapshot: { type:"attribution-snapshot", version:1, surface:"cli", promptCount, promptCountAtLastCommit, fileStates:{} } }` | Git/file attribution checkpoint | dropped |
| `slash_command` | `{ phase:"invocation", rawCommand:"/init" } ` (also `/model`, `/exit`) | Slash-command marker | dropped |

`system` records are excluded from all message counts (the `type` filter only counts `user`/`assistant`).

---

## 11. Subagent / parent-child / dispatch

- **In-file linkage:** Qwen's `parentUuid` chains **records within one session** into a linked list. It is a per-record back-pointer, **not** a cross-session parent link, and Engram does **not** read it.
- **Cross-session linkage (`parentSessionId`):** Qwen's native files contain **no** session-to-session parent linkage, and — unlike the Gemini adapter — the **Qwen adapter reads no `<sessionId>.engram.json` sidecar**. `parentSessionId`/`suggestedParentId`/`agentRole`/`originator` are hard-coded `nil` (Swift:110-117). There is no adapter-level originator/sidecar signal for Qwen (Gemini's Layer 1c deterministic sidecar + `originator` field are absent here).
- **Where attribution comes from (downstream, not the adapter):**
  - **Layer 2 heuristic** (dispatch-pattern + temporal/cwd scoring) → `suggested_parent_id`.
  - **`StartupBackfills.backfillPolycliProviderParents`** (per project `CLAUDE.md` → Agent Session Grouping) classifies Polycli-launched `qwen` provider sessions as `dispatched` → tier `skip` when the first user message is a health-ping / review-probe / stage-fact probe, or a same-cwd near-concurrent provider child.
  - **`SwiftIndexer.isSkippableFirstUserMessages`** skips known Polycli probe prompts (`ping`, `POLYCLI_HEALTH_OK`, `No tools. Review...`, `No tools. Stage ... facts...`).
- **Live evidence of dispatch context:** `qwen-plugin-cc*` / Polycli-probe project dirs, `system/slash_command` `/init` probes, and the in-transcript `subagent_name` telemetry field (§9.3, a hint Engram does not use for linking). So a Qwen session launched by Claude Code via Polycli is tiered `skip`, but that decision is made **outside** the adapter.

---

## 12. Summary / compaction

**No summary record consumed by Engram.** Engram synthesizes a session **summary** itself: the first **non-system-injection** `user` message's flattened text, capped at 200 chars (`String(firstUserText.prefix(200))` Swift:106; `firstUserText.slice(0, 200)` TS:113). Derived, not stored. Parity confirms `summary == firstUserSummary == "<first user text>"`.

> **Correction (official): the tool CAN emit a compaction record.** The `ChatRecord` `subtype` enum includes `chat_compression` ([`chatRecordingService.ts`](https://raw.githubusercontent.com/QwenLM/qwen-code/main/packages/core/src/services/chatRecordingService.ts)), a `type:"system"` compaction record. So this section's "no compaction record type" claim is only true for what Engram *consumes* — on disk a `system/chat_compression` record can exist (it was not observed in the sampled live store, and the `type` filter drops all `system` rows regardless). Engram still synthesizes its own summary.

---

## 13. SQLite / DB internals

**N/A for Qwen Code.** Sessions are plain append-only JSONL files; no SQLite, leveldb, or gRPC cache. (Distinct from the VS Code `.vscdb`/leveldb family — Cursor/VS Code/Copilot/Cline — which shares no lineage with Qwen.)

---

## 14. Auxiliary files (present live, NOT consumed)

| File | Shape | Example (anonymized) | Notes |
|---|---|---|---|
| `projects/<encodedCwd>/meta.json` | `{ version, createdAt, updatedAt }` | `{ "version":1, "createdAt":"2026-05-07T00:51:25.767Z", "updatedAt":"2026-05-07T00:51:25.767Z" }` | Project metadata; ignored. (Some are 0-byte/empty live.) |
| `projects/<encodedCwd>/extract-cursor.json` | `{ updatedAt }` **OR** `{ sessionId, processedOffset, updatedAt }` (both forms live) | `{ "updatedAt":"2026-05-07T00:54:20.137Z" }` / `{ "sessionId":"f16aad1d-…", "processedOffset":4, "updatedAt":"…Z" }` | A cross-tool extraction cursor/checkpoint; ignored. `processedOffset` likely a record index (value `4` on a small session). Writer/consumer unconfirmed. |
| `projects/<encodedCwd>/memory/` | per-project memory dir (often empty) | — | Ignored. |
| `tmp/<64-hex>/logs.json` | array of `{ sessionId, messageId:int, type, message, timestamp }` | `{ "sessionId":"7f657511-…", "messageId":0, "type":"user", "message":"/model", "timestamp":"…Z" }` | Gemini-style UI telemetry rows; `<64-hex>` is a project-hash dir (Gemini-fork remnant). `messageId` is a 0-based per-session sequence. **NOT a transcript.** Ignored. **15 of the 16 live `tmp/` dirs hold this file; 1 holds none** — so "tmp dirs hold logs.json" is *most*, not universal. |
| `debug/<sessionId>.txt` | per-session plaintext **INFO/DEBUG log** (timestamped lines, not JSON) | `2026-04-22T06:34:26.771Z [INFO] Config initialization started` / `…[DEBUG] [HOOK_REGISTRY] …` | **SESSION-KEYED** like the transcripts but stored OUTSIDE `projects/`: filename **stem == `sessionId`**, 1:1 with `projects/<encodedCwd>/chats/<sameStem>.jsonl` (verified: `debug/0061a40c-…159.txt` ↔ `-Users-bing--Code--polycli/chats/0061a40c-…159.jsonl`). **750 files live.** NOT a transcript; **never read by the adapter** (adapter only enumerates `projects/`). |
| `todos/<sessionId>.json` | `{ sessionId, todos:[ { content, id, status } ] }` | `{ "sessionId":"1e34a19c-…", "todos":[ { "content":"<TEXT>", "id":"…", "status":"completed" } ] }` | **SESSION-KEYED** (top-level `sessionId` == filename stem == a real transcript stem; verified ↔ `-Users-bing--Code--qwen-plugin-cc/chats/1e34a19c-….jsonl`). `todos[].status` seen: `completed`. NOT a transcript; **never read.** |
| `memories/MEMORY.md` | global memory markdown (often empty) | `(empty live)` | Global (not per-session) Qwen memory file. NOT session data; never read. |
| `skills/<name>/` | installed-skill directories | `superpowers/`, `fireworks-tech-graph/` | Installed CLI skills. NOT session data; never read. |
| `settings.json.orig` | backup of `settings.json` | `(JSON config)` | Config backup. NOT session data; never read. |
| `usage_record.jsonl` | per-session aggregate `{ version, sessionId, timestamp, startTime, project, durationMs, totalLatencyMs, files, tools, models{<model>:{requests,inputTokens,outputTokens,cachedTokens,thoughtsTokens,totalTokens,totalLatencyMs}} }` | `{ "version":1, "sessionId":"19b4e448-…", "project":"/Users/<u>/-Code-/polycli", "models":{"qwen3.7-plus":{"requests":2,"inputTokens":19179,…}} }` | Cross-session usage ledger; ignored by adapter. |
| `usage/token-usage-YYYY-MM.jsonl` | per-request `{ schemaVersion, id, timestamp, localDate, localMonth, sessionId, model, authType, source, inputTokens, outputTokens, cachedTokens, thoughtsTokens, totalTokens, apiDurationMs }` | `{ "schemaVersion":1, "id":"d7aae8bc-…", "sessionId":"7f640a35-…", "model":"qwen3.7-plus", "authType":"openai", "source":"main", "inputTokens":24564, "outputTokens":27 }` | Monthly token ledger; ignored. |
| `~/.qwen/projects.json` | — | — | **Does not exist.** Qwen has no global cwd→name map (Gemini does). |
| `<sessionId>.engram.json` sidecar | — | — | **Not present and not read by `QwenAdapter`** (Gemini-only convention). |
| `settings.json`, `oauth_creds.json`, `QWEN.md`, `output-language.md`, `tip_history.json`, `installation_id` | CLI config | — | NOT session data; never read. |

---

## 15. Engram mapping

`source field/record → Engram Session field → adapter file:line` (Swift `QwenAdapter.swift` / TS `qwen.ts`).

| Engram field | Source field/record | Swift | TS | Notes |
|---|---|---|---|---|
| `id` | `sessionId` (first user/assistant record) | `:60-62,93` | `:73,102` | required (else `malformedJSON`/null) |
| `source` | constant | `:4,94` | `:16,103` | `.qwen` / `'qwen'` |
| `summary` / title | first non-injection `user` text, `prefix(200)` | `:85,106` | `:92-94,113` | empty → nil |
| `project` | **`nil`** (never decoded from `<encodedCwd>`) | `:99` | (omitted) | Diverges from Gemini (which sets dir name); parity `project:null` |
| `cwd` | per-record `cwd` (first seen) | `:63-65,98` | `:74,107` | from the in-record field, not the dir name (no `projects.json`) |
| `model` | top-level `model` (first assistant) | `:66-68,100` | `:79-82,108` | TS also falls back to `message.model` (dead vs live data; live has top-level only) |
| `startTime` | first record `timestamp` | `:69-71,95` | `:75,104` | required |
| `endTime` | last record `timestamp` (nil if == start) | `:72-74,97` | `:76,105` | optional |
| `messageCount` | `userCount + assistantCount` | `:101` | `:108` | excludes system/tool_result/injection-as-user |
| `userMessageCount` | `type=="user"` minus injections | `:83-86,102` | `:86-95,109` | |
| `assistantMessageCount` | `type=="assistant"` | `:76-77,103` | `:84-85,110` | counted by type even if content empty |
| `toolMessageCount` | constant `0` | `:104` | `:111` | `tool_result`/`functionCall` never counted |
| `systemMessageCount` | injection-reclassified `user` records | `:81-82,105` | `:88-90,112` | NOT the raw `type:"system"` records |
| `filePath` | locator | `:107` | `:114` | |
| `sizeBytes` | file size | `:108` | `:115` | Swift `JSONLAdapterSupport.fileSize`; TS `stat.size` |
| `parentSessionId` / `suggestedParentId` / `agentRole` / `originator` | **`nil`** (no sidecar read) | `:110,116-117` | (omitted) | Diverges from Gemini Layer 1c; set later by heuristics/backfill |
| **per-message** `role` | `type=="assistant"`→assistant else user | `:170` | `:146,149` | from top-level `type`, not `message.role` |
| **per-message** `content` | `extractContent(message.parts[].text)` joined | `:167,228-241` | `:150,194-206` | thought text leaks in; `functionCall`/`functionResponse` dropped; separator `\n\n` (Swift) vs `\n` (TS) |
| **per-message** `timestamp` | `timestamp` | `:168` | `:151` | |
| **per-message** `usage` | assistant `usageMetadata` ?? pending `ui_telemetry` | `:164,170,174-213` | **none** | **Swift only** |
| **per-message** `toolCalls` | `nil` | `:169` | (none) | dropped |

**What Engram does NOT consume:** the entire `tool_result` record type; all `system` rows except `ui_telemetry/api_response` token mining (Swift); `parts[].functionCall`/`functionResponse` (but `thought` text leaks in); `message.role`; `parentUuid`; `uuid`; `gitBranch`; `version`; `contextWindowSize`; `usageMetadata.{thoughtsTokenCount,totalTokenCount}`; the whole `uiEvent` minus 3 token fields; the `<encodedCwd>` dir name (→ `project:nil`); `meta.json`; `extract-cursor.json`; `memory/`; `tmp/*/logs.json`; `usage/*` ledgers; and (TS path) **all** token usage. There is no on-disk `messageCount`/sidecar to consume.

---

## 16. Lineage, gotchas, version drift & edge cases

### Shared Gemini-CLI lineage — and where Qwen diverges

Qwen Code is a **fork of Google Gemini CLI** that **forked the content model but rewrote the persistence model.** It shares Gemini's *content body* (`message.parts[].text`, assistant `role:"model"`, `usageMetadata` token names) but adopts a **Claude-Code-style per-line JSONL envelope**. So Qwen is a **hybrid: Gemini body on a Claude-Code frame.**

| Dimension | Gemini CLI | **Qwen Code** | Same? |
|---|---|---|---|
| Root | `~/.gemini/tmp/<alias\|hash>/chats/` | **`~/.qwen/projects/<encodedCwd>/chats/`** | ✗ (`tmp` vs `projects`; alias/hash vs encoded-cwd) |
| Global map | `~/.gemini/projects.json` (cwd→name) | **none** | ✗ |
| File form | single-object `.json` (legacy) / `$set` `.jsonl` (new) | **append-per-event JSONL** (Claude-CC style) | ✗ |
| Filename | `session-<ts>-<8hex>.<json\|jsonl>` | **`<sessionId>.jsonl`** (bare UUID) | ✗ |
| Line envelope | top-level `{kind,projectHash,startTime,lastUpdated,messages[]}` | **per-line `{uuid,parentUuid,sessionId,timestamp,cwd,gitBranch,version,type}`** | ✗ (Qwen = Claude-CC frame) |
| Content shape | `messages[].content` = string / `[{text}]` | **`message.parts[].text`, assistant `role:"model"`** | ✓ (Gemini `parts`/`model` heritage) |
| Record types | `user`/`gemini`/`model`/`info` | **`user`/`assistant`/`tool_result`/`system{ui_telemetry,attribution_snapshot,slash_command}`** | ✗ |
| Tool calls | inline in assistant `toolCalls[]` (+ result) | **split: assistant `functionCall` + separate `tool_result`** | ✗ |
| Reasoning | separate `thoughts[]` array (text **dropped** by Engram) | **in-band `{text,thought:true}` part (text KEPT by Engram)** | ✗ behavior |
| Token usage | `tokens{input,output,cached,thoughts,tool,total}`; `inputTokens=max(input−cached,0)`, thoughts/tool folded into output | **`usageMetadata{promptTokenCount,…}` + `ui_telemetry` fallback**; `promptTokenCount` un-decached, thoughts unused | ✗ names + arithmetic |
| Engram `project` | dir name | **`nil`** | ✗ |
| Engram sidecar (Layer 1c) | reads `<sessionId>.engram.json` + `originator` | **not read** (heuristic + Polycli backfill only) | ✗ |

### Where Qwen and iFlow diverge (sibling tools)

**iFlow** (`~/.iflow/projects/<dir>/`, sibling `IflowAdapter`) is a *closer* cousin to **Claude Code** than to Qwen on the message body: it shares Qwen's root pattern (`~/.<tool>/projects/<encodedCwd>/`) + Claude-Code per-line JSONL frame, but uses **`message.content`** (Claude/Anthropic-style string or `[{type:"text",text}]`) + `isSidechain`/`userType` + an Anthropic-style `message.usage{}` (`model:"glm-5"`), and its files use a **`session-` prefix**. So within the Google-fork family: **Gemini `.json`/`$set` ≠ Qwen `parts`-JSONL ≠ iFlow `content`-JSONL** — three distinct persistence schemas. Do not assume Qwen and iFlow are field-identical: Qwen needs `parts[].text`, iFlow needs `message.content` blocks. (Both fixtures normalize to the same 3-message shape, masking the schema gap at the parity level.)

This whole family is **distinct** from the VS Code `.vscdb`/leveldb family (Cursor/VS Code/Copilot/Cline) — no lineage overlap.

### Gotchas / version drift / edge cases

1. **Fixtures are stale `v0.10.5` schema (HIGH).** `tests/fixtures/qwen/*` and the parity input use the flat 3-line `user`/`assistant` form with `message.parts[].text`, top-level `model`, and **no** telemetry/`tool_result`/`system`/`usageMetadata`/`thought` parts. Live `v0.14.5+` is far richer. The fixtures validate only the happy text path and **do not test** token extraction, telemetry fallback, `tool_result` skipping, injection filtering, or thought-leak. `schema_drift.jsonl` only proves unknown-key tolerance.
2. **`gemini-cli.md` §15 overstates the shared layout (CRITICAL correction).** It claims Qwen "reuses the same `tmp/<dir>/chats/` + `projects.json` layout." **REAL data contradicts this:** Qwen uses `~/.qwen/projects/<encodedCwd>/chats/<uuid>.jsonl`, has **no `projects.json`**, and its `tmp/*/` holds only `logs.json` telemetry. Qwen shares Gemini's content shape, not its file layout. Correct that doc.
3. **`tool_result` dropped, `toolMessageCount` always 0.** Tool I/O is fully on disk (a rich session can hold hundreds of `tool_result` records) but invisible in Engram. Linkage is `id`/`callId`-based across two records, not co-located like Gemini.
4. **Tool calls invisible + content can be empty.** Assistant turns whose `parts` are only `functionCall` count as assistant turns (counted by `type`) but flatten to **empty content**.
5. **Reasoning text leaks into assistant content (opposite of Gemini).** `extractContent` keeps any part with a `text` key, including `{text,thought:true}` reasoning — Qwen does NOT strip reasoning the way Gemini does. Engram's Qwen assistant content = reasoning + answer concatenated.
6. **`thoughtsTokenCount` not summed.** Qwen `outputTokens` = `candidatesTokenCount` only (Gemini folds thoughts+tool into output). Cross-tool output-token totals are not apples-to-apples.
7. **No cache subtraction (vs Gemini).** Qwen Swift maps `promptTokenCount → inputTokens` directly; Gemini does `max(input − cached, 0)`. So Qwen `inputTokens` includes cached tokens. Cross-source cost comparisons are inconsistent.
8. **Tokens only in the Swift product path.** TS reference adapter reports zero usage for Qwen; parity fixture (all-zero `usageTotals`) masks this.
9. **`systemMessageCount` ≠ count of `type:"system"` records.** Engram's `systemMessageCount` counts **system-injection user messages** (prompts starting `"You are Qwen Code"` / containing `<INSTRUCTIONS>`), NOT the (numerous) actual `type:"system"` records. The name is misleading.
10. **System-injection detection is brittle.** Hard-coded English prefixes (`"You are Qwen Code"`); a localized or reworded system prompt would be miscounted as a real user message and could become the `summary`.
11. **`project` always nil; `cwd` comes from inside the file.** The dash-encoded cwd dir name is never decoded; `cwd` comes from the in-record field. A session where no `user`/`assistant` record carries `cwd` would get an empty `cwd`.
12. **Sessions with no `user`/`assistant` record fail.** A session that only ever logged a `user` line + `system` telemetry still has a `user` record so `sessionId` is found; but a hypothetical all-`system` file → `sessionId` empty → `malformedJSON`/null (the `sessionId`/`cwd`/`model`/`timestamp` scan only reads `user`/`assistant` records, Swift:53-58).
13. **Per-line `version` can drift mid-file** across CLI upgrades on resume (live range `0.10.5`…`0.18.4`); neither adapter reads it, so any schema drift is **silent**. "Session version" is not single-valued.
14. **Size/parse caps differ Swift vs TS — and Qwen's truncation is SILENT.** TS has **no** file-size, line-size, or message-count cap (streams everything). Swift caps file 100 MB / line 8 MB / messages 10,000 and adds the mid-read file-identity guard. **Key correction:** because `QwenAdapter` calls `readObjects` WITHOUT `reportFailures` (`QwenAdapter.swift:40,131`; default `false` at `CodexAdapter.swift:61`), the message-count and per-line-byte caps are **swallowed, not surfaced** for Qwen — a >10,000-record session is **silently truncated** to the first 10,000 parsed objects (NO `.messageLimitExceeded` is raised, contrast Codex which passes `reportFailures:true`), and a >8 MB line is silently skipped. The TS path reads such a session in full (unbounded). Only **`.fileTooLarge`** (pre-read >100 MB, dropped by Swift / kept by TS) and **`.fileModifiedDuringParse`** (`CodexAdapter.swift:79-80`, NOT gated by `reportFailures`) actually surface for Qwen.
15. **File-identity guard (Swift only).** An actively-appended live session can trip `.fileModifiedDuringParse` and be retried — common because Qwen appends continuously.
16. **Content join separator drift.** Swift joins parts with `\n\n`, TS with `\n` — multi-part message bodies render with different spacing across the two parsers.
17. **Whole-file load on every read.** Neither path uses the streaming `windowedMessages` helper; paged reads load the entire file each time (O(file) per page for large sessions).
18. **Filename ≠ Gemini grammar, no prefix filter.** Bare `<sessionId>.jsonl`, no `session-` prefix or timestamp — and the adapter does **not** prefix-filter (any `.jsonl` under `chats/` is parsed), unlike Gemini/iFlow which require `session-`.
19. **`tmp/<64-hex>/` dirs** are a Gemini-fork remnant (project-hash dirs), parallel to the human-slug dirs under `projects/`. **CONFIRMED from source** ([`storage.ts`](https://raw.githubusercontent.com/QwenLM/qwen-code/main/packages/core/src/config/storage.ts)): `getProjectTempDir()` = `~/.qwen/tmp/<getProjectHash(cwd)>`, and `getProjectHash(p)` = `crypto.createHash('sha256').update(normalizedPath).digest('hex')` — a SHA-256 hex digest (exactly 64 hex chars) of the (Windows-lowercased) absolute cwd. So `tmp/<64-hex>` and `projects/<encodedCwd>` name the **same** project two different ways; only `projects/` holds `chats/`. **Most** tmp dirs hold a `logs.json` telemetry file (live: 15 of 16; **1 holds none** — empty/no logs), never a transcript. Engram reads only `projects/`.
20. **Other session-keyed artifacts live OUTSIDE `projects/`.** `debug/<sessionId>.txt` (750 live INFO/DEBUG logs, stem == sessionId, 1:1 with a transcript) and `todos/<sessionId>.json` (`{sessionId, todos:[{content,id,status}]}`) are keyed by `sessionId` exactly like the transcripts, yet sit at `~/.qwen/` top level — so a reader hunting "all per-session data Qwen writes" must look beyond `projects/`. Both are ignored: the adapter only enumerates `projects/<encodedCwd>/chats/*.jsonl` (`QwenAdapter.swift:22-36`). Also at root: global `memories/MEMORY.md`, `skills/<name>/`, `settings.json.orig` (none session data, none read).

### Open questions / resolved (web-confirmed 2026-06-21)

Most items below were resolved against qwen-code's published source on 2026-06-21. Remaining unknowns and Engram-internal design choices are marked.

- **Confirmed (official): the `system` `subtype` enum is much larger than the 3 observed live** — `chat_compression`, `slash_command`, `ui_telemetry`, `at_command`, `attribution_snapshot`, `notification`, `cron`, `mid_turn_user_message`, `custom_title`, `rewind`, `agent_bootstrap`, `agent_launch_prompt`, `file_history_snapshot`. The live-observed `{ui_telemetry, attribution_snapshot, slash_command}` are a subset; `chat_compression` is a compaction record (see §4, §12). Engram's behavior is unaffected (all `system` rows dropped except `api_response` token mining). — [`chatRecordingService.ts`](https://raw.githubusercontent.com/QwenLM/qwen-code/main/packages/core/src/services/chatRecordingService.ts)
- **Confirmed (official): the `<encodedCwd>` encoding rule is from CLI source, not inferred.** `sanitizeCwd(cwd) = normalizedCwd.replace(/[^a-zA-Z0-9]/g, '-')` (Windows lowercases first); `getProjectDir()` = `~/.qwen/projects/<sanitizeCwd(cwd)>`. Every non-alphanumeric char → a single `-`, so the leading-`-` + doubled-dash-on-separator + lossy `_`/`.`→`-` pattern is exact. — [`paths.ts`](https://raw.githubusercontent.com/QwenLM/qwen-code/main/packages/core/src/utils/paths.ts), [`storage.ts`](https://raw.githubusercontent.com/QwenLM/qwen-code/main/packages/core/src/config/storage.ts) (see §2 naming grammar)
- **Confirmed (official): `~/.qwen/tmp/<64-hex>/` is keyed by `getProjectHash(cwd)`** = `crypto.createHash('sha256').update(normalizedPath).digest('hex')` (SHA-256 hex, 64 chars) of the (Windows-lowercased) absolute cwd, via `getProjectTempDir()`. Same `getProjectHash` mechanism as the Gemini fork. `tmp/<64-hex>` and `projects/<encodedCwd>` name the same project two ways; only `projects/` holds `chats/`. — [`storage.ts`](https://raw.githubusercontent.com/QwenLM/qwen-code/main/packages/core/src/config/storage.ts), [`paths.ts`](https://raw.githubusercontent.com/QwenLM/qwen-code/main/packages/core/src/utils/paths.ts), [Issue #2373](https://github.com/QwenLM/qwen-code/issues/2373) (see §15 gotcha 19)
- **Confirmed (official): there is NO global `~/.qwen/projects.json` cwd→name map** (divergence from Gemini is real). The Storage layer derives the per-project dir purely from `sanitizeCwd(cwd)`; discovery/resume is by directory scanning. — [`storage.ts`](https://raw.githubusercontent.com/QwenLM/qwen-code/main/packages/core/src/config/storage.ts), [DeepWiki Insight pipeline](https://deepwiki.com/QwenLM/qwen-code/8.4-tool-development)
- **Confirmed (official): the transcript path is `~/.qwen/projects/<encodedCwd>/chats/<sessionId>.jsonl`** with the filename being the bare session UUID + `.jsonl` (no `session-` prefix, no timestamp). `getTranscriptPath()` = `path.join(storage.getProjectDir(), 'chats', `${sessionId}.jsonl`)`. — [`config.ts`](https://github.com/QwenLM/qwen-code/blob/main/packages/core/src/config/config.ts), [`storage.ts`](https://raw.githubusercontent.com/QwenLM/qwen-code/main/packages/core/src/config/storage.ts) (see §2)
- **Confirmed (official): Qwen never writes top-level `model` on `user` lines, and there is no `message.model`.** `model` is set ONLY by `recordAssistantTurn` as a top-level sibling; `recordUserMessage`/`recordToolResult` never set it, and `message` is a `Content` object (role+parts) with no model identifier. So the TS adapter's `message.model` fallback (`qwen.ts:81`) is **dead against all current and historical qwen-code output**. — [`chatRecordingService.ts`](https://raw.githubusercontent.com/QwenLM/qwen-code/main/packages/core/src/services/chatRecordingService.ts) (see §5, §15 mapping)
- **Confirmed (official): `cacheCreationTokens:0` is structurally permanent for Qwen.** `usageMetadata` is the Google GenAI `GenerateContentResponseUsageMetadata` type, which has `cachedContentTokenCount` (cache **read**) but **no cache-creation field**. — [`chatRecordingService.ts`](https://raw.githubusercontent.com/QwenLM/qwen-code/main/packages/core/src/services/chatRecordingService.ts), [field reference](https://v03.api.js.langchain.com/interfaces/_langchain_google_common.types.GenerateContentResponseUsageMetadata.html) (see §9.1)
- **Confirmed (official): assistant-only `model`/`usageMetadata` top-level placement.** `createBaseRecord` builds the shared envelope; `recordAssistantTurn` adds top-level `model` and (when present) `usageMetadata` + optional `contextWindowSize`. `recordUserMessage`/`recordToolResult` set neither. — [`chatRecordingService.ts`](https://raw.githubusercontent.com/QwenLM/qwen-code/main/packages/core/src/services/chatRecordingService.ts)
- **Confirmed (official): append-per-line JSONL is stable; no `$set`/whole-file rewrite.** ChatRecordingService is "Append-only writes (never rewrite the file)"; every write is `jsonl.writeLine(conversationFile, record)`. The project-scoped JSONL system explicitly replaced the OLD single-JSON format precisely to get incremental append saves, so reverting to a `$set` mutation log is contrary to the stated design direction. — [`chatRecordingService.ts`](https://raw.githubusercontent.com/QwenLM/qwen-code/main/packages/core/src/services/chatRecordingService.ts), [Issue #2373](https://github.com/QwenLM/qwen-code/issues/2373)
- **Confirmed (partial, official): `user` content can carry multipart / non-`text` parts.** `recordUserMessage` accepts a `@google/genai` `PartListUnion` wrapped via `createUserContent`, so a user record's `parts` can contain multiple parts and non-text kinds (notably `inlineData`); `functionResponse` parts go on `tool_result` records, not user. Empirically all sampled live sessions were single `[{text}]`, so the doc's prior "always single text part" is accurate for text-only sessions but the format permits multipart/`inlineData` — `extractContent`'s "keep `.text` only" would silently drop an `inlineData` part. — [`chatRecordingService.ts`](https://raw.githubusercontent.com/QwenLM/qwen-code/main/packages/core/src/services/chatRecordingService.ts) (see §6.2)
- Full enum of `toolCallResult.errorType` (live seen: `file_not_found`, `execution_denied`, `invalid_tool_params`, `unhandled_exception`, `edit_no_occurrence_found`) and `ui_telemetry.tool_call.decision`/`tool_type` (`auto_accept`/`native` seen) (web-checked 2026-06-21: no authoritative single-file enum found — emitted across multiple tool-execution/telemetry layers; authenticated GitHub code search would be the next step; low-impact since the whole `tool_result` type is dropped).
- Role of `extract-cursor.json` (two live shapes: `{updatedAt}` vs `{sessionId,processedOffset,updatedAt}`); `processedOffset` byte-offset vs record-index unconfirmed; writer/consumer unconfirmed (web-checked 2026-06-21: no authoritative source found — `chatRecordingService.ts` writes ONLY `chats/<sessionId>.jsonl`, and the Insight pipeline caches under `~/.qwen/insights/facets/` keyed by session id with no cursor/checkpoint/`processedOffset` file; not produced by any inspected code path).
- Whether `qwen-code.api_error` / `qwen-code.tool_call` telemetry should also feed usage (Engram-internal design — not web-verifiable). Format fact (confirmed): `api_error` events carry no `usageMetadata` and a failed turn produces no assistant `usageMetadata`, so the cost of failed API calls is genuinely absent from per-turn usage fields; `tool_call` telemetry carries `tool_token_count` but no prompt/completion split. — [`chatRecordingService.ts`](https://raw.githubusercontent.com/QwenLM/qwen-code/main/packages/core/src/services/chatRecordingService.ts)
- **Behavioral choices (Engram-internal design — not web-verifiable):** whether to strip reasoning (`thought:true`) text and whether to subtract cache from `inputTokens` (vs Gemini). Format facts that bound the decision (confirmed): (a) reasoning is an in-band part with `thought:true` on the assistant record (no separate `thoughts[]` array), so the flag is the only signal available to strip it; (b) `promptTokenCount` and `cachedContentTokenCount` are separate fields, so cache subtraction is possible if desired. — [`chatRecordingService.ts`](https://raw.githubusercontent.com/QwenLM/qwen-code/main/packages/core/src/services/chatRecordingService.ts)
- Whether Engram should add a Qwen `.engram.json` sidecar / originator path for deterministic Claude-Code/Polycli dispatch linking (Engram-internal design — not web-verifiable). Format fact (confirmed): qwen-code's `ChatRecord` schema has no cross-session parent field and no originator field (`parentUuid` is intra-session only), so any sidecar/originator path would be an Engram-added convention. — [`chatRecordingService.ts`](https://raw.githubusercontent.com/QwenLM/qwen-code/main/packages/core/src/services/chatRecordingService.ts)

---

## 17. Appendix: real anonymized samples

> Structure/keys verbatim; message/reasoning/tool text stripped to `<TEXT>`/placeholders; personal paths reduced.

### 17.1 Minimal live session — 3 records (user → ui_telemetry → assistant)

```jsonl
{"uuid":"0b7d3ecc-…-dbc39a20e637","parentUuid":null,"sessionId":"9ac9a7c3-…-2ce24fc677d6","timestamp":"2026-04-23T00:39:48.359Z","type":"user","cwd":"/Users/<u>/-Code-/engram","version":"0.15.0","gitBranch":"main","message":{"role":"user","parts":[{"text":"<TEXT>"}]}}
{"uuid":"ec79c67f-…","parentUuid":"0b7d3ecc-…","sessionId":"9ac9a7c3-…","timestamp":"2026-04-23T00:39:51.104Z","type":"system","subtype":"ui_telemetry","cwd":"/Users/<u>/-Code-/engram","version":"0.15.0","gitBranch":"main","systemPayload":{"uiEvent":{"event.name":"qwen-code.api_response","event.timestamp":"2026-04-23T00:39:51.103Z","response_id":"chatcmpl-…","model":"qwen3.5-plus","status_code":200,"duration_ms":2717,"input_token_count":16928,"output_token_count":40,"cached_content_token_count":0,"thoughts_token_count":21,"tool_token_count":0,"total_token_count":16968,"prompt_id":"db69c0b90dc7d","auth_type":"openai"}}}
{"uuid":"7171547f-…","parentUuid":"ec79c67f-…","sessionId":"9ac9a7c3-…","timestamp":"2026-04-23T00:39:51.130Z","type":"assistant","cwd":"/Users/<u>/-Code-/engram","version":"0.15.0","gitBranch":"main","model":"qwen3.5-plus","contextWindowSize":1000000,"usageMetadata":{"promptTokenCount":16928,"candidatesTokenCount":40,"thoughtsTokenCount":21,"totalTokenCount":16968,"cachedContentTokenCount":0},"message":{"role":"model","parts":[{"text":"<reasoning>","thought":true},{"text":"<final answer>"}]}}
```

### 17.2 Assistant record batching multiple tool calls (functionCall parts)

```json
{ "type": "assistant", "model": "qwen3.6-plus", "contextWindowSize": 1000000,
  "usageMetadata": { "promptTokenCount": 17297, "candidatesTokenCount": 533, "thoughtsTokenCount": 20, "totalTokenCount": 17830, "cachedContentTokenCount": 0 },
  "message": { "role": "model", "parts": [
    { "text": "<reasoning>", "thought": true },
    { "text": "<plan text>" },
    { "functionCall": { "id": "call_44de1922…", "name": "read_file", "args": { "file_path": "<path1>" } } },
    { "functionCall": { "id": "call_07ae16a2…", "name": "read_file", "args": { "file_path": "<path2>" } } }
  ] } }
```

### 17.3 `tool_result` records (success + error variants; dropped by Engram)

```json
// success
{ "type":"tool_result", "uuid":"<uuid>", "parentUuid":"<uuid>", "sessionId":"<uuid>",
  "timestamp":"2026-04-23T02:11:28.503Z", "cwd":"<path>", "gitBranch":"main", "version":"0.15.0",
  "toolCallResult":{ "callId":"call_44de…", "status":"success", "resultDisplay":"<TEXT>" },
  "message":{ "role":"user", "parts":[ { "functionResponse":{
      "id":"call_44de…", "name":"read_file", "response":{ "output":"<TEXT>" } } } ] } }

// error
{ "type":"tool_result", "...":"...",
  "toolCallResult":{ "callId":"call_f511ad84…", "status":"error",
      "resultDisplay":"File not found: <path>", "error":{}, "errorType":"file_not_found" },
  "message":{ "role":"user", "parts":[ { "functionResponse":{
      "id":"call_f511ad84…", "name":"read_file", "response":{ "error":"File not found: <path>" } } } ] } }
```

### 17.4 `system/attribution_snapshot` payload (auxiliary; dropped)

```json
{ "type":"system", "subtype":"attribution_snapshot",
  "systemPayload": { "snapshot": {
    "type":"attribution-snapshot", "version":1, "surface":"cli",
    "fileStates":{}, "promptCount":1, "promptCountAtLastCommit":0 } } }
```

### 17.5 `system/slash_command` payload (auxiliary; dropped)

```json
{ "type":"system", "subtype":"slash_command", "systemPayload": { "phase":"invocation", "rawCommand":"/model" } }
```

### 17.6 `ui_telemetry` tool_call & api_error events (auxiliary; dropped)

```json
{ "event.name":"qwen-code.tool_call", "event.timestamp":"…Z", "function_name":"read_file",
  "function_args":{ "file_path":"<path>" }, "duration_ms":755, "status":"success",
  "success":true, "decision":"auto_accept", "prompt_id":"0dbcd3638654a",
  "response_id":"chatcmpl-…", "tool_type":"native", "content_length":25062 }

{ "event.name":"qwen-code.api_error", "event.timestamp":"…Z", "response_id":"",
  "model":"qwen3.6-plus", "duration_ms":2769, "prompt_id":"84fb45f8bd654",
  "auth_type":"openai", "error_message":"Connection error. (cause: fetch failed)",
  "error_type":"APIConnectionError" }
```

### 17.7 Auxiliary / ledger files (ignored)

```json
// projects/<encodedCwd>/meta.json
{ "version":1, "createdAt":"2026-05-07T00:51:25.767Z", "updatedAt":"2026-05-07T00:51:25.767Z" }

// projects/<encodedCwd>/extract-cursor.json  (two live shapes)
{ "updatedAt":"2026-05-07T00:54:20.137Z" }
{ "sessionId":"f16aad1d-…", "processedOffset":4, "updatedAt":"…Z" }

// tmp/<64-hex>/logs.json (row) — telemetry, NOT a transcript
{ "sessionId":"7f657511-…", "messageId":0, "type":"user", "message":"/model", "timestamp":"2026-02-22T12:30:57.941Z" }

// usage_record.jsonl (row)
{ "version":1, "sessionId":"19b4e448-…", "project":"/Users/<u>/-Code-/polycli", "durationMs":6033,
  "models":{ "qwen3.7-plus":{ "requests":2, "inputTokens":19179, "outputTokens":139, "cachedTokens":0, "thoughtsTokens":… } } }

// usage/token-usage-YYYY-MM.jsonl (row)
{ "schemaVersion":1, "id":"d7aae8bc-…", "sessionId":"7f640a35-…", "model":"qwen3.7-plus",
  "authType":"openai", "source":"main", "inputTokens":24564, "outputTokens":27 }
```

### 17.8 Stale fixture session (`tests/fixtures/qwen/sample.jsonl`, v0.10.5 schema)

```jsonl
{"uuid":"q-001","parentUuid":null,"sessionId":"qwen-session-001","timestamp":"2026-01-20T09:00:00.000Z","type":"user","cwd":"/Users/test/my-project","version":"0.10.5","message":{"role":"user","parts":[{"text":"<TEXT>"}]}}
{"uuid":"q-002","parentUuid":"q-001","sessionId":"qwen-session-001","timestamp":"2026-01-20T09:00:08.000Z","type":"assistant","cwd":"/Users/test/my-project","version":"0.10.5","model":"qwen3.5-plus","message":{"role":"model","parts":[{"text":"<TEXT>"}]}}
{"uuid":"q-003","parentUuid":"q-002","sessionId":"qwen-session-001","timestamp":"2026-01-20T09:01:00.000Z","type":"user","cwd":"/Users/test/my-project","version":"0.10.5","message":{"role":"user","parts":[{"text":"<TEXT>"}]}}
```

### 17.9b Session-keyed artifacts outside `projects/` (ignored by adapter)

```
// ~/.qwen/debug/<sessionId>.txt  (stem == sessionId; 1:1 with chats/<stem>.jsonl) — plaintext log, NOT JSON
2026-04-22T06:34:26.771Z [INFO] Config initialization started
2026-04-22T06:34:26.771Z [DEBUG] [HOOK_REGISTRY] Hook registry initialized with 0 hook entries
2026-04-22T06:34:26.771Z [DEBUG] MessageBus initialized with hook subscription
```

```json
// ~/.qwen/todos/<sessionId>.json  (sessionId == filename stem == a real transcript stem)
{ "sessionId": "1e34a19c-…-2b9d34641eea",
  "todos": [ { "content": "<TEXT>", "id": "…", "status": "completed" } ] }
```

### 17.9 Lineage contrast — iFlow line (shares family root, different message body)

```json
{"type":"user","sessionId":"session-iflow-001","message":{"role":"user","content":"<TEXT>"},"isSidechain":false,"userType":"external","cwd":"/Users/test/my-project","gitBranch":"main","version":"1.0.0"}
```
(iFlow = `message.content` blocks, Claude/Anthropic style; Qwen = `message.parts[].text`, Gemini style.)

---

## 18. References (official sources)

Verified 2026-06-21 against the QwenLM/qwen-code repository and supporting type references.

- [QwenLM/qwen-code — `packages/core/src/utils/paths.ts`](https://raw.githubusercontent.com/QwenLM/qwen-code/main/packages/core/src/utils/paths.ts) — `sanitizeCwd`, `getProjectHash`.
- [QwenLM/qwen-code — `packages/core/src/config/storage.ts`](https://raw.githubusercontent.com/QwenLM/qwen-code/main/packages/core/src/config/storage.ts) — `getProjectDir`, `getProjectTempDir`.
- [QwenLM/qwen-code — `packages/core/src/services/chatRecordingService.ts`](https://raw.githubusercontent.com/QwenLM/qwen-code/main/packages/core/src/services/chatRecordingService.ts) — `ChatRecord` schema, append-only writes, `recordUserMessage`/`recordAssistantTurn`/`recordToolResult`.
- [QwenLM/qwen-code — `packages/core/src/config/config.ts`](https://github.com/QwenLM/qwen-code/blob/main/packages/core/src/config/config.ts) — `getTranscriptPath`.
- [QwenLM/qwen-code Issue #2373 — Portable Chat History](https://github.com/QwenLM/qwen-code/issues/2373) — `project_hash` / `getProjectHash`, tmp dir.
- [DeepWiki — QwenLM/qwen-code Insight Generation](https://deepwiki.com/QwenLM/qwen-code/8.4-tool-development) — `DataProcessor.scanChatFiles`, `insights/facets` cache.
- [Google GenAI `GenerateContentResponseUsageMetadata` field reference (LangChain.js types)](https://v03.api.js.langchain.com/interfaces/_langchain_google_common.types.GenerateContentResponseUsageMetadata.html) — `usageMetadata` field set (no cache-creation field).
