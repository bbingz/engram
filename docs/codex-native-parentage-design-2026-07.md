# Design Doc: Codex Native Parentage

- **Status**: Draft
- **Owner**: unassigned
- **Date**: 2026-07-24
- **Related**: `docs/competitive-mirror-2026-07.md` backlog row 22 (F4).
  Sibling specs from the same mirror pass, and the single authoritative
  implementation sequence, are indexed in that report's **Follow-up specs**
  section: `docs/insight-supersede-filter-design-2026-07.md` (row 1),
  `docs/source-health-predicate-design-2026-07.md` (row 2),
  `docs/adapter-format-drift-design-2026-07.md` (row 23). This spec is **third**
  in that sequence, and slice 4 is a hard prerequisite for row 23's first Codex
  baseline accept — see slice 4.

## Problem

Codex stamps the parent thread id of every subagent it spawns directly into the
rollout's first line, and Engram throws it away. Measured on the local corpus on
2026-07-24 (1,099 rollouts under `~/.codex/sessions/`, joined against
`~/.engram/index.sqlite`):

| Measurement | Count |
| --- | --- |
| Rollouts carrying `payload.source.subagent.thread_spawn` | 635 |
| Rollouts yielding a deterministic child → parent pair | 637 |
| Of those, indexed | 634 |
| Indexed with `parent_session_id IS NULL` | 481 |
| Of those, carrying a heuristic `suggested_parent_id` | 389 |
| Of those 389, suggestions that match the vendor-stamped parent | **0** |

The 0/389 is structural, not bad luck. `backfillSuggestedParents` draws its
candidate pool from `source IN ('gemini-cli', 'codex')`
(`macos/EngramCoreWrite/Indexing/StartupBackfills.swift:1605`) but its *parent*
pool from `source IN ('claude-code', 'claude')` (`:1625`). A Codex child spawned
by a Codex parent can never be scored against its real parent, so every
suggestion it receives is wrong by construction. Meanwhile 481 sessions the
vendor already told us are children are displayed as independent top-level
sessions, and 389 of them are offered to the user as suggested children of an
unrelated Claude Code session.

Our own format documentation already records the gap:
`docs/session-formats/codex.md:718` — "Codex's NATIVE subagent spawn tree
(`multi_agent_version: "v1"`) — NOT consumed by Engram".

Honest framing of the win: this is a **grouping** fix, not a hiding fix. 447 of
the 481 are already `tier='skip'` because `CodexAdapter` reads the top-level
`agent_role` field (`macos/Shared/EngramCore/Adapters/Sources/CodexAdapter.swift:596-598`).
Only 34 currently surface as independent `premium` sessions.

## Goals / Non-goals

- Goal: read the vendor-stamped Codex parent thread id and write it to
  `sessions.parent_session_id` for both already-indexed and newly-indexed
  rollouts.
- Goal: clear the wrong `suggested_parent_id` on exactly the rows that gain a
  vendor parent, and on no other row.
- Goal: land newly-parented children at `tier='skip'` and keep them there.
- Goal: run once over the existing corpus, self-terminate, and stay idempotent
  on every later start.
- Goal: never regress visibility — no session may become unreachable from every
  read surface as a result of this change.
- Non-goal: reading `~/.codex/state_5.sqlite` / `thread_spawn_edges`. It is
  structurally unreachable by `CodexAdapter.listSessionLocators`
  (`CodexAdapter.swift:484-495`, filter `hasPrefix("rollout-") && pathExtension == "jsonl"`;
  the file lives at `~/.codex/state_5.sqlite`, a level *above* `~/.codex/sessions/`)
  and adds zero measured coverage over the 637 JSONL-derived pairs.
- Non-goal: classifying the 7 `{"subagent":"review"}` rollouts that carry no
  parent id anywhere. Hiding sessions that have no parent to group under is a
  separate decision.
- Non-goal: parsing Codex's parent-side `collab_agent_spawn_end` events
  (`docs/session-formats/codex.md:733`). The child-side signal already resolves
  111/111 distinct parents.
- Non-goal: widening `backfillSuggestedParents` to score Codex parents. The
  vendor signal makes the heuristic unnecessary for these rows.
- Non-goal: any TypeScript change. See Test plan.

## Current state

Anchors verified at `main` @ `382693db` on 2026-07-24.

**The adapter discards the signal.** `CodexAdapter.parseSessionInfo` returns
`parentSessionId: nil` and `suggestedParentId: nil` verbatim
(`macos/Shared/EngramCore/Adapters/Sources/CodexAdapter.swift:623-624`). It
never reads `meta["source"]` or `meta["parent_thread_id"]`. It *does* read
`meta["agent_role"]` and `meta["originator"]` and derives
`effectiveRole = explicitRole ?? (isClaudeCode ? "dispatched" : nil)` (`:596-598`).

**Already-indexed rollouts will never be re-parsed by the scan.** There are two
skip layers in `SwiftIndexer`:

- Layer 1: `FileIndexDecision.decide(...) == .skip` when a `file_index_state`
  row matches size/mtime/inode/device
  (`macos/EngramCoreWrite/Indexing/SwiftIndexer.swift:200-209`).
- Layer 2: fires when `knownParseState == nil || skipKnownFileLocators`
  (`:249-271`). On the **startup** path (`indexAllSessions` passes
  `skipKnownFileLocators: true`,
  `macos/EngramCoreWrite/Indexing/EngramDatabaseIndexer.swift:430-441`) it
  `continue`s unconditionally at `:257-259` without parsing and without
  stamping. On the **periodic** path (`skipKnownFileLocators: false`) it
  compares `sessions.size_bytes` and `sessions.indexed_at` against the file and,
  on a match, calls `recordFileIndexSuccess` (`:267`) — re-stamping a fresh
  cache row — and `continue`s without parsing.

Deleting `file_index_state` rows is therefore a no-op in both directions:
startup bails before the comparison, periodic re-stamps success. The corpus is
unchanged on disk, so no identity check will ever fail. Bumping
`FileIndexState.currentSchemaVersion` would defeat layer 1 for all 17 sources at
once and still not defeat layer 2 at startup.

**The only in-tree predicate that defeats both layers** is
`needsInstructionBackfill`, derived from `sessions.instruction_count IS NULL`
(`SwiftIndexer.swift:194-197`, negating layer 1 at `:202` and layer 2 at `:253`).
It is not reusable here without double-driving instruction backfill.

**The right mechanism already exists three times**: a startup backfill that
reads the rollout head straight off disk and writes a narrow `UPDATE`, bypassing
the indexer entirely.

- `backfillCodexOriginator` (`StartupBackfills.swift:1364-1413`): selects
  unclassified codex rows 500 at a time in a `while true` loop (`:1366-1380`)
  with **no** rowid cursor, `readFirstLine(path:maxBytes: 16_384)`
  (`:1386`), JSON-parses, and on a match writes
  `agent_role = 'dispatched', tier = 'skip', link_checked_at = NULL` (`:1398-1405`)
  then calls `deleteRecoverableIndexArtifactsForSkippedSession` (`:1407`). On a
  non-match it stamps `link_checked_at = datetime('now')` (`:1392-1396`). That
  stamp is load-bearing: the loop terminates **only** because every row it
  touches is mutated out of its own candidate set. Its candidate query also
  carries `AND agent_role IS NULL` (`:1372`) and `AND suggested_parent_id IS NULL`
  (`:1374`), so it never sees — and never stamps — a row carrying a vendor role
  or a heuristic suggestion.
