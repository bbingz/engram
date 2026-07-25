# Design Doc: Prune orphan `file_index_state` rows

- **Status**: Implemented, not yet merged — `7dc30436` + `b4b83b65` on
  `feat/orphan-prune-v2`, local only. This doc describes the code as built.
- **Owner**: unassigned
- **Date**: 2026-07-25
- **Related**: PR #263 (`docs/rowc-predicate-measurement`) measured the corpus and
  found this defect while validating row 12's predicate. This doc is **row 12's
  prerequisite**: `docs/service-resilience-design-2026-07.md` Part C must not be
  implemented until this lands, because every row its chip would count is an
  orphan. Backlog row **12** (F6) in `docs/competitive-mirror-2026-07.md`.

Code citations are at `b4b83b65` unless a line is marked "before this change",
in which case it is at `138a3740` on `main`. Each was verified by opening the
file. Corpus figures are read read-only from `~/.engram/index.sqlite` on
2026-07-25 and are evidence from one machine, not invariants.

A first implementation (`c3991bdb`, superseded) gated the delete on a per-adapter
completeness `Bool`. Verifying it surfaced a defect in the *design*: that question
cannot express a `SourceName` with more than one writer. The measurement and the
corrected shape are in "Two ways an enumeration is not the source's full set" and
"Alternatives considered".

## Problem

`file_index_state` accumulated rows forever. Product code creates the table
(`EngramCoreWrite/Database/EngramMigrations.swift:163`), inserts and upserts
(`EngramDatabaseIndexer.swift:339`), and reads it from three
(`EngramDatabaseIndexer.swift:204`,
`EngramService/Core/ArchiveV2ServiceCoordinator.swift:1876`,
`EngramService/Core/ClaudeCodeProfileService.swift:201`).
**Before this change there was no `DELETE` in the product tree** — the only one
was `EngramCoreTests/IndexerParityTests.swift:658`. A row written for a locator
that was later deleted from disk, or written by a discovery path that no longer
exists, stayed and was counted forever.

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

