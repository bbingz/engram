# Design Doc: <title>

- **Status**: Draft | In review | Accepted | Superseded by <link>
- **Owner**: <author>
- **Date**: <YYYY-MM-DD>
- **Related**: <PRs / issues / CHANGELOG entries / prior docs>

## Problem

What is broken or missing, who is affected, and why now. Cite observed
evidence (bug reports, measurements, session IDs) rather than speculation.

## Goals / Non-goals

- Goals: outcomes this change must deliver.
- Non-goals: adjacent work explicitly out of scope.

## Current state

How the affected subsystem works today. Anchor claims to code
(`path/File.swift:line` at a named commit) so drift is detectable.

## Proposed design

The minimum design that meets the goals. Cover what applies:

- Data / schema changes (migrations must be idempotent; update both the
  inline CREATE TABLE and the add-column list; note parity fixtures).
- Service / IPC changes (command handler case, DTOs, protocol, client,
  mock client).
- UI changes (views touched, read-model methods, `nonisolated` reads).
- Backfills (version-gated metadata key, ordering relative to existing
  startup backfills, self-terminating).

## Invariants affected

List each invariant from `docs/invariants.md` this design touches and how it
is preserved. New invariants introduced here must be added to the ledger in
the same PR.

## Alternatives considered

Each alternative in one or two sentences with the concrete reason it lost.

## Test plan

- Bug fixes: repro test first (`_repro` suffix), then the fix.
- New behavior: focused unit tests; parity fixtures when Swift/TS mirrors are
  involved; guard tests for red lines.
- What is intentionally not tested and why.

## Rollout

- Version/tag implications, deploy steps (app + service rebuild), and when
  backfills take effect.
- Revert story: what undoes this if it goes wrong.

## Risks and open questions

Known risks with likelihood/impact, and questions that must be answered
before or during implementation.
