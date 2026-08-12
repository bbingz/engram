# Design Doc: Cursor workspace ownership (CURSOR-CWD-001)

- **Status**: Implemented on PR #305
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
  - Executable regression coverage that rejects unrelated file selection as authority.
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

## Accepted design

### Authority rule

The definitive format evidence in `docs/session-formats/cursor.md` identifies
the only composer-bound mapping Cursor persists:

1. Enumerate direct children of `User/workspaceStorage`.
2. Accept only a `workspace.json` with a local absolute `file://` `folder` URI.
   A `configuration` workspace is potentially multi-root and is skipped.
3. Read `ItemTable['composer.composerData'].allComposers[]` from that
   workspace's `state.vscdb`.
4. Aggregate folder paths by `composerId`. Set ownership only when the set has
   exactly one unique path. Zero paths or conflicting paths leave ownership
   empty.

The mapping is refreshed once per session discovery pass and reused across all
parses in that pass. A standalone parse lazily loads the same mapping.

### Explicit non-authorities (must never set cwd alone)

- Currently selected / focused editor URI
- Recently opened files, search results, or git status paths
- Paths appearing only inside bubble `rawText` / tool payloads
- The directory containing `state.vscdb` itself

### Project derivation

When `cwd` is set, `project` is its final path component, matching the Swift
indexer's standard cwd fallback. No Cursor-only alias rule is added.

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

1. `testCursorUsesUniqueWorkspaceIndexInsteadOfUnrelatedFileSelection_repro`
   proves a unique pointer-index owner wins over an unrelated selected file.
2. `testCursorFileSelectionAloneDoesNotSetWorkspaceOwnership_repro` proves a
   selected file alone leaves `cwd == ""` / `project == nil`.
3. `testCursorConflictingWorkspaceIndexesFailClosed_repro` proves two distinct
   workspace owners leave ownership empty.
4. Existing Cursor content / byte-accounting tests remain in the focused suite.

## Rollout

- Implemented in `CursorAdapter` with focused `EngramCoreTests` fixtures.
- No migration; re-index updates new parses on next scan.
- Revert: restore empty cwd assignment.

## Risks and open questions

1. Cursor may omit or prune a per-workspace pointer. Those sessions remain
   unowned rather than falling back to prompt context.
2. Multi-root `configuration` workspaces intentionally remain empty until an
   explicit primary-root product contract exists.
3. No eager migration is added; normal re-indexing applies ownership when the
   pointer index is available.