**Goal.** After a scan enumerates an adapter's declared roots, rows in
`file_index_state` for that adapter's source **under those roots** whose locator
is not in the enumerated set are deleted, so the table describes only files the
product currently tracks.

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
        source: adapter.source, locators: locators)                 // :187
    …
}
```

Two properties matter:

1. **A failed enumeration already `continue`s** (`:169`) before any state is
   consulted, so a prune placed after `:170` never sees a partial list caused by
   an adapter throw.
2. **`knownFileIndexStates` is already restricted to the enumerated locators**
   (`EngramDatabaseIndexer.swift:204-206`, `WHERE source = ? AND locator IN (…)`).
   That is precisely why orphans are invisible to the rest of the pipeline — the
   read path can never observe a row it did not ask for.

### Two ways an enumeration is not the source's full set

**1. Narrowing wrappers.** The scheduled scan path wraps every file-backed
adapter in a recency filter (`SessionAdapterFactory.swift:101-111`):

```swift
let recentFileBacked: [any SessionAdapter] = fileBackedAdapters.map { adapter in
    if let exact = adapter as? any ExactArchiveSourceAdapter {
        return RecentlyModifiedExactArchiveSourceAdapter(base: exact, modifiedSince: cutoff, …)
    }
    return RecentlyModifiedSessionAdapter(base: adapter, modifiedSince: cutoff)
}
```

`RecentlyModifiedSessionAdapter.listSessionLocators()` returns only files
modified since `cutoff` (`:189-203`). A prune keyed on that list would delete the
row of every file older than the cutoff on every incremental scan, discarding
`parsed_offset` and `boundary_hash` for ~35,000 files. Two more wrappers narrow
the same way: `ExactLocatorSubsetSessionAdapter` (`:311`, the codex retry subset)
and `CapturedLocatorIndexAdapter` (`:380`, the archive-capture batch).

**2. Several `SourceName`s have more than one writer.** This is the deeper one,
and it is why the shipped design declares a *domain* rather than a completeness
flag. `file_index_state.source` is written as `adapter.source` at every write site
(`SwiftIndexer.swift:230`, `:267`, `:279`, `:311`, `:326`, `:387` before this
change), and a single `SourceName` can be fed by adapters over disjoint roots:

| `source` | the adapter's own root | rows under a *different* root | share of the source |
|---|---|---|---|
| `codex` | `~/.codex` 2,777 | `~/.claude-openai` **3,237** | **54%** |
| `kimi` | `~/.kimi` 575 | `~/.claude-kimi` **2,090** | **78%** |
| `qwen` | `~/.qwen` 830 | `~/.claude-qwen` **654** | **44%** |

`CodexAdapter.source` is `.codex` (`CodexAdapter.swift:463`) and its
`sessionRoots` are exactly `~/.codex/sessions` plus `~/.codex/archived_sessions`
(`expandSessionRoots`, `:764-770`), filtered to `rollout-*.jsonl` (`:490`). It
never walks `~/.claude-openai`. An adapter can therefore enumerate its own root
exhaustively and still be missing most of its `SourceName`'s rows. **A per-adapter
"is this list complete?" question cannot express this**; 5,981 rows across three
sources would thrash every cycle and re-parse from offset 0 forever.

## Design as implemented

### 1. Adapters declare a domain, and the default is none

`SessionAdapter` gains one requirement (`SessionAdapter.swift:332`), defaulted in
the existing `public extension` (`:350`):

```swift
/// Absolute path prefixes this adapter enumerates exhaustively. A prune may
/// delete a `file_index_state` row only when its locator falls under one of
/// these. Empty — the default — means the adapter declares no domain and is
/// never pruned.
var enumerationRoots: [String] { get }
```

Default `[]`, so **every adapter is safe until it opts in**. This is the load-
bearing choice. The rejected alternative — a `Bool` defaulting to "complete" —
makes every adapter dangerous until someone remembers to exclude it, and both
narrowing wrappers and the multi-writer case above got through exactly that way.
Under the shipped shape the narrowing wrappers need **no override at all**: `[]`
is already correct for them, so the correctness of this change does not depend on
a future reader enumerating every wrapper.

It is a protocol requirement rather than extension-only so it dispatches
dynamically through `any SessionAdapter`, the same reason `scanForIndexing` is
declared in the protocol.

### 2. `ClaudeCodeAdapter` is the only opt-in, stamped from one profile read

`ClaudeCodeAdapter.enumerationRoots` (`ClaudeCodeAdapter.swift:21`) returns roots
recorded by the last `listSessionLocators()` call, which now refreshes profiles
**once** and feeds that same array to both the keep-set and the roots:

```swift
func listSessionLocators() async throws -> [String] {
    // One profile refresh feeds both the keep-set and enumerationRoots.
    let profiles = refreshProfilesForListing()
    lastListingRoots.replace(with: Self.canonicalProjectsRoots(from: profiles))
    return try await listSessionLocators(profiles: profiles)
}
```

This is not cosmetic. `automaticCandidates()` is gated on the user setting
`claudeCodeProfiles.autoDiscover` (`ClaudeCodeProfileResolver.swift:170`). With it
on — the current local value — the resolver takes `~/.claude/projects` plus every
existing `~/.claude-*/projects`, which is **13 of 13** roots present on disk.
Turn it off and the profile set collapses to `~/.claude/projects` plus custom
roots, leaving **3,709** of the 36,418 `claude-code` rows outside the enumerated
roots (32,709 are under `~/.claude/projects`). Because roots come from the same
snapshot as the keep-set, they shrink together and the narrowed delete simply
cannot reach the other profiles' rows. A second resolver read, or a cached root
list, would reintroduce the gap.

Roots are empty until the first successful list, so a reordered call site cannot
prune against init-time profiles. Scan order (list → read roots → prune) is
load-bearing and commented as such.

A 14th root, `~/.claude-mimosg` (23 rows), appears in the corpus. That directory
does not exist on disk and its files are gone; those rows are genuine orphans and
deleting them is the intended outcome, not a coverage gap.

### 3. The prune, and why the root predicate is `instr` and not `LIKE`

`pruneOrphanFileIndexStates(source:keeping:under:)` on the sink protocol
(`IndexingWriteSink.swift:267`, default `0` at `:289`), the sink facade
(`EngramDatabaseIndexer.swift:78`), and the writer (`:384`). Called from
`SwiftIndexer.swift:172-182`, immediately after the `listSessionLocators`
`do/catch`, with `_ = try?` so a prune failure cannot abort an otherwise healthy
scan and the unused `Int` leaves no warning.

Scope is **dual** — keep-set membership *and* root prefix:

```sql
DELETE FROM file_index_state
 WHERE source = ?
   AND locator NOT IN (SELECT locator FROM _prune_keep)
   AND ((locator = ? OR instr(locator, ? || '/') = 1) OR …)
