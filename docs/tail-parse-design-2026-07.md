# Design Doc: JSONL Tail Parsing for Swift Indexing

- **Status**: Accepted for wave 5 implementation
- **Owner**: Codex
- **Date**: 2026-07-08
- **Related**: Wave 5 task 8 (`tail-parse`), upcoming PR, `CHANGELOG.md` Unreleased entry

## Problem

Claude Code transcripts are append-only JSONL in the common case. The Swift
indexer currently treats any changed file as a full-file reparse, so a one-line
append to a large transcript pays the same parse cost as indexing the whole
file. `file_index_state` already stores `parsed_offset` and `boundary_hash`
columns, but the runtime does not consume them for append detection.

The change is needed now because the app has active performance coverage for
the Swift indexer, but the production path still lacks the safe tail checkpoint
needed to make append work incremental without losing exact parity with full
reparse output.

## Goals / Non-goals

- Goals: detect safe append-only JSONL changes, parse only complete appended
  lines for the fast path, persist a reusable checkpoint, and prove that the
  resulting database state matches a full reindex.
- Goals: guarantee that `parsed_offset` advances only to a complete-line
  boundary and that an unterminated appended line is picked up after it is
  completed.
- Goals: prefer full reparse whenever file identity, boundary bytes, or derived
  state cannot prove an exact merge.
- Non-goals: add a schema migration, change non-JSONL adapters, or make
  semantic/vector search incremental.
- Non-goals: ship an additive merge for fields that require unavailable prior
  transcript context.

## Current state

At `main` commit `6ffc6e5c`, `FileIndexState` already has checkpoint fields:
`parsedOffset` and `boundaryHash` are stored on the model
(`macos/EngramCoreWrite/Indexing/IndexingWriteSink.swift:105`,
`:115`, `:116`). A successful parse currently sets `parsedOffset` to the full
file size and stores `boundaryHash` as `nil`
(`macos/EngramCoreWrite/Indexing/IndexingWriteSink.swift:159`, `:172`,
`:173`).

Those fields are persisted in `file_index_state`: the migration has
`parsed_offset` and `boundary_hash`
(`macos/EngramCoreWrite/Database/EngramMigrations.swift:156`, `:163`,
`:164`), and the database writer reads and writes them
(`macos/EngramCoreWrite/Indexing/EngramDatabaseIndexer.swift:170`, `:201`,
`:202`, `:215`, `:237`, `:238`).

`SwiftIndexer` fetches `knownFileIndexStates` before scanning locators
(`macos/EngramCoreWrite/Indexing/SwiftIndexer.swift:166`, `:169`), but the
decision only skips when size, mtime, inode, and device all match the stored
state (`macos/EngramCoreWrite/Indexing/IndexingWriteSink.swift:90`,
`:93`, `:214`). If the file changed, the indexer always calls
`adapter.scanForIndexing(locator:)` and builds a fresh snapshot from the full
message list (`macos/EngramCoreWrite/Indexing/SwiftIndexer.swift:210`,
`:214`, `:240`, `:244`).

Claude Code indexing already has a single-read full parser:
`ClaudeCodeAdapter.scanForIndexing` uses `JSONLAdapterSupport.readObjects`
and then derives session info plus messages from the resulting objects
(`macos/Shared/EngramCore/Adapters/Sources/ClaudeCodeAdapter.swift:108`,
`:110`, `:116`, `:120`). `JSONLAdapterSupport.readObjects` reads every line
from the beginning of the file
(`macos/Shared/EngramCore/Adapters/Sources/CodexAdapter.swift:80`, `:87`,
`:91`, `:100`).

Full snapshot construction includes fields that are not all additive from raw
counts. In particular, implementation beats are derived by walking the ordered
message stream (`macos/Shared/EngramCore/Indexing/ImplementationDigestExtractor.swift:121`,
`:140`, `:147`, `:163`), and the current writer reconstructs only a partial
snapshot from the `sessions` row for merges
(`macos/EngramCoreWrite/Indexing/SessionSnapshotWriter.swift:218`, `:222`,
`:249`).

## Proposed design