- `backfillCodexModelLabels` (`:1415-1462`): version-gated on `metadata` key
  `codex_model_backfill_version` (`:124-125`, checked `:1421`, stamped
  unconditionally `:1454-1460`), reading a 256 KiB head via `readFileHead`
  (`:1961-1968`, `codexModelHeadScanBytes` `:132`). It does **not** loop: it
  fetches all candidates in one `Row.fetchAll ... ORDER BY rowid` with no
  `LIMIT` (`:1423-1432`), precisely because it leaves non-matching rows
  unmutated.
- `backfillParentLinks` (`:1262-1300`): pages with an explicit rowid cursor
  (`AND rowid > ?` `:1277`, `lastRowID = row["rowid"]` assigned before any
  `continue` `:1287`) with a comment naming the hazard —
  `PARENT-BACKFILL-STARVE-001` (`:1263-1265`) — for exactly the reason above: it
  leaves rejected rows unmutated.

`readFileHead` (`:1961-1968`) returns `String(data: handle.readData(ofLength:
maxBytes), encoding: .utf8)`. On a byte-count-truncated read this returns `nil`,
not a truncated string, whenever the 262,144-byte cut lands inside a multi-byte
UTF-8 sequence. Measured on `~/.codex/sessions` on 2026-07-24: 848 of 1,099
rollouts are ≥256 KiB, **21** of them fail whole-head UTF-8 decode, and **11** of
those 21 carry a spawn parent. It is therefore not reusable here.

**Startup order** (`StartupBackfills.runStartupMaintenanceAndParents`,
`:334-378`, inside the `initialScanBackfills` write command,
`macos/EngramService/Core/EngramServiceRunner.swift:1147-1160`):
`downgradeSubagentTiers` (`:335`) → `backfillParentLinks` (`:339`) →
`resetStaleDetections` (`:343`) → `backfillCodexOriginator` (`:347`) →
`backfillPolycliProviderParents` (`:351`) → `backfillSuggestedParents` (`:366`),
then the `ready` event at `:392`. Two more call sites run a 4-step subset:
`EngramDatabaseIndexer.indexSessions(runParentBackfills: true)` (`:556-561`) and
`runPeriodicParentBackfills` (`:525-532`).

**Site 1 is not a static call.** `runStartupMaintenanceAndParents` takes
`database: any StartupBackfillDatabase` (protocol declared at
`StartupBackfills.swift:79-98`) and calls `try database.backfillParentLinks()`
(`:339`). There is no `Database` in scope. The production conformer is
`WriterStartupBackfillDatabase` (`macos/EngramCoreWrite/Indexing/StartupComposition.swift:211-213`,
each method its own `writer.write { db in ... }`); the test double is
`RecordingStartupDatabase` (`macos/EngramCoreTests/StartupBackfillTests.swift:2291`,
`backfillParentLinks` stub at `:2345-2348`), and
`testRunInitialScanEmitsNodeCompatibleStartupEventsInOrder` asserts exact array
equality on both `database.callOrder` (`:970-992`, `"backfillParentLinks"` at
`:980`) and `events` (`:993-1066`). Sites 2 and 3
(`EngramDatabaseIndexer.swift:557`, `:527`) call the static
`StartupBackfills.backfillParentLinks(_ db:)` directly.

**Which service phase actually runs which pass.** `runStartupIndex`
(`StartupBackfills.swift:213-215`) → `WriterStartupIndexing.indexAll()`
(`StartupComposition.swift:62-65`) → `indexAllSessions` →
`indexSessions(runParentBackfills: true)`. So **site 2 executes inside the index
phase**, `gate.performWriteCommand(name: "initialScanIndex")`
(`macos/EngramService/Core/EngramServiceRunner.swift:1124-1135`; the archive-v2
branch at `:1052-1062` is the equivalent), which runs *before*
`initialScanBackfills` (`:1147-1160`). Anything version-gated therefore fires in
`initialScanIndex`, and `initialScanBackfills` only ever sees the already-gated
steady-state pass.

**Link plumbing.** `validateParentLink` (`StartupBackfills.swift:1701-1718`)
rejects self-link, a nonexistent parent, a parent that itself has a parent
(depth guard, `:1710-1711`), and a child that already has children (`:1712-1717`).
`setParentSession` (`:1738-1756`) writes `parent_session_id` and `link_source`
while NULLing `suggested_parent_id`, `suggestion_status`, and
`suggestion_candidates` — and does **not** touch `tier`.

`SessionSnapshotWriter.upsert` writes `parent_session_id` with
`link_source = 'path'` through an unvalidated CASE (no self-link, existence, or
depth check; `macos/EngramCoreWrite/Indexing/SessionSnapshotWriter.swift:374-383`)
and preserves `link_source = 'manual'` (`:375`, `:380`).

**Tier.** `SessionTier.compute` returns `.skip` at the first check
`if input.agentRole != nil` (`macos/Shared/EngramCore/Indexing/SessionTier.swift:12`).
`parentSessionId` is not a tier input. Linking alone changes no tier.

**On-disk shapes** (all five verified verbatim from the corpus; `payload`
abridged to relevant keys):

1. `thread_spawn`, 635 files —
   `~/.codex/sessions/2026/03/04/rollout-2026-03-04T10-57-56-019cb6c7-d7da-7d81-97a7-f2deb2c20a8a.jsonl`:
   ```json
   {"id":"019cb6c7-...","source":{"subagent":{"thread_spawn":{"parent_thread_id":"019cb312-98af-7be2-8524-a8c90a1a2b16","depth":1,"agent_nickname":"Raman","agent_role":"explorer"}}},"agent_role":"explorer"}
   ```
2. `thread_spawn` with `agent_role: null`, 52 of the 635 —
   `.../2026/04/27/rollout-2026-04-27T17-17-38-019dce3a-e2e7-7fe0-9a91-51fdfc9d0e90.jsonl`:
   ```json
   {"id":"019dce3a-...","source":{"subagent":{"thread_spawn":{"parent_thread_id":"019dccf4-1ed7-7670-8450-48bed05894b3","depth":1,"agent_path":null,"agent_nickname":"Schrodinger","agent_role":null}}}}
   ```
   No top-level `agent_role`. These are the only rollouts whose tier can change.
3. `{"subagent":"review"}` **with** a top-level parent, 2 files —
   `.../2026/07/03/rollout-2026-07-03T10-29-20-019f25cf-2747-7cc1-b4c7-e5c56a36f615.jsonl`:
   ```json
   {"id":"019f25cf-2747-...","source":{"subagent":"review"},"parent_thread_id":"019f25cf-2679-7da2-987e-268673a8b336","thread_source":"subagent"}
   ```
   These 2 are the entire difference between 635 and 637.
4. `{"subagent":"review"}` with no parent anywhere, 7 files —
   `.../2026/03/18/rollout-2026-03-18T22-53-10-019d016f-b0e6-7102-9ac9-2ffd20fe9473.jsonl`.
   Out of scope (Non-goals).
