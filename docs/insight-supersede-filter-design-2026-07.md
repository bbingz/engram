# Design Doc: Superseded Insights Must Not Reach Agent-Facing Reads

- **Status**: Draft
- **Owner**: unassigned
- **Date**: 2026-07-24
- **Related**: `docs/competitive-mirror-2026-07.md` backlog row 1 (F1, effort S).
  Sibling specs from the same mirror pass, and the single authoritative
  implementation sequence, are indexed in that report's **Follow-up specs**
  section: `docs/source-health-predicate-design-2026-07.md` (row 2),
  `docs/codex-native-parentage-design-2026-07.md` (row 22),
  `docs/adapter-format-drift-design-2026-07.md` (row 23). This spec is **first**
  in that sequence.

## Problem

Measured on the live database today (`~/.engram/index.sqlite`, read-only query
`SELECT count(*), sum(superseded_by IS NOT NULL) FROM insights`): **127 insights,
0 superseded**. The leak this doc fixes is therefore *latent*, not observed. No
agent has yet been served a stale memory, because nothing has been superseded
yet.

What is broken is the contract, not (yet) the output. The writer already treats
`superseded_by IS NULL` as the definition of the active memory set —
`findDuplicateInsight` scopes deduplication to non-superseded rows
(`macos/EngramService/Core/EngramServiceCommandHandler.swift:2067`) — and
`saveInsight` marks the old row superseded on a normalized-duplicate re-save
(`:1882-1891`) *without* deleting its `insights_fts` entry (`:1892-1896`). Every
agent-facing read then ignores the flag. The first duplicate save in the field
turns a correctness bug into a serving bug with no further code change.

Two claims in the mirror do not survive verification and must not be repeated:

- **"the tool the SessionStart hook calls"** — the shipped hook runs
  `EngramCLI context --cwd … --timeout-ms 2500 --max-bytes 8192` with no
  `--task` (`integrations/claude-code/engram/scripts/session-start-context:29`),
  `EngramCLI` only forwards `task` when non-empty
  (`macos/Shared/Service/EngramCLIContextCommand.swift:357-358`), and
  `get_context` gates its whole memory block on `task.count >= 3`
  (`macos/EngramMCP/Core/MCPDatabase.swift:1513`). The SessionStart hook injects
  **zero** memories today. The reachable callers are explicit `get_context` calls
  carrying a task (the `catch-up` skill / `engram:catch-up` prompt) and the
  `search` keyword path.
- **"no existing test covers get_context insight injection"** — false.
  `testGetContextWithMemoryMatchesGolden`
  (`macos/EngramMCPTests/EngramMCPExecutableTests.swift:2761-2769`) byte-compares
  against `tests/fixtures/mcp-golden/get_context.engram.with_memory.json`, which
  contains five `[memory] …` lines and a `+ 5 memories` footer. What is genuinely
  uncovered is *supersede filtering*.

Justification for doing the work now is the asymmetry, not observed harm: one
shared helper serves five callers, the fix is a few lines behind an existing
probe, and the window in which no superseded rows exist is exactly the cheapest
time to close it.

## Goals / Non-goals

- Goal: no superseded insight is returned by any agent-facing read in
  `EngramMCP` — `get_context`, `search` (keyword), `get_memory` on every branch,
  the semantic RRF keyword leg, and `resources/list`.
- Goal: behavior on an un-migrated `insights` table (no lifecycle columns) is
  unchanged and never errors. `EngramMCP` opens the DB read-only
  (`macos/EngramMCP/Core/MCPDatabase.swift:62-67`, `configuration.readonly = true`)
  and must not assume the writer's schema (`:529-532`).
- Goal: no change to any existing MCP wire contract — no `outputSchema` edit, no
  golden-fixture regeneration.
- Non-goal: emitting `id` / `importance` / `type` on `search` insight rows. Cut;
  see Alternatives.
- Non-goal: adopting `get_memory`'s lifecycle ranking in `get_context`. Cut; see
  Alternatives.
- Non-goal: incrementing `access_count` for search- or context-surfaced
  insights. Cut; see Alternatives.
- Non-goal: filtering `insightContent(id:)`
  (`macos/EngramMCP/Core/MCPDatabase.swift:2087-2095`), which backs
  `resources/read` for an explicitly named `engram://insight/<id>`. Once the
  catalog is filtered (slice 2) superseded ids are no longer discoverable; an
  agent that names a specific id gets that id.
- Non-goal: the app-facing service reads
  (`macos/EngramService/Core/EngramServiceReadProvider.swift:1076-1126`) and
  `MemoryView` (`macos/Engram/Views/Pages/MemoryView.swift:234`). That is a human
  management UI, and `EngramServiceInsightInfo`
  (`macos/Shared/Service/EngramServiceModels.swift:599-615`) has no field that
  could even express "superseded", so "show it, marked" would cost a DTO + IPC
  change for no agent-correctness gain.
- Non-goal: any TypeScript change. `superseded_by` appears in zero `.ts` files;
  the reference schema has no lifecycle columns
  (`src/core/db/migration.ts:518-529`), so there is nothing to filter and no
  parity fixture to keep in step.
- Non-goal: any schema or migration work. The columns and
  `idx_insights_superseded` already exist and the migration is idempotent
  (`macos/EngramCoreWrite/Database/EngramMigrations.swift:1137-1153`).

