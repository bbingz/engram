# Design Doc: Prune orphan `file_index_state` rows

- **Status**: Draft
- **Owner**: unassigned
- **Date**: 2026-07-25
- **Related**: PR #263 (`docs/rowc-predicate-measurement`) measured the corpus and
  found this defect while validating row 12's predicate. This doc is **row 12's
  prerequisite**: `docs/service-resilience-design-2026-07.md` Part C must not be
  implemented until this lands, because every row its chip would count is an
  orphan. Backlog row **12** (F6) in `docs/competitive-mirror-2026-07.md`.

Code citations are at `138a3740` on `main`, verified by opening each file.
Corpus figures are read read-only from `~/.engram/index.sqlite` on 2026-07-25 and
are evidence from one machine, not invariants.

## Problem

`file_index_state` accumulates rows forever. Product code creates the table
(`EngramCoreWrite/Database/EngramMigrations.swift:163`), inserts and upserts
(`EngramCoreWrite/Indexing/EngramDatabaseIndexer.swift:330`), and reads it from
three (`EngramDatabaseIndexer.swift:195`,
`EngramService/Core/ArchiveV2ServiceCoordinator.swift:1876`,
`EngramService/Core/ClaudeCodeProfileService.swift:201`).
**There is no `DELETE` in the product tree** — the only one is
`EngramCoreTests/IndexerParityTests.swift:658`. A row written for a locator that
is later deleted from disk, or written by a discovery path that no longer exists,
stays and is counted forever.

Measured on the local corpus, every one of the 528 rows with a format-breakage
`failure_kind` is such a row:

| subset | rows | evidence |
|---|---|---|
| `…/subagents/workflows/*/journal.jsonl` | **514** | files exist and parse as valid JSON; no current adapter enumerates this shape |
| file no longer exists on disk | **10** | 4 of them recorded `size_bytes = 0` |
| file exists, every line valid JSON | 4 | 7–8 control-only records, 2.4–2.6 KB |
| a file that currently fails to parse | **0** | — |

Their `updated_at` is frozen at 2026-06-21 (the 10 missing), 2026-07-02 (3),
and 2026-07-02..07-04 (the 514), while the table's newest `updated_at` is the
current day. Nothing is retrying them, and nothing can: `ClaudeCodeAdapter`'s
`listSessionLocators` descends exactly one level into `subagents/` and takes
`.jsonl` direct children (`ClaudeCodeAdapter.swift:112-119`, unchanged since
`6a472734`, 2026-04-24), so it cannot produce a
`subagents/workflows/<wf>/journal.jsonl` locator at all. **1,166** such files
exist under `~/.claude` alone against **262** recorded `claude-code` rows — a
live enumeration would hold all of them.

Who is affected today: nobody visibly, because nothing reads
`failure_kind`. That is exactly why this must land first. Row 12 exists to put a
per-source parse-failure chip on `SourcePulseView`; on this corpus that chip
would render a permanent `262` on `claude-code` describing damage that does not
exist. Shipping it would add a false claim to a backlog whose subject is
removing false claims.

## Goals / Non-goals

**Goal.** After a scan enumerates a source's complete locator set, rows in
`file_index_state` for that source whose locator is not in the set are deleted,
so the table describes only files the product currently tracks.

**Non-goals.** A new table, column, or migration — this is a `DELETE`, not a
schema change. Pruning any other table (`sessions` retention is a separate
concern and is not touched). Reference-counting or tombstoning deleted rows;
re-parsing a file that is pruned by mistake is a recoverable CPU cost, not data
loss. Changing what `failure_kind` means or how it is written. Implementing row
12 itself.

## Current state

`SwiftIndexer.scanSnapshots` (`EngramCoreWrite/Indexing/SwiftIndexer.swift:148`)
already has everything needed, per source, per cycle:

```swift
for adapter in adapters {
    guard await adapter.detect() else { continue }
    let locators: [String]
    do {
        locators = try await adapter.listSessionLocators()          // :160
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        Self.log.error("adapter listSessionLocators failed: …")     // :166
        continue                                                    // :169
    }
    let fileIndexStates = try? sink.knownFileIndexStates(
        source: adapter.source, locators: locators)                 // :175
    …
}
```

Two properties matter:

1. **A failed enumeration already `continue`s** (`:169`) before any state is
   consulted, so a prune placed after `:170` never sees a partial list caused by
   an adapter throw.
2. **`knownFileIndexStates` is already restricted to the enumerated locators**
   (`EngramDatabaseIndexer.swift:195-197`, `WHERE source = ? AND locator IN (…)`).
   That is precisely why orphans are invisible to the rest of the pipeline — the
   read path can never observe a row it did not ask for.

### The one thing that makes this dangerous

`listSessionLocators()` is **not always a complete enumeration.** The scheduled
scan path wraps every file-backed adapter in a recency filter
(`SessionAdapterFactory.swift:101-111`):

```swift
let recentFileBacked: [any SessionAdapter] = fileBackedAdapters.map { adapter in
    if let exact = adapter as? any ExactArchiveSourceAdapter {
        return RecentlyModifiedExactArchiveSourceAdapter(base: exact, modifiedSince: cutoff, …)
    }
    return RecentlyModifiedSessionAdapter(base: adapter, modifiedSince: cutoff)
}
```

and `RecentlyModifiedSessionAdapter.listSessionLocators()` returns only files
modified since `cutoff` (`:189-203`).

**A prune that ran on that list would delete the `file_index_state` row of every
file older than the cutoff on every incremental scan**, discarding
`parsed_offset` and `boundary_hash` for ~35,000 files and forcing a full
re-parse each cycle. This is the single failure mode that must be designed out,
not merely tested for.

## Proposed design

**1. Make completeness an explicit adapter capability, not a type check.**
Add one requirement to `SessionAdapter`
(`Shared/EngramCore/Adapters/SessionAdapter.swift:317`):

```swift
/// True when `listSessionLocators()` returns this source's complete locator set.
/// Wrappers that narrow the enumeration (recency filters) return false, so
/// orphan pruning can never run against a partial list.
var enumeratesCompleteLocatorSet: Bool { get }
```

Default `true` in the existing `public extension SessionAdapter` (`:337`), so no
concrete adapter changes. Override to `false` in exactly two places:
`RecentlyModifiedSessionAdapter` and `RecentlyModifiedExactArchiveSourceAdapter`
(`SessionAdapterFactory.swift:167`, `:236`). It is a protocol requirement, not
an extension-only member, so it dispatches dynamically through
`any SessionAdapter` — the same reason `scanForIndexing` is declared in the
protocol (`SessionAdapter.swift:322-326`).

Deliberately **not** `if adapter is RecentlyModifiedSessionAdapter`: a third
narrowing wrapper added later would silently opt back into pruning, and the
failure would be a full-corpus re-parse rather than a compile error.

**2. Prune after a complete enumeration.** In `scanSnapshots`, immediately after
the `do/catch` at `:170`:

```swift
if adapter.enumeratesCompleteLocatorSet {
    try? sink.pruneOrphanFileIndexStates(source: adapter.source, keeping: locators)
}
```

`try?` matches the surrounding style (`:173`, `:175`, `:184`): pruning is
maintenance, and a failure must not abort a scan that is otherwise fine.

**3. Sink method.** `EngramDatabaseIndexer.swift` holds both halves of this pair:
a sink facade that delegates (`upsertFileIndexState` at `:73`) and the writer
implementation (`:326`). The new method follows the same shape at both:

```swift
func pruneOrphanFileIndexStates(source: SourceName, keeping locators: [String]) throws -> Int
```

- **Refuse to prune an empty keep-set.** If `locators.isEmpty`, return 0 without
  deleting. A healthy adapter that legitimately enumerates zero files and a
  source root that just became unreadable are indistinguishable here, and the
  second is the one that must not wipe a source's entire parse state.
- One write transaction: a temp table of the keep-set, then a single delete.
  `NOT IN` cannot be chunked the way `knownFileIndexStates` chunks `IN` —
  chunked `IN` unions, chunked `NOT IN` intersects — so the keep-set is
  materialised rather than split across statements.

```sql
CREATE TEMP TABLE IF NOT EXISTS _prune_keep(locator TEXT PRIMARY KEY);
DELETE FROM _prune_keep;
-- batched INSERT OR IGNORE of every keep locator
DELETE FROM file_index_state
 WHERE source = ?
   AND locator NOT IN (SELECT locator FROM _prune_keep);
```