5. `depth: 2`, 2 files —
   `.../2026/07/23/rollout-2026-07-23T19-35-32-019f8ec2-63fe-7980-a725-67ffd70e0f3c.jsonl`:
   ```json
   {"source":{"subagent":{"thread_spawn":{"parent_thread_id":"019f8db9-7892-7722-845a-1a69340ebe0b","depth":2,"agent_path":"/root/architecture_contracts/contract_ref_audit","agent_nickname":"Peirce","agent_role":null}}},"parent_thread_id":"019f8db9-..."}
   ```

Bare-string `source` values (`cli` 271, `vscode` 157, `exec` 26, `unknown` 1)
carry no parent. No other shape exists locally; in particular there is **no**
`{"other": ...}` variant on this machine, contrary to the mirror.

Where both forms are present (174 files) the two parent ids **agree 174/174**.

`readFirstLine`'s 16 KiB budget is too small for this corpus: 719 of 1,099
rollouts (65%) have a line 1 longer than 16 KiB (max 41,622 bytes), because
`base_instructions` is inlined.

## Proposed design

One new startup backfill, `StartupBackfills.backfillCodexNativeParents(_ db:)`,
modelled on `backfillCodexOriginator` + `backfillCodexModelLabels`. No adapter
change, no indexer change, no schema change, no forced re-parse.

### Why not the adapter

Reading the parent in `CodexAdapter.parseSessionInfo` would be one line, but it
buys nothing and costs three things: it never runs on the 481 existing rollouts
(both skip layers hold), it writes through the unvalidated upsert CASE at
`SessionSnapshotWriter.swift:374-383` (bypassing `validateParentLink` entirely),
and it leaves `suggested_parent_id` untouched because the upsert never writes
that column. The backfill covers new rollouts too — it runs in the same
transaction immediately after every index pass. Cut it.

### Parse rule

Do **not** reuse `readFileHead`: it decodes the whole 256 KiB read at once and
returns `nil` when the byte cut splits a multi-byte character, which silently
drops 11 rollouts that carry a spawn parent (see Current state). Add instead:

```swift
/// Reads up to `maxBytes`, truncates at the first 0x0A, and decodes only that
/// prefix, so a mid-character cut past line 1 cannot nil out the parse.
static func readFirstLineBytes(path: String, maxBytes: Int) -> String? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    let data = handle.readData(ofLength: maxBytes)
    let line = data.firstIndex(of: 0x0A).map { data[..<$0] } ?? data[...]
    return String(data: line, encoding: .utf8)
}
```

Call it with `codexModelHeadScanBytes` (256 KiB, `StartupBackfills.swift:132`),
never with `readFirstLine`'s 16 KiB. Line 1 tops out at 41,622 bytes on this
corpus, so the 256 KiB window always contains a complete line 1. JSON-decode the
result and require `type == "session_meta"`. Then:

```
parent = payload.source.subagent.thread_spawn.parent_thread_id   (if source is a dict
                                                                  and subagent is a dict
                                                                  and thread_spawn is a dict)
      ?? payload.parent_thread_id                                 (unconditional fallback)
depth  = payload.source.subagent.thread_spawn.depth               (Int?, may be absent)
```

`parent_thread_id` is an explicit JSON `null` inside `thread_spawn` in some
files — decode with `as? String`, never with a key-presence check. The
unconditional top-level fallback (not nested inside the `source`-is-a-dict
branch, as Agent Sessions does it) is the rule; it is what yields shape 3.

No `{"other": ...}` branch and no `subDict.keys.sorted().first` catch-all: zero
local instances, so neither can be tested against real data. Unknown future
`source` shapes fall through to the top-level `parent_thread_id` fallback, which
is what newer Codex builds stamp anyway.

### Candidate query

```sql
SELECT rowid, id, file_path FROM sessions
WHERE source = 'codex'
  AND file_path LIKE '%/.codex/%'
  AND parent_session_id IS NULL
  AND (link_source IS NULL OR link_source != 'manual')
  AND rowid > :cursor
ORDER BY rowid
```

**No `LIMIT`, no loop.** One `Row.fetchAll`, exactly as `backfillCodexModelLabels`
does at `:1423-1432` — which is already the in-tree precedent for a version-gated
one-shot Codex sweep, and which omits `LIMIT` for the same reason we must: this
backfill leaves rejected rows unmutated, so a `LIMIT 500` loop modelled on
`backfillCodexOriginator` would re-fetch the same first page forever. (Measured
2026-07-24: the sweep predicate at `:cursor = 0` matches **2,353** rows and only
~458 of them link, so the first page is guaranteed to contain permanently
rejected rows.) The `backfillParentLinks` rowid-cursor loop (`:1268-1287`) is the
other correct shape; it is rejected here only because the single-fetch shape is
smaller and the candidate set is bounded by the Codex corpus.

`:cursor` is the persisted high-water rowid described under "Version gate and
cursor".

`file_path LIKE '%/.codex/%'` matters: 3,004 of the 5,765 `source='codex'` rows
live under `~/.claude-openai/projects/`, are Claude-Code-shaped, carry no
`thread_spawn`, and are already parented by the `/subagents/` path regex. The
predicate also covers `~/.codex/archived_sessions/`, which `CodexAdapter`
enumerates (`CodexAdapter.swift:764-770`).

### Version gate and cursor

Add, alongside `codexModelBackfillMetadataKey` (`StartupBackfills.swift:124-125`):

```swift
static let codexSpawnParentBackfillMetadataKey = "codex_spawn_parent_backfill_version"
static let codexSpawnParentBackfillVersion = "1"
static let codexSpawnParentCursorMetadataKey = "codex_spawn_parent_scan_rowid"
```

Two keys, one mechanism:

- Read `codex_spawn_parent_backfill_version`. If it differs from
  `codexSpawnParentBackfillVersion`, this is the **one-shot sweep**: set
  `cursor = 0` so every legacy row is reachable (the 481 legacy rows all carry
  `link_checked_at NOT NULL`, so a `link_checked_at`-based predicate would never
  reach them). Otherwise read `codex_spawn_parent_scan_rowid` (default `0`) and
  use it as the cursor — the **steady-state** pass.
- Run the single-fetch candidate query above.
- At the end, unconditionally upsert both keys: the version key (exactly as
  `backfillCodexModelLabels` does at `:1454-1460`, so a partial failure cannot
  make the sweep run forever) and the cursor key set to the largest `rowid`
  seen in this pass, or left unchanged if the pass returned no rows.

**Why a rowid cursor and not `link_checked_at IS NULL`.** An earlier draft of
this design claimed the `link_checked_at IS NULL` set was self-limiting because
`backfillCodexOriginator` stamps every row it fails to classify. That is false:
its candidate query additionally requires `agent_role IS NULL` (`:1372`) and
`suggested_parent_id IS NULL` (`:1374`). Measured 2026-07-24, the
`link_checked_at IS NULL` steady-state set is **43** rows, of which **43** carry
a `suggested_parent_id` and **37** carry an `agent_role` — so
`backfillCodexOriginator` would stamp exactly **0** of them, and all 43 heads
(~11 MB) would be re-read on every service start and every periodic scan,
forever, growing by one for every future rejection. The monotone rowid cursor
gives every row exactly one attempt, ever, and drains the steady-state set to
empty.