## Current state

Verified at `main` @ `382693db`.

`searchInsightsFTS` is the single shared insight-retrieval helper, spanning
`macos/EngramMCP/Core/MCPDatabase.swift:1959-1996`. Neither branch filters
lifecycle:

- CJK branch (`:1964-1970`):
  `SELECT * FROM insights WHERE content LIKE :pattern ESCAPE '\' ORDER BY created_at DESC LIMIT :limit`.
- FTS branch (`:1973-1988`):
  `SELECT i.* FROM insights_fts f JOIN insights i ON i.id = f.insight_id WHERE insights_fts MATCH :query ORDER BY f.rank LIMIT :limit`,
  with a quoted-query retry on any thrown error (`:1990-1995`).

Its five callers:

| Caller | Site | Can leak superseded rows today |
| --- | --- | --- |
| `get_context` | `:1514` (`limit: 5`) | yes |
| `search` keyword | `:1075` (`limit: 5`) | yes |
| `get_memory` legacy fallback | `:553` (`limit: 10`) | n/a — reached only when the lifecycle columns are absent (probe at `:464`, branch at `:533`) |
| `get_memory` lifecycle path via `rankedActiveInsights` | `:677` (`limit: 40`) | no — Swift filter at `:678`; but the 40-row candidate set changes, see "Candidate-set effects" |
| `semanticMemory` RRF keyword leg | `:848` (`limit: 40`) | no — post-fusion filter at `:856` when `lifecycleAware`; but RRF input ranks change, see "Candidate-set effects" |

`get_context` emits each row as `"[memory] \(content)\n"` with no id, importance
or type (`:1513-1523`). `search` emits `insightResults` as bare content strings,
keyword path only, gated on `query.count >= 3` (`:1074-1083`); the semantic and
hybrid response builders emit no insights at all (`:1266-1277`).

`get_memory` chooses its branch on `insightsHasLifecycleColumns()` — a
`PRAGMA table_info(insights)` probe for `superseded_by` **and** `insight_type`
**and** `access_count` (`:663-671`) — taking the lifecycle path at `:533-551`
and the raw fallback at `:553-574`. That fallback is *not* a leak: if the columns
are absent, no row can be superseded.

`listInsightsByWing` (`:1998-2013`) is also unfiltered, and feeds
`recentResourceCatalog` (`:2042-2084`, insights at `:2072`), which publishes up
to 15 `engram://insight/<id>` MCP resources for `@`-mention autocomplete
(`macos/EngramMCP/Core/MCPToolRegistry.swift:1360`). This is a fourth
agent-facing surface the mirror did not list.

Constraints discovered in the fixture and schema layer:

- `tests/fixtures/mcp-contract.sqlite` has the pre-lifecycle 8-column `insights`
  table (`id, content, wing, room, source_session_id, importance, has_embedding,
  created_at`; verified via `PRAGMA table_info`) and holds 10 insights. An
  unconditional `AND superseded_by IS NULL` throws `no such column` against it.
- The error is not survivable: the FTS retry re-runs the same broken SQL
  (`:1990-1995`), `get_context:1514` and `keywordSearchResponse:1075` use bare
  `try`, and the registry catch-all degrades `search` to
  `"Search failed. Check the Engram database and retry."`
  (`macos/EngramMCP/Core/MCPToolRegistry.swift:990-994`).
- `MCPOutputSchemas.search` declares
  `"insightResults":{"type":"array","items":{"type":"string"}}` inside an
  `additionalProperties:false` root
  (`macos/EngramMCP/Core/MCPOutputSchemas.swift:63-65`), enforced at runtime by
  `testStructuredContentMatchesDeclaredOutputSchema`
  (`macos/EngramMCPTests/EngramMCPExecutableTests.swift:411-464`, checker at
  `:6741-6791`).
- `get_context` declares no `outputSchema` and returns `.textOnly`
  (`macos/EngramMCP/Core/MCPToolRegistry.swift:996-1006`); it is excluded from
  `coveredToolNames` (`MCPOutputSchemas.swift:6-10`) and a test asserts that
  exclusion (`EngramMCPExecutableTests.swift:376`).
- `get_insights` is the **cost** tool (`macos/EngramMCP/Core/MCPInsightsTool.swift:3-47`),
  unrelated to the `insights` table. Its schema is out of scope entirely.

## Proposed design

Push the active-set predicate into SQL in the two shared helpers, gated on the
existing column probe. Nothing else.

```swift
// MCPDatabase.swift, near :1959
private func supersededFilterSQL(alias: String) -> String {
    ((try? insightsHasLifecycleColumns()) == true) ? " AND \(alias)superseded_by IS NULL" : ""
}
```

#### Where the probe is evaluated (mandatory — nesting traps)

`insightsHasLifecycleColumns()` is itself `try queue.read { … }` (`:663-671`),
and `queue` is a serial `DatabaseQueue` (`:59`). GRDB 6.29.3 (pinned in
`macos/Engram.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved:19`)
does not permit nested access: `GRDBPrecondition(!watchdog.allows(db),
"Database methods are not reentrant.")`, verified at tag `v6.29.3` in the local
SPM repository cache, `GRDB/Core/SerializedDatabase.swift:132`. That is a
precondition failure, not a catchable error.