- Return the deleted count and `log.info` it when non-zero. A prune that removes
  thousands of rows on a routine cycle is the signature of a discovery
  regression, and it must be visible in `os_log` without a debugger.

## Invariants affected

- **New:** for any source whose adapter reports a complete enumeration, every
  `file_index_state` row for that source names a locator that source currently
  enumerates. Rows for other sources, and rows under a narrowed enumeration, are
  untouched.
- **Unchanged:** `sessions` and every other table. Pruning a row does not delete
  the indexed session it came from; it deletes the incremental-parse bookkeeping.
- **Unchanged:** `knownFileIndexStates` semantics — it already only returns rows
  for enumerated locators, so the read path cannot tell a pruned row from an
  absent one.

## Alternatives considered

- **Prune only rows whose file no longer exists on disk.** Simpler and needs no
  completeness signal, but it fixes 10 of 528 rows here and leaves the 514
  workflow journals, whose files do exist. It also adds a `stat` per row.
- **Prune at startup instead of per scan.** Startup already runs a maintenance
  chain, but it would need to re-run discovery purely to build the keep-set,
  duplicating the work the scan does anyway.
- **Leave the rows and filter at the read site** (row 12 option 2: scope the chip
  to still-enumerated locators). Makes the chip honest without touching the
  table, but leaves an unbounded table growing forever and only fixes the surface
  that happened to notice.
- **A percentage guard** ("refuse to delete more than N% of a source's rows").
  Rejected as speculative: the empty-set guard covers the realistic catastrophic
  case, and a percentage threshold would need a justification the data does not
  supply.

## Test plan

Swift, in `EngramCoreTests`. The first two are the ones that carry information;
each must be shown red before the fix and green after, with the mutation
compiling and the tests actually executing.

| test | asserts |
|---|---|
| `testPartialEnumerationDoesNotPruneFileIndexState_repro` | a source behind `RecentlyModifiedSessionAdapter` keeps rows for files outside the recency window. **The most important test in this change** — it fails loudly if the completeness gate is ever removed. |
| `testOrphanFileIndexStateIsPruned_repro` | a row whose locator the adapter does not enumerate is deleted after one scan |
| `testEmptyEnumerationDoesNotPruneFileIndexState_repro` | zero enumerated locators deletes nothing |
| `testPruneLeavesOtherSourcesIntact` | pruning `claude-code` does not touch `codex` rows |
| `testPruneKeepsEnumeratedRowsAndTheirParseOffsets` | surviving rows keep `parsed_offset` / `boundary_hash` (guards against delete-and-reinsert) |

Corpus check after implementing, recorded as evidence, not asserted in a test:
the 528 rows above should go to 0 on one full scan, and a second scan should
delete 0 more.

## Rollout

One PR, Swift only, no migration. It is self-healing: the first complete scan
per source drops that source's orphans, so there is no backfill step and no
version gate. Reverting the PR stops pruning; it does not restore deleted rows,
which is acceptable because a deleted row costs a re-parse and nothing else.

Row 12 (Part C of `docs/service-resilience-design-2026-07.md`) unblocks once the
corpus check above is recorded.

## BLOCKING CORRECTION (2026-07-25, after the first implementation attempt)

**The completeness gate above is necessary but not sufficient, and the design as
written would delete thousands of live rows on every scan.** The first
implementation (`c3991bdb` on `feat/file-index-state-orphan-prune`, local only,
**must not be pushed as-is**) follows this doc faithfully and inherits the defect.

The gate asks "is this adapter's list complete?" The question that actually
matters is "is this adapter's list complete **for this `source`**". It is not,
because `file_index_state.source` is written as `adapter.source` at every write
site (`SwiftIndexer.swift:230`, `:267`, `:279`, `:311`, `:326`, `:387`) and
**several `SourceName`s have more than one writer, each covering a disjoint
root**:

| `source` | the adapter's own root | rows under a *different* root | measured deletion |
|---|---|---|---|
| `codex` | `~/.codex` 2,777 | `~/.claude-openai` **3,237** | **54% of the source** |
| `kimi` | `~/.kimi` 575 | `~/.claude-kimi` **2,090** | **78%** |
| `qwen` | `~/.qwen` 830 | `~/.claude-qwen` **654** | **44%** |