```

- `instr(locator, root || '/') = 1` is an **exact** prefix test. `LIKE root ||
  '/%'` is not: `LIKE` reads `_` and `%` in the *root* as wildcards, so a profile
  directory named `.claude-a_b` would also sweep `.claude-aXb`. Demonstrated
  directly in SQLite — the `LIKE` form returns 1 for that pair, `instr` returns 0.
  This predicate is the entire guarantee that a prune stays inside its own domain,
  so it must not have wildcard semantics. The first implementation used `LIKE`
  with a comment claiming it avoided `/foo` matching `/foobar`, which was true for
  that case and false for `_`/`%` — the same "comment asserts a guard it does not
  provide" defect this backlog exists to remove.
- **Empty keep-set or empty roots refuse to prune** and return 0. A healthy
  adapter that legitimately enumerates zero files and a source root that just
  became unreadable are indistinguishable here, and the second must not wipe a
  source's parse state.
- The keep-set is materialised into a `TEMP TABLE` in batches of 500 inside the
  one write transaction. `NOT IN` cannot be chunked the way `knownFileIndexStates`
  chunks `IN` — chunked `IN` unions, chunked `NOT IN` intersects.
- Roots are de-duplicated and trailing slashes trimmed before use.
- A non-zero delete count is logged at `info` on `com.engram.service`. A prune
  that removes thousands of rows on a routine cycle is the signature of a
  discovery regression and must be visible without a debugger.

### Where it runs

`EngramServiceRunner.swift:759`, `:930`, `:1021` build adapters with
`SessionAdapterFactory.defaultAdapters()` — unwrapped, so `ClaudeCodeAdapter`
declares its roots and the prune runs. The periodic paths use
`indexingAdapters(…)`, whose wrappers report `[]`, so incremental scans never
prune. That matches the intended lifecycle: self-healing on a full scan, inert in
between.

## Invariants affected

- **New:** for any adapter that declares `enumerationRoots`, every
  `file_index_state` row for that adapter's `source` **under one of those roots**
  names a locator the adapter currently enumerates. Rows of the same `source`
  outside those roots, rows of other sources, and rows seen only through a
  narrowing wrapper are untouched.
- **Unchanged:** `sessions` and every other table. Pruning a row deletes
  incremental-parse bookkeeping, not the indexed session.
- **Unchanged:** `knownFileIndexStates` semantics — it already returns only rows
  for enumerated locators, so the read path cannot distinguish a pruned row from
  an absent one.

## Alternatives considered

- **A `Bool` completeness flag defaulting to `true`** (the first design, and the
  first implementation `c3991bdb`). Rejected on measurement: it cannot express the
  multi-writer case, and its default makes every adapter dangerous. See the table
  above — 5,981 rows deleted per scan across `codex`/`kimi`/`qwen`.
- **Prune only rows whose file no longer exists on disk.** Needs no domain signal,
  but fixes 10 of 528 rows here and leaves the 514 workflow journals, whose files
  do exist. Also adds a `stat` per row.
- **Prune at startup instead of per scan.** Startup already runs a maintenance
  chain, but it would re-run discovery purely to build the keep-set, duplicating
  work the scan does anyway.
- **Leave the rows and filter at the read site** (row 12 option 2). Makes the chip
  honest without touching the table, but leaves the table growing without bound
  and fixes only the surface that happened to notice.
- **A percentage guard** ("refuse to delete more than N% of a source's rows").
  Speculative: the empty-set guards cover the realistic catastrophic case, and a
  threshold would need a justification the data does not supply.

## Test plan — as implemented

`macos/EngramCoreTests/FileIndexStateOrphanPruneTests.swift`, 8 tests, all green
(`xcodebuild_exit=0`, Executed 8, 0 failures, 0 Swift compile errors, 0 warnings
in touched files).

| test | asserts |
|---|---|
| `testForeignRootRowsUnderSameSourceSurvivePrune_repro` | **load-bearing.** Two writers under one `SourceName` over disjoint roots; pruning one leaves the other's rows and their `parsed_offset`. Modelled on the real `codex` case. |
| `testShrunkProfileSetDoesNotPruneOtherProfiles_repro` | roots and keep-set both derived from a reduced profile list; rows under the dropped profile survive. The `autoDiscover = false` case. |
| `testRootWithLikeWildcardDoesNotOverMatch_repro` | a declared root containing `_` does not sweep a neighbouring root. Red under the `LIKE` predicate, green under `instr`. |
| `testOrphanUnderDeclaredRootIsPruned_repro` | a row under a declared root the adapter no longer lists is deleted |
| `testEmptyEnumerationRootsNeverPrunes` | default `[]` deletes nothing even with a non-empty keep-set |
| `testEmptyKeepSetNeverPrunes` | empty keep-set deletes nothing |
| `testPruneKeepsEnumeratedRowsAndTheirParseOffsets` | survivors keep `parsed_offset` / `boundary_hash`; includes a composite locator |
| `testDefaultAdapterEnumerationRootsAreEmpty` | the protocol default is `[]` |

**Mutation evidence.** Every mutation compiled and the tests executed; a red from
a compile error would carry no information. "Reproduced" marks a mutation run
independently during review rather than taken from the implementation report.

| mutation | result |
|---|---|
| root clauses replaced with an always-true predicate of the same arity (i.e. no domain scoping) — **reproduced** | exit 65, 0 Swift compile errors, 7 executed (before the wildcard test existed), **exactly 2 test methods red**, both multi-writer `_repro`s, 6 assertions: `("2") is not equal to ("1")`, `rows under a second writer's root must not be deleted`, `("nil") is not equal to ("Optional(3237)")`, and the three shrunk-profile counterparts |
| `lastListingRoots` unions old roots instead of replacing (roots never shrink) — from the implementation report, not re-run | exit 65, 7 executed, `testShrunkProfileSetDoesNotPruneOtherProfiles_repro` red: `shrunk roots must not reach the dropped profile` |
| `instr(…) = 1` reverted to `LIKE ? \|\| '/%'` — **reproduced** | exit 65, 0 compile errors, 8 executed, **only** `testRootWithLikeWildcardDoesNotOverMatch_repro` red (2 assertions) |
| all restored | exit 0, 8 executed, 0 failures, 0 Swift warnings, `xcodeproj drift ok` |