Every SQL literal this change edits sits **inside** a read closure: the CJK
literal inside `try queue.read { db in` (`:1964`, literal at `:1967`); the FTS
literal inside `readRetryingTransientMissingFTS` (`:1974`), which is
`try queue.read(block)` (`:2277-2291`, call at `:2285`); both `listInsightsByWing`
statements inside `try queue.read { db in` (`:1999`). Interpolating
`supersededFilterSQL(...)` directly into those literals therefore calls
`queue.read` from inside `queue.read` and traps on the two hottest agent reads.

So: **call the helper once per function, before entering any closure, and let
the closure capture the resulting `String`.**

- `searchInsightsFTS`: first lines of the function, above the
  `CJKText.containsCJK` branch at `:1961` —
  `let filter = supersededFilterSQL(alias: "")` and
  `let aliasedFilter = supersededFilterSQL(alias: "i.")` (or one `Bool` probe and
  two strings built from it, which pays a single PRAGMA). The nested `runQuery`
  closure must close over `aliasedFilter`, never call the helper.
- `listInsightsByWing`: `let filter = supersededFilterSQL(alias: "")` immediately
  before `try queue.read` at `:1999`.

In-file precedent for exactly this shape: `listContextSessions` (`:2097`)
computes `defaultSessionVisibilityConditions(alias: "s")` at `:2099` — which
calls the sibling probe `sessionsHaveHumanDrivenColumns()` at `:644`, itself a
`queue.read` — one line *before* `return try queue.read { db in`.

No `queue.read`-wrapping helper may be invoked from inside a `queue.read` body.

#### Exact post-edit SQL

| Site | Statement after the change |
| --- | --- |
| CJK branch `:1967` | `SELECT * FROM insights WHERE content LIKE :pattern ESCAPE '\'\(filter) ORDER BY created_at DESC LIMIT :limit` |
| FTS branch `:1977-1984` | `… JOIN insights i ON i.id = f.insight_id WHERE insights_fts MATCH :query\(aliasedFilter) ORDER BY f.rank LIMIT :limit` |
| `listInsightsByWing`, wing branch `:2003` | `SELECT * FROM insights WHERE wing = :wing\(filter) ORDER BY created_at DESC LIMIT :limit` |
| `listInsightsByWing`, recency branch `:2009` | `SELECT * FROM insights WHERE 1=1\(filter) ORDER BY created_at DESC LIMIT :limit` |

The recency statement has **no `WHERE` clause** today (`:2007-2011`), so appending
an ` AND …` fragment to it would emit
`SELECT * FROM insights AND superseded_by IS NULL ORDER BY …` — a syntax error
that `resources/list` would swallow into an empty resource array
(`MCPToolRegistry.swift:1360`, `(try? …) ?? []`) and that `get_memory:564` would
throw. It gets the `WHERE 1=1` carrier instead. With the probe false, `filter` is
`""` and the statement is `SELECT * FROM insights WHERE 1=1 ORDER BY …`, which is
semantically and plan-wise identical to today's.

#### Candidate-set effects (intended, and not only exclusion)

Pushing the predicate into SQL changes *which rows are fetched*, not just which
are shown. Two lifecycle-path consequences follow, and neither is a leak:

- `rankedActiveInsights` (`:675-682`) fetches 40 candidates then drops superseded
  rows in Swift at `:678` and takes `prefix(10)`. On a corpus with more than 40
  matching or recent rows, the 40 now arrive already-active, so `get_memory` can
  return **more** active memories than before — up to 10 where it previously
  returned fewer, or none. Recall increases; it cannot decrease.
- `semanticMemory` (`:848-856`) feeds `keywordIds` into
  `RankFusion.rrf` (`macos/Shared/EngramCore/AI/RankFusion.swift:18`), which
  scores by list *position*. Removing superseded ids from the keyword leg
  promotes every id after them by one rank, so fused scores and the `firstSeen`
  tie-break (`RankFusion.swift:24`) change: the **ordering of active memories** in
  semantic/hybrid `get_memory` can differ after this change, and the fused set can
  contain active ids the leg previously spent slots missing.

Both are behavior changes on a production read path. The first is pinned by a
test (Test plan, slice 2). The second is deliberately not pinned — see
"Intentionally not tested".

Why SQL-with-probe rather than a Swift-side `rows.filter { … }`:

1. **Completeness, not compromise.** The gate is safe because a partial-column
   state is unreachable through the shipped writers, not because the probe reads
   `superseded_by` alone — it is a conjunction over `superseded_by` **and**
   `insight_type` **and** `access_count` (`:667-669`). Both writer paths add all
   four lifecycle columns inside a single transaction:
   `EngramMigrations.migrateInsightsLifecycle` (`:1137-1153`) runs under
   `try pool.write { db in try EngramMigrationRunner.migrate(db) }`
   (`macos/EngramCoreWrite/Database/EngramDatabaseWriter.swift:50-52`), and
   `EngramServiceCommandHandler.ensureInsightTables` (`:1410-1443`, ALTERs at
   `:1431-1440`) runs inside `writer.write` at every call site (`saveInsight`
   `:1837`, `deleteInsight` `:1917`). A crash mid-migration rolls back
   atomically. The aux-schema version gate is also not a hazard:
   `migrateInsightsLifecycle` is called at `EngramMigrations.swift:593`, inside
   the block gated at `:580` on `auxSchemaVersion` — currently `"4"` (`:5`) —
   and the stamp is written only after it at `:596-600`, so a DB stamped at the
   pre-lifecycle version still runs it. Therefore probe-false ⇒ no lifecycle
   columns ⇒ no row can carry a supersede pointer, and the un-migrated case is
   vacuously clean.