`CodexAdapter.source` is `.codex` (`CodexAdapter.swift:463`) and its
`sessionRoots` are exactly `~/.codex/sessions` plus `~/.codex/archived_sessions`
(`expandSessionRoots`, `:764-770`), filtered to `rollout-*.jsonl` (`:490`). It
never walks `~/.claude-openai`. So `CodexAdapter` would report a complete
enumeration, and the prune — keyed on `source` alone — would delete all 3,237
`~/.claude-openai` rows. The other writer recreates them; the next scan deletes
them again. **5,981 rows across three sources thrash every cycle, and their files
are re-parsed from offset 0 forever** — precisely the failure mode the recency
section of this doc exists to prevent, arrived at by a different route.

### Corrected direction

Replace the Bool with the adapter's **enumeration domain**, so scope is declared
rather than assumed:

```swift
/// Absolute path prefixes this adapter enumerates exhaustively. A prune may
/// delete a row only when its locator falls under one of these. Empty — the
/// default — means the adapter declares no domain and is never pruned.
var enumerationRoots: [String] { get }
```

- Default `[]`, so **every adapter is safe until it opts in**, one at a time,
  each with its own measurement. This inverts the current risk: the present
  design's default (`true`) makes every adapter dangerous until someone thinks to
  exclude it, which is how both the subset wrappers and this defect got through.
- The delete gains `AND (locator LIKE ? || '/%' OR …)`, one clause per declared
  root, so a second writer's rows under the same `source` can never be in scope.
- Narrowing wrappers return `[]` — the same override sites, one concept instead
  of two.
- `ClaudeCodeAdapter` is the first and only opt-in for this change: it owns the
  514 orphan journal rows, and it can declare its roots from
  `refreshProfilesForListing()` (`ClaudeCodeAdapter.swift:510-517`).

### Required additional test

`testForeignRootRowsUnderSameSourceSurvivePrune_repro` — two writers under one
`SourceName` with disjoint roots; pruning on one must leave the other's rows and
their `parsed_offset` untouched. This is now **the** load-bearing test, ahead of
the partial-enumeration one.

### What the first attempt got right

The implementation report flagged a real gap in this doc independently: the
"exactly two places" claim was wrong — `ExactLocatorSubsetSessionAdapter`
(`SessionAdapterFactory.swift:311`) and `CapturedLocatorIndexAdapter` (`:380`)
also narrow the list and were left at the dangerous default. Under the corrected
direction both simply declare `[]` like every other non-opted-in adapter, and the
enumeration of narrowing wrappers stops being something a future reader has to
get exhaustively right.

## Risks and open questions

- **A discovery regression now deletes state instead of merely missing files.**
  Before this change, an adapter that stopped enumerating a directory left its
  rows behind (which is how the 514 survived); after it, those rows are removed
  and the files are re-parsed from offset 0 when discovery is fixed. That is the
  intended trade, but it means a discovery bug becomes a CPU spike. The logged
  delete count is the detector.
- **Sources with composite or synthetic locators.** `backingFilePath`
  (`SessionAdapterFactory.swift:225-233`) shows locators may carry `::` or
  `?composer=` suffixes, so the keep-set must be compared as the raw locator
  string, exactly as written by `upsertFileIndexState`. Any normalisation
  mismatch would delete live rows every cycle — this is the second-most likely
  way to get it wrong and should be covered by including one composite-locator
  source in `testPruneKeepsEnumeratedRowsAndTheirParseOffsets`.
- **Not established:** which code wrote the 514 journal rows during
  2026-07-02..04, or the 10 rows on 2026-06-21. Neither path is in `main`. The
  July window coincides with the `codex/perf-integration-review` merges, but that
  was not traced to a commit and is not claimed here. The prune is correct
  regardless of provenance, but until it is known, a recurrence cannot be ruled
  out — which is a further argument for logging the delete count.
- **One machine.** Every corpus figure here is from a single local
  `~/.engram/index.sqlite`. The code facts (no `DELETE` in the product tree, the
  recency wrapper, the one-level `subagents` walk) are corpus-independent; the
  counts are not.