Add a bounded JSONL tail checkpoint helper shared by append-capable JSONL
adapters. The helper records a checkpoint as:

- `parsedOffset`: byte offset immediately after the last newline-complete line.
- `boundaryHash`: SHA-256 of the last 4 KiB before `parsedOffset` (or the
  available shorter prefix).

The fast path is eligible only when all preconditions hold:

- The stored state is schema-current and has `parseStatus == ok`.
- The current file has the same inode and device as the stored state.
- The current size is greater than the stored `parsedOffset`; shrink and equal
  size changes are full reparse.
- The stored `parsedOffset` is inside the current file and falls on a
  complete-line boundary.
- Re-hashing the bytes immediately before `parsedOffset` exactly matches
  `boundaryHash`.
- The tail scan reads at least one newline-complete JSONL line, and any final
  unterminated bytes remain beyond the new checkpoint.

Add an optional adapter capability for tail indexing. `ClaudeCodeAdapter` will
implement it first. `CodexAdapter` remains a follow-up unless the shared helper
makes support near-free without changing parser semantics.

The indexer merge is intentionally gated:

- If the tail starts with a substantive user message, existing implementation
  beats cannot be modified by later assistant output, so the indexer may merge
  current persisted snapshot state with the parsed tail.
- If the tail starts with assistant, tool, system, or any message that could
  alter the previous pending human turn, the indexer must full-reparse.
- If current persisted costs, tools, work beats, instruction signals, parent
  link, tier inputs, or any other derived field cannot be reconstructed exactly,
  the indexer must full-reparse.
- If a full reparse is required after a valid append is detected, the code still
  refreshes the checkpoint from the full parse result. It must not ship an
  unsound additive merge.

There is no schema change. The existing `file_index_state` columns become live.

## Invariants affected

Existing invariant 1 (Swift runtime owns product behavior) is preserved because
the implementation lives in the Swift indexer and Swift adapters only.

Existing invariant 3 (app and MCP writes go through the service writer gate) is
preserved because tail indexing still writes through `IndexingWriteSink` and
`SessionBatchUpsert`.

A new invariant is introduced: append-tail checkpoints may advance only to a
newline-complete JSONL boundary whose bounded boundary hash is persisted with
the offset. This PR must add that invariant to `docs/invariants.md`.

## Alternatives considered

Always full-reparse after detecting append-only changes. This is safe and keeps
checkpoint bookkeeping honest, but it does not deliver the intended large-file
append cost reduction.

Blindly add tail counts to the current `sessions` row. This loses parity because
implementation beats, instruction deduplication, and some tier inputs depend on
ordered prior transcript context.

Persist every normalized message in SQLite. That would make future merges easy
to prove, but it is a larger storage and migration project than this task needs.

## Test plan

- Add a parity test that indexes a Claude fixture, appends a user/assistant
  pair, runs the tail path, full-indexes the final file into a second temporary
  database, and compares sessions, costs, tools, work beats, file index state,
  queued index jobs, and searchable FTS content after draining jobs.
- Add a rewrite-in-place fallback test proving boundary mismatch routes to full
  reparse.
- Add a truncation fallback test proving shrink routes to full reparse.
- Add a partial-line test proving `parsedOffset` does not advance past an
  unterminated tail and that the completed line is picked up on the next pass.
- Keep non-JSONL adapters on the existing full-parse path.

## Rollout

No version bump or migration is required. The next app/service build starts
writing non-null boundary checkpoints for successful JSONL parses. Existing
rows with `boundary_hash == NULL` are treated as ineligible and will full-reparse
once before becoming eligible.

Revert is straightforward: remove the tail capability and restore success
checkpoints to full file size with nil boundary hash. Stored checkpoint values
are harmless if no consumer uses them.

## Risks and open questions

The main risk is a false-positive append merge. The mitigation is strict gating:
same file identity, boundary hash match, complete-line offsets, and full reparse
whenever derived state cannot be reconstructed exactly.

Performance gains apply only to eligible Claude Code appends. Rewrites,
truncations, rows without a boundary hash, and tails that can mutate the previous
implementation beat intentionally keep full-parse behavior.