2. **No under-fill.** The helpers apply `LIMIT` in SQL. Filtering afterwards in
   Swift would let a `limit: 5` call return 2 memories when 3 of the top FTS hits
   are superseded. `get_memory` sidesteps that by over-fetching 40 and trimming
   to 10 (`:674-682`); `get_context` and `search` have no such headroom, and
   adding over-fetch to them is more code than the predicate.
3. **Negligible cost.** The predicate is an O(1) residual test on rows the query
   already materializes — in the FTS branch the driving table is `insights_fts`
   and `i.superseded_by IS NULL` is evaluated after the rowid lookup into
   `insights`; the CJK branch is already a full scan on `content LIKE '%…%'`.
   `idx_insights_superseded` (`EngramMigrations.swift:1152`) exists but is not
   what makes this cheap and is not cited as a reason.
4. **No reliance on unverified GRDB behavior.** A Swift-side filter would depend
   on `Row["superseded_by"]` returning `nil` rather than trapping for an absent
   column. That behavior is asserted by an in-repo comment (`:610-613`) but the
   un-migrated path is never exercised: `filterInsights` returns early when
   `type == nil` (`:612`), and every type-filtered test ALTERs the table first
   (`EngramMCPExecutableTests.swift:1845-1852`). See open questions.

Cost of the probe: one `PRAGMA table_info(insights)` per `searchInsightsFTS` /
`listInsightsByWing` call (one, not two, if `searchInsightsFTS` probes once into a
`Bool` and builds both alias forms from it). `EngramMCP` is a short-lived stdio
process serving one tool call per invocation in the hook path, and `get_memory`
already pays the same probe on every call (`:464`). No memoization — it would be
an abstraction for a single-use path.

`rankedActiveInsights:678` keeps its Swift filter, now a no-op guard on
lifecycle DBs. Removing it is not required by the goals and would enlarge the
diff.

No schema change. No IPC change. No UI change. No backfill — supersession is
evaluated at read time, and there is no historical state to repair (0 superseded
rows today; a future backfill would have nothing to do).

### Implementation slices

Ordered, each independently landable.

**Slice 1 — filter the tool read path.**
Add `supersededFilterSQL(alias:)`, hoist the two locals to the top of
`searchInsightsFTS`, and apply them to both branches
(`MCPDatabase.swift:1959-1996`). Add the three repro tests named in the Test
plan (FTS `get_context`, FTS `search`, CJK `get_context`).
*Done when*: `testGetContextExcludesSupersededInsights_repro`,
`testSearchExcludesSupersededInsights_repro`, and
`testGetContextExcludesSupersededInsightsForCJKQuery_repro` fail on `main` and
pass with the change; `testGetContextMatchesGolden`,
`testGetContextWithMemoryMatchesGolden`, `testSearchMatchesGolden`,
`testGetMemoryMatchesGolden`, `testStructuredContentMatchesDeclaredOutputSchema`,
and both `get_memory` lifecycle tests still pass unmodified; no fixture or
golden file is touched.

**Slice 2 — filter the recency/catalog helper.**
Apply the hoisted helper to both statements in `listInsightsByWing`
(`MCPDatabase.swift:1998-2013`), giving the recency statement the `WHERE 1=1`
carrier. What this actually changes:
- `resources/list` via `recentResourceCatalog:2072` → `MCPToolRegistry.swift:1360`
  stops publishing superseded `engram://insight/<id>` resources.