### Full-suite regression

`enumerationRoots` is a protocol requirement, so the risk was never the prune
logic but whether every existing conformance still compiles and behaves. All
three schemes CI's `swift-unit` job runs (`.github/workflows/test.yml:201`,
`:216`, `:217`) were run locally at `88daa384`:

| scheme | test bundle | executed | skipped | failures | exit | Swift compile errors |
|---|---|---|---|---|---|---|
| `Engram -skip-testing:EngramUITests` | `EngramCoreTests` | 1,006 | 1 | 0 | 0 | 0 |
| " | `EngramTests` | 781 | 0 | 0 | 0 | 0 |
| `EngramServiceCore` | `EngramServiceCoreTests` | 585 | 1 | 0 | 0 | 0 |
| `EngramMCPTests` | `EngramMCPTests` | 176 | 0 | 0 | 0 | 0 |
| **total** | | **2,548** | **2** | **0** | | **0** |

Both skips are pre-existing environment gates, not fallout:
`IndexerPerformanceTests.testSwiftIndexerThroughputForGeneratedSessionFixtures`
(gated on `ENGRAM_PERF`) and
`RemoteSyncCoordinatorTests.testLiveOffloadRehydrateAgainstDeployedServer`
(needs a deployed server).

Not run locally: `EngramUITests` (skipped here as CI's `swift-unit` skips it —
`ui-test-smoke`/`ui-test-full` own it), the `EngramRemoteServerCore` /
`EngramRemoteServer` schemes (the separate `remote-server-swift` job), and
`scripts/release-verify.sh --hygiene-only`.

A first attempt at the domain-scoping mutation deleted the SQL clause without
dropping its bound arguments and failed with `SQLite error 21: wrong number of
statement arguments`. That red proved only that the tests reach the real SQL path,
not the scoping semantics, so it was redone with the arity preserved.

## Rollout

Swift only, no migration. Self-healing: the first full scan drops that source's
orphans under the declared roots, so there is no backfill step and no version
gate. Reverting stops pruning; it does not restore deleted rows, which is
acceptable because a deleted row costs a re-parse and nothing else.

### Corpus check — run, and it contradicts the prediction

The prediction above ("the 528 rows go to 0") was **wrong**. Measured against an
online `.backup` copy of the real `~/.engram/index.sqlite` (52,943 rows), driving
the production sequence — `SessionAdapterFactory.defaultAdapters()` → the real
`ClaudeCodeAdapter.listSessionLocators()` → `enumerationRoots` →
`pruneOrphanFileIndexStates` — the live database was never opened for writing.

| | before | after |
|---|---|---|
| `file_index_state` rows | 52,943 | 48,970 |
| `source='claude-code'` | 37,940 | 33,967 |
| `failure_kind IS NOT NULL` | 1,284 | **1,022** |
| `failure_kind='malformedJSON'` | 528 | **266** |
| workflow-journal rows, all sources | 514 | **252** |
| workflow-journal rows, `claude-code` | 262 | **0** |
| `~/.claude-mimosg` rows | 23 | **23** |