This backfill must **not** stamp `link_checked_at` itself. Doing so would
permanently exclude the row from `backfillCodexOriginator`'s candidate query,
which requires `link_checked_at IS NULL`.

Known limit of the cursor: SQLite reuses an implicit `rowid` after the
max-rowid row is deleted (`sessions.id` is a TEXT primary key, so there is no
`AUTOINCREMENT` monotonicity guarantee). A session inserted into a reused rowid
below the high-water mark is skipped until the next version bump. Accepted:
the cost is one un-grouped session, the same outcome as today.

### Write rule, per candidate

Link only when all of these hold:

1. A parent id was parsed.
2. Vendor `depth` is absent or `<= 1`.
3. `validateParentLink(db, sessionId:parentId:)` returns `true`.
4. The prospective parent's `tier != 'skip'`.

Then, in this order:

- If `sessions.agent_role IS NULL`, write
  `UPDATE sessions SET agent_role = 'dispatched', tier = 'skip' WHERE id = ?`
  and call `deleteRecoverableIndexArtifactsForSkippedSession(db, sessionId:)`
  (`:1079`), matching `backfillCodexOriginator:1398-1408`.
- Call `setParentSession(db, sessionId:, parentId:, linkSource: "path")`
  (`:1738`). This is what clears the stale `suggested_parent_id`,
  `suggestion_status`, and `suggestion_candidates` — scoped by construction to
  exactly the rows that gained a vendor parent. The corpus holds 1,546 Codex
  rows with a non-NULL `suggested_parent_id`, so after clearing 368 the
  untouched Codex remainder is **1,178** (1,157 non-candidates plus the 21
  skip-tier-parent rejections), and the 286 suggestions from other sources are
  untouched.

Candidates failing any condition are left **completely untouched** (no link, no
role write, no suggestion clear). That makes every rejection a strict
no-regression against today's state.

Condition 2 (`depth <= 1`) removes order-dependence for every candidate that
carries an explicit vendor `depth`: without it, the outcome for the 2 depth-2
chains would depend on iteration order, because `validateParentLink` rejects in
*both* directions (link the intermediate first and the deep child fails the
"parent has a parent" check, `:1710-1711`; link the deep child first and the
intermediate fails the "child has children" check, `:1712-1717`). With the
filter, the 2 depth-2 rows are never linked and stay exactly as they are today:
top-level and visible.

Two residual order-dependencies remain and are accepted, not eliminated:

- Shape 3 (`{"subagent":"review"}` with a top-level `parent_thread_id`) carries
  no `depth` key, and the parse rule admits absent depth. A shape-3 child whose
  prospective parent is itself a linkable spawn child is still adjudicated by
  `validateParentLink` in whichever direction the sweep reaches first. Bounded
  at 2 local files.
- Condition 4 reads the prospective parent's `tier`, and the same sweep writes
  `tier = 'skip'` on role-NULL rows earlier in the pass, so a later candidate's
  parent may look skip only because we skipped it.

`ORDER BY rowid` makes both outcomes deterministic-but-arbitrary per install.
That is acceptable because both branches are no-regressions: the loser stays
exactly as it is today.

Condition 4 exists because 4 of the 111 distinct vendor parents are themselves
`tier='skip'`. Every top-level surface filters
`parent_session_id IS NULL AND suggested_parent_id IS NULL` and hides `skip`, so
a child linked under a skip parent renders on no surface at all — the parent is
never listed, so its disclosure row is never drawn. On this corpus that would
strand 21 sessions. This is the same class of regression Agent Sessions shipped
a fix for in v4.6.2; declining the link keeps them visible.

Condition 4 holds only at link time. Two later steps in the same sequence can
demote a just-linked parent: `backfillCodexOriginator` writes `tier = 'skip'`
(`:1398-1405`) with no children check, and `backfillSuggestedParents`' `.none`
branch does the same (`:1673-1690`) when the row already carries
`agent_role IN ('dispatched','subagent')`. Neither is narrowed by this design —
see Risks — so acceptance criterion 5 is stated as a post-sequence property.

### Ordering

Insert `backfillCodexNativeParents` immediately after `backfillParentLinks` at
all three call sites. Sites 2 and 3 are one-line static calls; site 1 goes
through a protocol and needs five coordinated edits.

**Sites 2 and 3 — static, one line each.**

- `EngramDatabaseIndexer.swift:557` (`indexSessions(runParentBackfills: true)`):
  `_ = try StartupBackfills.backfillCodexNativeParents(db)`
- `EngramDatabaseIndexer.swift:527` (`runPeriodicParentBackfills`): same line.

**Site 1 — `StartupBackfills.swift:339`, protocol-dispatched.** There is no
`Database` in scope; the static overload cannot be called there. Required edits:

1. `StartupBackfills.swift:79-98` — add
   `func backfillCodexNativeParents() throws -> Int` to `StartupBackfillDatabase`,
   immediately after `backfillParentLinks` at `:88`.
2. `StartupComposition.swift`, after `:213` — add
   `public func backfillCodexNativeParents() throws -> Int { try writer.write { db in try StartupBackfills.backfillCodexNativeParents(db) } }`
   to `WriterStartupBackfillDatabase`.
3. `StartupBackfills.swift:340` — call it with the same
   `if count > 0 { emit(...) }` shape as its siblings, emitting verbatim:
   ```swift
   emit(StartupBackfillEvent(
       event: "backfill",
       payload: ["type": .string("codex_native_parents"), "linked": .int(linked)]
   ))
   ```
4. `StartupBackfillTests.swift:2345` — add the stub to
   `RecordingStartupDatabase`: append `"backfillCodexNativeParents"` to
   `callOrder` and return a distinct sentinel count not already used by another
   stub.
5. `StartupBackfillTests.swift:980-981` — insert
   `"backfillCodexNativeParents"` into the expected `callOrder` array between
   `"backfillParentLinks"` and `"resetStaleDetections"`, and insert the matching
   `StartupBackfillEvent` (payload as in edit 3, `linked` = the sentinel) into
   the expected `events` array at `:993-1066` in the same position.

Rationale: it is a deterministic Layer-1 signal and must precede every advisory
layer. Placing it after `backfillCodexOriginator` or `backfillSuggestedParents`
would let those stamp `link_checked_at` / `suggested_parent_id` first and
permanently exclude the row — the documented D01 / wave-6 trap
(`EngramDatabaseIndexer.swift:551-556`). Wiring only the startup site would
leave children indexed by a periodic scan top-level until the next service
restart, which is the exact bug `runPeriodicParentBackfills` was added to fix.

### Cost and user-visible behavior

The one-shot sweep runs in the **`initialScanIndex`** phase, not
`initialScanBackfills`: site 2 is inside `indexSessions(runParentBackfills:
true)`, which `runStartupIndex` reaches first (see Current state), so the
version gate is already satisfied by the time site 1 executes. Site 1 therefore
only ever runs the steady-state pass, and after the cursor drains that is a
single indexed `SELECT` returning zero rows.

Measured on 2026-07-24: reading a 256 KiB head and JSON-parsing line 1 for all
1,099 rollouts takes **0.58 s** wall (Python, warm cache). The one-shot sweep
touches at most 2,353 rows matching the sweep predicate under `~/.codex/`,
roughly 1,101 of which still have a file on disk (the rest fail
`FileHandle(forReadingAtPath:)` immediately). Work after that is ~458 single-row
`UPDATE`s plus ≤33 per-session artifact deletions.