- `get_memory`'s **lifecycle** recency path — `rankedActiveInsights(fromRecent:
  true)` at `:676` — now over-fetches 40 already-active rows instead of 40 rows
  it then thins in Swift, so it can fill 10 memories where it previously returned
  fewer or none.
- It does **not** change `get_memory`'s legacy recency fallback at `:564`: that
  line is only reachable inside the `!lifecycleAware` branch (`:533`, probe at
  `:464`), where the fragment is empty by construction. Do not go looking for a
  behavior change there.
*Done when*: `testResourceCatalogExcludesSupersededInsights_repro` and
`testGetMemoryRecencyFillsActiveMemoriesPastOverfetchWindow_repro` fail before
and pass after; `resources/list` on an un-migrated fixture returns the same
entries as before (`testResourcesListExposesSessions`,
`testResourceReadInsightReturnsContent` unmodified).

**Slice 3 — ledger and docs.**
Add invariant 14 (below) to `docs/invariants.md` with `Gate` = `none`, citing the
repro tests from slices 1-2. Add `"14": ["ledger-paths"]` to the `invariants` map
in `scripts/invariant-gates.json` (currently keys `"1"`–`"13"`, every one
carrying at least `["ledger-paths"]`, including entries 11 and 13 whose ledger
`Gate` is `none`). This is convention, not an enforced gate:
`scripts/check-invariants-ledger.sh` iterates the registry, never the ledger
headings, so an unregistered 14 would pass silently and leave the new entry the
only one without a path-existence gate. Update `docs/mcp-tools.md:124` (search
Notes) and `:143` (get_context Notes) to state that only non-superseded insights
are returned. Leave `:29` (the `insightResults[]` field description) unchanged —
the shape does not change.
*Done when*: `scripts/check-invariants-ledger.sh` passes, invariant 14 is
present in both `docs/invariants.md` and `scripts/invariant-gates.json`, and
`tests/docs/mcp-tools.test.ts` still passes.

**Cross-spec coordination for slice 3 (integration pass, 2026-07-24).**
Three of the four mirror specs write to `docs/invariants.md` and would collide
if landed in parallel:

- This spec **appends a new entry 14** and touches no existing entry, so it is
  the only ledger edit with no merge surface. That is why it is sequenced first.
- `docs/source-health-predicate-design-2026-07.md` (row 2) amends entry **3**'s
  `Verified by` list at `docs/invariants.md:23`.
- `docs/codex-native-parentage-design-2026-07.md` (row 22) amends entries **2,
  3, 9, 10** — including the same `:23` line.

Land this spec's entry 14 before either of those, or rebase; there is no
semantic conflict, only a line-level one.

`docs/mcp-tools.md` is edited **only** by this spec. Row 2's acceptance
criterion 8 forbids `docs/mcp-tools.md` in *its own* diff (verified: the file
contains zero occurrences of `health` and zero of `searchable`), which is a
scoping statement about row 2, not a prohibition on this slice.

### Acceptance criteria

1. On a database whose `insights` table has the lifecycle columns and contains a
   row with non-NULL `superseded_by` whose content matches the query, that row's
   content appears in **none** of: `get_context` text output, `search`
   `structuredContent.insightResults`, `get_memory`
   `structuredContent.memories`, `resources/list` entry names.
2. Against `tests/fixtures/mcp-contract.sqlite` (no lifecycle columns), the
   byte-exact output of `get_context`, `search`, `get_memory`, and
   `resources/list` is identical before and after the change. No golden fixture
   under `tests/fixtures/mcp-golden/` is edited.
3. `MCPOutputSchemas.swift` is not modified.
4. No file under `src/` or `tests/` (TypeScript) is modified.
5. `EngramMCP` performs no SQLite write and opens no service socket that it did
   not already open.
6. A CJK query (`searchInsightsFTS` LIKE branch) excludes superseded rows, not
   only the FTS branch — pinned by
   `testGetContextExcludesSupersededInsightsForCJKQuery_repro`.
7. On a lifecycle DB where the 40 most recent insights are all superseded and
   older active rows exist, `get_memory` with a non-matching query returns those
   active rows instead of an empty result. Recall on the lifecycle paths may
   increase; it must never decrease.
8. `supersededFilterSQL` is never called from inside a `queue.read` closure. A
   `get_context` / `search` / `resources/list` smoke call against a **lifecycle**
   DB completes without a `Database methods are not reentrant` precondition
   failure — which the three slice-1 tests and the slice-2 tests already exercise,
   since all of them seed the lifecycle columns.

## Invariants affected

This design touches **no existing entry** in `docs/invariants.md`. Entry 1
(Single-Writer Discipline) and entry 12 (EngramMCP Is Read-Only Except Service
IPC Writes) would be in play only if `access_count` writes were added to `search`
or `get_context`; that is an explicit non-goal, so both are untouched. Entry 3
(Tier Visibility) covers sessions, not insights.

Slice 3 **adds** invariant 14:

- **Statement** — An insight whose `superseded_by` names an existing insight is
  never returned by an agent-facing `EngramMCP` read: `get_context`, `search`,
  `get_memory`, or `resources/list`. The predicate is applied when
  `insightsHasLifecycleColumns()` is true (all three of `superseded_by`,
  `insight_type`, `access_count` present) and omitted otherwise, which is safe
  because both writer paths add all four lifecycle columns inside a single
  transaction, so a partial-column state is unreachable. Rows whose
  `superseded_by` points at a deleted id are out of the partition and outside this
  invariant (see Risks).
- **Enforced by** — `macos/EngramMCP/Core/MCPDatabase.swift`,
  `macos/EngramCoreWrite/Database/EngramMigrations.swift`.
- **Verified by** — `macos/EngramMCPTests/AuditMediumMCPReproTests.swift`
  (testGetContextExcludesSupersededInsights_repro,
  testSearchExcludesSupersededInsights_repro,
  testGetContextExcludesSupersededInsightsForCJKQuery_repro,
  testResourceCatalogExcludesSupersededInsights_repro,
  testGetMemoryRecencyFillsActiveMemoriesPastOverfetchWindow_repro).
- **Gate** — `none` (registered in `scripts/invariant-gates.json` as
  `"14": ["ledger-paths"]`).

## Alternatives considered

**Unconditional `AND superseded_by IS NULL` (the mirror's literal proposal).**
Rejected: throws `no such column` against `tests/fixtures/mcp-contract.sqlite`
and any un-migrated user DB, taking down `get_context` outright (bare `try` at
`:1514`) and degrading `search` to a generic error. The FTS retry re-runs the
same broken SQL. This is a hard outage on the exact tool the change protects.

**Swift-side `rows.filter` inside `searchInsightsFTS`.** Rejected: filters after
`LIMIT`, so a `limit: 5` caller can silently drop to 2 memories; and it depends
on unverified GRDB missing-column subscript behavior. The probe-gated SQL costs
one PRAGMA and avoids both.

**Emit `id` / `importance` / `type` on `search.insightResults`.** Cut.
`get_memory` already returns exactly those fields in structured `memories[]`
(`MCPOutputSchemas.swift:19`) and is the designated memory-retrieval tool; a
parallel structured payload on `search` adds no capability, breaks a published
`string[]` contract, forces a same-commit edit of the
`additionalProperties:false` schema literal, and roughly triples the insight byte
cost in both `structuredContent` and its text mirror — which can push a response
past the 4096-char mirror threshold (`MCPToolRegistry.swift:1826-1838`) and
change output for unrelated queries. If "cite an insight from search" later
becomes a real requirement, the already-shipped `engram://insight/<id>` resource
URI is a zero-schema-change way to express it.

