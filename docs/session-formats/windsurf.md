# Windsurf (Cascade) — Session Format Reference

Last researched: 2026-06-21 (Engram session-format research workflow)

> **Sibling tool:** Windsurf shares its *entire* code path with **Antigravity** (the
> "Cascade family" — both are Codeium/Cascade-derived). `CascadeCacheSupport`,
> `CascadeClient`, `CascadeDiscovery`, and `cascade.proto` are literally shared by both
> adapters. These shared infra files live under
> `macos/Shared/EngramCore/Adapters/Cascade/` — a **sibling** of
> `macos/Shared/EngramCore/Adapters/Sources/` (where `WindsurfAdapter.swift` and
> `AntigravityAdapter.swift` live), **not** nested under `Sources/`. This doc is
> self-contained; where behavior is identical, the Antigravity doc cross-references here.
> Only the on-disk roots differ (see §15) — the code path (including
> `getTrajectoryMessages`, see gotcha #9) splits by *which* RPC each adapter calls, not by
> file.

---

## 1. Overview & TL;DR

**What/where/how saved.** Windsurf (Codeium Cascade) is the **odd one out** among Engram's
sources: Engram does **not** parse Windsurf's native on-disk store. Windsurf persists each
conversation ("trajectory") as an **opaque, high-entropy binary `.pb` blob** under
`~/.codeium/windsurf/cascade/<cascadeId>.pb`, readable **only** through the running Cascade
*language server* over a local HTTP/Connect-RPC endpoint
(`exa.language_server_pb.LanguageServerService`). The underlying logical format **is**
protobuf — the official Exafunction/codeium repo describes the `.pb` as a protobuf "base
index" (~40 MB) accompanied by `.tmp` "incremental snapshots" (deltas merged into the base)
([issue #286](https://github.com/Exafunction/codeium/issues/286)). But the on-disk byte
stream is not *directly* decodable: `file(1)` reports `data`, and the first bytes are
high-entropy with no protobuf field-tag structure (`14f4 2934 face 359b …`) — most
consistent with a protobuf base + delta-merge layout that is **likely compressed** (Windsurf
gzip-wraps its Connect-RPC bodies). No official source supports "encrypted." Either way
Engram cannot parse it offline; it needs the running language server.

Engram therefore uses a **two-stage model**:

1. **Live sync (Connect-RPC → JSONL cache).** Discover the running language server via a
   daemon JSON file, call `GetAllCascadeTrajectories` then `ConvertTrajectoryToMarkdown`
   per conversation, split the Markdown into user/assistant turns, and write an
   **Engram-owned JSONL cache** at `~/.engram/cache/windsurf/<cascadeId>.jsonl`.
2. **Index the JSONL cache.** The indexer reads only the cache; it never opens a `.pb`.

**Critical: stage 1 is DISABLED in the shipped Swift product.** The factory constructs
`WindsurfAdapter(enableLiveSync: false)` (`SessionAdapterFactory.swift:25,70`), so `sync()`
returns immediately at its `guard enableLiveSync …` (`WindsurfAdapter.swift:204-208`). The
product is **strictly cache-only**: it indexes whatever `*.jsonl` already exists in
`~/.engram/cache/windsurf/` and writes nothing new. With an empty cache and no prior
sync, the product currently surfaces **zero** Windsurf sessions on this machine. The TS
reference adapter (`src/adapters/windsurf.ts`) has no `enableLiveSync` gate and is the only
path that ever *produces* cache files.

**Mental model (layering / ASCII).**

```
 LAYER 0  Windsurf-owned, OPAQUE (Engram reads mtime only, never content)
 ┌──────────────────────────────────────────────────────────────────────┐
 │ ~/.codeium/windsurf/cascade/<cascadeId>.pb   (protobuf base + .tmp     │
 │                                               deltas; likely gzipped)  │
 │ ~/.codeium/windsurf/daemon/*.json            (httpPort + csrfToken)    │
 └───────────────┬──────────────────────────────────────────────────────┘
                 │  (only via running language server)
 LAYER 1  Live Connect-RPC wire schema (transient; never stored by Engram)
 ┌───────────────▼──────────────────────────────────────────────────────┐
 │ POST http://localhost:<port>/exa.language_server_pb.LanguageServer…    │
 │   GetAllCascadeTrajectories   → trajectorySummaries{cascadeId→summary} │
 │   ConvertTrajectoryToMarkdown → { markdown: "## user…\n…## assistant…"}│
 └───────────────┬──────────────────────────────────────────────────────┘
                 │  sync(): parse markdown, flatten to {role,content}
 LAYER 2  Engram-owned cache — THE ONLY THING THE PRODUCT READS
 ┌───────────────▼──────────────────────────────────────────────────────┐
 │ ~/.engram/cache/windsurf/<cascadeId>.jsonl                            │
 │   line 1   = metadata  {id,title,createdAt,updatedAt,cwd?}            │
 │   lines 2+ = messages  {role,content[,timestamp]}                    │
 └──────────────────────────────────────────────────────────────────────┘
                 │  listSessionLocators → parseSessionInfo → streamMessages
                 ▼  NormalizedSessionInfo → DB Session row
```

**Evidence basis.** Cross-checked **four** sources on this machine:

| Source | Detail |
|---|---|
| **Live upstream store** | `~/.codeium/windsurf/cascade/` → **2** real `.pb` files (42.3 KB `3943ee14-…` + 2.1 MB `7da9e8cd-…`). `~/.codeium/windsurf/daemon/` is **ABSENT**. |
| **Live Engram cache** | `~/.engram/cache/windsurf/` exists but is **EMPTY (0 files)** — consistent with live sync OFF. |
| **Repo fixtures** | `tests/fixtures/windsurf/cache/conv-w01.jsonl` (3 lines, 323 B) + parity pair `tests/fixtures/adapter-parity/windsurf/{input/cache/conv-w01.jsonl, success.expected.json}`. Synthetic goldens, not user data. |
| **Adapters (codified)** | Swift `Adapters/Sources/WindsurfAdapter.swift` + shared infra `Adapters/Cascade/{CascadeClient,CascadeDiscovery}.swift` + `Adapters/Cascade/cascade.proto` (the `Cascade/` and `Sources/` dirs are **siblings** under `macos/Shared/EngramCore/Adapters/`); TS `src/adapters/windsurf.ts` (+ `src/adapters/grpc/cascade-client.ts`). |

**Conflict resolution.** Real data wins. The live store *has* data (`.pb`) but the product
produces nothing because live sync is off and the cache is empty. So the *indexable* schema
is the Layer-2 JSONL-cache schema; the Layer-1 wire schema is documented as the upstream
source the cache is derived from. The only writer/reader drift (per-message `timestamp`,
see §6/§15) is confirmed by source, not by a live-generated artifact (none exists here).

---

## 2. On-disk layout & file naming

### Authoritative roots & storage tech

| Role | Path (default) | Storage tech | Owner | Read by product? |
|---|---|---|---|---|
| Upstream daemon discovery dir | `~/.codeium/windsurf/daemon/` | Per-instance JSON files (`httpPort`, `csrfToken`) | Codeium/Windsurf | Only when `enableLiveSync=true` (OFF in product) |
| Upstream conversation store | `~/.codeium/windsurf/cascade/` | One opaque binary `.pb` per conversation, `<cascadeId>.pb` | Codeium/Windsurf | Read only via daemon RPC; never parsed. Used as **mtime freshness source** |
| **Engram cache (parsed source of truth)** | `~/.engram/cache/windsurf/` | **JSONL**, one file per conversation `<cascadeId>.jsonl` | **Engram** | **YES — the only thing the product reads** |

Defaults are wired in both adapters: `WindsurfAdapter.init` (`WindsurfAdapter.swift:106-113`)
and the TS constructor (`windsurf.ts:38-42`). `SourceCatalog` lists the Windsurf
`defaultPath` as `~/.codeium/windsurf/daemon` (`SourceCatalog.swift:38`), i.e. the discovery
dir, even though the parsed data lives in the Engram cache.

### Naming grammar

| Artifact | Grammar | Example | Notes |
|---|---|---|---|
| Upstream blob | `<cascadeId>.pb` | `7da9e8cd-17ea-4f40-99af-411f6386a59b.pb` | `cascadeId` = lowercase UUIDv4 (Cascade *trajectory id*) |
| Engram cache file | `<cascadeId>.jsonl` | `7da9e8cd-….jsonl` | Same `cascadeId`, `.jsonl`; written by `sync()` (`WindsurfAdapter.swift:212`) |
| Fixture file | arbitrary `<name>.jsonl` | `conv-w01.jsonl` | Filename is **not** parsed for identity; session `id` comes from the JSONL metadata line, so cache filename and metadata `id` *can* differ |
| Daemon discovery file | `*.json` in `daemon/` | (varies) | Picked by reverse lexical sort (`$0 > $1`) → newest-named first (`CascadeDiscovery.swift:30`) |

**Session identity = the `id` field inside the JSONL metadata line, NOT the filename**
(`parseSessionInfo` reads `metadata["id"]`, `WindsurfAdapter.swift:139`). During sync the file
is named after `conversation.cascadeId`, so in practice they coincide.

### Real directory tree (this machine)

```
~/.codeium/windsurf/                         # Codeium/Windsurf upstream data dir
├── cascade/                                 # <-- per-conversation transcript blobs
│   ├── 3943ee14-bc8c-4529-adc4-07b7fb2c1f5c.pb   # opaque binary, 42.3 KB
│   └── 7da9e8cd-17ea-4f40-99af-411f6386a59b.pb   # opaque binary, 2.1 MB
├── daemon/                                  # (ABSENT here) language-server discovery JSON
├── database/                                # internal Codeium DB (not session data; ignored)
├── memories/{global_memories.md,global_rules.md}  # not parsed by Engram
├── brain/  code_tracker/  context_state/  implicit/  recipes/  skills/
├── bin/  windsurf/  ws-browser/  ws-browser-profile/
├── installation_id        (36 B)
├── mcp_config.json        (155 B)
└── user_settings.pb       (4 KB)

~/.engram/cache/windsurf/                    # Engram-owned cache — EMPTY (live sync off)

tests/fixtures/windsurf/cache/
└── conv-w01.jsonl         (323 B)           # canonical cache example
```

Engram only ever touches two of these: `daemon/*.json` (for RPC discovery, when sync is on)
and `~/.engram/cache/windsurf/*.jsonl` (always). Everything else under
`~/.codeium/windsurf/` — `database/`, `memories/`, `brain/`, etc. — is ignored.

---

## 3. File lifecycle & generation

| Question | Answer |
|---|---|
| **Append or rewrite?** | The Engram cache `.jsonl` is **fully rewritten** each sync — `writeCache` does `write(to:atomically:true)` of the whole file (`WindsurfAdapter.swift:79`; TS `writeFile`, `windsurf.ts:97`). Never appended. The upstream `.pb` is rewritten/grown by Windsurf itself (the 2.1 MB blob shows in-place growth, not rollover). |
| **DB or file?** | File-based on both ends Engram touches: opaque `.pb` files upstream, JSONL files in the Engram cache. (Windsurf keeps an internal `database/` dir, but Engram never reads it.) |
| **Resume / continuation** | Same `cascadeId` ⇒ same `.pb` ⇒ same cache file. A resumed Windsurf conversation grows its existing blob and, on next sync, overwrites the existing `<cascadeId>.jsonl`. No new file per resume — *until* the conversation is evicted by the ~20-conversation retention cap (see Rollover row), after which its upstream `.pb` no longer exists to resume. |
| **Rollover** | No size/time-based *splitting* of a single conversation. But conversations are **not** kept for life: Windsurf enforces a retention cap of ~20 conversations in Cascade — creating the 21st permanently deletes the oldest ("your first conversation is gone forever") ([issue #136](https://github.com/Exafunction/codeium/issues/136)). So the upstream `.pb` for an evicted conversation is deleted by Windsurf. Engram's own JSONL cache is never pruned (see Archive/deletion row), so an evicted conversation's stale `.jsonl` lingers in the cache after its `.pb` is gone. |
| **Freshness gate** | Sync regenerates a cache only if **stale**: cache missing, or `cache.mtime < pb.mtime` (`isFresh`, `WindsurfAdapter.swift:238-256`; TS `windsurf.ts:73-77`). A `requireContent` flag would also treat caches `≤ 200` bytes as stale, but the live call passes `requireContent:false` (`:214`), so tiny/empty caches are NOT auto-refreshed on that basis. |
| **Archive / deletion** | Engram never deletes cache files. If a Windsurf conversation is deleted upstream, its `.jsonl` is simply never refreshed and lingers; sync only *creates/overwrites*, never prunes. |
| **Live sync status in product** | **OFF.** `WindsurfAdapter(enableLiveSync: false)` (`SessionAdapterFactory.swift:25,70`). The adapter *default* is `true` (`WindsurfAdapter.swift:116`) but the factory overrides it. `sync()` early-returns; product is strictly cache-only. The cache-only status is **canonicalized** in `LiveSyncDisabledSources.ids = ["windsurf", "antigravity"]` (`macos/Shared/Service/LiveSyncDisabledSources.swift:15`) and surfaced to the user as a **"Cache only" badge** in the app UI, so the live-sync-off state is shown honestly rather than implied as a broken/active sync. |

### Discovery / enumeration flow

`listSessionLocators()` (Swift `WindsurfAdapter.swift:129-132`) / `listSessionFiles()`
(TS `:107-119`):

1. **`await sync()`** — in the product this returns immediately (`enableLiveSync=false`).
   With sync on it would: discover the daemon
   (`CascadeDiscovery.discoverWindsurfClient` reads `daemon/*.json`, reverse-sorted, picks the
   first with a valid `httpPort` + non-empty `csrfToken`, `CascadeDiscovery.swift:20-42`),
   `listConversations()` via RPC, and for each non-empty `cascadeId` that is stale: fetch
   Markdown, parse to messages, **rewrite** `~/.engram/cache/windsurf/<cascadeId>.jsonl`.
2. **Enumerate the cache** — `CascadeCacheSupport.jsonlLocators(cacheDir:)` lists the
   **direct children** (non-recursive) of `~/.engram/cache/windsurf/` whose extension is
   `.jsonl`, sorted; returns absolute paths as locators (`WindsurfAdapter.swift:6-11`).
3. **Per-session parse** — `parseSessionInfo(locator:)` streams the JSONL: line 1 → metadata
   (requires non-empty `id` + `createdAt`, else `.malformedJSON`); lines 2..N → counts of
   `user`/`assistant` messages + first user text; builds `summary`.
4. **`detect()`** returns true if **either** `~/.codeium/windsurf/daemon/` **or**
   `~/.engram/cache/windsurf/` is a directory (`WindsurfAdapter.swift:125-127`). So Windsurf
   can be "detected" even with sync off and an empty cache, as long as the cache dir exists.

---

## 4. Record / line taxonomy

Three logical record kinds exist across the layers; only the JSONL cache kinds are parsed.

| Record kind | Where | Parsed by Engram? | Purpose |
|---|---|---|---|
| **`.pb` trajectory blob** | `cascade/<cascadeId>.pb` | **No** (mtime only) | Native Windsurf transcript; opaque binary |
| **Daemon discovery JSON** | `daemon/*.json` | Only during live sync | Provides `httpPort` + `csrfToken` for RPC |
| **RPC payloads** | transient (HTTP) | Consumed in-memory, never stored | Source of cache content (Layer 1) |
| **JSONL metadata record** | cache `.jsonl` line 1 | **Yes** | Session envelope (id, title, times, cwd) |
| **JSONL message record** | cache `.jsonl` lines 2..N | **Yes** | One user/assistant turn |

**Distinct nesting layers in the cache:** the JSONL has only two flat layers — (1) the
*record* (one JSON object per line) and (2) the metadata-vs-message *kind*, discriminated by
line index (`objects.first` = metadata, `objects.dropFirst()` = messages,
`WindsurfAdapter.swift:13-17`). There are **no content-blocks**; tool calls are flattened
away (`toolMessageCount`/`systemMessageCount` hard-coded `0`,
`WindsurfAdapter.swift:166-167`).

---

## 5. Shared envelope / metadata fields

The metadata record is the JSONL line 1 (exactly one per file). Written by
`CascadeCacheSupport.writeCache` (`WindsurfAdapter.swift:62-80`) / `windsurf.ts:86-97`;
read by `parseSessionInfo`.

| Field | Type | Req? | Meaning | Optional | Example (anonymized) |
|---|---|---|---|---|---|
| `id` | string | **required** | Session id = `cascadeId` = `.pb` basename. Empty/missing → whole file rejected (`.malformedJSON`, `WindsurfAdapter.swift:138-144`) | no | `"conv-w01"` (live: UUIDs e.g. `3943ee14-…`) |
| `title` | string | optional | Conversation title; from `CascadeTrajectorySummary.summary` (the summary IS the title — see §15) | written always (may be `""`) | `"Refactor the API"` |
| `createdAt` | string (ISO-8601 `…Z`) | **required** | Session start → `startTime`. Missing → file rejected (`:141`) | no | `"2026-02-18T09:00:00.000Z"` |
| `updatedAt` | string (ISO-8601 `…Z`) | optional | Last modified → `endTime` if `≠ createdAt`, else `nil` (`:159`); defaults to `createdAt` if absent (`:151`) | falls back to `createdAt` | `"2026-02-18T09:20:00.000Z"` |
| `cwd` | string (abs path) | optional | Workspace folder; from `workspaces[0].workspaceFolderAbsoluteUri` (`file://` stripped, %-decoded) → `info.cwd`. **Added later** — caches written before this field lack it; backfill once `.pb` mtime advances (`WindsurfAdapter.swift:228-233`) | yes | `"/Users/<user>/proj"` (absent in fixture) |

```json
{"id":"conv-w01","title":"Refactor the API","createdAt":"2026-02-18T09:00:00.000Z","updatedAt":"2026-02-18T09:20:00.000Z"}
```
With `cwd` (newer format):
```json
{"id":"conv-1","title":"T","createdAt":"2026-02-18T09:00:00.000Z","updatedAt":"2026-02-18T09:20:00.000Z","cwd":"/Users/test/ws-project"}
```

> Swift `writeCache` emits metadata keys **sorted** (`JSONSerialization … .sortedKeys`,
> `WindsurfAdapter.swift:91-93`). TS emits insertion order. The reader tolerates both.

---

## 6. Message & content schema

The message record is lines 2..N (zero or more). Schema is **deliberately minimal — exactly
two written keys** (`role`, `content`), with a third (`timestamp`) tolerated on read but
never written by the Swift writer.

| Field | Type | Written by sync? | Read by parser? | Meaning | Example |
|---|---|---|---|---|---|
| `role` | enum string | yes | yes | `"user"` or `"assistant"` only. Any other value → message dropped (`normalizedMessages`, `WindsurfAdapter.swift:19-35`; TS `:201`) | `"user"` |
| `content` | string | yes | yes | Flattened turn body (a Markdown section body). Missing → `""` (`:29`) | `"Refactor the API to use REST"` |
| `timestamp` | string (ISO-8601) | **no — structurally impossible** | partial | Per-message time. Read by TS `streamMessages` (`:198-211`) and Swift `normalizedMessages` (`:30`); appears only in hand-authored fixtures. `writeCache` cannot emit it because the in-memory message struct `CascadeTrajectoryMessage` (`CascadeClient.swift:12-15`) has **only** `role`+`content` — no timestamp field exists to write | `"2026-02-18T09:00:20.000Z"` |

```json
{"role":"user","content":"Refactor the API to use REST","timestamp":"2026-02-18T09:00:00.000Z"}
{"role":"assistant","content":"I'll restructure the endpoints.","timestamp":"2026-02-18T09:00:20.000Z"}
```

> **Content variants:** there is exactly one — a plain UTF-8 string. No content-blocks, no
> structured arrays, no images, no tool-result objects. The original trajectory's
> tool/reasoning structure is collapsed into prose by the Markdown sync step (see §7/§8).

> **Writer/reader drift (confirmed by source only):** the fixture carries `timestamp` on
> message lines, but Swift `writeCache` emits only `{role,content}`. This is **not** the
> writer choosing to drop an available value — `CascadeTrajectoryMessage`
> (`CascadeClient.swift:12-15`) is a 2-field struct (`role`, `content`) with no timestamp
> field, so a synced message *never has* a timestamp to begin with; the cache structurally
> cannot carry per-message timestamps. The `timestamp` key only ever appears in
> hand-authored fixtures/legacy caches. This is a **Cascade-family** trait: the *same*
> `CascadeCacheSupport.writeCache` is shared with Antigravity, so the identical absence
> applies there. Not verifiable empirically here because the live cache is empty.

---

## 7. Tool calls & results

**N/A for Windsurf (cache-level).** Tool calls, tool results, and call↔result linkage do
**not** exist anywhere Engram can index.

- Cascade trajectory tool steps are **not** among the 3 step types the structured parser
  extracts (`USER_INPUT` / `PLANNER_RESPONSE` / `NOTIFY_USER`, `CascadeClient.swift:71-89`),
  and that structured parser (`getTrajectoryMessages`) is **not on the *Windsurf* sync
  path** — `WindsurfAdapter.sync()` calls `getMarkdown` (`WindsurfAdapter.swift:218`). (It
  *is* the active path for the sibling AntigravityAdapter — see gotcha #9 — but
  `USER_INPUT`/`PLANNER_RESPONSE`/`NOTIFY_USER` still carry no tool steps either way.)
- The Markdown sync (`ConvertTrajectoryToMarkdown`) collapses everything to prose split on
  `^##\s+` headers (`parseMarkdownToMessages`, `WindsurfAdapter.swift:37-60`), so tool
  output that the language server rendered into Markdown becomes opaque `content`.
- `NormalizedMessage.toolCalls` is set to `nil` (`:31`); `toolMessageCount` is hard-coded
  `0` (`:166`); parity golden `toolCalls: []`, `fileToolCounts: {}`,
  `insightFields.toolCallCount: 0` (`success.expected.json`).

---

## 8. Reasoning / thinking

**N/A for Windsurf.** No dedicated reasoning/thinking field exists in the cache schema. Any
chain-of-thought the language server rendered into Markdown is folded into the `content`
string of an assistant message (if at all). There is no separate `thinking`/`reasoning`
record, block, or count.

---

## 9. Token usage & cost

**N/A for Windsurf — no token or cost data exists.**

- Cascade exposes no usage in the synced Markdown path; `NormalizedMessage.usage` is `nil`
  (`WindsurfAdapter.swift:32`).
- No `inputTokens`/`outputTokens`/cache-read/cache-creation fields anywhere in the cache.
- Parity golden `usageTotals` is **all zero**:
  `{inputTokens:0, outputTokens:0, cacheReadTokens:0, cacheCreationTokens:0}`
  (`success.expected.json`).
- `model` is **`nil`** (`WindsurfAdapter.swift:162`) — Windsurf never records the model name
  in anything Engram reads.

---

## 10. Subagent / parent-child / dispatch

**N/A for Windsurf.** Windsurf never participates in parent-linking. The adapter sets
`agentRole`, `originator`, `origin`, `parentSessionId`, and `suggestedParentId` all to `nil`
(`WindsurfAdapter.swift:172-179`). There is no sidecar (unlike Gemini's `.engram.json`), no
path-based subagent detection, and no dispatch metadata. Parent/child links may still be
assigned later by Engram's heuristic Layer-2 pipeline, but the adapter contributes nothing.

---

## 11. Summary / compaction

**N/A for Windsurf (no native compaction record).** There is no compaction/summary event in
the cache. The *session summary* is derived at parse time, not stored as a record:

```
summary = (title.isEmpty ? firstUserText : title).prefix(200)   // WindsurfAdapter.swift:153
```

i.e. the metadata `title` (Cascade `summary`) if present, else the first user message text,
truncated to 200 chars. Empty → `nil` (`:168`).

---

## 12. SQLite / DB internals

**N/A for Windsurf.** Windsurf is **not** DB-backed from Engram's perspective. The upstream
data is opaque `.pb` blobs (not SQLite); Engram's own store is plain JSONL files. (Windsurf
itself keeps an internal `~/.codeium/windsurf/database/` dir, but Engram never opens it.)

> Contrast: the VS Code-family tools (Cursor, VS Code, Copilot, Cline) *are* DB/state-backed
> (`state.vscdb`, `chatSessions/*.jsonl`, per-task JSON). Windsurf shares **no** on-disk
> schema with them — see §15.

---

## 13. Auxiliary files

| File / dir | Role | Used by Engram? |
|---|---|---|
| `~/.codeium/windsurf/daemon/*.json` | Language-server discovery (`httpPort`, `csrfToken`) | Only during live sync (OFF in product) |
| `~/.codeium/windsurf/cascade/<id>.pb` | Native trajectory blob | mtime only (freshness gate) |
| `~/.codeium/windsurf/database/` | Internal Codeium DB | No |
| `~/.codeium/windsurf/memories/{global_memories.md,global_rules.md}` | Codeium memories/rules | No |
| `~/.codeium/windsurf/{brain,code_tracker,context_state,implicit,recipes,skills}/` | Codeium internals | No |
| `~/.codeium/windsurf/{mcp_config.json,user_settings.pb,installation_id}` | Codeium config/identity | No |
| `~/.engram/cache/windsurf/<id>.jsonl` | **Engram-derived parsed cache** | **Yes — the only parsed input** |

There are no indexes, logs, or sidecar files Engram writes for Windsurf beyond the JSONL
cache itself.

### Daemon discovery JSON fields (read during live sync only)

| Field | Type | Meaning |
|---|---|---|
| `httpPort` | int or numeric string | Local port of the Cascade language server (`CascadeDiscovery.swift:33`) |
| `csrfToken` | string (non-empty) | Sent as `x-codeium-csrf-token` header on every RPC (`CascadeClient.swift:111`) |

> **Version-fragility warning.** The `daemon/*.json` `{httpPort, csrfToken}` discovery file and
> the exact `x-codeium-csrf-token` header spelling are Engram's own reverse-engineered details
> — they are **not** confirmed by any official/public source. The CSRF-token auth path is
> version-dependent: Windsurf 1.9577+ **removed** the `--csrf_token` language-server argument in
> favor of `--stdin_initial_metadata`
> ([opencode-windsurf-auth #8](https://github.com/rsvedant/opencode-windsurf-auth/issues/8)), so
> on current Windsurf builds the `csrfToken`-based discovery may no longer apply. Windsurf *does*
> run a local language server over Connect-RPC and the default local LS port matches the
> community-documented `LS_PORT=42100`
> ([WindsurfAPI](https://github.com/dwgx/WindsurfAPI/blob/master/README.en.md)), but treat the
> specific discovery/auth mechanism here as possibly stale rather than canonical.

---

## 14. Engram mapping

Two stages: (A) cache → `NormalizedSessionInfo` (adapter); (B) `NormalizedSessionInfo` → DB
`Session` row (`SwiftIndexer.buildSnapshot`). All adapter line numbers verified against the
files on disk.

| Engram field | Source of truth | Swift `file:line` | TS parity `file:line` | Notes |
|---|---|---|---|---|
| **id** | metadata `id` | `WindsurfAdapter.swift:139,156` | `windsurf.ts:133,159` | required; empty/missing → `malformedJSON` (Swift) / `null` (TS) |
| **source** | constant `windsurf` | `WindsurfAdapter.swift:98,157` | `windsurf.ts:28,160` | `SourceName.windsurf` |
| **startTime** | metadata `createdAt` | `WindsurfAdapter.swift:141,158` | `windsurf.ts:161` | required |
| **endTime** | `updatedAt` if `≠ createdAt`, else `nil` | `WindsurfAdapter.swift:151,159` | `windsurf.ts:162` | identical times collapse to `nil`/`undefined` |
| **cwd** | metadata `cwd` (default `""`) | `WindsurfAdapter.swift:160` | `windsurf.ts:163` | derived in Layer-1 from `workspaces[0]` |
| **project** | `nil` at adapter; derived downstream | `WindsurfAdapter.swift:161` | (absent in TS `SessionInfo`) | `SwiftIndexer.swift:216-217`: `project = URL(cwd).lastPathComponent` if cwd non-empty; empty cwd → stays `nil` |
| **model** | `nil` (not captured) | `WindsurfAdapter.swift:162` | (absent) | Windsurf never records model |
| **messageCount** | user+assistant count | `WindsurfAdapter.swift:147-148,163` | `windsurf.ts:164` | tool/system always 0 |
| **userMessageCount** | count `role==user` | `WindsurfAdapter.swift:147,164` | `windsurf.ts:147,165` | |
| **assistantMessageCount** | count `role==assistant` | `WindsurfAdapter.swift:148,165` | `windsurf.ts:150,166` | |
| **toolMessageCount** | hard-coded `0` | `WindsurfAdapter.swift:166` | `windsurf.ts:167` | Cascade tool steps not modeled in cache |
| **systemMessageCount** | hard-coded `0` | `WindsurfAdapter.swift:167` | `windsurf.ts:168` | |
| **summary** | `(title ?: firstUserText).prefix(200)` | `WindsurfAdapter.swift:150,153,168` | `windsurf.ts:169` | empty → `nil`/`undefined` |
| **filePath / locator** | cache `.jsonl` path | `WindsurfAdapter.swift:169` | `windsurf.ts:170` | |
| **sizeBytes** | cache file size | `WindsurfAdapter.swift:170` | `windsurf.ts:171` | parity fixture = `323` bytes |
| **usage (tokens)** | none — `usage:nil` per msg | `WindsurfAdapter.swift:32`; totals `success.expected.json` all `0` | `windsurf.ts:207-211` (no usage) | `usageTotals = {input:0,output:0,cacheRead:0,cacheCreation:0}` |
| **role (per message)** | `user`/`assistant` only | `WindsurfAdapter.swift:21-26` | `windsurf.ts:201,248-251` | non-{user,assistant} dropped |
| **timestamp (per message)** | metadata `timestamp` (read only) | `WindsurfAdapter.swift:30` | `windsurf.ts:210` | never written by `writeCache` (`:72-78`) |
| **toolCalls (per message)** | `nil` | `WindsurfAdapter.swift:31` | (absent) | |
| **agentRole / originator / origin / parent / suggested** | `nil` | `WindsurfAdapter.swift:172-179` | (absent) | Windsurf never participates in parent-linking |
| **tier** | computed downstream (not adapter) | `SwiftIndexer.swift:342` (`SessionTier.compute`) | n/a | from messageCount/source/preamble/assistant/tool counts |
| **summaryMessageCount** | `stats.indexedMessageCount` | `SwiftIndexer.swift:357,378` | n/a | adapter passes `nil` (`WindsurfAdapter.swift:175`); indexer fills |
| **snapshotHash / indexedAt / syncVersion / authoritativeNode** | indexer bookkeeping | `SwiftIndexer.swift:363-365` | n/a | snapshot hash includes `cwd`, `summaryMessageCount` (`:388-400`) |

### Layer-1 wire → cache field mapping (live sync path only)

| Proto / Connect-JSON field | Type | Maps to cache field | Code |
|---|---|---|---|
| `trajectory_summaries` map key (`trajectory_id`) | string | `id` | `CascadeClient.swift:40-45` |
| `CascadeTrajectorySummary.summary` (#1) | string | `title` **and** `summary` | `CascadeClient.swift:42,46-47` |
| `created_time` (#7, `Timestamp{seconds,nanos}` or ISO) | ts | `createdAt` | `CascadeClient.swift:48,138-162` |
| `last_modified_time` (#3) | ts | `updatedAt` | `CascadeClient.swift:49` |
| `annotations.title` (#15→1) | string | **Read only by the TS gRPC fallback** (`listConversationsGrpc` maps it → `title`, `cascade-client.ts:328`). Ignored by the Connect-JSON primary path (TS `:300` uses `summary` as title) and by Swift (Connect-JSON only, no gRPC fallback). See gotcha #6/#7 §15 | `cascade.proto:16-18,25`; `cascade-client.ts:328` |
| `workspaces[0].workspaceFolderAbsoluteUri` (Connect-JSON only) | `file://…` string | `cwd` (`file://` stripped, %-decoded) | `CascadeClient.swift:128-136` |
| `ConvertTrajectoryToMarkdown.markdown` | string | parsed into `{role,content}` messages | `CascadeClient.swift:94-101`, `WindsurfAdapter.swift:37-60` |

Markdown → messages: split on `^##\s+`; header starting `user` → user; header starting
`assistant` **or `cascade`** → assistant; empty-content sections dropped
(`parseMarkdownToMessages`, `WindsurfAdapter.swift:52-57`; TS `windsurf.ts:248-251`).

---

## 15. Lineage, gotchas, version drift & edge cases

### Shared format lineage

**Windsurf ↔ Antigravity (the Cascade family).** Same engine, same code path. Both are
Codeium/"Cascade"-derived. `CascadeCacheSupport`, `CascadeClient`, `CascadeDiscovery`, and
`cascade.proto` are **literally shared** by both adapters
(`CascadeDiscovery.discoverAntigravityClient` `:4-10` vs `discoverWindsurfClient` `:12-18`).
Same daemon-JSON discovery contract (`httpPort`+`csrfToken`), same
`language_server_pb.LanguageServerService` RPCs, same Markdown→message parsing, same JSONL
cache shape (meta line + `{role,content}` lines). Both registered
`enableLiveSync:false` (`SessionAdapterFactory.swift:25-26,70-71`).

**Differences from Antigravity:** roots only —
- Windsurf: `~/.codeium/windsurf/{daemon,cascade}`. For Windsurf the `SourceCatalog`
  `defaultPath` **equals** the Cascade daemon-discovery dir: both are
  `~/.codeium/windsurf/daemon` (`SourceCatalog.swift:38`; `CascadeDiscovery.swift:13`).
- Antigravity: `~/.gemini/antigravity/daemon` (Google/Antigravity rebrand under `.gemini`)
  for Cascade daemon discovery (`CascadeDiscovery.swift:5`), and Antigravity *additionally*
  reads Antigravity CLI **brain transcripts** at `~/.gemini/antigravity-cli/brain`
  (`AntigravityAdapter.swift:22-24`). Note the asymmetry vs Windsurf: Antigravity's
  `SourceCatalog` `defaultPath` is the **brain** dir `~/.gemini/antigravity-cli/brain`
  (`SourceCatalog.swift:39`), which is a **different root** from its Cascade daemon dir
  `~/.gemini/antigravity/daemon` — two distinct roots, unlike Windsurf where the
  `SourceCatalog` `defaultPath` *is* the daemon dir.
- Antigravity's process-based discovery (`discoverClientFromProcess`) tries `ps`/`lsof`
  first; Windsurf uses daemon-dir discovery only (`CascadeDiscovery.swift:9,17`).
- **Sync RPC split:** `WindsurfAdapter.sync()` calls `getMarkdown` (prose);
  `AntigravityAdapter.syncConversation`/`syncFromPbFiles` call `getTrajectoryMessages`
  (structured `USER_INPUT`/`PLANNER_RESPONSE`/`NOTIFY_USER` steps) and only fall back to
  `getMarkdown` when the structured result is empty
  (`AntigravityAdapter.swift:153-158,192-197`). Same shared `CascadeClient`, different
  entry point — see gotcha #9.

**NOT shared with Cursor/VS Code/Copilot/Cline.** Those persist to SQLite `state.vscdb`,
`workspace.json`+`chatSessions/*.jsonl`, or per-task JSON. Windsurf is the odd one out: it
requires a *live language-server RPC bridge* and produces a private derived JSONL cache —
no shared on-disk schema with the VS Code-state family. The only coincidental overlap with
the Gemini-CLI cluster is the `.gemini` path prefix used by **Antigravity** (rebranding,
not format sharing).

### Gotchas & version drift

1. **Live sync OFF in product (biggest gotcha).** `enableLiveSync:false`
   (`SessionAdapterFactory.swift:25,70`). The adapter default is `true`
   (`WindsurfAdapter.swift:116`) but the factory overrides it. `sync()` returns immediately
   (`:204-208`); the cache is never auto-populated. Clean machine = **zero Windsurf
   sessions** even though `.pb` files exist.
2. **Empty cache despite present source.** Confirmed here: 2 live `.pb` files but empty
   `~/.engram/cache/windsurf/` and **missing** `~/.codeium/windsurf/daemon/`. Even with live
   sync enabled, discovery would fail (no daemon JSON) and need the language server
   *running* to recover a CSRF token via `ps`/`lsof` — which Windsurf's discovery path does
   **not** even attempt (it is daemon-dir only).
3. **Opaque `.pb` source (protobuf base + `.tmp` deltas, likely compressed — not "encrypted").**
   The logical format is protobuf: the official repo calls the `.pb` a protobuf "base index"
   (~40 MB) accompanied by `.tmp` "incremental snapshots" (deltas)
   ([issue #286](https://github.com/Exafunction/codeium/issues/286)). The high-entropy bytes
   Engram observes locally (first bytes `14f4 2934 face 359b …`; `file(1)` = `data`; no plaintext
   protobuf tags) are most consistent with a compressed (gzip-wrapped) and/or delta-merge layout,
   **not** encryption — no official source supports "encrypted." Either way there is no offline
   path to recover Windsurf history without the running language server; uninstall Windsurf and the
   trajectories become unreadable by Engram.
4. **`cwd` is newer than the cache format.** Caches written before the `cwd` field existed
   carry no workspace path; they backfill only when the `.pb` mtime advances
   (`WindsurfAdapter.swift:228-233`; TS comment `windsurf.ts:21-24`). Stale caches →
   `project` derives to `nil` (empty cwd at `SwiftIndexer.swift:216`).
5. **`timestamp` is structurally absent from synced caches (not "dropped").** It's not that
   `writeCache` chooses to drop an available timestamp — the in-memory message struct
   `CascadeTrajectoryMessage` (`CascadeClient.swift:12-15`) has **only** `role`+`content`,
   no timestamp field, so `writeCache` emits `{role,content}`
   (`WindsurfAdapter.swift:72-78`) because there is nothing else to emit. A synced message
   never carries a timestamp in the first place. The parser/fixtures still *read* `timestamp`
   (`windsurf.ts:198-211`, `WindsurfAdapter.swift:30`), so the key appears only in
   hand-authored fixtures/legacy caches and is absent from any cache the product regenerates.
   Because `CascadeCacheSupport.writeCache` is shared, the identical absence applies to
   Antigravity — silent reader-vs-writer drift across the whole Cascade family.
6. **Title source drift (scoped — not "neither client").** `cascade.proto` declares
   `ConversationAnnotations.title` (`:16-18,25`). The **Connect-JSON primary path** (TS
   `cascade-client.ts:300`) and **Swift** (Connect-JSON only, no gRPC fallback;
   `CascadeClient.swift:42,46-47`) ignore it and use the trajectory `summary` as the title.
   **But the TS gRPC fallback path DOES read it:** `listConversationsGrpc()` maps
   `title: s.annotations?.title ?? ''` (`cascade-client.ts:328`). So the "mis-title if a
   future Cascade build populates `annotations.title` distinctly" risk applies **only to the
   Connect-JSON / Swift paths**; the TS gRPC fallback would already pick up
   `annotations.title`. (Swift never hits the gRPC path, so for the product the
   summary-as-title behavior is what ships.)
7. **Connect-JSON vs gRPC fallback (runtime divergence — TWO fields differ).** TS prefers
   Connect-JSON and falls back to raw gRPC (`listConversationsGrpc`). The fallback differs
   from the primary path in **two** ways, not one:
   (1) **`cwd` is lost** — Connect-JSON derives `cwd` from `workspaces[0]`, the gRPC fallback
       hard-codes `cwd: ''` (`cascade-client.ts:332`);
   (2) **title source flips** — Connect-JSON uses the trajectory `summary` as the title
       (`:300`), the gRPC fallback uses `annotations.title` (`:328`). (See gotcha #6.)
   Swift (`CascadeClient.swift`) speaks Connect-JSON only over `http://localhost:<port>` with
   `x-codeium-csrf-token` — **no gRPC fallback**, so Swift always uses `summary`-as-title and
   `workspaces[0]`-derived cwd.
8. **Single-workspace assumption.** Only `workspaces[0]` is read
   (`CascadeClient.swift:129`); multi-root workspaces lose their other folders.
9. **`getTrajectoryMessages` is OFF the *Windsurf* path but is the ACTIVE path for
   Antigravity — it is NOT dead code.** The shared structured step parser
   (`USER_INPUT`/`PLANNER_RESPONSE`/`NOTIFY_USER`, `CascadeClient.swift:55-92`) is the
   primary message source for the sibling **AntigravityAdapter**, which calls
   `client.getTrajectoryMessages(...)` at `AntigravityAdapter.swift:153` (in
   `syncConversation`) and `:192` (in `syncFromPbFiles`), falling back to `getMarkdown` only
   when the structured result is empty (`:154-158,193-197`). The Cascade family splits
   cleanly across the *one* shared `CascadeClient`:
   - **Windsurf** `sync()` → `getMarkdown` (prose; Markdown split into `{role,content}` —
     `WindsurfAdapter.swift:218`).
   - **Antigravity** `sync()` → `getTrajectoryMessages` (structured steps), Markdown only as
     fallback.
   So step-type extraction is dead *only relative to Windsurf*; within the shared family it
   is a live write path. (Earlier "dead code / reserved for future use, unconfirmed"
   framing was wrong.)
10. **Timestamp encoding split.** `Timestamp{seconds,nanos}` is converted to ISO-8601 via
    `DateFormatter` (`CascadeClient.swift:138-162`); Connect-JSON may already return ISO
    strings (handled by the `is-string` branches `:139,148`). Mixed encodings across Cascade
    versions are tolerated, but **`nanos` is dropped** (millisecond precision only).
11. **`sizeBytes` is content-exact (`323`) and feeds the snapshot hash.** Any
    whitespace/line-ending change to the cache shifts `sizeBytes`
    (`success.expected.json`), and `cwd`/`summaryMessageCount` feed the snapshot hash
    (`SwiftIndexer.swift:388-400`).
12. **`detect()` is permissive.** Returns true if either the daemon dir OR the (possibly
    empty) cache dir exists (`WindsurfAdapter.swift:125-127`). So Windsurf can be "detected"
    yet surface zero sessions.

### Negative list (exhaustive — what is ABSENT from the Windsurf schema)

| Concept | Status |
|---|---|
| Tool calls / results / linkage | **Absent.** `toolCalls:nil`, `toolMessageCount:0` |
| Reasoning / thinking blocks | **Absent.** Folded into `content` if rendered to Markdown |
| Token / usage / cost | **Absent.** `usage:nil`; all `usageTotals` = 0 |
| Model name | **Absent.** `model:nil` |
| System messages | **Absent.** `systemMessageCount:0`; role filter admits only user/assistant |
| Parent/child/dispatch/originator | **Absent / nil** at adapter |
| `annotations.title` | **Present in proto. Read ONLY by the TS gRPC fallback** (`cascade-client.ts:328`). The Connect-JSON path (TS) and Swift (Connect-JSON only) ignore it, using `summary` as the title — so it is unread on the **product** (Swift) path |
| Multi-workspace cwd | **Dropped** — only `workspaces[0]` |
| Per-message timestamps in product-generated caches | **Dropped by writer** |

---

## 16. Appendix: real anonymized samples

### A. Engram cache JSONL — metadata record (line 1)
From `tests/fixtures/windsurf/cache/conv-w01.jsonl` (verbatim structure; content synthetic):
```json
{"id":"conv-w01","title":"Refactor the API","createdAt":"2026-02-18T09:00:00.000Z","updatedAt":"2026-02-18T09:20:00.000Z"}
```
Newer format with `cwd` (from `Round5RemediationTests`):
```json
{"id":"conv-1","title":"T","createdAt":"2026-02-18T09:00:00.000Z","updatedAt":"2026-02-18T09:20:00.000Z","cwd":"/Users/test/ws-project"}
```

### B. Engram cache JSONL — message records (lines 2..N)
```json
{"role":"user","content":"Refactor the API to use REST","timestamp":"2026-02-18T09:00:00.000Z"}
{"role":"assistant","content":"I'll restructure the endpoints.","timestamp":"2026-02-18T09:00:20.000Z"}
```
Product-synced (Swift `writeCache`) variant — no `timestamp`:
```json
{"role":"user","content":"Refactor the API to use REST"}
{"role":"assistant","content":"I'll restructure the endpoints."}
```

### C. Daemon discovery JSON (live sync only)
```json
{"httpPort":42100,"csrfToken":"REDACTED-csrf-token"}
```

### D. Layer-1 RPC — `GetAllCascadeTrajectories` response (Connect-JSON, anonymized)
```json
{
  "trajectorySummaries": {
    "3943ee14-bc8c-4529-adc4-07b7fb2c1f5c": {
      "summary": "Refactor the API",
      "createdTime": {"seconds": "1771405200", "nanos": 0},
      "lastModifiedTime": {"seconds": "1771406400"},
      "workspaces": [{"workspaceFolderAbsoluteUri": "file:///Users/u/proj"}]
    }
  }
}
```

### E. Layer-1 RPC — `ConvertTrajectoryToMarkdown` response (anonymized)
```json
{"markdown": "## User\nRefactor the API to use REST\n\n## Assistant\nI'll restructure the endpoints.\n"}
```

### F. Native `.pb` blob (opaque — NOT parsed; first 32 bytes, this machine)
```
00000000: 14f4 2934 face 359b 4377 7d07 6f6f 4011  ..)4..5.Cw}.oo@.
00000010: e7dc 7975 fa10 681b 8688 6a73 ca27 4391  ..yu..h...js.'C.
file(1): data    # high-entropy; no plaintext protobuf field tags → protobuf base, likely compressed
```
> Logical format is protobuf per [issue #286](https://github.com/Exafunction/codeium/issues/286)
> (protobuf "base index" + `.tmp` deltas); the high entropy reflects compression / delta-merge
> layout, not encryption.

### G. Parity golden (`tests/fixtures/adapter-parity/windsurf/success.expected.json`)

This is the **only concrete golden** Windsurf has. It has **16 top-level keys** — the
`sessionInfo` sub-object below is just **one** of them. The earlier "11-field object" was a
hand-trimmed excerpt; the full top-level record is enumerated after.

**G.1 — `sessionInfo` sub-object only (excerpt of one key):**
```json
{
  "id": "conv-w01", "source": "windsurf",
  "startTime": "2026-02-18T09:00:00.000Z", "endTime": "2026-02-18T09:20:00.000Z",
  "cwd": "", "project": null, "model": null,
  "messageCount": 2, "userMessageCount": 1, "assistantMessageCount": 1,
  "toolMessageCount": 0, "systemMessageCount": 0,
  "summary": "Refactor the API",
  "filePath": "<fixtureRoot>/windsurf/input/cache/conv-w01.jsonl", "sizeBytes": 323
}
```

**G.2 — full top-level parity-record fields (all 16 keys, verbatim from the golden):**

| Top-level key | Type | Meaning | Value in this golden |
|---|---|---|---|
| `source` | string | Adapter source id | `"windsurf"` |
| `sessionInfo` | object | The `NormalizedSessionInfo` (see G.1) | the object above |
| `messages` | array of `{role,content,timestamp}` | Full streamed messages incl. `timestamp` (fixture-only — product caches lack it, §6) | `[{role:"user",content:"…",timestamp:"…"},{role:"assistant",…}]` |
| `toolCalls` | array | Flattened tool calls (always empty for Windsurf) | `[]` |
| `usageTotals` | object | Token totals — all zero for Windsurf | `{inputTokens:0, outputTokens:0, cacheReadTokens:0, cacheCreationTokens:0}` |
| `fileToolCounts` | object | Per-file tool-use counts (empty — no tools) | `{}` |
| `insightFields` | object | Insight-extraction inputs | `{firstUserSummary:"Refactor the API", messageCount:2, toolCallCount:0}` |
| `searchIndexFields` | object | Search-index inputs | `{contentPreview:"Refactor the API to use REST\nI'll restructure the endpoints.", contentSha256InputBytes:60, roles:["user","assistant"]}` |
| `statsFields` | object | Per-role message counts | `{messageCount:2, userMessageCount:1, assistantMessageCount:1, toolMessageCount:0, systemMessageCount:0}` |
| `projectFields` | object | Project/cwd resolution | `{cwd:"", project:null, source:"windsurf"}` |
| `locator` | string | Relative locator under the fixture root | `"windsurf/input/cache/conv-w01.jsonl"` |
| `inputPath` | string | Same relative input path | `"windsurf/input/cache/conv-w01.jsonl"` |
| `failure` | null \| object | Parse failure (none here) | `null` |
| `schemaVersion` | int | Parity-record schema version | `1` |
| `generatedAtCommit` | string | Git short-SHA the golden was generated at | `"88f86631"` |
| `nodeVersion` | string | Node version that generated the golden | `"v26.0.0"` |

Note the search/insight fields that the prose otherwise never surfaces:
`searchIndexFields.contentSha256InputBytes = 60` (the byte length hashed for the search
index), `searchIndexFields.roles = ["user","assistant"]`, and
`insightFields.firstUserSummary = "Refactor the API"`.

---

## 17. Open questions / unverified (web-confirmed 2026-06-21)

The reverse-engineered claims in §1–§16 were cross-checked against external sources on
2026-06-21. Outcomes per question:

- **Q1 — conversations stored at `~/.codeium/windsurf/cascade/<id>.pb` (§1/§2).**
  **Confirmed (official):** the Exafunction/codeium repo documents
  `~/.codeium/windsurf/cascade/` as the on-disk conversation-history store holding `.pb` and
  `.tmp` files ([issue #286](https://github.com/Exafunction/codeium/issues/286),
  [issue #127](https://github.com/Exafunction/codeium/issues/127)).
- **Q2 — the `.pb` is "not plain protobuf … encrypted or compressed" (§1, gotcha #3).**
  **Confirmed (official) — corrected, see D2 above:** the official repo describes the `.pb` as
  a protobuf "base index" + `.tmp` delta snapshots; the on-disk stream is likely *compressed*
  (gzip-wrapped Connect-RPC bodies), **not encrypted**. The doc body was softened accordingly
  ([issue #286](https://github.com/Exafunction/codeium/issues/286)). The operational conclusion
  (not decodable offline; needs the language server) stands.
- **Q3 — rollover is "one conversation = one file for life" (§3).**
  **Refuted (official) — corrected, see D1 above:** Windsurf enforces a ~20-conversation
  retention cap; the 21st conversation permanently deletes the oldest, so upstream trajectories
  *are* pruned ([issue #136](https://github.com/Exafunction/codeium/issues/136)). The narrower
  sub-claim (Engram's own JSONL cache never prunes) still holds.
- **Q4 — memories/rules at `~/.codeium/windsurf/memories/{global_memories.md,global_rules.md}`
  (§2/§13).** **Confirmed (official):** auto-generated memories live in
  `~/.codeium/windsurf/memories/` and the global rules file is
  `~/.codeium/windsurf/memories/global_rules.md`
  ([Cascade Memories docs](https://docs.devin.ai/desktop/cascade/memories)). Engram correctly
  treats these as not-parsed Codeium files.
- **Q5 — local language server over HTTP/Connect-RPC with port discovery + a
  `x-codeium-csrf-token` header (§1/§2/§13).** **Confirmed (official) — partial, corrected, see
  D3 above:** Windsurf does run a local language server using Connect-RPC, and a CSRF-token
  mechanism is real, but it is version-dependent — Windsurf 1.9577+ replaced `--csrf_token` with
  `--stdin_initial_metadata`
  ([opencode-windsurf-auth #8](https://github.com/rsvedant/opencode-windsurf-auth/issues/8),
  [Windsurf Internals](https://medium.com/@GenerationAI/windsurf-internals-ac4b452807a0)). The
  exact `x-codeium-csrf-token` spelling and the `daemon/*.json` `{httpPort,csrfToken}` discovery
  file are Engram-reverse-engineered and unconfirmed by official sources; the default local LS
  port matches community-documented `LS_PORT=42100`
  ([WindsurfAPI](https://github.com/dwgx/WindsurfAPI/blob/master/README.en.md)).
- **Q6 — RPC method/service names (`exa.language_server_pb.LanguageServerService`,
  `GetAllCascadeTrajectories`, `ConvertTrajectoryToMarkdown`, `getTrajectoryMessages`)
  (§1/§14).** The `exa.*_pb` service family and `exa.language_server_pb.LanguageServerService`
  are corroborated by reverse-engineered traffic and user logs
  ([Windsurf Internals](https://medium.com/@GenerationAI/windsurf-internals-ac4b452807a0)), but
  the specific Cascade trajectory RPC method names are Engram's own reverse-engineering
  (web-checked 2026-06-21: no authoritative source found).
- **Q7 — `cascadeId` is a lowercase UUIDv4 used as the `.pb` basename (§2 naming grammar).**
  Consistent with locally observed files and Windsurf's UUID telemetry conventions, but the
  `.pb` basename grammar is not documented by any public source (web-checked 2026-06-21: no
  authoritative source found).
- **Q8 — Engram-internal claims (`enableLiveSync=false` in product, JSONL cache schema,
  timestamp writer/reader drift, Antigravity code-path sharing) (§1,§3,§6,§15).**
  (Engram-internal design — not web-verifiable.) Verify these against the Swift/TS source in the
  repo, not the web.

---

## 18. References (official sources)

- [Exafunction/codeium issue #286 — language_server memory leak (cascade `.pb`/`.tmp` disk usage)](https://github.com/Exafunction/codeium/issues/286)
- [Exafunction/codeium issue #136 — Remove or increase limit of past conversations in Cascade](https://github.com/Exafunction/codeium/issues/136)
- [Exafunction/codeium issue #127 — Windsurf Chat history Export and Search](https://github.com/Exafunction/codeium/issues/127)
- [Windsurf/Devin Cascade Memories docs (memories + rules on-disk locations)](https://docs.devin.ai/desktop/cascade/memories)
- [opencode-windsurf-auth issue #8 — Windsurf 1.9577+ uses `--stdin_initial_metadata` instead of `--csrf_token`](https://github.com/rsvedant/opencode-windsurf-auth/issues/8)
- [Wei Lu — Windsurf Internals (reverse-engineering of Connect-RPC/proto wire traffic)](https://medium.com/@GenerationAI/windsurf-internals-ac4b452807a0)
- [dwgx/WindsurfAPI README (`LS_PORT=42100` default gRPC port; `LS_DATA_DIR`)](https://github.com/dwgx/WindsurfAPI/blob/master/README.en.md)