Search does not go blank. `EngramDatabaseWriter` wraps a GRDB `DatabasePool`, which is WAL
by construction (`macos/EngramCoreWrite/Database/EngramDatabaseWriter.swift:6-27`), so
readers run concurrently with the write transaction. No FTS rebuild is involved
— `FTSRebuildPolicy.expectedVersion` is untouched — and the only FTS delta is
≤33 sessions losing their rows because they moved to `skip`. Agent Sessions'
2.5-minute Codex-search blackout came from a full index rebuild; this design has
no such phase. No progress UI is warranted for a sub-second step; it emits the
existing `StartupBackfillEvent(event: "backfill", ...)` shape like its siblings.

### Implementation slices

**Slice 1 — parse + unit coverage.** Add
`static func codexSpawnParent(head: String) -> (parentId: String, depth: Int?)?`
and `static func readFirstLineBytes(path:maxBytes:) -> String?` to
`StartupBackfills.swift`, plus a Swift-only test that feeds the parser the five
verbatim shapes above. No SQL, no wiring.

Both helpers must be declared with **default internal access — not `private`**.
`StartupBackfillTests.swift:4` uses `@testable import EngramCoreWrite`, which
elevates `internal` to public for the test target but leaves `private` and
`fileprivate` file-scoped and unreachable. That is why every existing private
helper in `StartupBackfills` (`readFirstLine` `:1920`, `codexModelLabelFromHead`
`:1932`, `readFileHead` `:1961`, `validateParentLink` `:1701`,
`setParentSession` `:1738`) is exercised only indirectly through a public entry
point; this slice cannot follow that precedent and still be independently
landable.

*Done when:* the parser returns the right parent for shapes 1, 2, 3 and 5, `nil`
for shape 4 and for bare-string `source`, and does not crash on a `null`
`parent_thread_id`; and `readFirstLineBytes` returns line 1 intact from a file
whose byte 262,144 falls inside a multi-byte character.

**Slice 2 — the backfill, unwired, with the repro test.** Add
`public static func backfillCodexNativeParents(_ db: Database) throws -> Int`
with the single-fetch cursor query, the version gate + cursor upsert, the four
link conditions, and the role/tier + `setParentSession` writes. Add the three
metadata constants next to `:124-125`. Not called from anywhere yet. The
`_repro` test lands here, in the same PR as the function it exercises, per the
CLAUDE.md repro convention; its red state is not observable on a landed commit
(the function does not exist on `main`), so verify red by commenting out the
`setParentSession` call, re-running, and recording that in the PR description.

*Done when:* `StartupBackfillTests` proves link, depth-2 rejection, skip-parent
rejection, manual-unlink preservation, scoped suggestion clearing, `dispatched`
+ `skip` on role-NULL rows, artifact deletion, second-run no-op, third-run
no-re-read of a rejected row, >500-candidate drain where the first 500 are all
rejected, and idempotence over a row already linked to the same vendor parent.

**Slice 3 — wiring.** Apply the five edits listed under Ordering (protocol
requirement, `WriterStartupBackfillDatabase` conformance, site-1 call + emit,
`RecordingStartupDatabase` stub, both golden arrays) plus the two static call
sites.
*Done when:* `testRunInitialScanEmitsNodeCompatibleStartupEventsInOrder` **is
updated** to include `"backfillCodexNativeParents"` in `callOrder` and the
matching event in `events`, and passes. It cannot pass unmodified: both
assertions are exact array equality.

**Slice 4 — ledger and format doc.** Update the invariant 2 / 3 / 9 / 10 anchors
in `docs/invariants.md` to name the new test functions — including
`testBackfillCodexNativeParentsDeletesFtsRowsWhenTierBecomesSkip` in entry #3's
`Verified by` list at `docs/invariants.md:23`, since 32 sessions move
`premium → skip` through a new code path. Note that
`scripts/check-invariants-ledger.sh` validates backticked path existence only
(`:26-70`), not that the named test functions exist, so this is a human check.
Then run `scripts/check-invariants-ledger.sh`. Flip
`docs/session-formats/codex.md:718` and its coverage-table row from "NOT
consumed" / "(gap)" to the new consumer — **and its Chinese mirror
`docs/session-formats/codex.zh.md:692`** (`### (B) Codex 的**原生** subagent
spawn 树(`multi_agent_version: "v1"`)— Engram 不消费`), verified present in
the integration pass on 2026-07-24. Every format doc ships as an `.md` / `.zh.md`
pair (34 files, 17 pairs); editing only the English half leaves the Chinese half
asserting the opposite.
*Done when:* the ledger script passes and **both** format docs no longer claim
the field family is unread.

**Cross-spec coordination for slice 4 (integration pass, 2026-07-24).**