**Surface ids in `get_context`'s `[memory]` lines.** Cut. `get_context` is
text-only and test-locked as such (`EngramMCPExecutableTests.swift:376`), so ids
could only ride inside the line, and any line-format change forces a hand-edit of
the byte-compared `get_context.engram.with_memory.json` golden. No demonstrated
consumer.

**Adopt `get_memory`'s lifecycle ranking in `get_context` / `search`.** Cut.
It would mean over-fetching 40 candidates instead of 5, pulling in
`contextNow()` / `ENGRAM_MCP_NOW` semantics, and reordering the `with_memory`
golden — for an unmeasured quality delta. `get_context` also has a hard character
budget (`:1518`) that lifecycle scoring does not model. Minimum diff wins; the
filter is what correctness requires, ranking is a preference.

**Increment `access_count` on search-/context-surfaced insights.** Cut. The write
site is `recordInsightAccess`
(`macos/EngramService/Core/EngramServiceCommandHandler.swift:1334-1356`), invoked
only from the `get_memory` branch and only over service IPC
(`MCPToolRegistry.swift:964-971`, `:1292-1319`). `access_count` feeds the
lifecycle `accessBoost` (`MCPDatabase.swift:696-697`), and a dedicated test proves
it causally reorders `get_memory`
(`EngramMCPExecutableTests.swift:2403-2411`). Inflating it from broad keyword
search would degrade ranking with rows nobody read, and would add a service
round-trip to the hottest read path — one that `get_context` cannot even use,
since its response is a bare string with no ids to extract.

**Narrow the gate to a single-column probe (`names.contains("superseded_by")`).**
Raised in review as a way to make justification 1 literally true. Not adopted:
adding a second, subtly different schema probe next to
`insightsHasLifecycleColumns()` (`:663-671`) is an abstraction for one call site
and invites the two probes to drift. The unreachability of the partial-column
state is now argued in writing from the writer code instead
(`EngramDatabaseWriter.swift:50-52`, `EngramServiceCommandHandler.swift:1410`,
`EngramMigrations.swift:580/593`), which is the same guarantee at zero code cost.

**Delete the superseded row's `insights_fts` entry at supersede time.** Rejected.
It would fix the leak at the source, but it is a writer-side change with a much
larger blast radius: it breaks `get_memory`'s keyword path over historical rows
and forecloses any future "show supersede history" feature. Read-time filtering
is reversible; deleting index rows is not.

## Test plan

All new tests go in the existing
`macos/EngramMCPTests/AuditMediumMCPReproTests.swift` — no new file, therefore no
`xcodegen generate` step. Reuse its private helpers: `temporaryFixtureCopy(_:prefix:)`
(`:22`), `rpc(_:dbPath:…)` returning `structuredContent` (`:38`), and
`rpcResult(_:dbPath:…)` returning the full result for text-only tools (`:53`).

Seed pattern: copy the block at
`macos/EngramMCPTests/EngramMCPExecutableTests.swift:2343-2376` verbatim — four
`ALTER TABLE insights ADD COLUMN …` statements wrapped in `try?`, then
`DELETE FROM insights` / `DELETE FROM insights_fts`, then paired inserts into
`insights` and `insights_fts`. Do **not** add lifecycle columns to
`tests/fixtures/mcp-contract.sqlite` itself: CI regenerates and diffs it
(`scripts/ci/check-mcp-contract-fixtures.sh`, generator
`scripts/gen-mcp-contract-fixtures.ts:82-87`).

Seed four rows. Two ASCII rows that both match the FTS probe query:
`"supersede probe active fact"` (id `sup-active`, `superseded_by` NULL) and
`"supersede probe obsolete fact"` (id `sup-old`, `superseded_by = 'sup-active'`).
Two CJK rows for the LIKE branch: `"有效事实 supersede probe"` (id `sup-cjk-active`,
`superseded_by` NULL) and `"废弃事实 supersede probe"` (id `sup-cjk-old`,
`superseded_by = 'sup-cjk-active'`). The CJK branch reads `insights` only
(`MCPDatabase.swift:1967`), so its rows need no `insights_fts` insert — insert
them anyway to keep one seed helper for all tests.

Branch selection is `CJKText.containsCJK(query)` at `MCPDatabase.swift:1961`
(`macos/Shared/EngramCore/CJKTextHelpers.swift:12-20`, CJK/Hangul scalar ranges
only), so an ASCII query routes to FTS and a query containing `有效` routes to
LIKE. That is why the FTS tests alone cannot cover `:1967`.

**Slice 1**

