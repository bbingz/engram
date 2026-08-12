# Design Doc: Cursor workspace ownership (CURSOR-CWD-001)

- **Status**: Draft
- **Owner**: Grok (stewardship) + implementer
- **Date**: 2026-08-12
- **Related**: `docs/followups.md` B3; `CURSOR-CWD-001`; `macos/Shared/EngramCore/Adapters/Sources/CursorAdapter.swift`; PR #211 (Cursor content only)

## Problem

Cursor sessions currently ship with empty `cwd` and `project: nil`
(`CursorAdapter.swift` `parseSessionInfo` success path). That is safer than
wrong ownership, but it blocks project grouping, move/archive confinement, and
home/today filters that rely on project identity.

Historical risk (followups + 2026-07-18 blind audit): any “infer CWD from
selected editor file / open tab” heuristic can attach a session to an unrelated
repo when the user has multi-root workspaces or browsed a dependency path.

## Goals / Non-goals

- Goals:
  - Deterministic rule for when Engram may set Cursor `cwd` / `project`.
  - Fail closed: prefer empty over wrong.
  - Executable `_repro` that rejects unrelated file selection as authority.
- Non-goals:
  - Reconstructing full multi-root VS Code workspace graphs.
  - Inferring project from message text or tool output paths.
  - Changing non-Cursor adapters.

## Current state

- Locator shape: `state.vscdb?composer=<composerId>` (`parseVirtualLocator`).
- Session metadata from `cursorDiskKV` key `composerData:<id>` only.
- `cwd: ""`, `project: nil` always today — intentional fail-closed until this
  contract lands.
- Per-session byte accounting already avoids attributing whole `state.vscdb`
  size (content work in #211 family).

## Proposed design

### Authority order (first match wins)

1. **Composer-bound workspace folder** — a path field on `composerData` that
   Cursor stores as the conversation’s workspace root (exact key TBD by fixture
   inspection of real `composerData` JSON). Must be an absolute directory path.
2. **Explicit workspace id → folder map** — only if `composerData` names a
   workspace id that maps 1:1 to a single folder path in Cursor storage (not a
   multi-folder workspace unless all folders share one basename project policy
   we already use elsewhere — default: skip multi-root).
3. **Else leave empty** — do not guess.

### Explicit non-authorities (must never set cwd alone)

- Currently selected / focused editor URI
- Recently opened files, search results, or git status paths
- Paths appearing only inside bubble `rawText` / tool payloads
- The directory containing `state.vscdb` itself

### Project derivation

When `cwd` is set, derive `project` with the same basename/alias rules used by
other Swift adapters (no Cursor-only special case beyond ownership).

### Persistence

No schema change. Indexer already stores `cwd` / `project` on sessions; empty
rows remain valid.

## Invariants affected

- No change to write-path single-writer invariant (adapter parse only).
- Project-move path confinement benefits once cwd is accurate; incorrect cwd
  would expand blast radius — hence fail-closed rule is load-bearing.

## Alternatives considered

- **Always empty (status quo)** — safe but permanent product gap for Cursor
  project surfaces. Loses for long-term UX once a safe key is proven.
- **Majority path among open files** — non-deterministic, multi-root unsafe.
- **Git root of first user message path** — message content is not ownership.

## Test plan

1. Fixture: `composerData` with a clear workspace root key → `cwd`/`project`
   populated.
2. `_repro`: composer with only a selected-file / open-editors style field and
   no workspace root → remains `cwd == ""` / `project == nil`.
3. Multi-root workspace id without single folder → empty.
4. Existing Cursor content / byte-accounting tests stay green.

## Rollout

- Design accept → implement in `CursorAdapter` + focused
  `EngramCoreTests` Cursor fixtures.
- No migration; re-index updates new parses on next scan.
- Revert: restore empty cwd assignment.

## Risks and open questions

1. **Which real `composerData` keys are stable across Cursor versions?** Need
   at least two host fixtures before coding the happy path.
2. Multi-root policy: empty vs primary folder — default empty until product
   pick.
3. Do not backfill historical rows until the key is proven on live DBs.