- `docs/invariants.md:23` (entry 3's `Verified by` line) is amended by **both**
  this spec and `docs/source-health-predicate-design-2026-07.md` (row 2, slice
  1). The two additions are a union; the recorded sequence lands row 2 first, so
  this slice rebases onto the already-amended line. Row 1
  (`docs/insight-supersede-filter-design-2026-07.md`) appends a new entry 14 and
  does not collide with either.
- `docs/adapter-format-drift-design-2026-07.md` (row 23) treats
  `docs/session-formats/codex.md` and `codex.zh.md` as **evidence artifacts**:
  its `--accept` path (Accept path, step 6) rewrites the `Last researched:`
  stamp (`codex.md:3`) and the researched-version-range line (`:10`) in every
  file listed in the format's matrix `docs` list. Those are different lines from
  `:718` / `:692`, so there is no textual conflict — but there is an ordering
  hazard: an accept run *before* this slice stamps the doc "freshly verified
  2026-07-24" while it still asserts the field family is unconsumed. **This
  slice must land before row 23's first Codex baseline accept**, or that accept
  must be re-run afterwards.

### Acceptance criteria

Measured against this machine's corpus as of 2026-07-24. All figures are
`measured-on-date`, not invariants — the corpus grows.

**Measurement protocol for criteria 1–3.** Do **not** measure these by diffing a
full service start. Four later steps in the same sequence write the same columns
— `backfillCodexOriginator` writes `agent_role='dispatched', tier='skip'`
(`:1398-1405`), `setSuggestedParent` writes `suggested_parent_id` and
`link_checked_at` (`:1773-1789`), and `backfillSuggestedParents`' `.none` branch
writes role and tier (`:1673-1690`) — so a corpus-wide `suggested_parent_id`
count falls and rises again within one start and the deltas are not attributable.
Instead: take a copy of the pre-change `~/.engram/index.sqlite`, snapshot
`id, parent_session_id, suggested_parent_id, agent_role, tier` into a temp
table, invoke `StartupBackfills.backfillCodexNativeParents(db)` **in isolation**
against that copy, and diff immediately after.

1. Run in isolation as above, `backfillCodexNativeParents` returns **458** and
   links 458 sessions with `link_source = 'path'`; each linked row's
   `parent_session_id` equals the
   `thread_spawn.parent_thread_id ?? parent_thread_id` in its rollout's line 1.
   (This figure assumes the line-bounded `readFirstLineBytes` helper. Reusing
   `readFileHead` yields 453 — the 5-row gap is the whole-head UTF-8 decode
   failure documented under Current state, and is a defect, not a tolerance.)
2. **368** of those rows go from `suggested_parent_id NOT NULL` to
   `suggested_parent_id IS NULL` in the isolated run, and no other row's
   `suggested_parent_id` changes. Cross-check against the single consistent
   total: 1,546 Codex rows carry a suggestion before the run, 1,178 after; the
   189 gemini-cli, 52 qwen, 25 claude-code, 13 copilot, 4 opencode, and 3 pi
   suggestions are unchanged (286 total).
3. **33** rows go from `agent_role IS NULL` to `agent_role = 'dispatched'`, of
   which **32** go from `tier = 'premium'` to `tier = 'skip'`. No row's `tier`
   changes in the other direction. `sessions_fts` is chunk-granular, not one row
   per session (329,887 rows across 3,338 distinct `session_id` on this corpus),
   so assert `SELECT COUNT(DISTINCT session_id) FROM sessions_fts` drops by
   exactly 32 and `SELECT COUNT(*) FROM sessions_fts WHERE session_id IN
   (<the 32 ids>)` is 0.
4. The **2** depth-2 rollouts (`019f8ec2-63fe-7980-a725-67ffd70e0f3c`,
   `019f8eef-81bf-7671-a401-22336a1b743a`) still have `parent_session_id IS NULL`
   and their pre-existing `tier`.
5. The **21** rows whose vendor parent is `tier='skip'` still have
   `parent_session_id IS NULL`. Checked **after the full startup sequence has
   completed** (i.e. after `backfillSuggestedParents` returns, not after our
   function returns): no session has a non-NULL `parent_session_id` pointing at
   a `tier='skip'` row as a result of this change. If this fails, the cause is
   a later step demoting a parent we linked — see Risks; it is not fixable
   inside `backfillCodexNativeParents`.
6. A second service start links 0 additional rows, changes 0 rows, and reads
   **0** file heads — the version gate short-circuits the sweep and the persisted
   `codex_spawn_parent_scan_rowid` leaves the steady-state query with an empty
   result set. A third start likewise re-reads no head belonging to a row
   rejected on the first pass.
7. Any row with `link_source = 'manual'` and `parent_session_id IS NULL` before
   the run still has both after the run.
8. Read the phase durations emitted by `runInitialScanPhase`
   (`macos/EngramService/Core/EngramServiceRunner.swift:1124`, `:1147`). The
   **`initialScanIndex`** phase — where the one-shot sweep actually runs — is
   within +2.0 s of the pre-change baseline on the first start after upgrade.
   Both phases are within +100 ms of baseline on every subsequent start.
9. `npm run lint` passes and no file under `src/`, `scripts/`, or
   `tests/fixtures/` is modified.

## Invariants affected

**#2 Subagent Sessions Stay Skip** (`docs/invariants.md:12-17`) — touched and
preserved. `setParentSession` is not modified and still writes no `tier`. The
`skip` classification for the 33 role-NULL rows is a *separate* write, the same
one `backfillCodexOriginator:1398-1403` already performs, and it only ever moves
a row into `skip`. Add the new tests to this entry's `Verified by` list.

**#3 Tier Visibility** (`:19-24`) — touched. 32 sessions move `premium → skip`
and are removed from `sessions_fts` and the other recoverable artifact tables via
`deleteRecoverableIndexArtifactsForSkippedSession` (`:1079-1116`), which is the
established discipline for every skip-writing backfill. No session becomes more
visible. Add `testBackfillCodexNativeParentsDeletesFtsRowsWhenTierBecomesSkip`
to this entry's `Verified by` list (`docs/invariants.md:23`).

**#9 Startup Backfills Are Ordered and Idempotent** (`:61-66`) — touched. The
new step is version-gated on `codex_spawn_parent_backfill_version`, stamps that
key and the `codex_spawn_parent_scan_rowid` cursor unconditionally so it
self-terminates, and is placed immediately after `backfillParentLinks` and
before every advisory layer at all three call sites. Add the new tests to this
entry.

**#10 Manual Unlink Is Respected** (`:68-73`) — touched. The candidate query
carries `(link_source IS NULL OR link_source != 'manual')`, matching
`:1276` and `:1471`. Add the new test to this entry.

**#4 Parent-Detection Parity Triple Lock** (`:26-31`) — **not** touched.
`ParentDetection.detectionVersion` governs heuristic scoring only, and bumping it
would not help: every `UPDATE` in `resetStaleDetections` carries
`AND suggested_parent_id IS NULL` (`:1324`, `:1336`), so it can never re-open the
389 rows that carry a wrong suggestion. Using a private metadata key instead
keeps `src/core/parent-detection.ts` and
`tests/fixtures/parent-detection/detection-version.json` out of scope.

**#11 Sessions Schema Migrations Are Idempotent** (`:75-80`) — **not** touched.
No new column. `parent_session_id`, `suggested_parent_id`, `link_source`,
`link_checked_at`, `agent_role`, and `tier` all exist. Only two `metadata` rows
are added.

**#13 JSONL Tail Checkpoints** (`:89-94`) — **not** touched.
`CodexAdapter.scanTailForIndexing` and `file_index_state` are not modified. The
backfill reads file heads with its own `FileHandle` and writes no cache rows.

**#1 / #12 Single-writer** (`:5-10`, `:82-87`) — preserved. The code lives in
`EngramCoreWrite` and runs inside three gated write commands, never outside one:
`gate.performWriteCommand(name: "initialScanIndex")`
(`EngramServiceRunner.swift:1130`) — where the heavy one-shot sweep executes —
`gate.performWriteCommand(name: "initialScanBackfills")` (`:1153`), and
`gate.performWriteCommand(name: "periodicParentBackfills")` (`:793`). No script,
no app-side migration.

**#5 FTS Full Rebuild Versioning** (`:33-38`) — **not** touched.
`FTSRebuildPolicy.expectedVersion` is unchanged; the FTS delta is 32 targeted
row deletions.

## Alternatives considered

**Read the parent in `CodexAdapter.parseSessionInfo` and let it flow through
`NormalizedSessionInfo`.** This is what the mirror literally proposed. Lost
because it never executes on the 481 already-indexed rollouts (both skip layers
hold), it bypasses `validateParentLink` entirely through
`SessionSnapshotWriter.swift:374-383`, and it cannot clear
`suggested_parent_id`, which that upsert never writes.

**Delete `file_index_state` rows to force a re-parse.** Lost because it is a
verified no-op: the startup path `continue`s at `SwiftIndexer.swift:257-259`
before comparing anything, and the periodic path re-stamps a success row at
`:267` without parsing. It would also destroy the `parsed_offset` /
`boundary_hash` chain invariant 13 protects.

**Bump `FileIndexState.currentSchemaVersion`.** Lost because it invalidates
layer 1 for all 17 sources — a multi-GB reparse; the Codex corpus alone is
6.2 GB — and still does not defeat layer 2 at startup.

**Add a `needsSpawnParentBackfill` predicate to `KnownIndexedFileState` to force
a real re-parse.** This is the one mechanism that provably defeats both layers,
and it is how `needsInstructionBackfill` works. Lost because a full re-parse of
these rollouts costs gigabytes of I/O, rewrites every `snapshot_hash`, and
re-enqueues FTS jobs, to recover a value that lives in the first 41 KB of the
file.

**Read `~/.codex/state_5.sqlite`'s `thread_spawn_edges`.** It is the vendor's
authoritative graph. Lost because it adds a live vendor-SQLite read surface for
zero measured coverage gain: the JSONL signal already resolves all 637 pairs and
all 111 distinct parents.

**Bump `ParentDetection.detectionVersion` to clear the 389 stale suggestions.**
Lost because `resetStaleDetections` only re-opens rows with
`suggested_parent_id IS NULL` (`:1324`, `:1336`), so it clears none of them, and
it would drag two TypeScript files into scope.

**Flatten depth-2 links to the root ancestor instead of declining them.** Lost
because the UI renders exactly one level (`ExpandableSessionCard` fetches
children only for top-level cards), so re-pointing a grandchild at a grandparent
it was not spawned by trades an invisible session for a misattributed one, over
2 rows.

**Bound the steady-state pass by recency (`AND indexed_at >= datetime('now','-7
days')`) instead of a rowid cursor.** Proposed in review as the fix for the false
"self-limiting" claim. Lost because it is a decay, not a bound: a rejected row
inside the window is still re-read on every start for seven days, and a row
indexed while the service was down for longer than the window is never attempted
at all. The rowid high-water cursor gives every row exactly one attempt, ever.

**Widen `backfillSuggestedParents`' parent pool to include `source='codex'`.**
Lost because a deterministic vendor signal beats a heuristic; the heuristic would
still be advisory and would still need adjudication.

## Test plan

All Swift. No TypeScript change is required: the Codex parity input fixture
`tests/fixtures/adapter-parity/codex/input/.../rollout-sample.jsonl` has
`"source":"cli"` and no parent field, and
`tests/fixtures/adapter-parity/codex/success.expected.json` has no
`parentSessionId` key in `sessionInfo`, so the full-struct equality assert at
`macos/EngramCoreTests/AdapterParityTests.swift:204` is unaffected — and this
design does not touch the adapter at all. Do **not** add a `thread_spawn` case
to that fixture: the goldens are generated from `src/adapters/codex.ts` by
`scripts/gen-adapter-parity-fixtures.ts`, so doing so would force TypeScript work
for no product benefit.

**Not to be confused with row 23 (integration pass, 2026-07-24).**
`docs/adapter-format-drift-design-2026-07.md` requires, when a *new bucket* is
accepted, a line appended to `tests/fixtures/<source>/new-types.jsonl` plus a
named case in `macos/EngramCoreTests/AdapterSchemaDriftTests.swift`. That is the
**`tests/fixtures/codex/` hand-written tree**, which is not regenerated by
`scripts/gen-adapter-parity-fixtures.ts`. The prohibition above is specifically
on **`tests/fixtures/adapter-parity/codex/`**, the generated golden tree. The two
requirements do not conflict; do not read row 23 as licence to touch the parity
goldens, and do not read this paragraph as a ban on row 23's drift fixtures.
This spec's acceptance criterion 9 (`no file under `tests/fixtures/` modified`)
is scoped to this spec's own diff.

**Seeding helper prerequisite.** The existing
`insertSession(_:id:source:...)` helper at `StartupBackfillTests.swift:1924`
cannot seed the two columns these tests assert on: its parameter list
(`:1925-1946`) and INSERT column list (`:1951-1956`) expose `suggestion_status`
and `suggestion_candidates` but neither `suggested_parent_id` nor
`parent_session_id`. Slice 2 extends it: add
`suggestedParentId: String? = nil` and `parentSessionId: String? = nil`
parameters plus the matching columns and bind arguments. Defaults keep every
existing call site unchanged. Four tests below depend on this
(`..._repro`, `...ClearsOnlyLinkedRowsSuggestions`, `...SkipsSkipTierParents`,
`...IsIdempotentOverAlreadyLinkedRows`).

**Repro test.** `macos/EngramCoreTests/StartupBackfillTests.swift`, using that
extended `insertSession` helper and the existing `writer` / `tempDB` fixture at
`:7-23`:

```swift
// docs/codex-native-parentage-design-2026-07.md — mirror row 22.
func testBackfillCodexNativeParentsLinksVendorStampedChild_repro() throws
```

Write a real rollout file to a temp directory whose line 1 is shape 1 verbatim,
seed the parent and the child with `insertSession(... source: "codex",
filePath: <that path>, agentRole: nil, tier: "premium",
linkCheckedAt: "2026-07-01T00:00:00.000Z",
suggestedParentId: <an unrelated claude-code session id>)`, then assert:

- Before: `parent_session_id IS NULL` and `suggested_parent_id` is the wrong id.
- `StartupBackfills.backfillCodexNativeParents(db)` returns 1.
- After: `parent_session_id` == the vendor parent, `link_source == "path"`,
  `suggested_parent_id IS NULL`, `agent_role == "dispatched"`, `tier == "skip"`.

The red state is not observable on a landed commit — the function does not exist
on `main`, so the test does not compile there. Establish red inside slice 2 by
commenting out the `setParentSession` call and re-running, and record that in the
PR description rather than claiming a pre-fix assertion failure.

**Supporting tests, same file:**

| Name | Assertion |
| --- | --- |
| `testBackfillCodexNativeParentsSkipsDepthTwoChains` | shape-5 line 1 → returns 0, child keeps `parent_session_id IS NULL` and its original tier |
| `testBackfillCodexNativeParentsSkipsSkipTierParents` | parent seeded `tier: "skip"` → returns 0, child untouched including its suggestion |
| `testBackfillCodexNativeParentsPreservesManualUnlink` | child seeded `linkSource: "manual"` with NULL parent → returns 0 |
| `testBackfillCodexNativeParentsClearsOnlyLinkedRowsSuggestions` | two children, one with a vendor parent and one without; only the linked one loses its `suggested_parent_id` |
| `testBackfillCodexNativeParentsUsesTopLevelParentThreadIdFallback` | shape-3 line 1 → linked |
| `testBackfillCodexNativeParentsReadsLineOneBeyond16KiB` | line 1 padded past 16 KiB with a `base_instructions` blob → still linked (guards against reusing `readFirstLine`) |
| `testBackfillCodexNativeParentsDecodesLineOneAcrossMultiByteHeadBoundary` | file padded past 256 KiB with a multi-byte character straddling byte 262,144 → still linked (guards against reusing `readFileHead`, whose whole-head `String(data:encoding:)` returns nil) |
| `testBackfillCodexNativeParentsDrainsPastAFullyRejectedFirstPage` | seed >500 candidates whose first 500 by rowid are all rejected (depth-2), one linkable row after them → returns 1 and terminates (guards against copying `backfillCodexOriginator`'s cursorless `LIMIT 500` loop) |
| `testBackfillCodexNativeParentsDoesNotRereadRejectedRowsOnThirdCall` | one rejected candidate; after call 1 stamps the version + cursor, delete its rollout file, then call twice more → returns 0 both times with no file access (guards the cursor, since `backfillCodexOriginator` will never stamp such a row) |
| `testBackfillCodexNativeParentsPreservesExistingAgentRole` | child seeded `agentRole: "explorer"` → role unchanged, tier unchanged, still linked |
| `testBackfillCodexNativeParentsDeletesFtsRowsWhenTierBecomesSkip` | seed a `sessions_fts` row, assert it is gone (pattern: `testDowngradeSubagentTiersAndRemoveFTSRows` at `:25`) |
| `testBackfillCodexNativeParentsVersionGatePreventsSecondSweep` | second call returns 0 and reads no heads; delete the rollout file between calls to prove no read (pattern: `testBackfillCodexModelLabelsVersionGatePreventsSecondScan`) |
| `testBackfillCodexNativeParentsIsIdempotentOverAlreadyLinkedRows` | child pre-seeded with the correct vendor parent and `link_source: "path"` → returns 0, row byte-identical |
| `testBackfillCodexNativeParentsIgnoresClaudeOpenAIPaths` | `source: "codex"` with `filePath` under `~/.claude-openai/projects/` → not selected |

**Intentionally not tested:** the 7 parentless `{"subagent":"review"}` rollouts
(explicit non-goal); `state_5.sqlite` (non-goal); the exact wall-clock of the
sweep (measured out-of-band, asserted only as an ordering/no-op property).

## Rollout

No version bump, no migration, no schema change. Ships with the next
`EngramService` build. The one-shot sweep runs inside the **`initialScanIndex`**
phase on the first start after upgrade (call site 2, reached by `runStartupIndex`
before `initialScanBackfills` — see Current state), before the `ready` event, and
adds under two seconds. `initialScanBackfills` sees only the already-gated
steady-state pass. The user sees the existing backfill status text; nothing
blanks, and readers keep serving from WAL throughout.

Revert story: remove the three call sites. Already-written links persist and are
correct — they are `link_source='path'` rows identical in shape to what
`backfillParentLinks` produces — and the orphaned `metadata` rows are inert. To
fully undo, `DELETE FROM metadata WHERE key IN
('codex_spawn_parent_backfill_version', 'codex_spawn_parent_scan_rowid')`
and re-run with the reverted binary; the links themselves would need a manual
`UPDATE` and are not automatically reversible, which is why slice 3 is the last
slice to land.

## Risks and open questions

**High — 21 sessions stay mis-suggested rather than correctly linked.**
Condition 4 declines any link whose parent is `tier='skip'`, so those children
keep whatever wrong `suggested_parent_id` they have. This is deliberate: the
alternative makes them invisible on every surface. Revisit only alongside a
decision about whether a skip-tier parent should render a disclosure row.

**Medium — a parent we link can be skip-demoted later in the same sequence.**
Condition 4 is evaluated at link time, but two steps that run after us write
`tier = 'skip'` with no "has children" check: `backfillCodexOriginator`
(`:1398-1405`) and `backfillSuggestedParents`' `.none` branch (`:1673-1690`, only
when the row already carries `agent_role IN ('dispatched','subagent')`). Either
can hide children this design just grouped — the exact regression condition 4
exists to prevent. Structurally bounded: measured 2026-07-24, **0** of the 111
distinct vendor parents carry `originator == "Claude Code"` in their own rollout
head, so `backfillCodexOriginator` demotes none of them today, and
`backfillSuggestedParents` reaches only parents that are already dispatch-marked.
A review asked to close this by adding
`AND NOT EXISTS (SELECT 1 FROM sessions c WHERE c.parent_session_id = sessions.id)`
to those two `UPDATE`s. **Declined as scope expansion**: both statements predate
this design, the change would alter tiering for every source, and it needs its
own repro. Handled here by stating acceptance criterion 5 as a post-sequence
property so the regression is at least detectable. File the narrowing separately.

**Medium — pre-existing defect inherited by the neighbourhood, not by this
change.** `backfillCodexOriginator:1386` reads only 16 KiB of line 1, which
truncates 719 of 1,099 rollouts (65%), including 62 of the 131 rollouts with
`originator == "Claude Code"`. Those rows are stamped `link_checked_at` and
silently never classified. This design uses 256 KiB and does not touch that
function; fix it in a separate PR per the surgical-diff rule.

**Medium — the local baseline is not a clean baseline.** 153 of the 634 indexed
vendor children *already* carry the correct vendor parent with
`link_source='path'`, and 153/153 match. No code at `main` can produce this:
`CodexAdapter` returns `nil` and `backfillParentLinks` requires an
`agent_role='subagent'` row with a `/subagents/` path. **Open question:** the
provenance is unknown — most likely an out-of-band developer write. Consequence:
on a fresh install the sweep would link roughly 634, not 458, and the acceptance
numbers in this doc would not reproduce. The idempotence test over the
already-linked shape exists precisely because this state is unexplained.

**Medium — `agent_role` vocabulary and the orphan-cascade hole.**
`trg_sessions_parent_cascade` (`macos/EngramCoreWrite/Database/EngramMigrations.swift:88-91`,
`:97-100`) resets `tier` to NULL — which
`SessionVisibilityFilter.nonSkipTierSQL` treats as *visible* — for any orphaned
child whose `agent_role` is not literally `'subagent'` or `'dispatched'`. 599
Codex children already carry vendor roles (`explorer`, `worker`, `awaiter`,
`default`, `lazycodex-*`, `metis`) that are in neither list, so the hole exists
today. This design writes `'dispatched'` for the 33 role-NULL rows specifically
so it does not enlarge the hole, but it does raise the number of *linked* rows
exposed to the trigger from 153 to ~611. **Open question:** extend the trigger's
role list (and `downgradeSubagentTiers:1072`) to cover the vendor vocabulary, or
leave it? Out of scope here; file separately.

**Low — format drift.** Codex changed this field family at least three times
inside the corpus window: `thread_spawn` added, `{"subagent":"review"}` at
~0.115.0, top-level `parent_thread_id` for review subagents at 0.143.0-alpha.34.
The unconditional top-level fallback is the drift absorber. A future nested
variant with a *new* wrapper key and no top-level stamp would read as a root
session. Accepted: no local instance exists to test against, and Agent Sessions'
`subDict.keys.sorted().first` catch-all sets `subagentType`, not the parent id,
so it would not help here either.

**Low — 3 rollouts carrying a vendor parent are not indexed** as of 2026-07-24
(`019f912f…`, `019f9130…`, `019f9136…`, all created that day). **Open question:**
whether they are simply newer than the last scan or carry a `file_index_state`
failure; not checked. They will be picked up by the steady-state pass either way.

**Open question — does the app render a child under a `tier='skip'` parent at
all?** Condition 4 was derived from the top-level SQL filter
(`parent_session_id IS NULL AND suggested_parent_id IS NULL`) plus the tier
filter, not from opening `ExpandableSessionCard` / `SessionsPageView` and
confirming the disclosure row is never drawn. Unverified. If it turns out a skip
parent *is* listed, condition 4 becomes unnecessary and 21 more sessions can be
linked.

**Open question — `~/.codex/archived_sessions/` content.** The candidate
predicate covers it via `LIKE '%/.codex/%'`, but the 2 files there were not
scanned for spawn signals. Unverified; harmless either way.

**Open question — Swift wall-clock.** The 0.58 s figure is Python over a warm
page cache. `FileHandle` + `JSONSerialization` plus GRDB write-transaction
overhead for ~458 `UPDATE`s is expected to be the same order but was not
measured. Acceptance criterion 8 is the guard.