- `func testGetContextExcludesSupersededInsights_repro()` — call `get_context`
  with the literal
  `{"cwd":"/tmp/engram-supersede-probe","task":"supersede probe","include_environment":false}`
  via `rpcResult`, read `result.content[0].text`. Assert the text contains
  `"supersede probe active fact"`, does **not** contain
  `"supersede probe obsolete fact"`, and contains `"+ 1 memories"`. The fixture's
  sessions are intentionally left in place: `basename(cwd)` resolves to no
  indexed project so `listContextSessions` returns `[]`, and memory lines are
  appended before session lines (`:1513-1523` vs `:1525-1533`), so neither the
  session count nor the 16,000-char budget can perturb the footer at `:1536-1537`.
  Fails on `main` (2 memories, both lines present).
- `func testSearchExcludesSupersededInsights_repro()` — call `search` with
  `{"query":"supersede probe","limit":5}` via `rpc`, read
  `structuredContent.insightResults`. Assert exactly one element and that no
  element contains `"obsolete"`. Fails on `main` (2 elements).
- `func testGetContextExcludesSupersededInsightsForCJKQuery_repro()` — same shape
  as the first test but with `"task":"有效事实"`, which forces the LIKE branch.
  Assert the text contains `"有效事实 supersede probe"`, does **not** contain
  `"废弃事实"`, and contains `"+ 1 memories"`. Fails on `main` (2 memories). This
  is the only coverage of `:1967` and of acceptance criterion 6.

**Slice 2**

- `func testResourceCatalogExcludesSupersededInsights_repro()` — issue the full
  envelope `{"jsonrpc":"2.0","id":1,"method":"resources/list"}` (the stdio server
  drops any request without an `id` before dispatch,
  `macos/EngramMCP/Core/MCPStdioServer.swift:52-54`, so a bare `{"method":…}`
  produces no stdout line and the helper fails on the empty-stdout unwrap).
  Use `rpcResult(_:dbPath:)` and read `result["resources"] as? [[String: Any]]`:
  `resources/list` returns `{"resources": [...]}` with no `structuredContent`
  (`MCPToolRegistry.swift:1358-1369`), so `rpc(_:dbPath:)` would fail its
  `XCTUnwrap` at `AuditMediumMCPReproTests.swift:50`. Working envelope precedent:
  `EngramMCPExecutableTests.swift:512`. Assert no entry has `uri`
  `"engram://insight/sup-old"` and that `"engram://insight/sup-active"` is
  present. Fails on `main`.
- `func testGetMemoryRecencyFillsActiveMemoriesPastOverfetchWindow_repro()` —
  pins the recall change at `:676`. On a separate lifecycle fixture copy, seed 45
  insights: the 40 most recent all with `superseded_by = 'recency-active-40'`,
  the 5 oldest active. Call `get_memory` with a query matching nothing in FTS
  (e.g. `"zzzznomatch"`) so `rankedActiveInsights(fromRecent: false)` returns
  empty and the recency path at `:676` runs. Assert
  `structuredContent.memories` has 5 elements. Fails on `main`, where the 40-row
  over-fetch is entirely superseded, `:678` empties it, and `get_memory` returns
  `emptyMemoryResult`.

**Regression guards already in place** (must pass unmodified, no fixture edits).
Two groups, and the distinction matters:

*Un-migrated-fixture guards* — these read `tests/fixtures/mcp-contract.sqlite`
as-is (no lifecycle columns) and are the proof that the probe gate degrades
correctly: `testGetContextMatchesGolden` (`EngramMCPExecutableTests.swift:2751`),
`testGetContextWithMemoryMatchesGolden` (`:2761`), `testSearchMatchesGolden`
(`:2060`), `testGetMemoryMatchesGolden` (`:1820`, the byte-compare that backs
acceptance criterion 2 for `get_memory`),
`testStructuredContentMatchesDeclaredOutputSchema` (`:411`),
`testResourcesListExposesSessions` (`:509`), and
`testResourceReadInsightReturnsContent` (`:522`).

*Lifecycle-present guards* — these copy the fixture and then `ALTER` all four
lifecycle columns onto the copy before seeding (`:2343-2350`), so they exercise
the probe-**true** path and prove the filtered `get_memory` ranking is unchanged:
`testGetMemoryRanksByImportanceAndRecencyWhenLifecyclePresent` (`:2337`) and
`testGetMemoryRanksByServiceRecordedAccessCount_diskAuditConsumer` (`:2411`).

**Intentionally not tested**:

- The semantic/hybrid `get_memory` re-ordering described under "Candidate-set
  effects". The fused order of *active* memories is not a pinned contract
  anywhere in the repo, the change can only remove superseded ids from one RRF
  input list, and acceptance criterion 1 already asserts that no superseded row
  survives. Pinning an exact RRF order would require standing up the
  mock-provider harness (`EngramMCPExecutableTests.swift:2210`) to assert an
  ordering nobody has specified, which locks in an implementation detail instead
  of a requirement. Accepted risk, recorded here rather than silently skipped.
- The app `MemoryView` / service `insights()` path (out of scope, unchanged);
  `insightContent(id:)` (out of scope); TypeScript (unchanged and structurally
  incapable of the bug).

## Rollout

No version bump, no migration, no backfill, no service restart requirement
beyond the normal `EngramMCP` rebuild. The change takes effect the next time an
MCP client spawns the rebuilt `EngramMCP` binary. Users on an un-migrated DB see
byte-identical behavior.