Enumeration: **37,841** locators, **1** declared root. Deleted **3,973** rows, of
which 262 were workflow journals. A second prune with identical inputs deleted
**0** — idempotent as designed.

**Why one root, not thirteen.** Every `~/.claude-*/projects` on this machine is a
**symlink to `~/.claude/projects`**. `canonicalProjectsRoots` resolves and
de-duplicates them, so the thirteen profiles collapse to one canonical root. That
is correct behaviour, not a defect — but it means the 3,709 `claude-code` rows
recorded under symlink spellings (`~/.claude-doubao/projects/…`) fall outside the
declared root by string prefix and are **kept**. 3,624 of them have a canonical
twin row, i.e. they are duplicate spellings of files already tracked under
`~/.claude/projects`. They are as stale as the journals; the prune simply cannot
see them.

**Why 252 journals survive.** They belong to `codex` (156), `glm` (43),
`deepseek` (16), `kimi` (14), `mimo` (9), `qwen` (8), `minimax` (4) and `doubao`
(2). Those adapters declare no roots, so by design they never prune. Nothing is
wrong with the prune; the opt-in is simply one adapter wide.

**Row 12 is therefore still blocked.** Its predicate would count 266 malformed /
1,022 total rows after this change, and every one of those is still residue. This
change removes half the target set. Unblocking row 12 needs at least one more
step — extending the opt-in to the other Claude-profile-backed sources, and
handling symlink-spelled locators (canonicalise on write, or match roots after
resolving symlinks rather than by string prefix). Neither is in this change's
scope, and neither should be bolted on without its own measurement.

## Risks and open questions

- **A discovery regression now deletes state instead of merely missing files.**
  Before this change an adapter that stopped enumerating a directory left its rows
  behind — which is how the 514 survived. Now they are removed and re-parsed from
  offset 0 when discovery is fixed. That is the intended trade; the logged delete
  count is the detector.
- ~~**Only one test class has been run.**~~ **Closed.** All three schemes CI's
  `swift-unit` runs were run locally and are green — see "Full-suite regression"
  below. `enumerationRoots` is a new protocol requirement, and the extension
  default absorbed every conformance including the four adapter mocks in
  `EngramServiceCoreTests` (`ArchiveV2ServiceCoordinatorTests.swift:3244`,
  `:3313`, `:3355`, `ArchiveV2RunnerIntegrationTests.swift:735`) with zero
  compile errors.
- **`ClaudeCodeDerivedSourceAdapter`** (minimax/lobsterai over Claude files)
  defaults to `[]` and never prunes. That is correct as written, but which
  `SourceName` those adapters write `file_index_state` under was not
  independently confirmed.
- **Composite locators.** `backingFilePath` (`SessionAdapterFactory.swift:225-233`)
  shows locators may carry `::` or `?composer=` suffixes. The keep-set compares
  the raw locator string exactly as `upsertFileIndexState` wrote it, and the root
  test is a prefix, so a composite locator under a declared root behaves like any
  other. Covered by `testPruneKeepsEnumeratedRowsAndTheirParseOffsets`.
- **Symlink-spelled locators are unreachable by this prune.** `~/.claude-*/projects`
  are symlinks to `~/.claude/projects` on this machine, so 3,709 `claude-code`
  rows carry a spelling no canonical root prefixes. Keeping them is the safe
  outcome, but they are stale and this change cannot remove them. A follow-up must
  either canonicalise locators on write or compare roots after resolving symlinks
  instead of by string prefix.
- **The opt-in is one adapter wide.** 252 of the 514 workflow-journal rows belong
  to seven other sources whose adapters declare no roots. Extending the opt-in is
  the obvious next step and needs its own per-source measurement, not a blanket
  default.
- **Not established:** which code wrote the 514 journal rows during
  2026-07-02..04, or the 10 rows on 2026-06-21. Neither path is in `main`. The
  July window coincides with the `codex/perf-integration-review` merges, but that
  was not traced to a commit and is not claimed here. The prune is correct
  regardless of provenance.
- **One machine.** Every corpus figure is from a single local
  `~/.engram/index.sqlite`. The code facts — the pre-change absence of any
  `DELETE` in the product tree, the
  recency wrappers, `CodexAdapter`'s roots, `LIKE` wildcard semantics — are
  corpus-independent; the counts are not.