Revert story: the change is one small helper, two hoisted locals, and four SQL
statements (one of which gains a `WHERE 1=1` carrier). Reverting
restores the prior unfiltered reads; no persisted state is written or altered, so
a revert leaves nothing to clean up. Slice 3's ledger entry must be reverted with
it.

## Risks and open questions

**Risk — partial fix claimed as complete (medium).** Landing slice 1 without
slice 2 leaves `resources/list` publishing superseded insights one `@`-mention
away, while the ledger and docs would claim agents no longer receive superseded
memory. Mitigation: slice 3 (ledger + docs) must not land before slice 2.

**Risk — dangling `superseded_by` pointers (medium, pre-existing, and this
change makes it worse).** `delete_insight` hard-deletes with no cleanup of rows
pointing at the deleted id
(`macos/EngramService/Core/EngramServiceCommandHandler.swift:1913-1930`, the two
`DELETE`s at `:1924-1926`), and there is no FK and no trigger on `insights`
(verified: `PRAGMA foreign_key_list(insights)` and the trigger query are both
empty). Today, an insight A superseded by B stays reachable through
`get_context`, `search`, and `resources/list` after B is deleted; only
`get_memory` hides it (`MCPDatabase.swift:678`). After slices 1-2, A is reachable
from **no** agent-facing MCP surface, permanently, with no operator signal.

Not fixed here, deliberately: the fix is writer-side and outside this doc's
scope. The concrete one-liner for whoever takes it — inside `deleteInsight`'s
existing `writer.write` block at `:1917`, alongside the two deletes:
`UPDATE insights SET superseded_by = NULL WHERE superseded_by = ?`. It is
idempotent, needs one `_repro` test, and fixes all four read surfaces at once.
Mitigations applied here instead: invariant 14 is scoped to pointers that name an
*existing* insight, so it does not assert a partition the corpus cannot honor;
and filing that backlog row is a precondition for landing slice 3, since slice 3
is what publishes the "agents never receive superseded memory" claim. The
alternative of widening the read predicate to
`AND (superseded_by IS NULL OR superseded_by NOT IN (SELECT id FROM insights))`
was rejected: it makes every keyword read carry a correlated subquery to
compensate for a writer bug, and it would have to be mirrored in the Swift filter
at `:678` to keep `get_memory` in agreement — more code in the hot path than the
one-line writer fix.

**Risk — wasted embedding spend (low, pre-existing).**
`InsightEmbeddingBackfill.pendingInsights`
(`macos/EngramCoreWrite/Indexing/InsightEmbeddingBackfill.swift:114-136`) has no
lifecycle predicate, so superseded rows still consume provider calls before
`semanticMemory:856` discards them. Unaffected by this change; noted so it is not
mistaken for a regression.

**Open question — GRDB missing-column subscript.** Whether
`Row["superseded_by"]` returns `nil` rather than trapping when the column is
absent from the result set is **unverified**. The in-repo comment at
`MCPDatabase.swift:610-613` asserts it for `insight_type`, but no test exercises
it: `filterInsights` returns early when `type == nil`, and every type-filtered
test ALTERs the table first. This design avoids depending on the behavior. If an
implementer prefers the Swift-side filter for any reason, this must be confirmed
against the pinned GRDB version first.

**Open question — `access_count` intended semantics.** It is written only from
`get_memory` and read as a ranking boost, which implies "deliberately retrieved
as memory". No doc or comment states this. Left unchanged and unresolved.

**Open question — external consumers of `search.insightResults`.** No Swift test
asserts its contents; `tests/tools/search.test.ts:209-211` asserts the TypeScript
reference shape only. Whether any third-party MCP client parses it is unverified.
This design does not change the shape, so the question is deferred rather than
answered.

**Review findings not adopted** (recorded so an implementer does not re-open them):

- *"The `testGetMemoryRanksByImportanceAndRecencyWhenLifecyclePresent` anchor
  should be `:2336`, not `:2337`."* Refuted: `grep -n "func
  testGetMemoryRanksByImportanceAndRecencyWhenLifecyclePresent"` on
  `macos/EngramMCPTests/EngramMCPExecutableTests.swift` returns `2337`. The `func`
  line is `:2337`; `:2343` is the `DatabaseQueue(path:).write` that wraps the
  `ALTER` block at `:2345-2350`. Anchors kept.
- *"Add a fourth slice clearing `superseded_by` pointers in `deleteInsight`."*
  Not adopted here — it is a writer-side change and this doc is scoped to the
  read path. Documented with its exact fix under Risks so it can be filed and
  landed on its own.
- *"Pin the semantic/hybrid RRF ordering with a test."* Not adopted; reasoned
  under "Intentionally not tested".
- *"Seed ≥11 recent rows to expose the `:676` recall change."* That seed cannot
  expose it: `rankedActiveInsights` over-fetches 40 (`:675-677`), so with 11 rows
  the pre- and post-change candidate sets contain the same active rows. The
  slice-2 test seeds 45 for this reason.

**Open question — should the app Memory page hide, mark, or show superseded
insights?** No product statement exists, and `EngramServiceInsightInfo` cannot
express the distinction today. Declared a non-goal here; needs a product
decision before anyone touches the service read path.
